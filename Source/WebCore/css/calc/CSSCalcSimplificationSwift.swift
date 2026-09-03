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

// The CSS unit vocabulary: `CSSUnitType`, and the eleven `constexpr double` conversion constants
// that `canonicalize`'s fourteen arithmetic cases multiply by.
//
// THIS IMPORT IS WHAT MADE `canonicalize` PORTABLE, and the reason it did not exist before is worth
// recording, because the old boundary comment gave "Swift cannot see `CSS::pixelsPerCm`" as a fact
// about the language when it was a fact about the module map. CSSUnits.h really cannot be taken by a
// boundary module -- it is not self-contained -- but the constants can be split out of it exactly as
// `CSSUnitType` already was, and a namespace-scope `constexpr double` imports cleanly. (A `static
// constexpr` DATA MEMBER does not; that is filings register §39, and it is why these were left at
// namespace scope rather than gathered into a struct.) See CSSUnitConversions.h.
//
// `internal`, not `public`: nothing this file exposes names a unit type. A `public` Swift signature
// naming an imported C++ enum is refused outright under library evolution -- "C++ types from
// imported module '__ObjC' do not support library evolution" -- so this is also the only access
// level that compiles.
internal import WebCore_Private.CSSUnitsSwiftTypes

// `degreesPerRadianDouble`, `degreesPerGradientDouble` and `degreesPerTurnDouble`, for the three
// <angle> cases. THE SUBMODULE IS LOAD-BEARING: plain `import wtf` does not see them, because WTF's
// module map declares `explicit module *` under its umbrella, so the members are only visible
// through the submodule that owns the header. Same rule as `Darwin` above -- these ARE the constants
// the C++ arm multiplies by, so the two arms share one definition by construction.
internal import wtf.Core.MathExtras

// libm, and nothing else. `sin`, `cos`, `tan`, `asin`, `acos`, `atan`, `atan2`, `pow`, `log` and
// `exp` are not in the Swift standard library, and the point of taking them from here rather than
// from Foundation is that these ARE the C functions the C++ arm calls -- `std::sin` on Darwin is
// `::sin` -- so "the two arms share one libm" is a construction rather than a claim. Everything
// else the executors need is stdlib and needs no import at all: `squareRoot()`,
// `truncatingRemainder(dividingBy:)`, `rounded(.down)`, `.magnitude` and `.sign` are all IEEE-754
// operations on `Double` with the same semantics as `std::sqrt`, `std::fmod`, `std::floor`,
// `std::abs` and `std::signbit`.
import Darwin

// Swift island for CSS calc() SIMPLIFICATION: a port of CSSCalcTree+Simplification.cpp, selected by
// USE_SWIFT_CSS_CALC_SIMPLIFICATION. Slices A1 and A2 of that port, A2 complete.
//
// WHY THIS IS A SECOND ISLAND ON THE SAME TREE, AND WHAT IT ADDS. The serialization island next
// door only ever READS a tree. This one rewrites it, and the whole boundary question that shaped
// the design is how a node gets CONSTRUCTED without the operation kind crossing. The answer, which
// CSSCalcSwiftTypes.h states at length, is that it never has to: simplification is a tree-to-tree
// rewrite in which the output node's kind is the input node's kind everywhere except one rule, so
// `rebuildFrom` recovers the operation from the ORIGINAL node's own variant tag and the island
// supplies only operands and a count.
//
// WHAT THE ISLAND SIMPLIFIES. Every tree whose every node is one of
//
//   - the four numeric leaves, and `Symbol` at any unit its table resolves to,
//   - `Invert` and `Deg2Rad`, the two implementation-only wrappers,
//   - 21 of the 34 operations that A1 took: `mod`, `rem`, `round` in all four strategies, the six
//     trig functions, `atan2`, `pow`, `sqrt`, `log`, `exp`, `abs`, `sign`, `progress` and
//     `progress(no-clamp ...)`,
//   - and the four A2 took: `hypot()` (A2a), `min()` and `max()` (A2b) and `clamp()` (A2c),
//   - and `Sum` (A2d), which is `+` and, through `Negate`, half of `-`.
//
// Everything else declines, and a decline is a WHOLE-TREE decline: the C++ arm runs and the island's
// operand stack is destroyed unread. That is why this island needs no equivalent of the
// serialization island's "the walk is the decline decision" rule -- a `StringBuilder` cannot be
// un-appended, but a local `Vector<Child>` can simply be dropped.
//
// STILL DECLINED, and each for its own reason: `Product` (whose rules 9.1 and 9.2 merge every
// `Number` factor into one running product -- A3), `Negate` (whose rules 6.2 to 6.4 rewrite a
// *child's* children in place), `CalcMix` (normalisation over per-item weights that are not child
// nodes), `Random`, `Anchor`, `AnchorSize`, `sibling-count()` and `sibling-index()` (all of which need
// `Style::BuilderState` or the anchor evaluator, which the boundary does not carry and this island
// does not ask it to).
//
// WHAT A2 ADDED THAT A1 HAD NO SHAPE FOR: an ARITY CHANGE. A1 rebuilt every unfolded node with
// exactly the children it came in with, so `rebuildSlot(const Children&)` -- which deliberately takes
// all remaining operands and ignores the original's count -- had never executed. `min()`'s merge and
// `hypot()`'s rebuild are the first things in the whole port to run it, and A2d's `Sum` is the first
// to make the count go UP as well as down, because step 8.1 SPLICES a nested `Sum`'s terms into its
// parent. A2 also added the only rewrite that produces a node of a kind that was not in the input,
// `clamp()` collapsing to `min()` or `max()`, which is `buildMinMax`'s first and only caller.
//
// WHAT A2d ADDED BEYOND THAT: an address for a node the parent does not own. `Sum`'s terms are not its
// children -- after 8.1 they are the leaves of a chain of nested `Sum`s, at any depth -- so
// `.replacedBySumTerm` names one by ORDINAL and `pushSumTerm` resolves it by re-walking the identical
// chain. The plan for this slice specified a two-level `(child, grandchild)` address instead, on the
// argument that three levels are impossible; that argument is refuted in `Fold.replacedByTerm` with
// the expression that breaks it, and the ordinal needs no depth argument at all.
//
// THE PUSH IS LAZY, AND THAT IS THE ONE DESIGN DECISION WORTH ARGUING ABOUT. The obvious shape for a
// post-order rewriter is "simplify each child, push it, then ask the parent to fold" -- and it does
// not work, because the builder is an operand STACK with no pop. A parent that folds `mod(1, 2)`
// into `Number(1)` would leave its two children stranded on the stack under the answer, and the
// entry point's "exactly one operand" contract would fail for every folded tree in the document.
// Adding a `discard(n)` to the boundary was the alternative and it was rejected: it is C++ written
// to facilitate Swift, and it is not needed. A1's version of that argument was "every fold requires
// every child to have folded to a numeric leaf first"; A2 breaks that premise -- `min(r, 1px)` keeps
// an unresolved `Symbol` as a survivor, and `clamp(none, r, 1px)` rebuilds as a `min()` over two
// subtrees -- and the answer is still not a `pop`, because `Fold` grew three cases that say what
// `rewrite` must push instead. So the island splits the work in two:
//
//   - `fold(_:_:)` decides what a subtree collapses to, PUSHING NOTHING. It is pure apart from the
//     two `const` lookups on the builder, and it allocates nothing on the C++ side either, so a
//     subtree that folds away never causes a `makeChild` at all.
//   - `rewrite(_:_:)` pushes exactly one operand: the folded leaf if there is one, otherwise its
//     children's operands followed by `rebuildFrom`.
//
// The cost is that `fold` is re-entered once per level, so a node at depth d is folded d+1 times --
// and for a merged `Min`/`Max` the merge plan is computed twice, once in `fold` to learn the arity
// and once in `rewrite` to push the survivors. Priced rather than assumed, and on the same evidence
// `childAt`'s linear scan was priced on: a calc expression's tree is a handful of nodes, the deepest
// in the whole WPT css-values corpus is single digits, and `childInTreeOrder` is already linear per
// access so the walk is quadratic before this file adds anything. If a measurement finds it, the fix
// is for `fold` to hand its per-child results down to `rewrite` rather than a boundary change. The
// alternative considered for A2 -- having `.mergedChildren` CARRY the survivor list -- was rejected
// for now because the list is dynamically sized, so it would put a heap allocation on a `Fold` value
// that is constructed for every node at every level, where the common case allocates nothing.
//
// THE ARITHMETIC IS PORTED, NOT UPCALLED, and that is the opposite of the choice the serialization
// island made for number FORMATTING. The two are different problems. `formatCSSNumberValue` is a
// CSS-specific algorithm with no Swift equivalent, so a reimplementation would agree on every common
// value and diverge on subnormals; `std::fmod` and `std::sin` are libm, and Swift reaches the SAME
// libm. So porting them introduces no second implementation of anything -- `Double`'s IEEE
// operations and `Darwin`'s transcendentals are the identical machine instructions and the identical
// library calls -- while an upcall would have been ~30 lines of C++ written purely to let Swift do
// arithmetic. Every executor below names the C++ expression it reproduces at its site, and the four
// places where the correspondence rests on something subtler than "same libm call" say so.
//
// NO `unsafe`, AND IT IS THE BOUNDARY THAT BUYS IT, exactly as next door: the tree crosses as a
// borrowed `~Escapable` handle and the output crosses as a `SWIFT_SAFE` builder taken `inout`.
// Nothing in this file can see a pointer, so there is no marker to justify.

/// What the island did with a tree.
///
/// `@c` (SE-0495) makes this the single declaration of the numbering: it is emitted into
/// WebCoreSwift-Generated.h and `static_assert`ed against these names in
/// CSSCalcTree+Simplification.cpp, so reordering these cases is a build failure there rather than a
/// silent reinterpretation -- `declined` read as `simplified` would install an EMPTY operand stack
/// as the tree.
///
/// Internal rather than `public`, for the reason CSSCalcSerializationSwift.swift:139 gives: `@c` on
/// a *resilient* enum crashes IRGen and WebCore compiles with library evolution, and the generated
/// header is emitted at `-emit-clang-header-min-access internal` so nothing is lost.
@c
enum CSSCalcSwiftSimplificationOutcome: UInt8 {
    /// The island built the complete simplified tree on the builder's operand stack.
    case simplified = 0
    /// The island built nothing usable; the caller must run the C++ simplifier.
    case declined = 1
}

// MARK: - The per-alternative discriminant

// WHY THE ISLAND DISPATCHES ON `CSSCalcSwiftAlternative` AND NOT ON `CSSCalcSwiftNodeKind`.
//
// The 23-case `kind` classifies a node by the SHAPE of its serialization, which is exactly what the
// serialization island needs and is not enough for a rewriter: `min()` and `mod()` are both
// `CSSCalcSwiftNodeKind.Function`, and A1 folds one and declines the other. `kind` plus `valueID`
// does not close the gap either, because a Swift file CANNOT NAME a `CSSValueID`. That was measured
// rather than assumed, with a control that fails:
//
//     ~/src/webkit-swift-ports/cssprobe/calcsimplify/valueidprobe.swift
//     "error: type 'WebCore' has no member 'CSSValueSin'"
//
// CSSValueKeywords.h is inside the `Core` umbrella that no island may import, and unlike
// CSSUnitType.h it cannot be split into a module of its own, because it is not self-contained: it
// includes <wtf/HashFunctions.h> and <wtf/HashTraits.h>. Comparing against the raw numbers instead
// would put a slice of a GENERATED keyword table into Swift, which is the one thing this port counts
// as goop by name.
//
// So the boundary carries the variant's own alternative index, and the island imports that enum
// rather than mirroring it -- 41 cases, pinned to `Node`'s alternative indices with
// `WTF::alternativeIndexV`, and the same numbering `kindMask` and `declineAlternative` are keyed on.

/// `WebCore::CSSCalc::CSSCalcSwiftAlternative`, spelled once.
///
/// A typealias purely for line length: the qualified name appears in nearly every signature below,
/// and this is the same abbreviation the C++ gets for free from `using namespace`.
private typealias CalcAlternative = WebCore.CSSCalc.CSSCalcSwiftAlternative

/// The value `CSSCalcSwiftLeaf.kind` wants for one of the four numeric leaves.
///
/// The two numberings agree today and the agreement is not a coincidence: `CSSCalcSwiftNodeKind`'s
/// first four cases are the four numeric leaves in the same order as `Node`'s first four
/// alternatives, which is what makes this the identity. It is still routed through a function
/// rather than written as `kind.rawValue` at three call sites, because "the two enums happen to
/// agree" is exactly the sort of fact that stops being true in a later slice, and one function is
/// one place to find out.
@inline(always)
private func leafKindRawValue(_ kind: NumericKind) -> UInt8 {
    switch kind {
    case .number:
        return WebCore.CSSCalc.CSSCalcSwiftNodeKind.Number.rawValue
    case .percentage:
        return WebCore.CSSCalc.CSSCalcSwiftNodeKind.Percentage.rawValue
    case .canonicalDimension:
        return WebCore.CSSCalc.CSSCalcSwiftNodeKind.CanonicalDimension.rawValue
    case .nonCanonicalDimension:
        return WebCore.CSSCalc.CSSCalcSwiftNodeKind.NonCanonicalDimension.rawValue
    }
}

// MARK: - The four numeric leaves

/// Which of the four numeric alternatives a folded value is.
///
/// A four-case Swift enum rather than the 41-case discriminant, because every predicate below wants
/// exactly this distinction and switching over 41 cases to answer a four-way question is how a
/// transcription error hides. It is the island's own vocabulary, not a mirror of a C++ table: the
/// one place it meets the boundary is `leafKindRawValue` above.
private enum NumericKind {
    case number
    case percentage
    case canonicalDimension
    case nonCanonicalDimension
}

/// A numeric leaf the island has decided on: everything `makeChildWithValueBasedOn` carries, and
/// nothing else.
///
/// This is the island's answer to a problem the boundary does not have an accessor for. Once Swift
/// has pushed an operand it cannot read it back -- `CSSCalcSwiftBuilder` is a sink -- so a parent
/// cannot ask "did my child simplify to a `<number>`?" the way the C++ asks `get_if<Number>`.
/// It does not need to: Swift PRODUCED every operand, so it already knows. Carrying the answer out
/// of the recursion is exact, costs four registers, and needs no boundary change at all.
///
/// The fields are `makeChildWithValueBasedOn`'s (CSSCalcTree.cpp:311-:329): the same alternative,
/// the same unit, the same percent hint, a new value. A fold that carried anything less would
/// produce a node the C++ arm would not -- dropping a `Percentage`'s `hint` is the specific way
/// that goes wrong, and it is why `CSSCalcSwiftNodeInfo` carries `percentHint` at all.
private struct NumericLeaf {
    let kind: NumericKind
    let value: Double
    /// A `CSSUnitType` underlying value: `toCSSUnit(leaf)` (CSSCalcTree.h:1008-:1011).
    let unitType: UInt16
    /// `Type::PercentHint`'s underlying value, 0 for none. Meaningful only for `.percentage`.
    let percentHint: UInt8

    /// The same leaf with a new value: `makeChildWithValueBasedOn(value, a)`.
    @inline(always)
    func withValue(_ newValue: Double) -> NumericLeaf {
        return NumericLeaf(kind: kind, value: newValue, unitType: unitType, percentHint: percentHint)
    }

    /// A bare `<number>`: `makeChild(Number { .value = value })`.
    ///
    /// The unit is named rather than spelled, from the REAL `CSSUnitType` -- the enum
    /// CSSUnitType.h was split out of CSSUnits.h to be self-contained precisely so an island could
    /// import it instead of mirroring it. `toCSSUnit(const Number&)` is `CSSUnitType::Number`
    /// unconditionally (CSSCalcTree.h:1008), so this is that function and not a guess.
    @inline(always)
    static func number(_ value: Double) -> NumericLeaf {
        return NumericLeaf(
            kind: .number,
            value: value,
            unitType: UInt16(WebCore.CSSUnitType.Number.rawValue),
            percentHint: 0
        )
    }

    /// A canonical `<angle>`: `makeChild(CanonicalDimension { .value = v, .dimension = Angle })`,
    /// which is what the three arc-trig folds and `atan2()` produce.
    ///
    /// `toCSSUnit(Dimension::Angle)` is `CSSUnitType::Deg` (CSSCalcTree.h:996), and `makeNumeric`
    /// maps `Deg` back to `Dimension::Angle` (CSSCalcTree.cpp:202) -- so the round trip through the
    /// boundary's `unitType` is those two functions and `Dimension` never crosses.
    @inline(always)
    static func canonicalAngle(_ value: Double) -> NumericLeaf {
        return NumericLeaf(
            kind: .canonicalDimension,
            value: value,
            unitType: UInt16(WebCore.CSSUnitType.Deg.rawValue),
            percentHint: 0
        )
    }

    /// A canonical `<length>`: `makeChild(CanonicalDimension { .value = v, .dimension = Length })`,
    /// which is `simplify(Sum&)`'s "we removed too much" result (`+Simplification.cpp:663`).
    ///
    /// `toCSSUnit(Dimension::Length)` is `CSSUnitType::Px` (CSSCalcTree.h:993), so this names the real
    /// unit and `makeNumeric` maps it back -- the identical round trip `canonicalAngle` above makes,
    /// and the reason `Dimension` still never crosses the boundary.
    @inline(always)
    static func canonicalLength(_ value: Double) -> NumericLeaf {
        return NumericLeaf(
            kind: .canonicalDimension,
            value: value,
            unitType: UInt16(WebCore.CSSUnitType.Px.rawValue),
            percentHint: 0
        )
    }

    /// What `CSSCalcSwiftBuilder.pushLeaf` takes.
    @inline(always)
    var boundaryLeaf: WebCore.CSSCalc.CSSCalcSwiftLeaf {
        return WebCore.CSSCalc.CSSCalcSwiftLeaf(
            value: value,
            unitType: unitType,
            kind: leafKindRawValue(kind),
            percentHint: percentHint
        )
    }
}

// MARK: - The arithmetic
//
// A port of `CSSCalcExecutor.h`'s `OperatorExecutor<Operator::X>` specializations, one static
// function each, in the header's own order. A caseless `enum` as a namespace, so there is no
// instance and no storage.
//
// Two spellings recur and both are deliberate:
//
//   - `x == 0` for the C++ `!x` on a double. `!x` is `x == 0`, which is TRUE for both `+0` and `-0`
//     and FALSE for a NaN, and `== 0` is exactly that. `x.isZero` would also be exact;
//     `x.magnitude < .leastNormalMagnitude` would not.
//   - `x.sign == .minus` for `std::signbit(x)`. Both read the sign BIT, so both are true for `-0.0`
//     and for a negative NaN, where `x < 0` is false for either. Getting this one wrong is the
//     specific way a signed-zero port goes wrong, and `CSSCalcTree+Simplification.cpp:917`-`:919`
//     records that the C++ chose unary negation over `0 - value` for the same reason.
private enum CalcExecutor {

    /// `deg2rad` (wtf/MathExtras.h:96), i.e. `d * radiansPerDegreeDouble` where
    /// `radiansPerDegreeDouble` is `std::numbers::pi / 180.0` (`:87`).
    ///
    /// Written as the parenthesised constant expression rather than as a `static let`, so that it is
    /// a compile-time fold like the C++ `constexpr` and not a lazily-initialised global behind a
    /// `swift_once`. `Double.pi` and `std::numbers::pi` are the same IEEE double, and one
    /// correctly-rounded division of the same operands gives the same result on both sides.
    @inline(always)
    static func degreesToRadians(_ degrees: Double) -> Double {
        return degrees * (Double.pi / 180.0)
    }

    /// `rad2deg` (wtf/MathExtras.h:97), i.e. `r * degreesPerRadianDouble` = `r * (180.0 / pi)`.
    @inline(always)
    static func radiansToDegrees(_ radians: Double) -> Double {
        return radians * (180.0 / Double.pi)
    }

    /// `getNearestMultiples` (CSSCalcExecutor.h:49-:57).
    @inline(always)
    static func nearestMultiples(_ a: Double, _ b: Double) -> (lower: Double, upper: Double) {
        // `if (!std::fmod(a, b)) return { a, a };`
        if a.truncatingRemainder(dividingBy: b) == 0 {
            return (a, a)
        }
        // `double lower = std::floor(a / std::abs(b)) * std::abs(b); double upper = lower + std::abs(b);`
        let interval = b.magnitude
        let lower = (a / interval).rounded(.down) * interval
        return (lower, lower + interval)
    }

    /// `minWithSignedZero` (CSSCalcExecutor.h:61-:66).
    ///
    /// `std::min(a, b)` is specified as `b < a ? b : a`, and it is spelled out rather than written
    /// as `Swift.min` for one reason: `Double.minimum(_:_:)` sits next to it in the stdlib, is the
    /// IEEE-754 NaN-quieting operation, and is DIFFERENT for a NaN operand. `std::min(1, NaN)` is
    /// `1`, `std::min(NaN, 1)` is `NaN`, and the ternary below reproduces both; `Double.minimum`
    /// returns `1` for either.
    @inline(always)
    static func minWithSignedZero(_ a: Double, _ b: Double) -> Double {
        if a == b {
            return a.sign == .minus ? a : b
        }
        return b < a ? b : a
    }

