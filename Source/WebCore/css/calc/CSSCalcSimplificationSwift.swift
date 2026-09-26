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

// calc() simplification in Swift, used when WebCore is built with WK_USE_SWIFT_CSS.
//
// Simplification copies the `CSSCalc::Child` tree once into an owned `CalcNode` tree
// (`calcBuildNode`), simplifies it in place by a recursive post-order walk (`CalcFold.simplify`),
// children before their parent and in forward order as `copyAndSimplify` does, and then emits it onto
// the builder's operand stack (`calcEmit`). The operand stack has no pop, so nothing is pushed until
// the whole tree has simplified. A tree that cannot be simplified is refused whole:
// `isSimplifiableAlternative` refuses an arity `rebuildFrom` could not fill, and a fold that cannot
// derive its answer sets `CalcFold.declined`.

/// What simplification did with a tree.
@c
enum CSSCalcSwiftSimplificationOutcome: UInt8 {
    /// The complete simplified tree is on the builder's operand stack.
    case simplified = 0
    /// Nothing usable was built. The caller stops with a `RELEASE_ASSERT`.
    case declined = 1
}

// MARK: - The per-alternative discriminant

// Dispatches on `CSSCalcSwiftAlternative`, the variant's own alternative index, not on
// `CSSCalcSwiftNodeKind`, which classifies by serialization shape and conflates `min()` with `mod()`.

private typealias CalcAlternative = WebCore.CSSCalc.CSSCalcSwiftAlternative

/// `WebCore::CSSCalc::Type`.
///
/// The backticks are required: unescaped, `WebCore.CSSCalc.Type` parses as the metatype of the
/// `WebCore.CSSCalc` namespace enum.
private typealias CalcType = WebCore.CSSCalc.`Type`

/// A switch rather than `kind.rawValue`: nothing ties the two enums' raw values together.
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
private enum NumericKind {
    case number
    case percentage
    case canonicalDimension
    case nonCanonicalDimension
}

/// `Type::PercentHintValue` as the `uint8_t` the boundary carries, 0 for none. Decoded by comparison
/// because `PercentHintValue`'s storage is private.
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

/// The inverse, or `nil` for 0 or an unrecognized value.
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
        // `!(… == …)`, not `!=`: the ClangImporter does not synthesise the negation of a defaulted
        // `operator==`.
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
            kind: leafKindRawValue(kind),
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

/// Whether a node of this alternative with this many children can be simplified.
///
/// The count must match what `rebuildFrom` consumes, or it would fill the wrong slots.
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

/// Simplify a whole tree onto the builder's operand stack, or refuse it.
@_expose(Cxx)
public func cssCalcSimplifySwift(
    _ root: borrowing WebCore.CSSCalc.Child,
    _ builder: inout WebCore.CSSCalc.CSSCalcSwiftBuilder,
    _ options: WebCore.CSSCalc.CSSCalcSwiftSimplificationOptions
) -> WebCore.CSSCalc.CSSCalcSwiftSimplificationResult {
    let rootInfo = WebCore.CSSCalc.swiftNodeInfo(root)

    // A numeric leaf root is never rewritten structurally (`simplify(Number&)` and its two siblings
    // are no-ops, `simplify(NonCanonicalDimension&)` only canonicalizes), so it builds no `CalcNode`.
    if rootInfo.childCount == 0 {
        switch rootInfo.alternative {
        case .Number, .Percentage, .CanonicalDimension, .NonCanonicalDimension:
            return calcSimplifyNumericLeafRoot(rootInfo, options, &builder)
        default:
            break
        }
    }

    return calcSimplifyOwnedTree(root, rootInfo, &builder, options)
}

/// The whole of `cssCalcSimplifySwift` for a root that is a numeric leaf with no children.
@inline(always)
private func calcSimplifyNumericLeafRoot(
    _ info: WebCore.CSSCalc.CSSCalcSwiftNodeInfo,
    _ options: WebCore.CSSCalc.CSSCalcSwiftSimplificationOptions,
    _ builder: inout WebCore.CSSCalc.CSSCalcSwiftBuilder
) -> WebCore.CSSCalc.CSSCalcSwiftSimplificationResult {
    let kind: NumericKind
    switch info.alternative {
    case .Number: kind = .number
    case .Percentage: kind = .percentage
    case .CanonicalDimension: kind = .canonicalDimension
    default: kind = .nonCanonicalDimension
    }
    let leaf = NumericLeaf(
        kind: kind,
        value: info.numericValue,
        unitType: UInt16(info.unitType),
        percentHint: info.percentHint
    )
    return calcSimplifyNumericLeaf(leaf, info.alternative, options, &builder)
}

