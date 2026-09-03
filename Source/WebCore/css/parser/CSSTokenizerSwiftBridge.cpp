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

// Bridge for the Swift CSS tokenizer island (CSSTokenizerSwift.swift), see
// ~/Documents/webkit-swift-adoption-notes.md §11.
//
// Exposes three things to TestWebKitAPI and the standalone harnesses, `extern "C"`
// so no header needs exporting:
//
//   1. comparison entries that build the whole CSSParserToken stream both ways in
//      one process and compare the tokens themselves — at either character width,
//      and with an observer wrapper attached. This is the gate that matters: the
//      standalone probe only proves two of my own ports agree with each other,
//      which a symmetric misreading of the spec would satisfy;
//   2. benchmark entries that time a whole CSSTokenizer construction on one
//      scanner or the other, at either width;
//   3. diagnostics: the decline counter, the forced-decline switch for the
//      failure-reporting path, and the compile-time scanner choice.
//
// Every entry here is WEBCORE_EXPORT and this file is in WebCore's own sources with
// no `#if` guard, so it ships inside WebCore.framework: its size is interop cost,
// not test overhead. Two families of entry were deleted for that reason, both
// strictly dominated. A `webCoreCSSTokenizerSwiftValidate` walked the island's POD
// output beside a real CSSParserTokenRange, but skipped escaped values entirely and
// hand-reimplemented CSSParserToken::convertToDimensionWithUnit's merge rule, where
// webCoreCSSTokenizerComparePaths below compares real CSSParserTokens including
// their numeric fields and block types. A `webCoreCSSTokenizerBenchSwift` /
// `...BenchReal` pair timed the island's scan against a control its own comment
// admitted was "not a like-for-like control", where
// webCoreCSSTokenizerBenchIntegrated does the same work on both sides.

#include "config.h"

// Off unless ENABLE_CSS_TOKENIZER_SWIFT_BRIDGE=1. Everything below is WEBCORE_EXPORT and
// exists only to validate the island against the C++ scanner and to measure it, so it has no
// business in a shipping WebCore.framework -- which is where it was going, since this file is
// in WebCore's own sources build phase with no guard at all. Switch it on with
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
// DEFINED here, so a translation unit that calls either without this include fails
// -Werror,-Wundefined-inline rather than at link time. Needed by entry 10.
#include "FontCascadeInlines.h"
// For the calc simplification differential's conversion-data axis: a `Style::ComputedStyle` at a
// chosen font size is the only way to prove `canonicalize` is READING the conversion data rather
// than answering a constant.
#include "StyleComputedStyle.h"
#include "StyleComputedStyle+GettersInlines.h"
#include "StyleComputedStyle+SettersInlines.h"
// The island entry points this file calls, and every other island's boundary types along with
// them -- WebCoreSwift-Generated.h is module-scoped, so a translation unit that includes it must
// declare all of them. WebCoreSwiftBoundaryTypes.h says why, and is the one file an added island
// edits.
#include "WebCoreSwiftBoundaryTypes.h"
#include <array>
#include <atomic>
#include <bit>
#include <cmath>
#include <limits>
#include <optional>
#include <wtf/NeverDestroyed.h>
#include <wtf/StdLibExtras.h>
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

// MARK: - Helpers for the calc serialization differential below.
//
// In WebCore's own anonymous namespace rather than beside the entries they serve, because those
// entries live inside `extern "C"` and a C-linkage function may not return a user-defined type:
// -Werror,-Wreturn-type-c-linkage rejects `const CSSParserContext&` and `ParsedCalc` outright.

// The categories to try, in order. A calc expression is only parseable in a context that admits its
// type -- `calc(1 + 2)` needs Number, `calc(1px + 1em)` needs Length -- and the corpus mixes all of
// them, so trying a list is what keeps a case from being silently skipped for being handed the
// wrong context. Integer is first because it is the most restrictive.
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

// The parser context, built once. A `CSSParserContext` carries a URL and a settings snapshot; the
// colour differential next door measured construction-per-call dominating its sweep, and this one
// makes millions of calls too. A function-local static rather than a global because WebCore links
// with -no_inits.
const CSSParserContext& calcParserContext()
{
    static NeverDestroyed<CSSParserContext> context = [] {
        CSSParserContext built { HTMLStandardMode };
        // Without this, `sibling-count()` and `sibling-index()` are rejected at
        // CSSCalcTree+Parser.cpp:1345, and the `SiblingCount` / `SiblingIndex` node kinds are
        // unreachable through this entry -- so the differential's coverage guard would fail rather
        // than quietly testing six kinds while claiming eight.
        built.cssTreeCountingFunctionsEnabled = true;
        // Without these two, `random()` and `calc-mix()` are rejected outright at
        // CSSCalcTree+Parser.cpp:663 and :933, so the `Random` and `CalcMix` alternatives are
        // unreachable and the `Operation` node kind -- which after S2 means exactly "one of those
        // two" -- is never produced. The differential's coverage guard then reports a kind it never
        // tested, which is how this was found: S2's decline corpus is *only* those two, so with them
        // off the whole decline corpus parsed nothing.
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
// relative-colour component symbols, copied from the table
// CSSPropertyParserConsumer+Color.cpp:285 builds, so this is a context the parser really does see
// rather than one invented for the test. `symbolTable` is left empty on the simplification side, so
// the symbol stays unresolved and survives into the tree as a `Symbol` leaf, which is exactly the
// node the island has to serialize.
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
// `conversionData` is deliberately `std::nullopt`, which is what the production parse at
// CSSUnevaluatedCalc.cpp:167 passes: with no conversion data, simplification cannot fold length
// units into their canonical form, so operator nodes survive into the tree instead of collapsing to
// a single leaf. That is what gives the island's walk something to descend through -- with
// conversion data most of this corpus would simplify to one `Number` before serialization ever ran,
// and the child accessors would go untested while every case still passed.
ParsedCalc parseCalcExpression(const String& source)
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
            // `anchor-size()` are rejected outright at CSSCalcTree+Parser.cpp:1043 and :1136 --
            // so the `Anchor` and `AnchorSize` alternatives are unreachable through this entry and
            // the differential's coverage guard reports a node kind it never tested. They are the
            // two alternatives whose reported child count is not the truth (`tuple_size` 0,
            // webkit.org/b/280798), which makes them the last two that should go untested.
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

        auto tree = CSSCalc::parseAndSimplify(range, parserState, parserOptions, simplificationOptions);
        // A trailing token means the expression was only partly consumed, which is not a parse.
        if (tree && range.atEnd())
            return { WTF::move(tree), category, WebCore::CSS::All };
    }
    return { };
}

