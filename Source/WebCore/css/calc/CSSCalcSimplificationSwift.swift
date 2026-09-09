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

internal import WebCore_Private.Core

// `CSSUnits.h` is not self-contained, so the conversion constants are split into namespace-scope
// `constexpr double`s, which import cleanly. Not `public`: a `public` Swift signature naming an
// imported C++ enum is refused under library evolution.
internal import WebCore_Private.CSSUnitsSwiftTypes

// The three <angle> conversion constants. Imported through the submodule rather than plain
// `import wtf`, which does not see them under WTF's umbrella module map.
internal import wtf.Core.MathExtras

internal import WebCore_Private.CSSCalcTypeSwiftTypes

// `CSS::Category`, which `Type::determinePercentHint` takes and `Type::calculationCategory`
// returns. `percentageResolveToDimension` alone cannot distinguish `LengthPercentage` from
// `AnglePercentage` for step 9.4's `Category::Percentage` case.
internal import WebCore_Private.CSSPrimitiveNumericCategorySwiftTypes

internal import Cxx

import Darwin

// Swift port of CSSCalcTree+Simplification.cpp's calc() simplification, selected by
// USE_SWIFT_CSS_CALC_SIMPLIFICATION.
//
// Handles all 41 of `CSSCalc::Node`'s alternatives. What is not handled is refused per tree rather
// than per operation: `isSimplifiableAlternative` refuses an arity the boundary's `rebuildFrom`
// could not fill, and a simplification that cannot derive its answer sets `CalcFlatTree.declined`.
// That function's `@unknown default: return false` is what keeps an alternative added later in C++
// from being mis-handled by a stale case list here.
//
// A node's own kind never crosses the boundary: `rebuildFrom` recovers it from the original node's
// variant tag.
//
// The walk is flat and single-pass. `calcFlatten` copies the tree into one pre-order array of
// `CalcFlatNode` in a stack buffer, so a parent's index is always less than its children's; one
// backwards loop then simplifies every child before its parent, mutating nodes in place, and
// `emitRoot` walks the result forwards onto the builder's operand stack. The operand stack has no
// pop, which is why simplification cannot push as it goes.

/// What simplification did with a tree.
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

/// `WebCore::CSSCalc::Type`: seven `int8_t` exponents and a percent hint, 8 bytes, trivially
/// copyable. Written with backticks: `WebCore.CSSCalc.Type` unescaped parses as the metatype of the
/// `WebCore.CSSCalc` namespace enum, not the C++ struct.
private typealias CalcType = WebCore.CSSCalc.`Type`

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

/// `Type::PercentHintValue` as the `uint8_t` the boundary carries. A decoder rather than a field
/// read, since `PercentHintValue`'s storage is private and no accessor returns it: the value is
/// identified by comparing against each enumerator's own construction.
@inline(always)
private func percentHintRawValue(_ hint: CalcType.PercentHintValue) -> UInt8 {
    if hint == CalcType.PercentHintValue(.Length) {
        return WebCore.CSSCalc.PercentHint.Length.rawValue
    }
    if hint == CalcType.PercentHintValue(.Angle) {
        return WebCore.CSSCalc.PercentHint.Angle.rawValue
    }
    if hint == CalcType.PercentHintValue(.Time) {
        return WebCore.CSSCalc.PercentHint.Time.rawValue
    }
    if hint == CalcType.PercentHintValue(.Frequency) {
        return WebCore.CSSCalc.PercentHint.Frequency.rawValue
    }
    if hint == CalcType.PercentHintValue(.Resolution) {
        return WebCore.CSSCalc.PercentHint.Resolution.rawValue
    }
    if hint == CalcType.PercentHintValue(.Flex) {
        return WebCore.CSSCalc.PercentHint.Flex.rawValue
    }
    return 0
}

/// The inverse: the `Type::PercentHint` whose raw value this byte is, or `nil` for 0 or an
/// unrecognized value.
///
/// `init?(rawValue:)` on an imported C++ scoped enum does not validate -- it accepts any raw
/// value, and an out-of-range hint then aliases onto `.length` in
/// `Type::operator[](PercentHint)`, folding `calc(10% * 1em / 1em)` to `calc(10px)` where the
/// C++ gives `calc(10%)`. The six explicit comparisons below are what reject.
@inline(always)
private func percentHintFromRawValue(_ raw: UInt8) -> WebCore.CSSCalc.PercentHint? {
    if raw == WebCore.CSSCalc.PercentHint.Length.rawValue {
        return WebCore.CSSCalc.PercentHint.Length
    }
    if raw == WebCore.CSSCalc.PercentHint.Angle.rawValue {
        return WebCore.CSSCalc.PercentHint.Angle
    }
    if raw == WebCore.CSSCalc.PercentHint.Time.rawValue {
        return WebCore.CSSCalc.PercentHint.Time
    }
    if raw == WebCore.CSSCalc.PercentHint.Frequency.rawValue {
        return WebCore.CSSCalc.PercentHint.Frequency
    }
    if raw == WebCore.CSSCalc.PercentHint.Resolution.rawValue {
        return WebCore.CSSCalc.PercentHint.Resolution
    }
    if raw == WebCore.CSSCalc.PercentHint.Flex.rawValue {
        return WebCore.CSSCalc.PercentHint.Flex
    }
    return nil
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

    /// A canonical `<length>`: `simplify(Sum&)`'s "we removed too much" result.
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

    /// A canonical dimension in a named canonical unit, covering the remaining five dimensions
    /// step 9.4 can produce. The single-dimension helpers above are kept separate so each
    /// documents which C++ site produces it.
    @inline(always)
    static func canonical(_ value: Double, _ canonicalUnit: WebCore.CSSUnitType) -> NumericLeaf {
        return NumericLeaf(
            kind: .canonicalDimension,
            value: value,
            unitType: UInt16(canonicalUnit.rawValue),
            percentHint: 0
        )
    }

    /// `makeChild(Percentage { .value = v, .hint = H })`, the three shapes step 9.4's category
    /// switch produces. The hint is the real `Type::PercentHintValue`, not a transcribed constant.
    @inline(always)
    static func percentage(_ value: Double, _ hint: CalcType.PercentHintValue) -> NumericLeaf {
        return NumericLeaf(
            kind: .percentage,
            value: value,
            unitType: UInt16(WebCore.CSSUnitType.Percentage.rawValue),
            percentHint: percentHintRawValue(hint)
        )
    }
}

/// The merge key for a leaf: its `CSSUnitType` underlying value.
///
/// `CSSCalcTree+NumericIdentity.h` exists to give the C++ a dense key, and `toNumericIdentity` is
/// injective on the unit: `Number`, `Percentage`, each of the six canonical dimensions and each of
/// the 48 non-canonical units map one-to-one onto a `NumericIdentity`. The unit already is the
/// identity, so keying on it directly gives the same fixed-size table without a second 56-case
/// enum to keep in step.
///
/// Masked to 7 bits, which loses nothing and is what makes the index total: `CSSUnitType.h` states
/// that `CSSValue` allocates 7 bits for the value, so no enumerator can exceed 127 and the mask
/// never aliases two units onto one bucket. The tables are therefore indexed with no bounds trap,
/// whatever value the boundary hands over.
@inline(always)
private func mergeKey(_ leaf: NumericLeaf) -> Int {
    return Int(leaf.unitType & 0x7F)
}

