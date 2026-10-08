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
#include <span>
#include <type_traits>
#include <wtf/Ref.h>
#include <wtf/RefCounted.h>
#include <wtf/SwiftBridging.h>
#include <wtf/TZoneMalloc.h>
#include <wtf/Vector.h>

namespace WTF {
class StringBuilder;
class TextStream;
}

namespace WebCore {

class CSSParserTokenRange;
class CSSCalcSymbolsAllowed;
struct ComputedStyleDependencies;

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

    // A fixed spelling of `length` characters, packed little-endian into two words. Keywords go
    // through `appendValueIDName`.
    WEBCORE_EXPORT void appendCharacters(uint64_t first, uint64_t second, uint8_t length) noexcept;

    WEBCORE_EXPORT void appendNumber(double value, uint8_t unitType) noexcept;

    WEBCORE_EXPORT void appendValueIDName(uint16_t valueID) noexcept;

    WEBCORE_EXPORT void appendPayloadArgument(uint8_t part, uint32_t payload, double weight, bool present) noexcept;

    // The `<random-key>` or `fixed <number>` of a `random()`, and the comma after it.
    WEBCORE_EXPORT void appendRandomSharing(uint32_t payload) noexcept;

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

// `collectComputedStyleDependencies`, fed by a walk of the stored tree. A unit is a node's own, so
// the one table of which unit depends on what stays `CSS::collectComputedStyleDependencies`.
struct SWIFT_SAFE CSSCalcSwiftDependencySink {
    CSSCalcSwiftDependencySink(ComputedStyleDependencies& dependencies LIFETIME_BOUND, const CSSCalcSwiftFlatPayloads* payloads LIFETIME_BOUND) noexcept
        : m_dependencies(&dependencies)
        , m_payloads(payloads)
    {
    }

    WEBCORE_EXPORT void addUnit(uint8_t unitType) const noexcept;
    // A `calc-mix()` weight that is a math function, whose own tree is in the payload.
    WEBCORE_EXPORT void addCalcMixWeight(uint32_t payload) const noexcept;
    WEBCORE_EXPORT void addFunctions(bool siblingFunctions, bool anchorFunctions) const noexcept;

private:
    ComputedStyleDependencies* m_dependencies;
    const CSSCalcSwiftFlatPayloads* m_payloads;
};

// `CSSNumericValue::reifyMathExpression`, fed post-order by a walk of the stored tree. Each call is
// false once an exception is recorded, which ends the walk as the C++'s first exception ends its
// recursion.
struct CSSCalcSwiftNumericValueOperands;

struct SWIFT_SAFE CSSCalcSwiftNumericValueBuilder {
    CSSCalcSwiftNumericValueBuilder(CSSCalcSwiftNumericValueOperands& operands LIFETIME_BOUND) noexcept
        : m_operands(&operands)
    {
    }

    WEBCORE_EXPORT bool pushUnitValue(double value, uint8_t unitType) noexcept;
    // `Sum`, `Product`, `Min`, `Max` over the last `childCount` values, `Negate` and `Invert` over the
    // last one, `Clamp` over the last three. Any other alternative is `UnknownError`.
    WEBCORE_EXPORT bool buildOperation(CSSCalcSwiftAlternative, uint32_t childCount) noexcept;

private:
    CSSCalcSwiftNumericValueOperands* m_operands;
};

// MARK: - Simplification

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

// MARK: - Upcalls

// No payload, or no such node.
static constexpr uint32_t cssCalcSwiftFlatNoNode = UINT32_MAX;
static constexpr uint8_t cssCalcSwiftNoAlternative = UINT8_MAX;

// The upcalls Swift's folds and the evaluator make, over the options and the tree's payload table.
// `SWIFT_SAFE` is unchecked and holds only while every copy stays a parameter of the one walk.
struct SWIFT_SAFE CSSCalcSwiftBuilder {
    CSSCalcSwiftBuilder(const SimplificationOptions& options LIFETIME_BOUND, const CSSCalcSwiftFlatPayloads* payloads LIFETIME_BOUND) noexcept
        : m_options(&options)
        , m_payloads(payloads)
    {
    }

