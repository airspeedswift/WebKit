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
// Handles every tree, at either stage, whose every node is one of:
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
// with a root that is not a bare `Negate`, `Invert` or `Deg2Rad`. All 34 operations, all 41 `Child`
// alternatives and both `Stage`s are covered. Everything else declines and emits nothing.
//
// The `Computed` stage looked like it needed a way to *construct* a `Child` -- the C++ clamps the
// value and calls `makeChildWithValueBasedOn` before re-entering the serializer -- but that helper
// only copies the `hint`, the `dimension` and the `unit` and replaces the value, so the rebuilt
// leaf's `toCSSUnit` is unchanged and the whole re-entry collapses to one `appendNumber`. The C++
// tests `state.stage` in exactly one place in the whole 1,300-line serializer, and only for a
// numeric root, where it clamps to the range and drops the `calc(` wrapper; a `Sum`, a `Symbol` or
// a math function at `Computed` already serializes identically to `Specified`. The real cost is the
// plumbing: see `CalcSerialization` below, and two `Double`s more across the boundary.
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
    case serialized = 0
    case declined = 1
}

/// Every fixed spelling this file emits, named rather than spelled, so that C++ owns the characters
/// and there is exactly one copy of every CSS literal in the program.
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
    /// `, `
    case commaSpace = 10
    /// `round(`. The name is fixed here because the four rounding operations differ by strategy.
    case roundOpen = 11
    /// `(no-clamp `, whose trailing space is unlike the `, ` every other prefix uses.
    case noClampOpen = 12
    /// `none`
    case noneKeyword = 13
    /// ` `
    case space = 14
    /// `fixed `
    case randomFixedPrefix = 15
    /// `element-scoped`
    case elementScoped = 16
}

/// Which non-tree argument of `random()`, `calc-mix()`, `anchor()` or `anchor-size()` an
/// `appendOperationArgument` upcall should write.
@c
enum CSSCalcSwiftOperationPart: UInt8 {
    /// `random()`'s `<random-cache-key>` name, or `anchor()`/`anchor-size()`'s `<anchor-element>`.
    /// Which one is meant follows from the node's own kind.
    case dashedIdent = 0
    case randomFixedValue = 1
    /// Preceded by a space, or nothing at all when the item has no weight. That presence test is
    /// C++'s, and it is the only one.
    case calcMixWeight = 2
}

/// One bit per `CSSCalcSwiftNodeKind`, for the mask the walk reports.
@inline(always)
private func kindBit(_ kind: WebCore.CSSCalc.CSSCalcSwiftNodeKind) -> UInt32 {
    return UInt32(1) << UInt32(kind.rawValue)
}

/// Whether this file can serialize a node of this kind anywhere in a tree. An exhaustive `switch`,
/// so that splitting further kinds out of `Operation` later cannot silently start claiming coverage
/// it does not have.
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
        // Steps 6 and 7 both begin by serializing "root's first child", so a childless `Sum` has no
        // serialization and the C++ reads an empty inline buffer behind a compiled-out `ASSERT`.
        return childCount > 0
    case .Negate, .Invert, .Transparent:
        return childCount == 1
    case .Function, .RoundFunction, .ProgressNoClampFunction:
        // No lower bound: an argument-less math function serializes as `name()` on both paths.
        return true
    case .ClampWithNoneMinimum, .ClampWithNoneMaximum:
        // Exactly one bound holds the keyword, so two subtrees remain. Insisting on the count keeps
        // the keyword's position and the arguments' positions in agreement.
        return childCount == 2
    case .Operation:
        return false
    case .RandomFunction:
        // The two required arguments plus an optional step; the `<random-key>` is not a child.
        return childCount == 2 || childCount == 3
    case .CalcMixFunction:
        return true
    case .AnchorFunction, .AnchorSizeFunction:
        // The count is checked against `operationInfo()` in `walk`, which is where the record that
        // says how many children there SHOULD be is available. Two predicates rather than one
        // because this one is also asked about nodes deep inside a tree, where the extra crossing
        // would be paid for every node of every kind.
        return true
    case .OpaqueOperation:
        // No current producer. Retained because removing it would renumber every kind above it.
        return false
    @unknown default:
        return false
    }
}

