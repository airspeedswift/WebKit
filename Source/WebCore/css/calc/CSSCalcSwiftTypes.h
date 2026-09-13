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
// CSSCalcRandomSharing.h, wtf/Vector.h and wtf/TZoneMalloc.h.
//
// This note used to give a second reason: that it avoided an importer defect where the `Variant`
// member's destructor is odr-used over incomplete `UniqueRef<Op>` alternatives. THAT REASON WAS
// WRONG and has been removed. The defect is real (rdar://186742920) but is specific to
// `std::variant`; `WTF::Variant` is MPark.Variant and imports cleanly, and CSSCalcTree.h now
// carries the `#if !defined(__swift__)` stand-in for `Child::value` and imports with 0 errors and
// 0 warnings. The self-containment reason above is the one that still holds.
//
// The recursive walk and the sink below import with 0 errors, 0 warnings and 0 `unsafe` markers.
//
// EVERY FUNCTION SWIFT CALLS HERE IS `noexcept`, AND THAT IS NOT DECORATION. Swift emits a
// termination landing pad around each call to a C++ function whose declaration permits an exception:
// measured on a two-function probe under this project's real interop flags
// (`cssprobe/trapcensus/noexceptprobe/`), a throwing and a `noexcept` callee compile to
// instruction-for-instruction identical code except for the throwing arm's trailing `brk #0x1`. At
// the census taken before these keywords were added, that cost the simplification island 62 `brk`s,
// two of which were reachable *conditionally* -- the `bl; cbz; brk` around the zero-length-removal
// upcall that has since been retired -- and so were live trap conditions rather than pure size.
//
// Why the annotation is correct rather than a hazard, which is the direction that matters, since
// `noexcept` over something that can throw converts an exception into `std::terminate`:
//
//   1. Every definition below lives in a WebCore translation unit, and WebCore is compiled
//      `-fno-exceptions` (`Source/WebCore/Configurations/Base.xcconfig:63`,
//      `GCC_ENABLE_CPP_EXCEPTIONS = NO`; the flag is on the real compile line, reached through the
//      per-target `*-common-args.resp` response file). A `throw` expression is therefore ill-formed
//      in these translation units, and libc++'s `_LIBCPP_THROW` aborts rather than throwing.
//   2. The one thing that would otherwise throw is allocation, and WebKit's allocators do not:
//      `Vector`'s growth, `makeUniqueRef` and TZone all `CRASH()` on failure rather than raising
//      `std::bad_alloc`.
//   3. The residual hazard `-fno-exceptions` does not cover is an Objective-C `@throw` unwinding
//      *through* one of these frames, so it is checked per function rather than assumed. The
//      deepest call graphs here are `resolveRelativeLength` (`CSS::toLengthUnit`, then
//      `Style::resolveLength`, whose relative units read a realised font cascade) and
//      `resolveStyleCoupledValue` (`Style::AnchorPositionEvaluator::evaluateSize`, `Style::toStyle`,
//      the sibling-count/index resolvers and `simplify(Random&)`); every frame in them is C++, and
//      the rest of this header's functions do nothing but read POD fields off a `Child` or push onto
//      a `Vector`. And in the direction that matters for safety, an Objective-C exception crossing a
//      `-fno-exceptions` frame already has no cleanup and is undefined today: `noexcept` turns that
//      into a deterministic `std::terminate`, which is not a regression.
//
// So the keyword records a fact the build already guarantees, and its only effect is to let Swift
// stop generating a pad for a path that cannot exist. Note that `noexcept` is not part of the
// Itanium mangling of these symbols, so no exported name changes.

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

// Forward declaration only, so this header stays self-contained. The sink writes into a builder
// that C++ owns; Swift never sees StringBuilder's definition and never needs to.
namespace WTF {
class StringBuilder;
}

