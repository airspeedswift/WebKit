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
// USE_SWIFT_CSS_CALC_SERIALIZATION. This is phase S1 of that port.
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
// WHAT S1 DOES. S0 proved the boundary and retired nothing on purpose. S1 is the first phase that
// takes real C++ responsibility across it: the island now owns
// https://drafts.csswg.org/css-values-4/#serialize-a-calculation-tree steps 4 to 7 -- Negate,
// Invert, Sum and Product -- plus the math-function wrapper for a Sum or Product root. Concretely
// it serializes any tree whose every node is one of
//
//   - the seven leaves (the four numeric kinds, `Symbol`, `sibling-count()`, `sibling-index()`), and
//   - `Sum`, `Product`, `Negate`, `Invert`,
//
// with a root that is a leaf, a `Sum` or a `Product`, at the `Specified` stage. Everything else
// declines, and a decline emits nothing at all.
//
// WHY THOSE FOUR AND NOT SOME OTHER FOUR. They are the whole of the grouping-parenthesis state
// machine, which is the only stateful thing in the entire serializer: `SerializationState::
// groupingParenthesis` plus `ParenthesisSaver`, mutated and restored around every descent. The
// other 30 operators are a prefix, comma-separated arguments and a close paren, and every one of
// them *reuses* this machinery for its arguments. So getting this state across is the work, and S2's
// remaining 30 are then largely a name table -- which is why the order is this way round and not by
// line count.
//
// THE STATE IS IN SWIFT, AND IT IS A PARAMETER RATHER THAN STATE. This is the one design decision in
// S1 worth arguing about, and the C++-side cost of the alternative decided it: carrying
// `groupingParenthesis` in C++ would mean the boundary owning a mutable state object, an accessor
// pair to read and write it, and a scope guard the island has to remember to use -- glue whose whole
// job is to hold a bit that the recursion already knows. In Swift it is an argument:
// `serializeCalculationTree(_:includingGroupingParenthesis:_:)`. Zero glue, and structurally better
// than what it replaces: `ParenthesisSaver` is shared mutable state restored by a destructor, so a
// descent that forgets one silently serializes its subtree with the wrong parenthesisation, while a
// parameter cannot be forgotten -- the compiler demands a value at every call.
//
// SORT ORDER IS AN UPCALL, FOR THE SAME REASON NUMBER FORMATTING IS. Steps 6 and 7 begin "Sort
// root's children", and the key is a 60-case unit order generated with `__COUNTER__`
// (CSSCalcTree+Serialization.cpp:146). Copying a generated table into Swift is not allowed here, so
// `childAt` answers in serialization order -- sorted for `Sum` and `Product`, tree order otherwise --
// and the island only ever names a position. `sink.appendNumber` likewise routes to C++'s
// `formatCSSNumberValue`: Swift's `Double.description` is shortest-round-trip and CSS's algorithm is
// a different one, so a Swift version would agree on every common value, pass all 211 calc tests in
// the WPT corpus, and diverge on subnormals and 17-significant-digit values.
//
// THE WALK IS THE DECLINE DECISION. A partial emit cannot be undone -- the builder is C++'s and has
// no truncate -- so the island has to decide whether it can serialize the *entire* tree before it
// appends anything. That is why the coverage predicate is evaluated by a full traversal first and
// the serialization is a second pass. What the walk additionally *reports* -- node count and a kind
// mask -- is free, three registers on the way out, and it is what stops the differential from being
// vacuous: a decline is invisible, because for a declined tree both arms run the C++ and agreement is
// guaranteed, and so is a walk that never descended.
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

