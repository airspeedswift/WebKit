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
// sizes live only in their audio stream packet descriptions. Reached from C++ through @_cdecl;
// every CoreMedia function goes through its PAL soft-link accessor.

#if ENABLE_CM_UTILITIES_SWIFT

internal import CoreFoundation
internal import CoreMedia
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

#endif // ENABLE_CM_UTILITIES_SWIFT
