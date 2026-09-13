//
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
///

// Only the Swift-callable boundary types, not the WebCore_Private umbrella: importing the
// umbrella walks ~3,500 headers into JavaScriptCore's, where two inner structs live in explicit
// submodules nothing imports.
public import WebCore_Private.CodecParsersSwiftTypes

// Swift port of the media codec-configuration string parsers, selected by
// USE_SWIFT_CODEC_PARSERS. Slice 1 of the codec island: `parseDoViCodecParameters` and the five
// static helpers it calls, from HEVCUtilities.cpp:292-406.
//
// WHY THIS SLICE FIRST. It is the only entry point in the cluster that is flat POD out *and* has
// a free JS-reachable oracle (`Internals::parseDoViCodecParameters`, exercised by
// LayoutTests/media/dovi-codec-parameters.html) *and* lives in the file carrying the
// GPU-process caller. `parseVPCodecParameters`, which the original brief ranked first, returns a
// record holding a `String`; settling that is a separate question from settling the boundary,
// and doing both in one commit would confound them.
//
// WHY IT IS WORTH PORTING AT ALL, stated precisely so it is not overclaimed. This is NOT a
// spatial-safety win: `-Wunsafe-buffer-usage` is on for WebCore, the C++ here is `StringView`-
// and `std::span`-based throughout, and every index it performs is bounds-checked by libc++
// under `_LIBCPP_HARDENING_MODE_EXTENSIVE`. The hazard is semantic -- a codec string arriving
// over IPC from WebContent (`GPUProcess/webrtc/LibWebRTCCodecsProxy.mm:183, :327` for the
// sibling HEVC parser) is decoded into fields that configure VideoToolbox and, below it, the
// driver. Swift makes the validation total: the profile and level are constrained by the
// grammar's own tables rather than by a chain of early returns whose completeness is only
// established by reading all five helpers together.
//
// NO NEW C++ ON THE RETURN SIDE. Swift constructs `DoViParameters` itself -- default member
// initializers and the nested `enum class Codec` included -- and returns it inside the real
// `std::optional`, so the exposed signature is `parseDoViCodecParameters`' own. There is no
// parallel POD, no outcome enum and no conversion function. The only new C++ this island costs
// is the input crossing value, `CodecStringText`; see its comment for why a view cannot cross.

// MARK: - The character predicates, mirrored rather than imported
//
// These are `WTF::isASCIIDigit` and `WTF::isUnicodeCompatibleASCIIWhitespace` (ASCIICType.h:154
// and :174). They are mirrored, not called, because they are three comparisons each and the
// alternative is importing WTF's umbrella for them. If either changes in C++ this file must
// change with it, which is what the differential over the layout test is for.

private let dot: Latin1Character = 0x2e
private let plus: Latin1Character = 0x2b
private let zero: Latin1Character = 0x30
private let nine: Latin1Character = 0x39

private func isDigit(_ unit: Latin1Character) -> Bool { unit >= zero && unit <= nine }

/// `isASCIIWhitespace` plus `'\v'`, which is what `parseInteger` skips.
private func isWhitespace(_ unit: Latin1Character) -> Bool {
    unit == 0x20 || unit == 0x0a || unit == 0x09 || unit == 0x0d || unit == 0x0c || unit == 0x0b
}

// MARK: - Splitting
//
// `StringView::split(char16_t)` DROPS empty entries -- the empty-allowing variant is the
// separately named `splitAllowingEmptyEntries` -- so `dvh1..04.09` yields three elements and
// parses successfully today. Reproducing that is not a courtesy to malformed input; it is the
// difference between a port and a behaviour change, and the differential would report it as a
// mismatch rather than as an improvement.

private struct DotSplit {
    let text: WebCore.CodecStringText
    let length: Int
    var index = 0

    init(_ text: WebCore.CodecStringText) {
        self.text = text
        // `length` is the candidate's TRUE length and C++ declines above the capacity, so this
        // clamp is a belt-and-braces bound rather than the live one. It is spelled anyway
        // because the constant is what makes every `units[i]` below provably in range.
        self.length = min(Int(text.length), Int(WebCore.codecStringTextCapacity))
    }

