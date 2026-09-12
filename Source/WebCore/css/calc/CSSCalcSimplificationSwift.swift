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
// treat differently. The boundary carries the variant's own alternative index instead, pinned to
// `Node`'s alternative indices via `WTF::alternativeIndexV`.

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

// MARK: - The `Type` algebra: implementation selection

/// Which implementation answers the css-typed-om `Type` algebra for this file's call sites. Both
/// are compiled in; this chooses which one, at compile time. Same arrangement as
/// `CSSCalc::Simplifier` and `CSSCalc::Serializer`: the C++ stays in tree and stays selectable.
private enum CalcTypeAlgebraArm {
    /// `CSSCalcType.cpp`, reached through the C++ interop boundary.
    case cpp
    /// The bodies below.
    case swift
}

/// The implementation the production call sites take.
private let defaultTypeAlgebra = CalcTypeAlgebraArm.swift

// MARK: - The `Type` algebra in Swift

private extension CalcType {

    /// The C++'s `if (type.percentHint)` -- `PercentHintValue`'s `explicit operator bool`
    /// (`CSSCalcType.h:90`).
    @inline(always)
    var hasPercentHint: Bool {
        // `!(… == …)`, not `!=`: C++20 synthesises the negation of a defaulted `operator==` and
        // the ClangImporter does not.
        return !(percentHint == CalcType.PercentHintValue())
    }

    /// css-typed-om step 2, shared verbatim by "add two types" (`CSSCalcType.cpp:50`-`:60`) and
    /// "multiply two types" (`:124`-`:135`).
    @inline(always)
    static func normalizePercentHints(
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

    /// One lane of `multiply`'s step 4, accumulating the overflow flag rather than branching per
    /// lane, so the seven are a straight run of `adds`/`csinc` rather than seven early exits.
    ///
    /// `addingReportingOverflow` is the exact analogue of the C++'s `checkedSum<int8_t>`
    /// (`CSSCalcType.cpp:142`-`:144`). Not `&+`, which would silently wrap where the C++ refuses,
    /// and not `+`, which would trap where the C++ returns `std::nullopt`.
    @inline(always)
    static func sumExponent(_ a: Int8, _ b: Int8, _ overflowed: inout Bool) -> Int8 {
        let (result, didOverflow) = a.addingReportingOverflow(b)
        overflowed = overflowed || didOverflow
        return result
    }

    /// `Type::multiply` (`CSSCalcType.cpp:110`-`:153`).
    @inline(always)
    func multiplied(by other: CalcType) -> CalcType? {
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
            // overflow." (`CSSCalcType.cpp:141`)
            return nil
        }

        finalType.percentHint = type1.percentHint

        return finalType
    }

