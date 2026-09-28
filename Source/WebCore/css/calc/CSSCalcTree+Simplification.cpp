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
#include <atomic>
#include <bit>
#include <wtf/StdLibExtras.h>

namespace WebCore {
namespace CSSCalc {

// The C++ simplifier: the per-operation `simplify` overloads and the recursive
// `copyAndSimplify(const Child&)`. See `CSS_CALC_CPP_SIMPLIFIER_COMPILED_IN` for what stays compiled
// without it.
#if CSS_CALC_CPP_SIMPLIFIER_COMPILED_IN
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

template<typename... F> static decltype(auto) switchTogether(const Child& a, const Child& b, F&&... f)
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

template<typename Op, typename Completion> static std::optional<Child> simplifyForOperationWithCompletion(Child& a, Child& b, const SimplificationOptions& options, Completion&& completion)
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
    // 1. Let `specified sum` be the sum of the percentages specified in items (clamped to 100%), or 0% if the percentages are omitted for all items.
    // 2. For each omitted percentage in items, set it to (100% - specified sum) / (number of omitted percentages).
    // 3. Let `total` be the sum of the percentages of all the items
    // 4. If `total` is greater than 100%, or if total is greater than 0% and the force normalization flag is true, multiply every percentage in items by (100% / total).
    // 5. If total is less than 100%, let leftover be (100% - total). Otherwise, let leftover be 0%.
    // NOTE: Per spec, "Any “leftover” mix percentage is applied to a consistently-typed zero value, and thus effectively discarded".

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
    double total = 0;
    unsigned numberOfOmittedWeights = 0;
    unsigned numberOfKnownZeroWeights = 0;