    /// `maxWithSignedZero` (CSSCalcExecutor.h:68-:73). `std::max(a, b)` is `a < b ? b : a`.
    @inline(always)
    static func maxWithSignedZero(_ a: Double, _ b: Double) -> Double {
        if a == b {
            return a.sign == .minus ? b : a
        }
        return a < b ? b : a
    }

    /// `OperatorExecutor<Operator::Invert>` (CSSCalcExecutor.h:127-:132), and equally
    /// `simplify(Invert&)`'s own `(1.0 / a.value)` at CSSCalcTree+Simplification.cpp:972.
    @inline(always)
    static func invert(_ a: Double) -> Double {
        return 1.0 / a
    }

    /// `OperatorExecutor<Operator::Sum>`'s two-`double` overload (CSSCalcExecutor.h:94-:97): `a + b`.
    ///
    /// The whole executor, and there is nothing hiding in it: no NaN check, no signed-zero helper,
    /// no range. IEEE-754 addition is the same operation in both languages, so `simplify(Sum&)`'s
    /// merge agrees on `NaN`, on `±0` (`+0 + -0` is `+0` on both) and on the infinities by
    /// construction. What does NOT come for free is the ORDER: `+` is not associative, so
    /// `calc(1e300px + 1px + -1e300px)` depends on the per-bucket accumulation order, and
    /// `sumMergePlan` accumulates in term index order for exactly that reason.
    @inline(always)
    static func sum(_ a: Double, _ b: Double) -> Double {
        return a + b
    }

    /// `OperatorExecutor<Operator::Min>`'s TWO-`double` overload (CSSCalcExecutor.h:155-:161).
    ///
    /// NOT `minWithSignedZero`, AND THIS IS THE MOST DANGEROUS TRANSCRIPTION IN THE FILE. The helper
    /// sits right above and is documented at length, so calling it from `min()`'s merge is the obvious
    /// move and it is wrong: the executor short-circuits BOTH operands for NaN before reaching the
    /// helper, and the helper does not. `std::min(1, NaN)` -- which is what the helper reproduces --
    /// is `1`, while `OperatorExecutor<Operator::Min>{}(1, NaN)` is `NaN`. So a `min(1px, calc(NaN *
    /// 1px))` routed through the helper folds to `1px` where the C++ gives `NaN`.
    ///
    /// The parameter names are the C++'s (`val`, `min`), and the ORDER MATTERS for exactly that
    /// reason: with both short-circuits the first NaN operand wins, so this is not commutative in the
    /// bit pattern it returns even though it is in `isnan`. Every caller passes (accumulator, new) or
    /// (val, max) to match its own C++ site.
    @inline(always)
    static func min(_ val: Double, _ minimum: Double) -> Double {
        if val.isNaN {
            return val
        }
        if minimum.isNaN {
            return minimum
        }
        return minWithSignedZero(val, minimum)
    }

    /// `OperatorExecutor<Operator::Max>`'s two-`double` overload (CSSCalcExecutor.h:190-:196), which
    /// is `min` above with the helper swapped. See its note: the two NaN short-circuits are the whole
    /// difference from `maxWithSignedZero` and they are not optional.
    @inline(always)
    static func max(_ val: Double, _ maximum: Double) -> Double {
        if val.isNaN {
            return val
        }
        if maximum.isNaN {
            return maximum
        }
        return maxWithSignedZero(val, maximum)
    }

    /// `OperatorExecutor<Operator::Clamp>`'s three-`double` overload (CSSCalcExecutor.h:206-:214).
    ///
    /// Two callers, and they are two different C++ sites: `progress()`
    /// (`+Simplification.cpp:1403`-`:1443`, which calls `executeOperation<Operator::Clamp>` itself)
    /// and A2c's `clamp()` with neither bound `none` (`:1098`). Written as the real executor rather
    /// than inlined at either site, because both C++ sites go through it and the three must not drift.
    ///
    /// It calls the two HELPERS and not `min`/`max` above, which is not an inconsistency: the C++
    /// executor for `Clamp` calls `maxWithSignedZero`/`minWithSignedZero` directly after its own
    /// three-way NaN check, and does NOT go through `OperatorExecutor<Operator::Min>`. Reproducing
    /// that structure is what makes `clamp(-0, +0, +0)` agree.
    @inline(always)
    static func clamp(_ minimum: Double, _ value: Double, _ maximum: Double) -> Double {
        if minimum.isNaN || value.isNaN || maximum.isNaN {
            return Double.nan
        }
        return maxWithSignedZero(minimum, minWithSignedZero(value, maximum))
    }

    /// `OperatorExecutor<Operator::RoundNearest>` (CSSCalcExecutor.h:237-:250).
    @inline(always)
    static func roundNearest(_ valueToRound: Double, _ roundingInterval: Double) -> Double {
        // `if (!std::isinf(valueToRound) && std::isinf(roundingInterval)) return std::signbit(valueToRound) ? -0.0 : +0.0;`
        if !valueToRound.isInfinite && roundingInterval.isInfinite {
            return valueToRound.sign == .minus ? -0.0 : 0.0
        }
        let (lower, upper) = nearestMultiples(valueToRound, roundingInterval)
        // `return std::abs(upper - valueToRound) <= std::abs(roundingInterval) / 2 ? upper : lower;`
        return (upper - valueToRound).magnitude <= roundingInterval.magnitude / 2 ? upper : lower
    }

    /// `OperatorExecutor<Operator::RoundUp>` (CSSCalcExecutor.h:252-:267).
    @inline(always)
    static func roundUp(_ valueToRound: Double, _ roundingInterval: Double) -> Double {
        if !valueToRound.isInfinite && roundingInterval.isInfinite {
            // `if (!valueToRound) return valueToRound;` -- returns the ZERO ITSELF, so `-0` stays
            // `-0`, which the `+0.0` literal below would not preserve.
            if valueToRound == 0 {
                return valueToRound
            }
            return valueToRound.sign == .minus ? -0.0 : Double.infinity
        }
        return nearestMultiples(valueToRound, roundingInterval).upper
    }

    /// `OperatorExecutor<Operator::RoundDown>` (CSSCalcExecutor.h:269-:284).
    @inline(always)
    static func roundDown(_ valueToRound: Double, _ roundingInterval: Double) -> Double {
        if !valueToRound.isInfinite && roundingInterval.isInfinite {
            if valueToRound == 0 {
                return valueToRound
            }
            return valueToRound.sign == .minus ? -Double.infinity : 0.0
        }
        return nearestMultiples(valueToRound, roundingInterval).lower
    }

    /// `OperatorExecutor<Operator::RoundToZero>` (CSSCalcExecutor.h:286-:299).
    @inline(always)
    static func roundToZero(_ valueToRound: Double, _ roundingInterval: Double) -> Double {
        if !valueToRound.isInfinite && roundingInterval.isInfinite {
            return valueToRound.sign == .minus ? -0.0 : 0.0
        }
        let (lower, upper) = nearestMultiples(valueToRound, roundingInterval)
        // `return std::abs(upper) < std::abs(lower) ? upper : lower;`
        return upper.magnitude < lower.magnitude ? upper : lower
    }

    /// `OperatorExecutor<Operator::Mod>` (CSSCalcExecutor.h:301-:321).
    @inline(always)
    static func mod(_ a: Double, _ b: Double) -> Double {
        // "In mod(A, B) only, if B is infinite and A has opposite sign to B (including an
        // oppositely-signed zero), the result is NaN." https://drafts.csswg.org/css-values/#round-infinities
        if b.isInfinite && (a.sign == .minus) != (b.sign == .minus) {
            return Double.nan
        }
        var result = a.truncatingRemainder(dividingBy: b)
        // "A zero remainder takes the sign of B", rather than the sign `std::fmod` inherits from A.
        if result == 0 {
            return b.sign == .minus ? -0.0 : 0.0
        }
        // "If the result is on opposite side of zero from B, put it between 0 and B."
        if (result.sign == .minus) != (b.sign == .minus) {
            result += b
        }
        return result
    }

    /// `OperatorExecutor<Operator::Rem>` (CSSCalcExecutor.h:323-:330).
    @inline(always)
    static func rem(_ a: Double, _ b: Double) -> Double {
        if b == 0 {
            return Double.nan
        }
        return a.truncatingRemainder(dividingBy: b)
    }

    /// `OperatorExecutor<Operator::Sin>` (CSSCalcExecutor.h:332-:337): `std::sin(a)`.
    @inline(always)
    static func sin(_ a: Double) -> Double {
        return Darwin.sin(a)
    }

    /// `OperatorExecutor<Operator::Cos>` (CSSCalcExecutor.h:339-:344): `std::cos(a)`.
    @inline(always)
    static func cos(_ a: Double) -> Double {
        return Darwin.cos(a)
    }

    /// `OperatorExecutor<Operator::Tan>` (CSSCalcExecutor.h:346-:360).
    ///
    /// The two poles are named exactly rather than approached, which is the whole content of this
    /// executor: `tan()` at `90deg` is `infinity` per css-values-4 and libm's `tan` is merely very
    /// large there. The comparisons are `==` against the same two constants the C++ compares
    /// against -- `piOverTwoDouble` is `std::numbers::pi / 2` (wtf/MathExtras.h:53) -- so the
    /// reduction has to produce a bit-identical `x` for them to fire, which is why the expressions
    /// below are the C++'s operand for operand rather than an algebraically equal rewrite.
    ///
    /// The C++'s two `ASSERT`s on the reduced range are not reproduced: both are compiled out of
    /// every shipping build, and neither has a behaviour to reproduce.
    @inline(always)
    static func tan(_ a: Double) -> Double {
        let fullTurn = Double.pi * 2
        // `double x = std::fmod(a, std::numbers::pi * 2);`
        var x = a.truncatingRemainder(dividingBy: fullTurn)
        // `x = x < 0 ? std::numbers::pi * 2 + x : x;` -- `std::fmod` can return negative values.
        x = x < 0 ? fullTurn + x : x
        if x == Double.pi / 2 {
            return Double.infinity
        }
        if x == 3 * (Double.pi / 2) {
            return -Double.infinity
        }
        return Darwin.tan(x)
    }

    /// `OperatorExecutor<Operator::Asin>` (CSSCalcExecutor.h:362-:367): `rad2deg(std::asin(a))`.
    @inline(always)
    static func asin(_ a: Double) -> Double {
        return radiansToDegrees(Darwin.asin(a))
    }

    /// `OperatorExecutor<Operator::Acos>` (CSSCalcExecutor.h:369-:374): `rad2deg(std::acos(a))`.
    @inline(always)
    static func acos(_ a: Double) -> Double {
        return radiansToDegrees(Darwin.acos(a))
    }

    /// `OperatorExecutor<Operator::Atan>` (CSSCalcExecutor.h:376-:381): `rad2deg(std::atan(a))`.
    @inline(always)
    static func atan(_ a: Double) -> Double {
        return radiansToDegrees(Darwin.atan(a))
    }

    /// `OperatorExecutor<Operator::Atan2>` (CSSCalcExecutor.h:383-:388): `rad2deg(atan2(a, b))`.
    @inline(always)
    static func atan2(_ a: Double, _ b: Double) -> Double {
        return radiansToDegrees(Darwin.atan2(a, b))
    }

    /// `OperatorExecutor<Operator::Pow>` (CSSCalcExecutor.h:390-:395): `std::pow(a, b)`.
    @inline(always)
    static func pow(_ a: Double, _ b: Double) -> Double {
        return Darwin.pow(a, b)
    }

    /// `OperatorExecutor<Operator::Sqrt>` (CSSCalcExecutor.h:397-:402): `std::sqrt(a)`.
    ///
    /// `squareRoot()` rather than `Darwin.sqrt`, because it is the IEEE-754 `squareRoot` operation
    /// and lowers to the same `fsqrt` instruction `std::sqrt` does -- correctly rounded, so there is
    /// no libm implementation to agree with in the first place.
    @inline(always)
    static func sqrt(_ a: Double) -> Double {
        return a.squareRoot()
    }

    /// `OperatorExecutor<Operator::Log>`'s one-argument overload (CSSCalcExecutor.h:425-:428).
    @inline(always)
    static func log(_ a: Double) -> Double {
        return Darwin.log(a)
    }

    /// `OperatorExecutor<Operator::Log>`'s two-argument overload (CSSCalcExecutor.h:430-:433):
    /// `std::log(a) / std::log(b)`, and NOT `log(a) / log(b)` reassociated or `logb`-based -- the
    /// two divisions differ in the last place for many inputs.
    @inline(always)
    static func log(_ a: Double, _ b: Double) -> Double {
        return Darwin.log(a) / Darwin.log(b)
    }

    /// `OperatorExecutor<Operator::Exp>` (CSSCalcExecutor.h:443-:448): `std::exp(a)`.
    @inline(always)
    static func exp(_ a: Double) -> Double {
        return Darwin.exp(a)
    }

    /// `OperatorExecutor<Operator::Abs>` (CSSCalcExecutor.h:450-:455): `std::abs(a)`.
    ///
    /// `.magnitude` is `fabs`: it clears the sign bit, so `-0` becomes `+0` and a negative NaN
    /// becomes a positive NaN, which is what `std::abs(double)` does too.
    @inline(always)
    static func abs(_ a: Double) -> Double {
        return a.magnitude
    }

    /// `OperatorExecutor<Operator::Sign>` (CSSCalcExecutor.h:457-:466).
    ///
    /// The final `return a` is load-bearing and is why this is not `a.sign`: it returns the operand
    /// ITSELF for anything that is neither greater nor less than zero, so `sign(-0)` is `-0`,
    /// `sign(+0)` is `+0` and `sign(NaN)` is `NaN`.
    @inline(always)
    static func sign(_ a: Double) -> Double {
        if a > 0 {
            return 1
        }
        if a < 0 {
            return -1
        }
        return a
    }

    /// `OperatorExecutor<Operator::Progress>` (CSSCalcExecutor.h:468-:475).
    @inline(always)
    static func progress(_ progress: Double, _ from: Double, _ to: Double) -> Double {
        if from == to {
            return 0.0
        }
        return clamp(0.0, (progress - from) / (to - from), 1.0)
    }

    /// `OperatorExecutor<Operator::ProgressNoClamp>` (CSSCalcExecutor.h:477-:489).
    @inline(always)
    static func progressNoClamp(_ progress: Double, _ from: Double, _ to: Double) -> Double {
        if from == to {
            if progress < from {
                return -Double.infinity
            }
            if progress > from {
                return Double.infinity
            }
            return 0.0
        }
        return (progress - from) / (to - from)
    }
}

// MARK: - What a subtree folded to

/// The result of folding one subtree, which is `copyAndSimplify`'s `std::optional<Child>` plus the
/// island's decline channel.
///
/// THE INVARIANT THE WHOLE FILE RESTS ON: `.leaf` holds exactly when the C++'s `simplify` produced
/// one of the four `Numeric` alternatives, and every other case holds exactly when it did not. Every
/// operand predicate below is a test for `.leaf`, and each is a transcription of a C++ `switchOn` arm
/// that fires only for a `Numeric`, so the two agree case by case. A2's three new cases preserve it
/// rather than weaken it, and each says how at its own declaration -- the interesting one is
/// `.replacedByTerm`, which is never produced when the promoted term IS a leaf.
private enum Fold {
    /// `simplify` returned a replacement, and the replacement is a numeric leaf.
    ///
    /// NOTHING HAS BEEN PUSHED. The caller either uses the value or pushes the leaf itself.
    case leaf(NumericLeaf)
    /// `simplify` returned `std::nullopt`: the node keeps its own kind and is rebuilt from its
    /// simplified children WITH THE SAME ARITY. Carries the node's alternative, which `foldInvert`
    /// needs and which the caller would otherwise pay a second `info()` crossing for.
    case unchanged(CalcAlternative)
    /// The node collapses to one of its own children, unfolded: `return { WTF::move(root.children[i])
    /// }` at `+Simplification.cpp:409`, `:456` and `:1015`. `rewrite` pushes that subtree's operand
    /// and nothing else, which is exactly one operand, so the parent's count is unaffected.
    ///
    /// ONE LEVEL, AND IT STAYS ONE LEVEL -- which is a CORRECTION to the plan for A2d, recorded here
    /// because that plan's reasoning was checked against the C++ and found wrong.
    /// `cssprobe/calcsimplify/A2-PLAN.md` §1.0 specified this case as
    /// `(child: UInt32, grandchild: UInt32?)`, on the argument that `Sum`'s step 8.1 splices a child
    /// `Sum`'s children into the parent so a survivor can be a grandchild, and that it "is never three
    /// levels: after 8.1 no direct term of the sum is itself a `Sum`". The first half is right; the
    /// second confuses "a spliced term is not itself spliceable" with "a spliced term is a
    /// grandchild". `calc(1px + (1em + (1rem + 1vw)))` with no conversion data flattens TWICE -- the
    /// innermost `Sum` survives its own pass as a `Sum` (two terms, two units, nothing merges), the
    /// middle one splices it and also survives, and the outer one then splices the middle -- so a term
    /// can sit at any depth the parser admits and no fixed number of levels is enough.
    ///
    /// A2d therefore addresses a `Sum`'s terms with `.replacedBySumTerm` below, which needs ONE
    /// integer at ANY depth, and this case is left exactly as A2a-A2c wrote it: `rewrite` on the named
    /// child re-folds it, so a child that itself collapses to a grandchild is handled by the recursion
    /// and never needs to be addressed from here.
    ///
    /// NEVER PRODUCED WHEN THE PROMOTED TERM IS A LEAF -- see `promoteTerm`, which returns the leaf
    /// itself in that case. That is what keeps the file's `.leaf` invariant exact: the C++ returns the
    /// child, so if the child is a `Numeric` the parent's `switchOn` sees a `Numeric`.
    case replacedByTerm(child: UInt32)
    /// A `Sum` that collapses to one of its own FLATTENED terms: `simplify(Sum&)`'s `:595`, `:657` and
    /// `:675`, each of which returns an element of `root.children` AFTER step 8.1 has spliced every
    /// nested `Sum`'s children into it.
    ///
    /// THE PAYLOAD IS AN ORIGIN ORDINAL, NOT A CHILD INDEX, and that is what makes one integer enough
    /// at unbounded depth -- see `.replacedByTerm` above for why a depth-limited address is not.
    /// `collectSumTerms` numbers the tree positions it emits (the children of the splice chain that
    /// are not themselves spliced `Sum`s) in visit order, and every term of every level of that chain
    /// carries the ordinal of the position it came from -- for a merged term, its first instance's.
    /// `rewrite` re-walks the identical structure counting the same ordinals and pushes the one it was
    /// asked for, so nothing is stored and nothing has to be kept in step with a depth. See
    /// `pushSumTerm`.
    ///
    /// Never produced when the term is a leaf, for the same reason and by the same helper shape as
    /// `.replacedByTerm`: see `promoteSumTerm`.
    case replacedBySumTerm(origin: UInt32)
    /// `clamp()` becoming `min()` or `max()`: `rewrite` pushes children 0 and 1 in tree order and
    /// calls `buildMinMax(isMax, 2)`. The ONLY rewrite in the whole simplifier that creates an
    /// operation kind that was not in the input (`+Simplification.cpp:1018`-`:1044`), and the only
    /// reason `buildMinMax` exists on the boundary.
    case rebuiltMinMax(isMax: Bool)
    /// A `Children`-slotted node whose children MERGED: `rewrite` recomputes the merge plan, pushes
    /// one operand per survivor, and calls `rebuildFrom(node, survivorCount)` with the new count.
    ///
    /// Kept apart from `.unchanged` rather than folded into it -- the C++ returns `std::nullopt` for
    /// both -- so that `fold`'s answer says whether the ARITY changed, which is the property
    /// `rebuildSlot(const Children&)` turns on. Carries the alternative for the same reason
    /// `.unchanged` does.
    case mergedChildren(CalcAlternative)
    /// Outside the island's slice, or a boundary contract the island will not guess at. The whole tree
    /// declines.
    ///
    /// THE PAYLOAD IS THE BLAME, and it is what `CSSCalcSwiftSimplificationResult.declineAlternative`
    /// reports. `nil` means "declined with no single alternative to blame", which the boundary spells
    /// `0xFF`; every decline this file produces from a *known* cause names it, so a `nil` reaching the
    /// harness is itself a finding. The differential checks the blame against the reason it derives
    /// independently -- `(inputKindMask & ~handledMask)` must contain this bit -- so an island that
    /// declined correctly for the wrong reason stops passing.
    case declined(CalcAlternative?)
}

/// The result of pushing one subtree's operand.
///
/// A two-case enum rather than a `Bool`, so that a decline carries the same blame `Fold.declined`
/// does and `declineAlternative` is answerable from wherever the decline happened. A `Bool` would
/// have made every rewrite-time decline report `0xFF`, and the boundary's own note says an
/// unattributed decline is one nobody can close.
private enum Rewrite {
    case pushed
    case declined(CalcAlternative?)
}

// MARK: - The traversal that decides, and reports