namespace WebCore {

// Forward declaration only, for the same reason as StringBuilder above: the parse cursor holds a
// reference to one and Swift never sees its definition, which is what keeps CSSTokenizer.h and its
// includes out of this header.
class CSSParserTokenRange;

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
    // The last four, each carrying non-tree arguments no child index can reach. What they need
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
// no table, nothing per-operation on either side of the boundary.
//
// This list is the ONLY copy. `CSSCalc::Node`'s `Variant<...>` is generated from it in
// `CSSCalcTree.h`, so the enumerator order and the alternative order cannot diverge: divergence is
// not expressible rather than merely asserted against. `numberOfCSSCalcSwiftAlternatives` counts
// the list rather than reading the last enumerator, and is held equal to `WTF::VariantSizeV<Node>`;
// each pairing is still pinned with `WTF::alternativeIndexV<T, Node>` in
// `CSSCalcTree+Serialization.cpp`, kept deliberately now that it is redundant, because
// `init?(rawValue:)` on an imported C++ enum never fails -- a wrong raw value would reach Swift as
// a valid case rather than as nil, so the only place it can be caught is at compile time.
//
// The second macro argument is the alternative's C++ type, inert in this header -- a macro body is
// not parsed until expanded -- which is what lets this self-contained boundary header own a list
// naming `IndirectNode<Sum>` for the translation unit that can see it.
//
// Split into FIRST and REST because a `Variant<...>` template argument list cannot carry a trailing
// comma: `CSSCalcTree.h` emits the first alternative bare and each of the rest comma-prefixed.
// Every other consumer expands the whole list and does not care.
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

// The length of the list above, counted from the list itself, not from the last enumerator.
#define CSS_CALC_SWIFT_COUNT_ALTERNATIVE(name, type) + 1
static constexpr uint8_t numberOfCSSCalcSwiftAlternatives = 0 CSS_CALC_SWIFT_FOR_EACH_ALTERNATIVE(CSS_CALC_SWIFT_COUNT_ALTERNATIVE);
#undef CSS_CALC_SWIFT_COUNT_ALTERNATIVE

// The math functions whose only slot is one `Child`: the ten one-argument functions of
// <calc-value>, plus the `Deg2Rad` wrapper the parser inserts around an <angle> argument to
// sin/cos/tan, which has no syntax of its own and can only ever appear inside those three.
//
// A LIST RATHER THAN ELEVEN TRANSCRIBED SWITCH ARMS, because every consumer of it does the same
// thing to each name and the slot shape is what they have in common: `buildOperation` fills the
// one slot from the one operand, and the arity check and the construction are written once. Adding
// a twelfth of the same shape is one line here and none anywhere else, and one of a DIFFERENT shape
// fails to compile at `buildOperation`'s `static_assert` rather than being silently filled.
//
// `Negate` and `Invert` have this slot shape too and are deliberately NOT in the list: they are
// arithmetic rather than math functions, they were served before stage E2, and the widening that
// rerouted already-served alternatives onto new machinery is the one that measured +7.78 %.
//
// Grouped by the type rule the grammar applies to each -- trig, arc-trig, then the four that share
// no rule with a neighbour -- because that is the only other axis anything reads them along.
#define CSS_CALC_SWIFT_FOR_EACH_UNARY_MATH_FUNCTION(macro) \
    macro(Deg2Rad) \
    macro(Sin) macro(Cos) macro(Tan) \
    macro(Asin) macro(Acos) macro(Atan) \
    macro(Sqrt) macro(Exp) macro(Abs) macro(Sign)

// The math functions whose slots are one `Child` and one `std::optional<Child>`: `round()`'s four
// rounding strategies and `log()` (P7b stage E4).
//
// `round()` IS FOUR ALTERNATIVES, NOT ONE WITH A MODE. `consumeRound` selects among four template
// instantiations on the `<rounding-strategy>` keyword (`CSSCalcTree+Parser.cpp:668`-`:679`) and
// `CSSCalcSwiftAlternative` already carries all four, so the keyword costs the boundary nothing.
//
// NEITHER DOES THE OPTIONAL SLOT. Its two states are separated by the OPERAND COUNT with nothing
// left over -- `round(X)` pushes one and `round(X, Y)` two -- which is `rebuildSlot(const
// std::optional<Child>&)`'s own rule at `CSSCalcTree+Simplification.cpp:2098`. That is what makes
// this list a widening of an existing entry rather than a second `noneMask`.
#define CSS_CALC_SWIFT_FOR_EACH_OPTIONAL_SECOND_MATH_FUNCTION(macro) \
    macro(RoundNearest) macro(RoundUp) macro(RoundDown) macro(RoundToZero) \
    macro(Log)

// The math functions whose slots are a FIXED NUMBER of plain `Child`s, two or three (P7b stage E5):
// `mod` `rem` `atan2` `pow`, and `progress()`'s two alternatives.
//
// ONE LIST FOR BOTH ARITIES, because `buildOperation` fills them from
// `std::make_index_sequence<std::tuple_size_v<Op>>` and the arity is therefore not something the
// list has to say -- the variant declaration already says it. A seventh of either arity costs one
// line here; one with a slot that is not a `Child` fails to compile at the `static_assert`.
//
// `no-clamp` SELECTS THE ALTERNATIVE, as `round()`'s strategy does: `consumeProgress` picks between
// two template instantiations (`CSSCalcTree+Parser.cpp:906`-`:908`), so the keyword costs the
// boundary nothing here either.
#define CSS_CALC_SWIFT_FOR_EACH_FIXED_ARITY_MATH_FUNCTION(macro) \
    macro(Mod) macro(Rem) macro(Atan2) macro(Pow) \
    macro(Progress) macro(ProgressNoClamp)

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
// than per node, so it needs a per-index accessor, which is `swiftCalcMixItemWeight`.
// The presence test, the `Raw`/`Calc` test and the value all cross now, because `simplify(CalcMix&)`
// does arithmetic on the weights and produces new ones. The serialization upcall is unchanged and
// still writes the separator and number in C++ without needing any of them.
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

// One `CalcMix` item's weight: a `<percentage [0,100]>` that may be absent, may be a `Raw`
// number, or may be a whole nested `calc()`.
//
// Three states in two bools rather than a three-case enum, because the two questions are asked
// separately: spec step 1 counts the absent ones, and the `canNormalize` guard at
// CSSCalcTree+Simplification.cpp:1509 rejects the `Calc` ones.
//
// `isRaw` is the only thing learned about a `Calc` weight. `value` is zero, not indeterminate,
// when the weight is absent or a `Calc`: a reader that consults it for the wrong state gets a
// defined wrong answer rather than garbage, and it is not a usable stand-in for either state,
// since a `Calc` weight can evaluate to anything and `isKnownZero()` (CSSPrimitiveNumeric.h:142)
// is `isRaw() && value == 0`.
struct CSSCalcSwiftCalcMixWeight {
    double value;
    bool present;
    bool isRaw;
};

// 8 + 1 + 1 = 10 live bytes aligned to 8, so this comes back in registers exactly as
// `CSSCalcSwiftNumericResult` does. The assert is what makes that a check rather than a claim.
static_assert(sizeof(CSSCalcSwiftCalcMixWeight) == 16);

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

// MARK: - Reading a node
//
// Four free readers over a borrowed `CSSCalc::Child`. Together with `Child::operator[]`, which
// gives Swift a checked borrow of a child (CSSCalcTree.h says why it must stay an operator), and
// `Child::childCount()`, which bounds the loop, this is the whole reading surface of both calc
// islands. There is no cursor type: a node is a `Child` on both sides.
//
// A `const Child&` PARAMETER is safe to Swift, unlike a `const Child&` RETURN: only the return
// position imports as `UnsafePointer`. And every return here is a POD by value, which is
// unrestricted. So none of this needs an annotation, a handle type or an `unsafe` marker.
//
// `Child` is incomplete in this header, deliberately -- it stays self-contained and does not
// include CSSCalcTree.h. That is fine for a parameter; it is only an incomplete RETURN type that
// makes the importer drop a declaration.
WEBCORE_EXPORT CSSCalcSwiftNodeInfo swiftNodeInfo(const Child&) noexcept;
WEBCORE_EXPORT CSSCalcSwiftOperationInfo swiftOperationInfo(const Child&) noexcept;
WEBCORE_EXPORT CSSCalcSwiftCalcMixWeight swiftCalcMixItemWeight(const Child&, uint32_t index) noexcept;

// There is deliberately NO child-order entry point here. Serialization order differs from tree
// order only for `Sum` and `Product`, and CSSCalcSerializationSwift.swift's `sortPriority` computes
// it from the `unitType` `swiftNodeInfo` already reports. The entry point that used to answer it
// regenerated the whole permutation per access, which measured as the entire width-dependent
// serialization gap; see notes/calc-c2-serialization-band-and-refutation-0911.md.

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
//     `trySerializeWithSwiftIsland` (CSSCalcTree+Serialization.cpp) -- from that function's own
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
    WEBCORE_EXPORT void appendLiteral(uint8_t literal) noexcept;

    // Routes to CSS::serializationForCSS over a CSS::SerializableNumber, which is what the C++
    // serializer at CSSCalcTree+Serialization.cpp:589 does, so the two arms share one
    // number-formatting implementation by construction rather than by comparison.
    WEBCORE_EXPORT void appendNumber(double value, uint8_t unitType) noexcept;

    // `nameLiteralForSerialization(CSSValueID)`, for Symbol, SiblingCount and SiblingIndex. The
    // id is named here; C++ owns the table, which is generated and must not be transcribed.
    WEBCORE_EXPORT void appendValueIDName(uint16_t valueID) noexcept;

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
    // The node itself rather than a cursor onto it, for the reason the four readers above give: a
    // `const Child&` parameter is safe to Swift and needs no annotation, where a `const Child&`
    // return would not be.
    WEBCORE_EXPORT void appendOperationArgument(const Child&, uint8_t part, uint32_t index) noexcept;

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
// Shares the four free readers, `CSSCalcSwiftNodeInfo` and `CSSCalcSwiftNodeKind` with the
// serialization boundary above, and adds the half that did not exist: a way for Swift to
// construct nodes.
//
// The constraint that shapes all of it: no operation kind ever crosses in the construction
// direction. The output node's kind is, with one exception, the input node's kind, so
// `rebuildFrom` recovers it from the original node's own variant tag and reconstructs generically
// over the tuple conformance. The exception is `clamp()` becoming `min()` or `max()`
// (CSSCalcTree+Simplification.cpp:1012-1038), handled by `buildOperation` alone.

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

