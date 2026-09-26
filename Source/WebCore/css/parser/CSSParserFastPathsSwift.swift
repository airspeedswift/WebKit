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

// Only the boundary types, not the WebCore_Private umbrella, which reaches JavaScriptCore
// headers whose definitions live in explicit submodules nothing imports.
public import WebCore_Private.CSSTokenizerSwiftTypes

// Swift implementation of the color fast paths in CSSParserFastPaths.cpp, used when WebCore is
// built with WK_USE_SWIFT_CSS: hex, named and `rgb()`/`hsl()` colors.
//
// The numeric color forms run floating point and must match the C++ bit for bit; "MARK: -
// Bit-exactness" below lists the rounding sites where that is not automatic.
//
// The named-color table stays gperf output in C++ and is reached through
// `cssSwiftFindNamedColor`.

/// What a fast-path scan concluded. `declined` is part of the numbering CSSParserFastPaths.cpp
/// asserts, but no scan in this file produces it.
///
/// `@c` (SE-0495) emits this into WebCoreSwift-Generated.h as a `uint8_t`-backed C enum, so the
/// C++ names `CSSSwiftColorOutcomeParsed` directly. Internal rather than `public` because `@c` on
/// a resilient enum crashes IRGen and WebCore compiles with library evolution.
@c
enum CSSSwiftColorOutcome: UInt8 {
    case notAColor = 0
    case parsed
    case declined
}

/// A code unit a candidate can be spelled in, with the width-specific `parseCSSNumber` upcall, so
/// that a scan generic over the unit reaches the right C++ function without a runtime test.
private protocol CSSColorCodeUnit: CSSCodeUnit {
    /// `parseCSSNumber` (CSSParserFastPaths.cpp) over `characters`.
    static func parseCSSNumber(_ characters: Span<Self>) -> WebCore.CSSSwiftDoubleScan
}

extension UInt8: CSSColorCodeUnit {
    @inline(always)
    static func parseCSSNumber(_ characters: Span<UInt8>) -> WebCore.CSSSwiftDoubleScan {
        WebCore.cssSwiftParseCSSNumber8(characters)
    }
}

extension UInt16: CSSColorCodeUnit {
    @inline(always)
    static func parseCSSNumber(_ characters: Span<UInt16>) -> WebCore.CSSSwiftDoubleScan {
        WebCore.cssSwiftParseCSSNumber16(characters)
    }
}

@inline(always)
private func widen(_ unit: some CSSCodeUnit) -> UInt32 { UInt32(truncatingIfNeeded: unit) }

// MARK: - Character predicates
//
// Each mirrors an ASCIICType.h helper exactly, since the precise spelling matters for UTF-16 input.

/// `isASCII`.
@inline(always)
private func isASCIIUnit(_ unit: UInt32) -> Bool { unit & ~0x7F == 0 }

/// `isASCIIHexDigit` and `toASCIIHexValue` fused.
///
/// Kept separate, the value's subtraction carries an overflow check the range test has already
/// made redundant. The wrapping arithmetic is exact: `unit &- 0x30 < 10` is `unit >= 0x30 && unit
/// <= 0x39` over `UInt32`.
@inline(always)
private func hexDigitValue(_ unit: UInt32) -> UInt32? {
    let digit = unit &- 0x30
    if digit < 10 {
        return digit
    }
    let letter = (unit | 0x20) &- 0x61
    if letter < 6 {
        return letter &+ 10
    }
    return nil
}

/// `toASCIILower` for a character already known to be ASCII: the same mapping as
/// `asciiCaseFoldTable` over 0x00-0x7F, without the load.
@inline(always)
private func toASCIILowerUnit(_ unit: UInt32) -> UInt8 {
    let byte = UInt8(truncatingIfNeeded: unit)
    return (byte >= 0x41 && byte <= 0x5A) ? byte + 0x20 : byte
}

// MARK: - Hex colors

/// `finishParsingHexColor`, answering a packed `PackedColor::ARGB` for every length so that the
/// C++ caller needs one conversion.
@inline(always)
private func finishParsingHexColorARGB(_ value: UInt32, _ length: Int) -> UInt32? {
    switch length {
    case 3:
        // #234 converts to #223344.
        let r = (value & 0x0F00) >> 8
        let g = (value & 0x00F0) >> 4
        let b = value & 0x000F
        return 0xFF00_0000 | (r << 4 | r) << 16 | (g << 4 | g) << 8 | (b << 4 | b)
    case 4:
        // #234a converts to #223344aa.
        let r = (value & 0xF000) >> 12
        let g = (value & 0x0F00) >> 8
        let b = (value & 0x00F0) >> 4
        let a = value & 0x000F
        return (a << 4 | a) << 24 | (r << 4 | r) << 16 | (g << 4 | g) << 8 | (b << 4 | b)
    case 6:
        return 0xFF00_0000 | value
    case 8:
        // The input order is RGBA, which `asSRGBA(PackedColor::RGBA)` reads as
        // 0xRRGGBBAA; ARGB wants the alpha byte first.
        return (value & 0xFF) << 24 | (value >> 8)
    default:
        return nil
    }
}

/// `parseHexColorInternal`.
///
/// No leading `#`: the caller has already consumed one, or is on the quirks-mode path where
/// there was none.
@inline(always)
private func scanHexColor<Unit: CSSCodeUnit>(_ characters: Span<Unit>) -> WebCore.CSSSwiftColor {
    let count = characters.count
    guard count == 3 || count == 4 || count == 6 || count == 8 else {
        return notAColor
    }

    var value: UInt32 = 0
    for index in 0..<count {
        guard let digit = hexDigitValue(widen(characters[index])) else {
            return notAColor
        }
        value = value << 4 | digit
    }

    guard let argb = finishParsingHexColorARGB(value, count) else {
        return notAColor
    }
    return WebCore.CSSSwiftColor(argb: argb, outcome: CSSSwiftColorOutcome.parsed.rawValue)
}

