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
// and there is no accessor facade over it at all -- a node is a `Child` on both sides. The subscript
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
// simplification that cannot derive its answer sets `CalcFlatTree.declined`. That function's
// `@unknown default: return false` is why the list above can be stated as complete -- an
// alternative C++ adds later declines on its own rather than being mis-handled by a stale case
// list here.
//
// A node's own kind never crosses the boundary: `rebuildFrom` recovers it from the original node's
// variant tag.
//
// THE WALK IS FLAT AND SINGLE-PASS. `calcFlatten` copies the tree into one pre-order array of
// `CalcFlatNode` in a stack buffer, so a parent's index is always less than its children's; one
// backwards loop then simplifies every child before its parent, mutating nodes in place, and
// `emitRoot` walks the result forwards onto the builder's operand stack. The operand stack has no
// pop, which is why the simplification cannot push as it goes -- but the flat array can hold a
// simplified child, so nothing has to be decided twice.
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
// treat differently. So the boundary carries the variant's own alternative index (41 cases, pinned
// to `Node`'s alternative indices via `WTF::alternativeIndexV`), and this file imports that enum
// rather than mirroring it.
//
// THE SECOND HALF OF THAT SENTENCE USED TO READ "and a Swift file cannot name a `CSSValueID` to
// disambiguate further". IT IS FALSE, AND IT WAS FALSE FOR A REASON THAT WAS WEBKIT'S OWN. This
// file names `WebCore.CSSValueMin` directly (`calcParseFunctionAlternative` below).
//
// What was true, measured 2026-09-11 by probe E0 as a `-typecheck` replay of WebCore's own Swift
// step, is that no ENUMERATOR of `CSSValueID` imported while the type itself did. The cause is not
// Swift, not this enum's size and not C++ interop: an incomplete `enum X : uint16_t;` declaration
// parsed BEFORE the complete definition, anywhere in the same Clang module, makes the importer
// bring the type in with an EMPTY enumerator list. Twenty-two WebCore headers forward-declare
// `CSSValueID` that way, an `umbrella` directory is walked in filename order, and several of them
// sort before CSSValueKeywords.h. Listing that header ahead of the umbrella in
// `WebCore_Private.modulemap` parses it first and all 1322 enumerators import; only the FIRST
// declaration matters, so no forward declaration had to be touched. Reduced variants with both
// controls: `cssprobe/e0/twinorder/variants.py`.
//
// So the boundary's alternative index is still the right design for the first reason above -- `kind`
// conflates operations this file must treat differently -- but the function-identity channel it
// forced, a `CSSCalcSwiftAlternative` riding in `CSSCalcSwiftToken::id`, is GONE. `functionId`
// crosses raw and is compared against `CSSValueMin` here.
//
// STILL MISSING, and the one E0 defect with no WebKit-side fix: Swift imports no `static constexpr`
// DATA MEMBER of a C++ struct at all -- not an `int`, not a deduced `auto`, not an enum type
// (`cssprobe/e0/twin/statics.h`). That is why `WebCore.CSSCalc.Min.id`, which exists precisely to
// name this and sits right there at `CSSCalcTree.h:432`, does not import. It costs nothing here
// only because the enumerator it would have returned is now reachable directly.

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

// MARK: - The `Type` algebra: arm selection

/// Which implementation answers the css-typed-om `Type` algebra for THIS FILE's call sites. Both
/// are compiled in; this chooses which one, at compile time. Same arrangement as
/// `CSSCalc::Simplifier` and `CSSCalc::Serializer`, and for the same reason: the C++ stays in tree
/// and stays selectable, which is the schedule, and the differential names an arm EXPLICITLY
/// rather than taking `defaultTypeAlgebra`, so an ignored build flag cannot masquerade as a pass.
///
/// A Swift `enum` and a Swift `let`, and that is the point of this stage rather than an accident
/// of it: the selector costs **zero production C++**. `CSSCalcType.{h,cpp}` are byte-identical
/// before and after. The `Cpp` arm is not a fallback kept alive for the island -- it is the same
/// code the C++ parser, `CSSCalcTree.cpp`'s `toType` and CSS Typed OM's `CSSMathValue` already
/// call, so it cannot be deleted and does not need a guard.
///
/// R10 -- a gate selected in two places at once -- does NOT apply. `defaultTypeAlgebra` is a Swift
/// `let` in one whole-module-optimized module, not a C++ `static constexpr` used as a default
/// argument and therefore evaluated in each caller's translation unit.
private enum CalcTypeAlgebraArm {
    /// `CSSCalcType.cpp`, reached through the C++ interop boundary.
    case cpp
    /// The bodies below.
    case swift
}

/// The arm the production call sites take. **Flipping this one token is the differential's arm**,
/// in the same way every other `validate/arms/*.patch` in this port is one token or one block.
///
/// Deliberately NOT an xcconfig flag. `USE_SWIFT_CSS_CALC_SIMPLIFICATION` exists because a C++
/// caller outside this file has to pick the simplifier; nothing outside this file picks the type
/// algebra, so a build-system knob would be three lines of xcconfig buying nothing.
private let defaultTypeAlgebra = CalcTypeAlgebraArm.swift

// MARK: - The `Type` algebra in Swift

private extension CalcType {

    /// The C++'s `if (type.percentHint)` -- `PercentHintValue`'s `explicit operator bool`
    /// (`CSSCalcType.h:90`).
    ///
    /// A comparison against a default-constructed `PercentHintValue`, not a decode to `UInt8`.
    /// `PercentHintValue::m_value` is PRIVATE and nothing reads it; `percentHintRawValue` above
    /// needs six comparisons to get at it, and **the algebra never needs to**. Every operation
    /// here either COPIES a hint or tests two for equality, and the imported defaulted
    /// `operator==` (`CSSCalcType.h:89`) does both directly. That is why porting the algebra needs
    /// no accessor added to the C++ and no `unsafe`.
    @inline(always)
    var hasPercentHint: Bool {
        // `!(… == …)`, not `!=`. The imported defaulted `operator==` (`CSSCalcType.h:89`) gives
        // Swift `==` and NOT `!=`: C++20 synthesises the negation, the ClangImporter does not, and
        // the diagnostic is "binary operator '!=' cannot be applied" rather than anything naming
        // the rewrite rule.
        return !(percentHint == CalcType.PercentHintValue())
    }

    /// css-typed-om step 2, shared verbatim by "add two types" (`CSSCalcType.cpp:50`-`:60`) and
    /// "multiply two types" (`:124`-`:135`) -- the two C++ bodies are identical apart from a
    /// comment, and are written once here.
    ///
    /// `false` is the shared failure exit: both hints non-null and different. On `true` both types
    /// carry the same hint.
    ///
    /// The C++ writes `type2.percentHint = *type1.percentHint`, i.e. it unwraps to a `PercentHint`
    /// and lets the converting constructor re-wrap it. Assigning the `PercentHintValue` straight
    /// across is bit-identical -- the constructor is `static_cast<InternalValue>(hint)`
    /// (`CSSCalcType.h:84`-`:87`) and the source is non-null on that branch -- and it avoids the
    /// unwrap, which is the operation the private storage makes awkward.
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
    /// (`CSSCalcType.cpp:142`-`:144`). Not `&+`, which would silently wrap where the C++ REFUSES,
    /// and not `+`, which would TRAP where the C++ returns `std::nullopt` -- a Swift-only abort on
    /// input the C++ merely declines. Neither substitute is detectable on any tree the corpus
    /// builds; the extremal arm of the differential is what tests this lane.
    @inline(always)
    static func sumExponent(_ a: Int8, _ b: Int8, _ overflowed: inout Bool) -> Int8 {
        let (result, didOverflow) = a.addingReportingOverflow(b)
        overflowed = overflowed || didOverflow
        return result
    }

    /// `Type::multiply` (`CSSCalcType.cpp:110`-`:153`).
    ///
    /// The C++ adds the seven exponents in a loop over `allBaseTypes()` whose body is
    /// `operator[]`, a SEVEN-WAY SWITCH on a runtime index (`CSSCalcType.h:201`-`:231`) -- so the
    /// switch is a real branch on every one of the seven iterations, twice, once per operand.
    /// Written straight-line here over the named fields. **That is the same algorithm with the
    /// C++'s own loop unrolled**, not a different one: `allBaseTypes()` is a compile-time list and
    /// the field names ARE the enumeration, so Swift can spell what C++ needed a subscript for.
    /// It is also why this port needs no `Type::operator[]` equivalent and no index type.
    @inline(always)
    func multiplied(by other: CalcType) -> CalcType? {
        var type1 = self
        var type2 = other

        // Steps 2/3.
        guard Self.normalizePercentHints(&type1, &type2) else {
            return nil
        }

        // Step 4.
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

        // "Set finalType's percent hint to type1's percent hint." (`:148`-`:149`) -- type1's, after
        // step 2 has already made the two agree.
        finalType.percentHint = type1.percentHint

        // Step 5.
        return finalType
    }

    /// `Type::invert` (`CSSCalcType.cpp:155`-`:170`).
    ///
    /// `0 &- exponent`, NOT `-exponent`, and this is a correctness point rather than a style one.
    /// The C++ is `result[unit] = -1 * type[unit]`: the operand promotes to `int`, multiplies, and
    /// NARROWS back to `int8_t`. For -128 that is 128 narrowed, which on every target WebKit ships
    /// is -128. Swift's unary `-` on `Int8` TRAPS on -128, so the literal translation would turn a
    /// defined C++ answer into an abort. `&-` reproduces the C++ bit for bit and adds no trap
    /// condition to the census.
    ///
    /// -128 IS reachable: `multiply` admits any sum that fits in `Int8`, so two `Product`s of
    /// exponent -64 get there, and `invert` is then called on the result by step 9.4's `Invert`
    /// arm. Not reachable from the corpus, which is why the differential carries an extremal set
    /// the corpus cannot produce.
    @inline(always)
    func inverted() -> CalcType {
        // "Let result be a new type with an initially empty ordered map and a percent hint matching
        // that of type." (`:160`-`:162`)
        var result = CalcType()
        result.percentHint = percentHint

        // "For each unit -> exponent of type, set result[unit] to (-1 * exponent)." (`:164`-`:166`)
        result.length = 0 &- length
        result.angle = 0 &- angle
        result.time = 0 &- time
        result.frequency = 0 &- frequency
        result.resolution = 0 &- resolution
        result.flex = 0 &- flex
        result.percent = 0 &- percent

        return result
    }

    /// The C++'s `hasNonPercentEntry()` (`CSSCalcType.h:196`-`:199`), which is already written
    /// straight-line there rather than as a loop -- so this one is a transliteration, not an
    /// unrolling.
    @inline(always)
    var containsNonPercentEntry: Bool {
        return length != 0 || angle != 0 || time != 0 || frequency != 0 || resolution != 0 || flex != 0
    }

    /// `Type::applyPercentHint` (`CSSCalcType.h:263`-`:277`), as a value-returning form.
    ///
    /// `&+`, NOT `+`, AND THIS IS THE THIRD ARITHMETIC HAZARD OF THE STAGE. The C++ is
    /// `(*this)[hint] += (*this)[BaseType::Percent]` on an `int8_t`: the operands promote to `int`,
    /// add, and narrow back, so 127 + 127 is 254 narrowed, which on every target WebKit ships is
    /// -2. Swift's `+` on `Int8` TRAPS there, turning a defined C++ answer into an abort. Reachable
    /// only with saturated lanes, which is why the differential carries an extremal set.
    ///
    /// THE `default` ARM IS NOT DEAD AND MUST ALIAS TO `length`. The C++ indexes through
    /// `operator[](PercentHint)` (`CSSCalcType.h:232`-`:245`), whose switch falls out to
    /// `return length` for a value outside the enum -- `ASSERT_NOT_REACHED_UNDER_CONSTEXPR_CONTEXT`
    /// is a no-op in a Release build. An imported C++ enum's `init?(rawValue:)` never fails, so an
    /// out-of-range hint IS constructible in Swift, and `percentageLeafType`'s own comment already
    /// warns that such a value aliases onto `length`. Matching the C++ here is what keeps that
    /// warning true.
    @inline(always)
    func withPercentHintApplied(_ hint: WebCore.CSSCalc.PercentHint) -> CalcType {
        var result = self
        // Step 1 needs no work: "doesn't contain" is represented as 0.
        // Step 2: add `percent` into the hinted lane, then zero `percent`.
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
        // Step 3.
        result.percentHint = CalcType.PercentHintValue(hint)
        return result
    }

    /// `Type::allNonZeroValuesEqual` (`CSSCalcType.h:279`-`:289`), unrolled over the seven lanes.
    ///
    /// The C++ loops `allBaseTypes()` and indexes with `operator[]`, a seven-way switch on a runtime
    /// index, so it runs that switch seven times per call and `add` calls this up to fourteen times.
    /// Written out, it is seven compares.
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
    /// entries that finalType doesn't already contain" (`CSSCalcType.cpp:66`-`:71`, and again at
    /// `:87`-`:92` -- the C++ writes it twice, this is written once).
    ///
    /// `self` is type1, so the percent hint comes across with it, which is what the C++'s
    /// `finalType = type1` does. The provisional-hint branch overwrites it afterwards.
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
    ///
    /// The C++ applies the hint to `type1` and `type2` IN PLACE, tests, and reverts from copies it
    /// took at the top of the iteration. Taking the copies forward instead of reverting is the same
    /// computation with the bookkeeping removed -- there is nothing to revert if nothing was
    /// mutated -- and it is why this port has six calls where the C++ has a loop with a rollback.
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
    /// DELIBERATE SPEC DEVIATION, MIRRORING THE C++ IT REPLACES -- do not "fix" this against the
    /// spec. css-typed-om's "apply the percent hint" is three steps; `CSSCalcType.cpp:56`/`:59`
    /// performs only the third (assign the hint; do NOT fold `percent` into the hinted lane), and
    /// step 3's first branch then compares the UN-APPLIED types at `:65`. This port must match that
    /// or the Stage B differential reports a correct port as wrong. The deviation is a real WebCore
    /// bug -- web-visible through Typed OM, whose `CSSNumericType::multiplyTypes` has the same
    /// omission: see `cssprobe/notes/webkit-bug-tocss-empty-optional-0909.md` "Bug 3".
    /// WHEN THAT BUG IS FIXED, THIS COMMENT AND `normalizePercentHints` CHANGE TOGETHER.
    ///
    /// `add`'s own omission is MASKED on spec-legal input by the provisional-hint search below,
    /// which re-derives the application step 2 should have made -- which is very likely why nobody
    /// noticed. It is unmasked only by a `Type` carrying both a non-null hint and a non-zero
    /// `percent` lane, a state the spec forbids and `multiply`'s omission produces.
    func added(to other: CalcType) -> CalcType? {
        var type1 = self
        var type2 = other

        // Step 2, shared verbatim with `multiplied(by:)`.
        guard CalcType.normalizePercentHints(&type1, &type2) else {
            return nil
        }

        // Step 3, first branch (`:64`-`:73`).
        if type1.nonZeroValuesEqual(type2) && type2.nonZeroValuesEqual(type1) {
            return type1.mergingAbsentLanes(from: type2)
        }

        // Step 3, second branch (`:75`-`:103`). The guard is the C++'s own, and it is what keeps
        // the six-hint search off every pair that cannot benefit from it.
        guard (type1.percent != 0 || type2.percent != 0)
            && (type1.containsNonPercentEntry || type2.containsNonPercentEntry) else {
            return nil
        }

        // `allPotentialPercentHintTypes()` unrolled. Six calls rather than a loop over a container:
        // a `Swift.Array` literal here is a heap allocation and a release per call on a path
        // `consistentType` reaches per node, and an `InlineArray` subscript would add a bounds
        // check to a census this stage is required not to move.
        if let merged = CalcType.addUnderHint(.Length, type1, type2) { return merged }
        if let merged = CalcType.addUnderHint(.Angle, type1, type2) { return merged }
        if let merged = CalcType.addUnderHint(.Time, type1, type2) { return merged }
        if let merged = CalcType.addUnderHint(.Frequency, type1, type2) { return merged }
        if let merged = CalcType.addUnderHint(.Resolution, type1, type2) { return merged }
        if let merged = CalcType.addUnderHint(.Flex, type1, type2) { return merged }

        // "If the loop finishes without returning finalType, then the types can't be added."
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
        // 1.
        if hasPercentHint && input.hasPercentHint && !(percentHint == input.percentHint) {
            return nil
        }
        // 2.
        var base = self
        if !base.hasPercentHint {
            base.percentHint = input.percentHint
        }
        // 3.
        return base
    }

    // MARK: `validateType`, as the three predicates the math functions actually ask for
    //
    // `TypeMatcher<M...>::matchesAny` (`CSSCalcType.h:290`-`:361`) is a template whose whole body
    // is `if constexpr`: `computeCheck<match>()` is decided at compile time for each of the seven
    // base types, so the run-time content of an instantiation is seven comparisons and, when
    // `Match::Number` is one of the arguments, no `foundMatch` test at all. Instantiated by hand
    // here, once per policy, which is what a template argument list is. There is no run-time
    // `AllowedTypes` value in this port and no switch on one -- `Op::input` is a compile-time
    // constant on the C++ side too, and `validateType<AllowedTypes::Any>` is `return true`, which
    // is why `abs()` and `sign()` ask nothing below.
    //
    // Every one of the three is called with the C++'s `{ .allowsPercentHint = true }`, which is the
    // only matching context any math function uses (`CSSCalcType.h:388`, `:390`), so the
    // `percentHint` half of `Type::matchesAny` (`:369`-`:372`) is skipped rather than omitted.

    /// `matchesAny<Match::Number>({ .allowsPercentHint = true })`.
    ///
    /// `Number` is not a base type, so `computeCheck` answers `MustBeZero` for all seven lanes, and
    /// `containsMatch<Number>()` then makes the `foundMatch` test unconditionally true. Seven zeros.
    @inline(always)
    var matchesNumber: Bool {
        return length == 0 && angle == 0 && time == 0 && frequency == 0
            && resolution == 0 && flex == 0 && percent == 0
    }

    /// `matchesAny<Match::Number, Match::Angle>({ .allowsPercentHint = true })`.
    ///
    /// Two match arguments, so `Angle` is `MustBeOneOrZero` rather than `MustBeOne`, and `Number`
    /// again waives `foundMatch`. A bare `<number>` and a bare `<angle>` both pass; `1deg * 1deg`
    /// (angle exponent 2) does not.
    @inline(always)
    var matchesNumberOrAngle: Bool {
        return (angle == 0 || angle == 1) && length == 0 && time == 0 && frequency == 0
            && resolution == 0 && flex == 0 && percent == 0
    }

    /// `matchesAny<Match::Angle>({ .allowsPercentHint = true })`, the `Deg2Rad` condition at
    /// `CSSCalcTree+Parser.cpp:312`.
    ///
    /// ONE match argument, so `Angle` is `MustBeOne` and `foundMatch` is NOT waived -- which is
    /// exactly what separates this from `matchesNumberOrAngle`: `sin(0.5)` matches that and not
    /// this, and gets no `Deg2Rad` wrapper.
    @inline(always)
    var matchesAngle: Bool {
        return angle == 1 && length == 0 && time == 0 && frequency == 0
            && resolution == 0 && flex == 0 && percent == 0
    }
}

/// `Type::multiply` through the selected arm.
///
/// `@inline(always)` with a constant `arm` folds the switch away, so the `Cpp` arm costs exactly
/// the call it costs today and the `Swift` arm costs no dispatch. `@inline(always)`, never
/// `@inline(__always)`: the underscored spelling is silently declined on exactly the bodies where
/// it matters.
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

/// `Type::invert` through the selected arm.
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

/// `Type::add` through the selected arm.
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

/// `Type::consistentType` through the selected arm.
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

/// `Type::sameType` through the selected arm. NO PRODUCTION CALLER IN THE ISLAND TODAY -- it exists
/// for `mergeTypes<MergePolicy::Same>` at step B6, and is ported now because the differential covers
/// it for free alongside `add`, whose input universe it shares.
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

/// `Type::madeConsistent` through the selected arm. Also no production caller yet; same reason.
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

/// `Type::applyPercentHint` through the selected arm, as a value-returning form so both arms have
/// the same shape. The C++ member is `constexpr` and mutating, so the `cpp` arm copies first.
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
/// since `+` is not associative -- `simplifySum` accumulates in child order for that reason.
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
    ///
    /// `isFinite`, not `!isInfinite`, in this and the three below -- and the C++ was changed in the
    /// same commit, so this is still a transcription rather than a divergence. The two differ only
    /// at NaN, which css-values-4 excludes from the branch ("If A is FINITE but B is infinite") and
    /// which then reached a `signbit` IEEE 754-2019 §6.3 leaves unspecified. See the block comment
    /// above `OperatorExecutor<Operator::RoundNearest>` for the whole finding.
    @inline(always)
    static func roundNearest(_ valueToRound: Double, _ roundingInterval: Double) -> Double {
        // `if (std::isfinite(valueToRound) && std::isinf(roundingInterval)) return std::signbit(valueToRound) ? -0.0 : +0.0;`
        if valueToRound.isFinite && roundingInterval.isInfinite {
            return valueToRound.sign == .minus ? -0.0 : 0.0
        }
        let (lower, upper) = nearestMultiples(valueToRound, roundingInterval)
        // `return std::abs(upper - valueToRound) <= std::abs(roundingInterval) / 2 ? upper : lower;`
        return (upper - valueToRound).magnitude <= roundingInterval.magnitude / 2 ? upper : lower
    }

    /// `OperatorExecutor<Operator::RoundUp>` (CSSCalcExecutor.h:252-:267).
    @inline(always)
    static func roundUp(_ valueToRound: Double, _ roundingInterval: Double) -> Double {
        if valueToRound.isFinite && roundingInterval.isInfinite {
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

// MARK: - The coverage predicate

/// Whether this file can simplify a node of this alternative with this many children. The child
/// count is part of the check: the boundary reads `childCount` and asks `rebuildFrom` to consume
/// exactly that many operands, so a mismatched count would fill the wrong slots.
///
/// `calcFlatten` is the traversal that asks it: there is no separate coverage walk, because a second
/// pass over the same nodes meant a second `swiftNodeInfo` crossing for an answer the first one
/// already had.
/// `@inline(always)` because it has two call sites since `calcFlattenNode` was split out, and the
/// optimizer's answer to two was to OUTLINE it: the leaf fast path grew a `bl` and, worse, kept all
/// seven `stp`/`ldp` pairs in `calcFlatten`'s frame because every field of `info` then had to
/// survive a call. Inlined it is a range test and a jump table, and the leaf path makes no call at
/// all after `swiftNodeInfo`.
@inline(always)
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
        // admits; whether `kind` agrees on WHICH bound is `none` is checked separately in `simplifyClamp`.
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
        // `simplifyAnchorFunction`, which is the only place both halves are in scope. Both are `IndirectNode`s
        // with slots, so `rebuildFrom` fills them via its two hand-written arms.
        return alternative == .Anchor ? childCount <= 2 : childCount <= 1

    @unknown default:
        // An alternative C++ grew and this file has not been taught. Declining is the only safe
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

}

// MARK: - The leaf type dispatch
//
// `getType` and the canonical-unit table, which every arm of the simplifier reaches and which are
// therefore stated once, here, rather than at each use.

private extension CalcSimplification {

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

}

// MARK: - `canonicalize`, and the relative lengths only the builder can resolve

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
//
// `hypot()`'s running type tag, the merge tables `min()`/`max()`/`Sum` key by unit identity, and the
// two predicates `Sum` and `Product` reach for. Declared apart from the pass that uses them because
// each states a C++ fact -- an encoding, a table size, an upcall's disagreement with `isLength` --
// that belongs in one place.

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

    // MARK: `hypot()`

    /// The tag transition itself, over a leaf the caller has already unwrapped.
    ///
    /// Takes the leaf rather than the child, so that the one transcription of
    /// `+Simplification.cpp:1216`-`:1264` serves whatever holds the child. A second copy of a
    /// five-state machine whose failure mode is a silently wrong `hypot()` is exactly the kind of
    /// duplication this file has been paying down.
    @inline(always)
    func hypotElement(_ leaf: NumericLeaf, _ tag: inout HypotTag) -> Double {
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
            // folded result's hint is stamped from the category. See `simplifyHypot`'s `.percentage`
            // arm.
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
            // Absorbing, and the loop keeps running. See `simplifyHypot`'s note on why this is not a
            // `return`.
            return Double.nan
        }
    }

    // MARK: the merge tables

    /// `std::array<size_t, numberOfNumericIdentityTypes> offsetOfFirstInstance` (`:414`), restored:
    /// the merge is keyed by unit identity in a compile-time fixed-size table, not by a per-term heap
    /// array. `MergeTable` holds `index + 1`, so 0 means no term of that unit has been seen -- the
    /// C++'s own encoding, which is what lets the whole table be zero-initialised.
    ///
    /// `UInt32` rather than `Int32`, which is what a node index is: the store side then spells the
    /// narrowing `UInt32(truncatingIfNeeded:)` instead of the trapping `Int32(_:)`, and the read side
    /// widens for free. See the store sites for the range argument.
    typealias MergeTable = InlineArray<128, UInt32>
    /// `FirstInstance::canRemove` (`:603`), one bit per unit identity. A separate table rather than a
    /// field beside the offset so the common (`Min`/`Max`) case pays for the offsets alone.
    typealias MergeFlags = InlineArray<128, Bool>

    // MARK: `Sum`'s zero-length removal

    /// `isLength(id) && options.allowZeroValueLengthRemovalFromSum` (`:611`). `.number`/`.percentage`
    /// never qualify; `.canonicalDimension` qualifies only for `Px`; `.nonCanonicalDimension` asks
    /// the real predicate. The flag is tested first so the work is skipped when it cannot be used,
    /// and the caller only reaches it for a merged value of exactly zero.
    ///
    /// `toNumericIdentity` and `isLength` are the C++ definitions, called directly rather than
    /// through an upcall: both are `constexpr` free functions over an enum, so they import, and the
    /// 48-of-64 membership set stays in CSSCalcTree+NumericIdentity.h where it always was. Nothing
    /// is transcribed here.
    ///
    /// The `Px` special case is stated once, here, because it is a disagreement rather than a
    /// detail: `toNumericIdentity(NonCanonicalDimension{...})` answers `Number` for
    /// `CSSUnitType::Px` and so returns FALSE for canonical px, where `isLength(PX)` in the C++ is
    /// true. `.value` is inert -- `toNumericIdentity` reads only `unit`.
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

