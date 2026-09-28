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

// Everything the calc Swift sources may see of WebCore. It has its own Clang module and must stay
// self-contained: including CSSCalcTree.h or CSSTokenizer.h here pulls in the PrivateHeaders
// umbrella. Every function must stay `noexcept`, or Swift emits a termination landing pad around
// each call.

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
struct PropertyParserState;
}

namespace CSSCalc {

struct Child;
struct Tree;
struct CSSCalcSwiftStoredRoot;
struct SimplificationOptions;
struct EvaluationOptions;
struct CSSCalcSwiftOperandStack;

// Values a `CalcNode` names by index in its `origin`, which Swift never sees.
struct CSSCalcSwiftFlatPayloads;

// `Node`'s variant alternatives, numbered by `Node::index()`. `Node`'s `Variant<...>` is generated
// from this list, and each pairing is pinned with `WTF::alternativeIndexV`, because
// `init?(rawValue:)` on an imported C++ enum never fails. Split into FIRST and REST because a
// template argument list cannot carry a trailing comma.
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

#define CSS_CALC_SWIFT_COUNT_ALTERNATIVE(name, type) + 1
static constexpr uint8_t numberOfCSSCalcSwiftAlternatives = 0 CSS_CALC_SWIFT_FOR_EACH_ALTERNATIVE(CSS_CALC_SWIFT_COUNT_ALTERNATIVE);
#undef CSS_CALC_SWIFT_COUNT_ALTERNATIVE

// What an operation needs beyond its child subtrees. A field a kind does not carry is zero.
struct CSSCalcSwiftOperationInfo {
    uint16_t valueID;

    // Both false means `auto`.
    bool randomSharingIsKey;
    bool randomSharingIsFixed;
    bool randomKeyHasName;
    bool randomKeyIsElementScoped;
    bool randomKeyHasPropertyScope;

    // When false, the `<anchor-side>` is a `<percentage>` subtree in child 0.
    bool anchorSideIsKeyword;

    bool hasElementName;
    bool hasDimension;
    bool hasFallback;
};

// Numbers are formatted in C++ because CSS number serialization is not Swift's shortest-round-trip
// `Double.description`. `SWIFT_SAFE` is unchecked and holds only while no Swift type stores a sink:
// every Swift signature takes it `inout`.
struct SWIFT_SAFE CSSCalcSwiftSink {
    CSSCalcSwiftSink(WTF::StringBuilder& builder LIFETIME_BOUND, const CSS::SerializationContext& context LIFETIME_BOUND, const CSSCalcSwiftFlatPayloads* payloads LIFETIME_BOUND = nullptr) noexcept
        : m_builder(&builder)
        , m_context(&context)
        , m_payloads(payloads)
    {
    }

    // A `CSSCalcSwiftLiteral`, which this header cannot name because its generated header depends
    // on this one.
    WEBCORE_EXPORT void appendLiteral(uint8_t literal) noexcept;

    WEBCORE_EXPORT void appendNumber(double value, uint8_t unitType) noexcept;

    WEBCORE_EXPORT void appendValueIDName(uint16_t valueID) noexcept;

    WEBCORE_EXPORT void appendPayloadArgument(uint8_t part, uint32_t payload, double weight, bool present) noexcept;

    WEBCORE_EXPORT CSSCalcSwiftOperationInfo randomSharingInfo(uint32_t payload) const noexcept;

private:
    WTF::StringBuilder* m_builder;
    const CSS::SerializationContext* m_context;
    const CSSCalcSwiftFlatPayloads* m_payloads;
};

struct SWIFT_SAFE CSSCalcSwiftPayloadComparer {
    WEBCORE_EXPORT bool equal(uint32_t a, uint32_t b) const noexcept;

#if !defined(__swift__)
    const CSSCalcSwiftFlatPayloads* first;
    const CSSCalcSwiftFlatPayloads* second;
#else
    const void* m_firstStandIn;
    const void* m_secondStandIn;
#endif
};

// MARK: - Simplification

struct CSSCalcSwiftLeaf {
    double value;
    uint16_t unitType;
    // A `CSSCalcSwiftAlternative`, needed because `unitType` cannot distinguish `Percentage`.
    uint8_t alternative;
    uint8_t percentHint;
    uint16_t valueID;
};
static_assert(sizeof(CSSCalcSwiftLeaf) == 16);

struct CSSCalcSwiftNumericResult {
    double value;
    uint16_t unitType;
    bool resolved;
    CSSCalcSwiftAlternative alternative;

