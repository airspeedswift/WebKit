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

// Only the island's own boundary types, not the WebCore_Private umbrella, for the reason
// CSSCalcSwiftTypes.h records.
public import WebCore_Private.CSSCalcSwiftTypes

// Swift island for CSS calc() serialization: a port of CSSCalcTree+Serialization.cpp, selected by
// USE_SWIFT_CSS_CALC_SERIALIZATION. This is phase S0 of that port.
//
// WHY calc() SERIALIZATION IS WEBCORE ISLAND #3, AND WHY THIS SLICE OF IT.
// `Source/WebCore/css/calc/` is 10,110 lines across 31 files with nothing generated, and it is the
// largest coarse-boundary retirement available today. The reason it was not attempted sooner is
// `conversionData`: one field in the signature, but 31 dereferences behind it, 29 of them
// `Style::BuilderState` upcalls and 4 of them mutating. `serializationForCSS` is the one entry of
// any size that needs **none** of them -- its whole context is a `CSS::Range` and a
// `CSS::SerializationContext`, and the latter is only URL-replacement state, inert for calc. It is
// also the one slice where the other expensive risk is absent: `css/calc/**` contains zero
// `double`->`float` narrowing, so there is no `narrowPrecisionToFloat` ordering to reproduce
// bit-for-bit. Two external call sites, both in CSSUnevaluatedCalc.cpp.
//
// WHAT S0 DOES, AND WHAT IT DELIBERATELY DOES NOT.
// S0 retires no C++ lines. It exists to prove the boundary and stand up the differential so that
// S1 and S2 can absorb the serializer's 506 lines behind a gate that declines cleanly. Concretely
// the island here:
//
//   - walks the whole tree through the borrowed handle, which is what proves the child accessors
//     work on real input rather than on a probe;
//   - serializes the seven leaf kinds -- the four numeric ones, `Symbol`, `sibling-count()` and
//     `sibling-index()`;
//   - declines everything else, which for now means any tree containing an operator node anywhere,
//     and any tree at the `Computed` stage.
//
// THE WALK IS NOT DEAD WORK, AND THAT IS WHY IT IS SHAPED THIS WAY. A partial emit cannot be
// undone -- the builder is C++'s and has no truncate -- so the island has to decide whether it can
// serialize the *entire* tree before it appends anything. S0's coverage predicate is "no operator
// node anywhere", and establishing that requires the traversal. So the walk is the decline
// decision, not an instrumentation pass bolted beside one; S1 relaxes the predicate kind by kind
// and the traversal turns into the serialization itself. What the walk additionally *reports* --
// node count and a kind mask -- is free, three registers on the way out, and it is what stops the
// differential from being vacuous: a walk that never descended would otherwise read exactly like
// one that did.
//
// NUMBER FORMATTING IS AN UPCALL, ON PURPOSE. `sink.appendNumber` routes to C++'s
// `formatCSSNumberValue`. Reimplementing it here is the single highest-probability silent
// divergence in this whole slice: Swift's `Double.description` is shortest-round-trip and CSS's
// algorithm is a different one, so a Swift version would agree on every common value, pass all 211
// calc tests in the WPT corpus, and diverge on subnormals and 17-significant-digit values.
//
// NO `unsafe`, AND IT IS THE BOUNDARY THAT BUYS IT. The tree crosses as a borrowed `~Escapable`
// handle and the output crosses as a `SWIFT_SAFE` sink taken `inout`; neither is a pointer this
// file can see, so there is no marker to justify. Probe arms 11, 12 and 13 in
// ~/src/webkit-swift-ports/cssprobe/calcimport/ established that at 0 errors and 0 warnings, each
// with a control that fails when the annotation is removed.

/// What the island did with a tree.
///
/// `@c` (SE-0495) makes this the single declaration of the numbering: it is emitted into
/// WebCoreSwift-Generated.h and `static_assert`ed against these names in
/// CSSCalcTree+Serialization.cpp, so reordering these cases is a build failure there rather than a
/// silent reinterpretation of every calc() in every stylesheet. `frozen` because `@c` on a
/// resilient enum crashes IRGen and WebCore compiles with library evolution.
@frozen
@c
enum CSSCalcSwiftOutcome: UInt8 {
    /// The island wrote the complete serialization into the sink.
    case serialized = 0
    /// The island wrote nothing; the caller must run the C++ serializer.
    case declined = 1
}

/// One bit per `CSSCalcSwiftNodeKind`, for the mask the walk reports.
@inline(always)
private func kindBit(_ kind: WebCore.CSSCalc.CSSCalcSwiftNodeKind) -> UInt32 {
    return UInt32(1) << UInt32(kind.rawValue)
}

/// Whether S0 can serialize a node of this kind on its own.
///
/// The seven leaves, and no operator. Written as an exhaustive `switch` rather than a comparison
/// against `.Operation`, so that S1 splitting `Operation` into named cases cannot silently start
/// claiming coverage it does not have -- the compiler will demand a decision for each new case.
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
        // guessing would serialize a node whose spelling the island does not know.
        return false
    }
}

/// The traversal. Accumulates the node count and the kind mask, and reports whether every node it
/// saw is one S0 can serialize.
///
/// Recursive rather than an explicit stack: calc trees are shallow -- the deepest expression in the
/// whole WPT css-values corpus is single digits of nodes -- and the parser bounds depth long before
/// this runs. An explicit worklist would need a Swift container of a `~Escapable` element, which no
/// container accepts, and reaching for C++ to hold one would be exactly the mistake this project
/// has a standing rule against.
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
        // first operator. The differential's coverage assertions rest on that: a mask that stopped
        // early would under-report exactly the kinds S1 needs to see arriving.
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

/// The island's entry point: serialize a whole tree, or decline.
///
/// `isComputedStage` comes from the caller rather than the tree, because `Stage` lives on
/// `CSSCalc::Tree` and not on a `Child`, and the handle is a cursor onto a `Child`. S0 declines the
/// `Computed` stage outright: that path clamps the value to the range and rebuilds the leaf through
/// `makeChildWithValueBasedOn` before serializing (`+Serialization.cpp:275`-`:280`), which is a
/// construction the island cannot do without a way to make a `Child`.
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