/// Which alternatives the FLAT simplifier covers, as a mask over the same alternative index
/// `kindMask` is built from.
///
/// Built from the alternative list rather than written as a hex literal, so teaching the flat
/// simplifier a new alternative is one name added here and the two cannot drift: the raw values come
/// from the imported C++ enum, which is generated from `CSS_CALC_SWIFT_FOR_EACH_ALTERNATIVE`.
///
/// A computed `static var`, not a `static let` -- see `mask` itself. The claim that used to stand
/// here, that "every term is a compile-time constant so the optimizer folds the whole expression to
/// one immediate", was WRONG and is corrected at `bit`: the terms fold only while the chain is
/// small enough, and the shift spelling is what keeps it so.
///
/// `NonCanonicalDimension` is here because `simplifyNonCanonicalDimension` ports
/// `simplify(NonCanonicalDimension&)` (`+Simplification.cpp:506`-`:514`) in full, upcall included.
/// It was absent until then for a reason worth keeping in view: letting one through without
/// `canonicalize` would COPY the node where the C++ converts it -- a silent wrong answer rather than
/// a decline. Adding an alternative here means porting its `simplify`, not editing this list.
private enum CalcFlatCoverage {
    /// `&<<`, THE MASKING SHIFT, NOT `<<` -- and it is worth 31 retired instructions per
    /// simplification on EVERY band, measured.
    ///
    /// `UInt64`'s `<<` is the *smart* shift: it is defined for a negative or over-large amount, so
    /// it lowers to a branchy sequence (over-shift to zero, under-shift to zero, `and` by 63, then
    /// the shift) -- about eight basic blocks per term. `alternative.rawValue` is not folded at SIL
    /// level either, because it goes through `RawRepresentable`'s witness, so `mask` reaches LLVM as
    /// forty copies of that sequence chained by `or`. LLVM folds the chain while it is small and
    /// STOPS ABOVE A SIZE THRESHOLD, which is why this cost nothing at 27 terms, nothing at 35, and
    /// +31 instructions per simplification the moment batch E took it to 40 -- a step, not a slope,
    /// and the reason the "the optimizer folds the whole expression to one immediate" claim that
    /// used to stand here survived so long. `leaf` measured 603.3 at 35 terms, 634.3 at 40, and
    /// 603.2 with the five new folds present and their five bits withheld, which is the 2x2 that
    /// attributes it to the bits rather than to the folds.
    ///
    /// `&<<` deletes the branches: the shift amount is an alternative index, there are 41 of them,
    /// and 41 < 64, so masking by 63 is the identity and no defined behaviour changes. Not `unsafe`,
    /// not a trap removed -- a shift that cannot overflow, spelled as one.
    @inline(always)
    static func bit(_ alternative: CalcAlternative) -> UInt64 {
        return UInt64(1) &<< UInt64(alternative.rawValue)
    }

    /// A computed `static var`, not a `static let`: a stored global is lazily initialised behind a
    /// `swift_once` guard, which is an atomic load on every read -- and this is read once per node,
    /// by `CalcFlattenReport.sawAlternative`. Measured at 10 retired instructions per simplification
    /// when it was tried, against 0 for the computed form once `bit` stopped branching, which is
    /// what lets it fold into the immediate of `sawAlternative`'s single `tst`.
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
///
/// On `.simplified` the stack holds exactly one operand, the new root. On `.declined` the stack
/// holds whatever the abandoned emit left on it; `trySimplifyWithSwiftIsland` discards it unread and
/// runs the C++ path.
///
/// `kindMask` and `nodeCount` come from the flattening pass, which is also the coverage walk, because
/// they have to describe every tree the gate saw, including the ones it declined -- coverage measured
/// only on the cases that succeeded is not a coverage measurement. That is why `calcFlatten` keeps
/// crossing after it stops writing. Both are keyed on the alternative index (0 to 40), not on the 23
/// serialization kinds.
@_expose(Cxx)
public func cssCalcSimplifySwift(
    _ root: borrowing WebCore.CSSCalc.Child,
    _ builder: inout WebCore.CSSCalc.CSSCalcSwiftBuilder,
    _ options: WebCore.CSSCalc.CSSCalcSwiftSimplificationOptions
) -> WebCore.CSSCalc.CSSCalcSwiftSimplificationResult {
    // ONE `swiftNodeInfo` crossing for the root, taken HERE and threaded into whichever of the two
    // routes below the tree takes, so the split costs no extra crossing on either. The flat pass used
    // to make this call itself; `calcFlatten` now receives it.
    let rootInfo = WebCore.CSSCalc.swiftNodeInfo(root)

    // A ROOT THAT IS A NUMERIC LEAF WITH NO CHILDREN NEVER ENTERS THE FLAT MACHINERY.
    //
    // The flat representation exists so that a tree can be REWRITTEN: the stack buffer, the
    // `CalcFlattenReport`, the `OutputSpan` lifecycle, the reverse simplification scan and the
    // recursive emit are all there because a node's children may change shape and a parent has to see
    // them changed. A single numeric leaf is never rewritten structurally -- `simplify(Number&)`,
    // `simplify(Percentage&)` and `simplify(CanonicalDimension&)` are unconditional no-ops
    // (`+Simplification.cpp:486`-`:503`) and `simplify(NonCanonicalDimension&)` (`:505`) is a
    // value-for-value canonicalization -- so all of it is pure overhead on that shape. The C++ arm
    // does none of it: `copyAndSimplify(const Child&)` reads the variant tag once, into a
    // compile-time-specialised lambda, and constructs the answer in its caller's slot.
    //
    // NOT A CORNER CASE, and that is measured on the corpus rather than assumed. Of the 33 shapes in
    // `calc-shapes.tsv`, NINETEEN reach the island as one numeric leaf: the whole `leaf` band, the
    // whole `funcs` band -- the parser folds `min(1px, 2px)` to `calc(1px)` and `sin(30deg)` to
    // `calc(0.5)`, so that band exercises no math function in the simplifier at all -- and four of
    // `real`'s seven captured expressions, including all three `calc(100% / N)`.
    //
    // The four numeric leaves are named rather than "any childless alternative": `Symbol`,
    // `SiblingCount` and `SiblingIndex` are childless too, and each needs an upcall plus, when it
    // does not resolve, `emit`'s deep-copy-from-origin route. They stay on the flat path, where they
    // get the same answer they get today.
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
///
/// `@inline(always)`, so this is an early return out of the entry point and not a call. It therefore
/// shares that function's frame, INCLUDING `withTemporaryAllocation`'s 1000-byte `alloca` and the stack
/// protector the `alloca` forces -- an `alloca` lives in the entry block, so those are paid on every
/// path through the function that holds one, ~18 retired instructions this path does not use. Splitting
/// the flat pass out to escape them was measured and LOSES; see `calcSimplifyFlatTree`.
///
/// Nothing here allocates, nothing recurses, and no `CalcFlatNode` is ever written: the leaf lives in
/// registers from `swiftNodeInfo` to `pushLeaf`.
@inline(always)
private func calcSimplifyNumericLeafRoot(
    _ info: WebCore.CSSCalc.CSSCalcSwiftNodeInfo,
    _ options: WebCore.CSSCalc.CSSCalcSwiftSimplificationOptions,
    _ builder: inout WebCore.CSSCalc.CSSCalcSwiftBuilder
) -> WebCore.CSSCalc.CSSCalcSwiftSimplificationResult {
    // The same `kindMask` and `nodeCount` the flattening pass would report for a one-node tree, and
    // they have to be the same because they are the coverage measurement: a tree the island finished
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
        // is kept so this arm and `setLeaf` cannot diverge on an input neither can receive.
        //
        // `CalcSimplification` is built here rather than at the entry point so that none of its three
        // fields is live across the branch above; `canonicalizedDimension` reads none of them, and
        // the construction folds away.
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
        // `pushLeaf` refusing a kind outside the four numeric leaves, which this arm cannot hand it.
        // Declined rather than asserted, for the reason `trySimplifyWithSwiftIsland`'s contract check
        // gives: a boundary that came apart falls back to the C++ arm.
        return declined(kindMask, 1, nil)
    }
    return WebCore.CSSCalc.CSSCalcSwiftSimplificationResult(
        kindMask: kindMask,
        nodeCount: 1,
        outcome: CSSCalcSwiftSimplificationOutcome.simplified.rawValue,
        declineAlternative: noDeclineAlternative
    )
}

/// Everything a tree that is not a single numeric leaf needs: the flat pass, unchanged.
///
/// `@inline(always)`, and that is a MEASURED 2x2 rather than the obvious choice. The obvious choice is
/// `@inline(never)`, which takes `withTemporaryAllocation`'s 1000-byte `alloca` -- and the stack
/// protector it forces -- out of the leaf path's frame, and it does: the leaf band reads 254.3 retired
/// instructions against 272.1 here. But an `alloca` lives in the entry block, so the split has to be a
/// real call, and the trees that DO need the flat pass then pay a second frame, the `bl` and the repack
/// of the 24-byte node info into the callee's registers -- a flat +28 per call, measured identically on
/// `mixed`, every rung of the unit ladder and every rung of the depth ladder. Four of `real`'s seven
/// captured expressions take the leaf path and three do not, so the split loses on the band that
/// ships: `real` 913.2 split against 907.6 inlined, `mixed` 1993.9 against 1956.8, `ladder12` 6045.9
/// against 6010.3.
///
/// The fourth cell says why the split cannot be rescued by shrinking the entry frame. Moving the
/// `NonCanonicalDimension` canonicalization out of line is worth −3.4 on `real` WITH the split and
/// −1.3 against this arrangement, i.e. it was buying back the split's own cost; both together are
/// WORSE than this alone (`real` 908.9, `leaf` 278.7). Parked as
/// `cssprobe/patches/calc-leafroot-coldcanon-0908.patch`.
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

    // THE FLAT PATH, taken whenever every alternative in the tree is one it implements.
    //
    // No gate, no new C++, and no option selecting it: the two simplifiers are two ports of the same
    // spec, so a build flag choosing between them would mean the differential only ever exercised one
    // of them. The tree itself decides instead -- `kindMask` already says which alternatives are
    // present and a subset test is one `and` -- so `simplifycheck` runs the flat path on every
    // qualifying corpus case, and ANY disagreement with the C++ fails the differential rather than
    // waiting for someone to flip a flag.
    //
    // `CalcFlatCoverage.mask` holds all 41 alternatives, so the subset test can no longer refuse a
    // tree on coverage grounds; what it still refuses is a node `isSimplifiableAlternative` will not
    // touch at all, and that declines to the C++ arm. The mask stays as a mask rather than becoming
    // an assertion because it is what a new C++ alternative would fall out of, and because the same
    // bits carry the decline blame.
    var (report, emitted) = withCalcFlatTree(root, rootInfo, calcFlatStackCapacity) { tree in
        tree.simplify(root, simplification, builder)
        return tree.emitRoot(root, into: &builder)
    }

    // A tree too big for the fixed stack buffer, retried at its exact size. `nodeCount` is exact even
    // when the first pass overflowed, because the pass keeps counting after it stops writing. This
    // costs a second crossing per node, which is what EVERY tree paid before the coverage walk was
    // folded into the flattening pass; above 25 nodes the buffer goes to the heap regardless.
    if emitted == nil, report.overflowed, report.everyNodeSimplifiable,
        report.kindMask & ~CalcFlatCoverage.mask == 0 {
        (report, emitted) = calcFlatSimplifyOversized(root, rootInfo, report.nodeCount, simplification, &builder)
    }

    if let emitted {
        guard emitted else {
            // `emit` returning false is a construction refusing, and there is now exactly ONE shape of
            // that: a builder contract violation -- either the mid-pass `declined` valve, or
            // `pushLeaf`/`rebuildFrom`/`buildOperation` handed something outside its own contract.
            // None of them has one alternative behind it, so none is named.
            //
            // IT USED TO HAVE A SECOND SHAPE AND THAT IS WHY IT USED TO BLAME `.Clamp`:
            // `buildOperation` answered `std::nullopt` from `toType` for a `clamp()` this pass had
            // rewritten to a `min()`/`max()` whose children's types do not merge, and by then the
            // operands were already consumed. `convertToMinMax` asks `Type::consistentType` before it
            // commits instead, so a merge that fails leaves the node a `Clamp` and this cannot be
            // reached that way any more -- which took the island's last 45 declines to zero.
            //
            // The blame went with it. Keeping "any tree containing a `clamp()` blames `Clamp`" once
            // the `clamp()` reason is gone would point every future contract violation at whichever
            // alternative happened to be in the tree, and a confident wrong attribution is worse than
            // none: an UNATTRIBUTED decline fails `simplifycheck`'s guard 3b outright, which is the
            // right treatment for a contract violation and the wrong one for a coverage refusal. A
            // decline that IS a coverage refusal must name what it refused.
            return declined(report.kindMask, report.nodeCount, nil)
        }
        return WebCore.CSSCalc.CSSCalcSwiftSimplificationResult(
            kindMask: report.kindMask,
            nodeCount: report.nodeCount,
            outcome: CSSCalcSwiftSimplificationOutcome.simplified.rawValue,
            declineAlternative: noDeclineAlternative
        )
    }

    // `CalcFlattenReport.writing` fails for exactly three reasons, and `CalcFlatCoverage.mask` being
    // complete at 41 of 41 retires the third: no tree can hold an alternative the flat pass does not
    // cover. Of the other two, the buffer overflow is handled by the exact-size retry above, so what
    // reaches here is a node no port handles at all -- `report.blame` names it. There is no second
    // simplifier to try, so this declines and the C++ arm runs, which is what the C++ arm is for.
    //
    // This is what replaced the two-pass `fold`/`rewrite` port. That port was reachable only through
    // an alternative the flat mask did not claim; with the mask complete it became unreachable code,
    // and the instrument that says so is `simplifycheck`'s decline accounting: a case that used to be
    // finished by `rewrite` would now report `.declined` and move 36549 simplified / 45 declined.
    return declined(report.kindMask, report.nodeCount, report.blame)
}

/// The oversized-tree retry, `@inline(never)` and out of line for a reason that was MEASURED rather
/// than assumed.
///
/// `withCalcFlatTree` is `@inline(always)`, which is what folds the fixed-capacity call's
/// `_isStackAllocationSafe` test and its heap fallback away to a plain `sub sp`. Inlined a SECOND
/// time at a runtime capacity none of that folds, and the resulting bulk in `cssCalcSimplifySwift`
/// pushed `CalcFlatTree.simplify` and `emit` back out of line: the single-node band moved -1.6%
/// against a -12% to -19% on every multi-node band, and the fit across the ladder put the new fixed
/// per-call cost at about 129 instructions. Kept in its own frame it costs a call on a path taken
/// only above 25 nodes.
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

/// What the `calc-mix()` weight census learned about the weight list, as values.
///
/// Four scalars in one struct so that the counting loop can live inside a
/// `withTemporaryAllocation` closure and still hand its results on without a seven-parameter call.
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
    ///
    /// `false` is not an optimisation: it is the only spelling that can carry a `Calc` weight, a
    /// whole nested `CSSCalcValue`, through the rebuild, and two of the C++'s paths need exactly
    /// that (`:1573`-`:1582`, `:1594`-`:1600`).
    let replaceWeight: Bool

    static let dropped = CalcMixItemPlan(survives: false, weight: 0, replaceWeight: false)
}

/// What spec steps 1 to 5 (`+Simplification.cpp:1509`-`:1611`) do to ONE item, given the census of
/// the whole weight list.
///
/// PURE, and that is load-bearing rather than tidy: no tree, no folded children, no position. It is
/// what lets `emit` run the plan a SECOND time over the original weights and reproduce the fold's
/// survivor list exactly, which is how the flat port carries a per-item weight plan across a
/// boundary that has nowhere to put one. See `CalcFlatTree.simplifyCalcMix`.
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
        // known-zeros (`:1518`-`:1526`) -- are ONE line here, because with
        // `numberOfKnownZeroWeights == 0` no item is `isKnownZero` and the condition never fires.
        return isKnownZero
            ? .dropped
            : CalcMixItemPlan(survives: true, weight: weight.value, replaceWeight: false)
    }

    if survey.total >= 100 {
        // `:1531`-`:1562`. Omitted weights become 0 and are removed, specified zeros are removed,
        // and every remaining weight is scaled -- in BOTH of the C++'s sub-branches, which differ
        // only in whether anything is dropped.
        guard weight.present, !isKnownZero else {
            return .dropped
        }
        // `item.weight->raw()->value * normalizationFactor` (`:1552`, `:1560`). The MULTIPLY is the
        // C++'s, not a divide by `total / 100`; the two differ in the last bit.
        return CalcMixItemPlan(
            survives: true,
            weight: weight.value * (100.0 / survey.total),
            replaceWeight: true
        )
    }

    // `:1563`-`:1611`, `total < 100`. There is no normalisation factor here: a present, non-zero
    // weight is left exactly as it is in all four of the C++'s sub-branches.
    if weight.present {
        // `:1576`-`:1577`, `:1596`-`:1597`: a known-zero weight is dropped wherever there is one to
        // drop. The `numberOfKnownZeroWeights > 0` half is implied by `isKnownZero` and is kept
        // because the C++ spells it.
        if isKnownZero, survey.numberOfKnownZeroWeights > 0 {
            return .dropped
        }
        return CalcMixItemPlan(survives: true, weight: weight.value, replaceWeight: false)
    }

    // `item.weight = CalcMix::Item::Weight { weightForOmitted }` (`:1579`, `:1608`), spec step 2.
    // `static_cast<double>(numberOfOmittedWeights)`, and the division is by the count of OMITTED
    // weights rather than by the item count. It cannot divide by zero: this arm is reached only for
    // an absent weight, so there is at least one.
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
/// DECLARED IN C++ SINCE P7c SLICE C1, WHICH REVERSES WHAT THIS COMMENT USED TO SAY. The previous
/// text read: *"DEFINED IN SWIFT, and that is the point of the exercise rather than an aesthetic
/// preference: the declaration briefly lived in CSSCalcSwiftTypes.h so that an `emitFlatTree` upcall
/// could take a `Span` of these, and every consequence of that ran the wrong way -- C++ owning the
/// shape of a structure only Swift builds, a size `static_assert` to keep the two in step, and a
/// boundary type that grows a field every time the simplifier learns an alternative."* That was
/// right about the boundary it was written for -- an upcall taking a span -- and it does not survive
/// the STORAGE question, which is a different question with a different answer:
///
/// * Toolchain filings 55: `PrintAsClang` exports even a `@frozen`, `BitwiseCopyable` Swift struct
///   as a non-trivially-copyable, non-default-constructible C++ class routing copies through the
///   value witness table, so a Swift-declared node **cannot be a `WTF::Vector` element**. The stored
///   flat tree is a `WTF::Vector`. Filed, with an acceptance criterion; unavailable, not harder.
/// * The two C++ producers of a calc tree (`Style::Calculation::toCSS`,
///   `CSSNumericValue::toCalcTreeNode`) must eventually construct nodes, and cannot name a
///   Swift-only type.
///
/// Two of the three costs the old text named did not materialise. There is still exactly ONE
/// declaration, so nothing is kept in step by hand and nothing is transcribed -- this is a
/// `typealias`, not a mirror, and a field added on the C++ side appears here with no edit. The size
/// `static_assert` earns its place independently: filings 57 records an `@_expose(Cxx)` return-struct
/// tail-zeroing bug found in production on this island, and the assert is what makes a later field
/// addition that re-enters its range a build failure rather than a wrong stylesheet.
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
fileprivate typealias CalcFlatNode = WebCore.CSSCalc.CSSCalcSwiftFlatNode

