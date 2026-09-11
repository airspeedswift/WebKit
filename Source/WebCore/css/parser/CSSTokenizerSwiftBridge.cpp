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

// Test and benchmark entry points for the Swift CSS tokenizer, calc parser, calc simplifier,
// calc serializer and colour fast path. Exposed `extern "C"` to TestWebKitAPI and the standalone
// harnesses, so that no header needs exporting.

#include "config.h"

// Switched on with WK_ENABLE_CSS_TOKENIZER_SWIFT_BRIDGE=YES, which appends the define for both
// WebCore and TestWebKitAPI. The flag has to reach both, because TestWebKitAPI links these
// symbols.
#if ENABLE(CSS_TOKENIZER_SWIFT_BRIDGE)

#include "CSSParserObserver.h"
#include "CSSParserObserverWrapper.h"
#include "CSSParserContext.h"
#include "CSSParserFastPaths.h"
#include "CSSParserToken.h"
#include "CSSParserTokenRange.h"
#include "CSSCalcSwiftTypes.h"
#include "CSSPropertyParserConsumer+Primitives.h"
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
// `FontCascade::metricsOfPrimaryFont` and `primaryFont` are declared `inline` in FontCascade.h
// and defined here, so a translation unit that calls either without this include fails
// -Werror,-Wundefined-inline rather than at link time.
#include "FontCascadeInlines.h"
// For the calc simplification comparison's conversion-data axis.
#include "StyleComputedStyle.h"
#include "StyleComputedStyle+GettersInlines.h"
#include "StyleComputedStyle+SettersInlines.h"
// The builder-state fixture. `Style::BuilderState` is required by `simplify(SiblingCount&)`,
// `simplify(SiblingIndex&)`, `simplify(Random&)`, `simplify(Anchor&)` and
// `simplify(AnchorSize&)`, and `BuilderContext` holds a non-null `const Ref<const Document>`, so
// a real `Document` is mandatory.
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
// The Style to CSS calculation conversion, for the round-trip entry.
#include "StyleCalculationTree.h"
#include "StyleCalculationTree+Conversion.h"
// WebCoreSwift-Generated.h is module-scoped, so any translation unit that includes it must
// declare every Swift boundary type in the module, not just the ones this file calls.
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

// A do-nothing observer, so that a CSSParserObserverWrapper can be constructed and the offsets
// it is fed compared between the two paths.
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
// Declared in the anonymous namespace rather than beside the entries they serve: those entries
// have `extern "C"` linkage, and a C-linkage function may not return a user-defined type.

// The categories to try, in order. A calc expression is only parseable in a context that admits
// its type, so trying each in turn avoids skipping an expression handed the wrong context.
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

// The parser context, built once: construction per call would dominate a sweep that makes
// millions of calls. A function-local static because WebCore links with -no_inits.
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
        // unreachable and the `Operation` node kind never produced.
        built.cssRandomFunctionEnabled = true;
        built.cssCalcMixEnabled = true;
        return built;
    }();
    return context.get();
}