// Copies a serialization out to the harness. Truncates rather than overflowing, and reports the
// true length so a truncated compare cannot read as agreement.
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

// A tree built DIRECTLY rather than parsed, because that is the only way to reach the two root shapes
// the island declines on the C++'s account: a bare `Negate` or `Invert` at the root of a `Tree`.
//
// `serializeMathFunction` has explicit `serializeMathFunctionArguments` overloads for `Sum` and
// `Product` that route back into the calculation-tree serializer, and NONE for `Negate` or `Invert`
// (CSSCalcTree+Serialization.cpp:403-:411). So a `Negate` root takes the generic argument template at
// :545, which walks the node's single child and emits it with no prefix at all -- step 4's `-1 * `
// is gone, and the serialization means a different number from the tree. Shapes 2 and 3 are the
// control that isolates it: the SAME `Negate` node one level down inside a `Sum` does emit `-1 * `,
// so the difference is the root position and not the node.
//
// The leaf is parsed rather than constructed so that its `Type` is the one the real parser would
// produce; only the operator node above it is built by hand.
std::optional<CSSCalc::Tree> constructRootShape(unsigned shape)
{
    auto parsed = parseCalcExpression("calc(1px)"_str);
    if (!parsed.tree)
        return std::nullopt;

    // `calc(1px)` does NOT survive as a `Sum` wrapping the leaf: `parseAndSimplify` folds the
    // one-child wrapper away and the root is the leaf itself. This unwrap is therefore inert today
    // -- measured, not assumed, by `webCoreCSSCalcCompareSerializationStaged`'s C1 phase landing all
    // 660 of its cases on a numeric root with no unwrap -- and it is kept only so that a future
    // simplification change which stops folding cannot silently turn this into a `Sum` shape.
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

// MARK: - Helpers for the calc SIMPLIFICATION differential below.
//
// Same reason as the block above for living here rather than beside the entries: these return
// user-defined types, and a C-linkage function may not.
//
// SIMPLIFICATION IS `Tree -> Tree`, WHICH IS WHY THIS BLOCK EXISTS AT ALL. The serialization
// differential compares two strings and needs no comparison machinery of its own. Here the oracle
// has to compare two TREES, and the three things a string comparison never had to answer -- what
// counts as equal, what counts as a NaN, and which alternatives the tree contains -- are the whole
// of what follows.

// The deep, BITWISE comparison that is the differential's verdict.
//
// `Tree::operator==` is defaulted and therefore uses `double ==`, which is wrong in BOTH directions
// for this job and simplifycheck.cpp reports both: too strict on NaN (`NaN != NaN`, so two arms that
// both correctly produce NaN compare unequal) and too weak on signed zero (`-0.0 == 0.0`, so a fold
// that normalised the sign of zero -- which `abs`, `mod`, `round(to-zero)` and `sign` all can --
// would pass). Serialization cannot see a signed zero either: `calc(-0)` serializes as `calc(0)`.
// So this is the only one of the three comparisons that can see it, and it is the verdict.
static bool bitwiseEqualChild(const CSSCalc::Child&, const CSSCalc::Child&);

// Every double compared by bit pattern rather than by value. `-0.0` and `0.0` differ; two NaNs with
// the same payload agree. `bit_cast` rather than `memcmp`, so the comparison is on a value and not
// on an object representation with padding in it.
static bool sameBits(double a, double b)
{
    return std::bit_cast<uint64_t>(a) == std::bit_cast<uint64_t>(b);
}

// One overload per slot SHAPE, exactly as `rebuildSlot` in CSSCalcTree+Simplification.cpp has --
// five shapes, so five overloads, and an operation that introduced a sixth would fail to compile
// here rather than be compared shallowly.
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
    // `operator==` and not a bitwise walk, and the reason is that `Sharing` is never COMPUTED: both
    // arms copy it through unchanged (`copyAndSimplify(const Random::Sharing&)`), so the `double`
    // inside `SharingFixed` is the same object's value on both sides and cannot have been rounded
    // differently. A bitwise comparison here would test the copy, which `pushCopyOf` already routes
    // through the one `CSSCalc::copy`.
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
                    // below would compare NOTHING and report every pair of anchors equal. Written
                    // out instead: this is the same lie `rebuildFrom` stops at, stopped again.
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
                // `operator==` IS the bitwise comparison.
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
// Its own walker rather than `forAllChildNodes`, for the reason that keeps coming back: `Anchor`
// and `AnchorSize` declare `tuple_size` 0, so the generic traversal yields no children for them and
// a mask built from it would under-report exactly the two alternatives whose reported child count
// is already not the truth.
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
// `CSSCalcSwiftSimplificationResult::kindMask` for why only this keying can express the
// differential's decline expectation.
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

// Whether any numeric leaf in the subtree is a NaN.
//
// FROM THE TREE AND NOT FROM THE CASE TEXT, which is the point: `calc(0 / 0)` produces a NaN the
// text does not mention, and the differential's guard 9 exempts exactly the NaN set from the
// disagreement between the bitwise and defaulted comparisons. An exemption computed from the text
// would exempt the wrong set.
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
// FUNCTION-LOCAL STATICS BECAUSE `CSSToLengthConversionData` HOLDS A REFERENCE to the style, not a
// copy, so a style built per call and returned by value would leave the options pointing at a dead
// object. WebCore links with -no_inits, which is why these are function-local rather than globals.
//
// `styleBuilderState()` is null, which is what makes `SiblingCount`, `SiblingIndex`, `Random`,
// `Anchor` and `AnchorSize` return `nullopt` from their `simplify` on both arms. All five are
// declined by the first slice, so nothing is lost today; simplifycheck.cpp's guard 12 names this as
// the first thing that must change when the slice claiming them lands.
//
// `setFontDescription` AND NOT `setFontDescriptionWithoutUpdate`, AND THIS IS LOAD-BEARING.
// `WithoutUpdate` leaves `FontCascade::m_fonts` NULL (StyleComputedStyleBase.cpp:233 only rebuilds
// the cascade from the description); the non-`WithoutUpdate` form calls `FontCascade::update(
// fontSelector)` at :229, which goes to `FontCache::forCurrentThread()->updateFontCascade` and
// installs a real `FontCascadeFonts`. Without it, `Style::resolveEx` -> `metricsOfPrimaryFont()` ->
// `primaryFont()` dereferences a null `m_fonts` and takes EXC_BAD_ACCESS at 0x68 on the FIRST
// font-metric-relative unit any caller feeds in -- measured, `calc(1ex)` under the @16px fixture.
//
// That `update(nullptr)` works here at all -- no Document, no Page, no FontSelector, inside a
// framework loaded by a bare command-line tool -- is NOT an assumption. It is measured by
// `~/src/webkit-swift-ports/cssprobe/validate/fontrealizeprobe.cpp` against this framework:
// `fonts()` goes 0x0 -> non-null, and the metrics the units resolve from differ between the two
// sizes (xHeight 7.1797 vs 14.3594, capHeight 10.5859 vs 21.1719, lineSpacing 18 vs 37), which is
// what makes the two-present-values design of this fixture actually prove something.
const Style::ComputedStyle& simplificationStyleAtFontSize(float fontSize)
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
    // TWO PRESENT VALUES AND NOT ONE, deliberately: a present/absent boolean would be satisfied by
    // an island whose `canonicalize` returned a constant, and only a second style with a different
    // font size proves the conversion data is being read.
    return fontSize > 16 ? style32.get() : style16.get();
}

