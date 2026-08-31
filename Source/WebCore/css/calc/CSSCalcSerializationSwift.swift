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
// Handles every tree at the `Specified` stage whose every node is one of:
//
//   - the seven leaves (the four numeric kinds, `Symbol`, `sibling-count()`, `sibling-index()`),
//   - `Sum`, `Product`, `Negate`, `Invert` (css-values-4 steps 4 to 7),
//   - `Deg2Rad`, the implementation-only node inside a trig function, which serializes as its child,
//   - 26 of the 34 operations as plain math functions: `min`, `max`, `clamp` (including a `none`
//     bound), `round` in all four rounding strategies, `mod`, `rem`, the six trig functions,
//     `atan2`, `pow`, `sqrt`, `hypot`, `log`, `exp`, `abs`, `sign`, `progress` and
//     `progress(no-clamp ...)`,
//   - and `random()` (all three `<random-key>` alternatives), `calc-mix()` (with per-item weights),
//     `anchor()` and `anchor-size()`,
//
// with a root that is not a bare `Negate`, `Invert` or `Deg2Rad`. All 34 operations and all 41
// `Child` alternatives are covered; what is left is the `Computed` stage. Everything else declines
// and emits nothing.
//
// `random()`, `calc-mix()`, `anchor()` and `anchor-size()` each get their own node kind rather than
// sharing one, because each is exactly the case where the C++ has a `serializeMathFunctionArguments`
// overload rather than the generic template -- their arguments are not a plain list of calculation
// trees, so here the shape *is* the operation. All four still cost no name table on this side:
// `valueID` is `Op::id` for all of them, the same as the 26 plain math functions.
//
// `anchor()`'s arguments go through `serializeWithoutOmittingPrefix`, not the calculation-tree
// serializer -- the C++'s own comment is "as anchor() is not actually a math function, calc() can't
// be omitted in arguments" -- which puts every one of them in root position, where `Negate`,
// `Invert` and `Deg2Rad` are declined (see `isSerializableRoot`). `Anchor`/`AnchorSize` also had a
// `tuple_size` of 0 (webkit.org/b/280798), so `forAllChildNodes` reported no children for them; the
// bridge's `forEachChildNodeOfChild` answers for them directly instead of relying on that count.
//
// `Sum`/`Product`/`Negate`/`Invert` are the whole of the grouping-parenthesis state machine, the
// only stateful part of the serializer (`SerializationState::groupingParenthesis` plus
// `ParenthesisSaver`, mutated and restored around every descent); the other 30 operations reuse
// that machinery for their own arguments and add no state, so they cost a name table rather than
// new plumbing (see `serializeMathFunctionCall`). Here the grouping state is a parameter
// (`serializeCalculationTree(_:includingGroupingParenthesis:_:)`) rather than mutable state with a
// scope guard: a parameter cannot be forgotten, where a descent that skips restoring
// `ParenthesisSaver` silently serializes with the wrong parenthesisation.
//
// Sort order and operator names are both C++ upcalls, for the same reason number formatting is.
// Steps 6 and 7 sort root's children by a generated 60-case unit table
// (`CSSCalcTree+Serialization.cpp:146`), so `childAt` answers in serialization order already --
// sorted for `Sum` and `Product`, tree order otherwise -- and this file only ever names a position.
// `nameLiteralForSerialization` is generated from CSSValueKeywords.in, so this file carries a
// `CSSValueID` and `appendValueIDName` owns the spelling; the twenty-six plain math functions
// therefore cost no name table here. `sink.appendNumber` likewise routes to C++'s
// `formatCSSNumberValue`: Swift's `Double.description` is shortest-round-trip and CSS's algorithm
// is not, so a reimplementation would diverge on subnormals and high-precision values.
//
// The walk establishes coverage over the whole tree before any output is appended, since a partial
// emit into C++'s `StringBuilder` cannot be undone.
//
// The tree crosses as a borrowed `~Escapable` handle and the output as a `SWIFT_SAFE` sink taken
// `inout`; neither is a pointer this file can see, so there is no `unsafe` marker here.

