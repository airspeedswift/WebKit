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
#include "CSSCalcTree+Serialization.h"

#include "AnchorPositionEvaluator.h"
#include "CSSCalcSwiftTypes.h"
#include "CSSCalcSymbolTable.h"
#include "CSSCalcTree+Traversal.h"
#include "CSSCalcTree.h"
#include "CSSMarkup.h"
#include "CSSPrimitiveNumericTypes+Serialization.h"
#include "CSSPrimitiveValue.h"
#include "CSSUnits.h"
// The entry points this file calls, and every other Swift boundary's types along with them --
// WebCoreSwift-Generated.h is module-scoped, so a translation unit that includes it must declare
// all of them. See WebCoreSwiftBoundaryTypes.h.
#if USE(SWIFT_CSS)
#include "WebCoreSwiftBoundaryTypes.h"
#endif
#include <atomic>
#include <limits>
#include <ranges>
#include <wtf/text/StringBuilder.h>

namespace WebCore {
namespace CSSCalc {

// The C++ serializer sits in three guarded regions, so that a build can compile it out entirely
// and let the compiler name whatever still needs it. See CSSCalcTree+Serialization.h for the guard
// and WebCore.xcconfig for the build setting. First region: the serialization state and the child
// sorting `serializeMathFunctionArguments` uses.
#if CSS_CALC_CPP_SERIALIZER_COMPILED_IN

struct SerializationState {
    enum class GroupingParenthesis {
        Omit,
        Include
    };

    ASCIILiteral openGroup() const { return groupingParenthesis == GroupingParenthesis::Omit ? ""_s : "("_s; }
    ASCIILiteral closeGroup() const { return groupingParenthesis == GroupingParenthesis::Omit ? ""_s : ")"_s; }

    GroupingParenthesis groupingParenthesis = GroupingParenthesis::Include;
    Stage stage = Stage::Specified;
    CSS::Range range = CSS::All;
    const CSS::SerializationContext& serializationContext;
};

struct ParenthesisSaver {
    ParenthesisSaver(SerializationState& state)
        : state { state }
        , savedGroupingParenthesis { state.groupingParenthesis }
    {
    }

    ~ParenthesisSaver()
    {
        state.groupingParenthesis = savedGroupingParenthesis;
    }

