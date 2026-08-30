// Copyright (C) 2026 Apple Inc. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions
// are met:
// 1. Redistributions of source code must retain the above copyright
//    notice, this list of conditions and the following disclaimer.
// 2. Redistributions in binary form must reproduce the above copyright
//    notice, this list of conditions and the following disclaimer in the
//    documentation and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
// THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
// PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
// BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
// THE POSSIBILITY OF SUCH DAMAGE.

// Only this file's own boundary types, not the WebCore_Private umbrella -- see
// CSSCalcSwiftTypes.h for why.
public import WebCore_Private.CSSCalcSwiftTypes

// Swift port of CSSCalcTree+Serialization.cpp for CSS calc() serialization, selected by
// USE_SWIFT_CSS_CALC_SERIALIZATION.
//
// `Source/WebCore/css/calc/` is 10,110 lines across 31 files. `serializationForCSS` is a good entry
// point because its only context is a `CSS::Range` and a `CSS::SerializationContext`
// (URL-replacement state, inert for calc) -- it needs none of `conversionData`'s
// `Style::BuilderState` upcalls, and `css/calc/**` has no `double`->`float` narrowing to reproduce
// bit-for-bit. Two external call sites, both in CSSUnevaluatedCalc.cpp.
//
// This first slice retires no C++: it walks the whole tree through the borrowed handle, serializes
// the seven leaf kinds (the four numeric ones, `Symbol`, `sibling-count()` and `sibling-index()`),
// and declines everything else -- any tree containing an operator node, or at the `Computed` stage.
//
// The walk establishes coverage before anything is appended, because a partial emit cannot be
// undone: the builder is C++'s and has no truncate. It also reports a node count and kind mask,
// which cost three registers and let a test tell a tree that was fully covered apart from one that
// declined immediately.
//
// Number formatting is a C++ upcall (`sink.appendNumber` -> `formatCSSNumberValue`) rather than a
// reimplementation: Swift's `Double.description` is shortest-round-trip and CSS's algorithm is not,
// so they would agree on common values and diverge on subnormals and high-precision values.
//
// The tree crosses as a borrowed `~Escapable` handle and the output as a `SWIFT_SAFE` sink taken
// `inout`; neither is a pointer this file can see, so there is no `unsafe` marker here.

/// Whether this file serialized a tree, or left it for the C++ serializer.
///
/// `@c` (SE-0495) makes this the single declaration of the numbering: it is emitted into
/// WebCoreSwift-Generated.h and `static_assert`ed against these names in
/// CSSCalcTree+Serialization.cpp, so reordering these cases is a build failure there rather than a
/// silent reinterpretation of every calc() in every stylesheet. `frozen` because `@c` on a
/// resilient enum crashes IRGen and WebCore compiles with library evolution.
@frozen
@c
enum CSSCalcSwiftOutcome: UInt8 {
    /// This file wrote the complete serialization into the sink.
    case serialized = 0
    /// This file wrote nothing; the caller must run the C++ serializer.
    case declined = 1
}

/// One bit per `CSSCalcSwiftNodeKind`, for the mask the walk reports.
@inline(always)
private func kindBit(_ kind: WebCore.CSSCalc.CSSCalcSwiftNodeKind) -> UInt32 {
    return UInt32(1) << UInt32(kind.rawValue)
}

/// Whether this file can serialize a node of this kind on its own: the seven leaves, and no
/// operator.
///
/// Written as an exhaustive `switch` rather than a comparison against `.Operation`, so that
/// splitting further kinds out of `Operation` later cannot silently start claiming coverage it does
/// not have -- the compiler will demand a decision for each new case.
@inline(always)
private func isSerializableLeaf(_ kind: WebCore.CSSCalc.CSSCalcSwiftNodeKind) -> Bool {
    switch kind {
    case .Number, .Percentage, .CanonicalDimension, .NonCanonicalDimension:
        return true
    case .Symbol, .SiblingCount, .SiblingIndex:
        return true
    case .Operation:
        return false
    @unknown default:
        // A kind C++ grew and this file has not been taught. Declining is the only safe answer;
        // guessing would serialize a node whose spelling this file does not know.
        return false
    }
}

