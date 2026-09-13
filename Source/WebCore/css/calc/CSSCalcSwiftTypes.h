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
// around each call to it. Anything added here needs a call graph that is C++ throughout, with no
// Objective-C frame that could `@throw` past it.

#pragma once

#include <cstddef>
#include <cstdint>
#include <type_traits>
#include <WebCore/CSSCalcType.h>
#include <WebCore/CSSParserTokenBits.h>
#include <WebCore/CSSUnitType.h>
#include <WebCore/PlatformExportMacros.h>
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

namespace CSS {
struct SerializationContext;
}

namespace CSSCalc {

struct Child;
struct SimplificationOptions;

// Defined in CSSCalcTree+Simplification.cpp, because naming what it is -- a `WTF::Vector<Child>` --
// would need wtf/Vector.h here.
struct CSSCalcSwiftOperandStack;


// The shape of a node's serialization, not its operation: several operations share a kind, and
// `CSSCalcSwiftNodeInfo::valueID` carries the name, so the operator name table stays in C++.
// `Operation` is an operation this boundary has not been taught, and falls back to the C++ path.
//
// New cases are appended, never inserted. `CSSCalcSwiftSerializationResult::kindMask` is
// `1 << rawValue`, so inserting a case would silently relabel every existing coverage count.
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
    // `clamp()` with one bound holding the keyword `none` -- the one argument in the tree that is
    // not a child node, since `forAllChildNodes` skips a `ChildOrNone` holding `none`. Without
    // these, `clamp(none, VAL, MAX)` would serialize as `clamp(VAL, MAX)`. Two kinds rather than a
    // flag, so that an exhaustive `switch` is forced to decide. `clamp(none, VAL, none)` needs no
    // kind, because simplification rewrites it to `VAL`.
    ClampWithNoneMinimum,
    ClampWithNoneMaximum,
    // The four operations whose arguments are not a plain list of calculation trees; see
    // `CSSCalcSwiftOperationInfo`. `childCount` counts `Child`s only, so `random()`'s
    // `<random-key>`, `calc-mix()`'s per-item weights and `anchor()`'s keyword `<anchor-side>` are
    // not in it.
    RandomFunction,
    CalcMixFunction,
    AnchorFunction,
    AnchorSizeFunction,
};

// Which of `CSSCalc::Node`'s variant alternatives a node is, exactly, for a rewriter that must
// dispatch on the operation rather than on the serialization shape. The numbering is the variant's
// own alternative index, read with `Node::index()`, and this list is the only copy: `Node`'s
// `Variant<...>` is generated from it in CSSCalcTree.h, and each pairing is pinned with
// `WTF::alternativeIndexV<T, Node>` in CSSCalcTree+Serialization.cpp because `init?(rawValue:)` on
// an imported C++ enum never fails.
//
// Split into FIRST and REST because a `Variant<...>` template argument list cannot carry a trailing
// comma.
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

// Counted from the list rather than read off the last enumerator, and held equal to
// `WTF::VariantSizeV<Node>` in CSSCalcTree+Serialization.cpp.
#define CSS_CALC_SWIFT_COUNT_ALTERNATIVE(name, type) + 1
static constexpr uint8_t numberOfCSSCalcSwiftAlternatives = 0 CSS_CALC_SWIFT_FOR_EACH_ALTERNATIVE(CSS_CALC_SWIFT_COUNT_ALTERNATIVE);
#undef CSS_CALC_SWIFT_COUNT_ALTERNATIVE

// The operations grouped by slot shape, so that `buildOperation` and `rebuildFrom` serve each group
// with one spelling.
#define CSS_CALC_SWIFT_FOR_EACH_UNARY_MATH_FUNCTION(macro) \
    macro(Deg2Rad) \
    macro(Sin) macro(Cos) macro(Tan) \
    macro(Asin) macro(Acos) macro(Atan) \
    macro(Sqrt) macro(Exp) macro(Abs) macro(Sign)

// One `Child` and one `std::optional<Child>`, whose two states are separated by the operand count.
#define CSS_CALC_SWIFT_FOR_EACH_OPTIONAL_SECOND_MATH_FUNCTION(macro) \
    macro(RoundNearest) macro(RoundUp) macro(RoundDown) macro(RoundToZero) \
    macro(Log)

// A fixed number of plain `Child`s, which the variant declaration already states.
#define CSS_CALC_SWIFT_FOR_EACH_FIXED_ARITY_MATH_FUNCTION(macro) \
    macro(Mod) macro(Rem) macro(Atan2) macro(Pow) \
    macro(Progress) macro(ProgressNoClamp)

