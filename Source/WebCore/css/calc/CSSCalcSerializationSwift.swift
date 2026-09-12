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

// This file's own boundary types.
public import WebCore_Private.CSSCalcSwiftTypes

// `CSSCalc::Child` itself: this file walks the REAL tree, not a handle over it, exactly as
// CSSCalcSimplificationSwift.swift does. `Child::operator[]` yields a checked borrow of a child and
// `Child::childCount()` bounds the loop; the subscript spelling is load-bearing rather than
// stylistic, and CSSCalcTree.h explains why at the declaration.
internal import WebCore_Private.Core

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
// Operator names are a C++ upcall, for the same reason number formatting is. THE SORT ORDER IS
// NOT, any more: steps 6 and 7 sort a `Sum`'s and a `Product`'s children and nothing else's, and
// this file computes that order itself from `swiftNodeInfo(child).unitType` and `sortPriority`
// below. It used to name a position and let `swiftSerializationChildIndex` say what the position
// meant, which regenerated the whole permutation ON EVERY ACCESS -- measured as the entire
// width-dependent Swift-vs-C++ serialization gap, a ratio climbing 1.45 to 3.00 across a 4.3x
// width range where the unsorted `min()` family stayed flat at 1.315
// (notes/calc-c2-serialization-band-and-refutation-0911.md). Ordering here costs one `UInt64` key
// per child in a `withTemporaryAllocation` buffer, computed once per node.
// `nameLiteralForSerialization` is generated from CSSValueKeywords.in, so this file carries a
// `CSSValueID` and `appendValueIDName` owns the spelling; the twenty-six plain math functions
// therefore cost no name table here. `sink.appendNumber` likewise routes to C++'s
// `formatCSSNumberValue`: Swift's `Double.description` is shortest-round-trip and CSS's algorithm
// is not, so a reimplementation would diverge on subnormals and high-precision values.
//
// The walk establishes coverage over the whole tree before any output is appended, since a partial
// emit into C++'s `StringBuilder` cannot be undone.
//
// The tree crosses as a borrowed non-copyable `Child` and the output as a `SWIFT_SAFE` sink taken
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

/// Sorts after every real unit, for a child that is not a numeric value at all.
///
/// `+Serialization.cpp`'s `otherSortPriority`, and the sentinel is `UInt32.max` on both sides for
/// the same reason: it is independent of how many units there are, so adding one cannot collide
/// with it.
private let otherSortPriority = UInt32.max

/// Sorts after every real unit and before `otherSortPriority`, for a numeric value whose unit is
/// not one the sort order covers (`Calc`, the two `CalcPercentageWith*`, `QuirkyEm`, `Unknown`).
///
/// `+Serialization.cpp`'s `errorSortPriority`. The C++ reaches it through an `ASSERT_NOT_REACHED`
/// that is compiled out of every shipping build, so this is the *shipping* behaviour reproduced,
/// not the assertion.
private let errorSortPriority = UInt32.max - 1

/// The css-values-4 sort key of a unit: number, then percentage, then dimension by unit ordered
/// ASCII case-insensitively.
///
/// A SECOND, INDEPENDENT SPELLING of `+Serialization.cpp`'s `sortPriority(CSSUnitType)`, which
/// assigns its keys with `__COUNTER__` and which this file used to reach through
/// `swiftSerializationChildIndex`. Two spellings rather than a crossing, for the reason
/// `anchorSizeDimensionValueID` already gives: the differential compares the two arms over every
/// ordered pair of units, so a wrong entry here is a test failure rather than a silently
/// mis-ordered stylesheet, and a crossing per child was measured at the whole of the
/// width-dependent serialization gap (notes/calc-c2-serialization-band-and-refutation-0911.md §2).
///
/// The case list is GENERATED from the C++ (`validate/sortpriority-generated.swift.txt`) rather
/// than hand-transcribed, in the C++'s own case order, so the two read as a side-by-side diff.
/// Swift has no `__COUNTER__`, so the keys are literal -- which is exactly why the exhaustive
/// pair differential is the oracle for this function and `calccheck` alone is not.
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

    // Non-numeric types are not supported. `default` rather than naming the five: an imported C++
    // scoped enum's `init?(rawValue:)` accepts any value of the underlying type, so a raw byte
    // outside the enum has to land somewhere, and the C++'s shipping answer for it is this.
    default: return errorSortPriority
    }
}

