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

// Everything the Swift calc islands -- CSSCalcSerializationSwift.swift and
// CSSCalcSimplificationSwift.swift -- are allowed to see of WebCore, and nothing else. Same shape
// and same reason as CSSTokenizerSwiftTypes.h next door: its own Clang module in
// WebCore_Private.modulemap, self-contained, so that importing it
// cannot walk the ~3,500-header PrivateHeaders umbrella into JavaScriptCore's private headers.
//
// SELF-CONTAINED IS WHY THE TREE IS NOT IMPORTED. The probe matrix at
// ~/src/webkit-swift-ports/cssprobe/calcimport/ was built to answer "can Swift hold a
// CSSCalc::Child?", and its arm 8 answered yes -- hide the `Variant` member from the importer
// behind `#if !defined(__swift__)` with same-size stand-in storage and a `static_assert` on it,
// because the importer odr-uses the member's destructor over incomplete `UniqueRef<Op>`
// alternatives (filings register §35). But Swift does not need `Child`'s *layout* to walk the
// tree -- only its *identity*. A handle holding `const Child*` needs `Child` merely
// forward-declared, which is what CSSCalcTree+Serialization.h has always done, and that shape is
// strictly better on every axis this project scores:
//
//   - CSSCalcTree.h is not touched at all, so there is no stand-in storage to keep in sync and no
//     `static_assert` that has to be right;
//   - §35's importer bug is never reached, because no variant member is ever imported;
//   - and the boundary header stays self-contained, where importing CSSCalcTree.h would drag in
//     CSSPrimitiveNumeric.h, CSSCustomIdent.h, CSSValueKeywords.h, CSSCalcRandomSharing.h,
//     wtf/Vector.h and wtf/TZoneMalloc.h.
//
// Probed end to end as arm 11 and arm 13 of that matrix before any of this was written: the
// recursive walk plus the sink below import at **0 errors, 0 warnings and 0 `unsafe` markers**,
// with anti-vacuity controls (arm 13C) confirming that removing `SWIFT_SAFE` puts the marker back.

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

// The simplification island's operand stack, which C++ owns. Forward-declared and defined in
// CSSCalcTree+Simplification.cpp, because naming what it actually is -- a `WTF::Vector<Child>` --
// would need wtf/Vector.h here, and a self-contained boundary header is the whole premise of this
// file (see the note at the top). Swift never sees inside it; it only names positions on it
// implicitly, by pushing and by saying how many operands a reconstruction consumes.
struct CSSCalcSwiftOperandStack;

