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

// Swift port of CSSCalcTree+Serialization.cpp, used when WebCore is built with WK_USE_SWIFT_CSS.
// Operator names and number formatting are C++ upcalls, because CSS number serialization is not
// Swift's shortest-round-trip `Double.description`.

/// Every fixed spelling this file emits, so that C++ owns the characters.
@c
enum CSSCalcSwiftLiteral: UInt8 {
    case calcOpen = 0
    case openParen = 1
    case closeParen = 2
    case emptyParens = 3
    case plus = 4
    case minus = 5
    case times = 6
    case dividedBy = 7
    case negateOpen = 8
    case invertOpen = 9
    case commaSpace = 10
    /// Fixed because the four rounding operations differ only by strategy.
    case roundOpen = 11
    case noClampOpen = 12
    case noneKeyword = 13
    case space = 14
    case randomFixedPrefix = 15
    case elementScoped = 16
}

/// Which non-tree argument of `random()`, `calc-mix()`, `anchor()` or `anchor-size()` an
/// `appendPayloadArgument` upcall should write.
@c
enum CSSCalcSwiftOperationPart: UInt8 {
    /// A `<random-cache-key>` name or an `<anchor-element>`, according to the node's kind.
    case dashedIdent = 0
    case randomFixedValue = 1
    /// Preceded by a space, or nothing at all when the item has no weight.
    case calcMixWeight = 2
}

/// The sort priority of a child that is not a numeric value at all.
///
/// `otherSortPriority` in `+Serialization.cpp`.
private let otherSortPriority = UInt32.max

/// The sort priority of a unit with no priority of its own.
///
/// `errorSortPriority` in `+Serialization.cpp`, which the C++ returns after an
/// `ASSERT_NOT_REACHED`.
private let errorSortPriority = UInt32.max - 1

/// The sort priority of a unit, `sortPriority(CSSUnitType)` in `+Serialization.cpp`.
///
/// An imported C++ enum's `init?(rawValue:)` accepts any value, so the `default` below is required
/// and a new `CSSUnitType` falls into it; the `static_assert` on `sortPriorityCount` beside the C++
/// table catches that. Keep the two in step: 64 priorities in the C++'s case order.
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

    default: return errorSortPriority
    }
}