/// Whether A1 can simplify a node of this alternative with this many children.
///
/// An exhaustive `switch` with no catch-all, so that an alternative added to `CSSCalcTree.h` is a
/// compile error here rather than a node silently claimed. That direction is the same allowlist
/// argument `isGenericSerializedFunction` makes on the C++ side.
///
/// THE CHILD COUNT IS PART OF THE PREDICATE, and it is a genuine safety condition rather than
/// belt-and-braces. The C++ reads a node's slots directly -- `root.a`, `root.b`, `root.value` --
/// so its arity cannot disagree with itself. The island reads `childCount` and then asks
/// `rebuildFrom` to consume exactly that many operands, so a count that did not match the
/// operation's shape would fill the wrong slots. Insisting on it costs one comparison and makes the
/// disagreement a decline.
private func isSimplifiableAlternative(_ alternative: CalcAlternative, _ childCount: UInt32) -> Bool {
    switch alternative {
    case .Number, .Percentage, .CanonicalDimension, .NonCanonicalDimension:
        // The four leaves. `simplify` is a no-op for three of them and `canonicalize` for the
        // fourth (`+Simplification.cpp:486`-`:513`).
        return true

    case .Symbol:
        // `+Simplification.cpp:516`-`:524`. Any resolved unit, since the boundary now reports both
        // halves of `makeNumeric(value->value, root.unit)` -- see `foldSymbol`. An unresolvable
        // symbol is not a decline either; it is copied through.
        return true

    case .Invert:
        // `+Simplification.cpp:962`-`:979`.
        return childCount == 1
    case .Deg2Rad:
        // `+Simplification.cpp:981`-`:996`.
        return childCount == 1

    case .Mod, .Rem, .Atan2, .Pow:
        // `+Simplification.cpp:1127`-`:1135`, `:1167`-`:1172`, `:1174`-`:1187`. Fixed two-argument
        // operations; there is no shape of these with one child.
        return childCount == 2

    case .RoundNearest, .RoundUp, .RoundDown, .RoundToZero:
        // `simplifyForRound` (`:328`-`:337`) branches on whether `root.b` is present, and
        // `childCount` is exactly that: `forAllChildNodes` counts a `std::optional<Child>` only when
        // it holds one. So 1 is `round(X)` and 2 is `round(X, Y)`.
        return childCount == 1 || childCount == 2

    case .Sin, .Cos, .Tan, .Asin, .Acos, .Atan, .Sqrt, .Exp, .Abs, .Sign:
        return childCount == 1

    case .Log:
        // `log( <calc-sum>, <calc-sum>? )`, the second overload being the natural log.
        return childCount == 1 || childCount == 2

    case .Progress, .ProgressNoClamp:
        // `progress( <calc-sum>, <calc-sum>, <calc-sum> )`, all three required.
        return childCount == 3

    case .Sum:
        // `simplify(Sum&)` (`:547`-`:714`), A2d. THE SAME ARITY BOUND `Min`/`Max` TAKE, and for the
        // same reason: `simplify(Sum&)` opens with `ASSERT(!root.children.isEmpty())`. A shipping
        // build with no children would fall through step 8.1, find nothing to remove and rebuild
        // empty, which is what the island would do too -- but an assertions build fires on the C++
        // arm and would not on this one, and "the island claims a node the C++ arm asserts against"
        // is not a state worth having. Unreachable through the parser: `calc()` does not parse.
        //
        // No UPPER bound: `Children` is a variable-arity slot and `rebuildSlot(const Children&)`
        // takes all remaining operands, so any count is structurally valid on the rebuild side. Step
        // 8.1 can also make the term count LARGER than `childCount`, which is exactly what that
        // overload was written for.
        return childCount >= 1

    case .Product:
        // Declined. Its rules 9.1 and 9.2 merge every `Number` factor into one running product and
        // reassociate the rest, which is slice A3's work and not a fold of one node. A2d landed the
        // splice machinery it will build on: 9.1 is step 8.1 with `Product` in place of `Sum`.
        return false

    case .Negate:
        // Declined by A1. Rules 6.2 to 6.4 rewrite a CHILD's children in place
        // (`+Simplification.cpp:927`-`:959`), which the operand stack cannot express: the island
        // would have to hand back a subtree it never held.
        return false

    case .Min, .Max:
        // `simplifyForMinMax` (`:371`-`:482`), A2b. THE ONE ARITY BOUND IN THIS FUNCTION THAT COMES
        // FROM THE C++'s OWN PRECONDITION rather than from a slot count: `simplifyForMinMax` opens
        // with `ASSERT(!root.children.isEmpty())`. A shipping build with no children returns
        // `nullopt` and rebuilds empty, which is what the island would do too, so the two agree on
        // behaviour -- but an assertions build fires on the C++ arm and would not on this one, and
        // "the island claims a node the C++ arm asserts against" is not a state worth having. A
        // decline runs the C++ arm and fires the assert, which is the honest answer. Unreachable
        // through the parser either way: `min()` with no argument does not parse.
        //
        // No UPPER bound: `Children` is a variable-arity slot and `rebuildSlot(const Children&)`
        // takes all remaining operands, so any count is structurally valid on the rebuild side.
        return childCount >= 1

    case .Clamp:
        // `simplify(Clamp&)` (`:1008`-`:1105`), A2c. The one rule that changes an operation's KIND --
        // `clamp(none, VAL, MAX)` becomes `min(VAL, MAX)` -- and the only reason `buildMinMax` exists
        // on the boundary.
        //
        // 3 is `clamp(MIN, VAL, MAX)`, 2 is one bound holding the keyword `none`, and 1 is both
        // bounds holding it. Those are the only three shapes `ChildOrNone` admits, because `val` is a
        // plain `Child` and is always present. The SECOND half of the check -- that `kind` and
        // `childCount` agree about WHICH bound is `none` -- cannot be made here, because `kind` is
        // not a parameter; it is in `foldClamp`, which declines on disagreement.
        return childCount >= 1 && childCount <= 3

    case .Hypot:
        // `simplify(Hypot&)` (`:1204`-`:1279`), A2a. A stateful optimistic pass over a variable number
        // of children with a running type tag.
        //
        // NO ARITY CONDITION AT ALL, and unlike `Min`/`Max` above that is deliberate rather than an
        // omission: `simplify(Hypot&)` has no `ASSERT` on its child count, and its executor
        // (CSSCalcExecutor.h:404-:422) defines the empty case -- it returns NaN without ever calling
        // the functor, so the type tag stays `monostate` and the node is rebuilt unchanged. The island
        // reaches the identical answer for zero children (`.unchanged`, rebuilt through the same
        // `Children` slot), so there is nothing to decline.
        return true

    case .CalcMix:
        // Declined by A1. Normalisation over per-item weights that are not child nodes.
        return false

    case .Random:
        // Declined by A1. Needs `Style::BuilderState` for `resolveRandomBaseValue`, which is not
        // on the boundary and which A1 does not ask it to carry.
        return false

    case .SiblingCount, .SiblingIndex:
        // Declined by A1, and for the same reason `Random` is: both read
        // `conversionData->styleBuilderState()->element()` (`:527`-`:544`).
        return false

    case .Anchor, .AnchorSize:
        // Declined by A1 twice over: they need the anchor position evaluator, and they are the one
        // place the tuple conformance is a lie -- `rebuildFrom` refuses them outright
        // (CSSCalcSwiftTypes.h's note on `tuple_size` 0), so even a pass-through rebuild is not
        // available.
        return false

    @unknown default:
        // An alternative C++ grew and this file has not been taught. Declining is the only safe
        // answer.
        return false
    }
}

/// The coverage traversal. Accumulates the node count and the alternative mask, and reports whether
/// every node it saw is one A1 can simplify.
///
/// Recursive rather than an explicit stack, for the reason CSSCalcSerializationSwift.swift:403
/// gives: an explicit worklist would need a Swift container of a `~Escapable` element, no container
/// accepts one, and reaching for C++ to hold the container is the mistake this project has a
/// standing rule against. Calc trees are shallow and the parser bounds their depth long before this
/// runs.
///
/// KEPT AS A FULL TRAVERSAL EVEN ONCE THE ANSWER IS `false`, so that the node count and the mask
/// describe the whole tree rather than the prefix walked before the first declined node. The
/// differential's coverage assertions rest on that: a mask that stopped early would under-report
/// exactly the alternatives A1 needs to see arriving. It is also why this is a separate pass from
/// the rewrite, which stops at the first decline because there is nothing left to learn.
private func walk(
    _ node: borrowing WebCore.CSSCalc.CSSCalcSwiftNode,
    _ nodeCount: inout UInt32,
    _ kindMask: inout UInt64,
    _ blame: inout CalcAlternative?
) -> Bool {
    // One crossing per node: `info()` answers the discriminant, the child count and every POD
    // payload together, because they all come off the same variant tag.
    let info = node.info()
    nodeCount += 1

    kindMask |= UInt64(1) << UInt64(info.alternative.rawValue)

    var everyNodeSimplifiable = isSimplifiableAlternative(info.alternative, info.childCount)
    if !everyNodeSimplifiable, blame == nil {
        // The FIRST unhandled alternative, in the pre-order the walk visits, is the one reported.
        // First rather than last so that the blame is stable under a change that widens the slice:
        // teaching the island one more alternative can only move the blame outward, never make a
        // previously-blamed tree report a different node it also could not handle.
        blame = info.alternative
    }

    var index: UInt32 = 0
    while index < info.childCount {
        // TREE order, not serialization order. `childAt` sorts a `Sum`'s and a `Product`'s children
        // by unit, which is right for the serializer and would silently permute every multi-unit
        // sum in the document here. A1 declines both of those alternatives, so the two orders agree
        // for everything the island actually rewrites -- and this still uses the tree order,
        // because a predicate that is correct only because of what the caller declines is a defect
        // waiting for A2.
        if !walk(node.childInTreeOrder(index), &nodeCount, &kindMask, &blame) {
            everyNodeSimplifiable = false
        }
        index += 1
    }

    return everyNodeSimplifiable
}

// MARK: - The simplifier

/// The part of `SimplificationOptions` the island reads, which is two bools.
///
/// A `struct`, not a `class`: a class stored property costs dynamic exclusivity enforcement
/// (`swift_beginAccess`/`swift_endAccess`) on every read, on a recursion that reads this at nearly
/// every node.
///
/// IT IS TWO FIELDS OF SIX, AND THAT IS STILL THE FINDING. `CSSCalcSwiftSimplificationOptions`
/// carries six, and the island reads two of them. `range` is read at ZERO sites in the whole C++
/// simplifier -- it is the *serializer* that clamps against it; `category` is carried so that a later
/// slice needing the category itself does not have to widen the struct, and nothing reads it yet;
/// `hasConversionData` is subsumed by `resolveRelativeLength` answering `resolved == false`; and
/// `Stage` is copied through `copyAndSimplify` and never read. So this struct is the honest
/// reduction, and the boundary struct is sized for a later slice rather than for this one.
///
/// A2d IS WHAT MADE THE SECOND FIELD LIVE. `allowZeroValueLengthRemovalFromSum` is read at exactly
/// one C++ site, `:611`, inside `simplify(Sum&)`, which every slice before A2d declined -- so the
/// differential asserted the flag INERT (`simplifycheck.cpp`'s guard 7) and that assertion had to
/// flip with this slice. It flipped in both directions: the axis stopped being a null axis, and the
/// corpus grew the eleven `Sum`-with-a-zero-length-term cases that make the new assertion mean
/// something, because the hand-written corpus had none and the old guard was passing vacuously.
private struct CalcSimplification {
    /// `percentageResolveToDimension(options)` (`+Simplification.cpp:86`-`:107`), precomputed in
    /// C++ because deriving it here would put a second copy of the eleven-case `CSS::Category`
    /// table in Swift for a predicate whose whole content is "is it one of these two".
    let percentageResolveToDimension: Bool

    /// `options.allowZeroValueLengthRemovalFromSum`, read at exactly one C++ site, `:611`.
    ///
    /// NOT A RARE FLAG, which is why declining when it is set was never an acceptable answer for
    /// `Sum`: four production callers pass `true` -- `CSSUnevaluatedCalc.cpp:58`,
    /// `SizesAttributeParser.cpp:186`, and `StyleCalculationTree+Conversion.cpp:347` and `:370`.
    let allowZeroValueLengthRemovalFromSum: Bool

    // MARK: Shared predicates

    /// `unitsMatch` (`+Simplification.cpp:111`-`:129`), for two leaves already known to be the same
    /// alternative.
    ///
    /// ONE COMPARISON RATHER THAN A FOUR-WAY SWITCH, and the reason is `toCSSUnit`: `Number` always
    /// reports `CSSUnitType::Number` and `Percentage` always `CSSUnitType::Percentage`
    /// (CSSCalcTree.h:1008-:1009), so the two overloads that return an unconditional `true` are
    /// comparisons that cannot fail. `CanonicalDimension` reports `toCSSUnit(dimension)`, which is a
    /// bijection onto the six canonical units (`:992`), so comparing units is comparing dimensions;
    /// and `NonCanonicalDimension` reports `unit` itself. All four overloads are therefore this line.
    @inline(always)
    func unitsMatch(_ a: NumericLeaf, _ b: NumericLeaf) -> Bool {
        return a.unitType == b.unitType
    }

    /// `switchTogether` (`+Simplification.cpp:69`-`:82`) restricted to what A1 uses it for: two
    /// operands take the `Numeric T` visitor only when they are the SAME alternative, and fall to
    /// the `(const auto&, const auto&)` catch-all otherwise.
    @inline(always)
    func switchTogether(_ a: NumericLeaf, _ b: NumericLeaf) -> Bool {
        return a.kind == b.kind
    }

    /// `magnitudeComparable` (`+Simplification.cpp:133`-`:151`).
    @inline(always)
    func magnitudeComparable(_ a: NumericLeaf) -> Bool {
        switch a.kind {
        case .number, .canonicalDimension, .nonCanonicalDimension:
            return true
        case .percentage:
            return !percentageResolveToDimension
        }
    }

    /// `fullyResolved` (`+Simplification.cpp:155`-`:173`).
    ///
    /// The one that differs from `magnitudeComparable`, and it differs in one case:
    /// a `NonCanonicalDimension` is comparable by magnitude but is NOT fully resolved, because its
    /// value is in a unit that has not been converted yet.
    @inline(always)
    func fullyResolved(_ a: NumericLeaf) -> Bool {
        switch a.kind {
        case .number, .canonicalDimension:
            return true
        case .percentage:
            return !percentageResolveToDimension
        case .nonCanonicalDimension:
            return false
        }
    }

    // MARK: Generic partial evaluation

    /// `simplifyForOperation<Op>` (`+Simplification.cpp:298`-`:311`): both operands the same
    /// numeric alternative, units matching, the first fully resolved, and the result carried onto a
    /// leaf shaped like the first operand.
    @inline(always)
    func simplifyForOperation(
        _ a: NumericLeaf,
        _ b: NumericLeaf,
        _ operation: (Double, Double) -> Double
    ) -> Fold {
        guard switchTogether(a, b), unitsMatch(a, b), fullyResolved(a) else {
            return .unchanged(.Number)
        }
        return .leaf(a.withValue(operation(a.value, b.value)))
    }

    /// `simplifyForOperationWithCompletion<Op, Completion>` (`+Simplification.cpp:313`-`:326`).
    ///
    /// The same three predicates, with the caller choosing the result's SHAPE rather than inheriting
    /// the first operand's. `atan2()` is the only A1 user: its arguments may be any consistent
    /// numeric type and its result is always a canonical `<angle>`.
    @inline(always)
    func simplifyForOperationWithCompletion(
        _ a: NumericLeaf,
        _ b: NumericLeaf,
        _ operation: (Double, Double) -> Double,
        _ completion: (Double) -> NumericLeaf
    ) -> Fold {
        guard switchTogether(a, b), unitsMatch(a, b), fullyResolved(a) else {
            return .unchanged(.Number)
        }
        return .leaf(completion(operation(a.value, b.value)))
    }

    /// `simplifyForTrig<Op>` (`+Simplification.cpp:339`-`:354`): the argument has been type-checked
    /// to be a `<number>` or a `Deg2Rad` wrapper around an `<angle>`, so the fold fires only once it
    /// has resolved to a `Number` -- i.e. to a value already in radians.
    @inline(always)
    func simplifyForTrig(_ a: NumericLeaf, _ operation: (Double) -> Double) -> Fold {
        guard a.kind == .number else {
            return .unchanged(.Number)
        }
        return .leaf(NumericLeaf.number(operation(a.value)))
    }

    /// `simplifyForArcTrig<Op>` (`+Simplification.cpp:356`-`:369`): a `<number>` in, a canonical
    /// `<angle>` out.
    @inline(always)
    func simplifyForArcTrig(_ a: NumericLeaf, _ operation: (Double) -> Double) -> Fold {
        guard a.kind == .number else {
            return .unchanged(.Number)
        }
        return .leaf(NumericLeaf.canonicalAngle(operation(a.value)))
    }
}

// MARK: - The per-operation folds
//
// One function per C++ `simplify` overload, in `CSSCalcTree+Simplification.cpp`'s own order, each
// taking its operands already folded. A function per operation rather than one switch with the
// arithmetic inline, because the C++ is one function per operation and a reader checking the port
// should be able to put the two side by side.

private extension CalcSimplification {

    /// `simplify(Invert&)` (`+Simplification.cpp:962`-`:979`).
    ///
    /// Rule 7.1 only. RULE 7.2 -- "if root's child is an Invert node, return the child's child" --
    /// IS DECLINED, and this is A1's one coverage gap that is a boundary limitation rather than a
    /// scope decision. The child's child is a subtree the island never held: `rewrite` pushed the
    /// child as one operand and `rebuildFrom` consumed it, and the operand stack has no way to hand
    /// a node's slot back. Declining is exact -- the C++ arm runs and applies 7.2 itself.
    ///
    /// Reachability, so the gap is sized rather than merely named: division always builds a
    /// `Product` wrapper, so `calc(1 / r)` parses as `Product{Number(1), Invert{Symbol}}` and an
    /// `Invert` therefore only ever appears inside a `Product`, which A1 declines outright. A bare
    /// `Invert{Invert{X}}` is reachable only from a programmatically constructed tree.
    @inline(always)
    func foldInvert(_ a: Fold) -> Fold {
        switch a {
        case .leaf(let leaf):
            guard leaf.kind == .number else {
                // 7.1 is `<number>` only: the reciprocal of a percentage or a dimension is not a
                // value the tree can hold, so the C++ `Number&` visitor does not match and the node
                // is rebuilt.
                return .unchanged(.Invert)
            }
            return .leaf(NumericLeaf.number(CalcExecutor.invert(leaf.value)))
        case .unchanged(let childAlternative):
            if childAlternative == .Invert {
                return .declined(.Invert)
            }
            return .unchanged(.Invert)
        case .replacedByTerm, .replacedBySumTerm:
            // A2. The child collapsed to one of ITS OWN children -- a single-argument `min()`, a
            // `clamp(none, VAL, none)`, or (A2d) a `Sum` that collapsed to one of its flattened terms
            // -- and the island does not carry what that term's alternative is, so it cannot tell
            // whether rule 7.2 applies to the result. Declining is exact, because a decline runs the
            // C++ arm and that arm applies 7.2 or not as the tree requires; the cost is coverage, and
            // it is unmeasurable here for the reason above: an `Invert` is only reachable inside a
            // `Product`, which declines outright, so reaching this at all needs a constructed tree.
            return .declined(.Invert)
        case .mergedChildren, .rebuiltMinMax:
            // A2. Neither can be an `Invert` and both carry what they ARE -- `.mergedChildren` names
            // its alternative and is produced only by `foldMinMax` and `foldSum`, and
            // `.rebuiltMinMax` is `buildMinMax` by construction. So this is the C++'s `[](auto&)`
            // arm: `nullopt`, and the `Invert` is rebuilt from its one simplified child.
            return .unchanged(.Invert)
        case .declined(let blame):
            return .declined(blame)
        }
    }

    /// `simplify(Deg2Rad&)` (`+Simplification.cpp:981`-`:996`).
    ///
    /// A SAFETY IMPROVEMENT OVER THE C++, and a deliberate one. The C++ writes
    /// `ASSERT(a.dimension == CanonicalDimension::Dimension::Angle)` and then converts whatever it
    /// was given -- so in a shipping build, where the assertion is compiled out, a `Deg2Rad`
    /// wrapping a canonical `<length>` would silently produce `px * pi / 180` and call it a number.
    /// The island requires the unit instead and declines when it does not hold, which cannot
    /// diverge: a decline runs the C++ arm, which produces the answer it would have produced anyway.
    ///
    /// `toCSSUnit(Dimension::Angle)` is `CSSUnitType::Deg` (CSSCalcTree.h:996), so comparing units
    /// is comparing dimensions and no `Dimension` crosses the boundary.
    @inline(always)
    func foldDeg2Rad(_ angle: Fold) -> Fold {
        guard case .leaf(let leaf) = angle else {
            return foldFailed(angle, .Deg2Rad)
        }
        guard leaf.kind == .canonicalDimension,
              leaf.unitType == UInt16(WebCore.CSSUnitType.Deg.rawValue) else {
            return .unchanged(.Deg2Rad)
        }
        return .leaf(NumericLeaf.number(CalcExecutor.degreesToRadians(leaf.value)))
    }