    for (auto& item : root.children) {
        if (item.weight) {
            WTF::switchOn(*item.weight,
                [&](const CalcMix::Item::Weight::Raw& raw) {
                    if (!raw.value)
                        ++numberOfKnownZeroWeights;

                    // Build a running sum of all the percentage values for use in normalization.
                    total += raw.value;
                },
                [&](const CalcMix::Item::Weight::Calc&) {
                    canNormalize = false;
                }
            );
        } else
            ++numberOfOmittedWeights;
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

    if (total >= 100) {
        // If the total of the specific weights is >= 100, all items with omitted weights will
        // be given a weight of 0 and can be removed.
        //
        // Also take this opportunity to remove items with specified weights of 0.
        //
        // Also apply the normalization factor to any remaining weights.

        auto normalizationFactor = 100.0 / total;

        if (numberOfOmittedWeights > 0 || numberOfKnownZeroWeights > 0) {
            auto newNumberOfChildren = root.children.size() - (numberOfOmittedWeights + numberOfKnownZeroWeights);

            Vector<CalcMix::Item> newChildren;
            newChildren.reserveInitialCapacity(newNumberOfChildren);
            for (auto& item : root.children) {
                // Skip omitted weights and any known zero weights.
                if (!item.weight || item.weight->isKnownZero())
                    continue;

                // Update weight using normalization factor.
                item.weight = CalcMix::Item::Weight { item.weight->raw()->value * normalizationFactor };

                newChildren.append(WTF::move(item));
            }
            root.children = WTF::move(newChildren);
        } else {
            for (auto& item : root.children) {
                // Update weight using normalization factor.
                item.weight = CalcMix::Item::Weight { item.weight->raw()->value * normalizationFactor };
            }
        }
    } else {
        if (numberOfKnownZeroWeights > 0) {
            if (numberOfOmittedWeights > 0) {
                auto newNumberOfChildren = root.children.size() - numberOfKnownZeroWeights;

                Vector<CalcMix::Item> newChildren;
                newChildren.reserveInitialCapacity(newNumberOfChildren);

                auto weightForOmitted = (100.0 - total) / static_cast<double>(numberOfOmittedWeights);

                for (auto& item : root.children) {
                    if (item.weight) {
                        // Skip any known zero weights.
                        if (item.weight->isKnownZero())
                            continue;
                    } else
                        item.weight = CalcMix::Item::Weight { weightForOmitted };

                    newChildren.append(WTF::move(item));
                }
                root.children = WTF::move(newChildren);
            } else {
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
        } else if (numberOfOmittedWeights > 0) {
            auto weightForOmitted = (100.0 - total) / static_cast<double>(numberOfOmittedWeights);

            for (auto& item : root.children) {
                if (!item.weight)
                    item.weight = CalcMix::Item::Weight { weightForOmitted };
            }
        }
    }

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
#endif // CSS_CALC_CPP_SIMPLIFIER_COMPILED_IN

// What an `anchor()` evaluates to, or nothing. Shared by `simplify(Anchor&)` and
// `resolveStyleCoupledValue`.
//
// `.range` is `CSS::All`, not `options.range`: an anchor is evaluated unclamped.
static std::optional<double> evaluateAnchorFunction(const Anchor& anchor, const SimplificationOptions& options)
{
    return evaluateWithoutFallback(anchor, EvaluationOptions {
        .category = options.category,
        .range = CSS::All,
        .conversionData = options.conversionData,
        .symbolTable = options.symbolTable
    });
}

// What an `anchor-size()` evaluates to, or nothing. Shared by `simplify(AnchorSize&)` and
// `resolveStyleCoupledValue`.
static std::optional<double> evaluateAnchorSizeFunction(const AnchorSize& anchorSize, Style::BuilderState& builderState)
{
    std::optional<Style::ScopedName> anchorSizeScopedName;
    if (anchorSize.elementName) {
        anchorSizeScopedName = Style::ScopedName {
            .name = Style::toStyle(*anchorSize.elementName, builderState).value,
            .scopeOrdinal = builderState.styleScopeOrdinal()
        };
    }
    return Style::AnchorPositionEvaluator::evaluateSize(builderState, anchorSizeScopedName, anchorSize.dimension);
}

#if CSS_CALC_CPP_SIMPLIFIER_COMPILED_IN
// MARK: - The `calc()` prefix an anchor slot carries
//
// `anchor()` and `anchor-size()` are not math functions, so a `calc()` written inside one keeps its
// prefix in serialization. `consumeValueWithoutSimplifyingRootCalc` records it as a one-child `Sum`
// in the slot, which css-values-4 8.3's one-term collapse (`simplify(Sum&)`) removes: a whole-tree
// `copyAndSimplify` would turn `anchor(--a top, calc(1em * 2))` into `anchor(--a top, 2em)`.
// `rebuildChildren` restores the wrapper, and the two substitution sites below drop it again once
// the `anchor()` itself is gone.
//
// The slot as it came out of the pass, with the wrapper restored if the pass flattened a math
// function into a leaf. `before` is the input slot, `after` the mapped one.
static std::optional<Child> anchorSlotKeepingPrefix(const std::optional<Child>& before, std::optional<Child>&& after)
{
    if (!before || !after || isLeaf(*before) || !isLeaf(*after))
        return WTF::move(after);
    auto type = getType(*after);
    return makeChild(Sum { Vector<Child>::from(WTF::move(*after)) }, type);
}

// The slot on its way out of the anchor node it takes the place of, with the wrapper removed. Left
// in place, it would make the pass non-idempotent.
static std::optional<Child> anchorSlotLeavingTheNode(std::optional<Child>&& slot)
{
    auto* sum = slot ? get_if<IndirectNode<Sum>>(&*slot) : nullptr;
    if (sum && (*sum)->children.size() == 1)
        return WTF::move((*sum)->children[0]);
    return WTF::move(slot);
}

std::optional<Child> simplify(Anchor& anchor, const SimplificationOptions& options)
{
    if (!options.conversionData || !options.conversionData->styleBuilderState())
        return { };

    auto result = evaluateAnchorFunction(anchor, options);
    if (!result) {
        // https://drafts.csswg.org/css-anchor-position-1/#anchor-valid
        // "If any of these conditions are false, the anchor() function resolves to its specified fallback value.
        // If no fallback value is specified, it makes the declaration referencing it invalid at computed-value time."

        if (!anchor.fallback)
            options.conversionData->styleBuilderState()->setCurrentPropertyInvalidAtComputedValueTime();

        // Replace the anchor node with the fallback node.
        return anchorSlotLeavingTheNode(std::exchange(anchor.fallback, { }));
    }
    return CanonicalDimension { .value = *result, .dimension = CanonicalDimension::Dimension::Length };
}

std::optional<Child> simplify(AnchorSize& anchorSize, const SimplificationOptions& options)
{
    if (!options.conversionData || !options.conversionData->styleBuilderState())
        return { };

    CheckedPtr builderState = options.conversionData->styleBuilderState();

    auto result = evaluateAnchorSizeFunction(anchorSize, *builderState);

    if (!result) {
        if (!anchorSize.fallback)
            options.conversionData->styleBuilderState()->setCurrentPropertyInvalidAtComputedValueTime();

        return anchorSlotLeavingTheNode(std::exchange(anchorSize.fallback, { }));
    }

    return CanonicalDimension { .value = *result, .dimension = CanonicalDimension::Dimension::Length };
}

// MARK: Copy & Simplify.

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

// One walk over an operation's tuple slots, parameterised by what each slot becomes.
// FIXME: webkit.org/b/280798, make Anchor and AnchorSize tuple-like, and remove their two branches.
//
// An anchor's `side` is copied, not simplified, so `anchor(--a calc(25% + 25%))` does not fold to
// `anchor(--a 50%)`. Its `fallback` is simplified, so its prefix has to be restored.
//
// `NOESCAPE` holds: `mapSlot` is only ever called here, never stored or captured.
template<typename Op, typename MapSlot> static Op rebuildChildren(const IndirectNode<Op>& root, NOESCAPE MapSlot&& mapSlot)
{
    // `Random::Sharing` is the one tuple slot that is not a subtree.
    //
    // It is named rather than tested with `requires { mapSlot(slot); }`, which would silently pass
    // through a slot shape a mapper does not handle.
    //
    // Without `ALWAYS_INLINE_LAMBDA`, `copyAndSimplify(const Children&)` gets `WTF::map` outlined,
    // adding a call per node.
    auto mapChildSlot = [&](const auto& slot) ALWAYS_INLINE_LAMBDA {
        if constexpr (std::same_as<std::decay_t<decltype(slot)>, Random::Sharing>)
            return slot;
        else
            return mapSlot(slot);
    };

    if constexpr (std::same_as<Op, Anchor>)
        return Anchor { .elementName = root->elementName, .side = copy(root->side), .fallback = anchorSlotKeepingPrefix(root->fallback, mapSlot(root->fallback)) };
    else if constexpr (std::same_as<Op, AnchorSize>)
        return AnchorSize { .elementName = root->elementName, .dimension = root->dimension, .fallback = anchorSlotKeepingPrefix(root->fallback, mapSlot(root->fallback)) };
    else
        return WTF::apply([&](const auto& ...x) { return Op { mapChildSlot(x)... }; }, *root);
}

template<typename Op> static auto copyAndSimplifyChildren(const IndirectNode<Op>& root, const SimplificationOptions& options) -> Op
{
    return rebuildChildren(root, [&](const auto& slot) { return copyAndSimplify(slot, options); });
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
// The storage a `Tree` holds its Swift root in, the upcalls Swift's folds and walks make, and the
// construction of a `Child` from a stored tree for the C++ that reads one. Swift emits that tree
// post-order and the builder below constructs the `Child`s on a C++-owned operand stack.

// One `calc-mix()` item's weight, pushed before the `CalcMix` is built.
struct CalcMixWeightPlan {
    // The weight, as a `<percentage>` in [0,100], when `present` is set and `real` is absent.
    double weight;
    bool present;
    // A `Calc` weight from the payload table, which a `double` cannot express. Takes precedence over
    // the fields above.
    std::optional<CalcMix::Item::Weight> real;
};

// The operand stack the Swift emit pushes onto, forward-declared in CSSCalcSwiftTypes.h.
//
// 16 rather than 8 inline: the peak is the widest operand run the emit holds at once, and at 8 a
// twelve-term sum moves to the heap.
using OperandVector = Vector<Child, 16>;

struct CSSCalcSwiftOperandStack {
    OperandVector value { };
    // The weights the next `calc-mix()` construction pairs with its items, in item order. A stack,
    // so that a nested `calc-mix()` consumes only its own.
    Vector<CalcMixWeightPlan> calcMixWeights { };
    // Where the finished root is constructed instead of on the stack: the `Child` that
    // `materializedRoot` returns.
    //
    // Null means the root goes on the stack.
    //
    // Also the completion flag: `constructOperand` nulls it, so a non-null slot afterwards means no
    // root was built. A second root construction goes on the stack, which then fails the same check.
    Child* rootSlot { nullptr };

    // The payload table a node names by index in its `origin`.
    //
    // Null when the tree has none.
    const CSSCalcSwiftFlatPayloads* flatPayloads { nullptr };
};

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
    if (!m_operands->flatPayloads || index >= m_operands->flatPayloads->size())
        return nullptr;
    return get_if<T>(&(*m_operands->flatPayloads)[index]);
}

// Constructs a finished node in place: into the root slot when this is the root and one was
// provided, onto the operand stack otherwise.
//
// The root slot holds a live placeholder `Child` holding a `Number` (see `materializedRoot`), whose
// destructor is not run: [basic.life]/5 allows reusing its storage because nothing depends on that
// destructor.
template<typename... Args>
static ALWAYS_INLINE void constructOperand(CSSCalcSwiftOperandStack& operands, bool isRoot, Args&&... args)
{
    static_assert(std::is_trivially_destructible_v<Number>, "the root placeholder's storage is reused without a destructor call, which [basic.life]/5 allows only because nothing depends on the destructor");
    if (Child* slot = isRoot ? std::exchange(operands.rootSlot, nullptr) : nullptr)
        new (NotNull, slot) Child(std::forward<Args>(args)...);
    else
        operands.value.constructAndAppend(std::forward<Args>(args)...);
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
    CSSCalcSwiftOperandStack operands { .flatPayloads = &payloads };
    CSSCalcSwiftBuilder builder { operands, request.options };
    auto cursor = CSSCalcSwiftParseCursor { request.tokens, request.symbols, &request.propertyParserState, &payloads };
    new (m_root) CSSCalcSwiftRoot(cssCalcParseSwift(cursor, builder, request.parseOptions, swiftSimplificationOptions(request.options), true, request.result));
    if (request.result.outcome == static_cast<uint8_t>(CSSCalcSwiftParseOutcome::Parsed) && !payloads.isEmpty())
        m_payloads = adoptRef(*new CSSCalcSwiftFlatPayloadsBox(WTF::move(payloads)));
}

bool CSSCalcSwiftBuilder::pushLeaf(CSSCalcSwiftLeaf leaf, bool isRoot) noexcept
{
    // Constructed in place from the named alternative, which selects the variant member at compile
    // time; appending a finished `Child` would cost an out-of-line 41-alternative move.
    switch (static_cast<CSSCalcSwiftAlternative>(leaf.alternative)) {
    case CSSCalcSwiftAlternative::Percentage:
        // Not `makeNumeric`, which builds a `Percentage` with no hint: a folded percentage keeps its
        // operand's hint, as in `makeChildWithValueBasedOn`.
        constructOperand(*m_operands, isRoot, Percentage {
            .value = leaf.value,
            .hint = leaf.percentHint ? Type::PercentHintValue { static_cast<PercentHint>(leaf.percentHint) } : Type::PercentHintValue { }
        });
        return true;

    case CSSCalcSwiftAlternative::NonCanonicalDimension:
        // Not `makeNumeric`, which would canonicalize some of these units; a
        // `NonCanonicalDimension` that `simplify(NonCanonicalDimension&)` leaves alone stays one.
        constructOperand(*m_operands, isRoot, NonCanonicalDimension { .value = leaf.value, .unit = static_cast<CSSUnitType>(leaf.unitType) });
        return true;

    case CSSCalcSwiftAlternative::Number:
        // `makeNumeric` builds `Number` for exactly these two units.
        //
        // A `Number` alternative with any other unit is a contract violation.
        if (auto unit = static_cast<CSSUnitType>(leaf.unitType); unit != CSSUnitType::Number && unit != CSSUnitType::Integer)
            return false;
        constructOperand(*m_operands, isRoot, Number { .value = leaf.value });
        return true;

    case CSSCalcSwiftAlternative::CanonicalDimension:
        // `makeNumeric` picks the `CanonicalDimension::Dimension`, so the canonical-unit table is not
        // duplicated.
        //
        // This is the one case that pays the extra `Child` move.
        constructOperand(*m_operands, isRoot, makeNumeric(leaf.value, static_cast<CSSUnitType>(leaf.unitType)));
        return true;

    case CSSCalcSwiftAlternative::Symbol:
        // `parseCalcKeyword`'s `Symbol { token.id(), *unit }`. `CSSValueInvalid` is refused: it
        // would resolve to nothing at computed-value time instead of failing the parse.
        if (static_cast<CSSValueID>(leaf.valueID) == CSSValueInvalid)
            return false;
        constructOperand(*m_operands, isRoot, Symbol { static_cast<CSSValueID>(leaf.valueID), static_cast<CSSUnitType>(leaf.unitType) });
        return true;

    case CSSCalcSwiftAlternative::SiblingCount:
        // The tree-counting functions are leaves, empty structs whose type is `Type { }`.
        constructOperand(*m_operands, isRoot, SiblingCount { });
        return true;

    case CSSCalcSwiftAlternative::SiblingIndex:
        constructOperand(*m_operands, isRoot, SiblingIndex { });
        return true;

    default:
        // A contract violation.
        return false;
    }
}

bool CSSCalcSwiftBuilder::pushCalcMixItemWeight(double weight, bool present, uint32_t payloadIndex) noexcept
{
    if (payloadIndex == cssCalcSwiftFlatNoNode) {
        m_operands->calcMixWeights.append(CalcMixWeightPlan { .weight = weight, .present = present, .real = std::nullopt });
        return true;
    }
    // A `Calc` weight that `CSSCalcSwiftParseCursor::consumeCalcMixWeightAt` resolved.
    auto* real = payloadFor<CalcMix::Item::Weight>(payloadIndex);
    if (!real)
        return false;
    m_operands->calcMixWeights.append(CalcMixWeightPlan { .weight = 0, .present = true, .real = *real });
    return true;
}

// Whether `Op` declares a slot count at all, which the operations do and the leaves do not.
template<typename Op> concept OperationWithSlots = requires { std::tuple_size<Op>::value; };

// Whether `Op` has at least one slot and every slot is a plain `Child`, so that N slots take N
// operands in order.
template<OperationWithSlots Op> static constexpr bool slotsAreAllChild = []<size_t... I>(std::index_sequence<I...>) {
    return sizeof...(I) > 0 && (std::is_same_v<std::remove_cvref_t<std::tuple_element_t<I, Op>>, Child> && ...);
}(std::make_index_sequence<std::tuple_size_v<Op>> { });

bool CSSCalcSwiftBuilder::buildOperation(CSSCalcSwiftAlternative alternative, uint32_t childCount, Type carriedType, bool isRoot, uint8_t noneMask) noexcept
{
    auto& stack = m_operands->value;
    if (!childCount || childCount > stack.size())
        return false;

    size_t base = stack.size() - childCount;

    auto finish = [&](auto&& op) -> bool {
        stack.shrink(base);
        // Constructed in place, as in `pushLeaf`.
        //
        // No `toType`: `clamp()` rewritten to `min()`/`max()` computes its type in
        // `CalcFold.convertToMinMax` and carries it like every other node.
        constructOperand(*m_operands, isRoot, makeIndirectNode(WTF::move(op), carriedType));
        return true;
    };

    // The `Children`-slotted operations, which take every operand.
    auto takeChildren = [&] {
        Vector<Child> children;
        children.reserveInitialCapacity(childCount);
        for (size_t i = base; i < stack.size(); ++i)
            children.append(WTF::move(stack[i]));
        return children;
    };

    // The operations whose slots are filled from the operand stack alone, placed by the slot shape
    // `Op` declares.
    //
    // No Swift type can hold a `Child`, so this construction is in C++.
    //
    // Two shapes are served, and any other is refused:
    //
    //  - N plain `Child` slots take exactly N operands. Braced-init evaluates left to right, so
    //    slot order is operand order.
    //  - `Child, std::optional<Child>` (`round()` and `log()`) takes one or two operands; the
    //    second slot is present exactly when there are two.
    //
    // The arity is checked before any slot is taken; getting it wrong reads past the stack.
    auto finishFromSlotShape = [&]<typename Op>() -> bool {
        if constexpr (OperationWithSlots<Op>) {
            if constexpr (slotsAreAllChild<Op>) {
                if (childCount != std::tuple_size_v<Op>)
                    return false;
                return [&]<size_t... I>(std::index_sequence<I...>) {
                    return finish(Op { WTF::move(stack[base + I])... });
                }(std::make_index_sequence<std::tuple_size_v<Op>> { });
            } else if constexpr (std::tuple_size_v<Op> == 2) {
                if constexpr (std::is_same_v<std::remove_cvref_t<std::tuple_element_t<0, Op>>, Child>
                    && std::is_same_v<std::remove_cvref_t<std::tuple_element_t<1, Op>>, std::optional<Child>>) {
                    if (childCount > 2)
                        return false;
                    return finish(Op { WTF::move(stack[base]),
                        childCount == 2 ? std::optional<Child> { WTF::move(stack[base + 1]) } : std::optional<Child> { } });
                }
            }
        }
        return false;
    };

    switch (alternative) {
    case CSSCalcSwiftAlternative::Sum:
        return finish(Sum { .children = takeChildren() });
    case CSSCalcSwiftAlternative::Product:
        return finish(Product { .children = takeChildren() });
    case CSSCalcSwiftAlternative::Min:
        return finish(Min { .children = takeChildren() });
    case CSSCalcSwiftAlternative::Max:
        return finish(Max { .children = takeChildren() });
    case CSSCalcSwiftAlternative::Hypot:
        return finish(Hypot { .children = takeChildren() });

    // `clamp()`, whose slots cannot be filled from the operand stack alone.
    //
    // A `none` bound is not pushed, so `noneMask` says which bounds are `none`.
    //
    // `childCount + popcount(noneMask)` must be 3, checked before any slot is taken.
    case CSSCalcSwiftAlternative::Clamp: {
        if (childCount + (noneMask & 1) + ((noneMask >> 1) & 1) != 3)
            return false;
        size_t next = base;
        auto bound = [&](uint8_t bit) -> ChildOrNone {
            return (noneMask & bit) ? ChildOrNone { CSS::Keyword::None { } } : ChildOrNone { WTF::move(stack[next++]) };
        };
        auto minimum = bound(1);
        auto value = WTF::move(stack[next++]);
        return finish(Clamp { WTF::move(minimum), WTF::move(value), bound(2) });
    }

    // `calc-mix()`, whose weights are not operands.
    //
    // Each item's value is an operand; its weight comes off the `pushCalcMixItemWeight` stack. The
    // top `childCount` weights are this node's: a nested `calc-mix()` consumed its own first.
    case CSSCalcSwiftAlternative::CalcMix: {
        auto& weights = m_operands->calcMixWeights;
        if (weights.size() < childCount)
            return false;
        size_t weightBase = weights.size() - childCount;
        Vector<CalcMix::Item> items(childCount, [&](size_t item) {
            auto& plan = weights[weightBase + item];
            // As `simplify(CalcMix&)` constructs a weight.
            return CalcMix::Item { .value = WTF::move(stack[base + item]), .weight = plan.real ? plan.real : (plan.present ? std::optional<CalcMix::Item::Weight> { CalcMix::Item::Weight { plan.weight } } : std::nullopt) };
        });
        weights.shrink(weightBase);
        return finish(CalcMix { WTF::move(items) });
    }

    default:
        // Served by its slot shape. A leaf, or an operation with its own entry point, is a
        // contract violation, and the stack is left as it was.
#define CSS_CALC_SWIFT_BUILD_FROM_SLOT_SHAPE(name, type) \
        case CSSCalcSwiftAlternative::name: \
            return finishFromSlotShape.operator()<name>();
        switch (alternative) {
        CSS_CALC_SWIFT_FOR_EACH_ALTERNATIVE(CSS_CALC_SWIFT_BUILD_FROM_SLOT_SHAPE)
        }
#undef CSS_CALC_SWIFT_BUILD_FROM_SLOT_SHAPE
        return false;
    }
}

// `anchor()` and `anchor-size()`: the third and fourth alternatives whose slots are not fillable
// from the operand stack alone, and the only two whose missing piece is a `CSS::CustomIdent`.
//
// The ident was resolved by `CSSCalcSwiftParseCursor::resolveDashedIdentAt`, through
// `consumeUnresolvedDashedIdent`'s own spelling over the same one token, and is named here by its
// payload index. Nothing is re-read at emit, so the tokens need not be alive.
//
// The slot layout is derived rather than sent, which is why this takes no flags argument: the
// `<anchor-side>` subtree first, and only when the side is a `<percentage>` rather than a keyword,
// then the fallback. `valueID == CSSValueInvalid` on an `Anchor` means the side is the
// subtree, because `Anchor::side` is not optional; on an `AnchorSize` it means `dimension` is
// absent. So the side occupies a slot only for an `Anchor` with no keyword, and the fallback is
// whatever slot remains.
bool CSSCalcSwiftBuilder::buildAnchor(CSSCalcSwiftAlternative alternative, uint32_t childCount, Type carriedType, bool isRoot, uint16_t valueID, uint32_t elementNamePayload) noexcept
{
    auto& stack = m_operands->value;
    uint32_t sideSlots = alternative == CSSCalcSwiftAlternative::Anchor && !valueID ? 1 : 0;
    if (childCount > stack.size() || childCount < sideSlots || childCount > sideSlots + 1)
        return false;

    std::optional<CSS::CustomIdent> elementName;
    if (elementNamePayload != cssCalcSwiftFlatNoNode) {
        auto* resolved = payloadFor<CSS::CustomIdent>(elementNamePayload);
        if (!resolved)
            return false;
        elementName = *resolved;
    }

    // Both slots are taken before either node is built, so the two branches below are one `shrink`
    // and one construction rather than two of each. `side` is built unconditionally and an
    // `AnchorSize` discards it: `sideSlots` is zero there, so the ternary takes the `CSSValueID`
    // branch and the discarded value is a variant holding an enumerator.
    size_t base = stack.size() - childCount;
    auto fallback = childCount > sideSlots ? std::optional<Child> { WTF::move(stack[base + sideSlots]) } : std::nullopt;
    AnchorSide side = sideSlots ? AnchorSide { WTF::move(stack[base]) } : AnchorSide { static_cast<CSSValueID>(valueID) };
    stack.shrink(base);
    if (alternative == CSSCalcSwiftAlternative::Anchor)
        constructOperand(*m_operands, isRoot, makeIndirectNode(Anchor { .elementName = WTF::move(elementName), .side = WTF::move(side), .fallback = WTF::move(fallback) }, carriedType));
    else
        // `cssValueIDToAnchorSizeDimension` is `consumeAnchorSize`'s own table, shared rather than
        // copied, so an `<anchor-size>` keyword maps identically however the tree was built.
        constructOperand(*m_operands, isRoot, makeIndirectNode(AnchorSize { .elementName = WTF::move(elementName), .dimension = valueID ? cssValueIDToAnchorSizeDimension(static_cast<CSSValueID>(valueID)) : std::nullopt, .fallback = WTF::move(fallback) }, carriedType));
    return true;
}

// `random()`, whose `Random::Sharing` comes from the payload table.
//
// `CSSCalcSwiftParseCursor::consumeRandomKey` resolved it during the parse, with the
// `cssRandomFunctionCount` of this function's own position, so no count is read here.
bool CSSCalcSwiftBuilder::buildRandom(uint32_t childCount, Type carriedType, bool isRoot, uint32_t sharingPayload) noexcept
{
    auto& stack = m_operands->value;
    // `<random()> = random( <random-key>? , <calc-sum>, <calc-sum>, <calc-sum>? )`
    if (childCount < 2 || childCount > 3 || childCount > stack.size())
        return false;

    auto* sharing = payloadFor<Random::Sharing>(sharingPayload);
    if (!sharing)
        return false;

    size_t base = stack.size() - childCount;
    auto minimum = WTF::move(stack[base]);
    auto maximum = WTF::move(stack[base + 1]);
    auto step = childCount > 2 ? std::optional<Child> { WTF::move(stack[base + 2]) } : std::nullopt;
    stack.shrink(base);
    constructOperand(*m_operands, isRoot, makeIndirectNode(Random { .sharing = *sharing, .min = WTF::move(minimum), .max = WTF::move(maximum), .step = WTF::move(step) }, carriedType));
    return true;
}

static constexpr CSSCalcSwiftNumericResult unresolvedNumber { .value = 0, .unitType = static_cast<uint16_t>(CSSUnitType::Unknown), .resolved = false, .alternative = CSSCalcSwiftAlternative::Number, .substituteFallback = false };

static constexpr CSSCalcSwiftNumericResult resolvedNumber(double value)
{
    return { .value = value, .unitType = static_cast<uint16_t>(CSSUnitType::Number), .resolved = true, .alternative = CSSCalcSwiftAlternative::Number, .substituteFallback = false };
}

// A resolved canonical `<length>`, as `simplify(Anchor&)` and `simplify(AnchorSize&)` produce.
//
// The unit is `toCSSUnit(Dimension::Length)`, so that `pushLeaf`'s `makeNumeric` builds the same
// alternative.
static constexpr CSSCalcSwiftNumericResult resolvedCanonicalLength(double value)
{
    return { .value = value, .unitType = static_cast<uint16_t>(toCSSUnit(CanonicalDimension::Dimension::Length)), .resolved = true, .alternative = CSSCalcSwiftAlternative::CanonicalDimension, .substituteFallback = false };
}

// See `CSSCalcSwiftNumericResult::substituteFallback`.
static constexpr CSSCalcSwiftNumericResult substituteAnchorFallback { .value = 0, .unitType = static_cast<uint16_t>(CSSUnitType::Unknown), .resolved = false, .alternative = CSSCalcSwiftAlternative::Number, .substituteFallback = true };

CSSCalcSwiftNumericResult CSSCalcSwiftBuilder::resolveStyleCoupledValue(const Child& node) const noexcept
{
    // The guard `simplify(SiblingCount&)`, `simplify(SiblingIndex&)` and `simplify(Random&)` open
    // with. It comes before the `fixed` branch, so `random(fixed 0.5, 1px, 3px)` does not fold
    // without a builder state.
    if (!m_options->conversionData || !m_options->conversionData->styleBuilderState())
        return unresolvedNumber;

    CheckedPtr builderState = protect(m_options->conversionData->styleBuilderState());

    // `get_if` rather than `switchOn`, which would instantiate all 41 alternatives. Any other
    // alternative answers `unresolvedNumber`.
    if (auto* random = get_if<IndirectNode<Random>>(&node)) {
        // A `fixed` `Calc` needs full evaluation, which simplification does not do, so it does not
        // go through `resolveRandomBaseValue`.
        if (auto* sharingFixed = std::get_if<Random::SharingFixed>(&(*random)->sharing)) {
            return WTF::switchOn(sharingFixed->value,
                [](const CSS::Number<CSS::ClosedUnitRange>::Raw& raw) { return resolvedNumber(raw.value); },
                [](const CSS::Number<CSS::ClosedUnitRange>::Calc&) { return unresolvedNumber; }
            );
        }
        // The same resolver `evaluate(const IndirectNode<Random>&)` calls.
        if (auto randomBaseValue = resolveRandomBaseValue((*random)->sharing, *builderState))
            return resolvedNumber(*randomBaseValue);
        return unresolvedNumber;
    }

    auto anchorEvaluationFailed = [&](bool hasFallback) {
        // https://drafts.csswg.org/css-anchor-position-1/#anchor-valid
        // "If any of these conditions are false, the anchor() function resolves to its specified
        // fallback value. If no fallback value is specified, it makes the declaration referencing it
        // invalid at computed-value time."
        //
        // Unlike `simplify(Anchor&)`, this does not move the fallback out of the node: Swift
        // substitutes the fallback subtree it has already simplified.
        if (!hasFallback)
            builderState->setCurrentPropertyInvalidAtComputedValueTime();
        return substituteAnchorFallback;
    };

    // The evaluation `simplify(Anchor&)` and `simplify(AnchorSize&)` use, answered as a value.
    //
    // Above the element guard: `AnchorPositionEvaluator::evaluate` does not need one.
    if (auto* anchor = get_if<IndirectNode<Anchor>>(&node)) {
        if (auto result = evaluateAnchorFunction(**anchor, *m_options))
            return resolvedCanonicalLength(*result);
        return anchorEvaluationFailed(static_cast<bool>((*anchor)->fallback));
    }

    if (auto* anchorSize = get_if<IndirectNode<AnchorSize>>(&node)) {
        if (auto result = evaluateAnchorSizeFunction(**anchorSize, *builderState))
            return resolvedCanonicalLength(*result);
        return anchorEvaluationFailed(static_cast<bool>((*anchorSize)->fallback));
    }

    // `simplify(SiblingCount&)` and `simplify(SiblingIndex&)` require an element and otherwise leave
    // the function in the tree. `simplify(Random&)` does not, so it is handled above.
    if (!builderState->element())
        return unresolvedNumber;

    if (WTF::holdsAlternative<SiblingCount>(node))
        return resolvedNumber(static_cast<double>(builderState->siblingCount()));
    if (WTF::holdsAlternative<SiblingIndex>(node))
        return resolvedNumber(static_cast<double>(builderState->siblingIndex()));
    return unresolvedNumber;
}

CSSCalcSwiftNumericResult CSSCalcSwiftBuilder::resolveStyleCoupledValueOfTop() noexcept
{
    auto& stack = m_operands->value;
    if (stack.isEmpty())
        return unresolvedNumber;
    auto result = resolveStyleCoupledValue(stack.last());
    stack.removeLast();
    return result;
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

CSSCalcSwiftNumericResult CSSCalcSwiftBuilder::resolveRandomBaseValueForEvaluation(uint32_t payload) const noexcept
{
    auto* sharing = payloadFor<Random::Sharing>(payload);
    if (!sharing || !hasStyleBuilderState())
        return unresolvedNumber;
    CheckedPtr builderState = m_options->conversionData->styleBuilderState();
    if (auto base = resolveRandomBaseValue(*sharing, *builderState))
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

CSSCalcSwiftNumericResult CSSCalcSwiftBuilder::resolveSymbol(uint16_t valueID, uint16_t unit) const noexcept
{
    // The lookup `simplify(Symbol&)` makes.
    auto value = m_options->symbolTable.get(static_cast<CSSValueID>(valueID));
    if (!value) {
        // A miss leaves the `Symbol` unchanged. Not a failure.
        return unresolvedNumber;
    }

    // The value from the table and the unit from the node, as `simplify(Symbol&)` does; the table's
    // own unit is not read.
    auto leaf = makeNumeric(value->value, static_cast<CSSUnitType>(unit));

    // Read back off the node `makeNumeric` built, so its unit classification is not duplicated.
    // The numeric alternatives are inline, so this does not allocate.
    CSSCalcSwiftNumericResult out {
        .value = 0,
        .unitType = static_cast<uint16_t>(CSSUnitType::Unknown),
        .resolved = true,
        .alternative = static_cast<CSSCalcSwiftAlternative>(leaf.value.index()),
        .substituteFallback = false,
    };
    WTF::switchOn(leaf,
        [&]<Numeric T>(const T& numeric) {
            out.value = numeric.value;
            out.unitType = static_cast<uint16_t>(toCSSUnit(numeric));
        },
        // Unreachable: `makeNumeric` always returns a numeric leaf.
        [&](const auto&) { }
    );
    return out;
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
// The `<anchor-size>` dimension as the `CSSValueID` a stored `anchor-size()` carries, the inverse of
// `cssValueIDToAnchorSizeDimension`.
static CSSValueID anchorSizeDimensionValueID(Style::AnchorSizeDimension dimension)
{
    static constexpr std::array ids { CSSValueWidth, CSSValueHeight, CSSValueBlock, CSSValueInline, CSSValueSelfBlock, CSSValueSelfInline };
    auto id = ids[static_cast<size_t>(dimension)];
    ASSERT(cssValueIDToAnchorSizeDimension(id) == dimension);
    return id;
}

template<typename Payload> static uint32_t storePayload(CSSCalcSwiftFlatPayloads& payloads, const Payload& payload)
{
    payloads.append(payload);
    return static_cast<uint32_t>(payloads.size() - 1);
}

// Push `node` onto `builder`, children first, with its payloads copied into `payloads`.
static bool storeNode(CSSCalcSwiftStoreBuilder& builder, CSSCalcSwiftFlatPayloads& payloads, const Child& node)
{
    auto alternative = static_cast<CSSCalcSwiftAlternative>(node.value.index());
    auto leaf = [&](double value, CSSUnitType unit, uint8_t percentHint = 0, CSSValueID valueID = CSSValueInvalid) {
        builder.pushLeaf(alternative, value, static_cast<uint8_t>(unit), percentHint, static_cast<uint16_t>(valueID));
        return true;
    };
    auto operation = [&](const auto& op, uint32_t count, uint8_t noneMask = 0, CSSValueID valueID = CSSValueInvalid, uint32_t origin = cssCalcSwiftFlatNoNode) {
        return builder.pushOperation(alternative, count, op.type, noneMask, static_cast<uint16_t>(valueID), origin);
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
    auto elementName = [&](const std::optional<CSS::CustomIdent>& name) {
        return name ? storePayload(payloads, *name) : cssCalcSwiftFlatNoNode;
    };
    return WTF::switchOn(node,
        [&](const Number& number) { return leaf(number.value, CSSUnitType::Number); },
        [&](const Percentage& percentage) { return leaf(percentage.value, CSSUnitType::Percentage, percentage.hint ? static_cast<uint8_t>(*percentage.hint) : 0); },
        [&](const CanonicalDimension& dimension) { return leaf(dimension.value, toCSSUnit(dimension)); },
        [&](const NonCanonicalDimension& dimension) { return leaf(dimension.value, dimension.unit); },
        [&](const Symbol& symbol) { return leaf(0, symbol.unit, 0, symbol.id); },
        [&](const SiblingCount&) { return leaf(0, CSSUnitType::Unknown); },
        [&](const SiblingIndex&) { return leaf(0, CSSUnitType::Unknown); },
        [&](const IndirectNode<CalcMix>& calcMix) {
            for (auto& item : calcMix->children) {
                if (!storeNode(builder, payloads, item.value))
                    return false;
                auto raw = item.weight ? item.weight->raw() : std::nullopt;
                builder.pushCalcMixWeight(raw ? raw->value : 0, item.weight.has_value(), item.weight && !raw ? storePayload(payloads, *item.weight) : cssCalcSwiftFlatNoNode);
            }
            return operation(calcMix, calcMix->children.size() * 2);
        },
        [&](const IndirectNode<Anchor>& anchor) {
            auto* sideKeyword = get_if<CSSValueID>(&anchor->side.value);
            if (!sideKeyword && !storeNode(builder, payloads, get<Child>(anchor->side.value)))
                return false;
            if (anchor->fallback && !storeNode(builder, payloads, *anchor->fallback))
                return false;
            return operation(anchor, !sideKeyword + anchor->fallback.has_value(), 0, sideKeyword ? *sideKeyword : CSSValueInvalid, elementName(anchor->elementName));
        },
        [&](const IndirectNode<AnchorSize>& anchorSize) {
            if (anchorSize->fallback && !storeNode(builder, payloads, *anchorSize->fallback))
                return false;
            return operation(anchorSize, anchorSize->fallback.has_value(), 0, anchorSize->dimension ? anchorSizeDimensionValueID(*anchorSize->dimension) : CSSValueInvalid, elementName(anchorSize->elementName));
        },
        [&](const IndirectNode<Random>& random) {
            auto count = children(random);
            return count && operation(random, *count, 0, CSSValueInvalid, storePayload(payloads, random->sharing));
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

Child materializedRoot(const Tree& tree)
{
    Child root = Number { .value = 0 };
    CSSCalcSwiftOperandStack operands { .rootSlot = &root, .flatPayloads = tree.stored.payloads() };
    SimplificationOptions options { .category = CSS::Category::Number, .range = CSS::All, .conversionData = std::nullopt, .symbolTable = { } };
    CSSCalcSwiftBuilder builder { operands, options };
    RELEASE_ASSERT_WITH_MESSAGE(cssCalcEmitStoredSwift(tree.stored.root(), builder) && !operands.rootSlot && operands.value.isEmpty(), "a stored calc() tree could not be built as a Child");
    return root;
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
    CSSCalcSwiftOperandStack operands { .flatPayloads = tree.stored.payloads() };
    CSSCalcSwiftBuilder builder { operands, options };
    bool simplified = false;
    auto simplifiedRoot = cssCalcSimplifyStoredSwift(tree.stored.root(), builder, swiftSimplificationOptions(options), simplified);
    if (simplified && operands.value.isEmpty()) {
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
// The Swift evaluator on any subtree, not only a whole tree's root, because `evaluateWithoutFallback`
// evaluates an `anchor()`'s `<anchor-side>` on its own.
static CSSCalcSwiftNumericResult cssCalcSwiftEvaluateStored(const CSSCalcSwiftStoredRoot& stored, const EvaluationOptions& options) noexcept
{
    // The builder carries the conversion data Swift reads, as a `SimplificationOptions`. The operand
    // stack holds only a node an upcall is asked about, while it is asked.
    SimplificationOptions simplificationOptions {
        .category = options.category,
        .range = options.range,
        .conversionData = options.conversionData,
        .symbolTable = options.symbolTable,
    };
    CSSCalcSwiftOperandStack operands { .flatPayloads = stored.payloads() };
    CSSCalcSwiftBuilder builder { operands, simplificationOptions };
    return cssCalcEvaluateSwift(stored.root(), builder, simplificationOptions.conversionData.has_value());
}

// Only an `anchor()`'s `<anchor-side>` is evaluated on its own, and only while the anchor is.
static CSSCalcSwiftNumericResult cssCalcSwiftEvaluateChild(const Child& root, const EvaluationOptions& options) noexcept
{
    auto stored = storedFormOf(root);
    RELEASE_ASSERT_WITH_MESSAGE(stored, "a calc() tree built in C++ has no Swift form");
    return cssCalcSwiftEvaluateStored(*stored, options);
}


// With the C++ evaluator compiled in, a tree the Swift evaluator refuses is a `std::nullopt` the
// caller answers with the C++. Without it, a `std::nullopt` would read as "answers nothing" and
// compute as zero, so it stops.
static std::optional<double> answerOf(const CSSCalcSwiftNumericResult& result)
{
    if (result.resolved)
        return result.value;
#if !CSS_CALC_CPP_EVALUATOR_COMPILED_IN
    RELEASE_ASSERT_WITH_MESSAGE(!result.substituteFallback, "the Swift calc() evaluator refused a tree in a build with no C++ evaluator compiled in");
#endif
    return std::nullopt;
}

std::optional<double> evaluateDoubleWithSwift(const Tree& tree, const EvaluationOptions& options)
{
    return answerOf(cssCalcSwiftEvaluateStored(tree.stored, options));
}

std::optional<double> evaluateDoubleWithSwift(const Child& root, const EvaluationOptions& options)
{
    return answerOf(cssCalcSwiftEvaluateChild(root, options));
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