/// The unit priority in the high 32 bits and the tree position in the low 32, so that ascending
/// integer order is the stable sort steps 6 and 7 ask for.
@inline(always)
private func sortKey(_ node: borrowing CalcNode, _ index: Int) -> UInt64 {
    let info = node[index].info
    var priority = otherSortPriority
    switch info.kind {
    case .number, .percentage, .canonicalDimension, .nonCanonicalDimension:
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

@inline(always)
private func childPosition(_ key: UInt64) -> Int {
    Int(key & 0xFFFF_FFFF)
}

/// Insertion sort, because a hand-written `calc()` is usually already sorted.
@inline(always)
private func fillSortedChildOrder(
    _ node: borrowing CalcNode,
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

/// Exhaustive, so that a kind split out of `operation` cannot silently claim coverage.
@inline(always)
private func isSerializableNode(
    _ kind: CalcNodeKind,
    _ childCount: UInt32
) -> Bool {
    switch kind {
    case .number, .percentage, .canonicalDimension, .nonCanonicalDimension:
        return true
    case .symbol, .siblingCount, .siblingIndex:
        return true
    case .sum, .product:
        // Steps 6 and 7 begin with the first child, so a childless `Sum` has no serialization. No
        // producer makes one, and refusing rather than inventing `calc(0)` keeps the break visible.
        return childCount > 0
    case .negate, .invert, .transparent:
        return childCount == 1
    case .function, .roundFunction, .progressNoClampFunction:
        // An argument-less math function serializes as `name()`.
        return true
    case .clampWithNoneMinimum, .clampWithNoneMaximum:
        // One bound holds the keyword, so two subtrees remain.
        return childCount == 2
    case .clampWithNoneMinimumAndMaximum:
        return childCount == 1
    case .operation:
        // An alternative `CalcNode.info` has not been taught, refused rather than written with a
        // wrong name.
        return false
    case .randomFunction:
        // The two required arguments plus an optional step; the `<random-key>` is not a child.
        return childCount == 2 || childCount == 3
    case .calcMixFunction:
        return true
    case .anchorFunction, .anchorSizeFunction:
        // Each argument goes through `serializeWithoutOmittingPrefix`, which is total over every
        // kind admitted here.
        return true
    }
}

/// The same question as `isSerializableNode`, since every kind serializes alike at the root.
@inline(always)
private func isSerializableRoot(
    _ kind: CalcNodeKind,
    _ childCount: UInt32
) -> Bool {
    isSerializableNode(kind, childCount)
}

/// Whether every node of the tree can be serialized here, established before anything is appended,
/// since a partial emit into C++'s `StringBuilder` cannot be undone.
private func walk(_ node: borrowing CalcNode) -> Bool {
    let info = node.info
    guard isSerializableNode(info.kind, info.childCount) else {
        return false
    }
    var index: UInt32 = 0
    while index < info.childCount {
        guard walk(node[Int(index)]) else {
            return false
        }
        index += 1
    }
    return true
}

/// The part of `SerializationState` that does not vary with depth. `groupingParenthesis` is a
/// parameter rather than state, so that no descent has to restore it.
private struct CalcSerialization {
    let isComputedStage: Bool
    let rangeMinimum: Double
    let rangeMaximum: Double

    /// NaN becomes 0, then `std::clamp`, spelled as the ternary it is specified to be:
    /// `min(max(value, lo), hi)` differs when `lo > hi`.
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
    /// `includingGroupingParenthesis` false is step 4's removal of an enclosing `(` and `)`, applied
    /// when the node is written rather than by editing the output.
    func serializeCalculationTree(
        _ node: borrowing CalcNode,
        includingGroupingParenthesis includeGrouping: Bool,
        _ sink: inout WebCore.CSSCalc.CSSCalcSwiftSink
    ) {
        let info = node.info
        switch info.kind {
        case .number, .percentage, .canonicalDimension, .nonCanonicalDimension:
            // 2. If root is a numeric value, serialize root per the normal rules for it.
            sink.appendNumber(info.numericValue, info.unitType)

        case .symbol:
            sink.appendValueIDName(info.valueID)

        case .siblingCount, .siblingIndex:
            sink.appendValueIDName(info.valueID)
            sink.appendLiteral(CSSCalcSwiftLiteral.emptyParens.rawValue)

        case .transparent:
            // `Deg2Rad` has no CSS spelling, so its child takes its place.
            serializeCalculationTree(node[0], includingGroupingParenthesis: includeGrouping, &sink)

        case .function, .roundFunction, .progressNoClampFunction,
            .clampWithNoneMinimum, .clampWithNoneMaximum, .clampWithNoneMinimumAndMaximum,
            .randomFunction, .calcMixFunction, .anchorFunction, .anchorSizeFunction:
            // 3. If root is anything but a Sum, Negate, Product, or Invert node, serialize a math
            // function for the function corresponding to the node type.
            serializeMathFunctionCall(node, info, &sink)

        case .sum:
            serializeSum(node, info.childCount, includingGroupingParenthesis: includeGrouping, &sink)

        case .product:
            serializeProduct(node, info.childCount, includingGroupingParenthesis: includeGrouping, &sink)

        case .negate:
            // 4. If root is a Negate node: `(`, `-1 * `, the child, `)`.
            if includeGrouping {
                sink.appendLiteral(CSSCalcSwiftLiteral.openParen.rawValue)
            }
            sink.appendLiteral(CSSCalcSwiftLiteral.negateOpen.rawValue)
            serializeCalculationTree(node[0], includingGroupingParenthesis: true, &sink)
            if includeGrouping {
                sink.appendLiteral(CSSCalcSwiftLiteral.closeParen.rawValue)
            }

        case .invert:
            // 5. If root is an Invert node: `(`, `1 / `, the child, `)`.
            if includeGrouping {
                sink.appendLiteral(CSSCalcSwiftLiteral.openParen.rawValue)
            }
            sink.appendLiteral(CSSCalcSwiftLiteral.invertOpen.rawValue)
            serializeCalculationTree(node[0], includingGroupingParenthesis: true, &sink)
            if includeGrouping {
                sink.appendLiteral(CSSCalcSwiftLiteral.closeParen.rawValue)
            }

        case .operation:
            // Unreachable: `walk` refuses it before anything is appended.
            preconditionFailure("the walk admitted a node kind the serializer cannot emit")
        }
    }

    /// https://drafts.csswg.org/css-values-4/#serialize-a-math-function, steps 3 to 5.
    ///
    /// Each argument omits its grouping parenthesis, but a `Sum` inside it keeps them for its own
    /// children, so `min(1px + 1em, (1rem + 1vw) * 2)` has one set of parentheses, not two.
    func serializeMathFunctionCall(
        _ node: borrowing CalcNode,
        _ info: CalcNodeInfo,
        _ sink: inout WebCore.CSSCalc.CSSCalcSwiftSink
    ) {
        // 3. Let s be a string initially containing the name of the root node, lowercased, followed by
        //    a "(".
        switch info.kind {
        case .roundFunction:
            // `valueID` is the strategy here, because all four rounding operations share the name.
            sink.appendLiteral(CSSCalcSwiftLiteral.roundOpen.rawValue)
            sink.appendValueIDName(info.valueID)
            sink.appendLiteral(CSSCalcSwiftLiteral.commaSpace.rawValue)

        case .progressNoClampFunction:
            sink.appendValueIDName(info.valueID)
            sink.appendLiteral(CSSCalcSwiftLiteral.noClampOpen.rawValue)

        default:
            sink.appendValueIDName(info.valueID)
            sink.appendLiteral(CSSCalcSwiftLiteral.openParen.rawValue)
        }

        // 4. For each child of the root node, serialize the calculation tree, then concatenate all of
        //    the results using ", ".
        switch info.kind {
        case .randomFunction:
            serializeRandomArguments(node, info, &sink)

        case .calcMixFunction:
            serializeCalcMixArguments(node, info, &sink)

        case .anchorFunction:
            serializeAnchorArguments(node, &sink)

        case .anchorSizeFunction:
            serializeAnchorSizeArguments(node, &sink)

        default:
            // A `clamp()` bound holding `none` is not a child, so it is written from the kind.
            let leadingNone = info.kind == .clampWithNoneMinimum || info.kind == .clampWithNoneMinimumAndMaximum
            let trailingNone = info.kind == .clampWithNoneMaximum || info.kind == .clampWithNoneMinimumAndMaximum
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
    func serializeRandomArguments(
        _ node: borrowing CalcNode,
        _ info: CalcNodeInfo,
        _ sink: inout WebCore.CSSCalc.CSSCalcSwiftSink
    ) {
        let operation = node.operationInfo(sink)

        if operation.randomSharingIsKey {
            var wroteSomething = false
            if operation.randomKeyHasName {
                sink.appendPayloadArgument(CSSCalcSwiftOperationPart.dashedIdent.rawValue, node.origin, 0, true)
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
            sink.appendPayloadArgument(CSSCalcSwiftOperationPart.randomFixedValue.rawValue, node.origin, 0, true)
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
    /// The weight upcall writes its own leading space.
    func serializeCalcMixArguments(
        _ node: borrowing CalcNode,
        _ info: CalcNodeInfo,
        _ sink: inout WebCore.CSSCalc.CSSCalcSwiftSink
    ) {
        var index: UInt32 = 0
        while index < info.childCount {
            if index > 0 {
                sink.appendLiteral(CSSCalcSwiftLiteral.commaSpace.rawValue)
            }
            serializeCalculationTree(node[Int(index)], includingGroupingParenthesis: false, &sink)
            let weight = node.calcMixWeight(Int(index))
            sink.appendPayloadArgument(
                CSSCalcSwiftOperationPart.calcMixWeight.rawValue,
                node.calcMixWeightPayload(Int(index)),
                weight.value,
                weight.present
            )
            index += 1
        }
    }

    /// `anchor( <anchor-element>? && <anchor-side>, <length-percentage>? )`. `anchor()` is not a
    /// math function, so `calc(` cannot be omitted in its arguments.
    func serializeAnchorArguments(
        _ node: borrowing CalcNode,
        _ sink: inout WebCore.CSSCalc.CSSCalcSwiftSink
    ) {
        let operation = node.operationInfo(sink)

        if operation.hasElementName {
            sink.appendPayloadArgument(CSSCalcSwiftOperationPart.dashedIdent.rawValue, node.origin, 0, true)
            sink.appendLiteral(CSSCalcSwiftLiteral.space.rawValue)
        }

        // The `<anchor-side>`: a keyword, or a `<percentage>` subtree occupying child 0.
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

    /// `anchor-size( [ <anchor-element> || <anchor-size> ]? , <length-percentage>? )`.
    func serializeAnchorSizeArguments(
        _ node: borrowing CalcNode,
        _ sink: inout WebCore.CSSCalc.CSSCalcSwiftSink
    ) {
        let operation = node.operationInfo(sink)

        if operation.hasElementName {
            sink.appendPayloadArgument(CSSCalcSwiftOperationPart.dashedIdent.rawValue, node.origin, 0, true)
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

    /// A leaf serializes as itself and anything else as a math function, so a `Sum` argument of
    /// `anchor()` comes out as `calc(1px + 1em)`.
    @inline(always)
    func serializeWithoutOmittingPrefix(
        _ node: borrowing CalcNode,
        _ sink: inout WebCore.CSSCalc.CSSCalcSwiftSink
    ) {
        let info = node.info
        switch info.kind {
        case .number, .percentage, .canonicalDimension, .nonCanonicalDimension,
            .symbol, .siblingCount, .siblingIndex:
            serializeCalculationTree(node, includingGroupingParenthesis: false, &sink)
        default:
            serializeMathFunction(node, info, &sink)
        }
    }

    /// Step 6, the Sum node.
    func serializeSum(
        _ node: borrowing CalcNode,
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

            // Every child keeps its grouping parenthesis: an omission applies to this node only.
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

    /// A function because `CalcNode` is non-copyable and Swift has no borrowing local binding, so
    /// `let child = node[i]` does not compile.
    func serializeSumTerm(
        _ child: borrowing CalcNode,
        _ sink: inout WebCore.CSSCalc.CSSCalcSwiftSink
    ) {
        let childInfo = child.info
        switch childInfo.kind {
        case .negate:
            // 6.1. If child is a Negate node, append " - " and serialize the Negate's child.
            sink.appendLiteral(CSSCalcSwiftLiteral.minus.rawValue)
            serializeCalculationTree(child[0], includingGroupingParenthesis: true, &sink)

        case .number, .percentage, .canonicalDimension, .nonCanonicalDimension:
            // 6.2. If child is a negative numeric value, append " - " and serialize its negation.
            // `-0.0` and NaN are not `< 0`, so both take the " + " branch, as in the C++.
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
    func serializeProduct(
        _ node: borrowing CalcNode,
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

    /// A function for the reason `serializeSumTerm` gives.
    func serializeProductTerm(
        _ child: borrowing CalcNode,
        _ sink: inout WebCore.CSSCalc.CSSCalcSwiftSink
    ) {
        if child.info.kind == .invert {
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
    /// Not `@inline(always)`: the `transparent` case makes this self-recursive, and the attribute is
    /// silently ignored on a recursive function.
    func serializeMathFunction(
        _ node: borrowing CalcNode,
        _ info: CalcNodeInfo,
        _ sink: inout WebCore.CSSCalc.CSSCalcSwiftSink
    ) {
        switch info.kind {
        case .number, .percentage, .canonicalDimension, .nonCanonicalDimension:
            // 1. If the root is a numeric value and the serialization is of a computed value or
            //    later, clamp the value to the range allowed for its context, then serialize it as
            //    normal, with no `calc(` wrapper.
            if isComputedStage {
                sink.appendNumber(clampValue(info.numericValue), info.unitType)
                return
            }
            sink.appendLiteral(CSSCalcSwiftLiteral.calcOpen.rawValue)
            sink.appendNumber(info.numericValue, info.unitType)
            sink.appendLiteral(CSSCalcSwiftLiteral.closeParen.rawValue)

        case .symbol:
            sink.appendLiteral(CSSCalcSwiftLiteral.calcOpen.rawValue)
            sink.appendValueIDName(info.valueID)
            sink.appendLiteral(CSSCalcSwiftLiteral.closeParen.rawValue)

        case .siblingCount, .siblingIndex:
            sink.appendValueIDName(info.valueID)
            sink.appendLiteral(CSSCalcSwiftLiteral.emptyParens.rawValue)

        case .sum:
            // 3. The prefix for a calc-operator node is "calc(". 4. Its argument is the calculation
            // tree with the grouping parenthesis omitted.
            sink.appendLiteral(CSSCalcSwiftLiteral.calcOpen.rawValue)
            serializeSum(node, info.childCount, includingGroupingParenthesis: false, &sink)
            sink.appendLiteral(CSSCalcSwiftLiteral.closeParen.rawValue)

        case .product:
            sink.appendLiteral(CSSCalcSwiftLiteral.calcOpen.rawValue)
            serializeProduct(node, info.childCount, includingGroupingParenthesis: false, &sink)
            sink.appendLiteral(CSSCalcSwiftLiteral.closeParen.rawValue)

        case .function, .roundFunction, .progressNoClampFunction,
            .clampWithNoneMinimum, .clampWithNoneMaximum, .clampWithNoneMinimumAndMaximum,
            .randomFunction, .calcMixFunction, .anchorFunction, .anchorSizeFunction:
            // The same as its serialization as a child, so `min(1px, 1em)` has no `calc(` around it.
            serializeMathFunctionCall(node, info, &sink)

        case .negate, .invert:
            // Steps 3 and 4 make `Negate(1px)` at the root `calc(-1 * 1px)`. This deliberately differs
            // from the C++ serializer, which drops the root's `-1 * ` or `1 / ` and emits `calc(1px)`,
            // a different value.
            sink.appendLiteral(CSSCalcSwiftLiteral.calcOpen.rawValue)
            serializeCalculationTree(node, includingGroupingParenthesis: false, &sink)
            sink.appendLiteral(CSSCalcSwiftLiteral.closeParen.rawValue)

        case .transparent:
            // `Deg2Rad` has no CSS spelling, so whether `calc(` appears is the child's decision.
            let childInfo = node[0].info
            serializeMathFunction(node[0], childInfo, &sink)

        case .operation:
            // Unreachable: `walk` refuses it.
            preconditionFailure("the root check admitted a node kind the math-function wrapper cannot emit")
        }
    }
}

/// False, with nothing appended, for a tree `walk` refuses.
///
/// `omittingGroupingParenthesis` false is `serializationForCSS`, which wraps a calc-operator root
/// in `calc(`; true is `serializationForCSSAsFunctionArgument`, for the inner `<calc-sum>` of
/// `calc-size()`, which writes the calculation tree with no `calc(` and does not clamp a numeric
/// root at the computed stage.
@_expose(Cxx)
public func cssCalcSerializeSwift(
    _ stored: CSSCalcSwiftRoot,
    _ sink: inout WebCore.CSSCalc.CSSCalcSwiftSink,
    _ isComputedStage: Bool,
    _ rangeMinimum: Double,
    _ rangeMaximum: Double,
    _ omittingGroupingParenthesis: Bool
) -> Bool {
    let box = stored
    return calcSerialize(box.root, &sink, isComputedStage, rangeMinimum, rangeMaximum, omittingGroupingParenthesis)
}

private func calcSerialize(
    _ root: borrowing CalcNode,
    _ sink: inout WebCore.CSSCalc.CSSCalcSwiftSink,
    _ isComputedStage: Bool,
    _ rangeMinimum: Double,
    _ rangeMaximum: Double,
    _ omittingGroupingParenthesis: Bool
) -> Bool {
    let rootInfo = root.info
    guard walk(root), isSerializableRoot(rootInfo.kind, rootInfo.childCount) else {
        return false
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

    return true
}
