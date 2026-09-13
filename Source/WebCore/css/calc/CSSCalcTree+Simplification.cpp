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
#include "CSSCalcTree+Copy.h"
#include "CSSCalcTree+Evaluation.h"
#include "CSSCalcTree+Mappings.h"
#include "CSSCalcTree+NumericIdentity.h"
#include "CSSCalcTree+Traversal.h"
#include "CSSCalcTree.h"
#include "CSSPrimitiveNumericCategory.h"
#include "CSSPrimitiveValue.h"
#include "CSSUnevaluatedCalc.h"
#include "StyleBuilderState.h"
#include "StyleComputedStyle+GettersInlines.h"
#include "StyleLengthResolution.h"
// The Swift entry point this file calls, and every other Swift boundary type along with them
// -- WebCoreSwift-Generated.h is module-scoped, so a translation unit that includes it must declare
// all of them. WebCoreSwiftBoundaryTypes.h says why, and is the one file a newly added Swift port edits.
#include "WebCoreSwiftBoundaryTypes.h"
#include <atomic>
#include <bit>
#include <wtf/StdLibExtras.h>

namespace WebCore {
namespace CSSCalc {

static auto copyAndSimplify(const CalcMix::Item&, const SimplificationOptions&) -> CalcMix::Item;
static auto copyAndSimplify(const Vector<CalcMix::Item>&, const SimplificationOptions&) -> Vector<CalcMix::Item>;
static auto copyAndSimplify(const CSS::Keyword::None&, const SimplificationOptions&) -> CSS::Keyword::None;
static auto copyAndSimplify(const Children&, const SimplificationOptions&) -> Children;
static auto copyAndSimplify(const ChildOrNone&, const SimplificationOptions&) -> ChildOrNone;
template<typename T>
static auto copyAndSimplify(const std::optional<T>&, const SimplificationOptions&) -> std::optional<T>;

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
        ASSERT(category);
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

// What an `anchor()` evaluates to, or nothing.
//
// Extracted because it has TWO callers that need the same answer in two different shapes:
// `simplify(Anchor&)` below turns it into a `Child`, and the Swift island's
// `resolveStyleCoupledValue` needs it as a `double` on a POD, because the island keeps folding the
// enclosing expression -- `calc(anchor(top) + 1em)` has to become one length, which it can only do
// if the value comes back to it. The island used to restate this, and a restatement of an
// evaluation is exactly the sort of second definition that drifts.
//
// `.range` is `CSS::All`, not `options.range`: an anchor is evaluated unclamped even inside a
// property with a range.
static std::optional<double> evaluateAnchorFunction(const Anchor& anchor, const SimplificationOptions& options)
{
    return evaluateWithoutFallback(anchor, EvaluationOptions {
        .category = options.category,
        .range = CSS::All,
        .conversionData = options.conversionData,
        .symbolTable = options.symbolTable
    });
}

// What an `anchor-size()` evaluates to, or nothing. Same two callers, same reason.
//
// `dimension` is passed through as the `optional` it is: `evaluateSize` substitutes
// `defaultDimensionForPropertyID(propertyID)` for an absent one
// (AnchorPositionEvaluator.cpp:1023), so a presence bit would not be enough to reconstruct it.
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

// MARK: - The `calc()` prefix an anchor slot carries, and why a whole-tree pass has to restore it.
//
// `anchor()` and `anchor-size()` are NOT math functions, so a `calc()` written inside one is not
// omitted from the serialization the way it is inside `min()`: `serializeWithoutOmittingPrefix`
// (CSSCalcTree+Serialization.cpp:576) prints a prefix for a non-`Leaf` child and nothing at all for
// a `Leaf`. The tree has nowhere else to record that the author wrote a math function here, so
// `consumeValueWithoutSimplifyingRootCalc` (CSSCalcTree+Parser.cpp:913 -- "Wrap in Sum to keep top
// level calc() function in serialization") encodes it as a ONE-CHILD `Sum` in the slot. The anchor
// slots are the only position in the whole tree where such a node means anything: `parseCalcSum`
// and `parseCalcProduct` both return the single term rather than building a wrapper, and at the
// root of a `Tree` the prefix comes from `serializeMathFunction`'s `Numeric` overload instead.
//
// css-values-4 8.3's one-term collapse (`simplify(Sum&)` above, "Special case a root with one
// child") is entitled to remove that wrapper, and does. That is invisible while every
// simplification happens per-operation DURING the parse, because nothing then re-simplifies the
// slot. It stops being invisible the moment a WHOLE-TREE `copyAndSimplify` runs over a parsed tree,
// which is exactly what `ParseSimplification::Terminal` does. Measured against the shipping eager
// parser, both shapes:
//
//     anchor(--a top, calc(1em * 2))  ->  anchor(--a top, calc(2em))    Sum{leaf} in the slot
//                                     ->  anchor(--a top, 2em)          bare leaf in the slot
//     anchor(--a top, 1px)            ->  anchor(--a top, 1px)          control: never gains one
//
// (~/src/webkit-swift-ports/cssprobe/validate/anchorserialize.cpp, thirteen cases, including the
// bare-literal controls that must not gain a prefix and the WPT-pinned `anchor(calc(50%))`.)
//
// So `rebuildChildren` restores the wrapper for a slot that went in as a math function and came out
// as a leaf, and the two substitution sites below drop it again: once the `anchor()` is gone the
// former fallback is an ordinary subtree, and the ordinary serialization rules supply its prefix.
//
// The slot as it came out of the pass, with the wrapper put back if the pass flattened a math
// function into a leaf. `before` is the input slot, `after` the mapped one.
static std::optional<Child> anchorSlotKeepingPrefix(const std::optional<Child>& before, std::optional<Child>&& after)
{
    if (!before || !after || isLeaf(*before) || !isLeaf(*after))
        return WTF::move(after);
    auto type = getType(*after);
    return makeChild(Sum { Vector<Child>::from(WTF::move(*after)) }, type);
}

// The slot on its way OUT of an anchor node that is being replaced by it. The wrapper only ever
// meant "this argument of anchor() keeps its prefix", so it is removed here rather than left to
// travel up the tree as a one-term `Sum` that no other node would have produced -- which would
// also make the pass non-idempotent, since a second one would collapse it.
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

// ONE walk over an operation's tuple slots, parameterised by what each slot becomes.
//
// Two callers want the same walk and differ only in the per-slot answer: `copyAndSimplifyChildren`
// below maps each slot through `copyAndSimplify`, and `CSSCalcSwiftBuilder::rebuildFrom` takes each
// slot off the Swift island's operand cursor through `rebuildSlot`. Written once, so the one thing
// that is genuinely per-operation -- `Anchor` and `AnchorSize` declaring `tuple_size` 0 while
// holding three slots each (CSSCalcTree.h:1317, "FIXME (webkit.org/b/280798): make Anchor and
// AnchorSize tuple-like") -- is stated once instead of in both walks. When that FIXME is fixed the
// two branches delete themselves and nothing else moves.
//
// `side` is COPIED, not mapped: `simplify` is not applied to the `<anchor-side>` subtree, because
// doing so would fold `anchor(--a calc(25% + 25%))` to `anchor(--a 50%)`, which this file does not
// do. `elementName` and `dimension` are not subtrees at all.
//
// `fallback` IS mapped, and the asymmetry is why it goes through `anchorSlotKeepingPrefix`: because
// the side is copied its one-child `Sum` survives, and because the fallback is simplified its own
// has to be restored. See that function for what the wrapper means and for the measurement.
//
// `NOESCAPE` is `__attribute__((noescape))` -- an UNCHECKED assertion, so it is justified rather than
// left to the reader. It holds by inspection and the inspection is exhaustive: `mapSlot` appears in
// this function in call position only, three times (the tuple-slot map and one `mapSlot(root->fallback)`
// in each of the `Anchor` / `AnchorSize` branches). It is never stored, returned, bound to a
// reference, or captured by anything. Both callers -- `copyAndSimplifyChildren` (:1914) and
// `CSSCalcSwiftBuilder::rebuildFrom` (:2317) -- pass a `[&]` lambda that is a temporary in the call
// expression, so an escape would be a dangling capture rather than a lifetime extension. This is
// C++-internal: `static` in one translation unit, not part of the Swift boundary, so no Swift-side
// safety claim depends on it.
template<typename Op, typename MapSlot> static Op rebuildChildren(const IndirectNode<Op>& root, NOESCAPE MapSlot&& mapSlot)
{
    // `Random::Sharing` is a `<random-key>`, not a `<calc-sum>`: the one tuple slot in any operation
    // that is not a subtree. Passed through here, once, rather than through an identity overload in
    // each mapper -- both had one, stating the same fact twice.
    //
    // The type is NAMED rather than tested with `requires { mapSlot(slot); }`, deliberately: the
    // `requires` form compiles and would silently pass through any slot shape a mapper does not
    // handle, which is exactly the failure `rebuildSlot`'s overload set exists to turn into a
    // compile error.
    //
    // ALWAYS_INLINE_LAMBDA IS LOAD-BEARING AND MEASURED. Without it the extra call layer moves the
    // inliner's decision for a caller this does not touch: `copyAndSimplify(const Children&)` stops
    // being emitted out of line and is inlined into `Child::switchOn<copyAndSimplify>` (2992 -> 3021
    // instructions) while `WTF::map` is outlined in its place, costing the C++ arm ~2 retired
    // instructions PER NODE -- real +0.49% on `real` and +0.69% on `depth12`, measured against a
    // +-0.08% floor (cssprobe/validate/bench-item2-0909.txt, the 2x2 in
    // arms/calc-mapslot-item2-parked.md). With it, all 605 CSSCalc symbols are instruction-identical
    // to the tree without this change and `__text` differs only in the `__LINE__` immediates the
    // added lines shift.
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

// MARK: - The Swift calc simplification port (CSSCalcSimplificationSwift.swift)
//
// Everything C++ still does for Swift is here, and the shape is the same as
// CSSCalcTree+Serialization.cpp's, with one half added. That file only had to READ the tree; this one has to write one, and the
// question the whole design answers is how a node gets constructed without the operation kind
// crossing the boundary.
//
// The answer, for the port that rewrites a borrowed C++ tree, is that the kind never crosses,
// because it never has to. Simplification rewrites a tree into a tree in which the output node's
// kind is the input node's kind, everywhere except one rule -- `clamp()` collapsing to
// `min()`/`max()`. So `rebuildFrom` takes the ORIGINAL node and recovers the operation from its own
// variant tag, filling the slots generically over the tuple conformance; Swift supplies only the
// operands and their count. That is why there is no 34-case construction switch here and no
// operation table in Swift.
//
// `buildOperation` is the other answer, for the flat tree Swift owns outright, and it names the
// alternative. That is not a relaxation of the rule above: with no original node there is nothing
// to recover a kind FROM, so a kind that does not cross is a kind that has to be reinvented. It
// also covers the `clamp()` exception, which is why no separate `buildMinMax` selector exists.
//
// The other decision worth stating is that the operands live on a C++-owned stack. No Swift
// container ever holds a `CSSCalc::Child`, so the `~Escapable` problem that shaped the tokenizer's
// token buffer does not arise at all -- not because it was priced and accepted, but
// because the representation was chosen so that it does not exist.

// The outcome numbering is declared once, in Swift, and reaches C++ through the generated header.
// These pin it, so that a reordering of the Swift enum is a build failure here rather than a silent
// reinterpretation of every simplification: `declined` read as `simplified` would install an EMPTY
// operand stack's contents as the tree.
static_assert(!static_cast<uint8_t>(CSSCalcSwiftSimplificationOutcomeSimplified));
static_assert(static_cast<uint8_t>(CSSCalcSwiftSimplificationOutcomeDeclined) == 1);

// One surviving `CalcMix` item's weight, and the one boundary shape here that is neither a
// subtree nor a scalar computed outright.
//
// Two cases because a weight has two provenances, and only one is expressible in Swift. Spec
// steps 2 and 4 produce weights arithmetically -- `(100% - specified sum) / n` and `weight * 100%
// / total` -- and those cross as a `double`. But `simplify(CalcMix&)`'s `!canNormalize` path
// (`+Simplification.cpp:1509`-`:1529`) removes items while leaving every survivor's weight alone,
// and a survivor there can hold a `Calc` weight, a whole `CSSCalcValue` that cannot be reproduced
// in Swift. So Swift names the item it came from instead, and C++ copies its
// `std::optional<Weight>` by the index Swift gives rather than by a position C++ assumes.
//
// Not in CSSCalcSwiftTypes.h: nothing about it crosses. `pushCalcMixItemWeight` takes the three
// fields as arguments, so this type stays a detail of the reconstruction.
struct CalcMixWeightPlan {
    // The replacement weight, as a `<percentage>` in [0,100]. Meaningful only when `replace` is set;
    // 0 rather than indeterminate otherwise.
    double weight;
    // The item's index in the original item list, when `replace` is not set.
    uint32_t origin;
    bool replace;
};

// Swift's operand stack, forward-declared in CSSCalcSwiftTypes.h so that boundary header can
// stay free of wtf/Vector.h. One line, and it is the entire reason no Swift type ever has to hold a
// `Child`.
// Inline capacity, so a simplification whose peak operand run fits leaves the allocator untouched.
// Worth a FLAT ~240 retired instructions per simplification on every band of calc-shapes.tsv and
// calc-depth.tsv, which is 23% of the `leaf` band -- single-node trees, where there is no walk to
// amortise the per-call cost over. 16 rather than 8: the peak is the widest operand run the walk
// holds at once, one per leaf for the widest operation in the tree, and at 8 a 12-term sum
// (`ladder12`) pays the inline-to-heap move on top of the malloc it still makes -- measured +388
// there against -246 at 16, with the -240 on every other band unchanged either way.
using OperandVector = Vector<Child, 16>;

struct CSSCalcSwiftOperandStack {
    OperandVector value { };
    // The weights the next CalcMix reconstruction pairs with its items, in item order. A separate
    // stack because a weight is not a subtree; kept as a stack rather than per-node so a nested
    // CalcMix follows the same consume-the-top discipline as every other slot shape.
    Vector<CalcMixWeightPlan> calcMixWeights { };
    // Where the finished ROOT is constructed, instead of on the stack: `Tree::root` inside the
    // caller's own return object. `swiftSimplifiedRoot` below is what makes that address reachable;
    // `CSSCalcSwiftBuilder::pushLeaf`'s `isRoot` comment is why it exists.
    //
    // Null for the `ENABLE(CSS_TOKENIZER_SWIFT_BRIDGE)` primitive benchmarks, which drive the
    // builder directly and have no tree to put a root in; the root then goes on the stack like
    // anything else and their `value.size() == 1` assertions are unchanged.
    //
    // ALSO THE COMPLETION FLAG. `constructOperand` nulls it as it consumes it, so "a construction
    // has taken the root slot" needs no second field: `trySimplifyWithSwiftIsland` reads a
    // still-non-null slot as "the walk finished leaving the caller's placeholder in place". The
    // safety property is the one a separate `bool` gave, not a weaker one -- a second root
    // construction finds a null slot, appends to the operand stack instead of overwriting a live
    // `Child`, and the non-empty-stack half of that same check declines the tree.
    Child* rootSlot { nullptr };

    // THE FLAT ARM'S DESTINATION AND SOURCE (P7c slice C1d). Null on every path that does not carry
    // one, which is the primitive benchmarks, the differential's non-store arms and the whole
    // simplification path.
    //
    // HERE RATHER THAN ON `CSSCalcSwiftBuilder`, which is where C1c's sketch put them. The builder
    // is 16 bytes and the `simplifyX` family takes it BY VALUE as an `Optional` on a per-node path;
    // two more pointers there would take every one of those copies from two registers to four. This
    // struct is a stack local constructed once per parse and the builder already indirects through
    // it, so the pointers cost three folded null stores instead. It is also forward-declared in the
    // boundary header, so nothing here is visible to Swift and no `SWIFT_SAFE` claim changes.
    //
    // Two pointers rather than one because the two directions differ in constness and a `const_cast`
    // to unify them would be a lie about which entry mutates: `flatNodesOut` is the parse's
    // destination, `flatNodesIn` is what a rebuild reads back.
    CSSCalcSwiftFlatNodeVector* flatNodesOut { nullptr };
    uint32_t* flatRootIndexOut { nullptr };
    const CSSCalcSwiftFlatNodeVector* flatNodesIn { nullptr };
};

// Where a finished node goes.
//
// The root slot when this is the root and one was provided, the top of the operand stack
// otherwise. Both are IN-PLACE constructions from a named alternative -- `Vector::constructAndAppend`
// and placement new select the variant member at compile time -- so neither route builds an
// intermediate `Child`.
//
// THE PLACEHOLDER'S DESTRUCTOR IS DELIBERATELY NOT RUN. `Tree` has no default constructor, so the
// root slot handed over is not raw storage but a live `Child` holding a `Number` (see
// `swiftSimplifiedRoot`). [basic.life]/5 permits reusing an object's storage without calling its
// non-trivial destructor as long as nothing depends on that destructor's side effects, and a
// `Number` has none -- it is two words of POD inside the variant. Calling `~Child()` here would
// cost exactly the out-of-line 41-alternative `mpark` visit this whole route exists to remove,
// which would be half the saving spent to no effect.
template<typename... Args>
static ALWAYS_INLINE void constructOperand(CSSCalcSwiftOperandStack& operands, bool isRoot, Args&&... args)
{
    static_assert(std::is_trivially_destructible_v<Number>, "the root placeholder's storage is reused without a destructor call, which [basic.life]/5 allows only because nothing depends on the destructor");
    if (Child* slot = isRoot ? std::exchange(operands.rootSlot, nullptr) : nullptr)
        new (NotNull, slot) Child(std::forward<Args>(args)...);
    else
        operands.value.constructAndAppend(std::forward<Args>(args)...);
}

// The operands `rebuildFrom` fills a node's slots from: a forward cursor over the top of the stack.
//
// A cursor rather than a per-operation arity computed up front: `Children` and CalcMix's item
// vector can change arity during simplification, so demand is not a fixed function of the
// operation. The contract check is exact both ways: too few operands trips `ok`; too many leaves
// the cursor short of `end`.
struct RebuildCursor {
    OperandVector& stack;
    size_t next;
    size_t end;
    // The weight stack and the position this node's CalcMix weights start at. Carried on the
    // cursor rather than reached through the builder, so `rebuildSlot` needs no extra parameter
    // just for the one slot shape that has a second stack.
    Vector<CalcMixWeightPlan>& weights;
    size_t weightBase;
    bool ok { true };

    bool exhausted() const { return next >= end; }

    Child take()
    {
        if (exhausted()) {
            ok = false;
            // Never reaches the tree: `rebuildFrom` discards the whole node when `ok` is false. Exists
            // because a slot expression cannot decline mid-aggregate-initialisation; returning a
            // default is cheaper than making every slot optional.
            return makeChild(Number { .value = 0 });
        }
        return WTF::move(stack[next++]);
    }
};

// One overload per CHILD-SHAPED slot, which is what makes `rebuildFrom` generic over all
// operations: `rebuildChildren` hands each tuple slot that holds a subtree to this set, and passes
// the one that does not (`Random::Sharing`) through itself. Adding an operation adds no code here
// unless it adds a new slot shape, in which case it fails to compile rather than silently
// mishandling it.
static Child rebuildSlot(const Child&, RebuildCursor& cursor)
{
    return cursor.take();
}

static std::optional<Child> rebuildSlot(const std::optional<Child>& original, RebuildCursor& cursor)
{
    // Presence follows the original: round(X) stays one-argument and round(X, Y) stays two,
    // because childCount counted only the present operands.
    if (!original)
        return std::nullopt;
    return cursor.take();
}

static ChildOrNone rebuildSlot(const ChildOrNone& original, RebuildCursor& cursor)
{
    // The `none` keyword is not a child and was never pushed, so it comes off the original -- the
    // same asymmetry `CSSCalcSwiftNodeKind::ClampWithNoneMinimum` exists for on the reading side.
    if (WTF::holdsAlternative<CSS::Keyword::None>(original))
        return ChildOrNone { CSS::Keyword::None { } };
    return ChildOrNone { cursor.take() };
}

static Children rebuildSlot(const Children&, RebuildCursor& cursor)
{
    // All the remaining operands; the original's count is deliberately not consulted. This is what
    // lets a Sum lose a zero term, a min() fold two arguments together, or a Product collapse to a
    // single factor. Children is always the only slot for the operations that have one (Sum,
    // Product, Min, Max, Hypot), so "the rest" is unambiguous.
    //
    // Moved straight out of the stack rather than through `take()`, which returns a `Child` BY
    // VALUE and so costs a second out-of-line 41-alternative `mpark` variant move per operand --
    // measured at ~42 retired instructions each on the ladder bands (the `movecut` probe in
    // notes/calc-buildoperation-widening-REFUTED-0908.md section 6). `take()`'s only behavioural
    // extra is its `exhausted()` guard, which the loop bound enforces instead; the cursor is
    // advanced once because every remaining operand is taken.
    Vector<Child> children;
    children.reserveInitialCapacity(cursor.end - cursor.next);
    for (size_t i = std::exchange(cursor.next, cursor.end); i < cursor.end; ++i)
        children.append(WTF::move(cursor.stack[i]));
    return Children { WTF::move(children) };
}

static Vector<CalcMix::Item> rebuildSlot(const Vector<CalcMix::Item>& original, RebuildCursor& cursor)
{
    // `CalcMix`'s single tuple slot is a `Vector<Item>` rather than a `Children`, because each
    // argument carries an optional weight beside its value; without this overload `WTF::apply`
    // would not compile for `CalcMix`.
    //
    // All the remaining operands are taken, as in `rebuildSlot(const Children&)`; the original's
    // item count is not consulted. `simplify(CalcMix&)` can remove zero-weight and omitted-weight
    // items and rewrite survivors' weights, so pairing weights to items by position against the
    // original is wrong in general. Each surviving item's weight is instead looked up by index
    // through `CalcMixWeightPlan`, never by position or by item count. `weightBase` marks where
    // this node's own plans start, so a nested `CalcMix` cannot re-read weights a previous consume
    // already took.
    size_t itemCount = cursor.end - cursor.next;
    if (cursor.weights.size() - cursor.weightBase != itemCount) {
        // Too few weights means the operand and weight stacks got out of step, a contract violation
        // rather than a possible input; too many is the same fault from the other side. Declines
        // rather than pairing a prefix.
        cursor.ok = false;
        return { };
    }

    Vector<CalcMix::Item> items;
    items.reserveInitialCapacity(itemCount);
    for (size_t i = 0; i < itemCount; ++i) {
        auto& plan = cursor.weights[cursor.weightBase + i];
        std::optional<CalcMix::Item::Weight> weight;
        if (plan.replace) {
            // `CalcMix::Item::Weight { double }` is the same construction `simplify(CalcMix&)` uses at each
            // of its four weight assignments (`:1552`, `:1560`, `:1579`, `:1608`), so a normalised
            // weight built here matches one built there.
            weight = CalcMix::Item::Weight { plan.weight };
        } else if (plan.origin < original.size()) {
            // The survivor's own weight, whatever it is -- including a `Calc` one or an absent one, which is
            // why this is an `std::optional<Weight>` copy rather than a value copy.
            weight = original[plan.origin].weight;
        } else {
            cursor.ok = false;
            return { };
        }
        items.append(CalcMix::Item { .value = cursor.take(), .weight = WTF::move(weight) });
    }
    cursor.weights.shrink(cursor.weightBase);
    return items;
}

// The `SimplificationOptions` fields Swift reads, as a POD.
//
// One definition rather than one per entry point, because there are now two: the whole-tree
// simplification (`trySimplifyWithSwiftIsland`) and the fused parse (`cssCalcSwiftParseIntoChild`),
// which runs the same in-Swift pass over a tree the grammar built rather than one it flattened.
// Two hand-written copies of a six-field conversion is exactly the shape that goes out of step.
static CSSCalcSwiftSimplificationOptions swiftSimplificationOptions(const SimplificationOptions& options)
{
    return CSSCalcSwiftSimplificationOptions {
        .rangeMinimum = options.range.min,
        .rangeMaximum = options.range.max,
        .category = static_cast<uint8_t>(options.category),
        .allowZeroValueLengthRemovalFromSum = options.allowZeroValueLengthRemovalFromSum,
        .hasConversionData = options.conversionData.has_value(),
        // Derived here, not in Swift: it is an eleven-case switch over `CSS::Category` whose whole
        // content is "is it one of these two", and deriving it in Swift would duplicate the
        // category table there.
        .percentageResolveToDimension = percentageResolveToDimension(options),
    };
}

// Rebuild a `Child` from a stored flat tree, for a consumer that has not been ported yet.
//
// The mirror of `cssCalcSwiftParseIntoChild`, and it lives here for the same reason: the operand
// stack holds a `WTF::Vector<Child>`, so it is only complete in this translation unit and no other
// file can construct one. All the work is in Swift -- this is the stack, the contract check and
// nothing else.
bool cssCalcSwiftEmitStoreIntoChild(const CSSCalcSwiftFlatNodeVector& nodes, uint32_t rootIndex, const SimplificationOptions& options, Child& outRoot) noexcept
{
    CSSCalcSwiftOperandStack operands { .rootSlot = &outRoot, .flatNodesIn = &nodes };
    CSSCalcSwiftBuilder builder { operands, options };
    if (!cssCalcSwiftEmitFromStore(builder, rootIndex) || operands.rootSlot || !operands.value.isEmpty()) {
        builder.clearOperands();
        return false;
    }
    return true;
}

CSSCalcSwiftParseResult cssCalcSwiftParseIntoChild(const CSSParserTokenRange& innerRange, CSSCalcSwiftParseOptions parseOptions, const SimplificationOptions& options, Child& outRoot, bool simplify, CSSCalcSwiftFlatNodeVector* outFlatNodes, uint32_t* outFlatRootIndex) noexcept
{
    CSSCalcSwiftOperandStack operands { .rootSlot = &outRoot, .flatNodesOut = outFlatNodes, .flatRootIndexOut = outFlatRootIndex };
    CSSCalcSwiftBuilder builder { operands, options };
    auto cursor = CSSCalcSwiftParseCursor { innerRange };

    auto result = cssCalcParseSwift(cursor, builder, parseOptions, swiftSimplificationOptions(options), simplify);

    if (result.outcome != static_cast<uint8_t>(CSSCalcSwiftParseOutcome::Parsed)) {
        // A failed or declined descent can leave partial operands behind; drop them rather than
        // letting the stack's destructor be the only thing that notices.
        builder.clearOperands();
        return result;
    }

    // The same contract the simplification entry checks, and for the same reason: a boundary that
    // came apart must be a fallback to the C++ arm, not a tree built from whatever was left on the
    // stack. The emit constructs the root straight into the slot -- it knows which node is the root,
    // which is what removed `finishRoot` -- so a non-null one here means the descent finished while
    // leaving the caller's placeholder in place.
    if (operands.rootSlot || !operands.value.isEmpty()) {
        builder.clearOperands();
        result.outcome = static_cast<uint8_t>(CSSCalcSwiftParseOutcome::Failed);
    }
    return result;
}

bool CSSCalcSwiftBuilder::pushLeaf(CSSCalcSwiftLeaf leaf, bool isRoot) noexcept
{
    // `constructAndAppend`, not `append(makeChild(...))`, wherever the alternative is named here.
    // `makeChild` returns a whole `Child`, and appending one move-constructs the 41-alternative
    // `Variant` into the stack slot -- an out-of-line `mpark` visit the C++ arm never makes, because
    // `copyAndSimplify` ends at a `makeChild` whose result object IS its own return slot.
    // Constructing from the alternative instead selects the variant member at COMPILE time, so
    // there is no visit and no intermediate `Child` at all. `sample` on the single-node band put the
    // three extra variant visits the Swift arm makes at 15.3% of its profile.
    switch (static_cast<CSSCalcSwiftNodeKind>(leaf.kind)) {
    case CSSCalcSwiftNodeKind::Percentage:
        // The one alternative `makeNumeric` cannot produce faithfully: it builds a `Percentage`
        // with `hint = { }` (CSSCalcTree.cpp:197), and a folded percentage has to keep the hint its
        // operand had, exactly as `makeChildWithValueBasedOn` does at CSSCalcTree.cpp:318. That is
        // the whole reason `kind` is on `CSSCalcSwiftLeaf` beside `unitType`.
        constructOperand(*m_operands, isRoot, Percentage {
            .value = leaf.value,
            .hint = leaf.percentHint ? Type::PercentHintValue { static_cast<PercentHint>(leaf.percentHint) } : Type::PercentHintValue { }
        });
        return true;

    case CSSCalcSwiftNodeKind::NonCanonicalDimension:
        // `makeNumeric` cannot produce this alternative faithfully: it maps unit to alternative, so it
        // cannot express "stays a `NonCanonicalDimension`" for a unit it classifies as something
        // else -- the six canonical dimensional units, the three non-dimensional ones and the five
        // non-numeric ones, fourteen in total. `simplify(NonCanonicalDimension&)` copies the node
        // through unchanged in all of those cases, so this leaf is built directly instead of via
        // `makeNumeric`.
        //
        // `unit` is the only member `NonCanonicalDimension` has beside `value` (CSSCalcTree.h:138),
        // so nothing is re-derived here and no table crosses.
        constructOperand(*m_operands, isRoot, NonCanonicalDimension { .value = leaf.value, .unit = static_cast<CSSUnitType>(leaf.unitType) });
        return true;

    case CSSCalcSwiftNodeKind::Number:
        // `makeNumeric` maps `CSSUnitType::Number` and `CSSUnitType::Integer` to `Number { value }`
        // and nothing else maps to that alternative, so for this kind its seventy-case
        // classification has exactly ONE outcome and naming the alternative here duplicates no
        // table -- the two-element set below is the whole of what this arm reads from it.
        //
        // Worth naming rather than routing through `makeNumeric`, because it takes the arm off BOTH
        // out-of-line calls: `makeNumeric` itself (34 retired instructions) and the variant
        // move-construct that appending its finished `Child` costs (measured at 69 on the operator
        // arm below).
        //
        // CHECKED, not assumed: `kind` and `unitType` are two independent boundary fields and this
        // is the one arm where their agreement is load-bearing, so a `Number` kind carrying any
        // other unit declines to the C++ arm instead of building a `Number` where `makeNumeric`
        // would have built a dimension. `simplifycheck`'s decline count is the non-vacuous check --
        // it is 45, and 45 of those are the constructed `Clamp` shapes, so nothing in 924951 cases
        // reaches this.
        if (auto unit = static_cast<CSSUnitType>(leaf.unitType); unit != CSSUnitType::Number && unit != CSSUnitType::Integer)
            return false;
        constructOperand(*m_operands, isRoot, Number { .value = leaf.value });
        return true;

    case CSSCalcSwiftNodeKind::CanonicalDimension:
        // `makeNumeric` owns the classification, including which `CanonicalDimension::Dimension` a
        // canonical unit means, so `Dimension` never crosses the boundary. `unitType` is
        // authoritative here; `kind` states what Swift believes it is building, and the
        // differential test checks the two agree.
        //
        // The one arm that keeps the extra variant move, and deliberately: the alternative's
        // PAYLOAD is not known here -- it is `makeNumeric`'s unit switch that picks the `Dimension`
        // -- and naming it at this call site would put a second copy of the canonical-unit table on
        // the boundary. Unlike the `Number` arm above, the set is six units wide and each maps to a
        // different value, so there is nothing to check instead of duplicating.
        constructOperand(*m_operands, isRoot, makeNumeric(leaf.value, static_cast<CSSUnitType>(leaf.unitType)));
        return true;

    case CSSCalcSwiftNodeKind::SiblingCount:
        // THE TREE-COUNTING FUNCTIONS ARE LEAVES, not zero-argument operations
        // (`CSSCalcTree.h:161`-`:181`, `static constexpr bool isLeaf = true`), which is why stage F1
        // lands here and never reaches `buildOperation` -- whose `!childCount` guard a zero-operand
        // alternative could not have passed anyway.
        //
        // NO PAYLOAD AT ALL: both are empty structs and `getType` of either is `Type { }`
        // (`CSSCalcTree.cpp:451`-`:459`), so `value`, `unitType` and `percentHint` on the incoming
        // leaf are inert and nothing is re-derived here. The `kind` IS the whole crossing.
        constructOperand(*m_operands, isRoot, SiblingCount { });
        return true;

    case CSSCalcSwiftNodeKind::SiblingIndex:
        constructOperand(*m_operands, isRoot, SiblingIndex { });
        return true;

    default:
        // A kind outside the four numeric leaves and the two tree-counting ones is a contract
        // violation rather than a possible input, and declines rather than building something
        // plausible.
        return false;
    }
}

void CSSCalcSwiftBuilder::pushCopyOf(const Child& node, bool isRoot) noexcept
{
    // `CSSCalc::copy(const Child&)`, which is what `copyAndSimplifyChildren` bottoms out in too, so
    // the two cannot disagree about what a copy is.
    constructOperand(*m_operands, isRoot, copy(node));
}

void CSSCalcSwiftBuilder::pushCalcMixItemWeight(uint32_t origin, double weight, bool replaceWeight) noexcept
{
    m_operands->calcMixWeights.append(CalcMixWeightPlan { .weight = weight, .origin = origin, .replace = replaceWeight });
}

// Defined here rather than in CSSCalcTree+Serialization.cpp, where the other two node readers live:
// those two sit next to the child walker so the count and the indices stay in step, while this
// reads a payload no walker yields -- `forAllChildNodes` visits nothing for a weight -- so there is
// nothing here to stay in step with.
CSSCalcSwiftCalcMixWeight swiftCalcMixItemWeight(const Child& node, uint32_t index) noexcept
{
    // `get_if` rather than `switchOn`, for the reason CSSCalcTree+Serialization.cpp:1322 gives at the
    // one other place a specific alternative is reached for: a generic visitor instantiates its
    // fallback once per alternative, costing ~22 KB for an answer only one kind has.
    auto* calcMix = get_if<IndirectNode<CalcMix>>(&node);
    if (!calcMix || index >= (*calcMix)->children.size()) {
        // Asked about a node that is not a `CalcMix`, or about an item past the end. Not a
        // `RELEASE_ASSERT` as `Child::operator[]` uses: an out-of-range child there would be a wrong
        // serialization, while "absent" here is a state already handled (spec step 1's omitted
        // weight), so a safe answer exists.
        return { };
    }

    auto& weight = (*calcMix)->children[index].weight;
    if (!weight)
        return { };
    if (auto raw = weight->raw())
        return { .value = raw->value, .present = true, .isRaw = true };
    // A `Calc` weight: present, and its value stays in C++. `raw()` is `std::optional<Raw>`
    // (CSSPrimitiveNumeric.h:120), so this is the same test `isRaw()` is, not a second one.
    return { .value = 0, .present = true, .isRaw = false };
}

bool CSSCalcSwiftBuilder::rebuildFrom(const Child& original, uint32_t childCount, bool isRoot) noexcept
{
    auto& stack = m_operands->value;
    auto& weights = m_operands->calcMixWeights;
    if (childCount > stack.size())
        return false;

    size_t base = stack.size() - childCount;
    // Only a `CalcMix` reconstruction reads the weight stack, so this must not refuse a node that
    // has none: every other slot shape leaves `weights` untouched and `weightBase` is inert for
    // them. Clamped rather than asserted, so a `CalcMix` arriving without its own weights lands on
    // `rebuildSlot`'s `!=` test (`weights.size() - weightBase` is 0 against a non-zero item count)
    // rather than on an underflowed `size_t`.
    size_t weightBase = weights.size() >= childCount ? weights.size() - childCount : weights.size();
    RebuildCursor cursor { stack, base, stack.size(), weights, weightBase };

    // The generic lambda instantiates once per alternative, which is the ~22 KB shape
    // `childInSerializationOrder` avoided with `get_if`. It is not avoidable here and it is not new
    // cost: reconstruction genuinely is per-operation, and `copyAndSimplifyChildren` at :1786 is the
    // same instantiation over the same 41 alternatives already in the binary.
    auto rebuilt = WTF::switchOn(original,
        [&](const auto& alternative) -> std::optional<Child> {
            if constexpr (requires { *alternative; }) {
                // The SAME walk `copyAndSimplifyChildren` uses, with `rebuildSlot` in place of
                // `copyAndSimplify`: every slot shape is served by an overload rather than by an
                // arm here, so adding an operation adds no code unless it adds a slot shape, in
                // which case it fails to compile. `Anchor`'s and `AnchorSize`'s non-tuple-like
                // layout is handled inside `rebuildChildren` for both callers at once.
                auto op = rebuildChildren(alternative, [&](const auto& slot) { return rebuildSlot(slot, cursor); });
                if (!cursor.ok || !cursor.exhausted())
                    return std::nullopt;
                // The ORIGINAL's type, which is what `copyAndSimplify` uses at :1814. A node
                // whose children simplified but whose kind did not change keeps its type; the
                // one rewrite that does change kind asks `buildOperation` for a fresh one.
                return makeChild(WTF::move(op), getType(alternative));
            } else {
                // A leaf has no slots to rebuild from, so asking is a contract violation.
                return std::nullopt;
            }
        }
    );

    if (!rebuilt) {
        // Some operands may have been moved out of before the failure. That is harmless and not tidied
        // up: `rebuildFrom` returning false declines the whole tree, and the stack is destroyed
        // unread. A moved-from `Child` is destructible, which is all that is required.
        return false;
    }

    stack.shrink(base);
    constructOperand(*m_operands, isRoot, WTF::move(*rebuilt));
    return true;
}

// Not gated: `cssCalcSwiftParseIntoChild` above calls this on its failure and contract-violation
// paths, and that entry is production. See the declaration's comment.
void CSSCalcSwiftBuilder::clearOperands() noexcept
{
    m_operands->value.shrink(0);
}

size_t CSSCalcSwiftBuilder::takeFlatNodes(const CSSCalcSwiftFlatNode* __counted_by(nodeCount) nodes __attribute__((noescape)), size_t nodeCount, uint32_t rootIndex) noexcept
{
    // No destination is not a failure: the differential's non-store arms and the primitive
    // benchmarks parse without one, and the Swift side asserts the crossing by comparing this
    // against the node count it handed over.
    if (!m_operands->flatNodesOut)
        return nodeCount;

    // ONE malloc for the whole tree, straight into the `Vector` the `Tree` will own, where C1b's
    // store object took a TZone allocation as well. Assigning rather than appending, because the
    // destination is a fresh local in `parseAndSimplify` that no earlier attempt has written to --
    // the grammar's oversized retry starts from a clean state by construction.
    *m_operands->flatNodesOut = CSSCalcSwiftFlatNodeVector(unsafeMakeSpan(nodes, nodeCount));
    if (m_operands->flatRootIndexOut)
        *m_operands->flatRootIndexOut = rootIndex;
    return m_operands->flatNodesOut->size();
}

uint32_t CSSCalcSwiftBuilder::flatNodeCount() const noexcept
{
    return m_operands->flatNodesIn ? m_operands->flatNodesIn->size() : 0;
}

CSSCalcSwiftFlatNode CSSCalcSwiftBuilder::flatNodeAt(uint32_t index) const noexcept
{
    // Out of range answers a terminated node rather than trapping, matching what
    // `CSSCalcSwiftParseCursor::tokenAt` does past the end: the caller is a Swift walk whose
    // termination condition is the sentinel, so handing it the sentinel makes the walk stop where
    // a bounds pre-check on the Swift side would have stopped it, and does so without Swift having
    // to mirror a bound it cannot see.
    if (!m_operands->flatNodesIn || index >= m_operands->flatNodesIn->size()) {
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
    return (*m_operands->flatNodesIn)[index];
}

bool CSSCalcSwiftBuilder::buildOperation(CSSCalcSwiftAlternative alternative, uint32_t childCount, Type carriedType, bool isRoot, uint8_t noneMask) noexcept
{
    auto& stack = m_operands->value;
    if (!childCount || childCount > stack.size())
        return false;

    size_t base = stack.size() - childCount;

    auto finish = [&](auto&& op) -> bool {
        stack.shrink(base);
        // `constructAndAppend`, not `append(makeChild(...))`: the same in-place construction
        // `pushLeaf` uses. `makeChild` hands back a whole `Child`, and appending one move-constructs
        // the 41-alternative `Variant` through an out-of-line `mpark` visit that the C++ arm never
        // makes -- `copyAndSimplify` ends at a `makeChild` whose result object IS its own return
        // slot. Naming the alternative instead picks the variant member at COMPILE time.
        // `makeIndirectNode` is `ChildConstruction`'s own indirect half (CSSCalcTree.h), so this is
        // not a second spelling of how an operation node is built.
        //
        // No `toType` here, and that is the point of `carriedType`. The one rewrite whose output
        // kind is not its input kind -- `clamp()` to `min()`/`max()` -- computes its own type in
        // `CalcFlatTree.convertToMinMax` and carries it like every other node, so there is no second
        // type rule and no failure mode a caller would have to unwind an already-consumed operand
        // stack to recover from.
        constructOperand(*m_operands, isRoot, makeIndirectNode(WTF::move(op), carriedType));
        return true;
    };

    // The `Children`-slotted operations. Taking every operand is what lets the arity change, which
    // is the commonest simplification there is -- dropping a zero term from a sum.
    auto takeChildren = [&] {
        Vector<Child> children;
        children.reserveInitialCapacity(childCount);
        for (size_t i = base; i < stack.size(); ++i)
            children.append(WTF::move(stack[i]));
        return children;
    };

    // The single-`Child` operations, as one body: the alternative selects the variant member and
    // nothing else varies. See the stage E2 arms below for why this is a lambda rather than eleven
    // copies of `Negate`'s three lines.
    auto finishOneChild = [&]<typename Op>() -> bool {
        static_assert(std::tuple_size_v<Op> == 1 && std::is_same_v<std::remove_cvref_t<std::tuple_element_t<0, Op>>, Child>,
            "buildOperation's one-Child arm fills exactly one Child slot; an operation shaped differently must not reach it.");
        if (childCount != 1)
            return false;
        return finish(Op { WTF::move(stack[base]) });
    };

    // `Child a; std::optional<Child> b` -- `round()`'s four strategies and `log()` (stage E4).
    //
    // THE PRESENCE OF THE SECOND SLOT IS THE OPERAND COUNT AND NOTHING ELSE, which is the whole
    // reason this stage adds no boundary argument where `clamp()` needed two bits. Two operands
    // fill both slots, one fills the first and leaves `std::nullopt`, and no third state exists --
    // `rebuildSlot(const std::optional<Child>&)` states the same rule for the rebuild direction
    // (`:2098`). The arity check is therefore `<= 2`, and `>= 1` is the entry's own precondition.
    auto finishOptionalSecond = [&]<typename Op>() -> bool {
        static_assert(std::tuple_size_v<Op> == 2 && std::is_same_v<std::remove_cvref_t<std::tuple_element_t<0, Op>>, Child>
            && std::is_same_v<std::remove_cvref_t<std::tuple_element_t<1, Op>>, std::optional<Child>>,
            "buildOperation's optional-second arm fills one Child and one std::optional<Child>; an operation shaped differently must not reach it.");
        if (childCount > 2)
            return false;
        return finish(Op { WTF::move(stack[base]),
            childCount == 2 ? std::optional<Child> { WTF::move(stack[base + 1]) } : std::optional<Child> { } });
    };

    // A FIXED NUMBER of plain `Child` slots, two or three -- stage E5's `mod` `rem` `atan2` `pow`
    // and `progress()`'s two alternatives.
    //
    // ONE ARM FOR BOTH ARITIES, driven by `std::tuple_size_v<Op>` rather than by two hand-written
    // shapes, which is the design note's W-B: a family with a new arity of `Child`s costs zero
    // lines here. Braced-init evaluates left to right, so slot order is operand order -- the same
    // guarantee `rebuildChildren`'s `WTF::apply` already relies on (`:1919`).
    //
    // Still purely ADDITIVE: `Negate`/`Invert` keep `finishOneChild` and the four `Children`-slotted
    // arms keep `takeChildren`, because rerouting already-served alternatives onto new machinery is
    // what the refuted 2026-09-08 widening measured at +7.78 %.
    auto finishFixedArity = [&]<typename Op>() -> bool {
        if (childCount != std::tuple_size_v<Op>)
            return false;
        return [&]<size_t... I>(std::index_sequence<I...>) {
            static_assert((std::is_same_v<std::remove_cvref_t<std::tuple_element_t<I, Op>>, Child> && ...),
                "buildOperation's fixed-arity arm fills N plain Child slots; an operation shaped differently must not reach it.");
            return finish(Op { WTF::move(stack[base + I])... });
        }(std::make_index_sequence<std::tuple_size_v<Op>> { });
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
    // Stage E5. `hypot` is `Children`-slotted like the four above and shares `min`/`max`'s type
    // rule exactly, so it joins them here and the Swift side reuses `calcParseArgumentList`
    // unchanged -- the variadic family costs one arm and no new machinery on either side.
    case CSSCalcSwiftAlternative::Hypot:
        return finish(Hypot { .children = takeChildren() });

    case CSSCalcSwiftAlternative::Negate:
        if (childCount != 1)
            return false;
        return finish(Negate { WTF::move(stack[base]) });
    case CSSCalcSwiftAlternative::Invert:
        if (childCount != 1)
            return false;
        return finish(Invert { WTF::move(stack[base]) });

    // The ten unary math functions, plus the `Deg2Rad` wrapper the grammar inserts around an
    // <angle> argument to sin/cos/tan (P7b stage E2).
    //
    // WHY ANY OF THIS IS C++. Swift cannot construct a `CSSCalc::Child`: a `@frozen public struct`
    // exports as non-trivially-copyable and non-default-constructible, and no Swift container
    // accepts a `~Escapable` element (toolchain filings register section 55). So the mapping from
    // an alternative to the variant member it names can only be spelled where the variant is
    // declared, and eleven of those names are what stage E2 costs. This WIDENS an entry that
    // already exists rather than adding a boundary -- nothing new crosses, and the Swift arm calls
    // exactly the entry it already called for `Negate`.
    //
    // GENERATED, NOT TRANSCRIBED. Every one of them has `Negate`'s and `Invert`'s slot shape -- one
    // `Child` and nothing else -- so the arity check and the construction are a single templated
    // lambda and the case labels come from the list the boundary header already owns. The
    // `static_assert` is what makes "same slot shape" a checked claim rather than an asserted one,
    // and it is `rebuildSlot`'s own rule in miniature (`:1893`-`:1896`): an operation shaped
    // differently must FAIL TO COMPILE here rather than be silently filled from one operand. It is
    // not a `requires`, for the reason given there -- a `requires` drops the unhandled shape
    // through to some other overload.
    //
    // THE SIX ARMS ABOVE ARE NOT REROUTED THROUGH IT. That is deliberate: the refuted 2026-09-08
    // widening's +7.78 % was attributed in the disassembly to `RebuildCursor::take()`'s by-value
    // `Child` return and to an outlined generic dispatch, both incurred because it moved the
    // EXISTING alternatives onto new machinery. This arm is purely additive.
#define CSS_CALC_SWIFT_BUILD_ONE_CHILD(name) \
    case CSSCalcSwiftAlternative::name: \
        return finishOneChild.operator()<name>();
    CSS_CALC_SWIFT_FOR_EACH_UNARY_MATH_FUNCTION(CSS_CALC_SWIFT_BUILD_ONE_CHILD)
#undef CSS_CALC_SWIFT_BUILD_ONE_CHILD

#define CSS_CALC_SWIFT_BUILD_OPTIONAL_SECOND(name) \
    case CSSCalcSwiftAlternative::name: \
        return finishOptionalSecond.operator()<name>();
    CSS_CALC_SWIFT_FOR_EACH_OPTIONAL_SECOND_MATH_FUNCTION(CSS_CALC_SWIFT_BUILD_OPTIONAL_SECOND)
#undef CSS_CALC_SWIFT_BUILD_OPTIONAL_SECOND

#define CSS_CALC_SWIFT_BUILD_FIXED_ARITY(name) \
    case CSSCalcSwiftAlternative::name: \
        return finishFixedArity.operator()<name>();
    CSS_CALC_SWIFT_FOR_EACH_FIXED_ARITY_MATH_FUNCTION(CSS_CALC_SWIFT_BUILD_FIXED_ARITY)
#undef CSS_CALC_SWIFT_BUILD_FIXED_ARITY

    // `clamp()` (P7b stage E3), and the ONE alternative in the grammar's reach whose slots cannot
    // be filled from the operand stack alone.
    //
    // WHY `noneMask` AND NOTHING ELSE. Two of the three slots are `ChildOrNone`, so a bound is
    // either a subtree or the keyword. A keyword is not pushed -- the same asymmetry
    // `rebuildSlot(const ChildOrNone&)` above (`:2107`) has, where the answer comes off the
    // ORIGINAL node -- so `clamp(none, V, M)` and `clamp(M, V, none)` arrive here indistinguishable
    // by count, both with two operands. That is two bits of genuinely new information and the
    // boundary header carries them as a defaulted trailing parameter, which costs no call site and
    // no line. A sentinel operand would cost a `makeUniqueRef` allocation per `none`, built only to
    // be discarded.
    //
    // THE ARITY CHECK IS THE MASK'S OWN, not a fixed 3: an absent bound is an absent operand, so
    // the contract is `childCount + popcount(noneMask) == 3`. Getting that wrong is a read past the
    // top of the stack, which is why it is checked before any slot is taken rather than after.
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

    default:
        // Outside the set this entry serves. A contract violation of the caller's own scope rather
        // than an input it could serve, so the stack is left exactly as it was found.
        return false;
    }
}

// The two shapes every `CSSCalcSwiftNumericResult` answer takes, written once instead of
// duplicated across `resolveSymbol` and `resolveRelativeLength`. `CSSUnitType::Unknown` and the
// inert `Number` alternative are the values `CSSCalcSwiftNumericResult`'s own comments specify for
// `resolved == false`.
static constexpr CSSCalcSwiftNumericResult unresolvedNumber { .value = 0, .unitType = static_cast<uint16_t>(CSSUnitType::Unknown), .resolved = false, .alternative = CSSCalcSwiftAlternative::Number, .substituteFallback = false };

// A resolved plain `<number>`. `toCSSUnit(const Number&)` is `CSSUnitType::Number`
// unconditionally (CSSCalcTree.h:1008), so the unit is that function's answer rather than a
// guess, and the alternative is `Number` because `makeChild(Number { ... })` is what the C++
// builds.
static constexpr CSSCalcSwiftNumericResult resolvedNumber(double value)
{
    return { .value = value, .unitType = static_cast<uint16_t>(CSSUnitType::Number), .resolved = true, .alternative = CSSCalcSwiftAlternative::Number, .substituteFallback = false };
}

// A resolved canonical `<length>`. Both `simplify(Anchor&)` and `simplify(AnchorSize&)` end at
// `CanonicalDimension { .value = *result, .dimension = CanonicalDimension::Dimension::Length }`
// (`:1716`, `:1743`).
//
// The unit is `toCSSUnit(Dimension::Length)`, read out of the header (CSSCalcTree.h:992) rather
// than the literal `CSSUnitType::CSS_PX`: this value gets pushed back through `pushLeaf`, which
// calls `makeNumeric` again, and the round trip has to land on the same alternative. Writing `Px`
// here would duplicate "the canonical length unit is px" elsewhere in the program.
static constexpr CSSCalcSwiftNumericResult resolvedCanonicalLength(double value)
{
    return { .value = value, .unitType = static_cast<uint16_t>(toCSSUnit(CanonicalDimension::Dimension::Length)), .resolved = true, .alternative = CSSCalcSwiftAlternative::CanonicalDimension, .substituteFallback = false };
}

// The C++ reaches `std::exchange(node.fallback, { })`: there was a builder state and evaluation
// answered nothing, so the node is replaced by its fallback -- or, having none, is rebuilt with
// the property marked invalid at computed-value time. See
// `CSSCalcSwiftNumericResult::substituteFallback` for why this cannot be the same answer as
// `unresolvedNumber`.
static constexpr CSSCalcSwiftNumericResult substituteAnchorFallback { .value = 0, .unitType = static_cast<uint16_t>(CSSUnitType::Unknown), .resolved = false, .alternative = CSSCalcSwiftAlternative::Number, .substituteFallback = true };

CSSCalcSwiftNumericResult CSSCalcSwiftBuilder::resolveStyleCoupledValue(const Child& node) const noexcept
{
    // The guard `simplify(SiblingCount&)`, `(SiblingIndex&)` and `(Random&)` all open with (`:528`,
    // `:538`, `:1352`). For `random()` it runs deliberately before the sharing is looked at, so a
    // `fixed` value that needs neither conversion data nor a builder state still answers nothing
    // without them -- hoisting the fixed arm above this would fold `random(fixed 0.5, 1px, 3px)` in
    // a context where the C++ leaves it alone.
    if (!m_options->conversionData || !m_options->conversionData->styleBuilderState())
        return unresolvedNumber;

    // `protect(...)` exactly as `:534`, `:543` and `:1387` write it, matching the checked access, not
    // just the same call.
    CheckedPtr builderState = protect(m_options->conversionData->styleBuilderState());

    // Dispatch comes from the node's own variant tag. `get_if` rather than `switchOn`, as
    // `childInSerializationOrder` uses it: three comparisons instead of a 41-alternative
    // instantiation. Any other alternative falls through to `unresolvedNumber` at the bottom -- a
    // contract violation, unreachable since this is only called from the three matching `fold` arms
    // -- so it's checked rather than asserted, falling back to the C++ path instead of reading the
    // wrong alternative.
    if (auto* random = get_if<IndirectNode<Random>>(&node)) {
        // `:1375`-`:1386`: a `fixed <number>` resolves here when it is a `Raw` and answers nothing when
        // it is a `Calc`, which needs full evaluation. Deliberately not routed through
        // `resolveRandomBaseValue` below, whose fixed arm would run `Style::toStyle` and evaluate
        // that `Calc` -- a value simplification is not entitled to.
        if (auto* sharingFixed = std::get_if<Random::SharingFixed>(&(*random)->sharing)) {
            return WTF::switchOn(sharingFixed->value,
                [](const CSS::Number<CSS::ClosedUnitRange>::Raw& raw) { return resolvedNumber(raw.value); },
                [](const CSS::Number<CSS::ClosedUnitRange>::Calc&) { return unresolvedNumber; }
            );
        }
        // `:1388`: every other sharing alternative resolves through the shared resolver, which is the
        // same function `evaluate(const IndirectNode<Random>&)` calls (CSSCalcTree+Evaluation.cpp:238),
        // so the two arms cannot disagree about which cache slot a key names.
        if (auto randomBaseValue = resolveRandomBaseValue((*random)->sharing, *builderState))
            return resolvedNumber(*randomBaseValue);
        return unresolvedNumber;
    }

    // The failure tail of both anchor functions, written once. `:1710`-`:1714` and `:1737`-`:1740`
    // are the same three lines twice in the C++, and this is the one place saying what an anchor
    // function does when evaluation answers nothing. See
    // `CSSCalcSwiftNumericResult::substituteFallback` for why the answer cannot be
    // `unresolvedNumber`.
    auto anchorEvaluationFailed = [&](bool hasFallback) {
        // https://drafts.csswg.org/css-anchor-position-1/#anchor-valid
        // "If any of these conditions are false, the anchor() function resolves to its specified
        // fallback value. If no fallback value is specified, it makes the declaration referencing it
        // invalid at computed-value time."
        //
        // The fallback is not touched here. `:1714` is `std::exchange(anchor.fallback, { })`, which
        // both reads and clears the fallback on the per-arm copy; this reports "substitute the
        // fallback" instead and mutates nothing, since the answer here is an operand pushed for the
        // fallback subtree rather than the fallback `Child` moved out of the node.
        if (!hasFallback)
            builderState->setCurrentPropertyInvalidAtComputedValueTime();
        return substituteAnchorFallback;
    };

    // `simplify(Anchor&)` and `simplify(AnchorSize&)`, through the SAME evaluation each of them
    // calls rather than through a restatement of it. What is left here is only the part that
    // differs: those two answer with a `Child` and mutate the node, and this answers with a POD and
    // does not, because the island is still folding the enclosing expression and needs the value.
    //
    // Placed above the element guard because neither requires an element --
    // `AnchorPositionEvaluator::evaluate` finds its own (`AnchorPositionEvaluator.cpp:897`) and
    // answers nothing when there is none.
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

    // The second guard, easy to miss: `:530` and `:540` require an element. `siblingCount()` on a
    // builder state with no element does not answer 0 -- it's simply not a question the C++ asks,
    // and the C++ returns `std::nullopt` so the function stays in the tree. Placed below the
    // `random()` branch because `simplify(Random&)` does not require an element; only the
    // `element-scoped` sharing alternatives do, and `resolveRandomBaseValue` checks that itself
    // (CSSCalcTree+Evaluation.cpp:242, :252).
    if (!builderState->element())
        return unresolvedNumber;

    // `simplify(SiblingCount&)` and `simplify(SiblingIndex&)` (`:527`-`:544`), whole. `siblingIndex()`
    // is 1-based; `siblingCount()` is a count. Dispatch is read directly from the node's variant
    // tag, so the two can never be swapped across the boundary.
    if (WTF::holdsAlternative<SiblingCount>(node))
        return resolvedNumber(static_cast<double>(builderState->siblingCount()));
    if (WTF::holdsAlternative<SiblingIndex>(node))
        return resolvedNumber(static_cast<double>(builderState->siblingIndex()));
    return unresolvedNumber;
}

CSSCalcSwiftNumericResult CSSCalcSwiftBuilder::resolveSymbol(uint16_t valueID, uint16_t unit) const noexcept
{
    // The same call `simplify(Symbol&)` makes at :521. An id and the node's unit are passed in; C++
    // owns the table, a `HashMap` on the options that is not reducible to anything that crosses.
    auto value = m_options->symbolTable.get(static_cast<CSSValueID>(valueID));
    if (!value) {
        // `std::nullopt` from the C++, which copies the `Symbol` through unchanged. Not a failure.
        return unresolvedNumber;
    }

    // The value from the table and the unit from the node -- `makeNumeric(value->value, root.unit)`
    // exactly. `value->unit`, the table's own unit, is deliberately not read: the C++ does not read
    // it either, and reading it here would diverge on any input whose two `HashMap`s disagree.
    auto leaf = makeNumeric(value->value, static_cast<CSSUnitType>(unit));

    // `makeNumeric` itself is called, not a restatement of its seventy cases. Its answer is read
    // back off the node it built -- the alternative index straight from the variant tag, the value
    // and unit through `toCSSUnit`, the same round trip `pushLeaf` makes in the other direction --
    // so there is no second place in the program that classifies a `CSSUnitType`. No allocation is
    // involved: all four numeric alternatives are stored inline in `Node`; only `IndirectNode`
    // operations are out-of-line.
    CSSCalcSwiftNumericResult out {
        .value = 0,
        .unitType = static_cast<uint16_t>(CSSUnitType::Unknown),
        .resolved = true,
        .alternative = static_cast<CSSCalcSwiftAlternative>(leaf.value.index()),
        // Never set by this lookup: only the two anchor functions have a fallback to substitute.
        // Written out explicitly rather than left to default-initialise, so it reads as a
        // statement rather than an omission.
        .substituteFallback = false,
    };
    WTF::switchOn(leaf,
        [&]<Numeric T>(const T& numeric) {
            out.value = numeric.value;
            out.unitType = static_cast<uint16_t>(toCSSUnit(numeric));
        },
        // Unreachable: `makeNumeric` returns one of the four numeric leaves for every input,
        // including the units it rejects, for which it asserts and returns `Number { 0 }`. Present
        // because `switchOn` over `Node` must be exhaustive, and it leaves `resolved` true with an
        // inert value rather than inventing a fifth outcome the C++ does not have.
        [&](const auto&) { }
    );
    return out;
}

CSSCalcSwiftNumericResult CSSCalcSwiftBuilder::resolveRelativeLength(double value, uint16_t unitType) const noexcept
{
    // `canonicalize`'s `tryMakeCanonical` (`:181`-`:187`), and only that. The other twenty-eight of
    // its seventy cases are decided in Swift -- see `canonicalizedDimension` in
    // CSSCalcSimplificationSwift.swift -- so what is left here is the one thing that cannot cross:
    // `Style::resolveLength` needs a `CSSToLengthConversionData`, carrying a style, a realised font
    // cascade and a viewport.
    //
    // Which forty-two units reach this is never named here: the `switch` names the twenty-eight it
    // decides and this is its `default` arm, so `CSS::toLengthUnit` remains the only statement of
    // that membership set.
    //
    // Both optionals are checked. `canonicalize` writes `*CSS::toLengthUnit(root.unit)` (`:245`),
    // sound there only because the surrounding `switch` already established that `root.unit` is
    // one of the forty-two; here the unit arrives as a `uint16_t` across the boundary with no such
    // guarantee, so an unchecked dereference would be UB on a constructible input. This reports
    // "no answer" instead -- the dimension stays as it is.
    //
    // An `if` with an initializer, the resolved case first, the unresolved one as the fallthrough.
    // `resolvedCanonicalLength` is that literal, written once: a canonical `CSSUnitType` rather
    // than a `CanonicalDimension::Dimension`, so the reverse mapping stays `makeNumeric`'s and
    // `Dimension` never crosses; and it calls `toCSSUnit` rather than writing `CSSUnitType::Px` out,
    // so there is no second place saying a resolved length is measured in pixels.
    if (auto lengthUnit = CSS::toLengthUnit(static_cast<CSSUnitType>(unitType)); lengthUnit && m_options->conversionData)
        return resolvedCanonicalLength(Style::resolveLength(value, *lengthUnit, *m_options->conversionData));
    return unresolvedNumber;
}

#if ENABLE(CSS_TOKENIZER_SWIFT_BRIDGE)
// Test-only, and compiled out otherwise so the production path pays no load for them. Same set and
// same reasons as CSSCalcTree+Serialization.cpp:1277's.
//
// The four under `CSS_CALC_ISLAND_HARNESS_COUNTERS` are further separable from the other two: they
// are written on EVERY whole-tree call, where the decline counter is written only on a decline and
// the force-decline flag is only read. `CSSCalcTree+Simplification.h` says why that second gate
// exists and which configuration is which.
static std::atomic<bool> s_simplificationForceDecline;
static std::atomic<unsigned> s_simplificationDeclines;
#if CSS_CALC_ISLAND_HARNESS_COUNTERS
static std::atomic<uint32_t> s_simplificationLastNodeCount;
static std::atomic<uint64_t> s_simplificationLastKindMask;
static std::atomic<uint8_t> s_simplificationLastDeclineAlternative { 0xFF };
static std::atomic<uint64_t> s_simplificationSwiftCalls;
#endif

void webCoreCSSCalcSimplificationSetForceDecline(bool force)
{
    s_simplificationForceDecline.store(force, std::memory_order_relaxed);
}

unsigned webCoreCSSCalcSimplificationDeclineCount(void)
{
    return s_simplificationDeclines.load(std::memory_order_relaxed);
}

uint32_t webCoreCSSCalcSimplificationLastNodeCount(void)
{
#if CSS_CALC_ISLAND_HARNESS_COUNTERS
    return s_simplificationLastNodeCount.load(std::memory_order_relaxed);
#else
    // "No walk was recorded", not "a walk of zero nodes". The four accessors below answer this way
    // rather than disappearing so that a harness `dlsym`ing them still links; what makes the
    // configuration impossible to mistake is that an empty mask fails `simplifycheck`'s coverage
    // assertion, which is the assertion that would otherwise silently pass on a build that
    // measured nothing.
    return 0;
#endif
}

uint64_t webCoreCSSCalcSimplificationLastKindMask(void)
{
#if CSS_CALC_ISLAND_HARNESS_COUNTERS
    return s_simplificationLastKindMask.load(std::memory_order_relaxed);
#else
    return 0;
#endif
}

uint8_t webCoreCSSCalcSimplificationLastDeclineAlternative(void)
{
#if CSS_CALC_ISLAND_HARNESS_COUNTERS
    return s_simplificationLastDeclineAlternative.load(std::memory_order_relaxed);
#else
    return 0xFF;
#endif
}

uint64_t webCoreCSSCalcSimplificationSwiftCallCount(void)
{
#if CSS_CALC_ISLAND_HARNESS_COUNTERS
    return s_simplificationSwiftCalls.load(std::memory_order_relaxed);
#else
    return 0;
#endif
}

// Per-primitive timing, to split the island's FIXED per-whole-tree cost between the read crossing
// and the construction upcalls. R144 left that term unattributed and it is the biggest one: an
// operator tree costs Swift 4,197 retired instructions against the C++ arm's 1,025, and no
// traversal-side fix touches it.
//
// Each case is paired with the C++ arm's equivalent for the SAME output, so the answer is a
// like-for-like per-primitive ratio and not a bare number. Lives here rather than in the bridge
// because `CSSCalcSwiftOperandStack` is defined in this file and a builder cannot be constructed
// without it; the fixture tree is built directly rather than parsed, for the same reason.
//
// `sink` is returned so no case can be optimised away.
uint64_t webCoreCSSCalcSimplificationPrimitiveBench(uint32_t which, uint32_t iterations)
{
    auto options = SimplificationOptions {
        .category = CSS::Category::Length,
        .range = CSS::All,
        .conversionData = std::nullopt,
        .symbolTable = { },
        .allowZeroValueLengthRemovalFromSum = false,
    };

    // A two-child Sum of units that cannot canonicalize without conversion data, so it survives as
    // an operator node -- the shape the ladder measures.
    auto makeFixture = [&] {
        Vector<Child> kids;
        kids.append(makeChild(NonCanonicalDimension { .value = 1, .unit = CSSUnitType::Em }));
        kids.append(makeChild(NonCanonicalDimension { .value = 2, .unit = CSSUnitType::Rem }));
        auto sum = Sum { Children { WTF::move(kids) } };
        auto type = toType(sum);
        return makeChild(WTF::move(sum), type.value_or(Type { }));
    };
    auto fixture = makeFixture();
    auto leafChild = makeChild(Number { .value = 1 });

    // HOISTED, and that correction matters. Constructing a `CSSCalcSwiftOperandStack` inside the
    // loop charges every iteration with the `Vector<Child>`'s first malloc and its free, which the
    // real path pays ONCE PER WHOLE TREE and not once per leaf. Measured that way `pushLeaf` came
    // out at 11.6x `makeChild`, and essentially all of it was the allocation. The stack is hoisted
    // here and shrunk (not freed) between iterations, so what is timed is a STEADY-STATE push.
    CSSCalcSwiftOperandStack hoisted;
    hoisted.value.reserveInitialCapacity(8);
    CSSCalcSwiftBuilder hoistedBuilder { hoisted, options };

    // A fixture that actually FOLDS, unlike the Em/Rem one above which survives as an operator:
    // `1 + 2 + (-4) + (1/5) + (2*3)`, all `Number`, which exercises the sum merge, the unary minus,
    // the reciprocal, the product fold and the leaves, and collapses to a single `Number` -- so the
    // two arms can be compared by VALUE and the timing is not the only thing measured.
    auto makeFoldFixture = [&] {
        auto negate = Negate { makeChild(Number { .value = 4 }) };
        auto invert = Invert { makeChild(Number { .value = 5 }) };
        Vector<Child> factors;
        factors.append(makeChild(Number { .value = 2 }));
        factors.append(makeChild(Number { .value = 3 }));
        auto product = Product { Children { WTF::move(factors) } };

        Vector<Child> kids;
        kids.append(makeChild(Number { .value = 1 }));
        kids.append(makeChild(Number { .value = 2 }));
        // The type is computed into a local BEFORE the move, never inline beside it: argument
        // evaluation order is unspecified, so `makeChild(WTF::move(x), toType(x))` can read a
        // moved-from node whose `UniqueRef` is already null. The Sum fixture above sequences them
        // the same way for the same reason.
        auto negateType = toType(negate).value_or(Type { });
        auto invertType = toType(invert).value_or(Type { });
        auto productType = toType(product).value_or(Type { });
        kids.append(makeChild(WTF::move(negate), negateType));
        kids.append(makeChild(WTF::move(invert), invertType));
        kids.append(makeChild(WTF::move(product), productType));
        auto sum = Sum { Children { WTF::move(kids) } };
        auto sumType = toType(sum).value_or(Type { });
        return makeChild(WTF::move(sum), sumType);
    };
    auto foldFixture = makeFoldFixture();

    // THE ORACLE, run once rather than per iteration. Without it cases 14 and 15 would report a
    // ratio between a real simplification and whatever the flat pass happens to do, and a pass that
    // skipped work would look like the win. `RELEASE_ASSERT`, so a shipping build fails too.
    if (which == 14 || which == 15) {
        auto cppRoot = copyAndSimplify(foldFixture, options);
        auto* cppNumber = get_if<Number>(&cppRoot);
        RELEASE_ASSERT(cppNumber);
        // `std::bit_cast`, not `memcpy`: WebKit builds with -Wunsafe-buffer-usage-in-libc-call.
        uint64_t cppBits = std::bit_cast<uint64_t>(cppNumber->value);
        uint64_t swiftBits = cssCalcFlatSimplifyProbeSwift(foldFixture, 1);
        RELEASE_ASSERT_WITH_MESSAGE(swiftBits == cppBits,
            "flat simplifier disagrees with the C++ arm on the fold fixture");
    }

    if (which == 14)
        return cssCalcFlatSimplifyProbeSwift(foldFixture, iterations);
    if (which == 15) {
        uint64_t sum = 0;
        for (uint32_t i = 0; i < iterations; ++i)
            sum += copyAndSimplify(foldFixture, options).index();
        return sum;
    }

    // R151 GATE 3's ORACLE, and the reason this gate is worth running at all: the fixture must
    // SURVIVE simplification as an operator node, which is the one shape gates 1 and 2 did not
    // cover. Three separate assertions, because each catches a different way the gate could pass
    // while measuring nothing:
    //
    //   1. the C++ answer is still a `Sum` -- if the fixture ever folded, emit would cost one
    //      `makeChild` and the row would silently become a second copy of gate 2;
    //   2. the Swift arm actually emitted -- the flat emit walk returns false rather than building
    //      something plausible, and a false would otherwise read as a very fast pass;
    //   3. the two trees are EQUAL BY VALUE, `Child::operator==`, which compares the stored
    //      `Type` and walks the children -- so a flat pass that skipped work cannot read as the
    //      win.
    //
    // Run once, on a throwaway stack, ahead of the timed loop. `RELEASE_ASSERT`, so a shipping
    // build fails too.
    if (which == 16) {
        auto cppRoot = copyAndSimplify(fixture, options);
        RELEASE_ASSERT_WITH_MESSAGE(WTF::holdsAlternative<IndirectNode<Sum>>(cppRoot),
            "R151 gate 3's fixture must survive simplification as an operator node");

        CSSCalcSwiftOperandStack oracleOperands;
        CSSCalcSwiftBuilder oracleBuilder { oracleOperands, options };
        RELEASE_ASSERT_WITH_MESSAGE(cssCalcFlatEmitProbeSwift(fixture, oracleBuilder, 1) == 1,
            "the flat emit path declined the surviving-operator fixture");
        RELEASE_ASSERT(oracleOperands.value.size() == 1);
        RELEASE_ASSERT_WITH_MESSAGE(oracleOperands.value[0] == cppRoot,
            "flat convert+simplify+emit disagrees with the C++ arm on the surviving-operator fixture");
    }

    // R151 PROBE, ahead of the loop deliberately: the gating number for flipping the calc tree to a
    // Swift representation is what one conversion costs with WARM buffers, and the Swift entry point
    // therefore runs the iteration loop itself. Read it against case 13, the C++ arm simplifying the
    // same fixture end to end, and against the `walk` coverage pre-pass this pass would subsume
    // (R144: 95.4 + 141.9N + 5.02N^2 instructions).
    if (which == 12)
        return cssCalcFlattenProbeSwift(fixture, iterations);

    // GATE 3: the whole flat pipeline -- convert, simplify, and EMIT a real `CSSCalc::Child` --
    // on the Em/Rem `Sum`, which survives as an operator node. The denominator is case 13, the
    // C++ arm's `copyAndSimplify` of the SAME fixture, so no new C++ arm is needed and the two
    // rows already sit in the same run.
    //
    // The builder is HOISTED for the reason case 3's operand stack is: constructing a
    // `CSSCalcSwiftOperandStack` inside the loop charges every iteration with the `Vector<Child>`'s
    // first malloc and its free, which the real path pays once per whole tree. `clearOperands`
    // shrinks rather than frees, so what is timed is a steady-state emit. Swift's own two flat
    // buffers are hoisted the same way, inside the Swift entry point, which is why the loop runs
    // there and not here.
    if (which == 16) {
        CSSCalcSwiftOperandStack emitOperands;
        emitOperands.value.reserveInitialCapacity(8);
        CSSCalcSwiftBuilder emitBuilder { emitOperands, options };
        return cssCalcFlatEmitProbeSwift(fixture, emitBuilder, iterations);
    }

    uint64_t sink = 0;
    for (uint32_t i = 0; i < iterations; ++i) {
        switch (which) {
        case 0: {  // READ: swiftNodeInfo() on a leaf -- the per-node read crossing.
            auto info = swiftNodeInfo(leafChild);
            sink += info.childCount + static_cast<uint32_t>(info.kind);
            break;
        }
        case 1: {  // READ: swiftNodeInfo() on the operator node.
            auto info = swiftNodeInfo(fixture);
            sink += info.childCount + static_cast<uint32_t>(info.kind);
            break;
        }
        case 2: {  // READ: the surviving child accessor -- `Child::operator[]` plus `swiftNodeInfo`.
            // NOT comparable with what this case measured before slice C2s. It used to route
            // through `swiftSerializationChildIndex`, which re-sorted a `Sum`'s children on every
            // access; that entry point is gone and Swift orders the children itself, so what is
            // left here is the borrow alone, spelled the way Swift spells it. Also not comparable
            // with what `childAt` measured before the handle went.
            sink += static_cast<uint32_t>(swiftNodeInfo(fixture[0]).kind);
            break;
        }
        case 3: {  // BUILD, Swift's route: one leaf onto the operand stack, steady state.
            sink += hoistedBuilder.pushLeaf(CSSCalcSwiftLeaf { .value = 1, .unitType = 0, .kind = 0, .percentHint = 0 }) ? 1 : 0;
            hoisted.value.shrink(0);
            break;
        }
        case 4: {  // BUILD, the C++ arm's route to the SAME leaf.
            auto built = makeChild(Number { .value = 1 });
            sink += built.index();
            break;
        }
        case 5: {  // BUILD, Swift's route: deep-copy an input subtree.
            CSSCalcSwiftOperandStack operands;
            CSSCalcSwiftBuilder builder { operands, options };
            builder.pushCopyOf(fixture);
            sink += operands.value.size();
            break;
        }
        case 6: {  // BUILD, the C++ arm's route to the SAME copy.
            auto copied = copy(fixture);
            sink += copied.index();
            break;
        }
        case 7: {  // BUILD, Swift's route: two leaves plus a generic reconstruction.
            CSSCalcSwiftOperandStack operands;
            CSSCalcSwiftBuilder builder { operands, options };
            builder.pushLeaf(CSSCalcSwiftLeaf { .value = 1, .unitType = 0, .kind = 0, .percentHint = 0 });
            builder.pushLeaf(CSSCalcSwiftLeaf { .value = 2, .unitType = 0, .kind = 0, .percentHint = 0 });
            sink += builder.rebuildFrom(fixture, 2) ? 1 : 0;
            break;
        }
        case 8: {  // BUILD, the C++ arm's route to the same two-child Sum.
            auto built = makeFixture();
            sink += built.index();
            break;
        }
        case 9: {  // BUILD: `makeNumeric` alone -- the unit-classification switch `pushLeaf` routes
                   // a Number through, re-deriving from `unitType` what Swift already stated in
                   // `kind`. Splits pushLeaf's cost from the operand-stack append below.
            auto built = makeNumeric(1, CSSUnitType::Number);
            sink += built.index();
            break;
        }
        case 10: {  // BUILD: the operand-stack append alone, steady state, no allocation.
            hoisted.value.append(makeChild(Number { .value = 1 }));
            sink += hoisted.value.size();
            hoisted.value.shrink(0);
            break;
        }
        case 11: {  // BUILD: the stack's CONSTRUCTION and destruction, once -- the per-whole-tree
                    // cost the hoisting above removes from cases 3 and 10.
            CSSCalcSwiftOperandStack fresh;
            fresh.value.append(makeChild(Number { .value = 1 }));
            sink += fresh.value.size();
            break;
        }
        case 17: {  // BUILD, Swift's route: the SAME two leaves and reconstruction as case 7, but over
                    // the HOISTED stack. Case 7 also constructs and destroys a fresh
                    // `CSSCalcSwiftOperandStack` (case 11 prices that alone), so case 7 minus case 8
                    // is an UPPER BOUND on `rebuildFrom` and not a measurement of it -- the 1396
                    // figure quoted in CSSCalcSwiftTypes.h came from there. Read this against case 18,
                    // which is the same thing without the reconstruction.
            hoistedBuilder.pushLeaf(CSSCalcSwiftLeaf { .value = 1, .unitType = 0, .kind = 0, .percentHint = 0 });
            hoistedBuilder.pushLeaf(CSSCalcSwiftLeaf { .value = 2, .unitType = 0, .kind = 0, .percentHint = 0 });
            sink += hoistedBuilder.rebuildFrom(fixture, 2) ? 1 : 0;
            hoisted.value.shrink(0);
            break;
        }
        case 18: {  // BUILD: case 17 WITHOUT the reconstruction. 17 minus 18 is `rebuildFrom`'s own
                    // cost -- its 41-way `switchOn`, its `WTF::apply` over the tuple conformance, the
                    // `Children` vector it allocates and the `makeChild` -- plus the difference
                    // between destroying one `Sum` over two leaves and destroying two loose leaves,
                    // which is one extra free. Still an upper bound, but a much tighter one, and the
                    // stack construction and the two `pushLeaf`s are gone from both sides.
            hoistedBuilder.pushLeaf(CSSCalcSwiftLeaf { .value = 1, .unitType = 0, .kind = 0, .percentHint = 0 });
            hoistedBuilder.pushLeaf(CSSCalcSwiftLeaf { .value = 2, .unitType = 0, .kind = 0, .percentHint = 0 });
            sink += hoisted.value.size();
            hoisted.value.shrink(0);
            break;
        }
        case 13: {  // The C++ arm simplifying the same fixture end to end -- the denominator case 12
                    // has to be read against, measured in the same loop rather than across runs.
            sink += copyAndSimplify(fixture, options).index();
            break;
        }
        default:
            return 0;
        }
    }
    return sink;
}
#endif

// Whether the island simplified: true leaves the new root already constructed in
// `operands.rootSlot`, false means "run your own simplifier". Nothing done here is observable in
// that case: the operand stack is the caller's local and is destroyed with it, which is what makes
// a whole-tree decline free of the truncation problem `serializationForCSS` has with a
// `StringBuilder`.
//
// The stack is the CALLER's, and the answer is a `bool` rather than a `std::optional<Tree>`,
// because every `Child` handover is a 41-way generic `mpark` visit that neither inlines nor
// specialises. Building a `Tree` here, moving it into the optional and moving that into the
// caller's return slot cost THREE such move-constructions and three matching destructions per
// simplification -- measured at 1072 of the 5651 profile samples of a single-node tree, 19% -- and
// the C++ arm's `Tree { .root = copyAndSimplify(tree.root, options), ... }` pays none of them,
// because the inner call's return slot IS the outer node's. The root slot takes the LAST of those
// away too: the finished root is constructed where the caller's `Tree` needs it, so the Swift path
// now moves nothing at all, matching the C++ arm exactly.
static bool trySimplifyWithSwiftIsland(const Tree& tree, const SimplificationOptions& options, CSSCalcSwiftOperandStack& operands)
{
    CSSCalcSwiftBuilder builder { operands, options };

    auto swiftOptions = swiftSimplificationOptions(options);

    auto result = cssCalcSimplifySwift(tree.root, builder, swiftOptions);

#if ENABLE(CSS_TOKENIZER_SWIFT_BRIDGE)
#if CSS_CALC_ISLAND_HARNESS_COUNTERS
    // THE ONLY INSTRUMENTATION ON THE TIMED PATH, which is why it has its own gate: one atomic RMW
    // and three relaxed stores, and an atomic RMW does not pipeline. Nothing here is read by
    // `calcbench`; it is the differential harness's self-report.
    s_simplificationSwiftCalls.fetch_add(1, std::memory_order_relaxed);
    s_simplificationLastNodeCount.store(result.nodeCount, std::memory_order_relaxed);
    s_simplificationLastKindMask.store(result.kindMask, std::memory_order_relaxed);
    // Recorded even when this simplified, where it is 0xFF: a simplified tree names no reason just
    // as a declined one does.
    s_simplificationLastDeclineAlternative.store(result.declineAlternative, std::memory_order_relaxed);
#endif
    if (s_simplificationForceDecline.load(std::memory_order_relaxed)) {
        s_simplificationDeclines.fetch_add(1, std::memory_order_relaxed);
        return false;
    }
#endif

    if (result.outcome != static_cast<uint8_t>(CSSCalcSwiftSimplificationOutcomeSimplified)) {
#if ENABLE(CSS_TOKENIZER_SWIFT_BRIDGE)
        s_simplificationDeclines.fetch_add(1, std::memory_order_relaxed);
#endif
        return false;
    }

    // Swift's other contract: a completed walk constructs the root in the root slot and leaves
    // nothing behind on the operand stack. Checked rather than asserted, so that a boundary that
    // came apart is a fallback to the C++ arm and not a crash or -- much worse -- a tree built from
    // whatever else was on the stack. A declined tree cannot reach here, so a still-non-null
    // `rootSlot` means the walk finished while leaving the caller's placeholder in place, which
    // would return `calc(0)` for every input.
    if (operands.rootSlot || !operands.value.isEmpty()) {
#if ENABLE(CSS_TOKENIZER_SWIFT_BRIDGE)
        s_simplificationDeclines.fetch_add(1, std::memory_order_relaxed);
#endif
        return false;
    }

    return true;
}

// MARK: Exposed interface

// The island's whole-tree call, with the finished root constructed straight into the `Tree` the
// caller asked for.
//
// THE ELISION CHAIN, which is the only reason a destination exists to hand over. `root` is this
// function's return object -- one `return` of one named local, so NRVO; the call is the prvalue
// initialiser of `Tree::root` below, which C++17 elides by guarantee; and `copyAndSimplify` returns
// that `Tree` by NRVO in turn. So `&root` here IS `Tree::root` in the storage the original caller
// provided, and the last construction the walk makes writes the root where it has to end up.
//
// The placeholder is here because `Tree` has no default constructor and so cannot hand out an
// uninitialised root slot; `constructOperand` says why its destructor is not run. Its cost is one
// store, against the ~52 retired instructions the move it replaces cost -- an out-of-line 41-way
// `mpark` visit to move the root off the operand stack and another to destroy the moved-from slot.
//
// On a DECLINE the placeholder (or, for the forced-decline benchmark hook, a perfectly good root
// nobody wants) is returned and destroyed by the caller. That path is 45 cases in 924951 and pays
// one ordinary `Child` destruction for the privilege.
static Child swiftSimplifiedRoot(const Tree& tree, const SimplificationOptions& options, bool& simplified)
{
    Child root = Number { .value = 0 };

    CSSCalcSwiftOperandStack operands { .rootSlot = &root };
    simplified = trySimplifyWithSwiftIsland(tree, options, operands);
    return root;
}

Tree copyAndSimplify(const Tree& tree, const SimplificationOptions& options, Simplifier simplifier)
{
    if (simplifier == Simplifier::Swift) {
        bool simplified = false;
        Tree result {
            .root = swiftSimplifiedRoot(tree, options, simplified),
            .type = tree.type,
            .stage = tree.stage,
            .requiresConversionData = tree.requiresConversionData,
        };
        if (simplified)
            return result;
    }

#if CSS_CALC_CPP_SIMPLIFIER_COMPILED_IN
    return Tree {
        .root = copyAndSimplify(tree.root, options),
        .type = tree.type,
        .stage = tree.stage,
        .requiresConversionData = tree.requiresConversionData,
    };
#else
    // With no C++ arm there is nowhere to fall back to, and `copyAndSimplify` has no failure
    // channel -- it returns a `Tree`, and every caller treats that as the answer. So a decline has
    // to stop rather than return the tree unsimplified, which would be a silently wrong computed
    // value rather than a missing one.
    //
    // This mode does not remove the 42 per-operation `simplify` overloads or the recursive
    // `copyAndSimplify(const Child&)`: callers outside this file reach them directly.
    RELEASE_ASSERT_NOT_REACHED_WITH_MESSAGE("the calc() simplification island declined a tree in a build with no C++ simplifier compiled in");
#endif
}

// MARK: - Can Simplify

// NOTE: This is a simple and conservative implementation of `canSimplify`. A more precise
// implementation is possible by utilizing the provided `SimplificationOptions` if that should be
// necessary.
//
// Split out of `canSimplify` below rather than left inline in its `else`, so the Swift arm is a
// named function with its own body and the two arms read as two implementations of one question.
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

bool canSimplify(const Tree& tree, const SimplificationOptions& options, Simplifier simplifier)
{
    // This predicate is very nearly vacuous as an oracle. The body above ignores `options` outright
    // and returns `false` for exactly three of `Node`'s 41 alternatives, so it is one bit per tree
    // and cannot be wrong about any tree whose root is an operator -- most trees that reach here.
    // `canSimplify(t) == false` must imply `copyAndSimplify(t) == t`, which the C++ satisfies only
    // because those three alternatives' `simplify` overloads are unconditional no-ops.
    //
    // No fallback on this arm, unlike `copyAndSimplify`: the Swift answer is total over the 41
    // alternatives -- a `switch` on a discriminant with no operand to fail on -- so there is no
    // decline to fall back from.
    if (simplifier == Simplifier::Swift)
        return cssCalcCanSimplifySwift(tree.root);

    return canSimplifyWithCpp(tree, options);
}

} // namespace CSSCalc
} // namespace WebCore
