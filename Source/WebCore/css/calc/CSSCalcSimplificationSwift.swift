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

// Only these boundary types are imported, not the WebCore_Private umbrella; see
// CSSCalcSwiftTypes.h.
public import WebCore_Private.CSSCalcSwiftTypes

// The CSS unit vocabulary plus the conversion constants `canonicalize` multiplies by.
//
// `CSSUnits.h` is not self-contained, so the constants are split into namespace-scope `constexpr
// double`s, which import cleanly. `internal`, not `public`, because a `public` Swift signature
// naming an imported C++ enum is refused under library evolution.
internal import WebCore_Private.CSSUnitsSwiftTypes

// The three <angle> conversion constants. Imported through the submodule rather than plain
// `import wtf`, which does not see them under WTF's umbrella module map.
internal import wtf.Core.MathExtras

// libm, for the trig/pow/log/exp functions the C++ arm calls directly (`std::sin` on Darwin is
// `::sin`), so both arms reach the same functions. Everything else the executors need is stdlib.
import Darwin

// Swift port of CSSCalcTree+Simplification.cpp's calc() simplification, selected by
// USE_SWIFT_CSS_CALC_SIMPLIFICATION.
//
// WHY THIS IS A SECOND SWIFT PASS OVER THE SAME TREE, AND WHAT IT ADDS. The serializer next
// door only ever READS a tree. This one rewrites it, and the whole boundary question that shaped
// the design is how a node gets CONSTRUCTED without the operation kind crossing. The answer, which
// CSSCalcSwiftTypes.h states at length, is that it never has to: simplification is a tree-to-tree
// rewrite in which the output node's kind is the input node's kind everywhere except one rule, so
// `rebuildFrom` recovers the operation from the ORIGINAL node's own variant tag and this file
// supplies only operands and a count.
//
// What this file simplifies. Every tree whose every node is one of
//
//   - the four numeric leaves, and `Symbol` at any unit its table resolves to,
//   - `Invert` and `Deg2Rad`, the two implementation-only wrappers,
//   - 21 of the 34 operations: `mod`, `rem`, `round` in all four strategies, the six
//     trig functions, `atan2`, `pow`, `sqrt`, `log`, `exp`, `abs`, `sign`, `progress` and
//     `progress(no-clamp ...)`,
//   - and four more: `hypot()`, `min()`, `max()` and `clamp()`.
//
// Everything else declines, and a decline is a WHOLE-TREE decline: the C++ arm runs and the Swift
// operand stack is destroyed unread. That is why this file needs no equivalent of the
// serializer's "the walk is the decline decision" rule -- a `StringBuilder` cannot be
// un-appended, but a local `Vector<Child>` can simply be dropped.
//
// The kinds still declined, and each for its own reason: `Sum` and `Product` (whose rules
// reassociate and reorder), `Negate` (whose rules 6.2 to 6.4 rewrite a *child's* children in place),
// `CalcMix` (normalisation over per-item weights that are not child nodes), `Random`, `Anchor`,
// `AnchorSize`, `sibling-count()` and `sibling-index()` (all of which need `Style::BuilderState` or
// the anchor evaluator, which the boundary does not carry and this file does not ask it to).
//
// This round added an arity change: everything before rebuilt every unfolded node with exactly the
// children it came in with, so `rebuildSlot(const Children&)` -- which deliberately takes all
// remaining operands and ignores the original's count -- had never executed. `min()`'s merge and
// `hypot()`'s rebuild are the first things in the whole file to run it. This also added the only
// rewrite that produces a node of a kind that was not in the input, `clamp()` collapsing to `min()`
// or `max()`, which is `buildMinMax`'s first and only caller.
//
// THE PUSH IS LAZY, AND THAT IS THE ONE DESIGN DECISION WORTH ARGUING ABOUT. The obvious shape for a
// post-order rewriter is "simplify each child, push it, then ask the parent to fold" -- and it does
// not work, because the builder is an operand STACK with no pop. A parent that folds `mod(1, 2)`
// into `Number(1)` would leave its two children stranded on the stack under the answer, and the
// entry point's "exactly one operand" contract would fail for every folded tree in the document.
// Adding a `discard(n)` to the boundary was the alternative and it was rejected: it is C++ written
// to facilitate Swift, and it is not needed: a `min(r, 1px)` keeps an unresolved `Symbol` as a
// survivor, and `clamp(none, r, 1px)` rebuilds as a `min()` over two subtrees, and the answer is
// still not a `pop`, because `Fold` has cases that say what `rewrite` must push instead. So the work
// splits in two:
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
// is for `fold` to hand its per-child results down to `rewrite` rather than a boundary change. Having
// `.mergedChildren` carry the survivor list was rejected for now because the list is dynamically
// sized, so it would put a heap allocation on a `Fold` value that is constructed for every node at
// every level, where the common case allocates nothing.
//
// THE ARITHMETIC IS PORTED, NOT UPCALLED, and that is the opposite of the choice the serialization
// pass made for number FORMATTING. The two are different problems. `formatCSSNumberValue` is a
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

/// What simplification did with a tree.
///
/// `@c` (SE-0495) makes this the single declaration of the numbering, checked against
/// CSSCalcTree+Simplification.cpp via `static_assert`. Internal rather than `public`: `@c` on a
/// resilient enum crashes IRGen, and WebCore compiles with library evolution.
@c
enum CSSCalcSwiftSimplificationOutcome: UInt8 {
    /// Swift built the complete simplified tree on the builder's operand stack.
    case simplified = 0
    /// Swift built nothing usable; the caller must run the C++ simplifier.
    case declined = 1
}

// MARK: - The per-alternative discriminant

// Dispatches on `CSSCalcSwiftAlternative`, not `CSSCalcSwiftNodeKind`: `kind` classifies a node by
// serialization shape, which conflates operations like `min()` and `mod()` that this file must
// treat differently, and a Swift file cannot name a `CSSValueID` to disambiguate further. So the
// boundary carries the variant's own alternative index (41 cases, pinned to `Node`'s alternative
// indices via `WTF::alternativeIndexV`), and this file imports that enum rather than mirroring it.

