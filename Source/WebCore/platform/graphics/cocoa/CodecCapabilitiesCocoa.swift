/*
 * Copyright (C) 2018-2023 Apple Inc. All rights reserved.
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

// The VideoToolbox capability queries behind the AV1, HEVC and Dolby Vision decoding checks.
// Each @_cdecl entry point gets the address of a live parameters struct and returns a
// PlatformMediaCapabilitiesInfo packed into a byte: 0 is std::nullopt, otherwise bit 7 is set and
// bits 0, 1 and 2 hold supported, smooth and powerEfficient.
//
// VideoToolbox and AVFoundation are soft-linked, so every function and constant is reached
// through its soft-link accessor. A MAY_FAIL constant is read only after its canLoad_ check.

#if ENABLE_CODEC_CAPABILITIES_SWIFT

internal import CoreFoundation
internal import CoreMedia
internal import Foundation
internal import WebCore_Private
internal import pal.Core.cocoa.AVFoundationSoftLink

private typealias AV1CodecConfigurationRecord = WebCore_Private.WebCore.AV1CodecConfigurationRecord
private typealias HEVCParameters = WebCore_Private.WebCore.HEVCParameters
private typealias DoViParameters = WebCore_Private.WebCore.DoViParameters

// MARK: - Result

private struct CapabilitiesInfo {
    var supported = false
    var smooth = false
    var powerEfficient = false

    func packed() -> UInt8 {
        0x80 | (supported ? 1 : 0) | (smooth ? 2 : 0) | (powerEfficient ? 4 : 0)
    }
}

private func pack(_ info: CapabilitiesInfo?) -> UInt8 {
    info?.packed() ?? 0
}

// MARK: - CF helpers

/// WTF's `dynamic_cf_cast`: `object` as a `T` if its CF type is `typeID`, else nil. A Swift `as?`
/// to a CF type does not consult the type ID.
private func dynamicCFCast<T: AnyObject>(_ object: AnyObject?, typeID: CFTypeID, as _: T.Type) -> T? {
    guard let object, CFGetTypeID(object) == typeID else {
        return nil
    }
    return (object as! T)
}

private func dynamicCFArray(_ object: AnyObject?) -> CFArray? {
    dynamicCFCast(object, typeID: CFArrayGetTypeID(), as: CFArray.self)
}

private func dynamicCFDictionary(_ object: AnyObject?) -> CFDictionary? {
    dynamicCFCast(object, typeID: CFDictionaryGetTypeID(), as: CFDictionary.self)
}

private func dynamicCFNumber(_ object: AnyObject?) -> CFNumber? {
    dynamicCFCast(object, typeID: CFNumberGetTypeID(), as: CFNumber.self)
}

private func dynamicCFString(_ object: AnyObject?) -> CFString? {
    dynamicCFCast(object, typeID: CFStringGetTypeID(), as: CFString.self)
}

/// CFDictionaryGetValue. A nil `key` is passed as NULL, as the C++ would pass it.
private func dictionaryValue(_ dictionary: CFDictionary, _ key: AnyObject?) -> AnyObject? {
    withExtendedLifetime(key) {
        // SAFETY: `key` is kept alive across the call, so its unretained pointer is valid; the
        // result is +0 and owned by `dictionary`, which the caller keeps alive and which is
        // immutable, so takeUnretainedValue() yields a live object that is then retained.
        let keyPointer = unsafe key.map { unsafe UnsafeRawPointer(Unmanaged.passUnretained($0).toOpaque()) }
        guard let value = unsafe CFDictionaryGetValue(dictionary, keyPointer) else {
            return nil
        }
        return unsafe Unmanaged<AnyObject>.fromOpaque(value).takeUnretainedValue()
    }
}

/// Every element of `array` in order, a NULL element as nil.
private func arrayElements(_ array: CFArray) -> [AnyObject?] {
    (0..<CFArrayGetCount(array)).map { index in
        // SAFETY: `index` is within the count, and the element is +0 and owned by `array`,
        // which the caller keeps alive and which is immutable.
        unsafe CFArrayGetValueAtIndex(array, index).map { unsafe Unmanaged<AnyObject>.fromOpaque($0).takeUnretainedValue() }
    }
}

/// CFArrayContainsValue over the whole array for a kCFNumberSInt16Type number holding `value`.
private func arrayContainsSInt16(_ array: CFArray, _ value: Int16) -> Bool {
    var value = value
    // SAFETY: `&value` points to a live Int16, the layout kCFNumberSInt16Type names, for the call.
    guard let number = unsafe CFNumberCreate(kCFAllocatorDefault, .sInt16Type, &value) else {
        return false
    }
    return withExtendedLifetime(number) {
        // SAFETY: `number` is kept alive across the call, so its unretained pointer is valid.
        unsafe CFArrayContainsValue(array, CFRangeMake(0, CFArrayGetCount(array)), Unmanaged.passUnretained(number).toOpaque())
    }
}

/// CFNumberGetValue as kCFNumberSInt16Type into a zero-initialised Int16; nil if it returns false.
private func sInt16Value(_ number: CFNumber) -> Int16? {
    var value: Int16 = 0
    // SAFETY: `&value` points to a live, exclusively accessed Int16, which is exactly the size
    // and layout of kCFNumberSInt16Type, so CFNumberGetValue writes only within it.
    guard unsafe CFNumberGetValue(number, .sInt16Type, &value) else {
        return nil
    }
    return value
}

private func isBooleanTrue(_ dictionary: CFDictionary, _ key: AnyObject?) -> Bool {
    dictionaryValue(dictionary, key) === kCFBooleanTrue
}

/// WTF's parseInteger<T>(String(string)) in base 10: optional leading and trailing whitespace
/// (space, \t, \n, \v, \f, \r), an optional '+', then one or more decimal digits. Overflow of T fails.
private func parseDecimal<T: FixedWidthInteger & UnsignedInteger>(_ string: CFString, as _: T.Type) -> T? {
    let length = CFStringGetLength(string)
    func isWhitespace(_ character: UniChar) -> Bool {
        character == 0x20 || (0x09...0x0D).contains(character)
    }
    func isDigit(_ character: UniChar) -> Bool {
        (0x30...0x39).contains(character)
    }

    var index = 0
    while index < length && isWhitespace(CFStringGetCharacterAtIndex(string, index)) {
        index += 1
    }
    if index < length && CFStringGetCharacterAtIndex(string, index) == 0x2B {
        index += 1
    }
    guard index < length && isDigit(CFStringGetCharacterAtIndex(string, index)) else {
        return nil
    }

    var value: T = 0
    var overflowed = false
    while index < length && isDigit(CFStringGetCharacterAtIndex(string, index)) {
        let product = value.multipliedReportingOverflow(by: 10)
        let sum = product.partialValue.addingReportingOverflow(T(CFStringGetCharacterAtIndex(string, index) - 0x30))
        overflowed = overflowed || product.overflow || sum.overflow
        value = sum.partialValue
        index += 1
    }
    if overflowed {
        return nil
    }

    while index < length && isWhitespace(CFStringGetCharacterAtIndex(string, index)) {
        index += 1
    }
    return index == length ? value : nil
}

/// makeVector over parseInteger<uint8_t>: elements that are not CFStrings or do not parse are dropped.
private func parsedUInt8Elements(_ array: CFArray) -> [UInt8] {
    arrayElements(array).compactMap { element in
        dynamicCFString(element).flatMap { parseDecimal($0, as: UInt8.self) }
    }
}

// MARK: - AV1

/// The record fields validateAV1Parameters reads, loaded in place: the record holds a String.
private struct AV1Fields {
    var profile: UInt8
    var level: UInt8
    var bitDepth: UInt8
    var monochrome: UInt8
    var chromaSubsampling: UInt8
    var colorPrimaries: UInt8
    var transferCharacteristics: UInt8
    var matrixCoefficients: UInt8

    init(_ rawRecord: UnsafeRawPointer) {
        // SAFETY: the caller passes the address of a live AV1CodecConfigurationRecord and does
        // not modify it until the call returns; only scalar fields are read.
        let record = unsafe rawRecord.assumingMemoryBound(to: AV1CodecConfigurationRecord.self)
        profile = unsafe record.pointee.profile.rawValue
        level = unsafe record.pointee.level.rawValue
        bitDepth = unsafe record.pointee.bitDepth
        monochrome = unsafe record.pointee.monochrome
        chromaSubsampling = unsafe record.pointee.chromaSubsampling
        colorPrimaries = unsafe record.pointee.colorPrimaries
        transferCharacteristics = unsafe record.pointee.transferCharacteristics
        matrixCoefficients = unsafe record.pointee.matrixCoefficients
    }
}

private struct AV1Constants {
    let supportedProfiles: CFString?
    let perProfileSupport: CFString?
    let isHardwareAccelerated: CFString?
    let maxDecodeLevel: CFString?
    let maxPlaybackLevel: CFString?
    let chromaSubsampling: CFString?
    let colorDepth: CFString?

    static func load() -> AV1Constants {
        // SAFETY: each getter returns a +0 reference to an immutable CFString exported by
        // VideoToolbox, which stays loaded once canLoad_ has succeeded, so takeUnretainedValue()
        // is right; the getters carry no CF annotation, hence Unmanaged.
        unsafe AV1Constants(
            supportedProfiles: WebCore_Private.WebCore.get_VideoToolbox_kVTDecoderCodecCapability_SupportedProfilesSingleton()?.takeUnretainedValue(),
            perProfileSupport: WebCore_Private.WebCore.get_VideoToolbox_kVTDecoderCodecCapability_PerProfileSupportSingleton()?.takeUnretainedValue(),
            isHardwareAccelerated: WebCore_Private.WebCore.get_VideoToolbox_kVTDecoderProfileCapability_IsHardwareAcceleratedSingleton()?.takeUnretainedValue(),
            maxDecodeLevel: WebCore_Private.WebCore.get_VideoToolbox_kVTDecoderProfileCapability_MaxDecodeLevelSingleton()?.takeUnretainedValue(),
            maxPlaybackLevel: WebCore_Private.WebCore.get_VideoToolbox_kVTDecoderProfileCapability_MaxPlaybackLevelSingleton()?.takeUnretainedValue(),
            chromaSubsampling: WebCore_Private.WebCore.get_VideoToolbox_kVTDecoderCapability_ChromaSubsamplingSingleton()?.takeUnretainedValue(),
            colorDepth: WebCore_Private.WebCore.get_VideoToolbox_kVTDecoderCapability_ColorDepthSingleton()?.takeUnretainedValue()
        )
    }
}

private func isConfigurationRecordHDR(_ record: AV1Fields) -> Bool {
    if record.bitDepth < 10 {
        return false
    }
    // AV1ConfigurationColorPrimaries::BT_2020_Nonconstant_Luminance.
    if record.colorPrimaries != 9 {
        return false
    }
    // BT_2020_10bit, BT_2020_12bit, SMPTE_ST_2084, BT_2100_HLG.
    if record.transferCharacteristics != 14 && record.transferCharacteristics != 15
        && record.transferCharacteristics != 16 && record.transferCharacteristics != 18 {
        return false
    }
    // BT_2020_Nonconstant_Luminance, BT_2020_Constant_Luminance, BT_2100_ICC.
    if record.matrixCoefficients != 9 && record.matrixCoefficients != 10 && record.matrixCoefficients != 14 {
        return false
    }
    return true
}

private func validateAV1Parameters(_ record: AV1Fields) -> CapabilitiesInfo? {
    guard WebCore_Private.WebCore.canLoad_VideoToolbox_VTCopyAV1DecoderCapabilitiesDictionary(),
        WebCore_Private.WebCore.canLoad_VideoToolbox_kVTDecoderCodecCapability_SupportedProfiles(),
        WebCore_Private.WebCore.canLoad_VideoToolbox_kVTDecoderCodecCapability_PerProfileSupport(),
        WebCore_Private.WebCore.canLoad_VideoToolbox_kVTDecoderProfileCapability_IsHardwareAccelerated(),
        WebCore_Private.WebCore.canLoad_VideoToolbox_kVTDecoderProfileCapability_MaxDecodeLevel(),
        WebCore_Private.WebCore.canLoad_VideoToolbox_kVTDecoderProfileCapability_MaxPlaybackLevel(),
        WebCore_Private.WebCore.canLoad_VideoToolbox_kVTDecoderCapability_ChromaSubsampling(),
        WebCore_Private.WebCore.canLoad_VideoToolbox_kVTDecoderCapability_ColorDepth()
    else { return nil }

    // SAFETY: a Copy function returns +1, so takeRetainedValue() balances it (adoptCF in C++);
    // the soft-link wrapper carries no CF annotation, hence Unmanaged.
    guard let capabilities = unsafe WebCore_Private.WebCore.softLink_VideoToolbox_VTCopyAV1DecoderCapabilitiesDictionary()?.takeRetainedValue() else {
        return nil
    }
    let keys = AV1Constants.load()

    guard let supportedProfiles = dynamicCFArray(dictionaryValue(capabilities, keys.supportedProfiles)) else {
        return nil
    }
    let profile = Int16(record.profile)
    guard arrayContainsSInt16(supportedProfiles, profile) else {
        return nil
    }

    guard let perProfileSupport = dynamicCFDictionary(dictionaryValue(capabilities, keys.perProfileSupport)),
        let profileSupport = dynamicCFDictionary(dictionaryValue(perProfileSupport, Swift.String(profile) as CFString))
    else { return nil }

    var info = CapabilitiesInfo()
    info.supported = true
    info.powerEfficient = isBooleanTrue(profileSupport, keys.isHardwareAccelerated)

    let level = Int16(record.level)
    if let cfMaxDecodeLevel = dynamicCFNumber(dictionaryValue(profileSupport, keys.maxDecodeLevel)) {
        guard let maxDecodeLevel = sInt16Value(cfMaxDecodeLevel), level <= maxDecodeLevel else {
            return nil
        }
    }

    if let cfSupportedChromaSubsampling = dynamicCFArray(dictionaryValue(profileSupport, keys.chromaSubsampling)) {
        // VideoToolbox's low digit is mono_chrome, where the codecs string has
        // chroma_sample_position, so the query keeps the record's high digits and uses monochrome.
        let subsamplingXandY = record.chromaSubsampling - record.chromaSubsampling % 10
        let subsamplingQuery = subsamplingXandY &+ (record.monochrome != 0 ? 1 : 0)
        guard parsedUInt8Elements(cfSupportedChromaSubsampling).contains(subsamplingQuery) else {
            return nil
        }
    }

    if let cfSupportedColorDepths = dynamicCFArray(dictionaryValue(profileSupport, keys.colorDepth)) {
        guard parsedUInt8Elements(cfSupportedColorDepths).contains(record.bitDepth) else {
            return nil
        }
    }

    if let cfMaxPlaybackLevel = dynamicCFNumber(dictionaryValue(profileSupport, keys.maxPlaybackLevel)) {
        guard let maxPlaybackLevel = sInt16Value(cfMaxPlaybackLevel) else {
            return nil
        }
        info.smooth = level <= maxPlaybackLevel
    }

    if WebCore_Private.WebCore.canLoad_VideoToolbox_kVTDecoderProfileCapability_MaxHDRPlaybackLevel() && isConfigurationRecordHDR(record) {
        // SAFETY: as for AV1Constants.load(); canLoad_ has just succeeded.
        let maxHDRPlaybackLevelKey = unsafe WebCore_Private.WebCore.get_VideoToolbox_kVTDecoderProfileCapability_MaxHDRPlaybackLevelSingleton()?.takeUnretainedValue()
        if let cfMaxHDRPlaybackLevel = dynamicCFNumber(dictionaryValue(profileSupport, maxHDRPlaybackLevelKey)) {
            guard let maxHDRPlaybackLevel = sInt16Value(cfMaxHDRPlaybackLevel) else {
                return nil
            }
            info.smooth = level <= maxHDRPlaybackLevel
        }
    }

    return info
}

@_cdecl("WebCoreAV1ValidateParameters")
internal func webCoreAV1ValidateParameters(_ rawRecord: UnsafeRawPointer) -> UInt8 {
    pack(validateAV1Parameters(unsafe AV1Fields(rawRecord)))
}

// MARK: - HEVC and Dolby Vision

private func canCreateDecoder(_ codec: CMVideoCodecType) -> Bool {
    // SAFETY: the out-parameter is NULL, so no decoder instance is returned and none is owned.
    unsafe WebCore_Private.WebCore.softLink_VideoToolbox_VTSelectAndCreateVideoDecoderInstance(codec, kCFAllocatorDefault, nil, nil) == noErr
}

private func copyHEVCDecoderCapabilities() -> CFDictionary? {
    // SAFETY: as for the AV1 capabilities copy.
    unsafe WebCore_Private.WebCore.softLink_VideoToolbox_VTCopyHEVCDecoderCapabilitiesDictionary()?.takeRetainedValue()
}

/// FourCC::fromString(String { AVVideoCodecTypeHEVCWithAlpha }): four ASCII characters, big-endian.
private func hevcWithAlphaCodecType() -> CMVideoCodecType? {
    let string: Swift.String? = PAL.get_AVFoundation_AVVideoCodecTypeHEVCWithAlphaSingleton()
    let units = Array((string ?? "").utf16)
    guard units.count == 4, units.allSatisfy({ $0 < 0x80 }) else {
        return nil
    }
    return units.reduce(0) { ($0 << 8) | CMVideoCodecType($1) }
}

private struct HEVCConstants {
    let supportedProfiles: CFString?
    let perProfileSupport: CFString?
    let isHardwareAccelerated: CFString?
    let maxDecodeLevel: CFString?
    let maxPlaybackLevel: CFString?

    static func load() -> HEVCConstants {
        // SAFETY: as for AV1Constants.load(); every canLoad_ has already succeeded.
        unsafe HEVCConstants(
            supportedProfiles: WebCore_Private.WebCore.get_VideoToolbox_kVTHEVCDecoderCapability_SupportedProfilesSingleton()?.takeUnretainedValue(),
            perProfileSupport: WebCore_Private.WebCore.get_VideoToolbox_kVTHEVCDecoderCapability_PerProfileSupportSingleton()?.takeUnretainedValue(),
            isHardwareAccelerated: WebCore_Private.WebCore.get_VideoToolbox_kVTHEVCDecoderProfileCapability_IsHardwareAcceleratedSingleton()?.takeUnretainedValue(),
            maxDecodeLevel: WebCore_Private.WebCore.get_VideoToolbox_kVTHEVCDecoderProfileCapability_MaxDecodeLevelSingleton()?.takeUnretainedValue(),
            maxPlaybackLevel: WebCore_Private.WebCore.get_VideoToolbox_kVTHEVCDecoderProfileCapability_MaxPlaybackLevelSingleton()?.takeUnretainedValue()
        )
    }
}

private struct HEVCFields {
    var generalProfileSpace: UInt16
    var generalProfileIDC: UInt16
    var generalProfileCompatibilityFlags: UInt32
    var generalLevelIDC: UInt16

    init(_ rawParameters: UnsafeRawPointer) {
        // SAFETY: the caller passes the address of a live HEVCParameters, unmodified until the
        // call returns; only scalar fields are read, never the Vector.
        let parameters = unsafe rawParameters.assumingMemoryBound(to: HEVCParameters.self)
        generalProfileSpace = unsafe parameters.pointee.generalProfileSpace
        generalProfileIDC = unsafe parameters.pointee.generalProfileIDC
        generalProfileCompatibilityFlags = unsafe parameters.pointee.generalProfileCompatibilityFlags
        generalLevelIDC = unsafe parameters.pointee.generalLevelIDC
    }
}

private func validateHEVCParameters(_ parameters: HEVCFields, hasAlphaChannel: Bool, hdrSupport: Bool) -> CapabilitiesInfo? {
    var codec = kCMVideoCodecType_HEVC
    if hasAlphaChannel {
        guard PAL.isAVFoundationFrameworkAvailable(), PAL.canLoad_AVFoundation_AVVideoCodecTypeHEVCWithAlpha() else {
            return nil
        }
        guard let codecCode = hevcWithAlphaCodecType() else {
            return nil
        }
        codec = codecCode
    }

    if hdrSupport {
        // HEVC Main10 Profile, as defined by ITU-T H.265 v6 (06/2019).
        let isMain10 = parameters.generalProfileSpace == 0
            && (parameters.generalProfileIDC == 2 || parameters.generalProfileCompatibilityFlags == 1)
        if !isMain10 {
            return nil
        }
    }

    guard canCreateDecoder(codec) else {
        return nil
    }

    guard WebCore_Private.WebCore.canLoad_VideoToolbox_VTCopyHEVCDecoderCapabilitiesDictionary(),
        WebCore_Private.WebCore.canLoad_VideoToolbox_kVTHEVCDecoderCapability_SupportedProfiles(),
        WebCore_Private.WebCore.canLoad_VideoToolbox_kVTHEVCDecoderCapability_PerProfileSupport(),
        WebCore_Private.WebCore.canLoad_VideoToolbox_kVTHEVCDecoderProfileCapability_IsHardwareAccelerated(),
        WebCore_Private.WebCore.canLoad_VideoToolbox_kVTHEVCDecoderProfileCapability_MaxDecodeLevel(),
        WebCore_Private.WebCore.canLoad_VideoToolbox_kVTHEVCDecoderProfileCapability_MaxPlaybackLevel()
    else { return nil }

    guard let capabilities = copyHEVCDecoderCapabilities() else {
        return nil
    }
    let keys = HEVCConstants.load()

    guard let supportedProfiles = dynamicCFArray(dictionaryValue(capabilities, keys.supportedProfiles)) else {
        return nil
    }
    let generalProfileIDC = Int16(truncatingIfNeeded: parameters.generalProfileIDC)
    guard arrayContainsSInt16(supportedProfiles, generalProfileIDC) else {
        return nil
    }

    guard let perProfileSupport = dynamicCFDictionary(dictionaryValue(capabilities, keys.perProfileSupport)),
        let profileSupport = dynamicCFDictionary(dictionaryValue(perProfileSupport, Swift.String(generalProfileIDC) as CFString))
    else { return nil }

    var info = CapabilitiesInfo()
    info.supported = true
    info.powerEfficient = isBooleanTrue(profileSupport, keys.isHardwareAccelerated)

    // uint16_t against int16_t: both promote to int.
    let generalLevelIDC = Int(parameters.generalLevelIDC)
    if let cfMaxDecodeLevel = dynamicCFNumber(dictionaryValue(profileSupport, keys.maxDecodeLevel)) {
        guard let maxDecodeLevel = sInt16Value(cfMaxDecodeLevel), generalLevelIDC <= Int(maxDecodeLevel) else {
            return nil
        }
    }

    if let cfMaxPlaybackLevel = dynamicCFNumber(dictionaryValue(profileSupport, keys.maxPlaybackLevel)) {
        guard let maxPlaybackLevel = sInt16Value(cfMaxPlaybackLevel) else {
            return nil
        }
        info.smooth = generalLevelIDC <= Int(maxPlaybackLevel)
    }

    return info
}

@_cdecl("WebCoreHEVCValidateParameters")
internal func webCoreHEVCValidateParameters(_ rawParameters: UnsafeRawPointer, _ hasAlphaChannel: Bool, _ hdrSupport: Bool) -> UInt8 {
    pack(validateHEVCParameters(unsafe HEVCFields(rawParameters), hasAlphaChannel: hasAlphaChannel, hdrSupport: hdrSupport))
}

private struct DoViFields {
    var codec: DoViParameters.Codec
    var bitstreamProfileID: UInt16
    var bitstreamLevelID: UInt16

    init(_ rawParameters: UnsafeRawPointer) {
        // SAFETY: as for HEVCFields; DoViParameters holds only scalars.
        let parameters = unsafe rawParameters.assumingMemoryBound(to: DoViParameters.self)
        codec = unsafe parameters.pointee.codec
        bitstreamProfileID = unsafe parameters.pointee.bitstreamProfileID
        bitstreamLevelID = unsafe parameters.pointee.bitstreamLevelID
    }
}

private struct DoViConstants {
    let supportedProfiles: CFString?
    let supportedLevels: CFString?
    let isHardwareAccelerated: CFString?

    static func load() -> DoViConstants {
        // SAFETY: as for AV1Constants.load(); every canLoad_ has already succeeded.
        unsafe DoViConstants(
            supportedProfiles: WebCore_Private.WebCore.get_VideoToolbox_kVTDolbyVisionDecoderCapability_SupportedProfilesSingleton()?.takeUnretainedValue(),
            supportedLevels: WebCore_Private.WebCore.get_VideoToolbox_kVTDolbyVisionDecoderCapability_SupportedLevelsSingleton()?.takeUnretainedValue(),
            isHardwareAccelerated: WebCore_Private.WebCore.get_VideoToolbox_kVTDolbyVisionDecoderCapability_IsHardwareAcceleratedSingleton()?.takeUnretainedValue()
        )
    }
}

private func codecType(_ codec: DoViParameters.Codec) -> CMVideoCodecType {
    switch codec {
    case .AVC1, .AVC3:
        return kCMVideoCodecType_H264
    case .HEV1, .HVC1:
        return kCMVideoCodecType_HEVC
    @unknown default:
        // Undefined behaviour in C++, which has no return for a value outside the enum.
        fatalError()
    }
}

/// The array at `dictionary[key]`, each element parsed as parseInteger<uint16_t> of the NSString
/// it is (a non-NSString is a null String); nil if it is not an array or any element fails.
private func parseStringArrayFromDictionaryToUInt16Vector(_ dictionary: CFDictionary, _ key: AnyObject?) -> [UInt16]? {
    guard let array = dynamicCFArray(dictionaryValue(dictionary, key)) else {
        return nil
    }
    var result: [UInt16] = []
    for element in arrayElements(array) {
        guard let string = element as? NSString, let value = parseDecimal(string as CFString, as: UInt16.self) else {
            return nil
        }
        result.append(value)
    }
    return result
}

private func validateDoViParameters(_ parameters: DoViFields, hasAlphaChannel: Bool, hdrSupport: Bool) -> CapabilitiesInfo? {
    if hasAlphaChannel {
        return nil
    }

    if hdrSupport {
        // HEVC Main10 Profile is signalled by DoVi profiles 4, 5, 7 and 8.
        switch parameters.bitstreamProfileID {
        case 4, 5, 7, 8:
            break
        default:
            return nil
        }
    }

    guard canCreateDecoder(codecType(parameters.codec)) else {
        return nil
    }

    guard WebCore_Private.WebCore.canLoad_VideoToolbox_VTCopyHEVCDecoderCapabilitiesDictionary(),
        WebCore_Private.WebCore.canLoad_VideoToolbox_kVTDolbyVisionDecoderCapability_SupportedProfiles(),
        WebCore_Private.WebCore.canLoad_VideoToolbox_kVTDolbyVisionDecoderCapability_SupportedLevels(),
        WebCore_Private.WebCore.canLoad_VideoToolbox_kVTDolbyVisionDecoderCapability_IsHardwareAccelerated()
    else { return nil }

    guard let capabilities = copyHEVCDecoderCapabilities() else {
        return nil
    }
    let keys = DoViConstants.load()

    guard let supportedProfiles = parseStringArrayFromDictionaryToUInt16Vector(capabilities, keys.supportedProfiles),
        let supportedLevels = parseStringArrayFromDictionaryToUInt16Vector(capabilities, keys.supportedLevels)
    else { return nil }

    let isHardwareAccelerated = isBooleanTrue(capabilities, keys.isHardwareAccelerated)

    guard supportedProfiles.contains(parameters.bitstreamProfileID), supportedLevels.contains(parameters.bitstreamLevelID) else {
        return nil
    }

    return CapabilitiesInfo(supported: true, smooth: true, powerEfficient: isHardwareAccelerated)
}

@_cdecl("WebCoreDoViValidateParameters")
internal func webCoreDoViValidateParameters(_ rawParameters: UnsafeRawPointer, _ hasAlphaChannel: Bool, _ hdrSupport: Bool) -> UInt8 {
    pack(validateDoViParameters(unsafe DoViFields(rawParameters), hasAlphaChannel: hasAlphaChannel, hdrSupport: hdrSupport))
}

#endif