    mutating func next() -> Range<Int>? {
        while index < length, text.units[index] == dot { index += 1 }
        guard index < length else { return nil }
        let start = index
        while index < length, text.units[index] != dot { index += 1 }
        return start..<index
    }
}

// MARK: - `parseInteger<uint8_t>`
//
// Mirrors `WTF::parseInteger<uint8_t>(StringView)` (StringToIntegerConversion.h:49) at its
// default policies -- `TrailingJunkPolicy::Disallow`, `ParseIntegerWhitespacePolicy::Allow`.
// Four behaviours that are easy to miss and that the corpus must exercise, because each one
// admits inputs a naive two-digit parser would reject:
//
//  * LEADING AND TRAILING WHITESPACE IS ALLOWED. `dvh1.04. 09 ` parses.
//  * A SINGLE LEADING '+' IS ALLOWED. The '-' branch is `std::is_signed_v`-gated and dead here.
//  * LEADING ZEROS ARE UNLIMITED, and are the reason this island's capacity is a decline
//    threshold rather than a grammar bound: there is no length above which a codec string is
//    certainly invalid.
//  * OVERFLOW IS AN ANSWER, NOT A CLAMP. `Checked<uint8_t, RecordOverflow>` returns nullopt
//    above 255, so `dvh1.04.300` is not-a-codec rather than level 44.

private func parseUInt8(_ text: WebCore.CodecStringText, _ range: Range<Int>) -> UInt8? {
    var index = range.lowerBound
    let end = range.upperBound

    while index < end, isWhitespace(text.units[index]) { index += 1 }
    if index < end, text.units[index] == plus { index += 1 }
    guard index < end, isDigit(text.units[index]) else { return nil }

    var value: UInt32 = 0
    var overflowed = false
    repeat {
        if !overflowed {
            value = value * 10 + UInt32(text.units[index] - zero)
            overflowed = value > 255
        }
        index += 1
    } while index < end && isDigit(text.units[index])

    if overflowed { return nil }

    while index < end, isWhitespace(text.units[index]) { index += 1 }
    guard index == end else { return nil }

    return UInt8(value)
}

// MARK: - The four tables, from "Dolby Vision Profiles and Levels Version 1.3.2"

/// `parseDoViCodecType`, HEVCUtilities.cpp:292. Exactly four characters; the C++ is a
/// `SortedArrayMap` over `PackedLettersLiteral<uint32_t>`, which cannot match any other length.
private func doViCodec(_ text: WebCore.CodecStringText, _ range: Range<Int>) -> WebCore.DoViParameters.Codec? {
    guard range.count == 4 else { return nil }
    let base = range.lowerBound
    let tag = (text.units[base], text.units[base + 1], text.units[base + 2], text.units[base + 3])
    switch tag {
    case (0x64, 0x76, 0x61, 0x31): return .AVC1  // dva1
    case (0x64, 0x76, 0x61, 0x76): return .AVC3  // dvav
    case (0x64, 0x76, 0x68, 0x31): return .HVC1  // dvh1
    case (0x64, 0x76, 0x68, 0x65): return .HEV1  // dvhe
    default: return nil
    }
}

