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
// USE_SWIFT_CSS_CALC_SERIALIZATION. This is phase S3 of that port.
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
// WHAT THE ISLAND SERIALIZES AFTER S4. Every tree, at EITHER stage, whose every node is one of
//
//   - the seven leaves (the four numeric kinds, `Symbol`, `sibling-count()`, `sibling-index()`),
//   - `Sum`, `Product`, `Negate`, `Invert` -- css-values-4 steps 4 to 7, S1's work,
//   - `Deg2Rad`, the implementation-only node inside a trig function, which serializes as its child,
//   - 26 of the 34 operations as plain math functions: `min`, `max`, `clamp` (including a `none`
//     bound), `round` in all four rounding strategies, `mod`, `rem`, the six trig functions,
//     `atan2`, `pow`, `sqrt`, `hypot`, `log`, `exp`, `abs`, `sign`, `progress` and
//     `progress(no-clamp ...)`, S2's work,
//   - and the last four, S3's: `random()` with all three `<random-key>` alternatives, `calc-mix()`
//     with per-item weights, `anchor()` and `anchor-size()`,
//
// with a root that is not a bare `Negate`, `Invert` or `Deg2Rad`. **All 34 operations, all 41
// `Child` alternatives and both `Stage`s are now covered.** Everything else declines, and a decline
// emits nothing at all.
//
// WHY THE `Computed` STAGE WAS ITS OWN PHASE, AND WHY IT IS FIVE LINES. S1 through S3 declined it
// outright, on the belief that it needs a `Child` to be *constructed* -- the C++ clamps the value
// and calls `makeChildWithValueBasedOn` before re-entering the serializer. It does not: that helper
// copies the `hint`, the `dimension` and the `unit` and replaces only the value, so the rebuilt leaf
// has the same `toCSSUnit` as the original and the whole re-entry collapses to one `appendNumber`.
// What the stage really is, is a **narrow** difference with a **wide** decline in front of it: the
// C++ tests `state.stage` in exactly one place out of the whole 1,300-line serializer, and only for
// a NUMERIC ROOT, where it clamps to the range and drops the `calc(` wrapper. A `Sum`, a `Symbol` or
// a math function at `Computed` was already serializing identically, and was being declined anyway.
// The cost that is real is the plumbing -- `CalcSerialization` below, and two doubles more across
// the boundary.
//
// WHY S3'S FOUR ARE FOUR KINDS WHERE S2'S TWENTY-SIX WERE ONE. S2's rule was "the kind names the
// SHAPE and `valueID` carries the name", and it collapsed thirty operations into four kinds because
// their serialization differed only in the prefix. These four are exactly the ones for which the
// C++ has a `serializeMathFunctionArguments` OVERLOAD rather than the generic template, i.e. the
// ones whose arguments are not a list of calculation trees -- so here the shape *is* the operation
// and collapsing would have meant a flag per difference instead. What they still share is that the
// function NAME costs nothing: `valueID` is `Op::id` for all four, as it is for the twenty-six.
//
// S3'S TWO STRUCTURAL FINDINGS, both of which are the sort a differential would have caught late.
// `anchor()`'s arguments go through `serializeWithoutOmittingPrefix`, not the calculation-tree
// serializer -- the C++'s own comment is "as anchor() is not actually a math function, calc() can't
// be omitted in arguments" -- which puts every one of them in ROOT position, where `Negate`,
// `Invert` and `Deg2Rad` are declined. And `Anchor`/`AnchorSize` had a lying child count, because
// their `tuple_size` is 0; the bridge's `forEachChildNodeOfChild` now answers for them directly
// rather than fixing the FIXME, which would change what simplification and evaluation traverse.
//
// WHY THE ORDER WAS S1'S FOUR THEN S2'S TWENTY-SIX. S1's four are the whole of the
// grouping-parenthesis state machine, which is the only stateful thing in the entire serializer:
// `SerializationState::groupingParenthesis` plus `ParenthesisSaver`, mutated and restored around
// every descent. Every one of S2's twenty-six *reuses* that machinery for its arguments and adds no
// state of its own -- it is a prefix, comma-separated arguments and a close paren. So S1 was the
// work and S2 is a name table, which is why it is a name table that stays in C++ (see
// `serializeMathFunctionCall`).
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
// SORT ORDER AND THE OPERATOR NAMES ARE UPCALLS, FOR THE SAME REASON NUMBER FORMATTING IS. Steps 6
// and 7 begin "Sort root's children", and the key is a 60-case unit order generated with
// `__COUNTER__` (CSSCalcTree+Serialization.cpp:146). Copying a generated table into Swift is not
// allowed here, so `childAt` answers in serialization order -- sorted for `Sum` and `Product`, tree
// order otherwise -- and the island only ever names a position. The same rule is what decides S2's
// shape: `nameLiteralForSerialization` is generated from CSSValueKeywords.in, so the island carries a
// `CSSValueID` and `sink.appendValueIDName` owns the spelling, and twenty-six operations therefore
// cost zero names on this side. `sink.appendNumber` likewise routes to C++'s `formatCSSNumberValue`:
// Swift's `Double.description` is shortest-round-trip and CSS's algorithm is a different one, so a
// Swift version would agree on every common value, pass all 211 calc tests in the WPT corpus, and
// diverge on subnormals and 17-significant-digit values.
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
/// silent reinterpretation of every calc() in every stylesheet.
///
/// Internal rather than `public`, for the reason CSSParserFastPathsSwift.swift:71 gives: `@c` on a
/// *resilient* enum crashes IRGen and WebCore compiles with library evolution, and the generated
/// header is emitted at `-emit-clang-header-min-access internal` so nothing is lost. S0 wrote
/// `@frozen` here as well, which was redundant -- `@frozen` has no effect on a non-public enum,
/// which is what a non-public enum being non-resilient already means, and the compiler now says so.
/// The two sibling islands have carried bare internal `@c` enums since before this one existed.
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
/// `RELEASE_ASSERT_NOT_REACHED` instead of a wrong stylesheet. Internal and bare `@c`, for the reason
/// `CSSCalcSwiftOutcome` above records.
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
    /// `, `, the argument separator of step 4 of serialize-a-math-function.
    case commaSpace = 10
    /// `round(`. The function name plus its open paren, because the four rounding operations differ
    /// by *strategy* and share the name -- so the name is fixed here and the strategy arrives as a
    /// `CSSValueID`.
    case roundOpen = 11
    /// `(no-clamp `, the whole of `progress(no-clamp ...)`'s prefix after the function name. A space
    /// rather than the `, ` every other prefix uses, which is the one thing about this operator that
    /// is not the generic shape.
    case noClampOpen = 12
    /// `none`, for a `clamp()` bound that holds the keyword. Named rather than spelled for the same
    /// reason every other literal here is: C++ emits it through
    /// `nameLiteralForSerialization(CSSValueNone)`, which is the generated table, so the island never
    /// holds the characters.
    case noneKeyword = 13
    /// ` `, the separator inside `random()`'s `<random-cache-key>`, between `anchor()`'s
    /// `<anchor-element>` and its `<anchor-side>`, and between `anchor-size()`'s two.
    case space = 14
    /// `fixed `, the prefix of `random()`'s `fixed <number>` sharing. The keyword goes through the
    /// generated table and the space is part of the prefix, which is how the C++ writes it too.
    case randomFixedPrefix = 15
    /// `element-scoped`, one of the three optional parts of a `<random-cache-key>`.
    case elementScoped = 16
}

