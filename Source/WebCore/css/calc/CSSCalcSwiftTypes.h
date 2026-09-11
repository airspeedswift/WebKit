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
#include <WebCore/CSSCalcType.h>
#include <WebCore/CSSParserTokenBits.h>
#include <WebCore/CSSUnitType.h>
#include <WebCore/PlatformExportMacros.h>
#include <wtf/SwiftBridging.h>

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

// The TREE-ORDER index of `node`'s `index`th child IN SERIALIZATION ORDER, or `node.childCount()`
// for an out-of-range request.
//
// For `Sum` and `Product` serialization order is not tree order: css-values-4 steps 6 and 7 both
// begin "Sort root's children", and the key is `sortPriority`, a 60-case unit order generated with
// `__COUNTER__` (CSSCalcTree+Serialization.cpp:146). That generated table must not be transcribed
// into Swift, so C++ keeps the sort. Every other kind is the identity, because no other kind sorts.
//
// A permutation ENTRY, not a child: a `const Child&` return would import as `UnsafePointer`, so the
// sorted child cannot be handed over as a reference at all. Handing back the INDEX instead lets
// Swift take the borrow through `Child::operator[]`, which is the route the simplification island
// already uses everywhere -- so no permutation buffer crosses and this boundary owns no storage.
//
// Linear per access, and for `Sum` and `Product` it re-sorts per access, so a full walk is
// quadratic in the child count. Deliberate and priced rather than assumed: a calc expression's
// child lists are a handful of nodes (the widest in the whole WPT css-values corpus is single
// digits), and the alternative is a buffer this boundary would have to own.
WEBCORE_EXPORT uint32_t swiftSerializationChildIndex(const Child&, uint32_t index) noexcept;

// Where the serialization output goes.
//
// C++ owns the buffer and the number formatting; Swift says what to append. That split is the
// single most important correctness decision here: `formatCSSNumberValue` must be an upcall.
// Swift's `Double.description` is shortest-round-trip and CSS number serialization is a different
// algorithm, so a Swift reimplementation would agree on every common value and diverge on
// subnormals and 17-significant-digit values, with nothing in this repository to catch it.
//
// A `SWIFT_SAFE` *value* struct taken `inout`, rather than the `SWIFT_SHARED_REFERENCE` over
// `ThreadSafeRefCounted` that CSSSwiftTokenSink uses. Both reach zero `unsafe`, and a value struct
// is better here: the sink lives on the C++ stack for exactly one `serializationForCSS` call, so a
// refcounted sink would cost a heap allocation per call on a path `cssText` and getComputedStyle
// reach, and "immortal" would be a claim that is not true.
//
// WHY THE `SWIFT_SAFE` CLAIM HOLDS, which is a separate question from the paragraph above and is the
// one that matters. `SWIFT_SAFE` is `swift_attr("safe")`: an UNCHECKED assertion that this type
// safely encapsulates its unsafe constituents. Nothing verifies it -- and WebCore's Swift is built
// with `-strict-memory-safety` and `-Werror StrictMemorySafety`, so without the annotation the two
// raw pointer members below would make the whole type unsafe to Swift and every use of it would need
// an `unsafe` marker. Two of the island's zero `unsafe` markers rest on this line and on the
// matching one on `CSSCalcSwiftBuilder`, so the claim is stated rather than left implicit:
//
//   * The referents outlive every use. The sink is constructed at exactly one site --
//     `trySerializeWithSwift` (CSSCalcTree+Serialization.cpp) -- from that function's own
//     `StringBuilder&` parameter and from `options.serializationContext`, both of which the caller
//     of `serializationForCSS` owns; it is passed straight to `cssCalcSerializeSwift` in the next
//     statement and destroyed at the end of that scope. `[[clang::lifetimebound]]` on both
//     constructor parameters is what makes a temporary at that site a clang diagnostic rather than a
//     silent dangle, so the one-site claim is enforced for any site added later.
//   * Swift does not extend either pointer's reach, and this is the bullet that needs checking
//     rather than asserting: the struct imports as an ordinary copyable value, so a copy COULD carry
//     `m_builder` into a stored property. None does. Every one of the thirteen Swift signatures that
//     names this type (`CSSCalcSerializationSwift.swift`) takes it `inout`, no Swift type declares a
//     stored property of it, and no escaping closure captures it -- an `inout` argument cannot be
//     captured by one in any case. So every copy of `m_builder` is a parameter whose lifetime nests
//     inside the C++ call that supplied it.
//   * The output is disjoint from the input, so the `inout` costs nothing in exclusivity terms: the
//     `StringBuilder` being appended to is not reachable from the `Child` tree being read.
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