/// Every fixed spelling the island emits, named rather than spelled.
///
/// No text crosses the boundary: the island names a literal and C++ owns the characters, so there is
/// exactly one copy of every CSS literal in the program and it is on the C++ side. Declared here
/// rather than in C++ for the reason `CSSCalcSwiftOutcome` is -- Swift produces the choice and C++
/// consumes it, so the single declaration belongs on the producing side, and
/// `CSSCalcSwiftSink::appendLiteral` switches over these *names* rather than over raw values, which
/// is what makes reordering this enum harmless and adding a case without teaching C++ a
/// `RELEASE_ASSERT_NOT_REACHED` instead of a wrong stylesheet.
@frozen
@c
enum CSSCalcSwiftLiteral: UInt8 {
    /// `calc(`
    case calcOpen = 0
    /// `(` -- the grouping parenthesis of steps 4 to 7.
    case openParen = 1
    /// `)`
    case closeParen = 2
    /// `()`, for `sibling-count()` and `sibling-index()`.
    case emptyParens = 3
    /// ` + `
    case plus = 4
    /// ` - `
    case minus = 5
    /// ` * `
    case times = 6
    /// ` / `
    case dividedBy = 7
    /// `-1 * `, the Negate prefix of step 4.
    case negateOpen = 8
    /// `1 / `, the Invert prefix of step 5.
    case invertOpen = 9
}

/// One bit per `CSSCalcSwiftNodeKind`, for the mask the walk reports.
@inline(always)
private func kindBit(_ kind: WebCore.CSSCalc.CSSCalcSwiftNodeKind) -> UInt32 {
    return UInt32(1) << UInt32(kind.rawValue)
}

/// Whether the island can serialize a node of this kind *anywhere in a tree*.
///
/// Written as an exhaustive `switch` rather than a comparison against `.Operation`, so that S2
/// splitting further kinds out of `Operation` cannot silently start claiming coverage it does not
/// have -- the compiler will demand a decision for each new case.
///
/// `childCount` is a parameter because for `Sum` and `Product` it is part of the predicate. Step 6
/// and step 7 both begin by serializing "root's first child", and a childless `Sum` therefore has no
/// serialization: the C++ indexes `sortedChildrenMap[0]` of an empty `Vector<ChildRepresentation, 16>`
/// behind an `ASSERT` that is compiled out of every shipping build, which is an uninitialised read of
/// its inline buffer. The island declines instead. Whether the parser and simplifier can actually
/// produce one is not established -- and that is exactly why this is a decline rather than a
/// `precondition`: declining costs one comparison and is correct either way, where trusting the
/// invariant is only correct if the invariant holds.
@inline(always)
private func isSerializableNode(
    _ kind: WebCore.CSSCalc.CSSCalcSwiftNodeKind,
    _ childCount: UInt32
) -> Bool {
    switch kind {
    case .Number, .Percentage, .CanonicalDimension, .NonCanonicalDimension:
        return true
    case .Symbol, .SiblingCount, .SiblingIndex:
        return true
    case .Sum, .Product:
        return childCount > 0
    case .Negate, .Invert:
        return childCount == 1
    case .Operation:
        return false
    case .OpaqueOperation:
        // `Anchor` and `AnchorSize`, whose reported `childCount` is 0 because their `tuple_size` is
        // (CSSCalcTree.h:1317, webkit.org/b/280798) -- so a walk that trusted the count would take
        // them for leaves. Declining is not a formality here: it is the reason the kind exists.
        return false
    @unknown default:
        // A kind C++ grew and this file has not been taught. Declining is the only safe answer;
        // guessing would serialize a node whose spelling the island does not know.
        return false
    }
}

/// Whether the island can serialize a tree *rooted* at this kind.
///
/// Narrower than `isSerializableNode` for exactly two kinds, and the reason is a property of the C++
/// it has to match rather than of the island. `serializeMathFunction` has explicit
/// `serializeMathFunctionArguments` overloads for `Sum` and `Product` that route back into the
/// calculation-tree serializer (`+Serialization.cpp:403`-`:411`), and none for `Negate` or `Invert`
/// -- so a `Negate` root takes the generic overload at `:545`, which emits the child *without* the
/// `-1 * ` prefix that step 4 requires. Matching that byte for byte would mean reproducing it; not
/// matching it would be a differential failure. So the island declines, the C++ answers for its own
/// shape, and no defect is copied across the boundary.
///
/// Reachability is an open question rather than a claim: simplification rewrites `Negate` of a
/// numeric, of a `Negate`, and of an all-numeric `Sum`/`Product`
/// (`+Simplification.cpp:904`-`:953`), and no parse observed so far produces a bare `Negate` or
/// `Invert` at the root of a `Tree`. If it is truly unreachable this predicate is inert; the way to
/// settle it is a bridge entry that constructs such a tree directly, which is S2's to do.
@inline(always)
private func isSerializableRoot(
    _ kind: WebCore.CSSCalc.CSSCalcSwiftNodeKind,
    _ childCount: UInt32
) -> Bool {
    switch kind {
    case .Negate, .Invert:
        return false
    default:
        return isSerializableNode(kind, childCount)
    }
}