    /// `Type::invert` (`CSSCalcType.cpp:155`-`:170`).
    ///
    /// `0 &- exponent`, not `-exponent`, and that is a correctness point rather than a style one.
    /// The C++ is `result[unit] = -1 * type[unit]`: the operand promotes to `int`, multiplies, and
    /// narrows back to `int8_t`, so -128 stays -128 on every target WebKit ships. Swift's unary `-`
    /// on `Int8` traps there, turning a defined C++ answer into an abort.
    ///
    /// -128 is reachable: `multiply` admits any sum that fits in `Int8`, so two `Product`s of
    /// exponent -64 get there, and step 9.4 then inverts the result.
    @inline(always)
    func inverted() -> CalcType {
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

    /// The C++'s `hasNonPercentEntry()` (`CSSCalcType.h:196`-`:199`).
    @inline(always)
    var containsNonPercentEntry: Bool {
        return length != 0 || angle != 0 || time != 0 || frequency != 0 || resolution != 0 || flex != 0
    }

    /// `Type::applyPercentHint` (`CSSCalcType.h:263`-`:277`), as a value-returning form.
    ///
    /// `&+`, not `+`. The C++ is `(*this)[hint] += (*this)[BaseType::Percent]` on an `int8_t`: the
    /// operands promote to `int`, add, and narrow back, so 127 + 127 is -2 on every target WebKit
    /// ships, where Swift's `+` traps. Reachable only with saturated lanes.
    ///
    /// The `default` case is not dead and must alias to `length`. The C++ indexes through
    /// `operator[](PercentHint)` (`CSSCalcType.h:232`-`:245`), whose switch falls out to
    /// `return length` for a value outside the enum --
    /// `ASSERT_NOT_REACHED_UNDER_CONSTEXPR_CONTEXT` is a no-op in a Release build -- and an
    /// imported C++ enum's `init?(rawValue:)` never fails, so an out-of-range hint is
    /// constructible in Swift.
    @inline(always)
    func withPercentHintApplied(_ hint: WebCore.CSSCalc.PercentHint) -> CalcType {
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

    /// `Type::allNonZeroValuesEqual` (`CSSCalcType.h:279`-`:289`), unrolled over the seven lanes.
    @inline(always)
    func nonZeroValuesEqual(_ other: CalcType) -> Bool {
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
    /// entries that finalType doesn't already contain" (`CSSCalcType.cpp:66`-`:71`, `:87`-`:92`).
    @inline(always)
    func mergingAbsentLanes(from other: CalcType) -> CalcType {
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

    /// One iteration of `add`'s provisional-hint loop (`CSSCalcType.cpp:78`-`:99`).
    static func addUnderHint(
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

    /// `Type::add` (`CSSCalcType.cpp:36`-`:107`).
    ///
    /// Deliberate spec deviation, matching the C++ this replaces: do not "fix" it against the
    /// spec. css-typed-om's "apply the percent hint" is three steps; `CSSCalcType.cpp:56`/`:59`
    /// performs only the third (assign the hint; do not fold `percent` into the hinted lane), and
    /// step 3's first branch then compares the un-applied types at `:65`.
    ///
    /// The omission is masked on spec-legal input by the provisional-hint search below, which
    /// re-derives the application step 2 should have made. It is unmasked only by a `Type`
    /// carrying both a non-null hint and a non-zero `percent` lane, a state the spec forbids and
    /// `multiply`'s matching omission produces.
    ///
    /// FIXME: the deviation is web-visible through Typed OM, whose `CSSNumericType::multiplyTypes`
    /// has the same omission. Fixing it there, here and in `normalizePercentHints` is one change.
    func added(to other: CalcType) -> CalcType? {
        var type1 = self
        var type2 = other

        guard CalcType.normalizePercentHints(&type1, &type2) else {
            return nil
        }

        if type1.nonZeroValuesEqual(type2) && type2.nonZeroValuesEqual(type1) {
            return type1.mergingAbsentLanes(from: type2)
        }

        // Step 3, second branch (`:75`-`:103`). The guard is the C++'s own, and keeps the
        // six-hint search off every pair that cannot benefit from it.
        guard (type1.percent != 0 || type2.percent != 0)
            && (type1.containsNonPercentEntry || type2.containsNonPercentEntry) else {
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

    /// `Type::sameType` (`CSSCalcType.cpp:172`-`:177`).
    @inline(always)
    func sameType(as other: CalcType) -> CalcType? {
        return (self == other) ? self : nil
    }

    /// `Type::consistentType` (`CSSCalcType.cpp:180`-`:185`) -- "two or more calculations have a
    /// consistent type if adding the types doesn't result in failure", so it IS `add`.
    @inline(always)
    func consistentType(with other: CalcType) -> CalcType? {
        return added(to: other)
    }

    /// `Type::madeConsistent` (`CSSCalcType.cpp:188`-`:200`). `self` is the C++'s `base`.
    @inline(always)
    func madeConsistent(with input: CalcType) -> CalcType? {
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
    var matchesNumber: Bool {
        return length == 0 && angle == 0 && time == 0 && frequency == 0
            && resolution == 0 && flex == 0 && percent == 0
    }

    /// `matchesAny<Match::Number, Match::Angle>({ .allowsPercentHint = true })`.
    @inline(always)
    var matchesNumberOrAngle: Bool {
        return (angle == 0 || angle == 1) && length == 0 && time == 0 && frequency == 0
            && resolution == 0 && flex == 0 && percent == 0
    }

    /// `matchesAny<Match::Angle>({ .allowsPercentHint = true })`, the `Deg2Rad` condition at
    /// `CSSCalcTree+Parser.cpp:312`.
    @inline(always)
    var matchesAngle: Bool {
        return angle == 1 && length == 0 && time == 0 && frequency == 0
            && resolution == 0 && flex == 0 && percent == 0
    }
}

/// `Type::multiply` through the selected implementation. `@inline(always)` with a constant `arm`
/// folds the switch away, so neither implementation pays for the dispatch.
@inline(always)
private func calcTypeMultiply(
    _ a: CalcType,
    _ b: CalcType,
    _ arm: CalcTypeAlgebraArm = defaultTypeAlgebra
) -> CalcType? {
    switch arm {
    case .cpp:
        return CalcType.multiply(a, b).value
    case .swift:
        return a.multiplied(by: b)
    }
}

/// `Type::invert` through the selected implementation.
@inline(always)
private func calcTypeInvert(
    _ a: CalcType,
    _ arm: CalcTypeAlgebraArm = defaultTypeAlgebra
) -> CalcType {
    switch arm {
    case .cpp:
        return CalcType.invert(a)
    case .swift:
        return a.inverted()
    }
}

/// `Type::add` through the selected implementation.
@inline(always)
private func calcTypeAdd(
    _ a: CalcType,
    _ b: CalcType,
    _ arm: CalcTypeAlgebraArm = defaultTypeAlgebra
) -> CalcType? {
    switch arm {
    case .cpp:
        return CalcType.add(a, b).value
    case .swift:
        return a.added(to: b)
    }
}

/// `Type::consistentType` through the selected implementation.
@inline(always)
private func calcTypeConsistentType(
    _ a: CalcType,
    _ b: CalcType,
    _ arm: CalcTypeAlgebraArm = defaultTypeAlgebra
) -> CalcType? {
    switch arm {
    case .cpp:
        return CalcType.consistentType(a, b).value
    case .swift:
        return a.consistentType(with: b)
    }
}

/// `Type::sameType` through the selected implementation. No caller in this file yet: it exists for
/// `mergeTypes<MergePolicy::Same>`.
@inline(always)
private func calcTypeSameType(
    _ a: CalcType,
    _ b: CalcType,
    _ arm: CalcTypeAlgebraArm = defaultTypeAlgebra
) -> CalcType? {
    switch arm {
    case .cpp:
        return CalcType.sameType(a, b).value
    case .swift:
        return a.sameType(as: b)
    }
}

/// `Type::madeConsistent` through the selected implementation. No caller in this file yet.
@inline(always)
private func calcTypeMadeConsistent(
    _ base: CalcType,
    _ input: CalcType,
    _ arm: CalcTypeAlgebraArm = defaultTypeAlgebra
) -> CalcType? {
    switch arm {
    case .cpp:
        return CalcType.madeConsistent(base, input).value
    case .swift:
        return base.madeConsistent(with: input)
    }
}

/// `Type::applyPercentHint` through the selected implementation, as a value-returning form so both
/// have the same shape. The C++ member is `constexpr` and mutating, so the `cpp` case copies first.
@inline(always)
private func calcTypeApplyPercentHint(
    _ a: CalcType,
    _ hint: WebCore.CSSCalc.PercentHint,
    _ arm: CalcTypeAlgebraArm = defaultTypeAlgebra
) -> CalcType {
    switch arm {
    case .cpp:
        var copy = a
        copy.applyPercentHint(hint)
        return copy
    case .swift:
        return a.withPercentHintApplied(hint)
    }
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
            type = calcTypeApplyPercentHint(type, hint)
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

/// One node of the flat tree.
///
/// Children are named by index, not by pointer, which is what makes the whole structure `Copyable`,
/// storable in an ordinary Swift buffer, and free of the `~Escapable` problem a borrowed handle has.
///
/// Declared in C++, and it has to be. `PrintAsClang` exports even a `@frozen`, `BitwiseCopyable`
/// Swift struct as a non-trivially-copyable, non-default-constructible C++ class routing copies
/// through the value witness table, so a Swift-declared node could not be a `WTF::Vector` element,
/// and the stored flat tree is a `WTF::Vector`. The two C++ producers of a calc tree
/// (`Style::Calculation::toCSS`, `CSSNumericValue::toCalcTreeNode`) also have to construct nodes and
/// cannot name a Swift-only type. There is still exactly one declaration: this is a `typealias`, so
/// a field added on the C++ side appears here with no edit. The size `static_assert` beside it
/// guards an `@_expose(Cxx)` return-struct tail-zeroing bug, and makes a later field addition that
/// re-enters its range a build failure rather than a wrong stylesheet.
///
/// `alternative` is the imported C++ enum rather than a Swift mirror of it, so a `switch` here is
/// checked against the one list (`CSS_CALC_SWIFT_FOR_EACH_ALTERNATIVE`). That only diagnoses a 42nd
/// alternative in the switches that enumerate every case and close with `@unknown default:` --
/// `isSimplifiableAlternative` and `cssCalcCanSimplifySwift`. `isNumericLeaf`, `numericLeaf` and
/// `simplifyNode` close with a bare `default:`, which takes a new alternative silently, so what
/// keeps it from being mis-handled there is the per-tree refusal rather than the compiler.
///
/// The child list is a linked list, `firstChild` plus `nextSibling`, and that is load-bearing.
/// css-values-4 step 8.1 -- splice a nested `Sum`'s terms into its parent -- makes a child run
/// longer than it started, so a side table of contiguous child index runs has to be bump-allocated
/// and can reach O(N^2) slots on a left-nested chain of sums. A linked list splices by relinking:
/// O(1), and no storage beyond the N nodes. That is what lets the whole flat tree be one
/// fixed-size buffer sized from a node count known in advance, and so live on the stack rather than
/// costing a heap allocation per simplification.
///
/// Random access to child `k` is O(k) rather than O(1) as a result. That is the right trade: calc
/// arities are a handful, every hot walk is sequential, and the alternative cost a buffer that
/// could not be stack-allocated.
fileprivate typealias CalcFlatNode = WebCore.CSSCalc.CSSCalcSwiftFlatNode

fileprivate extension CalcFlatNode {
    /// The end-of-list sentinel, and the "no such node" answer.
    static var noNode: UInt32 { WebCore.CSSCalc.cssCalcSwiftFlatNoNode }
}

/// The bits on `CalcFlatNode.flags`.
fileprivate enum CalcFlatNodeFlags {
    /// `clamp()` whose minimum bound is the keyword `none` rather than a subtree.
    static let clampNoneMinimum: UInt8 = 1 << 0
    /// `clamp()`'s maximum bound is the keyword `none`.
    static let clampNoneMaximum: UInt8 = 1 << 1
    /// The two bits `CSSCalcSwiftBuilder::buildOperation`'s `noneMask` parameter is defined over.
    ///
    /// The bit positions are the boundary's, not this enum's private business: `noneMask` bit 0 is
    /// the minimum and bit 1 the maximum, stated in `CSSCalcSwiftTypes.h` on the declaration. They
    /// agree here because the flat node captured them from `CSSCalcSwiftNodeKind` on the reading
    /// side and the grammar sets the same two bits, so nothing translates -- and because nothing
    /// translates, nothing checks.
    static let clampNoneMask: UInt8 = clampNoneMinimum | clampNoneMaximum
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
    // Both bounds are the keyword, which the reading boundary has no kind for: a `clamp()` with two
    // `none`s is the plain `Clamp` kind and `Child::operator[]` skips both, so one child is the
    // whole of what distinguishes it. Setting both bits here rather than leaving the flags clear is
    // what makes the invariant one rule -- `childCount + nones == 3`, checked in `simplifyClamp`
    // and again in `CSSCalcSwiftBuilder::buildOperation` -- instead of a rule with an exception the
    // construction side would have to re-derive in C++.
    case .Operation where info.alternative == .Clamp && info.childCount == 1:
        flags |= CalcFlatNodeFlags.clampNoneMask
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

    /// `simplify` for a tree the GRAMMAR built: the same pass, forwards, with no original.
    ///
    /// TWO DIFFERENCES FROM `simplify` ABOVE AND NO THIRD, both of which fall out of where the tree
    /// came from rather than out of what it contains.
    ///
    /// The loop runs FORWARD. `calcFlatten` writes pre-order, so counting down reaches every child
    /// before its parent; a recursive-descent parser writes post-order, so counting UP does. Nothing
    /// else in the flat representation is order-dependent -- the folds address nodes by index as a
    /// unique key and never compare two of them, which is exactly why the direction is the whole
    /// change (see the note at `CalcParsed`).
    ///
    /// There is no `original`, and none is needed. `simplifyNode` reaches one at four sites --
    /// `simplifySiblingFunction`, `simplifyAnchorFunction`, `simplifyRandom` and `simplifyCalcMix`,
    /// each through `withCalcOriginalNode` -- and all four serve alternatives this grammar cannot
    /// produce: it emits the four numeric leaves, `Sum`, `Product`, `Negate` and `Invert`, and no
    /// fold over that set invents another. So the switch below is `simplifyNode`'s hot arm with the
    /// cold call removed, and the `default` is a REFUSAL rather than a leave-alone: an alternative
    /// arriving here would be a contract violation, not a coverage gap, because the only writer of
    /// these nodes is fifty lines above.
    ///
    /// `Min` and `Max` are absent for the same reason, one level further out: they reach the flat
    /// tree only from `convertToMinMax`, which only `simplifyClamp` calls.
    ///
    /// Returns false when a fold gave up mid-pass, which is the `declined` valve `emitRoot` tests on
    /// the other path; asked here instead so a refused tree never reaches emit.
    mutating func simplifyParsed(
        _ options: CalcSimplification,
        _ builder: WebCore.CSSCalc.CSSCalcSwiftBuilder?
    ) -> Bool {
        var i = 0
        while i < count {
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
                // The three unconditional no-ops, as `simplifyNode` names them.
                break

            default:
                // EVERY MATH FUNCTION, behind ONE call and behind `default`, which is
                // `simplifyNode`'s shape and is measured rather than tidy: naming them here would
                // take this switch from ten case values to twenty-one, and the thirty-first label on
                // `simplifyNode`'s switch cost 6.7 retired instructions per simplification on a
                // single-node tree that executes none of it (filings register section 51 -- LLVM
                // merges the case clusters, peels the widest, and then declines a jump table below
                // AArch64's ten-entry minimum). The hot switch names what a real page's CSS holds.
                guard simplifyParsedFunction(i, options) else {
                    return false
                }
            }
            i += 1
        }
        return !declined
    }

    /// The math-function folds a parsed tree can hold, behind one out-of-line call.
    @inline(never)
    private mutating func simplifyParsedFunction(_ i: Int, _ options: CalcSimplification) -> Bool {
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

        case .Log:
            simplifyLog(i)

        case .Mod:
            simplifyBinaryOperation(i, options, CalcExecutor.mod)

        case .Rem:
            simplifyBinaryOperation(i, options, CalcExecutor.rem)

        case .Atan2:
            simplifyAtan2(i, options)

        case .Pow:
            simplifyPow(i)

        case .Hypot:
            simplifyHypot(i, options)

        case .Progress:
            simplifyProgress(i, options, CalcExecutor.progress)

        case .ProgressNoClamp:
            simplifyProgress(i, options, CalcExecutor.progressNoClamp)

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

        case .Sqrt:
            simplifySqrt(i)

        case .Exp:
            simplifyNumberToNumber(i, CalcExecutor.exp)

        case .Abs:
            simplifyAbs(i, options)

        case .Sign:
            simplifySign(i, options)

        default:
            return false
        }
        return true
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
    /// Which bounds hold the keyword `none` is not derivable from the child count.
    /// `clamp(none, VAL, MAX)` and `clamp(MIN, VAL, none)` both report two children, because
    /// `Child::operator[]` skips a `ChildOrNone` holding the keyword entirely; the flat node carries
    /// the answer in `clampNoneMinimum`/`clampNoneMaximum`, captured at flatten from the boundary's
    /// two dedicated `CSSCalcSwiftNodeKind`s -- and, for both keywords at once, from the plain
    /// `Clamp` kind with one child, which `calcFlattenNode` turns into both bits so that this pass
    /// and the construction boundary share one invariant.
    ///
    /// The two collapse branches use different argument positions -- `Min(val, max)` at `:1064` and
    /// `Max(min, val)` at `:1080` -- and the two-argument executors short-circuit on whichever
    /// operand is NaN first, so the positions are transcribed rather than normalised. The result is
    /// shaped like `val` in both, since both call `makeChildWithValueBasedOn(..., val)`.
    ///
    /// `magnitudeComparable`, not `fullyResolved`: `clamp(none, 1em, 2em)` folds where
    /// `mod(5em, 3em)` does not, because a `NonCanonicalDimension` is comparable by magnitude
    /// (`:149`) and not fully resolved (`:171`). The asymmetry is real and is reproduced.
    ///
    /// The node produced by the `min()`/`max()` rewrite is never re-simplified. `copyAndSimplify`
    /// (`:1810`-`:1823`) calls `simplify` exactly once and takes the replacement as-is, so the
    /// rewritten `Min` does not go through `simplifyForMinMax`. The reverse scan gives that for
    /// free: node `i` has already been visited when this runs, and nothing revisits it.
    @inline(never)
    private mutating func simplifyClamp(_ i: Int, _ options: CalcSimplification) {
        let childCount = nodes[i].childCount
        let minimumIsNone = nodes[i].flags & CalcFlatNodeFlags.clampNoneMinimum != 0
        let maximumIsNone = nodes[i].flags & CalcFlatNodeFlags.clampNoneMaximum != 0

        // The cross-check, and the flat node's whole `clamp()` invariant: an absent bound is an
        // absent child, so `childCount + nones == 3` for all four states. A mismatch refuses the
        // tree rather than reading a bound out of the wrong slot -- and it must refuse rather than
        // leave the node alone, since `rebuildFrom` would then take the keywords off the original
        // and produce a node this pass never reasoned about.
        let nones = UInt32(minimumIsNone ? 1 : 0) + UInt32(maximumIsNone ? 1 : 0)
        guard childCount + nones == 3 else {
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
            let merged = calcTypeConsistentType(firstType, secondType) else {
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
                      let multiplied = calcTypeMultiply(productType, factorType) else {
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

    /// `emitRoot` for a tree the grammar built. `root` is named rather than assumed to be 0.
    func emitParsedRoot(_ root: Int, into builder: inout WebCore.CSSCalc.CSSCalcSwiftBuilder) -> Bool {
        guard !declined else {
            return false
        }
        return emitParsed(root, isRoot: true, into: &builder)
    }

    /// `emit` with the two origin routes removed, because there is no original tree to reach.
    ///
    /// THE ROUTE SET IS SMALLER, NOT DIFFERENT. `emit` above has three ways out -- `pushLeaf`,
    /// `buildOperation`, and a deep copy from the original for the payloads a fixed-size node cannot
    /// carry. A parsed tree holds only the four numeric leaves and the six operations
    /// `buildOperation` serves, so the third route has nothing to serve and its absence is a REFUSAL
    /// rather than an omission: anything else declines the tree to the C++ arm instead of building
    /// a node from an `origin` field that names nothing.
    ///
    /// `isRoot` is a parameter rather than `i == root`, because a comparison against a stored field
    /// is not the free `cmp #0` the pre-order path gets, and the recursion already has to pass
    /// something at each level.
    func emitParsed(_ i: Int, isRoot: Bool, into builder: inout WebCore.CSSCalc.CSSCalcSwiftBuilder) -> Bool {
        let node = nodes[i]

        // Two mask tests rather than two compare chains: one `lsr`/`tbz` pair against an immediate
        // the optimizer folds, instead of a run of `cmp`s proportional to how many alternatives
        // this route serves. `emitParsed` runs once per emitted node, and a compare chain is linear
        // in the label count, so the case that widens coverage would be the case that pays -- two
        // extra labels on the operation case measured a regression per parse. A mask
        // is constant in it.
        let alternativeBit = CalcFlatCoverage.bit(node.alternative)

        if alternativeBit & CalcParsedEmitCoverage.leafMask != 0 {
            guard let leaf = node.numericLeaf else {
                return false
            }
            return builder.pushLeaf(leaf.boundaryLeaf, isRoot)
        }

        guard alternativeBit & CalcParsedEmitCoverage.operationMask != 0 else {
            return false
        }

        var pushed: UInt32 = 0
        var cursor = node.firstChild
        while cursor != CalcFlatNode.noNode {
            guard emitParsed(Int(cursor), isRoot: false, into: &builder) else { return false }
            pushed &+= 1
            cursor = nodes[Int(cursor)].nextSibling
        }
        return builder.buildOperation(
            node.alternative, pushed, node.type, isRoot, node.flags & CalcFlatNodeFlags.clampNoneMask)
    }
}

/// What `emitParsed` can materialise, as two masks over the alternative index.
///
/// THE SET IS THE BOUNDARY'S, NOT THE GRAMMAR'S, and stating it here is what keeps the two from
/// drifting: `leafMask` is what `CSSCalcSwiftBuilder::pushLeaf` takes and `operationMask` is
/// exactly the switch in `CSSCalcSwiftBuilder::buildOperation`. A grammar arm that produces an
/// alternative outside them is a boundary contract violation, and `emitParsed` reports it as
/// `Failed` rather than as a decline -- see `CalcParseAttempt.emitRefused`.
///
/// Built from `CalcFlatCoverage.bit` rather than written as a hex literal, for that function's own
/// reasons: `&<<` cannot overflow at 41 alternatives, so no branchy smart shift is emitted, and the
/// whole `or` chain folds to one immediate at this size.
///
/// A computed `static var` rather than a `static let`, again for `CalcFlatCoverage.mask`'s reason: a
/// stored global is lazily initialised behind a `swift_once` guard, which is an atomic load, and
/// both of these are read once per emitted node.
private enum CalcParsedEmitCoverage {
    /// The four numeric leaves. `pushLeaf` serves all four and nothing else; the other three leaf
    /// alternatives -- `Symbol`, `SiblingCount`, `SiblingIndex` -- are stage F and are not here.
    static var leafMask: UInt64 {
        return CalcFlatCoverage.bit(.Number)
            | CalcFlatCoverage.bit(.Percentage)
            | CalcFlatCoverage.bit(.CanonicalDimension)
            | CalcFlatCoverage.bit(.NonCanonicalDimension)
    }

    /// The operations `buildOperation` constructs from operands alone: the two `Children`-slotted
    /// arithmetic nodes, the two `Children`-slotted comparison functions, the eleven whose only slot
    /// is one `Child` -- `Negate`, `Invert`, and the ten unary math functions with the `Deg2Rad`
    /// wrapper that goes inside three of them -- `Clamp`, whose two `ChildOrNone` bounds ride in the
    /// `noneMask` argument, and the five whose slots are `Child a; std::optional<Child> b`:
    /// `round()`'s four strategies, which are four alternatives rather than one node with a mode,
    /// and `log()`. The second slot's presence is the operand count and needs no argument at all.
    static var operationMask: UInt64 {
        return CalcFlatCoverage.bit(.Clamp)
            | CalcFlatCoverage.bit(.RoundNearest)
            | CalcFlatCoverage.bit(.RoundUp)
            | CalcFlatCoverage.bit(.RoundDown)
            | CalcFlatCoverage.bit(.RoundToZero)
            | CalcFlatCoverage.bit(.Log)
            | CalcFlatCoverage.bit(.Hypot)
            | CalcFlatCoverage.bit(.Mod)
            | CalcFlatCoverage.bit(.Rem)
            | CalcFlatCoverage.bit(.Atan2)
            | CalcFlatCoverage.bit(.Pow)
            | CalcFlatCoverage.bit(.Progress)
            | CalcFlatCoverage.bit(.ProgressNoClamp)
            | CalcFlatCoverage.bit(.Sum)
            | CalcFlatCoverage.bit(.Product)
            | CalcFlatCoverage.bit(.Min)
            | CalcFlatCoverage.bit(.Max)
            | CalcFlatCoverage.bit(.Negate)
            | CalcFlatCoverage.bit(.Invert)
            | CalcFlatCoverage.bit(.Deg2Rad)
            | CalcFlatCoverage.bit(.Sin)
            | CalcFlatCoverage.bit(.Cos)
            | CalcFlatCoverage.bit(.Tan)
            | CalcFlatCoverage.bit(.Asin)
            | CalcFlatCoverage.bit(.Acos)
            | CalcFlatCoverage.bit(.Atan)
            | CalcFlatCoverage.bit(.Sqrt)
            | CalcFlatCoverage.bit(.Exp)
            | CalcFlatCoverage.bit(.Abs)
            | CalcFlatCoverage.bit(.Sign)
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

// MARK: - The calc grammar in Swift (P7b stage D)

/// `<calc-sum>` over `<calc-product>` over `<calc-value>`, for the leaf grammar.
///
/// COVERED: `<number>`, `<percentage>`, `<dimension>` (canonical and non-canonical), the five
/// `<calc-keyword>` constants, `+`/`-`/`*`/`/` with both whitespace-adjacency rules, parenthesised
/// blocks and nested `calc()` (stage D2), `min()` and `max()` at any depth INCLUDING the top level
/// (stage E1), the ten one-argument math functions -- `sin()` `cos()` `tan()` `asin()` `acos()`
/// `atan()` `sqrt()` `exp()` `abs()` `sign()` -- with the parse-time `Deg2Rad` insertion the first
/// three need (stage E2), and the type algebra that goes with them. DECLINED, each with its own
/// reason so the coverage number stays attributable: the other twelve math functions (stages
/// E3-E5), symbols and tree-counting (stage F).
///
/// A DECLINE AND A FAILURE ARE DIFFERENT OUTCOMES and share no channel. `calc(1px +2px)` is a
/// FAILURE -- the C++ arm rejects it too, so retrying would re-derive the same rejection and a
/// caller that treated it as a decline would parse garbage twice. `calc(hypot(1px, 2px))` is a
/// DECLINE -- this grammar does not cover it yet and the C++ arm must run. Collapsing them makes
/// the decline count meaningless as a coverage number, which is the one number this stage exists
/// to move.
///
/// Nothing here holds the cursor in a stored property: it is passed down the recursion by value,
/// which is what keeps `CSSCalcSwiftParseCursor`'s `SWIFT_SAFE` claim -- "no stored property and no
/// escaping closure holds it" -- true as written.

/// The C++ parser's `maxExpressionDepth`, pinned on the C++ side by a `static_assert` so the two
/// arms cannot disagree about which deeply nested expressions parse.
private let calcMaxExpressionDepth: Int32 = 100

/// Mutable state threaded through the descent. Separate from the return value because both a
/// success and a decline can have set `requiresConversionData` on the way.
private struct CalcParseState {
    var requiresConversionData = false
    var declineReason = WebCore.CSSCalc.CSSCalcSwiftParseDeclineReason.None
    /// Set when the grammar hit something it does not cover, as opposed to invalid input.
    var declined = false

    /// A ONE-TOKEN CACHE, and it is not a micro-optimisation: `tokenAt` is an out-of-line call
    /// across the language boundary returning a 24-byte POD, and it cannot be inlined, because
    /// defining it in the header would mean naming `CSSParserTokenRange` there and this header is
    /// deliberately self-contained.
    ///
    /// The descent reads the same index several times over. For `calc(1px + 2px)` -- five tokens --
    /// the sequence of indices requested is 0, 0, 1, 2, 2, 2, 1, 3, 3, 4, 4: eleven crossings for
    /// five tokens, because the whitespace skip, the product loop, the sum loop and the
    /// look-BEHIND each ask about a token a caller has already fetched. One entry collapses that to
    /// six, the one repeat it cannot serve being the look-behind at `index - 1` after `index` has
    /// been cached.
    ///
    /// It lives here rather than in a parameter of its own because this struct is already threaded
    /// through the whole descent, and it holds an INDEX and a VALUE -- never the cursor -- so
    /// `CSSCalcSwiftParseCursor`'s `SWIFT_SAFE` claim, which says no stored property holds it,
    /// stays true as written.
    var cachedIndex: UInt32 = .max
    var cachedToken = WebCore.CSSCalc.CSSCalcSwiftToken()
}

/// The cached read. `UInt32.max` is the empty sentinel: a token count that large is not reachable --
/// `CSSParserTokenRange` is a span over the tokenizer's own vector and 4 billion tokens is 96 GB of
/// them -- so it cannot collide with a real index.
@inline(always)
private func calcToken(
    _ cursor: WebCore.CSSCalc.CSSCalcSwiftParseCursor,
    _ state: inout CalcParseState,
    _ index: UInt32
) -> WebCore.CSSCalc.CSSCalcSwiftToken {
    if state.cachedIndex != index {
        state.cachedToken = cursor.tokenAt(index)
        state.cachedIndex = index
    }
    return state.cachedToken
}

@inline(always)
private func calcTokenIsWhitespace(_ type: WebCore.CSSParserTokenType) -> Bool {
    type == WebCore.NonNewlineWhitespaceToken || type == WebCore.NewlineToken
}

private func calcSkipWhitespace(
    _ cursor: WebCore.CSSCalc.CSSCalcSwiftParseCursor,
    _ index: inout UInt32,
    _ end: UInt32,
    _ state: inout CalcParseState
) {
    while index < end && calcTokenIsWhitespace(calcToken(cursor, &state, index).type) {
        index += 1
    }
}

/// The index of the `BlockEnd` matching the `BlockStart` at `start`, or nil if the range ends first.
private func calcFindBlockEnd(
    _ cursor: WebCore.CSSCalc.CSSCalcSwiftParseCursor,
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

// MARK: The grammar's output: `CalcFlatNode`s, not `Child`s

/// One parsed subtree: where its root landed, and the `Type` the grammar computed for it.
private struct CalcParsed {
    let index: UInt32
    let type: CalcType
}

/// Append a numeric leaf and return its slot, or nil if the buffer is full.
@inline(always)
private func calcParseAppendLeaf(
    _ out: inout OutputSpan<CalcFlatNode>,
    _ alternative: WebCore.CSSCalc.CSSCalcSwiftAlternative,
    _ value: Double,
    _ unitType: UInt16,
    _ percentHint: UInt8
) -> UInt32? {
    // `setLeaf`'s narrowing guard, for the same reason it gives: no `CSSUnitType` enumerator can
    // fail it, because that enum is `uint8_t`-backed, but the flat node's `unitType` is a `UInt8`
    // and a silent truncation here would be a wrong unit rather than a decline.
    guard out.count < out.capacity, let narrowUnit = UInt8(exactly: unitType) else {
        return nil
    }
    let me = UInt32(truncatingIfNeeded: out.count)
    out.append(CalcFlatNode(
        value: value,
        type: CalcType(),
        firstChild: CalcFlatNode.noNode,
        nextSibling: CalcFlatNode.noNode,
        childCount: 0,
        // NO ORIGINAL TREE EXISTS, so there is no pre-order index to name. `calcFlatten` stores the
        // node's own slot here; a parsed node stores the sentinel, because the only readers of
        // `origin` are the four folds and two emit routes that reach back into a `CSSCalc::Child`,
        // and every one of them serves an alternative this grammar cannot produce. `emitParsed`
        // refuses those alternatives outright rather than trusting that they cannot arrive.
        origin: CalcFlatNode.noNode,
        valueID: 0,
        unitType: narrowUnit,
        alternative: alternative,
        percentHint: percentHint,
        flags: 0))
    return me
}

/// Append an operation over children already in the buffer, and return its slot.
@inline(always)
private func calcParseAppendOperation(
    _ out: inout OutputSpan<CalcFlatNode>,
    _ alternative: WebCore.CSSCalc.CSSCalcSwiftAlternative,
    _ firstChild: UInt32,
    _ childCount: UInt32,
    _ type: CalcType,
    _ flags: UInt8 = 0
) -> UInt32? {
    guard out.count < out.capacity else {
        return nil
    }
    let me = UInt32(truncatingIfNeeded: out.count)
    out.append(CalcFlatNode(
        value: 0,
        // The type the grammar computed, carried rather than recomputed at emit: `copyAndSimplify`
        // ends at `makeChild(..., getType(root))`, the node's own type, and a fresh `toType` over
        // simplified operands is a measured divergence.
        type: type,
        firstChild: firstChild,
        nextSibling: CalcFlatNode.noNode,
        childCount: childCount,
        origin: CalcFlatNode.noNode,
        valueID: 0,
        unitType: 0,
        alternative: alternative,
        percentHint: 0,
        flags: flags))
    return me
}

/// Link `node` on after `previous`. The caller must pass a real predecessor.
@inline(always)
private func calcParseLink(_ out: inout OutputSpan<CalcFlatNode>, _ previous: UInt32, _ node: UInt32) {
    var written = out.mutableSpan
    written[Int(previous)].nextSibling = node
}

/// `<calc-value>` = `<number>` | `<dimension>` | `<percentage>` | `<calc-keyword>` | `( <calc-sum> )`.
private func calcParseValue(
    _ cursor: WebCore.CSSCalc.CSSCalcSwiftParseCursor,
    _ index: inout UInt32,
    _ end: UInt32,
    _ depth: Int32,
    _ out: inout OutputSpan<CalcFlatNode>,
    _ options: WebCore.CSSCalc.CSSCalcSwiftParseOptions,
    _ state: inout CalcParseState
) -> CalcParsed? {
    if depth > calcMaxExpressionDepth { return nil }
    if index >= end { return nil }

    let token = calcToken(cursor, &state, index)

    // `parseCalcValue`'s `findBlock`: a `LeftParenthesisToken` is a nested `<calc-sum>`, and so is a
    // `calc()` / `-webkit-calc()` function. Any other math function is real CSS this grammar does
    // not cover yet, so it declines; a function block that is not a math function at all is a parse
    // failure, which is what the C++ does with it -- `findBlock` returns nothing and the value
    // switch below has no `FunctionToken` case.
    if token.blockType == calcBlockStart {
        return calcParseBlock(cursor, &index, end, depth, &out, options, &state, token)
    }

    index += 1
    calcSkipWhitespace(cursor, &index, end, &state)

    switch token.type {
    case WebCore.NumberToken:
        guard let me = calcParseAppendLeaf(&out, .Number, token.numericValue,
            UInt16(WebCore.CSSUnitType.Number.rawValue), 0) else { return nil }
        return CalcParsed(index: me, type: CalcType())

    case WebCore.PercentageToken:
        // `parseCalcPercentage`: the hint comes from the category, not from the token.
        let hint = CalcType.determinePercentHint(options.category)
        guard let me = calcParseAppendLeaf(&out, .Percentage, token.numericValue,
            UInt16(WebCore.CSSUnitType.Percentage.rawValue), percentHintRawValue(hint)) else { return nil }
        var percentType = CalcType()
        percentType.percent = 1
        if let unwrapped = percentHintFromRawValue(percentHintRawValue(hint)) {
            percentType = percentType.withPercentHintApplied(unwrapped)
        }
        return CalcParsed(index: me, type: percentType)

    case WebCore.DimensionToken:
        if token.unit == WebCore.CSSUnitType.Unknown { return nil }
        if token.flags & WebCore.CSSCalc.cssCalcSwiftTokenUnitNeedsConversionData != 0 {
            // `absoluteLengthUnitsOnly` makes this invalid input, not a decline.
            if options.absoluteLengthUnitsOnly { return nil }
            state.requiresConversionData = true
        }
        guard let alternative = calcNumericAlternativeForLeafKind(
            WebCore.CSSCalc.cssCalcSwiftLeafKindForUnit(UInt16(token.unit.rawValue))) else { return nil }
        guard let me = calcParseAppendLeaf(&out, alternative, token.numericValue,
            UInt16(token.unit.rawValue), 0) else { return nil }
        return CalcParsed(index: me, type: CalcType.determineType(token.unit))

    case WebCore.IdentToken:
        // `parseCalcKeyword`. The symbol-table case must be checked first on the C++ side, so an
        // ident that is not a constant is handed back rather than rejected: with a non-empty
        // `allowedSymbols` the C++ might still resolve it.
        let constant = WebCore.CSSCalc.cssCalcSwiftLookupConstantNumber(UInt16(token.id))
        if options.hasAllowedSymbols || !constant.resolved {
            state.declined = true
            state.declineReason = .Symbol
            return nil
        }
        guard let me = calcParseAppendLeaf(&out, .Number, constant.value,
            UInt16(WebCore.CSSUnitType.Number.rawValue), 0) else { return nil }
        return CalcParsed(index: me, type: CalcType())

    default:
        return nil
    }
}

/// Which of the four numeric alternatives a `CSSCalcSwiftNodeKind` leaf answer names.
@inline(always)
private func calcNumericAlternativeForLeafKind(_ kind: UInt8) -> WebCore.CSSCalc.CSSCalcSwiftAlternative? {
    switch kind {
    case WebCore.CSSCalc.CSSCalcSwiftNodeKind.Number.rawValue: return .Number
    case WebCore.CSSCalc.CSSCalcSwiftNodeKind.Percentage.rawValue: return .Percentage
    case WebCore.CSSCalc.CSSCalcSwiftNodeKind.CanonicalDimension.rawValue: return .CanonicalDimension
    case WebCore.CSSCalc.CSSCalcSwiftNodeKind.NonCanonicalDimension.rawValue: return .NonCanonicalDimension
    default: return nil
    }
}

/// The block case of `<calc-value>`, kept out of line.
@inline(never)
private func calcParseBlock(
    _ cursor: WebCore.CSSCalc.CSSCalcSwiftParseCursor,
    _ index: inout UInt32,
    _ end: UInt32,
    _ depth: Int32,
    _ out: inout OutputSpan<CalcFlatNode>,
    _ options: WebCore.CSSCalc.CSSCalcSwiftParseOptions,
    _ state: inout CalcParseState,
    _ token: WebCore.CSSCalc.CSSCalcSwiftToken
) -> CalcParsed? {
    // `parseCalcValue`'s `findBlock`: a `LeftParenthesisToken` is a nested `<calc-sum>`, and so is a
    // `calc()` / `-webkit-calc()` function. Any other math function is real CSS this grammar does
    // not cover yet, so it declines; a function block that is not a math function at all is a parse
    // failure, which is what the C++ does with it -- `findBlock` returns nothing and the value
    // switch has no `FunctionToken` case.
    let isPlainCalc = token.type == WebCore.LeftParenthesisToken
        || token.flags & WebCore.CSSCalc.cssCalcSwiftTokenIsPlainCalcFunction != 0
    if !isPlainCalc {
        if let function = calcParseFunctionAlternative(token.functionId) {
            return calcParseFunctionBlock(cursor, &index, end, depth, &out, options, &state,
                function.alternative, function.arguments)
        }
        if token.flags & WebCore.CSSCalc.cssCalcSwiftTokenIsCalcFunction != 0 {
            state.declined = true
            state.declineReason = .MathFunction
        }
        return nil
    }

    guard let blockEnd = calcFindBlockEnd(cursor, &state, index, end) else { return nil }

    var inner = index + 1
    calcSkipWhitespace(cursor, &inner, blockEnd, &state)
    guard let innerParsed = calcParseSum(cursor, &inner, blockEnd, depth + 1, &out, options, &state) else { return nil }
    // `if (!innerRange.atEnd()) return nullopt` -- extraneous tokens inside the block are a failure,
    // not a decline.
    calcSkipWhitespace(cursor, &inner, blockEnd, &state)
    if inner != blockEnd { return nil }

    index = blockEnd + 1
    calcSkipWhitespace(cursor, &index, end, &state)
    // A parenthesised group is not a node: the C++ returns the inner `<calc-sum>`'s child directly,
    // so the block contributes no slot of its own and the caller links the inner root.
    return innerParsed
}

// MARK: The math functions

/// Which `consume*Arguments` helper `parseCalcFunction` runs for a covered function -- i.e. the
/// function's argument grammar, which is the only thing that differs between the families this
/// grammar serves.
private enum CalcFunctionArguments: UInt8 {
    /// `<calc-sum>#`, at least one, comma separated -- `consumeOneOrMoreArguments`
    /// (`CSSCalcTree+Parser.cpp:321`).
    case oneOrMore
    /// Exactly one `<calc-sum>` -- `consumeExactlyOneArgument` (`:280`).
    case exactlyOne
    /// `[ <calc-sum> | none ], <calc-sum>, [ <calc-sum> | none ]` -- `consumeClamp` (`:493`). The
    /// first argument grammar that is neither a repetition nor a fixed arity of subtrees, which is
    /// why it is a third case rather than a count.
    case clamp
    /// `<calc-sum>, <calc-sum>?` -- `consumeOneOrTwoArguments` (`:430`). Stage E4, and `log()` is
    /// its only member: `round()` has the same SHAPE but a different type rule, below.
    case oneOrTwo
    /// `<rounding-strategy>?, <calc-sum>, <calc-sum>?` -- `consumeRound` (`:655`), stage E4.
    ///
    /// A FIFTH CASE RATHER THAN `oneOrTwo` PLUS A FLAG, because two things differ and neither is a
    /// parameter of the other. The leading keyword SELECTS THE ALTERNATIVE -- `RoundNearest`,
    /// `RoundUp`, `RoundDown`, `RoundToZero` are four variant alternatives, not one node with a
    /// mode (`CSSCalcSwiftTypes.h:267`-`:270`) -- and `consumeRoundArguments` (`:595`) validates a
    /// DIFFERENT type from `consumeOneOrTwoArguments`: `AllowedTypes::Number` on the one-argument
    /// form only, and nothing at all on the two-argument form, where `log()` validates
    /// `Op::input` on both arguments in both forms. The header says so in as many words --
    /// "NOTE: This is special cased in the code" (`CSSCalcTree.h:495`-`:499`).
    case round
    /// Exactly two `<calc-sum>`, comma separated -- `consumeExactlyTwoArguments` (`:379`). Stage E5:
    /// `mod`, `rem`, `atan2`, `pow`.
    case exactlyTwo
    /// `no-clamp? <calc-sum>, <calc-sum>, <calc-sum>` -- `consumeProgress` (`:902`), stage E5.
    ///
    /// The keyword takes NO COMMA after it, unlike `round()`'s strategy, and that asymmetry is in
    /// the C++ too: `consumeRound` requires one at `:663` and `consumeProgress` requires none.
    case progress
}

/// Which `CSSCalcSwiftAlternative` a `FunctionToken`'s `CSSValueID` names, and how its arguments
/// parse, or nil for a function this grammar does not cover.
@inline(always)
private func calcParseFunctionAlternative(_ functionId: UInt16)
    -> (alternative: WebCore.CSSCalc.CSSCalcSwiftAlternative, arguments: CalcFunctionArguments)? {
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
    default: return nil
    }
}

/// A covered math function as a nested `<calc-value>`: find the block, parse its arguments, step past.
@inline(never)
private func calcParseFunctionBlock(
    _ cursor: WebCore.CSSCalc.CSSCalcSwiftParseCursor,
    _ index: inout UInt32,
    _ end: UInt32,
    _ depth: Int32,
    _ out: inout OutputSpan<CalcFlatNode>,
    _ options: WebCore.CSSCalc.CSSCalcSwiftParseOptions,
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
            cursor, &inner, blockEnd, depth + 1, &out, options, &state, alternative)
    case .exactlyOne:
        argumentsParsed = calcParseUnaryFunction(
            cursor, &inner, blockEnd, depth + 1, &out, options, &state, alternative)
    case .clamp:
        argumentsParsed = calcParseClamp(
            cursor, &inner, blockEnd, depth + 1, &out, options, &state)
    case .oneOrTwo:
        argumentsParsed = calcParseOneOrTwoArguments(
            cursor, &inner, blockEnd, depth + 1, &out, options, &state, alternative)
    case .round:
        argumentsParsed = calcParseRound(
            cursor, &inner, blockEnd, depth + 1, &out, options, &state)
    case .exactlyTwo:
        argumentsParsed = calcParseTwoArguments(
            cursor, &inner, blockEnd, depth + 1, &out, options, &state, alternative)
    case .progress:
        argumentsParsed = calcParseProgress(
            cursor, &inner, blockEnd, depth + 1, &out, options, &state)
    }
    guard let parsed = argumentsParsed else { return nil }
    if inner != blockEnd { return nil }

    index = blockEnd + 1
    calcSkipWhitespace(cursor, &index, end, &state)
    return parsed
}

/// `consumeExactlyOneArgument<Op>` (`CSSCalcTree+Parser.cpp:280`-`:319`): one `<calc-sum>`, its
/// type checked against `Op::input`, the node's type `transformType<Op::output>` of it, and --
/// for the three trigonometric functions given an `<angle>` -- a `Deg2Rad` wrapper around the
/// argument.
private func calcParseUnaryFunction(
    _ cursor: WebCore.CSSCalc.CSSCalcSwiftParseCursor,
    _ index: inout UInt32,
    _ end: UInt32,
    _ depth: Int32,
    _ out: inout OutputSpan<CalcFlatNode>,
    _ options: WebCore.CSSCalc.CSSCalcSwiftParseOptions,
    _ state: inout CalcParseState,
    _ alternative: WebCore.CSSCalc.CSSCalcSwiftAlternative
) -> CalcParsed? {
    if depth > calcMaxExpressionDepth { return nil }

    calcSkipWhitespace(cursor, &index, end, &state)
    guard let argument = calcParseSum(cursor, &index, end, depth, &out, options, &state) else { return nil }
    calcSkipWhitespace(cursor, &index, end, &state)

    // The operand the operation node will name. It is the argument itself unless the `Deg2Rad`
    // wrapper goes in, and the wrapper is appended before the operation so the buffer stays
    // post-order: every child at a lower index than its parent.
    var operand = argument.index
    let outputType: CalcType

    switch alternative {
    case .Sin, .Cos, .Tan:
        guard argument.type.matchesNumberOrAngle,
            let transformed = CalcType.makeNumber().madeConsistent(with: argument.type) else { return nil }
        outputType = transformed

        // `CSSCalcTree+Parser.cpp:311`-`:316`. Two things a transcription gets wrong and both are
        // silent: the condition is on the argument's type matching `<angle>` exactly -- so
        // `sin(0.5)` gets no wrapper and `sin(30deg)` does -- and the node carries `Type { }`, the
        // empty type, not the angle's.
        if argument.type.matchesAngle {
            guard let converted = calcParseAppendOperation(
                &out, .Deg2Rad, argument.index, 1, CalcType()) else { return nil }
            operand = converted
        }

    case .Asin, .Acos, .Atan:
        guard argument.type.matchesNumber,
            let transformed = CalcType.makeAngle().madeConsistent(with: argument.type) else { return nil }
        outputType = transformed

    case .Sqrt, .Exp:
        guard argument.type.matchesNumber,
            let transformed = CalcType.makeNumber().madeConsistent(with: argument.type) else { return nil }
        outputType = transformed

    case .Sign:
        guard let transformed = CalcType.makeNumber().madeConsistent(with: argument.type) else { return nil }
        outputType = transformed

    case .Abs:
        outputType = argument.type

    default:
        // Not one of the ten. Unreachable, because the only caller reaches here through
        // `calcParseFunctionAlternative`'s `.exactlyOne` case -- and a refusal rather than a guess:
        // an alternative built with the wrong type rule is a wrong tree, where handing the input
        // back is merely the C++ path running.
        return nil
    }

    guard let me = calcParseAppendOperation(&out, alternative, operand, 1, outputType) else { return nil }
    return CalcParsed(index: me, type: outputType)
}

/// `consumeCommaIncludingWhitespace` (`CSSPropertyParserConsumer+Primitives.h`), as the grammar's
/// call sites spell it: the token must be a comma, and the whitespace after it goes with it.
@inline(always)
private func calcParseComma(
    _ cursor: WebCore.CSSCalc.CSSCalcSwiftParseCursor,
    _ index: inout UInt32,
    _ end: UInt32,
    _ state: inout CalcParseState
) -> Bool {
    guard index < end, calcToken(cursor, &state, index).type == WebCore.CommaToken else { return false }
    index += 1
    calcSkipWhitespace(cursor, &index, end, &state)
    return true
}

/// `parseCalcSumOrNone` (`CSSCalcTree+Parser.cpp:503`-`:513`): the keyword `none`, or a
/// `<calc-sum>`.
@inline(always)
private func calcParseSumOrNone(
    _ cursor: WebCore.CSSCalc.CSSCalcSwiftParseCursor,
    _ index: inout UInt32,
    _ end: UInt32,
    _ depth: Int32,
    _ out: inout OutputSpan<CalcFlatNode>,
    _ options: WebCore.CSSCalc.CSSCalcSwiftParseOptions,
    _ state: inout CalcParseState
) -> CalcParsed? {
    if index < end, calcToken(cursor, &state, index).id == UInt16(WebCore.CSSValueNone.rawValue) {
        index += 1
        calcSkipWhitespace(cursor, &index, end, &state)
        return CalcParsed(index: CalcFlatNode.noNode, type: CalcType())
    }
    return calcParseSum(cursor, &index, end, depth, &out, options, &state)
}

/// `consumeClamp` (`CSSCalcTree+Parser.cpp:493`-`:591`):
/// `clamp( [ <calc-sum> | none ], <calc-sum>, [ <calc-sum> | none ] )`.
///
/// The type rule is four-way, and that is not a simplification of one merge. `computeType`
/// (`:547`-`:583`) folds only the bounds that are present: both `none` gives the value's own type
/// untouched, and a single `none` merges the remaining pair. Folding an empty `Type` in instead
/// would be a different answer -- `Type { }` is not an identity for `consistentType` -- so the cases
/// are written out. All three merges are `MergePolicy::Consistent` (`Clamp::merge`,
/// `CSSCalcTree.h:470`), and there is no `validateType` and no output transform: `Clamp::input` is
/// `AllowedTypes::Any`, which is `return true`, and `Clamp::output` is `OutputTransform::None`.
///
/// No operand container: the three subtrees are already in the flat buffer, and the node names the
/// first and links the rest.
private func calcParseClamp(
    _ cursor: WebCore.CSSCalc.CSSCalcSwiftParseCursor,
    _ index: inout UInt32,
    _ end: UInt32,
    _ depth: Int32,
    _ out: inout OutputSpan<CalcFlatNode>,
    _ options: WebCore.CSSCalc.CSSCalcSwiftParseOptions,
    _ state: inout CalcParseState
) -> CalcParsed? {
    if depth > calcMaxExpressionDepth { return nil }
    calcSkipWhitespace(cursor, &index, end, &state)

    guard let minimum = calcParseSumOrNone(cursor, &index, end, depth, &out, options, &state) else { return nil }
    calcSkipWhitespace(cursor, &index, end, &state)
    guard calcParseComma(cursor, &index, end, &state) else { return nil }

    guard let value = calcParseSum(cursor, &index, end, depth, &out, options, &state) else { return nil }
    calcSkipWhitespace(cursor, &index, end, &state)
    guard calcParseComma(cursor, &index, end, &state) else { return nil }

    guard let maximum = calcParseSumOrNone(cursor, &index, end, depth, &out, options, &state) else { return nil }
    calcSkipWhitespace(cursor, &index, end, &state)

    let noneMinimum = minimum.index == CalcFlatNode.noNode
    let noneMaximum = maximum.index == CalcFlatNode.noNode

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
            let merged = lower.consistentType(with: maximum.type) else { return nil }
        outputType = merged
    }

    // The sibling list is min, val, max in that order over the bounds that exist, because
    // `buildOperation` fills the slots left to right from the top of the operand stack and an
    // absent bound is an absent operand. `emitParsed` pushes in list order, so list order is
    // operand order.
    var head = value.index
    var childCount: UInt32 = 1
    if !noneMinimum {
        calcParseLink(&out, minimum.index, value.index)
        head = minimum.index
        childCount += 1
    }
    if !noneMaximum {
        calcParseLink(&out, value.index, maximum.index)
        childCount += 1
    }

    var flags: UInt8 = 0
    if noneMinimum { flags |= CalcFlatNodeFlags.clampNoneMinimum }
    if noneMaximum { flags |= CalcFlatNodeFlags.clampNoneMaximum }

    guard let me = calcParseAppendOperation(&out, .Clamp, head, childCount, outputType, flags) else { return nil }
    return CalcParsed(index: me, type: outputType)
}

/// Which `<rounding-strategy>` an ident names, as the alternative it selects.
@inline(always)
private func calcRoundingStrategyAlternative(_ id: UInt16)
    -> WebCore.CSSCalc.CSSCalcSwiftAlternative? {
    switch id {
    case UInt16(WebCore.CSSValueNearest.rawValue): return .RoundNearest
    case UInt16(WebCore.CSSValueUp.rawValue): return .RoundUp
    case UInt16(WebCore.CSSValueDown.rawValue): return .RoundDown
    case UInt16(WebCore.CSSValueToZero.rawValue): return .RoundToZero
    default: return nil
    }
}

/// `consumeRound` (`CSSCalcTree+Parser.cpp:655`-`:682`):
/// `round( <rounding-strategy>?, <calc-sum>, <calc-sum>? )`.
private func calcParseRound(
    _ cursor: WebCore.CSSCalc.CSSCalcSwiftParseCursor,
    _ index: inout UInt32,
    _ end: UInt32,
    _ depth: Int32,
    _ out: inout OutputSpan<CalcFlatNode>,
    _ options: WebCore.CSSCalc.CSSCalcSwiftParseOptions,
    _ state: inout CalcParseState
) -> CalcParsed? {
    // Before the peek, not after. `consumeIdentRaw` peeks a range whose leading whitespace the
    // caller has already stripped (`parseCalcValue`'s `innerRange.consumeWhitespace()`, `:1537`),
    // but `calcParseFunctionBlock` hands its callee the range starting one token past `(` -- so
    // `calcParseClamp` and `calcParseUnaryFunction` each strip it themselves and so must this.
    calcSkipWhitespace(cursor, &index, end, &state)

    var alternative = WebCore.CSSCalc.CSSCalcSwiftAlternative.RoundNearest
    if index < end, let selected = calcRoundingStrategyAlternative(calcToken(cursor, &state, index).id) {
        index += 1
        calcSkipWhitespace(cursor, &index, end, &state)
        guard calcParseComma(cursor, &index, end, &state) else { return nil }
        alternative = selected
    }
    return calcParseRoundArguments(cursor, &index, end, depth, &out, options, &state, alternative)
}

/// `consumeRoundArguments<Op>` (`CSSCalcTree+Parser.cpp:595`-`:653`): `<calc-sum>, <calc-sum>?`
/// under `round()`'s own type rule.
private func calcParseRoundArguments(
    _ cursor: WebCore.CSSCalc.CSSCalcSwiftParseCursor,
    _ index: inout UInt32,
    _ end: UInt32,
    _ depth: Int32,
    _ out: inout OutputSpan<CalcFlatNode>,
    _ options: WebCore.CSSCalc.CSSCalcSwiftParseOptions,
    _ state: inout CalcParseState,
    _ alternative: WebCore.CSSCalc.CSSCalcSwiftAlternative
) -> CalcParsed? {
    if depth > calcMaxExpressionDepth { return nil }
    calcSkipWhitespace(cursor, &index, end, &state)

    guard let a = calcParseSum(cursor, &index, end, depth, &out, options, &state) else { return nil }
    calcSkipWhitespace(cursor, &index, end, &state)

    if index == end {
        // `validateType<AllowedTypes::Number>(sumA->type)`, not `Op::input`. `round(1.5px)` is a
        // failure and `round(1.5)` is not, which no other one-argument family in this grammar does.
        guard a.type.matchesNumber else { return nil }
        guard let me = calcParseAppendOperation(&out, alternative, a.index, 1, a.type) else { return nil }
        return CalcParsed(index: me, type: a.type)
    }

    guard calcParseComma(cursor, &index, end, &state) else { return nil }
    guard let b = calcParseSum(cursor, &index, end, depth, &out, options, &state) else { return nil }
    calcSkipWhitespace(cursor, &index, end, &state)

    guard let merged = a.type.consistentType(with: b.type) else { return nil }
    calcParseLink(&out, a.index, b.index)
    guard let me = calcParseAppendOperation(&out, alternative, a.index, 2, merged) else { return nil }
    return CalcParsed(index: me, type: merged)
}

/// `consumeOneOrTwoArguments<Op>` (`CSSCalcTree+Parser.cpp:430`-`:491`): `<calc-sum>, <calc-sum>?`.
private func calcParseOneOrTwoArguments(
    _ cursor: WebCore.CSSCalc.CSSCalcSwiftParseCursor,
    _ index: inout UInt32,
    _ end: UInt32,
    _ depth: Int32,
    _ out: inout OutputSpan<CalcFlatNode>,
    _ options: WebCore.CSSCalc.CSSCalcSwiftParseOptions,
    _ state: inout CalcParseState,
    _ alternative: WebCore.CSSCalc.CSSCalcSwiftAlternative
) -> CalcParsed? {
    if depth > calcMaxExpressionDepth { return nil }
    calcSkipWhitespace(cursor, &index, end, &state)

    guard let a = calcParseSum(cursor, &index, end, depth, &out, options, &state) else { return nil }
    calcSkipWhitespace(cursor, &index, end, &state)
    guard a.type.matchesNumber else { return nil }

    if index == end {
        guard let transformed = CalcType.makeNumber().madeConsistent(with: a.type) else { return nil }
        guard let me = calcParseAppendOperation(&out, alternative, a.index, 1, transformed) else { return nil }
        return CalcParsed(index: me, type: transformed)
    }

    guard calcParseComma(cursor, &index, end, &state) else { return nil }
    guard let b = calcParseSum(cursor, &index, end, depth, &out, options, &state) else { return nil }
    calcSkipWhitespace(cursor, &index, end, &state)
    guard b.type.matchesNumber else { return nil }

    guard let merged = a.type.consistentType(with: b.type),
        let transformed = CalcType.makeNumber().madeConsistent(with: merged) else { return nil }
    calcParseLink(&out, a.index, b.index)
    guard let me = calcParseAppendOperation(&out, alternative, a.index, 2, transformed) else { return nil }
    return CalcParsed(index: me, type: transformed)
}

/// `consumeExactlyTwoArguments<Op>` (`CSSCalcTree+Parser.cpp:379`-`:428`): `mod`, `rem`, `atan2`,
/// `pow`.
private func calcParseTwoArguments(
    _ cursor: WebCore.CSSCalc.CSSCalcSwiftParseCursor,
    _ index: inout UInt32,
    _ end: UInt32,
    _ depth: Int32,
    _ out: inout OutputSpan<CalcFlatNode>,
    _ options: WebCore.CSSCalc.CSSCalcSwiftParseOptions,
    _ state: inout CalcParseState,
    _ alternative: WebCore.CSSCalc.CSSCalcSwiftAlternative
) -> CalcParsed? {
    if depth > calcMaxExpressionDepth { return nil }
    calcSkipWhitespace(cursor, &index, end, &state)

    guard let a = calcParseSum(cursor, &index, end, depth, &out, options, &state) else { return nil }
    calcSkipWhitespace(cursor, &index, end, &state)
    if alternative == .Pow && !a.type.matchesNumber { return nil }

    guard calcParseComma(cursor, &index, end, &state) else { return nil }
    guard let b = calcParseSum(cursor, &index, end, depth, &out, options, &state) else { return nil }
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
        // Not one of the four; unreachable through `calcParseFunctionAlternative`'s `.exactlyTwo`
        // case, and a refusal rather than a guess for `calcParseUnaryFunction`'s reason.
        return nil
    }

    calcParseLink(&out, a.index, b.index)
    guard let me = calcParseAppendOperation(&out, alternative, a.index, 2, outputType) else { return nil }
    return CalcParsed(index: me, type: outputType)
}

/// `consumeProgress` (`CSSCalcTree+Parser.cpp:902`-`:910`) and `consumeProgressImpl` (`:824`):
/// `progress( no-clamp? <calc-sum>, <calc-sum>, <calc-sum> )`.
private func calcParseProgress(
    _ cursor: WebCore.CSSCalc.CSSCalcSwiftParseCursor,
    _ index: inout UInt32,
    _ end: UInt32,
    _ depth: Int32,
    _ out: inout OutputSpan<CalcFlatNode>,
    _ options: WebCore.CSSCalc.CSSCalcSwiftParseOptions,
    _ state: inout CalcParseState
) -> CalcParsed? {
    if depth > calcMaxExpressionDepth { return nil }
    calcSkipWhitespace(cursor, &index, end, &state)

    var alternative = WebCore.CSSCalc.CSSCalcSwiftAlternative.Progress
    if index < end, calcToken(cursor, &state, index).id == UInt16(WebCore.CSSValueNoClamp.rawValue) {
        index += 1
        calcSkipWhitespace(cursor, &index, end, &state)
        alternative = .ProgressNoClamp
    }

    guard let value = calcParseSum(cursor, &index, end, depth, &out, options, &state) else { return nil }
    calcSkipWhitespace(cursor, &index, end, &state)
    guard calcParseComma(cursor, &index, end, &state) else { return nil }

    guard let start = calcParseSum(cursor, &index, end, depth, &out, options, &state) else { return nil }
    calcSkipWhitespace(cursor, &index, end, &state)
    guard calcParseComma(cursor, &index, end, &state) else { return nil }

    guard let finish = calcParseSum(cursor, &index, end, depth, &out, options, &state) else { return nil }
    calcSkipWhitespace(cursor, &index, end, &state)
    if index != end { return nil }

    guard let firstMerge = value.type.consistentType(with: start.type),
        let merged = firstMerge.consistentType(with: finish.type),
        let outputType = CalcType.makeNumber().madeConsistent(with: merged) else { return nil }

    // Slot order is list order, as it is for `clamp()`: `buildOperation` fills left to right from
    // the top of the operand stack and `emitParsed` pushes in list order.
    calcParseLink(&out, value.index, start.index)
    calcParseLink(&out, start.index, finish.index)
    guard let me = calcParseAppendOperation(&out, alternative, value.index, 3, outputType) else { return nil }
    return CalcParsed(index: me, type: outputType)
}

/// `consumeOneOrMoreArguments<Op>` (`CSSCalcTree+Parser.cpp:321`-`:376`): `<calc-sum>#`, at least
/// one, over the whole range it is given.
private func calcParseArgumentList(
    _ cursor: WebCore.CSSCalc.CSSCalcSwiftParseCursor,
    _ index: inout UInt32,
    _ end: UInt32,
    _ depth: Int32,
    _ out: inout OutputSpan<CalcFlatNode>,
    _ options: WebCore.CSSCalc.CSSCalcSwiftParseOptions,
    _ state: inout CalcParseState,
    _ alternative: WebCore.CSSCalc.CSSCalcSwiftAlternative
) -> CalcParsed? {
    if depth > calcMaxExpressionDepth { return nil }

    var mergedType = CalcType()
    var childCount: UInt32 = 0
    var head = CalcFlatNode.noNode
    var tail = CalcFlatNode.noNode

    while index < end {
        calcSkipWhitespace(cursor, &index, end, &state)
        if childCount > 0 {
            guard calcParseComma(cursor, &index, end, &state) else { return nil }
        }

        guard let argument = calcParseSum(cursor, &index, end, depth, &out, options, &state) else { return nil }

        if childCount == 0 {
            mergedType = argument.type
            head = argument.index
        } else {
            guard let merged = mergedType.consistentType(with: argument.type) else { return nil }
            mergedType = merged
            calcParseLink(&out, tail, argument.index)
        }
        tail = argument.index
        childCount += 1
    }

    // `if (argumentCount < 1) return nullopt` -- `min()` is invalid input, not a decline.
    if childCount == 0 { return nil }
    guard let me = calcParseAppendOperation(&out, alternative, head, childCount, mergedType) else { return nil }
    return CalcParsed(index: me, type: mergedType)
}

/// `<calc-product> = <calc-value> [ [ '*' | '/' ] <calc-value> ]*`
private func calcParseProduct(
    _ cursor: WebCore.CSSCalc.CSSCalcSwiftParseCursor,
    _ index: inout UInt32,
    _ end: UInt32,
    _ depth: Int32,
    _ out: inout OutputSpan<CalcFlatNode>,
    _ options: WebCore.CSSCalc.CSSCalcSwiftParseOptions,
    _ state: inout CalcParseState
) -> CalcParsed? {
    if depth > calcMaxExpressionDepth { return nil }

    guard let first = calcParseValue(cursor, &index, end, depth, &out, options, &state) else { return nil }
    var productType = first.type

    var childCount: UInt32 = 0
    let head = first.index
    var tail = first.index

    while index < end {
        let token = calcToken(cursor, &state, index)
        let op = token.type == WebCore.DelimiterToken ? token.delimiter : 0
        if op != 0x2A && op != 0x2F { break }  // '*' and '/'
        index += 1
        calcSkipWhitespace(cursor, &index, end, &state)

        guard let next = calcParseValue(cursor, &index, end, depth, &out, options, &state) else { return nil }

        var operandType = next.type
        var operand = next.index
        if op == 0x2F {
            operandType = next.type.inverted()
            guard let inverted = calcParseAppendOperation(&out, .Invert, next.index, 1, operandType) else { return nil }
            operand = inverted
        }

        if childCount == 0 { childCount = 1 }
        guard let merged = productType.multiplied(by: operandType) else { return nil }
        productType = merged
        childCount += 1
        calcParseLink(&out, tail, operand)
        tail = operand
    }

    if childCount == 0 { return first }
    guard let me = calcParseAppendOperation(&out, .Product, head, childCount, productType) else { return nil }
    return CalcParsed(index: me, type: productType)
}

/// `<calc-sum> = <calc-product> [ [ '+' | '-' ] <calc-product> ]*`
private func calcParseSum(
    _ cursor: WebCore.CSSCalc.CSSCalcSwiftParseCursor,
    _ index: inout UInt32,
    _ end: UInt32,
    _ depth: Int32,
    _ out: inout OutputSpan<CalcFlatNode>,
    _ options: WebCore.CSSCalc.CSSCalcSwiftParseOptions,
    _ state: inout CalcParseState
) -> CalcParsed? {
    if depth > calcMaxExpressionDepth { return nil }

    // The look-BEHIND below indexes one before the current token, so the sum's own start is where
    // that index is measured from -- exactly what `originalTokens` is on the C++ side.
    guard let first = calcParseProduct(cursor, &index, end, depth, &out, options, &state) else { return nil }
    var sumType = first.type

    var childCount: UInt32 = 0
    let head = first.index
    var tail = first.index

    while index < end {
        let token = calcToken(cursor, &state, index)
        let op = token.type == WebCore.DelimiterToken ? token.delimiter : 0
        if op != 0x2B && op != 0x2D { break }  // '+' and '-'

        // `calc(1px+ 2px)` is invalid: the operator must be preceded by whitespace. The C++ reads
        // `originalTokens[tokens.begin() - originalTokens.data() - 1]`, which is the token before
        // the operator in the whole range -- an index subtraction here, and the reason whitespace
        // tokens are not filtered out of the cursor.
        if index == 0 { return nil }
        if !calcTokenIsWhitespace(calcToken(cursor, &state, index - 1).type) { return nil }

        index += 1
        // `calc(1px +2px)` is invalid: the operator must be followed by whitespace.
        if index >= end || !calcTokenIsWhitespace(calcToken(cursor, &state, index).type) { return nil }
        calcSkipWhitespace(cursor, &index, end, &state)

        guard let next = calcParseProduct(cursor, &index, end, depth, &out, options, &state) else { return nil }

        var operand = next.index
        if op == 0x2D {
            guard let negated = calcParseAppendOperation(&out, .Negate, next.index, 1, next.type) else { return nil }
            operand = negated
        }

        if childCount == 0 { childCount = 1 }
        guard let merged = sumType.added(to: next.type) else { return nil }
        sumType = merged
        childCount += 1
        calcParseLink(&out, tail, operand)
        tail = operand
    }

    if childCount == 0 { return first }
    guard let me = calcParseAppendOperation(&out, .Sum, head, childCount, sumType) else { return nil }
    return CalcParsed(index: me, type: sumType)
}

/// The retry size. Every node is paid for by at least one distinct token -- a leaf by its own
/// token, a `Sum`/`Product`/`Negate`/`Invert` by a delimiter, a function node by its
/// `FunctionToken` and `)` -- and the one node that consumes no token of its own, the `Deg2Rad`
/// wrapper, is paid for by the `sin`/`cos`/`tan` token's second unit, so `2N + 1` bounds the
/// count with margin.
@inline(always)
private func calcParseNodeUpperBound(_ tokenCount: UInt32) -> Int {
    return 2 * Int(tokenCount) + 1
}

/// What one attempt at the whole parse produced.
private struct CalcParseAttempt {
    /// Nil when the descent failed, declined, or ran out of buffer -- the flags say which.
    var type: CalcType?
    /// The buffer filled up, so the caller should retry at an exact size rather than report.
    var overflowed = false
    /// A FOLD gave up on the tree, which is the `CalcFlatTree.declined` valve. A genuine decline:
    /// the C++ arm must run. Currently unreachable and kept because it is the valve's contract, not
    /// because it fires -- every site that sets `declined` is in `simplifySymbol`,
    /// `simplifySiblingFunction`, `simplifyAnchorFunction`, `simplifyRandom`, `simplifyClamp`,
    /// `simplifyRound`, `simplifyCalcMix` or `calcMixFoldToZero`, and this grammar produces none of
    /// those alternatives.
    var foldRefused = false
    /// A CONSTRUCTION refused, which is a boundary contract violation and not a decline. Reported as
    /// `Failed`, deliberately: the differential treats a decline as never-a-mismatch, so routing a
    /// contract violation there would absorb it silently, where `Failed` on an input the C++ arm
    /// parsed is exactly the mismatch that should be loud.
    var emitRefused = false
}

/// Parse the token range inside a `calc()`, simplify it, and materialise the result once.
@_expose(Cxx)
public func cssCalcParseSwift(
    _ cursor: WebCore.CSSCalc.CSSCalcSwiftParseCursor,
    _ builder: inout WebCore.CSSCalc.CSSCalcSwiftBuilder,
    _ options: WebCore.CSSCalc.CSSCalcSwiftParseOptions,
    _ simplificationOptions: WebCore.CSSCalc.CSSCalcSwiftSimplificationOptions,
    _ simplify: Bool
) -> WebCore.CSSCalc.CSSCalcSwiftParseResult {
    var result = WebCore.CSSCalc.CSSCalcSwiftParseResult()
    var state = CalcParseState()

    var attempt = calcParseAttempt(cursor, &builder, options, simplificationOptions, simplify,
        calcFlatStackCapacity, &state)

    // A tree too big for the fixed stack buffer, retried at a size that cannot overflow. Nothing has
    // been observed on the first attempt -- the buffer is scratch, and a descent that overflowed
    // pushed no operand, because operands are only pushed by the emit that overflow prevents -- so
    // the retry starts from a clean state, exactly as `calcFlatSimplifyOversized` does.
    if attempt.overflowed {
        state = CalcParseState()
        attempt = calcParseAttempt(cursor, &builder, options, simplificationOptions, simplify,
            calcParseNodeUpperBound(cursor.tokenCount()), &state)
    }

    guard let type = attempt.type else {
        if attempt.foldRefused {
            result.outcome = UInt8(WebCore.CSSCalc.CSSCalcSwiftParseOutcome.Declined.rawValue)
            result.declineReason = UInt8(WebCore.CSSCalc.CSSCalcSwiftParseDeclineReason.None.rawValue)
            return result
        }
        if attempt.emitRefused {
            result.outcome = UInt8(WebCore.CSSCalc.CSSCalcSwiftParseOutcome.Declined.rawValue)
            result.declineReason = UInt8(
                WebCore.CSSCalc.CSSCalcSwiftParseDeclineReason.ContractViolation.rawValue)
            return result
        }
        result.outcome = UInt8(state.declined
            ? WebCore.CSSCalc.CSSCalcSwiftParseOutcome.Declined.rawValue
            : WebCore.CSSCalc.CSSCalcSwiftParseOutcome.Failed.rawValue)
        result.declineReason = UInt8(state.declineReason.rawValue)
        return result
    }

    result.type = type
    result.outcome = UInt8(WebCore.CSSCalc.CSSCalcSwiftParseOutcome.Parsed.rawValue)
    result.requiresConversionData = state.requiresConversionData
    return result
}

/// One attempt at parse, simplify and emit over a buffer of `capacity` nodes.
@inline(never)
private func calcParseAttempt(
    _ cursor: WebCore.CSSCalc.CSSCalcSwiftParseCursor,
    _ builder: inout WebCore.CSSCalc.CSSCalcSwiftBuilder,
    _ options: WebCore.CSSCalc.CSSCalcSwiftParseOptions,
    _ simplificationOptions: WebCore.CSSCalc.CSSCalcSwiftSimplificationOptions,
    _ simplify: Bool,
    _ capacity: Int,
    _ state: inout CalcParseState
) -> CalcParseAttempt {
    let end = cursor.tokenCount()
    return withTemporaryAllocation(of: CalcFlatNode.self, capacity: capacity) { out -> CalcParseAttempt in
        var attempt = CalcParseAttempt()
        var index: UInt32 = 0
        calcSkipWhitespace(cursor, &index, end, &state)

        // The top-level function, which `parseAndSimplify` reads before it hands the inner range
        // over: `calc()` and `-webkit-calc()` have a bare `<calc-sum>` body, and every other
        // covered math function has one of the argument grammars. All at depth 0, matching
        // `parseCalcFunction(tokens, function, 0, state)` (`CSSCalcTree+Parser.cpp:194`) -- not the
        // block case's `depth + 1`, a divergence only a 100-deep expression would show.
        let descent: CalcParsed?
        if let rootFunction = calcParseFunctionAlternative(options.rootFunctionId) {
            switch rootFunction.arguments {
            case .oneOrMore:
                descent = calcParseArgumentList(cursor, &index, end, 0, &out, options, &state, rootFunction.alternative)
            case .exactlyOne:
                descent = calcParseUnaryFunction(cursor, &index, end, 0, &out, options, &state, rootFunction.alternative)
            case .clamp:
                descent = calcParseClamp(cursor, &index, end, 0, &out, options, &state)
            case .oneOrTwo:
                descent = calcParseOneOrTwoArguments(cursor, &index, end, 0, &out, options, &state, rootFunction.alternative)
            case .round:
                descent = calcParseRound(cursor, &index, end, 0, &out, options, &state)
            case .exactlyTwo:
                descent = calcParseTwoArguments(cursor, &index, end, 0, &out, options, &state, rootFunction.alternative)
            case .progress:
                descent = calcParseProgress(cursor, &index, end, 0, &out, options, &state)
            }
        } else if options.rootFunctionId == UInt16(WebCore.CSSValueCalc.rawValue)
            || options.rootFunctionId == UInt16(WebCore.CSSValueWebkitCalc.rawValue) {
            descent = calcParseSum(cursor, &index, end, 0, &out, options, &state)
        } else {
            // A top-level math function this grammar does not cover. `parseAndSimplify` accepts any
            // `isCalcFunction` at the top (`CSSCalcTree+Parser.cpp:171`-`:175`) and hands this
            // entry the range inside it, so for `hypot(3px, 4px)` the range is `3px, 4px`; falling
            // through to `<calc-sum>` would parse `3px` and stop at the comma, and for a
            // one-argument form such as `atan(e - 2.7182818284590452354)` would run to the end and
            // report the argument as the whole parse where the C++ builds an `Atan` over it. The
            // fall-through is correct only for `calc()` and `-webkit-calc()`.
            state.declined = true
            state.declineReason = .MathFunction
            descent = nil
        }

        guard let parsed = descent else {
            // A descent that stopped with the buffer full is an overflow rather than a rejection.
            attempt.overflowed = out.count >= out.capacity
            return attempt
        }

        // `parseCalcFunction` requires the inner range to be exhausted -- extraneous tokens are a
        // failure, not a decline.
        calcSkipWhitespace(cursor, &index, end, &state)
        if index != end {
            return attempt
        }

        // `out.count` into a local first: `mutableSpan` is a mutating accessor, so reading the count
        // in the same expression is two overlapping accesses to `out` and the exclusivity checker
        // rejects it.
        let written = out.count
        var tree = CalcFlatTree(storage: out.mutableSpan, count: written)

        if simplify {
            let simplification = CalcSimplification(
                percentageResolveToDimension: simplificationOptions.percentageResolveToDimension,
                allowZeroValueLengthRemovalFromSum: simplificationOptions.allowZeroValueLengthRemovalFromSum,
                category: simplificationOptions.category
            )
            guard tree.simplifyParsed(simplification, builder) else {
                attempt.foldRefused = true
                return attempt
            }
        }

        guard tree.emitParsedRoot(Int(parsed.index), into: &builder) else {
            attempt.emitRefused = true
            return attempt
        }

        let stored = builder.takeFlatNodes(tree.nodes.span.extracting(0..<tree.count), UInt32(parsed.index))
        // The crossing is asserted, not trusted. A `takeFlatNodes` that stored a different number of
        // nodes than were handed to it is a boundary defect, and reporting it as a refusal makes
        // the negative control -- poison `takeFlatNodes` -- fail the differential instead of
        // producing a quietly truncated tree.
        if stored != tree.count {
            attempt.emitRefused = true
            return attempt
        }

        attempt.type = parsed.type
        return attempt
    }
}

/// Rebuild a `CSSCalc::Child` from a stored flat tree, reading it back one node at a time by value.
///
/// Two things at once:
///
///  * It is the only thing that makes the store observable. `takeFlatNodes` could store nothing, or
///    half the tree, or the wrong root, and a differential that compares the `Child` the emit built
///    directly would still pass. Reading the store back and emitting from that puts the whole
///    crossing under test.
///  * It is the materialising fallback a consumer that has not been ported needs, so it can keep
///    reading `Child` off a `Value` that stores the flat form.
///
/// The read is per element by value, which is `CSSCalcSwiftParseCursor::tokenAt`'s shape at 40 bytes
/// instead of 24, and it is what keeps this file free of `unsafe`: Swift cannot receive a
/// bounds-carrying view from C++ at all (rdar://186723514), so no `Span` of the store's buffer can
/// cross. The nodes are copied into the same kind of stack buffer the parse already uses, and the
/// existing `emitParsedRoot` runs over it unchanged.
@_expose(Cxx)
public func cssCalcSwiftEmitFromStore(
    _ builder: inout WebCore.CSSCalc.CSSCalcSwiftBuilder,
    _ rootIndex: UInt32
) -> Bool {
    let count = Int(builder.flatNodeCount())
    guard count > 0, rootIndex != CalcFlatNode.noNode, Int(rootIndex) < count else {
        return false
    }
    return withTemporaryAllocation(of: CalcFlatNode.self, capacity: count) { out -> Bool in
        var i: UInt32 = 0
        while i < UInt32(count) {
            out.append(builder.flatNodeAt(i))
            i &+= 1
        }
        let tree = CalcFlatTree(storage: out.mutableSpan, count: count)
        return tree.emitParsedRoot(Int(rootIndex), into: &builder)
    }
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

// MARK: - The `Type` algebra differential

/// A test-only exhaustive differential over the two `Type`-algebra implementations, driven entirely
/// from Swift.
private struct CalcTypeAlgebraDifferential {

    // The counters, in the order `cssCalcTypeAlgebraDifferentialCounter` reports them. Every one of
    // these exists to make a specific way of measuring nothing fail loudly rather than pass; the
    // vacuity each answers is named at its declaration.
    var universeCount = 0            // 0
    var extremalCount = 0            // 1  V4: axis 2 present at all
    var multiplyCases = 0            // 2  V5: assert the case count, never the exit status
    var multiplyMismatches = 0       // 3
    var invertCases = 0              // 4
    var invertMismatches = 0         // 5
    var multiplyBothEngaged = 0      // 6  V1: an all-`nil` sweep compares one bit and nothing else
    var distinctInputs = 0           // 7  V3: a universe that collapsed to the default value
    var distinctMultiplyResults = 0  // 8  V3
    var hintConflictInputs = 0       // 9  V4: the hint-conflict exit
    var overflowInputs = 0           // 10 V4: the overflow exit -- LIVE ONLY ON AXIS 2
    var hintPropagatedInputs = 0     // 11 V4: step 2's propagation, the NC-B2 path
    var invertMinExponentInputs = 0  // 12 V4: the `0 &- (-128)` lane, LIVE ONLY ON AXIS 2
    var byteVersusEqualsDisagreements = 0 // 13 the `Type`-has-no-padding cross-check

    var addCases = 0                 // 15
    var addMismatches = 0            // 16
    var addCppEngaged = 0            // 17 V1 for `add`
    var addCppHintChanged = 0        // 18 V4: ONLY the provisional-hint branch can set a hint
    var sameTypeMismatches = 0       // 19
    var madeConsistentMismatches = 0 // 20
    var madeConsistentCppEngaged = 0 // 21 V1
    var consistentTypeMismatches = 0 // 22
    var applyHintCases = 0           // 23 V5
    var applyHintMismatches = 0      // 24
    var applyHintOverflowInputs = 0  // 25 V4: the `&+` lane of `applyPercentHint`, AXIS 2 ONLY
    var applyHintOutOfRangeCases = 0 // 26 V4: the `default:` case, which aliases onto `length`
    var mergeCouldCopyInputs = 0     // 27 pairs where `add`'s merge loop could actually copy a lane

    /// The 8 bytes of a `Type` as one integer: the verdict's cross-check, and the key the distinct
    /// counts are taken over.
    static func encode(_ t: CalcType) -> UInt64 {
        var bits: UInt64 = 0
        bits |= UInt64(UInt8(bitPattern: t.length)) << 0
        bits |= UInt64(UInt8(bitPattern: t.angle)) << 8
        bits |= UInt64(UInt8(bitPattern: t.time)) << 16
        bits |= UInt64(UInt8(bitPattern: t.frequency)) << 24
        bits |= UInt64(UInt8(bitPattern: t.resolution)) << 32
        bits |= UInt64(UInt8(bitPattern: t.flex)) << 40
        bits |= UInt64(UInt8(bitPattern: t.percent)) << 48
        bits |= UInt64(percentHintRawValue(t.percentHint)) << 56
        return bits
    }

    /// The reachable set: what the parser and simplifier can actually build.
    static func reachableUniverse() -> [CalcType] {
        let seeds: [CalcType] = [
            CalcType.makeNumber(), CalcType.makeLength(), CalcType.makeAngle(), CalcType.makeTime(),
            CalcType.makeFrequency(), CalcType.makeResolution(), CalcType.makeFlex(), CalcType.makePercent(),
        ]
        let hints: [WebCore.CSSCalc.PercentHint] = [.Length, .Angle, .Time, .Frequency, .Resolution, .Flex]

        var seen = Set<UInt64>()
        var universe: [CalcType] = []
        func add(_ t: CalcType) {
            if seen.insert(encode(t)).inserted {
                universe.append(t)
            }
        }
        for seed in seeds {
            add(seed)
            for hint in hints {
                var hinted = seed
                hinted.applyPercentHint(hint)
                add(hinted)
            }
        }
        // One closure round through the C++, so the closure itself cannot be biased by the code
        // under test.
        let base = universe
        for a in base {
            add(CalcType.invert(a))
            for b in base {
                if let product = CalcType.multiply(a, b).value {
                    add(product)
                }
            }
        }
        return universe
    }

    /// The parameter boundary, which the reachable set can never produce.
    static func extremalUniverse() -> [CalcType] {
        let edges: [Int8] = [-128, -127, -1, 0, 1, 126, 127]
        var seen = Set<UInt64>()
        var universe: [CalcType] = []
        func add(_ t: CalcType) {
            if seen.insert(encode(t)).inserted {
                universe.append(t)
            }
        }
        for e in edges {
            for lane in 0..<7 {
                var t = CalcType()
                switch lane {
                case 0: t.length = e
                case 1: t.angle = e
                case 2: t.time = e
                case 3: t.frequency = e
                case 4: t.resolution = e
                case 5: t.flex = e
                default: t.percent = e
                }
                add(t)
                var hinted = t
                hinted.applyPercentHint(.Length)
                add(hinted)
            }
            // Two saturated lanes, so an overflow in one lane cannot be confused with an early exit.
            var pair = CalcType()
            pair.length = e
            pair.percent = e
            add(pair)
            var all = CalcType()
            all.length = e; all.angle = e; all.time = e; all.frequency = e
            all.resolution = e; all.flex = e; all.percent = e
            add(all)
        }
        return universe
    }

    /// Whether the C++ `multiply` must refuse this pair for overflow, computed in `Int` by a third
    /// implementation that cannot overflow at all.
    static func overflowsIndependently(_ a: CalcType, _ b: CalcType) -> Bool {
        let lanes: [(Int8, Int8)] = [
            (a.length, b.length), (a.angle, b.angle), (a.time, b.time), (a.frequency, b.frequency),
            (a.resolution, b.resolution), (a.flex, b.flex), (a.percent, b.percent),
        ]
        for (x, y) in lanes {
            let sum = Int(x) + Int(y)
            if sum < -128 || sum > 127 {
                return true
            }
        }
        return false
    }

    mutating func run() {
        let universe = Self.reachableUniverse() + Self.extremalUniverse()
        universeCount = Self.reachableUniverse().count
        extremalCount = Self.extremalUniverse().count

        var inputKeys = Set<UInt64>()
        var resultKeys = Set<UInt64>()
        for t in universe {
            inputKeys.insert(Self.encode(t))
        }
        distinctInputs = inputKeys.count

        for a in universe {
            // `invert` -- total, so engagement cannot differ and the verdict is the value.
            let cppInverted = calcTypeInvert(a, .cpp)
            let swiftInverted = calcTypeInvert(a, .swift)
            invertCases += 1
            if !(cppInverted == swiftInverted) {
                invertMismatches += 1
            }
            if Self.encode(cppInverted) != Self.encode(swiftInverted) {
                if cppInverted == swiftInverted {
                    byteVersusEqualsDisagreements += 1
                }
            } else if !(cppInverted == swiftInverted) {
                byteVersusEqualsDisagreements += 1
            }
            if a.length == Int8.min || a.angle == Int8.min || a.time == Int8.min
                || a.frequency == Int8.min || a.resolution == Int8.min || a.flex == Int8.min
                || a.percent == Int8.min {
                invertMinExponentInputs += 1
            }

            for b in universe {
                multiplyCases += 1
                let cppProduct = CalcType.multiply(a, b).value
                let swiftProduct = a.multiplied(by: b)

                switch (cppProduct, swiftProduct) {
                case (nil, nil):
                    break
                case let (cpp?, swift?):
                    multiplyBothEngaged += 1
                    resultKeys.insert(Self.encode(cpp))
                    let equalByOperator = cpp == swift
                    let equalByBytes = Self.encode(cpp) == Self.encode(swift)
                    if !equalByOperator {
                        multiplyMismatches += 1
                    }
                    if equalByOperator != equalByBytes {
                        byteVersusEqualsDisagreements += 1
                    }
                default:
                    multiplyMismatches += 1
                }

                if a.hasPercentHint && b.hasPercentHint && !(a.percentHint == b.percentHint) {
                    hintConflictInputs += 1
                } else if a.hasPercentHint != b.hasPercentHint {
                    hintPropagatedInputs += 1
                }
                if Self.overflowsIndependently(a, b) {
                    overflowInputs += 1
                }
            }
        }
        distinctMultiplyResults = resultKeys.count

        let hints: [WebCore.CSSCalc.PercentHint] = [
            .Length, .Angle, .Time, .Frequency, .Resolution, .Flex,
            WebCore.CSSCalc.PercentHint(rawValue: 99)!,
        ]
        for t in universe {
            for (index, hint) in hints.enumerated() {
                applyHintCases += 1
                if index == 6 {
                    applyHintOutOfRangeCases += 1
                }
                let cpp = calcTypeApplyPercentHint(t, hint, .cpp)
                let swift = calcTypeApplyPercentHint(t, hint, .swift)
                if !(cpp == swift) {
                    applyHintMismatches += 1
                }
                if (Self.encode(cpp) == Self.encode(swift)) != (cpp == swift) {
                    byteVersusEqualsDisagreements += 1
                }
                let lane: Int8
                switch index {
                case 1: lane = t.angle
                case 2: lane = t.time
                case 3: lane = t.frequency
                case 4: lane = t.resolution
                case 5: lane = t.flex
                default: lane = t.length
                }
                let sum = Int(lane) + Int(t.percent)
                if sum < -128 || sum > 127 {
                    applyHintOverflowInputs += 1
                }
            }
        }

        for a in universe {
            for b in universe {
                addCases += 1

                let cppSum = calcTypeAdd(a, b, .cpp)
                let swiftSum = calcTypeAdd(a, b, .swift)
                switch (cppSum, swiftSum) {
                case (nil, nil):
                    break
                case let (cpp?, swift?):
                    addCppEngaged += 1
                    if !(cpp == swift) {
                        addMismatches += 1
                    }
                    // Read off the C++ alone: a result whose hint matches neither operand's can
                    // only have come from the provisional-hint branch, because the first branch
                    // returns `type1`'s hint after step 2 made the two agree.
                    if !(cpp.percentHint == a.percentHint) && !(cpp.percentHint == b.percentHint) {
                        addCppHintChanged += 1
                    }
                default:
                    addMismatches += 1
                }

                // `consistentType` is `add` in both implementations, so this is a cheap check that
                // the two entry points did not drift apart, not a second sweep of the algebra.
                switch (calcTypeConsistentType(a, b, .cpp), calcTypeConsistentType(a, b, .swift)) {
                case (nil, nil): break
                case let (cpp?, swift?): if !(cpp == swift) { consistentTypeMismatches += 1 }
                default: consistentTypeMismatches += 1
                }

                // Is `add`'s merge loop ("copy all of type2's entries that finalType doesn't
                // already contain") able to copy anything at all? It runs only after
                // `allNonZeroValuesEqual` has passed both ways, which forces every non-zero lane of
                // one operand to equal the other's -- so a lane that is zero in type1 and non-zero
                // in type2 would have failed the second call. Computed here in plain `Int` over the
                // raw operands (step 2 touches only `percentHint`, never a lane), so it shares no
                // code with either implementation. Expected 0: the loop is dead under its own
                // precondition.
                let la = [Int(a.length), Int(a.angle), Int(a.time), Int(a.frequency),
                          Int(a.resolution), Int(a.flex), Int(a.percent)]
                let lb = [Int(b.length), Int(b.angle), Int(b.time), Int(b.frequency),
                          Int(b.resolution), Int(b.flex), Int(b.percent)]
                var equalBothWays = true
                var couldCopy = false
                for k in 0..<7 {
                    if la[k] != 0 && la[k] != lb[k] { equalBothWays = false }
                    if lb[k] != 0 && lb[k] != la[k] { equalBothWays = false }
                    if la[k] == 0 && lb[k] != 0 { couldCopy = true }
                }
                if equalBothWays && couldCopy {
                    mergeCouldCopyInputs += 1
                }

                switch (calcTypeSameType(a, b, .cpp), calcTypeSameType(a, b, .swift)) {
                case (nil, nil): break
                case let (cpp?, swift?): if !(cpp == swift) { sameTypeMismatches += 1 }
                default: sameTypeMismatches += 1
                }

                switch (calcTypeMadeConsistent(a, b, .cpp), calcTypeMadeConsistent(a, b, .swift)) {
                case (nil, nil): break
                case let (cpp?, swift?):
                    madeConsistentCppEngaged += 1
                    if !(cpp == swift) { madeConsistentMismatches += 1 }
                default: madeConsistentMismatches += 1
                }
            }
        }
    }
}

/// Run the `Type`-algebra differential and return one counter; `which == 13` is the total mismatch
/// count and is the verdict.
@_expose(Cxx)
public func cssCalcTypeAlgebraDifferential(_ which: UInt32) -> UInt64 {
    var r = CalcTypeAlgebraDifferential()
    r.run()
    switch which {
    case 0: return UInt64(r.universeCount)
    case 1: return UInt64(r.extremalCount)
    case 2: return UInt64(r.multiplyCases)
    case 3: return UInt64(r.multiplyMismatches)
    case 4: return UInt64(r.invertCases)
    case 5: return UInt64(r.invertMismatches)
    case 6: return UInt64(r.multiplyBothEngaged)
    case 7: return UInt64(r.distinctInputs)
    case 8: return UInt64(r.distinctMultiplyResults)
    case 9: return UInt64(r.hintConflictInputs)
    case 10: return UInt64(r.overflowInputs)
    case 11: return UInt64(r.hintPropagatedInputs)
    case 12: return UInt64(r.invertMinExponentInputs)
    case 13:
        return UInt64(r.multiplyMismatches + r.invertMismatches + r.addMismatches
            + r.sameTypeMismatches + r.madeConsistentMismatches + r.consistentTypeMismatches
            + r.applyHintMismatches + r.byteVersusEqualsDisagreements)
    case 14: return UInt64(r.byteVersusEqualsDisagreements)
    case 15: return UInt64(r.addCases)
    case 16: return UInt64(r.addMismatches)
    case 17: return UInt64(r.addCppEngaged)
    case 18: return UInt64(r.addCppHintChanged)
    case 19: return UInt64(r.sameTypeMismatches)
    case 20: return UInt64(r.madeConsistentMismatches)
    case 21: return UInt64(r.madeConsistentCppEngaged)
    case 22: return UInt64(r.consistentTypeMismatches)
    case 23: return UInt64(r.applyHintCases)
    case 24: return UInt64(r.applyHintMismatches)
    case 25: return UInt64(r.applyHintOverflowInputs)
    case 26: return UInt64(r.applyHintOutOfRangeCases)
    case 27: return UInt64(r.mergeCouldCopyInputs)
    default: return UInt64.max
    }
}

// MARK: - The parse path's token boundary, differential only

/// This exists to prove the boundary. `CSSCalcSwiftParseCursor` imports with zero `unsafe`
/// markers, which is the property the design turns on: the cursor is `SWIFT_SAFE`, and every token
/// crosses by value as a 24-byte POD carrying no pointer.
@_expose(Cxx)
public func cssCalcParseTokenChecksumSwift(_ cursor: WebCore.CSSCalc.CSSCalcSwiftParseCursor) -> UInt64 {
    var hash: UInt64 = 0xcbf29ce484222325

    @inline(always)
    func mix(_ value: UInt64) {
        hash = (hash ^ value) &* 0x100000001b3
    }

    let count = cursor.tokenCount()
    for i in 0...count {
        let token = cursor.tokenAt(i)
        mix(token.numericValue.bitPattern)
        mix(UInt64(token.id))
        mix(UInt64(token.functionId))
        mix(UInt64(token.delimiter))
        mix(UInt64(token.unit.rawValue))
        mix(UInt64(token.type.rawValue))
        mix(UInt64(token.blockType))
        // Folded so the field crosses under test at all. A field-sensitivity pair cannot isolate
        // `flags`, because it is a pure function of `unit` and `functionId`, which are folded
        // above: two inputs differing in `flags` necessarily differ in one of those too. The direct
        // checks in `webCoreCSSCalcCompareParse`'s self-tests are what cover it.
        mix(UInt64(token.flags))
    }
    return hash
}



#endif