    // The symbol table's value for `simplify(Symbol&)`, as a number. Swift pairs it with the node's
    // unit, not the table's: the table's would fold `Symbol{r, Deg}` under `{r -> 1px}` into a
    // length where `simplify` makes an angle.
    WEBCORE_EXPORT CSSCalcSwiftNumericResult resolveSymbol(uint16_t valueID) const noexcept;

    WEBCORE_EXPORT CSSCalcSwiftNumericResult resolveRelativeLength(double value, uint16_t unitType) const noexcept;

    // `sibling-count()` or `sibling-index()`, which need an element.
    WEBCORE_EXPORT CSSCalcSwiftNumericResult resolveTreeCounting(CSSCalcSwiftAlternative) const noexcept;

    // `evaluateWithoutFallback` for `Anchor`, and its `AnchorSize` counterpart, without the fallback
    // and without marking the property invalid. `valueID` is the node's: the side keyword, or
    // `CSSValueInvalid` when the side is `sideFraction` (the `<percentage>` subtree evaluated, / 100);
    // for `AnchorSize` the dimension, or `CSSValueInvalid` for none.
    WEBCORE_EXPORT CSSCalcSwiftNumericResult resolveAnchor(CSSCalcSwiftAlternative, uint32_t elementNamePayload, uint16_t valueID, double sideFraction) const noexcept;

    WEBCORE_EXPORT CSSCalcSwiftNumericResult resolveCalcMixWeight(double value, bool present, uint32_t payload) const noexcept;

    // Asked separately because `resolveRandomBaseValue` has a side effect.
    WEBCORE_EXPORT bool hasStyleBuilderState() const noexcept;

    // A `random()`'s base value. It inserts into the random cache, so it is asked only where the C++
    // asks it. The sharing is read whole from the payload: `resolveRandomBaseValue` hashes all of it
    // into a `RandomCachingKey`, and a second derivation that disagreed would give one key two values.
    // A `fixed` `Calc` value is evaluated only with `evaluatesFixedCalc`, as
    // `evaluate(const IndirectNode<Random>&)` does; `simplify(Random&)` leaves that node unfolded.
    WEBCORE_EXPORT CSSCalcSwiftNumericResult resolveRandomBaseValue(uint32_t payload, bool evaluatesFixedCalc) const noexcept;

    WEBCORE_EXPORT void markCurrentPropertyInvalidAtComputedValueTime() const noexcept;

private:
    template<typename T> const T* payloadFor(uint32_t index) const noexcept;

    const SimplificationOptions* m_options;
    const CSSCalcSwiftFlatPayloads* m_payloads;
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

    void fillTokenBits(std::span<CSSParserTokenBits> out __attribute__((noescape))) const noexcept;

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

struct alignas(8) CSSCalcSwiftParseResult {
    Type type;
    uint8_t outcome;
    bool requiresConversionData;
    // For `bareCalcSum`, and only for `Parsed`. Kept inside the asserted size, clear of the
    // `@_expose(Cxx)` return-struct tail-zeroing bug (rdar://186742920).
    uint32_t consumedTokens;
};
static_assert(sizeof(CSSCalcSwiftParseResult) == 16);
static_assert(alignof(CSSCalcSwiftParseResult) == 8);

// C++ answers because `makeNumeric` owns the seventy-case unit table.
WEBCORE_EXPORT uint8_t cssCalcSwiftLeafKindForUnit(uint16_t unit) noexcept;


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

// MARK: - `Style::Calculation::Tree`, stored as the Swift tree

#if !defined(__swift__)
// The `SimplificationOptions` fields Swift reads.
CSSCalcSwiftSimplificationOptions swiftSimplificationOptions(const SimplificationOptions&);
#endif

// `toCSS`'s payloads: a `random()`'s fixed base value, as the `Random::SharingFixed` a parsed tree
// holds. `SWIFT_SAFE` holds because it lives on the C++ stack for the one Swift call that takes it
// `inout`, as the ones below do.
struct SWIFT_SAFE StyleCalcSwiftPayloadSink {
    StyleCalcSwiftPayloadSink(CSSCalcSwiftFlatPayloads& payloads LIFETIME_BOUND) noexcept
        : m_payloads(&payloads)
    {
    }

