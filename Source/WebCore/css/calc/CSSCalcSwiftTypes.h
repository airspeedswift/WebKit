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

// Everything the Swift calc serialization and simplification code -- CSSCalcSerializationSwift.swift
// and CSSCalcSimplificationSwift.swift -- may see of WebCore. Its own Clang module in
// WebCore_Private.modulemap, self-contained, so importing it cannot walk the ~3,500-header
// PrivateHeaders umbrella into JavaScriptCore's private headers.
//
// The tree itself is not imported. Swift does not need `Child`'s layout to walk the tree, only its
// identity, so a handle holding `const Child*` needs `Child` merely forward-declared, which is what
// CSSCalcTree+Serialization.h has always done. That keeps this header self-contained -- importing
// CSSCalcTree.h would drag in CSSPrimitiveNumeric.h, CSSCustomIdent.h, CSSValueKeywords.h,
// CSSCalcRandomSharing.h, wtf/Vector.h and wtf/TZoneMalloc.h -- and avoids an importer defect where
// the private `Variant` member's destructor is odr-used over incomplete `UniqueRef<Op>`
// alternatives.
//
// The recursive walk and the sink below import with 0 errors, 0 warnings and 0 `unsafe` markers.

#pragma once

#include <cstddef>
#include <cstdint>
#include <WebCore/PlatformExportMacros.h>
#include <wtf/SwiftBridging.h>

// Forward declaration only, so this header stays self-contained. The sink writes into a builder
// that C++ owns; Swift never sees StringBuilder's definition and never needs to.
namespace WTF {
class StringBuilder;
}

