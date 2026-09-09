/*
 * Copyright (C) 2026 Apple Inc. All rights reserved.
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
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

// Bridge for the Swift CSS tokenizer (CSSTokenizerSwift.swift).
//
// Exposes three things to TestWebKitAPI and the standalone harnesses, `extern "C"`
// so no header needs exporting:
//
//   1. comparison entries that build the whole CSSParserToken stream both ways in
//      one process and compare the tokens themselves — at either character width,
//      and with an observer wrapper attached;
//   2. benchmark entries that time a whole CSSTokenizer construction on one
//      scanner or the other, at either width;
//   3. diagnostics: the decline counter, the forced-decline switch for the
//      failure-reporting path, and the compile-time scanner choice.
//
// Every entry here is WEBCORE_EXPORT and this file is in WebCore's own sources with
// no `#if` guard, so it ships inside WebCore.framework: its size is interop cost,
// not test overhead.

#include "config.h"

// Off unless ENABLE_CSS_TOKENIZER_SWIFT_BRIDGE=1. Everything below is WEBCORE_EXPORT and
// exists only to validate the Swift tokenizer against the C++ scanner and to measure it,
// so it has no business in a shipping WebCore.framework. Switch it on with
// WK_ENABLE_CSS_TOKENIZER_SWIFT_BRIDGE=YES, which appends the define for both WebCore and
// TestWebKitAPI; the flag has to reach both, because TestWebKitAPI links these symbols.
#if ENABLE(CSS_TOKENIZER_SWIFT_BRIDGE)

#include "CSSParserObserver.h"
#include "CSSParserObserverWrapper.h"
#include "CSSParserContext.h"
#include "CSSParserFastPaths.h"
#include "CSSParserToken.h"
#include "CSSParserTokenRange.h"
#include "CSSCalcSwiftTypes.h"
#include "CSSCalcSymbolTable.h"
#include "CSSCalcSymbolsAllowed.h"
#include "CSSCalcTree+Copy.h"
#include "CSSCalcTree+Parser.h"
#include "CSSCalcTree+Serialization.h"
#include "CSSCalcTree+Simplification.h"
#include "CSSCalcTree.h"
#include "CSSPrimitiveNumericCategory.h"
#include "CSSToLengthConversionData.h"
#include "CSSPropertyParserState.h"
#include "StyleRule.h"
#include "CSSSerializationContext.h"
#include "CSSTokenizer.h"
#include "CSSTokenizerSwiftTypes.h"
// `FontCascade::metricsOfPrimaryFont` and `primaryFont` are declared `inline` in FontCascade.h and
// defined here, so a translation unit that calls either without this include fails
// -Werror,-Wundefined-inline rather than at link time. Needed by entry 10.
#include "FontCascadeInlines.h"
// For the calc simplification comparison's conversion-data axis: a `Style::ComputedStyle` at a
// chosen font size is the only way to prove `canonicalize` reads the conversion data rather than
// answering a constant.
#include "StyleComputedStyle.h"
#include "StyleComputedStyle+GettersInlines.h"
#include "StyleComputedStyle+SettersInlines.h"
// The builder-state fixture (conversion-data kinds 3 and 4). `Style::BuilderState` is required by
// `simplify(SiblingCount&)`, `simplify(SiblingIndex&)`, `simplify(Random&)`, `simplify(Anchor&)` and
// `simplify(AnchorSize&)`, and `BuilderContext` holds a non-null `const Ref<const Document>`, so a
// real `Document` is mandatory.
//
// Building one from nothing but a `Document` has WebCore precedent: five production sites already
// do it, e.g. CSSPropertyParserConsumer+Transform.cpp:432-433
// (`Style::BuilderState::create(dummyStyle, Style::BuilderContext { document })`) and
// StyleCustomPropertyRegistry.cpp:201-202. The construction recipe below follows TestWebKitAPI's,
// at Tests/WebCore/DocumentOrder.cpp:56-67.
#include "AnchorPositionEvaluator.h"
#include "CSSCalcRandomCachingKey.h"
#include "Document.h"
#include "DocumentInlines.h"
#include "ElementInlines.h"
#include "HTMLBodyElement.h"
#include "HTMLDivElement.h"
#include "HTMLHtmlElement.h"
#include "NodeInlines.h"
#include "ProcessWarming.h"
#include "Settings.h"
#include "StyleBuilderState.h"
// WebCoreSwift-Generated.h is module-scoped, so any translation unit that includes it must declare
// every Swift boundary type in the module, not just the ones this file calls.
// WebCoreSwiftBoundaryTypes.h states that requirement once.
#include "WebCoreSwiftBoundaryTypes.h"
#include <array>
#include <atomic>
#include <bit>
#include <cmath>
#include <limits>
#include <optional>
#include <wtf/NeverDestroyed.h>
#include <wtf/StdLibExtras.h>
#include <wtf/URL.h>
#include <wtf/text/Latin1Character.h>
#include <wtf/text/WTFString.h>

namespace WebCore {
namespace {

// A do-nothing observer, so a CSSParserObserverWrapper can be constructed and the
// offsets the tokenizer feeds it compared between the two paths. The parser is
// what would normally call these; the tokenizer only supplies offsets.
class NullCSSParserObserver final : public CSSParserObserver {
public:
    void startRuleHeader(StyleRuleType, unsigned) final { }
    void endRuleHeader(unsigned) final { }
    void observeSelector(unsigned, unsigned) final { }
    void startRuleBody(unsigned) final { }
    void endRuleBody(unsigned) final { }
    void markRuleBodyContainsImplicitlyNestedProperties() final { }
    void observeProperty(unsigned, unsigned, bool, bool) final { }
    void observeComment(unsigned, unsigned) final { }
};

// MARK: - Helpers for the calc serialization comparison entries below
//
// Declared in WebCore's own anonymous namespace rather than beside the entries they serve: those
// entries have `extern "C"` linkage, and a C-linkage function may not return a user-defined type
// (-Werror,-Wreturn-type-c-linkage rejects `const CSSParserContext&` and `ParsedCalc`).

// The categories to try, in order. A calc expression is only parseable in a context that admits
// its type -- `calc(1 + 2)` needs Number, `calc(1px + 1em)` needs Length -- so trying each in turn
// avoids skipping an expression just because it was handed the wrong context. Integer is first
// because it is the most restrictive.
constexpr std::array<WebCore::CSS::Category, 11> calcCategories {
    WebCore::CSS::Category::Integer,
    WebCore::CSS::Category::Number,
    WebCore::CSS::Category::Percentage,
    WebCore::CSS::Category::Length,
    WebCore::CSS::Category::Angle,
    WebCore::CSS::Category::Time,
    WebCore::CSS::Category::Frequency,
    WebCore::CSS::Category::Resolution,
    WebCore::CSS::Category::Flex,
    WebCore::CSS::Category::LengthPercentage,
    WebCore::CSS::Category::AnglePercentage,
};

// The parser context, built once. A `CSSParserContext` carries a URL and a settings snapshot, and
// construction-per-call would dominate a sweep that makes millions of calls. A function-local
// static rather than a global because WebCore links with -no_inits.
const CSSParserContext& calcParserContext()
{
    static NeverDestroyed<CSSParserContext> context = [] {
        CSSParserContext built { HTMLStandardMode };
        // Without this, `sibling-count()` and `sibling-index()` are rejected at
        // CSSCalcTree+Parser.cpp:1345, so the `SiblingCount` and `SiblingIndex` node kinds are
        // unreachable through this entry.
        built.cssTreeCountingFunctionsEnabled = true;
        // Without these two, `random()` and `calc-mix()` are rejected outright at
        // CSSCalcTree+Parser.cpp:663 and :933, making the `Random` and `CalcMix` alternatives
        // unreachable and the `Operation` node kind -- which covers exactly those two -- never produced.
        built.cssRandomFunctionEnabled = true;
        built.cssCalcMixEnabled = true;
        return built;
    }();
    return context.get();
}

// Symbols the calc parser will accept as unresolved `Symbol` leaves.
//
// Without a non-empty table the `Symbol` node kind is unreachable: a bare identifier inside calc()
// is only a symbol if the caller said so, and every other parse rejects it. These four are the
// relative-colour component symbols, matching the table CSSPropertyParserConsumer+Color.cpp:285
// builds. `symbolTable` is left empty on the simplification side, so the symbol stays unresolved
// and survives into the tree as a `Symbol` leaf.
CSSCalcSymbolsAllowed calcAllowedSymbols()
{
    return CSSCalcSymbolsAllowed {
        { CSSValueR, CSSUnitType::Number },
        { CSSValueG, CSSUnitType::Number },
        { CSSValueB, CSSUnitType::Number },
        { CSSValueAlpha, CSSUnitType::Number },
    };
}

struct ParsedCalc {
    std::optional<CSSCalc::Tree> tree;
    WebCore::CSS::Category category { WebCore::CSS::Category::Number };
    WebCore::CSS::Range range { WebCore::CSS::All };
};

// Parses one expression, trying each category until one accepts it.
//
// `conversionData` is deliberately `std::nullopt`, matching the production parse at
// CSSUnevaluatedCalc.cpp:167: with no conversion data, simplification cannot fold length units
// into canonical form, so operator nodes survive into the tree instead of collapsing to a leaf.
// `parseSimplification` selects WHEN the parse simplifies -- see `CSSCalc::ParseSimplification`. It
// is a parameter rather than process state on purpose: a set/clear pair around a loop that returns
// from the middle leaves the flag set for every later case in the run, and that failure reads as a
// corpus problem rather than an invocation one.
ParsedCalc parseCalcExpression(const String& source, CSSCalc::ParseSimplification parseSimplification = CSSCalc::ParseSimplification::Eager)
{
    for (auto category : calcCategories) {
        CSSTokenizer tokenizer(source);
        auto range = tokenizer.tokenRange();
        if (range.atEnd())
            return { };

        // `currentRule` and `currentProperty` are both load-bearing, not boilerplate:
        // CSSCalcTree+Parser.cpp:1346-1349 rejects the tree-counting functions unless the rule is a
        // Style or Keyframe rule AND a real property is named. With the defaults
        // (`currentProperty == CSSPropertyInvalid`) those two node kinds never appear.
        auto parserState = WebCore::CSS::PropertyParserState {
            .context = calcParserContext(),
            .currentRule = StyleRuleType::Style,
            .currentProperty = CSSPropertyWidth,
        };
        auto parserOptions = CSSCalc::ParserOptions {
            .category = category,
            .range = WebCore::CSS::All,
            .allowedSymbols = calcAllowedSymbols(),
            // Both policies default to `Forbid`, and with the defaults `anchor()` and
            // `anchor-size()` are rejected outright at CSSCalcTree+Parser.cpp:1043 and :1136, making
            // the `Anchor` and `AnchorSize` alternatives unreachable through this entry. Those two
            // alternatives also report a child count of 0 regardless of contents (`tuple_size` 0,
            // webkit.org/b/280798), so they are exactly the ones that must not go untested.
            .propertyOptions = {
                .anchorPolicy = AnchorPolicy::Allow,
                .anchorSizePolicy = AnchorSizePolicy::Allow,
            },
        };
        auto simplificationOptions = CSSCalc::SimplificationOptions {
            .category = category,
            .range = WebCore::CSS::All,
            .conversionData = std::nullopt,
            .symbolTable = { },
            .allowZeroValueLengthRemovalFromSum = false,
        };

        auto tree = CSSCalc::parseAndSimplify(range, parserState, parserOptions, simplificationOptions, parseSimplification);
        // A trailing token means the expression was only partly consumed, which is not a parse.
        if (tree && range.atEnd())
            return { WTF::move(tree), category, WebCore::CSS::All };
    }
    return { };
}

// Copies a serialization out to the caller's buffer. Truncates rather than overflowing, and
// reports the true length so a truncated compare cannot read as agreement.
size_t copyOutSerialization(const String& text, char* out, size_t capacity)
{
    auto utf8 = text.utf8();
    auto span = utf8.span();
    if (out && capacity) {
        size_t copied = span.size() < capacity - 1 ? span.size() : capacity - 1;
        auto destination = unsafeMakeSpan(out, copied + 1);
        memcpySpan(destination.first(copied), span.first(copied));
        destination[copied] = '\0';
    }
    return span.size();
}

// A tree built directly rather than parsed, to reach a root shape no parse produces: a bare
// `Negate` or `Invert` at the root of a `Tree`.
//
// `serializeMathFunction` has explicit `serializeMathFunctionArguments` overloads for `Sum` and
// `Product` that route back into the calculation-tree serializer, and none for `Negate` or
// `Invert` (CSSCalcTree+Serialization.cpp:403-:411). A `Negate` root therefore takes the generic
// argument template at :545, which walks the node's single child and emits it with no prefix at
// all -- step 4's `-1 * ` is dropped, so the serialized text means a different number from the
// tree it came from. The same `Negate` node one level down inside a `Sum` does emit `-1 * `; only
// the root position is affected.
//
// The leaf is parsed rather than constructed so that its `Type` matches what the real parser
// would produce; only the operator node above it is built by hand.
std::optional<CSSCalc::Tree> constructRootShape(unsigned shape)
{
    auto parsed = parseCalcExpression("calc(1px)"_str);
    if (!parsed.tree)
        return std::nullopt;

    // `calc(1px)` does NOT survive as a `Sum` wrapping the leaf: `parseAndSimplify` folds the
    // one-child wrapper away and the root is the leaf itself, so this unwrap is inert today. It is
    // kept so that a future simplification change which stops folding cannot silently turn this
    // into a `Sum` shape.
    auto leaf = WTF::move(parsed.tree->root);
    if (auto* sum = get_if<CSSCalc::IndirectNode<CSSCalc::Sum>>(&leaf); sum && (*sum)->children.size() == 1)
        leaf = WTF::move((*sum)->children[0]);
    auto type = CSSCalc::getType(leaf);

    auto operatorNode = [&](CSSCalc::Child&& child) -> CSSCalc::Child {
        if (shape & 1)
            return CSSCalc::makeChild(CSSCalc::Invert { WTF::move(child) }, type);
        return CSSCalc::makeChild(CSSCalc::Negate { WTF::move(child) }, type);
    };

    auto root = operatorNode(WTF::move(leaf));
    if (shape >= 2) {
        Vector<CSSCalc::Child> children;
        children.append(WTF::move(root));
        root = CSSCalc::makeChild(CSSCalc::Sum { WTF::move(children) }, type);
    }

    return CSSCalc::Tree {
        .root = WTF::move(root),
        .type = type,
        .stage = CSSCalc::Stage::Specified,
    };
}

// MARK: - Helpers for the calc simplification comparison entries below
//
// Declared here rather than beside the entries for the same reason as the serialization helpers
// above: these return user-defined types, and a C-linkage function may not.
//
// Simplification is `Tree -> Tree`, unlike serialization's `Tree -> String`, so comparing two
// trees needs machinery a string comparison did not: a definition of equality, of what counts as
// NaN, and of which alternatives a tree contains. That is what the rest of this block provides.

// A deep, bitwise comparison of two trees.
//
// `Tree::operator==` is defaulted and therefore uses `double ==`, which is wrong in both
// directions here: too strict on NaN (`NaN != NaN`, so two correctly-NaN results compare
// unequal) and too weak on signed zero (`-0.0 == 0.0`, so a fold that normalizes the sign of zero
// -- which `abs`, `mod`, `round(to-zero)` and `sign` can all do -- would incorrectly pass).
// Serialization cannot distinguish a signed zero either, since `calc(-0)` serializes as `calc(0)`.
static bool bitwiseEqualChild(const CSSCalc::Child&, const CSSCalc::Child&);

// Every double compared by bit pattern rather than by value. `-0.0` and `0.0` differ; two NaNs with
// the same payload agree. `bit_cast` rather than `memcmp`, so the comparison is on a value and not
// on an object representation with padding in it.
static bool sameBits(double a, double b)
{
    return std::bit_cast<uint64_t>(a) == std::bit_cast<uint64_t>(b);
}

// One overload per slot shape, matching `rebuildSlot` in CSSCalcTree+Simplification.cpp -- five
// shapes, so five overloads, and a sixth would fail to compile here rather than be compared
// shallowly.
static bool bitwiseEqualSlot(const CSSCalc::Child& a, const CSSCalc::Child& b)
{
    return bitwiseEqualChild(a, b);
}

static bool bitwiseEqualSlot(const std::optional<CSSCalc::Child>& a, const std::optional<CSSCalc::Child>& b)
{
    if (a.has_value() != b.has_value())
        return false;
    return !a || bitwiseEqualChild(*a, *b);
}

static bool bitwiseEqualSlot(const CSSCalc::ChildOrNone& a, const CSSCalc::ChildOrNone& b)
{
    auto* childA = get_if<CSSCalc::Child>(&a);
    auto* childB = get_if<CSSCalc::Child>(&b);
    if (!childA || !childB)
        return !childA && !childB;
    return bitwiseEqualChild(*childA, *childB);
}

static bool bitwiseEqualSlot(const CSSCalc::Children& a, const CSSCalc::Children& b)
{
    if (a.size() != b.size())
        return false;
    for (size_t i = 0; i < a.size(); ++i) {
        if (!bitwiseEqualChild(a[i], b[i]))
            return false;
    }
    return true;
}

static bool bitwiseEqualSlot(const CSSCalc::Random::Sharing& a, const CSSCalc::Random::Sharing& b)
{
    // `operator==` and not a bitwise walk: `Sharing` is never computed, only copied through
    // unchanged (`rebuildChildren` passes it through as the one tuple slot that is not a subtree),
    // so the `double` inside `SharingFixed` is the same object's value on both sides and cannot
    // have been rounded differently.
    return a == b;
}

static bool bitwiseEqualSlot(const Vector<CSSCalc::CalcMix::Item>& a, const Vector<CSSCalc::CalcMix::Item>& b)
{
    if (a.size() != b.size())
        return false;
    for (size_t i = 0; i < a.size(); ++i) {
        // The weight is not a subtree and is copied through, so `operator==` for the same reason
        // `Random::Sharing` gets one; the value is a subtree and gets the bitwise walk.
        if (a[i].weight != b[i].weight || !bitwiseEqualChild(a[i].value, b[i].value))
            return false;
    }
    return true;
}

static bool bitwiseEqualAnchorSide(const CSSCalc::AnchorSide& a, const CSSCalc::AnchorSide& b)
{
    auto* childA = get_if<CSSCalc::Child>(&a.value);
    auto* childB = get_if<CSSCalc::Child>(&b.value);
    if (childA && childB)
        return bitwiseEqualChild(*childA, *childB);
    if (childA || childB)
        return false;
    return *get_if<CSSValueID>(&a.value) == *get_if<CSSValueID>(&b.value);
}

static bool bitwiseEqualChild(const CSSCalc::Child& a, const CSSCalc::Child& b)
{
    // The variant tag first, so everything below may assume the same alternative.
    if (a.value.index() != b.value.index())
        return false;

    return WTF::switchOn(a.value,
        [&](const auto& alternative) -> bool {
            using A = std::remove_cvref_t<decltype(alternative)>;
            const auto& other = *get_if<A>(&b.value);
            if constexpr (requires { *alternative; }) {
                using Op = std::remove_cvref_t<decltype(*alternative)>;
                // The per-node `Type` is compared for every operation, and it is one of the five
                // things serialization cannot see. Two trees that serialize identically can carry
                // different types, and the type is what the next stage consumes.
                if (!(alternative.type == other.type))
                    return false;
                if constexpr (std::same_as<Op, CSSCalc::Anchor>) {
                    // Not tuple-like (`tuple_size` 0, webkit.org/b/280798), so the generic walk
                    // below would compare nothing and report every pair of anchors equal. Compared
                    // field-by-field instead.
                    return alternative->elementName == other->elementName
                        && bitwiseEqualAnchorSide(alternative->side, other->side)
                        && bitwiseEqualSlot(alternative->fallback, other->fallback);
                } else if constexpr (std::same_as<Op, CSSCalc::AnchorSize>) {
                    return alternative->elementName == other->elementName
                        && alternative->dimension == other->dimension
                        && bitwiseEqualSlot(alternative->fallback, other->fallback);
                } else {
                    return [&]<size_t... I>(std::index_sequence<I...>) {
                        return (bitwiseEqualSlot(CSSCalc::get<I>(*alternative), CSSCalc::get<I>(*other)) && ...);
                    }(std::make_index_sequence<std::tuple_size_v<Op>> { });
                }
            } else if constexpr (std::same_as<A, CSSCalc::Number>)
                return sameBits(alternative.value, other.value);
            else if constexpr (std::same_as<A, CSSCalc::Percentage>) {
                // `hint` is the other thing serialization cannot see: it does not appear in `10%`,
                // and it is what `makeChildWithValueBasedOn` carries onto a folded percentage.
                return sameBits(alternative.value, other.value) && alternative.hint == other.hint;
            } else if constexpr (std::same_as<A, CSSCalc::CanonicalDimension>)
                return sameBits(alternative.value, other.value) && alternative.dimension == other.dimension;
            else if constexpr (std::same_as<A, CSSCalc::NonCanonicalDimension>)
                return sameBits(alternative.value, other.value) && alternative.unit == other.unit;
            else {
                // `Symbol`, `SiblingCount`, `SiblingIndex`: no `double` anywhere, so the defaulted
                // `operator==` is already the bitwise comparison.
                return alternative == other;
            }
        }
    );
}

// The whole `Tree`, which is four members and not one. `type`, `stage` and `requiresConversionData`
// are all invisible to serialization and all three are compared here; `requiresConversionData`
// drives eager evaluation at parse time and a warning in `UnevaluatedCalcBase::evaluateDeprecated`,
// and nothing in the text shows it.
static bool bitwiseEqualTree(const CSSCalc::Tree& a, const CSSCalc::Tree& b)
{
    return a.stage == b.stage
        && a.requiresConversionData == b.requiresConversionData
        && a.type == b.type
        && bitwiseEqualChild(a.root, b.root);
}

// Visits every node of a subtree, root included, in tree order.
//
// Its own walker rather than `forAllChildNodes`: `Anchor` and `AnchorSize` declare `tuple_size` 0,
// so the generic traversal yields no children for them, and a mask built from it would
// under-report exactly those two alternatives.
template<typename F> static void forEachNodeOfSubtree(const CSSCalc::Child& node, const F& function)
{
    function(node);

    auto visitSlot = [&](const auto& slot) {
        using S = std::remove_cvref_t<decltype(slot)>;
        if constexpr (std::same_as<S, CSSCalc::Child>)
            forEachNodeOfSubtree(slot, function);
        else if constexpr (std::same_as<S, std::optional<CSSCalc::Child>>) {
            if (slot)
                forEachNodeOfSubtree(*slot, function);
        } else if constexpr (std::same_as<S, CSSCalc::ChildOrNone>) {
            if (auto* child = get_if<CSSCalc::Child>(&slot))
                forEachNodeOfSubtree(*child, function);
        } else if constexpr (std::same_as<S, CSSCalc::Children>) {
            for (const auto& child : slot)
                forEachNodeOfSubtree(child, function);
        } else if constexpr (std::same_as<S, Vector<CSSCalc::CalcMix::Item>>) {
            for (const auto& item : slot)
                forEachNodeOfSubtree(item.value, function);
        }
        // `Random::Sharing` holds no subtree, and falls through deliberately.
    };

    WTF::switchOn(node.value,
        [&](const auto& alternative) {
            if constexpr (requires { *alternative; }) {
                using Op = std::remove_cvref_t<decltype(*alternative)>;
                if constexpr (std::same_as<Op, CSSCalc::Anchor>) {
                    if (auto* child = get_if<CSSCalc::Child>(&alternative->side.value))
                        forEachNodeOfSubtree(*child, function);
                    if (alternative->fallback)
                        forEachNodeOfSubtree(*alternative->fallback, function);
                } else if constexpr (std::same_as<Op, CSSCalc::AnchorSize>) {
                    if (alternative->fallback)
                        forEachNodeOfSubtree(*alternative->fallback, function);
                } else {
                    [&]<size_t... I>(std::index_sequence<I...>) {
                        (visitSlot(CSSCalc::get<I>(*alternative)), ...);
                    }(std::make_index_sequence<std::tuple_size_v<Op>> { });
                }
            }
        }
    );
}

// Bit `1 << index` for every `Node` alternative the subtree contains. 41 bits, so `uint64_t`, and
// keyed on the variant index rather than on `CSSCalcSwiftNodeKind` -- see
// `CSSCalcSwiftSimplificationResult::kindMask` for why only this keying expresses which
// alternatives were declined.
static uint64_t alternativeMaskOfSubtree(const CSSCalc::Child& root)
{
    uint64_t mask = 0;
    forEachNodeOfSubtree(root, [&](const CSSCalc::Child& node) {
        mask |= 1ULL << node.value.index();
    });
    return mask;
}

static uint32_t nodeCountOfSubtree(const CSSCalc::Child& root)
{
    uint32_t count = 0;
    forEachNodeOfSubtree(root, [&](const CSSCalc::Child&) { ++count; });
    return count;
}

// Does the subtree contain a `Sum` with a `Sum` directly among its children, or a `Product` with a
// `Product`? That is exactly the shape css-values-4 step 8.1 (CSSCalcTree+Simplification.cpp:555)
// and the outer half of step 9.1 (`:744`) splice, and the shape `CalcFlatTree.spliceNestedChildren`
// implements on the Swift side.
//
// IT IS UNREACHABLE FROM A PRE-SIMPLIFIED PARSE, which is the whole reason it is reported. The
// parser simplifies bottom-up, so by the time an outer `Sum` is built its inner `Sum` has already
// been spliced into it. Every case this differential ran before phase U therefore has this at 0, and
// the count of phase-U cases where it is 1 is the exact number of mismatches negative control NC-4
// -- an island with the splice disabled -- has to produce.
static bool subtreeHasSpliceableNesting(const CSSCalc::Child& root)
{
    bool found = false;
    forEachNodeOfSubtree(root, [&](const CSSCalc::Child& node) {
        if (auto* sum = get_if<CSSCalc::IndirectNode<CSSCalc::Sum>>(&node.value)) {
            for (const auto& child : (*sum)->children) {
                if (WTF::holdsAlternative<CSSCalc::IndirectNode<CSSCalc::Sum>>(child.value))
                    found = true;
            }
        }
        if (auto* product = get_if<CSSCalc::IndirectNode<CSSCalc::Product>>(&node.value)) {
            for (const auto& child : (*product)->children) {
                if (WTF::holdsAlternative<CSSCalc::IndirectNode<CSSCalc::Product>>(child.value))
                    found = true;
            }
        }
    });
    return found;
}

// Whether any numeric leaf in the subtree is a NaN.
//
// Computed from the tree, not from the source text: `calc(0 / 0)` produces a NaN the text does not
// mention. This is what lets the disagreement between the bitwise and defaulted comparisons be
// exempted for exactly the cases that contain a NaN, rather than for whatever the text implies.
static bool subtreeContainsNaN(const CSSCalc::Child& root)
{
    bool found = false;
    forEachNodeOfSubtree(root, [&](const CSSCalc::Child& node) {
        WTF::switchOn(node.value,
            [&]<CSSCalc::Numeric T>(const T& leaf) {
                if (std::isnan(leaf.value))
                    found = true;
            },
            [](const auto&) { }
        );
    });
    return found;
}

// A `Style::ComputedStyle` at a chosen font size, kept alive for the process.
//
// Function-local statics, not globals, because `CSSToLengthConversionData` holds a reference to
// the style rather than a copy: a style built per call and returned by value would leave the
// options pointing at a dead object. WebCore also links with -no_inits.
//
// `styleBuilderState()` is null for conversion-data kinds 1 and 2, which is what makes
// `SiblingCount`, `SiblingIndex`, `Random`, `Anchor` and `AnchorSize` return `nullopt` from their
// `simplify` on both sides at those kinds. Kinds 3 and 4 -- `simplificationBuilderStateAtFontSize`
// below -- are the same two styles with a live `Style::BuilderState` attached.
//
// `setFontDescription`, not `setFontDescriptionWithoutUpdate` -- this is load-bearing.
// `WithoutUpdate` leaves `FontCascade::m_fonts` null (StyleComputedStyleBase.cpp:233 only rebuilds
// the cascade from the description); the non-`WithoutUpdate` form calls `FontCascade::update(
// fontSelector)` at :229, which goes to `FontCache::forCurrentThread()->updateFontCascade` and
// installs a real `FontCascadeFonts`. Without it, `Style::resolveEx` -> `metricsOfPrimaryFont()` ->
// `primaryFont()` dereferences a null `m_fonts` and takes EXC_BAD_ACCESS on the first
// font-metric-relative unit, e.g. `calc(1ex)`.
//
// `update(nullptr)` works here with no Document, no Page and no FontSelector: `fonts()` goes from
// null to non-null, and the metrics the units resolve from differ between the two font sizes
// (xHeight 7.1797 vs 14.3594, capHeight 10.5859 vs 21.1719, lineSpacing 18 vs 37), which is what
// lets the two-size design below prove the conversion data is actually read.
//
// Non-const; the const wrapper below is what everything else uses. `Style::BuilderState::create`
// takes `ComputedStyle&`, and `BuilderState::siblingCount()` writes
// `m_style.setUsesTreeCountingFunctions()` on it, so the builder-state kinds need a mutable
// reference to the same object kinds 1 and 2 use. Sharing it is what makes comparing kind 3 against
// kind 1 change only `styleBuilderState()`, rather than comparing two different fixtures.
static Style::ComputedStyle& simplificationStyleStorageAtFontSize(float fontSize)
{
    static NeverDestroyed<Style::ComputedStyle> style16 = [] {
        auto style = Style::ComputedStyle::create();
        auto description = style.fontDescription();
        description.setComputedSize(16);
        description.setSpecifiedSize(16);
        style.setFontDescription(WTF::move(description));
        return style;
    }();
    static NeverDestroyed<Style::ComputedStyle> style32 = [] {
        auto style = Style::ComputedStyle::create();
        auto description = style.fontDescription();
        description.setComputedSize(32);
        description.setSpecifiedSize(32);
        style.setFontDescription(WTF::move(description));
        return style;
    }();
    // Two present values rather than one, deliberately: a present/absent boolean would be satisfied
    // by a `canonicalize` that just returned a constant; only a second style at a different font
    // size proves the conversion data is actually read.
    return fontSize > 16 ? style32.get() : style16.get();
}

const Style::ComputedStyle& simplificationStyleAtFontSize(float fontSize)
{
    return simplificationStyleStorageAtFontSize(fontSize);
}

// MARK: - The builder-state fixture: conversion-data kinds 3 and 4
//
// Five `simplify` overloads (`SiblingCount`, `SiblingIndex`, `Random`, `Anchor`, `AnchorSize`)
// return `nullopt` on both arms when `options.conversionData->styleBuilderState()` is null, so
// this fixture supplies a real one.
//
// The element is the third of five siblings, so `siblingCount()` is 5 and `siblingIndex()` is 3
// -- distinguishable, unlike with a single sibling. No Page, Frame or style resolution is needed.
//
// `BuilderContext` is left at its default except four fields: `treeResolutionState` and
// `rootElementStyle` stay null (matching production and kinds 1/2 respectively), and
// `parentStyle` is set to the style itself rather than left null, because
// `CSSToLengthConversionData`'s `parentStyle()` unconditionally dereferences it
// (CSSToLengthConversionData.cpp:56, StyleBuilderState.h:127) -- a null there is UB.
struct SimplificationBuilderStateFixture {
    RefPtr<Settings> settings;
    RefPtr<Document> document;
    // The third of the five `<div>`s.
    RefPtr<Element> element;
    // Re-created between the two arms; see `resetSimplificationBuilderStates`.
    std::optional<UniqueRef<Style::BuilderState>> state16;
    std::optional<UniqueRef<Style::BuilderState>> state32;
};

static SimplificationBuilderStateFixture& simplificationBuilderStateFixture()
{
    static NeverDestroyed<SimplificationBuilderStateFixture> fixture = [] {
        SimplificationBuilderStateFixture f;
        // Registers the qualified names `HTMLHtmlElement::create` and friends look up. Omitting it
        // is not a soft failure -- it is what TestWebKitAPI's own recipe does first.
        ProcessWarming::initializeNames();
        f.settings = Settings::create(nullptr);
        f.document = Document::create(*f.settings, aboutBlankURL());
        Ref documentElement = HTMLHtmlElement::create(*f.document);
        f.document->appendChild(documentElement);
        Ref body = HTMLBodyElement::create(*f.document);
        documentElement->appendChild(body);
        for (unsigned i = 0; i < 5; ++i) {
            Ref div = HTMLDivElement::create(*f.document);
            body->appendChild(div);
            if (i == 2)
                f.element = div.ptr();
        }
        return f;
    }();
    return fixture.get();
}

// Destroys and rebuilds both `BuilderState`s, leaving the Document and the element tree alone.
//
// Must run between the two comparison arms: the anchor `simplify` overloads set a bit
// (`m_invalidAtComputedValueTimeProperties`, StyleBuilderState.cpp:324-327) with no public way
// to clear it, so the state is replaced instead of reused.
//
// The Document and element are NOT rebuilt: `random()`'s base value is cached on them by
// `RandomCachingKey`, and rebuilding would give the two arms different values for the same key.
//
// A `CheckedPtr` to a `BuilderState` must not outlive it (`CanMakeCheckedPtr`'s destructor
// RELEASE_ASSERTs), so callers build `SimplificationOptions` after this call and drop them
// before the next one.
//
// The anchor overloads' `std::exchange(node.fallback, { })` looks like it mutates the input, but
// `copyAndSimplifyChildren` (CSSCalcTree+Simplification.cpp:1795-1807) already hands each arm a
// freshly built `Anchor`/`AnchorSize`, not the input's node, so each arm only mutates its own
// copy.
static void resetSimplificationBuilderStates()
{
    auto& fixture = simplificationBuilderStateFixture();
    auto make = [&](float fontSize) {
        auto& style = simplificationStyleStorageAtFontSize(fontSize);
        return Style::BuilderState::create(style, Style::BuilderContext {
            .document = *fixture.document,
            .parentStyle = &style,
            .element = fixture.element,
        });
    };
    // Cleared before either is rebuilt so that the old objects are gone before the new ones exist,
    // rather than two live states briefly sharing one style.
    fixture.state16 = std::nullopt;
    fixture.state32 = std::nullopt;
    fixture.state16.emplace(make(16.0f));
    fixture.state32.emplace(make(32.0f));
}

static Style::BuilderState& simplificationBuilderStateAtFontSize(float fontSize)
{
    auto& fixture = simplificationBuilderStateFixture();
    if (!fixture.state16)
        resetSimplificationBuilderStates();
    return fontSize > 16 ? fixture.state32->get() : fixture.state16->get();
}

// Did either anchor overload mark the current property invalid at computed-value time during the
// run that just happened? The current property is null here, so `cssPropertyID()` is
// `CSSPropertyInvalid` and the bit index is 0, which still works as a channel for "this happened" --
// the only externally visible effect of `simplify(Anchor&)` on a node with no fallback.
static bool simplificationBuilderStateFlaggedInvalid(float fontSize)
{
    return simplificationBuilderStateAtFontSize(fontSize).isCurrentPropertyInvalidAtComputedValueTime();
}

// Which font size a conversion-data kind selects, and whether it carries a builder state.
// 0 none, 1 a style at 16px, 2 the same at 32px, 3 16px WITH a builder state, 4 32px with one.
static float simplificationConversionDataFontSize(uint32_t kind)
{
    return (kind == 2 || kind == 4) ? 32.0f : 16.0f;
}

static bool simplificationConversionDataCarriesBuilderState(uint32_t kind)
{
    return kind >= 3;
}


// Nine symbol tables, keyed by kind. Kinds 3..8 are the only way to bind a `Symbol` to a value the
// CSS number grammar cannot spell as a literal -- NaN, an infinity, a negative zero, a subnormal or
// 2^31-1 -- so e.g. `mod(r, g)` with `r` bound to NaN is the only way to reach
// `executeMathOperation<Mod>(NaN, NaN)`. The four ids are the relative-colour component symbols,
// matching `calcAllowedSymbols`'s parse-side table; this one is used on the simplification side.
CSSCalcSymbolTable simplificationSymbolTable(uint32_t kind)
{
    constexpr double subnormal = 5e-324;
    switch (kind) {
    case 1:
        return CSSCalcSymbolTable {
            { CSSValueR, CSSUnitType::Number, 1.0 },
            { CSSValueG, CSSUnitType::Number, 2.0 },
            { CSSValueB, CSSUnitType::Number, 3.0 },
            { CSSValueAlpha, CSSUnitType::Number, 0.5 },
        };
    case 2:
        // A dimension rather than a number, which gives the recursive `copyAndSimplify` inside
        // `simplify(Symbol&)` real work: the replacement is a `CanonicalDimension`, making the
        // percentage-typed operations reachable.
        return CSSCalcSymbolTable {
            { CSSValueR, CSSUnitType::Px, 1.0 },
            { CSSValueG, CSSUnitType::Px, 2.0 },
            { CSSValueB, CSSUnitType::Px, 3.0 },
            { CSSValueAlpha, CSSUnitType::Px, 0.5 },
        };
    case 3:
        return CSSCalcSymbolTable {
            { CSSValueR, CSSUnitType::Number, std::numeric_limits<double>::quiet_NaN() },
            { CSSValueG, CSSUnitType::Number, std::numeric_limits<double>::quiet_NaN() },
            { CSSValueB, CSSUnitType::Number, std::numeric_limits<double>::quiet_NaN() },
            { CSSValueAlpha, CSSUnitType::Number, std::numeric_limits<double>::quiet_NaN() },
        };
    case 4:
        return CSSCalcSymbolTable {
            { CSSValueR, CSSUnitType::Number, std::numeric_limits<double>::infinity() },
            { CSSValueG, CSSUnitType::Number, std::numeric_limits<double>::infinity() },
            { CSSValueB, CSSUnitType::Number, std::numeric_limits<double>::infinity() },
            { CSSValueAlpha, CSSUnitType::Number, std::numeric_limits<double>::infinity() },
        };
    case 5:
        return CSSCalcSymbolTable {
            { CSSValueR, CSSUnitType::Number, -std::numeric_limits<double>::infinity() },
            { CSSValueG, CSSUnitType::Number, -std::numeric_limits<double>::infinity() },
            { CSSValueB, CSSUnitType::Number, -std::numeric_limits<double>::infinity() },
            { CSSValueAlpha, CSSUnitType::Number, -std::numeric_limits<double>::infinity() },
        };
    case 6:
        // The value neither the defaulted comparison nor serialization can see: `-0.0 == 0.0` is
        // true, and `calc(-0)` serializes as `calc(0)`. Only the bitwise comparison reports a fold
        // that normalized the sign.
        return CSSCalcSymbolTable {
            { CSSValueR, CSSUnitType::Number, -0.0 },
            { CSSValueG, CSSUnitType::Number, -0.0 },
            { CSSValueB, CSSUnitType::Number, -0.0 },
            { CSSValueAlpha, CSSUnitType::Number, -0.0 },
        };
    case 7:
        return CSSCalcSymbolTable {
            { CSSValueR, CSSUnitType::Number, subnormal },
            { CSSValueG, CSSUnitType::Number, subnormal },
            { CSSValueB, CSSUnitType::Number, subnormal },
            { CSSValueAlpha, CSSUnitType::Number, subnormal },
        };
    case 8:
        // Straddling INT_MAX on purpose: `g` is one above it, so `mod(r, g)` and the four rounding
        // strategies run either side of the boundary where a `double -> int` narrowing would show.
        return CSSCalcSymbolTable {
            { CSSValueR, CSSUnitType::Number, 2147483647.0 },
            { CSSValueG, CSSUnitType::Number, 2147483648.0 },
            { CSSValueB, CSSUnitType::Number, 2147483647.0 },
            { CSSValueAlpha, CSSUnitType::Number, 2147483647.0 },
        };
    default:
        return { };
    }
}

// Eight trees built directly rather than parsed, because no parse produces them.
//
// Every parse-reachable `Deg2Rad` sits inside a `Product` (`sin(r * 1deg)`), and every
// parse-reachable `Invert` does too (`calc(1 / r)` is `Product{1, Invert{Symbol}}`); since
// `Product` is declined here, a parsed corpus reaches `Deg2Rad` and `Invert` without ever
// simplifying them. See `constructRootShape` above for the same idea applied to `Negate` and
// `Invert` at a tree's root.
//
// Shapes 4 to 7 cover `Min`, `Max`, `Clamp` and `Hypot` branches that are reached and simplified by
// a parsed corpus but whose specific outcome is not. The sharpest is shape 4: `buildMinMax` is the
// only rewrite that produces a node kind not present in the input, and it never runs from parsed
// input because the conversion condition it tests is monotone under canonicalization --
// `clamp(none, 1px, 1em)` arrives already converted, as `min(1px, 1em)` with no `Clamp` in it.
constexpr unsigned simplificationConstructedShapeCount = 8;

std::optional<CSSCalc::Tree> constructSimplificationShape(unsigned shape)
{
    auto typeOf = [](const auto& op, const CSSCalc::Child& fallbackTypeSource) {
        // The operation's own computed type where it has one, and the child's where `toType`
        // declines. A tree built with a type its operation would not have produced is a tree the
        // two sides could disagree about for a reason that is this function's fault, not theirs.
        if (auto type = CSSCalc::toType(op))
            return *type;
        return CSSCalc::getType(fallbackTypeSource);
    };

    switch (shape) {
    case 0: {
        // `Deg2Rad{Symbol}`. Angle-typed, because that is what `Deg2Rad` wraps.
        auto child = CSSCalc::makeChild(CSSCalc::Symbol { .id = CSSValueR, .unit = CSSUnitType::Deg });
        auto op = CSSCalc::Deg2Rad { .angle = CSSCalc::copy(child) };
        auto type = typeOf(op, child);
        return CSSCalc::Tree { .root = CSSCalc::makeChild(WTF::move(op), type), .type = type, .stage = CSSCalc::Stage::Specified };
    }
    case 1: {
        // `Sin{Deg2Rad{Symbol}}` -- the shape the parser really builds for `sin(<angle>)`, but with
        // the angle a symbol rather than a literal, so it survives the parse-time fold.
        auto child = CSSCalc::makeChild(CSSCalc::Symbol { .id = CSSValueR, .unit = CSSUnitType::Deg });
        auto inner = CSSCalc::Deg2Rad { .angle = CSSCalc::copy(child) };
        auto innerType = typeOf(inner, child);
        auto innerChild = CSSCalc::makeChild(WTF::move(inner), innerType);
        auto op = CSSCalc::Sin { .a = CSSCalc::copy(innerChild) };
        auto type = typeOf(op, innerChild);
        return CSSCalc::Tree { .root = CSSCalc::makeChild(WTF::move(op), type), .type = type, .stage = CSSCalc::Stage::Specified };
    }
    case 2: {
        // `Deg2Rad{CanonicalDimension(1deg)}`, the one shape here that folds: `simplify(Deg2Rad&)`
        // turns a `CanonicalDimension` child into `Number { deg2rad(value) }` unconditionally
        // (CSSCalcTree+Simplification.cpp:986-990). This is the only shape whose `Deg2Rad` handling
        // actually produces a node, and it changes its input at the parse baseline with no swept
        // option involved -- see the note on `webCoreCSSCalcCompareSimplificationConstructed`.
        auto child = CSSCalc::makeChild(CSSCalc::CanonicalDimension { .value = 1, .dimension = CSSCalc::CanonicalDimension::Dimension::Angle });
        auto op = CSSCalc::Deg2Rad { .angle = CSSCalc::copy(child) };
        auto type = typeOf(op, child);
        return CSSCalc::Tree { .root = CSSCalc::makeChild(WTF::move(op), type), .type = type, .stage = CSSCalc::Stage::Specified };
    }
    case 3: {
        // `Invert{Symbol}`, number-typed. A bare `Invert` is unreachable through a parse because
        // division always builds the `Product` wrapper around it.
        //
        // The symbol is `CSSValueR` here and in shapes 0, 1 and 6 so that the swept symbol table
        // resolves it; a symbol the table does not bind would leave those shapes inert across the
        // whole sweep.
        auto child = CSSCalc::makeChild(CSSCalc::Symbol { .id = CSSValueR, .unit = CSSUnitType::Number });
        auto op = CSSCalc::Invert { .a = CSSCalc::copy(child) };
        auto type = typeOf(op, child);
        return CSSCalc::Tree { .root = CSSCalc::makeChild(WTF::move(op), type), .type = type, .stage = CSSCalc::Stage::Specified };
    }
    case 4: {
        // `clamp(none, 1px, 1em)`, i.e. `convertToMin` succeeding -- the only rewrite in the
        // simplifier that produces an operation kind not present in the input
        // (`+Simplification.cpp:1018`-`:1044`), via `CSSCalcSwiftBuilder::buildMinMax`.
        //
        // No parse reaches it: `convertToMin` fires when `val` is a `Numeric` and the present bound
        // is a different alternative or unit, and that condition is monotone under
        // canonicalization, so a bound that mismatches after conversion also mismatched before it --
        // `clamp(none, 1px, 1em)` as text arrives as `min(1px, 1em)` with no `Clamp` in the tree at
        // all. The symbol route does not help either: `calcAllowedSymbols()` declares all four
        // symbols `CSSUnitType::Number`, and `simplify(Symbol&)` takes the unit from the node, so no
        // symbol table can create a mismatch.
        //
        // The mismatch here is `CanonicalDimension` against `NonCanonicalDimension`, which holds
        // with no conversion data and dissolves once one is supplied -- there `1em` canonicalizes to
        // a `Px` and the `clamp()` folds to a leaf instead.
        auto minimum = CSSCalc::ChildOrNone { CSS::Keyword::None { } };
        auto value = CSSCalc::makeChild(CSSCalc::CanonicalDimension { .value = 1, .dimension = CSSCalc::CanonicalDimension::Dimension::Length });
        auto maximum = CSSCalc::makeChild(CSSCalc::NonCanonicalDimension { .value = 1, .unit = CSSUnitType::Em });
        auto op = CSSCalc::Clamp { .min = WTF::move(minimum), .val = CSSCalc::copy(value), .max = CSSCalc::ChildOrNone { CSSCalc::copy(maximum) } };
        auto type = typeOf(op, value);
        return CSSCalc::Tree { .root = CSSCalc::makeChild(WTF::move(op), type), .type = type, .stage = CSSCalc::Stage::Specified };
    }
    case 5: {
        // `clamp(none, 1px, 1)`, i.e. `convertToMin` failing -- `toType(Min { 1px, 1 })` returns
        // `std::nullopt` because a `<length>` and a `<number>` do not merge, at which point the C++
        // `simplify` returns `nullopt` and rebuilds the `Clamp` itself.
        //
        // The Swift side cannot do that: by the time `buildMinMax` answers false, `rewrite` has
        // already pushed two operands where the parent expects one and there is no `pop`, so a false
        // answer means the whole tree is declined (see `rewriteConvertedMinMax` in
        // CSSCalcSimplificationSwift.swift for why that is exact).
        //
        // A `Clamp` whose type does not merge is not reachable through the parser at all, since the
        // parser's own type check rejects `clamp(none, 1px, 1)` outright. This is a boundary
        // contract test rather than a coverage test.
        auto minimum = CSSCalc::ChildOrNone { CSS::Keyword::None { } };
        auto value = CSSCalc::makeChild(CSSCalc::CanonicalDimension { .value = 1, .dimension = CSSCalc::CanonicalDimension::Dimension::Length });
        auto maximum = CSSCalc::makeChild(CSSCalc::Number { .value = 1 });
        auto op = CSSCalc::Clamp { .min = WTF::move(minimum), .val = CSSCalc::copy(value), .max = CSSCalc::ChildOrNone { CSSCalc::copy(maximum) } };
        auto type = typeOf(op, value);
        return CSSCalc::Tree { .root = CSSCalc::makeChild(WTF::move(op), type), .type = type, .stage = CSSCalc::Stage::Specified };
    }
    case 6: {
        // `min(r)`, i.e. `simplifyForMinMax`'s one-child early return (`+Simplification.cpp:408`).
        //
        // No parse reaches it: that return does not require the child to be resolved, so `min(r)`
        // as text folds to `calc(r)` during the parse's own simplification and no `Min` survives.
        // The Swift equivalent is `foldMinMax`'s `folded.count == 1 -> promoteTerm`, which produces
        // `.replacedByTerm` for an unresolved symbol and `.leaf` for a resolved one -- two different
        // paths, selected here by the symbol table.
        //
        // `clamp(none, VAL, none)` (`:1013`) is unreachable for the identical reason and is not given
        // its own shape: it is the same `promoteTerm` call from `foldClamp`'s `childCount == 1` arm.
        auto child = CSSCalc::makeChild(CSSCalc::Symbol { .id = CSSValueR, .unit = CSSUnitType::Number });
        auto op = CSSCalc::Min { .children = CSSCalc::Children { Vector<CSSCalc::Child>::from(CSSCalc::copy(child)) } };
        auto type = typeOf(op, child);
        return CSSCalc::Tree { .root = CSSCalc::makeChild(WTF::move(op), type), .type = type, .stage = CSSCalc::Stage::Specified };
    }
    case 7: {
        // `hypot(10%, 20%)`, i.e. `simplify(Hypot&)`'s `PercentageTag` arm
        // (`+Simplification.cpp:1269`).
        //
        // No parse reaches it: `hypot(10%, 20%)` as text constant-folds during the parse, and no
        // symbol table can produce a `Percentage` leaf, since `calcAllowedSymbols()` declares all
        // four symbols `CSSUnitType::Number`.
        //
        // This also tests a claim made by derivation rather than by carrying the value: the C++
        // stamps `Type::determinePercentHint(options.category)` onto the folded `Percentage`, while
        // the Swift side writes `percentHint: 0`, which is exact because `determinePercentHint` is
        // non-`None` for exactly `LengthPercentage` and `AnglePercentage`, `percentageResolveToDimension`
        // is true for exactly those two, and the percentage arm is only entered when it is false.
        // `.hint = { }` is `Type::PercentHintValue`'s `None`, matching what `makeNumeric` builds for
        // a parsed `<percentage>` (CSSCalcTree.cpp:196-:197). Spelled rather than defaulted because
        // `-Wmissing-designated-field-initializers` is an error in this build.
        auto first = CSSCalc::makeChild(CSSCalc::Percentage { .value = 10, .hint = { } });
        auto second = CSSCalc::makeChild(CSSCalc::Percentage { .value = 20, .hint = { } });
        auto op = CSSCalc::Hypot { .children = CSSCalc::Children { Vector<CSSCalc::Child>::from(CSSCalc::copy(first), CSSCalc::copy(second)) } };
        auto type = typeOf(op, first);
        return CSSCalc::Tree { .root = CSSCalc::makeChild(WTF::move(op), type), .type = type, .stage = CSSCalc::Stage::Specified };
    }
    default:
        return std::nullopt;
    }
}

} // namespace
} // namespace WebCore

using namespace WebCore;

extern "C" {

struct CSSTokenizerSwiftValidationResult {
    // -1 when the streams agree; otherwise the index of the first divergence.
    int64_t divergenceIndex;
    // What diverged, for the failure message.
    uint32_t expectedType;
    uint32_t actualType;
    uint64_t realTokenCount;
    uint64_t swiftTokenCount;
    // What diverged, decoded by divergenceReason() in CSSTokenizerSwiftTest.cpp: 0 = the
    // tokens compare unequal, 1 = block types, 2 = token counts, 3 = an observer token
    // offset, 4 = the observer's end offset, 5 = a numeric field, 6 = the source was not
    // valid UTF-8, 7 = a dimension's unit type, 8 = a dimension's value text, 9 = a
    // dimension's non-unit prefix length. Add a case there too when adding a code.
    uint32_t reason;
};

WEBCORE_EXPORT CSSTokenizerSwiftValidationResult webCoreCSSTokenizerComparePaths(const char*, size_t);
WEBCORE_EXPORT CSSTokenizerSwiftValidationResult webCoreCSSTokenizerCompareObserverOffsets(const char*, size_t);
WEBCORE_EXPORT CSSTokenizerSwiftValidationResult webCoreCSSTokenizerComparePathsUTF8(const char*, size_t);
WEBCORE_EXPORT unsigned webCoreCSSTokenizerSwiftDeclineCount(void);
WEBCORE_EXPORT void webCoreCSSTokenizerSetForceSwiftIslandDecline(bool);
WEBCORE_EXPORT bool webCoreCSSTokenizerTryCreateSucceeds(const char*, size_t);
WEBCORE_EXPORT bool webCoreCSSTokenizerDefaultScannerIsSwift(void);
WEBCORE_EXPORT void webCoreCSSTokenizerBenchIntegrated(const char*, size_t, bool, size_t*, uint64_t*);
WEBCORE_EXPORT void webCoreCSSTokenizerBenchIntegrated16(const char*, size_t, bool, size_t*, uint64_t*, bool*);
WEBCORE_EXPORT uint32_t webCoreCSSTokenizerUnitTrieCompare8(const uint8_t*, size_t);
WEBCORE_EXPORT uint32_t webCoreCSSTokenizerUnitTrieCompare16(const uint16_t*, size_t);
WEBCORE_EXPORT uint64_t webCoreCSSTokenizerUnitTrieCxxCallCount(void);
WEBCORE_EXPORT size_t webCoreCSSTokenizerUnitTrieMaximumLength(void);

// The integration gate: builds the whole CSSParserToken stream both ways, in one
// process, and compares the tokens themselves rather than just the POD-level
// output. This has to hold before the Swift path could ever be turned on by
// default, because it compares what the rest of the CSS parser will actually
// see: values, numeric values, units, hash types and block types.
//
// One token's worth of that comparison, shared by the 8-bit and the UTF-8 entry below
// so that the two cannot drift apart. Returns nothing when the tokens agree.
//
// operator== covers more than it looks: the whitespace run length is compared, via
// `case NonNewlineWhitespaceToken` in CSSParserToken.cpp. What it does not cover is
// the numeric fields of NumberToken and PercentageToken -- for those it compares
// originalText() and stops -- and, for a DimensionToken, anything but originalText()
// whenever the *left* operand has a non-unit prefix. Both holes are filled below:
// after this function returns nullopt, every field a DimensionToken carries has been
// compared, m_bits.nonUnitPrefixLength included, and none of it needed a new accessor.
struct TokenDivergence {
    uint32_t reason;
    uint32_t expected;
    uint32_t actual;
};

static std::optional<TokenDivergence> compareTokens(const CSSParserToken& expected, const CSSParserToken& actual)
{
    if (!(expected == actual))
        return TokenDivergence { 0, static_cast<uint32_t>(expected.type()), static_cast<uint32_t>(actual.type()) };
    if (expected.getBlockType() != actual.getBlockType())
        return TokenDivergence { 1, static_cast<uint32_t>(expected.getBlockType()), static_cast<uint32_t>(actual.getBlockType()) };

    // nonInteger, plusSign and minusSign become numericValueType and numericSign, and
    // for NumberToken and PercentageToken nothing above compares them: a wrong flag would
    // pass every test here while breaking <integer> validation and nth-child(An+B) sign
    // handling.
    //
    // Compared as bit patterns rather than as doubles, so that +0 and -0 are
    // distinguished -- that is exactly the difference a sign flag makes, and == would
    // hide it. Both paths run the same charactersToDouble over the same range, so
    // anything but an identical pattern is a real divergence.
    if (expected.type() == NumberToken || expected.type() == PercentageToken || expected.type() == DimensionToken) {
        bool agrees = std::bit_cast<uint64_t>(expected.numericValue()) == std::bit_cast<uint64_t>(actual.numericValue())
            && expected.numericValueType() == actual.numericValueType();
        // numericSign() asserts on NumberToken: it is the only type <an+b> reads it for.
        if (agrees && expected.type() == NumberToken)
            agrees = expected.numericSign() == actual.numericSign();
        if (!agrees)
            return TokenDivergence { 5, static_cast<uint32_t>(expected.numericValueType()), static_cast<uint32_t>(actual.numericValueType()) };
    }

    // A DimensionToken's unit. operator== takes its `m_bits.nonUnitPrefixLength == 0` branch off
    // *this*, so with a prefix it falls through to `originalText()` and never compares
    // `unitString()` or `m_bits.unit` -- exactly the field a bad change could corrupt with every
    // test still passing.
    //
    // value() plus unitString() together pin `m_bits.nonUnitPrefixLength` too, since unitString()
    // is value().substring(m_bits.nonUnitPrefixLength) -- no new accessor needed. value() alone
    // also catches convertToDimensionWithUnit's merge rule: `10px` keeps both parts in one view;
    // `1\70x` (escaped) does not, so value() differs even though the unit type agrees.
    //
    // Still uncompared: a value whose text matches but whose backing StringImpl chose the other
    // character width.
    if (expected.type() == DimensionToken) {
        if (expected.unitType() != actual.unitType())
            return TokenDivergence { 7, static_cast<uint32_t>(expected.unitType()), static_cast<uint32_t>(actual.unitType()) };
        if (expected.value() != actual.value())
            return TokenDivergence { 8, expected.value().length(), actual.value().length() };
        // value() agreed, so this is exactly a m_bits.nonUnitPrefixLength divergence.
        if (expected.unitString() != actual.unitString())
            return TokenDivergence { 9, expected.value().length() - expected.unitString().length(), actual.value().length() - actual.unitString().length() };
    }
    return std::nullopt;
}

// The integration gate: builds the whole CSSParserToken stream both ways, in one
// process, and compares the tokens themselves rather than just the POD-level
// output. This has to hold before the Swift path could ever be turned on by
// default, because it compares what the rest of the CSS parser will actually
// see: values, numeric values, units, hash types and block types.
WEBCORE_EXPORT CSSTokenizerSwiftValidationResult webCoreCSSTokenizerComparePaths(const char* text, size_t length)
{
    CSSTokenizerSwiftValidationResult result { -1, 0, 0, 0, 0, 0 };
    String source { unsafeMakeSpan(byteCast<Latin1Character>(text), length) };

    // Both tokenizers stay alive for the comparison: each token's value is a view
    // into its own tokenizer's input or string pool.
    WebCore::CSSTokenizer cppTokenizer(source, CSSTokenizer::Scanner::Cpp);
    WebCore::CSSTokenizer swiftTokenizer(source, CSSTokenizer::Scanner::Swift);

    auto cppRange = cppTokenizer.tokenRange();
    auto swiftRange = swiftTokenizer.tokenRange();
    result.realTokenCount = cppRange.size();
    result.swiftTokenCount = swiftRange.size();

    size_t index = 0;
    for (; !cppRange.atEnd() && !swiftRange.atEnd(); cppRange.consume(), swiftRange.consume(), ++index) {
        if (auto divergence = compareTokens(cppRange.peek(), swiftRange.peek())) {
            result.divergenceIndex = static_cast<int64_t>(index);
            result.expectedType = divergence->expected;
            result.actualType = divergence->actual;
            result.reason = divergence->reason;
            return result;
        }
    }
    if (cppRange.size() != swiftRange.size()) {
        result.divergenceIndex = static_cast<int64_t>(index);
        result.reason = 2;
    }
    return result;
}

// Same comparison, but the source is built from UTF-8 so that any non-ASCII text
// makes StringImpl choose its 16-bit representation. That is the only way to
// exercise the Swift tokenizer's UInt16 specialization: a String built from
// Latin-1 bytes is always 8-bit. `expectedType` comes back as 8 or 16 so the
// caller can confirm which representation was actually tested rather than
// assuming.
WEBCORE_EXPORT CSSTokenizerSwiftValidationResult webCoreCSSTokenizerComparePathsUTF8(const char* text, size_t length)
{
    CSSTokenizerSwiftValidationResult result { -1, 0, 0, 0, 0, 0 };
    String source = String::fromUTF8(unsafeMakeSpan(byteCast<char8_t>(text), length));
    if (source.isNull()) {
        result.divergenceIndex = 0;
        result.reason = 6;
        return result;
    }

    WebCore::CSSTokenizer cppTokenizer(source, CSSTokenizer::Scanner::Cpp);
    WebCore::CSSTokenizer swiftTokenizer(source, CSSTokenizer::Scanner::Swift);

    auto cppRange = cppTokenizer.tokenRange();
    auto swiftRange = swiftTokenizer.tokenRange();
    result.realTokenCount = cppRange.size();
    result.swiftTokenCount = swiftRange.size();
    result.expectedType = source.is8Bit() ? 8 : 16;

    size_t index = 0;
    for (; !cppRange.atEnd() && !swiftRange.atEnd(); cppRange.consume(), swiftRange.consume(), ++index) {
        if (auto divergence = compareTokens(cppRange.peek(), swiftRange.peek())) {
            result.divergenceIndex = static_cast<int64_t>(index);
            // expectedType stays the character width the caller asserts on, so only the
            // actual value is reported here.
            result.actualType = divergence->actual;
            result.reason = divergence->reason;
            return result;
        }
    }
    if (cppRange.size() != swiftRange.size()) {
        result.divergenceIndex = static_cast<int64_t>(index);
        result.reason = 2;
    }
    return result;
}

// The inspector path: both tokenizers built with an observer wrapper attached, then
// every source offset the wrapper was fed compared. A wrapper records one offset
// per token plus one per comment, and startOffset()/endOffset() read them back, so
// walking the range position by position checks all of them.
WEBCORE_EXPORT CSSTokenizerSwiftValidationResult webCoreCSSTokenizerCompareObserverOffsets(const char* text, size_t length)
{
    CSSTokenizerSwiftValidationResult result { -1, 0, 0, 0, 0, 0 };
    String source { unsafeMakeSpan(byteCast<Latin1Character>(text), length) };

    NullCSSParserObserver observer;
    auto cppWrapper = CSSParserObserverWrapper::create(observer);
    auto swiftWrapper = CSSParserObserverWrapper::create(observer);

    WebCore::CSSTokenizer cppTokenizer(source, cppWrapper.get(), CSSTokenizer::Scanner::Cpp);
    WebCore::CSSTokenizer swiftTokenizer(source, swiftWrapper.get(), CSSTokenizer::Scanner::Swift);

    auto cppRange = cppTokenizer.tokenRange();
    auto swiftRange = swiftTokenizer.tokenRange();
    result.realTokenCount = cppRange.size();
    result.swiftTokenCount = swiftRange.size();
    if (cppRange.size() != swiftRange.size()) {
        result.divergenceIndex = 0;
        result.reason = 2;
        return result;
    }

    size_t index = 0;
    for (; !cppRange.atEnd(); cppRange.consume(), swiftRange.consume(), ++index) {
        if (cppWrapper->startOffset(cppRange) != swiftWrapper->startOffset(swiftRange)) {
            result.divergenceIndex = static_cast<int64_t>(index);
            result.expectedType = cppWrapper->startOffset(cppRange);
            result.actualType = swiftWrapper->startOffset(swiftRange);
            result.reason = 3;
            return result;
        }
    }
    if (cppWrapper->endOffset(cppRange) != swiftWrapper->endOffset(swiftRange)) {
        result.divergenceIndex = static_cast<int64_t>(index);
        result.expectedType = cppWrapper->endOffset(cppRange);
        result.actualType = swiftWrapper->endOffset(swiftRange);
        result.reason = 4;
    }
    return result;
}

WEBCORE_EXPORT unsigned webCoreCSSTokenizerSwiftDeclineCount(void)
{
    return CSSTokenizer::swiftIslandDeclineCountForTesting();
}

// Makes the Swift scanner fail every input, after it has built a chunk, so the
// failure-reporting path is reachable from a test. See
// CSSTokenizer::setForceSwiftIslandDeclineForTesting.
WEBCORE_EXPORT void webCoreCSSTokenizerSetForceSwiftIslandDecline(bool force)
{
    CSSTokenizer::setForceSwiftIslandDeclineForTesting(force);
}

// Whether tryCreate succeeded. There is no fallback: when the Swift scanner cannot
// allocate, construction fails, and this is how a test observes that rather than
// inferring it.
WEBCORE_EXPORT bool webCoreCSSTokenizerTryCreateSucceeds(const char* text, size_t length)
{
    String source { unsafeMakeSpan(byteCast<Latin1Character>(text), length) };
    return !!CSSTokenizer::tryCreate(source);
}

// Reports the compile-time choice, so a test can confirm that
// -DUSE_SWIFT_CSS_TOKENIZER=1 actually selects the Swift scanner rather than being
// silently ignored.
WEBCORE_EXPORT bool webCoreCSSTokenizerDefaultScannerIsSwift(void)
{
    return CSSTokenizer::defaultScanner == CSSTokenizer::Scanner::Swift;
}

// Times a whole CSSTokenizer construction on one path or the other. Same work on
// both sides at last: same tokens, same string pool, same double conversions.
WEBCORE_EXPORT void webCoreCSSTokenizerBenchIntegrated(const char* text, size_t length, bool useSwift, size_t* outTokens, uint64_t* outFold)
{
    String source { unsafeMakeSpan(byteCast<Latin1Character>(text), length) };
    WebCore::CSSTokenizer tokenizer(source, useSwift ? CSSTokenizer::Scanner::Swift : CSSTokenizer::Scanner::Cpp);
    size_t count = 0;
    uint64_t fold = 0;
    for (auto range = tokenizer.tokenRange(); !range.atEnd(); range.consume()) {
        ++count;
        fold = fold * 1000003 + static_cast<uint64_t>(range.peek().type());
    }
    *outTokens = count;
    *outFold = fold;
}

// The same timing at 16-bit width. Every other bench entry builds its String from Latin-1
// bytes, so all three were 8-bit-only and the Swift tokenizer's UInt16 specialization -- a
// separate body of generated code, reached by every stylesheet containing a character above
// U+00FF -- had never been timed at all, only checked for correctness.
//
// The source is upconverted rather than decoded: each input byte becomes one UTF-16 code
// unit, so the token stream is identical to the 8-bit entry's on the same input and the two
// widths are directly comparable on one corpus. Decoding UTF-8 instead would change the
// characters and therefore the tokens, which is right for a correctness oracle
// (comparePathsUTF8 does exactly that) and wrong for a throughput comparison.
// `outIs16Bit` reports what StringImpl actually chose, so a caller cannot assume a width it
// did not get -- a 16-bit measurement that quietly ran 8-bit would be the same invisible
// failure as a decline.
WEBCORE_EXPORT void webCoreCSSTokenizerBenchIntegrated16(const char* text, size_t length, bool useSwift, size_t* outTokens, uint64_t* outFold, bool* outIs16Bit)
{
    auto bytes = unsafeMakeSpan(byteCast<Latin1Character>(text), length);
    StringBuilder builder;
    builder.reserveCapacity(length + 4);
    for (auto byte : bytes)
        builder.append(static_cast<char16_t>(byte));
    // A run of pure Latin-1 would collapse back to 8-bit on toString(), so force the
    // 16-bit representation with a character that cannot be represented in 8 bits, in a
    // comment where it costs one token and no interned string. Appended as an explicit
    // char16_t rather than in a literal: a non-ASCII character in a WebKit string literal
    // breaks assertions builds.
    builder.append("/*"_s);
    builder.append(static_cast<char16_t>(0x2028));
    builder.append("*/"_s);
    String source = builder.toString();

    WebCore::CSSTokenizer tokenizer(source, useSwift ? CSSTokenizer::Scanner::Swift : CSSTokenizer::Scanner::Cpp);
    size_t count = 0;
    uint64_t fold = 0;
    for (auto range = tokenizer.tokenRange(); !range.atEnd(); range.consume()) {
        ++count;
        fold = fold * 1000003 + static_cast<uint64_t>(range.peek().type());
    }
    *outTokens = count;
    *outFold = fold;
    *outIs16Bit = !source.is8Bit();
}