    // A third state, needed because `resolved == false` is ambiguous for `anchor()` and
    // `anchor-size()` in a way it is not for any other user of this struct. Every other lookup
    // here has two outcomes -- an answer, or "leave the node alone" -- but the two anchor
    // functions have three (`+Simplification.cpp:1692`-`:1744`), and the two that both report
    // `resolved == false` produce different trees:
    //
    //   - no conversion data or no builder state: the opening guard returns `{ }`, and
    //     `copyAndSimplify` rebuilds the node with its simplified fallback still on it.
    //     `substituteFallback == false`.
    //   - the evaluation answered nothing: the C++ reached `std::exchange(node.fallback, { })`, so
    //     the node is replaced by its fallback, or the property is marked invalid at
    //     computed-value time if it had none. `substituteFallback == true`.
    //   - it resolved to a `CanonicalDimension` length. `resolved == true`.
    //
    // Swift cannot derive the middle case, since `CSSCalcSwiftSimplificationOptions` carries only
    // `hasConversionData`, not whether a `Style::BuilderState` hangs off it, so it is reported
    // rather than reconstructed. Which rebuild path to take is `info.hasFallback`, already on the
    // boundary.
    //
    // Free in bytes: 12 live bytes became 13 in a struct that aligns to 8, so `sizeof` is 16
    // before and after, held by the `static_assert` below.
    //
    // False for every lookup but the two anchor ones, and mutually exclusive with `resolved`.
    bool substituteFallback;
};

// 8 + 2 + 1 + 1 + 1 = 13 live bytes, aligned to 8. See `alternative` and `substituteFallback` above:
// this is the assert that makes "the field is free" a check rather than a claim.
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
    // CSSCalcTree+Simplification.cpp:611, and Swift answers the `isLength` half of that one site
    // itself, by calling CSSCalcTree+NumericIdentity.h's own predicate. Not a rare flag -- four
    // production callers set it.
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

// MARK: - The Swift calc FLAT TREE (P7c slices C1/C1d)

// One node of the flat tree, in the form Swift builds and reads.
//
// WHY THIS IS DECLARED IN C++, WHICH REVERSES A POSITION THIS ISLAND HELD AND STATED. The Swift
// declaration's own comment argued the case for staying in Swift -- "C++ owning the shape of a
// structure only Swift builds, a size static_assert to keep the two in step, and a boundary type
// that grows a field every time the simplifier learns an alternative" -- and it was right for the
// boundary it was written about, which was an `emitFlatTree` upcall taking a span of these. It does
// not survive the STORAGE question, and the difference is not a change of taste:
//
//   * Toolchain filings 55, verified with a seven-arm reproducer: `PrintAsClang` exports even a
//     `@frozen`, `BitwiseCopyable` Swift struct as a NON-trivially-copyable, non-default-
//     constructible C++ class that routes copies through the value witness table. Such a type
//     cannot be a `WTF::Vector` element, and the store is a `WTF::Vector`. This is a hard
//     unavailability, not a preference, and it is filed with an acceptance criterion.
//   * The two C++ PRODUCERS of a calc tree -- `Style::Calculation::toCSS`
//     (`StyleCalculationTree+Conversion.cpp:155`) and `CSSNumericValue::toCalcTreeNode` (a pure
//     virtual with ten overrides) -- must eventually be able to construct nodes. A type only Swift
//     can name cannot serve them.
//
// The `static_assert` the old comment counted as a cost is now the thing that PREVENTS a class of
// silent defect rather than tracking one: filings 57 records that an `@_expose(Cxx)` Swift function
// returning a struct whose size leaves a tail of 3, 5, 6 or 7 bytes after the first eight silently
// zeroes that tail, found in production on this island. 40 is outside that range; the assert is
// what makes a later field addition that re-enters it a build failure instead of a wrong stylesheet.
//
// FIELD ORDER IS THE SWIFT DECLARATION'S, so the layout is unchanged and no conversion exists at
// any point. There is now exactly one declaration of this shape, which is strictly fewer than the
// two the old comment was guarding against.
struct alignas(8) CSSCalcSwiftFlatNode {
    // The numeric payload of a leaf. Meaningless for an operation.
    double value;
    // The node's own `Type`, carried rather than recomputed -- a node whose children simplified but
    // whose kind did not change keeps its type, which is what `copyAndSimplify` does.
    Type type;
    // The first child's index, or `cssCalcSwiftFlatNoNode`.
    uint32_t firstChild;
    // The next sibling in the parent's list, or `cssCalcSwiftFlatNoNode`.
    uint32_t nextSibling;
    // How many children the list holds.
    uint32_t childCount;
    // The pre-order index this node had when an EXISTING tree was flattened, naming the original
    // `CSSCalc::Child` it came from. Meaningless on the parse path, which has no original.
    uint32_t origin;
    uint16_t valueID;
    uint8_t unitType;
    CSSCalcSwiftAlternative alternative;
    uint8_t percentHint;
    // `CalcFlatNodeFlags` in the Swift file: clampNoneMinimum, clampNoneMaximum,
    // anchorSideIsSubtree, insideAnchorSide.
    uint8_t flags;
};
static_assert(sizeof(CSSCalcSwiftFlatNode) == 40);
static_assert(alignof(CSSCalcSwiftFlatNode) == 8);
static_assert(std::is_trivially_copyable_v<CSSCalcSwiftFlatNode>);

// The end-of-list sentinel and the "no such node" answer. `UInt32.max` cannot collide with a real
// index: a `Child` is 24 bytes, so a tree of 2^32 nodes would need 96 GB.
static constexpr uint32_t cssCalcSwiftFlatNoNode = UINT32_MAX;