// MARK: - Named colors

/// `parseNamedColorInternal`, folding into an `InlineArray` whose own bound checks each write.
///
/// No NUL terminator is written: gperf's `findColorImpl` reads only `str[0 ..< len]`. The fold
/// buffer is longer than `maximumColorNameLength` (CSSParserFastPaths.h), so a candidate that does
/// not fit cannot name a color.
@inline(always)
private func scanNamedColor<Unit: CSSCodeUnit>(_ characters: Span<Unit>) -> WebCore.CSSSwiftColor {
    let count = characters.count
    // Declared before the guard so that the guard tests the buffer's own size, which is the bound
    // `folded[index]` relies on.
    var folded = InlineArray<24, UInt8>(repeating: 0)
    guard count <= folded.count else {
        return notAColor
    }

    for index in 0..<count {
        let value = widen(characters[index])
        // `!character || !isASCII(character)`: a NUL would make the table lookup read a shorter
        // string than it was given a length for, and non-ASCII cannot name a color.
        guard value != 0, isASCIIUnit(value) else {
            return notAColor
        }
        folded[index] = toASCIILowerUnit(value)
    }

    return WebCore.cssSwiftFindNamedColor(folded.span.extracting(0..<count))
}

/// The one spelling of a rejection.
///
/// A `let` of a constant, so it needs no `swift_once`.
private let notAColor = WebCore.CSSSwiftColor(argb: 0, outcome: CSSSwiftColorOutcome.notAColor.rawValue)

// MARK: - Bit-exactness
//
// `parseHSL` and the `rgb()`/`rgba()` branch of `parseNumericColor` run floating point, and the
// Swift must produce bit-identical output. Three sites need care:
//
// 1. Contraction. WebCore builds with `-ffp-contract=on`, so
//    `ColorConversion<ExtendedSRGBA<float>, HSLA<float>>::convert`'s
//    `scaledLightness - (a * max(...))` is a single `fmadd`. `addingProduct` reproduces it; a
//    plain `lightness - a * t` rounds twice. No other float expression on these paths contracts.
//
// 2. Narrowing order. `narrowPrecisionToFloat` and `convertPrescaledSRGBAFloatToSRGBAByte`'s
//    `float` parameter narrow a `double` before `lround`, and each site below narrows in the same
//    place. `std::lround` is `.toNearestOrAwayFromZero`, not Swift's default `.toNearestOrEven`,
//    and the C++ clamps after rounding.
//
// 3. Decimal parsing. Saturation, lightness, alpha and every `rgb()` component use
//    CSSParserFastPaths.cpp's own `parseDouble`, which is `parseLocalDouble` here. The hue uses
//    `parseCSSNumber`, which is `fast_float::from_chars` and correctly rounded. `scanExactDouble`
//    answers with Clinger's fast path, the exact case fast_float itself takes first: a
//    significand <= 2^53 and a decimal exponent in [-22, 22] make
//    `Double(significand) * or / exactPowerOfTen` a single correctly-rounded operation. Outside
//    that domain it calls `parseCSSNumber` itself, so the result is the C++'s by construction.
//    `Double(String)` is not usable: it allocates, and accepts hex floats, `inf` and `nan`.

/// `convertPrescaledSRGBAFloatToSRGBAByte`: `std::clamp(std::lround(value), 0l, 255l)` on a
/// `float`.
///
/// The C++ parameter is `float` and every caller passes a `double`, so the value is narrowed
/// before rounding.
///
/// The clamp cannot fire on this path, since `parseColorIntOrPercentage` bounds the value to
/// [0, 255]; it is kept so the function matches the C++ for every argument.
@inline(always)
private func convertPrescaledSRGBAFloatToSRGBAByte(_ value: Double) -> UInt8 {
    let narrowed = Float(value)
    let rounded = narrowed.rounded(.toNearestOrAwayFromZero)
    if !(rounded > 0) {
        // Also the NaN case, which `UInt8(_:)` would trap on.
        return 0
    }
    if rounded >= 255 {
        return 255
    }
    return UInt8(rounded)
}

/// `convertFloatAlphaTo<uint8_t>`: `std::clamp(std::lround(value * 255.0f), 0l, 255l)`.
///
/// The value is narrowed first, so the multiply by 255 is single precision.
@inline(always)
private func convertFloatAlphaToByte(_ value: Double) -> UInt8 {
    let narrowed = Float(value)
    let scaled = narrowed * 255
    let rounded = scaled.rounded(.toNearestOrAwayFromZero)
    if !(rounded > 0) {
        return 0
    }
    if rounded >= 255 {
        return 255
    }
    return UInt8(rounded)
}

// MARK: - Character predicates for the numeric paths

/// `isASCIIDigit`.
@inline(always)
private func isASCIIDigitUnit(_ unit: UInt32) -> Bool { unit &- 0x30 < 10 }

/// `isCSSSpace`: space, tab and newline only. `parseHSL` ends the hue token with this, so a `\r`
/// stays in the token, where `charactersToDouble` skips it as leading whitespace.
@inline(always)
private func isCSSSpaceUnit(_ unit: UInt32) -> Bool { unit == 0x20 || unit == 0x09 || unit == 0x0A }

