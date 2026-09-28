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

internal import Cxx
import Darwin
public import WebCore_Private.CSSCalcSwiftTypes
internal import WebCore_Private.CSSCalcTypeSwiftTypes
// `CSS::Category`, for `Type::determinePercentHint`.
internal import WebCore_Private.CSSPrimitiveNumericCategorySwiftTypes
// The unit conversion constants, as namespace-scope `constexpr double`s: `CSSUnits.h` is not
// self-contained.
internal import WebCore_Private.CSSUnitsSwiftTypes
internal import WebCore_Private.Core
// The <angle> conversion constants, which plain `import wtf` does not see.
internal import wtf.Core.MathExtras

// calc() simplification, parsing and evaluation in Swift, used when WebCore is built with
// WK_USE_SWIFT_CSS, in which the C++ simplifier, parser and evaluator are not compiled.
//
// Handles all 41 of `CSSCalc::Node`'s alternatives. A simplification that cannot derive its answer
// sets `CalcFold.declined`, which refuses the whole tree.
//
// The grammar builds an owned `CalcNode` tree and folds it as it goes; `CSSCalc::Tree` stores the
// result (`CSSCalcSwiftRoot`), and every reader walks that stored tree: simplification with
// conversion data folds a copy of it, children before their parent and in forward order as
// `copyAndSimplify` does. A `CSSCalc::Child` is built from it (`calcEmitParsed`) only for the C++
// that reads one.

// MARK: - The per-alternative discriminant

// Dispatches on `CSSCalcSwiftAlternative`, the variant's own alternative index (pinned to `Node`'s
// via `WTF::alternativeIndexV`), not on `CalcNodeKind`, which classifies by serialization shape and
// conflates `min()` with `mod()`.

typealias CalcAlternative = WebCore.CSSCalc.CSSCalcSwiftAlternative

/// `WebCore::CSSCalc::Type`.
///
/// The backticks are required: unescaped, `WebCore.CSSCalc.Type` parses as the metatype of the
/// `WebCore.CSSCalc` namespace enum.
typealias CalcType = WebCore.CSSCalc.`Type`

/// The value `CSSCalcSwiftLeaf.alternative` wants for one of the four numeric leaves.
@inline(always)
private func leafAlternativeRawValue(_ kind: NumericKind) -> UInt8 {
    switch kind {
    case .number:
        return CalcAlternative.Number.rawValue
    case .percentage:
        return CalcAlternative.Percentage.rawValue
    case .canonicalDimension:
        return CalcAlternative.CanonicalDimension.rawValue
    case .nonCanonicalDimension:
        return CalcAlternative.NonCanonicalDimension.rawValue
    }
}

/// The shape of a node's serialization, not its operation: several operations share a kind, and the
/// node's `valueID` carries the name, so the operator name table stays in C++. `operation` is an
/// alternative `CalcNode.info` has not been taught.
enum CalcNodeKind: UInt8 {
    case number
    case percentage
    case canonicalDimension
    case nonCanonicalDimension
    case symbol
    case siblingCount
    case siblingIndex
    case sum
    case product
    case negate
    case invert
    case operation
    /// `Deg2Rad`, which has no CSS-level spelling and serializes as its child.
    case transparent
    case function
    /// `valueID` is the rounding strategy rather than the function name.
    case roundFunction
    case progressNoClampFunction
    /// `clamp()` with one bound, or both, holding the keyword `none`, which is not a child, so the
    /// kind says where the keyword goes.
    case clampWithNoneMinimum
    case clampWithNoneMaximum
    case clampWithNoneMinimumAndMaximum
    /// The four operations whose arguments are not a plain list of calculation trees.
    case randomFunction
    case calcMixFunction
    case anchorFunction
    case anchorSizeFunction
}

// MARK: - The four numeric leaves

/// Which of the four numeric alternatives a folded value is.
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
/// Explicit comparisons, because `init?(rawValue:)` on an imported C++ scoped enum accepts any raw
/// value, and an out-of-range hint would alias onto `.length` in `Type::operator[](PercentHint)`.
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

// MARK: - The `Type` algebra in Swift

extension CalcType {
    /// The C++'s `if (type.percentHint)`.
    @inline(always)
    fileprivate var hasPercentHint: Bool {
        // `!(… == …)`, not `!=`: C++20 synthesises the negation of a defaulted `operator==` and
        // the ClangImporter does not.
        !(percentHint == CalcType.PercentHintValue())
    }

    /// css-typed-om step 2, shared by `Type::add` and `Type::multiply`.
    @inline(always)
    fileprivate static func normalizePercentHints(
        _ type1: inout CalcType,
        _ type2: inout CalcType
    ) -> Bool {
        if type1.hasPercentHint && type2.hasPercentHint {
            return type1.percentHint == type2.percentHint
        }
        if type1.hasPercentHint {
            type2.percentHint = type1.percentHint
        } else if type2.hasPercentHint {
            type1.percentHint = type2.percentHint
        }
        return true
    }

    /// One lane of step 4 of `multiply`.
    ///
    /// `addingReportingOverflow` matches the C++'s `checkedSum<int8_t>`: `&+` would wrap where the
    /// C++ fails, and `+` would trap.
    @inline(always)
    fileprivate static func sumExponent(_ a: Int8, _ b: Int8, _ overflowed: inout Bool) -> Int8 {
        let (result, didOverflow) = a.addingReportingOverflow(b)
        overflowed = overflowed || didOverflow
        return result
    }

    /// `Type::multiply`.
    @inline(always)
    fileprivate func multiplied(by other: CalcType) -> CalcType? {
        var type1 = self
        var type2 = other

        guard Self.normalizePercentHints(&type1, &type2) else {
            return nil
        }

        var finalType = CalcType()
        var overflowed = false
        finalType.length = Self.sumExponent(type1.length, type2.length, &overflowed)
        finalType.angle = Self.sumExponent(type1.angle, type2.angle, &overflowed)
        finalType.time = Self.sumExponent(type1.time, type2.time, &overflowed)
        finalType.frequency = Self.sumExponent(type1.frequency, type2.frequency, &overflowed)
        finalType.resolution = Self.sumExponent(type1.resolution, type2.resolution, &overflowed)
        finalType.flex = Self.sumExponent(type1.flex, type2.flex, &overflowed)
        finalType.percent = Self.sumExponent(type1.percent, type2.percent, &overflowed)
        if overflowed {
            // "NOTE: This is amended in our implementation to return `failure` if exponent would
            // overflow."
            return nil
        }

        finalType.percentHint = type1.percentHint

        return finalType
    }

    /// `Type::invert`.
    ///
    /// `0 &- exponent`, not `-exponent`: the C++'s `-1 * type[unit]` computes in `int` and narrows
    /// back, so -128 stays -128, where Swift's unary `-` traps. -128 is reachable, since `multiply`
    /// admits any sum that fits in `Int8`.
    @inline(always)
    fileprivate func inverted() -> CalcType {
        var result = CalcType()
        result.percentHint = percentHint

        result.length = 0 &- length
        result.angle = 0 &- angle
        result.time = 0 &- time
        result.frequency = 0 &- frequency
        result.resolution = 0 &- resolution
        result.flex = 0 &- flex
        result.percent = 0 &- percent

        return result
    }

    /// `Type::hasNonPercentEntry()`.
    @inline(always)
    fileprivate var containsNonPercentEntry: Bool {
        length != 0 || angle != 0 || time != 0 || frequency != 0 || resolution != 0 || flex != 0
    }

    /// `Type::applyPercentHint`, as a value-returning form.
    ///
    /// `&+`, not `+`: the C++'s `int8_t` `+=` computes in `int` and narrows back, so 127 + 127 is -2
    /// where Swift's `+` traps. The `default` case must alias to `length`, as
    /// `operator[](PercentHint)` does in a Release build, because an out-of-range hint is
    /// constructible in Swift.
    @inline(always)
    fileprivate func withPercentHintApplied(_ hint: WebCore.CSSCalc.PercentHint) -> CalcType {
        var result = self
        switch hint {
        case .Length: result.length = result.length &+ result.percent
        case .Angle: result.angle = result.angle &+ result.percent
        case .Time: result.time = result.time &+ result.percent
        case .Frequency: result.frequency = result.frequency &+ result.percent
        case .Resolution: result.resolution = result.resolution &+ result.percent
        case .Flex: result.flex = result.flex &+ result.percent
        default: result.length = result.length &+ result.percent
        }
        result.percent = 0
        result.percentHint = CalcType.PercentHintValue(hint)
        return result
    }

    /// `Type::allNonZeroValuesEqual`.
    @inline(always)
    fileprivate func nonZeroValuesEqual(_ other: CalcType) -> Bool {
        if length != 0 && length != other.length { return false }
        if angle != 0 && angle != other.angle { return false }
        if time != 0 && time != other.time { return false }
        if frequency != 0 && frequency != other.frequency { return false }
        if resolution != 0 && resolution != other.resolution { return false }
        if flex != 0 && flex != other.flex { return false }
        if percent != 0 && percent != other.percent { return false }
        return true
    }

    /// `add`'s merge: "copy all of type1's entries to finalType, and then copy all of type2's
    /// entries that finalType doesn't already contain".
    @inline(always)
    fileprivate func mergingAbsentLanes(from other: CalcType) -> CalcType {
        var result = self
        if other.length != 0 && result.length == 0 { result.length = other.length }
        if other.angle != 0 && result.angle == 0 { result.angle = other.angle }
        if other.time != 0 && result.time == 0 { result.time = other.time }
        if other.frequency != 0 && result.frequency == 0 { result.frequency = other.frequency }
        if other.resolution != 0 && result.resolution == 0 { result.resolution = other.resolution }
        if other.flex != 0 && result.flex == 0 { result.flex = other.flex }
        if other.percent != 0 && result.percent == 0 { result.percent = other.percent }
        return result
    }

    /// One iteration of the provisional-hint loop in `add`.
    fileprivate static func addUnderHint(
        _ hint: WebCore.CSSCalc.PercentHint,
        _ type1: CalcType,
        _ type2: CalcType
    ) -> CalcType? {
        let hinted1 = type1.withPercentHintApplied(hint)
        let hinted2 = type2.withPercentHintApplied(hint)
        guard hinted1.nonZeroValuesEqual(hinted2), hinted2.nonZeroValuesEqual(hinted1) else {
            return nil
        }
        var finalType = hinted1.mergingAbsentLanes(from: hinted2)
        finalType.percentHint = CalcType.PercentHintValue(hint)
        return finalType
    }

    /// `Type::add`, including its deviation from css-typed-om: step 2 only assigns the hint and does
    /// not fold `percent` into the hinted lane.
    ///
    /// The provisional-hint search masks this on spec-legal input.
    ///
    /// FIXME: the deviation is web-visible through Typed OM, whose `CSSNumericType::multiplyTypes`
    /// has the same omission. Fixing it there, here and in `normalizePercentHints` is one change.
    fileprivate func added(to other: CalcType) -> CalcType? {
        var type1 = self
        var type2 = other

        guard CalcType.normalizePercentHints(&type1, &type2) else {
            return nil
        }

        if type1.nonZeroValuesEqual(type2) && type2.nonZeroValuesEqual(type1) {
            return type1.mergingAbsentLanes(from: type2)
        }

        // Step 3, second branch, behind the C++'s own guard.
        guard
            (type1.percent != 0 || type2.percent != 0)
                && (type1.containsNonPercentEntry || type2.containsNonPercentEntry)
        else {
            return nil
        }

        if let merged = CalcType.addUnderHint(.Length, type1, type2) { return merged }
        if let merged = CalcType.addUnderHint(.Angle, type1, type2) { return merged }
        if let merged = CalcType.addUnderHint(.Time, type1, type2) { return merged }
        if let merged = CalcType.addUnderHint(.Frequency, type1, type2) { return merged }
        if let merged = CalcType.addUnderHint(.Resolution, type1, type2) { return merged }
        if let merged = CalcType.addUnderHint(.Flex, type1, type2) { return merged }

        return nil
    }

    /// `Type::sameType`.
    @inline(always)
    fileprivate func sameType(as other: CalcType) -> CalcType? {
        (self == other) ? self : nil
    }

    /// `Type::consistentType`, which is `add`.
    @inline(always)
    fileprivate func consistentType(with other: CalcType) -> CalcType? {
        added(to: other)
    }

    /// `Type::madeConsistent`. `self` is the C++'s `base`.
    @inline(always)
    fileprivate func madeConsistent(with input: CalcType) -> CalcType? {
        if hasPercentHint && input.hasPercentHint && !(percentHint == input.percentHint) {
            return nil
        }
        var base = self
        if !base.hasPercentHint {
            base.percentHint = input.percentHint
        }
        return base
    }

    // MARK: `validateType`, as the three predicates the math functions actually ask for

    /// `matchesAny<Match::Number>({ .allowsPercentHint = true })`.
    @inline(always)
    fileprivate var matchesNumber: Bool {
        length == 0 && angle == 0 && time == 0 && frequency == 0
            && resolution == 0 && flex == 0 && percent == 0
    }

    /// `matchesAny<Match::Number, Match::Angle>({ .allowsPercentHint = true })`.
    @inline(always)
    fileprivate var matchesNumberOrAngle: Bool {
        (angle == 0 || angle == 1) && length == 0 && time == 0 && frequency == 0
            && resolution == 0 && flex == 0 && percent == 0
    }

    /// Whether this type matches an angle, allowing a percent hint.
    ///
    /// `matchesAny<Match::Angle>({ .allowsPercentHint = true })`, the condition of `Deg2Rad`.
    @inline(always)
    fileprivate var matchesAngle: Bool {
        angle == 1 && length == 0 && time == 0 && frequency == 0
            && resolution == 0 && flex == 0 && percent == 0
    }

    /// `Type::calculationCategory()`, narrowed to the four answers the two slots of `anchor()`
    /// distinguish.
    @inline(always)
    fileprivate var anchorSlotCategory: CalcAnchorSlotCategory {
        if angle != 0 || time != 0 || frequency != 0 || resolution != 0 || flex != 0 {
            return .other
        }
        if length == 1 && percent == 0 {
            return hasPercentHint ? .lengthPercentage : .length
        }
        if length == 0 && percent == 1 {
            return .percentage
        }
        if length == 0 && percent == 0 {
            return .number
        }
        return .other
    }
}

/// The `CSS::Category` answers `anchor()` and `anchor-size()` act on, and one bucket for the rest.
private enum CalcAnchorSlotCategory {
    case length
    case lengthPercentage
    case number
    case percentage
    case other
}

/// `Type::multiply`.
@inline(always)
private func calcTypeMultiply(
    _ a: CalcType,
    _ b: CalcType
) -> CalcType? {
    a.multiplied(by: b)
}

/// `Type::invert`.
@inline(always)
private func calcTypeInvert(
    _ a: CalcType
) -> CalcType {
    a.inverted()
}

/// `Type::add`.
@inline(always)
private func calcTypeAdd(
    _ a: CalcType,
    _ b: CalcType
) -> CalcType? {
    a.added(to: b)
}

/// `Type::consistentType`.
@inline(always)
private func calcTypeConsistentType(
    _ a: CalcType,
    _ b: CalcType
) -> CalcType? {
    a.consistentType(with: b)
}

/// `Type::sameType`, for `mergeTypes<MergePolicy::Same>`.
@inline(always)
private func calcTypeSameType(
    _ a: CalcType,
    _ b: CalcType
) -> CalcType? {
    a.sameType(as: b)
}

/// `Type::madeConsistent`.
@inline(always)
private func calcTypeMadeConsistent(
    _ base: CalcType,
    _ input: CalcType
) -> CalcType? {
    base.madeConsistent(with: input)
}

/// `Type::applyPercentHint`, value-returning.
@inline(always)
private func calcTypeApplyPercentHint(
    _ a: CalcType,
    _ hint: WebCore.CSSCalc.PercentHint
) -> CalcType {
    a.withPercentHintApplied(hint)
}

/// A numeric leaf: everything `makeChildWithValueBasedOn` carries.
private struct NumericLeaf {
    let kind: NumericKind
    let value: Double
    /// A `CSSUnitType` underlying value: `toCSSUnit(leaf)`.
    let unitType: UInt16
    /// The underlying value of a `Type::PercentHint`, 0 for none.
    ///
    /// Meaningful only for `.percentage`.
    let percentHint: UInt8

    /// `makeChildWithValueBasedOn(value, a)`.
    @inline(always)
    func withValue(_ newValue: Double) -> NumericLeaf {
        NumericLeaf(kind: kind, value: newValue, unitType: unitType, percentHint: percentHint)
    }

    /// A bare `<number>`.
    @inline(always)
    static func number(_ value: Double) -> NumericLeaf {
        NumericLeaf(
            kind: .number,
            value: value,
            unitType: UInt16(WebCore.CSSUnitType.Number.rawValue),
            percentHint: 0
        )
    }

    /// A canonical `<angle>`.
    @inline(always)
    static func canonicalAngle(_ value: Double) -> NumericLeaf {
        NumericLeaf(
            kind: .canonicalDimension,
            value: value,
            unitType: UInt16(WebCore.CSSUnitType.Deg.rawValue),
            percentHint: 0
        )
    }

    /// A canonical `<length>`.
    @inline(always)
    static func canonicalLength(_ value: Double) -> NumericLeaf {
        NumericLeaf(
            kind: .canonicalDimension,
            value: value,
            unitType: UInt16(WebCore.CSSUnitType.Px.rawValue),
            percentHint: 0
        )
    }

    @inline(always)
    var boundaryLeaf: WebCore.CSSCalc.CSSCalcSwiftLeaf {
        WebCore.CSSCalc.CSSCalcSwiftLeaf(
            value: value,
            unitType: unitType,
            alternative: leafAlternativeRawValue(kind),
            percentHint: percentHint,
            valueID: 0
        )
    }

    /// A canonical dimension in a named canonical unit.
    @inline(always)
    static func canonical(_ value: Double, _ canonicalUnit: WebCore.CSSUnitType) -> NumericLeaf {
        NumericLeaf(
            kind: .canonicalDimension,
            value: value,
            unitType: UInt16(canonicalUnit.rawValue),
            percentHint: 0
        )
    }

    /// `makeChild(Percentage { .value = v, .hint = H })`.
    @inline(always)
    static func percentage(_ value: Double, _ hint: CalcType.PercentHintValue) -> NumericLeaf {
        NumericLeaf(
            kind: .percentage,
            value: value,
            unitType: UInt16(WebCore.CSSUnitType.Percentage.rawValue),
            percentHint: percentHintRawValue(hint)
        )
    }
}

/// `getType(const Percentage&)`.
///
/// The hint is tested with `!= 0` because `percentHintFromRawValue` answers
/// `nil` for both 0 and an out-of-range value.
@inline(always)
private func calcPercentageLeafType(_ leaf: NumericLeaf) -> CalcType? {
    var type = CalcType.makePercent()
    if leaf.percentHint != 0 {
        guard let hint = percentHintFromRawValue(leaf.percentHint) else {
            return nil
        }
        type = calcTypeApplyPercentHint(type, hint)
    }
    return type
}

/// `getType(const CanonicalDimension&)`: `determineType(toCSSUnit(d))`. `UInt8(exactly:)` because
/// narrowing the `uint16_t` unit can fail.
@inline(always)
private func calcCanonicalDimensionLeafType(_ leaf: NumericLeaf) -> CalcType? {
    guard let rawUnit = UInt8(exactly: leaf.unitType),
        let unit = WebCore.CSSUnitType(rawValue: rawUnit)
    else {
        return nil
    }
    return CalcType.determineType(unit)
}

/// `getType(const Child&)` for a numeric leaf.
@inline(always)
private func calcLeafType(_ leaf: NumericLeaf) -> CalcType? {
    switch leaf.kind {
    case .number:
        return CalcType()
    case .percentage:
        return calcPercentageLeafType(leaf)
    case .canonicalDimension, .nonCanonicalDimension:
        return calcCanonicalDimensionLeafType(leaf)
    }
}

/// The merge key for a leaf: its `CSSUnitType`, which `toNumericIdentity` maps one-to-one onto a
/// `NumericIdentity`. `CSSValue` stores a unit in 7 bits, so the mask never aliases two units and
/// indexing a 128-entry table with the key needs no bounds check.
@inline(always)
private func mergeKey(_ leaf: NumericLeaf) -> Int {
    Int(leaf.unitType & 0x7F)
}

// MARK: - The arithmetic
private enum CalcExecutor {
    /// `deg2rad`.
    @inline(always)
    static func degreesToRadians(_ degrees: Double) -> Double {
        degrees * (Double.pi / 180.0)
    }

    /// `rad2deg`.
    @inline(always)
    static func radiansToDegrees(_ radians: Double) -> Double {
        radians * (180.0 / Double.pi)
    }

    /// `getNearestMultiples`.
    @inline(always)
    static func nearestMultiples(_ a: Double, _ b: Double) -> (lower: Double, upper: Double) {
        if a.truncatingRemainder(dividingBy: b) == 0 {
            return (a, a)
        }
        let interval = b.magnitude
        let lower = (a / interval).rounded(.down) * interval
        return (lower, lower + interval)
    }

    /// `minWithSignedZero`: `min(0, -0)` is `-0`, which `Swift.min` does not give.
    @inline(always)
    static func minWithSignedZero(_ a: Double, _ b: Double) -> Double {
        if a == b {
            return a.sign == .minus ? a : b
        }
        return b < a ? b : a
    }

    /// `maxWithSignedZero`. `std::max(a, b)` is `a < b ? b : a`.
    @inline(always)
    static func maxWithSignedZero(_ a: Double, _ b: Double) -> Double {
        if a == b {
            return a.sign == .minus ? b : a
        }
        return a < b ? b : a
    }

    /// `OperatorExecutor<Operator::Invert>`.
    @inline(always)
    static func invert(_ a: Double) -> Double {
        1.0 / a
    }

    /// `OperatorExecutor<Operator::Sum>`. `+` is not associative, so callers accumulate in child
    /// order.
    @inline(always)
    static func sum(_ a: Double, _ b: Double) -> Double {
        a + b
    }

    /// The two-`double` overload of `OperatorExecutor<Operator::Min>`.
    ///
    /// Its NaN checks run first, so `min(1, NaN)` is `NaN` where `minWithSignedZero` alone would
    /// give `1`.
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

    /// `OperatorExecutor<Operator::Max>`.
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

    /// `OperatorExecutor<Operator::Clamp>`, which calls the signed-zero helpers directly after its
    /// own NaN check.
    @inline(always)
    static func clamp(_ minimum: Double, _ value: Double, _ maximum: Double) -> Double {
        if minimum.isNaN || value.isNaN || maximum.isNaN {
            return Double.nan
        }
        return maxWithSignedZero(minimum, minWithSignedZero(value, maximum))
    }

    /// `OperatorExecutor<Operator::RoundNearest>`.
    @inline(always)
    static func roundNearest(_ valueToRound: Double, _ roundingInterval: Double) -> Double {
        if valueToRound.isFinite && roundingInterval.isInfinite {
            return valueToRound.sign == .minus ? -0.0 : 0.0
        }
        let (lower, upper) = nearestMultiples(valueToRound, roundingInterval)
        return (upper - valueToRound).magnitude <= roundingInterval.magnitude / 2 ? upper : lower
    }

    /// `OperatorExecutor<Operator::RoundUp>`.
    @inline(always)
    static func roundUp(_ valueToRound: Double, _ roundingInterval: Double) -> Double {
        if valueToRound.isFinite && roundingInterval.isInfinite {
            // Returns the zero itself, so `-0` stays `-0`.
            if valueToRound == 0 {
                return valueToRound
            }
            return valueToRound.sign == .minus ? -0.0 : Double.infinity
        }
        return nearestMultiples(valueToRound, roundingInterval).upper
    }

    /// `OperatorExecutor<Operator::RoundDown>`.
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

    /// `OperatorExecutor<Operator::RoundToZero>`.
    @inline(always)
    static func roundToZero(_ valueToRound: Double, _ roundingInterval: Double) -> Double {
        if valueToRound.isFinite && roundingInterval.isInfinite {
            return valueToRound.sign == .minus ? -0.0 : 0.0
        }
        let (lower, upper) = nearestMultiples(valueToRound, roundingInterval)
        return upper.magnitude < lower.magnitude ? upper : lower
    }

    /// `OperatorExecutor<Operator::Mod>`.
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

    /// `OperatorExecutor<Operator::Rem>`.
    @inline(always)
    static func rem(_ a: Double, _ b: Double) -> Double {
        if b == 0 {
            return Double.nan
        }
        return a.truncatingRemainder(dividingBy: b)
    }

    @inline(always)
    static func sin(_ a: Double) -> Double {
        Darwin.sin(a)
    }

    @inline(always)
    static func cos(_ a: Double) -> Double {
        Darwin.cos(a)
    }

    /// `OperatorExecutor<Operator::Tan>`.
    ///
    /// The poles are exact comparisons against the same reduced constants the C++ uses
    /// (`tan(90deg)` is infinity per css-values-4), so the reduction must be bit-identical to the
    /// C++'s.
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

    @inline(always)
    static func asin(_ a: Double) -> Double {
        radiansToDegrees(Darwin.asin(a))
    }

    @inline(always)
    static func acos(_ a: Double) -> Double {
        radiansToDegrees(Darwin.acos(a))
    }

    @inline(always)
    static func atan(_ a: Double) -> Double {
        radiansToDegrees(Darwin.atan(a))
    }

    @inline(always)
    static func atan2(_ a: Double, _ b: Double) -> Double {
        radiansToDegrees(Darwin.atan2(a, b))
    }

    @inline(always)
    static func pow(_ a: Double, _ b: Double) -> Double {
        Darwin.pow(a, b)
    }

    @inline(always)
    static func sqrt(_ a: Double) -> Double {
        a.squareRoot()
    }

    @inline(always)
    static func log(_ a: Double) -> Double {
        Darwin.log(a)
    }

    /// `std::log(a) / std::log(b)`, as the C++ writes it; other spellings differ in the last place.
    @inline(always)
    static func log(_ a: Double, _ b: Double) -> Double {
        Darwin.log(a) / Darwin.log(b)
    }

    @inline(always)
    static func exp(_ a: Double) -> Double {
        Darwin.exp(a)
    }

    @inline(always)
    static func abs(_ a: Double) -> Double {
        a.magnitude
    }

    /// `OperatorExecutor<Operator::Sign>`.
    ///
    /// Returning `a` itself makes `sign(-0)` `-0` and `sign(NaN)` `NaN`.
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

    /// `OperatorExecutor<Operator::Progress>`.
    @inline(always)
    static func progress(_ progress: Double, _ from: Double, _ to: Double) -> Double {
        if from == to {
            return 0.0
        }
        return clamp(0.0, (progress - from) / (to - from), 1.0)
    }

    /// `OperatorExecutor<Operator::ProgressNoClamp>`.
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

    /// `OperatorExecutor<Operator::Random>`.
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

/// Whether this file can evaluate a node of this alternative with this many children: an arity no
/// parse produces is refused.
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
        // `simplify(Sum&)` asserts non-empty children.
        return childCount >= 1

    case .Product:
        // `simplify(Product&)` asserts non-empty children. Steps 9.1-9.3 can grow or shrink the
        // factor count, so there is no upper bound.
        return childCount >= 1

    case .Negate:
        return childCount == 1

    case .Min, .Max:
        // `simplifyForMinMax` asserts non-empty children. `rebuildSlot` takes all remaining
        // operands.
        return childCount >= 1

    case .Clamp:
        return childCount >= 1 && childCount <= 3

    case .Hypot:
        // `simplify(Hypot&)` has no arity condition; its executor defines the empty case.
        return true

    case .CalcMix:
        // With no items, `simplify(CalcMix&)` dereferences an empty `std::optional`.
        return childCount >= 1

    case .Random:
        // The `<random-key>` is not a child.
        return childCount == 2 || childCount == 3

    case .SiblingCount, .SiblingIndex:
        return true