// The storage a `Tree` owns its flat form in, named once so that the parse's local, the boundary
// signatures and `Tree`'s member cannot drift apart -- and so that an inline capacity is a
// one-line experiment rather than a six-file one. Zero today: C1c measured inline capacity in the
// heap-allocated store it replaces at -85.5 instructions for +150 persistent bytes per calc value,
// and C1d's own saving is larger and free, so the trade is re-measured against THIS baseline before
// any capacity is taken (`cssprobe/notes/calc-c1d-results-0912.md`).
using CSSCalcSwiftFlatNodeVector = Vector<CSSCalcSwiftFlatNode>;

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
//     CSSCalcTree+Simplification.cpp: the production one is `trySimplifyWithSwiftIsland`, over that
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

    // Build one of the four numeric leaves, or one of the two tree-counting ones, and push it. See
    // `CSSCalcSwiftLeaf`.
    //
    // Returns false for a `kind` outside that set, which is a contract violation rather than an
    // input that can be met, declining rather than building something plausible.
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
    //
    // `noneMask` IS THE ONLY NEW INFORMATION `clamp()` NEEDS, and it is a defaulted trailing
    // parameter rather than a second entry. Bit 0 set means the MINIMUM bound is the keyword
    // `none`, bit 1 the MAXIMUM; every other bit is ignored. Operand COUNT cannot carry it --
    // `clamp(none, V, M)` and `clamp(M, V, none)` both push two operands -- and a sentinel operand
    // would be a `makeUniqueRef` allocation built only to be discarded, which the allocation bar
    // refuses. The reading direction has the same asymmetry and answers it the same way, with two
    // dedicated `CSSCalcSwiftNodeKind`s (`ClampWithNoneMinimum`/`ClampWithNoneMaximum` above);
    // `rebuildFrom` needs neither, because it reads none-ness off the original node it is given.
    //
    // Defaulted and LAST, after `isRoot`, so that the two Swift call sites that pass `isRoot`
    // positionally are unchanged: a parameter inserted before it would rewrite them for nothing.
    WEBCORE_EXPORT bool buildOperation(CSSCalcSwiftAlternative, uint32_t childCount, Type, bool isRoot = false, uint8_t noneMask = 0) noexcept;

    // Pop the subtree slots of an `anchor()` or an `anchor-size()` and push the finished node
    // (P7b stage G slice 2).
    //
    // A SEPARATE ENTRY RATHER THAN TWO MORE LABELS IN `buildOperation`, and the reason is the hot
    // path rather than tidiness: the two extra arguments would be materialised at every one of
    // `buildOperation`'s per-node call sites, and its label count is already the thing that trips
    // clang's inliner cliff on this entry. Nothing here runs for a tree with no `anchor()` in it.
    //
    // THE ELEMENT NAME CROSSES AS A TOKEN INDEX, not as a string. Swift deliberately cannot see a
    // token's text (`CSSCalcSwiftToken` carries no pointer, and says why), so the grammar decides
    // *whether* the token is a `<dashed-ident>` from `cssCalcSwiftTokenIsDashedIdent` and this entry
    // materialises the `CSS::CustomIdent` from `peek(elementNameToken)` -- the same one token
    // `consumeUnresolvedDashedIdent` reads, through the same `toAtomString()`. Same `AtomString`,
    // same atomisation, by construction. `cssCalcSwiftFlatNoNode` means no element name. This is the
    // tokenizer island's own shape (`CSSParserToken.h:124`-`:143`: Swift writes an offset, C++
    // resolves it), not a new one.
    //
    // `valueID` IS THE `<anchor-side>` KEYWORD FOR AN `Anchor` AND THE `<anchor-size>` KEYWORD FOR AN
    // `AnchorSize`, and `CSSValueInvalid` carries the two "absent" answers, which are different
    // answers and are disjoint by alternative: for an `AnchorSize` it means `dimension` is
    // `std::nullopt`, and for an `Anchor` -- whose `side` is NOT optional -- it means the side is the
    // `<percentage>` SUBTREE in slot 0. So the slot layout is derived here rather than sent: an
    // `Anchor` with no keyword has a side slot, everything else does not, and the remaining slot is
    // the fallback. Nothing about the shape needs a flags argument.
    WEBCORE_EXPORT bool buildAnchor(CSSCalcSwiftAlternative, uint32_t childCount, Type, bool isRoot, uint16_t valueID, uint32_t elementNameToken) noexcept;

    // Drop every operand.
    //
    // Two callers and they are not the same kind: `cssCalcSwiftParseIntoChild`'s failure and
    // contract-violation paths, which are production, and the benchmark's timed emit loop
    // (`cssCalcFlatEmitProbeSwift`, itself behind the bridge gate). `copyAndSimplify` builds a fresh
    // `CSSCalcSwiftOperandStack` per call, so nothing on the SIMPLIFICATION path ever re-enters a
    // used one; the parse path does, because a descent that declines half way leaves operands
    // behind. It is a member rather than a line in the benchmark because the stack reaches the
    // timed loop only through this builder, and the loop has to be on the SWIFT side -- that is
    // what hoists the flat tree's two buffers across iterations, and allocating them per call read
    // 2338 retired instructions against 458 hoisted.
    //
    // Inline is not available: `CSSCalcSwiftOperandStack` is forward-declared here, deliberately, so
    // that this header stays self-contained and does not pull in wtf/Vector.h.
    //
    // THERE USED TO BE A `finishRoot()` BESIDE THIS, and it is gone rather than moved. It moved the
    // single remaining operand into the root slot, because a recursive-descent parser does not know
    // which node is the root until the descent is over -- one `Child` move per parse, an
    // out-of-line 41-alternative variant move at ~42 instructions. Its own comment said it "goes
    // away if the grammar ever builds into the flat form and emits in one pass", which is what the
    // grammar now does: `emitParsed` walks a finished flat tree, so it knows the root before it
    // builds it and passes `isRoot` like every other construction here.
    WEBCORE_EXPORT void clearOperands() noexcept;

    // THE FLAT ARM, WRITE SIDE: one crossing per tree, straight into the `Vector` the finished
    // `Tree` will own (P7c slice C1d). There is no store OBJECT any more -- `CSSCalcSwiftFlatStore`
    // was a refcounted, TZone-allocated class, and every instruction of the two allocator round
    // trips it cost (136.2 of 379.1 per parse, measured in situ) went with it.
    //
    // `__counted_by` PLUS `noescape` is what makes this import as a single
    // `Span<CSSCalcSwiftFlatNode>` with no `unsafe` marker; either annotation alone gives an
    // `UnsafeBufferPointer` or a pointer and a count as two arguments, and NEITHER failure names the
    // missing annotation (`calcflatstore/run.sh` arms W1 and W2).
    //
    // WHY THE DESTINATION IS NOT A MEMBER OF THIS STRUCT, which is where C1c's sketch put it. This
    // type is 16 bytes and the `simplifyX` family takes it BY VALUE as an `Optional` on a per-node
    // path; two more pointers here would take every one of those copies from two registers to four.
    // It goes on `CSSCalcSwiftOperandStack` instead -- the object this already indirects through,
    // constructed once per parse, forward-declared so Swift never sees inside it. No new pointer
    // member on a `SWIFT_SAFE` type, so the assertion at the top of this struct is unchanged rather
    // than re-argued.
    //
    // Returns the number of nodes stored, so Swift can assert the crossing rather than trust it. A
    // caller that asked for NO flat arm -- the differential's non-store arms and the primitive
    // benchmarks -- gets `nodeCount` back unchanged, because "there was nowhere to put it" is not a
    // boundary failure and must not read as one.
    WEBCORE_EXPORT size_t takeFlatNodes(const CSSCalcSwiftFlatNode* __counted_by(nodeCount) nodes __attribute__((noescape)), size_t nodeCount, uint32_t rootIndex) noexcept;

    // THE FLAT ARM, READ SIDE: per element by value, which is `CSSCalcSwiftParseCursor::tokenAt`'s
    // shape at 40 bytes instead of 24. No pointer and no view crosses, so there is no capacity
    // policy to get wrong and no bounds pre-check for Swift to mirror -- Swift cannot RECEIVE a
    // bounds-carrying view at all (rdar://186723514, filings 27).
    //
    // Out of range yields a zeroed node whose `firstChild` is the no-node sentinel, so a walk that
    // runs off the end terminates rather than reading adjacent memory.
    WEBCORE_EXPORT uint32_t flatNodeCount() const noexcept;
    WEBCORE_EXPORT CSSCalcSwiftFlatNode flatNodeAt(uint32_t index) const noexcept;

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
    WEBCORE_EXPORT CSSCalcSwiftNumericResult resolveSymbol(uint16_t valueID, uint16_t unit) const noexcept;

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
    WEBCORE_EXPORT CSSCalcSwiftNumericResult resolveRelativeLength(double value, uint16_t unitType) const noexcept;

    // The fourth upcall, and the only place `Style::BuilderState` reaches this boundary.
    //
    // Covers three style-coupled operations: `sibling-count()`, `sibling-index()`
    // (`+Simplification.cpp:527`-`:544`) and `random()` (`:1350`-`:1402`). None of the three can be
    // answered in Swift, and all three fail for one reason: `Style::BuilderState` carries the
    // element, its parent's child list and the document's random base-value cache, and is not
    // reducible to anything that crosses a POD boundary. That is the same reason `resolveSymbol`'s
    // `HashMap` and `resolveRelativeLength`'s `CSSToLengthConversionData` stay here, and why this is
    // an upcall rather than a field: Swift names what it wants and C++ owns the object that
    // answers.
    //
    // One entry for three operations, with no selector at all: no operation kind ever crosses in
    // the construction direction, because C++ recovers the operation from the node's own variant
    // tag, the same principle `rebuildFrom` rests on. Two other shapes were rejected: separate
    // named methods for each operation, which repeats the conversion-data guard three times and
    // puts a discriminant on the boundary that the node already carries; and a three-case Swift
    // `@c` selector enum, which trades two declarations for one plus an enum plus three
    // `static_assert`s plus a `switch` -- not fewer of anything.
    //
    // This one is 25 lines, one declaration, and the discriminant cannot be gotten wrong because it
    // is never stated: a tree-counting node arrives as a `SiblingCount` or a `SiblingIndex` and the
    // implementation reads which; the `random()` case is the same `get_if` it needed anyway to reach
    // the key. The 3-way tag test is on a path taken only by three rare kinds.
    //
    // Not a precomputed field on `CSSCalcSwiftSimplificationOptions`, which would otherwise be the
    // cheapest possible crossing (one per `copyAndSimplify` instead of one per node), for the reason
    // `resolveRelativeLength` above gives: `siblingCount()` and `siblingIndex()` walk the element's parent's
    // child list, so a field would run that walk for every `calc()` in every stylesheet to answer a
    // question almost none of them ask. `random()` could not use one at all -- its answer depends on
    // the node's key.
    //
    // `resolved == false` is exactly the C++'s `std::nullopt`: no conversion data, no builder state,
    // no element for a tree-counting function, no cached base value for a key, or a node of an
    // alternative this does not serve (a contract violation, checked rather than asserted). The node
    // is copied through unchanged in every one of those cases, matching what `copyAndSimplify` does
    // with a `std::nullopt` from `simplify`.
    //
    // `CSSCalcSwiftNumericResult` is reused rather than adding a two-field struct, and the two
    // fields beyond `value` and `resolved` are truthful here rather than inert: all three operations
    // produce a plain `<number>` -- `makeChild(Number { ... })` at `:534` and `:543`, and a
    // `<random-key>` base value is a `<number [0,1]>` by definition -- so `unitType` is
    // `CSSUnitType::Number` and `alternative` is `Number` because that is what the answer is.
    //
    // `Anchor` and `AnchorSize` join the same entry, still with no selector. They are the last two
    // style-coupled operations and fail for the same reason the other three do, one step further
    // out: `Style::BuilderState` carries the element, its style and the anchor-position machinery,
    // `Style::ScopedName` needs `Style::toStyle` plus the state's scope ordinal, and
    // `Style::AnchorPositionEvaluator` reaches renderers -- none of it reduces to a POD. The
    // dispatch is still the node's own variant tag, so which of the five operations this is standing
    // on is never named, and the 3-way tag test at the bottom became a 5-way one.
    //
    // The answer for these two is a `CanonicalDimension`, not a `Number` -- `simplify(Anchor&)` ends
    // at `CanonicalDimension { .value = *result, .dimension = Dimension::Length }` -- so `unitType`
    // is `toCSSUnit(Dimension::Length)` read out of the header rather than the literal `Px`, and
    // `alternative` is `CanonicalDimension`.
    //
    // They also need a third outcome, `CSSCalcSwiftNumericResult::substituteFallback` -- see that
    // field. It is the only reason the struct grew, and it grew by nothing (see "free in bytes"
    // there).
    //
    // The invalid mark is set here, in C++, deliberately.
    // `setCurrentPropertyInvalidAtComputedValueTime()` on a `Style::BuilderState` is not reachable
    // from Swift, and a second boundary entry meaning "mark it" would put the `if (!node.fallback)`
    // test in Swift where C++ already has the node -- a shim re-deriving a decision the input
    // already carries. The mark is monotone with no public clear, so a repeated call cannot be
    // distinguished from a single one, which is what makes it safe on a path `fold` may re-enter for
    // a node whose parent did not fold.
    //
    // Why the `<random-key>` needs the node and must not become a POD. `Random::Sharing` is a
    // `Variant<SharingAuto, Key, SharingFixed>` over a `CSS::CustomIdent` (an `AtomString`), a
    // `CSSPropertyID`, a `RandomFunction`, indices and two optional keywords
    // (CSSCalcRandomSharing.h), and `resolveRandomBaseValue` hashes the whole of it into a
    // `RandomCachingKey` to look up a value cached on the Document and on the element. Transcribing
    // that key across the boundary would be a duplicated table and a second hash of it, and two arms
    // hashing differently would hand the same key two different `random()` values -- a wrong
    // stylesheet, not a decline.
    //
    // The `SharingFixed` arm is decided here, in C++, rather than in Swift -- the only such
    // decision left, now that `swiftCalcMixItemWeight` moved `CalcMix`'s per-item
    // weight presence back to Swift. `simplify(Random&)` resolves a `fixed <number>` locally when
    // it is a `Raw` and answers nothing when it is a `Calc`, rather than going through
    // `resolveRandomBaseValue`, whose own fixed arm would run `Style::toStyle` and evaluate the
    // `Calc`. That `Raw`/`Calc` discrimination is over `CSS::Number<CSS::ClosedUnitRange>`, another
    // `Variant`, with no numeric channel to Swift: `CSSCalcSwiftOperationInfo` reports only
    // `randomSharingIsFixed`, because serialization needs the fixed value as text and gets it
    // through `CSSCalcSwiftOperationPart::randomFixedValue`. Adding a numeric channel would take
    // `CSSCalcSwiftOperationInfo` from 12 bytes to 24 and its return from registers to an indirect
    // `sret`, for more new C++ than the four-line branch below -- the two dispositions are
    // indistinguishable to Swift either way, since a `Calc` fixed value comes back
    // `resolved == false` and the node is copied through, matching `std::nullopt` from the C++ arm.
    WEBCORE_EXPORT CSSCalcSwiftNumericResult resolveStyleCoupledValue(const Child&) const noexcept;

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
    //
    // IT CARRIED A SECOND ANSWER FOR ONE DAY AND NO LONGER DOES, which is worth recording because
    // the measurement that shaped it still holds. Stage E1 needed WHICH math function a
    // `FunctionToken` names to reach Swift, and Swift could not name `CSSValueMin`; a separate
    // `uint8_t functionAlternative` fits in this struct's six spare bytes and cost SIX RETIRED
    // INSTRUCTIONS PER TOKEN READ -- +17 on a single-leaf parse and +211 on the eight-term band,
    // 0.711 -> 0.726 on the production pair. `tokenAt` runs once per token and returns this struct
    // BY VALUE, so a field it did not have to write is a field it must not grow. Anything a later
    // stage wants to add here is subject to that price.
    //
    // The channel is gone entirely now: `functionId` below already crosses raw, and Swift compares
    // it against `CSSValueMin` itself (see WebCore_Private.modulemap's `Core` module).
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

    // ONE ANSWER THAT RIDES IN THE PADDING, so the grammar asks for it for free rather than making
    // a crossing. It is a function of `unit` alone and was a separate exported C++ call made once
    // per dimension leaf built; the struct had seven spare bytes, so carrying it here deletes a
    // boundary entry point instead of adding one.
    //
    // `makeNumeric`'s answer (which alternative a unit builds) deliberately does NOT ride here, and
    // that is measured, not stylistic: filling it in `tokenAt` cost 403 instructions on the
    // eight-term band, because `tokenAt` runs once per TOKEN while the answer is needed once per
    // dimension LEAF, and `makeNumeric` constructs and destroys a `Child`. It stays a crossing.
    //
    // Filled ONLY for a `DimensionToken` -- they are meaningless otherwise, and computing them for
    // every whitespace token and operator would be the trade the other way round.
    //
    // Three cheap predicates, one bit each. All are pure functions of a field already in this
    // struct, so none of them is new information crossing -- what they buy is that the grammar does
    // not make a call to ask. Each is a plain switch on the C++ side; the expensive answer
    // (`makeNumeric`'s) deliberately stays a crossing, see the note above.
    uint8_t flags;
};
// Bit 0, for a DimensionToken: `conversionToCanonicalUnitRequiresConversionData(unit)`.
static constexpr uint8_t cssCalcSwiftTokenUnitNeedsConversionData = 1 << 0;
// Bit 1, for a FunctionToken: `isCalcFunction(functionId)` -- any of the math functions, `calc()`
// included. The grammar declines these rather than failing, because they are real CSS it does not
// cover yet.
static constexpr uint8_t cssCalcSwiftTokenIsCalcFunction = 1 << 1;
// Bit 2, for a FunctionToken: the function is `calc()` or `-webkit-calc()` specifically, which
// `parseCalcFunction` routes straight to `<calc-sum>`. A calc function WITHOUT this bit is a
// decline; a function block with neither bit is a parse FAILURE, which is what the C++ arm does
// with it -- `findBlock` returns nothing and the value switch has no `FunctionToken` arm.
static constexpr uint8_t cssCalcSwiftTokenIsPlainCalcFunction = 1 << 2;
// Bit 3, for an IdentToken: the token's text starts with `--`, so it is a `<dashed-ident>` and a
// candidate `<anchor-element>` (P7b stage G slice 2).
//
// THE ONE THING `anchor()` NEEDS THAT THIS BOUNDARY DELIBERATELY DOES NOT CARRY IS TEXT, and this is
// the whole of it. `consumeUnresolvedDashedIdent` (CSSPropertyParserConsumer+Ident.cpp:139-:144) is
// `range.peek().type() == IdentToken && range.peek().value().startsWith("--"_s)` over exactly ONE
// token; this bit is that predicate over the same token, so the two arms' accept sets are identical
// by construction rather than by an argument about escapes. The NAME still never crosses -- Swift
// sends back the token's INDEX and `CSSCalcSwiftBuilder::buildAnchor` materialises the
// `CSS::CustomIdent` from `peek(index)`, which is the same `toAtomString()` into the same table.
//
// A FLAG BIT RATHER THAN AN `identClassAt(index)` ENTRY ON THE CURSOR, which is what the design note
// chose: the entry is nine lines of C++ and this is three, and this project prices a line of glue
// above an instruction (CLAUDE.md 1). The cost is one compare on the fall-through arm of an
// `if`/`else if` chain `tokenAt` already runs -- a DimensionToken and a FunctionToken pay nothing --
// against the six retired instructions per token a FIELD here was measured to cost.
static constexpr uint8_t cssCalcSwiftTokenIsDashedIdent = 1 << 3;
static_assert(sizeof(CSSCalcSwiftToken) == 24);
static_assert(alignof(CSSCalcSwiftToken) == 8);