namespace WebCore {

namespace CSS {
struct SerializationContext;
}

namespace CSSCalc {

struct Child;
struct SimplificationOptions;

// The simplification operand stack, which C++ owns. Forward-declared and defined in
// CSSCalcTree+Simplification.cpp, because naming what it actually is -- a `WTF::Vector<Child>` --
// would need wtf/Vector.h here, and this header must stay self-contained (see the note at the
// top). Swift never sees inside it; it only names positions on it implicitly, by pushing and by
// saying how many operands a reconstruction consumes.
struct CSSCalcSwiftOperandStack;

// What kind of node the walk is standing on.
//
// Declared here in C++ rather than in Swift with `@c`: C++ produces the kind and Swift consumes
// it, so the single declaration belongs on the producing side, and an `enum class ... : uint8_t`
// imports as an ordinary Swift enum that Swift can `switch` over exhaustively.
//
// Four operator kinds are split out of a single `Operation` case -- the four whose serialization
// is the grouping-parenthesis state machine (css-values-4 steps 4 to 7). The remaining 30 are not
// named one per kind, because their *serialization* only has four shapes: the kind names the shape
// and `valueID` carries the name. `Function` is `name(id)` followed by comma-separated arguments,
// which is 19 of the 30 outright and `clamp()` too whenever neither bound is `none`. A per-operator
// kind would have been 30 Swift cases and 30 C++ lambdas doing the same thing, putting the operator
// *table* on both sides of the boundary.
//
// `Operation` is therefore no longer "everything unabsorbed" but a much narrower thing: now it is
// only "an operation added to CSSCalcTree.h that this file has not been taught". That fallback
// direction is deliberate: the C++ side uses an allowlist of generically-serialized operations, so
// a new operation declines until taught, where a denylist would silently serialize it with the
// wrong spelling.
//
// The last four -- `Random`, `CalcMix`, `Anchor` and `AnchorSize` -- each get their own kind rather
// than sharing one, because unlike the thirty above, their serializations have four genuinely
// different shapes and each needs different non-tree data (see `CSSCalcSwiftOperationInfo`). Where
// the rule above was "the kind names the shape and `valueID` carries the name", these four are the
// cases where the shape *is* the operation.
//
// `OpaqueOperation` no longer has a producer, and is retained rather than removed. It was `Anchor`
// and `AnchorSize`, which declare `tuple_size` 0 (CSSCalcTree.h:1317, "FIXME
// (webkit.org/b/280798): make Anchor and AnchorSize tuple-like") so that `forAllChildNodes` reports
// no children even though an `Anchor` holds an `AnchorSide` and an optional fallback `Child`. This
// does not fix that FIXME -- doing so would change what `forAllChildNodes` yields for every other
// caller, simplification and evaluation included. Instead `forEachChildNodeOfChild` in the bridge
// answers for those two directly, so the lie stops at the boundary and `childCount` is the truth on
// the Swift side. The case stays because removing it would renumber every kind above it, and
// `kindMask` is `1 << rawValue` with per-kind figures printed by bit number.
//
// New cases are appended, never inserted: `CSSCalcSwiftSerializationResult::kindMask` is `1 <<
// rawValue` with per-kind coverage counts printed by bit number, so inserting a case would
// silently relabel every existing count.
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
    OpaqueOperation,
    // `Deg2Rad`, which is inserted at parse time inside `Sin`/`Cos`/`Tan` when the argument is an
    // angle and has no CSS-level spelling at all. It serializes as its child, transparently.
    Transparent,
    // A math function whose serialization is `nameLiteralForSerialization(Op::id)`, `(`, its
    // arguments joined with `, `, `)`. Nineteen of the 34 operations by name, plus `clamp()` when
    // neither bound is `none`, and `valueID` is the name.
    Function,
    // `round()`: the same shape with `round(` and the rounding strategy ahead of the arguments.
    // `valueID` is the STRATEGY (`nearest`, `up`, `down`, `to-zero`), because the function name is
    // fixed and the strategy is what distinguishes the four operations.
    RoundFunction,
    // `progress(no-clamp ...)`, whose prefix is the function name followed by `(no-clamp ` -- a
    // space rather than the `, ` every other multi-argument prefix uses.
    ProgressNoClampFunction,
    // `clamp()` with one bound holding the keyword `none`, the one place in the whole tree where an
    // argument is not a child node: `min` and `max` are `ChildOrNone`, and the C++ argument
    // serializer emits `none` for a bound holding one (`+Serialization.cpp:588`-`:596`) where
    // `forAllChildNodes` skips it entirely. Without these, `clamp(none, VAL, MAX)` would serialize
    // as `clamp(VAL, MAX)` -- a wrong value rather than a missing one.
    //
    // Two kinds rather than a flag on the node, so the exhaustive `switch` is forced to decide.
    // `clamp(none, VAL, none)` needs no kind at all -- simplification rewrites it to `VAL` for any
    // `val` whatever (`+Simplification.cpp:1007`) -- and is reported as `Operation`, so a change
    // that made it reachable declines instead of dropping a bound.
    ClampWithNoneMinimum,
    ClampWithNoneMaximum,
    // The last four, each carrying non-tree arguments that `childAt` cannot reach. What they need
    // beyond `CSSCalcSwiftNodeInfo` arrives in `CSSCalcSwiftOperationInfo` below, and their
    // `valueID` is `Op::id` -- `random`, `calc-mix`, `anchor`, `anchor-size` -- exactly as
    // `Function`'s is, so the four function names still cost nothing on the Swift side.
    //
    // `random( <random-key>? , <calc-sum>, <calc-sum>, <calc-sum>? )`. `childCount` is 2 or 3: the
    // `<random-key>` is not a `Child` at all.
    RandomFunction,
    // `calc-mix( [ <calc-sum> <percentage>? ]# )`. `childCount` is the item count; the per-item
    // weight is not a `Child`.
    CalcMixFunction,
    // `anchor( <anchor-element>? && <anchor-side>, <length-percentage>? )`. `childCount` counts the
    // `<anchor-side>` only when it is a `<percentage>` rather than a keyword, plus the fallback.
    AnchorFunction,
    // `anchor-size( [ <anchor-element> || <anchor-size> ]? , <length-percentage>? )`. `childCount`
    // is 1 when there is a fallback and 0 otherwise.
    AnchorSizeFunction,
};

// WHICH of `CSSCalc::Node`'s 41 variant alternatives the walk is standing on, exactly.
//
// A second discriminant beside `CSSCalcSwiftNodeKind`: the kind names the serialization shape
// (several operations share one, e.g. `min()` and `mod()` are both `Function`), but a rewriter
// must dispatch on the operation itself, which no amount of `valueID` inspection can do over a
// kind that lumps operations together.
//
// No existing WebCore enum serves this role: `CSSCalc::Operator` omits the seven leaves,
// `Deg2Rad`, `Anchor` and `AnchorSize`, and nothing in the tree maps an operation onto it;
// `ToCalculationTreeOp<Op>` is a type alias with the same gaps; `Style::Calculation`'s parallel
// tree declares no enum at all.
//
// So the numbering is the variant's own alternative index, read with `Node::index()` -- no switch,
// no table, nothing per-operation on either side of the boundary. Kept from drifting: the
// enumerator list and the pinning list are the same macro expansion
// (`CSS_CALC_SWIFT_FOR_EACH_ALTERNATIVE`); `numberOfCSSCalcSwiftAlternatives` counts that list
// rather than the last enumerator and is held equal to `std::variant_size_v<Node>`; and each
// pairing is pinned with `WTF::alternativeIndexV<T, Node>`, which rejects a duplicated alternative
// type.
//
// The second macro argument is the alternative's C++ type, inert in this header -- a macro body is
// not parsed until expanded -- which lets this self-contained header still name
// `IndirectNode<Sum>` for the translation unit that can.
#define CSS_CALC_SWIFT_FOR_EACH_ALTERNATIVE(macro) \
    macro(Number, Number) \
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

enum class CSSCalcSwiftAlternative : uint8_t {
#define CSS_CALC_SWIFT_DECLARE_ALTERNATIVE(name, type) name,
    CSS_CALC_SWIFT_FOR_EACH_ALTERNATIVE(CSS_CALC_SWIFT_DECLARE_ALTERNATIVE)
#undef CSS_CALC_SWIFT_DECLARE_ALTERNATIVE
};

// The length of the list above, counted from the list itself, not from the last enumerator.
#define CSS_CALC_SWIFT_COUNT_ALTERNATIVE(name, type) + 1
static constexpr uint8_t numberOfCSSCalcSwiftAlternatives = 0 CSS_CALC_SWIFT_FOR_EACH_ALTERNATIVE(CSS_CALC_SWIFT_COUNT_ALTERNATIVE);
#undef CSS_CALC_SWIFT_COUNT_ALTERNATIVE

// Which non-tree argument of an operation node an `appendOperationArgument` upcall should write.
//
// Declared in Swift as `CSSCalcSwiftOperationPart` and reaching C++ through
// WebCoreSwift-Generated.h, for the reason `CSSCalcSwiftLiteral` gives: Swift produces the choice
// and C++ consumes it, so the single declaration belongs on the producing side, and the switch in
// `appendOperationArgument` is over those *names*.

// Everything the four operation kinds below need that is neither a child subtree nor text, from
// one crossing.
//
// A second accessor rather than more fields on `CSSCalcSwiftNodeInfo`, because `info()` is called
// once per node on every walk of every calc() in every stylesheet, and these fields are meaningful
// for four rare kinds. Fetched only when the kind says so.
//
// Every field is a `bool` rather than a bit in a flags word. The flags spelling reads as
// `(info.flags & UInt8(Flag.randomSharingIsKey.rawValue)) != 0` on the Swift side, which is the
// kind of expression a transcription error hides in; these are a handful of bytes on an accessor
// that runs for `anchor()` and `random()` only.
//
// The one *presence* test that is not here is `CalcMix`'s per-item weight: it is per item rather
// than per node, so surfacing it needs a second per-index accessor beside `childAt`. Instead the
// `calcMixWeight` upcall writes `' '` and the weight when the item has one and nothing when it does
// not -- one crossing instead of two, at the cost of that presence decision staying in C++.
struct CSSCalcSwiftOperationInfo {
    // `Anchor`: the `<anchor-side>` keyword, when `anchorSideIsKeyword`.
    // `AnchorSize`: the `<anchor-size>` dimension keyword, when `hasDimension`.
    // `Random`: `property-scoped` or `property-index-scoped`, when `randomKeyHasPropertyScope`.
    // `CSSValueInvalid` otherwise, so a reader that consults it for the wrong kind gets a defined
    // wrong answer rather than garbage.
    uint16_t valueID;