/// `WebCore::CSSCalc::CSSCalcSwiftAlternative`, aliased for line length.
private typealias CalcAlternative = WebCore.CSSCalc.CSSCalcSwiftAlternative

/// The value `CSSCalcSwiftLeaf.kind` wants for one of the four numeric leaves. Routed through a
/// function rather than `kind.rawValue`, since the two enums' agreement is not guaranteed to hold.
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

/// Which of the four numeric alternatives a folded value is: a four-case enum rather than the
/// 41-case discriminant, since every predicate below only needs this distinction.
private enum NumericKind {
    case number
    case percentage
    case canonicalDimension
    case nonCanonicalDimension
}

/// A numeric leaf the file has decided on: everything `makeChildWithValueBasedOn` carries. Needed
/// because `CSSCalcSwiftBuilder` is a sink -- once pushed, an operand cannot be read back -- so a
/// parent must carry the answer out of the recursion itself.
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

/// A bare `<number>`. The unit is the real `CSSUnitType.Number` (`toCSSUnit(const Number&)`,
/// CSSCalcTree.h:1008), not a guess.
    @inline(always)
    static func number(_ value: Double) -> NumericLeaf {
        return NumericLeaf(
            kind: .number,
            value: value,
            unitType: UInt16(WebCore.CSSUnitType.Number.rawValue),
            percentHint: 0
        )
    }