// What kind of node the walk is standing on.
//
// Declared here in C++ rather than in Swift with `@c`, which is the opposite of what the
// tokenizer island does for its token types -- and deliberately. That numbering is declared in
// Swift because *Swift* produces it and C++ consumes it, so a single Swift declaration removes a
// transcription. Here C++ produces the kind and Swift consumes it, so the single declaration
// belongs on the C++ side; an `enum class ... : uint8_t` imports as an ordinary Swift enum that
// the island can `switch` over exhaustively, and there is nothing left to `static_assert`.
//
// S1 split four operator kinds out of S0's single `Operation` case -- the four whose serialization
// is the grouping-parenthesis state machine (css-values-4 steps 4 to 7). S2 takes the remaining 30,
// and it does NOT name them one per kind, because their *serialization* only has four shapes. What
// the island needs of an operator is the shape, so the kind names the shape and `valueID` carries
// the name: `Function` is `name(id)` followed by comma-separated arguments, which is 19 of the 30
// outright and `clamp()` too whenever neither bound is `none`. A per-operator kind would have been 30
// Swift cases and 30 C++ lambdas that all did the same thing, and it would have put the operator
// *table* on both sides of the boundary.
//
// `Operation` is therefore no longer "everything unabsorbed" but a much narrower thing: after S3 it
// is ONLY "an operation added to CSSCalcTree.h that this file has not been taught". That fallback
// direction is deliberate and is the whole reason the C++ side uses an ALLOWLIST of
// generically-serialized operations: a new operation declines until someone teaches the island,
// where a denylist would silently serialize it with the wrong spelling.
//
// S3 takes the last four -- `Random`, `CalcMix`, `Anchor` and `AnchorSize` -- and each gets its own
// kind rather than sharing one, because unlike S2's thirty their serializations have four genuinely
// different shapes and each needs different non-tree data (see `CSSCalcSwiftOperationInfo`). Where
// S2's rule was "the kind names the SHAPE and `valueID` carries the name", these four are the cases
// where the shape *is* the operation.
//
// `OpaqueOperation` NO LONGER HAS A PRODUCER, and it is retained rather than removed. It was
// `Anchor` and `AnchorSize`, which declare `tuple_size` 0 (CSSCalcTree.h:1317, "FIXME
// (webkit.org/b/280798): make Anchor and AnchorSize tuple-like") so that `forAllChildNodes` reports
// no children even though an `Anchor` holds an `AnchorSide` and an optional fallback `Child`. S3
// does not fix that FIXME -- fixing it would change what `forAllChildNodes` yields for every other
// caller, simplification and evaluation included, which is a semantic change this slice has no
// oracle for. Instead `forEachChildNodeOfChild` in the bridge answers for those two directly, so the
// lie stops at the boundary and `childCount` is the truth on the Swift side. The case stays because
// removing it would renumber every kind above it, and `kindMask` is `1 << rawValue` with the
// differential's per-kind figures printed by bit number.
//
// New cases are APPENDED, never inserted: `CSSCalcSwiftSerializationResult::kindMask` is `1 <<
// rawValue` and the differential's per-kind coverage counts are printed by bit number, so inserting
// a case would silently relabel every historical figure.
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
    // `clamp()` with one bound holding the keyword `none`, which is the one place in the whole tree
    // where an ARGUMENT is not a child node: `min` and `max` are `ChildOrNone`, and the C++ argument
    // serializer emits `none` for a bound holding one (`+Serialization.cpp:588`-`:596`) where
    // `forAllChildNodes` skips it entirely. Without these the island would serialize
    // `clamp(none, VAL, MAX)` as `clamp(VAL, MAX)` -- a wrong value rather than a missing one.
    //
    // Two kinds rather than a flag on the node, because that is what makes the island's exhaustive
    // `switch` decide. It also replaced the first attempt at this, a cursor discriminated so it could
    // stand on something other than a `Child`: that was 25 more lines of C++ for identical coverage,
    // and it took the glue ratio the wrong way. `clamp(none, VAL, none)` needs no kind at all --
    // simplification rewrites it to `VAL` for any `val` whatever (`+Simplification.cpp:1007`) -- and
    // is reported as `Operation`, so a change that made it reachable declines instead of dropping a
    // bound.
    ClampWithNoneMinimum,
    ClampWithNoneMaximum,
    // S3's four, each carrying non-tree arguments that `childAt` cannot reach. What they need
    // beyond `CSSCalcSwiftNodeInfo` arrives in `CSSCalcSwiftOperationInfo` below, and their
    // `valueID` is `Op::id` -- `random`, `calc-mix`, `anchor`, `anchor-size` -- exactly as
    // `Function`'s is, so the four function NAMES still cost nothing on the Swift side.
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
// A SECOND discriminant beside `CSSCalcSwiftNodeKind`, and the two answer different questions. The
// kind names the SERIALIZATION SHAPE, which is what the serialization island needs and which is why
// it lumps the nineteen plain math functions into one `Function` case -- `min()` and `mod()`
// serialize identically up to their name, so an island that only prints them has no reason to tell
// them apart. A REWRITER does: this slice folds `mod()` and declines `min()`, so it must dispatch on
// the operation itself, and no amount of `valueID` inspection makes an exhaustive `switch` out of
// that. The kind stays exactly as it is, because the serialization island is landed and correct
// against it.
//
// A REAL EXISTING ENUM WAS LOOKED FOR FIRST, and there is not one that works. Three candidates,
// each rejected on evidence rather than on taste:
//
//  - `CSSCalc::Operator` (CSSCalcOperator.h:35) is the closest thing and covers 31 of the 41: it has
//    no enumerator for the seven leaves, none for `Deg2Rad`, and none for `Anchor` or `AnchorSize`.
//    It is also deliberately sparse -- `Sum = '+'`, `Negate = '-'`, `Product = '*'`, `Invert = '/'`
//    ("Don't change these values; parsing uses them") -- so a `1 << rawValue` mask over it would
//    need 48 bits to carry 31 alternatives and could not name the ten it lacks at all. Decisively:
//    NOTHING IN THE TREE MAPS AN OPERATION TYPE ONTO IT. `Operator` is referenced in exactly two
//    places, `CSSCalcExecutor.h`'s explicit specializations and four `static_cast<char>` comparisons
//    in CSSCalcTree+Parser.cpp; there is no `Op::op`, so carrying it would mean writing a fresh
//    31-line `Op -> Operator` table, which is a duplicated table and the thing this port counts as
//    goop by name.
//  - `ToCalculationTreeOp<Op>` (CSSCalcTree+Mappings.h:35) is a TYPE alias -- `ToCalculationMapping`
//    has a single member, `using type` -- not an operation id, and it too omits `Deg2Rad`, `Anchor`,
//    `AnchorSize` and the leaves.
//  - `Style::Calculation`'s parallel tree (StyleCalculationTree.h:131) declares no `enum class` at
//    all.
//
// So the numbering is the variant's OWN alternative index, which is the one numbering in the
// program that cannot drift and the same one simplifycheck.cpp keys its 41-bit masks on. It is read
// with `Node::index()` -- no switch, no table, nothing per-operation on either side of the boundary.
//
// HOW THIS CANNOT REPEAT THE `webCoreCSSCalcNodeKindCount` FAILURE. That count is spelled "the LAST
// enumerator + 1", so when S3 appended four kinds it read 19 instead of 23 and the differential
// silently stopped requiring the new ones. Nothing here is spelled that way:
//
//  1. the enumerator list and the pinning list ARE THE SAME LIST -- both are expansions of
//     `CSS_CALC_SWIFT_FOR_EACH_ALTERNATIVE` -- so an added enumerator is an added assert, and there
//     is no second list to forget;
//  2. `numberOfCSSCalcSwiftAlternatives` counts the list rather than reading the last enumerator,
//     and CSSCalcTree+Serialization.cpp holds it equal to `std::variant_size_v<Node>`, so an
//     alternative added to `Node` without a line here is a build failure;
//  3. each pairing is pinned with `WTF::alternativeIndexV<T, Node>`, whose own
//     `static_assert(count == 1)` (StdLibExtras.h:617) additionally rejects a duplicated
//     alternative type;
//  4. the bridge reports `std::variant_size_v<Node>` to the harness rather than any enumerator, so
//     the differential's coverage guard is driven by the variant too.
//
// The second macro argument is the alternative's C++ type. It is inert in this header -- a macro
// body is not parsed until it is expanded, and the expansions here ignore it -- which is what lets
// a self-contained boundary header that must not include CSSCalcTree.h still name
// `IndirectNode<Sum>` for the benefit of the translation unit that can.
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

// The length of the list above, counted FROM the list. Not "the last enumerator + 1"; see point 2.
#define CSS_CALC_SWIFT_COUNT_ALTERNATIVE(name, type) + 1
static constexpr uint8_t numberOfCSSCalcSwiftAlternatives = 0 CSS_CALC_SWIFT_FOR_EACH_ALTERNATIVE(CSS_CALC_SWIFT_COUNT_ALTERNATIVE);
#undef CSS_CALC_SWIFT_COUNT_ALTERNATIVE

// Which non-tree argument of an operation node an `appendOperationArgument` upcall should write.
//
// Declared in Swift as `CSSCalcSwiftOperationPart` and reaching C++ through
// WebCoreSwift-Generated.h, for the reason `CSSCalcSwiftLiteral` gives: Swift produces the choice
// and C++ consumes it, so the single declaration belongs on the producing side, and the switch in
// `appendOperationArgument` is over those *names*.

// Everything S3's four operations need that is neither a child subtree nor text, from ONE crossing.
//
// A second accessor rather than more fields on `CSSCalcSwiftNodeInfo`, because `info()` is called
// once per node on every walk of every calc() in every stylesheet and these fields are meaningful
// for four rare kinds. Fetched only when the kind says so.
//
// Every field is a `bool` rather than a bit in a flags word. The flags spelling reads as
// `(info.flags & UInt8(Flag.randomSharingIsKey.rawValue)) != 0` on the Swift side, which is the
// kind of expression a transcription error hides in; these are a handful of bytes on an accessor
// that runs for `anchor()` and `random()` only.
//
// The one *presence* test that is NOT here is `CalcMix`'s per-item weight, and that is deliberate:
// it is per item rather than per node, so surfacing it would need a second per-index accessor
// beside `childAt`. Instead the `calcMixWeight` upcall writes `' '` and the weight when the item
// has one and nothing when it does not -- one crossing instead of two, at the cost of one
// structural decision staying in C++. It is the only one in the island.
struct CSSCalcSwiftOperationInfo {
    // `Anchor`: the `<anchor-side>` keyword, when `anchorSideIsKeyword`.
    // `AnchorSize`: the `<anchor-size>` dimension keyword, when `hasDimension`.
    // `Random`: `property-scoped` or `property-index-scoped`, when `randomKeyHasPropertyScope`.
    // `CSSValueInvalid` otherwise, so a reader that consults it for the wrong kind gets a defined
    // wrong answer rather than garbage.
    uint16_t valueID;

