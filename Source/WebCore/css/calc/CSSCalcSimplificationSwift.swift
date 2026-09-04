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

// `CSSCalc::Type` and its algebra (`multiply`, `invert`, `calculationCategory`,
// `determinePercentHint`, `determineType`, `applyPercentHint`) for `Product`'s step 9.4.
//
// Called via the boundary rather than reimplemented, so both arms share the one definition in
// CSSCalcType.cpp. CSSCalcType.h is self-contained (only `<array>`, `<optional>`,
// `<wtf/Forward.h>`, with `CSSUnitType` and `CSS::Category` forward-declared), which is what lets
// it be imported directly.
internal import WebCore_Private.CSSCalcTypeSwiftTypes

// `CSS::Category`, which `Type::determinePercentHint` takes and `Type::calculationCategory` returns.
//
// Needed because `percentageResolveToDimension` alone cannot distinguish `LengthPercentage` from
// `AnglePercentage` for step 9.4's `Category::Percentage` arm.
internal import WebCore_Private.CSSPrimitiveNumericCategorySwiftTypes

// The `CxxOptional` protocol, for `std::optional<Type>` and `std::optional<CSS::Category>` --
// needed for the non-deprecated `.value` spelling on the imported optionals.
internal import Cxx

// libm, for the trig/pow/log/exp functions the C++ arm calls directly (`std::sin` on Darwin is
// `::sin`), so both arms reach the same functions. Everything else the executors need is stdlib.
import Darwin

// Swift port of CSSCalcTree+Simplification.cpp's calc() simplification, selected by
// USE_SWIFT_CSS_CALC_SIMPLIFICATION.
//
// Handles the four numeric leaves, `Symbol`, `Invert`, `Deg2Rad`, most single-argument and
// fixed-arity operations, `hypot()`, `min()`/`max()`, `clamp()` and `Sum`; everything else declines
// the whole tree, including `Product`, `Negate`, `CalcMix`, `Random`, `Anchor`/`AnchorSize` and
// `sibling-count()`/`sibling-index()`.
//
// A node's own kind never crosses the boundary: `rebuildFrom` recovers it from the original node's
// variant tag.
//
// The walk is two passes because the builder is an operand stack with no pop: `fold` decides what a
// subtree collapses to without pushing, and `rewrite` pushes exactly one operand per node -- a
// single eager pass would strand a folded node's children under its answer.
//
// The arithmetic is ported rather than upcalled, since Swift's `Double` operations and Darwin's
// transcendentals are the same libm calls the C++ arm makes. No `unsafe`: the tree crosses as a
// borrowed `~Escapable` handle and the output as a `SWIFT_SAFE` builder taken `inout`.

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
    // `Type::PercentHintValue::InternalValue::None`, which is 0 and is what the boundary's
    // `percentHint` field means by 0.
    return 0
}

/// The inverse: the `Type::PercentHint` whose raw value this byte is, or `nil` for 0 or an
/// unrecognized value.
///
/// `init?(rawValue:)` on an imported C++ scoped enum does not validate -- it accepts any raw value.
/// Trusting it here previously let an out-of-range hint alias onto `.length` in
/// `Type::operator[](PercentHint)`, which folded `calc(10% * 1em / 1em)` to `calc(10px)` where the
/// C++ gives `calc(10%)`. The six explicit comparisons below are what actually reject.
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

/// A canonical dimension in a named canonical unit, covering the remaining five dimensions step
/// 9.4 can produce. The single-dimension helpers above are kept separate so each documents which
/// C++ site produces it.
    @inline(always)
    static func canonical(_ value: Double, _ canonicalUnit: WebCore.CSSUnitType) -> NumericLeaf {
        return NumericLeaf(
            kind: .canonicalDimension,
            value: value,
            unitType: UInt16(canonicalUnit.rawValue),
            percentHint: 0
        )
    }

/// `makeChild(Percentage { .value = v, .hint = H })`, the three shapes step 9.4's category switch
/// produces. The hint is the real `Type::PercentHintValue`, not a transcribed constant.
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