/// The sort key of `node`'s `index`th child: the unit priority in the high 32 bits and the tree
/// position in the low 32.
///
/// Ascending integer order on this key IS the stable sort by priority that steps 6 and 7 ask for --
/// equal priorities fall back to the tree position, which is what "stable" means. So there is no
/// comparator, no `sort(by:)` and no stability argument to get wrong; `std::ranges::stable_sort`'s
/// guarantee is encoded in the key instead of relied on.
@inline(always)
private func sortKey(_ node: borrowing WebCore.CSSCalc.Child, _ index: Int) -> UInt64 {
    let info = WebCore.CSSCalc.swiftNodeInfo(node[index])
    var priority = otherSortPriority
    switch info.kind {
    case .Number, .Percentage, .CanonicalDimension, .NonCanonicalDimension:
        // `sortPriority(const Child&)`'s `[]<Numeric T>` arm is exactly these four alternatives,
        // and `toCSSUnit(leaf)` is exactly the byte `swiftNodeInfo` reports as `unitType`. Every
        // other alternative -- including `Symbol`, which carries a unit but is not `Numeric` --
        // takes the generic arm and sorts after everything.
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
    return Int(key & 0xFFFF_FFFF)
}

/// Fill `keys` with `node`'s children's sort keys, in serialization order.
///
/// One pass to build the keys, then an insertion sort in place. Insertion sort rather than
/// `MutableSpan.sort()`: the counts here are a `Sum`'s operands -- 1.9 nodes on the real captured
/// payload, 13 on the widest synthetic band -- and an insertion sort over an already-sorted input,
/// which is what a hand-written `calc()` usually is, is a single comparison per element.
///
/// The buffer is `withTemporaryAllocation` (SE-0524) rather than any owned container, for the
/// reason `withCalcFlatTree` gives at length in CSSCalcSimplificationSwift.swift: a per-call heap
/// buffer costs more than the pass it feeds, and an `Array` here would be a refcounted allocation
/// per operator node. It is sized to the child count, so `Builtin.stackAlloc` handles everything
/// under 128 children and only a wider node than that reaches `malloc` -- against the C++'s
/// `Vector<ChildRepresentation, 16>`, which heap-allocates above 16 children ON EVERY ACCESS.
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
        // The count is checked against `swiftOperationInfo` in `walk`, which is where the record that
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
/// First, the count has to agree with the record: `swiftOperationInfo` says whether the
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
    _ node: borrowing WebCore.CSSCalc.Child,
    _ info: WebCore.CSSCalc.CSSCalcSwiftNodeInfo
) -> Bool {
    let operation = WebCore.CSSCalc.swiftOperationInfo(node)

    var expected: UInt32 = operation.hasFallback ? 1 : 0
    if info.kind == .AnchorFunction && !operation.anchorSideIsKeyword {
        expected += 1
    }
    if expected != info.childCount {
        return false
    }

    var index: UInt32 = 0
    while index < info.childCount {
        let childInfo = WebCore.CSSCalc.swiftNodeInfo(node[Int(index)])
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
/// this runs. An explicit worklist would need a Swift container of a non-copyable borrowed
/// element, and no standard container holds a borrow.
///
/// TREE ORDER, not serialization order, and that is a property of what this function computes
/// rather than a shortcut: all three of its results -- a sum, a bitwise OR, and an AND over the
/// children -- are commutative, so no permutation can change any of them. It used to descend in
/// serialization order, which cost a `Sum` its whole permutation per child, i.e. n of them per
/// node before a single character was appended.
private func walk(
    _ node: borrowing WebCore.CSSCalc.Child,
    _ nodeCount: inout UInt32,
    _ kindMask: inout UInt32
) -> Bool {
    // One crossing per node, not five: `swiftNodeInfo` answers the kind, the child count and every POD
    // payload together, because they all come off the same variant discriminant.
    let info = WebCore.CSSCalc.swiftNodeInfo(node)
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
        if !walk(node[Int(index)], &nodeCount, &kindMask) {
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
    /// because `Stage` lives on `CSSCalc::Tree` and what this file is handed is a `Child`.
    let isComputedStage: Bool
    /// `state.range.min` and `state.range.max`.
    let rangeMinimum: Double
    let rangeMaximum: Double

    /// `clampValue` (`+Serialization.cpp:272`): NaN becomes 0, then `std::clamp`.
    ///
    /// Spelled as the ternary `std::clamp` is specified to be, not as `min(max(value, lo), hi)`,
    /// which is a different function whenever `lo > hi`: `std::clamp` returns `lo` there and the
    /// nested form returns `hi`. A `CSS::Range` with `min > max` is not something the parser builds
    /// today, but this avoids introducing a divergence via a rewrite that looks equivalent but is not.
    ///
    /// `Double.isNaN` and `<` are IEEE on both sides, so `-0.0` and the two infinities match the C++
    /// exactly: `-0.0 < -inf` is false and `inf < -0.0` is false, so `-0.0` passes through against the
    /// default range and serializes as `-0`, exactly as the C++ does.
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
            // `Deg2Rad` has no CSS-level representation, so serialize the child in this node's place --
            // including inheriting this node's grouping parenthesis, which is what
            // `serializeCalculationTree(IndirectNode<Deg2Rad>)` does by passing `state` through
            // unchanged (`+Serialization.cpp:762`).
            serializeCalculationTree(node[0], includingGroupingParenthesis: includeGrouping, &sink)

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
    func serializeMathFunctionCall(
        _ node: borrowing WebCore.CSSCalc.Child,
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
                serializeCalculationTree(node[0], includingGroupingParenthesis: false, &sink)
            }
            while index < info.childCount {
                if index > 0 {
                    sink.appendLiteral(CSSCalcSwiftLiteral.commaSpace.rawValue)
                }
                serializeCalculationTree(node[Int(index)], includingGroupingParenthesis: false, &sink)
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

        // `min`, `max`, and the optional `step`. The walk has already established the count is 2 or 3.
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
    /// Mirrors `serializeMathFunctionArguments(IndirectNode<CalcMix>)` (`+Serialization.cpp:466`). One
    /// child per item, in item order, each optionally followed by its weight.
    ///
    /// The weight upcall writes its own leading space, and writes nothing when the item has none, so
    /// this loop has no presence test of its own; `CSSCalcSwiftOperationInfo` records why that check
    /// stays in C++.
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
    /// Mirrors `serializeMathFunctionArguments(IndirectNode<Anchor>)` (`+Serialization.cpp:478`).
    ///
    /// Both subtree arguments go through `serializeWithoutOmittingPrefix` rather than
    /// `serializeCalculationTree`, which is the C++'s own comment: "as anchor() is not actually a math
    /// function, calc() can't be omitted in arguments". `walk` has already established that every one
    /// of them is serializable in ROOT position, which is the narrower condition that routing implies.
    func serializeAnchorArguments(
        _ node: borrowing WebCore.CSSCalc.Child,
        _ sink: inout WebCore.CSSCalc.CSSCalcSwiftSink
    ) {
        let operation = WebCore.CSSCalc.swiftOperationInfo(node)

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
            serializeWithoutOmittingPrefix(node[0], &sink)
            fallbackIndex = 1
        }

        if operation.hasFallback {
            sink.appendLiteral(CSSCalcSwiftLiteral.commaSpace.rawValue)
            serializeWithoutOmittingPrefix(node[Int(fallbackIndex)], &sink)
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

    /// `serializeWithoutOmittingPrefix` (`+Serialization.cpp:568`): a leaf serializes as itself, and
    /// anything else serializes as a MATH FUNCTION -- so a `Sum` argument of `anchor()` comes out as
    /// `calc(1px + 1em)` and not as `1px + 1em`.
    ///
    /// Reuses `serializeMathFunction`, whose `default` traps; that is safe only because `walk` already
    /// declined any `anchor()` whose arguments are not serializable in root position. The two are one
    /// mechanism and neither is correct without the other.
    @inline(always)
    func serializeWithoutOmittingPrefix(
        _ node: borrowing WebCore.CSSCalc.Child,
        _ sink: inout WebCore.CSSCalc.CSSCalcSwiftSink
    ) {
        let info = WebCore.CSSCalc.swiftNodeInfo(node)
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
    /// "Sort root's children" is step 6's first clause, and `fillSortedChildOrder` is it: one key
    /// per child, sorted once, then read in order. The permutation is alive only inside the
    /// `withTemporaryAllocation` scope, so nothing owns it and nothing outlives the node.
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

            // - Serialize root's first child. Every child below is serialized WITH its grouping
            //   parenthesis, which is `ParenthesisSaver`'s only job in the C++: the Omit that a
            //   math-function wrapper installed applies to this node and not to its children.
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
    /// A `borrowing` PARAMETER rather than a `let` in the loop above, and that is the whole reason
    /// this is a function: `Child` is non-copyable, so `let child = node[i]` is a consume of a
    /// borrow and does not compile, and Swift has no borrowing local binding to spell instead
    /// (toolchain filings section 49). A parameter is one, and a subscript in argument position is
    /// the shape `calcDescendToOrigin` has shipped since R144. No closure, so no `partial_apply`.
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
    }

    /// Step 7, the Product node. Same shape as step 6 with `Invert`/` / `/` * ` in place of
    /// `Negate`/` - `/` + `, and with no negative-value case -- a Product does not rewrite a negative
    /// child, which is why this is not one function with a flag.
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

    /// One later term of a `Product`. A `borrowing` parameter for the reason `serializeSumTerm`
    /// gives.
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

    /// https://drafts.csswg.org/css-values-4/#serialize-a-math-function
    ///
    /// Mirrors CSSCalcTree+Serialization.cpp's `serializeMathFunction` overloads. The `calc(` wrapper
    /// and the grouping-parenthesis Omit are the same step 3/4 pair for every kind here, except the
    /// last: `sibling-count()` and `sibling-index()` take NO `calc(` wrapper, because their
    /// `serializeMathFunction` overloads defer straight to the calculation-tree serializer
    /// (`:320`-`:328`). Both spellings parse, so only a dedicated test catches the difference.
    ///
    /// The only function here that reads the stage, matching the C++ shape: `state.stage` is tested
    /// in exactly one place in the whole 1,300-line serializer (`+Serialization.cpp:289`), inside
    /// `template<Numeric Op> serializeMathFunction`. A `Sum`, a `Symbol`, a `sibling-count()` or a
    /// math function at the `Computed` stage serializes byte for byte as it does at `Specified`.
    @inline(always)
    func serializeMathFunction(
        _ node: borrowing WebCore.CSSCalc.Child,
        _ info: WebCore.CSSCalc.CSSCalcSwiftNodeInfo,
        _ sink: inout WebCore.CSSCalc.CSSCalcSwiftSink
    ) {
        switch info.kind {
        case .Number, .Percentage, .CanonicalDimension, .NonCanonicalDimension:
            // 1. If the root is a numeric value and the serialization is of a computed value or
            //    later, clamp the value to the range allowed for its context, then serialize it as
            //    normal -- WITH NO `calc(` WRAPPER, because step 1 returns before step 3 builds one.
            //    Both spellings reparse to the same value, so `1px` and `calc(1px)` differ only in
            //    `cssText`.
            //
            //    The C++ rebuilds the leaf through `makeChildWithValueBasedOn` and re-enters
            //    `serializeCalculationTree`, but that construction is not needed here:
            //    `makeChildWithValueBasedOn` copies the `hint`, the `dimension` and the `unit` and
            //    replaces only the value (`CSSCalcTree.cpp:311`-`:329`), so `toCSSUnit` of the
            //    rebuilt leaf is `toCSSUnit` of this one, and the whole of the re-entry is the
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
            // path, the last two because this file does not serialize them anywhere. See
            // `isSerializableRoot`.
            preconditionFailure("the root check admitted a node kind the math-function wrapper cannot emit")
        }
    }
}

/// Entry point: serialize a whole tree, or decline.
///
/// `isComputedStage`, `rangeMinimum` and `rangeMaximum` come from the caller rather than from the
/// tree, because `Stage` lives on `CSSCalc::Tree` and the range lives on `SerializationOptions`,
/// while what this file is handed is a `Child`. Together they are the rest of
/// `SerializationState`; see `CalcSerialization`.
@_expose(Cxx)
public func cssCalcSerializeSwift(
    _ root: borrowing WebCore.CSSCalc.Child,
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
    serialization.serializeMathFunction(root, rootInfo, &sink)

    return WebCore.CSSCalc.CSSCalcSwiftSerializationResult(
        kindMask: kindMask,
        nodeCount: nodeCount,
        outcome: CSSCalcSwiftOutcome.serialized.rawValue
    )
}
