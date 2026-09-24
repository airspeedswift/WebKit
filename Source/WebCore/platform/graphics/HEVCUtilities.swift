/*
 * Copyright (C) 2018-2022 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

// The AVC, HEVC and Dolby Vision codecs parameter string and decoder configuration record parsers.
// Each @_cdecl entry point gets the address of a caller default-constructed parameters struct and,
// on success, assigns the fields the parse determines and returns true. On failure the struct
// contents do not matter. HEVCParameters::generalConstraintIndicatorFlags is written only through
// the separate address of its six bytes, never through the struct.
//
// The element walker, the decimal scanner and withBytes are shared with AV1Utilities.swift.

#if ENABLE_HEVC_UTILITIES_SWIFT

internal import WebCore_Private

private typealias AVCParameters = WebCore_Private.WebCore.AVCParameters
private typealias HEVCParameters = WebCore_Private.WebCore.HEVCParameters
private typealias DoViParameters = WebCore_Private.WebCore.DoViParameters

// MARK: - Scanning

/// parseInteger<T>(_, 16): optional leading and trailing whitespace (space, \t, \n, \v, \f, \r),
/// an optional '+', then one or more hex digits of either case. Overflow of T fails.
private func parseHex<Value: FixedWidthInteger & UnsignedInteger, Unit: CodeUnit>(_ characters: Span<Unit>, _ range: Range<Int>, as _: Value.Type) -> Value? {
    func isWhitespace(_ character: Unit) -> Bool {
        character == 0x20 || (0x09...0x0D).contains(character)
    }
    func hexValue(_ character: Unit) -> Value? {
        if (0x30...0x39).contains(character) {
            return Value(character - 0x30)
        }
        let folded = character | 0x20
        return (0x61...0x66).contains(folded) ? Value(folded - 0x61 + 10) : nil
    }

    var index = range.lowerBound
    while index < range.upperBound && isWhitespace(characters[index]) {
        index += 1
    }
    if index < range.upperBound && characters[index] == 0x2B {
        index += 1
    }
    let digitsStart = index
    var value: Value = 0
    var overflowed = false
    while index < range.upperBound, let digit = hexValue(characters[index]) {
        let (shifted, shiftOverflow) = value.multipliedReportingOverflow(by: 16)
        let (sum, addOverflow) = shifted.addingReportingOverflow(digit)
        overflowed = overflowed || shiftOverflow || addOverflow
        value = sum
        index += 1
    }
    if index == digitsStart {
        return nil
    }
    while index < range.upperBound {
        if !isWhitespace(characters[index]) {
            return nil
        }
        index += 1
    }
    return overflowed ? nil : value
}

/// Case-sensitive comparison of an element with a four-character code such as 0x61766331 ("avc1").
private func equals<Unit: CodeUnit>(_ characters: Span<Unit>, _ range: Range<Int>, _ fourCC: UInt32) -> Bool {
    if range.count != 4 {
        return false
    }
    for offset in 0..<4 where UInt32(characters[range.lowerBound + offset]) != (fourCC >> (24 - 8 * offset)) & 0xFF {
        return false
    }
    return true
}

/// The key of a PackedLettersLiteral<uint32_t or uint64_t> lookup: at most `width` ASCII
/// characters, each folded by OR-ing 0x20 (so '\u{11}' matches '1'), packed from the top byte down.
private func packedLetters<Unit: CodeUnit>(_ characters: Span<Unit>, _ range: Range<Int>, width: Int) -> UInt64? {
    if range.count > width {
        return nil
    }
    var key: UInt64 = 0
    for offset in 0..<range.count {
        let character = characters[range.lowerBound + offset]
        if character > 0x7F {
            return nil
        }
        key |= UInt64(character | 0x20) << (8 * (width - 1 - offset))
    }
    return key
}

private func reverseBits32(_ value: UInt32) -> UInt32 {
    var result: UInt32 = 0
    for bit in 0..<32 where value & (1 << bit) != 0 {
        result |= 1 << (31 - bit)
    }
    return result
}

private func bigEndianUInt16(_ data: Span<UInt8>, at offset: Int) -> UInt16 {
    UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
}

private func bigEndianUInt32(_ data: Span<UInt8>, at offset: Int) -> UInt32 {
    UInt32(bigEndianUInt16(data, at: offset)) << 16 | UInt32(bigEndianUInt16(data, at: offset + 2))
}

// MARK: - Parsed fields

private struct ParsedAVC {
    var profileIDC: UInt8
    var constraintsFlags: UInt8
    var levelIDC: UInt8
}

/// A nil profile space is one the parse leaves at its default.
private struct ParsedHEVC {
    var codec: HEVCParameters.Codec
    var generalProfileSpace: UInt16?
    var generalProfileIDC: UInt16
    var generalProfileCompatibilityFlags: UInt32
    var generalTierFlag: UInt8
    var generalLevelIDC: UInt16
    /// Constraint flag byte i is bits 8i...8i+7; only the first `constraintFlagCount` are assigned.
    var constraintFlags: UInt64
    var constraintFlagCount: Int
}

private struct ParsedDoVi {
    var codec: DoViParameters.Codec?
    var bitstreamProfileID: UInt16
    var bitstreamLevelID: UInt16
}

extension ParsedAVC {
    func apply(to parameters: inout AVCParameters) {
        parameters.profileIDC = profileIDC
        parameters.constraintsFlags = constraintsFlags
        parameters.levelIDC = levelIDC
    }
}

extension ParsedHEVC {
    func apply(to parameters: inout HEVCParameters) {
        parameters.codec = codec
        if let generalProfileSpace { parameters.generalProfileSpace = generalProfileSpace }
        parameters.generalProfileIDC = generalProfileIDC
        parameters.generalProfileCompatibilityFlags = generalProfileCompatibilityFlags
        parameters.generalTierFlag = generalTierFlag
        parameters.generalLevelIDC = generalLevelIDC
    }
}

extension ParsedDoVi {
    func apply(to parameters: inout DoViParameters) {
        if let codec { parameters.codec = codec }
        parameters.bitstreamProfileID = bitstreamProfileID
        parameters.bitstreamLevelID = bitstreamLevelID
    }
}

// SAFETY (all three stores): the caller passes the address of a live parameters struct of the
// named type that it constructed, and does not touch it until the call returns.
private func store(_ parsed: ParsedAVC, into rawParameters: UnsafeMutableRawPointer) {
    unsafe parsed.apply(to: &rawParameters.assumingMemoryBound(to: AVCParameters.self).pointee)
}

private func store(_ parsed: ParsedHEVC, into rawParameters: UnsafeMutableRawPointer, constraintFlags: UnsafeMutablePointer<UInt8>) {
    unsafe parsed.apply(to: &rawParameters.assumingMemoryBound(to: HEVCParameters.self).pointee)
    for i in 0..<parsed.constraintFlagCount {
        // SAFETY: `constraintFlags` addresses the six bytes of the struct's constraint flag
        // Vector, which no store through the struct touches, and the count is at most six.
        unsafe constraintFlags[i] = UInt8(truncatingIfNeeded: parsed.constraintFlags >> (8 * i))
    }
}

private func store(_ parsed: ParsedDoVi, into rawParameters: UnsafeMutableRawPointer) {
    unsafe parsed.apply(to: &rawParameters.assumingMemoryBound(to: DoViParameters.self).pointee)
}

// MARK: - Codecs parameter strings

/// ISO/IEC 14496-15:2014, Annex E.2: avc1.<profile_idc><constraint flags><level_idc>, as one hex
/// number. Elements after the first are ignored, and 'avc3' is rejected.
private func parseAVCCodecParameters<Unit: CodeUnit>(_ characters: Span<Unit>) -> ParsedAVC? {
    var index = 0
    guard let codecName = nextElement(characters, &index), equals(characters, codecName, 0x61766331), // avc1
        let element = nextElement(characters, &index),
        let profileFlagsAndLevel = parseHex(characters, element, as: UInt32.self)
    else { return nil }
    return ParsedAVC(profileIDC: UInt8(truncatingIfNeeded: profileFlagsAndLevel >> 16),
        constraintsFlags: UInt8(truncatingIfNeeded: profileFlagsAndLevel >> 8),
        levelIDC: UInt8(truncatingIfNeeded: profileFlagsAndLevel))
}

/// ISO/IEC 14496-15:2014, Annex E.3:
/// <hvc1|hev1>.[A-C]<profile_idc>.<compatibility flags>.<L|H><level_idc>[.<constraint byte>]{0,6}
/// Constraint bytes past the sixth are ignored.
private func parseHEVCCodecParameters<Unit: CodeUnit>(_ characters: Span<Unit>) -> ParsedHEVC? {
    var index = 0
    guard let codecName = nextElement(characters, &index) else { return nil }
    let codec: HEVCParameters.Codec
    if equals(characters, codecName, 0x68766331) { // hvc1
        codec = .Hvc1
    } else if equals(characters, codecName, 0x68657631) { // hev1
        codec = .Hev1
    } else {
        return nil
    }

    // The optional profile space letter A, B or C maps to 1, 2 or 3; the profile IDC is decimal.
    guard var profile = nextElement(characters, &index) else { return nil }
    var generalProfileSpace: UInt16?
    let profileSpaceCharacter = characters[profile.lowerBound]
    if (0x41...0x43).contains(profileSpaceCharacter) {
        generalProfileSpace = UInt16(profileSpaceCharacter - 0x40)
        profile = profile.dropFirst()
    }
    guard let generalProfileIDC = parseUInt8(characters, profile) else { return nil }

    // The compatibility flags are hex with bit 31 of the field as the least significant bit.
    guard let compatibilityElement = nextElement(characters, &index),
        let compatibilityFlags = parseHex(characters, compatibilityElement, as: UInt32.self)
    else { return nil }

    // The tier letter L or H, then the level IDC in decimal.
    guard let tierLevel = nextElement(characters, &index) else { return nil }
    let tierCharacter = characters[tierLevel.lowerBound]
    if tierCharacter != 0x4C && tierCharacter != 0x48 {
        return nil
    }
    guard let generalLevelIDC = parseUInt8(characters, tierLevel.dropFirst()) else { return nil }

    var constraintFlags: UInt64 = 0
    var constraintFlagCount = 0
    while constraintFlagCount < 6, let element = nextElement(characters, &index) {
        guard let flag = parseHex(characters, element, as: UInt8.self) else { return nil }
        constraintFlags |= UInt64(flag) << (8 * constraintFlagCount)
        constraintFlagCount += 1
    }

    return ParsedHEVC(codec: codec, generalProfileSpace: generalProfileSpace, generalProfileIDC: UInt16(generalProfileIDC),
        generalProfileCompatibilityFlags: reverseBits32(compatibilityFlags), generalTierFlag: tierCharacter == 0x48 ? 1 : 0,
        generalLevelIDC: UInt16(generalLevelIDC), constraintFlags: constraintFlags, constraintFlagCount: constraintFlagCount)
}

/// Section 4.1 of "Dolby Vision Profiles and Levels Version 1.3.2": the valid profiles and the
/// highest level of each.
private func maximumDoViLevel(forProfile profileID: UInt16) -> UInt16? {
    switch profileID {
    case 4, 7: 9
    case 5, 8: 13
    case 9: 5
    default: nil
    }
}

/// "Dolby Vision Profiles and Levels Version 1.3.2": <dva1|dvav|dvh1|dvhe>.<profile>.<level>,
/// matched ignoring ASCII case. A profile starting with '0' is decimal. Any other profile is
/// looked up, Table 7, as that many characters of the whole string after its first five.
private func parseDoViCodecParameters<Unit: CodeUnit>(_ characters: Span<Unit>) -> ParsedDoVi? {
    var index = 0
    guard let codecElement = nextElement(characters, &index) else { return nil }
    let codec: DoViParameters.Codec
    let isAVC: Bool
    switch packedLetters(characters, codecElement, width: 4) {
    case 0x6476_6131: (codec, isAVC) = (.AVC1, true) // dva1
    case 0x6476_6176: (codec, isAVC) = (.AVC3, true) // dvav
    case 0x6476_6831: (codec, isAVC) = (.HVC1, false) // dvh1
    case 0x6476_6865: (codec, isAVC) = (.HEV1, false) // dvhe
    default: return nil
    }

    guard let profileElement = nextElement(characters, &index) else { return nil }
    let bitstreamProfileID: UInt16
    if characters[profileElement.lowerBound] == 0x30 {
        guard let profileID = parseUInt8(characters, profileElement) else { return nil }
        bitstreamProfileID = UInt16(profileID)
    } else {
        let key = 0..<min(characters.count, 5 + profileElement.count)
        switch packedLetters(characters, key, width: 8) {
        case 0x6476_6176_2E73_6500: bitstreamProfileID = 9 // dvav.se
        case 0x6476_6865_2E64_7462: bitstreamProfileID = 7 // dvhe.dtb
        case 0x6476_6865_2E64_7472: bitstreamProfileID = 4 // dvhe.dtr
        case 0x6476_6865_2E73_7400: bitstreamProfileID = 8 // dvhe.st
        case 0x6476_6865_2E73_746E: bitstreamProfileID = 5 // dvhe.stn
        default: return nil
        }
    }

    // Profile 9 is AVC only; every other profile is HEVC only.
    guard let maximumLevelID = maximumDoViLevel(forProfile: bitstreamProfileID), isAVC == (bitstreamProfileID == 9),
        let levelElement = nextElement(characters, &index),
        let bitstreamLevelID = parseUInt8(characters, levelElement), UInt16(bitstreamLevelID) <= maximumLevelID
    else { return nil }
    return ParsedDoVi(codec: codec, bitstreamProfileID: bitstreamProfileID, bitstreamLevelID: UInt16(bitstreamLevelID))
}

// MARK: - Decoder configuration records

/// ISO/IEC 14496-15:2014 AVCDecoderConfigurationRecord: version, profile, compatibility, level. At least 24 bytes.
private func parseAVCDecoderConfigurationRecord(_ data: Span<UInt8>) -> ParsedAVC? {
    if data.count < 24 {
        return nil
    }
    return ParsedAVC(profileIDC: data[1], constraintsFlags: data[2], levelIDC: data[3])
}

/// ISO/IEC 14496-15:2014, 8.3.3.1: version, profile space (2) tier (1) IDC (5), compatibility
/// flags (32, kept in stream bit order), constraint flags (48), level. At least 23 bytes.
private func parseHEVCDecoderConfigurationRecord(_ codecCode: UInt32, _ data: Span<UInt8>) -> ParsedHEVC? {
    if data.count < 23 {
        return nil
    }
    let codec: HEVCParameters.Codec
    switch codecCode {
    case 0x68657631: codec = .Hev1 // hev1
    case 0x68766331: codec = .Hvc1 // hvc1
    default: return nil
    }

    let profileSpaceTierIDC = data[1]
    var constraintFlags: UInt64 = 0
    for i in 0..<6 {
        constraintFlags |= UInt64(data[6 + i]) << (8 * i)
    }
    return ParsedHEVC(codec: codec, generalProfileSpace: UInt16(profileSpaceTierIDC >> 6), generalProfileIDC: UInt16(profileSpaceTierIDC & 0x1F),
        generalProfileCompatibilityFlags: bigEndianUInt32(data, at: 2), generalTierFlag: (profileSpaceTierIDC >> 5) & 1,
        generalLevelIDC: UInt16(data[12]), constraintFlags: constraintFlags, constraintFlagCount: 6)
}

/// "Dolby Vision Streams Within the ISO Base Media File Format, Version 2.0": dv_version_major,
/// dv_version_minor, dv_profile (7), dv_level (6), then flags. At least 24 bytes. Codec is not set.
private func parseDoViDecoderConfigurationRecord(_ data: Span<UInt8>) -> ParsedDoVi? {
    if data.count < 24 {
        return nil
    }
    let profileLevelAndFlags = bigEndianUInt16(data, at: 2)
    return ParsedDoVi(codec: nil, bitstreamProfileID: profileLevelAndFlags >> 9, bitstreamLevelID: (profileLevelAndFlags >> 3) & 0x3F)
}

// MARK: - Boundary

/// Reads the caller's Latin-1 or UTF-16 characters in place; both are compared as code points.
private func withCharacters<Result>(_ characters: UnsafeRawPointer?, _ length: Int, _ is8Bit: Bool, latin1: (Span<UInt8>) -> Result, utf16: (Span<UInt16>) -> Result) -> Result {
    // SAFETY: the caller passes `length` Latin-1 bytes if `is8Bit`, else `length` UTF-16 code units,
    // at `characters`, which is null only when `length` is 0, and does not modify or free them
    // until this call returns.
    let count = unsafe characters == nil ? 0 : length
    if is8Bit {
        return latin1(unsafe UnsafeBufferPointer(start: characters?.assumingMemoryBound(to: UInt8.self), count: count).span)
    }
    return utf16(unsafe UnsafeBufferPointer(start: characters?.assumingMemoryBound(to: UInt16.self), count: count).span)
}

@_cdecl("WebCoreAVCParseCodecParameters")
internal func webCoreAVCParseCodecParameters(_ characters: UnsafeRawPointer?, _ length: Int, _ is8Bit: Bool, _ rawParameters: UnsafeMutableRawPointer) -> Bool {
    guard let parsed = unsafe withCharacters(characters, length, is8Bit, latin1: parseAVCCodecParameters, utf16: parseAVCCodecParameters) else {
        return false
    }
    unsafe store(parsed, into: rawParameters)
    return true
}

@_cdecl("WebCoreAVCParseDecoderConfigurationRecord")
internal func webCoreAVCParseDecoderConfigurationRecord(_ bytes: UnsafePointer<UInt8>?, _ count: Int, _ rawParameters: UnsafeMutableRawPointer) -> Bool {
    unsafe withBytes(bytes, count) { data in
        guard let parsed = parseAVCDecoderConfigurationRecord(data) else {
            return false
        }
        unsafe store(parsed, into: rawParameters)
        return true
    }
}

@_cdecl("WebCoreHEVCParseCodecParameters")
internal func webCoreHEVCParseCodecParameters(_ characters: UnsafeRawPointer?, _ length: Int, _ is8Bit: Bool, _ rawParameters: UnsafeMutableRawPointer, _ constraintFlags: UnsafeMutablePointer<UInt8>) -> Bool {
    guard let parsed = unsafe withCharacters(characters, length, is8Bit, latin1: parseHEVCCodecParameters, utf16: parseHEVCCodecParameters) else {
        return false
    }
    unsafe store(parsed, into: rawParameters, constraintFlags: constraintFlags)
    return true
}

@_cdecl("WebCoreHEVCParseDecoderConfigurationRecord")
internal func webCoreHEVCParseDecoderConfigurationRecord(_ codecCode: UInt32, _ bytes: UnsafePointer<UInt8>?, _ count: Int, _ rawParameters: UnsafeMutableRawPointer, _ constraintFlags: UnsafeMutablePointer<UInt8>) -> Bool {
    unsafe withBytes(bytes, count) { data in
        guard let parsed = parseHEVCDecoderConfigurationRecord(codecCode, data) else {
            return false
        }
        unsafe store(parsed, into: rawParameters, constraintFlags: constraintFlags)
        return true
    }
}

@_cdecl("WebCoreDoViParseCodecParameters")
internal func webCoreDoViParseCodecParameters(_ characters: UnsafeRawPointer?, _ length: Int, _ is8Bit: Bool, _ rawParameters: UnsafeMutableRawPointer) -> Bool {
    guard let parsed = unsafe withCharacters(characters, length, is8Bit, latin1: parseDoViCodecParameters, utf16: parseDoViCodecParameters) else {
        return false
    }
    unsafe store(parsed, into: rawParameters)
    return true
}

@_cdecl("WebCoreDoViParseDecoderConfigurationRecord")
internal func webCoreDoViParseDecoderConfigurationRecord(_ bytes: UnsafePointer<UInt8>?, _ count: Int, _ rawParameters: UnsafeMutableRawPointer) -> Bool {
    unsafe withBytes(bytes, count) { data in
        guard let parsed = parseDoViDecoderConfigurationRecord(data) else {
            return false
        }
        unsafe store(parsed, into: rawParameters)
        return true
    }
}

#endif // ENABLE_HEVC_UTILITIES_SWIFT