    // `Random`: which alternative `sharing` holds. Both false means `auto`, which serializes as
    // omitted -- so there is no third flag, and the island's `else` is the `auto` case.
    bool randomSharingIsKey;
    bool randomSharingIsFixed;
    // `Random` with a `<random-cache-key>`: which of the key's three optional parts are present.
    // The parser never produces an empty key, but the island does not rest on that -- it writes the
    // separators from these three and an empty key would come out empty rather than wrong.
    bool randomKeyHasName;
    bool randomKeyIsElementScoped;
    bool randomKeyHasPropertyScope;

    // `Anchor`: whether `<anchor-side>` is a keyword. When false it is a `<percentage>` subtree and
    // occupies child 0, which is what makes the fallback's index depend on this.
    //
    // A `bool` rather than "`valueID` is `CSSValueInvalid`", so that the island never has to name a
    // sentinel value from the generated keyword table.
    bool anchorSideIsKeyword;

    // `Anchor` and `AnchorSize`: whether an `<anchor-element>` dashed-ident is present.
    bool hasElementName;
    // `AnchorSize`: whether an `<anchor-size>` dimension keyword is present.
    bool hasDimension;
    // `Anchor` and `AnchorSize`: whether a fallback `<length-percentage>` is present. Redundant
    // with `childCount` and kept anyway, for the reason the two `ClampWithNone...` kinds are kept:
    // the island requires the two to AGREE and declines when they do not, so a boundary that came
    // apart is a decline rather than an argument written in the wrong position.
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
    // argument reports one child, not two, and the island never sees an absent one.
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
    // side: the island names an id and `appendValueIDName` owns how it is spelled.
    uint16_t valueID;
    // For the four numeric kinds: `toCSSUnit(node)`, i.e. the CSSUnitType underlying value.
    // A unit *number* rather than a unit string, so the island names a unit and C++ owns how it is
    // spelled -- the unit table is generated and must not be transcribed into Swift.
    //
    // FOR A `Symbol`, `Symbol::unit`, AND THAT IS NOT THE SYMBOL TABLE'S UNIT. The distinction is
    // the whole reason this field is filled for a fifth kind. `simplify(Symbol&)` is
    // `makeNumeric(value->value, root.unit)` (CSSCalcTree+Simplification.cpp:516-524): the VALUE
    // comes from `CSSCalcSymbolTable` and the UNIT from the node, which the parser took from
    // `CSSCalcSymbolsAllowed` (CSSCalcTree+Parser.cpp:1582). Those are two independently populated
    // `HashMap`s, so an island that read the unit off the table's answer would fold `Symbol{r, Deg}`
    // under an `{r -> 1px}` table into a length where the C++ makes an angle. Free in bytes: the
    // field existed and was inert for a `Symbol`.
    uint8_t unitType;
    // The discriminant. Typed as the enum rather than as a raw value, so the island's `switch` is
    // checked for exhaustiveness by the compiler.
    CSSCalcSwiftNodeKind kind;
    // For `Percentage`: the node's `hint`, as `Type::PercentHint`'s underlying value, and 0 for
    // none. NO SENTINEL IS INVENTED for that: `CSSCalcType.h:53` numbers `PercentHint` from 1
    // precisely so that 0 is `Type::PercentHintValue`'s internal `None`, and this field is that
    // representation unchanged. Inert (0) for every other kind.
    //
    // The simplification island needs it because `makeChildWithValueBasedOn(value, const
    // Percentage&)` carries `hint` onto the result (CSSCalcTree.cpp:318), so an island that folded
    // two percentages and did not carry the hint would produce a node the C++ arm would not.
    //
    // THIS FIELD IS NOT FREE, and saying so is the point of this paragraph. The five fields above
    // pack to exactly 16 bytes with no padding (8 + 4 + 2 + 1 + 1), so a seventeenth byte takes the
    // struct to 24 and moves the AArch64 return from x0/x1 to an indirect `sret`. Priced rather
    // than assumed: `info()` is not a two-instruction accessor -- it already runs a 41-alternative
    // `switchOn` and then a second full pass over the children in `childNodeCount` -- so a store
    // and a load is a small addition to it, but it is an addition and it is on the per-node path.
    // The free alternative was rejected deliberately: `valueID` is inert for `Percentage` and the
    // two are kind-disjoint, so the hint could ride in it at zero cost, and that is a field with
    // two unrelated meanings on a boundary whose legibility is what keeps the two arms in step.
    uint8_t percentHint;
    // WHICH of `Node`'s 41 alternatives this is, exactly -- see `CSSCalcSwiftAlternative`, which
    // says why the 23-case `kind` beside it cannot answer that and why no existing WebCore enum
    // could be imported instead.
    //
    // AND THIS ONE IS FREE, which is the whole reason it is a field on `info()` rather than a
    // second accessor. The paragraph above is right that `percentHint` took the struct from 16
    // bytes to 24 and the AArch64 return from x0/x1 to an indirect `sret`; the arithmetic it gives
    // is 8 + 4 + 2 + 1 + 1 = 16 exactly, then 17 rounding up to 24. Seventeen live bytes in a
    // 24-byte struct leave SEVEN of tail padding, so this is the eighteenth of twenty-four and
    // `sizeof` does not move. Held to that rather than argued: CSSCalcTree+Serialization.cpp
    // `static_assert`s `sizeof(CSSCalcSwiftNodeInfo) == 24`, so a future field that does grow the
    // struct has to say so.
    //
    // GETTING BACK TO 16 was tried and is not takeable in this change, and the reason is worth
    // recording because the obvious moves all fail. Eighteen live bytes have to become sixteen, and
    // there are exactly three ways: (i) alias two kind-disjoint fields into one byte -- `unitType`
    // is inert for every non-leaf and the alternative id is redundant with `kind` for the four
    // numeric leaves, so the pair genuinely fits, but that is the "field with two unrelated
    // meanings" the paragraph above already rejects by name, and doing it twice over is worse, not
    // better; (ii) narrow `childCount` to `uint16_t`, which introduces a truncation with no channel
    // to report it on -- a `Sum` with more than 65,535 terms is not real content but the CHECK for
    // it would have to be, and there is no spare enumerator to signal it; (iii) move `childCount`
    // out to its own accessor, which is the one that actually pays -- it leaves 14 live bytes,
    // returns `info()` to registers, AND removes the `childNodeCount` walk from the four numeric
    // leaves, which never have children. That is a change to the accessor the LANDED serialization
    // island calls once per node, so it is a measurement this change cannot make and must not
    // assert; it is recorded as the named next step for the first session that can build and run
    // cssbench.
    CSSCalcSwiftAlternative alternative;
};