/// Whether this file serialized a tree, or left it for the C++ serializer.
///
/// `@c` (SE-0495) makes this the single declaration of the numbering: it is emitted into
/// WebCoreSwift-Generated.h and `static_assert`ed against these names in
/// CSSCalcTree+Serialization.cpp, so reordering these cases is a build failure there rather than a
/// silent reinterpretation of every calc() in every stylesheet.
///
/// Internal rather than `public`: `@c` on a *resilient* enum crashes IRGen and WebCore compiles
/// with library evolution, and the generated header is emitted at
/// `-emit-clang-header-min-access internal` so nothing is lost by not being public. `@frozen` is
/// not needed here -- it has no effect on a non-public enum, since a non-public enum is already
/// non-resilient.
@c
enum CSSCalcSwiftOutcome: UInt8 {
    /// This file wrote the complete serialization into the sink.
    case serialized = 0
    /// This file wrote nothing; the caller must run the C++ serializer.
    case declined = 1
}

/// Every fixed spelling this file emits, named rather than spelled.
///
/// No text crosses the boundary: this side names a literal and C++ owns the characters, so there is
/// exactly one copy of every CSS literal in the program. `CSSCalcSwiftSink::appendLiteral` switches
/// over these *names* rather than raw values, so reordering this enum is harmless and adding a case
/// without teaching C++ is a `RELEASE_ASSERT_NOT_REACHED` rather than a wrong stylesheet.
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
    /// `nameLiteralForSerialization(CSSValueNone)`, which is the generated table, so this file never
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

/// Which non-tree argument of `random()`, `calc-mix()`, `anchor()` or `anchor-size()` an
/// `appendOperationArgument` upcall should write.
///
/// `CSSCalcSwiftSink::appendOperationArgument` switches over these *names* rather than raw values,
/// for the same reason `CSSCalcSwiftLiteral` does.
@c
enum CSSCalcSwiftOperationPart: UInt8 {
    /// `random()`'s `<random-cache-key>` name, or `anchor()`/`anchor-size()`'s `<anchor-element>`.
    /// Both are a `CSS::CustomIdent`, and which one is meant follows from the node's own kind.
    case dashedIdent = 0
    /// `random()`'s `fixed <number [0,1]>` value, without the `fixed ` prefix.
    case randomFixedValue = 1
    /// `calc-mix()`'s `index`th item's `<percentage>` weight, preceded by a space -- or nothing at
    /// all when that item has no weight. The presence test is C++'s here, and it is the only one in
    /// this file; see `CSSCalcSwiftOperationInfo` for why.
    case calcMixWeight = 2
}

/// One bit per `CSSCalcSwiftNodeKind`, for the mask the walk reports.
@inline(always)
private func kindBit(_ kind: WebCore.CSSCalc.CSSCalcSwiftNodeKind) -> UInt32 {
    return UInt32(1) << UInt32(kind.rawValue)
}

/// Whether this file can serialize a node of this kind *anywhere in a tree*.
///
/// Written as an exhaustive `switch` rather than a comparison against `.Operation`, so that
/// splitting further kinds out of `Operation` later cannot silently start claiming coverage it does
/// not have -- the compiler will demand a decision for each new case.
///
/// `childCount` is a parameter because for `Sum` and `Product` it is part of the predicate. Step 6
/// and step 7 both begin by serializing "root's first child", and a childless `Sum` therefore has no
/// serialization: the C++ indexes `sortedChildrenMap[0]` of an empty `Vector<ChildRepresentation, 16>`
/// behind an `ASSERT` that is compiled out of every shipping build, which is an uninitialised read of
/// its inline buffer. This file declines instead. Whether the parser and simplifier can actually
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
        // is what keeps this file from writing `random(1px)` if the two ever came apart.
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
        // No current producer -- `Anchor` and `AnchorSize` are their own kinds now and the bridge's
        // `forEachChildNodeOfChild` answers for them, so `childCount` is the truth for every kind.
        // The case is retained because removing it would renumber every kind above it; declining is
        // still the only safe answer if C++ ever produces one again.
        return false
    @unknown default:
        // A kind C++ grew and this file has not been taught. Declining is the only safe answer;
        // guessing would serialize a node whose spelling this file does not know.
        return false
    }
}

