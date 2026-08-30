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

// Only the Swift-callable boundary types, not the WebCore_Private umbrella: importing the
// umbrella walks ~3,500 headers into JavaScriptCore's, where two inner structs live in
// explicit submodules nothing imports.
public import WebCore_Private.CSSTokenizerSwiftTypes

// Swift port of the CSS colour fast paths: `parseHexColorInternal` and
// `parseNamedColorInternal` from CSSParserFastPaths.cpp, selected by
// USE_SWIFT_CSS_COLOR_FAST_PATHS.
//
// `CSSParserFastPaths::parseSimpleColor` runs before a `CSSTokenizer` exists --
// `CSSPropertyParser.cpp:286` calls `maybeParseValue` and only constructs one at `:289` if that
// declines -- so every colour in every stylesheet, `bgcolor=` attribute and `<input
// type=color>` value reaches this code.
//
// Covers hex (`#rgb`, `#rgba`, `#rrggbb`, `#rrggbbaa`) and the 152 named colours. Not `parseHSL`
// or the `rgb()`/`rgba()` forms: those run `narrowPrecisionToFloat` and
// `convertPrescaledSRGBAFloatToSRGBAByte`, where a `double` is passed to a `float` parameter
// (CSSParserFastPaths.cpp:352, ColorUtilities.h:97) and the `Float(_:)` / `lround` / `clamp`
// order has to match exactly or the last bit of a component moves. Hex and named involve no
// floating point, so they can match the C++ bit-for-bit.
//
// No `unsafe` marker: `@_expose(Cxx)` cannot express a `Span<T>` parameter for an entry point,
// and `std::span` is itself an `@unsafe` imported type that cannot be indexed without one. The
// candidate crosses by value instead, in a `CSSSwiftColorText<T>` holding a `std::array` and a
// length: `std::array` holds no pointer, so it imports as an ordinary bounds-checked type with
// no lifetime to get wrong. See the type's comment in CSSTokenizerSwiftTypes.h.
//
// The named-colour table is not copied here: `findColor` stays gperf output, and this file
// calls it through `cssSwiftFindNamedColor`, whose `__counted_by` plus `noescape` parameter
// carries a folded buffer across with no marker either.

/// What a colour scan concluded. Three outcomes, not two: `notAColor` is a definitive answer
/// that C++ must not re-parse, while `declined` means C++ must run its own scan. The C++ answer
/// for a declined input is identical to its answer for a rejected one, so conflating the two
/// would silently drop coverage without changing any output.
///
/// `@c` (SE-0495) makes this the single declaration of the numbering: it is emitted into
/// WebCoreSwift-Generated.h as a `uint8_t`-backed C enum, so CSSParserFastPaths.cpp names
/// `CSSSwiftColorOutcomeParsed` directly and cannot drift. Internal rather than `public` because
/// `@c` on a resilient enum crashes IRGen and WebCore compiles with library evolution; the
/// generated header is emitted at `-emit-clang-header-min-access internal`, so nothing is lost.
@c
enum CSSSwiftColorOutcome: UInt8 {
    case notAColor = 0
    case parsed
    case declined
}

/// Each width gets its own concrete scanner function rather than a shared generic: a generic
/// entry point does not specialize across the exposed Cxx boundary, which costs an extra call
/// frame and an extra copy of the crossing struct per scan. The loop itself is still written
/// once, passed in as a closure to an `@inline(always)` function, which compiles to the same
/// code as writing it out per width.

/// The crossing capacity is bounded below by 20, the longest CSS named colour
/// (`lightgoldenrodyellow`, gperf's `MAX_WORD_LENGTH` over ColorData.gperf), and above by the
/// point where the register-passed `CSSSwiftColorText<Latin1Character>` would start crossing by
/// address instead of by value; 24 fits both.
///
/// A literal rather than `Int(WebCore.cssSwiftColorTextCapacity)`: an imported C++ constant is a
/// `let` global that is lazily initialised behind a `swift_once`, and this value is read on a
/// hot path. CSSParserFastPaths.cpp static_asserts the C++ constant against 24, so the two
/// cannot drift.
private let colorTextCapacity = 24

// MARK: - Character predicates
//
// Direct ports of the ASCIICType.h helpers these two paths use. Each names the C++ it
// mirrors, because the exact spelling is load-bearing for wide input.

/// `isASCII` (ASCIICType.h:88): `!(character & ~0x7F)`.
@inline(always)
private func isASCIIUnit(_ unit: UInt32) -> Bool { unit & ~0x7F == 0 }

/// Fuses `isASCIIHexDigit` (ASCIICType.h:123) and `toASCIIHexValue` (ASCIICType.h:209): the C++
/// computes `character - '0'` once for the range test and once for the value, and Swift cannot
/// see that the second is safe given the first.
///
/// Splitting them traps at runtime on the value's subtraction, guarding an underflow the caller
/// has already excluded. Fusing removes the trap with no `unsafe` and no `-Ounchecked`, and the
/// wrapping arithmetic is not a weakening: `unit &- 0x30 < 10` is exactly `unit >= 0x30 && unit
/// <= 0x39` over `UInt32`. `| 0x20` folds a code unit toward lowercase without misreading a wide
/// character that merely shares a low byte with `'a'`, and `&- 0x61` with the `< 6` check and
/// `&+ 10` folds the lowercase and uppercase ranges the same way the C++'s `& 0xF` does, checked
/// against it over every 3-, 4- and 6-digit string.
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