// MARK: - The CSS unit-type trie
//
// CSSUnitTrieSwift.swift is a transcription of cssPrimitiveValueUnitFromTrie. These two entries
// compare it against the C++ original linked into this same framework, packed into one call so
// there is no way to pair a C++ answer for one input against a Swift answer for another.
//
// The Swift side is reached through the generated header's thunk, with parameters packed into
// 64-bit words: a Swift *callee* cannot take a Span (the `__counted_by` plus `noescape` recipe
// only works for a caller), and the alternatives all need an `unsafe` marker in a file that has
// none.

static std::atomic<uint64_t> s_unitTrieCxxCalls;

// The cap the Swift entries enforce with a precondition. Reported rather than duplicated, so
// the harness cannot quietly sweep longer strings than the entry point can carry.
static constexpr size_t maximumUnitTrieLength = 16;

WEBCORE_EXPORT size_t webCoreCSSTokenizerUnitTrieMaximumLength(void)
{
    return maximumUnitTrieLength;
}

WEBCORE_EXPORT uint64_t webCoreCSSTokenizerUnitTrieCxxCallCount(void)
{
    return s_unitTrieCxxCalls.load(std::memory_order_relaxed);
}

// Returns (C++ unit << 8) | Swift unit. Both are CSSUnitType underlying values; Unknown is 0.
WEBCORE_EXPORT uint32_t webCoreCSSTokenizerUnitTrieCompare8(const uint8_t* data, size_t length)
{
    RELEASE_ASSERT(length <= maximumUnitTrieLength);
    auto text = unsafeMakeSpan(byteCast<Latin1Character>(data), length);
    s_unitTrieCxxCalls.fetch_add(1, std::memory_order_relaxed);
    auto cppUnit = static_cast<uint32_t>(CSSParserToken::stringToUnitType(StringView { text }));

    std::array<uint64_t, 2> packed { 0, 0 };
    for (size_t i = 0; i < length; ++i)
        packed[i / 8] |= static_cast<uint64_t>(text[i]) << (8 * (i % 8));
    auto swiftUnit = static_cast<uint32_t>(cssUnitTrieSwiftLookup8(packed[0], packed[1], static_cast<ptrdiff_t>(length)));

    return (cppUnit << 8) | swiftUnit;
}