// Where the simplification output goes: the construction sink.
//
// Modelled on `CSSCalcSwiftSink` above: a `SWIFT_SAFE` value struct taken `inout` (the builder
// lives on the C++ stack for exactly one `copyAndSimplify` call, so a refcounted one would cost a
// heap allocation per call); every `Child` parameter by `const&`, never by value; one
// entry rather than N named methods wherever a selector can carry the choice; and anything whose
// exact output must match the C++ arm stays an upcall.
//
// It is an operand stack, not a node factory. Swift walks the tree post-order and pushes each
// finished subtree; a parent then says how many operands it consumes and gets one back, which is
// what lets `rebuildFrom` be generic and keeps `~Escapable` out of the picture -- no Swift
// container ever holds a `Child`, because the container is the C++ stack.
//
// WHY THE `SWIFT_SAFE` CLAIM HOLDS. As on `CSSCalcSwiftSink` (see the longer note there for what
// `swift_attr("safe")` is and why an unchecked assertion is load-bearing here), the annotation is an
// UNCHECKED claim that the two raw pointer members below are safely encapsulated, and the island's
// `unsafe` count of zero rests on it. What makes it true:
//
//   * The referents outlive every use. Six construction sites, all in
//     CSSCalcTree+Simplification.cpp: the production one is `trySimplifyWithSwift`, over that
//     function's `CSSCalcSwiftOperandStack&` parameter -- storage owned by `swiftSimplifiedRoot`'s
//     frame, which is also the frame holding the root slot the walk writes into -- and its
//     `const SimplificationOptions&`. The other five are `calcbench`'s probe entries, each over a
//     stack local declared immediately above. In all six the builder is destroyed in the same scope
//     that built it, before the referents go away. `[[clang::lifetimebound]]` on both constructor
//     parameters keeps a temporary at any future site a clang diagnostic rather than a dangle.
//   * Swift does not extend either pointer's reach, and the check is less trivial than the sink's
//     because this type is NOT only passed `inout`: the `simplifyX` family takes it by value as an
//     `Optional`, so copies of `m_operands` do exist. They are all parameters. No Swift type declares
//     a stored property of this type (grep for one: there is none), no escaping closure captures it,
//     and the by-value copies only travel further down the same recursion, so every copy's lifetime
//     nests inside the one C++ call.
//   * The `inout` builder is held across borrows of the input tree, which relies on EXCLUSIVITY and
//     is worth stating because it is the one non-obvious part: `simplify` borrows the original
//     `Child` while mutating the builder. That is sound by input/output disjointness -- the operand
//     stack and root slot are freshly constructed C++ storage, not reachable from the input tree --
//     so the two accesses can never overlap, whatever order the optimizer picks.
struct SWIFT_SAFE CSSCalcSwiftBuilder {
    CSSCalcSwiftBuilder(CSSCalcSwiftOperandStack& operands [[clang::lifetimebound]], const SimplificationOptions& options [[clang::lifetimebound]]) noexcept
        : m_operands(&operands)
        , m_options(&options)
    {
    }

