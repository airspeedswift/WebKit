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

// Everything CSSCalcSerializationSwift.swift and CSSCalcSimplificationSwift.swift may see of
// WebCore. It has its own Clang module in WebCore_Private.modulemap and must stay self-contained:
// including CSSCalcTree.h or CSSTokenizer.h here walks the importer into the PrivateHeaders
// umbrella.
//
// Every function declared here must stay `noexcept`, or Swift emits a termination landing pad
// around each call to it.

#pragma once

#include <WebCore/CSSCalcType.h>
#include <WebCore/CSSParserTokenBits.h>
#include <WebCore/CSSUnitType.h>
#include <WebCore/PlatformExportMacros.h>
#include <cstddef>
#include <cstdint>
#include <type_traits>
#include <wtf/Ref.h>
#include <wtf/RefCounted.h>
#include <wtf/SwiftBridging.h>
#include <wtf/TZoneMalloc.h>
#include <wtf/Vector.h>

namespace WTF {
class StringBuilder;
}

namespace WebCore {

class CSSParserTokenRange;
class CSSCalcSymbolsAllowed;

namespace CSS {
struct SerializationContext;
// Not included: CSSPropertyParserState.h names the generated property-id enum.
struct PropertyParserState;
}

namespace CSSCalc {

struct Child;
struct Tree;
struct SimplificationOptions;
struct EvaluationOptions;

// Defined in CSSCalcTree+Simplification.cpp.
struct CSSCalcSwiftOperandStack;

// The payload table: the values the parse resolves for an `<anchor-element>`, a `<random-key>` and a
// `calc-mix()` weight that is a math function. A parsed `CalcNode` names one by index in its
// `origin`; Swift never sees the values. Defined in CSSCalcTree.h.
struct CSSCalcSwiftFlatPayloads;


// The shape of a node's serialization, not its operation: several operations share a kind, and
// `CSSCalcSwiftNodeInfo::valueID` carries the name. `Operation` is one the Swift serializer does
// not handle.
//
// New cases are appended, never inserted: `CSSCalcSwiftSerializationResult::kindMask` is
// `1 << rawValue`.
enum class CSSCalcSwiftNodeKind : uint8_t {
    Number,
    Percentage,
    CanonicalDimension,
    NonCanonicalDimension,
    Symbol,
    SiblingCount,
    SiblingIndex,
    Sum,
    Product,
    Negate,
    Invert,
    Operation,
    // No producer. Retained because removing it would renumber every kind below it.
    OpaqueOperation,
    // `Deg2Rad`, which has no CSS-level spelling and serializes as its child.
    Transparent,
    Function,
    // `valueID` is the rounding strategy rather than the function name.
    RoundFunction,
    ProgressNoClampFunction,
    // `clamp()` with one bound holding the keyword `none`, which `forAllChildNodes` skips. Without
    // these, `clamp(none, VAL, MAX)` would serialize as `clamp(VAL, MAX)`.
    ClampWithNoneMinimum,
    ClampWithNoneMaximum,
    // The four operations whose arguments are not all calculation trees; see
    // `CSSCalcSwiftOperationInfo`. `childCount` counts only the `Child`s.
    RandomFunction,
    CalcMixFunction,
    AnchorFunction,
    AnchorSizeFunction,
    // `clamp(none, VAL, none)`, which `simplify(Clamp&)` rewrites to `VAL`, so only an unsimplified
    // tree serializes it.
    ClampWithNoneMinimumAndMaximum,
};

// Swift's `<<` yields 0 for a shift of 32 or more rather than trapping, so a kind past 31 would
// silently drop out of `kindMask`.
static_assert(static_cast<uint8_t>(CSSCalcSwiftNodeKind::ClampWithNoneMinimumAndMaximum) < 32, "kindMask is 1 << rawValue in a UInt32");

// Which of `CSSCalc::Node`'s variant alternatives a node is, numbered by `Node::index()`. `Node`'s
// `Variant<...>` is generated from this list in CSSCalcTree.h, and each pairing is pinned with
// `WTF::alternativeIndexV` in CSSCalcTree+Serialization.cpp, because `init?(rawValue:)` on an
// imported C++ enum never fails.
//
// Split into FIRST and REST because a template argument list cannot carry a trailing comma.
#define CSS_CALC_SWIFT_FOR_EACH_ALTERNATIVE_FIRST(macro) \
    macro(Number, Number)

#define CSS_CALC_SWIFT_FOR_EACH_ALTERNATIVE_REST(macro) \
    macro(Percentage, Percentage) \
    macro(CanonicalDimension, CanonicalDimension) \
    macro(NonCanonicalDimension, NonCanonicalDimension) \
    macro(Symbol, Symbol) \
    macro(SiblingCount, SiblingCount) \
    macro(SiblingIndex, SiblingIndex) \
    macro(Sum, IndirectNode<Sum>) \
    macro(Product, IndirectNode<Product>) \
    macro(Negate, IndirectNode<Negate>) \
    macro(Invert, IndirectNode<Invert>) \
    macro(Deg2Rad, IndirectNode<Deg2Rad>) \
    macro(Min, IndirectNode<Min>) \
    macro(Max, IndirectNode<Max>) \
    macro(Clamp, IndirectNode<Clamp>) \
    macro(RoundNearest, IndirectNode<RoundNearest>) \
    macro(RoundUp, IndirectNode<RoundUp>) \
    macro(RoundDown, IndirectNode<RoundDown>) \
    macro(RoundToZero, IndirectNode<RoundToZero>) \
    macro(Mod, IndirectNode<Mod>) \
    macro(Rem, IndirectNode<Rem>) \
    macro(Sin, IndirectNode<Sin>) \
    macro(Cos, IndirectNode<Cos>) \
    macro(Tan, IndirectNode<Tan>) \
    macro(Asin, IndirectNode<Asin>) \
    macro(Acos, IndirectNode<Acos>) \
    macro(Atan, IndirectNode<Atan>) \
    macro(Atan2, IndirectNode<Atan2>) \
    macro(Pow, IndirectNode<Pow>) \
    macro(Sqrt, IndirectNode<Sqrt>) \
    macro(Hypot, IndirectNode<Hypot>) \
    macro(Log, IndirectNode<Log>) \
    macro(Exp, IndirectNode<Exp>) \
    macro(Abs, IndirectNode<Abs>) \
    macro(Sign, IndirectNode<Sign>) \
    macro(Random, IndirectNode<Random>) \
    macro(Progress, IndirectNode<Progress>) \
    macro(ProgressNoClamp, IndirectNode<ProgressNoClamp>) \
    macro(CalcMix, IndirectNode<CalcMix>) \
    macro(Anchor, IndirectNode<Anchor>) \
    macro(AnchorSize, IndirectNode<AnchorSize>)

#define CSS_CALC_SWIFT_FOR_EACH_ALTERNATIVE(macro) \
    CSS_CALC_SWIFT_FOR_EACH_ALTERNATIVE_FIRST(macro) \
    CSS_CALC_SWIFT_FOR_EACH_ALTERNATIVE_REST(macro)

enum class CSSCalcSwiftAlternative : uint8_t {
#define CSS_CALC_SWIFT_DECLARE_ALTERNATIVE(name, type) name,
    CSS_CALC_SWIFT_FOR_EACH_ALTERNATIVE(CSS_CALC_SWIFT_DECLARE_ALTERNATIVE)
#undef CSS_CALC_SWIFT_DECLARE_ALTERNATIVE
};

// Held equal to `WTF::VariantSizeV<Node>` in CSSCalcTree+Serialization.cpp.
#define CSS_CALC_SWIFT_COUNT_ALTERNATIVE(name, type) + 1
static constexpr uint8_t numberOfCSSCalcSwiftAlternatives = 0 CSS_CALC_SWIFT_FOR_EACH_ALTERNATIVE(CSS_CALC_SWIFT_COUNT_ALTERNATIVE);
#undef CSS_CALC_SWIFT_COUNT_ALTERNATIVE

// What the four operation kinds need beyond their child subtrees. A field a kind does not carry is
// zero.
struct CSSCalcSwiftOperationInfo {
    // `Anchor`: the `<anchor-side>` keyword. `AnchorSize`: the `<anchor-size>` dimension keyword.
    // `Random`: `property-scoped` or `property-index-scoped`. `CSSValueInvalid` otherwise.
    uint16_t valueID;