    case .Anchor, .AnchorSize:
        return alternative == .Anchor ? childCount <= 2 : childCount <= 1

    @unknown default:
        // An alternative added in C++ and not handled here.
        return false
    }
}

// MARK: - The options the simplifier reads

/// The fields of `SimplificationOptions` the Swift simplifier reads.
///
/// A `struct`, because a class stored property pays dynamic exclusivity enforcement on every
/// read.
private struct CalcSimplification {
    /// `percentageResolveToDimension(options)`, computed in C++.
    let percentageResolveToDimension: Bool

    let allowZeroValueLengthRemovalFromSum: Bool

    /// `options.category` as the underlying value of a `CSS::Category`.
    ///
    /// For `Type::determinePercentHint(options.category)` in step 9.4.
    let category: UInt8

    /// Whether `options.conversionData` is set.
    ///
    /// Without it no relative length resolves, so `resolvedRelativeLength` does not ask
    /// the builder.
    let hasConversionData: Bool

    // MARK: Shared predicates

    /// `unitsMatch`, for two leaves already known to be the same alternative: `toCSSUnit` is
    /// injective per kind, so comparing units compares dimensions.
    @inline(always)
    func unitsMatch(_ a: NumericLeaf, _ b: NumericLeaf) -> Bool {
        a.unitType == b.unitType
    }

    /// `switchTogether`: the `Numeric T` visitor applies only to two operands of the same
    /// alternative.
    @inline(always)
    func switchTogether(_ a: NumericLeaf, _ b: NumericLeaf) -> Bool {
        a.kind == b.kind
    }

    /// `magnitudeComparable`.
    @inline(always)
    func magnitudeComparable(_ a: NumericLeaf) -> Bool {
        switch a.kind {
        case .number, .canonicalDimension, .nonCanonicalDimension:
            return true
        case .percentage:
            return !percentageResolveToDimension
        }
    }

    /// `fullyResolved`.
    ///
    /// Unlike `magnitudeComparable`, false for a `NonCanonicalDimension`.
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

extension CalcSimplification {
    /// The type step 9.4 folds with, or `nil` when step 9.4 stops and the node keeps its kind.
    /// `getType(const Percentage&)` applies a percent hint that the dimension overload has no
    /// analogue for, so the two stay separate.
    @inline(always)
    fileprivate func numericLeafType(_ leaf: NumericLeaf) -> CalcType? {
        switch leaf.kind {
        case .percentage:
            return percentageLeafType(leaf)

        case .canonicalDimension:
            return canonicalDimensionLeafType(leaf)

        case .number:
            return CalcType()

        case .nonCanonicalDimension:
            // Step 9.4's switch has no case for it.
            return nil
        }
    }

    @inline(always)
    fileprivate func percentageLeafType(_ leaf: NumericLeaf) -> CalcType? {
        calcPercentageLeafType(leaf)
    }

    @inline(always)
    fileprivate func canonicalDimensionLeafType(_ leaf: NumericLeaf) -> CalcType? {
        calcCanonicalDimensionLeafType(leaf)
    }

    /// `getType(const Child&)`.
    ///
    /// Unlike `numericLeafType`, it answers for a `NonCanonicalDimension`.
    @inline(always)
    fileprivate func leafType(_ leaf: NumericLeaf) -> CalcType? {
        calcLeafType(leaf)
    }

    /// The `CSS::Category` to numeric-leaf table shared by step 9.4's result switch and
    /// `zeroValueMatchingChild`. `nil` is each caller's own fall-through.
    @inline(always)
    fileprivate func numericLeafForCategory(_ resolvedCategory: WebCore.CSS.Category, _ value: Double) -> NumericLeaf? {
        switch resolvedCategory {
        case .Integer, .Number:
            return NumericLeaf.number(value)

        case .Percentage:
            // The options' category, not `resolvedCategory`, which is already `Percentage` here.
            guard let optionsCategory = WebCore.CSS.Category(rawValue: category) else {
                // Never taken: an imported C++ scoped enum's `init?(rawValue:)` does not validate.
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
            // A category added in C++ and not handled here.
            return nil
        }
    }
}

// MARK: - `canonicalize`, and the relative lengths only the builder can resolve

/// How far `canonicalize` gets on the unit alone.
private enum CanonicalizeStep {
    case leaf(NumericLeaf)
    case relativeLength
}

extension CalcSimplification {
    /// `canonicalize`, except that a relative length is reported, not resolved: only the builder
    /// holds the conversion data.
    @inline(always)
    fileprivate func canonicalizeStep(_ value: Double, _ unitType: UInt16) -> CanonicalizeStep {
        func unchanged() -> CanonicalizeStep {
            .leaf(NumericLeaf(kind: .nonCanonicalDimension, value: value, unitType: unitType, percentHint: 0))
        }
        // `makeCanonical(value, dimension)`, naming the canonical unit because `Dimension` does not
        // cross the boundary. There is no `Fr` case: `canonicalize` has none for `Dimension::Flex`.
        func canonical(_ canonicalized: Double, _ canonicalUnit: WebCore.CSSUnitType) -> CanonicalizeStep {
            .leaf(
                NumericLeaf(
                    kind: .canonicalDimension,
                    value: canonicalized,
                    unitType: UInt16(canonicalUnit.rawValue),
                    percentHint: 0
                )
            )
        }

        // `UInt8(exactly:)` because narrowing can fail. `CSSUnitType(rawValue:)` accepts any value,
        // so an out-of-enum unit reaches `default` below, as it reaches the C++'s
        // `ASSERT_NOT_REACHED` in a Release build.
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

        // Units a `NonCanonicalDimension` never holds: `ASSERT_NOT_REACHED` in the C++. Listed so
        // they do not reach `default`.
        case .Px, .Deg, .S, .Hz, .Dppx, .Fr,
            .Number, .Integer, .Percentage,
            .Calc, .CalcPercentageWithAngle, .CalcPercentageWithLength, .QuirkyEm, .Unknown:
            return unchanged()

        default:
            // Every relative length, without restating `CSS::toLengthUnit`'s membership. The builder
            // checks `CSS::toLengthUnit` first and reports a non-length unit as unresolved, so a
            // newly added unit is left unchanged, never mis-converted.
            return .relativeLength
        }
    }

    /// `tryMakeCanonical`: `Style::resolveLength` with the builder's `CSSToLengthConversionData`.
    ///
    /// An unresolved answer leaves the dimension as it is.
    @inline(always)
    fileprivate func resolvedRelativeLength(
        _ value: Double,
        _ unitType: UInt16,
        _ builder: borrowing WebCore.CSSCalc.CSSCalcSwiftBuilder
    ) -> NumericLeaf {
        guard hasConversionData else {
            return NumericLeaf(kind: .nonCanonicalDimension, value: value, unitType: unitType, percentHint: 0)
        }
        let resolved = builder.resolveRelativeLength(value, unitType)
        guard resolved.resolved else {
            return NumericLeaf(kind: .nonCanonicalDimension, value: value, unitType: unitType, percentHint: 0)
        }
        return NumericLeaf(
            kind: .canonicalDimension,
            value: resolved.value,
            unitType: resolved.unitType,
            percentHint: 0
        )
    }

    /// `simplify(NonCanonicalDimension&)`: canonicalize if there is enough information, otherwise
    /// leave it alone.
    @inline(always)
    fileprivate func canonicalizedDimension(
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

/// The running type tag of `simplify(Hypot&)`.
///
/// `Variant<std::monostate, NumberTag, PercentageTag, DimensionTag, FailureTag>` in the C++.
private enum HypotTag {
    case unset
    case number
    case percentage
    case dimension(UInt16)
    case failed
}

extension CalcSimplification {
    // MARK: `hypot()`

    @inline(always)
    fileprivate func hypotElement(_ leaf: NumericLeaf, _ tag: inout HypotTag) -> Double {
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
            // Absorbing; the loop keeps running.
            return Double.nan
        }
    }

    // MARK: the merge tables

    /// `offsetOfFirstInstance`, keyed by `mergeKey`.
    fileprivate typealias MergeTable = InlineArray<128, UInt32>
    /// `FirstInstance::canRemove`, one flag per `mergeKey`, separate so `Min`/`Max` do not pay for it.
    fileprivate typealias MergeFlags = InlineArray<128, Bool>

    // MARK: `Sum`'s zero-length removal

    /// `isLength(id) && options.allowZeroValueLengthRemovalFromSum`.
    @inline(always)
    fileprivate func lengthRemovalAllowed(_ leaf: NumericLeaf) -> Bool {
        guard allowZeroValueLengthRemovalFromSum else {
            return false
        }
        switch leaf.kind {
        case .number, .percentage:
            return false
        case .canonicalDimension:
            return leaf.unitType == UInt16(WebCore.CSSUnitType.Px.rawValue)
        case .nonCanonicalDimension:
            // An out-of-enum unit reaches `toNumericIdentity`'s `ASSERT_NOT_REACHED` branch and
            // comes back `NumericIdentity::Number`, not a length, as in the C++: the term stays.
            guard let raw = UInt8(exactly: leaf.unitType),
                let unit = WebCore.CSSUnitType(rawValue: raw)
            else {
                return false
            }
            var dimension = WebCore.CSSCalc.NonCanonicalDimension()
            dimension.value = 0
            dimension.unit = unit
            return WebCore.CSSCalc.isLength(WebCore.CSSCalc.toNumericIdentity(dimension))
        }
    }

    // MARK: `Product`'s numeric factor

    /// `numericProduct = Number { .value = childValue->value * numericProduct->value }`.
    ///
    /// The new factor is the left operand, as in the C++, because IEEE-754 leaves the sign of a NaN
    /// product unspecified.
    @inline(always)
    fileprivate func multipliedNumericProduct(_ value: Double, _ accumulated: Double?) -> Double {
        if let accumulated {
            return value * accumulated
        }
        return value
    }
}

// MARK: - The entry point

/// Which alternatives the Swift simplifier covers, as a mask over the same alternative index
/// `kindMask` is built from.
private enum CalcCoverage {
    /// The bit for one alternative.
    ///
    /// `&<<`, not `<<`: the smart shift lowers to a branchy sequence per term, and LLVM stops folding
    /// the chain of 41 of them in `mask`. With fewer than 64 alternatives, masking the amount changes
    /// nothing.
    @inline(always)
    static func bit(_ alternative: CalcAlternative) -> UInt64 {
        UInt64(1) &<< UInt64(alternative.rawValue)
    }