    // `isRoot`, ON EVERY CONSTRUCTION ENTRY BELOW, and it is the whole of the boundary's knowledge
    // of where the finished tree goes.
    //
    // Set, the node being built is the tree's ROOT, and it is constructed straight into the `Tree`
    // the caller of `copyAndSimplify` asked for rather than onto the operand stack. Clear, it goes
    // on the stack as every other node does. Swift answers it with `i == 0`: node 0 of the flat
    // tree is the root and no child index is 0, so it costs one comparison and no extra crossing.
    //
    // WHY IT EXISTS. The last operand on the stack is the new root, and handing it over used to be
    // `Tree { .root = WTF::move(operands.value[0]) }` -- an out-of-line 41-alternative `mpark`
    // visit for the move plus another for the destroy of the moved-from slot, about 52 retired
    // instructions once per simplification, against a C++ arm that pays nothing because
    // `copyAndSimplify(const Child&)`'s return slot IS the `Tree`'s root. See `swiftSimplifiedRoot`
    // (CSSCalcTree+Simplification.cpp) for the elision chain that makes the destination reachable
    // and `constructOperand` for what happens at the slot.
    //
    // A trailing parameter rather than a `beginRoot()` entry, because arming would be a second
    // crossing per tree for a fact the caller already has, and rather than five `*Root` overloads,
    // because the destination is not a different way to build a node.
    //
    // Defaulted, so the `ENABLE(CSS_TOKENIZER_SWIFT_BRIDGE)` primitive benchmarks, which build
    // operands on a stack with no root slot at all, are unchanged. A `true` with no root slot
    // provided still pushes; nothing depends on the flag being honoured.

    // Build one of the four numeric leaves and push it. See `CSSCalcSwiftLeaf`.
    //
    // Returns false for a `kind` outside the four numeric leaves, which is a contract violation
    // rather than an input that can be met, declining rather than building something plausible.
    WEBCORE_EXPORT bool pushLeaf(CSSCalcSwiftLeaf, bool isRoot = false) noexcept;

    // Deep-copy an input subtree and push it. Used for every node walked past without changing,
    // and for every child of a node that is declined for rewriting.
    //
    // Routes to `CSSCalc::copy(const Child&)`, which is the copy the C++ arm's own
    // `copyAndSimplifyChildren` bottoms out in, so the two arms cannot disagree about what a copy
    // is. That overload had to be DECLARED for this -- CSSCalcTree+Copy.h exposed only `Tree` and
    // `AnchorSide`, while `Child` was one of ten `static` overloads inside CSSCalcTree+Copy.cpp --
    // which is one line of header and the removal of one `static`, and is the smallest thing that
    // works. Nothing new was written.
    WEBCORE_EXPORT void pushCopyOf(const Child&, bool isRoot = false) noexcept;

    // Pop `childCount` operands and push back one node of `original`'s own kind, built from them.
    //
    // C++ recovers the operation from `original`'s variant tag with `WTF::switchOn` and fills its
    // slots with `WTF::apply` over the tuple conformance (CSSCalcTree.h:1277-1319) -- the same
    // shape `copyAndSimplifyChildren` (CSSCalcTree+Simplification.cpp:1786) and `copy`
    // (CSSCalcTree+Copy.cpp:103) already use -- so all 34 operations are served by one spelling
    // and no operation is ever named on the boundary.
    //
    // A `Children`-slotted operation (`Sum`, `Product`, `Min`, `Max`, `Hypot`, `CalcMix`'s item
    // vector) takes all `childCount` operands, which is what lets the arity change -- dropping a
    // zero term from a sum is the commonest simplification there is. Every other slot takes exactly
    // one operand or none, following the original's shape for `std::optional<Child>` and
    // `ChildOrNone`.
    //
    // Returns false, reported as a decline, for a contract violation: too few operands, a mismatched
    // arity, a leaf, or an `Anchor`/`AnchorSize` -- both declare `tuple_size` 0 (CSSCalcTree.h:1317,
    // "FIXME webkit.org/b/280798"), so generic reconstruction would build them empty.
    WEBCORE_EXPORT bool rebuildFrom(const Child& original, uint32_t childCount, bool isRoot = false) noexcept;