    // `Random`: which alternative `sharing` holds. Both false means `auto`, which serializes as
    // omitted -- so there is no third flag, and the `else` case is `auto`.
    bool randomSharingIsKey;
    bool randomSharingIsFixed;
    // `Random` with a `<random-cache-key>`: which of the key's three optional parts are present.
    // The parser never produces an empty key, but this does not rest on that -- it writes the
    // separators from these three and an empty key would come out empty rather than wrong.
    bool randomKeyHasName;
    bool randomKeyIsElementScoped;
    bool randomKeyHasPropertyScope;

    // `Anchor`: whether `<anchor-side>` is a keyword. When false it is a `<percentage>` subtree and
    // occupies child 0, which is what makes the fallback's index depend on this.
    //
    // A `bool` rather than "`valueID` is `CSSValueInvalid`", so no sentinel value needs to be named
    // from the generated keyword table.
    bool anchorSideIsKeyword;

    // `Anchor` and `AnchorSize`: whether an `<anchor-element>` dashed-ident is present.
    bool hasElementName;
    // `AnchorSize`: whether an `<anchor-size>` dimension keyword is present.
    bool hasDimension;
    // `Anchor` and `AnchorSize`: whether a fallback `<length-percentage>` is present. Redundant
    // with `childCount` and kept anyway, for the reason the two `ClampWithNone...` kinds are kept:
    // the two are required to agree, and a mismatch is reported as a contract violation rather than
    // silently writing an argument in the wrong position.
    bool hasFallback;
};

// One node, described. A plain aggregate of trivial types, so it crosses in registers and needs no
// annotation and no lifetime -- there is nothing here that points at the tree.
//
// Each field is meaningful only for the kinds that carry it, and the unused ones are given inert
// values rather than left indeterminate (`CSSValueInvalid`, `CSSUnitType::Unknown`), so a Swift
// reader that consults the wrong field for a kind gets a defined wrong answer rather than garbage.
struct CSSCalcSwiftNodeInfo {
    // For the four numeric kinds: the node's `value`.
    double numericValue;
    // How many `Child`-typed children this node has, counting through `ChildOrNone` and
    // `std::optional<Child>` exactly as `forAllChildNodes` does -- so a `round()` with no second
    // argument reports one child, not two, and an absent one is never seen.
    //
    // A `ChildOrNone` holding `none` is therefore NOT counted, which is right and is why the two
    // `ClampWithNone...` kinds exist: the count stays the number of subtrees to walk, and the kind
    // says where the keyword goes. A `static_assert` in CSSCalcTree+Serialization.cpp holds `Clamp` to
    // being the only operation with a `ChildOrNone` at all, so no other kind can hide one.
    uint32_t childCount;
    // For Symbol, SiblingCount and SiblingIndex: the CSSValueID underlying value.
    // For Function and ProgressNoClampFunction: `Op::id`, the function's own name. For
    // RoundFunction: the ROUNDING STRATEGY's id, since the function name is always `round`.
    //
    // This field, and not a kind per operator, is what keeps the operator name table on the C++
    // side: an id is named here and `appendValueIDName` owns how it is spelled.
    uint16_t valueID;
    // For the four numeric kinds: `toCSSUnit(node)`, i.e. the CSSUnitType underlying value.
    // A unit *number* rather than a unit string, so a unit is named here and C++ owns how it is
    // spelled -- the unit table is generated and must not be transcribed into Swift.
    //
    // For a `Symbol`, `Symbol::unit` -- not the symbol table's unit. `simplify(Symbol&)` is
    // `makeNumeric(value->value, root.unit)` (CSSCalcTree+Simplification.cpp:516-524): the value
    // comes from `CSSCalcSymbolTable` and the unit from the node, which the parser took from
    // `CSSCalcSymbolsAllowed` (CSSCalcTree+Parser.cpp:1582). Those are two independently populated
    // `HashMap`s, so reading the unit off the table's answer instead would fold `Symbol{r, Deg}`
    // under an `{r -> 1px}` table into a length where the C++ makes an angle. Free in bytes: the
    // field existed and was inert for a `Symbol`.
    uint8_t unitType;
    // The discriminant. Typed as the enum rather than as a raw value, so the `switch` over it is
    // checked for exhaustiveness by the compiler.
    CSSCalcSwiftNodeKind kind;
    // For `Percentage`: the node's `hint`, as `Type::PercentHint`'s underlying value, and 0 for
    // none (`CSSCalcType.h:53` numbers `PercentHint` from 1 so that 0 is internal `None`). Inert
    // (0) for every other kind.
    //
    // Needed because `makeChildWithValueBasedOn(value, const Percentage&)` carries `hint` onto
    // the result (CSSCalcTree.cpp:318), so folding two percentages without it would produce a node
    // the C++ arm would not.
    //
    // Not free: the five fields above pack to exactly 16 bytes with no padding, so a seventeenth
    // byte takes the struct to 24 and moves the AArch64 return to an indirect `sret`. The
    // zero-cost alternative -- aliasing it onto `valueID`, inert for `Percentage` -- was rejected:
    // that gives a field two unrelated meanings on a boundary whose legibility is what keeps the
    // two arms in step.
    uint8_t percentHint;
    // Which of `Node`'s 41 alternatives this is, exactly -- see `CSSCalcSwiftAlternative`.
    //
    // Free: `percentHint` above already took the struct from 16 bytes to 24 (17 live bytes
    // rounding up to 24), leaving seven bytes of tail padding, so this is the eighteenth of
    // twenty-four and `sizeof` does not move -- held by CSSCalcTree+Serialization.cpp's
    // `static_assert(sizeof(CSSCalcSwiftNodeInfo) == 24)`.
    CSSCalcSwiftAlternative alternative;
};

// A borrowed cursor onto one node of a live CSSCalc::Tree.
//
// Always a `Child`, i.e. a subtree, which keeps this an 8-byte handle with nothing to
// discriminate. `clamp()`'s `none` bound is the one argument that is not a subtree, carried by
// the parent's *kind* rather than by a cursor that could point at something else -- see
// `CSSCalcSwiftNodeKind::ClampWithNoneMinimum`.
//
// `SWIFT_NONESCAPABLE` is the point: the handle borrows a node owned by a tree on the C++ stack,
// and `~Escapable` is what makes the compiler enforce that it cannot outlive the borrow.
//
// Three annotations are load-bearing: `SWIFT_SAFE` clears the residual unsafety of the private
// `const Child*` member, without which every call site needs an `unsafe` marker; the
// constructors' `@lifetime(immortal)` / `@lifetime(copy node)` are what make a method *returning*
// this type import at all, rather than being silently dropped; and `[[clang::lifetimebound]]` on
// `childAt`, prefix and nothing else, is the one of six lifetime spellings that imports without a
// #ClangDeclarationImport warning.
struct SWIFT_SAFE SWIFT_NONESCAPABLE CSSCalcSwiftNode {
    __attribute__((swift_attr("@lifetime(immortal)")))
    CSSCalcSwiftNode()
        : m_node(nullptr)
    {
    }