    /// A computed `static var`, not a `static let`, so that it folds to a constant rather than being
    /// read through a `swift_once` guard.
    static var mask: UInt64 {
        bit(.Number)
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

// MARK: - The second entry point

/// Whether simplifying this tree could change it, as `canSimplifyWithCpp` answers.
@_expose(Cxx)
public func cssCalcCanSimplifySwift(_ stored: CSSCalcSwiftRoot) -> Bool {
    switch stored.root.alternative {
    case .Number, .Percentage, .CanonicalDimension:
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
        // As the C++ catch-all answers, and the conservative direction.
        return true
    }
}

// MARK: - `calc-mix()`

/// What one pass over the weight list of a `calc-mix()` found.
private struct CalcMixWeightSurvey {
    /// False as soon as any weight is a `Calc`: normalisation is off for the whole node.
    var canNormalize = true
    /// The sum of every `Raw` weight in item order, zeros included, in the C++'s addition order.
    var total = 0.0
    var numberOfOmittedWeights: UInt32 = 0
    var numberOfKnownZeroWeights: UInt32 = 0
}

/// One item's disposition under spec steps 1 to 5, as values.
private struct CalcMixItemPlan {
    let survives: Bool
    /// The effective weight as a `<percentage>`.
    ///
    /// Meaningful only where `canNormalize` held.
    let weight: Double
    /// Whether the rebuild carries `weight` (step 2 or step 4) rather than the item's own weight.
    let replaceWeight: Bool

    static let dropped = CalcMixItemPlan(survives: false, weight: 0, replaceWeight: false)
}

/// What spec steps 1 to 5, as `simplify(CalcMix&)` implements them, do to one item.
@inline(always)
private func calcMixItemPlan(
    _ weight: CalcMixWeight,
    _ survey: CalcMixWeightSurvey
) -> CalcMixItemPlan {
    // `item.weight && item.weight->isKnownZero()`. A `Calc` weight is never known to be zero.
    let isKnownZero = weight.present && weight.isRaw && weight.value == 0

    if !survey.canNormalize {
        // The C++ returns `{ }` from every path of this branch, so each survivor keeps its own weight.
        return isKnownZero
            ? .dropped
            : CalcMixItemPlan(survives: true, weight: weight.value, replaceWeight: false)
    }

    if survey.total >= 100 {
        guard weight.present, !isKnownZero else {
            return .dropped
        }
        // A multiply by `normalizationFactor`, as the C++ has it; a divide differs in the last bit.
        return CalcMixItemPlan(
            survives: true,
            weight: weight.value * (100.0 / survey.total),
            replaceWeight: true
        )
    }

    if weight.present {
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

extension CalcSimplification {
    /// Whether the accumulator and this item are the same kind with the same unit or hint.
    ///
    /// Unlike `unitsMatch`, a percentage compares its hint, as `simplify(CalcMix&)` does.
    @inline(always)
    fileprivate func calcMixAccumulatorAgrees(_ current: NumericLeaf, _ leaf: NumericLeaf) -> Bool {
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

/// The "no payload" index: `CalcNode.origin` on a parsed node that names no payload, and the
/// payload argument of `pushCalcMixItemWeight` for a weight that is not a math function.
var calcNoPayload: UInt32 { WebCore.CSSCalc.cssCalcSwiftFlatNoNode }

/// The bits on `CalcNode.flags`.
enum CalcNodeFlags {
    /// The minimum bound of `clamp()` is the keyword `none`.
    static let clampNoneMinimum: UInt16 = 1 << 0
    /// The maximum bound of `clamp()` is the keyword `none`.
    static let clampNoneMaximum: UInt16 = 1 << 1
    /// The `noneMask` of `buildOperation`.
    ///
    /// The bit positions are the boundary's (bit 0 the minimum, bit 1 the maximum, as
    /// `CSSCalcSwiftTypes.h` states) and are passed through untranslated.
    static let clampNoneMask: UInt16 = clampNoneMinimum | clampNoneMaximum
    /// The `<anchor-side>` of `anchor()` is a subtree rather than a keyword.
    ///
    /// It occupies child slot 0, and the fallback, if there is one, is slot 1.
    static let anchorSideIsSubtree: UInt16 = 1 << 2
    /// This node is inside the `<anchor-side>` subtree of an `anchor()`.
    ///
    /// It is never simplified: `simplify(Anchor&)` copies the side, so `anchor(--a calc(25% + 25%))`
    /// keeps its sum.
    static let insideAnchorSide: UInt16 = 1 << 3
    /// On an interleaved weight node of a parsed `calc-mix()`: the author wrote a `<percentage>` here.
    ///
    /// Clear means the item's weight was omitted, which folds differently from `0%`: `0%` is
    /// dropped, an absent weight takes step 2's `(100% - total) / n`.
    static let calcMixWeightPresent: UInt16 = 1 << 4
    /// On a parsed `anchor()` node: the `<anchor-side>` was written as a math function.
    ///
    /// `consumeValueWithoutSimplifyingRootCalc` wraps a function that parsed to a leaf in a one-child
    /// `Sum`, so that `anchor(--a calc(50%))` keeps its `calc()` when serialized, and
    /// `anchorSlotKeepingPrefix` restores that wrapper after simplification. A `<calc-value>` that is
    /// not a function is always a leaf, so this bit plus a leaf test at emit reproduces the wrapper
    /// without the grammar building it.
    static let anchorSideWasFunction: UInt16 = 1 << 5
    /// The same, for the `<length-percentage>` fallback slot of an `anchor()` or an `anchor-size()`.
    static let anchorFallbackWasFunction: UInt16 = 1 << 6
    /// On a weight node of a parsed `calc-mix()`: the weight is a math function.
    ///
    /// `origin` indexes the payload table and `value` means nothing. Implies `calcMixWeightPresent`.
    ///
    /// Such a weight is a separate `CSSCalc::Value` with its own category, range and simplification
    /// (`UnevaluatedCalcBase::parseBase`), not part of this tree, so it is resolved by
    /// `consumeCalcMixWeightAt` rather than held as a subtree.
    static let calcMixWeightIsCalc: UInt16 = 1 << 7
    /// On a `Sum`, `Product`, `Min` or `Max` the grammar built: `calcFoldAtConstruction` already
    /// folded it with the options `simplifyParsed` uses, so the parse's pass skips its fold.
    ///
    /// This holds because nothing changes a node's children after `calcFoldAtConstruction`
    /// returns it.
    static let foldedAtConstruction: UInt16 = 1 << 8
}

/// What `emitParsed` can materialise, as two masks over the alternative index.
private enum CalcParsedEmitCoverage {
    /// Every leaf alternative, all of which `pushLeaf` serves.
    static var leafMask: UInt64 {
        CalcCoverage.bit(.Number)
            | CalcCoverage.bit(.Percentage)
            | CalcCoverage.bit(.CanonicalDimension)
            | CalcCoverage.bit(.NonCanonicalDimension)
            | CalcCoverage.bit(.SiblingCount)
            | CalcCoverage.bit(.SiblingIndex)
            | CalcCoverage.bit(.Symbol)
    }

    /// The operations `buildOperation` constructs from operands alone.
    ///
    /// The `none` bounds of `Clamp` travel in `noneMask`; for `round()` and `log()` the optional second
    /// slot's presence is the operand count.
    static var operationMask: UInt64 {
        CalcCoverage.bit(.Clamp)
            | CalcCoverage.bit(.RoundNearest)
            | CalcCoverage.bit(.RoundUp)
            | CalcCoverage.bit(.RoundDown)
            | CalcCoverage.bit(.RoundToZero)
            | CalcCoverage.bit(.Log)
            | CalcCoverage.bit(.Hypot)
            | CalcCoverage.bit(.Mod)
            | CalcCoverage.bit(.Rem)
            | CalcCoverage.bit(.Atan2)
            | CalcCoverage.bit(.Pow)
            | CalcCoverage.bit(.Progress)
            | CalcCoverage.bit(.ProgressNoClamp)
            | CalcCoverage.bit(.Sum)
            | CalcCoverage.bit(.Product)
            | CalcCoverage.bit(.Min)
            | CalcCoverage.bit(.Max)
            | CalcCoverage.bit(.Negate)
            | CalcCoverage.bit(.Invert)
            | CalcCoverage.bit(.Deg2Rad)
            | CalcCoverage.bit(.Sin)
            | CalcCoverage.bit(.Cos)
            | CalcCoverage.bit(.Tan)
            | CalcCoverage.bit(.Asin)
            | CalcCoverage.bit(.Acos)
            | CalcCoverage.bit(.Atan)
            | CalcCoverage.bit(.Sqrt)
            | CalcCoverage.bit(.Exp)
            | CalcCoverage.bit(.Abs)
            | CalcCoverage.bit(.Sign)
    }
}

// MARK: - The owned tree

/// One node of a calc tree, owning its children.
///
/// `~Copyable` because a copy would be a deep copy of the subtree; a node moves into its parent's
/// `children` and out again. `origin` indexes the node's payload, on the nodes that have one, in the
/// payload table stored with the tree.
struct CalcNode: ~Copyable {
    var value: Double
    /// Carried, as `copyAndSimplify` keeps a node's type when its kind does not change.
    ///
    /// A leaf's is cleared; see `emittedType`.
    var type: CalcType
    var origin: UInt32
    var valueID: UInt16
    var unitType: UInt8
    var alternative: CalcAlternative
    var percentHint: UInt8
    /// `CalcNodeFlags`.
    var flags: UInt16
    var children: UniqueArray<CalcNode>

    @inline(always)
    init(
        value: Double,
        type: CalcType,
        origin: UInt32,
        valueID: UInt16,
        unitType: UInt8,
        alternative: CalcAlternative,
        percentHint: UInt8,
        flags: UInt16,
        children: consuming UniqueArray<CalcNode>
    ) {
        self.value = value
        self.type = type
        self.origin = origin
        self.valueID = valueID
        self.unitType = unitType
        self.alternative = alternative
        self.percentHint = percentHint
        self.flags = flags
        self.children = children
    }
}

/// The tree `CSSCalc::Tree` stores.
///
/// A class because a C++ type cannot hold a `~Copyable` Swift struct, and not a struct wrapping one
/// because C++ copies a Swift class with a direct `swift_retain`/`swift_release` but a struct through
/// its value-witness table, and C++ moves a `CSSCalc::Tree` by copying it. The tree is never mutated
/// once stored, so every copy of a `Tree` shares it.
@_expose(Cxx)
public final class CSSCalcSwiftRoot: Sendable {
    let root: CalcNode

    init(_ root: consuming CalcNode) {
        self.root = root
    }

    /// The root an entry answers when it has none, beside the failure it reports. Not an `Optional`,
    /// because C++ holds a `swift::Optional`'s payload in heap storage and copies it through the
    /// value-witness table. One shared object, so that a failed parse allocates nothing. The C++ reads
    /// a root only from a `Parsed` outcome, a simplified result or a finished builder, so this one is
    /// never read.
    static var none: CSSCalcSwiftRoot { calcNoRoot }
}

private let calcNoRoot = CSSCalcSwiftRoot(
    CalcNode(
        value: 0,
        type: CalcType(),
        origin: calcNoPayload,
        valueID: 0,
        unitType: 0,
        alternative: .Number,
        percentHint: 0,
        flags: 0,
        children: UniqueArray()
    )
)

// MARK: The stored tree, read as the `CSSCalc::Child` it stands for

/// One node, as the walks read it.
///
/// Each field is meaningful only for the kinds that carry it.
struct CalcNodeInfo {
    var numericValue: Double
    /// Operands, as `Child::operator[]` counts them: a `clamp()` bound holding `none` is not one, which
    /// is why the two `clampWithNone...` kinds exist.
    var childCount: UInt32
    var valueID: UInt16
    /// A numeric leaf's unit, or the own unit of a `Symbol` rather than the symbol table's.
    var unitType: UInt8
    var kind: CalcNodeKind
    /// The underlying value of a `Type::PercentHint`, 0 for none.
    var percentHint: UInt8
    var alternative: CalcAlternative
    /// An `anchor()` whose `<anchor-side>` is a subtree rather than a keyword, so child 0 is the side.
    var anchorSideIsSubtree: Bool
}

/// One `calc-mix()` item's weight.
///
/// Three states in two bools: absent, a number (`isRaw`), or a math function, whose value stays in
/// its payload.
struct CalcMixWeight {
    var value: Double
    var present: Bool
    var isRaw: Bool
}

/// A stored tree has the shape of the `CSSCalc::Child` it stands for, with one exception: a
/// `calc-mix()`'s children interleave each item's value with a node carrying its weight. These read
/// a node as `Child::operator[]` and the `Child` accessors read the `Child`.
extension CalcNode {
    /// Operand `k`, counted as `Child::operator[]` counts: a `calc-mix()` item's value, not its weight.
    subscript(_ k: Int) -> CalcNode {
        borrow {
            return children[alternative == .CalcMix ? k &* 2 : k]
        }
    }

    /// The weight node of item `k`, of a `calc-mix()`.
    func calcMixWeight(_ k: Int) -> CalcMixWeight {
        let flags = children[k &* 2 &+ 1].flags
        let present = flags & CalcNodeFlags.calcMixWeightPresent != 0
        return CalcMixWeight(
            value: children[k &* 2 &+ 1].value,
            present: present,
            isRaw: present && flags & CalcNodeFlags.calcMixWeightIsCalc == 0
        )
    }

    /// The weight payload of item `k`, or `calcNoPayload` when the weight is a number or absent.
    func calcMixWeightPayload(_ k: Int) -> UInt32 {
        let w = k &* 2 &+ 1
        return children[w].flags & CalcNodeFlags.calcMixWeightIsCalc != 0 ? children[w].origin : calcNoPayload
    }

    var info: CalcNodeInfo {
        let kind: CalcNodeKind
        var valueID: UInt16 = 0
        switch alternative {
        case .Number: kind = .number
        case .Percentage: kind = .percentage
        case .CanonicalDimension: kind = .canonicalDimension
        case .NonCanonicalDimension: kind = .nonCanonicalDimension
        case .Symbol:
            kind = .symbol
            valueID = self.valueID
        case .SiblingCount:
            kind = .siblingCount
            valueID = calcValueID(WebCore.CSSValueSiblingCount)
        case .SiblingIndex:
            kind = .siblingIndex
            valueID = calcValueID(WebCore.CSSValueSiblingIndex)
        case .Sum: kind = .sum
        case .Product: kind = .product
        case .Negate: kind = .negate
        case .Invert: kind = .invert
        case .Deg2Rad: kind = .transparent
        case .Clamp:
            valueID = calcValueID(WebCore.CSSValueClamp)
            switch flags & CalcNodeFlags.clampNoneMask {
            case CalcNodeFlags.clampNoneMask: kind = .clampWithNoneMinimumAndMaximum
            case CalcNodeFlags.clampNoneMinimum: kind = .clampWithNoneMinimum
            case CalcNodeFlags.clampNoneMaximum: kind = .clampWithNoneMaximum
            default: kind = .function
            }
        case .RoundNearest:
            kind = .roundFunction
            valueID = calcValueID(WebCore.CSSValueNearest)
        case .RoundUp:
            kind = .roundFunction
            valueID = calcValueID(WebCore.CSSValueUp)
        case .RoundDown:
            kind = .roundFunction
            valueID = calcValueID(WebCore.CSSValueDown)
        case .RoundToZero:
            kind = .roundFunction
            valueID = calcValueID(WebCore.CSSValueToZero)
        case .ProgressNoClamp:
            kind = .progressNoClampFunction
            valueID = calcValueID(WebCore.CSSValueProgress)
        case .Random:
            kind = .randomFunction
            valueID = calcValueID(WebCore.CSSValueRandom)
        case .CalcMix:
            kind = .calcMixFunction
            valueID = calcValueID(WebCore.CSSValueCalcMix)
        case .Anchor:
            kind = .anchorFunction
            valueID = calcValueID(WebCore.CSSValueAnchor)
        case .AnchorSize:
            kind = .anchorSizeFunction
            valueID = calcValueID(WebCore.CSSValueAnchorSize)
        case .Min, .Max, .Mod, .Rem, .Sin, .Cos, .Tan, .Asin, .Acos, .Atan, .Atan2, .Pow, .Sqrt, .Hypot,
            .Log, .Exp, .Abs, .Sign, .Progress:
            kind = .function
            valueID = calcFunctionValueID(alternative)
        @unknown default:
            // An alternative added in C++ and not taught here: `.Operation` is refused by the
            // serializer before anything is written.
            kind = .operation
        }
        let isLeaf = children.isEmpty && CalcCoverage.bit(alternative) & CalcParsedEmitCoverage.leafMask != 0
        return CalcNodeInfo(
            numericValue: isLeaf ? value : 0,
            childCount: UInt32(truncatingIfNeeded: alternative == .CalcMix ? children.count / 2 : children.count),
            valueID: valueID,
            unitType: isLeaf ? unitType : UInt8(WebCore.CSSUnitType.Unknown.rawValue),
            kind: kind,
            percentHint: alternative == .Percentage ? percentHint : 0,
            alternative: alternative,
            anchorSideIsSubtree: alternative == .Anchor && flags & CalcNodeFlags.anchorSideIsSubtree != 0
        )
    }

    /// The sharing of a `random()` is read through `sink`, from the payload.
    func operationInfo(_ sink: borrowing WebCore.CSSCalc.CSSCalcSwiftSink) -> WebCore.CSSCalc.CSSCalcSwiftOperationInfo {
        if alternative == .Random {
            return sink.randomSharingInfo(origin)
        }
        let isAnchor = alternative == .Anchor
        let sideIsSubtree = isAnchor && flags & CalcNodeFlags.anchorSideIsSubtree != 0
        return WebCore.CSSCalc.CSSCalcSwiftOperationInfo(
            valueID: valueID,
            randomSharingIsKey: false,
            randomSharingIsFixed: false,
            randomKeyHasName: false,
            randomKeyIsElementScoped: false,
            randomKeyHasPropertyScope: false,
            anchorSideIsKeyword: isAnchor && !sideIsSubtree,
            hasElementName: origin != calcNoPayload,
            hasDimension: alternative == .AnchorSize && valueID != 0,
            hasFallback: children.count > (sideIsSubtree ? 1 : 0)
        )
    }

    /// A deep copy, for a fold that must not change the tree it was handed.
    func clone() -> CalcNode {
        var copied = UniqueArray<CalcNode>(capacity: children.count)
        var k = 0
        while k < children.count {
            copied.append(children[k].clone())
            k &+= 1
        }
        return CalcNode(
            value: value,
            type: type,
            origin: origin,
            valueID: valueID,
            unitType: unitType,
            alternative: alternative,
            percentHint: percentHint,
            flags: flags,
            children: copied
        )
    }
}

@inline(always)
private func calcValueID(_ id: WebCore.CSSValueID) -> UInt16 {
    id.rawValue
}

/// `Op::id` for the operations serialized as `name(args...)`.
private func calcFunctionValueID(_ alternative: CalcAlternative) -> UInt16 {
    switch alternative {
    case .Min: return calcValueID(WebCore.CSSValueMin)
    case .Max: return calcValueID(WebCore.CSSValueMax)
    case .Mod: return calcValueID(WebCore.CSSValueMod)
    case .Rem: return calcValueID(WebCore.CSSValueRem)
    case .Sin: return calcValueID(WebCore.CSSValueSin)
    case .Cos: return calcValueID(WebCore.CSSValueCos)
    case .Tan: return calcValueID(WebCore.CSSValueTan)
    case .Asin: return calcValueID(WebCore.CSSValueAsin)
    case .Acos: return calcValueID(WebCore.CSSValueAcos)
    case .Atan: return calcValueID(WebCore.CSSValueAtan)
    case .Atan2: return calcValueID(WebCore.CSSValueAtan2)
    case .Pow: return calcValueID(WebCore.CSSValuePow)
    case .Sqrt: return calcValueID(WebCore.CSSValueSqrt)
    case .Hypot: return calcValueID(WebCore.CSSValueHypot)
    case .Log: return calcValueID(WebCore.CSSValueLog)
    case .Exp: return calcValueID(WebCore.CSSValueExp)
    case .Abs: return calcValueID(WebCore.CSSValueAbs)
    case .Sign: return calcValueID(WebCore.CSSValueSign)
    case .Progress: return calcValueID(WebCore.CSSValueProgress)
    default: return 0
    }
}

/// Restore the one-child `Sum` a `calc()` in an `anchor()` slot leaves when it parses or folds to a
/// leaf. `anchor()` is not a math function, so the C++ keeps that wrapper
/// (`anchorSlotKeepingPrefix`) and serializes `anchor(--a calc(50%))` with its `calc()`.
///
/// The grammar records the prefix as a flag rather than building the wrapper, and a fold may
/// collapse it again, so this runs after every fold of a tree that is kept. A wrapped side keeps
/// `insideAnchorSide`, which is what stops a later fold collapsing it.
func calcRestoreAnchorPrefixes(_ node: inout CalcNode) {
    var k = 0
    while k < node.children.count {
        calcRestoreAnchorPrefixes(&node.children[k])
        k &+= 1
    }
    guard node.alternative == .Anchor || node.alternative == .AnchorSize else {
        return
    }
    let sideSlots = node.flags & CalcNodeFlags.anchorSideIsSubtree != 0 ? 1 : 0
    k = 0
    while k < node.children.count {
        let prefixBit = k < sideSlots ? CalcNodeFlags.anchorSideWasFunction : CalcNodeFlags.anchorFallbackWasFunction
        if node.flags & prefixBit != 0, node.children[k].children.isEmpty,
            CalcCoverage.bit(node.children[k].alternative) & CalcParsedEmitCoverage.leafMask != 0,
            let leafType = calcParsedLeafType(node.children[k])
        {
            let inherited = node.children[k].flags & CalcNodeFlags.insideAnchorSide
            var wrapped = UniqueArray<CalcNode>(capacity: 1)
            wrapped.append(node.children.remove(at: k))
            node.children.insert(
                CalcNode(
                    value: 0,
                    type: leafType,
                    origin: calcNoPayload,
                    valueID: 0,
                    unitType: 0,
                    alternative: .Sum,
                    percentHint: 0,
                    flags: inherited,
                    children: wrapped
                ),
                at: k
            )
        }
        k &+= 1
    }
}

extension CalcNode {
    fileprivate var childCount: Int { children.count }

    /// The four numeric leaves, the only alternatives that carry a foldable value.
    fileprivate var isNumericLeaf: Bool {
        switch alternative {
        case .Number, .Percentage, .CanonicalDimension, .NonCanonicalDimension: return true
        default: return false
        }
    }

    /// This node as the boundary's leaf representation, or nil if it is not one of the four.
    fileprivate var numericLeaf: NumericLeaf? {
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

    /// The leaf `pushLeaf` takes for the three non-numeric leaf alternatives, or nil.
    fileprivate var nonNumericLeaf: WebCore.CSSCalc.CSSCalcSwiftLeaf? {
        switch alternative {
        case .Symbol:
            return WebCore.CSSCalc.CSSCalcSwiftLeaf(
                value: 0,
                unitType: UInt16(unitType),
                alternative: CalcAlternative.Symbol.rawValue,
                percentHint: 0,
                valueID: valueID
            )
        case .SiblingCount:
            return WebCore.CSSCalc.CSSCalcSwiftLeaf(
                value: 0,
                unitType: 0,
                alternative: CalcAlternative.SiblingCount.rawValue,
                percentHint: 0,
                valueID: 0
            )
        case .SiblingIndex:
            return WebCore.CSSCalc.CSSCalcSwiftLeaf(
                value: 0,
                unitType: 0,
                alternative: CalcAlternative.SiblingIndex.rawValue,
                percentHint: 0,
                valueID: 0
            )
        default:
            return nil
        }
    }

    /// `getType(const Child&)` for this node as it will be emitted.
    fileprivate func emittedType(_ options: CalcSimplification) -> CalcType? {
        switch alternative {
        case .Number, .Percentage, .CanonicalDimension, .NonCanonicalDimension:
            guard let leaf = numericLeaf else {
                return nil
            }
            return options.leafType(leaf)
        case .Symbol:
            guard let unit = WebCore.CSSUnitType(rawValue: unitType) else {
                return nil
            }
            return CalcType.determineType(unit)
        case .SiblingCount, .SiblingIndex:
            return CalcType()
        default:
            return type
        }
    }

    /// Replace the node with its child `k`, the C++'s `return { WTF::move(root.children[k]) }`.
    ///
    /// The child keeps its own `flags` and `origin`.
    @inline(always)
    fileprivate mutating func promote(_ k: Int) {
        self = children.remove(at: k)
    }

    /// `promote`, but a promoted leaf takes this node's emptied children buffer, for
    /// `calcFoldAtConstruction` to reuse.
    @inline(always)
    fileprivate mutating func promoteKeepingBuffer(_ k: Int) {
        var child = children.remove(at: k)
        if child.children.isEmpty {
            swap(&child.children, &children)
            child.children.removeAll()
        }
        self = child
    }

    /// Overwrite this node with a numeric leaf, keeping `flags` (which describe the slot) and
    /// `origin`.
    ///
    /// False, with nothing written, if the unit does not fit. `keepingBuffer` leaves the emptied
    /// children buffer in place for `calcFoldAtConstruction`.
    @discardableResult
    fileprivate mutating func setLeaf(_ leaf: NumericLeaf, keepingBuffer: Bool = false) -> Bool {
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
        value = leaf.value
        type = CalcType()
        if keepingBuffer {
            children.removeAll()
        } else {
            children = UniqueArray()
        }
        valueID = 0
        unitType = unit
        self.alternative = alternative
        percentHint = leaf.percentHint
        return true
    }

    /// `std::ranges::all_of(children, isNumeric)`.
    ///
    /// True for an empty list, as `all_of` is.
    fileprivate func allChildrenAreNumericLeaves() -> Bool {
        var k = 0
        while k < children.count {
            guard children[k].isNumericLeaf else {
                return false
            }
            k &+= 1
        }
        return true
    }

    /// Remove child `k`, keeping the order of the rest, by bubbling it to the end on the safe
    /// `MutableSpan`.
    @inline(always)
    fileprivate mutating func dropChild(_ k: Int) {
        let n = children.count
        var span = children.mutableSpan
        var j = k
        while j &+ 1 < n {
            span.swapAt(j, j &+ 1)
            j &+= 1
        }
        _ = consume span
        _ = children.removeLast()
    }
}

/// What a simplification pass over a `CalcNode` tree reads, and its one output besides the tree.
private struct CalcFold {
    init(
        options: CalcSimplification,
        builder: WebCore.CSSCalc.CSSCalcSwiftBuilder?,
        keepsBuffers: Bool = false,
        refoldsStoredTree: Bool = false
    ) {
        self.options = options
        self.builder = builder
        self.keepsBuffers = keepsBuffers
        self.refoldsStoredTree = refoldsStoredTree
    }

    let options: CalcSimplification
    let builder: WebCore.CSSCalc.CSSCalcSwiftBuilder?
    /// Whether `foldSum` and `foldProduct` leave a collapsed node's buffer on its leaf.
    ///
    /// Set only by `calcFoldAtConstruction`, which reuses it; a kept tree must not carry empty
    /// buffers.
    var keepsBuffers = false
    /// `simplifyParsed` over a stored tree, which the parse folded without conversion data: every
    /// node is folded again, including the functions that read the builder.
    let refoldsStoredTree: Bool
    /// A fold discovered mid-pass that it cannot finish, so the whole tree is refused.
    ///
    /// Whole-tree rather than per-node because the operand stack has no pop, and leaving the node as
    /// it arrived would be a silently wrong computed value.
    var declined = false
}

// MARK: The folds that read nothing but the node and its children

extension CalcFold {
    /// False: an alternative none of these folds covers.
    @discardableResult
    fileprivate mutating func foldFunction(_ node: inout CalcNode) -> Bool {
        switch node.alternative {
        case .Clamp: foldClamp(&node)
        case .RoundNearest: foldRound(&node, CalcExecutor.roundNearest)
        case .RoundUp: foldRound(&node, CalcExecutor.roundUp)
        case .RoundDown: foldRound(&node, CalcExecutor.roundDown)
        case .RoundToZero: foldRound(&node, CalcExecutor.roundToZero)
        case .Mod: foldBinaryOperation(&node, CalcExecutor.mod)
        case .Rem: foldBinaryOperation(&node, CalcExecutor.rem)
        case .Abs: foldAbs(&node)
        case .Sign: foldSign(&node)
        case .Pow: calcFoldPow(&node)
        case .Sqrt: calcFoldNumberToNumber(&node, CalcExecutor.sqrt)
        case .Deg2Rad: calcFoldDeg2Rad(&node)
        case .Sin: calcFoldNumberToNumber(&node, CalcExecutor.sin)
        case .Cos: calcFoldNumberToNumber(&node, CalcExecutor.cos)
        case .Tan: calcFoldNumberToNumber(&node, CalcExecutor.tan)
        case .Asin: calcFoldArcTrig(&node, CalcExecutor.asin)
        case .Acos: calcFoldArcTrig(&node, CalcExecutor.acos)
        case .Atan: calcFoldArcTrig(&node, CalcExecutor.atan)
        case .Atan2: foldAtan2(&node)
        case .Hypot: foldHypot(&node)
        case .Log: calcFoldLog(&node)
        case .Exp: calcFoldNumberToNumber(&node, CalcExecutor.exp)
        case .Progress: foldProgress(&node, CalcExecutor.progress)
        case .ProgressNoClamp: foldProgress(&node, CalcExecutor.progressNoClamp)
        default: return false
        }
        return true
    }
}

// MARK: Negate, Invert, Sum, Product, Min and Max

/// `simplify(Negate&)`.
///
/// FIXME: Like the C++, this negates every factor of an all-numeric `Product`, which multiplies it by
/// `(-1)^n` rather than `-1`. Fix both together.
private func calcFoldNegate(_ node: inout CalcNode) {
    guard node.children.count == 1 else {
        return
    }
    if node.children[0].isNumericLeaf {
        // Unary minus, so `-(+0)` is `-0`.
        let negated = -node.children[0].value
        node.promote(0)
        node.value = negated
        return
    }
    if node.children[0].alternative == .Negate, node.children[0].children.count == 1 {
        node.promote(0)
        node.promote(0)
        return
    }
    if node.children[0].alternative == .Sum || node.children[0].alternative == .Product {
        guard node.children[0].allChildrenAreNumericLeaves() else {
            return
        }
        var k = 0
        while k < node.children[0].children.count {
            node.children[0].children[k].value = -node.children[0].children[k].value
            k &+= 1
        }
        node.promote(0)
    }
}

/// `simplify(Invert&)`.
private func calcFoldInvert(_ node: inout CalcNode) {
    guard node.children.count == 1 else {
        return
    }
    if node.children[0].alternative == .Number {
        let inverted = CalcExecutor.invert(node.children[0].value)
        node.promote(0)
        node.value = inverted
        return
    }
    if node.children[0].alternative == .Invert, node.children[0].children.count == 1 {
        node.promote(0)
        node.promote(0)
    }
}

/// css-values-4 step 8.1 for `Sum` and step 9.1 for `Product`: each `kind` child is replaced in place
/// by its children.
///
/// One level suffices because the nested node was simplified first.
private func calcSpliceNestedChildren(_ node: inout CalcNode, _ kind: CalcAlternative) {
    var k = 0
    while k < node.children.count {
        guard node.children[k].alternative == kind else {
            k &+= 1
            continue
        }
        var nested = node.children.remove(at: k)
        let n = nested.children.count
        nested.children.edit { span in node.children.insert(moving: &span, at: k) }
        k &+= n
    }
}

/// The test `if (!offset || (offset - 1) == i)` in `simplifyForMinMax`, for the child at `k`.
@inline(always)
private func calcMinMaxSurvives(
    _ leaf: NumericLeaf?,
    _ k: Int,
    _ offsets: borrowing CalcSimplification.MergeTable
) -> Bool {
    guard let leaf else {
        return true
    }
    let offset = Int(offsets[mergeKey(leaf)])
    return offset == 0 || offset - 1 == k
}

extension CalcFold {
    @inline(always)
    fileprivate func promote(_ node: inout CalcNode, _ k: Int) {
        if keepsBuffers {
            node.promoteKeepingBuffer(k)
        } else {
            node.promote(k)
        }
    }

    @inline(always)
    @discardableResult
    fileprivate func setLeaf(_ node: inout CalcNode, _ leaf: NumericLeaf) -> Bool {
        node.setLeaf(leaf, keepingBuffer: keepsBuffers)
    }

    /// `simplify(Sum&)`, css-values-4 steps 8.1 to 8.4, in the C++'s order.
    ///
    /// The merge table stands in for the C++'s `std::array<FirstInstance, ...>`, keyed by `mergeKey`.
    ///
    /// Two running totals replace `FirstInstance::merges`. `canRemove` is reassigned on every merge,
    /// not accumulated, so `removableBuckets` must move in both directions.
    fileprivate func foldSum(_ node: inout CalcNode) {
        guard node.children.count > 0 else {
            return
        }

        calcSpliceNestedChildren(&node, .Sum)

        if node.children.count == 1 {
            promote(&node, 0)
            return
        }

        var offsets = CalcSimplification.MergeTable(repeating: 0)
        var canRemove = CalcSimplification.MergeFlags(repeating: false)
        var merges = 0
        var removableBuckets = 0

        var k = 0
        while k < node.children.count {
            let c = k
            k &+= 1
            guard let leaf = node.children[c].numericLeaf else {
                continue
            }
            let key = mergeKey(leaf)

            if offsets[key] != 0 {
                let first = Int(offsets[key]) - 1
                let merged = CalcExecutor.sum(node.children[first].value, node.children[c].value)
                node.children[first].value = merged
                merges &+= 1
                let removable = merged == 0 && options.lengthRemovalAllowed(leaf)
                if removable != canRemove[key] {
                    removableBuckets &+= removable ? 1 : -1
                    canRemove[key] = removable
                }
                continue
            }

            offsets[key] = UInt32(truncatingIfNeeded: c &+ 1)
            let removable = node.children[c].value == 0 && options.lengthRemovalAllowed(leaf)
            if removable != canRemove[key] {
                removableBuckets &+= removable ? 1 : -1
                canRemove[key] = removable
            }
        }

        let size = node.children.count
        let removeTotal = merges &+ removableBuckets
        if removeTotal == 0 {
            return
        }

        // Before zero-removal and without consulting `canRemove`, as the C++ does.
        if size &- merges == 1 {
            promote(&node, 0)
            return
        }

        let combined = size &- removeTotal
        if combined == 0 {
            setLeaf(&node, NumericLeaf.canonicalLength(0))
            return
        }

        if combined == 1 {
            var s = 0
            while s < node.children.count {
                if calcSumSurvives(node.children[s].numericLeaf, s, offsets, canRemove) {
                    promote(&node, s)
                    return
                }
                s &+= 1
            }
        }

        // Keep non-numerics and non-removable first instances. `read` is the original position the
        // offsets are keyed on; `write` is the next survivor's slot.
        var write = 0
        var read = 0
        while write < node.children.count {
            if calcSumSurvives(node.children[write].numericLeaf, read, offsets, canRemove) {
                write &+= 1
            } else {
                node.dropChild(write)
            }
            read &+= 1
        }
    }

    /// `simplifyForMinMax`, css-values-4 steps 5.1 to 5.3.
    fileprivate func foldMinMax(_ node: inout CalcNode, _ isMax: Bool) {
        guard node.children.count > 0 else {
            return
        }
        if node.children.count == 1 {
            promote(&node, 0)
            return
        }

        var offsets = CalcSimplification.MergeTable(repeating: 0)
        let canMergePercentages = !options.percentageResolveToDimension
        var merges = 0

        var c = 0
        while c < node.children.count {
            defer { c &+= 1 }
            guard let leaf = node.children[c].numericLeaf else {
                continue
            }
            if leaf.kind == .percentage, !canMergePercentages {
                continue
            }
            let key = mergeKey(leaf)
            if offsets[key] != 0 {
                let first = Int(offsets[key]) - 1
                node.children[first].value =
                    isMax
                    ? CalcExecutor.max(node.children[first].value, node.children[c].value)
                    : CalcExecutor.min(node.children[first].value, node.children[c].value)
                merges &+= 1
                continue
            }
            offsets[key] = UInt32(truncatingIfNeeded: c &+ 1)
        }

        if merges == 0 {
            return
        }
        if node.children.count &- merges == 1 {
            promote(&node, 0)
            return
        }

        var write = 0
        var read = 0
        while write < node.children.count {
            if calcMinMaxSurvives(node.children[write].numericLeaf, read, offsets) {
                write &+= 1
            } else {
                node.dropChild(write)
            }
            read &+= 1
        }
    }

    /// `simplify(Product&)`, css-values-4 steps 9.1 to 9.5.
    ///
    /// As in the C++, 9.4's `success` starts false, so an empty factor list does not fold to `1`.
    fileprivate func foldProduct(_ node: inout CalcNode) {
        guard node.children.count > 0 else {
            return
        }

        calcSpliceNestedChildren(&node, .Product)

        // 9.2: fold every `<number>` into one factor, which goes after the other survivors.
        var numericProduct: Double?
        var mergedNumber: CalcNode? = nil
        var haveMergedNumber = false
        var k = 0
        while k < node.children.count {
            guard node.children[k].alternative == .Number else {
                k &+= 1
                continue
            }
            numericProduct = options.multipliedNumericProduct(node.children[k].value, numericProduct)
            if !haveMergedNumber {
                mergedNumber = node.children.remove(at: k)
                haveMergedNumber = true
            } else {
                node.dropChild(k)
            }
        }

        if let numericProduct {
            let survivors = node.children.count
            if survivors == 0 {
                setLeaf(&node, NumericLeaf.number(numericProduct))
                return
            }
            if survivors == 1, calcDistributeNumber(&node, numericProduct, keepsBuffers) {
                return
            }
            if var merged = mergedNumber.take() {
                merged.value = numericProduct
                node.children.append(merged)
            }
        }

        // 9.4.
        var productValue = 1.0
        var productType = CalcType()
        var success = false
        var f = 0
        while f < node.children.count {
            success = calcMultiplyFactor(node.children[f], &productValue, &productType, options)
            if !success {
                break
            }
            f &+= 1
        }

        if success, let resolvedCategory = productType.calculationCategory().value,
            let folded = options.numericLeafForCategory(resolvedCategory, productValue)
        {
            setLeaf(&node, folded)
        }
    }
}

/// The test `if ((firstInstance.offset - 1) == i && !firstInstance.canRemove)` in
/// `simplify(Sum&)`.
@inline(always)
private func calcSumSurvives(
    _ leaf: NumericLeaf?,
    _ k: Int,
    _ offsets: borrowing CalcSimplification.MergeTable,
    _ canRemove: borrowing CalcSimplification.MergeFlags
) -> Bool {
    guard let leaf else {
        return true
    }
    let key = mergeKey(leaf)
    guard Int(offsets[key]) - 1 == k else {
        return false
    }
    return !canRemove[key]
}

/// Step 9.3 for the single surviving factor.
///
/// False leaves the node untouched.
private func calcDistributeNumber(_ node: inout CalcNode, _ product: Double, _ keepingBuffer: Bool = false) -> Bool {
    if node.children[0].isNumericLeaf {
        let scaled = node.children[0].value * product
        if keepingBuffer {
            node.promoteKeepingBuffer(0)
        } else {
            node.promote(0)
        }
        node.value = scaled
        return true
    }
    if node.children[0].alternative == .Sum {
        guard node.children[0].allChildrenAreNumericLeaves() else {
            return false
        }
        var k = 0
        while k < node.children[0].children.count {
            node.children[0].children[k].value *= product
            k &+= 1
        }
        node.promote(0)
        return true
    }
    if node.children[0].alternative == .Invert {
        // FIXME: Like the C++, this multiplies the inverted operand and drops the `Invert`.
        guard node.children[0].children.count == 1, node.children[0].children[0].isNumericLeaf else {
            return false
        }
        let scaled = node.children[0].children[0].value * product
        node.promote(0)
        node.promote(0)
        node.value = scaled
        return true
    }
    return false
}

/// One factor of step 9.4.
private func calcMultiplyFactor(
    _ factor: borrowing CalcNode,
    _ productValue: inout Double,
    _ productType: inout CalcType,
    _ options: CalcSimplification
) -> Bool {
    if let leaf = factor.numericLeaf {
        switch leaf.kind {
        case .number:
            productValue *= leaf.value
            return true
        case .percentage, .canonicalDimension:
            guard let factorType = options.numericLeafType(leaf),
                let multiplied = calcTypeMultiply(productType, factorType)
            else {
                return false
            }
            productType = multiplied
            productValue *= leaf.value
            return true
        case .nonCanonicalDimension:
            return false
        }
    }
    guard factor.alternative == .Invert, factor.children.count == 1,
        let inner = factor.children[0].numericLeaf
    else {
        return false
    }
    switch inner.kind {
    case .number:
        productValue /= inner.value
        return true
    case .percentage, .canonicalDimension:
        guard let factorType = options.numericLeafType(inner) else {
            return false
        }
        let invertedType = calcTypeInvert(factorType)
        guard let multiplied = calcTypeMultiply(productType, invertedType) else {
            return false
        }
        productType = multiplied
        productValue /= inner.value
        return true
    case .nonCanonicalDimension:
        return false
    }
}

// MARK: Clamp, round(), mod(), rem(), hypot() and the unary folds

extension CalcFold {
    /// `simplify(Clamp&)`.
    ///
    /// Which bounds are `none` is not derivable from the child count, because `Child::operator[]`
    /// skips a `none` bound; `calcBuildSubtree` records it in `clampNoneMinimum`/`clampNoneMaximum`.
    /// The collapse branches keep the C++'s argument order, `Min(val, max)` and `Max(min, val)`,
    /// because the executors propagate whichever operand is NaN first. The test is
    /// `magnitudeComparable`, not `fullyResolved`, as in the C++, and the rewritten `min()`/`max()`
    /// is not simplified again, because `copyAndSimplify` calls `simplify` once per node.
    fileprivate mutating func foldClamp(_ node: inout CalcNode) {
        let childCount = node.children.count
        let minimumIsNone = node.flags & CalcNodeFlags.clampNoneMinimum != 0
        let maximumIsNone = node.flags & CalcNodeFlags.clampNoneMaximum != 0
        let nones = (minimumIsNone ? 1 : 0) + (maximumIsNone ? 1 : 0)
        guard childCount + nones == 3 else {
            declined = true
            return
        }

        if childCount == 1 {
            node.promote(0)
            return
        }

        if childCount == 3 {
            guard let value = node.children[1].numericLeaf else {
                return
            }
            guard let minimum = node.children[0].numericLeaf,
                let maximum = node.children[2].numericLeaf,
                options.switchTogether(value, minimum), options.switchTogether(value, maximum)
            else {
                return
            }
            guard options.unitsMatch(minimum, value), options.unitsMatch(value, maximum) else {
                return
            }
            guard options.magnitudeComparable(value) else {
                return
            }
            node.setLeaf(value.withValue(CalcExecutor.clamp(minimum.value, value.value, maximum.value)))
            return
        }

        if minimumIsNone {
            guard let value = node.children[0].numericLeaf else {
                return
            }
            guard let maximum = node.children[1].numericLeaf, options.switchTogether(value, maximum),
                options.unitsMatch(value, maximum), options.magnitudeComparable(value)
            else {
                convertToMinMax(&node, isMax: false)
                return
            }
            node.setLeaf(value.withValue(CalcExecutor.min(value.value, maximum.value)))
            return
        }

        guard let value = node.children[1].numericLeaf else {
            return
        }
        guard let minimum = node.children[0].numericLeaf, options.switchTogether(minimum, value),
            options.unitsMatch(minimum, value), options.magnitudeComparable(value)
        else {
            convertToMinMax(&node, isMax: true)
            return
        }
        node.setLeaf(value.withValue(CalcExecutor.max(minimum.value, value.value)))
    }

    /// `convertToMin` / `convertToMax`: a `clamp()` with one `none` bound that did not fold becomes
    /// the two-argument `min()`/`max()`.
    ///
    /// The children are already in the C++'s order, `val, max` or `min, val`. The type is
    /// `Type::consistentType` of the two, which is what `toType(Min)` and `toType(Max)` reduce to.
    /// If it fails the node stays a `Clamp`, as in the C++.
    ///
    /// FIXME: `convertToMin` in the C++ moves `root.val` and `root.max` into its new `Vector`
    /// before testing `toType`, so on failure `copyAndSimplify` rebuilds the `Clamp` from moved-from
    /// children, an `IndirectNode` holding a null `UniqueRef`. `root.max` can be an arbitrary
    /// subtree. Nothing is moved here.
    fileprivate func convertToMinMax(_ node: inout CalcNode, isMax: Bool) {
        guard let firstType = node.children[0].emittedType(options),
            let secondType = node.children[1].emittedType(options),
            let merged = calcTypeConsistentType(firstType, secondType)
        else {
            return
        }
        node.alternative = isMax ? .Max : .Min
        node.type = merged
    }

    /// `simplifyForRound<Op>`.
    fileprivate mutating func foldRound(_ node: inout CalcNode, _ operation: (Double, Double) -> Double) {
        guard node.children.count > 0 else {
            declined = true
            return
        }
        if node.children.count == 2 {
            foldForOperation(&node, operation)
            return
        }
        guard node.children[0].alternative == .Number else {
            return
        }
        node.setLeaf(NumericLeaf.number(operation(node.children[0].value, 1.0)))
    }

    /// `simplifyForOperation<Op>` over children 0 and 1.
    fileprivate func foldForOperation(_ node: inout CalcNode, _ operation: (Double, Double) -> Double) {
        guard let a = node.children[0].numericLeaf, let b = node.children[1].numericLeaf else {
            return
        }
        guard options.switchTogether(a, b), options.unitsMatch(a, b), options.fullyResolved(a) else {
            return
        }
        node.setLeaf(a.withValue(operation(a.value, b.value)))
    }

    /// `simplify(Mod&)` and `simplify(Rem&)`.
    fileprivate mutating func foldBinaryOperation(_ node: inout CalcNode, _ operation: (Double, Double) -> Double) {
        guard node.children.count >= 2 else {
            declined = true
            return
        }
        foldForOperation(&node, operation)
    }

    fileprivate func foldAbs(_ node: inout CalcNode) {
        guard node.children.count > 0, let a = node.children[0].numericLeaf,
            options.magnitudeComparable(a)
        else {
            return
        }
        node.setLeaf(a.withValue(CalcExecutor.abs(a.value)))
    }

    fileprivate func foldSign(_ node: inout CalcNode) {
        guard node.children.count > 0, let a = node.children[0].numericLeaf,
            options.magnitudeComparable(a)
        else {
            return
        }
        node.setLeaf(NumericLeaf.number(CalcExecutor.sign(a.value)))
    }

    fileprivate func foldAtan2(_ node: inout CalcNode) {
        guard node.children.count >= 2,
            let a = node.children[0].numericLeaf, let b = node.children[1].numericLeaf
        else {
            return
        }
        guard options.switchTogether(a, b), options.unitsMatch(a, b), options.fullyResolved(a) else {
            return
        }
        node.setLeaf(NumericLeaf.canonicalAngle(CalcExecutor.atan2(a.value, b.value)))
    }

    fileprivate func foldProgress(_ node: inout CalcNode, _ operation: (Double, Double, Double) -> Double) {
        guard node.children.count >= 3,
            let value = node.children[0].numericLeaf,
            let start = node.children[1].numericLeaf,
            let end = node.children[2].numericLeaf
        else {
            return
        }
        guard options.switchTogether(value, start), options.switchTogether(start, end) else {
            return
        }
        guard options.unitsMatch(value, start), options.unitsMatch(start, end),
            options.fullyResolved(value)
        else {
            return
        }
        node.setLeaf(NumericLeaf.number(operation(value.value, start.value, end.value)))
    }

    /// `simplify(Hypot&)`.
    ///
    /// The squares are summed in child order, as `OperatorExecutor<Hypot>` does, because
    /// floating-point `+` is not associative. An empty list is left unchanged: the executor returns
    /// NaN for it without calling the functor, so the C++ does not fold it.
    fileprivate func foldHypot(_ node: inout CalcNode) {
        let childCount = node.children.count
        guard childCount > 0 else {
            return
        }
        var tag = HypotTag.unset
        var sumOfSquares = 0.0
        var firstElement = 0.0
        var k = 0
        while k < childCount {
            let value: Double
            if let leaf = node.children[k].numericLeaf {
                value = options.hypotElement(leaf, &tag)
            } else {
                tag = .failed
                value = Double.nan
            }
            if k == 0 {
                firstElement = value
            }
            sumOfSquares += value * value
            k &+= 1
        }

        let value = childCount == 1 ? firstElement.magnitude : sumOfSquares.squareRoot()

        switch tag {
        case .number:
            node.setLeaf(NumericLeaf.number(value))
        case .percentage:
            guard let optionsCategory = WebCore.CSS.Category(rawValue: options.category) else {
                return
            }
            node.setLeaf(NumericLeaf.percentage(value, CalcType.determinePercentHint(optionsCategory)))
        case .dimension(let canonicalUnit):
            node.setLeaf(NumericLeaf(kind: .canonicalDimension, value: value, unitType: canonicalUnit, percentHint: 0))
        case .unset, .failed:
            return
        }
    }
}

private func calcFoldPow(_ node: inout CalcNode) {
    guard node.children.count >= 2,
        node.children[0].alternative == .Number, node.children[1].alternative == .Number
    else {
        return
    }
    node.setLeaf(NumericLeaf.number(CalcExecutor.pow(node.children[0].value, node.children[1].value)))
}

private func calcFoldDeg2Rad(_ node: inout CalcNode) {
    guard node.children.count > 0, let angle = node.children[0].numericLeaf,
        angle.kind == .canonicalDimension,
        angle.unitType == UInt16(WebCore.CSSUnitType.Deg.rawValue)
    else {
        return
    }
    node.setLeaf(NumericLeaf.number(CalcExecutor.degreesToRadians(angle.value)))
}

/// `simplifyForTrig<Op>`, and `simplify(Sqrt&)`, `simplify(Exp&)` and one-argument `simplify(Log&)`.
private func calcFoldNumberToNumber(_ node: inout CalcNode, _ operation: (Double) -> Double) {
    guard node.children.count > 0, node.children[0].alternative == .Number else {
        return
    }
    node.setLeaf(NumericLeaf.number(operation(node.children[0].value)))
}

/// `simplifyForArcTrig<Op>`: a `Number` in, a canonical angle out.
private func calcFoldArcTrig(_ node: inout CalcNode, _ operation: (Double) -> Double) {
    guard node.children.count > 0, node.children[0].alternative == .Number else {
        return
    }
    node.setLeaf(NumericLeaf.canonicalAngle(operation(node.children[0].value)))
}

private func calcFoldLog(_ node: inout CalcNode) {
    guard node.children.count == 2 else {
        calcFoldNumberToNumber(&node, CalcExecutor.log)
        return
    }
    guard node.children[0].alternative == .Number, node.children[1].alternative == .Number else {
        return
    }
    node.setLeaf(NumericLeaf.number(CalcExecutor.log(node.children[0].value, node.children[1].value)))
}

// MARK: The folds that read the builder

/// How a fold asks `resolveStyleCoupledValue` about the node it stands on.
///
/// Nil refuses the tree.
typealias CalcStyleCoupledResolver = (WebCore.CSSCalc.CSSCalcSwiftBuilder, borrowing CalcNode) -> WebCore.CSSCalc.CSSCalcSwiftNumericResult?

/// Builds the node as a `Child` on the operand stack and asks about that.
///
/// Only `anchor()`, `anchor-size()`, `random()` and the tree-counting functions ask.
private func calcResolveStoredStyleCoupled(
    _ builder: WebCore.CSSCalc.CSSCalcSwiftBuilder,
    _ node: borrowing CalcNode
) -> WebCore.CSSCalc.CSSCalcSwiftNumericResult? {
    var builder = builder
    guard calcEmitParsed(node, false, &builder) else {
        return nil
    }
    return builder.resolveStyleCoupledValueOfTop()
}

extension CalcFold {
    /// A leaf stays a leaf, so this is a `setLeaf`.
    ///
    /// Clearing `type` matches the C++, whose `ChildConstruction<Leaf>::make` discards a
    /// leaf's `Type`.
    fileprivate func foldNonCanonicalDimension(_ node: inout CalcNode) {
        let unit = UInt16(node.unitType)
        let leaf: NumericLeaf
        switch options.canonicalizeStep(node.value, unit) {
        case .leaf(let step):
            leaf = step
        case .relativeLength:
            guard let builder else {
                return
            }
            leaf = options.resolvedRelativeLength(node.value, unit, builder)
        }
        guard leaf.kind != .nonCanonicalDimension else {
            return
        }
        node.setLeaf(leaf)
    }

    /// The C++ runs the whole `copyAndSimplify` on the resolved symbol, so a non-canonical unit is
    /// then canonicalized; `canonicalizedDimension` is that step.
    fileprivate mutating func foldSymbol(_ node: inout CalcNode) {
        guard let builder else {
            return
        }
        let resolved = builder.resolveSymbol(node.valueID, UInt16(node.unitType))
        guard resolved.resolved else {
            return
        }
        switch resolved.alternative {
        case .Number:
            node.setLeaf(NumericLeaf(kind: .number, value: resolved.value, unitType: resolved.unitType, percentHint: 0))
        case .Percentage:
            node.setLeaf(NumericLeaf(kind: .percentage, value: resolved.value, unitType: resolved.unitType, percentHint: 0))
        case .CanonicalDimension:
            node.setLeaf(NumericLeaf(kind: .canonicalDimension, value: resolved.value, unitType: resolved.unitType, percentHint: 0))
        case .NonCanonicalDimension:
            node.setLeaf(options.canonicalizedDimension(resolved.value, resolved.unitType, builder))
        default:
            declined = true
        }
    }

    /// `resolved == false` is not a refusal: the C++ returns `{ }` and the leaf stays in the tree.
    fileprivate mutating func foldSiblingFunction(_ node: inout CalcNode, _ resolve: CalcStyleCoupledResolver) {
        guard let builder else {
            return
        }
        guard let resolved = resolve(builder, node) else {
            declined = true
            return
        }
        guard resolved.resolved else {
            return
        }
        node.setLeaf(NumericLeaf.number(resolved.value))
    }

    fileprivate mutating func foldAnchorFunction(_ node: inout CalcNode, _ resolve: CalcStyleCoupledResolver) {
        guard let builder else {
            return
        }
        let sideSlots = node.flags & CalcNodeFlags.anchorSideIsSubtree != 0 ? 1 : 0
        let childCount = node.children.count
        guard childCount == sideSlots || childCount == sideSlots &+ 1 else {
            declined = true
            return
        }
        guard let resolved = resolve(builder, node) else {
            declined = true
            return
        }
        if resolved.resolved {
            guard resolved.alternative == .CanonicalDimension else {
                declined = true
                return
            }
            node.setLeaf(NumericLeaf(kind: .canonicalDimension, value: resolved.value, unitType: resolved.unitType, percentHint: 0))
            return
        }
        if resolved.substituteFallback, childCount == sideSlots &+ 1 {
            // A subtree fallback reaches the parent as a subtree, so
            // `calc(anchor(top, 1px) + 1em)` becomes `17px`, not `calc(1px + 16px)`.
            node.promote(sideSlots)
        }
    }

    /// The `<random-key>` is not a child; only `min`, `max` and the optional `step` are, so
    /// `childCount` is 2 or 3 whether or not a key is present.
    ///
    /// All present operands must be the same numeric alternative and unit, checked against `max` and
    /// `step` separately and both anchored on `min`, as the C++ does; only `min` is checked for
    /// `fullyResolved`, so a non-canonical dimension never folds here. The result is shaped like
    /// `min`, so a `random()` over percentages keeps `min`'s percent hint.
    fileprivate mutating func foldRandom(_ node: inout CalcNode, _ resolve: CalcStyleCoupledResolver) {
        guard let builder else {
            return
        }
        let childCount = node.children.count
        guard childCount >= 2, let minimum = node.children[0].numericLeaf,
            let maximum = node.children[1].numericLeaf
        else {
            return
        }
        guard options.switchTogether(minimum, maximum), options.unitsMatch(minimum, maximum),
            options.fullyResolved(minimum)
        else {
            return
        }
        var step: Double? = nil
        if childCount > 2 {
            guard let stepLeaf = node.children[2].numericLeaf else {
                return
            }
            guard options.switchTogether(minimum, stepLeaf), options.unitsMatch(minimum, stepLeaf) else {
                return
            }
            step = stepLeaf.value
        }
        guard let baseValue = resolve(builder, node) else {
            declined = true
            return
        }
        guard baseValue.resolved else {
            return
        }
        node.setLeaf(minimum.withValue(CalcExecutor.random(baseValue.value, minimum.value, maximum.value, step)))
    }

    /// `zeroValueMatchingChild(children[0])` (`+Simplification.cpp:1454`-`:1482`).
    fileprivate mutating func calcMixFoldToZero(_ node: inout CalcNode) {
        guard node.children.count > 0,
            let childType = node.children[0].emittedType(options),
            let category = childType.calculationCategory().value,
            let zero = options.numericLeafForCategory(category, 0)
        else {
            declined = true
            return
        }
        node.setLeaf(zero)
    }
}

// MARK: The owned tree's simplifier and emit

/// Where a tree differs from the `CSSCalc::Child` it stands for, which the fold and emit account for:
///
/// - `origin` indexes a payload on an `Anchor`, `AnchorSize` or `Random`, and on a `calc-mix()`
///   weight that is a math function (`CalcNodeFlags.calcMixWeightIsCalc`); elsewhere it is
///   `calcNoPayload`.
/// - A `calc-mix()`'s children are interleaved: value, weight carrier, value, weight carrier, ...
extension CalcFold {
    /// `copyAndSimplify`. With `skipAnchorSides`, an `anchor()`'s `<anchor-side>`
    /// is copied without being simplified, as `copyAndSimplifyChildren` does.
    fileprivate mutating func simplifyParsed(_ node: inout CalcNode, _ skipAnchorSides: Bool) -> Bool {
        var k = 0
        while k < node.children.count {
            if !skipAnchorSides || node.children[k].flags & CalcNodeFlags.insideAnchorSide == 0 {
                guard simplifyParsed(&node.children[k], skipAnchorSides) else {
                    return false
                }
            }
            k &+= 1
        }
        return simplifyParsedNode(&node)
    }

    /// One node of `simplifyParsed`.
    ///
    /// False refuses the tree.
    @inline(always)
    fileprivate mutating func simplifyParsedNode(_ node: inout CalcNode) -> Bool {
        if node.flags & CalcNodeFlags.foldedAtConstruction != 0, !refoldsStoredTree {
            return true
        }
        switch node.alternative {
        case .Negate: calcFoldNegate(&node)
        case .Invert: calcFoldInvert(&node)
        case .Sum: foldSum(&node)
        case .Product: foldProduct(&node)
        case .Min: foldMinMax(&node, false)
        case .Max: foldMinMax(&node, true)
        case .NonCanonicalDimension: foldNonCanonicalDimension(&node)
        case .Number, .Percentage, .CanonicalDimension: break
        case .SiblingCount, .SiblingIndex:
            if refoldsStoredTree {
                foldSiblingFunction(&node, calcResolveStoredStyleCoupled)
            }
        case .Symbol: foldSymbol(&node)
        default:
            guard simplifyParsedFunction(&node) else {
                return false
            }
        }
        return true
    }

    @inline(never)
    fileprivate mutating func simplifyParsedFunction(_ node: inout CalcNode) -> Bool {
        switch node.alternative {
        case .CalcMix:
            foldParsedCalcMix(&node)
            return true
        case .Anchor, .AnchorSize:
            if refoldsStoredTree {
                foldAnchorFunction(&node, calcResolveStoredStyleCoupled)
            }
            return true
        case .Random:
            if refoldsStoredTree {
                foldRandom(&node, calcResolveStoredStyleCoupled)
            }
            return true
        default:
            return foldFunction(&node)
        }
    }

    /// `simplify(CalcMix&)` for a parsed tree, whose weights are the interleaved carriers.
    @inline(never)
    fileprivate mutating func foldParsedCalcMix(_ node: inout CalcNode) {
        let pairs = node.children.count
        let itemCount = UInt32(truncatingIfNeeded: pairs / 2)
        guard itemCount > 0, pairs % 2 == 0 else {
            declined = true
            return
        }

        var survey = CalcMixWeightSurvey()
        var w = 1
        while w < pairs {
            if node.children[w].flags & CalcNodeFlags.calcMixWeightPresent == 0 {
                survey.numberOfOmittedWeights &+= 1
            } else if node.children[w].flags & CalcNodeFlags.calcMixWeightIsCalc != 0 {
                survey.canNormalize = false
            } else {
                if node.children[w].value == 0 {
                    survey.numberOfKnownZeroWeights &+= 1
                }
                survey.total += node.children[w].value
            }
            w &+= 2
        }

        if !survey.canNormalize {
            if survey.numberOfKnownZeroWeights != 0, itemCount == survey.numberOfKnownZeroWeights {
                calcMixFoldToZero(&node)
                return
            }
        } else if survey.total < 100 {
            if survey.numberOfKnownZeroWeights > 0, survey.numberOfOmittedWeights == 0,
                itemCount == survey.numberOfKnownZeroWeights
            {
                calcMixFoldToZero(&node)
                return
            }
        }

        // Keep the surviving pairs, writing the planned weight into each survivor's carrier.
        var v = 0
        while v &+ 1 < node.children.count {
            let present = node.children[v &+ 1].flags & CalcNodeFlags.calcMixWeightPresent != 0
            let isCalc = node.children[v &+ 1].flags & CalcNodeFlags.calcMixWeightIsCalc != 0
            let plan = calcMixItemPlan(
                CalcMixWeight(
                    value: node.children[v &+ 1].value,
                    present: present,
                    isRaw: present && !isCalc
                ),
                survey
            )
            if plan.survives {
                if plan.replaceWeight {
                    node.children[v &+ 1].value = plan.weight
                    node.children[v &+ 1].flags |= CalcNodeFlags.calcMixWeightPresent
                    node.children[v &+ 1].flags &= ~CalcNodeFlags.calcMixWeightIsCalc
                }
                v &+= 2
            } else {
                node.dropChild(v &+ 1)
                node.dropChild(v)
            }
        }

        guard survey.canNormalize else {
            return
        }

        // Phase 4, the weighted sum, using the weights the carriers now hold.
        var accumulated: NumericLeaf? = nil
        v = 0
        while v &+ 1 < node.children.count {
            guard let leaf = node.children[v].numericLeaf else {
                return
            }
            let scaled = node.children[v &+ 1].value / 100.0
            v &+= 2
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
            return
        }
        node.setLeaf(result)
    }
}

/// `getType(const Child&)` for a node `calcEmitParsed` has established is a leaf.
@inline(always)
private func calcParsedLeafType(_ node: borrowing CalcNode) -> CalcType? {
    guard let leaf = node.numericLeaf else {
        guard node.alternative == .Symbol else {
            return CalcType()
        }
        guard let unit = WebCore.CSSUnitType(rawValue: node.unitType) else {
            return nil
        }
        return CalcType.determineType(unit)
    }
    return calcLeafType(leaf)
}

/// Build `node` on the builder's operand stack as a `Child`.
private func calcEmitParsed(
    _ node: borrowing CalcNode,
    _ isRoot: Bool,
    _ builder: inout WebCore.CSSCalc.CSSCalcSwiftBuilder
) -> Bool {
    let alternativeBit = CalcCoverage.bit(node.alternative)

    if alternativeBit & CalcParsedEmitCoverage.leafMask != 0 {
        guard let leaf = node.numericLeaf else {
            guard let nonNumeric = node.nonNumericLeaf else {
                return false
            }
            return builder.pushLeaf(nonNumeric, isRoot)
        }
        return builder.pushLeaf(leaf.boundaryLeaf, isRoot)
    }

    guard alternativeBit & CalcParsedEmitCoverage.operationMask != 0 else {
        switch node.alternative {
        case .CalcMix: return calcEmitParsedCalcMix(node, isRoot, &builder)
        case .Anchor, .AnchorSize: return calcEmitParsedAnchor(node, isRoot, &builder)
        case .Random: return calcEmitParsedRandom(node, isRoot, &builder)
        default: return false
        }
    }

    var k = 0
    while k < node.children.count {
        guard calcEmitParsed(node.children[k], false, &builder) else { return false }
        k &+= 1
    }
    return builder.buildOperation(
        node.alternative,
        UInt32(truncatingIfNeeded: k),
        node.type,
        isRoot,
        UInt8(truncatingIfNeeded: node.flags & CalcNodeFlags.clampNoneMask)
    )
}

@inline(never)
private func calcEmitParsedCalcMix(
    _ node: borrowing CalcNode,
    _ isRoot: Bool,
    _ builder: inout WebCore.CSSCalc.CSSCalcSwiftBuilder
) -> Bool {
    let count = node.children.count
    guard count != 0, count % 2 == 0 else { return false }
    var v = 0
    while v < count {
        guard calcEmitParsed(node.children[v], false, &builder) else { return false }
        let flags = node.children[v &+ 1].flags
        if flags & CalcNodeFlags.calcMixWeightIsCalc != 0 {
            guard builder.pushCalcMixItemWeight(0, true, node.children[v &+ 1].origin) else { return false }
        } else {
            _ = builder.pushCalcMixItemWeight(
                node.children[v &+ 1].value,
                flags & CalcNodeFlags.calcMixWeightPresent != 0,
                calcNoPayload
            )
        }
        v &+= 2
    }
    return builder.buildOperation(.CalcMix, UInt32(truncatingIfNeeded: count / 2), node.type, isRoot, 0)
}

/// A parsed `random()`. `origin` indexes its `Random::Sharing` in the payload table.
@inline(never)
private func calcEmitParsedRandom(
    _ node: borrowing CalcNode,
    _ isRoot: Bool,
    _ builder: inout WebCore.CSSCalc.CSSCalcSwiftBuilder
) -> Bool {
    var k = 0
    while k < node.children.count {
        guard calcEmitParsed(node.children[k], false, &builder) else { return false }
        k &+= 1
    }
    return builder.buildRandom(UInt32(truncatingIfNeeded: k), node.type, isRoot, node.origin)
}

/// A parsed `anchor()` or `anchor-size()`.
///
/// A slot written as a math function that simplified to a leaf gets its `calc()` wrapper back, as
/// `anchorSlotKeepingPrefix` does.
@inline(never)
private func calcEmitParsedAnchor(
    _ node: borrowing CalcNode,
    _ isRoot: Bool,
    _ builder: inout WebCore.CSSCalc.CSSCalcSwiftBuilder
) -> Bool {
    let sideSlots = node.alternative == .Anchor && node.valueID == 0 ? 1 : 0
    var k = 0
    while k < node.children.count {
        guard calcEmitParsed(node.children[k], false, &builder) else { return false }
        let prefixBit =
            k < sideSlots
            ? CalcNodeFlags.anchorSideWasFunction
            : CalcNodeFlags.anchorFallbackWasFunction
        if node.flags & prefixBit != 0,
            CalcCoverage.bit(node.children[k].alternative) & CalcParsedEmitCoverage.leafMask != 0
        {
            guard let leafType = calcParsedLeafType(node.children[k]),
                builder.buildOperation(.Sum, 1, leafType, false, 0)
            else { return false }
        }
        k &+= 1
    }
    return builder.buildAnchor(
        node.alternative,
        UInt32(truncatingIfNeeded: k),
        node.type,
        isRoot,
        node.valueID,
        node.origin
    )
}

// MARK: - The stored tree's entries

/// `copyAndSimplify` of a stored tree: a copy of it, folded with the options' conversion data.
/// `simplified` is false, and the root means nothing, if a fold gave up.
@_expose(Cxx)
public func cssCalcSimplifyStoredSwift(
    _ root: CSSCalcSwiftRoot,
    _ builder: inout WebCore.CSSCalc.CSSCalcSwiftBuilder,
    _ options: WebCore.CSSCalc.CSSCalcSwiftSimplificationOptions,
    _ simplified: inout Bool
) -> CSSCalcSwiftRoot {
    simplified = true
    let box = root
    // `simplify(Number&)`, `simplify(Percentage&)` and `simplify(CanonicalDimension&)` are no-ops, so
    // a tree that is one of those leaves is its own simplification and is shared rather than copied.
    switch box.root.alternative {
    case .Number, .Percentage, .CanonicalDimension:
        return copy root
    default:
        break
    }

    let simplification = CalcSimplification(
        percentageResolveToDimension: options.percentageResolveToDimension,
        allowZeroValueLengthRemovalFromSum: options.allowZeroValueLengthRemovalFromSum,
        category: options.category,
        hasConversionData: options.hasConversionData
    )
    var tree = box.root.clone()
    var fold = CalcFold(options: simplification, builder: builder, refoldsStoredTree: true)
    guard fold.simplifyParsed(&tree, true), !fold.declined else {
        simplified = false
        return .none
    }
    calcRestoreAnchorPrefixes(&tree)
    return CSSCalcSwiftRoot(tree)
}

/// Build the stored tree as a `CSSCalc::Child` in the builder's root slot, for the C++ that reads one:
/// Typed OM reification, and the computed-style dependency walk.
@_expose(Cxx)
public func cssCalcEmitStoredSwift(
    _ stored: CSSCalcSwiftRoot,
    _ builder: inout WebCore.CSSCalc.CSSCalcSwiftBuilder
) -> Bool {
    calcEmitParsed(stored.root, true, &builder)
}

/// Whether two stored trees stand for equal `CSSCalc::Child`s, as `Child::operator==` compares them.
///
/// Payloads are compared by value through `payloads`, not by index.
@_expose(Cxx)
public func cssCalcSwiftRootsEqual(
    _ a: CSSCalcSwiftRoot,
    _ b: CSSCalcSwiftRoot,
    _ payloads: borrowing WebCore.CSSCalc.CSSCalcSwiftPayloadComparer
) -> Bool {
    if a === b {
        return true
    }
    return calcNodesEqual(a.root, b.root, payloads)
}

/// The flags that are part of the tree `Child` stands for, rather than bookkeeping about how it was
/// built or folded.
private let calcStructuralFlags =
    CalcNodeFlags.clampNoneMask | CalcNodeFlags.anchorSideIsSubtree
    | CalcNodeFlags.calcMixWeightPresent | CalcNodeFlags.calcMixWeightIsCalc

private func calcNodesEqual(
    _ a: borrowing CalcNode,
    _ b: borrowing CalcNode,
    _ payloads: borrowing WebCore.CSSCalc.CSSCalcSwiftPayloadComparer
) -> Bool {
    guard a.alternative == b.alternative, a.valueID == b.valueID, a.children.count == b.children.count,
        a.flags & calcStructuralFlags == b.flags & calcStructuralFlags
    else {
        return false
    }
    switch a.alternative {
    case .Number:
        guard a.value == b.value else { return false }
    case .Percentage:
        guard a.value == b.value, a.percentHint == b.percentHint else { return false }
    case .CanonicalDimension, .NonCanonicalDimension:
        guard a.value == b.value, a.unitType == b.unitType else { return false }
    case .Symbol:
        guard a.unitType == b.unitType else { return false }
    case .SiblingCount, .SiblingIndex:
        break
    default:
        guard a.type == b.type else { return false }
    }
    // `origin` means something only where a payload is held; a fold that turns a node into a leaf
    // leaves its old `origin` behind.
    let holdsPayload: Bool
    switch a.alternative {
    case .Anchor, .AnchorSize, .Random: holdsPayload = true
    default: holdsPayload = a.flags & CalcNodeFlags.calcMixWeightIsCalc != 0
    }
    if holdsPayload, a.origin != calcNoPayload || b.origin != calcNoPayload {
        guard a.origin != calcNoPayload, b.origin != calcNoPayload, payloads.equal(a.origin, b.origin) else {
            return false
        }
    }
    var k = 0
    while k < a.children.count {
        guard calcNodesEqual(a.children[k], b.children[k], payloads) else {
            return false
        }
        k &+= 1
    }
    return true
}

/// `getType(tree.root)`.
@_expose(Cxx)
public func cssCalcSwiftRootType(_ stored: CSSCalcSwiftRoot) -> WebCore.CSSCalc.`Type` {
    let box = stored
    guard box.root.children.isEmpty, CalcCoverage.bit(box.root.alternative) & CalcParsedEmitCoverage.leafMask != 0 else {
        return box.root.type
    }
    return calcParsedLeafType(box.root) ?? CalcType()
}

/// The alternative of the root node of `stored`.
@_expose(Cxx)
public func cssCalcSwiftRootAlternative(_ stored: CSSCalcSwiftRoot) -> WebCore.CSSCalc.CSSCalcSwiftAlternative {
    stored.root.alternative
}

/// Where a tree built in C++ is stored: the C++ walks its `Child` and pushes each node here, children
/// before their parent, so Swift never reads a `Child`.
@_expose(Cxx)
public final class CSSCalcSwiftStoreBuilder {
    var stack = UniqueArray<CalcNode>()

    /// An empty builder.
    public init() {
    }

    /// A leaf.
    ///
    /// `valueID` is that of a `Symbol`; `unitType` is the unit of a dimension or a `Symbol`.
    public func pushLeaf(
        _ alternative: WebCore.CSSCalc.CSSCalcSwiftAlternative,
        _ value: Double,
        _ unitType: UInt8,
        _ percentHint: UInt8,
        _ valueID: UInt16
    ) {
        stack.append(
            CalcNode(
                value: value,
                type: CalcType(),
                origin: calcNoPayload,
                valueID: valueID,
                unitType: unitType,
                alternative: alternative,
                percentHint: percentHint,
                flags: 0,
                children: UniqueArray()
            )
        )
    }

    /// A `calc-mix()` item's weight, pushed after the item's value: a number, the math function
    /// `payload` names, or omitted when `present` is false.
    public func pushCalcMixWeight(_ value: Double, _ present: Bool, _ payload: UInt32) {
        var flags: UInt16 = 0
        if present {
            flags = CalcNodeFlags.calcMixWeightPresent
            if payload != calcNoPayload {
                flags |= CalcNodeFlags.calcMixWeightIsCalc
            }
        }
        stack.append(
            CalcNode(
                value: present && payload == calcNoPayload ? value : 0,
                type: CalcType(),
                origin: payload,
                valueID: 0,
                unitType: UInt8(WebCore.CSSUnitType.Percentage.rawValue),
                alternative: .Percentage,
                percentHint: 0,
                flags: flags,
                children: UniqueArray()
            )
        )
    }

    /// Pop `childCount` nodes and push an operation over them.
    ///
    /// `noneMask` is that of `clamp()`, as on `CSSCalcSwiftBuilder::buildOperation`. For `anchor()`,
    /// `valueID` is the `<anchor-side>` keyword, or zero when the side is the first child; for
    /// `anchor-size()` it is the dimension, or zero. `origin` names an `<anchor-element>` or
    /// `random()` sharing payload. False, with nothing pushed, when there are fewer than `childCount`
    /// nodes.
    public func pushOperation(
        _ alternative: WebCore.CSSCalc.CSSCalcSwiftAlternative,
        _ childCount: UInt32,
        _ type: WebCore.CSSCalc.`Type`,
        _ noneMask: UInt8,
        _ valueID: UInt16,
        _ origin: UInt32
    ) -> Bool {
        let count = Int(childCount)
        guard count <= stack.count else {
            return false
        }
        var children = UniqueArray<CalcNode>(capacity: count)
        var k = stack.count &- count
        while k < stack.count {
            children.append(stack.remove(at: k))
        }
        var flags = UInt16(noneMask) & CalcNodeFlags.clampNoneMask
        if alternative == .Anchor || alternative == .AnchorSize {
            let sideSlots = alternative == .Anchor && valueID == 0 ? 1 : 0
            if sideSlots == 1 {
                flags |= CalcNodeFlags.anchorSideIsSubtree
                calcMarkInsideAnchorSide(&children[0])
            }
            k = 0
            while k < children.count {
                // Not a leaf: if a fold makes it one, `calcRestoreAnchorPrefixes` keeps the `calc()`
                // the C++ keeps.
                if !children[k].children.isEmpty {
                    flags |= k < sideSlots ? CalcNodeFlags.anchorSideWasFunction : CalcNodeFlags.anchorFallbackWasFunction
                }
                k &+= 1
            }
        }
        stack.append(
            CalcNode(
                value: 0,
                type: type,
                origin: origin,
                valueID: valueID,
                unitType: 0,
                alternative: alternative,
                percentHint: 0,
                flags: flags,
                children: children
            )
        )
        return true
    }

    /// Whether exactly one node is left, which `finish` then answers as the tree.
    public var isFinished: Bool { stack.count == 1 }

    /// The tree, or `.none` when the pushes did not leave exactly one node.
    public func finish() -> CSSCalcSwiftRoot {
        guard stack.count == 1 else {
            return .none
        }
        var root = stack.removeLast()
        calcRestoreAnchorPrefixes(&root)
        return CSSCalcSwiftRoot(root)
    }
}

// MARK: - The calc grammar in Swift

/// `<calc-sum>` over `<calc-product>` over `<calc-value>`, for the leaf grammar.
///
/// Parses the math functions `calcParseFunctionAlternative` lists, under the context conditions the
/// C++ applies to each. The three payloads a `CalcNode` cannot hold (a `<random-key>`, an
/// `<anchor-element>` and a `calc-mix()` weight that is a second `CSSCalc::Value`) are resolved by
/// the C++ consumer when it accepts them, and the node names the result by its index in the payload
/// table.
///
/// Invalid input and a refusal are separate outcomes. `calc(1px +2px)` is invalid CSS and fails.
/// `state.declined` is set only for input the grammar does not handle.
///
/// `CalcTokens` is `~Escapable` and depends on a stack buffer that dies before `cssCalcParseSwift`
/// returns, which is what keeps `CSSCalcSwiftParseCursor`'s `SWIFT_SAFE` claim true.

/// The C++ parser's `maxExpressionDepth`.
///
/// The C++ `static_assert` checks only its own constant, so this literal must be edited with it.
private let calcMaxExpressionDepth: Int32 = 100

private struct CalcParseOptions {
    /// `Type::determinePercentHint(options.category)`.
    var percentageLeafHint: UInt8
    let absoluteLengthUnitsOnly: Bool
    /// Whether `ParserOptions::allowedSymbols` has any entry. `var`, because an `<anchor-side>`
    /// parses with `allowedSymbols = { }` and clears it for the duration.
    var hasAllowedSymbols: Bool
    let treeCountingAllowed: Bool
    let calcMixEnabled: Bool
    /// `CSSPropertyParserOptions::anchorPolicy` / `::anchorSizePolicy`, each already `== Allow`.
    var anchorAllowed: Bool
    var anchorSizeAllowed: Bool
    /// The four gate clauses of `consumeRandom`, already ANDed.
    ///
    /// Clear makes `random()` invalid input.
    let randomAllowed: Bool
    let unitlessZeroLengthAllowed: Bool
    let rootFunctionId: UInt16
    /// The entry is `parseAndSimplifyCalcSum` rather than `parseAndSimplify`.
    ///
    /// See `CSSCalcSwiftParseOptions::bareCalcSum` for the three things it selects.
    let bareCalcSum: Bool

    @inline(always)
    init(_ options: WebCore.CSSCalc.CSSCalcSwiftParseOptions) {
        self.percentageLeafHint = percentHintRawValue(CalcType.determinePercentHint(options.category))
        self.absoluteLengthUnitsOnly = options.absoluteLengthUnitsOnly
        self.hasAllowedSymbols = options.hasAllowedSymbols
        self.treeCountingAllowed = options.treeCountingAllowed
        self.calcMixEnabled = options.cssCalcMixEnabled
        self.anchorAllowed = options.anchorAllowed
        self.anchorSizeAllowed = options.anchorSizeAllowed
        self.randomAllowed = options.randomAllowed
        self.unitlessZeroLengthAllowed = options.unitlessZeroLengthAllowed
        self.rootFunctionId = options.rootFunctionId
        self.bareCalcSum = options.bareCalcSum
    }
}

/// Mutable state threaded through the descent.
///
/// Separate from the return value because both a success and a refusal can set
/// `requiresConversionData`.
private struct CalcParseState: ~Copyable {
    var options: CalcParseOptions

    init(_ options: CalcParseOptions) {
        self.options = options
    }

    var requiresConversionData = false
    var declineReason = WebCore.CSSCalc.CSSCalcSwiftParseDeclineReason.None
    /// Set when the grammar hit something it does not handle, as opposed to invalid input.
    var declined = false

    /// Whether a fold that needs `options.conversionData` would run on this parse, in which case
    /// the grammar refuses every node whose fold it cannot reproduce.
    var conversionDataFoldsRun = false

    /// Whether the grammar built an `anchor()` whose `<anchor-side>` is a subtree, the only shape
    /// that sets `CalcNodeFlags.insideAnchorSide`.
    var hasAnchorSide = false

    /// Whether `simplifyParsed` will run over the node being built, so its folds can be made at
    /// construction.
    ///
    /// Cleared inside an `<anchor-side>`, which the pass does not descend into.
    var foldAtConstruction = false

    /// What `simplifyParsed` will fold with.
    ///
    /// Meaningful only while `foldAtConstruction` is set.
    var simplification = CalcSimplification(
        percentageResolveToDimension: false,
        allowZeroValueLengthRemovalFromSum: false,
        category: 0,
        hasConversionData: false
    )

    /// One emptied children buffer from an operation that collapsed at construction, reused by the
    /// next operation.
    ///
    /// One slot suffices because the grammar builds post-order.
    var spare = UniqueArray<CalcNode>()

    @inline(always)
    mutating func takeOperandBuffer() -> UniqueArray<CalcNode> {
        takeBuffer(calcOperandListCapacity)
    }

    @inline(always)
    mutating func takeBuffer(_ capacity: Int) -> UniqueArray<CalcNode> {
        if spare.capacity >= capacity {
            var buffer = UniqueArray<CalcNode>()
            swap(&buffer, &spare)
            return buffer
        }
        return UniqueArray(capacity: capacity)
    }

    @inline(always)
    mutating func operation(
        _ alternative: WebCore.CSSCalc.CSSCalcSwiftAlternative,
        only child: consuming CalcNode,
        _ type: CalcType
    ) -> CalcNode {
        var children = takeBuffer(1)
        children.append(child)
        return calcParseOperation(alternative, children, type)
    }

    @inline(always)
    mutating func recycleEmptyBuffer(_ node: inout CalcNode) {
        if node.children.isEmpty && node.children.capacity > spare.capacity {
            swap(&node.children, &spare)
            node.children.removeAll()
            if node.children.capacity > 0 {
                node.children = UniqueArray()
            }
        }
    }
}

/// `simplify(Sum&)`, `simplify(Product&)`, `simplify(Min&)` and `simplify(Max&)` at construction,
/// as `parseCalcSum`, `parseCalcProduct` and `consumeOneOrMoreArguments` call them.
///
/// Only over children that are all `Number`, `Percentage` or `CanonicalDimension` leaves, which
/// `simplifyParsed` does not change, so the pass would fold this node over the same operands.
/// Folding the result again is a no-op. Any other child can change in the pass, so its parent is
/// left to it.
@inline(always)
private func calcFoldAtConstruction(
    _ node: inout CalcNode,
    _ state: inout CalcParseState
) {
    guard state.foldAtConstruction else {
        return
    }
    var k = 0
    while k < node.children.count {
        switch node.children[k].alternative {
        case .Number, .Percentage, .CanonicalDimension:
            k &+= 1
        default:
            return
        }
    }
    let fold = CalcFold(options: state.simplification, builder: nil, keepsBuffers: true)
    switch node.alternative {
    case .Sum: fold.foldSum(&node)
    case .Product: fold.foldProduct(&node)
    case .Min: fold.foldMinMax(&node, false)
    case .Max: fold.foldMinMax(&node, true)
    default: return
    }
    switch node.alternative {
    case .Sum, .Product, .Min, .Max: node.flags |= CalcNodeFlags.foldedAtConstruction
    default: break
    }
    state.recycleEmptyBuffer(&node)
}

/// One token as the grammar reads it: the token's own storage, decoded one field at a time as a
/// production asks, so a whitespace or block walk reads two bitfields and nothing else.
///
/// Each field answers what `CSSParserToken`'s accessor of the same name answers, and answers it only
/// for the token types that accessor is for, as the C++ grammar asks: `numericValue` is 0 and
/// `delimiter` is `\0` for any other type, because the union behind them holds another member then.
/// The keyword `id`/`functionId` needs the range, so it is `CalcTokens.id(_:)`/`functionId(_:)`.
private struct CalcToken {
    let bits: WebCore.CSSParserTokenBits
    let index: UInt32

    @inline(always)
    var type: WebCore.CSSParserTokenType { WebCore.CSSParserTokenType(rawValue: UInt8(truncatingIfNeeded: bits.type)) }
    @inline(always)
    var blockType: UInt8 { UInt8(truncatingIfNeeded: bits.blockType) }
    @inline(always)
    var unitRaw: UInt8 { UInt8(truncatingIfNeeded: bits.unit) }
    @inline(always)
    var numericValue: Double {
        let t = type
        return t == WebCore.NumberToken || t == WebCore.PercentageToken || t == WebCore.DimensionToken ? bits.numericValue : 0
    }
    @inline(always)
    var delimiter: UInt16 { type == WebCore.DelimiterToken ? bits.delimiter : 0 }
    /// For a `DimensionToken`: `conversionToCanonicalUnitRequiresConversionData(unit)`.
    @inline(always)
    var unitNeedsConversionData: Bool { WebCore.CSSCalc.cssCalcSwiftUnitNeedsConversionData(unitRaw) }
}

/// The tokens of one `calc()`, copied out of the range as their storage in one crossing per parse
/// (`CSSCalcSwiftParseCursor::fillTokenBits`) and decoded by `CalcToken` as they are read, and the
/// C++ cursor for the upcalls that need the range itself (a symbol lookup, a `<random-key>`, a
/// `calc-mix()` weight, an `<anchor-element>`).
///
/// Reading the C++ token vector in place would need a bounds-carrying view of C++ storage
/// (rdar://186723514). A Swift-owned buffer that C++ fills through a `__counted_by` + `noescape`
/// parameter needs none.
///
/// `~Escapable` because `tokens` is a `Span` over the caller's stack buffer.
private struct CalcTokens: ~Escapable {
    let cursor: WebCore.CSSCalc.CSSCalcSwiftParseCursor
    /// The range's `tokenCount()` tokens. The `EOFToken` `CSSParserTokenRange::peek` answers past the
    /// end is `token`'s, not a slot.
    let tokens: Span<WebCore.CSSParserTokenBits>

    @inline(always)
    @_lifetime(copy tokens)
    init(_ cursor: WebCore.CSSCalc.CSSCalcSwiftParseCursor, _ tokens: Span<WebCore.CSSParserTokenBits>) {
        self.cursor = cursor
        self.tokens = tokens
    }

    /// The token at `index`, or the EOF token at or past the end of the range, as `peek` answers.
    @inline(always)
    func token(_ index: UInt32) -> CalcToken {
        let i = Int(index)
        if i < tokens.count { return CalcToken(bits: tokens[i], index: index) }
        // `CSSParserTokenRange::eofToken()`'s storage: `CSSParserToken(EOFToken)`, no block, no value.
        var eof = WebCore.CSSParserTokenBits()
        eof.type = UInt32(WebCore.EOFToken.rawValue)
        return CalcToken(bits: eof, index: index)
    }

    /// `id()`: the `CSSValueID` of an `IdentToken`, `CSSValueInvalid` for any other.
    @inline(always)
    func id(_ token: CalcToken) -> UInt16 { token.type == WebCore.IdentToken ? keyword(token) : 0 }
    /// `functionId()`: the `CSSValueID` of a `FunctionToken`, `CSSValueInvalid` for any other.
    @inline(always)
    func functionId(_ token: CalcToken) -> UInt16 { token.type == WebCore.FunctionToken ? keyword(token) : 0 }
    /// The token's keyword cache when it is filled, and C++ otherwise.
    ///
    /// The same test as `identOrFunctionId`.
    @inline(always)
    private func keyword(_ token: CalcToken) -> UInt16 {
        let cached = token.bits.id
        return cached >= 0 ? UInt16(truncatingIfNeeded: cached) : cursor.keywordId(token.index)
    }
    /// For a `FunctionToken`: `calc()` or `-webkit-calc()` specifically.
    ///
    /// A function block that is neither this nor `isCalcFunction` is a parse failure, which is what
    /// the C++ path does with it.
    @inline(always)
    func isPlainCalcFunction(_ token: CalcToken) -> Bool {
        let f = functionId(token)
        return f == UInt16(WebCore.CSSValueCalc.rawValue) || f == UInt16(WebCore.CSSValueWebkitCalc.rawValue)
    }
    /// For a `FunctionToken`: `isCalcFunction(functionId)`.
    @inline(always)
    func isCalcFunction(_ token: CalcToken) -> Bool { WebCore.CSSCalc.cssCalcSwiftIsCalcFunction(functionId(token)) }

    @inline(always)
    func tokenCount() -> UInt32 { UInt32(truncatingIfNeeded: tokens.count) }
    @inline(always)
    func lookupSymbol(_ valueID: UInt16) -> WebCore.CSSCalc.CSSCalcSwiftSymbolResult {
        cursor.lookupSymbol(valueID)
    }
    @inline(always)
    func consumeRandomKey(_ index: UInt32) -> WebCore.CSSCalc.CSSCalcSwiftConsumedPayload {
        cursor.consumeRandomKey(index)
    }
    @inline(always)
    func consumeCalcMixWeightAt(_ index: UInt32) -> WebCore.CSSCalc.CSSCalcSwiftConsumedPayload {
        cursor.consumeCalcMixWeightAt(index)
    }
    @inline(always)
    func resolveDashedIdentAt(_ index: UInt32) -> UInt32 {
        cursor.resolveDashedIdentAt(index)
    }
}

@inline(always)
private func withCalcTokens<R: ~Copyable>(
    _ cursor: WebCore.CSSCalc.CSSCalcSwiftParseCursor,
    _ body: (borrowing CalcTokens) -> R
) -> R {
    let count = Int(cursor.tokenCount())
    return withTemporaryAllocation(of: WebCore.CSSParserTokenBits.self, capacity: count) { buffer in
        // Initialised before C++ writes it, because `MutableSpan` covers initialised elements only.
        while !buffer.isFull {
            buffer.append(WebCore.CSSParserTokenBits())
        }
        var slots = buffer.mutableSpan
        cursor.fillTokenBits(&slots)
        _ = consume slots
        return body(CalcTokens(cursor, buffer.span))
    }
}

@inline(always)
private func calcToken(
    _ cursor: borrowing CalcTokens,
    _ state: inout CalcParseState,
    _ index: UInt32
) -> CalcToken {
    cursor.token(index)
}

@inline(always)
private func calcTokenIsWhitespace(_ type: WebCore.CSSParserTokenType) -> Bool {
    type == WebCore.NonNewlineWhitespaceToken || type == WebCore.NewlineToken
}

private func calcSkipWhitespace(
    _ cursor: borrowing CalcTokens,
    _ index: inout UInt32,
    _ end: UInt32,
    _ state: inout CalcParseState
) {
    while index < end && calcTokenIsWhitespace(calcToken(cursor, &state, index).type) {
        index += 1
    }
}

/// The index of the `BlockEnd` matching the `BlockStart` at `start`, or nil if the range ends
/// first.
private func calcFindBlockEnd(
    _ cursor: borrowing CalcTokens,
    _ state: inout CalcParseState,
    _ start: UInt32,
    _ end: UInt32
) -> UInt32? {
    var depth = 0
    var i = start
    while i < end {
        let blockType = calcToken(cursor, &state, i).blockType
        if blockType == calcBlockStart {
            depth += 1
        } else if blockType == calcBlockEnd {
            depth -= 1
            if depth == 0 { return i }
        }
        i += 1
    }
    return nil
}

/// `CSSParserToken::BlockType`, pinned on the C++ side one enumerator per line.
private let calcBlockStart: UInt8 = 1
private let calcBlockEnd: UInt8 = 2

// MARK: The grammar's output

/// One parsed subtree, owned, and the `Type` the grammar computed for it.
private struct CalcParsed: ~Copyable {
    var node: CalcNode
    let type: CalcType
}

/// A numeric leaf, or nil if its unit does not fit the node's `unitType`.
@inline(always)
private func calcParseLeaf(
    _ alternative: WebCore.CSSCalc.CSSCalcSwiftAlternative,
    _ value: Double,
    _ unitType: UInt16,
    _ percentHint: UInt8,
    _ flags: UInt16 = 0,
    _ origin: UInt32 = calcNoPayload
) -> CalcNode? {
    // No `CSSUnitType` enumerator fails this, but a silent truncation would be a wrong unit.
    guard let narrowUnit = UInt8(exactly: unitType) else {
        return nil
    }
    return CalcNode(
        value: value,
        type: CalcType(),
        // The sentinel, except on a `calc-mix()`'s interleaved weight carrier whose weight is a math
        // function (`CalcNodeFlags.calcMixWeightIsCalc`), which names its payload. A weight carrier is
        // never emitted as a node: `calcEmitParsedCalcMix` reads it and steps past it.
        origin: origin,
        valueID: 0,
        unitType: narrowUnit,
        alternative: alternative,
        percentHint: percentHint,
        flags: flags,
        children: UniqueArray()
    )
}

@inline(always)
private func calcParseOperation(
    _ alternative: WebCore.CSSCalc.CSSCalcSwiftAlternative,
    _ children: consuming UniqueArray<CalcNode>,
    _ type: CalcType,
    _ flags: UInt16 = 0,
    _ valueID: UInt16 = 0,
    _ origin: UInt32 = calcNoPayload
) -> CalcNode {
    CalcNode(
        value: 0,
        // The type the grammar computed: `copyAndSimplify` ends at `makeChild(..., getType(root))`,
        // and a fresh `toType` over simplified operands can differ.
        type: type,
        // The sentinel for every operation but three: on an `Anchor`, `AnchorSize` or `Random` it is
        // the index of the payload the parse resolved, an `<anchor-element>` or a `<random-key>`,
        // which `buildAnchor` and `buildRandom` read back.
        origin: origin,
        valueID: valueID,
        unitType: 0,
        alternative: alternative,
        percentHint: 0,
        flags: flags,
        children: children
    )
}

/// An operation over exactly one child: the wrappers (`Negate`, `Invert`, `Deg2Rad`) and every
/// one-argument function.
@inline(always)
private func calcParseOperation(
    _ alternative: WebCore.CSSCalc.CSSCalcSwiftAlternative,
    only child: consuming CalcNode,
    _ type: CalcType
) -> CalcNode {
    var children = UniqueArray<CalcNode>(capacity: 1)
    children.append(child)
    return calcParseOperation(alternative, children, type)
}

/// The first capacity of the children buffer of a `Sum`, a `Product` or an argument list.
///
/// `UniqueArray` grows 0, 1, 2, 3, 5 from empty, so four holds any list of up to four operands in
/// one allocation.
private let calcOperandListCapacity = 4

/// The operand of a `-` in a `<calc-sum>`: `Negate { operand }`, or with the wrapper already
/// folded.
///
/// `parseCalcSum` simplifies each `Negate` as it builds it. For a `Number`, `Percentage` or
/// `CanonicalDimension` operand the fold is `calcFoldNegate`'s first case, and these leaves have no
/// fold of their own that would run first. A `NonCanonicalDimension` is left to the pass, which
/// runs `foldNonCanonicalDimension` before the wrapper's fold.
@inline(always)
private func calcParseNegate(
    _ operand: consuming CalcNode,
    _ type: CalcType,
    _ state: borrowing CalcParseState
) -> CalcNode {
    if state.foldAtConstruction {
        switch operand.alternative {
        case .Number, .Percentage, .CanonicalDimension:
            // The unary minus, as `calcFoldNegate`: `-(+0)` is `-0`.
            operand.value = -operand.value
            return operand
        default:
            break
        }
    }
    return calcParseOperation(.Negate, only: operand, type)
}

/// The operand of a `/` in a `<calc-product>`.
///
/// The reasoning of `calcParseNegate`, for the first case of `calcFoldInvert`, which is a `Number`
/// leaf only.
@inline(always)
private func calcParseInvert(
    _ operand: consuming CalcNode,
    _ type: CalcType,
    _ state: borrowing CalcParseState
) -> CalcNode {
    if state.foldAtConstruction, operand.alternative == .Number {
        operand.value = CalcExecutor.invert(operand.value)
        return operand
    }
    return calcParseOperation(.Invert, only: operand, type)
}

/// Mark `node` and every node below it as inside the `<anchor-side>` of an `anchor()`.
private func calcMarkInsideAnchorSide(_ node: inout CalcNode) {
    node.flags |= CalcNodeFlags.insideAnchorSide
    var k = 0
    while k < node.children.count {
        calcMarkInsideAnchorSide(&node.children[k])
        k &+= 1
    }
}

/// `<calc-value>` = `<number>` | `<dimension>` | `<percentage>` | `<calc-keyword>` | `( <calc-sum>
/// )`.
private func calcParseValue(
    _ cursor: borrowing CalcTokens,
    _ index: inout UInt32,
    _ end: UInt32,
    _ depth: Int32,
    _ state: inout CalcParseState
) -> CalcParsed? {
    if depth > calcMaxExpressionDepth { return nil }
    if index >= end { return nil }

    let token = calcToken(cursor, &state, index)

    if token.blockType == calcBlockStart {
        return calcParseBlock(cursor, &index, end, depth, &state, token)
    }

    index += 1
    calcSkipWhitespace(cursor, &index, end, &state)

    switch token.type {
    case WebCore.NumberToken:
        guard
            let me = calcParseLeaf(
                .Number,
                token.numericValue,
                UInt16(WebCore.CSSUnitType.Number.rawValue),
                0
            )
        else { return nil }
        return CalcParsed(node: me, type: CalcType())

    case WebCore.PercentageToken:
        // `parseCalcPercentage`: the hint comes from the category, not from the token. An
        // `<anchor-side>` parses at `CSS::Category::Percentage` and overrides it.
        let hint = state.options.percentageLeafHint
        guard
            let me = calcParseLeaf(
                .Percentage,
                token.numericValue,
                UInt16(WebCore.CSSUnitType.Percentage.rawValue),
                hint
            )
        else { return nil }
        var percentType = CalcType()
        percentType.percent = 1
        if let unwrapped = percentHintFromRawValue(hint) {
            percentType = percentType.withPercentHintApplied(unwrapped)
        }
        return CalcParsed(node: me, type: percentType)

    case WebCore.DimensionToken:
        // Never nil: an imported C++ scoped enum's `init?(rawValue:)` does not validate.
        guard let unit = WebCore.CSSUnitType(rawValue: token.unitRaw) else { return nil }
        if unit == WebCore.CSSUnitType.Unknown { return nil }
        if token.unitNeedsConversionData {
            // `absoluteLengthUnitsOnly` makes this invalid input, not a decline.
            if state.options.absoluteLengthUnitsOnly { return nil }
            state.requiresConversionData = true
        }
        guard
            let alternative = calcNumericAlternativeForLeafKind(
                WebCore.CSSCalc.cssCalcSwiftLeafKindForUnit(UInt16(token.unitRaw))
            )
        else { return nil }
        guard
            let me = calcParseLeaf(
                alternative,
                token.numericValue,
                UInt16(token.unitRaw),
                0
            )
        else { return nil }
        return CalcParsed(node: me, type: CalcType.determineType(unit))

    case WebCore.IdentToken:
        return calcParseKeyword(cursor, &state, token)

    default:
        return nil
    }
}

/// `parseCalcKeyword`, in its order: the symbol table first, then the five `<calc-keyword>`
/// constants, so an id present in both resolves as a `Symbol`.
///
/// With `hasAllowedSymbols` clear (no symbols, or inside an `<anchor-side>`) the table lookup is
/// skipped. Any other ident is invalid input.
@inline(never)
private func calcParseKeyword(
    _ cursor: borrowing CalcTokens,
    _ state: inout CalcParseState,
    _ token: CalcToken
) -> CalcParsed? {
    if state.options.hasAllowedSymbols {
        let symbol = cursor.lookupSymbol(cursor.id(token))
        if symbol.resolved {
            if symbol.needsConversionData {
                if state.options.absoluteLengthUnitsOnly { return nil }
                state.requiresConversionData = true
            }
            guard let unit = WebCore.CSSUnitType(rawValue: UInt8(truncatingIfNeeded: symbol.unitType)) else {
                // Never taken: an imported C++ scoped enum's `init?(rawValue:)` does not validate.
                return nil
            }
            // From the symbol's unit, not its value: the value is not known until simplification.
            let type = CalcType.determineType(unit)
            guard let me = calcParseSymbol(cursor.id(token), symbol.unitType) else { return nil }
            return CalcParsed(node: me, type: type)
        }
    }

    let constant = WebCore.CSSCalc.cssCalcSwiftLookupConstantNumber(cursor.id(token))
    guard constant.resolved else { return nil }
    guard
        let me = calcParseLeaf(
            .Number,
            constant.value,
            UInt16(WebCore.CSSUnitType.Number.rawValue),
            0
        )
    else { return nil }
    return CalcParsed(node: me, type: CalcType())
}

@inline(always)
private func calcParseSymbol(
    _ valueID: UInt16,
    _ unitType: UInt16
) -> CalcNode? {
    guard let narrowUnit = UInt8(exactly: unitType) else {
        return nil
    }
    return CalcNode(
        value: 0,
        type: CalcType(),
        origin: calcNoPayload,
        valueID: valueID,
        unitType: narrowUnit,
        alternative: .Symbol,
        percentHint: 0,
        flags: 0,
        children: UniqueArray()
    )
}

/// Which of the four numeric alternatives the answer of `cssCalcSwiftLeafKindForUnit` names.
@inline(always)
private func calcNumericAlternativeForLeafKind(_ raw: UInt8) -> WebCore.CSSCalc.CSSCalcSwiftAlternative? {
    switch raw {
    case CalcAlternative.Number.rawValue: return .Number
    case CalcAlternative.Percentage.rawValue: return .Percentage
    case CalcAlternative.CanonicalDimension.rawValue: return .CanonicalDimension
    case CalcAlternative.NonCanonicalDimension.rawValue: return .NonCanonicalDimension
    default: return nil
    }
}

/// The block case of `<calc-value>`, kept out of line.
@inline(never)
private func calcParseBlock(
    _ cursor: borrowing CalcTokens,
    _ index: inout UInt32,
    _ end: UInt32,
    _ depth: Int32,
    _ state: inout CalcParseState,
    _ token: CalcToken
) -> CalcParsed? {
    // `parseCalcValue`'s `findBlock`: a `LeftParenthesisToken` or a `calc()` / `-webkit-calc()`
    // function is a nested `<calc-sum>`. A math function not listed in
    // `calcParseFunctionAlternative` is refused; any other function block is invalid input.
    let isPlainCalc =
        token.type == WebCore.LeftParenthesisToken
        || cursor.isPlainCalcFunction(token)
    if !isPlainCalc {
        if let function = calcParseFunctionAlternative(cursor.functionId(token)) {
            return calcParseFunctionBlock(
                cursor,
                &index,
                end,
                depth,
                &state,
                function.alternative,
                function.arguments
            )
        }
        if cursor.isCalcFunction(token) {
            state.declined = true
            state.declineReason = calcParseDeclineReasonForFunction(cursor.functionId(token))
        }
        return nil
    }

    guard let blockEnd = calcFindBlockEnd(cursor, &state, index, end) else { return nil }

    var inner = index + 1
    calcSkipWhitespace(cursor, &inner, blockEnd, &state)
    guard let innerParsed = calcParseSum(cursor, &inner, blockEnd, depth + 1, &state) else { return nil }
    // Extraneous tokens inside the block are invalid input.
    calcSkipWhitespace(cursor, &inner, blockEnd, &state)
    if inner != blockEnd { return nil }

    index = blockEnd + 1
    calcSkipWhitespace(cursor, &index, end, &state)
    // A parenthesised group contributes no node of its own.
    return innerParsed
}

// MARK: The math functions

/// Which `consume*Arguments` helper `parseCalcFunction` runs for a function: its argument grammar.
private enum CalcFunctionArguments: UInt8 {
    /// `<calc-sum>#`: `consumeOneOrMoreArguments`.
    case oneOrMore
    /// Exactly one `<calc-sum>`: `consumeExactlyOneArgument`.
    case exactlyOne
    /// `[ <calc-sum> | none ], <calc-sum>, [ <calc-sum> | none ]`: `consumeClamp`.
    case clamp
    /// `<calc-sum>, <calc-sum>?`: `consumeOneOrTwoArguments`. Only `log()`; `round()` has the same
    /// shape but a different type rule.
    case oneOrTwo
    /// `<rounding-strategy>?, <calc-sum>, <calc-sum>?`: `consumeRound`.
    case round
    /// Two comma-separated `<calc-sum>`s: `consumeExactlyTwoArguments`.
    case exactlyTwo
    /// `no-clamp? <calc-sum>, <calc-sum>, <calc-sum>`: `consumeProgress`.
    case progress
    /// `consumeZeroArguments<Op>`: `sibling-count()` and `sibling-index()`.
    case zeroArguments
    /// `[ <calc-sum> <percentage [0,100]>? ]#`: `consumeCalcMix`.
    case calcMix
    /// `anchor( <anchor-element>? && <anchor-side>, <length-percentage>? )`: `consumeAnchor`.
    case anchor
    /// `anchor-size( [ <anchor-element> || <anchor-size> ]? , <length-percentage>? )`:
    /// `consumeAnchorSize`.
    case anchorSize
    /// `random( <random-key>? , <calc-sum>, <calc-sum>, <calc-sum>? )`: `consumeRandom`. The
    /// `<random-key>` is not a child; see `calcParseRandom`.
    case random
}

/// Which `CSSCalcSwiftParseDeclineReason` an unhandled `isCalcFunction` belongs to.
@inline(never)
private func calcParseDeclineReasonForFunction(
    _ functionId: UInt16
)
    -> WebCore.CSSCalc.CSSCalcSwiftParseDeclineReason
{
    switch functionId {
    case WebCore.CSSValueSiblingCount.rawValue, WebCore.CSSValueSiblingIndex.rawValue:
        return .TreeCounting
    default:
        return .MathFunction
    }
}

/// Which `CSSCalcSwiftAlternative` the `CSSValueID` of a `FunctionToken` names, and how its
/// arguments parse, or nil for a function this grammar does not handle.
@inline(always)
private func calcParseFunctionAlternative(
    _ functionId: UInt16
)
    -> (alternative: WebCore.CSSCalc.CSSCalcSwiftAlternative, arguments: CalcFunctionArguments)?
{
    switch functionId {
    case WebCore.CSSValueMin.rawValue: return (.Min, .oneOrMore)
    case WebCore.CSSValueMax.rawValue: return (.Max, .oneOrMore)
    case WebCore.CSSValueSin.rawValue: return (.Sin, .exactlyOne)
    case WebCore.CSSValueCos.rawValue: return (.Cos, .exactlyOne)
    case WebCore.CSSValueTan.rawValue: return (.Tan, .exactlyOne)
    case WebCore.CSSValueAsin.rawValue: return (.Asin, .exactlyOne)
    case WebCore.CSSValueAcos.rawValue: return (.Acos, .exactlyOne)
    case WebCore.CSSValueAtan.rawValue: return (.Atan, .exactlyOne)
    case WebCore.CSSValueSqrt.rawValue: return (.Sqrt, .exactlyOne)
    case WebCore.CSSValueExp.rawValue: return (.Exp, .exactlyOne)
    case WebCore.CSSValueAbs.rawValue: return (.Abs, .exactlyOne)
    case WebCore.CSSValueSign.rawValue: return (.Sign, .exactlyOne)
    case WebCore.CSSValueClamp.rawValue: return (.Clamp, .clamp)
    case WebCore.CSSValueRound.rawValue: return (.RoundNearest, .round)
    case WebCore.CSSValueLog.rawValue: return (.Log, .oneOrTwo)
    case WebCore.CSSValueHypot.rawValue: return (.Hypot, .oneOrMore)
    case WebCore.CSSValueMod.rawValue: return (.Mod, .exactlyTwo)
    case WebCore.CSSValueRem.rawValue: return (.Rem, .exactlyTwo)
    case WebCore.CSSValueAtan2.rawValue: return (.Atan2, .exactlyTwo)
    case WebCore.CSSValuePow.rawValue: return (.Pow, .exactlyTwo)
    case WebCore.CSSValueProgress.rawValue: return (.Progress, .progress)
    case WebCore.CSSValueSiblingCount.rawValue: return (.SiblingCount, .zeroArguments)
    case WebCore.CSSValueSiblingIndex.rawValue: return (.SiblingIndex, .zeroArguments)
    case WebCore.CSSValueCalcMix.rawValue: return (.CalcMix, .calcMix)
    case WebCore.CSSValueAnchor.rawValue: return (.Anchor, .anchor)
    case WebCore.CSSValueAnchorSize.rawValue: return (.AnchorSize, .anchorSize)
    case WebCore.CSSValueRandom.rawValue: return (.Random, .random)
    default: return nil
    }
}

/// A math function as a nested `<calc-value>`: find the block, parse its arguments, step past.
@inline(never)
private func calcParseFunctionBlock(
    _ cursor: borrowing CalcTokens,
    _ index: inout UInt32,
    _ end: UInt32,
    _ depth: Int32,
    _ state: inout CalcParseState,
    _ alternative: WebCore.CSSCalc.CSSCalcSwiftAlternative,
    _ arguments: CalcFunctionArguments
) -> CalcParsed? {
    guard let blockEnd = calcFindBlockEnd(cursor, &state, index, end) else { return nil }

    var inner = index + 1
    let argumentsParsed: CalcParsed?
    switch arguments {
    case .oneOrMore:
        argumentsParsed = calcParseArgumentList(
            cursor,
            &inner,
            blockEnd,
            depth + 1,
            &state,
            alternative
        )
    case .exactlyOne:
        argumentsParsed = calcParseUnaryFunction(
            cursor,
            &inner,
            blockEnd,
            depth + 1,
            &state,
            alternative
        )
    case .clamp:
        argumentsParsed = calcParseClamp(
            cursor,
            &inner,
            blockEnd,
            depth + 1,
            &state
        )
    case .oneOrTwo:
        argumentsParsed = calcParseOneOrTwoArguments(
            cursor,
            &inner,
            blockEnd,
            depth + 1,
            &state,
            alternative
        )
    case .round:
        argumentsParsed = calcParseRound(
            cursor,
            &inner,
            blockEnd,
            depth + 1,
            &state
        )
    case .exactlyTwo:
        argumentsParsed = calcParseTwoArguments(
            cursor,
            &inner,
            blockEnd,
            depth + 1,
            &state,
            alternative
        )
    case .progress:
        argumentsParsed = calcParseProgress(
            cursor,
            &inner,
            blockEnd,
            depth + 1,
            &state
        )
    case .zeroArguments:
        argumentsParsed = calcParseZeroArguments(
            cursor,
            &inner,
            blockEnd,
            &state,
            alternative
        )
    case .calcMix:
        argumentsParsed = calcParseCalcMix(
            cursor,
            &inner,
            blockEnd,
            depth + 1,
            &state
        )
    case .anchor:
        argumentsParsed = calcParseAnchor(
            cursor,
            &inner,
            blockEnd,
            depth + 1,
            &state
        )
    case .anchorSize:
        argumentsParsed = calcParseAnchorSize(
            cursor,
            &inner,
            blockEnd,
            depth + 1,
            &state
        )
    case .random:
        argumentsParsed = calcParseRandom(
            cursor,
            &inner,
            blockEnd,
            depth + 1,
            &state
        )
    }
    guard let parsed = consume argumentsParsed else { return nil }
    if inner != blockEnd { return nil }

    index = blockEnd + 1
    calcSkipWhitespace(cursor, &index, end, &state)
    return parsed
}

/// `consumeZeroArguments<Op>` and the conditions guarding its two callers: `sibling-count()` and
/// `sibling-index()`.
///
///   * `treeCountingAllowed` clear: invalid input, as the C++ returns `{ }`.
///   * a fold would run (`CalcParseState.conversionDataFoldsRun`): refused with `.TreeCounting`,
///     because the fold is C++'s and needs a `CSSCalc::Child`.
///   * otherwise: the leaf, unfolded, as `copyAndSimplify` leaves it.
@inline(never)
private func calcParseZeroArguments(
    _ cursor: borrowing CalcTokens,
    _ index: inout UInt32,
    _ end: UInt32,
    _ state: inout CalcParseState,
    _ alternative: WebCore.CSSCalc.CSSCalcSwiftAlternative
) -> CalcParsed? {
    if !state.options.treeCountingAllowed {
        return nil
    }
    if state.conversionDataFoldsRun {
        state.declined = true
        state.declineReason = .TreeCounting
        return nil
    }

    calcSkipWhitespace(cursor, &index, end, &state)
    state.requiresConversionData = true
    guard let me = calcParseLeaf(alternative, 0, 0, 0) else { return nil }
    return CalcParsed(node: me, type: CalcType())
}

/// `consumeExactlyOneArgument<Op>`: one `<calc-sum>`, its type checked against `Op::input`, the
/// node's type `transformType<Op::output>` of it, and a `Deg2Rad` wrapper around an `<angle>`
/// argument of the three trigonometric functions.
private func calcParseUnaryFunction(
    _ cursor: borrowing CalcTokens,
    _ index: inout UInt32,
    _ end: UInt32,
    _ depth: Int32,
    _ state: inout CalcParseState,
    _ alternative: WebCore.CSSCalc.CSSCalcSwiftAlternative
) -> CalcParsed? {
    if depth > calcMaxExpressionDepth { return nil }

    calcSkipWhitespace(cursor, &index, end, &state)
    guard let argument = calcParseSum(cursor, &index, end, depth, &state) else { return nil }
    calcSkipWhitespace(cursor, &index, end, &state)

    var wrapInDeg2Rad = false
    let outputType: CalcType

    switch alternative {
    case .Sin, .Cos, .Tan:
        guard argument.type.matchesNumberOrAngle,
            let transformed = CalcType.makeNumber().madeConsistent(with: argument.type)
        else { return nil }
        outputType = transformed

        // Only an argument matching `<angle>` gets the wrapper (`sin(30deg)`, not `sin(0.5)`), and
        // the wrapper's type is `Type { }`, not the angle's.
        if argument.type.matchesAngle {
            wrapInDeg2Rad = true
        }

    case .Asin, .Acos, .Atan:
        guard argument.type.matchesNumber,
            let transformed = CalcType.makeAngle().madeConsistent(with: argument.type)
        else { return nil }
        outputType = transformed

    case .Sqrt, .Exp:
        guard argument.type.matchesNumber,
            let transformed = CalcType.makeNumber().madeConsistent(with: argument.type)
        else { return nil }
        outputType = transformed

    case .Sign:
        guard let transformed = CalcType.makeNumber().madeConsistent(with: argument.type) else { return nil }
        outputType = transformed

    case .Abs:
        outputType = argument.type

    default:
        // Unreachable through `calcParseFunctionAlternative`'s `.exactlyOne` case.
        return nil
    }

    var operand = argument.node
    if wrapInDeg2Rad {
        operand = calcParseOperation(.Deg2Rad, only: operand, CalcType())
    }
    return CalcParsed(node: state.operation(alternative, only: operand, outputType), type: outputType)
}

/// `consumeCommaIncludingWhitespace`: a comma and the whitespace after it.
@inline(always)
private func calcParseComma(
    _ cursor: borrowing CalcTokens,
    _ index: inout UInt32,
    _ end: UInt32,
    _ state: inout CalcParseState
) -> Bool {
    guard index < end, calcToken(cursor, &state, index).type == WebCore.CommaToken else { return false }
    index += 1
    calcSkipWhitespace(cursor, &index, end, &state)
    return true
}

/// One `[ <calc-sum> | none ]`: the subtree, or nil for `none`, whose type is `Type { }`.
private struct CalcParsedSumOrNone: ~Copyable {
    var node: CalcNode?
    let type: CalcType
    let isNone: Bool
}

/// `parseCalcSumOrNone`: the keyword `none`, or a `<calc-sum>`.
@inline(always)
private func calcParseSumOrNone(
    _ cursor: borrowing CalcTokens,
    _ index: inout UInt32,
    _ end: UInt32,
    _ depth: Int32,
    _ state: inout CalcParseState
) -> CalcParsedSumOrNone? {
    if index < end, cursor.id(calcToken(cursor, &state, index)) == UInt16(WebCore.CSSValueNone.rawValue) {
        index += 1
        calcSkipWhitespace(cursor, &index, end, &state)
        return CalcParsedSumOrNone(node: nil, type: CalcType(), isNone: true)
    }
    guard let parsed = calcParseSum(cursor, &index, end, depth, &state) else { return nil }
    let type = parsed.type
    return CalcParsedSumOrNone(node: parsed.node, type: type, isNone: false)
}

/// `consumeClamp`: `clamp( [ <calc-sum> | none ], <calc-sum>, [ <calc-sum> | none ] )`.
///
/// `computeType` merges only the bounds that are present, and `Type { }` is not an identity for
/// `consistentType`, so the four cases are written out. All merges are `MergePolicy::Consistent`,
/// with no input check and no output transform.
private func calcParseClamp(
    _ cursor: borrowing CalcTokens,
    _ index: inout UInt32,
    _ end: UInt32,
    _ depth: Int32,
    _ state: inout CalcParseState
) -> CalcParsed? {
    if depth > calcMaxExpressionDepth { return nil }
    calcSkipWhitespace(cursor, &index, end, &state)

    guard var minimum = calcParseSumOrNone(cursor, &index, end, depth, &state) else { return nil }
    calcSkipWhitespace(cursor, &index, end, &state)
    guard calcParseComma(cursor, &index, end, &state) else { return nil }

    guard let value = calcParseSum(cursor, &index, end, depth, &state) else { return nil }
    calcSkipWhitespace(cursor, &index, end, &state)
    guard calcParseComma(cursor, &index, end, &state) else { return nil }

    guard var maximum = calcParseSumOrNone(cursor, &index, end, depth, &state) else { return nil }
    calcSkipWhitespace(cursor, &index, end, &state)

    let noneMinimum = minimum.isNone
    let noneMaximum = maximum.isNone

    let outputType: CalcType
    if noneMinimum && noneMaximum {
        outputType = value.type
    } else if noneMinimum {
        guard let merged = value.type.consistentType(with: maximum.type) else { return nil }
        outputType = merged
    } else if noneMaximum {
        guard let merged = minimum.type.consistentType(with: value.type) else { return nil }
        outputType = merged
    } else {
        guard let lower = minimum.type.consistentType(with: value.type),
            let merged = lower.consistentType(with: maximum.type)
        else { return nil }
        outputType = merged
    }

    // Min, val, max, over the bounds that exist: `buildOperation` fills its slots in list order,
    // and the flags say which bound is absent.
    var children = state.takeBuffer(3)
    if let lower = minimum.node.take() {
        children.append(lower)
    }
    children.append(value.node)
    if let upper = maximum.node.take() {
        children.append(upper)
    }

    var flags: UInt16 = 0
    if noneMinimum { flags |= CalcNodeFlags.clampNoneMinimum }
    if noneMaximum { flags |= CalcNodeFlags.clampNoneMaximum }

    return CalcParsed(node: calcParseOperation(.Clamp, children, outputType, flags), type: outputType)
}

/// Which `<rounding-strategy>` an ident names, as the alternative it selects.
@inline(always)
private func calcRoundingStrategyAlternative(
    _ id: UInt16
)
    -> WebCore.CSSCalc.CSSCalcSwiftAlternative?
{
    switch id {
    case UInt16(WebCore.CSSValueNearest.rawValue): return .RoundNearest
    case UInt16(WebCore.CSSValueUp.rawValue): return .RoundUp
    case UInt16(WebCore.CSSValueDown.rawValue): return .RoundDown
    case UInt16(WebCore.CSSValueToZero.rawValue): return .RoundToZero
    default: return nil
    }
}

/// `consumeRound`: `round( <rounding-strategy>?, <calc-sum>, <calc-sum>? )`.
private func calcParseRound(
    _ cursor: borrowing CalcTokens,
    _ index: inout UInt32,
    _ end: UInt32,
    _ depth: Int32,
    _ state: inout CalcParseState
) -> CalcParsed? {
    // `calcParseFunctionBlock` hands over the range starting one token past `(`, so leading
    // whitespace is still there.
    calcSkipWhitespace(cursor, &index, end, &state)

    var alternative = WebCore.CSSCalc.CSSCalcSwiftAlternative.RoundNearest
    if index < end, let selected = calcRoundingStrategyAlternative(cursor.id(calcToken(cursor, &state, index))) {
        index += 1
        calcSkipWhitespace(cursor, &index, end, &state)
        guard calcParseComma(cursor, &index, end, &state) else { return nil }
        alternative = selected
    }
    return calcParseRoundArguments(cursor, &index, end, depth, &state, alternative)
}

/// `consumeRoundArguments<Op>`: `<calc-sum>, <calc-sum>?` under the type rule of `round()`.
private func calcParseRoundArguments(
    _ cursor: borrowing CalcTokens,
    _ index: inout UInt32,
    _ end: UInt32,
    _ depth: Int32,
    _ state: inout CalcParseState,
    _ alternative: WebCore.CSSCalc.CSSCalcSwiftAlternative
) -> CalcParsed? {
    if depth > calcMaxExpressionDepth { return nil }
    calcSkipWhitespace(cursor, &index, end, &state)

    guard let a = calcParseSum(cursor, &index, end, depth, &state) else { return nil }
    calcSkipWhitespace(cursor, &index, end, &state)

    if index == end {
        // `validateType<AllowedTypes::Number>`, not `Op::input`: `round(1.5px)` is invalid.
        guard a.type.matchesNumber else { return nil }
        let type = a.type
        return CalcParsed(node: state.operation(alternative, only: a.node, type), type: type)
    }

    guard calcParseComma(cursor, &index, end, &state) else { return nil }
    guard let b = calcParseSum(cursor, &index, end, depth, &state) else { return nil }
    calcSkipWhitespace(cursor, &index, end, &state)

    guard let merged = a.type.consistentType(with: b.type) else { return nil }
    var children = state.takeBuffer(2)
    children.append(a.node)
    children.append(b.node)
    return CalcParsed(node: calcParseOperation(alternative, children, merged), type: merged)
}

/// `consumeOneOrTwoArguments<Op>`: `<calc-sum>, <calc-sum>?`.
private func calcParseOneOrTwoArguments(
    _ cursor: borrowing CalcTokens,
    _ index: inout UInt32,
    _ end: UInt32,
    _ depth: Int32,
    _ state: inout CalcParseState,
    _ alternative: WebCore.CSSCalc.CSSCalcSwiftAlternative
) -> CalcParsed? {
    if depth > calcMaxExpressionDepth { return nil }
    calcSkipWhitespace(cursor, &index, end, &state)

    guard let a = calcParseSum(cursor, &index, end, depth, &state) else { return nil }
    calcSkipWhitespace(cursor, &index, end, &state)
    guard a.type.matchesNumber else { return nil }

    if index == end {
        guard let transformed = CalcType.makeNumber().madeConsistent(with: a.type) else { return nil }
        return CalcParsed(node: state.operation(alternative, only: a.node, transformed), type: transformed)
    }

    guard calcParseComma(cursor, &index, end, &state) else { return nil }
    guard let b = calcParseSum(cursor, &index, end, depth, &state) else { return nil }
    calcSkipWhitespace(cursor, &index, end, &state)
    guard b.type.matchesNumber else { return nil }

    guard let merged = a.type.consistentType(with: b.type),
        let transformed = CalcType.makeNumber().madeConsistent(with: merged)
    else { return nil }
    var children = state.takeBuffer(2)
    children.append(a.node)
    children.append(b.node)
    return CalcParsed(node: calcParseOperation(alternative, children, transformed), type: transformed)
}

/// `consumeExactlyTwoArguments<Op>`: `mod`, `rem`, `atan2`, `pow`.
private func calcParseTwoArguments(
    _ cursor: borrowing CalcTokens,
    _ index: inout UInt32,
    _ end: UInt32,
    _ depth: Int32,
    _ state: inout CalcParseState,
    _ alternative: WebCore.CSSCalc.CSSCalcSwiftAlternative
) -> CalcParsed? {
    if depth > calcMaxExpressionDepth { return nil }
    calcSkipWhitespace(cursor, &index, end, &state)

    guard let a = calcParseSum(cursor, &index, end, depth, &state) else { return nil }
    calcSkipWhitespace(cursor, &index, end, &state)
    if alternative == .Pow && !a.type.matchesNumber { return nil }

    guard calcParseComma(cursor, &index, end, &state) else { return nil }
    guard let b = calcParseSum(cursor, &index, end, depth, &state) else { return nil }
    calcSkipWhitespace(cursor, &index, end, &state)
    if alternative == .Pow && !b.type.matchesNumber { return nil }

    guard let merged = a.type.consistentType(with: b.type) else { return nil }
    let outputType: CalcType
    switch alternative {
    case .Atan2:
        guard let transformed = CalcType.makeAngle().madeConsistent(with: merged) else { return nil }
        outputType = transformed
    case .Mod, .Rem, .Pow:
        outputType = merged
    default:
        // Unreachable through `calcParseFunctionAlternative`'s `.exactlyTwo` case.
        return nil
    }

    var children = state.takeBuffer(2)
    children.append(a.node)
    children.append(b.node)
    return CalcParsed(node: calcParseOperation(alternative, children, outputType), type: outputType)
}

/// `consumeProgress`: `progress( no-clamp? <calc-sum>, <calc-sum>, <calc-sum> )`.
private func calcParseProgress(
    _ cursor: borrowing CalcTokens,
    _ index: inout UInt32,
    _ end: UInt32,
    _ depth: Int32,
    _ state: inout CalcParseState
) -> CalcParsed? {
    if depth > calcMaxExpressionDepth { return nil }
    calcSkipWhitespace(cursor, &index, end, &state)

    var alternative = WebCore.CSSCalc.CSSCalcSwiftAlternative.Progress
    if index < end, cursor.id(calcToken(cursor, &state, index)) == UInt16(WebCore.CSSValueNoClamp.rawValue) {
        index += 1
        calcSkipWhitespace(cursor, &index, end, &state)
        alternative = .ProgressNoClamp
    }

    guard let value = calcParseSum(cursor, &index, end, depth, &state) else { return nil }
    calcSkipWhitespace(cursor, &index, end, &state)
    guard calcParseComma(cursor, &index, end, &state) else { return nil }

    guard let start = calcParseSum(cursor, &index, end, depth, &state) else { return nil }
    calcSkipWhitespace(cursor, &index, end, &state)
    guard calcParseComma(cursor, &index, end, &state) else { return nil }

    guard let finish = calcParseSum(cursor, &index, end, depth, &state) else { return nil }
    calcSkipWhitespace(cursor, &index, end, &state)

    guard let firstMerge = value.type.consistentType(with: start.type),
        let merged = firstMerge.consistentType(with: finish.type),
        let outputType = CalcType.makeNumber().madeConsistent(with: merged)
    else { return nil }

    var children = state.takeBuffer(3)
    children.append(value.node)
    children.append(start.node)
    children.append(finish.node)
    return CalcParsed(node: calcParseOperation(alternative, children, outputType), type: outputType)
}

/// `consumeOneOrMoreArguments<Op>`: `<calc-sum>#` over the whole range it is given.
private func calcParseArgumentList(
    _ cursor: borrowing CalcTokens,
    _ index: inout UInt32,
    _ end: UInt32,
    _ depth: Int32,
    _ state: inout CalcParseState,
    _ alternative: WebCore.CSSCalc.CSSCalcSwiftAlternative
) -> CalcParsed? {
    if depth > calcMaxExpressionDepth { return nil }

    var mergedType = CalcType()
    // Taken after the first argument is parsed, so an argument that collapsed at construction can
    // hand its buffer on.
    var children = UniqueArray<CalcNode>()

    while index < end {
        calcSkipWhitespace(cursor, &index, end, &state)
        if children.count > 0 {
            guard calcParseComma(cursor, &index, end, &state) else { return nil }
        }

        guard let argument = calcParseSum(cursor, &index, end, depth, &state) else { return nil }

        if children.count == 0 {
            children = state.takeOperandBuffer()
            mergedType = argument.type
        } else {
            guard let merged = mergedType.consistentType(with: argument.type) else { return nil }
            mergedType = merged
        }
        children.append(argument.node)
    }

    // `min()` is invalid input.
    if children.count == 0 { return nil }
    var operation = calcParseOperation(alternative, children, mergedType)
    calcFoldAtConstruction(&operation, &state)
    return CalcParsed(node: operation, type: mergedType)
}

// MARK: Parsing `calc-mix()`

/// One `calc-mix()` item weight: `MetaConsumer<CalcMix::Item::Weight>::consume`.
///
/// A `<percentage>` token is decided here; a math function is resolved by the C++ consumer into
/// the payload table (`CalcNodeFlags.calcMixWeightIsCalc`).
@inline(never)
private func calcParseCalcMixWeight(
    _ cursor: borrowing CalcTokens,
    _ index: inout UInt32,
    _ end: UInt32,
    _ state: inout CalcParseState
) -> CalcParsedCalcMixWeight? {
    let token = calcToken(cursor, &state, index)
    guard token.type == WebCore.PercentageToken else {
        // A function is the only other token `MetaConsumer` accepts as a weight. It is validated
        // and resolved in one call, so a weight the C++ rejects fails the whole `calc-mix()`.
        guard token.type == WebCore.FunctionToken else { return nil }
        let parsed = cursor.consumeCalcMixWeightAt(index)
        guard parsed.consumed else { return nil }
        index = parsed.nextIndex
        calcSkipWhitespace(cursor, &index, end, &state)
        return CalcParsedCalcMixWeight(value: 0, payload: parsed.payloadIndex)
    }
    let value = token.numericValue
    guard value >= 0, value <= 100 else { return nil }
    index += 1
    calcSkipWhitespace(cursor, &index, end, &state)
    return CalcParsedCalcMixWeight(value: value, payload: calcNoPayload)
}

/// One parsed `calc-mix()` item weight: a `<percentage>`, or the payload-table index of a math
/// function weight.
private struct CalcParsedCalcMixWeight {
    let value: Double
    /// `calcNoPayload` for a `<percentage>`.
    let payload: UInt32
}

/// `consumeCalcMix`: `calc-mix( [ <calc-sum> <percentage [0,100]>? ]# )`.
private func calcParseCalcMix(
    _ cursor: borrowing CalcTokens,
    _ index: inout UInt32,
    _ end: UInt32,
    _ depth: Int32,
    _ state: inout CalcParseState
) -> CalcParsed? {
    if depth > calcMaxExpressionDepth { return nil }
    if !state.options.calcMixEnabled { return nil }

    var mergedType = CalcType()
    var itemCount: UInt32 = 0
    // Interleaved: value, weight carrier, value, weight carrier, ...
    var children = UniqueArray<CalcNode>()

    while index < end {
        calcSkipWhitespace(cursor, &index, end, &state)
        if itemCount > 0 {
            guard calcParseComma(cursor, &index, end, &state) else { return nil }
        }

        guard let value = calcParseSum(cursor, &index, end, depth, &state) else { return nil }
        if itemCount == 0 {
            mergedType = value.type
        } else {
            guard let merged = mergedType.consistentType(with: value.type) else { return nil }
            mergedType = merged
        }
        children.append(value.node)

        var weightValue = 0.0
        var weightFlags: UInt16 = 0
        var weightPayload = calcNoPayload
        if index < end, calcToken(cursor, &state, index).type != WebCore.CommaToken {
            guard let weight = calcParseCalcMixWeight(cursor, &index, end, &state) else { return nil }
            weightValue = weight.value
            weightFlags = CalcNodeFlags.calcMixWeightPresent
            if weight.payload != calcNoPayload {
                weightFlags |= CalcNodeFlags.calcMixWeightIsCalc
                weightPayload = weight.payload
            }
        }
        guard
            let weightNode = calcParseLeaf(
                .Percentage,
                weightValue,
                UInt16(WebCore.CSSUnitType.Percentage.rawValue),
                0,
                weightFlags,
                weightPayload
            )
        else { return nil }
        children.append(weightNode)
        // `&+=`: bounded by the token count, since each item consumes at least one token.
        itemCount &+= 1
    }

    // `calc-mix()` is invalid input.
    if itemCount == 0 { return nil }
    return CalcParsed(node: calcParseOperation(.CalcMix, children, mergedType), type: mergedType)
}

// MARK: Parsing `anchor()` and `anchor-size()`

/// `consumeUnresolvedDashedIdent`, resolved into the payload table and answered as its index.
///
/// Only C++ can see a token's text, so the `CSS::CustomIdent` is resolved here.
@inline(always)
private func calcParseDashedIdent(
    _ cursor: borrowing CalcTokens,
    _ index: inout UInt32,
    _ end: UInt32,
    _ state: inout CalcParseState
) -> UInt32? {
    guard index < end else { return nil }
    guard calcToken(cursor, &state, index).type == WebCore.IdentToken else { return nil }
    // The resolver checks the `--` prefix and returns `calcNoPayload` for an ident without it,
    // which is invalid input.
    let payload = cursor.resolveDashedIdentAt(index)
    guard payload != calcNoPayload else { return nil }
    index += 1
    calcSkipWhitespace(cursor, &index, end, &state)
    return payload
}

/// `consumeIdentRaw` over a keyword test: the id of the accepted `IdentToken`, consumed, or
/// `CSSValueInvalid` with the index unchanged.
@inline(always)
private func calcParseAnchorKeyword(
    _ cursor: borrowing CalcTokens,
    _ index: inout UInt32,
    _ end: UInt32,
    _ state: inout CalcParseState,
    _ accepts: (UInt16) -> Bool
) -> UInt16 {
    guard index < end else { return 0 }
    let token = calcToken(cursor, &state, index)
    guard token.type == WebCore.IdentToken, cursor.id(token) != 0, accepts(cursor.id(token)) else { return 0 }
    index += 1
    calcSkipWhitespace(cursor, &index, end, &state)
    return cursor.id(token)
}

/// Whether `id` is one of the keywords of `<anchor-side>`.
@inline(always)
private func calcIsAnchorSideKeyword(_ id: UInt16) -> Bool {
    switch id {
    case WebCore.CSSValueInside.rawValue, WebCore.CSSValueOutside.rawValue,
        WebCore.CSSValueTop.rawValue, WebCore.CSSValueLeft.rawValue,
        WebCore.CSSValueRight.rawValue, WebCore.CSSValueBottom.rawValue,
        WebCore.CSSValueStart.rawValue, WebCore.CSSValueEnd.rawValue,
        WebCore.CSSValueSelfStart.rawValue, WebCore.CSSValueSelfEnd.rawValue,
        WebCore.CSSValueCenter.rawValue:
        return true
    default:
        return false
    }
}

/// `<anchor-size> = width | height | block | inline | self-block | self-inline`.
@inline(always)
private func calcIsAnchorSizeKeyword(_ id: UInt16) -> Bool {
    switch id {
    case WebCore.CSSValueWidth.rawValue, WebCore.CSSValueHeight.rawValue,
        WebCore.CSSValueBlock.rawValue, WebCore.CSSValueInline.rawValue,
        WebCore.CSSValueSelfBlock.rawValue, WebCore.CSSValueSelfInline.rawValue:
        return true
    default:
        return false
    }
}

/// One parsed anchor slot: the subtree's root, and whether the author wrote a math function there.
private struct CalcParsedAnchorSlot: ~Copyable {
    var node: CalcNode
    var type: CalcType
    let wasFunction: Bool
}

/// `consumeValueWithoutSimplifyingRootCalc`.
@inline(always)
private func calcParseAnchorSlotValue(
    _ cursor: borrowing CalcTokens,
    _ index: inout UInt32,
    _ end: UInt32,
    _ depth: Int32,
    _ state: inout CalcParseState
) -> CalcParsedAnchorSlot? {
    guard index < end else { return nil }
    let token = calcToken(cursor, &state, index)
    // A bare parenthesised group is not a legal anchor slot.
    if token.type == WebCore.LeftParenthesisToken { return nil }
    let wasFunction = cursor.functionId(token) != 0
    guard let value = calcParseValue(cursor, &index, end, depth, &state) else { return nil }
    let type = value.type
    return CalcParsedAnchorSlot(node: value.node, type: type, wasFunction: wasFunction)
}

/// `consumeAnchorFallback`: the `<length-percentage>` an `anchor()` or `anchor-size()` falls back
/// to, plus the unitless-zero case.
///
/// It consumes the token before it can fail, as `parseCalcValue` does; `calcParseAnchorSize`
/// depends on that.
///
/// A unitless zero becomes a canonical `0px` length, in place. The test is on the `Number`
/// alternative (`std::get_if<Number>`), not the type: `calc(0)` has number type but is rejected.
@inline(always)
private func calcParseAnchorFallback(
    _ cursor: borrowing CalcTokens,
    _ index: inout UInt32,
    _ end: UInt32,
    _ depth: Int32,
    _ state: inout CalcParseState
) -> CalcParsedAnchorSlot? {
    guard var slot = calcParseAnchorSlotValue(cursor, &index, end, depth, &state) else {
        return nil
    }
    switch slot.type.anchorSlotCategory {
    case .length, .lengthPercentage:
        return slot

    case .number:
        guard state.options.unitlessZeroLengthAllowed else { return nil }
        guard !slot.wasFunction, slot.node.alternative == .Number, slot.node.value == 0 else {
            return nil
        }
        slot.node.value = 0
        slot.node.unitType = UInt8(WebCore.CSSUnitType.Px.rawValue)
        slot.node.alternative = .CanonicalDimension
        slot.node.percentHint = 0
        slot.type = CalcType.makeLength()
        return slot

    case .percentage, .other:
        return nil
    }
}

/// `consumeAnchor`: `anchor( <anchor-element>? && <anchor-side>, <length-percentage>? )`.
private func calcParseAnchor(
    _ cursor: borrowing CalcTokens,
    _ index: inout UInt32,
    _ end: UInt32,
    _ depth: Int32,
    _ state: inout CalcParseState
) -> CalcParsed? {
    if depth > calcMaxExpressionDepth { return nil }
    if !state.options.anchorAllowed { return nil }
    // Refused rather than invalid: with conversion data the C++ evaluates the anchor, which needs
    // a `CSSCalc::Child`.
    if state.conversionDataFoldsRun {
        state.declined = true
        state.declineReason = .AnchorEvaluation
        return nil
    }

    calcSkipWhitespace(cursor, &index, end, &state)
    var elementName = calcParseDashedIdent(cursor, &index, end, &state)

    let sideKeyword = calcParseAnchorKeyword(cursor, &index, end, &state, calcIsAnchorSideKeyword)
    var side: CalcParsedAnchorSlot? = nil
    if sideKeyword == 0 {
        guard let parsed = calcParseAnchorSide(cursor, &index, end, depth, &state) else {
            return nil
        }
        side = consume parsed
    }

    if elementName == nil {
        elementName = calcParseDashedIdent(cursor, &index, end, &state)
    }

    var type = CalcType.makeLength()
    var flags: UInt16 = 0
    // The side subtree first, when there is one, then the fallback.
    var children = UniqueArray<CalcNode>(capacity: 2)
    if let parsedSide = side.take() {
        flags |= CalcNodeFlags.anchorSideIsSubtree
        if parsedSide.wasFunction {
            flags |= CalcNodeFlags.anchorSideWasFunction
        }
        children.append(parsedSide.node)
    }

    if calcParseComma(cursor, &index, end, &state) {
        guard let fallback = calcParseAnchorFallback(cursor, &index, end, depth, &state) else {
            return nil
        }
        if fallback.wasFunction {
            flags |= CalcNodeFlags.anchorFallbackWasFunction
        }
        if fallback.type.anchorSlotCategory == .lengthPercentage {
            type.percentHint = CalcType.PercentHintValue(.Length)
        }
        children.append(fallback.node)
    }

    state.requiresConversionData = true
    return CalcParsed(
        node: calcParseOperation(
            .Anchor,
            children,
            type,
            flags,
            sideKeyword,
            elementName ?? calcNoPayload
        ),
        type: type
    )
}

/// An `<anchor-side>` subtree, parsed with the options `consumeAnchor` gives it.
///
///   * `category` is `CSS::Category::Percentage`, so a `<percentage>` leaf takes no percent hint.
///   * `propertyOptions` is `{ }`, which forbids `anchor()` and `anchor-size()`, so
///     `anchor(--a anchor(top))` is invalid.
///   * `allowedSymbols` is `{ }`, so no ident resolves as a symbol.
@inline(never)
private func calcParseAnchorSide(
    _ cursor: borrowing CalcTokens,
    _ index: inout UInt32,
    _ end: UInt32,
    _ depth: Int32,
    _ state: inout CalcParseState
) -> CalcParsedAnchorSlot? {
    let saved = state.options
    let savedFold = state.foldAtConstruction
    state.options.percentageLeafHint = 0
    state.options.anchorAllowed = false
    state.options.anchorSizeAllowed = false
    state.options.hasAllowedSymbols = false
    state.foldAtConstruction = false
    let parsed = calcParseAnchorSlotValue(cursor, &index, end, depth, &state)
    state.options = saved
    state.foldAtConstruction = savedFold

    guard var slot = consume parsed, slot.type.anchorSlotCategory == .percentage else { return nil }

    state.hasAnchorSide = true
    calcMarkInsideAnchorSide(&slot.node)
    return slot
}

/// `consumeAnchorSize`: `anchor-size( [ <anchor-element> || <anchor-size> ]? , <length-percentage>?
/// )`.
///
/// With neither an element nor a size, the C++ calls `consumeAnchorFallback` and does not check the
/// result. The fallback consumes the token before it fails, so `anchor-size(bogus)` parses as
/// `anchor-size()` and `anchor-size(bogus bogus)` does not. This matches the C++ rather than the
/// spec, so that validity does not depend on `WK_USE_SWIFT_CSS`.
///
/// FIXME: the C++ should reject a junk token here. Fixing it means dropping the unchecked call
/// below and rejecting a failed fallback when neither an element nor a size was present.
private func calcParseAnchorSize(
    _ cursor: borrowing CalcTokens,
    _ index: inout UInt32,
    _ end: UInt32,
    _ depth: Int32,
    _ state: inout CalcParseState
) -> CalcParsed? {
    if depth > calcMaxExpressionDepth { return nil }
    if !state.options.anchorSizeAllowed { return nil }
    if state.conversionDataFoldsRun {
        state.declined = true
        state.declineReason = .AnchorEvaluation
        return nil
    }

    calcSkipWhitespace(cursor, &index, end, &state)
    var elementName = calcParseDashedIdent(cursor, &index, end, &state)
    let sizeKeyword = calcParseAnchorKeyword(cursor, &index, end, &state, calcIsAnchorSizeKeyword)
    if sizeKeyword != 0, elementName == nil {
        elementName = calcParseDashedIdent(cursor, &index, end, &state)
    }

    var children = UniqueArray<CalcNode>(capacity: 1)
    var flags: UInt16 = 0
    var type = CalcType.makeLength()
    var fallback: CalcParsedAnchorSlot? = nil
    if sizeKeyword != 0 || elementName != nil {
        if calcParseComma(cursor, &index, end, &state) {
            guard let parsed = calcParseAnchorFallback(cursor, &index, end, depth, &state) else {
                return nil
            }
            fallback = consume parsed
        }
    } else {
        fallback = calcParseAnchorFallback(cursor, &index, end, depth, &state)
    }

    if let parsed = fallback.take() {
        if parsed.wasFunction {
            flags |= CalcNodeFlags.anchorFallbackWasFunction
        }
        if parsed.type.anchorSlotCategory == .lengthPercentage {
            type.percentHint = CalcType.PercentHintValue(.Length)
        }
        children.append(parsed.node)
    }

    state.requiresConversionData = true
    return CalcParsed(
        node: calcParseOperation(
            .AnchorSize,
            children,
            type,
            flags,
            sizeKeyword,
            elementName ?? calcNoPayload
        ),
        type: type
    )
}

// MARK: Parsing `random()`

/// `consumeRandom`: `random( <random-key>? , <calc-sum>, <calc-sum>, <calc-sum>? )`.
///
/// `Random::Sharing` holds text a `CalcToken` does not read, so `cursor.consumeRandomKey` resolves
/// the `<random-key>` in C++ into the payload table and `origin` holds the index.
///
/// `cssRandomFunctionCount` must be read and incremented in source order, before the arguments, so
/// a nested `random()` sees the incremented value. `consumeRandomKey` does both at that point in
/// the descent; nothing about the count is stored on the node. `cssCalcParseSwift` restores the
/// count across a retried descent and across every refusal.
///
/// `randomAllowed` clear is invalid input, as for every other context condition here.
private func calcParseRandom(
    _ cursor: borrowing CalcTokens,
    _ index: inout UInt32,
    _ end: UInt32,
    _ depth: Int32,
    _ state: inout CalcParseState
) -> CalcParsed? {
    if depth > calcMaxExpressionDepth { return nil }
    if !state.options.randomAllowed { return nil }
    // Refused rather than invalid, as in `calcParseAnchor`: with conversion data
    // `simplify(Random&)` evaluates the node through a `CSSCalc::Child`.
    if state.conversionDataFoldsRun {
        state.declined = true
        state.declineReason = .RandomEvaluation
        return nil
    }

    calcSkipWhitespace(cursor, &index, end, &state)

    // The `<random-key>` and its comma. An omitted key means `auto`.
    let key = cursor.consumeRandomKey(index)
    guard key.consumed else { return nil }
    index = key.nextIndex
    calcSkipWhitespace(cursor, &index, end, &state)

    guard let minimum = calcParseSum(cursor, &index, end, depth, &state) else { return nil }
    calcSkipWhitespace(cursor, &index, end, &state)
    guard calcParseComma(cursor, &index, end, &state) else { return nil }

    guard let maximum = calcParseSum(cursor, &index, end, depth, &state) else { return nil }
    calcSkipWhitespace(cursor, &index, end, &state)

    // `Op::input` is `AllowedTypes::Any` and `Op::output` is `OutputTransform::None`. `Op::merge`
    // is `MergePolicy::Same`, not `Consistent`.
    var stepNode: CalcNode? = nil
    var mergedType: CalcType
    if index >= end {
        guard let merged = minimum.type.sameType(as: maximum.type) else { return nil }
        mergedType = merged
    } else {
        guard calcParseComma(cursor, &index, end, &state) else { return nil }
        guard let step = calcParseSum(cursor, &index, end, depth, &state) else { return nil }
        calcSkipWhitespace(cursor, &index, end, &state)
        // Checked here as well as in `calcParseFunctionBlock`, because this condition selects the
        // form: `random(1px, 2px, 3px, 4px)` is invalid.
        if index != end { return nil }
        // In the C++'s order: min with max, then that with step.
        guard let first = minimum.type.sameType(as: maximum.type),
            let merged = first.sameType(as: step.type)
        else { return nil }
        mergedType = merged
        let stepParsed = consume step
        stepNode = .some(stepParsed.node)
    }

    var children = UniqueArray<CalcNode>(capacity: 3)
    children.append(minimum.node)
    children.append(maximum.node)
    if let step = stepNode.take() {
        children.append(step)
    }
    state.requiresConversionData = true

    return CalcParsed(
        node: calcParseOperation(
            .Random,
            children,
            mergedType,
            0,
            0,
            key.payloadIndex
        ),
        type: mergedType
    )
}

/// Parses a `<calc-product>`.
///
/// `<calc-product> = <calc-value> [ [ '*' | '/' ] <calc-value> ]*`
private func calcParseProduct(
    _ cursor: borrowing CalcTokens,
    _ index: inout UInt32,
    _ end: UInt32,
    _ depth: Int32,
    _ state: inout CalcParseState
) -> CalcParsed? {
    if depth > calcMaxExpressionDepth { return nil }

    guard let parsedFirst = calcParseValue(cursor, &index, end, depth, &state) else { return nil }
    var productType = parsedFirst.type

    // A product of one operand is not a node, so the first operand is held until a second arrives.
    var first: CalcParsed? = parsedFirst
    var second: CalcNode? = nil
    var holdingSecond = false
    var children = UniqueArray<CalcNode>()

    while index < end {
        let token = calcToken(cursor, &state, index)
        let op = token.type == WebCore.DelimiterToken ? token.delimiter : 0
        if op != 0x2A && op != 0x2F { break } // '*' and '/'
        index += 1
        calcSkipWhitespace(cursor, &index, end, &state)

        guard let next = calcParseValue(cursor, &index, end, depth, &state) else { return nil }

        let nextType = next.type
        var operandType = nextType
        var operand = next.node
        if op == 0x2F {
            operandType = nextType.inverted()
            operand = calcParseInvert(operand, operandType, state)
        }

        guard let merged = productType.multiplied(by: operandType) else { return nil }
        productType = merged

        // The second operand is held too, so a product of two leaves can fold without a buffer
        // (`calcFoldLeafProduct`).
        if first != nil && !holdingSecond {
            second = .some(consume operand)
            holdingSecond = true
            continue
        }
        if let head = first.take() {
            children = state.takeOperandBuffer()
            children.append(head.node)
            if let pending = second.take() {
                children.append(pending)
            }
        }
        children.append(operand)
    }

    if let single = first.take() {
        guard var pending = second.take() else { return single }
        var head = single.node
        if state.foldAtConstruction, calcFoldLeafProduct(&head, &pending) {
            return CalcParsed(node: head, type: productType)
        }
        children = state.takeOperandBuffer()
        children.append(head)
        children.append(pending)
    }
    var product = calcParseOperation(.Product, children, productType)
    calcFoldAtConstruction(&product, &state)
    return CalcParsed(node: product, type: productType)
}

/// `foldProduct` over `Product { a, b }` of two `Number`, `Percentage` or `CanonicalDimension`
/// leaves, in place on `a`.
///
/// The two shapes the spec's step 9.2 finishes:
///
/// - two numbers: `b * a`, as a number leaf;
/// - a number and a percentage or dimension: the other leaf, its value `other * number`.
///
/// Anything else answers false with both untouched.
@inline(always)
private func calcFoldLeafProduct(_ a: inout CalcNode, _ b: inout CalcNode) -> Bool {
    switch (a.alternative, b.alternative) {
    case (.Number, .Number):
        a.setLeaf(NumericLeaf.number(b.value * a.value))
        return true
    case (.Number, .Percentage), (.Number, .CanonicalDimension):
        let scaled = b.value * a.value
        swap(&a, &b)
        a.value = scaled
        return true
    case (.Percentage, .Number), (.CanonicalDimension, .Number):
        a.value = a.value * b.value
        return true
    default:
        return false
    }
}

/// Parses a `<calc-sum>`.
///
/// `<calc-sum> = <calc-product> [ [ '+' | '-' ] <calc-product> ]*`
private func calcParseSum(
    _ cursor: borrowing CalcTokens,
    _ index: inout UInt32,
    _ end: UInt32,
    _ depth: Int32,
    _ state: inout CalcParseState
) -> CalcParsed? {
    if depth > calcMaxExpressionDepth { return nil }

    guard let parsedFirst = calcParseProduct(cursor, &index, end, depth, &state) else { return nil }
    var sumType = parsedFirst.type

    var first: CalcParsed? = parsedFirst
    var children = UniqueArray<CalcNode>()

    while index < end {
        let token = calcToken(cursor, &state, index)
        let op = token.type == WebCore.DelimiterToken ? token.delimiter : 0
        if op != 0x2B && op != 0x2D { break } // '+' and '-'

        // `calc(1px+ 2px)` is invalid: the operator must be preceded by whitespace, which is why
        // whitespace tokens stay in the cursor.
        if index == 0 { return nil }
        if !calcTokenIsWhitespace(calcToken(cursor, &state, index - 1).type) { return nil }

        index += 1
        // `calc(1px +2px)` is invalid: the operator must be followed by whitespace.
        if index >= end || !calcTokenIsWhitespace(calcToken(cursor, &state, index).type) { return nil }
        calcSkipWhitespace(cursor, &index, end, &state)

        guard let next = calcParseProduct(cursor, &index, end, depth, &state) else { return nil }

        let nextType = next.type
        var operand = next.node
        if op == 0x2D {
            operand = calcParseNegate(operand, nextType, state)
        }

        guard let merged = sumType.added(to: nextType) else { return nil }
        sumType = merged

        // Step 8.2's merge into the first instance, made before a buffer exists. See
        // `calcSumMergesIntoHead`.
        if state.foldAtConstruction, first != nil, calcSumMergesIntoHead(first!.node, operand) {
            first!.node.value = CalcExecutor.sum(first!.node.value, operand.value)
            continue
        }

        if let head = first.take() {
            children = state.takeOperandBuffer()
            children.append(head.node)
        }
        children.append(operand)
    }

    if let single = first.take() { return CalcParsed(node: single.node, type: sumType) }
    var sum = calcParseOperation(.Sum, children, sumType)
    calcFoldAtConstruction(&sum, &state)
    return CalcParsed(node: sum, type: sumType)
}

/// Whether `foldSum` would merge `operand` into `head` if they were children 0 and 1 of a `Sum`:
/// both are `Number`, `Percentage` or `CanonicalDimension` leaves with the same `mergeKey`.
///
/// Merging before the `Sum` exists gives the node `simplifyParsed` would give, whatever follows:
/// `foldSum` accumulates the head's bucket into the head left to right, and `size` and `merges`
/// both drop by one, so neither `size - merges` nor `size - (merges + removableBuckets)` moves. A
/// `NonCanonicalDimension` is not merged, because the pass may canonicalize it first.
@inline(always)
private func calcSumMergesIntoHead(_ head: borrowing CalcNode, _ operand: borrowing CalcNode) -> Bool {
    switch head.alternative {
    case .Number, .Percentage, .CanonicalDimension: break
    default: return false
    }
    switch operand.alternative {
    case .Number, .Percentage, .CanonicalDimension: break
    default: return false
    }
    guard let headLeaf = head.numericLeaf, let operandLeaf = operand.numericLeaf else {
        return false
    }
    return mergeKey(headLeaf) == mergeKey(operandLeaf)
}

/// What one attempt at the whole parse produced.
private struct CalcParseAttempt: ~Copyable {
    /// Nil when the descent failed or refused; the flags say which.
    var type: CalcType?
    /// The simplified tree, when `type` is not nil.
    var root: CalcNode? = nil
    /// A fold refused the tree (`CalcFold.declined`), as `simplifyParsedCalcMix` and
    /// `calcMixFoldToZero` can.
    var foldRefused = false
    /// How many tokens the descent consumed, for `CalcParseOptions.bareCalcSum`, whose C++ caller
    /// advances its range by exactly this.
    ///
    /// Meaningless unless `type` is non-nil.
    var consumedTokens: UInt32 = 0
}

/// Parse the token range inside a `calc()` and simplify it.
///
/// The root means nothing unless `outcome` is `Parsed`.
@_expose(Cxx)
public func cssCalcParseSwift(
    _ cursor: WebCore.CSSCalc.CSSCalcSwiftParseCursor,
    _ builder: inout WebCore.CSSCalc.CSSCalcSwiftBuilder,
    _ options: WebCore.CSSCalc.CSSCalcSwiftParseOptions,
    _ simplificationOptions: WebCore.CSSCalc.CSSCalcSwiftSimplificationOptions,
    _ simplify: Bool,
    _ outcome: inout WebCore.CSSCalc.CSSCalcSwiftParseResult
) -> CSSCalcSwiftRoot {
    // Named `outcome`, not `result`: the generated C++ thunk names its return buffer `result`, and
    // a parameter of that name is shadowed by it.
    outcome = WebCore.CSSCalc.CSSCalcSwiftParseResult()
    let parseOptions = CalcParseOptions(options)
    var state = CalcParseState(parseOptions)

    // `consumeRandomKey` advances `PropertyParserState::cssRandomFunctionCount`, which keys each
    // `random()` draw, so a descent that produces no tree puts the count back.
    let savedRandomCount = cursor.randomFunctionCount()

    var attempt = withCalcTokens(cursor) { tokens in
        calcParseAttempt(tokens, &builder, simplificationOptions, simplify, &state)
    }

    guard let type = attempt.type else {
        cursor.setRandomFunctionCount(savedRandomCount)

        if attempt.foldRefused {
            outcome.outcome = UInt8(WebCore.CSSCalc.CSSCalcSwiftParseOutcome.Declined.rawValue)
            outcome.declineReason = UInt8(WebCore.CSSCalc.CSSCalcSwiftParseDeclineReason.None.rawValue)
            return .none
        }
        outcome.outcome = UInt8(
            state.declined
                ? WebCore.CSSCalc.CSSCalcSwiftParseOutcome.Declined.rawValue
                : WebCore.CSSCalc.CSSCalcSwiftParseOutcome.Failed.rawValue
        )
        outcome.declineReason = UInt8(state.declineReason.rawValue)
        return .none
    }

    outcome.type = type
    outcome.outcome = UInt8(WebCore.CSSCalc.CSSCalcSwiftParseOutcome.Parsed.rawValue)
    outcome.requiresConversionData = state.requiresConversionData
    outcome.consumedTokens = attempt.consumedTokens
    guard let root = attempt.root.take() else {
        outcome.outcome = UInt8(WebCore.CSSCalc.CSSCalcSwiftParseOutcome.Declined.rawValue)
        outcome.declineReason = UInt8(WebCore.CSSCalc.CSSCalcSwiftParseDeclineReason.ContractViolation.rawValue)
        return .none
    }
    return CSSCalcSwiftRoot(root)
}

/// One attempt at parse and simplify.
@inline(never)
private func calcParseAttempt(
    _ cursor: borrowing CalcTokens,
    _ builder: inout WebCore.CSSCalc.CSSCalcSwiftBuilder,
    _ simplificationOptions: WebCore.CSSCalc.CSSCalcSwiftSimplificationOptions,
    _ simplify: Bool,
    _ state: inout CalcParseState
) -> CalcParseAttempt {
    let end = cursor.tokenCount()
    // An unsimplified parse makes no fold at all.
    state.conversionDataFoldsRun = simplify && simplificationOptions.hasConversionData
    state.foldAtConstruction = simplify
    state.simplification = CalcSimplification(
        percentageResolveToDimension: simplificationOptions.percentageResolveToDimension,
        allowZeroValueLengthRemovalFromSum: simplificationOptions.allowZeroValueLengthRemovalFromSum,
        category: simplificationOptions.category,
        hasConversionData: simplificationOptions.hasConversionData
    )
    var attempt = CalcParseAttempt()
    var index: UInt32 = 0
    // Not for the bare `<calc-sum>` entry: `parseCalcSum` skips no leading whitespace. For
    // `parseAndSimplify`, `consumeFunction` already has, so this is a no-op.
    if !state.options.bareCalcSum {
        calcSkipWhitespace(cursor, &index, end, &state)
    }

    // The top-level function, at depth 0 as in `parseCalcFunction(tokens, function, 0, state)`.
    let descent: CalcParsed?
    if state.options.bareCalcSum {
        // `parseAndSimplifyCalcSum`: `parseCalcSum(tokens, 0, state)`. `rootFunctionId` is
        // `CSSValueInvalid`.
        descent = calcParseSum(cursor, &index, end, 0, &state)
    } else if let rootFunction = calcParseFunctionAlternative(state.options.rootFunctionId) {
        switch rootFunction.arguments {
        case .oneOrMore:
            descent = calcParseArgumentList(cursor, &index, end, 0, &state, rootFunction.alternative)
        case .exactlyOne:
            descent = calcParseUnaryFunction(cursor, &index, end, 0, &state, rootFunction.alternative)
        case .clamp:
            descent = calcParseClamp(cursor, &index, end, 0, &state)
        case .oneOrTwo:
            descent = calcParseOneOrTwoArguments(cursor, &index, end, 0, &state, rootFunction.alternative)
        case .round:
            descent = calcParseRound(cursor, &index, end, 0, &state)
        case .exactlyTwo:
            descent = calcParseTwoArguments(cursor, &index, end, 0, &state, rootFunction.alternative)
        case .progress:
            descent = calcParseProgress(cursor, &index, end, 0, &state)
        case .zeroArguments:
            descent = calcParseZeroArguments(cursor, &index, end, &state, rootFunction.alternative)
        case .calcMix:
            descent = calcParseCalcMix(cursor, &index, end, 0, &state)
        case .anchor:
            descent = calcParseAnchor(cursor, &index, end, 0, &state)
        case .anchorSize:
            descent = calcParseAnchorSize(cursor, &index, end, 0, &state)
        case .random:
            descent = calcParseRandom(cursor, &index, end, 0, &state)
        }
    } else if state.options.rootFunctionId == UInt16(WebCore.CSSValueCalc.rawValue)
        || state.options.rootFunctionId == UInt16(WebCore.CSSValueWebkitCalc.rawValue)
    {
        descent = calcParseSum(cursor, &index, end, 0, &state)
    } else {
        // A top-level math function this grammar does not handle. The range is the function's
        // arguments, so parsing it as a `<calc-sum>` would be wrong.
        state.declined = true
        state.declineReason = calcParseDeclineReasonForFunction(state.options.rootFunctionId)
        descent = nil
    }

    guard var parsed = consume descent else {
        return attempt
    }

    // `parseCalcFunction` requires the inner range to be exhausted.
    //
    // The bare `<calc-sum>` entry does not: `<calc-sum>` stops at `calc-size()`'s top-level comma,
    // which its caller consumes. It reports how many tokens were consumed, and skips no trailing
    // whitespace, because `parseCalcSum` leaves its range at the same place.
    if state.options.bareCalcSum {
        attempt.consumedTokens = index
    } else {
        calcSkipWhitespace(cursor, &index, end, &state)
        if index != end {
            return attempt
        }
        attempt.consumedTokens = end
    }

    if simplify {
        let simplification = CalcSimplification(
            percentageResolveToDimension: simplificationOptions.percentageResolveToDimension,
            allowZeroValueLengthRemovalFromSum: simplificationOptions.allowZeroValueLengthRemovalFromSum,
            category: simplificationOptions.category,
            hasConversionData: simplificationOptions.hasConversionData
        )
        // A fold that refuses outright and one that sets `declined` mid-pass are both
        // `foldRefused`.
        var fold = CalcFold(options: simplification, builder: builder)
        guard fold.simplifyParsed(&parsed.node, state.hasAnchorSide), !fold.declined else {
            attempt.foldRefused = true
            return attempt
        }
    }

    calcRestoreAnchorPrefixes(&parsed.node)
    attempt.type = parsed.type
    attempt.root = consume parsed.node
    return attempt
}

// MARK: - Evaluation

/// `evaluateDouble` (`CSSCalcTree+Evaluation.cpp`), over the stored tree.
///
/// Nothing is built and nothing is allocated, except for the style-coupled functions, whose upcall
/// is asked about the node built as a `Child` (`resolveStyleCoupled`).
///
/// A nil answer is an evaluation to nothing, where `evaluateDouble` has none. A node
/// `isSimplifiableAlternative` refuses (an arity no parse produces) sets `refused`, and the whole
/// evaluation is handed back unevaluated (see `cssCalcEvaluateSwift`).
private struct CalcEvaluation: ~Copyable {
    let units: CalcSimplification
    /// Mutable only for `resolveStyleCoupled`, which builds a node on the operand stack.
    var builder: WebCore.CSSCalc.CSSCalcSwiftBuilder
    /// The alternative where a nil started, not an ancestor it was passed up through.
    var blame: CalcAlternative? = nil
    /// The walk reached a node it does not handle.
    var refused = false

    init(units: CalcSimplification, builder: WebCore.CSSCalc.CSSCalcSwiftBuilder) {
        self.units = units
        self.builder = builder
    }

    /// `resolveStyleCoupledValue` for `node`, which the upcall reads as a `Child`.
    mutating func resolveStyleCoupled(_ node: borrowing CalcNode) -> WebCore.CSSCalc.CSSCalcSwiftNumericResult {
        guard calcEmitParsed(node, false, &builder) else {
            return WebCore.CSSCalc.CSSCalcSwiftNumericResult(
                value: 0,
                unitType: 0,
                resolved: false,
                alternative: node.alternative,
                substituteFallback: false
            )
        }
        return builder.resolveStyleCoupledValueOfTop()
    }

    @inline(always)
    mutating func fail(_ alternative: CalcAlternative) -> Double? {
        if blame == nil {
            blame = alternative
        }
        return nil
    }

    @inline(always)
    mutating func child(_ node: borrowing CalcNode, _ k: Int) -> Double? {
        evaluateNode(node[k])
    }

    /// `evaluate(node)`, for a node whose `info` has not been asked for.
    @inline(always)
    mutating func evaluateNode(_ node: borrowing CalcNode) -> Double? {
        evaluate(node, node.info)
    }

    /// `evaluate(node[k])` with its blame discarded: a present but unresolvable optional argument
    /// is read as omitted, so it must not be the node a later nil is attributed to.
    @inline(always)
    mutating func swallowedChild(_ node: borrowing CalcNode, _ k: Int) -> Double? {
        let saved = blame
        blame = nil
        let value = child(node, k)
        blame = saved
        return value
    }

    /// `EvaluatedItem`: an item's value, and its weight or nil where the weight was omitted.
    typealias CalcMixEvaluatedItem = (value: Double, weight: Double?)

    /// The `Vector<EvaluatedItem, 8>` of `evaluate(const IndirectNode<CalcMix>&)`.
    ///
    /// Up to eight items are in an `InlineArray` (SE-0453), more in an `Array`, both handed to the
    /// body as a `MutableSpan`.
    ///
    /// Out of line, so the inline storage is not in every frame of the recursive `evaluate`. Item
    /// `k` is child `k`; its weight comes from the upcall that applies the evaluator's
    /// `Style::toStyle`.
    @inline(never)
    mutating func evaluateCalcMix(_ node: borrowing CalcNode, _ itemCount: Int) -> Double? {
        if itemCount <= 8 {
            var items = InlineArray<8, CalcMixEvaluatedItem>(repeating: (value: 0, weight: nil))
            var span = items.mutableSpan
            return evaluateCalcMixItems(node, itemCount, &span)
        }
        var items = [CalcMixEvaluatedItem](repeating: (value: 0, weight: nil), count: itemCount)
        var span = items.mutableSpan
        return evaluateCalcMixItems(node, itemCount, &span)
    }

    /// The body of `evaluateCalcMix`, over `items`, which has room for at least `itemCount` items.
    mutating func evaluateCalcMixItems(
        _ node: borrowing CalcNode,
        _ itemCount: Int,
        _ items: inout MutableSpan<CalcMixEvaluatedItem>
    ) -> Double? {
        // Value then weight, one item at a time, stopping at the first value that answers nothing,
        // as the C++ does: converting a `Calc` weight can have side effects. Each weight is
        // converted once.
        var total = 0.0
        var numberOfOmittedWeights = 0
        for k in 0..<itemCount {
            guard let value = child(node, k) else {
                return nil
            }
            let stored = node.calcMixWeight(k)
            let weight = builder.resolveCalcMixWeight(stored.value, stored.present, node.calcMixWeightPayload(k))
            guard weight.resolved else {
                return fail(.CalcMix)
            }
            if weight.substituteFallback {
                items[k] = (value: value, weight: nil)
                numberOfOmittedWeights += 1
            } else {
                items[k] = (value: value, weight: weight.value)
                total += weight.value
            }
        }
        // `std::min(total, 100.0)` is `100.0 < total ? 100.0 : total`, which keeps a NaN `total`
        // where `Swift.min` would not.
        let cappedTotal = 100.0 < total ? 100.0 : total
        let weightForOmitted = numberOfOmittedWeights > 0 ? (100.0 - cappedTotal) / Double(numberOfOmittedWeights) : 0.0
        let normalizationFactor = total > 100.0 ? (100.0 / total) : 1.0
        // `OperatorExecutor<Operator::CalcMix>`: a running sum from `+0` of
        // `value * (percentage / 100)`, in item order.
        var result = 0.0
        for k in 0..<itemCount {
            let item = items[k]
            let percentage = (item.weight ?? weightForOmitted) * normalizationFactor
            result += item.value * (percentage / 100)
        }
        return result
    }

    /// The value of `node`, whose `info` is `info`, or nil if this walk does not evaluate it.
    mutating func evaluate(_ node: borrowing CalcNode, _ info: CalcNodeInfo) -> Double? {
        let alternative = info.alternative
        let count = Int(info.childCount)
        guard isSimplifiableAlternative(alternative, info.childCount) else {
            refused = true
            return fail(alternative)
        }

        switch alternative {
        // `evaluate(const Number&)`, `evaluate(const Percentage&)` and
        // `evaluate(const CanonicalDimension&)`: the stored value, unconditionally.
        case .Number, .Percentage, .CanonicalDimension:
            return info.numericValue

        // `evaluate(const NonCanonicalDimension&)`: `canonicalize` against the conversion data, or
        // nothing if it does not canonicalize.
        case .NonCanonicalDimension:
            let canonical = units.canonicalizedDimension(info.numericValue, UInt16(info.unitType), builder)
            guard canonical.kind != .nonCanonicalDimension else {
                return fail(.NonCanonicalDimension)
            }
            return canonical.value

        // `executeVariadicMathOperationAfterUnwrapping`: any child that answers nothing makes the
        // operation answer nothing.
        case .Sum:
            // From `+0`, as `OperatorExecutor<Operator::Sum>`, so a sum of only `-0` is `+0`.
            var sum: Double = 0
            var k = 0
            while k < count {
                guard let value = child(node, k) else {
                    return nil
                }
                sum += value
                k += 1
            }
            return sum

        case .Product:
            // Left to right from `1`, as `OperatorExecutor<Operator::Product>`, not numbers first
            // as `simplify(Product&)`; the two can differ in the last bit.
            var product: Double = 1
            var k = 0
            while k < count {
                guard let value = child(node, k) else {
                    return nil
                }
                product *= value
                k += 1
            }
            return product

        case .Min, .Max:
            // `OperatorExecutor<Operator::Min>` and `<Operator::Max>`: a signed-zero fold that
            // stops at the first NaN. Every operand is still evaluated, because a later one
            // answering nothing makes the whole thing answer nothing.
            let isMin = alternative == .Min
            var result: Double? = nil
            var sawNaN = false
            var k = 0
            while k < count {
                guard let value = child(node, k) else {
                    return nil
                }
                if let current = result {
                    if !sawNaN {
                        if value.isNaN {
                            result = value
                            sawNaN = true
                        } else {
                            result = isMin ? CalcExecutor.minWithSignedZero(current, value) : CalcExecutor.maxWithSignedZero(current, value)
                        }
                    }
                } else {
                    result = value
                }
                k += 1
            }
            // An empty range is NaN in the C++; a parsed `min()` always has an operand.
            return result ?? Double.nan

        case .Hypot:
            // `OperatorExecutor<Operator::Hypot>`: one operand is its magnitude, none is NaN.
            var sumOfSquares: Double = 0
            var only: Double = 0
            var k = 0
            while k < count {
                guard let value = child(node, k) else {
                    return nil
                }
                sumOfSquares += value * value
                only = value
                k += 1
            }
            switch count {
            case 0:
                return Double.nan
            case 1:
                return CalcExecutor.abs(only)
            default:
                return CalcExecutor.sqrt(sumOfSquares)
            }

        // `isSimplifiableAlternative` has already required exactly one child.
        case .Negate:
            return child(node, 0).map { -$0 }
        case .Invert:
            return child(node, 0).map { CalcExecutor.invert($0) }
        case .Deg2Rad:
            return child(node, 0).map { CalcExecutor.degreesToRadians($0) }
        // The operand is a number, or a `Deg2Rad` over an angle, so it is already in radians.
        case .Sin:
            return child(node, 0).map { CalcExecutor.sin($0) }
        case .Cos:
            return child(node, 0).map { CalcExecutor.cos($0) }
        case .Tan:
            return child(node, 0).map { CalcExecutor.tan($0) }
        // The inverse functions answer in degrees, as their executors do.
        case .Asin:
            return child(node, 0).map { CalcExecutor.asin($0) }
        case .Acos:
            return child(node, 0).map { CalcExecutor.acos($0) }
        case .Atan:
            return child(node, 0).map { CalcExecutor.atan($0) }
        case .Sqrt:
            return child(node, 0).map { CalcExecutor.sqrt($0) }
        case .Exp:
            return child(node, 0).map { CalcExecutor.exp($0) }
        case .Abs:
            return child(node, 0).map { CalcExecutor.abs($0) }
        case .Sign:
            return child(node, 0).map { CalcExecutor.sign($0) }

        // Both operands are evaluated before either is tested, as the C++ builds its argument pack.
        case .Atan2, .Pow, .Mod, .Rem:
            let x = child(node, 0)
            let y = child(node, 1)
            guard let x, let y else {
                return nil
            }
            switch alternative {
            case .Atan2: return CalcExecutor.atan2(x, y)
            case .Pow: return CalcExecutor.pow(x, y)
            case .Mod: return CalcExecutor.mod(x, y)
            default: return CalcExecutor.rem(x, y)
            }

        case .Progress, .ProgressNoClamp:
            let x = child(node, 0)
            let y = child(node, 1)
            let z = child(node, 2)
            guard let x, let y, let z else {
                return nil
            }
            return alternative == .Progress ? CalcExecutor.progress(x, y, z) : CalcExecutor.progressNoClamp(x, y, z)

        // `round()` and `log()`: the second argument is present when `childCount` is 2.
        //
        // FIXME: `evaluateDouble` reads a second argument that is present but answers nothing as
        // omitted, because `executeMathOperationAfterUnwrapping` tests only the outer optional:
        // `round(100px, 1rem)` without conversion data rounds to 1. This reproduces it so the two
        // evaluators agree; fix both together.
        case .RoundNearest, .RoundUp, .RoundDown, .RoundToZero, .Log:
            let x = child(node, 0)
            let second: Double? = count == 2 ? swallowedChild(node, 1) : nil
            guard let x else {
                return nil
            }
            switch alternative {
            case .RoundNearest: return CalcExecutor.roundNearest(x, second ?? 1.0)
            case .RoundUp: return CalcExecutor.roundUp(x, second ?? 1.0)
            case .RoundDown: return CalcExecutor.roundDown(x, second ?? 1.0)
            case .RoundToZero: return CalcExecutor.roundToZero(x, second ?? 1.0)
            default:
                if let second {
                    return CalcExecutor.log(x, second)
                }
                return CalcExecutor.log(x)
            }

        // `evaluate(const SiblingCount&)` and `evaluate(const SiblingIndex&)`, through the upcall
        // the simplifier makes, with the evaluator's guards in its order.
        case .SiblingCount, .SiblingIndex:
            let resolved = resolveStyleCoupled(node)
            guard resolved.resolved else {
                return fail(alternative)
            }
            return resolved.value

        // `evaluate(const IndirectNode<CalcMix>&)`. `isSimplifiableAlternative` requires an item.
        case .CalcMix:
            return evaluateCalcMix(node, count)

        // `evaluate(const Symbol&)`: the symbol table's value with the node's unit, through
        // `makeNumeric`, evaluated as the numeric leaf that builds. A miss answers nothing, as the
        // C++ does after its `ASSERT_NOT_REACHED`.
        case .Symbol:
            let resolved = builder.resolveSymbol(info.valueID, UInt16(info.unitType))
            guard resolved.resolved else {
                return fail(alternative)
            }
            switch resolved.alternative {
            case .Number, .Percentage, .CanonicalDimension:
                return resolved.value
            case .NonCanonicalDimension:
                let canonical = units.canonicalizedDimension(resolved.value, resolved.unitType, builder)
                guard canonical.kind != .nonCanonicalDimension else {
                    return fail(.NonCanonicalDimension)
                }
                return canonical.value
            default:
                return fail(alternative)
            }

        // `evaluate(const IndirectNode<Random>&)`, in its order: the guard, min, max, step, then
        // the base value, whose lookup inserts into the random cache. A step that answers nothing
        // is read as omitted, as for `round()`.
        case .Random:
            guard builder.hasStyleBuilderState() else {
                return fail(alternative)
            }
            guard let minimum = child(node, 0) else {
                return nil
            }
            guard let maximum = child(node, 1) else {
                return nil
            }
            let step: Double? = count == 3 ? swallowedChild(node, 2) : nil
            let base = builder.resolveRandomBaseValueForEvaluation(node.origin)
            guard base.resolved else {
                return fail(alternative)
            }
            return CalcExecutor.random(base.value, minimum, maximum, step)

        // `evaluate(const IndirectNode<Anchor>&)` and `<AnchorSize>`, through the simplifier's
        // upcall, which answers the value, nothing, or asks for the fallback (having marked the
        // property invalid if there is none). A fallback that answers nothing marks it invalid, in
        // the C++'s order. An `<anchor-side>` subtree is child 0; the fallback follows it.
        case .Anchor, .AnchorSize:
            let answer = resolveStyleCoupled(node)
            if answer.resolved {
                return answer.value
            }
            guard answer.substituteFallback else {
                return fail(alternative)
            }
            let fallbackIndex = alternative == .Anchor && info.anchorSideIsSubtree ? 1 : 0
            guard count > fallbackIndex else {
                return fail(alternative)
            }
            if let fallback = child(node, fallbackIndex) {
                return fallback
            }
            builder.markCurrentPropertyInvalidAtComputedValueTime()
            return nil

        // `evaluate(const IndirectNode<Clamp>&)` and `OperatorExecutor<Operator::Clamp>`. A `none`
        // bound is not a child, and the kind says which are missing. A bound that answers nothing
        // fails the whole `clamp()`. All three are evaluated before any is tested.
        case .Clamp:
            let minimumIsNone = info.kind == .clampWithNoneMinimum || info.kind == .clampWithNoneMinimumAndMaximum
            let maximumIsNone = info.kind == .clampWithNoneMaximum || info.kind == .clampWithNoneMinimumAndMaximum
            let expected = 3 - (minimumIsNone ? 1 : 0) - (maximumIsNone ? 1 : 0)
            guard count == expected else {
                return fail(alternative)
            }
            var next = 0
            var minimum: Double? = nil
            var maximum: Double? = nil
            var failed = false
            if !minimumIsNone {
                next += 1
                minimum = child(node, 0)
                failed = failed || minimum == nil
            }
            let valueSlot = next
            next += 1
            let value = child(node, valueSlot)
            failed = failed || value == nil
            if !maximumIsNone {
                maximum = child(node, next)
                failed = failed || maximum == nil
            }
            guard !failed, let value else {
                return nil
            }
            // `clamp(none, VAL, none)` is `VAL`; `clamp(none, VAL, MAX)` is the two-operand
            // `min()`; `clamp(MIN, VAL, none)` is the two-operand `max()`, operands in that order.
            switch (minimum, maximum) {
            case (nil, nil):
                return value
            case (nil, let maximum?):
                return CalcExecutor.min(value, maximum)
            case (let minimum?, nil):
                return CalcExecutor.max(minimum, value)
            case (let minimum?, let maximum?):
                return CalcExecutor.clamp(minimum, value, maximum)
            }

        default:
            refused = true
            return fail(alternative)
        }
    }
}

/// Evaluate a tree to a `double`.
///
/// When `resolved` is false, `alternative` names the node the walk stopped at, and
/// `substituteFallback` says why: set, the tree was refused unevaluated; clear, it evaluated to
/// nothing, as `evaluateDouble` would.
@_expose(Cxx)
public func cssCalcEvaluateSwift(
    _ stored: CSSCalcSwiftRoot,
    _ builder: inout WebCore.CSSCalc.CSSCalcSwiftBuilder,
    _ hasConversionData: Bool
) -> WebCore.CSSCalc.CSSCalcSwiftNumericResult {
    // `canonicalizedDimension` reads only `hasConversionData`.
    let units = CalcSimplification(
        percentageResolveToDimension: false,
        allowZeroValueLengthRemovalFromSum: false,
        category: 0,
        hasConversionData: hasConversionData
    )

    let box = stored
    let rootInfo = box.root.info
    var evaluation = CalcEvaluation(units: units, builder: builder)
    let value = evaluation.evaluate(box.root, rootInfo)

    // A refused tree names the root. A tree that evaluates to nothing, where
    // `evaluateDouble` answers nothing, answers that, naming the node the walk stopped at.
    if evaluation.refused {
        return WebCore.CSSCalc.CSSCalcSwiftNumericResult(
            value: 0,
            unitType: 0,
            resolved: false,
            alternative: rootInfo.alternative,
            substituteFallback: true
        )
    }
    guard let answer = value else {
        return WebCore.CSSCalc.CSSCalcSwiftNumericResult(
            value: 0,
            unitType: 0,
            resolved: false,
            alternative: evaluation.blame ?? rootInfo.alternative,
            substituteFallback: false
        )
    }
    return WebCore.CSSCalc.CSSCalcSwiftNumericResult(
        value: answer,
        unitType: 0,
        resolved: true,
        alternative: .Number,
        substituteFallback: false
    )
}

// MARK: - Conversion to `Style::Calculation::Tree`

/// `toStyle(const CSSCalc::Child&)` (StyleCalculationTree+Conversion.cpp), over the simplified
/// tree, onto the operand stack of `builder`.
///
/// False only for a builder contract violation.
///
/// The order is the C++'s, because two steps read caches with side effects: a `random()`'s base
/// value is resolved before its arguments, and each `calc-mix()` item's weight before its value.
private func calcToStyle(
    _ node: borrowing CalcNode,
    _ builder: inout WebCore.CSSCalc.CSSCalcSwiftStyleBuilder
) -> Bool {
    let info = node.info
    let count = Int(info.childCount)
    let alternative = info.alternative
    switch alternative {
    case .Number:
        builder.pushNumber(info.numericValue)
        return true
    case .Percentage:
        builder.pushPercentage(info.numericValue)
        return true
    case .CanonicalDimension:
        builder.pushCanonicalDimension(info.numericValue, UInt16(info.unitType))
        return true
    case .Symbol where info.valueID == UInt16(WebCore.CSSValueSize.rawValue):
        builder.pushSize()
        return true

    // Resolved by simplification with conversion data, so never present here. The C++ asserts and
    // answers the number 0 without converting any argument.
    case .NonCanonicalDimension, .Symbol, .SiblingCount, .SiblingIndex, .Anchor, .AnchorSize:
        builder.pushNumber(0)
        return true

    // The style tree has no `Deg2Rad` node.
    case .Deg2Rad:
        guard count == 1, calcToStyle(node[0], &builder) else {
            return false
        }
        builder.pushNumber(Double.pi / 180.0)
        return builder.buildOperation(.Product, 2, 0)
    case .Random:
        builder.pushRandomBaseValue(node.origin)
    case .CalcMix:
        var k = 0
        while k < count {
            let weight = node.calcMixWeight(k)
            builder.pushCalcMixItemWeight(weight.value, weight.present, node.calcMixWeightPayload(k))
            guard calcToStyle(node[k], &builder) else {
                return false
            }
            k += 1
        }
        return builder.buildOperation(alternative, info.childCount, 0)
    default:
        break
    }

    var k = 0
    while k < count {
        guard calcToStyle(node[k], &builder) else {
            return false
        }
        k += 1
    }
    let noneMask: UInt8
    switch info.kind {
    case .clampWithNoneMinimum: noneMask = 1
    case .clampWithNoneMaximum: noneMask = 2
    case .clampWithNoneMinimumAndMaximum: noneMask = 3
    default: noneMask = 0
    }
    return builder.buildOperation(alternative, info.childCount, noneMask)
}

/// Convert a simplified tree to a `Style::Calculation::Tree`, left as the one operand on `builder`.
@_expose(Cxx)
public func cssCalcToStyleSwift(
    _ stored: CSSCalcSwiftRoot,
    _ builder: inout WebCore.CSSCalc.CSSCalcSwiftStyleBuilder
) -> Bool {
    let box = stored
    return calcToStyle(box.root, &builder)
}