    /// `simplifyForRound<Op>` (`+Simplification.cpp:328`-`:337`), for all four strategies.
    ///
    /// Two shapes, and the C++ branches on `root.b` where this branches on the child count -- the
    /// same test, because `forAllChildNodes` counts a `std::optional<Child>` exactly when it holds
    /// one. With a second argument it is `simplifyForOperation`; without one, the value must be a
    /// `Number` and the interval is `1.0`.
    @inline(always)
    func foldRound(_ a: Fold, _ b: Fold?, _ alternative: CalcAlternative, _ operation: (Double, Double) -> Double) -> Fold {
        guard case .leaf(let valueToRound) = a else {
            return foldFailed(a, alternative)
        }

        if let b {
            guard case .leaf(let interval) = b else {
                return foldFailed(b, alternative)
            }
            return reshape(simplifyForOperation(valueToRound, interval, operation), alternative)
        }

        // `if (auto* numberA = get_if<Number>(&root.a)) return makeChild(Number { .value =
        // executeMathOperation<Op>(numberA->value, 1.0) });`
        guard valueToRound.kind == .number else {
            return .unchanged(alternative)
        }
        return .leaf(NumericLeaf.number(operation(valueToRound.value, 1.0)))
    }

    /// `simplify(Mod&)` and `simplify(Rem&)` (`+Simplification.cpp:1127`-`:1135`), and equally
    /// `simplify(Atan2&)`'s predicate half. Both are `simplifyForOperation` over two folded
    /// operands.
    @inline(always)
    func foldBinaryOperation(_ a: Fold, _ b: Fold, _ alternative: CalcAlternative, _ operation: (Double, Double) -> Double) -> Fold {
        guard case .leaf(let left) = a else {
            return foldFailed(a, alternative)
        }
        guard case .leaf(let right) = b else {
            return foldFailed(b, alternative)
        }
        return reshape(simplifyForOperation(left, right, operation), alternative)
    }

    /// `simplify(Atan2&)` (`+Simplification.cpp:1167`-`:1172`): `simplifyForOperationWithCompletion`
    /// whose completion builds a canonical `<angle>`.
    @inline(always)
    func foldAtan2(_ a: Fold, _ b: Fold) -> Fold {
        guard case .leaf(let left) = a else {
            return foldFailed(a, .Atan2)
        }
        guard case .leaf(let right) = b else {
            return foldFailed(b, .Atan2)
        }
        let folded = simplifyForOperationWithCompletion(left, right, CalcExecutor.atan2) { value in
            NumericLeaf.canonicalAngle(value)
        }
        return reshape(folded, .Atan2)
    }

    /// `simplify(Pow&)` (`+Simplification.cpp:1174`-`:1187`).
    ///
    /// `switchTogether` with a `(const Number&, const Number&)` visitor and NOTHING ELSE -- no
    /// `unitsMatch`, no `fullyResolved`, because both arguments are type-checked to be `<number>` at
    /// parse time and any other same-alternative pair falls to the catch-all. So the predicate here
    /// is "both are `Number`", which is narrower than `simplifyForOperation`'s and is why `pow()`
    /// does not share `foldBinaryOperation`.
    @inline(always)
    func foldTwoNumbers(_ a: Fold, _ b: Fold, _ alternative: CalcAlternative, _ operation: (Double, Double) -> Double) -> Fold {
        guard case .leaf(let left) = a else {
            return foldFailed(a, alternative)
        }
        guard case .leaf(let right) = b else {
            return foldFailed(b, alternative)
        }
        guard left.kind == .number, right.kind == .number else {
            return .unchanged(alternative)
        }
        return .leaf(NumericLeaf.number(operation(left.value, right.value)))
    }

    /// `simplify(Sqrt&)`, `simplify(Exp&)` and `simplify(Log&)`'s one-argument shape
    /// (`+Simplification.cpp:1189`-`:1202`, `:1307`-`:1320`, `:1300`-`:1305`): a `Number` in, a
    /// `Number` out, with no other predicate.
    @inline(always)
    func foldOneNumber(_ a: Fold, _ alternative: CalcAlternative, _ operation: (Double) -> Double) -> Fold {
        guard case .leaf(let operand) = a else {
            return foldFailed(a, alternative)
        }
        guard operand.kind == .number else {
            return .unchanged(alternative)
        }
        return .leaf(NumericLeaf.number(operation(operand.value)))
    }

    /// `simplify(Abs&)` (`+Simplification.cpp:1322`-`:1334`): any numeric alternative, guarded by
    /// `magnitudeComparable` alone, with the result carried onto a leaf shaped like the operand.
    @inline(always)
    func foldAbs(_ a: Fold) -> Fold {
        guard case .leaf(let operand) = a else {
            return foldFailed(a, .Abs)
        }
        guard magnitudeComparable(operand) else {
            return .unchanged(.Abs)
        }
        return .leaf(operand.withValue(CalcExecutor.abs(operand.value)))
    }

    /// `simplify(Sign&)` (`+Simplification.cpp:1336`-`:1348`): the same guard as `abs()`, and a
    /// `Number` result whatever the operand's alternative was.
    @inline(always)
    func foldSign(_ a: Fold) -> Fold {
        guard case .leaf(let operand) = a else {
            return foldFailed(a, .Sign)
        }
        guard magnitudeComparable(operand) else {
            return .unchanged(.Sign)
        }
        return .leaf(NumericLeaf.number(CalcExecutor.sign(operand.value)))
    }

    /// `simplify(Progress&)` and `simplify(ProgressNoClamp&)` (`+Simplification.cpp:1403`-`:1443`).
    ///
    /// Three operands, all of the same alternative -- the C++ tests `index()` equality across all
    /// three before the `Numeric T` visitor runs -- with `unitsMatch` checked on both adjacent pairs
    /// and `fullyResolved` on the first. The result is always a `<number>`, which is what makes
    /// `progress()` a ratio rather than a quantity.
    @inline(always)
    func foldProgress(
        _ value: Fold,
        _ start: Fold,
        _ end: Fold,
        _ alternative: CalcAlternative,
        _ operation: (Double, Double, Double) -> Double
    ) -> Fold {
        guard case .leaf(let numericValue) = value else {
            return foldFailed(value, alternative)
        }
        guard case .leaf(let numericStart) = start else {
            return foldFailed(start, alternative)
        }
        guard case .leaf(let numericEnd) = end else {
            return foldFailed(end, alternative)
        }
        guard switchTogether(numericValue, numericStart), switchTogether(numericStart, numericEnd) else {
            return .unchanged(alternative)
        }
        guard unitsMatch(numericValue, numericStart), unitsMatch(numericStart, numericEnd),
              fullyResolved(numericValue) else {
            return .unchanged(alternative)
        }
        return .leaf(NumericLeaf.number(operation(numericValue.value, numericStart.value, numericEnd.value)))
    }

    /// What an operation reports when one of its operands did not fold to a leaf.
    ///
    /// A declined operand declines the whole tree; an unchanged one means the operation keeps its
    /// own alternative and is rebuilt from its children. One function so that the distinction is
    /// made in one place rather than at each of the twelve operand guards above, where getting it
    /// backwards would turn a decline into a wrong tree.
    @inline(always)
    func foldFailed(_ operand: Fold, _ alternative: CalcAlternative) -> Fold {
        if case .declined(let blame) = operand {
            return .declined(blame)
        }
        return .unchanged(alternative)
    }

    /// Restamp a shared predicate's `.unchanged` with the caller's own alternative.
    ///
    /// `simplifyForOperation` and its siblings do not know which operation invoked them, so they
    /// report `.unchanged(.Number)` as a placeholder. This puts the right alternative back, which
    /// matters because `rewrite` uses it and `foldInvert` reads it.
    @inline(always)
    func reshape(_ fold: Fold, _ alternative: CalcAlternative) -> Fold {
        if case .unchanged = fold {
            return .unchanged(alternative)
        }
        return fold
    }
}

// MARK: - Folding a whole subtree

private extension CalcSimplification {

    /// What `copyAndSimplify(const Child&)` (`+Simplification.cpp:1809`-`:1822`) would produce for
    /// this subtree, PUSHING NOTHING.
    ///
    /// The C++ does two things per node -- simplify the children, then try to fold the node itself
    /// -- and this is both of them, with the second's result reported rather than materialised. See
    /// the file header for why the push has to be deferred.
    ///
    /// `builder` is `borrowing` and only its two `const` upcalls are reached from here, which is
    /// what makes "pushes nothing" a property the compiler helps with rather than a comment:
    /// `pushLeaf`, `pushCopyOf`, `rebuildFrom` and `buildMinMax` are all non-`const` in C++ and
    /// therefore `mutating` in Swift, so none of them can be called on a borrow.
    func fold(
        _ node: borrowing WebCore.CSSCalc.CSSCalcSwiftNode,
        _ builder: borrowing WebCore.CSSCalc.CSSCalcSwiftBuilder
    ) -> Fold {
        let info = node.info()
        let alternative = info.alternative

        switch alternative {
        // `simplify(Number&)`, `simplify(Percentage&)` and `simplify(CanonicalDimension&)` all
        // return `std::nullopt` (`:486`-`:513`), so the C++ rebuilds the leaf as itself. Reported as
        // `.leaf` rather than `.unchanged` because those are the same node and the leaf form is what
        // lets a parent fold -- which is the entire point of the two-phase design.
        //
        // Three cases rather than one with a mapping function, because a mapping function over a
        // 41-case enum needs a catch-all to be total and a catch-all is what turns "the island got
        // the alternative wrong" from a compile error into a `<number>`.
        case .Number:
            return .leaf(NumericLeaf(
                kind: .number,
                value: info.numericValue,
                unitType: UInt16(info.unitType),
                percentHint: 0
            ))

        case .Percentage:
            // The hint is the one field a fold must carry and can neither recompute nor default:
            // `makeChildWithValueBasedOn(value, const Percentage&)` copies it (CSSCalcTree.cpp:318),
            // and `makeNumeric` would set it to `{ }`.
            return .leaf(NumericLeaf(
                kind: .percentage,
                value: info.numericValue,
                unitType: UInt16(info.unitType),
                percentHint: info.percentHint
            ))

        case .CanonicalDimension:
            return .leaf(NumericLeaf(
                kind: .canonicalDimension,
                value: info.numericValue,
                unitType: UInt16(info.unitType),
                percentHint: 0
            ))

        case .NonCanonicalDimension:
            // `simplify(NonCanonicalDimension&)` (`:505`-`:513`), shared with `foldSymbol`'s fourth
            // arm because the C++ reaches the same overload from both.
            return .leaf(canonicalizedDimension(info.numericValue, UInt16(info.unitType), builder))

        case .Symbol:
            return foldSymbol(info, builder)

        case .Invert:
            return foldInvert(fold(node.childInTreeOrder(0), builder))

        case .Deg2Rad:
            return foldDeg2Rad(fold(node.childInTreeOrder(0), builder))

        case .Min:
            return foldMinMax(node, info, false, builder)
        case .Max:
            return foldMinMax(node, info, true, builder)

        case .Sum:
            return foldSum(node, info, builder)

        case .Clamp:
            return foldClamp(node, info, builder)

        case .RoundNearest:
            return foldRound(fold(node.childInTreeOrder(0), builder), secondOperand(node, info, builder), alternative, CalcExecutor.roundNearest)
        case .RoundUp:
            return foldRound(fold(node.childInTreeOrder(0), builder), secondOperand(node, info, builder), alternative, CalcExecutor.roundUp)
        case .RoundDown:
            return foldRound(fold(node.childInTreeOrder(0), builder), secondOperand(node, info, builder), alternative, CalcExecutor.roundDown)
        case .RoundToZero:
            return foldRound(fold(node.childInTreeOrder(0), builder), secondOperand(node, info, builder), alternative, CalcExecutor.roundToZero)

        case .Mod:
            return foldBinaryOperation(fold(node.childInTreeOrder(0), builder), fold(node.childInTreeOrder(1), builder), alternative, CalcExecutor.mod)
        case .Rem:
            return foldBinaryOperation(fold(node.childInTreeOrder(0), builder), fold(node.childInTreeOrder(1), builder), alternative, CalcExecutor.rem)

        case .Sin:
            return reshape(simplifyForTrigOperand(fold(node.childInTreeOrder(0), builder), alternative, CalcExecutor.sin), alternative)
        case .Cos:
            return reshape(simplifyForTrigOperand(fold(node.childInTreeOrder(0), builder), alternative, CalcExecutor.cos), alternative)
        case .Tan:
            return reshape(simplifyForTrigOperand(fold(node.childInTreeOrder(0), builder), alternative, CalcExecutor.tan), alternative)

        case .Asin:
            return reshape(simplifyForArcTrigOperand(fold(node.childInTreeOrder(0), builder), alternative, CalcExecutor.asin), alternative)
        case .Acos:
            return reshape(simplifyForArcTrigOperand(fold(node.childInTreeOrder(0), builder), alternative, CalcExecutor.acos), alternative)
        case .Atan:
            return reshape(simplifyForArcTrigOperand(fold(node.childInTreeOrder(0), builder), alternative, CalcExecutor.atan), alternative)

        case .Atan2:
            return foldAtan2(fold(node.childInTreeOrder(0), builder), fold(node.childInTreeOrder(1), builder))

        case .Pow:
            return foldTwoNumbers(fold(node.childInTreeOrder(0), builder), fold(node.childInTreeOrder(1), builder), alternative, CalcExecutor.pow)

        case .Sqrt:
            return foldOneNumber(fold(node.childInTreeOrder(0), builder), alternative, CalcExecutor.sqrt)

        case .Hypot:
            return foldHypot(node, info, builder)

        case .Log:
            // `log( <calc-sum>, <calc-sum>? )`. With a base it is the two-`Number` shape, without
            // one it is the natural log -- two different `OperatorExecutor<Operator::Log>`
            // overloads, and the C++ picks between them on `root.b` exactly as this picks on the
            // child count.
            if let base = secondOperand(node, info, builder) {
                return foldTwoNumbers(fold(node.childInTreeOrder(0), builder), base, alternative, CalcExecutor.log)
            }
            return foldOneNumber(fold(node.childInTreeOrder(0), builder), alternative, CalcExecutor.log)

        case .Exp:
            return foldOneNumber(fold(node.childInTreeOrder(0), builder), alternative, CalcExecutor.exp)

        case .Abs:
            return foldAbs(fold(node.childInTreeOrder(0), builder))

        case .Sign:
            return foldSign(fold(node.childInTreeOrder(0), builder))

        case .Progress:
            return foldProgress(
                fold(node.childInTreeOrder(0), builder),
                fold(node.childInTreeOrder(1), builder),
                fold(node.childInTreeOrder(2), builder),
                alternative,
                CalcExecutor.progress
            )
        case .ProgressNoClamp:
            return foldProgress(
                fold(node.childInTreeOrder(0), builder),
                fold(node.childInTreeOrder(1), builder),
                fold(node.childInTreeOrder(2), builder),
                alternative,
                CalcExecutor.progressNoClamp
            )

        case .SiblingCount, .SiblingIndex, .Product, .Negate,
             .Random, .CalcMix, .Anchor, .AnchorSize:
            // Outside the island's slice. Enumerated one by one rather than swept into the
            // `@unknown default` below, so that the two lists stay distinguishable: these are
            // alternatives the island KNOWS and declines, and the default is alternatives it has not
            // been taught.
            return .declined(alternative)

        @unknown default:
            // An alternative C++ grew and this file has not been taught. Blamed by name anyway,
            // because `alternative` is a value rather than a case label and reporting it is what
            // tells the next reader which one it was.
            return .declined(alternative)
        }
    }

    /// `simplify(Symbol&)` (`+Simplification.cpp:516`-`:524`): resolve the `<calc-keyword>` against
    /// the symbol table and simplify what it resolves to.
    ///
    /// ANY RESOLVED UNIT, not just `<number>`. Both of the two reasons A1 originally restricted this
    /// to `Number`/`Integer` were boundary defects rather than scope decisions, and both are now
    /// closed at the boundary rather than worked around here:
    ///
    ///  1. The island could not classify an arbitrary unit. `simplify(Symbol&)` builds
    ///     `makeNumeric(value, unit)`, which is a seventy-case switch choosing among the four
    ///     numeric alternatives, and the island has to know WHICH it chose in order to report the
    ///     leaf. Reproducing that choice here would be a duplicated generated table -- the one thing
    ///     this port counts as goop by name -- so `CSSCalcSwiftNumericResult` carries the
    ///     alternative `makeNumeric` actually built, read back off the node C++ built rather than
    ///     restated. Free: the struct padded to 16 bytes with three fields and still does with four
    ///     (measured, `cssprobe/calcsimplify/sizeprobe.cpp`).
    ///
    ///  2. The unit the boundary reported was the SYMBOL TABLE's, and the C++ uses the SYMBOL
    ///     NODE's. `simplify(Symbol&)` is `makeNumeric(value->value, root.unit)` -- the value from
    ///     `CSSCalcSymbolTable` and the unit from `Symbol::unit`, which the parser took from
    ///     `CSSCalcSymbolsAllowed` (CSSCalcTree+Parser.cpp:1582), two independently populated
    ///     `HashMap`s. `info().unitType` now carries `Symbol::unit`, and it is passed back down to
    ///     `resolveSymbol` so that C++ does exactly the call the C++ arm does. Nothing here reads
    ///     the table's unit, because the C++ does not read it either.
    ///
    /// THE RECURSION IS WRITTEN OUT rather than re-entered. The C++ is
    /// `copyAndSimplify(makeNumeric(...), options)`, and `copyAndSimplify` on a numeric leaf is one
    /// `simplify` overload: a no-op for `Number`, `Percentage` and `CanonicalDimension`, and
    /// `canonicalize` for `NonCanonicalDimension` (`:486`-`:513`). So the four arms below are that
    /// recursion, bottomed out -- and the fourth shares `canonicalizedDimension` with the walk's own
    /// `NonCanonicalDimension` case, so there is one spelling of it and not two.
    ///
    /// An UNRESOLVED symbol is not a failure and not a decline: `simplify` returns `std::nullopt`
    /// and the node is copied through unchanged, which is `.unchanged` here.
    @inline(always)
    func foldSymbol(
        _ info: WebCore.CSSCalc.CSSCalcSwiftNodeInfo,
        _ builder: borrowing WebCore.CSSCalc.CSSCalcSwiftBuilder
    ) -> Fold {
        let resolved = builder.resolveSymbol(info.valueID, UInt16(info.unitType))
        guard resolved.resolved else {
            return .unchanged(.Symbol)
        }

        switch resolved.alternative {
        case .Number:
            return .leaf(NumericLeaf(
                kind: .number,
                value: resolved.value,
                unitType: resolved.unitType,
                percentHint: 0
            ))

        case .Percentage:
            // `makeNumeric` builds `Percentage { .value = value, .hint = { } }`
            // (CSSCalcTree.cpp:196-:197), so the hint is 0 and is not inherited from anywhere --
            // unlike a FOLD of an existing percentage, which must carry the operand's hint.
            return .leaf(NumericLeaf(
                kind: .percentage,
                value: resolved.value,
                unitType: resolved.unitType,
                percentHint: 0
            ))

        case .CanonicalDimension:
            return .leaf(NumericLeaf(
                kind: .canonicalDimension,
                value: resolved.value,
                unitType: resolved.unitType,
                percentHint: 0
            ))

        case .NonCanonicalDimension:
            return .leaf(canonicalizedDimension(resolved.value, resolved.unitType, builder))

        default:
            // `makeNumeric` returns one of the four numeric alternatives for every input it is
            // given, so this is unreachable through the boundary as it stands -- it is the branch
            // that exists because a `switch` over the 41-case discriminant needs one, and declining
            // is the only answer that cannot be silently wrong. Blamed as `Symbol`, which is the
            // node the island was standing on.
            return .declined(.Symbol)
        }
    }

