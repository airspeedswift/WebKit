/*
 * Copyright (C) 2020-2025 Apple Inc. All rights reserved.
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

// The VP8 and VP9 decoder capability checks: which configuration records the available decoders
// support, and the PlatformMediaCapabilitiesInfo a video configuration gets.
//
// Each @_cdecl entry point gets the address of a live record or video configuration, and returns
// either a Bool or a PlatformMediaCapabilitiesInfo packed into a byte: 0 is std::nullopt,
// otherwise bit 7 is set and bits 0, 1 and 2 hold supported, smooth and powerEfficient.
//
// The record's codecName is a WTF::String, so C++ classifies it into a codecKind first: 0 for
// neither VP8 nor VP9, 1 for "vp08"/"vp8", 2 for "vp09"/"vp9".
//
// vp9HardwareDecoderAvailable(), systemHasBattery() and systemHasAC() cache machine state on
// their first call, and vp9HardwareDecoderAvailable() can initialize codecs support as a side
// effect, so each is called at the point the check reaches it and no earlier.

#if ENABLE_VP9_CAPABILITIES_SWIFT

internal import WebCore_Private

private typealias VPCodecConfigurationRecord = WebCore_Private.WebCore.VPCodecConfigurationRecord
private typealias VideoConfiguration = WebCore_Private.WebCore.PlatformMediaCapabilitiesVideoConfiguration
private typealias TransferFunction = WebCore_Private.WebCore.PlatformMediaCapabilitiesTransferFunction
private typealias ColorGamut = WebCore_Private.WebCore.PlatformMediaCapabilitiesColorGamut

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

// MARK: - Resolution

private enum ResolutionCategory: UInt8, Comparable {
    case R_480p
    case R_720p
    case R_1080p
    case R_2K
    case R_4K
    case R_8K
    case R_12K

    static func < (lhs: ResolutionCategory, rhs: ResolutionCategory) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// The category of a FloatSize whose area() is `pixels`. Every threshold is a product of two
/// pixel counts below 2^24, so it converts to Float exactly and the comparison is the C++ one.
private func resolutionCategory(_ pixels: Float) -> ResolutionCategory {
    if pixels > 7680 * 4320 {
        return .R_12K
    }
    if pixels > 4096 * 2160 {
        return .R_8K
    }
    if pixels > 2048 * 1080 {
        return .R_4K
    }
    if pixels > 1920 * 1080 {
        return .R_2K
    }
    if pixels > 1280 * 720 {
        return .R_1080p
    }
    if pixels > 640 * 480 {
        return .R_720p
    }
    return .R_480p
}

/// Whether an attached screen, or the screen size and scale override, is large enough for 4K
/// video. largestScreenScaledArea() collapses the override and the screen datas into the one
/// area to categorize, since resolutionCategory is monotonic in area.
private func hasScreenLargeEnoughFor4K() -> Bool {
    resolutionCategory(WebCore_Private.WebCore.largestScreenScaledArea()) >= .R_4K
}

// MARK: - Configuration record

/// The record fields the capability checks read, loaded in place: the record holds a String.
private struct VPFields {
    var profile: UInt8
    var level: UInt8
    var bitDepth: UInt8
    var chromaSubsampling: UInt8
    var colorPrimaries: UInt8
    var transferCharacteristics: UInt8

    init(_ rawRecord: UnsafeRawPointer) {
        // SAFETY: the caller passes the address of a live VPCodecConfigurationRecord and does not
        // modify it until the call returns; only scalar fields are read, never codecName.
        let record = unsafe rawRecord.assumingMemoryBound(to: VPCodecConfigurationRecord.self)
        profile = unsafe record.pointee.profile
        level = unsafe record.pointee.level
        bitDepth = unsafe record.pointee.bitDepth
        chromaSubsampling = unsafe record.pointee.chromaSubsampling
        colorPrimaries = unsafe record.pointee.colorPrimaries
        transferCharacteristics = unsafe record.pointee.transferCharacteristics
    }
}

/// The video configuration fields the capability checks read, loaded in place: the configuration
/// holds a String.
private struct VideoConfigurationFields {
    var width: UInt32
    var height: UInt32
    var framerate: Double
    var alphaChannel: Bool?
    var colorGamut: ColorGamut?
    var transferFunction: TransferFunction?

    init(_ rawConfiguration: UnsafeRawPointer) {
        // SAFETY: the caller passes the address of a live
        // PlatformMediaCapabilitiesVideoConfiguration and does not modify it until the call
        // returns; only scalar and std::optional-of-scalar fields are read, never contentType.
        let configuration = unsafe rawConfiguration.assumingMemoryBound(to: VideoConfiguration.self)
        width = unsafe configuration.pointee.width
        height = unsafe configuration.pointee.height
        framerate = unsafe configuration.pointee.framerate
        alphaChannel = unsafe configuration.pointee.alphaChannel.value
        colorGamut = unsafe configuration.pointee.colorGamut.value
        transferFunction = unsafe configuration.pointee.transferFunction.value
    }
}

/// The codecName classification C++ passes across, since Swift does not read the WTF::String.
private enum CodecKind: UInt8 {
    case neither = 0
    case vp8 = 1
    case vp9 = 2
}

// MARK: - Supported configuration records

private func isVP9CodecConfigurationRecordSupported(_ codecConfiguration: VPFields) -> Bool {
    if !WebCore_Private.WebCore.isVP9DecoderAvailable() {
        return false
    }

    // HW & SW VP9 Decoders support Profile 0 & 2:
    if codecConfiguration.profile != 0 && codecConfiguration.profile != 2 {
        return false
    }

    // HW & SW VP9 Decoders support only 420 chroma subsampling:
    // VPConfigurationChromaSubsampling::Subsampling_420_Colocated.
    if codecConfiguration.chromaSubsampling > 1 {
        return false
    }

    // HW & SW VP9 Decoders support 8 or 10 bit color:
    if codecConfiguration.bitDepth > 10 {
        return false
    }

    // HW & SW VP9 Decoders support up to Level 6: VPConfigurationLevel::Level_6.
    if codecConfiguration.level > 60 {
        return false
    }

    // Hardware decoders are always available.
    if WebCore_Private.WebCore.vp9HardwareDecoderAvailable() && !WebCore_Private.WebCore.isSWDecodersAlwaysEnabled() {
        return true
    }

    // For wall-powered devices, always report VP9 as supported, even if not powerEfficient.
    if !WebCore_Private.WebCore.systemHasBattery() {
        return true
    }

    // For battery-powered devices, always report VP9 as supported when running on AC power,
    // but only on battery when there is an attached screen whose resolution is large enough
    // to support 4K video.
    if WebCore_Private.WebCore.systemHasAC() {
        return true
    }

    return hasScreenLargeEnoughFor4K()
}

private func isVP8CodecConfigurationRecordSupported(_ codecConfiguration: VPFields) -> Bool {
    if !WebCore_Private.WebCore.isVP8DecoderAvailable() {
        return false
    }

    // VP8 decoder only supports Profile 0;
    if codecConfiguration.profile != 0 {
        return false
    }

    // VP8 decoder only supports 420 chroma subsampling.
    // VPConfigurationChromaSubsampling::Subsampling_420_Colocated.
    if codecConfiguration.chromaSubsampling > 1 {
        return false
    }

    // VP8 decoder only supports 8-bit color:
    if codecConfiguration.bitDepth > 8 {
        return false
    }

    return true
}

private func isVPCodecConfigurationRecordSupported(_ codecConfiguration: VPFields, _ codecKind: CodecKind) -> Bool {
    switch codecKind {
    case .vp8:
        return isVP8CodecConfigurationRecordSupported(codecConfiguration)
    case .vp9:
        return isVP9CodecConfigurationRecordSupported(codecConfiguration)
    case .neither:
        return false
    }
}

// MARK: - Capabilities

private func isVPSoftwareDecoderSmooth(_ videoConfiguration: VideoConfigurationFields) -> Bool {
    if videoConfiguration.height <= 1080 && videoConfiguration.framerate > 60 {
        return false
    }

    if videoConfiguration.height <= 2160 && videoConfiguration.framerate > 30 {
        return false
    }

    return true
}

private func computeVPParameters(_ videoConfiguration: VideoConfigurationFields, _ vp9HardwareDecoderAvailable: Bool) -> CapabilitiesInfo? {
    var info = CapabilitiesInfo()

    if vp9HardwareDecoderAvailable {
        // HW VP9 Decoder does not support alpha channel:
        if videoConfiguration.alphaChannel ?? false {
            return nil
        }

        // HW VP9 Decoder can support up to 4K @ 120 or 8K @ 30
        let resolution = resolutionCategory(Float(videoConfiguration.width) * Float(videoConfiguration.height))
        if resolution > .R_8K {
            return nil
        }
        if resolution == .R_8K && videoConfiguration.framerate > 30 {
            info.smooth = false
        } else if resolution <= .R_4K && videoConfiguration.framerate > 120 {
            info.smooth = false
        } else {
            info.smooth = true
        }

        info.powerEfficient = true
        info.supported = true
        return info
    }

    info.powerEfficient = false

    // SW VP9 Decoder has much more variable capabilities depending on CPU characteristics.
    // FIXME: Add a lookup table for device-to-capabilities. For now, assume that the SW VP9
    // decoder can support 4K @ 30.
    info.smooth = isVPSoftwareDecoderSmooth(videoConfiguration)

    if WebCore_Private.WebCore.isSWDecodersAlwaysEnabled() {
        info.supported = true
        return info
    }

    // For wall-powered devices, always report VP9 as supported, even if not powerEfficient.
    if !WebCore_Private.WebCore.systemHasBattery() {
        info.supported = true
        return info
    }

    // For battery-powered devices, always report VP9 as supported when running on AC power,
    // but only on battery when there is an attached screen whose resolution is large enough
    // to support 4K video.
    if WebCore_Private.WebCore.systemHasAC() {
        info.supported = true
        return info
    }

    if !hasScreenLargeEnoughFor4K() {
        return nil
    }

    info.supported = true
    return info
}

private func validateVPParameters(_ codecConfiguration: VPFields, _ videoConfiguration: VideoConfigurationFields, _ codecKind: CodecKind) -> CapabilitiesInfo? {
    if !isVPCodecConfigurationRecordSupported(codecConfiguration, codecKind) {
        return nil
    }

    // PlatformMediaCapabilitiesVideoConfiguration and VPCodecConfigurationRecord can have conflicting values for HDR properties. If so, reject.
    if let transferFunction = videoConfiguration.transferFunction {
        // Note: Transfer Characteristics are defined by ISO/IEC 23091-2:2019.
        if transferFunction == .SRGB && codecConfiguration.transferCharacteristics > 15 {
            return nil
        }
        if transferFunction == .PQ && codecConfiguration.transferCharacteristics != 16 {
            return nil
        }
        if transferFunction == .HLG && codecConfiguration.transferCharacteristics != 18 {
            return nil
        }
    }

    if let colorGamut = videoConfiguration.colorGamut {
        if colorGamut == .Rec2020 && codecConfiguration.colorPrimaries != 9 {
            return nil
        }
    }
    return computeVPParameters(videoConfiguration, WebCore_Private.WebCore.vp9HardwareDecoderAvailable())
}

// MARK: - Entry points

@_cdecl("WebCoreVP9IsCodecConfigurationRecordSupported")
internal func webCoreVP9IsCodecConfigurationRecordSupported(_ rawRecord: UnsafeRawPointer, _ codecKind: UInt8) -> Bool {
    // SAFETY: C++ passes the address of a live VPCodecConfigurationRecord, whose scalar fields are
    // read before anything else runs; a codecKind outside the mapping is neither VP8 nor VP9.
    isVPCodecConfigurationRecordSupported(unsafe VPFields(rawRecord), CodecKind(rawValue: codecKind) ?? .neither)
}

@_cdecl("WebCoreVP9ValidateParameters")
internal func webCoreVP9ValidateParameters(_ rawRecord: UnsafeRawPointer, _ rawConfiguration: UnsafeRawPointer, _ codecKind: UInt8) -> UInt8 {
    // SAFETY: C++ passes the addresses of a live record and a live video configuration, whose
    // scalar fields are read before anything else runs; an unmapped codecKind is neither.
    pack(validateVPParameters(unsafe VPFields(rawRecord), unsafe VideoConfigurationFields(rawConfiguration), CodecKind(rawValue: codecKind) ?? .neither))
}

@_cdecl("WebCoreVP9IsSoftwareDecoderSmooth")
internal func webCoreVP9IsSoftwareDecoderSmooth(_ rawConfiguration: UnsafeRawPointer) -> Bool {
    // SAFETY: C++ passes the address of a live PlatformMediaCapabilitiesVideoConfiguration, whose
    // scalar fields are read before anything else runs.
    isVPSoftwareDecoderSmooth(unsafe VideoConfigurationFields(rawConfiguration))
}

@_cdecl("WebCoreVP9ComputeParameters")
internal func webCoreVP9ComputeParameters(_ rawConfiguration: UnsafeRawPointer, _ hardwareDecoderAvailable: Bool) -> UInt8 {
    // SAFETY: C++ passes the address of a live PlatformMediaCapabilitiesVideoConfiguration, whose
    // scalar fields are read before anything else runs.
    pack(computeVPParameters(unsafe VideoConfigurationFields(rawConfiguration), hardwareDecoderAvailable))
}

#endif // ENABLE_VP9_CAPABILITIES_SWIFT
