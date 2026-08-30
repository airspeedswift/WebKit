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

// Only the islands' own boundary types, not the WebCore_Private umbrella, for the reason
// CSSTokenizerSwiftTypes.h records: importing the umbrella walks ~3,500 headers into
// JavaScriptCore's, where two inner structs live in explicit submodules nothing imports.
public import WebCore_Private.CSSTokenizerSwiftTypes

// Swift island for the CSS colour fast paths: a port of `parseHexColorInternal` and
// `parseNamedColorInternal` from CSSParserFastPaths.cpp, selected by
// USE_SWIFT_CSS_COLOR_FAST_PATHS.
//
// WHY THIS IS THE SECOND WEBCORE ISLAND. `CSSParserFastPaths::parseSimpleColor` runs *before*
// a tokenizer exists -- `CSSPropertyParser.cpp:286` calls `maybeParseValue` and only
// constructs a `CSSTokenizer` at `:289` if it declines -- so every colour in every stylesheet,
// every `bgcolor=` attribute and every `<input type=color>` value goes through here without
// the tokenizer island being reachable at any gate setting. It is pure new coverage rather
// than a widening of island #1, and it costs nothing to introduce because the expensive part
// of pointing Swift at a target -- module boundaries, build wiring, an importable boundary
// header -- is per *target* and WebCore has already paid it.
//
// WHAT IS AND IS NOT HERE. Hex (`#rgb`, `#rgba`, `#rrggbb`, `#rrggbbaa`) and the 152 named
// colours. Deliberately not `parseHSL` or the `rgb()`/`rgba()` forms: those run
// `narrowPrecisionToFloat` and `convertPrescaledSRGBAFloatToSRGBAByte`, where a `double` is
// passed to a `float` parameter (CSSParserFastPaths.cpp:352, ColorUtilities.h:97) and the
// `Float(_:)` / `lround` / `clamp` order has to be reproduced exactly or the last bit of a
// component moves. Hex and named involve no floating point at all -- the arithmetic is nibble
// shifts and a table lookup -- so this phase is bit-identical by construction rather than by
// argument, which is exactly why it is the phase to do first.
//
// NO `unsafe`, AND THAT IS A DESIGN CONSEQUENCE. The tokenizer island next door has two
// markers, both `Span(_unsafeCxxSpan:)` at its entry points, because `@_expose(Cxx)` cannot
// express a `Span<T>` parameter (filings register §27) and `std::span` is an `@unsafe`
// imported type that cannot even be *indexed* without one. This island has none, because the
// candidate string crosses **by value** in a `CSSSwiftColorText<T>` -- a `std::array` plus a
// length -- and a value has no lifetime to get wrong. See the type's comment in
// CSSTokenizerSwiftTypes.h; it is the first interim workaround §27 has had.
//
// The named-colour table is *not* copied here. `findColor` is gperf output and stays gperf
// output; the island calls it through `cssSwiftFindNamedColor`, whose `__counted_by` plus
// `noescape` parameter is what lets a folded buffer go the other way with no marker either.

/// What a colour scan concluded. Three outcomes, not two: `notAColor` is a *finding* that the
/// C++ must not second-guess, where `declined` means the island did not try and C++ must run
/// its own path. Conflating them is how a port silently loses coverage -- the C++ answer for a
/// declined input is identical to the C++ answer for a rejected one, so a decline reads as
/// parity.
///
/// `@c` (SE-0495) makes this the single declaration of the numbering: it is emitted into
/// WebCoreSwift-Generated.h as a `uint8_t`-backed C enum, so CSSParserFastPaths.cpp names
/// `CSSSwiftColorOutcomeParsed` directly and cannot drift. Internal rather than `public`
/// because `@c` on a *resilient* enum crashes IRGen and WebCore compiles with library
/// evolution; the generated header is emitted at `-emit-clang-header-min-access internal`, so
/// nothing is lost.
@c
enum CSSSwiftColorOutcome: UInt8 {
    case notAColor = 0
    case parsed
    case declined
}

/// One scanner implementation over both of `StringImpl`'s widths, and the reason it is shaped
/// like this rather than as a generic over a protocol.
///
/// The obvious spelling -- a `CSSSwiftColorTextRepresentation` protocol, both crossing structs
/// conforming, one generic scanner -- was written first and measured 0.63-0.68 of the C++ on a
/// micro-benchmark whose null control was tight to 2%. The disassembly said why, and it was not
/// the algorithm: the specialization stayed a separate function behind the exposed entry's thunk,
/// so every scan paid a call frame plus another to `finishParsingHexColorARGB`, and the entry
/// copied the whole crossing struct onto its own frame with `ldp q0, q1` / `stp q0, q1` -- a
/// *second* copy on top of the one C++ had already made.
///
/// `@inline(always)` on the generic did not fix it (measured: 157 instructions against the
/// concrete shape's 50). What did was giving each width its own concrete entry. Passing the unit
/// accessor as a closure to an `@inline(always)` function keeps the loop single-sourced and emits
/// *byte-identical* code to writing the loop out twice -- same instruction count, same vector
/// pair count, same call count, at both widths -- so the duplication the fast shape seemed to
/// require turned out not to be required at all. Probe: cssprobe/probes/colorboundary.