/// `isASCIIWhitespace`: space, `\n`, `\t`, `\r`, `\f`. `parseColorIntOrPercentage` and
/// `parseRGBAlphaValue` use this one, so the `rgb()` and `hsl()` paths disagree about `\r`.
@inline(always)
private func isASCIIWhitespaceUnit(_ unit: UInt32) -> Bool {
    unit == 0x20 || unit == 0x0A || unit == 0x09 || unit == 0x0D || unit == 0x0C
}

/// `isUnicodeCompatibleASCIIWhitespace`: `isASCIIWhitespace` plus `\v`, which is what
/// `charactersToDouble` skips before the hue.
@inline(always)
private func isUnicodeCompatibleASCIIWhitespaceUnit(_ unit: UInt32) -> Bool {
    isASCIIWhitespaceUnit(unit) || unit == 0x0B
}

/// `isASCIIAlphaCaselessEqual(unit, letter)`.
///
/// The comparison is against the whole code unit, so `| 0x20` cannot make a UTF-16 character
/// equal an ASCII letter.
@inline(always)
private func isASCIIAlphaCaselessEqualUnit(_ unit: UInt32, _ letter: UInt32) -> Bool {
    unit | 0x20 == letter
}

// MARK: - A cursor over the candidate

/// The candidate plus a position in it, standing in for the C++'s `std::span` mutated through
/// ParsingUtilities.h's `skip`/`skipExactly`/`consume`. `~Escapable` because `Span` is: the
/// storage belongs to the C++ caller for the duration of the call.
private struct ColorCursor<Unit: CSSColorCodeUnit>: ~Escapable {
    let characters: Span<Unit>
    /// How much of the candidate has been consumed.
    var offset: Int = 0

    @inline(always)
    @_lifetime(copy characters)
    init(_ characters: Span<Unit>) {
        self.characters = characters
    }

    /// The length of the whole candidate, not of what remains.
    var count: Int {
        @inline(always)
        get { characters.count }
    }

    /// One code unit of the candidate, by absolute index.
    @inline(always)
    func unit(_ index: Int) -> UInt32 { widen(characters[index]) }

    /// `parseCSSNumber` over `[start, end)` of the candidate, for where Clinger's fast path does
    /// not apply.
    @inline(always)
    func parseNumber(_ start: Int, _ end: Int) -> (value: Double, ok: Bool) {
        let scan = Unit.parseCSSNumber(characters.extracting(start..<end))
        return (scan.value, scan.ok != 0)
    }

    /// `characters.empty()`.
    var isEmpty: Bool {
        @inline(always)
        get { offset >= count }
    }

    /// `characters.size()`.
    var remaining: Int {
        @inline(always)
        get { count - offset }
    }

    /// `characters.front()`, or `nil` at the end.
    @inline(always)
    func front() -> UInt32? { offset < count ? unit(offset) : nil }

    /// `characters[index]`, relative to the current position.
    @inline(always)
    func at(_ index: Int) -> UInt32 { unit(offset + index) }

    /// `skip(characters, n)`.
    @inline(always)
    mutating func skip(_ n: Int) { offset += n }

    /// `skipExactly(characters, c)`: consumes one unit if it matches, and reports whether it did.
    @inline(always)
    mutating func skipExactly(_ expected: UInt32) -> Bool {
        guard offset < count, unit(offset) == expected else {
            return false
        }
        offset += 1
        return true
    }

    /// `skipWhile<isASCIIWhitespace>`.
    @inline(always)
    mutating func skipASCIIWhitespace() {
        while offset < count, isASCIIWhitespaceUnit(unit(offset)) {
            offset += 1
        }
    }

    /// Skips CSS whitespace.
    ///
    /// `skipWhile<isCSSSpace>`, as used by the `skipWhitespace` lambda in `parseHSL`.
    @inline(always)
    mutating func skipCSSSpace() {
        while offset < count, isCSSSpaceUnit(unit(offset)) {
            offset += 1
        }
    }

    /// `skipWhile<isASCIIDigit>`.
    @inline(always)
    mutating func skipASCIIDigits() {
        while offset < count, isASCIIDigitUnit(unit(offset)) {
            offset += 1
        }
    }
}

// MARK: - The file's own decimal parser

/// `checkForValidDouble`: the number of characters forming a valid double terminated by
/// `terminator`, or 0, including when there is no terminator.
///
/// A non-zero result therefore means the terminator is still there to be read.
@inline(always)
private func checkForValidDouble<Unit: CSSColorCodeUnit>(_ cursor: borrowing ColorCursor<Unit>, _ terminator: UInt32) -> Int {
    let length = cursor.remaining
    if length < 1 {
        return 0
    }

    var decimalMarkOffset: Int? = nil
    var processedLength = 0

    for index in 0..<length {
        let value = cursor.at(index)
        if value == terminator {
            processedLength = index
            break
        }
        if !isASCIIDigitUnit(value) {
            guard decimalMarkOffset == nil, value == 0x2E else {
                return 0
            }
            decimalMarkOffset = index
        }
    }

    // "CSS disallows a period without a subsequent digit." With no terminator `processedLength` is
    // 0 and the C++'s `processedLength - 1` wraps without effect; `&- 1` wraps the same way.
    if let mark = decimalMarkOffset, mark == processedLength &- 1 {
        return 0
    }

    return processedLength
}