/// A canonical `<angle>`, produced by the arc-trig folds and `atan2()`.
    @inline(always)
    static func canonicalAngle(_ value: Double) -> NumericLeaf {
        return NumericLeaf(
            kind: .canonicalDimension,
            value: value,
            unitType: UInt16(WebCore.CSSUnitType.Deg.rawValue),
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
// function each, in the header's own order.
//
// Two spellings recur: `x == 0` for the C++ `!x` on a double (true for both `+0` and `-0`, false for
// NaN), and `x.sign == .minus` for `std::signbit(x)` (true for `-0.0` and negative NaN, unlike `x <
// 0`).
private enum CalcExecutor {

/// `deg2rad`: `d * radiansPerDegreeDouble`. Written as a constant expression so it folds at
/// compile time like the C++ `constexpr`.
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

/// `minWithSignedZero` (CSSCalcExecutor.h:61-:66). Spelled out rather than `Swift.min`, because
/// `Double.minimum` NaN-quiets and gives a different answer for a NaN operand.
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

/// `OperatorExecutor<Operator::Min>`'s two-`double` overload. NOT `minWithSignedZero`: this executor
/// short-circuits on either operand being NaN before the helper would run, so `min(1, NaN)` here is
/// `NaN` while the helper's would be `1`. Parameter order matters for the same reason.
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

/// `OperatorExecutor<Operator::Max>`, `min` above with the helper swapped; the two NaN
/// short-circuits are the whole difference from `maxWithSignedZero`.
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

/// `OperatorExecutor<Operator::Clamp>`. Calls `maxWithSignedZero`/`minWithSignedZero` directly
/// after its own three-way NaN check, matching the C++ executor rather than going through `min`/`max`
/// above.
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

/// The two poles are named exactly (`90deg` is `infinity` per css-values-4, where libm's `tan` is
/// merely very large): compared bit-for-bit against the same reduced constants the C++ compares
/// against, so the reduction must be bit-identical for them to fire.
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

/// `OperatorExecutor<Operator::Sign>`. The final `return a` is load-bearing: it returns the operand
/// itself when neither greater nor less than zero, so `sign(-0)` is `-0` and `sign(NaN)` is `NaN`.
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

/// The result of folding one subtree: `copyAndSimplify`'s `std::optional<Child>` plus a decline
/// channel. Invariant: `.leaf` holds exactly when the C++'s `simplify` produced a `Numeric`, and
/// every operand predicate below relies on that.
private enum Fold {
/// `simplify` returned a replacement that is a numeric leaf. Nothing has been pushed; the caller
/// uses the value or pushes the leaf itself.
    case leaf(NumericLeaf)
/// `simplify` returned `std::nullopt`: the node keeps its kind and is rebuilt from its simplified
/// children with the same arity. Carries the alternative, which `foldInvert` needs.
    case unchanged(CalcAlternative)
    /// The node collapses to one of its own children, unfolded: `return { WTF::move(root.children[i])
    /// }` at `+Simplification.cpp:409`, `:456` and `:1015`. `rewrite` pushes that subtree's operand
    /// and nothing else, which is exactly one operand, so the parent's count is unaffected.
    ///
    /// One level for now: `rewrite` on the named child re-folds it, so a child that itself collapses
    /// to a grandchild is handled by the recursion and never needs to be addressed from here. `Sum`
    /// is the case that needs a second level, because step 8.1 splices a child `Sum`'s children into
    /// the parent's own child list before the merge runs, and a survivor of that merge can be a
    /// grandchild that `rewrite` has no single child to delegate to.
    ///
    /// Never produced when the promoted term is a leaf -- see `promoteTerm`, which returns the leaf
    /// itself in that case. That is what keeps the file's `.leaf` invariant exact: the C++ returns the
    /// child, so if the child is a `Numeric` the parent's `switchOn` sees a `Numeric`.
    case replacedByTerm(child: UInt32)
/// `clamp()` becoming `min()` or `max()`: the only rewrite that creates an operation kind not in
/// the input, and the only reason `buildMinMax` exists on the boundary.
    case rebuiltMinMax(isMax: Bool)
    /// A `Children`-slotted node whose children merged: `rewrite` recomputes the merge plan, pushes
    /// one operand per survivor, and calls `rebuildFrom(node, survivorCount)` with the new count.
    ///
    /// Kept apart from `.unchanged` rather than folded into it -- the C++ returns `std::nullopt` for
    /// both -- so that `fold`'s answer says whether the arity changed, which is the property
    /// `rebuildSlot(const Children&)` turns on. Carries the alternative for the same reason
    /// `.unchanged` does.
    case mergedChildren(CalcAlternative)
/// Outside this file's slice, or a boundary contract it will not guess at: the whole tree declines.
/// The payload is the blame `declineAlternative` reports; `nil` means declined with no single cause.
    case declined(CalcAlternative?)
}

/// The result of pushing one subtree's operand. A two-case enum rather than `Bool`, so a decline
/// still carries blame the way `Fold.declined` does.
private enum Rewrite {
    case pushed
    case declined(CalcAlternative?)
}

// MARK: - The traversal that decides, and reports

/// Whether this file can simplify a node of this alternative with this many children. The child
/// count is part of the check: the boundary reads `childCount` and asks `rebuildFrom` to consume
/// exactly that many operands, so a mismatched count would fill the wrong slots.
private func isSimplifiableAlternative(_ alternative: CalcAlternative, _ childCount: UInt32) -> Bool {
    switch alternative {
    case .Number, .Percentage, .CanonicalDimension, .NonCanonicalDimension:
        // The four leaves. `simplify` is a no-op for three of them and `canonicalize` for the
        // fourth (`+Simplification.cpp:486`-`:513`).
        return true

    case .Symbol:
        // Any resolved unit; an unresolvable symbol is copied through rather than declined.
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

    case .Sum, .Product:
        // Declined. Their rules reassociate and reorder -- step 8.1 splices a child Sum's children
        // into the parent, and the zero-term and same-unit merges run over an index-offset table --
        // which is not a fold of one node.
        return false

    case .Negate:
        // Rules 6.2 to 6.4 rewrite a child's children in place (`+Simplification.cpp:927`-`:959`),
        // which the operand stack cannot express: it would have to hand back a subtree it never held.
        return false

    case .Min, .Max:
        // `simplifyForMinMax` (`:371`-`:482`) asserts non-empty children; unreachable through the
        // parser, so a decline (rather than claiming the node) is the honest answer if it ever isn't.
        // No upper bound: `rebuildSlot` takes all remaining operands.
        return childCount >= 1

    case .Clamp:
        // `clamp(none, VAL, MAX)` becomes `min(VAL, MAX)` -- the only rule that changes an operation's kind,
        // and the only reason `buildMinMax` exists on the boundary. 3/2/1 are the only shapes `ChildOrNone`
        // admits; whether `kind` agrees on WHICH bound is `none` is checked separately in `foldClamp`.
        return childCount >= 1 && childCount <= 3

    case .Hypot:
        // A stateful pass over a variable number of children with a running type tag. No arity condition:
        // `simplify(Hypot&)` has no `ASSERT` on child count, and its executor defines the empty case (returns
        // NaN without calling the functor), which this file reaches the same way via `.unchanged`.
        return true

    case .CalcMix:
        // Normalisation over per-item weights that are not child nodes.
        return false

    case .Random:
        // Needs `Style::BuilderState` for `resolveRandomBaseValue`, which the boundary does not carry.
        return false

    case .SiblingCount, .SiblingIndex:
        // Both read `conversionData->styleBuilderState()->element()` (`:527`-`:544`).
        return false

    case .Anchor, .AnchorSize:
        // Need the anchor position evaluator. Also the one place `rebuildFrom`'s tuple conformance
        // does not cover: `tuple_size` is 0 for both (CSSCalcSwiftTypes.h), so even a pass-through
        // rebuild is unavailable.
        return false

    @unknown default:
        // An alternative C++ grew and this file has not been taught. Declining is the only safe
        // answer.
        return false
    }
}

/// The coverage traversal. Accumulates the node count and alternative mask, and reports whether
/// every node it saw is one this file can simplify. Recursive rather than an explicit stack, since
/// calc trees are shallow and no Swift container accepts a `~Escapable` element. Walks the whole tree
/// even after the first decline, so the mask describes the full tree rather than a truncated prefix.
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
        // The first unhandled alternative in pre-order is the one reported, so widening this file's
        // coverage can only move the blame outward.
        blame = info.alternative
    }

    var index: UInt32 = 0
    while index < info.childCount {
        // Tree order, not serialization order: `childAt` sorts a `Sum`'s/`Product`'s children by unit for
        // the serializer, which would silently permute a multi-unit sum here.
        if !walk(node.childInTreeOrder(index), &nodeCount, &kindMask, &blame) {
            everyNodeSimplifiable = false
        }
        index += 1
    }

    return everyNodeSimplifiable
}

// MARK: - The simplifier

/// The part of `SimplificationOptions` this file reads.
///
/// A `struct`, not a `class`: a class stored property costs dynamic exclusivity enforcement
/// (`swift_beginAccess`/`swift_endAccess`) on every read, on a recursion that reads this at nearly
/// every node.
///
/// `CSSCalcSwiftSimplificationOptions` carries six fields; this reads one. `range` is read at zero
/// sites in the C++ simplifier -- the *serializer* clamps against it instead;
/// `allowZeroValueLengthRemovalFromSum` is read at exactly one site, inside `simplify(Sum&)`, not yet
/// handled here; `category` is unread so far; `hasConversionData` is subsumed by
/// `resolveRelativeLength` answering `resolved == false`; and `Stage` is copied through
/// `copyAndSimplify` and never read.
private struct CalcSimplification {
    /// `percentageResolveToDimension(options)` (`+Simplification.cpp:86`-`:107`), precomputed in C++
    /// to avoid a second copy of the `CSS::Category` table here.
    let percentageResolveToDimension: Bool

    // MARK: Shared predicates

    /// `unitsMatch` (`+Simplification.cpp:111`-`:129`), for two leaves already known to be the same
    /// alternative: one comparison covers all four kinds because `toCSSUnit` is injective per kind,
    /// so comparing units is comparing dimensions.
    @inline(always)
    func unitsMatch(_ a: NumericLeaf, _ b: NumericLeaf) -> Bool {
        return a.unitType == b.unitType
    }

    /// `switchTogether` (`+Simplification.cpp:69`-`:82`): two operands take the `Numeric T` visitor
    /// only when they are the same alternative, falling to the catch-all otherwise.
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

    /// `fullyResolved` (`+Simplification.cpp:155`-`:173`). Differs from `magnitudeComparable` only for
    /// a `NonCanonicalDimension`: comparable by magnitude, but not fully resolved since its unit
    /// hasn't converted yet.
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

    /// `simplifyForOperationWithCompletion<Op, Completion>` (`+Simplification.cpp:313`-`:326`): the
    /// same three predicates, but the caller chooses the result's shape rather than inheriting the
    /// first operand's -- `atan2()`'s result is always a canonical `<angle>`.
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
// One function per C++ `simplify` overload, in `CSSCalcTree+Simplification.cpp`'s own order, so a
// reader can put the two side by side.

private extension CalcSimplification {

    /// `simplify(Invert&)` (`+Simplification.cpp:962`-`:979`).
    ///
    /// Rule 7.1 only. Rule 7.2 -- "if root's child is an Invert node, return the child's child" -- is
    /// declined: it is a boundary limitation, not a scope decision. The child's child is a subtree
    /// never held here -- `rewrite` pushed the child as one operand and `rebuildFrom` consumed it, and
    /// the operand stack cannot hand a node's slot back. Declining is exact: the C++ arm runs and
    /// applies 7.2 itself.
    ///
    /// Division always builds a `Product` wrapper, so `calc(1 / r)` parses as `Product{Number(1),
    /// Invert{Symbol}}`, and an `Invert` only ever appears inside a `Product`, which is declined
    /// outright. A bare `Invert{Invert{X}}` is reachable only from a programmatically constructed
    /// tree.
    @inline(always)
    func foldInvert(_ a: Fold) -> Fold {
        switch a {
        case .leaf(let leaf):
            guard leaf.kind == .number else {
                // 7.1 is `<number>` only: a percentage or dimension has no reciprocal the tree can
                // hold, so the node is rebuilt.
                return .unchanged(.Invert)
            }
            return .leaf(NumericLeaf.number(CalcExecutor.invert(leaf.value)))
        case .unchanged(let childAlternative):
            if childAlternative == .Invert {
                return .declined(.Invert)
            }
            return .unchanged(.Invert)
        case .replacedByTerm:
            // The child collapsed to one of its own children -- a single-argument `min()`, or a
            // `clamp(none, VAL, none)` -- and this file does not carry what that grandchild's
            // alternative is, so it cannot tell whether rule 7.2 applies to the result. Declining is
            // exact: a decline runs the C++ arm, which applies 7.2 or not as the tree requires. An
            // `Invert` is only reachable inside a `Product`, which declines outright, so reaching this
            // at all needs a constructed tree.
            return .declined(.Invert)
        case .mergedChildren, .rebuiltMinMax:
            // Both provably produce a `Min` or a `Max` and never an `Invert`: `.mergedChildren` carries
            // the alternative and `foldMinMax` is its only producer, and `.rebuiltMinMax` is
            // `buildMinMax` by construction. So this is the C++'s `[](auto&)` arm: `nullopt`, and the
            // `Invert` is rebuilt from its one simplified child.
            return .unchanged(.Invert)
        case .declined(let blame):
            return .declined(blame)
        }
    }

    /// `simplify(Deg2Rad&)` (`+Simplification.cpp:981`-`:996`). Safer than the C++: the C++'s
    /// `ASSERT` on the angle dimension is compiled out in shipping builds, so a `Deg2Rad` wrapping a
    /// `<length>` would silently misconvert there; this file checks the unit and declines instead.
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

    /// `simplifyForRound<Op>` (`+Simplification.cpp:328`-`:337`): branches on child count rather
    /// than `root.b` -- the same test, since `forAllChildNodes` counts an optional child only when
    /// present. With a second argument this is `simplifyForOperation`; without one the value must be
    /// a `Number` and the interval is `1.0`.
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

    /// `simplify(Pow&)` (`+Simplification.cpp:1174`-`:1187`): both arguments are type-checked to be
    /// `<number>` at parse time, so the only predicate needed is "both are `Number`" -- narrower
    /// than `simplifyForOperation`'s, which is why `pow()` doesn't share `foldBinaryOperation`.
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

    /// `simplify(Progress&)` and `simplify(ProgressNoClamp&)` (`+Simplification.cpp:1403`-`:1443`):
    /// all three operands must be the same alternative, with `unitsMatch` checked pairwise and
    /// `fullyResolved` on the first. The result is always a `<number>` -- `progress()` is a ratio,
    /// not a quantity.
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

    /// What an operation reports when an operand did not fold to a leaf: a declined operand
    /// declines the whole tree, an unchanged one rebuilds from children. Centralized so the operand
    /// guards above can't get the two backwards.
    @inline(always)
    func foldFailed(_ operand: Fold, _ alternative: CalcAlternative) -> Fold {
        if case .declined(let blame) = operand {
            return .declined(blame)
        }
        return .unchanged(alternative)
    }

    /// Restamp a shared predicate's `.unchanged` with the caller's own alternative: the
    /// `simplifyForOperation` family doesn't know which operation invoked it and reports
    /// `.unchanged(.Number)` as a placeholder, which `rewrite` and `foldInvert` need corrected.
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
    /// this subtree, without pushing anything: it simplifies the children, then tries to fold the
    /// node itself, reporting the result rather than materializing it.
    ///
    /// `builder` is `borrowing` here, so only its `const` upcalls are reachable -- `pushLeaf`,
    /// `pushCopyOf`, `rebuildFrom` and `buildMinMax` are all `mutating` in Swift and can't be called
    /// on a borrow, which makes "pushes nothing" compiler-checked rather than a comment.
    func fold(
        _ node: borrowing WebCore.CSSCalc.CSSCalcSwiftNode,
        _ builder: borrowing WebCore.CSSCalc.CSSCalcSwiftBuilder
    ) -> Fold {
        let info = node.info()
        let alternative = info.alternative

        switch alternative {
        // `simplify(Number&)`, `simplify(Percentage&)` and `simplify(CanonicalDimension&)` all
        // return `std::nullopt` (`:486`-`:513`), so the C++ rebuilds the leaf as itself; reported as
        // `.leaf` here so a parent can fold over it.
        //
        // Three cases rather than one mapping function, so a wrong alternative is a compile error
        // rather than a silently-produced `<number>`.
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

        case .SiblingCount, .SiblingIndex, .Sum, .Product, .Negate,
             .Random, .CalcMix, .Anchor, .AnchorSize:
            // Enumerated by name rather than swept into the `@unknown default` below, so an
            // alternative that is declined on purpose stays distinguishable from one that simply has
            // not been taught.
            return .declined(alternative)

        @unknown default:
            // An alternative C++ grew and this file has not been taught. Blamed by name anyway,
            // because `alternative` is a value rather than a case label and reporting it is what
            // tells the next reader which one it was.
            return .declined(alternative)
        }
    }

    /// `simplify(Symbol&)` (`+Simplification.cpp:516`-`:524`): resolve the `<calc-keyword>` against
    /// the symbol table and simplify what it resolves to, for any resolved unit, not just `<number>`.
    ///
    /// `CSSCalcSwiftNumericResult` carries the alternative `makeNumeric` actually built, read back
    /// off the C++ node rather than re-derived from a duplicated unit table. It also carries
    /// `Symbol::unit` (not the symbol table's own unit) back down to `resolveSymbol`, matching
    /// `makeNumeric(value->value, root.unit)` exactly -- the two are independently populated
    /// `HashMap`s and can disagree.
    ///
    /// The recursion is written out rather than re-entered: `copyAndSimplify` on a numeric leaf is a
    /// no-op for `Number`/`Percentage`/`CanonicalDimension` and `canonicalize` for
    /// `NonCanonicalDimension`, so the four arms below are that recursion bottomed out.
    ///
    /// An unresolved symbol is not a decline: it is copied through unchanged (`.unchanged` here).
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
            // (CSSCalcTree.cpp:196-:197): the hint is 0, not inherited.
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
            // Unreachable: `makeNumeric` always returns one of the four numeric alternatives.
            // Declining is the only answer that cannot be silently wrong.
            return .declined(.Symbol)
        }
    }

    /// `simplify(NonCanonicalDimension&)` (`:505`-`:513`) / `canonicalize`
    /// (`+Simplification.cpp:169`-`:287`): canonicalize if there is enough information, otherwise
    /// leave it alone. Shared by the walk's own case and `foldSymbol`.
    ///
    /// `canonicalize`'s seventy `CSSUnitType` cases split three ways: fourteen do arithmetic against a
    /// compile-time constant (reproduced below, reading the same constants through
    /// `CSSUnitConversions.h`/`wtf.Core.MathExtras`); fourteen a `NonCanonicalDimension` can never
    /// hold (enumerated below so they can't silently fall into the upcall arm); and forty-two are
    /// font-, viewport- and container-relative lengths, resolved through one upcall
    /// (`resolveRelativeLength`) rather than a transcribed unit table. `resolved == false` there means
    /// "no conversion data", a normal outcome, and the dimension stays as it is.
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
        // `uint16_t` (see `CSSCalcSwiftLeaf.unitType`), so narrowing it back is a conversion that
        // must be able to fail. A value outside the enum lands in the same place the C++'s
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

        // The fourteen units a `NonCanonicalDimension` can never hold. `ASSERT_NOT_REACHED` in the
        // C++; unchanged here, matching shipping behavior. Enumerated so they don't fall to the
        // upcall below.
        case .Px, .Deg, .S, .Hz, .Dppx, .Fr,
             .Number, .Integer, .Percentage,
             .Calc, .CalcPercentageWithAngle, .CalcPercentageWithLength, .QuirkyEm, .Unknown:
            return unchanged()

        // Everything else is a font-, viewport- or container-relative length, resolved via upcall
        // rather than a transcribed `CSS::toLengthUnit` table.
        default:
            let resolved = builder.resolveRelativeLength(value, unitType)
            guard resolved.resolved else {
                return unchanged()
            }
            // `CanonicalDimension` unconditionally: resolving a length yields a length, and the unit
            // comes from the upcall's own answer, not a guess here.
            return NumericLeaf(
                kind: .canonicalDimension,
                value: resolved.value,
                unitType: resolved.unitType,
                percentHint: 0
            )
        }
    }


    /// The `std::optional<Child> b` slot of `round()` and `log()`, folded, or `nil` when absent.
    ///
    /// `childCount > 1` is a presence test, not a bounds check -- the arity is already validated --
    /// and is written as `> 1` rather than `== 2` so it stays correct if a wider arity is admitted
    /// later.
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
// These can produce a result with a different number of children than the input, or a node of a
// kind not in the input, so each needs its own node rather than just its operands' folds. `fold` may
// answer `.replacedByTerm`, `.mergedChildren` or `.rebuiltMinMax` for them.