// Everything the four operation kinds need that is neither a child subtree nor text. Each field is
// meaningful only for the kinds that carry it, and the rest are inert rather than indeterminate.
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

    // When false, the `<anchor-side>` is a `<percentage>` subtree occupying child 0, which is what
    // makes the fallback's index depend on this.
    bool anchorSideIsKeyword;

    bool hasElementName;
    bool hasDimension;
    // Redundant with `childCount`, and kept so that a mismatch between the two is reported as a
    // contract violation rather than writing an argument in the wrong position.
    bool hasFallback;
};

// One `calc-mix()` item's weight. Three states in two bools because the two questions are asked
// separately: the spec's step 1 counts the absent ones, and `simplify(CalcMix&)`'s `canNormalize`
// guard rejects the `Calc` ones. `value` is zero, not indeterminate, in the other two states, and is
// not a stand-in for either, since a `Calc` weight can evaluate to anything.
struct CSSCalcSwiftCalcMixWeight {
    double value;
    bool present;
    bool isRaw;
};

static_assert(sizeof(CSSCalcSwiftCalcMixWeight) == 16);

// One node, described. Each field is meaningful only for the kinds that carry it, and the rest are
// inert (`CSSValueInvalid`, `CSSUnitType::Unknown`) rather than indeterminate.
struct CSSCalcSwiftNodeInfo {
    double numericValue;
    // Counts through `ChildOrNone` and `std::optional<Child>` exactly as `forAllChildNodes` does. A
    // `ChildOrNone` holding `none` is not counted, which is why the two `ClampWithNone...` kinds
    // exist: the count stays the number of subtrees to walk and the kind says where the keyword
    // goes.
    uint32_t childCount;
    uint16_t valueID;
    // `toCSSUnit(node)` for a numeric leaf, and `Symbol::unit` for a `Symbol` -- not the symbol
    // table's unit. `simplify(Symbol&)` takes the value from `CSSCalcSymbolTable` and the unit from
    // the node, and those are two independently populated `HashMap`s: reading the unit off the
    // table's answer would fold `Symbol{r, Deg}` under an `{r -> 1px}` table into a length where the
    // C++ makes an angle.
    uint8_t unitType;
    CSSCalcSwiftNodeKind kind;
    // `Type::PercentHint`'s underlying value, 0 for none. Needed because
    // `makeChildWithValueBasedOn(value, const Percentage&)` carries `hint` onto the result.
    uint8_t percentHint;
    CSSCalcSwiftAlternative alternative;
};

// MARK: - Reading a node
//
// A `const Child&` parameter is safe to Swift where a `const Child&` return is not -- only the
// return position imports as `UnsafePointer`. That is what lets `Child` stay incomplete here.
WEBCORE_EXPORT CSSCalcSwiftNodeInfo swiftNodeInfo(const Child&) noexcept;
WEBCORE_EXPORT CSSCalcSwiftOperationInfo swiftOperationInfo(const Child&) noexcept;
WEBCORE_EXPORT CSSCalcSwiftCalcMixWeight swiftCalcMixItemWeight(const Child&, uint32_t index) noexcept;

// Where the serialization output goes. Number formatting must stay an upcall: Swift's
// `Double.description` is shortest-round-trip and CSS number serialization is a different
// algorithm, so a Swift reimplementation would diverge on subnormals and 17-significant-digit
// values.
//
// `SWIFT_SAFE` is an unchecked assertion that the two raw pointers below are safely encapsulated,
// and it is what keeps every Swift use of this type free of an `unsafe` marker. It holds only while
// no Swift type declares a stored property of this type: every Swift signature naming it takes it
// `inout`, and an `inout` argument cannot be captured by an escaping closure.
struct SWIFT_SAFE CSSCalcSwiftSink {
    CSSCalcSwiftSink(WTF::StringBuilder& builder [[clang::lifetimebound]], const CSS::SerializationContext& context [[clang::lifetimebound]]) noexcept
        : m_builder(&builder)
        , m_context(&context)
    {
    }

    // One entry for every fixed spelling, selected by `CSSCalcSwiftLiteral`, so that no text crosses
    // the boundary and there is exactly one copy of every CSS literal in the program. `uint8_t`
    // rather than the imported enum type, because this header is what the generated header is
    // generated from and cannot see the Swift enum's C name.
    WEBCORE_EXPORT void appendLiteral(uint8_t literal) noexcept;

    WEBCORE_EXPORT void appendNumber(double value, uint8_t unitType) noexcept;

    // `nameLiteralForSerialization(CSSValueID)`. C++ owns the table, which is generated and must not
    // be transcribed.
    WEBCORE_EXPORT void appendValueIDName(uint16_t valueID) noexcept;