// A read-only cursor over the tokens of one `calc()`, for the Swift grammar.
//
// SHAPE, AND WHY IT IS THIS ONE. Swift reads one token at a time, BY VALUE, through `tokenAt`.
// It does not receive a buffer and it is not handed one to fill, because both were measured and
// rejected (`~/src/webkit-swift-ports/calctokenspan/`): Swift cannot RECEIVE a bounds-carrying view
// at all -- ten crossing shapes enumerated, only the two Swift-as-caller ones work -- and the
// buffer-filling alternative costs 24 bytes of copy plus 24 of zero-fill per token, against a C++
// parser that copies nothing whatever (`CSSParserTokenRange` IS a span over the tokenizer's own
// vector). A by-value 24-byte return crosses no pointer, needs no capacity policy, and has no
// "too many tokens" decline to get wrong.
//
// WHY THE `SWIFT_SAFE` CLAIM HOLDS. As on `CSSCalcSwiftSink` above, this is `swift_attr("safe")`:
// an UNCHECKED assertion that the type safely encapsulates its unsafe constituent, here the
// `std::span` inside `CSSParserTokenRange`. Nothing verifies it, and it is REQUIRED rather than
// stylistic -- measured, not assumed: a receiver holding a span member makes every use of it unsafe
// to Swift, and it defeats even `operator[]`, which is otherwise one of only two reference-return
// spellings that import safely. The claim, stated so it can be checked:
//
//   * The referent outlives every use. The cursor is constructed on the C++ stack immediately
//     before the single Swift call that takes it, from a `CSSParserTokenRange` the caller of
//     `parseAndSimplify` owns, and it is destroyed when that call returns. No stored property and
//     no escaping closure can hold it: it crosses `noescape`.
//   * Nothing mutates the token vector for the duration. The range is a view over
//     `CSSTokenizer::m_tokens`, which is complete before any property parser runs.
//   * The cursor is `const` throughout and hands out only values, so no aliasing question arises
//     on the Swift side.
//
// A future toolchain change removes the need for the annotation entirely: it is the second
// direction of rdar://186723514 (`__counted_by` synthesising a safe view for a RETURN or an
// out-parameter, not only for a parameter). Filings register 27 carries the ask and its acceptance
// criterion; when it lands, this becomes a span crossing and the assertion goes.
struct SWIFT_SAFE CSSCalcSwiftParseCursor {
    // How many tokens the range holds. Swift's whitespace look-behind is `tokenAt(i - 1)`, which
    // is why whitespace tokens are NOT filtered out here.
    uint32_t tokenCount() const noexcept;

