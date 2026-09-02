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

// CSSParserToken's storage, in a self-contained header that does not include CSSParserToken.h,
// so that C++ and Swift compile one definition of the layout rather than two. Swift names the
// fields directly and its writers are in CSSParserTokenBitsSwift.swift; what is declared here
// are the accessors C++ calls.

#pragma once

#include <cstddef>
#include <cstdint>
#include <span>
#include <type_traits>
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

// The bitfields below occupy 25 bits of a single 32-bit allocation unit. CSSParserToken.h
// asserts the resulting object size, which is a cache-residency property: the CSS parser holds
// one of these per token of every stylesheet.
//
// SWIFT_SAFE holds rather than silences: while Swift can see the struct the pointer slot holds
// an offset, and resolveValuePointer turns it into a pointer only after the chunk has crossed
// into C++. Swift never forms or dereferences a pointer here, so there is no lifetime to model
// and no ~Escapable requirement.
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
    // Whether the union below carries `pendingNumberRange` rather than one of its other
    // members. Which member is active is a phase of construction rather than a function of
    // `type`, so it is tracked explicitly: `makeNumericTokenBits` is the only writer that sets
    // it, and every other factory and every one of `CSSParserToken`'s constructors leaves it
    // clear.
    unsigned hasParkedNumberRange : 1 { 0 };
    unsigned valueLength { 0 };
    // The value's characters. While Swift owns the token the slot holds `parkedValueOffset`, an
    // offset into the input, or, tagged, into the chunk's unescape buffer;
    // `resolveValuePointer` turns it into `valueDataCharRaw` once the chunk has crossed into
    // C++. A union so that Swift can write the offset with no `unsafe` marker: under strict
    // memory safety (SE-0458) every expression of type `UnsafeRawPointer` is unsafe to form or
    // store, dereferenced or not. `uintptr_t` so that the alternative covers the whole slot.
    union {
        const void* valueDataCharRaw; // Either Latin1Character* or char16_t*.
        uintptr_t parkedValueOffset { 0 };
    };

    union {
        char16_t delimiter;
        HashTokenType hashTokenType;
        double numericValue { 0 };
        mutable int id;
        unsigned whitespaceCount;

        // While Swift still holds the token, the number's own range in the input.
        // CSSSwiftTokenSink::takeChunk reads it and overwrites it with `numericValue`; the range
        // is dead once the double exists. Read only when `hasParkedNumberRange` is set.
        struct { unsigned offset; unsigned length; } pendingNumberRange;
    };
};


// MARK: - Reading the parked state

// Which buffer a parked value offset indexes: set means the chunk's unescape buffer, clear
// means the input. The tag lives in the offset's top bit because CSSParserTokenBits has no
// spare flag to give, being the whole of CSSParserToken's storage, whereas the pointer slot
// holds a 32-bit offset until resolveValuePointer runs.
constexpr unsigned cssParserTokenBitsUnescapedValueTag = 0x80000000u;

// The offset parked in the pointer slot, tag included. Only meaningful before
// resolveValuePointer has run.
inline unsigned bitsParkedValueOffset(const CSSParserTokenBits& bits)
{
    return static_cast<unsigned>(bits.parkedValueOffset);
}

// MARK: - The token types
//
// Declared here rather than in CSSParserToken.h so that Swift imports the enumeration itself
// rather than mirroring it. CSSParserToken.h includes this header, and the enum stays unscoped,
// so every `IdentToken` in the CSS parser still resolves unqualified. Swift sees it as a type
// with `rawValue` whose enumerators are global constants: `WebCore.IdentToken`, not
// `CSSParserTokenType.ident`.