    // Arguments that are CSS values rather than calculation trees. Routing them through
    // `appendNumber` would mean deciding in Swift that they are plain doubles in a known unit, a
    // claim about types Swift cannot see.
    WEBCORE_EXPORT void appendOperationArgument(const Child&, uint8_t part, uint32_t index) noexcept;

private:
    WTF::StringBuilder* m_builder;
    const CSS::SerializationContext* m_context;
};

// What the serialization walk did. `nodeCount` and `kindMask` make the walk observable: a fallback
// to the C++ serializer is otherwise invisible, since it reads as parity by comparing the C++
// against itself.
struct CSSCalcSwiftSerializationResult {
    // Bit `1 << rawValue` for each CSSCalcSwiftNodeKind the walk stood on.
    uint32_t kindMask;
    uint32_t nodeCount;
    // 0 = serialized, 1 = declined. Not a `bool`, so a third outcome is not an ABI change; the
    // numbering is pinned by static_assert against the Swift enum.
    uint8_t outcome;
};

// MARK: - The Swift calc simplification path (CSSCalcSimplificationSwift.swift)
//
// No operation kind crosses in the construction direction. The output node's kind is, with one
// exception, the input node's kind, so `rebuildFrom` recovers it from the original node's variant
// tag. The exception is `clamp()` becoming `min()` or `max()`, which goes through `buildOperation`.

// A numeric leaf to build. `CanonicalDimension::Dimension` is not carried, because `makeNumeric`
// recovers it from `unitType` and is the same function that classifies a `CSSUnitType` for every
// other producer in the tree.
struct CSSCalcSwiftLeaf {
    double value;
    uint16_t unitType;
    // A `CSSCalcSwiftNodeKind`, restricted to the four numeric leaves. It selects the alternative
    // for the one case `unitType` cannot answer, `Percentage`.
    uint8_t kind;
    uint8_t percentHint;
};

// A `double` and a `CSSUnitType`, or nothing: one type for both of the builder's lookups.
struct CSSCalcSwiftNumericResult {
    double value;
    // For `resolveSymbol` this is `toCSSUnit` of the leaf `makeNumeric` built, not the unit that was
    // asked about, so that a round trip back through `pushLeaf` lands on the same alternative.
    uint16_t unitType;
    // False means "no answer", a normal outcome rather than an error: an unresolved `<calc-keyword>`
    // and a `1em` with no conversion data both stay as they are.
    bool resolved;
    // Reported rather than recomputed, so that `makeNumeric`'s seventy-case unit table stays out of
    // Swift.
    CSSCalcSwiftAlternative alternative;

    // A third state, needed because `resolved == false` is ambiguous for `anchor()` and
    // `anchor-size()` alone. With no conversion data or no builder state the node is rebuilt with
    // its simplified fallback still on it; when the evaluation answered nothing the node is replaced
    // by its fallback, or the property is marked invalid at computed-value time if it had none.
    // Mutually exclusive with `resolved`.
    bool substituteFallback;
};

static_assert(sizeof(CSSCalcSwiftNumericResult) == 16);

// The parts of `CSSCalc::SimplificationOptions` Swift reads, each reduced to a trivial type.
struct CSSCalcSwiftSimplificationOptions {
    double rangeMinimum;
    double rangeMaximum;
    // `CSS::Category`'s underlying value. Carried for completeness; nothing reads it yet.
    uint8_t category;
    bool allowZeroValueLengthRemovalFromSum;
    bool hasConversionData;
    // `percentageResolveToDimension(options)`, precomputed so that its eleven-case `switch` over
    // `CSS::Category` does not need a second copy in Swift.
    bool percentageResolveToDimension;
};

// MARK: - The Swift calc flat tree