// A borrowed cursor onto one node of a live CSSCalc::Tree.
//
// Always a `Child`, i.e. a subtree, which is what keeps this an 8-byte handle with nothing to
// discriminate. `clamp()`'s `none` bound is the one argument that is not a subtree, and it is carried
// by the parent's *kind* rather than by a cursor that could point at something else -- see
// `CSSCalcSwiftNodeKind::ClampWithNoneMinimum`.
//
// `SWIFT_NONESCAPABLE` is the point: the handle borrows a node owned by a tree on the C++ stack,
// and `~Escapable` is what makes the compiler enforce that it cannot outlive the borrow. Arm 13
// showed the Escapable spelling also reaches zero `unsafe`, so this is a safety choice rather
// than a necessity, and it is the stronger of the two.
//
// Three annotations are load-bearing and each was established with a control that fails without
// it (arm 12's six-way spelling matrix, arm 13C):
//
//   - `SWIFT_SAFE` clears the residual unsafety of the private `const Child*` member. Without it
//     every call site needs an `unsafe` marker; that is arm 13C.
//   - the constructors' `@lifetime(immortal)` / `@lifetime(copy node)` are what make a method
//     *returning* this type import at all rather than being silently dropped (filings register
//     §33). The ingredient is on the returned type, not the accessor.
//   - `[[clang::lifetimebound]]` on `childAt` is what makes it import *without a warning*. §33
//     recorded that attribute as observably inert in this position, but that was measured where
//     the returned type was a different view whose constructors were unannotated; with annotated
//     constructors and a self-returning accessor it is the one spelling of six that is clean.
//     The other five (`@lifetime(borrow self)` and `@lifetime(copy self)`, prefix and postfix,
//     and the underscored form) all import but each leave one #ClangDeclarationImport warning.
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

    // Everything about this node, from ONE crossing.
    //
    // Five separate accessors (`kind`, `childCount`, `numericValue`, `unitType`, `valueID`) were
    // written first and consolidated into this, for two reasons that point the same way. It is
    // ~20 fewer lines of hand-written bridging, which is the metric this port is held to; and it
    // turns four or five calls per leaf node into one, where each of those calls was a separate
    // `WTF::switchOn` over the same 41-alternative `Variant` -- so C++ was re-deriving the same
    // discriminant up to five times per node to answer questions it could answer together.
    WEBCORE_EXPORT CSSCalcSwiftNodeInfo info() const;

    // Everything S3's four operations need beyond `info()`, from one more crossing.
    //
    // Separate from `info()` rather than folded into it because `info()` runs for every node of
    // every tree and this answers questions only four kinds ask. The island calls it exactly when
    // the kind says to.
    WEBCORE_EXPORT CSSCalcSwiftOperationInfo operationInfo() const;

    // The `index`th child, IN SERIALIZATION ORDER.
    //
    // For `Sum` and `Product` that is not tree order: css-values-4 steps 6 and 7 both begin "Sort
    // root's children", and the sort key is `sortPriority`, a 60-case unit order generated with
    // `__COUNTER__` (CSSCalcTree+Serialization.cpp:146). Transcribing that table into Swift is
    // exactly the duplication this port is not allowed to do, and handing Swift a permutation to
    // apply would need a buffer the boundary would have to own. So C++ answers in the sorted order
    // it already computes, the same way it already answers `formatCSSNumberValue` -- the island
    // names a position and C++ owns what that position means. Every other kind answers in tree
    // order, because no other kind sorts.
    //
    // Linear, so a full walk is quadratic in the node count, and for Sum and Product it also
    // re-sorts per access. That is deliberate and priced rather than assumed: a calc expression's
    // tree is a handful of nodes (the deepest in the whole WPT css-values corpus is single digits),
    // and the alternative -- handing Swift a child *list* -- is either a buffer the boundary would
    // have to own or a second representation of the tree, which is exactly the goop this design
    // exists to avoid. If a measurement finds it, the fix is an iterator handle, not a flattened
    // array.
    WEBCORE_EXPORT CSSCalcSwiftNode childAt(uint32_t index) const [[clang::lifetimebound]];

    // The `index`th child, IN TREE ORDER -- what `forAllChildNodes` yields, unsorted.
    //
    // A second accessor rather than a flag on `childAt`, because the two orders are wanted by two
    // different islands and each wants only one of them. Serialization must have the SORTED order
    // for `Sum` and `Product` (css-values-4 steps 6 and 7 begin "Sort root's children"), and
    // simplification must have the TREE order for the same two: it reconstructs the node from its
    // children, and reconstructing a `Sum` from its children in sort order would silently permute
    // every multi-unit sum in the document. Nothing outside `Sum` and `Product` distinguishes them.
    //
    // THE COUNT IS THE SAME ONE. `info().childCount` is `childNodeCount`, which counts what
    // `forEachChildNodeOfChild` yields and is order-independent -- sorting a `Sum`'s children
    // permutes them, it does not add or drop any -- so there is no second count and none is
    // declared here. That is worth stating rather than leaving to be re-derived, because a count
    // that silently belonged to the other order is exactly the boundary defect this pair could
    // have.
    //
    // Linear per access, so a full walk is quadratic in the child count, for the reason `childAt`
    // gives at length and on the same evidence.
    //
    // `[[clang::lifetimebound]]`, prefix, and nothing else: the six-way spelling matrix in arm 12
    // found it is the one of six that imports without a #ClangDeclarationImport warning, and this
    // accessor is the same shape as `childAt` (self-returning, annotated constructors) that the
    // matrix was run against.
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