    // Push the weight the next `CalcMix` item pushed as an operand is to carry.
    //
    // A second stack beside the operand stack, with the same discipline: `rebuildFrom` on a
    // `CalcMix` consumes the top `childCount` of both, so operands are pushed first and weights
    // after.
    //
    // `replaceWeight` set means `weight` is a `<percentage>` computed here -- spec step 2's
    // `(100% - specified sum) / n` or step 4's `weight * 100% / total`. Clear means "the weight of
    // original item `origin`, unchanged", the only way `simplify(CalcMix&)`'s `!canNormalize` path
    // (CSSCalcTree+Simplification.cpp:1509) is expressible: it drops items while leaving survivors'
    // weights alone, and a survivor can hold a `Calc` weight that cannot be reproduced.
    //
    // Addressed by index rather than by position, because pairing by original position is wrong
    // once items can be dropped -- only the caller knows which original item each survivor is.
    WEBCORE_EXPORT void pushCalcMixItemWeight(uint32_t origin, double weight, bool replaceWeight) noexcept;

    // Pop `childCount` operands and push a FRESH node of the named `alternative` built from them.
    //
    // The construction entry that does NOT take an original node, and the one the flat tree uses for
    // every operator it can build from operands alone. `rebuildFrom` above recovers the operation
    // from the original node's variant tag through a 41-way `switchOn` plus `WTF::apply`, and a flat
    // node has no original to recover from and does not need one: it already states its own
    // alternative.
    //
    // WHAT THAT DISPATCH COSTS, measured rather than asserted, and CORRECTED: this comment used to
    // read "1396 retired instructions, measured as primitive 7 against primitive 8", which was
    // wrong twice over. Primitive 7 also constructs and destroys a fresh
    // `CSSCalcSwiftOperandStack` and makes two `pushLeaf` calls, so 7 against 8 was an upper bound
    // on the whole reconstruction and not a measurement of the dispatch; and 1396 is not that
    // difference at any build measured since -- primitives 7 and 8 read 1151.4 and 854.2.
    // Primitives 17 and 18 isolate it (CSSCalcTree+Simplification.cpp): the same two `pushLeaf`s
    // over a HOISTED stack, with and without the reconstruction, at 1138.5 and 266.1. So
    // `rebuildFrom` reconstructing a two-child `Sum` is 872 retired instructions INCLUDING the
    // `Vector<Child>` it allocates, the `makeChild`, and two extra frees at teardown -- against 854
    // for primitive 8, the C++ arm building the same node directly INCLUDING its two leaves.
    // Netting the leaves out (2 x primitive 4, 68) puts the dispatch premium at ROUGHLY 50 TO 90
    // INSTRUCTIONS, about a tenth of the reconstruction. The allocation dominates it, not the
    // 41-way visit. Routing every operator through `rebuildFrom` to retire this entry was BUILT AND
    // MEASURED (`cssprobe/validate/arms/calc-p3only.patch`) and costs +16.9% on the real payload,
    // so the premium is not a rounding error at this granularity; see the note there.
    //
    // Naming the alternative here is a deliberate reversal of the rule the reading direction keeps
    // ("no operation kind ever crosses in the construction direction", above). That rule is right
    // when the output node's kind IS the input node's kind, because then recovering it is free and
    // stating it is duplication. It stops being right once Swift owns the tree: there is no input
    // node, so a kind that does not cross is a kind that has to be re-derived from something, and
    // there is nothing left to re-derive it from.
    //
    // This subsumes the earlier `buildMinMax(bool isMax, ...)`: `clamp(none, VAL, MAX)` rewriting
    // to `min(VAL, MAX)` and `clamp(MIN, VAL, none)` to `max(MIN, VAL)`
    // (CSSCalcTree+Simplification.cpp:1012-1038) is `Min`/`Max` through this same entry, so the
    // selector is one enum rather than one enum and one `bool`.
    //
    // ONE TYPE RULE, AND IT IS `carriedType`. The C++ arm does not recompute a type when it rebuilds
    // a node whose kind did not change: `copyAndSimplify` ends at `makeChild(WTF::move(simplified),
    // getType(root))` (`:1821`), the ORIGINAL node's type, and `rebuildFrom` above matches it with
    // `getType(alternative)`. Recomputing instead is a measured differential failure, not a
    // theoretical gap: `calc((2 / 3px) * 4px)` simplifies to a surviving `Product{6px, 4px}` on both
    // arms, which SERIALIZES identically on both, so only the structural oracle sees it -- the C++
    // keeps the parse-time type while a fresh `toType` computes px^2. 57 cases in simplifycheck's
    // own corpus, all of that one shape.
    //
    // The one rewrite that invents a kind not present in the input carries a type too, and that is
    // why the `bool recomputeType` selector this entry used to take is gone. `toType(Min)` is
    // `Type::consistentType` over the two operands -- `AllowedTypes::Any` in, `OutputTransform::None`
    // out -- so the island computes it in `convertToMinMax` and stores it on the flat node BEFORE
    // committing to the conversion. A merge that fails leaves the node a `Clamp`, which is what
    // `convertToMin` returning `std::nullopt` (`:1021`) makes `copyAndSimplify` do with it. So this
    // entry can no longer fail for a reason that is not a contract violation, and the whole-tree
    // decline that a `std::nullopt` here used to force -- the island's last one -- has no cause left.
    //
    // `Type` is 8 bytes of `int8_t` exponents plus a percent hint (CSSCalcType.h, `static_assert
    // (sizeof(Type) == 8)`), so it crosses in a register. It costs this header one include, of a
    // file whose own includes are `<array>`, `<optional>` and `<wtf/Forward.h>` -- so the
    // self-containment the note at the top of this file protects is intact, and the Swift step
    // already imported `CSSCalcType.h` through `CSSCalcTree.h` regardless.
    //
    // Serves the `Children`-slotted operations (`Sum`, `Product`, `Min`, `Max`) and the two unary
    // ones (`Negate`, `Invert`); an alternative outside that set, a mismatched arity, or too few
    // operands is a contract violation and returns false without touching the stack. Widening the
    // set is a case each, and it is why `Children` never has to reach Swift: this is the only
    // place a `Vector<Child>` is assembled, and it is assembled from the operand stack.
    WEBCORE_EXPORT bool buildOperation(CSSCalcSwiftAlternative, uint32_t childCount, Type, bool isRoot = false) noexcept;

#if ENABLE(CSS_TOKENIZER_SWIFT_BRIDGE)
    // Drop every operand.
    //
    // The benchmark's, and only the benchmark's -- so it is compiled out of a shipping build, and
    // its one Swift caller (`cssCalcFlatEmitProbeSwift`) already sits behind the same guard.
    // `copyAndSimplify` builds a fresh `CSSCalcSwiftOperandStack` per call, so nothing on a real
    // path ever re-enters a used one. It is a member rather than a line in the benchmark because
    // the stack reaches the timed loop only through this builder, and the loop has to be on the
    // SWIFT side -- that is what hoists the flat tree's two buffers across iterations, and
    // allocating them per call read 2338 retired instructions against 458 hoisted.
    //
    // Inline is not available: `CSSCalcSwiftOperandStack` is forward-declared here, deliberately, so
    // that this header stays self-contained and does not pull in wtf/Vector.h.
    // Move the single remaining operand into the root slot.
    //
    // WHY THE PARSER NEEDS THIS AND THE SIMPLIFIER DOES NOT. The simplifier walks a tree it already
    // has, so it knows which node is the root before it builds it and passes `isRoot` -- which
    // constructs straight into the root slot and moves nothing. A recursive-descent parser does not
    // know: whether the first `<calc-product>` is the whole expression or the first operand of a
    // sum is only settled after it has been parsed and pushed. Deciding by lookahead would mean
    // scanning for a top-level `+` at every nesting level before descending.
    //
    // Costs one `Child` move per parse -- an out-of-line 41-alternative variant move, ~42
    // instructions, measured on the `RebuildCursor::take()` arm. Once per whole parse, not per
    // node, and it goes away if the grammar ever builds into the flat form and emits in one pass.
    // Returns false if the stack does not hold exactly one operand, which is a boundary contract
    // violation rather than a parse outcome.
    WEBCORE_EXPORT bool finishRoot() noexcept;