// MARK: - The arithmetic
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
        if a.truncatingRemainder(dividingBy: b) == 0 {
            return (a, a)
        }
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

    /// `OperatorExecutor<Operator::Sum>` (CSSCalcExecutor.h:94-:97): plain IEEE `a + b`, so both
    /// implementations agree by construction on NaN, signed zero and infinities. What differs is
    /// accumulation order, since `+` is not associative -- `simplifySum` accumulates in child order
    /// for that reason.
    @inline(always)
    static func sum(_ a: Double, _ b: Double) -> Double {
        return a + b
    }

    /// `OperatorExecutor<Operator::Min>`'s two-`double` overload. Not `minWithSignedZero`: this
    /// executor short-circuits on either operand being NaN before the helper would run, so
    /// `min(1, NaN)` here is `NaN` while the helper's would be `1`. Parameter order matters for the
    /// same reason.
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
    /// after its own three-way NaN check, matching the C++ executor rather than going through
    /// `min`/`max` above.
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
        if valueToRound.isFinite && roundingInterval.isInfinite {
            return valueToRound.sign == .minus ? -0.0 : 0.0
        }
        let (lower, upper) = nearestMultiples(valueToRound, roundingInterval)
        return (upper - valueToRound).magnitude <= roundingInterval.magnitude / 2 ? upper : lower
    }

    /// `OperatorExecutor<Operator::RoundUp>` (CSSCalcExecutor.h:252-:267).
    @inline(always)
    static func roundUp(_ valueToRound: Double, _ roundingInterval: Double) -> Double {
        if valueToRound.isFinite && roundingInterval.isInfinite {
            // `if (!valueToRound) return valueToRound;` -- returns the zero itself, so `-0` stays
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
        if valueToRound.isFinite && roundingInterval.isInfinite {
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
        if valueToRound.isFinite && roundingInterval.isInfinite {
            return valueToRound.sign == .minus ? -0.0 : 0.0
        }
        let (lower, upper) = nearestMultiples(valueToRound, roundingInterval)
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
        if result == 0 {
            return b.sign == .minus ? -0.0 : 0.0
        }
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

    /// `OperatorExecutor<Operator::Tan>`. The two poles are named exactly (`90deg` is `infinity`
    /// per css-values-4, where libm's `tan` is merely very large): the comparison is bit-for-bit
    /// against the same reduced constants the C++ compares against, so the reduction must be
    /// bit-identical for them to fire.
    @inline(always)
    static func tan(_ a: Double) -> Double {
        let fullTurn = Double.pi * 2
        var x = a.truncatingRemainder(dividingBy: fullTurn)
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
    /// `std::log(a) / std::log(b)`, and not `log(a) / log(b)` reassociated or `logb`-based -- the
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
    @inline(always)
    static func abs(_ a: Double) -> Double {
        return a.magnitude
    }

    /// `OperatorExecutor<Operator::Sign>`. The final `return a` is load-bearing: it returns the
    /// operand itself when neither greater nor less than zero, so `sign(-0)` is `-0` and
    /// `sign(NaN)` is `NaN`.
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

    /// `OperatorExecutor<Operator::Random>` (CSSCalcExecutor.h:506-:559).
    @inline(always)
    static func random(_ randomBaseValue: Double, _ minimum: Double, _ maximum: Double, _ step: Double?) -> Double {
        if minimum.isNaN || maximum.isNaN {
            return Double.nan
        }
        if minimum.isInfinite {
            return minimum
        }

        let upperBound = maximum < minimum ? minimum : maximum

        let range = upperBound - minimum
        if range.isInfinite {
            return Double.nan
        }

        guard let step else {
            return minimum + randomBaseValue * range
        }
        if step.isNaN {
            return Double.nan
        }
        if step <= 0 {
            return minimum + randomBaseValue * range
        }

        let epsilon = step / 1000.0

        var n = (range / step).rounded(.down)
        if n.isInfinite {
            return minimum + randomBaseValue * range
        }

        // "If N produces a value that is not within epsilon of max, but N+1 would produce a value
        // within epsilon of max, set N to N+1."
        let distanceToMax = upperBound - (minimum + (n * step))
        if distanceToMax.magnitude > epsilon {
            let distanceToMaxPlus1 = upperBound - (minimum + ((n + 1) * step))
            if distanceToMaxPlus1.magnitude < epsilon {
                n = n + 1
            }
        }

        let stepIndex = roundDown(randomBaseValue * (n + 1.0), 1.0)

        let value = minimum + stepIndex * step

        if stepIndex == n && (upperBound - value).magnitude < epsilon {
            return upperBound
        }
        return value
    }
}

// MARK: - The coverage predicate

/// Whether this file can simplify a node of this alternative with this many children. The child
/// count is part of the check: the boundary reads `childCount` and asks `rebuildFrom` to consume
/// exactly that many operands, so a mismatched count would fill the wrong slots.
@inline(always)
private func isSimplifiableAlternative(_ alternative: CalcAlternative, _ childCount: UInt32) -> Bool {
    switch alternative {
    case .Number, .Percentage, .CanonicalDimension, .NonCanonicalDimension:
        return true

    case .Symbol:
        return true

    case .Invert:
        return childCount == 1
    case .Deg2Rad:
        return childCount == 1

    case .Mod, .Rem, .Atan2, .Pow:
        return childCount == 2

    case .RoundNearest, .RoundUp, .RoundDown, .RoundToZero:
        return childCount == 1 || childCount == 2

    case .Sin, .Cos, .Tan, .Asin, .Acos, .Atan, .Sqrt, .Exp, .Abs, .Sign:
        return childCount == 1

    case .Log:
        return childCount == 1 || childCount == 2

    case .Progress, .ProgressNoClamp:
        return childCount == 3

    case .Sum:
        // `simplify(Sum&)` (`:547`-`:714`). The same arity bound `Min`/`Max` take, and for the
        // same reason: `simplify(Sum&)` opens with `ASSERT(!root.children.isEmpty())`. An empty
        // node would fall through step 8.1 and rebuild empty, which is the answer this fold would
        // give anyway, but an assertions build fires in C++ and would not here. Unreachable through
        // the parser: `calc()` does not parse empty.
        return childCount >= 1

    case .Product:
        // `simplify(Product&)` (`:716`-`:908`), the largest single body in the file. Its `ASSERT` that
        // children are non-empty is unreachable through the parser, so a shipping build without it
        // still agrees. No upper bound: steps 9.1-9.3 can grow or shrink the factor count.
        return childCount >= 1

    case .Negate:
        // One slot, so the count cannot be anything but 1 for a parser-built node.
        return childCount == 1

    case .Min, .Max:
        // `simplifyForMinMax` (`:371`-`:482`) asserts non-empty children; unreachable through the
        // parser, so an empty node is refused rather than claimed. No upper bound: `rebuildSlot`
        // takes all remaining operands.
        return childCount >= 1

    case .Clamp:
        return childCount >= 1 && childCount <= 3

    case .Hypot:
        // A stateful pass over a variable number of children with a running type tag. No arity
        // condition: `simplify(Hypot&)` has no `ASSERT` on child count, and its executor defines
        // the empty case (returns NaN without calling the functor), which this file reaches the
        // same way via `.unchanged`.
        return true

    case .CalcMix:
        // `simplify(CalcMix&)`, the only alternative whose payload is a `Vector<Item>` rather than
        // a `Child`/`Children`. At least one item is required: with none, the accumulator loop
        // never runs and `:1685` dereferences an empty `std::optional`. Unreachable through the
        // parser, since `consumeCalcMix` requires at least one `<calc-sum>`. No upper bound: the
        // count can only shrink.
        return childCount >= 1

    case .Random:
        // `random( <random-key>? , <calc-sum>, <calc-sum>, <calc-sum>? )`; the key is not a child, so
        // `childCount` is 2 or 3 regardless of whether a key is present.
        return childCount == 2 || childCount == 3

    case .SiblingCount, .SiblingIndex:
        return true

    case .Anchor, .AnchorSize:
        return alternative == .Anchor ? childCount <= 2 : childCount <= 1

    @unknown default:
        // An alternative C++ grew that this file has not been taught. Refusing is the only safe
        // answer.
        return false
    }
}

// MARK: - The options the simplifier reads

/// The two fields of `SimplificationOptions` this file reads, as a `struct` rather than a `class`
/// (a class stored property costs dynamic exclusivity enforcement on every read).
private struct CalcSimplification {
    /// `percentageResolveToDimension(options)` (`+Simplification.cpp:86`-`:107`), precomputed in C++
    /// to avoid a second copy of the `CSS::Category` table here.
    let percentageResolveToDimension: Bool

    /// `options.allowZeroValueLengthRemovalFromSum`, read at one C++ site, `:611`. Not rare: several
    /// production callers pass `true`, so declining when it is set is not an acceptable answer.
    let allowZeroValueLengthRemovalFromSum: Bool

    /// `options.category` as `CSS::Category`'s underlying value, read at one C++ site: step 9.4's
    /// `Category::Percentage` case, `Type::determinePercentHint(options.category)`
    /// (`+Simplification.cpp:885`).
    let category: UInt8

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

}

// MARK: - The leaf type dispatch

private extension CalcSimplification {

    /// Which `getType` overload a numeric leaf reaches. A dispatcher over `NumericKind` rather
    /// than one body shared by two alternatives: `getType(const Percentage&)` applies a conditional
    /// percent hint that `getType(const CanonicalDimension&)` has no analogue for, and sharing one
    /// body gives the wrong hint for `calc(10% * 1em / 1em)`. `nil` means step 9.4 stops folding
    /// and the node keeps its kind.
    @inline(always)
    func numericLeafType(_ leaf: NumericLeaf) -> CalcType? {
        switch leaf.kind {
        case .percentage:
            return percentageLeafType(leaf)

        case .canonicalDimension:
            return canonicalDimensionLeafType(leaf)

        case .number:
            return CalcType()

        case .nonCanonicalDimension:
            // Not a case of step 9.4's switch: it reaches
            // `[](const auto&) -> bool { return false; }` (`+Simplification.cpp:871`, `:866`).
            return nil
        }
    }

    /// `getType(const Percentage&)` (CSSCalcTree.cpp:351-:357): `Type { .percent = 1 }`, plus
    /// `applyPercentHint` if a hint is present. The zero test must be a literal `!= 0` comparison, not
    /// `PercentHint(rawValue:)`'s failure -- that init doesn't fail (see `percentHintFromRawValue`) and
    /// would alias an out-of-range value onto `length` via `applyPercentHint`'s `operator[]`.
    @inline(always)
    func percentageLeafType(_ leaf: NumericLeaf) -> CalcType? {
        var type = CalcType.makePercent()
        if leaf.percentHint != 0 {
            guard let hint = percentHintFromRawValue(leaf.percentHint) else {
                return nil
            }
            type.applyPercentHint(hint)
        }
        return type
    }

    /// `getType(const CanonicalDimension&)` (CSSCalcTree.cpp:359-:362) is `determineType(toCSSUnit(d))`,
    /// called rather than transcribed. `UInt8(exactly:)`, not `UInt8(_:)`, since narrowing the
    /// boundary's `uint16_t` unit back can fail; an out-of-enum value falls through to step 9.5.
    @inline(always)
    func canonicalDimensionLeafType(_ leaf: NumericLeaf) -> CalcType? {
        guard let rawUnit = UInt8(exactly: leaf.unitType),
              let unit = WebCore.CSSUnitType(rawValue: rawUnit) else {
            return nil
        }
        return CalcType.determineType(unit)
    }

    /// `getType(const Child&)` (CSSCalcTree.cpp:384-:387) for a folded numeric leaf. Separate from
    /// `numericLeafType`: that one answers `nil` for a `NonCanonicalDimension` (step 9.4 has no case
    /// for one), this one has a real overload and answers, so merging the two would make one wrong.
    @inline(always)
    func leafType(_ leaf: NumericLeaf) -> CalcType? {
        switch leaf.kind {
        case .number:
            // `getType(const Number&)` is `Type { }` (CSSCalcTree.cpp:346-:349): the identity type.
            return CalcType()
        case .percentage:
            return percentageLeafType(leaf)
        case .canonicalDimension, .nonCanonicalDimension:
            return canonicalDimensionLeafType(leaf)
        }
    }

    /// The eleven-case `CSS::Category` -> numeric-leaf table, shared by step 9.4's result switch and
    /// `zeroValueMatchingChild` (same categories, value 0), so a future category can't be taught to
    /// one caller and not the other. `nil` is each caller's own fall-through.
    @inline(always)
    func numericLeafForCategory(_ resolvedCategory: WebCore.CSS.Category, _ value: Double) -> NumericLeaf? {
        switch resolvedCategory {
        case .Integer, .Number:
            return NumericLeaf.number(value)

        case .Percentage:
            // `Type::determinePercentHint(options.category)` (`:885`-`:886`, `:1462`-`:1463`). The
            // category is the options' one, not the resolved one -- `resolvedCategory` is already known
            // to be `Percentage` here, so passing it would make this case a constant and lose the whole
            // point of the call.
            guard let optionsCategory = WebCore.CSS.Category(rawValue: category) else {
                // Never taken: an imported C++ scoped enum's `init?(rawValue:)` doesn't validate, so
                // this can't fail (see `percentHintFromRawValue`). Kept because it's the spelling that
                // produces a `CSS::Category` to pass, at no cost.
                return nil
            }
            return NumericLeaf.percentage(value, CalcType.determinePercentHint(optionsCategory))

        case .LengthPercentage:
            return NumericLeaf.percentage(value, CalcType.PercentHintValue(.Length))

        case .Length:
            return NumericLeaf.canonical(value, .Px)

        case .Angle:
            return NumericLeaf.canonical(value, .Deg)

        case .AnglePercentage:
            return NumericLeaf.percentage(value, CalcType.PercentHintValue(.Angle))

        case .Time:
            return NumericLeaf.canonical(value, .S)

        case .Frequency:
            return NumericLeaf.canonical(value, .Hz)

        case .Resolution:
            return NumericLeaf.canonical(value, .Dppx)

        case .Flex:
            return NumericLeaf.canonical(value, .Fr)

        @unknown default:
            // A category C++ grew that this file has not been taught. Both C++ switches are
            // exhaustive with no `default`, so growing the enum is a build failure there.
            return nil
        }
    }

}

// MARK: - `canonicalize`, and the relative lengths only the builder can resolve

/// How far `canonicalize` (`+Simplification.cpp:169`-`:287`) gets on the unit alone.
private enum CanonicalizeStep {
    case leaf(NumericLeaf)
    case relativeLength
}

private extension CalcSimplification {

    /// `canonicalize` (`+Simplification.cpp:169`-`:287`) minus its one upcall; see
    /// `CanonicalizeStep` for why the upcall is reported rather than taken here.
    @inline(always)
    func canonicalizeStep(_ value: Double, _ unitType: UInt16) -> CanonicalizeStep {
        func unchanged() -> CanonicalizeStep {
            return .leaf(NumericLeaf(kind: .nonCanonicalDimension, value: value, unitType: unitType, percentHint: 0))
        }
        // `makeCanonical(value, dimension)`. The canonical unit is named rather than the
        // `CanonicalDimension::Dimension`, because `Dimension` does not cross the boundary and
        // `makeNumeric` maps the unit back to it (CSSCalcTree.cpp:187) -- so these five spellings are
        // `toCSSUnit(Dimension)` (CSSCalcTree.h:992) read forwards, and there is no sixth: `Fr` is
        // `Dimension::Flex`, which `canonicalize` has no case for.
        func canonical(_ canonicalized: Double, _ canonicalUnit: WebCore.CSSUnitType) -> CanonicalizeStep {
            return .leaf(NumericLeaf(
                kind: .canonicalDimension,
                value: canonicalized,
                unitType: UInt16(canonicalUnit.rawValue),
                percentHint: 0
            ))
        }

        // `UInt8(exactly:)`, not `UInt8(_:)`, which traps: narrowing the boundary's `uint16_t` unit
        // back must be able to fail. `CSSUnitType(rawValue:)` beside it is not a real check, though --
        // an imported C++ scoped enum's `init?(rawValue:)` accepts any value of the underlying type --
        // so an out-of-enum value falls to `default` below, matching the C++'s `ASSERT_NOT_REACHED`
        // behavior in a shipping build.
        guard let raw = UInt8(exactly: unitType), let unit = WebCore.CSSUnitType(rawValue: raw) else {
            return unchanged()
        }

        switch unit {
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

        case .Rad:
            return canonical(value * degreesPerRadianDouble, .Deg)
        case .Grad:
            return canonical(value * degreesPerGradientDouble, .Deg)
        case .Turn:
            return canonical(value * degreesPerTurnDouble, .Deg)

        case .Ms:
            return canonical(value * WebCore.CSS.secondsPerMillisecond, .S)

        case .Khz:
            return canonical(value * WebCore.CSS.hertzPerKilohertz, .Hz)

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

        default:
            // Every relative length, reported as an upcall rather than listed here: `CSS::toLengthUnit`
            // is the one statement of that membership set, and spelling the units out again would
            // create the second copy it exists to prevent.
            //
            // Safe against a newly added `CSSUnitType` falling in here, which is what the C++'s
            // exhaustive switch gets from `-Wswitch` and this one cannot: the upcall checks
            // `CSS::toLengthUnit` first (`+Simplification.cpp:2857`) and reports unresolved for a
            // unit that is not a length, which `resolvedRelativeLength` turns back into the
            // unchanged dimension. So a new unit is left alone, never mis-converted.
            return .relativeLength
        }
    }

    /// `tryMakeCanonical` (`+Simplification.cpp:182`-`:186`), the one case of `canonicalize` Swift
    /// cannot finish on its own: `Style::resolveLength` reads the `CSSToLengthConversionData` the
    /// builder holds. `resolved == false` is that lambda's `if (conversionData)` answering no, a
    /// normal outcome, and the dimension stays as it is.
    @inline(always)
    func resolvedRelativeLength(
        _ value: Double,
        _ unitType: UInt16,
        _ builder: borrowing WebCore.CSSCalc.CSSCalcSwiftBuilder
    ) -> NumericLeaf {
        let resolved = builder.resolveRelativeLength(value, unitType)
        guard resolved.resolved else {
            return NumericLeaf(kind: .nonCanonicalDimension, value: value, unitType: unitType, percentHint: 0)
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

    /// `simplify(NonCanonicalDimension&)` (`:505`-`:513`) / `canonicalize`
    /// (`+Simplification.cpp:169`-`:287`), both halves: canonicalize if there is enough information,
    /// otherwise leave it alone. Its one caller is `simplifySymbol`, which always holds a builder;
    /// `simplifyNonCanonicalDimension` runs the same two steps itself because it also has to skip the
    /// write when `canonicalize` answers `nullopt`.
    @inline(always)
    func canonicalizedDimension(
        _ value: Double,
        _ unitType: UInt16,
        _ builder: borrowing WebCore.CSSCalc.CSSCalcSwiftBuilder
    ) -> NumericLeaf {
        switch canonicalizeStep(value, unitType) {
        case .leaf(let leaf):
            return leaf
        case .relativeLength:
            return resolvedRelativeLength(value, unitType, builder)
        }
    }

}

// MARK: - The pieces the `Children`-slotted operations share

/// `simplify(Hypot&)`'s five-alternative running type tag (`+Simplification.cpp:1208`-`:1212`), spelled
/// `Variant<std::monostate, NumberTag, PercentageTag, DimensionTag, FailureTag>` in the C++.
private enum HypotTag {
    case unset
    case number
    case percentage
    case dimension(UInt16)
    case failed
}

private extension CalcSimplification {

    // MARK: `hypot()`

    /// Takes the leaf rather than the child, so that the one transcription of
    /// `+Simplification.cpp:1216`-`:1264` serves whatever holds the child.
    @inline(always)
    func hypotElement(_ leaf: NumericLeaf, _ tag: inout HypotTag) -> Double {
        switch tag {
        case .unset:
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
                tag = .failed
                return Double.nan
            }

        case .number:
            guard leaf.kind == .number else {
                tag = .failed
                return Double.nan
            }
            return leaf.value

        case .percentage:
            guard leaf.kind == .percentage else {
                tag = .failed
                return Double.nan
            }
            return leaf.value

        case .dimension(let canonicalUnit):
            guard leaf.kind == .canonicalDimension, leaf.unitType == canonicalUnit else {
                tag = .failed
                return Double.nan
            }
            return leaf.value

        case .failed:
            // Absorbing, and the loop keeps running. See `simplifyHypot`'s note on why this is not a
            // `return`.
            return Double.nan
        }
    }

    // MARK: the merge tables

    /// `std::array<size_t, numberOfNumericIdentityTypes> offsetOfFirstInstance` (`:414`): the merge
    /// is keyed by unit identity in a compile-time fixed-size table, not by a per-term heap array.
    typealias MergeTable = InlineArray<128, UInt32>
    /// `FirstInstance::canRemove` (`:603`), one bit per unit identity. A separate table rather than a
    /// field beside the offset so the common (`Min`/`Max`) case pays for the offsets alone.
    typealias MergeFlags = InlineArray<128, Bool>

    // MARK: `Sum`'s zero-length removal

    /// `isLength(id) && options.allowZeroValueLengthRemovalFromSum` (`:611`).
    @inline(always)
    func lengthRemovalAllowed(_ leaf: NumericLeaf) -> Bool {
        guard allowZeroValueLengthRemovalFromSum else {
            return false
        }
        switch leaf.kind {
        case .number, .percentage:
            return false
        case .canonicalDimension:
            return leaf.unitType == UInt16(WebCore.CSSUnitType.Px.rawValue)
        case .nonCanonicalDimension:
            // `UInt8(exactly:)`, not `UInt8(_:)`, which traps: narrowing the boundary's `uint16_t`
            // unit back must be able to fail. `CSSUnitType(rawValue:)` beside it is not a real
            // check -- an imported C++ scoped enum's `init?(rawValue:)` accepts any value of the
            // underlying type -- but that is exactly the C++'s own behaviour here: a unit outside
            // the 56 `toNumericIdentity` enumerates lands on its `ASSERT_NOT_REACHED` branch and
            // comes back `NumericIdentity::Number`, which `isLength` answers false for. The
            // conservative direction: leave the term in the sum rather than remove it.
            guard let raw = UInt8(exactly: leaf.unitType),
                  let unit = WebCore.CSSUnitType(rawValue: raw) else {
                return false
            }
            var dimension = WebCore.CSSCalc.NonCanonicalDimension()
            dimension.value = 0
            dimension.unit = unit
            return WebCore.CSSCalc.isLength(WebCore.CSSCalc.toNumericIdentity(dimension))
        }
    }

    // MARK: `Product`'s flattened factor list

    /// `numericProduct = Number { .value = childValue->value * numericProduct->value }` (`:734`,
    /// `:736`). The new factor is the left operand, matching the C++'s order: multiplication is
    /// commutative for finite doubles but not for the sign of a NaN result, which IEEE-754 leaves
    /// unspecified.
    @inline(always)
    func multipliedNumericProduct(_ value: Double, _ accumulated: Double?) -> Double {
        if let accumulated {
            return value * accumulated
        }
        return value
    }

}

// MARK: - The entry point

/// Which alternatives the flat simplifier covers, as a mask over the same alternative index
/// `kindMask` is built from.
private enum CalcFlatCoverage {
    /// `&<<`, the masking shift, not `<<`, which costs measurably more per simplification.
    ///
    /// `UInt64`'s `<<` is the smart shift: it is defined for a negative or over-large amount, so it
    /// lowers to a branchy sequence (over-shift to zero, under-shift to zero, `and` by 63, then the
    /// shift). `alternative.rawValue` does not fold at SIL level either, because it goes through
    /// `RawRepresentable`'s witness, so `mask` reaches LLVM as forty copies of that sequence chained
    /// by `or`. LLVM folds the chain while it is small and stops above a size threshold, which this
    /// expression crosses at 40 terms.
    ///
    /// `&<<` deletes the branches: the shift amount is an alternative index, there are 41 of them,
    /// and 41 < 64, so masking by 63 is the identity and no defined behaviour changes.
    @inline(always)
    static func bit(_ alternative: CalcAlternative) -> UInt64 {
        return UInt64(1) &<< UInt64(alternative.rawValue)
    }

    /// A computed `static var`, not a `static let`: a stored global is lazily initialised behind a
    /// `swift_once` guard, which is an atomic load on every read, and this is read once per node by
    /// `CalcFlattenReport.sawAlternative`. Computed, and with `bit` not branching, it folds into the
    /// immediate of that function's single `tst`.
    static var mask: UInt64 {
        return bit(.Number)
            | bit(.Percentage)
            | bit(.CanonicalDimension)
            | bit(.NonCanonicalDimension)
            | bit(.Sum)
            | bit(.Product)
            | bit(.Negate)
            | bit(.Invert)
            | bit(.Min)
            | bit(.Max)
            | bit(.Clamp)
            | bit(.RoundNearest)
            | bit(.RoundUp)
            | bit(.RoundDown)
            | bit(.RoundToZero)
            | bit(.Mod)
            | bit(.Rem)
            | bit(.Abs)
            | bit(.Sign)
            | bit(.Pow)
            | bit(.Sqrt)
            | bit(.Deg2Rad)
            | bit(.Sin)
            | bit(.Cos)
            | bit(.Tan)
            | bit(.Asin)
            | bit(.Acos)
            | bit(.Atan)
            | bit(.Atan2)
            | bit(.Hypot)
            | bit(.Log)
            | bit(.Exp)
            | bit(.Progress)
            | bit(.ProgressNoClamp)
            | bit(.CalcMix)
            | bit(.Symbol)
            | bit(.SiblingCount)
            | bit(.SiblingIndex)
            | bit(.Anchor)
            | bit(.AnchorSize)
            | bit(.Random)
    }
}

/// Simplify a whole tree onto the builder's operand stack, or decline.
@_expose(Cxx)
public func cssCalcSimplifySwift(
    _ root: borrowing WebCore.CSSCalc.Child,
    _ builder: inout WebCore.CSSCalc.CSSCalcSwiftBuilder,
    _ options: WebCore.CSSCalc.CSSCalcSwiftSimplificationOptions
) -> WebCore.CSSCalc.CSSCalcSwiftSimplificationResult {
    let rootInfo = WebCore.CSSCalc.swiftNodeInfo(root)

    // A root that is a numeric leaf with no children never enters the flat machinery. The flat
    // representation exists so that a tree can be rewritten: the stack buffer, the
    // `CalcFlattenReport`, the `OutputSpan` lifecycle, the reverse simplification scan and the
    // recursive emit are all there because a node's children may change shape and a parent has to
    // see them changed. A single numeric leaf is never rewritten structurally --
    // `simplify(Number&)`, `simplify(Percentage&)` and `simplify(CanonicalDimension&)` are
    // unconditional no-ops (`+Simplification.cpp:486`-`:503`) and
    // `simplify(NonCanonicalDimension&)` (`:505`) is a value-for-value canonicalization -- so all
    // of it is overhead on that shape.
    if rootInfo.childCount == 0 {
        switch rootInfo.alternative {
        case .Number, .Percentage, .CanonicalDimension, .NonCanonicalDimension:
            return calcSimplifyNumericLeafRoot(rootInfo, options, &builder)
        default:
            break
        }
    }

    return calcSimplifyFlatTree(root, rootInfo, &builder, options)
}

/// The whole of `cssCalcSimplifySwift` for a root that is a numeric leaf with no children.
@inline(always)
private func calcSimplifyNumericLeafRoot(
    _ info: WebCore.CSSCalc.CSSCalcSwiftNodeInfo,
    _ options: WebCore.CSSCalc.CSSCalcSwiftSimplificationOptions,
    _ builder: inout WebCore.CSSCalc.CSSCalcSwiftBuilder
) -> WebCore.CSSCalc.CSSCalcSwiftSimplificationResult {
    // The same `kindMask` and `nodeCount` the flattening pass would report for a one-node tree, and
    // they have to be the same because they are the coverage measurement: a tree that was finished
    // has to appear in the accounting whichever route it took. One node, one bit.
    let kindMask = UInt64(1) &<< UInt64(info.alternative.rawValue)

    let kind: NumericKind
    switch info.alternative {
    case .Number: kind = .number
    case .Percentage: kind = .percentage
    case .CanonicalDimension: kind = .canonicalDimension
    default: kind = .nonCanonicalDimension
    }
    var leaf = NumericLeaf(
        kind: kind,
        value: info.numericValue,
        unitType: UInt16(info.unitType),
        percentHint: info.percentHint
    )

    if kind == .nonCanonicalDimension {
        // `simplifyNonCanonicalDimension`, with the flat slot taken out of the middle: the same
        // `canonicalizeStep`, the same `resolvedRelativeLength` upcall, and the same two reasons to
        // leave the dimension exactly as it arrived -- `canonicalize` answering `nullopt`, which is
        // the leaf coming back still a `nonCanonicalDimension`, and `setLeaf`'s narrowing guard on a
        // unit that does not fit the flat node's `UInt8`. The second cannot fire, since every unit
        // both routes produce is a `CSSUnitType` enumerator and that enum is `uint8_t`-backed, but it
        // is kept so this case and `setLeaf` cannot diverge on an input neither can receive.
        let simplification = CalcSimplification(
            percentageResolveToDimension: options.percentageResolveToDimension,
            allowZeroValueLengthRemovalFromSum: options.allowZeroValueLengthRemovalFromSum,
            category: options.category
        )
        let canonicalized = simplification.canonicalizedDimension(leaf.value, leaf.unitType, builder)
        if canonicalized.kind != .nonCanonicalDimension, UInt8(exactly: canonicalized.unitType) != nil {
            leaf = canonicalized
        }
    }

    // `isRoot` is unconditionally true: this IS the tree, so the finished leaf is constructed straight
    // into the caller's `Tree` and the operand stack is never touched.
    guard builder.pushLeaf(leaf.boundaryLeaf, true) else {
        // `pushLeaf` refusing a kind outside the four numeric leaves, which this path cannot hand
        // it. Refused rather than asserted: a boundary that came apart falls back to the C++ path.
        return declined(kindMask, 1, nil)
    }
    return WebCore.CSSCalc.CSSCalcSwiftSimplificationResult(
        kindMask: kindMask,
        nodeCount: 1,
        outcome: CSSCalcSwiftSimplificationOutcome.simplified.rawValue,
        declineAlternative: noDeclineAlternative
    )
}

/// Everything a tree that is not a single numeric leaf needs.
@inline(always)
private func calcSimplifyFlatTree(
    _ root: borrowing WebCore.CSSCalc.Child,
    _ rootInfo: WebCore.CSSCalc.CSSCalcSwiftNodeInfo,
    _ builder: inout WebCore.CSSCalc.CSSCalcSwiftBuilder,
    _ options: WebCore.CSSCalc.CSSCalcSwiftSimplificationOptions
) -> WebCore.CSSCalc.CSSCalcSwiftSimplificationResult {
    let simplification = CalcSimplification(
        percentageResolveToDimension: options.percentageResolveToDimension,
        allowZeroValueLengthRemovalFromSum: options.allowZeroValueLengthRemovalFromSum,
        category: options.category
    )

    // `CalcFlatCoverage.mask` holds all 41 alternatives, so the subset test cannot refuse a tree on
    // coverage grounds; what it still refuses is a node `isSimplifiableAlternative` will not touch
    // at all, which falls back to the C++ path. The mask stays a mask rather than becoming an
    // assertion because it is what a new C++ alternative falls out of, and because the same bits
    // carry the blame for a refusal.
    var (report, emitted) = withCalcFlatTree(root, rootInfo, calcFlatStackCapacity) { tree in
        tree.simplify(root, simplification, builder)
        return tree.emitRoot(root, into: &builder)
    }

    // A tree too big for the fixed stack buffer, retried at its exact size. `nodeCount` is exact
    // even when the first pass overflowed, because the pass keeps counting after it stops writing.
    if emitted == nil, report.overflowed, report.everyNodeSimplifiable,
        report.kindMask & ~CalcFlatCoverage.mask == 0 {
        (report, emitted) = calcFlatSimplifyOversized(root, rootInfo, report.nodeCount, simplification, &builder)
    }

    if let emitted {
        guard emitted else {
            // `emit` returning false is a builder contract violation: either the mid-pass
            // `declined` valve, or `pushLeaf`/`rebuildFrom`/`buildOperation` was handed something
            // outside its own contract. None of those has one alternative behind it, so none is
            // blamed -- a confident wrong attribution is worse than none, and an unattributed
            // refusal is the right treatment for a contract violation. A refusal that is a
            // coverage refusal must name what it refused.
            return declined(report.kindMask, report.nodeCount, nil)
        }
        return WebCore.CSSCalc.CSSCalcSwiftSimplificationResult(
            kindMask: report.kindMask,
            nodeCount: report.nodeCount,
            outcome: CSSCalcSwiftSimplificationOutcome.simplified.rawValue,
            declineAlternative: noDeclineAlternative
        )
    }

    // `CalcFlattenReport.writing` fails for three reasons, and `CalcFlatCoverage.mask` being
    // complete at 41 of 41 retires the third: no tree can hold an alternative the flat pass does
    // not cover. The buffer overflow is handled by the exact-size retry above, so what reaches here
    // is a node no port handles at all, which `report.blame` names. The C++ path runs instead.
    return declined(report.kindMask, report.nodeCount, report.blame)
}

/// The oversized-tree retry, kept out of line.
@inline(never)
private func calcFlatSimplifyOversized(
    _ root: borrowing WebCore.CSSCalc.Child,
    _ rootInfo: WebCore.CSSCalc.CSSCalcSwiftNodeInfo,
    _ nodeCount: UInt32,
    _ simplification: CalcSimplification,
    _ builder: inout WebCore.CSSCalc.CSSCalcSwiftBuilder
) -> (report: CalcFlattenReport, result: Bool?) {
    return withCalcFlatTree(root, rootInfo, Int(clamping: nodeCount)) { tree in
        tree.simplify(root, simplification, builder)
        return tree.emitRoot(root, into: &builder)
    }
}

/// `CSSCalcSwiftSimplificationResult::declineAlternative`'s "did not decline, or declined without
/// one alternative to blame" value.
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
@_expose(Cxx)
public func cssCalcCanSimplifySwift(_ root: borrowing WebCore.CSSCalc.Child) -> Bool {
    switch WebCore.CSSCalc.swiftNodeInfo(root).alternative {
    case .Number, .Percentage, .CanonicalDimension:
        // The three the C++ names explicitly. `NonCanonicalDimension` is not among them: its
        // `simplify` canonicalizes when there is conversion data, so it really can change.
        return false

    case .NonCanonicalDimension, .Symbol, .SiblingCount, .SiblingIndex,
         .Sum, .Product, .Negate, .Invert, .Deg2Rad,
         .Min, .Max, .Clamp,
         .RoundNearest, .RoundUp, .RoundDown, .RoundToZero, .Mod, .Rem,
         .Sin, .Cos, .Tan, .Asin, .Acos, .Atan, .Atan2,
         .Pow, .Sqrt, .Hypot, .Log, .Exp, .Abs, .Sign,
         .Random, .Progress, .ProgressNoClamp, .CalcMix, .Anchor, .AnchorSize:
        return true

    @unknown default:
        // An alternative C++ grew that this file has not been taught. `true` is what the C++
        // catch-all would answer for it, and it is the conservative direction anyway: it only ever
        // says "simplifying might change something", which costs a pass and cannot produce a wrong
        // tree.
        return true
    }
}

// MARK: - `calc-mix()`

/// What one pass over a `calc-mix()`'s weight list found.
private struct CalcMixWeightSurvey {
    /// False as soon as any weight is a `Calc` (`:1499`-`:1501`): normalisation is off for the whole
    /// node.
    var canNormalize = true
    /// The sum of every `Raw` weight in item order, zeros included -- the C++'s addition sequence.
    var total = 0.0
    /// `numberOfOmittedWeights` (`:1503`).
    var numberOfOmittedWeights: UInt32 = 0
    /// `numberOfKnownZeroWeights` (`:1495`).
    var numberOfKnownZeroWeights: UInt32 = 0
}

/// One item's disposition under spec steps 1 to 5, as values.
private struct CalcMixItemPlan {
    /// Whether the item is in the rebuilt list at all.
    let survives: Bool
    /// The item's effective weight as a `<percentage>`, which the accumulator divides by 100
    /// (`+Simplification.cpp:1622`). Meaningful only where `canNormalize` held, which is exactly
    /// where the accumulator runs.
    let weight: Double
    /// Whether the rebuild carries `weight` -- step 2's `(100% - specified sum) / n` or step 4's
    /// `weight * 100% / total` -- or the original item's own weight, unchanged.
    let replaceWeight: Bool

    static let dropped = CalcMixItemPlan(survives: false, weight: 0, replaceWeight: false)
}

/// What spec steps 1 to 5 (`+Simplification.cpp:1509`-`:1611`) do to one item, given a survey of
/// the whole weight list.
@inline(always)
private func calcMixItemPlan(
    _ weight: WebCore.CSSCalc.CSSCalcSwiftCalcMixWeight,
    _ survey: CalcMixWeightSurvey
) -> CalcMixItemPlan {
    // `item.weight && item.weight->isKnownZero()`, which the C++ spells inline at each of its four
    // sites. `isKnownZero()` is `isRaw() && value == 0` (CSSPrimitiveNumeric.h:142), so a `Calc`
    // weight is never one however it would evaluate.
    let isKnownZero = weight.present && weight.isRaw && weight.value == 0

    if !survey.canNormalize {
        // `:1509`-`:1529`. Normalisation is off for the whole node and the C++ returns `{ }` on
        // every path out of this branch, so the accumulator never runs and every survivor keeps its
        // own weight. Its two sub-branches -- nothing to remove (`:1511`-`:1513`) and drop the
        // known-zeros (`:1518`-`:1526`) -- are one line here, because with
        // `numberOfKnownZeroWeights == 0` no item is `isKnownZero` and the condition never fires.
        return isKnownZero
            ? .dropped
            : CalcMixItemPlan(survives: true, weight: weight.value, replaceWeight: false)
    }

    if survey.total >= 100 {
        guard weight.present, !isKnownZero else {
            return .dropped
        }
        // `item.weight->raw()->value * normalizationFactor` (`:1552`, `:1560`). A multiply, as the
        // C++ has it, not a divide by `total / 100`; the two differ in the last bit.
        return CalcMixItemPlan(
            survives: true,
            weight: weight.value * (100.0 / survey.total),
            replaceWeight: true
        )
    }

    if weight.present {
        // `:1576`-`:1577`, `:1596`-`:1597`: a known-zero weight is dropped wherever there is one to
        // drop. The `numberOfKnownZeroWeights > 0` half is implied by `isKnownZero` and is kept
        // because the C++ spells it.
        if isKnownZero, survey.numberOfKnownZeroWeights > 0 {
            return .dropped
        }
        return CalcMixItemPlan(survives: true, weight: weight.value, replaceWeight: false)
    }

    return CalcMixItemPlan(
        survives: true,
        weight: (100.0 - survey.total) / Double(survey.numberOfOmittedWeights),
        replaceWeight: true
    )
}

private extension CalcSimplification {

    /// Whether the accumulator and this item are the same alternative and agree on that alternative's
    /// own identity. `unitsMatch` is not the same test: it compares raw `CSSUnitType`s, where the
    /// C++ compares each kind's own identity (`:1613`-`:1689`).
    @inline(always)
    func calcMixAccumulatorAgrees(_ current: NumericLeaf, _ leaf: NumericLeaf) -> Bool {
        guard current.kind == leaf.kind else {
            return false
        }
        switch leaf.kind {
        case .number:
            return true
        case .percentage:
            return current.percentHint == leaf.percentHint
        case .canonicalDimension:
            return current.unitType == leaf.unitType
        case .nonCanonicalDimension:
            return current.unitType == leaf.unitType
        }
    }
}

// MARK: - The flat node
//
// This began (R151) as a probe answering one question: what does converting a `CSSCalc::Child` into
// a flat Swift array cost? The answer made it the production representation. Simplification runs as
// a reverse loop over the array -- no 41-way variant dispatch per access, no `UniqueRef<Op>` pointer
// chase per node, no per-node `Children` vector, no operand stack, and no boundary crossing per node
// at all -- and the conversion pass also computes `nodeCount`, `kindMask` and the decline predicate
// on the way through, so it REPLACED the separate coverage pre-pass rather than adding to it.

/// One node of the flat tree.
///
/// Children are named by INDEX, not by pointer, which is what makes the whole structure `Copyable`,
/// storable in an ordinary Swift buffer, and free of the `~Escapable` problem that forced the handle
/// design in the first place. Same move as the tokenizer island's offset-in-the-pointer-slot design.
///
/// DEFINED IN SWIFT, and that is the point of the exercise rather than an aesthetic preference: the
/// declaration briefly lived in CSSCalcSwiftTypes.h so that an `emitFlatTree` upcall could take a
/// `Span` of these, and every consequence of that ran the wrong way -- C++ owning the shape of a
/// structure only Swift builds, a size `static_assert` to keep the two in step, and a boundary type
/// that grows a field every time the simplifier learns an alternative. Emit takes no span, so
/// nothing on the C++ side names this type and nothing has to.
///
/// `alternative` is the imported C++ enum rather than a Swift mirror of it, so a `switch` here is
/// checked against the one list (`CSS_CALC_SWIFT_FOR_EACH_ALTERNATIVE`). That only diagnoses a 42nd
/// alternative in the switches that enumerate every case and close with `@unknown default:` --
/// `isSimplifiableAlternative` and `cssCalcCanSimplifySwift`. `isNumericLeaf`, `numericLeaf` and
/// `simplifyNode` close with a bare `default:`, which takes a new alternative silently, so what
/// keeps it from being mis-handled there is the per-tree refusal rather than the compiler.
///
/// THE CHILD LIST IS A LINKED LIST, `firstChild` plus `nextSibling`, and that is load-bearing rather
/// than a style choice. The previous shape was a side table of child indices with each node owning a
/// contiguous run, and css-values-4 step 8.1 -- splice a nested `Sum`'s terms into its parent -- makes
/// a run LONGER than it started, so the table had to be bump-allocated and could reach O(N^2) slots
/// on a left-nested chain of sums. A linked list splices by relinking: O(1), and **no storage beyond
/// the N nodes**. That is what lets the whole flat tree be one fixed-size buffer sized from a node
/// count known in advance, which is what lets it live on the stack. A per-simplification heap buffer
/// was measured at 617 retired instructions on this path -- 4.9x the C++ arm's ENTIRE single-node
/// simplification -- so "just one allocation" was never an acceptable answer.
///
/// Random access to child `k` is O(k) rather than O(1) as a result. That is the right trade: calc
/// arities are a handful, every hot walk is sequential, and the alternative cost a buffer that could
/// not be stack-allocated.
fileprivate struct CalcFlatNode {
    /// The numeric payload of a leaf. Meaningless for an operation.
    var value: Double

    /// The node's own `Type`, carried rather than recomputed.
    ///
    /// `rebuildFrom` takes the ORIGINAL node's type (`CSSCalcTree+Simplification.cpp:2147`), which is
    /// what `copyAndSimplify` does at `:1821`: a node whose children simplified but whose kind did
    /// not change keeps its type. A flat node has no original to reach at emit time, so it carries
    /// the type from flattening instead. The alternative -- recomputing `toType` during emit -- is
    /// what the R151 emit probe did, and it is both extra work per node and a different answer for
    /// any node whose children changed shape.
    var type: CalcType

    /// The first child's index, or `CalcFlatNode.noNode` when there are none.
    var firstChild: UInt32
    /// The next sibling in the parent's list, or `CalcFlatNode.noNode`.
    var nextSibling: UInt32
    /// How many children the list holds. Derivable by walking it, and kept because arity is tested
    /// far more often than the list is walked.
    var childCount: UInt32

    /// The pre-order index this node had when the tree was flattened.
    ///
    /// Not the same as the node's current slot once simplification starts moving nodes about --
    /// promoting a grandchild copies a node into an ancestor's slot, and the copy has to keep naming
    /// the ORIGINAL `CSSCalc::Child` it came from, because that is the only route back to a payload
    /// no fixed-size node can hold: an `AtomString` element name, a nested `CSSCalcValue` weight, an
    /// `AnchorSide` subtree, a `Random::Sharing`.
    var origin: UInt32

    var valueID: UInt16
    var unitType: UInt8
    var alternative: WebCore.CSSCalc.CSSCalcSwiftAlternative
    var percentHint: UInt8
    /// See `CalcFlatNodeFlags`.
    var flags: UInt8

    /// The end-of-list sentinel, and the "no such node" answer.
    ///
    /// `UInt32.max` cannot collide with a real index: the index space is bounded by the node count,
    /// and a tree of 2^32 nodes cannot be built -- a `Child` is 24 bytes, so it would need 96 GB.
    static let noNode: UInt32 = .max
}

/// The bits on `CalcFlatNode.flags`.
///
/// A bitfield rather than separate `Bool`s, so the node stays inside the 8-byte tail slot it shares
/// with `valueID`, `unitType`, `alternative` and `percentHint`, and each further predicate costs
/// nothing.
fileprivate enum CalcFlatNodeFlags {
    /// `clamp()` whose MINIMUM bound is the keyword `none` rather than a subtree.
    ///
    /// Neither the child count nor the alternative can answer this: `clamp(none, VAL, MAX)` and
    /// `clamp(MIN, VAL, none)` both report two children, because `Child::operator[]` skips a
    /// `ChildOrNone` holding the keyword entirely. The reading boundary answers it with two
    /// dedicated `CSSCalcSwiftNodeKind`s (`CSSCalcSwiftTypes.h:154-155`); here it is a bit, captured
    /// once during flattening.
    static let clampNoneMinimum: UInt8 = 1 << 0
    /// `clamp()` whose MAXIMUM bound is the keyword `none`.
    static let clampNoneMaximum: UInt8 = 1 << 1
    /// `anchor()`'s `<anchor-side>` is a subtree rather than a keyword, so it occupies child slot 0
    /// and the fallback, if there is one, is slot 1.
    static let anchorSideIsSubtree: UInt8 = 1 << 2
    /// This node is inside an `anchor()`'s `<anchor-side>` subtree.
    ///
    /// **Never simplify one.** `simplify(Anchor&)` COPIES the side (`+Simplification.cpp:1797`)
    /// rather than simplifying it, so folding it would turn `anchor(--a calc(25% + 25%))` into
    /// `anchor(--a 50%)`, which the C++ does not do. The flattening pass still has to VISIT the
    /// subtree -- an alternative this file has not been taught, sitting inside a side, still has to
    /// decline the whole tree -- so the distinction has to be a mark rather than an omission.
    static let insideAnchorSide: UInt8 = 1 << 3
}

/// Where a pre-order descent over the original tree got to.
fileprivate enum CalcOriginDescent<R> {
    /// The target was not in this subtree, which spans this many pre-order indices.
    case passed(UInt32)
    /// The target was reached, and this is what `body` answered about it.
    case reached(R)
}

/// Run `body` on the original node whose pre-order index is `target`, or answer nil if no node has
/// that index.
///
/// It needs no boundary change of its own. `CalcFlatNode.origin` already names the original node,
/// and every upcall that needs one -- `rebuildFrom`, `pushCopyOf`, `resolveStyleCoupledValue`,
/// `swiftCalcMixItemWeight` -- already existed. `rebuildFrom` in particular recovers the operation
/// from the original's own variant tag, fills its slots generically over the tuple conformance, and
/// takes `getType(alternative)`, which is the same type the flat node carries because `calcFlatten`
/// read it off the same node. So an alternative whose payload a fixed-size flat node cannot hold
/// needs a fold and a mask bit, and no boundary change at all.
///
/// A recursive descent rather than a lookup table, which is forced rather than chosen: a
/// `CSSCalc::Child` is move-only and `~Copyable`, so no Swift container may hold one and there is
/// no array of them to index. Keeping the borrow on the call stack is the whole technique.
///
/// A body rather than a selector, so that the four upcalls that need an original share one walk
/// instead of one walk each. A selector byte read back at the bottom of the descent would
/// re-derive a dispatch that is already known; the closure is non-escaping and specializes away.
///
/// It is costly per node stepped past -- two generic variant visits per
/// step, since `Child::childCount()` is a `WTF::switchOn` over 41 alternatives plus a `WTF::apply`
/// over the tuple, and `operator[]` is another. The walk visits exactly the nodes at pre-order
/// indices below `target`, plus the target, so there is nothing to prune and the cost is O(target)
/// per node served.
///
/// FIXME: have `calcFlatten` record each node's original subtree size in a side table indexed by
/// origin, for trees whose `kindMask` says an origin route will be taken. The walk could then skip
/// a sibling subtree by reading its size instead of entering it, making it O(depth) with one
/// `operator[]` per level, at the cost of a second stack buffer and a conditional store per node
/// during flattening.
///
/// `Child::childCount()` rather than `swiftNodeInfo`, because the walk needs the arity and nothing
/// else; both are the same generic visit.
fileprivate func withCalcOriginalNode<R>(
    _ root: borrowing WebCore.CSSCalc.Child,
    _ target: UInt32,
    _ body: (borrowing WebCore.CSSCalc.Child) -> R
) -> R? {
    switch calcDescendToOrigin(root, 0, target, body) {
    case .reached(let answer):
        return answer
    case .passed:
        return nil
    }
}

fileprivate func calcDescendToOrigin<R>(
    _ node: borrowing WebCore.CSSCalc.Child,
    _ index: UInt32,
    _ target: UInt32,
    _ body: (borrowing WebCore.CSSCalc.Child) -> R
) -> CalcOriginDescent<R> {
    if index == target {
        return .reached(body(node))
    }

    // Pre-order: the first child is always the next index, and each later child starts after its
    // predecessor's whole subtree. Exactly the numbering `calcFlatten` assigned, which is why
    // `origin` means the same thing on both sides.
    var next = index &+ 1
    var childIndex = 0
    let childCount = node.childCount()
    while childIndex < childCount {
        switch calcDescendToOrigin(node[childIndex], next, target, body) {
        case .reached(let answer):
            return .reached(answer)
        case .passed(let size):
            next &+= size
        }
        childIndex += 1
    }
    return .passed(next &- index)
}

/// The two origin routes, kept out of line.
@inline(never)
fileprivate func calcEmitFromOrigin(
    _ target: UInt32,
    _ operands: UInt32,
    _ copyWhole: Bool,
    _ isRoot: Bool,
    _ original: borrowing WebCore.CSSCalc.Child,
    _ builder: inout WebCore.CSSCalc.CSSCalcSwiftBuilder
) -> Bool {
    if copyWhole {
        return withCalcOriginalNode(original, target) { builder.pushCopyOf($0, isRoot) } != nil
    }
    return withCalcOriginalNode(original, target) { builder.rebuildFrom($0, operands, isRoot) } ?? false
}

/// `calc-mix()`'s emit route: the plan recomputed, its weights pushed, and then the same generic
/// `rebuildFrom` every other origin-routed alternative uses.
@inline(never)
fileprivate func calcEmitCalcMix(
    _ target: UInt32,
    _ operands: UInt32,
    _ isRoot: Bool,
    _ original: borrowing WebCore.CSSCalc.Child,
    _ builder: inout WebCore.CSSCalc.CSSCalcSwiftBuilder
) -> Bool {
    return withCalcOriginalNode(original, target) { node -> Bool in
        let itemCount = UInt32(clamping: node.childCount())

        var survey = CalcMixWeightSurvey()
        var index: UInt32 = 0
        while index < itemCount {
            // `&+=` throughout: every counter here is bounded by `itemCount`, which is
            // `node.childCount()` of a `calc-mix()` already in memory, clamped into `UInt32`.
            let weight = WebCore.CSSCalc.swiftCalcMixItemWeight(node, index)
            if !weight.present {
                survey.numberOfOmittedWeights &+= 1
            } else if weight.isRaw {
                if weight.value == 0 {
                    survey.numberOfKnownZeroWeights &+= 1
                }
                survey.total += weight.value
            } else {
                survey.canNormalize = false
            }
            index += 1
        }

        // In item order, which is the order `rebuildSlot(const Vector<CalcMix::Item>&)` pairs them
        // with the operands. The operands are already on the stack: `emit` pushed the surviving flat
        // children before the switch that reached here, and a nested `calc-mix()` consumed its own
        // weights inside that recursion, so the stack is back where it started.
        var pushed: UInt32 = 0
        index = 0
        while index < itemCount {
            let plan = calcMixItemPlan(WebCore.CSSCalc.swiftCalcMixItemWeight(node, index), survey)
            if plan.survives {
                builder.pushCalcMixItemWeight(index, plan.weight, plan.replaceWeight)
                pushed &+= 1
            }
            index += 1
        }
        guard pushed == operands else {
            return false
        }
        return builder.rebuildFrom(node, operands, isRoot)
    } ?? false
}

fileprivate extension CalcFlatNode {
    /// The four numeric leaves -- the only alternatives that carry a foldable value.
    var isNumericLeaf: Bool {
        switch alternative {
        case .Number, .Percentage, .CanonicalDimension, .NonCanonicalDimension: return true
        default: return false
        }
    }

    /// This node as the boundary's leaf representation, or nil if it is not one of the four.
    var numericLeaf: NumericLeaf? {
        let kind: NumericKind
        switch alternative {
        case .Number: kind = .number
        case .Percentage: kind = .percentage
        case .CanonicalDimension: kind = .canonicalDimension
        case .NonCanonicalDimension: kind = .nonCanonicalDimension
        default: return nil
        }
        return NumericLeaf(kind: kind, value: value, unitType: UInt16(unitType), percentHint: percentHint)
    }
}

// MARK: - The flat tree

/// The whole flat tree: one buffer of `CalcFlatNode`, and nothing else.
///
/// `~Escapable`, because the storage is a `MutableSpan` over a buffer the caller owns rather than
/// anything this type allocates. See `withCalcFlatTree`, which sizes the buffer from a node count
/// the flattening pass has already computed and puts it on the stack. Nothing here allocates, and
/// there is no second buffer to keep in step.
///
/// Pre-order, so a parent's index is always less than any of its descendants'. That one property is
/// what makes simplification a plain reverse loop with no recursion and no work list: counting down
/// from `count - 1` reaches every child before its parent, which is exactly the order
/// `copyAndSimplify` recurses in (`+Simplification.cpp:1810`). A pass holding only a read-only
/// handle on the original tree and a write-only operand stack cannot do that, because it has
/// nowhere to put a simplified child.
fileprivate struct CalcFlatTree: ~Escapable, ~Copyable {
    var nodes: MutableSpan<CalcFlatNode>
    /// How many of `nodes` are live. The span is sized to the whole tree up front, so this only
    /// counts up during flattening and never moves afterwards.
    var count: Int

    /// A fold discovered mid-pass that it cannot finish, so the whole tree is refused.
    ///
    /// `emitRoot` tests it once and the tree never reaches `emit`, at which point
    /// `cssCalcSimplifySwift` reports `.declined` and the C++ path runs. The alternative -- leaving
    /// the node as it arrived -- is a silently wrong computed value.
    ///
    /// Whole-tree rather than per-node because that is what the boundary can express: the operand
    /// stack has no pop, so a fold that gives up after its children are already operands cannot put
    /// the tree back.
    var declined = false

    @_lifetime(copy storage)
    init(storage: consuming MutableSpan<CalcFlatNode>, count: Int) {
        self.nodes = storage
        self.count = count
    }
}

/// Everything the single flattening pass reports about the tree it walked.
fileprivate struct CalcFlattenReport {
    /// Every node in the whole tree, including any past the point where writing stopped.
    var nodeCount: UInt32 = 0
    /// One bit per `CSSCalcSwiftAlternative` seen, over the whole tree for the same reason.
    var kindMask: UInt64 = 0
    /// The first unhandled alternative in pre-order.
    var blame: CalcAlternative? = nil
    /// Whether every node is one this file can simplify at all.
    var everyNodeSimplifiable = true
    /// The buffer filled up. Nodes past that point are counted and masked but not written, so
    /// `nodeCount` still sizes an exact retry.
    var overflowed = false

    /// Whether the nodes written so far can still become a flat tree. Two ways to lose it, and both
    /// are monotone, so once this is false it stays false and the pass degrades to a plain walk: it
    /// keeps crossing and counting, because the count and the mask have to describe every tree
    /// seen, but it writes nothing more and stops paying `getType` and `operationInfo` for nodes no
    /// flat tree will hold.
    var writing = true

    /// Record `alternative` in `kindMask`.
    @inline(always)
    mutating func sawAlternative(_ alternative: CalcAlternative) {
        kindMask |= UInt64(1) &<< UInt64(alternative.rawValue)
    }

    /// Whether every alternative seen so far is one the flat port covers. Asked once per tree.
    var everyAlternativeCovered: Bool {
        return kindMask & ~CalcFlatCoverage.mask == 0
    }

    /// A node no port handles at all. The first one in pre-order is the one blamed, so widening this
    /// file's coverage can only move the blame outward.
    @inline(always)
    mutating func sawUnsimplifiableNode(_ alternative: CalcAlternative) {
        if blame == nil {
            blame = alternative
        }
        everyNodeSimplifiable = false
        writing = false
    }

    /// The buffer filled up. The walk continues, so `nodeCount` still sizes an exact retry.
    @inline(always)
    mutating func sawOverflow() {
        overflowed = true
        writing = false
    }
}

/// Flatten `node`'s subtree in pre-order onto `out`, and return its index.
///
/// ONE `swiftNodeInfo` crossing per node, and it is the ONLY per-node read crossing this file makes:
/// this pass IS the coverage walk, and every pass downstream reads the flat array. The ROOT's crossing
/// is made by `cssCalcSimplifySwift`, which needs the answer to choose a route, and handed in here --
/// so the count is still one per node.
///
/// Appended rather than written at an index, which is what removes the placeholder fill
/// `withCalcFlatTree` used to need: `OutputSpan` hands out initialized storage only for what has been
/// appended, so a buffer sized for the worst case costs a stack pointer adjustment and nothing per
/// unused slot. Only two links are patched afterwards, both into the written prefix.
///
/// `firstChild` is `me + 1` rather than the index child 0 reports, and that is exact rather than an
/// approximation: appending is pre-order, so a node's first child is always the next slot.
///
/// Tree order, not serialization order: `swiftSerializationChildIndex` sorts a `Sum`'s and a
/// `Product`'s children by unit for the serializer, which would silently permute a multi-unit sum
/// here.
fileprivate func calcFlatten(
    _ node: borrowing WebCore.CSSCalc.Child,
    _ info: WebCore.CSSCalc.CSSCalcSwiftNodeInfo,
    _ inheritedFlags: UInt8,
    _ out: inout OutputSpan<CalcFlatNode>,
    _ report: inout CalcFlattenReport
) -> UInt32 {
    return calcFlattenNodeWithInfo(node, info, inheritedFlags, &out, &report)
}

/// `calcFlattenNode` for a node whose `info` the caller already has. The child loops do not have
/// it: they reach a child through `Child::operator[]` and have to ask. The root's caller does,
/// because `cssCalcSimplifySwift` reads it to decide whether the tree needs a flat pass at all.
@inline(always)
fileprivate func calcFlattenNode(
    _ node: borrowing WebCore.CSSCalc.Child,
    _ inheritedFlags: UInt8,
    _ out: inout OutputSpan<CalcFlatNode>,
    _ report: inout CalcFlattenReport
) -> UInt32 {
    // One crossing per node: `info()` answers the discriminant, the child count and every POD
    // payload together, because they all come off the same variant tag.
    return calcFlattenNodeWithInfo(node, WebCore.CSSCalc.swiftNodeInfo(node), inheritedFlags, &out, &report)
}

/// The per-node body, separated from `calcFlattenSubtree` so that a leaf child does not pay that
/// function's whole frame -- seven `stp`/`ldp` pairs and fourteen callee-saved registers, which
/// exist for the operation path's `getType`, `swiftOperationInfo`, child loop and
/// `Child::operator[]`, none of which a leaf reaches.
@inline(always)
fileprivate func calcFlattenNodeWithInfo(
    _ node: borrowing WebCore.CSSCalc.Child,
    _ info: WebCore.CSSCalc.CSSCalcSwiftNodeInfo,
    _ inheritedFlags: UInt8,
    _ out: inout OutputSpan<CalcFlatNode>,
    _ report: inout CalcFlattenReport
) -> UInt32 {
    // `&+=` and `&<<`, for the reason `CalcFlatCoverage.bit` gives: `+=` is overflow-checked and
    // `<<` is the smart shift, which is defined for an over-large amount and so carries a
    // `cmp`/`csel` pair the alternative index can never need -- there are 41 of them and the mask
    // is 64 bits wide. `nodeCount` cannot wrap either: it counts nodes of a tree that is already in
    // memory.
    report.nodeCount &+= 1
    report.sawAlternative(info.alternative)

    if !isSimplifiableAlternative(info.alternative, info.childCount) {
        report.sawUnsimplifiableNode(info.alternative)
    }
    // A `guard` rather than a plain `if`, and spelled `count < capacity` rather than
    // `freeCapacity == 0`, so that the append below is reached only on a path where
    // `OutputSpan.append`'s own precondition is an established fact in the form it is written in.
    guard out.count < out.capacity else {
        report.sawOverflow()
        return calcFlattenSubtree(node, info, inheritedFlags, &out, &report)
    }

    switch info.alternative {
    case .Number, .Percentage, .CanonicalDimension, .NonCanonicalDimension,
         .Symbol, .SiblingCount, .SiblingIndex:
        if info.childCount == 0, report.writing {
            let me = UInt32(truncatingIfNeeded: out.count)
            out.append(CalcFlatNode(
                value: info.numericValue,
                type: CalcType(),
                firstChild: CalcFlatNode.noNode,
                nextSibling: CalcFlatNode.noNode,
                childCount: 0,
                origin: me,
                valueID: info.valueID,
                unitType: info.unitType,
                alternative: info.alternative,
                percentHint: info.percentHint,
                flags: inheritedFlags & CalcFlatNodeFlags.insideAnchorSide))
            return me
        }
    default:
        break
    }

    return calcFlattenSubtree(node, info, inheritedFlags, &out, &report)
}

/// Everything a node with children needs, and the only recursive function in the pass.
@inline(never)
fileprivate func calcFlattenSubtree(
    _ node: borrowing WebCore.CSSCalc.Child,
    _ info: WebCore.CSSCalc.CSSCalcSwiftNodeInfo,
    _ inheritedFlags: UInt8,
    _ out: inout OutputSpan<CalcFlatNode>,
    _ report: inout CalcFlattenReport
) -> UInt32 {
    // `out.count < out.capacity` is re-established here, and it is not redundant with the identical
    // guard `calcFlattenNodeWithInfo` makes before every call that reaches the append below. This
    // function is `@inline(never)`, and a fact established in a caller does not cross that
    // boundary; there is no safe spelling that publishes it across, so without this the append at
    // the end carries `OutputSpan.append`'s own `_precondition(_count < capacity)`
    // (`OutputSpan.swift:300`) as a trap.
    guard report.writing, out.count < out.capacity else {
        if out.count >= out.capacity {
            report.sawOverflow()
        }
        var index: UInt32 = 0
        while index < info.childCount {
            _ = calcFlattenNode(node[Int(index)], inheritedFlags, &out, &report)
            index += 1
        }
        return CalcFlatNode.noNode
    }

    // `truncatingIfNeeded` rather than the trapping `UInt32(_:)`: `out.count` is bounded by the
    // buffer's capacity, which `withCalcFlatTree` sized from a `UInt32` node count, so the value
    // cannot exceed `UInt32.max` and the trapping conversion's range test is two instructions per
    // node for a condition the caller has already established.
    let me = UInt32(truncatingIfNeeded: out.count)

    // Only `insideAnchorSide` propagates: it describes where the slot is, and the whole point of it
    // is that it reaches every descendant. The other three describe the node itself, so they are
    // masked out of what arrived rather than OR-ed into it. Getting this wrong is not cosmetic --
    // an inherited `anchorSideIsSubtree` makes `sideRoot` below true for child 0 of every node
    // under an `anchor()`, so `anchor(--a calc(25% + 25%), 1px + 2px)` would mark the fallback
    // sum's first term as unsimplifiable; an inherited `clampNoneMinimum` makes a nested
    // `clamp(MIN, VAL, none)` claim both bounds are the keyword.
    var flags = inheritedFlags & CalcFlatNodeFlags.insideAnchorSide
    switch info.kind {
    case .ClampWithNoneMinimum: flags |= CalcFlatNodeFlags.clampNoneMinimum
    case .ClampWithNoneMaximum: flags |= CalcFlatNodeFlags.clampNoneMaximum
    default: break
    }

    if info.alternative == .Anchor, !WebCore.CSSCalc.swiftOperationInfo(node).anchorSideIsKeyword {
        flags |= CalcFlatNodeFlags.anchorSideIsSubtree
    }

    let carriesType: Bool
    switch info.alternative {
    case .Number, .Percentage, .CanonicalDimension, .NonCanonicalDimension,
         .Symbol, .SiblingCount, .SiblingIndex:
        carriesType = false
    default:
        carriesType = true
    }

    out.append(CalcFlatNode(
        value: info.numericValue,
        type: carriesType ? WebCore.CSSCalc.getType(node) : CalcType(),
        firstChild: info.childCount != 0 ? me &+ 1 : CalcFlatNode.noNode,
        nextSibling: CalcFlatNode.noNode,
        childCount: info.childCount,
        origin: me,
        valueID: info.valueID,
        unitType: info.unitType,
        alternative: info.alternative,
        percentHint: info.percentHint,
        flags: flags))

    var previous = CalcFlatNode.noNode
    var index: UInt32 = 0
    while index < info.childCount {
        let sideRoot = (flags & CalcFlatNodeFlags.anchorSideIsSubtree) != 0 && index == 0
        let child = calcFlattenNode(node[Int(index)], sideRoot ? flags | CalcFlatNodeFlags.insideAnchorSide : flags, &out, &report)
        // `report.writing` is re-read rather than remembered: a descendant can be the node that
        // fills the buffer or the node that is not simplifiable, and after either one `child` is
        // `noNode` and `previous` may name a slot that no longer means what it did.
        if previous != CalcFlatNode.noNode, report.writing {
            var written = out.mutableSpan
            written[Int(previous)].nextSibling = child
        }
        previous = child
        index += 1
    }
    return me
}

fileprivate extension CalcFlatTree {
    /// The `k`th child of node `i`, or nil if it has fewer than `k + 1`.
    func child(_ i: Int, _ k: Int) -> Int? {
        var cursor = nodes[i].firstChild
        var remaining = k
        while cursor != CalcFlatNode.noNode {
            if remaining == 0 { return Int(cursor) }
            // `&-`: `remaining` is only decremented on the branch where it is not 0, and it starts
            // at `k`, which is a non-negative literal or a 0-or-1 `UInt32` at every call site.
            remaining &-= 1
            cursor = nodes[Int(cursor)].nextSibling
        }
        return nil
    }

    /// `getType(const Child&)` (`CSSCalcTree.cpp:453`-`:456`) for the node this slot will emit.
    func emittedType(_ node: CalcFlatNode, _ options: CalcSimplification) -> CalcType? {
        switch node.alternative {
        case .Number, .Percentage, .CanonicalDimension, .NonCanonicalDimension:
            guard let leaf = node.numericLeaf else {
                return nil
            }
            return options.leafType(leaf)

        case .Symbol:
            guard let unit = WebCore.CSSUnitType(rawValue: node.unitType) else {
                // Never taken: an imported C++ scoped enum's `init?(rawValue:)` does not validate.
                return nil
            }
            return CalcType.determineType(unit)

        case .SiblingCount, .SiblingIndex:
            return CalcType()

        default:
            return node.type
        }
    }
}

/// The largest tree the fixed-size stack buffer holds, which is a stdlib threshold rather than a
/// taste: `withTemporaryAllocation` uses `Builtin.stackAlloc` only while the request is at most 1024
/// bytes (`TemporaryAllocation.swift`'s `_isStackAllocationSafe`), and falls back to `malloc` above
/// that. `CalcFlatNode` is 40 bytes, so 25 nodes is 1000 and 26 would silently start heap-allocating
/// on every simplification, which costs more than the whole pass. Trees above
/// this take the exact-size retry, which pays the malloc it would have paid anyway.
fileprivate let calcFlatStackCapacity = 25

/// Flatten `root` into a stack buffer of `capacity` nodes and, if the result is usable, hand the
/// tree to `body`.
@inline(always)
fileprivate func withCalcFlatTree<R>(
    _ root: borrowing WebCore.CSSCalc.Child,
    _ rootInfo: WebCore.CSSCalc.CSSCalcSwiftNodeInfo,
    _ capacity: Int,
    _ body: (inout CalcFlatTree) -> R
) -> (report: CalcFlattenReport, result: R?) {
    return withTemporaryAllocation(of: CalcFlatNode.self, capacity: capacity) { out in
        var report = CalcFlattenReport()
        _ = calcFlatten(root, rootInfo, 0, &out, &report)
        // `everyAlternativeCovered` beside `writing`, and the only place the coverage subset test
        // is asked -- see `CalcFlattenReport.writing`. A tree holding an alternative the flat port
        // does not cover is flattened in full and discarded unread here.
        guard report.writing, report.everyAlternativeCovered else {
            return (report, nil)
        }
        // `out.count` into a local first: `mutableSpan` is a mutating accessor, so reading the count
        // in the same expression is two overlapping accesses to `out` and the exclusivity checker
        // rejects it (#ExclusivityViolation).
        let written = out.count
        var tree = CalcFlatTree(storage: out.mutableSpan, count: written)
        return (report, body(&tree))
    }
}

// MARK: The flat simplifier

// The `nodes[...]` bounds checks below are deliberate. Routing every node index through a
// validating accessor was built and measured, and it is slower on every multi-node band: the added
// guards push `CalcFlatTree.simplify`, and then `resolveRelativeLength` one level down, past
// inliner thresholds. All three variants tried are smaller than this file in static instruction count
// and all three are slower, so static size is no guide here.

/// `if ((firstInstance.offset - 1) == i && !firstInstance.canRemove)` (`+Simplification.cpp:700`),
/// plus its non-`Numeric` overload (`:707`) -- the C++'s own survivor test, asked of a flat child.
@inline(always)
private func calcFlatSumSurvives(
    _ leaf: NumericLeaf?,
    _ index: Int,
    _ offsets: borrowing CalcSimplification.MergeTable,
    _ canRemove: borrowing CalcSimplification.MergeFlags
) -> Bool {
    // `[](const auto&)` (`:707`): "Non-numeric values are not eligible for merge or removal", so one
    // always survives.
    guard let leaf else {
        return true
    }
    let key = mergeKey(leaf)
    // Not `... == index && !canRemove[key]`. `&&`'s right operand is an autoclosure, and an
    // autoclosure cannot capture a `borrowing` parameter; the diagnostic says "cannot be captured
    // by an escaping closure", which reads as if a closure had been written here.
    guard Int(offsets[key]) - 1 == index else {
        return false
    }
    return !canRemove[key]
}

/// `if (!offset || (offset - 1) == i)` (`+Simplification.cpp:468`), plus its non-`Numeric` overload
/// (`:475`) -- `simplifyForMinMax`'s own survivor test, asked of a flat child.
@inline(always)
private func calcFlatMinMaxSurvives(
    _ leaf: NumericLeaf?,
    _ index: Int,
    _ offsets: borrowing CalcSimplification.MergeTable
) -> Bool {
    guard let leaf else {
        return true
    }
    let offset = Int(offsets[mergeKey(leaf)])
    // Both operands are plain `Int` locals, so this can be the C++'s own single expression --
    // `calcFlatSumSurvives` had to be split into two `guard`s only because its right operand reads a
    // `borrowing` table through the autoclosure `&&` makes of it.
    return offset == 0 || offset - 1 == index
}

fileprivate extension CalcFlatTree {
    /// `builder` is `Optional` because `cssCalcFlatSimplifyProbeSwift`, whose C++ signature is fixed
    /// by the harness that calls it, has no builder to hand over. One thing is read through it,
    /// `simplifyNonCanonicalDimension`'s `resolveRelativeLength`, and `nil` cannot change an answer
    /// on any tree the production route sends here, because that route always passes the builder.
    mutating func simplify(
        _ original: borrowing WebCore.CSSCalc.Child,
        _ options: CalcSimplification,
        _ builder: WebCore.CSSCalc.CSSCalcSwiftBuilder?
    ) {
        var i = count - 1
        while i >= 0 {
            // Never fold inside an `anchor()`'s `<anchor-side>`: the C++ copies that subtree rather
            // than simplifying it. One bit test, because `flatten` marked the whole subtree.
            if nodes[i].flags & CalcFlatNodeFlags.insideAnchorSide == 0 {
                simplifyNode(i, original, options, builder)
            }
            i -= 1
        }
    }

    /// Replace node `i` with node `j`, keeping `i`'s place in its parent's list.
    ///
    /// Every promotion goes through this. A plain `nodes[i] = nodes[j]` copies `nextSibling` too, so
    /// the promoted node inherits the sibling link of wherever it came from; in a `Sum` whose term
    /// is promoted out of a nested `Sum`, that link points back into the list being walked and the
    /// splice loop builds a cycle. This is the invariant that comes with the linked list's O(1)
    /// splicing.
    ///
    /// `firstChild` and `childCount` are taken from `j`: the node genuinely adopts `j`'s children.
    /// So is `origin`, so the promoted node keeps naming the original `CSSCalc::Child` it came
    /// from.
    private mutating func replace(_ i: Int, with j: Int) {
        let sibling = nodes[i].nextSibling
        nodes[i] = nodes[j]
        nodes[i].nextSibling = sibling
    }

    private mutating func simplifyNode(
        _ i: Int,
        _ original: borrowing WebCore.CSSCalc.Child,
        _ options: CalcSimplification,
        _ builder: WebCore.CSSCalc.CSSCalcSwiftBuilder?
    ) {
        switch nodes[i].alternative {
        case .Negate:
            simplifyNegate(i)

        case .Invert:
            simplifyInvert(i)

        case .Sum:
            simplifySum(i, options, builder)

        case .Product:
            simplifyProduct(i, options)

        case .Min:
            simplifyMinMax(i, options, false)

        case .Max:
            simplifyMinMax(i, options, true)

        case .NonCanonicalDimension:
            simplifyNonCanonicalDimension(i, options, builder)

        case .Number, .Percentage, .CanonicalDimension:
            // The other three leaves, and for each of them that is a port rather than an omission:
            // `simplify(Number&)` (`+Simplification.cpp:487`), `simplify(Percentage&)` (`:493`) and
            // `simplify(CanonicalDimension&)` (`:500`) each `return { }` with no body, which is
            // also why `canSimplify` answers false for exactly those three -- and true for the
            // fourth, which is the case just above.
            return

        default:
            // Every remaining alternative, spelled as `default` rather than as the thirty-one
            // labels it stands for, and that is measured. With the list written out, the
            // thirty-first label costs measurably more on a
            // single-node tree, and more again per node, on trees that execute none of it. Thirty
            // labels are free and thirty-one are not, so it is a lowering threshold rather than a
            // slope.
            simplifyColdNode(i, original, options, builder)
        }
    }

    /// The alternatives a real page's CSS does not hold, behind one call site.
    @inline(never)
    private mutating func simplifyColdNode(
        _ i: Int,
        _ original: borrowing WebCore.CSSCalc.Child,
        _ options: CalcSimplification,
        _ builder: WebCore.CSSCalc.CSSCalcSwiftBuilder?
    ) {
        switch nodes[i].alternative {
        case .Clamp:
            simplifyClamp(i, options)

        case .RoundNearest:
            simplifyRound(i, options, CalcExecutor.roundNearest)

        case .RoundUp:
            simplifyRound(i, options, CalcExecutor.roundUp)

        case .RoundDown:
            simplifyRound(i, options, CalcExecutor.roundDown)

        case .RoundToZero:
            simplifyRound(i, options, CalcExecutor.roundToZero)

        case .Mod:
            simplifyBinaryOperation(i, options, CalcExecutor.mod)

        case .Rem:
            simplifyBinaryOperation(i, options, CalcExecutor.rem)

        case .Abs:
            simplifyAbs(i, options)

        case .Sign:
            simplifySign(i, options)

        case .Pow:
            simplifyPow(i)

        case .Sqrt:
            simplifySqrt(i)

        case .Deg2Rad:
            simplifyDeg2Rad(i)

        case .Sin:
            simplifyNumberToNumber(i, CalcExecutor.sin)

        case .Cos:
            simplifyNumberToNumber(i, CalcExecutor.cos)

        case .Tan:
            simplifyNumberToNumber(i, CalcExecutor.tan)

        case .Asin:
            simplifyArcTrig(i, CalcExecutor.asin)

        case .Acos:
            simplifyArcTrig(i, CalcExecutor.acos)

        case .Atan:
            simplifyArcTrig(i, CalcExecutor.atan)

        case .Atan2:
            simplifyAtan2(i, options)

        case .Hypot:
            simplifyHypot(i, options)

        case .Log:
            simplifyLog(i)

        case .Exp:
            simplifyNumberToNumber(i, CalcExecutor.exp)

        case .Progress:
            simplifyProgress(i, options, CalcExecutor.progress)

        case .ProgressNoClamp:
            simplifyProgress(i, options, CalcExecutor.progressNoClamp)

        case .CalcMix:
            simplifyCalcMix(i, original, options)

        case .Symbol:
            simplifySymbol(i, options, builder)

        case .SiblingCount, .SiblingIndex:
            simplifySiblingFunction(i, original, builder)

        case .Anchor, .AnchorSize:
            simplifyAnchorFunction(i, original, builder)

        case .Random:
            simplifyRandom(i, original, options, builder)

        default:
            // Unreachable: the caller's `default` selects exactly the thirty-one above. Spelled as a
            // return rather than a trap for the reason every other unreachable case in this file is
            // -- an untaught alternative leaves the node alone, which the mask has already made
            // impossible, rather than killing the process.
            return
        }
    }

    /// A leaf stays a leaf. The value, the unit and the alternative change and nothing structural
    /// does, so this is a `setLeaf` and never a `replace`: no promotion, no splice, no link touched,
    /// and none of the `nextSibling` hazards apply. `setLeaf` clearing `type` is right here and is
    /// not the `:1821` rule -- the C++ takes the `:1818` replacement branch for a leaf, and
    /// `ChildConstruction<Leaf>::make` discards a leaf's `Type` (CSSCalcTree.h:1016-:1018).
    private mutating func simplifyNonCanonicalDimension(
        _ i: Int,
        _ options: CalcSimplification,
        _ builder: WebCore.CSSCalc.CSSCalcSwiftBuilder?
    ) {
        let unit = UInt16(nodes[i].unitType)
        let leaf: NumericLeaf
        switch options.canonicalizeStep(nodes[i].value, unit) {
        case .leaf(let step):
            leaf = step
        case .relativeLength:
            guard let builder else {
                return
            }
            leaf = options.resolvedRelativeLength(nodes[i].value, unit, builder)
        }
        guard leaf.kind != .nonCanonicalDimension else {
            return
        }
        setLeaf(i, leaf)
    }

    /// The post-step is real: `:523` calls the entire `copyAndSimplify`, not `makeNumeric` alone, so
    /// a symbol that resolves to a non-canonical unit is then canonicalized by
    /// `simplify(NonCanonicalDimension&)` (`:506`). `canonicalizedDimension` is that step; skipping
    /// it would be a silently wrong computed value.
    @inline(never)
    private mutating func simplifySymbol(
        _ i: Int,
        _ options: CalcSimplification,
        _ builder: WebCore.CSSCalc.CSSCalcSwiftBuilder?
    ) {
        guard let builder else {
            return
        }
        let resolved = builder.resolveSymbol(nodes[i].valueID, UInt16(nodes[i].unitType))
        guard resolved.resolved else {
            return
        }

        switch resolved.alternative {
        case .Number:
            setLeaf(i, NumericLeaf(kind: .number, value: resolved.value, unitType: resolved.unitType, percentHint: 0))
        case .Percentage:
            // `makeNumeric` builds `Percentage { .value = value, .hint = { } }`
            // (CSSCalcTree.cpp:196-:197): the hint is 0, not inherited from anywhere.
            setLeaf(i, NumericLeaf(kind: .percentage, value: resolved.value, unitType: resolved.unitType, percentHint: 0))
        case .CanonicalDimension:
            setLeaf(i, NumericLeaf(kind: .canonicalDimension, value: resolved.value, unitType: resolved.unitType, percentHint: 0))
        case .NonCanonicalDimension:
            setLeaf(i, options.canonicalizedDimension(resolved.value, resolved.unitType, builder))
        default:
            // Unreachable: `makeNumeric` always answers one of the four numeric alternatives.
            declined = true
        }
    }

    /// `resolved == false` is not a refusal: the C++ returns `{ }` and the leaf stays in the tree,
    /// which is `emit`'s deep-copy case. Neither is a `nil` builder, which is the probe's.
    @inline(never)
    private mutating func simplifySiblingFunction(
        _ i: Int,
        _ original: borrowing WebCore.CSSCalc.Child,
        _ builder: WebCore.CSSCalc.CSSCalcSwiftBuilder?
    ) {
        guard let builder else {
            return
        }
        guard let resolved = withCalcOriginalNode(original, nodes[i].origin, { builder.resolveStyleCoupledValue($0) }) else {
            declined = true
            return
        }
        guard resolved.resolved else {
            return
        }
        setLeaf(i, NumericLeaf.number(resolved.value))
    }

    /// Three dispositions, and the third is why `CSSCalcSwiftNumericResult` carries
    /// `substituteFallback` at all:
    @inline(never)
    private mutating func simplifyAnchorFunction(
        _ i: Int,
        _ original: borrowing WebCore.CSSCalc.Child,
        _ builder: WebCore.CSSCalc.CSSCalcSwiftBuilder?
    ) {
        guard let builder else {
            return
        }

        // Where the fallback sits among the children: `anchorChildren` (CSSCalcTree.cpp:95-:111) fills
        // the `<anchor-side>` subtree first, when it is a `<percentage>` rather than a keyword, then
        // the fallback -- and it is the same function `childCount` and `operator[]` answer from, so
        // deriving presence from the count here cannot disagree with the boundary. Cross-checking
        // against `operationInfo().hasFallback` instead would be a second crossing for an answer the
        // count already gives.
        let sideSlots: UInt32 = nodes[i].flags & CalcFlatNodeFlags.anchorSideIsSubtree != 0 ? 1 : 0
        let childCount = nodes[i].childCount
        guard childCount == sideSlots || childCount == sideSlots &+ 1 else {
            declined = true
            return
        }

        guard let resolved = withCalcOriginalNode(original, nodes[i].origin, { builder.resolveStyleCoupledValue($0) }) else {
            declined = true
            return
        }

        if resolved.resolved {
            // `simplify` always ends at a `CanonicalDimension` here, so the check is on the
            // alternative and not the unit: a boundary that came apart refuses the tree rather than
            // building the wrong leaf.
            guard resolved.alternative == .CanonicalDimension else {
                declined = true
                return
            }
            setLeaf(i, NumericLeaf(kind: .canonicalDimension, value: resolved.value, unitType: resolved.unitType, percentHint: 0))
            return
        }

        if resolved.substituteFallback, childCount == sideSlots &+ 1, let fallback = child(i, Int(sideSlots)) {
            // The node becomes the fallback child itself, `replace` rather than a leaf write, so a
            // `Numeric` fallback reaches the parent as a numeric and a subtree reaches it as a
            // subtree: `calc(anchor(top, 1px) + 1em)` has to become `17px`, not `calc(1px + 16px)`.
            replace(i, with: fallback)
            return
        }

    }

    /// The `<random-key>` is not a child; only `min`, `max` and the optional `step` are, so
    /// `childCount` is 2 or 3 whether or not a key is present. All present operands must be the same
    /// numeric alternative and unit, checked against `max` and `step` separately and both anchored
    /// on `min`, as the C++ does; only `min` is checked for `fullyResolved`, so a non-canonical
    /// dimension never folds here. The result is shaped like `min`, so a `random()` over percentages
    /// keeps `min`'s percent hint.
    @inline(never)
    private mutating func simplifyRandom(
        _ i: Int,
        _ original: borrowing WebCore.CSSCalc.Child,
        _ options: CalcSimplification,
        _ builder: WebCore.CSSCalc.CSSCalcSwiftBuilder?
    ) {
        guard let builder else {
            return
        }
        let childCount = nodes[i].childCount
        guard let minimumChild = child(i, 0), let maximumChild = child(i, 1),
            let minimum = nodes[minimumChild].numericLeaf,
            let maximum = nodes[maximumChild].numericLeaf else {
            // Either bound not a numeric leaf is the C++'s `[](const auto&)` overload, and a missing one
            // cannot happen for a parser-built node -- `isSimplifiableAlternative` already bounds the
            // arity to 2 or 3. Both leave the node alone.
            return
        }
        guard options.switchTogether(minimum, maximum), options.unitsMatch(minimum, maximum),
            options.fullyResolved(minimum) else {
            return
        }

        var step: Double? = nil
        if childCount > 2 {
            guard let stepChild = child(i, 2), let stepLeaf = nodes[stepChild].numericLeaf else {
                return
            }
            guard options.switchTogether(minimum, stepLeaf), options.unitsMatch(minimum, stepLeaf) else {
                return
            }
            step = stepLeaf.value
        }

        guard let baseValue = withCalcOriginalNode(original, nodes[i].origin, { builder.resolveStyleCoupledValue($0) }) else {
            declined = true
            return
        }
        guard baseValue.resolved else {
            return
        }

        setLeaf(i, minimum.withValue(CalcExecutor.random(baseValue.value, minimum.value, maximum.value, step)))
    }

    /// `simplify(Negate&)` (`+Simplification.cpp:911`-`:961`), all four cases.
    private mutating func simplifyNegate(_ i: Int) {
        guard nodes[i].childCount == 1, let a = child(i, 0) else {
            return
        }

        if nodes[a].isNumericLeaf {
            // 6.1 (`:916`-`:921`). The unary minus, not `0 - v` and not `* -1`: it flips the sign
            // bit of a zero, so `-(+0)` is `-0`, which is the C++'s own stated reason for the
            // spelling at `:918`.
            let negated = -nodes[a].value
            replace(i, with: a)
            nodes[i].value = negated
            return
        }

        if nodes[a].alternative == .Negate, nodes[a].childCount == 1, let inner = child(a, 0) {
            replace(i, with: inner)
            return
        }

        if nodes[a].alternative == .Sum || nodes[a].alternative == .Product {
            // `:927`-`:956`, "Not stated in spec, but needed for tests": an all-numeric `Sum` or
            // `Product` child has every child's value negated in place and is then returned in the
            // `Negate`'s place, keeping its own cached `Type`, which `replace` carries over with it.
            //
            // For a `Product` the C++ negates every factor, which multiplies the product by
            // `(-1)^n` rather than by `-1`, so a two-factor product comes back with its original
            // sign. Reproduced deliberately, because the differential compares against this C++.
            // Negating a single factor here diverges the two paths; both must change together.
            guard allChildrenAreNumericLeaves(a) else {
                return
            }
            var cursor = nodes[a].firstChild
            while cursor != CalcFlatNode.noNode {
                nodes[Int(cursor)].value = -nodes[Int(cursor)].value
                cursor = nodes[Int(cursor)].nextSibling
            }
            replace(i, with: a)
        }
    }

    /// `simplify(Invert&)` (`+Simplification.cpp:963`-`:980`), both cases and no third one.
    private mutating func simplifyInvert(_ i: Int) {
        guard nodes[i].childCount == 1, let a = child(i, 0) else {
            return
        }

        if nodes[a].alternative == .Number {
            let inverted = CalcExecutor.invert(nodes[a].value)
            replace(i, with: a)
            nodes[i].value = inverted
            return
        }

        if nodes[a].alternative == .Invert, nodes[a].childCount == 1, let inner = child(a, 0) {
            replace(i, with: inner)
        }
    }

    /// `std::ranges::all_of(children, isNumeric)` (`+Simplification.cpp:769`, `:930`, `:945`) over a
    /// flat node's final child list. True for an empty list, as `all_of` is.
    private func allChildrenAreNumericLeaves(_ i: Int) -> Bool {
        var cursor = nodes[i].firstChild
        while cursor != CalcFlatNode.noNode {
            guard nodes[Int(cursor)].isNumericLeaf else {
                return false
            }
            cursor = nodes[Int(cursor)].nextSibling
        }
        return true
    }

    /// Overwrite node `i` with a numeric leaf, keeping its place in its parent's list.
    ///
    /// The counterpart of `replace` for the three C++ sites that return a leaf the input tree does
    /// not contain: `makeChild(CanonicalDimension { 0, Length })` at `:664`,
    /// `makeChild(*numericProduct)` at `:755`, and step 9.4's eleven-case category table at
    /// `:882`-`:902`. Those sites are reached here through `NumericLeaf.number`,
    /// `NumericLeaf.canonicalLength` and `numericLeafForCategory`, so no unit or percent-hint table
    /// is written a second time.
    ///
    /// `nextSibling` and `flags` are the two fields not written: the first because overwriting it is
    /// the cycle bug `replace` documents, the second because `insideAnchorSide` describes where the
    /// slot is rather than what is in it.
    ///
    /// False means `leaf.unitType` did not fit the node's `uint8_t`, which cannot happen: every unit
    /// here comes from a `CSSUnitType`, whose raw type is `uint8_t`, and `CSSUnitType.h` allocates 7
    /// bits for it. Answered rather than trapped, and answered before anything is written, so a
    /// boundary that ever broke that leaves the node untouched instead of half-built.
    @discardableResult
    private mutating func setLeaf(_ i: Int, _ leaf: NumericLeaf) -> Bool {
        guard let unit = UInt8(exactly: leaf.unitType) else {
            return false
        }
        let alternative: CalcAlternative
        switch leaf.kind {
        case .number: alternative = .Number
        case .percentage: alternative = .Percentage
        case .canonicalDimension: alternative = .CanonicalDimension
        case .nonCanonicalDimension: alternative = .NonCanonicalDimension
        }
        nodes[i].value = leaf.value
        nodes[i].type = CalcType()
        nodes[i].firstChild = CalcFlatNode.noNode
        nodes[i].childCount = 0
        nodes[i].valueID = 0
        nodes[i].unitType = unit
        nodes[i].alternative = alternative
        nodes[i].percentHint = leaf.percentHint
        return true
    }

    /// Splice every child of node `i` that is itself a `kind` node into `i`'s own child list, one
    /// level, in order, and leave `childCount` correct.
    ///
    /// Step 8.1 for `Sum` (`+Simplification.cpp:554`-`:564`) and the outer half of step 9.1 for
    /// `Product` (`:744`-`:750`) are the same list surgery, so they are the same function.
    ///
    /// One level is the whole subtlety. The C++ iterates `root.children` exactly once and appends a
    /// grandchild without looking at it, and it does not need to look: the reverse loop simplified
    /// that inner `Sum` before this one, so the inner sum's own nested sums were already spliced
    /// into it. `cursor` therefore continues from the node after the spliced child, never from the
    /// head -- continuing from the head splices a `Sum` nested two deep twice.
    ///
    /// The C++ guards `Sum`'s splice with `any_of(children, holdsAlternative<IndirectNode<Sum>>)`
    /// (`:555`) and does not guard `Product`'s. That asymmetry is not reproduced because it is not
    /// observable: the guard exists to avoid allocating a `Vector<Child> newChildren` when nothing
    /// would change, and relinking a list in place is already a no-op when nothing is nested.
    private mutating func spliceNestedChildren(_ i: Int, _ kind: CalcAlternative) {
        var previous = CalcFlatNode.noNode
        var cursor = nodes[i].firstChild
        var terms: UInt32 = 0
        while cursor != CalcFlatNode.noNode {
            let c = Int(cursor)
            guard nodes[c].alternative == kind else {
                previous = cursor
                cursor = nodes[c].nextSibling
                // `&+=` at all three `terms` sites: `terms` is the length of the rebuilt sibling
                // list, every element of which is a distinct slot of `nodes`, so it is bounded by
                // `nodes.count`.
                terms &+= 1
                continue
            }

            let after = nodes[c].nextSibling
            let head = nodes[c].firstChild
            if head == CalcFlatNode.noNode {
                // `appendVector` of an empty vector: the nested node contributes no terms and
                // disappears. Unreachable -- both `simplify` overloads open with
                // `ASSERT(!root.children.isEmpty())` -- but it is one branch, and the alternative if
                // it ever happened is a list linked through a node that is no longer in it.
                if previous == CalcFlatNode.noNode {
                    nodes[i].firstChild = after
                } else {
                    nodes[Int(previous)].nextSibling = after
                }
                cursor = after
                continue
            }

            var tail = head
            terms &+= 1
            while nodes[Int(tail)].nextSibling != CalcFlatNode.noNode {
                tail = nodes[Int(tail)].nextSibling
                terms &+= 1
            }
            // Relink the nested node's whole list in place of the node itself. The nested node is
            // discarded and nothing else can reference its children, so redirecting the tail's
            // `nextSibling` to this node's continuation is safe.
            nodes[Int(tail)].nextSibling = after
            if previous == CalcFlatNode.noNode {
                nodes[i].firstChild = head
            } else {
                nodes[Int(previous)].nextSibling = head
            }
            previous = tail
            cursor = after
        }
        nodes[i].childCount = terms
    }

    /// `simplify(Sum&)` (`+Simplification.cpp:548`-`:715`), css-values-4 steps 8.1 to 8.4, in the
    /// C++'s execution order.
    ///
    /// The merge table is the C++'s own `std::array<FirstInstance, numberOfNumericIdentityTypes>`
    /// (`:606`): two `InlineArray`s in the frame, keyed by `mergeKey` -- 128 entries because the key
    /// is the 7-bit `CSSUnitType`, which `mergeKey` explains is injective on `NumericIdentity` and
    /// so gives the same fixed-size table without transcribing a 56-case enum into this file. Fixed
    /// size, stack, no allocation.
    ///
    /// `FirstInstance::merges` is not kept per bucket. The C++ keeps it only to sum it at `:647`,
    /// and two running totals -- `merges`, and how many buckets are currently marked removable --
    /// give both of its tallies for free. That substitution depends on one thing: `canRemove` is
    /// assigned on every merge (`:625`), not accumulated, so it can go back to false and the count
    /// has to move both ways.
    private mutating func simplifySum(
        _ i: Int,
        _ options: CalcSimplification,
        _ builder: WebCore.CSSCalc.CSSCalcSwiftBuilder?
    ) {
        guard nodes[i].childCount > 0 else {
            return
        }

        spliceNestedChildren(i, .Sum)

        if nodes[i].childCount == 1, let only = child(i, 0) {
            replace(i, with: only)
            return
        }

        var offsets = CalcSimplification.MergeTable(repeating: 0)
        var canRemove = CalcSimplification.MergeFlags(repeating: false)
        var merges = 0
        var removableBuckets = 0

        var cursor = nodes[i].firstChild
        while cursor != CalcFlatNode.noNode {
            let c = Int(cursor)
            cursor = nodes[c].nextSibling

            // `[](const auto&) { }` (`:636`-`:638`): "Non-numeric values are not eligible for merge or
            // removal."
            guard let leaf = nodes[c].numericLeaf else {
                continue
            }
            let key = mergeKey(leaf)

            if offsets[key] != 0 {
                let first = Int(offsets[key]) - 1
                let merged = CalcExecutor.sum(nodes[first].value, nodes[c].value)
                nodes[first].value = merged
                merges &+= 1

                // `firstInstance.canRemove = canRemoveIfZero && !mergedValue;` (`:625`) -- an
                // assignment, so a bucket made removable by an earlier merge is cleared when a
                // later one lands non-zero. `!mergedValue` is true for both `+0` and `-0`, which
                // `== 0` is and a sign test would not be. Written in this order so the unit
                // classification is skipped for every non-zero merge.
                let removable = merged == 0 && options.lengthRemovalAllowed(leaf)
                if removable != canRemove[key] {
                    // `&+=`: guarded on `removable != canRemove[key]` and paired with the assignment
                    // below, so this counter is exactly "how many of the 128 buckets have
                    // `canRemove` set" and never leaves `0 ... 128`.
                    removableBuckets &+= removable ? 1 : -1
                    canRemove[key] = removable
                }
                continue
            }

            // `firstInstances[id] = { .offset = i + 1, .merges = 0, .canRemove = canRemoveIfZero &&
            // !child.value };` (`:630`-`:634`). `c + 1` is a node index, not a term position: see
            // `calcFlatSumSurvives`.
            offsets[key] = UInt32(truncatingIfNeeded: c &+ 1)
            let removable = nodes[c].value == 0 && options.lengthRemovalAllowed(leaf)
            if removable != canRemove[key] {
                removableBuckets &+= removable ? 1 : -1
                canRemove[key] = removable
            }
        }

        let size = Int(nodes[i].childCount)
        let removeTotal = merges &+ removableBuckets

        if removeTotal == 0 {
            return
        }

        // `if ((root.children.size() - childrenToRemoveFromMerges) == 1) return { WTF::move(
        // root.children[0]) };` (`:657`). Before zero-removal and without consulting `canRemove`, so
        // an all-merging sum of removable zero lengths returns that zero rather than the fabricated
        // one at `:664`. Child 0 is always the sole merge-survivor -- it has no earlier term to
        // merge into -- which is why the C++ names it unconditionally and this needs no search, and
        // its value is the accumulated one, written back above.
        if size &- merges == 1, let only = child(i, 0) {
            replace(i, with: only)
            return
        }

        let combined = size &- removeTotal

        // 8.4's over-removal guard (`:660`-`:664`): "If the new size is 0, we removed too much. Return
        // a single 0 value of type `length` ... because the only kind of node that can be removed is
        // of type `length`."
        if combined == 0 {
            setLeaf(i, NumericLeaf.canonicalLength(0))
            return
        }

        if combined == 1 {
            var scan = nodes[i].firstChild
            while scan != CalcFlatNode.noNode {
                let s = Int(scan)
                if calcFlatSumSurvives(nodes[s].numericLeaf, s, offsets, canRemove) {
                    replace(i, with: s)
                    return
                }
                scan = nodes[s].nextSibling
            }
            // Cannot happen given the arithmetic above. Falling through to the rebuild below leaves a
            // one-child `Sum`, which is a valid tree, rather than the C++'s empty one.
        }

        // `:690`-`:712`: keep the non-numerics and the first instances that are not removable, in
        // order. The node keeps its kind and its original cached `Type` -- `copyAndSimplify` takes
        // `getType(root)` at `:1821` for a node whose `simplify` returned `nullopt`, and `:712` is
        // that path.
        var previous = CalcFlatNode.noNode
        // `kept` counts survivors of one sibling list, each a distinct slot of `nodes`, so it is
        // bounded by `nodes.count` and its `&+=` below cannot wrap.
        var kept: UInt32 = 0
        cursor = nodes[i].firstChild
        while cursor != CalcFlatNode.noNode {
            let c = Int(cursor)
            let next = nodes[c].nextSibling
            if calcFlatSumSurvives(nodes[c].numericLeaf, c, offsets, canRemove) {
                if previous == CalcFlatNode.noNode {
                    nodes[i].firstChild = cursor
                } else {
                    nodes[Int(previous)].nextSibling = cursor
                }
                previous = cursor
                kept &+= 1
            }
            cursor = next
        }
        if previous == CalcFlatNode.noNode {
            nodes[i].firstChild = CalcFlatNode.noNode
        } else {
            nodes[Int(previous)].nextSibling = CalcFlatNode.noNode
        }
        nodes[i].childCount = kept
    }

    /// `simplifyForMinMax` (`+Simplification.cpp:372`-`:483`), css-values-4 steps 5.1 to 5.3,
    /// reached from `simplify(Min&)` (`:999`) and `simplify(Max&)` (`:1004`).
    private mutating func simplifyMinMax(_ i: Int, _ options: CalcSimplification, _ isMax: Bool) {
        // `ASSERT(!root.children.isEmpty())` (`:374`). Unreachable through the parser and refused by
        // `isSimplifiableAlternative` if it ever were, so this only keeps the code below total.
        guard nodes[i].childCount > 0 else {
            return
        }

        // `if (root.children.size() == 1) return { WTF::move(root.children[0]) };` (`:409`-`:410`),
        // before the merge pass -- which is why a one-child `min()` promotes its child whatever the
        // child is, including a percentage the merge would have refused and an operator node.
        if nodes[i].childCount == 1, let only = child(i, 0) {
            replace(i, with: only)
            return
        }

        var offsets = CalcSimplification.MergeTable(repeating: 0)
        let canMergePercentages = !options.percentageResolveToDimension
        var merges = 0

        var cursor = nodes[i].firstChild
        while cursor != CalcFlatNode.noNode {
            let c = Int(cursor)
            cursor = nodes[c].nextSibling

            // `[](const auto&) { return 0; }` (`:443`-`:444`): a non-`Numeric` child is no merge
            // opportunity, is never merged, and always survives.
            guard let leaf = nodes[c].numericLeaf else {
                continue
            }

            if leaf.kind == .percentage, !canMergePercentages {
                continue
            }

            let key = mergeKey(leaf)
            if offsets[key] != 0 {
                // `root.children[offset - 1] = evaluate(root.children[offset - 1],`
                // `root.children[i]);` (`:431`). `evaluate` is
                // `executeMathOperation<Op>(aNumeric.value, get<T>(b).value)` (`:399`) with a = the
                // accumulated first instance and b = the later child, and the two-argument
                // `Min`/`Max` executors are NaN-order-sensitive, so the argument order here is the
                // C++'s position for position.
                let first = Int(offsets[key]) - 1
                nodes[first].value = isMax
                    ? CalcExecutor.max(nodes[first].value, nodes[c].value)
                    : CalcExecutor.min(nodes[first].value, nodes[c].value)
                merges &+= 1
                continue
            }

            // `offsetOfFirstInstance[static_cast<uint8_t>(id)] = i + 1;` (`:438`). `c + 1` is a node
            // index, not a term position: see `calcFlatSumSurvives`.
            offsets[key] = UInt32(truncatingIfNeeded: c &+ 1)
        }

        if merges == 0 {
            return
        }

        let size = Int(nodes[i].childCount)
        if size &- merges == 1, let only = child(i, 0) {
            replace(i, with: only)
            return
        }

        // `:459`-`:480`: keep every non-numeric child and the first instance of each merged unit,
        // in order. The node keeps its kind and its original cached `Type` -- the C++ returns `{ }`
        // at `:482` even here, so `copyAndSimplify` takes the `getType(root)` branch at `:1821`.
        var previous = CalcFlatNode.noNode
        // `kept` counts survivors of one sibling list, each a distinct slot of `nodes`, so it is
        // bounded by `nodes.count` and its `&+=` below cannot wrap.
        var kept: UInt32 = 0
        cursor = nodes[i].firstChild
        while cursor != CalcFlatNode.noNode {
            let c = Int(cursor)
            let next = nodes[c].nextSibling
            if calcFlatMinMaxSurvives(nodes[c].numericLeaf, c, offsets) {
                if previous == CalcFlatNode.noNode {
                    nodes[i].firstChild = cursor
                } else {
                    nodes[Int(previous)].nextSibling = cursor
                }
                previous = cursor
                kept &+= 1
            }
            cursor = next
        }
        // At least child 0 survives, so `previous` is never the sentinel here; the branch is kept for
        // the same reason `simplify(Sum&)`'s is, so a list this loop somehow emptied is a valid empty
        // list rather than one linked through a dropped child.
        if previous == CalcFlatNode.noNode {
            nodes[i].firstChild = CalcFlatNode.noNode
        } else {
            nodes[Int(previous)].nextSibling = CalcFlatNode.noNode
        }
        nodes[i].childCount = kept
    }

    /// `simplify(Clamp&)` (`+Simplification.cpp:1009`-`:1106`), all five outcomes.
    ///
    /// WHICH BOUNDS ARE THE KEYWORD `none` IS NOT DERIVABLE FROM THE CHILD COUNT.
    /// `clamp(none, VAL, MAX)` and `clamp(MIN, VAL, none)` both report two children, because
    /// `Child::operator[]` skips a `ChildOrNone` holding the keyword entirely; the flat node carries
    /// the answer in `clampNoneMinimum`/`clampNoneMaximum`, captured at flatten from the boundary's
    /// two dedicated `CSSCalcSwiftNodeKind`s. Both keywords at once is the plain `Clamp` kind and one
    /// child, which is what the cross-check below tests.
    ///
    /// THE TWO COLLAPSE BRANCHES USE DIFFERENT ARGUMENT POSITIONS -- `Min(val, max)` at `:1064` and
    /// `Max(min, val)` at `:1080` -- and the two-argument executors short-circuit on whichever
    /// operand is NaN first, so the positions are transcribed rather than normalised. The result is
    /// shaped like `val` in both, since both call `makeChildWithValueBasedOn(..., val)`.
    ///
    /// `magnitudeComparable`, NOT `fullyResolved`: `clamp(none, 1em, 2em)` folds where
    /// `mod(5em, 3em)` does not, because a `NonCanonicalDimension` is comparable by magnitude
    /// (`:149`) and not fully resolved (`:171`). The asymmetry is real and is reproduced.
    ///
    /// THE NODE PRODUCED BY THE `min()`/`max()` REWRITE IS NEVER RE-SIMPLIFIED. `copyAndSimplify`
    /// (`:1810`-`:1823`) calls `simplify` exactly once and takes the replacement as-is, so the
    /// rewritten `Min` does not go through `simplifyForMinMax`. The reverse scan gives that for free:
    /// node `i` has already been visited when this runs, and nothing revisits it.
    @inline(never)
    private mutating func simplifyClamp(_ i: Int, _ options: CalcSimplification) {
        let childCount = nodes[i].childCount
        let minimumIsNone = nodes[i].flags & CalcFlatNodeFlags.clampNoneMinimum != 0
        let maximumIsNone = nodes[i].flags & CalcFlatNodeFlags.clampNoneMaximum != 0

        // The cross-check: exactly one absent bound means two children and vice versa. A mismatch
        // declines rather than reading a bound out of the wrong slot -- and it must decline rather
        // than leave the node alone, since `rebuildFrom` would then take the keywords off the
        // original and produce a node this pass never reasoned about.
        guard (childCount == 2) == (minimumIsNone || maximumIsNone) else {
            declined = true
            return
        }

        if childCount == 1 {
            guard let value = child(i, 0) else {
                declined = true
                return
            }
            replace(i, with: value)
            return
        }

        if childCount == 3 {
            guard let minimumChild = child(i, 0), let valueChild = child(i, 1),
                let maximumChild = child(i, 2) else {
                declined = true
                return
            }
            // `[](const auto&)` (`:1099`-`:1101`): `val` not `Numeric` leaves the node alone, and it
            // dominates every other test.
            guard let value = nodes[valueChild].numericLeaf else {
                return
            }
            guard let minimum = nodes[minimumChild].numericLeaf,
                let maximum = nodes[maximumChild].numericLeaf,
                options.switchTogether(value, minimum), options.switchTogether(value, maximum) else {
                return
            }
            guard options.unitsMatch(minimum, value), options.unitsMatch(value, maximum) else {
                return
            }
            guard options.magnitudeComparable(value) else {
                return
            }
            setLeaf(i, value.withValue(CalcExecutor.clamp(minimum.value, value.value, maximum.value)))
            return
        }

        if minimumIsNone {
            guard let valueChild = child(i, 0), let maximumChild = child(i, 1) else {
                declined = true
                return
            }
            guard let value = nodes[valueChild].numericLeaf else {
                // Outcome 2 again, and it dominates the conversion: the `[&]<Numeric T>` visitor
                // never runs for a non-`Numeric` `val`, so `convertToMin` is not reached.
                return
            }
            guard let maximum = nodes[maximumChild].numericLeaf, options.switchTogether(value, maximum),
                options.unitsMatch(value, maximum), options.magnitudeComparable(value) else {
                // All three of the C++'s `convertToMin()` sites (`:1050`, `:1055`, `:1060`), plus
                // `max` not being a `Numeric` at all, which is the first of them.
                convertToMinMax(i, nodes[valueChild], nodes[maximumChild], isMax: false, options)
                return
            }
            setLeaf(i, value.withValue(CalcExecutor.min(value.value, maximum.value)))
            return
        }

        guard let minimumChild = child(i, 0), let valueChild = child(i, 1) else {
            declined = true
            return
        }
        guard let value = nodes[valueChild].numericLeaf else {
            return
        }
        guard let minimum = nodes[minimumChild].numericLeaf, options.switchTogether(minimum, value),
            options.unitsMatch(minimum, value), options.magnitudeComparable(value) else {
            convertToMinMax(i, nodes[minimumChild], nodes[valueChild], isMax: true, options)
            return
        }
        setLeaf(i, value.withValue(CalcExecutor.max(minimum.value, value.value)))
    }

    /// `convertToMin` / `convertToMax` (`+Simplification.cpp:1019`-`:1045`): a `clamp()` with one
    /// keyword bound that could not be folded becomes the equivalent two-argument `min()`/`max()`.
    ///
    /// No list surgery at all: the C++ builds a fresh two-element `Vector<Child>` in `val, max`
    /// order for `convertToMin` and `min, val` order for `convertToMax`, and the flat child list is
    /// already in exactly those orders -- child 0 is whichever of the three slots the keyword did
    /// not occupy first. So both conversions take the list as it stands, and `first`/`second` here
    /// are always child 0 and child 1.
    ///
    /// The new type is computed here rather than at emit, and that is what closes the one coverage
    /// hole this fold had. `toType(Min)` and `toType(Max)` are `Type::add` over the two children:
    /// `Min::input` and `Max::input` are `AllowedTypes::Any`, so `getValidatedTypeFor` never
    /// refuses; `merge` is `MergePolicy::Consistent`, which is `Type::consistentType`; and `output`
    /// is `OutputTransform::None`, so `transformType` is the identity (`CSSCalcTree.cpp:509`-`:523`,
    /// `CSSCalcType.h:378`-`:435`). `consistentType` is called, not transcribed. Asking before the
    /// conversion is what leaves nothing to unwind: recomputing the type at emit would find the
    /// operands already consumed into a node that cannot be built.
    ///
    /// A failing merge leaves the node a `Clamp`, which is exactly what the C++ does with it:
    /// `convertToMin` returns `std::nullopt` (`:1021`), `simplify(Clamp&)` propagates it, and
    /// `copyAndSimplify` (`:1818`-`:1821`) rebuilds the `Clamp` with `getType(root)`. Emit's
    /// `default` case rebuilds it from the same two operands through `rebuildFrom`, which takes
    /// `getType(alternative)` off the same original.
    ///
    /// FIXME: `convertToMin` in the C++ moves `root.val` and `root.max` into its new `Vector`
    /// before testing `toType`, and returns `std::nullopt` on failure, at which point
    /// `copyAndSimplify` rebuilds a `Clamp` from children that have been moved from -- an
    /// `IndirectNode` holding a null `UniqueRef`. `root.val` is always a numeric leaf on that path,
    /// but `root.max` can be an arbitrary subtree. Nothing is moved here, so this port does not
    /// reproduce it.
    private mutating func convertToMinMax(_ i: Int, _ first: CalcFlatNode, _ second: CalcFlatNode, isMax: Bool, _ options: CalcSimplification) {
        guard let firstType = emittedType(first, options),
            let secondType = emittedType(second, options),
            let merged = CalcType.consistentType(firstType, secondType).value else {
            // The types do not merge, so the node stays a `Clamp` and `emit`'s `default` case
            // rebuilds it from these same two operands. Not a refusal: the C++ does not build the
            // `min()` either.
            return
        }
        nodes[i].alternative = isMax ? .Max : .Min
        nodes[i].type = merged
    }

    /// `simplifyForRound<Op>` (`+Simplification.cpp:328`-`:337`), shared by
    /// `round(nearest|up|down|to-zero, ...)`; `simplify(RoundNearest&)` and its three siblings
    /// (`:1108`-`:1126`) are one line each onto it.
    @inline(never)
    private mutating func simplifyRound(_ i: Int, _ options: CalcSimplification, _ operation: (Double, Double) -> Double) {
        guard let valueChild = child(i, 0) else {
            declined = true
            return
        }

        if nodes[i].childCount == 2 {
            guard let intervalChild = child(i, 1) else {
                declined = true
                return
            }
            simplifyForOperation(i, valueChild, intervalChild, options, operation)
            return
        }

        guard nodes[valueChild].alternative == .Number else {
            return
        }
        setLeaf(i, NumericLeaf.number(operation(nodes[valueChild].value, 1.0)))
    }

    /// `simplifyForOperation<Op>` (`+Simplification.cpp:299`-`:312`): both operands the same
    /// numeric alternative (`switchTogether`, `:70`), units matching, the first fully resolved, and
    /// the result carried onto a leaf shaped like the first --
    /// `makeChildWithValueBasedOn(op(a, b), a)`.
    private mutating func simplifyForOperation(
        _ i: Int,
        _ aChild: Int,
        _ bChild: Int,
        _ options: CalcSimplification,
        _ operation: (Double, Double) -> Double
    ) {
        guard let a = nodes[aChild].numericLeaf, let b = nodes[bChild].numericLeaf else {
            // The catch-all visitor (`:308`-`:310`): either operand not a `Numeric` leaves the node.
            return
        }
        guard options.switchTogether(a, b), options.unitsMatch(a, b), options.fullyResolved(a) else {
            return
        }
        setLeaf(i, a.withValue(operation(a.value, b.value)))
    }

    /// `simplify(Mod&)` and `simplify(Rem&)` (`+Simplification.cpp:1128`-`:1136`), which are one
    /// line each onto `simplifyForOperation<Mod|Rem>(root.a, root.b, options)`.
    @inline(never)
    private mutating func simplifyBinaryOperation(
        _ i: Int,
        _ options: CalcSimplification,
        _ operation: (Double, Double) -> Double
    ) {
        guard let aChild = child(i, 0), let bChild = child(i, 1) else {
            // `isSimplifiableAlternative` has already bounded the arity to 2, so this is a flat
            // tree disagreeing with itself. Refused rather than left alone, as `simplifyRound`
            // does for the same contradiction: a structure that contradicts itself cannot be
            // relied on to produce a tree.
            declined = true
            return
        }
        simplifyForOperation(i, aChild, bChild, options, operation)
    }

    /// `simplify(Abs&)` (`+Simplification.cpp:1323`-`:1335`): any numeric alternative, guarded by
    /// `magnitudeComparable` alone, with the result carried onto a leaf shaped like the operand --
    /// `makeChildWithValueBasedOn(executeMathOperation<Abs>(a.value), a)`.
    @inline(never)
    private mutating func simplifyAbs(_ i: Int, _ options: CalcSimplification) {
        guard let aChild = child(i, 0), let a = nodes[aChild].numericLeaf,
            options.magnitudeComparable(a) else {
            return
        }
        setLeaf(i, a.withValue(CalcExecutor.abs(a.value)))
    }

    /// `simplify(Sign&)` (`+Simplification.cpp:1337`-`:1349`): `abs()`'s guard, and a `Number`
    /// result whatever the operand's alternative was -- `sign()` is a ratio, not a quantity.
    @inline(never)
    private mutating func simplifySign(_ i: Int, _ options: CalcSimplification) {
        guard let aChild = child(i, 0), let a = nodes[aChild].numericLeaf,
            options.magnitudeComparable(a) else {
            return
        }
        setLeaf(i, NumericLeaf.number(CalcExecutor.sign(a.value)))
    }

    /// `simplify(Pow&)` (`+Simplification.cpp:1175`-`:1188`): both operands must be `Number`, and
    /// that is the whole predicate -- no `unitsMatch`, no `fullyResolved`, because the parser has
    /// already type-checked `pow()`'s two arguments to `<number>`. `switchTogether` is given only a
    /// `(const Number&, const Number&)` overload, so anything else falls to the catch-all.
    @inline(never)
    private mutating func simplifyPow(_ i: Int) {
        guard let aChild = child(i, 0), let bChild = child(i, 1),
            nodes[aChild].alternative == .Number, nodes[bChild].alternative == .Number else {
            return
        }
        setLeaf(i, NumericLeaf.number(CalcExecutor.pow(nodes[aChild].value, nodes[bChild].value)))
    }

    /// `simplify(Sqrt&)` (`+Simplification.cpp:1190`-`:1203`): a `Number` in, a `Number` out.
    @inline(never)
    private mutating func simplifySqrt(_ i: Int) {
        guard let aChild = child(i, 0), nodes[aChild].alternative == .Number else {
            return
        }
        setLeaf(i, NumericLeaf.number(CalcExecutor.sqrt(nodes[aChild].value)))
    }

    /// `simplify(Deg2Rad&)` (`+Simplification.cpp:982`-`:997`): the parse-time wrapper that turns an
    /// `<angle>` argument to `sin()`/`cos()`/`tan()` into the `<number>` of radians those three fold
    /// over. It has no syntax of its own, so it is only ever reached inside a trig function.
    @inline(never)
    private mutating func simplifyDeg2Rad(_ i: Int) {
        guard let angleChild = child(i, 0), let angle = nodes[angleChild].numericLeaf,
            angle.kind == .canonicalDimension,
            angle.unitType == UInt16(WebCore.CSSUnitType.Deg.rawValue) else {
            return
        }
        setLeaf(i, NumericLeaf.number(CalcExecutor.degreesToRadians(angle.value)))
    }

    /// `simplifyForTrig<Op>` (`+Simplification.cpp:340`-`:355`), which `simplify(Sin&)`, `(Cos&)`
    /// and `(Tan&)` (`:1138`-`:1151`) are one line each onto -- and, character for character, the
    /// bodies of `simplify(Exp&)` (`:1308`-`:1321`) and `simplify(Log&)`'s one-argument shape
    /// (`:1300`-`:1305`) as well, which is why those two route here rather than to a copy of it.
    @inline(never)
    private mutating func simplifyNumberToNumber(_ i: Int, _ operation: (Double) -> Double) {
        guard let aChild = child(i, 0), nodes[aChild].alternative == .Number else {
            return
        }
        setLeaf(i, NumericLeaf.number(operation(nodes[aChild].value)))
    }

    /// `simplifyForArcTrig<Op>` (`+Simplification.cpp:357`-`:370`), for `simplify(Asin&)`, `(Acos&)`
    /// and `(Atan&)` (`:1153`-`:1166`): the same single-case `Number` predicate, and a canonical
    /// `<angle>` out rather than a `<number>` -- `CalcExecutor.asin`/`.acos`/`.atan` all end in
    /// `radiansToDegrees`, so the value is already in the `Deg` `NumericLeaf.canonicalAngle` names.
    @inline(never)
    private mutating func simplifyArcTrig(_ i: Int, _ operation: (Double) -> Double) {
        guard let aChild = child(i, 0), nodes[aChild].alternative == .Number else {
            return
        }
        setLeaf(i, NumericLeaf.canonicalAngle(operation(nodes[aChild].value)))
    }

    /// `simplify(Atan2&)` (`+Simplification.cpp:1168`-`:1173`), which is
    /// `simplifyForOperationWithCompletion<Atan2>` (`:314`-`:326`): `simplifyForOperation`'s three
    /// predicates, with the caller choosing the result's shape instead of inheriting the first
    /// operand's. For `atan2()` that shape is always a canonical `<angle>`.
    @inline(never)
    private mutating func simplifyAtan2(_ i: Int, _ options: CalcSimplification) {
        guard let aChild = child(i, 0), let bChild = child(i, 1),
            let a = nodes[aChild].numericLeaf, let b = nodes[bChild].numericLeaf else {
            return
        }
        guard options.switchTogether(a, b), options.unitsMatch(a, b), options.fullyResolved(a) else {
            return
        }
        setLeaf(i, NumericLeaf.canonicalAngle(CalcExecutor.atan2(a.value, b.value)))
    }

    /// `simplify(Log&)` (`+Simplification.cpp:1282`-`:1306`).
    @inline(never)
    private mutating func simplifyLog(_ i: Int) {
        guard nodes[i].childCount == 2 else {
            simplifyNumberToNumber(i, CalcExecutor.log)
            return
        }
        guard let aChild = child(i, 0), let bChild = child(i, 1),
            nodes[aChild].alternative == .Number, nodes[bChild].alternative == .Number else {
            return
        }
        setLeaf(i, NumericLeaf.number(CalcExecutor.log(nodes[aChild].value, nodes[bChild].value)))
    }

    /// `simplify(CalcMix&)` (`+Simplification.cpp:1446`-`:1691`), the second-largest body in the
    /// C++ file.
    ///
    /// Four phases, all four kept. The weight survey (`:1487`-`:1507`); the `!canNormalize` early
    /// return that only drops known-zero items (`:1509`-`:1529`); the `total >= 100` and
    /// `total < 100` normalisation branches (`:1531`-`:1611`); and the accumulator, which requires
    /// every surviving item to be the same numeric kind and to agree on that kind's own identity
    /// (`:1613`-`:1689`). `zeroValueMatchingChild`'s eleven-case category table (`:1454`-`:1482`) is
    /// reached through `numericLeafForCategory`, which is shared with step 9.4, so no category table
    /// is written a third time.
    ///
    /// The plan is recomputed at emit rather than carried, and that is the one real design choice
    /// here. `rebuildSlot(const Vector<CalcMix::Item>&)` (`:1976`) wants one
    /// `pushCalcMixItemWeight` plan per surviving item at emit time, and a flat node has two spare
    /// bytes -- nowhere to keep an item index, a `Double` and a flag per child. Pushing them during
    /// the fold does not work either: the weight stack is consumed from the top by item count, and
    /// the reverse scan folds an inner `calc-mix()` before an outer one while `emit` reaches the
    /// inner one first, so the inner rebuild would take the outer's plans. `calcMixItemPlan` is a
    /// pure function of one original weight and the survey of all of them, so `emit` runs it a
    /// second time and gets the same survivor list in the same order, onto which the surviving flat
    /// children zip.
    ///
    /// The sum failing is a rebuild, not a refusal. `:1681` returns `nullopt` from a `simplify` that
    /// has already rewritten `root.children`, so `calc-mix(10% 25%, 10px 75%)` keeps its
    /// `calc-mix()` with the normalised weights. The relink below therefore happens whether or not
    /// the accumulator agrees, and it happens before the accumulator reads anything.
    @inline(never)
    private mutating func simplifyCalcMix(
        _ i: Int,
        _ original: borrowing WebCore.CSSCalc.Child,
        _ options: CalcSimplification
    ) {
        let itemCount = nodes[i].childCount
        guard itemCount > 0 else {
            return
        }
        let origin = nodes[i].origin

        guard let survey = calcMixSurvey(origin, itemCount, original) else {
            declined = true
            return
        }

        // The all-zero answers (`:1514`-`:1516` and `:1587`-`:1590`), written as the C++'s two
        // separate branches rather than merged: they sit in different normalisation cases and only
        // one of them tests `numberOfOmittedWeights`. The first is dead -- `!canNormalize` needs a
        // `Calc` weight, which is never `isKnownZero`, so `itemCount` cannot equal the known-zero
        // count there -- and is reproduced anyway, because a dead branch transcribed is cheaper to
        // audit than a dead branch reasoned away.
        if !survey.canNormalize {
            if survey.numberOfKnownZeroWeights != 0, itemCount == survey.numberOfKnownZeroWeights {
                calcMixFoldToZero(i, options)
                return
            }
        } else if survey.total < 100 {
            if survey.numberOfKnownZeroWeights > 0, survey.numberOfOmittedWeights == 0,
                itemCount == survey.numberOfKnownZeroWeights {
                calcMixFoldToZero(i, options)
                return
            }
        }

        guard calcMixKeepSurvivors(i, origin, itemCount, survey, original) else {
            declined = true
            return
        }

        // `!canNormalize` returns `{ }` on every path (`:1511`, `:1521`, `:1528`), so the
        // accumulator never runs for it and the node is rebuilt from whatever the relink left. It
        // must: a `Calc` weight is a whole nested `CSSCalcValue`, `swiftCalcMixItemWeight` reports
        // its value as 0 rather than as anything usable, and weighting an item by it would be an
        // invented answer rather than a fold.
        guard survey.canNormalize else {
            return
        }

        // Phase 4, the weighted sum (`:1613`-`:1689`). Over the survivors, which is what the relink
        // just left in the child list, and over their normalised weights, which `calcMixItemPlan`
        // gives again -- the same recomputation `emit` makes, for the same reason. `/ 100.0`, not
        // `* 0.01`: they differ in the last bit.
        var accumulated: NumericLeaf? = nil
        var cursor = nodes[i].firstChild
        var index: UInt32 = 0
        while cursor != CalcFlatNode.noNode, index < itemCount {
            guard let weight = calcMixWeight(origin, index, original) else {
                declined = true
                return
            }
            index += 1
            let plan = calcMixItemPlan(weight, survey)
            guard plan.survives else {
                continue
            }

            let c = Int(cursor)
            cursor = nodes[c].nextSibling
            guard let leaf = nodes[c].numericLeaf else {
                // `[](const auto&)`: an item that is not a `Numeric` ends the fold and the node is
                // rebuilt from the children the relink left.
                return
            }
            let scaled = plan.weight / 100.0
            guard let current = accumulated else {
                accumulated = leaf.withValue(leaf.value * scaled)
                continue
            }
            guard options.calcMixAccumulatorAgrees(current, leaf) else {
                return
            }
            accumulated = current.withValue(current.value + leaf.value * scaled)
        }

        guard let result = accumulated else {
            // No survivors at all. Unreachable -- every path that can empty the list either folded
            // through `calcMixFoldToZero` above or kept the item whose weight took `total` to 100 --
            // and rebuilt rather than asserted, which cannot be wrong.
            return
        }
        setLeaf(i, result)
    }

    /// Phase 1 (`+Simplification.cpp:1487`-`:1507`), in one descent of the original tree.
    private func calcMixSurvey(
        _ origin: UInt32,
        _ itemCount: UInt32,
        _ original: borrowing WebCore.CSSCalc.Child
    ) -> CalcMixWeightSurvey? {
        return withCalcOriginalNode(original, origin) { node -> CalcMixWeightSurvey in
            var survey = CalcMixWeightSurvey()
            var index: UInt32 = 0
            while index < itemCount {
                // `&+=`: both counters are bounded by `itemCount`, the `childCount()` of a
                // `calc-mix()` already in memory.
                let weight = WebCore.CSSCalc.swiftCalcMixItemWeight(node, index)
                if !weight.present {
                    survey.numberOfOmittedWeights &+= 1
                } else if weight.isRaw {
                    if weight.value == 0 {
                        survey.numberOfKnownZeroWeights &+= 1
                    }
                    survey.total += weight.value
                } else {
                    survey.canNormalize = false
                }
                index += 1
            }
            return survey
        }
    }

    /// One item's weight off the original, for the two passes that need it after the survey.
    private func calcMixWeight(
        _ origin: UInt32,
        _ index: UInt32,
        _ original: borrowing WebCore.CSSCalc.Child
    ) -> WebCore.CSSCalc.CSSCalcSwiftCalcMixWeight? {
        return withCalcOriginalNode(original, origin) { WebCore.CSSCalc.swiftCalcMixItemWeight($0, index) }
    }

    /// Phases 2 and 3 applied to the child list: keep the surviving items, in item order, and
    /// relink. The C++ builds a `Vector<Child> newChildren` and moves it over `root.children`
    /// (`:1524`, `:1554`, `:1581`, `:1599`); a linked list relinks in place and allocates nothing.
    private mutating func calcMixKeepSurvivors(
        _ i: Int,
        _ origin: UInt32,
        _ itemCount: UInt32,
        _ survey: CalcMixWeightSurvey,
        _ original: borrowing WebCore.CSSCalc.Child
    ) -> Bool {
        var previous = CalcFlatNode.noNode
        // `kept` counts survivors of one sibling list, each a distinct slot of `nodes`, so it is
        // bounded by `nodes.count` and its `&+=` below cannot wrap.
        var kept: UInt32 = 0
        var cursor = nodes[i].firstChild
        var index: UInt32 = 0
        while cursor != CalcFlatNode.noNode, index < itemCount {
            guard let weight = calcMixWeight(origin, index, original) else {
                return false
            }
            index += 1
            let c = Int(cursor)
            let next = nodes[c].nextSibling
            if calcMixItemPlan(weight, survey).survives {
                if previous == CalcFlatNode.noNode {
                    nodes[i].firstChild = cursor
                } else {
                    nodes[Int(previous)].nextSibling = cursor
                }
                previous = cursor
                kept &+= 1
            }
            cursor = next
        }
        if previous == CalcFlatNode.noNode {
            nodes[i].firstChild = CalcFlatNode.noNode
        } else {
            nodes[Int(previous)].nextSibling = CalcFlatNode.noNode
        }
        nodes[i].childCount = kept
        return true
    }

    /// `zeroValueMatchingChild(children[0])` (`+Simplification.cpp:1454`-`:1482`, called at `:1516`
    /// and `:1589`): when every weight is known zero the whole `calc-mix()` becomes a zero of the
    /// first item's category.
    private mutating func calcMixFoldToZero(_ i: Int, _ options: CalcSimplification) {
        guard let first = child(i, 0),
            let childType = emittedType(nodes[first], options),
            let category = childType.calculationCategory().value,
            let zero = options.numericLeafForCategory(category, 0) else {
            declined = true
            return
        }
        setLeaf(i, zero)
    }

    /// `simplify(Progress&)` and `simplify(ProgressNoClamp&)` (`+Simplification.cpp:1404`-`:1444`),
    /// which are identical but for the executor.
    @inline(never)
    private mutating func simplifyProgress(
        _ i: Int,
        _ options: CalcSimplification,
        _ operation: (Double, Double, Double) -> Double
    ) {
        guard let valueChild = child(i, 0), let startChild = child(i, 1), let endChild = child(i, 2),
            let value = nodes[valueChild].numericLeaf,
            let start = nodes[startChild].numericLeaf,
            let end = nodes[endChild].numericLeaf else {
            return
        }
        guard options.switchTogether(value, start), options.switchTogether(start, end) else {
            return
        }
        guard options.unitsMatch(value, start), options.unitsMatch(start, end),
            options.fullyResolved(value) else {
            return
        }
        setLeaf(i, NumericLeaf.number(operation(value.value, start.value, end.value)))
    }

    /// `simplify(Hypot&)` (`+Simplification.cpp:1205`-`:1279`), the only stateful fold in the file:
    /// an optimistic pass over the children carrying a five-state tag, which the C++ cannot
    /// short-circuit because its evaluation API takes a functor over the whole range.
    ///
    /// Three things that look like details and are not.
    ///
    /// 1. Child order. `sum += value * value` runs in `root.children` order
    ///    (`CSSCalcExecutor.h:404`-`:416`) and floating-point `+` is not associative, so this walks
    ///    `firstChild`/`nextSibling` and never a re-sorted or re-linked list.
    /// 2. The value is computed even after the tag fails, and only then discarded by the final
    ///    switch. Observationally identical to an early exit -- kept because it is the C++'s shape
    ///    and because `.failed` is absorbing, so an early exit would have to prove that.
    /// 3. The empty list must be "unchanged", not a division and not an index.
    ///    `OperatorExecutor<Hypot>` returns NaN for an empty range without calling the functor
    ///    (`CSSCalcExecutor.h:406`-`:407`), so `result` stays `monostate` and the trailing
    ///    `switchOn` takes the catch-all. Returning here is that, and it is also what keeps
    ///    `firstElement` from being read before it is written.
    @inline(never)
    private mutating func simplifyHypot(_ i: Int, _ options: CalcSimplification) {
        let childCount = nodes[i].childCount
        guard childCount > 0 else {
            return
        }

        var tag = HypotTag.unset
        var sumOfSquares = 0.0
        var firstElement = 0.0
        var isFirst = true
        var cursor = nodes[i].firstChild
        while cursor != CalcFlatNode.noNode {
            let c = Int(cursor)
            let value: Double
            if let leaf = nodes[c].numericLeaf {
                value = options.hypotElement(leaf, &tag)
            } else {
                tag = .failed
                value = Double.nan
            }
            if isFirst {
                firstElement = value
                isFirst = false
            }
            sumOfSquares += value * value
            cursor = nodes[c].nextSibling
        }

        let value = childCount == 1 ? firstElement.magnitude : sumOfSquares.squareRoot()

        switch tag {
        case .number:
            setLeaf(i, NumericLeaf.number(value))

        case .percentage:
            guard let optionsCategory = WebCore.CSS.Category(rawValue: options.category) else {
                // Never taken: an imported C++ scoped enum's `init?(rawValue:)` does not validate.
                return
            }
            setLeaf(i, NumericLeaf.percentage(value, CalcType.determinePercentHint(optionsCategory)))

        case .dimension(let canonicalUnit):
            setLeaf(i, NumericLeaf(
                kind: .canonicalDimension,
                value: value,
                unitType: canonicalUnit,
                percentHint: 0
            ))

        case .unset, .failed:
            // `nullopt`: the node keeps its kind, its cached `Type` and its children. `.unset` is
            // unreachable (the empty list returned above) but enumerated rather than defaulted, so a
            // future tag has to be classified.
            return
        }
    }

    /// `simplify(Product&)` (`+Simplification.cpp:717`-`:909`), css-values-4 steps 9.1 to 9.5.
    private mutating func simplifyProduct(_ i: Int, _ options: CalcSimplification) {
        guard nodes[i].childCount > 0 else {
            return
        }

        // 9.1 (`:744`-`:750`), unconditionally unlike `Sum`'s, and one level: a grandchild that is
        // itself a `Product` is kept as a factor, because `processChild` (`:734`) tests only for
        // `Number`. Spliced-in grandchildren are examined by 9.2 below, which is why these are two
        // passes here where the C++ writes them as one; the visitation order is identical.
        spliceNestedChildren(i, .Product)

        // 9.2 (`:729`-`:742`): fold every `<number>` factor into one value and unlink it. Only
        // `Number` -- not a percentage, not a dimension -- which is what leaves those to 9.4.
        var numericProduct: Double?
        // The slot of the first `<number>` folded away, reused at `:801` below. Not a link, so `-1`
        // rather than `noNode` is the "none yet" value.
        var mergedNumberSlot = -1
        var survivors: UInt32 = 0
        var previous = CalcFlatNode.noNode
        var cursor = nodes[i].firstChild
        while cursor != CalcFlatNode.noNode {
            let c = Int(cursor)
            let next = nodes[c].nextSibling
            if nodes[c].alternative == .Number {
                // `numericProduct = Number { .value = childValue->value * numericProduct->value }`
                // (`:737`) -- the new factor on the left, which `multipliedNumericProduct`
                // documents and which matters only for the sign of a NaN.
                numericProduct = options.multipliedNumericProduct(nodes[c].value, numericProduct)
                if mergedNumberSlot < 0 {
                    mergedNumberSlot = c
                }
                if previous == CalcFlatNode.noNode {
                    nodes[i].firstChild = next
                } else {
                    nodes[Int(previous)].nextSibling = next
                }
            } else {
                previous = cursor
                // `&+=` at both `survivors` sites: survivors are distinct slots of one sibling list,
                // so the count is bounded by `nodes.count`. The second site adds the one folded
                // `<number>` slot back, which is a slot this same list just released.
                survivors &+= 1
            }
            cursor = next
        }
        nodes[i].childCount = survivors

        if let numericProduct {
            if survivors == 0 {
                setLeaf(i, NumericLeaf.number(numericProduct))
                return
            }

            if survivors == 1, let only = child(i, 0), distributeNumber(i, only, numericProduct) {
                return
            }

            if mergedNumberSlot >= 0 {
                nodes[mergedNumberSlot].value = numericProduct
                nodes[mergedNumberSlot].firstChild = CalcFlatNode.noNode
                nodes[mergedNumberSlot].childCount = 0
                nodes[mergedNumberSlot].nextSibling = CalcFlatNode.noNode
                if previous == CalcFlatNode.noNode {
                    nodes[i].firstChild = UInt32(mergedNumberSlot)
                } else {
                    nodes[Int(previous)].nextSibling = UInt32(mergedNumberSlot)
                }
                survivors &+= 1
                nodes[i].childCount = survivors
            }
        }

        // 9.4 (`:806`-`:905`). `success` starts false and is overwritten by each iteration, so an
        // empty list falls through to 9.5 rather than folding to `1`. Unreachable here -- a
        // zero-survivor product either returned above or gained the merged number -- and reproduced
        // anyway.
        var productValue = 1.0
        var productType = CalcType()
        var success = false
        var factor = nodes[i].firstChild
        while factor != CalcFlatNode.noNode {
            success = multiplyFactor(Int(factor), &productValue, &productType, options)
            if !success {
                break
            }
            factor = nodes[Int(factor)].nextSibling
        }

        if success, let resolvedCategory = productType.calculationCategory().value,
           let folded = options.numericLeafForCategory(resolvedCategory, productValue) {
            setLeaf(i, folded)
            return
        }

    }

    /// Step 9.3's three cases (`+Simplification.cpp:763`-`:798`) for the single surviving factor `s`.
    private mutating func distributeNumber(_ i: Int, _ s: Int, _ product: Double) -> Bool {
        if nodes[s].isNumericLeaf {
            // `makeChildWithValueBasedOn(numeric.value * numericProduct->value, numeric)`
            // (`:765`-`:767`): the factor's own alternative, unit and percent hint with a scaled
            // value, which is what promoting the node and then writing the value is. It cannot be a
            // `Number` -- 9.2 folded every one of those away -- so this is the `Percentage`,
            // `CanonicalDimension` and `NonCanonicalDimension` overloads.
            let scaled = nodes[s].value * product
            replace(i, with: s)
            nodes[i].value = scaled
            return true
        }

        if nodes[s].alternative == .Sum {
            guard allChildrenAreNumericLeaves(s) else {
                return false
            }
            var cursor = nodes[s].firstChild
            while cursor != CalcFlatNode.noNode {
                nodes[Int(cursor)].value *= product
                cursor = nodes[Int(cursor)].nextSibling
            }
            replace(i, with: s)
            return true
        }

        if nodes[s].alternative == .Invert {
            // `:780`-`:788`: the C++ multiplies the inverted operand's value by the product and
            // returns a leaf shaped like that operand, discarding the `Invert` -- so a factor of
            // `1/x` scales by `x` rather than dividing by it. Reproduced deliberately, because the
            // differential compares against this C++. Dividing here, or restoring the `Invert`,
            // diverges the two paths; both must change together.
            guard nodes[s].childCount == 1, let inner = child(s, 0), nodes[inner].isNumericLeaf else {
                return false
            }
            let scaled = nodes[inner].value * product
            replace(i, with: inner)
            nodes[i].value = scaled
            return true
        }

        return false
    }

    /// One iteration of step 9.4's factor loop (`+Simplification.cpp:815`-`:878`): multiply this
    /// factor's type into `productType` and its value into `productValue`.
    private func multiplyFactor(
        _ c: Int,
        _ productValue: inout Double,
        _ productType: inout CalcType,
        _ options: CalcSimplification
    ) -> Bool {
        if let leaf = nodes[c].numericLeaf {
            switch leaf.kind {
            case .number:
                productValue *= leaf.value
                return true

            case .percentage, .canonicalDimension:
                guard let factorType = options.numericLeafType(leaf),
                      let multiplied = CalcType.multiply(productType, factorType).value else {
                    return false
                }
                productType = multiplied
                productValue *= leaf.value
                return true

            case .nonCanonicalDimension:
                // Not a case of the C++ switch, so it reaches
                // `[](const auto&) -> bool { return false; }` (`:872`-`:874`). Reachable:
                // `calc(2 * 1em)` with no conversion data leaves the `em` uncanonicalized, and it
                // arrives here as a `Product` factor.
                return false
            }
        }

        // `[&](IndirectNode<Invert>& invertChild)` (`:840`-`:871`). Every other surviving node -- a
        // `Sum`, a `Min`, a `Product` the splice could not take -- is the outer `[](const auto&)` overload
        // (`:872`), and an `Invert` whose operand is not `Numeric` is the inner one (`:867`).
        guard nodes[c].alternative == .Invert, nodes[c].childCount == 1, let a = child(c, 0),
              let inner = nodes[a].numericLeaf else {
            return false
        }
        switch inner.kind {
        case .number:
            // "`<number>` is the identity type, so multiplying / inverting by it has no effect."
            // (`:843`) Unreachable, since 7.1 collapsed `Invert(Number)` already, and reproduced.
            productValue /= inner.value
            return true

        case .percentage, .canonicalDimension:
            guard let factorType = options.numericLeafType(inner) else {
                return false
            }
            let invertedType = CalcType.invert(factorType)
            guard let multiplied = CalcType.multiply(productType, invertedType).value else {
                return false
            }
            productType = multiplied
            productValue /= inner.value
            return true

        case .nonCanonicalDimension:
            return false
        }
    }

    /// Emit the whole tree, or report the mid-pass refusal a fold recorded.
    func emitRoot(
        _ original: borrowing WebCore.CSSCalc.Child,
        into builder: inout WebCore.CSSCalc.CSSCalcSwiftBuilder
    ) -> Bool {
        guard !declined else {
            return false
        }
        return emit(0, original, into: &builder)
    }

    /// Materialise the subtree rooted at `i` as a real `CSSCalc::Child`, on the builder's operand
    /// stack, and report whether it got there.
    func emit(
        _ i: Int,
        _ original: borrowing WebCore.CSSCalc.Child,
        into builder: inout WebCore.CSSCalc.CSSCalcSwiftBuilder
    ) -> Bool {
        let node = nodes[i]

        // Three routes out of the flat tree, and this switch picks between the two a node with no
        // operands can take. `buildOperation` is the third and the cheap one -- one enum-indexed
        // jump table and one `makeChild` -- and it is what every node that states its own
        // alternative uses. The other two exist because a fixed-size flat node cannot carry every
        // payload, and they cost an O(index) walk of the original tree at 192 instructions a step,
        // so an alternative belongs on them only when it genuinely cannot be built from operands.
        switch node.alternative {
        case .Number, .Percentage, .CanonicalDimension, .NonCanonicalDimension:
            guard let leaf = node.numericLeaf else {
                return false
            }
            return builder.pushLeaf(leaf.boundaryLeaf, i == 0)

        case .Symbol, .SiblingCount, .SiblingIndex:
            // The three non-numeric leaves, unresolved. `pushLeaf` serves the four numeric ones and
            // refuses anything else (`+Simplification.cpp:2060`-`:2063`), and `rebuildFrom` refuses
            // a leaf outright because there are no slots to fill (`:2166`-`:2169`), so a deep copy
            // of the original is the only route.
            return calcEmitFromOrigin(node.origin, 0, true, i == 0, original, &builder)

        default:
            // Every operation, whether or not `buildOperation` can construct it. One it cannot is
            // refused with `false` and reported as a decline, which is why this case is safe rather
            // than merely convenient: an alternative added to `CSSCalcSwiftAlternative` and not to
            // `CalcFlatCoverage.mask` never reaches emit at all, and one added to both without a
            // route declines the tree instead of building the wrong node.
            break
        }

        var pushed: UInt32 = 0
        var cursor = node.firstChild
        if node.flags & CalcFlatNodeFlags.anchorSideIsSubtree != 0, cursor != CalcFlatNode.noNode {
            // `anchor()`'s `<anchor-side>` subtree is child 0 and is not an operand: `rebuildFrom`
            // takes it off the original with `CSSCalc::copy` (`+Simplification.cpp:2150`), matching
            // `copyAndSimplifyChildren`'s `.side = copy(anchor->side)` (`:1797`). Pushing it would
            // leave one operand more than `rebuildFrom` consumes, and its `!cursor.exhausted()`
            // test would refuse the whole tree. `calcFlatten` still wrote the subtree, because
            // coverage has to see an alternative sitting inside a side, and `insideAnchorSide` is
            // why nothing simplified it.
            cursor = nodes[Int(cursor)].nextSibling
        }
        while cursor != CalcFlatNode.noNode {
            guard emit(Int(cursor), original, into: &builder) else { return false }
            pushed &+= 1
            cursor = nodes[Int(cursor)].nextSibling
        }

        switch node.alternative {
        case .Sum, .Product, .Negate, .Invert, .Min, .Max:
            break

        case .CalcMix:
            // The one alternative whose origin route needs something pushed before `rebuildFrom`:
            // one weight plan per surviving item. See `calcEmitCalcMix` and
            // `CalcFlatTree.simplifyCalcMix` for why the plan is recomputed here rather than
            // carried from the fold.
            return calcEmitCalcMix(node.origin, pushed, i == 0, original, &builder)

        default:
            // Everything `buildOperation` does not construct, which is every operation whose slots
            // are not one `Children` or one `Child`: a `Random::Sharing` naming a dashed-ident, a
            // per-item weight that can be a whole nested `CSSCalcValue`, an `AtomString` element
            // name, an `AnchorSide` subtree -- and equally a `Clamp`'s two `ChildOrNone` bounds and
            // a `round()`'s optional second argument, which the flat node can describe but the
            // boundary has no entry for. Its children are already operands; everything else comes
            // off the original through `rebuildFrom`, which fills slots generically over the tuple
            // conformance and so serves all 41 alternatives with no C++ added per alternative.
            return calcEmitFromOrigin(node.origin, pushed, false, i == 0, original, &builder)
        }

        // The node's own type, always, and never a fresh `toType` of the operands.
        return builder.buildOperation(node.alternative, pushed, node.type, i == 0)
    }
}

/// The `SimplificationOptions` the two flat probes run under.
private var calcFlatProbeOptions: CalcSimplification {
    return CalcSimplification(
        percentageResolveToDimension: false,
        allowZeroValueLengthRemovalFromSum: false,
        category: 0
    )
}

#if ENABLE_CSS_TOKENIZER_SWIFT_BRIDGE

/// Convert and then fold, `iterations` times, returning the bit pattern of the resulting root's
/// value so the caller can check it against the C++ rather than trust the timing.
@_expose(Cxx)
public func cssCalcFlatSimplifyProbeSwift(_ root: borrowing WebCore.CSSCalc.Child, _ iterations: UInt32) -> UInt64 {
    var bits: UInt64 = 0
    let options = calcFlatProbeOptions
    for _ in 0..<iterations {
        // `nil` means the pass declined the fixture rather than timing it, and 0 is not a bit pattern
        // any fixture here produces, so the caller's value check catches a probe that measured
        // nothing.
        bits = withCalcFlatTree(root, WebCore.CSSCalc.swiftNodeInfo(root), calcFlatStackCapacity) { tree in
            tree.simplify(root, options, nil)
            return tree.nodes[0].value.bitPattern
        }.result ?? 0
    }
    return bits
}

/// Converts `root` `iterations` times and returns the summed node count.
@_expose(Cxx)
public func cssCalcFlattenProbeSwift(_ root: borrowing WebCore.CSSCalc.Child, _ iterations: UInt32) -> UInt32 {
    var total: UInt32 = 0
    for _ in 0..<iterations {
        total &+= withCalcFlatTree(root, WebCore.CSSCalc.swiftNodeInfo(root), calcFlatStackCapacity) { tree in UInt32(tree.count) }.result ?? 0
    }
    return total
}

/// Convert, simplify, and emit a real `CSSCalc::Child`, `iterations` times, returning how many
/// iterations emitted successfully so the caller can check the count rather than trust the timing.
@_expose(Cxx)
public func cssCalcFlatEmitProbeSwift(
    _ root: borrowing WebCore.CSSCalc.Child,
    _ builder: inout WebCore.CSSCalc.CSSCalcSwiftBuilder,
    _ iterations: UInt32
) -> UInt32 {
    var emitted: UInt32 = 0
    let options = calcFlatProbeOptions
    for _ in 0..<iterations {
        builder.clearOperands()
        if withCalcFlatTree(root, WebCore.CSSCalc.swiftNodeInfo(root), calcFlatStackCapacity, { tree -> Bool in
            tree.simplify(root, options, builder)
            return tree.emitRoot(root, into: &builder)
        }).result == true {
            emitted &+= 1
        }
    }
    return emitted
}

#endif