    SerializationState& state;
    SerializationState::GroupingParenthesis savedGroupingParenthesis;
};

// https://drafts.csswg.org/css-values-4/#serialize-a-math-function
static void serializeMathFunction(StringBuilder&, const Child&, SerializationState&);
static void serializeMathFunction(StringBuilder&, const Symbol&, SerializationState&);
static void serializeMathFunction(StringBuilder&, const SiblingCount&, SerializationState&);
static void serializeMathFunction(StringBuilder&, const SiblingIndex&, SerializationState&);
static void serializeMathFunction(StringBuilder&, const IndirectNode<Deg2Rad>&, SerializationState&);
template<Numeric Op> static void serializeMathFunction(StringBuilder&, const Op&, SerializationState&);
template<typename Op> static void serializeMathFunction(StringBuilder&, const IndirectNode<Op>&, SerializationState&);

static void serializeMathFunctionPrefix(StringBuilder&, const IndirectNode<Sum>&, SerializationState&);
static void serializeMathFunctionPrefix(StringBuilder&, const IndirectNode<Product>&, SerializationState&);
static void serializeMathFunctionPrefix(StringBuilder&, const IndirectNode<Negate>&, SerializationState&);
static void serializeMathFunctionPrefix(StringBuilder&, const IndirectNode<Invert>&, SerializationState&);
static void serializeMathFunctionPrefix(StringBuilder&, const IndirectNode<RoundNearest>&, SerializationState&);
static void serializeMathFunctionPrefix(StringBuilder&, const IndirectNode<RoundUp>&, SerializationState&);
static void serializeMathFunctionPrefix(StringBuilder&, const IndirectNode<RoundDown>&, SerializationState&);
static void serializeMathFunctionPrefix(StringBuilder&, const IndirectNode<RoundToZero>&, SerializationState&);
static void serializeMathFunctionPrefix(StringBuilder&, const IndirectNode<ProgressNoClamp>&, SerializationState&);
template<typename Op> static void serializeMathFunctionPrefix(StringBuilder&, const IndirectNode<Op>&, SerializationState&);

static void serializeMathFunctionArguments(StringBuilder&, const IndirectNode<Sum>&, SerializationState&);
static void serializeMathFunctionArguments(StringBuilder&, const IndirectNode<Product>&, SerializationState&);
static void serializeMathFunctionArguments(StringBuilder&, const IndirectNode<Random>&, SerializationState&);
static void serializeMathFunctionArguments(StringBuilder&, const IndirectNode<CalcMix>&, SerializationState&);
static void serializeMathFunctionArguments(StringBuilder&, const IndirectNode<Anchor>&, SerializationState&);
static void serializeMathFunctionArguments(StringBuilder&, const IndirectNode<AnchorSize>&, SerializationState&);
template<typename Op> static void serializeMathFunctionArguments(StringBuilder&, const IndirectNode<Op>&, SerializationState&);

void serializeWithoutOmittingPrefix(StringBuilder&, const Child&, SerializationState&);

// https://drafts.csswg.org/css-values-4/#serialize-a-calculation-tree
static void serializeCalculationTree(StringBuilder&, const Child&, SerializationState&);
static void serializeCalculationTree(StringBuilder&, const ChildOrNone&, SerializationState&);
static void serializeCalculationTree(StringBuilder&, const CSS::Keyword::None&, SerializationState&);
static void serializeCalculationTree(StringBuilder&, const Symbol&, SerializationState&);
static void serializeCalculationTree(StringBuilder&, const SiblingCount&, SerializationState&);
static void serializeCalculationTree(StringBuilder&, const SiblingIndex&, SerializationState&);
static void serializeCalculationTree(StringBuilder&, const IndirectNode<Sum>&, SerializationState&);
static void serializeCalculationTree(StringBuilder&, const IndirectNode<Product>&, SerializationState&);
static void serializeCalculationTree(StringBuilder&, const IndirectNode<Negate>&, SerializationState&);
static void serializeCalculationTree(StringBuilder&, const IndirectNode<Invert>&, SerializationState&);
static void serializeCalculationTree(StringBuilder&, const IndirectNode<Deg2Rad>&, SerializationState&);
template<Numeric Op> void serializeCalculationTree(StringBuilder&, const Op&, SerializationState&);
template<typename Op> static void serializeCalculationTree(StringBuilder&, const IndirectNode<Op>&, SerializationState&);

// MARK: Sorting

// Sort keys are assigned sequentially via __COUNTER__ rather than hand-numbered,
// so that adding, removing or reordering a case cannot accidentally collide with
// or skip a value (which is how 'vmax' came to share 'svb's key and skip its own).
// The base is captured once so the keys start at 0 regardless of any prior
// __COUNTER__ use in this translation unit.
static constexpr unsigned sortPriorityBase = __COUNTER__;
#define SORT_PRIORITY_NEXT (__COUNTER__ - sortPriorityBase - 1)

// Sentinels that sort after every real unit, independent of how many there are.
static constexpr unsigned errorSortPriority = std::numeric_limits<unsigned>::max() - 1;
static constexpr unsigned otherSortPriority = std::numeric_limits<unsigned>::max();

static unsigned NODELETE sortPriority(CSSUnitType unit)
{
    // Sort order: number, percentage, dimension (by unit, ordered ASCII case-insensitively), other.

    switch (unit) {
    // number
    case CSSUnitType::Number:
    case CSSUnitType::Integer:      return SORT_PRIORITY_NEXT;
    // percentage
    case CSSUnitType::Percentage:   return SORT_PRIORITY_NEXT;

    // dimension (by unit, ordered ASCII case-insensitively)
    case CSSUnitType::Cap:          return SORT_PRIORITY_NEXT;
    case CSSUnitType::Ch:           return SORT_PRIORITY_NEXT;
    case CSSUnitType::Cm:           return SORT_PRIORITY_NEXT;
    case CSSUnitType::Cqb:          return SORT_PRIORITY_NEXT;
    case CSSUnitType::Cqh:          return SORT_PRIORITY_NEXT;
    case CSSUnitType::Cqi:          return SORT_PRIORITY_NEXT;
    case CSSUnitType::Cqmax:        return SORT_PRIORITY_NEXT;
    case CSSUnitType::Cqmin:        return SORT_PRIORITY_NEXT;
    case CSSUnitType::Cqw:          return SORT_PRIORITY_NEXT;
    case CSSUnitType::Deg:          return SORT_PRIORITY_NEXT;
    case CSSUnitType::Dpcm:         return SORT_PRIORITY_NEXT;
    case CSSUnitType::Dpi:          return SORT_PRIORITY_NEXT;
    case CSSUnitType::Dppx:         return SORT_PRIORITY_NEXT;
    case CSSUnitType::Dvb:          return SORT_PRIORITY_NEXT;
    case CSSUnitType::Dvh:          return SORT_PRIORITY_NEXT;
    case CSSUnitType::Dvi:          return SORT_PRIORITY_NEXT;
    case CSSUnitType::Dvmax:        return SORT_PRIORITY_NEXT;
    case CSSUnitType::Dvmin:        return SORT_PRIORITY_NEXT;
    case CSSUnitType::Dvw:          return SORT_PRIORITY_NEXT;
    case CSSUnitType::Em:           return SORT_PRIORITY_NEXT;
    case CSSUnitType::Ex:           return SORT_PRIORITY_NEXT;
    case CSSUnitType::Fr:           return SORT_PRIORITY_NEXT;
    case CSSUnitType::Grad:         return SORT_PRIORITY_NEXT;
    case CSSUnitType::Hz:           return SORT_PRIORITY_NEXT;
    case CSSUnitType::Ic:           return SORT_PRIORITY_NEXT;
    case CSSUnitType::In:           return SORT_PRIORITY_NEXT;
    case CSSUnitType::Khz:          return SORT_PRIORITY_NEXT;
    case CSSUnitType::Lh:           return SORT_PRIORITY_NEXT;
    case CSSUnitType::Lvb:          return SORT_PRIORITY_NEXT;
    case CSSUnitType::Lvh:          return SORT_PRIORITY_NEXT;
    case CSSUnitType::Lvi:          return SORT_PRIORITY_NEXT;
    case CSSUnitType::Lvmax:        return SORT_PRIORITY_NEXT;
    case CSSUnitType::Lvmin:        return SORT_PRIORITY_NEXT;
    case CSSUnitType::Lvw:          return SORT_PRIORITY_NEXT;
    case CSSUnitType::Mm:           return SORT_PRIORITY_NEXT;
    case CSSUnitType::Ms:           return SORT_PRIORITY_NEXT;
    case CSSUnitType::Pc:           return SORT_PRIORITY_NEXT;
    case CSSUnitType::Pt:           return SORT_PRIORITY_NEXT;
    case CSSUnitType::Px:           return SORT_PRIORITY_NEXT;
    case CSSUnitType::Q:            return SORT_PRIORITY_NEXT;
    case CSSUnitType::Rad:          return SORT_PRIORITY_NEXT;
    case CSSUnitType::Rcap:         return SORT_PRIORITY_NEXT;
    case CSSUnitType::Rch:          return SORT_PRIORITY_NEXT;
    case CSSUnitType::Rem:          return SORT_PRIORITY_NEXT;
    case CSSUnitType::Rex:          return SORT_PRIORITY_NEXT;
    case CSSUnitType::Ric:          return SORT_PRIORITY_NEXT;
    case CSSUnitType::Rlh:          return SORT_PRIORITY_NEXT;
    case CSSUnitType::S:            return SORT_PRIORITY_NEXT;
    case CSSUnitType::Svb:          return SORT_PRIORITY_NEXT;
    case CSSUnitType::Svh:          return SORT_PRIORITY_NEXT;
    case CSSUnitType::Svi:          return SORT_PRIORITY_NEXT;
    case CSSUnitType::Svmax:        return SORT_PRIORITY_NEXT;
    case CSSUnitType::Svmin:        return SORT_PRIORITY_NEXT;
    case CSSUnitType::Svw:          return SORT_PRIORITY_NEXT;
    case CSSUnitType::Turn:         return SORT_PRIORITY_NEXT;
    case CSSUnitType::Vb:           return SORT_PRIORITY_NEXT;
    case CSSUnitType::Vh:           return SORT_PRIORITY_NEXT;
    case CSSUnitType::Vi:           return SORT_PRIORITY_NEXT;
    case CSSUnitType::Vmax:         return SORT_PRIORITY_NEXT;
    case CSSUnitType::Vmin:         return SORT_PRIORITY_NEXT;
    case CSSUnitType::Vw:           return SORT_PRIORITY_NEXT;
    case CSSUnitType::X:            return SORT_PRIORITY_NEXT;

    // Non-numeric types are not supported.
    case CSSUnitType::Calc:
    case CSSUnitType::CalcPercentageWithAngle:
    case CSSUnitType::CalcPercentageWithLength:
    case CSSUnitType::QuirkyEm:
    case CSSUnitType::Unknown:
        break;
    }

    ASSERT_NOT_REACHED();
    return errorSortPriority;
}

// How many distinct priorities the switch above assigns, and the number the Swift mirror is kept in
// step with. `CSSCalcSerializationSwift.swift` spells the same table by hand -- it has to, because an
// imported C++ scoped enum's `init?(rawValue:)` accepts any underlying value, so its switch needs a
// `default` and cannot be exhaustive the way this one is.
//
// That `default` is the hazard: a newly added `CSSUnitType` fails to compile here, which is loud,
// but falls into the Swift `default` and mis-orders a `Sum`, which is not. Adding a unit above moves
// this count and fails the assert, whose message names the file to update.
static constexpr unsigned sortPriorityCount = 64;
static_assert(SORT_PRIORITY_NEXT == sortPriorityCount,
    "a unit was added to or removed from sortPriority: update sortPriorityCount here and the mirrored table in CSSCalcSerializationSwift.swift");

#undef SORT_PRIORITY_NEXT

static unsigned sortPriority(const Child& child)
{
    // https://drafts.csswg.org/css-values-4/#sort-a-calculations-children

    return WTF::switchOn(child,
        []<Numeric T>(const T& root) -> unsigned {
            return sortPriority(toCSSUnit(root));
        },
        [](const auto&) -> unsigned {
            return otherSortPriority; // Sorts after every numeric unit, even the error case.
        }
    );
}

struct ChildRepresentation {
    // Offset in the operations `children` vector.
    size_t index;