    // Both false means `auto`, which serializes as omitted.
    bool randomSharingIsKey;
    bool randomSharingIsFixed;
    bool randomKeyHasName;
    bool randomKeyIsElementScoped;
    bool randomKeyHasPropertyScope;

    // When false, the `<anchor-side>` is a `<percentage>` subtree in child 0.
    bool anchorSideIsKeyword;

    bool hasElementName;
    bool hasDimension;
    // Redundant with `childCount`, so that a mismatch is a contract violation rather than an
    // argument written in the wrong position.
    bool hasFallback;
};

// One `calc-mix()` item's weight: absent, raw, or `Calc`. The spec's step 1 counts the absent
// ones and `simplify(CalcMix&)`'s `canNormalize` rejects the `Calc` ones. `value` is zero unless
// the weight is raw.
struct CSSCalcSwiftCalcMixWeight {
    double value;
    bool present;
    bool isRaw;
};

static_assert(sizeof(CSSCalcSwiftCalcMixWeight) == 16);

// One node, described. A field a kind does not carry is `CSSValueInvalid`, `CSSUnitType::Unknown`
// or zero.
struct CSSCalcSwiftNodeInfo {
    double numericValue;
    // Counts as `forAllChildNodes` does, so a `ChildOrNone` holding `none` is not counted.
    uint32_t childCount;
    uint16_t valueID;
    // `toCSSUnit(node)` for a numeric leaf, and `Symbol::unit` for a `Symbol`: `simplify(Symbol&)`
    // takes the value from `CSSCalcSymbolTable` and the unit from the node.
    uint8_t unitType;
    CSSCalcSwiftNodeKind kind;
    // `Type::PercentHint`'s underlying value, 0 for none.
    uint8_t percentHint;
    CSSCalcSwiftAlternative alternative;
    // An `anchor()` whose `<anchor-side>` is a subtree: child 0 is the side and the fallback, if
    // any, is child 1.
    bool anchorSideIsSubtree;
};

// MARK: - Reading a node
//
// `Child` is taken as a `const Child&` parameter, never returned: only a return imports as
// `UnsafePointer`.
WEBCORE_EXPORT CSSCalcSwiftNodeInfo swiftNodeInfo(const Child&) noexcept;
WEBCORE_EXPORT CSSCalcSwiftOperationInfo swiftOperationInfo(const Child&) noexcept;
WEBCORE_EXPORT CSSCalcSwiftCalcMixWeight swiftCalcMixItemWeight(const Child&, uint32_t index) noexcept;

// Where the serialization output goes. Numbers are formatted in C++, because CSS number
// serialization is not Swift's shortest-round-trip `Double.description`.
//
// `SWIFT_SAFE` is an unchecked assertion about the two raw pointers below. It holds only while no
// Swift type stores one of these: every Swift signature takes it `inout`, which cannot escape.
struct SWIFT_SAFE CSSCalcSwiftSink {
    CSSCalcSwiftSink(WTF::StringBuilder& builder LIFETIME_BOUND, const CSS::SerializationContext& context LIFETIME_BOUND) noexcept
        : m_builder(&builder)
        , m_context(&context)
    {
    }