    WEBCORE_EXPORT uint32_t appendRandomFixed(double baseValue) noexcept;

private:
    CSSCalcSwiftFlatPayloads* m_payloads;
};

// `operator<<(TextStream&, const Style::Calculation::Tree&)`, with numbers, operator names and
// `none` written by `TextStream` as the C++ dump writes them.
struct SWIFT_SAFE StyleCalcSwiftDumpSink {
    StyleCalcSwiftDumpSink(WTF::TextStream& ts LIFETIME_BOUND) noexcept
        : m_ts(&ts)
    {
    }

    WEBCORE_EXPORT void appendNumber(double, bool respectingIntegers) noexcept;
    WEBCORE_EXPORT void appendCharacter(uint8_t) noexcept;
    // A `CSSCalc::Operator`.
    WEBCORE_EXPORT void appendOperator(uint8_t) noexcept;
    WEBCORE_EXPORT void appendNone() noexcept;

private:
    WTF::TextStream* m_ts;
};

} // namespace CSSCalc
} // namespace WebCore

// MARK: - The numeric primitive consumers (CSSPropertyParserConsumer+MetaConsumerDefinitions.h)

// What a numeric consumer reads of `CSSPropertyParserOptions` and `PropertyParserState`, as bits.
enum CSSNumericConsumerSwiftFlag : uint8_t {
    CSSNumericConsumerSwiftUnitlessZeroLength = 1 << 0,
    CSSNumericConsumerSwiftAbsoluteLengthUnitsOnly = 1 << 1,
    CSSNumericConsumerSwiftResolvesToFloat = 1 << 2, // the primitive's `ResolvedValueType`, which a clamp rounds through
    CSSNumericConsumerSwiftQuirkyLength = 1 << 3, // `HTMLQuirksMode && CSSProperty::acceptsQuirkyLength(currentProperty)`
    CSSNumericConsumerSwiftUnitlessZeroAngle = 1 << 4,
    CSSNumericConsumerSwiftQuirkyAngle = 1 << 5, // `HTMLQuirksMode && CSSProperty::acceptsQuirkyAngle(currentProperty)`
};

// `packed` is the raw value of the primitive's unit enum, with bit 8 set if the token was accepted. A
// `{ double; uint32_t }` comes back in two registers; a trailing `bool` field is repacked through the stack.
struct CSSNumericConsumerSwiftResult {
    double value;
    uint32_t packed;

    bool accepted() const { return packed & 0x100; }
    uint8_t unit() const { return static_cast<uint8_t>(packed); }
};

// A `<number>`, `<percentage>` or `<dimension>` token for the primitive of `category` (a `CSS::Category`)
// with range `[rangeMin, rangeMax]` and its `CSS::RangeParseTimeBehavior`s. `@c @implementation` in
// CSSCalcSimplificationSwift.swift (SE-0495). Every argument is a scalar, so all of them are passed in registers.
extern "C" CSSNumericConsumerSwiftResult cssConsumeNumericSwift(double value, double rangeMin, double rangeMax, uint8_t category, uint8_t tokenType, uint8_t unitType, uint8_t parserMode, uint8_t minBehavior, uint8_t maxBehavior, uint8_t flags) noexcept;
// The same for `CSS::LengthPercentage<R, float>` with `R` = `CSS::Nonnegative` and `CSS::All`, the two ranges
// of nearly every `<length-percentage>` site. The range is a constant in each, which makes it a leaf.
extern "C" CSSNumericConsumerSwiftResult cssConsumeLengthPercentageNonnegativeSwift(double value, uint8_t tokenType, uint8_t unitType, uint8_t parserMode, uint8_t flags) noexcept;
extern "C" CSSNumericConsumerSwiftResult cssConsumeLengthPercentageAllSwift(double value, uint8_t tokenType, uint8_t unitType, uint8_t parserMode, uint8_t flags) noexcept;