/// `simplify(Hypot&)`'s five-alternative running type tag (`+Simplification.cpp:1208`-`:1212`), spelled
/// `Variant<std::monostate, NumberTag, PercentageTag, DimensionTag, FailureTag>` in the C++.
///
/// `.unset`, not `.none`: a case named `none` on a non-`Optional` enum reads as `Optional.none` at
/// every `switch` site. `DimensionTag`'s key is a `CSSUnitType` raw value rather than a
/// `CanonicalDimension::Dimension`, since `toCSSUnit` is a bijection onto the six canonical units.
private enum HypotTag {
    case unset
    case number
    case percentage
    case dimension(UInt16)
    case failed
}

private extension CalcSimplification {

    /// Fold every child of a variable-arity node, in tree order. One `[Fold]` allocation per node --
    /// `Fold` is all `Copyable`/`Escapable` scalars, so no container-of-`~Escapable` problem arises.
    func foldChildren(
        _ node: borrowing WebCore.CSSCalc.CSSCalcSwiftNode,
        _ childCount: UInt32,
        _ builder: borrowing WebCore.CSSCalc.CSSCalcSwiftBuilder
    ) -> [Fold] {
        var folded: [Fold] = []
        // `Int(clamping:)`, not `Int(_:)`, which traps if `Int` is narrower than `UInt32`. A
        // saturating capacity hint can't be wrong -- `append` grows regardless.
        folded.reserveCapacity(Int(clamping: childCount))
        var index: UInt32 = 0
        while index < childCount {
            folded.append(fold(node.childInTreeOrder(index), builder))
            index += 1
        }
        return folded
    }