/// `profileIDForAlphabeticDoViProfile`, HEVCUtilities.cpp:303 -- Table 7.
///
/// Note what the C++ matches against: `codecView.left(5 + profileID.length())`, a prefix of the
/// WHOLE candidate, not the profile element. The two disagree whenever the separator run is not
/// a single dot: for `dvhe..dtr.04` the element is `dtr` but the prefix is `dvhe..d`, which
/// matches nothing, so the alphabetic form rejects input the numeric form would accept. That is
/// reproduced deliberately.
private func alphabeticProfileID(_ text: WebCore.CodecStringText, prefixLength: Int) -> UInt16? {
    let length = min(Int(text.length), Int(WebCore.codecStringTextCapacity))
    // `left(n)` clamps to the string rather than failing, so a short candidate yields a short
    // prefix that matches nothing -- reproduced by clamping instead of rejecting.
    let count = min(prefixLength, length)
    guard count <= 8 else { return nil }

    // Packed big-endian into a UInt64, which is what `PackedLettersLiteral<uint64_t>` does on
    // the C++ side. The pack encodes the length as well as the characters -- a seven-byte value
    // cannot equal an eight-byte one, since no literal starts with a NUL -- so no separate
    // length comparison is needed, and no array is materialized to hold a literal.
    var packed: UInt64 = 0
    for offset in 0..<count { packed = packed << 8 | UInt64(text.units[offset]) }

    switch packed {
    case 0x64_76_61_76_2e_73_65: return 9     // dvav.se
    case 0x64_76_68_65_2e_64_74_62: return 7  // dvhe.dtb
    case 0x64_76_68_65_2e_64_74_72: return 4  // dvhe.dtr
    case 0x64_76_68_65_2e_73_74: return 8     // dvhe.st
    case 0x64_76_68_65_2e_73_74_6e: return 5  // dvhe.stn
    default: return nil
    }
}

/// `maximumLevelIDForDoViProfileID`, HEVCUtilities.cpp:330 -- Section 4.1. Returning `nil` for
/// an unlisted profile also serves as `isValidDoViProfileID` (:316), whose accepted set is
/// exactly this function's domain; the C++ spells both because it calls them at different
/// points, and collapsing them here removes a way for the two lists to drift apart.
private func maximumLevelID(forProfileID profileID: UInt16) -> UInt16? {
    switch profileID {
    case 4: return 9
    case 5: return 13
    case 7: return 9
    case 8: return 13
    case 9: return 5
    default: return nil
    }
}

/// `isValidProfileIDForCodec`, HEVCUtilities.cpp:343.
private func isValid(profileID: UInt16, for codec: WebCore.DoViParameters.Codec) -> Bool {
    if profileID == 9 {
        return codec == .AVC1 || codec == .AVC3
    }
    return codec == .HVC1 || codec == .HEV1
}

// MARK: - Entry point

/// `parseDoViCodecParameters`, HEVCUtilities.cpp:350.
///
/// The C++ never checks for a fourth element, so trailing junk after the level is ignored and
/// `dvh1.04.09.whatever` parses. Reproduced.
@_expose(Cxx)
public func codecParseDoViSwift(_ text: WebCore.CodecStringText) -> WebCore.OptionalDoViParameters {
    var split = DotSplit(text)

    guard let codecRange = split.next(), let codec = doViCodec(text, codecRange) else {
        return WebCore.OptionalDoViParameters()
    }
    guard let profileRange = split.next(), !profileRange.isEmpty else {
        return WebCore.OptionalDoViParameters()
    }

    let profileID: UInt16
    if text.units[profileRange.lowerBound] == zero {
        guard let numeric = parseUInt8(text, profileRange) else {
            return WebCore.OptionalDoViParameters()
        }
        profileID = UInt16(numeric)
    } else {
        guard let alphabetic = alphabeticProfileID(text, prefixLength: 5 + profileRange.count) else {
            return WebCore.OptionalDoViParameters()
        }
        profileID = alphabetic
    }

    guard let maximumLevel = maximumLevelID(forProfileID: profileID) else {
        return WebCore.OptionalDoViParameters()
    }
    guard isValid(profileID: profileID, for: codec) else {
        return WebCore.OptionalDoViParameters()
    }
    guard let levelRange = split.next(), let level = parseUInt8(text, levelRange) else {
        return WebCore.OptionalDoViParameters()
    }
    guard UInt16(level) <= maximumLevel else {
        return WebCore.OptionalDoViParameters()
    }

    var parameters = WebCore.DoViParameters()
    parameters.codec = codec
    parameters.bitstreamProfileID = profileID
    parameters.bitstreamLevelID = UInt16(level)
    return WebCore.OptionalDoViParameters(parameters)
}