    // A `CSSCalcSwiftLiteral`, a Swift enum this header cannot name: the generated header that
    // declares it depends on this one.
    WEBCORE_EXPORT void appendLiteral(uint8_t literal) noexcept;

    WEBCORE_EXPORT void appendNumber(double value, uint8_t unitType) noexcept;

    // `nameLiteralForSerialization(CSSValueID)`.
    WEBCORE_EXPORT void appendValueIDName(uint16_t valueID) noexcept;

    // Arguments that are CSS values rather than calculation trees, serialized by their own C++ types.
    WEBCORE_EXPORT void appendOperationArgument(const Child&, uint8_t part, uint32_t index) noexcept;

private:
    WTF::StringBuilder* m_builder;
    const CSS::SerializationContext* m_context;
};

// What the serialization walk did.
struct CSSCalcSwiftSerializationResult {
    // Bit `1 << rawValue` for each CSSCalcSwiftNodeKind the walk stood on.
    uint32_t kindMask;
    uint32_t nodeCount;
    // 0 = serialized, 1 = handed back. Pinned by static_assert against the Swift enum.
    uint8_t outcome;
};

// MARK: - The Swift calc simplification path (CSSCalcSimplificationSwift.swift)

// A leaf to build. `makeNumeric` recovers `CanonicalDimension::Dimension` from `unitType`.
struct CSSCalcSwiftLeaf {
    double value;
    uint16_t unitType;
    // A `CSSCalcSwiftNodeKind`: one of the four numeric leaves, the two tree-counting ones, or
    // `Symbol`.
    uint8_t kind;
    uint8_t percentHint;
    // `Symbol::id`; `CSSValueInvalid` for every other kind.
    uint16_t valueID;
};
static_assert(sizeof(CSSCalcSwiftLeaf) == 16);

// A `double` and a `CSSUnitType`, or nothing: one type for both of the builder's lookups.
struct CSSCalcSwiftNumericResult {
    double value;
    // For `resolveSymbol`, `toCSSUnit` of the leaf `makeNumeric` built, so that passing it back to
    // `pushLeaf` builds the same alternative.
    uint16_t unitType;
    // False means "no answer", not an error: an unresolved `<calc-keyword>` or a `1em` with no
    // conversion data stays as it is.
    bool resolved;
    // Reported so that `makeNumeric`'s unit table is not duplicated in Swift.
    CSSCalcSwiftAlternative alternative;

