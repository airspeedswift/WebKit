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

public import WebCore_Private.CSSCalcSwiftTypes
// `CSSCalc::Child` itself: this file walks the real tree, not a handle over it.
internal import WebCore_Private.Core

// Swift port of CSSCalcTree+Serialization.cpp, used when WebCore is built with WK_USE_SWIFT_CSS.
//
// The walk establishes coverage over the whole tree before any output is appended, since a partial
// emit into C++'s `StringBuilder` cannot be undone. Anything it cannot serialize is handed back to
// the C++ serializer with nothing emitted.
//
// Operator names and number formatting are C++ upcalls: `nameLiteralForSerialization` is generated
// from CSSValueKeywords.in, and `formatCSSNumberValue` implements an algorithm that is not Swift's
// shortest-round-trip `Double.description`, so a reimplementation here would diverge on subnormals
// and high-precision values.

/// Whether this file serialized a tree, or left it for the C++ serializer.
///
/// `@c` (SE-0495) makes this the single declaration of the numbering: it is `static_assert`ed
/// against these names in CSSCalcTree+Serialization.cpp, so reordering these cases is a build
/// failure there rather than a silent reinterpretation of every calc() in every stylesheet.
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
    /// `(`, the grouping parenthesis of steps 4 to 7.
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

/// The sort priority of a child that is not a numeric value at all.
///
/// `otherSortPriority` in `+Serialization.cpp`.
private let otherSortPriority = UInt32.max

/// The sort priority of a unit with no priority of its own.
///
/// `errorSortPriority` in `+Serialization.cpp`, which the C++ reaches through an
/// `ASSERT_NOT_REACHED` that is compiled out of every shipping build, so this reproduces the
/// shipping behaviour.
private let errorSortPriority = UInt32.max - 1

/// The css-values-4 sort key of a unit. A second, independent spelling of `+Serialization.cpp`'s
/// `sortPriority(CSSUnitType)`, which assigns its keys with `__COUNTER__`.
///
/// The second spelling is forced: an imported C++ scoped enum's `init?(rawValue:)` accepts any value
/// of the underlying type, so this switch needs a `default` and cannot be exhaustive the way the
/// C++'s is. That `default` is also the hazard, because a newly added `CSSUnitType` falls into it and
/// mis-orders a `Sum` rather than failing to build. What catches that is the `static_assert` on
/// `sortPriorityCount` beside the C++ table, which fails and names this file. Keep the two in step:
/// 64 priorities, keys 0 through 63, in the C++'s own case order.
@inline(always)
private func sortPriority(_ unit: WebCore.CSSUnitType) -> UInt32 {
    switch unit {
    case .Number, .Integer: return 0
    case .Percentage: return 1
    case .Cap: return 2
    case .Ch: return 3
    case .Cm: return 4
    case .Cqb: return 5
    case .Cqh: return 6
    case .Cqi: return 7
    case .Cqmax: return 8
    case .Cqmin: return 9
    case .Cqw: return 10
    case .Deg: return 11
    case .Dpcm: return 12
    case .Dpi: return 13
    case .Dppx: return 14
    case .Dvb: return 15
    case .Dvh: return 16
    case .Dvi: return 17
    case .Dvmax: return 18
    case .Dvmin: return 19
    case .Dvw: return 20
    case .Em: return 21
    case .Ex: return 22
    case .Fr: return 23
    case .Grad: return 24
    case .Hz: return 25
    case .Ic: return 26
    case .In: return 27
    case .Khz: return 28
    case .Lh: return 29
    case .Lvb: return 30
    case .Lvh: return 31
    case .Lvi: return 32
    case .Lvmax: return 33
    case .Lvmin: return 34
    case .Lvw: return 35
    case .Mm: return 36
    case .Ms: return 37
    case .Pc: return 38
    case .Pt: return 39
    case .Px: return 40
    case .Q: return 41
    case .Rad: return 42
    case .Rcap: return 43
    case .Rch: return 44
    case .Rem: return 45
    case .Rex: return 46
    case .Ric: return 47
    case .Rlh: return 48
    case .S: return 49
    case .Svb: return 50
    case .Svh: return 51
    case .Svi: return 52
    case .Svmax: return 53
    case .Svmin: return 54
    case .Svw: return 55
    case .Turn: return 56
    case .Vb: return 57
    case .Vh: return 58
    case .Vi: return 59
    case .Vmax: return 60
    case .Vmin: return 61
    case .Vw: return 62
    case .X: return 63

    // Non-numeric types are not supported, and `default` rather than naming the five, because an
    // imported C++ scoped enum's `init?(rawValue:)` accepts any value of the underlying type.
    default: return errorSortPriority
    }
}

