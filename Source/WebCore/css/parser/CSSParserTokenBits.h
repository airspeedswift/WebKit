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

// CSSParserToken's storage, in a header that does not include CSSParserToken.h, so that C++ and
// Swift share one definition of the layout. The Swift writers are in
// CSSParserTokenBitsSwift.swift; the accessors C++ calls are here.

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

// The bitfields below occupy 25 bits of one 32-bit allocation unit; CSSParserToken.h asserts the
// object size.
//
// SWIFT_SAFE: while Swift can see the struct the pointer slot holds an offset, which
// resolveValuePointer turns into a pointer only in C++. Swift never forms or dereferences a
// pointer here.
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
    // Whether the union below holds `pendingNumberRange`. That depends on which factory built
    // the token, not on `type`: only `makeNumericTokenBits` sets it.
    unsigned hasParkedNumberRange : 1 { 0 };
    unsigned valueLength { 0 };
    // The value's characters. Until `resolveValuePointer` runs in C++, the slot holds
    // `parkedValueOffset`, an offset into the input or, tagged, into the chunk's unescape buffer.
    // A union so that Swift can write the offset without `unsafe`: under strict memory safety
    // (SE-0458) forming or storing an `UnsafeRawPointer` is unsafe.
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

        // The number's range in the input, until CSSSwiftTokenSink::takeChunk replaces it with
        // `numericValue`. Valid only when `hasParkedNumberRange` is set.
        struct {
            unsigned offset;
            unsigned length;
        } pendingNumberRange;
    };
};


// MARK: - Reading the parked state

// Set when a parked value offset indexes the chunk's unescape buffer rather than the input.
// CSSParserTokenBits has no spare flag bit, so the tag is the offset's top bit.
constexpr unsigned cssParserTokenBitsUnescapedValueTag = 0x80000000u;

// Only meaningful before resolveValuePointer has run.
inline unsigned bitsParkedValueOffset(const CSSParserTokenBits& bits)
{
    return static_cast<unsigned>(bits.parkedValueOffset);
}

// MARK: - The token types
//
// Declared here so that Swift imports the enumeration rather than mirroring it. It stays
// unscoped, so the CSS parser's unqualified `IdentToken` still resolves; Swift spells the
// enumerators as globals, `WebCore.IdentToken`.

// `: uint8_t` so that Swift imports `rawValue` as `UInt8`, the block stack's element type.
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

// Turns a parked input offset into a pointer. A caller that finds
// cssParserTokenBitsUnescapedValueTag set must intern the value and set the value fields itself.
//
// A valueless token gets a null pointer, as the constructors give it, not an empty one:
// StringView::isNull distinguishes them. Its parked state is offset zero with length zero, which
// no real value has, since a zero-length value only occurs inside a delimited token (`""` or
// `url()`) and starts past the opening delimiter.
//
// `characterSize` is a template parameter because it is fixed for the whole tokenization, so
// neither instantiation needs a multiply.
template<unsigned characterSize>
inline void resolveValuePointer(CSSParserTokenBits& bits, std::span<const uint8_t> input)
{
    static_assert(characterSize == 1 || characterSize == 2, "the only two StringImpl widths");
    auto offset = bits.parkedValueOffset;
    // subspan so that libc++ hardening checks both the offset and the length Swift supplied;
    // value() reads valueLength characters from the result.
    const void* resolved = input.subspan(offset * characterSize, size_t { bits.valueLength } * characterSize).data();
    bits.valueDataCharRaw = (offset | bits.valueLength) ? resolved : nullptr;
}

} // namespace WebCore