/// CSSParserFastPaths.cpp's own `parseDouble`, not WTF's: the number of characters consumed and
/// the value, or nil.
///
/// The C++'s `localValue * 10 + digit` and `fraction * 10 + digit` may be contracted to `fmadd`,
/// and neither can observe it. The fraction stays below 1e7, so every intermediate is an exact
/// integer. The integral part diverges only past 2^53, and every caller either bounds it far below
/// that (`parseColorIntOrPercentage` clamps at 255) or gives one answer above it (out of gamut, or
/// an alpha clamped to 1).
@inline(always)
private func parseLocalDouble<Unit: CSSColorCodeUnit>(
    _ cursor: borrowing ColorCursor<Unit>,
    _ terminator: UInt32
) -> (length: Int, value: Double)? {
    let length = checkForValidDouble(cursor, terminator)
    if length == 0 {
        return nil
    }

    var position = 0
    var localValue: Double = 0

    // `checkForValidDouble` has established that these are ASCII digits and at most one '.'.
    while position < length {
        let value = cursor.at(position)
        if value == 0x2E {
            break
        }
        localValue = localValue * 10 + Double(value &- 0x30)
        position += 1
    }

    // The C++'s `if (++position == length)` steps over the '.' or past the end.
    position += 1
    if position == length {
        return (length, localValue)
    }

    var fraction: Double = 0
    var scale: Double = 1
    let maxScale: Double = 1_000_000

    while position < length, scale < maxScale {
        fraction = fraction * 10 + Double(cursor.at(position) &- 0x30)
        position += 1
        scale *= 10
    }

    return (length, localValue + fraction / scale)
}

// MARK: - The correctly-rounded parser the hue needs

/// The powers of ten exactly representable in a `Double`, 1e0 through 1e22, as literals so that no
/// entry is the product of an inexact multiply.
private let exactPowersOfTen: InlineArray<23, Double> = [
    1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11,
    1e12, 1e13, 1e14, 1e15, 1e16, 1e17, 1e18, 1e19, 1e20, 1e21, 1e22,
]

private enum ExactDoubleScan {
    case value(Double)
    case invalid
}

/// `parseCSSNumber` over the hue token: `charactersToDouble` with `TrailingJunkPolicy::Disallow`
/// and `WhitespacePolicy::Skip`, accepting fast_float's `general | no_infnan | allow_leading_plus`
/// grammar.
///
/// The value comes from Clinger's fast path where that is exact, and from `cursor.parseNumber`
/// otherwise; see "MARK: - Bit-exactness".
private func scanExactDouble<Unit: CSSColorCodeUnit>(_ cursor: borrowing ColorCursor<Unit>, _ start: Int, _ end: Int) -> ExactDoubleScan {
    var index = start

    // `charactersToDouble` skips leading whitespace, including `\v`.
    while index < end, isUnicodeCompatibleASCIIWhitespaceUnit(cursor.unit(index)) {
        index += 1
    }

    let numberStart = index
    var negative = false
    if index < end, cursor.unit(index) == 0x2D {
        negative = true
        index += 1
    } else if index < end, cursor.unit(index) == 0x2B {
        // `allow_leading_plus`.
        index += 1
    }

    // The significand as an integer with a decimal exponent, the form Clinger's path needs.
    // Leading zeros are not significant digits.
    var significand: UInt64 = 0
    var digits = 0
    var overflowed = false
    var exponent = 0
    var sawDigit = false

    @inline(always)
    func accumulate(_ unit: UInt32) {
        sawDigit = true
        if significand == 0, unit == 0x30 {
            // A leading zero contributes nothing and is not a significant digit.
            return
        }
        let (product, mulOverflow) = significand.multipliedReportingOverflow(by: 10)
        if mulOverflow {
            overflowed = true
            return
        }
        let (sum, addOverflow) = product.addingReportingOverflow(UInt64(unit &- 0x30))
        if addOverflow {
            overflowed = true
            return
        }
        significand = sum
        digits += 1
    }

    while index < end, isASCIIDigitUnit(cursor.unit(index)) {
        accumulate(cursor.unit(index))
        index += 1
    }

    var sawDot = false
    if index < end, cursor.unit(index) == 0x2E {
        sawDot = true
        index += 1
        while index < end, isASCIIDigitUnit(cursor.unit(index)) {
            accumulate(cursor.unit(index))
            // Every fraction digit moves the exponent, leading zeros included: `0.001` is
            // significand 1 at exponent -3. An overflowed significand leaves the exponent wrong,
            // but that case re-parses the token through `upcallParseNumber`.
            exponent -= 1
            index += 1
        }
    }

    if !sawDigit {
        return .invalid
    }

    // `parseCSSNumber` rejects a trailing '.'.
    if sawDot, index == end, cursor.unit(index - 1) == 0x2E {
        return .invalid
    }

    if index < end, cursor.unit(index) | 0x20 == 0x65 {
        let exponentMarker = index
        var cursorIndex = index + 1
        var exponentNegative = false
        if cursorIndex < end, cursor.unit(cursorIndex) == 0x2D {
            exponentNegative = true
            cursorIndex += 1
        } else if cursorIndex < end, cursor.unit(cursorIndex) == 0x2B {
            cursorIndex += 1
        }
        if cursorIndex < end, isASCIIDigitUnit(cursor.unit(cursorIndex)) {
            var explicitExponent = 0
            while cursorIndex < end, isASCIIDigitUnit(cursor.unit(cursorIndex)) {
                if explicitExponent < 1_000_000 {
                    explicitExponent = explicitExponent * 10 + Int(cursor.unit(cursorIndex) &- 0x30)
                }
                cursorIndex += 1
            }
            exponent += exponentNegative ? -explicitExponent : explicitExponent
            index = cursorIndex
        } else {
            // `1e` with no exponent digits: fast_float consumes only `1`, which leaves trailing
            // junk and a rejection.
            index = exponentMarker
        }
    }

    // `TrailingJunkPolicy::Disallow`: `ok` is `parsedLength == data.size()`.
    if index != end {
        return .invalid
    }
    // A bare sign.
    if numberStart == end {
        return .invalid
    }

    if overflowed || digits > 19 {
        return upcallParseNumber(cursor, start, end)
    }
    // Clinger's conditions, from fast_float's `clinger_fast_path_impl`: an exactly representable
    // significand and power of ten.
    if significand > (1 << 53) {
        return upcallParseNumber(cursor, start, end)
    }
    if exponent < -22 || exponent > 22 {
        return upcallParseNumber(cursor, start, end)
    }

    // One correctly-rounded operation on exact operands, so the correctly-rounded conversion.
    var value = Double(significand)
    if exponent < 0 {
        value = value / exactPowersOfTen[-exponent]
    } else {
        value = value * exactPowersOfTen[exponent]
    }
    return .value(negative ? -value : value)
}