    __attribute__((swift_attr("@lifetime(copy node)")))
    CSSCalcSwiftNode(const Child* node [[clang::lifetimebound]])
        : m_node(node)
    {
    }

    CSSCalcSwiftNode(const CSSCalcSwiftNode&) = default;

    // Everything about this node, from one crossing.
    //
    // One call rather than five separate accessors (`kind`, `childCount`, `numericValue`,
    // `unitType`, `valueID`): each of those was a separate `WTF::switchOn` over the same
    // 41-alternative `Variant`, so splitting them would re-derive the same discriminant up to five
    // times per node to answer questions this answers together.
    WEBCORE_EXPORT CSSCalcSwiftNodeInfo info() const;

    // Everything the four operation kinds below need beyond `info()`, from one more crossing.
    //
    // Separate from `info()` rather than folded into it because `info()` runs for every node of
    // every tree, and this answers questions only four rare kinds ask. Called only when the kind
    // says to.
    WEBCORE_EXPORT CSSCalcSwiftOperationInfo operationInfo() const;

    // The `index`th child, IN SERIALIZATION ORDER.
    //
    // For `Sum` and `Product` that is not tree order: css-values-4 steps 6 and 7 both begin "Sort
    // root's children", and the sort key is `sortPriority`, a 60-case unit order generated with
    // `__COUNTER__` (CSSCalcTree+Serialization.cpp:146). Transcribing that table into Swift is
    // exactly the duplication this port is not allowed to do, and handing Swift a permutation to
    // apply would need a buffer the boundary would have to own. So C++ answers in the sorted order
    // it already computes, the same way it already answers `formatCSSNumberValue` -- a position is
    // named here and C++ owns what that position means. Every other kind answers in tree order,
    // because no other kind sorts.
    //
    // Linear, so a full walk is quadratic in the node count, and for Sum and Product it also
    // re-sorts per access. That is deliberate and priced rather than assumed: a calc expression's
    // tree is a handful of nodes (the deepest in the whole WPT css-values corpus is single digits),
    // and the alternative -- handing Swift a child *list* -- is either a buffer the boundary would
    // have to own or a second representation of the tree. If a measurement finds this costly, the
    // fix is an iterator handle, not a flattened array.
    WEBCORE_EXPORT CSSCalcSwiftNode childAt(uint32_t index) const [[clang::lifetimebound]];

    // The `index`th child, in tree order -- what `forAllChildNodes` yields, unsorted.
    //
    // A second accessor rather than a flag on `childAt`, because serialization needs the sorted
    // order for `Sum` and `Product` and simplification needs tree order for the same two: it
    // reconstructs the node from its children, and doing so in sort order would silently permute
    // every multi-unit sum in the document.
    //
    // `info().childCount` serves both orders, since sorting a `Sum`'s children permutes them
    // without adding or dropping any.
    //
    // `[[clang::lifetimebound]]`, prefix and nothing else, is the one spelling of six that imports
    // without a #ClangDeclarationImport warning.
    WEBCORE_EXPORT CSSCalcSwiftNode childInTreeOrder(uint32_t index) const [[clang::lifetimebound]];

private:
    // So that `appendOperationArgument` can reach the node it is being asked to write a piece of,
    // and so that the builder can reach the node it is being asked to copy or reconstruct. The
    // alternative -- a public accessor handing out the `Child*` -- would put a raw pointer in the
    // Swift-visible surface of a type whose whole point is that no pointer crosses.
    friend struct CSSCalcSwiftSink;
    friend struct CSSCalcSwiftBuilder;