/// The traversal. Accumulates the node count and the kind mask, and reports whether every node it
/// saw can be serialized here.
///
/// Recursive rather than an explicit stack: calc trees are shallow -- the deepest expression in the
/// whole WPT css-values corpus is single digits of nodes -- and the parser bounds depth long before
/// this runs. An explicit worklist would need a Swift container of a `~Escapable` element, and no
/// standard container accepts one.
private func walk(
    _ node: borrowing WebCore.CSSCalc.CSSCalcSwiftNode,
    _ nodeCount: inout UInt32,
    _ kindMask: inout UInt32
) -> Bool {
    // One crossing per node, not five: `info()` answers the kind, the child count and every POD
    // payload together, because they all come off the same variant discriminant.
    let info = node.info()
    nodeCount += 1
    kindMask |= kindBit(info.kind)

    var everyNodeSerializable = isSerializableLeaf(info.kind)

    let count = info.childCount
    var index: UInt32 = 0
    while index < count {
        // Kept as a full traversal even once `everyNodeSerializable` is false, so that the node
        // count and the kind mask describe the whole tree rather than the prefix walked before the
        // first operator: a mask that stopped early would under-report the kinds not yet handled.
        if !walk(node.childAt(index), &nodeCount, &kindMask) {
            everyNodeSerializable = false
        }
        index += 1
    }

    return everyNodeSerializable
}

/// Serializes one leaf into the sink.
///
/// Mirrors CSSCalcTree+Serialization.cpp's `serializeMathFunction` for the `Numeric`, `Symbol`,
/// `SiblingCount` and `SiblingIndex` overloads, at the `Specified` stage:
///
///   - a numeric leaf or a symbol serializes as `calc(` + its own serialization + `)`
///     (`:295`-`:297`, `:302`-`:305`);
///   - `sibling-count()` and `sibling-index()` serialize as themselves, with no `calc(` wrapper,
///     because `serializeMathFunction` for those two defers straight to
///     `serializeCalculationTree` (`:308`-`:316`), which emits the name and `()` (`:599`-`:611`).
///
/// The distinction in that last pair is the one thing here that is easy to get wrong and invisible
/// in casual testing, since both spellings parse.
@inline(always)
private func serializeLeaf(
    _ node: borrowing WebCore.CSSCalc.CSSCalcSwiftNode,
    _ sink: inout WebCore.CSSCalc.CSSCalcSwiftSink
) {
    let info = node.info()
    switch info.kind {
    case .Number, .Percentage, .CanonicalDimension, .NonCanonicalDimension:
        sink.appendCalcOpen()
        sink.appendNumber(info.numericValue, info.unitType)
        sink.appendCloseParen()
    case .Symbol:
        sink.appendCalcOpen()
        sink.appendValueIDName(info.valueID)
        sink.appendCloseParen()
    default:
        // SiblingCount and SiblingIndex. Reached only through `isSerializableLeaf`, so `Operation`
        // and any future kind cannot arrive here.
        sink.appendValueIDName(info.valueID)
        sink.appendEmptyParens()
    }
}

/// Entry point: serialize a whole tree, or decline.
///
/// `isComputedStage` comes from the caller rather than the tree, because `Stage` lives on
/// `CSSCalc::Tree` and not on a `Child`, and the handle here is a cursor onto a `Child`. The
/// `Computed` stage declines outright: that path clamps the value to the range and rebuilds the
/// leaf through `makeChildWithValueBasedOn` before serializing (`+Serialization.cpp:275`-`:280`),
/// which needs a way to construct a `Child` that this file does not have.
@_expose(Cxx)
public func cssCalcSerializeSwift(
    _ root: WebCore.CSSCalc.CSSCalcSwiftNode,
    _ sink: inout WebCore.CSSCalc.CSSCalcSwiftSink,
    _ isComputedStage: Bool
) -> WebCore.CSSCalc.CSSCalcSwiftSerializationResult {
    var nodeCount: UInt32 = 0
    var kindMask: UInt32 = 0

    // The walk runs unconditionally, including for the Computed stage, so that the node count and
    // the kind mask describe every tree the gate saw and not only the ones it could have taken.
    // Coverage that is only measured on the cases that succeeded is not a coverage measurement.
    let everyNodeSerializable = walk(root, &nodeCount, &kindMask)

    guard everyNodeSerializable, !isComputedStage else {
        return WebCore.CSSCalc.CSSCalcSwiftSerializationResult(
            kindMask: kindMask,
            nodeCount: nodeCount,
            outcome: CSSCalcSwiftOutcome.declined.rawValue
        )
    }

    // A serializable tree is a single leaf: every kind `isSerializableLeaf` admits has no children,
    // so `everyNodeSerializable` and a child count of zero are the same condition here. Asserted
    // rather than assumed, because the day S1 admits an operator kind this stops being true and a
    // silent single-node emit would drop the rest of the expression.
    precondition(nodeCount == 1, "S0 admits only childless leaves; a multi-node tree must have declined")

    serializeLeaf(root, &sink)

    return WebCore.CSSCalc.CSSCalcSwiftSerializationResult(
        kindMask: kindMask,
        nodeCount: nodeCount,
        outcome: CSSCalcSwiftOutcome.serialized.rawValue
    )
}
