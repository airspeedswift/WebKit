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

// The boundary's POD record types -- `CSSCalcSwiftNodeInfo`, the builder, the result -- and the
// three free functions that read a node's scalars. See CSSCalcSwiftTypes.h.
public import WebCore_Private.CSSCalcSwiftTypes

// `CSSCalc::Child` itself: this file walks the REAL tree, not a handle over it.
//
// `Child::operator[]` yields a checked borrow of a child and `Child::childCount()` bounds the loop,
// so the `CSSCalcSwiftNode` accessor facade is off the reading path entirely. The subscript
// spelling is load-bearing rather than stylistic -- CSSCalcTree.h explains why at the declaration,
// and rdar://140443562 is the upstream item that would let it be a named accessor.
//
// This is the WebCore_Private umbrella, which CSSCalcSwiftTypes.h's header comment used to say
// could not be imported at all. It can (R139); `Child` and every operation are safe types once
// their pointer-bearing members are hidden, which CSSCalcTree.h does.
internal import WebCore_Private.Core

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
// Handles all 41 of `CSSCalc::Node`'s alternatives: the four numeric leaves, `Symbol`, `Invert`,
// `Negate`, `Deg2Rad`, the single-argument and fixed-arity operations, `hypot()`, `min()`/`max()`,
// `clamp()`, `Sum`, `Product`, `calc-mix()`, `random()`, `anchor()`/`anchor-size()` and
// `sibling-count()`/`sibling-index()`. What remains is declined per TREE, not per operation:
// `isSimplifiableAlternative` refuses an arity the boundary's `rebuildFrom` could not fill, and a
// `fold*` that cannot derive its answer returns `.declined`. That function's `@unknown default:
// return false` is why the list above can be stated as complete -- an alternative C++ adds later
// declines on its own rather than being mis-handled by a stale case list here.
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