fileprivate extension CalcFlatNode {
    /// The end-of-list sentinel, and the "no such node" answer.
    ///
    /// One declaration, in C++ (`cssCalcSwiftFlatNoNode`), read here rather than restated: a
    /// sentinel that disagreed across the boundary would make a Swift walk and a C++ walk terminate
    /// at different nodes, silently.
    static var noNode: UInt32 { WebCore.CSSCalc.cssCalcSwiftFlatNoNode }
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
    /// `clamp()`'s MAXIMUM bound is the keyword `none`.
    static let clampNoneMaximum: UInt8 = 1 << 1
    /// The two bits `CSSCalcSwiftBuilder::buildOperation`'s `noneMask` parameter is defined over.
    ///
    /// THE BIT POSITIONS ARE THE BOUNDARY'S, not this enum's private business, and that is the one
    /// thing about stage E3 a reader has to know: `noneMask` bit 0 is the minimum and bit 1 the
    /// maximum, stated in `CSSCalcSwiftTypes.h`'s comment on the declaration. They agree here
    /// because the flat node captured them from `CSSCalcSwiftNodeKind` on the reading side and the
    /// grammar sets the same two bits, so nothing translates -- and because nothing translates,
    /// nothing checks, which is what the `e3-nc1-swapmask` negative control is for.
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

/// Where a pre-order descent over the ORIGINAL tree got to.
///
/// A subtree that does not hold the target reports its SIZE, because that is what tells the parent
/// which pre-order index its next child has. Nothing else can: a pre-order index is a running count,
/// and the original tree stores no count.
fileprivate enum CalcOriginDescent<R> {
    /// The target was not in this subtree, which spans this many pre-order indices.
    case passed(UInt32)
    /// The target was reached, and this is what `body` answered about it.
    case reached(R)
}

/// Run `body` on the ORIGINAL node whose pre-order index is `target`, or answer nil if no node has
/// that index.
///
/// THE POINT OF THIS FUNCTION IS THAT IT ADDS NO C++. `CalcFlatNode.origin` already names the
/// original node, and every upcall that needs one -- `rebuildFrom`, `pushCopyOf`,
/// `resolveStyleCoupledValue`, `swiftCalcMixItemWeight` -- already existed before this pass did.
/// `rebuildFrom` in particular recovers the operation from the original's own
/// variant tag, fills its slots generically over the tuple conformance, and takes
/// `getType(alternative)`, which is the same type the flat node carries because `calcFlatten` read it
/// off the same node. So an alternative whose payload a fixed-size flat node cannot hold needs a fold
/// and a mask bit, and no boundary change at all.
///
/// A RECURSIVE DESCENT RATHER THAN A LOOKUP TABLE, and that is forced rather than chosen: a
/// `CSSCalc::Child` is move-only and `~Copyable`, so no Swift container may hold one and there is no
/// array of them to index. Keeping the borrow on the call stack is the whole technique.
///
/// A BODY RATHER THAN A SELECTOR, so that the four upcalls that need an original share one walk
/// instead of one walk each. A selector byte read back at the bottom of the descent would be exactly
/// the re-derived dispatch this file exists to remove; the closure is non-escaping and specializes
/// away.
///
/// COST, MEASURED AND NOT SMALL: 192 retired instructions per node stepped past. The walk visits
/// exactly the nodes at pre-order indices below `target`, plus the target -- pre-order means one
/// child's subtree contains the target and the ones before it are walked to be COUNTED, so there is
/// nothing to prune; an early exit on `index > target` can never fire for a target that exists. So
/// this is O(target) per node served, and O(N^2) for a tree that is all such nodes.
///
/// The 192 is two generic variant visits per step, not loop overhead: `Child::childCount()` is a
/// `WTF::switchOn` over 41 alternatives plus a `WTF::apply` over the tuple, and `operator[]` is
/// another. Measured on `corpus/calc-descent.tsv`, whose paired bands are MIRROR IMAGES -- same node
/// count, same alternatives, same folds, same emit, the one origin-routed node at pre-order index 1
/// or at index 2k -- so the difference is the walk and nothing else. Five pairs from k=2 to k=10 fit
/// 191.0 / 191.9 / 191.9 / 192.4 / 192.2 instructions per extra step: exactly linear, which is what
/// makes it an attribution rather than a correlation. The C++ arm reads 2374.1 against 2374.7 on the
/// same pair, so the corpus is genuinely symmetric.
///
/// THAT IS THE REAL PRICE OF THIS ROUTE, and it is not the one the design predicted: `rebuildFrom`'s
/// 41-way dispatch, which the plan called the cost, is roughly 50 to 90 instructions once isolated
/// (primitives 17 and 18). Named fix, not taken here because none of the alternatives that use this
/// appears in any real captured payload: have `calcFlatten` record each node's ORIGINAL subtree size
/// in a side table indexed by origin, and only for a tree whose `kindMask` says an origin route will
/// be taken. The walk then skips a sibling subtree by reading its size instead of entering it,
/// making it O(depth) with one `operator[]` per level. It costs a second stack buffer and a
/// conditional store per node during flattening, which is why it is not free and is not done
/// speculatively.
///
/// `Child::childCount()` rather than `swiftNodeInfo`, because the walk needs the arity and nothing
/// else; both are the same generic visit.
///
/// A `nil` answer means the flat tree and the tree it was built from disagree about their own shape.
/// Every caller declines on it rather than reaching for another node.
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

/// The two origin routes, OUT OF LINE, and that is measured rather than stylistic.
///
/// A closure body is a `partial_apply` and a stack slot even when it is `[on_stack]` and
/// specialised, and two of them inside `emit` grew that function's frame -- which `emit` pays PER
/// NODE, because it recurses. Inline, they cost the whole pass a fixed ~70 retired instructions per
/// simplification, measured on `calc-shapes`' `leaf` band, which is a single numeric leaf and
/// reaches neither route.
///
/// `@inline(never)` rather than trusting the optimizer: both arms are cold by construction -- none
/// of the alternatives that take them appears in any real captured payload -- and the whole point of
/// the split is that `emit`'s frame does not grow.
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
///
/// THE PLAN IS RECOMPUTED HERE RATHER THAN CARRIED FROM THE FOLD, and `CalcFlatTree.simplifyCalcMix`
/// sets out why: there is nowhere on a fixed-size flat node to keep an item index, a `Double` and a
/// flag per child, and pushing them during the fold takes them in the wrong order -- the reverse
/// scan folds an inner `calc-mix()` before an outer one while `emit` reaches the inner one first,
/// and `rebuildSlot` consumes the weight stack from the top. `calcMixItemPlan` is a pure function of
/// the original weights, which have not changed, so the second run produces the same survivors in
/// the same order as the first.
///
/// ONE descent, because the census, the plans and the rebuild all read the same original node.
/// `itemCount` comes from `childCount()` on that node and NOT from the flat node, whose `childCount`
/// is the survivor count by the time emit runs: `swiftCalcMixItemWeight` answers an out-of-range
/// index with `present == false`, which is indistinguishable from an omitted weight, so reading past
/// the end would silently invent items.
///
/// The survivor/operand cross-check is `rebuildSlot`'s too (`+Simplification.cpp:1988`-`:1994`) and
/// is made here as well, because failing it early declines the tree rather than pairing a prefix.
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

        // In ITEM ORDER, which is the order `rebuildSlot(const Vector<CalcMix::Item>&)` pairs them
        // with the operands. The operands are already on the stack: `emit` pushed the surviving flat
        // children before the switch that reached here, and a nested `calc-mix()` consumed its own
        // weights inside that recursion, so the stack is back where it started.
        var pushed: UInt32 = 0
        index = 0
        while index < itemCount {
            let plan = calcMixItemPlan(WebCore.CSSCalc.swiftCalcMixItemWeight(node, index), survey)
            if plan.survives {
                builder.pushCalcMixItemWeight(index, plan.weight, plan.replaceWeight)
                // `&+=`: at most one push per item, so `pushed <= itemCount`.
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
/// the node). The C++ visits each node once and so does this -- which a pass holding only a
/// read-only handle on the original tree and a write-only operand stack cannot do, because it has
/// nowhere to put a simplified child.
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

    /// A fold discovered mid-pass that it cannot finish, so the whole tree declines.
    ///
    /// The valve that lets a fold refuse WITHOUT a per-node decline channel, and it costs no C++ and
    /// nothing per node: `emitRoot` tests it once and the tree never reaches `emit`, at which point
    /// `cssCalcSimplifySwift` reports `.declined` and the C++ arm runs. The alternative -- leaving
    /// the node as it arrived -- is a silently wrong computed value, which is the failure mode
    /// `CalcFlatCoverage.mask`'s comment is about.
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
///
/// This is what the separate `walk` coverage pre-pass used to produce. It is folded into `calcFlatten`
/// because the two passes read exactly the same thing off exactly the same nodes: `walk` crossed the
/// boundary once per node for `swiftNodeInfo`, and `flatten` then crossed again for the same answer.
/// A single-node tree paid that twice, and `walk` was 685 of the 5651 profile samples of one.
fileprivate struct CalcFlattenReport {
    /// Every node in the WHOLE tree, including any past the point where writing stopped.
    var nodeCount: UInt32 = 0
    /// One bit per `CSSCalcSwiftAlternative` seen, over the whole tree for the same reason.
    var kindMask: UInt64 = 0
    /// The first unhandled alternative in pre-order.
    var blame: CalcAlternative? = nil
    /// Whether every node is one this file can simplify at all -- the old `walk` return value.
    var everyNodeSimplifiable = true
    /// The buffer filled up. Nodes past that point are counted and masked but not written, so
    /// `nodeCount` still sizes an exact retry.
    var overflowed = false

    /// Whether the nodes written so far can still become a flat tree. Two ways to lose it, and both
    /// are monotone, so once this is false it stays false and the pass degrades to a plain walk: it
    /// keeps crossing and counting, because the count and the mask have to describe every tree the
    /// gate saw, but it writes nothing more, and it stops paying `getType` and `operationInfo` for
    /// nodes no flat tree will hold.
    ///
    /// MAINTAINED, NOT RECOMPUTED, and that is what the monotonicity buys. As a computed property
    /// this was three loads, two compares and a `bics` against a stored copy of
    /// `CalcFlatCoverage.mask` -- eight instructions -- at each of its four read sites, one of which
    /// is per node and one per CHILD. Maintained it is `ldrb`/`cmp`/`b.ne`.
    ///
    /// THE COVERAGE SUBSET TEST IS NO LONGER ONE OF THE WAYS, and that is a deliberate move of the
    /// same test from per node to per tree: `withCalcFlatTree` asks it once, beside this. A tree
    /// holding an alternative outside `CalcFlatCoverage.mask` is now flattened in full and then
    /// declined, rather than degrading to a walk at the offending node. Same answer, same blame,
    /// same decline; the difference is wasted writes into a scratch buffer nothing reads on a path
    /// that the mask being complete at 41 of 41 makes unreachable anyway. Kept per node it cost
    /// three or four instructions on EVERY node, because the mask has to be materialised and
    /// compared where it used to ride along in a `bics` against a field already loaded.
    var writing = true

    /// Record `alternative` in `kindMask`.
    @inline(always)
    mutating func sawAlternative(_ alternative: CalcAlternative) {
        kindMask |= UInt64(1) &<< UInt64(alternative.rawValue)
    }

    /// Whether every alternative seen so far is one the FLAT port covers. Asked once per tree.
    ///
    /// Against the mask rather than against `rawValue < 41`, which is the same answer today and
    /// would not stay the same: a bit dropped from `CalcFlatCoverage.mask` to narrow coverage has to
    /// take the trees holding it off the flat path, and only the mask formulation does that.
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
/// Tree order, not serialization order: the serializer sorts a `Sum`'s and a `Product`'s children
/// by unit (`CSSCalcSerializationSwift.swift`'s `sortPriority`), which would silently permute a
/// multi-unit sum here.
fileprivate func calcFlatten(
    _ node: borrowing WebCore.CSSCalc.Child,
    _ info: WebCore.CSSCalc.CSSCalcSwiftNodeInfo,
    _ inheritedFlags: UInt8,
    _ out: inout OutputSpan<CalcFlatNode>,
    _ report: inout CalcFlattenReport
) -> UInt32 {
    return calcFlattenNodeWithInfo(node, info, inheritedFlags, &out, &report)
}

/// `calcFlattenNode` for a node whose `info` the caller already has.
///
/// The child loops do not: they reach a child through `Child::operator[]` and have to ask. The ROOT's
/// caller does, because `cssCalcSimplifySwift` reads it to decide whether the tree needs a flat pass at
/// all, and threading it in is what makes that decision cost no extra crossing.
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

/// The per-node body, and the reason it is separated from `calcFlattenSubtree`.
///
/// A leaf child used to pay `calcFlatten`'s WHOLE frame -- seven `stp`/`ldp` pairs, fourteen
/// callee-saved registers -- and that frame exists for the operation path: `getType`,
/// `swiftOperationInfo`, the child loop and `Child::operator[]` are what force it, and a leaf
/// reaches none of them. The C++ arm's `copyAndSimplifyChildren` reaches each child through
/// `WTF::apply` over the tuple slots and, for a leaf, does a `switchOn` and a 16-byte copy.
///
/// So the seven leaf alternatives finish HERE, with no call of any kind, and this is
/// `@inline(always)` into its two call sites: the out-of-line entry above and
/// `calcFlattenSubtree`'s child loop. The recursion therefore runs through `calcFlattenSubtree`
/// alone -- a leaf child costs neither a call nor a frame -- and there is still only one copy of
/// the leaf body in the source.
@inline(always)
fileprivate func calcFlattenNodeWithInfo(
    _ node: borrowing WebCore.CSSCalc.Child,
    _ info: WebCore.CSSCalc.CSSCalcSwiftNodeInfo,
    _ inheritedFlags: UInt8,
    _ out: inout OutputSpan<CalcFlatNode>,
    _ report: inout CalcFlattenReport
) -> UInt32 {
    // `&+=` and `&<<`, for the reason `CalcFlatCoverage.bit` gives: `+=` is overflow-checked and
    // `<<` is the SMART shift, which is defined for an over-large amount and so carries a
    // `cmp`/`csel` pair the alternative index can never need -- there are 41 of them and the mask
    // is 64 bits wide. Three instructions per NODE, on every band. `nodeCount` cannot wrap either:
    // it counts nodes of a tree that is already in memory.
    report.nodeCount &+= 1
    report.sawAlternative(info.alternative)

    if !isSimplifiableAlternative(info.alternative, info.childCount) {
        report.sawUnsimplifiableNode(info.alternative)
    }
    // A `guard` rather than a plain `if`, and spelled as `count < capacity` rather than as
    // `freeCapacity == 0`, so that the append below is reached only on a path where
    // `OutputSpan.append`'s own precondition is an established fact in the FORM the precondition is
    // written in. `freeCapacity == 0` establishes only that the two DIFFER, which does not
    // discharge `count < capacity`, and the append then repeated the bounds test and carried its
    // own trap.
    guard out.count < out.capacity else {
        report.sawOverflow()
        return calcFlattenSubtree(node, info, inheritedFlags, &out, &report)
    }

    // THE LEAF FAST PATH. The same seven alternatives `carriesType` names below, and the node it
    // writes is the same one `calcFlattenSubtree` would write for them, by case analysis rather
    // than by assumption:
    //
    //  * `type` -- `carriesType` is false for exactly these seven, so `getType` is not called and
    //    the slot is a default `CalcType()`.
    //  * `flags` -- `info.kind` for a leaf is one of the numeric or symbol kinds, never
    //    `ClampWithNoneMinimum`/`Maximum`, and `.Anchor` is not in this set, so the two arms that
    //    can add a bit are both unreachable and `flags` reduces to the inherited
    //    `insideAnchorSide`.
    //  * `firstChild` -- guarded on `childCount == 0`, which is what makes the child loop empty;
    //    a leaf alternative reporting children (which the parser cannot build) falls through to
    //    `calcFlattenSubtree` and is handled by the general path rather than mishandled here.
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
///
/// `@inline(never)`: inlining it into the entry wrapper would put the operation path's fourteen
/// callee-saved registers back on the leaf path, which is the whole cost this split removes.
@inline(never)
fileprivate func calcFlattenSubtree(
    _ node: borrowing WebCore.CSSCalc.Child,
    _ info: WebCore.CSSCalc.CSSCalcSwiftNodeInfo,
    _ inheritedFlags: UInt8,
    _ out: inout OutputSpan<CalcFlatNode>,
    _ report: inout CalcFlattenReport
) -> UInt32 {
    // `out.count < out.capacity` IS RE-ESTABLISHED HERE, and it is not redundant with the identical
    // guard `calcFlattenNodeWithInfo` makes before every call that reaches the append below. This
    // function is `@inline(never)` -- deliberately, so the operation path's fourteen callee-saved
    // registers stay off the leaf path -- and a fact established in a caller does not cross that
    // boundary. There is no safe spelling that publishes it across, so the append at the end of this
    // function carried `OutputSpan.append`'s own `_precondition(_count < capacity)`
    // (`OutputSpan.swift:300`) as a trap. Spelled `count < capacity`, the form the precondition is
    // written in, for the reason the caller's guard gives: `freeCapacity == 0` establishes only that
    // the two DIFFER.
    //
    // The else arm is neither unreachable nor a new behaviour. The only way into this function with
    // the buffer already full is the caller's own overflow branch, which has already called
    // `sawOverflow()` and so already cleared `writing` -- which is why the arm re-tests before
    // calling it rather than calling it unconditionally: reaching here with capacity to spare and
    // `writing` false is the ordinary unsimplifiable-node degradation, and must not be recorded as
    // an overflow, because `overflowed` is what selects the exact-size retry.
    guard report.writing, out.count < out.capacity else {
        if out.count >= out.capacity {
            report.sawOverflow()
        }
        // Walk only. No `getType`, no `operationInfo`, no stores: nothing downstream will read a
        // tree this pass has already given up on, and the remaining crossings exist solely so that
        // `nodeCount` and `kindMask` describe the full tree rather than a truncated prefix.
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

    // Only `insideAnchorSide` propagates: it describes where the slot IS, and the whole point of it
    // is that it reaches every descendant. The other three describe the node ITSELF, so they are
    // masked out of what arrived rather than OR-ed into it. Getting this wrong is not cosmetic --
    // an inherited `anchorSideIsSubtree` makes `sideRoot` below true for child 0 of every node
    // under an `anchor()`, so `anchor(--a calc(25% + 25%), 1px + 2px)` would mark the fallback
    // sum's first term as unsimplifiable; an inherited `clampNoneMinimum` makes a nested
    // `clamp(MIN, VAL, none)` claim both bounds are the keyword. Both were unreachable while
    // neither alternative was in `CalcFlatCoverage.mask` and both become reachable the moment one
    // is.
    var flags = inheritedFlags & CalcFlatNodeFlags.insideAnchorSide
    switch info.kind {
    case .ClampWithNoneMinimum: flags |= CalcFlatNodeFlags.clampNoneMinimum
    case .ClampWithNoneMaximum: flags |= CalcFlatNodeFlags.clampNoneMaximum
    // BOTH bounds are the keyword, which the reading boundary does NOT have a kind for: a
    // `clamp()` with two `none`s is the plain `Clamp` kind and `Child::operator[]` skips both, so
    // one child is the whole of what distinguishes it. Setting both bits here rather than leaving
    // the flags clear is what makes the invariant ONE rule -- `childCount + nones == 3`, checked in
    // `simplifyClamp` and again in `CSSCalcSwiftBuilder::buildOperation` -- instead of a rule with
    // an exception the construction side would have to re-derive in C++ (stage E3).
    //
    // `.Operation` is the kind, not a `.Clamp` -- there is no such kind. The boundary gives a
    // `clamp()` one of the two `ClampWithNone...` kinds when EXACTLY ONE bound is the keyword and
    // the generic operator kind otherwise, so both-`none` and neither-`none` share it and only the
    // child count separates them.
    case .Operation where info.alternative == .Clamp && info.childCount == 1:
        flags |= CalcFlatNodeFlags.clampNoneMask
    default: break
    }

    // A second crossing, taken only for the one alternative that needs it, on the same rule
    // `swiftOperationInfo` states: `swiftNodeInfo` runs for every node of every tree, and
    // this answers a question only `anchor()` asks.
    if info.alternative == .Anchor, !WebCore.CSSCalc.swiftOperationInfo(node).anchorSideIsKeyword {
        flags |= CalcFlatNodeFlags.anchorSideIsSubtree
    }

    // `getType(const Child&)` (CSSCalcTree.h:1053), the same accessor `copyAndSimplify` reads the
    // original's type through at `+Simplification.cpp:1821`. Nothing new was declared for this.
    //
    // NOT taken for the seven leaf alternatives, and that is not a micro-optimisation: a leaf's
    // `Type` is DISCARDED by construction. `ChildConstruction<T>::make(T&&, Type)` for a `Leaf`
    // ignores its `Type` argument entirely (CSSCalcTree.h:1016-1018). Paying a crossing per leaf for a value
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
        // Slot 0 of an `anchor()` with a subtree side IS that side. Everything under it is
        // marked, so the simplification pass skips the whole subtree on one bit test per node
        // rather than having to know where the boundary is.
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
    ///
    /// O(k). Every hot caller walks the list instead; this is for the fixed operand slots, where `k`
    /// is 0, 1 or 2 and is a literal at the call site.
    func child(_ i: Int, _ k: Int) -> Int? {
        var cursor = nodes[i].firstChild
        var remaining = k
        while cursor != CalcFlatNode.noNode {
            if remaining == 0 { return Int(cursor) }
            // `&-`: `remaining` is only decremented on the branch where it is not 0, and it starts
            // at `k`, which is non-negative at every one of this file's 43 call sites -- the literals
            // 0, 1 and 2, plus one `Int(sideSlots)` whose source is a `UInt32` that is 0 or 1. The
            // function is `fileprivate`, so that is the whole call set and no other can be added
            // from outside. So `remaining >= 1` here and the subtraction cannot underflow.
            remaining &-= 1
            cursor = nodes[Int(cursor)].nextSibling
        }
        return nil
    }

    /// `getType(const Child&)` (`CSSCalcTree.cpp:453`-`:456`) for the node this slot WILL EMIT.
    ///
    /// Two answers and no third, and neither is a fresh derivation of anything.
    ///
    /// An OPERATION answers with the type `calcFlatten` read off its original, because that is the
    /// type its emitted node carries whichever of the three emit routes it takes: `buildOperation` is
    /// handed exactly this value, and `calcEmitFromOrigin` reaches `rebuildFrom`, which stamps
    /// `getType(alternative)` -- the same accessor on the same node. A node promoted by `replace`
    /// carries the promoted node's type with it, so that stays true after list surgery.
    ///
    /// A LEAF answers from its own payload, because a leaf's `Type` is discarded at construction
    /// (`ChildConstruction<Leaf>::make` ignores its `Type` argument, `CSSCalcTree.h:1002`) and so is
    /// never stored to be read back. The seven overloads at `CSSCalcTree.cpp:415`-`:451` are
    /// `leafType` for the four numeric kinds, `determineType(unit)` for a `Symbol`, and the identity
    /// type for `sibling-count()` and `sibling-index()`.
    ///
    /// `nil` is the C++'s `std::nullopt` and must never be defaulted: `Type()` is a legitimate value,
    /// the dimensionless `<number>`.
    ///
    /// THE NODE BY VALUE, NOT ITS INDEX, and that is a runtime-trap decision rather than a style
    /// one. `simplifyClamp`, which is two of the three call sites, has already read both bounds --
    /// it asks `numericLeaf` of each before it can decide to convert -- so taking the index here
    /// would re-index the `MutableSpan` at a data-dependent offset the optimizer cannot fold against
    /// the caller's earlier one, and the census shows it as an extra `index out of bounds`
    /// condition. `calcMixFoldToZero`, the third, has not, and pays that one subscript at the call
    /// site instead; it is on the same cold path and the signature is not worth splitting for it.
    /// `CalcFlatNode` is 40 trivial bytes, and neither path -- a `clamp()` with one keyword bound
    /// that could not fold, or a `calc-mix()` whose weights are all zero -- is one any real captured
    /// payload reaches.
    func emittedType(_ node: CalcFlatNode, _ options: CalcSimplification) -> CalcType? {
        switch node.alternative {
        case .Number, .Percentage, .CanonicalDimension, .NonCanonicalDimension:
            guard let leaf = node.numericLeaf else {
                return nil
            }
            return options.leafType(leaf)

        case .Symbol:
            // `getType(const Symbol&)` is `determineType(root.unit)` (`CSSCalcTree.cpp:438`-`:441`),
            // and the flat node's `unitType` IS `Symbol::unit` -- it is the same field
            // `simplifySymbol` hands to `resolveSymbol`.
            guard let unit = WebCore.CSSUnitType(rawValue: node.unitType) else {
                // Never taken: an imported C++ scoped enum's `init?(rawValue:)` does not validate.
                return nil
            }
            return CalcType.determineType(unit)

        case .SiblingCount, .SiblingIndex:
            // `CSSCalcTree.cpp:443`-`:451`, both the identity type.
            return CalcType()

        default:
            return node.type
        }
    }
}

/// The largest tree the fixed-size stack buffer holds, and it is a stdlib threshold rather than a
/// taste: `withTemporaryAllocation` uses `Builtin.stackAlloc` only while the request is at most 1024
/// bytes (`TemporaryAllocation.swift`'s `_isStackAllocationSafe`), and falls back to `malloc` above
/// that. `CalcFlatNode` is 40 bytes, so 25 nodes is 1000 and 26 would silently start heap-allocating
/// on every simplification -- and a per-simplification heap buffer was MEASURED at 617 retired
/// instructions, more than the whole pass. Trees above this take the exact-size retry below, which
/// pays the malloc it would have paid anyway.
fileprivate let calcFlatStackCapacity = 25

/// Flatten `root` into a stack buffer of `capacity` nodes and, if the result is usable, hand the tree
/// to `body`.
///
/// Returns `nil` for `emitted` when `body` did not run, which is one of three things and the report
/// says which: a node no port handles, an alternative the FLAT port does not cover, or a tree larger
/// than the buffer. In all three the buffer is scratch that nothing has read, so nothing is
/// observable -- the same property that makes a whole-tree decline free of the truncation problem
/// `serializationForCSS` has with a `StringBuilder`.
///
/// `withTemporaryAllocation` (SE-0524) rather than any owned container: a `UniqueArray` here was
/// MEASURED at 617 retired instructions per simplification, against the C++ arm's 127 for an entire
/// single-node tree, so a per-call heap buffer costs more than the pass it feeds.
///
/// `OutputSpan` is append-only and `calcFlatten` appends, so there is NO placeholder fill: a buffer
/// sized for the worst case costs a stack pointer adjustment and nothing per unused slot, which is
/// what lets the capacity be a constant and the coverage walk disappear. `out.mutableSpan` then hands
/// back exactly the appended prefix, so `count` cannot name a slot nothing wrote.
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
        // `everyAlternativeCovered` beside `writing`, and this is the ONLY place the coverage subset
        // test is asked -- see `CalcFlattenReport.writing` for why it moved here from the per-node
        // path. A tree holding an alternative the flat port does not cover was flattened in full and
        // is discarded unread here, which is the same decline it used to reach at the offending
        // node.
        guard report.writing, report.everyAlternativeCovered else {
            return (report, nil)
        }
        // `out.count` into a local first: `mutableSpan` is a MUTATING accessor, so reading the count
        // in the same expression is two overlapping accesses to `out` and the exclusivity checker
        // rejects it (#ExclusivityViolation).
        let written = out.count
        var tree = CalcFlatTree(storage: out.mutableSpan, count: written)
        return (report, body(&tree))
    }
}

// MARK: The flat simplifier
//
// COVERAGE: `Sum`, `Product`, `Negate`, `Invert`, `Min`, `Max`, `Clamp`, the four `round()`s,
// `mod()`, `rem()`, `abs()`, `sign()`, `pow()`, `sqrt()`, `Symbol`, `SiblingCount`,
// `SiblingIndex`, `Anchor`, `AnchorSize`, `Random` and the four numeric leaves, and nothing else. Every other alternative is left exactly as it arrived, which is the
// honest behaviour for a bounded port -- it is not a decline channel and must not be read as one.
// `CalcFlatCoverage.mask` is what keeps a tree holding one of the remaining alternatives away from
// here; widening the two together is the work this representation exists to make possible.
//
// The six operations below are a full port of their `simplify` overloads, not a sketch: every arm
// the C++ has, in the C++'s own execution order, including the two arms of `simplify(Negate&)` and
// the `Sum`/`Invert` arms of step 9.3 that are "not stated in spec, but needed for tests", and
// including one arm that is a defect (see `distributeNumber`). Divergence from the C++ is the failure
// mode this whole exercise is measured by, so a rule that looks wrong is reproduced and annotated
// rather than corrected.
//
// WHY THE REPRESENTATION IS A FLAT ARRAY, and it is the whole reason for the exercise: no
// recursion, no per-node crossing, no 41-way variant dispatch, no operand stack, and above all no
// re-folding. `flatten` builds the array in pre-order, so a parent's index is always LESS than its
// children's, and one backwards loop therefore visits every child exactly once before its parent --
// which is `copyAndSimplify`'s own shape. The predecessor this replaced -- a decide-then-rewrite pair
// over the original tree, deleted once the mask reached 41 of 41 -- re-folded every subtree it had
// already decided about and fitted `953 + 2225d + 366d^2` against the C++'s linear depth term.
//
// NOTHING HERE ALLOCATES. The tree is the one stack buffer `withCalcFlatTree` sized in advance; the
// `Sum` merge table is two `InlineArray`s in the frame and `Min`/`Max`'s is one; the `Product`'s
// merged `<number>` reuses the slot of a `<number>` it just folded away rather than needing a slot
// the buffer does not have. A per-simplification heap buffer was measured at 617 retired
// instructions, which is more than the whole pass, so "just one small array" was never available as
// an implementation choice.
//
// EVERY COUNTER BELOW IS WRAPPING (`&+=`, `&-`), and the equivalence argument is the one
// `calcFlattenNodeWithInfo` already makes for `report.nodeCount &+= 1`: these count the nodes or the
// children of a tree THAT IS ALREADY IN MEMORY. Concretely, every one of them is bounded by the
// length of one node's sibling list, which is a sublist of `nodes` -- itself a `MutableSpan` over a
// buffer of at most `UInt32.max` slots, since `withCalcFlatTree` sizes it from a `UInt32` node count
// -- so no counter can reach `UInt32.max`, let alone `Int.max`. The differences (`size - merges`,
// `size - removeTotal`) subtract two values both in `0 ... UInt32.max`, so they land in
// `-(2^32-1) ... 2^32-1`, inside `Int` by 31 bits at each end. The check is therefore not merely
// unlikely to fire, it is unreachable, and it was 21 trap conditions on the hot path (R167 Q1).
//
// The bound is stated again at each site, because `&+=` is not a free rewrite: it turns a detected
// overflow into a silent wrap, so a site whose bound cannot be named must keep the trap.

// THE 139 `nodes[...]` BOUNDS CHECKS BELOW ARE JUSTIFIED BY MEASUREMENT, NOT LEFT UNADDRESSED, and
// this is the measurement. R167's census ranked "one validating accessor for every node index" as the
// island's largest remaining trap item and pre-registered "retired instructions flat to -1% on `leaf`,
// flat on `real` and `ladder12`". That prediction is REFUTED. Four arms were built at thin LTO against
// this file as it stands, seven interleaved rounds, medians, the C++ arm as a null control (flat to
// +-0.02%) and a duplicate-of-one-arm floor of +-0.02%:
//
//   arm                                          conditions   real    mixed  ladder12 depth12  leaf
//   this file                                       180 (139 index)    --      --      --       --
//   A  every link/sentinel site through `slot()`     95 ( 57)  +0.49%  +0.82%  +0.63%  +0.50%  +0.04%
//   B  A + one `indices.contains` guard per head     42 (  2)  +2.06%  +2.84%  +4.65%  +1.90%   0.00%
//   C  B + `@inline(always)` on `simplify`           42 (  2)  +0.38%  +1.01%  +3.88%  +1.69%   0.00%
//
// `slot(_ raw: UInt32) -> Int?` returning `nodes.indices.contains(k) ? k : nil` -- spelled the way the
// subscript's own `_precondition(indices.contains(position))` is spelled, never
// `UInt(bitPattern:) <`, which is the trap filings §43 exists about. Arms A-C are parked as
// `cssprobe/validate/arms/trapq6{link,,inl}.patch`.
//
// THE COMPARES ARE NOT THE COST, which is why this is priced rather than abandoned. `sample` profiles
// of arm B on a single-band `ladder12` corpus attribute it to INLINER THRESHOLDS, twice over:
// `CalcFlatTree.simplify` went from 0.00% self time -- only ever executed inlined into
// `cssCalcSimplifySwift` -- to 7.02%, with the entry dropping 6.00% -> 1.52%; `@inline(always)` puts
// it back (arm C, `real` +2.06% -> +0.38%), and the profile then shows the SAME shape one level down,
// `resolveRelativeLength` appearing at 1.58% from 0.00% and `toLengthUnit` at +1.49pp under a
// `simplifyNonCanonicalDimension` that the guard grew. Static instruction counts are worthless here
// and were checked: all three arms are SMALLER than this file (7578, 7117, 7568 against 7739) and all
// three are slower.
//
// So the next step is selective placement rather than a spelling: the guard is affordable wherever it
// does not push its function over a threshold, and the two thresholds are now named. Until that is
// done these checks stay, and they are PARITY WITH THE C++ rather than a Swift deficit --
// `WTF::Vector::operator[]` forwards to `at()`, which calls `OverflowHandler::overflowed()`
// unconditionally in Release (`Vector.h:803`-`:817`), and `CSSCalc::Children` wraps a `Vector<Child>`
// (`CSSCalcTree.h:356`-`:364`), so the C++ arm aborts on an out-of-range child index exactly as this
// does. Removing them buys no coverage and no memory safety; it is a throughput question, and on this
// evidence it currently loses.

/// `if ((firstInstance.offset - 1) == i && !firstInstance.canRemove)` (`+Simplification.cpp:700`),
/// plus its non-`Numeric` arm (`:707`) -- the C++'s own survivor test, asked of a flat child.
///
/// Over node indices rather than term positions: a
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
    // an escaping closure", which reads as if a closure had been written here.
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
    /// `options` is a `CalcSimplification`, which is where the fields the C++ reads --
    /// `allowZeroValueLengthRemovalFromSum` at `:612` and `category` at `:886` -- are spelled.
    ///
    /// `builder` is `Optional` for exactly one reason, and not as a design preference:
    /// `cssCalcFlatSimplifyProbeSwift` -- whose C++ signature is fixed by the benchmark harness that
    /// calls it -- has no builder to hand over. Two things are read through it here,
    /// One thing is read through it here, `simplifyNonCanonicalDimension`'s `resolveRelativeLength`,
    /// and `nil` cannot change an answer on any tree the production route sends here, because that
    /// route always passes the builder. It CAN change one on the probe's own trees, which is why the
    /// `nil` behaviour is pinned at that site rather than assumed unreachable: a relative length with
    /// no conversion data to resolve against is the C++'s `nullopt`.
    ///
    /// `original` is the tree `calcFlatten` walked, threaded down for the folds whose upcall takes a
    /// `CSSCalc::Child` -- `resolveStyleCoupledValue` and `swiftCalcMixItemWeight`. They reach it
    /// through `withCalcOriginalNode`, at the node's own place in the reverse scan, which is the
    /// position `copyAndSimplify` resolves at too. Taking them during `calcFlatten` instead would
    /// have been O(1) rather than O(index), and was rejected: it resolves an `anchor()` BEFORE its
    /// fallback is simplified and resolves a `random()` whose bounds the fold has not yet checked,
    /// so it can make an upcall -- and, for `anchor()`, a
    /// `setCurrentPropertyInvalidAtComputedValueTime` side effect -- that the C++ arm never makes.
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

    /// The math-function folds a PARSED tree can hold, behind one out-of-line call.
    ///
    /// `false` is "the grammar produced an alternative this pass does not fold", which declines the
    /// tree -- the same answer `simplifyParsed`'s `default` used to give directly. It is a REFUSAL
    /// and not a no-op: leaving an unfolded node in place would hand `emitParsed` a node whose
    /// `origin` names nothing.
    ///
    /// NONE OF THESE FOLDS READS THE ORIGINAL TREE, which is what makes them reachable from a parsed
    /// tree at all -- `simplifyColdNode`'s other arms (`CalcMix`, the sibling functions, the anchor
    /// functions, `Random`) all take a `borrowing Child` and step through it, and there is no
    /// original at parse time. They are also, one for one, the same calls `simplifyColdNode` makes,
    /// not second copies of them.
    ///
    /// `@inline(never)` for `simplifyColdNode`'s reason: `simplifyParsed` pays this frame per node,
    /// and no expression a page actually contains reaches it.
    @inline(never)
    private mutating func simplifyParsedFunction(_ i: Int, _ options: CalcSimplification) -> Bool {
        switch nodes[i].alternative {
        case .Clamp:
            // Stage E3, and it reaches a PARSED tree for the same reason the ten below do: it reads
            // no original. Its bounds' none-ness is on the flat node's own `flags`, which the
            // grammar sets and `calcFlatten` sets, and its `min()`/`max()` rewrite goes through
            // `convertToMinMax`, which computes the new node's `Type` in Swift and writes it before
            // committing. The forward loop revisits nothing, so the rewritten `Min` is taken as-is
            // -- which is what `copyAndSimplify` does with it (`:1810`-`:1823`) and the property the
            // reverse scan was relied on for at the other call site.
            simplifyClamp(i, options)

        // Stage E4. The same five folds `simplifyColdNode` already dispatches for a flattened tree,
        // and they reach a parsed one for the same reason `Clamp` and the ten below do: none of
        // them reads an original node. `simplifyRound` and `simplifyLog` are unchanged.
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

        // Stage E5, and the same seven folds `simplifyColdNode` already dispatches.
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
            // The other three leaves, and for each of them that is a PORT rather than an omission:
            // `simplify(Number&)` (`+Simplification.cpp:487`), `simplify(Percentage&)` (`:493`) and
            // `simplify(CanonicalDimension&)` (`:500`) each `return { }` with no body, which is
            // also why `canSimplify` answers false for exactly those three -- and true for the
            // fourth, which is the case just above.
            return

        default:
            // EVERY REMAINING ALTERNATIVE, spelled as `default` rather than as the thirty-one
            // labels it stands for, and that is measured. The list WAS written out, and the
            // thirty-first label -- `CalcMix`, the last of the forty-one -- cost 6.7 retired
            // instructions per simplification on the single-node `leaf` band plus about 2.2 per
            // node, `leaf` +1.17% and `ladder12` +0.44%, on trees that execute none of it. Thirty
            // labels were free and thirty-one were not, so it is a lowering threshold rather than a
            // slope; naming the ten alternatives this switch actually dispatches and defaulting the
            // rest took every band back to the baseline exactly (`leaf` 581.2 -> 574.5, `ladder12`
            // 7665.2 -> 7630.4).
            //
            // THE MECHANISM IS NAMED, AND IT IS LLVM, NOT SWIFT -- two heuristics compounding, both
            // confirmed alone, and it reproduces in C++ over the same enum. `sortAndRangeify`
            // merges the case values into clusters; the thirty-first label merges `[14,37]` and
            // `[39,40]` into one `[14,40]`, taking the widest cluster from 24 of 38 case values to
            // 27 of 39. `SelectionDAGBuilder::peelDominantCaseCluster` peels the highest-probability
            // cluster out in front once it reaches `switch-peel-threshold` (66%), and with no
            // profile data `BranchProbabilityInfo` weights every case VALUE equally -- so a merged
            // range is "dominant" purely for being wide: 69.2% with the label, 63.2% without. The
            // peel leaves nine clusters, and `SwitchLowering::findJumpTables` then bails because
            // `AArch64Subtarget.cpp` sets `getMinimumJumpTableEntries()` to ten. The switch loses
            // its jump table and becomes a binary-search comparison chain.
            //
            // Written up as filings register §51 with the sweep, the C twin and the reproducers
            // (`~/src/webkit-swift-ports/cssprobe/caselabels/`). Not monotonic in the label count --
            // N = 22 and 23 also lose the table while 24..30 keep it -- because the cluster count
            // and the widest cluster's share move independently, which is why the workaround here
            // is a measurement rather than a rule of thumb. It is also only available because
            // `default` is genuinely unreachable for the omitted values; a switch that must stay
            // exhaustive has no source-level workaround at all.
            //
            // SAFE BECAUSE THE MASK IS NOW COMPLETE. `simplify` runs only for a tree whose whole
            // `kindMask` is inside `CalcFlatCoverage.mask`, and that mask holds all forty-one, so
            // `default` here is exactly the thirty-one cold alternatives. An alternative C++ grows
            // later cannot reach this line -- it would not be in the mask -- and if it somehow did,
            // `simplifyColdNode`'s own `default` leaves the node alone, which is the same answer
            // this arm used to give.
            simplifyColdNode(i, original, options, builder)
        }
    }

    /// The alternatives a REAL PAGE'S CSS does not hold, behind ONE call site.
    ///
    /// THIRTY-ONE ALTERNATIVES BEHIND ONE CALL, and that shape is measured rather than tidy. The
    /// hot switch above names exactly the operations the captured payloads contain --
    /// `calc-real.txt`, the four `real-sp3-*.css` and `bench.css` hold `max()` twice and no other
    /// math function at all -- plus the four leaves, and everything else is its `default`. Five
    /// separate `@inline(never)` arms instead of one pushed `CalcFlatTree.simplify` (1544 bytes)
    /// out of line and out of `withCalcFlatTree`'s specialized body, which cost the SINGLE-NODE
    /// band 12.7% -- 73 retired instructions on a tree that executes none of the new code, measured
    /// with the folds present and the mask bits withheld so they were dead. The budget is what
    /// matters, not the individual markers: a batch that adds an alternative adds an arm HERE,
    /// where the enclosing function is already cold and already out of line, and the hot switch
    /// does not grow at all -- it names ten alternatives and defaults the rest, which is a second
    /// measured constraint in its own right and is written up at that `default`.
    ///
    /// `@inline(never)` for the same reason each of these already carried it: `simplify` pays this
    /// function's frame per node, and none of these is reached by a tree a page actually contains.
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
            // return rather than a trap for the reason every other unreachable arm in this file is
            // -- an untaught alternative leaves the node alone, which the mask has already made
            // impossible, rather than killing the process.
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

    /// `simplify(Symbol&)` (`+Simplification.cpp:516`-`:524`):
    /// `copyAndSimplify(makeNumeric(options.symbolTable.get(root.id)->value, root.unit), options)`.
    ///
    /// A leaf stays a leaf, so this is a `setLeaf` and nothing structural moves -- the same shape as
    /// `simplifyNonCanonicalDimension`, and for the same reason.
    ///
    /// THE POST-STEP IS REAL AND IS THE WHOLE REASON THIS COULD NOT LAND EARLIER. `:523` calls the
    /// entire `copyAndSimplify`, not `makeNumeric` alone, so a symbol that resolves to a
    /// NON-CANONICAL unit is then canonicalized by `simplify(NonCanonicalDimension&)` (`:506`).
    /// `canonicalizedDimension` is that step; skipping it would be a silently wrong computed value
    /// rather than a decline.
    ///
    /// `nil` builder is the probe's, as in `simplifyNonCanonicalDimension`: with no symbol table to
    /// consult there is nothing to resolve against, which is the C++'s own `return { }` for a symbol
    /// the table does not hold.
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
            // `options.symbolTable.get(root.id)` answered nothing: the C++ returns `{ }` and the
            // unresolved `Symbol` is copied through, which is `emit`'s deep-copy arm.
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
            // Declines rather than leaving the node alone, which would be the one answer that is
            // silently wrong, since the C++ definitely replaced it with something.
            declined = true
        }
    }

    /// `simplify(SiblingCount&)` and `simplify(SiblingIndex&)` (`+Simplification.cpp:527`-`:544`):
    /// resolve the tree-counting functions against the styled element.
    ///
    /// One function for both, because `resolveStyleCoupledValue` reads which off the node's own
    /// variant tag -- so the two can never be swapped across the boundary -- and it implements both
    /// guards in the C++'s own order (`:2400`-`:2409`): no conversion data or no builder state, then
    /// no element. `sibling-count()` widens its integer result with `static_cast<double>`, which is
    /// what the upcall already returns.
    ///
    /// `resolved == false` is NOT a decline: the C++ returns `{ }` and the leaf stays in the tree,
    /// which is `emit`'s deep-copy arm. Neither is a `nil` builder, which is the probe's.
    ///
    /// A `nil` from `withCalcOriginalNode` is the one real failure -- the flat tree naming an origin
    /// index the original tree does not have -- and it declines the whole tree rather than folding
    /// something else.
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

    /// `simplify(Anchor&)` and `simplify(AnchorSize&)` (`+Simplification.cpp:1692`-`:1744`): resolve
    /// against the anchor position evaluator, substituting the fallback when it answers nothing.
    ///
    /// One function for both, since `resolveStyleCoupledValue` reads which off the node's own variant
    /// tag and implements the whole of both bodies, including the `EvaluationOptions` with
    /// `.range = CSS::All` and the `setCurrentPropertyInvalidAtComputedValueTime()` tail.
    ///
    /// THREE dispositions, and the third is why `CSSCalcSwiftNumericResult` carries
    /// `substituteFallback` at all:
    ///
    ///   * resolved -- a canonical `<length>`, and the fallback is discarded. It was still simplified,
    ///     because the reverse scan reached it first, which is exactly what the C++ does: children are
    ///     simplified before `simplify` runs on the node, and that simplification can have observable
    ///     upcalls.
    ///   * the evaluation answered nothing -- `:1714`'s `std::exchange(anchor.fallback, { })`, so the
    ///     node BECOMES its fallback. With no fallback the exchange yields `std::nullopt`, which is
    ///     `simplify` returning `{ }`, so the node survives; the property was already marked invalid
    ///     at computed-value time inside the upcall.
    ///   * no conversion data or no builder state -- the opening guard's `{ }`, and the node survives
    ///     with its simplified fallback still on it.
    ///
    /// A surviving one leaves through `rebuildFrom` on the original, which is `emit`'s default arm:
    /// an `AtomString` element name, an `AnchorSide` subtree and an `<anchor-size>` dimension are
    /// none of them things a fixed-size flat node can hold.
    ///
    /// The `<anchor-side>` subtree is NOT simplified and NOT pushed as an operand -- `:1797` copies
    /// it -- which `insideAnchorSide` and `emit`'s first-child skip handle between them.
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
        // the fallback -- and it is the SAME function `childCount` and `operator[]` answer from, so
        // deriving presence from the count here cannot disagree with the boundary. Cross-checking
        // against `operationInfo().hasFallback` instead would be a second crossing for an answer the
        // count already gives.
        let sideSlots: UInt32 = nodes[i].flags & CalcFlatNodeFlags.anchorSideIsSubtree != 0 ? 1 : 0
        let childCount = nodes[i].childCount
        guard childCount == sideSlots || childCount == sideSlots &+ 1 else {
            // The count and the side flag disagree, which no tree the boundary produced can do.
            declined = true
            return
        }

        guard let resolved = withCalcOriginalNode(original, nodes[i].origin, { builder.resolveStyleCoupledValue($0) }) else {
            declined = true
            return
        }

        if resolved.resolved {
            // `simplify` always ends at a `CanonicalDimension` here, so the check is on the
            // alternative and not the unit: a boundary that came apart declines rather than building
            // the wrong leaf.
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

        // Both remaining dispositions leave the node as it is. They differ only in whether the C++
        // marked the property invalid at computed-value time, which the upcall already did.
    }

    /// `simplify(Random&)` (`+Simplification.cpp:1350`-`:1402`): fold `random()` once its bounds are
    /// resolved numerics of one alternative and its `<random-key>` names a base value.
    ///
    /// The `<random-key>` is not a child; only `min`, `max` and the optional `step` are, so
    /// `childCount` is 2 or 3 whether or not a key is present. All present operands must be the same
    /// numeric alternative and unit, checked against `max` and `step` SEPARATELY and both anchored on
    /// `min`, as the C++ does; only `min` is checked for `fullyResolved`, so a non-canonical dimension
    /// never folds here. The result is shaped like `min`, so a `random()` over percentages keeps
    /// `min`'s percent hint.
    ///
    /// THE BOUNDS ARE CHECKED BEFORE THE UPCALL, and that is not just cheaper. `resolveRandomBaseValue`
    /// goes through `BuilderState::lookupCSSRandomBaseValue`, which is a lookup-or-INSERT keyed on the
    /// sharing, and the C++ reaches it only after the bounds pass (`:1388`). Asking earlier would
    /// register a key for a `random()` the C++ never resolved.
    ///
    /// A surviving one leaves through `rebuildFrom` on the original: `Random::Sharing` is a variant
    /// holding a dashed-ident and has no operand-stack representation at all.
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
            // Either bound not a numeric leaf is the C++'s `[](const auto&)` arm, and a missing one
            // cannot happen for a parser-built node -- `isSimplifiableAlternative` already bounds the
            // arity to 2 or 3. Both leave the node alone.
            return
        }
        guard options.switchTogether(minimum, maximum), options.unitsMatch(minimum, maximum),
            options.fullyResolved(minimum) else {
            return
        }

        // `root.step` is present exactly when there is a third child, as with `round()`'s second
        // argument and `log()`'s base.
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
        // `resolved == false` covers all three of the C++'s causes -- no conversion data or builder
        // state, an unresolved element-scoped key, a `Calc` fixed value -- and none of them is a
        // decline: the C++ leaves the node in the tree and so does this.
        guard baseValue.resolved else {
            return
        }

        setLeaf(i, minimum.withValue(CalcExecutor.random(baseValue.value, minimum.value, maximum.value, step)))
    }

    /// `simplify(Negate&)` (`+Simplification.cpp:911`-`:961`), all four arms.
    private mutating func simplifyNegate(_ i: Int) {
        guard nodes[i].childCount == 1, let a = child(i, 0) else {
            return
        }

        if nodes[a].isNumericLeaf {
            // 6.1 (`:916`-`:921`). The unary MINUS, not `0 - v` and not `* -1`: it flips the sign bit
            // of a zero, so `-(+0)` is `-0`. That is the C++'s own stated reason for the spelling, and
            // it is the distinction the C++ comment at `:918` calls out.
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
            // 7.1 (`:968`-`:971`), through `CalcExecutor.invert`, which is where the division is
            // spelled once.
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
    /// at `:755`, and step 9.4's eleven-case category table at `:882`-`:902`. `NumericLeaf` is this
    /// file's representation of exactly that -- "everything `makeChildWithValueBasedOn`
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
    /// (`:606`) rather than the O(k^2) pairwise scan this function used to do: two `InlineArray`s in
    /// the frame, keyed by `mergeKey` -- 128 entries because the key is the 7-bit `CSSUnitType`, which
    /// `mergeKey` explains is injective on `NumericIdentity` and so gives the same fixed-size table
    /// without transcribing a 56-case enum into this file. Fixed size, stack, no allocation, and the
    /// same two typealiases `MergeTable` and `MergeFlags` name, so there is one declaration of
    /// each.
    ///
    /// `FirstInstance::merges` is not kept per bucket. The C++ keeps it only to sum it at `:647`, and
    /// two running totals -- `merges`, and how many buckets are currently marked removable -- give
    /// both of its tallies for free. That substitution depends on one thing: `canRemove` is ASSIGNED
    /// on every merge (`:625`), not accumulated, so it can go back to false and the count has to move
    /// both ways.
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
                // `&+=`: at most one merge per child of the sibling list, so `merges <= nodes.count`.
                merges &+= 1

                // `firstInstance.canRemove = canRemoveIfZero && !mergedValue;` (`:625`) -- an
                // ASSIGNMENT, so a bucket made removable by an earlier merge is cleared when a later
                // one lands non-zero. `!mergedValue` is true for both `+0` and `-0`, which `== 0` is
                // and a sign test would not be. Written in this order so the unit classification is
                // skipped for every non-zero merge.
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
            // `UInt32(truncatingIfNeeded: c &+ 1)` rather than the trapping `Int32(c + 1)`: `c` is a
            // node index that has already indexed `nodes`, whose length `withCalcFlatTree` sized from
            // a `UInt32` node count, so `c <= UInt32.max - 1` and `c &+ 1` fits `UInt32` exactly.
            // Same argument `calcFlattenSubtree` gives for `UInt32(truncatingIfNeeded: out.count)`.
            offsets[key] = UInt32(truncatingIfNeeded: c &+ 1)
            let removable = nodes[c].value == 0 && options.lengthRemovalAllowed(leaf)
            if removable != canRemove[key] {
                removableBuckets &+= removable ? 1 : -1
                canRemove[key] = removable
            }
        }

        let size = Int(nodes[i].childCount)
        // `childrenToRemoveTotal` (`:644`-`:650`).
        // `&+`: `merges` is in `0 ... nodes.count` and `removableBuckets` in `0 ... 128`.
        let removeTotal = merges &+ removableBuckets

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
        // `&-` twice: `size` is a `UInt32` `childCount` widened to `Int`, and `merges` and
        // `removeTotal` are both in `0 ... nodes.count + 128`, so either difference lies inside
        // `-(2^32-1) ... 2^32-1`.
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
                // `&+=`: at most one merge per child of the sibling list, so `merges <= nodes.count`.
                merges &+= 1
                continue
            }

            // `offsetOfFirstInstance[static_cast<uint8_t>(id)] = i + 1;` (`:438`). `c + 1` is a node
            // index, not a term position: see `calcFlatSumSurvives`.
            // `truncatingIfNeeded` on the same range argument `simplifySum`'s store gives.
            offsets[key] = UInt32(truncatingIfNeeded: c &+ 1)
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
        // `&-`: `size` is a `UInt32` `childCount` widened to `Int` and `merges <= nodes.count`, so
        // the difference lies inside `-(2^32-1) ... 2^32-1`.
        if size &- merges == 1, let only = child(i, 0) {
            replace(i, with: only)
            return
        }

        // `:459`-`:480`: keep every non-numeric child and the first instance of each merged unit, in
        // order. The node keeps its kind AND its original cached `Type` -- the C++ returns `{ }` at
        // `:482` even here, so `copyAndSimplify` takes the `getType(root)` branch at `:1821`.
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
    /// two dedicated `CSSCalcSwiftNodeKind`s -- and, for BOTH keywords at once, from the plain `Clamp`
    /// kind with one child, which `calcFlattenNode` turns into both bits so that this pass and the
    /// construction boundary share one invariant. The C++ node shape it comes from is the plain one
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

        // The cross-check, and it is the flat node's whole `clamp()` invariant: an absent bound is
        // an absent child, so `childCount + nones == 3` for all four states. A mismatch declines
        // rather than reading a bound out of the wrong slot -- and it must decline rather than
        // leave the node alone, since `rebuildFrom` would then take the keywords off the original
        // and produce a node this pass never reasoned about.
        //
        // `buildOperation` checks the SAME arithmetic on the construction side, which is what lets
        // the grammar and the flattener write the flags the same way and neither of them special-
        // case the both-`none` shape.
        let nones = UInt32(minimumIsNone ? 1 : 0) + UInt32(maximumIsNone ? 1 : 0)
        guard childCount + nones == 3 else {
            declined = true
            return
        }

        if childCount == 1 {
            // Both bounds hold the keyword, so child 0 is `val`: "clamp(none, VAL, none) is
            // equivalent to just calc(VAL)" (`:1014`-`:1016`), returned whatever it is.
            guard let value = child(i, 0) else {
                declined = true
                return
            }
            replace(i, with: value)
            return
        }

        if childCount == 3 {
            // Neither bound is `none`: `[min, val, max]`.
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
            // `holdsAlternative<T>` against `val`'s own alternative for both bounds (`:1085`); a
            // non-numeric bound fails it too.
            guard let minimum = nodes[minimumChild].numericLeaf,
                let maximum = nodes[maximumChild].numericLeaf,
                options.switchTogether(value, minimum), options.switchTogether(value, maximum) else {
                return
            }
            guard options.unitsMatch(minimum, value), options.unitsMatch(value, maximum) else {
                return
            }
            // "As units already match, we only have to check that one of the arguments is
            // `magnitudeComparable`", and the C++ checks `val` (`:1094`).
            guard options.magnitudeComparable(value) else {
                return
            }
            setLeaf(i, value.withValue(CalcExecutor.clamp(minimum.value, value.value, maximum.value)))
            return
        }

        // Exactly one bound is the keyword, so there are two children.
        if minimumIsNone {
            // `[val, max]`, and `clamp(none, VAL, MAX)` is `min(VAL, MAX)` (`:1046`-`:1064`).
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

        // `[min, val]`, and `clamp(MIN, VAL, none)` is `max(MIN, VAL)` (`:1065`-`:1080`).
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
    /// NO LIST SURGERY AT ALL, and that is the flat representation paying off rather than a
    /// coincidence: the C++ builds a fresh two-element `Vector<Child>` in `val, max` order for
    /// `convertToMin` and `min, val` order for `convertToMax`, and the flat child list is ALREADY in
    /// exactly those orders -- child 0 is whichever of the three slots the keyword did not occupy
    /// first. So both conversions take the list as it stands, and `first`/`second` here are always
    /// child 0 and child 1.
    ///
    /// THE NEW TYPE IS COMPUTED HERE RATHER THAN AT EMIT, and that is what closes the one coverage
    /// hole this file had. `toType(Min)` and `toType(Max)` are `Type::add` over the two children
    /// -- `Min::input` and `Max::input` are `AllowedTypes::Any`, so `getValidatedTypeFor` never
    /// refuses; `merge` is `MergePolicy::Consistent`, which is `Type::consistentType`; and `output`
    /// is `OutputTransform::None`, so `transformType` is the identity (`CSSCalcTree.cpp:509`-`:523`,
    /// `CSSCalcType.h:378`-`:435`). `consistentType` is CALLED, not transcribed.
    ///
    /// A FAILING MERGE LEAVES THE NODE A `Clamp`, which is exactly what the C++ does with it:
    /// `convertToMin` returns `std::nullopt` (`:1021`), `simplify(Clamp&)` propagates it, and
    /// `copyAndSimplify` (`:1818`-`:1821`) rebuilds the `Clamp` with `getType(root)`. Emit's
    /// `default` arm rebuilds it from the same two operands through `rebuildFrom`, which takes
    /// `getType(alternative)` off the same original -- the same node, not a near one. This used to
    /// be the island's last decline: the type was recomputed at emit, by which time `buildOperation`
    /// had already consumed the operands into the node it could not build, so a failure had nowhere
    /// to go but a whole-tree decline. Asking BEFORE the conversion instead means there is nothing
    /// to unwind.
    ///
    /// THE C++ HAS A DEFECT HERE THAT THIS CANNOT REPRODUCE. `convertToMin` moves `root.val` and
    /// `root.max` into its new `Vector` BEFORE testing `toType`, and returns `std::nullopt` on
    /// failure -- at which point `copyAndSimplify` rebuilds a `Clamp` from children that have been
    /// moved from, i.e. an `IndirectNode` holding a null `UniqueRef`. `root.val` is always a numeric
    /// leaf on this path so it is harmless; `root.max` can be an arbitrary subtree. Reachability is
    /// unverified and probably nil, since the parser type-checks `clamp()`'s three arguments for
    /// consistency. Nothing is moved here, so the port does not reproduce it -- and it no longer
    /// declines into the C++ arm to have it executed either. Recorded as a to-file WebKit bug and as
    /// a safety-ledger entry.
    private mutating func convertToMinMax(_ i: Int, _ first: CalcFlatNode, _ second: CalcFlatNode, isMax: Bool, _ options: CalcSimplification) {
        guard let firstType = emittedType(first, options),
            let secondType = emittedType(second, options),
            let merged = calcTypeConsistentType(firstType, secondType) else {
            // The types do not merge, so the node stays a `Clamp` and `emit`'s `default` arm rebuilds
            // it from these same two operands. Not a decline: the C++ does not build the `min()`
            // either.
            return
        }
        nodes[i].alternative = isMax ? .Max : .Min
        nodes[i].type = merged
    }

    /// `simplifyForRound<Op>` (`+Simplification.cpp:328`-`:337`), shared by `round(nearest|up|down|
    /// to-zero, ...)` -- `simplify(RoundNearest&)` and its three siblings (`:1108`-`:1126`) are one
    /// line each onto it.
    ///
    /// Branches on the child count rather than on `root.b`, which is the same test: `forAllChildNodes`
    /// counts a `std::optional<Child>` only when it holds one, and `isSimplifiableAlternative` has
    /// already bounded the count to 1 or 2.
    ///
    /// The one-argument form requires `a` to be a `Number` SPECIFICALLY -- `get_if<Number>` at `:334`,
    /// not the `Numeric` concept -- so `round(1.5px)` does not fold even though `round(1.5px, 1px)`
    /// does.
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

    /// `simplifyForOperation<Op>` (`+Simplification.cpp:299`-`:312`): both operands the same numeric
    /// alternative (`switchTogether`, `:70`), units matching, the FIRST fully resolved, and the result
    /// carried onto a leaf shaped like the first -- `makeChildWithValueBasedOn(op(a, b), a)`.
    ///
    /// `fullyResolved` and not `magnitudeComparable`, which is the load-bearing half of the split at
    /// `:155`-`:173`: a `NonCanonicalDimension` is not fully resolved, so `mod(5em, 3em)` does not
    /// fold here where `abs(-5em)` folds in `simplifyAbs`.
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
    ///
    /// The two-argument shape `round()` reaches through its own `if (root.b)`, so the operand
    /// lookup is here and the predicate is shared.
    @inline(never)
    private mutating func simplifyBinaryOperation(
        _ i: Int,
        _ options: CalcSimplification,
        _ operation: (Double, Double) -> Double
    ) {
        guard let aChild = child(i, 0), let bChild = child(i, 1) else {
            // `isSimplifiableAlternative` has already bounded the arity to 2, so this is a flat tree
            // disagreeing with itself. Left alone rather than declined: `emit` pushes whatever the
            // list holds and `rebuildFrom` refuses an operand count its slots cannot take, so the
            // tree declines there instead of rebuilding something different.
            return
        }
        simplifyForOperation(i, aChild, bChild, options, operation)
    }

    /// `simplify(Abs&)` (`+Simplification.cpp:1323`-`:1335`): ANY numeric alternative, guarded by
    /// `magnitudeComparable` alone, with the result carried onto a leaf shaped like the operand --
    /// `makeChildWithValueBasedOn(executeMathOperation<Abs>(a.value), a)`.
    ///
    /// `magnitudeComparable` and NOT `fullyResolved` (`:1327`), which is the other side of the split
    /// `simplifyForOperation` sits on: a `NonCanonicalDimension` is comparable by magnitude (`:149`)
    /// and not fully resolved (`:171`), so `abs(-5em)` folds where `mod(5em, 3em)` does not. The
    /// asymmetry is reproduced, not normalised.
    @inline(never)
    private mutating func simplifyAbs(_ i: Int, _ options: CalcSimplification) {
        guard let aChild = child(i, 0), let a = nodes[aChild].numericLeaf,
            options.magnitudeComparable(a) else {
            // The catch-all visitor (`:1331`-`:1333`), plus the guard: the node is left alone.
            return
        }
        setLeaf(i, a.withValue(CalcExecutor.abs(a.value)))
    }

    /// `simplify(Sign&)` (`+Simplification.cpp:1337`-`:1349`): `abs()`'s guard, and a `Number`
    /// result whatever the operand's alternative was -- `sign()` is a ratio, not a quantity.
    ///
    /// `CalcExecutor.sign` returns the OPERAND when it is neither `> 0` nor `< 0`, so `sign(-0)` is
    /// `-0` and `sign(NaN)` is `NaN`; that is `CSSCalcExecutor.h`'s own shape and not a shortcut.
    @inline(never)
    private mutating func simplifySign(_ i: Int, _ options: CalcSimplification) {
        guard let aChild = child(i, 0), let a = nodes[aChild].numericLeaf,
            options.magnitudeComparable(a) else {
            return
        }
        setLeaf(i, NumericLeaf.number(CalcExecutor.sign(a.value)))
    }

    /// `simplify(Pow&)` (`+Simplification.cpp:1175`-`:1188`): both operands must be `Number`, and
    /// that is the WHOLE predicate -- no `unitsMatch`, no `fullyResolved`, because the parser has
    /// already type-checked `pow()`'s two arguments to `<number>`. `switchTogether` is given only a
    /// `(const Number&, const Number&)` arm, so anything else falls to the catch-all.
    @inline(never)
    private mutating func simplifyPow(_ i: Int) {
        guard let aChild = child(i, 0), let bChild = child(i, 1),
            nodes[aChild].alternative == .Number, nodes[bChild].alternative == .Number else {
            return
        }
        setLeaf(i, NumericLeaf.number(CalcExecutor.pow(nodes[aChild].value, nodes[bChild].value)))
    }

    /// `simplify(Sqrt&)` (`+Simplification.cpp:1190`-`:1203`): a `Number` in, a `Number` out.
    ///
    /// `CalcExecutor.sqrt` is `.squareRoot()`, which is IEEE-correctly-rounded, deliberately: it is
    /// what `std::sqrt` gives and what the C++ arm therefore produces.
    @inline(never)
    private mutating func simplifySqrt(_ i: Int) {
        guard let aChild = child(i, 0), nodes[aChild].alternative == .Number else {
            return
        }
        setLeaf(i, NumericLeaf.number(CalcExecutor.sqrt(nodes[aChild].value)))
    }

    /// `simplify(Deg2Rad&)` (`+Simplification.cpp:982`-`:997`): the parse-time wrapper that turns an
    /// `<angle>` argument to `sin()`/`cos()`/`tan()` into the `<number>` of radians those three fold
    /// over. It has no syntax of its own, so it is only ever reached inside a trig function -- which
    /// is also why teaching this pass `Sin` without it would have bought almost nothing: `sin(30deg)`
    /// has `Deg2Rad` in its `kindMask`, so the whole tree would have declined.
    ///
    /// SAFER THAN THE C++, deliberately: the
    /// C++ `ASSERT`s the dimension is `Angle` and then converts whatever it got, so a `Deg2Rad`
    /// wrapping a `<length>` misconverts silently in a shipping build. This checks the unit and
    /// leaves the node alone.
    @inline(never)
    private mutating func simplifyDeg2Rad(_ i: Int) {
        guard let angleChild = child(i, 0), let angle = nodes[angleChild].numericLeaf,
            angle.kind == .canonicalDimension,
            angle.unitType == UInt16(WebCore.CSSUnitType.Deg.rawValue) else {
            return
        }
        setLeaf(i, NumericLeaf.number(CalcExecutor.degreesToRadians(angle.value)))
    }

    /// `simplifyForTrig<Op>` (`+Simplification.cpp:340`-`:355`), which `simplify(Sin&)`, `(Cos&)` and
    /// `(Tan&)` (`:1138`-`:1151`) are one line each onto -- and, character for character, the bodies
    /// of `simplify(Exp&)` (`:1308`-`:1321`) and `simplify(Log&)`'s one-argument shape
    /// (`:1300`-`:1305`) as well, which is why those two route here rather than to a copy of it.
    ///
    /// `Number` SPECIFICALLY, not the `Numeric` concept: the C++ gives `WTF::switchOn` a single
    /// `(const Number&)` arm, so `sin(50%)` and `exp(1em)` fall to the catch-all and are left alone.
    /// For the trig three the argument was type-checked to `<number>` at parse or wrapped in a
    /// `Deg2Rad` that produces one, so this fires exactly when the operand has resolved to radians.
    ///
    /// `CalcExecutor.tan` reproduces the two named poles bit for bit (`.swift:519`); it is not
    /// `Darwin.tan`, and the closure passed here is the reason that distinction survives.
    @inline(never)
    private mutating func simplifyNumberToNumber(_ i: Int, _ operation: (Double) -> Double) {
        guard let aChild = child(i, 0), nodes[aChild].alternative == .Number else {
            return
        }
        setLeaf(i, NumericLeaf.number(operation(nodes[aChild].value)))
    }

    /// `simplifyForArcTrig<Op>` (`+Simplification.cpp:357`-`:370`), for `simplify(Asin&)`, `(Acos&)`
    /// and `(Atan&)` (`:1153`-`:1166`): the same one-arm `Number` predicate, and a canonical
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
    ///
    /// `fullyResolved`, so `atan2(1em, 2em)` does not fold -- the same side of the `:155`-`:173`
    /// split `mod()` sits on, and the opposite side from `abs()`.
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
    ///
    /// Two shapes, selected by whether `root.b` is present -- which `childCount` answers exactly as
    /// it does for `round()`, since `forAllChildNodes` counts a `std::optional<Child>` only when it
    /// holds one. With a base, BOTH operands must be `Number` (`switchTogether` is given only a
    /// `(const Number&, const Number&)` arm, so this is `pow()`'s predicate and not
    /// `simplifyForOperation`'s); without one it is the natural log through the shared
    /// `simplifyNumberToNumber`.
    ///
    /// NOT REASSOCIATED. `CalcExecutor.log(a, b)` is `std::log(a) / std::log(b)`, two library calls
    /// and a divide (`.swift:584`); `log(a) * (1 / log(b))` is a different double for many inputs.
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
    /// file, and the forty-first of forty-one.
    ///
    /// FOUR PHASES, all four kept. The weight census (`:1487`-`:1507`); the `!canNormalize` early
    /// return that only drops known-zero items (`:1509`-`:1529`); the `total >= 100` and
    /// `total < 100` normalisation branches (`:1531`-`:1611`); and the accumulator, which requires
    /// every surviving item to be the same numeric kind and to agree on that kind's own identity
    /// (`:1613`-`:1689`). `zeroValueMatchingChild`'s eleven-case category table (`:1454`-`:1482`)
    /// is reached through `numericLeafForCategory`, which is shared with
    /// step 9.4, so no category table is written a third time.
    ///
    /// THE PLAN IS RECOMPUTED AT EMIT, NOT CARRIED, and that is the one real design choice here.
    /// `rebuildSlot(const Vector<CalcMix::Item>&)` (`:1976`) wants one `pushCalcMixItemWeight` plan
    /// per SURVIVING item at emit time, and a flat node has two spare BYTES -- nowhere to keep an
    /// item index, a `Double` and a flag per child. Pushing them during the fold does not work
    /// either: the weight stack is consumed from the top by item count, and the reverse scan folds
    /// an INNER `calc-mix()` before an outer one while `emit` reaches the inner one FIRST, so the
    /// inner rebuild would take the outer's plans. `calcMixItemPlan` is a pure function of one
    /// original weight and the census of all of them, so `emit` runs it a second time and gets the
    /// same survivor list in the same order, onto which the surviving flat children zip.
    ///
    /// THE SUM FAILING IS A REBUILD, NOT A DECLINE. `:1681` returns `nullopt` from a `simplify`
    /// that has ALREADY rewritten `root.children`, so `calc-mix(10% 25%, 10px 75%)` keeps its
    /// `calc-mix()` with the normalised weights rather than declining. The relink below therefore
    /// happens whether or not the accumulator agrees, and it happens before the accumulator reads
    /// anything.
    ///
    /// TWO DESCENTS OF THE ORIGINAL TREE, not two per item: `swiftCalcMixItemWeight` indexes the
    /// item vector, so one `withCalcOriginalNode` walk serves the whole list and the reads are O(1)
    /// each. Two rather than one because the census has to be complete before any item can be
    /// judged. At 192 retired instructions per node stepped past that is the dominant cost of this
    /// fold, and it is accepted for the reason the other origin routes are: `calc-mix()` does not
    /// appear in any real captured payload.
    @inline(never)
    private mutating func simplifyCalcMix(
        _ i: Int,
        _ original: borrowing WebCore.CSSCalc.Child,
        _ options: CalcSimplification
    ) {
        let itemCount = nodes[i].childCount
        // `isSimplifiableAlternative` already refuses an empty one, which is where the C++
        // dereferences an empty `std::optional` at `:1685`.
        guard itemCount > 0 else {
            return
        }
        let origin = nodes[i].origin

        guard let survey = calcMixSurvey(origin, itemCount, original) else {
            declined = true
            return
        }

        // The all-zero answers (`:1514`-`:1516` and `:1587`-`:1590`), written as the C++'s two
        // separate branches rather than merged: they sit in different normalisation arms and only
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

        // `!canNormalize` RETURNS `{ }` ON EVERY PATH (`:1511`, `:1521`, `:1528`), so the
        // accumulator never runs for it and the node is rebuilt from whatever the relink left. It
        // must: a `Calc` weight is a whole nested `CSSCalcValue`, `swiftCalcMixItemWeight` reports
        // its value as 0 rather than as anything usable, and weighting an item by it would be an
        // invented answer rather than a fold.
        guard survey.canNormalize else {
            return
        }

        // Phase 4, the weighted sum (`:1613`-`:1689`). Over the SURVIVORS, which is what the relink
        // just left in the child list, and over their normalised weights, which
        // `calcMixItemPlan` gives again -- the same recomputation `emit` makes, for the same
        // reason. `/ 100.0`, not `* 0.01`: they differ in the last bit.
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
    ///
    /// `total` accumulates every `Raw` weight in item order INCLUDING the zeros, so its rounding is
    /// the C++'s addition sequence; `isKnownZero()` is `isRaw() && value == 0`
    /// (CSSPrimitiveNumeric.h:142), so a `Calc` weight is never counted however it would evaluate.
    /// `nil` means the flat tree and the tree it was built from disagree about their own shape.
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

    /// One item's weight off the original, for the two passes that need it after the census.
    ///
    /// A named function rather than the call spelled at each site, so the `withCalcOriginalNode`
    /// closure captures the index and nothing else -- in particular not `self`, which is a
    /// `~Escapable` struct over a `MutableSpan` and cannot be handed to one.
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
    ///
    /// `false` means an item's weight could not be read, which is the flat tree and the original
    /// disagreeing about their shape -- a decline, not a rebuild, because the two lists would then
    /// pair up wrongly.
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
    /// FIRST item's category.
    ///
    /// The category comes from `getType(child.value)`, and `emittedType` is that accessor: the four
    /// numeric leaves from their own payload, a `Symbol` from its unit, the identity type for the two
    /// sibling functions, and every OPERATION from the type the flat node carries, which is the field
    /// `getType(const IndirectNode<T>&)` reads (`CSSCalcTree.h:1019`-`:1022`).
    ///
    /// IT USED TO ASK `numericLeaf` AND DECLINE ON AN OPERATION, and that was the island's last
    /// coverage hole: `calc-mix(1% * sibling-index() 0%, 3px 0%)` folds to `calc(0%)` in the C++ and
    /// declined here, because a `sibling-index()` with no builder state leaves the first item a
    /// `Product` rather than a leaf. The comment that stood here called `getType` on an operation "a
    /// recursive type computation with no boundary accessor behind it" and said the C++ had the same
    /// gap. All three were wrong -- it is a field read, the accessor was already in this file for
    /// `simplifyClamp`, and the C++ answers for every alternative. Reached only on unsimplified
    /// input, since an eager parse folds the whole `calc-mix()` before the island sees it.
    ///
    /// `nil` still declines, and now means only what `emittedType` means by it: a `Type` the C++
    /// would have had too, which is the C++'s own `ASSERT(category)` at `:1457`.
    private mutating func calcMixFoldToZero(_ i: Int, _ options: CalcSimplification) {
        guard let first = child(i, 0),
            let childType = emittedType(nodes[first], options),
            let category = childType.calculationCategory().value,
            // `.value = 0`, a literal in all eleven of the C++'s arms -- positive zero.
            let zero = options.numericLeafForCategory(category, 0) else {
            declined = true
            return
        }
        setLeaf(i, zero)
    }

    /// `simplify(Progress&)` and `simplify(ProgressNoClamp&)`
    /// (`+Simplification.cpp:1404`-`:1444`), which are identical but for the executor.
    ///
    /// The C++ opens with `value.index() != start.index() || start.index() != end.index()`, an
    /// equality over the WHOLE 41-alternative variant tag, and only then takes the `Numeric T`
    /// visitor on `value`. Three numeric leaves of one kind is the same predicate: a non-`Numeric`
    /// operand fails the visitor whether or not the indices matched, and two `Numeric`s of different
    /// kinds fail the index test, which `switchTogether` reproduces. The pair is checked the C++'s
    /// way -- `(value, start)` then `(start, end)` -- rather than transitively, because
    /// `unitsMatch` is spelled over exactly those two pairs at `:1414`.
    ///
    /// `fullyResolved` on `value` alone, so `progress(1em, 2em, 3em)` does not fold. The result is a
    /// `<number>` whatever the operands were: `progress()` is a ratio, not a quantity.
    ///
    /// `CalcExecutor.progress`/`.progressNoClamp` (`.swift:618`, `:627`) carry the `from == to`
    /// arms -- `0.0` for `progress()`, `+-infinity`/`0.0` for the no-clamp form -- which are the two
    /// the corpus is least likely to reach; see the commit's non-vacuity note.
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
    /// THREE THINGS THAT LOOK LIKE DETAILS AND ARE NOT.
    ///
    /// 1. CHILD ORDER. `sum += value * value` runs in `root.children` order
    ///    (`CSSCalcExecutor.h:404`-`:416`) and floating-point `+` is not associative, so this walks
    ///    `firstChild`/`nextSibling` and never a re-sorted or re-linked list.
    /// 2. THE VALUE IS COMPUTED EVEN AFTER THE TAG FAILS, and only then discarded by the final
    ///    switch. Observationally identical to an early exit -- kept because it is the C++'s shape
    ///    and because `.failed` is absorbing, so an early exit would have to prove that.
    /// 3. THE EMPTY LIST MUST BE "UNCHANGED", not a division and not an index.
    ///    `OperatorExecutor<Hypot>` returns NaN for an empty range WITHOUT calling the functor
    ///    (`CSSCalcExecutor.h:406`-`:407`), so `result` stays `monostate` and the trailing
    ///    `switchOn` takes the catch-all. Returning here is that, and it is also what keeps
    ///    `firstElement` from being read before it is written.
    ///
    /// The state machine itself is `hypotElement`, which is where `:1216`-`:1264` is transcribed.
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
                // The `[&](const auto&)` arm of whichever tag state is live; every one of them sets
                // `FailureTag` (`:1234`-`:1237`, `:1244`, `:1250`, `:1257`).
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

        // `std::abs(*range.begin())` for one element, `std::sqrt(sum)` for two or more.
        // `.magnitude` is `std::abs(double)`: it clears the sign bit, so `hypot(-0px)` is `+0px`.
        let value = childCount == 1 ? firstElement.magnitude : sumOfSquares.squareRoot()

        switch tag {
        case .number:
            setLeaf(i, NumericLeaf.number(value))

        case .percentage:
            // `Percentage { .value = value, .hint = Type::determinePercentHint(options.category) }`
            // (`:1271`), spelled as the call rather than as the constant 0 it can be reasoned down
            // to. The two agree -- `percentageResolveToDimension`
            // (`:87`-`:104`) and `determinePercentHint` (`CSSCalcType.cpp:308`-`:327`) are
            // non-trivial on exactly `LengthPercentage` and `AnglePercentage`, and this arm is
            // reachable only when the first is false -- but a transcribed constant that is correct
            // by a two-step argument is worth less than the call it stands for.
            guard let optionsCategory = WebCore.CSS.Category(rawValue: options.category) else {
                // Never taken: an imported C++ scoped enum's `init?(rawValue:)` does not validate.
                return
            }
            setLeaf(i, NumericLeaf.percentage(value, CalcType.determinePercentHint(optionsCategory)))

        case .dimension(let canonicalUnit):
            // The FIRST child's unit, carried through the tag; every later child had to match it.
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
                // `&+=` at both `survivors` sites: survivors are distinct slots of one sibling list,
                // so the count is bounded by `nodes.count`. The second site adds the one folded
                // `<number>` slot back, which is a slot this same list just released.
                survivors &+= 1
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
                survivors &+= 1
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
            // `:879`-`:904`'s eleven-case category table, reached through `numericLeafForCategory`
            // so each category's canonical unit and percent hint are written down once in this file.
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
            // divergence. Reachable only when the operand is a `Percentage` or a dimension,
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
    /// Calls `numericLeafType`, so the `getType(const Percentage&)` / `getType(const
    /// CanonicalDimension&)` split, and the reason a `NonCanonicalDimension` answers `nil` rather
    /// than `determineType(unit)`, are stated once in this file.
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
                      let multiplied = calcTypeMultiply(productType, factorType) else {
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
            let invertedType = calcTypeInvert(factorType)
            guard let multiplied = calcTypeMultiply(productType, invertedType) else {
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

    /// Emit the whole tree, or report the mid-pass decline a fold recorded.
    ///
    /// The `declined` test is HERE and not in `emit`, so the valve costs one branch per tree rather
    /// than one per node.
    ///
    /// A `Bool`, and that is MEASURED rather than a style choice. Answering with a two-field struct
    /// so a failure could name the alternative to blame cost the LEAF BAND 16.0% -- 92 retired
    /// instructions on a single-node tree that never reaches a failure at all. The mechanism is in
    /// the symbol table: `withCalcFlatTree` is `@inline(always)` and its closure was
    /// closure-propagated and specialized, and the wider return type replaced that with a generic
    /// specialization plus a `partial apply forwarder`, pushing `CalcFlatTree.simplify` (1428 bytes)
    /// out of line. The blame is recovered from `kindMask` instead, which crosses nothing new.
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
    ///
    /// `original` is the tree `calcFlatten` walked, and it is threaded down rather than reached
    /// through the flat node because a `CSSCalc::Child` is move-only: no Swift container may hold
    /// one, so the only place a borrow of one can live is the call stack. See `withCalcOriginalNode`.
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
    /// Distinct from `rebuildFrom`, which `calcEmitFromOrigin` calls for the four alternatives no
    /// fixed-size node can carry: that takes
    /// the ORIGINAL node and recovers its operation through a 41-way `switchOn` plus `WTF::apply`.
    /// A flat node states its own alternative, so there is nothing to recover -- and the dispatch
    /// that recovery costs is ROUGHLY 50 TO 90 retired instructions, not the 1396 this comment used
    /// to quote; see the corrected note at `CSSCalcSwiftTypes.h`'s `buildOperation`. What actually
    /// makes the origin route expensive is the WALK, at 192 instructions per node stepped past
    /// (`withCalcOriginalNode`).
    ///
    /// `i == 0` IS "this node is the root", and it is passed to every construction entry as
    /// `isRoot`. Node 0 is where `calcFlatten` writes the root and `emitRoot` is the only caller
    /// that names an index, so no child can be 0. The boundary uses it to construct the finished
    /// root straight into the caller's `Tree` instead of onto the operand stack; see
    /// `CSSCalcSwiftBuilder::pushLeaf`'s `isRoot` note for what that is worth. It costs one
    /// comparison at each of the six construction calls and no extra crossing.
    ///
    /// Recursive on tree DEPTH, not on node count, and the deepest calc expression in the whole WPT
    /// css-values corpus is single digits.
    func emit(
        _ i: Int,
        _ original: borrowing WebCore.CSSCalc.Child,
        into builder: inout WebCore.CSSCalc.CSSCalcSwiftBuilder
    ) -> Bool {
        let node = nodes[i]

        // THREE ROUTES OUT OF THE FLAT TREE, and this switch picks between the two a node with no
        // operands can take. `buildOperation` is the third and the cheap one -- one enum-indexed
        // jump table and one `makeChild`, about 3.4 retired instructions per node -- and it is what
        // every node that states its own alternative uses. The other two exist because a fixed-size
        // flat node cannot carry every payload, and they cost an O(index) walk of the original tree
        // at 192 instructions a step, so an alternative belongs on them only when it genuinely
        // cannot be built from operands.
        //
        // ONE dispatch here, not two, and that is measured rather than tidy. Asking `numericLeaf`
        // and then a second pure switch on the same `alternative` byte lets the optimizer HOIST the
        // second one -- with the four extra field loads it needs -- above the leaf return, so a
        // single-node `calc(1px)` paid operator routing it never reaches: 16 retired instructions
        // per node on the `leaf` band.
        //
        // The origin answer for an OPERATION cannot be given here even though this switch knows it,
        // because its children have to become operands first. Rebinding it into a `let` for the test
        // after the loop puts the hoist straight back -- measured, `leaf` +2.4% again -- so the
        // alternative is switched on a second time, after the loop.
        switch node.alternative {
        case .Number, .Percentage, .CanonicalDimension, .NonCanonicalDimension:
            // `pushLeaf` owns which alternative a unit means, via `makeNumeric`, so no unit table is
            // re-derived here.
            guard let leaf = node.numericLeaf else {
                return false
            }
            return builder.pushLeaf(leaf.boundaryLeaf, i == 0)

        case .Symbol, .SiblingCount, .SiblingIndex:
            // The three non-numeric leaves, unresolved. `pushLeaf` serves the four NUMERIC ones and
            // refuses anything else (`+Simplification.cpp:2060`-`:2063`), and `rebuildFrom` refuses a
            // leaf outright because there are no slots to fill (`:2166`-`:2169`), so a deep copy of
            // the original is the only route -- and it is exact, not merely conservative, for the
            // reason `+Simplification.cpp:2166`-`:2169` gives: there is nothing to fill.
            return calcEmitFromOrigin(node.origin, 0, true, i == 0, original, &builder)

        default:
            // Every operation, whether or not `buildOperation` can construct it. One it cannot is
            // refused with `false` and reported as a decline, which is why this arm is safe rather
            // than merely convenient: an alternative added to `CSSCalcSwiftAlternative` and not to
            // `CalcFlatCoverage.mask` never reaches emit at all, and one added to both without a
            // route declines the tree instead of building the wrong node.
            break
        }

        var pushed: UInt32 = 0
        var cursor = node.firstChild
        if node.flags & CalcFlatNodeFlags.anchorSideIsSubtree != 0, cursor != CalcFlatNode.noNode {
            // `anchor()`'s `<anchor-side>` subtree is child 0 and is NOT an operand: `rebuildFrom`
            // takes it off the original with `CSSCalc::copy` (`+Simplification.cpp:2150`), matching
            // `copyAndSimplifyChildren`'s `.side = copy(anchor->side)` (`:1797`). Pushing it would
            // leave one operand more than `rebuildFrom` consumes, and its `!cursor.exhausted()` test
            // would decline the whole tree. `calcFlatten` still WROTE the subtree, because coverage
            // has to see an alternative sitting inside a side, and `insideAnchorSide` is why nothing
            // simplified it.
            cursor = nodes[Int(cursor)].nextSibling
        }
        while cursor != CalcFlatNode.noNode {
            guard emit(Int(cursor), original, into: &builder) else { return false }
            // `&+=`: one push per child of this node's sibling list, so `pushed <= nodes.count`.
            pushed &+= 1
            cursor = nodes[Int(cursor)].nextSibling
        }

        switch node.alternative {
        case .Sum, .Product, .Negate, .Invert, .Min, .Max:
            break

        case .CalcMix:
            // The one alternative whose origin route needs something pushed BEFORE `rebuildFrom`:
            // one weight plan per surviving item. See `calcEmitCalcMix` and
            // `CalcFlatTree.simplifyCalcMix` for why the plan is recomputed here rather than
            // carried from the fold.
            //
            // A `case` OF THIS SWITCH, and that placement was checked rather than assumed. A fourth
            // arm on a switch `emit` runs at every node is exactly the shape that cost
            // `simplifyNode` 6.7 instructions per simplification for its thirty-first label, so the
            // alternative -- an `==` inside the `default` arm below, paid only by a node already
            // taking the O(index) origin walk -- was built and measured: `leaf` 581.2 against
            // 581.3, every other band identical to a tenth of an instruction. Neutral, so the
            // clearer spelling stays. The two are NOT the same shape as `simplifyNode`'s, which is
            // why the result there does not transfer and this was measured separately.
            return calcEmitCalcMix(node.origin, pushed, i == 0, original, &builder)

        default:
            // Everything `buildOperation` does not construct, which is every operation whose slots
            // are not one `Children` or one `Child`: a `Random::Sharing` naming a dashed-ident, a
            // per-item weight that can be a whole nested `CSSCalcValue`, an `AtomString` element
            // name, an `AnchorSide` subtree -- and equally a `Clamp`'s two `ChildOrNone` bounds and
            // a `round()`'s optional second argument, which the flat node CAN describe but the
            // boundary has no entry for. Its children are already operands; everything else comes
            // off the original through `rebuildFrom`, which fills slots generically over the tuple
            // conformance and so serves all 41 alternatives with no C++ added per alternative.
            //
            // THE COMPLEMENT OF `buildOperation`'S SET, not a list of the alternatives that happen
            // to need it today. Stated this way the routing cannot fall out of step with coverage:
            // an alternative added to `CalcFlatCoverage.mask` lands here by default and is BUILT
            // rather than declined, where a hand-kept list would have had to be remembered.
            //
            // A SWITCH, not a bit test against a mask built from `CalcFlatCoverage.bit`. That mask
            // does not constant-fold: `UInt64(alternative.rawValue)` over an IMPORTED C++ enum
            // leaves the optimizer eight `cond_fail`s and four shifts to run here, per operator
            // node. `CalcFlatCoverage.mask` gets away with the same shape because LLVM folds the
            // whole chain -- but only below a size threshold, which is what `bit`'s `&<<` is for,
            // and NOT because the mask is "read once per tree": `CalcFlattenReport.sawAlternative`
            // reads it once per node. That claim used to stand here and is corrected at `bit`.
            //
            // THE PRICE IS THE WALK, not the rebuild: `withCalcOriginalNode` costs 192 retired
            // instructions per node stepped past, against `rebuildFrom`'s own 41-way dispatch at
            // roughly 50 to 90. Accepted for these alternatives because none of them appears in any
            // real captured payload -- `max()` twice is the whole of the math functions across
            // `calc-real.txt`, the four `real-sp3-*.css` and `bench.css`.
            //
            // `CalcMix` used to be routed here and held out of `CalcFlatCoverage.mask`, with a note
            // saying the blocker was that `rebuildSlot(const Vector<CalcMix::Item>&)` needs one
            // `pushCalcMixItemWeight` plan per SURVIVING item at emit time and a flat node has two
            // spare bytes. That was the right diagnosis and the wrong conclusion: the plan is a pure
            // function of the original weights, so it is RECOMPUTED at emit rather than carried.
            // It has its own arm above; see `calcEmitCalcMix`.
            return calcEmitFromOrigin(node.origin, pushed, false, i == 0, original, &builder)
        }

        // THE NODE'S OWN TYPE, ALWAYS, and never a fresh `toType` of the operands.
        // `copyAndSimplify` ends at `makeChild(WTF::move(simplified), getType(root))`
        // (`+Simplification.cpp:1821`) -- the original node's type -- so recomputing here diverges
        // from the C++ for any surviving operator whose children changed shape. Measured, not
        // supposed: `calc((2 / 3px) * 4px)` survives as `Product{6px, 4px}` on both arms and
        // SERIALIZES identically, so only simplifycheck's structural oracle catches it; the C++
        // keeps the parse-time type where a fresh `toType` computes px^2. That is why `flatten` pays
        // `getType` per operator node, and why it skips it for the seven leaf alternatives, whose
        // type `makeChild` discards.
        //
        // THE ONE OPERATION WHOSE KIND CHANGES CARRIES A TYPE TOO. `clamp()` collapsing to
        // `min()`/`max()` has no original node to take a type from, and `convertToMin`/`convertToMax`
        // compute `toType` over the operands (`:1019`-`:1045`) -- but `convertToMinMax` has already
        // done that, in Swift, and written the answer into this node. So there is no second type
        // rule, no `recomputeType` selector to pass, and no way for construction to fail on a type:
        // a merge that would have failed left the node a `Clamp`, which this switch does not reach.
        return builder.buildOperation(node.alternative, pushed, node.type, i == 0)
    }

    /// `emitRoot` for a tree the GRAMMAR built. `root` is named rather than assumed to be 0.
    ///
    /// Post-order puts the root at the LAST slot the descent appended, not the first, and a fold can
    /// only ever `replace` into that slot -- `replace(i, with: j)` keeps `i`'s place -- so the index
    /// the descent returned stays the root through the whole pass.
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

        // TWO MASK TESTS, NOT TWO COMPARE CHAINS, and the shape is `CalcFlattenReport`'s: one
        // `lsr`/`tbz` pair against an immediate the optimizer folds, instead of a run of `cmp`s
        // proportional to how many alternatives this route serves.
        //
        // The chain it replaces was measured. `emitParsed` runs ONCE PER EMITTED NODE, and stage
        // E1's two extra labels on the operation arm cost **+12.7 retired instructions per parse**
        // -- isolated with a built probe that dropped `.Min, .Max` from the label and recovered
        // +18.6 to +5.9, and per-node rather than per-token by the per-band fit (~7.5 + 5.5n; on
        // the nine-node band the probe recovered 53.1 of the 53.7 delta). A compare chain is linear
        // in the label count, so the arm that widens coverage is the arm that pays, and the next
        // stage takes the operation set from six alternatives to seventeen. A mask is constant in
        // it.
        //
        // The same reasoning `CalcFlatCoverage.bit`'s note gives applies here and is why this is a
        // `&<<` against a `static var`: the shift cannot overflow (41 alternatives, 41 < 64) so the
        // masking shift is the identity, and a computed `static var` folds into the immediate where
        // a stored `let` would be a `swift_once` atomic load on a per-node path.
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
            // `&+=`: one push per child of this node's sibling list, so `pushed <= nodes.count`.
            pushed &+= 1
            cursor = nodes[Int(cursor)].nextSibling
        }
        // THE NODE'S OWN TYPE, which for a parsed node is the one the grammar's type algebra
        // computed on the way up -- the same value stage D handed to this same entry.
        //
        // THE MASK IS PASSED UNCONDITIONALLY AND MASKED HERE, not on the C++ side and not behind a
        // `.Clamp` test. One `and` on a byte this node already loaded, against a branch on a switch
        // that runs once per emitted node -- E1's `.Min, .Max` labels cost 12.7 instructions per
        // parse for exactly that shape. Masking here rather than passing `node.flags` raw is what
        // keeps the boundary's contract "two bits" instead of "the island's private flag byte":
        // `anchorSideIsSubtree` and `insideAnchorSide` share the byte and mean nothing to C++.
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
    /// arithmetic nodes, the two `Children`-slotted comparison functions, the eleven whose only
    /// slot is one `Child` -- `Negate`, `Invert`, and stage E2's ten unary math functions with the
    /// `Deg2Rad` wrapper that goes inside three of them -- and stage E3's `Clamp`, whose two
    /// `ChildOrNone` bounds ride in the `noneMask` argument. Stage E4 adds the five whose slots are
    /// `Child a; std::optional<Child> b`: `round()`'s four strategies, which are four alternatives
    /// rather than one node with a mode, and `log()`. Their second slot's presence is the operand
    /// count and needs no argument at all.
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
///
/// All three fields at their C++ default, which is what a probe wants: the fixtures are timed for the
/// shape of the pass, and an options-dependent arm would make the number depend on a value the
/// harness does not pass. `allowZeroValueLengthRemovalFromSum` false also means the zero-length
/// removal arm is never taken, and the only remaining builder read is `resolveRelativeLength`, which
/// is why the probes can hand `simplify` no builder.
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
///
/// THE LOOP IS IN SWIFT, and that is a correction rather than a convenience: two fresh `Array`s per
/// conversion charged every iteration with two mallocs and two frees that a real implementation pays
/// once per process, not once per tree, and measured that way conversion came out at 2338
/// instructions against 1457 for the C++ arm's entire simplification. There is now no allocation at
/// all -- the tree is a stack buffer -- so what this measures is the traversal and the stores.
@_expose(Cxx)
public func cssCalcFlattenProbeSwift(_ root: borrowing WebCore.CSSCalc.Child, _ iterations: UInt32) -> UInt32 {
    var total: UInt32 = 0
    for _ in 0..<iterations {
        total &+= withCalcFlatTree(root, WebCore.CSSCalc.swiftNodeInfo(root), calcFlatStackCapacity) { tree in UInt32(tree.count) }.result ?? 0
    }
    return total
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
    // `CSSTokenizer::isWhitespace` (CSSTokenizer.cpp:449-:452), which is these two and nothing else.
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
///
/// Swift computes block extents itself -- that is what `blockType` is in the token for. `nil` cannot
/// happen for a range the tokenizer produced, since it balances blocks and auto-closes an
/// unterminated one, but it is a parse failure rather than a precondition: a cursor is built from a
/// caller's range and this function does not get to assume where it came from.
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
//
// THE GRAMMAR WRITES THE ISLAND'S OWN REPRESENTATION AND THE TREE IS MATERIALISED ONCE, which is
// what `calc-p7b-staging-plan-0909.md` section 1.4 specified and what stage D did not do. Stage D
// called `pushLeaf`/`buildOperation` per node and handed back a `CSSCalc::Child`; production then
// ran `copyAndSimplify` on it (`CSSCalcTree+Parser.cpp`, the `ParseSimplification::Terminal` line),
// which FLATTENED that `Child` back into these same nodes and emitted a second time. Three
// per-node representation conversions where the design budgeted one. This is the one.
//
// POST-ORDER, NOT PRE-ORDER, and that is forced by recursive descent rather than chosen: a
// `<calc-sum>` does not know whether it is a `Sum` at all until it has parsed its first product and
// seen what follows, so a parent slot cannot be reserved before its children are written. Appending
// as each node is finished puts every child at a LOWER index than its parent -- the mirror of what
// `calcFlatten` produces -- and the one property the flat simplifier needs is preserved either way:
// a single linear pass visits every child before its parent. `calcFlatten`'s pre-order needs the
// REVERSE loop for that; this needs the FORWARD one. `CalcFlatTree.simplifyParsed` is that loop.
//
// Nothing else about the representation changes, and that is deliberate. The links are the same
// `firstChild`/`nextSibling` list, so `simplifySum`'s splice, `replace`, `child(_:_:)` and the merge
// tables are untouched -- they address nodes by index as a unique key and never compare two indices,
// which is what makes the order a free parameter. The one place the OLD order was written into an
// invariant is `calcFlatSumSurvives`'s note that "index 0 is always the root and so never a child";
// that reasoning is redundant rather than load-bearing, because the encoding it justifies is
// `nodeIndex + 1`, which reserves 0 for "not seen" whatever index 0 turns out to be.

/// One parsed subtree: where its root landed, and the `Type` the grammar computed for it.
///
/// The index has to come back out of the recursion because a parent has to link its children, and
/// the type because `<calc-sum>`'s and `<calc-product>`'s type algebra runs on the way up. Stage D
/// returned only the type, since the operand stack made the node implicit; a flat tree has no stack
/// and names its children.
private struct CalcParsed {
    let index: UInt32
    let type: CalcType
}

/// Append a numeric leaf and return its slot, or nil if the buffer is full.
///
/// `nil` IS AN OVERFLOW AND NOT A PARSE FAILURE, and the difference is handled one level up: the
/// entry retries the whole parse at an exact size, exactly as `calcFlatSimplifyOversized` does for
/// the simplification path. Stage D had no size limit because it pushed onto a growable C++
/// `Vector`; a fixed stack buffer must not turn a large expression into a decline.
///
/// `count < capacity` rather than `freeCapacity != 0`, so `OutputSpan.append`'s own precondition is
/// discharged in the form it is written in -- see `calcFlattenNodeWithInfo`'s guard for why the
/// other spelling leaves the trap in place.
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
        // A leaf's `Type` is discarded at construction (`ChildConstruction<Leaf>::make` ignores its
        // `Type` argument), so nothing reads this slot and `emittedType` answers from the payload.
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
///
/// `firstChild` is passed rather than derived: post-order gives no arithmetic relation between a
/// parent and its first child, where `calcFlatten`'s pre-order could say `me + 1`.
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
        // THE TYPE THE GRAMMAR COMPUTED, carried rather than recomputed at emit. This is the same
        // value stage D handed straight to `buildOperation`, and `emitParsed` hands it to the same
        // entry -- so the parse path's type rule is unchanged by the fusion. It matters that it is
        // carried: `copyAndSimplify` ends at `makeChild(..., getType(root))`, the node's own type,
        // and a fresh `toType` over simplified operands is a measured divergence.
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

/// Link `node` on after `previous`, or report it as the list head when there is no previous.
///
/// A separate function so the sibling walk in `<calc-sum>` and `<calc-product>` is the same three
/// lines in both. `out.mutableSpan` is re-taken per patch, as `calcFlattenSubtree` does: it is a
/// mutating accessor, so it cannot be held across the `append` that comes between two patches.
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
    // `calc()` / `-webkit-calc()` function. Any OTHER math function is real CSS this grammar does
    // not cover yet, so it declines; a function block that is not a math function at all is a parse
    // FAILURE, which is what the C++ does with it -- `findBlock` returns nothing and the value
    // switch below has no `FunctionToken` arm.
    if token.blockType == calcBlockStart {
        return calcParseBlock(cursor, &index, end, depth, &out, options, &state, token)
    }

    // `tokens.consumeIncludingWhitespace()`: take this token, then skip the whitespace after it.
    index += 1
    calcSkipWhitespace(cursor, &index, end, &state)

    switch token.type {
    case WebCore.NumberToken:
        // `parseCalcNumber`: a `Number` leaf and an empty `Type`.
        guard let me = calcParseAppendLeaf(&out, .Number, token.numericValue,
            UInt16(WebCore.CSSUnitType.Number.rawValue), 0) else { return nil }
        return CalcParsed(index: me, type: CalcType())

    case WebCore.PercentageToken:
        // `parseCalcPercentage`: the hint comes from the category, not from the token.
        let hint = CalcType.determinePercentHint(options.category)
        guard let me = calcParseAppendLeaf(&out, .Percentage, token.numericValue,
            UInt16(WebCore.CSSUnitType.Percentage.rawValue), percentHintRawValue(hint)) else { return nil }
        // `getType(const Percentage&)` (CSSCalcTree.cpp:428-:434) is `{ .percent = 1 }` and then
        // `applyPercentHint` if the hint is set -- which MOVES the percent exponent into the
        // hinted dimension rather than merely recording it, so setting `percentHint` directly
        // would be a different type.
        var percentType = CalcType()
        percentType.percent = 1
        if let unwrapped = percentHintFromRawValue(percentHintRawValue(hint)) {
            percentType = percentType.withPercentHintApplied(unwrapped)
        }
        return CalcParsed(index: me, type: percentType)

    case WebCore.DimensionToken:
        // `parseCalcDimension`: `CSSUnitType::Unknown` is the reject, and it is a FAILURE -- the
        // C++ arm returns nullopt for it too.
        if token.unit == WebCore.CSSUnitType.Unknown { return nil }
        // Both unit answers rode over in the token's padding, so neither is a crossing: which
        // alternative `makeNumeric` builds, and whether the unit needs conversion data.
        if token.flags & WebCore.CSSCalc.cssCalcSwiftTokenUnitNeedsConversionData != 0 {
            // `absoluteLengthUnitsOnly` makes this invalid input, not a decline.
            if options.absoluteLengthUnitsOnly { return nil }
            state.requiresConversionData = true
        }
        // The same C++ answer stage D used, read as an ALTERNATIVE rather than as a node kind.
        // `cssCalcSwiftLeafKindForUnit` returns a `CSSCalcSwiftNodeKind` because that is what
        // `pushLeaf` takes; a flat node stores the 41-way alternative instead, and the two enums
        // agree on exactly these four names. Mapped here rather than at emit, so the node the
        // simplifier reads already states what it is.
        guard let alternative = calcNumericAlternativeForLeafKind(
            WebCore.CSSCalc.cssCalcSwiftLeafKindForUnit(UInt16(token.unit.rawValue))) else { return nil }
        guard let me = calcParseAppendLeaf(&out, alternative, token.numericValue,
            UInt16(token.unit.rawValue), 0) else { return nil }
        return CalcParsed(index: me, type: CalcType.determineType(token.unit))

    case WebCore.IdentToken:
        // `parseCalcKeyword`. The symbol-table arm is stage F, and it must be checked FIRST on the
        // C++ side, so an ident that is not a constant is a decline rather than a failure: with a
        // non-empty `allowedSymbols` the C++ arm might still resolve it.
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

/// Which of the four numeric ALTERNATIVES a `CSSCalcSwiftNodeKind` leaf answer names.
///
/// Total over the four, `nil` for anything else, which is a decline rather than a guess: the node
/// kind enum has twenty-three cases and only these four are leaves a flat node can hold.
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

/// The block arm of `<calc-value>`, deliberately OUT OF LINE.
///
/// `@inline(never)` keeps `calcParseValue` small, and it is worth **only -2 instructions on a
/// single-leaf parse and -13 on the eight-term band** -- which is the honest finding, because the
/// first version of this comment claimed the arm's size was the cost and that is REFUTED.
///
/// Covering blocks costs **+43 on a single-leaf parse and +226 on the eight-term band** whatever is
/// done with the arm, and the reason is structural: the block arm calls `calcParseSum`, so the
/// descent stops being a DAG -- sum, product, value -- and becomes a CYCLE, which no amount of
/// moving code between functions removes. Before blocks the whole descent could inline into one
/// function; it cannot now. The C++ parser has the same cycle and always did, which is why its
/// column does not move.
///
/// So this attribute is kept for the -2/-13 and for saying where the cold path is, NOT as the fix
/// for the +43. The +43 is the price of the coverage.
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
    // `calc()` / `-webkit-calc()` function. Any OTHER math function is real CSS this grammar does
    // not cover yet, so it declines; a function block that is not a math function at all is a parse
    // FAILURE, which is what the C++ does with it -- `findBlock` returns nothing and the value
    // switch has no `FunctionToken` arm.
    let isPlainCalc = token.type == WebCore.LeftParenthesisToken
        || token.flags & WebCore.CSSCalc.cssCalcSwiftTokenIsPlainCalcFunction != 0
    if !isPlainCalc {
        // A math function the grammar covers: `parseCalcFunction` dispatches on the id and reaches
        // the same `<calc-sum>` recursion the plain-calc arm does, one level down.
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

    // `consumeBlock` hands the inner range EXCLUDING the brackets, and `parseCalcFunction` reaches
    // `parseCalcSum` at `depth + 1`.
    var inner = index + 1
    calcSkipWhitespace(cursor, &inner, blockEnd, &state)
    guard let innerParsed = calcParseSum(cursor, &inner, blockEnd, depth + 1, &out, options, &state) else { return nil }
    // `if (!innerRange.atEnd()) return nullopt` -- extraneous tokens inside the block are a failure,
    // not a decline.
    calcSkipWhitespace(cursor, &inner, blockEnd, &state)
    if inner != blockEnd { return nil }

    // Past the `BlockEnd`, then `tokens.consumeWhitespace()`.
    index = blockEnd + 1
    calcSkipWhitespace(cursor, &index, end, &state)
    // A parenthesised group is not a node: the C++ returns the inner `<calc-sum>`'s child directly,
    // so the block contributes no slot of its own and the caller links the inner root.
    return innerParsed
}

// MARK: The math functions (P7b stages E1 and E2)

/// Which `consume*Arguments` helper `parseCalcFunction` runs for a covered function -- i.e. the
/// function's ARGUMENT GRAMMAR, which is the only thing that differs between the families this
/// grammar serves.
///
/// Carried alongside the alternative rather than derived from it, so the id switch below answers
/// both halves in one pass. Deriving it would be a second switch over the same twelve labels on a
/// path that already runs one.
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
///
/// `WebCore.CSSValueMin` IS THE REAL ENUMERATOR, not a transcribed constant -- the thing this
/// boundary must never do. It reads it because `WebCore_Private.modulemap` lists CSSValueKeywords.h
/// ahead of Core's umbrella; see the note at `CalcAlternative`.
///
/// TOTAL AND EXPLICIT, never `CSSCalcSwiftAlternative(rawValue:)`, and that is not style: on an
/// IMPORTED C++ enum `init?(rawValue:)` NEVER FAILS (interop notes 92), so the `guard let` that
/// spelling invites is vacuous and an unknown id would become an alternative the emit then hands to
/// `buildOperation`. Same shape as `calcNumericAlternativeForLeafKind` above.
///
/// THE ORDER OF THE LABELS IS `parseCalcFunction`'S (`CSSCalcTree+Parser.cpp:1205`-`:1387`), so the
/// two can be read side by side and a missing family is visible as a gap rather than having to be
/// counted. The twenty-two the C++ serves and this does not are stages E3-E5, F and G.
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
    // Stage E5. `hypot` shares `min`/`max`'s ENTIRE grammar and type rule -- `<calc-sum>#` with
    // `input = Any`, `merge = Consistent`, `output = None` (`CSSCalcTree.h:765`-`:767`) -- so it
    // reuses `calcParseArgumentList` unchanged and the variadic case costs one line and no new
    // container. That is the running-`CalcType`-plus-count idiom, not a `Swift.Array`.
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
///
/// The plain-calc arm next door and this one differ only in what they run over the inner range --
/// `<calc-sum>` there, one of the two argument grammars here -- which is exactly how
/// `parseCalcFunction` is shaped. Both enter the inner range at `depth + 1`, matching
/// `parseCalcValue`'s `parseCalcFunction(innerRange, *functionId, depth + 1, state)`
/// (`CSSCalcTree+Parser.cpp:1541`).
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
    // `if (!innerRange.atEnd()) return nullopt`. Vacuous for `<calc-sum>#`, whose loop runs to
    // `blockEnd` by construction, and LOAD-BEARING for the one-argument families: it is what makes
    // `abs(1px, 2px)` and `sin(1 2)` failures rather than silently accepted one-argument calls.
    if inner != blockEnd { return nil }

    index = blockEnd + 1
    calcSkipWhitespace(cursor, &index, end, &state)
    return parsed
}

/// `consumeExactlyOneArgument<Op>` (`CSSCalcTree+Parser.cpp:280`-`:319`): one `<calc-sum>`, its type
/// checked against `Op::input`, the node's type `transformType<Op::output>` of it, and -- for the
/// three trigonometric functions given an `<angle>` -- a `Deg2Rad` wrapper around the argument.
///
/// NO OPERAND CONTAINER, the same as `calcParseArgumentList`: the argument is already in the flat
/// buffer and the node names it by index, so there is no `Array` for `swift_bridgeObjectRelease` to
/// reach.
///
/// THE TYPE RULE IS ONE SWITCH, and the five arms are the five distinct `(Op::input, Op::output)`
/// pairs among the ten -- not ten arms, and not a run-time `AllowedTypes`/`OutputTransform` value
/// threaded through a policy parameter, which would turn a compile-time fact into a dispatch. They
/// read, in the header's order (`CSSCalcTree.h:625`-`:830`): trig `NumberOrAngle -> Number`, arc-trig
/// `Number -> Angle`, `sqrt`/`exp` `Number -> Number`, `abs` `Any -> None`, `sign` `Any -> Number`.
///
/// `validateType<AllowedTypes::Any>` is `return true` (`CSSCalcType.h:385`-`:386`), which is why
/// `abs` and `sign` test nothing -- an omission that would otherwise look like one.
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
    // wrapper goes in, and the wrapper is appended BEFORE the operation so the buffer stays
    // post-order: every child at a lower index than its parent.
    var operand = argument.index
    let outputType: CalcType

    switch alternative {
    case .Sin, .Cos, .Tan:
        guard argument.type.matchesNumberOrAngle,
            let transformed = CalcType.makeNumber().madeConsistent(with: argument.type) else { return nil }
        outputType = transformed

        // `CSSCalcTree+Parser.cpp:311`-`:316`. Two things a transcription gets wrong and both are
        // silent: the condition is on the argument's TYPE matching `<angle>` exactly -- so
        // `sin(0.5)` gets no wrapper and `sin(30deg)` does -- and the node carries `Type { }`, the
        // EMPTY type, not the angle's. The oracle compares the stored `Type`, so the second one
        // fails every angle-argument case and is invisible to serialization.
        //
        // `makeSimplifiedChild` rather than `makeChild` on the C++ side folds this eagerly, but
        // only when `state.simplificationOptions` is set, i.e. under `ParseSimplification::Eager`.
        // Production is `Terminal` and so is this grammar: the wrapper is built unfolded and the
        // whole-tree pass collapses it.
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
        // `calcParseFunctionAlternative`'s `.exactlyOne` arm -- and a REFUSAL rather than a guess,
        // for `calcNumericAlternativeForLeafKind`'s reason: an alternative built with the wrong
        // type rule is a wrong tree, where a decline is merely the C++ arm running.
        return nil
    }

    guard let me = calcParseAppendOperation(&out, alternative, operand, 1, outputType) else { return nil }
    return CalcParsed(index: me, type: outputType)
}

/// `consumeCommaIncludingWhitespace` (`CSSPropertyParserConsumer+Primitives.h`), as the grammar's
/// three call sites spell it: the token must BE a comma, and the whitespace after it goes with it.
///
/// A function rather than the three inlined lines `calcParseArgumentList` used to carry, because
/// `clamp()` needs it twice more and "every argument after the first" and "exactly here" are the
/// same operation. `@inline(always)` so the three-instruction body does not become a call on a
/// per-argument path.
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

/// `parseCalcSumOrNone` (`CSSCalcTree+Parser.cpp:503`-`:513`): the keyword `none`, or a `<calc-sum>`.
///
/// `none` REPORTS `CalcFlatNode.noNode` AS ITS INDEX. It is a keyword, not a subtree: the C++ puts
/// `CSS::Keyword::None` in the slot and appends no child, so nothing is written to the flat buffer
/// and nothing becomes an operand. The caller turns the two absences into the two bits
/// `buildOperation` needs, which is the whole of what `clamp()` costs the boundary.
///
/// TESTED BEFORE THE SUM, AND ON `id` ALONE. `CSSCalcSwiftToken.id` is non-zero only for an
/// IdentToken, so `id == CSSValueNone` already carries the token-type test `CSSParserToken::id()`
/// performs; and `none` is NOT a `<calc-value>` keyword, so reaching `calcParseSum` with it would
/// be a failure rather than a fall-through. The C++ does not skip whitespace here either -- the
/// inner range arrives with it stripped (`parseCalcValue`'s `innerRange.consumeWhitespace()`,
/// `:1537`) and every comma takes its own -- so neither does this.
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
        // `tokens.consumeIncludingWhitespace()`.
        index += 1
        calcSkipWhitespace(cursor, &index, end, &state)
        return CalcParsed(index: CalcFlatNode.noNode, type: CalcType())
    }
    return calcParseSum(cursor, &index, end, depth, &out, options, &state)
}

/// `consumeClamp` (`CSSCalcTree+Parser.cpp:493`-`:591`), stage E3:
/// `clamp( [ <calc-sum> | none ], <calc-sum>, [ <calc-sum> | none ] )`.
///
/// THE TYPE RULE IS FOUR-WAY AND THAT IS NOT A SIMPLIFICATION OF ONE MERGE. `computeType`
/// (`:547`-`:583`) folds only the bounds that are present: both `none` gives the value's own type
/// untouched, and a single `none` merges the remaining pair. Folding an empty `Type` in instead
/// would be a different answer -- `Type { }` is not an identity for `consistentType` -- so the
/// arms are written out. All three merges are `MergePolicy::Consistent` (`Clamp::merge`,
/// `CSSCalcTree.h:470`), and there is no `validateType` and no output transform: `Clamp::input` is
/// `AllowedTypes::Any`, which is `return true`, and `Clamp::output` is `OutputTransform::None`.
///
/// NO OPERAND CONTAINER AND NO `Array`, the same as the other two argument grammars: the three
/// subtrees are already in the flat buffer, and the node names the first and links the rest.
///
/// `depth` IS THE FUNCTION'S OWN, not `depth + 1` per argument: `consumeClamp` passes its `depth`
/// straight to all three `parseCalcSum` calls, and only entering a nested function increments it.
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

    // The sibling list is min, val, max IN THAT ORDER over the bounds that exist, because
    // `buildOperation` fills the slots left to right from the top of the operand stack and an
    // absent bound is an absent operand. `emitParsed` pushes in list order, so list order IS
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

/// Which `<rounding-strategy>` an ident names, as the alternative it SELECTS.
///
/// `consumeIdentRaw<CSSValueNearest, CSSValueToZero, CSSValueUp, CSSValueDown>` (`:659`) is a
/// four-name match, and nil for every other ident -- which is load-bearing rather than a
/// fall-through: `round(pi, 2)` must parse `pi` as the constant in the first `<calc-sum>`, not fail.
///
/// TESTED ON `id` ALONE, `calcParseSumOrNone`'s resolution for `none`: `CSSCalcSwiftToken.id` is
/// non-zero only for an IdentToken, so `id == CSSValueUp` already carries the `type() != IdentToken`
/// test `consumeIdentRaw` performs, and no new byte crosses the boundary for keyword recognition.
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

/// `consumeRound` (`CSSCalcTree+Parser.cpp:655`-`:682`), stage E4:
/// `round( <rounding-strategy>?, <calc-sum>, <calc-sum>? )`.
///
/// THE STRATEGY IS NOT A PARAMETER, IT IS THE ALTERNATIVE, which is why nothing new crosses the
/// boundary for it: `consumeRound` picks among four template instantiations and this picks among
/// four `CSSCalcSwiftAlternative` values that already exist. There is no `roundingStrategy` field on
/// any boundary type and none is wanted.
///
/// THE COMMA IS REQUIRED ONLY WHEN A STRATEGY WAS CONSUMED. `round(1.5)` has no strategy and no
/// comma; `round(up)` has a strategy and no comma and is a FAILURE, not a one-argument round -- the
/// C++ returns `nullopt` at `:663` before it ever reaches the arguments.
private func calcParseRound(
    _ cursor: WebCore.CSSCalc.CSSCalcSwiftParseCursor,
    _ index: inout UInt32,
    _ end: UInt32,
    _ depth: Int32,
    _ out: inout OutputSpan<CalcFlatNode>,
    _ options: WebCore.CSSCalc.CSSCalcSwiftParseOptions,
    _ state: inout CalcParseState
) -> CalcParsed? {
    // BEFORE THE PEEK, NOT AFTER, and the differential found this rather than a reading of it.
    // `consumeIdentRaw` peeks a range whose leading whitespace the caller has already stripped
    // (`parseCalcValue`'s `innerRange.consumeWhitespace()`, `:1537`), but `calcParseFunctionBlock`
    // hands its callee the range starting one token past `(` -- so `calcParseClamp` and
    // `calcParseUnaryFunction` each strip it themselves and so must this. Without it
    // `round( up , 1.5px , 1px )` saw whitespace, took no strategy, and `up` then reached
    // `calcParseSum` as a bare ident, i.e. a SYMBOL DECLINE where the C++ parses.
    calcSkipWhitespace(cursor, &index, end, &state)

    var alternative = WebCore.CSSCalc.CSSCalcSwiftAlternative.RoundNearest
    if index < end, let selected = calcRoundingStrategyAlternative(calcToken(cursor, &state, index).id) {
        // `range.consumeIncludingWhitespace()`.
        index += 1
        calcSkipWhitespace(cursor, &index, end, &state)
        guard calcParseComma(cursor, &index, end, &state) else { return nil }
        alternative = selected
    }
    return calcParseRoundArguments(cursor, &index, end, depth, &out, options, &state, alternative)
}

/// `consumeRoundArguments<Op>` (`CSSCalcTree+Parser.cpp:595`-`:653`): `<calc-sum>, <calc-sum>?`
/// under `round()`'s own type rule.
///
/// A SECOND FUNCTION RATHER THAN `calcParseOneOrTwoArguments` WITH A FLAG, and the difference is
/// not cosmetic. `Round*::input` is `AllowedTypes::Any` -- which `validateType` answers `true` for
/// unconditionally -- but the ONE-ARGUMENT form checks `AllowedTypes::Number` instead (`:604`),
/// against the operation's own rule, and the TWO-argument form checks nothing at all, where `log()`
/// checks `Op::input` on every argument in both forms. Threading that through as a policy value
/// would turn two compile-time facts into a run-time dispatch on a per-node path, which is the same
/// reason `calcParseUnaryFunction` writes its five type rules out.
///
/// `Round*::merge` is `Consistent` and `Round*::output` is `None`, so the two-argument node's type
/// is the merge and nothing transforms it.
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
        // `validateType<AllowedTypes::Number>(sumA->type)`, NOT `Op::input`. `round(1.5px)` is a
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

/// `consumeOneOrTwoArguments<Op>` (`CSSCalcTree+Parser.cpp:430`-`:491`): `<calc-sum>, <calc-sum>?`,
/// stage E4. `log()` is its only member in the C++ dispatch.
///
/// SPECIALISED TO `Log`'S TYPE RULE for `calcParseArgumentList`'s reason: `input =
/// AllowedTypes::Number` (so both arguments are checked), `merge = Consistent`, `output =
/// NumberMadeConsistent` (so the node's type is a fresh `<number>` made consistent with the merge,
/// exactly `calcParseUnaryFunction`'s `Sqrt`/`Exp` arm and not the merge itself).
///
/// THE SECOND SLOT'S PRESENCE IS THE OPERAND COUNT and costs no boundary bit: `Child a;
/// std::optional<Child> b` has two states and one/two operands separate them with nothing left
/// over. That is `rebuildSlot(const std::optional<Child>&)`'s own rule, stated at
/// `CSSCalcTree+Simplification.cpp:2098` -- "presence follows the original ... because childCount
/// counted only the present operands" -- and it is why E4 needs no analogue of `clamp()`'s mask.
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

/// `consumeExactlyTwoArguments<Op>` (`CSSCalcTree+Parser.cpp:379`-`:428`), stage E5: `mod`, `rem`,
/// `atan2`, `pow`.
///
/// THREE TYPE RULES OVER FOUR FAMILIES, written out for `calcParseUnaryFunction`'s reason -- a
/// policy value threaded through would be a run-time dispatch for a compile-time fact.
/// `Mod`/`Rem` are `Any -> None`, `Atan2` is `Any -> AngleMadeConsistent`, `Pow` is
/// `Number -> None`; all four merge `Consistent`. `Mod`'s header carries an in-tree FIXME saying
/// the spec wants `Same` and the tests say otherwise (`CSSCalcTree.h:589`) -- this follows the
/// CODE, which is what the differential compares against.
///
/// THE ORDER OF THE LAST TWO CHECKS IS THE C++'s: `atEnd()` is tested BEFORE argument #2's type
/// (`:403` then `:409`). Both reject, so the outcome is the same either way, and it is written in
/// this order so the two can be read side by side.
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
    // `validateType<Op::input>` on argument #1, which is `return true` for the three `Any` families.
    if alternative == .Pow && !a.type.matchesNumber { return nil }

    guard calcParseComma(cursor, &index, end, &state) else { return nil }
    guard let b = calcParseSum(cursor, &index, end, depth, &out, options, &state) else { return nil }
    calcSkipWhitespace(cursor, &index, end, &state)
    if index != end { return nil }
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
        // arm, and a REFUSAL rather than a guess for `calcParseUnaryFunction`'s reason.
        return nil
    }

    calcParseLink(&out, a.index, b.index)
    guard let me = calcParseAppendOperation(&out, alternative, a.index, 2, outputType) else { return nil }
    return CalcParsed(index: me, type: outputType)
}