/// The traversal. Accumulates the node count and the kind mask, and reports whether every node it
/// saw is one the island can serialize.
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

    var everyNodeSerializable = isSerializableNode(info.kind, info.childCount)

    let count = info.childCount
    var index: UInt32 = 0
    while index < count {
        // Kept as a full traversal even once `everyNodeSerializable` is false, so that the node
        // count and the kind mask describe the whole tree rather than the prefix walked before the
        // first operator. The differential's coverage assertions rest on that: a mask that stopped
        // early would under-report exactly the kinds S2 needs to see arriving.
        if !walk(node.childAt(index), &nodeCount, &kindMask) {
            everyNodeSerializable = false
        }
        index += 1
    }

    return everyNodeSerializable
}

/// https://drafts.csswg.org/css-values-4/#serialize-a-calculation-tree
///
/// `includingGroupingParenthesis` is the whole of `SerializationState::groupingParenthesis`, carried
/// as a parameter instead of as mutable state with a scope guard. `false` is step 4's "if a result
/// starts with `(` and ends with `)`, remove those characters" applied at the point of production
/// rather than by editing the output afterwards, which is what the C++ does too and is why a
/// `StringBuilder` suffices for both.
private func serializeCalculationTree(
    _ node: borrowing WebCore.CSSCalc.CSSCalcSwiftNode,
    includingGroupingParenthesis includeGrouping: Bool,
    _ sink: inout WebCore.CSSCalc.CSSCalcSwiftSink
) {
    let info = node.info()
    switch info.kind {
    case .Number, .Percentage, .CanonicalDimension, .NonCanonicalDimension:
        // 2. If root is a numeric value, serialize root per the normal rules for it.
        sink.appendNumber(info.numericValue, info.unitType)

    case .Symbol:
        sink.appendValueIDName(info.valueID)

    case .SiblingCount, .SiblingIndex:
        sink.appendValueIDName(info.valueID)
        sink.appendLiteral(CSSCalcSwiftLiteral.emptyParens.rawValue)

    case .Sum:
        serializeSum(node, info.childCount, includingGroupingParenthesis: includeGrouping, &sink)

    case .Product:
        serializeProduct(node, info.childCount, includingGroupingParenthesis: includeGrouping, &sink)

    case .Negate:
        // 4. If root is a Negate node: `(`, `-1 * `, the child, `)`.
        if includeGrouping {
            sink.appendLiteral(CSSCalcSwiftLiteral.openParen.rawValue)
        }
        sink.appendLiteral(CSSCalcSwiftLiteral.negateOpen.rawValue)
        serializeCalculationTree(node.childAt(0), includingGroupingParenthesis: true, &sink)
        if includeGrouping {
            sink.appendLiteral(CSSCalcSwiftLiteral.closeParen.rawValue)
        }

    case .Invert:
        // 5. If root is an Invert node: `(`, `1 / `, the child, `)`.
        if includeGrouping {
            sink.appendLiteral(CSSCalcSwiftLiteral.openParen.rawValue)
        }
        sink.appendLiteral(CSSCalcSwiftLiteral.invertOpen.rawValue)
        serializeCalculationTree(node.childAt(0), includingGroupingParenthesis: true, &sink)
        if includeGrouping {
            sink.appendLiteral(CSSCalcSwiftLiteral.closeParen.rawValue)
        }

    case .Operation, .OpaqueOperation:
        // Unreachable: `cssCalcSerializeSwift` walked the whole tree and declined before appending
        // anything if any node was one of these. Trapping rather than emitting nothing, because the
        // failure this guards against is a silently truncated serialization of every math function
        // on the page -- a stop is recoverable evidence and a wrong `cssText` is not. Justified
        // rather than measured away: it is a single comparison on a path that already ran a full
        // traversal, and the differential's 3,000-plus serialized cases are what establish it does
        // not fire.
        preconditionFailure("the walk admitted a node kind the serializer cannot emit")

    @unknown default:
        preconditionFailure("the walk admitted a node kind the serializer cannot emit")
    }
}