    /// The first child that declined, as the `Fold` to return, or `nil` when none did. Returns the
    /// child's own `.declined` value rather than its blame, avoiding a double optional.
    ///
    /// Checked over all children before any fold dispatches: a declined child means the whole tree
    /// can't be built, regardless of which operand the C++ would have looked at first.
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
    /// The `.leaf` case is required, not an optimisation: the C++ returns the child itself, so a
    /// parent must be able to fold over it if it's `Numeric` (`abs(min(1px))` -> `1px`). This is what
    /// keeps `Fold`'s `.leaf` invariant true.
    @inline(always)
    func promoteTerm(_ folded: Fold, _ index: UInt32) -> Fold {
        switch folded {
        case .leaf(let leaf):
            return .leaf(leaf)
        case .declined(let blame):
            return .declined(blame)
        case .unchanged, .replacedByTerm, .rebuiltMinMax, .mergedChildren:
            return .replacedByTerm(child: index)
        }
    }

    // MARK: `hypot()`

    /// `simplify(Hypot&)` (`+Simplification.cpp:1204`-`:1279`). An optimistic state machine over the
    /// children: empty range -> NaN; one element -> `abs(f(c0))`; two or more -> `sqrt(sum(f(c)^2))`.
    /// The functor runs once per element in tree order.
    ///
    /// Runs the full pass even after failure (matching the C++, which cannot short-circuit its
    /// evaluation API) though the accumulated value is discarded once failed -- observationally
    /// identical to an early exit, kept for parity with the C++ it's checked against.
    ///
    /// Only ever runs over `.leaf` children: any other `Fold` case means `simplify` did not produce a
    /// `Numeric`, which `hypotElement` maps to `.failed` in one place.
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
            // The hint is provably 0 wherever this runs: `determinePercentHint` is non-`None` only for
            // `LengthPercentage`/`AnglePercentage`, and this arm is reached only when
            // `percentageResolveToDimension` was false for those same two categories -- the two
            // conditions can't both hold.
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
            // `nullopt` in the C++: rebuilt from its children at the same arity. `.unset` is
            // unreachable here (the empty case returned above) but enumerated rather than defaulted so
            // a future tag must be classified.
            return .unchanged(.Hypot)
        }
    }

    /// One iteration of `simplify(Hypot&)`'s functor: advance the tag and return the value the
    /// executor accumulates. `Double.nan` on every failure, matching the C++; discarded once
    /// `.failed`, but returned anyway for parity.
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
                // A `Numeric`, but the C++ has no arm for it: `hypot()` over an unconverted `1em` is
                // rebuilt rather than folded, since its value isn't yet in a comparable unit.
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
            // Reads the value only: a percentage's `hint` plays no part in matching here -- the
            // folded result's hint is stamped from the category. See `foldHypot`'s `.percentage` arm.
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

    // MARK: `min()` and `max()`

    /// `simplifyForMinMax` (`+Simplification.cpp:371`-`:482`), css-values-4 steps 5.1 to 5.3, for both
    /// `Min` and `Max`.
    ///
    /// The C++ mutates `root.children` while iterating it, relying on invariants nothing states (that
    /// an assignment target index is always behind the read index, and that a moved-from `Variant`
    /// keeps its discriminant). This file needs neither: it merges over `NumericLeaf` values via
    /// `mergePlan`, never mutating the tree, and `rewrite` makes the single consuming pass once the
    /// plan is complete.
    ///
    /// Four outcomes, in the C++'s order: one child -> return it; no merges -> rebuild unchanged;
    /// `n - merges == 1` -> return child 0; otherwise -> survivors replace the children
    /// (`.mergedChildren`, which the C++'s single `nullopt` can't distinguish from the no-merges case).
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
        // Term 0 is always the sole survivor here, which is why the C++ writes `children[0]`
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

    /// One term's place in the merge: what it accumulated, whether anything may merge into it, and
    /// whether it survives. Per term, not per unit identity, which removes the C++'s 512-byte dense
    /// table (`:414`) in favor of a linear scan (`mergeTarget`).
    struct MergeSlot {
        /// The accumulated leaf, or `nil` when the term is not a `Numeric`. A value type, so a merge
        /// is a copy and there is nothing the tree can observe.
        var accumulated: NumericLeaf?
        /// Whether a later term may merge into this one -- true only for a first instance, matching
        /// the C++'s `offsetOfFirstInstance[id] = i + 1`.
        var mergeable: Bool
        /// Whether the term appears in the rebuilt child list.
        var survives: Bool
    }

    /// Phase 1 of `simplifyForMinMax` (`:418`-`:446`), as values. No dense table: `CSSUnitType` is a
    /// bijection onto `NumericIdentity` over every leaf the tree can hold, so the merge keys on the
    /// `unitType` already carried in `NumericLeaf` and finds a first instance with a linear scan
    /// instead of a 512-byte table.
    ///
    /// `evaluate` is `CalcExecutor.min`/`.max` (the two-`double` overload, not the signed-zero
    /// helpers). With those executors' NaN short-circuits and signed-zero symmetry, merge order can't
    /// change the result for `Min`/`Max` -- written in term order anyway since it costs nothing and
    /// `Sum` genuinely depends on it.
    func mergePlan(_ folded: [Fold], _ isMax: Bool) -> (slots: [MergeSlot], merges: Int) {
        var slots = [MergeSlot](
            repeating: MergeSlot(accumulated: nil, mergeable: false, survives: true),
            count: folded.count
        )
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
            if leaf.kind == .percentage, !canMergePercentages {
                slots[i].accumulated = leaf
                continue
            }

            // The scan carries the accumulated leaf out with the index, rather than re-reading
            // `slots[j].accumulated` after the loop: two `if let`s would leave a fall-through where a
            // set target with a `nil` leaf silently became a new first instance.
            var target: (index: Int, accumulated: NumericLeaf)?
            for j in 0..<i where slots[j].mergeable {
                guard let accumulated = slots[j].accumulated else {
                    continue
                }
                if switchTogether(accumulated, leaf), unitsMatch(accumulated, leaf) {
                    target = (j, accumulated)
                    break
                }
            }

            if let target {
                // The surviving alternative, unit and percent hint are the first instance's, which
                // is exactly what `withValue` carries.
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

    // MARK: `clamp()`

    /// `simplify(Clamp&)` (`+Simplification.cpp:1008`-`:1105`). Four outcomes: both bounds `none` ->
    /// return `val` whatever it is; `val` not a `Numeric` -> rebuild unchanged (dominates the other
    /// two); one bound `none` -> fold if it agrees with `val`, else convert to `min()`/`max()`;
    /// neither `none` -> fold if all three agree, else rebuild (no conversion in this branch).
    ///
    /// `Clamp`'s tuple skips an absent bound in tree order, so `childInTreeOrder` already gives
    /// `[val, max]` / `[min, val]` / `[val]` / `[min, val, max]`. `childCount` gives the arity and
    /// `info.kind`'s `ClampWithNoneMinimum`/`ClampWithNoneMaximum` says which bound is absent when the
    /// arity is 2; the two are cross-checked and a mismatch declines.
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

        // The cross-check: exactly one absent bound means two children and vice versa. A mismatch
        // declines rather than filling a bound with the wrong subtree.
        guard (info.childCount == 2) == (minimumIsNone || maximumIsNone) else {
            return .declined(.Clamp)
        }

        // `childCount == 1` means both bounds hold the keyword, so child 0 is `val` -- returned
        // whatever it is.
        if info.childCount == 1 {
            return promoteTerm(folded[0], 0)
        }

        if info.childCount == 3 {
            // Neither bound is `none`: `[min, val, max]`.
            guard case .leaf(let value) = folded[1] else {
                // `val` is not a `Numeric`. Outcome 2.
                return .unchanged(.Clamp)
            }
            // `switchTogether` against `val` for both bounds; a non-leaf bound fails it too.
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
                // Covers all three of the C++'s `convertToMin()` sites, plus `max` not folding to a
                // `Numeric` at all.
                return .rebuiltMinMax(isMax: false)
            }
            // Argument order is load-bearing: the executor's NaN short-circuit returns the first NaN
            // operand, so `(val, max)` and `(max, val)` differ.
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
        // Operands are `(min, val)`; the result's shape is `val`'s, matching the branch above.
        return .leaf(value.withValue(CalcExecutor.max(minimum.value, value.value)))
    }
}

