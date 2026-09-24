/*
 * Copyright (C) 2020-2021 Apple Inc. All rights reserved.
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

// Sample-buffer slicing (forEachSample, copySampleBufferForRange), including buffers whose packet
// sizes live only in their audio stream packet descriptions, and the colour-space extensions and
// pixel-buffer attachments of a PlatformVideoColorSpace. Reached from C++ through @_cdecl; every
// CoreMedia function goes through its PAL soft-link accessor, and every CoreVideo function and
// constant through WebCore's.

#if ENABLE_CM_UTILITIES_SWIFT

internal import CoreFoundation
internal import CoreMedia
internal import CoreVideo
internal import Foundation
internal import WebCore_Private
internal import pal.Core.cf.CoreMediaSoftLink

private func sampleBufferHasNoSampleSizes(_ sampleBuffer: CMSampleBuffer?) -> Bool {
    // SAFETY: a size query passes no output array and no count pointer, so nothing is written.
    unsafe PAL.softLink_CoreMedia_CMSampleBufferGetSampleSizeArray(sampleBuffer, 0, nil, nil) == kCMSampleBufferError_BufferHasNoSampleSizes
}

/// `WebCore::getPacketDescriptions`; `body` sees an empty span on any failure.
private func withPacketDescriptions<R>(_ sampleBuffer: CMSampleBuffer?, _ body: (Span<AudioStreamPacketDescription>) -> R) -> R {
    var packetDescriptionsSize = 0
    guard unsafe PAL.softLink_CoreMedia_CMSampleBufferGetAudioStreamPacketDescriptions(sampleBuffer, 0, nil, &packetDescriptionsSize) == noErr else {
        return body(Span())
    }
    let numDescriptions = packetDescriptionsSize / MemoryLayout<AudioStreamPacketDescription>.size
    if numDescriptions == 0 {
        return body(Span())
    }
    return withUnsafeTemporaryAllocation(of: AudioStreamPacketDescription.self, capacity: numDescriptions) { descriptions in
        unsafe descriptions.initialize(repeating: AudioStreamPacketDescription())
        // SAFETY: `descriptions` holds the whole descriptions within `packetDescriptionsSize`.
        guard unsafe PAL.softLink_CoreMedia_CMSampleBufferGetAudioStreamPacketDescriptions(sampleBuffer, packetDescriptionsSize, descriptions.baseAddress, nil) == noErr else {
            return body(Span())
        }
        let numPackets = PAL.softLink_CoreMedia_CMSampleBufferGetNumSamples(sampleBuffer)
        guard UInt(numDescriptions) == UInt(bitPattern: numPackets) else {
            return body(Span())
        }
        // SAFETY: every element was initialized above and the allocation outlives `body`.
        return body(unsafe UnsafeBufferPointer(descriptions).span)
    }
}

/// `WebCore::getSampleTimingInfoArray`: `body` sees an empty span on any failure.
private func withSampleTimingInfo<R>(_ sampleBuffer: CMSampleBuffer?, _ body: (Span<CMSampleTimingInfo>) -> R) -> R {
    var entriesNeeded: CMItemCount = 0
    guard unsafe PAL.softLink_CoreMedia_CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, 0, nil, &entriesNeeded) == noErr, entriesNeeded != 0 else {
        return body(Span())
    }
    return withUnsafeTemporaryAllocation(of: CMSampleTimingInfo.self, capacity: entriesNeeded) { timings in
        unsafe timings.initialize(repeating: CMSampleTimingInfo())
        // SAFETY: `timings` holds exactly `entriesNeeded` elements.
        guard unsafe PAL.softLink_CoreMedia_CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entriesNeeded, timings.baseAddress, nil) == noErr else {
            return body(Span())
        }
        return body(unsafe UnsafeBufferPointer(timings).span)
    }
}

/// The format description and data buffer of `sampleBuffer`, retained, or nil for either.
private func formatAndData(_ sampleBuffer: CMSampleBuffer?) -> (CMFormatDescription, CMBlockBuffer)? {
    // SAFETY: both getters return +0 objects owned by `sampleBuffer`, which the caller keeps alive.
    let formatDescription = unsafe PAL.softLink_CoreMedia_CMSampleBufferGetFormatDescription(sampleBuffer)?.takeUnretainedValue()
    let sourceBlockBuffer = unsafe PAL.softLink_CoreMedia_CMSampleBufferGetDataBuffer(sampleBuffer)?.takeUnretainedValue()
    guard let formatDescription, let sourceBlockBuffer else {
        return nil
    }
    return (formatDescription, sourceBlockBuffer)
}

/// The capacity is truncated to 32 bits, as the C++ implicit conversion does.
private func createEmptyBlockBuffer(_ capacity: CFIndex) -> CMBlockBuffer? {
    var rawSubBlock: CMBlockBuffer?
    // SAFETY: `&rawSubBlock` points to a live local for the duration of the call.
    guard unsafe PAL.softLink_CoreMedia_CMBlockBufferCreateEmpty(kCFAllocatorDefault, UInt32(truncatingIfNeeded: capacity), 0, &rawSubBlock) == kCMBlockBufferNoErr else {
        return nil
    }
    return rawSubBlock
}

private func appendPacket(_ subBlock: CMBlockBuffer, _ sourceBlockBuffer: CMBlockBuffer, _ desc: AudioStreamPacketDescription) -> Bool {
    if desc.mStartOffset < 0 {
        return false
    }
    return PAL.softLink_CoreMedia_CMBlockBufferAppendBufferReference(subBlock, sourceBlockBuffer, Int(desc.mStartOffset), Int(desc.mDataByteSize), 0) == kCMBlockBufferNoErr
}

private func createSinglePacketSampleBuffer(_ sourceBlockBuffer: CMBlockBuffer, _ formatDescription: CMFormatDescription, _ desc: AudioStreamPacketDescription, _ timing: CMSampleTimingInfo) -> CMSampleBuffer? {
    guard desc.mStartOffset >= 0, let subBlock = createEmptyBlockBuffer(1), appendPacket(subBlock, sourceBlockBuffer, desc) else {
        return nil
    }
    var timing = timing
    var sampleSize = Int(desc.mDataByteSize)
    var rawSample: CMSampleBuffer?
    // SAFETY: each `&` argument points to a live local holding exactly the one entry passed.
    guard unsafe PAL.softLink_CoreMedia_CMSampleBufferCreateReady(kCFAllocatorDefault, subBlock, formatDescription, 1, 1, &timing, 1, &sampleSize, &rawSample) == noErr else {
        return nil
    }
    return rawSample
}

/// `baseTiming` with each valid timestamp advanced by `count` durations, when the duration is valid.
private func advanced(_ baseTiming: CMSampleTimingInfo, by count: CFIndex) -> CMSampleTimingInfo {
    var timing = baseTiming
    guard baseTiming.duration.flags.contains(.valid) else {
        return timing
    }
    for _ in 0..<count {
        if timing.presentationTimeStamp.flags.contains(.valid) {
            timing.presentationTimeStamp = PAL.softLink_CoreMedia_CMTimeAdd(timing.presentationTimeStamp, baseTiming.duration)
        }
        if timing.decodeTimeStamp.flags.contains(.valid) {
            timing.decodeTimeStamp = PAL.softLink_CoreMedia_CMTimeAdd(timing.decodeTimeStamp, baseTiming.duration)
        }
    }
    return timing
}

// MARK: - The C boundary

/// `WebCore::forEachSample`; the first non-noErr callback result stops the walk and is returned.
@_cdecl("WebCoreCMForEachSample")
internal func webCoreCMForEachSample(_ sampleBuffer: CMSampleBuffer?, _ callback: @convention(c) (CMSampleBuffer?, CMItemCount, UnsafeMutableRawPointer?) -> OSStatus, _ context: UnsafeMutableRawPointer?) -> OSStatus {
    if !sampleBufferHasNoSampleSizes(sampleBuffer) {
        // SAFETY: `callback` and `context` are the caller's matched pair, used only during this call.
        return unsafe PAL.softLink_CoreMedia_CMSampleBufferCallForEachSample(sampleBuffer, callback, context)
    }

    let numSamples = PAL.softLink_CoreMedia_CMSampleBufferGetNumSamples(sampleBuffer)
    return withPacketDescriptions(sampleBuffer) { packetDescs in
        guard UInt(packetDescs.count) == UInt(bitPattern: numSamples) else {
            return kCMSampleBufferError_CannotSubdivide
        }
        return withSampleTimingInfo(sampleBuffer) { timings in
            if timings.isEmpty {
                return kCMSampleBufferError_CannotSubdivide
            }
            let uniformTiming = timings.count == 1
            let baseTiming = timings[0]
            var runningPTS = baseTiming.presentationTimeStamp
            var runningDTS = baseTiming.decodeTimeStamp

            guard let (formatDescription, sourceBlockBuffer) = formatAndData(sampleBuffer) else {
                return kCMSampleBufferError_CannotSubdivide
            }

            for i in 0..<max(numSamples, 0) {
                let timing = uniformTiming
                    ? CMSampleTimingInfo(duration: baseTiming.duration, presentationTimeStamp: runningPTS, decodeTimeStamp: runningDTS)
                    : timings[i]
                if uniformTiming && baseTiming.duration.flags.contains(.valid) {
                    if runningPTS.flags.contains(.valid) {
                        runningPTS = PAL.softLink_CoreMedia_CMTimeAdd(runningPTS, baseTiming.duration)
                    }
                    if runningDTS.flags.contains(.valid) {
                        runningDTS = PAL.softLink_CoreMedia_CMTimeAdd(runningDTS, baseTiming.duration)
                    }
                }

                guard let subSample = createSinglePacketSampleBuffer(sourceBlockBuffer, formatDescription, packetDescs[i], timing) else {
                    return kCMSampleBufferError_CannotSubdivide
                }

                let status = unsafe callback(subSample, i, context)
                if status != noErr {
                    return status
                }
            }
            return noErr
        }
    }
}

private func copyPacketDescribedRange(_ sampleBuffer: CMSampleBuffer?, _ location: CFIndex, _ length: CFIndex) -> CMSampleBuffer? {
    let numSamples = PAL.softLink_CoreMedia_CMSampleBufferGetNumSamples(sampleBuffer)
    // Wrapping addition matches the C++ on overflow; the out-of-range index then traps below.
    if location < 0 || length <= 0 || location &+ length > numSamples {
        return nil
    }

    return withPacketDescriptions(sampleBuffer) { packetDescs -> CMSampleBuffer? in
        guard UInt(packetDescs.count) == UInt(bitPattern: numSamples) else {
            return nil
        }
        return withSampleTimingInfo(sampleBuffer) { timings -> CMSampleBuffer? in
            guard !timings.isEmpty, let (formatDescription, sourceBlockBuffer) = formatAndData(sampleBuffer), let subBlock = createEmptyBlockBuffer(length) else {
                return nil
            }

            return withUnsafeTemporaryAllocation(of: Int.self, capacity: length) { sampleSizes -> CMSampleBuffer? in
                for i in 0..<length {
                    let desc = packetDescs[location &+ i]
                    guard appendPacket(subBlock, sourceBlockBuffer, desc) else {
                        return nil
                    }
                    unsafe sampleSizes.initializeElement(at: i, to: Int(desc.mDataByteSize))
                }

                let createReady = { (timingEntries: CMItemCount, timingArray: UnsafePointer<CMSampleTimingInfo>?) -> CMSampleBuffer? in
                    var rawSample: CMSampleBuffer?
                    // SAFETY: `timingArray` and `sampleSizes` hold the entry counts passed with them.
                    guard unsafe PAL.softLink_CoreMedia_CMSampleBufferCreateReady(kCFAllocatorDefault, subBlock, formatDescription, length, timingEntries, timingArray, length, sampleSizes.baseAddress, &rawSample) == noErr else {
                        return nil
                    }
                    return rawSample
                }

                if timings.count == 1 {
                    var uniformTimingForRange = advanced(timings[0], by: location)
                    return unsafe createReady(1, &uniformTimingForRange)
                }
                let rangeTimings = timings.extracting(location..<(location &+ length))
                return rangeTimings.withUnsafeBufferPointer { unsafe createReady(rangeTimings.count, $0.baseAddress) }
            }
        }
    }
}

/// `WebCore::copySampleBufferForRange`: the result is +1, or nil.
@_cdecl("WebCoreCMCopySampleBufferForRange")
internal func webCoreCMCopySampleBufferForRange(_ sampleBuffer: CMSampleBuffer?, _ location: CFIndex, _ length: CFIndex) -> Unmanaged<CMSampleBuffer>? {
    var copy: CMSampleBuffer?
    if !sampleBufferHasNoSampleSizes(sampleBuffer) {
        guard unsafe PAL.softLink_CoreMedia_CMSampleBufferCopySampleBufferForRange(kCFAllocatorDefault, sampleBuffer, CFRange(location: location, length: length), &copy) == noErr else {
            return nil
        }
    } else {
        copy = copyPacketDescribedRange(sampleBuffer, location, length)
    }
    guard let copy else {
        return nil
    }
    // SAFETY: the caller adopts the result, so it receives one retain of its own.
    return unsafe Unmanaged.passRetained(copy)
}

// MARK: - Colour space

/// The CoreVideo and CoreMedia constants the colour-space tables use, read in one expression so
/// the Unmanaged-to-managed claim is made once for all of them.
private struct CMColorConstants {
    let cgColorSpaceKey: CFString?
    let colorPrimariesKey: CFString?
    let transferFunctionKey: CFString?
    let gammaLevelKey: CFString?
    let yCbCrMatrixKey: CFString?
    let chromaLocationTopFieldKey: CFString?
    let chromaLocationBottomFieldKey: CFString?
    let fieldCountKey: CFString?
    let fieldDetailKey: CFString?
    let fullRangeVideoKey: CFString?

    let colorPrimaries_ITU_R_709_2: CFString?
    let colorPrimaries_EBU_3213: CFString?
    let colorPrimaries_P22: CFString?
    let colorPrimaries_SMPTE_C: CFString?
    let colorPrimaries_DCI_P3: CFString?
    let colorPrimaries_P3_D65: CFString?
    let colorPrimaries_ITU_R_2020: CFString?

    let transferFunction_ITU_R_709_2: CFString?
    let transferFunction_SMPTE_240M_1995: CFString?
    let transferFunction_UseGamma: CFString?
    let transferFunction_SMPTE_ST_2084_PQ: CFString?
    let transferFunction_ITU_R_2020: CFString?
    let transferFunction_SMPTE_ST_428_1: CFString?
    let transferFunction_ITU_R_2100_HLG: CFString?
    let transferFunction_sRGB: CFString?
    let transferFunction_Linear: CFString?

    let yCbCrMatrix_ITU_R_2020: CFString?
    let yCbCrMatrix_ITU_R_601_4: CFString?
    let yCbCrMatrix_ITU_R_709_2: CFString?
    let yCbCrMatrix_SMPTE_240M_1995: CFString?

    let chromaLocation_Left: CFString?
    let chromaLocation_Center: CFString?
    let chromaLocation_TopLeft: CFString?
    let chromaLocation_Top: CFString?
    let chromaLocation_BottomLeft: CFString?
    let chromaLocation_Bottom: CFString?
    let chromaLocation_DV420: CFString?

    let fieldDetailTemporalTopFirst: CFString?
    let fieldDetailTemporalBottomFirst: CFString?
    let fieldDetailSpatialFirstLineEarly: CFString?
    let fieldDetailSpatialFirstLineLate: CFString?

    static func load() -> CMColorConstants {
        // SAFETY: each get_*Singleton() returns a +0 reference to an immutable CFString constant
        // exported by CoreVideo or CoreMedia, which stays loaded for the life of the process, so
        // takeUnretainedValue() yields a live object that the managed reference then retains.
        // Not provable today because SOFT_LINK_CONSTANT_FOR_HEADER declares the getters outside
        // any CF-audited region and without CF_RETURNS_NOT_RETAINED, so Swift imports their
        // CFStringRef results as Unmanaged and cannot know the +0 convention.
        unsafe CMColorConstants(
            cgColorSpaceKey: WebCore_Private.WebCore.get_CoreVideo_kCVImageBufferCGColorSpaceKeySingleton()?.takeUnretainedValue(),
            colorPrimariesKey: WebCore_Private.WebCore.get_CoreVideo_kCVImageBufferColorPrimariesKeySingleton()?.takeUnretainedValue(),
            transferFunctionKey: WebCore_Private.WebCore.get_CoreVideo_kCVImageBufferTransferFunctionKeySingleton()?.takeUnretainedValue(),
            gammaLevelKey: WebCore_Private.WebCore.get_CoreVideo_kCVImageBufferGammaLevelKeySingleton()?.takeUnretainedValue(),
            yCbCrMatrixKey: WebCore_Private.WebCore.get_CoreVideo_kCVImageBufferYCbCrMatrixKeySingleton()?.takeUnretainedValue(),
            chromaLocationTopFieldKey: WebCore_Private.WebCore.get_CoreVideo_kCVImageBufferChromaLocationTopFieldKeySingleton()?.takeUnretainedValue(),
            chromaLocationBottomFieldKey: WebCore_Private.WebCore.get_CoreVideo_kCVImageBufferChromaLocationBottomFieldKeySingleton()?.takeUnretainedValue(),
            fieldCountKey: WebCore_Private.WebCore.get_CoreVideo_kCVImageBufferFieldCountKeySingleton()?.takeUnretainedValue(),
            fieldDetailKey: WebCore_Private.WebCore.get_CoreVideo_kCVImageBufferFieldDetailKeySingleton()?.takeUnretainedValue(),
            fullRangeVideoKey: PAL.get_CoreMedia_kCMFormatDescriptionExtension_FullRangeVideoSingleton()?.takeUnretainedValue(),
            colorPrimaries_ITU_R_709_2: WebCore_Private.WebCore.get_CoreVideo_kCVImageBufferColorPrimaries_ITU_R_709_2Singleton()?.takeUnretainedValue(),
            colorPrimaries_EBU_3213: WebCore_Private.WebCore.get_CoreVideo_kCVImageBufferColorPrimaries_EBU_3213Singleton()?.takeUnretainedValue(),
            colorPrimaries_P22: WebCore_Private.WebCore.get_CoreVideo_kCVImageBufferColorPrimaries_P22Singleton()?.takeUnretainedValue(),
            colorPrimaries_SMPTE_C: WebCore_Private.WebCore.get_CoreVideo_kCVImageBufferColorPrimaries_SMPTE_CSingleton()?.takeUnretainedValue(),
            colorPrimaries_DCI_P3: PAL.get_CoreMedia_kCMFormatDescriptionColorPrimaries_DCI_P3Singleton()?.takeUnretainedValue(),
            colorPrimaries_P3_D65: PAL.get_CoreMedia_kCMFormatDescriptionColorPrimaries_P3_D65Singleton()?.takeUnretainedValue(),
            colorPrimaries_ITU_R_2020: PAL.get_CoreMedia_kCMFormatDescriptionColorPrimaries_ITU_R_2020Singleton()?.takeUnretainedValue(),
            transferFunction_ITU_R_709_2: WebCore_Private.WebCore.get_CoreVideo_kCVImageBufferTransferFunction_ITU_R_709_2Singleton()?.takeUnretainedValue(),
            transferFunction_SMPTE_240M_1995: WebCore_Private.WebCore.get_CoreVideo_kCVImageBufferTransferFunction_SMPTE_240M_1995Singleton()?.takeUnretainedValue(),
            transferFunction_UseGamma: WebCore_Private.WebCore.get_CoreVideo_kCVImageBufferTransferFunction_UseGammaSingleton()?.takeUnretainedValue(),
            transferFunction_SMPTE_ST_2084_PQ: PAL.get_CoreMedia_kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQSingleton()?.takeUnretainedValue(),
            transferFunction_ITU_R_2020: PAL.get_CoreMedia_kCMFormatDescriptionTransferFunction_ITU_R_2020Singleton()?.takeUnretainedValue(),
            transferFunction_SMPTE_ST_428_1: PAL.get_CoreMedia_kCMFormatDescriptionTransferFunction_SMPTE_ST_428_1Singleton()?.takeUnretainedValue(),
            transferFunction_ITU_R_2100_HLG: PAL.get_CoreMedia_kCMFormatDescriptionTransferFunction_ITU_R_2100_HLGSingleton()?.takeUnretainedValue(),
            transferFunction_sRGB: PAL.get_CoreMedia_kCMFormatDescriptionTransferFunction_sRGBSingleton()?.takeUnretainedValue(),
            transferFunction_Linear: PAL.get_CoreMedia_kCMFormatDescriptionTransferFunction_LinearSingleton()?.takeUnretainedValue(),
            yCbCrMatrix_ITU_R_2020: PAL.get_CoreMedia_kCMFormatDescriptionYCbCrMatrix_ITU_R_2020Singleton()?.takeUnretainedValue(),
            yCbCrMatrix_ITU_R_601_4: WebCore_Private.WebCore.get_CoreVideo_kCVImageBufferYCbCrMatrix_ITU_R_601_4Singleton()?.takeUnretainedValue(),
            yCbCrMatrix_ITU_R_709_2: WebCore_Private.WebCore.get_CoreVideo_kCVImageBufferYCbCrMatrix_ITU_R_709_2Singleton()?.takeUnretainedValue(),
            yCbCrMatrix_SMPTE_240M_1995: WebCore_Private.WebCore.get_CoreVideo_kCVImageBufferYCbCrMatrix_SMPTE_240M_1995Singleton()?.takeUnretainedValue(),
            chromaLocation_Left: WebCore_Private.WebCore.get_CoreVideo_kCVImageBufferChromaLocation_LeftSingleton()?.takeUnretainedValue(),
            chromaLocation_Center: WebCore_Private.WebCore.get_CoreVideo_kCVImageBufferChromaLocation_CenterSingleton()?.takeUnretainedValue(),
            chromaLocation_TopLeft: WebCore_Private.WebCore.get_CoreVideo_kCVImageBufferChromaLocation_TopLeftSingleton()?.takeUnretainedValue(),
            chromaLocation_Top: WebCore_Private.WebCore.get_CoreVideo_kCVImageBufferChromaLocation_TopSingleton()?.takeUnretainedValue(),
            chromaLocation_BottomLeft: WebCore_Private.WebCore.get_CoreVideo_kCVImageBufferChromaLocation_BottomLeftSingleton()?.takeUnretainedValue(),
            chromaLocation_Bottom: WebCore_Private.WebCore.get_CoreVideo_kCVImageBufferChromaLocation_BottomSingleton()?.takeUnretainedValue(),
            chromaLocation_DV420: WebCore_Private.WebCore.get_CoreVideo_kCVImageBufferChromaLocation_DV420Singleton()?.takeUnretainedValue(),
            fieldDetailTemporalTopFirst: WebCore_Private.WebCore.get_CoreVideo_kCVImageBufferFieldDetailTemporalTopFirstSingleton()?.takeUnretainedValue(),
            fieldDetailTemporalBottomFirst: WebCore_Private.WebCore.get_CoreVideo_kCVImageBufferFieldDetailTemporalBottomFirstSingleton()?.takeUnretainedValue(),
            fieldDetailSpatialFirstLineEarly: WebCore_Private.WebCore.get_CoreVideo_kCVImageBufferFieldDetailSpatialFirstLineEarlySingleton()?.takeUnretainedValue(),
            fieldDetailSpatialFirstLineLate: WebCore_Private.WebCore.get_CoreVideo_kCVImageBufferFieldDetailSpatialFirstLineLateSingleton()?.takeUnretainedValue()
        )
    }
}

private typealias ColorPrimaries = WebCore_Private.WebCore.PlatformVideoColorPrimaries
private typealias TransferCharacteristics = WebCore_Private.WebCore.PlatformVideoTransferCharacteristics
private typealias MatrixCoefficients = WebCore_Private.WebCore.PlatformVideoMatrixCoefficients
private typealias ChromaLocation = WebCore_Private.WebCore.PlatformVideoChromaLocation
private typealias FieldDetail = WebCore_Private.WebCore.PlatformVideoFieldDetail
private typealias VideoColorSpace = WebCore_Private.WebCore.PlatformVideoColorSpace

private func convertToCMColorPrimaries(_ primaries: ColorPrimaries, _ constants: CMColorConstants) -> CFString? {
    switch primaries {
    case .Bt709:
        return constants.colorPrimaries_ITU_R_709_2
    case .JedecP22Phosphors:
        return constants.colorPrimaries_EBU_3213
    case .Smpte170m, .Smpte240m:
        return constants.colorPrimaries_SMPTE_C
    case .SmpteRp431:
        return constants.colorPrimaries_DCI_P3
    case .SmpteEg432:
        return constants.colorPrimaries_P3_D65
    case .Bt2020:
        return constants.colorPrimaries_ITU_R_2020
    default:
        return nil
    }
}

private func convertToCMTransferFunction(_ characteristics: TransferCharacteristics, _ constants: CMColorConstants) -> CFString? {
    switch characteristics {
    case .Smpte170m, .Bt709:
        return constants.transferFunction_ITU_R_709_2
    case .Smpte240m:
        return constants.transferFunction_SMPTE_240M_1995
    case .SmpteSt2084:
        return constants.transferFunction_SMPTE_ST_2084_PQ
    case .Bt2020_10bit, .Bt2020_12bit:
        return constants.transferFunction_ITU_R_2020
    case .SmpteSt4281:
        return constants.transferFunction_SMPTE_ST_428_1
    case .AribStdB67Hlg:
        return constants.transferFunction_ITU_R_2100_HLG
    case .Iec6196621:
        return constants.transferFunction_sRGB
    case .Gamma22curve, .Gamma28curve:
        return constants.transferFunction_UseGamma
    case .Linear:
        return constants.transferFunction_Linear
    default:
        return nil
    }
}

private func convertToCMYCbCRMatrix(_ coefficients: MatrixCoefficients, _ constants: CMColorConstants) -> CFString? {
    switch coefficients {
    case .Bt2020NonconstantLuminance:
        return constants.yCbCrMatrix_ITU_R_2020
    case .Bt470bg, .Smpte170m:
        return constants.yCbCrMatrix_ITU_R_601_4
    case .Bt709:
        return constants.yCbCrMatrix_ITU_R_709_2
    case .Smpte240m:
        return constants.yCbCrMatrix_SMPTE_240M_1995
    default:
        return nil
    }
}

private func convertToCMChromaLocation(_ chromaLocation: ChromaLocation, _ constants: CMColorConstants) -> CFString? {
    switch chromaLocation {
    case .Left:
        return constants.chromaLocation_Left
    case .Center:
        return constants.chromaLocation_Center
    case .TopLeft:
        return constants.chromaLocation_TopLeft
    case .Top:
        return constants.chromaLocation_Top
    case .BottomLeft:
        return constants.chromaLocation_BottomLeft
    case .Bottom:
        return constants.chromaLocation_Bottom
    case .Dv420:
        return constants.chromaLocation_DV420
    default:
        return nil
    }
}

private func convertToCMFieldDetail(_ fieldDetail: FieldDetail, _ constants: CMColorConstants) -> CFString? {
    switch fieldDetail {
    case .TemporalTopFirst:
        return constants.fieldDetailTemporalTopFirst
    case .TemporalBottomFirst:
        return constants.fieldDetailTemporalBottomFirst
    case .SpatialFirstLineEarly:
        return constants.fieldDetailSpatialFirstLineEarly
    case .SpatialFirstLineLate:
        return constants.fieldDetailSpatialFirstLineLate
    default:
        return nil
    }
}

/// The gamma level CoreVideo pairs with UseGamma, or nil for any other transfer. `@(double)` makes a
/// kCFNumberDoubleType CFNumber, which NSNumber(value: Double) does not, so it is created directly.
private func gammaLevel(_ transfer: TransferCharacteristics) -> CFNumber? {
    var value: Double
    switch transfer {
    case .Gamma22curve:
        value = 2.2
    case .Gamma28curve:
        value = 2.8
    default:
        return nil
    }
    // SAFETY: CFNumberCreate reads one Double from the address, which is `value`, live for the call.
    return unsafe CFNumberCreate(nil, .doubleType, &value)
}

/// WTF's `safeCFEqual`: two nils are equal, and one nil equals nothing.
private func safeCFEqual(_ a: AnyObject?, _ b: CFString?) -> Bool {
    guard let a, let b else {
        return a == nil && b == nil
    }
    return CFEqual(a, b)
}

private func addValue(_ dictionary: CFMutableDictionary?, _ key: CFString?, _ value: AnyObject?) {
    // SAFETY: `key` and `value` are live objects, or nil, for the duration of the call, and the
    // dictionary retains what it stores under the kCFType callbacks CMUtilities creates it with.
    unsafe CFDictionaryAddValue(dictionary, unsafe key.map { unsafe Unmanaged.passUnretained($0).toOpaque() }, unsafe value.map { unsafe Unmanaged.passUnretained($0).toOpaque() })
}

private func setAttachment(_ buffer: CVBuffer, _ key: CFString?, _ value: AnyObject?) {
    WebCore_Private.WebCore.softLink_CoreVideo_CVBufferSetAttachment(buffer, key, value, .shouldPropagate)
}

private func attachment(_ buffer: CVBuffer, _ key: CFString?) -> AnyObject? {
    // SAFETY: CVBufferGetAttachment follows the CF Get rule: the result is +0 and owned by the
    // buffer's attachments, which the caller keeps alive and does not mutate across this call.
    // Not provable today because the soft-link wrapper carries no CF_RETURNS_NOT_RETAINED, so
    // Swift imports its CFTypeRef result as Unmanaged.
    unsafe WebCore_Private.WebCore.softLink_CoreVideo_CVBufferGetAttachment(buffer, key, nil)?.takeUnretainedValue()
}

/// The colour-space, field-count and field-detail extensions of a video format description.
/// `fieldCount` and `fieldDetail` are 0 for std::nullopt and the raw value plus one otherwise.
@_cdecl("WebCoreCMAddColorExtensions")
internal func webCoreCMAddColorExtensions(_ extensions: CFMutableDictionary?, _ rawColorSpace: UnsafeRawPointer, _ fieldCount: UInt16, _ fieldDetail: UInt16) {
    let constants = CMColorConstants.load()
    // SAFETY: the caller passes a live PlatformVideoColorSpace that nothing mutates during the call.
    let colorSpace = unsafe rawColorSpace.assumingMemoryBound(to: VideoColorSpace.self).pointee

    if colorSpace.fullRange.value ?? false {
        addValue(extensions, constants.fullRangeVideoKey, kCFBooleanTrue)
    }

    if let primaries = colorSpace.primaries.value, let cmColorPrimaries = convertToCMColorPrimaries(primaries, constants) {
        addValue(extensions, constants.colorPrimariesKey, cmColorPrimaries)
    }
    if let transfer = colorSpace.transfer.value {
        if let cmTransferFunction = convertToCMTransferFunction(transfer, constants) {
            addValue(extensions, constants.transferFunctionKey, cmTransferFunction)
        }
        if let gamma = gammaLevel(transfer) {
            addValue(extensions, constants.gammaLevelKey, gamma)
        }
    }

    if let matrix = colorSpace.matrix.value, let cmMatrix = convertToCMYCbCRMatrix(matrix, constants) {
        addValue(extensions, constants.yCbCrMatrixKey, cmMatrix)
    }

    if let chromaLocation = colorSpace.chromaLocation.value, let cmChromaLocation = convertToCMChromaLocation(chromaLocation, constants) {
        addValue(extensions, constants.chromaLocationTopFieldKey, cmChromaLocation)
        addValue(extensions, constants.chromaLocationBottomFieldKey, cmChromaLocation)
    }

    // Boxed as `@(uint8_t)` boxes it, so the CFNumber has the same type.
    if fieldCount != 0 {
        addValue(extensions, constants.fieldCountKey, NSNumber(value: UInt8(fieldCount - 1)))
    }

    if fieldDetail != 0, let detail = FieldDetail(rawValue: UInt8(fieldDetail - 1)), let cmFieldDetail = convertToCMFieldDetail(detail, constants) {
        addValue(extensions, constants.fieldDetailKey, cmFieldDetail)
    }
}

/// Replaces `pixelBuffer`'s CGColorSpace with the attachments for each engaged field of the
/// colour space. An engaged field with no CoreVideo name is attached as NULL.
@_cdecl("WebCoreCMAttachColorSpaceToPixelBuffer")
internal func webCoreCMAttachColorSpaceToPixelBuffer(_ rawColorSpace: UnsafeRawPointer, _ pixelBuffer: CVBuffer?) {
    guard let pixelBuffer else {
        return
    }
    let constants = CMColorConstants.load()
    // SAFETY: the caller passes a live PlatformVideoColorSpace that nothing mutates during the call.
    let colorSpace = unsafe rawColorSpace.assumingMemoryBound(to: VideoColorSpace.self).pointee

    WebCore_Private.WebCore.softLink_CoreVideo_CVBufferRemoveAttachment(pixelBuffer, constants.cgColorSpaceKey)
    if let primaries = colorSpace.primaries.value {
        setAttachment(pixelBuffer, constants.colorPrimariesKey, convertToCMColorPrimaries(primaries, constants))
    }
    if let transfer = colorSpace.transfer.value {
        setAttachment(pixelBuffer, constants.transferFunctionKey, convertToCMTransferFunction(transfer, constants))
        if let gamma = gammaLevel(transfer) {
            setAttachment(pixelBuffer, constants.gammaLevelKey, gamma)
        }
    }
    if let matrix = colorSpace.matrix.value {
        setAttachment(pixelBuffer, constants.yCbCrMatrixKey, convertToCMYCbCRMatrix(matrix, constants))
    }
    if let chromaLocation = colorSpace.chromaLocation.value, let cmChromaLocation = convertToCMChromaLocation(chromaLocation, constants) {
        setAttachment(pixelBuffer, constants.chromaLocationTopFieldKey, cmChromaLocation)
        setAttachment(pixelBuffer, constants.chromaLocationBottomFieldKey, cmChromaLocation)
    }
}

/// Writes the colour space `pixelBuffer`'s attachments describe into the caller's
/// default-constructed PlatformVideoColorSpace, which a nil buffer leaves untouched.
@_cdecl("WebCoreCMComputePixelBufferColorSpace")
internal func webCoreCMComputePixelBufferColorSpace(_ pixelBuffer: CVBuffer?, _ rawColorSpace: UnsafeMutableRawPointer) {
    guard let pixelBuffer else {
        return
    }
    let constants = CMColorConstants.load()
    var colorSpace = VideoColorSpace()

    let pixelPrimaries = attachment(pixelBuffer, constants.colorPrimariesKey)
    if safeCFEqual(pixelPrimaries, constants.colorPrimaries_ITU_R_709_2) {
        colorSpace.primaries = .init(.Bt709)
    } else if safeCFEqual(pixelPrimaries, constants.colorPrimaries_EBU_3213) {
        colorSpace.primaries = .init(.JedecP22Phosphors)
    } else if safeCFEqual(pixelPrimaries, constants.colorPrimaries_P22) {
        colorSpace.primaries = .init(.JedecP22Phosphors)
    } else if safeCFEqual(pixelPrimaries, constants.colorPrimaries_SMPTE_C) {
        colorSpace.primaries = .init(.Smpte170m)
    } else if safeCFEqual(pixelPrimaries, constants.colorPrimaries_DCI_P3) {
        colorSpace.primaries = .init(.SmpteRp431)
    } else if safeCFEqual(pixelPrimaries, constants.colorPrimaries_P3_D65) {
        colorSpace.primaries = .init(.SmpteEg432)
    } else if safeCFEqual(pixelPrimaries, constants.colorPrimaries_ITU_R_2020) {
        colorSpace.primaries = .init(.Bt2020)
    }

    let pixelTransfer = attachment(pixelBuffer, constants.transferFunctionKey)
    if safeCFEqual(pixelTransfer, constants.transferFunction_ITU_R_709_2) {
        colorSpace.transfer = .init(.Bt709)
    } else if safeCFEqual(pixelTransfer, constants.transferFunction_SMPTE_240M_1995) {
        colorSpace.transfer = .init(.Smpte240m)
    } else if safeCFEqual(pixelTransfer, constants.transferFunction_SMPTE_ST_2084_PQ) {
        colorSpace.transfer = .init(.SmpteSt2084)
    } else if safeCFEqual(pixelTransfer, constants.transferFunction_SMPTE_ST_428_1) {
        colorSpace.transfer = .init(.SmpteSt4281)
    } else if safeCFEqual(pixelTransfer, constants.transferFunction_ITU_R_2100_HLG) {
        colorSpace.transfer = .init(.AribStdB67Hlg)
    } else if safeCFEqual(pixelTransfer, constants.transferFunction_Linear) {
        colorSpace.transfer = .init(.Linear)
    } else if safeCFEqual(pixelTransfer, constants.transferFunction_sRGB) {
        colorSpace.transfer = .init(.Iec6196621)
    } else if safeCFEqual(pixelTransfer, constants.transferFunction_ITU_R_2020) {
        colorSpace.transfer = .init(.Bt2020_10bit)
    } else if safeCFEqual(pixelTransfer, constants.transferFunction_UseGamma) {
        // The gamma level is read as a CFNumber without a type check, and a failed
        // conversion leaves it 0, which takes the 2.2 curve.
        if let gammaLevel = attachment(pixelBuffer, constants.gammaLevelKey) {
            var gamma: Double = 0
            // SAFETY: `&gamma` is a live, exclusively accessed Double, and kCFNumberFloat64Type
            // writes exactly one Double.
            _ = unsafe CFNumberGetValue((gammaLevel as! CFNumber), .float64Type, &gamma)
            colorSpace.transfer = .init(gamma < 2.5 ? .Gamma22curve : .Gamma28curve)
        }
    }

    let pixelMatrix = attachment(pixelBuffer, constants.yCbCrMatrixKey)
    if safeCFEqual(pixelMatrix, constants.yCbCrMatrix_ITU_R_2020) {
        colorSpace.matrix = .init(.Bt2020NonconstantLuminance)
    } else if safeCFEqual(pixelMatrix, constants.yCbCrMatrix_ITU_R_709_2) {
        colorSpace.matrix = .init(.Bt709)
    } else if safeCFEqual(pixelMatrix, constants.yCbCrMatrix_SMPTE_240M_1995) {
        colorSpace.matrix = .init(.Smpte240m)
    } else if safeCFEqual(pixelMatrix, constants.yCbCrMatrix_ITU_R_601_4) {
        colorSpace.matrix = .init(.Bt470bg)
    }

    // Every format other than the two bi-planar video-range ones counts as full range. The cast
    // only renames the type: WebCore redeclares CVPixelBufferRef, so Swift imports two classes
    // for the one __CVBuffer, and a cast to a CF class never fails.
    let pixelFormat = WebCore_Private.WebCore.softLink_CoreVideo_CVPixelBufferGetPixelFormatType((pixelBuffer as! CVPixelBuffer))
    colorSpace.fullRange = .init(pixelFormat != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange && pixelFormat != kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)

    var pixelChromaLocation = attachment(pixelBuffer, constants.chromaLocationTopFieldKey)
    if pixelChromaLocation == nil {
        pixelChromaLocation = attachment(pixelBuffer, constants.chromaLocationBottomFieldKey)
    }
    if safeCFEqual(pixelChromaLocation, constants.chromaLocation_Left) {
        colorSpace.chromaLocation = .init(.Left)
    } else if safeCFEqual(pixelChromaLocation, constants.chromaLocation_Center) {
        colorSpace.chromaLocation = .init(.Center)
    } else if safeCFEqual(pixelChromaLocation, constants.chromaLocation_TopLeft) {
        colorSpace.chromaLocation = .init(.TopLeft)
    } else if safeCFEqual(pixelChromaLocation, constants.chromaLocation_Top) {
        colorSpace.chromaLocation = .init(.Top)
    } else if safeCFEqual(pixelChromaLocation, constants.chromaLocation_BottomLeft) {
        colorSpace.chromaLocation = .init(.BottomLeft)
    } else if safeCFEqual(pixelChromaLocation, constants.chromaLocation_Bottom) {
        colorSpace.chromaLocation = .init(.Bottom)
    } else if safeCFEqual(pixelChromaLocation, constants.chromaLocation_DV420) {
        colorSpace.chromaLocation = .init(.Dv420)
    }

    // SAFETY: the caller passes a live, exclusively owned PlatformVideoColorSpace, so one
    // assignment of a fully built value replaces it.
    unsafe rawColorSpace.assumingMemoryBound(to: VideoColorSpace.self).pointee = colorSpace
}

#endif // ENABLE_CM_UTILITIES_SWIFT
