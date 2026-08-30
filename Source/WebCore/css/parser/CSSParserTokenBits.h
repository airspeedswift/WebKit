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

        // While Swift still holds the token, the number's own range in the input.
        // `resolveNumericValue` reads it and overwrites it with `numericValue`; the range is
        // dead once the double exists.
        struct { unsigned offset; unsigned length; } pendingNumberRange;
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

// The constructor this mirrors uses designated mem-initialisers, leaving the union's bytes
// above the delimiter unspecified; this zeroes them via numericValue's default member
// initialiser instead. Behaviourally identical, since nothing may read an unwritten union
// member, and better defined.
inline CSSParserTokenBits makeDelimiterTokenBits(unsigned type, char16_t character)
{
    CSSParserTokenBits bits;
    bits.type = type;
    bits.delimiter = character;
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
// the rounding stays bit-identical with the C++ scanner, for free. Until that post-pass runs
// the union carries the number's own range instead, which costs nothing because the slot the
// double will occupy is dead until it exists.
//
// The number's range and the value range are separate parameters because they are separate
// things, and the first is not recoverable from the second. For a NumberToken they do coincide
// -- value() is originalText() is the number. But convertToDimensionWithUnit merges the number
// and the unit into one view when they are physically adjacent in the input and the number is
// shorter than sixteen characters, and after that merge value() is "10px" and the number's own
// range is only recoverable if you know the merge happened. In the two cases where it did not
// -- a number of sixteen characters or more, and an escaped unit, whose text is a pooled String
// rather than a range of the input -- value() is the unit alone and the number is nowhere in it.
//
// nonUnitPrefixLength is the field that records which of those happened: zero when the value is
// the bare unit, the number's length when the two were merged. It is not a detail the caller may
// leave at its default, because unitString() is defined as value().substring(nonUnitPrefixLength),
// operator== selects which comparison a DimensionToken gets on whether it is zero, and custom
// property serialization reserializes from value(). A merged value with a zero prefix length is a
// state convertToDimensionWithUnit can never produce, and every one of those three would read it
// as a unit sixteen characters long.
inline CSSParserTokenBits makeNumericTokenBits(unsigned type, unsigned numericValueType, unsigned numericSign, unsigned unit, unsigned valueOffset, unsigned valueLength, unsigned nonUnitPrefixLength, unsigned numberOffset, unsigned numberLength, bool is8Bit)
{
    CSSParserTokenBits bits;
    bits.type = type;
    bits.numericValueType = numericValueType;
    bits.numericSign = numericSign;
    bits.unit = unit;
    bits.nonUnitPrefixLength = nonUnitPrefixLength;
    bits.valueLength = valueLength;
    bits.valueIs8Bit = is8Bit;
    bits.valueDataCharRaw = reinterpret_cast<const void*>(static_cast<uintptr_t>(valueOffset));
    bits.pendingNumberRange = { numberOffset, numberLength };
    return bits;
}

// NumberToken, PercentageToken and DimensionToken are contiguous, so "does this token still
// owe a double" is one unsigned range check rather than a switch.
constexpr unsigned firstNumericCSSParserTokenType = 7; // NumberToken
constexpr unsigned lastNumericCSSParserTokenType = 9; // DimensionToken

inline constexpr bool bitsCarryPendingNumber(const CSSParserTokenBits& bits)
{
    return bits.type - firstNumericCSSParserTokenType <= lastNumericCSSParserTokenType - firstNumericCSSParserTokenType;
}

// The branch-free half of the boundary: an offset becomes a pointer, with no reference to
// the token's kind.
//
// A token that carries no value comes out with a *null* value pointer rather than a pointer
// to the start of the input with length zero. Every constructor leaves the slot null for such
// a token, so value() is a null StringView there, and null and empty are not interchangeable:
// StringView::isNull distinguishes them, and toString turns one into a null String and the
// other into an empty one.
//
// The unresolved state of a valueless token is exactly offset zero with length zero, and no
// real value can hold it: a zero-length value only occurs inside a delimited token (`""` or
// `url()`), so its range always starts past the opening delimiter and its offset is never
// zero. Testing the two fields together therefore separates the cases exactly, as an or, a
// compare and a select rather than a branch: the resolved pointer is computed unconditionally
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
