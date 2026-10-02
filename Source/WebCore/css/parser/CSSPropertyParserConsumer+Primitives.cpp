/*
 * Copyright (C) 2024 Apple Inc. All rights reserved.
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
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#include "config.h"
#include "CSSPropertyParserConsumer+Primitives.h"

#include "CSSParserTokenRange.h"
#include "CSSPropertyParserOptions.h"
#if USE(SWIFT_CSS)
#include "CSSKeywordValue.h"
#include "CSSPropertyParserConsumer+CSSPrimitiveValueResolver.h"
#include "CSSValuePair.h"
#include "CSSValuePool.h"
#endif

namespace WebCore {
namespace CSSPropertyParserHelpers {

bool consumeCommaIncludingWhitespace(CSSParserTokenRange& range)
{
    auto& value = range.peek();
    if (value.type() != CommaToken)
        return false;
    range.consumeIncludingWhitespace();
    return true;
}

bool consumeSlashIncludingWhitespace(CSSParserTokenRange& range)
{
    auto& value = range.peek();
    if (value.type() != DelimiterToken || value.delimiter() != '/')
        return false;
    range.consumeIncludingWhitespace();
    return true;
}

CSSParserTokenRange consumeFunction(CSSParserTokenRange& range)
{
    ASSERT(range.peek().type() == FunctionToken);
    CSSParserTokenRange contents = range.consumeBlock();
    range.consumeWhitespace();
    contents.consumeWhitespace();
    return contents;
}

std::optional<CSSParserTokenRange> consumeArgument(CSSParserTokenRange& range, unsigned index)
{
    if (range.atEnd())
        return std::nullopt;

    if (index) {
        ASSERT(range.peek().type() == CommaToken);
        range.consume();
    }

    range.consumeWhitespace();

    auto argumentStart = range;
    while (!range.atEnd()) {
        if (range.peek().type() == CommaToken)
            break;

        if (range.peek().getBlockType() == CSSParserToken::BlockStart) {
            range.consumeBlock();
            continue;
        }

        range.consume();
    }

    return argumentStart.rangeUntil(range);
}

} // namespace CSSPropertyParserHelpers
} // namespace WebCore

#if USE(SWIFT_CSS)
namespace WebCore {

uint32_t CSSPropertyParserSwiftCursor::tokenCount() const
{
    return m_range.size();
}

CSSParserTokenBits CSSPropertyParserSwiftCursor::bits(uint32_t i) const
{
    return m_range.peek(i).bits();
}

uint16_t CSSPropertyParserSwiftCursor::keywordId(uint32_t i) const
{
    return m_range.peek(i).id();
}

uint32_t CSSPropertyParserSwiftCursor::nextIndex() const
{
    return m_nextIndex;
}

void CSSPropertyParserSwiftCursor::setNextIndex(uint32_t i) const
{
    m_nextIndex = i;
}

static_assert(sizeof(CSSPropertyParserSwiftCursor) == 3 * sizeof(void*));

CSSValue& CSSPropertyParserSwiftCursor::keyword(uint16_t id) const
{
    return CSSKeywordValue::create(static_cast<CSSValueID>(id)).leakRef();
}

CSSValue& CSSPropertyParserSwiftCursor::lengthPercentage(double value, uint8_t unit) const
{
    return CSSPrimitiveValue::create(value, CSS::toCSSUnitType(static_cast<CSS::LengthPercentageUnit>(unit))).leakRef();
}

CSSValue& CSSPropertyParserSwiftCursor::pair(CSSValue& first, CSSValue& second, bool coalescing) const
{
    return (coalescing ? CSSValuePair::create(Ref { first }, Ref { second }) : CSSValuePair::createNoncoalescing(Ref { first }, Ref { second })).leakRef();
}

CSSValue* CSSPropertyParserSwiftCursor::lengthPercentageNonnegativeAt(uint32_t i) const
{
    auto range = CSSParserTokenRange { m_range.span().subspan(i) };
    auto value = CSSPropertyParserHelpers::CSSPrimitiveValueResolver<CSS::LengthPercentage<CSS::Nonnegative>>::consumeAndResolve(range, m_state);
    m_nextIndex = range.begin() - m_range.begin();
    return value.leakRef();
}

} // namespace WebCore
#endif // USE(SWIFT_CSS)