    // Replace an `anchor()` or `anchor-size()` by its fallback. Exclusive with `resolved`.
    bool substituteFallback;
};

static_assert(sizeof(CSSCalcSwiftNumericResult) == 16);

struct CSSCalcSwiftSimplificationOptions {
    double rangeMinimum;
    double rangeMaximum;
    uint8_t category;
    bool allowZeroValueLengthRemovalFromSum;
    bool hasConversionData;
    bool percentageResolveToDimension;
};

// MARK: - Building the result tree

// No payload, or no such node.
static constexpr uint32_t cssCalcSwiftFlatNoNode = UINT32_MAX;
static constexpr uint8_t cssCalcSwiftNoAlternative = UINT8_MAX;

// An operand stack that Swift fills post-order, so that no Swift container holds a `Child`.
// `SWIFT_SAFE` is unchecked and holds only while every copy stays a parameter of the one recursion,
// and because the stack is fresh storage the input tree cannot reach.
struct SWIFT_SAFE CSSCalcSwiftBuilder {
    CSSCalcSwiftBuilder(CSSCalcSwiftOperandStack& operands LIFETIME_BOUND, const SimplificationOptions& options LIFETIME_BOUND) noexcept
        : m_operands(&operands)
        , m_options(&options)
    {
    }

    // `isRoot` constructs the node into the root slot, if there is one, rather than pushing it.
    // Each `bool` return is false for a contract violation.

    WEBCORE_EXPORT bool pushLeaf(CSSCalcSwiftLeaf, bool isRoot = false) noexcept;

    // `payloadIndex` names a `Calc` weight, which no `double` can carry.
    WEBCORE_EXPORT bool pushCalcMixItemWeight(double weight, bool present, uint32_t payloadIndex = cssCalcSwiftFlatNoNode) noexcept;

    // `Type` is supplied rather than recomputed because `copyAndSimplify` keeps a node's type when
    // its kind does not change: `calc((2 / 3px) * 4px)` keeps its parse-time type, where `toType` of
    // the surviving `Product{6px, 4px}` is px^2. `noneMask` bit 0 means the minimum bound of
    // `clamp()` is `none`, bit 1 the maximum; the `none` bound pushes no operand.
    WEBCORE_EXPORT bool buildOperation(CSSCalcSwiftAlternative, uint32_t childCount, Type, bool isRoot = false, uint8_t noneMask = 0) noexcept;

    // `valueID` `CSSValueInvalid` means no dimension for `AnchorSize`, and for `Anchor` that the side
    // is the `<percentage>` subtree in slot 0.
    WEBCORE_EXPORT bool buildAnchor(CSSCalcSwiftAlternative, uint32_t childCount, Type, bool isRoot, uint16_t valueID, uint32_t elementNamePayload) noexcept;

    // The sharing is carried whole: `resolveRandomBaseValue` hashes all of it into a
    // `RandomCachingKey`, and a second derivation that disagreed would give one key two values.
    WEBCORE_EXPORT bool buildRandom(uint32_t childCount, Type, bool isRoot, uint32_t sharingPayload) noexcept;

    // `simplify(Symbol&)`. The unit is the node's, not the table's: the table's would fold
    // `Symbol{r, Deg}` under `{r -> 1px}` into a length where `simplify` makes an angle.
    WEBCORE_EXPORT CSSCalcSwiftNumericResult resolveSymbol(uint16_t valueID, uint16_t unit) const noexcept;

    WEBCORE_EXPORT CSSCalcSwiftNumericResult resolveRelativeLength(double value, uint16_t unitType) const noexcept;

    // May mark the property invalid at computed-value time. The mark has no clear, so a repeated
    // call is harmless.
    WEBCORE_EXPORT CSSCalcSwiftNumericResult resolveStyleCoupledValue(const Child&) const noexcept;

    WEBCORE_EXPORT CSSCalcSwiftNumericResult resolveStyleCoupledValueOfTop() noexcept;

    WEBCORE_EXPORT CSSCalcSwiftNumericResult resolveCalcMixWeight(double value, bool present, uint32_t payload) const noexcept;