// Same, at 16-bit width. StringView built from a char16_t span keeps its 16-bit
// representation whatever the text is, which is the only way to reach the C++ template's
// char16_t instantiation on Latin-1 content -- a String built from Latin-1 bytes never would.
WEBCORE_EXPORT uint32_t webCoreCSSTokenizerUnitTrieCompare16(const uint16_t* data, size_t length)
{
    RELEASE_ASSERT(length <= maximumUnitTrieLength);
    auto text = unsafeMakeSpan(reinterpret_cast<const char16_t*>(data), length);
    s_unitTrieCxxCalls.fetch_add(1, std::memory_order_relaxed);
    auto cppUnit = static_cast<uint32_t>(CSSParserToken::stringToUnitType(StringView { text }));

    std::array<uint64_t, 4> packed { 0, 0, 0, 0 };
    for (size_t i = 0; i < length; ++i)
        packed[i / 4] |= static_cast<uint64_t>(text[i]) << (16 * (i % 4));
    auto swiftUnit = static_cast<uint32_t>(cssUnitTrieSwiftLookup16(packed[0], packed[1], packed[2], packed[3], static_cast<ptrdiff_t>(length)));

    return (cppUnit << 8) | swiftUnit;
}

// MARK: - Color fast-path comparison entries (CSSParserFastPathsSwift.swift)
//
// Both scanners run on the same input in one call, so a C++ answer for one candidate can never be
// paired with a Swift answer for another; this also halves the cross-library call count for a
// sweep over every 3/4/6-digit hex string and all 152 named colours.
//
// Each side names its scanner explicitly rather than using the build default, so the comparison
// is meaningful regardless of WK_USE_SWIFT_CSS_COLOR_FAST_PATHS. `webCoreCSSColorFastPathsAreSwift`
// reports the default separately.