    // Value used to order children during sort, based on unit.
    unsigned sortPriority;
};

static Vector<ChildRepresentation, 16> generateSortedChildrenMap(const Children& children)
{
    Vector<ChildRepresentation, 16> sortedChildrenMap;
    sortedChildrenMap.reserveInitialCapacity(children.size());

    for (size_t i = 0; i < children.size(); ++i)
        sortedChildrenMap.append(ChildRepresentation { .index = i, .sortPriority = sortPriority(children[i]) });

    std::ranges::stable_sort(sortedChildrenMap, { }, &ChildRepresentation::sortPriority);

    return sortedChildrenMap;
}

// Second region: the serializer proper, css-values-4 steps 1 to 7 for every node kind. One region
// with the sorting above, which has no caller outside it.

// MARK: Math Function
// https://drafts.csswg.org/css-values-4/#serialize-a-math-function

static double clampValue(double value, CSS::Range range)
{
    value = std::isnan(value) ? 0 : value;
    return std::clamp(value, range.min, range.max);
}

void serializeMathFunction(StringBuilder& builder, const Child& fn, SerializationState& state)
{
    WTF::switchOn(fn, [&builder, &state](const auto& root) { serializeMathFunction(builder, root, state); });
}

template<Numeric Op> void serializeMathFunction(StringBuilder& builder, const Op& fn, SerializationState& state)
{
    // 1. If the root of the calculation tree fn represents is a numeric value (number, percentage, or dimension), and the serialization being produced is of a computed value or later, then clamp the value to the range allowed for its context (if necessary), then serialize the value as normal and return the result.

    if (state.stage == Stage::Computed) {
        auto clampedFn = makeChildWithValueBasedOn(clampValue(fn.value, state.range), fn);
        serializeCalculationTree(builder, clampedFn, state);
        return;
    }

    // `CSS::SerializableNumber` serialization implements the appropriate logic for steps 2 & steps 3-5 for Numeric expressions.

    // 2. If fn represents an infinite or NaN value: let s be the string "calc(".
    // 2.1. Let s be the string "calc(".
    // 2.2. Serialize the keyword infinity, -infinity, or NaN, as appropriate to represent the value, and append it to s.
    // 2.3. If fn’s type is anything other than «[ ]» (empty, representing a <number>), append " * " to s. Create a numeric value in the canonical unit for fn’s type (such as px for <length>), with a value of 1. Serialize this numeric value and append it to s.

    // [...]

    // 3. If the calculation tree’s root node is a numeric value, or a calc-operator node, let s be a string initially containing "calc(".
    // 4. For each child of the root node, serialize the calculation tree. [...]
    // 5. Append ")" (close parenthesis) to s.

    builder.append("calc("_s);
    serializeCalculationTree(builder, fn, state);
    builder.append(')');
}

void serializeMathFunction(StringBuilder& builder, const Symbol& fn, SerializationState& state)
{
    builder.append("calc("_s);
    serializeCalculationTree(builder, fn, state);
    builder.append(')');
}

void serializeMathFunction(StringBuilder& builder, const SiblingCount& fn, SerializationState& state)
{
    serializeCalculationTree(builder, fn, state);
}

void serializeMathFunction(StringBuilder& builder, const SiblingIndex& fn, SerializationState& state)
{
    serializeCalculationTree(builder, fn, state);
}

template<typename Op> void serializeMathFunction(StringBuilder& builder, const IndirectNode<Op>& fn, SerializationState& state)
{
    // 3. If the calculation tree’s root node is a numeric value, or a calc-operator node, let s be a string initially containing "calc(".
    //
    //    Otherwise, let s be a string initially containing the name of the root node, lowercased (such as "sin" or "max"), followed by a "(" (open parenthesis).

    // Both clauses of step 3 are handle via the appropriate overloaded function.

    serializeMathFunctionPrefix(builder, fn, state);

    // 4. For each child of the root node, serialize the calculation tree. If a result of this serialization starts with a "(" (open parenthesis) and ends with a ")" (close parenthesis), remove those characters from the result. Concatenate all of the results using ", " (comma followed by space), then append the result to s.
    {
        ParenthesisSaver saver { state };
        state.groupingParenthesis = SerializationState::GroupingParenthesis::Omit;

        serializeMathFunctionArguments(builder, fn, state);
    }

    // 5. Append ")" (close parenthesis) to s.
    builder.append(')');
}


void serializeMathFunctionPrefix(StringBuilder& builder, const IndirectNode<Sum>&, SerializationState&)
{
    builder.append("calc("_s);
}

void serializeMathFunctionPrefix(StringBuilder& builder, const IndirectNode<Product>&, SerializationState&)
{
    builder.append("calc("_s);
}

void serializeMathFunctionPrefix(StringBuilder& builder, const IndirectNode<Negate>&, SerializationState&)
{
    builder.append("calc("_s);
}

void serializeMathFunctionPrefix(StringBuilder& builder, const IndirectNode<Invert>&, SerializationState&)
{
    builder.append("calc("_s);
}

void serializeMathFunctionPrefix(StringBuilder& builder, const IndirectNode<RoundNearest>&, SerializationState&)
{
    builder.append(nameLiteralForSerialization(CSSValueRound), '(', nameLiteralForSerialization(RoundNearest::id), ", "_s);
}

void serializeMathFunctionPrefix(StringBuilder& builder, const IndirectNode<RoundUp>&, SerializationState&)
{
    builder.append(nameLiteralForSerialization(CSSValueRound), '(', nameLiteralForSerialization(RoundUp::id), ", "_s);
}

void serializeMathFunctionPrefix(StringBuilder& builder, const IndirectNode<RoundDown>&, SerializationState&)
{
    builder.append(nameLiteralForSerialization(CSSValueRound), '(', nameLiteralForSerialization(RoundDown::id), ", "_s);
}

void serializeMathFunctionPrefix(StringBuilder& builder, const IndirectNode<RoundToZero>&, SerializationState&)
{
    builder.append(nameLiteralForSerialization(CSSValueRound), '(', nameLiteralForSerialization(RoundToZero::id), ", "_s);
}

void serializeMathFunctionPrefix(StringBuilder& builder, const IndirectNode<ProgressNoClamp>&, SerializationState&)
{
    builder.append(nameLiteralForSerialization(ProgressNoClamp::id), "(no-clamp "_s);
}

template<typename Op> void serializeMathFunctionPrefix(StringBuilder& builder, const IndirectNode<Op>&, SerializationState&)
{
    builder.append(nameLiteralForSerialization(Op::id), '(');
}

void serializeMathFunctionArguments(StringBuilder& builder, const IndirectNode<Sum>& fn, SerializationState& state)
{
    serializeCalculationTree(builder, fn, state);
}

void serializeMathFunctionArguments(StringBuilder& builder, const IndirectNode<Product>& fn, SerializationState& state)
{
    serializeCalculationTree(builder, fn, state);
}

void serializeMathFunctionArguments(StringBuilder& builder, const IndirectNode<Random>& fn, SerializationState& state)
{
    WTF::switchOn(fn->sharing,
        [&](const Random::SharingAuto&) {
            // `auto` serializes as omitted.
        },
        [&](const Random::Key& key) {
            bool wroteSomething = false;
            auto separate = [&] {
                if (wroteSomething)
                    builder.append(' ');
                wroteSomething = true;
            };
            if (key.name) {
                separate();
                CSS::serializationForCSS(builder, state.serializationContext, *key.name);
            }
            if (key.elementScoped) {
                separate();
                builder.append(nameLiteralForSerialization(CSSValueElementScoped));
            }
            if (key.propertyScoped) {
                separate();
                WTF::switchOn(*key.propertyScoped,
                    [&](const Random::Key::PropertyScoped&) {
                        builder.append(nameLiteralForSerialization(CSSValuePropertyScoped));
                    },
                    [&](const Random::Key::PropertyIndexScoped&) {
                        builder.append(nameLiteralForSerialization(CSSValuePropertyIndexScoped));
                    }
                );
            }
            // The parser never produces an empty <random-cache-key>.
            ASSERT(wroteSomething);
            builder.append(", "_s);
        },
        [&](const Random::SharingFixed& fixed) {
            builder.append(nameLiteralForSerialization(CSSValueFixed), ' ');
            CSS::serializationForCSS(builder, state.serializationContext, fixed.value);
            builder.append(", "_s);
        }
    );

    serializeCalculationTree(builder, fn->min, state);
    builder.append(", "_s);
    serializeCalculationTree(builder, fn->max, state);

    if (fn->step) {
        builder.append(", "_s);
        serializeCalculationTree(builder, *fn->step, state);
    }
}

void serializeMathFunctionArguments(StringBuilder& builder, const IndirectNode<CalcMix>& fn, SerializationState& state)
{
    auto separator = ""_s;
    for (const auto& item : fn->children) {
        builder.append(std::exchange(separator, ", "_s));
        serializeCalculationTree(builder, item.value, state);
        if (item.weight) {
            builder.append(' ');
            CSS::serializationForCSS(builder, state.serializationContext, *item.weight);
        }
    }
}

void serializeMathFunctionArguments(StringBuilder& builder, const IndirectNode<Anchor>& anchor, SerializationState& state)
{
    if (anchor->elementName) {
        CSS::serializationForCSS(builder, state.serializationContext, *anchor->elementName);
        builder.append(' ');
    }

    WTF::switchOn(anchor->side,
        [&](CSSValueID valueID) {
            builder.append(nameLiteralForSerialization(valueID));
        },
        [&](const Child& percentage) {
            // As anchor() is not actually a "math function", calc() can't be omitted in arguments.
            serializeWithoutOmittingPrefix(builder, percentage, state);
        }
    );

    if (anchor->fallback) {
        builder.append(", "_s);
        serializeWithoutOmittingPrefix(builder, *anchor->fallback, state);
    }
}

static void serializeAnchorSizeDimension(StringBuilder& builder, Style::AnchorSizeDimension dimension)
{
    switch (dimension) {
    case Style::AnchorSizeDimension::Width:
        builder.append("width"_s);
        break;
    case Style::AnchorSizeDimension::Height:
        builder.append("height"_s);
        break;
    case Style::AnchorSizeDimension::Block:
        builder.append("block"_s);
        break;
    case Style::AnchorSizeDimension::Inline:
        builder.append("inline"_s);
        break;
    case Style::AnchorSizeDimension::SelfBlock:
        builder.append("self-block"_s);
        break;
    case Style::AnchorSizeDimension::SelfInline:
        builder.append("self-inline"_s);
        break;
    }
}

void serializeMathFunctionArguments(StringBuilder& builder, const IndirectNode<AnchorSize>& anchorSize, SerializationState& state)
{
    if (anchorSize->elementName)
        CSS::serializationForCSS(builder, state.serializationContext, *anchorSize->elementName);

    if (anchorSize->dimension) {
        if (anchorSize->elementName)
            builder.append(' ');
        serializeAnchorSizeDimension(builder, *anchorSize->dimension);
    }

    if (anchorSize->fallback) {
        if (anchorSize->elementName || anchorSize->dimension)
            builder.append(", "_s);

        serializeWithoutOmittingPrefix(builder, *anchorSize->fallback, state);
    }
}

template<typename Op> void serializeMathFunctionArguments(StringBuilder& builder, const IndirectNode<Op>& fn, SerializationState& state)
{
    auto separator = ""_s;
    forAllChildren(*fn, WTF::makeVisitor(
        [&](const std::optional<Child>& root) {
            if (root) {
                builder.append(std::exchange(separator, ", "_s));
                serializeCalculationTree(builder, *root, state);
            }
        },
        [&](const CSS::CustomIdent& root) {
            if (!root.value.isNull()) {
                builder.append(std::exchange(separator, ", "_s));
                CSS::serializationForCSS(builder, state.serializationContext, root);
            }
        },
        [&](const auto& root) {
            builder.append(std::exchange(separator, ", "_s));
            serializeCalculationTree(builder, root, state);
        }
    ));
}

void serializeWithoutOmittingPrefix(StringBuilder& builder, const Child& child, SerializationState& state)
{
    WTF::switchOn(child,
        [&](Leaf auto& op) {
            serializeCalculationTree(builder, op, state);
        },
        [&](auto& op) {
            serializeMathFunction(builder, op, state);
        }
    );
}

// MARK: Calculation Tree
// https://drafts.csswg.org/css-values-4/#serialize-a-calculation-tree

void serializeCalculationTree(StringBuilder& builder, const Child& root, SerializationState& state)
{
    WTF::switchOn(root, [&builder, &state](const auto& root) { serializeCalculationTree(builder, root, state); });
}

void serializeCalculationTree(StringBuilder& builder, const ChildOrNone& root, SerializationState& state)
{
    WTF::switchOn(root, [&builder, &state](const auto& root) { serializeCalculationTree(builder, root, state); });
}

void serializeCalculationTree(StringBuilder& builder, const CSS::Keyword::None& root, SerializationState& state)
{
    CSS::serializationForCSS(builder, state.serializationContext, root);
}

template<Numeric Op> void serializeCalculationTree(StringBuilder& builder, const Op& root, SerializationState& state)
{
    // 2. If root is a numeric value, or a non-math function, serialize root per the normal rules for it and return the result.

    CSS::serializationForCSS(builder, state.serializationContext, CSS::SerializableNumber { root.value, unitTypeString(toCSSUnit(root)) });
}

void serializeCalculationTree(StringBuilder& builder, const Symbol& root, SerializationState&)
{
    // 2. If root is a numeric value, or a non-math function, serialize root per the normal rules for it and return the result.

    builder.append(nameLiteralForSerialization(root.id));
}

void serializeCalculationTree(StringBuilder& builder, const SiblingCount& root, SerializationState&)
{
    // 2. If root is a numeric value, or a non-math function, serialize root per the normal rules for it and return the result.

    builder.append(nameLiteralForSerialization(root.id), "()"_s);
}

void serializeCalculationTree(StringBuilder& builder, const SiblingIndex& root, SerializationState&)
{
    // 2. If root is a numeric value, or a non-math function, serialize root per the normal rules for it and return the result.

    builder.append(nameLiteralForSerialization(root.id), "()"_s);
}

void serializeCalculationTree(StringBuilder& builder, const IndirectNode<Sum>& root, SerializationState& state)
{
    ASSERT(!root->children.isEmpty());

    // 6. If root is a Sum node,

    // - let s be a string initially containing "(".
    builder.append(state.openGroup());

    // - Sort root’s children.

    // NOTE: Rather than actually sorting the children, which we can't because they are immutable, we generate
    // a map of offsets to sorted offsets we can use while iterating.
    auto sortedChildrenMap = generateSortedChildrenMap(root->children);

    {
        ParenthesisSaver saver { state };
        state.groupingParenthesis = SerializationState::GroupingParenthesis::Include;

        // - Serialize root’s first child, and append it to s.
        serializeCalculationTree(builder, root->children[sortedChildrenMap[0].index], state);

        // - For each child of root beyond the first:
        for (size_t i = 1; i < root->children.size(); ++i) {
            WTF::switchOn(root->children[sortedChildrenMap[i].index],
                [&builder, &state](const IndirectNode<Negate>& child) {
                    // 1. If child is a Negate node, append " - " to s, then serialize the Negate’s child and append the result to s.
                    builder.append(" - "_s);
                    serializeCalculationTree(builder, child->a, state);
                },
                [&builder, &state]<Numeric T>(const T& child) {
                    // 2. If child is a negative numeric value, append " - " to s, then serialize the negation of child as normal and append the result to s.
                    if (child.value < 0) {
                        builder.append(" - "_s);
                        serializeCalculationTree(builder, makeChildWithValueBasedOn(-child.value, child), state);
                        return;
                    }

                    // 3. Otherwise, append " + " to s, then serialize child and append the result to s.
                    builder.append(" + "_s);
                    serializeCalculationTree(builder, child, state);
                },
                [&builder, &state](const auto& child) {
                    // 3. Otherwise, append " + " to s, then serialize child and append the result to s.
                    builder.append(" + "_s);
                    serializeCalculationTree(builder, child, state);
                }
            );
        }
    }

    // - Finally, append ")" to s and return it.
    builder.append(state.closeGroup());
}

void serializeCalculationTree(StringBuilder& builder, const IndirectNode<Product>& root, SerializationState& state)
{
    ASSERT(!root->children.isEmpty());

    // 7. If root is a Product node,

    // - let s be a string initially containing "(".
    builder.append(state.openGroup());

    // - Sort root’s children.

    // NOTE: Rather than actually sorting the children, which we can't because they are immutable, we generate
    // a map of offsets to sorted offsets we can use while iterating.
    auto sortedChildrenMap = generateSortedChildrenMap(root->children);

    {
        ParenthesisSaver saver { state };
        state.groupingParenthesis = SerializationState::GroupingParenthesis::Include;

        // - Serialize root’s first child, and append it to s.
        serializeCalculationTree(builder, root->children[sortedChildrenMap[0].index], state);

        // - For each child of root beyond the first:
        for (size_t i = 1; i < root->children.size(); ++i) {
            WTF::switchOn(root->children[sortedChildrenMap[i].index],
                [&builder, &state](const IndirectNode<Invert>& child) {
                    // 1. If child is an Invert node, append " / " to s, then serialize the Invert’s child and append the result to s.
                    builder.append(" / "_s);
                    serializeCalculationTree(builder, child->a, state);
                },
                [&builder, &state](const auto& child) {
                    // 2. Otherwise, append " * " to s, then serialize child and append the result to s.
                    builder.append(" * "_s);
                    serializeCalculationTree(builder, child, state);
                }
            );
        }
    }

    // - Finally, append ")" to s and return it.
    builder.append(state.closeGroup());
}

void serializeCalculationTree(StringBuilder& builder, const IndirectNode<Negate>& root, SerializationState& state)
{
    // 4. If root is a Negate node,

    // - let s be a string initially containing "(-1 * ".
    builder.append(state.openGroup(), "-1 * "_s);

    {
        ParenthesisSaver saver { state };
        state.groupingParenthesis = SerializationState::GroupingParenthesis::Include;

        // - Serialize root’s child, and append it to s.
        serializeCalculationTree(builder, root->a, state);
    }

    // - Append ")" to s, then return it.
    builder.append(state.closeGroup());
}

void serializeCalculationTree(StringBuilder& builder, const IndirectNode<Invert>& root, SerializationState& state)
{
    // 5. If root is an Invert node,

    // - let s be a string initially containing "(1 / ".
    builder.append(state.openGroup(), "1 / "_s);

    {
        ParenthesisSaver saver { state };
        state.groupingParenthesis = SerializationState::GroupingParenthesis::Include;

        // - Serialize root’s child, and append it to s.
        serializeCalculationTree(builder, root->a, state);
    }

    // - Append ")" to s, then return it.
    builder.append(state.closeGroup());
}

void serializeCalculationTree(StringBuilder& builder, const IndirectNode<Deg2Rad>& root, SerializationState& state)
{
    // Deg2Rad is an implementation-only node inserted at parse time inside trig functions. It has
    // no CSS-level representation, so serialize it transparently by just serializing its child.
    serializeCalculationTree(builder, root->angle, state);
}

void serializeMathFunction(StringBuilder& builder, const IndirectNode<Deg2Rad>& root, SerializationState& state)
{
    // Deg2Rad has no CSS-level representation, so defer to the child.
    serializeMathFunction(builder, root->angle, state);
}

template<typename Op> void serializeCalculationTree(StringBuilder& builder, const IndirectNode<Op>& root, SerializationState& state)
{
    // 3. If root is anything but a Sum, Negate, Product, or Invert node, serialize a math function for the function corresponding to the node type, treating the node’s children as the function’s comma-separated calculation arguments, and return the result.
    serializeMathFunction(builder, root, state);
}

#endif // CSS_CALC_CPP_SERIALIZER_COMPILED_IN

// MARK: - Swift serialization support (CSSCalcSerializationSwift.swift)
#if USE(SWIFT_CSS)
//
// What C++ does here is small: answer six questions about a node, append five things to a builder,
// and hand the root over. Swift walks the `CSSCalc::Child` graph in place through these accessors,
// so there is no serialized copy to build and no buffer to own; output goes into the caller's
// `StringBuilder`, and number formatting and the CSSValueID name table are upcalls rather than
// duplicated tables.
//
// `formatCSSNumberValue` must stay in C++: Swift's `Double.description` is shortest-round-trip, a
// different algorithm from CSS number serialization. The two agree on common values but diverge
// on subnormals and 17-significant-digit values.

// The outcome numbering is declared in Swift and reaches C++ through the generated header. Pinned
// here so that reordering the Swift enum is a build failure rather than a silent reinterpretation
// of every calc() serialization: `declined` read as `serialized` would emit nothing at all for
// every math function on the page.
static_assert(!static_cast<uint8_t>(CSSCalcSwiftOutcomeSerialized));
static_assert(static_cast<uint8_t>(CSSCalcSwiftOutcomeDeclined) == 1);

// The direct `Child`-typed children of a node are `Child::childCount()` and `Child::operator[]`
// (CSSCalcTree.cpp). They answer for exactly the set `forAllChildNodes` yields, including the two
// alternatives whose `tuple_size` 0 makes it under-report them, and they do so in O(1) per access
// rather than by visiting every child. One definition of what a child is, on the type itself,
// reachable from Swift as well as from here.

// MARK: The operations this file serializes as plain math functions
//
// An allowlist, and the direction matters: these are the operations for which
// `serializeMathFunctionPrefix` and `serializeMathFunctionArguments` both resolve to their generic
// templates above, i.e. whose whole serialization is `nameLiteralForSerialization(Op::id)`, `(`,
// the arguments joined with `, `, `)`. An operation added to CSSCalcTree.h is not in this list, so
// it is handed to the C++ serializer until someone adds it here; a denylist would instead serialize
// a new function through the generic path and be wrong if that function needed a prefix or argument
// overload of its own.
//
// `round()`'s four strategies, `progress(no-clamp ...)`, `Sum`, `Product`, `Negate` and `Invert`
// are absent because they have prefix overloads; `Random`, `CalcMix`, `Anchor` and `AnchorSize`
// because their argument overloads are not a list of calculation trees; `Deg2Rad` because it has no
// CSS spelling at all.
template<typename T, typename... Ts> static constexpr bool isOneOf = (std::same_as<T, Ts> || ...);

template<typename Op> static constexpr bool isGenericSerializedFunction = isOneOf<Op,
    Min, Max, Mod, Rem, Sin, Cos, Tan, Asin, Acos, Atan, Atan2, Pow, Sqrt, Hypot, Log, Exp,
    Abs, Sign, Progress>;

template<typename Op> static constexpr bool isRoundingStrategy = isOneOf<Op,
    RoundNearest, RoundUp, RoundDown, RoundToZero>;

// Whether any of `Op`'s tuple elements is a `ChildOrNone`, the one argument shape a child count
// cannot describe: `forAllChildren` visits a bound holding `none` and the serializer writes `none`
// for it, while `forAllChildNodes`, which `Child::childCount()` uses, skips it entirely. `Clamp` is
// the only such operation, handled by kind rather than by count; this `static_assert` makes a
// second one a build failure rather than an argument silently dropped from a stylesheet.
template<typename Op> static constexpr bool hasChildOrNoneArgument = []<size_t... I>(std::index_sequence<I...>) {
    return (std::same_as<std::remove_cvref_t<std::tuple_element_t<I, Op>>, ChildOrNone> || ...);
}(std::make_index_sequence<std::tuple_size_v<Op>> { });

// 8 + 4 + 2 + 1 + 1 = 16 bytes, with no padding. A field that grows the struct trips this and has
// to justify moving the AArch64 return value out of registers.
static_assert(sizeof(CSSCalcSwiftNodeInfo) == 16);

CSSCalcSwiftNodeInfo swiftNodeInfo(const Child& node) noexcept
{
    // One `switchOn` over the 41-alternative Variant, answering every question about the node at
    // once, so a leaf costs one discriminant dispatch rather than one per field.
    CSSCalcSwiftNodeInfo out {
        .numericValue = 0,
        .childCount = 0,
        .valueID = static_cast<uint16_t>(CSSValueInvalid),
        .unitType = static_cast<uint8_t>(CSSUnitType::Unknown),
        .kind = CSSCalcSwiftNodeKind::Operation,
    };

    // `childCount` is filled inside this visit rather than by a trailing `node.childCount()` call,
    // which would be a second 41-alternative `WTF::switchOn` over a node whose concrete alternative
    // the visit already has in hand. The four leaf lambdas need do nothing: `childCount` starts at
    // 0 and `childNodeCountOf` is 0 for every `Leaf` by definition (CSSCalcTree+Traversal.h).
    //
    // `Anchor` and `AnchorSize` call `childCount()` anyway, because both declare `tuple_size` 0
    // (FIXME: webkit.org/b/280798) and `CSSCalcTree.cpp`'s `anchorChildren` answers for them by hand
    // from a `static` this file cannot see.
    auto countOf = [&](const auto& operation) {
        out.childCount = childNodeCountOf(*operation);
    };

    WTF::switchOn(node,
        [&]<Numeric T>(const T& leaf) {
            if constexpr (std::same_as<T, Number>)
                out.kind = CSSCalcSwiftNodeKind::Number;
            else if constexpr (std::same_as<T, Percentage>)
                out.kind = CSSCalcSwiftNodeKind::Percentage;
            else if constexpr (std::same_as<T, CanonicalDimension>)
                out.kind = CSSCalcSwiftNodeKind::CanonicalDimension;
            else
                out.kind = CSSCalcSwiftNodeKind::NonCanonicalDimension;
            out.numericValue = leaf.value;
            out.unitType = static_cast<uint8_t>(toCSSUnit(leaf));
        },
        [&](const Symbol& leaf) {
            out.kind = CSSCalcSwiftNodeKind::Symbol;
            out.valueID = static_cast<uint16_t>(leaf.id);
        },
        [&](const SiblingCount&) {
            out.kind = CSSCalcSwiftNodeKind::SiblingCount;
            out.valueID = static_cast<uint16_t>(SiblingCount::id);
        },
        [&](const SiblingIndex&) {
            out.kind = CSSCalcSwiftNodeKind::SiblingIndex;
            out.valueID = static_cast<uint16_t>(SiblingIndex::id);
        },
        // The four calc-operator nodes whose serialization is the grouping-parenthesis state machine.
        [&](const IndirectNode<Sum>& op) {
            out.kind = CSSCalcSwiftNodeKind::Sum;
            countOf(op);
        },
        [&](const IndirectNode<Product>& op) {
            out.kind = CSSCalcSwiftNodeKind::Product;
            countOf(op);
        },
        [&](const IndirectNode<Negate>& op) {
            out.kind = CSSCalcSwiftNodeKind::Negate;
            countOf(op);
        },
        [&](const IndirectNode<Invert>& op) {
            out.kind = CSSCalcSwiftNodeKind::Invert;
            countOf(op);
        },
        // No CSS-level spelling: `serializeCalculationTree` emits this node's child in its place.
        [&](const IndirectNode<Deg2Rad>& op) {
            out.kind = CSSCalcSwiftNodeKind::Transparent;
            countOf(op);
        },
        // These four each get their own kind because each has a different serialization shape and
        // a different set of non-tree arguments; `valueID` is the function's own name in all four,
        // exactly as for the generic ones, so none of them costs a name table on the Swift side.
        [&](const IndirectNode<Anchor>&) {
            out.kind = CSSCalcSwiftNodeKind::AnchorFunction;
            out.valueID = static_cast<uint16_t>(Anchor::id);
            out.childCount = static_cast<uint32_t>(node.childCount());
        },
        [&](const IndirectNode<AnchorSize>&) {
            out.kind = CSSCalcSwiftNodeKind::AnchorSizeFunction;
            out.valueID = static_cast<uint16_t>(AnchorSize::id);
            out.childCount = static_cast<uint32_t>(node.childCount());
        },
        // `clamp()`, and only because of its `none` bounds. `min` and `max` are `ChildOrNone`, so a
        // bound holding the keyword is an argument the serializer emits but not a child node the
        // walk can see: the kind carries it, and `childCount` stays the number of subtrees.
        // Simplification rewrites a `clamp()` with both bounds `none` to `val`, so that shape is
        // carried by its own kind rather than relied on being unreachable.
        [&](const IndirectNode<Clamp>& clamp) {
            out.valueID = static_cast<uint16_t>(Clamp::id);
            countOf(clamp);
            bool minIsNone = WTF::holdsAlternative<CSS::Keyword::None>(clamp->min);
            bool maxIsNone = WTF::holdsAlternative<CSS::Keyword::None>(clamp->max);
            if (minIsNone && maxIsNone)
                out.kind = CSSCalcSwiftNodeKind::ClampWithNoneMinimumAndMaximum;
            else if (minIsNone)
                out.kind = CSSCalcSwiftNodeKind::ClampWithNoneMinimum;
            else if (maxIsNone)
                out.kind = CSSCalcSwiftNodeKind::ClampWithNoneMaximum;
            else
                out.kind = CSSCalcSwiftNodeKind::Function;
        },
        // The two whose `serializeMathFunctionArguments` overload is not a list of calculation
        // trees: `Random`'s `<random-cache-key>` and `CalcMix`'s per-item weights. Both keep being
        // named explicitly rather than falling into the generic lambda below, so that the allowlist
        // there stays the only other thing that can hand a tree back.
        [&](const IndirectNode<Random>& op) {
            out.kind = CSSCalcSwiftNodeKind::RandomFunction;
            out.valueID = static_cast<uint16_t>(Random::id);
            countOf(op);
        },
        [&](const IndirectNode<CalcMix>& op) {
            out.kind = CSSCalcSwiftNodeKind::CalcMixFunction;
            out.valueID = static_cast<uint16_t>(CalcMix::id);
            countOf(op);
        },
        // Everything else, classified by the shape of its serialization rather than one case per
        // operation. These operations cost no name here or in Swift: `valueID` carries `Op::id` and
        // is handed back to `nameLiteralForSerialization`, generated from CSSValueKeywords.in, so
        // the keyword table is never duplicated.
        [&](const auto& operation) {
            using Op = std::remove_cvref_t<decltype(*operation)>;
            static_assert(!hasChildOrNoneArgument<Op>,
                "a second operation with a ChildOrNone argument needs its own kind the way Clamp has, "
                "or a `none` bound will be dropped from the serialization");
            countOf(operation);
            // One place sets `valueID`, because every kind below wants the same thing from it: the
            // operation's own `id`, which for `round()` is the rounding strategy (`nearest`, `up`,
            // `down`, `to-zero`) rather than the function name, since all four share the name and
            // differ only by the strategy.
            if constexpr (isRoundingStrategy<Op> || std::same_as<Op, ProgressNoClamp> || isGenericSerializedFunction<Op>) {
                out.valueID = static_cast<uint16_t>(Op::id);
                out.kind = isRoundingStrategy<Op> ? CSSCalcSwiftNodeKind::RoundFunction
                    : std::same_as<Op, ProgressNoClamp> ? CSSCalcSwiftNodeKind::ProgressNoClampFunction
                    : CSSCalcSwiftNodeKind::Function;
            } else {
                // `Operation` means "the Swift serializer has not been taught this operation", and its
                // only handling is to hand the tree to the C++ serializer, which the configuration
                // that compiles the C++ serializer out has not got. So an unclassified operation is a
                // build failure naming the operation, rather than a `RELEASE_ASSERT` that fires the
                // first time the new function appears in a stylesheet.
                //
                // This is also what makes `CSSCalcSwiftNodeKind::Operation` producerless, and that is
                // the whole justification for the Swift serializer's `.Operation` trap: it is
                // unreachable by construction, established at compile time, not by inspection of
                // producers. Every one of the 41 alternatives either has a lambda of its own above or
                // satisfies the condition on the line this `#else` belongs to.
                //
                // Outside CSS_CALC_CPP_SERIALIZER_COMPILED_IN, so the proof holds in every
                // configuration, not only the one without a C++ serializer.
                static_assert(isRoundingStrategy<Op> || std::same_as<Op, ProgressNoClamp> || isGenericSerializedFunction<Op>,
                    "an operation reached the generic classification with no kind of its own, and the Swift serializer cannot emit it. "
                    "Add it to `isGenericSerializedFunction` if its serialization is `name(args...)`, or give it its own kind and teach "
                    "CSSCalcSerializationSwift.swift, whichever is true of the new operation.");
                out.kind = CSSCalcSwiftNodeKind::Operation;
            }
        }
    );

    return out;
}

// The `<anchor-size>` dimension as a `CSSValueID`, so callers can hand it to
// `appendValueIDName` and the generated keyword table spells it.
//
// Deliberately not shared with `serializeAnchorSizeDimension` above, which keeps its own six
// hardcoded string literals: sharing one table would mean a wrong entry produces the same wrong
// output on both the Swift and C++ serialization paths, so a test comparing them could not
// catch it. Two independent spellings keep that comparison meaningful.
static CSSValueID anchorSizeDimensionValueID(Style::AnchorSizeDimension dimension)
{
    switch (dimension) {
    case Style::AnchorSizeDimension::Width:      return CSSValueWidth;
    case Style::AnchorSizeDimension::Height:     return CSSValueHeight;
    case Style::AnchorSizeDimension::Block:      return CSSValueBlock;
    case Style::AnchorSizeDimension::Inline:     return CSSValueInline;
    case Style::AnchorSizeDimension::SelfBlock:  return CSSValueSelfBlock;
    case Style::AnchorSizeDimension::SelfInline: return CSSValueSelfInline;
    }
    RELEASE_ASSERT_NOT_REACHED();
}

CSSCalcSwiftOperationInfo swiftOperationInfo(const Child& node) noexcept
{
    CSSCalcSwiftOperationInfo out {
        .valueID = static_cast<uint16_t>(CSSValueInvalid),
        .randomSharingIsKey = false,
        .randomSharingIsFixed = false,
        .randomKeyHasName = false,
        .randomKeyIsElementScoped = false,
        .randomKeyHasPropertyScope = false,
        .anchorSideIsKeyword = false,
        .hasElementName = false,
        .hasDimension = false,
        .hasFallback = false,
    };

    // `get_if` on the three alternatives that carry anything, rather than a `WTF::switchOn` over
    // all 41: the `switchOn` spelling instantiates its generic fallback once per alternative, ~22 KB
    // of code. `CalcMix` is absent because all it needs is its child count and its per-item weights,
    // and the weights are an upcall.
    if (auto* random = get_if<IndirectNode<Random>>(&node)) {
        WTF::switchOn((*random)->sharing,
            [&](const Random::SharingAuto&) {
                // Serializes as omitted; both flags stay false and nothing is written.
            },
            [&](const Random::Key& key) {
                out.randomSharingIsKey = true;
                out.randomKeyHasName = key.name.has_value();
                out.randomKeyIsElementScoped = key.elementScoped.has_value();
                if (key.propertyScoped) {
                    out.randomKeyHasPropertyScope = true;
                    out.valueID = static_cast<uint16_t>(WTF::switchOn(*key.propertyScoped,
                        [](const Random::Key::PropertyScoped&) { return CSSValuePropertyScoped; },
                        [](const Random::Key::PropertyIndexScoped&) { return CSSValuePropertyIndexScoped; }
                    ));
                }
            },
            [&](const Random::SharingFixed&) {
                out.randomSharingIsFixed = true;
            }
        );
        return out;
    }

    if (auto* anchor = get_if<IndirectNode<Anchor>>(&node)) {
        out.hasElementName = (*anchor)->elementName.has_value();
        out.hasFallback = (*anchor)->fallback.has_value();
        if (auto* side = get_if<CSSValueID>(&(*anchor)->side.value)) {
            out.anchorSideIsKeyword = true;
            out.valueID = static_cast<uint16_t>(*side);
        }
        return out;
    }

    if (auto* anchorSize = get_if<IndirectNode<AnchorSize>>(&node)) {
        out.hasElementName = (*anchorSize)->elementName.has_value();
        out.hasFallback = (*anchorSize)->fallback.has_value();
        if ((*anchorSize)->dimension) {
            out.hasDimension = true;
            out.valueID = static_cast<uint16_t>(anchorSizeDimensionValueID(*(*anchorSize)->dimension));
        }
        return out;
    }

    // Every other kind: this is not called for them, and an all-inert record is what would come
    // back if it ever were.
    return out;
}

void CSSCalcSwiftSink::appendLiteral(uint8_t literal) noexcept
{
    // Selected by name rather than by index, so the numbering `CSSCalcSwiftLiteral` declares in
    // Swift is never transcribed here: reordering those cases cannot change which spelling is
    // emitted, and adding one without teaching this switch is a `RELEASE_ASSERT_NOT_REACHED` rather
    // than a silently wrong stylesheet. Hence a switch rather than a table indexed by the raw value.
    switch (literal) {
    case CSSCalcSwiftLiteralCalcOpen:
        m_builder->append("calc("_s);
        return;
    case CSSCalcSwiftLiteralOpenParen:
        m_builder->append('(');
        return;
    case CSSCalcSwiftLiteralCloseParen:
        m_builder->append(')');
        return;
    case CSSCalcSwiftLiteralEmptyParens:
        m_builder->append("()"_s);
        return;
    case CSSCalcSwiftLiteralPlus:
        m_builder->append(" + "_s);
        return;
    case CSSCalcSwiftLiteralMinus:
        m_builder->append(" - "_s);
        return;
    case CSSCalcSwiftLiteralTimes:
        m_builder->append(" * "_s);
        return;
    case CSSCalcSwiftLiteralDividedBy:
        m_builder->append(" / "_s);
        return;
    case CSSCalcSwiftLiteralNegateOpen:
        m_builder->append("-1 * "_s);
        return;
    case CSSCalcSwiftLiteralInvertOpen:
        m_builder->append("1 / "_s);
        return;
    case CSSCalcSwiftLiteralCommaSpace:
        m_builder->append(", "_s);
        return;
    // `round(` is spelled through the generated name table rather than as the string "round", so
    // there is still exactly one place in the program that decides how CSSValueRound is written:
    // this is the same call the C++ rounding prefix makes.
    case CSSCalcSwiftLiteralRoundOpen:
        m_builder->append(nameLiteralForSerialization(CSSValueRound), '(');
        return;
    case CSSCalcSwiftLiteralNoClampOpen:
        m_builder->append("(no-clamp "_s);
        return;
    // `clamp()`'s `none` bound. The same call `serializeCalculationTree(CSS::Keyword::None)` makes:
    // `CSS::Keyword::None` is `Constant<CSSValueNone>`, whose `Serialize` specialization is exactly
    // `nameLiteralForSerialization(CSSValueNone)` (CSSValueTypes.h).
    case CSSCalcSwiftLiteralNoneKeyword:
        m_builder->append(nameLiteralForSerialization(CSSValueNone));
        return;
    // `element-scoped` and `fixed` are named through the generated table for the same reason
    // `round(` is: one place in the program decides how each keyword is written.
    case CSSCalcSwiftLiteralSpace:
        m_builder->append(' ');
        return;
    case CSSCalcSwiftLiteralRandomFixedPrefix:
        m_builder->append(nameLiteralForSerialization(CSSValueFixed), ' ');
        return;
    case CSSCalcSwiftLiteralElementScoped:
        m_builder->append(nameLiteralForSerialization(CSSValueElementScoped));
        return;
    }
    RELEASE_ASSERT_NOT_REACHED();
}

void CSSCalcSwiftSink::appendNumber(double value, uint8_t unitType) noexcept
{
    // The same call `serializeCalculationTree`'s Numeric overload makes, so both serializers share
    // one number-formatting implementation by construction rather than by comparison.
    CSS::serializationForCSS(*m_builder, *m_context, CSS::SerializableNumber { value, unitTypeString(static_cast<CSSUnitType>(unitType)) });
}

void CSSCalcSwiftSink::appendValueIDName(uint16_t valueID) noexcept
{
    m_builder->append(nameLiteralForSerialization(static_cast<CSSValueID>(valueID)));
}

void CSSCalcSwiftSink::appendOperationArgument(const Child& node, uint8_t part, uint32_t index) noexcept
{
    // Selected by name, like `appendLiteral`, so the numbering `CSSCalcSwiftOperationPart` declares
    // in Swift is never transcribed here.
    //
    // Every branch makes the same `CSS::serializationForCSS` call the C++ serializer makes for that
    // argument, over the same typed CSS value, so the two cannot disagree about how a dashed-ident
    // escapes or how a `<number [0,1]>` formats. That is why these are upcalls rather than doubles
    // and strings crossing the boundary.
    switch (part) {
    case CSSCalcSwiftOperationPartDashedIdent: {
        // `random()`'s `<random-cache-key>` name, or `anchor()`/`anchor-size()`'s
        // `<anchor-element>`. Which one is unambiguous from the node's own alternative, and this is
        // only asked when `swiftOperationInfo` said there is one.
        const CSS::CustomIdent* ident = nullptr;
        if (auto* random = get_if<IndirectNode<Random>>(&node)) {
            if (auto* key = get_if<Random::Key>(&(*random)->sharing))
                ident = key->name ? &*key->name : nullptr;
        } else if (auto* anchor = get_if<IndirectNode<Anchor>>(&node))
            ident = (*anchor)->elementName ? &*(*anchor)->elementName : nullptr;
        else if (auto* anchorSize = get_if<IndirectNode<AnchorSize>>(&node))
            ident = (*anchorSize)->elementName ? &*(*anchorSize)->elementName : nullptr;
        RELEASE_ASSERT(ident);
        CSS::serializationForCSS(*m_builder, *m_context, *ident);
        return;
    }
    case CSSCalcSwiftOperationPartRandomFixedValue: {
        auto* random = get_if<IndirectNode<Random>>(&node);
        RELEASE_ASSERT(random);
        auto* fixed = get_if<Random::SharingFixed>(&(*random)->sharing);
        RELEASE_ASSERT(fixed);
        CSS::serializationForCSS(*m_builder, *m_context, fixed->value);
        return;
    }
    case CSSCalcSwiftOperationPartCalcMixWeight: {
        // The one presence test that stays in C++: the weight is per item, so exposing it here
        // would need a per-index accessor beside the child index, for a value that has nowhere
        // else to be spelled anyway. The leading space belongs to the weight, exactly as in
        // `serializeMathFunctionArguments(IndirectNode<CalcMix>)`.
        auto* calcMix = get_if<IndirectNode<CalcMix>>(&node);
        RELEASE_ASSERT(calcMix);
        RELEASE_ASSERT(index < (*calcMix)->children.size());
        const auto& item = (*calcMix)->children[index];
        if (!item.weight)
            return;
        m_builder->append(' ');
        CSS::serializationForCSS(*m_builder, *m_context, *item.weight);
        return;
    }
    }
    RELEASE_ASSERT_NOT_REACHED();
}


#if !CSS_CALC_CPP_SERIALIZER_COMPILED_IN
// Whether the tree was serialized. Returns false to mean "run the C++ serializer", and in that case
// guarantees nothing was appended: the decision is made before anything is emitted, because a
// StringBuilder cannot be truncated back.
//
// `omitGroupingParenthesis` is the whole of the difference between the two entry points below, exactly
// as it is the whole of the difference between the two `SerializationState`s the C++ builds for them.
static bool trySerializeWithSwift(StringBuilder& builder, const Tree& tree, const SerializationOptions& options, bool omitGroupingParenthesis)
{
    CSSCalcSwiftSink sink { builder, options.serializationContext };
    // The stage and the range are the whole of `SerializationState` this cannot read for itself:
    // `Stage` is on the `Tree` and the range is on the options, while what is passed in is the root
    // `Child`. Two doubles rather than a `CSS::Range`, because `clampValue` reads `min` and `max`,
    // and the two `RangeParseTimeBehavior` members belong to the parser.
    auto result = cssCalcSerializeSwift(tree.root, sink, tree.stage == Stage::Computed, options.range.min, options.range.max, omitGroupingParenthesis);
    if (result.outcome != static_cast<uint8_t>(CSSCalcSwiftOutcomeSerialized))
        return false;
    return true;
}
#endif // !CSS_CALC_CPP_SERIALIZER_COMPILED_IN
#endif // USE(SWIFT_CSS)

// MARK: Exposed interface

void serializationForCSS(StringBuilder& builder, const Tree& tree, const SerializationOptions& options)
{
#if CSS_CALC_CPP_SERIALIZER_COMPILED_IN
    SerializationState state {
        .stage = tree.stage,
        .range = options.range,
        .serializationContext = options.serializationContext,
    };
    serializeMathFunction(builder, tree.root, state);
#else
    // `false`: a math function, so a calc-operator root is wrapped in `calc(`.
    if (trySerializeWithSwift(builder, tree, options, false))
        return;

    // `serializationForCSS` has no failure channel: it returns a `String` and every caller treats
    // that as the answer. Stopping here is preferable to returning a truncated `cssText` for every
    // math function on the page.
    //
    // The paths that reach here have no known producer: a childless `Sum`/`Product`, an `anchor()`
    // whose child count disagrees with its record, and the generic `Operation` fall-through.
    RELEASE_ASSERT_NOT_REACHED_WITH_MESSAGE("the Swift calc() serializer declined a tree");
#endif
}

String serializationForCSS(const Tree& tree, const SerializationOptions& options)
{
    StringBuilder builder;
    serializationForCSS(builder, tree, options);
    return builder.toString();
}

#if CSS_CALC_CPP_SERIALIZER_COMPILED_IN
void serializationForCSS(StringBuilder& builder, const Child& child, const SerializationOptions& options)
{
    SerializationState state {
        .range = options.range,
        .serializationContext = options.serializationContext,
    };
    serializeCalculationTree(builder, child, state);
}

String serializationForCSS(const Child& child, const SerializationOptions& options)
{
    StringBuilder builder;
    serializationForCSS(builder, child, options);
    return builder.toString();
}
#endif

void serializationForCSSAsFunctionArgument(StringBuilder& builder, const Tree& tree, const SerializationOptions& options)
{
    // `calc-size()`'s inner `<calc-sum>`, and the only caller of this entry point
    // (CSSCalcSizeFunction.cpp). The Swift serializer takes the same `Omit` the C++ state does, so
    // both serializers write this position identically.
#if CSS_CALC_CPP_SERIALIZER_COMPILED_IN
    SerializationState state {
        .groupingParenthesis = SerializationState::GroupingParenthesis::Omit,
        .stage = tree.stage,
        .range = options.range,
        .serializationContext = options.serializationContext,
    };
    serializeCalculationTree(builder, tree.root, state);
#else
    if (trySerializeWithSwift(builder, tree, options, true))
        return;

    // Same reasoning as `serializationForCSS` above: no failure channel. Both entry points share one
    // walk, so the trees handed back are the same ones.
    RELEASE_ASSERT_NOT_REACHED_WITH_MESSAGE("the Swift calc() serializer declined a calc-size() argument");
#endif
}

} // namespace CSSCalc
} // namespace WebCore