/// `OperatorExecutor<Operator::Sum>` (CSSCalcExecutor.h:94-:97): plain IEEE `a + b`, so the two arms
/// agree by construction on NaN, signed zero and infinities. What differs is accumulation ORDER,
/// since `+` is not associative -- `sumMergePlan` accumulates in term index order for that reason.
    @inline(always)
    static func sum(_ a: Double, _ b: Double) -> Double {
        return a + b
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

    /// `OperatorExecutor<Operator::Random>` (CSSCalcExecutor.h:506-:559).
    ///
    /// css-values-5 § 9.4: pick a value in `[min, max]` from a base value in `[0, 1]`, snapped to a
    /// `step` grid when given. The base value is cached on the Document/element and reaches this file
    /// through `resolveStyleCoupledValue`.
    ///
    /// The five early exits are each a different non-finite case, transcribed one for one because
    /// they don't agree: a NaN bound gives NaN, an infinite minimum gives that infinity, an infinite
    /// range gives NaN, an infinite step count falls back to the unstepped formula. `max < min` is a
    /// comparison, not a `max(min, max)` call, which matters for signed zero.
    @inline(always)
    static func random(_ randomBaseValue: Double, _ minimum: Double, _ maximum: Double, _ step: Double?) -> Double {
        if minimum.isNaN || maximum.isNaN {
            return Double.nan
        }
        if minimum.isInfinite {
            return minimum
        }

        // `if (max < min) max = min;` -- "If the maximum value is less than the minimum value, it
        // behaves as if it's equal to the minimum value."
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

        // "Let epsilon be step / 1000."
        let epsilon = step / 1000.0

        // "Let N be the largest integer such that min + N * step is less than or equal to max."
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

        // "Let step index be a random integer less than N+1, given R."
        let stepIndex = roundDown(randomBaseValue * (n + 1.0), 1.0)

        // "Let value be min + step index * step."
        let value = minimum + stepIndex * step

        // "If step index is N and value is within epsilon of max, return max."
        if stepIndex == n && (upperBound - value).magnitude < epsilon {
            return upperBound
        }
        return value
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
/// The node collapses to one of its own children, unfolded (`+Simplification.cpp:409`, `:456`,
/// `:1015`): `rewrite` pushes that subtree's operand and nothing else.
///
/// Addresses only a direct child, not a grandchild: `Sum`'s spliced terms need `.replacedBySumTerm`
/// below instead, since a spliced term can sit at any depth. Never produced when the promoted term is
/// a leaf -- see `promoteTerm` -- which keeps `.leaf`'s invariant exact.
    case replacedByTerm(child: UInt32)
/// A `Sum` that collapses to one of its own flattened terms (`simplify(Sum&)`'s `:595`, `:657`,
/// `:675`), after step 8.1 splices every nested `Sum`'s children into it.
///
/// The payload is an origin ordinal, not a child index, since a term can sit at unbounded depth after
/// splicing: `collectSumTerms` numbers positions in visit order and `pushSumTerm` re-walks to find the
/// one requested. Never produced when the term is a leaf; see `promoteSumTerm`.
    case replacedBySumTerm(origin: UInt32)
/// The node collapses to its grandchild: `Negate(Negate(x))` -> `x` (rule 6.2) and
/// `Invert(Invert(x))` -> `x` (rule 7.2). Exactly two levels, since neither rule splices -- a third
/// level is handled by recursion re-folding the grandchild. Never produced when the grandchild is a
/// leaf; see `promoteGrandchild`.
    case replacedByGrandchild(child: UInt32, grandchild: UInt32)
/// `Negate`'s rules 6.3 and 6.4: the child is a `Sum` or `Product` whose children are all numeric,
/// and the answer is that node with every child's value negated. The C++ mutates the child list in
/// place; since Swift has no moved-from state, `fold` decides every child is numeric and `rewrite`
/// pushes one negated leaf per child, then rebuilds the child's own kind. No payload: the negated leaf
/// list is dynamically sized and `rewrite` re-derives it rather than allocating on every `Fold` value.
    case negatedChildren
/// `Product`'s step 9.3 `Sum` arm: after 9.2 merges every `Number` factor into one, the one
/// remaining factor is a `Sum` whose children are all numeric, multiplied by the merged number.
///
/// Kept separate from `.negatedChildren` because `-x` and `x * -1.0` can differ in a NaN's sign bit
/// (`fneg` vs `fmul` on AArch64), and the C++ uses a unary minus at one site and `*=` at the other.
/// Addressed by origin ordinal for the same splicing reason as `.replacedBySumTerm`.
    case scaledSumChildren(origin: UInt32, factor: Double)
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

/// Whether a node of this alternative is a leaf whose `.unchanged` answer must be pushed as a copy
/// rather than handed to `rebuildFrom`. Only `Symbol` (unresolved `<calc-keyword>`) and
/// `SiblingCount`/`SiblingIndex` (no conversion data/element) can reach here as leaves; the four
/// numeric leaves never reach `rebuild` at all, and every other alternative is an `IndirectNode` with
/// slots that `rebuildFrom` handles directly.
private func isCopiedLeafAlternative(_ alternative: CalcAlternative) -> Bool {
    switch alternative {
    case .Symbol, .SiblingCount, .SiblingIndex:
        return true

    case .Number, .Percentage, .CanonicalDimension, .NonCanonicalDimension:
        // Leaves, but they never arrive: see above. `false` is unreachable rather than wrong, and it
        // is spelled out so that the reason is here and not only in the prose.
        return false

    case .Sum, .Product, .Negate, .Invert, .Deg2Rad,
         .Min, .Max, .Clamp,
         .RoundNearest, .RoundUp, .RoundDown, .RoundToZero, .Mod, .Rem,
         .Sin, .Cos, .Tan, .Asin, .Acos, .Atan, .Atan2,
         .Pow, .Sqrt, .Hypot, .Log, .Exp, .Abs, .Sign,
         .Random, .Progress, .ProgressNoClamp, .CalcMix, .Anchor, .AnchorSize:
        // Every operation. `rebuildFrom` recovers the kind from the original's own variant tag and
        // fills its slots, which is the whole point of that method.
        return false

    @unknown default:
        // An alternative C++ grew and this file has not been taught. `false` routes it to
        // `rebuildFrom`, which is where an untaught alternative was already going.
        return false
    }
}

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

    case .Sum:
        // `simplify(Sum&)` (`:547`-`:714`). The same arity bound `Min`/`Max` take, and for the same
        // reason: `simplify(Sum&)` opens with `ASSERT(!root.children.isEmpty())`. An empty node would
        // fall through step 8.1 and rebuild empty, which is the same answer this fold would give -- but
        // an assertions build fires on the C++ arm and would not here, so this declines rather than
        // claim a node the C++ arm asserts against. Unreachable through the parser: `calc()` does not
        // parse.
        //
        // No upper bound: `Children` is a variable-arity slot and `rebuildSlot(const Children&)` takes
        // all remaining operands, so any count is structurally valid on the rebuild side. Step 8.1 can
        // also make the term count larger than `childCount`, which is what that overload is for.
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
        // `random( <random-key>? , <calc-sum>, <calc-sum>, <calc-sum>? )`; the key is not a child, so
        // `childCount` is 2 or 3 regardless of whether a key is present.
        return childCount == 2 || childCount == 3

    case .SiblingCount, .SiblingIndex:
        // Leaves (`isLeaf` true on both), so there is no arity to check.
        return true

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
    /// `Category::Percentage` arm, `Type::determinePercentHint(options.category)`
    /// (`+Simplification.cpp:885`).
    ///
    /// Carried raw rather than decoded, since the only arm that needs it decodes it there and a
    /// decode that cannot fail at the one use site is not worth a failure channel on the struct.
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

    /// `simplify(Invert&)` (`+Simplification.cpp:962`-`:979`). Rule 7.2 (`Invert(Invert(x))` -> `x`)
    /// reaches a grandchild via `childInTreeOrder`/`.replacedByGrandchild`, no boundary change needed.
    /// Rule 7.1 folds only a `<number>`, so `Invert(Invert(50%))` reaches 7.2 with a `Percentage`
    /// grandchild; `promoteGrandchild` reports it as a leaf so an enclosing `Product` still folds it.
    @inline(always)
    func foldInvert(
        _ node: borrowing WebCore.CSSCalc.CSSCalcSwiftNode,
        _ builder: borrowing WebCore.CSSCalc.CSSCalcSwiftBuilder
    ) -> Fold {
        let a = fold(node.childInTreeOrder(0), builder)
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
                // 7.2.
                return promoteGrandchild(node, 0, 0, builder)
            }
            return .unchanged(.Invert)
        case .replacedByTerm, .replacedBySumTerm, .replacedByGrandchild:
            // The child collapsed to a subtree of itself, and this file does not carry that subtree's
            // alternative, so it can't tell whether rule 7.2 applies. Declines rather than guesses;
            // reachable only from a constructed tree, since no CSS spelling of division produces one.
            return .declined(.Invert)
        case .mergedChildren, .rebuiltMinMax, .negatedChildren, .scaledSumChildren:
            // None of these can be an `Invert`, and each already carries or implies what it is, so
            // this is the C++'s `[](auto&)` arm: rebuild from the one simplified child.
            return .unchanged(.Invert)
        case .declined(let blame):
            return .declined(blame)
        }
    }

    /// `simplify(Negate&)` (`+Simplification.cpp:910`-`:960`). Rule 6.1 is a unary minus, not `0 - x`
    /// or `* -1.0`: both alternatives can disagree with `-x` on the sign bit of a zero or NaN.
    /// Rules 6.3/6.4 mutate a `Sum`/`Product` child's children in place in the C++; since Swift has
    /// no moved-from state, `numericChildren` decides every child is numeric and `rewriteNegatedChildren`
    /// re-derives the list and pushes one negated leaf per child. The two declines below are named
    /// gaps, not catch-alls.
    @inline(always)
    func foldNegate(
        _ node: borrowing WebCore.CSSCalc.CSSCalcSwiftNode,
        _ builder: borrowing WebCore.CSSCalc.CSSCalcSwiftBuilder
    ) -> Fold {
        let child = node.childInTreeOrder(0)
        let a = fold(child, builder)
        switch a {
        case .leaf(let leaf):
            // 6.1. The unary minus above.
            return .leaf(leaf.withValue(-leaf.value))

        case .unchanged(let childAlternative):
            if childAlternative == .Negate {
                // 6.2: the grandchild, unfolded. `promoteGrandchild` returns it as a leaf when it
                // folds to one, keeping `Fold`'s `.leaf` invariant exact.
                return promoteGrandchild(node, 0, 0, builder)
            }
            if childAlternative == .Sum || childAlternative == .Product {
                // 6.3 / 6.4 on an arity-preserving child.
                if numericChildren(child, a, builder) != nil {
                    return .negatedChildren
                }
            }
            // The C++'s `[](auto&)` arm, and the `!all_of(..., isNumeric)` exit of 6.3/6.4: `nullopt`,
            // so the `Negate` is rebuilt from its one simplified child.
            return .unchanged(.Negate)

        case .mergedChildren(let childAlternative):
            if childAlternative == .Product {
                // 6.4 over a `Product` whose factor list step 9.1/9.2 changed. Reaching this arm does
                // NOT require every factor numeric -- `productHasNonNumericFactor` looks for one
                // witness that isn't, which is enough to answer `.unchanged` rather than decline.
                if productHasNonNumericFactor(child, builder) {
                    return .unchanged(.Negate)
                }
                // No witness: every child folded to `Numeric` or a spliceable `Product`, and this
                // file cannot re-derive what step 9.1 spliced into the final list. Reachable only
                // from a constructed tree, since `parseAndSimplify` flattens nested `Product`s.
                return .declined(.Negate)
            }
            if childAlternative == .Sum {
                // 6.3 over a `Sum` whose term list step 8.1 spliced or whose terms merged.
                if numericChildren(child, a, builder) != nil {
                    return .negatedChildren
                }
            }
            return .unchanged(.Negate)

        case .replacedByTerm, .replacedBySumTerm, .replacedByGrandchild:
            // The child collapsed to a subtree of itself; this file cannot tell whether 6.2, 6.3 or
            // 6.4 applies to the result, so it declines and lets the C++ arm decide.
            return .declined(.Negate)

        case .rebuiltMinMax:
            // A `clamp()` that became a `min()`/`max()`: none of `Negate`/`Sum`/`Product`, so this
            // is the `[](auto&)` arm with nothing to decline over.
            return .unchanged(.Negate)

        case .negatedChildren, .scaledSumChildren:
            // The child's own 6.3/6.4 or 9.3 already fired, leaving all-numeric children this node's
            // 6.3/6.4 applies to too -- but reporting `.unchanged` would be wrong, so it declines.
            // A named gap: reachable only from a constructed tree, no CSS spelling produces one.
            return .declined(.Negate)

        case .declined(let blame):
            return .declined(blame)
        }
    }

    /// `std::ranges::all_of(a->children, isNumeric)` (`+Simplification.cpp:923`, `:938`), over the
    /// child's post-simplification list (not the parser's original), as leaves. `nil` means at least
    /// one child is not numeric; every survivor is a leaf whenever this returns non-`nil`.
    func numericChildren(
        _ child: borrowing WebCore.CSSCalc.CSSCalcSwiftNode,
        _ folded: Fold,
        _ builder: borrowing WebCore.CSSCalc.CSSCalcSwiftBuilder
    ) -> [NumericLeaf]? {
        switch folded {
        case .unchanged(let alternative):
            guard alternative == .Sum || alternative == .Product else {
                return nil
            }
            // `.unchanged` is the arity-preserving case by definition -- see `Fold.mergedChildren` on
            // why the two are kept apart -- so the final list IS the node's own children in tree
            // order.
            let info = child.info()
            var leaves: [NumericLeaf] = []
            // `Int(clamping:)` for the capacity HINT, as `foldChildren` explains: saturating cannot be
            // wrong here, because `append` grows regardless.
            leaves.reserveCapacity(Int(clamping: info.childCount))
            var index: UInt32 = 0
            while index < info.childCount {
                guard case .leaf(let leaf) = fold(child.childInTreeOrder(index), builder) else {
                    return nil
                }
                leaves.append(leaf)
                index += 1
            }
            return leaves

        case .mergedChildren(let alternative):
            guard alternative == .Sum else {
                // `.Min`/`.Max` are neither a `Sum` nor a `Product`, and `.Product` never reaches here
                // -- `foldNegate` declines it, because this function has no way to say "cannot
                // derive" as distinct from "not numeric".
                return nil
            }
            let info = child.info()
            var origin: UInt32 = 0
            let terms = collectSumTerms(child, info.childCount, &origin, builder)
            if terms.declined != nil {
                // Unreachable: this same walk produced `.mergedChildren(.Sum)` without declining.
                // Checked rather than asserted, and answered with `nil` so the contract above stays
                // single-valued -- the caller then rebuilds the `Negate` and the child's own `rewrite`
                // declines the tree, which is a fallback to the C++ arm either way.
                return nil
            }
            let plan = sumMergePlan(terms.folds, builder)
            var leaves: [NumericLeaf] = []
            leaves.reserveCapacity(plan.slots.count)
            for k in 0..<plan.slots.count where plan.slots[k].survives {
                // `termFold` and not `terms.folds[k]`: a merged first instance's own fold is its value
                // BEFORE anything merged into it, and getting that backwards is silent.
                guard case .leaf(let leaf) = termFold(plan.slots, terms, k) else {
                    return nil
                }
                leaves.append(leaf)
            }
            return leaves

        case .leaf, .replacedByTerm, .replacedBySumTerm, .replacedByGrandchild, .rebuiltMinMax,
             .negatedChildren, .scaledSumChildren, .declined:
            // None of these left a `Sum`/`Product` in place, and each is refused by `foldNegate`
            // first. Enumerated rather than defaulted so a new `Fold` case is a compile error here too.
            return nil
        }
    }

    /// True when this `Product`'s final factor list is certain to contain a non-`Numeric` node --
    /// a witness, not a derivation: one own child that isn't numeric suffices, except a spliceable
    /// `Product` factor (step 9.1 replaces it with its own children, which can all be numeric), which
    /// is not a witness and is answered `false` rather than recursed into.
    func productHasNonNumericFactor(
        _ child: borrowing WebCore.CSSCalc.CSSCalcSwiftNode,
        _ builder: borrowing WebCore.CSSCalc.CSSCalcSwiftBuilder
    ) -> Bool {
        let info = child.info()
        var index: UInt32 = 0
        while index < info.childCount {
            let folded = fold(child.childInTreeOrder(index), builder)
            switch folded {
            case .leaf:
                // A `Numeric`: `isNumeric` is true for it, so it is not a witness.
                break

            case .unchanged(let alternative), .mergedChildren(let alternative):
                if alternative != .Product {
                    return true
                }
                // A spliceable `Product`. Not a witness -- see the note above.

            case .rebuiltMinMax:
                // A `Min` or a `Max`, which `isNumeric` refuses.
                return true

            case .replacedByTerm, .replacedBySumTerm, .replacedByGrandchild, .negatedChildren,
                 .scaledSumChildren, .declined:
                // Unreachable: `productFactors` returned `.mergedChildren(.Product)` for this node,
                // which means it accepted every child, and it accepts none of these. Answered `false`
                // rather than `true` so that a `Fold` case added later can only cost a decline, never
                // produce a `Negate` the C++ would not have rebuilt.
                return false
            }
            index += 1
        }
        return false
    }

    /// `simplify(Product&)` (`+Simplification.cpp:716`-`:908`), step 9, the largest body in the file.
    /// Five sub-steps: 9.1 splices a nested `Product`'s factors in, 9.2 folds every `<number>` factor
    /// into one, 9.3 is the distribution special case, 9.4 is the type walk (calling the real
    /// `Type::multiply`/`invert`/etc., not reimplementing them), 9.5 is "return root". `.mergedChildren`
    /// is reported unless no factor was spliced or folded, i.e. the list is unchanged.
    func foldProduct(
        _ node: borrowing WebCore.CSSCalc.CSSCalcSwiftNode,
        _ info: WebCore.CSSCalc.CSSCalcSwiftNodeInfo,
        _ builder: borrowing WebCore.CSSCalc.CSSCalcSwiftBuilder
    ) -> Fold {
        // 9.1 and 9.2, merged exactly as the C++ merges them.
        var origin: UInt32 = 0
        let factors = productFactors(node, info.childCount, &origin, builder)
        if let declined = factors.declined {
            return declined
        }

        var finalFactors = factors.survivors

        if let numericProduct = factors.numericProduct {
            // "If `numericProduct` has a value and `newChildren` is empty, that means all the
            // children were numbers and the product can be returned directly." (`:750`)
            if finalFactors.isEmpty {
                return .leaf(NumericLeaf.number(numericProduct))
            }

            // 9.3, extended by the C++ itself to `Numeric` and `Invert` factors as well as `Sum`
            // ones. The arity test is on the list BEFORE the merged number is appended, which is
            // what `:761`'s note means by "the last child is a singular `number` child".
            if finalFactors.count == 1, let replacement = distributeNumber(finalFactors[0], numericProduct) {
                return replacement
            }

            // "If there was more than one child or no replacement was found, append the product from
            // step 9.2 into the newChildren array." (`:798`) -- at the END, which is what makes the
            // list a reordering of the input rather than a copy of it.
            finalFactors.append(ProductFactor(
                fold: .leaf(NumericLeaf.number(numericProduct)),
                origin: Self.mergedNumberOrigin,
                invertedLeaf: nil,
                numericSum: false
            ))
        }

        // 9.4. `auto productResult = ProductResult { .value = 1, .type = Type { } };` and
        // `bool success = false;` (`:806`-`:810`) -- `success` starts FALSE and is overwritten by
        // each iteration, so an empty list falls through to 9.5 rather than folding to `1`.
        var productValue = 1.0
        var productType = CalcType()
        var success = false
        for factor in finalFactors {
            success = multiplyProductFactor(factor, &productValue, &productType)
            if !success {
                break
            }
        }

        if success, let resolvedCategory = productType.calculationCategory().value {
            switch resolvedCategory {
            case .Integer, .Number:
                // `:882`-`:884`. The two categories share one arm in the C++ too.
                return .leaf(NumericLeaf.number(productValue))

            case .Percentage:
                // `makeChild(Percentage { .value = ..., .hint = Type::determinePercentHint(
                // options.category) })` (`:885`-`:886`). The category is the options' one, not the
                // product's -- `resolvedCategory` is already known to be `Percentage` here, so
                // passing it would make this arm a constant and lose the whole point of the call.
                guard let optionsCategory = WebCore.CSS.Category(rawValue: category) else {
                    // Never taken: `init?(rawValue:)` on an imported C++ scoped enum is failable in
                    // its signature and non-validating in its body -- it accepts any value of the
                    // underlying type. The branch is kept because it is the spelling that produces a
                    // `CSS::Category` to pass, and it costs nothing; it is not a check against a
                    // boundary that came apart. What does contain an out-of-enum value here is
                    // `determinePercentHint`'s own `switch`, which falls through to `return { }`.
                    return .declined(nil)
                }
                return .leaf(NumericLeaf.percentage(productValue, CalcType.determinePercentHint(optionsCategory)))

            case .LengthPercentage:
                // `:887`-`:888`, a LITERAL `PercentHint::Length` in the C++ rather than a
                // `determinePercentHint` call. Reproduced literally.
                return .leaf(NumericLeaf.percentage(productValue, CalcType.PercentHintValue(.Length)))

            case .Length:
                // `:889`-`:890`. `toCSSUnit(Dimension::Length)` is `CSSUnitType::Px`
                // (CSSCalcTree.h:993), so naming the unit is naming the dimension.
                return .leaf(NumericLeaf.canonical(productValue, .Px))

            case .Angle:
                // `:891`-`:892`; `toCSSUnit(Dimension::Angle)` is `Deg` (CSSCalcTree.h:994).
                return .leaf(NumericLeaf.canonical(productValue, .Deg))

            case .AnglePercentage:
                // `:893`-`:894`, the other literal hint.
                return .leaf(NumericLeaf.percentage(productValue, CalcType.PercentHintValue(.Angle)))

            case .Time:
                // `:895`-`:896`; `toCSSUnit(Dimension::Time)` is `S` (CSSCalcTree.h:995).
                return .leaf(NumericLeaf.canonical(productValue, .S))

            case .Frequency:
                // `:897`-`:898`; `toCSSUnit(Dimension::Frequency)` is `Hz` (CSSCalcTree.h:996).
                return .leaf(NumericLeaf.canonical(productValue, .Hz))

            case .Resolution:
                // `:899`-`:900`; `toCSSUnit(Dimension::Resolution)` is `Dppx` (CSSCalcTree.h:997).
                return .leaf(NumericLeaf.canonical(productValue, .Dppx))

            case .Flex:
                // `:901`-`:902`; `toCSSUnit(Dimension::Flex)` is `Fr` (CSSCalcTree.h:998).
                return .leaf(NumericLeaf.canonical(productValue, .Fr))

            @unknown default:
                // A category C++ grew and this file has not been taught. The C++ `switch` is
                // exhaustive with no `default`, so growing the enum is a build failure THERE; here it
                // can only be a fall-through to 9.5, which is what an unhandled category would mean.
                break
            }
        }

        // 9.5. Return root.
        if factors.numericProduct == nil, !factors.spliced {
            return .unchanged(.Product)
        }
        return .mergedChildren(.Product)
    }

    /// Step 9.3's three arms (`+Simplification.cpp:763`-`:796`), for the single surviving factor.
    ///
    /// `nil` is not a decline: it means the caller appends the merged number and falls into 9.4
    /// instead, exactly as the C++ does at `:798`.
    @inline(always)
    func distributeNumber(_ factor: ProductFactor, _ numericProduct: Double) -> Fold? {
        switch factor.fold {
        case .leaf(let leaf):
            // `[&]<Numeric T>(T& numeric) { return makeChildWithValueBasedOn(numeric.value *
            // numericProduct->value, numeric); }` (`:765`-`:767`). `withValue` IS
            // `makeChildWithValueBasedOn`: same alternative, same unit, same percent hint. The
            // factor cannot be a `Number` -- 9.2 folded every one of those away -- so this is the
            // `Percentage`, `CanonicalDimension` and `NonCanonicalDimension` overloads.
            return .leaf(leaf.withValue(leaf.value * numericProduct))

        case .unchanged(let alternative), .mergedChildren(let alternative):
            if alternative == .Sum {
                // `[&](IndirectNode<Sum>& sum)` (`:768`-`:780`): all-numeric, then scale each child
                // and hand the SAME node back. `numericSum` is `all_of(sum->children, isNumeric)`
                // computed where the node was in hand; `nil` here is its `return { }`.
                guard factor.numericSum else {
                    return nil
                }
                return .scaledSumChildren(origin: factor.origin, factor: numericProduct)
            }
            if alternative == .Invert {
                // `[&](IndirectNode<Invert>& invert)` (`:781`-`:791`). The C++ switches on
                // `invert->a` and, for a `Numeric` one, returns `makeChildWithValueBasedOn(child.value
                // * numericProduct->value, child)` -- the child's own value scaled, with the `Invert`
                // dropped and not reciprocated. That is a defect in the C++ and is reproduced
                // verbatim rather than fixed.
                //
                // `invertedLeaf` is `invert->a` folded, captured where the node was in hand;
                // `nil` is the C++'s `[](const auto&)` arm.
                guard let inner = factor.invertedLeaf else {
                    return nil
                }
                return .leaf(inner.withValue(inner.value * numericProduct))
            }
            // `[](auto&) -> std::optional<Child> { return { }; }` (`:792`-`:794`).
            return nil

        case .rebuiltMinMax:
            // A `clamp()` that became a `min()` or a `max()`: a node, and not one of the three the
            // C++ names. The same `[](auto&)` arm.
            return nil

        case .replacedByTerm, .replacedBySumTerm, .replacedByGrandchild, .negatedChildren,
             .scaledSumChildren, .declined:
            // Unreachable: `productFactors` refuses every one of these, because for each of them this
            // file does not carry what the resulting subtree's alternative is and so cannot tell
            // which of 9.3's arms the C++ would take. Enumerated rather than defaulted so that a new
            // `Fold` case has to be classified here too, and answered `nil` -- which is the
            // conservative direction if the guard upstream ever stops holding, since it only skips a
            // replacement the caller then re-derives in 9.4.
            return nil
        }
    }

    /// One iteration of step 9.4's factor loop (`+Simplification.cpp:812`-`:877`): multiply this
    /// factor's type into `productType` and its value into `productValue`.
    ///
    /// The outer arms multiply the value; the inner (`Invert`) arms divide it and invert the type
    /// first. `<number>` is the identity type on both sides, so it never touches `productType`.
    @inline(always)
    func multiplyProductFactor(
        _ factor: ProductFactor,
        _ productValue: inout Double,
        _ productType: inout CalcType
    ) -> Bool {
        switch factor.fold {
        case .leaf(let leaf):
            switch leaf.kind {
            case .number:
                // "`<number>` is the identity type, so multiplying by it has no effect." (`:815`)
                productValue *= leaf.value
                return true

            case .percentage, .canonicalDimension:
                // `Type::multiply(productResult.type, getType(x))` (`:821`, `:831`). Two arms in the
                // C++ and two `getType` overloads behind `numericLeafType`, which dispatches on the
                // leaf's own kind -- one spelling here, two bodies there.
                guard let factorType = numericLeafType(leaf),
                      let multiplied = CalcType.multiply(productType, factorType).value else {
                    return false
                }
                productType = multiplied
                productValue *= leaf.value
                return true

            case .nonCanonicalDimension:
                // Not an arm of the C++ switch, so it reaches `[](const auto&) -> bool { return
                // false; }` (`:874`). A `NonCanonicalDimension` survives `canonicalize` only when
                // there is no conversion data, and step 9.4 declines to fold in that case rather
                // than guessing a canonical unit -- which is why this is `false` and not a call to
                // `determineType` on the non-canonical unit.
                return false
            }

        case .unchanged(let alternative), .mergedChildren(let alternative):
            guard alternative == .Invert, let inner = factor.invertedLeaf else {
                // Any other surviving node -- a `Sum`, a `Min`, a `Symbol`, a `Product` the splice
                // could not take -- is the outer `[](const auto&)` arm; and an `Invert` whose `a` is
                // not `Numeric` is the INNER one (`:868`-`:870`). Both are `false`.
                return false
            }
            switch inner.kind {
            case .number:
                // "`<number>` is the identity type, so multiplying / inverting by it has no effect."
                // (`:840`)
                productValue /= inner.value
                return true

            case .percentage, .canonicalDimension:
                // `Type::multiply(productResult.type, Type::invert(getType(x)))` (`:845`-`:851`,
                // `:856`-`:862`). Two statements in the C++ and two here, so the order of the two
                // calls is the C++'s.
                guard let factorType = numericLeafType(inner) else {
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
                // The inner `[](const auto&)` arm, for the same reason the outer one above gives.
                return false
            }

        case .rebuiltMinMax:
            // A converted `min()`/`max()` node: the outer `[](const auto&)` arm.
            return false

        case .replacedByTerm, .replacedBySumTerm, .replacedByGrandchild, .negatedChildren,
             .scaledSumChildren, .declined:
            // Unreachable, for the reason `distributeNumber` states: `productFactors` refuses all of
            // these. `false` is the conservative answer if that ever stops holding -- it only makes
            // the node keep its own kind, which is 9.5.
            return false
        }
    }

    /// Which `getType` overload a numeric leaf reaches -- a dispatcher over `NumericKind`, not one
    /// body shared by two alternatives: `getType(const Percentage&)` applies a conditional percent
    /// hint that `getType(const CanonicalDimension&)` has no analogue for, so collapsing the two into
    /// one call previously produced a wrong hint (`calc(10% * 1em / 1em)`; see `percentHintFromRawValue`).
    /// `nil` means step 9.4 stops folding and the node keeps its kind.
    @inline(always)
    func numericLeafType(_ leaf: NumericLeaf) -> CalcType? {
        switch leaf.kind {
        case .percentage:
            return percentageLeafType(leaf)

        case .canonicalDimension:
            return canonicalDimensionLeafType(leaf)

        case .number:
            // `getType(const Number&)` is `Type { }` (CSSCalcTree.cpp:346-:349) -- the identity type.
            // Unreachable: both call sites answer `<number>` before asking, because the C++'s two
            // `Number` arms do not touch `productResult.type` at all. Answered exactly rather than
            // declined, so that a future caller cannot be surprised by a `nil` that means nothing.
            return CalcType()

        case .nonCanonicalDimension:
            // NOT AN ARM OF STEP 9.4's SWITCH -- it reaches `[](const auto&) -> bool { return false; }`
            // (`+Simplification.cpp:871`, `:866`). Declined rather than answered with
            // `determineType(unit)`, because a `NonCanonicalDimension` survives only where there is no
            // conversion data and the C++ refuses to fold it rather than guessing a canonical unit.
            // Both call sites already refuse it; this is the same answer written where the dispatch
            // is, so the two cannot drift apart.
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
            return foldInvert(node, builder)

        case .Negate:
            return foldNegate(node, builder)

        case .Product:
            return foldProduct(node, info, builder)

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

        case .SiblingCount, .SiblingIndex:
            return foldSiblingFunction(node, alternative, builder)

        case .Random:
            return foldRandom(node, info, builder)

        case .CalcMix, .Anchor, .AnchorSize:
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

    /// `simplify(SiblingCount&)` and `simplify(SiblingIndex&)` (`+Simplification.cpp:527`-`:544`):
    /// resolve the tree-counting functions against the styled element. Both are leaves with nothing
    /// to recurse into; `resolveStyleCoupledValue` picks the right C++ method off the node's own tag.
    ///
    /// `resolved == false` is not a decline -- it means no conversion data/builder state/element, and
    /// the C++ copies the leaf through unchanged, which is `.unchanged` here. `sibling-count()` widens
    /// its integer result to a `Number` via `static_cast<double>`, as the C++ does.
    @inline(always)
    func foldSiblingFunction(
        _ node: borrowing WebCore.CSSCalc.CSSCalcSwiftNode,
        _ alternative: CalcAlternative,
        _ builder: borrowing WebCore.CSSCalc.CSSCalcSwiftBuilder
    ) -> Fold {
        let resolved = builder.resolveStyleCoupledValue(node)
        guard resolved.resolved else {
            return .unchanged(alternative)
        }
        return .leaf(NumericLeaf.number(resolved.value))
    }

    /// `simplify(Random&)` (`+Simplification.cpp:1350`-`:1402`): fold `random()` once its bounds are
    /// resolved numerics of one type and its `<random-key>` names a base value.
    ///
    /// The `<random-key>` is not a child; only `min`, `max` and the optional `step` are (tree indices
    /// 0, 1, 2). All present operands must be the same numeric alternative and unit
    /// (`switchTogether`/`unitsMatch`), checked against `max` and `step` separately (both anchored on
    /// `min`, matching the C++). `min` must also be `fullyResolved`, so a `NonCanonicalDimension`
    /// never folds here. The result is shaped like `min` (`NumericLeaf.withValue`), so a `random()`
    /// over percentages keeps `min`'s percent hint.
    @inline(always)
    func foldRandom(
        _ node: borrowing WebCore.CSSCalc.CSSCalcSwiftNode,
        _ info: WebCore.CSSCalc.CSSCalcSwiftNodeInfo,
        _ builder: borrowing WebCore.CSSCalc.CSSCalcSwiftBuilder
    ) -> Fold {
        let minimumFold = fold(node.childInTreeOrder(0), builder)
        guard case .leaf(let minimum) = minimumFold else {
            return foldFailed(minimumFold, .Random)
        }

        let maximumFold = fold(node.childInTreeOrder(1), builder)
        guard case .leaf(let maximum) = maximumFold else {
            return foldFailed(maximumFold, .Random)
        }
        guard switchTogether(minimum, maximum), unitsMatch(minimum, maximum), fullyResolved(minimum) else {
            return .unchanged(.Random)
        }

        // `root.step` is present exactly when there is a third child, as with `round()`'s second
        // argument and `log()`'s base.
        var step: Double? = nil
        if info.childCount > 2 {
            let stepChildFold = fold(node.childInTreeOrder(2), builder)
            guard case .leaf(let stepLeaf) = stepChildFold else {
                return foldFailed(stepChildFold, .Random)
            }
            guard switchTogether(minimum, stepLeaf), unitsMatch(minimum, stepLeaf) else {
                return .unchanged(.Random)
            }
            step = stepLeaf.value
        }

        // The `<random-key>`. `resolved == false` covers all three of the C++'s causes (no
        // conversion data/builder state, an unresolved element-scoped key, or a `Calc` fixed value) --
        // none of which is a decline; the C++ leaves the node in the tree and so does this.
        let baseValue = builder.resolveStyleCoupledValue(node)
        guard baseValue.resolved else {
            return .unchanged(.Random)
        }

        return .leaf(minimum.withValue(CalcExecutor.random(baseValue.value, minimum.value, maximum.value, step)))
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

        // `UInt8(exactly:)`, not `UInt8(_:)`, which traps: narrowing the boundary's `uint16_t` unit
        // back must be able to fail. `CSSUnitType(rawValue:)` beside it is not a real check, though --
        // an imported C++ scoped enum's `init?(rawValue:)` accepts any value of the underlying type --
        // so an out-of-enum value falls to `default` below, matching the C++'s `ASSERT_NOT_REACHED`
        // behavior in a shipping build.
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
        case .unchanged, .replacedByTerm, .replacedBySumTerm, .replacedByGrandchild,
             .rebuiltMinMax, .mergedChildren, .negatedChildren, .scaledSumChildren:
            return .replacedByTerm(child: index)
        }
    }

    /// `promoteTerm` for a node that collapses to its grandchild: `Negate(Negate(x))` and
    /// `Invert(Invert(x))`. The grandchild is folded here and folded again by `rewrite` -- can't be
    /// skipped, since (unlike `Negate`) `Invert`'s rule 7.1 doesn't fold every numeric alternative, so
    /// "the child didn't fold" doesn't imply "the grandchild isn't a leaf".
    @inline(always)
    func promoteGrandchild(
        _ node: borrowing WebCore.CSSCalc.CSSCalcSwiftNode,
        _ child: UInt32,
        _ grandchild: UInt32,
        _ builder: borrowing WebCore.CSSCalc.CSSCalcSwiftBuilder
    ) -> Fold {
        let inner = node.childInTreeOrder(child)
        switch fold(inner.childInTreeOrder(grandchild), builder) {
        case .leaf(let leaf):
            return .leaf(leaf)
        case .declined(let blame):
            return .declined(blame)
        case .unchanged, .replacedByTerm, .replacedBySumTerm, .replacedByGrandchild,
             .rebuiltMinMax, .mergedChildren, .negatedChildren, .scaledSumChildren:
            return .replacedByGrandchild(child: child, grandchild: grandchild)
        }
    }

    /// `promoteTerm` for a `Sum`, whose terms are addressed by origin ordinal rather than child index,
    /// since step 8.1 splices nested `Sum`s to any depth. See `Fold.replacedBySumTerm`.
    @inline(always)
    func promoteSumTerm(_ folded: Fold, _ origin: UInt32) -> Fold {
        switch folded {
        case .leaf(let leaf):
            return .leaf(leaf)
        case .declined(let blame):
            return .declined(blame)
        case .unchanged, .replacedByTerm, .replacedBySumTerm, .replacedByGrandchild,
             .rebuiltMinMax, .mergedChildren, .negatedChildren, .scaledSumChildren:
            return .replacedBySumTerm(origin: origin)
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
        /// `FirstInstance::merges` (`:602`), `Sum` only: how many later terms merged into this one.
        /// Carried on the shared slot (rather than a `Sum`-specific one) so `mergeTarget` has one
        /// definition.
        var merges: UInt32
        /// `FirstInstance::canRemove` (`:603`), `Sum` only: whether this zero-valued length may be
        /// dropped. Always false here -- `simplifyForMinMax` never drops a term.
        var canRemove: Bool
    }

    /// An empty slot: a term not yet classified. `survives` defaults to `true`, so a non-`Numeric`
    /// term survives by construction rather than by an arm remembering to say so.
    @inline(always)
    func unclassifiedSlot() -> MergeSlot {
        return MergeSlot(accumulated: nil, mergeable: false, survives: true, merges: 0, canRemove: false)
    }

    /// `offsetOfFirstInstance[toNumericIdentity(child)]`, as a scan: the earliest term of the same
    /// `(kind, unitType)` that `leaf` may merge into. Shared by `mergePlan` and `sumMergePlan`, which
    /// differ only in what they do with the answer.
    ///
    /// Returns the accumulated leaf along with the index, rather than making the caller re-read it --
    /// avoiding a fall-through where a `nil` leaf could silently look like a new first instance.
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

            // Percentage merges are skipped when disallowed; the table entry is left unset so the
            // child survives, but its leaf is still recorded for phase 3. `simplify(Sum&)` has no such
            // skip -- see `sumMergePlan`, which is why the two plans are separate functions.
            if leaf.kind == .percentage, !canMergePercentages {
                slots[i].accumulated = leaf
                continue
            }

            if let target = mergeTarget(slots, i, leaf) {
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

    // MARK: `Sum`

    /// `simplify(Sum&)` (`+Simplification.cpp:547`-`:714`), css-values-4 steps 8.1 to 8.4.
    ///
    /// Step 8.1 splices any child `Sum` into this node's term list first, so terms can sit at any
    /// depth; `collectSumTerms`/`pushSumTerm` address a term by tree-position ordinal rather than
    /// child/grandchild index. `isSpliceableSum` tests the child's simplified `Fold`, not the input,
    /// since a child `Sum` that folded to a leaf is no longer spliceable.
    ///
    /// Five size outcomes, in C++ order (`:652`-`:711`): no removals -> `nullopt`; exactly one
    /// survivor after merges (not after removals) -> that child, `:656` -- `calc(0px + 0px)` under
    /// the removal flag keeps its survivor rather than collapsing further; zero survivors -> a
    /// canonical zero length; one survivor after removals -> a scan for it; otherwise rebuild from
    /// the survivors.
    ///
    /// A `Sum` that spliced but merged nothing is not `.unchanged`: `nullopt` means "keeps its
    /// kind", but `root.children` was already replaced by the flattened term list, so it needs
    /// `.mergedChildren(.Sum)`. The arity-one check (`:594`) is on the flattened count.
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

        // Term 0 is always the sole merge-survivor here (same proof as `foldMinMax`), so no search is
        // needed. Its `canRemove` bit is not consulted -- removals aren't applied yet at this test.
        if terms.folds.count - plan.merges == 1 {
            return promoteSumTerm(termFold(plan.slots, terms, 0), terms.origins[0])
        }

        let combined = terms.folds.count - plan.removeTotal

        // A `length` zero is returned because only a `length` node can be removed.
        if combined == 0 {
            return .leaf(NumericLeaf.canonicalLength(0))
        }

        // The C++'s scan condition (non-`Numeric`, or a first instance with `!canRemove`) is exactly
        // `survives`.
        if combined == 1 {
            for k in 0..<plan.slots.count where plan.slots[k].survives {
                return promoteSumTerm(termFold(plan.slots, terms, k), terms.origins[k])
            }
            // Cannot happen per the arithmetic above; if it did, `rebuildFrom` with zero operands is
            // refused and the tree declines, safer than the C++'s empty `Sum`.
        }

        // 5. `root.children = WTF::move(combinedChildren); return { };`
        return .mergedChildren(.Sum)
    }

    /// A term's own result once the merge has run: the accumulated leaf for a `Numeric` term, else
    /// the term's own fold. A function rather than an inline expression, since getting it backwards
    /// (reading the pre-merge leaf) is silent.
    @inline(always)
    func termFold(_ slots: [MergeSlot], _ terms: SumTermList, _ index: Int) -> Fold {
        if let accumulated = slots[index].accumulated {
            return .leaf(accumulated)
        }
        return terms.folds[index]
    }

    /// Whether step 8.1 splices this child's terms into the parent instead of taking it as one term:
    /// true exactly when the simplified child is still a `Sum`, i.e. `.unchanged(.Sum)` or
    /// `.mergedChildren(.Sum)`. Checked by alternative rather than assumed, since several other folds
    /// also produce those two cases.
    @inline(always)
    func isSpliceableSum(_ folded: Fold) -> Bool {
        switch folded {
        case .unchanged(let alternative), .mergedChildren(let alternative):
            return alternative == .Sum
        case .leaf, .replacedByTerm, .replacedBySumTerm, .replacedByGrandchild, .rebuiltMinMax,
             .negatedChildren, .scaledSumChildren, .declined:
            // `.negatedChildren` and `.scaledSumChildren` don't splice either: their child's children
            // are about to be rewritten by `rewrite`, and splicing would take the untransformed
            // subtree instead, dropping the negation/scale. Enumerated rather than defaulted since a
            // new case here needs a value, not a decline.
            return false
        }
    }

    /// The `Product` analogue of `isSpliceableSum`: whether step 9.1 replaces this child with its own
    /// factors instead of taking it as one factor.
    ///
    /// True for `.mergedChildren(.Product)` (step 9.1 spliced or 9.2 folded a `<number>`) as well as
    /// `.unchanged(.Product)`.
    @inline(always)
    func isSpliceableProduct(_ folded: Fold) -> Bool {
        switch folded {
        case .unchanged(let alternative), .mergedChildren(let alternative):
            return alternative == .Product
        case .leaf, .replacedByTerm, .replacedBySumTerm, .replacedByGrandchild, .rebuiltMinMax,
             .negatedChildren, .scaledSumChildren, .declined:
            return false
        }
    }

    /// One `Sum`'s flattened term list, as values -- no node handle, since `CSSCalcSwiftNode` is
    /// `~Escapable` and no Swift container accepts one. Everything here is `Copyable`/`Escapable`, so
    /// the list can be freely returned and walked.
    struct SumTermList {
        /// One entry per term of the flattened list, in order.
        var folds: [Fold] = []
        /// The tree-position ordinal each term came from. See `Fold.replacedBySumTerm`.
        var origins: [UInt32] = []
        /// The first child that declined, as the `Fold` to return -- same shape as `declinedChild`.
        var declined: Fold?
    }

    /// Step 8.1: `node`'s children in tree order, with every child that is still a `Sum` replaced by
    /// its own post-merge terms. Recurses only through that splice chain, not through `fold`'s own
    /// recursion, re-deriving each spliced child's flattened list rather than assuming a fixed depth.
    ///
    /// `origin` threads through the whole recursion so one ordinal names a term at any depth. Cost is
    /// exponential in nested-`Sum` depth in theory, but `parseAndSimplify` flattens nested sums during
    /// the parse, so no stylesheet-derived tree nests here in practice.
    func collectSumTerms(
        _ node: borrowing WebCore.CSSCalc.CSSCalcSwiftNode,
        _ childCount: UInt32,
        _ origin: inout UInt32,
        _ builder: borrowing WebCore.CSSCalc.CSSCalcSwiftBuilder
    ) -> SumTermList {
        var out = SumTermList()
        // `Int(clamping:)`, not `Int(_:)`, which traps where `Int` is narrower than `UInt32`.
        out.folds.reserveCapacity(Int(clamping: childCount))
        out.origins.reserveCapacity(Int(clamping: childCount))

        var index: UInt32 = 0
        while index < childCount {
            let child = node.childInTreeOrder(index)
            let folded = fold(child, builder)
            if case .declined = folded {
                // Checked here, not by a sweep afterwards: a declined grandchild must stop the walk
                // before the parent's plan is computed over a list missing terms.
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

    /// `isLength(id) && options.allowZeroValueLengthRemovalFromSum` (`:611`). `.number`/`.percentage`
    /// never qualify; `.canonicalDimension` qualifies only for `Px`; `.nonCanonicalDimension` (48 of 56
    /// units) crosses to `isLengthUnit`. The flag is tested first so the upcall is skipped when it
    /// cannot be used, and the caller only reaches it for a merged value of exactly zero.
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

    /// Steps 8.2 to 8.4's first phase (`:607`-`:649`): `simplifyForMinMax`'s `mergePlan`, but with a
    /// per-bucket `{offset, merges, canRemove}` record (outcomes need the removal count separately),
    /// `canRemove` recomputed from the merged value on every merge rather than accumulated, and no
    /// percentage skip (`Sum` merges percentages unconditionally, unlike `Min`/`Max`).
    ///
    /// Accumulation runs in term index order because `+` is not associative:
    /// `calc(1e300px + 1px + -1e300px)` depends on it.
    func sumMergePlan(
        _ folded: [Fold],
        _ builder: borrowing WebCore.CSSCalc.CSSCalcSwiftBuilder
    ) -> (slots: [MergeSlot], merges: Int, removeTotal: Int) {
        var slots = [MergeSlot](repeating: unclassifiedSlot(), count: folded.count)

        for i in 0..<folded.count {
            // `[](const auto&) { }` (`:635`): a non-`Numeric` term is never eligible for merge or
            // removal, so it always survives.
            guard case .leaf(let leaf) = folded[i] else {
                continue
            }

            if let target = mergeTarget(slots, i, leaf) {
                let merged = CalcExecutor.sum(target.accumulated.value, leaf.value)
                slots[target.index].accumulated = target.accumulated.withValue(merged)
                slots[target.index].merges += 1
                // `firstInstance.canRemove = canRemoveIfZero && !mergedValue;` (`:624`), spelled as
                // `if`/`else` rather than `&&` because `&&`'s autoclosure right operand cannot capture
                // a `borrowing` parameter. This is an assignment, not an accumulation: a slot made
                // removable by an earlier merge must be cleared when a later merge lands non-zero.
                if merged == 0 {
                    slots[target.index].canRemove = lengthRemovalAllowed(leaf, builder)
                } else {
                    slots[target.index].canRemove = false
                }
                slots[i].survives = false
            } else {
                // `firstInstances[id] = { .offset = i + 1, .merges = 0, .canRemove = canRemoveIfZero
                // && !child.value }` (`:629`-`:633`).
                slots[i].accumulated = leaf
                slots[i].mergeable = true
                // `&&` would capture `builder` in an autoclosure; see the merge arm above.
                if leaf.value == 0 {
                    slots[i].canRemove = lengthRemovalAllowed(leaf, builder)
                }
            }
        }

        // `for (auto& firstInstance : firstInstances) if (firstInstance.offset) { ... }` (`:644`-`:649`),
        // over buckets (`mergeable`), not terms.
        var merges = 0
        var removeTotal = 0
        for i in 0..<slots.count where slots[i].mergeable {
            merges += Int(slots[i].merges)
            removeTotal += Int(slots[i].merges) + (slots[i].canRemove ? 1 : 0)
            if slots[i].canRemove {
                // The rebuild's own condition, `(firstInstance.offset - 1) == i && !canRemove`
                // (`:699`), folded into the slot so every site asks it the same way.
                slots[i].survives = false
            }
        }

        return (slots, merges, removeTotal)
    }

    // MARK: `Product`'s flattened factor list

    /// One surviving factor of a `Product`, as values -- `CSSCalcSwiftNode` is `~Escapable`, so no
    /// Swift container can hold the node itself. Carries two answers steps 9.3 and 9.4 need but a bare
    /// `Fold` cannot give: whether a `Sum` factor's children are all numeric, and what an `Invert`
    /// factor's `a` folded to. Computed once here rather than by a re-walk per question.
    struct ProductFactor {
        /// What the factor's own subtree folded to.
        let fold: Fold
        /// The ordinal of the tree position it came from. `mergedNumberOrigin` for the synthesised
        /// `<number>` step 9.2 appends, since that one is never addressed by ordinal.
        let origin: UInt32
        /// For a factor that survived as an `Invert`, what its `a` folded to when that is `Numeric`;
        /// `nil` otherwise (`:790`, `:868`).
        let invertedLeaf: NumericLeaf?
        /// For a factor that survived as a `Sum`, `all_of(sum->children, isNumeric)` (`:769`) over
        /// its post-simplification children; `false` for every other alternative. Computed eagerly
        /// even though only step 9.3 reads it -- the lazy form would need a full re-walk.
        let numericSum: Bool
    }

    /// The result of steps 9.1 and 9.2 over one `Product`: its factors flattened through every
    /// nested `Product`, with every `<number>` among them folded into a single value.
    struct ProductFactorList {
        /// The non-`<number>` factors, in order. This is the C++'s `newChildren` BEFORE `:798`
        /// appends the merged number, which is the list 9.3's arity test is about.
        var survivors: [ProductFactor] = []
        /// `std::optional<Number> numericProduct` (`:730`): the product of every `<number>` factor,
        /// accumulated in walk order. `nil` when there were none.
        var numericProduct: Double?
        /// Whether step 9.1 replaced any child with its own factors, at any depth. Read only by
        /// 9.5, to tell `.unchanged(.Product)` from `.mergedChildren(.Product)`.
        var spliced = false
        /// The first child that declined, as the `Fold` to return. Same shape and same reason as
        /// `SumTermList.declined`.
        var declined: Fold?
    }

    /// The `origin` of the `<number>` step 9.2 synthesises: `UInt32.max`, since that factor exists
    /// nowhere in the input tree and is never addressed by ordinal.
    static var mergedNumberOrigin: UInt32 { return UInt32.max }

    /// Steps 9.1 and 9.2 (`+Simplification.cpp:729`-`:748`), as one pass. Recurses only through the
    /// splice chain, like `collectSumTerms`, re-deriving each spliced child's already-flattened list;
    /// a nested `Product` contributes its survivors plus one merged number (`n_parent = n_child *
    /// n_parent_before`, in that order, since `*` is not associative on doubles).
    ///
    /// Every unclassifiable factor declines the whole tree here rather than at 9.3/9.4: a factor whose
    /// alternative this file does not carry cannot be treated as opaque, since 9.1/9.3/9.4 all branch
    /// on it. See `classifyProductFactor`.
    func productFactors(
        _ node: borrowing WebCore.CSSCalc.CSSCalcSwiftNode,
        _ childCount: UInt32,
        _ origin: inout UInt32,
        _ builder: borrowing WebCore.CSSCalc.CSSCalcSwiftBuilder
    ) -> ProductFactorList {
        var out = ProductFactorList()
        // `Int(clamping:)` for the capacity HINT, as `collectSumTerms` explains: saturating cannot be
        // wrong, because `append` grows regardless.
        out.survivors.reserveCapacity(Int(clamping: childCount))

        var index: UInt32 = 0
        while index < childCount {
            let child = node.childInTreeOrder(index)
            let folded = fold(child, builder)
            if case .declined = folded {
                out.declined = folded
                return out
            }

            if isSpliceableProduct(folded) {
                // 9.1. `for (auto& childProductChild : (*childProduct)->children) processChild(...)`.
                out.spliced = true
                let childInfo = child.info()
                let spliced = productFactors(child, childInfo.childCount, &origin, builder)
                if let declined = spliced.declined {
                    out.declined = declined
                    return out
                }
                out.survivors.append(contentsOf: spliced.survivors)
                if let childProduct = spliced.numericProduct {
                    out.numericProduct = multipliedNumericProduct(childProduct, out.numericProduct)
                }
            } else if case .leaf(let leaf) = folded, leaf.kind == .number {
                // 9.2 (`:733`-`:737`).
                out.numericProduct = multipliedNumericProduct(leaf.value, out.numericProduct)
                origin += 1
            } else if let factor = classifyProductFactor(child, folded, origin, builder) {
                // `newChildren.append(WTF::move(child))` (`:739`).
                out.survivors.append(factor)
                origin += 1
            } else {
                out.declined = .declined(.Product)
                return out
            }
            index += 1
        }
        return out
    }

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

    /// Turn one surviving factor's `Fold` into a `ProductFactor`, answering the two node-dependent
    /// questions steps 9.3 and 9.4 ask -- or `nil` (a decline, not "opaque") for the five `Fold` cases
    /// whose alternative this file does not carry.
    ///
    /// The `Invert` probe re-folds the grandchild `foldInvert` already folded, trading a repeat fold
    /// for avoiding a whole ordinal re-walk per `Invert` factor.
    func classifyProductFactor(
        _ child: borrowing WebCore.CSSCalc.CSSCalcSwiftNode,
        _ folded: Fold,
        _ origin: UInt32,
        _ builder: borrowing WebCore.CSSCalc.CSSCalcSwiftBuilder
    ) -> ProductFactor? {
        switch folded {
        case .leaf:
            // A `Numeric` that is not a `Number` -- 9.2 took those. Both questions are `Invert`'s and
            // `Sum`'s, so neither applies.
            return ProductFactor(fold: folded, origin: origin, invertedLeaf: nil, numericSum: false)

        case .unchanged(let alternative), .mergedChildren(let alternative):
            if alternative == .Invert {
                // `invert->a`, folded: an `Invert` surviving as `Invert` means `a` is a
                // `Percentage`, `CanonicalDimension`, `NonCanonicalDimension`, or non-`Numeric`.
                let inner = fold(child.childInTreeOrder(0), builder)
                if case .leaf(let leaf) = inner {
                    return ProductFactor(fold: folded, origin: origin, invertedLeaf: leaf, numericSum: false)
                }
                return ProductFactor(fold: folded, origin: origin, invertedLeaf: nil, numericSum: false)
            }
            if alternative == .Sum {
                // `std::ranges::all_of(sum->children, isNumeric)` (`:769`) over the child's final,
                // post-splice list -- see `numericChildren`.
                return ProductFactor(
                    fold: folded,
                    origin: origin,
                    invertedLeaf: nil,
                    numericSum: numericChildren(child, folded, builder) != nil
                )
            }
            // Any other surviving node: opaque to 9.3 and 9.4, which both have a catch-all arm for it.
            return ProductFactor(fold: folded, origin: origin, invertedLeaf: nil, numericSum: false)

        case .rebuiltMinMax:
            // A `clamp()` that became a `min()`/`max()`: a known node kind, but 9.1/9.3/9.4 have no
            // arm for it, so it is opaque rather than a decline.
            return ProductFactor(fold: folded, origin: origin, invertedLeaf: nil, numericSum: false)

        case .replacedByTerm, .replacedBySumTerm, .replacedByGrandchild:
            // The factor collapsed to a subtree of itself whose alternative this file does not
            // carry, so 9.1/9.3/9.4 cannot classify it; declining is exact since the C++ arm then
            // applies whatever rule the tree needs. Unreachable from a parse -- `parseAndSimplify`
            // simplifies incrementally, so the collapse already happened before the enclosing
            // `Product` was built -- only from a constructed tree.
            return nil

        case .negatedChildren, .scaledSumChildren:
            // Treating these as opaque would be wrong, not just imprecise: both leave a node whose
            // children are about to be rewritten, and for `.negatedChildren` that node may be a
            // `Product`, so skipping it would miss step 9.1's splice. Unreachable from a parse for the
            // same reason as the case above.
            return nil

        case .declined:
            // Handled by the caller before this is reached; answered `nil` rather than trapped so
            // that the contract is single-valued.
            return nil
        }
    }
}

// MARK: - Building the answer

private extension CalcSimplification {

    /// Push exactly one operand for this subtree, or decline. On `.pushed` the operand stack has
    /// grown by exactly one; on `.declined` the caller must abandon the tree without inspecting the
    /// stack. Dispatches on `fold`'s answer: a numeric leaf pushes directly with no children built; a
    /// collapse (to a child, a `Sum` term, a `min()`/`max()` conversion, or a grandchild) pushes one
    /// operand for the replacement; merged `Sum`/`Product`/`Min`/`Max` children push their survivors
    /// and `rebuildFrom` with the new count; everything else rewrites each child then rebuilds.
    ///
    /// Unlike the coverage walk, this stops at the first decline -- there is nothing left to learn,
    /// and the walk's mask/count already describe the whole tree.
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

        case .replacedBySumTerm(let origin):
            // The same thing for a `Sum`, whose terms are not its children: step 8.1 spliced them in
            // from any depth, so the answer is addressed by ordinal and resolved by re-walking.
            return rewriteSumTerm(node, origin, &builder)

        case .rebuiltMinMax(let isMax):
            return rewriteConvertedMinMax(node, isMax, &builder)

        case .mergedChildren(let alternative):
            // `Sum` and `Product` each have their own pass because their survivors are terms of a
            // flattened list, not children of the node; `Min`/`Max` survivors are children.
            if alternative == .Sum {
                return rewriteSumChildren(node, &builder)
            }
            if alternative == .Product {
                return rewriteProductChildren(node, &builder)
            }
            return rewriteMergedChildren(node, alternative, &builder)

        case .replacedByGrandchild(let child, let grandchild):
            // `Negate`'s rule 6.2 and `Invert`'s rule 7.2: `return { WTF::move(a->a) }`, one level
            // deeper than `.replacedByTerm`. The intermediate `let` is required: `childInTreeOrder`
            // returns a `~Escapable` view, and chaining two in one expression has nothing to borrow
            // from.
            let inner = node.childInTreeOrder(child)
            return rewrite(inner.childInTreeOrder(grandchild), &builder)

        case .negatedChildren:
            return rewriteNegatedChildren(node, &builder)

        case .scaledSumChildren(let origin, let factor):
            // `Product`'s step 9.3 `Sum` arm: the answer is that `Sum` with every child scaled.
            return rewriteScaledSumFactor(node, origin, factor, &builder)

        case .unchanged(let alternative):
            return rebuild(node, alternative, &builder)
        }
    }

    /// The `.negatedChildren` half of `rewrite`: `Negate`'s rules 6.3 and 6.4. `rebuildFrom` runs on
    /// the child, not the `Negate` (`+Simplification.cpp:939`, `:954`), so the `Negate` disappears and
    /// contributes only the sign. Every child is pushed as a leaf, never re-rewritten, since
    /// `numericChildren` guarantees every final child is numeric.
    ///
    /// The unary minus (`:934`, `:949`: `child.value = -child.value`) flips a NaN's sign bit rather
    /// than propagating it -- not the same as `* -1.0`; see `Fold.scaledSumChildren`.
    mutating func rewriteNegatedChildren(
        _ node: borrowing WebCore.CSSCalc.CSSCalcSwiftNode,
        _ builder: inout WebCore.CSSCalc.CSSCalcSwiftBuilder
    ) -> Rewrite {
        let child = node.childInTreeOrder(0)
        guard let leaves = numericChildren(child, fold(child, builder), builder) else {
            // Unreachable: `fold` returned `.negatedChildren`, which it does only after this same call
            // returned a list. Checked rather than asserted, so that a boundary that came apart is a
            // fallback to the C++ arm and not a node rebuilt from operands that were never pushed.
            return .declined(.Negate)
        }

        // Counted alongside the loop rather than narrowed from `leaves.count`: `rebuildFrom` wants a
        // `UInt32`, and this is the number actually pushed.
        var pushed: UInt32 = 0
        for leaf in leaves {
            guard builder.pushLeaf(leaf.withValue(-leaf.value).boundaryLeaf) else {
                // A contract violation, as in `rewrite`'s `.leaf` arm: the leaf was synthesised here,
                // so there is no input alternative to blame.
                return .declined(nil)
            }
            pushed += 1
        }

        // `rebuildSlot(const Children&)` takes all remaining operands and ignores the original's
        // count, which is what lets the arity change.
        return builder.rebuildFrom(child, pushed) ? .pushed : .declined(.Negate)
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

    /// The `.mergedChildren(.Sum)` half of `rewrite`: step 8.1 and its consuming loop (`:689`-`:711`).
    /// Separate from `rewriteMergedChildren` because a `Sum`'s survivors are not its children -- step
    /// 8.1 flattened the list, so a survivor can be a grandchild or deeper, reached through
    /// `pushSumTerm`'s ordinal re-walk.
    ///
    /// The count can go up as well as down: `calc(1px + (1em + 1%))` arrives with two children and
    /// rebuilds with three. `rebuildSlot` takes all remaining operands regardless of direction.
    mutating func rewriteSumChildren(
        _ node: borrowing WebCore.CSSCalc.CSSCalcSwiftNode,
        _ builder: inout WebCore.CSSCalc.CSSCalcSwiftBuilder
    ) -> Rewrite {
        let info = node.info()
        var origin: UInt32 = 0
        let terms = collectSumTerms(node, info.childCount, &origin, builder)
        if case .declined(let blame) = terms.declined {
            // Unreachable in practice; checked rather than asserted so a broken boundary falls back
            // to the C++ arm.
            return .declined(blame)
        }
        let plan = sumMergePlan(terms.folds, builder)

        var survivors: UInt32 = 0
        for k in 0..<plan.slots.count where plan.slots[k].survives {
            if let accumulated = plan.slots[k].accumulated {
                // A `Numeric` survivor is pushed as a leaf, required for the same reason as
                // `rewriteMergedChildren`: its value may have been accumulated by a nested `Sum`'s
                // own pass and exists nowhere in the input tree.
                guard builder.pushLeaf(accumulated.boundaryLeaf) else {
                    return .declined(nil)
                }
            } else {
                var counter: UInt32 = 0
                guard let pushed = pushSumTerm(node, info.childCount, terms.origins[k], &counter, &builder) else {
                    // Would mean the two walks disagreed on ordinals. A decline rather than a trap:
                    // the C++ arm then runs and the mismatch is a visible finding, not a crash.
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
    /// This is the mirror of `collectSumTerms` and has to stay one: both walk `node`'s children in tree
    /// order, both call `fold` on each, and both test `isSpliceableSum` on the answer -- so both visit
    /// the same positions in the same order and assign the same ordinals. `collectSumTerms` numbers the
    /// non-spliceable ones; this counts them and stops at `target`.
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

    /// The `.mergedChildren(.Product)` half of `rewrite`: pushes steps 9.1/9.2's replacement of
    /// `root.children` as the single consuming pass. A `Product`'s factors are neither its children
    /// (9.1 splices from any depth) nor a merge plan (9.2's folded `<number>` exists nowhere in the
    /// input). The merged number is appended last, matching the C++'s order, not the input's --
    /// `Product{2, x}` rebuilds as `Product{x, 2}`. A `.leaf` factor is pushed as a leaf rather than
    /// re-rewritten, since it may already have been folded by a nested `Product`'s own pass.
    mutating func rewriteProductChildren(
        _ node: borrowing WebCore.CSSCalc.CSSCalcSwiftNode,
        _ builder: inout WebCore.CSSCalc.CSSCalcSwiftBuilder
    ) -> Rewrite {
        let info = node.info()
        var origin: UInt32 = 0
        let factors = productFactors(node, info.childCount, &origin, builder)
        if case .declined(let blame) = factors.declined {
            // Unreachable: `fold` returned `.mergedChildren(.Product)`, which it does only after this
            // same walk found no declining factor. Checked rather than asserted, so that a boundary
            // that came apart is a fallback to the C++ arm rather than a tree built from a short
            // factor list.
            return .declined(blame)
        }

        var pushedFactors: UInt32 = 0
        for factor in factors.survivors {
            if case .leaf(let leaf) = factor.fold {
                guard builder.pushLeaf(leaf.boundaryLeaf) else {
                    return .declined(nil)
                }
            } else {
                var counter: UInt32 = 0
                guard let resolved = pushProductFactor(node, info.childCount, factor.origin, nil, &counter, &builder) else {
                    // The ordinal named a position the re-walk did not reach, which can only mean the
                    // two walks disagreed. A decline rather than a trap, exactly as
                    // `rewriteSumChildren` argues.
                    return .declined(.Product)
                }
                if case .declined(let blame) = resolved {
                    return .declined(blame)
                }
            }
            pushedFactors += 1
        }

        if let numericProduct = factors.numericProduct {
            // `newChildren.append(makeChild(*numericProduct))` (`:798`). Reached only when 9.3 found
            // no replacement, which is what `fold` decided; the two agree because both re-derive the
            // same list from the same walk.
            guard builder.pushLeaf(NumericLeaf.number(numericProduct).boundaryLeaf) else {
                return .declined(nil)
            }
            pushedFactors += 1
        }

        // `rebuildSlot(const Children&)` takes ALL the remaining operands and ignores the original's
        // own count, which is the line that lets the arity change in either direction.
        return builder.rebuildFrom(node, pushedFactors) ? .pushed : .declined(.Product)
    }

    /// The `.scaledSumChildren` half of `rewrite`: `Product`'s step 9.3 `Sum` arm
    /// (`+Simplification.cpp:768`-`:780`) as the single consuming pass.
    ///
    /// The whole `Product` disappears and the answer is the `Sum`, exactly as `.replacedByTerm`'s
    /// node disappears -- so one operand is pushed for the entire subtree, and `rebuildFrom` is
    /// called ON THE `Sum`, which is what rewrapping the C++'s `IndirectNode` does.
    mutating func rewriteScaledSumFactor(
        _ node: borrowing WebCore.CSSCalc.CSSCalcSwiftNode,
        _ origin: UInt32,
        _ factor: Double,
        _ builder: inout WebCore.CSSCalc.CSSCalcSwiftBuilder
    ) -> Rewrite {
        let info = node.info()
        var counter: UInt32 = 0
        guard let resolved = pushProductFactor(node, info.childCount, origin, factor, &counter, &builder) else {
            return .declined(.Product)
        }
        return resolved
    }

    /// Resolve a factor's origin ordinal back to the tree position it names, and either rewrite that
    /// subtree or push it as a scaled `Sum`. Mirrors `productFactors`' walk exactly (same order, same
    /// ordinals), so the two agree without either knowing which factors survived. `scale` carries both
    /// jobs in one walk: `nil` pushes the surviving factor, a value scales a `Sum` child by it.
    mutating func pushProductFactor(
        _ node: borrowing WebCore.CSSCalc.CSSCalcSwiftNode,
        _ childCount: UInt32,
        _ target: UInt32,
        _ scale: Double?,
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
            if isSpliceableProduct(folded) {
                let childInfo = child.info()
                if let found = pushProductFactor(child, childInfo.childCount, target, scale, &counter, &builder) {
                    return found
                }
            } else {
                if counter == target {
                    guard let scale else {
                        // `rewrite` on the factor pushes exactly one operand, which is what the
                        // rebuilt `Product` owes for this slot.
                        return rewrite(child, &builder)
                    }
                    return pushScaledSum(child, folded, scale, &builder)
                }
                counter += 1
            }
            index += 1
        }
        return nil
    }

    /// `for (auto& child : sum->children) child.value *= numericProduct->value;` and
    /// `return { Child { WTF::move(sum) } };` (`+Simplification.cpp:771`-`:779`).
    ///
    /// `rebuildFrom` is called on the `Sum`, not on the `Product`, which is the whole rewrite: the
    /// C++ hands the `Sum`'s own `IndirectNode` back and the `Product` contributes only the factor.
    ///
    /// A `*=`, not a negation-shaped transform: `Fold.scaledSumChildren` records why this is not
    /// shared with `rewriteNegatedChildren` -- `-x` and `x * -1.0` are free to differ in the sign
    /// bit of a NaN, so `:773`'s `*=` is reproduced as a `*` and `:934`'s unary minus as a unary
    /// minus.
    ///
    /// Every child is a leaf whenever this runs, by `numericChildren`'s own guard -- which is what
    /// lets this be a straight push loop with no `pushSumTerm` for a non-`Numeric` survivor.
    mutating func pushScaledSum(
        _ sum: borrowing WebCore.CSSCalc.CSSCalcSwiftNode,
        _ folded: Fold,
        _ scale: Double,
        _ builder: inout WebCore.CSSCalc.CSSCalcSwiftBuilder
    ) -> Rewrite {
        guard let leaves = numericChildren(sum, folded, builder) else {
            // Unreachable: `fold` produced `.scaledSumChildren` only after this same call returned a
            // list. Checked rather than asserted, for the reason `rewriteNegatedChildren` gives.
            return .declined(.Product)
        }

        var pushedChildren: UInt32 = 0
        for leaf in leaves {
            guard builder.pushLeaf(leaf.withValue(leaf.value * scale).boundaryLeaf) else {
                // A contract violation: the leaf was synthesised here, so there is no input
                // alternative to blame.
                return .declined(nil)
            }
            pushedChildren += 1
        }

        return builder.rebuildFrom(sum, pushedChildren) ? .pushed : .declined(.Product)
    }

    /// The `.unchanged` half of `rewrite`: the node keeps its own alternative and is rebuilt from
    /// its simplified children.
    ///
    /// The three leaves that reach here are copied, not rebuilt: an unresolved `Symbol`, and
    /// `SiblingCount`/`SiblingIndex` with no live builder state or no element -- the leaves whose
    /// `simplify` overload can return `std::nullopt`. The four numeric leaves never reach here:
    /// `fold` answers `.leaf` for them and `rewrite` pushes that through `pushLeaf`.
    ///
    /// Not `@inline(always)`: `rebuild` and `rewrite` are mutually recursive, so the optimizer would
    /// decline it anyway.
    mutating func rebuild(
        _ node: borrowing WebCore.CSSCalc.CSSCalcSwiftNode,
        _ alternative: CalcAlternative,
        _ builder: inout WebCore.CSSCalc.CSSCalcSwiftBuilder
    ) -> Rewrite {
        let info = node.info()

        if isCopiedLeafAlternative(alternative) {
            // An unresolved `<calc-keyword>`, or a tree-counting function with nothing to resolve
            // against. A leaf, so `rebuildFrom` would refuse it -- there are no slots to fill -- and
            // a deep copy is what `copyAndSimplify` does for it.
            //
            // `pushCopyOf` is exact here, not merely conservative: with `simplify` returning
            // `std::nullopt`, `copyAndSimplify(const Child&)` (`:1808`-`:1822`) ends at
            // `makeChild(WTF::move(simplified), getType(root))`, and for a `Leaf Op`,
            // `copyAndSimplifyChildren` (`:1785`-`:1788`) is `return op;` with the type unread --
            // `makeChild` for a `Leaf` is `ChildConstruction<T>::make(T&&, Type)`, which discards the
            // `Type` and yields `Child { WTF::move(op) }` (CSSCalcTree.h:916-:919). `pushCopyOf`
            // routes to `CSSCalc::copy(const Child&)`, whose `Leaf` overload is `return { root };`
            // (CSSCalcTree+Copy.cpp:95-:99) -- the same `Child` from the same leaf value.
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
        // decline rather than an impossibility: it covers an `Anchor`/`AnchorSize` whose tuple
        // conformance is a lie, and an arity that does not match a fixed-slot operation.
        //
        // A leaf cannot reach here: `isCopiedLeafAlternative` above routes every leaf that can reach
        // `rebuild` to the copy. An `@unknown` leaf C++ grows would still land here, which is why the
        // check stays.
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
        percentageResolveToDimension: options.percentageResolveToDimension,
        allowZeroValueLengthRemovalFromSum: options.allowZeroValueLengthRemovalFromSum,
        category: options.category
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