/// The crossing capacity. Above 20 because the longest CSS named colour,
/// `lightgoldenrodyellow`, is 20 -- which is gperf's own `MAX_WORD_LENGTH` over ColorData.gperf,
/// not a guess -- and no higher than 24 because a `CSSSwiftColorText<Latin1Character>` of 28
/// bytes is passed to Swift in registers where one of 36 is passed by address and copied. That
/// threshold is the whole reason this number is 24 and not 32; see the note above.
///
/// A literal rather than `Int(WebCore.cssSwiftColorTextCapacity)`, because a `let` global
/// initialised from an imported C++ constant is lazily initialised behind a `swift_once` and this
/// is read on a hot path. CSSParserFastPaths.cpp static_asserts the C++ constant against 24, so
/// the two cannot drift.
private let colorTextCapacity = 24

// MARK: - Character predicates
//
// Direct ports of the ASCIICType.h helpers these two paths use. Each names the C++ it
// mirrors, because the exact spelling is load-bearing for wide input.

/// `isASCII` (ASCIICType.h:88): `!(character & ~0x7F)`.
@inline(always)
private func isASCIIUnit(_ unit: UInt32) -> Bool { unit & ~0x7F == 0 }

/// `isASCIIHexDigit` (ASCIICType.h:123) and `toASCIIHexValue` (ASCIICType.h:209) fused, because
/// the C++ computes `character - '0'` twice -- once inside the predicate's range test and once
/// for the value -- and Swift cannot see that the second is safe from the first.
///
/// Splitting them cost a runtime trap: the predicate's subtraction lowered to an unchecked `sub`
/// for its comparison, and the value's to a `subs` with `b.lo` into a `brk`, guarding an
/// underflow the caller had already excluded. Fusing them removes the trap without an `unsafe`
/// or an `-Ounchecked`, and the wrapping operators are not a weakening: `unit &- 0x30 < 10` is
/// *exactly* `unit >= 0x30 && unit <= 0x39` over `UInt32`, which is the predicate the C++ spells
/// with two comparisons. The `| 0x20` is `toASCIILowerUnchecked`, applied to the whole code unit
/// so that a wide character sharing a low byte with `'a'` is still rejected.
///
/// The `& 0xF` the C++ applies to `(character - 'A' + 10)` is what folds the lowercase range onto
/// the uppercase one; folding first with `| 0x20` and adding 10 to a value already below 6 is the
/// same function, checked against the C++ over every 3-, 4- and 6-digit string.
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
/// The C++ builds an `SRGBA<uint8_t>` four different ways -- component-wise for the 3- and
/// 4-digit forms, `asSRGBA(PackedColor::ARGB { 0xFF000000 | value })` for 6 digits and
/// `asSRGBA(PackedColor::RGBA { value })` for 8. Returning 0xAARRGGBB for all four means the
/// C++ side has one conversion rather than a switch, which matters because a shim that only
/// re-derives a dispatch is the exact cost this port measured on `takeChunk`: a construction
/// site that knows its form statically should never encode the form for the other side to
/// decode.
///
/// `nil` for any other length, which `parseHexColorSwift` has already excluded; it is kept
/// because it is the C++'s own `return std::nullopt` and removing it would make the two
/// functions differ in a way no test could see.
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
/// consumed one, or is the quirks-mode path where there was none.
///
/// Takes the unit accessor as a closure, so that the two widths share this loop while each entry
/// point still compiles to a single concrete function with the accesses folded in. `count` is the
/// candidate's *true* length, which may exceed the crossing capacity; that never matters here,
/// because the only accepted lengths are 3, 4, 6 and 8 and the test comes first -- so a
/// five-thousand-character property value costs one comparison rather than a scan, exactly as in
/// the C++.
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
/// Three differences from the C++, all of them removals.
///
/// The `std::array<char, 64>` becomes an `InlineArray`, so the write is bounds-checked against a
/// length the compiler knows rather than against a hand-written `characters.size() > buffer.size()
/// - 1` guard.
///
/// The NUL is gone. The C++ hands `finishParsingNamedColor` a span *one past* the folded text so
/// that `buffer.back() = '\0'` has somewhere to go, and that function then passes
/// `buffer.size() - 1` to undo it -- but gperf's `findColorImpl` reads only `str[0 .. len-1]`; the
/// `s[len] == '\0'` it tests belongs to the table entry. So the terminator, the `+ 1`, the
/// `back()` on a span whose non-emptiness only the caller's arithmetic established, and the
/// unchecked `size() - 1` that would underflow if it were ever empty are all dead weight, and
/// none of them crosses this boundary.
///
/// And the capacity check is a *finding* rather than a buffer-management detail: a string longer
/// than the crossing capacity is not a named colour, because gperf's own `MAX_WORD_LENGTH` over
/// ColorData.gperf is 20.
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
// Four, being two scanners at two widths. Each takes its candidate by value, which is why none of
// them needs `unsafe`; and each is its own concrete function rather than a call into a shared
// generic, which is why none of them pays a call frame or a second copy of the candidate. The
// loops themselves are still written once -- see the note on `scanHexColor`.

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