/// `parseCSSNumber` over the whole token, for a token Clinger's fast path cannot answer exactly.
///
/// The range is the token's, not the accumulated digits, so the C++ does its own whitespace, sign
/// and trailing-junk handling.
@inline(always)
private func upcallParseNumber<Unit: CSSColorCodeUnit>(_ cursor: borrowing ColorCursor<Unit>, _ start: Int, _ end: Int) -> ExactDoubleScan {
    let scan = cursor.parseNumber(start, end)
    return scan.ok ? .value(scan.value) : .invalid
}

// MARK: - rgb() / rgba()

/// Whether the components seen so far are numbers or percentages; the first decides for all three.
private enum ColorUnitType { case unknown, number, percentage }

/// `parseColorIntOrPercentage`.
///
/// Consumes one component and, on success only, advances the cursor past it.
@inline(always)
private func parseColorIntOrPercentage<Unit: CSSColorCodeUnit>(
    _ cursor: inout ColorCursor<Unit>,
    _ consumableTerminator: UInt32?,
    _ expectedUnitType: inout ColorUnitType
) -> UInt8? {
    var current = cursor

    var localValue: Double = 0
    var negative = false
    current.skipASCIIWhitespace()

    if current.skipExactly(0x2D) {
        negative = true
    }

    guard let first = current.front(), isASCIIDigitUnit(first) else {
        return nil
    }

    while let value = current.front(), isASCIIDigitUnit(value) {
        current.skip(1)
        let newValue = localValue * 10 + Double(value &- 0x30)
        if newValue >= 255 {
            // "Clamp values at 255."
            localValue = 255
            current.skipASCIIDigits()
            break
        }
        localValue = newValue
    }

    guard let afterDigits = current.front() else {
        return nil
    }

    if expectedUnitType == .number, afterDigits == 0x2E || afterDigits == 0x25 {
        return nil
    }

    if afterDigits == 0x2E {
        // "We already parsed the integral part, try to parse the fraction part of the percentage
        // value."
        guard let parsed = parseLocalDouble(current, 0x25) else {
            return nil
        }
        current.skip(parsed.length)
        // A non-zero length from `parseLocalDouble` means the '%' is there.
        guard current.front() == 0x25 else {
            return nil
        }
        localValue += parsed.value
    }

    if expectedUnitType == .percentage, current.front() != 0x25 {
        return nil
    }

    if current.skipExactly(0x25) {
        expectedUnitType = .percentage
        // Divide, then multiply: the other order differs in the last bit.
        localValue = localValue / 100.0 * 255.0
        // "Clamp values at 255 for percentages over 100%"
        if localValue > 255 {
            localValue = 255
        }
    } else {
        expectedUnitType = .number
    }

    current.skipASCIIWhitespace()

    if let terminator = consumableTerminator, !current.skipExactly(terminator) {
        return nil
    }

    cursor.offset = current.offset

    // "Clamp negative values at zero."
    assert(localValue <= 255)
    return negative ? 0 : convertPrescaledSRGBAFloatToSRGBAByte(localValue)
}

/// `isTenthAlpha`: `"0.X"` or `".X"`.
@inline(always)
private func isTenthAlpha<Unit: CSSColorCodeUnit>(_ cursor: borrowing ColorCursor<Unit>, _ length: Int) -> Bool {
    if length == 3, cursor.at(0) == 0x30, cursor.at(1) == 0x2E, isASCIIDigitUnit(cursor.at(2)) {
        return true
    }
    if length == 2, cursor.at(0) == 0x2E, isASCIIDigitUnit(cursor.at(1)) {
        return true
    }
    return false
}

/// `parseRGBAlphaValue`.
///
/// On success the whole candidate is consumed, as the C++'s `string = { }` empties it.
@inline(always)
private func parseRGBAlphaValue<Unit: CSSColorCodeUnit>(_ cursor: inout ColorCursor<Unit>, _ terminator: UInt32) -> UInt8? {
    cursor.skipASCIIWhitespace()

    var negative = false
    if cursor.skipExactly(0x2D) {
        negative = true
    }

    let length = cursor.remaining
    if length < 2 {
        return nil
    }

    guard cursor.at(length - 1) == terminator, isASCIIDigitUnit(cursor.at(length - 2)) else {
        return nil
    }

    guard let first = cursor.front() else {
        return nil
    }

    if first != 0x30, first != 0x31, first != 0x2E {
        // Not 0, 1 or '.': anything else that is nonetheless a valid double saturates.
        if checkForValidDouble(cursor, terminator) != 0 {
            cursor.offset = cursor.count
            return negative ? 0 : 255
        }
        return nil
    }

    if length == 2, first != 0x2E {
        // "0)" or "1)".
        let result: UInt8 = (!negative && first == 0x31) ? 255 : 0
        cursor.offset = cursor.count
        return result
    }

    if isTenthAlpha(cursor, length - 1) {
        // The C++'s table: 26, 77 and 179 are not what rounding 0.1, 0.3 and 0.7 * 255 gives.
        let tenthAlphaValues: InlineArray<10, UInt8> = [0, 26, 51, 77, 102, 128, 153, 179, 204, 230]
        let digit = Int(cursor.at(length - 2) &- 0x30)
        let result: UInt8 = negative ? 0 : tenthAlphaValues[digit]
        cursor.offset = cursor.count
        return result
    }

    guard let parsed = parseLocalDouble(cursor, terminator) else {
        return nil
    }

    cursor.offset = cursor.count
    return negative ? 0 : convertFloatAlphaToByte(parsed.value)
}