// Both scanners' answers for one candidate. `found` is 0 or 1; `argb` is meaningful only when
// `found`, and is zeroed otherwise so a whole-struct comparison cannot pass on garbage.
struct CSSColorSwiftComparison {
    uint32_t cppARGB;
    uint32_t swiftARGB;
    uint8_t cppFound;
    uint8_t swiftFound;
};

// Which fast path to compare. Mirrors the three public entry points.
enum CSSColorSwiftScanKind : unsigned {
    CSSColorSwiftScanHex = 0,
    CSSColorSwiftScanNamed = 1,
    CSSColorSwiftScanSimple = 2,
};

WEBCORE_EXPORT CSSColorSwiftComparison webCoreCSSColorCompare(const uint16_t*, size_t, unsigned characterSize, unsigned kind, bool quirksMode);
WEBCORE_EXPORT bool webCoreCSSColorFastPathsAreSwift(void);
WEBCORE_EXPORT void webCoreCSSColorSetForceDecline(bool);
WEBCORE_EXPORT unsigned webCoreCSSColorDeclineCount(void);
WEBCORE_EXPORT uint64_t webCoreCSSColorCallCount(void);
WEBCORE_EXPORT size_t webCoreCSSColorTextCapacity(void);
WEBCORE_EXPORT uint64_t webCoreCSSColorBench(const uint16_t*, size_t, unsigned characterSize, unsigned kind, bool quirksMode, bool useSwift, uint64_t repetitions);

// How many times WebCore was actually asked to scan a color, so a caller can confirm its sweep
// really reached this code rather than being elided or miscounted.
static std::atomic<uint64_t> s_colorScanCalls;

static std::optional<SRGBA<uint8_t>> scanOneColor(StringView text, unsigned kind, const CSSParserContext& context, CSSParserFastPaths::ColorScanner scanner)
{
    switch (kind) {
    case CSSColorSwiftScanHex:
        return CSSParserFastPaths::parseHexColor(text, scanner);
    case CSSColorSwiftScanNamed:
        return CSSParserFastPaths::parseNamedColor(text, scanner);
    default:
        return CSSParserFastPaths::parseSimpleColor(text, context, scanner);
    }
}

// The two contexts, built once. A `CSSParserContext` carries a URL and a settings snapshot, and
// constructing one per call would dominate a sweep that makes tens of millions of them.
// Function-local statics rather than globals because WebCore links with -no_inits.
static const CSSParserContext& colorScanContext(bool quirksMode)
{
    static NeverDestroyed<CSSParserContext> quirks { HTMLQuirksMode };
    static NeverDestroyed<CSSParserContext> standard { HTMLStandardMode };
    return quirksMode ? quirks.get() : standard.get();
}

// Runs `kind` both ways over the same characters. `characterSize` picks which of StringImpl's
// two representations the StringView carries: passing 1 narrows 16-bit input to 8-bit first,
// which is the only way to reach the 8-bit template instantiation for text that would otherwise
// have been stored 8-bit anyway.
WEBCORE_EXPORT CSSColorSwiftComparison webCoreCSSColorCompare(const uint16_t* units, size_t length, unsigned characterSize, unsigned kind, bool quirksMode)
{
    s_colorScanCalls.fetch_add(1, std::memory_order_relaxed);

    auto wide = unsafeMakeSpan(reinterpret_cast<const char16_t*>(units), length);
    auto& context = colorScanContext(quirksMode);

    std::optional<SRGBA<uint8_t>> cpp;
    std::optional<SRGBA<uint8_t>> swift;
    if (characterSize == 1) {
        std::array<Latin1Character, 256> narrowed;
        RELEASE_ASSERT(length <= narrowed.size());
        for (size_t i = 0; i < length; ++i) {
            RELEASE_ASSERT(wide[i] < 256);
            narrowed[i] = static_cast<Latin1Character>(wide[i]);
        }
        auto narrow = std::span<const Latin1Character> { narrowed }.first(length);
        cpp = scanOneColor(StringView { narrow }, kind, context, CSSParserFastPaths::ColorScanner::Cpp);
        swift = scanOneColor(StringView { narrow }, kind, context, CSSParserFastPaths::ColorScanner::Swift);
    } else {
        cpp = scanOneColor(StringView { wide }, kind, context, CSSParserFastPaths::ColorScanner::Cpp);
        swift = scanOneColor(StringView { wide }, kind, context, CSSParserFastPaths::ColorScanner::Swift);
    }

    return CSSColorSwiftComparison {
        cpp ? PackedColor::ARGB { *cpp }.value : 0u,
        swift ? PackedColor::ARGB { *swift }.value : 0u,
        static_cast<uint8_t>(cpp ? 1 : 0),
        static_cast<uint8_t>(swift ? 1 : 0),
    };
}