// Symbols the calc parser will accept as unresolved `Symbol` leaves. Without a non-empty table
// the `Symbol` node kind is unreachable: a bare identifier inside calc() is only a symbol if the
// caller said so. These four are the relative-colour component symbols.
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
//
// Split from the category loop below so that ONE category can be named directly. The Style
// round-trip entry needs that: `Style::Calculation::toStyle` accepts `LengthPercentage` and
// `AnglePercentage` only, and taking whichever category the search happened to settle on would
// convert a tree parsed at `Integer` under `LengthPercentage` options -- a different
// `Percentage::hint`, so a different tree, for a reason that has nothing to do with the conversion
// under test.
ParsedCalc parseCalcExpressionAtCategory(const String& source, WebCore::CSS::Category category, CSSCalc::ParseSimplification parseSimplification)
{
    CSSTokenizer tokenizer(source);
    auto range = tokenizer.tokenRange();
    if (range.atEnd())
        return { };

    // `currentRule` and `currentProperty` are load-bearing: CSSCalcTree+Parser.cpp:1346-1349
    // rejects the tree-counting functions unless the rule is a Style or Keyframe rule and a real
    // property is named.
    auto parserState = WebCore::CSS::PropertyParserState {
        .context = calcParserContext(),
        .currentRule = StyleRuleType::Style,
        .currentProperty = CSSPropertyWidth,
    };
    auto parserOptions = CSSCalc::ParserOptions {
        .category = category,
        .range = WebCore::CSS::All,
        .allowedSymbols = calcAllowedSymbols(),
        // Both policies default to `Forbid`, which rejects `anchor()` and `anchor-size()`
        // outright at CSSCalcTree+Parser.cpp:1043 and :1136. Those two alternatives also report a
        // child count of 0 regardless of contents (`tuple_size` 0, webkit.org/b/280798).
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
    return { };
}

ParsedCalc parseCalcExpression(const String& source, CSSCalc::ParseSimplification parseSimplification = CSSCalc::ParseSimplification::Eager)
{
    for (auto category : calcCategories) {
        auto parsed = parseCalcExpressionAtCategory(source, category, parseSimplification);
        if (parsed.tree)
            return parsed;
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
// `Negate` or `Invert` at the root of a `Tree`. `serializeMathFunction` has explicit
// `serializeMathFunctionArguments` overloads for `Sum` and `Product` and none for `Negate` or
// `Invert` (CSSCalcTree+Serialization.cpp:403-:411), so a `Negate` root takes the generic argument
// template at :545, which emits the single child with no prefix at all and drops step 4's `-1 * `.
// Only the root position is affected.
//
// The leaf is parsed rather than constructed so that its `Type` matches what the real parser would
// produce.
std::optional<CSSCalc::Tree> constructRootShape(unsigned shape)
{
    auto parsed = parseCalcExpression("calc(1px)"_str);
    if (!parsed.tree)
        return std::nullopt;

    // `parseAndSimplify` folds a one-child wrapper away, so the root of `calc(1px)` is the leaf
    // itself and this unwrap is inert. It is kept so that a future simplification change which
    // stops folding cannot silently turn this into a `Sum` shape.
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
// Simplification is `Tree -> Tree`, unlike serialization's `Tree -> String`, so comparing two
// trees needs a definition of equality, of what counts as NaN, and of which alternatives a tree
// contains. That is what the rest of this block provides.

// A deep, bitwise comparison of two trees. `Tree::operator==` is defaulted and therefore uses
// `double ==`, which is wrong in both directions here: too strict on NaN, and too weak on signed
// zero, which `abs`, `mod`, `round(to-zero)` and `sign` can all normalize.
static bool bitwiseEqualChild(const CSSCalc::Child&, const CSSCalc::Child&);

// Every double compared by bit pattern rather than by value. `bit_cast` rather than `memcmp`, so
// the comparison is on a value and not on an object representation with padding in it.
static bool sameBits(double a, double b)
{
    return std::bit_cast<uint64_t>(a) == std::bit_cast<uint64_t>(b);
}

// One overload per slot shape, matching `rebuildSlot` in CSSCalcTree+Simplification.cpp, so that
// a sixth shape would fail to compile here rather than be compared shallowly.
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
    // unchanged, so the `double` inside `SharingFixed` is the same object's value on both sides.
    return a == b;
}

static bool bitwiseEqualSlot(const Vector<CSSCalc::CalcMix::Item>& a, const Vector<CSSCalc::CalcMix::Item>& b)
{
    if (a.size() != b.size())
        return false;
    for (size_t i = 0; i < a.size(); ++i) {
        // The weight is copied through, so `operator==` for the same reason `Random::Sharing`
        // gets one; the value is a subtree and gets the bitwise walk.
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
    if (a.value.index() != b.value.index())
        return false;

    return WTF::switchOn(a.value,
        [&](const auto& alternative) -> bool {
            using A = std::remove_cvref_t<decltype(alternative)>;
            const auto& other = *get_if<A>(&b.value);
            if constexpr (requires { *alternative; }) {
                using Op = std::remove_cvref_t<decltype(*alternative)>;
                // The per-node `Type` is one of the things serialization cannot see: two trees
                // that serialize identically can carry different types.
                if (!(alternative.type == other.type))
                    return false;
                if constexpr (std::same_as<Op, CSSCalc::Anchor>) {
                    // Not tuple-like (`tuple_size` 0, webkit.org/b/280798), so the generic walk
                    // below would report every pair of anchors equal.
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
                // `hint` is the other thing serialization cannot see: it does not appear in
                // `10%`, and `makeChildWithValueBasedOn` carries it onto a folded percentage.
                return sameBits(alternative.value, other.value) && alternative.hint == other.hint;
            } else if constexpr (std::same_as<A, CSSCalc::CanonicalDimension>)
                return sameBits(alternative.value, other.value) && alternative.dimension == other.dimension;
            else if constexpr (std::same_as<A, CSSCalc::NonCanonicalDimension>)
                return sameBits(alternative.value, other.value) && alternative.unit == other.unit;
            else {
                // `Symbol`, `SiblingCount`, `SiblingIndex`: no `double` anywhere, so the
                // defaulted `operator==` is already the bitwise comparison.
                return alternative == other;
            }
        }
    );
}

// The whole `Tree`, which is four members and not one. `type`, `stage` and
// `requiresConversionData` are all invisible to serialization and all three are compared here.
static bool bitwiseEqualTree(const CSSCalc::Tree& a, const CSSCalc::Tree& b)
{
    return a.stage == b.stage
        && a.requiresConversionData == b.requiresConversionData
        && a.type == b.type
        && bitwiseEqualChild(a.root, b.root);
}

// Visits every node of a subtree, root included, in tree order. Its own walker rather than
// `forAllChildNodes`, because `Anchor` and `AnchorSize` declare `tuple_size` 0 and the generic
// traversal yields no children for them.
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

// Bit `1 << index` for every `Node` alternative the subtree contains. Keyed on the variant index
// rather than on `CSSCalcSwiftNodeKind`, which is what expresses which alternatives were
// declined.
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

// Does the subtree contain a `Sum` with a `Sum` directly among its children, or a `Product` with
// a `Product`? That is the shape css-values-4 step 8.1 (CSSCalcTree+Simplification.cpp:555) and
// the outer half of step 9.1 (`:744`) splice.
//
// A pre-simplified parse cannot present one: the parser simplifies bottom-up, so by the time an
// outer `Sum` is built its inner `Sum` has already been spliced into it.
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

// Whether any numeric leaf in the subtree is a NaN. Computed from the tree, not from the source
// text: `calc(0 / 0)` produces a NaN the text does not mention.
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

// A `Style::ComputedStyle` at a chosen font size, kept alive for the process. Function-local
// statics, not globals, because `CSSToLengthConversionData` holds a reference to the style rather
// than a copy, and because WebCore links with -no_inits.
//
// `setFontDescription`, not `setFontDescriptionWithoutUpdate`: `WithoutUpdate` leaves
// `FontCascade::m_fonts` null (StyleComputedStyleBase.cpp:233), where the non-`WithoutUpdate` form
// calls `FontCascade::update(fontSelector)` at :229 and installs a real `FontCascadeFonts`.
// Without it, `Style::resolveEx` reaches `primaryFont()` through a null `m_fonts` and takes
// EXC_BAD_ACCESS on the first font-metric-relative unit.
//
// Non-const, because `Style::BuilderState::create` takes `ComputedStyle&` and
// `BuilderState::siblingCount()` writes `m_style.setUsesTreeCountingFunctions()` on it.
static Style::ComputedStyle& simplificationStyleStorageAtFontSize(float fontSize)
{
    static NeverDestroyed<Style::ComputedStyle> style16 = [] {
        auto style = Style::ComputedStyle::create();
        auto description = style.fontDescription();
        description.setComputedSize(16);
        style.setFontDescription(WTF::move(description));
        return style;
    }();
    static NeverDestroyed<Style::ComputedStyle> style32 = [] {
        auto style = Style::ComputedStyle::create();
        auto description = style.fontDescription();
        description.setComputedSize(32);
        style.setFontDescription(WTF::move(description));
        return style;
    }();
    // Two present values rather than one: a present/absent boolean would be satisfied by a
    // `canonicalize` that just returned a constant.
    return fontSize > 16 ? style32.get() : style16.get();
}

const Style::ComputedStyle& simplificationStyleAtFontSize(float fontSize)
{
    return simplificationStyleStorageAtFontSize(fontSize);
}

// MARK: - The builder-state fixture: conversion-data kinds 3 and 4
//
// Five `simplify` overloads (`SiblingCount`, `SiblingIndex`, `Random`, `Anchor`, `AnchorSize`)
// return `nullopt` on both paths when `options.conversionData->styleBuilderState()` is null, so
// this fixture supplies a real one. The element is the third of five siblings, so `siblingCount()`
// is 5 and `siblingIndex()` is 3.
//
// `BuilderContext` is left at its default except that `parentStyle` is set to the style itself
// rather than left null, because `CSSToLengthConversionData`'s `parentStyle()` unconditionally
// dereferences it (CSSToLengthConversionData.cpp:56, StyleBuilderState.h:127).
struct SimplificationBuilderStateFixture {
    RefPtr<Settings> settings;
    RefPtr<Document> document;
    RefPtr<Element> element;
    // Re-created between the two comparison runs; see `resetSimplificationBuilderStates`.
    std::optional<UniqueRef<Style::BuilderState>> state16;
    std::optional<UniqueRef<Style::BuilderState>> state32;
};

static SimplificationBuilderStateFixture& simplificationBuilderStateFixture()
{
    static NeverDestroyed<SimplificationBuilderStateFixture> fixture = [] {
        SimplificationBuilderStateFixture f;
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
// Must run between the two comparison paths: the anchor `simplify` overloads set
// `m_invalidAtComputedValueTimeProperties` (StyleBuilderState.cpp:324-327) with no public way to
// clear it. The Document and element are not rebuilt, because `random()`'s base value is cached on
// them by `RandomCachingKey`.
//
// A `CheckedPtr` to a `BuilderState` must not outlive it (`CanMakeCheckedPtr`'s destructor
// RELEASE_ASSERTs), so callers build `SimplificationOptions` after this call and drop them before
// the next one.
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
    // Cleared before either is rebuilt, so the old objects are gone before the new ones exist
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

// Did either anchor overload mark the current property invalid at computed-value time? That is
// the only externally visible effect of `simplify(Anchor&)` on a node with no fallback.
static bool simplificationBuilderStateFlaggedInvalid(float fontSize)
{
    return simplificationBuilderStateAtFontSize(fontSize).isCurrentPropertyInvalidAtComputedValueTime();
}

// Which font size a conversion-data kind selects, and whether it carries a builder state.
// 0 none, 1 a style at 16px, 2 the same at 32px, 3 16px with a builder state, 4 32px with one.
static float simplificationConversionDataFontSize(uint32_t kind)
{
    return (kind == 2 || kind == 4) ? 32.0f : 16.0f;
}

static bool simplificationConversionDataCarriesBuilderState(uint32_t kind)
{
    return kind >= 3;
}


// Nine symbol tables, keyed by kind. Kinds 3..8 are the only way to bind a `Symbol` to a value
// the CSS number grammar cannot spell as a literal -- NaN, an infinity, a negative zero, a
// subnormal or 2^31-1 -- so `mod(r, g)` with `r` bound to NaN is the only way to reach
// `executeMathOperation<Mod>(NaN, NaN)`.
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
        // `simplify(Symbol&)` real work and makes the percentage-typed operations reachable.
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
        // The value neither the defaulted comparison nor serialization can see: `-0.0 == 0.0`,
        // and `calc(-0)` serializes as `calc(0)`.
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
        // Straddling INT_MAX on purpose: `g` is one above it, so `mod(r, g)` and the four
        // rounding strategies run either side of a `double -> int` narrowing boundary.
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

// Eight trees built directly rather than parsed, because no parse produces them. Every
// parse-reachable `Deg2Rad` and `Invert` sits inside a `Product`, which is declined here, and the
// `Min`, `Max`, `Clamp` and `Hypot` branches of shapes 4 to 7 are reached by a parsed corpus
// without their specific outcome being reached.
constexpr unsigned simplificationConstructedShapeCount = 8;

std::optional<CSSCalc::Tree> constructSimplificationShape(unsigned shape)
{
    auto typeOf = [](const auto& op, const CSSCalc::Child& fallbackTypeSource) {
        // The operation's own computed type where it has one, and the child's where `toType`
        // declines, so that no shape carries a type its operation would not have produced.
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
        // `Sin{Deg2Rad{Symbol}}`, the shape the parser builds for `sin(<angle>)`, with the angle
        // a symbol rather than a literal so that it survives the parse-time fold.
        auto child = CSSCalc::makeChild(CSSCalc::Symbol { .id = CSSValueR, .unit = CSSUnitType::Deg });
        auto inner = CSSCalc::Deg2Rad { .angle = CSSCalc::copy(child) };
        auto innerType = typeOf(inner, child);
        auto innerChild = CSSCalc::makeChild(WTF::move(inner), innerType);
        auto op = CSSCalc::Sin { .a = CSSCalc::copy(innerChild) };
        auto type = typeOf(op, innerChild);
        return CSSCalc::Tree { .root = CSSCalc::makeChild(WTF::move(op), type), .type = type, .stage = CSSCalc::Stage::Specified };
    }
    case 2: {
        // `Deg2Rad{CanonicalDimension(1deg)}`, the one shape here that folds:
        // `simplify(Deg2Rad&)` turns a `CanonicalDimension` child into `Number { deg2rad(value) }`
        // unconditionally (CSSCalcTree+Simplification.cpp:986-990).
        auto child = CSSCalc::makeChild(CSSCalc::CanonicalDimension { .value = 1, .dimension = CSSCalc::CanonicalDimension::Dimension::Angle });
        auto op = CSSCalc::Deg2Rad { .angle = CSSCalc::copy(child) };
        auto type = typeOf(op, child);
        return CSSCalc::Tree { .root = CSSCalc::makeChild(WTF::move(op), type), .type = type, .stage = CSSCalc::Stage::Specified };
    }
    case 3: {
        // `Invert{Symbol}`, number-typed. A bare `Invert` is unreachable through a parse, because
        // division always builds the `Product` wrapper around it. The symbol is `CSSValueR` here
        // and in shapes 0, 1 and 6 so that the swept symbol table resolves it.
        auto child = CSSCalc::makeChild(CSSCalc::Symbol { .id = CSSValueR, .unit = CSSUnitType::Number });
        auto op = CSSCalc::Invert { .a = CSSCalc::copy(child) };
        auto type = typeOf(op, child);
        return CSSCalc::Tree { .root = CSSCalc::makeChild(WTF::move(op), type), .type = type, .stage = CSSCalc::Stage::Specified };
    }
    case 4: {
        // `clamp(none, 1px, 1em)`: `convertToMin` succeeding, the only rewrite in the simplifier
        // that produces an operation kind not present in the input (`+Simplification.cpp:1018`).
        //
        // No parse reaches it: `convertToMin` fires when `val` is a `Numeric` and the present
        // bound is a different alternative or unit, and that condition is monotone under
        // canonicalization, so `clamp(none, 1px, 1em)` as text arrives as `min(1px, 1em)` with no
        // `Clamp` in the tree. The mismatch here is `CanonicalDimension` against
        // `NonCanonicalDimension`, which holds with no conversion data and dissolves once one is
        // supplied.
        auto minimum = CSSCalc::ChildOrNone { CSS::Keyword::None { } };
        auto value = CSSCalc::makeChild(CSSCalc::CanonicalDimension { .value = 1, .dimension = CSSCalc::CanonicalDimension::Dimension::Length });
        auto maximum = CSSCalc::makeChild(CSSCalc::NonCanonicalDimension { .value = 1, .unit = CSSUnitType::Em });
        auto op = CSSCalc::Clamp { .min = WTF::move(minimum), .val = CSSCalc::copy(value), .max = CSSCalc::ChildOrNone { CSSCalc::copy(maximum) } };
        auto type = typeOf(op, value);
        return CSSCalc::Tree { .root = CSSCalc::makeChild(WTF::move(op), type), .type = type, .stage = CSSCalc::Stage::Specified };
    }
    case 5: {
        // `clamp(none, 1px, 1)`: `convertToMin` failing, because `toType(Min { 1px, 1 })` returns
        // `std::nullopt` when a `<length>` and a `<number>` do not merge, at which point the C++
        // `simplify` returns `nullopt` and rebuilds the `Clamp` itself.
        //
        // The Swift side cannot: by the time `buildMinMax` answers false, `rewrite` has pushed two
        // operands where the parent expects one and there is no `pop`, so a false answer declines
        // the whole tree. The parser's own type check rejects this text outright, so this is a
        // boundary contract test rather than a coverage test.
        auto minimum = CSSCalc::ChildOrNone { CSS::Keyword::None { } };
        auto value = CSSCalc::makeChild(CSSCalc::CanonicalDimension { .value = 1, .dimension = CSSCalc::CanonicalDimension::Dimension::Length });
        auto maximum = CSSCalc::makeChild(CSSCalc::Number { .value = 1 });
        auto op = CSSCalc::Clamp { .min = WTF::move(minimum), .val = CSSCalc::copy(value), .max = CSSCalc::ChildOrNone { CSSCalc::copy(maximum) } };
        auto type = typeOf(op, value);
        return CSSCalc::Tree { .root = CSSCalc::makeChild(WTF::move(op), type), .type = type, .stage = CSSCalc::Stage::Specified };
    }
    case 6: {
        // `min(r)`: `simplifyForMinMax`'s one-child early return (`+Simplification.cpp:408`). No
        // parse reaches it, because that return does not require the child to be resolved, so
        // `min(r)` as text folds to `calc(r)` during the parse's own simplification. The Swift
        // equivalent is `foldMinMax`'s `folded.count == 1 -> promoteTerm`, which produces
        // `.replacedByTerm` for an unresolved symbol and `.leaf` for a resolved one; the symbol
        // table selects which.
        auto child = CSSCalc::makeChild(CSSCalc::Symbol { .id = CSSValueR, .unit = CSSUnitType::Number });
        auto op = CSSCalc::Min { .children = CSSCalc::Children { Vector<CSSCalc::Child>::from(CSSCalc::copy(child)) } };
        auto type = typeOf(op, child);
        return CSSCalc::Tree { .root = CSSCalc::makeChild(WTF::move(op), type), .type = type, .stage = CSSCalc::Stage::Specified };
    }
    case 7: {
        // `hypot(10%, 20%)`: `simplify(Hypot&)`'s `PercentageTag` arm
        // (`+Simplification.cpp:1269`). No parse reaches it, because `hypot(10%, 20%)` as text
        // constant-folds during the parse and no symbol table can produce a `Percentage` leaf.
        // The C++ stamps `Type::determinePercentHint(options.category)` onto the folded
        // `Percentage` while the Swift side writes `percentHint: 0`, which agrees because the
        // percentage arm is only entered where `determinePercentHint` is `None`. Spelled rather
        // than defaulted because `-Wmissing-designated-field-initializers` is an error here.
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
WEBCORE_EXPORT void webCoreCSSTokenizerSetForceSwiftScannerFailure(bool);
WEBCORE_EXPORT bool webCoreCSSTokenizerTryCreateSucceeds(const char*, size_t);
WEBCORE_EXPORT bool webCoreCSSTokenizerDefaultScannerIsSwift(void);
WEBCORE_EXPORT void webCoreCSSTokenizerBenchIntegrated(const char*, size_t, bool, size_t*, uint64_t*);
WEBCORE_EXPORT void webCoreCSSTokenizerBenchIntegrated16(const char*, size_t, bool, size_t*, uint64_t*, bool*);
WEBCORE_EXPORT uint32_t webCoreCSSTokenizerUnitTrieCompare8(const uint8_t*, size_t);
WEBCORE_EXPORT uint32_t webCoreCSSTokenizerUnitTrieCompare16(const uint16_t*, size_t);
WEBCORE_EXPORT uint64_t webCoreCSSTokenizerUnitTrieCxxCallCount(void);
WEBCORE_EXPORT size_t webCoreCSSTokenizerUnitTrieMaximumLength(void);

// One token's worth of the integration comparison, shared by the 8-bit and the UTF-8 entries
// below so that the two cannot drift apart. Returns nothing when the tokens agree.
//
// `operator==` covers more than it looks: the whitespace run length is compared, via `case
// NonNewlineWhitespaceToken` in CSSParserToken.cpp. What it does not cover is the numeric fields
// of NumberToken and PercentageToken, and, for a DimensionToken, anything but `originalText()`
// whenever the left operand has a non-unit prefix. Both holes are filled below.
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

    // nonInteger, plusSign and minusSign become numericValueType and numericSign, which nothing
    // above compares for NumberToken and PercentageToken: a wrong flag would pass every test here
    // while breaking <integer> validation and nth-child(An+B) sign handling.
    //
    // Compared as bit patterns rather than as doubles, so that +0 and -0 are distinguished, which
    // is exactly the difference a sign flag makes.
    if (expected.type() == NumberToken || expected.type() == PercentageToken || expected.type() == DimensionToken) {
        bool agrees = std::bit_cast<uint64_t>(expected.numericValue()) == std::bit_cast<uint64_t>(actual.numericValue())
            && expected.numericValueType() == actual.numericValueType();
        // numericSign() asserts on NumberToken: it is the only type <an+b> reads it for.
        if (agrees && expected.type() == NumberToken)
            agrees = expected.numericSign() == actual.numericSign();
        if (!agrees)
            return TokenDivergence { 5, static_cast<uint32_t>(expected.numericValueType()), static_cast<uint32_t>(actual.numericValueType()) };
    }

    // A DimensionToken's unit. `operator==` takes its `m_bits.nonUnitPrefixLength == 0` branch off
    // `this`, so with a prefix it falls through to `originalText()` and never compares
    // `unitString()` or `m_bits.unit`. `value()` plus `unitString()` together pin
    // `m_bits.nonUnitPrefixLength` too, since `unitString()` is
    // `value().substring(m_bits.nonUnitPrefixLength)`.
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

// Builds the whole CSSParserToken stream both ways, in one process, and compares the tokens
// themselves: values, numeric values, units, hash types and block types.
WEBCORE_EXPORT CSSTokenizerSwiftValidationResult webCoreCSSTokenizerComparePaths(const char* text, size_t length)
{
    CSSTokenizerSwiftValidationResult result { -1, 0, 0, 0, 0, 0 };
    String source { unsafeMakeSpan(byteCast<Latin1Character>(text), length) };

    // Both tokenizers stay alive for the comparison: each token's value is a view into its own
    // tokenizer's input or string pool.
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

// The same comparison with the source built from UTF-8, so that any non-ASCII text makes
// StringImpl choose its 16-bit representation. That is the only way to exercise the Swift
// tokenizer's UInt16 specialization, since a String built from Latin-1 bytes is always 8-bit.
// `expectedType` comes back as 8 or 16 so the caller can confirm which representation was
// tested.
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
            // expectedType stays the character width the caller asserts on.
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

// The inspector path: both tokenizers built with an observer wrapper attached, then every source
// offset the wrapper was fed compared. A wrapper records one offset per token plus one per
// comment, and startOffset()/endOffset() read them back.
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
    return CSSTokenizer::swiftScannerFailureCountForTesting();
}

// Makes the Swift scanner fail every input, after it has built a chunk, so the
// failure-reporting path is reachable from a test.
WEBCORE_EXPORT void webCoreCSSTokenizerSetForceSwiftScannerFailure(bool force)
{
    CSSTokenizer::setForceSwiftScannerFailureForTesting(force);
}

// Whether tryCreate succeeded. There is no fallback: when the Swift scanner cannot allocate,
// construction fails, and this is how a test observes that rather than inferring it.
WEBCORE_EXPORT bool webCoreCSSTokenizerTryCreateSucceeds(const char* text, size_t length)
{
    String source { unsafeMakeSpan(byteCast<Latin1Character>(text), length) };
    return !!CSSTokenizer::tryCreate(source);
}

// Reports the compile-time choice, so a test can confirm that -DUSE_SWIFT_CSS_TOKENIZER=1
// selects the Swift scanner rather than being silently ignored.
WEBCORE_EXPORT bool webCoreCSSTokenizerDefaultScannerIsSwift(void)
{
    return CSSTokenizer::defaultScanner == CSSTokenizer::Scanner::Swift;
}

// Times a whole CSSTokenizer construction on one path or the other: same tokens, same string
// pool, same double conversions on both sides.
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

// The same timing at 16-bit width. The source is upconverted rather than decoded, so each input
// byte becomes one UTF-16 code unit and the token stream is identical to the 8-bit entry's on the
// same input; decoding UTF-8 instead would change the tokens, which is right for a correctness
// oracle and wrong for a throughput comparison. `outIs16Bit` reports what StringImpl actually
// chose.
WEBCORE_EXPORT void webCoreCSSTokenizerBenchIntegrated16(const char* text, size_t length, bool useSwift, size_t* outTokens, uint64_t* outFold, bool* outIs16Bit)
{
    auto bytes = unsafeMakeSpan(byteCast<Latin1Character>(text), length);
    StringBuilder builder;
    builder.reserveCapacity(length + 4);
    for (auto byte : bytes)
        builder.append(static_cast<char16_t>(byte));
    // A run of pure Latin-1 would collapse back to 8-bit on toString(), so force the 16-bit
    // representation with a character that cannot be represented in 8 bits, in a comment where it
    // costs one token and no interned string. Appended as an explicit char16_t rather than in a
    // literal: a non-ASCII character in a WebKit string literal breaks assertions builds.
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
// that a C++ answer for one input cannot be paired with a Swift answer for another. The
// parameters are packed into 64-bit words because a Swift callee cannot take a `Span`.

static std::atomic<uint64_t> s_unitTrieCxxCalls;

// The cap the Swift entries enforce with a precondition, reported rather than duplicated so that
// a harness cannot sweep longer strings than the entry point can carry.
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

// The same at 16-bit width. A StringView built from a char16_t span keeps its 16-bit
// representation whatever the text is, which is the only way to reach the C++ template's
// char16_t instantiation on Latin-1 content.
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
// paired with a Swift answer for another. Each side names its scanner explicitly rather than
// using the build default, so the comparison is meaningful regardless of
// WK_USE_SWIFT_CSS_COLOR_FAST_PATHS; `webCoreCSSColorFastPathsAreSwift` reports the default.

// Both scanners' answers for one candidate. `argb` is meaningful only when `found`, and is zeroed
// otherwise so that a whole-struct comparison cannot pass on garbage.
struct CSSColorSwiftComparison {
    uint32_t cppARGB;
    uint32_t swiftARGB;
    uint8_t cppFound;
    uint8_t swiftFound;
};

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

// So that a caller can confirm its sweep reached this code rather than being elided.
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

// The two contexts, built once: constructing one per call would dominate a sweep that makes tens
// of millions of them. Function-local statics because WebCore links with -no_inits.
static const CSSParserContext& colorScanContext(bool quirksMode)
{
    static NeverDestroyed<CSSParserContext> quirks { HTMLQuirksMode };
    static NeverDestroyed<CSSParserContext> standard { HTMLStandardMode };
    return quirksMode ? quirks.get() : standard.get();
}

// Runs `kind` both ways over the same characters. `characterSize` picks which of StringImpl's two
// representations the StringView carries; passing 1 narrows 16-bit input to 8-bit first, which is
// the only way to reach the 8-bit template instantiation.
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

// The compile-time default, so that a build which ignored the flag cannot pass as one that
// honoured it.
WEBCORE_EXPORT bool webCoreCSSColorFastPathsAreSwift(void)
{
    return CSSParserFastPaths::defaultColorScanner == CSSParserFastPaths::ColorScanner::Swift;
}

// Forces every comparison to report a decline, so the C++ fall-through path runs. With nothing
// declining otherwise, that fall-through would ship untested.
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

// Reported rather than duplicated by the caller, which could understate it.
WEBCORE_EXPORT size_t webCoreCSSColorTextCapacity(void)
{
    return cssSwiftColorTextCapacity;
}

// One scanner, timed. The `CSSParserContext` and the character narrowing are hoisted out of the
// loop so that what is timed is the scan, and the checksum is returned so the loop cannot be
// optimized away.
WEBCORE_EXPORT uint64_t webCoreCSSColorBench(const uint16_t* units, size_t length, unsigned characterSize, unsigned kind, bool quirksMode, bool useSwift, uint64_t repetitions)
{
    auto wide = unsafeMakeSpan(reinterpret_cast<const char16_t*>(units), length);
    auto& context = colorScanContext(quirksMode);
    auto scanner = useSwift ? CSSParserFastPaths::ColorScanner::Swift : CSSParserFastPaths::ColorScanner::Cpp;

    std::array<Latin1Character, 256> narrowed;
    RELEASE_ASSERT(length <= narrowed.size());
    for (size_t i = 0; i < length; ++i) {
        RELEASE_ASSERT(wide[i] < 256);
        narrowed[i] = static_cast<Latin1Character>(wide[i]);
    }
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
// `CSSCalc::serializationForCSS` is a pure `(Tree, Range, SerializationContext) -> String`: parse
// a calc expression, serialize the resulting tree both ways, compare. Both paths run on the same
// `Tree` object inside one call, so a C++ answer for one expression can never be paired with a
// Swift answer for another. Each side names its serializer explicitly rather than taking the
// build default, so the comparison holds regardless of WK_USE_SWIFT_CSS_CALC_SERIALIZATION.

// One expression's worth of comparison, plus fields that let a caller confirm the Swift path was
// exercised.
struct CSSCalcSerializationComparison {
    // 1 if the text parsed as a calc value at some category. 0 means the case exercised nothing.
    uint32_t parsed;
    uint32_t agree;
    // 1 if the Swift path declined this tree, so `agree` is the C++ compared against itself.
    uint32_t declined;
    // How many nodes the Swift walk visited and which kinds it stood on, so a caller can confirm
    // it descended into the tree rather than stopping at the root.
    uint32_t nodeCount;
    uint32_t kindMask;
    uint32_t cppLength;
    uint32_t swiftLength;
    // Which CSS::Category the expression parsed at.
    uint32_t category;
    // The kind of the tree's root, which the mask above cannot answer: the root is the one
    // position where the C++ drops step 4's `-1 * ` prefix.
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

// So that a caller can confirm its sweep reached this code rather than being elided.
static std::atomic<uint64_t> s_calcCompareCalls;

// Reported here rather than duplicated by the caller, whose own count could go stale.
WEBCORE_EXPORT uint32_t webCoreCSSCalcNodeKindCount(void)
{
    // The last case, so that adding a kind without updating this line under-reports the count.
    return static_cast<uint32_t>(CSSCalc::CSSCalcSwiftNodeKind::AnchorSizeFunction) + 1;
}

// Serializes one of the directly-constructed root shapes on the named serializer. Returns the
// length, or 0 if the leaf could not be parsed. See `constructRootShape` for why no parse
// reaches these.
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

// Serializes one tree both ways and compares; both see the same `Tree` object.
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
// A parse always produces `Stage::Specified`, and the one place in WebCore that writes
// `Stage::Computed` (StyleCalculationTree+Conversion.cpp:357) needs a `Style::Calculation::Tree`
// and conversion data this entry does not have, so the stage is set directly on an already-parsed
// tree. The stage only changes serialization for a numeric root, so this only tests something if
// the root is one.
WEBCORE_EXPORT CSSCalcSerializationComparison webCoreCSSCalcCompareSerializationStaged(const char* text, size_t length, unsigned computedStage, double rangeMinimum, double rangeMaximum, char* cppOut, size_t cppCapacity, char* swiftOut, size_t swiftCapacity)
{
    s_calcCompareCalls.fetch_add(1, std::memory_order_relaxed);

    CSSCalcSerializationComparison result { 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    String source { unsafeMakeSpan(byteCast<Latin1Character>(text), length) };

    auto parsed = parseCalcExpression(source);
    if (!parsed.tree)
        return result;

    // The parsed tree with only its stage replaced, rebuilt rather than mutated in place because
    // `Tree::stage` is not something a caller of `parseCalcExpression` should be able to reach.
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

// Serialization must be idempotent under reparsing: serialize(parse(s)) ==
// serialize(parse(serialize(parse(s)))). A reference-free check, so it can fail even where the
// C++ and Swift serializers agree with each other.
//
// `serializerKind` is 0 for C++ and 1 for Swift. Returns 0 stable, 1 first parse failed, 2 reparse
// failed, 3 unstable.
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

// The compile-time default, so that a build which ignored the flag cannot pass as one that
// honoured it.
WEBCORE_EXPORT bool webCoreCSSCalcSerializationIsSwift(void)
{
    return CSSCalc::defaultSerializer == CSSCalc::Serializer::Swift;
}

// Forces the Swift path to decline every tree, so the C++ fall-through runs even with the gate on.
// A fall-through reachable only by input eventually ships untested.
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
// A sibling of the serialization block above, not an extension of it: simplification is
// `Tree -> Tree`, so every field below exists because a tree comparison has failure modes a string
// comparison does not.
//
// `parseAndSimplify` simplifies incrementally during the parse, at eighteen per-operation
// `simplify(Op&, ...)` sites in CSSCalcTree+Parser.cpp plus one `copyAndSimplify(const Child&)` at
// `:1638`, and has no terminal whole-tree pass. A parsed tree is therefore already at a fixed
// point for the options it was parsed with, so the comparison entry parses at a fixed baseline and
// simplifies under a caller-supplied set instead.

// The swept options, passed by pointer rather than as nine scalars so that an axis can be added
// without re-spelling the signature of every entry.
struct CSSCalcSimplificationOptionsSpec {
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
    // `CSSCalc::ParseSimplification` as a `uint32_t`: 0 Eager, 1 Terminal, 2 None. Only 0 and 2
    // are used: under `None` the harness gets the raw tree and `compareSimplificationOfTree` runs
    // both simplifier paths on that one object, and its `Simplifier::Cpp` result is the `Terminal`
    // tree, so both comparisons come out of one call.
    //
    // Appended last: a harness built against the previous layout passes a 40-byte struct, so this
    // field reads whatever follows it, and `webCoreCSSCalcSimplificationUnsimplifiedParseAvailable`
    // rather than this field is what says the path is real.
    uint32_t parseSimplification;
};

// One case's worth of comparison. Mirrored field for field by `struct Comparison` in
// simplifycheck.cpp; the order is ABI and the two must be edited together.
struct CSSCalcSimplificationComparison {
    uint32_t parsed;
    // The Swift side's decision, and, when it declined, the alternative that caused it. 0xFF means
    // it declined without naming one.
    uint32_t declined;
    uint32_t declineKind;
    // (a) the verdict: deep, bitwise over leaf doubles, plus every `Type`, the stage and the
    // conversion-data flag. The only one of the three that can see a signed zero.
    uint32_t agree;
    // (b) `Tree::operator==`, defaulted. Reported beside (a) rather than instead of it, since it
    // disagrees in two directions: too strict on NaN, too weak on signed zero.
    uint32_t agreeDefaulted;
    // (c) both result trees through the C++ serializer, so that a serialization defect cannot be
    // mistaken for one here. Diagnostic only.
    uint32_t agreeSerialized;
    uint32_t containsNaN;
    uint32_t cppChangedInput;
    uint32_t swiftChangedInput;
    uint32_t cppIdempotent;
    uint32_t swiftIdempotent;
    uint32_t cppCanSimplify;
    uint32_t swiftCanSimplify;
    // Whether `canSimplify(t) == false` really implied `copyAndSimplify(t) == t`, which is the
    // check with information in it: `canSimplify` itself is one bit per tree.
    uint32_t cppCanSimplifySound;
    uint32_t swiftCanSimplifySound;
    uint32_t cppPreservedStageAndFlag;
    uint32_t swiftPreservedStageAndFlag;
    uint32_t inputNodeCount;
    uint32_t outputNodeCount;
    uint32_t inputRootKind;
    uint32_t outputRootKind;
    uint32_t parseCategory;
    // Masks over `Node` alternative indices. The Swift side's must be a subset of the input's, and
    // equal to it on any case it did not decline.
    uint64_t inputKindMask;
    uint64_t swiftKindMask;
    uint32_t cppLength;
    uint32_t swiftLength;
    // Did this side call `BuilderState::setCurrentPropertyInvalidAtComputedValueTime()`? That is
    // the only observable effect of `simplify(Anchor&)` and `simplify(AnchorSize&)` on a node with
    // no fallback: both return `std::exchange(node.fallback, { })`, which is `nullopt` when there
    // is no fallback, and so is indistinguishable in the output tree. Read after each run from a
    // freshly created builder state.
    uint32_t cppInvalidAtComputedValueTime;
    uint32_t swiftInvalidAtComputedValueTime;

    // The following six fields are written only when `spec->parseSimplification` selects `None`.
    // The baseline half is computed here rather than by a second call from the harness, so that
    // the two parses are one pair of live `Tree` objects and `bitwiseEqualTree` -- the only oracle
    // here that can see a signed zero or a per-node `Type` -- can be used across them.
    uint64_t baselineKindMask;
    // A `Sum` directly under a `Sum`, or a `Product` directly under a `Product`, anywhere in the
    // input: css-values-4 step 8.1 / 9.1, the splice at CSSCalcTree+Simplification.cpp:555 and
    // :744. A pre-simplified parse cannot present one, because the inner node was spliced at its
    // own `simplify` call.
    uint32_t inputHasSpliceableNesting;
    // Did the same text parse with eager simplification on? This must equal `parsed`: suppressing
    // simplification changes the tree and never the parse, because the parse-time type is computed
    // from the unsimplified children in both paths.
    uint32_t baselineParsed;
    uint32_t baselineNodeCount;
    uint32_t baselineRootKind;
    // `bitwiseEqualTree(copyAndSimplify(unsimplifiedTree, swept, Cpp), baselineParsedTree)`: at the
    // baseline tuple, the whole test of whether the parser's eager per-operation `simplify(Op&)`
    // sites and one terminal whole-tree `copyAndSimplify` compute the same thing. Meaningless at a
    // swept tuple, where the two are simplified under different options.
    uint32_t eagerMatchesWholeTree;
    // Was `eagerMatchesWholeTree` actually computed? It is written by
    // `webCoreCSSCalcCompareSimplification` only, and only when a baseline tree exists, so a zero
    // in the field above has two meanings and a reader must not take the wrong one.
    uint32_t eagerTerminalComputed;
};

// The layout is pinned rather than merely described. These two structs cross a `dlsym` boundary
// into a caller that declares its own copies, so a field inserted on one side and not the other
// does not fail to link: it shifts every field after it and compares unrelated fields silently.
static_assert(sizeof(CSSCalcSimplificationOptionsSpec) == 48);
static_assert(offsetof(CSSCalcSimplificationOptionsSpec, rangeMinimum) == 8);
static_assert(offsetof(CSSCalcSimplificationOptionsSpec, conversionDataKind) == 24);
static_assert(offsetof(CSSCalcSimplificationOptionsSpec, stage) == 36);
static_assert(offsetof(CSSCalcSimplificationOptionsSpec, parseSimplification) == 40);
// The trailing fields land in what was tail padding, so a size assertion alone would not notice
// them; the offsets are asserted too.
static_assert(sizeof(CSSCalcSimplificationComparison) == 152);
static_assert(offsetof(CSSCalcSimplificationComparison, parseCategory) == 84);
static_assert(offsetof(CSSCalcSimplificationComparison, inputKindMask) == 88);
static_assert(offsetof(CSSCalcSimplificationComparison, swiftKindMask) == 96);
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
WEBCORE_EXPORT unsigned webCoreCSSCalcSimplificationSwiftDeclineCount(void);
WEBCORE_EXPORT uint64_t webCoreCSSCalcSimplificationHarnessCallCount(void);
WEBCORE_EXPORT uint32_t webCoreCSSCalcChildAlternativeCount(void);
WEBCORE_EXPORT uint32_t webCoreCSSCalcCategoryCount(void);
WEBCORE_EXPORT uint32_t webCoreCSSCalcConstructedShapeCount(void);
WEBCORE_EXPORT uint64_t webCoreCSSCalcSimplificationBench(const char*, size_t, bool, uint32_t, uint32_t*);
WEBCORE_EXPORT uint64_t webCoreCSSCalcParseBench(const char*, size_t, unsigned parseSimplification, uint32_t iterations, uint32_t* outParsed, uint32_t* outNodeCount, uint32_t* outCategory);
struct CSSCalcParseComparison {
    uint8_t swiftOutcome;
    uint8_t declineReason;
    bool cppParsed;
    // Whether the two trees are equal. Meaningful only when both paths parsed.
    bool treesAgree;
    // Whether `requiresConversionData` matched. It reaches the caller on the tree and feeds the
    // caller's own conversion-data decision, so a disagreement is a real divergence even when the
    // trees match. Both raw values are reported too.
    bool conversionDataAgrees;
    bool cppRequiresConversionData;
    bool swiftRequiresConversionData;
    uint8_t category;
    // Boundary self-tests. Each is a fixed-input probe of one thing the grammar reads through
    // the boundary, so a wiring fault shows up as a named failure rather than as a wrong outcome.
    //
    // What the cursor reports for token 0 of the inner range, against what the range itself says.
    // They must be equal.
    uint8_t cursorFirstTokenType;
    uint8_t rangeFirstTokenType;
    //   `emRequiresConversionData` -- the unit predicate on a unit that certainly needs conversion
    //   data (`em`). Must be true; a false here means the predicate is mis-wired, not that the
    //   grammar forgot to set the flag.
    bool emRequiresConversionData;
    // 0 = the input is not a `calc()` this entry can drive, so the case is SKIPPED rather than
    // passed -- a skipped case must never read as agreement.
    bool applicable;
};

WEBCORE_EXPORT bool webCoreCSSCalcCompareParseTokens(const char*, size_t, uint64_t* outCpp, uint64_t* outSwift, uint32_t* outTokenCount);
WEBCORE_EXPORT CSSCalcParseComparison webCoreCSSCalcCompareParse(const char*, size_t, bool withSymbols);
WEBCORE_EXPORT uint64_t webCoreCSSCalcSimplificationPrimitiveBench(uint32_t, uint32_t);
WEBCORE_EXPORT bool webCoreCSSCalcSimplificationFontMetricsAvailable(void);
WEBCORE_EXPORT bool webCoreCSSCalcSimplificationBuilderStateAvailable(void);
WEBCORE_EXPORT unsigned webCoreCSSCalcSimplificationFixtureSiblingCount(void);
WEBCORE_EXPORT unsigned webCoreCSSCalcSimplificationFixtureSiblingIndex(void);

// Does this WebCore understand `CSSCalcSimplificationOptionsSpec::parseSimplification`? A
// framework built before that field existed still exports the comparison entry, still reads the
// first 40 bytes of the spec, ignores the flag, and hands back a comparison over a tree the C++
// already simplified, which would agree on everything and read as a pass. A harness must dlsym
// this separately and skip its unsimplified-tree comparison when it is missing.
WEBCORE_EXPORT bool webCoreCSSCalcSimplificationUnsimplifiedParseAvailable(void);

// Decomposes comparison (a)'s bitwise verdict into which of `bitwiseEqualTree`'s four components
// disagreed. Diagnostic only; see the definition for the bit assignment.
WEBCORE_EXPORT uint32_t webCoreCSSCalcSimplificationEagerTerminalDelta(const char*, size_t);

// The raw bits of each path's result root, for a case where both paths serialize `calc(NaN)` and the
// bitwise oracle still says no. Diagnostic only.
WEBCORE_EXPORT bool webCoreCSSCalcSimplificationRootBits(const char*, size_t, const CSSCalcSimplificationOptionsSpec*, uint64_t*, uint64_t*);

static std::atomic<bool> s_eagerTerminalPerturb;

// Perturbs comparison (a), so that a caller checking it has a negative control that reaches it.
// See the definition.
WEBCORE_EXPORT void webCoreCSSCalcSimplificationSetEagerTerminalPerturb(bool);

struct CSSCalcStyleRoundTripResult {
    uint32_t parsed;        // the text parsed as a calc at the requested category
    uint32_t nodeCount;     // of the CSS tree that came back
    uint32_t rootKind;      // its root's `Node` alternative index
    uint32_t stage;         // `Tree::stage`, which `toCSS` sets to `Computed`
    uint32_t textLength;    // the true length, so a truncated compare cannot read as agreement
    uint32_t styleRootKind; // the intermediate `Style::Calculation::Tree`'s root alternative
    uint32_t styleDepth;    // and its depth, so a corpus that reaches only leaves cannot read as coverage
    uint64_t kindMask;      // 1 << index for every alternative the CSS tree contains
    uint64_t digest;        // see above
    uint64_t treeTypeBits;  // `Tree::type`, which the round trip recomputes
};
WEBCORE_EXPORT CSSCalcStyleRoundTripResult webCoreCSSCalcStyleRoundTrip(const char*, size_t, uint32_t, uint32_t, char*, size_t);

// Compares `canonicalize` directly, parameterized over the full `CSSUnitType` range rather than
// only the units a parsed CSS corpus happens to use; `canonicalize`
// (CSSCalcTree+Simplification.cpp:169-287) is a seventy-case `switch`.
//
// Four paths, each able to fail where the others cannot: reference arithmetic computed directly
// from <WebCore/CSSUnitConversions.h> and <wtf/MathExtras.h>, the same headers both ported paths
// read; `canonicalize` itself, unmediated by a tree walk; the C++ simplifier over a
// `NonCanonicalDimension`-rooted tree, which is how `canonicalize` is reached in production; and
// the Swift `canonicalizedDimension` over the same tree object.
//
// The unit crosses as a `uint32_t` so that callers can pass values outside the enum too; `built`
// is 0 for those.
struct CSSCalcCanonicalizationComparison {
    double cppValue;
    double swiftValue;
    // The `canonicalize`'s own answer. Meaningful only when `referenceResolved`.
    double referenceValue;
    uint32_t cppUnitType;
    uint32_t swiftUnitType;
    uint32_t referenceUnitType;
    // `Node`'s alternative index of each path's result root, so that "it stayed a
    // NonCanonicalDimension" and "it became a CanonicalDimension" are distinguishable.
    uint32_t cppAlternative;
    uint32_t swiftAlternative;
    // Did `canonicalize` return a value at all. `nullopt` for a relative unit with no conversion
    // data, and for the units a `NonCanonicalDimension` can never hold.
    uint32_t referenceResolved;
    // Did the Swift side decline the tree. A decline is invisible in an output comparison.
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
// counter advances by up to three per case, while this one counts one per declining comparison.
static std::atomic<unsigned> s_simplifyComparisonDeclines;

// One `SimplificationOptions` from one spec, shared by the two comparison entries below and by
// `webCoreCSSCalcCompareCanonicalization`, so that all three read the same conversion data.
//
// The returned options hold a `CheckedPtr` to the builder state at kinds 3 and 4, so the result
// must be destroyed before `resetSimplificationBuilderStates` runs again: `CanMakeCheckedPtr`'s
// destructor RELEASE_ASSERTs the pointer count is zero.
static CSSCalc::SimplificationOptions makeSimplificationOptions(const CSSCalcSimplificationOptionsSpec* spec)
{
    auto conversionData = [&]() -> std::optional<CSSToLengthConversionData> {
        if (!spec->conversionDataKind)
            return std::nullopt;
        auto fontSize = simplificationConversionDataFontSize(spec->conversionDataKind);
        if (simplificationConversionDataCarriesBuilderState(spec->conversionDataKind)) {
            // The two-argument constructor, the only one that sets `m_styleBuilderState`. It also
            // derives `m_rootStyle`, `m_parentStyle`, `m_renderView` and
            // `m_elementForContainerUnitResolution` from the builder state rather than from the
            // arguments (CSSToLengthConversionData.cpp:52-61), which is why the fixture's
            // `BuilderContext` leaves `rootElementStyle` null: that keeps the `rem` family
            // behaving the same at kind 3 as at kind 1.
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

// Everything the two comparison entries share. Both paths run on the same input `Tree` object
// inside one call, which is what makes it impossible to pair a C++ answer for one case with a
// Swift answer for another. `baselineTree` is the same text parsed with the parser's eager
// simplification left on, supplied only when `spec->parseSimplification` selects `None`.
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
        // only place in WebCore that writes `Computed` needs conversion data this entry does not
        // have.
        .stage = spec->stage ? CSSCalc::Stage::Computed : CSSCalc::Stage::Specified,
        .requiresConversionData = inputTree.requiresConversionData,
    };

    // The baseline tree gets the same `stage` override the input does, so that
    // `eagerMatchesWholeTree` below compares the two simplification routes and not two stages.
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

    // The two comparison runs use separate builder states, and each one's options are scoped so
    // that the `CheckedPtr` inside them is released before the next reset. Scoped to only the
    // kinds that need it: at conversion-data kinds 0 to 2 nothing touches the fixture, so the
    // Document is never created.
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

    // Diagnostic from here down, sharing one further builder state built after the two comparison
    // runs, so that no `CheckedPtr` from it is alive across either reset above.
    if (usesBuilderState)
        resetSimplificationBuilderStates();
    auto options = makeSimplificationOptions(spec);

    result.declined = declinesAfter != declinesBefore ? 1 : 0;
    if (result.declined)
        s_simplifyComparisonDeclines.fetch_add(1, std::memory_order_relaxed);
    result.declineKind = CSSCalc::webCoreCSSCalcSimplificationLastDeclineAlternative();
    result.swiftKindMask = CSSCalc::webCoreCSSCalcSimplificationLastKindMask();

    // Comparison (a) is not computed here. `armOptions` is the spec's options, whose category the
    // harness does not pin, while the eager tree was simplified at whichever category the parse
    // succeeded at, so the two would differ for a reason that is the caller's own.
    // `webCoreCSSCalcCompareSimplification` computes it against the parse's options and overwrites
    // the field.

    result.agree = bitwiseEqualTree(cppTree, swiftTree) ? 1 : 0;
    result.agreeDefaulted = cppTree == swiftTree ? 1 : 0;
    result.containsNaN = (subtreeContainsNaN(cppTree.root) || subtreeContainsNaN(swiftTree.root)) ? 1 : 0;

    result.cppChangedInput = bitwiseEqualTree(input, cppTree) ? 0 : 1;
    result.swiftChangedInput = bitwiseEqualTree(input, swiftTree) ? 0 : 1;
    result.outputNodeCount = nodeCountOfSubtree(cppTree.root);
    result.outputRootKind = static_cast<uint32_t>(cppTree.root.value.index());

    // Idempotence, checked per side and reference-free, so it can fail on a case where the two
    // sides agree with each other. Compared bitwise: the defaulted comparison would report every
    // NaN result as non-idempotent.
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

// Throughput of one path of whole-tree simplification. One entry taking a path selector rather
// than two frameworks, so that both paths come out of one binary and are interleaved inside one
// process, with no cross-build drift to attribute.
//
// The parse happens once, outside the loop, because the thing being timed is simplification and a
// parse costs far more than one simplification of what it produced; the caller amortises it by
// passing a large `iterations`. `fold` exists only to stop the loop being eliminated.
//
// With the bridge enabled, the Swift path pays five relaxed atomics per whole-tree call that the
// C++ path does not (CSSCalcTree+Simplification.cpp:2516-2523), so the comparison is biased against
// Swift by that much. It is a per-tree cost, not per node.
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

// Throughput of one `CSSCalc::ParseSimplification` mode of the whole parse.
//
// A second bench entry rather than a parameter on the one above, because that one parses once
// outside its loop and this one puts the parse inside it. Moving work between the parse and
// simplification is invisible to a simplification-only band, which would see a terminal pass
// arrive and never see the eager passes leave.
//
// One category, not eleven, which is why `parseCalcExpressionAtCategory` is separate: timing the
// category loop charges the eager path for simplifying every rejected parse, which is enough to
// reverse the sign. `outNodeCount` is what lets a caller refuse to time a build that ignores the
// mode argument, and is taken outside the loop because a tree walk inside it would be proportional
// to tree size. `fold` exists only to stop the loop being eliminated.
//
// With the bridge enabled, the `Terminal` mode's one whole-tree Swift call pays five relaxed
// atomics that `Eager` does not, per tree rather than per node.
WEBCORE_EXPORT uint64_t webCoreCSSCalcParseBench(const char* text, size_t length, unsigned parseSimplification, uint32_t iterations, uint32_t* outParsed, uint32_t* outNodeCount, uint32_t* outCategory)
{
    String source { unsafeMakeSpan(byteCast<Latin1Character>(text), length) };
    auto mode = static_cast<CSSCalc::ParseSimplification>(parseSimplification);

    // One full parse outside the loop, to find the accepting category and fill the out-parameters.
    // Its cost is amortised away by `iterations`.
    auto probe = parseCalcExpression(source, mode);
    if (outParsed)
        *outParsed = probe.tree ? 1 : 0;
    if (outNodeCount)
        *outNodeCount = probe.tree ? nodeCountOfSubtree(probe.tree->root) : 0;
    if (outCategory)
        *outCategory = static_cast<uint32_t>(probe.category);
    if (!probe.tree)
        return 0;
    auto category = probe.category;

    uint64_t fold = 0;
    for (uint32_t i = 0; i < iterations; ++i) {
        auto parsed = parseCalcExpressionAtCategory(source, category, mode);
        if (!parsed.tree)
            return 0;
        fold = fold * 1000003 + static_cast<uint64_t>(parsed.tree->root.index());
        fold = fold * 1000003 + static_cast<uint64_t>(parsed.tree->type.percent);
    }
    return fold;
}

// The token boundary's differential: does Swift see every token, in order, with every field
// intact?
//
// Both sides fold the same seven fields of the same tokens into the same FNV-style hash, but they
// read them differently: C++ reads `CSSParserToken`'s accessors directly, and Swift reads the
// 24-byte `CSSCalcSwiftToken` POD through `CSSCalcSwiftParseCursor`. A shared implementation would
// agree with itself and prove nothing, so the duplication of the two guards below is deliberate.
//
// The loop runs to `count` inclusive, so the EOF-past-the-end behaviour both sides rely on is part
// of what is compared. Varied: token type, unit, numeric value, ident and function IDs, delimiter,
// block type and token order. Held fixed: the input is Latin-1, and nothing here sweeps 16-bit
// input or nesting beyond what the corpus contains.
WEBCORE_EXPORT bool webCoreCSSCalcCompareParseTokens(const char* text, size_t length, uint64_t* outCpp, uint64_t* outSwift, uint32_t* outTokenCount)
{
    String source { unsafeMakeSpan(byteCast<Latin1Character>(text), length) };
    CSSTokenizer tokenizer(source);
    auto range = tokenizer.tokenRange();

    uint64_t hash = 0xcbf29ce484222325ULL;
    auto mix = [&](uint64_t value) { hash = (hash ^ value) * 0x100000001b3ULL; };

    auto count = static_cast<uint32_t>(range.size());
    for (uint32_t i = 0; i <= count; ++i) {
        auto& token = range.peek(i);
        auto type = token.type();
        bool isNumeric = type == NumberToken || type == PercentageToken || type == DimensionToken;
        double numericValue = isNumeric ? token.numericValue() : 0;
        // Bit pattern, not the value: it is what distinguishes -0.0 from 0.0 and makes two NaNs
        // with different payloads compare unequal, both of which the Swift side folds the same way.
        mix(std::bit_cast<uint64_t>(numericValue));
        mix(static_cast<uint64_t>(token.id()));
        mix(static_cast<uint64_t>(token.functionId()));
        mix(static_cast<uint64_t>(type == DelimiterToken ? token.delimiter() : u'\0'));
        mix(static_cast<uint64_t>(token.unitType()));
        mix(static_cast<uint64_t>(type));
        mix(static_cast<uint64_t>(token.getBlockType()));
    }

    auto cursor = CSSCalc::CSSCalcSwiftParseCursor { range };
    uint64_t swiftHash = WebCore::cssCalcParseTokenChecksumSwift(cursor);

    if (outCpp)
        *outCpp = hash;
    if (outSwift)
        *outSwift = swiftHash;
    if (outTokenCount)
        *outTokenCount = count;
    return hash == swiftHash;
}

// The stage D grammar's differential: does the Swift `<calc-sum>` grammar build the SAME TREE the
// C++ parser builds, for the inputs it claims to cover?
//
// The C++ arm runs at `ParseSimplification::None`, because the Swift grammar does not simplify --
// comparing against `Terminal` would compare a simplified tree with an unsimplified one and every
// case would "fail" for a reason that is not a defect.
//
// Trees are compared by VALUE with `Child::operator==`, which compares the stored `Type` and walks
// the children. Not by serialization: `Product{6px, 4px}` and its simplified form serialize the
// same, and 57 corpus cases already carry exactly that class of divergence.
//
// `withSymbols` selects whether `ParserOptions::allowedSymbols` is populated. It is an AXIS, not a
// convenience: with a non-empty table the Swift grammar declines every `IdentToken` on purpose
// (the C++ checks the symbol table before the five constants, so an id in both would resolve
// differently), and the constants path is only reachable with the table empty. A run that only
// used one value of this flag would leave one of those two behaviours untested.

WEBCORE_EXPORT CSSCalcParseComparison webCoreCSSCalcCompareParse(const char* text, size_t length, bool withSymbols)
{
    CSSCalcParseComparison result { };
    String source { unsafeMakeSpan(byteCast<Latin1Character>(text), length) };

    CSSTokenizer tokenizer(source);
    auto cppRange = tokenizer.tokenRange();
    if (cppRange.atEnd())
        return result;

    // Only plain `calc()` / `-webkit-calc()`: stage D covers no other function, and driving it with
    // one would be asking it to decline, which the corpus does separately.
    auto functionId = cppRange.peek().functionId();
    if (functionId != CSSValueCalc && functionId != CSSValueWebkitCalc)
        return result;
    result.applicable = true;

    // The category is swept, not fixed: pinning it to `Length` makes the C++ path reject `calc(1)`,
    // `calc(2 * 3)` and every constant, which reads as "Swift parsed, C++ did not".
    // `parseCalcExpression` tries each category until one accepts, and the Swift path is then driven
    // at that category, so the two paths are asked the same question.
    auto parserState = WebCore::CSS::PropertyParserState {
        .context = calcParserContext(),
        .currentRule = StyleRuleType::Style,
        .currentProperty = CSSPropertyWidth,
    };
    auto makeParserOptions = [&](WebCore::CSS::Category category) {
        return CSSCalc::ParserOptions {
            .category = category,
            .range = WebCore::CSS::All,
            .allowedSymbols = withSymbols ? calcAllowedSymbols() : CSSCalcSymbolsAllowed { },
            .propertyOptions = { },
        };
    };
    auto makeSimplificationOptions = [&](WebCore::CSS::Category category) {
        return CSSCalc::SimplificationOptions {
            .category = category,
            .range = WebCore::CSS::All,
            .conversionData = std::nullopt,
            .symbolTable = { },
            .allowZeroValueLengthRemovalFromSum = false,
        };
    };

    // The C++ path, unsimplified, at the first category that accepts. Its own copy of the range,
    // because a parse consumes one.
    std::optional<CSSCalc::Tree> cppTree;
    auto category = calcCategories[0];
    for (auto candidate : calcCategories) {
        auto cppParseRange = cppRange;
        auto tree = CSSCalc::parseAndSimplify(cppParseRange, parserState, makeParserOptions(candidate), makeSimplificationOptions(candidate), CSSCalc::ParseSimplification::None);
        if (tree && cppParseRange.atEnd()) {
            cppTree = WTF::move(tree);
            category = candidate;
            break;
        }
    }
    result.cppParsed = cppTree.has_value();
    result.category = static_cast<uint8_t>(category);
    auto simplificationOptions = makeSimplificationOptions(category);

    // The Swift path, over the tokens inside the function, which is what `consumeFunction` leaves
    // and therefore what `parseCalcFunction` sees.
    auto swiftRange = cppRange;
    auto innerRange = CSSPropertyParserHelpers::consumeFunction(swiftRange);

    // The operand stack is only complete inside CSSCalcTree+Simplification.cpp, so the driver lives
    // there; this is also the shape `parseAndSimplify` will call when the parse path is gated on.
    CSSCalc::Child root = CSSCalc::Number { .value = 0 };
    auto swiftResult = CSSCalc::cssCalcSwiftParseIntoChild(innerRange, CSSCalc::CSSCalcSwiftParseOptions {
        .category = category,
        .absoluteLengthUnitsOnly = false,
        .hasAllowedSymbols = withSymbols,
    }, simplificationOptions, root);

    result.swiftOutcome = swiftResult.outcome;
    result.declineReason = swiftResult.declineReason;

    if (swiftResult.outcome != static_cast<uint8_t>(CSSCalc::CSSCalcSwiftParseOutcome::Parsed))
        return result;

    result.swiftRequiresConversionData = swiftResult.requiresConversionData;
    result.emRequiresConversionData = CSSCalc::cssCalcSwiftUnitRequiresConversionData(static_cast<uint16_t>(CSSUnitType::Em));
    {
        auto probeCursor = CSSCalc::CSSCalcSwiftParseCursor { innerRange };
        result.cursorFirstTokenType = probeCursor.tokenCount() ? static_cast<uint8_t>(probeCursor.tokenAt(0).type) : 0xFF;
        result.rangeFirstTokenType = innerRange.atEnd() ? 0xFF : static_cast<uint8_t>(innerRange.peek().type());
    }
    if (result.cppParsed) {
        result.cppRequiresConversionData = cppTree->requiresConversionData;
        result.treesAgree = cppTree->root == root && cppTree->type == swiftResult.type;
        result.conversionDataAgrees = cppTree->requiresConversionData == swiftResult.requiresConversionData;
    }
    return result;
}

WEBCORE_EXPORT CSSCalcSimplificationComparison webCoreCSSCalcCompareSimplification(const char* text, size_t length, const CSSCalcSimplificationOptionsSpec* spec, char* cppOut, size_t cppCapacity, char* swiftOut, size_t swiftCapacity)
{
    // Counted before the parse filter, so that a caller's call tally matches even for cases that
    // do not parse: it counts calls made, not cases run.
    s_simplifyCompareCalls.fetch_add(1, std::memory_order_relaxed);

    CSSCalcSimplificationComparison result { };
    result.declineKind = 0xFF;
    String source { unsafeMakeSpan(byteCast<Latin1Character>(text), length) };

    // Spec value 3 is a control rather than a `ParseSimplification`: parse eagerly, but compute
    // the baseline anyway, so that a caller can reproduce the state of having asked for
    // unsimplified trees and received pre-simplified ones. Passing `Eager` does not reproduce it,
    // because with no baseline computed the failure is indistinguishable from no case getting past
    // the parse-agreement check. `Eager` on its own stays free, so a large sweep pays no second
    // parse.
    auto specMode = spec->parseSimplification;
    bool forceSimplifiedInput = specMode == 3;
    auto mode = forceSimplifiedInput
        ? CSSCalc::ParseSimplification::Eager
        : static_cast<CSSCalc::ParseSimplification>(specMode);

    // The second parse happens only when the axis is off its default value. It is the eager tree,
    // today's production output, and it is what both comparison (a) and the vacuity checks are
    // computed against.
    std::optional<CSSCalc::Tree> baseline;
    if (mode != CSSCalc::ParseSimplification::Eager || forceSimplifiedInput) {
        // Named, because `WTF::move` static_asserts on an lvalue reference and a temporary's member
        // is not one.
        auto baselineParse = parseCalcExpression(source, CSSCalc::ParseSimplification::Eager);
        baseline = WTF::move(baselineParse.tree);
    }

    auto parsed = parseCalcExpression(source, mode);
    if (!parsed.tree) {
        // Reported even on the failing path: "the eager parse succeeded and the unsimplified one
        // did not" is invisible if this returns the zeroed struct.
        result.baselineParsed = baseline ? 1 : 0;
        return result;
    }

    // Comparison (a) is computed here and not from `cppTree`, and the difference is not cosmetic.
    // `ParseSimplification::Terminal` calls `copyAndSimplify(result, simplificationOptions)` with
    // the parse's own options, whose `category` is whichever category the parse succeeded at, while
    // `compareSimplificationOfTree` simplifies under the spec's options, whose category a caller
    // does not pin. On an expression that parses at another category -- `min(1em, 1rem, 3%, 4%)`
    // parses at LengthPercentage -- reading (a) off `cppTree` would compare two trees simplified at
    // different categories and report a divergence that is the caller's own.
    //
    // `Simplifier::Cpp` explicitly: no Swift runs on either side of (a).
    if (baseline) {
        auto parseOptions = CSSCalc::SimplificationOptions {
            .category = parsed.category,
            .range = parsed.range,
            .conversionData = std::nullopt,
            .symbolTable = { },
            // `false` is what the parse passes. The perturbation flips exactly this, and only on
            // the terminal side, which is what gives comparison (a) a negative control.
            .allowZeroValueLengthRemovalFromSum = s_eagerTerminalPerturb.load(std::memory_order_relaxed),
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

// The same comparison over a tree built directly rather than parsed; `constructSimplificationShape`
// says which shapes and why no parse reaches them.
//
// Shape 2 is `Deg2Rad{CanonicalDimension(1deg)}`, and `simplify(Deg2Rad&)` folds a
// `CanonicalDimension` child unconditionally, so this entry reports `cppChangedInput = 1` for it
// even at the parse baseline. A tree handed back at its own parse fixed point does not change, and
// that premise does not hold for a constructed tree, which is why this entry is separate.
WEBCORE_EXPORT CSSCalcSimplificationComparison webCoreCSSCalcCompareSimplificationConstructed(unsigned shape, const CSSCalcSimplificationOptionsSpec* spec, char* cppOut, size_t cppCapacity, char* swiftOut, size_t swiftCapacity)
{
    s_simplifyCompareCalls.fetch_add(1, std::memory_order_relaxed);

    CSSCalcSimplificationComparison result { };
    result.declineKind = 0xFF;

    auto tree = constructSimplificationShape(shape);
    if (!tree)
        return result;

    // `std::nullopt`: a constructed tree has no parse, so it has no baseline counterpart and the
    // six baseline fields stay zero.
    return compareSimplificationOfTree(WTF::move(*tree), std::nullopt, spec, spec->category, cppOut, cppCapacity, swiftOut, swiftCapacity);
}

// The compile-time default, so that a build which ignored the flag cannot pass as one that
// honoured it. Reported separately from the entries above, which name their simplifier.
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

// The Swift side's own decline counter, which the entry above is not: that one reports
// `s_simplifyComparisonDeclines`, incremented only inside the two comparison entries, so a caller
// driving the Swift path through `webCoreCSSCalcSimplificationBench` would read a counter that
// cannot move.
WEBCORE_EXPORT unsigned webCoreCSSCalcSimplificationSwiftDeclineCount(void)
{
    return CSSCalc::webCoreCSSCalcSimplificationDeclineCount();
}

// A forwarder, and it has to be one: at global scope a declaration here would not name
// `CSSCalc::webCoreCSSCalcSimplificationPrimitiveBench` but declare a C-linkage function of the
// same name, which would not link.
WEBCORE_EXPORT uint64_t webCoreCSSCalcSimplificationPrimitiveBench(uint32_t which, uint32_t iterations)
{
    return CSSCalc::webCoreCSSCalcSimplificationPrimitiveBench(which, iterations);
}

WEBCORE_EXPORT uint64_t webCoreCSSCalcSimplificationHarnessCallCount(void)
{
    return s_simplifyCompareCalls.load(std::memory_order_relaxed);
}

// From the variant, never from an enumerator, which can go stale as kinds are added.
// `VariantSizeV` is also the right-hand side of the assert that pins `CSSCalcSwiftAlternative` in
// CSSCalcTree+Serialization.cpp.
WEBCORE_EXPORT uint32_t webCoreCSSCalcChildAlternativeCount(void)
{
    return static_cast<uint32_t>(WTF::VariantSizeV<CSSCalc::Node>);
}

// The category list this file actually iterates, not a recount of the enum.
//
// Not fully drift-proof: `CSS::Category` has no count of its own, so a category appended after
// `AnglePercentage` would be missed by both the assert below and by `calcCategories`. The assert
// does catch one added in the middle, or one removed. Closing the gap properly needs a count in
// CSSPrimitiveNumericCategory.h, a header this file does not own.
WEBCORE_EXPORT uint32_t webCoreCSSCalcCategoryCount(void)
{
    static_assert(calcCategories.size() == static_cast<size_t>(WebCore::CSS::Category::AnglePercentage) + 1);
    return static_cast<uint32_t>(calcCategories.size());
}

WEBCORE_EXPORT uint32_t webCoreCSSCalcConstructedShapeCount(void)
{
    return simplificationConstructedShapeCount;
}

// See the declaration for why this exists rather than a caller simply setting the flag and
// trusting it. It answers constructively: it parses one expression both ways and requires the
// unsimplified tree to be strictly larger.
//
// `calc(1px + 2px)` is the witness. `calc(1px)` will not do, because neither `parseCalcProduct` nor
// `parseCalcSum` wraps a single term (CSSCalcTree+Parser.cpp:1511-1512 and :1445-1446), so it is a
// bare `CanonicalDimension` in every mode. The exact counts are asserted rather than only their
// order, so that a simplification change which stops folding fails here loudly.
WEBCORE_EXPORT bool webCoreCSSCalcSimplificationUnsimplifiedParseAvailable(void)
{
    auto eager = parseCalcExpression("calc(1px + 2px)"_str, CSSCalc::ParseSimplification::Eager);
    auto none = parseCalcExpression("calc(1px + 2px)"_str, CSSCalc::ParseSimplification::None);
    if (!eager.tree || !none.tree)
        return false;
    return nodeCountOfSubtree(eager.tree->root) == 1 && nodeCountOfSubtree(none.tree->root) == 3;
}

// The negative control for comparison (a): it flips `allowZeroValueLengthRemovalFromSum` on the
// terminal side only. That flag is a live axis, so with it set the terminal pass really does
// compute a different tree from the eager parse, and a check that cannot see that cannot see
// anything.
//
// A plain relaxed atomic: set it, run the sweep, clear it. Defaults to false, so a caller that
// never calls it gets the production comparison.
WEBCORE_EXPORT void webCoreCSSCalcSimplificationSetEagerTerminalPerturb(bool perturb)
{
    s_eagerTerminalPerturb.store(perturb, std::memory_order_relaxed);
}

// Which of `bitwiseEqualTree`'s four components made comparison (a) fail. A bare verdict carries
// no attribution, since a failing case can serialize identically on both paths with the same node
// count and the same root alternative.
//
//   bit 0  Tree::stage
//   bit 1  Tree::requiresConversionData
//   bit 2  Tree::type, the whole-tree type, recomputed by the terminal pass
//   bit 3  the subtree, per node, bitwise: a stored per-node `Type`, a signed zero, a
//          `Percentage::hint`, or a leaf double
//
// Returns 0 when the two paths agree and `0xFFFF` when the text did not parse on both.
WEBCORE_EXPORT uint32_t webCoreCSSCalcSimplificationEagerTerminalDelta(const char* text, size_t length)
{
    String source { unsafeMakeSpan(byteCast<Latin1Character>(text), length) };
    auto eager = parseCalcExpression(source, CSSCalc::ParseSimplification::Eager);
    auto raw = parseCalcExpression(source, CSSCalc::ParseSimplification::None);
    if (!eager.tree || !raw.tree)
        return 0xFFFF;

    // Exactly the options `parseCalcExpression` parsed with, so this is the terminal path as
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

// The raw bits of each path's result root, for a case the bitwise oracle rejects while both paths
// serialize identically: serialization cannot show a NaN's sign or payload. Two out pointers
// rather than a two-element array, because an indexed write trips -Wunsafe-buffer-usage, which is
// on with -Werror here, and a `std::span` would not survive a `dlsym`. Returns 1 when both roots
// were numeric leaves.
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

// The Style to CSS conversion round trip, reported in enough detail to be compared across two
// builds. `Style::Calculation::toCSS`'s per-operation `CSSCalc::simplify(Op&, ...)` call is the
// last caller of those overloads outside `copyAndSimplify`, and the two sides of replacing it with
// one whole-tree pass cannot coexist in one binary, so the comparison has to be one entry run in
// two builds whose report is stable enough to diff.
//
// `digest` covers what the serialization does not: the stored per-node `Type`, which can differ in
// `percentHint` or in an exponent without changing one character of the serialization.
//
// `conversionDataKind` is passed rather than fixed because `toStyle` dereferences
// `conversionData->styleBuilderState()` for `CalcMix` and `Random`
// (StyleCalculationTree+Conversion.cpp:208, :228), so kinds 0 to 2 would take EXC_BAD_ACCESS
// rather than declining on a corpus containing either.

// FNV-1a over the bytes of one `Type`, which is seven `int8_t` exponents plus a one-byte
// `PercentHintValue`, all value-initialised, so its object representation has no padding.
static uint64_t mixType(uint64_t hash, const CSSCalc::Type& type)
{
    auto mixByte = [&](uint8_t byte) {
        hash ^= byte;
        hash *= 0x00000100000001B3ull;
    };
    mixByte(static_cast<uint8_t>(type.length));
    mixByte(static_cast<uint8_t>(type.angle));
    mixByte(static_cast<uint8_t>(type.time));
    mixByte(static_cast<uint8_t>(type.frequency));
    mixByte(static_cast<uint8_t>(type.resolution));
    mixByte(static_cast<uint8_t>(type.flex));
    mixByte(static_cast<uint8_t>(type.percent));
    mixByte(type.percentHint ? static_cast<uint8_t>(*type.percentHint) : 0);
    return hash;
}

static uint64_t digestOfSubtree(const CSSCalc::Child& root)
{
    uint64_t hash = 0xCBF29CE484222325ull;
    auto mixWord = [&](uint64_t word) {
        for (unsigned i = 0; i < 8; ++i) {
            hash ^= static_cast<uint8_t>(word >> (i * 8));
            hash *= 0x00000100000001B3ull;
        }
    };
    forEachNodeOfSubtree(root, [&](const CSSCalc::Child& node) {
        mixWord(node.value.index());
        hash = mixType(hash, CSSCalc::getType(node));
        WTF::switchOn(node.value,
            [&]<CSSCalc::Numeric T>(const T& leaf) { mixWord(std::bit_cast<uint64_t>(leaf.value)); },
            [&](const auto&) { });
        if (auto* dimension = get_if<CSSCalc::CanonicalDimension>(&node.value))
            mixWord(static_cast<uint64_t>(dimension->dimension));
        if (auto* dimension = get_if<CSSCalc::NonCanonicalDimension>(&node.value))
            mixWord(static_cast<uint64_t>(dimension->unit));
    });
    return hash;
}

WEBCORE_EXPORT CSSCalcStyleRoundTripResult webCoreCSSCalcStyleRoundTrip(const char* text, size_t length, uint32_t category, uint32_t conversionDataKind, char* out, size_t capacity)
{
    CSSCalcStyleRoundTripResult result { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };

    String source { unsafeMakeSpan(byteCast<Latin1Character>(text), length) };
    auto parsed = parseCalcExpressionAtCategory(source, static_cast<WebCore::CSS::Category>(category), CSSCalc::ParseSimplification::Eager);
    if (!parsed.tree)
        return result;
    result.parsed = 1;

    // Scoped, because `ToStyleOptions::conversionData` holds a `CheckedPtr` to the builder state
    // and `CanMakeCheckedPtr`'s destructor RELEASE_ASSERTs the count is zero when the fixture is
    // reset.
    CSSCalc::Tree roundTripped = [&] {
        if (simplificationConversionDataCarriesBuilderState(conversionDataKind))
            resetSimplificationBuilderStates();
        auto fontSize = simplificationConversionDataFontSize(conversionDataKind);
        auto conversionData = [&]() -> std::optional<CSSToLengthConversionData> {
            if (!conversionDataKind)
                return std::nullopt;
            if (simplificationConversionDataCarriesBuilderState(conversionDataKind))
                return CSSToLengthConversionData { simplificationStyleAtFontSize(fontSize), simplificationBuilderStateAtFontSize(fontSize) };
            return CSSToLengthConversionData { simplificationStyleAtFontSize(fontSize), nullptr, nullptr, nullptr, nullptr };
        }();

        auto styleTree = WebCore::Style::Calculation::toStyle(*parsed.tree, WebCore::Style::Calculation::ToStyleOptions {
            .category = static_cast<WebCore::CSS::Category>(category),
            .range = WebCore::CSS::All,
            .conversionData = WTF::move(conversionData),
            .symbolTable = { },
        });
        result.styleRootKind = static_cast<uint32_t>(styleTree.root.value.index());
        // `computeDepth`, not a node count: a corpus whose Style trees are all leaves would
        // exercise the conversion's leaf overloads only and read as green while covering nothing.
        result.styleDepth = static_cast<uint32_t>(WebCore::Style::Calculation::computeDepth(styleTree));

        return WebCore::Style::Calculation::toCSS(styleTree, WebCore::Style::Calculation::ToCSSOptions {
            .category = static_cast<WebCore::CSS::Category>(category),
            .range = WebCore::CSS::All,
        });
    }();

    result.nodeCount = nodeCountOfSubtree(roundTripped.root);
    result.rootKind = static_cast<uint32_t>(roundTripped.root.value.index());
    result.stage = static_cast<uint32_t>(roundTripped.stage);
    result.kindMask = alternativeMaskOfSubtree(roundTripped.root);
    result.digest = digestOfSubtree(roundTripped.root);
    result.treeTypeBits = mixType(0xCBF29CE484222325ull, roundTripped.type);

    auto serializationOptions = CSSCalc::SerializationOptions {
        .range = WebCore::CSS::All,
        .serializationContext = WebCore::CSS::defaultSerializationContext(),
    };
    // Through `Serializer::Cpp` explicitly: this entry is about the conversion, and taking the
    // build's default serializer would let a serialization change move the table.
    result.textLength = static_cast<uint32_t>(copyOutSerialization(
        CSSCalc::serializationForCSS(roundTripped, serializationOptions, CSSCalc::Serializer::Cpp), out, capacity));
    return result;
}

// Does the conversion-data fixture support font-metric-relative units? A style whose
// `FontCascade::m_fonts` is null takes EXC_BAD_ACCESS inside `Style::resolveEx` for every
// font-metric unit (`ex`, `cap`, `ch`, `ic`, `lh` and the `r*` forms).
//
// Returning `fonts() != nullptr` would not be enough: a fixture whose two styles realized the same
// font would make the whole conversion-data axis vacuous, since a `canonicalize` that returned a
// constant would still pass. So this returns true only if both styles have a realized font and
// their x-heights, cap-heights and line spacings all differ.
WEBCORE_EXPORT bool webCoreCSSCalcSimplificationFontMetricsAvailable(void)
{
    auto& cascade16 = simplificationStyleAtFontSize(16.0f).fontCascade();
    auto& cascade32 = simplificationStyleAtFontSize(32.0f).fontCascade();
    if (!cascade16.fonts() || !cascade32.fonts())
        return false;

    auto& metrics16 = cascade16.metricsOfPrimaryFont();
    auto& metrics32 = cascade32.metricsOfPrimaryFont();
    // `Markable<float>`, not `std::optional<float>`, taken by `auto` so that the accessor's own
    // return type decides rather than a conversion that may not exist.
    auto differs = [](auto a, auto b) {
        return a && b && *a != *b;
    };
    return differs(metrics16.xHeight(), metrics32.xHeight())
        && differs(metrics16.capHeight(), metrics32.capHeight())
        && metrics16.lineSpacing() != metrics32.lineSpacing();
}

// Does the conversion-data fixture support a live `Style::BuilderState`? A pre-flight check: if
// any of the five builder-state-requiring `simplify` overloads dereferences something this fixture
// lacks, the process takes EXC_BAD_ACCESS, so every dereference those five perform is exercised
// here first.
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

    // Both `random()` sharing paths. The values are a per-process random draw, so only that both
    // return and that the cache is stable is checked.
    CSSCalc::RandomCachingKey key { CSSCalc::RandomCachingKey::Key { .name = std::nullopt, .propertyScoped = std::nullopt } };
    auto documentScoped = state.lookupCSSRandomBaseValue(key, std::nullopt);
    auto elementScoped = state.lookupCSSRandomBaseValue(key, CSS::Keyword::ElementScoped { });
    ok = ok && state.lookupCSSRandomBaseValue(key, std::nullopt) == documentScoped;
    ok = ok && state.lookupCSSRandomBaseValue(key, CSS::Keyword::ElementScoped { }) == elementScoped;

    // The anchor entry point, with no property in flight. Must be `nullopt`, and must not crash
    // getting there.
    ok = ok && !WebCore::Style::AnchorPositionEvaluator::evaluateSize(state, std::nullopt, std::nullopt);

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

// Reported rather than hardcoded, so that a fixture which became one-sibling -- making
// `sibling-count()` and `sibling-index()` indistinguishable -- shows up in the numbers.
WEBCORE_EXPORT unsigned webCoreCSSCalcSimplificationFixtureSiblingCount(void)
{
    return simplificationBuilderStateAtFontSize(16.0f).siblingCount();
}

WEBCORE_EXPORT unsigned webCoreCSSCalcSimplificationFixtureSiblingIndex(void)
{
    return simplificationBuilderStateAtFontSize(16.0f).siblingIndex();
}

// One unit, one value, four paths. See the struct above for why there are four.
WEBCORE_EXPORT CSSCalcCanonicalizationComparison webCoreCSSCalcCompareCanonicalization(double value, uint32_t unitRaw, const CSSCalcSimplificationOptionsSpec* spec)
{
    // Counted on the same tally as the tree-level entries.
    s_simplifyCompareCalls.fetch_add(1, std::memory_order_relaxed);

    CSSCalcCanonicalizationComparison result { };
    // Reported rather than asserted: callers may pass values outside the enum on purpose, and a
    // `static_cast` of an out-of-range value would be UB.
    if (unitRaw > static_cast<uint32_t>(CSSUnitType::QuirkyEm))
        return result;
    result.built = 1;

    auto unit = static_cast<CSSUnitType>(unitRaw);
    auto options = makeSimplificationOptions(spec);

    // The reference call, reading its conversion data off `options` rather than rebuilding it, so
    // that all three paths use the same.
    if (auto canonical = CSSCalc::canonicalize(CSSCalc::NonCanonicalDimension { .value = value, .unit = unit }, options.conversionData)) {
        result.referenceResolved = 1;
        result.referenceValue = canonical->value;
        result.referenceUnitType = static_cast<uint32_t>(CSSCalc::toCSSUnit(canonical->dimension));
    }

    // Both simplifiers run over the same input `Tree` object.
    auto root = CSSCalc::makeChild(CSSCalc::NonCanonicalDimension { .value = value, .unit = unit });
    auto type = CSSCalc::getType(root);
    auto input = CSSCalc::Tree { .root = WTF::move(root), .type = type, .stage = spec->stage ? CSSCalc::Stage::Computed : CSSCalc::Stage::Specified };

    auto declinesBefore = CSSCalc::webCoreCSSCalcSimplificationDeclineCount();
    auto cppTree = CSSCalc::copyAndSimplify(input, options, CSSCalc::Simplifier::Cpp);
    auto swiftTree = CSSCalc::copyAndSimplify(input, options, CSSCalc::Simplifier::Swift);
    result.swiftDeclined = CSSCalc::webCoreCSSCalcSimplificationDeclineCount() != declinesBefore ? 1 : 0;
    // Each call runs the Swift side exactly once, since there are no idempotence checks here, so
    // the counter advances by at most one per case.
    if (result.swiftDeclined)
        s_simplifyComparisonDeclines.fetch_add(1, std::memory_order_relaxed);

    // The result leaf, read off the variant tag rather than guessed from the unit. The catch-all
    // is unreachable for a `NonCanonicalDimension` root, since neither simplifier turns a numeric
    // leaf into an operation, and it leaves the value at 0 with the alternative still reported.
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

// How many `CSSUnitType` enumerators there are, so that a caller's sweep width comes from WebCore
// rather than a hardcoded count.
//
// Spelled as the last enumerator plus one, which `CSSUnitType` has no `variant_size_v` equivalent
// of. That catches an enumerator inserted in the middle or removed, but would miss one appended
// after `QuirkyEm`; closing that properly needs a count in CSSUnitType.h.
WEBCORE_EXPORT uint32_t webCoreCSSCalcUnitTypeCount(void)
{
    return static_cast<uint32_t>(CSSUnitType::QuirkyEm) + 1;
}

} // extern "C"

#endif // ENABLE(CSS_TOKENIZER_SWIFT_BRIDGE)