    const Child* m_node;
};

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
struct SWIFT_SAFE CSSCalcSwiftSink {
    CSSCalcSwiftSink(WTF::StringBuilder& builder [[clang::lifetimebound]], const CSS::SerializationContext& context [[clang::lifetimebound]])
        : m_builder(&builder)
        , m_context(&context)
    {
    }

    // Every method is non-const, so the importer presents them as `mutating` and Swift takes the
    // sink `inout`. That is the honest shape: appending is a mutation.

    // One entry for every fixed spelling this emits, selected by `CSSCalcSwiftLiteral` -- declared
    // once, in Swift, and reaching C++ through WebCoreSwift-Generated.h. Ten fixed spellings
    // (`calc(`, `)`, `()`, `(`, ` + `, ` - `, ` * `, ` / `, `-1 * `, `1 / `) share this one entry and
    // a switch rather than ten named methods, so the numbering lives on the producing side and
    // there is no table of spellings to keep in sync on the Swift side.
    //
    // This converts a compile-time choice into a run-time one, but the C++ code it replaces already
    // made the same choice at run time -- `state.openGroup()` is a ternary returning one of two
    // `ASCIILiteral`s, read per node -- and no text crosses the boundary either way, so there is
    // still exactly one copy of every CSS literal in the program, and it is in C++.
    //
    // `uint8_t` rather than the imported enum type because this header is what the generated header
    // is generated *from*; it cannot see the Swift enum's C name.
    WEBCORE_EXPORT void appendLiteral(uint8_t literal);

    // Routes to CSS::serializationForCSS over a CSS::SerializableNumber, which is what the C++
    // serializer at CSSCalcTree+Serialization.cpp:589 does, so the two arms share one
    // number-formatting implementation by construction rather than by comparison.
    WEBCORE_EXPORT void appendNumber(double value, uint8_t unitType);

    // `nameLiteralForSerialization(CSSValueID)`, for Symbol, SiblingCount and SiblingIndex. The
    // id is named here; C++ owns the table, which is generated and must not be transcribed.
    WEBCORE_EXPORT void appendValueIDName(uint16_t valueID);

