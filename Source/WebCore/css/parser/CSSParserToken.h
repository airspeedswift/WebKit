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

enum CSSParserTokenType {
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

template<typename CharacterType>
inline void CSSParserToken::updateCharacters(std::span<const CharacterType> characters)
{
    m_bits.valueLength = characters.size();
    m_bits.valueIs8Bit = (sizeof(CharacterType) == 1);
    m_bits.valueDataCharRaw = characters.data();
}

} // namespace WebCore
