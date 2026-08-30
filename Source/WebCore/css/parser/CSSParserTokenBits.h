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

// CSSParserToken's storage, kept in its own self-contained header (it deliberately does not
// include CSSParserToken.h) so exactly one definition is compiled by both C++ and Swift.
//
// Swift names this struct's fields directly, including the anonymous union's members and
// `pendingNumberRange`. Swift's writers live in CSSParserTokenBitsSwift.swift; this header
// keeps only the accessors C++ still calls.

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

// CSSParserToken's own storage, unchanged, so C++ and Swift compile the exact same layout.
//
// Same fields, same order, same bitfield widths as CSSParserToken's private storage, so the
// object's layout and every accessor's codegen are unaffected.
//
// SWIFT_SAFE is honest rather than a silencer: the pointer slot holds an *offset* for as long
// as Swift can see the struct -- resolveValuePointer turns it into a pointer only after the
// chunk has crossed into C++. Swift never forms or dereferences a pointer here, so there is no
// lifetime to model and no ~Escapable requirement.
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


// MARK: - Token-bits factories
//
// One factory per token kind, mirroring CSSParserToken's constructors. Inline, so the Swift
// importer folds them and no call survives.
//
// `valueOffset` is an offset into the input, parked in the pointer slot; resolveValuePointer
// below turns it into a real pointer once the chunk lands in C++. Swift therefore never
// holds, forms or dereferences a pointer.

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