    // A second upcall for arguments that are CSS values rather than calculation trees, and every
    // one of them must be spelled by C++.
    //
    // `<dashed-ident>` goes through `CSS::serializationForCSS` over a `CSS::CustomIdent`;
    // `random()`'s `fixed <number>` and `calc-mix()`'s weight are `PrimitiveNumeric` types the C++
    // serializer hands to `CSS::serializationForCSS` directly. Routing them through `appendNumber`
    // instead would mean deciding in Swift that they are plain doubles in a known unit, a claim
    // about types Swift cannot see.
    //
    // One entry selected by `part` rather than four named methods, for the reason `appendLiteral`
    // gives. `index` is meaningful only for `calcMixWeight`, where it selects the item.
    //
    // Taken by `const&`, which is load-bearing: by value this method imports as `unsafe`, because
    // the sink's struct-level `SWIFT_SAFE` does not reach a parameter that is itself
    // `~Escapable`. By const reference: zero `unsafe`.
    WEBCORE_EXPORT void appendOperationArgument(const CSSCalcSwiftNode&, uint8_t part, uint32_t index);

private:
    WTF::StringBuilder* m_builder;
    const CSS::SerializationContext* m_context;
};

// What the serialization walk did, and what it saw doing it.
//
// `outcome` is the gate's answer: 0 serialized, 1 declined. The other two fields make the walk
// observable rather than something a test has to take on trust: a decline is otherwise invisible,
// since it reads as parity by comparing the C++ against itself, and so is a walk that never
// descended. `nodeCount` and `kindMask` come back from the same traversal that made the decline
// decision, cost nothing (three registers), and let a test assert that the tree was really walked
// and that every kind it expected to reach was reached.
//
// A plain aggregate of trivial types, so it crosses in registers and needs no annotation.
struct CSSCalcSwiftSerializationResult {
    // Bit `1 << rawValue` set for each CSSCalcSwiftNodeKind the walk stood on.
    uint32_t kindMask;
    // How many nodes the walk visited, root included.
    uint32_t nodeCount;
    // 0 = serialized, 1 = declined. Not a `bool`, so adding a third outcome later is not an ABI
    // change; the numbering is pinned by static_assert against the Swift enum.
    uint8_t outcome;
};

// MARK: - The Swift calc simplification path (CSSCalcSimplificationSwift.swift)
//
// Shares `CSSCalcSwiftNode`, `CSSCalcSwiftNodeInfo` and `CSSCalcSwiftNodeKind` with the
// serialization boundary above, and adds the half that did not exist: a way for Swift to
// construct nodes.
//
// The constraint that shapes all of it: no operation kind ever crosses in the construction
// direction. The output node's kind is, with one exception, the input node's kind, so
// `rebuildFrom` recovers it from the original node's own variant tag and reconstructs generically
// over the tuple conformance. The exception is `clamp()` becoming `min()` or `max()`
// (CSSCalcTree+Simplification.cpp:1012-1038), handled by `buildMinMax` alone.

// A numeric leaf to build, in the one representation the boundary has for one.
//
// `CanonicalDimension::Dimension` is not carried; it is recovered from `unitType` by `makeNumeric`
// (CSSCalcTree.cpp:187), the same function that classifies a `CSSUnitType` for every other producer
// in the tree, so this reuses that classification rather than restating it -- there is no second
// place where "Dppx means Resolution" is written down. The forward direction is `toCSSUnit`
// (CSSCalcTree.h:992), which is what `info().unitType` reports, so a leaf read out and pushed
// straight back round-trips through those two.
//
// That round trip is not `static_assert`-able: `toCSSUnit` is `constexpr` but `makeNumeric` is an
// out-of-line switch in a .cpp, so a `static_assert` here could only restate `toCSSUnit`'s own
// header and would pass whatever `makeNumeric` did. It is checked instead by round-tripping every
// numeric leaf in the test corpus.
struct CSSCalcSwiftLeaf {
    double value;
    // A `CSSUnitType` underlying value. Widened from the `uint8_t` `CSSCalcSwiftNodeInfo` uses --
    // `CSSUnitType` is `enum class : uint8_t` -- purely because it costs nothing: this struct pads
    // to 16 bytes either way.
    uint16_t unitType;
    // A `CSSCalcSwiftNodeKind`, restricted to the four numeric leaves: `Number`, `Percentage`,
    // `CanonicalDimension`, `NonCanonicalDimension`. It selects which alternative gets built for
    // the one case `unitType` cannot answer -- `Percentage`, which needs the hint below -- and
    // everything else routes through `makeNumeric`. A kind outside those four is a contract
    // violation and `pushLeaf` reports it rather than guessing.
    uint8_t kind;
    // `Type::PercentHint`'s underlying value, 0 for none, exactly as `CSSCalcSwiftNodeInfo` carries
    // it. Meaningful only when `kind` is `Percentage`.
    uint8_t percentHint;
};

// A `double` and a `CSSUnitType`, or nothing.
//
// One type for both of the builder's lookups -- the symbol table and unit canonicalization --
// because both answer exactly that shape, and one boundary type is one fewer thing that can drift.
// Returned by value rather than through an out-parameter, so no reference crosses in the argument
// position at all: at 16 bytes it comes back in registers, with no `inout` import to reason about.
struct CSSCalcSwiftNumericResult {
    double value;
    // A `CSSUnitType` underlying value. Inert (`CSSUnitType::Unknown`) when `resolved` is false.
    //
    // For `resolveSymbol` this is `toCSSUnit` of the leaf `makeNumeric` built, not the unit that was
    // asked about, so that `Integer` comes back as `Number` and the round trip back through
    // `pushLeaf` -- which calls `makeNumeric` again -- lands on the same alternative. For
    // `resolveRelativeLength` it is `toCSSUnit(canonical->dimension)`, which for a resolved relative
    // length is always `CSSUnitType::Px`.
    uint16_t unitType;
    // False means "no answer", which for both lookups is a normal outcome and not an error: an
    // unresolved `<calc-keyword>` and a `1em` with no conversion data both simply stay as they are.
    bool resolved;
    // Which of the four numeric alternatives `makeNumeric` built, so the caller does not have to
    // work it out. Keeps `makeNumeric`'s seventy-case unit table out of Swift:
    // `simplify(Symbol&)` is `copyAndSimplify(makeNumeric(value, root.unit), options)`, and the
    // folded leaf's alternative has to be reported to its parent. Reproducing `makeNumeric`'s
    // choice in Swift would duplicate the table, so C++ answers from `makeNumeric` itself.
    //
    // Free in bytes: 8 + 2 + 1 + 1 = 12 live bytes in a struct that aligns to 8, so `sizeof` was
    // 16 before this field and is 16 after, held by the `static_assert` below.
    //
    // Inert (`Number`) when `resolved` is false. `canonicalizeUnit` always answers
    // `CanonicalDimension` when it resolves, by construction, and fills it there anyway.
    CSSCalcSwiftAlternative alternative;
};

// 8 + 2 + 1 + 1 = 12 live bytes, aligned to 8. See `alternative` above: this is the assert that
// makes "the field is free" a check rather than a claim.
static_assert(sizeof(CSSCalcSwiftNumericResult) == 16);

// The parts of `CSSCalc::SimplificationOptions` Swift reads, from one crossing.
//
// A plain aggregate of trivial types. The three things `SimplificationOptions` actually holds that
// are not trivial -- `conversionData`, `symbolTable`, and the `CSS::Category` enum -- stay on the
// C++ side, and each is here in the reduced form Swift needs rather than as itself.
struct CSSCalcSwiftSimplificationOptions {
    // `options.range.min` and `options.range.max`. Two doubles rather than a `CSS::Range`, for the
    // reason the serialization entry gives: `clampValue` reads only those two, and the two
    // `RangeParseTimeBehavior` members are the parser's.
    double rangeMinimum;
    double rangeMaximum;
    // `CSS::Category`'s underlying value. Carried for completeness -- the `switch` on it in Swift
    // is the predicate below -- and inert for everything else.
    uint8_t category;
    // `options.allowZeroValueLengthRemovalFromSum`. `simplify(Sum&)` reads it at
    // CSSCalcTree+Simplification.cpp:611, and `isLengthUnit` below is the other half of that one
    // site. Not a rare flag -- four production callers set it.
    bool allowZeroValueLengthRemovalFromSum;
    // Whether `options.conversionData` holds a value. Swift cannot be given
    // `CSSToLengthConversionData` and does not need it: every use of it is inside
    // `resolveRelativeLength` and the two sibling-function upcalls. `resolveRelativeLength`
    // answering `resolved == false` already says whether a canonicalization could succeed, so this
    // bool exists for the two sibling-function upcalls.
    bool hasConversionData;
    // Precomputed in C++ deliberately: it is `percentageResolveToDimension(options)`
    // (CSSCalcTree+Simplification.cpp:80-101), an eleven-case `switch` over `CSS::Category` that is
    // true for exactly two of them (`AnglePercentage`, `LengthPercentage`). Deriving it once here is
    // one `bool`; deriving it in Swift would mean the eleven-case `CSS::Category` enum crossing the
    // boundary as a thing Swift switches over -- a second copy of a category table for a predicate
    // whose whole content is "is it one of these two". `category` still crosses so a later change
    // needing the category itself does not have to widen this struct, but nothing reads it yet.
    bool percentageResolveToDimension;
};

// Where the simplification output goes: the construction sink.
//
// Modelled on `CSSCalcSwiftSink` above: a `SWIFT_SAFE` value struct taken `inout` (the builder
// lives on the C++ stack for exactly one `copyAndSimplify` call, so a refcounted one would cost a
// heap allocation per call); every `CSSCalcSwiftNode` parameter by `const&`, never by value; one
// entry rather than N named methods wherever a selector can carry the choice; and anything whose
// exact output must match the C++ arm stays an upcall.
//
// It is an operand stack, not a node factory. Swift walks the tree post-order and pushes each
// finished subtree; a parent then says how many operands it consumes and gets one back, which is
// what lets `rebuildFrom` be generic and keeps `~Escapable` out of the picture -- no Swift
// container ever holds a `Child`, because the container is the C++ stack.
struct SWIFT_SAFE CSSCalcSwiftBuilder {
    CSSCalcSwiftBuilder(CSSCalcSwiftOperandStack& operands [[clang::lifetimebound]], const SimplificationOptions& options [[clang::lifetimebound]])
        : m_operands(&operands)
        , m_options(&options)
    {
    }