// MARK: - Building the answer

private extension CalcSimplification {

    /// Push exactly ONE operand for this subtree, and report whether the rewrite can continue.
    ///
    /// The contract in both directions, because `rebuildFrom`'s correctness rests on it: on
    /// `.pushed` the operand stack has grown by exactly one, and on `.declined` the caller must
    /// abandon the tree without inspecting the stack at all.
    ///
    /// Six shapes, in the order they are tried:
    ///
    ///  1. The subtree folds to a numeric leaf -- `pushLeaf`, and none of its children are ever
    ///     built at all. That is not just an allocation saved: a folded subtree in the C++ arm
    ///     builds every intermediate `Child` and then throws them away.
    ///  2. The subtree is an unresolved `Symbol` -- `pushCopyOf`, which routes to
    ///     `CSSCalc::copy(const Child&)`, the same copy `copyAndSimplifyChildren` bottoms out in.
    ///  3. The subtree collapses to one of its own children -- push that child's operand and nothing
    ///     else, which is still exactly one operand.
    ///  4. A `clamp()` that became a `min()` or a `max()` -- push its two arguments and `buildMinMax`.
    ///     This is the only place the file asks for a kind that was not in the input.
    ///  5. A `min()`/`max()` whose children merged -- push one operand per survivor and `rebuildFrom`
    ///     with the new count -- the first thing here to change an arity.
    ///  6. Anything else in scope -- rewrite each child in tree order, then `rebuildFrom`, which
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
            // `false` is a contract violation, not a real input: `pushLeaf` only refuses a `kind`
            // outside the four numeric leaves, which this file never builds. Checked rather than
            // asserted so a broken boundary falls back to the C++ arm.
            return builder.pushLeaf(leaf.boundaryLeaf) ? .pushed : .declined(nil)