/// `toASCIILower` for a character already known to be ASCII. The C++ reaches the `char`
/// overload (ASCIICType.h:194), which indexes `asciiCaseFoldTable`; over 0x00-0x7F that table
/// is the identity except that 0x41-0x5A map to 0x61-0x7A, so this is the same function
/// without the load.
@inline(always)
private func toASCIILowerUnit(_ unit: UInt32) -> UInt8 {
    let byte = UInt8(truncatingIfNeeded: unit)
    return (byte >= 0x41 && byte <= 0x5A) ? byte + 0x20 : byte
}

// MARK: - Hex colours

/// `finishParsingHexColor` (CSSParserFastPaths.cpp:462), expressed as a packed
/// `PackedColor::ARGB` value.
///
/// The C++ builds an `SRGBA<uint8_t>` a different way for each length. Returning 0xAARRGGBB
/// uniformly for all four lets the C++ side use one conversion rather than switch on the length
/// again.
///
/// `nil` for any other length, which `parseHexColorSwift` has already excluded; kept because it
/// mirrors the C++'s own `return std::nullopt`.
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

/// `parseHexColorInternal` (CSSParserFastPaths.cpp:489). No leading `#`: the caller has already
/// consumed one, or is on the quirks-mode path where there was none.
///
/// Takes the unit accessor as a closure, so the two widths share this loop while each entry
/// point still compiles to a single concrete function. `count` is the candidate's true length
/// even past the crossing capacity, but only 3, 4, 6 and 8 are accepted and that check comes
/// first, so a long property value costs one comparison rather than a scan.
@inline(always)
private func scanHexColor(_ count: Int, _ unit: (Int) -> UInt32) -> WebCore.CSSSwiftColor {
    guard count == 3 || count == 4 || count == 6 || count == 8 else {
        return notAColor
    }

    var value: UInt32 = 0
    for index in 0..<count {
        guard let digit = hexDigitValue(unit(index)) else {
            return notAColor
        }
        value = value << 4 | digit
    }

    guard let argb = finishParsingHexColorARGB(value, count) else {
        return notAColor
    }
    return WebCore.CSSSwiftColor(argb: argb, outcome: CSSSwiftColorOutcome.parsed.rawValue)
}

// MARK: - Named colours

/// `parseNamedColorInternal` (CSSParserFastPaths.cpp:693).
///
/// The `std::array<char, 64>` becomes an `InlineArray`, so the write is bounds-checked against a
/// length the compiler knows, not a hand-written `characters.size() > buffer.size() - 1` guard.
///
/// No NUL terminator: the C++ passes `finishParsingNamedColor` a span one past the folded text
/// so `buffer.back() = '\0'` has somewhere to go, then undoes it with `buffer.size() - 1` -- but
/// gperf's `findColorImpl` only reads `str[0 .. len-1]`, so the terminator, the `+ 1`, and the
/// unchecked `size() - 1` (which would underflow on an empty span) never cross this boundary.
///
/// A candidate longer than the crossing capacity is not a named colour: gperf's own
/// `MAX_WORD_LENGTH` over ColorData.gperf is 20.
@inline(always)
private func scanNamedColor(_ count: Int, _ unit: (Int) -> UInt32) -> WebCore.CSSSwiftColor {
    guard count <= colorTextCapacity else {
        return notAColor
    }

    var folded = InlineArray<24, UInt8>(repeating: 0)
    for index in 0..<count {
        let value = unit(index)
        // `!character || !isASCII(character)`: a NUL would make the table lookup read a shorter
        // string than it was given a length for, and non-ASCII cannot name a colour.
        guard value != 0, isASCIIUnit(value) else {
            return notAColor
        }
        folded[index] = toASCIILowerUnit(value)
    }

    return WebCore.cssSwiftFindNamedColor(folded.span.extracting(0..<count))
}

/// The one place a rejection is spelled, so the two scanners cannot disagree about what one looks
/// like. A `let` rather than a function: it is a compile-time constant, so it needs no
/// `swift_once` and no call.
private let notAColor = WebCore.CSSSwiftColor(argb: 0, outcome: CSSSwiftColorOutcome.notAColor.rawValue)

// MARK: - Entry points
//
// Four: two scanners at two widths. Each takes its candidate by value (no `unsafe` needed) and
// is its own concrete function rather than a call into a shared generic. The loop itself is
// still written once; see `scanHexColor`.

/// `parseHexColorInternal` over Latin-1 text: the common case, since a property value that
/// survives preprocessing as Latin-1 is what a stylesheet usually holds.
@_expose(Cxx)
public func cssParseHexColorSwift8(_ text: WebCore.CSSSwiftColorText8) -> WebCore.CSSSwiftColor {
    scanHexColor(Int(text.length)) { UInt32(text.units[$0]) }
}

/// `parseHexColorInternal` over UTF-16 text.
@_expose(Cxx)
public func cssParseHexColorSwift16(_ text: WebCore.CSSSwiftColorText16) -> WebCore.CSSSwiftColor {
    scanHexColor(Int(text.length)) { UInt32(text.units[$0]) }
}

/// `parseNamedColorInternal` over Latin-1 text.
@_expose(Cxx)
public func cssParseNamedColorSwift8(_ text: WebCore.CSSSwiftColorText8) -> WebCore.CSSSwiftColor {
    scanNamedColor(Int(text.length)) { UInt32(text.units[$0]) }
}

/// `parseNamedColorInternal` over UTF-16 text.
@_expose(Cxx)
public func cssParseNamedColorSwift16(_ text: WebCore.CSSSwiftColorText16) -> WebCore.CSSSwiftColor {
    scanNamedColor(Int(text.length)) { UInt32(text.units[$0]) }
}
