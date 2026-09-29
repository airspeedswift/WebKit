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
#include "CSSCalcTree+Simplification.h"

#include "AnchorPositionEvaluator.h"
#include "CSSCalcExecutor.h"
#include "CSSCalcRandomCachingKey.h"
#include "CSSCalcSwiftTypes.h"
#include "CSSCalcSymbolTable.h"
#include "CSSCalcSymbolsAllowed.h"
#include "CSSCalcTree+Copy.h"
#include "CSSCalcTree+Evaluation.h"
#include "CSSCalcTree+Mappings.h"
#include "CSSCalcTree+NumericIdentity.h"
#include "CSSCalcTree+Traversal.h"
#include "CSSCalcTree.h"
#include "CSSNormalizedMixPercentages.h"
#include "CSSPrimitiveNumericCategory.h"
#include "CSSPrimitiveValue.h"
#include "CSSPropertyParserState.h"
#include "CSSRandomKeyParser.h"
#include "CSSUnevaluatedCalc.h"
#include "StyleBuilderState.h"
#include "StyleComputedStyle+GettersInlines.h"
#include "StyleLengthResolution.h"
// WebCoreSwift-Generated.h is module-scoped, so a translation unit that includes it must declare
// every Swift boundary type.
#if USE(SWIFT_CSS)
#include "WebCoreSwiftBoundaryTypes.h"
#endif
#include <wtf/StdLibExtras.h>
#include <wtf/ZippedRange.h>