/// The merge key for a leaf: its `CSSUnitType` underlying value.
///
/// `CSSCalcTree+NumericIdentity.h` exists to give the C++ a *dense* key -- "fixed size ... lookup
/// tables needed in expression simplification" -- and `toNumericIdentity` is injective on the unit:
/// `Number`, `Percentage`, each of the six canonical dimensions and each of the 48 non-canonical units
/// map one-to-one onto a `NumericIdentity`. So the unit already IS the identity, and keying on it
/// directly gives the same fixed-size table without transcribing a second 56-case enum into this file
/// and having to keep it in step.
///
/// Masked to 7 bits, which loses nothing and is what makes the index total: `CSSUnitType.h` states that
/// `CSSValue` allocates 7 bits for the value, so no enumerator can exceed 127 and the mask never aliases
/// two units onto one bucket. The tables are therefore indexed with no bounds trap, whatever value the
/// boundary hands over.
@inline(always)
private func mergeKey(_ leaf: NumericLeaf) -> Int {
    return Int(leaf.unitType & 0x7F)
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
/// the input, and the only reason the boundary has a construction entry that names its own kind.
    case rebuiltMinMax(isMax: Bool)
/// A `Children`-slotted node whose children merged: `rewrite` recomputes the merge plan, pushes one
/// operand per survivor, and calls `rebuildFrom` with the new count. Kept apart from `.unchanged`
/// because the arity may have changed.
///
/// `CalcMix` uses this case for every rebuild, even unchanged ones: its rebuild pushes a weight plan
/// per item on a second stack, and `.unchanged` would leave that stack out of step. See
/// `foldCalcMix`.
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
        // Every operation: `rebuildFrom` recovers the kind from the original's variant tag and fills its
        // slots -- including `Anchor`/`AnchorSize`, whose `.unchanged` instead routes to `rebuildAnchor`
        // since their `<anchor-side>` subtree must not be pushed as an operand.
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
        // and the only reason `buildOperation` is reachable from this port. 3/2/1 are the only shapes `ChildOrNone`
        // admits; whether `kind` agrees on WHICH bound is `none` is checked separately in `foldClamp`.
        return childCount >= 1 && childCount <= 3

    case .Hypot:
        // A stateful pass over a variable number of children with a running type tag. No arity condition:
        // `simplify(Hypot&)` has no `ASSERT` on child count, and its executor defines the empty case (returns
        // NaN without calling the functor), which this file reaches the same way via `.unchanged`.
        return true

    case .CalcMix:
        // `simplify(CalcMix&)`, the only alternative whose payload is a `Vector<Item>` rather than a
        // `Child`/`Children`. At least one item is required: with none, the accumulator loop never runs and
        // `:1685` dereferences an empty `std::optional` -- undefined in a shipping build. Unreachable through
        // the parser, since `consumeCalcMix` requires at least one `<calc-sum>`. No upper bound: the count
        // can only shrink.
        return childCount >= 1

    case .Random:
        // `random( <random-key>? , <calc-sum>, <calc-sum>, <calc-sum>? )`; the key is not a child, so
        // `childCount` is 2 or 3 regardless of whether a key is present.
        return childCount == 2 || childCount == 3

    case .SiblingCount, .SiblingIndex:
        // Leaves (`isLeaf` true on both), so there is no arity to check.
        return true

    case .Anchor, .AnchorSize:
        // The two whose children the boundary answers for by hand: `Anchor` has the `<anchor-side>` when
        // it's a `<percentage>` subtree plus the fallback, `AnchorSize` has the fallback alone -- bound 2 and
        // 1, checked exactly against `operationInfo()`'s `anchorSideIsKeyword`/`hasFallback` in
        // `foldAnchorFunction`, which is the only place both halves are in scope. Both are `IndirectNode`s
        // with slots, so `rebuildFrom` fills them via its two hand-written arms.
        return alternative == .Anchor ? childCount <= 2 : childCount <= 1

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
    _ node: borrowing WebCore.CSSCalc.Child,
    _ nodeCount: inout UInt32,
    _ kindMask: inout UInt64,
    _ blame: inout CalcAlternative?
) -> Bool {
    // One crossing per node: `info()` answers the discriminant, the child count and every POD
    // payload together, because they all come off the same variant tag.
    let info = WebCore.CSSCalc.swiftNodeInfo(node)
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
        if !walk(node[Int(index)], &nodeCount, &kindMask, &blame) {
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

/// What `pushNumericChildren` does to each numeric child before pushing it.
///
/// A closed enum rather than a closure, because `pushNumericChildren` holds the builder `inout` and
/// a closure that also mutated it would be an overlapping access -- see `hasOnlyNumericChildren`.
/// The two cases are deliberately not one `* factor`: `-x` and `x * -1.0` are free to differ in the
/// sign bit of a NaN, which is exactly what `Fold.scaledSumChildren` records.
private enum NumericChildTransform {
    /// Rules 6.3/6.4's unary minus (`+Simplification.cpp:934`, `:949`: `child.value = -child.value`).
    case negated
    /// Step 9.3's `*=` (`:773`), distributing the merged `<number>` over a `Sum`'s children.
    case scaled(Double)

    @inline(always)
    func applied(to leaf: NumericLeaf) -> NumericLeaf {
        switch self {
        case .negated:
            return leaf.withValue(-leaf.value)
        case .scaled(let factor):
            return leaf.withValue(leaf.value * factor)
        }
    }
}

/// What `pushNumericChildren` did.
private enum NumericChildrenPush {
    /// Every final child was numeric and this many operands were pushed.
    case pushed(UInt32)
    /// At least one final child was not numeric -- `hasOnlyNumericChildren` answering false. Both
    /// callers reach this only if the fold pass and the rewrite pass disagree, and report it as a
    /// decline rather than asserting.
    case notAllNumeric
    /// `pushLeaf` refused a leaf this function synthesised: a contract violation with no input
    /// alternative to blame.
    case pushRefused
}

private extension CalcSimplification {

    /// `simplify(Invert&)` (`+Simplification.cpp:962`-`:979`). Rule 7.2 (`Invert(Invert(x))` -> `x`)
    /// reaches a grandchild via the child subscript and `.replacedByGrandchild`, no boundary change needed.
    /// Rule 7.1 folds only a `<number>`, so `Invert(Invert(50%))` reaches 7.2 with a `Percentage`
    /// grandchild; `promoteGrandchild` reports it as a leaf so an enclosing `Product` still folds it.
    @inline(always)
    func foldInvert(
        _ node: borrowing WebCore.CSSCalc.Child,
        _ builder: borrowing WebCore.CSSCalc.CSSCalcSwiftBuilder
    ) -> Fold {
        let a = fold(node[0], builder)
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
    /// no moved-from state, `hasOnlyNumericChildren` decides every child is numeric and
    /// `rewriteNegatedChildren`
    /// re-derives the list and pushes one negated leaf per child. The two declines below are named
    /// gaps, not catch-alls.
    @inline(always)
    func foldNegate(
        _ node: borrowing WebCore.CSSCalc.Child,
        _ builder: borrowing WebCore.CSSCalc.CSSCalcSwiftBuilder
    ) -> Fold {
        let a = fold(node[0], builder)
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
                if hasOnlyNumericChildren(node[0], a, builder) {
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
                if productHasNonNumericFactor(node[0], builder) {
                    return .unchanged(.Negate)
                }
                // No witness: every child folded to `Numeric` or a spliceable `Product`, and this
                // file cannot re-derive what step 9.1 spliced into the final list. Reachable only
                // from a constructed tree, since `parseAndSimplify` flattens nested `Product`s.
                return .declined(.Negate)
            }
            if childAlternative == .Sum {
                // 6.3 over a `Sum` whose term list step 8.1 spliced or whose terms merged.
                if hasOnlyNumericChildren(node[0], a, builder) {
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
    /// child's post-simplification list (not the parser's original). False means at least one child is
    /// not numeric.
    ///
    /// The predicate half of what used to be a single `numericChildren` returning `[NumericLeaf]?`.
    /// Three of that function's five callers only ever compared its result against `nil`, so a heap
    /// buffer was built and freed per node to answer a Boolean; the other two walked the list once,
    /// pushed each leaf and dropped it, which is `pushNumericChildren` below. Neither buffer exists
    /// now.
    ///
    /// The two are separate functions rather than one traversal parameterised over what to do per
    /// leaf, because they differ in how they hold the builder and Swift cannot be generic over that:
    /// this one runs in the fold pass, where the builder is `borrowing` at every frame, while
    /// `pushNumericChildren` runs in the rewrite pass and needs it `inout` for `pushLeaf`. A shared
    /// traversal taking a closure does not work either -- `sumMergePlan` records the first half of the
    /// reason (a closure cannot capture a `borrowing` parameter of copyable type, which the builder
    /// is), and passing the builder as a borrowed argument while a closure captures it mutably is an
    /// overlapping access.
    func hasOnlyNumericChildren(
        _ child: borrowing WebCore.CSSCalc.Child,
        _ folded: Fold,
        _ builder: borrowing WebCore.CSSCalc.CSSCalcSwiftBuilder
    ) -> Bool {
        switch folded {
        case .unchanged(let alternative):
            guard alternative == .Sum || alternative == .Product else {
                return false
            }
            // `.unchanged` is the arity-preserving case by definition -- see `Fold.mergedChildren` on
            // why the two are kept apart -- so the final list IS the node's own children in tree
            // order.
            let info = WebCore.CSSCalc.swiftNodeInfo(child)
            var index: UInt32 = 0
            while index < info.childCount {
                guard case .leaf = fold(child[Int(index)], builder) else {
                    return false
                }
                index += 1
            }
            return true

        case .mergedChildren(let alternative):
            guard alternative == .Sum else {
                // `.Min`/`.Max` are neither a `Sum` nor a `Product`, and `.Product` never reaches here
                // -- `foldNegate` declines it, because this function has no way to say "cannot
                // derive" as distinct from "not numeric".
                return false
            }
            let info = WebCore.CSSCalc.swiftNodeInfo(child)
            var origin: UInt32 = 0
            var terms = collectSumTerms(child, info.childCount, &origin, builder)
            if terms.declined != nil {
                // Unreachable: this same walk produced `.mergedChildren(.Sum)` without declining.
                // Checked rather than asserted, and answered `false` so the contract above stays
                // single-valued -- the caller then rebuilds the `Negate` and the child's own `rewrite`
                // declines the tree, which is a fallback to the C++ arm either way.
                return false
            }
            // `sumMergePlan` merges into `terms.folds`, so a first instance already carries its
            // accumulated value here; reading the term back is reading the merged result.
            let plan = sumMergePlan(&terms.folds, builder)
            for k in 0..<terms.folds.count where plan.survives(k, terms.folds.span) {
                guard case .leaf = terms.folds[k] else {
                    return false
                }
            }
            return true

        case .leaf, .replacedByTerm, .replacedBySumTerm, .replacedByGrandchild, .rebuiltMinMax,
             .negatedChildren, .scaledSumChildren, .declined:
            // None of these left a `Sum`/`Product` in place, and each is refused by `foldNegate`
            // first. Enumerated rather than defaulted so a new `Fold` case is a compile error here too.
            return false
        }
    }

    /// The collecting half: every final numeric child of `child`, transformed and pushed as an
    /// operand, in the same order `hasOnlyNumericChildren` visits them.
    ///
    /// Pushes as it walks rather than materialising a `[NumericLeaf]` for the caller to walk and drop
    /// -- one heap buffer per rewritten `Negate` or distributed `Product`, and one
    /// `swift_bridgeObjectRelease` on the hand-off. The interleaving is safe because nothing the fold
    /// pass reads from the builder (`resolveSymbol`, `resolveRelativeLength`,
    /// `resolveStyleCoupledValue`, `isLengthUnit`) can observe the operand stack, and because a push
    /// that happens before a later `.notAllNumeric` is discarded whole: both callers answer that with
    /// `.declined`, and a declined tree throws the builder away and runs the C++ arm.
    ///
    /// `.notAllNumeric` is `hasOnlyNumericChildren` answering false; both callers report it as
    /// unreachable, for the reason each states.
    func pushNumericChildren(
        _ child: borrowing WebCore.CSSCalc.Child,
        _ folded: Fold,
        _ transform: NumericChildTransform,
        _ builder: inout WebCore.CSSCalc.CSSCalcSwiftBuilder
    ) -> NumericChildrenPush {
        switch folded {
        case .unchanged(let alternative):
            guard alternative == .Sum || alternative == .Product else {
                return .notAllNumeric
            }
            let info = WebCore.CSSCalc.swiftNodeInfo(child)
            var pushedLeaves: UInt32 = 0
            var index: UInt32 = 0
            while index < info.childCount {
                guard case .leaf(let leaf) = fold(child[Int(index)], builder) else {
                    return .notAllNumeric
                }
                guard builder.pushLeaf(transform.applied(to: leaf).boundaryLeaf) else {
                    return .pushRefused
                }
                pushedLeaves += 1
                index += 1
            }
            return .pushed(pushedLeaves)

        case .mergedChildren(let alternative):
            guard alternative == .Sum else {
                return .notAllNumeric
            }
            let info = WebCore.CSSCalc.swiftNodeInfo(child)
            var origin: UInt32 = 0
            var terms = collectSumTerms(child, info.childCount, &origin, builder)
            if terms.declined != nil {
                return .notAllNumeric
            }
            let plan = sumMergePlan(&terms.folds, builder)
            var pushedLeaves: UInt32 = 0
            for k in 0..<terms.folds.count where plan.survives(k, terms.folds.span) {
                guard case .leaf(let leaf) = terms.folds[k] else {
                    return .notAllNumeric
                }
                guard builder.pushLeaf(transform.applied(to: leaf).boundaryLeaf) else {
                    return .pushRefused
                }
                pushedLeaves += 1
            }
            return .pushed(pushedLeaves)

        case .leaf, .replacedByTerm, .replacedBySumTerm, .replacedByGrandchild, .rebuiltMinMax,
             .negatedChildren, .scaledSumChildren, .declined:
            return .notAllNumeric
        }
    }

    /// True when this `Product`'s final factor list is certain to contain a non-`Numeric` node --
    /// a witness, not a derivation: one own child that isn't numeric suffices, except a spliceable
    /// `Product` factor (step 9.1 replaces it with its own children, which can all be numeric), which
    /// is not a witness and is answered `false` rather than recursed into.
    func productHasNonNumericFactor(
        _ child: borrowing WebCore.CSSCalc.Child,
        _ builder: borrowing WebCore.CSSCalc.CSSCalcSwiftBuilder
    ) -> Bool {
        let info = WebCore.CSSCalc.swiftNodeInfo(child)
        var index: UInt32 = 0
        while index < info.childCount {
            let folded = fold(child[Int(index)], builder)
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
        _ node: borrowing WebCore.CSSCalc.Child,
        _ info: WebCore.CSSCalc.CSSCalcSwiftNodeInfo,
        _ builder: borrowing WebCore.CSSCalc.CSSCalcSwiftBuilder
    ) -> Fold {
        // 9.1 and 9.2, merged exactly as the C++ merges them.
        var origin: UInt32 = 0
        var factors = productFactors(node, info.childCount, &origin, builder)
        if let declined = factors.declined {
            return declined
        }

        // Read out before the list is appended to, because 9.5 below asks about them after: the list
        // is now mutated in place rather than copied into a `finalFactors` of its own, which is one
        // fewer heap buffer per `Product` node -- and with `Array` that copy was a real duplication,
        // not a shared reference, from the moment `append` fired below.
        let numericProduct = factors.numericProduct
        let spliced = factors.spliced

        if let numericProduct {
            // "If `numericProduct` has a value and `newChildren` is empty, that means all the
            // children were numbers and the product can be returned directly." (`:750`)
            if factors.survivors.isEmpty {
                return .leaf(NumericLeaf.number(numericProduct))
            }

            // 9.3, extended by the C++ itself to `Numeric` and `Invert` factors as well as `Sum`
            // ones. The arity test is on the list BEFORE the merged number is appended, which is
            // what `:761`'s note means by "the last child is a singular `number` child".
            if factors.survivors.count == 1, let replacement = distributeNumber(factors.survivors[0], numericProduct) {
                return replacement
            }

            // "If there was more than one child or no replacement was found, append the product from
            // step 9.2 into the newChildren array." (`:798`) -- at the END, which is what makes the
            // list a reordering of the input rather than a copy of it.
            factors.survivors.append(ProductFactor(
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
        let finalFactors = factors.survivors.span
        for factorIndex in finalFactors.indices {
            success = multiplyProductFactor(finalFactors[factorIndex], &productValue, &productType)
            if !success {
                break
            }
        }

        if success, let resolvedCategory = productType.calculationCategory().value {
            // `:882`-`:902`, the eleven-case table -- shared verbatim with `zeroValueMatchingChild`
            // (`:1454`-`:1482`), which is the same table over the same categories with a value of 0.
            // See `numericLeafForCategory`.
            //
            // `nil` falls through to 9.5, which is `@unknown default: break`. It also absorbs the
            // `CSS::Category(rawValue:)` failure the `Percentage` arm used to spell as `.declined(nil)`:
            // an imported C++ scoped enum's `init?(rawValue:)` does not validate, so that branch never
            // fires, and 9.5 is never a wrong answer where a decline would have been a lost fold.
            if let folded = numericLeafForCategory(resolvedCategory, productValue) {
                return .leaf(folded)
            }
        }

        // 9.5. Return root.
        if numericProduct == nil, !spliced {
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

    /// `getType(const Child&)` (CSSCalcTree.cpp:384-:387) for a folded numeric leaf. Separate from
    /// `numericLeafType`: that one answers `nil` for a `NonCanonicalDimension` (step 9.4 has no arm
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
            // `:882`-`:884` and `:1459`-`:1461`. The two categories share one arm in both C++ bodies.
            return NumericLeaf.number(value)

        case .Percentage:
            // `Type::determinePercentHint(options.category)` (`:885`-`:886`, `:1462`-`:1463`). The
            // category is the options' one, not the resolved one -- `resolvedCategory` is already known
            // to be `Percentage` here, so passing it would make this arm a constant and lose the whole
            // point of the call.
            guard let optionsCategory = WebCore.CSS.Category(rawValue: category) else {
                // Never taken: an imported C++ scoped enum's `init?(rawValue:)` doesn't validate, so
                // this can't fail (see `percentHintFromRawValue`). Kept because it's the spelling that
                // produces a `CSS::Category` to pass, at no cost.
                return nil
            }
            return NumericLeaf.percentage(value, CalcType.determinePercentHint(optionsCategory))

        case .LengthPercentage:
            // `:887`-`:888` and `:1464`-`:1465`, a LITERAL `PercentHint::Length` in both C++ bodies
            // rather than a `determinePercentHint` call. Reproduced literally.
            return NumericLeaf.percentage(value, CalcType.PercentHintValue(.Length))

        case .Length:
            // `:889`-`:890`, `:1466`-`:1467`. `toCSSUnit(Dimension::Length)` is `CSSUnitType::Px`
            // (CSSCalcTree.h:993), so naming the unit is naming the dimension.
            return NumericLeaf.canonical(value, .Px)

        case .Angle:
            // `:891`-`:892`, `:1468`-`:1469`; `toCSSUnit(Dimension::Angle)` is `Deg`
            // (CSSCalcTree.h:994).
            return NumericLeaf.canonical(value, .Deg)

        case .AnglePercentage:
            // `:893`-`:894`, `:1470`-`:1471`, the other literal hint.
            return NumericLeaf.percentage(value, CalcType.PercentHintValue(.Angle))

        case .Time:
            // `:895`-`:896`, `:1472`-`:1473`; `toCSSUnit(Dimension::Time)` is `S` (CSSCalcTree.h:995).
            return NumericLeaf.canonical(value, .S)

        case .Frequency:
            // `:897`-`:898`, `:1474`-`:1475`; `toCSSUnit(Dimension::Frequency)` is `Hz`
            // (CSSCalcTree.h:996).
            return NumericLeaf.canonical(value, .Hz)

        case .Resolution:
            // `:899`-`:900`, `:1476`-`:1477`; `toCSSUnit(Dimension::Resolution)` is `Dppx`
            // (CSSCalcTree.h:997).
            return NumericLeaf.canonical(value, .Dppx)

        case .Flex:
            // `:901`-`:902`, `:1478`-`:1479`; `toCSSUnit(Dimension::Flex)` is `Fr`
            // (CSSCalcTree.h:998).
            return NumericLeaf.canonical(value, .Fr)

        @unknown default:
            // A category C++ grew and this file has not been taught. Both C++ `switch`es are exhaustive
            // with no `default`, so growing the enum is a build failure THERE.
            return nil
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

/// How far `canonicalize` (`+Simplification.cpp:169`-`:287`) gets on the unit alone.
///
/// Twenty-eight of its seventy `CSSUnitType` cases need nothing else: fourteen multiply by a
/// compile-time constant, and fourteen are units a `NonCanonicalDimension` can never hold. The other
/// forty-two are font-, viewport- and container-relative lengths, which `Style::resolveLength`
/// resolves against a `CSSToLengthConversionData` only the C++ builder holds.
///
/// Reported rather than resolved so a caller with no builder can still take the twenty-eight: a
/// single builder-taking entry point would answer "unchanged" for `1cm` whenever the builder is
/// absent, which is a silent wrong answer and not a decline.
private enum CanonicalizeStep {
    case leaf(NumericLeaf)
    case relativeLength
}

private extension CalcSimplification {

    /// What `copyAndSimplify(const Child&)` (`+Simplification.cpp:1809`-`:1822`) would produce for
    /// this subtree, without pushing anything: it simplifies the children, then tries to fold the
    /// node itself, reporting the result rather than materializing it.
    ///
    /// `builder` is `borrowing` here, so only its `const` upcalls are reachable -- `pushLeaf`,
    /// `pushCopyOf`, `rebuildFrom` and `buildOperation` are all `mutating` in Swift and can't be called
    /// on a borrow, which makes "pushes nothing" compiler-checked rather than a comment.
    func fold(
        _ node: borrowing WebCore.CSSCalc.Child,
        _ builder: borrowing WebCore.CSSCalc.CSSCalcSwiftBuilder
    ) -> Fold {
        let info = WebCore.CSSCalc.swiftNodeInfo(node)
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
            return foldDeg2Rad(fold(node[0], builder))

        case .Min:
            return foldMinMax(node, info, false, builder)
        case .Max:
            return foldMinMax(node, info, true, builder)

        case .Sum:
            return foldSum(node, info, builder)

        case .Clamp:
            return foldClamp(node, info, builder)

        case .RoundNearest:
            return foldRound(fold(node[0], builder), secondOperand(node, info, builder), alternative, CalcExecutor.roundNearest)
        case .RoundUp:
            return foldRound(fold(node[0], builder), secondOperand(node, info, builder), alternative, CalcExecutor.roundUp)
        case .RoundDown:
            return foldRound(fold(node[0], builder), secondOperand(node, info, builder), alternative, CalcExecutor.roundDown)
        case .RoundToZero:
            return foldRound(fold(node[0], builder), secondOperand(node, info, builder), alternative, CalcExecutor.roundToZero)

        case .Mod:
            return foldBinaryOperation(fold(node[0], builder), fold(node[1], builder), alternative, CalcExecutor.mod)
        case .Rem:
            return foldBinaryOperation(fold(node[0], builder), fold(node[1], builder), alternative, CalcExecutor.rem)

        case .Sin:
            return reshape(simplifyForTrigOperand(fold(node[0], builder), alternative, CalcExecutor.sin), alternative)
        case .Cos:
            return reshape(simplifyForTrigOperand(fold(node[0], builder), alternative, CalcExecutor.cos), alternative)
        case .Tan:
            return reshape(simplifyForTrigOperand(fold(node[0], builder), alternative, CalcExecutor.tan), alternative)

        case .Asin:
            return reshape(simplifyForArcTrigOperand(fold(node[0], builder), alternative, CalcExecutor.asin), alternative)
        case .Acos:
            return reshape(simplifyForArcTrigOperand(fold(node[0], builder), alternative, CalcExecutor.acos), alternative)
        case .Atan:
            return reshape(simplifyForArcTrigOperand(fold(node[0], builder), alternative, CalcExecutor.atan), alternative)

        case .Atan2:
            return foldAtan2(fold(node[0], builder), fold(node[1], builder))

        case .Pow:
            return foldTwoNumbers(fold(node[0], builder), fold(node[1], builder), alternative, CalcExecutor.pow)

        case .Sqrt:
            return foldOneNumber(fold(node[0], builder), alternative, CalcExecutor.sqrt)

        case .Hypot:
            return foldHypot(node, info, builder)

        case .Log:
            // `log( <calc-sum>, <calc-sum>? )`. With a base it is the two-`Number` shape, without
            // one it is the natural log -- two different `OperatorExecutor<Operator::Log>`
            // overloads, and the C++ picks between them on `root.b` exactly as this picks on the
            // child count.
            if let base = secondOperand(node, info, builder) {
                return foldTwoNumbers(fold(node[0], builder), base, alternative, CalcExecutor.log)
            }
            return foldOneNumber(fold(node[0], builder), alternative, CalcExecutor.log)

        case .Exp:
            return foldOneNumber(fold(node[0], builder), alternative, CalcExecutor.exp)

        case .Abs:
            return foldAbs(fold(node[0], builder))

        case .Sign:
            return foldSign(fold(node[0], builder))

        case .Progress:
            return foldProgress(
                fold(node[0], builder),
                fold(node[1], builder),
                fold(node[2], builder),
                alternative,
                CalcExecutor.progress
            )
        case .ProgressNoClamp:
            return foldProgress(
                fold(node[0], builder),
                fold(node[1], builder),
                fold(node[2], builder),
                alternative,
                CalcExecutor.progressNoClamp
            )

        case .SiblingCount, .SiblingIndex:
            return foldSiblingFunction(node, alternative, builder)

        case .Random:
            return foldRandom(node, info, builder)

        case .Anchor, .AnchorSize:
            return foldAnchorFunction(node, info, alternative, builder)

        case .CalcMix:
            return foldCalcMix(node, info, builder)

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
        _ node: borrowing WebCore.CSSCalc.Child,
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
        _ node: borrowing WebCore.CSSCalc.Child,
        _ info: WebCore.CSSCalc.CSSCalcSwiftNodeInfo,
        _ builder: borrowing WebCore.CSSCalc.CSSCalcSwiftBuilder
    ) -> Fold {
        let minimumFold = fold(node[0], builder)
        guard case .leaf(let minimum) = minimumFold else {
            return foldFailed(minimumFold, .Random)
        }

        let maximumFold = fold(node[1], builder)
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
            let stepChildFold = fold(node[2], builder)
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

    /// Where the fallback `<length-percentage>` sits among an anchor function's children.
    ///
    /// `Anchor`/`AnchorSize` declare `tuple_size` 0, so the boundary answers for their children by
    /// hand: an `Anchor` has the `<anchor-side>` (when it's a `<percentage>` subtree, not a keyword)
    /// then the fallback; an `AnchorSize` has the fallback alone.
    @inline(always)
    func anchorFallbackIndex(
        _ alternative: CalcAlternative,
        _ operation: WebCore.CSSCalc.CSSCalcSwiftOperationInfo
    ) -> UInt32 {
        // `anchorSideIsKeyword` is inert for `AnchorSize`, so the alternative is tested first rather
        // than the flag being trusted for a kind that does not carry it.
        return (alternative == .Anchor && !operation.anchorSideIsKeyword) ? 1 : 0
    }

    /// `simplify(Anchor&)` and `simplify(AnchorSize&)` (`+Simplification.cpp:1692`-`:1744`): resolve
    /// against the anchor position evaluator, substituting the fallback on failure. One function for
    /// both, since `resolveStyleCoupledValue` reads which off the node's own variant tag.
    ///
    /// Three dispositions: RESOLVED, a canonical `<length>` (after folding the discarded fallback for
    /// its upcalls); THE EVALUATION ANSWERED NOTHING, so the fallback substitutes via `promoteTerm`
    /// (non-numeric becomes `.replacedByTerm`, numeric becomes the leaf itself); or NO CONVERSION
    /// DATA/BUILDER STATE, rebuilt with nothing marked.
    ///
    /// The `<anchor-side>` subtree is deliberately NOT folded: the C++ copies it rather than
    /// simplifying (`:1797`), so `anchor(--a calc(25% + 25%))` keeps its unfolded `Sum` on the C++ arm
    /// too. The child count and `operationInfo()`'s record must agree, or this declines.
    @inline(always)
    func foldAnchorFunction(
        _ node: borrowing WebCore.CSSCalc.Child,
        _ info: WebCore.CSSCalc.CSSCalcSwiftNodeInfo,
        _ alternative: CalcAlternative,
        _ builder: borrowing WebCore.CSSCalc.CSSCalcSwiftBuilder
    ) -> Fold {
        let operation = WebCore.CSSCalc.swiftOperationInfo(node)
        let fallbackIndex = anchorFallbackIndex(alternative, operation)
        guard fallbackIndex + (operation.hasFallback ? 1 : 0) == info.childCount else {
            return .declined(alternative)
        }

        let resolved = builder.resolveStyleCoupledValue(node)
        if resolved.resolved {
            // `simplify` always ends at a `CanonicalDimension`, so the check is on the alternative,
            // not the unit -- a boundary that came apart declines rather than building the wrong leaf.
            guard resolved.alternative == .CanonicalDimension else {
                return .declined(alternative)
            }

            // The discarded fallback is still folded here for its upcalls, even though its value is
            // thrown away: `copyAndSimplify` simplifies children before `simplify` runs on the node, so
            // the C++ arm has already simplified the fallback it discards, and that simplification can
            // have an observable effect (e.g. marking a property invalid at computed-value time).
            // Done in `fold` rather than `rewrite`, since a parent that folds this node away never
            // calls `rewrite` on it at all.
            if operation.hasFallback {
                _ = fold(node[Int(fallbackIndex)], builder)
            }

            return .leaf(NumericLeaf(
                kind: .canonicalDimension,
                value: resolved.value,
                unitType: resolved.unitType,
                percentHint: 0
            ))
        }

        if resolved.substituteFallback, operation.hasFallback {
            // Routed through `promoteTerm`, not a bare `.replacedByTerm`: the C++ returns the fallback
            // child itself, so a `Numeric` fallback must reach the parent as a `.leaf` or the parent
            // (e.g. a wrapping `Sum`) will treat it as an opaque subtree and fail to fold
            // (`calc(anchor(top, 1px) + 1em)` must become `17px`, not `calc(1px + 16px)`).
            return promoteTerm(fold(node[Int(fallbackIndex)], builder), fallbackIndex)
        }

        // Both remaining dispositions rebuild the node with its simplified fallback; they differ only
        // in whether the C++ marked the property invalid, which this file need not repeat.
        return .unchanged(alternative)
    }

    /// `canonicalize` (`+Simplification.cpp:169`-`:287`) minus its one upcall; see `CanonicalizeStep`
    /// for why the upcall is reported rather than taken here.
    ///
    /// The fourteen constant multiplies read the same constants the C++ reads, through
    /// `CSSUnitConversions.h`/`wtf.Core.MathExtras` and in the same operand order -- a transcribed
    /// literal would be a different `double`. The fourteen unreachable units are enumerated rather
    /// than left to `default`, and must stay that way: `CSS::toLengthUnit`'s domain
    /// (CSSPrimitiveNumericUnits.h:609-:666) is WIDER than the upcall group, accepting `QuirkyEm`,
    /// `Px`, `Cm`, `Mm`, `Q`, `In`, `Pt` and `Pc` as well, so any of them dropped from the list would
    /// route to `resolveRelativeLength` and resolve where the C++ answers `nullopt`.
    @inline(always)
    func canonicalizeStep(_ value: Double, _ unitType: UInt16) -> CanonicalizeStep {
        // The C++'s `nullopt`: `simplify(NonCanonicalDimension&)` copies the node through unchanged.
        func unchanged() -> CanonicalizeStep {
            return .leaf(NumericLeaf(kind: .nonCanonicalDimension, value: value, unitType: unitType, percentHint: 0))
        }
        // `makeCanonical(value, dimension)`. The canonical UNIT is named rather than the
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
            return .relativeLength
        }
    }

    /// `tryMakeCanonical` (`+Simplification.cpp:182`-`:186`), the one arm of `canonicalize` Swift
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
    /// otherwise leave it alone. The two-pass port's spelling, for the walk's own case and
    /// `foldSymbol`, which both always hold a builder.
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


    /// The `std::optional<Child> b` slot of `round()` and `log()`, folded, or `nil` when absent.
    ///
    /// `childCount > 1` is a presence test, not a bounds check -- the arity is already validated --
    /// and is written as `> 1` rather than `== 2` so it stays correct if a wider arity is admitted
    /// later.
    @inline(always)
    func secondOperand(
        _ node: borrowing WebCore.CSSCalc.Child,
        _ info: WebCore.CSSCalc.CSSCalcSwiftNodeInfo,
        _ builder: borrowing WebCore.CSSCalc.CSSCalcSwiftBuilder
    ) -> Fold? {
        guard info.childCount > 1 else {
            return nil
        }
        return fold(node[1], builder)
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

    /// Fold every child of a variable-arity node, in tree order, and hand the result to `body`.
    ///
    /// This is the port's stand-in for the C++'s `root.children`, which is the one thing this file
    /// cannot have: the C++ simplifies **in place**, so by the time `simplify(Sum&)` runs, the
    /// simplified children are already sitting in the `Vector<Child>` the tree owns and reading them
    /// allocates nothing at all. Swift holds the tree through a read-only handle, so the folded
    /// children have to be materialised somewhere.
    ///
    /// Somewhere is a **scoped stack allocation** (SE-0524's `withTemporaryAllocation`), not a heap
    /// `Array`: the list is sized exactly by `childCount`, dead when the fold returns, and never
    /// escapes -- which is that facility's exact shape. No `unsafe`, no refcount, and no `malloc` on
    /// any tree small enough to fit the stack, which is the nearest this gets to the C++'s zero.
    ///
    /// The remaining heap buffers are `SumTermList`'s and `ProductFactorList`'s, which are genuinely
    /// growable (a spliced term or factor list is bounded by subtree size, not by `childCount`) and
    /// are what the C++ spends a conditional `Vector` on too. Both are `UniqueArray`, so they are
    /// allocations without a refcount rather than `Array`s with one.
    @inline(always)
    func withFoldedChildren<R: ~Copyable>(
        _ node: borrowing WebCore.CSSCalc.Child,
        _ childCount: UInt32,
        _ builder: WebCore.CSSCalc.CSSCalcSwiftBuilder,
        _ body: (inout OutputSpan<Fold>) -> R
    ) -> R {
        // `Int(clamping:)`, not `Int(_:)`, which traps if `Int` is narrower than `UInt32`. Unlike the
        // `Array` this replaces, the capacity is a bound and not a hint -- `append` past it traps --
        // but the loop below appends exactly `childCount` times.
        return withTemporaryAllocation(of: Fold.self, capacity: Int(clamping: childCount)) { folded in
            var index: UInt32 = 0
            while index < childCount {
                folded.append(fold(node[Int(index)], builder))
                index += 1
            }
            return body(&folded)
        }
    }

    /// The first child that declined, as the `Fold` to return, or `nil` when none did. Returns the
    /// child's own `.declined` value rather than its blame, avoiding a double optional.
    ///
    /// Checked over all children before any fold dispatches: a declined child means the whole tree
    /// can't be built, regardless of which operand the C++ would have looked at first.
    @inline(always)
    func declinedChild(_ folded: Span<Fold>) -> Fold? {
        for index in folded.indices {
            if case .declined = folded[index] {
                return folded[index]
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
        _ node: borrowing WebCore.CSSCalc.Child,
        _ child: UInt32,
        _ grandchild: UInt32,
        _ builder: borrowing WebCore.CSSCalc.CSSCalcSwiftBuilder
    ) -> Fold {
        switch fold(node[Int(child)][Int(grandchild)], builder) {
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
        _ node: borrowing WebCore.CSSCalc.Child,
        _ info: WebCore.CSSCalc.CSSCalcSwiftNodeInfo,
        _ builder: borrowing WebCore.CSSCalc.CSSCalcSwiftBuilder
    ) -> Fold {
        return withFoldedChildren(node, info.childCount, builder) { folded -> Fold in
            if let declined = declinedChild(folded.span) {
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
            for index in folded.span.indices {
                let value = hypotElement(folded[index], &tag)
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
        _ node: borrowing WebCore.CSSCalc.Child,
        _ info: WebCore.CSSCalc.CSSCalcSwiftNodeInfo,
        _ isMax: Bool,
        _ builder: borrowing WebCore.CSSCalc.CSSCalcSwiftBuilder
    ) -> Fold {
        let alternative: CalcAlternative = isMax ? .Max : .Min
        return withFoldedChildren(node, info.childCount, builder) { folded -> Fold in
            if let declined = declinedChild(folded.span) {
                return declined
            }

            // `if (root.children.size() == 1) return { WTF::move(root.children[0]) };` -- BEFORE the
            // merge, which is why a single-child `min()` folds to its child even when the child is a
            // percentage the merge would have refused.
            if folded.count == 1 {
                return promoteTerm(folded[0], 0)
            }

            let plan = mergePlan(&folded, isMax)

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
            //
            // `folded[0]` is the merged value, not the input's: `mergePlan` wrote it back, exactly as the
            // C++ wrote into `root.children[offset - 1]`.
            if folded.count - plan.merges == 1 {
                return promoteTerm(folded[0], 0)
            }

            return .mergedChildren(alternative)
        }
    }

    /// `std::array<size_t, numberOfNumericIdentityTypes> offsetOfFirstInstance` (`:414`), restored:
    /// the merge is keyed by unit identity in a compile-time fixed-size table, not by a per-term heap
    /// array. `MergeTable` holds `index + 1`, so 0 means no term of that unit has been seen -- the
    /// C++'s own encoding, which is what lets the whole table be zero-initialised.
    typealias MergeTable = InlineArray<128, Int32>
    /// `FirstInstance::canRemove` (`:603`), one bit per unit identity. A separate table rather than a
    /// field beside the offset so the common (`Min`/`Max`) case pays for the offsets alone.
    typealias MergeFlags = InlineArray<128, Bool>

    /// The `Min`/`Max` merge plan: `simplifyForMinMax`'s `offsetOfFirstInstance` plus its
    /// `numberOfMergeOpportunities` (`:414`, `:418`).
    ///
    /// `~Copyable` on purpose. The table is 512 bytes, so an accidental copy would be a silent
    /// regression of exactly the kind this change removes; making one a compile error is free.
    struct MinMaxMergePlan: ~Copyable {
        var offsets = MergeTable(repeating: 0)
        var merges = 0

        /// `if (!offset || (offset - 1) == i)` (`:466`), the C++'s own survivor test, asked of the
        /// term list rather than stored per term.
        ///
        /// Three ways to survive, all in that one condition: a non-`Numeric` term (the C++'s
        /// `[](const auto&)` arm), a term whose unit was never recorded -- which is how a percentage
        /// survives when merging percentages is disallowed -- and the first instance of its unit.
        @inline(always)
        func survives(_ index: Int, _ folded: Span<Fold>) -> Bool {
            guard case .leaf(let leaf) = folded[index] else {
                return true
            }
            let offset = offsets[mergeKey(leaf)]
            return offset == 0 || Int(offset) - 1 == index
        }
    }

    /// Phase 1 of `simplifyForMinMax` (`:418`-`:446`), and like the C++ it merges **into the term
    /// list**: `root.children[offset - 1] = evaluate(...)` becomes `folded[target] = .leaf(...)`.
    ///
    /// Writing the merged value back is what removes the per-term slot array. The earlier design
    /// carried an `accumulated` leaf per term because the tree itself is immutable here -- but the
    /// term list is not the tree, it is this function's own local, and mutating it costs nothing that
    /// the tree can observe.
    ///
    /// `evaluate` is `CalcExecutor.min`/`.max` (the two-`double` overload, not the signed-zero
    /// helpers). With those executors' NaN short-circuits and signed-zero symmetry, merge order can't
    /// change the result for `Min`/`Max` -- written in term order anyway since it costs nothing and
    /// `Sum` genuinely depends on it.
    func mergePlan(_ folded: inout OutputSpan<Fold>, _ isMax: Bool) -> MinMaxMergePlan {
        var plan = MinMaxMergePlan()
        // `bool canMergePercentages = !percentageResolveToDimension(options);` (`:416`).
        let canMergePercentages = !percentageResolveToDimension

        for i in 0..<folded.count {
            // `[](const auto&) { return 0; }`: a non-`Numeric` child contributes no merge
            // opportunity, is never merged, and always survives.
            guard case .leaf(let leaf) = folded[i] else {
                continue
            }

            // `if (id == NumericIdentity::Percentage && !canMergePercentages) return 0;` (`:423`).
            // The bucket is left unset, which is exactly how `survives` lets the term through.
            // `simplify(Sum&)` has no such skip -- see `sumMergePlan`, which is why the two plans are
            // separate functions.
            if leaf.kind == .percentage, !canMergePercentages {
                continue
            }

            let key = mergeKey(leaf)
            // The bucket's term is a leaf by construction -- only a leaf is ever recorded, and a merge
            // only ever writes another leaf back. Re-seating rather than trapping keeps the one
            // invariant `survives` depends on ("the recorded term is the surviving one") true even if
            // that ever stopped holding, where dropping through would silently delete a term.
            if plan.offsets[key] != 0, case .leaf(let first) = folded[Int(plan.offsets[key]) - 1] {
                // The surviving alternative, unit and percent hint are the first instance's, which
                // is exactly what `withValue` carries -- `makeChildWithValueBasedOn(result, aNumeric)`.
                let merged = isMax
                    ? CalcExecutor.max(first.value, leaf.value)
                    : CalcExecutor.min(first.value, leaf.value)
                folded[Int(plan.offsets[key]) - 1] = .leaf(first.withValue(merged))
                plan.merges += 1
                continue
            }

            // `offsetOfFirstInstance[id] = i + 1;` -- the first instance, not yet a merge opportunity.
            plan.offsets[key] = Int32(i + 1)
        }

        return plan
    }

    // MARK: `clamp()`

    /// `simplify(Clamp&)` (`+Simplification.cpp:1008`-`:1105`). Four outcomes: both bounds `none` ->
    /// return `val` whatever it is; `val` not a `Numeric` -> rebuild unchanged (dominates the other
    /// two); one bound `none` -> fold if it agrees with `val`, else convert to `min()`/`max()`;
    /// neither `none` -> fold if all three agree, else rebuild (no conversion in this branch).
    ///
    /// `Clamp`'s tuple skips an absent bound in tree order, so the child subscript already gives
    /// `[val, max]` / `[min, val]` / `[val]` / `[min, val, max]`. `childCount` gives the arity and
    /// `info.kind`'s `ClampWithNoneMinimum`/`ClampWithNoneMaximum` says which bound is absent when the
    /// arity is 2; the two are cross-checked and a mismatch declines.
    func foldClamp(
        _ node: borrowing WebCore.CSSCalc.Child,
        _ info: WebCore.CSSCalc.CSSCalcSwiftNodeInfo,
        _ builder: borrowing WebCore.CSSCalc.CSSCalcSwiftBuilder
    ) -> Fold {
        return withFoldedChildren(node, info.childCount, builder) { folded -> Fold in
            if let declined = declinedChild(folded.span) {
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
        _ node: borrowing WebCore.CSSCalc.Child,
        _ info: WebCore.CSSCalc.CSSCalcSwiftNodeInfo,
        _ builder: borrowing WebCore.CSSCalc.CSSCalcSwiftBuilder
    ) -> Fold {
        var origin: UInt32 = 0
        var terms = collectSumTerms(node, info.childCount, &origin, builder)
        if let declined = terms.declined {
            return declined
        }

        // `if (root.children.size() == 1) return { WTF::move(root.children[0]) };` (`:594`), on the
        // FLATTENED list. No merge has run, so the term's own fold is the answer.
        if terms.folds.count == 1 {
            return promoteSumTerm(terms.folds[0], terms.origins[0])
        }

        let plan = sumMergePlan(&terms.folds, builder)

        // 1. `if (!childrenToRemoveTotal) return { };`
        if plan.removeTotal == 0 {
            // ... and the arity is the flattened one, which 8.1 may already have changed.
            return terms.folds.count == Int(info.childCount) ? .unchanged(.Sum) : .mergedChildren(.Sum)
        }

        // Term 0 is always the sole merge-survivor here (same proof as `foldMinMax`), so no search is
        // needed. Its `canRemove` bit is not consulted -- removals aren't applied yet at this test.
        // Its fold is the merged value, which `sumMergePlan` wrote back over the term.
        if terms.folds.count - plan.merges == 1 {
            return promoteSumTerm(terms.folds[0], terms.origins[0])
        }

        let combined = terms.folds.count - plan.removeTotal

        // A `length` zero is returned because only a `length` node can be removed.
        if combined == 0 {
            return .leaf(NumericLeaf.canonicalLength(0))
        }

        // The C++'s scan condition (non-`Numeric`, or a first instance with `!canRemove`) is exactly
        // `survives`.
        if combined == 1 {
            for k in 0..<terms.folds.count where plan.survives(k, terms.folds.span) {
                return promoteSumTerm(terms.folds[k], terms.origins[k])
            }
            // Cannot happen per the arithmetic above; if it did, `rebuildFrom` with zero operands is
            // refused and the tree declines, safer than the C++'s empty `Sum`.
        }

        // 5. `root.children = WTF::move(combinedChildren); return { };`
        return .mergedChildren(.Sum)
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

    /// One `Sum`'s flattened term list, as values -- no node handle, since a borrowed `Child` is
    /// `~Escapable` and no Swift container accepts one. Everything here is `Copyable`/`Escapable`, so
    /// the list can be freely returned and walked.
    struct SumTermList: ~Copyable {
        /// One entry per term of the flattened list, in order.
        ///
        /// `UniqueArray` (SE-0527), not `Array`, and the reason this type is `~Copyable`. Both buffers
        /// are scratch owned by exactly one `collectSumTerms` frame and are never shared, so
        /// copy-on-write buys nothing and costs a uniqueness check on every `append` plus a
        /// retain/release pair each time the list is returned -- and this list is built three times
        /// per `Sum` node (`foldSum`, `hasOnlyNumericChildren`/`pushNumericChildren`, and
        /// `rewriteMergedSum`), once more per nested `Sum` spliced in. A `UniqueArray`'s buffer is not
        /// a refcounted object at all, so none of that appears.
        var folds = UniqueArray<Fold>()
        /// The tree-position ordinal each term came from. See `Fold.replacedBySumTerm`.
        var origins = UniqueArray<UInt32>()
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
        _ node: borrowing WebCore.CSSCalc.Child,
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
            let folded = fold(node[Int(index)], builder)
            if case .declined = folded {
                // Checked here, not by a sweep afterwards: a declined grandchild must stop the walk
                // before the parent's plan is computed over a list missing terms.
                out.declined = folded
                return out
            }

            if isSpliceableSum(folded) {
                let childInfo = WebCore.CSSCalc.swiftNodeInfo(node[Int(index)])
                var spliced = collectSumTerms(node[Int(index)], childInfo.childCount, &origin, builder)
                if let declined = spliced.declined {
                    out.declined = declined
                    return out
                }
                let childPlan = sumMergePlan(&spliced.folds, builder)
                for k in 0..<spliced.folds.count where childPlan.survives(k, spliced.folds.span) {
                    out.folds.append(spliced.folds[k])
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
    ///
    /// Shared with the flat simplifier, which is why the `Px` special case is stated once: the
    /// `isLengthUnit(uint16_t)` upcall (`+Simplification.cpp:2470`) routes through
    /// `toNumericIdentity(NonCanonicalDimension{...})`, which answers `Number` for `CSSUnitType::Px`
    /// and so returns FALSE for canonical px, where `isLength(PX)` in the C++ is true.
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

    /// The `Sum` merge plan: `std::array<FirstInstance, numberOfNumericIdentityTypes> firstInstances`
    /// (`:605`), minus the per-bucket `merges` counter, which the C++ only keeps in order to sum it at
    /// `:644` and which a running total gives for free.
    ///
    /// `~Copyable` for the same reason as `MinMaxMergePlan`: 640 bytes of tables, and no copy of them
    /// is ever wanted.
    struct SumMergePlan: ~Copyable {
        var offsets = MergeTable(repeating: 0)
        /// `FirstInstance::canRemove` (`:603`) per bucket: whether this zero-valued length may be
        /// dropped.
        var canRemove = MergeFlags(repeating: false)
        /// `childrenToRemoveFromMerges` (`:641`).
        var merges = 0
        /// `childrenToRemoveTotal` (`:642`).
        var removeTotal = 0

        /// `if ((firstInstance.offset - 1) == i && !firstInstance.canRemove)` (`:699`), the C++'s own
        /// survivor test, plus its non-`Numeric` arm. Unlike `Min`/`Max` there is no unrecorded-unit
        /// case: `simplify(Sum&)` records every `Numeric` term, which is why its condition has no
        /// `!offset` half.
        @inline(always)
        func survives(_ index: Int, _ folded: Span<Fold>) -> Bool {
            guard case .leaf(let leaf) = folded[index] else {
                return true
            }
            let key = mergeKey(leaf)
            return Int(offsets[key]) - 1 == index && !canRemove[key]
        }
    }

    /// Steps 8.2 to 8.4's first phase (`:607`-`:649`): `mergePlan` for `Sum`, differing in that it
    /// tracks removals as well as merges, recomputes `canRemove` from the merged value on every merge
    /// rather than accumulating it, and has no percentage skip (`Sum` merges percentages
    /// unconditionally, unlike `Min`/`Max`).
    ///
    /// Merges into the term list, as `mergePlan` does and for the same reason.
    ///
    /// Accumulation runs in term index order because `+` is not associative:
    /// `calc(1e300px + 1px + -1e300px)` depends on it.
    func sumMergePlan(
        _ folded: inout UniqueArray<Fold>,
        _ builder: borrowing WebCore.CSSCalc.CSSCalcSwiftBuilder
    ) -> SumMergePlan {
        var plan = SumMergePlan()
        // `childrenToRemoveTotal`'s second half (`:647`), kept as a running count of buckets whose
        // `canRemove` is currently set, since `canRemove` is assigned and can go back to false.
        var removableBuckets = 0

        for i in 0..<folded.count {
            // `[](const auto&) { }` (`:635`): a non-`Numeric` term is never eligible for merge or
            // removal, so it always survives.
            guard case .leaf(let leaf) = folded[i] else {
                continue
            }

            let key = mergeKey(leaf)
            // See `mergePlan` on why a non-leaf at the recorded offset re-seats the bucket rather
            // than dropping through.
            if plan.offsets[key] != 0, case .leaf(let first) = folded[Int(plan.offsets[key]) - 1] {
                let merged = CalcExecutor.sum(first.value, leaf.value)
                folded[Int(plan.offsets[key]) - 1] = .leaf(first.withValue(merged))
                plan.merges += 1
                // `firstInstance.canRemove = canRemoveIfZero && !mergedValue;` (`:624`), spelled as
                // `if`/`else` rather than `&&` because `&&`'s autoclosure right operand cannot capture
                // a `borrowing` parameter. This is an assignment, not an accumulation: a bucket made
                // removable by an earlier merge must be cleared when a later merge lands non-zero.
                let removable: Bool
                if merged == 0 {
                    removable = lengthRemovalAllowed(leaf, builder)
                } else {
                    removable = false
                }
                if removable != plan.canRemove[key] {
                    removableBuckets += removable ? 1 : -1
                    plan.canRemove[key] = removable
                }
                continue
            }

            // `firstInstances[id] = { .offset = i + 1, .merges = 0, .canRemove = canRemoveIfZero
            // && !child.value }` (`:629`-`:633`).
            plan.offsets[key] = Int32(i + 1)
            // `&&` would capture `builder` in an autoclosure; see the merge arm above.
            let removable: Bool
            if leaf.value == 0 {
                removable = lengthRemovalAllowed(leaf, builder)
            } else {
                removable = false
            }
            if removable != plan.canRemove[key] {
                removableBuckets += removable ? 1 : -1
                plan.canRemove[key] = removable
            }
        }

        // `childrenToRemoveTotal += firstInstance.merges + (firstInstance.canRemove ? 1 : 0)`
        // (`:647`), summed over buckets. The C++'s loop over the whole table is what the two running
        // counts replace.
        plan.removeTotal = plan.merges + removableBuckets

        return plan
    }

    // MARK: `Product`'s flattened factor list

    /// One surviving factor of a `Product`, as values -- a borrowed `Child` is `~Copyable`, so no
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
    struct ProductFactorList: ~Copyable {
        /// The non-`<number>` factors, in order. This is the C++'s `newChildren` BEFORE `:798`
        /// appends the merged number, which is the list 9.3's arity test is about.
        ///
        /// `UniqueArray`, and the reason this type is `~Copyable`: same argument as `SumTermList`'s.
        /// It also removes a second buffer that used to be built per `Product` -- `foldProduct` took
        /// `var finalFactors = factors.survivors` and appended to it, which is a copy-on-write buffer
        /// duplicated in full the moment step 9.2 had a number to append. `foldProduct` now appends in
        /// place, which a uniquely-owned buffer makes safe by construction.
        var survivors = UniqueArray<ProductFactor>()
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
        _ node: borrowing WebCore.CSSCalc.Child,
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
            let folded = fold(node[Int(index)], builder)
            if case .declined = folded {
                out.declined = folded
                return out
            }

            if isSpliceableProduct(folded) {
                // 9.1. `for (auto& childProductChild : (*childProduct)->children) processChild(...)`.
                out.spliced = true
                let childInfo = WebCore.CSSCalc.swiftNodeInfo(node[Int(index)])
                let spliced = productFactors(node[Int(index)], childInfo.childCount, &origin, builder)
                if let declined = spliced.declined {
                    out.declined = declined
                    return out
                }
                // Appended one at a time through the child's `Span`: `UniqueArray` is noncopyable, so
                // there is no `append(contentsOf:)` over another one of itself to reach for, and this
                // is the same element-wise copy that spelling would have done.
                let splicedSurvivors = spliced.survivors.span
                for k in splicedSurvivors.indices {
                    out.survivors.append(splicedSurvivors[k])
                }
                if let childProduct = spliced.numericProduct {
                    out.numericProduct = multipliedNumericProduct(childProduct, out.numericProduct)
                }
            } else if case .leaf(let leaf) = folded, leaf.kind == .number {
                // 9.2 (`:733`-`:737`).
                out.numericProduct = multipliedNumericProduct(leaf.value, out.numericProduct)
                origin += 1
            } else if let factor = classifyProductFactor(node[Int(index)], folded, origin, builder) {
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
        _ child: borrowing WebCore.CSSCalc.Child,
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
                let inner = fold(child[0], builder)
                if case .leaf(let leaf) = inner {
                    return ProductFactor(fold: folded, origin: origin, invertedLeaf: leaf, numericSum: false)
                }
                return ProductFactor(fold: folded, origin: origin, invertedLeaf: nil, numericSum: false)
            }
            if alternative == .Sum {
                // `std::ranges::all_of(sum->children, isNumeric)` (`:769`) over the child's final,
                // post-splice list -- see `hasOnlyNumericChildren`.
                return ProductFactor(
                    fold: folded,
                    origin: origin,
                    invertedLeaf: nil,
                    numericSum: hasOnlyNumericChildren(child, folded, builder)
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
    func rewrite(
        _ node: borrowing WebCore.CSSCalc.Child,
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
            return rewrite(node[Int(child)], &builder)

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
            if alternative == .CalcMix {
                // A `calc-mix()`'s survivors are its children, as `Min`'s and `Max`'s are. It needs its
                // own pass for the weights, which are not operands and which `rebuildFrom` consumes from a
                // second stack. See `rewriteCalcMixItems`.
                return rewriteCalcMixItems(node, &builder)
            }
            return rewriteMergedChildren(node, alternative, &builder)

        case .replacedByGrandchild(let child, let grandchild):
            // `Negate`'s rule 6.2 and `Invert`'s rule 7.2: `return { WTF::move(a->a) }`, one level
            // deeper than `.replacedByTerm`. Chained subscripts: each yields a borrow of the one
            // before it, which the old `~Escapable` handle could not express -- it needed an
            // intermediate `let`, and a `let` is exactly what a borrowed `Child` cannot be bound to.
            return rewrite(node[Int(child)][Int(grandchild)], &builder)

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
    /// `hasOnlyNumericChildren` guarantees every final child is numeric.
    ///
    /// The unary minus (`:934`, `:949`: `child.value = -child.value`) flips a NaN's sign bit rather
    /// than propagating it -- not the same as `* -1.0`; see `Fold.scaledSumChildren`.
    func rewriteNegatedChildren(
        _ node: borrowing WebCore.CSSCalc.Child,
        _ builder: inout WebCore.CSSCalc.CSSCalcSwiftBuilder
    ) -> Rewrite {
        // Hoisted, so that the fold's read of `builder` finishes before `pushNumericChildren` takes it
        // `inout`.
        let folded = fold(node[0], builder)
        // Counted by `pushNumericChildren` rather than narrowed from a list's `count`: `rebuildFrom`
        // wants a `UInt32`, and this is the number actually pushed.
        switch pushNumericChildren(node[0], folded, .negated, &builder) {
        case .notAllNumeric:
            // Unreachable: `fold` returned `.negatedChildren`, which it does only after
            // `hasOnlyNumericChildren` answered true over this same walk. Checked rather than
            // asserted, so that a boundary that came apart is a fallback to the C++ arm and not a node
            // rebuilt from operands that were never pushed.
            return .declined(.Negate)

        case .pushRefused:
            // A contract violation, as in `rewrite`'s `.leaf` arm: the leaf was synthesised in
            // `pushNumericChildren`, so there is no input alternative to blame.
            return .declined(nil)

        case .pushed(let pushed):
            // `rebuildSlot(const Children&)` takes all remaining operands and ignores the original's
            // count, which is what lets the arity change.
            return builder.rebuildFrom(node[0], pushed) ? .pushed : .declined(.Negate)
        }
    }

    /// `rebuild` for a surviving `anchor()`/`anchor-size()`: the fallback is the only operand, and the
    /// `<anchor-side>` subtree is deliberately not one, since the C++ copies rather than simplifies it
    /// (`copyAndSimplifyChildren(const IndirectNode<Anchor>&)`, `.side = copy(anchor->side)`, `:1797`)
    /// -- `anchor(--a calc(25% + 25%))` keeps its unfolded `Sum`, and folding it would be wrong. The
    /// side comes off the original inside `rebuildFrom` through the same `CSSCalc::copy`.
    ///
    /// The coverage walk still descends into the side, so an untaught alternative there declines the
    /// whole tree -- conservative, since the C++ arm would have copied it regardless.
    func rebuildAnchor(
        _ node: borrowing WebCore.CSSCalc.Child,
        _ alternative: CalcAlternative,
        _ builder: inout WebCore.CSSCalc.CSSCalcSwiftBuilder
    ) -> Rewrite {
        let operation = WebCore.CSSCalc.swiftOperationInfo(node)

        // Named `pushedFallback`, not `pushed`: the selftest's control asserts each `pushed`-style
        // counter name is unique in the file, and a second `pushed` would collide with
        // `rewriteNegatedChildren`'s.
        var pushedFallback: UInt32 = 0
        if operation.hasFallback {
            let fallback = rewrite(node[Int(anchorFallbackIndex(alternative, operation))], &builder)
            if case .declined(let blame) = fallback {
                return .declined(blame)
            }
            pushedFallback = 1
        }

        return builder.rebuildFrom(node, pushedFallback) ? .pushed : .declined(alternative)
    }

    /// `convertToMin`/`convertToMax` (`+Simplification.cpp:1018`-`:1044`): a fresh `min()`/`max()`
    /// over `clamp()`'s two surviving arguments, via `buildOperation`, the boundary's construction
    /// entry for a node with no original to rebuild from.
    ///
    /// A `false` from `buildOperation` declines the whole tree rather than rebuilding the `Clamp`: by
    /// that point two operands are already pushed where the parent expects one, and there is no `pop`.
    /// Exact regardless, since the C++ arm then rebuilds the `Clamp` itself. Expected never to fire in
    /// practice, since the parser's own type check should make the mismatch unreachable.
    func rewriteConvertedMinMax(
        _ node: borrowing WebCore.CSSCalc.Child,
        _ isMax: Bool,
        _ builder: inout WebCore.CSSCalc.CSSCalcSwiftBuilder
    ) -> Rewrite {
        var index: UInt32 = 0
        while index < 2 {
            if case .declined(let blame) = rewrite(node[Int(index)], &builder) {
                return .declined(blame)
            }
            index += 1
        }
        return builder.buildOperation(isMax ? .Max : .Min, 2) ? .pushed : .declined(.Clamp)
    }

    /// The `.mergedChildren` half of `rewrite`: `simplifyForMinMax`'s phase 2 (`:458`-`:479`). The
    /// merge plan is recomputed here rather than carried on `Fold`, trading a re-walk for avoiding a
    /// heap allocation on every node's `Fold` value.
    ///
    /// A `Numeric` survivor is pushed as a leaf rather than re-rewritten -- required, not an
    /// optimisation, since a merged first instance's value is `evaluate(...)`'s result and exists
    /// nowhere in the input tree.
    func rewriteMergedChildren(
        _ node: borrowing WebCore.CSSCalc.Child,
        _ alternative: CalcAlternative,
        _ builder: inout WebCore.CSSCalc.CSSCalcSwiftBuilder
    ) -> Rewrite {
        let info = WebCore.CSSCalc.swiftNodeInfo(node)
        return withFoldedChildren(node, info.childCount, builder) { folded -> Rewrite in
            let plan = mergePlan(&folded, alternative == .Max)

            // Carried as a `UInt32` beside the iteration rather than converted from the buffer's `Int`:
            // the child subscript wants an `Int`.
            var index: UInt32 = 0
            var survivors: UInt32 = 0
            for i in 0..<folded.count {
                defer { index += 1 }
                guard plan.survives(i, folded.span) else {
                    continue
                }
                // A surviving `Numeric` carries the merged value, which exists nowhere in the input tree,
                // so it is pushed as a leaf rather than re-rewritten.
                if case .leaf(let accumulated) = folded[i] {
                    guard builder.pushLeaf(accumulated.boundaryLeaf) else {
                        // A contract violation: the leaf is synthesised here, so there is no input
                        // alternative to blame.
                        return .declined(nil)
                    }
                } else if case .declined(let blame) = rewrite(node[Int(index)], &builder) {
                    return .declined(blame)
                }
                survivors += 1
            }

            // Expressed as a count: `rebuildSlot` takes all remaining operands, which is what lets
            // the arity change.
            return builder.rebuildFrom(node, survivors) ? .pushed : .declined(alternative)
        }
    }

    /// The `.mergedChildren(.Sum)` half of `rewrite`: step 8.1 and its consuming loop (`:689`-`:711`).
    /// Separate from `rewriteMergedChildren` because a `Sum`'s survivors are not its children -- step
    /// 8.1 flattened the list, so a survivor can be a grandchild or deeper, reached through
    /// `pushSumTerm`'s ordinal re-walk.
    ///
    /// The count can go up as well as down: `calc(1px + (1em + 1%))` arrives with two children and
    /// rebuilds with three. `rebuildSlot` takes all remaining operands regardless of direction.
    func rewriteSumChildren(
        _ node: borrowing WebCore.CSSCalc.Child,
        _ builder: inout WebCore.CSSCalc.CSSCalcSwiftBuilder
    ) -> Rewrite {
        let info = WebCore.CSSCalc.swiftNodeInfo(node)
        var origin: UInt32 = 0
        var terms = collectSumTerms(node, info.childCount, &origin, builder)
        if case .declined(let blame) = terms.declined {
            // Unreachable in practice; checked rather than asserted so a broken boundary falls back
            // to the C++ arm.
            return .declined(blame)
        }
        let plan = sumMergePlan(&terms.folds, builder)

        var survivors: UInt32 = 0
        for k in 0..<terms.folds.count where plan.survives(k, terms.folds.span) {
            if case .leaf(let accumulated) = terms.folds[k] {
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
    func rewriteSumTerm(
        _ node: borrowing WebCore.CSSCalc.Child,
        _ origin: UInt32,
        _ builder: inout WebCore.CSSCalc.CSSCalcSwiftBuilder
    ) -> Rewrite {
        let info = WebCore.CSSCalc.swiftNodeInfo(node)
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
    func pushSumTerm(
        _ node: borrowing WebCore.CSSCalc.Child,
        _ childCount: UInt32,
        _ target: UInt32,
        _ counter: inout UInt32,
        _ builder: inout WebCore.CSSCalc.CSSCalcSwiftBuilder
    ) -> Rewrite? {
        var index: UInt32 = 0
        while index < childCount {
            let folded = fold(node[Int(index)], builder)
            if case .declined(let blame) = folded {
                return .declined(blame)
            }
            if isSpliceableSum(folded) {
                let childInfo = WebCore.CSSCalc.swiftNodeInfo(node[Int(index)])
                if let found = pushSumTerm(node[Int(index)], childInfo.childCount, target, &counter, &builder) {
                    return found
                }
            } else {
                if counter == target {
                    // `rewrite` on the term pushes exactly one operand, which is what the collapsed
                    // `Sum` owes its parent.
                    return rewrite(node[Int(index)], &builder)
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
    func rewriteProductChildren(
        _ node: borrowing WebCore.CSSCalc.Child,
        _ builder: inout WebCore.CSSCalc.CSSCalcSwiftBuilder
    ) -> Rewrite {
        let info = WebCore.CSSCalc.swiftNodeInfo(node)
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
        let survivors = factors.survivors.span
        for survivorIndex in survivors.indices {
            let factor = survivors[survivorIndex]
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
    func rewriteScaledSumFactor(
        _ node: borrowing WebCore.CSSCalc.Child,
        _ origin: UInt32,
        _ factor: Double,
        _ builder: inout WebCore.CSSCalc.CSSCalcSwiftBuilder
    ) -> Rewrite {
        let info = WebCore.CSSCalc.swiftNodeInfo(node)
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
    func pushProductFactor(
        _ node: borrowing WebCore.CSSCalc.Child,
        _ childCount: UInt32,
        _ target: UInt32,
        _ scale: Double?,
        _ counter: inout UInt32,
        _ builder: inout WebCore.CSSCalc.CSSCalcSwiftBuilder
    ) -> Rewrite? {
        var index: UInt32 = 0
        while index < childCount {
            let folded = fold(node[Int(index)], builder)
            if case .declined(let blame) = folded {
                return .declined(blame)
            }
            if isSpliceableProduct(folded) {
                let childInfo = WebCore.CSSCalc.swiftNodeInfo(node[Int(index)])
                if let found = pushProductFactor(node[Int(index)], childInfo.childCount, target, scale, &counter, &builder) {
                    return found
                }
            } else {
                if counter == target {
                    guard let scale else {
                        // `rewrite` on the factor pushes exactly one operand, which is what the
                        // rebuilt `Product` owes for this slot.
                        return rewrite(node[Int(index)], &builder)
                    }
                    return pushScaledSum(node[Int(index)], folded, scale, &builder)
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
    /// Every child is a leaf whenever this runs, by `hasOnlyNumericChildren`'s own guard -- which is
    /// what
    /// lets this be a straight push loop with no `pushSumTerm` for a non-`Numeric` survivor.
    func pushScaledSum(
        _ sum: borrowing WebCore.CSSCalc.Child,
        _ folded: Fold,
        _ scale: Double,
        _ builder: inout WebCore.CSSCalc.CSSCalcSwiftBuilder
    ) -> Rewrite {
        switch pushNumericChildren(sum, folded, .scaled(scale), &builder) {
        case .notAllNumeric:
            // Unreachable: `fold` produced `.scaledSumChildren` only after `hasOnlyNumericChildren`
            // answered true over this same walk. Checked rather than asserted, for the reason
            // `rewriteNegatedChildren` gives.
            return .declined(.Product)

        case .pushRefused:
            // A contract violation: the leaf was synthesised in `pushNumericChildren`, so there is no
            // input alternative to blame.
            return .declined(nil)

        case .pushed(let pushedChildren):
            return builder.rebuildFrom(sum, pushedChildren) ? .pushed : .declined(.Product)
        }
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
    func rebuild(
        _ node: borrowing WebCore.CSSCalc.Child,
        _ alternative: CalcAlternative,
        _ builder: inout WebCore.CSSCalc.CSSCalcSwiftBuilder
    ) -> Rewrite {
        let info = WebCore.CSSCalc.swiftNodeInfo(node)

        if alternative == .Anchor || alternative == .AnchorSize {
            // The two alternatives whose children are answered by hand at the boundary, and whose
            // `<anchor-side>` child must not be pushed as an operand. See `rebuildAnchor`.
            return rebuildAnchor(node, alternative, &builder)
        }

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
            let child = rewrite(node[Int(index)], &builder)
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

/// Which alternatives the FLAT simplifier covers, as a mask over the same alternative index
/// `kindMask` is built from.
///
/// Built from the alternative list rather than written as a hex literal, so teaching the flat
/// simplifier a new alternative is one name added here and the two cannot drift: the raw values come
/// from the imported C++ enum, which is generated from `CSS_CALC_SWIFT_FOR_EACH_ALTERNATIVE`.
///
/// A computed `static var`, not a `static let`: a stored global is lazily initialised behind a
/// `swift_once` guard, which is an atomic load on every simplification, and every term here is a
/// compile-time constant so the optimizer folds the whole expression to one immediate.
///
/// `NonCanonicalDimension` is here because `simplifyNonCanonicalDimension` ports
/// `simplify(NonCanonicalDimension&)` (`+Simplification.cpp:506`-`:514`) in full, upcall included.
/// It was absent until then for a reason worth keeping in view: letting one through without
/// `canonicalize` would COPY the node where the C++ converts it -- a silent wrong answer rather than
/// a decline. Adding an alternative here means porting its `simplify`, not editing this list.
private enum CalcFlatCoverage {
    @inline(always)
    static func bit(_ alternative: CalcAlternative) -> UInt64 {
        return UInt64(1) << UInt64(alternative.rawValue)
    }

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
    }
}

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
    _ root: borrowing WebCore.CSSCalc.Child,
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

    let simplification = CalcSimplification(
        percentageResolveToDimension: options.percentageResolveToDimension,
        allowZeroValueLengthRemovalFromSum: options.allowZeroValueLengthRemovalFromSum,
        category: options.category
    )

    // THE FLAT PATH, taken whenever every alternative in the tree is one it implements.
    //
    // No gate, no new C++, and no option selecting it: the two simplifiers are two ports of the same
    // spec, so a build flag choosing between them would mean the differential only ever exercised one
    // of them. The tree itself decides instead -- `kindMask` already says which alternatives are
    // present and a subset test is one `and` -- so `simplifycheck` runs the flat path on every
    // qualifying corpus case, and ANY disagreement with the C++ fails the differential rather than
    // waiting for someone to flip a flag.
    //
    // Coverage cannot regress from this. A tree holding any of the other 31 alternatives falls through
    // to the two-pass `rewrite` below unchanged, and `walk` has already refused outright any tree
    // holding one that neither port handles -- so the flat path is only ever reached for a tree the
    // two-pass port would have finished too. What it can do is DIVERGE, which is the point of routing
    // it here rather than leaving it behind a flag nothing sets.
    if kindMask & ~CalcFlatCoverage.mask == 0 {
        let emitted = withCalcFlatTree(root, nodeCount) { tree -> Bool in
            tree.simplify(simplification, builder)
            return tree.emit(0, into: &builder)
        }
        guard emitted else {
            // `emit` returning false is `buildOperation` refusing, and that has no one alternative to
            // blame: it is either a builder contract violation or `toType` answering `std::nullopt`
            // for children whose types do not merge -- and in that second case the C++ arm returns
            // `std::nullopt` from its own rewrite too. Reported the way the two-pass path reports its
            // own blameless decline, `.declined(nil)`.
            return declined(kindMask, nodeCount, nil)
        }
        return WebCore.CSSCalc.CSSCalcSwiftSimplificationResult(
            kindMask: kindMask,
            nodeCount: nodeCount,
            outcome: CSSCalcSwiftSimplificationOutcome.simplified.rawValue,
            declineAlternative: noDeclineAlternative
        )
    }

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
public func cssCalcCanSimplifySwift(_ root: borrowing WebCore.CSSCalc.Child) -> Bool {
    switch WebCore.CSSCalc.swiftNodeInfo(root).alternative {
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

// MARK: - `calc-mix()` -- A6

/// What `simplify(CalcMix&)`'s weight normalisation (spec steps 1 to 5) did to the item list, as
/// values -- the plan half of the file's fold -> plan -> single-consuming-pass shape.
///
/// The C++ mutates `item.weight` in place at four sites (`+Simplification.cpp:1552`, `:1560`, `:1579`,
/// `:1608`) and moves out of a live vector at five (`:1524`, `:1554`, `:1581`, `:1599`, plus the
/// `root.children = WTF::move(newChildren)` that follows each) -- the same shape `simplifyForMinMax`
/// has, and Swift has no moved-from state to mirror it, so the whole of steps 1 to 5 runs over values
/// here and the tree is touched exactly once, by `rewriteCalcMixItems`.
///
/// A `struct` of arrays rather than a `Fold` payload, for the reason `Fold.negatedChildren` gives: a
/// dynamically-sized plan on a `Fold` value constructed for every node at every level would be a heap
/// allocation. `rewrite` re-derives this plan instead.
///
/// `~Copyable`, because `survivors` is a `UniqueArray`: the plan is scratch owned by exactly one
/// `calc-mix()` fold, is never shared, and every copy of it would be a copy of that buffer. Making
/// the struct noncopyable is what lets the buffer be `UniqueArray` rather than `Array`, and that in
/// turn is what takes the retain/release pair off every hand-off of the plan -- a `[Survivor]`
/// crossing a function boundary is a `swift_bridgeObjectRetain`/`Release` pair per `calc-mix()` node
/// even when nothing mutates it.
private struct CalcMixPlan: ~Copyable {
    /// One surviving item, in item order.
    struct Survivor {
        /// The item's index in the original item list -- which is also its child index, because
        /// `forAllChildNodes`'s hand-written `CalcMix` overload (CSSCalcTree+Traversal.h:127) yields each
        /// item's `value` once in item order and yields nothing for a weight.
        let index: UInt32
        /// What the item's `value` folded to. Carried rather than looked up by index, so that the
        /// accumulator needs no `UInt32` -> `Int` narrowing to justify.
        let fold: Fold
        /// The item's effective weight as a `<percentage>`, which is what the accumulator divides by
        /// 100 (`:1622`).
        ///
        /// Meaningful only where `canNormalize` held, which is exactly where the accumulator runs: the
        /// `!canNormalize` path returns before it (`:1528`), and 0 here for a `Calc` weight is the same
        /// inert value the boundary reports rather than a claim about what the `calc()` evaluates to.
        let weight: Double
        /// Whether the rebuild carries `weight` -- spec step 2's `(100% - specified sum) / n` or step 4's
        /// `weight * 100% / total` -- or the original item's own weight, unchanged.
        ///
        /// `false` is not an optimisation, it is the only spelling of two of the C++'s paths:
        /// `:1573`-`:1582` leaves a present non-omitted weight alone while removing other items, and
        /// `:1594`-`:1600` leaves every survivor's weight alone. A survivor of either can hold a `Calc`
        /// weight, a whole `CSSCalcValue` this cannot reproduce. See `pushCalcMixItemWeight`.
        let replaceWeight: Bool
    }

    /// In item order, which is the order `Vector<CalcMix::Item>` is rebuilt in.
    ///
    /// `UniqueArray` (SE-0527), not `Array`: a uniquely-owned, non-copy-on-write buffer, so there is
    /// no uniqueness check on `append`, no defensive copy, and no refcount on the buffer object at
    /// all. Nothing here is ever shared -- see the type's own note.
    var survivors = UniqueArray<Survivor>()

    /// A `Fold` to return instead of running the accumulator.
    ///
    /// Three things reach it, and all three are the C++ returning before `:1619`: the `!canNormalize`
    /// path's two rebuilds (`:1528`, reached whether or not it removed anything), and
    /// `zeroValueMatchingChild` (`:1516`, `:1589`), which is a fold to a leaf. A decline can also land
    /// here, from `zeroValueMatchingChild` on a child this cannot type.
    var early: Fold?

    /// The first child that declined, as the `Fold` to return -- same shape as `declinedChild`.
    ///
    /// Carried beside `early` rather than in it, because `calcMixPlan` can also set `early` to a
    /// decline of its own and the two are answered with different blame. It is a field rather than
    /// the second half of a returned tuple because the plan is now `~Copyable`, and a tuple is the
    /// one place that would have to be too.
    var decliningChild: Fold?
}

/// What `calcMixPlan`'s counting loop learned about the weight list, as values.
///
/// Four scalars in one struct so that the loop can live inside a `withTemporaryAllocation` closure
/// and still hand its results to `calcMixPlanFromWeights` without a seven-parameter call.
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

private extension CalcSimplification {

    /// `simplify(CalcMix&)` (`+Simplification.cpp:1445`-`:1690`), the largest body in the file.
    ///
    /// Two halves: steps 1-5 normalise weights and drop zero/omitted items, as values (`calcMixPlan`);
    /// then a weighted sum over an accumulator every item must agree with (`calcMixSum`).
    ///
    /// The sum failing is a rebuild, not a decline: `:1681` returns `nullopt` from a `simplify` that
    /// already mutated `root.children`, so the C++ rebuilds with the normalised weights --
    /// `calc-mix(10% 25%, 10px 75%)` keeps its `calc-mix()` with explicit weights rather than
    /// declining. Every rebuild is `.mergedChildren(.CalcMix)`; `.unchanged` is never produced, since
    /// `rebuildSlot` takes each item's weight from the pushed plan and a generic `rebuild` would leave
    /// that stack out of step.
    func foldCalcMix(
        _ node: borrowing WebCore.CSSCalc.Child,
        _ info: WebCore.CSSCalc.CSSCalcSwiftNodeInfo,
        _ builder: borrowing WebCore.CSSCalc.CSSCalcSwiftBuilder
    ) -> Fold {
        // `copyAndSimplify(const CalcMix::Item&)` (`:1753`-`:1756`) simplifies each item's `value` before
        // `simplify(root)` ever runs, so every weight decision below is made against the simplified
        // children -- which is what makes `zeroValueMatchingChild`'s `getType(child.value)` a question
        // about a folded subtree rather than about the parsed one.
        // The plan outlives the folded children (`calcMixSum` reads only the plan), so the scoped
        // buffer ends here rather than wrapping the whole body.
        let plan = withFoldedChildren(node, info.childCount, builder) { folded -> CalcMixPlan in
            if let declined = declinedChild(folded.span) {
                return CalcMixPlan(early: declined)
            }
            return calcMixPlan(node, info.childCount, folded.span)
        }
        if let early = plan.early {
            return early
        }
        return calcMixSum(plan)
    }

    /// Spec steps 1 to 5 (`+Simplification.cpp:1447`-`:1611`), as a plan.
    ///
    /// The counting loop matches the C++ exactly, including what it does not do: `total` accumulates
    /// every `Raw` weight in item order including the zeros, so its rounding is the C++'s addition
    /// sequence; `!raw.value` is a test against zero that is true for `-0.0` and false for a NaN, and
    /// `== 0` is the same on both counts; and `isKnownZero()` is `isRaw() && value == 0`
    /// (CSSPrimitiveNumeric.h:142), so a `Calc` weight is never counted however it would evaluate. The
    /// boundary reports the three states this needs and nothing is re-derived.
    ///
    /// The weight list is read once per item and carried, rather than re-crossing the boundary in
    /// each of the six branches of `calcMixPlanFromWeights`: `calcMixItemWeight` walks to the item,
    /// and the branches ask about the same three fields up to twice each. It is carried in ONE
    /// `withTemporaryAllocation` buffer of the boundary's own record (SE-0524), not in the three
    /// parallel `[Bool]`/`[Bool]`/`[Double]` heap arrays this used to build: the list is sized
    /// exactly by `itemCount`, dead when the plan is returned, and never escapes, which is that
    /// facility's exact shape. Three heap allocations and three `swift_bridgeObjectRelease`s per
    /// `calc-mix()` node become none.
    func calcMixPlan(
        _ node: borrowing WebCore.CSSCalc.Child,
        _ itemCount: UInt32,
        _ folded: Span<Fold>
    ) -> CalcMixPlan {
        // `Int(clamping:)`, not `Int(_:)`, which traps if `Int` is narrower than `UInt32`; the
        // capacity is a bound here and not a hint, and the loop appends exactly `itemCount` times.
        return withTemporaryAllocation(
            of: WebCore.CSSCalc.CSSCalcSwiftCalcMixWeight.self,
            capacity: Int(clamping: itemCount)
        ) { weights in
            var survey = CalcMixWeightSurvey()

            var index: UInt32 = 0
            while index < itemCount {
                let weight = WebCore.CSSCalc.swiftCalcMixItemWeight(node, index)
                weights.append(weight)

                if weight.present {
                    if weight.isRaw {
                        // `[&](const Weight::Raw& raw)` (`:1492`-`:1498`).
                        if weight.value == 0 {
                            survey.numberOfKnownZeroWeights += 1
                        }
                        survey.total += weight.value
                    } else {
                        // `[&](const Weight::Calc&)` (`:1499`-`:1501`).
                        survey.canNormalize = false
                    }
                } else {
                    survey.numberOfOmittedWeights += 1
                }
                index += 1
            }

            return calcMixPlanFromWeights(itemCount, folded, weights.span, survey)
        }
    }

    /// Steps 1 to 5's decision half, over the weights `calcMixPlan` already read.
    ///
    /// Split from the counting loop only so that the loop's scratch buffer is a
    /// `withTemporaryAllocation` and this body does not have to live inside its closure. `node` is
    /// deliberately not a parameter: every question left is about the weights and the folded values.
    func calcMixPlanFromWeights(
        _ itemCount: UInt32,
        _ folded: Span<Fold>,
        _ weights: Span<WebCore.CSSCalc.CSSCalcSwiftCalcMixWeight>,
        _ survey: CalcMixWeightSurvey
    ) -> CalcMixPlan {
        let canNormalize = survey.canNormalize
        let total = survey.total
        let numberOfOmittedWeights = survey.numberOfOmittedWeights
        let numberOfKnownZeroWeights = survey.numberOfKnownZeroWeights

        var index: UInt32 = 0
        // `item.weight && item.weight->isKnownZero()` is spelled inline at each of the four sites below
        // as `weights[i].present && weights[i].isRaw && weights[i].value == 0`, rather than hoisted
        // into a helper: every loop here is a `while` over a `UInt32` with no closure.
        var plan = CalcMixPlan()

        if !canNormalize {
            // `:1509`-`:1529`. Normalisation is off entirely and the C++ returns `{ }` on every path
            // out of this branch, so the accumulator never runs and every survivor keeps its own weight.
            if numberOfKnownZeroWeights == 0 {
                // `return { }` with `root.children` untouched: rebuilt at the same arity with the same
                // weights. Every `replaceWeight` is clear, which is the only spelling that can carry a
                // `Calc` weight through.
                calcMixKeepAll(itemCount, folded, into: &plan.survivors)
                plan.early = .mergedChildren(.CalcMix)
                return plan
            }

            if itemCount - numberOfKnownZeroWeights == 0 {
                // "If all the weights are known to be zero, we can simplify all the way down zero value
                // for the calc-mix itself." (`:1514`-`:1516`)
                plan.early = zeroValueMatchingChild(folded[0])
                return plan
            }

            // `:1518`-`:1526`: drop the known-zero items, leave every other weight alone.
            index = 0
            while index < itemCount {
                let i = Int(index)
                if !(weights[i].present && weights[i].isRaw && weights[i].value == 0) {
                    plan.survivors.append(CalcMixPlan.Survivor(
                        index: index,
                        fold: folded[i],
                        weight: weights[i].value,
                        replaceWeight: false
                    ))
                }
                index += 1
            }
            plan.early = .mergedChildren(.CalcMix)
            return plan
        }

        if total >= 100 {
            // `:1531`-`:1562`. Omitted weights become 0 and are removed, specified zeros are removed,
            // and every remaining weight is scaled -- so every survivor's weight is replaced, in both of
            // the C++'s two sub-branches. They differ only in whether anything is dropped, which the one
            // loop below expresses as "an omitted or known-zero item does not survive": with both counts
            // zero that condition is never true and the loop is `:1558`-`:1561`.
            let normalizationFactor = 100.0 / total
            index = 0
            while index < itemCount {
                let i = Int(index)
                if !weights[i].present || (weights[i].isRaw && weights[i].value == 0) {
                    index += 1
                    continue
                }
                plan.survivors.append(CalcMixPlan.Survivor(
                    index: index,
                    fold: folded[i],
                    // `item.weight->raw()->value * normalizationFactor` (`:1552`, `:1560`). The
                    // multiply is the C++'s, not a divide by `total / 100`: the two differ in the last
                    // bit.
                    weight: weights[i].value * normalizationFactor,
                    replaceWeight: true
                ))
                index += 1
            }
            return plan
        }

        // `:1563`-`:1611`, `total < 100`. `weightForOmitted` is step 2, and it is computed in both of
        // the two sub-branches that have omitted weights and in neither of the two that do not -- so it
        // is computed here and used only where the weight is absent, which cannot happen when the count
        // is zero.
        //
        // `Double(numberOfOmittedWeights)` is `static_cast<double>(numberOfOmittedWeights)`, and the
        // division is by the count of omitted weights rather than by the item count.
        let weightForOmitted = numberOfOmittedWeights > 0
            ? (100.0 - total) / Double(numberOfOmittedWeights)
            : 0.0

        if numberOfKnownZeroWeights > 0, numberOfOmittedWeights == 0 {
            // `:1584`-`:1601`. Nothing is rewritten; the known-zero items are dropped.
            if itemCount - numberOfKnownZeroWeights == 0 {
                plan.early = zeroValueMatchingChild(folded[0])
                return plan
            }
        }

        index = 0
        while index < itemCount {
            let i = Int(index)
            if weights[i].present {
                // `:1576`-`:1577`, `:1596`-`:1597`: a known-zero weight is dropped wherever there is
                // one to drop, and where `numberOfKnownZeroWeights` is 0 this is never true. A present,
                // non-zero weight is left exactly as it is in all four sub-branches -- `total < 100` has
                // no normalisation factor.
                if weights[i].isRaw, weights[i].value == 0, numberOfKnownZeroWeights > 0 {
                    index += 1
                    continue
                }
                plan.survivors.append(CalcMixPlan.Survivor(
                    index: index,
                    fold: folded[i],
                    weight: weights[i].value,
                    replaceWeight: false
                ))
            } else {
                // `item.weight = CalcMix::Item::Weight { weightForOmitted }` (`:1579`, `:1608`). Step 2,
                // and the item survives.
                plan.survivors.append(CalcMixPlan.Survivor(
                    index: index,
                    fold: folded[i],
                    weight: weightForOmitted,
                    replaceWeight: true
                ))
            }
            index += 1
        }
        return plan
    }

    /// Every item surviving with its own weight: the `!canNormalize`, nothing-to-remove rebuild.
    ///
    /// Fills the plan's list through `inout` rather than returning one. A returned list is a second
    /// heap buffer per `calc-mix()` node -- plus, back when it was an `Array`, ARC on the handoff,
    /// which is what `#ReturnTypeImplicitCopy` names; appending into the caller's list writes the only
    /// buffer there ever is. `reserveCapacity` is a total, not an increment, so it counts what the
    /// list already holds -- zero on the one path that calls this, and correct if that ever stops
    /// being true.
    @inline(always)
    func calcMixKeepAll(
        _ itemCount: UInt32,
        _ folded: Span<Fold>,
        into survivors: inout UniqueArray<CalcMixPlan.Survivor>
    ) {
        survivors.reserveCapacity(survivors.count + Int(clamping: itemCount))
        var index: UInt32 = 0
        while index < itemCount {
            survivors.append(CalcMixPlan.Survivor(
                index: index,
                fold: folded[Int(index)],
                weight: 0,
                replaceWeight: false
            ))
            index += 1
        }
    }

    /// `zeroValueMatchingChild` (`+Simplification.cpp:1454`-`:1482`): when every weight is known zero,
    /// `calc-mix()` folds to a zero of the first item's category. `getType` is answered via `leafType`
    /// for a folded leaf and declined for an operation (a recursive type computation this file can't
    /// run and no boundary accessor answers) -- a narrow, named gap: `calc-mix(sibling-index() 0%, 2 0%)`
    /// with no builder state hits it, `calc-mix(1em 0%, 2em 0%)` does not.
    @inline(always)
    func zeroValueMatchingChild(_ folded: Fold) -> Fold {
        guard case .leaf(let leaf) = folded else {
            return .declined(.CalcMix)
        }
        guard let childType = leafType(leaf),
              let category = childType.calculationCategory().value,
              // `.value = 0`, written as a literal in all ten of the C++'s arms -- positive zero, which
              // is what `makeChild(Number { .value = 0 })` builds.
              let zero = numericLeafForCategory(category, 0) else {
            return .declined(.CalcMix)
        }
        return .leaf(zero)
    }

    /// The weighted sum (`+Simplification.cpp:1613`-`:1689`): an accumulator every item must agree with
    /// on alternative AND that alternative's own identity (a `Percentage`'s hint, a
    /// `CanonicalDimension`'s dimension, a `NonCanonicalDimension`'s unit -- NOT just `unitsMatch`,
    /// which would pass two percentages with different hints). `std::nullopt` on disagreement is a
    /// rebuild, not a decline. Weight is `/ 100.0`, not `* 0.01` -- they differ in the last bit, which
    /// matters for signed zero and NaN.
    ///
    /// `borrowing`, and the survivor list is walked through its `Span` rather than by `for ... in`:
    /// `UniqueArray` is noncopyable and so is no `Sequence`, and a borrowed plan is read without the
    /// buffer changing hands. Taking the plan by value cost a retain/release of the survivor buffer
    /// per `calc-mix()` node back when it was an `Array`; it is now unrepresentable rather than
    /// merely avoided.
    func calcMixSum(_ plan: borrowing CalcMixPlan) -> Fold {
        var accumulated: NumericLeaf?

        let survivors = plan.survivors.span
        for survivorIndex in survivors.indices {
            let survivor = survivors[survivorIndex]
            // `auto weight = item.weight->raw()->value / 100.0;` (`:1622`). The dereference is
            // unconditional in the C++ and safe there for the reason it is safe here: every path that
            // reaches this loop left every survivor with a present `Raw` weight, and the one path that
            // does not -- `!canNormalize` -- returned at `:1528`.
            let weight = survivor.weight / 100.0

            guard case .leaf(let leaf) = survivor.fold else {
                return .mergedChildren(.CalcMix)
            }

            guard let current = accumulated else {
                accumulated = leaf.withValue(leaf.value * weight)
                continue
            }
            guard calcMixAccumulatorAgrees(current, leaf) else {
                return .mergedChildren(.CalcMix)
            }
            accumulated = current.withValue(current.value + leaf.value * weight)
        }

        guard let result = accumulated else {
            // No survivors, which `isSimplifiableAlternative` already refuses at the source: a
            // `CalcMix` with no items is where the C++ dereferences an empty `std::optional<Variant<...>>`
            // at `:1685`, and every path that can empty the list either folds through
            // `zeroValueMatchingChild` first or keeps at least the item whose weight took `total` to 100.
            // Rebuilt rather than asserted, which cannot be wrong.
            return .mergedChildren(.CalcMix)
        }
        return .leaf(result)
    }

    /// Whether the accumulator and this item are the same alternative and agree on that alternative's
    /// own identity. See `calcMixSum` for why this is not `unitsMatch`.
    @inline(always)
    func calcMixAccumulatorAgrees(_ current: NumericLeaf, _ leaf: NumericLeaf) -> Bool {
        guard current.kind == leaf.kind else {
            // `!WTF::holdsAlternative<T>(*result)`, all four arms.
            return false
        }
        switch leaf.kind {
        case .number:
            // `:1630`-`:1631` has no second test: `Number`'s only member is `value`.
            return true
        case .percentage:
            // `get<Percentage>(*result).hint != value.hint` (`:1643`). The boundary carries the hint as
            // `Type::PercentHintValue`'s underlying byte with 0 for none, so comparing the bytes is
            // comparing the values and no `PercentHint` has to be decoded to make the comparison.
            return current.percentHint == leaf.percentHint
        case .canonicalDimension:
            // `get<CanonicalDimension>(*result).dimension != value.dimension` (`:1656`), with the unit
            // standing in for the dimension: `toCSSUnit` is a bijection onto the six canonical units
            // (CSSCalcTree.h:992-:1000), so comparing units is comparing dimensions.
            return current.unitType == leaf.unitType
        case .nonCanonicalDimension:
            // `get<NonCanonicalDimension>(*result).unit != value.unit` (`:1669`), and here `unitType` IS
            // `unit` -- `toCSSUnit(const NonCanonicalDimension&)` is `root.unit` (CSSCalcTree.h:1011).
            return current.unitType == leaf.unitType
        }
    }
}

private extension CalcSimplification {

    /// The `.mergedChildren(.CalcMix)` half of `rewrite`: the single consuming pass for a `calc-mix()`
    /// that stays a `calc-mix()`.
    ///
    /// Separate from `rewriteMergedChildren` for one reason -- the weights. The survivors are the
    /// node's own children, as `Min`'s and `Max`'s are and unlike `Sum`'s spliced terms, so each is
    /// reached by `rewrite(node[Int(index)])` and nothing is pushed as a pre-folded leaf: a
    /// `calc-mix()` item's value is never merged with another item's, so there is no accumulated value
    /// that exists nowhere in the input tree.
    ///
    /// Operands first, then weights: a nested `calc-mix(calc-mix(1px, 2px) 50%, 3px 50%)` consumes its
    /// inner node's weights inside `rewrite`, so by the time this pushes its own the weight stack is
    /// back where it started and `rebuildFrom` finds exactly this node's `n` on top of both.
    func rewriteCalcMixItems(
        _ node: borrowing WebCore.CSSCalc.Child,
        _ builder: inout WebCore.CSSCalc.CSSCalcSwiftBuilder
    ) -> Rewrite {
        let info = WebCore.CSSCalc.swiftNodeInfo(node)
        // The declining child is reported in the plan's own `decliningChild`, not through
        // `plan.early`, which `calcMixPlan` can also set to a decline of its own -- and the two are
        // answered with different blame below. A tuple would be the other spelling and cannot be one:
        // `CalcMixPlan` is `~Copyable`.
        let plan = withFoldedChildren(node, info.childCount, builder) { folded -> CalcMixPlan in
            if let declined = declinedChild(folded.span) {
                return CalcMixPlan(decliningChild: declined)
            }
            return calcMixPlan(node, info.childCount, folded.span)
        }
        if case .declined(let blame)? = plan.decliningChild {
            // Unreachable: `fold` returned `.mergedChildren(.CalcMix)`, which it does only after this
            // same walk found no declining child. Checked rather than asserted, so that a boundary that
            // came apart is a fallback to the C++ arm and not a node rebuilt from a short list.
            return .declined(blame)
        }
        if let early = plan.early {
            // Only `.mergedChildren(.CalcMix)` routes here, and `calcMixPlan` sets `early` to exactly
            // that whenever the survivor list is the whole answer -- this is the `!canNormalize` rebuild
            // arriving with the plan it needs. Any other early answer would be a `zeroValueMatchingChild`
            // fold or a decline, and pushing its survivors as an item list would be a wrong tree.
            guard case .mergedChildren = early else {
                return .declined(.CalcMix)
            }
        }

        // Named `pushedItems`, not `pushed`: `rewriteNegatedChildren`'s counter is spelled `var
        // pushed: UInt32 = 0` and its selftest asserts that name's uniqueness across the file, so a
        // second `pushed` here would collide with that check instead of with the diagnostic it exists
        // for. `foldProduct`'s `pushedFactors`/`pushedChildren` and `rebuildAnchor`'s `pushedFallback`
        // follow the same rule.
        var pushedItems: UInt32 = 0
        for survivorIndex in plan.survivors.indices {
            if case .declined(let blame) = rewrite(node[Int(plan.survivors[survivorIndex].index)], &builder) {
                return .declined(blame)
            }
            pushedItems += 1
        }
        for survivorIndex in plan.survivors.indices {
            let survivor = plan.survivors[survivorIndex]
            builder.pushCalcMixItemWeight(survivor.index, survivor.weight, survivor.replaceWeight)
        }

        // `rebuildSlot(const Vector<CalcMix::Item>&)` takes all the remaining operands and one weight
        // plan each, so this serves a node that lost items and one that did not, and it is the line that
        // lets the arity change at all.
        return builder.rebuildFrom(node, pushedItems) ? .pushed : .declined(.CalcMix)
    }
}

// MARK: - PROBE (R151): what a Swift-owned FLAT tree costs to build
//
// Not on any production path. This exists to measure the gating number for flipping the calc tree
// to a Swift representation: if converting a `CSSCalc::Child` into a flat Swift array is cheap,
// then simplification can run as a reverse loop over that array -- no 41-way variant dispatch per
// access, no `UniqueRef<Op>` pointer chase per node, no per-node `Children` vector, no operand
// stack, and no boundary crossing per node at all. If conversion is expensive, the idea dies here.
//
// The pre-registered prediction, from a number already measured rather than a guess: the `walk`
// coverage pre-pass does exactly this traversal without building anything, and R144 fitted it at
// `95.4 + 141.9N + 5.02N^2` retired instructions, ~8% of the Swift arm. Conversion should land near
// that plus the stores, and it REPLACES the pre-pass rather than adding to it, because the same
// pass can compute `nodeCount`, `kindMask` and the decline predicate on the way through.

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
/// checked against the one list (`CSS_CALC_SWIFT_FOR_EACH_ALTERNATIVE`) and adding a 42nd
/// alternative is a compile error here rather than a silent passthrough.
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
/// A bitfield rather than four `Bool`s, so the node stays inside the 8-byte tail slot it shares with
/// `valueID`, `unitType`, `alternative` and `percentHint`, and the fifth predicate costs nothing.
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

fileprivate extension CalcFlatNode {
    /// The four numeric leaves -- the only alternatives that carry a foldable value.
    var isNumericLeaf: Bool {
        switch alternative {
        case .Number, .Percentage, .CanonicalDimension, .NonCanonicalDimension: return true
        default: return false
        }
    }

    /// This node as the boundary's leaf representation, or nil if it is not one of the four.
    ///
    /// The mapping is spelled out rather than taken from the two enums happening to agree on their
    /// first four raw values. They do agree today, and nothing holds them to it: `CSSCalcSwiftNodeKind`
    /// is the serializer's 20-case shape list and `CSSCalcSwiftAlternative` is the variant's 41-case
    /// index, and they are declared in different macro lists three hundred lines apart.
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

/// The whole flat tree: ONE buffer of `CalcFlatNode`, and nothing else.
///
/// `~Escapable`, because the storage is a `MutableSpan` over a buffer the caller owns rather than
/// anything this type allocates. That is the point -- see `withCalcFlatTree`, which sizes the buffer
/// from a node count the coverage walk has already computed and puts it on the stack. Nothing here
/// allocates, and there is no second buffer to keep in step.
///
/// Pre-order, so a parent's index is always LESS than any of its descendants'. That one property is
/// what makes simplification a plain reverse loop with no recursion and no work list: counting down
/// from `count - 1` reaches every child before its parent, which is exactly the order
/// `copyAndSimplify` recurses in (`+Simplification.cpp:1810` -- simplify the children, then look at
/// the node). The C++ visits each node once and so does this; the two-pass `fold`/`rewrite` port
/// beside it cannot, because it holds a read-only handle and a write-only builder and has nowhere to
/// put a simplified child.
///
/// The verified spelling, since three of the four obvious ones do not compile: the storage is taken
/// `consuming` with `@_lifetime(copy storage)`, not `inout`, which otherwise fails "missing
/// reinitialization of inout parameter after consume"; the attribute is `@_lifetime`, not
/// `@lifetime`; and it needs `-enable-experimental-feature Lifetimes`, which WebCore's Swift step
/// already passes. Reproducer: `~/src/webkit-swift-ports/cssprobe/flatstack/probe3.swift`.
fileprivate struct CalcFlatTree: ~Escapable, ~Copyable {
    var nodes: MutableSpan<CalcFlatNode>
    /// How many of `nodes` are live. The span is sized to the whole tree up front, so this only
    /// counts up during flattening and never moves afterwards.
    var count: Int

    @_lifetime(copy storage)
    init(storage: consuming MutableSpan<CalcFlatNode>) {
        self.nodes = storage
        self.count = 0
    }
}

fileprivate extension CalcFlatTree {
    /// Flatten `node`'s subtree in pre-order and return its index.
    ///
    /// One `swiftNodeInfo` crossing per node, and it is the last per-node read crossing anything
    /// makes: every pass downstream reads the flat array. The recursion is over the original
    /// `CSSCalc::Child` tree and is the only place that tree is walked.
    ///
    /// Tree order, not serialization order: `childAt` sorts a `Sum`'s and a `Product`'s children by
    /// unit for the serializer, which would silently permute a multi-unit sum here.
    mutating func flatten(_ node: borrowing WebCore.CSSCalc.Child, _ inheritedFlags: UInt8) -> UInt32 {
        let info = WebCore.CSSCalc.swiftNodeInfo(node)
        let me = count
        count += 1

        var flags = inheritedFlags
        switch info.kind {
        case .ClampWithNoneMinimum: flags |= CalcFlatNodeFlags.clampNoneMinimum
        case .ClampWithNoneMaximum: flags |= CalcFlatNodeFlags.clampNoneMaximum
        default: break
        }

        // A second crossing, taken only for the one alternative that needs it, on the same rule
        // `CSSCalcSwiftNode::operationInfo` states: `info()` runs for every node of every tree, and
        // this answers a question only `anchor()` asks.
        if info.alternative == .Anchor, !WebCore.CSSCalc.swiftOperationInfo(node).anchorSideIsKeyword {
            flags |= CalcFlatNodeFlags.anchorSideIsSubtree
        }

        // `getType(const Child&)` (CSSCalcTree.h:1053), the same accessor `copyAndSimplify` reads the
        // original's type through at `+Simplification.cpp:1821`. Nothing new was declared for this.
        //
        // NOT taken for the seven leaf alternatives, and that is not a micro-optimisation: a leaf's
        // `Type` is DISCARDED by construction. `ChildConstruction<T>::make(T&&, Type)` for a `Leaf`
        // ignores its `Type` argument entirely (CSSCalcTree.h:1016-1018), which is the same fact the
        // two-pass port's `pushCopyOf` comment rests on. Paying a crossing per leaf for a value
        // nothing can read is the shape this whole exercise exists to remove, and leaves are most of
        // a real calc tree's nodes.
        let carriesType: Bool
        switch info.alternative {
        case .Number, .Percentage, .CanonicalDimension, .NonCanonicalDimension,
             .Symbol, .SiblingCount, .SiblingIndex:
            carriesType = false
        default:
            carriesType = true
        }

        nodes[me] = CalcFlatNode(
            value: info.numericValue,
            type: carriesType ? WebCore.CSSCalc.getType(node) : CalcType(),
            firstChild: CalcFlatNode.noNode,
            nextSibling: CalcFlatNode.noNode,
            childCount: info.childCount,
            origin: UInt32(me),
            valueID: info.valueID,
            unitType: info.unitType,
            alternative: info.alternative,
            percentHint: info.percentHint,
            flags: flags)

        var previous = CalcFlatNode.noNode
        var index: UInt32 = 0
        while index < info.childCount {
            // Slot 0 of an `anchor()` with a subtree side IS that side. Everything under it is
            // marked, so the simplification pass skips the whole subtree on one bit test per node
            // rather than having to know where the boundary is.
            let sideRoot = (flags & CalcFlatNodeFlags.anchorSideIsSubtree) != 0 && index == 0
            let child = flatten(node[Int(index)], sideRoot ? flags | CalcFlatNodeFlags.insideAnchorSide : flags)
            if previous == CalcFlatNode.noNode {
                nodes[me].firstChild = child
            } else {
                nodes[Int(previous)].nextSibling = child
            }
            previous = child
            index += 1
        }
        return UInt32(me)
    }

    /// The `k`th child of node `i`, or nil if it has fewer than `k + 1`.
    ///
    /// O(k). Every hot caller walks the list instead; this is for the fixed operand slots, where `k`
    /// is 0, 1 or 2 and is a literal at the call site.
    func child(_ i: Int, _ k: Int) -> Int? {
        var cursor = nodes[i].firstChild
        var remaining = k
        while cursor != CalcFlatNode.noNode {
            if remaining == 0 { return Int(cursor) }
            remaining -= 1
            cursor = nodes[Int(cursor)].nextSibling
        }
        return nil
    }
}

/// Flatten `root` into a stack buffer and hand the tree to `body`.
///
/// `nodeCount` comes from the coverage walk, which has already visited exactly this node set and
/// allocated nothing to do it, so the buffer is sized exactly and no growth is possible.
///
/// `withTemporaryAllocation` (SE-0524) rather than any owned container, and that is the whole reason
/// the count is threaded in: a `UniqueArray` here was MEASURED at 617 retired instructions per
/// simplification, against the C++ arm's 127 for an entire single-node tree, so a per-call heap
/// buffer costs more than the pass it feeds. The stdlib falls back to the heap for a buffer too large
/// for the stack, so an adversarially wide tree degrades rather than overflowing.
///
/// `OutputSpan` is append-only, so the buffer is filled with a placeholder and then read back as a
/// `MutableSpan`. `flatten` writes every slot it will use exactly once before anything reads it, and
/// `count` bounds every read to the written prefix.
@inline(always)
fileprivate func withCalcFlatTree<R: ~Copyable>(
    _ root: borrowing WebCore.CSSCalc.Child,
    _ nodeCount: UInt32,
    _ body: (inout CalcFlatTree) -> R
) -> R {
    let capacity = Int(clamping: nodeCount)
    return withTemporaryAllocation(of: CalcFlatNode.self, capacity: capacity) { buffer in
        let blank = CalcFlatNode(
            value: 0, type: CalcType(), firstChild: CalcFlatNode.noNode,
            nextSibling: CalcFlatNode.noNode, childCount: 0, origin: 0, valueID: 0,
            unitType: 0, alternative: .Number, percentHint: 0, flags: 0)
        for _ in 0..<capacity {
            buffer.append(blank)
        }
        var tree = CalcFlatTree(storage: buffer.mutableSpan)
        _ = tree.flatten(root, 0)
        return body(&tree)
    }
}

// MARK: The flat simplifier
//
// COVERAGE: `Sum`, `Product`, `Negate`, `Invert`, `Min`, `Max` and the four numeric leaves, and
// nothing else. Every other alternative is left exactly as it arrived, which is the honest behaviour
// for a bounded port -- it is not a decline channel and must not be read as one.
// `CalcFlatCoverage.mask` is what keeps a tree holding one of the other 31 away from here; widening
// the two together is the work this representation exists to make possible.
//
// The six operations below are a full port of their `simplify` overloads, not a sketch: every arm
// the C++ has, in the C++'s own execution order, including the two arms of `simplify(Negate&)` and
// the `Sum`/`Invert` arms of step 9.3 that are "not stated in spec, but needed for tests", and
// including one arm that is a defect (see `distributeNumber`). Divergence from the C++ is the failure
// mode this whole exercise is measured by, so a rule that looks wrong is reproduced and annotated
// rather than corrected.
//
// WHAT MAKES IT DIFFERENT FROM THE TWO-PASS PORT, and it is the whole reason for the exercise: no
// recursion, no per-node crossing, no 41-way variant dispatch, no operand stack, and above all no
// re-folding. `flatten` builds the array in pre-order, so a parent's index is always LESS than its
// children's, and one backwards loop therefore visits every child exactly once before its parent --
// which is `copyAndSimplify`'s own shape, and the reason the C++ is exactly linear in depth where the
// two-pass port fits `953 + 2225d + 366d^2`.
//
// NOTHING HERE ALLOCATES. The tree is the one stack buffer `withCalcFlatTree` sized in advance; the
// `Sum` merge table is two `InlineArray`s in the frame and `Min`/`Max`'s is one; the `Product`'s
// merged `<number>` reuses the slot of a `<number>` it just folded away rather than needing a slot
// the buffer does not have. A per-simplification heap buffer was measured at 617 retired
// instructions, which is more than the whole pass, so "just one small array" was never available as
// an implementation choice.

/// `if ((firstInstance.offset - 1) == i && !firstInstance.canRemove)` (`+Simplification.cpp:700`),
/// plus its non-`Numeric` arm (`:707`) -- the C++'s own survivor test, asked of a flat child.
///
/// The same predicate as `SumMergePlan.survives`, over node indices rather than term positions: a
/// flat child list is addressed by node index, those are unique per child, and index 0 is always the
/// root and so never a child -- so `offset` can store `nodeIndex + 1` where the C++ stores `i + 1`.
/// Both encodings reserve 0 for "no term of this unit has been seen", which is what lets the table be
/// zero-initialised.
///
/// A free function rather than a method, so it can borrow the two tables without also borrowing the
/// tree, which is being mutated around every call to it.
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
    // NOT `... == index && !canRemove[key]`. `&&`'s right operand is an autoclosure, and an
    // autoclosure cannot capture a `borrowing` parameter -- the diagnostic says "cannot be captured by
    // an escaping closure", which reads as if a closure had been written here. `sumMergePlan` hit the
    // same wall for the same reason and records it too.
    guard Int(offsets[key]) - 1 == index else {
        return false
    }
    return !canRemove[key]
}

/// `if (!offset || (offset - 1) == i)` (`+Simplification.cpp:468`), plus its non-`Numeric` arm
/// (`:475`) -- `simplifyForMinMax`'s own survivor test, asked of a flat child.
///
/// Three ways to survive, all in that one condition, and the middle one is the whole reason this is
/// not `calcFlatSumSurvives`: a non-`Numeric` child (the C++'s `[&](const auto&)` arm, which appends
/// unconditionally), a child whose unit was never recorded -- which is how a percentage survives when
/// `canMergePercentages` is false and the merge pass skipped it outright -- and the first instance of
/// its unit. `simplify(Sum&)` records every numeric child, so it has no "never recorded" case and its
/// predicate instead carries the `canRemove` bit `Min`/`Max` has no counterpart for.
///
/// Node indices rather than term positions, on `calcFlatSumSurvives`'s reasoning: they are unique per
/// child, index 0 is always the root and so never a child, and 0 stays free for "not seen".
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
    /// Simplify the whole tree, children before parents, in one reverse pass.
    ///
    /// `options` is the same `CalcSimplification` the two-pass port carries, so the fields the C++
    /// reads -- `allowZeroValueLengthRemovalFromSum` at `:612` and `category` at `:886` -- have one
    /// spelling in this file rather than two.
    ///
    /// `builder` is `Optional` for exactly one reason, and not as a design preference:
    /// `cssCalcFlatSimplifyProbeSwift` -- whose C++ signature is fixed by the benchmark harness that
    /// calls it -- has no builder to hand over. Two things are read through it here,
    /// `lengthRemovalAllowed`'s `isLengthUnit` and `simplifyNonCanonicalDimension`'s
    /// `resolveRelativeLength`, and `nil` cannot change an answer on any tree the production route
    /// sends here, because that route always passes the builder. It CAN change one on the probe's own
    /// trees, which is why the `nil` behaviour is pinned at each site rather than assumed unreachable:
    /// a relative length with no conversion data to resolve against is the C++'s `nullopt`.
    mutating func simplify(
        _ options: CalcSimplification,
        _ builder: WebCore.CSSCalc.CSSCalcSwiftBuilder?
    ) {
        var i = count - 1
        while i >= 0 {
            // Never fold inside an `anchor()`'s `<anchor-side>`: the C++ copies that subtree rather
            // than simplifying it. One bit test, because `flatten` marked the whole subtree.
            if nodes[i].flags & CalcFlatNodeFlags.insideAnchorSide == 0 {
                simplifyNode(i, options, builder)
            }
            i -= 1
        }
    }

    /// Replace node `i` with node `j`, keeping `i`'s place in its parent's list.
    ///
    /// EVERY promotion goes through this, and the reason is a bug this cost a crash to find: a plain
    /// `nodes[i] = nodes[j]` copies `nextSibling` too, so the promoted node inherits the sibling link
    /// of wherever it came from. In a `Sum` whose term is promoted out of a nested `Sum`, that link
    /// points back into the list being walked, and the splice loop runs forever building a cycle --
    /// which reads as an OOM kill with no output rather than as anything legible. The contiguous-run
    /// representation could not have this defect because it had no sibling link to copy; the linked
    /// list buys O(1) splicing and this is the invariant that comes with it.
    ///
    /// `firstChild` and `childCount` ARE taken from `j`: the node genuinely adopts `j`'s children.
    /// So is `origin`, so the promoted node keeps naming the original `CSSCalc::Child` it came from.
    private mutating func replace(_ i: Int, with j: Int) {
        let sibling = nodes[i].nextSibling
        nodes[i] = nodes[j]
        nodes[i].nextSibling = sibling
    }

    private mutating func simplifyNode(
        _ i: Int,
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

        default:
            // Including the other three leaves, and for each of them that is a PORT rather than an
            // omission: `simplify(Number&)` (`+Simplification.cpp:487`), `simplify(Percentage&)`
            // (`:493`) and `simplify(CanonicalDimension&)` (`:500`) each `return { }` with no body,
            // which is also why `canSimplify` answers false for exactly those three -- and true for
            // the fourth, which is the case just above.
            return
        }
    }

    /// `simplify(NonCanonicalDimension&)` (`+Simplification.cpp:506`-`:514`), which is `canonicalize`
    /// (`:169`-`:287`) done in place.
    ///
    /// A leaf stays a leaf. The value, the unit and the alternative change and nothing structural
    /// does, so this is a `setLeaf` and never a `replace`: no promotion, no splice, no link touched,
    /// and none of the `nextSibling` hazards apply. `setLeaf` clearing `type` is right here and is
    /// NOT the `:1821` rule -- the C++ takes the `:1818` replacement branch for a leaf, and
    /// `ChildConstruction<Leaf>::make` discards a leaf's `Type` (CSSCalcTree.h:1016-:1018).
    ///
    /// Placement is `simplifyNode` rather than `flatten` because `copyAndSimplify` runs
    /// `canonicalize` at the node's own position in the post-order (`:1815`-`:1818`), and because
    /// `flatten` also visits an `anchor()`'s `<anchor-side>` subtree, which `:1798` only COPIES;
    /// this loop is the one guarded by `insideAnchorSide`.
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
            // `tryMakeCanonical`'s `if (conversionData)` (`:183`): with no builder there is no
            // conversion data to consult, which is the C++'s `nullopt` and leaves the dimension as it
            // is. Reached only from `cssCalcFlatSimplifyProbeSwift`.
            guard let builder else {
                return
            }
            leaf = options.resolvedRelativeLength(nodes[i].value, unit, builder)
        }
        // `canonicalize` answering `nullopt` is `simplify` returning `{ }`, which leaves the node
        // alone -- and the leaf handed back is then bit-identical to what the slot already holds, down
        // to the `percentHint` a non-`Percentage` node always carries as 0
        // (CSSCalcSwiftTypes.h:376-:389). Skipped rather than written and discarded.
        guard leaf.kind != .nonCanonicalDimension else {
            return
        }
        setLeaf(i, leaf)
    }

    /// `simplify(Negate&)` (`+Simplification.cpp:911`-`:961`), all four arms.
    private mutating func simplifyNegate(_ i: Int) {
        guard nodes[i].childCount == 1, let a = child(i, 0) else {
            return
        }

        if nodes[a].isNumericLeaf {
            // 6.1 (`:916`-`:921`). The unary MINUS, not `0 - v` and not `* -1`: it flips the sign bit
            // of a zero, so `-(+0)` is `-0`. That is the C++'s own stated reason for the spelling, and
            // the same distinction the two-pass port's `Fold` draws.
            let negated = -nodes[a].value
            replace(i, with: a)
            nodes[i].value = negated
            return
        }

        if nodes[a].alternative == .Negate, nodes[a].childCount == 1, let inner = child(a, 0) {
            // 6.2 (`:923`-`:926`). `negate(negate(x))` is `x`.
            replace(i, with: inner)
            return
        }

        if nodes[a].alternative == .Sum || nodes[a].alternative == .Product {
            // `:927`-`:956`, "Not stated in spec, but needed for tests": an all-numeric `Sum` or
            // `Product` child has EVERY child's value negated in place and is then returned in the
            // `Negate`'s place, keeping its own cached `Type`, which `replace` carries over with it.
            //
            // For a `Product` that is arithmetically wrong, and it is reproduced anyway: negating
            // every factor of `2 * 3` gives `-2 * -3`, so an even-arity all-numeric product comes back
            // with its sign UNFLIPPED. It is observable behaviour of the shipping C++, not dead code,
            // so the differential compares against it and a "fix" here would read as a Swift defect.
            guard allChildrenAreNumericLeaves(a) else {
                // `!all_of(a->children, isNumeric)` (`:930`, `:945`): `nullopt`, so the `Negate` keeps
                // its kind and its one simplified child.
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

    /// `simplify(Invert&)` (`+Simplification.cpp:963`-`:980`), both arms and no third one.
    ///
    /// 7.1's C++ arm is `[&](Number& a)`, NOT `[&]<Numeric T>(T&)`: a `Percentage`, a
    /// `CanonicalDimension` and a `NonCanonicalDimension` all reach `[](auto&) { return { }; }`
    /// (`:976`) and are left alone, because the reciprocal of a dimension is a type no `Child` leaf
    /// can hold. Checked against the source rather than assumed -- it is the one place in this set
    /// where `isNumericLeaf` would be the wrong predicate -- and step 9.3 depends on the distinction:
    /// `Invert(Number)` never survives to be a `Product` factor, which is what makes
    /// `distributeNumber`'s `Invert` arm reachable only for a percentage or a dimension.
    private mutating func simplifyInvert(_ i: Int) {
        guard nodes[i].childCount == 1, let a = child(i, 0) else {
            return
        }

        if nodes[a].alternative == .Number {
            // 7.1 (`:968`-`:971`), through the same executor the two-pass port's `foldInvert` uses.
            let inverted = CalcExecutor.invert(nodes[a].value)
            replace(i, with: a)
            nodes[i].value = inverted
            return
        }

        if nodes[a].alternative == .Invert, nodes[a].childCount == 1, let inner = child(a, 0) {
            // 7.2 (`:972`-`:975`).
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
    /// The counterpart of `replace` for the three C++ sites that return a leaf the input tree does not
    /// contain: `makeChild(CanonicalDimension { 0, Length })` at `:664`, `makeChild(*numericProduct)`
    /// at `:755`, and step 9.4's eleven-case category table at `:882`-`:902`. `NumericLeaf` is the
    /// two-pass port's own representation of exactly that -- "everything `makeChildWithValueBasedOn`
    /// carries" -- so those sites are reached here through `NumericLeaf.number`,
    /// `NumericLeaf.canonicalLength` and `numericLeafForCategory`, and no unit or percent-hint table is
    /// written a second time.
    ///
    /// `nextSibling` and `flags` are the two fields NOT written: the first because overwriting it is
    /// the cycle bug `replace` documents, the second because `insideAnchorSide` describes where the
    /// slot is rather than what is in it.
    ///
    /// False means `leaf.unitType` did not fit the node's `uint8_t`, which cannot happen: every unit
    /// here comes from a `CSSUnitType`, whose raw type IS `uint8_t`, and `CSSUnitType.h` allocates 7
    /// bits for it. Answered rather than trapped, and answered BEFORE anything is written, so a
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
        // A leaf's `Type` is DISCARDED by construction -- `ChildConstruction<T>::make(T&&, Type)` for
        // a `Leaf` ignores its `Type` argument (CSSCalcTree.h:1016-1018) -- so this is cleared rather
        // than computed, the same fact `flatten` rests on when it fetches no type for a leaf.
        nodes[i].type = CalcType()
        nodes[i].firstChild = CalcFlatNode.noNode
        nodes[i].childCount = 0
        nodes[i].valueID = 0
        nodes[i].unitType = unit
        nodes[i].alternative = alternative
        nodes[i].percentHint = leaf.percentHint
        return true
    }

    /// Splice every child of node `i` that is itself a `kind` node into `i`'s own child list, ONE
    /// LEVEL, in order, and leave `childCount` correct.
    ///
    /// Step 8.1 for `Sum` (`+Simplification.cpp:554`-`:564`) and the outer half of step 9.1 for
    /// `Product` (`:744`-`:750`) are the same list surgery, so they are the same function.
    ///
    /// ONE LEVEL IS THE WHOLE SUBTLETY, and the previous version of this got it wrong: it re-examined
    /// from the spliced-in head, so a `Sum` nested two deep spliced twice. The C++ iterates
    /// `root.children` exactly once and appends a grandchild without looking at it, and it does not
    /// need to look -- the reverse loop simplified that inner `Sum` before this one, so the inner
    /// sum's own nested sums were already spliced into it. `cursor` therefore continues from the node
    /// AFTER the spliced child, never from the head.
    ///
    /// The C++ guards `Sum`'s splice with `any_of(children, holdsAlternative<IndirectNode<Sum>>)`
    /// (`:555`) and does not guard `Product`'s. That asymmetry is not reproduced because it is not
    /// observable: the guard exists to avoid allocating a `Vector<Child> newChildren` when nothing
    /// would change, and relinking a list in place is already a no-op when nothing is nested. One pass
    /// here does what the C++'s scan-then-rebuild does in two.
    private mutating func spliceNestedChildren(_ i: Int, _ kind: CalcAlternative) {
        var previous = CalcFlatNode.noNode
        var cursor = nodes[i].firstChild
        var terms: UInt32 = 0
        while cursor != CalcFlatNode.noNode {
            let c = Int(cursor)
            guard nodes[c].alternative == kind else {
                previous = cursor
                cursor = nodes[c].nextSibling
                terms += 1
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
            terms += 1
            while nodes[Int(tail)].nextSibling != CalcFlatNode.noNode {
                tail = nodes[Int(tail)].nextSibling
                terms += 1
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
    /// (`:606`) rather than the O(k^2) pairwise scan this function used to do: two `InlineArray`s in
    /// the frame, keyed by `mergeKey` -- 128 entries because the key is the 7-bit `CSSUnitType`, which
    /// `mergeKey` explains is injective on `NumericIdentity` and so gives the same fixed-size table
    /// without transcribing a 56-case enum into this file. Fixed size, stack, no allocation, and the
    /// same two typealiases the two-pass port's `SumMergePlan` uses so there is one declaration of
    /// each.
    ///
    /// `FirstInstance::merges` is not kept per bucket. The C++ keeps it only to sum it at `:647`, and
    /// two running totals -- `merges`, and how many buckets are currently marked removable -- give
    /// both of its tallies for free. `SumMergePlan` makes the same substitution and states the one
    /// thing it depends on: `canRemove` is ASSIGNED on every merge (`:625`), not accumulated, so it can
    /// go back to false and the count has to move both ways.
    private mutating func simplifySum(
        _ i: Int,
        _ options: CalcSimplification,
        _ builder: WebCore.CSSCalc.CSSCalcSwiftBuilder?
    ) {
        guard nodes[i].childCount > 0 else {
            return
        }

        // 8.1 (`:554`-`:564`).
        spliceNestedChildren(i, .Sum)

        // `if (root.children.size() == 1) return { WTF::move(root.children[0]) };` (`:594`-`:596`), on
        // the FLATTENED list, and it returns that child WHATEVER IT IS -- an operator node just as
        // readily as a numeric leaf. The previous version required a leaf, which left
        // `calc(min(1px, 2px) + 0px)` as a one-term `Sum` where the C++ returns the `min()` itself.
        if nodes[i].childCount == 1, let only = child(i, 0) {
            replace(i, with: only)
            return
        }

        // 8.2's first phase (`:601`-`:640`).
        var offsets = CalcSimplification.MergeTable(repeating: 0)
        var canRemove = CalcSimplification.MergeFlags(repeating: false)
        // `childrenToRemoveFromMerges` (`:643`).
        var merges = 0
        // The second half of `childrenToRemoveTotal` (`:648`), as a count of the buckets whose
        // `canRemove` is currently set.
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
                // A repeat: `evaluate(root.children[firstInstance.offset - 1], root.children[i])` and
                // then `root.children[firstInstance.offset - 1] = WTF::move(mergedChild)`
                // (`:618`-`:621`). The surviving node is the FIRST INSTANCE, so its alternative, unit
                // and percent hint are what `makeChildWithValueBasedOn` keeps and only the value
                // changes -- which is exactly what writing the sum back into its slot does.
                let first = Int(offsets[key]) - 1
                let merged = CalcExecutor.sum(nodes[first].value, nodes[c].value)
                nodes[first].value = merged
                merges += 1

                // `firstInstance.canRemove = canRemoveIfZero && !mergedValue;` (`:625`) -- an
                // ASSIGNMENT, so a bucket made removable by an earlier merge is cleared when a later
                // one lands non-zero. `!mergedValue` is true for both `+0` and `-0`, which `== 0` is
                // and a sign test would not be. Spelled as `if`/`else` rather than `&&` because
                // `&&`'s autoclosure right operand cannot capture what `lengthRemovalAllowed` needs,
                // and written in this order so the upcall inside it is skipped for every non-zero
                // merge.
                //
                // `let builder` unwraps here rather than inside `lengthRemovalAllowed`, so that
                // function keeps its non-`Optional` `borrowing` parameter and the two-pass port's
                // three call sites are untouched: promoting a `borrowing` argument into an `Optional`
                // is a CONSUME, and the diagnostic for it ("'builder' is borrowed and cannot be
                // consumed") names the call site, not the promotion. A `nil` builder answers false,
                // which only ever mis-answers a `NonCanonicalDimension`; the production route always
                // passes a builder, and the only caller that does not is the benchmark probe, whose
                // fixture holds `Number` leaves alone.
                let removable: Bool
                if merged == 0, let builder {
                    removable = options.lengthRemovalAllowed(leaf, builder)
                } else {
                    removable = false
                }
                if removable != canRemove[key] {
                    removableBuckets += removable ? 1 : -1
                    canRemove[key] = removable
                }
                continue
            }

            // `firstInstances[id] = { .offset = i + 1, .merges = 0, .canRemove = canRemoveIfZero &&
            // !child.value };` (`:630`-`:634`). `c + 1` is a node index, not a term position: see
            // `calcFlatSumSurvives`.
            offsets[key] = Int32(c + 1)
            let removable: Bool
            if nodes[c].value == 0, let builder {
                removable = options.lengthRemovalAllowed(leaf, builder)
            } else {
                removable = false
            }
            if removable != canRemove[key] {
                removableBuckets += removable ? 1 : -1
                canRemove[key] = removable
            }
        }

        let size = Int(nodes[i].childCount)
        // `childrenToRemoveTotal` (`:644`-`:650`).
        let removeTotal = merges + removableBuckets

        // `if (!childrenToRemoveTotal) return { };` (`:653`). The node keeps its kind, its cached
        // `Type` and whatever list 8.1 left it with.
        if removeTotal == 0 {
            return
        }

        // `if ((root.children.size() - childrenToRemoveFromMerges) == 1) return { WTF::move(
        // root.children[0]) };` (`:657`). BEFORE zero-removal and without consulting `canRemove`, so
        // an all-merging sum of removable zero lengths returns that zero rather than the fabricated
        // one at `:664`. Child 0 is always the sole merge-survivor -- it has no earlier term to merge
        // into -- which is why the C++ names it unconditionally and this needs no search, and its
        // value is the accumulated one, written back above.
        if size - merges == 1, let only = child(i, 0) {
            replace(i, with: only)
            return
        }

        let combined = size - removeTotal

        // 8.4's over-removal guard (`:660`-`:664`): "If the new size is 0, we removed too much. Return
        // a single 0 value of type `length` ... because the only kind of node that can be removed is
        // of type `length`."
        if combined == 0 {
            setLeaf(i, NumericLeaf.canonicalLength(0))
            return
        }

        // 8.3 with one survivor (`:667`-`:688`): "we know there is one child, we just don't know which
        // one yet."
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
        // order. The node keeps its kind AND its original cached `Type` -- `copyAndSimplify` takes
        // `getType(root)` at `:1821` for a node whose `simplify` returned `nullopt`, and `:712` is
        // that path.
        var previous = CalcFlatNode.noNode
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
                kept += 1
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

    /// `simplifyForMinMax` (`+Simplification.cpp:372`-`:483`), css-values-4 steps 5.1 to 5.3, reached
    /// from `simplify(Min&)` (`:999`) and `simplify(Max&)` (`:1004`).
    ///
    /// `simplify(Sum&)`'s merge machinery MINUS removal, and that is the whole of it: no step 8.1
    /// splice (the C++ never flattens a nested `min()` into its parent), no `canRemove`, no
    /// over-removal guard, and one extra way for a child to survive -- see `calcFlatMinMaxSurvives`.
    /// The table is the same `MergeTable` keyed by the same `mergeKey`, which is the C++'s own
    /// `std::array<size_t, numberOfNumericIdentityTypes>` (`:415`): fixed size, in the frame, zero
    /// allocation, and the C++ arm zero-initialises an array of the same shape per node.
    ///
    /// NO RESOLUTION TEST, unlike every other multi-operand fold in this file. `simplifyForOperation`
    /// gates on `fullyResolved` (`:303`), so `mod(5em, 3em)` does not fold; this gates only on
    /// `percentageResolveToDimension` (`:417`), so `min(1em, 2em)` DOES fold to `1em`. Both are
    /// correct as written -- an `em` scale is positive, so magnitudes really are comparable without
    /// knowing it -- and the asymmetry is transcribed rather than normalised.
    private mutating func simplifyMinMax(_ i: Int, _ options: CalcSimplification, _ isMax: Bool) {
        // `ASSERT(!root.children.isEmpty())` (`:374`). Unreachable through the parser and refused by
        // `isSimplifiableAlternative` if it ever were, so this only keeps the code below total.
        guard nodes[i].childCount > 0 else {
            return
        }

        // `if (root.children.size() == 1) return { WTF::move(root.children[0]) };` (`:409`-`:410`),
        // BEFORE the merge pass -- which is why a one-child `min()` promotes its child whatever the
        // child is, including a percentage the merge would have refused and an operator node.
        if nodes[i].childCount == 1, let only = child(i, 0) {
            replace(i, with: only)
            return
        }

        // `std::array<size_t, numberOfNumericIdentityTypes> offsetOfFirstInstance { };` (`:415`) and
        // `bool canMergePercentages = !percentageResolveToDimension(options);` (`:417`).
        var offsets = CalcSimplification.MergeTable(repeating: 0)
        let canMergePercentages = !options.percentageResolveToDimension
        // `unsigned numberOfMergeOpportunities = 0;` (`:419`).
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

            // `if (id == NumericIdentity::Percentage && !canMergePercentages) return 0;` (`:424`).
            // The bucket is left UNSET, which is exactly how `calcFlatMinMaxSurvives` then lets the
            // child through the rebuild.
            if leaf.kind == .percentage, !canMergePercentages {
                continue
            }

            let key = mergeKey(leaf)
            if offsets[key] != 0 {
                // `root.children[offset - 1] = evaluate(root.children[offset - 1], root.children[i]);`
                // (`:431`). `evaluate` is `executeMathOperation<Op>(aNumeric.value, get<T>(b).value)`
                // (`:399`) with a = the ACCUMULATED first instance and b = the later child, and the
                // two-argument `Min`/`Max` executors are NaN-order-sensitive, so the argument order
                // here is the C++'s position for position.
                //
                // `makeChildWithValueBasedOn(result, aNumeric)` keeps the FIRST INSTANCE's
                // alternative, unit and percent hint and changes only the value -- which is what
                // writing the merged value back into its slot does.
                let first = Int(offsets[key]) - 1
                nodes[first].value = isMax
                    ? CalcExecutor.max(nodes[first].value, nodes[c].value)
                    : CalcExecutor.min(nodes[first].value, nodes[c].value)
                merges += 1
                continue
            }

            // `offsetOfFirstInstance[static_cast<uint8_t>(id)] = i + 1;` (`:438`). `c + 1` is a node
            // index, not a term position: see `calcFlatSumSurvives`.
            offsets[key] = Int32(c + 1)
        }

        // `if (!numberOfMergeOpportunities) return { };` (`:450`-`:451`). The node keeps its kind, its
        // cached `Type` and its child list.
        if merges == 0 {
            return
        }

        // `if (combinedChildrenSize == 1) return { WTF::move(root.children[0]) };` (`:453`-`:457`).
        // Child 0 is always the sole survivor here and the C++ names it without searching for the
        // same reason `simplify(Sum&)` does: child 0 has no earlier child to merge into, so it always
        // survives, and any merge implies a first instance that survives -- two survivors would
        // contradict `size - merges == 1`. Its value is the accumulated one, written back above.
        let size = Int(nodes[i].childCount)
        if size - merges == 1, let only = child(i, 0) {
            replace(i, with: only)
            return
        }

        // `:459`-`:480`: keep every non-numeric child and the first instance of each merged unit, in
        // order. The node keeps its kind AND its original cached `Type` -- the C++ returns `{ }` at
        // `:482` even here, so `copyAndSimplify` takes the `getType(root)` branch at `:1821`.
        var previous = CalcFlatNode.noNode
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
                kept += 1
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

    /// `simplify(Product&)` (`+Simplification.cpp:717`-`:909`), css-values-4 steps 9.1 to 9.5.
    private mutating func simplifyProduct(_ i: Int, _ options: CalcSimplification) {
        guard nodes[i].childCount > 0 else {
            return
        }

        // 9.1 (`:744`-`:750`), UNCONDITIONALLY unlike `Sum`'s, and one level: a grandchild that is
        // itself a `Product` is kept as a factor, because `processChild` (`:734`) tests only for
        // `Number`. Spliced-in grandchildren ARE examined by 9.2 below, which is why these are two
        // passes here where the C++ writes them as one; the visitation order is identical.
        spliceNestedChildren(i, .Product)

        // 9.2 (`:729`-`:742`): fold every `<number>` factor into one value and unlink it. ONLY
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
                // (`:737`) -- the new factor on the LEFT, which `multipliedNumericProduct` documents
                // and which matters only for the sign of a NaN.
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
                survivors += 1
            }
            cursor = next
        }
        nodes[i].childCount = survivors

        if let numericProduct {
            // "If `numericProduct` has a value and `newChildren` is empty, that means all the children
            // were numbers and the product can be returned directly." (`:752`-`:755`)
            if survivors == 0 {
                setLeaf(i, NumericLeaf.number(numericProduct))
                return
            }

            // 9.3 (`:757`-`:798`). The arity test is on the survivor list BEFORE the merged number is
            // appended, which is what `:761`'s note means by "the last child is a singular `number`
            // child".
            if survivors == 1, let only = child(i, 0), distributeNumber(i, only, numericProduct) {
                return
            }

            // "If there was more than one child or no replacement was found, append the product from
            // step 9.2 into the newChildren array." (`:801`) -- at the END, so the final list is a
            // reordering of the input rather than a copy of it.
            //
            // THE APPENDED NODE IS A SLOT THIS PASS JUST FREED, and that is what keeps the buffer
            // exactly the size `walk` counted: reaching here means at least one `<number>` factor was
            // unlinked, its slot is unreachable from any list, and it is already a `Number` carrying
            // `Number`'s unit -- so only the value and the links need writing. There is no growable
            // buffer here and no allocation to reach for; a heap buffer on this path was measured at
            // 617 retired instructions, more than the whole pass.
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
                survivors += 1
                nodes[i].childCount = survivors
            }
        }

        // 9.4 (`:806`-`:905`). `success` starts FALSE and is overwritten by each iteration, so an
        // empty list falls through to 9.5 rather than folding to `1`. Unreachable here -- a zero-
        // survivor product either returned above or gained the merged number -- and reproduced anyway.
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
            // `:879`-`:904`'s eleven-case category table, reached through the two-pass port's own
            // `numericLeafForCategory` so each category's canonical unit and percent hint are written
            // down once in this file.
            setLeaf(i, folded)
            return
        }

        // 9.5. Return root.
    }

    /// Step 9.3's three arms (`+Simplification.cpp:763`-`:798`) for the single surviving factor `s`.
    ///
    /// True means node `i` has been replaced; false is the C++'s `return { }` out of an arm, after
    /// which the caller appends the merged `<number>` and falls into 9.4.
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
            // `[&](IndirectNode<Sum>& sum)` (`:768`-`:780`): all children numeric, then EVERY child's
            // value multiplied in place and the same `Sum` node returned -- keeping its cached `Type`,
            // which `replace` carries over.
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
            // `[&](IndirectNode<Invert>& invert)` (`:781`-`:790`), AND IT IS WRONG: the C++ returns
            // `makeChildWithValueBasedOn(child.value * numericProduct->value, child)` -- the inner
            // operand's value MULTIPLIED by the number where dividing is what an `Invert` means, and
            // carrying the inner operand's own unit rather than its inverse. `calc(2 / 50%)` comes
            // back as `calc(100%)`.
            //
            // Reproduced exactly, not corrected. It is observable behaviour of the shipping C++ that
            // the differential compares against, so "fixing" it here would be recorded as a Swift
            // divergence; the two-pass port's `distributeNumber` reproduces the same arm and says so
            // in the same words. Reachable only when the operand is a `Percentage` or a dimension,
            // because 7.1 collapsed `Invert(Number)` before this node's turn came round.
            guard nodes[s].childCount == 1, let inner = child(s, 0), nodes[inner].isNumericLeaf else {
                // The inner `[](const auto&)` arm (`:786`-`:788`).
                return false
            }
            let scaled = nodes[inner].value * product
            replace(i, with: inner)
            nodes[i].value = scaled
            return true
        }

        // `[](auto&) -> std::optional<Child> { return { }; }` (`:791`-`:793`).
        return false
    }

    /// One iteration of step 9.4's factor loop (`+Simplification.cpp:815`-`:878`): multiply this
    /// factor's type into `productType` and its value into `productValue`.
    ///
    /// The same body as the two-pass port's `multiplyProductFactor`, over a flat node instead of a
    /// `ProductFactor`, and calling the same `numericLeafType` -- so the `getType(const Percentage&)`
    /// / `getType(const CanonicalDimension&)` split, and the reason a `NonCanonicalDimension` answers
    /// `nil` rather than `determineType(unit)`, are stated once in this file.
    ///
    /// `Type::multiply` and `Type::invert` are the real C++ functions, called rather than transcribed:
    /// pure arithmetic over `Type`'s eight bytes. The two calls are in the C++'s order.
    private func multiplyFactor(
        _ c: Int,
        _ productValue: inout Double,
        _ productType: inout CalcType,
        _ options: CalcSimplification
    ) -> Bool {
        if let leaf = nodes[c].numericLeaf {
            switch leaf.kind {
            case .number:
                // "`<number>` is the identity type, so multiplying by it has no effect." (`:818`)
                productValue *= leaf.value
                return true

            case .percentage, .canonicalDimension:
                // `Type::multiply(productResult.type, getType(x))` (`:823`, `:832`).
                guard let factorType = options.numericLeafType(leaf),
                      let multiplied = CalcType.multiply(productType, factorType).value else {
                    return false
                }
                productType = multiplied
                productValue *= leaf.value
                return true

            case .nonCanonicalDimension:
                // Not an arm of the C++ switch, so it reaches `[](const auto&) -> bool { return
                // false; }` (`:872`-`:874`). REACHABLE on the production path now that
                // `CalcFlatCoverage.mask` admits the alternative: `calc(2 * 1em)` with no conversion
                // data leaves the `em` uncanonicalized, and it arrives here as a `Product` factor.
                return false
            }
        }

        // `[&](IndirectNode<Invert>& invertChild)` (`:840`-`:871`). Every other surviving node -- a
        // `Sum`, a `Min`, a `Product` the splice could not take -- is the outer `[](const auto&)` arm
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
            // `Type::multiply(productResult.type, Type::invert(getType(x)))` (`:848`-`:854`,
            // `:858`-`:864`), and the value is DIVIDED.
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
            // The inner `[](const auto&)` arm (`:867`-`:869`).
            return false
        }
    }

    /// Materialise the subtree rooted at `i` as a real `CSSCalc::Child`, on the builder's operand
    /// stack, and report whether it got there.
    ///
    /// SWIFT WALKS ITS OWN TREE. That is the whole shape of this function and the reason the flat
    /// node does not exist in C++: nothing about the representation crosses, only finished operands
    /// and, for an operator, the alternative and the arity. Post-order, so every child is an operand
    /// on the stack before its parent asks for it -- the same discipline the rest of the builder
    /// already uses, and the reason no Swift container ever holds a `Child`.
    ///
    /// What crosses per node: `pushLeaf` takes a 16-byte POD, `buildOperation` an enum and a count.
    /// Neither re-derives anything. The predecessor was one crossing for the whole tree -- Swift
    /// handing over two `Span`s and C++ walking them -- and the reason that is gone is not that it
    /// was slow but that it required C++ to name the node type, which is the inversion running
    /// backwards. The price of the swap was measured rather than assumed: 0.9580 to 0.9636 of the
    /// C++ arm, about 3.4 retired instructions per node.
    ///
    /// Distinct from `rebuildFrom`, which is what the two-pass port calls: that takes the ORIGINAL
    /// node and recovers its operation through a 41-way `switchOn` plus `WTF::apply`, at 1396 retired
    /// instructions. A flat node states its own alternative, so there is nothing to recover.
    ///
    /// Recursive on tree DEPTH, not on node count, and the deepest calc expression in the whole WPT
    /// css-values corpus is single digits.
    func emit(_ i: Int, into builder: inout WebCore.CSSCalc.CSSCalcSwiftBuilder) -> Bool {
        let node = nodes[i]

        if let leaf = node.numericLeaf {
            // `pushLeaf` owns which alternative a unit means, via `makeNumeric`, so no unit table is
            // re-derived here -- the same routing the two-pass port's leaves take.
            return builder.pushLeaf(leaf.boundaryLeaf)
        }

        var pushed: UInt32 = 0
        var cursor = node.firstChild
        while cursor != CalcFlatNode.noNode {
            guard emit(Int(cursor), into: &builder) else { return false }
            pushed += 1
            cursor = nodes[Int(cursor)].nextSibling
        }
        // False for anything outside `buildOperation`'s set, which for now is this prototype's own
        // coverage. Declining rather than building something plausible.
        // The node's OWN type, not a fresh `toType` of the operands, and this is the overload that
        // exists for it. `copyAndSimplify` ends at `makeChild(WTF::move(simplified), getType(root))`
        // (`+Simplification.cpp:1821`) -- the original node's type -- so recomputing here diverges
        // from the C++ for any surviving operator whose children changed shape. Measured, not
        // supposed: `calc((2 / 3px) * 4px)` survives as `Product{6px, 4px}` on both arms and
        // SERIALIZES identically, so only simplifycheck's structural oracle catches it; the C++ keeps
        // the parse-time type where a fresh `toType` computes px^2. That is why `flatten` pays
        // `getType` per operator node, and why it skips it for the seven leaf alternatives, whose
        // type `makeChild` discards.
        return builder.buildOperation(node.alternative, pushed, node.type)
    }
}

/// Count the nodes of `root`, so a flat tree can be stack-allocated for it.
///
/// A separate traversal only in the probes below. On any real path the number comes from `walk`,
/// which computes it already and allocates nothing to do it -- which is the point: the counting pass
/// the flat tree needs is a pass that has to run anyway.
fileprivate func calcFlatNodeCount(_ root: borrowing WebCore.CSSCalc.Child) -> UInt32 {
    var total: UInt32 = 1
    let info = WebCore.CSSCalc.swiftNodeInfo(root)
    var index: UInt32 = 0
    while index < info.childCount {
        total += calcFlatNodeCount(root[Int(index)])
        index += 1
    }
    return total
}

/// The `SimplificationOptions` the two flat probes run under.
///
/// All three fields at their C++ default, which is what a probe wants: the fixtures are timed for the
/// shape of the pass, and an options-dependent arm would make the number depend on a value the
/// harness does not pass. `allowZeroValueLengthRemovalFromSum` false also means the one arm that
/// would reach `isLengthUnit` is never taken, which is why the probes can hand `simplify` no builder.
private var calcFlatProbeOptions: CalcSimplification {
    return CalcSimplification(
        percentageResolveToDimension: false,
        allowZeroValueLengthRemovalFromSum: false,
        category: 0
    )
}

/// Convert and then FOLD, `iterations` times, returning the bit pattern of the resulting root's
/// value so the caller can check it against the C++ arm rather than trust the timing.
@_expose(Cxx)
public func cssCalcFlatSimplifyProbeSwift(_ root: borrowing WebCore.CSSCalc.Child, _ iterations: UInt32) -> UInt64 {
    var bits: UInt64 = 0
    let n = calcFlatNodeCount(root)
    let options = calcFlatProbeOptions
    for _ in 0..<iterations {
        bits = withCalcFlatTree(root, n) { tree in
            tree.simplify(options, nil)
            return tree.nodes[0].value.bitPattern
        }
    }
    return bits
}

/// Converts `root` `iterations` times and returns the summed node count.
///
/// THE LOOP IS IN SWIFT, and that is a correction rather than a convenience: two fresh `Array`s per
/// conversion charged every iteration with two mallocs and two frees that a real implementation pays
/// once per process, not once per tree, and measured that way conversion came out at 2338
/// instructions against 1457 for the C++ arm's entire simplification. There is now no allocation at
/// all -- the tree is a stack buffer -- so what this measures is the traversal and the stores.
@_expose(Cxx)
public func cssCalcFlattenProbeSwift(_ root: borrowing WebCore.CSSCalc.Child, _ iterations: UInt32) -> UInt32 {
    var total: UInt32 = 0
    let n = calcFlatNodeCount(root)
    for _ in 0..<iterations {
        total &+= withCalcFlatTree(root, n) { tree in UInt32(tree.count) }
    }
    return total
}

#if ENABLE_CSS_TOKENIZER_SWIFT_BRIDGE

/// R151 GATE 3: convert, simplify, and EMIT a real `CSSCalc::Child`, `iterations` times, returning
/// how many iterations emitted successfully so the caller can check the count rather than trust the
/// timing.
///
/// The one shape gates 1 and 2 did not price. Gate 2's fixture folds away to a single `Number`, so
/// its emit is one `makeChild`; a tree that SURVIVES as an operator node has to rebuild a real node
/// with real children, and that is the cost that decides whether the flat design wins on the trees
/// real CSS actually carries.
///
/// The operand stack is cleared rather than freed between iterations, so what is timed is a
/// steady-state emit rather than a vector growing `iterations` long.
@_expose(Cxx)
public func cssCalcFlatEmitProbeSwift(
    _ root: borrowing WebCore.CSSCalc.Child,
    _ builder: inout WebCore.CSSCalc.CSSCalcSwiftBuilder,
    _ iterations: UInt32
) -> UInt32 {
    var emitted: UInt32 = 0
    let n = calcFlatNodeCount(root)
    let options = calcFlatProbeOptions
    for _ in 0..<iterations {
        builder.clearOperands()
        if withCalcFlatTree(root, n, { tree -> Bool in
            tree.simplify(options, builder)
            return tree.emit(0, into: &builder)
        }) {
            emitted &+= 1
        }
    }
    return emitted
}

#endif