// One node of the flat tree, in the form Swift builds and reads. Declared in C++ rather than in
// Swift because `PrintAsClang` exports even a `@frozen`, `BitwiseCopyable` Swift struct as a
// non-trivially-copyable C++ class that routes copies through the value witness table
// (rdar://186742920), and such a type cannot be a `WTF::Vector` element. Field order is the Swift
// declaration's, so no conversion exists.
//
// The size assert is load-bearing: an `@_expose(Cxx)` Swift function returning a struct whose size
// leaves a tail of 3, 5, 6 or 7 bytes after the first eight silently zeroes that tail
// (rdar://186742920). 40 is outside that range, and the assert makes a later field addition that
// re-enters it a build failure rather than a wrong stylesheet.
struct alignas(8) CSSCalcSwiftFlatNode {
    double value;
    // Carried rather than recomputed: a node whose children simplified but whose kind did not change
    // keeps its type, which is what `copyAndSimplify` does.
    Type type;
    uint32_t firstChild;
    uint32_t nextSibling;
    uint32_t childCount;
    // The pre-order index this node had when an existing tree was flattened; on a parsed `Anchor`
    // or `AnchorSize`, the `<anchor-element>`'s token index; the no-node sentinel otherwise.
    uint32_t origin;
    uint16_t valueID;
    uint8_t unitType;
    CSSCalcSwiftAlternative alternative;
    uint8_t percentHint;
    // `CalcFlatNodeFlags` in the Swift file. Seven of the eight bits are used.
    uint8_t flags;
};
static_assert(sizeof(CSSCalcSwiftFlatNode) == 40);
static_assert(sizeof(CSSCalcSwiftFlatNode) % 8 == 0, "a tail of 3, 5, 6 or 7 bytes after the first eight is the hazard (rdar://186742920)");
static_assert(alignof(CSSCalcSwiftFlatNode) == 8);
static_assert(std::is_trivially_copyable_v<CSSCalcSwiftFlatNode>);

// The end-of-list sentinel and the "no such node" answer. It cannot collide with a real index: a
// `Child` is 24 bytes, so a tree of 2^32 nodes would need 96 GB.
static constexpr uint32_t cssCalcSwiftFlatNoNode = UINT32_MAX;

// Named once so that the parse's local, the boundary signatures and `Tree`'s member cannot drift.
using CSSCalcSwiftFlatNodeVector = Vector<CSSCalcSwiftFlatNode>;

// Where the simplification output goes: an operand stack, not a node factory. Swift walks the tree
// post-order and pushes each finished subtree; a parent then says how many operands it consumes and
// gets one back. That is what keeps `~Escapable` out of the picture, since no Swift container ever
// holds a `Child`.
//
// `SWIFT_SAFE` is an unchecked assertion, as on `CSSCalcSwiftSink`. Unlike that one, this type is
// also taken by value, so copies of `m_operands` exist; the assertion holds only while every such
// copy stays a parameter travelling down the same recursion. The `inout` builder is held across
// borrows of the input tree, which is sound because the operand stack and root slot are freshly
// constructed C++ storage, not reachable from that tree.
struct SWIFT_SAFE CSSCalcSwiftBuilder {
    CSSCalcSwiftBuilder(CSSCalcSwiftOperandStack& operands [[clang::lifetimebound]], const SimplificationOptions& options [[clang::lifetimebound]]) noexcept
        : m_operands(&operands)
        , m_options(&options)
    {
    }

    // `isRoot` on every construction entry below is the whole of the boundary's knowledge of where
    // the finished tree goes. Set, the node is constructed straight into the `Tree` the caller of
    // `copyAndSimplify` asked for; clear, it goes on the operand stack. A `true` with no root slot
    // provided still pushes.

    // Returns false for a `kind` outside the four numeric leaves and the two tree-counting ones,
    // which is a contract violation rather than an input that can be met.
    WEBCORE_EXPORT bool pushLeaf(CSSCalcSwiftLeaf, bool isRoot = false) noexcept;

    // Deep-copy an input subtree and push it. Routes to `CSSCalc::copy(const Child&)`, which is what
    // the C++ path's own `copyAndSimplifyChildren` bottoms out in, so the two cannot disagree about
    // what a copy is.
    WEBCORE_EXPORT void pushCopyOf(const Child&, bool isRoot = false) noexcept;

    // Pop `childCount` operands and push back one node of `original`'s own kind, recovering the
    // operation from `original`'s variant tag so that no operation is named on the boundary. A
    // `Children`-slotted operation takes all `childCount` operands, which is what lets the arity
    // change; every other slot takes one operand or none.
    //
    // Returns false for a contract violation: too few operands, a mismatched arity, a leaf, or an
    // `Anchor`/`AnchorSize`, both of which declare `tuple_size` 0 (webkit.org/b/280798) so that
    // generic reconstruction would build them empty.
    WEBCORE_EXPORT bool rebuildFrom(const Child& original, uint32_t childCount, bool isRoot = false) noexcept;

    // Push the weight the next `calc-mix()` item pushed as an operand is to carry. `rebuildFrom`
    // consumes the top `childCount` of both stacks, so operands are pushed first and weights after.
    //
    // `replaceWeight` clear means "the weight of original item `origin`, unchanged", which is the
    // only way `simplify(CalcMix&)`'s `!canNormalize` path is expressible: it drops items while
    // leaving survivors' weights alone, and a survivor can hold a `Calc` weight that cannot be
    // reproduced. Addressed by index, because pairing by position is wrong once items can be
    // dropped.
    WEBCORE_EXPORT void pushCalcMixItemWeight(uint32_t origin, double weight, bool replaceWeight) noexcept;