    // Build one of the four numeric leaves and push it. See `CSSCalcSwiftLeaf`.
    //
    // Returns false for a `kind` outside the four numeric leaves, which is a contract violation
    // rather than an input that can be met, declining rather than building something plausible.
    WEBCORE_EXPORT bool pushLeaf(CSSCalcSwiftLeaf);

    // Deep-copy an input subtree and push it. Used for every node walked past without changing,
    // and for every child of a node that is declined for rewriting.
    //
    // Routes to `CSSCalc::copy(const Child&)`, which is the copy the C++ arm's own
    // `copyAndSimplifyChildren` bottoms out in, so the two arms cannot disagree about what a copy
    // is. That overload had to be DECLARED for this -- CSSCalcTree+Copy.h exposed only `Tree` and
    // `AnchorSide`, while `Child` was one of ten `static` overloads inside CSSCalcTree+Copy.cpp --
    // which is one line of header and the removal of one `static`, and is the smallest thing that
    // works. Nothing new was written.
    WEBCORE_EXPORT void pushCopyOf(const CSSCalcSwiftNode&);

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
    // Returns false, reported as a decline, for a contract violation: too few operands, a
    // mismatched arity, or a leaf.
    //
    // `Anchor` and `AnchorSize` are served by two hand-written cases rather than by the tuple
    // conformance -- they declare `tuple_size` 0 (CSSCalcTree.h:1317, "FIXME webkit.org/b/280798"),
    // so `WTF::apply` yields no slots. `copyAndSimplifyChildren`'s own two overloads
    // (`+Simplification.cpp:1795`-`:1807`) take `elementName`, `side` and `dimension` off the
    // original exactly as they do, with the fallback taken from the cursor, so the two arms cannot
    // disagree about the non-fallback parts of the node. This does not fix the FIXME: doing so
    // would change what `forAllChildNodes` yields for every other caller, including simplification
    // and the computed-style-dependency walk.
    WEBCORE_EXPORT bool rebuildFrom(const CSSCalcSwiftNode& original, uint32_t childCount);

    // Pop `childCount` operands and push a FRESH `min()` or `max()` built from them.
    //
    // The only operation kind simplification ever creates that was not already in the input, and
    // the only reason a construction selector exists at all: `clamp(none, VAL, MAX)` rewrites to
    // `min(VAL, MAX)` and `clamp(MIN, VAL, none)` to `max(MIN, VAL)`
    // (CSSCalcTree+Simplification.cpp:1012-1038). A `bool` rather than a kind, because two is the
    // whole set and naming it `CSSCalcSwiftNodeKind::Min` would reopen exactly the door principle
    // one closes.
    //
    // Unlike `rebuildFrom` this computes a FRESH `toType(...)`, because there is no original node
    // of this kind to take one from -- which is also why it can fail for a reason that is not a
    // contract violation: `toType` returns `std::nullopt` when the children's types do not merge,
    // and the C++ arm returns `std::nullopt` from the rewrite in exactly that case. So false here
    // means "the C++ would not have made this node either", so this must decline rather than
    // treat it as impossible.
    WEBCORE_EXPORT bool buildMinMax(bool isMax, uint32_t childCount);

    // `simplify(Symbol&)` (CSSCalcTree+Simplification.cpp:516-524) in full --
    // `makeNumeric(options.symbolTable.get(id)->value, unit)`.
    //
    // In C++ because the table is a `HashMap<CSSValueID, ...>` living on the options, and a hash
    // map is not reducible to a POD. Both the value and the unit have to cross: the value is the
    // table's, the unit is the symbol node's (`Symbol::unit`, read from `info().unitType`), and
    // the two come from independently populated `HashMap`s -- taking the unit from the table's
    // answer instead would fold `Symbol{r, Deg}` under an `{r -> 1px}` table into a length where
    // the C++ makes an angle.
    //
    // The `unit` parameter is what lets the answer carry `alternative`: classifying a unit in
    // Swift would mean transcribing `makeNumeric`'s seventy cases.
    WEBCORE_EXPORT CSSCalcSwiftNumericResult resolveSymbol(uint16_t valueID, uint16_t unit) const;