/// `consumeProgress` (`CSSCalcTree+Parser.cpp:902`-`:910`) and `consumeProgressImpl` (`:824`),
/// stage E5: `progress( no-clamp? <calc-sum>, <calc-sum>, <calc-sum> )`.
///
/// `no-clamp` SELECTS THE ALTERNATIVE and takes NO COMMA, which is the one place this differs from
/// `round()`'s strategy: `consumeRound` requires a comma after its keyword (`:663`) and
/// `consumeProgress` requires none. Getting that wrong makes `progress(no-clamp 2px, 1px, 3px)` a
/// failure, which is why the case set carries it with and without the keyword.
///
/// THE THREE VALIDATIONS COME AFTER ALL THREE PARSES in the C++ (`:861`-`:876`), not interleaved.
/// It makes no difference to the outcome -- `Progress::input` is `AllowedTypes::Any`, so all three
/// are `return true` and there is nothing to call -- and it is recorded so a later family with a
/// real input rule does not copy the interleaved shape by accident.
///
/// `merge` is `Consistent` twice, LEFT-ASSOCIATED: `(value, start)` then that with `end`. `output`
/// is `NumberMadeConsistent`, so the node's type is a fresh `<number>` made consistent with the
/// merge -- not the merge itself.
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
        // `consumeIdentRaw<CSSValueNoClamp>`, i.e. `consumeIncludingWhitespace`. No comma.
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

    // Slot order IS list order, as it is for `clamp()`: `buildOperation` fills left to right from
    // the top of the operand stack and `emitParsed` pushes in list order.
    calcParseLink(&out, value.index, start.index)
    calcParseLink(&out, start.index, finish.index)
    guard let me = calcParseAppendOperation(&out, alternative, value.index, 3, outputType) else { return nil }
    return CalcParsed(index: me, type: outputType)
}