    // The token at `index`, by value. Out of range yields a token whose `type` is `EOFToken`,
    // matching what `CSSParserTokenRange::peek` does past the end, so Swift needs no bounds
    // pre-check to mirror the C++ grammar's behaviour.
    CSSCalcSwiftToken tokenAt(uint32_t index) const noexcept;

#if !defined(__swift__)
    explicit CSSCalcSwiftParseCursor(const CSSParserTokenRange& range)
        : m_range(range)
    {
    }

private:
    const CSSParserTokenRange& m_range;
#else
    // Same-size stand-in, so the importer never walks CSSParserTokenRange -- which would drag
    // CSSTokenizer.h and its includes into this deliberately self-contained header. The branch that
    // can see the real type asserts the size, because a `void*` placeholder that disagreed would
    // let the two languages hold different views of one live object with no diagnostic.
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

    // Whether `parseCalcFunction` would admit `sibling-count()` / `sibling-index()` here: the
    // CONJUNCTION of its three gates (`CSSCalcTree+Parser.cpp:1414`-`:1420`) -- the context
    // setting, a `currentRule` of `Style` or `Keyframe`, and a `currentProperty` other than
    // `CSSPropertyInvalid`.
    //
    // ONE PRECOMPUTED BOOL, NOT THREE FIELDS AND NOT `PropertyParserState` CROSSING, and the same
    // shape `hasAllowedSymbols` above already uses: the conjunction is a C++ fact the caller
    // already has, so carrying it is a copy of a value rather than a second evaluation of it.
    //
    // CLEAR MEANS **FAILED**, NOT DECLINED, which is the one thing easy to get backwards here. With
    // any gate clear the C++ arm returns `{ }` from its `case CSSValueSiblingCount:` -- i.e.
    // `std::nullopt`, invalid input -- so the grammar must FAIL too. Declining instead would be
    // merely slow; parsing instead would accept CSS the C++ rejects.
    bool treeCountingAllowed;