/// `calcSimplifyNumericLeafRoot` for a leaf already read, from a `Child` or from a stored node.
@inline(always)
private func calcSimplifyNumericLeaf(
    _ arrived: NumericLeaf,
    _ alternative: CalcAlternative,
    _ options: WebCore.CSSCalc.CSSCalcSwiftSimplificationOptions,
    _ builder: inout WebCore.CSSCalc.CSSCalcSwiftBuilder
) -> WebCore.CSSCalc.CSSCalcSwiftSimplificationResult {
    // The same `kindMask` and `nodeCount` that `calcBuildNode` reports for a one-node tree.
    let kindMask = CalcCoverage.bit(alternative)
    var leaf = arrived

    if leaf.kind == .nonCanonicalDimension {
        // `simplifyNonCanonicalDimension` without a tree. The `UInt8` guard mirrors `setLeaf`'s so
        // the two cannot diverge, although `CSSUnitType` is `uint8_t`-backed and it never fires.
        let simplification = CalcSimplification(
            percentageResolveToDimension: options.percentageResolveToDimension,
            allowZeroValueLengthRemovalFromSum: options.allowZeroValueLengthRemovalFromSum,
            category: options.category,
            hasConversionData: options.hasConversionData
        )
        let canonicalized = simplification.canonicalizedDimension(leaf.value, leaf.unitType, builder)
        if canonicalized.kind != .nonCanonicalDimension, UInt8(exactly: canonicalized.unitType) != nil {
            leaf = canonicalized
        }
    }

    // The leaf is the whole tree, so it is constructed straight into the caller's root slot.
    guard builder.pushLeaf(leaf.boundaryLeaf, true) else {
        return declined(kindMask, 1, nil)
    }
    return WebCore.CSSCalc.CSSCalcSwiftSimplificationResult(
        kindMask: kindMask,
        nodeCount: 1,
        outcome: CSSCalcSwiftSimplificationOutcome.simplified.rawValue,
        declineAlternative: noDeclineAlternative
    )
}

/// `CSSCalcSwiftSimplificationResult::declineAlternative` when there is no alternative to blame.
private let noDeclineAlternative: UInt8 = 0xFF

/// A declined result, with the blame filled in.
@inline(always)
private func declined(
    _ kindMask: UInt64,
    _ nodeCount: UInt32,
    _ blame: CalcAlternative?
) -> WebCore.CSSCalc.CSSCalcSwiftSimplificationResult {
    WebCore.CSSCalc.CSSCalcSwiftSimplificationResult(
        kindMask: kindMask,
        nodeCount: nodeCount,
        outcome: CSSCalcSwiftSimplificationOutcome.declined.rawValue,
        declineAlternative: blame.map { $0.rawValue } ?? noDeclineAlternative
    )
}

// MARK: - The second entry point