/// Which non-tree argument of one of S3's four operations an `appendOperationArgument` upcall
/// should write.
///
/// Declared here rather than in C++ for the reason `CSSCalcSwiftLiteral` is: Swift produces the
/// choice and C++ consumes it, so the single declaration belongs on the producing side, and
/// `CSSCalcSwiftSink::appendOperationArgument` switches over these *names* rather than over raw
/// values. Internal and bare `@c`, same as its two siblings.
@c
enum CSSCalcSwiftOperationPart: UInt8 {
    /// `random()`'s `<random-cache-key>` name, or `anchor()`/`anchor-size()`'s `<anchor-element>`.
    /// Both are a `CSS::CustomIdent`, and which one is meant follows from the node's own kind.
    case dashedIdent = 0
    /// `random()`'s `fixed <number [0,1]>` value, without the `fixed ` prefix.
    case randomFixedValue = 1
    /// `calc-mix()`'s `index`th item's `<percentage>` weight, preceded by a space -- or nothing at
    /// all when that item has no weight. The presence test is C++'s here, and it is the only one in
    /// the island; see `CSSCalcSwiftOperationInfo` for why.
    case calcMixWeight = 2
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
    case .Negate, .Invert, .Transparent:
        return childCount == 1
    case .Function, .RoundFunction, .ProgressNoClampFunction:
        // No lower bound on the argument count, and that is not laxity: an argument-less math
        // function serializes as `name()` on both arms by construction -- the C++ generic argument
        // serializer writes its separator *before* each argument, so zero arguments write nothing --
        // so there is nothing here to disagree about. Contrast `Sum` above, where a zero count is a
        // real hazard in the C++ rather than an empty string.
        return true
    case .ClampWithNoneMinimum, .ClampWithNoneMaximum:
        // `clamp( [ <calc-sum> | none ], <calc-sum>, [ <calc-sum> | none ] )` with exactly one bound
        // holding the keyword, so two subtrees remain. Insisting on the count is what keeps the
        // keyword's position and the arguments' positions in agreement: the kind says *which* bound is
        // `none` and the walk supplies the other two in order, so a count of anything but 2 would mean
        // the two halves of that agreement had come apart.
        return childCount == 2
    case .Operation:
        return false
    case .RandomFunction:
        // `random( <random-key>? , <calc-sum>, <calc-sum>, <calc-sum>? )`. The `<random-key>` is not
        // a child, so the count is the two required arguments plus an optional step. Insisting on it
        // is what keeps the island from writing `random(1px)` if the boundary ever came apart.
        return childCount == 2 || childCount == 3
    case .CalcMixFunction:
        // `calc-mix( [ <calc-sum> <percentage>? ]# )`, one child per item. No lower bound, for the
        // reason `.Function` gives: an empty list serializes as `calc-mix()` on both arms, because
        // both write the separator before each item.
        return true
    case .AnchorFunction, .AnchorSizeFunction:
        // The count is checked against `operationInfo()` in `walk`, which is where the record that
        // says how many children there SHOULD be is available. Two predicates rather than one
        // because this one is also asked about nodes deep inside a tree, where the extra crossing
        // would be paid for every node of every kind.
        return true
    case .OpaqueOperation:
        // No producer since S3 -- `Anchor` and `AnchorSize` are their own kinds now and the bridge's
        // `forEachChildNodeOfChild` answers for them, so `childCount` is the truth for every kind.
        // The case is retained because removing it would renumber every kind above it; declining is
        // still the only safe answer if C++ ever produces one again.
        return false
    @unknown default:
        // A kind C++ grew and this file has not been taught. Declining is the only safe answer;
        // guessing would serialize a node whose spelling the island does not know.
        return false
    }
}