    // Asked separately because `resolveRandomBaseValueForEvaluation` has a side effect.
    WEBCORE_EXPORT bool hasStyleBuilderState() const noexcept;

    // Unlike `resolveStyleCoupledValue`, this evaluates a `fixed` `Calc` value. It inserts into the
    // random cache, so it is asked only where `evaluate(const IndirectNode<Random>&)` asks it.
    WEBCORE_EXPORT CSSCalcSwiftNumericResult resolveRandomBaseValueForEvaluation(uint32_t payload) const noexcept;

    WEBCORE_EXPORT void markCurrentPropertyInvalidAtComputedValueTime() const noexcept;

private:
    template<typename T> const T* payloadFor(uint32_t index) const noexcept;

    CSSCalcSwiftOperandStack* m_operands;
    const SimplificationOptions* m_options;
};

// MARK: - Parsing

// The grammar reads copies of each token's `CSSParserTokenBits`. It never reads a copy's value
// slot, which points into the stylesheet text.

WEBCORE_EXPORT bool cssCalcSwiftUnitNeedsConversionData(uint8_t unit) noexcept;
// A math function the Swift grammar does not parse is handed back to the C++ parser.
WEBCORE_EXPORT bool cssCalcSwiftIsCalcFunction(uint16_t functionId) noexcept;

struct CSSCalcSwiftConsumedPayload {
    uint32_t nextIndex;
    uint32_t payloadIndex;
    bool consumed;
};
static_assert(sizeof(CSSCalcSwiftConsumedPayload) == 12);

struct CSSCalcSwiftSymbolResult {
    uint16_t unitType;
    bool resolved;
    bool needsConversionData;
};
static_assert(sizeof(CSSCalcSwiftSymbolResult) == 4);

// Swift copies the tokens into a buffer it owns because it cannot receive a bounds-carrying view of
// the range (rdar://186723514). `SWIFT_SAFE` is unchecked over the range's `std::span`, and holds
// because the cursor lives on the C++ stack for the one Swift call that takes it `noescape`.
struct SWIFT_SAFE CSSCalcSwiftParseCursor {
    // Includes whitespace tokens, because the grammar looks behind one token.
    uint32_t tokenCount() const noexcept;

    void fillTokenBits(CSSParserTokenBits *__counted_by(count) out __attribute__((noescape)), uint32_t count) const noexcept;

    uint16_t keywordId(uint32_t index) const noexcept;

    CSSCalcSwiftSymbolResult lookupSymbol(uint16_t valueID) const noexcept;

    // `consumeRandom`'s `<random-key>` half (`CSSCalcTree+Parser.cpp:786`-`:808`), resolved into the
    // payload table. It stays in C++ because a key can hold an ident, a property name or a nested
    // `calc()`, none of which the token fields carry. Swift calls it before the arguments, as
    // `consumeRandom` does, so `cssRandomFunctionCount` is read and incremented in source order.
    CSSCalcSwiftConsumedPayload consumeRandomKey(uint32_t index) const noexcept;

    uint32_t randomFunctionCount() const noexcept;
    void setRandomFunctionCount(uint32_t) const noexcept;

    CSSCalcSwiftConsumedPayload consumeCalcMixWeightAt(uint32_t index) const noexcept;

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
    // Non-const because `consumeRandomKey` increments `cssRandomFunctionCount`; the member functions
    // stay `const` so that Swift imports them as non-mutating.
    CSS::PropertyParserState* m_propertyParserState;
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

struct CSSCalcSwiftParseOptions {
    // The enum rather than its raw value: `init?(rawValue:)` on an imported C++ enum never fails.
    CSS::Category category;
    bool absoluteLengthUnitsOnly;
    bool hasAllowedSymbols;

    bool treeCountingAllowed;

    bool cssCalcMixEnabled;

    bool anchorAllowed;
    bool anchorSizeAllowed;

    bool randomAllowed;

    bool unitlessZeroLengthAllowed;

    // The parse is handed only the range inside the top-level function, so that its arguments are
    // at depth 0. Ignored when `bareCalcSum` is set.
    uint16_t rootFunctionId;

