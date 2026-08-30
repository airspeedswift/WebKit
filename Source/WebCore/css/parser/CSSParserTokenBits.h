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

#include <cstddef>
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
// compiled by both C++ and Swift. The island used to emit a different struct carrying offsets
// plus a type tag, which C++ decoded back into a typed constructor call -- a dispatch the
// producer had already made for free. Sharing the real storage lets the island write finished
// tokens instead, and that round trip is gone.
//
// Same fields, same order, same bitfield widths, so the object's layout and every accessor's
// codegen are unchanged. Lifting it out was a pure refactor and was verified as one.
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

        // While the island still holds the token, the number's own range in the input.
        // resolveNumericValue reads it and overwrites it with numericValue -- the range is
        // dead the moment the double exists, and the double is the only thing that survives.
        struct { unsigned offset; unsigned length; } pendingNumberRange;
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
//
// Where a field is a C++ enumeration with two or three values -- NumericValueType,
// NumericSign, HashTokenType -- these take booleans and do the mapping here, rather than
// taking the encoded value. That is deliberate: an island passing `1` for NumberValueType
// would be mirroring a numbering with nothing checking it, and these enums have no
// static_assert bridge the way CSSParserTokenType and CSSUnitType do. `type`, `blockType`
// and `unit` do take encoded values, because for those the island's enums are declared in
// Swift with `@c` and CSSTokenizer.cpp pins all 106 enumerators by name.

// Which buffer a parked value offset indexes. Set means the chunk's unescape buffer, clear
// means the input. There is no room in CSSParserTokenBits for a flag of its own -- every bit
// of it is CSSParserToken::m_bits, and adding one would change the object the whole CSS
// parser stores -- but the pointer slot holds a 32-bit offset for as long as Swift owns the
// token, so the top bit of that is free until resolveValuePointer runs.
constexpr unsigned cssParserTokenBitsUnescapedValueTag = 0x80000000u;

// The island calls this once per tokenization, not once per token. A stylesheet at or above
// 2 GB cannot have its value offsets tagged, and the island has no fallback, so it reports
// failure instead of truncating. Nothing real comes close; "surely not" is not a bound.
inline bool cssParserTokenBitsCanRepresentOffsets(size_t inputLength)
{
    return inputLength < cssParserTokenBitsUnescapedValueTag;
}

// The offset Swift parked in the pointer slot, tag included. Only meaningful before
// resolveValuePointer has run.
inline unsigned bitsParkedValueOffset(const CSSParserTokenBits& bits)
{
    return static_cast<unsigned>(reinterpret_cast<uintptr_t>(bits.valueDataCharRaw));
}

// Swift cannot name a bitfield, and this is the only kind it has to read back off a finished
// token: end-of-file to stop the loop, and CommentToken to keep comments out of the token
// buffer. One `ubfx`, and the packing still lives in exactly one place.
inline unsigned tokenBitsType(const CSSParserTokenBits& bits)
{
    return bits.type;
}

inline CSSParserTokenBits makeSimpleTokenBits(unsigned type, unsigned blockType)
{
    CSSParserTokenBits bits;
    bits.type = type;
    bits.blockType = blockType;
    return bits;
}

inline CSSParserTokenBits makeValueTokenBits(unsigned type, unsigned blockType, unsigned valueOffset, unsigned valueLength, bool valueIsUnescaped, bool is8Bit)
{
    CSSParserTokenBits bits;
    bits.type = type;
    bits.blockType = blockType;
    bits.valueLength = valueLength;
    bits.valueIs8Bit = is8Bit;
    bits.valueDataCharRaw = reinterpret_cast<const void*>(static_cast<uintptr_t>(valueIsUnescaped ? valueOffset | cssParserTokenBitsUnescapedValueTag : valueOffset));
    bits.id = -1;
    return bits;
}

// The constructor this mirrors uses designated mem-initialisers, so it leaves the union's bytes
// above the delimiter unspecified where this zeroes them through numericValue's default member
// initialiser. That is behaviourally identical -- nothing may read a union member that was never
// written -- and better defined, so it is deliberate rather than an oversight.
inline CSSParserTokenBits makeDelimiterTokenBits(unsigned type, unsigned character)
{
    CSSParserTokenBits bits;
    bits.type = type;
    bits.delimiter = static_cast<char16_t>(character);
    return bits;
}

// Zeroes the rest of the union where the constructor leaves it unspecified, for the same reason
// as the delimiter factory above.
inline CSSParserTokenBits makeWhitespaceTokenBits(unsigned type, unsigned count)
{
    CSSParserTokenBits bits;
    bits.type = type;
    bits.whitespaceCount = count;
    return bits;
}

inline CSSParserTokenBits makeHashTokenBits(unsigned type, bool isIdHashToken, unsigned valueOffset, unsigned valueLength, bool valueIsUnescaped, bool is8Bit)
{
    CSSParserTokenBits bits;
    bits.type = type;
    bits.valueLength = valueLength;
    bits.valueIs8Bit = is8Bit;
    bits.valueDataCharRaw = reinterpret_cast<const void*>(static_cast<uintptr_t>(valueIsUnescaped ? valueOffset | cssParserTokenBitsUnescapedValueTag : valueOffset));
    bits.hashTokenType = isIdHashToken ? HashTokenId : HashTokenUnrestricted;
    return bits;
}

