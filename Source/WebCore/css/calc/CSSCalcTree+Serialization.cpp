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
// The island entry points this file calls, and every other island's boundary types along with
// them -- WebCoreSwift-Generated.h is module-scoped, so a translation unit that includes it must
// declare all of them. WebCoreSwiftBoundaryTypes.h says why, and is the one file an added island
// edits.
#include "WebCoreSwiftBoundaryTypes.h"
#include <atomic>
#include <limits>
#include <ranges>
#include <wtf/text/StringBuilder.h>

namespace WebCore {
namespace CSSCalc {

// REGION 1 of 3 of the C++ serializer, guarded so that a build can answer what is DELETABLE by
// making the compiler the oracle. See CSSCalcTree+Serialization.h for the mode and
// WebCore.xcconfig for why it is a build mode rather than an `nm` inspection.
//
// The sorting block below is deliberately OUTSIDE all three regions: `sortPriority` and
// `generateSortedChildrenMap` are called by the island's own bridge, from
// `childInSerializationOrder` at :1139. With the regions gone that is their ONLY caller -- the
// serializer's two uses are at :655 and :710, both inside region 2 -- so those 107 lines do not
// become deletable and instead get RECLASSIFIED: they stop being "the C++ serializer" and become
// "C++ the island calls". The ratio has to be reported on that basis as well as the added-lines
// basis, rather than left flattering.
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

#endif // CSS_CALC_CPP_SERIALIZER_COMPILED_IN

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

// REGION 2 of 3: the serializer proper, css-values-4 steps 1 to 7 for every node kind.
#if CSS_CALC_CPP_SERIALIZER_COMPILED_IN

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

// MARK: - The Swift calc serialization island (CSSCalcSerializationSwift.swift)
//
// Everything C++ still does for the island is here, and it is deliberately little: answer six
// questions about a node, append five things to a builder, and hand the root over. There is no
// representation to translate, because Swift walks the real `CSSCalc::Child` graph in place through
// these accessors rather than being given a serialized copy of it; there is no buffer to own,
// because the output goes into the caller's `StringBuilder`; and there is no table or algorithm
// duplicated on the Swift side, because number formatting and the CSSValueID name table are
// upcalls.
//
// That last point is the load-bearing one. `formatCSSNumberValue` MUST stay in C++: Swift's
// `Double.description` is shortest-round-trip and CSS number serialization is a different
// algorithm, so a Swift reimplementation would agree on every common value, pass all 211 calc
// tests in the WPT corpus, and diverge on subnormals and 17-significant-digit values. Nothing in
// this repository would have caught it.

// The outcome numbering is declared once, in Swift, and reaches C++ through the generated header.
// These pin it, so that a reordering of the Swift enum is a build failure here rather than a silent
// reinterpretation of every calc() serialization: `declined` read as `serialized` would emit
// nothing at all for every math function on the page.
static_assert(!static_cast<uint8_t>(CSSCalcSwiftOutcomeSerialized));
static_assert(static_cast<uint8_t>(CSSCalcSwiftOutcomeDeclined) == 1);

// Walks the direct `Child`-typed children of a node, whatever alternative it holds.
//
// `forAllChildNodes` already does this for an operation, and does it generically over the tuple
// conformance, so the 34 `IndirectNode<Op>` alternatives need no per-op code here. What it cannot
// be handed is a *leaf*: the `Child` overload at CSSCalcTree+Traversal.h:126 dereferences the
// alternative, which only `IndirectNode` supports, so the `requires` below is what makes one
// spelling serve all 41 alternatives.
//
// THE GAP IS CLOSED HERE, AND DELIBERATELY NOT AT ITS SOURCE. `Anchor` and `AnchorSize` declare
// `tuple_size` 0 (CSSCalcTree.h:1317, "FIXME (webkit.org/b/280798): make Anchor and AnchorSize
// tuple-like"), so `forAllChildNodes` reports no children for them even though an `Anchor` holds an
// `AnchorSide` and an optional fallback `Child`. Fixing the FIXME would be the tidier change and it
// is not this slice's to make: `forAllChildNodes` is what simplification, evaluation and the
// computed-style-dependency walk all traverse with, so giving those two children changes what every
// one of those callers sees, and this slice's differential only oracles serialization. Answering
// for them *here* confines the change to the boundary -- `childCount` and `childAt` become the
// truth on the Swift side and nothing else in the tree moves.
template<typename Functor> static void forEachChildNodeOfChild(const Child& node, const Functor& functor)
{
    if (auto* anchor = get_if<IndirectNode<Anchor>>(&node)) {
        // In serialization order: the `<anchor-side>` when it is a `<percentage>` subtree rather
        // than a keyword, then the fallback. `serializeMathFunctionArguments(IndirectNode<Anchor>)`
        // writes them in exactly that order.
        if (auto* side = get_if<Child>(&(*anchor)->side.value))
            functor(*side);
        if ((*anchor)->fallback)
            functor(*(*anchor)->fallback);
        return;
    }
    if (auto* anchorSize = get_if<IndirectNode<AnchorSize>>(&node)) {
        if ((*anchorSize)->fallback)
            functor(*(*anchorSize)->fallback);
        return;
    }

    WTF::switchOn(node, [&](const auto& alternative) {
        if constexpr (requires { *alternative; })
            forAllChildNodes(*alternative, functor);
    });
}

// Counts the direct `Child`-typed children. Shared by `info()` and `childAt()`.
static uint32_t childNodeCount(const Child& node)
{
    uint32_t count = 0;
    forEachChildNodeOfChild(node, [&](const Child&) { ++count; });
    return count;
}

// MARK: The operations the island serializes as plain math functions
//
// An ALLOWLIST, and the direction matters more than the contents. These are the operations for which
// `serializeMathFunctionPrefix` and `serializeMathFunctionArguments` both resolve to their *generic*
// templates above (`:398` and `:545`), i.e. whose whole serialization is
// `nameLiteralForSerialization(Op::id)`, `(`, the arguments joined with `, `, `)`. An operation added
// to CSSCalcTree.h is not in this list, so the island declines it until someone teaches it -- where a
// denylist would silently serialize a new function through the generic path and be wrong if the new
// function had a prefix or argument overload of its own.
//
// `round()`'s four strategies, `progress(no-clamp ...)`, `Sum`, `Product`, `Negate` and `Invert` are
// absent because they have prefix overloads; `Random`, `CalcMix`, `Anchor` and `AnchorSize` because
// they have argument overloads whose arguments are not a list of calculation trees; `Deg2Rad` because
// it has no CSS spelling at all.
template<typename T, typename... Ts> static constexpr bool isOneOf = (std::same_as<T, Ts> || ...);

template<typename Op> static constexpr bool isGenericSerializedFunction = isOneOf<Op,
    Min, Max, Mod, Rem, Sin, Cos, Tan, Asin, Acos, Atan, Atan2, Pow, Sqrt, Hypot, Log, Exp,
    Abs, Sign, Progress>;

template<typename Op> static constexpr bool isRoundingStrategy = isOneOf<Op,
    RoundNearest, RoundUp, RoundDown, RoundToZero>;

// Whether any of `Op`'s tuple elements is a `ChildOrNone`, which is the one argument shape a child
// COUNT cannot describe: `forAllChildren` visits a bound holding `none` and the serializer writes
// `none` for it, while `forAllChildNodes` -- what `childNodeCount` uses -- skips it entirely. `Clamp`
// is the only such operation, and the island handles it by *kind* rather than by count. This is the
// `static_assert` that makes a second one a build failure rather than an argument silently dropped
// from a stylesheet.
template<typename Op> static constexpr bool hasChildOrNoneArgument = []<size_t... I>(std::index_sequence<I...>) {
    return (std::same_as<std::remove_cvref_t<std::tuple_element_t<I, Op>>, ChildOrNone> || ...);
}(std::make_index_sequence<std::tuple_size_v<Op>> { });

CSSCalcSwiftNodeInfo CSSCalcSwiftNode::info() const
{
    // One `switchOn` over the 41-alternative Variant, answering every question at once. The five
    // separate accessors this replaced each ran their own, so a leaf cost up to five discriminant
    // dispatches to produce four fields that come from the same alternative.
    CSSCalcSwiftNodeInfo out {
        .numericValue = 0,
        .childCount = 0,
        .valueID = static_cast<uint16_t>(CSSValueInvalid),
        .unitType = static_cast<uint8_t>(CSSUnitType::Unknown),
        .kind = CSSCalcSwiftNodeKind::Operation,
    };

    WTF::switchOn(*m_node,
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
        // The four calc-operator nodes, which are the four whose serialization is the
        // grouping-parenthesis state machine and the four S1 absorbed.
        [&](const IndirectNode<Sum>&) { out.kind = CSSCalcSwiftNodeKind::Sum; },
        [&](const IndirectNode<Product>&) { out.kind = CSSCalcSwiftNodeKind::Product; },
        [&](const IndirectNode<Negate>&) { out.kind = CSSCalcSwiftNodeKind::Negate; },
        [&](const IndirectNode<Invert>&) { out.kind = CSSCalcSwiftNodeKind::Invert; },
        // No CSS-level spelling: `serializeCalculationTree` emits this node's child in its place.
        [&](const IndirectNode<Deg2Rad>&) { out.kind = CSSCalcSwiftNodeKind::Transparent; },
        // S3's four. Each is its own kind because each has a different serialization shape and a
        // different set of non-tree arguments; `valueID` is the function's own name in all four,
        // exactly as it is for the twenty-six generic ones, so absorbing them still costs no name
        // table on the Swift side.
        [&](const IndirectNode<Anchor>&) {
            out.kind = CSSCalcSwiftNodeKind::AnchorFunction;
            out.valueID = static_cast<uint16_t>(Anchor::id);
        },
        [&](const IndirectNode<AnchorSize>&) {
            out.kind = CSSCalcSwiftNodeKind::AnchorSizeFunction;
            out.valueID = static_cast<uint16_t>(AnchorSize::id);
        },
        // `clamp()`, and only because of its `none` bounds. `min` and `max` are `ChildOrNone`, so a
        // bound holding the keyword is an argument the serializer emits but not a child node the walk
        // can see -- the kind carries it, and `childCount` stays the number of subtrees. With both
        // bounds `none` the tree cannot reach here at all (`+Simplification.cpp:1007` rewrites it to
        // `val` whatever `val` is), and it declines rather than resting on that.
        [&](const IndirectNode<Clamp>& clamp) {
            out.valueID = static_cast<uint16_t>(Clamp::id);
            bool minIsNone = WTF::holdsAlternative<CSS::Keyword::None>(clamp->min);
            bool maxIsNone = WTF::holdsAlternative<CSS::Keyword::None>(clamp->max);
            if (minIsNone && maxIsNone)
                out.kind = CSSCalcSwiftNodeKind::Operation;
            else if (minIsNone)
                out.kind = CSSCalcSwiftNodeKind::ClampWithNoneMinimum;
            else if (maxIsNone)
                out.kind = CSSCalcSwiftNodeKind::ClampWithNoneMaximum;
            else
                out.kind = CSSCalcSwiftNodeKind::Function;
        },
        // The two whose `serializeMathFunctionArguments` overload is not a list of calculation
        // trees: `Random`'s `<random-cache-key>` and `CalcMix`'s per-item weights. Both are S3's,
        // and both keep being named explicitly rather than falling into the generic lambda below,
        // so that the allowlist there stays the only other thing that can decline.
        [&](const IndirectNode<Random>&) {
            out.kind = CSSCalcSwiftNodeKind::RandomFunction;
            out.valueID = static_cast<uint16_t>(Random::id);
        },
        [&](const IndirectNode<CalcMix>&) {
            out.kind = CSSCalcSwiftNodeKind::CalcMixFunction;
            out.valueID = static_cast<uint16_t>(CalcMix::id);
        },
        // Everything else, classified by the SHAPE of its serialization rather than one case per
        // operation. Twenty-six operations reach the island through these four lines, and none of
        // them costs a name here or in Swift: `valueID` carries `Op::id` and the island hands it back
        // to `nameLiteralForSerialization`, which is generated from CSSValueKeywords.in and is exactly
        // the kind of table this port may not transcribe.
        [&](const auto& operation) {
            using Op = std::remove_cvref_t<decltype(*operation)>;
            static_assert(!hasChildOrNoneArgument<Op>,
                "a second operation with a ChildOrNone argument needs its own kind the way Clamp has, "
                "or a `none` bound will be dropped from the serialization");
            // One place sets `valueID`, because every kind below wants the same thing from it: the
            // operation's own `id`, which for `round()` is the ROUNDING STRATEGY (`nearest`, `up`,
            // `down`, `to-zero`) rather than the function name, since all four share the name and
            // differ only by it. `+Serialization.cpp:373`-`:391`.
            if constexpr (isRoundingStrategy<Op> || std::same_as<Op, ProgressNoClamp> || isGenericSerializedFunction<Op>) {
                out.valueID = static_cast<uint16_t>(Op::id);
                out.kind = isRoundingStrategy<Op> ? CSSCalcSwiftNodeKind::RoundFunction
                    : std::same_as<Op, ProgressNoClamp> ? CSSCalcSwiftNodeKind::ProgressNoClampFunction
                    : CSSCalcSwiftNodeKind::Function;
            } else
                out.kind = CSSCalcSwiftNodeKind::Operation;
        }
    );

    out.childCount = childNodeCount(*m_node);
    return out;
}

// The `<anchor-size>` dimension as a `CSSValueID`, so the island can hand it back to
// `appendValueIDName` and the generated keyword table spells it.
//
// DELIBERATELY NOT SHARED with `serializeAnchorSizeDimension` above, which keeps its six hardcoded
// string literals. Rewriting that function in terms of this one would be the tidier code and it
// would make the differential vacuous: with both arms reading one table, a wrong entry produces the
// same wrong output on both sides and the comparison passes. Two independent spellings is what
// makes "`nameLiteralForSerialization(CSSValueSelfBlock)` is `self-block`" a thing the harness
// checks rather than a thing this comment asserts. The C++ literals go when the C++ arm goes.
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

CSSCalcSwiftOperationInfo CSSCalcSwiftNode::operationInfo() const
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
    // all 41, for the reason `childInSerializationOrder` records: the `switchOn` spelling
    // instantiates its generic fallback once per alternative and costs ~22 KB. `CalcMix` is absent
    // because everything it needs is its child count and its per-item weights, and the weights are
    // an upcall.
    if (auto* random = get_if<IndirectNode<Random>>(m_node)) {
        WTF::switchOn((*random)->sharing,
            [&](const Random::SharingAuto&) {
                // Serializes as omitted; both flags stay false and the island writes nothing.
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

    if (auto* anchor = get_if<IndirectNode<Anchor>>(m_node)) {
        out.hasElementName = (*anchor)->elementName.has_value();
        out.hasFallback = (*anchor)->fallback.has_value();
        if (auto* side = get_if<CSSValueID>(&(*anchor)->side.value)) {
            out.anchorSideIsKeyword = true;
            out.valueID = static_cast<uint16_t>(*side);
        }
        return out;
    }

    if (auto* anchorSize = get_if<IndirectNode<AnchorSize>>(m_node)) {
        out.hasElementName = (*anchorSize)->elementName.has_value();
        out.hasFallback = (*anchorSize)->fallback.has_value();
        if ((*anchorSize)->dimension) {
            out.hasDimension = true;
            out.valueID = static_cast<uint16_t>(anchorSizeDimensionValueID(*(*anchorSize)->dimension));
        }
        return out;
    }

    // Every other kind: the island does not call this, and an all-inert record is what it gets if
    // it ever does.
    return out;
}

// The children of `node` in the order the serializer must visit them.
//
// For `Sum` and `Product` that is the SORTED order, because css-values-4 steps 6 and 7 both begin
// "Sort root's children" and the key is `sortPriority` above -- a 60-case unit order generated with
// `__COUNTER__`. That table is exactly the kind of thing this port is not allowed to transcribe into
// Swift, so C++ answers in sorted order and the island only ever names a position. Every other kind
// answers in tree order, since no other kind sorts.
//
// `generateSortedChildrenMap` runs per access rather than once per node, which makes serializing an
// n-child Sum O(n^2 log n). Priced rather than assumed, for the reason CSSCalcSwiftTypes.h gives at
// `childAt`: real calc trees are a handful of nodes. Caching it would mean the boundary owning a
// buffer, which is the goop this design exists not to have.
//
// `get_if` rather than `WTF::switchOn` for the two-alternative test, and that is a MEASURED choice
// rather than a stylistic one. The `switchOn` spelling instantiates its generic fallback lambda once
// per alternative, and each copy re-enters `forEachChildNodeOfChild` and its own `switchOn`: the
// dispatcher came out at 10,252 instructions plus 38 leaf lambdas of 303 each, about 22 KB, against
// 302 instructions for the whole of S0's `childAt`. `get_if` tests two alternatives and shares one
// copy of the generic path.
static const Child* childInSerializationOrder(const Child& node, uint32_t index)
{
    const Children* sorts = nullptr;
    if (auto* sum = get_if<IndirectNode<Sum>>(&node))
        sorts = &(*sum)->children;
    else if (auto* product = get_if<IndirectNode<Product>>(&node))
        sorts = &(*product)->children;

    if (sorts) {
        auto sortedChildrenMap = generateSortedChildrenMap(*sorts);
        if (index >= sortedChildrenMap.size())
            return nullptr;
        return &(*sorts)[sortedChildrenMap[index].index];
    }

    const Child* found = nullptr;
    uint32_t current = 0;
    forEachChildNodeOfChild(node, [&](const Child& child) {
        if (current++ == index)
            found = &child;
    });
    return found;
}

CSSCalcSwiftNode CSSCalcSwiftNode::childAt(uint32_t index) const
{
    auto* found = childInSerializationOrder(*m_node, index);
    // Not a clamp and not a null return. The island only ever indexes below the `childCount` it was
    // just given, so reaching here means the two disagree, which would mean the tree changed under a
    // borrow -- and returning a default-constructed handle would turn that into a silent wrong
    // serialization instead of a stop.
    RELEASE_ASSERT(found);
    return CSSCalcSwiftNode { found };
}

void CSSCalcSwiftSink::appendLiteral(uint8_t literal)
{
    // Selected by NAME, not by index, so the numbering `CSSCalcSwiftLiteral` declares in Swift is
    // never transcribed here: reordering those cases cannot change which spelling is emitted, and
    // adding one without teaching this switch is a `RELEASE_ASSERT_NOT_REACHED` rather than a
    // silently wrong stylesheet. That is why this is a switch and not a table indexed by the raw
    // value. One line per case, matching `sortPriority` above.
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
    // there is still exactly one place in the program that decides how CSSValueRound is written --
    // this is the same call the C++ prefix at `:375` makes.
    case CSSCalcSwiftLiteralRoundOpen:  m_builder->append(nameLiteralForSerialization(CSSValueRound), '('); return;
    case CSSCalcSwiftLiteralNoClampOpen: m_builder->append("(no-clamp "_s); return;
    // `clamp()`'s `none` bound. The same call `serializeCalculationTree(CSS::Keyword::None)` makes:
    // `CSS::Keyword::None` is `Constant<CSSValueNone>`, whose `Serialize` specialization is exactly
    // `nameLiteralForSerialization(CSSValueNone)` (CSSValueTypes.h:178).
    case CSSCalcSwiftLiteralNoneKeyword: m_builder->append(nameLiteralForSerialization(CSSValueNone)); return;
    // S3's three. `element-scoped` and `fixed` are named through the generated table for the same
    // reason `round(` is: one place in the program decides how each keyword is written.
    case CSSCalcSwiftLiteralSpace: m_builder->append(' '); return;
    case CSSCalcSwiftLiteralRandomFixedPrefix: m_builder->append(nameLiteralForSerialization(CSSValueFixed), ' '); return;
    case CSSCalcSwiftLiteralElementScoped: m_builder->append(nameLiteralForSerialization(CSSValueElementScoped)); return;
    }
    RELEASE_ASSERT_NOT_REACHED();
}

void CSSCalcSwiftSink::appendNumber(double value, uint8_t unitType)
{
    // The same call the C++ arm makes at serializeCalculationTree's Numeric overload, so the two
    // arms share one number-formatting implementation by construction rather than by comparison.
    CSS::serializationForCSS(*m_builder, *m_context, CSS::SerializableNumber { value, unitTypeString(static_cast<CSSUnitType>(unitType)) });
}

void CSSCalcSwiftSink::appendValueIDName(uint16_t valueID)
{
    m_builder->append(nameLiteralForSerialization(static_cast<CSSValueID>(valueID)));
}

void CSSCalcSwiftSink::appendOperationArgument(const CSSCalcSwiftNode& node, uint8_t part, uint32_t index)
{
    // Selected by NAME, like `appendLiteral`, so the numbering `CSSCalcSwiftOperationPart` declares
    // in Swift is never transcribed here.
    //
    // Every branch makes the SAME `CSS::serializationForCSS` call the C++ arm makes for that
    // argument, over the same typed CSS value, so the two arms cannot disagree about how a
    // dashed-ident escapes or how a `<number [0,1]>` formats. That is the whole reason these are
    // upcalls rather than doubles and strings crossing the boundary.
    switch (part) {
    case CSSCalcSwiftOperationPartDashedIdent: {
        // `random()`'s `<random-cache-key>` name, or `anchor()`/`anchor-size()`'s
        // `<anchor-element>`. Which one is unambiguous from the node's own alternative, and the
        // island only asks when `operationInfo()` said there is one.
        const CSS::CustomIdent* ident = nullptr;
        if (auto* random = get_if<IndirectNode<Random>>(node.m_node)) {
            if (auto* key = get_if<Random::Key>(&(*random)->sharing))
                ident = key->name ? &*key->name : nullptr;
        } else if (auto* anchor = get_if<IndirectNode<Anchor>>(node.m_node))
            ident = (*anchor)->elementName ? &*(*anchor)->elementName : nullptr;
        else if (auto* anchorSize = get_if<IndirectNode<AnchorSize>>(node.m_node))
            ident = (*anchorSize)->elementName ? &*(*anchorSize)->elementName : nullptr;
        RELEASE_ASSERT(ident);
        CSS::serializationForCSS(*m_builder, *m_context, *ident);
        return;
    }
    case CSSCalcSwiftOperationPartRandomFixedValue: {
        auto* random = get_if<IndirectNode<Random>>(node.m_node);
        RELEASE_ASSERT(random);
        auto* fixed = get_if<Random::SharingFixed>(&(*random)->sharing);
        RELEASE_ASSERT(fixed);
        CSS::serializationForCSS(*m_builder, *m_context, fixed->value);
        return;
    }
    case CSSCalcSwiftOperationPartCalcMixWeight: {
        // The one presence test that stays in C++, and the reason is in CSSCalcSwiftTypes.h: the
        // weight is per ITEM, so hoisting it to the island would need a per-index accessor beside
        // `childAt` for a value the island cannot spell anyway. The leading space belongs to the
        // weight, exactly as it does in `serializeMathFunctionArguments(IndirectNode<CalcMix>)`.
        auto* calcMix = get_if<IndirectNode<CalcMix>>(node.m_node);
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

#if ENABLE(CSS_TOKENIZER_SWIFT_BRIDGE)
// Test-only, and compiled out otherwise so the production path pays no load for them.
//
// `s_forceDecline` makes the island decline every tree, which is the only way to exercise the C++
// fall-through *while the gate is on*. Without it that path is reachable only by input, and once
// S1 and S2 land it may not be reachable at all -- a path that is never executed is not a path
// that works.
//
// `s_declines` is what stops the differential passing vacuously. A decline is invisible in an
// output comparison, because the C++ output for a declined tree is the same C++ output the
// comparison already trusts; so a slice that silently declined everything would read as perfect
// agreement. `s_lastNodeCount` and `s_lastKindMask` are the other half of that: they prove the
// walk descended and say which kinds it reached, so "the island agreed" cannot mean "the island
// looked at the root and stopped".
static std::atomic<bool> s_forceDecline;
static std::atomic<unsigned> s_declines;
static std::atomic<uint32_t> s_lastNodeCount;
static std::atomic<uint32_t> s_lastKindMask;
static std::atomic<uint32_t> s_lastRootKind;
static std::atomic<uint64_t> s_swiftCalls;

void webCoreCSSCalcSerializationSetForceDecline(bool force)
{
    s_forceDecline.store(force, std::memory_order_relaxed);
}

unsigned webCoreCSSCalcSerializationDeclineCount(void)
{
    return s_declines.load(std::memory_order_relaxed);
}

uint32_t webCoreCSSCalcSerializationLastNodeCount(void)
{
    return s_lastNodeCount.load(std::memory_order_relaxed);
}

uint32_t webCoreCSSCalcSerializationLastKindMask(void)
{
    return s_lastKindMask.load(std::memory_order_relaxed);
}

uint32_t webCoreCSSCalcSerializationLastRootKind(void)
{
    return s_lastRootKind.load(std::memory_order_relaxed);
}

uint64_t webCoreCSSCalcSerializationSwiftCallCount(void)
{
    return s_swiftCalls.load(std::memory_order_relaxed);
}
#endif

// Whether the island serialized the tree. Returns false to mean "run your own serializer", and in
// that case guarantees nothing was appended: the island decides before it emits, because a
// StringBuilder cannot be truncated back.
static bool trySerializeWithSwiftIsland(StringBuilder& builder, const Tree& tree, const SerializationOptions& options)
{
    CSSCalcSwiftSink sink { builder, options.serializationContext };
    // The stage and the range are the whole of `SerializationState` the island cannot read for
    // itself: `Stage` is on the `Tree` and the range is on the options, while the handle it takes is
    // a cursor onto a `Child`. Two doubles rather than a `CSS::Range`, because `clampValue` reads
    // `min` and `max` and the two `RangeParseTimeBehavior` members are the parser's.
    auto result = cssCalcSerializeSwift(CSSCalcSwiftNode { &tree.root }, sink, tree.stage == Stage::Computed, options.range.min, options.range.max);

#if ENABLE(CSS_TOKENIZER_SWIFT_BRIDGE)
    s_swiftCalls.fetch_add(1, std::memory_order_relaxed);
    s_lastNodeCount.store(result.nodeCount, std::memory_order_relaxed);
    s_lastKindMask.store(result.kindMask, std::memory_order_relaxed);
    s_lastRootKind.store(static_cast<uint32_t>(CSSCalcSwiftNode { &tree.root }.info().kind), std::memory_order_relaxed);
    if (s_forceDecline.load(std::memory_order_relaxed)) {
        s_declines.fetch_add(1, std::memory_order_relaxed);
        return false;
    }
#endif

    if (result.outcome != static_cast<uint8_t>(CSSCalcSwiftOutcomeSerialized)) {
#if ENABLE(CSS_TOKENIZER_SWIFT_BRIDGE)
        s_declines.fetch_add(1, std::memory_order_relaxed);
#endif
        return false;
    }
    return true;
}

// MARK: Exposed interface

void serializationForCSS(StringBuilder& builder, const Tree& tree, const SerializationOptions& options, Serializer serializer)
{
    if (serializer == Serializer::Swift && trySerializeWithSwiftIsland(builder, tree, options))
        return;

    // REGION 3 of 3: the fallback itself, and the two `Child` entries that nothing calls.
    //
    // This is the region R107's `nm` criterion could never have accounted for, and the reason that
    // criterion is wrong: the code below is UNCONDITIONAL, so `serializeMathFunction` links into
    // every build whatever the island's coverage is, and its presence in a symbol table measures
    // the fallback decision rather than the port.
#if CSS_CALC_CPP_SERIALIZER_COMPILED_IN
    SerializationState state {
        .stage = tree.stage,
        .range = options.range,
        .serializationContext = options.serializationContext,
    };
    serializeMathFunction(builder, tree.root, state);
#else
    // With no C++ serializer there is nowhere to fall back to, and `serializationForCSS` has no
    // failure channel -- it returns a `String`, and every caller treats that as the answer. So a
    // decline has to stop rather than return a truncated `cssText`, which is the same trade the
    // tokenizer island took when it dropped its fallback: a stop is recoverable evidence, a
    // silently wrong serialization of every math function on the page is not.
    //
    // The island's remaining decline paths all have NO PRODUCER -- the root `Negate`/`Invert`
    // defect it declines rather than reproduces, a childless `Sum`/`Product`, an `anchor()` whose
    // child count disagrees with its record, and the `Operation` fall-through -- which is what
    // makes this mode buildable at all, and is a claim `calccheck` tests at 6,188 trees and 0
    // declines, on the arm that is not this build.
    RELEASE_ASSERT_NOT_REACHED_WITH_MESSAGE("the calc() island declined a tree in a build with no C++ serializer compiled in");
#endif
}

String serializationForCSS(const Tree& tree, const SerializationOptions& options, Serializer serializer)
{
    StringBuilder builder;
    serializationForCSS(builder, tree, options, serializer);
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

} // namespace CSSCalc
} // namespace WebCore