    // For `anchor()` and `anchor-size()`: the evaluation answered nothing, so the node is replaced
    // by its fallback, or the property is invalid at computed-value time if it has none. Mutually
    // exclusive with `resolved`.
    bool substituteFallback;
};

static_assert(sizeof(CSSCalcSwiftNumericResult) == 16);

// The parts of `CSSCalc::SimplificationOptions` Swift reads, each reduced to a trivial type.
struct CSSCalcSwiftSimplificationOptions {
    double rangeMinimum;
    double rangeMaximum;
    // `CSS::Category`'s underlying value. Not read by Swift.
    uint8_t category;
    bool allowZeroValueLengthRemovalFromSum;
    bool hasConversionData;
    // `percentageResolveToDimension(options)`.
    bool percentageResolveToDimension;
};

// MARK: - Building the result tree

// "No payload" and "no such node". No tree or payload table is large enough to reach it.
static constexpr uint32_t cssCalcSwiftFlatNoNode = UINT32_MAX;

// Where the Swift simplifier's output goes: an operand stack. Swift emits its tree post-order,
// pushing each finished leaf; an operation pops the operands it consumes and pushes one node. No
// Swift container ever holds a `Child`.
//
// `SWIFT_SAFE` is an unchecked assertion, as on `CSSCalcSwiftSink`. This type is also taken by
// value, so it holds only while every copy stays a parameter of the same recursion. The operand
// stack and root slot are fresh C++ storage, not reachable from the input tree.
struct SWIFT_SAFE CSSCalcSwiftBuilder {
    CSSCalcSwiftBuilder(CSSCalcSwiftOperandStack& operands LIFETIME_BOUND, const SimplificationOptions& options LIFETIME_BOUND) noexcept
        : m_operands(&operands)
        , m_options(&options)
    {
    }

    // `isRoot` on the entries below constructs the node into the root slot rather than onto the
    // operand stack. With no root slot provided it pushes.

    // Returns false, a contract violation, for a `kind` `CSSCalcSwiftLeaf::kind` does not allow.
    WEBCORE_EXPORT bool pushLeaf(CSSCalcSwiftLeaf, bool isRoot = false) noexcept;

    // Push a deep copy of an input subtree, made by `CSSCalc::copy(const Child&)`.
    WEBCORE_EXPORT void pushCopyOf(const Child&, bool isRoot = false) noexcept;

    // Pop `childCount` operands and push one node of `original`'s operation, with `original`'s type.
    // A `Children` slot takes all the operands, so its arity may change; every other slot takes one
    // or none.
    //
    // Returns false for a contract violation: too few operands, a mismatched arity, or a leaf.
    // `Anchor` and `AnchorSize` declare `tuple_size` 0 (webkit.org/b/280798) and are rebuilt by
    // `rebuildChildren`.
    WEBCORE_EXPORT bool rebuildFrom(const Child& original, uint32_t childCount, bool isRoot = false) noexcept;

