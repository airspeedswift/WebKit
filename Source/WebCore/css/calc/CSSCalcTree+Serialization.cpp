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
// Swift walks its own `CalcNode` tree and calls back here for output: fixed spellings, numbers,
// keyword names, and the arguments the tree keeps as payloads (`random()` keys, `<anchor-element>`
// names, `calc-mix()` weights). Output goes into the caller's `StringBuilder`, and number formatting
// and the CSSValueID name table are upcalls rather than duplicated tables.
//
// `formatCSSNumberValue` must stay in C++: Swift's `Double.description` is shortest-round-trip, a
// different algorithm from CSS number serialization. The two agree on common values but diverge
// on subnormals and 17-significant-digit values.

// Pins `CSSCalcSwiftAlternative` to `Node`'s alternative order, in the nearest translation unit
// that can see both. `init?(rawValue:)` on an imported C++ enum never fails, so a renumbered
// alternative would reach Swift as a valid case and build a wrong node with no runtime check able
// to catch it. `WTF::alternativeIndexV` also rejects a type that appears twice in `Node` or not at
// all.
#define CSS_CALC_SWIFT_PIN_ALTERNATIVE(name, type) \
    static_assert(WTF::alternativeIndexV<type, Node> == static_cast<size_t>(CSSCalcSwiftAlternative::name), \
        "CSSCalcSwiftAlternative::" #name " is not Node's index for " #type);
CSS_CALC_SWIFT_FOR_EACH_ALTERNATIVE(CSS_CALC_SWIFT_PIN_ALTERNATIVE)
#undef CSS_CALC_SWIFT_PIN_ALTERNATIVE

// Makes an added alternative a build failure. `WTF::VariantSizeV`, not `std::variant_size_v`: WTF's `Variant` is an alias for `mpark::variant`,
// so the `std` spelling instantiates an undefined template.
static_assert(numberOfCSSCalcSwiftAlternatives == WTF::VariantSizeV<Node>);

static CSSCalcSwiftOperationInfo randomSharingInfo(const Random::Sharing& sharing)
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
    WTF::switchOn(sharing,
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

void CSSCalcSwiftSink::appendLiteral(uint8_t literal) noexcept
{
    // Selected by name rather than by index, so the numbering `CSSCalcSwiftLiteral` declares in
    // Swift is never transcribed here: reordering those cases cannot change which spelling is
    // emitted, and adding one without teaching this switch is a `RELEASE_ASSERT_NOT_REACHED` rather
    // than a silently wrong stylesheet. Hence a switch rather than a table indexed by the raw value.
    switch (literal) {
    case CSSCalcSwiftLiteralCalcOpen:   m_builder->append("calc("_s);  return;
    case CSSCalcSwiftLiteralOpenParen:  m_builder->append('(');        return;
    case CSSCalcSwiftLiteralCloseParen: m_builder->append(')');        return;
    case CSSCalcSwiftLiteralEmptyParens: m_builder->append("()"_s);    return;
    case CSSCalcSwiftLiteralPlus:       m_builder->append(" + "_s);    return;
    case CSSCalcSwiftLiteralMinus:      m_builder->append(" - "_s);    return;
    case CSSCalcSwiftLiteralTimes:      m_builder->append(" * "_s);    return;
    case CSSCalcSwiftLiteralDividedBy:  m_builder->append(" / "_s);    return;
    case CSSCalcSwiftLiteralNegateOpen: m_builder->append("-1 * "_s);  return;
    case CSSCalcSwiftLiteralInvertOpen: m_builder->append("1 / "_s);   return;
    case CSSCalcSwiftLiteralCommaSpace: m_builder->append(", "_s);     return;
    // `round(` is spelled through the generated name table rather than as the string "round", so
    // there is still exactly one place in the program that decides how CSSValueRound is written:
    // this is the same call the C++ rounding prefix makes.
    case CSSCalcSwiftLiteralRoundOpen:  m_builder->append(nameLiteralForSerialization(CSSValueRound), '('); return;
    case CSSCalcSwiftLiteralNoClampOpen: m_builder->append("(no-clamp "_s); return;
    // `clamp()`'s `none` bound. The same call `serializeCalculationTree(CSS::Keyword::None)` makes:
    // `CSS::Keyword::None` is `Constant<CSSValueNone>`, whose `Serialize` specialization is exactly
    // `nameLiteralForSerialization(CSSValueNone)` (CSSValueTypes.h).
    case CSSCalcSwiftLiteralNoneKeyword: m_builder->append(nameLiteralForSerialization(CSSValueNone)); return;
    // `element-scoped` and `fixed` are named through the generated table for the same reason
    // `round(` is: one place in the program decides how each keyword is written.
    case CSSCalcSwiftLiteralSpace: m_builder->append(' '); return;
    case CSSCalcSwiftLiteralRandomFixedPrefix: m_builder->append(nameLiteralForSerialization(CSSValueFixed), ' '); return;
    case CSSCalcSwiftLiteralElementScoped: m_builder->append(nameLiteralForSerialization(CSSValueElementScoped)); return;
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


CSSCalcSwiftOperationInfo CSSCalcSwiftSink::randomSharingInfo(uint32_t payload) const noexcept
{
    return CSSCalc::randomSharingInfo(storedPayload<Random::Sharing>(m_payloads, payload));
}

void CSSCalcSwiftSink::appendPayloadArgument(uint8_t part, uint32_t payload, double weight, bool present) noexcept
{
    // Every branch makes the same `CSS::serializationForCSS` call the C++ serializer makes for that
    // argument, over the same typed CSS value, so the two cannot disagree about how a dashed-ident
    // escapes or how a `<number [0,1]>` formats.
    switch (part) {
    case CSSCalcSwiftOperationPartDashedIdent: {
        RELEASE_ASSERT(m_payloads && payload < m_payloads->size());
        const CSS::CustomIdent* ident = nullptr;
        if (auto* sharing = get_if<Random::Sharing>(&(*m_payloads)[payload])) {
            auto* key = get_if<Random::Key>(sharing);
            ident = key && key->name ? &*key->name : nullptr;
        } else
            ident = &storedPayload<CSS::CustomIdent>(m_payloads, payload);
        RELEASE_ASSERT(ident);
        CSS::serializationForCSS(*m_builder, *m_context, *ident);
        return;
    }
    case CSSCalcSwiftOperationPartRandomFixedValue: {
        auto* fixed = get_if<Random::SharingFixed>(&storedPayload<Random::Sharing>(m_payloads, payload));
        RELEASE_ASSERT(fixed);
        CSS::serializationForCSS(*m_builder, *m_context, fixed->value);
        return;
    }
    case CSSCalcSwiftOperationPartCalcMixWeight:
        if (!present)
            return;
        m_builder->append(' ');
        if (payload != cssCalcSwiftFlatNoNode)
            CSS::serializationForCSS(*m_builder, *m_context, storedPayload<CalcMix::Item::Weight>(m_payloads, payload));
        else
            CSS::serializationForCSS(*m_builder, *m_context, CalcMix::Item::Weight { weight });
        return;
    }
    RELEASE_ASSERT_NOT_REACHED();
}

#if !CSS_CALC_CPP_SERIALIZER_COMPILED_IN
// Whether the tree was serialized. On false nothing was appended: the decision is made before
// anything is emitted, because a StringBuilder cannot be truncated back.
//
// `omitGroupingParenthesis` is the whole of the difference between the two entry points below, exactly
// as it is the whole of the difference between the two `SerializationState`s the C++ builds for them.
static bool trySerializeWithSwift(StringBuilder& builder, const Tree& tree, const SerializationOptions& options, bool omitGroupingParenthesis)
{
    CSSCalcSwiftSink sink { builder, options.serializationContext, tree.stored.payloads() };
    // The stage and the range are the whole of `SerializationState` this cannot read for itself:
    // `Stage` is on the `Tree` and the range is on the options, while what is passed in is the stored
    // root. Two doubles rather than a `CSS::Range`, because `clampValue` reads `min` and `max`,
    // and the two `RangeParseTimeBehavior` members belong to the parser.
    return cssCalcSerializeSwift(tree.stored.root(), sink, tree.stage == Stage::Computed, options.range.min, options.range.max, omitGroupingParenthesis);
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
    // The paths that reach here have no known producer: a childless `Sum`/`Product`, or an
    // alternative `CalcNode.info` has no kind for.
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

    // Same reasoning as `serializationForCSS` above: no failure channel.
    RELEASE_ASSERT_NOT_REACHED_WITH_MESSAGE("the Swift calc() serializer declined a calc-size() argument");
#endif
}

} // namespace CSSCalc
} // namespace WebCore