/// Whether this file can serialize a tree *rooted* at this kind.
///
/// Narrower than `isSerializableNode` for three kinds, for two different reasons.
///
/// `Negate` and `Invert`, because of a property of the C++ this has to match. `serializeMathFunction`
/// has explicit `serializeMathFunctionArguments` overloads for `Sum` and `Product` that route back
/// into the calculation-tree serializer (`+Serialization.cpp:403`-`:411`), and none for `Negate` or
/// `Invert` -- so a `Negate` root takes the generic overload at `:545`, which walks the node's one
/// child and emits it *without* the `-1 * ` that step 4 requires. It is not a formatting difference:
/// `Negate(1px)` serialises as `calc(1px)`, the negation silently gone, where the very same node one
/// level down inside a `Sum` serialises as `(-1 * 1px)`. This is a WebKit defect (recorded to file),
/// and this file declines rather than reproducing it, because matching a wrong value is worse than
/// declining.
///
/// Reachability is settled separately: across 24,655 parsed cases no parse produces a bare `Negate`
/// or `Invert` root -- simplification rewrites `Negate` of a numeric, of a `Negate`, and of an
/// all-numeric `Sum`/`Product` (`+Simplification.cpp:904`-`:953`). So this predicate is inert on
/// everything the parser can build, and the defect is not user-visible through parsed CSS. It is
/// still a defect, because `CSSCalc::Tree`s are also built programmatically.
///
/// `Transparent`, i.e. `Deg2Rad`, because at the root it is the one node whose C++ path is *not* the
/// same function: `serializeMathFunction(IndirectNode<Deg2Rad>)` (`:769`) defers to its child's math
/// function, so whether `calc(` appears is decided by the child's kind, which this predicate cannot
/// see from a kind and a count. It is also unreachable as a root -- `Deg2Rad` is only ever inserted
/// *inside* a trig function.
///
/// The two `ClampWithNone...` kinds need no exception: carrying the `none` keyword on the *parent's*
/// kind rather than on a cursor standing on the keyword itself means every kind here can root a real
/// subtree.
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
/// First, the count has to agree with the record: `operationInfo()` says whether the
/// `<anchor-side>` is a keyword and whether there is a fallback, and `childCount` says how many
/// subtrees the bridge hands over. The fallback is written at index `anchorSideIsKeyword ? 0 : 1`,
/// so if those two came apart this would serialize the side as the fallback or index past the end.
///
/// Second: `anchor()`'s arguments are serialized by `serializeWithoutOmittingPrefix`, not by
/// `serializeCalculationTree` -- "as anchor() is not actually a math function, calc() can't be
/// omitted in arguments" (`+Serialization.cpp:492`). That routes a non-leaf argument through the
/// math-function path, so each argument sits in root position, which is narrower than child
/// position for `Negate`, `Invert` and `Transparent` (see `isSerializableRoot`) -- so those have to
/// be declined here too, where the C++ would reach the same defect.
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
        // first operator: a mask that stopped early would under-report the kinds not yet handled.
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
        // Unreachable: the walk already covers the whole tree and declines before appending
        // anything if any node is one of these. Trapping rather than emitting nothing, because a
        // stop is recoverable evidence and a silently truncated `cssText` is not.
        preconditionFailure("the walk admitted a node kind the serializer cannot emit")

    @unknown default:
        preconditionFailure("the walk admitted a node kind the serializer cannot emit")
    }
}