// Where the island's output goes.
//
// C++ owns the buffer and the number formatting; Swift says what to append. That split is not a
// convenience, it is the single most important correctness decision in this slice.
// `formatCSSNumberValue` MUST be an upcall: Swift's `Double.description` is shortest-round-trip
// and CSS number serialization is a different algorithm, so a Swift reimplementation would agree
// on every common value -- passing every WPT test in the corpus -- and diverge on subnormals and
// 17-significant-digit values. There is no test in this repository that would have caught it.
//
// A `SWIFT_SAFE` *value* struct taken `inout`, rather than the `SWIFT_SHARED_REFERENCE` over
// `ThreadSafeRefCounted` that CSSSwiftTokenSink uses. Both reach zero `unsafe` (probe arms 13A
// and 13B), and this one is better here: the sink lives on the C++ stack for exactly one
// `serializationForCSS` call, so a refcounted sink would cost a heap allocation per call on a
// path `cssText` and getComputedStyle reach, and "immortal" would be a claim that is not true.
// A value struct claims nothing.
struct SWIFT_SAFE CSSCalcSwiftSink {
    CSSCalcSwiftSink(WTF::StringBuilder& builder [[clang::lifetimebound]], const CSS::SerializationContext& context [[clang::lifetimebound]])
        : m_builder(&builder)
        , m_context(&context)
    {
    }

    // Every method is non-const, so the importer presents them as `mutating` and the island takes
    // the sink `inout`. That is the honest shape: appending is a mutation.

    // ONE entry for every fixed spelling the island emits, selected by `CSSCalcSwiftLiteral` --
    // which is declared once, in Swift, and reaches C++ through WebCoreSwift-Generated.h. S0 had
    // three separate named methods here (`appendCalcOpen`, `appendCloseParen`, `appendEmptyParens`)
    // and S1 needs seven more: `(`, ` + `, ` - `, ` * `, ` / `, `-1 * `, `1 / `. Ten named methods
    // is ~40 lines of C++ written to facilitate Swift, against ~14 for one entry and a switch, and
    // the switch also puts the *numbering* on the side that produces it, so there is no table of
    // spellings on the Swift side and nothing to keep in sync.
    //
    // It does convert a compile-time choice into a run-time one, which this project normally counts
    // against a boundary. Priced honestly: the C++ arm this replaces already makes the same choice
    // at run time -- `state.openGroup()` is a ternary returning one of two `ASCIILiteral`s, read
    // per node -- and no text crosses the boundary either way, so there is still exactly one copy
    // of every CSS literal in the program and it is in C++.
    //
    // `uint8_t` rather than the imported enum type because this header is what the generated header
    // is generated *from*; it cannot see the Swift enum's C name.
    WEBCORE_EXPORT void appendLiteral(uint8_t literal);

    // THE UPCALL. Routes to CSS::serializationForCSS over a CSS::SerializableNumber, which is
    // what the C++ serializer at CSSCalcTree+Serialization.cpp:589 does, so the two arms share
    // one number-formatting implementation by construction rather than by comparison.
    WEBCORE_EXPORT void appendNumber(double value, uint8_t unitType);

    // `nameLiteralForSerialization(CSSValueID)`, for Symbol, SiblingCount and SiblingIndex. The
    // island names the id; C++ owns the table, which is generated and must not be transcribed.
    WEBCORE_EXPORT void appendValueIDName(uint16_t valueID);

    // THE SECOND UPCALL, and it exists for the same reason the first does: S3's four operations
    // carry arguments that are CSS values rather than calculation trees, and every one of them must
    // be spelled by C++.
    //
    // `<dashed-ident>` goes through `CSS::serializationForCSS` over a `CSS::CustomIdent`, which
    // escapes identifiers; `random()`'s `fixed <number>` is a `CSS::Number<ClosedUnitRange>` and
    // `calc-mix()`'s weight a `CSS::Percentage<ClosedPercentageRange>`, both of which are
    // `PrimitiveNumeric` types that the C++ serializer hands to `CSS::serializationForCSS`
    // directly. Routing them through `appendNumber` instead would mean the island deciding they are
    // plain doubles in a known unit, which is a claim about types it cannot see -- so this calls
    // exactly what the C++ arm calls, and the two agree by construction rather than by comparison.
    // Same rule, same reason, as `formatCSSNumberValue`.
    //
    // ONE entry selected by `part` rather than four named methods, for the reason `appendLiteral`
    // gives: four methods is ~28 lines of C++ written to facilitate Swift against ~20 for one
    // entry and a switch, and the numbering lives on the side that produces it.
    //
    // `index` is meaningful only for `calcMixWeight`, where it selects the item.
    //
    // BY `const&`, AND THAT IS LOAD-BEARING. Taken by VALUE this method imports as `unsafe` and
    // every call site needs a marker -- the sink's struct-level `SWIFT_SAFE` does not reach a
    // parameter that is itself `~Escapable`. Measured, with the three sink methods above as the
    // control since they take only PODs and are clean:
    //
    //   by value, no annotation ......................... 1 unsafe call
    //   SWIFT_SAFE on the method, prefix or postfix ..... 1 unsafe call  (the annotation is INERT
    //                                                     in this position -- it is not the cure,
    //                                                     and reaching for it would have looked
    //                                                     like one)
    //   [[clang::lifetimebound]] on the parameter ....... does not compile
    //   **by const reference ............................ 0**
    //
    // Reproducer: ~/src/webkit-swift-ports/cssprobe/calcimport/s3safe/ (`probe.swift`, seconds to
    // run, and it fails on the baseline so it is not a vacuous pass).
    WEBCORE_EXPORT void appendOperationArgument(const CSSCalcSwiftNode&, uint8_t part, uint32_t index);

private:
    WTF::StringBuilder* m_builder;
    const CSS::SerializationContext* m_context;
};

// What the island did, and what it saw doing it.
//
// `outcome` is the gate's answer: 0 serialized, 1 declined. The other two fields are what make
// the walk *observable* rather than something the differential has to take on trust. A decline is
// invisible -- it reads as parity, because it compares the C++ against itself -- and so is a walk
// that never descended. `nodeCount` and `kindMask` come back from the same traversal that made
// the decline decision, cost nothing (three registers), and let the harness assert that the tree
// was really walked and that every kind it expected to reach was reached.
//
// A plain aggregate of trivial types, so it crosses in registers and needs no annotation.
struct CSSCalcSwiftSerializationResult {
    // Bit `1 << rawValue` set for each CSSCalcSwiftNodeKind the walk stood on.
    uint32_t kindMask;
    // How many nodes the walk visited, root included.
    uint32_t nodeCount;
    // 0 = serialized, 1 = declined. Not a `bool`, so adding a third outcome in S1 is not an ABI
    // change; the numbering is pinned by static_assert against the Swift enum.
    uint8_t outcome;
};