/// Whether this file can serialize a tree rooted at this kind.
///
/// A `Negate` root takes the generic `serializeMathFunction` overload and emits its one child
/// *without* the `-1 * ` that step 4 requires: `Negate(1px)` serialises as `calc(1px)`, the negation
/// silently gone, where the same node inside a `Sum` serialises as `(-1 * 1px)`. That is a WebKit
/// defect, and handing the tree back is better than matching a wrong value. `Transparent`, i.e.
/// `Deg2Rad`,
/// because at the root its C++ path defers to its child's math function, so whether `calc(` appears
/// is decided by the child's kind, which a kind and a count cannot see.
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

/// The part of `SerializationState` that does NOT vary as the walk descends: the stage, and the
/// `CSS::Range` that the `Computed` stage clamps a numeric root against.
///
/// Invariant state belongs on the type; state that varies belongs in the signature. The C++ puts
/// both in one mutable `SerializationState&` and then needs `ParenthesisSaver`, a destructor, to put
/// the varying half back (`+Serialization.cpp:71`-`:84`). Splitting them here means
/// `groupingParenthesis` stays a parameter the compiler demands a value for, while `stage` and
/// `range` are `let`s written once by the caller, and every serializer below is a method on this
/// struct. Neither half can be forgotten or mutated by mistake.
///
/// Three scalars rather than a `CSS::Range`, because `Range` also carries two
/// `RangeParseTimeBehavior` enums that exist for the *parser* -- `clampValue` reads only `min` and
/// `max` -- and two `Double`s cross the boundary as two registers with no C++ needed to describe
/// them.
private struct CalcSerialization {
    /// `state.stage == Stage::Computed`. It arrives from the caller rather than from the tree,
    /// because `Stage` lives on `CSSCalc::Tree` and the handle here is a cursor onto a `Child`.
    let isComputedStage: Bool
    /// `state.range.min` and `state.range.max`.
    let rangeMinimum: Double
    let rangeMaximum: Double

    /// `clampValue`: NaN becomes 0, then `std::clamp`. Spelled as the ternary `std::clamp` is
    /// specified to be, not as `min(max(value, lo), hi)`, which is a different function whenever
    /// `lo > hi`. `Double.isNaN` and `<` are IEEE on both sides, so `-0.0` and the two infinities
    /// match the C++ exactly.
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
    /// `includingGroupingParenthesis` false is step 4's "if a result starts with `(` and ends with
    /// `)`, remove those characters", applied at the point of production rather than by editing the
    /// output, which is why a `StringBuilder` suffices.
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
            // function for the function corresponding to the node type. `includeGrouping` is unused,
            // because a math function is already parenthesised by its own name and paren.
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
            // Unreachable: the walk reports `.declined` before anything is appended if any node is
            // one of these. Trapping rather than emitting nothing, because a silently truncated
            // `cssText` is not recoverable evidence.
            preconditionFailure("the walk admitted a node kind the serializer cannot emit")