// The nine symbol tables the sweep uses, and the reason the axis exists.
//
// Kinds 3..8 are THE ADVERSARIAL NUMERIC INJECTOR, and they are the only route to those values:
// nothing in the CSS number grammar spells NaN, an infinity, a negative zero, a subnormal or
// 2^31-1 as a literal, so `mod(r, g)` with `r` bound to NaN is the only way to reach
// `executeMathOperation<Mod>(NaN, NaN)` at all. The four ids are the relative-colour component
// symbols, which are the same four the PARSE-side `calcAllowedSymbols` binds -- the parse side is
// always `CSSUnitType::Number` and always populated, or nothing in the corpus parses to a `Symbol`
// in the first place; this table is the SIMPLIFICATION side, and is the swept axis.
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
        // A DIMENSION rather than a number, which is what gives the recursive `copyAndSimplify`
        // inside `simplify(Symbol&)` real work: the replacement is a `CanonicalDimension` and the
        // percentage-typed operations become reachable.
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
        // The value NEITHER of the other two comparisons can see: `-0.0 == 0.0` is true, and
        // `calc(-0)` serializes as `calc(0)`. Only the bitwise oracle reports a fold that
        // normalised it.
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

// The four trees the differential builds directly, because no parse produces them.
//
// THE PRECEDENT IS `constructRootShape` ABOVE and the reason is the same, but the kinds are
// different: there it was a `Negate` or `Invert` at the ROOT of a tree; here it is `Deg2Rad` and
// `Invert` at all, as kinds the first slice claims and simplifies. Measured, not assumed: every
// parse-reachable `Deg2Rad` sits inside a `Product` (`sin(r * 1deg)`) and every parse-reachable
// `Invert` does too (`calc(1 / r)` is `Product{1, Invert{Symbol}}`), and the first slice declines
// `Product` -- so without these four, `Deg2Rad` and `Invert` are reached by the corpus and never
// once simplified, which is a kind counted as covered whose handling has never executed.
//
// The symbol is `CSSValueR` so that the swept symbol table resolves it; a symbol the table does not
// bind would leave shapes 0, 1 and 3 inert across the whole sweep.
constexpr unsigned simplificationConstructedShapeCount = 4;

