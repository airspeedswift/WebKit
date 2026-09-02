// Copyright 2014 The Chromium Authors. All rights reserved.
// Copyright (C) 2016-2024 Apple Inc. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are
// met:
//
//    * Redistributions of source code must retain the above copyright
// notice, this list of conditions and the following disclaimer.
//    * Redistributions in binary form must reproduce the above
// copyright notice, this list of conditions and the following disclaimer
// in the documentation and/or other materials provided with the
// distribution.
//    * Neither the name of Google Inc. nor the names of its
// contributors may be used to endorse or promote products derived from
// this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
// "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
// LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
// A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
// OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
// SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
// LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
// DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
// THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

#pragma once

#include <WebCore/CSSParserTokenBits.h>

#include <WebCore/CSSPrimitiveValue.h>
#include <wtf/text/StringView.h>

namespace WebCore {


// And the predicate itself, over every token type, because a range check written the wrong way
// round still compiles and still returns a bool. This walks the whole enumeration and compares
// against the three-way test the range check stands in for, so it is a proof rather than a
// sample, and it costs nothing at runtime.
static_assert([] {
    auto bitsWithType = [](unsigned type) {
        CSSParserTokenBits bits;
        bits.type = type;
        return bits;
    };
    for (unsigned type = 0; type < static_cast<unsigned>(numberOfCSSParserTokenTypes); ++type) {
        bool isNumeric = type == NumberToken || type == PercentageToken || type == DimensionToken;
        if (bitsCarryPendingNumber(bitsWithType(type)) != isNumeric)
            return false;
    }
    return true;
}());


DECLARE_ALLOCATOR_WITH_HEAP_IDENTIFIER(CSSParserToken);
class CSSParserToken {
    WTF_DEPRECATED_MAKE_FAST_ALLOCATED_WITH_HEAP_IDENTIFIER(CSSParserToken, CSSParserToken);
public:
    enum BlockType {
        NotBlock,
        BlockStart,
        BlockEnd,
    };

    CSSParserToken(CSSParserTokenType, BlockType = NotBlock);
    CSSParserToken(CSSParserTokenType, StringView, BlockType = NotBlock);

    explicit CSSParserToken(unsigned nonNewlineWhitespaceCount); // NonNewlineWhitespaceToken
    CSSParserToken(CSSParserTokenType, char16_t); // for DelimiterToken
    CSSParserToken(double, NumericValueType, NumericSign, StringView originalText); // for NumberToken

    CSSParserToken(HashTokenType, StringView);

    static CSSUnitType NODELETE stringToUnitType(StringView);

    bool operator==(const CSSParserToken& other) const;

    // Converts NumberToken to DimensionToken.
    void convertToDimensionWithUnit(CSSUnitType);
    void NODELETE convertToDimensionWithUnit(StringView);

    // Converts NumberToken to PercentageToken.
    void NODELETE convertToPercentage();

    CSSParserTokenType type() const { return static_cast<CSSParserTokenType>(m_bits.type); }
    StringView value() const { return { m_bits.valueDataCharRaw, m_bits.valueLength, m_bits.valueIs8Bit }; }

    char16_t NODELETE delimiter() const;
    NumericSign NODELETE numericSign() const;
    NumericValueType NODELETE numericValueType() const;
    double NODELETE numericValue() const;
    StringView NODELETE originalText() const;
    HashTokenType getHashTokenType() const { ASSERT(m_bits.type == HashToken); return m_bits.hashTokenType; }
    BlockType getBlockType() const { return static_cast<BlockType>(m_bits.blockType); }
    CSSUnitType unitType() const { return static_cast<CSSUnitType>(m_bits.unit); }
    StringView NODELETE unitString() const;
    CSSValueID id() const;
    CSSValueID functionId() const;

    bool NODELETE hasStringBacking() const;
    bool tryUseStringLiteralBacking();
    bool isBackedByStringLiteral() const { return m_bits.isBackedByStringLiteral; }

    CSSPropertyID parseAsCSSPropertyID() const;

    enum class SerializationMode : bool {
        Normal,
        // "Specified values of custom properties must be serialized exactly as specified by the author.
        // Simplifications that might occur in other properties, such as dropping comments, normalizing whitespace,
        // reserializing numeric tokens from their value, etc., must not occur."
        // https://drafts.csswg.org/css-variables-2/#serializing-custom-props
        CustomProperty
    };
    void serialize(StringBuilder&, const CSSParserToken* nextToken = nullptr, SerializationMode = SerializationMode::Normal) const;

    template<typename CharacterType>
    void updateCharacters(std::span<const CharacterType> characters);

private:
    // Adopts storage the island has already finished writing, so a chunk of tokens can be
    // appended in bulk without being taken apart and reassembled through the constructors above.
    // The bits must already have been through resolveValuePointer: while Swift holds them the
    // pointer slot carries an offset, and nothing here can tell the difference.
    //
    // Private, with exactly one friend, because that precondition cannot be put in the type. The
    // design this replaced could not get it wrong -- the island emitted a *different* struct with
    // a `uint32_t valueStart`, so an offset was never a candidate for dereference -- and the one
    // thing that stood in for that here was this comment. Naming CSSSwiftTokenSink narrows the
    // reachable callers to the resolve loop in CSSSwiftTokenSink::takeChunk, which is the only
    // code that has run resolveValuePointer. It has to be `tryAppend(CSSParserToken { bits })`
    // there rather than `tryConstructAndAppend(bits)`: Vector's in-place construction happens
    // inside Vector, where the access check is made in Vector's context, so a private constructor
    // and friendship would have had to name Vector and would have widened rather than narrowed.
    // Ledger R1.
    friend class CSSSwiftTokenSink;
    explicit CSSParserToken(CSSParserTokenBits bits)
        : m_bits(bits)
    {
    }

    void initValueFromStringView(StringView string)
    {
        m_bits.valueLength = string.length();
        m_bits.valueIs8Bit = string.is8Bit();
        m_bits.valueDataCharRaw = string.rawCharacters();
        m_bits.isBackedByStringLiteral = false;
    }
    CSSValueID identOrFunctionId() const;

    CSSParserTokenBits m_bits;
};

// The token is the CSS parser's bulk storage -- one per token in every stylesheet's m_tokens --
// so its size is a cache-residency property rather than an implementation detail. Asserted here
// because R2's union discriminant went into CSSParserTokenBits' spare bitfield padding, and "the
// bitfields sum to 24 bits so there are eight free in that allocation unit" is a layout claim, not
// something to take on trust. cssprobe/probes/bits-packing-probe.cpp is the standalone version.
static_assert(sizeof(CSSParserToken) == 24);
static_assert(alignof(CSSParserToken) == 8);
static_assert(sizeof(CSSParserTokenBits) == sizeof(CSSParserToken));

template<typename CharacterType>
inline void CSSParserToken::updateCharacters(std::span<const CharacterType> characters)
{
    m_bits.valueLength = characters.size();
    m_bits.valueIs8Bit = (sizeof(CharacterType) == 1);
    m_bits.valueDataCharRaw = characters.data();
}

} // namespace WebCore