// Numeric tokens keep their double unconverted: charactersToDouble runs on the C++ side so
// the rounding stays bit-identical with the C++ scanner, for free. Until that post-pass runs
// the union carries the number's own range instead, which costs nothing because the slot the
// double will occupy is dead until it exists.
//
// The number's range and the value range are separate parameters because they are separate
// things, and the first is not recoverable from the second. For a NumberToken they do coincide
// -- value() is originalText() is the number. But a DimensionToken merges the number and the
// unit into one view when they are physically adjacent in the input and the number is shorter
// than sixteen characters, and after that merge value() is "10px" and the number's own range is
// only recoverable if you know the merge happened. In the two cases where it did not -- a number
// of sixteen characters or more, and an escaped unit, whose text is a pooled String rather than
// a range of the input -- value() is the unit alone and the number is nowhere in it.
//
// nonUnitPrefixLength is the field that records which of those happened: zero when the value is
// the bare unit, the number's length when the two were merged. It is not a detail the caller may
// leave at its default, because unitString() is defined as value().substring(nonUnitPrefixLength),
// operator== selects which comparison a DimensionToken gets on whether it is zero, and custom
// property serialization reserializes from value(). A merged value with a zero prefix length is a
// state convertToDimensionWithUnit can never produce, and every one of those three would read it
// as a unit sixteen characters long.
inline CSSParserTokenBits makeNumericTokenBits(unsigned type, bool isNonInteger, bool hasPlusSign, bool hasMinusSign, unsigned unit, unsigned valueOffset, unsigned valueLength, bool valueIsUnescaped, unsigned nonUnitPrefixLength, unsigned numberOffset, unsigned numberLength, bool is8Bit)
{
    CSSParserTokenBits bits;
    bits.type = type;
    bits.numericValueType = isNonInteger ? NumberValueType : IntegerValueType;
    bits.numericSign = hasMinusSign ? MinusSign : (hasPlusSign ? PlusSign : NoSign);
    bits.unit = unit;
    bits.nonUnitPrefixLength = nonUnitPrefixLength;
    bits.valueLength = valueLength;
    bits.valueIs8Bit = is8Bit;
    bits.valueDataCharRaw = reinterpret_cast<const void*>(static_cast<uintptr_t>(valueIsUnescaped ? valueOffset | cssParserTokenBitsUnescapedValueTag : valueOffset));
    bits.pendingNumberRange = { numberOffset, numberLength };
    return bits;
}

// NumberToken, PercentageToken and DimensionToken are 7, 8 and 9 in CSSParserTokenType, and
// contiguous, so "does this token still owe a double" is one unsigned range check rather than a
// switch. The enumerators cannot be named here: this header is deliberately free of
// CSSParserToken.h so the island's Clang module can take it alone. CSSParserToken.h is the one
// place that can see both, and it static_asserts these literals against the enumerators, because
// a stand-in whose value drifts from the real definition with no diagnostic is a failure this
// project has already paid for.
constexpr unsigned firstNumericCSSParserTokenType = 7; // NumberToken
constexpr unsigned lastNumericCSSParserTokenType = 9; // DimensionToken

inline constexpr bool bitsCarryPendingNumber(const CSSParserTokenBits& bits)
{
    return bits.type - firstNumericCSSParserTokenType <= lastNumericCSSParserTokenType - firstNumericCSSParserTokenType;
}

// The branch-free half of the boundary: an offset becomes a pointer, with no reference to
// the token's kind. Only for an offset into the *input* -- a caller that finds
// cssParserTokenBitsUnescapedValueTag set has to intern the value first and set the three
// value fields itself, because there is no input range to point at.
//
// A token that carries no value has to come out with a *null* value pointer rather than a
// pointer to the start of the input with length zero. Every constructor leaves the slot null
// for such a token, so value() is a null StringView there, and null and empty are not
// interchangeable: StringView::isNull distinguishes them, and toString turns the one into a null
// String and the other into an empty one. The comment that used to sit here claimed base + 0 was
// harmless, and it was wrong.
//
// The unresolved state of a valueless token is exactly offset zero with length zero, and no
// real value can hold it. A zero-length value only occurs inside a delimited token -- `""` or
// `url()` -- so its range always starts past the opening delimiter and its offset is never
// zero. Testing the two fields together therefore separates the cases exactly, and it is an or,
// a compare and a select rather than a branch: the resolved pointer is computed unconditionally
// on both paths.
inline void resolveValuePointer(CSSParserTokenBits& bits, std::span<const uint8_t> input, unsigned characterSize)
{
    auto offset = reinterpret_cast<uintptr_t>(bits.valueDataCharRaw);
    // subspan rather than pointer arithmetic: libc++ hardening is on in this build, so this
    // is a real bounds check on a value that crossed a language boundary, which the raw form
    // would not have been.
    const void* resolved = input.subspan(offset * characterSize).data();
    bits.valueDataCharRaw = (offset | bits.valueLength) ? resolved : nullptr;
}

} // namespace WebCore