/// Step 6, the Sum node.
///
/// The child order is `childAt`'s, which for a Sum is the *sorted* order that step 6 requires -- C++
/// owns that sort, because its key is a generated 60-case unit table.
private func serializeSum(
    _ node: borrowing WebCore.CSSCalc.CSSCalcSwiftNode,
    _ childCount: UInt32,
    includingGroupingParenthesis includeGrouping: Bool,
    _ sink: inout WebCore.CSSCalc.CSSCalcSwiftSink
) {
    if includeGrouping {
        sink.appendLiteral(CSSCalcSwiftLiteral.openParen.rawValue)
    }

    // - Serialize root's first child. Every child below is serialized WITH its grouping parenthesis,
    //   which is `ParenthesisSaver`'s only job in the C++: the Omit that a math-function wrapper
    //   installed applies to this node and not to its children.
    serializeCalculationTree(node.childAt(0), includingGroupingParenthesis: true, &sink)

    var index: UInt32 = 1
    while index < childCount {
        let child = node.childAt(index)
        let childInfo = child.info()
        switch childInfo.kind {
        case .Negate:
            // 6.1. If child is a Negate node, append " - " and serialize the Negate's child.
            sink.appendLiteral(CSSCalcSwiftLiteral.minus.rawValue)
            serializeCalculationTree(child.childAt(0), includingGroupingParenthesis: true, &sink)

        case .Number, .Percentage, .CanonicalDimension, .NonCanonicalDimension:
            // 6.2. If child is a negative numeric value, append " - " and serialize its negation.
            //
            // `< 0` has IEEE semantics on both sides, which is load-bearing rather than incidental:
            // `-0.0 < 0` is false and `Double.nan < 0` is false, so both take the " + " branch and
            // serialize as themselves, exactly as the C++ `child.value < 0` does. A `signbit` or an
            // `isLess` spelling would have diverged on those two.
            if childInfo.numericValue < 0 {
                sink.appendLiteral(CSSCalcSwiftLiteral.minus.rawValue)
                sink.appendNumber(-childInfo.numericValue, childInfo.unitType)
            } else {
                sink.appendLiteral(CSSCalcSwiftLiteral.plus.rawValue)
                sink.appendNumber(childInfo.numericValue, childInfo.unitType)
            }

        default:
            // 6.3. Otherwise, append " + " and serialize child.
            sink.appendLiteral(CSSCalcSwiftLiteral.plus.rawValue)
            serializeCalculationTree(child, includingGroupingParenthesis: true, &sink)
        }
        index += 1
    }

    if includeGrouping {
        sink.appendLiteral(CSSCalcSwiftLiteral.closeParen.rawValue)
    }
}

/// Step 7, the Product node. Same shape as step 6 with `Invert`/` / `/` * ` in place of
/// `Negate`/` - `/` + `, and with no negative-value case -- a Product does not rewrite a negative
/// child, which is why this is not one function with a flag.
private func serializeProduct(
    _ node: borrowing WebCore.CSSCalc.CSSCalcSwiftNode,
    _ childCount: UInt32,
    includingGroupingParenthesis includeGrouping: Bool,
    _ sink: inout WebCore.CSSCalc.CSSCalcSwiftSink
) {
    if includeGrouping {
        sink.appendLiteral(CSSCalcSwiftLiteral.openParen.rawValue)
    }

    serializeCalculationTree(node.childAt(0), includingGroupingParenthesis: true, &sink)

    var index: UInt32 = 1
    while index < childCount {
        let child = node.childAt(index)
        if child.info().kind == .Invert {
            // 7.1. If child is an Invert node, append " / " and serialize the Invert's child.
            sink.appendLiteral(CSSCalcSwiftLiteral.dividedBy.rawValue)
            serializeCalculationTree(child.childAt(0), includingGroupingParenthesis: true, &sink)
        } else {
            // 7.2. Otherwise, append " * " and serialize child.
            sink.appendLiteral(CSSCalcSwiftLiteral.times.rawValue)
            serializeCalculationTree(child, includingGroupingParenthesis: true, &sink)
        }
        index += 1
    }

    if includeGrouping {
        sink.appendLiteral(CSSCalcSwiftLiteral.closeParen.rawValue)
    }
}