/// The sort key of child `index` of `node`.
///
/// The unit priority is in the high 32 bits and the tree position in the low 32, so ascending
/// integer order on it is the stable sort steps 6 and 7 ask for and there is no comparator and no
/// stability argument to get wrong.
@inline(always)
private func sortKey(_ node: borrowing WebCore.CSSCalc.Child, _ index: Int) -> UInt64 {
    let info = WebCore.CSSCalc.swiftNodeInfo(node[index])
    var priority = otherSortPriority
    switch info.kind {
    case .Number, .Percentage, .CanonicalDimension, .NonCanonicalDimension:
        // `sortPriority(const Child&)`'s `[]<Numeric T>` overload is exactly these four alternatives.
        if let unit = WebCore.CSSUnitType(rawValue: info.unitType) {
            priority = sortPriority(unit)
        } else {
            priority = errorSortPriority
        }
    default:
        break
    }
    return (UInt64(priority) << 32) | UInt64(UInt32(index))
}

/// The tree position a sort key names.
@inline(always)
private func childPosition(_ key: UInt64) -> Int {
    Int(key & 0xFFFF_FFFF)
}

/// Fill `keys` with the sort keys of the children of `node`, in serialization order.
///
/// Insertion sort, because an already-sorted input, which a hand-written `calc()` usually is,
/// costs one comparison per element.
@inline(always)
private func fillSortedChildOrder(
    _ node: borrowing WebCore.CSSCalc.Child,
    _ childCount: Int,
    _ keys: inout OutputSpan<UInt64>
) {
    var index = 0
    while index < childCount {
        keys.append(sortKey(node, index))
        index += 1
    }

    var order = keys.mutableSpan
    var i = 1
    while i < order.count {
        let key = order[i]
        var j = i
        while j > 0 && order[j - 1] > key {
            order[j] = order[j - 1]
            j -= 1
        }
        order[j] = key
        i += 1
    }
}

/// One bit per `CSSCalcSwiftNodeKind`, for the mask the walk reports.
@inline(always)
private func kindBit(_ kind: WebCore.CSSCalc.CSSCalcSwiftNodeKind) -> UInt32 {
    UInt32(1) << UInt32(kind.rawValue)
}