    /// `simplify(NonCanonicalDimension&)` (`:505`-`:513`): canonicalize if there is enough
    /// information, otherwise leave it alone.
    ///
    /// Shared by the walk's own `NonCanonicalDimension` case and by `foldSymbol`, because the C++
    /// reaches the same overload from both -- and two spellings of it is two things that can drift.
    ///
    /// THIS IS `canonicalize` (`+Simplification.cpp:169`-`:287`) ITSELF, not a call to it. Its
    /// seventy `CSSUnitType` cases split three ways and Swift names only two of the three:
    ///
    ///   - FOURTEEN do arithmetic against a compile-time constant and are here, multiplying by the
    ///     same `WebCore::CSS::` and `wtf/MathExtras.h` constants the C++ arm multiplies by. Not
    ///     transcribed: read from the same headers, through `CSSUnitConversions.h` and
    ///     `wtf.Core.MathExtras`.
    ///   - FOURTEEN are the ones a `NonCanonicalDimension` can never hold -- the six canonical
    ///     dimensional units, the three non-dimensional ones, and five non-numeric ones. The C++
    ///     `ASSERT_NOT_REACHED`es and returns `nullopt`, so the shipping behaviour is "leave it
    ///     alone", which is what these do. They are ENUMERATED rather than defaulted, so that a unit
    ///     that cannot be canonicalized at all does not silently cost a crossing.
    ///   - FORTY-TWO are font-, viewport- and container-relative lengths, and they are the `default`
    ///     arm. THE ISLAND NEVER NAMES THEM, which is the whole reason this port does not duplicate
    ///     a table: knowing *which* forty-two they are would be `CSS::toLengthUnit`
    ///     (CSSPrimitiveNumericUnits.h:609) restated in Swift, and "everything I did not name" needs
    ///     no list. `Style::resolveLength` needs `CSSToLengthConversionData` -- a style object, with
    ///     font metrics and a viewport on it -- so it stays the one upcall.
    ///
    /// `resolved == false` from that upcall is the C++'s `nullopt`, which for those forty-two means
    /// "no conversion data": a normal outcome, not a failure, and the dimension stays as it is.
    @inline(always)
    func canonicalizedDimension(
        _ value: Double,
        _ unitType: UInt16,
        _ builder: borrowing WebCore.CSSCalc.CSSCalcSwiftBuilder
    ) -> NumericLeaf {
        // The C++'s `nullopt`: `simplify(NonCanonicalDimension&)` copies the node through unchanged.
        func unchanged() -> NumericLeaf {
            return NumericLeaf(kind: .nonCanonicalDimension, value: value, unitType: unitType, percentHint: 0)
        }
        // `makeCanonical(value, dimension)`. The canonical UNIT is named rather than the
        // `CanonicalDimension::Dimension`, because `Dimension` does not cross the boundary and
        // `makeNumeric` maps the unit back to it (CSSCalcTree.cpp:187) -- so these five spellings are
        // `toCSSUnit(Dimension)` (CSSCalcTree.h:992) read forwards, and there is no sixth: `Fr` is
        // `Dimension::Flex`, which `canonicalize` has no case for.
        func canonical(_ canonicalized: Double, _ canonicalUnit: WebCore.CSSUnitType) -> NumericLeaf {
            return NumericLeaf(
                kind: .canonicalDimension,
                value: canonicalized,
                unitType: UInt16(canonicalUnit.rawValue),
                percentHint: 0
            )
        }

        // `UInt8(exactly:)` rather than `UInt8(_:)`, which traps: the boundary widens the unit to
        // `uint16_t` (see `CSSCalcSwiftLeaf.unitType`), so narrowing it back is a conversion this
        // island has to be able to fail. A value outside the enum lands in the same place the C++'s
        // `ASSERT_NOT_REACHED` does in a shipping build -- unchanged -- rather than trapping.
        guard let raw = UInt8(exactly: unitType), let unit = WebCore.CSSUnitType(rawValue: raw) else {
            return unchanged()
        }

        switch unit {
        // Absolute lengths, canonicalizable with no conversion data at all.
        case .Cm:
            return canonical(value * WebCore.CSS.pixelsPerCm, .Px)
        case .Mm:
            return canonical(value * WebCore.CSS.pixelsPerMm, .Px)
        case .Q:
            return canonical(value * WebCore.CSS.pixelsPerQ, .Px)
        case .In:
            return canonical(value * WebCore.CSS.pixelsPerInch, .Px)
        case .Pt:
            return canonical(value * WebCore.CSS.pixelsPerPt, .Px)
        case .Pc:
            return canonical(value * WebCore.CSS.pixelsPerPc, .Px)

        // <angle>
        case .Rad:
            return canonical(value * degreesPerRadianDouble, .Deg)
        case .Grad:
            return canonical(value * degreesPerGradientDouble, .Deg)
        case .Turn:
            return canonical(value * degreesPerTurnDouble, .Deg)

        // <time>
        case .Ms:
            return canonical(value * WebCore.CSS.secondsPerMillisecond, .S)

        // <frequency>
        case .Khz:
            return canonical(value * WebCore.CSS.hertzPerKilohertz, .Hz)

        // <resolution>
        case .X:
            return canonical(value * WebCore.CSS.dppxPerX, .Dppx)
        case .Dpi:
            return canonical(value * WebCore.CSS.dppxPerDpi, .Dppx)
        case .Dpcm:
            return canonical(value * WebCore.CSS.dppxPerDpcm, .Dppx)

        // The fourteen a `NonCanonicalDimension` can never hold: the six canonical dimensional units,
        // the three non-dimensional ones, and five non-numeric ones. `ASSERT_NOT_REACHED` in the C++;
        // unchanged here, which is what that build actually does. Enumerated so that they do NOT fall
        // into the upcall arm below.
        case .Px, .Deg, .S, .Hz, .Dppx, .Fr,
             .Number, .Integer, .Percentage,
             .Calc, .CalcPercentageWithAngle, .CalcPercentageWithLength, .QuirkyEm, .Unknown:
            return unchanged()

        // EVERYTHING ELSE is a font-, viewport- or container-relative length, and this arm is what
        // keeps `CSS::toLengthUnit` out of Swift: the island names the twenty-eight it decides and
        // forwards the rest without enumerating them.
        default:
            let resolved = builder.resolveRelativeLength(value, unitType)
            guard resolved.resolved else {
                return unchanged()
            }
            // `CanonicalDimension` unconditionally, and that is the upcall's own answer rather than
            // this island's guess: `resolveRelativeLength` fills `alternative` from `makeNumeric`,
            // and for a resolved relative length it is always this one -- resolving a length yields
            // a length. Read from `resolved.unitType` so the unit still comes from C++.
            return NumericLeaf(
                kind: .canonicalDimension,
                value: resolved.value,
                unitType: resolved.unitType,
                percentHint: 0
            )
        }
    }


    /// The `std::optional<Child> b` slot of `round()` and `log()`, folded, or `nil` when the node
    /// does not have one.
    ///
    /// `childCount` is the presence test, for the reason `isSimplifiableAlternative` gives: a
    /// `std::optional<Child>` is counted by `forAllChildNodes` exactly when it holds a value, so
    /// there is no absent child for the island to index past. The count has already been checked to
    /// be 1 or 2 by the coverage walk, so this is a presence test and not a bounds check -- but it
    /// is written as `> 1` rather than `== 2` so that it stays a presence test if a later slice
    /// admits a wider arity.
    @inline(always)
    func secondOperand(
        _ node: borrowing WebCore.CSSCalc.CSSCalcSwiftNode,
        _ info: WebCore.CSSCalc.CSSCalcSwiftNodeInfo,
        _ builder: borrowing WebCore.CSSCalc.CSSCalcSwiftBuilder
    ) -> Fold? {
        guard info.childCount > 1 else {
            return nil
        }
        return fold(node.childInTreeOrder(1), builder)
    }

    /// `simplifyForTrig` over an already-folded operand.
    @inline(always)
    func simplifyForTrigOperand(_ a: Fold, _ alternative: CalcAlternative, _ operation: (Double) -> Double) -> Fold {
        guard case .leaf(let operand) = a else {
            return foldFailed(a, alternative)
        }
        return simplifyForTrig(operand, operation)
    }

    /// `simplifyForArcTrig` over an already-folded operand.
    @inline(always)
    func simplifyForArcTrigOperand(_ a: Fold, _ alternative: CalcAlternative, _ operation: (Double) -> Double) -> Fold {
        guard case .leaf(let operand) = a else {
            return foldFailed(a, alternative)
        }
        return simplifyForArcTrig(operand, operation)
    }
}

// MARK: - The `Children`-slotted folds: `hypot()`, `min()`, `max()` and `clamp()`
//
// Slice A2a-A2c. These are the first operations in the port whose result can have a DIFFERENT NUMBER
// OF CHILDREN from its input, and the first that can produce a node of a kind that was not in the
// input. Three things follow, and they are what separates these from A1's folds:
//
//   - each needs its own node rather than just its operands' folds, because the arity is part of the
//     answer, so they live here beside `fold` rather than in the per-operation extension above;
//   - `fold` may answer `.replacedByTerm`, `.mergedChildren` or `.rebuiltMinMax`, none of which A1
//     had a shape for, and each of which tells `rewrite` what to push instead of "the children";
//   - they are the only callers of `rebuildSlot(const Children&)` and `buildMinMax`, both of which
//     had never executed before A2.

/// `simplify(Hypot&)`'s five-alternative running type tag (`+Simplification.cpp:1208`-`:1212`), which
/// the C++ spells as a `Variant<std::monostate, NumberTag, PercentageTag, DimensionTag, FailureTag>`.
///
/// `.unset` rather than the C++'s `monostate` name, and NOT `.none`, which is what the plan for this
/// slice wrote: a case literally called `none` on a non-`Optional` enum is legal but reads as
/// `Optional.none` at every `switch` site, and this is a state machine where confusing "no tag yet"
/// with "no value" is a wrong fold rather than a compile error.
///
/// `DimensionTag`'s key is a `CanonicalDimension::Dimension` in the C++ and a `CSSUnitType` raw value
/// here, which is the identical substitution `foldDeg2Rad` already makes: `toCSSUnit(Dimension)` is a
/// bijection onto the six canonical units (CSSCalcTree.h:992-:1005), so comparing units is comparing
/// dimensions and `Dimension` still never crosses the boundary.
private enum HypotTag {
    case unset
    case number
    case percentage
    case dimension(UInt16)
    case failed
}

private extension CalcSimplification {

    /// Fold every child of a variable-arity node, in TREE order.
    ///
    /// One array of `Fold` values, which is an allocation per `Min`/`Max`/`Clamp`/`Hypot` node and is
    /// the cost the file header prices. Nothing here refers to the tree: a `Fold` is a `NumericLeaf`
    /// (four `Copyable` scalars), an alternative index or a blame, all `Escapable`, so there is no
    /// container-of-`~Escapable` problem to solve and no reason to reach for C++ to hold it.
    func foldChildren(
        _ node: borrowing WebCore.CSSCalc.CSSCalcSwiftNode,
        _ childCount: UInt32,
        _ builder: borrowing WebCore.CSSCalc.CSSCalcSwiftBuilder
    ) -> [Fold] {
        var folded: [Fold] = []
        // `Int(clamping:)` rather than `Int(_:)`, which traps where `Int` is narrower than `UInt32`.
        // A saturating capacity HINT cannot be wrong -- `append` grows regardless -- so this is the
        // one narrowing in the file where clamping is exact rather than a silent wrong answer.
        folded.reserveCapacity(Int(clamping: childCount))
        var index: UInt32 = 0
        while index < childCount {
            folded.append(fold(node.childInTreeOrder(index), builder))
            index += 1
        }
        return folded
    }

    /// The first child that declined, as the `Fold` to return, or `nil` when none did.
    ///
    /// Returns the child's own `.declined` value rather than its blame, so the blame cannot be
    /// re-wrapped wrongly at three call sites -- and so the signature is `Fold?` rather than the
    /// double optional a `CalcAlternative??` would need to distinguish "no decline" from "a decline
    /// with no blame".
    ///
    /// Checked over ALL children before any of the three folds below dispatches, and that ordering is
    /// deliberate: the C++'s `switchOn` can return `nullopt` after reading only one operand, but a
    /// declined child means the island cannot build this tree at all, whichever operand the C++ would
    /// have looked at. Declining is exact in every such case -- the C++ arm runs and produces whatever
    /// it would have produced -- so hoisting the check cannot change an answer, only which alternative
    /// gets the blame, and the blame is the child's either way.
    @inline(always)
    func declinedChild(_ folded: [Fold]) -> Fold? {
        for child in folded {
            if case .declined = child {
                return child
            }
        }
        return nil
    }

    /// `return { WTF::move(root.children[index]) }`: the node collapses to one of its own children.
    ///
    /// THE LEAF CASE IS NOT AN OPTIMISATION, it is required for exactness. The C++ returns the child
    /// itself, so the parent's `switchOn` sees whatever the child is -- and if the child is a
    /// `Numeric`, the parent can fold over it (`abs(min(1px))` folds to `1px`). Reporting
    /// `.replacedByTerm` there instead would make the parent treat a `Numeric` as a non-`Numeric`, and
    /// it is also what keeps `Fold`'s `.leaf` invariant true.
    @inline(always)
    func promoteTerm(_ folded: Fold, _ index: UInt32) -> Fold {
        switch folded {
        case .leaf(let leaf):
            return .leaf(leaf)
        case .declined(let blame):
            return .declined(blame)
        case .unchanged, .replacedByTerm, .replacedBySumTerm, .rebuiltMinMax, .mergedChildren:
            return .replacedByTerm(child: index)
        }
    }

    /// `promoteTerm` for a `Sum`, whose terms are addressed by ORIGIN ORDINAL rather than by child
    /// index because step 8.1 splices nested `Sum`s to any depth. See `Fold.replacedBySumTerm`.
    ///
    /// The leaf case carries the same requirement `promoteTerm`'s does: the C++ returns the term
    /// itself, so a `Numeric` term must reach the parent AS a leaf or the parent will treat a
    /// `Numeric` as a non-`Numeric` -- which is also what keeps `Fold`'s `.leaf` invariant exact.
    @inline(always)
    func promoteSumTerm(_ folded: Fold, _ origin: UInt32) -> Fold {
        switch folded {
        case .leaf(let leaf):
            return .leaf(leaf)
        case .declined(let blame):
            return .declined(blame)
        case .unchanged, .replacedByTerm, .replacedBySumTerm, .rebuiltMinMax, .mergedChildren:
            return .replacedBySumTerm(origin: origin)
        }
    }

    // MARK: `hypot()` -- A2a

    /// `simplify(Hypot&)` (`+Simplification.cpp:1204`-`:1279`).
    ///
    /// An optimistic state machine over the children, driven by
    /// `executeMathOperation<Hypot>(root.children.value, functor)`. The executor
    /// (CSSCalcExecutor.h:404-:422) has three shapes and all three are reproduced below:
    ///
    ///   - empty range: NaN, and THE FUNCTOR IS NEVER CALLED, so the tag stays `.unset` and the C++
    ///     returns `nullopt`;
    ///   - one element: `std::abs(f(c0))` -- `size()` does not call the functor, `*begin()` does, once;
    ///   - two or more: `sum += f(c) * f(c)` in order, then `std::sqrt(sum)`.
    ///
    /// The functor is called exactly once per element in tree order: `std::views::transform` is a lazy
    /// view, so the ordering is the loop's and not a materialised copy's.
    ///
    /// THE ABSORBING FAILURE STATE IS NOT SHORT-CIRCUITED, and that is a deliberate non-divergence.
    /// The C++ must keep evaluating after the failure bit is set "due to the evaluation API's
    /// interface"; Swift could `return` immediately and it would be OBSERVATIONALLY IDENTICAL, because
    /// the accumulated value is discarded whenever the tag is `.failed`. It is written as the full pass
    /// anyway so that the ported control flow matches the C++ it is checked against -- the accumulation
    /// is `sum += v*v` over doubles, and an early exit is exactly the kind of thing a later reader
    /// "optimises" into the wrong shape once the equivalence argument has scrolled off. It costs
    /// nothing: `hypot()`'s arity is 2 or 3 in real content.
    ///
    /// THE STATE MACHINE ONLY EVER RUNS OVER `.leaf` CHILDREN, and that is exact rather than a
    /// simplification: `.unchanged` and the other non-`.leaf` cases mean the C++'s `simplify` did not
    /// produce a `Numeric`, which reaches the `[&](const auto&)` arm of every one of the five tag
    /// states and therefore sets `FailureTag`. So `hypotElement` maps every non-`.leaf` child to
    /// `.failed` in one place instead of five.
    func foldHypot(
        _ node: borrowing WebCore.CSSCalc.CSSCalcSwiftNode,
        _ info: WebCore.CSSCalc.CSSCalcSwiftNodeInfo,
        _ builder: borrowing WebCore.CSSCalc.CSSCalcSwiftBuilder
    ) -> Fold {
        let folded = foldChildren(node, info.childCount, builder)
        if let declined = declinedChild(folded) {
            return declined
        }

        // The empty range, which never calls the functor.
        if folded.isEmpty {
            return .unchanged(.Hypot)
        }

        var tag = HypotTag.unset
        var sumOfSquares = 0.0
        var firstElement = 0.0
        var isFirst = true
        for child in folded {
            let value = hypotElement(child, &tag)
            if isFirst {
                firstElement = value
                isFirst = false
            }
            sumOfSquares += value * value
        }

        // `std::abs(*range.begin())` for one element, `std::sqrt(sum)` for two or more. `.magnitude`
        // is `std::abs(double)`: it clears the sign bit, so `hypot(-0px)` is `+0px` on both arms.
        let value = folded.count == 1 ? firstElement.magnitude : sumOfSquares.squareRoot()

        switch tag {
        case .number:
            return .leaf(NumericLeaf.number(value))

        case .percentage:
            // `makeChild(Percentage { .value = value, .hint = Type::determinePercentHint(
            // options.category) })` (`:1270`), and the hint IS PROVABLY 0 WHEREVER THIS RUNS, so the
            // boundary does not have to carry `determinePercentHint`'s answer for A2a.
            //
            // The proof, checked against both functions rather than assumed: `determinePercentHint`
            // (CSSCalcType.cpp:308-:330) returns non-`None` for exactly `LengthPercentage` and
            // `AnglePercentage`, and `percentageResolveToDimension` (`+Simplification.cpp:86`-`:107`)
            // is true for exactly the same two categories. This arm is reached only when the tag became
            // `.percentage`, which `hypotElement` does only when `percentageResolveToDimension` is
            // FALSE (`:1224`-`:1227` sets `FailureTag` otherwise). So the two disjoint conditions
            // cannot both hold and the hint cannot be non-zero here.
            //
            // IT IS STILL A COUPLING BETWEEN TWO FUNCTIONS IN TWO FILES THAT NOTHING IN THE PROGRAM
            // ENFORCES, and A2d is where it stops being free: `simplify(Sum&)` needs
            // `allowZeroValueLengthRemovalFromSum` and an `isLength` upcall anyway, so the one
            // `uint8_t` `percentHintForCategory` field rides along at zero size cost then. Recorded
            // here rather than added now, because A2a-A2c are deliberately a zero-new-C++ slice.
            return .leaf(NumericLeaf(
                kind: .percentage,
                value: value,
                unitType: UInt16(WebCore.CSSUnitType.Percentage.rawValue),
                percentHint: 0
            ))

        case .dimension(let canonicalUnit):
            // `makeChild(CanonicalDimension { .value = value, .dimension = tag.dimension })`. The unit
            // is the FIRST child's, carried through the tag, and every subsequent child was required
            // to match it.
            return .leaf(NumericLeaf(
                kind: .canonicalDimension,
                value: value,
                unitType: canonicalUnit,
                percentHint: 0
            ))

        case .unset, .failed:
            // The C++'s `[&](const auto&)` arm of the result switch: `nullopt`, so the node keeps its
            // own kind and is rebuilt from its children -- through the `Children` slot, at the same
            // arity. `.unset` is unreachable here (the empty case returned above), and is enumerated
            // beside `.failed` rather than defaulted so that a future tag has to be classified.
            return .unchanged(.Hypot)
        }
    }

    /// One iteration of `simplify(Hypot&)`'s functor: advance the tag and return the value the
    /// executor accumulates.
    ///
    /// `Double.nan` for every failure, which is `std::numeric_limits<double>::quiet_NaN()` at each of
    /// the C++'s five sites. The value is discarded whenever the tag ends `.failed`, so only the tag
    /// transition is observable -- but it is returned rather than skipped, because the C++ returns it.
    @inline(always)
    func hypotElement(_ folded: Fold, _ tag: inout HypotTag) -> Double {
        guard case .leaf(let leaf) = folded else {
            // Not a `Numeric`, which reaches the `[&](const auto&)` arm of whichever tag state is
            // live. Every one of them sets `FailureTag`, including `monostate`'s.
            tag = .failed
            return Double.nan
        }

        switch tag {
        case .unset:
            // `:1216`-`:1240`, the first iteration.
            switch leaf.kind {
            case .number:
                tag = .number
                return leaf.value
            case .percentage:
                if percentageResolveToDimension {
                    tag = .failed
                    return Double.nan
                }
                tag = .percentage
                return leaf.value
            case .canonicalDimension:
                tag = .dimension(leaf.unitType)
                return leaf.value
            case .nonCanonicalDimension:
                // A `Numeric`, but the C++ has no arm for it -- it falls to the same
                // `[&](const auto&)` a non-`Numeric` does. A `hypot()` over an unconverted `1em` is
                // therefore rebuilt rather than folded, which is right: its value is not yet in a
                // comparable unit.
                tag = .failed
                return Double.nan
            }

        case .number:
            // `if (auto* numberChild = get_if<Number>(&child)) return numberChild->value;`
            guard leaf.kind == .number else {
                tag = .failed
                return Double.nan
            }
            return leaf.value

        case .percentage:
            // `get_if<Percentage>(&child)`, which reads the VALUE only: a percentage's `hint` plays no
            // part in whether it matches, and the folded result's hint is stamped from the category
            // rather than inherited. See `foldHypot`'s `.percentage` arm.
            guard leaf.kind == .percentage else {
                tag = .failed
                return Double.nan
            }
            return leaf.value

        case .dimension(let canonicalUnit):
            // `get_if<CanonicalDimension>(&child); dimensionChild && dimensionChild->dimension ==
            // tag.dimension`, with the unit standing in for the dimension.
            guard leaf.kind == .canonicalDimension, leaf.unitType == canonicalUnit else {
                tag = .failed
                return Double.nan
            }
            return leaf.value

        case .failed:
            // Absorbing, and the loop keeps running. See `foldHypot`'s note on why this is not a
            // `return`.
            return Double.nan
        }
    }

    // MARK: `min()` and `max()` -- A2b

