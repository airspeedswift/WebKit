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

// Everything the Swift calc serialization island (CSSCalcSerializationSwift.swift) is allowed to
// see of WebCore, and nothing else. Same shape and same reason as CSSTokenizerSwiftTypes.h next
// door: its own Clang module in WebCore_Private.modulemap, self-contained, so that importing it
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
    uint8_t unitType;
    // The discriminant. Typed as the enum rather than as a raw value, so the island's `switch` is
    // checked for exhaustiveness by the compiler.
    CSSCalcSwiftNodeKind kind;
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

private:
    // So that `appendOperationArgument` can reach the node it is being asked to write a piece of.
    // The alternative -- a public accessor handing out the `Child*` -- would put a raw pointer in
    // the Swift-visible surface of a type whose whole point is that no pointer crosses.
    friend struct CSSCalcSwiftSink;

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

} // namespace CSSCalc
} // namespace WebCore