    // Push the weight of the next `calc-mix()` item. A `calc-mix()` consumes the top `childCount` of
    // both the operand and the weight stacks.
    //
    // For `rebuildFrom`, `replaceWeight` clear means "original item `origin`'s weight, unchanged",
    // which is how `simplify(CalcMix&)`'s `!canNormalize` path drops items while keeping the
    // survivors' weights. For `buildOperation`, which has no original, clear means an omitted weight.
    //
    // A `payloadIndex` other than `cssCalcSwiftFlatNoNode` names a `Calc` weight in the payload table
    // and takes precedence over the other arguments. Returns false only for a `payloadIndex` that
    // names no payload, a contract violation.
    WEBCORE_EXPORT bool pushCalcMixItemWeight(uint32_t origin, double weight, bool replaceWeight, uint32_t payloadIndex = cssCalcSwiftFlatNoNode) noexcept;

    // Pop `childCount` operands and push a new node of `alternative`, for a node with no original
    // to rebuild from, and for `clamp()` rewritten to `min()` or `max()`.
    //
    // `Type` is supplied rather than recomputed, because `copyAndSimplify` keeps a node's type when
    // its kind does not change: `calc((2 / 3px) * 4px)` keeps its parse-time type, where `toType`
    // of the surviving `Product{6px, 4px}` is px^2.
    //
    // `noneMask` bit 0 means the minimum bound is `none`, bit 1 the maximum; `clamp(none, V, M)`
    // and `clamp(M, V, none)` both push two operands.
    //
    // Returns false, leaving the stack untouched, for a contract violation: an alternative this does
    // not build, a mismatched arity, or too few operands.
    WEBCORE_EXPORT bool buildOperation(CSSCalcSwiftAlternative, uint32_t childCount, Type, bool isRoot = false, uint8_t noneMask = 0) noexcept;

    // Pop the subtree operands of an `anchor()` or `anchor-size()` and push the finished node.
    // `elementNamePayload` names the `CSS::CustomIdent` from `resolveDashedIdentAt` in the payload
    // table, or is `cssCalcSwiftFlatNoNode` for none.
    //
    // `valueID` `CSSValueInvalid` means, for an `AnchorSize`, no dimension; for an `Anchor`, that
    // the side is the `<percentage>` subtree in slot 0.
    WEBCORE_EXPORT bool buildAnchor(CSSCalcSwiftAlternative, uint32_t childCount, Type, bool isRoot, uint16_t valueID, uint32_t elementNamePayload) noexcept;

    // Pop a `random()`'s two or three `<calc-sum>` operands and push the finished node.
    // `sharingPayload` names the `Random::Sharing` that `consumeRandomKey` resolved.
    //
    // The sharing is carried whole: `resolveRandomBaseValue` hashes all of it into a
    // `RandomCachingKey`, and a second derivation that disagreed would give one key two values.
    WEBCORE_EXPORT bool buildRandom(uint32_t childCount, Type, bool isRoot, uint32_t sharingPayload) noexcept;

    // Drop every operand, after an emit that stopped half way.
    WEBCORE_EXPORT void clearOperands() noexcept;

    // `simplify(Symbol&)`: `makeNumeric(options.symbolTable.get(id)->value, unit)`, with the
    // node's unit; see `CSSCalcSwiftNodeInfo::unitType`.
    WEBCORE_EXPORT CSSCalcSwiftNumericResult resolveSymbol(uint16_t valueID, uint16_t unit) const noexcept;

    // `canonicalize`'s `tryMakeCanonical`, for the lengths that need `CSSToLengthConversionData`.
    // The Swift `switch` calls this as its `default` case, so the set is not duplicated.
    WEBCORE_EXPORT CSSCalcSwiftNumericResult resolveRelativeLength(double value, uint16_t unitType) const noexcept;

    // `simplify`'s `Style::BuilderState` folds of `sibling-count()`, `sibling-index()`, `random()`,
    // `anchor()` and `anchor-size()`, dispatched on the node's variant tag. `resolved == false` is
    // the C++'s `std::nullopt`. The anchor answers are a `CanonicalDimension` and alone use
    // `substituteFallback`; the others are a `<number>`.
    //
    // This may mark the property invalid at computed-value time. The mark has no clear, so a
    // repeated call is harmless.
    WEBCORE_EXPORT CSSCalcSwiftNumericResult resolveStyleCoupledValue(const Child&) const noexcept;

private:
    // The payload `index` names, or null for no table, an index out of range, or a payload that is
    // not a `T`. Each is a contract violation, and callers refuse rather than substitute a default.
    template<typename T> const T* payloadFor(uint32_t index) const noexcept;