    // `CSSParserContext::cssCalcMixEnabled`, which is `consumeCalcMix`'s first statement
    // (`CSSCalcTree+Parser.cpp:1013`-`:1014`) and its only gate.
    //
    // CLEAR MEANS **FAILED**, NOT DECLINED, for `treeCountingAllowed`'s reason one line up: the
    // C++ returns `{ }` -- `std::nullopt`, invalid input -- so the grammar must fail too.
    //
    // A SECOND FIELD RATHER THAN A CONJUNCTION WITH THE ONE ABOVE, because the two gates are
    // independent facts about different functions and ANDing them would make `calc-mix()` fail
    // wherever `sibling-count()` is forbidden. There is no third state to save a byte for: the
    // struct is passed by value once per parse, not per node.
    bool cssCalcMixEnabled;

    // `CSSPropertyParserOptions::anchorPolicy` and `::anchorSizePolicy`, each already reduced to
    // "is it `Allow`" -- `consumeAnchor`'s and `consumeAnchorSize`'s first statements
    // (`CSSCalcTree+Parser.cpp:1120` and `:1213`), and their only context gates.
    //
    // CLEAR MEANS **FAILED**, NOT DECLINED, as for the two gates above: the C++ returns `{ }`.
    //
    // TWO FIELDS, NOT ONE "anchor positioning is on" BIT, because the two policies are INDEPENDENT
    // in production and a single bit could not tell a conforming arm from one that conflated them:
    // the eight inset properties allow both, while `width`/`height`/`max-*`/`margin-*` allow only
    // `anchor-size()`. That asymmetry is what makes `width` a sharp negative control for `anchor()`
    // and a treatment for `anchor-size()` in the same corpus.
    bool anchorAllowed;
    bool anchorSizeAllowed;

    // `CSSPropertyParserOptions::unitlessZeroLength == UnitlessZeroQuirk::Allow`, which is
    // `consumeAnchorFallback`'s `Category::Number` arm (`CSSCalcTree+Parser.cpp:1098`) and nothing
    // else in the grammar's reach.
    //
    // IT HAS TO CROSS EVEN THOUGH ITS DEFAULT IS `Allow`, and the direction of the error is why:
    // a property that FORBIDS it rejects `anchor(top, 0)`, so assuming `Allow` would make the island
    // accept CSS the C++ arm rejects -- the one divergence direction that is never conservative.
    bool unitlessZeroLengthAllowed;

    // The TOP-LEVEL function's `CSSValueID` raw value: `CSSValueCalc`, `CSSValueWebkitCalc`, or
    // whichever math function the grammar covers. The caller has it already -- it is the
    // `functionId` it tested with `isCalcFunction` -- so this is a copy of a value C++ read, not a
    // second classification of it.
    //
    // `parseAndSimplify` accepts ANY `isCalcFunction` at the top (`CSSCalcTree+Parser.cpp:171`), so
    // `width: min(1px, 2px)` is a top-level `Min`, but this entry is handed the range INSIDE the
    // function and so cannot see which one it was. Carried here rather than by handing Swift the
    // OUTER range, because routing the top level through the block arm would enter its arguments at
    // depth 1 where the C++ enters them at 0 (`parseCalcFunction(tokens, function, 0, state)`) -- a
    // divergence only a 100-deep expression can see and no ordinary corpus contains.
    uint16_t rootFunctionId;
};

// Why the parse stopped, when it did.
//
// A decline and a FAILURE are different outcomes and must not share a channel: a failure means the
// input is not a valid `calc()` and the C++ arm would also have returned `std::nullopt`, so the
// caller must NOT retry; a decline means this grammar does not cover the input yet and the C++ arm
// must run. Collapsing them would make the fallback either miss real parses or re-parse garbage,
// and would make the decline count meaningless as a coverage number.
enum class CSSCalcSwiftParseOutcome : uint8_t {
    Parsed,
    // The input is invalid. The C++ arm agrees; do not retry.
    Failed,
    // Not covered by this grammar yet. Retry with the C++ arm.
    Declined,
};