// The compile-time default, so a build that ignored WK_USE_SWIFT_CSS_COLOR_FAST_PATHS cannot
// pass as one that honoured it.
WEBCORE_EXPORT bool webCoreCSSColorFastPathsAreSwift(void)
{
    return CSSParserFastPaths::defaultColorScanner == CSSParserFastPaths::ColorScanner::Swift;
}

// Forces every comparison to report a decline, so the C++ fall-through path actually runs. With
// nothing declining otherwise, that fall-through would ship untested.
WEBCORE_EXPORT void webCoreCSSColorSetForceDecline(bool force)
{
    webCoreCSSColorFastPathSetForceDecline(force);
}

WEBCORE_EXPORT unsigned webCoreCSSColorDeclineCount(void)
{
    return webCoreCSSColorFastPathDeclineCount();
}

WEBCORE_EXPORT uint64_t webCoreCSSColorCallCount(void)
{
    return s_colorScanCalls.load(std::memory_order_relaxed);
}

// Reported here rather than duplicated by the caller, so a caller cannot silently understate the
// buffer capacity it claims to have exercised.
WEBCORE_EXPORT size_t webCoreCSSColorTextCapacity(void)
{
    return cssSwiftColorTextCapacity;
}

// One scanner, timed. The `CSSParserContext` and the character narrowing are hoisted out of the
// loop so that what is timed is the scan, and the checksum is returned so the loop cannot be
// optimized away -- the same arrangement as webCoreCSSTokenizerBenchIntegrated above.
WEBCORE_EXPORT uint64_t webCoreCSSColorBench(const uint16_t* units, size_t length, unsigned characterSize, unsigned kind, bool quirksMode, bool useSwift, uint64_t repetitions)
{
    auto wide = unsafeMakeSpan(reinterpret_cast<const char16_t*>(units), length);
    auto& context = colorScanContext(quirksMode);
    auto scanner = useSwift ? CSSParserFastPaths::ColorScanner::Swift : CSSParserFastPaths::ColorScanner::Cpp;

    std::array<Latin1Character, 256> narrowed;
    RELEASE_ASSERT(length <= narrowed.size());
    for (size_t i = 0; i < length; ++i)
        narrowed[i] = static_cast<Latin1Character>(wide[i] & 0xFF);
    auto narrow = std::span<const Latin1Character> { narrowed }.first(length);

    uint64_t checksum = 0;
    for (uint64_t i = 0; i < repetitions; ++i) {
        auto result = characterSize == 1
            ? scanOneColor(StringView { narrow }, kind, context, scanner)
            : scanOneColor(StringView { wide }, kind, context, scanner);
        checksum = checksum * 31 + (result ? PackedColor::ARGB { *result }.value : 1u);
    }
    return checksum;
}

// MARK: - calc() serialization comparison entries (CSSCalcSerializationSwift.swift)
//
// `CSSCalc::serializationForCSS` is a pure `(Tree, Range, SerializationContext) -> String`: parse a
// calc expression, serialize the resulting tree both ways, compare. Both arms run on the same
// `Tree` object inside one call, so a C++ answer for one expression can never be paired with a
// Swift answer for another.
//
// The serializer is named explicitly on each side rather than taken from the build default, so the
// comparison holds regardless of WK_USE_SWIFT_CSS_CALC_SERIALIZATION.
// `webCoreCSSCalcSerializationIsSwift` reports the default separately.

// One expression's worth of comparison, plus fields that let a caller confirm the comparison
// actually exercised the Swift path.
struct CSSCalcSerializationComparison {
    // 1 if the text parsed as a calc value at some category. 0 means the case exercised nothing.
    uint32_t parsed;
    // 1 if the two serializations are byte-identical.
    uint32_t agree;
    // 1 if the Swift path declined this tree, so "agree" below is the C++ compared against itself.
    uint32_t declined;
    // How many nodes the Swift walk visited and which kinds it stood on, so a caller can confirm
    // the walk actually descended into the tree rather than stopping at the root.
    uint32_t nodeCount;
    uint32_t kindMask;
    uint32_t cppLength;
    uint32_t swiftLength;
    // Which CSS::Category the expression parsed at, so the harness can report the spread rather
    // than assume one.
    uint32_t category;
    // The kind of the tree's ROOT, which the mask above cannot answer: the mask says a `Negate` was
    // somewhere in the tree, but not whether it was the root, which is the one position where the
    // C++ drops step 4's `-1 * ` prefix.
    uint32_t rootKind;
};

WEBCORE_EXPORT CSSCalcSerializationComparison webCoreCSSCalcCompareSerialization(const char*, size_t, char*, size_t, char*, size_t);
WEBCORE_EXPORT CSSCalcSerializationComparison webCoreCSSCalcCompareSerializationStaged(const char*, size_t, unsigned, double, double, char*, size_t, char*, size_t);
WEBCORE_EXPORT uint32_t webCoreCSSCalcRoundTrip(const char*, size_t, unsigned, char*, size_t, char*, size_t);
WEBCORE_EXPORT bool webCoreCSSCalcSerializationIsSwift(void);
WEBCORE_EXPORT void webCoreCSSCalcSetForceDecline(bool);
WEBCORE_EXPORT unsigned webCoreCSSCalcDeclineCount(void);
WEBCORE_EXPORT uint64_t webCoreCSSCalcSwiftCallCount(void);
WEBCORE_EXPORT uint64_t webCoreCSSCalcHarnessCallCount(void);
WEBCORE_EXPORT uint32_t webCoreCSSCalcNodeKindCount(void);
WEBCORE_EXPORT uint32_t webCoreCSSCalcSerializeConstructedRoot(unsigned, unsigned, char*, size_t);

// How many times WebCore was actually asked to compare, so a caller can confirm its sweep really
// reached this code rather than being elided or miscounted.
static std::atomic<uint64_t> s_calcCompareCalls;

// Reported here rather than duplicated by the caller, so a claim of reaching every node kind can't
// be checked against a stale count.
WEBCORE_EXPORT uint32_t webCoreCSSCalcNodeKindCount(void)
{
    // The LAST case, so adding a kind without updating this line silently under-reports the count.
    return static_cast<uint32_t>(CSSCalc::CSSCalcSwiftNodeKind::AnchorSizeFunction) + 1;
}

// Serializes one of the four directly-constructed root shapes, on the named arm. Returns the length,
// or 0 if the leaf could not be parsed. See `constructRootShape` for what this settles and why a
// parse cannot settle it.
WEBCORE_EXPORT uint32_t webCoreCSSCalcSerializeConstructedRoot(unsigned shape, unsigned serializerKind, char* out, size_t capacity)
{
    auto tree = constructRootShape(shape);
    if (!tree)
        return 0;
    auto options = CSSCalc::SerializationOptions {
        .range = WebCore::CSS::All,
        .serializationContext = WebCore::CSS::defaultSerializationContext(),
    };
    auto text = CSSCalc::serializationForCSS(*tree, options,
        serializerKind ? CSSCalc::Serializer::Swift : CSSCalc::Serializer::Cpp);
    return static_cast<uint32_t>(copyOutSerialization(text, out, capacity));
}