    // Pop `childCount` operands and push a fresh node of the named `alternative`, for the flat tree,
    // which has no original to recover an operation from. Also serves `clamp(none, VAL, MAX)`
    // rewriting to `min(VAL, MAX)` and `clamp(MIN, VAL, none)` to `max(MIN, VAL)`.
    //
    // `Type` is supplied rather than recomputed, and that is the one type rule: the C++ path keeps
    // the original type when it rebuilds a node whose kind did not change, so recomputing here
    // diverges. `calc((2 / 3px) * 4px)` simplifies to a surviving `Product{6px, 4px}` where the C++
    // keeps the parse-time type and a fresh `toType` computes px^2.
    //
    // `noneMask` bit 0 set means the minimum bound is the keyword `none`, bit 1 the maximum. The
    // operand count cannot carry it, since `clamp(none, V, M)` and `clamp(M, V, none)` both push two
    // operands.
    //
    // An alternative outside the `Children`-slotted and unary sets, a mismatched arity, or too few
    // operands is a contract violation and returns false without touching the stack.
    WEBCORE_EXPORT bool buildOperation(CSSCalcSwiftAlternative, uint32_t childCount, Type, bool isRoot = false, uint8_t noneMask = 0) noexcept;

    // Pop the subtree slots of an `anchor()` or an `anchor-size()` and push the finished node.
    //
    // The element name crosses as a token index, not as a string: Swift cannot see a token's text, so
    // this entry materialises the `CSS::CustomIdent` from `peek(elementNameToken)`, the same one
    // token `consumeUnresolvedDashedIdent` reads through the same `toAtomString()`.
    // `cssCalcSwiftFlatNoNode` means no element name.
    //
    // `CSSValueInvalid` in `valueID` carries two different absent answers, disjoint by alternative:
    // for an `AnchorSize` the dimension is `std::nullopt`, and for an `Anchor` -- whose side is not
    // optional -- the side is the `<percentage>` subtree in slot 0. The slot layout is derived from
    // that rather than sent.
    WEBCORE_EXPORT bool buildAnchor(CSSCalcSwiftAlternative, uint32_t childCount, Type, bool isRoot, uint16_t valueID, uint32_t elementNameToken) noexcept;

    // Drop every operand, for `cssCalcSwiftParseIntoChild`'s failure and contract-violation paths: a
    // descent that stops half way leaves operands behind. Not inline, because
    // `CSSCalcSwiftOperandStack` is forward-declared here.
    WEBCORE_EXPORT void clearOperands() noexcept;

    // Store the flat tree in one crossing. `__counted_by` plus `noescape` is what makes this import
    // as a single `Span<CSSCalcSwiftFlatNode>` with no `unsafe` marker; either annotation alone gives
    // an `UnsafeBufferPointer` or a pointer and a count as two arguments, and neither failure names
    // the missing annotation.
    //
    // A caller that asked for no flat tree gets `nodeCount` back unchanged, because "there was
    // nowhere to put it" is not a boundary failure.
    WEBCORE_EXPORT size_t takeFlatNodes(const CSSCalcSwiftFlatNode* __counted_by(nodeCount) nodes __attribute__((noescape)), size_t nodeCount, uint32_t rootIndex) noexcept;

    // Read the flat tree back per element by value, because Swift cannot receive a bounds-carrying
    // view at all (rdar://186723514). Out of range yields a zeroed node whose `firstChild` is the
    // no-node sentinel, so a walk that runs off the end terminates rather than reading adjacent
    // memory.
    WEBCORE_EXPORT uint32_t flatNodeCount() const noexcept;
    WEBCORE_EXPORT CSSCalcSwiftFlatNode flatNodeAt(uint32_t index) const noexcept;

    // `simplify(Symbol&)` in full: `makeNumeric(options.symbolTable.get(id)->value, unit)`. The unit
    // crosses as well as the value, and it is the symbol node's rather than the table's; see
    // `CSSCalcSwiftNodeInfo::unitType`.
    WEBCORE_EXPORT CSSCalcSwiftNumericResult resolveSymbol(uint16_t valueID, uint16_t unit) const noexcept;

    // `canonicalize`'s `tryMakeCanonical`, for the font-, viewport- and container-relative lengths,
    // which need `CSSToLengthConversionData`. The membership set exists exactly once, here: the
    // `switch` in Swift names the units it decides itself and this upcall is its `default` case.
    WEBCORE_EXPORT CSSCalcSwiftNumericResult resolveRelativeLength(double value, uint16_t unitType) const noexcept;