/// Whether simplifying this tree could change it, as `canSimplifyWithCpp` answers.
@_expose(Cxx)
public func cssCalcCanSimplifySwift(_ root: borrowing WebCore.CSSCalc.Child) -> Bool {
    switch WebCore.CSSCalc.swiftNodeInfo(root).alternative {
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
    _ weight: WebCore.CSSCalc.CSSCalcSwiftCalcMixWeight,
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

/// The "no payload" index, for a parsed node that names no payload and for a weight that is not a
/// math function.
private var calcNoPayload: UInt32 { WebCore.CSSCalc.cssCalcSwiftFlatNoNode }

/// The bits on `CalcNode.flags`.
private enum CalcNodeFlags {
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
    /// keeps its sum. The subtree is still visited, so that an unhandled alternative refuses the tree.
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
    /// folded it with the options `simplifyParsed` uses, so the pass skips its fold.
    ///
    /// This holds because nothing changes a node's children after `calcFoldAtConstruction`
    /// returns it.
    static let foldedAtConstruction: UInt16 = 1 << 8
}

/// Where a pre-order descent over the original tree got to.
private enum CalcOriginDescent<R> {
    /// The target was not in this subtree, which spans this many pre-order indices.
    case passed(UInt32)
    /// The target was reached, and this is what `body` answered about it.
    case reached(R)
}

/// Run `body` on the original node whose pre-order index is `target`, or answer nil if no node has
/// that index.
///
/// A recursive descent because a `CSSCalc::Child` is `~Copyable` and no Swift container can hold
/// one, so the borrow stays on the call stack. It is O(target): each node stepped past costs
/// `Child::childCount()` and `operator[]`, both generic visits over every alternative.
///
/// FIXME: record each node's original subtree size while building, so that the walk can skip a
/// sibling subtree and run in O(depth).
private func withCalcOriginalNode<R>(
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

private func calcDescendToOrigin<R>(
    _ node: borrowing WebCore.CSSCalc.Child,
    _ index: UInt32,
    _ target: UInt32,
    _ body: (borrowing WebCore.CSSCalc.Child) -> R
) -> CalcOriginDescent<R> {
    if index == target {
        return .reached(body(node))
    }

    // Pre-order, the numbering `calcBuildNode` assigns to `origin`.
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
private func calcEmitFromOrigin(
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

/// Emits a `calc-mix()`: recompute the weight plan, push the surviving weights, then `rebuildFrom`.
@inline(never)
private func calcEmitCalcMix(
    _ target: UInt32,
    _ operands: UInt32,
    _ isRoot: Bool,
    _ original: borrowing WebCore.CSSCalc.Child,
    _ builder: inout WebCore.CSSCalc.CSSCalcSwiftBuilder
) -> Bool {
    withCalcOriginalNode(original, target) { node -> Bool in
        let itemCount = UInt32(clamping: node.childCount())

        var survey = CalcMixWeightSurvey()
        var index: UInt32 = 0
        while index < itemCount {
            // Every counter is bounded by `itemCount`, so `&+=` cannot overflow.
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

        // In item order, the order `rebuildSlot(const Vector<CalcMix::Item>&)` pairs weights with
        // operands. The operands are already on the stack, and nested `calc-mix()`es have consumed
        // their own weights.
        var pushed: UInt32 = 0
        index = 0
        while index < itemCount {
            let plan = calcMixItemPlan(WebCore.CSSCalc.swiftCalcMixItemWeight(node, index), survey)
            if plan.survives {
                _ = builder.pushCalcMixItemWeight(
                    index,
                    plan.weight,
                    plan.replaceWeight,
                    calcNoPayload
                )
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

/// Everything `calcBuildNode` reports about the tree it walked, which is returned to C++.
private struct CalcBuildReport {
    /// Every node in the whole tree, including any past the point where writing stopped.
    var nodeCount: UInt32 = 0
    /// One bit per `CSSCalcSwiftAlternative` seen, over the whole tree.
    var kindMask: UInt64 = 0
    /// The first unhandled alternative in pre-order.
    var blame: CalcAlternative? = nil
    var everyNodeSimplifiable = true
    /// Whether the tree built so far can still be simplified.
    ///
    /// Once false it stays false, and the walk keeps counting but builds nothing more.
    var writing = true

    @inline(always)
    mutating func sawAlternative(_ alternative: CalcAlternative) {
        kindMask |= UInt64(1) &<< UInt64(alternative.rawValue)
    }

    /// Whether every alternative seen is one this file covers.
    var everyAlternativeCovered: Bool {
        kindMask & ~CalcCoverage.mask == 0
    }

    /// A node this file cannot simplify.
    ///
    /// The first one in pre-order is blamed.
    @inline(always)
    mutating func sawUnsimplifiableNode(_ alternative: CalcAlternative) {
        if blame == nil {
            blame = alternative
        }
        everyNodeSimplifiable = false
        writing = false
    }
}

// MARK: - The owned tree

/// One node of the calc tree the Swift simplifier works on, owning its children.
///
/// `~Copyable` because a copy would be a deep copy of the subtree; a node moves into its parent's
/// `children` and out again. `origin` is the node's pre-order index in the original
/// `CSSCalc::Child` tree, which `withCalcOriginalNode` descends to; on a parsed node it indexes the
/// payload table instead.
private struct CalcNode: ~Copyable {
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
                kind: WebCore.CSSCalc.CSSCalcSwiftNodeKind.Symbol.rawValue,
                percentHint: 0,
                valueID: valueID
            )
        case .SiblingCount:
            return WebCore.CSSCalc.CSSCalcSwiftLeaf(
                value: 0,
                unitType: 0,
                kind: WebCore.CSSCalc.CSSCalcSwiftNodeKind.SiblingCount.rawValue,
                percentHint: 0,
                valueID: 0
            )
        case .SiblingIndex:
            return WebCore.CSSCalc.CSSCalcSwiftLeaf(
                value: 0,
                unitType: 0,
                kind: WebCore.CSSCalc.CSSCalcSwiftNodeKind.SiblingIndex.rawValue,
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
    init(options: CalcSimplification, builder: WebCore.CSSCalc.CSSCalcSwiftBuilder?, keepsBuffers: Bool = false) {
        self.options = options
        self.builder = builder
        self.keepsBuffers = keepsBuffers
    }

    let options: CalcSimplification
    let builder: WebCore.CSSCalc.CSSCalcSwiftBuilder?
    /// Whether `foldSum` and `foldProduct` leave a collapsed node's buffer on its leaf.
    ///
    /// Set only by `calcFoldAtConstruction`, which reuses it; a kept tree must not carry empty
    /// buffers.
    var keepsBuffers = false
    /// A fold discovered mid-pass that it cannot finish, so the whole tree is refused.
    ///
    /// Whole-tree rather than per-node because the operand stack has no pop, and leaving the node as
    /// it arrived would be a silently wrong computed value.
    var declined = false
}

// MARK: The owned tree's producer

/// Build the subtree of `node` as a `CalcNode`.
///
/// `origin` is the node's pre-order index in the tree of `node`, which is `report.nodeCount`
/// before this node is counted.
@inline(always)
private func calcBuildNode(
    _ node: borrowing WebCore.CSSCalc.Child,
    _ info: WebCore.CSSCalc.CSSCalcSwiftNodeInfo,
    _ inheritedFlags: UInt16,
    _ report: inout CalcBuildReport
) -> CalcNode {
    let me = report.nodeCount
    report.nodeCount &+= 1
    report.sawAlternative(info.alternative)
    if !isSimplifiableAlternative(info.alternative, info.childCount) {
        report.sawUnsimplifiableNode(info.alternative)
    }

    if info.childCount == 0 {
        switch info.alternative {
        case .Number, .Percentage, .CanonicalDimension, .NonCanonicalDimension,
            .Symbol, .SiblingCount, .SiblingIndex:
            return CalcNode(
                value: info.numericValue,
                type: CalcType(),
                origin: me,
                valueID: info.valueID,
                unitType: info.unitType,
                alternative: info.alternative,
                percentHint: info.percentHint,
                flags: inheritedFlags & CalcNodeFlags.insideAnchorSide,
                children: UniqueArray()
            )
        default:
            break
        }
    }
    return calcBuildSubtree(node, info, inheritedFlags, me, &report)
}

/// `calcBuildNode` for a child reached through `Child::operator[]`, which has to ask for `info`.
@inline(always)
private func calcBuildChild(
    _ node: borrowing WebCore.CSSCalc.Child,
    _ inheritedFlags: UInt16,
    _ report: inout CalcBuildReport
) -> CalcNode {
    calcBuildNode(node, WebCore.CSSCalc.swiftNodeInfo(node), inheritedFlags, &report)
}

/// Only `insideAnchorSide` is inherited.
///
/// The other flags describe the node itself: an inherited `anchorSideIsSubtree` would mark
/// child 0 of every node under an `anchor()` as a side.
@inline(never)
private func calcBuildSubtree(
    _ node: borrowing WebCore.CSSCalc.Child,
    _ info: WebCore.CSSCalc.CSSCalcSwiftNodeInfo,
    _ inheritedFlags: UInt16,
    _ me: UInt32,
    _ report: inout CalcBuildReport
) -> CalcNode {
    var flags = inheritedFlags & CalcNodeFlags.insideAnchorSide
    switch info.kind {
    case .ClampWithNoneMinimum: flags |= CalcNodeFlags.clampNoneMinimum
    case .ClampWithNoneMaximum: flags |= CalcNodeFlags.clampNoneMaximum
    case .ClampWithNoneMinimumAndMaximum: flags |= CalcNodeFlags.clampNoneMask
    default: break
    }
    if info.anchorSideIsSubtree {
        flags |= CalcNodeFlags.anchorSideIsSubtree
    }

    let carriesType: Bool
    switch info.alternative {
    case .Number, .Percentage, .CanonicalDimension, .NonCanonicalDimension,
        .Symbol, .SiblingCount, .SiblingIndex:
        carriesType = false
    default:
        carriesType = true
    }
    // A tree that will be refused needs only the count and the mask.
    let type = carriesType && report.writing ? WebCore.CSSCalc.getType(node) : CalcType()

    var children = UniqueArray<CalcNode>(capacity: Int(info.childCount))
    var index: UInt32 = 0
    while index < info.childCount {
        let sideRoot = (flags & CalcNodeFlags.anchorSideIsSubtree) != 0 && index == 0
        children.append(
            calcBuildChild(
                node[Int(index)],
                sideRoot ? flags | CalcNodeFlags.insideAnchorSide : flags,
                &report
            )
        )
        index += 1
    }
    return CalcNode(
        value: info.numericValue,
        type: type,
        origin: me,
        valueID: info.valueID,
        unitType: info.unitType,
        alternative: info.alternative,
        percentHint: info.percentHint,
        flags: flags,
        children: children
    )
}

// MARK: The owned tree's simplifier

/// `copyAndSimplify` over a tree built from `original`: children first, in order, then the node.
extension CalcFold {
    fileprivate mutating func simplify(_ node: inout CalcNode, _ original: borrowing WebCore.CSSCalc.Child) {
        // `copyAndSimplify` copies an `anchor()`'s `<anchor-side>` (child 0) without simplifying it.
        var k = node.flags & CalcNodeFlags.anchorSideIsSubtree != 0 ? 1 : 0
        while k < node.children.count {
            simplify(&node.children[k], original)
            k &+= 1
        }
        simplifyNode(&node, original)
    }

    @inline(always)
    fileprivate mutating func simplifyNode(_ node: inout CalcNode, _ original: borrowing WebCore.CSSCalc.Child) {
        switch node.alternative {
        case .Negate: calcFoldNegate(&node)
        case .Invert: calcFoldInvert(&node)
        case .Sum: foldSum(&node)
        case .Product: foldProduct(&node)
        case .Min: foldMinMax(&node, false)
        case .Max: foldMinMax(&node, true)
        case .NonCanonicalDimension: foldNonCanonicalDimension(&node)
        case .Number, .Percentage, .CanonicalDimension: return
        default: simplifyColdNode(&node, original)
        }
    }

    @inline(never)
    fileprivate mutating func simplifyColdNode(_ node: inout CalcNode, _ original: borrowing WebCore.CSSCalc.Child) {
        switch node.alternative {
        case .CalcMix: foldCalcMix(&node, original)
        case .Symbol: foldSymbol(&node)
        case .SiblingCount, .SiblingIndex: foldSiblingFunction(&node, original)
        case .Anchor, .AnchorSize: foldAnchorFunction(&node, original)
        case .Random: foldRandom(&node, original)
        default: foldFunction(&node)
        }
    }

    /// The folds that read only the node and its children.
    ///
    /// False for any other alternative.
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
    /// FIXME: `convertToMin` in the C++ moves `root.val` and `root.max` out before testing `toType`,
    /// so on failure `copyAndSimplify` rebuilds the `Clamp` from moved-from children. Nothing is
    /// moved here.
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

// MARK: The folds that read the builder or the original tree

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

    /// An unresolved value is not a refusal: the C++ returns `{ }` and the leaf stays in the tree.
    fileprivate mutating func foldSiblingFunction(_ node: inout CalcNode, _ original: borrowing WebCore.CSSCalc.Child) {
        guard let builder else {
            return
        }
        guard let resolved = withCalcOriginalNode(original, node.origin, { builder.resolveStyleCoupledValue($0) }) else {
            declined = true
            return
        }
        guard resolved.resolved else {
            return
        }
        node.setLeaf(NumericLeaf.number(resolved.value))
    }

    /// The node folds to the resolved value, stays as it is, or, with `substituteFallback`, becomes
    /// its fallback child.
    fileprivate mutating func foldAnchorFunction(_ node: inout CalcNode, _ original: borrowing WebCore.CSSCalc.Child) {
        guard let builder else {
            return
        }
        let sideSlots = node.flags & CalcNodeFlags.anchorSideIsSubtree != 0 ? 1 : 0
        let childCount = node.children.count
        guard childCount == sideSlots || childCount == sideSlots &+ 1 else {
            declined = true
            return
        }
        guard let resolved = withCalcOriginalNode(original, node.origin, { builder.resolveStyleCoupledValue($0) }) else {
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

    /// The `<random-key>` is not a child, so the children are `min`, `max` and the optional `step`.
    ///
    /// As in the C++, `max` and `step` are each checked against `min`, only `min` must be fully
    /// resolved, and the result is shaped like `min`.
    fileprivate mutating func foldRandom(_ node: inout CalcNode, _ original: borrowing WebCore.CSSCalc.Child) {
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
        guard let baseValue = withCalcOriginalNode(original, node.origin, { builder.resolveStyleCoupledValue($0) }) else {
            declined = true
            return
        }
        guard baseValue.resolved else {
            return
        }
        node.setLeaf(minimum.withValue(CalcExecutor.random(baseValue.value, minimum.value, maximum.value, step)))
    }

    /// `simplify(CalcMix&)`: the weight survey, the `!canNormalize` early return that drops only
    /// known-zero items, normalisation, and the weighted sum, which needs every surviving item to be
    /// the same numeric kind and identity.
    ///
    /// `emit` recomputes each item's weight plan rather than reading it off the node. The fold
    /// finishes an inner `calc-mix()` before an outer one while `emit` reaches the inner one first,
    /// so plans pushed during the fold would be consumed by the wrong node. `calcMixItemPlan` is a
    /// pure function of one weight and the survey, so both calls agree.
    ///
    /// A failing sum still keeps the dropped items and normalised weights, as in the C++, so the
    /// survivor pass runs before the accumulator.
    fileprivate mutating func foldCalcMix(_ node: inout CalcNode, _ original: borrowing WebCore.CSSCalc.Child) {
        let itemCount = UInt32(truncatingIfNeeded: node.children.count)
        guard itemCount > 0 else {
            return
        }
        let origin = node.origin

        guard let survey = calcMixSurveyOf(origin, itemCount, original) else {
            declined = true
            return
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

        // Phases 2 and 3: keep the surviving items, in item order.
        var write = 0
        var index: UInt32 = 0
        while write < node.children.count, index < itemCount {
            guard let weight = calcMixWeightOf(origin, index, original) else {
                declined = true
                return
            }
            index += 1
            if calcMixItemPlan(weight, survey).survives {
                write &+= 1
            } else {
                node.dropChild(write)
            }
        }

        guard survey.canNormalize else {
            return
        }

        // Phase 4, the weighted sum, over the survivors. `/ 100.0`, as in the C++, not `* 0.01`.
        var accumulated: NumericLeaf? = nil
        var c = 0
        index = 0
        while c < node.children.count, index < itemCount {
            guard let weight = calcMixWeightOf(origin, index, original) else {
                declined = true
                return
            }
            index += 1
            let plan = calcMixItemPlan(weight, survey)
            guard plan.survives else {
                continue
            }
            let item = c
            c &+= 1
            guard let leaf = node.children[item].numericLeaf else {
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
            return
        }
        node.setLeaf(result)
    }

    /// `zeroValueMatchingChild(children[0])`.
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

/// The weight survey of `simplify(CalcMix&)`, in one descent of the original tree.
private func calcMixSurveyOf(
    _ origin: UInt32,
    _ itemCount: UInt32,
    _ original: borrowing WebCore.CSSCalc.Child
) -> CalcMixWeightSurvey? {
    withCalcOriginalNode(original, origin) { node -> CalcMixWeightSurvey in
        var survey = CalcMixWeightSurvey()
        var index: UInt32 = 0
        while index < itemCount {
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

private func calcMixWeightOf(
    _ origin: UInt32,
    _ index: UInt32,
    _ original: borrowing WebCore.CSSCalc.Child
) -> WebCore.CSSCalc.CSSCalcSwiftCalcMixWeight? {
    withCalcOriginalNode(original, origin) { WebCore.CSSCalc.swiftCalcMixItemWeight($0, index) }
}

// MARK: The owned tree's emit

/// Push the subtree of `node` onto the builder's operand stack.
///
/// False if it cannot be built.
private func calcEmit(
    _ node: borrowing CalcNode,
    _ isRoot: Bool,
    _ original: borrowing WebCore.CSSCalc.Child,
    _ builder: inout WebCore.CSSCalc.CSSCalcSwiftBuilder
) -> Bool {
    switch node.alternative {
    case .Number, .Percentage, .CanonicalDimension, .NonCanonicalDimension:
        guard let leaf = node.numericLeaf else {
            return false
        }
        return builder.pushLeaf(leaf.boundaryLeaf, isRoot)
    case .Symbol, .SiblingCount, .SiblingIndex:
        return calcEmitFromOrigin(node.origin, 0, true, isRoot, original, &builder)
    default:
        break
    }

    // `anchor()`'s `<anchor-side>` subtree is child 0 and is not an operand: `rebuildFrom` copies
    // it off the original.
    var k = node.flags & CalcNodeFlags.anchorSideIsSubtree != 0 ? 1 : 0
    var pushed: UInt32 = 0
    while k < node.children.count {
        guard calcEmit(node.children[k], false, original, &builder) else { return false }
        pushed &+= 1
        k &+= 1
    }

    switch node.alternative {
    case .Sum, .Product, .Negate, .Invert, .Min, .Max:
        break
    case .CalcMix:
        return calcEmitCalcMix(node.origin, pushed, isRoot, original, &builder)
    default:
        return calcEmitFromOrigin(node.origin, pushed, false, isRoot, original, &builder)
    }
    return builder.buildOperation(node.alternative, pushed, node.type, isRoot)
}

// MARK: The owned tree's entry

/// Build, simplify and emit a tree that is not a single numeric leaf.
@inline(always)
private func calcSimplifyOwnedTree(
    _ root: borrowing WebCore.CSSCalc.Child,
    _ rootInfo: WebCore.CSSCalc.CSSCalcSwiftNodeInfo,
    _ builder: inout WebCore.CSSCalc.CSSCalcSwiftBuilder,
    _ options: WebCore.CSSCalc.CSSCalcSwiftSimplificationOptions
) -> WebCore.CSSCalc.CSSCalcSwiftSimplificationResult {
    let simplification = CalcSimplification(
        percentageResolveToDimension: options.percentageResolveToDimension,
        allowZeroValueLengthRemovalFromSum: options.allowZeroValueLengthRemovalFromSum,
        category: options.category,
        hasConversionData: options.hasConversionData
    )

    var report = CalcBuildReport()
    var tree = calcBuildNode(root, rootInfo, 0, &report)
    // A tree holding an alternative with no Swift fold is built only for the count and the mask.
    guard report.writing, report.everyAlternativeCovered else {
        return declined(report.kindMask, report.nodeCount, report.blame)
    }

    var fold = CalcFold(options: simplification, builder: builder)
    fold.simplify(&tree, root)
    guard !fold.declined, calcEmit(tree, true, root, &builder) else {
        // A refusal mid-pass, or a builder contract violation; no single alternative to blame.
        return declined(report.kindMask, report.nodeCount, nil)
    }
    return WebCore.CSSCalc.CSSCalcSwiftSimplificationResult(
        kindMask: report.kindMask,
        nodeCount: report.nodeCount,
        outcome: CSSCalcSwiftSimplificationOutcome.simplified.rawValue,
        declineAlternative: noDeclineAlternative
    )
}