    WEBCORE_EXPORT void clearOperands() noexcept;
#endif

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

// MARK: - The Swift calc PARSE path's token boundary (P7b stage C)

// One CSS token, in the form the calc grammar needs and nothing more.
//
// WHY A PURPOSE-BUILT POD RATHER THAN `CSSParserTokenBits`, WHICH IS ALREADY `SWIFT_SAFE` AND
// ALREADY IMPORTED. Its value slot is a union that, once `CSSSwiftTokenSink::takeChunk` has
// resolved it, holds a LIVE `const void*` into the stylesheet text. `CSSParserTokenBits`'s own
// `SWIFT_SAFE` is honest today precisely because on the tokenizer's path that slot holds a parked
// integer for exactly as long as Swift can see it (CSSParserTokenBits.h). Handing the calc parser a
// *resolved* one would make that assertion false in a new way and silently, so this carries no
// pointer at all: `id` and `functionId` are resolved on the C++ side, which is where
// `cssValueKeywordID` already runs, so Swift never needs a token's text and the parse never touches
// the stylesheet buffer.
//
// THE FIELD SET IS EXHAUSTIVE, NOT A SKETCH. It is every accessor `CSSCalcTree+Parser.cpp` reads off
// a token, enumerated from the source rather than assumed:
//   `type()` (dispatch, and the whitespace look-behind at :1410), `unitType()` (:1608, where
//   `Unknown` is the reject signal), `numericValue()` (:1594, :1602, :1613), `id()` (:1571, :1584),
//   `functionId()` (:170, :916, :1529) and `delimiter()` (:1406).
// `numericValueType()` is deliberately ABSENT -- no calc grammar rule reads integer-ness. If one
// ever does, this struct has seven spare bytes.
//
// `delimiter` IS 16 BITS AND THAT IS LOAD-BEARING. `CSSParserToken::delimiter()` returns `char16_t`
// (CSSParserToken.h:92) and the design sketch this came from said `uint8_t`. Truncating would make
// U+012B compare equal to '+' (0x2B), i.e. accept `calc(1px ī 2px)` as a sum -- a silently WRONG
// stylesheet rather than a decline, which is the class of defect an imported-enum mirror already
// produced once on this island.
//
// `id`/`functionId` are the raw values of `CSSValueID`, not the enum: `CSSValueKeywords.h` is
// generated and would defeat this header's self-containment (see the file comment). Swift compares
// them against values it obtains FROM C++, never against a transcribed list -- transcribing the
// enumerator table is the thing that must not happen here.
struct CSSCalcSwiftToken {
    // Meaningful for NumberToken, PercentageToken and DimensionToken.
    double numericValue;
    // `CSSValueID` raw value. Non-zero only for IdentToken.
    uint16_t id;
    // `CSSValueID` raw value. Non-zero only for FunctionToken.
    uint16_t functionId;
    // `CSSParserToken::delimiter()`. Meaningful only for DelimiterToken.
    char16_t delimiter;
    // `CSSUnitType::Unknown` is what `parseCalcDimension` rejects on, so it crosses as itself.
    CSSUnitType unit;
    CSSParserTokenType type;
    // `CSSParserToken::BlockType`, so Swift can compute block extents itself and `consumeBlock`
    // needs no crossing. Pinned one enumerator per line in CSSCalcTree+Parser.cpp rather than
    // trusted, exactly as the tokenizer boundary pins its token numbering.
    uint8_t blockType;
};
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

// What the parse needs from `ParserState` and `ParserOptions`, flattened. Deliberately small:
// stage D covers `<calc-sum>`, `<calc-product>`, `<calc-value>`, the numeric leaves, the five
// keyword constants and parenthesised blocks, and declines everything else -- so the symbol table,
// the tree-counting context and the math-function set do not cross yet.
struct CSSCalcSwiftParseOptions {
    // The enum itself, not its raw value. `CSSCalcSwiftSimplificationOptions` carries a `uint8_t`
    // and Swift reconstructs it with `CSS::Category(rawValue:)` behind a `guard let` -- but
    // `init?(rawValue:)` on an IMPORTED C++ enum NEVER FAILS (interop notes 92), so that guard is
    // vacuous and the reconstruction is pure ceremony. Carrying the type removes both.
    CSS::Category category;
    // `PropertyParserState::absoluteLengthUnitsOnly`: a unit needing conversion data is a parse
    // failure rather than a decline when this is set, exactly as `parseCalcDimension` has it.
    bool absoluteLengthUnitsOnly;
    // Whether `ParserOptions::allowedSymbols` has anything in it.
    //
    // LOAD-BEARING, not informational. `parseCalcKeyword` checks the symbol table BEFORE the five
    // constants, so an id present in both resolves as a symbol on the C++ side and would resolve
    // as a constant here. Stage D does not carry the symbol table, so with a non-empty table every
    // `IdentToken` is declined -- the conservative side, since a decline runs the C++ arm and a
    // wrong constant would be a wrong stylesheet.
    bool hasAllowedSymbols;
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
    // A math function: `min`, `max`, `clamp`, `round`, the trig set, and the rest. Stage E.
    MathFunction,
    // An `IdentToken` while `ParserOptions::allowedSymbols` is non-empty. Stage F.
    Symbol,
    // `sibling-count()` / `sibling-index()`. Stage F.
    TreeCounting,
    // More tokens than the grammar's fixed cursor budget.
    TooManyTokens,
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

// The alternative `makeNumeric` would build for `unit`.
//
// C++ answers this, and that is the point: `makeNumeric` maps unit to alternative through a
// seventy-case table, and reproducing the choice in Swift would duplicate it -- the same argument
// `CSSCalcSwiftNumericResult::kind` already carries in this file. Called once per dimension leaf
// actually built, NOT once per token, so it costs nothing on the tokens the grammar walks past.
// Returns a `CSSCalcSwiftNodeKind`.
WEBCORE_EXPORT uint8_t cssCalcSwiftLeafKindForUnit(uint16_t unit) noexcept;

// `conversionToCanonicalUnitRequiresConversionData(unit)`. Same argument: a unit predicate whose
// table belongs to C++.
WEBCORE_EXPORT bool cssCalcSwiftUnitRequiresConversionData(uint16_t unit) noexcept;

// `lookupConstantNumber(id)`: the five `<calc-keyword>` constants. `resolved` false means the
// identifier is not one of them. Same argument again -- the table is C++'s, and it is keyed on
// `CSSValueID`, which this header deliberately does not import.
WEBCORE_EXPORT CSSCalcSwiftNumericResult cssCalcSwiftLookupConstantNumber(uint16_t id) noexcept;

// Drives the Swift grammar over `innerRange` -- the tokens INSIDE a `calc()`, which is what
// `consumeFunction` leaves -- and constructs the parsed tree into `outRoot`.
//
// Lives beside the operand stack rather than at the call site because `CSSCalcSwiftOperandStack` is
// only forward-declared in this header (it holds a `WTF::Vector<Child>`, and this header must stay
// self-contained), so no other translation unit can build one. That is also the production shape:
// when the parse path is gated on, `parseAndSimplify` calls exactly this.
//
// Returns `Parsed` only when the whole range was consumed AND the boundary contract held -- the
// root slot taken and the operand stack empty. Anything else leaves `outRoot` untouched.
WEBCORE_EXPORT CSSCalcSwiftParseResult cssCalcSwiftParseIntoChild(const CSSParserTokenRange& innerRange, CSSCalcSwiftParseOptions, const SimplificationOptions&, Child& outRoot) noexcept;

} // namespace CSSCalc
} // namespace WebCore