        case .replacedByTerm(let child):
            // `return { WTF::move(root.children[i]) }`: pushes one operand for the named child and
            // nothing for the node itself, avoiding any need for `pop`.
            return rewrite(node.childInTreeOrder(child), &builder)

        case .rebuiltMinMax(let isMax):
            return rewriteConvertedMinMax(node, isMax, &builder)

        case .mergedChildren(let alternative):
            return rewriteMergedChildren(node, alternative, &builder)

        case .unchanged(let alternative):
            return rebuild(node, alternative, &builder)
        }
    }

    /// `convertToMin`/`convertToMax` (`+Simplification.cpp:1018`-`:1044`): a fresh `min()`/`max()`
    /// over `clamp()`'s two surviving arguments, via `buildMinMax`, the boundary's only construction
    /// selector.
    ///
    /// A `false` from `buildMinMax` declines the whole tree rather than rebuilding the `Clamp`: by
    /// that point two operands are already pushed where the parent expects one, and there is no `pop`.
    /// Exact regardless, since the C++ arm then rebuilds the `Clamp` itself. Expected never to fire in
    /// practice, since the parser's own type check should make the mismatch unreachable.
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

    /// The `.mergedChildren` half of `rewrite`: `simplifyForMinMax`'s phase 2 (`:458`-`:479`). The
    /// merge plan is recomputed here rather than carried on `Fold`, trading a re-walk for avoiding a
    /// heap allocation on every node's `Fold` value.
    ///
    /// A `Numeric` survivor is pushed as a leaf rather than re-rewritten -- required, not an
    /// optimisation, since a merged first instance's value is `evaluate(...)`'s result and exists
    /// nowhere in the input tree.
    mutating func rewriteMergedChildren(
        _ node: borrowing WebCore.CSSCalc.CSSCalcSwiftNode,
        _ alternative: CalcAlternative,
        _ builder: inout WebCore.CSSCalc.CSSCalcSwiftBuilder
    ) -> Rewrite {
        let info = node.info()
        let folded = foldChildren(node, info.childCount, builder)
        let plan = mergePlan(folded, alternative == .Max)

        // Carried as a `UInt32` beside the iteration rather than converted from the array's `Int`:
        // `childInTreeOrder` wants a `UInt32`.
        var index: UInt32 = 0
        var survivors: UInt32 = 0
        for slot in plan.slots {
            defer { index += 1 }
            guard slot.survives else {
                continue
            }
            if let accumulated = slot.accumulated {
                guard builder.pushLeaf(accumulated.boundaryLeaf) else {
                    // A contract violation: the leaf is synthesised here, so there is no input
                    // alternative to blame.
                    return .declined(nil)
                }
            } else if case .declined(let blame) = rewrite(node.childInTreeOrder(index), &builder) {
                return .declined(blame)
            }
            survivors += 1
        }

        // Expressed as a count: `rebuildSlot` takes all remaining operands, which is what lets
        // the arity change.
        return builder.rebuildFrom(node, survivors) ? .pushed : .declined(alternative)
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
            // Tree order: `rebuildFrom` fills the operation's slots from the operands in the order
            // they were pushed. `childAt` would reorder a `Sum`'s terms by unit, so the loop is
            // written against tree order, which is correct for every alternative.
            let child = rewrite(node.childInTreeOrder(index), &builder)
            if case .declined(let blame) = child {
                return .declined(blame)
            }
            index += 1
        }

        // Pops `childCount` operands and pushes one node of the original's kind. `false` is a
        // decline rather than an impossibility: it covers a leaf, an `Anchor`/`AnchorSize` whose
        // tuple conformance is a lie, and an arity that does not match a fixed-slot operation.
        return builder.rebuildFrom(node, info.childCount) ? .pushed : .declined(alternative)
    }
}