namespace WebCore {
namespace CSSCalc {

// The C++ simplifier: the per-operation `simplify` overloads and the recursive
// `copyAndSimplify(const Child&)`. See `CSS_CALC_CPP_SIMPLIFIER_COMPILED_IN` for what stays compiled
// without it.
#if CSS_CALC_CPP_SIMPLIFIER_COMPILED_IN
static auto copyAndSimplify(const Random::Sharing&, const SimplificationOptions&) -> Random::Sharing;
static auto copyAndSimplify(const CalcMix::Item&, const SimplificationOptions&) -> CalcMix::Item;
static auto copyAndSimplify(const Vector<CalcMix::Item>&, const SimplificationOptions&) -> Vector<CalcMix::Item>;
static auto copyAndSimplify(const CSS::Keyword::None&, const SimplificationOptions&) -> CSS::Keyword::None;
static auto copyAndSimplify(const Children&, const SimplificationOptions&) -> Children;
static auto copyAndSimplify(const ChildOrNone&, const SimplificationOptions&) -> ChildOrNone;
template<typename T>
static auto copyAndSimplify(const std::optional<T>&, const SimplificationOptions&) -> std::optional<T>;
#endif // CSS_CALC_CPP_SIMPLIFIER_COMPILED_IN

#if CSS_CALC_CPP_SIMPLIFIER_COMPILED_IN
template<typename Op, typename... Args> static double executeMathOperation(Args&&... args)
{
    return executeOperation<ToCalculationTreeOp<Op>::op>(std::forward<Args>(args)...);
}

template<typename... F> static decltype(auto) switchTogether(const Child& a, const Child& b, NOESCAPE F&&... f)
{
    auto visitor = WTF::makeVisitor(std::forward<F>(f)...);
    using ResultType = decltype(visitor(std::declval<Number>(), std::declval<Number>()));

    if (a.index() != b.index())
        return visitor(std::nullopt, std::nullopt);

    return WTF::switchOn(a,
        [&]<typename T>(const T& aT) -> ResultType {
            return visitor(aT, get<T>(b));
        }
    );
}
#endif // CSS_CALC_CPP_SIMPLIFIER_COMPILED_IN

// MARK: Predicate: percentageResolveToDimension

static bool NODELETE percentageResolveToDimension(const SimplificationOptions& options)
{
    switch (options.category) {
    case CSS::Category::Integer:
    case CSS::Category::Number:
    case CSS::Category::Length:
    case CSS::Category::Percentage:
    case CSS::Category::Angle:
    case CSS::Category::Time:
    case CSS::Category::Frequency:
    case CSS::Category::Resolution:
    case CSS::Category::Flex:
        return false;

    case CSS::Category::AnglePercentage:
    case CSS::Category::LengthPercentage:
        return true;
    }

    ASSERT_NOT_REACHED();
    return false;
}

#if CSS_CALC_CPP_SIMPLIFIER_COMPILED_IN
// MARK: Predicate: unitsMatch

constexpr bool NODELETE unitsMatch(const Number&, const Number&, const SimplificationOptions&)
{
    return true;
}

constexpr bool NODELETE unitsMatch(const Percentage&, const Percentage&, const SimplificationOptions&)
{
    return true;
}

static bool NODELETE unitsMatch(const CanonicalDimension& a, const CanonicalDimension& b, const SimplificationOptions&)
{
    return a.dimension == b.dimension;
}

static bool NODELETE unitsMatch(const NonCanonicalDimension& a, const NonCanonicalDimension& b, const SimplificationOptions&)
{
    return a.unit == b.unit;
}

// MARK: Predicate: magnitudeComparable

constexpr bool NODELETE magnitudeComparable(const Number&, const SimplificationOptions&)
{
    return true;
}

static bool NODELETE magnitudeComparable(const Percentage&, const SimplificationOptions& options)
{
    return !percentageResolveToDimension(options);
}

constexpr bool NODELETE magnitudeComparable(const CanonicalDimension&, const SimplificationOptions&)
{
    return true;
}

constexpr bool NODELETE magnitudeComparable(const NonCanonicalDimension&, const SimplificationOptions&)
{
    return true;
}

// MARK: Predicate: fullyResolved

constexpr bool NODELETE fullyResolved(const Number&, const SimplificationOptions&)
{
    return true;
}

static bool NODELETE fullyResolved(const Percentage&, const SimplificationOptions& options)
{
    return !percentageResolveToDimension(options);
}

constexpr bool NODELETE fullyResolved(const CanonicalDimension&, const SimplificationOptions&)
{
    return true;
}

constexpr bool NODELETE fullyResolved(const NonCanonicalDimension&, const SimplificationOptions&)
{
    return false;
}
#endif // CSS_CALC_CPP_SIMPLIFIER_COMPILED_IN

std::optional<CanonicalDimension> canonicalize(NonCanonicalDimension root, const std::optional<CSSToLengthConversionData>& conversionData)
{
    auto makeCanonical = [&](double value, CanonicalDimension::Dimension dimension) -> std::optional<CanonicalDimension> {
        return CanonicalDimension { .value = value, .dimension = dimension };
    };

    auto tryMakeCanonical = [&](double value, CSS::LengthUnit lengthUnit) -> std::optional<CanonicalDimension> {
        if (conversionData)
            return CanonicalDimension { .value = Style::resolveLength(value, lengthUnit, *conversionData), .dimension = CanonicalDimension::Dimension::Length };
        return { };
    };

    switch (root.unit) {
    // Absolute Lengths (can be canonicalized without conversion data).
    case CSSUnitType::Cm:
        return makeCanonical(root.value * CSS::pixelsPerCm,              CanonicalDimension::Dimension::Length);
    case CSSUnitType::Mm:
        return makeCanonical(root.value * CSS::pixelsPerMm,              CanonicalDimension::Dimension::Length);
    case CSSUnitType::Q:
        return makeCanonical(root.value * CSS::pixelsPerQ,               CanonicalDimension::Dimension::Length);
    case CSSUnitType::In:
        return makeCanonical(root.value * CSS::pixelsPerInch,            CanonicalDimension::Dimension::Length);
    case CSSUnitType::Pt:
        return makeCanonical(root.value * CSS::pixelsPerPt,              CanonicalDimension::Dimension::Length);
    case CSSUnitType::Pc:
        return makeCanonical(root.value * CSS::pixelsPerPc,              CanonicalDimension::Dimension::Length);

    // Font, Viewport and Container relative Lengths (require conversion data for canonicalization).
    case CSSUnitType::Em:
    case CSSUnitType::Ex:
    case CSSUnitType::Lh:
    case CSSUnitType::Cap:
    case CSSUnitType::Ch:
    case CSSUnitType::Ic:
    case CSSUnitType::Rcap:
    case CSSUnitType::Rch:
    case CSSUnitType::Rem:
    case CSSUnitType::Rex:
    case CSSUnitType::Ric:
    case CSSUnitType::Rlh:
    case CSSUnitType::Vw:
    case CSSUnitType::Vh:
    case CSSUnitType::Vmin:
    case CSSUnitType::Vmax:
    case CSSUnitType::Vb:
    case CSSUnitType::Vi:
    case CSSUnitType::Svw:
    case CSSUnitType::Svh:
    case CSSUnitType::Svmin:
    case CSSUnitType::Svmax:
    case CSSUnitType::Svb:
    case CSSUnitType::Svi:
    case CSSUnitType::Lvw:
    case CSSUnitType::Lvh:
    case CSSUnitType::Lvmin:
    case CSSUnitType::Lvmax:
    case CSSUnitType::Lvb:
    case CSSUnitType::Lvi:
    case CSSUnitType::Dvw:
    case CSSUnitType::Dvh:
    case CSSUnitType::Dvmin:
    case CSSUnitType::Dvmax:
    case CSSUnitType::Dvb:
    case CSSUnitType::Dvi:
    case CSSUnitType::Cqw:
    case CSSUnitType::Cqh:
    case CSSUnitType::Cqi:
    case CSSUnitType::Cqb:
    case CSSUnitType::Cqmin:
    case CSSUnitType::Cqmax:
        return tryMakeCanonical(root.value, *CSS::toLengthUnit(root.unit));

    // <angle>
    case CSSUnitType::Rad:
        return makeCanonical(root.value * degreesPerRadianDouble,        CanonicalDimension::Dimension::Angle);
    case CSSUnitType::Grad:
        return makeCanonical(root.value * degreesPerGradientDouble,      CanonicalDimension::Dimension::Angle);
    case CSSUnitType::Turn:
        return makeCanonical(root.value * degreesPerTurnDouble,          CanonicalDimension::Dimension::Angle);

    // <time>
    case CSSUnitType::Ms:
        return makeCanonical(root.value * CSS::secondsPerMillisecond,    CanonicalDimension::Dimension::Time);

    // <frequency>
    case CSSUnitType::Khz:
        return makeCanonical(root.value * CSS::hertzPerKilohertz,        CanonicalDimension::Dimension::Frequency);

    // <resolution>
    case CSSUnitType::X:
        return makeCanonical(root.value * CSS::dppxPerX,                 CanonicalDimension::Dimension::Resolution);
    case CSSUnitType::Dpi:
        return makeCanonical(root.value * CSS::dppxPerDpi,               CanonicalDimension::Dimension::Resolution);
    case CSSUnitType::Dpcm:
        return makeCanonical(root.value * CSS::dppxPerDpcm,              CanonicalDimension::Dimension::Resolution);

    // Canonical dimensional types should never be stored in a NonCanonicalDimension.
    case CSSUnitType::Px:
    case CSSUnitType::Deg:
    case CSSUnitType::S:
    case CSSUnitType::Hz:
    case CSSUnitType::Dppx:
    case CSSUnitType::Fr:
    // Non-dimensional types should never be stored in a NonCanonicalDimension.
    case CSSUnitType::Number:
    case CSSUnitType::Integer:
    case CSSUnitType::Percentage:
    // Non-numeric types should never be stored in a NonCanonicalDimension.
    case CSSUnitType::Calc:
    case CSSUnitType::CalcPercentageWithAngle:
    case CSSUnitType::CalcPercentageWithLength:
    case CSSUnitType::QuirkyEm:
    case CSSUnitType::Unknown:
        break;
    }

    ASSERT_NOT_REACHED();
    return { };
}


#if CSS_CALC_CPP_SIMPLIFIER_COMPILED_IN
// MARK: Generic partial evaluation functions

template<typename Op> static std::optional<Child> simplifyForOperation(Child& a, Child& b, const SimplificationOptions& options)
{
    return switchTogether(a, b,
        [&]<Numeric T>(const T& numericA, const T& numericB) -> std::optional<Child> {
            if (!unitsMatch(numericA, numericB, options) || !fullyResolved(numericA, options))
                return { };

            return makeChildWithValueBasedOn(executeMathOperation<Op>(numericA.value, numericB.value), numericA);
        },
        [](const auto&, const auto&) -> std::optional<Child> {
            return { };
        }
    );
}

template<typename Op, typename Completion> static std::optional<Child> simplifyForOperationWithCompletion(Child& a, Child& b, const SimplificationOptions& options, NOESCAPE const Completion& completion)
{
    return switchTogether(a, b,
        [&]<Numeric T>(const T& numericA, const T& numericB) -> std::optional<Child> {
            if (!unitsMatch(numericA, numericB, options) || !fullyResolved(numericA, options))
                return { };

            return completion(executeMathOperation<Op>(numericA.value, numericB.value));
        },
        [](const auto&, const auto&) -> std::optional<Child> {
            return { };
        }
    );
}

template<typename Op> static std::optional<Child> simplifyForRound(Op& root, const SimplificationOptions& options)
{
    if (root.b)
        return simplifyForOperation<Op>(root.a, *root.b, options);

    if (auto* numberA = get_if<Number>(&root.a))
        return makeChild(Number { .value = executeMathOperation<Op>(numberA->value, 1.0) });

    return { };
}

template<typename Op> static std::optional<Child> simplifyForTrig(Op& root, const SimplificationOptions&)
{
    // NOTE: `root.a` has been type checked by this point to be `<number>`, or to be a Deg2Rad
    // wrapper inserted at parse time around an `<angle>` subtree. The Deg2Rad node takes care of
    // converting degrees to radians, so simplification here only needs to collapse the trig
    // function when the wrapped value has resolved to a Number (i.e. a value in radians).

    return WTF::switchOn(root.a,
        [&](const Number& a) -> std::optional<Child> {
            return makeChild(Number { .value = executeMathOperation<Op>(a.value) });
        },
        [](const auto&) -> std::optional<Child> {
            return { };
        }
    );
}

template<typename Op> static std::optional<Child> simplifyForArcTrig(Op& root, const SimplificationOptions&)
{
    // NOTE: `a` has been type checked by this point to be `<number>`, though they may not
    // be able to be fully resolved yet.

    return WTF::switchOn(root.a,
        [&](const Number& a) -> std::optional<Child> {
            return makeChild(CanonicalDimension { .value = executeMathOperation<Op>(a.value), .dimension = CanonicalDimension::Dimension::Angle });
        },
        [](const auto&) -> std::optional<Child> {
            return { };
        }
    );
}

template<typename Op> static std::optional<Child> simplifyForMinMax(Op& root, const SimplificationOptions& options)
{
    ASSERT(!root.children.isEmpty());

    // This function implements shared logic for Min and Max simplification:

    //   5.1. For each node child of root’s children:
    //        If child is a numeric value with enough information to compare magnitudes with another child of the same unit (see note in previous step), and there are other children of root that are numeric values with the same unit, combine all such children with the appropriate operator per root, and replace child with the result, removing all other child nodes involved.
    //   5.2. If root has only one child, return the child.
    //   5.3. Otherwise, return root.

    // --

    // These steps are implemented as a two phase procedure.
    //    1. Iterate children to find "merge opportunities", counting the total number of merges that will happen, and storing the index of the first child of each merge type in a lookup table.
    //    2. Perform merges based on data from step 1.
    //
    // By splitting it up, we can perform two optimizations:
    //    1. If the result of step 1 shows that the number of "merge opportunities" will lead to only one remaining child, we can avoid allocating a new Children Vector, and just merge directly into the child.
    //    2. If the result of step 1 shows that the number of "merge opportunities" will lead to more than one remaining child, we can precisely allocate the Children Vector to be (existing children - "merge opportunities").

    auto evaluate = [](const Child& a, const Child& b) -> Child {
        ASSERT(a.index() == b.index());

        return WTF::switchOn(a,
            [&]<Numeric T>(const T& aNumeric) -> Child {
                ASSERT(toNumericIdentity(aNumeric) == toNumericIdentity(get<T>(b)));
                return makeChildWithValueBasedOn(executeMathOperation<Op>(aNumeric.value, get<T>(b).value), aNumeric);
            },
            [](const auto&) -> Child {
                ASSERT_NOT_REACHED();
                return makeChild(Number { .value = 0 });
            }
        );
    };

    // Special case a root with one child to avoid doing any work at all, and just returning the child.
    if (root.children.size() == 1)
        return { WTF::move(root.children[0]) };

    // Map of unit types (via NumericIdentity) to the first index in `root.children` where a value with that unit can be found.
    // More specifically, it maps the unit to the index + 1, as 0 is used to indicate no units of that type have been found.
    // FIXME: This should be turned into a type with an interface that doesn't require explicit use of static_cast<uint8_t> by the caller.
    std::array<size_t, numberOfNumericIdentityTypes> offsetOfFirstInstance { };

    bool canMergePercentages = !percentageResolveToDimension(options);

    unsigned numberOfMergeOpportunities = 0;
    for (size_t i = 0; i < root.children.size(); ++i) {
        numberOfMergeOpportunities += WTF::switchOn(root.children[i],
            [&]<Numeric T>(const T& child) {
                auto id = toNumericIdentity(child);
                if (id == NumericIdentity::Percentage && !canMergePercentages)
                    return 0;

                if (auto offset = offsetOfFirstInstance[static_cast<uint8_t>(id)]) {
                    // There has already been an instance of this type. This is a merge opportunity.

                    // Merge the value into first instance.
                    root.children[offset - 1] = evaluate(root.children[offset - 1], root.children[i]);

                    // Return 1 to increment the number of merge opportunities observed.
                    return 1;
                }

                // First instance of this. Store the index (well, index + 1, since 0 is the unset value).
                offsetOfFirstInstance[static_cast<uint8_t>(id)] = i + 1;

                // Give this was the first instance, it is not yet a merge opportunity.
                return 0;
            },
            [](const auto&) {
                return 0;
            }
        );
    }

    // If there are no merge opportunities, no further simplification is possible.
    if (!numberOfMergeOpportunities)
        return { };

    auto combinedChildrenSize = root.children.size() - numberOfMergeOpportunities;

    // If all the removal from merges leaves a single child, that means everything merged into the first child.
    if (combinedChildrenSize == 1)
        return { WTF::move(root.children[0]) };

    Vector<Child> combinedChildren;
    combinedChildren.reserveInitialCapacity(combinedChildrenSize);

    for (size_t i = 0; i < root.children.size(); ++i) {
        WTF::switchOn(root.children[i],
            [&]<Numeric T>(const T& child) {
                auto offset = offsetOfFirstInstance[static_cast<uint8_t>(toNumericIdentity(child))];

                // If the stored offset for this type is unset (as it would be for percentages if merging them is disallowed) or is set to this index (as it would be for the first instance of a merged type), append the child as normal.
                if (!offset || (offset - 1) == i) {
                    combinedChildren.append(WTF::move(root.children[i]));
                    return;
                }

                // Otherwise, it's one that can be dropped.
            },
            [&](const auto&) {
                combinedChildren.append(WTF::move(root.children[i]));
            }
        );
    }
    root.children = WTF::move(combinedChildren);

    return { };
}

// MARK: In-place simplification / replacement finding.

std::optional<Child> simplify(Number&, const SimplificationOptions&)
{
    // No further simplification possible for <number>.
    return { };
}

std::optional<Child> simplify(Percentage&, const SimplificationOptions&)
{
    // 1.1. If root is a percentage that will be resolved against another value, and there is enough information available to resolve it, do so, and express the resulting numeric value in the appropriate canonical unit. Return the value.
    // NOTE: Handled by the Style::Calculation::Tree / Style::Calculation::Value types at use time.
    return { };
}

std::optional<Child> simplify(CanonicalDimension&, const SimplificationOptions&)
{
    // No further simplification possible for canonical <dimension>.
    return { };
}

std::optional<Child> simplify(NonCanonicalDimension& root, const SimplificationOptions& options)
{
    // NOTE: This implements the non-canonical dimension relevant parts of the numeric value simplification steps.

    // 1.2. If root is a dimension that is not expressed in its canonical unit, and there is enough information available to convert it to the canonical unit, do so, and return the value.
    if (auto canonical = canonicalize(root, options.conversionData))
        return makeChild(WTF::move(*canonical));

    return { };
}

std::optional<Child> simplify(Symbol& root, const SimplificationOptions& options)
{
    // NOTE: This implements the keyword relevant parts of the numeric value simplification steps.

    // 1.3. If root is a <calc-keyword> that can be resolved, return what it resolves to, simplified.
    if (auto value = options.symbolTable.get(root.id))
        return copyAndSimplify(makeNumeric(value->value, root.unit), options);

    return { };
}

std::optional<Child> simplify(SiblingCount&, const SimplificationOptions& options)
{
    if (!options.conversionData || !options.conversionData->styleBuilderState())
        return { };
    if (!options.conversionData->styleBuilderState()->element())
        return { };

    return makeChild(Number { .value = static_cast<double>(protect(options.conversionData->styleBuilderState())->siblingCount()) });
}

std::optional<Child> simplify(SiblingIndex&, const SimplificationOptions& options)
{
    if (!options.conversionData || !options.conversionData->styleBuilderState())
        return { };
    if (!options.conversionData->styleBuilderState()->element())
        return { };

    return makeChild(Number { .value = static_cast<double>(protect(options.conversionData->styleBuilderState())->siblingIndex()) });
}

std::optional<Child> simplify(Sum& root, const SimplificationOptions& options)
{
    ASSERT(!root.children.isEmpty());

    // 8. If root is a Sum node:

    // 8.1. For each of root’s children that are Sum nodes, replace them with their children.
    if (std::ranges::any_of(root.children, [](auto& child) { return WTF::holdsAlternative<IndirectNode<Sum>>(child); })) {
        Vector<Child> newChildren;
        for (auto& child : root.children) {
            if (auto* childSum = get_if<IndirectNode<Sum>>(&child))
                newChildren.appendVector(WTF::move((*childSum)->children.value));
            else
                newChildren.append(WTF::move(child));
        }
        root.children = WTF::move(newChildren);
    }

    // 8.2. For each set of root’s children that are numeric values with identical units, remove those children and replace them with a single numeric value containing the sum of the removed nodes, and with the same unit. (E.g. combine numbers, combine percentages, combine px values, etc.)
    // 8.3. If root has only a single child at this point, return the child.
    // 8.4. Otherwise, return root

    // These steps are implemented as a two phase procedure.
    //    1. Iterate children to find "merge/removal opportunities", counting the total number of opportunities that will happen, and storing the index of the first child of each type in a lookup table.
    //    2. Perform merges and removals based on data from step 1.
    //
    // By splitting it up, we can perform two optimizations:
    //    1. If the result of step 1 shows that the number of "merge/removal opportunities" will lead to only one remaining child, we can avoid allocating a new Children Vector, and just merge directly into the child.
    //    2. If the result of step 1 shows that the number of "merge/removal opportunities" will lead to more than one remaining child, we can precisely allocate the Children Vector to be (existing children - "merge/removal opportunities").

    auto evaluate = [](const Child& a, const Child& b) -> std::pair<Child, double> {
        ASSERT(a.index() == b.index());

        return WTF::switchOn(a,
            [&]<Numeric T>(const T& aNumeric) -> std::pair<Child, double> {
                ASSERT(toNumericIdentity(aNumeric) == toNumericIdentity(get<T>(b)));
                auto result = executeMathOperation<Sum>(aNumeric.value, get<T>(b).value);
                return { makeChildWithValueBasedOn(result, aNumeric), result };
            },
            [](const auto&) -> std::pair<Child, double> {
                ASSERT_NOT_REACHED();
                return { makeChild(Number { .value = 0 }), 0 };
            }
        );
    };

    // Special case a root with one child to avoid doing any work at all, and just returning the child.
    if (root.children.size() == 1)
        return { WTF::move(root.children[0]) };

    // Map of unit types (via NumericIdentity) to the first index in `root.children` where a value with that unit can be found.
    // More specifically, it maps the unit to the index + 1, as 0 is used to indicate no units of that type have been found.
    // FIXME: This should be turned into a type with an interface that doesn't require explicit use of static_cast<uint8_t> by the caller.
    struct FirstInstance {
        size_t offset = 0;
        unsigned merges = 0;
        bool canRemove = false;
    };
    std::array<FirstInstance, numberOfNumericIdentityTypes> firstInstances { };

    for (size_t i = 0; i < root.children.size(); ++i) {
        WTF::switchOn(root.children[i],
            [&]<Numeric T>(const T& child) {
                auto id = toNumericIdentity(child);
                bool canRemoveIfZero = isLength(id) && options.allowZeroValueLengthRemovalFromSum;

                if (auto& firstInstance = firstInstances[static_cast<uint8_t>(id)]; firstInstance.offset) {
                    // There has already been an instance of this type. This is a merge opportunity.

                    // Calculate the merged value.
                    auto [mergedChild, mergedValue] = evaluate(root.children[firstInstance.offset - 1], root.children[i]);

                    // Store the merged value in the original array.
                    root.children[firstInstance.offset - 1] = WTF::move(mergedChild);

                    // Update the `merges` count and `canRemove` bit for the new merged value.
                    firstInstance.merges += 1;
                    firstInstance.canRemove = canRemoveIfZero && !mergedValue;
                    return;
                }

                // First instance of this. Store the index (well, index + 1, since 0 is the unset value) and the canRemove bit.
                firstInstances[static_cast<uint8_t>(id)] = {
                    .offset = i + 1,
                    .merges = 0,
                    .canRemove = canRemoveIfZero && !child.value
                };
            },
            [](const auto&) {
                // Non-numeric values are not eligible for merge or removal.
            }
        );
    }

    // Calculate the total number of children we will be able to remove from merges and removals.
    unsigned childrenToRemoveFromMerges = 0;
    unsigned childrenToRemoveTotal = 0;
    for (auto& firstInstance : firstInstances) {
        if (firstInstance.offset) {
            childrenToRemoveFromMerges += firstInstance.merges;
            childrenToRemoveTotal += firstInstance.merges + (firstInstance.canRemove ? 1 : 0);
        }
    }

    // If there are no merge/removal opportunities, no further simplification is possible.
    if (!childrenToRemoveTotal)
        return { };

    // If all the removal from merges leaves a single child, that means everything merged into the first child.
    if ((root.children.size() - childrenToRemoveFromMerges) == 1)
        return { WTF::move(root.children[0]) };

    auto combinedChildrenSize = root.children.size() - childrenToRemoveTotal;

    // If the new size is 0, we removed too much. Return a single 0 value of type `length` to keep things valid. A value of type `length` is returned because the only kind of node that can be removed is of type `length`.
    if (!combinedChildrenSize)
        return { makeChild(CanonicalDimension { .value = 0, .dimension = CanonicalDimension::Dimension::Length }) };

    // If the new size is 1, we know there is one child, we just don't know which one yet.
    if (combinedChildrenSize == 1) {
        for (size_t i = 0; i < root.children.size(); ++i) {
            auto replacement = WTF::switchOn(root.children[i],
                [&]<Numeric T>(const T& child) -> std::optional<Child> {
                    auto& firstInstance = firstInstances[static_cast<uint8_t>(toNumericIdentity(child))];
                    ASSERT(firstInstance.offset);

                    // If the stored offset for this type is set to this index and it's not one that can be removed, this is the 1 child to return.
                    if ((firstInstance.offset - 1) == i && !firstInstance.canRemove)
                        return { WTF::move(root.children[i]) };

                    // Otherwise, it's one that can be dropped.
                    return { };
                },
                [&](const auto&) -> std::optional<Child> {
                    return { WTF::move(root.children[i]) };
                }
            );
            if (replacement)
                return { WTF::move(*replacement) };
        }
    }

    Vector<Child> combinedChildren;
    combinedChildren.reserveInitialCapacity(combinedChildrenSize);

    for (size_t i = 0; i < root.children.size(); ++i) {
        WTF::switchOn(root.children[i],
            [&]<Numeric T>(const T& child) {
                auto& firstInstance = firstInstances[static_cast<uint8_t>(toNumericIdentity(child))];
                ASSERT(firstInstance.offset);

                // If the stored offset for this type is set to this index and it's not one that can be removed, append the child as normal
                if ((firstInstance.offset - 1) == i && !firstInstance.canRemove) {
                    combinedChildren.append(WTF::move(root.children[i]));
                    return;
                }

                // Otherwise, it's one that can be dropped.
            },
            [&](const auto&) {
                combinedChildren.append(WTF::move(root.children[i]));
            }
        );
    }
    root.children = WTF::move(combinedChildren);

    return { };
}

std::optional<Child> simplify(Product& root, const SimplificationOptions& options)
{
    ASSERT(!root.children.isEmpty());

    // 9. If root is a Product node:

    // NOTE: We merge steps 9.1. and 9.2, as they have significant overlap.

    // 9.1. For each of root’s children that are Product nodes, replace them with their children.
    //
    //   -- and --
    //
    // 9.2. If root has multiple children that are numbers (not percentages or dimensions), remove them and replace them with a single number containing the product of the removed nodes.

    Vector<Child> newChildren;
    std::optional<Number> numericProduct;

    auto processChild = [&newChildren, &numericProduct](Child& child) {
        if (auto* childValue = get_if<Number>(&child)) {
            if (numericProduct)
                numericProduct = Number { .value = childValue->value * numericProduct->value };
            else
                numericProduct = Number { .value = childValue->value };
        } else
            newChildren.append(WTF::move(child));
    };

    for (auto& child : root.children) {
        if (auto* childProduct = get_if<IndirectNode<Product>>(&child)) {
            for (auto& childProductChild : (*childProduct)->children)
                processChild(childProductChild);
        } else
            processChild(child);
    }

    // If `numericProduct` has a value and `newChildren` is empty, that means all the children were numbers and the product can be returned directly.
    if (numericProduct) {
        if (newChildren.isEmpty())
            return makeChild(*numericProduct);

        // 9.3. If root contains only two children, one of which is a number (not a percentage or dimension) and the other of which is a Sum whose children are all numeric values, multiply all of the Sum’s children by the number, then return the Sum.

        // We extend this step to include numeric and Invert children for the non-number child as an optimization taking advantage of step 9.4, but for the case where the check is cheaper.

        // NOTE: Since we just merged all numeric values into `numericProduct`, we know that if `numericProduct` is not std::nullopt the last child is a singular `number` child. Therefore, we only need to check if there is one child and is a Sum (or Numeric or Invert).

        if (newChildren.size() == 1) {
            auto replacement = WTF::switchOn(newChildren[0],
                [&]<Numeric T>(T& numeric) -> std::optional<Child> {
                    return makeChildWithValueBasedOn(numeric.value * numericProduct->value, numeric);
                },
                [&](IndirectNode<Sum>& sum) -> std::optional<Child> {
                    if (!std::ranges::all_of(sum->children, isNumeric))
                        return { };

                    for (auto& child : sum->children) {
                        WTF::switchOn(child,
                            [&]<Numeric T>(T& child) { child.value *= numericProduct->value; },
                            [](auto&) { }
                        );
                    }

                    return { Child { WTF::move(sum) } };
                },
                [&](IndirectNode<Invert>& invert) -> std::optional<Child> {
                    return WTF::switchOn(invert->a,
                        [&]<Numeric T>(const T& child) -> std::optional<Child> {
                            return makeChildWithValueBasedOn(child.value * numericProduct->value, child);
                        },
                        [](const auto&) -> std::optional<Child> {
                            return { };
                        }
                    );
                },
                [](auto&) -> std::optional<Child> {
                    return { };
                }
            );

            if (replacement)
                return { WTF::move(*replacement) };
        }

        // If there was more than one child or no replacement was found, append the product from step 9.2 into the newChildren array.
        newChildren.append(makeChild(*numericProduct));
    }

    root.children = WTF::move(newChildren);

    // 9.4. If root contains only numeric values and/or Invert nodes containing numeric values, and multiplying the types of all the children (noting that the type of an Invert node is the inverse of its child’s type) results in a type that matches any of the types that a math function can resolve to, return the result of multiplying all the values of the children (noting that the value of an Invert node is the reciprocal of its child’s value), expressed in the result’s canonical unit.

    struct ProductResult {
        double value;
        Type type;
    };
    auto productResult = ProductResult { .value = 1, .type = Type { } };

    bool success = false;
    for (auto& child : root.children) {
        success = WTF::switchOn(child,
            [&](const Number& number) -> bool {
                // <number> is the identity type, so multiplying by it has no effect.
                productResult.value *= number.value;
                return true;
            },
            [&](const Percentage& percentage) -> bool {
                auto multipliedType = Type::multiply(productResult.type, getType(percentage));
                if (!multipliedType)
                    return false;

                productResult.type = *multipliedType;
                productResult.value *= percentage.value;
                return true;
            },
            [&](const CanonicalDimension& canonicalDimension) -> bool {
                auto multipliedType = Type::multiply(productResult.type, getType(canonicalDimension.dimension));
                if (!multipliedType)
                    return false;

                productResult.type = *multipliedType;
                productResult.value *= canonicalDimension.value;
                return true;
            },
            [&](IndirectNode<Invert>& invertChild) -> bool {
                return WTF::switchOn(invertChild->a,
                    [&](const Number& number) -> bool {
                        // <number> is the identity type, so multiplying / inverting by it has no effect.
                        productResult.value /= number.value;
                        return true;
                    },
                    [&](const Percentage& percentage) -> bool {
                        auto invertedPercentageChildType = Type::invert(getType(percentage));
                        auto multipliedType = Type::multiply(productResult.type, invertedPercentageChildType);
                        if (!multipliedType)
                            return false;

                        productResult.type = *multipliedType;
                        productResult.value /= percentage.value;
                        return true;
                    },
                    [&](const CanonicalDimension& canonicalDimension) -> bool {
                        auto invertedCanonicalDimensionType = Type::invert(getType(canonicalDimension));
                        auto multipliedType = Type::multiply(productResult.type, invertedCanonicalDimensionType);
                        if (!multipliedType)
                            return false;

                        productResult.type = *multipliedType;
                        productResult.value /= canonicalDimension.value;
                        return true;
                    },
                    [](const auto&) -> bool {
                        return false;
                    }
                );
            },
            [](const auto&) -> bool {
                return false;
            }
        );
        if (!success)
            break;
    }
    if (success) {
        if (auto category = productResult.type.calculationCategory()) {
            switch (*category) {
            case CSS::Category::Integer:
            case CSS::Category::Number:
                return makeChild(Number { .value = productResult.value });
            case CSS::Category::Percentage:
                return makeChild(Percentage { .value = productResult.value, .hint = Type::determinePercentHint(options.category) });
            case CSS::Category::LengthPercentage:
                return makeChild(Percentage { .value = productResult.value, .hint = PercentHint::Length });
            case CSS::Category::Length:
                return makeChild(CanonicalDimension { .value = productResult.value, .dimension = CanonicalDimension::Dimension::Length });
            case CSS::Category::Angle:
                return makeChild(CanonicalDimension { .value = productResult.value, .dimension = CanonicalDimension::Dimension::Angle });
            case CSS::Category::AnglePercentage:
                return makeChild(Percentage { .value = productResult.value, .hint = PercentHint::Angle });
            case CSS::Category::Time:
                return makeChild(CanonicalDimension { .value = productResult.value, .dimension = CanonicalDimension::Dimension::Time });
            case CSS::Category::Frequency:
                return makeChild(CanonicalDimension { .value = productResult.value, .dimension = CanonicalDimension::Dimension::Frequency });
            case CSS::Category::Resolution:
                return makeChild(CanonicalDimension { .value = productResult.value, .dimension = CanonicalDimension::Dimension::Resolution });
            case CSS::Category::Flex:
                return makeChild(CanonicalDimension { .value = productResult.value, .dimension = CanonicalDimension::Dimension::Flex });
            }
        }
    }

    // 9.5. Return root.
    return { };
}

std::optional<Child> simplify(Negate& root, const SimplificationOptions&)
{
    // 6. If root is a Negate node:

    return WTF::switchOn(root.a,
        [&]<Numeric T>(T& a) -> std::optional<Child> {
            // 6.1. If root’s child is a numeric value, return an equivalent numeric value, but with the value negated.
            // NOTE: We use unary negation rather than the spec's literal "0 - value" so that the sign of a zero is
            // flipped (negating +0 yields -0), matching IEEE 754 and the runtime Negate executor.
            // https://drafts.csswg.org/css-values-4/#calc-ieee
            return makeChildWithValueBasedOn(-a.value, a);
        },
        [](IndirectNode<Negate>& a) -> std::optional<Child> {
            // 6.2. If root’s child is a Negate node, return the child’s child.
            return { WTF::move(a->a) };
        },
        [](IndirectNode<Sum>& a) -> std::optional<Child> {
            // Not stated in spec, but needed for tests.

            if (!std::ranges::all_of(a->children, isNumeric))
                return { };

            for (auto& child : a->children) {
                WTF::switchOn(child,
                    [&]<Numeric T>(T& child) { child.value = -child.value; },
                    [](auto&) { }
                );
            }

            return { Child { WTF::move(a) } };
        },
        [](IndirectNode<Product>& a) -> std::optional<Child> {
            // Not stated in spec, but needed for tests.

            if (!std::ranges::all_of(a->children, isNumeric))
                return { };

            for (auto& child : a->children) {
                WTF::switchOn(child,
                    [&]<Numeric T>(T& child) { child.value = -child.value; },
                    [](auto&) { }
                );
            }

            return { Child { WTF::move(a) } };
        },
        [](auto&) -> std::optional<Child> {
            return { };
        }
    );
}

std::optional<Child> simplify(Invert& root, const SimplificationOptions&)
{
    // 7. If root is an Invert node:

    return WTF::switchOn(root.a,
        [&](Number& a) -> std::optional<Child> {
            // 7.1. If root’s child is a number (not a percentage or dimension) return the reciprocal of the child’s value.
            return makeChild(Number { .value = (1.0 / a.value) });
        },
        [](IndirectNode<Invert>& a) -> std::optional<Child> {
            // 7.2. If root’s child is an Invert node, return the child’s child.
            return { WTF::move(a->a) };
        },
        [](auto&) -> std::optional<Child> {
            return { };
        }
    );
}

std::optional<Child> simplify(Deg2Rad& root, const SimplificationOptions&)
{
    // Deg2Rad wraps an <angle> subtree and produces a <number> in radians. It is inserted at
    // parse time inside trig functions whose argument is an <angle>, so that evaluation does not
    // need to inspect the argument's type.

    return WTF::switchOn(root.angle,
        [&](const CanonicalDimension& a) -> std::optional<Child> {
            ASSERT(a.dimension == CanonicalDimension::Dimension::Angle);
            return makeChild(Number { .value = deg2rad(a.value) });
        },
        [](const auto&) -> std::optional<Child> {
            return { };
        }
    );
}

std::optional<Child> simplify(Min& root, const SimplificationOptions& options)
{
    return simplifyForMinMax(root, options);
}

std::optional<Child> simplify(Max& root, const SimplificationOptions& options)
{
    return simplifyForMinMax(root, options);
}

std::optional<Child> simplify(Clamp& root, const SimplificationOptions& options)
{
    auto minIsNone = WTF::holdsAlternative<CSS::Keyword::None>(root.min);
    auto maxIsNone = WTF::holdsAlternative<CSS::Keyword::None>(root.max);

    if (minIsNone && maxIsNone) {
        // - clamp(none, VAL, none) is equivalent to just calc(VAL).
        return { WTF::move(root.val) };
    }

    auto convertToMin = [&] -> std::optional<Child> {
        Vector<Child> newChildren;
        newChildren.reserveInitialCapacity(2);
        newChildren.append(WTF::move(root.val));
        newChildren.append(get<Child>(WTF::move(root.max)));

        auto min = Min { .children = WTF::move(newChildren) };
        auto minType = toType(min);
        if (!minType)
            return std::nullopt;

        return makeChild(WTF::move(min), *minType);
    };

    auto convertToMax = [&] -> std::optional<Child> {
        Vector<Child> newChildren;
        newChildren.reserveInitialCapacity(2);
        newChildren.append(get<Child>(WTF::move(root.min)));
        newChildren.append(WTF::move(root.val));

        auto max = Max { .children = WTF::move(newChildren) };
        auto maxType = toType(max);
        if (!maxType)
            return std::nullopt;

        return makeChild(WTF::move(max), *maxType);
    };

    return WTF::switchOn(root.val,
        [&]<Numeric T>(T& val) -> std::optional<Child> {
            if (minIsNone) {
                auto& maxChild = get<Child>(root.max);
                if (!WTF::holdsAlternative<T>(maxChild))
                    return convertToMin();

                auto& max = get<T>(maxChild);

                if (!unitsMatch(val, max, options))
                    return convertToMin();

                // As units already match, we only have to check that one of the arguments is `magnitudeComparable`.
                if (!magnitudeComparable(val, options))
                    return convertToMin();

                // - clamp(none, VAL, MAX) is equivalent to min(VAL, MAX)
                return makeChildWithValueBasedOn(executeMathOperation<Min>(val.value, max.value), val);
            } else if (maxIsNone) {
                auto& minChild = get<Child>(root.min);
                if (!WTF::holdsAlternative<T>(minChild))
                    return convertToMax();

                auto& min = get<T>(minChild);

                if (!unitsMatch(min, val, options))
                    return convertToMax();

                // As units already match, we only have to check that one of the arguments is `magnitudeComparable`.
                if (!magnitudeComparable(val, options))
                    return convertToMax();

                // - clamp(MIN, VAL, none) is equivalent to max(MIN, VAL)
                return makeChildWithValueBasedOn(executeMathOperation<Max>(min.value, val.value), val);
            } else {
                auto& minChild = get<Child>(root.min);
                auto& maxChild = get<Child>(root.max);

                // If all three parameters have the same unit, we can perform the clamp in full.
                if (!WTF::holdsAlternative<T>(minChild) || !WTF::holdsAlternative<T>(maxChild))
                    return { };

                auto& min = get<T>(minChild);
                auto& max = get<T>(maxChild);

                if (!unitsMatch(min, val, options) || !unitsMatch(val, max, options))
                    return { };

                // As units already match, we only have to check that one of the arguments is `magnitudeComparable`.
                if (!magnitudeComparable(val, options))
                    return { };

                return makeChildWithValueBasedOn(executeMathOperation<Clamp>(min.value, val.value, max.value), val);
            }
        },
        [](const auto&) -> std::optional<Child> {
            return { };
        }
    );
}

std::optional<Child> simplify(RoundNearest& root, const SimplificationOptions& options)
{
    return simplifyForRound(root, options);
}

std::optional<Child> simplify(RoundUp& root, const SimplificationOptions& options)
{
    return simplifyForRound(root, options);
}

std::optional<Child> simplify(RoundDown& root, const SimplificationOptions& options)
{
    return simplifyForRound(root, options);
}

std::optional<Child> simplify(RoundToZero& root, const SimplificationOptions& options)
{
    return simplifyForRound(root, options);
}

std::optional<Child> simplify(Mod& root, const SimplificationOptions& options)
{
    return simplifyForOperation<Mod>(root.a, root.b, options);
}

std::optional<Child> simplify(Rem& root, const SimplificationOptions& options)
{
    return simplifyForOperation<Rem>(root.a, root.b, options);
}

std::optional<Child> simplify(Sin& root, const SimplificationOptions& options)
{
    return simplifyForTrig(root, options);
}

std::optional<Child> simplify(Cos& root, const SimplificationOptions& options)
{
    return simplifyForTrig(root, options);
}

std::optional<Child> simplify(Tan& root, const SimplificationOptions& options)
{
    return simplifyForTrig(root, options);
}

std::optional<Child> simplify(Asin& root, const SimplificationOptions& options)
{
    return simplifyForArcTrig(root, options);
}

std::optional<Child> simplify(Acos& root, const SimplificationOptions& options)
{
    return simplifyForArcTrig(root, options);
}

std::optional<Child> simplify(Atan& root, const SimplificationOptions& options)
{
    return simplifyForArcTrig(root, options);
}

std::optional<Child> simplify(Atan2& root, const SimplificationOptions& options)
{
    return simplifyForOperationWithCompletion<Atan2>(root.a, root.b, options, [](double value) {
        return makeChild(CanonicalDimension { .value = value, .dimension = CanonicalDimension::Dimension::Angle });
    });
}

std::optional<Child> simplify(Pow& root, const SimplificationOptions&)
{
    // NOTE: `a` and `b` have been type checked by this point to be `<number>`, though they may not
    // be able to be fully resolved yet.

    return switchTogether(root.a, root.b,
        [&](const Number& a, const Number& b) -> std::optional<Child> {
            return makeChild(Number { .value = executeMathOperation<Pow>(a.value, b.value) });
        },
        [](const auto&, const auto&) -> std::optional<Child> {
            return { };
        }
    );
}

std::optional<Child> simplify(Sqrt& root, const SimplificationOptions&)
{
    // NOTE: `a` has been type checked by this point to be `<number>`, though they may not
    // be able to be fully resolved yet.

    return WTF::switchOn(root.a,
        [&](const Number& a) -> std::optional<Child> {
            return makeChild(Number { .value = executeMathOperation<Sqrt>(a.value) });
        },
        [](const auto&) -> std::optional<Child> {
            return { };
        }
    );
}

std::optional<Child> simplify(Hypot& root, const SimplificationOptions& options)
{
    // Hypot can be simplified if all its children are the same type, and it is both canonical (for lengths) and fully resolved (for percentages). We optimistically assume that the children fit this criteria, and execute the operation over the children, checking each one as it is requested. If we find out our assumption was incorrect (e.g. a child is non-canonical or non-resolved), we set a flag indicating the evaluation failed, but due to the evaluation API's interface, must evaluate all the remaining children. Once the evaluation is complete, if the fail bit is set, we failed to simplify, if it is not, we can return the new numeric result.

    struct NumberTag { };
    struct PercentageTag { };
    struct DimensionTag { CanonicalDimension::Dimension dimension; };
    struct FailureTag { };
    Variant<std::monostate, NumberTag, PercentageTag, DimensionTag, FailureTag> result;

    double value = executeMathOperation<Hypot>(root.children.value, [&](const auto& child) {
        return WTF::switchOn(result,
            [&](const std::monostate&) -> double {
                // First iteration.
                return WTF::switchOn(child,
                    [&](const Number& number) -> double {
                        result = NumberTag { };
                        return number.value;
                    },
                    [&](const Percentage& percentage) -> double {
                        if (percentageResolveToDimension(options)) {
                            result = FailureTag { };
                            return std::numeric_limits<double>::quiet_NaN();
                        }
                        result = PercentageTag { };
                        return percentage.value;
                    },
                    [&](const CanonicalDimension& dimension) -> double {
                        result = DimensionTag { dimension.dimension };
                        return dimension.value;
                    },
                    [&](const auto&) -> double {
                        result = FailureTag { };
                        return std::numeric_limits<double>::quiet_NaN();
                    }
                );
            },
            [&](const NumberTag&) -> double {
                if (auto* numberChild = get_if<Number>(&child))
                    return numberChild->value;
                result = FailureTag { };
                return std::numeric_limits<double>::quiet_NaN();
            },
            [&](const PercentageTag&) -> double {
                if (auto* percentageChild = get_if<Percentage>(&child))
                    return percentageChild->value;
                result = FailureTag { };
                return std::numeric_limits<double>::quiet_NaN();
            },
            [&](const DimensionTag& tag) -> double {
                if (auto* dimensionChild = get_if<CanonicalDimension>(&child); dimensionChild && dimensionChild->dimension == tag.dimension)
                    return dimensionChild->value;
                result = FailureTag { };
                return std::numeric_limits<double>::quiet_NaN();
            },
            [&](const FailureTag&) -> double {
                return std::numeric_limits<double>::quiet_NaN();
            }
        );
    });

    return WTF::switchOn(result,
        [&](const NumberTag&) -> std::optional<Child> {
            return makeChild(Number { .value = value });
        },
        [&](const PercentageTag&) -> std::optional<Child> {
            return makeChild(Percentage { .value = value, .hint = Type::determinePercentHint(options.category) });
        },
        [&](const DimensionTag& tag) -> std::optional<Child> {
            return makeChild(CanonicalDimension { .value = value, .dimension = tag.dimension });
        },
        [&](const auto&) -> std::optional<Child> {
            return { };
        }
    );
}

std::optional<Child> simplify(Log& root, const SimplificationOptions&)
{
    // NOTE: `a` and `b` have been type checked by this point to be `<number>`, though they may not
    // be able to be fully resolved yet.

    if (root.b) {
        return switchTogether(root.a, *root.b,
            [&](const Number& a, const Number& b) -> std::optional<Child> {
                return makeChild(Number { .value = executeMathOperation<Log>(a.value, b.value) });
            },
            [](const auto&, const auto&) -> std::optional<Child> {
                return { };
            }
        );
    }

    return WTF::switchOn(root.a,
        [](const Number& a) -> std::optional<Child> {
            return makeChild(Number { .value = executeMathOperation<Log>(a.value) });
        },
        [](const auto&) -> std::optional<Child> {
            return { };
        }
    );
}

std::optional<Child> simplify(Exp& root, const SimplificationOptions&)
{
    // NOTE: `a` has been type checked by this point to be `<number>`, though they may not
    // be able to be fully resolved yet.

    return WTF::switchOn(root.a,
        [](const Number& a) -> std::optional<Child> {
            return makeChild(Number { .value = executeMathOperation<Exp>(a.value) });
        },
        [](const auto&) -> std::optional<Child> {
            return { };
        }
    );
}

std::optional<Child> simplify(Abs& root, const SimplificationOptions& options)
{
    return WTF::switchOn(root.a,
        [&]<Numeric T>(const T& a) -> std::optional<Child> {
            if (!magnitudeComparable(a, options))
                return { };
            return makeChildWithValueBasedOn(executeMathOperation<Abs>(a.value), a);
        },
        [](const auto&) -> std::optional<Child> {
            return { };
        }
    );
}

std::optional<Child> simplify(Sign& root, const SimplificationOptions& options)
{
    return WTF::switchOn(root.a,
        [&]<Numeric T>(const T& a) -> std::optional<Child> {
            if (!magnitudeComparable(a, options))
                return { };
            return makeChild(Number { .value = executeMathOperation<Sign>(a.value) });
        },
        [](const auto&) -> std::optional<Child> {
            return { };
        }
    );
}

std::optional<Child> simplify(Random& root, const SimplificationOptions& options)
{
    if (!options.conversionData || !options.conversionData->styleBuilderState())
        return { };
    if (root.min.index() != root.max.index() || (root.step && root.step->index() != root.min.index()))
        return { };

    return WTF::switchOn(root.min,
        [&]<Numeric T>(const T& numericMin) -> std::optional<Child> {
            auto numericMax = get<T>(root.max);

            if (!unitsMatch(numericMin, numericMax, options) || !fullyResolved(numericMin, options))
                return { };

            std::optional<double> valueStep;
            if (root.step) {
                auto numericStep = get<T>(*root.step);

                if (!unitsMatch(numericMin, numericStep, options))
                    return { };

                valueStep = numericStep.value;
            }

            // A fixed <number> can only be simplified here when it is a raw value; a calc-based fixed value
            // needs full evaluation. All other sharing resolves through the shared resolver.
            std::optional<double> randomBaseValue;
            if (auto* sharingFixed = std::get_if<Random::SharingFixed>(&root.sharing)) {
                randomBaseValue = WTF::switchOn(sharingFixed->value,
                    [](const CSS::Number<CSS::ClosedUnitRange>::Raw& raw) -> std::optional<double> {
                        return raw.value;
                    },
                    [](const CSS::Number<CSS::ClosedUnitRange>::Calc&) -> std::optional<double> {
                        return { };
                    }
                );
            } else {
                CheckedPtr builderState = options.conversionData->styleBuilderState();
                randomBaseValue = resolveRandomBaseValue(root.sharing, *builderState);
            }
            if (!randomBaseValue)
                return { };

            return makeChildWithValueBasedOn(executeMathOperation<Random>(*randomBaseValue, numericMin.value, numericMax.value, valueStep), numericMin);
        },
        [](const auto&) -> std::optional<Child> {
            return { };
        }
    );

    return { };
}

std::optional<Child> simplify(Progress& root, const SimplificationOptions& options)
{
    if (root.value.index() != root.start.index() || root.start.index() != root.end.index())
        return { };

    return WTF::switchOn(root.value,
        [&]<Numeric T>(const T& numericValue) -> std::optional<Child> {
            const auto& numericStart = get<T>(root.start);
            const auto& numericEnd = get<T>(root.end);

            if (!unitsMatch(numericValue, numericStart, options) || !unitsMatch(numericStart, numericEnd, options) || !fullyResolved(numericValue, options))
                return { };

            return makeChild(Number { .value = executeMathOperation<Progress>(numericValue.value, numericStart.value, numericEnd.value) });
        },
        [](const auto&) -> std::optional<Child> {
            return { };
        }
    );
}

std::optional<Child> simplify(ProgressNoClamp& root, const SimplificationOptions& options)
{
    if (root.value.index() != root.start.index() || root.start.index() != root.end.index())
        return { };

    return WTF::switchOn(root.value,
        [&]<Numeric T>(const T& numericValue) -> std::optional<Child> {
            const auto& numericStart = get<T>(root.start);
            const auto& numericEnd = get<T>(root.end);

            if (!unitsMatch(numericValue, numericStart, options) || !unitsMatch(numericStart, numericEnd, options) || !fullyResolved(numericValue, options))
                return { };

            return makeChild(Number { .value = executeMathOperation<ProgressNoClamp>(numericValue.value, numericStart.value, numericEnd.value) });
        },
        [](const auto&) -> std::optional<Child> {
            return { };
        }
    );
}

std::optional<Child> simplify(CalcMix& root, const SimplificationOptions& options)
{
    auto zeroValueMatchingChild = [options](auto& child) -> Child {
        auto childType = getType(child.value);
        auto category = childType.calculationCategory();
        // `calculationCategory()` is `std::nullopt` for a mixed-base type (`px * s`) or a power
        // other than 1 (`px * px`). `parseAndSimplify`'s type check rejects both, but other callers
        // are not bound by it.
        RELEASE_ASSERT(category);
        switch (*category) {
        case CSS::Category::Integer:
        case CSS::Category::Number:
            return makeChild(Number { .value = 0 });
        case CSS::Category::Percentage:
            return makeChild(Percentage { .value = 0, .hint = Type::determinePercentHint(options.category) });
        case CSS::Category::LengthPercentage:
            return makeChild(Percentage { .value = 0, .hint = PercentHint::Length });
        case CSS::Category::Length:
            return makeChild(CanonicalDimension { .value = 0, .dimension = CanonicalDimension::Dimension::Length });
        case CSS::Category::Angle:
            return makeChild(CanonicalDimension { .value = 0, .dimension = CanonicalDimension::Dimension::Angle });
        case CSS::Category::AnglePercentage:
            return makeChild(Percentage { .value = 0, .hint = PercentHint::Angle });
        case CSS::Category::Time:
            return makeChild(CanonicalDimension { .value = 0, .dimension = CanonicalDimension::Dimension::Time });
        case CSS::Category::Frequency:
            return makeChild(CanonicalDimension { .value = 0, .dimension = CanonicalDimension::Dimension::Frequency });
        case CSS::Category::Resolution:
            return makeChild(CanonicalDimension { .value = 0, .dimension = CanonicalDimension::Dimension::Resolution });
        case CSS::Category::Flex:
            return makeChild(CanonicalDimension { .value = 0, .dimension = CanonicalDimension::Dimension::Flex });
        }
        // Only an out-of-range `CSS::Category` reaches this; returning a zero would give it the
        // wrong type.
        RELEASE_ASSERT_NOT_REACHED();
    };

    bool canNormalize = true;
    unsigned numberOfKnownZeroWeights = 0;

    for (auto& item : root.children) {
        if (!item.weight)
            continue;
        WTF::switchOn(*item.weight,
            [&](const CalcMix::Item::Weight::Raw& raw) {
                if (!raw.value)
                    ++numberOfKnownZeroWeights;
            },
            [&](const CalcMix::Item::Weight::Calc&) {
                canNormalize = false;
            }
        );
    }

    // If not all the percentage weights are fully resolvable (e.g. `calc-mix(10px calc(50% * sibling-index()), 20px)`
    // at parse time) we can't normalize.
    if (!canNormalize) {
        // Even if we can't normalize, we can still remove any items with a weight that is known to be zero.
        if (numberOfKnownZeroWeights > 0) {
            auto newNumberOfChildren = root.children.size() - numberOfKnownZeroWeights;

            // If all the weights are known to be zero, we can simplify all the way down zero value for the calc-mix itself.
            if (!newNumberOfChildren)
                return zeroValueMatchingChild(root.children[0]);

            Vector<CalcMix::Item> newChildren;
            newChildren.reserveInitialCapacity(newNumberOfChildren);
            for (auto& item : root.children) {
                // Skip any known zero weights.
                if (item.weight && item.weight->isKnownZero())
                    continue;
                newChildren.append(WTF::move(item));
            }
            root.children = WTF::move(newChildren);
        }
        return { };
    }

    struct InputCalcMixWeight {
        std::optional<CalcMix::Item::Weight::Raw> percentage;
    };

    // NOTE: Per spec, "Any “leftover” mix percentage is applied to a consistently-typed zero value, and thus effectively discarded".
    auto [percentages, _] = CSS::normalizedMixPercentages<CSS::ForceNormalization::No>(root.children | std::views::transform([](const auto& item) {
        return InputCalcMixWeight { .percentage = item.weight ? item.weight->raw() : std::nullopt };
    }));

    // Remove any items with a weight of 0, including items with omitted weights when the specified weights sum to 100% or more.
    Vector<CalcMix::Item> newChildren;
    for (auto [item, normalizedWeight] : zippedRange(root.children, percentages)) {
        if (!normalizedWeight)
            continue;
        item.weight = CalcMix::Item::Weight { normalizedWeight };
        newChildren.append(WTF::move(item));
    }

    // If all the weights are zero, we can simplify all the way down zero value for the calc-mix itself.
    if (newChildren.isEmpty())
        return zeroValueMatchingChild(root.children[0]);

    root.children = WTF::move(newChildren);

    // Types used to check if all the values are fully simplified down to the same type.
    // This can fail in cases like:
    //     width: calc-mix(10% 25%, 10px 75%) - <length-percentage> result allows either <percentage> or <length> values, but <percentage> is not resolvable until later.
    //     width: calc-mix(10px * sibling-index() 25%, 10px 75%) - `10px * sibling-index()` cannot be fully simplified until later.
    //     width: calc-mix(10em 25%, 10px 75%) - `10em` cannot be resolved until later.

    std::optional<Variant<Number, Percentage, CanonicalDimension, NonCanonicalDimension>> result;

    for (auto& item : root.children) {
        auto weight = item.weight->raw()->value / 100.0;

        bool success = WTF::switchOn(item.value,
            [&](const Number& value) {
                if (!result) {
                    result = Number { .value = value.value * weight };
                    return true;
                }
                if (!WTF::holdsAlternative<Number>(*result))
                    return false;

                auto addition = value.value * weight;
                auto newResult = get<Number>(*result).value + addition;
                get<Number>(*result).value = newResult;
                return true;
            },
            [&](const Percentage& value) {
                if (!result) {
                    result = Percentage { .value = value.value * weight, .hint = value.hint };
                    return true;
                }
                if (!WTF::holdsAlternative<Percentage>(*result) || get<Percentage>(*result).hint != value.hint)
                    return false;

                auto addition = value.value * weight;
                auto newResult = get<Percentage>(*result).value + addition;
                get<Percentage>(*result).value = newResult;
                return true;
            },
            [&](const CanonicalDimension& value) {
                if (!result) {
                    result = CanonicalDimension { .value = value.value * weight, .dimension = value.dimension };
                    return true;
                }
                if (!WTF::holdsAlternative<CanonicalDimension>(*result) || get<CanonicalDimension>(*result).dimension != value.dimension)
                    return false;

                auto addition = value.value * weight;
                auto newResult = get<CanonicalDimension>(*result).value + addition;
                get<CanonicalDimension>(*result).value = newResult;
                return true;
            },
            [&](const NonCanonicalDimension& value) {
                if (!result) {
                    result = NonCanonicalDimension { .value = value.value * weight, .unit = value.unit };
                    return true;
                }
                if (!WTF::holdsAlternative<NonCanonicalDimension>(*result) || get<NonCanonicalDimension>(*result).unit != value.unit)
                    return false;

                auto addition = value.value * weight;
                auto newResult = get<NonCanonicalDimension>(*result).value + addition;
                get<NonCanonicalDimension>(*result).value = newResult;
                return true;
            },
            [&](const auto&) {
                return false;
            }
        );
        if (!success)
            return { };
    }

    return WTF::switchOn(*result,
        [&]<Numeric T>(const T& numeric) -> std::optional<Child> {
            return makeChild(numeric);
        }
    );
}

std::optional<Child> simplify(Anchor& anchor, const SimplificationOptions& options)
{
    if (!options.conversionData || !options.conversionData->styleBuilderState())
        return { };

    auto evaluationOptions = EvaluationOptions {
        .category = options.category,
        .range = CSS::All,
        .conversionData = options.conversionData,
        .symbolTable = options.symbolTable
    };

    auto result = evaluateWithoutFallback(anchor, evaluationOptions);
    if (!result) {
        // https://drafts.csswg.org/css-anchor-position-1/#anchor-valid
        // "If any of these conditions are false, the anchor() function resolves to its specified fallback value.
        // If no fallback value is specified, it makes the declaration referencing it invalid at computed-value time."

        if (!anchor.fallback)
            options.conversionData->styleBuilderState()->setCurrentPropertyInvalidAtComputedValueTime();

        // Replace the anchor node with the fallback node.
        return std::exchange(anchor.fallback, { });
    }
    return CanonicalDimension { .value = *result, .dimension = CanonicalDimension::Dimension::Length };
}

std::optional<Child> simplify(AnchorSize& anchorSize, const SimplificationOptions& options)
{
    if (!options.conversionData || !options.conversionData->styleBuilderState())
        return { };

    CheckedPtr builderState = options.conversionData->styleBuilderState();

    std::optional<Style::ScopedName> anchorSizeScopedName;
    if (anchorSize.elementName) {
        anchorSizeScopedName = Style::ScopedName {
            .name = Style::toStyle(*anchorSize.elementName, *builderState).value,
            .scopeOrdinal = builderState->styleScopeOrdinal()
        };
    }

    auto result = Style::AnchorPositionEvaluator::evaluateSize(*builderState, anchorSizeScopedName, anchorSize.dimension);

    if (!result) {
        if (!anchorSize.fallback)
            options.conversionData->styleBuilderState()->setCurrentPropertyInvalidAtComputedValueTime();

        return std::exchange(anchorSize.fallback, { });
    }

    return CanonicalDimension { .value = *result, .dimension = CanonicalDimension::Dimension::Length };
}

// MARK: Copy & Simplify.

Random::Sharing copyAndSimplify(const Random::Sharing& root, const SimplificationOptions&)
{
    return root;
}

CalcMix::Item copyAndSimplify(const CalcMix::Item& root, const SimplificationOptions& options)
{
    return { .value = copyAndSimplify(root.value, options), .weight = root.weight };
}

Vector<CalcMix::Item> copyAndSimplify(const Vector<CalcMix::Item>& items, const SimplificationOptions& options)
{
    return WTF::map(items, [&](auto& item) { return copyAndSimplify(item, options); });
}

CSS::Keyword::None NODELETE copyAndSimplify(const CSS::Keyword::None& root, const SimplificationOptions&)
{
    return root;
}

Children copyAndSimplify(const Children& children, const SimplificationOptions& options)
{
    return WTF::map(children, [&](auto& child) { return copyAndSimplify(child, options); });
}

auto copyAndSimplify(const ChildOrNone& root, const SimplificationOptions& options) -> ChildOrNone
{
    return WTF::switchOn(root, [&](auto& root) { return ChildOrNone { copyAndSimplify(root, options) }; });
}

template<typename T> auto copyAndSimplify(const std::optional<T>& root, const SimplificationOptions& options) -> std::optional<T>
{
    if (root)
        return copyAndSimplify(*root, options);
    return { };
}

template<Leaf Op> static auto copyAndSimplifyChildren(const Op& op, const SimplificationOptions&) -> Op
{
    return op;
}

template<typename Op> static auto copyAndSimplifyChildren(const IndirectNode<Op>& root, const SimplificationOptions& options) -> Op
{
    return WTF::apply([&](const auto& ...x) { return Op { copyAndSimplify(x, options)... }; } , *root);
}

static auto copyAndSimplifyChildren(const IndirectNode<Anchor>& anchor, const SimplificationOptions& options) -> Anchor
{
    return Anchor { .elementName = anchor->elementName, .side = copy(anchor->side), .fallback = copyAndSimplify(anchor->fallback, options) };
}

static auto copyAndSimplifyChildren(const IndirectNode<AnchorSize>& anchorSize, const SimplificationOptions& options) -> AnchorSize
{
    return AnchorSize {
        .elementName = anchorSize->elementName,
        .dimension = anchorSize->dimension,
        .fallback = copyAndSimplify(anchorSize->fallback, options)
    };
}

Child copyAndSimplify(const Child& root, const SimplificationOptions& options)
{
    return WTF::switchOn(root,
        [&](const auto& root) -> Child {
            // Create a simplified copy by recursively calling simplify on all children.
            auto simplified = copyAndSimplifyChildren(root, options);

            // Attempt to simplify the term itself, using the result as a replacement if successful.
            if (auto replacement = simplify(simplified, options))
                return WTF::move(*replacement);

            return makeChild(WTF::move(simplified), getType(root));
        }
    );
}
#endif // CSS_CALC_CPP_SIMPLIFIER_COMPILED_IN

// MARK: - The Swift calc simplification path (CSSCalcSimplificationSwift.swift)
#if USE(SWIFT_CSS)
//
// The storage a `Tree` holds its Swift root in, and the upcalls Swift's folds and walks make.

// MARK: The stored Swift root

// `m_root` holds a `CSSCalcSwiftRoot` created by placement new, so reading it back needs
// `std::launder`: a pointer to the byte array is not a pointer to the object nested in it.
static CSSCalcSwiftRoot& storedRoot(unsigned char* bytes)
{
    return *std::launder(reinterpret_cast<CSSCalcSwiftRoot*>(bytes));
}

static_assert(sizeof(CSSCalcSwiftRoot) == 8 && alignof(CSSCalcSwiftRoot) <= 8);

CSSCalcSwiftStoredRoot::CSSCalcSwiftStoredRoot(const CSSCalcSwiftRoot& root, RefPtr<CSSCalcSwiftFlatPayloadsBox>&& payloads)
    : m_payloads(WTF::move(payloads))
{
    new (m_root) CSSCalcSwiftRoot(root);
}

// The generated `CSSCalcSwiftRoot` moves by copying (`swift::_impl::RefCountedClass`).
CSSCalcSwiftStoredRoot::CSSCalcSwiftStoredRoot(const CSSCalcSwiftStoredRoot& other)
    : m_payloads(other.m_payloads)
{
    new (m_root) CSSCalcSwiftRoot(other.root());
}

CSSCalcSwiftStoredRoot::CSSCalcSwiftStoredRoot(CSSCalcSwiftStoredRoot&& other)
    : CSSCalcSwiftStoredRoot(other)
{
}

CSSCalcSwiftStoredRoot& CSSCalcSwiftStoredRoot::operator=(const CSSCalcSwiftStoredRoot& other)
{
    storedRoot(m_root) = other.root();
    m_payloads = other.m_payloads;
    return *this;
}

CSSCalcSwiftStoredRoot& CSSCalcSwiftStoredRoot::operator=(CSSCalcSwiftStoredRoot&& other)
{
    return *this = other;
}

CSSCalcSwiftStoredRoot::~CSSCalcSwiftStoredRoot()
{
    storedRoot(m_root).~CSSCalcSwiftRoot();
}

bool CSSCalcSwiftStoredRoot::operator==(const CSSCalcSwiftStoredRoot& other) const
{
    return cssCalcSwiftRootsEqual(root(), other.root(), CSSCalcSwiftPayloadComparer { .first = payloads(), .second = other.payloads() });
}

bool CSSCalcSwiftPayloadComparer::equal(uint32_t a, uint32_t b) const noexcept
{
    return first && second && a < first->size() && b < second->size() && (*first)[a] == (*second)[b];
}

const CSSCalcSwiftRoot& CSSCalcSwiftStoredRoot::root() const
{
    return storedRoot(const_cast<unsigned char*>(m_root));
}

const CSSCalcSwiftFlatPayloads* CSSCalcSwiftStoredRoot::payloads() const
{
    return m_payloads ? &m_payloads->payloads : nullptr;
}

RefPtr<CSSCalcSwiftFlatPayloadsBox> CSSCalcSwiftStoredRoot::payloadsBox() const
{
    return m_payloads;
}

// The payload node `index` names. See the declaration for why each failure refuses.
template<typename T> const T* CSSCalcSwiftBuilder::payloadFor(uint32_t index) const noexcept
{
    if (!m_payloads || index >= m_payloads->size())
        return nullptr;
    return get_if<T>(&(*m_payloads)[index]);
}

// The `SimplificationOptions` fields Swift reads, as a POD.
static CSSCalcSwiftSimplificationOptions swiftSimplificationOptions(const SimplificationOptions& options)
{
    return CSSCalcSwiftSimplificationOptions {
        .rangeMinimum = options.range.min,
        .rangeMaximum = options.range.max,
        .category = static_cast<uint8_t>(options.category),
        .allowZeroValueLengthRemovalFromSum = options.allowZeroValueLengthRemovalFromSum,
        .hasConversionData = options.conversionData.has_value(),
        .percentageResolveToDimension = percentageResolveToDimension(options),
    };
}

// The thunk's result is a prvalue, so the root is constructed in place from Swift's +1 reference.
CSSCalcSwiftStoredRoot::CSSCalcSwiftStoredRoot(const CSSCalcSwiftParseRequest& request)
{
    // The payloads the parse resolves, which the stored tree keeps.
    CSSCalcSwiftFlatPayloads payloads;
    CSSCalcSwiftBuilder builder { request.options, &payloads };
    auto cursor = CSSCalcSwiftParseCursor { request.tokens, request.symbols, &request.propertyParserState, &payloads };
    new (m_root) CSSCalcSwiftRoot(cssCalcParseSwift(cursor, builder, request.parseOptions, swiftSimplificationOptions(request.options), true, request.result));
    if (request.result.outcome == static_cast<uint8_t>(CSSCalcSwiftParseOutcome::Parsed) && !payloads.isEmpty())
        m_payloads = adoptRef(*new CSSCalcSwiftFlatPayloadsBox(WTF::move(payloads)));
}

static constexpr CSSCalcSwiftNumericResult unresolvedNumber { .value = 0, .unitType = static_cast<uint16_t>(CSSUnitType::Unknown), .resolved = false, .alternative = CSSCalcSwiftAlternative::Number, .substituteFallback = false };

static constexpr CSSCalcSwiftNumericResult resolvedNumber(double value)
{
    return { .value = value, .unitType = static_cast<uint16_t>(CSSUnitType::Number), .resolved = true, .alternative = CSSCalcSwiftAlternative::Number, .substituteFallback = false };
}

// A resolved canonical `<length>`, as `simplify(Anchor&)` and `simplify(AnchorSize&)` produce.
static constexpr CSSCalcSwiftNumericResult resolvedCanonicalLength(double value)
{
    return { .value = value, .unitType = static_cast<uint16_t>(toCSSUnit(CanonicalDimension::Dimension::Length)), .resolved = true, .alternative = CSSCalcSwiftAlternative::CanonicalDimension, .substituteFallback = false };
}

CSSCalcSwiftNumericResult CSSCalcSwiftBuilder::resolveTreeCounting(CSSCalcSwiftAlternative alternative) const noexcept
{
    CheckedPtr builderState = hasStyleBuilderState() ? m_options->conversionData->styleBuilderState() : nullptr;
    if (!builderState || !builderState->element())
        return unresolvedNumber;
    return resolvedNumber(static_cast<double>(alternative == CSSCalcSwiftAlternative::SiblingCount ? builderState->siblingCount() : builderState->siblingIndex()));
}

CSSCalcSwiftNumericResult CSSCalcSwiftBuilder::resolveAnchor(CSSCalcSwiftAlternative alternative, uint32_t elementNamePayload, uint16_t valueID, double sideFraction) const noexcept
{
    if (!hasStyleBuilderState())
        return unresolvedNumber;
    CheckedPtr builderState = m_options->conversionData->styleBuilderState();

    std::optional<Style::ScopedName> elementName;
    if (elementNamePayload != cssCalcSwiftFlatNoNode) {
        auto* name = payloadFor<CSS::CustomIdent>(elementNamePayload);
        if (!name)
            return unresolvedNumber;
        elementName = Style::ScopedName { .name = Style::toStyle(*name, *builderState).value, .scopeOrdinal = builderState->styleScopeOrdinal() };
    }

    auto id = static_cast<CSSValueID>(valueID);
    auto result = alternative == CSSCalcSwiftAlternative::Anchor
        ? Style::AnchorPositionEvaluator::evaluate(*builderState, WTF::move(elementName), id ? Style::AnchorPositionEvaluator::Side { id } : Style::AnchorPositionEvaluator::Side { sideFraction })
        : Style::AnchorPositionEvaluator::evaluateSize(*builderState, WTF::move(elementName), id ? cssValueIDToAnchorSizeDimension(id) : std::nullopt);
    return result ? resolvedCanonicalLength(*result) : unresolvedNumber;
}

CSSCalcSwiftNumericResult CSSCalcSwiftBuilder::resolveCalcMixWeight(double value, bool present, uint32_t payload) const noexcept
{
    if (!m_options->conversionData || !m_options->conversionData->styleBuilderState())
        return unresolvedNumber;
    if (!present)
        return { .value = 0, .unitType = static_cast<uint16_t>(CSSUnitType::Unknown), .resolved = true, .alternative = CSSCalcSwiftAlternative::Number, .substituteFallback = true };
    CheckedPtr builderState = m_options->conversionData->styleBuilderState();
    if (payload == cssCalcSwiftFlatNoNode)
        return resolvedNumber(Style::toStyle(CalcMix::Item::Weight { value }, *builderState).value);
    auto* weight = payloadFor<CalcMix::Item::Weight>(payload);
    if (!weight)
        return unresolvedNumber;
    return resolvedNumber(Style::toStyle(*weight, *builderState).value);
}

CSSCalcSwiftNumericResult CSSCalcSwiftBuilder::resolveRandomBaseValue(uint32_t payload, bool evaluatesFixedCalc) const noexcept
{
    auto* sharing = payloadFor<Random::Sharing>(payload);
    if (!sharing || !hasStyleBuilderState())
        return unresolvedNumber;
    if (auto* fixed = std::get_if<Random::SharingFixed>(sharing); fixed && !evaluatesFixedCalc) {
        return WTF::switchOn(fixed->value,
            [](const CSS::Number<CSS::ClosedUnitRange>::Raw& raw) { return resolvedNumber(raw.value); },
            [](const CSS::Number<CSS::ClosedUnitRange>::Calc&) { return unresolvedNumber; }
        );
    }
    CheckedPtr builderState = m_options->conversionData->styleBuilderState();
    if (auto base = CSSCalc::resolveRandomBaseValue(*sharing, *builderState))
        return resolvedNumber(*base);
    return unresolvedNumber;
}

bool CSSCalcSwiftBuilder::hasStyleBuilderState() const noexcept
{
    return m_options->conversionData && m_options->conversionData->styleBuilderState();
}

void CSSCalcSwiftBuilder::markCurrentPropertyInvalidAtComputedValueTime() const noexcept
{
    if (hasStyleBuilderState())
        m_options->conversionData->styleBuilderState()->setCurrentPropertyInvalidAtComputedValueTime();
}

CSSCalcSwiftNumericResult CSSCalcSwiftBuilder::resolveSymbol(uint16_t valueID) const noexcept
{
    // A miss leaves the `Symbol` unchanged. Not a failure.
    auto value = m_options->symbolTable.get(static_cast<CSSValueID>(valueID));
    return value ? resolvedNumber(value->value) : unresolvedNumber;
}

CSSCalcSwiftNumericResult CSSCalcSwiftBuilder::resolveRelativeLength(double value, uint16_t unitType) const noexcept
{
    // `canonicalize`'s `tryMakeCanonical`. `canonicalizedDimension` in
    // CSSCalcSimplificationSwift.swift handles the other units.
    //
    // `CSS::toLengthUnit` is the only statement of which units reach this.
    //
    // Both optionals are checked: unlike in `canonicalize`, nothing has established that the unit
    // is a length unit.
    if (auto lengthUnit = CSS::toLengthUnit(static_cast<CSSUnitType>(unitType)); lengthUnit && m_options->conversionData)
        return resolvedCanonicalLength(Style::resolveLength(value, *lengthUnit, *m_options->conversionData));
    return unresolvedNumber;
}


#endif // USE(SWIFT_CSS)

#if USE(SWIFT_CSS)
template<typename Payload> static uint32_t storePayload(CSSCalcSwiftFlatPayloads& payloads, const Payload& payload)
{
    payloads.append(payload);
    return static_cast<uint32_t>(payloads.size() - 1);
}

// Push `node` onto `builder`, children first, with its payloads copied into `payloads`.
//
// The producers are `Style::Calculation::toCSS` and the Typed OM, neither of which can build a tree
// counting function or an anchor function, so those refuse.
static bool storeNode(CSSCalcSwiftStoreBuilder& builder, CSSCalcSwiftFlatPayloads& payloads, const Child& node)
{
    auto alternative = static_cast<CSSCalcSwiftAlternative>(node.value.index());
    auto leaf = [&](double value, CSSUnitType unit, uint8_t percentHint = 0, CSSValueID valueID = CSSValueInvalid) {
        builder.pushLeaf(alternative, value, static_cast<uint8_t>(unit), percentHint, static_cast<uint16_t>(valueID));
        return true;
    };
    auto operation = [&](const auto& op, uint32_t count, uint8_t noneMask = 0, uint32_t origin = cssCalcSwiftFlatNoNode) {
        return builder.pushOperation(alternative, count, op.type, noneMask, origin);
    };
    auto children = [&](const auto& op) {
        uint32_t count = 0;
        bool ok = true;
        forAllChildNodes(*op, [&](const Child& child) {
            ok = ok && storeNode(builder, payloads, child);
            ++count;
        });
        return ok ? std::optional { count } : std::nullopt;
    };
    return WTF::switchOn(node,
        [&](const Number& number) { return leaf(number.value, CSSUnitType::Number); },
        [&](const Percentage& percentage) { return leaf(percentage.value, CSSUnitType::Percentage, percentage.hint ? static_cast<uint8_t>(*percentage.hint) : 0); },
        [&](const CanonicalDimension& dimension) { return leaf(dimension.value, toCSSUnit(dimension)); },
        [&](const NonCanonicalDimension& dimension) { return leaf(dimension.value, dimension.unit); },
        [&](const Symbol& symbol) { return leaf(0, symbol.unit, 0, symbol.id); },
        [&](const SiblingCount&) { return false; },
        [&](const SiblingIndex&) { return false; },
        [&](const IndirectNode<Anchor>&) { return false; },
        [&](const IndirectNode<AnchorSize>&) { return false; },
        [&](const IndirectNode<CalcMix>& calcMix) {
            for (auto& item : calcMix->children) {
                if (!storeNode(builder, payloads, item.value))
                    return false;
                auto raw = item.weight ? item.weight->raw() : std::nullopt;
                builder.pushCalcMixWeight(raw ? raw->value : 0, item.weight.has_value(), item.weight && !raw ? storePayload(payloads, *item.weight) : cssCalcSwiftFlatNoNode);
            }
            return operation(calcMix, calcMix->children.size() * 2);
        },
        [&](const IndirectNode<Random>& random) {
            auto count = children(random);
            return count && operation(random, *count, 0, storePayload(payloads, random->sharing));
        },
        [&](const IndirectNode<Clamp>& clamp) {
            auto count = children(clamp);
            uint8_t noneMask = (WTF::holdsAlternative<CSS::Keyword::None>(clamp->min) ? 1 : 0) | (WTF::holdsAlternative<CSS::Keyword::None>(clamp->max) ? 2 : 0);
            return count && operation(clamp, *count, noneMask);
        },
        [&](const auto& op) {
            auto count = children(op);
            return count && operation(op, *count);
        }
    );
}

static std::optional<CSSCalcSwiftStoredRoot> storedFormOf(const Child& root)
{
    CSSCalcSwiftFlatPayloads payloads;
    auto builder = CSSCalcSwiftStoreBuilder::init();
    if (!storeNode(builder, payloads, root))
        return std::nullopt;
    if (!builder.isFinished())
        return std::nullopt;
    return CSSCalcSwiftStoredRoot { builder.finish(), payloads.isEmpty() ? nullptr : RefPtr { adoptRef(*new CSSCalcSwiftFlatPayloadsBox(WTF::move(payloads))) } };
}

Tree makeTree(Child&& root, Type type, Stage stage, bool requiresConversionData)
{
    auto stored = storedFormOf(root);
    // Every node a C++ producer builds has a Swift form, and nothing in this build reads a tree
    // without one.
    RELEASE_ASSERT_WITH_MESSAGE(stored, "a calc() tree built in C++ has no Swift form");
    return Tree { .stored = WTF::move(*stored), .type = type, .stage = stage, .requiresConversionData = requiresConversionData };
}

bool Tree::rootEquals(const Tree& other) const
{
    return stored == other.stored;
}

bool Tree::rootIsPercentage() const
{
    return cssCalcSwiftRootAlternative(stored.root()) == CSSCalcSwiftAlternative::Percentage;
}

Type Tree::rootType() const
{
    return cssCalcSwiftRootType(stored.root());
}
#else
Tree makeTree(Child&& root, Type type, Stage stage, bool requiresConversionData)
{
    return Tree { .root = WTF::move(root), .type = type, .stage = stage, .requiresConversionData = requiresConversionData };
}

bool Tree::rootEquals(const Tree& other) const
{
    return root == other.root;
}

bool Tree::rootIsPercentage() const
{
    return WTF::holdsAlternative<Percentage>(root);
}

Type Tree::rootType() const
{
    return getType(root);
}
#endif

Tree copyAndSimplify(const Tree& tree, const SimplificationOptions& options)
{
#if CSS_CALC_CPP_SIMPLIFIER_COMPILED_IN
    return Tree {
        .root = copyAndSimplify(tree.root, options),
        .type = tree.type,
        .stage = tree.stage,
        .requiresConversionData = tree.requiresConversionData,
    };
#else
    CSSCalcSwiftBuilder builder { options, tree.stored.payloads() };
    bool simplified = false;
    auto simplifiedRoot = cssCalcSimplifyStoredSwift(tree.stored.root(), builder, swiftSimplificationOptions(options), simplified);
    if (simplified) {
        return Tree {
            .stored = CSSCalcSwiftStoredRoot { simplifiedRoot, tree.stored.payloadsBox() },
            .type = tree.type,
            .stage = tree.stage,
            .requiresConversionData = tree.requiresConversionData,
        };
    }

    // There is no C++ simplifier in this build and `copyAndSimplify` has no failure channel.
    // Returning the tree unsimplified would be a silently wrong computed value.
    RELEASE_ASSERT_NOT_REACHED_WITH_MESSAGE("the Swift calc() simplifier declined a tree");
#endif
}

// MARK: - Can Simplify

#if CSS_CALC_CPP_SIMPLIFIER_COMPILED_IN
// NOTE: This is a simple and conservative implementation of `canSimplify`. A more precise
// implementation is possible by utilizing the provided `SimplificationOptions` if that should be
// necessary.
static bool canSimplifyWithCpp(const Tree& tree, const SimplificationOptions&)
{
    return WTF::switchOn(tree.root,
        [&](const Number&) -> bool {
            return false;
        },
        [&](const Percentage&) -> bool {
            return false;
        },
        [&](const CanonicalDimension&) -> bool {
            return false;
        },
        [&](auto const&) -> bool {
            return true;
        }
    );
}
#endif // CSS_CALC_CPP_SIMPLIFIER_COMPILED_IN

#if USE(SWIFT_CSS)
std::optional<double> evaluateDoubleWithSwift(const Tree& tree, const EvaluationOptions& options)
{
    // The builder carries the conversion data Swift reads, as a `SimplificationOptions`.
    SimplificationOptions simplificationOptions {
        .category = options.category,
        .range = options.range,
        .conversionData = options.conversionData,
        .symbolTable = options.symbolTable,
    };
    CSSCalcSwiftBuilder builder { simplificationOptions, tree.stored.payloads() };
    auto result = cssCalcEvaluateSwift(tree.stored.root(), builder, simplificationOptions.conversionData.has_value());
    if (result.resolved)
        return result.value;
#if !CSS_CALC_CPP_EVALUATOR_COMPILED_IN
    RELEASE_ASSERT_WITH_MESSAGE(!result.substituteFallback, "the Swift calc() evaluator refused a tree in a build with no C++ evaluator compiled in");
#endif
    return std::nullopt;
}
#endif // USE(SWIFT_CSS)

bool canSimplify(const Tree& tree, const SimplificationOptions& options)
{
    // `canSimplify(t) == false` must imply `copyAndSimplify(t) == t`, which holds because `simplify`
    // is a no-op for the three alternatives it answers false for.
#if CSS_CALC_CPP_SIMPLIFIER_COMPILED_IN
    return canSimplifyWithCpp(tree, options);
#else
    UNUSED_PARAM(options);
    return cssCalcCanSimplifySwift(tree.stored.root());
#endif
}

} // namespace CSSCalc
} // namespace WebCore