    CSSCalcSwiftOperandStack* m_operands;
    const SimplificationOptions* m_options;
};

// What the simplification walk did.
struct CSSCalcSwiftSimplificationResult {
    // Bit `1 << rawValue` for each `CSSCalcSwiftAlternative` the walk stood on. Keyed on the
    // alternative because `min()` and `mod()` share a `CSSCalcSwiftNodeKind`.
    uint64_t kindMask;
    uint32_t nodeCount;
    // 0 = simplified, 1 = handed back. Pinned by static_assert in CSSCalcTree+Simplification.cpp.
    uint8_t outcome;
    // The `CSSCalcSwiftAlternative` that stopped the walk, or 0xFF.
    uint8_t declineAlternative;
};

// MARK: - The Swift calc parse path's token boundary

// One CSS token, as the calc grammar needs it. Unlike `CSSParserTokenBits` it holds no pointer into
// the stylesheet text.
struct CSSCalcSwiftToken {
    double numericValue;
    // Raw `CSSValueID`s: CSSValueKeywords.h is generated. Swift compares them only against values it
    // obtains from C++.
    uint16_t id;
    uint16_t functionId;
    // 16 bits, as `CSSParserToken::delimiter()` returns: at 8, U+012B would compare equal to '+'.
    char16_t delimiter;
    CSSUnitType unit;
    CSSParserTokenType type;
    // `CSSParserToken::BlockType`, pinned in CSSCalcTree+Parser.cpp.
    uint8_t blockType;

    // Predicates on the fields above, computed once per token by `fillTokens`.
    uint8_t flags;
};
// For a DimensionToken: `conversionToCanonicalUnitRequiresConversionData(unit)`.
static constexpr uint8_t cssCalcSwiftTokenUnitNeedsConversionData = 1 << 0;
// For a FunctionToken: `isCalcFunction(functionId)`. A math function the Swift grammar does not parse
// hands the input back rather than failing.
static constexpr uint8_t cssCalcSwiftTokenIsCalcFunction = 1 << 1;
// For a FunctionToken: `calc()` or `-webkit-calc()`. A function with neither bit fails the parse.
static constexpr uint8_t cssCalcSwiftTokenIsPlainCalcFunction = 1 << 2;
static_assert(sizeof(CSSCalcSwiftToken) == 24);
static_assert(alignof(CSSCalcSwiftToken) == 8);

// What `consumeRandomKey` and `consumeCalcMixWeightAt` answer. Each resolves its construct with the
// C++ production and stores it in the payload table, so the emit needs no tokens and no
// `PropertyParserState`.
struct CSSCalcSwiftConsumedPayload {
    // First token past the construct, and past a `<random-key>`'s comma. Unchanged for an omitted key.
    uint32_t nextIndex;
    // The payload's index, which becomes the node's `origin`. An omitted `<random-key>` resolves to
    // `auto` and has one too.
    uint32_t payloadIndex;
    // False for input the C++ consumer rejects, which fails the enclosing function.
    bool consumed;
};
static_assert(sizeof(CSSCalcSwiftConsumedPayload) == 12);

// `ParserOptions::allowedSymbols.get(id)`, for `<calc-keyword>`.
struct CSSCalcSwiftSymbolResult {
    uint16_t unitType;
    bool resolved;
    // `conversionToCanonicalUnitRequiresConversionData` of the resolved unit.
    bool needsConversionData;
};
static_assert(sizeof(CSSCalcSwiftSymbolResult) == 4);

// A read-only cursor over the tokens of one `calc()`, which Swift copies into a buffer it owns
// because it cannot receive a bounds-carrying view of the range (rdar://186723514).
//
// `SWIFT_SAFE` is an unchecked assertion over the `std::span` inside `CSSParserTokenRange`. It holds
// because the cursor is constructed on the C++ stack immediately before the single Swift call that
// takes it and destroyed when that call returns, it crosses `noescape`, and the token vector is
// complete before any property parser runs.
struct SWIFT_SAFE CSSCalcSwiftParseCursor {
    // Includes whitespace tokens: the grammar looks behind at the token at `i - 1`.
    uint32_t tokenCount() const noexcept;

    // Tokens `[0, count)` into `out`. A slot past the end gets the `EOFToken` that
    // `CSSParserTokenRange::peek` returns there.
    void fillTokens(CSSCalcSwiftToken *__counted_by(count) out __attribute__((noescape)), uint32_t count) const noexcept;