// Which uncovered construct caused a decline. An unattributed decline is one nobody can close,
// which is the argument for the field -- the same argument `CSSCalcSwiftSimplificationResult`'s
// `declineAlternative` already carries.
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
    // A `calc-mix()` item weight that is a math function rather than a raw `<percentage>`. Its
    // `CalcMix::Item::Weight` is a `Variant<Raw, UnevaluatedCalc>` and the second alternative holds
    // a `Ref<CSSCalc::Value>` (CSSUnevaluatedCalc.h) -- a whole second calc value, not a `Child`,
    // so no flat node can carry it. Stage G's one declined residue, named rather than folded into
    // `MathFunction` so the remaining coverage stays attributable.
    //
    // APPENDED, NOT INSERTED IN GRAMMAR ORDER, and that is the prefix rule the validation harnesses
    // already rely on for `CSSCalcParseComparison`: `cssprobe/validate/parsecheck.cpp`'s
    // `declineReasonName` mirrors these numbers by hand, so inserting would have made it print
    // `TooManyTokens` for this reason and `?` for that one -- a wrong name rather than a missing
    // one. Appended, an un-updated mirror prints `?`, which is visible.
    CalcMixWeight,
    // An `anchor()` or `anchor-size()` in a configuration where the C++ arm's `simplify` would
    // EVALUATE it -- `options.conversionData` with a style builder state. Both folds reach the
    // anchor position evaluator through the original `CSSCalc::Child`, which a parsed tree has not
    // got, so the island declines rather than handing back an unresolved node where the C++ hands
    // back a length. Stage G slice 2. APPENDED, for the reason the enumerator above gives.
    AnchorEvaluation,
};

struct alignas(8) CSSCalcSwiftParseResult {
    // The tree's `Type`, computed by the Swift type algebra rather than recomputed by C++.
    Type type;
    // A `CSSCalcSwiftParseOutcome`.
    uint8_t outcome;
    // A `CSSCalcSwiftParseDeclineReason`.
    uint8_t declineReason;
    // Whether any leaf's unit needs conversion data, which `ParserState` records for the caller.
    bool requiresConversionData;
};
static_assert(sizeof(CSSCalcSwiftParseResult) == 16);
static_assert(alignof(CSSCalcSwiftParseResult) == 8);


// The alternative `makeNumeric` would build for `unit`, a `CSSCalcSwiftNodeKind`. C++ answers it
// because `makeNumeric` owns the seventy-case unit table. Called once per dimension leaf actually
// built -- see the note on `unitFlags` for why it is not carried in the token.
WEBCORE_EXPORT uint8_t cssCalcSwiftLeafKindForUnit(uint16_t unit) noexcept;

// `lookupConstantNumber(id)`: the five `<calc-keyword>` constants. `resolved` false means the
// identifier is not one of them. Same argument again -- the table is C++'s, and it is keyed on
// `CSSValueID`, which this header deliberately does not import.
WEBCORE_EXPORT CSSCalcSwiftNumericResult cssCalcSwiftLookupConstantNumber(uint16_t id) noexcept;

// Drives the Swift grammar over `innerRange` -- the tokens INSIDE a `calc()`, which is what
// `consumeFunction` leaves -- simplifies the result, and constructs it into `outRoot`.
//
// Lives beside the operand stack rather than at the call site because `CSSCalcSwiftOperandStack` is
// only forward-declared in this header (it holds a `WTF::Vector<Child>`, and this header must stay
// self-contained), so no other translation unit can build one. That is also the production shape:
// when the parse path is gated on, `parseAndSimplify` calls exactly this.
//
// PARSE AND SIMPLIFICATION ARE ONE PASS. The grammar writes the island's own `CalcFlatNode` form,
// the island's existing per-alternative simplification runs over it in place, and a `CSSCalc::Child`
// is materialised once at the end. That is one per-node representation conversion where the shape
// this replaced had three: the grammar built a `Child` per node, and `ParseSimplification::Terminal`
// then flattened it back into `CalcFlatNode`s and emitted it again.
//
// `simplify` false skips the middle pass, matching `ParseSimplification::None`. It exists for the
// grammar differential, which must compare an UNSIMPLIFIED tree -- against a simplified one a parse
// defect and a commutative fold can cancel, since `Sum{2px, 1px}` and `Sum{1px, 2px}` agree after
// folding. Production is `Terminal`, which is this parameter's default.
//
// Returns `Parsed` only when the whole range was consumed AND the boundary contract held -- the
// root slot taken and the operand stack empty. Anything else leaves `outRoot` untouched.
//
// `outFlatNodes`/`outFlatRootIndex`, when non-null, also receive the flat tree the grammar built, in
// ONE crossing (P7c slices C1/C1d) -- the `Vector` a `Tree` owns by value, filled directly, with no
// intervening store object. Null is the shape the differential's non-store arms take.
WEBCORE_EXPORT CSSCalcSwiftParseResult cssCalcSwiftParseIntoChild(const CSSParserTokenRange& innerRange, CSSCalcSwiftParseOptions, const SimplificationOptions&, Child& outRoot, bool simplify = true, CSSCalcSwiftFlatNodeVector* outFlatNodes = nullptr, uint32_t* outFlatRootIndex = nullptr) noexcept;

// Rebuild a `Child` from a stored flat tree (P7c slice C1), reading it back one node at a time by
// value. Two uses, and the second is why it is production rather than test code: it is the only
// thing that can make a filled store OBSERVABLE to a differential, and it is the materialising
// fallback a consumer keeps until it moves to Swift -- the charter's gate on P7c being that a
// consumer either moves to Swift or keeps reading `Child`, never gets rewritten in C++ against the
// flat form. False leaves `outRoot` untouched.
//
// `tokens` IS THE RANGE THE TREE WAS PARSED FROM, and the parameter is required rather than
// defaulted because the flat form is an encoding RELATIVE TO THAT RANGE: an `anchor()`'s
// `<anchor-element>` is stored as a token index, not as a string (see `buildAnchor`), so a caller
// that no longer has the tokens cannot decode one. That is a real limit of the flat arm and the
// signature is where it is stated. IT IS SAFE, NOT MERELY DOCUMENTED: `buildAnchor` re-checks the
// `IdentToken` and `--` predicate at the index, and a default-constructed range yields the EOF
// token there, so a caller who passes the wrong range or none gets a REFUSAL -- false, `outRoot`
// untouched, fall back to the `Child` -- and never a wrong element name. Every other alternative
// the flat form carries is self-contained and decodes with an empty range.
WEBCORE_EXPORT bool cssCalcSwiftEmitStoreIntoChild(const CSSCalcSwiftFlatNodeVector&, uint32_t rootIndex, const SimplificationOptions&, const CSSParserTokenRange& tokens, Child& outRoot) noexcept;

} // namespace CSSCalc
} // namespace WebCore
