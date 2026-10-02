// Copyright 2014 The Chromium Authors. All rights reserved.
// Copyright (C) 2016 Apple Inc. All rights reserved.
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

#include <WebCore/CSSParserToken.h>
#include <WebCore/CSSTokenizer.h>
#include <wtf/Forward.h>
#include <wtf/SwiftBridging.h>
#include <wtf/text/ParsingUtilities.h>

namespace WebCore {

class StyleSheetContents;
namespace CSS {
struct PropertyParserState;
}

// A CSSParserTokenRange is an iterator over a subrange of a vector of CSSParserTokens.
// Accessing outside of the range will return an endless stream of EOF tokens.
// This class refers to half-open intervals [first, last).
class CSSParserTokenRange {
public:
    CSSParserTokenRange() = default;

    CSSParserTokenRange(std::span<const CSSParserToken> span)
        : m_tokens(span)
    { }

    template<size_t inlineBuffer>
    CSSParserTokenRange(const Vector<CSSParserToken, inlineBuffer>& vector LIFETIME_BOUND)
        : CSSParserTokenRange(vector.span())
    { }

    CSSParserTokenRange rangeUntil(const CSSParserTokenRange& end) const { return span().first(end.begin() - begin()); }

    bool atEnd() const { return m_tokens.empty(); }

    const CSSParserToken* begin() const LIFETIME_BOUND { return std::to_address(m_tokens.begin()); }
    const CSSParserToken* end() const LIFETIME_BOUND { return std::to_address(m_tokens.end()); }

    size_t size() const { return m_tokens.size(); }

    const CSSParserToken& peek(size_t offset = 0) const LIFETIME_BOUND
    {
        if (offset < m_tokens.size())
            return m_tokens[offset];
        return eofToken();
    }

    const CSSParserToken& consume() LIFETIME_BOUND
    {
        if (m_tokens.empty())
            return eofToken();
        return WTF::consume(m_tokens);
    }

    const CSSParserToken& consumeIncludingWhitespace() LIFETIME_BOUND
    {
        auto& result = consume();
        consumeWhitespace();
        return result;
    }

    // The returned range doesn't include the brackets
    CSSParserTokenRange NODELETE consumeBlock();
    CSSParserTokenRange consumeBlockCheckingForEditability(StyleSheetContents*);

    void NODELETE consumeComponentValue();

    // https://drafts.csswg.org/css-syntax-3/#typedef-any-value
    bool NODELETE consumeAnyValue();

    void consumeWhitespace()
    {
        size_t i = 0;
        for (; i < m_tokens.size() && CSSTokenizer::isWhitespace(m_tokens[i].type()); ++i) { }
        skip(m_tokens, i);
    }

    void NODELETE trimTrailingWhitespace();
    const CSSParserToken& NODELETE consumeLast() LIFETIME_BOUND;

    CSSParserTokenRange consumeAll() { return { std::exchange(m_tokens, std::span<const CSSParserToken> { }) }; }

    String serialize(CSSParserToken::SerializationMode = CSSParserToken::SerializationMode::Normal) const;

    std::span<const CSSParserToken> span() const LIFETIME_BOUND { return m_tokens; }

    static CSSParserToken& NODELETE eofToken();

private:
    std::span<const CSSParserToken> m_tokens;
};

// A Swift property parser reads `range` by index and creates its values through this. Swift sees the
// tokens one at a time because `peek` returns a reference into the range, which it cannot import. The
// values are created here because a `CSSValue` subclass does not import as a subclass of `CSSValue`
// in Swift, so Swift could not pass a `CSSPrimitiveValue` where a `CSSValue` is wanted.
// `SWIFT_SAFE` holds because a cursor lives on the C++ stack for the one Swift call that borrows it.
class SWIFT_SAFE CSSPropertyParserSwiftCursor {
public:
    uint32_t tokenCount() const;
    CSSParserTokenBits bits(uint32_t i) const;
    uint16_t keywordId(uint32_t i) const;

    CSSValue& keyword(uint16_t) const SWIFT_RETURNS_RETAINED;
    CSSValue& lengthPercentage(double value, uint8_t unit) const SWIFT_RETURNS_RETAINED;
    CSSValue& pair(CSSValue&, CSSValue&, bool coalescing) const SWIFT_RETURNS_RETAINED;
    // A `<length-percentage>` other than a plain numeric token (calc(), anchor(), ...) starting at
    // token `i`, through the `MetaResolver`. `nextIndex()` is the token after it.
    CSSValue* lengthPercentageNonnegativeAt(uint32_t i) const SWIFT_RETURNS_RETAINED;
    uint32_t nextIndex() const;
    // The cursor is passed to Swift by value, so the index lives in the caller's frame.
    void setNextIndex(uint32_t) const;

#if !defined(__swift__)
    CSSPropertyParserSwiftCursor(const CSSParserTokenRange& range, CSS::PropertyParserState& state, uint32_t& nextIndex)
        : m_range(range)
        , m_state(state)
        , m_nextIndex(nextIndex)
    {
    }

private:
    const CSSParserTokenRange& m_range;
    CSS::PropertyParserState& m_state;
    uint32_t& m_nextIndex;
#else
    const void* m_rangeStandIn;
    void* m_stateStandIn;
    void* m_nextIndexStandIn;
#endif
};

} // namespace WebCore