/// Whether the island can serialize a tree *rooted* at this kind.
///
/// Narrower than `isSerializableNode` for three kinds, and for two different reasons.
///
/// `Negate` and `Invert`, because of a property of the C++ rather than of the island, and S2 settled
/// what that property is. `serializeMathFunction` has explicit `serializeMathFunctionArguments`
/// overloads for `Sum` and `Product` that route back into the calculation-tree serializer
/// (`+Serialization.cpp:403`-`:411`), and none for `Negate` or `Invert` -- so a `Negate` root takes
/// the generic overload at `:545`, which walks the node's one child and emits it *without* the
/// `-1 * ` that step 4 requires. It is not a formatting difference: `Negate(1px)` serialises as
/// `calc(1px)`, the negation silently gone, where the very same node one level down inside a `Sum`
/// serialises as `(-1 * 1px)`. The bridge constructs both trees directly and prints them, so this is
/// demonstrated rather than argued, and it is recorded as a WebKit defect to file. The island
/// declines instead of reproducing it, because a differential that matches a wrong value is worse
/// than one that declines.
///
/// Reachability is settled too, and separately: `webCoreCSSCalcRootKindMask` accumulates the *root*
/// kind of every tree the differential parses, and across 24,655 cases no parse produces a bare
/// `Negate` or `Invert` root -- simplification rewrites `Negate` of a numeric, of a `Negate`, and of
/// an all-numeric `Sum`/`Product` (`+Simplification.cpp:904`-`:953`). So this predicate is inert on
/// everything the parser can build, and the defect is not user-visible through parsed CSS. It is
/// still a defect, because `CSSCalc::Tree`s are also built programmatically.
///
/// `Transparent`, i.e. `Deg2Rad`, because at the root it is the one node whose C++ path is *not* the
/// same function: `serializeMathFunction(IndirectNode<Deg2Rad>)` (`:769`) defers to its child's math
/// function, so whether `calc(` appears is decided by the child's kind, which this predicate cannot
/// see from a kind and a count. It is also unreachable as a root -- `Deg2Rad` is only ever inserted
/// *inside* a trig function -- and the same root-kind mask proves it over the whole corpus.
///
/// The two `ClampWithNone...` kinds need no exception, and that is worth saying because the first
/// attempt at `clamp()`'s `none` bound did: a cursor that could stand on the keyword itself would have
/// been a root candidate that is not a tree at all. Carrying the keyword on the *parent's* kind means
/// every kind the island can root is a real subtree.
@inline(always)
private func isSerializableRoot(
    _ kind: WebCore.CSSCalc.CSSCalcSwiftNodeKind,
    _ childCount: UInt32
) -> Bool {
    switch kind {
    case .Negate, .Invert, .Transparent:
        return false
    default:
        return isSerializableNode(kind, childCount)
    }
}