/// Whether this file can serialize a node of this kind anywhere in a tree.
///
/// An exhaustive `switch`, so that splitting further kinds out of `Operation` later cannot silently
/// start claiming coverage it does not have.
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
        // serialization at all.
        //
        // Not a coverage gap but a tree-invariant violation, which the C++ simplifier asserts
        // (`ASSERT(!root.children.isEmpty())`). No producer can make one: `parseCalcSum` and
        // `parseCalcProduct` return the single term rather than wrapping it when the operand list came
        // out empty, and `add`/`multiply`/`subtract` append exactly two. The C++ serializer would read
        // an empty inline buffer behind a compiled-out `ASSERT`, so refusing is strictly safer than
        // matching it. It stays a refusal rather than an invented identity value (`calc(0)` /
        // `calc(1)`), because inventing output would mask the invariant break that had to happen
        // upstream to get here.
        return childCount > 0
    case .Negate, .Invert, .Transparent:
        // Fixed arity 1 by construction: all three are single-slot operations in CSSCalcTree.h, so a
        // count other than 1 is the same class of invariant violation as a childless `Sum`.
        return childCount == 1
    case .Function, .RoundFunction, .ProgressNoClampFunction:
        // No lower bound: an argument-less math function serializes as `name()` on both paths.
        return true
    case .ClampWithNoneMinimum, .ClampWithNoneMaximum:
        // Exactly one bound holds the keyword, so two subtrees remain. Insisting on the count keeps
        // the keyword's position and the arguments' positions in agreement.
        return childCount == 2
    case .ClampWithNoneMinimumAndMaximum:
        // Both bounds hold the keyword, so only `val` is a child.
        return childCount == 1
    case .Operation:
        // Producerless by construction, not merely unobserved: `swiftNodeInfo`'s generic
        // classification branch carries a `static_assert` (CSSCalcTree+Serialization.cpp), in every
        // configuration, that every alternative reaching it is a rounding strategy, `ProgressNoClamp`,
        // or an `isGenericSerializedFunction`, all three of which get a kind of their own. `Clamp`
        // with both bounds `none` has `ClampWithNoneMinimumAndMaximum`. Kept `false` so that a build
        // with the C++ serializer hands such a tree back rather than trapping.
        return false
    case .RandomFunction:
        // The two required arguments plus an optional step; the `<random-key>` is not a child.
        return childCount == 2 || childCount == 3
    case .CalcMixFunction:
        return true
    case .AnchorFunction, .AnchorSizeFunction:
        // Each argument goes through `serializeWithoutOmittingPrefix`, which is total over every kind
        // this predicate admits.
        return true
    case .OpaqueOperation:
        // Nothing assigns this enumerator. Removing it would renumber every kind above it, and
        // `kindMask` is `1 << rawValue`, which the `static_assert` beside `CSSCalcSwiftNodeKind` in
        // CSSCalcSwiftTypes.h pins.
        return false
    @unknown default:
        // A kind added to `CSSCalcSwiftNodeKind` without a case here reaches
        // CSSCalcTree+Serialization.cpp's `RELEASE_ASSERT_NOT_REACHED_WITH_MESSAGE` when the C++
        // serializer is compiled out, rather than failing the build.
        return false
    }
}

/// Whether this file can serialize a tree rooted at this kind.
///
/// The same question as `isSerializableNode`: `serializeMathFunction` emits a root `Negate`,
/// `Invert` and `Transparent` alike, so there is no position-dependent refusal.
@inline(always)
private func isSerializableRoot(
    _ kind: WebCore.CSSCalc.CSSCalcSwiftNodeKind,
    _ childCount: UInt32
) -> Bool {
    isSerializableNode(kind, childCount)
}

/// The traversal.
///
/// Accumulates the node count and the kind mask, and reports whether every node it saw can be
/// serialized here.
///
/// Recursive rather than an explicit stack, which would need a Swift container of a non-copyable
/// borrowed element. Tree order, not serialization order: all three of its results (a sum, a
/// bitwise OR, and an AND over the children) are commutative.
private func walk(
    _ node: borrowing WebCore.CSSCalc.Child,
    _ nodeCount: inout UInt32,
    _ kindMask: inout UInt32
) -> Bool {
    // One crossing per node, not five.
    let info = WebCore.CSSCalc.swiftNodeInfo(node)
    nodeCount += 1
    kindMask |= kindBit(info.kind)

    var everyNodeSerializable = isSerializableNode(info.kind, info.childCount)

    let count = info.childCount
    var index: UInt32 = 0
    while index < count {
        // Kept as a full traversal even once `everyNodeSerializable` is false, so that the counts
        // describe the whole tree rather than the prefix before the first unhandled node.
        if !walk(node[Int(index)], &nodeCount, &kindMask) {
            everyNodeSerializable = false
        }
        index += 1
    }

    return everyNodeSerializable
}