    /// `simplifyForMinMax` (`+Simplification.cpp:371`-`:482`), css-values-4 steps 5.1 to 5.3, for both
    /// `Min` and `Max` -- one function, as the C++ has one template.
    ///
    /// THREE PASSES WHERE THE C++ HAS TWO, and the extra one is what makes this safe rather than
    /// merely correct. The C++ mutates `root.children` while still iterating it: `:430` assigns
    /// `root.children[offset - 1] = evaluate(root.children[offset - 1], root.children[i])`, taking both
    /// operands by `const Child&` INTO the vector it then assigns; `:468` and `:475`
    /// `WTF::move(root.children[i])` out of elements inside a live loop whose next iteration
    /// `switchOn`s element `i + 1`. Both are correct today and both rest on invariants nothing states:
    /// that `offset - 1 < i` always, so `:430` is never a self-move, and that a moved-from `Variant`
    /// keeps its discriminant, so the loop's own dispatch never reads a hole.
    ///
    /// The island needs neither invariant, because it never mutates the tree: the merge runs over
    /// `NumericLeaf` VALUES, `withValue` is a copy, and the subtrees are read from the original tree
    /// through the `const` `childInTreeOrder`. Swift's exclusivity rules make `:430`'s shape
    /// inexpressible rather than merely unwritten, and there is no moved-from state to depend on.
    ///
    ///   1. fold every child, in tree order (`foldChildren`);
    ///   2. compute the merge plan as values (`mergePlan`);
    ///   3. `rewrite` makes the single consuming pass, once the plan is complete.
    ///
    /// The four outcomes, in the C++'s own order:
    ///   - one child: return it (`:408`);
    ///   - no merge opportunities: `nullopt`, rebuilt at the same arity (`:449`);
    ///   - `n - merges == 1`: return child 0 (`:455`);
    ///   - otherwise: the children are replaced by the survivors and `nullopt` is returned (`:479`),
    ///     which is `.mergedChildren` -- an arity change reported through a `nullopt` the C++ cannot
    ///     distinguish from the second case, which is why the island has two cases for it.
    func foldMinMax(
        _ node: borrowing WebCore.CSSCalc.CSSCalcSwiftNode,
        _ info: WebCore.CSSCalc.CSSCalcSwiftNodeInfo,
        _ isMax: Bool,
        _ builder: borrowing WebCore.CSSCalc.CSSCalcSwiftBuilder
    ) -> Fold {
        let alternative: CalcAlternative = isMax ? .Max : .Min
        let folded = foldChildren(node, info.childCount, builder)
        if let declined = declinedChild(folded) {
            return declined
        }

        // `if (root.children.size() == 1) return { WTF::move(root.children[0]) };` -- BEFORE the
        // merge, which is why a single-child `min()` folds to its child even when the child is a
        // percentage the merge would have refused.
        if folded.count == 1 {
            return promoteTerm(folded[0], 0)
        }

        let plan = mergePlan(folded, isMax)

        // `if (!numberOfMergeOpportunities) return { };`
        if plan.merges == 0 {
            return .unchanged(alternative)
        }

        // `if (combinedChildrenSize == 1) return { WTF::move(root.children[0]) };`
        //
        // TERM 0 IS ALWAYS THE SOLE SURVIVOR HERE, which is why the C++ writes `children[0]`
        // unconditionally and why this needs no search. Proof: term 0 has no earlier term to merge
        // into, so it always survives; a non-`Numeric` term and a percentage the merge skipped both
        // always survive; and any merge implies a first instance that survives. So if term 0 were not
        // the only survivor there would be two, contradicting `n - merges == 1`.
        if folded.count - plan.merges == 1 {
            if let accumulated = plan.slots[0].accumulated {
                return .leaf(accumulated)
            }
            // Term 0 is not a `Numeric`, so the answer is the subtree itself.
            return .replacedByTerm(child: 0)
        }

        return .mergedChildren(alternative)
    }

    /// One term's place in the merge: what it accumulated, whether anything may merge INTO it, and
    /// whether it survives.
    ///
    /// PER TERM, not per unit identity, and that is what removes the C++'s two dense tables. `:414` is
    /// a `std::array<size_t, numberOfNumericIdentityTypes>` -- 64 entries, 512 bytes zeroed on entry --
    /// mapping a `NumericIdentity` to "the first index in `root.children` with this unit, plus one",
    /// with a FIXME at `:413` asking for a type that hides the `static_cast<uint8_t>` from the caller.
    struct MergeSlot {
        /// The accumulated leaf, or `nil` when the term is not a `Numeric`. A value type, so a merge
        /// is a copy and there is nothing the tree can observe.
        var accumulated: NumericLeaf?
        /// Whether a LATER term may merge into this one, i.e. whether this term is a first instance in
        /// the C++'s table. Set only where the C++ writes `offsetOfFirstInstance[id] = i + 1`, so it is
        /// false for a non-`Numeric` term, for a percentage the merge skipped, and for every term that
        /// merged into an earlier one -- a merged term never had it set, exactly as the C++ never
        /// overwrites a table entry.
        var mergeable: Bool
        /// Whether the term appears in the rebuilt child list.
        var survives: Bool
        /// `FirstInstance::merges` (`:602`), and `Sum` ONLY -- how many later terms merged into this
        /// one. `simplifyForMinMax` has no per-bucket record at all (its table is one `size_t`), so
        /// `mergePlan` leaves this 0 and counts its merges in a running total instead. Carried on the
        /// shared slot rather than on a `Sum`-specific one so that the merge SCAN
        /// (`mergeTarget`) has one definition; `simplify(Sum&)` needs the per-bucket count because its
        /// two size outcomes read `childrenToRemoveFromMerges` and `childrenToRemoveTotal`
        /// separately, and only the second includes removals.
        var merges: UInt32
        /// `FirstInstance::canRemove` (`:603`), and `Sum` ONLY: this term is a zero-valued length that
        /// `allowZeroValueLengthRemovalFromSum` permits dropping. Left false by `mergePlan`, which has
        /// no removal rule -- `simplifyForMinMax` never drops a term.
        var canRemove: Bool
    }

    /// An empty slot: a term that has not been classified yet.
    ///
    /// One spelling of the initialiser, so that the two plans below cannot disagree about a field's
    /// resting value -- `survives` defaulting to `true` is the load-bearing one, because it is what
    /// makes a non-`Numeric` term survive by construction rather than by an arm that remembers to say
    /// so.
    @inline(always)
    func unclassifiedSlot() -> MergeSlot {
        return MergeSlot(accumulated: nil, mergeable: false, survives: true, merges: 0, canRemove: false)
    }

    /// `offsetOfFirstInstance[toNumericIdentity(child)]` / `firstInstances[...].offset`, as a scan.
    ///
    /// The earliest term `leaf` may merge into: the first `j < upTo` that is a first instance of the
    /// same `(kind, unitType)`. Shared by `mergePlan` and `sumMergePlan` because both C++ functions
    /// index the identical table with the identical key, and two spellings of a lookup are two things
    /// that can drift -- which matters here more than usual, since `simplify(Sum&)` and
    /// `simplifyForMinMax` differ in what they DO with the answer and not in how they find it.
    ///
    /// The scan CARRIES the accumulated leaf out with the index, rather than leaving the caller to
    /// re-read `slots[j].accumulated`. Returning the index alone would have left a fall-through where
    /// a set target with a `nil` leaf silently became a NEW first instance -- unreachable, since the
    /// scan is what checked it, but "unreachable and silently wrong" is the pairing this file avoids
    /// by construction wherever the spelling allows it.
    @inline(always)
    func mergeTarget(_ slots: [MergeSlot], _ upTo: Int, _ leaf: NumericLeaf) -> (index: Int, accumulated: NumericLeaf)? {
        for j in 0..<upTo where slots[j].mergeable {
            guard let accumulated = slots[j].accumulated else {
                continue
            }
            if switchTogether(accumulated, leaf), unitsMatch(accumulated, leaf) {
                return (j, accumulated)
            }
        }
        return nil
    }

    /// Phase 1 of `simplifyForMinMax` (`:418`-`:446`), as values.
    ///
    /// THE ISLAND HAS NO TABLE, and that is a deliberate answer to the C++'s FIXME rather than an
    /// omission. Two facts make it exact:
    ///
    ///   1. `CSSUnitType` is a BIJECTION onto `NumericIdentity` over every leaf the tree can hold.
    ///      `toNumericIdentity` is `Number` for a `Number`, `Percentage` for a `Percentage`, a six-way
    ///      map of `CanonicalDimension::Dimension` (CSSCalcTree+NumericIdentity.h:118-:131) and the
    ///      unit itself for a `NonCanonicalDimension` (`:133`) -- 64 identities against 64 units, one
    ///      to one. So the island keys the merge on the `unitType` it is ALREADY CARRYING in
    ///      `NumericLeaf`, needs no `toNumericIdentity` upcall, no dense index and no `static_cast`.
    ///   2. `offsetOfFirstInstance[id]` holds exactly "the first index in the prefix with this id",
    ///      which is what a linear scan over the already-materialised slots finds. For `n` terms that
    ///      is at most `n(n-1)/2` `UInt16` comparisons -- a `min()` has a handful of arguments --
    ///      against 512 bytes of `memset` per call.
    ///
    /// Checked against all three of the C++'s special cases: a skipped percentage never sets the table
    /// entry and is never a scan target here either (`mergeable` stays false); a non-`Numeric` term is
    /// never a target on either side; and two skipped percentages both survive on both sides.
    ///
    /// THE KEY IS THE PAIR `(kind, unitType)`, not the unit alone, and it is spelled with A1's own
    /// `switchTogether` + `unitsMatch` so there is one definition of "same numeric alternative, same
    /// unit" in the file. The single input where the pair and `toNumericIdentity` disagree is a
    /// `NonCanonicalDimension` holding a CANONICAL unit: the C++ hits `:133`'s `ASSERT_NOT_REACHED`
    /// branch and buckets it with the numbers, where the pair keys it on itself. `makeNumeric` cannot
    /// build one and no parse produces one, so it is unreachable through the boundary -- and the pair
    /// is at least self-consistent where the C++ is arbitrary.
    ///
    /// `evaluate` (`:392`-`:405`) is `executeMathOperation<Op>(a, b)` with a = the ACCUMULATOR, and it
    /// is `CalcExecutor.min`/`.max` -- the two-`double` executor overload, NOT the
    /// `minWithSignedZero`/`maxWithSignedZero` helpers. See `CalcExecutor.min`. With the executor's two
    /// NaN short-circuits the operation is commutative in `isnan` and the helpers are symmetric for
    /// `±0` (`min(+0,-0) == min(-0,+0) == -0`, `max` both `+0`), so for `Min`/`Max` the merge order
    /// cannot change the result -- it is still written in term index order, because it costs nothing
    /// and `Sum` next door genuinely depends on the order.
    func mergePlan(_ folded: [Fold], _ isMax: Bool) -> (slots: [MergeSlot], merges: Int) {
        var slots = [MergeSlot](repeating: unclassifiedSlot(), count: folded.count)
        var merges = 0
        // `bool canMergePercentages = !percentageResolveToDimension(options);` (`:416`).
        let canMergePercentages = !percentageResolveToDimension

        for i in 0..<folded.count {
            // `[](const auto&) { return 0; }`: a non-`Numeric` child contributes no merge
            // opportunity, is never merged, and always survives.
            guard case .leaf(let leaf) = folded[i] else {
                continue
            }

            // `if (id == NumericIdentity::Percentage && !canMergePercentages) return 0;` -- and the
            // table entry is LEFT UNSET, which is what makes phase 2 keep every such child. Its leaf
            // is still recorded, because phase 3 pushes it.
            //
            // THERE IS NO SUCH SKIP IN `simplify(Sum&)`, which merges percentages unconditionally --
            // see `sumMergePlan`, which is why the two plans are two functions rather than one with a
            // flag.
            if leaf.kind == .percentage, !canMergePercentages {
                slots[i].accumulated = leaf
                continue
            }

            if let target = mergeTarget(slots, i, leaf) {
                // `root.children[offset - 1] = evaluate(root.children[offset - 1], root.children[i]);`
                // `makeChildWithValueBasedOn(result, aNumeric)` with a = the accumulator, so the
                // surviving alternative, unit and percent hint are the FIRST instance's, which is
                // exactly what `withValue` carries.
                let merged = isMax
                    ? CalcExecutor.max(target.accumulated.value, leaf.value)
                    : CalcExecutor.min(target.accumulated.value, leaf.value)
                slots[target.index].accumulated = target.accumulated.withValue(merged)
                slots[i].survives = false
                merges += 1
            } else {
                // `offsetOfFirstInstance[id] = i + 1;` -- the first instance, not yet a merge
                // opportunity.
                slots[i].accumulated = leaf
                slots[i].mergeable = true
            }
        }

        return (slots, merges)
    }

    // MARK: `clamp()` -- A2c

    /// `simplify(Clamp&)` (`+Simplification.cpp:1008`-`:1105`).
    ///
    /// FOUR OUTCOMES, and the first is decided before the C++'s `switchOn` runs:
    ///
    ///   1. both bounds `none` -> return `val`, WHATEVER IT IS, numeric or not (`:1013`-`:1016`);
    ///   2. `val` is not a `Numeric` -> the `[](const auto&)` arm, `nullopt` (`:1101`-`:1103`). THIS
    ///      DOMINATES OUTCOMES 3 AND 4: `convertToMin`/`convertToMax` are inside the `Numeric T`
    ///      visitor, so `clamp(none, r, 1px)` over an unresolved symbol is REBUILT as a `Clamp` and is
    ///      not converted to a `min()`;
    ///   3. exactly one bound `none`, `val` a `Numeric` -> fold if the present bound is the same
    ///      alternative, its unit matches and `val` is `magnitudeComparable`; otherwise
    ///      `convertToMin()` / `convertToMax()`, which is the kind change;
    ///   4. neither bound `none`, `val` a `Numeric` -> fold if all three agree; otherwise `nullopt`.
    ///      NO CONVERSION IN THIS BRANCH.
    ///
    /// CHILD ORDER NEEDS NO REASONING AT THE CALL SITE, because `Clamp`'s tuple is `{ChildOrNone min;
    /// Child val; ChildOrNone max;}` (CSSCalcTree.h:399-:401) and `childInTreeOrder` skips a bound
    /// holding `none`. So min-none gives `[val, max]`, which is `Min { val, max }`'s order (`:1021`-
    /// `:1022`); max-none gives `[min, val]`, which is `Max { min, val }`'s (`:1035`-`:1036`);
    /// both-none gives `[val]`; and neither gives `[min, val, max]`.
    ///
    /// HOW THE FOUR ARE TOLD APART WITH NO BOUNDARY WORK. `info().childCount` gives the arity (3 / 2 /
    /// 1), because `ChildOrNone` holding `none` is not counted, and `info().kind` says WHICH bound is
    /// `none` in the arity-2 case through the existing `ClampWithNoneMinimum` / `ClampWithNoneMaximum`
    /// kinds. The arity is keyed on the COUNT and never on the kind -- `Operation` is the boundary's
    /// fallback kind, so a future operation would arrive wearing it -- and the two are cross-checked:
    /// a `childCount` of 2 requires one of the two `ClampWithNone*` kinds and no other count may carry
    /// one. That is the same "the island requires the two to AGREE and declines when they do not" rule
    /// the boundary already states for `hasFallback` (CSSCalcSwiftTypes.h:351-:355).
    func foldClamp(
        _ node: borrowing WebCore.CSSCalc.CSSCalcSwiftNode,
        _ info: WebCore.CSSCalc.CSSCalcSwiftNodeInfo,
        _ builder: borrowing WebCore.CSSCalc.CSSCalcSwiftBuilder
    ) -> Fold {
        let folded = foldChildren(node, info.childCount, builder)
        if let declined = declinedChild(folded) {
            return declined
        }

        let minimumIsNone = info.kind == .ClampWithNoneMinimum
        let maximumIsNone = info.kind == .ClampWithNoneMaximum

        // The cross-check. A `ChildOrNone` holding `none` is not counted by `childCount`, so exactly
        // one bound absent means two children and vice versa; anything else is a boundary that came
        // apart, and a decline runs the C++ arm rather than filling a bound with the wrong subtree.
        guard (info.childCount == 2) == (minimumIsNone || maximumIsNone) else {
            return .declined(.Clamp)
        }

        // `if (minIsNone && maxIsNone) return { WTF::move(root.val) };` -- child 0 is `val`, and this
        // fires whatever `val` is. `childCount == 1` IS that condition: `val` is a plain `Child` and is
        // always present, so one child means both bounds hold the keyword.
        if info.childCount == 1 {
            return promoteTerm(folded[0], 0)
        }

        if info.childCount == 3 {
            // Neither bound is `none`: `[min, val, max]`.
            guard case .leaf(let value) = folded[1] else {
                // `val` is not a `Numeric`. Outcome 2.
                return .unchanged(.Clamp)
            }
            // `if (!holdsAlternative<T>(minChild) || !holdsAlternative<T>(maxChild)) return { };`
            // where `T` is `val`'s alternative -- so this is `switchTogether` against `val` twice, and
            // a bound that is not a leaf at all fails it for the same reason the C++'s does.
            guard case .leaf(let minimum) = folded[0], case .leaf(let maximum) = folded[2],
                  switchTogether(value, minimum), switchTogether(value, maximum) else {
                return .unchanged(.Clamp)
            }
            guard unitsMatch(minimum, value), unitsMatch(value, maximum) else {
                return .unchanged(.Clamp)
            }
            // "As units already match, we only have to check that one of the arguments is
            // `magnitudeComparable`", and the C++ checks `val`.
            guard magnitudeComparable(value) else {
                return .unchanged(.Clamp)
            }
            return .leaf(value.withValue(CalcExecutor.clamp(minimum.value, value.value, maximum.value)))
        }

        // Exactly one bound is `none`, so there are two children.
        if minimumIsNone {
            // `[val, max]`, and `clamp(none, VAL, MAX)` is `min(VAL, MAX)`.
            guard case .leaf(let value) = folded[0] else {
                // Outcome 2 again, and it dominates the conversion: a non-`Numeric` `val` never
                // reaches `convertToMin`.
                return .unchanged(.Clamp)
            }
            guard case .leaf(let maximum) = folded[1], switchTogether(value, maximum),
                  unitsMatch(value, maximum), magnitudeComparable(value) else {
                // Every one of the C++'s three `return convertToMin()` sites (`:1051`, `:1056`,
                // `:1060`), plus the case where `max` did not fold to a `Numeric` at all -- which is
                // `!holdsAlternative<T>(maxChild)` and is the first of those three.
                return .rebuiltMinMax(isMax: false)
            }
            // `makeChildWithValueBasedOn(executeMathOperation<Min>(val.value, max.value), val)`. The
            // ARGUMENT ORDER IS LOAD-BEARING: with the executor's two NaN short-circuits the first NaN
            // operand is the one returned, so `(val, max)` and `(max, val)` differ.
            return .leaf(value.withValue(CalcExecutor.min(value.value, maximum.value)))
        }

        // `[min, val]`, and `clamp(MIN, VAL, none)` is `max(MIN, VAL)`.
        guard case .leaf(let value) = folded[1] else {
            return .unchanged(.Clamp)
        }
        guard case .leaf(let minimum) = folded[0], switchTogether(minimum, value),
              unitsMatch(minimum, value), magnitudeComparable(value) else {
            return .rebuiltMinMax(isMax: true)
        }
        // `makeChildWithValueBasedOn(executeMathOperation<Max>(min.value, val.value), val)` -- the
        // operands are `(min, val)` and the RESULT's shape is `val`'s, which is not symmetric with the
        // branch above and is why `withValue` is called on `value` in both.
        return .leaf(value.withValue(CalcExecutor.max(minimum.value, value.value)))
    }

    // MARK: `Sum` -- A2d