std::optional<CSSCalc::Tree> constructSimplificationShape(unsigned shape)
{
    auto typeOf = [](const auto& op, const CSSCalc::Child& fallbackTypeSource) {
        // The operation's own computed type where it has one, and the child's where `toType`
        // declines. A tree built with a type its operation would not have produced is a tree the
        // arms could disagree about for a reason that is this function's fault, not the island's.
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
        // `Deg2Rad{CanonicalDimension(1deg)}`, the one shape here that FOLDS: `simplify(Deg2Rad&)`
        // turns a `CanonicalDimension` child into `Number { deg2rad(value) }` unconditionally
        // (CSSCalcTree+Simplification.cpp:986-990). It is the only case in the whole corpus in which
        // the island's `Deg2Rad` handling actually produces a node, which is why it is worth a shape
        // of its own -- and it is also why this shape changes its input at the PARSE BASELINE, with
        // no swept option involved. See the note on `webCoreCSSCalcCompareSimplificationConstructed`.
        auto child = CSSCalc::makeChild(CSSCalc::CanonicalDimension { .value = 1, .dimension = CSSCalc::CanonicalDimension::Dimension::Angle });
        auto op = CSSCalc::Deg2Rad { .angle = CSSCalc::copy(child) };
        auto type = typeOf(op, child);
        return CSSCalc::Tree { .root = CSSCalc::makeChild(WTF::move(op), type), .type = type, .stage = CSSCalc::Stage::Specified };
    }
    case 3: {
        // `Invert{Symbol}`, number-typed. A bare `Invert` is unreachable through a parse because
        // division always builds the `Product` wrapper around it.
        auto child = CSSCalc::makeChild(CSSCalc::Symbol { .id = CSSValueR, .unit = CSSUnitType::Number });
        auto op = CSSCalc::Invert { .a = CSSCalc::copy(child) };
        auto type = typeOf(op, child);
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
    // What diverged, decoded by divergenceReason() in CSSTokenizerSwiftTest.cpp and by
    // the copies in cssprobe's csscheck.cpp and cssfuzz.cpp: 0 = the tokens compare
    // unequal, 1 = block types, 2 = token counts, 3 = an observer token offset,
    // 4 = the observer's end offset, 5 = a numeric field, 6 = the source was not valid
    // UTF-8, 7 = a dimension's unit type, 8 = a dimension's value text, 9 = a
    // dimension's non-unit prefix length. Add a case to all three when adding a code.
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
// process, and compares the tokens themselves rather than the island's POD output.
// This is what has to hold before the Swift path could ever be turned on by
// default, because it is comparing what the rest of the CSS parser will actually
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

    // The island's nonInteger, plusSign and minusSign flags become numericValueType and
    // numericSign, and for NumberToken and PercentageToken nothing above compares them:
    // a wrong flag would pass every test here while breaking <integer> validation and
    // nth-child(An+B) sign handling.
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

    // A DimensionToken's unit. operator== takes its `m_bits.nonUnitPrefixLength == 0` branch
    // off *this* -- the C++ token here -- and only that branch compares unitString();
    // with a prefix it falls through to `originalText() == other.originalText()`, so a
    // wrong m_bits.unit or a wrong prefix length on such a token compared equal. That is not
    // hypothetical: it is the field a proposed change to this island would have
    // corrupted with every test still passing.
    //
    // value() is what catches convertToDimensionWithUnit's merge rule. The number text and
    // the unit text are joined into one view only when mergeIfAdjacent finds them
    // physically adjacent (`std::to_address(a.end()) == std::to_address(b.begin())`) and
    // the number is shorter than 16 characters, so `10px` from the input has value()
    // "10px", while `1\70x` -- the same unit written with an escape, which makes the unit
    // text a pooled String rather than a range of the input -- has value() "px". Which of
    // those happened is a property of where the island put the value, is invisible to the
    // numeric fields, and decides how a custom property reserializes.
    //
    // m_bits.nonUnitPrefixLength has no accessor and does not need one: unitString() is
    // defined as value().substring(m_bits.nonUnitPrefixLength), so with value() and
    // unitString() both equal the prefix length is equal too, being the difference of
    // their lengths. Comparing the two public views pins the private bit-field exactly,
    // which is why the check below adds no friend and no test-only getter.
    //
    // What remains uncompared is not specific to dimensions: StringView equality is
    // textual, so a value whose text matches but whose backing StringImpl chose the other
    // character width still compares equal, here and in operator== for every
    // value-carrying token.
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
// process, and compares the tokens themselves rather than the island's POD output.
// This is what has to hold before the Swift path could ever be turned on by
// default, because it is comparing what the rest of the CSS parser will actually
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
// exercise the island's UInt16 specialization: a String built from Latin-1 bytes is
// always 8-bit. `expectedType` comes back as 8 or 16 so the caller can confirm
// which representation was actually tested rather than assuming.
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

// Whether tryCreate succeeded. There is no fallback: when the island cannot allocate,
// construction fails, and this is how a test observes that rather than inferring it.
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
// bytes, so all three were 8-bit-only and the island's UInt16 specialization -- a separate
// body of generated code, reached by every stylesheet containing a character above U+00FF
// -- had never been timed at all, only checked for correctness.
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
// The island's trie is a transcription of cssPrimitiveValueUnitFromTrie, and these two
// entries are what prove the transcription right against the *in-tree* original rather than
// against an extraction of it. The standalone harness in ~/src/webkit-swift-ports/css-unit-trie
// compares the Swift against a verbatim copy of the C++ over 873,806,013 inputs, which is the
// exhaustive half of the argument; what it cannot show is that the copy is still the function
// WebCore compiles. This can, because both sides here are the ones linked into this framework:
// CSSParserToken::stringToUnitType is the only caller of the C++ trie, and the Swift is the
// island's own.
//
// Both results come back from one call, packed, for two reasons. It halves the cross-library
// call count on a sweep that makes ~870 million of them; and it puts the two evaluations of
// the same buffer next to each other, so there is no way for the harness to compare a
// C++ answer for one input against a Swift answer for another.
//
// The Swift side is reached through the generated header's thunk. Its parameters are packed
// into 64-bit words because a Swift *callee* cannot take a Span -- the `__counted_by` plus
// `noescape` recipe works in the other direction only -- and the alternatives all put an
// `unsafe` marker in a file that has none. Filings register §27. The packing is here rather
// than in the harness so that the harness keeps a pointer-and-length signature.

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

// MARK: - The colour fast-path island's differential (CSSParserFastPathsSwift.swift)
//
// Phase A's input domain is small enough to sweep properly rather than sample, so these entries
// exist to be called tens of millions of times: every 3-, 4- and 6-digit hex string, every
// length from 0 to 70 over an adversarial alphabet, and all 152 named colours in every case
// variation. Both answers come back from one call, for the reason the unit-trie entries above
// give -- it halves the cross-library call count, and it makes it impossible for the harness to
// pair a C++ answer for one input with a Swift answer for another.
//
// The scanner is named explicitly on each side rather than taken from the build's default, so
// the sweep measures the island against the C++ whatever WK_USE_SWIFT_CSS_COLOR_FAST_PATHS was
// set to. `webCoreCSSColorFastPathsAreSwift` reports the default separately, because that is a
// different question and conflating the two is how an ignored build flag reads as a pass.

// Both scanners' answers for one candidate. `found` is 0 or 1; `argb` is meaningful only when
// `found`, and is zeroed otherwise so a harness comparing whole structs cannot pass on garbage.
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

// How many times WebCore was actually asked. The anti-vacuity guard that matters most here: a
// sweep whose calls the optimizer elided, or whose loop bounds were wrong, would otherwise print
// a clean pass over inputs that never reached this framework. The harness asserts its own total
// against this.
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
// constructing one per call dominated a sweep that makes tens of millions of them -- which would
// have made the differential's cost a property of the harness rather than of the scanners, and
// pushed the exhaustive phases out of the time budget. Function-local statics rather than globals
// because WebCore links with -no_inits.
static const CSSParserContext& colorScanContext(bool quirksMode)
{
    static NeverDestroyed<CSSParserContext> quirks { HTMLQuirksMode };
    static NeverDestroyed<CSSParserContext> standard { HTMLStandardMode };
    return quirksMode ? quirks.get() : standard.get();
}

// Runs `kind` both ways over the same characters. `characterSize` picks which of StringImpl's
// two representations the StringView carries: the harness always hands over 16-bit units, and a
// `characterSize` of 1 narrows them, which is the only way to reach the 8-bit template
// instantiation for text that a String built from these bytes would have stored 8-bit anyway.
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

// Makes every island answer read as a decline, so the C++ fall-through runs. Phase A declines
// for no input at all -- hex and named are covered at both widths -- so this is the only way the
// fall-through gets executed, and a path that is never executed is not a path that works.
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

// Reported rather than duplicated in the harness, so a sweep cannot quietly stay inside the
// capacity while claiming to have crossed it.
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

// MARK: - The calc serialization island's differential (CSSCalcSerializationSwift.swift)
//
// `CSSCalc::serializationForCSS` is a pure `(Tree, Range, SerializationContext) -> String`, so this
// needs no document, no style and no rendering: parse a calc expression, serialize the resulting
// tree both ways, compare. Both arms run on the *same* `Tree` object inside one call, which is what
// makes it impossible for the harness to pair a C++ answer for one expression with a Swift answer
// for another -- the failure mode that the unit-trie and colour entries above are shaped to avoid
// for the same reason.
//
// The serializer is named explicitly on each side rather than taken from the build's default, so
// the differential compares the island against the C++ whatever WK_USE_SWIFT_CSS_CALC_SERIALIZATION
// was set to. `webCoreCSSCalcSerializationIsSwift` reports the default separately, because that is
// a different question and conflating the two is how an ignored build flag reads as a pass.

// One expression's worth of comparison, plus everything the harness needs to prove the run was not
// vacuous.
struct CSSCalcSerializationComparison {
    // 1 if the text parsed as a calc value at some category. 0 means the case exercised nothing.
    uint32_t parsed;
    // 1 if the two serializations are byte-identical.
    uint32_t agree;
    // 1 if the island declined this tree, so the "agreement" below is the C++ against itself.
    uint32_t declined;
    // What the island's walk saw: how many nodes it visited and which kinds it stood on. These are
    // the anti-vacuity fields. A walk that looked at the root and stopped reports nodeCount 1 on a
    // tree that has ten nodes, and a kindMask that never gains a bit is a walk that is not
    // descending.
    uint32_t nodeCount;
    uint32_t kindMask;
    uint32_t cppLength;
    uint32_t swiftLength;
    // Which CSS::Category the expression parsed at, so the harness can report the spread rather
    // than assume one.
    uint32_t category;
    // The kind of the tree's ROOT, which the kind mask above cannot answer. The mask says a `Negate`
    // was somewhere in the tree; the question is whether one can be a root, because that is the one
    // position where the C++ drops step 4's `-1 * ` prefix. Accumulated over the whole corpus, this
    // turns "no parse seems to produce one" into a measurement.
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

// How many times WebCore was actually asked to compare. Asserted by the harness against its own
// total: a sweep whose loop bounds were wrong, or whose calls the optimizer elided, would otherwise
// print a clean pass over expressions that never reached this framework.
static std::atomic<uint64_t> s_calcCompareCalls;

// Reported rather than duplicated in the harness, so a run cannot claim it reached every node kind
// while testing against a stale count of them.
WEBCORE_EXPORT uint32_t webCoreCSSCalcNodeKindCount(void)
{
    // The LAST case, so adding a kind without touching this line under-reports the count and the
    // harness silently stops requiring the new kind. That is exactly what happened when S3 appended
    // four: `ClampWithNoneMaximum` was no longer last, the count read 19 instead of 23, and guard 3
    // checked nothing about `RandomFunction`, `CalcMixFunction`, `AnchorFunction` or
    // `AnchorSizeFunction`.
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
// WHY THIS ENTRY HAS TO EXIST. A parse always produces `Stage::Specified` -- CSSCalcTree+Parser.cpp
// builds the `Tree` that way and nothing on the parse path writes `Computed` -- so every case the
// differential has ever run through `webCoreCSSCalcCompareSerialization` has exercised one of the
// two stages, and for three phases of the port the island's blanket `Computed` decline was code
// that had never once executed against the harness. `Stage::Computed` is written in exactly one
// place in WebCore, StyleCalculationTree+Conversion.cpp:357 (`toCSS`, the getComputedStyle path),
// and reaching it through that function needs a `Style::Calculation::Tree`, which needs the
// conversion data this harness deliberately does not have. So the stage is set here, on a tree that
// was parsed: the oracle is two serializers over one `Tree` object, and it does not care how the
// object was built.
//
// AN UNWRAP-TO-LEAF PARAMETER WAS HERE AND IS NOT, BECAUSE IT WAS MEASURED INERT. The stage changes
// the serialization for a NUMERIC ROOT and for nothing else, so the phase is worthless unless the
// root really is one -- and `constructRootShape` above says `calc(1px)` parses to a one-child `Sum`
// wrapping the leaf, which would mean it is not. It does not: `parseAndSimplify` folds the wrapper
// away, and all 660 of calccheck's C1 cases land on a numeric root with no unwrap at all. That
// comment on `constructRootShape` is stale, and it is corrected there. The harness asserts the
// outcome instead of arranging it -- `Expect::Leaf` requires `nodeCount == 1` and a numeric
// `rootKind` -- which fails loudly if simplification ever stops folding, where a silent unwrap
// would have hidden it.
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

// The reference-free oracle the spec gives for free: serialization must be idempotent under
// reparsing, i.e. serialize(parse(s)) == serialize(parse(serialize(parse(s)))). It catches a
// divergence without running the C++ arm at all, which matters because it can fail on a case where
// the two arms agree with each other -- a symmetric misreading of the spec satisfies a differential
// and does not satisfy this.
//
// `serializerKind` is 0 for C++ and 1 for Swift, so the property can be asserted of each arm
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

// Makes the island decline every tree, so the C++ fall-through runs even with the gate on. S0
// declines most input anyway, but that will stop being true as S1 and S2 land, and a fall-through
// that is only reachable by input is one that eventually ships untested.
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

// MARK: - The calc SIMPLIFICATION island's differential (CSSCalcSimplificationSwift.swift)
//
// A SIBLING of the serialization block above, not an extension of it, and the difference is the
// oracle. Serialization is `Tree -> String`, so its differential compares two strings and this file
// needed no comparison machinery for it. Simplification is `Tree -> Tree`, so every field below
// exists because a tree comparison has failure modes a string comparison does not; the helper block
// in the anonymous namespace above is the machinery, and simplifycheck.cpp's header is the full
// argument for each guard.
//
// THE ONE THING THAT MAKES THIS NON-VACUOUS, and it is not obvious: `parseAndSimplify` runs
// simplification INCREMENTALLY DURING THE PARSE, with the same `SimplificationOptions`, at 22 sites
// in CSSCalcTree+Parser.cpp. A parsed tree is therefore already at a FIXED POINT for the options it
// was parsed with, and handing it back to `copyAndSimplify` with those same options is the identity
// on essentially every case. So entry 1 parses at a fixed BASELINE -- `parseCalcExpression`'s
// options, which are the production ones from CSSUnevaluatedCalc.cpp:167 -- and simplifies under a
// SWEPT set built from the spec. When the two differ in a way simplification reads, real work
// happens; when they do not, nothing should, and the harness runs that deliberately as
// `--control identity`.

// The swept options, passed by pointer rather than as nine scalars so that an axis can be added
// without re-spelling the signature of every entry in four places.
struct CSSCalcSimplificationOptionsSpec {
    // Ordinal of `WebCore::CSS::Category`, 0..10, in declaration order.
    uint32_t category;
    double rangeMinimum;
    double rangeMaximum;
    // 0 none, 1 a style at 16px, 2 the same at 32px.
    uint32_t conversionDataKind;
    // 0 empty, 1 num, 2 px, 3 NaN, 4 +inf, 5 -inf, 6 -0, 7 subnormal, 8 INT_MAX.
    uint32_t symbolTableKind;
    uint32_t allowZeroValueLengthRemovalFromSum;
    // 0 Stage::Specified, 1 Stage::Computed, applied to the parsed tree before simplifying.
    uint32_t stage;
};

// One case's worth of comparison. Mirrored field-for-field by `struct Comparison` in
// simplifycheck.cpp; the order is ABI and the two must be edited together.
struct CSSCalcSimplificationComparison {
    uint32_t parsed;
    // The island's decision, and -- when it declined -- the alternative that caused it. 0xFF means
    // it declined without naming one, which the harness treats as a failure whenever the tree does
    // contain an unhandled alternative: an unattributed decline is one nobody can close.
    uint32_t declined;
    uint32_t declineKind;
    // (a) the verdict: deep, bitwise over leaf doubles, plus every `Type`, the stage and the
    // conversion-data flag. The only one of the three that can see a signed zero.
    uint32_t agree;
    // (b) `Tree::operator==`, defaulted. Reported BESIDE (a) rather than instead of it because it
    // disagrees in two directions -- too strict on NaN, too weak on signed zero -- and the harness
    // asserts the disagreement set is exactly the NaN set.
    uint32_t agreeDefaulted;
    // (c) both result trees through the C++ serializer, on BOTH arms, so a defect in the
    // serialization island cannot be mistaken for one here. Diagnostic, never the verdict.
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
    // 41-bit masks over `Node` alternative indices. The island's must be a SUBSET of the input's,
    // and equal to it on any case it did not decline.
    uint64_t inputKindMask;
    uint64_t islandKindMask;
    uint32_t cppLength;
    uint32_t swiftLength;
};

// THE LAYOUT IS THE CONTRACT, so it is pinned rather than described. These two structs cross a
// `dlsym` boundary into a harness that declares its own copies; a field inserted on one side and not
// the other does not fail to link, it silently shifts every field after it and the differential
// starts comparing `agree` against `containsNaN`. The numbers are the ones simplifycheck.cpp's own
// declarations produce, measured by compiling them standalone -- not derived by hand.
static_assert(sizeof(CSSCalcSimplificationOptionsSpec) == 40);
static_assert(offsetof(CSSCalcSimplificationOptionsSpec, rangeMinimum) == 8);
static_assert(offsetof(CSSCalcSimplificationOptionsSpec, conversionDataKind) == 24);
static_assert(offsetof(CSSCalcSimplificationOptionsSpec, stage) == 36);
static_assert(sizeof(CSSCalcSimplificationComparison) == 112);
static_assert(offsetof(CSSCalcSimplificationComparison, parseCategory) == 84);
static_assert(offsetof(CSSCalcSimplificationComparison, inputKindMask) == 88);
static_assert(offsetof(CSSCalcSimplificationComparison, islandKindMask) == 96);
static_assert(offsetof(CSSCalcSimplificationComparison, cppLength) == 104);
static_assert(offsetof(CSSCalcSimplificationComparison, swiftLength) == 108);

WEBCORE_EXPORT CSSCalcSimplificationComparison webCoreCSSCalcCompareSimplification(const char*, size_t, const CSSCalcSimplificationOptionsSpec*, char*, size_t, char*, size_t);
WEBCORE_EXPORT CSSCalcSimplificationComparison webCoreCSSCalcCompareSimplificationConstructed(unsigned, const CSSCalcSimplificationOptionsSpec*, char*, size_t, char*, size_t);
WEBCORE_EXPORT bool webCoreCSSCalcSimplificationIsSwift(void);
WEBCORE_EXPORT void webCoreCSSCalcSimplificationSetForceDecline(bool);
WEBCORE_EXPORT unsigned webCoreCSSCalcSimplificationDeclineCount(void);
WEBCORE_EXPORT uint64_t webCoreCSSCalcSimplificationHarnessCallCount(void);
WEBCORE_EXPORT uint32_t webCoreCSSCalcChildAlternativeCount(void);
WEBCORE_EXPORT uint32_t webCoreCSSCalcCategoryCount(void);
WEBCORE_EXPORT uint32_t webCoreCSSCalcConstructedShapeCount(void);
WEBCORE_EXPORT bool webCoreCSSCalcSimplificationFontMetricsAvailable(void);

static std::atomic<uint64_t> s_simplifyCompareCalls;

// THE BRIDGE KEEPS ITS OWN DECLINE COUNTER rather than forwarding
// `CSSCalc::webCoreCSSCalcSimplificationDeclineCount()`, and the reason is measurable rather than
// stylistic: each comparison below calls the Swift arm THREE times -- once for the answer and twice
// more for the two idempotence probes -- so the island's own counter advances by up to three per
// case while the harness tallies one per returned `declined`. Forwarding would fail the harness's
// cross-check on every run and the failure would read as a decline the harness missed. What is
// counted here is exactly "a comparison whose reported answer was a decline".
static std::atomic<unsigned> s_simplifyComparisonDeclines;

// Everything the two comparison entries share. Both arms run on the same input `Tree` object inside
// one call, which is what makes it impossible to pair a C++ answer for one case with a Swift answer
// for another.
static CSSCalcSimplificationComparison compareSimplificationOfTree(CSSCalc::Tree&& inputTree, const CSSCalcSimplificationOptionsSpec* spec, uint32_t parseCategory, char* cppOut, size_t cppCapacity, char* swiftOut, size_t swiftCapacity)
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

    auto options = CSSCalc::SimplificationOptions {
        .category = static_cast<WebCore::CSS::Category>(spec->category),
        .range = WebCore::CSS::Range { spec->rangeMinimum, spec->rangeMaximum },
        .conversionData = spec->conversionDataKind
            ? std::optional<CSSToLengthConversionData> { CSSToLengthConversionData { simplificationStyleAtFontSize(spec->conversionDataKind == 2 ? 32.0f : 16.0f), nullptr, nullptr, nullptr, nullptr } }
            : std::nullopt,
        .symbolTable = simplificationSymbolTable(spec->symbolTableKind),
        .allowZeroValueLengthRemovalFromSum = !!spec->allowZeroValueLengthRemovalFromSum,
    };

    result.inputKindMask = alternativeMaskOfSubtree(input.root);
    result.inputNodeCount = nodeCountOfSubtree(input.root);
    result.inputRootKind = static_cast<uint32_t>(input.root.value.index());

    auto declinesBefore = CSSCalc::webCoreCSSCalcSimplificationDeclineCount();
    auto cppTree = CSSCalc::copyAndSimplify(input, options, CSSCalc::Simplifier::Cpp);
    auto swiftTree = CSSCalc::copyAndSimplify(input, options, CSSCalc::Simplifier::Swift);
    auto declinesAfter = CSSCalc::webCoreCSSCalcSimplificationDeclineCount();

    result.declined = declinesAfter != declinesBefore ? 1 : 0;
    if (result.declined)
        s_simplifyComparisonDeclines.fetch_add(1, std::memory_order_relaxed);
    result.declineKind = CSSCalc::webCoreCSSCalcSimplificationLastDeclineAlternative();
    result.islandKindMask = CSSCalc::webCoreCSSCalcSimplificationLastKindMask();

    result.agree = bitwiseEqualTree(cppTree, swiftTree) ? 1 : 0;
    result.agreeDefaulted = cppTree == swiftTree ? 1 : 0;
    result.containsNaN = (subtreeContainsNaN(cppTree.root) || subtreeContainsNaN(swiftTree.root)) ? 1 : 0;

    result.cppChangedInput = bitwiseEqualTree(input, cppTree) ? 0 : 1;
    result.swiftChangedInput = bitwiseEqualTree(input, swiftTree) ? 0 : 1;
    result.outputNodeCount = nodeCountOfSubtree(cppTree.root);
    result.outputRootKind = static_cast<uint32_t>(cppTree.root.value.index());

    // Idempotence, PER ARM and reference-free: it can fail on a case where the two arms agree with
    // each other, which a differential alone never catches. Compared bitwise on purpose -- the
    // defaulted comparison would report every NaN result as non-idempotent.
    result.cppIdempotent = bitwiseEqualTree(CSSCalc::copyAndSimplify(cppTree, options, CSSCalc::Simplifier::Cpp), cppTree) ? 1 : 0;
    result.swiftIdempotent = bitwiseEqualTree(CSSCalc::copyAndSimplify(swiftTree, options, CSSCalc::Simplifier::Swift), swiftTree) ? 1 : 0;

    result.cppCanSimplify = CSSCalc::canSimplify(input, options, CSSCalc::Simplifier::Cpp) ? 1 : 0;
    result.swiftCanSimplify = CSSCalc::canSimplify(input, options, CSSCalc::Simplifier::Swift) ? 1 : 0;
    result.cppCanSimplifySound = (result.cppCanSimplify || !result.cppChangedInput) ? 1 : 0;
    result.swiftCanSimplifySound = (result.swiftCanSimplify || !result.swiftChangedInput) ? 1 : 0;

    result.cppPreservedStageAndFlag = (cppTree.stage == input.stage && cppTree.requiresConversionData == input.requiresConversionData) ? 1 : 0;
    result.swiftPreservedStageAndFlag = (swiftTree.stage == input.stage && swiftTree.requiresConversionData == input.requiresConversionData) ? 1 : 0;

    // Both through `Serializer::Cpp`, so that a defect in the serialization island shows up in its
    // own differential and not as a phantom failure in this one.
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

WEBCORE_EXPORT CSSCalcSimplificationComparison webCoreCSSCalcCompareSimplification(const char* text, size_t length, const CSSCalcSimplificationOptionsSpec* spec, char* cppOut, size_t cppCapacity, char* swiftOut, size_t swiftCapacity)
{
    // Counted BEFORE the parse filter, so that the harness's call tally matches even for cases that
    // do not parse -- it counts calls made, not cases run.
    s_simplifyCompareCalls.fetch_add(1, std::memory_order_relaxed);

    CSSCalcSimplificationComparison result { };
    result.declineKind = 0xFF;
    String source { unsafeMakeSpan(byteCast<Latin1Character>(text), length) };

    auto parsed = parseCalcExpression(source);
    if (!parsed.tree)
        return result;

    return compareSimplificationOfTree(WTF::move(*parsed.tree), spec, static_cast<uint32_t>(parsed.category), cppOut, cppCapacity, swiftOut, swiftCapacity);
}

// The same comparison over a tree built DIRECTLY rather than parsed. `constructSimplificationShape`
// says which four and why no parse reaches them.
//
// ONE INTERACTION WITH THE HARNESS'S IDENTITY CONTROL IS KNOWN AND IS NOT PAPERED OVER HERE. Shape 2
// is `Deg2Rad{CanonicalDimension(1deg)}`, and `simplify(Deg2Rad&)` folds a `CanonicalDimension`
// child unconditionally -- with no swept option involved -- so this entry honestly reports
// `cppChangedInput = 1` for it even at the parse baseline. `--control identity` requires the global
// changed-count to be zero, and it feeds `checkConstructed`'s count into that total, so that control
// will report shape 2. Reporting 0 instead would be a lie about the one case in the corpus where the
// island's `Deg2Rad` handling produces a node, so the honest number is reported and the control's
// premise -- "a tree handed back at its own parse fixed point does not change" -- is simply not true
// of a CONSTRUCTED tree, which is the whole reason this entry exists.
WEBCORE_EXPORT CSSCalcSimplificationComparison webCoreCSSCalcCompareSimplificationConstructed(unsigned shape, const CSSCalcSimplificationOptionsSpec* spec, char* cppOut, size_t cppCapacity, char* swiftOut, size_t swiftCapacity)
{
    s_simplifyCompareCalls.fetch_add(1, std::memory_order_relaxed);

    CSSCalcSimplificationComparison result { };
    result.declineKind = 0xFF;

    auto tree = constructSimplificationShape(shape);
    if (!tree)
        return result;

    return compareSimplificationOfTree(WTF::move(*tree), spec, spec->category, cppOut, cppCapacity, swiftOut, swiftCapacity);
}

// The compile-time default, so a build that ignored WK_USE_SWIFT_CSS_CALC_SIMPLIFICATION cannot pass
// as one that honoured it. Reported separately from what the entries above do, which name their arm
// explicitly: conflating the two is how an ignored build flag reads as a pass.
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

WEBCORE_EXPORT uint64_t webCoreCSSCalcSimplificationHarnessCallCount(void)
{
    return s_simplifyCompareCalls.load(std::memory_order_relaxed);
}

// FROM THE VARIANT, never from an enumerator. This is the number the harness keys every mask,
// expectation and coverage figure on, and `webCoreCSSCalcNodeKindCount` above is the cautionary
// tale: spelled as "the last enumerator + 1", it read 19 when the answer was 23 and the coverage
// guard silently stopped requiring four kinds. `VariantSizeV` cannot do that, and it is also the
// right-hand side of the assert that pins `CSSCalcSwiftAlternative` in
// CSSCalcTree+Serialization.cpp -- so the harness and the boundary are driven by one fact.
WEBCORE_EXPORT uint32_t webCoreCSSCalcChildAlternativeCount(void)
{
    return static_cast<uint32_t>(WTF::VariantSizeV<CSSCalc::Node>);
}

// The category list this file actually sweeps, not a recount of the enum.
//
// STILL NOT FULLY DRIFT-PROOF, and saying so is better than implying otherwise: `CSS::Category` has
// no count of its own, so a category APPENDED after `AnglePercentage` would be missed by both sides
// of the assert below and by `calcCategories`. What the assert does catch is the likelier edit --
// one added in the middle, or one removed -- and what would close the gap properly is a count in
// CSSPrimitiveNumericCategory.h, which is a change to a header this island does not own.
WEBCORE_EXPORT uint32_t webCoreCSSCalcCategoryCount(void)
{
    static_assert(calcCategories.size() == static_cast<size_t>(WebCore::CSS::Category::AnglePercentage) + 1);
    return static_cast<uint32_t>(calcCategories.size());
}

WEBCORE_EXPORT uint32_t webCoreCSSCalcConstructedShapeCount(void)
{
    return simplificationConstructedShapeCount;
}

// ENTRY 10. Does the conversionData fixture support FONT-METRIC-relative units?
//
// WHY A BRIDGE ENTRY AND NOT A COMMENT. `simplificationStyleAtFontSize` used to leave the style's
// `FontCascade::m_fonts` null, and every font-metric unit (`ex`, `cap`, `ch`, `ic`, `lh` and the
// `r*` forms) then took EXC_BAD_ACCESS inside `Style::resolveEx`. The harness had to exclude those
// units to run at all. An exclusion keyed on a comment ROTS: the day the fixture is fixed, the
// excluded units stay excluded and the sweep silently reports a pass over a hole. So the fixture
// reports its own capability and the harness keys the exclusion on the ANSWER.
//
// THE ANSWER IS NOT `fonts() != nullptr`. That would be satisfied by a fixture whose two styles
// realised the SAME font, which would make the whole conversionData axis vacuous -- a `canonicalize`
// returning a constant would pass. So this returns true only if both styles have a realised font AND
// their x-heights, cap-heights and line spacings all DIFFER, which is the property the two-font-size
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

} // extern "C"

#endif // ENABLE(CSS_TOKENIZER_SWIFT_BRIDGE)