    // The only place `Style::BuilderState` reaches this boundary. Covers `sibling-count()`,
    // `sibling-index()`, `random()`, `anchor()` and `anchor-size()`, none of which reduces to a POD.
    // One entry for five operations with no selector, because C++ recovers the operation from the
    // node's own variant tag.
    //
    // `resolved == false` is exactly the C++'s `std::nullopt`, and the node is copied through
    // unchanged. The tree-counting and `random()` answers are a plain `<number>`; the two anchor
    // answers are a `CanonicalDimension` length, and they alone use `substituteFallback`.
    //
    // The invalid-at-computed-value-time mark is set here because
    // `setCurrentPropertyInvalidAtComputedValueTime()` is not reachable from Swift. It is monotone
    // with no public clear, so a repeated call cannot be distinguished from a single one, which is
    // what makes it safe on a path `fold` may re-enter.
    //
    // The `<random-key>` must not become a POD: `resolveRandomBaseValue` hashes the whole of
    // `Random::Sharing` into a `RandomCachingKey`, and two hashings that disagreed would hand the
    // same key two different `random()` values.
    WEBCORE_EXPORT CSSCalcSwiftNumericResult resolveStyleCoupledValue(const Child&) const noexcept;

private:
    CSSCalcSwiftOperandStack* m_operands;
    const SimplificationOptions* m_options;
};

// What the simplification walk did. Mirrors `CSSCalcSwiftSerializationResult` except in the width
// and the key of the mask.
struct CSSCalcSwiftSimplificationResult {
    // Bit `1 << rawValue` for each `CSSCalcSwiftAlternative` the walk stood on. Keyed on the
    // alternative and not on the kind, because `min()` and `mod()` share the `Function` kind, one
    // handled and one not, so `(inputKindMask & ~handledMask) != 0` is not writable over a mask whose
    // bits lump the two together.
    uint64_t kindMask;
    uint32_t nodeCount;
    // 0 = simplified, 1 = declined. Not a `bool`, so a third outcome is not an ABI change; the
    // numbering is pinned by static_assert in CSSCalcTree+Simplification.cpp.
    uint8_t outcome;
    // A `CSSCalcSwiftAlternative` raw value, or 0xFF for "did not decline" and for "declined without
    // one alternative to blame".
    uint8_t declineAlternative;
};

// MARK: - The Swift calc parse path's token boundary

// One CSS token, in the form the calc grammar needs and nothing more. It carries no pointer, unlike
// `CSSParserTokenBits`, whose value slot holds a live `const void*` into the stylesheet text once
// `CSSSwiftTokenSink::takeChunk` has resolved it.
struct CSSCalcSwiftToken {
    double numericValue;
    // `CSSValueID` raw values rather than the enum, because CSSValueKeywords.h is generated and
    // including it would defeat this header's self-containment. Swift compares them against values it
    // obtains from C++, never against a transcribed list.
    uint16_t id;
    uint16_t functionId;
    // 16 bits because that is what `CSSParserToken::delimiter()` returns: truncating to 8 would make
    // U+012B compare equal to '+' and accept `calc(1px ī 2px)` as a sum.
    char16_t delimiter;
    // `CSSUnitType::Unknown` is what `parseCalcDimension` rejects on, so it crosses as itself.
    CSSUnitType unit;
    CSSParserTokenType type;
    // `CSSParserToken::BlockType`. Pinned one enumerator per line in CSSCalcTree+Parser.cpp.
    uint8_t blockType;

    // Predicates that ride in the padding, each a pure function of a field already in this struct.
    // `makeNumeric`'s answer deliberately does not ride here and stays `cssCalcSwiftLeafKindForUnit`:
    // `tokenAt` runs once per token where that answer is needed once per dimension leaf, and reaching
    // it constructs and destroys a `Child`.
    uint8_t flags;
};
// For a DimensionToken: `conversionToCanonicalUnitRequiresConversionData(unit)`.
static constexpr uint8_t cssCalcSwiftTokenUnitNeedsConversionData = 1 << 0;
// For a FunctionToken: `isCalcFunction(functionId)`. The grammar falls back to the C++ path for
// these rather than failing, because they are real CSS it does not cover yet.
static constexpr uint8_t cssCalcSwiftTokenIsCalcFunction = 1 << 1;
// For a FunctionToken: `calc()` or `-webkit-calc()` specifically. A function block with neither this
// bit nor the one above is a parse failure, which is what the C++ path does with it.
static constexpr uint8_t cssCalcSwiftTokenIsPlainCalcFunction = 1 << 2;
// For an IdentToken: the text starts with `--`. This is `consumeUnresolvedDashedIdent`'s predicate
// over the same one token, so the two paths' accept sets are identical by construction rather than by
// an argument about escapes.
static constexpr uint8_t cssCalcSwiftTokenIsDashedIdent = 1 << 3;
static_assert(sizeof(CSSCalcSwiftToken) == 24);
static_assert(alignof(CSSCalcSwiftToken) == 8);