// MARK: - hsl() / hsla()

/// The angle units `parseSimpleAngle` recognizes with `RequireUnits::No`. `grad` and `turn` are
/// not among them: `10turn` goes whole to `parseCSSNumber`, which rejects it.
private enum SimpleAngleUnit { case deg, rad }

/// `normalizeHue`: `fmod(fmod(hue, 360) + 360, 360)`.
///
/// The literals are `double`, so the C++ computes in `double` even for a `float` hue, and
/// so does this.
@inline(always)
private func normalizeHue(_ hue: Float) -> Float {
    let wide = Double(hue)
    return Float((wide.truncatingRemainder(dividingBy: 360.0) + 360.0).truncatingRemainder(dividingBy: 360.0))
}

/// `ColorConversion<ExtendedSRGBA<float>, HSLA<float>>::convert`, then the clamp to sRGB and the
/// conversion to bytes, in ARGB order.
///
/// The caller has already done the gamut check.
@inline(always)
private func hslaToSRGBABytes(hue: Float, saturation: Float, lightness: Float, alpha: Float) -> UInt32 {
    // `resolved()` maps NaN to 0. `scanHSL` has already rejected NaN, so these do not fire here.
    let h = hue.isNaN ? 0 : hue
    let s = saturation.isNaN ? 0 : saturation
    let l = lightness.isNaN ? 0 : lightness
    let a = alpha.isNaN ? 0 : alpha

    // A division, as in the C++: 1/30 is not exactly representable.
    let scaledHue = h / 30.0
    // The C++'s `1.0f / 100.0f` folds to the `float` 0.01; `/ 100.0` would differ.
    let scaledSaturation = s * (1.0 / 100.0 as Float)
    let scaledLightness = l * (1.0 / 100.0 as Float)

    let aTerm = scaledSaturation * min(scaledLightness, 1.0 - scaledLightness)

    func hueToRGB(_ n: Float) -> Float {
        let k = (n + scaledHue).truncatingRemainder(dividingBy: 12.0)
        // `std::max(-1.0f, std::min({ k - 3.0f, 9.0f - k, 1.0f }))`.
        let inner = max(-1.0, min(min(k - 3.0, 9.0 - k), 1.0))
        // The C++ contracts this to one `fmadd`; see "MARK: - Bit-exactness".
        return scaledLightness.addingProduct(-aTerm, inner)
    }

    // `clipToGamut` clamps the color components to [0, 1], then all four are scaled to bytes.
    func toByte(_ value: Float) -> UInt8 {
        let clamped = min(max(value, 0.0), 1.0)
        // `std::clamp(std::lround(value * 255.0f), 0l, 255l)`.
        let rounded = (clamped * 255.0).rounded(.toNearestOrAwayFromZero)
        if !(rounded > 0) {
            return 0
        }
        if rounded >= 255 {
            return 255
        }
        return UInt8(rounded)
    }

    let red = toByte(hueToRGB(0))
    let green = toByte(hueToRGB(8))
    let blue = toByte(hueToRGB(4))
    // `clipToGamut` leaves alpha alone, but the descriptor has already clamped it to [0, 1].
    let alphaByte = toByte(a)

    return UInt32(alphaByte) << 24 | UInt32(red) << 16 | UInt32(green) << 8 | UInt32(blue)
}

/// Parses a percentage for an HSL color.
///
/// The `parsePercentage` lambda in `parseHSL`. A free function because a `~Escapable` cursor
/// cannot be captured.
@inline(always)
private func parseColorPercentage<Unit: CSSColorCodeUnit>(_ cursor: inout ColorCursor<Unit>) -> Double? {
    cursor.skipCSSSpace()
    guard let parsed = parseLocalDouble(cursor, 0x25) else {
        return nil
    }
    cursor.skip(parsed.length)
    guard cursor.skipExactly(0x25) else {
        return nil
    }
    return parsed.value
}