// MARK: - The Swift calc SIMPLIFICATION island (CSSCalcSimplificationSwift.swift)
//
// Everything below belongs to the second island on this tree. It shares `CSSCalcSwiftNode`,
// `CSSCalcSwiftNodeInfo` and `CSSCalcSwiftNodeKind` with the serialization island above -- the
// read-only half of the boundary was already exactly what a simplifier needs to walk -- and adds
// the half that did not exist: a way for Swift to CONSTRUCT nodes.
//
// THE ONE CONSTRAINT THAT SHAPED ALL OF IT: no operation kind ever crosses in the construction
// direction. Simplification is a tree-to-tree rewrite in which the output node's kind is, with a
// single exception, the input node's kind -- so `rebuildFrom` recovers the kind from the ORIGINAL
// node's own variant tag and reconstructs generically over the tuple conformance, and Swift never
// names one of the 34 operations. The exception is `clamp()` becoming `min()` or `max()`
// (CSSCalcTree+Simplification.cpp:1012-1038), and it gets `buildMinMax` and nothing else. A design
// in which Swift said "make me a `Hypot`" would have put the 41-way operation table on the Swift
// side and a 41-case construction switch on the C++ side, which is the shape this port exists not
// to produce.

// A numeric leaf the island wants built, in the ONE representation the boundary has for one.
//
// `CanonicalDimension::Dimension` IS NOT CARRIED. It is recovered from `unitType` by `makeNumeric`
// (CSSCalcTree.cpp:187), which is the same function that already maps a `CSSUnitType` onto the
// right one of the four numeric alternatives for every other producer in the tree -- so the island
// reuses that classification rather than restating it, and there is no second place where "Dppx
// means Resolution" is written down. The forward direction is `toCSSUnit` (CSSCalcTree.h:992),
// which is what `info().unitType` reports, so a leaf read out and pushed straight back is a round
// trip through those two.
//
// That round trip is NOT static_assertable and it would be dishonest to write an assert that looks
// like it is: `toCSSUnit` is `constexpr` but `makeNumeric` is an out-of-line switch in a .cpp, so a
// `static_assert` here could only restate `toCSSUnit`'s own header and would pass whatever
// `makeNumeric` did. The check that has information in it is the differential, which round-trips
// every numeric leaf in the corpus.
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
// ONE type for BOTH of the builder's two lookups -- the symbol table and unit canonicalization --
// because both answer exactly that shape, and one boundary type is one fewer thing that can drift.
// Returned by value rather than written through an out-parameter so that no reference crosses in
// the argument position at all: at 16 bytes it comes back in registers, and there is no `inout`
// import to reason about.
struct CSSCalcSwiftNumericResult {
    double value;
    // A `CSSUnitType` underlying value. Inert (`CSSUnitType::Unknown`) when `resolved` is false.
    //
    // For `resolveSymbol` this is `toCSSUnit` OF THE LEAF `makeNumeric` BUILT, not the unit that was
    // asked about, so that `Integer` comes back as `Number` and the island's round trip back through
    // `pushLeaf` -- which calls `makeNumeric` again -- lands on the same alternative. For
    // `canonicalizeUnit` it is `toCSSUnit(canonical->dimension)`.
    uint16_t unitType;
    // False means "no answer", which for both lookups is a normal outcome and not an error: an
    // unresolved `<calc-keyword>` and a `1em` with no conversion data both simply stay as they are.
    bool resolved;
    // WHICH of the four numeric alternatives `makeNumeric` built, so the island does not have to
    // work it out.
    //
    // THE FIELD EXISTS TO KEEP A SEVENTY-CASE UNIT TABLE OUT OF SWIFT. `simplify(Symbol&)` is
    // `copyAndSimplify(makeNumeric(value, root.unit), options)`, and the island has to report the
    // folded leaf to its parent -- which means naming its alternative. `makeNumeric`
    // (CSSCalcTree.cpp:187-286) chooses among `Number`, `Percentage`, `CanonicalDimension` and
    // `NonCanonicalDimension` over seventy `CSSUnitType` cases; reproducing that choice on the
    // island would be a duplicated generated table, which is the one thing this port counts as goop
    // by name. So C++ answers it, from `makeNumeric` itself rather than from a restatement of it,
    // and there is no second place in the program where "Dppx means Resolution" is written down.
    //
    // FREE IN BYTES, measured rather than assumed: 8 + 2 + 1 + 1 = 12 live bytes in a struct that
    // aligns to 8, so `sizeof` was 16 before this field and is 16 after it, and the result still
    // comes back in registers. Held to that by the `static_assert` below, so a future field that
    // does grow it has to say so.
    //
    // Inert (`Number`) when `resolved` is false. `canonicalizeUnit` always answers
    // `CanonicalDimension` when it resolves, by construction -- that is what canonicalizing is --
    // and it is filled there anyway rather than left to the caller's memory.
    CSSCalcSwiftAlternative alternative;
};

// 8 + 2 + 1 + 1 = 12 live bytes, aligned to 8. See `alternative` above: this is the assert that
// makes "the field is free" a check rather than a claim.
static_assert(sizeof(CSSCalcSwiftNumericResult) == 16);

