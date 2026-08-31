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

// Everything the Swift calc serialization code (CSSCalcSerializationSwift.swift) may see of
// WebCore. Its own Clang module in WebCore_Private.modulemap, self-contained, so importing it
// cannot walk the ~3,500-header PrivateHeaders umbrella into JavaScriptCore's private headers.
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

// What kind of node the walk is standing on.
//
// Declared here in C++ rather than in Swift with `@c`: C++ produces the kind and Swift consumes
// it, so the single declaration belongs on the producing side, and an `enum class ... : uint8_t`
// imports as an ordinary Swift enum that Swift can `switch` over exhaustively.
//
// A single `Operation` case is split into four operator kinds here -- the four whose
// serialization is the grouping-parenthesis state machine (css-values-4 steps 4 to 7). The other
// 30 `IndirectNode<Op>` alternatives stay collapsed into `Operation`, not yet named. The walk
// still descends through an `Operation`, which exercises the child accessors on the kinds a later
// phase will need.
//
// `OpaqueOperation` is `Anchor` and `AnchorSize`, and it exists because for exactly those two
// `childCount` lies. Both declare `tuple_size` 0 (CSSCalcTree.h:1317, "FIXME
// (webkit.org/b/280798): make Anchor and AnchorSize tuple-like"), so `forAllChildNodes` reports no
// children even though an `Anchor` holds an `AnchorSide` and an optional fallback `Child`. Without
// a separate kind, serializing operators generically would read `childCount == 0`, conclude "leaf",
// and emit an anchor() with its arguments silently dropped. A separate kind forces the compiler to
// make that a decision rather than leaving a trap in the data: the exhaustive `switch` has to say
// something about it, and what it says is "decline".
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
    uint32_t childCount;
    // For Symbol, SiblingCount and SiblingIndex: the CSSValueID underlying value.
    uint16_t valueID;
    // For the four numeric kinds: `toCSSUnit(node)`, i.e. the CSSUnitType underlying value.
    // A unit *number* rather than a unit string, so a unit is named here and C++ owns how it is
    // spelled -- the unit table is generated and must not be transcribed into Swift.
    uint8_t unitType;
    // The discriminant. Typed as the enum rather than as a raw value, so the `switch` over it is
    // checked for exhaustiveness by the compiler.
    CSSCalcSwiftNodeKind kind;
};

// A borrowed cursor onto one node of a live CSSCalc::Tree.
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

private:
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

} // namespace CSSCalc
} // namespace WebCore