/// `parseHSL`, over the text after `hsl(` or `hsla(`.
private func scanHSL<Unit: CSSColorCodeUnit>(_ cursor: inout ColorCursor<Unit>) -> WebCore.CSSSwiftColor {
    // "Find the end of the hue token (terminated by comma or whitespace). A comma means legacy
    // syntax (comma-separated), whitespace means modern (space-separated)."
    var hueEnd = 0
    var isLegacy = false
    while hueEnd < cursor.remaining {
        let value = cursor.at(hueEnd)
        if value == 0x2C {
            isLegacy = true
            break
        }
        if isCSSSpaceUnit(value) {
            break
        }
        hueEnd += 1
    }
    if hueEnd == 0 || hueEnd == cursor.remaining {
        return notAColor
    }

    // `parseSimpleAngle(characters.first(hueEnd), RequireUnits::No, angleUnit, hue)`.
    var angleUnit = SimpleAngleUnit.deg
    var numberEnd = cursor.offset + hueEnd
    let numberStart = cursor.offset
    if hueEnd >= 4 {
        let c3 = cursor.at(hueEnd - 3)
        let c2 = cursor.at(hueEnd - 2)
        let c1 = cursor.at(hueEnd - 1)
        if isASCIIAlphaCaselessEqualUnit(c3, 0x64), isASCIIAlphaCaselessEqualUnit(c2, 0x65),
            isASCIIAlphaCaselessEqualUnit(c1, 0x67)
        {
            numberEnd -= 3
            angleUnit = .deg
        } else if isASCIIAlphaCaselessEqualUnit(c3, 0x72), isASCIIAlphaCaselessEqualUnit(c2, 0x61),
            isASCIIAlphaCaselessEqualUnit(c1, 0x64)
        {
            numberEnd -= 3
            angleUnit = .rad
        }
        // An unrecognized suffix goes to `parseCSSNumber` with the number, which rejects it.
    } else {
        angleUnit = .deg
    }

    // `parseCSSNumber` rejects a trailing '.'.
    if numberEnd > numberStart, cursor.unit(numberEnd - 1) == 0x2E {
        return notAColor
    }

    let hueScan = scanExactDouble(cursor, numberStart, numberEnd)
    let hue: Double
    switch hueScan {
    case .value(let parsed):
        hue = parsed
    case .invalid:
        return notAColor
    }

    cursor.skip(hueEnd)

    // "In legacy syntax, components are separated by commas."
    if isLegacy, !cursor.skipExactly(0x2C) {
        return notAColor
    }

    guard let saturation = parseColorPercentage(&cursor) else {
        return notAColor
    }

    if isLegacy, !cursor.skipExactly(0x2C) {
        return notAColor
    }

    guard let lightness = parseColorPercentage(&cursor) else {
        return notAColor
    }

    cursor.skipCSSSpace()

    // "Alpha is optional. Legacy uses comma separator, modern uses slash."
    var alpha: Double = 1.0
    let alphaSeparator: UInt32 = isLegacy ? 0x2C : 0x2F
    if let next = cursor.front(), next == alphaSeparator {
        cursor.skip(1)
        cursor.skipCSSSpace()

        if let parsed = parseLocalDouble(cursor, 0x29) {
            cursor.skip(parsed.length)
            alpha = parsed.value
        } else if let parsed = parseLocalDouble(cursor, 0x25) {
            cursor.skip(parsed.length)
            guard cursor.skipExactly(0x25) else {
                return notAColor
            }
            alpha = parsed.value / 100.0
        } else {
            return notAColor
        }

        cursor.skipCSSSpace()
    }

    // Only the next character is checked, as in the C++, so `hsl(0,50%,50%)junk` parses where the
    // `rgb()` path would reject trailing text.
    guard cursor.front() == 0x29 else {
        return notAColor
    }

    // The typed-color conversion (CSSColorConversion+ToTypedColor.h, HSLFunctionModern).
    //
    // Hue: `narrowPrecisionToFloat(convertAngle<Deg>(hue, angleUnit))` is stored in a `double`
    // `Style::Angle<>`, and `normalizeHue` runs on that. So: convert, narrow, widen, normalize.
    let hueInDegrees: Double
    switch angleUnit {
    case .deg:
        hueInDegrees = hue
    case .rad:
        // `rad2deg`: one multiply by the folded `180.0 / std::numbers::pi`.
        hueInDegrees = hue * (180.0 / Double.pi)
    }
    let narrowedHue = Float(hueInDegrees)
    let normalizedHue = normalizeHue(narrowedHue)

    // Saturation and lightness are `Style::Percentage<>`, also stored narrowed in a `double`.
    // Saturation clamps to [0, +inf) and lightness not at all, both in `double`.
    let narrowedSaturation = Double(Float(saturation))
    let narrowedLightness = Double(Float(lightness))
    let clampedSaturation = Swift.max(narrowedSaturation, 0.0)
    let clampedLightness = narrowedLightness

    // Alpha clamps to [0, 1].
    let narrowedAlpha = Double(Float(alpha))
    let clampedAlpha = Swift.min(Swift.max(narrowedAlpha, 0.0), 1.0)

    // `convertToColor<HSLFunctionModern, Absolute>(typedColor, 0)`: a NaN component
    // (`anyComponentIsNone()`) or a color outside sRGB (`outsideSRGBGamut`) is stored out of line,
    // so `tryGetAsSRGBABytes()` returns `nullopt`. A hue beyond `FLT_MAX` narrows to infinity and
    // normalizes to NaN. The NaN test comes first because NaN fails no comparison in the gamut
    // test.
    let saturationFloat = Float(clampedSaturation)
    let lightnessFloat = Float(clampedLightness)
    let alphaFloat = Float(clampedAlpha)
    if normalizedHue.isNaN || saturationFloat.isNaN || lightnessFloat.isNaN || alphaFloat.isNaN {
        return notAColor
    }
    if saturationFloat > 100.0 || lightnessFloat < 0.0 || lightnessFloat > 100.0 {
        return notAColor
    }

    let argb = hslaToSRGBABytes(
        hue: normalizedHue,
        saturation: saturationFloat,
        lightness: lightnessFloat,
        alpha: alphaFloat
    )
    return WebCore.CSSSwiftColor(argb: argb, outcome: CSSSwiftColorOutcome.parsed.rawValue)
}

// MARK: - The numeric scan

/// `mightBeRGB`, `mightBeRGBA`, `mightBeHSL` and `mightBeHSLA`, which differ only in their letters.
///
/// Reads the candidate from its start, whatever the cursor's position.
@inline(always)
private func hasColorFunctionPrefix<Unit: CSSCodeUnit>(
    _ characters: Span<Unit>,
    _ c0: UInt32,
    _ c1: UInt32,
    _ c2: UInt32,
    _ c3: UInt32?,
    _ parenIndex: Int
) -> Bool {
    guard characters.count >= parenIndex + 1, widen(characters[parenIndex]) == 0x28 else {
        return false
    }
    guard isASCIIAlphaCaselessEqualUnit(widen(characters[0]), c0),
        isASCIIAlphaCaselessEqualUnit(widen(characters[1]), c1),
        isASCIIAlphaCaselessEqualUnit(widen(characters[2]), c2)
    else {
        return false
    }
    guard let c3 else {
        return true
    }
    return isASCIIAlphaCaselessEqualUnit(widen(characters[3]), c3)
}