/// `consumeOneOrMoreArguments<Op>` (`CSSCalcTree+Parser.cpp:321`-`:376`): `<calc-sum>#`, at least
/// one, over the whole range it is given.
///
/// NOTHING HOLDS THE OPERANDS. A running `CalcType` and a `UInt32` count, exactly the idiom
/// `calcParseProduct` and `calcParseSum` use -- the arguments are already in the flat buffer and are
/// linked as they are parsed, so no Swift container ever holds one and there is no `Array` for
/// `swift_bridgeObjectRelease` to reach.
///
/// SPECIALISED TO `Min`/`Max`'S TYPE RULE, which is `input = AllowedTypes::Any` (so `validateType`
/// is `return true` and there is nothing to call), `merge = MergePolicy::Consistent` (so the fold is
/// `Type::consistentType`) and `output = OutputTransform::None` (so the merged type is the node's
/// type unchanged). The three later families with a different rule get their own arms rather than a
/// policy parameter, which would be a run-time dispatch for a compile-time fact.
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
        // `requireComma && !consumeCommaIncludingWhitespace(tokens)`, spelled as "every argument
        // after the first" rather than as a flag. `min(1px 2px)` fails here, which is what the C++
        // does with it.
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

    // Counts operands linked into THIS product, so the node gets the child count the C++ arm's
    // `children` vector would have had. Stays 0 while no operator has been seen, which is the case
    // where C++ returns `firstValue` and builds no `Product` at all.
    var childCount: UInt32 = 0
    // The head of the child list and its current tail. Two locals rather than any container: the
    // list is linked as it is built, so nothing accumulates.
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
            // `Invert` wraps the operand that follows the '/', before it joins the product.
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

        // `calc(1px+ 2px)` is invalid: the operator must be PRECEDED by whitespace. The C++ reads
        // `originalTokens[tokens.begin() - originalTokens.data() - 1]`, which is the token before
        // the operator in the whole range -- an index subtraction here, and the reason whitespace
        // tokens are not filtered out of the cursor.
        if index == 0 { return nil }
        if !calcTokenIsWhitespace(calcToken(cursor, &state, index - 1).type) { return nil }

        index += 1
        // `calc(1px +2px)` is invalid: the operator must be FOLLOWED by whitespace.
        if index >= end || !calcTokenIsWhitespace(calcToken(cursor, &state, index).type) { return nil }
        calcSkipWhitespace(cursor, &index, end, &state)

        guard let next = calcParseProduct(cursor, &index, end, depth, &out, options, &state) else { return nil }

        var operand = next.index
        if op == 0x2D {
            // `Negate` keeps its operand's type unchanged.
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

/// The largest first attempt, and it is `calcFlatStackCapacity` for the reason that constant gives:
/// above 25 nodes `withTemporaryAllocation` silently mallocs, and a per-parse heap buffer was
/// measured at 617 retired instructions -- more than the pass it feeds.
///
/// AN UPPER BOUND ON NODES FROM THE TOKEN COUNT, for the exact-size retry, and it is `2 * tokens`
/// rather than `tokens` because that bound is FALSE: `calc(1px/2/3/4)` is seven tokens and eight
/// nodes -- four leaves, three `Invert`s and a `Product`. The true count is `L + U + A`, where each
/// leaf `L` and each operator delimiter `U` consumes a distinct token (so `L + U <= tokens`) and the
/// n-ary nodes `A` are merges over `L` subtrees, so `A <= L - 1 <= tokens - 1`. Hence
/// `nodes <= 2 * tokens - 1`, and doubling is exact enough for a path taken only above 25 nodes.
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

/// The stage D entry point: parse the token range INSIDE a `calc()`, simplify it, and materialise
/// the result ONCE.
///
/// The caller has already consumed the `calc(` and the matching `)`, exactly as
/// `parseAndSimplify`'s `consumeFunction` does, so this sees `<calc-sum>` and nothing else.
///
/// `simplify` FALSE IS NOT A SECOND PARSER, it is the same descent with the middle pass skipped, and
/// it exists because the grammar differential has to compare a tree against
/// `ParseSimplification::None`. Comparing only the simplified arm would let a parse defect and a
/// commutative fold cancel: `Sum{2px, 1px}` and `Sum{1px, 2px}` both simplify to `3px`. Production
/// is `ParseSimplification::Terminal` (`CSSCalcTree+Parser.h:108`), which is `true`.
///
/// NO `CSSCalc::Child` IS BUILT UNTIL `emitParsedRoot`, which is the whole of C0: stage D pushed one
/// operand per node through the boundary during the descent, and every one of them was then
/// flattened straight back into a `CalcFlatNode` by `copyAndSimplify`. The descent now crosses the
/// boundary ZERO times -- `cssCalcSwiftLookupConstantNumber` and `cssCalcSwiftLeafKindForUnit` are
/// pure table reads, not constructions -- and `finishRoot`'s per-parse `Child` move is gone too,
/// because a flat emit knows which node is the root before it builds it.
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
        // A fold that gave up is a DECLINE with no alternative to blame, on `calcSimplifyFlatTree`'s
        // reasoning: none of the remaining shapes has one alternative behind it. A construction that
        // refused is a contract violation and reports `Failed`; a descent that stopped is whatever
        // the descent said it was.
        if attempt.foldRefused {
            result.outcome = UInt8(WebCore.CSSCalc.CSSCalcSwiftParseOutcome.Declined.rawValue)
            result.declineReason = UInt8(WebCore.CSSCalc.CSSCalcSwiftParseDeclineReason.None.rawValue)
            return result
        }
        if attempt.emitRefused {
            result.outcome = UInt8(WebCore.CSSCalc.CSSCalcSwiftParseOutcome.Failed.rawValue)
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
///
/// Split out so the oversized retry is a second call rather than a second copy, and `@inline(never)`
/// for the reason `calcFlatSimplifyOversized` gives: inlining a `withTemporaryAllocation` twice, once
/// at a constant capacity and once at a runtime one, stops the constant one folding to a plain
/// `sub sp` and pushes the bodies it specialised back out of line.
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

        // THE TOP-LEVEL FUNCTION, which `parseAndSimplify` reads before it hands the inner range
        // over: `calc()` and `-webkit-calc()` have a bare `<calc-sum>` body, and every other covered
        // math function has one of the two argument grammars. All at depth 0, matching
        // `parseCalcFunction(tokens, function, 0, state)` (`CSSCalcTree+Parser.cpp:194`) -- this is
        // NOT the block arm's `depth + 1`, and routing it there instead is the divergence only a
        // 100-deep expression would show.
        //
        // Spelled as an `if`/`else` rather than `Optional.map`, because the branches take `out` and
        // `state` `inout` and a closure cannot capture an `OutputSpan`.
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
            // A TOP-LEVEL MATH FUNCTION THIS GRAMMAR DOES NOT COVER, WHICH IS A DECLINE AND USED TO
            // BE A WRONG TREE. `parseAndSimplify` accepts any `isCalcFunction` at the top
            // (`CSSCalcTree+Parser.cpp:171`-`:175`) and hands this entry the range INSIDE it, so
            // for `hypot(3px, 4px)` the range is `3px, 4px`; falling through to `<calc-sum>` parsed
            // `3px`, stopped at the comma, and -- for a one-argument form such as
            // `atan(e - 2.7182818284590452354)` -- ran to the end and reported PARSED, handing the
            // caller the ARGUMENT where the C++ builds an `Atan` over it.
            //
            // Found by widening the differential's applicability predicate to every calc function,
            // not by reading: 74 corpus lines and two curated cases. It was never web-visible --
            // every caller of `cssCalcSwiftParseIntoChild` is inside
            // `ENABLE(CSS_TOKENIZER_SWIFT_BRIDGE)` today -- but it is exactly the shape that becomes
            // a wrong computed value on the day this entry gets a production caller, and the
            // fall-through was correct only for `calc()` and `-webkit-calc()`.
            state.declined = true
            state.declineReason = .MathFunction
            descent = nil
        }

        guard let parsed = descent else {
            // A descent that stopped with the buffer full is an overflow rather than a rejection.
            // Tested here, once per attempt, rather than threaded back through every `nil`.
            attempt.overflowed = out.count >= out.capacity
            return attempt
        }

        // `parseCalcFunction` requires the inner range to be exhausted -- extraneous tokens are a
        // failure, not a decline.
        calcSkipWhitespace(cursor, &index, end, &state)
        if index != end {
            return attempt
        }

        // `out.count` into a local first: `mutableSpan` is a MUTATING accessor, so reading the count
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

        // THE FLAT ARM, filled in ONE crossing (P7c slices C1/C1d). `takeFlatNodes` is
        // `__counted_by(nodeCount)` plus `noescape`, which is what makes the whole buffer cross as a
        // single `Span` with no `unsafe` marker; either annotation alone gives an
        // `UnsafeBufferPointer` or a pointer and a count as two arguments, and NEITHER failure names
        // the missing annotation (`calcflatstore/run.sh` arms W1 and W2).
        //
        // ADDRESSED TO THE BUILDER, which is what deleted the store OBJECT. C1b crossed to a
        // refcounted `CSSCalcSwiftFlatStore` whose TZone allocate/free pair measured 136.2 retired
        // instructions per parse; the builder already crosses, already carries the pointers it
        // needs, and the destination behind it is now the `Vector` the finished `Tree` owns.
        // Unconditional, because a caller with no destination is served by `takeFlatNodes`
        // answering `nodeCount` -- a null check on the C++ side, not a second crossing here.
        //
        // Read off `tree.nodes` rather than `out`, because `tree` holds `out`'s storage for the
        // duration and reading `out` again here is a second overlapping access the exclusivity
        // checker rejects.
        //
        // ONE `Vector` malloc per stored tree. The `Child` tree beside it is one `makeUniqueRef<Op>`
        // plus one `Children` vector PER OPERATOR node, so once a consumer reads the flat arm this is
        // strictly fewer; until then it is additive and is booked that way.
        let stored = builder.takeFlatNodes(tree.nodes.span.extracting(0..<tree.count), UInt32(parsed.index))
        // The crossing is ASSERTED, not trusted. A `takeFlatNodes` that stored a different number of
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

/// Rebuild a `CSSCalc::Child` from a stored flat tree, reading it back one node at a time BY VALUE.
///
/// WHAT THIS IS FOR, AND WHY IT IS NOT A THROWAWAY. Two things at once:
///
///  * It is the only thing that can VALIDATE slice C1. A store nothing reads is a change no test can
///    fail -- `takeFlatNodes` could store nothing, or half the tree, or the wrong root, and every
///    existing differential would still pass, because they all compare the `Child` the emit built
///    directly. Reading the store back and emitting from THAT makes the whole crossing observable:
///    the 1,639-expression corpus and the curated cases now compare a tree that went through
///    `takeFlatNodes` and 40 bytes of `flatNodeAt` per node against one that did not. Poisoning either
///    entry point fails them.
///  * It is the materialising fallback slice C2 needs, so that a consumer which has not yet been
///    ported can keep reading `Child` off a `Value` that stores the flat form. The charter's gate on
///    P7c is that a consumer either moves to Swift or keeps reading `Child`; this is the second
///    half of that sentence, and it is written in Swift rather than C++ for exactly that reason.
///
/// THE READ IS PER ELEMENT BY VALUE, which is `CSSCalcSwiftParseCursor::tokenAt`'s shape at 40 bytes
/// instead of 24, and it is what keeps the island at `unsafe` = 0: Swift cannot RECEIVE a
/// bounds-carrying view from C++ at all (rdar://186723514, filings 27), so no `Span` of the store's
/// buffer can cross. The nodes are copied into the same kind of stack buffer the parse already uses,
/// and the existing `emitParsedRoot` runs over it unchanged -- no second emit, no second
/// representation, no C++ rewritten against the flat form.
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

/// A test-only exhaustive differential over the two `Type`-algebra arms, driven ENTIRELY FROM SWIFT.
///
/// It lives here, not in `CSSTokenizerSwiftBridge.cpp`, because everything it needs is reachable
/// from Swift: the C++ arm through the interop boundary, the Swift arm directly. Written as a
/// bridge entry it would have been ~120 lines of C++ restating the universe; written here the C++
/// side of the harness is the two `@_expose(Cxx)` declarations the compiler generates, and the
/// stage's "zero new C++" claim survives the *validation*, not just the port.
///
/// Both arms are named EXPLICITLY (`.cpp` / `.swift`), never `defaultTypeAlgebra`, so the
/// differential is valid whichever arm the build ships -- the same reason `CSSCalc::Simplifier` is
/// named explicitly by the existing bridge, and the reason an ignored build flag cannot masquerade
/// here as a pass.
///
/// Compiled out of every shipping configuration by the gate above, so it is test-only C++'s Swift
/// counterpart and belongs in neither ratio.
private struct CalcTypeAlgebraDifferential {

    // The counters, in the order `cssCalcTypeAlgebraDifferentialCounter` reports them. Every one of
    // these exists to make a specific way of measuring nothing FAIL LOUDLY rather than pass; the
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

    // B2's additions.
    var addCases = 0                 // 15
    var addMismatches = 0            // 16
    var addCppEngaged = 0            // 17 V1 for `add`
    var addCppHintChanged = 0        // 18 V4: ONLY the provisional-hint branch can set a hint
                                     //    neither operand carried, and this is read off the C++
                                     //    arm alone, so it is independent of the code under test
    var sameTypeMismatches = 0       // 19
    var madeConsistentMismatches = 0 // 20
    var madeConsistentCppEngaged = 0 // 21 V1
    var consistentTypeMismatches = 0 // 22
    var applyHintCases = 0           // 23 V5
    var applyHintMismatches = 0      // 24
    var applyHintOverflowInputs = 0  // 25 V4: the `&+` lane of `applyPercentHint`, AXIS 2 ONLY
    var applyHintOutOfRangeCases = 0 // 26 V4: the `default:` arm, which aliases onto `length`
    var mergeCouldCopyInputs = 0     // 27 pairs where `add`'s merge loop could actually copy a lane

    /// The 8 bytes of a `Type` as one integer: the verdict's cross-check, and the key the distinct
    /// counts are taken over.
    ///
    /// This is the `memcmp` half of the design's "`operator==` decides, a byte compare cross-checks"
    /// rule. If the two ever disagree, `Type` has acquired padding and its `static_assert(sizeof ==
    /// 8)` has stopped telling the whole truth -- which is exactly the shape that makes a bitwise
    /// test pass for months and then fail on an unrelated build.
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

    /// AXIS 1 -- the reachable set: what the parser and simplifier can actually build.
    ///
    /// The seed is the eight values `determineType` can return: `makeNumber()` plus the seven unit
    /// vectors. That is not an approximation of `determineType`'s 70-way switch, it is its whole
    /// range, which is worth stating because it is what bounds this axis to something exhaustible.
    /// Crossed with the seven hint states, then closed under `invert` and one round of `multiply`.
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
        // One closure round through the C++ arm, so the closure itself cannot be biased by the code
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

    /// AXIS 2 -- the parameter boundary, which the reachable set can NEVER produce.
    ///
    /// This is the axis the two arithmetic hazards live on and the only axis that can distinguish
    /// `0 &- x` from `-x` or `addingReportingOverflow` from `&+`. A sweep without it is inert on
    /// exactly the substitutions this port introduces, and the four times this project shipped a
    /// differential that was exhaustive on the wrong axis are why it is built rather than argued.
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
            // One saturated lane, in each of the seven positions.
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
                // A hint ON a saturated type: the two hazards crossed with the hint machinery.
                var hinted = t
                hinted.applyPercentHint(.Length)
                add(hinted)
            }
            // Two saturated lanes, so an overflow in one lane cannot be confused with an early exit.
            var pair = CalcType()
            pair.length = e
            pair.percent = e
            add(pair)
            // Every lane saturated.
            var all = CalcType()
            all.length = e; all.angle = e; all.time = e; all.frequency = e
            all.resolution = e; all.flex = e; all.percent = e
            add(all)
        }
        return universe
    }

    /// Whether the C++ `multiply` must refuse this pair for overflow, computed in `Int` by a THIRD
    /// implementation that cannot overflow at all.
    ///
    /// Deliberately not derived from either arm: a coverage counter computed by the code under test
    /// reports that the code agrees with itself. This is the independent oracle for the exit.
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

                // Engagement first, payload only when BOTH are engaged. A `memcmp` over a
                // disengaged `std::optional<Type>` reads indeterminate payload bytes and is the
                // flaky test that passes for months.
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

        // ---- B2: `applyPercentHint`, over every value crossed with all six hints AND an
        // out-of-range one. The out-of-range case is not hypothetical: an imported C++ enum's
        // `init?(rawValue:)` never fails, and an out-of-range hint aliasing onto `length` through
        // `Type::operator[](PercentHint)` is a bug this island already shipped once
        // (`percentHintFromRawValue`'s comment). It is the only thing that exercises the Swift
        // port's `default:` arm.
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
                // Independent oracle, in `Int`, for the `&+` lane: does the hinted lane's sum leave
                // `Int8`? Lane selection mirrors the C++'s, including the out-of-range aliasing.
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

        // ---- B2: `add`, `sameType`, `consistentType`, `madeConsistent` over the same ordered pairs.
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
                    // Read off the C++ ARM ALONE: a result whose hint matches neither operand's can
                    // only have come from the provisional-hint branch, because the first branch
                    // returns `type1`'s hint after step 2 made the two agree.
                    if !(cpp.percentHint == a.percentHint) && !(cpp.percentHint == b.percentHint) {
                        addCppHintChanged += 1
                    }
                default:
                    addMismatches += 1
                }

                // `consistentType` IS `add` in both arms, so this is a cheap check that the two
                // entry points did not drift apart, not a second sweep of the algebra.
                switch (calcTypeConsistentType(a, b, .cpp), calcTypeConsistentType(a, b, .swift)) {
                case (nil, nil): break
                case let (cpp?, swift?): if !(cpp == swift) { consistentTypeMismatches += 1 }
                default: consistentTypeMismatches += 1
                }

                // Is `add`'s merge loop ("copy all of type2's entries that finalType doesn't
                // already contain") able to copy anything at all? It runs only after
                // `allNonZeroValuesEqual` has passed BOTH WAYS, which forces every non-zero lane of
                // one operand to equal the other's -- so a lane that is zero in type1 and non-zero
                // in type2 would have failed the second call. Computed here in plain `Int` over the
                // RAW operands (step 2 touches only `percentHint`, never a lane), so it shares no
                // code with either arm. Predicted 0: the loop is dead under its own precondition,
                // which is why a control that perturbs it is inert.
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
///
/// One entry point that re-runs the sweep per call, rather than a cached global: a `var` at file
/// scope is `nonisolated global shared mutable state` and does not compile under this module's
/// concurrency settings. The sweep is a few hundred thousand integer operations, so re-running it
/// is cheaper than the machinery that would make a global legal, and it removes any question of a
/// harness reading a counter from a stale run.
///
/// `UInt64.max` for an index this build does not have, so a harness reading a counter that does not
/// exist gets an unmistakable value rather than a plausible zero.
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

