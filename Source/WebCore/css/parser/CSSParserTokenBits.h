/*
 * Copyright (C) 2026 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

// CSSParserToken's storage, in its own header so that exactly one definition is compiled by
// both C++ and Swift. Self-contained on purpose: the island's boundary module takes this and
// nothing else, so importing it cannot walk into WebCore's umbrella.
//
// Swift cannot name a bitfield or an anonymous union member, so it does not: it calls the
// inline setters below, which are the only place the packing is written down.

#pragma once

#include <cstdint>
#include <span>
#include <wtf/SwiftBridging.h>

namespace WebCore {

enum NumericSign {
    NoSign,
    PlusSign,
    MinusSign,
};

enum NumericValueType {
    IntegerValueType,
    NumberValueType,
};

enum HashTokenType {
    HashTokenId,
    HashTokenUnrestricted,
};

// CSSParserToken's storage, lifted out of the class *unchanged* so one definition can be
// compiled by both C++ and Swift. The island today emits a different struct carrying offsets
// plus a type tag, which C++ decodes back into a typed constructor call -- a dispatch the
// producer had already made for free. Sharing the real storage lets the island write finished
// tokens instead, deleting that round trip.
//
// Same fields, same order, same bitfield widths, so the object's layout and every accessor's
// codegen are unchanged. This is a pure refactor and is verified as one.
// SWIFT_SAFE, and it is honest rather than a silencer: the pointer slot holds an *offset*
// for as long as Swift can see the struct -- resolveValuePointer turns it into a pointer only
// after the chunk has crossed into C++. So Swift never forms or dereferences one, and there is
// no lifetime to model either, which is why this needs no ~Escapable and sidesteps the whole
// problem that blocked handing Swift a real CSSParserToken.
struct SWIFT_SAFE CSSParserTokenBits {
    unsigned type : 6 { 0 }; // CSSParserTokenType
    unsigned blockType : 2 { 0 }; // BlockType
    unsigned numericValueType : 1 { 0 }; // NumericValueType
    unsigned numericSign : 2 { 0 }; // NumericSign
    unsigned unit : 7 { 0 }; // CSSUnitType
    unsigned nonUnitPrefixLength : 4 { 0 }; // Only for DimensionType, only needs to be long enough for UnicodeRange parsing.

    // value... is an unpacked StringView so that we can pack it
    // tightly with the rest of this object for a smaller object size.
    bool valueIs8Bit : 1 { false };
    bool isBackedByStringLiteral : 1 { false };
    unsigned valueLength { 0 };
    const void* valueDataCharRaw { nullptr }; // Either Latin1Character* or char16_t*.

    union {
        char16_t delimiter;
        HashTokenType hashTokenType;
        double numericValue { 0 };
        mutable int id;
        unsigned whitespaceCount;
    };
};


// MARK: - The island's writers
//
// One factory per token kind, mirroring CSSParserToken's constructors, so a producer that
// knows the kind statically never encodes it for a consumer to decode again. Inline, so the
// Swift importer folds them and no call survives.
//
// `valueOffset` is an offset into the input, parked in the pointer slot; resolveValuePointer
// below turns it into a real pointer in one branch-free pass once the chunk lands in C++.
// Swift therefore never holds, forms or dereferences a pointer.

inline CSSParserTokenBits makeSimpleTokenBits(unsigned type, unsigned blockType)
{
    CSSParserTokenBits bits;
    bits.type = type;
    bits.blockType = blockType;
    return bits;
}

inline CSSParserTokenBits makeValueTokenBits(unsigned type, unsigned blockType, unsigned valueOffset, unsigned valueLength, bool is8Bit)
{
    CSSParserTokenBits bits;
    bits.type = type;
    bits.blockType = blockType;
    bits.valueLength = valueLength;
    bits.valueIs8Bit = is8Bit;
    bits.valueDataCharRaw = reinterpret_cast<const void*>(static_cast<uintptr_t>(valueOffset));
    bits.id = -1;
    return bits;
}

inline CSSParserTokenBits makeDelimiterTokenBits(unsigned type, char16_t character)
{
    CSSParserTokenBits bits;
    bits.type = type;
    bits.delimiter = character;
    return bits;
}

inline CSSParserTokenBits makeWhitespaceTokenBits(unsigned type, unsigned count)
{
    CSSParserTokenBits bits;
    bits.type = type;
    bits.whitespaceCount = count;
    return bits;
}

inline CSSParserTokenBits makeHashTokenBits(unsigned type, unsigned hashTokenType, unsigned valueOffset, unsigned valueLength, bool is8Bit)
{
    CSSParserTokenBits bits;
    bits.type = type;
    bits.valueLength = valueLength;
    bits.valueIs8Bit = is8Bit;
    bits.valueDataCharRaw = reinterpret_cast<const void*>(static_cast<uintptr_t>(valueOffset));
    bits.hashTokenType = static_cast<HashTokenType>(hashTokenType);
    return bits;
}

// Numeric tokens keep their double unconverted: charactersToDouble runs on the C++ side so
// the rounding stays bit-identical with the C++ scanner, for free. The value range is the
// number's own text, which is what CSSParserToken calls originalText.
inline CSSParserTokenBits makeNumericTokenBits(unsigned type, unsigned numericValueType, unsigned numericSign, unsigned unit, unsigned numberOffset, unsigned numberLength, bool is8Bit)
{
    CSSParserTokenBits bits;
    bits.type = type;
    bits.numericValueType = numericValueType;
    bits.numericSign = numericSign;
    bits.unit = unit;
    bits.valueLength = numberLength;
    bits.valueIs8Bit = is8Bit;
    bits.valueDataCharRaw = reinterpret_cast<const void*>(static_cast<uintptr_t>(numberOffset));
    return bits;
}

// The branch-free half of the boundary: an offset becomes a pointer, with no reference to
// the token's kind. Tokens carrying no value have length 0, so base + 0 is harmless.
inline void resolveValuePointer(CSSParserTokenBits& bits, std::span<const uint8_t> input, unsigned characterSize)
{
    auto offset = reinterpret_cast<uintptr_t>(bits.valueDataCharRaw);
    // subspan rather than pointer arithmetic: libc++ hardening is on in this build, so this
    // is a real bounds check on a value that crossed a language boundary, which the raw form
    // would not have been.
    bits.valueDataCharRaw = input.subspan(offset * characterSize).data();
}

} // namespace WebCore