// The parts of `CSSCalc::SimplificationOptions` the island reads, from one crossing.
//
// A plain aggregate of trivial types. The three things `SimplificationOptions` actually holds that
// are not trivial -- `conversionData`, `symbolTable`, and the `CSS::Category` enum -- stay on the
// C++ side, and each is here in the reduced form the island needs rather than as itself.
struct CSSCalcSwiftSimplificationOptions {
    // `options.range.min` and `options.range.max`. Two doubles rather than a `CSS::Range`, for the
    // reason the serialization entry gives: `clampValue` reads only those two, and the two
    // `RangeParseTimeBehavior` members are the parser's.
    double rangeMinimum;
    double rangeMaximum;
    // `CSS::Category`'s underlying value. Carried for completeness -- the island's `switch` on it
    // is the predicate below -- and inert for everything else.
    uint8_t category;
    bool allowZeroValueLengthRemovalFromSum;
    // Whether `options.conversionData` holds a value. The island cannot be given
    // `CSSToLengthConversionData` and does not want it: every use of it is inside
    // `canonicalizeUnit` and the two sibling-function upcalls. What the island needs is only
    // whether a canonicalization COULD succeed, which is this bool.
    bool hasConversionData;
    // PRECOMPUTED IN C++ ON PURPOSE, and this is the one derived field here. It is
    // `percentageResolveToDimension(options)` (CSSCalcTree+Simplification.cpp:80-101), an
    // eleven-case `switch` over `CSS::Category` that is true for exactly two of them
    // (`AnglePercentage`, `LengthPercentage`). Deriving it once here is one `bool`; deriving it in
    // Swift would mean the eleven-case `CSS::Category` enum crossing the boundary as a thing the
    // island switches over -- a second copy of a category table, for a predicate whose whole
    // content is "is it one of these two". `category` still crosses so that a later slice needing
    // the category itself does not have to widen this struct, but nothing reads it yet.
    bool percentageResolveToDimension;
};

// Where the simplification island's output goes: the construction sink.
//
// Modelled on `CSSCalcSwiftSink` above and obeying the same four rules its comments establish, each
// for the same measured reason -- a `SWIFT_SAFE` value struct taken `inout` rather than a
// `SWIFT_SHARED_REFERENCE` (the builder lives on the C++ stack for exactly one `copyAndSimplify`
// call, so a refcounted one would cost a heap allocation per call); every `CSSCalcSwiftNode`
// parameter by `const&`, never by value, because by value each one imports as `unsafe` and needs a
// marker at every call site (measured, `CSSCalcSwiftSink:433`-`:447`); one entry rather than N
// named methods wherever a selector can carry the choice; and anything whose exact output must
// match the C++ arm stays an upcall.
//
// It is an OPERAND STACK, not a node factory. Swift walks the tree post-order and pushes each
// finished subtree; a parent then says how many operands it consumes and gets one back. That is
// what lets `rebuildFrom` be generic: the operands are already `CSSCalc::Child`s that C++ built,
// so reconstruction never has to name what is in them, only how many there are and which slot each
// one goes in. It is also what keeps `~Escapable` out of the picture entirely -- no Swift container
// ever holds a `Child`, because the container is the C++ stack.
struct SWIFT_SAFE CSSCalcSwiftBuilder {
    CSSCalcSwiftBuilder(CSSCalcSwiftOperandStack& operands [[clang::lifetimebound]], const SimplificationOptions& options [[clang::lifetimebound]])
        : m_operands(&operands)
        , m_options(&options)
    {
    }

    // Build one of the four numeric leaves and push it. See `CSSCalcSwiftLeaf`.
    //
    // Returns false for a `kind` outside the four numeric leaves, which is a contract violation
    // rather than an input the island can meet, and it declines rather than building something
    // plausible.
    WEBCORE_EXPORT bool pushLeaf(CSSCalcSwiftLeaf);

    // Deep-copy an input subtree and push it. What the island uses for every node it walks past
    // without changing, and for every child of a node it declines to rewrite.
    //
    // Routes to `CSSCalc::copy(const Child&)`, which is the copy the C++ arm's own
    // `copyAndSimplifyChildren` bottoms out in, so the two arms cannot disagree about what a copy
    // is. That overload had to be DECLARED for this -- CSSCalcTree+Copy.h exposed only `Tree` and
    // `AnchorSide`, while `Child` was one of ten `static` overloads inside CSSCalcTree+Copy.cpp --
    // which is one line of header and the removal of one `static`, and is the smallest thing that
    // works. Nothing new was written.
    WEBCORE_EXPORT void pushCopyOf(const CSSCalcSwiftNode&);

    // THE CRUX. Pop `childCount` operands and push back one node OF `original`'s OWN KIND, built
    // from them.
    //
    // This is the method that makes principle one hold. C++ recovers the operation from
    // `original`'s variant tag with `WTF::switchOn` and fills its slots with `WTF::apply` over the
    // tuple conformance (CSSCalcTree.h:1277-1319) -- the same two-line shape
    // `copyAndSimplifyChildren` (CSSCalcTree+Simplification.cpp:1786) and `copy`
    // (CSSCalcTree+Copy.cpp:103) already use -- so all 34 operations are served by one spelling and
    // the island never names one. The `Type` is `getType(original)`, which is what
    // `copyAndSimplify` uses at CSSCalcTree+Simplification.cpp:1814.
    //
    // A `Children`-slotted operation (`Sum`, `Product`, `Min`, `Max`, `Hypot`, and `CalcMix`'s
    // item vector) takes ALL `childCount` operands, which is what lets the island change those
    // operations' ARITY -- dropping a zero term from a sum is the commonest simplification there
    // is. Every other slot shape takes exactly one operand or none, following the original's own
    // shape for `std::optional<Child>` and `ChildOrNone`.
    //
    // Returns false rather than asserting on a contract violation -- too few operands, an arity
    // that does not match a fixed-slot operation, a leaf, or an `Anchor`/`AnchorSize` -- and the
    // island turns that into a decline. Those last two are structural: they declare `tuple_size` 0
    // (CSSCalcTree.h:1317, "FIXME (webkit.org/b/280798): make Anchor and AnchorSize tuple-like"),
    // so generic reconstruction would build them EMPTY, and no amount of care at this end fixes
    // that. They are the one place the tuple conformance is a lie, and this is where it stops.
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
    // means "the C++ would not have made this node either", and the island must decline rather
    // than treat it as impossible.
    WEBCORE_EXPORT bool buildMinMax(bool isMax, uint32_t childCount);