/// https://drafts.csswg.org/css-values-4/#serialize-a-math-function
///
/// Mirrors CSSCalcTree+Serialization.cpp's `serializeMathFunction` overloads at the `Specified`
/// stage. The `calc(` wrapper and the grouping-parenthesis Omit are the same step 3/4 pair for every
/// kind here, and the one case that is easy to get wrong and invisible in casual testing is the last:
/// `sibling-count()` and `sibling-index()` take NO `calc(` wrapper, because their
/// `serializeMathFunction` overloads defer straight to the calculation-tree serializer
/// (`:320`-`:328`). Both spellings parse, so nothing but a differential catches it.
@inline(always)
private func serializeMathFunction(
    _ node: borrowing WebCore.CSSCalc.CSSCalcSwiftNode,
    _ info: WebCore.CSSCalc.CSSCalcSwiftNodeInfo,
    _ sink: inout WebCore.CSSCalc.CSSCalcSwiftSink
) {
    switch info.kind {
    case .Number, .Percentage, .CanonicalDimension, .NonCanonicalDimension:
        sink.appendLiteral(CSSCalcSwiftLiteral.calcOpen.rawValue)
        sink.appendNumber(info.numericValue, info.unitType)
        sink.appendLiteral(CSSCalcSwiftLiteral.closeParen.rawValue)

    case .Symbol:
        sink.appendLiteral(CSSCalcSwiftLiteral.calcOpen.rawValue)
        sink.appendValueIDName(info.valueID)
        sink.appendLiteral(CSSCalcSwiftLiteral.closeParen.rawValue)

    case .SiblingCount, .SiblingIndex:
        sink.appendValueIDName(info.valueID)
        sink.appendLiteral(CSSCalcSwiftLiteral.emptyParens.rawValue)

    case .Sum:
        // 3. The prefix for a calc-operator node is "calc(". 4. Its argument is the calculation
        // tree serialized with the grouping parenthesis OMITTED, which is what makes
        // `calc(1px + 1em)` rather than `calc((1px + 1em))`.
        sink.appendLiteral(CSSCalcSwiftLiteral.calcOpen.rawValue)
        serializeSum(node, info.childCount, includingGroupingParenthesis: false, &sink)
        sink.appendLiteral(CSSCalcSwiftLiteral.closeParen.rawValue)

    case .Product:
        sink.appendLiteral(CSSCalcSwiftLiteral.calcOpen.rawValue)
        serializeProduct(node, info.childCount, includingGroupingParenthesis: false, &sink)
        sink.appendLiteral(CSSCalcSwiftLiteral.closeParen.rawValue)

    default:
        // Unreachable: `isSerializableRoot` declined every other kind before anything was appended,
        // and that includes `.Negate` and `.Invert`, whose C++ root path is the one shape the island
        // deliberately does not reproduce. See `isSerializableRoot`.
        preconditionFailure("the root check admitted a node kind the math-function wrapper cannot emit")
    }
}

/// The island's entry point: serialize a whole tree, or decline.
///
/// `isComputedStage` comes from the caller rather than the tree, because `Stage` lives on
/// `CSSCalc::Tree` and not on a `Child`, and the handle is a cursor onto a `Child`. S1 still declines
/// the `Computed` stage outright: that path clamps the value to the range and rebuilds the leaf
/// through `makeChildWithValueBasedOn` before serializing (`+Serialization.cpp:275`-`:280`), which is
/// a construction the island cannot do without a way to make a `Child`.
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

    let rootInfo = root.info()
    guard everyNodeSerializable, isSerializableRoot(rootInfo.kind, rootInfo.childCount), !isComputedStage else {
        return WebCore.CSSCalc.CSSCalcSwiftSerializationResult(
            kindMask: kindMask,
            nodeCount: nodeCount,
            outcome: CSSCalcSwiftOutcome.declined.rawValue
        )
    }

    serializeMathFunction(root, rootInfo, &sink)

    return WebCore.CSSCalc.CSSCalcSwiftSerializationResult(
        kindMask: kindMask,
        nodeCount: nodeCount,
        outcome: CSSCalcSwiftOutcome.serialized.rawValue
    )
}