/// `parseNumericColor` after its hex attempts, which the caller has already made through
/// `parseHexColorInternal`.
private func scanNumericColor<Unit: CSSColorCodeUnit>(_ characters: Span<Unit>) -> WebCore.CSSSwiftColor {
    var cursor = ColorCursor(characters)

    let isRGBA = hasColorFunctionPrefix(characters, 0x72, 0x67, 0x62, 0x61, 4)
    let isRGB = hasColorFunctionPrefix(characters, 0x72, 0x67, 0x62, nil, 3)

    if isRGB || isRGBA {
        cursor.skip(isRGBA ? 5 : 4)

        var expectedUnitType = ColorUnitType.unknown

        // "Red and green will both terminate with ','."
        guard let red = parseColorIntOrPercentage(&cursor, 0x2C, &expectedUnitType) else {
            return notAColor
        }
        guard let green = parseColorIntOrPercentage(&cursor, 0x2C, &expectedUnitType) else {
            return notAColor
        }

        // "Blue may terminate with ',' or ')', but do not consume either terminator."
        guard let blue = parseColorIntOrPercentage(&cursor, nil, &expectedUnitType) else {
            return notAColor
        }
        guard let afterBlue = cursor.front() else {
            return notAColor
        }

        // "Finish parsing rgb if no alpha value."
        if afterBlue == 0x29 {
            cursor.skip(1)
            guard cursor.isEmpty else {
                return notAColor
            }
            return WebCore.CSSSwiftColor(
                argb: 0xFF00_0000 | UInt32(red) << 16 | UInt32(green) << 8 | UInt32(blue),
                outcome: CSSSwiftColorOutcome.parsed.rawValue
            )
        }

        // "Parse alpha value if present."
        if afterBlue == 0x2C {
            cursor.skip(1)
            guard let alpha = parseRGBAlphaValue(&cursor, 0x29) else {
                return notAColor
            }
            guard cursor.isEmpty else {
                return notAColor
            }
            return WebCore.CSSSwiftColor(
                argb: UInt32(alpha) << 24 | UInt32(red) << 16 | UInt32(green) << 8 | UInt32(blue),
                outcome: CSSSwiftColorOutcome.parsed.rawValue
            )
        }

        return notAColor
    }

    // "hsl() and hsla() are synonyms."
    if hasColorFunctionPrefix(characters, 0x68, 0x73, 0x6C, 0x61, 4) {
        cursor.skip(5)
        return scanHSL(&cursor)
    }

    if hasColorFunctionPrefix(characters, 0x68, 0x73, 0x6C, nil, 3) {
        cursor.skip(4)
        return scanHSL(&cursor)
    }
    return notAColor
}

// MARK: - Entry points
//
// `Span(_unsafeCxxSpan:)` is the only way to import a `std::span` where the callee is Swift
// (rdar://186723514), and it takes both the count and the lifetime on trust. What makes the
// borrow sound:
//
// - The characters are a `StringView`'s `span8()`/`span16()`, or a `subspan` of one, and every
//   caller of `CSSParserFastPaths::parseSimpleColor`, `parseHexColor` and `parseNamedColor` keeps
//   the owning string alive across the call.
//
// - Swift re-enters C++ at two calls only: `cssSwiftFindNamedColor`, handed a Swift-owned
//   `InlineArray`, and `cssSwiftParseCSSNumber8`/`16`, handed a `const` sub-range of the
//   candidate. Neither writes the characters, allocates against the string, or calls back into
//   Swift.
//
// - `StringImpl` character storage is immutable and never relocated. An upcall that took a
//   mutable span, or that could append to the owning string, would invalidate this with no
//   diagnostic.

/// Every fast path over one candidate, selected by `kind`, so that each width has one
/// `Span(_unsafeCxxSpan:)` conversion.
///
/// The C++ passes `kind` as a constant at each call site.
@inline(always)
private func scanFastPath<Unit: CSSColorCodeUnit>(_ characters: Span<Unit>, _ kind: WebCore.CSSSwiftFastPathKind) -> WebCore.CSSSwiftColor {
    switch kind {
    case WebCore.CSSSwiftFastPathKindHexColor: scanHexColor(characters)
    case WebCore.CSSSwiftFastPathKindNamedColor: scanNamedColor(characters)
    case WebCore.CSSSwiftFastPathKindNumericColor: scanNumericColor(characters)
    default: notAColor
    }
}

/// The fast paths over Latin-1 text.
@_expose(Cxx)
public func cssParseFastPathSwift8(_ text: WebCore.CSSSwiftColorSpan8, _ kind: WebCore.CSSSwiftFastPathKind) -> WebCore.CSSSwiftColor {
    // rdar://186723514; invariants above.
    scanFastPath(unsafe Span<UInt8>(_unsafeCxxSpan: text), kind)
}

/// The fast paths over UTF-16 text.
@_expose(Cxx)
public func cssParseFastPathSwift16(_ text: WebCore.CSSSwiftColorSpan16, _ kind: WebCore.CSSSwiftFastPathKind) -> WebCore.CSSSwiftColor {
    // rdar://186723514; invariants above.
    scanFastPath(unsafe Span<UInt16>(_unsafeCxxSpan: text), kind)
}