// Serializes one tree both ways and compares. The two arms see the same `Tree` object, in this
// order, in this call.
WEBCORE_EXPORT CSSCalcSerializationComparison webCoreCSSCalcCompareSerialization(const char* text, size_t length, char* cppOut, size_t cppCapacity, char* swiftOut, size_t swiftCapacity)
{
    s_calcCompareCalls.fetch_add(1, std::memory_order_relaxed);

    CSSCalcSerializationComparison result { 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    String source { unsafeMakeSpan(byteCast<Latin1Character>(text), length) };

    auto parsed = parseCalcExpression(source);
    if (!parsed.tree)
        return result;

    result.parsed = 1;
    result.category = static_cast<uint32_t>(parsed.category);

    auto options = CSSCalc::SerializationOptions {
        .range = parsed.range,
        .serializationContext = WebCore::CSS::defaultSerializationContext(),
    };

    auto declinesBefore = CSSCalc::webCoreCSSCalcSerializationDeclineCount();
    auto cppText = CSSCalc::serializationForCSS(*parsed.tree, options, CSSCalc::Serializer::Cpp);
    auto swiftText = CSSCalc::serializationForCSS(*parsed.tree, options, CSSCalc::Serializer::Swift);
    auto declinesAfter = CSSCalc::webCoreCSSCalcSerializationDeclineCount();

    result.declined = declinesAfter != declinesBefore ? 1 : 0;
    result.nodeCount = CSSCalc::webCoreCSSCalcSerializationLastNodeCount();
    result.kindMask = CSSCalc::webCoreCSSCalcSerializationLastKindMask();
    result.rootKind = CSSCalc::webCoreCSSCalcSerializationLastRootKind();
    result.agree = cppText == swiftText ? 1 : 0;
    result.cppLength = static_cast<uint32_t>(copyOutSerialization(cppText, cppOut, cppCapacity));
    result.swiftLength = static_cast<uint32_t>(copyOutSerialization(swiftText, swiftOut, swiftCapacity));
    return result;
}

// The same comparison at a caller-chosen `Stage` and `CSS::Range`.
//
// A parse always produces `Stage::Specified`; `Stage::Computed` is written in exactly one place in
// WebCore, StyleCalculationTree+Conversion.cpp:357 (`toCSS`, the getComputedStyle path), which
// needs a `Style::Calculation::Tree` and the conversion data this entry does not have. So the
// stage is set directly on an already-parsed tree: both serializers run over the same `Tree`
// object regardless of how it was built.
//
// The stage only changes serialization for a numeric root, so this only tests something if the
// root is one. `constructRootShape`'s `calc(1px)` might look like it parses to a one-child `Sum`
// wrapping the leaf, but `parseAndSimplify` folds that wrapper away, landing on a numeric root
// directly. `Expect::Leaf` below asserts `nodeCount == 1` and a numeric `rootKind` rather than
// assuming it.
WEBCORE_EXPORT CSSCalcSerializationComparison webCoreCSSCalcCompareSerializationStaged(const char* text, size_t length, unsigned computedStage, double rangeMinimum, double rangeMaximum, char* cppOut, size_t cppCapacity, char* swiftOut, size_t swiftCapacity)
{
    s_calcCompareCalls.fetch_add(1, std::memory_order_relaxed);

    CSSCalcSerializationComparison result { 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    String source { unsafeMakeSpan(byteCast<Latin1Character>(text), length) };

    auto parsed = parseCalcExpression(source);
    if (!parsed.tree)
        return result;

    // The parsed tree with only its stage replaced. Rebuilt rather than mutated in place because
    // `Tree::stage` is not something a caller of `parseCalcExpression` should be able to reach
    // through the returned object.
    auto tree = CSSCalc::Tree {
        .root = WTF::move(parsed.tree->root),
        .type = parsed.tree->type,
        .stage = computedStage ? CSSCalc::Stage::Computed : CSSCalc::Stage::Specified,
    };

    result.parsed = 1;
    result.category = static_cast<uint32_t>(parsed.category);

    auto options = CSSCalc::SerializationOptions {
        .range = WebCore::CSS::Range { rangeMinimum, rangeMaximum },
        .serializationContext = WebCore::CSS::defaultSerializationContext(),
    };

    auto declinesBefore = CSSCalc::webCoreCSSCalcSerializationDeclineCount();
    auto cppText = CSSCalc::serializationForCSS(tree, options, CSSCalc::Serializer::Cpp);
    auto swiftText = CSSCalc::serializationForCSS(tree, options, CSSCalc::Serializer::Swift);
    auto declinesAfter = CSSCalc::webCoreCSSCalcSerializationDeclineCount();

    result.declined = declinesAfter != declinesBefore ? 1 : 0;
    result.nodeCount = CSSCalc::webCoreCSSCalcSerializationLastNodeCount();
    result.kindMask = CSSCalc::webCoreCSSCalcSerializationLastKindMask();
    result.rootKind = CSSCalc::webCoreCSSCalcSerializationLastRootKind();
    result.agree = cppText == swiftText ? 1 : 0;
    result.cppLength = static_cast<uint32_t>(copyOutSerialization(cppText, cppOut, cppCapacity));
    result.swiftLength = static_cast<uint32_t>(copyOutSerialization(swiftText, swiftOut, swiftCapacity));
    return result;
}

// The spec gives a reference-free check for free: serialization must be idempotent under
// reparsing, i.e. serialize(parse(s)) == serialize(parse(serialize(parse(s)))). This can fail even
// when the C++ and Swift serializers agree with each other -- a shared misreading of the spec
// would pass a bare comparison between them but not this.
//
// `serializerKind` is 0 for C++ and 1 for Swift, so the property can be checked for each
// independently. Returns 0 stable, 1 first parse failed, 2 reparse failed, 3 unstable.
WEBCORE_EXPORT uint32_t webCoreCSSCalcRoundTrip(const char* text, size_t length, unsigned serializerKind, char* firstOut, size_t firstCapacity, char* secondOut, size_t secondCapacity)
{
    auto serializer = serializerKind ? CSSCalc::Serializer::Swift : CSSCalc::Serializer::Cpp;
    String source { unsafeMakeSpan(byteCast<Latin1Character>(text), length) };

    auto first = parseCalcExpression(source);
    if (!first.tree)
        return 1;
    auto firstOptions = CSSCalc::SerializationOptions {
        .range = first.range,
        .serializationContext = WebCore::CSS::defaultSerializationContext(),
    };
    auto firstText = CSSCalc::serializationForCSS(*first.tree, firstOptions, serializer);
    copyOutSerialization(firstText, firstOut, firstCapacity);

    auto second = parseCalcExpression(firstText);
    if (!second.tree)
        return 2;
    auto secondOptions = CSSCalc::SerializationOptions {
        .range = second.range,
        .serializationContext = WebCore::CSS::defaultSerializationContext(),
    };
    auto secondText = CSSCalc::serializationForCSS(*second.tree, secondOptions, serializer);
    copyOutSerialization(secondText, secondOut, secondCapacity);

    return firstText == secondText ? 0 : 3;
}

// The compile-time default, so a build that ignored WK_USE_SWIFT_CSS_CALC_SERIALIZATION cannot pass
// as one that honoured it.
WEBCORE_EXPORT bool webCoreCSSCalcSerializationIsSwift(void)
{
    return CSSCalc::defaultSerializer == CSSCalc::Serializer::Swift;
}

// Forces the Swift path to decline every tree, so the C++ fall-through runs even with the gate on.
// A fall-through that is reachable only by input eventually ships untested.
WEBCORE_EXPORT void webCoreCSSCalcSetForceDecline(bool force)
{
    CSSCalc::webCoreCSSCalcSerializationSetForceDecline(force);
}

WEBCORE_EXPORT unsigned webCoreCSSCalcDeclineCount(void)
{
    return CSSCalc::webCoreCSSCalcSerializationDeclineCount();
}

WEBCORE_EXPORT uint64_t webCoreCSSCalcSwiftCallCount(void)
{
    return CSSCalc::webCoreCSSCalcSerializationSwiftCallCount();
}

WEBCORE_EXPORT uint64_t webCoreCSSCalcHarnessCallCount(void)
{
    return s_calcCompareCalls.load(std::memory_order_relaxed);
}

// MARK: - calc() simplification comparison entries (CSSCalcSimplificationSwift.swift)
//
// A sibling of the serialization block above, not an extension of it: the oracle differs.
// Serialization is `Tree -> String`, so comparing two strings needed no extra machinery.
// Simplification is `Tree -> Tree`, so every field below exists because a tree comparison has
// failure modes a string comparison does not.
//
// The non-obvious part: `parseAndSimplify` runs simplification incrementally during the parse, with
// the same `SimplificationOptions`, at EIGHTEEN per-operation `simplify(Op&, ...)` sites in
// CSSCalcTree+Parser.cpp (`:251` `:261` `:323` `:378` `:407` `:449` `:555` `:584` `:623` `:747`
// `:802` `:884` `:997` `:1423` `:1451` `:1489` `:1517` `:1592`) plus one `copyAndSimplify(const
// Child&)` at `:1638`, and it has no terminal whole-tree pass. (This comment said "22 sites" for
// five slices; the count was never checked and the enumeration above is
// webkit-swift-ports/cssprobe/notes/calc-deletable-callers-0908.md section 1.1's.) A parsed tree is
// therefore already at a fixed point for the options it was parsed with, so handing it back to
// `copyAndSimplify` with those same options is the identity on essentially every case. Entry 1
// parses at a fixed baseline -- `parseCalcExpression`'s options, the production ones from
// CSSUnevaluatedCalc.cpp:167 -- and simplifies under a caller-supplied set instead, so that when the
// two differ in a way simplification reads, real work happens.
//
// AND THAT IS A DIFFERENT AXIS FROM THE ONE THE FIXED POINT HIDES. Sweeping the OPTIONS gets real
// work out of a pre-simplified tree; it does not get an UNSIMPLIFIED tree.
// `CSSCalc::ParseSimplification::None` is the second value of that axis, and it is also the
// production gate P7b stage A introduces -- the seam and the shipping change are the same change.

// The swept options, passed by pointer rather than as nine scalars so that an axis can be added
// without re-spelling the signature of every entry in four places.
struct CSSCalcSimplificationOptionsSpec {
    // Ordinal of `WebCore::CSS::Category`, 0..10, in declaration order.
    uint32_t category;
    double rangeMinimum;
    double rangeMaximum;
    // 0 none, 1 a style at 16px, 2 the same at 32px, 3 the 16px style with a live
    // `Style::BuilderState`, 4 the 32px style with one. Kinds 3 and 4 are the only ones at which
    // `SiblingCount`, `SiblingIndex`, `Random`, `Anchor` and `AnchorSize` do anything at all.
    uint32_t conversionDataKind;
    // 0 empty, 1 num, 2 px, 3 NaN, 4 +inf, 5 -inf, 6 -0, 7 subnormal, 8 INT_MAX.
    uint32_t symbolTableKind;
    uint32_t allowZeroValueLengthRemovalFromSum;
    // 0 Stage::Specified, 1 Stage::Computed, applied to the parsed tree before simplifying.
    uint32_t stage;
    // `CSSCalc::ParseSimplification` as a `uint32_t`: 0 Eager, 1 Terminal, 2 None. Only 0 and 2 are
    // used by entry 1 -- 0 is the historical behaviour, and 2 is the UNSIMPLIFIED-TREE AXIS.
    //
    // THIS IS AN AXIS, NOT A MODE, and it is the axis this differential never varied: the comment
    // above says a parsed tree "is therefore already at a fixed point", and entry 1's answer was to
    // sweep the OPTIONS instead. That is a different axis. Nine corpora at one parameter value is
    // corpus coverage, not parameter coverage -- the content-extensions failure exactly.
    //
    // Entry 1 does NOT pass 1 (`Terminal`), and that is deliberate rather than an omission: under
    // `None` the harness gets the raw tree and `compareSimplificationOfTree` runs BOTH simplifier
    // arms on that one object, which is what makes it impossible to pair a C++ answer for one case
    // with a Swift answer for another. Its `Simplifier::Cpp` result IS the `Terminal` tree, so
    // comparison (a) -- eager against terminal, both C++ -- comes out of the same call as comparison
    // (b) and neither costs a third parse.
    //
    // Appended last on purpose. A harness built against the old layout passes a 40-byte struct and
    // this field reads whatever follows it, which is why the harness keys "the arm is real" on
    // entry 13's PRESENCE and never on this field.
    uint32_t parseSimplification;
};

// One case's worth of comparison. Mirrored field-for-field by `struct Comparison` in
// simplifycheck.cpp; the order is ABI and the two must be edited together.
struct CSSCalcSimplificationComparison {
    uint32_t parsed;
    // The Swift side's decision, and -- when it declined -- the alternative that caused it. 0xFF
    // means it declined without naming one, which is treated as a failure whenever the tree does
    // contain an unhandled alternative.
    uint32_t declined;
    uint32_t declineKind;
    // (a) the verdict: deep, bitwise over leaf doubles, plus every `Type`, the stage and the
    // conversion-data flag. The only one of the three that can see a signed zero.
    uint32_t agree;
    // (b) `Tree::operator==`, defaulted. Reported beside (a) rather than instead of it, since it
    // disagrees in two directions -- too strict on NaN, too weak on signed zero.
    uint32_t agreeDefaulted;
    // (c) both result trees through the C++ serializer, on both sides, so a defect in
    // serialization cannot be mistaken for one here. Diagnostic only.
    uint32_t agreeSerialized;
    uint32_t containsNaN;
    uint32_t cppChangedInput;
    uint32_t swiftChangedInput;
    uint32_t cppIdempotent;
    uint32_t swiftIdempotent;
    uint32_t cppCanSimplify;
    uint32_t swiftCanSimplify;
    // `canSimplify(t) == false` really implied `copyAndSimplify(t) == t`. The check with
    // information in it, since `canSimplify` itself is one bit per tree.
    uint32_t cppCanSimplifySound;
    uint32_t swiftCanSimplifySound;
    uint32_t cppPreservedStageAndFlag;
    uint32_t swiftPreservedStageAndFlag;
    uint32_t inputNodeCount;
    uint32_t outputNodeCount;
    uint32_t inputRootKind;
    uint32_t outputRootKind;
    uint32_t parseCategory;
    // 41-bit masks over `Node` alternative indices. The Swift side's must be a subset of the
    // input's, and equal to it on any case it did not decline.
    uint64_t inputKindMask;
    uint64_t islandKindMask;
    uint32_t cppLength;
    uint32_t swiftLength;
    // Did this side call `BuilderState::setCurrentPropertyInvalidAtComputedValueTime()`?
    //
    // The only observable effect of `simplify(Anchor&)` and `simplify(AnchorSize&)` on a node with
    // no fallback. Both return `std::exchange(node.fallback, { })`, which is `nullopt` when there is
    // no fallback -- indistinguishable in the output tree from the answer every case gave before
    // conversion-data kinds 3 and 4 existed. Without this field, `anchor(top)` would look tested
    // without actually being tested. Read after each run from a freshly created builder state; see
    // `resetSimplificationBuilderStates`.
    uint32_t cppInvalidAtComputedValueTime;
    uint32_t swiftInvalidAtComputedValueTime;

    // THE SIX PHASE-U FIELDS. Written only when `spec->parseSimplification == None` is set.
    //
    // WHY THE BASELINE HALF IS COMPUTED HERE AND NOT BY A SECOND CALL FROM THE HARNESS. Two calls
    // would work and would be wrong three ways: the harness's guard 2 (call tally) and guard 11
    // (decline tally) would both need a phase-specific exemption; the two parses would be two
    // unrelated `Tree` objects, so nothing stronger than a string comparison would be available
    // across them; and `bitwiseEqualTree` -- the only oracle in this differential that can see a
    // signed zero or a per-node `Type` -- takes two live trees and lives on this side. One extra
    // parse buys a BITWISE guard 19 instead of a textual one.
    uint64_t baselineKindMask;
    // A `Sum` directly under a `Sum`, or a `Product` directly under a `Product`, anywhere in the
    // input. css-values-4 step 8.1 / 9.1 -- the splice at CSSCalcTree+Simplification.cpp:555 and
    // :744, and `CalcFlatTree.spliceNestedChildren` on the Swift side -- is the only thing that acts
    // on that shape, and a PRE-SIMPLIFIED parse cannot present one, because the inner node was
    // spliced at its own `simplify` call. So this is 0 for every case the differential ran before
    // phase U, and it is what makes negative control NC-4's required mismatch count exact.
    uint32_t inputHasSpliceableNesting;
    // Did the same text parse at the BASELINE (eager simplification on)? The harness's guard 18
    // asserts this equals `parsed`: suppressing simplification must change the tree and never the
    // parse, because the parse-time type is computed from the unsimplified children in both arms and
    // a folded replacement carries `*outputType` unchanged.
    uint32_t baselineParsed;
    uint32_t baselineNodeCount;
    uint32_t baselineRootKind;
    // `bitwiseEqualTree(copyAndSimplify(unsimplifiedTree, swept, Cpp), baselineParsedTree)`. At the
    // baseline tuple this is the entire test of "the parser's 18 eager `simplify(Op&)` sites and one
    // terminal whole-tree `copyAndSimplify` compute the same thing" -- the measurement
    // webkit-swift-ports/cssprobe/notes/calc-deletable-callers-0908.md section 10 item 9 asks for and
    // has never had. Meaningless at a swept tuple, where the two are simplified under different
    // options; the harness reads it at the baseline tuple only.
    uint32_t eagerMatchesWholeTree;
    // Was `eagerMatchesWholeTree` actually computed? It is written by ENTRY 1 ONLY, and only when a
    // baseline tree exists, so a zero in the field above has two meanings and the harness must not
    // read the wrong one. Guard 19 asserts this is set on every case it counts -- without it, a
    // build in which the computation was skipped reports "0 failures" and reads as a pass.
    uint32_t eagerTerminalComputed;
};

// The layout is pinned rather than merely described. These two structs cross a `dlsym` boundary
// into a caller that declares its own copies; a field inserted on one side and not the other does
// not fail to link, it silently shifts every field after it, so a mismatch would compare unrelated
// fields against each other without any diagnostic.
static_assert(sizeof(CSSCalcSimplificationOptionsSpec) == 48);
static_assert(offsetof(CSSCalcSimplificationOptionsSpec, rangeMinimum) == 8);
static_assert(offsetof(CSSCalcSimplificationOptionsSpec, conversionDataKind) == 24);
static_assert(offsetof(CSSCalcSimplificationOptionsSpec, stage) == 36);
static_assert(offsetof(CSSCalcSimplificationOptionsSpec, parseSimplification) == 40);
// `eagerTerminalComputed` lands in what was tail padding, so the size is UNCHANGED at 152 and a
// harness built against the previous layout would still link and still read every other field
// correctly. That is precisely why the offset is asserted too: size alone would not have noticed.
static_assert(sizeof(CSSCalcSimplificationComparison) == 152);
static_assert(offsetof(CSSCalcSimplificationComparison, parseCategory) == 84);
static_assert(offsetof(CSSCalcSimplificationComparison, inputKindMask) == 88);
static_assert(offsetof(CSSCalcSimplificationComparison, islandKindMask) == 96);
static_assert(offsetof(CSSCalcSimplificationComparison, cppLength) == 104);
static_assert(offsetof(CSSCalcSimplificationComparison, swiftLength) == 108);
static_assert(offsetof(CSSCalcSimplificationComparison, cppInvalidAtComputedValueTime) == 112);
static_assert(offsetof(CSSCalcSimplificationComparison, swiftInvalidAtComputedValueTime) == 116);
static_assert(offsetof(CSSCalcSimplificationComparison, baselineKindMask) == 120);
static_assert(offsetof(CSSCalcSimplificationComparison, inputHasSpliceableNesting) == 128);
static_assert(offsetof(CSSCalcSimplificationComparison, baselineParsed) == 132);
static_assert(offsetof(CSSCalcSimplificationComparison, baselineNodeCount) == 136);
static_assert(offsetof(CSSCalcSimplificationComparison, baselineRootKind) == 140);
static_assert(offsetof(CSSCalcSimplificationComparison, eagerMatchesWholeTree) == 144);
static_assert(offsetof(CSSCalcSimplificationComparison, eagerTerminalComputed) == 148);

WEBCORE_EXPORT CSSCalcSimplificationComparison webCoreCSSCalcCompareSimplification(const char*, size_t, const CSSCalcSimplificationOptionsSpec*, char*, size_t, char*, size_t);
WEBCORE_EXPORT CSSCalcSimplificationComparison webCoreCSSCalcCompareSimplificationConstructed(unsigned, const CSSCalcSimplificationOptionsSpec*, char*, size_t, char*, size_t);
WEBCORE_EXPORT bool webCoreCSSCalcSimplificationIsSwift(void);
WEBCORE_EXPORT void webCoreCSSCalcSimplificationSetForceDecline(bool);
WEBCORE_EXPORT unsigned webCoreCSSCalcSimplificationDeclineCount(void);
WEBCORE_EXPORT unsigned webCoreCSSCalcSimplificationIslandDeclineCount(void);
WEBCORE_EXPORT uint64_t webCoreCSSCalcSimplificationHarnessCallCount(void);
WEBCORE_EXPORT uint32_t webCoreCSSCalcChildAlternativeCount(void);
WEBCORE_EXPORT uint32_t webCoreCSSCalcCategoryCount(void);
WEBCORE_EXPORT uint32_t webCoreCSSCalcConstructedShapeCount(void);
WEBCORE_EXPORT uint64_t webCoreCSSCalcSimplificationBench(const char*, size_t, bool, uint32_t, uint32_t*);
WEBCORE_EXPORT uint64_t webCoreCSSCalcSimplificationPrimitiveBench(uint32_t, uint32_t);
WEBCORE_EXPORT bool webCoreCSSCalcSimplificationFontMetricsAvailable(void);
WEBCORE_EXPORT bool webCoreCSSCalcSimplificationBuilderStateAvailable(void);
WEBCORE_EXPORT unsigned webCoreCSSCalcSimplificationFixtureSiblingCount(void);
WEBCORE_EXPORT unsigned webCoreCSSCalcSimplificationFixtureSiblingIndex(void);

// ENTRY 13. Does this WebCore understand `CSSCalcSimplificationOptionsSpec::parseSimplification`?
//
// Its ABSENCE is the only thing that can tell the harness apart from the one state that would make
// its unsimplified-tree arm silently vacuous: a framework built before that field existed still
// exports entry 1, still reads the first 40 bytes of the spec, ignores the flag, and hands back a
// comparison over a tree the C++ already simplified. Phase U would then run, agree on everything,
// and report as passing while re-measuring the axis value phases A-H already cover. So the harness
// dlsym's this separately and does not run phase U at all when it is missing -- the same shape as
// entries 10 and 10b, for the opposite reason: those degrade coverage, this one would fake it.
WEBCORE_EXPORT bool webCoreCSSCalcSimplificationUnsimplifiedParseAvailable(void);

// ENTRY 14. Decomposes comparison (a)'s bitwise verdict into which of `bitwiseEqualTree`'s four
// components disagreed. Purely diagnostic: guard 19's failing cases on this corpus all serialize
// identically, so the bare verdict names no mechanism. See the definition for the bit assignment.
WEBCORE_EXPORT uint32_t webCoreCSSCalcSimplificationEagerTerminalDelta(const char*, size_t);

// ENTRY 15. The raw bits of each arm's result root, for the four phase-U cases where both arms
// serialize `calc(NaN)` and the bitwise oracle still says no. Diagnostic only.
WEBCORE_EXPORT bool webCoreCSSCalcSimplificationRootBits(const char*, size_t, const CSSCalcSimplificationOptionsSpec*, uint64_t*, uint64_t*);

// ENTRIES 11 AND 12 compare `canonicalize` directly, parameterized over the full `CSSUnitType`
// range rather than only the units a parsed CSS corpus happens to use.
// `canonicalize` (CSSCalcTree+Simplification.cpp:169-287) is a seventy-case `switch` over
// `CSSUnitType`; sweeping every enumerator, boundary values included, exercises cases a corpus of
// real stylesheets would not reach.
//
// Four arms, each able to fail where the others cannot:
//   1. reference arithmetic computed directly from <WebCore/CSSUnitConversions.h> and
//      <wtf/MathExtras.h> -- the same headers both ported arms read.
//   2. `canonicalize` itself, called directly, unmediated by a tree walk.
//   3. the C++ simplifier over a `NonCanonicalDimension`-rooted tree, how `canonicalize` is reached
//      in production.
//   4. the Swift `canonicalizedDimension` over the same tree object.
//
// The unit crosses as a `uint32_t` rather than as `CSSUnitType` so callers can pass values outside
// the enum too; `built` is 0 for those.
struct CSSCalcCanonicalizationComparison {
    // Arm 3: the leaf the C++ simplifier produced.
    double cppValue;
    // Arm 4: the leaf the Swift side produced.
    double swiftValue;
    // Arm 2: `canonicalize`'s own answer. Meaningful only when `referenceResolved`.
    double referenceValue;
    // `toCSSUnit` of each arm's result leaf, as a `CSSUnitType` underlying value.
    uint32_t cppUnitType;
    uint32_t swiftUnitType;
    uint32_t referenceUnitType;
    // `Node`'s alternative index of each arm's result root, so "it stayed a NonCanonicalDimension"
    // and "it became a CanonicalDimension" are distinguishable without inspecting the value.
    uint32_t cppAlternative;
    uint32_t swiftAlternative;
    // Did `canonicalize` return a value at all. The C++'s `nullopt` for a relative unit with no
    // conversion data, and for the fourteen units a `NonCanonicalDimension` can never hold.
    uint32_t referenceResolved;
    // Did the Swift side decline the tree. A decline is invisible in an output comparison, so it is
    // reported rather than inferred.
    uint32_t swiftDeclined;
    // 0 = `unitRaw` is outside `CSSUnitType`, so no tree was built and every field above is inert.
    uint32_t built;
};

static_assert(sizeof(CSSCalcCanonicalizationComparison) == 56);
static_assert(offsetof(CSSCalcCanonicalizationComparison, cppUnitType) == 24);
static_assert(offsetof(CSSCalcCanonicalizationComparison, built) == 52);

WEBCORE_EXPORT CSSCalcCanonicalizationComparison webCoreCSSCalcCompareCanonicalization(double, uint32_t, const CSSCalcSimplificationOptionsSpec*);
WEBCORE_EXPORT uint32_t webCoreCSSCalcUnitTypeCount(void);

static std::atomic<uint64_t> s_simplifyCompareCalls;

// This file keeps its own decline counter rather than forwarding
// `CSSCalc::webCoreCSSCalcSimplificationDeclineCount()`, because each comparison below calls the
// Swift side three times -- once for the answer and twice more for idempotence checks -- so that
// counter advances by up to three per case, while this one counts exactly one per comparison whose
// reported answer was a decline.
static std::atomic<unsigned> s_simplifyComparisonDeclines;

// One `SimplificationOptions` from one spec, shared by the two comparison entries below and by
// `webCoreCSSCalcCompareCanonicalization`, so all three read the same conversion data rather than
// building three copies that could drift.
//
// The returned options hold a `CheckedPtr` to the builder state at kinds 3 and 4, so the result
// must be destroyed before `resetSimplificationBuilderStates` runs again -- `CanMakeCheckedPtr`'s
// destructor RELEASE_ASSERTs the pointer count is zero. Every caller scopes it accordingly.
static CSSCalc::SimplificationOptions makeSimplificationOptions(const CSSCalcSimplificationOptionsSpec* spec)
{
    auto conversionData = [&]() -> std::optional<CSSToLengthConversionData> {
        if (!spec->conversionDataKind)
            return std::nullopt;
        auto fontSize = simplificationConversionDataFontSize(spec->conversionDataKind);
        if (simplificationConversionDataCarriesBuilderState(spec->conversionDataKind)) {
            // The TWO-argument constructor, which is the only one that sets `m_styleBuilderState`.
            // It also derives `m_rootStyle`, `m_parentStyle`, `m_renderView` and
            // `m_elementForContainerUnitResolution` from the builder state rather than from the
            // arguments (CSSToLengthConversionData.cpp:52-61), which is why the fixture's
            // `BuilderContext` leaves `rootElementStyle` null: that keeps the `rem` family behaving
            // the same at kind 3 as at kind 1, so the axis moves ONE thing.
            return CSSToLengthConversionData { simplificationStyleAtFontSize(fontSize), simplificationBuilderStateAtFontSize(fontSize) };
        }
        return CSSToLengthConversionData { simplificationStyleAtFontSize(fontSize), nullptr, nullptr, nullptr, nullptr };
    }();

    return CSSCalc::SimplificationOptions {
        .category = static_cast<WebCore::CSS::Category>(spec->category),
        .range = WebCore::CSS::Range { spec->rangeMinimum, spec->rangeMaximum },
        .conversionData = WTF::move(conversionData),
        .symbolTable = simplificationSymbolTable(spec->symbolTableKind),
        .allowZeroValueLengthRemovalFromSum = !!spec->allowZeroValueLengthRemovalFromSum,
    };
}

// Everything the two comparison entries share. Both arms run on the same input `Tree` object inside
// one call, which is what makes it impossible to pair a C++ answer for one case with a Swift answer
// for another.
// `baselineTree` is the SAME text parsed with the parser's eager simplification left ON, supplied
// only by entry 1 and only when `spec->parseSimplification == None` is set. It is what turns the phase-U
// fields from a claim into a measurement.
static CSSCalcSimplificationComparison compareSimplificationOfTree(CSSCalc::Tree&& inputTree, std::optional<CSSCalc::Tree>&& baselineTree, const CSSCalcSimplificationOptionsSpec* spec, uint32_t parseCategory, char* cppOut, size_t cppCapacity, char* swiftOut, size_t swiftCapacity)
{
    CSSCalcSimplificationComparison result { };
    result.declineKind = 0xFF;
    result.parsed = 1;
    result.parseCategory = parseCategory;

    auto input = CSSCalc::Tree {
        .root = WTF::move(inputTree.root),
        .type = inputTree.type,
        // Set here rather than at parse time: a parse always produces `Stage::Specified`, and the
        // only place in WebCore that writes `Computed` needs the conversion data this harness
        // deliberately does not have. The oracle is two simplifiers over one `Tree` object and does
        // not care how the object was built.
        .stage = spec->stage ? CSSCalc::Stage::Computed : CSSCalc::Stage::Specified,
        .requiresConversionData = inputTree.requiresConversionData,
    };

    // The baseline tree gets the SAME `stage` override the input does, so that `eagerMatchesWholeTree`
    // below is a comparison of the two simplification routes and not of the stage the harness asked
    // for against the `Specified` every parse produces.
    std::optional<CSSCalc::Tree> baseline;
    if (baselineTree) {
        baseline = CSSCalc::Tree {
            .root = WTF::move(baselineTree->root),
            .type = baselineTree->type,
            .stage = input.stage,
            .requiresConversionData = baselineTree->requiresConversionData,
        };
    }

    result.inputKindMask = alternativeMaskOfSubtree(input.root);
    result.inputNodeCount = nodeCountOfSubtree(input.root);
    result.inputRootKind = static_cast<uint32_t>(input.root.value.index());
    result.inputHasSpliceableNesting = subtreeHasSpliceableNesting(input.root) ? 1 : 0;
    if (baseline) {
        result.baselineParsed = 1;
        result.baselineKindMask = alternativeMaskOfSubtree(baseline->root);
        result.baselineNodeCount = nodeCountOfSubtree(baseline->root);
        result.baselineRootKind = static_cast<uint32_t>(baseline->root.value.index());
    }

    // The two comparison runs use separate builder states, and each one's options are scoped so the
    // `CheckedPtr` inside them is released before the next reset; see
    // `resetSimplificationBuilderStates` for why the reset is required and why the Document and
    // element are not rebuilt between runs.
    //
    // Scoped to only the kinds that need it: at conversion-data kinds 0..2 nothing touches the
    // fixture, so the Document is never created and behaviour is unchanged from before this fixture
    // existed.
    auto usesBuilderState = simplificationConversionDataCarriesBuilderState(spec->conversionDataKind);
    auto declinesBefore = CSSCalc::webCoreCSSCalcSimplificationDeclineCount();
    auto runArm = [&](CSSCalc::Simplifier simplifier, uint32_t& invalidFlagOut) {
        if (usesBuilderState)
            resetSimplificationBuilderStates();
        auto armOptions = makeSimplificationOptions(spec);
        auto out = CSSCalc::copyAndSimplify(input, armOptions, simplifier);
        invalidFlagOut = usesBuilderState
            && simplificationBuilderStateFlaggedInvalid(simplificationConversionDataFontSize(spec->conversionDataKind)) ? 1 : 0;
        return out;
    };
    auto cppTree = runArm(CSSCalc::Simplifier::Cpp, result.cppInvalidAtComputedValueTime);
    auto swiftTree = runArm(CSSCalc::Simplifier::Swift, result.swiftInvalidAtComputedValueTime);
    auto declinesAfter = CSSCalc::webCoreCSSCalcSimplificationDeclineCount();

    // Everything below is diagnostic and shares one further builder state, built after the two
    // comparison runs so that no `CheckedPtr` from it is alive across either reset above.
    if (usesBuilderState)
        resetSimplificationBuilderStates();
    auto options = makeSimplificationOptions(spec);

    result.declined = declinesAfter != declinesBefore ? 1 : 0;
    if (result.declined)
        s_simplifyComparisonDeclines.fetch_add(1, std::memory_order_relaxed);
    result.declineKind = CSSCalc::webCoreCSSCalcSimplificationLastDeclineAlternative();
    result.islandKindMask = CSSCalc::webCoreCSSCalcSimplificationLastKindMask();

    // GUARD 19 IS NOT COMPUTED HERE, and the comment that said it was is the corrected claim. The
    // premise was "at the baseline tuple `armOptions` is the parse's own options" -- and it is not,
    // because the harness's baseline tuple pins conversion data, symbol table, the zero-removal flag
    // and stage but NOT the CATEGORY, while `parseCalcExpression` picks the category per case. So
    // `cppTree` here is simplified at the swept category and the eager tree was simplified at the
    // parse's, and six of guard 19's eleven first-run failures were that mismatch rather than an
    // eager/terminal divergence. Entry 1 computes (a) against the parse's own options instead and
    // overwrites the field; see the comment there.

    result.agree = bitwiseEqualTree(cppTree, swiftTree) ? 1 : 0;
    result.agreeDefaulted = cppTree == swiftTree ? 1 : 0;
    result.containsNaN = (subtreeContainsNaN(cppTree.root) || subtreeContainsNaN(swiftTree.root)) ? 1 : 0;

    result.cppChangedInput = bitwiseEqualTree(input, cppTree) ? 0 : 1;
    result.swiftChangedInput = bitwiseEqualTree(input, swiftTree) ? 0 : 1;
    result.outputNodeCount = nodeCountOfSubtree(cppTree.root);
    result.outputRootKind = static_cast<uint32_t>(cppTree.root.value.index());

    // Idempotence, checked per side and reference-free: this can fail on a case where the two sides
    // agree with each other, which a bare comparison between them would never catch. Compared
    // bitwise on purpose -- the defaulted comparison would report every NaN result as
    // non-idempotent.
    result.cppIdempotent = bitwiseEqualTree(CSSCalc::copyAndSimplify(cppTree, options, CSSCalc::Simplifier::Cpp), cppTree) ? 1 : 0;
    result.swiftIdempotent = bitwiseEqualTree(CSSCalc::copyAndSimplify(swiftTree, options, CSSCalc::Simplifier::Swift), swiftTree) ? 1 : 0;

    result.cppCanSimplify = CSSCalc::canSimplify(input, options, CSSCalc::Simplifier::Cpp) ? 1 : 0;
    result.swiftCanSimplify = CSSCalc::canSimplify(input, options, CSSCalc::Simplifier::Swift) ? 1 : 0;
    result.cppCanSimplifySound = (result.cppCanSimplify || !result.cppChangedInput) ? 1 : 0;
    result.swiftCanSimplifySound = (result.swiftCanSimplify || !result.swiftChangedInput) ? 1 : 0;

    result.cppPreservedStageAndFlag = (cppTree.stage == input.stage && cppTree.requiresConversionData == input.requiresConversionData) ? 1 : 0;
    result.swiftPreservedStageAndFlag = (swiftTree.stage == input.stage && swiftTree.requiresConversionData == input.requiresConversionData) ? 1 : 0;

    // Both through `Serializer::Cpp`, so a serialization defect shows up there rather than as a
    // phantom failure here.
    auto serializationOptions = CSSCalc::SerializationOptions {
        .range = WebCore::CSS::All,
        .serializationContext = WebCore::CSS::defaultSerializationContext(),
    };
    result.agreeSerialized = CSSCalc::serializationForCSS(cppTree, serializationOptions, CSSCalc::Serializer::Cpp)
        == CSSCalc::serializationForCSS(swiftTree, serializationOptions, CSSCalc::Serializer::Cpp) ? 1 : 0;
    result.cppLength = static_cast<uint32_t>(copyOutSerialization(CSSCalc::serializationForCSS(cppTree, serializationOptions, CSSCalc::Serializer::Cpp), cppOut, cppCapacity));
    result.swiftLength = static_cast<uint32_t>(copyOutSerialization(CSSCalc::serializationForCSS(swiftTree, serializationOptions, CSSCalc::Serializer::Cpp), swiftOut, swiftCapacity));
    return result;
}

// Throughput of ONE arm of whole-tree simplification, for the round-major driver in
// cssprobe/validate/calcbench.cpp. This island had never been timed at all: `cssbench` calls
// `webCoreCSSTokenizerBenchIntegrated`, which builds a `CSSTokenizer` and walks the token range and
// so never reaches the declaration parser, let alone `copyAndSimplify`. There was no instrument.
//
// One entry taking an ARM SELECTOR rather than two frameworks, exactly as
// `webCoreCSSTokenizerBenchIntegrated` does: both arms then come from one binary and are
// interleaved inside one process, so there is no cross-build drift to attribute and no framework
// ordering to control for.
//
// The parse happens ONCE, outside the loop, because the thing being timed is simplification and a
// parse costs far more than one simplification of what it produced. The caller amortises the parse
// by passing a large `iterations`; the driver divides by it.
//
// `fold` exists only to stop the loop being eliminated -- the result is otherwise unused, and the
// whole body is dead code without it. It folds the root's alternative and the tree's type so that
// an arm returning a structurally different answer cannot fold identically.
//
// NOTE FOR ANYONE READING A NUMBER FROM THIS: in a build with the bridge enabled, the SWIFT arm
// pays five relaxed atomics per whole-tree call that the C++ arm does not
// (CSSCalcTree+Simplification.cpp:2516-2523, all `#if ENABLE(CSS_TOKENIZER_SWIFT_BRIDGE)`), so the
// comparison is biased against Swift by that much. It is a per-TREE cost, not per node, and the
// driver bounds it with a microbenchmark rather than ignoring it.
WEBCORE_EXPORT uint64_t webCoreCSSCalcSimplificationBench(const char* text, size_t length, bool useSwift, uint32_t iterations, uint32_t* outParsed)
{
    String source { unsafeMakeSpan(byteCast<Latin1Character>(text), length) };
    auto parsed = parseCalcExpression(source);
    if (outParsed)
        *outParsed = parsed.tree ? 1 : 0;
    if (!parsed.tree)
        return 0;

    auto options = CSSCalc::SimplificationOptions {
        .category = parsed.category,
        .range = WebCore::CSS::All,
        .conversionData = std::nullopt,
        .symbolTable = { },
        .allowZeroValueLengthRemovalFromSum = false,
    };
    auto arm = useSwift ? CSSCalc::Simplifier::Swift : CSSCalc::Simplifier::Cpp;

    uint64_t fold = 0;
    for (uint32_t i = 0; i < iterations; ++i) {
        auto simplified = CSSCalc::copyAndSimplify(*parsed.tree, options, arm);
        fold = fold * 1000003 + static_cast<uint64_t>(simplified.root.index());
        fold = fold * 1000003 + static_cast<uint64_t>(simplified.type.percent);
    }
    return fold;
}

WEBCORE_EXPORT CSSCalcSimplificationComparison webCoreCSSCalcCompareSimplification(const char* text, size_t length, const CSSCalcSimplificationOptionsSpec* spec, char* cppOut, size_t cppCapacity, char* swiftOut, size_t swiftCapacity)
{
    // Counted BEFORE the parse filter, so that the harness's call tally matches even for cases that
    // do not parse -- it counts calls made, not cases run.
    s_simplifyCompareCalls.fetch_add(1, std::memory_order_relaxed);

    CSSCalcSimplificationComparison result { };
    result.declineKind = 0xFF;
    String source { unsafeMakeSpan(byteCast<Latin1Character>(text), length) };

    // SPEC VALUE 3 IS A CONTROL, NOT A `ParseSimplification`: "parse EAGER, but compute the
    // baseline anyway". It exists because `--control simplifiedinput` (NC-2) has to reproduce the
    // exact state the arm must detect -- the harness asked for unsimplified trees and got
    // pre-simplified ones -- and simply passing `Eager` does not: with no baseline computed, guard
    // 18 fires on every case and guard 17's `strictlyLarger == 0` comes out of "no case got past
    // the parse-agreement gate" rather than out of "input and baseline are the same tree". Both
    // exit 1, and only one of them is the vacuity the control names. `Eager` on its own stays free
    // for the 924,951-case sweep, which must not pay a second parse.
    auto specMode = spec->parseSimplification;
    bool forceSimplifiedInput = specMode == 3;
    auto mode = forceSimplifiedInput
        ? CSSCalc::ParseSimplification::Eager
        : static_cast<CSSCalc::ParseSimplification>(specMode);

    // THE SECOND PARSE, and it happens only when the axis is off its historical value, so nothing
    // about the 924,951-tuple sweep's cost or behaviour moves. It is the EAGER tree -- today's
    // production output -- and it is what both comparison (a) and the vacuity guards are computed
    // against. Parsed here rather than by a second call from the harness for the three reasons the
    // `CSSCalcSimplificationComparison` phase-U block gives.
    std::optional<CSSCalc::Tree> baseline;
    if (mode != CSSCalc::ParseSimplification::Eager || forceSimplifiedInput) {
        // Named, because `WTF::move` static_asserts on an lvalue reference and a temporary's member
        // is not one.
        auto baselineParse = parseCalcExpression(source, CSSCalc::ParseSimplification::Eager);
        baseline = WTF::move(baselineParse.tree);
    }

    auto parsed = parseCalcExpression(source, mode);
    if (!parsed.tree) {
        // REPORTED EVEN ON THE FAILING PATH. "the eager parse succeeded and the unsimplified one did
        // not" is precisely what the harness's guard 18 exists to catch, and it is invisible if this
        // returns the zeroed struct.
        result.baselineParsed = baseline ? 1 : 0;
        return result;
    }

    // COMPARISON (a), COMPUTED HERE AND NOT FROM `cppTree`, and the difference is not cosmetic.
    //
    // `ParseSimplification::Terminal` calls `copyAndSimplify(result, simplificationOptions)` with the
    // PARSE's OWN options -- CSSCalcTree+Parser.cpp -- whose `category` is whichever category the
    // parse succeeded at. `compareSimplificationOfTree` simplifies under the SPEC's options instead,
    // and the harness's "baseline tuple" pins conversion data, symbol table, the zero-removal flag
    // and stage but NOT the category. So on any expression that parses at a category other than the
    // tuple's -- `min(1em, 1rem, 3%, 4%)` parses at LengthPercentage while the baseline tuple sweeps
    // Number -- reading (a) off `cppTree` compares an eager tree simplified at category 9 against a
    // terminal tree simplified at category 1, and reports a divergence that is the harness's own.
    // Measured 2026-09-09: six of guard 19's eleven failures were exactly that, and all six agree
    // when the categories are matched.
    //
    // So (a) is computed against the parse's options, which is the comparison it claims to be, and
    // it is now independent of the swept tuple. `Simplifier::Cpp` explicitly: no Swift runs on
    // either side of (a).
    if (baseline) {
        auto parseOptions = CSSCalc::SimplificationOptions {
            .category = parsed.category,
            .range = parsed.range,
            .conversionData = std::nullopt,
            .symbolTable = { },
            .allowZeroValueLengthRemovalFromSum = false,
        };
        auto terminal = CSSCalc::copyAndSimplify(*parsed.tree, parseOptions, CSSCalc::Simplifier::Cpp);
        result.eagerMatchesWholeTree = bitwiseEqualTree(terminal, *baseline) ? 1 : 0;
        result.eagerTerminalComputed = 1;
    }

    auto comparison = compareSimplificationOfTree(WTF::move(*parsed.tree), WTF::move(baseline), spec, static_cast<uint32_t>(parsed.category), cppOut, cppCapacity, swiftOut, swiftCapacity);
    comparison.eagerMatchesWholeTree = result.eagerMatchesWholeTree;
    comparison.eagerTerminalComputed = result.eagerTerminalComputed;
    return comparison;
}

// The same comparison over a tree built directly rather than parsed. `constructSimplificationShape`
// says which shapes and why no parse reaches them.
//
// One known interaction with the identity control: shape 2 is `Deg2Rad{CanonicalDimension(1deg)}`,
// and `simplify(Deg2Rad&)` folds a `CanonicalDimension` child unconditionally, with no swept option
// involved, so this entry reports `cppChangedInput = 1` for it even at the parse baseline. That
// makes the control's premise -- "a tree handed back at its own parse fixed point does not change"
// -- not true of a constructed tree, which is the reason this entry exists separately.
WEBCORE_EXPORT CSSCalcSimplificationComparison webCoreCSSCalcCompareSimplificationConstructed(unsigned shape, const CSSCalcSimplificationOptionsSpec* spec, char* cppOut, size_t cppCapacity, char* swiftOut, size_t swiftCapacity)
{
    s_simplifyCompareCalls.fetch_add(1, std::memory_order_relaxed);

    CSSCalcSimplificationComparison result { };
    result.declineKind = 0xFF;

    auto tree = constructSimplificationShape(shape);
    if (!tree)
        return result;

    // `std::nullopt`: a CONSTRUCTED tree has no parse, so it has no baseline counterpart and none of
    // the six phase-U fields is meaningful for it. They stay zero, and the harness only reads them
    // for cases whose tuple selects `ParseSimplification::None`, which no constructed case does.
    return compareSimplificationOfTree(WTF::move(*tree), std::nullopt, spec, spec->category, cppOut, cppCapacity, swiftOut, swiftCapacity);
}

// The compile-time default, so a build that ignored WK_USE_SWIFT_CSS_CALC_SIMPLIFICATION cannot
// pass as one that honoured it. Reported separately from the entries above, which name their
// simplifier explicitly: conflating the two is how an ignored build flag reads as a pass.
WEBCORE_EXPORT bool webCoreCSSCalcSimplificationIsSwift(void)
{
    return CSSCalc::defaultSimplifier == CSSCalc::Simplifier::Swift;
}

WEBCORE_EXPORT void webCoreCSSCalcSimplificationSetForceDecline(bool force)
{
    CSSCalc::webCoreCSSCalcSimplificationSetForceDecline(force);
}

WEBCORE_EXPORT unsigned webCoreCSSCalcSimplificationDeclineCount(void)
{
    return s_simplifyComparisonDeclines.load(std::memory_order_relaxed);
}

// The ISLAND's own decline counter, which the entry above is NOT: that one reports
// `s_simplifyComparisonDeclines`, incremented only inside the two comparison entries, so a harness
// driving the island through `webCoreCSSCalcSimplificationBench` reads a counter that cannot move.
// `calcbench` did exactly that and printed `0 declines during the timed rounds` on every run of
// every arm ever measured -- a coverage guard that was structurally incapable of failing, which is
// the shape CLAUDE.md §2 calls a check that silently passes while measuring nothing.
//
// Two entries and not one: the comparison harness wants the comparison count (a decline inside
// `runArm` is already visible to it through `result.declined`) and a bench driver wants the
// island's. Keeping both named is cheaper than one entry that means different things to its two
// callers, which is how this went wrong the first time.
WEBCORE_EXPORT unsigned webCoreCSSCalcSimplificationIslandDeclineCount(void)
{
    return CSSCalc::webCoreCSSCalcSimplificationDeclineCount();
}

// A FORWARDER, and it has to be one. Everything from `extern "C" {` at :979 is at global scope, so
// a declaration here does NOT name `CSSCalc::webCoreCSSCalcSimplificationPrimitiveBench` -- it
// declares a different, C-linkage function, and without this body it would simply fail to link.
//
// Worth spelling out because the same shape caused a wrong diagnosis: the entry immediately above
// is likewise a forwarder, but to `s_simplifyComparisonDeclines` -- the BRIDGE's comparison
// counter, not the island's `CSSCalc::s_simplificationDeclines`. A harness that dlsym'd
// `webCoreCSSCalcSimplificationDeclineCount` and drove the island through some path other than the
// comparison entries therefore read a counter that never moves, which looked exactly like "the
// Swift arm is never reached" and was written up as a suspected ThinLTO defect. It was not.
WEBCORE_EXPORT uint64_t webCoreCSSCalcSimplificationPrimitiveBench(uint32_t which, uint32_t iterations)
{
    return CSSCalc::webCoreCSSCalcSimplificationPrimitiveBench(which, iterations);
}

WEBCORE_EXPORT uint64_t webCoreCSSCalcSimplificationHarnessCallCount(void)
{
    return s_simplifyCompareCalls.load(std::memory_order_relaxed);
}

// From the variant, never from an enumerator: `webCoreCSSCalcNodeKindCount` above was once spelled
// as "the last enumerator + 1", which silently read 19 when the true count was 23 after four kinds
// were added. `VariantSizeV` cannot go stale that way, and it is also the right-hand side of the
// assert that pins `CSSCalcSwiftAlternative` in CSSCalcTree+Serialization.cpp.
WEBCORE_EXPORT uint32_t webCoreCSSCalcChildAlternativeCount(void)
{
    return static_cast<uint32_t>(WTF::VariantSizeV<CSSCalc::Node>);
}

// The category list this file actually iterates, not a recount of the enum.
//
// Not fully drift-proof: `CSS::Category` has no count of its own, so a category appended after
// `AnglePercentage` would be missed by both the assert below and by `calcCategories`. The assert
// does catch the likelier edit -- one added in the middle, or one removed. Closing the gap
// properly needs a count in CSSPrimitiveNumericCategory.h, a header this file does not own.
WEBCORE_EXPORT uint32_t webCoreCSSCalcCategoryCount(void)
{
    static_assert(calcCategories.size() == static_cast<size_t>(WebCore::CSS::Category::AnglePercentage) + 1);
    return static_cast<uint32_t>(calcCategories.size());
}

WEBCORE_EXPORT uint32_t webCoreCSSCalcConstructedShapeCount(void)
{
    return simplificationConstructedShapeCount;
}

// ENTRY 13. See the declaration for why this exists at all rather than the harness simply setting
// the flag and trusting it.
//
// It answers the question CONSTRUCTIVELY rather than returning a bare `true`: it parses one
// expression both ways and requires the unsimplified tree to be strictly larger.
//
// THE WITNESS WAS `calc(1px)` AND THAT WAS WRONG -- it returns false on a build that carries the
// axis perfectly, which is the one answer this entry must never give. The claim behind it was that
// "the parser wraps a single term in a `Sum` and step 8.2 collapses the wrapper". It does not wrap:
// `parseCalcProduct` and `parseCalcSum` both `return firstValue` before constructing anything when
// no operator follows (CSSCalcTree+Parser.cpp:1511-1512 and :1445-1446), so `calc(1px)` is a bare
// `CanonicalDimension` in EVERY mode and this entry compared 1 against 1. The one-child `Sum`
// wrapper is built only by `consumeValueWithoutSimplifyingRootCalc` (`:916`-`:921`), which only
// `anchor()` and `anchor-size()` reach. The two comments elsewhere in this file that say
// `parseAndSimplify` "folds that wrapper away" (`constructRootShape`, and
// `webCoreCSSCalcCompareSerializationStaged`) reach the right conclusion -- the root is the leaf --
// by the wrong route; their unwrap is inert because there is nothing to unwrap.
//
// `calc(1px + 2px)` is the smallest witness with no room for coincidence: two same-unit canonical
// terms, so the eager parse folds `Sum{1px, 2px}` to a single `CanonicalDimension(3px)` while the
// unsimplified parse keeps all three nodes. The exact counts are asserted rather than only their
// order, so a future simplification change that stops folding fails here loudly instead of quietly
// weakening the guard this entry exists to be.
WEBCORE_EXPORT bool webCoreCSSCalcSimplificationUnsimplifiedParseAvailable(void)
{
    auto eager = parseCalcExpression("calc(1px + 2px)"_str, CSSCalc::ParseSimplification::Eager);
    auto none = parseCalcExpression("calc(1px + 2px)"_str, CSSCalc::ParseSimplification::None);
    if (!eager.tree || !none.tree)
        return false;
    return nodeCountOfSubtree(eager.tree->root) == 1 && nodeCountOfSubtree(none.tree->root) == 3;
}

// ENTRY 14. WHICH of `bitwiseEqualTree`'s four components made comparison (a) fail.
//
// Guard 19 reports a bare verdict, and on this corpus every failing case serializes IDENTICALLY on
// both arms, with the same node count and the same root alternative -- so "they differ" carries no
// attribution at all and the eight failing expressions look like eight unrelated findings. This
// splits the verdict into its parts so the mechanism can be named rather than guessed at:
//
//   bit 0  Tree::stage
//   bit 1  Tree::requiresConversionData
//   bit 2  Tree::type                        -- the whole-tree type, recomputed by the terminal pass
//   bit 3  the subtree, per-node, bitwise    -- a stored per-node `Type`, a signed zero, a
//                                              `Percentage::hint`, or a leaf double
//
// Returns 0 when the two arms agree and `0xFFFF` when the text did not parse on both.
WEBCORE_EXPORT uint32_t webCoreCSSCalcSimplificationEagerTerminalDelta(const char* text, size_t length)
{
    String source { unsafeMakeSpan(byteCast<Latin1Character>(text), length) };
    auto eager = parseCalcExpression(source, CSSCalc::ParseSimplification::Eager);
    auto raw = parseCalcExpression(source, CSSCalc::ParseSimplification::None);
    if (!eager.tree || !raw.tree)
        return 0xFFFF;

    // Exactly the options `parseCalcExpression` parsed with, so this is the terminal arm as
    // `ParseSimplification::Terminal` would run it.
    auto options = CSSCalc::SimplificationOptions {
        .category = eager.category,
        .range = WebCore::CSS::All,
        .conversionData = std::nullopt,
        .symbolTable = { },
        .allowZeroValueLengthRemovalFromSum = false,
    };
    auto terminal = CSSCalc::copyAndSimplify(*raw.tree, options, CSSCalc::Simplifier::Cpp);

    uint32_t delta = 0;
    if (terminal.stage != eager.tree->stage)
        delta |= 1u << 0;
    if (terminal.requiresConversionData != eager.tree->requiresConversionData)
        delta |= 1u << 1;
    if (!(terminal.type == eager.tree->type))
        delta |= 1u << 2;
    if (!bitwiseEqualChild(terminal.root, eager.tree->root))
        delta |= 1u << 3;
    return delta;
}

// ENTRY 15. The RAW BITS of each arm's result root, for a case the bitwise oracle rejects while
// both arms serialize identically.
//
// Phase U turned up four such cases and no earlier phase ever did: `calc(g - b)` and friends with
// the symbols bound to NaN, where `cpp` and `swift` both print `calc(NaN)` and `sameBits` says no.
// Serialization cannot show a NaN's sign or payload and neither can the harness's report, so
// without this the finding could only be described, not attributed. Two separate out pointers
// rather than a two-element array: an indexed write trips -Wunsafe-buffer-usage, which is on with
// -Werror here, and a `std::span` would not survive the `dlsym` the harness reaches this through.
// Returns 1 when both roots were numeric leaves.
WEBCORE_EXPORT bool webCoreCSSCalcSimplificationRootBits(const char* text, size_t length, const CSSCalcSimplificationOptionsSpec* spec, uint64_t* cppBits, uint64_t* swiftBits)
{
    String source { unsafeMakeSpan(byteCast<Latin1Character>(text), length) };
    auto parsed = parseCalcExpression(source, static_cast<CSSCalc::ParseSimplification>(spec->parseSimplification));
    if (!parsed.tree)
        return false;

    auto options = CSSCalc::SimplificationOptions {
        .category = static_cast<WebCore::CSS::Category>(spec->category),
        .range = { spec->rangeMinimum, spec->rangeMaximum },
        .conversionData = std::nullopt,
        .symbolTable = simplificationSymbolTable(spec->symbolTableKind),
        .allowZeroValueLengthRemovalFromSum = !!spec->allowZeroValueLengthRemovalFromSum,
    };

    auto rootBits = [](const CSSCalc::Child& root, uint64_t& bits) {
        return WTF::switchOn(root.value,
            [&](const CSSCalc::Number& n) { bits = std::bit_cast<uint64_t>(n.value); return true; },
            [&](const CSSCalc::Percentage& p) { bits = std::bit_cast<uint64_t>(p.value); return true; },
            [&](const CSSCalc::CanonicalDimension& d) { bits = std::bit_cast<uint64_t>(d.value); return true; },
            [&](const CSSCalc::NonCanonicalDimension& d) { bits = std::bit_cast<uint64_t>(d.value); return true; },
            [&](const auto&) { return false; });
    };

    auto cppTree = CSSCalc::copyAndSimplify(*parsed.tree, options, CSSCalc::Simplifier::Cpp);
    auto swiftTree = CSSCalc::copyAndSimplify(*parsed.tree, options, CSSCalc::Simplifier::Swift);
    return rootBits(cppTree.root, *cppBits) && rootBits(swiftTree.root, *swiftBits);
}

// ENTRY 10. Does the conversion-data fixture support font-metric-relative units?
//
// `simplificationStyleAtFontSize` used to leave the style's `FontCascade::m_fonts` null, and every
// font-metric unit (`ex`, `cap`, `ch`, `ic`, `lh` and the `r*` forms) took EXC_BAD_ACCESS inside
// `Style::resolveEx`. This reports the fixture's own capability rather than relying on a caller to
// exclude those units by a comment that could go stale.
//
// Returning `fonts() != nullptr` would not be enough: a fixture whose two styles realized the same
// font would make the whole conversion-data axis vacuous, since a `canonicalize` that just returns
// a constant would still pass. So this returns true only if both styles have a realized font and
// their x-heights, cap-heights and line spacings all differ -- the property the two-font-size
// design exists to give. Measured values on this framework: 7.1797/14.3594, 10.5859/21.1719, 18/37.
WEBCORE_EXPORT bool webCoreCSSCalcSimplificationFontMetricsAvailable(void)
{
    auto& cascade16 = simplificationStyleAtFontSize(16.0f).fontCascade();
    auto& cascade32 = simplificationStyleAtFontSize(32.0f).fontCascade();
    if (!cascade16.fonts() || !cascade32.fonts())
        return false;

    auto& metrics16 = cascade16.metricsOfPrimaryFont();
    auto& metrics32 = cascade32.metricsOfPrimaryFont();
    // `Markable<float>`, not `std::optional<float>` -- taken by `auto` so the accessor's actual
    // return type decides, rather than a conversion that may not exist.
    auto differs = [](auto a, auto b) {
        return a && b && *a != *b;
    };
    return differs(metrics16.xHeight(), metrics32.xHeight())
        && differs(metrics16.capHeight(), metrics32.capHeight())
        && metrics16.lineSpacing() != metrics32.lineSpacing();
}

// ENTRY 10b. Does the conversion-data fixture support a live `Style::BuilderState`?
//
// A pre-flight check: if any of the five builder-state-requiring `simplify` overloads
// dereferences something this fixture lacks, the process crashes with EXC_BAD_ACCESS, so every
// dereference those five perform is exercised here first.
//
//   - `element()` non-null.
//   - `siblingCount() == 5`, `siblingIndex() == 3` -- distinct, so a mixed-up port is caught.
//   - `lookupCSSRandomBaseValue` on both the document-scoped and element-scoped path.
//   - `AnchorPositionEvaluator::evaluateSize` returning `nullopt` without crashing (no property
//     is in flight, so `propertyAllowsAnchorSizeFunction` is false).
//   - `setCurrentPropertyInvalidAtComputedValueTime()` round-tripped: false, set, true.
//
// Leaves the fixture clean: `resetSimplificationBuilderStates` clears the flag it set.
WEBCORE_EXPORT bool webCoreCSSCalcSimplificationBuilderStateAvailable(void)
{
    resetSimplificationBuilderStates();
    auto& state = simplificationBuilderStateAtFontSize(16.0f);

    bool ok = true;
    ok = ok && state.element();
    ok = ok && state.siblingCount() == 5;
    ok = ok && state.siblingIndex() == 3;

    // Both `random()` sharing paths. The values themselves are not checked -- they are a
    // per-process random draw -- only that both return and that the cache is stable, which is what
    // lets the two runs agree with each other.
    CSSCalc::RandomCachingKey key { CSSCalc::RandomCachingKey::Key { .name = std::nullopt, .propertyScoped = std::nullopt } };
    auto documentScoped = state.lookupCSSRandomBaseValue(key, std::nullopt);
    auto elementScoped = state.lookupCSSRandomBaseValue(key, CSS::Keyword::ElementScoped { });
    ok = ok && state.lookupCSSRandomBaseValue(key, std::nullopt) == documentScoped;
    ok = ok && state.lookupCSSRandomBaseValue(key, CSS::Keyword::ElementScoped { }) == elementScoped;

    // The anchor entry point, with no property in flight. Must be `nullopt`, and must not crash
    // getting there.
    ok = ok && !WebCore::Style::AnchorPositionEvaluator::evaluateSize(state, std::nullopt, std::nullopt);

    // The invalid-at-computed-value-time channel, round-tripped.
    ok = ok && !state.isCurrentPropertyInvalidAtComputedValueTime();
    state.setCurrentPropertyInvalidAtComputedValueTime();
    ok = ok && state.isCurrentPropertyInvalidAtComputedValueTime();

    // The 32px state has to be live too, or conversion-data kind 4 is a silent no-op.
    auto& state32 = simplificationBuilderStateAtFontSize(32.0f);
    ok = ok && state32.element() == state.element();
    ok = ok && !state32.isCurrentPropertyInvalidAtComputedValueTime();

    resetSimplificationBuilderStates();
    return ok;
}

// The two sibling numbers the fixture actually presents, reported rather than hardcoded, so a
// fixture that silently became one-sibling (making `sibling-count()` and `sibling-index()`
// indistinguishable) would show up in the numbers themselves.
WEBCORE_EXPORT unsigned webCoreCSSCalcSimplificationFixtureSiblingCount(void)
{
    return simplificationBuilderStateAtFontSize(16.0f).siblingCount();
}

WEBCORE_EXPORT unsigned webCoreCSSCalcSimplificationFixtureSiblingIndex(void)
{
    return simplificationBuilderStateAtFontSize(16.0f).siblingIndex();
}

// ENTRY 11. One unit, one value, four arms. See the struct above for why there are four.
WEBCORE_EXPORT CSSCalcCanonicalizationComparison webCoreCSSCalcCompareCanonicalization(double value, uint32_t unitRaw, const CSSCalcSimplificationOptionsSpec* spec)
{
    // Counted on the same tally as the tree-level entries, so a caller cross-checking totals covers
    // this entry too.
    s_simplifyCompareCalls.fetch_add(1, std::memory_order_relaxed);

    CSSCalcCanonicalizationComparison result { };
    // Reported rather than asserted: callers may pass values outside the enum on purpose, and
    // `static_cast` of an out-of-range value would be UB, so this is checked explicitly instead.
    if (unitRaw > static_cast<uint32_t>(CSSUnitType::QuirkyEm))
        return result;
    result.built = 1;

    auto unit = static_cast<CSSUnitType>(unitRaw);
    auto options = makeSimplificationOptions(spec);

    // The reference call, using the same conversion data the two tree-based calls below get -- read
    // off `options` rather than rebuilt, so all three use the same conversion data.
    if (auto canonical = CSSCalc::canonicalize(CSSCalc::NonCanonicalDimension { .value = value, .unit = unit }, options.conversionData)) {
        result.referenceResolved = 1;
        result.referenceValue = canonical->value;
        result.referenceUnitType = static_cast<uint32_t>(CSSCalc::toCSSUnit(canonical->dimension));
    }

    // Both simplifiers run over the same input `Tree` object, so a C++ answer for one unit can
    // never be paired with a Swift answer for another.
    auto root = CSSCalc::makeChild(CSSCalc::NonCanonicalDimension { .value = value, .unit = unit });
    auto type = CSSCalc::getType(root);
    auto input = CSSCalc::Tree { .root = WTF::move(root), .type = type, .stage = spec->stage ? CSSCalc::Stage::Computed : CSSCalc::Stage::Specified };

    auto declinesBefore = CSSCalc::webCoreCSSCalcSimplificationDeclineCount();
    auto cppTree = CSSCalc::copyAndSimplify(input, options, CSSCalc::Simplifier::Cpp);
    auto swiftTree = CSSCalc::copyAndSimplify(input, options, CSSCalc::Simplifier::Swift);
    result.swiftDeclined = CSSCalc::webCoreCSSCalcSimplificationDeclineCount() != declinesBefore ? 1 : 0;
    // On the same tally the tree-level entries use. Each call runs the Swift side exactly once --
    // there are no idempotence checks here -- so the counter advances by at most one per case.
    if (result.swiftDeclined)
        s_simplifyComparisonDeclines.fetch_add(1, std::memory_order_relaxed);

    // The result leaf, read off the variant tag rather than guessed from the unit. The catch-all is
    // unreachable for a `NonCanonicalDimension` root, since neither simplifier turns a numeric leaf
    // into an operation; it leaves the value at 0 with the alternative still reported, so a
    // simplifier that somehow did would show up as a disagreement rather than as garbage.
    auto readLeaf = [](const CSSCalc::Tree& tree, double& outValue, uint32_t& outUnit, uint32_t& outAlternative) {
        outAlternative = static_cast<uint32_t>(tree.root.value.index());
        WTF::switchOn(tree.root.value,
            [&]<CSSCalc::Numeric T>(const T& numeric) {
                outValue = numeric.value;
                outUnit = static_cast<uint32_t>(CSSCalc::toCSSUnit(numeric));
            },
            [&](const auto&) { }
        );
    };
    readLeaf(cppTree, result.cppValue, result.cppUnitType, result.cppAlternative);
    readLeaf(swiftTree, result.swiftValue, result.swiftUnitType, result.swiftAlternative);
    return result;
}

// ENTRY 12. How many `CSSUnitType` enumerators there are, so a caller's sweep width comes from
// WebCore rather than a hardcoded count.
//
// Spelled as "the last enumerator + 1" -- the same fragile pattern `webCoreCSSCalcChildAlternativeCount`
// avoids via `std::variant_size_v`, which `CSSUnitType` has no equivalent of. `QuirkyEm` carries the
// comment that it is last. This catches an enumerator inserted in the middle or removed, but would
// miss one appended after `QuirkyEm`; closing that properly needs a count in CSSUnitType.h, a header
// this file shares with the tokenizer.
WEBCORE_EXPORT uint32_t webCoreCSSCalcUnitTypeCount(void)
{
    return static_cast<uint32_t>(CSSUnitType::QuirkyEm) + 1;
}

} // extern "C"

#endif // ENABLE(CSS_TOKENIZER_SWIFT_BRIDGE)