// A read-only cursor over the tokens of one `calc()`. Swift reads one token at a time by value,
// because it cannot receive a bounds-carrying view at all (rdar://186723514).
//
// `SWIFT_SAFE` is an unchecked assertion over the `std::span` inside `CSSParserTokenRange`. It holds
// because the cursor is constructed on the C++ stack immediately before the single Swift call that
// takes it and destroyed when that call returns, it crosses `noescape`, and the token vector is
// complete before any property parser runs.
struct SWIFT_SAFE CSSCalcSwiftParseCursor {
    // Whitespace tokens are not filtered out, because the grammar's look-behind is `tokenAt(i - 1)`.
    uint32_t tokenCount() const noexcept;

    // Out of range yields a token whose `type` is `EOFToken`, matching what
    // `CSSParserTokenRange::peek` does past the end, so Swift needs no bounds pre-check to mirror the
    // C++ grammar's behaviour.
    CSSCalcSwiftToken tokenAt(uint32_t index) const noexcept;

#if !defined(__swift__)
    explicit CSSCalcSwiftParseCursor(const CSSParserTokenRange& range)
        : m_range(range)
    {
    }

private:
    const CSSParserTokenRange& m_range;
#else
    // Same-size stand-in, so that the importer never walks CSSParserTokenRange and drags
    // CSSTokenizer.h into this header. The branch that can see the real type asserts the size,
    // because a placeholder that disagreed would let the two languages hold different views of one
    // live object with no diagnostic.
    const void* m_rangeStandIn;
#endif
};

// What the parse needs from `ParserState` and `ParserOptions`, flattened.
//
// `treeCountingAllowed`, `cssCalcMixEnabled`, `anchorAllowed` and `anchorSizeAllowed` are the
// context gates on `sibling-count()`/`sibling-index()`, `calc-mix()`, `anchor()` and
// `anchor-size()`. Clear means the parse must FAIL, not fall back: with the gate clear the C++ path
// returns `std::nullopt`, so parsing instead would accept CSS the C++ rejects.
struct CSSCalcSwiftParseOptions {
    // The enum itself rather than its raw value, because `init?(rawValue:)` on an imported C++ enum
    // never fails, so reconstructing it in Swift behind a `guard let` would be a vacuous guard.
    CSS::Category category;
    // A unit needing conversion data is a parse failure rather than a fallback when this is set,
    // exactly as `parseCalcDimension` has it.
    bool absoluteLengthUnitsOnly;
    // Load-bearing rather than informational: `parseCalcKeyword` checks the symbol table before the
    // five `<calc-keyword>` constants, so an id present in both resolves as a symbol on the C++ side
    // and would resolve as a constant here. The grammar does not carry the symbol table, so with a
    // non-empty table every `IdentToken` falls back to the C++ path.
    bool hasAllowedSymbols;

    // The conjunction of `parseCalcFunction`'s four clauses: the context setting, a `currentRule` of
    // `Style` or `Keyframe`, and a `currentProperty` other than `CSSPropertyInvalid` OR the parser
    // state's `treeCountingFunctionsAllowed` (the last two are disjoined, not conjoined).
    bool treeCountingAllowed;

    bool cssCalcMixEnabled;

    // Two fields rather than one "anchor positioning is on" bit, because the two policies are
    // independent in production: the eight inset properties allow both, while
    // `width`/`height`/`max-*`/`margin-*` allow only `anchor-size()`.
    bool anchorAllowed;
    bool anchorSizeAllowed;

    // `consumeAnchorFallback`'s `Category::Number` case. It has to cross even though its default is
    // `Allow`, because a property that forbids it rejects `anchor(top, 0)`.
    bool unitlessZeroLengthAllowed;

    // The top-level function's `CSSValueID` raw value. `parseAndSimplify` accepts any
    // `isCalcFunction` at the top, so `width: min(1px, 2px)` is a top-level `Min`, but this entry is
    // handed the range inside the function and cannot see which one it was. Carried rather than
    // handing Swift the outer range, because routing the top level through the block branch would
    // enter its arguments at depth 1 where the C++ enters them at 0.
    uint16_t rootFunctionId;
};