/// The part of `SerializationState` that does not vary as the walk descends.
///
/// The C++ puts both halves in one mutable `SerializationState&` and then needs
/// `ParenthesisSaver`, a destructor, to put the varying half back; here `groupingParenthesis`
/// stays a parameter the compiler demands a value for, which a descent cannot forget to restore.
private struct CalcSerialization {
    /// From the caller rather than the tree, because `Stage` lives on `CSSCalc::Tree`.
    let isComputedStage: Bool
    let rangeMinimum: Double
    let rangeMaximum: Double

    /// `clampValue`: NaN becomes 0, then `std::clamp`.
    ///
    /// Spelled as the ternary `std::clamp` is specified to be, not as `min(max(value, lo), hi)`,
    /// which is a different function whenever `lo > hi`. `Double.isNaN` and `<` are IEEE on both
    /// sides, so `-0.0` and the two infinities match the C++ exactly.
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

    /// Serializes a calculation tree.
    ///
    /// https://drafts.csswg.org/css-values-4/#serialize-a-calculation-tree
    ///
    /// `includingGroupingParenthesis` false is step 4's "if a result starts with `(` and ends with
    /// `)`, remove those characters", applied at the point of production rather than by editing the
    /// output, which is why a `StringBuilder` suffices.
    func serializeCalculationTree(
        _ node: borrowing WebCore.CSSCalc.Child,
        includingGroupingParenthesis includeGrouping: Bool,
        _ sink: inout WebCore.CSSCalc.CSSCalcSwiftSink
    ) {
        let info = WebCore.CSSCalc.swiftNodeInfo(node)
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
            // `Deg2Rad` has no CSS-level representation, so serialize the child in its place,
            // inheriting this node's grouping parenthesis.
            serializeCalculationTree(node[0], includingGroupingParenthesis: includeGrouping, &sink)

        case .Function, .RoundFunction, .ProgressNoClampFunction,
            .ClampWithNoneMinimum, .ClampWithNoneMaximum, .ClampWithNoneMinimumAndMaximum,
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
            serializeCalculationTree(node[0], includingGroupingParenthesis: true, &sink)
            if includeGrouping {
                sink.appendLiteral(CSSCalcSwiftLiteral.closeParen.rawValue)
            }

        case .Invert:
            // 5. If root is an Invert node: `(`, `1 / `, the child, `)`.
            if includeGrouping {
                sink.appendLiteral(CSSCalcSwiftLiteral.openParen.rawValue)
            }
            sink.appendLiteral(CSSCalcSwiftLiteral.invertOpen.rawValue)
            serializeCalculationTree(node[0], includingGroupingParenthesis: true, &sink)
            if includeGrouping {
                sink.appendLiteral(CSSCalcSwiftLiteral.closeParen.rawValue)
            }

        case .Operation, .OpaqueOperation:
            // Unreachable: `isSerializableNode` returns false for both, so `cssCalcSerializeSwift`
            // returns `.declined` before anything is appended.
            preconditionFailure("the walk admitted a node kind the serializer cannot emit")

        @unknown default:
            // Required because `CSSCalcSwiftNodeKind` is an imported C++ enum, and unreachable because
            // `isSerializableNode`'s own `@unknown default` returns false.
            preconditionFailure("the walk admitted a node kind the serializer cannot emit")
        }
    }

    /// https://drafts.csswg.org/css-values-4/#serialize-a-math-function, steps 3 to 5, for the
    /// operations whose arguments are a plain list of calculation trees.
    ///
    /// Every argument is serialized with the grouping parenthesis omitted, which is step 4's "if a
    /// result of this serialization starts with a `(` and ends with a `)`, remove those characters".
    /// It applies only to the arguments themselves: a `Sum` inside an argument re-establishes
    /// `Include` for its own children, which is what makes `min(1px + 1em, (1rem + 1vw) * 2)` come
    /// out with one set of parentheses and not two.
    func serializeMathFunctionCall(
        _ node: borrowing WebCore.CSSCalc.Child,
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
            // With both bounds `none` there is one child and two keywords, which is why the leading
            // `none` is written for two kinds and the trailing one for two others.
            let leadingNone = info.kind == .ClampWithNoneMinimum || info.kind == .ClampWithNoneMinimumAndMaximum
            let trailingNone = info.kind == .ClampWithNoneMaximum || info.kind == .ClampWithNoneMinimumAndMaximum
            var index: UInt32 = leadingNone ? 1 : 0
            if leadingNone {
                sink.appendLiteral(CSSCalcSwiftLiteral.noneKeyword.rawValue)
                sink.appendLiteral(CSSCalcSwiftLiteral.commaSpace.rawValue)
                serializeCalculationTree(node[0], includingGroupingParenthesis: false, &sink)
            }
            while index < info.childCount {
                if index > 0 {
                    sink.appendLiteral(CSSCalcSwiftLiteral.commaSpace.rawValue)
                }
                serializeCalculationTree(node[Int(index)], includingGroupingParenthesis: false, &sink)
                index += 1
            }
            if trailingNone {
                sink.appendLiteral(CSSCalcSwiftLiteral.commaSpace.rawValue)
                sink.appendLiteral(CSSCalcSwiftLiteral.noneKeyword.rawValue)
            }
        }

        // 5. Append ")" to s.
        sink.appendLiteral(CSSCalcSwiftLiteral.closeParen.rawValue)
    }

    /// `random( <random-key>? , <calc-sum>, <calc-sum>, <calc-sum>? )`.
    ///
    /// The C++ `ASSERT`s that a key wrote something; this does not, because `wroteSomething` is what
    /// places the separators, so an empty key would come out as `random(, 1px, 1em)` on both sides.
    func serializeRandomArguments(
        _ node: borrowing WebCore.CSSCalc.Child,
        _ info: WebCore.CSSCalc.CSSCalcSwiftNodeInfo,
        _ sink: inout WebCore.CSSCalc.CSSCalcSwiftSink
    ) {
        let operation = WebCore.CSSCalc.swiftOperationInfo(node)

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
            serializeCalculationTree(node[Int(index)], includingGroupingParenthesis: false, &sink)
            index += 1
        }
    }

    /// `calc-mix( [ <calc-sum> <percentage [0,100]>? ]# )`.
    ///
    /// The weight upcall writes its own leading space, and writes nothing when the item has none, so
    /// this loop has no presence test.
    func serializeCalcMixArguments(
        _ node: borrowing WebCore.CSSCalc.Child,
        _ info: WebCore.CSSCalc.CSSCalcSwiftNodeInfo,
        _ sink: inout WebCore.CSSCalc.CSSCalcSwiftSink
    ) {
        var index: UInt32 = 0
        while index < info.childCount {
            if index > 0 {
                sink.appendLiteral(CSSCalcSwiftLiteral.commaSpace.rawValue)
            }
            serializeCalculationTree(node[Int(index)], includingGroupingParenthesis: false, &sink)
            sink.appendOperationArgument(node, CSSCalcSwiftOperationPart.calcMixWeight.rawValue, index)
            index += 1
        }
    }

    /// `anchor( <anchor-element>? && <anchor-side>, <length-percentage>? )`.
    ///
    /// Both subtree arguments go through `serializeWithoutOmittingPrefix`: "as anchor() is not
    /// actually a math function, calc() can't be omitted in arguments".
    func serializeAnchorArguments(
        _ node: borrowing WebCore.CSSCalc.Child,
        _ sink: inout WebCore.CSSCalc.CSSCalcSwiftSink
    ) {
        let operation = WebCore.CSSCalc.swiftOperationInfo(node)

        if operation.hasElementName {
            sink.appendOperationArgument(node, CSSCalcSwiftOperationPart.dashedIdent.rawValue, 0)
            sink.appendLiteral(CSSCalcSwiftLiteral.space.rawValue)
        }

        // The `<anchor-side>`: a keyword, or a `<percentage>` subtree occupying child 0.
        // `childCount`, `anchorSideIsKeyword` and `hasFallback` are all derived from `Anchor::side`
        // and `Anchor::fallback`, so they cannot disagree about which slot the fallback is in, and
        // `Child::operator[]` `RELEASE_ASSERT`s an out-of-range index.
        var fallbackIndex: UInt32 = 0
        if operation.anchorSideIsKeyword {
            sink.appendValueIDName(operation.valueID)
        } else {
            serializeWithoutOmittingPrefix(node[0], &sink)
            fallbackIndex = 1
        }

        if operation.hasFallback {
            sink.appendLiteral(CSSCalcSwiftLiteral.commaSpace.rawValue)
            serializeWithoutOmittingPrefix(node[Int(fallbackIndex)], &sink)
        }
    }

    /// `anchor-size( [ <anchor-element> || <anchor-size> ]? , <length-percentage>? )`. Both leading
    /// parts are optional and independently so, which is why the separators are written from the
    /// flags rather than from a running "wrote something" the way `random()`'s key is.
    func serializeAnchorSizeArguments(
        _ node: borrowing WebCore.CSSCalc.Child,
        _ sink: inout WebCore.CSSCalc.CSSCalcSwiftSink
    ) {
        let operation = WebCore.CSSCalc.swiftOperationInfo(node)

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
            serializeWithoutOmittingPrefix(node[0], &sink)
        }
    }

    /// `serializeWithoutOmittingPrefix`: a leaf serializes as itself, and anything else as a math
    /// function, so a `Sum` argument of `anchor()` comes out as `calc(1px + 1em)`.
    ///
    /// Reuses `serializeMathFunction`, whose `default` traps, which is safe only because `walk`
    /// already rejected any `anchor()` whose arguments are not serializable in root position.
    @inline(always)
    func serializeWithoutOmittingPrefix(
        _ node: borrowing WebCore.CSSCalc.Child,
        _ sink: inout WebCore.CSSCalc.CSSCalcSwiftSink
    ) {
        let info = WebCore.CSSCalc.swiftNodeInfo(node)
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
    /// "Sort root's children" is step 6's first clause.
    func serializeSum(
        _ node: borrowing WebCore.CSSCalc.Child,
        _ childCount: UInt32,
        includingGroupingParenthesis includeGrouping: Bool,
        _ sink: inout WebCore.CSSCalc.CSSCalcSwiftSink
    ) {
        if includeGrouping {
            sink.appendLiteral(CSSCalcSwiftLiteral.openParen.rawValue)
        }

        let count = Int(childCount)
        withTemporaryAllocation(of: UInt64.self, capacity: count) { (keys: inout OutputSpan<UInt64>) in
            fillSortedChildOrder(node, count, &keys)
            let order = keys.mutableSpan

            // - Serialize root's first child. Every child is serialized with its grouping
            //   parenthesis: an `Omit` installed by a math-function wrapper applies to this node only.
            serializeCalculationTree(node[childPosition(order[0])], includingGroupingParenthesis: true, &sink)

            var index = 1
            while index < count {
                serializeSumTerm(node[childPosition(order[index])], &sink)
                index += 1
            }
        }

        if includeGrouping {
            sink.appendLiteral(CSSCalcSwiftLiteral.closeParen.rawValue)
        }
    }

    /// One later term of a `Sum`, with its own ` + ` or ` - ` separator.
    ///
    /// A `borrowing` parameter is the whole reason this is a function: `Child` is non-copyable, so
    /// `let child = node[i]` is a consume of a borrow and does not compile, and Swift has no
    /// borrowing local binding.
    func serializeSumTerm(
        _ child: borrowing WebCore.CSSCalc.Child,
        _ sink: inout WebCore.CSSCalc.CSSCalcSwiftSink
    ) {
        let childInfo = WebCore.CSSCalc.swiftNodeInfo(child)
        switch childInfo.kind {
        case .Negate:
            // 6.1. If child is a Negate node, append " - " and serialize the Negate's child.
            sink.appendLiteral(CSSCalcSwiftLiteral.minus.rawValue)
            serializeCalculationTree(child[0], includingGroupingParenthesis: true, &sink)

        case .Number, .Percentage, .CanonicalDimension, .NonCanonicalDimension:
            // 6.2. If child is a negative numeric value, append " - " and serialize its negation.
            // `< 0` has IEEE semantics on both sides, which is load-bearing: `-0.0 < 0` is false and
            // `Double.nan < 0` is false, so both take the " + " branch, exactly as the C++ does.
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
    }

    /// Step 7, the Product node.
    ///
    /// Same shape as step 6 with `Invert`/` / `/` * ` in place of `Negate`/` - `/` + `, and with no
    /// negative-value case, which is why this is not one function with a flag.
    func serializeProduct(
        _ node: borrowing WebCore.CSSCalc.Child,
        _ childCount: UInt32,
        includingGroupingParenthesis includeGrouping: Bool,
        _ sink: inout WebCore.CSSCalc.CSSCalcSwiftSink
    ) {
        if includeGrouping {
            sink.appendLiteral(CSSCalcSwiftLiteral.openParen.rawValue)
        }

        let count = Int(childCount)
        withTemporaryAllocation(of: UInt64.self, capacity: count) { (keys: inout OutputSpan<UInt64>) in
            fillSortedChildOrder(node, count, &keys)
            let order = keys.mutableSpan

            serializeCalculationTree(node[childPosition(order[0])], includingGroupingParenthesis: true, &sink)

            var index = 1
            while index < count {
                serializeProductTerm(node[childPosition(order[index])], &sink)
                index += 1
            }
        }

        if includeGrouping {
            sink.appendLiteral(CSSCalcSwiftLiteral.closeParen.rawValue)
        }
    }

    /// One later term of a `Product`.
    ///
    /// A `borrowing` parameter for the reason `serializeSumTerm` gives.
    func serializeProductTerm(
        _ child: borrowing WebCore.CSSCalc.Child,
        _ sink: inout WebCore.CSSCalc.CSSCalcSwiftSink
    ) {
        if WebCore.CSSCalc.swiftNodeInfo(child).kind == .Invert {
            // 7.1. If child is an Invert node, append " / " and serialize the Invert's child.
            sink.appendLiteral(CSSCalcSwiftLiteral.dividedBy.rawValue)
            serializeCalculationTree(child[0], includingGroupingParenthesis: true, &sink)
        } else {
            // 7.2. Otherwise, append " * " and serialize child.
            sink.appendLiteral(CSSCalcSwiftLiteral.times.rawValue)
            serializeCalculationTree(child, includingGroupingParenthesis: true, &sink)
        }
    }

    /// Serializes a math function.
    ///
    /// https://drafts.csswg.org/css-values-4/#serialize-a-math-function
    ///
    /// The `calc(` wrapper and the grouping-parenthesis Omit are the same step 3/4 pair for every
    /// kind here except the last: `sibling-count()` and `sibling-index()` take no `calc(` wrapper,
    /// and both spellings parse, so only a dedicated test catches the difference.
    ///
    /// Not `@inline(always)`: the `Transparent` case makes this directly self-recursive, and the
    /// attribute is silently declined on a recursive function rather than diagnosed.
    func serializeMathFunction(
        _ node: borrowing WebCore.CSSCalc.Child,
        _ info: WebCore.CSSCalc.CSSCalcSwiftNodeInfo,
        _ sink: inout WebCore.CSSCalc.CSSCalcSwiftSink
    ) {
        switch info.kind {
        case .Number, .Percentage, .CanonicalDimension, .NonCanonicalDimension:
            // 1. If the root is a numeric value and the serialization is of a computed value or
            //    later, clamp the value to the range allowed for its context, then serialize it as
            //    normal, with no `calc(` wrapper, because step 1 returns before step 3 builds one.
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
            .ClampWithNoneMinimum, .ClampWithNoneMaximum, .ClampWithNoneMinimumAndMaximum,
            .RandomFunction, .CalcMixFunction, .AnchorFunction, .AnchorSizeFunction:
            // A math function's root serialization and its serialization as a child are the same
            // thing, which is why `min(1px, 1em)` has no `calc(` around it at the root.
            serializeMathFunctionCall(node, info, &sink)

        case .Negate, .Invert:
            // css-values-4 #serialize-a-math-function step 4 serializes the root node with its grouping
            // parenthesis removed, so `Negate(1px)` is `calc(-1 * 1px)`. The C++ serializer omits the
            // `-1 * ` for a root `Negate` and emits `calc(1px)`.
            sink.appendLiteral(CSSCalcSwiftLiteral.calcOpen.rawValue)
            serializeCalculationTree(node, includingGroupingParenthesis: false, &sink)
            sink.appendLiteral(CSSCalcSwiftLiteral.closeParen.rawValue)

        case .Transparent:
            // `Deg2Rad` has no CSS-level representation, so the C++ `serializeMathFunction` overload
            // for it defers to the child's own math function, which is why whether `calc(` appears
            // is the child's decision, not this node's. Recursive because a `Deg2Rad` wrapping a
            // `Deg2Rad` is expressible and Swift has no borrowing local binding to loop with.
            let childInfo = WebCore.CSSCalc.swiftNodeInfo(node[0])
            serializeMathFunction(node[0], childInfo, &sink)

        case .Operation, .OpaqueOperation:
            preconditionFailure("the root check admitted a node kind the math-function wrapper cannot emit")

        @unknown default:
            // Not eliminable: an imported C++ enum is non-exhaustive to Swift whatever its case list.
            preconditionFailure("the root check admitted a node kind the math-function wrapper cannot emit")
        }
    }
}

/// Entry point: serialize a whole tree, or leave it to the C++ serializer. `isComputedStage`,
/// `rangeMinimum` and `rangeMaximum` come from the caller, because `Stage` lives on
/// `CSSCalc::Tree` and the range on `SerializationOptions`.
///
/// `omittingGroupingParenthesis` selects between the two C++ entry points rather than adding a third
/// behaviour: false is `serializationForCSS`, which serializes a *math function* and so wraps a
/// calc-operator root in `calc(`; true is `serializationForCSSAsFunctionArgument`, which serializes
/// the *calculation tree* with the outermost grouping parenthesis omitted and no `calc(` at all --
/// `calc-size()`'s inner `<calc-sum>`, its only caller (CSSCalcSizeFunction.cpp). The C++
/// difference is exactly `SerializationState::groupingParenthesis` plus which of
/// `serializeMathFunction` / `serializeCalculationTree` the root enters, and that is what these two
/// branches are. The function-argument path does *not* clamp a numeric root at the computed stage,
/// because `serializeCalculationTree`'s `Numeric` overload has no such step where
/// `serializeMathFunction`'s does.
@_expose(Cxx)
public func cssCalcSerializeSwift(
    _ root: borrowing WebCore.CSSCalc.Child,
    _ sink: inout WebCore.CSSCalc.CSSCalcSwiftSink,
    _ isComputedStage: Bool,
    _ rangeMinimum: Double,
    _ rangeMaximum: Double,
    _ omittingGroupingParenthesis: Bool
) -> WebCore.CSSCalc.CSSCalcSwiftSerializationResult {
    var nodeCount: UInt32 = 0
    var kindMask: UInt32 = 0

    // The walk runs unconditionally, so that the counts describe every tree passed in and not only
    // the ones it could serialize.
    let everyNodeSerializable = walk(root, &nodeCount, &kindMask)

    let rootInfo = WebCore.CSSCalc.swiftNodeInfo(root)
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
    if omittingGroupingParenthesis {
        serialization.serializeCalculationTree(root, includingGroupingParenthesis: false, &sink)
    } else {
        serialization.serializeMathFunction(root, rootInfo, &sink)
    }

    return WebCore.CSSCalc.CSSCalcSwiftSerializationResult(
        kindMask: kindMask,
        nodeCount: nodeCount,
        outcome: CSSCalcSwiftOutcome.serialized.rawValue
    )
}