/// https://drafts.csswg.org/css-values-4/#serialize-a-math-function, steps 3 to 5, for the
/// operations whose arguments are a plain list of calculation trees.
///
/// One function covers all of them because the C++ it mirrors is one function too:
/// `serializeMathFunctionPrefix`'s generic template is `nameLiteralForSerialization(Op::id)` plus
/// `(` for most of them (`+Serialization.cpp:398`-`:401`), and `serializeMathFunctionArguments`'s
/// generic template is `serializeCalculationTree` over the children joined with `, `
/// (`:545`-`:566`). Only the prefix varies: `round()` names a strategy first, and
/// `progress(no-clamp ...)` separates its flag with a space. The operator name table stays in
/// C++ -- `info.valueID` is `Op::id` and `appendValueIDName` is the generated
/// `nameLiteralForSerialization` -- so no table is needed on this side.
///
/// Every argument is serialized with the grouping parenthesis OMITTED, which is step 4's "if a
/// result of this serialization starts with a `(` and ends with a `)`, remove those characters". The
/// C++ spells it as a `ParenthesisSaver` that installs `Omit` around the whole argument list
/// (`:341`-`:346`); here it is the `false` below, and it applies only to the arguments themselves --
/// a `Sum` *inside* an argument re-establishes `Include` for its own children, which is what makes
/// `min(1px + 1em, (1rem + 1vw) * 2)` come out with one set of parentheses and not two.
private func serializeMathFunctionCall(
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
    // `random()`, `calc-mix()`, `anchor()` and `anchor-size()` take their own branch below,
    // because each is exactly the case where the C++ has a `serializeMathFunctionArguments`
    // OVERLOAD rather than the generic template: their arguments are not a plain list of
    // calculation trees. Everything else, including `clamp()`'s `none` bound, goes through the
    // shared loop below.
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
/// empty `<random-cache-key>`. This does not assert it: `wroteSomething` is what places the
/// separators, so an empty key would come out as `random(, 1px, 1em)` on both sides -- the same
/// output, whether or not the (compiled-out) assertion would have fired.
private func serializeRandomArguments(
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
/// this loop has no presence test of its own; `CSSCalcSwiftOperationInfo` records why that check
/// stays in C++.
private func serializeCalcMixArguments(
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
private func serializeAnchorArguments(
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
/// this file holds no spelling of its own: `Style::AnchorSizeDimension` is mapped to a keyword id in
/// `anchorSizeDimensionValueID` and `appendValueIDName` writes it through the generated table. The
/// C++ side keeps its own six literals independently, on purpose.
private func serializeAnchorSizeArguments(
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
/// Reuses `serializeMathFunction`, whose `default` traps; that is safe only because `walk` already
/// declined any `anchor()` whose arguments are not serializable in root position. The two are one
/// mechanism and neither is correct without the other.
@inline(always)
private func serializeWithoutOmittingPrefix(
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
/// kind here, except the last: `sibling-count()` and `sibling-index()` take NO `calc(` wrapper,
/// because their `serializeMathFunction` overloads defer straight to the calculation-tree serializer
/// (`:320`-`:328`). Both spellings parse, so only a dedicated test catches the difference.
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
        // path, the last two because this file does not serialize them anywhere. See
        // `isSerializableRoot`.
        preconditionFailure("the root check admitted a node kind the math-function wrapper cannot emit")
    }
}

/// Entry point: serialize a whole tree, or decline.
///
/// `isComputedStage` comes from the caller rather than the tree, because `Stage` lives on
/// `CSSCalc::Tree` and not on a `Child`, and the handle here is a cursor onto a `Child`. The
/// `Computed` stage still declines outright: that path clamps the value to the range and rebuilds
/// the leaf through `makeChildWithValueBasedOn` before serializing (`+Serialization.cpp:275`-`:280`),
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