// `: uint8_t` so that the Swift side's `rawValue` is a `UInt8`, matching the block-stack
// storage. Without it the enum imports with a `CUnsignedInt` rawValue and every use needs a
// narrowing conversion.
enum CSSParserTokenType : uint8_t {
    IdentToken = 0,
    FunctionToken,
    AtKeywordToken,
    HashToken,
    UrlToken,
    BadUrlToken,
    DelimiterToken,
    NumberToken,
    PercentageToken,
    DimensionToken,
    IncludeMatchToken,
    DashMatchToken,
    PrefixMatchToken,
    SuffixMatchToken,
    SubstringMatchToken,
    ColumnToken,
    NonNewlineWhitespaceToken,
    NewlineToken,
    CDOToken,
    CDCToken,
    ColonToken,
    SemicolonToken,
    CommaToken,
    LeftParenthesisToken,
    RightParenthesisToken,
    LeftBracketToken,
    RightBracketToken,
    LeftBraceToken,
    RightBraceToken,
    StringToken,
    BadStringToken,
    EOFToken,
    CommentToken,
    LastCSSParserTokenType = CommentToken,
};

constexpr std::underlying_type_t<CSSParserTokenType> numberOfCSSParserTokenTypes = LastCSSParserTokenType + 1;

// NumberToken, PercentageToken and DimensionToken are contiguous, so "does this token still
// owe a double" is one unsigned range check rather than a switch.
constexpr unsigned firstNumericCSSParserTokenType = NumberToken;
constexpr unsigned lastNumericCSSParserTokenType = DimensionToken;

// Whether a token of this type owes a double, from the type alone. CSSParserToken.h asserts
// this against a three-way test over every token type. It cannot say whether the token actually
// came from `makeNumericTokenBits`, the only writer of that union member; that is what
// `CSSParserTokenBits::hasParkedNumberRange` is for, and `takeChunk` requires both to agree
// before reading the range.
inline constexpr bool bitsCarryPendingNumber(const CSSParserTokenBits& bits)
{
    return bits.type - firstNumericCSSParserTokenType <= lastNumericCSSParserTokenType - firstNumericCSSParserTokenType;
}

// Turns a parked offset into a pointer. Only for an offset into the input: a caller that finds
// cssParserTokenBitsUnescapedValueTag set has to intern the value first and set the three value
// fields itself, since there is no input range to point at.
//
// A token that carries no value comes out with a null value pointer rather than a pointer to
// the start of the input with length zero, matching the constructors, which leave the slot null
// for such a token. Null and empty are not interchangeable: StringView::isNull distinguishes
// them, and toString turns one into a null String and the other into an empty one. The
// unresolved state of a valueless token is exactly offset zero with length zero, and no real
// value can hold it, since a zero-length value only occurs inside a delimited token (`""` or
// `url()`), whose range starts past the opening delimiter. Testing the two fields together
// therefore separates the cases exactly.
//
// `characterSize` is a template parameter, not an argument, because it is a property of the
// tokenization rather than of a token: CSSSwiftTokenSink::create decides it once, from the same
// StringImpl::is8Bit that picks which specialization runs. Specialized, the 8-bit instantiation
// needs no multiply and the 16-bit one folds both doublings into operands it already forms.
template<unsigned characterSize>
inline void resolveValuePointer(CSSParserTokenBits& bits, std::span<const uint8_t> input)
{
    static_assert(characterSize == 1 || characterSize == 2, "the only two StringImpl widths");
    // Read through the union's integer alternative, which is the one Swift wrote.
    auto offset = bits.parkedValueOffset;
    // subspan rather than pointer arithmetic, so that libc++ hardening bounds-checks a value
    // that crossed a language boundary. The two-argument overload, because the extent crosses
    // the boundary too: libc++ checks `offset <= size()` for `subspan(offset)` and additionally
    // `count <= size() - offset` for `subspan(offset, count)`, and `value()` is
    // `StringView { valueDataCharRaw, valueLength, valueIs8Bit }`, so a wrong `valueLength` is
    // an out-of-bounds read for every later reader of the value, not just a mis-parse.
    const void* resolved = input.subspan(offset * characterSize, size_t { bits.valueLength } * characterSize).data();
    bits.valueDataCharRaw = (offset | bits.valueLength) ? resolved : nullptr;
}

} // namespace WebCore