// MARK: - The parse path's token boundary (P7b stage C), differential only

/// Reads every token of one `calc()` through the Stage C boundary and folds it into a checksum.
///
/// This exists to prove the boundary before a grammar is written on it, and it is the whole of
/// stage C's Swift side. `CSSCalcSwiftParseCursor` imports with **zero `unsafe` markers**, which is
/// the property the design turns on: the cursor is `SWIFT_SAFE`, and every token crosses BY VALUE
/// as a 24-byte POD carrying no pointer.
///
/// The fold is order-dependent and mixes every field, so a boundary that dropped a field, truncated
/// one, or returned tokens in the wrong order produces a different checksum. The C++ side computes
/// the same fold straight off the `CSSParserTokenRange`, so the two disagree if and only if the
/// boundary is wrong -- and the axes it varies are the token TYPES and the field VALUES, which is
/// what a corpus of real `calc()` text sweeps.
///
/// Reading past the end is deliberate in the caller, not guarded here: `tokenAt` yields an EOF
/// token past the end exactly as `CSSParserTokenRange::peek` does, and the differential checks that
/// too rather than stopping at `tokenCount`.
@_expose(Cxx)
public func cssCalcParseTokenChecksumSwift(_ cursor: WebCore.CSSCalc.CSSCalcSwiftParseCursor) -> UInt64 {
    var hash: UInt64 = 0xcbf29ce484222325

    @inline(always)
    func mix(_ value: UInt64) {
        hash = (hash ^ value) &* 0x100000001b3
    }

    // One past the count, so the EOF-past-the-end behaviour is part of what is compared.
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
        // Folded so the field crosses under test at all. NOTE, stated rather than implied: a
        // field-sensitivity PAIR cannot isolate `flags`, because it is a pure function of `unit`
        // and `functionId`, which are folded above -- two inputs differing in `flags` necessarily
        // differ in one of those too. The direct checks in `webCoreCSSCalcCompareParse`'s
        // self-tests are what cover it.
        mix(UInt64(token.flags))
    }
    return hash
}



#endif