    /// `simplify(Sum&)` (`+Simplification.cpp:547`-`:714`), css-values-4 steps 8.1 to 8.4.
    ///
    /// The last of the five `Children`-slotted kinds, and the one that needed everything the other
    /// four did not: step 8.1's SPLICE, a per-bucket removal rule, and five size outcomes whose ORDER
    /// is load-bearing.
    ///
    /// STEP 8.1 IS WHY `Sum` NEEDED A NEW ADDRESS. `if any child is an IndirectNode<Sum>, replace each
    /// such child with its children` (`:554`-`:563`): the parent's own child list is rewritten before
    /// anything else happens, so its "children" from that point on are its TERMS, some of which are
    /// grandchildren -- or, at two levels of nesting, great-grandchildren, which is where the plan for
    /// this slice was wrong (see `Fold.replacedByTerm`). `collectSumTerms` produces the term list and
    /// numbers each term with the ordinal of the tree position it came from, and `pushSumTerm` resolves
    /// an ordinal back to a position by re-walking. One integer, any depth, no address to keep in step.
    ///
    /// THE TEST IS ON THE SIMPLIFIED CHILD, NOT THE INPUT ONE. The C++ examines `root.children` after
    /// `copyAndSimplifyChildren` has replaced them (`:1809`-`:1822` simplifies children first), so a
    /// child `Sum` that folded to a leaf is not an `IndirectNode<Sum>` any more and is not spliced.
    /// `isSpliceableSum` is that test, over the child's `Fold`.
    ///
    /// THE FIVE SIZE OUTCOMES, in the C++'s order, and the order decides two of them:
    ///
    ///   1. `!childrenToRemoveTotal` -> `nullopt` (`:652`). TOTAL, so it includes removals.
    ///   2. `size - childrenToRemoveFromMerges == 1` -> `children[0]` (`:656`). **`fromMerges`, NOT
    ///      `total`** -- so `calc(0px + 0px)` under the flag gives `calc(0px)` and does NOT remove the
    ///      survivor, even though that survivor is a removable zero length. This is the subtlest line
    ///      in the function and the one this slice was told to get exactly right.
    ///   3. `combinedChildrenSize == 0` -> `CanonicalDimension { 0, Length }` (`:663`), the "we removed
    ///      too much" result. Reachable only when every term is a removable zero length AND outcome 2
    ///      did not fire, i.e. two or more separate zero-length BUCKETS: `calc(0em + 0px)` at no
    ///      conversion data.
    ///   4. `combinedChildrenSize == 1` -> a SCAN for the single survivor (`:666`-`:687`). Unlike
    ///      `simplifyForMinMax`'s third outcome this is not index 0, because a removable index 0 shifts
    ///      the survivor.
    ///   5. otherwise -> the survivors replace the children and `nullopt` is returned (`:711`).
    ///
    /// AND OUTCOME 1 IS NOT `.unchanged` WHENEVER 8.1 FIRED, which is a trap the C++'s shape hides.
    /// `nullopt` from `simplify` means "the node keeps its kind", not "the node is unchanged" -- and by
    /// the time it is returned, `root.children` has ALREADY been replaced by the flattened list. So a
    /// `Sum` that spliced but merged nothing has a NEW ARITY and must be rebuilt from its terms, which
    /// is `.mergedChildren(.Sum)`; only a `Sum` that neither spliced nor merged is `.unchanged`.
    ///
    /// THE ARITY-ONE CHECK IS AFTER 8.1 TOO (`:594`), so it is the FLATTENED count that is tested.
    /// `calc((1px + 1em))`, whose parse nests one `Sum` inside another, has one child and two terms.
    func foldSum(
        _ node: borrowing WebCore.CSSCalc.CSSCalcSwiftNode,
        _ info: WebCore.CSSCalc.CSSCalcSwiftNodeInfo,
        _ builder: borrowing WebCore.CSSCalc.CSSCalcSwiftBuilder
    ) -> Fold {
        var origin: UInt32 = 0
        let terms = collectSumTerms(node, info.childCount, &origin, builder)
        if let declined = terms.declined {
            return declined
        }

        // `if (root.children.size() == 1) return { WTF::move(root.children[0]) };` (`:594`), on the
        // FLATTENED list. No merge has run, so the term's own fold is the answer.
        if terms.folds.count == 1 {
            return promoteSumTerm(terms.folds[0], terms.origins[0])
        }

        let plan = sumMergePlan(terms.folds, builder)

        // 1. `if (!childrenToRemoveTotal) return { };`
        if plan.removeTotal == 0 {
            // ... and the arity is the flattened one, which 8.1 may already have changed.
            return terms.folds.count == Int(info.childCount) ? .unchanged(.Sum) : .mergedChildren(.Sum)
        }

        // 2. `if ((root.children.size() - childrenToRemoveFromMerges) == 1) return { WTF::move(
        // root.children[0]) };`
        //
        // TERM 0 IS ALWAYS THE SOLE MERGE-SURVIVOR HERE, which is why the C++ writes `children[0]`
        // unconditionally and why this needs no search -- the same proof `foldMinMax` writes out: term
        // 0 has no earlier term to merge into, so it always survives the merges, and any merge implies
        // a first instance that survives, so two survivors would exist otherwise. Its `canRemove` bit
        // is deliberately NOT consulted, because this outcome is tested before removals are applied.
        if terms.folds.count - plan.merges == 1 {
            return promoteSumTerm(termFold(plan.slots, terms, 0), terms.origins[0])
        }

        let combined = terms.folds.count - plan.removeTotal

        // 3. `if (!combinedChildrenSize) return { makeChild(CanonicalDimension { 0, Length }) };`
        // "A value of type `length` is returned because the only kind of node that can be removed is
        // of type `length`", which is the C++'s own note and is what `canonicalLength` states.
        if combined == 0 {
            return .leaf(NumericLeaf.canonicalLength(0))
        }

        // 4. "If the new size is 1, we know there is one child, we just don't know which one yet."
        // The C++'s scan condition -- non-`Numeric`, or a first instance with `!canRemove` -- IS
        // `survives`, so this is the first surviving term.
        if combined == 1 {
            for k in 0..<plan.slots.count where plan.slots[k].survives {
                return promoteSumTerm(termFold(plan.slots, terms, k), terms.origins[k])
            }
            // Nothing survived, which the arithmetic above says cannot happen. The C++ falls out of
            // its own loop into the rebuild in exactly this case rather than asserting, so this does
            // too: `rebuildFrom` with zero operands would then be refused and the tree declines, which
            // is strictly safer than the C++'s empty `Sum`.
        }

        // 5. `root.children = WTF::move(combinedChildren); return { };`
        return .mergedChildren(.Sum)
    }

    /// The `Fold` a term's own result is, once the merge has run: the ACCUMULATED leaf for a `Numeric`
    /// term, and the term's own fold for a non-`Numeric` one.
    ///
    /// A function rather than an expression at the three outcome sites above, because getting it
    /// backwards is silent: `terms.folds[k]` for a merged first instance is the term's ORIGINAL leaf,
    /// which is the value before anything merged into it.
    @inline(always)
    func termFold(_ slots: [MergeSlot], _ terms: SumTermList, _ index: Int) -> Fold {
        if let accumulated = slots[index].accumulated {
            return .leaf(accumulated)
        }
        return terms.folds[index]
    }

    /// Whether step 8.1 splices this child's terms into the parent instead of taking it as one term.
    ///
    /// `WTF::holdsAlternative<IndirectNode<Sum>>(child)` (`:554`) on the SIMPLIFIED child, expressed
    /// over its `Fold`: the two cases in which `simplify` left the node a `Sum` are `nullopt`
    /// (`.unchanged`) and `nullopt` after replacing its children (`.mergedChildren`). Every other case
    /// replaced the node with something that is not a `Sum` -- `.leaf` and `.replacedBySumTerm` are
    /// `simplify(Sum&)`'s own three replacement outcomes, `.replacedByTerm` and `.rebuiltMinMax` belong
    /// to other kinds, and `.declined` never reaches here.
    ///
    /// The alternative is checked rather than assumed, because `.unchanged` and `.mergedChildren` are
    /// produced by six different folds in this file and only a `Sum`'s is spliced.
    @inline(always)
    func isSpliceableSum(_ folded: Fold) -> Bool {
        switch folded {
        case .unchanged(let alternative), .mergedChildren(let alternative):
            return alternative == .Sum
        case .leaf, .replacedByTerm, .replacedBySumTerm, .rebuiltMinMax, .declined:
            return false
        }
    }

    /// One `Sum`'s flattened term list, as VALUES.
    ///
    /// No node handle, which is the whole point: `CSSCalcSwiftNode` is `~Escapable`, so no Swift
    /// container accepts one, and reaching for C++ to hold the container is the mistake this project
    /// has a standing rule against. Everything here is `Copyable` and `Escapable` -- a `Fold` is four
    /// scalars, an alternative index or a blame -- so the list can be returned, stored and walked as
    /// many times as `fold` and `rewrite` need it.
    struct SumTermList {
        /// One entry per term of the flattened list, in order.
        var folds: [Fold] = []
        /// The ordinal of the tree position each term came from -- for a term that is itself the result
        /// of a nested `Sum`'s merge, its first instance's position. See `Fold.replacedBySumTerm`.
        var origins: [UInt32] = []
        /// The first child that declined, as the `Fold` to return. Same shape and same reason as
        /// `declinedChild`: returning the child's own value rather than its blame means the blame
        /// cannot be re-wrapped wrongly at the call sites.
        var declined: Fold?
    }

    /// Step 8.1, applied as deeply as the tree nests: `node`'s children in tree order, with every
    /// child that is still a `Sum` replaced by ITS OWN post-merge terms.
    ///
    /// RECURSIVE, AND THE RECURSION IS NOT THE SAME ONE `fold` MAKES. `fold` recurses to simplify a
    /// subtree; this recurses only through the SPLICE CHAIN -- children that are still `Sum`s -- and
    /// stops at every other child. The C++ writes one level because it does not have to write more: its
    /// children were simplified before it ran, so a child `Sum` has already spliced its own children,
    /// and `newChildren.appendVector(childSum->children.value)` therefore copies an already-flattened
    /// list. This reproduces that by re-deriving the child's flattened list here, which is the same
    /// answer computed the same way and is what makes the depth argument unnecessary rather than
    /// bounded.
    ///
    /// A SPLICED CHILD CONTRIBUTES ITS SURVIVORS, NOT ITS TERMS, and that is the whole content of "the
    /// C++ splices the SIMPLIFIED child's children": those children are what the child's own pass left
    /// behind, with its merges already accumulated and its removable zeros already gone. A `Numeric`
    /// survivor therefore enters the parent's list as its ACCUMULATED leaf, which exists nowhere in the
    /// input tree -- and that is also why the merge is two-stage rather than one: `+` is not
    /// associative, so `calc(1px + (2px + 3px))` must add `2 + 3` first and `1 + 5` second, exactly as
    /// the C++ does.
    ///
    /// `origin` is threaded through the WHOLE recursion rather than restarted per level, so an ordinal
    /// identifies a tree position across the entire splice chain. That is what lets one `UInt32` name a
    /// term at any depth.
    ///
    /// THE COST IS EXPONENTIAL IN THE NESTED-`Sum` DEPTH, and it is stated rather than left to be
    /// discovered. Each level calls `fold` on a spliceable child (which runs `collectSumTerms` inside
    /// `foldSum`) and then calls `collectSumTerms` on it again, so a chain of `d` nested `Sum`s costs
    /// `2^d` walks -- against the merely quadratic re-entry the file header prices for everything else.
    /// PRICED AND ACCEPTED FOR NOW, on a measurement rather than an intuition: `parseAndSimplify` runs
    /// `simplify(Sum&)` incrementally during the parse, so it performs step 8.1 itself and NO NESTED
    /// `Sum` SURVIVES A PARSE -- `calc(1px + (1em + (1rem + 1vw)))` arrives as a flat five-node `Sum`
    /// (measured, `cssprobe/validate/corpusprobe.cpp` note 8). So `d` is 0 for every tree that reaches
    /// this island through a stylesheet, and above 0 only while the island IS the parse's own
    /// simplifier, where the tree it sees is the one fragment being folded. If a measurement ever finds
    /// it, the fix is the one the file header already names for the quadratic case and is Swift-side:
    /// have `fold` hand its per-child results down rather than have each caller re-derive them.
    func collectSumTerms(
        _ node: borrowing WebCore.CSSCalc.CSSCalcSwiftNode,
        _ childCount: UInt32,
        _ origin: inout UInt32,
        _ builder: borrowing WebCore.CSSCalc.CSSCalcSwiftBuilder
    ) -> SumTermList {
        var out = SumTermList()
        // `Int(clamping:)` rather than `Int(_:)`, which traps where `Int` is narrower than `UInt32`. A
        // saturating capacity HINT cannot be wrong -- `append` grows regardless -- and the flatten can
        // exceed it anyway.
        out.folds.reserveCapacity(Int(clamping: childCount))
        out.origins.reserveCapacity(Int(clamping: childCount))

        var index: UInt32 = 0
        while index < childCount {
            let child = node.childInTreeOrder(index)
            let folded = fold(child, builder)
            if case .declined = folded {
                // Checked here rather than by a `declinedChild` sweep afterwards, because the splice
                // recurses and a declined grandchild has to stop the walk before its parent's plan is
                // computed over a list that is missing terms.
                out.declined = folded
                return out
            }

            if isSpliceableSum(folded) {
                let childInfo = child.info()
                let spliced = collectSumTerms(child, childInfo.childCount, &origin, builder)
                if let declined = spliced.declined {
                    out.declined = declined
                    return out
                }
                let childPlan = sumMergePlan(spliced.folds, builder)
                for k in 0..<childPlan.slots.count where childPlan.slots[k].survives {
                    out.folds.append(termFold(childPlan.slots, spliced, k))
                    out.origins.append(spliced.origins[k])
                }
            } else {
                out.folds.append(folded)
                out.origins.append(origin)
                origin += 1
            }
            index += 1
        }
        return out
    }

    /// `isLength(id) && options.allowZeroValueLengthRemovalFromSum` (`:611`), which is the only
    /// predicate in the whole island that needs a boundary call the other slices did not have.
    ///
    /// THREE OF THE FOUR NUMERIC KINDS ARE ANSWERED HERE, and only the fourth crosses:
    ///
    ///   - `.number` and `.percentage` are `NumericIdentity::Number` and `::Percentage`, neither of
    ///     which `isLength` admits (CSSCalcTree+NumericIdentity.h:280-:283);
    ///   - `.canonicalDimension` maps six-to-six onto `{PX, DEG, S, HZ, DPPX, FR}` and `isLength`
    ///     admits exactly `PX`, so the test is `unitType == Px` -- named from the real `CSSUnitType`,
    ///     the same way `foldDeg2Rad` names `Deg`;
    ///   - `.nonCanonicalDimension` is the real question, 48 of 56 units, and it is a generated table.
    ///     `isLengthUnit` is the upcall, and `CSSCalcSwiftTypes.h` records why a Swift DENYLIST of the
    ///     eight non-length units was rejected and why a free `bool` on `info()` was too.
    ///
    /// THE FLAG IS TESTED FIRST, so the upcall is not made at all in the configuration that cannot use
    /// its answer. That is a reordering of the C++'s `isLength(id) && options.allow...` and it is exact
    /// because `isLength` is pure.
    ///
    /// The CALLER gates on `value == 0` (`canRemove = canRemoveIfZero && !mergedValue`), so the upcall
    /// is reached only for a non-canonical dimension whose accumulated value is exactly zero, under a
    /// flag four production callers set: `calc(0em + 1px)` reaches it and nothing else in a stylesheet
    /// does. A memo per bucket was considered -- the value can reach zero again on a later merge, so
    /// `calc(0em + 1em + -1em)` calls twice -- and rejected as more state than that bound justifies.
    @inline(always)
    func lengthRemovalAllowed(
        _ leaf: NumericLeaf,
        _ builder: borrowing WebCore.CSSCalc.CSSCalcSwiftBuilder
    ) -> Bool {
        guard allowZeroValueLengthRemovalFromSum else {
            return false
        }
        switch leaf.kind {
        case .number, .percentage:
            return false
        case .canonicalDimension:
            return leaf.unitType == UInt16(WebCore.CSSUnitType.Px.rawValue)
        case .nonCanonicalDimension:
            return builder.isLengthUnit(leaf.unitType)
        }
    }

    /// Steps 8.2 to 8.4's first phase (`:607`-`:649`), as values: `simplifyForMinMax`'s `mergePlan`
    /// with three differences, all of them from the C++ and none of them shared.
    ///
    ///   1. THE PER-BUCKET RECORD IS `{offset, merges, canRemove}` (`:600`-`:604`) rather than one
    ///      `size_t`, because outcomes 1 and 2 read `childrenToRemoveTotal` and
    ///      `childrenToRemoveFromMerges` separately and only the first includes removals.
    ///   2. `canRemove` IS RECOMPUTED ON EVERY MERGE from the MERGED value (`:624`), not accumulated
    ///      and not taken from the first instance's own value. `calc(1em + -1em)` therefore becomes
    ///      removable through a merge, and `calc(0em + 1em)` stops being removable through one.
    ///   3. THERE IS NO PERCENTAGE SKIP. `Sum` merges percentages unconditionally; only
    ///      `simplifyForMinMax` consults `canMergePercentages` (`:416`, `:423`). Copying the skip across
    ///      would silently stop merging percentages in every `calc()` in a length-percentage property,
    ///      which is why the two plans are two functions and not one with a flag.
    ///
    /// Everything else is `mergePlan`'s and is shared: no dense table, the key is the `(kind, unitType)`
    /// pair through `mergeTarget`, and the accumulation runs in TERM INDEX ORDER. That last one is not
    /// cosmetic here the way it is for `Min`/`Max`: `+` is not associative, so
    /// `calc(1e300px + 1px + -1e300px)` depends on it.
    ///
    /// `evaluate` (`:577`-`:591`) is `executeMathOperation<Sum>(a, b)` = `a + b`, with a = the
    /// accumulator, and `makeChildWithValueBasedOn(result, aNumeric)` carries the FIRST instance's
    /// alternative, unit and percent hint -- which is exactly what `withValue` copies.
    func sumMergePlan(
        _ folded: [Fold],
        _ builder: borrowing WebCore.CSSCalc.CSSCalcSwiftBuilder
    ) -> (slots: [MergeSlot], merges: Int, removeTotal: Int) {
        var slots = [MergeSlot](repeating: unclassifiedSlot(), count: folded.count)

        for i in 0..<folded.count {
            // `[](const auto&) { }` (`:635`): "Non-numeric values are not eligible for merge or
            // removal." So a non-`Numeric` term always survives, on both arms -- the fact that makes
            // outcome 4's scan and the rebuild's own loop agree.
            guard case .leaf(let leaf) = folded[i] else {
                continue
            }

            if let target = mergeTarget(slots, i, leaf) {
                let merged = CalcExecutor.sum(target.accumulated.value, leaf.value)
                slots[target.index].accumulated = target.accumulated.withValue(merged)
                slots[target.index].merges += 1
                // `firstInstance.canRemove = canRemoveIfZero && !mergedValue;` (`:624`). `merged == 0`
                // is the C++'s `!mergedValue`: true for both `+0` and `-0`, false for a NaN.
                //
                // Spelled as an `if`/`else` rather than `&&` because `&&`'s right operand is an
                // `@autoclosure`, and a `borrowing` parameter cannot be captured by one -- the
                // compiler reports it as an escaping capture. Two things are load-bearing and both
                // are preserved exactly. The short circuit: `lengthRemovalAllowed` reaches a C++
                // upcall, and gating it on the merged value being zero is what keeps that upcall off
                // every non-zero term in every sum. And the `else`: this is an ASSIGNMENT, not an
                // accumulation, so a slot made removable by an earlier merge must be cleared when a
                // later one lands on it non-zero.
                if merged == 0 {
                    slots[target.index].canRemove = lengthRemovalAllowed(leaf, builder)
                } else {
                    slots[target.index].canRemove = false
                }
                slots[i].survives = false
            } else {
                // `firstInstances[id] = { .offset = i + 1, .merges = 0, .canRemove = canRemoveIfZero
                // && !child.value };` (`:629`-`:633`).
                slots[i].accumulated = leaf
                slots[i].mergeable = true
                // `&&` would capture `builder` in an autoclosure; see the merge arm above.
                if leaf.value == 0 {
                    slots[i].canRemove = lengthRemovalAllowed(leaf, builder)
                }
            }
        }

        // `for (auto& firstInstance : firstInstances) if (firstInstance.offset) { ... }` (`:644`-`:649`),
        // over the buckets rather than over the terms -- which is `mergeable`, since a bucket's
        // `offset` is set exactly where this file sets `mergeable`.
        var merges = 0
        var removeTotal = 0
        for i in 0..<slots.count where slots[i].mergeable {
            merges += Int(slots[i].merges)
            removeTotal += Int(slots[i].merges) + (slots[i].canRemove ? 1 : 0)
            if slots[i].canRemove {
                // The rebuild's own condition, `(firstInstance.offset - 1) == i && !canRemove`
                // (`:699`), folded into the slot so that the three sites that ask "does this term
                // appear in the output" ask it in one spelling.
                slots[i].survives = false
            }
        }

        return (slots, merges, removeTotal)
    }
}

// MARK: - Building the answer

private extension CalcSimplification {