    // `Style::resolveLength(value, *CSS::toLengthUnit(unit), *conversionData)`, which is
    // `canonicalize`'s `tryMakeCanonical` (CSSCalcTree+Simplification.cpp:181-:187).
    //
    // Forty-two of `canonicalize`'s seventy cases: the font-, viewport- and container-relative
    // lengths. The other twenty-eight are decided in Swift -- fourteen multiply by a `constexpr
    // double`, and fourteen can never reach a `NonCanonicalDimension` at all.
    //
    // These forty-two stay in C++ because `Style::resolveLength` needs
    // `CSSToLengthConversionData`, which carries a `RenderStyle`, a font cascade with realised
    // metrics, and a viewport -- not reducible to anything that crosses a POD boundary. They are
    // never named on the Swift side either: the `switch` in Swift names the twenty-eight it
    // decides and this upcall is its `default` arm, so the membership set exists exactly once,
    // here, where it always did.
    //
    // The answer is `nullopt` -- `resolved == false` -- exactly when the C++ returns `nullopt`,
    // which for these units means "no conversion data", and the dimension is left alone.
    // `alternative` is still reported for the reason `CSSCalcSwiftNumericResult::alternative` gives.
    WEBCORE_EXPORT CSSCalcSwiftNumericResult resolveRelativeLength(double value, uint16_t unitType) const;

    // `isLength(toNumericIdentity(...))` (CSSCalcTree+NumericIdentity.h:215), which
    // `simplify(Sum&)` reads at CSSCalcTree+Simplification.cpp:611 to decide whether a zero-valued
    // term can be dropped from a sum.
    //
    // In C++ because the answer is a 48-of-64 membership set over a generated unit enum, and
    // transcribing it in either direction would be a duplicated table. A Swift denylist of the
    // eight non-length non-canonical units (`Rad`, `Grad`, `Turn`, `Ms`, `Khz`, `X`, `Dpi`,
    // `Dpcm`) was rejected: a new angle or time unit added to `CSSUnitType` would then be silently
    // classified as a length and removed from every sum with a zero of it. A `bool isLength` field
    // on `CSSCalcSwiftNodeInfo` was rejected on cost: `info()` runs for every node of every tree,
    // and this would add a 56-case switch to answer a question only one operation asks.
    //
    // Not on any hot path: three of the four numeric kinds are decided in Swift from `unitType`
    // alone, so this is reached only for a `NonCanonicalDimension` term whose value is exactly
    // zero with `allowZeroValueLengthRemovalFromSum` set. `calc(0em + 1px)` reaches it; nothing
    // else does.
    WEBCORE_EXPORT bool isLengthUnit(uint16_t unitType) const;

private:
    CSSCalcSwiftOperandStack* m_operands;
    const SimplificationOptions* m_options;
};

// What the simplification walk did, and what it saw doing it. Mirrors
// `CSSCalcSwiftSerializationResult` field for field except in the width and the key of the mask,
// which is the one place the two results deliberately differ; see `kindMask`.
//
// `nodeCount` and `kindMask` exist to catch a vacuous pass. A whole-tree decline is otherwise
// invisible in an output comparison, since the C++ answer for a declined tree is the same C++
// answer the comparison already trusts, and so is a walk that agreed because it never descended.
// These two come back from the same traversal that made the decline decision, cost three
// registers, and let a test assert that the tree was really walked and that every kind it claims
// coverage of was really reached.
struct CSSCalcSwiftSimplificationResult {
    // Bit `1 << rawValue` set for each `CSSCalcSwiftAlternative` the walk stood on -- 41 bits, so
    // `uint64_t`.
    //
    // Keyed on the alternative, not on the kind, because a mask over the 23-case
    // `CSSCalcSwiftNodeKind` cannot express the decline expectation at all: `min()` and `mod()`
    // share the `Function` kind, one handled and one declined, so
    // `expectedDecline = (inputKindMask & ~handledMask) != 0` is not writable over a mask whose
    // bits lump the two together. Over the alternative index it is exact, over the whole corpus
    // rather than a hand-labelled subset.
    //
    // `CSSCalcSwiftSerializationResult::kindMask` is deliberately not changed to match: its
    // question is "which serialization shapes did the walk stand on", and 23 kinds in 32 bits
    // answers that. Two results, two questions.
    uint64_t kindMask;
    // How many nodes the walk visited, root included.
    uint32_t nodeCount;
    // 0 = simplified, 1 = declined. Not a `bool`, so a third outcome is not an ABI change; the
    // numbering is pinned by static_assert in CSSCalcTree+Simplification.cpp against the Swift
    // enum that declares it.
    uint8_t outcome;
    // Which alternative caused a decline -- a `CSSCalcSwiftAlternative` raw value, or 0xFF for
    // "did not decline" and for "declined without one alternative to blame".
    //
    // An unattributed decline is one nobody can close, which is the argument for the field: without
    // it, a test can only say a decline happened; with it, a test can check the reason against one
    // derived independently -- `(inputKindMask & ~handledMask)` must contain this bit -- so a
    // decline for the wrong reason stops passing.
    //
    // Free in bytes: 8 + 4 + 1 + 1 = 14 in a 16-byte struct, so it rides in existing padding and
    // the result still comes back in registers.
    uint8_t declineAlternative;
};

} // namespace CSSCalc
} // namespace WebCore