    // `parseCalcKeyword`'s symbol-table lookup. When it does not resolve, the grammar tries the
    // `<calc-keyword>` constants next, in `parseCalcKeyword`'s order.
    CSSCalcSwiftSymbolResult lookupSymbol(uint16_t valueID) const noexcept;

    // `consumeRandom`'s `<random-key>` half at `index`, resolved into the payload table. It stays in
    // C++ because a key can hold an ident, a property name or a nested `calc()`, none of which a
    // `CSSCalcSwiftToken` carries.
    //
    // Swift calls this where `consumeRandom` calls `consumeUnresolvedRandomKey`, before the
    // arguments, and this reads and increments `cssRandomFunctionCount`, so the count is taken in
    // source order and a nested `random()` sees the incremented value.
    CSSCalcSwiftConsumedPayload consumeRandomKey(uint32_t index) const noexcept;

    // The caller's `PropertyParserState::cssRandomFunctionCount`, so that a parse that produces no
    // tree can restore it. 0, and the setter does nothing, without a `PropertyParserState`.
    uint32_t randomFunctionCount() const noexcept;
    void setRandomFunctionCount(uint32_t) const noexcept;

    // `MetaConsumer<CalcMix::Item::Weight>::consume` at `index`, for a weight that is a math
    // function. That weight is a separate `CSSCalc::Value`, parsed and simplified under its own
    // options (`UnevaluatedCalcBase::parseBase`), not part of this tree, so it goes in the payload
    // table. A raw `<percentage>` weight is parsed in Swift.
    CSSCalcSwiftConsumedPayload consumeCalcMixWeightAt(uint32_t index) const noexcept;

    // `consumeUnresolvedDashedIdent` over the token at `index`, resolved into the payload table,
    // because Swift cannot see a token's text. `cssCalcSwiftFlatNoNode` when the token is not a
    // `<dashed-ident>`.
    uint32_t resolveDashedIdentAt(uint32_t index) const noexcept;

#if !defined(__swift__)
    CSSCalcSwiftParseCursor(const CSSParserTokenRange& range, const CSSCalcSymbolsAllowed& symbols, CSS::PropertyParserState* propertyParserState = nullptr, CSSCalcSwiftFlatPayloads* payloads = nullptr)
        : m_range(range)
        , m_symbols(symbols)
        , m_propertyParserState(propertyParserState)
        , m_payloads(payloads)
    {
    }

private:
    const CSSParserTokenRange& m_range;
    const CSSCalcSymbolsAllowed& m_symbols;
    // Read only by the three resolving productions, and null for a caller with no property state.
    // Non-const because `consumeRandomKey` increments `cssRandomFunctionCount`; the member functions
    // stay `const`, so Swift imports them as non-mutating.
    CSS::PropertyParserState* m_propertyParserState;
    // The payload table. When null, each resolving production refuses, which the Swift grammar
    // reports as a contract violation.
    CSSCalcSwiftFlatPayloads* m_payloads;
#else
    // Same-size stand-ins, so the importer never reaches CSSTokenizer.h. CSSCalcTree+Parser.cpp
    // asserts the size.
    const void* m_rangeStandIn;
    const void* m_symbolsStandIn;
    const void* m_propertyParserStateStandIn;
    const void* m_payloadsStandIn;
#endif
};

// What the parse needs from `ParserState` and `ParserOptions`, flattened.
//
// When `treeCountingAllowed`, `cssCalcMixEnabled`, `anchorAllowed`, `anchorSizeAllowed` or
// `randomAllowed` is clear, its function fails the parse, as in the C++ parser.
struct CSSCalcSwiftParseOptions {
    // The enum rather than its raw value: `init?(rawValue:)` on an imported C++ enum never fails.
    CSS::Category category;
    // When set, a unit needing conversion data fails the parse, as in `parseCalcDimension`.
    bool absoluteLengthUnitsOnly;
    // Whether `ParserOptions::allowedSymbols` is non-empty; when clear, `lookupSymbol` is skipped.
    // Cleared for an `<anchor-side>`, which `consumeAnchor` parses with no symbols.
    bool hasAllowedSymbols;

    // `treeCountingAllowedIn` in CSSCalcTree+Parser.cpp.
    bool treeCountingAllowed;

    bool cssCalcMixEnabled;

    // Separate, because the inset properties allow both while sizing and margin properties allow
    // only `anchor-size()`.
    bool anchorAllowed;
    bool anchorSizeAllowed;