// MARK: - The entry point

/// Simplify a whole tree onto the builder's operand stack, or decline.
///
/// On `.simplified` the stack holds exactly one operand, the new root. On `.declined` the stack
/// holds whatever the abandoned rewrite left on it; `trySimplifyWithSwiftIsland` discards it unread
/// and runs the C++ path.
///
/// `kindMask` and `nodeCount` come from the coverage walk rather than from the rewrite, because they
/// have to describe every tree the gate saw, including the ones it declined -- coverage measured
/// only on the cases that succeeded is not a coverage measurement. Both are keyed on the alternative
/// index (0 to 40), not on the 23 serialization kinds.
@_expose(Cxx)
public func cssCalcSimplifySwift(
    _ root: WebCore.CSSCalc.CSSCalcSwiftNode,
    _ builder: inout WebCore.CSSCalc.CSSCalcSwiftBuilder,
    _ options: WebCore.CSSCalc.CSSCalcSwiftSimplificationOptions
) -> WebCore.CSSCalc.CSSCalcSwiftSimplificationResult {
    var nodeCount: UInt32 = 0
    var kindMask: UInt64 = 0
    var blame: CalcAlternative?

    // Unconditional, so that the count and the mask describe every tree and not only the ones
    // Swift could take.
    let everyNodeSimplifiable = walk(root, &nodeCount, &kindMask, &blame)

    guard everyNodeSimplifiable else {
        return declined(kindMask, nodeCount, blame)
    }

    var simplification = CalcSimplification(
        percentageResolveToDimension: options.percentageResolveToDimension
    )

    if case .declined(let rewriteBlame) = simplification.rewrite(root, &builder) {
        // The rewrite's blame, not the walk's: the walk found nothing to blame or this would not be
        // reached, so this is a decline the coverage predicate could not have predicted -- `Invert`'s
        // rule 7.2, or a builder contract that came apart. A decline naming a handled alternative is
        // legitimate; only a `nil` blame is a contract violation.
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
/// The C++ ignores `SimplificationOptions` and switches only on the root alternative: `false` for
/// `Number`, `Percentage`, `CanonicalDimension`; `true` for the other 38. `canSimplify(t) == false`
/// implies `copyAndSimplify(t) == t`, true only because those three `simplify` overloads are
/// unconditional no-ops. An arm-agreement count over this function alone is weak coverage evidence:
/// it is right about any operator-rooted tree regardless of what the operator does.
///
/// Total, with no decline channel: every case is enumerated rather than swept into a catch-all, so
/// growing `CSSCalcTree.h` is a compile error here rather than a silently wrong answer.
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
