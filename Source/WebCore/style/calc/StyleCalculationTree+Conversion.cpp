/*
 * Copyright (C) 2024 Samuel Weinig <sam@webkit.org>
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
#include "StyleCalculationTree+Conversion.h"

#include "CSSCalcExecutor.h"
#include "CSSCalcRandomCachingKey.h"
#include "CSSCalcSymbolTable.h"
#include "CSSCalcTree+Evaluation.h"
#include "CSSCalcTree+Mappings.h"
#include "CSSCalcTree+Simplification.h"
#include "CSSCalcTree+Traversal.h"
#include "CSSCalcTree.h"
#include "CSSPrimitiveNumericCategory.h"
#include "CSSUnevaluatedCalc.h"
#include "StyleBuilderState.h"
#include "StyleCalculationTree.h"
#include "StyleLengthResolution.h"
#include "StylePrimitiveNumericTypes+Conversions.h"
#include <wtf/MathExtras.h>
#include <wtf/StdLibExtras.h>
#if USE(SWIFT_CSS)
#include "WebCoreSwiftBoundaryTypes.h"
#endif

// Whether the C++ conversion of a `CSSCalc::Tree` into a `Style::Calculation::Tree` is compiled in:
// exactly when the Swift CSS implementation is not. The conversion in the other direction, `toCSS`,
// is C++ in both builds.
#if USE(SWIFT_CSS)
#define STYLE_CALC_CPP_TO_STYLE_COMPILED_IN 0
#else
#define STYLE_CALC_CPP_TO_STYLE_COMPILED_IN 1
#endif

namespace WebCore {
namespace Style {
namespace Calculation {

struct ToCSSConversionOptions {
    CSSCalc::CanonicalDimension::Dimension canonicalDimension;
    CSSCalc::SimplificationOptions simplification;
};

#if STYLE_CALC_CPP_TO_STYLE_COMPILED_IN
struct ToStyleConversionOptions {
    CSSCalc::EvaluationOptions evaluation;
};
#endif

static auto toCSS(const Random::Fixed&, const ToCSSConversionOptions&) -> CSSCalc::Random::Sharing;
static auto toCSS(const CSS::Keyword::None&, const ToCSSConversionOptions&) -> CSS::Keyword::None;
static auto toCSS(const CalcMix::Item&, const ToCSSConversionOptions&) -> CSSCalc::CalcMix::Item;
static auto toCSS(const Vector<CalcMix::Item>&, const ToCSSConversionOptions&) -> Vector<CSSCalc::CalcMix::Item>;
static auto toCSS(const ChildOrNone&, const ToCSSConversionOptions&) -> CSSCalc::ChildOrNone;
static auto toCSS(const Children&, const ToCSSConversionOptions&) -> CSSCalc::Children;
static auto toCSS(const std::optional<Child>&, const ToCSSConversionOptions&) -> std::optional<CSSCalc::Child>;
static auto toCSS(const Child&, const ToCSSConversionOptions&) -> CSSCalc::Child;
static auto toCSS(const Number&, const ToCSSConversionOptions&) -> CSSCalc::Child;
static auto toCSS(const Percentage&, const ToCSSConversionOptions&) -> CSSCalc::Child;
static auto toCSS(const Dimension&, const ToCSSConversionOptions&) -> CSSCalc::Child;
static auto toCSS(const Size&, const ToCSSConversionOptions&) -> CSSCalc::Child;
template<typename CalculationOp> auto toCSS(const IndirectNode<CalculationOp>&, const ToCSSConversionOptions&) -> CSSCalc::Child;

static auto resolveRandomFixed(const CSSCalc::Random::Sharing&, const CSSToLengthConversionData&) -> Random::Fixed;
static auto resolveCalcMixWeight(const CSSCalc::CalcMix::Item::Weight&, const CSSToLengthConversionData&) -> double;

#if STYLE_CALC_CPP_TO_STYLE_COMPILED_IN
static auto toStyle(const CSSCalc::Random::Sharing&, const ToStyleConversionOptions&) -> Random::Fixed;
static auto toStyle(const std::optional<CSSCalc::Child>&, const ToStyleConversionOptions&) -> std::optional<Child>;
static auto toStyle(const CSS::Keyword::None&, const ToStyleConversionOptions&) -> CSS::Keyword::None;
static auto toStyle(const CSSCalc::CalcMix::Item&, const ToStyleConversionOptions&) -> CalcMix::Item;
static auto toStyle(const Vector<CSSCalc::CalcMix::Item>&, const ToStyleConversionOptions&) -> Vector<CalcMix::Item>;
static auto toStyle(const CSSCalc::ChildOrNone&, const ToStyleConversionOptions&) -> ChildOrNone;
static auto toStyle(const CSSCalc::Children&, const ToStyleConversionOptions&) -> Children;
static auto toStyle(const CSSCalc::Child&, const ToStyleConversionOptions&) -> Child;
static auto toStyle(const CSSCalc::Number&, const ToStyleConversionOptions&) -> Child;
static auto toStyle(const CSSCalc::Percentage&, const ToStyleConversionOptions&) -> Child;
static auto toStyle(const CSSCalc::CanonicalDimension&, const ToStyleConversionOptions&) -> Child;
static auto toStyle(const CSSCalc::NonCanonicalDimension&, const ToStyleConversionOptions&) -> Child;
static auto toStyle(const CSSCalc::Symbol&, const ToStyleConversionOptions&) -> Child;
static auto toStyle(const CSSCalc::SiblingCount&, const ToStyleConversionOptions&) -> Child;
static auto toStyle(const CSSCalc::SiblingIndex&, const ToStyleConversionOptions&) -> Child;
static auto toStyle(const CSSCalc::IndirectNode<CSSCalc::Anchor>&, const ToStyleConversionOptions&) -> Child;
static auto toStyle(const CSSCalc::IndirectNode<CSSCalc::AnchorSize>&, const ToStyleConversionOptions&) -> Child;
static auto toStyle(const CSSCalc::IndirectNode<CSSCalc::Deg2Rad>&, const ToStyleConversionOptions&) -> Child;
template<typename Op> auto toStyle(const CSSCalc::IndirectNode<Op>&, const ToStyleConversionOptions&) -> Child;
#endif

static CSSCalc::CanonicalDimension::Dimension NODELETE determineCanonicalDimension(CSS::Category category)
{
    switch (category) {
    case CSS::Category::LengthPercentage:
        return CSSCalc::CanonicalDimension::Dimension::Length;

    case CSS::Category::AnglePercentage:
        return CSSCalc::CanonicalDimension::Dimension::Angle;

    case CSS::Category::Integer:
    case CSS::Category::Number:
    case CSS::Category::Percentage:
    case CSS::Category::Length:
    case CSS::Category::Angle:
    case CSS::Category::Time:
    case CSS::Category::Frequency:
    case CSS::Category::Resolution:
    case CSS::Category::Flex:
        break;
    }

    ASSERT_NOT_REACHED();
    return CSSCalc::CanonicalDimension::Dimension::Length;
}

// MARK: - From

CSSCalc::Random::Sharing toCSS(const Random::Fixed& randomFixed, const ToCSSConversionOptions&)
{
    return CSSCalc::Random::SharingFixed { randomFixed.baseValue };
}

CSS::Keyword::None NODELETE toCSS(const CSS::Keyword::None& none, const ToCSSConversionOptions&)
{
    return none;
}

CSSCalc::CalcMix::Item toCSS(const CalcMix::Item& item, const ToCSSConversionOptions& options)
{
    return { .value = toCSS(item.value, options), .weight = CSSCalc::CalcMix::Item::Weight { item.weight } };
}

Vector<CSSCalc::CalcMix::Item> toCSS(const Vector<CalcMix::Item>& items, const ToCSSConversionOptions& options)
{
    return WTF::map(items, [&](const auto& item) { return toCSS(item, options); });
}

CSSCalc::ChildOrNone toCSS(const ChildOrNone& root, const ToCSSConversionOptions& options)
{
    return WTF::switchOn(root, [&](const auto& root) { return CSSCalc::ChildOrNone { toCSS(root, options) }; });
}

CSSCalc::Children toCSS(const Children& children, const ToCSSConversionOptions& options)
{
    return WTF::map(children.value, [&](const auto& child) -> CSSCalc::Child { return toCSS(child, options); });
}

std::optional<CSSCalc::Child> toCSS(const std::optional<Child>& root, const ToCSSConversionOptions& options)
{
    if (root)
        return toCSS(*root, options);
    return std::nullopt;
}

CSSCalc::Child toCSS(const Child& root, const ToCSSConversionOptions& options)
{
    return WTF::switchOn(root, [&](const auto& root) { return toCSS(root, options); });
}

CSSCalc::Child toCSS(const Number& number, const ToCSSConversionOptions&)
{
    return CSSCalc::makeChild(CSSCalc::Number { .value = number.value });
}

CSSCalc::Child toCSS(const Percentage& percentage, const ToCSSConversionOptions& options)
{
    return CSSCalc::makeChild(CSSCalc::Percentage { .value = percentage.value, .hint = CSSCalc::Type::determinePercentHint(options.simplification.category) });
}

CSSCalc::Child toCSS(const Size&, const ToCSSConversionOptions&)
{
    return CSSCalc::makeChild(CSSCalc::Symbol { .id = CSSValueSize, .unit = CSSUnitType::Px });
}

CSSCalc::Child toCSS(const Dimension& root, const ToCSSConversionOptions& options)
{
    return CSSCalc::makeChild(CSSCalc::CanonicalDimension { .value = root.value, .dimension = options.canonicalDimension });
}

template<typename CalculationOp> CSSCalc::Child toCSS(const IndirectNode<CalculationOp>& root, const ToCSSConversionOptions& options)
{
    using CalcOp = CSSCalc::ToCalcTreeOp<CalculationOp>;

    auto op = WTF::apply([&](const auto& ...x) { return CalcOp { toCSS(x, options)... }; } , *root);

    // Not simplified here: `toCSS(const Tree&)` below runs one whole-tree `copyAndSimplify`
    // instead, as `toStyle` does in the other direction.
    auto type = toType(op);
    ASSERT(type);
    return CSSCalc::makeChild(WTF::move(op), *type);
}

// MARK: - To.

auto resolveRandomFixed(const CSSCalc::Random::Sharing& randomSharing, const CSSToLengthConversionData& conversionData) -> Random::Fixed
{
    ASSERT(conversionData.styleBuilderState());

    if (auto* sharingFixed = std::get_if<CSSCalc::Random::SharingFixed>(&randomSharing)) {
        return WTF::switchOn(sharingFixed->value,
            [&](const CSS::Number<CSS::ClosedUnitRange>::Raw& raw) -> Random::Fixed {
                return Random::Fixed { raw.value };
            },
            [&](const CSS::Number<CSS::ClosedUnitRange>::Calc& calc) -> Random::Fixed {
                return Random::Fixed { calc.evaluate(*protect(conversionData.styleBuilderState())) };
            }
        );
    }

    // resolveRandomBaseValue only returns nullopt for element-scoped sharing with no element, which does not
    // happen during element style building. Assert the invariant rather than letting a future violation
    // silently resolve to min.
    CheckedPtr builderState = conversionData.styleBuilderState();
    auto baseValue = resolveRandomBaseValue(randomSharing, *builderState);
    ASSERT(baseValue);
    return Random::Fixed { baseValue.value_or(0) };
}

auto resolveCalcMixWeight(const CSSCalc::CalcMix::Item::Weight& weight, const CSSToLengthConversionData& conversionData) -> double
{
    ASSERT(conversionData.styleBuilderState());

    return Style::toStyle(weight, *protect(conversionData.styleBuilderState())).value;
}

#if STYLE_CALC_CPP_TO_STYLE_COMPILED_IN
auto toStyle(const CSSCalc::Random::Sharing& randomSharing, const ToStyleConversionOptions& options) -> Random::Fixed
{
    ASSERT(options.evaluation.conversionData);
    return resolveRandomFixed(randomSharing, *options.evaluation.conversionData);
}

std::optional<Child> toStyle(const std::optional<CSSCalc::Child>& optionalChild, const ToStyleConversionOptions& options)
{
    if (optionalChild)
        return toStyle(*optionalChild, options);
    return std::nullopt;
}

CSS::Keyword::None NODELETE toStyle(const CSS::Keyword::None& none, const ToStyleConversionOptions&)
{
    return none;
}

CalcMix::Item toStyle(const CSSCalc::CalcMix::Item& item, const ToStyleConversionOptions& options)
{
    ASSERT(options.evaluation.conversionData);
    ASSERT(item.weight);
    auto resolvedWeight = resolveCalcMixWeight(*item.weight, *options.evaluation.conversionData);
    return { .value = toStyle(item.value, options), .weight = resolvedWeight };
}

Vector<CalcMix::Item> toStyle(const Vector<CSSCalc::CalcMix::Item>& items, const ToStyleConversionOptions& options)
{
    return WTF::map(items, [&](const auto& item) { return toStyle(item, options); });
}

ChildOrNone toStyle(const CSSCalc::ChildOrNone& root, const ToStyleConversionOptions& options)
{
    return WTF::switchOn(root, [&](const auto& root) { return ChildOrNone { toStyle(root, options) }; });
}

Children toStyle(const CSSCalc::Children& children, const ToStyleConversionOptions& options)
{
    return WTF::map(children, [&](const auto& child) { return toStyle(child, options); });
}

Child toStyle(const CSSCalc::Child& root, const ToStyleConversionOptions& options)
{
    return WTF::switchOn(root, [&](const auto& root) { return toStyle(root, options); });
}

Child toStyle(const CSSCalc::Number& root, const ToStyleConversionOptions&)
{
    return number(root.value);
}

Child toStyle(const CSSCalc::Percentage& root, const ToStyleConversionOptions&)
{
    return percentage(root.value);
}

Child toStyle(const CSSCalc::CanonicalDimension& root, const ToStyleConversionOptions& options)
{
    switch (root.dimension) {
    case CSSCalc::CanonicalDimension::Dimension::Length:
        if (options.evaluation.conversionData)
            return dimension(resolveLength(root.value, CSS::LengthUnit::Px, *options.evaluation.conversionData));
        return dimension(resolveLength(root.value, CSS::LengthUnit::Px, NoConversionDataRequiredToken { }));

    case CSSCalc::CanonicalDimension::Dimension::Angle:
    case CSSCalc::CanonicalDimension::Dimension::Time:
    case CSSCalc::CanonicalDimension::Dimension::Frequency:
    case CSSCalc::CanonicalDimension::Dimension::Resolution:
    case CSSCalc::CanonicalDimension::Dimension::Flex:
        break;
    }

    return dimension(root.value);
}

Child toStyle(const CSSCalc::NonCanonicalDimension&, const ToStyleConversionOptions&)
{
    ASSERT_NOT_REACHED("Non-canonical numeric values are not supported in the Tree");
    return number(0);
}

Child toStyle(const CSSCalc::Symbol& root, const ToStyleConversionOptions&)
{
    // `size` is the one symbol the Tree can hold, since it resolves at used value time rather than
    // during conversion.
    if (root.id == CSSValueSize)
        return Size { };

    ASSERT_NOT_REACHED("Unevaluated symbols are not supported in the Tree");
    return number(0);
}

Child toStyle(const CSSCalc::SiblingCount&, const ToStyleConversionOptions&)
{
    ASSERT_NOT_REACHED("Unevaluated sibling-count() functions are not supported in the Tree");
    return number(0);
}

Child toStyle(const CSSCalc::SiblingIndex&, const ToStyleConversionOptions&)
{
    ASSERT_NOT_REACHED("Unevaluated sibling-index() functions are not supported in the Tree");
    return number(0);
}

Child toStyle(const CSSCalc::IndirectNode<CSSCalc::Anchor>&, const ToStyleConversionOptions&)
{
    ASSERT_NOT_REACHED("Unevaluated anchor() functions are not supported in the Tree");
    return number(0);
}

Child toStyle(const CSSCalc::IndirectNode<CSSCalc::AnchorSize>&, const ToStyleConversionOptions&)
{
    ASSERT_NOT_REACHED("Unevaluated anchor-size() functions are not supported in the Tree");
    return number(0);
}

Child toStyle(const CSSCalc::IndirectNode<CSSCalc::Deg2Rad>& root, const ToStyleConversionOptions& options)
{
    // Style::Calculation::Tree has no Deg2Rad node, so express it as a multiplication by the
    // radians-per-degree constant.
    return multiply(toStyle(root->angle, options), number(radiansPerDegreeDouble));
}

template<typename Op> Child toStyle(const CSSCalc::IndirectNode<Op>& root, const ToStyleConversionOptions& options)
{
    using CalculationOp = CSSCalc::ToCalculationTreeOp<Op>;

    return makeChild(WTF::apply([&](const auto& ...x) { return CalculationOp { toStyle(x, options)... }; } , *root));
}
#endif // STYLE_CALC_CPP_TO_STYLE_COMPILED_IN

} // namespace Calculation
} // namespace Style

#if USE(SWIFT_CSS)
namespace CSSCalc {

// MARK: - The Swift conversion's builder (CSSCalcSimplificationSwift.swift, `cssCalcToStyleSwift`)

struct CSSCalcSwiftStyleOperands {
    Vector<Style::Calculation::Child, 16> value;
    // Resolved before an operation's operands are converted and consumed when it is built, so both
    // are stacks: a nested `random()` or `calc-mix()` pushes and consumes its own inside its parent's.
    Vector<Style::Calculation::Random::Fixed> randomBaseValues;
    Vector<double> calcMixWeights;
};

void CSSCalcSwiftStyleBuilder::pushNumber(double value) noexcept
{
    m_operands->value.append(Style::Calculation::number(value));
}

void CSSCalcSwiftStyleBuilder::pushPercentage(double value) noexcept
{
    m_operands->value.append(Style::Calculation::percentage(value));
}

void CSSCalcSwiftStyleBuilder::pushCanonicalDimension(double value, uint16_t unitType) noexcept
{
    if (static_cast<CSSUnitType>(unitType) == toCSSUnit(CanonicalDimension::Dimension::Length)) {
        if (m_options->conversionData)
            value = Style::resolveLength(value, CSS::LengthUnit::Px, *m_options->conversionData);
        else
            value = Style::resolveLength(value, CSS::LengthUnit::Px, NoConversionDataRequiredToken { });
    }
    m_operands->value.append(Style::Calculation::dimension(value));
}

void CSSCalcSwiftStyleBuilder::pushSize() noexcept
{
    m_operands->value.constructAndAppend(Style::Calculation::Size { });
}

// The conversion's own preconditions: a tree reaches it only after `copyAndSimplify` with a style
// builder state, and a `calc-mix()` that survives that has a weight on every item.
void CSSCalcSwiftStyleBuilder::pushRandomBaseValue(uint32_t payload) noexcept
{
    RELEASE_ASSERT(m_options->conversionData);
    m_operands->randomBaseValues.append(Style::Calculation::resolveRandomFixed(storedPayload<Random::Sharing>(m_payloads, payload), *m_options->conversionData));
}

void CSSCalcSwiftStyleBuilder::pushCalcMixItemWeight(double value, bool present, uint32_t payload) noexcept
{
    RELEASE_ASSERT(present && m_options->conversionData);
    auto weight = payload == cssCalcSwiftFlatNoNode ? CalcMix::Item::Weight { value } : storedPayload<CalcMix::Item::Weight>(m_payloads, payload);
    m_operands->calcMixWeights.append(Style::Calculation::resolveCalcMixWeight(weight, *m_options->conversionData));
}

// The operands of one operation, taken in slot order. Each slot shape of a `Style::Calculation`
// operation has one overload, so an operation with a new shape fails to compile here.
struct StyleSlotCursor {
    CSSCalcSwiftStyleOperands& operands;
    size_t next;
    size_t end;
    size_t weightBase;
    uint8_t noneMask;
    uint8_t boundIndex { 0 };
    bool ok { true };

    Style::Calculation::Child take()
    {
        if (next >= end) {
            ok = false;
            return Style::Calculation::number(0);
        }
        return WTF::move(operands.value[next++]);
    }

    Style::Calculation::Child slot(std::type_identity<Style::Calculation::Child>) { return take(); }

    // Present exactly when an operand remains: `round()`, `log()` and `random()` have it last.
    std::optional<Style::Calculation::Child> slot(std::type_identity<std::optional<Style::Calculation::Child>>)
    {
        if (next >= end)
            return std::nullopt;
        return take();
    }

    // `clamp()`'s two bounds, in order: bit 0 of `noneMask` is the first, bit 1 the second.
    Style::Calculation::ChildOrNone slot(std::type_identity<Style::Calculation::ChildOrNone>)
    {
        if (noneMask & (1 << boundIndex++))
            return CSS::Keyword::None { };
        return take();
    }

    Style::Calculation::Children slot(std::type_identity<Style::Calculation::Children>)
    {
        Vector<Style::Calculation::Child> children;
        children.reserveInitialCapacity(end - next);
        for (; next < end; ++next)
            children.append(WTF::move(operands.value[next]));
        return Style::Calculation::Children { WTF::move(children) };
    }

    Style::Calculation::Random::Fixed slot(std::type_identity<Style::Calculation::Random::Fixed>)
    {
        if (operands.randomBaseValues.isEmpty()) {
            ok = false;
            return { 0 };
        }
        return operands.randomBaseValues.takeLast();
    }

    Vector<Style::Calculation::CalcMix::Item> slot(std::type_identity<Vector<Style::Calculation::CalcMix::Item>>)
    {
        size_t count = end - next;
        if (operands.calcMixWeights.size() - weightBase != count) {
            ok = false;
            return { };
        }
        Vector<Style::Calculation::CalcMix::Item> items(count, [&](size_t i) {
            return Style::Calculation::CalcMix::Item { .value = take(), .weight = operands.calcMixWeights[weightBase + i] };
        });
        operands.calcMixWeights.shrink(weightBase);
        return items;
    }
};

template<typename Op>
concept HasStyleCalculationOp = requires {
    typename ToCalculationTreeOp<Op>;
};

bool CSSCalcSwiftStyleBuilder::buildOperation(CSSCalcSwiftAlternative alternative, uint32_t childCount, uint8_t noneMask) noexcept
{
    auto& stack = m_operands->value;
    if (childCount > stack.size())
        return false;
    size_t base = stack.size() - childCount;

    // Instantiated for every alternative, and refusing the ones with no style operation: the leaves,
    // `Deg2Rad` and the two anchor functions.
    auto build = [&]<typename CalcOp>() -> bool {
        if constexpr (!HasStyleCalculationOp<CalcOp>)
            return false;
        else {
            using StyleOp = ToCalculationTreeOp<CalcOp>;
            auto& weights = m_operands->calcMixWeights;
            StyleSlotCursor cursor { .operands = *m_operands, .next = base, .end = stack.size(), .weightBase = weights.size() >= childCount ? weights.size() - childCount : 0, .noneMask = noneMask };
            // Braced initialisation evaluates left to right, so slot order is operand order.
            auto op = [&]<size_t... I>(std::index_sequence<I...>) {
                return StyleOp { cursor.slot(std::type_identity<std::remove_cvref_t<std::tuple_element_t<I, StyleOp>>> { })... };
            }(std::make_index_sequence<std::tuple_size_v<StyleOp>> { });
            if (!cursor.ok || cursor.next != cursor.end)
                return false;
            stack.shrink(base);
            stack.append(Style::Calculation::makeChild(WTF::move(op)));
            return true;
        }
    };

    switch (alternative) {
#define CSS_CALC_SWIFT_BUILD_STYLE_OPERATION(name, type) \
    case CSSCalcSwiftAlternative::name: \
        return build.operator()<name>();
        CSS_CALC_SWIFT_FOR_EACH_ALTERNATIVE(CSS_CALC_SWIFT_BUILD_STYLE_OPERATION)
#undef CSS_CALC_SWIFT_BUILD_STYLE_OPERATION
    }
    return false;
}

} // namespace CSSCalc
#endif // USE(SWIFT_CSS)

namespace Style {
namespace Calculation {

// MARK: - Exposed functions

CSSCalc::Tree toCSS(const Tree& tree, const ToCSSOptions& toCSSOptions)
{
    auto conversionOptions = ToCSSConversionOptions {
        .canonicalDimension = determineCanonicalDimension(toCSSOptions.category),
        .simplification = CSSCalc::SimplificationOptions {
            .category = toCSSOptions.category,
            .range = toCSSOptions.range,
            .conversionData = std::nullopt,
            .symbolTable = { },
            .allowZeroValueLengthRemovalFromSum = true,
        },
    };

    auto converted = CSSCalc::makeTree(toCSS(tree.root, conversionOptions), CSSCalc::Type { }, CSSCalc::Stage::Computed);

    // The finished tree is simplified once. `.conversionData` is `std::nullopt` above, so nothing is
    // canonicalised; what is left is folding, which `copyAndSimplify` does bottom-up.
    auto simplified = CSSCalc::copyAndSimplify(converted, conversionOptions.simplification);

    // Taken from the simplified root: `copyAndSimplify` copies `Tree::type` through unchanged, so
    // reading it off `converted` would give the type of the unfolded tree.
    simplified.type = simplified.rootType();
    return simplified;
}

Tree toStyle(const CSSCalc::Tree& tree, const ToStyleOptions& toStyleOptions)
{
    ASSERT(toStyleOptions.category == CSS::Category::LengthPercentage || toStyleOptions.category == CSS::Category::AnglePercentage);

    auto simplificationOptions = CSSCalc::SimplificationOptions {
        .category = toStyleOptions.category,
        .range = toStyleOptions.range,
        .conversionData = toStyleOptions.conversionData,
        .symbolTable = toStyleOptions.symbolTable,
        .allowZeroValueLengthRemovalFromSum = true,
    };
    auto simplifiedTree = CSSCalc::copyAndSimplify(tree, simplificationOptions);

#if STYLE_CALC_CPP_TO_STYLE_COMPILED_IN
    auto conversionOptions = ToStyleConversionOptions {
        .evaluation = CSSCalc::EvaluationOptions {
            .category = toStyleOptions.category,
            .range = toStyleOptions.range,
            .conversionData = toStyleOptions.conversionData,
            .symbolTable = toStyleOptions.symbolTable,
        }
    };
    return Tree { toStyle(simplifiedTree.root, conversionOptions) };
#else
    CSSCalc::CSSCalcSwiftStyleOperands operands;
    CSSCalc::CSSCalcSwiftStyleBuilder builder { operands, simplificationOptions, simplifiedTree.stored.payloads() };
    bool built = WebCore::cssCalcToStyleSwift(simplifiedTree.stored.root(), builder);
    // There is no C++ conversion in this build to fall back to, and a `Tree` has no empty state.
    RELEASE_ASSERT_WITH_MESSAGE(built && operands.value.size() == 1 && operands.randomBaseValues.isEmpty() && operands.calcMixWeights.isEmpty(), "the Swift calc() conversion to a style tree failed");
    return Tree { operands.value.takeLast() };
#endif
}

} // namespace Calculation
} // namespace Style
} // namespace WebCore