    // `randomAllowedIn` in CSSCalcTree+Parser.cpp. Also false without a `PropertyParserState`,
    // which every `<random-key>` production needs.
    bool randomAllowed;

    // `consumeAnchorFallback`'s `Category::Number` case: a property that forbids it rejects
    // `anchor(top, 0)`.
    bool unitlessZeroLengthAllowed;

    // The top-level function's `CSSValueID`, since the parse is handed only the range inside it.
    // Passing the outer range instead would parse the arguments at depth 1 rather than 0. Ignored
    // when `bareCalcSum` is set.
    uint16_t rootFunctionId;

    // `parseAndSimplifyCalcSum`: a bare `<calc-sum>`, for `calc-size()`'s arguments. The parse
    // starts at `<calc-sum>`, skips no leading whitespace, and need not exhaust the range: it stops
    // at `calc-size()`'s top-level comma, and `CSSCalcSwiftParseResult::consumedTokens` says where.
    bool bareCalcSum;
};

// `Failed` means the input is invalid. `Declined` means the Swift parser handed it back, which a
// caller must not treat as invalid.
enum class CSSCalcSwiftParseOutcome : uint8_t {
    Parsed,
    Failed,
    Declined,
};

// Which uncovered construct made the Swift parser hand the input back. Appended to, never inserted
// into, so that each reason keeps its number.
enum class CSSCalcSwiftParseDeclineReason : uint8_t {
    None,
    MathFunction,
    Symbol,
    TreeCounting,
    // No producer. Kept so that each later reason keeps its number.
    TooManyTokens,
    // No producer: a math-function `calc-mix()` weight goes in the payload table. Kept so that each
    // later reason keeps its number.
    CalcMixWeight,
    // An `anchor()` or `anchor-size()` that `simplify` would evaluate, which needs an original
    // `CSSCalc::Child` a parsed tree does not have.
    AnchorEvaluation,
    // A construction refused because the boundary's contract was broken, not because of the input.
    // No input should produce it.
    ContractViolation,
    // `AnchorEvaluation` for `random()`, which `simplify(Random&)` evaluates through
    // `resolveStyleCoupledValue(const Child&)`.
    RandomEvaluation,
};

struct alignas(8) CSSCalcSwiftParseResult {
    Type type;
    // A `CSSCalcSwiftParseOutcome`.
    uint8_t outcome;
    // A `CSSCalcSwiftParseDeclineReason`.
    uint8_t declineReason;
    bool requiresConversionData;
    // Tokens consumed, for `CSSCalcSwiftParseOptions::bareCalcSum`; meaningful only for `Parsed`.
    // Kept inside the asserted size, clear of the `@_expose(Cxx)` return-struct tail-zeroing hazard
    // (rdar://186742920).
    uint32_t consumedTokens;
};
static_assert(sizeof(CSSCalcSwiftParseResult) == 16);
static_assert(alignof(CSSCalcSwiftParseResult) == 8);


// The alternative `makeNumeric` builds for `unit`, as a `CSSCalcSwiftNodeKind`.
WEBCORE_EXPORT uint8_t cssCalcSwiftLeafKindForUnit(uint16_t unit) noexcept;

// `lookupConstantNumber(id)`: the `<calc-keyword>` constants.
WEBCORE_EXPORT CSSCalcSwiftNumericResult cssCalcSwiftLookupConstantNumber(uint16_t id) noexcept;

// Runs the Swift grammar over the tokens inside a `calc()`, simplifies the result, and constructs it
// into `outRoot`.
//
// `simplify` false leaves the tree as parsed, for a test that compares unsimplified trees.
//
// `propertyParserState` is what the three resolving productions need. With it null, `random()` and
// a math-function `calc-mix()` weight fail the parse.
//
// Returns `Parsed` only when the range was consumed, the root slot filled and the operand stack left
// empty. Anything else leaves `outRoot` untouched.
WEBCORE_EXPORT CSSCalcSwiftParseResult cssCalcSwiftParseIntoChild(const CSSParserTokenRange& innerRange, CSSCalcSwiftParseOptions, const CSSCalcSymbolsAllowed&, const SimplificationOptions&, Child& outRoot, bool simplify = true, CSS::PropertyParserState* = nullptr) noexcept;

} // namespace CSSCalc
} // namespace WebCore