    /// Push exactly ONE operand for this subtree, and report whether the island can continue.
    ///
    /// The contract in both directions, because `rebuildFrom`'s correctness rests on it: on
    /// `.pushed` the operand stack has grown by exactly one, and on `.declined` the caller must
    /// abandon the tree without inspecting the stack at all.
    ///
    /// Eight shapes, in the order they are tried:
    ///
    ///  1. The subtree folds to a numeric leaf -- `pushLeaf`, and none of its children are ever
    ///     built at all. That is not just an allocation saved: a folded subtree in the C++ arm
    ///     builds every intermediate `Child` and then throws them away.
    ///  2. The subtree is an unresolved `Symbol` -- `pushCopyOf`, which routes to
    ///     `CSSCalc::copy(const Child&)`, the same copy `copyAndSimplifyChildren` bottoms out in.
    ///  3. The subtree collapses to one of its own children -- push that child's operand and nothing
    ///     else, which is still exactly one operand. A2.
    ///  4. A `Sum` that collapses to one of its own flattened TERMS -- the same thing, addressed by
    ///     ordinal because step 8.1 spliced the term in from any depth. A2d.
    ///  5. A `clamp()` that became a `min()` or a `max()` -- push its two arguments and `buildMinMax`.
    ///     A2c, and the only place the island asks for a kind that was not in the input.
    ///  6. A `min()`/`max()` whose children merged -- push one operand per survivor and `rebuildFrom`
    ///     with the NEW count. A2b, and the first thing in the port to change an arity.
    ///  7. A `Sum` whose terms merged, were removed, or were SPLICED IN -- the same, over the
    ///     flattened list rather than over the children, so the new count can be larger than the old
    ///     as well as smaller. A2d.
    ///  8. Anything else in scope -- rewrite each child in tree order, then `rebuildFrom`, which
    ///     recovers the operation from the original's own variant tag.
    ///
    /// UNLIKE THE COVERAGE WALK, THIS STOPS AT THE FIRST DECLINE, and the asymmetry is deliberate:
    /// the walk keeps going because the mask and the count have to describe the whole tree, while
    /// here there is nothing left to learn and every further push is work on a stack that will be
    /// destroyed unread.
    mutating func rewrite(
        _ node: borrowing WebCore.CSSCalc.CSSCalcSwiftNode,
        _ builder: inout WebCore.CSSCalc.CSSCalcSwiftBuilder
    ) -> Rewrite {
        switch fold(node, builder) {
        case .declined(let blame):
            return .declined(blame)

        case .leaf(let leaf):
            // `false` here is a contract violation rather than an input the island can meet --
            // `pushLeaf` only refuses a `kind` outside the four numeric leaves, and every leaf this
            // file builds is one of them. It is still checked rather than asserted, so that a
            // boundary that came apart is a fallback to the C++ arm and not a tree built from an
            // operand that was never pushed. Blamed as `nil`, because the alternative that could not
            // be pushed is the leaf the island itself synthesised rather than anything in the input.
            return builder.pushLeaf(leaf.boundaryLeaf) ? .pushed : .declined(nil)

        case .replacedByTerm(let child):
            // `return { WTF::move(root.children[i]) }`. `rewrite` on the named child pushes exactly
            // one operand and NOTHING is pushed for the node itself, which is the whole reason the
            // fold/rewrite split exists: a `pop` on the builder would otherwise be the only way to
            // undo the children this node no longer has.
            return rewrite(node.childInTreeOrder(child), &builder)

        case .replacedBySumTerm(let origin):
            // The same thing for a `Sum`, whose terms are not its children: step 8.1 spliced them in
            // from any depth, so the answer is addressed by ordinal and resolved by re-walking.
            return rewriteSumTerm(node, origin, &builder)

        case .rebuiltMinMax(let isMax):
            return rewriteConvertedMinMax(node, isMax, &builder)

        case .mergedChildren(let alternative):
            // `Sum` has its own consuming pass, because its survivors are terms of the flattened list
            // rather than children of the node -- see `rewriteSumChildren`. `Min` and `Max` are the
            // only other producers of this case and their survivors ARE children.
            if alternative == .Sum {
                return rewriteSumChildren(node, &builder)
            }
            return rewriteMergedChildren(node, alternative, &builder)

        case .unchanged(let alternative):
            return rebuild(node, alternative, &builder)
        }
    }

    /// `convertToMin` / `convertToMax` (`+Simplification.cpp:1018`-`:1044`): a fresh `min()` or
    /// `max()` over `clamp()`'s two surviving arguments.
    ///
    /// Children 0 and 1 in tree order, which for both shapes is already the right argument order --
    /// see `foldClamp`. `buildMinMax` is the one construction selector on the boundary and this is its
    /// only caller.
    ///
    /// A FALSE FROM `buildMinMax` IS A WHOLE-TREE DECLINE, and it has to be. `convertToMin` computes
    /// `toType(min)` and returns `std::nullopt` when the children's types do not merge, at which point
    /// the C++ `simplify` returns `nullopt` and rebuilds the `Clamp` itself. The island cannot do that:
    /// by the time `buildMinMax` answers false, two operands have been pushed where the parent expects
    /// one, and there is no `pop`. Declining is exact -- the C++ arm runs and rebuilds the `Clamp` --
    /// and it is the same shape as `Invert`'s rule 7.2. Adding a `toTypeWouldSucceed` query to the
    /// boundary to avoid it was rejected: new C++ for a branch the parser's own type check should make
    /// unreachable. The differential counts it under guard 3d rather than failing, and its count is
    /// expected to be ZERO -- a non-zero one means that type check is weaker than this argument
    /// assumes, which is a finding rather than a tolerance.
    mutating func rewriteConvertedMinMax(
        _ node: borrowing WebCore.CSSCalc.CSSCalcSwiftNode,
        _ isMax: Bool,
        _ builder: inout WebCore.CSSCalc.CSSCalcSwiftBuilder
    ) -> Rewrite {
        var index: UInt32 = 0
        while index < 2 {
            if case .declined(let blame) = rewrite(node.childInTreeOrder(index), &builder) {
                return .declined(blame)
            }
            index += 1
        }
        return builder.buildMinMax(isMax, 2) ? .pushed : .declined(.Clamp)
    }

    /// The `.mergedChildren` half of `rewrite`: `simplifyForMinMax`'s phase 2 and its assignment to
    /// `root.children` (`:458`-`:479`), as the single consuming pass.
    ///
    /// THE PLAN IS RECOMPUTED HERE, which is the constant-factor cost the file header prices and the
    /// one thing about A2b worth revisiting if a measurement finds it. Having `.mergedChildren` carry
    /// the survivor list instead would remove the second pass and put a heap allocation on a `Fold`
    /// value that is built for every node at every level; the fix, if it is ever wanted, is still
    /// Swift-side and needs no boundary change.
    ///
    /// A `Numeric` SURVIVOR IS PUSHED AS A LEAF RATHER THAN RE-REWRITTEN, and that is required rather
    /// than an optimisation: an unmerged first instance is `children[i]` unchanged and would push the
    /// same value, but a MERGED first instance is `evaluate(...)`'s result and exists nowhere in the
    /// input tree. One path for both is exact, because `NumericLeaf` carries everything
    /// `makeChildWithValueBasedOn` carries -- the alternative, the unit and the percent hint.
    mutating func rewriteMergedChildren(
        _ node: borrowing WebCore.CSSCalc.CSSCalcSwiftNode,
        _ alternative: CalcAlternative,
        _ builder: inout WebCore.CSSCalc.CSSCalcSwiftBuilder
    ) -> Rewrite {
        let info = node.info()
        let folded = foldChildren(node, info.childCount, builder)
        let plan = mergePlan(folded, alternative == .Max)

        // The index is carried as a `UInt32` beside the iteration rather than converted from the
        // array's `Int`, so there is no narrowing to justify: `childInTreeOrder` wants a `UInt32` and
        // `plan.slots` is in tree order by construction.
        var index: UInt32 = 0
        var survivors: UInt32 = 0
        for slot in plan.slots {
            defer { index += 1 }
            guard slot.survives else {
                continue
            }
            if let accumulated = slot.accumulated {
                guard builder.pushLeaf(accumulated.boundaryLeaf) else {
                    // A contract violation, as in `rewrite`'s `.leaf` arm: the leaf is one the island
                    // synthesised, so there is no input alternative to blame.
                    return .declined(nil)
                }
            } else if case .declined(let blame) = rewrite(node.childInTreeOrder(index), &builder) {
                return .declined(blame)
            }
            survivors += 1
        }

        // `root.children = WTF::move(combinedChildren)`, expressed as a count: `rebuildSlot(const
        // Children&)` takes ALL the remaining operands and deliberately ignores the original's own
        // count, which is the line that lets an arity change happen at all.
        return builder.rebuildFrom(node, survivors) ? .pushed : .declined(alternative)
    }

    /// The `.mergedChildren(.Sum)` half of `rewrite`: `simplify(Sum&)`'s step 8.1 and its final
    /// consuming loop (`:689`-`:711`), as the single pass.
    ///
    /// SEPARATE FROM `rewriteMergedChildren` BECAUSE A `Sum`'s SURVIVORS ARE NOT ITS CHILDREN. The
    /// merged `min()` next door pushes `node.childInTreeOrder(index)` for a non-`Numeric` survivor,
    /// because its terms and its children are the same list. `Sum`'s are not: step 8.1 replaced the
    /// child list with the flattened one, so a survivor can be a grandchild, or deeper. Every
    /// non-`Numeric` survivor is therefore reached through `pushSumTerm`, which resolves an ordinal by
    /// re-walking the splice chain.
    ///
    /// THE COUNT CAN GO UP AS WELL AS DOWN, which nothing before A2d could do: `calc(1px + (1em + 1%))`
    /// arrives with two children and rebuilds with three. `rebuildSlot(const Children&)` takes all the
    /// remaining operands and deliberately ignores the original's count, so it serves both directions
    /// without knowing which happened.
    ///
    /// The plan is recomputed here, which is the constant-factor cost the file header prices and which
    /// `rewriteMergedChildren` pays too -- and for `Sum` it is paid once per splice level, since
    /// `collectSumTerms` re-derives each nested `Sum`'s plan as well.
    mutating func rewriteSumChildren(
        _ node: borrowing WebCore.CSSCalc.CSSCalcSwiftNode,
        _ builder: inout WebCore.CSSCalc.CSSCalcSwiftBuilder
    ) -> Rewrite {
        let info = node.info()
        var origin: UInt32 = 0
        let terms = collectSumTerms(node, info.childCount, &origin, builder)
        if case .declined(let blame) = terms.declined {
            // Unreachable: `fold` returned `.mergedChildren(.Sum)`, which it does only after the same
            // walk found no declining child. Checked rather than asserted, so that a boundary that came
            // apart is a fallback to the C++ arm rather than a tree built from a short term list.
            return .declined(blame)
        }
        let plan = sumMergePlan(terms.folds, builder)

        var survivors: UInt32 = 0
        for k in 0..<plan.slots.count where plan.slots[k].survives {
            if let accumulated = plan.slots[k].accumulated {
                // A `Numeric` survivor is pushed as a LEAF rather than re-rewritten, and that is
                // required rather than an optimisation, for the reason `rewriteMergedChildren` states
                // at length: a merged first instance is `evaluate(...)`'s result and exists nowhere in
                // the input tree. For a spliced term it is doubly so -- the value was accumulated by a
                // NESTED `Sum`'s pass.
                guard builder.pushLeaf(accumulated.boundaryLeaf) else {
                    return .declined(nil)
                }
            } else {
                var counter: UInt32 = 0
                guard let pushed = pushSumTerm(node, info.childCount, terms.origins[k], &counter, &builder) else {
                    // The ordinal named a position the re-walk did not reach, which can only mean the
                    // two walks disagreed. A decline rather than a trap: the C++ arm then produces the
                    // tree and the differential reports the decline against a handled alternative,
                    // which is a visible finding rather than a crash.
                    return .declined(.Sum)
                }
                if case .declined(let blame) = pushed {
                    return .declined(blame)
                }
            }
            survivors += 1
        }

        return builder.rebuildFrom(node, survivors) ? .pushed : .declined(.Sum)
    }

    /// The `.replacedBySumTerm` half of `rewrite`: push the one flattened term the `Sum` collapsed to,
    /// and nothing else.
    mutating func rewriteSumTerm(
        _ node: borrowing WebCore.CSSCalc.CSSCalcSwiftNode,
        _ origin: UInt32,
        _ builder: inout WebCore.CSSCalc.CSSCalcSwiftBuilder
    ) -> Rewrite {
        let info = node.info()
        var counter: UInt32 = 0
        guard let pushed = pushSumTerm(node, info.childCount, origin, &counter, &builder) else {
            return .declined(.Sum)
        }
        return pushed
    }

    /// Resolve an origin ordinal back to the tree position it names, and rewrite that subtree.
    ///
    /// THE MIRROR OF `collectSumTerms`, AND IT HAS TO STAY ONE. Both walk `node`'s children in tree
    /// order, both call `fold` on each, and both test `isSpliceableSum` on the answer -- so both visit
    /// the same positions in the same order and assign the same ordinals. `collectSumTerms` numbers the
    /// non-spliceable ones; this counts them and stops at `target`. Nothing else is shared, and nothing
    /// else needs to be: the two are three lines each of the same loop, and the predicate they both
    /// turn on is one function.
    ///
    /// `nil` means "not in this subtree", which at the top level means the ordinal was out of range and
    /// the caller declines. It is not folded into `Rewrite` as a third case, because "the walk found
    /// nothing" and "the walk found it and the push failed" need different answers at the call site and
    /// a single enum would let one be mistaken for the other.
    mutating func pushSumTerm(
        _ node: borrowing WebCore.CSSCalc.CSSCalcSwiftNode,
        _ childCount: UInt32,
        _ target: UInt32,
        _ counter: inout UInt32,
        _ builder: inout WebCore.CSSCalc.CSSCalcSwiftBuilder
    ) -> Rewrite? {
        var index: UInt32 = 0
        while index < childCount {
            let child = node.childInTreeOrder(index)
            let folded = fold(child, builder)
            if case .declined(let blame) = folded {
                return .declined(blame)
            }
            if isSpliceableSum(folded) {
                let childInfo = child.info()
                if let found = pushSumTerm(child, childInfo.childCount, target, &counter, &builder) {
                    return found
                }
            } else {
                if counter == target {
                    // `rewrite` on the term pushes exactly one operand, which is what the collapsed
                    // `Sum` owes its parent.
                    return rewrite(child, &builder)
                }
                counter += 1
            }
            index += 1
        }
        return nil
    }

    /// The `.unchanged` half of `rewrite`: the node keeps its own alternative and is rebuilt from
    /// its simplified children.
    mutating func rebuild(
        _ node: borrowing WebCore.CSSCalc.CSSCalcSwiftNode,
        _ alternative: CalcAlternative,
        _ builder: inout WebCore.CSSCalc.CSSCalcSwiftBuilder
    ) -> Rewrite {
        let info = node.info()

        if alternative == .Symbol {
            // An unresolved `<calc-keyword>`. A leaf, so `rebuildFrom` would refuse it -- there are
            // no slots to fill -- and a deep copy is what `copyAndSimplify` does for it.
            builder.pushCopyOf(node)
            return .pushed
        }

        var index: UInt32 = 0
        while index < info.childCount {
            // TREE order, and `rebuildFrom` fills the operation's slots from the operands in the
            // order they were pushed -- so this loop and `RebuildCursor` are one mechanism. Using
            // `childAt` here instead would reorder a `Sum`'s terms by unit; A1 declines `Sum`, and
            // the loop is still written against the order that is correct for every alternative.
            let child = rewrite(node.childInTreeOrder(index), &builder)
            if case .declined(let blame) = child {
                return .declined(blame)
            }
            index += 1
        }

        // Pops `childCount` operands and pushes one node of the ORIGINAL's kind. `false` is a
        // decline rather than an impossibility: it covers a leaf, an `Anchor`/`AnchorSize` whose
        // tuple conformance is a lie, and an arity that does not match a fixed-slot operation.
        return builder.rebuildFrom(node, info.childCount) ? .pushed : .declined(alternative)
    }
}

// MARK: - The entry point

/// Simplify a whole tree onto the builder's operand stack, or decline.
///
/// On `.simplified` the stack holds exactly one operand, the new root. On `.declined` the stack
/// holds whatever the abandoned rewrite left on it and the caller must not read it -- which is what
/// `trySimplifyWithSwiftIsland` does, destroying it unread and running the C++ arm.
///
/// `kindMask` and `nodeCount` come back from the coverage walk rather than from the rewrite, and
/// deliberately: they have to describe every tree the gate saw, including the ones it declined,
/// because coverage measured only on the cases that succeeded is not a coverage measurement. A
/// decline is invisible in an output comparison -- both arms run the C++ and agree by construction
/// -- and so is a walk that never descended. These two are what stop the differential from passing
/// vacuously, and they are keyed on the ALTERNATIVE index 0 to 40, not on the 23 serialization
/// kinds.
@_expose(Cxx)
public func cssCalcSimplifySwift(
    _ root: WebCore.CSSCalc.CSSCalcSwiftNode,
    _ builder: inout WebCore.CSSCalc.CSSCalcSwiftBuilder,
    _ options: WebCore.CSSCalc.CSSCalcSwiftSimplificationOptions
) -> WebCore.CSSCalc.CSSCalcSwiftSimplificationResult {
    var nodeCount: UInt32 = 0
    var kindMask: UInt64 = 0
    var blame: CalcAlternative?

    // Unconditional, so that the count and the mask describe every tree and not only the ones the
    // island could take.
    let everyNodeSimplifiable = walk(root, &nodeCount, &kindMask, &blame)

    guard everyNodeSimplifiable else {
        return declined(kindMask, nodeCount, blame)
    }

    var simplification = CalcSimplification(
        percentageResolveToDimension: options.percentageResolveToDimension,
        allowZeroValueLengthRemovalFromSum: options.allowZeroValueLengthRemovalFromSum
    )

    if case .declined(let rewriteBlame) = simplification.rewrite(root, &builder) {
        // The rewrite's blame, not the walk's: the walk found nothing to blame or we would not be
        // here, so this is a decline the coverage predicate could not have predicted -- `Invert`'s
        // rule 7.2, or a builder contract that came apart. Those are exactly the ones worth naming,
        // and the harness counts them per alternative rather than failing on them: a decline that
        // names a HANDLED alternative is legitimate, and only a `nil` blame is a contract violation.
        return declined(kindMask, nodeCount, rewriteBlame)
    }

    return WebCore.CSSCalc.CSSCalcSwiftSimplificationResult(
        kindMask: kindMask,
        nodeCount: nodeCount,
        outcome: CSSCalcSwiftSimplificationOutcome.simplified.rawValue,
        declineAlternative: noDeclineAlternative
    )
}

/// `CSSCalcSwiftSimplificationResult::declineAlternative`'s "did not decline, or declined without
/// one alternative to blame" value.
///
/// Spelled here once rather than as `0xFF` at four call sites. It is a sentinel in a field whose
/// other values are a `CSSCalcSwiftAlternative` raw value, and the boundary picked it because the
/// enum has 41 enumerators and cannot reach it -- `numberOfCSSCalcSwiftAlternatives` is counted from
/// the macro list and `static_assert`ed against `std::variant_size_v<Node>`, so growing the variant
/// past 255 alternatives is the only way to collide and that is a build failure elsewhere first.
private let noDeclineAlternative: UInt8 = 0xFF

/// A declined result, with the blame filled in.
@inline(always)
private func declined(_ kindMask: UInt64, _ nodeCount: UInt32, _ blame: CalcAlternative?) -> WebCore.CSSCalc.CSSCalcSwiftSimplificationResult {
    return WebCore.CSSCalc.CSSCalcSwiftSimplificationResult(
        kindMask: kindMask,
        nodeCount: nodeCount,
        outcome: CSSCalcSwiftSimplificationOutcome.declined.rawValue,
        declineAlternative: blame.map { $0.rawValue } ?? noDeclineAlternative
    )
}

// MARK: - The second entry point

/// Whether simplifying this tree could change it: a port of `canSimplify`
/// (`+Simplification.cpp`'s `canSimplifyWithCpp`).
///
/// THE PREDICATE IT PORTS IS VERY NEARLY VACUOUS, and that is recorded here rather than left for a
/// reader to discover from a green differential. The C++ **ignores its `SimplificationOptions`
/// entirely** -- the parameter is unnamed in the definition -- and switches only on the ROOT
/// alternative: `false` for `Number`, `Percentage` and `CanonicalDimension`, `true` for the other
/// 38, every operator included. So it carries ONE BIT PER TREE, and it **cannot be wrong about any
/// tree whose root is an operator**, which is most trees that reach it. An arm-versus-arm agreement
/// count over this function is therefore close to no evidence at all, and this port must not be read
/// as covered because that count is green. `simplifycheck.cpp`'s guard 10 prints the true/false
/// split for exactly that reason, and guard 10b carries the check that does have information in it:
/// `canSimplify(t) == false` must imply `copyAndSimplify(t) == t`, which the C++ satisfies only
/// because those three alternatives' `simplify` overloads are unconditional no-ops.
///
/// TAKING NO OPTIONS IS THE FAITHFUL PORT, not an omission, and the C++ entry's signature says so
/// too. If a future `canSimplify` starts reading them -- the NOTE at the C++ definition says a more
/// precise implementation is possible -- this signature has to grow with it, and the fact that it
/// does not take them today is the record of that.
///
/// TOTAL, SO THERE IS NO DECLINE CHANNEL. It is a `switch` on a discriminant with no operand to fail
/// on, so it returns a plain `Bool` and the C++ entry has no fallback arm for it. The three `false`
/// cases are enumerated and the other 38 are enumerated too rather than swept into a catch-all, for
/// the same reason `isSimplifiableAlternative` enumerates: an alternative added to `CSSCalcTree.h`
/// should be a compile error here, not a node silently claimed.
@_expose(Cxx)
public func cssCalcCanSimplifySwift(_ root: WebCore.CSSCalc.CSSCalcSwiftNode) -> Bool {
    switch root.info().alternative {
    case .Number, .Percentage, .CanonicalDimension:
        // The three the C++ names explicitly. Note that `NonCanonicalDimension` is NOT among them:
        // its `simplify` canonicalizes when there is conversion data, so it really can change.
        return false

    case .NonCanonicalDimension, .Symbol, .SiblingCount, .SiblingIndex,
         .Sum, .Product, .Negate, .Invert, .Deg2Rad,
         .Min, .Max, .Clamp,
         .RoundNearest, .RoundUp, .RoundDown, .RoundToZero, .Mod, .Rem,
         .Sin, .Cos, .Tan, .Asin, .Acos, .Atan, .Atan2,
         .Pow, .Sqrt, .Hypot, .Log, .Exp, .Abs, .Sign,
         .Random, .Progress, .ProgressNoClamp, .CalcMix, .Anchor, .AnchorSize:
        // The C++'s `[&](auto const&) -> bool { return true; }` catch-all, written out.
        return true

    @unknown default:
        // An alternative C++ grew and this file has not been taught. `true` is what the C++
        // catch-all would answer for it, so this stays a port rather than becoming a divergence --
        // and `true` is the conservative direction anyway: it only ever says "simplifying might
        // change something", which costs a simplification pass and cannot produce a wrong tree.
        return true
    }
}