    // A bare `<calc-sum>`, for `calc-size()`'s arguments. The parse skips no leading whitespace and
    // stops at a top-level comma; `CSSCalcSwiftParseResult::consumedTokens` says where.
    bool bareCalcSum;
};

// `Declined` means the Swift parser handed the input back, which a caller must not treat as invalid.
enum class CSSCalcSwiftParseOutcome : uint8_t {
    Parsed,
    Failed,
    Declined,
};

// Why the Swift parser handed the input back. Appended to, never inserted into, so that each reason
// keeps its number.
enum class CSSCalcSwiftParseDeclineReason : uint8_t {
    None,
    MathFunction,
    Symbol,
    TreeCounting,
    // No producer.
    TooManyTokens,
    // No producer.
    CalcMixWeight,
    // An `anchor()` or `anchor-size()` that `simplify` would evaluate, which needs the original
    // `CSSCalc::Child`.
    AnchorEvaluation,
    // No input should produce it.
    ContractViolation,
    RandomEvaluation,
};

struct alignas(8) CSSCalcSwiftParseResult {
    Type type;
    uint8_t outcome;
    uint8_t declineReason;
    bool requiresConversionData;
    // For `bareCalcSum`, and only for `Parsed`. Kept inside the asserted size, clear of the
    // `@_expose(Cxx)` return-struct tail-zeroing bug (rdar://186742920).
    uint32_t consumedTokens;
};
static_assert(sizeof(CSSCalcSwiftParseResult) == 16);
static_assert(alignof(CSSCalcSwiftParseResult) == 8);

// C++ answers because `makeNumeric` owns the seventy-case unit table.
WEBCORE_EXPORT uint8_t cssCalcSwiftLeafKindForUnit(uint16_t unit) noexcept;

WEBCORE_EXPORT CSSCalcSwiftNumericResult cssCalcSwiftLookupConstantNumber(uint16_t id) noexcept;

// For `CSSCalcSwiftStoredRoot`'s parsing constructor. One argument so that
// `std::optional<Tree>::emplace` can aggregate-initialise a `Tree` from it, building the stored root
// in its final slot: a C++ move of the printed class for a Swift class is a retain and a release.
// The root means nothing unless `result`'s outcome is `Parsed`.
#if !defined(__swift__)
struct CSSCalcSwiftParseRequest {
    const CSSParserTokenRange& tokens;
    CSSCalcSwiftParseOptions parseOptions;
    const CSSCalcSymbolsAllowed& symbols;
    const SimplificationOptions& options;
    CSS::PropertyParserState& propertyParserState;
    CSSCalcSwiftParseResult& result;
};
#endif

// MARK: - Conversion to `Style::Calculation::Tree`

struct CSSCalcSwiftStyleOperands;

// Filled post-order as `CSSCalcSwiftBuilder` is. `SWIFT_SAFE` holds because it lives on the C++
// stack for the one Swift call that takes it `inout`.
struct SWIFT_SAFE CSSCalcSwiftStyleBuilder {
    CSSCalcSwiftStyleBuilder(CSSCalcSwiftStyleOperands& operands LIFETIME_BOUND, const SimplificationOptions& options LIFETIME_BOUND, const CSSCalcSwiftFlatPayloads* payloads LIFETIME_BOUND) noexcept
        : m_operands(&operands)
        , m_options(&options)
        , m_payloads(payloads)
    {
    }

    WEBCORE_EXPORT void pushNumber(double) noexcept;
    WEBCORE_EXPORT void pushPercentage(double) noexcept;
    WEBCORE_EXPORT void pushCanonicalDimension(double, uint16_t unitType) noexcept;
    WEBCORE_EXPORT void pushSize() noexcept;

    // Pushed before the arguments are converted, the order in which the C++ conversion fills the
    // random cache.
    WEBCORE_EXPORT void pushRandomBaseValue(uint32_t payload) noexcept;

    WEBCORE_EXPORT void pushCalcMixItemWeight(double value, bool present, uint32_t payload) noexcept;

    WEBCORE_EXPORT bool buildOperation(CSSCalcSwiftAlternative, uint32_t childCount, uint8_t noneMask = 0) noexcept;

private:
    CSSCalcSwiftStyleOperands* m_operands;
    const SimplificationOptions* m_options;
    const CSSCalcSwiftFlatPayloads* m_payloads;
};

} // namespace CSSCalc
} // namespace WebCore