        @unknown default:
            preconditionFailure("the walk admitted a node kind the serializer cannot emit")
        }
    }

    /// https://drafts.csswg.org/css-values-4/#serialize-a-math-function, steps 3 to 5, for the
    /// operations whose arguments are a plain list of calculation trees.
    ///
    /// Every argument is serialized with the grouping parenthesis omitted, which is step 4's "if a
    /// result of this serialization starts with a `(` and ends with a `)`, remove those characters".
    /// It applies only to the arguments themselves -- a `Sum` inside an argument re-establishes
    /// `Include` for its own children, which is what makes `min(1px + 1em, (1rem + 1vw) * 2)` come
    /// out with one set of parentheses and not two.
    func serializeMathFunctionCall(
        _ node: borrowing WebCore.CSSCalc.CSSCalcSwiftNode,
        _ info: WebCore.CSSCalc.CSSCalcSwiftNodeInfo,
        _ sink: inout WebCore.CSSCalc.CSSCalcSwiftSink
    ) {
        // 3. Let s be a string initially containing the name of the root node, lowercased, followed by
        //    a "(".
        switch info.kind {
        case .RoundFunction:
            // `valueID` is the strategy here, because all four rounding operations share the name.
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
        // The four operations whose arguments are not a plain list of calculation trees take their
        // own branch.
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
            // because `min` and `max` are `ChildOrNone` and only `forAllChildren` visits a keyword.
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

    /// `random( <random-key>? , <calc-sum>, <calc-sum>, <calc-sum>? )`. The C++ `ASSERT`s that a key
    /// wrote something; this does not, because `wroteSomething` is what places the separators, so an
    /// empty key would come out as `random(, 1px, 1em)` on both sides.
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

        // `min`, `max`, and the optional `step`.
        var index: UInt32 = 0
        while index < info.childCount {
            if index > 0 {
                sink.appendLiteral(CSSCalcSwiftLiteral.commaSpace.rawValue)
            }
            serializeCalculationTree(node.childAt(index), includingGroupingParenthesis: false, &sink)
            index += 1
        }
    }

    /// `calc-mix( [ <calc-sum> <percentage [0,100]>? ]# )`. The weight upcall writes its own leading
    /// space, and writes nothing when the item has none, so this loop has no presence test.
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

    /// `anchor( <anchor-element>? && <anchor-side>, <length-percentage>? )`. Both subtree arguments
    /// go through `serializeWithoutOmittingPrefix`: "as anchor() is not actually a math function,
    /// calc() can't be omitted in arguments".
    func serializeAnchorArguments(
        _ node: borrowing WebCore.CSSCalc.CSSCalcSwiftNode,
        _ sink: inout WebCore.CSSCalc.CSSCalcSwiftSink
    ) {
        let operation = node.operationInfo()

        if operation.hasElementName {
            sink.appendOperationArgument(node, CSSCalcSwiftOperationPart.dashedIdent.rawValue, 0)
            sink.appendLiteral(CSSCalcSwiftLiteral.space.rawValue)
        }

        // The `<anchor-side>`: a keyword, or a `<percentage>` subtree occupying child 0. `walk`
        // checked that `childCount` agrees, so the fallback's index is not a guess.
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

    /// `anchor-size( [ <anchor-element> || <anchor-size> ]? , <length-percentage>? )`. Both leading
    /// parts are optional and independently so, which is why the separators are written from the
    /// flags rather than from a running "wrote something" the way `random()`'s key is.
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

    /// `serializeWithoutOmittingPrefix`: a leaf serializes as itself, and anything else as a math
    /// function -- so a `Sum` argument of `anchor()` comes out as `calc(1px + 1em)`. Reuses
    /// `serializeMathFunction`, whose `default` traps, which is safe only because `walk` already
    /// rejected any `anchor()` whose arguments are not serializable in root position.
    @inline(always)
    func serializeWithoutOmittingPrefix(
        _ node: borrowing WebCore.CSSCalc.CSSCalcSwiftNode,
        _ sink: inout WebCore.CSSCalc.CSSCalcSwiftSink
    ) {
        let info = node.info()
        switch info.kind {
        case .Number, .Percentage, .CanonicalDimension, .NonCanonicalDimension,
             .Symbol, .SiblingCount, .SiblingIndex:
            // The `Leaf auto&` overload; grouping never applies to a leaf on either path.
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
    /// `Negate`/` - `/` + `, and with no negative-value case, which is why this is not one function
    /// with a flag.
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
    /// The `calc(` wrapper and the grouping-parenthesis Omit are the same step 3/4 pair for every
    /// kind here except the last: `sibling-count()` and `sibling-index()` take no `calc(` wrapper,
    /// and both spellings parse, so only a dedicated test catches the difference.
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
            //    normal -- with no `calc(` wrapper, because step 1 returns before step 3 builds one.
            //    The C++ rebuilds the leaf through `makeChildWithValueBasedOn` and re-enters, but
            //    that helper replaces only the value, so the re-entry is one `appendNumber`.
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
            // tree with the grouping parenthesis omitted, which makes `calc(1px + 1em)` rather than
            // `calc((1px + 1em))`.
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
            // A math function's root serialization and its serialization as a child are the same
            // thing, which is why `min(1px, 1em)` has no `calc(` around it at the root.
            serializeMathFunctionCall(node, info, &sink)

        default:
            preconditionFailure("the root check admitted a node kind the math-function wrapper cannot emit")
        }
    }
}

/// Entry point: serialize a whole tree, or decline.
///
/// `isComputedStage`, `rangeMinimum` and `rangeMaximum` come from the caller rather than from the
/// tree, because `Stage` lives on `CSSCalc::Tree` and the range lives on `SerializationOptions`,
/// while the handle here is a cursor onto a `Child`. Together they are the rest of
/// `SerializationState`; see `CalcSerialization`.
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

    // The walk runs unconditionally, so that the counts describe every tree the gate saw and not
    // only the ones it could serialize.
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