    // THE FIRST UPCALL: `simplify(Symbol&)` (CSSCalcTree+Simplification.cpp:516-524) in full --
    // `makeNumeric(options.symbolTable.get(id)->value, unit)`.
    //
    // In C++ because the table is a `HashMap<CSSValueID, ...>` living on the options, and the
    // options are not a thing the island holds -- `CSSCalcSwiftSimplificationOptions` is the
    // reduction of them, and a hash map is not reducible to a POD. The island names an id and C++
    // owns the lookup, which is the same split `appendValueIDName` uses on the serialization side.
    //
    // BOTH HALVES CROSS BECAUSE THE C++ USES BOTH HALVES, and getting that wrong is a silent
    // divergence rather than a decline. The VALUE is the table's; the UNIT is the SYMBOL NODE's
    // (`Symbol::unit`, which the island reads from `info().unitType` and passes back down here), and
    // the two come from independently populated `HashMap`s -- `CSSCalcSymbolTable` and
    // `CSSCalcSymbolsAllowed` (CSSCalcTree+Parser.cpp:1582). Taking the unit from the table's answer
    // instead would fold `Symbol{r, Deg}` under an `{r -> 1px}` table into a length where the C++
    // makes an angle, and no differential over a corpus whose two tables happen to agree would see
    // it.
    //
    // The `unit` parameter is what lets the answer carry `alternative`: the island cannot classify a
    // unit without transcribing `makeNumeric`'s seventy cases, so `makeNumeric` is called here and
    // its own choice is reported. See `CSSCalcSwiftNumericResult::alternative`.
    WEBCORE_EXPORT CSSCalcSwiftNumericResult resolveSymbol(uint16_t valueID, uint16_t unit) const;

    // THE SECOND UPCALL: `canonicalize(NonCanonicalDimension, options.conversionData)`
    // (CSSCalcTree+Simplification.cpp:169-287).
    //
    // STAYS IN C++, and this is a decision rather than a default. Three things decide it, and the
    // first is dispositive on its own:
    //
    //  1. Swift cannot see the constants. `CSS::pixelsPerCm` and its nine siblings are in
    //     CSSUnits.h, which is in the `Core` umbrella module the islands may not import -- and it
    //     cannot be given a module of its own as CSSUnitType.h was, because it is not
    //     self-contained (it declares `ASCIILiteral unitTypeString(CSSUnitType)` at :83 with no
    //     include that provides `ASCIILiteral`). `degreesPerRadianDouble` is in wtf/MathExtras.h,
    //     which no island imports either. Checked, not assumed.
    //  2. Forty of the seventy cases resolve nothing themselves: they forward to
    //     `Style::resolveLength` over `CSSToLengthConversionData`, which is an upcall whatever
    //     happens. So a Swift port would move fourteen constant multiplications across and would
    //     have to transcribe the forty-unit "is this a font/viewport/container-relative length"
    //     membership set to know which ones to forward -- which is `CSS::toLengthUnit`
    //     (CSSPrimitiveNumericUnits.h:609) restated, i.e. a duplicated table, which is the one
    //     thing this port counts as goop by name.
    //  3. It would not be deletable either way. `canonicalize` has a second caller in
    //     CSSCalcTree+Evaluation.cpp:143, so all 119 lines stay compiled in whatever the island
    //     does, and a Swift copy would be an eighty-line SECOND implementation of a table that is
    //     still there -- with the differential's agreement then a coincidence rather than a
    //     construction.
    //
    // The answer is `nullopt` -- `resolved == false` -- exactly when the C++ returns `nullopt`,
    // which for the relative units means "no conversion data", and the island leaves the dimension
    // alone in that case just as `simplify(NonCanonicalDimension&)` does.
    WEBCORE_EXPORT CSSCalcSwiftNumericResult canonicalizeUnit(double value, uint16_t unitType) const;

private:
    CSSCalcSwiftOperandStack* m_operands;
    const SimplificationOptions* m_options;
};

// What the simplification island did, and what it saw doing it. Mirrors
// `CSSCalcSwiftSerializationResult` field for field EXCEPT in the width and the key of the mask,
// which is the one place the two results deliberately differ; see `kindMask`.
//
// `nodeCount` and `kindMask` ARE THE ANTI-VACUITY FIELDS and that is their only job. A whole-tree
// decline is invisible in an output comparison -- the C++ answer for a declined tree is the same
// C++ answer the comparison already trusts -- and so is a walk that agreed because it never
// descended. These two come back from the same traversal that made the decline decision, cost
// three registers, and let the harness assert that the tree was really walked and that every kind
// it claims coverage of was really reached. They are not diagnostics to be dropped once the island
// is trusted; they are what "trusted" is measured with.
struct CSSCalcSwiftSimplificationResult {
    // Bit `1 << rawValue` set for each `CSSCalcSwiftAlternative` the walk stood on -- 41 bits, so
    // `uint64_t`.
    //
    // KEYED ON THE ALTERNATIVE, NOT ON THE KIND, and this is not merely a widening. A mask over the
    // 23-case `CSSCalcSwiftNodeKind` cannot express the decline expectation at all: `min()` and
    // `mod()` share the `Function` kind, this slice handles one and declines the other, so the
    // predicate the differential wants --
    //
    //     expectedDecline = (inputKindMask & ~handledMask) != 0
    //
    // -- is not writable over a mask whose bits lump the two together. Over the alternative index
    // it is exact, and it is exact over the WHOLE corpus rather than over the hand-labelled subset,
    // which is the difference between a decline classification that is checked and one that is
    // declared. `simplifycheck.cpp` computes exactly that expression from this field.
    //
    // `CSSCalcSwiftSerializationResult::kindMask` is deliberately NOT changed with it. That island
    // is landed, its question really is "which serialization shapes did the walk stand on", and 23
    // kinds in 32 bits is the right answer to it. Two results, two questions.
    uint64_t kindMask;
    // How many nodes the walk visited, root included.
    uint32_t nodeCount;
    // 0 = simplified, 1 = declined. Not a `bool`, so a third outcome is not an ABI change; the
    // numbering is pinned by static_assert in CSSCalcTree+Simplification.cpp against the Swift
    // enum that declares it.
    uint8_t outcome;
    // WHICH alternative made the island decline -- a `CSSCalcSwiftAlternative` raw value, or 0xFF
    // for "did not decline" and for "declined without one alternative to blame".
    //
    // AN UNATTRIBUTED DECLINE IS ONE NOBODY CAN CLOSE, which is the whole argument for the field.
    // Without it the only thing a differential can say about a decline is that it happened; with
    // it, the harness checks the island's REASON against the reason it derived independently --
    // `(inputKindMask & ~handledMask)` must contain this bit -- and an island that declined
    // correctly for the wrong reason stops passing. simplifycheck.cpp's guard 3b treats 0xFF on a
    // tree that does contain an unhandled alternative as a failure for exactly that reason.
    //
    // Free in bytes: 8 + 4 + 1 + 1 = 14 in a 16-byte struct, so it rides in padding that already
    // existed and the result still comes back in registers.
    uint8_t declineAlternative;
};

} // namespace CSSCalc
} // namespace WebCore