// `Failed` and `Declined` must not share a channel: a failure means the input is not a valid
// `calc()` and the C++ path would also have returned `std::nullopt`, so the caller must not retry.
enum class CSSCalcSwiftParseOutcome : uint8_t {
    Parsed,
    Failed,
    Declined,
};

// Which uncovered construct caused a decline. Appended to, never inserted into, because the
// differential harness mirrors these numbers by hand.
enum class CSSCalcSwiftParseDeclineReason : uint8_t {
    None,
    MathFunction,
    Symbol,
    TreeCounting,
    TooManyTokens,
    // A `calc-mix()` item weight that is a math function rather than a raw `<percentage>`. Its
    // second `Weight` alternative holds a `Ref<CSSCalc::Value>` -- a whole second calc value, not a
    // `Child` -- so no flat node can carry it.
    CalcMixWeight,
    // An `anchor()` or `anchor-size()` in a configuration where the C++ path's `simplify` would
    // evaluate it, which it does through the original `CSSCalc::Child` that a parsed tree has not
    // got.
    AnchorEvaluation,
    // A construction refused: the boundary's own contract came apart, rather than the input being
    // uncovered. Carried as a decline so a production parse falls back to C++ instead of dropping a
    // declaration the C++ would have parsed, and named separately so it stays distinguishable from
    // an uncovered input. No input should produce it, and the differential reports the reason, so a
    // case that does is visible there.
    ContractViolation,
};

struct alignas(8) CSSCalcSwiftParseResult {
    Type type;
    // A `CSSCalcSwiftParseOutcome`.
    uint8_t outcome;
    // A `CSSCalcSwiftParseDeclineReason`.
    uint8_t declineReason;
    bool requiresConversionData;
};
static_assert(sizeof(CSSCalcSwiftParseResult) == 16);
static_assert(alignof(CSSCalcSwiftParseResult) == 8);


// The alternative `makeNumeric` would build for `unit`, as a `CSSCalcSwiftNodeKind`. C++ answers it
// because `makeNumeric` owns the seventy-case unit table.
WEBCORE_EXPORT uint8_t cssCalcSwiftLeafKindForUnit(uint16_t unit) noexcept;

// `lookupConstantNumber(id)`: the five `<calc-keyword>` constants. The table is C++'s, and it is
// keyed on `CSSValueID`, which this header deliberately does not import.
WEBCORE_EXPORT CSSCalcSwiftNumericResult cssCalcSwiftLookupConstantNumber(uint16_t id) noexcept;

// Drives the Swift grammar over the tokens inside a `calc()`, simplifies the result, and constructs
// it into `outRoot`. Declared here rather than at the call site because `CSSCalcSwiftOperandStack`
// is only forward-declared, so no other translation unit can build one.
//
// `simplify` false skips the middle pass, matching `ParseSimplification::None`. It exists for the
// grammar differential, which must compare an unsimplified tree: against a simplified one a parse
// defect and a commutative fold can cancel, since `Sum{2px, 1px}` and `Sum{1px, 2px}` agree after
// folding.
//
// Returns `Parsed` only when the whole range was consumed and the boundary contract held -- the root
// slot taken and the operand stack empty. Anything else leaves `outRoot` untouched.
WEBCORE_EXPORT CSSCalcSwiftParseResult cssCalcSwiftParseIntoChild(const CSSParserTokenRange& innerRange, CSSCalcSwiftParseOptions, const SimplificationOptions&, Child& outRoot, bool simplify = true, CSSCalcSwiftFlatNodeVector* outFlatNodes = nullptr, uint32_t* outFlatRootIndex = nullptr) noexcept;

// Rebuild a `Child` from a stored flat tree. False leaves `outRoot` untouched.
//
// `tokens` is the range the tree was parsed from, and is required rather than defaulted because the
// flat form is an encoding relative to that range: an `anchor()`'s `<anchor-element>` is stored as a
// token index (see `CSSCalcSwiftBuilder::buildAnchor`), so a caller that no longer has the tokens
// cannot decode one. A wrong range is refused rather than mis-decoded, because `buildAnchor`
// re-checks the `IdentToken` and `--` predicate at the index and a default-constructed range yields
// the EOF token there.
WEBCORE_EXPORT bool cssCalcSwiftEmitStoreIntoChild(const CSSCalcSwiftFlatNodeVector&, uint32_t rootIndex, const SimplificationOptions&, const CSSParserTokenRange& tokens, Child& outRoot) noexcept;

} // namespace CSSCalc
} // namespace WebCore