/// The extra condition `anchor()` and `anchor-size()` have to meet, which `isSerializableNode`
/// cannot express from a kind and a count.
///
/// Two things, and they fail for different reasons.
///
/// FIRST, the count has to AGREE with the record. `operationInfo()` says whether the
/// `<anchor-side>` is a keyword and whether there is a fallback; `childCount` says how many
/// subtrees the bridge will hand over. The island writes the fallback at index
/// `anchorSideIsKeyword ? 0 : 1`, so if those two ever came apart it would serialize the side as
/// the fallback or index past the end. Declining costs one comparison and is correct either way.
///
/// SECOND, and this is the one that is easy to miss: `anchor()`'s arguments are serialized by
/// `serializeWithoutOmittingPrefix`, not by `serializeCalculationTree` -- "as anchor() is not
/// actually a math function, calc() can't be omitted in arguments"
/// (`+Serialization.cpp:492`). That routes a non-leaf argument through the MATH FUNCTION path, so
/// each argument sits in root position, and root position is narrower than child position for
/// `Negate`, `Invert` and `Transparent` (see `isSerializableRoot`). A `Negate` fallback would hit
/// the C++ generic overload that drops the `-1 * `, which is the defect `isSerializableRoot`
/// declines rather than reproduces -- so it has to be declined *here* too, where the C++ would
/// reach it.
@inline(always)
private func anchorArgumentsAreSerializable(
    _ node: borrowing WebCore.CSSCalc.CSSCalcSwiftNode,
    _ info: WebCore.CSSCalc.CSSCalcSwiftNodeInfo
) -> Bool {
    let operation = node.operationInfo()

    var expected: UInt32 = operation.hasFallback ? 1 : 0
    if info.kind == .AnchorFunction && !operation.anchorSideIsKeyword {
        expected += 1
    }
    if expected != info.childCount {
        return false
    }

    var index: UInt32 = 0
    while index < info.childCount {
        let child = node.childAt(index)
        let childInfo = child.info()
        if !isSerializableRoot(childInfo.kind, childInfo.childCount) {
            return false
        }
        index += 1
    }
    return true
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

    if info.kind == .AnchorFunction || info.kind == .AnchorSizeFunction {
        // One extra crossing, for two kinds, on the two conditions a kind and a count cannot carry.
        if !anchorArgumentsAreSerializable(node, info) {
            everyNodeSerializable = false
        }
    }

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

/// The part of `SerializationState` that does NOT vary as the walk descends: the stage, and the
/// `CSS::Range` that the `Computed` stage clamps a numeric root against.
///
/// STATE THAT IS INVARIANT BELONGS ON THE TYPE; STATE THAT VARIES BELONGS IN THE SIGNATURE. The C++
/// puts both in one mutable `SerializationState&` and then needs `ParenthesisSaver`, a destructor,
/// to put the varying half back (`+Serialization.cpp:71`-`:84`). Splitting them is the whole design
/// here: `groupingParenthesis` changes at nearly every descent and so is a parameter the compiler
/// demands a value for, while `stage` and `range` are written once by the caller and never written
/// again, so they are `let`s on this struct and every serializer below is a method on it. Neither
/// half can be forgotten and neither can be mutated by mistake, which is two failure modes the C++
/// shape admits.
///
/// It is three scalars rather than a `CSS::Range`, because `Range` also carries two
/// `RangeParseTimeBehavior` enums that exist for the *parser* -- `clampValue` reads `min` and `max`
/// and nothing else -- and because two `Double`s cross the boundary as two registers with no C++
/// written to describe them.
private struct CalcSerialization {
    /// `state.stage == Stage::Computed`. It arrives from the caller rather than from the tree,
    /// because `Stage` lives on `CSSCalc::Tree` and the handle the island holds is a cursor onto a
    /// `Child`.
    let isComputedStage: Bool
    /// `state.range.min` and `state.range.max`.
    let rangeMinimum: Double
    let rangeMaximum: Double

    /// `clampValue` (`+Serialization.cpp:272`): NaN becomes 0, then `std::clamp`.
    ///
    /// Spelled as the ternary `std::clamp` is specified to be, and NOT as `min(max(value, lo), hi)`,
    /// which is the obvious Swift rewrite and a different function whenever `lo > hi`: `std::clamp`
    /// returns `lo` there and the nested form returns `hi`. A `CSS::Range` with `min > max` is not
    /// something the parser builds today, so this is not a bug being fixed -- it is a divergence not
    /// being introduced by a rewrite that looked equivalent.
    ///
    /// `Double.isNaN` and `<` are IEEE on both sides, so `-0.0` and the two infinities come out of
    /// this identically to the C++: `-0.0 < -inf` is false and `inf < -0.0` is false, so `-0.0`
    /// passes through against the default range and serializes as `-0`, exactly as the C++ arm does.
    @inline(always)
    func clampValue(_ value: Double) -> Double {
        let denanned = value.isNaN ? 0 : value
        if denanned < rangeMinimum {
            return rangeMinimum
        }
        if rangeMaximum < denanned {
            return rangeMaximum
        }
        return denanned
    }

    /// https://drafts.csswg.org/css-values-4/#serialize-a-calculation-tree
    ///
    /// `includingGroupingParenthesis` is the whole of `SerializationState::groupingParenthesis`, carried
    /// as a parameter instead of as mutable state with a scope guard. `false` is step 4's "if a result
    /// starts with `(` and ends with `)`, remove those characters" applied at the point of production
    /// rather than by editing the output afterwards, which is what the C++ does too and is why a
    /// `StringBuilder` suffices for both.
    func serializeCalculationTree(
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

        case .Transparent:
            // `Deg2Rad` has no CSS-level representation, so serialize the child in this node's place --
            // including inheriting this node's grouping parenthesis, which is what
            // `serializeCalculationTree(IndirectNode<Deg2Rad>)` does by passing `state` through
            // unchanged (`+Serialization.cpp:762`).
            serializeCalculationTree(node.childAt(0), includingGroupingParenthesis: includeGrouping, &sink)

        case .Function, .RoundFunction, .ProgressNoClampFunction,
             .ClampWithNoneMinimum, .ClampWithNoneMaximum,
             .RandomFunction, .CalcMixFunction, .AnchorFunction, .AnchorSizeFunction:
            // 3. If root is anything but a Sum, Negate, Product, or Invert node, serialize a math
            // function for the function corresponding to the node type.
            //
            // `includeGrouping` is deliberately unused. A math function is already parenthesised by its
            // own name and paren, so it never takes the grouping parenthesis, and the C++ says the same
            // by the *shape* of `+Serialization.cpp:775`: the template forwards to
            // `serializeMathFunction` without consulting `state.groupingParenthesis` at all.
            serializeMathFunctionCall(node, info, &sink)

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

    /// https://drafts.csswg.org/css-values-4/#serialize-a-math-function, steps 3 to 5, for the 26
    /// operations whose arguments are a plain list of calculation trees.
    ///
    /// This one function is the whole of S2's claim, and it is one function rather than twenty-six
    /// because the C++ it replaces is one function too: `serializeMathFunctionPrefix`'s generic template
    /// is `nameLiteralForSerialization(Op::id)` plus `(` for twenty of them
    /// (`+Serialization.cpp:398`-`:401`), and `serializeMathFunctionArguments`'s generic template is
    /// `serializeCalculationTree` over the children joined with `, ` (`:545`-`:566`). Only the prefix
    /// varies, and only in two ways: `round()` names a strategy first, and `progress(no-clamp ...)`
    /// separates its flag with a space. The *operator name table* stays in C++ -- `info.valueID` is
    /// `Op::id` and `appendValueIDName` is the generated `nameLiteralForSerialization` -- so absorbing
    /// twenty-six operations added no table on this side of the boundary and no C++ per operation.
    ///
    /// Every argument is serialized with the grouping parenthesis OMITTED, which is step 4's "if a
    /// result of this serialization starts with a `(` and ends with a `)`, remove those characters". The
    /// C++ spells it as a `ParenthesisSaver` that installs `Omit` around the whole argument list
    /// (`:341`-`:346`); here it is the `false` below, and it applies only to the arguments themselves --
    /// a `Sum` *inside* an argument re-establishes `Include` for its own children, which is what makes
    /// `min(1px + 1em, (1rem + 1vw) * 2)` come out with one set of parentheses and not two.
    func serializeMathFunctionCall(
        _ node: borrowing WebCore.CSSCalc.CSSCalcSwiftNode,
        _ info: WebCore.CSSCalc.CSSCalcSwiftNodeInfo,
        _ sink: inout WebCore.CSSCalc.CSSCalcSwiftSink
    ) {
        // 3. Let s be a string initially containing the name of the root node, lowercased, followed by
        //    a "(".
        switch info.kind {
        case .RoundFunction:
            // `round(` and then the rounding strategy: `valueID` is the STRATEGY here, because all four
            // rounding operations share the function name and differ only by it.
            sink.appendLiteral(CSSCalcSwiftLiteral.roundOpen.rawValue)
            sink.appendValueIDName(info.valueID)
            sink.appendLiteral(CSSCalcSwiftLiteral.commaSpace.rawValue)

        case .ProgressNoClampFunction:
            sink.appendValueIDName(info.valueID)
            sink.appendLiteral(CSSCalcSwiftLiteral.noClampOpen.rawValue)

        default:
            sink.appendValueIDName(info.valueID)
            sink.appendLiteral(CSSCalcSwiftLiteral.openParen.rawValue)
        }

        // 4. For each child of the root node, serialize the calculation tree, then concatenate all of
        //    the results using ", ".
        //
        // S3's four take their own branch, because each is exactly the case where the C++ has a
        // `serializeMathFunctionArguments` OVERLOAD rather than the generic template: their arguments
        // are not a plain list of calculation trees. Everything else, including `clamp()`'s `none`
        // bound, goes through the shared loop below.
        switch info.kind {
        case .RandomFunction:
            serializeRandomArguments(node, info, &sink)

        case .CalcMixFunction:
            serializeCalcMixArguments(node, info, &sink)

        case .AnchorFunction:
            serializeAnchorArguments(node, &sink)

        case .AnchorSizeFunction:
            serializeAnchorSizeArguments(node, &sink)

        default:
            // A `clamp()` bound holding `none` is an argument the C++ writes and the walk cannot see,
            // because `min` and `max` are `ChildOrNone` and only `forAllChildren` visits the keyword. It
            // occupies the first or the last position, never a middle one, so it is a leading or a
            // trailing term here rather than anything the loop has to know about.
            var index: UInt32 = info.kind == .ClampWithNoneMinimum ? 1 : 0
            if info.kind == .ClampWithNoneMinimum {
                sink.appendLiteral(CSSCalcSwiftLiteral.noneKeyword.rawValue)
                sink.appendLiteral(CSSCalcSwiftLiteral.commaSpace.rawValue)
                serializeCalculationTree(node.childAt(0), includingGroupingParenthesis: false, &sink)
            }
            while index < info.childCount {
                if index > 0 {
                    sink.appendLiteral(CSSCalcSwiftLiteral.commaSpace.rawValue)
                }
                serializeCalculationTree(node.childAt(index), includingGroupingParenthesis: false, &sink)
                index += 1
            }
            if info.kind == .ClampWithNoneMaximum {
                sink.appendLiteral(CSSCalcSwiftLiteral.commaSpace.rawValue)
                sink.appendLiteral(CSSCalcSwiftLiteral.noneKeyword.rawValue)
            }
        }

        // 5. Append ")" to s.
        sink.appendLiteral(CSSCalcSwiftLiteral.closeParen.rawValue)
    }

    /// `random( <random-key>? , <calc-sum>, <calc-sum>, <calc-sum>? )`.
    ///
    /// Mirrors `serializeMathFunctionArguments(IndirectNode<Random>)` (`+Serialization.cpp:413`). The
    /// `<random-key>`'s three optional parts are space-separated and the key as a whole is followed by
    /// `, `; `auto` serializes as omitted, which is the branch that writes nothing.
    ///
    /// The C++ `ASSERT`s that a key wrote something, on the grounds that the parser never produces an
    /// empty `<random-cache-key>`. The island does not assert it and does not need to: `wroteSomething`
    /// is what places the separators, so an empty key would come out as `random(, 1px, 1em)` here and
    /// on the C++ arm alike -- the same output, and an assertion that is compiled out of every shipping
    /// build is not a thing to reproduce.
    func serializeRandomArguments(
        _ node: borrowing WebCore.CSSCalc.CSSCalcSwiftNode,
        _ info: WebCore.CSSCalc.CSSCalcSwiftNodeInfo,
        _ sink: inout WebCore.CSSCalc.CSSCalcSwiftSink
    ) {
        let operation = node.operationInfo()

        if operation.randomSharingIsKey {
            var wroteSomething = false
            if operation.randomKeyHasName {
                sink.appendOperationArgument(node, CSSCalcSwiftOperationPart.dashedIdent.rawValue, 0)
                wroteSomething = true
            }
            if operation.randomKeyIsElementScoped {
                if wroteSomething {
                    sink.appendLiteral(CSSCalcSwiftLiteral.space.rawValue)
                }
                sink.appendLiteral(CSSCalcSwiftLiteral.elementScoped.rawValue)
                wroteSomething = true
            }
            if operation.randomKeyHasPropertyScope {
                if wroteSomething {
                    sink.appendLiteral(CSSCalcSwiftLiteral.space.rawValue)
                }
                sink.appendValueIDName(operation.valueID)
            }
            sink.appendLiteral(CSSCalcSwiftLiteral.commaSpace.rawValue)
        } else if operation.randomSharingIsFixed {
            sink.appendLiteral(CSSCalcSwiftLiteral.randomFixedPrefix.rawValue)
            sink.appendOperationArgument(node, CSSCalcSwiftOperationPart.randomFixedValue.rawValue, 0)
            sink.appendLiteral(CSSCalcSwiftLiteral.commaSpace.rawValue)
        }
        // else: `auto`, which serializes as omitted.

        // `min`, `max`, and the optional `step`. The walk has already established the count is 2 or 3.
        var index: UInt32 = 0
        while index < info.childCount {
            if index > 0 {
                sink.appendLiteral(CSSCalcSwiftLiteral.commaSpace.rawValue)
            }
            serializeCalculationTree(node.childAt(index), includingGroupingParenthesis: false, &sink)
            index += 1
        }
    }

    /// `calc-mix( [ <calc-sum> <percentage [0,100]>? ]# )`.
    ///
    /// Mirrors `serializeMathFunctionArguments(IndirectNode<CalcMix>)` (`+Serialization.cpp:466`). One
    /// child per item, in item order, each optionally followed by its weight.
    ///
    /// The weight upcall writes its own leading space, and writes nothing when the item has none, so
    /// this loop has no presence test in it. That is the one structural decision the island leaves to
    /// C++; `CSSCalcSwiftOperationInfo` records why.
    func serializeCalcMixArguments(
        _ node: borrowing WebCore.CSSCalc.CSSCalcSwiftNode,
        _ info: WebCore.CSSCalc.CSSCalcSwiftNodeInfo,
        _ sink: inout WebCore.CSSCalc.CSSCalcSwiftSink
    ) {
        var index: UInt32 = 0
        while index < info.childCount {
            if index > 0 {
                sink.appendLiteral(CSSCalcSwiftLiteral.commaSpace.rawValue)
            }
            serializeCalculationTree(node.childAt(index), includingGroupingParenthesis: false, &sink)
            sink.appendOperationArgument(node, CSSCalcSwiftOperationPart.calcMixWeight.rawValue, index)
            index += 1
        }
    }

    /// `anchor( <anchor-element>? && <anchor-side>, <length-percentage>? )`.
    ///
    /// Mirrors `serializeMathFunctionArguments(IndirectNode<Anchor>)` (`+Serialization.cpp:478`).
    ///
    /// Both subtree arguments go through `serializeWithoutOmittingPrefix` rather than
    /// `serializeCalculationTree`, which is the C++'s own comment: "as anchor() is not actually a math
    /// function, calc() can't be omitted in arguments". `walk` has already established that every one
    /// of them is serializable in ROOT position, which is the narrower condition that routing implies.
    func serializeAnchorArguments(
        _ node: borrowing WebCore.CSSCalc.CSSCalcSwiftNode,
        _ sink: inout WebCore.CSSCalc.CSSCalcSwiftSink
    ) {
        let operation = node.operationInfo()

        if operation.hasElementName {
            sink.appendOperationArgument(node, CSSCalcSwiftOperationPart.dashedIdent.rawValue, 0)
            sink.appendLiteral(CSSCalcSwiftLiteral.space.rawValue)
        }

        // The `<anchor-side>`: a keyword, or a `<percentage>` subtree occupying child 0. `walk` checked
        // that `childCount` agrees with this, so the fallback's index below is not a guess.
        var fallbackIndex: UInt32 = 0
        if operation.anchorSideIsKeyword {
            sink.appendValueIDName(operation.valueID)
        } else {
            serializeWithoutOmittingPrefix(node.childAt(0), &sink)
            fallbackIndex = 1
        }

        if operation.hasFallback {
            sink.appendLiteral(CSSCalcSwiftLiteral.commaSpace.rawValue)
            serializeWithoutOmittingPrefix(node.childAt(fallbackIndex), &sink)
        }
    }

    /// `anchor-size( [ <anchor-element> || <anchor-size> ]? , <length-percentage>? )`.
    ///
    /// Mirrors `serializeMathFunctionArguments(IndirectNode<AnchorSize>)` (`+Serialization.cpp:522`).
    /// Both leading parts are optional and independently so, which is why the separators are written
    /// from the flags rather than from a running "wrote something" the way `random()`'s key is -- the
    /// C++ spells it the same way, and the `, ` before a fallback appears only if something preceded it.
    ///
    /// The `<anchor-size>` dimension arrives as a `CSSValueID` rather than as one of six strings, so
    /// the island holds no spelling: `Style::AnchorSizeDimension` is mapped to a keyword id in
    /// `anchorSizeDimensionValueID` and `appendValueIDName` writes it through the generated table. The
    /// C++ arm keeps its own six literals on purpose, so the differential compares two independent
    /// spellings rather than one shared table.
    func serializeAnchorSizeArguments(
        _ node: borrowing WebCore.CSSCalc.CSSCalcSwiftNode,
        _ sink: inout WebCore.CSSCalc.CSSCalcSwiftSink
    ) {
        let operation = node.operationInfo()

        if operation.hasElementName {
            sink.appendOperationArgument(node, CSSCalcSwiftOperationPart.dashedIdent.rawValue, 0)
        }

        if operation.hasDimension {
            if operation.hasElementName {
                sink.appendLiteral(CSSCalcSwiftLiteral.space.rawValue)
            }
            sink.appendValueIDName(operation.valueID)
        }

        if operation.hasFallback {
            if operation.hasElementName || operation.hasDimension {
                sink.appendLiteral(CSSCalcSwiftLiteral.commaSpace.rawValue)
            }
            serializeWithoutOmittingPrefix(node.childAt(0), &sink)
        }
    }

    /// `serializeWithoutOmittingPrefix` (`+Serialization.cpp:568`): a leaf serializes as itself, and
    /// anything else serializes as a MATH FUNCTION -- so a `Sum` argument of `anchor()` comes out as
    /// `calc(1px + 1em)` and not as `1px + 1em`.
    ///
    /// Eight lines here against eleven there, and the eleven are the ones S3 makes deletable. Note it
    /// reuses `serializeMathFunction`, whose `default` traps: that is safe only because `walk` declined
    /// any `anchor()` whose arguments are not serializable in root position. The two are one mechanism
    /// and neither is correct without the other.
    @inline(always)
    func serializeWithoutOmittingPrefix(
        _ node: borrowing WebCore.CSSCalc.CSSCalcSwiftNode,
        _ sink: inout WebCore.CSSCalc.CSSCalcSwiftSink
    ) {
        let info = node.info()
        switch info.kind {
        case .Number, .Percentage, .CanonicalDimension, .NonCanonicalDimension,
             .Symbol, .SiblingCount, .SiblingIndex:
            // The `Leaf auto&` arm. Grouping never applies to a leaf on either arm -- none of the seven
            // consults `state.groupingParenthesis` -- so `false` is not a choice, it is the absence of
            // one.
            serializeCalculationTree(node, includingGroupingParenthesis: false, &sink)
        default:
            serializeMathFunction(node, info, &sink)
        }
    }

    /// Step 6, the Sum node.
    ///
    /// The child order is `childAt`'s, which for a Sum is the *sorted* order that step 6 requires -- C++
    /// owns that sort, because its key is a generated 60-case unit table.
    func serializeSum(
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
    func serializeProduct(
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
    /// Mirrors CSSCalcTree+Serialization.cpp's `serializeMathFunction` overloads. The `calc(` wrapper
    /// and the grouping-parenthesis Omit are the same step 3/4 pair for every
    /// kind here, and the one case that is easy to get wrong and invisible in casual testing is the last:
    /// `sibling-count()` and `sibling-index()` take NO `calc(` wrapper, because their
    /// `serializeMathFunction` overloads defer straight to the calculation-tree serializer
    /// (`:320`-`:328`). Both spellings parse, so nothing but a differential catches it.
    ///
    /// THIS IS THE ONLY FUNCTION IN THE ISLAND THAT READS THE STAGE, and the C++ is the same shape:
    /// `state.stage` is tested in exactly one place in the whole 1,300-line serializer
    /// (`+Serialization.cpp:289`), inside `template<Numeric Op> serializeMathFunction`. A `Sum`, a
    /// `Symbol`, a `sibling-count()` or a math function at the `Computed` stage serializes byte for
    /// byte as it does at `Specified`.
    @inline(always)
    func serializeMathFunction(
        _ node: borrowing WebCore.CSSCalc.CSSCalcSwiftNode,
        _ info: WebCore.CSSCalc.CSSCalcSwiftNodeInfo,
        _ sink: inout WebCore.CSSCalc.CSSCalcSwiftSink
    ) {
        switch info.kind {
        case .Number, .Percentage, .CanonicalDimension, .NonCanonicalDimension:
            // 1. If the root is a numeric value and the serialization is of a computed value or
            //    later, clamp the value to the range allowed for its context, then serialize it as
            //    normal -- WITH NO `calc(` WRAPPER, because step 1 returns before step 3 builds one.
            //    Both spellings reparse, so only a differential distinguishes them; `1px` and
            //    `calc(1px)` are the same declaration and a different `cssText`.
            //
            //    The C++ rebuilds the leaf through `makeChildWithValueBasedOn` and re-enters
            //    `serializeCalculationTree`. That construction is not needed here and R107 was wrong
            //    to say it is: `makeChildWithValueBasedOn` copies the `hint`, the `dimension` and the
            //    `unit` and replaces only the value (`CSSCalcTree.cpp:311`-`:329`), so `toCSSUnit` of
            //    the rebuilt leaf is `toCSSUnit` of this one, and the whole of the re-entry is the
            //    `appendNumber` below.
            if isComputedStage {
                sink.appendNumber(clampValue(info.numericValue), info.unitType)
                return
            }
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

        case .Function, .RoundFunction, .ProgressNoClampFunction,
             .ClampWithNoneMinimum, .ClampWithNoneMaximum,
             .RandomFunction, .CalcMixFunction, .AnchorFunction, .AnchorSizeFunction:
            // A math function's ROOT serialization and its serialization as a child are the same thing:
            // `serializeCalculationTree(IndirectNode<Op>)` forwards straight to `serializeMathFunction`
            // (`+Serialization.cpp:775`-`:779`). That identity is why the 26 operations cost one function
            // here and not two, and why `min(1px, 1em)` has no `calc(` around it at the root.
            serializeMathFunctionCall(node, info, &sink)

        default:
            // Unreachable: `isSerializableRoot` declined every other kind before anything was appended,
            // and that is now `.Negate`, `.Invert`, `.Transparent`, `.Operation` and `.OpaqueOperation` --
            // the first three because the C++ root path for them is a different function from the child
            // path, the last two because the island does not serialize them anywhere. See
            // `isSerializableRoot`.
            preconditionFailure("the root check admitted a node kind the math-function wrapper cannot emit")
        }
    }
}

/// The island's entry point: serialize a whole tree, or decline.
///
/// `isComputedStage`, `rangeMinimum` and `rangeMaximum` come from the caller rather than from the
/// tree, because `Stage` lives on `CSSCalc::Tree` and the range lives on `SerializationOptions`,
/// while the handle the island holds is a cursor onto a `Child`. Together they are the whole of
/// `SerializationState` that this function does not already own; see `CalcSerialization`.
@_expose(Cxx)
public func cssCalcSerializeSwift(
    _ root: WebCore.CSSCalc.CSSCalcSwiftNode,
    _ sink: inout WebCore.CSSCalc.CSSCalcSwiftSink,
    _ isComputedStage: Bool,
    _ rangeMinimum: Double,
    _ rangeMaximum: Double
) -> WebCore.CSSCalc.CSSCalcSwiftSerializationResult {
    var nodeCount: UInt32 = 0
    var kindMask: UInt32 = 0

    // The walk runs unconditionally, so that the node count and the kind mask describe every tree
    // the gate saw and not only the ones it could have taken. Coverage that is only measured on the
    // cases that succeeded is not a coverage measurement.
    let everyNodeSerializable = walk(root, &nodeCount, &kindMask)

    let rootInfo = root.info()
    guard everyNodeSerializable, isSerializableRoot(rootInfo.kind, rootInfo.childCount) else {
        return WebCore.CSSCalc.CSSCalcSwiftSerializationResult(
            kindMask: kindMask,
            nodeCount: nodeCount,
            outcome: CSSCalcSwiftOutcome.declined.rawValue
        )
    }

    let serialization = CalcSerialization(
        isComputedStage: isComputedStage,
        rangeMinimum: rangeMinimum,
        rangeMaximum: rangeMaximum
    )
    serialization.serializeMathFunction(root, rootInfo, &sink)

    return WebCore.CSSCalc.CSSCalcSwiftSerializationResult(
        kindMask: kindMask,
        nodeCount: nodeCount,
        outcome: CSSCalcSwiftOutcome.serialized.rawValue
    )
}
