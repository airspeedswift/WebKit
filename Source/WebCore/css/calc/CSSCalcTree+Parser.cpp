/*
 * Copyright (C) 2024-2026 Samuel Weinig <sam@webkit.org>
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
#include "CSSCalcTree+Parser.h"

#include "AnchorPositionEvaluator.h"
#include "CSSCalcOperator.h"
#include "CSSCalcSwiftTypes.h"
#include "CSSCalcSymbolTable.h"
#include "CSSCalcTree+Serialization.h"
#include "CSSCalcTree+Simplification.h"
#include "CSSCalcTree.h"
#include "CSSParserContext.h"
#include "CSSParserIdioms.h"
#include "CSSParserTokenRange.h"
#include "CSSParserTokenRangeGuard.h"
#include "CSSPrimitiveNumericCategory.h"
#include "CSSPropertyParserConsumer+Ident.h"
#include "CSSPropertyParserConsumer+MetaConsumer.h"
#include "CSSPropertyParserConsumer+NumberDefinitions.h"
#include "CSSPropertyParserConsumer+PercentageDefinitions.h"
#include "CSSPropertyParserConsumer+Primitives.h"
#include "CSSPropertyParserState.h"
#include "CSSPropertyParsing.h"
#include "CSSRandomKeyParser.h"
#include "CSSSerializationContext.h"
#include "CSSUnits.h"
#include "Logging.h"
#include <numbers>
#include <wtf/SortedArrayMap.h>

namespace WebCore {
namespace CSSCalc {

// MARK: - Constants

static constexpr int maxExpressionDepth = 100;

static std::optional<std::pair<Number, Type>> lookupConstantNumber(CSSValueID symbol)
{
    static constexpr SortedArrayMap constantMap { WTF::toArray<std::pair<CSSValueID, double>>({
        { CSSValueE,                     std::numbers::e                          },
        { CSSValuePi,                    std::numbers::pi                         },
        { CSSValueInfinity,              std::numeric_limits<double>::infinity()  },
        { CSSValueNegativeInfinity, -1 * std::numeric_limits<double>::infinity()  },
        { CSSValueNaN,                   std::numeric_limits<double>::quiet_NaN() },
    }) };
    if (auto value = constantMap.tryGet(symbol))
        return std::make_pair(Number { .value = *value }, Type { });
    return std::nullopt;
}

// MARK: - Parser State

namespace {

enum class ParseStatus { Ok, TooDeep };

struct ParserState {
    // CSS::PropertyParserState used to initiate the parse.
    CSS::PropertyParserState& propertyParserState;

    // ParserOptions used to initiate the parse.
    const ParserOptions& parserOptions;

    // SimplificationOptions used to initiate the parse, if provided.
    const SimplificationOptions* simplificationOptions;

    // Tracks whether the parse tree contains any non-canonical dimension units that require conversion data (e.g. em, vh, etc.).
    bool requiresConversionData = false;
};

} // namespace (anonymous)

static ParseStatus NODELETE checkDepth(int depth)
{
    if (depth > maxExpressionDepth)
        return ParseStatus::TooDeep;
    return ParseStatus::Ok;
}

// MARK: - Parser

struct TypedChild {
    Child child;
    Type type;
};

// Build `op` into a `Child`, first trying to fold it away if this parse simplifies eagerly.
//
// EIGHTEEN BYTE-IDENTICAL COPIES OF THIS BLOCK used to sit inline at the eighteen sites below, and
// collapsing them is not tidying: each copy was a call to `simplify(Op&, ...)`, i.e. to the C++
// simplifier, from outside `copyAndSimplify`. That is one of the three things
// CSSCalcTree+Simplification.h names as keeping the C++ simplifier reachable "no matter what", and
// it is why `CSS_CALC_CPP_SIMPLIFIER_COMPILED_IN` -- the build mode that answers "does anything
// still need the C++ simplifier" -- could not be 0 while the parser existed. One call site means
// one `#if`, and the mode becomes answerable for the parser too.
//
// WITH THE C++ SIMPLIFIER COMPILED OUT this returns the node unsimplified, and the whole-tree
// `copyAndSimplify` at the end of `parseAndSimplify` -- `ParseSimplification::Terminal`, which the
// Swift island serves at 41 of 41 alternatives and 0 declines -- is what simplifies it. `Eager` is
// then not a selectable mode; the `static_assert` below is what says so at build time rather than
// letting it become a silently unsimplified computed value.
template<typename Op> static Child makeSimplifiedChild(Op&& op, Type type, ParserState& state)
{
#if CSS_CALC_CPP_SIMPLIFIER_COMPILED_IN
    if (auto* simplificationOptions = state.simplificationOptions) {
        if (auto replacement = simplify(op, *simplificationOptions))
            return WTF::move(*replacement);
    }
#else
    UNUSED_PARAM(state);
#endif
    return makeChild(WTF::move(op), type);
}

// The same thing for the seventeen sites that return the node's type alongside it. The type is the
// SAME on both arms in the original -- a folded replacement was returned with `*outputType`, exactly
// as an unfolded `makeChild` was -- so carrying it once here is behaviour-preserving by inspection,
// not by argument.
template<typename Op> static TypedChild makeSimplifiedTypedChild(Op&& op, Type type, ParserState& state)
{
    return TypedChild { makeSimplifiedChild(WTF::move(op), type, state), type };
}

// A BUILD WITH NO C++ SIMPLIFIER HAS NO EAGER ARM, because `Eager` IS the C++ simplifier -- called
// once per operation during the parse instead of once at the end. So `defaultParseSimplification`
// has to be `Terminal` in that build, and the only other way to select `Eager` -- the differential
// passing it explicitly -- is already `#error`-ed out of this mode (CSSCalcTree+Simplification.h
// refuses WK_USE_SWIFT_CSS_CALC_SIMPLIFICATION_NO_FALLBACK together with the bridge).
//
// Stated as a build failure rather than a runtime check because it is a build configuration, and
// because the failure mode it replaces is the worst kind this file has: not a decline, not a crash,
// but a correctly-shaped tree that was never simplified.
static_assert(CSS_CALC_CPP_SIMPLIFIER_COMPILED_IN || defaultParseSimplification != ParseSimplification::Eager,
    "WK_USE_SWIFT_CSS_CALC_SIMPLIFICATION_NO_FALLBACK=YES compiles out the parser's eager simplification, so defaultParseSimplification must not be Eager");

static std::optional<TypedChild> parseCalcFunction(CSSParserTokenRange&, CSSValueID functionID, int depth, ParserState&);
static std::optional<TypedChild> parseCalcSum(CSSParserTokenRange&, int depth, ParserState&);
static std::optional<TypedChild> parseCalcProduct(CSSParserTokenRange&, int depth, ParserState&);
static std::optional<TypedChild> parseCalcValue(CSSParserTokenRange&, int depth, ParserState&);
static std::optional<TypedChild> parseCalcKeyword(const CSSParserToken&, ParserState&);
static std::optional<TypedChild> parseCalcNumber(const CSSParserToken&, ParserState&);
static std::optional<TypedChild> parseCalcPercentage(const CSSParserToken&, ParserState&);
static std::optional<TypedChild> parseCalcDimension(const CSSParserToken&, ParserState&);

std::optional<Tree> parseAndSimplify(CSSParserTokenRange& range, CSS::PropertyParserState& propertyParserState, const ParserOptions& parserOptions, const SimplificationOptions& simplificationOptions, ParseSimplification parseSimplification)
{
    auto function = range.peek().functionId();
    if (!isCalcFunction(function))
        return std::nullopt;

    auto tokens = CSSPropertyParserHelpers::consumeFunction(range);

    LOG_WITH_STREAM(Calc, stream << "Starting top level parse/simplification of function " << nameLiteralForSerialization(function) << "(" << tokens.serialize() << ") with expected type " << parserOptions.category);

    // -- Parsing --

    ParserState state {
        .propertyParserState = propertyParserState,
        .parserOptions = parserOptions,
        .simplificationOptions = &simplificationOptions
    };

    // The eighteen per-operation sites below are already written as
    // `if (auto* simplificationOptions = state.simplificationOptions)`, so nulling the pointer is
    // the whole of `Terminal` and `None` on the way in. No site needs to know which mode it is in,
    // and `consumeAnchor`'s `percentageState` shows the parser already runs this way.
    if (parseSimplification != ParseSimplification::Eager)
        state.simplificationOptions = nullptr;

    auto root = parseCalcFunction(tokens, function, 0, state);

    if (!root || !tokens.atEnd()) {
        LOG_WITH_STREAM(Calc, stream << "Failed top level parse/simplification of function '" << nameLiteralForSerialization(function) << "'");
        return std::nullopt;
    }

    // -- Type Checking --

    if (!root->type.matches(parserOptions.category)) {
        LOG_WITH_STREAM(Calc, stream << "Failed top level parse/simplification due to type check for function '" << nameLiteralForSerialization(function) << "', type=" << root->type << ", expected category=" << parserOptions.category);

        return std::nullopt;
    }

    auto result = Tree {
        .root = WTF::move(root->child),
        .type = root->type,
        .stage = CSSCalc::Stage::Specified,
        .requiresConversionData = state.requiresConversionData,
    };

    LOG_WITH_STREAM(Calc, stream << "Completed top level parse/simplification for function '" << nameLiteralForSerialization(function) << "': " << serializationForCSS(result, { parserOptions.range, CSS::defaultSerializationContext() }) << ", type: " << getType(result.root) << ", category=" << parserOptions.category << ", requires-conversion-data: " << result.requiresConversionData);

    // `Terminal` is `None` plus this one call, which is why the two are one enumerator apart rather
    // than two code paths. `copyAndSimplify(Tree)` takes `Simplifier = defaultSimplifier`, so this is
    // also the line that puts the Swift island on the parse path when the island is the default.
    // Placed after the log so that the log still describes the parse, as it always has.
    if (parseSimplification == ParseSimplification::Terminal)
        return copyAndSimplify(result, simplificationOptions);

    return result;
}

bool isCalcFunction(CSSValueID functionId)
{
    switch (functionId) {
    case CSSValueCalc:
    case CSSValueCalcMix:
    case CSSValueWebkitCalc:
    case CSSValueMin:
    case CSSValueMax:
    case CSSValueClamp:
    case CSSValuePow:
    case CSSValueSqrt:
    case CSSValueHypot:
    case CSSValueSin:
    case CSSValueCos:
    case CSSValueTan:
    case CSSValueExp:
    case CSSValueLog:
    case CSSValueAsin:
    case CSSValueAcos:
    case CSSValueAtan:
    case CSSValueAtan2:
    case CSSValueAbs:
    case CSSValueSign:
    case CSSValueRound:
    case CSSValueMod:
    case CSSValueRem:
    case CSSValueProgress:
    case CSSValueRandom:
    case CSSValueSiblingCount:
    case CSSValueSiblingIndex:
    case CSSValueAnchor:
    case CSSValueAnchorSize:
        return true;
    default:
        return false;
    }
    return false;
}

template<typename Op> static std::optional<TypedChild> consumeZeroArguments(CSSParserTokenRange& tokens, int, ParserState&)
{
    if (!tokens.atEnd()) {
        LOG_WITH_STREAM(Calc, stream << "Failed '" << nameLiteralForSerialization(Op::id) << "' function - extraneous tokens found");
        return std::nullopt;
    }

    auto child = Op { };
    auto type = getType(child);

    return TypedChild { makeChild(WTF::move(child)), type };
}

template<typename Op> static std::optional<TypedChild> consumeExactlyOneArgument(CSSParserTokenRange& tokens, int depth, ParserState& state)
{
    auto sum = parseCalcSum(tokens, depth, state);
    if (!sum) {
        LOG_WITH_STREAM(Calc, stream << "Failed '" << nameLiteralForSerialization(Op::id) << "' function - argument failed to parse");
        return std::nullopt;
    }

    if (!tokens.atEnd()) {
        LOG_WITH_STREAM(Calc, stream << "Failed '" << nameLiteralForSerialization(Op::id) << "' function - extraneous tokens found");
        return std::nullopt;
    }

    if (!validateType<Op::input>(sum->type)) {
        LOG_WITH_STREAM(Calc, stream << "Failed '" << nameLiteralForSerialization(Op::id) << "' function - argument has invalid type: " << sum->type);
        return std::nullopt;
    }

    auto outputType = transformType<Op::output>(sum->type);
    if (!outputType) {
        LOG_WITH_STREAM(Calc, stream << "Failed '" << nameLiteralForSerialization(Op::id) << "' function - output transform failed for type: " << sum->type);
        return std::nullopt;
    }

    Op op { WTF::move(sum->child) };

    // Sin, Cos, and Tan accept either a <number> (already in radians) or an <angle> (in the
    // canonical unit of degrees). Wrap angle arguments in a Deg2Rad node so that evaluation no
    // longer has to inspect types to decide whether to convert — the conversion is explicit in
    // the tree. Simplify the Deg2Rad eagerly so that fully-resolved angles collapse into a Number
    // (which then lets the trig simplification below reduce the whole expression to a Number).
    if constexpr (std::same_as<Op, Sin> || std::same_as<Op, Cos> || std::same_as<Op, Tan>) {
        if (sum->type.template matchesAny<Type::Match::Angle>({ .allowsPercentHint = true })) {
            Deg2Rad conversion { .angle = WTF::move(op.a) };
            op.a = makeSimplifiedChild(WTF::move(conversion), Type { }, state);
        }
    }

    return makeSimplifiedTypedChild(WTF::move(op), *outputType, state);
}

template<typename Op> static std::optional<TypedChild> consumeOneOrMoreArguments(CSSParserTokenRange& tokens, int depth, ParserState& state)
{
    std::optional<Type> mergedType;
    Vector<Child> children;

    bool requireComma = false;
    unsigned argumentCount = 0;

    while (!tokens.atEnd()) {
        tokens.consumeWhitespace();
        if (requireComma && !CSSPropertyParserHelpers::consumeCommaIncludingWhitespace(tokens)) {
            LOG_WITH_STREAM(Calc, stream << "Failed '" << nameLiteralForSerialization(Op::id) << "' function - missing comma");
            return std::nullopt;
        }

        auto sum = parseCalcSum(tokens, depth, state);
        if (!sum) {
            LOG_WITH_STREAM(Calc, stream << "Failed '" << nameLiteralForSerialization(Op::id) << "' function - failed parse of argument #" << argumentCount);
            return std::nullopt;
        }

        if (!validateType<Op::input>(sum->type)) {
            LOG_WITH_STREAM(Calc, stream << "Failed '" << nameLiteralForSerialization(Op::id) << "' function - argument #" << argumentCount << " has invalid type: " << sum->type);
            return std::nullopt;
        }

        if (!mergedType)
            mergedType = sum->type;
        else {
            auto mergeResult = mergeTypes<Op::merge>(*mergedType, sum->type);
            if (!mergeResult) {
                LOG_WITH_STREAM(Calc, stream << "Failed '" << nameLiteralForSerialization(Op::id) << "' function - argument #" << argumentCount << " failed to merge type with other arguments: existing type " << *mergedType << " & argument type " << sum->type);
                return std::nullopt;
            }
            mergedType = *mergeResult;
        }

        ++argumentCount;
        children.append(WTF::move(sum->child));
        requireComma = true;
    }

    if (argumentCount < 1) {
        LOG_WITH_STREAM(Calc, stream << "Failed '" << nameLiteralForSerialization(Op::id) << "' function - no arguments found");
        return std::nullopt;
    }

    auto outputType = transformType<Op::output>(*mergedType);
    if (!outputType) {
        LOG_WITH_STREAM(Calc, stream << "Failed '" << nameLiteralForSerialization(Op::id) << "' function - output transform failed for type: " << *mergedType);
        return std::nullopt;
    }

    Op op { WTF::move(children) };

    return makeSimplifiedTypedChild(WTF::move(op), *outputType, state);
}

template<typename Op> static std::optional<TypedChild> consumeExactlyTwoArguments(CSSParserTokenRange& tokens, int depth, ParserState& state)
{
    auto sumA = parseCalcSum(tokens, depth, state);
    if (!sumA) {
        LOG_WITH_STREAM(Calc, stream << "Failed '" << nameLiteralForSerialization(Op::id) << "' function - failed parse of argument #1");
        return std::nullopt;
    }

    if (!validateType<Op::input>(sumA->type)) {
        LOG_WITH_STREAM(Calc, stream << "Failed '" << nameLiteralForSerialization(Op::id) << "' function - argument #1 has invalid type: " << sumA->type);
        return std::nullopt;
    }

    if (!CSSPropertyParserHelpers::consumeCommaIncludingWhitespace(tokens)) {
        LOG_WITH_STREAM(Calc, stream << "Failed '" << nameLiteralForSerialization(Op::id) << "' function - missing comma");
        return std::nullopt;
    }

    auto sumB = parseCalcSum(tokens, depth, state);
    if (!sumB) {
        LOG_WITH_STREAM(Calc, stream << "Failed '" << nameLiteralForSerialization(Op::id) << "' function - failed parse of argument #2");
        return std::nullopt;
    }

    if (!tokens.atEnd()) {
        LOG_WITH_STREAM(Calc, stream << "Failed '" << nameLiteralForSerialization(Op::id) << "' function - extraneous tokens found");
        return std::nullopt;
    }

    if (!validateType<Op::input>(sumB->type)) {
        LOG_WITH_STREAM(Calc, stream << "Failed '" << nameLiteralForSerialization(Op::id) << "' function - argument #2 has invalid type:  " << sumB->type);
        return std::nullopt;
    }

    auto mergedType = mergeTypes<Op::merge>(sumA->type, sumB->type);
    if (!mergedType) {
        LOG_WITH_STREAM(Calc, stream << "Failed '" << nameLiteralForSerialization(Op::id) << "' function - failed to merge type with other arguments: argument #1 type " << sumA->type << " & argument #2 type" << sumB->type);
        return std::nullopt;
    }

    auto outputType = transformType<Op::output>(*mergedType);
    if (!outputType) {
        LOG_WITH_STREAM(Calc, stream << "Failed '" << nameLiteralForSerialization(Op::id) << "' function - output transform failed for type: " << *mergedType);
        return std::nullopt;
    }

    Op op { WTF::move(sumA->child), WTF::move(sumB->child) };

    return makeSimplifiedTypedChild(WTF::move(op), *outputType, state);
}

template<typename Op> static std::optional<TypedChild> consumeOneOrTwoArguments(CSSParserTokenRange& tokens, int depth, ParserState& state)
{
    auto sumA = parseCalcSum(tokens, depth, state);
    if (!sumA) {
        LOG_WITH_STREAM(Calc, stream << "Failed '" << nameLiteralForSerialization(Op::id) << "' function - failed parse of argument #1");
        return std::nullopt;
    }

    if (!validateType<Op::input>(sumA->type)) {
        LOG_WITH_STREAM(Calc, stream << "Failed '" << nameLiteralForSerialization(Op::id) << "' function - argument #1 has invalid type: " << sumA->type);
        return std::nullopt;
    }

    if (tokens.atEnd()) {
        auto outputType = transformType<Op::output>(sumA->type);
        if (!outputType) {
            LOG_WITH_STREAM(Calc, stream << "Failed '" << nameLiteralForSerialization(Op::id) << "' (one argument) function - output transform failed for type: " << sumA->type);
            return std::nullopt;
        }

        Op op { WTF::move(sumA->child), std::nullopt };

        return makeSimplifiedTypedChild(WTF::move(op), *outputType, state);
    }

    if (!CSSPropertyParserHelpers::consumeCommaIncludingWhitespace(tokens)) {
        LOG_WITH_STREAM(Calc, stream << "Failed '" << nameLiteralForSerialization(Op::id) << "' function - missing comma");
        return std::nullopt;
    }

    auto sumB = parseCalcSum(tokens, depth, state);
    if (!sumB) {
        LOG_WITH_STREAM(Calc, stream << "Failed '" << nameLiteralForSerialization(Op::id) << "' (two arguments) function - failed parse of argument #2");
        return std::nullopt;
    }

    if (!tokens.atEnd()) {
        LOG_WITH_STREAM(Calc, stream << "Failed '" << nameLiteralForSerialization(Op::id) << "' (two arguments) function - extraneous tokens found");
        return std::nullopt;
    }

    if (!validateType<Op::input>(sumB->type)) {
        LOG_WITH_STREAM(Calc, stream << "Failed '" << nameLiteralForSerialization(Op::id) << "' (two arguments) function - argument #2 has invalid type: " << sumB->type);
        return std::nullopt;
    }

    auto mergedType = mergeTypes<Op::merge>(sumA->type, sumB->type);
    if (!mergedType) {
        LOG_WITH_STREAM(Calc, stream << "Failed '" << nameLiteralForSerialization(Op::id) << "' (two arguments) function - failed to merge type with other arguments: argument #1 type " << sumA->type << " & argument #2 type" << sumB->type);
        return std::nullopt;
    }

    auto outputType = transformType<Op::output>(*mergedType);
    if (!outputType) {
        LOG_WITH_STREAM(Calc, stream << "Failed '" << nameLiteralForSerialization(Op::id) << "' (two arguments) function - output transform failed for type: " << *mergedType);
        return std::nullopt;
    }

    Op op { WTF::move(sumA->child), WTF::move(sumB->child) };

    return makeSimplifiedTypedChild(WTF::move(op), *outputType, state);
}

static std::optional<TypedChild> consumeClamp(CSSParserTokenRange& tokens, int depth, ParserState& state)
{
    // <clamp()> = clamp( [ <calc-sum> | none ], <calc-sum>, [ <calc-sum> | none ] )

    using Op = Clamp;

    struct TypedChildOrNone {
        ChildOrNone child;
        Type type;
    };
    auto parseCalcSumOrNone = [](auto& tokens, auto depth, auto& state) -> std::optional<TypedChildOrNone> {
        if (tokens.peek().id() == CSSValueNone) {
            tokens.consumeIncludingWhitespace();
            return TypedChildOrNone { ChildOrNone { CSS::Keyword::None { } }, Type { } };
        }
        auto sum = parseCalcSum(tokens, depth, state);
        if (!sum)
            return std::nullopt;

        return TypedChildOrNone { ChildOrNone { WTF::move(sum->child) }, sum->type };
    };

    auto min = parseCalcSumOrNone(tokens, depth, state);
    if (!min) {
        LOG_WITH_STREAM(Calc, stream << "Failed '" << nameLiteralForSerialization(Op::id) << "' function - argument 'min' failed to parse");
        return std::nullopt;
    }

    if (!CSSPropertyParserHelpers::consumeCommaIncludingWhitespace(tokens)) {
        LOG_WITH_STREAM(Calc, stream << "Failed '" << nameLiteralForSerialization(Op::id) << "' function - missing comma after argument 'min'");
        return std::nullopt;
    }

    auto val = parseCalcSum(tokens, depth, state);
    if (!val) {
        LOG_WITH_STREAM(Calc, stream << "Failed '" << nameLiteralForSerialization(Op::id) << "' function - argument 'val' failed to parse");
        return std::nullopt;
    }

    if (!CSSPropertyParserHelpers::consumeCommaIncludingWhitespace(tokens)) {
        LOG_WITH_STREAM(Calc, stream << "Failed '" << nameLiteralForSerialization(Op::id) << "' function - missing comma after argument 'val'");
        return std::nullopt;
    }

    auto max = parseCalcSumOrNone(tokens, depth, state);
    if (!max) {
        LOG_WITH_STREAM(Calc, stream << "Failed '" << nameLiteralForSerialization(Op::id) << "' function - argument 'max' failed to parse");
        return std::nullopt;
    }

    if (!tokens.atEnd()) {
        LOG_WITH_STREAM(Calc, stream << "Failed '" << nameLiteralForSerialization(Op::id) << "' function - extraneous tokens found");
        return std::nullopt;
    }

    auto computeType = [&] -> std::optional<Type> {
        bool minIsNone = WTF::holdsAlternative<CSS::Keyword::None>(min->child);
        bool maxIsNone = WTF::holdsAlternative<CSS::Keyword::None>(max->child);

        if (minIsNone && maxIsNone)
            return val->type;

        if (minIsNone) {
            auto valAndMaxType = mergeTypes<MergePolicy::Consistent>(val->type, max->type);
            if (!valAndMaxType) {
                LOG_WITH_STREAM(Calc, stream << "Failed '" << nameLiteralForSerialization(Op::id) << "' function - failed to merge argument 'val' type " << val->type << " & argument 'max' type " << max->type);
                return std::nullopt;
            }
            return *valAndMaxType;
        }

        if (maxIsNone) {
            auto minAndValType = mergeTypes<Op::merge>(min->type, val->type);
            if (!minAndValType) {
                LOG_WITH_STREAM(Calc, stream << "Failed '" << nameLiteralForSerialization(Op::id) << "' function - failed to merge argument 'min' type " << min->type << " & argument 'val' type " << val->type);
                return std::nullopt;
            }
            return *minAndValType;
        }

        auto minAndValType = mergeTypes<Op::merge>(min->type, val->type);
        if (!minAndValType) {
            LOG_WITH_STREAM(Calc, stream << "Failed '" << nameLiteralForSerialization(Op::id) << "' function - failed to merge argument 'min' type " << min->type << " & argument 'val' type " << val->type);
            return std::nullopt;
        }
        auto minAndValAndMaxType = mergeTypes<Op::merge>(*minAndValType, max->type);
        if (!minAndValAndMaxType) {
            LOG_WITH_STREAM(Calc, stream << "Failed '" << nameLiteralForSerialization(Op::id) << "' function - failed to merge already merged type " << *minAndValAndMaxType << " & argument 'max' type " << max->type);
            return std::nullopt;
        }
        return *minAndValAndMaxType;
    };

    auto outputType = computeType();
    if (!outputType)
        return std::nullopt;

    Op op { WTF::move(min->child), WTF::move(val->child), WTF::move(max->child) };

    return makeSimplifiedTypedChild(WTF::move(op), *outputType, state);
}

template<typename Op> static std::optional<TypedChild> consumeRoundArguments(CSSParserTokenRange& tokens, int depth, ParserState& state)
{
    auto sumA = parseCalcSum(tokens, depth, state);
    if (!sumA) {
        LOG_WITH_STREAM(Calc, stream << "Failed 'round(" << nameLiteralForSerialization(Op::id) << ")' function - failed parse of argument #1");
        return std::nullopt;
    }

    if (tokens.atEnd()) {
        if (!validateType<AllowedTypes::Number>(sumA->type)) {
            LOG_WITH_STREAM(Calc, stream << "Failed 'round(" << nameLiteralForSerialization(Op::id) << ")' function - argument #1 has invalid type: " << sumA->type);
            return std::nullopt;
        }

        auto outputType = transformType<Op::output>(sumA->type);
        if (!outputType) {
            LOG_WITH_STREAM(Calc, stream << "Failed 'round(" << nameLiteralForSerialization(Op::id) << ")' (one argument) function - output transform failed for type: " << sumA->type);
            return std::nullopt;
        }

        Op op { WTF::move(sumA->child), std::nullopt };

        return makeSimplifiedTypedChild(WTF::move(op), *outputType, state);
    }

    if (!CSSPropertyParserHelpers::consumeCommaIncludingWhitespace(tokens)) {
        LOG_WITH_STREAM(Calc, stream << "Failed 'round(" << nameLiteralForSerialization(Op::id) << ")' function - missing comma");
        return std::nullopt;
    }

    auto sumB = parseCalcSum(tokens, depth, state);
    if (!sumB) {
        LOG_WITH_STREAM(Calc, stream << "Failed 'round(" << nameLiteralForSerialization(Op::id) << ")' (two arguments) function - failed parse of argument #2");
        return std::nullopt;
    }

    if (!tokens.atEnd()) {
        LOG_WITH_STREAM(Calc, stream << "Failed 'round(" << nameLiteralForSerialization(Op::id) << ")' (two arguments) function - extraneous tokens found");
        return std::nullopt;
    }

    auto mergedType = mergeTypes<Op::merge>(sumA->type, sumB->type);
    if (!mergedType) {
        LOG_WITH_STREAM(Calc, stream << "Failed 'round(" << nameLiteralForSerialization(Op::id) << ")' (two arguments) function - failed to merge type with other arguments: argument #1 type " << sumA->type << " & argument #2 type" << sumB->type);
        return std::nullopt;
    }

    auto outputType = transformType<Op::output>(*mergedType);
    if (!outputType) {
        LOG_WITH_STREAM(Calc, stream << "Failed 'round(" << nameLiteralForSerialization(Op::id) << ")' (two arguments) function - output transform failed for type: " << *mergedType);
        return std::nullopt;
    }

    Op op { WTF::move(sumA->child), WTF::move(sumB->child) };

    LOG_WITH_STREAM(Calc, stream << "Succeeded 'round(" << nameLiteralForSerialization(Op::id) << ")' (two arguments) function: type is " << *outputType);

    return makeSimplifiedTypedChild(WTF::move(op), *outputType, state);
}

static std::optional<TypedChild> consumeRound(CSSParserTokenRange& tokens, int depth, ParserState& state)
{
    // <round()> = round( <rounding-strategy>?, <calc-sum>, <calc-sum>? )

    auto roundingStrategy = CSSPropertyParserHelpers::consumeIdentRaw<CSSValueNearest, CSSValueToZero, CSSValueUp, CSSValueDown>(tokens);
    if (!roundingStrategy)
        return consumeRoundArguments<RoundNearest>(tokens, depth, state);

    if (!CSSPropertyParserHelpers::consumeCommaIncludingWhitespace(tokens)) {
        LOG_WITH_STREAM(Calc, stream << "Failed 'round(" << nameLiteralForSerialization(*roundingStrategy) << ") function - missing comma after <rounding-strategy>");
        return std::nullopt;
    }

    switch (*roundingStrategy) {
    case CSSValueNearest:
        return consumeRoundArguments<RoundNearest>(tokens, depth, state);
    case CSSValueToZero:
        return consumeRoundArguments<RoundToZero>(tokens, depth, state);
    case CSSValueUp:
        return consumeRoundArguments<RoundUp>(tokens, depth, state);
    case CSSValueDown:
        return consumeRoundArguments<RoundDown>(tokens, depth, state);
    default:
        break;
    }

    return std::nullopt;
}

static std::optional<TypedChild> consumeRandom(CSSParserTokenRange& tokens, int depth, ParserState& state)
{
    // <random()> = random( <random-key>? , <calc-sum>, <calc-sum>, <calc-sum>? )

    if (!state.propertyParserState.context.cssRandomFunctionEnabled)
        return { };

    if (state.propertyParserState.currentRule != StyleRuleType::Style && state.propertyParserState.currentRule != StyleRuleType::Keyframe)
        return { };
    if (state.propertyParserState.currentProperty == CSSPropertyInvalid)
        return { };

    if (state.propertyParserState.randomFunctionsDisallowed)
        return { };

    using Op = Random;

    auto keySource = CSSPropertyParserHelpers::RandomKeySource {
        .property = { state.propertyParserState.currentProperty, state.propertyParserState.currentCustomPropertyName, RandomFunction::Random },
        .autoElementScoped = CSS::Keyword::ElementScoped { }
    };

    std::optional<Random::Sharing> sharing;
    if (auto optionalSharing = CSSPropertyParserHelpers::consumeUnresolvedRandomKey(tokens, state.propertyParserState, keySource, [&] {
        return state.propertyParserState.cssRandomFunctionCount;
    })) {
        if (!CSSPropertyParserHelpers::consumeCommaIncludingWhitespace(tokens)) {
            LOG_WITH_STREAM(Calc, stream << "Failed '" << nameLiteralForSerialization(Op::id) << "' function - missing comma after <random-key>");
            return { };
        }

        sharing = WTF::move(optionalSharing);
    } else
        sharing = CSSPropertyParserHelpers::randomSharingAuto(keySource, state.propertyParserState.cssRandomFunctionCount);

    // Increment the random function count early, but after processing the the sharing production to
    // ensure that any nested random() functions in the <calc-sum> productions have an incremented value.
    ++state.propertyParserState.cssRandomFunctionCount;

    auto min = parseCalcSum(tokens, depth, state);
    if (!min) {
        LOG_WITH_STREAM(Calc, stream << "Failed '" << nameLiteralForSerialization(Op::id) << "' function - failed parse of argument `min`");
        return { };
    }

    if (!CSSPropertyParserHelpers::consumeCommaIncludingWhitespace(tokens)) {
        LOG_WITH_STREAM(Calc, stream << "Failed '" << nameLiteralForSerialization(Op::id) << "' function - missing comma after argument `min`");
        return { };
    }

    auto max = parseCalcSum(tokens, depth, state);
    if (!max) {
        LOG_WITH_STREAM(Calc, stream << "Failed '" << nameLiteralForSerialization(Op::id) << "' function - failed parse of argument `max`");
        return { };
    }

    if (tokens.atEnd()) {
        // - Validate arguments

        if (!validateType<Op::input>(min->type)) {
            LOG_WITH_STREAM(Calc, stream << "Failed '" << nameLiteralForSerialization(Op::id) << "' function - argument `min` has invalid type: " << min->type);
            return { };
        }

        if (!validateType<Op::input>(max->type)) {
            LOG_WITH_STREAM(Calc, stream << "Failed '" << nameLiteralForSerialization(Op::id) << "' function - argument `max` has invalid type: " << max->type);
            return { };
        }

        // - Merge arguments

        auto mergedType = mergeTypes<Op::merge>(min->type, max->type);
        if (!mergedType) {
            LOG_WITH_STREAM(Calc, stream << "Failed '" << nameLiteralForSerialization(Op::id) << "' function - failed to merge types");
            return { };
        }

        auto outputType = transformType<Op::output>(*mergedType);
        if (!outputType) {
            LOG_WITH_STREAM(Calc, stream << "Failed '" << nameLiteralForSerialization(Op::id) << "' function - output transform failed for type: " << *mergedType);
            return { };
        }

        state.requiresConversionData = true;

        Op op { WTF::move(*sharing), WTF::move(min->child), WTF::move(max->child), std::nullopt };

        return makeSimplifiedTypedChild(WTF::move(op), *outputType, state);
    }

    if (!CSSPropertyParserHelpers::consumeCommaIncludingWhitespace(tokens)) {
        LOG_WITH_STREAM(Calc, stream << "Failed '" << nameLiteralForSerialization(Op::id) << "' function - missing comma after argument `max`");
        return { };
    }

    auto step = parseCalcSum(tokens, depth, state);
    if (!step) {
        LOG_WITH_STREAM(Calc, stream << "Failed '" << nameLiteralForSerialization(Op::id) << "' function - failed parse of argument `step`");
        return { };
    }

    if (!tokens.atEnd()) {
        LOG_WITH_STREAM(Calc, stream << "Failed '" << nameLiteralForSerialization(Op::id) << "' function - extraneous tokens found");
        return { };
    }

    // - Validate arguments

    if (!validateType<Op::input>(step->type)) {
        LOG_WITH_STREAM(Calc, stream << "Failed '" << nameLiteralForSerialization(Op::id) << "' function - argument `step` has invalid type: " << step->type);
        return { };
    }

    // - Merge arguments

    auto mergedType = mergeTypes<Op::merge>(min->type, max->type);
    if (!mergedType) {
        LOG_WITH_STREAM(Calc, stream << "Failed '" << nameLiteralForSerialization(Op::id) << "' function - failed to merge types");
        return { };
    }

    mergedType = mergeTypes<Op::merge>(*mergedType, step->type);
    if (!mergedType) {
        LOG_WITH_STREAM(Calc, stream << "Failed '" << nameLiteralForSerialization(Op::id) << "' function - failed to merge types");
        return { };
    }

    auto outputType = transformType<Op::output>(*mergedType);
    if (!outputType) {
        LOG_WITH_STREAM(Calc, stream << "Failed '" << nameLiteralForSerialization(Op::id) << "' function - output transform failed for type: " << *mergedType);
        return { };
    }

    state.requiresConversionData = true;

    Op op { WTF::move(*sharing), WTF::move(min->child), WTF::move(max->child), WTF::move(step->child) };

    return makeSimplifiedTypedChild(WTF::move(op), *outputType, state);
}

template<typename Op>
static std::optional<TypedChild> consumeProgressImpl(CSSParserTokenRange& tokens, int depth, ParserState& state)
{
    auto value = parseCalcSum(tokens, depth, state);
    if (!value) {
        LOG_WITH_STREAM(Calc, stream << "Failed '" << nameLiteralForSerialization(Op::id) << "' function - failed parse of argument #1");
        return std::nullopt;
    }

    if (!CSSPropertyParserHelpers::consumeCommaIncludingWhitespace(tokens)) {
        LOG_WITH_STREAM(Calc, stream << "Failed '" << nameLiteralForSerialization(Op::id) << "' function - missing comma");
        return std::nullopt;
    }

    auto start = parseCalcSum(tokens, depth, state);
    if (!start) {
        LOG_WITH_STREAM(Calc, stream << "Failed '" << nameLiteralForSerialization(Op::id) << "' function - failed parse of argument #2");
        return std::nullopt;
    }

    if (!CSSPropertyParserHelpers::consumeCommaIncludingWhitespace(tokens)) {
        LOG_WITH_STREAM(Calc, stream << "Failed '" << nameLiteralForSerialization(Op::id) << "' function - missing comma");
        return std::nullopt;
    }

    auto end = parseCalcSum(tokens, depth, state);
    if (!end) {
        LOG_WITH_STREAM(Calc, stream << "Failed '" << nameLiteralForSerialization(Op::id) << "' function - failed parse of argument #3");
        return std::nullopt;
    }

    if (!tokens.atEnd()) {
        LOG_WITH_STREAM(Calc, stream << "Failed '" << nameLiteralForSerialization(Op::id) << "' function - extraneous tokens found");
        return std::nullopt;
    }

    // - Validate arguments

    if (!validateType<Op::input>(value->type)) {
        LOG_WITH_STREAM(Calc, stream << "Failed '" << nameLiteralForSerialization(Op::id) << "' function - argument #1 has invalid type: " << value->type);
        return std::nullopt;
    }

    if (!validateType<Op::input>(start->type)) {
        LOG_WITH_STREAM(Calc, stream << "Failed '" << nameLiteralForSerialization(Op::id) << "' function - argument #2 has invalid type: " << start->type);
        return std::nullopt;
    }

    if (!validateType<Op::input>(end->type)) {
        LOG_WITH_STREAM(Calc, stream << "Failed '" << nameLiteralForSerialization(Op::id) << "' function - argument #3 has invalid type: " << end->type);
        return std::nullopt;
    }

    // - Merge arguments

    auto mergedType = mergeTypes<Op::merge>(value->type, start->type);
    if (!mergedType) {
        LOG_WITH_STREAM(Calc, stream << "Failed '" << nameLiteralForSerialization(Op::id) << "' function - failed to merge types: argument #1 type " << value->type << ", argument #2 type" << start->type << ", argument #3 type" << end->type);
        return std::nullopt;
    }

    mergedType = mergeTypes<Op::merge>(*mergedType, end->type);
    if (!mergedType) {
        LOG_WITH_STREAM(Calc, stream << "Failed '" << nameLiteralForSerialization(Op::id) << "' function - failed to merge types: argument #1 type " << value->type << ", argument #2 type" << start->type << ", argument #3 type" << end->type);
        return std::nullopt;
    }

    auto outputType = transformType<Op::output>(*mergedType);
    if (!outputType) {
        LOG_WITH_STREAM(Calc, stream << "Failed '" << nameLiteralForSerialization(Op::id) << "' function - output transform failed for type: " << *mergedType);
        return std::nullopt;
    }

    Op op { WTF::move(value->child), WTF::move(start->child), WTF::move(end->child) };

    return makeSimplifiedTypedChild(WTF::move(op), *outputType, state);
}

static std::optional<TypedChild> consumeProgress(CSSParserTokenRange& tokens, int depth, ParserState& state)
{
    // <progress()> = progress( no-clamp? <calc-sum>, <calc-sum>, <calc-sum> )

    if (CSSPropertyParserHelpers::consumeIdentRaw<CSSValueNoClamp>(tokens))
        return consumeProgressImpl<ProgressNoClamp>(tokens, depth, state);
    return consumeProgressImpl<Progress>(tokens, depth, state);
}

static std::optional<TypedChild> consumeValueWithoutSimplifyingRootCalc(CSSParserTokenRange& tokens, int depth, ParserState& state)
{
    // Complex arguments need to be surrounded by a math function.
    if (tokens.peek().type() == LeftParenthesisToken)
        return { };

    auto isFunction = !!tokens.peek().functionId();

    auto typedValue = parseCalcValue(tokens, depth, state);
    if (!typedValue)
        return { };

    auto isLeafValue = isLeaf(typedValue->child);

    if (isFunction && isLeafValue) {
        // Wrap in Sum to keep top level calc() function in serialization. `anchor()` is not a math
        // function, so `serializeWithoutOmittingPrefix` prints a `calc()` only for a non-`Leaf`
        // child, and this wrapper is the tree's ONLY record that the author wrote one. A whole-tree
        // `copyAndSimplify` collapses it (css-values-4 8.3) and `rebuildChildren` puts it back.
        Vector<Child> children;
        children.append(WTF::move(typedValue->child));

        return TypedChild { makeChild(Sum { WTF::move(children) }, typedValue->type), typedValue->type };
    }

    return typedValue;
}

static std::optional<TypedChild> consumeCalcMix(CSSParserTokenRange& tokens, int depth, ParserState& state)
{
    // <calc-mix()> = calc-mix( [ <calc-sum> <percentage [0,100]>? ]# )

    using Op = CalcMix;

    if (!state.propertyParserState.context.cssCalcMixEnabled)
        return { };

    std::optional<Type> mergedType;
    Vector<CalcMix::Item> children;

    bool requireComma = false;
    unsigned argumentCount = 0;

    while (!tokens.atEnd()) {
        tokens.consumeWhitespace();
        if (requireComma && !CSSPropertyParserHelpers::consumeCommaIncludingWhitespace(tokens)) {
            LOG_WITH_STREAM(Calc, stream << "Failed '" << nameLiteralForSerialization(Op::id) << "' function - missing comma");
            return std::nullopt;
        }

        auto sum = parseCalcSum(tokens, depth, state);
        if (!sum) {
            LOG_WITH_STREAM(Calc, stream << "Failed '" << nameLiteralForSerialization(Op::id) << "' function - failed parse of argument #" << argumentCount);
            return std::nullopt;
        }

        if (!validateType<Op::input>(sum->type)) {
            LOG_WITH_STREAM(Calc, stream << "Failed '" << nameLiteralForSerialization(Op::id) << "' function - argument #" << argumentCount << " has invalid type: " << sum->type);
            return std::nullopt;
        }

        if (!mergedType)
            mergedType = sum->type;
        else {
            auto mergeResult = mergeTypes<Op::merge>(*mergedType, sum->type);
            if (!mergeResult) {
                LOG_WITH_STREAM(Calc, stream << "Failed '" << nameLiteralForSerialization(Op::id) << "' function - argument #" << argumentCount << " failed to merge type with other arguments: existing type " << *mergedType << " & argument type " << sum->type);
                return std::nullopt;
            }
            mergedType = *mergeResult;
        }

        std::optional<CalcMix::Item::Weight> weight;
        if (!tokens.atEnd() && tokens.peek().type() != CommaToken) {
            weight = CSSPropertyParserHelpers::MetaConsumer<CalcMix::Item::Weight>::consume(tokens, state.propertyParserState);
            if (!weight)
                return { };
        }

        ++argumentCount;
        children.append(CalcMix::Item { .value = WTF::move(sum->child), .weight = WTF::move(weight) });
        requireComma = true;
    }

    if (argumentCount < 1) {
        LOG_WITH_STREAM(Calc, stream << "Failed '" << nameLiteralForSerialization(Op::id) << "' function - no arguments found");
        return std::nullopt;
    }

    auto outputType = transformType<Op::output>(*mergedType);
    if (!outputType) {
        LOG_WITH_STREAM(Calc, stream << "Failed '" << nameLiteralForSerialization(Op::id) << "' function - output transform failed for type: " << *mergedType);
        return std::nullopt;
    }

    Op op { WTF::move(children) };

    return makeSimplifiedTypedChild(WTF::move(op), *outputType, state);
}

// Parse the fallback value specified in anchor() and anchor-size() as a <length> or
// <length-percentage>. Additionally, unitless zero is allowed and gets treated as 0px.
static std::optional<TypedChild> consumeAnchorFallback(CSSParserTokenRange& tokens, int depth, ParserState& state)
{
    auto typedFallback = consumeValueWithoutSimplifyingRootCalc(tokens, depth, state);
    if (!typedFallback)
        return { };

    auto category = typedFallback->type.calculationCategory();
    if (!category)
        return { };

    switch (*category) {
    case CSS::Category::Length:
    case CSS::Category::LengthPercentage:
        return typedFallback;

    case CSS::Category::Number: {
        if (state.parserOptions.propertyOptions.unitlessZeroLength != UnitlessZeroQuirk::Allow)
            return { };

        // Allow unitless 0, but only as a bare <number> leaf. A math function
        // such as calc(0) or min(0, 0) also has number type but is wrapped in a
        // Sum node, so it is not a valid unitless-zero fallback.
        auto* number = std::get_if<Number>(&typedFallback->child.value);
        if (!number || number->value)
            return { };

        return TypedChild { makeNumeric(0, CSSUnitType::Px), Type::makeLength() };
    }

    default:
        return { };
    }
}

static std::optional<TypedChild> consumeAnchor(CSSParserTokenRange& tokens, int depth, ParserState& state)
{
    // <anchor()> = anchor( <anchor-element>? && <anchor-side>, <length-percentage>? )

    if (state.parserOptions.propertyOptions.anchorPolicy != AnchorPolicy::Allow)
        return { };

    auto anchorElement = CSSPropertyParserHelpers::consumeUnresolvedDashedIdent(tokens, state.propertyParserState);

    // <anchor-side> = inside | outside | top | left | right | bottom | start | end | self-start | self-end | <percentage> | center
    auto anchorSide = [&]() -> std::optional<AnchorSide> {
        auto sideIdent = CSSPropertyParserHelpers::consumeIdentRaw<CSSValueInside, CSSValueOutside, CSSValueTop, CSSValueLeft, CSSValueRight, CSSValueBottom, CSSValueStart, CSSValueEnd, CSSValueSelfStart, CSSValueSelfEnd, CSSValueCenter>(tokens);
        if (sideIdent)
            return AnchorSide { *sideIdent };

        auto percentageOptions = ParserOptions {
            .category = CSS::Category::Percentage,
            .range = CSS::All,
            .allowedSymbols = { },
            .propertyOptions = { },
        };
        auto percentageState = ParserState {
            .propertyParserState = state.propertyParserState,
            .parserOptions = percentageOptions,
            .simplificationOptions = { },
        };

        auto percentage = consumeValueWithoutSimplifyingRootCalc(tokens, depth, percentageState);
        if (!percentage)
            return { };

        auto category = percentage->type.calculationCategory();
        if (!category || category != CSS::Category::Percentage)
            return { };

        return AnchorSide { WTF::move(percentage->child) };
    }();

    if (!anchorSide)
        return { };

    if (!anchorElement)
        anchorElement = CSSPropertyParserHelpers::consumeUnresolvedDashedIdent(tokens, state.propertyParserState);

    auto type = Type::makeLength();
    std::optional<Child> fallback;

    if (CSSPropertyParserHelpers::consumeCommaIncludingWhitespace(tokens)) {
        auto maybeFallback = consumeAnchorFallback(tokens, depth, state);
        if (!maybeFallback)
            return { };

        fallback = WTF::move(maybeFallback->child);

        auto category = maybeFallback->type.calculationCategory();
        ASSERT(category && (category == CSS::Category::Length || category == CSS::Category::LengthPercentage));

        type.percentHint = Type::determinePercentHint(*category);
    }

    state.requiresConversionData = true;

    auto anchor = Anchor {
        .elementName = WTF::move(anchorElement),
        .side = WTF::move(*anchorSide),
        .fallback = WTF::move(fallback)
    };

    return TypedChild { makeChild(WTF::move(anchor), type), type };
}

static std::optional<Style::AnchorSizeDimension> NODELETE cssValueIDToAnchorSizeDimension(CSSValueID value)
{
    switch (value) {
    case CSSValueWidth:
        return Style::AnchorSizeDimension::Width;
    case CSSValueHeight:
        return Style::AnchorSizeDimension::Height;
    case CSSValueBlock:
        return Style::AnchorSizeDimension::Block;
    case CSSValueInline:
        return Style::AnchorSizeDimension::Inline;
    case CSSValueSelfBlock:
        return Style::AnchorSizeDimension::SelfBlock;
    case CSSValueSelfInline:
        return Style::AnchorSizeDimension::SelfInline;
    default:
        return { };
    }
}

static std::optional<TypedChild> consumeAnchorSize(CSSParserTokenRange& tokens, int depth, ParserState& state)
{
    // anchor-size() = anchor-size( [ <anchor-element> || <anchor-size> ]? , <length-percentage>? )
    // <anchor-element> = <dashed-ident>
    // <anchor-size> = width | height | block | inline | self-block | self-inline

    if (state.parserOptions.propertyOptions.anchorSizePolicy != AnchorSizePolicy::Allow)
        return { };

    // parse <anchor-element>
    auto maybeAnchorElement = CSSPropertyParserHelpers::consumeUnresolvedDashedIdent(tokens, state.propertyParserState);

    // then parse <anchor-size>
    auto maybeAnchorSize = CSSPropertyParserHelpers::consumeIdentRaw<CSSValueWidth, CSSValueHeight, CSSValueBlock, CSSValueInline, CSSValueSelfBlock, CSSValueSelfInline>(tokens);

    // if we could parse <anchor-size> but not <anchor-element>, it's possible <anchor-element> is specified
    // after <anchor-size>, so re-parse <anchor-element>
    if (maybeAnchorSize && !maybeAnchorElement)
        maybeAnchorElement = CSSPropertyParserHelpers::consumeUnresolvedDashedIdent(tokens, state.propertyParserState);

    std::optional<TypedChild> fallback;

    // if either <anchor-element> or <anchor-size> is present
    if (maybeAnchorSize || maybeAnchorElement) {
        // if a comma follows...
        if (CSSPropertyParserHelpers::consumeCommaIncludingWhitespace(tokens)) {
            // it must be followed by the fallback value.
            fallback = consumeAnchorFallback(tokens, depth, state);
            if (!fallback)
                return { };
        }
        // if a comma does not follow, then there's no fallback value.
    } else {
        // if <anchor-element> and <anchor-size> is not present
        // then an optional fallback value follows
        fallback = consumeAnchorFallback(tokens, depth, state);
    }

    // Return type of this function. It's a <length> if it can be resolved, otherwise the
    // <length-percentage> fallback is resolved, which could be a percentage.
    auto type = Type::makeLength();
    if (fallback) {
        auto category = fallback->type.calculationCategory();
        ASSERT(category && (category == CSS::Category::Length || category == CSS::Category::LengthPercentage));

        type.percentHint = Type::determinePercentHint(*category);
    }

    state.requiresConversionData = true;

    auto anchorSize = AnchorSize {
        .elementName = WTF::move(maybeAnchorElement),
        .dimension = maybeAnchorSize ? cssValueIDToAnchorSizeDimension(*maybeAnchorSize) : std::nullopt,
        .fallback = fallback ? std::make_optional(WTF::move(fallback->child)) : std::nullopt
    };

    return TypedChild {
        .child = makeChild(WTF::move(anchorSize), type),
        .type = type
    };
}

std::optional<TypedChild> parseCalcFunction(CSSParserTokenRange& tokens, CSSValueID functionID, int depth, ParserState& state)
{
    if (checkDepth(depth) != ParseStatus::Ok)
        return std::nullopt;

    switch (functionID) {
    case CSSValueWebkitCalc:
    case CSSValueCalc:
        // <calc()>  = calc( <calc-sum> )
        return parseCalcSum(tokens, depth, state);

    case CSSValueMin:
        // <min()>   = min( <calc-sum># )
        //     - INPUT: "consistent" <number>, <dimension>, or <percentage>
        //     - OUTPUT: consistent type
        return consumeOneOrMoreArguments<Min>(tokens, depth, state);

    case CSSValueMax:
        // <max()>   = max( <calc-sum># )
        //     - INPUT: "consistent" <number>, <dimension>, or <percentage>
        //     - OUTPUT: consistent type
        return consumeOneOrMoreArguments<Max>(tokens, depth, state);

    case CSSValueClamp:
        // <clamp()> = clamp( [ <calc-sum> | none ], <calc-sum>, [ <calc-sum> | none ] )
        //     - INPUT: "consistent" <number>, <dimension>, or <percentage>
        //     - OUTPUT: consistent type
        return consumeClamp(tokens, depth, state);

    case CSSValueRound:
        // <round()> = round( <rounding-strategy>?, <calc-sum>, <calc-sum>? )
        //     - INPUT: "consistent" <number>, <dimension>, or <percentage>
        //     - OUTPUT: consistent type
        return consumeRound(tokens, depth, state);

    case CSSValueMod:
        // <mod()>   = mod( <calc-sum>, <calc-sum> )
        //     - INPUT: "same" <number>, <dimension>, or <percentage>
        //     - OUTPUT: same type
        return consumeExactlyTwoArguments<Mod>(tokens, depth, state);

    case CSSValueRem:
        // <rem()>   = rem( <calc-sum>, <calc-sum> )
        //     - INPUT: "same" <number>, <dimension>, or <percentage>
        //     - OUTPUT: same type
        return consumeExactlyTwoArguments<Rem>(tokens, depth, state);

    case CSSValueSin:
        // <sin()>   = sin( <calc-sum> )
        //     - INPUT: <number> or <angle>
        //     - OUTPUT: <number> "made consistent"
        return consumeExactlyOneArgument<Sin>(tokens, depth, state);

    case CSSValueCos:
        // <cos()>   = cos( <calc-sum> )
        //     - INPUT: <number> or <angle>
        //     - OUTPUT: <number> "made consistent"
        return consumeExactlyOneArgument<Cos>(tokens, depth, state);

    case CSSValueTan:
        // <tan()>   = tan( <calc-sum> )
        //     - INPUT: <number> or <angle>
        //     - OUTPUT: <number> "made consistent"
        return consumeExactlyOneArgument<Tan>(tokens, depth, state);

    case CSSValueAsin:
        // <asin()>  = asin( <calc-sum> )
        //     - INPUT: <number>
        //     - OUTPUT: <angle> "made consistent"
        return consumeExactlyOneArgument<Asin>(tokens, depth, state);

    case CSSValueAcos:
        // <acos()>  = acos( <calc-sum> )
        //     - INPUT: <number>
        //     - OUTPUT: <angle> "made consistent"
        return consumeExactlyOneArgument<Acos>(tokens, depth, state);

    case CSSValueAtan:
        // <atan()>  = atan( <calc-sum> )
        //     - INPUT: <number>
        //     - OUTPUT: <angle> "made consistent"
        return consumeExactlyOneArgument<Atan>(tokens, depth, state);

    case CSSValueAtan2:
        // <atan2()> = atan2( <calc-sum>, <calc-sum> )
        //     - INPUT: "consistent" <number>, <dimension>, or <percentage>
        //     - OUTPUT: <angle> "made consistent"
        return consumeExactlyTwoArguments<Atan2>(tokens, depth, state);

    case CSSValuePow:
        // <pow()>   = pow( <calc-sum>, <calc-sum> )
        //     - INPUT: "consistent" <number>
        //     - OUTPUT: consistent type
        return consumeExactlyTwoArguments<Pow>(tokens, depth, state);

    case CSSValueSqrt:
        // <sqrt()>  = sqrt( <calc-sum> )
        //     - INPUT: <number>
        //     - OUTPUT: <number> "made consistent"
        return consumeExactlyOneArgument<Sqrt>(tokens, depth, state);

    case CSSValueHypot:
        // <hypot()> = hypot( <calc-sum># )
        //     - INPUT: "consistent" <number>, <dimension>, or <percentage>
        //     - OUTPUT: consistent type
        return consumeOneOrMoreArguments<Hypot>(tokens, depth, state);

    case CSSValueLog:
        // <log()>   = log( <calc-sum>, <calc-sum>? )
        //     - INPUT: <number>
        //     - OUTPUT: <number> "made consistent"
        return consumeOneOrTwoArguments<Log>(tokens, depth, state);

    case CSSValueExp:
        // <exp()>   = exp( <calc-sum> )
        //     - INPUT: <number>
        //     - OUTPUT: <number> "made consistent"
        return consumeExactlyOneArgument<Exp>(tokens, depth, state);

    case CSSValueAbs:
        // <abs()>   = abs( <calc-sum> )
        //     - INPUT: any
        //     - OUTPUT: input type
        return consumeExactlyOneArgument<Abs>(tokens, depth, state);

    case CSSValueSign:
        // <sign()>  = sign( <calc-sum> )
        //     - INPUT: any
        //     - OUTPUT: <number> "made consistent"
        return consumeExactlyOneArgument<Sign>(tokens, depth, state);

    case CSSValueRandom:
        // <random()> = random( <random-key>? , <calc-sum>, <calc-sum>, <calc-sum>? )
        //     - INPUT: "same" <number>, <dimension>, or <percentage>
        //     - OUTPUT: same type
        return consumeRandom(tokens, depth, state);

    case CSSValueProgress:
        // <progress()> = progress( <calc-sum>, <calc-sum>, <calc-sum> )
        //     - INPUT: "consistent" <number>, <dimension>, or <percentage>
        //     - OUTPUT: <number> "made consistent"
        return consumeProgress(tokens, depth, state);


    case CSSValueCalcMix:
        // <calc-mix()> = calc-mix( [ <calc-sum> <percentage [0,100]>? ]# )
        //     - INPUT: "consistent" <number>, <dimension>, or <percentage> (referring to <calc-sum> arguments)
        //     - OUTPUT: consistent type
        return consumeCalcMix(tokens, depth, state);

    case CSSValueSiblingCount:
        // <sibling-count()> = sibling-count()
        //     - INPUT: none
        //     - OUTPUT: <integer>
        if (!state.propertyParserState.context.cssTreeCountingFunctionsEnabled)
            return { };
        if (state.propertyParserState.currentRule != StyleRuleType::Style && state.propertyParserState.currentRule != StyleRuleType::Keyframe)
            return { };
        if (state.propertyParserState.currentProperty == CSSPropertyInvalid)
            return { };
        state.requiresConversionData = true;
        return consumeZeroArguments<SiblingCount>(tokens, depth, state);

    case CSSValueSiblingIndex:
        // <sibling-index()> = sibling-index()
        //     - INPUT: none
        //     - OUTPUT: <integer>
        if (!state.propertyParserState.context.cssTreeCountingFunctionsEnabled)
            return { };
        if (state.propertyParserState.currentRule != StyleRuleType::Style && state.propertyParserState.currentRule != StyleRuleType::Keyframe)
            return { };
        if (state.propertyParserState.currentProperty == CSSPropertyInvalid)
            return { };
        state.requiresConversionData = true;
        return consumeZeroArguments<SiblingIndex>(tokens, depth, state);

    case CSSValueAnchor:
        return consumeAnchor(tokens, depth, state);

    case CSSValueAnchorSize:
        return consumeAnchorSize(tokens, depth, state);

    default:
        break;
    }

    return std::nullopt;
}

std::optional<TypedChild> parseCalcSum(CSSParserTokenRange& tokens, int depth, ParserState& state)
{
    // <calc-sum> = <calc-product> [ [ '+' | '-' ] <calc-product> ]*

    if (checkDepth(depth) != ParseStatus::Ok)
        return std::nullopt;

    auto originalTokens = tokens.span();

    auto firstValue = parseCalcProduct(tokens, depth, state);
    if (!firstValue)
        return std::nullopt;

    auto sumType = firstValue->type;
    Vector<Child> children;

    while (!tokens.atEnd()) {
        auto& token = tokens.peek();
        char operatorCharacter = token.type() == DelimiterToken ? token.delimiter() : 0;
        if (operatorCharacter != static_cast<char>(Operator::Sum) && operatorCharacter != static_cast<char>(Operator::Negate))
            break;

        auto previousToken = originalTokens[tokens.begin() - originalTokens.data() - 1];
        if (!CSSTokenizer::isWhitespace(previousToken.type()))
            return std::nullopt; // calc(1px+ 2px) is invalid

        tokens.consume();
        if (!CSSTokenizer::isWhitespace(tokens.peek().type()))
            return std::nullopt; // calc(1px +2px) is invalid

        tokens.consumeIncludingWhitespace();

        auto nextValue = parseCalcProduct(tokens, depth, state);
        if (!nextValue)
            return std::nullopt;

        if (operatorCharacter == static_cast<char>(Operator::Negate)) {
            auto negate = [](TypedChild& next, ParserState& state) -> std::optional<TypedChild> {
                Negate negate { WTF::move(next.child) };
                auto negateType = next.type;

                return makeSimplifiedTypedChild(WTF::move(negate), negateType, state);
            };

            nextValue = negate(*nextValue, state);
        }

        if (firstValue) {
            children.append(WTF::move(firstValue->child));
            firstValue = std::nullopt;
        }

        auto newType = Type::add(sumType, nextValue->type);
        if (!newType)
            return std::nullopt;

        sumType = *newType;
        children.append(WTF::move(nextValue->child));
    }

    if (children.isEmpty())
        return firstValue;

    Sum sum { WTF::move(children) };

    return makeSimplifiedTypedChild(WTF::move(sum), sumType, state);
}

std::optional<TypedChild> parseCalcProduct(CSSParserTokenRange& tokens, int depth, ParserState& state)
{
    // <calc-product> = <calc-value> [ [ '*' | '/' ] <calc-value> ]*

    if (checkDepth(depth) != ParseStatus::Ok)
        return std::nullopt;

    auto firstValue = parseCalcValue(tokens, depth, state);
    if (!firstValue)
        return std::nullopt;

    auto productType = firstValue->type;
    Vector<Child> children;

    while (!tokens.atEnd()) {
        auto& token = tokens.peek();
        char operatorCharacter = token.type() == DelimiterToken ? token.delimiter() : 0;
        if (operatorCharacter != static_cast<char>(Operator::Product) && operatorCharacter != static_cast<char>(Operator::Invert))
            break;
        tokens.consumeIncludingWhitespace();

        auto nextValue = parseCalcValue(tokens, depth, state);
        if (!nextValue)
            return std::nullopt;

        if (operatorCharacter == static_cast<char>(Operator::Invert)) {
            auto invert = [](TypedChild& next, ParserState& state) -> std::optional<TypedChild> {
                Invert invert { WTF::move(next.child) };
                auto invertType = Type::invert(next.type);

                return makeSimplifiedTypedChild(WTF::move(invert), invertType, state);
            };

            nextValue = invert(*nextValue, state);
        }

        if (firstValue) {
            children.append(WTF::move(firstValue->child));
            firstValue = std::nullopt;
        }

        auto newType = Type::multiply(productType, nextValue->type);
        if (!newType)
            return std::nullopt;

        productType = *newType;
        children.append(WTF::move(nextValue->child));
    }

    if (children.isEmpty())
        return firstValue;

    Product product { WTF::move(children) };

    return makeSimplifiedTypedChild(WTF::move(product), productType, state);
}

std::optional<TypedChild> parseCalcValue(CSSParserTokenRange& tokens, int depth, ParserState& state)
{
    // <calc-value> = <number> | <dimension> | <percentage> | <calc-keyword> | ( <calc-sum> )
    // <calc-keyword> = e | pi | infinity | -infinity | NaN
    //
    // NOTE: <calc-keyword> is extended for identifiers specified via CSSCalcSymbolsAllowed.

    if (checkDepth(depth) != ParseStatus::Ok)
        return std::nullopt;

    auto findBlock = [&](auto& tokens) -> std::optional<CSSValueID> {
        if (tokens.peek().type() == LeftParenthesisToken) {
            // Simple blocks (e.g. parenthesis around additional expressions) can be treated just like a nested calc().
            return CSSValueCalc;
        }

        if (auto functionId = tokens.peek().functionId(); isCalcFunction(functionId))
            return functionId;
        return std::nullopt;
    };

    if (auto functionId = findBlock(tokens)) {
        CSSParserTokenRange innerRange = tokens.consumeBlock();
        tokens.consumeWhitespace();
        innerRange.consumeWhitespace();

        auto function = parseCalcFunction(innerRange, *functionId, depth + 1, state);
        if (!function)
            return std::nullopt;

        if (!innerRange.atEnd()) {
            LOG_WITH_STREAM(Calc, stream << "Failed '" << nameLiteralForSerialization(*functionId) << "' function - extraneous tokens found");
            return std::nullopt;
        }

        return function;
    }

    auto token = tokens.consumeIncludingWhitespace();

    switch (token.type()) {
    case IdentToken:
        return parseCalcKeyword(token, state);
    case NumberToken:
        return parseCalcNumber(token, state);
    case PercentageToken:
        return parseCalcPercentage(token, state);
    case DimensionToken:
        return parseCalcDimension(token, state);
    default:
        break;
    }

    return std::nullopt;
}

std::optional<TypedChild> parseCalcKeyword(const CSSParserToken& token, ParserState& state)
{
    if (auto unit = state.parserOptions.allowedSymbols.get(token.id())) {
        auto child = Symbol { token.id(), *unit };
        auto type = Type::determineType(*unit);

        if (conversionToCanonicalUnitRequiresConversionData(*unit)) {
            if (state.propertyParserState.absoluteLengthUnitsOnly)
                return std::nullopt;
            state.requiresConversionData = true;
        }

        return makeSimplifiedTypedChild(WTF::move(child), type, state);
    }

    if (auto constant = lookupConstantNumber(token.id())) {
        auto [child, type] = *constant;
        return TypedChild { makeChild(WTF::move(child)), type };
    }

    return std::nullopt;
}

std::optional<TypedChild> parseCalcNumber(const CSSParserToken& token, ParserState&)
{
    auto child = Number { .value = token.numericValue() };
    auto type = Type { };

    return TypedChild { makeChild(WTF::move(child)), type };
}

std::optional<TypedChild> parseCalcPercentage(const CSSParserToken& token, ParserState& state)
{
    auto child = Percentage { .value = token.numericValue(), .hint = Type::determinePercentHint(state.parserOptions.category) };
    auto type = getType(child);

    return TypedChild { makeChild(WTF::move(child)), type };
}

std::optional<TypedChild> parseCalcDimension(const CSSParserToken& token, ParserState& state)
{
    if (token.unitType() == CSSUnitType::Unknown)
        return std::nullopt;

    auto child = makeNumeric(token.numericValue(), token.unitType());
    auto type = Type::determineType(token.unitType());

    if (conversionToCanonicalUnitRequiresConversionData(token.unitType())) {
        if (state.propertyParserState.absoluteLengthUnitsOnly)
            return std::nullopt;
        state.requiresConversionData = true;
    }

    // THE ONE SITE THAT STARTS FROM A FINISHED `Child`, so it cannot use the helper above:
    // `makeNumeric` has already built the leaf and what runs on it is the recursive
    // `copyAndSimplify(const Child&, ...)`, which for a dimension leaf is `canonicalize`.
    // Guarded in place rather than wrapped, because one site does not pay for a second helper.
#if CSS_CALC_CPP_SIMPLIFIER_COMPILED_IN
    if (auto* simplificationOptions = state.simplificationOptions)
        return TypedChild { copyAndSimplify(WTF::move(child), *simplificationOptions), type };
#endif
    return TypedChild { WTF::move(child), type };
}


// MARK: - The Swift parse path's token boundary (P7b stage C)

// The Swift-visible stand-in must be the size of the real member, or the two languages hold
// different views of one live object with no diagnostic. Only this branch can see
// `CSSParserTokenRange`, which is why the assert is here and not beside the declaration.
static_assert(sizeof(CSSCalcSwiftParseCursor) == sizeof(const CSSParserTokenRange*));

// The block types cross as a raw byte, so they are pinned one enumerator per line rather than
// trusted. Inserting one is an ordinary WebCore change whose author has no reason to know that a
// Swift grammar reads the numbering -- the same failure the tokenizer boundary's token-type
// static_asserts exist to prevent.
static_assert(static_cast<uint8_t>(CSSParserToken::NotBlock) == 0);
static_assert(static_cast<uint8_t>(CSSParserToken::BlockStart) == 1);
static_assert(static_cast<uint8_t>(CSSParserToken::BlockEnd) == 2);
// Swift's `calcFindBlockEnd` compares against these two values literally, so the asserts above are
// what keep the two sides in step; a renumbering fails the build rather than silently changing
// which token closes a block.

// `id` and `functionId` cross as raw `CSSValueID` values, and "absent" has to be a value Swift can
// test. `CSSParserToken::id()`/`functionId()` already return `CSSValueInvalid` for a token of the
// wrong type, and that is 0, so the boundary needs no separate presence flag.
static_assert(static_cast<uint16_t>(CSSValueInvalid) == 0);

// The alternative `makeNumeric` would build for `unit`, answered by CALLING `makeNumeric` rather
// than by re-deriving its seventy-case table -- the same argument `CSSCalcSwiftNumericResult::kind`
// already carries. Every numeric alternative is an inline variant member, so this allocates
// nothing, and the grammar calls it once per dimension leaf actually built rather than once per
// token walked past.
uint8_t cssCalcSwiftLeafKindForUnit(uint16_t unit) noexcept
{
    auto child = makeNumeric(0, static_cast<CSSUnitType>(unit));

    // Asked of the variant directly rather than through `swiftNodeInfo`, which is a 41-way
    // `WTF::switchOn` -- 43.1 retired instructions measured (`calcbench --primitives`, row
    // `read info() on a leaf`) -- on a path that can only ever produce four alternatives. This
    // duplicates no table: `makeNumeric` still owns the seventy-case unit classification and is
    // still the thing being asked; what changes is how its answer is read back. The four tests
    // below are a 1:1 correspondence between an alternative and the kind that names it, not a
    // mapping with content, and `pushLeaf` already switches on exactly these four.
    if (WTF::holdsAlternative<Number>(child))
        return static_cast<uint8_t>(CSSCalcSwiftNodeKind::Number);
    if (WTF::holdsAlternative<Percentage>(child))
        return static_cast<uint8_t>(CSSCalcSwiftNodeKind::Percentage);
    if (WTF::holdsAlternative<CanonicalDimension>(child))
        return static_cast<uint8_t>(CSSCalcSwiftNodeKind::CanonicalDimension);
    if (WTF::holdsAlternative<NonCanonicalDimension>(child))
        return static_cast<uint8_t>(CSSCalcSwiftNodeKind::NonCanonicalDimension);

    // `makeNumeric` produces nothing else for any unit reachable here -- the grammar rejects
    // `CSSUnitType::Unknown` before asking, and every other non-numeric unit reaches
    // `makeNumeric`'s own `ASSERT_NOT_REACHED`. Reported rather than guessed: `pushLeaf` treats a
    // kind outside the four as a contract violation, which is the correct outcome for a unit this
    // function cannot classify.
    return static_cast<uint8_t>(CSSCalcSwiftNodeKind::Operation);
}

CSSCalcSwiftNumericResult cssCalcSwiftLookupConstantNumber(uint16_t id) noexcept
{
    auto constant = lookupConstantNumber(static_cast<CSSValueID>(id));
    if (!constant)
        return { .value = 0, .unitType = static_cast<uint16_t>(CSSUnitType::Unknown), .resolved = false, .alternative = CSSCalcSwiftAlternative::Number, .substituteFallback = false };
    // Always a `Number` with an empty `Type` -- `lookupConstantNumber` builds exactly that.
    return {
        .value = constant->first.value,
        .unitType = static_cast<uint16_t>(CSSUnitType::Number),
        .resolved = true,
        .alternative = CSSCalcSwiftAlternative::Number,
        .substituteFallback = false,
    };
}

// The Swift grammar's depth limit must be the C++ one, or the two arms disagree about which deeply
// nested expressions parse -- a divergence no corpus of ordinary CSS would surface.
// Which alternative `makeNumeric` builds for `unit`, and whether the unit needs conversion data.
// Static so it is not a boundary entry point: both answers ride in `CSSCalcSwiftToken`'s padding
// now, so the grammar never calls this.
// NARROW VERSION, and the wide one is refuted. Filling `leafKind` here too -- i.e. calling
// `makeNumeric` from `tokenAt` -- measured WORSE by 403 instructions on the eight-term band and
// +0.037 on the mean, because `tokenAt` runs once per TOKEN and `makeNumeric` constructs and
// destroys a `Child`, so a per-leaf cost became a per-token-read one. Only the cheap answer rides
// here: `conversionToCanonicalUnitRequiresConversionData` is a plain switch over the unit.
static uint8_t cssCalcSwiftUnitFlagsFor(CSSUnitType unit) noexcept
{
    return conversionToCanonicalUnitRequiresConversionData(unit) ? cssCalcSwiftTokenUnitNeedsConversionData : 0;
}

// The cheap `FunctionToken` predicates, one bit each, in one pass: `tokenAt` runs once per TOKEN,
// so this is one call rather than three.
//
// WHICH math function it is does NOT ride here and used to: Swift now compares `functionId`
// against `CSSValueMin` itself, because `WebCore_Private.modulemap` lists CSSValueKeywords.h ahead
// of Core's umbrella and the enumerators therefore import.
static uint8_t cssCalcSwiftFunctionFlagsFor(CSSValueID functionId) noexcept
{
    uint8_t flags = 0;
    if (isCalcFunction(functionId))
        flags |= cssCalcSwiftTokenIsCalcFunction;
    if (functionId == CSSValueCalc || functionId == CSSValueWebkitCalc)
        flags |= cssCalcSwiftTokenIsPlainCalcFunction;
    return flags;
}

static_assert(maxExpressionDepth == 100);

uint32_t CSSCalcSwiftParseCursor::tokenCount() const noexcept
{
    return static_cast<uint32_t>(m_range.size());
}

CSSCalcSwiftToken CSSCalcSwiftParseCursor::tokenAt(uint32_t index) const noexcept
{
    // Past the end this is the EOF token, which is what `CSSParserTokenRange::peek` returns and
    // what the C++ grammar relies on, so the Swift grammar needs no bounds pre-check to behave
    // identically.
    auto& token = m_range.peek(index);
    auto type = token.type();

    // THE TWO GUARDS ARE LOAD-BEARING, not defensive style. `CSSParserToken::numericValue()` and
    // `delimiter()` each ASSERT on a token of the wrong type (CSSParserToken.cpp:487, :467), and
    // this boundary reads every field of every token unconditionally -- so an unguarded version
    // compiles, passes every release test, and fires on the first whitespace token in any
    // assertions build. The other four accessors are total: `id()`/`functionId()` return
    // `CSSValueInvalid` for the wrong type, `unitType()` and `getBlockType()` are plain bitfield
    // reads.
    bool isNumeric = type == NumberToken || type == PercentageToken || type == DimensionToken;

    // Filled only for a DimensionToken: `makeNumeric` is not free, and running it for every
    // whitespace token and operator would cost more than the two crossings this saves.
    uint8_t flags = 0;
    if (type == DimensionToken)
        flags = cssCalcSwiftUnitFlagsFor(token.unitType());
    else if (type == FunctionToken)
        flags = cssCalcSwiftFunctionFlagsFor(token.functionId());

    return {
        .numericValue = isNumeric ? token.numericValue() : 0,
        .id = static_cast<uint16_t>(token.id()),
        .functionId = static_cast<uint16_t>(token.functionId()),
        .delimiter = type == DelimiterToken ? token.delimiter() : u'\0',
        .unit = token.unitType(),
        .type = type,
        .blockType = static_cast<uint8_t>(token.getBlockType()),
        .flags = flags,
    };
}

// MARK: - The Swift calc STORE (P7c slice C1)

WTF_MAKE_TZONE_ALLOCATED_IMPL(CSSCalcSwiftFlatStore);

CSSCalcSwiftFlatStore::CSSCalcSwiftFlatStore() = default;
CSSCalcSwiftFlatStore::~CSSCalcSwiftFlatStore() = default;

Ref<CSSCalcSwiftFlatStore> CSSCalcSwiftFlatStore::create()
{
    return adoptRef(*new CSSCalcSwiftFlatStore);
}

size_t CSSCalcSwiftFlatStore::takeNodes(const CSSCalcSwiftFlatNode* __counted_by(nodeCount) nodes __attribute__((noescape)), size_t nodeCount, uint32_t rootIndex) noexcept
{
    // `Vector::appendRange` on an empty vector allocates exactly `nodeCount` slots: ONE malloc for
    // the whole tree, where the `Child` form allocates one `makeUniqueRef<Op>` plus one `Children`
    // vector per operator node. Assigning rather than appending, because a store is filled once.
    m_nodes = Vector<CSSCalcSwiftFlatNode>(unsafeMakeSpan(nodes, nodeCount));
    m_rootIndex = rootIndex;
    return m_nodes.size();
}

CSSCalcSwiftFlatNode CSSCalcSwiftFlatStore::nodeAt(uint32_t index) const noexcept
{
    // Out of range answers a terminated node rather than trapping, matching what
    // `CSSCalcSwiftParseCursor::tokenAt` does past the end: the caller is a Swift walk whose
    // termination condition is the sentinel, so handing it the sentinel makes the walk stop where
    // a bounds pre-check on the Swift side would have stopped it, and does so without Swift having
    // to mirror a bound it cannot see.
    if (index >= m_nodes.size()) {
        return {
            .value = 0,
            .type = { },
            .firstChild = cssCalcSwiftFlatNoNode,
            .nextSibling = cssCalcSwiftFlatNoNode,
            .childCount = 0,
            .origin = cssCalcSwiftFlatNoNode,
            .valueID = 0,
            .unitType = 0,
            .alternative = CSSCalcSwiftAlternative::Number,
            .percentHint = 0,
            .flags = 0,
        };
    }
    return m_nodes[index];
}

} // namespace CSSCalc
} // namespace WebCore
