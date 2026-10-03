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
#include "CSSPropertyParserConsumer+AngleDefinitions.h"
#include "CSSPropertyParserConsumer+CSSPrimitiveValueResolver.h"
#include "CSSPropertyParserConsumer+LengthDefinitions.h"
#include "CSSPropertyParserConsumer+NumberDefinitions.h"
#include "CSSPropertyParserConsumer+Percentage.h"
#include "WebCoreSwiftBoundaryTypes.h"
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

uint16_t CSSPropertyParserSwiftCursor::keywordId(uint32_t i) const
{
    auto& token = m_range->peek(i);
    return token.type() == FunctionToken ? token.functionId() : token.id();
}

CSSPrimitiveValue* CSSPropertyParserSwiftCursor::primitiveAt(uint32_t i, uint32_t end, CSSPropertyParserSwiftPrimitive primitive) const
{
    using namespace CSSPropertyParserHelpers;
    using enum CSSPropertyParserSwiftPrimitive;
    auto range = CSSParserTokenRange { m_range->span().subspan(i, end - i) };
    RefPtr<CSSPrimitiveValue> value;
    switch (primitive) {
    case LengthPercentageNonnegative: value = CSSPrimitiveValueResolver<CSS::LengthPercentage<CSS::Nonnegative>>::consumeAndResolve(range, *m_state); break;
    case LengthPercentage: value = CSSPrimitiveValueResolver<CSS::LengthPercentage<>>::consumeAndResolve(range, *m_state); break;
    case Length: value = CSSPrimitiveValueResolver<CSS::Length<>>::consumeAndResolve(range, *m_state); break;
    case Number: value = CSSPrimitiveValueResolver<CSS::Number<>>::consumeAndResolve(range, *m_state); break;
    case Angle: case AngleOrUnitlessZero: value = CSSPrimitiveValueResolver<CSS::Angle<>>::consumeAndResolve(range, *m_state, { .unitlessZeroAngle = primitive == Angle ? UnitlessZeroQuirk::Forbid : UnitlessZeroQuirk::Allow }); break;
    case PercentageDividedBy100OrNumber: value = consumePercentageDividedBy100OrNumber(range, *m_state); break;
    case StrokeDashLengthPercentage: value = CSSPrimitiveValueResolver<CSS::LengthPercentage<CSS::Nonnegative>>::consumeAndResolve(range, *m_state, { .overrideParserMode = HTMLStandardMode, .unitlessZeroLength = UnitlessZeroQuirk::Forbid }); break;
    case NumberNonnegative: value = CSSPrimitiveValueResolver<CSS::Number<CSS::Nonnegative>>::consumeAndResolve(range, *m_state); break;
    }
    *m_nextIndex = range.begin() - m_range->begin();
    return value.leakRef();
}

RefPtr<CSSValue> CSSPropertyParserHelpers::consumePropertyInSwift(CSSParserTokenRange& range, CSS::PropertyParserState& state, uint8_t consumer, CSSPropertyParserOptions options)
{
    auto mode = options.overrideParserMode.value_or(state.context.mode);
    auto quirkyAngle = mode == HTMLQuirksMode && CSSProperty::acceptsQuirkyAngle(state.currentProperty) ? CSSNumericConsumerSwiftQuirkyAngle : 0;
    uint32_t nextIndex = 0;
    RefPtr value = adoptRef(cssConsumePropertySwift(CSSPropertyParserSwiftCursor { range, state, nextIndex }, consumer, mode, swiftNumericConsumerFlags(true, mode, state, options) | quirkyAngle));
    if (value)
        range = range.span().subspan(nextIndex);
    return value;
}

} // namespace WebCore
#endif // USE(SWIFT_CSS)
