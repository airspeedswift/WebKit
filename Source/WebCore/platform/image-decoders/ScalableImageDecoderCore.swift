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

// PROTOTYPE: Swift port of the WebCore::ScalableImageDecoder base class
// (image-decoders/ScalableImageDecoder.{h,cpp}: the status machine, setSize,
// the frame cache queries) as a Mutex-guarded Sendable core conforming to
// ImageDecoding. Not yet in WebCore.xcodeproj.
//
// Shape, and why:
//  * C++ subclasses (GIF/BMP/ICO/JPEG/PNG/WebP decoders) override virtuals and
//    reach the base's protected members. Here a format is a value type
//    conforming to `ScalableImageDecoderFormat`, stored INSIDE the locked
//    `ScalableImageDecoderState`; each C++ virtual is a static requirement
//    taking that state `inout` (a virtual call with an explicit `this`).
//    The protocol extension supplies the base-class bodies, so a format
//    overrides exactly what its C++ class overrides.
//  * The whole state (base members, frame cache, format/reader state) sits
//    behind one Mutex, and every entry point, including encodedDataStatus(),
//    isAllDataReceived(), size() and setSize/setFailed reached from a decode,
//    runs under it. C++ reads m_encodedDataStatus and m_size without m_lock
//    and setData() writes them under it; here there is no unlocked access to
//    any member. Hooks run with the lock held and must not call back into the
//    core (Mutex is not recursive, like WTF::Lock).
//  * Frame pixels are Swift-owned (ImageFrameBuffer.swift) and leave Swift as
//    pixels: the core conforms to PixelBufferImageDecoding, and
//    createFramePixels returns a snapshot of the frame's ImageBackingStore as
//    ImageDecoderFramePixels. No native image is created in Swift on any port;
//    the C++ adapter calls the port's existing ImageBackingStore::image()
//    (cg/ImageBackingStoreCG.cpp:37-56, skia/ImageBackingStoreSkia.cpp:36-44,
//    cairo/ImageBackingStoreCairo.cpp:34-47). This file imports only
//    Synchronization, so it builds for GTK/WPE without CoreGraphics/Foundation.

#if ENABLE_IMAGE_DECODERS_SWIFT

import Synchronization

// MARK: - The virtuals a format overrides

/// `SendableMetatype`: the static requirements run inside Mutex.withLock on any
/// thread, so a conformance must not be actor-isolated (SE-0470).
protocol ScalableImageDecoderFormat: SendableMetatype {
    /// ImageDecoder::filenameExtension (pure; every subclass overrides).
    static var filenameExtension: String { get }

    /// ScalableImageDecoder::tryDecodeSize (pure, private virtual).
    static func tryDecodeSize(_ state: inout ScalableImageDecoderState<Self>, allDataReceived: Bool)

    /// ScalableImageDecoder::frameBufferAtIndex (pure). Returns the index of
    /// the decoded frame in `state.frameBufferCache` (C++ returns a pointer
    /// into it), or nil for nullptr.
    static func frameBufferAtIndex(_ state: inout ScalableImageDecoderState<Self>, _ index: Int) -> Int?

    // Virtuals with a base-class body (the protocol extension).
    static func decodeIfNeededAndGetFrameCount(_ state: inout ScalableImageDecoderState<Self>) -> Int
    static func clearDecodedPixelDataIfNeeded(_ state: inout ScalableImageDecoderState<Self>, _ index: Int)
    static func setSize(_ state: inout ScalableImageDecoderState<Self>, _ size: PixelSize) -> Bool
    static func setFailed(_ state: inout ScalableImageDecoderState<Self>) -> Bool
    static func size(_ state: ScalableImageDecoderState<Self>) -> PixelSize
    static func frameSize(_ state: inout ScalableImageDecoderState<Self>, at index: Int, subsampling: SubsamplingLevel) -> PixelSize
    static func repetitionCount(_ state: inout ScalableImageDecoderState<Self>) -> Int32
    static func hotSpot(_ state: inout ScalableImageDecoderState<Self>) -> PixelPoint?
}

extension ScalableImageDecoderFormat {
    /// ScalableImageDecoder.h:177.
    static func decodeIfNeededAndGetFrameCount(_ state: inout ScalableImageDecoderState<Self>) -> Int { 1 }
    /// ScalableImageDecoder.h:182.
    static func clearDecodedPixelDataIfNeeded(_ state: inout ScalableImageDecoderState<Self>, _ index: Int) { }
    static func setSize(_ state: inout ScalableImageDecoderState<Self>, _ size: PixelSize) -> Bool { state.baseSetSize(size) }
    static func setFailed(_ state: inout ScalableImageDecoderState<Self>) -> Bool { state.baseSetFailed() }
    static func size(_ state: ScalableImageDecoderState<Self>) -> PixelSize { state.baseSize() }
    /// ScalableImageDecoder.h:109-112.
    static func frameSize(_ state: inout ScalableImageDecoderState<Self>, at index: Int, subsampling: SubsamplingLevel) -> PixelSize { state.size() }
    /// ScalableImageDecoder.h:127.
    static func repetitionCount(_ state: inout ScalableImageDecoderState<Self>) -> Int32 { RepetitionCount.none }
    /// ScalableImageDecoder.h:166.
    static func hotSpot(_ state: inout ScalableImageDecoderState<Self>) -> PixelPoint? { nil }
}

// MARK: - The base-class members

/// ScalableImageDecoder's data members plus the format's own state. Only ever
/// reached through ScalableImageDecoderCore's Mutex.
struct ScalableImageDecoderState<Format: ScalableImageDecoderFormat> {
    var format: Format

    /// m_data (the contiguous copy setData makes).
    var data: [UInt8] = []
    var frameBufferCache: [ScalableImageDecoderFrame] = []
    let premultiplyAlpha: Bool
    var ignoreGammaAndColorProfile: Bool
    var orientation: ImageOrientation = .none
    var densityCorrectedSize: PixelSize?
    /// ImageBackingStore.h:39-43: 32768 when built USE(CAIRO), otherwise nil.
    let cairoMaxImageSize: Int32?

    // Private in ScalableImageDecoder.h:195-197.
    fileprivate(set) var sizeStorage = PixelSize(width: 0, height: 0)
    fileprivate(set) var encodedDataStatus: EncodedDataStatus = .typeAvailable
    fileprivate(set) var decodingSizeFromSetData = false

    init(format: Format, premultiplyAlpha: Bool, ignoreGammaAndColorProfile: Bool, cairoMaxImageSize: Int32?) {
        self.format = format
        self.premultiplyAlpha = premultiplyAlpha
        self.ignoreGammaAndColorProfile = ignoreGammaAndColorProfile
        self.cairoMaxImageSize = cairoMaxImageSize
    }

    // Virtual dispatch.
    mutating func setSize(_ size: PixelSize) -> Bool { Format.setSize(&self, size) }
    @discardableResult
    mutating func setFailed() -> Bool { Format.setFailed(&self) }
    func size() -> PixelSize { Format.size(self) }

    /// ScalableImageDecoder::setSize (ScalableImageDecoder.h:116-123).
    mutating func baseSetSize(_ size: PixelSize) -> Bool {
        if ImageBackingStore.isOverSize(size, cairoMaxImageSize: cairoMaxImageSize) {
            return setFailed()
        }
        sizeStorage = size
        encodedDataStatus = .sizeAvailable
        return true
    }

    /// ScalableImageDecoder::setFailed (ScalableImageDecoder.h:154-158).
    mutating func baseSetFailed() -> Bool {
        encodedDataStatus = .error
        return false
    }

    /// ScalableImageDecoder.h:160.
    var failed: Bool { encodedDataStatus == .error }

    /// ScalableImageDecoder.h:100.
    var isSizeAvailable: Bool { encodedDataStatus.rawValue >= EncodedDataStatus.sizeAvailable.rawValue }

    /// ScalableImageDecoder::size (ScalableImageDecoder.h:102).
    func baseSize() -> PixelSize { isSizeAvailable ? sizeStorage : PixelSize(width: 0, height: 0) }

    /// ScalableImageDecoder::isAllDataReceived (ScalableImageDecoder.h:69-73).
    var isAllDataReceived: Bool {
        precondition(!decodingSizeFromSetData)
        return encodedDataStatus == .complete
    }

    /// ScalableImageDecoder::setData (ScalableImageDecoder.h:75-96), minus the
    /// lock, which the caller holds.
    mutating func setData(_ newData: [UInt8], allDataReceived: Bool) {
        if encodedDataStatus == .error {
            return
        }

        data = newData

        if encodedDataStatus == .typeAvailable {
            decodingSizeFromSetData = true
            Format.tryDecodeSize(&self, allDataReceived: allDataReceived)
            decodingSizeFromSetData = false
        }

        if encodedDataStatus == .error {
            return
        }

        if allDataReceived {
            // C++ ASSERT(m_encodedDataStatus == EncodedDataStatus::SizeAvailable)
            // is debug-only; the release behaviour (Complete regardless) is kept.
            encodedDataStatus = .complete
        }
    }

    /// ScalableImageDecoder::frameIsCompleteAtIndex (ScalableImageDecoder.cpp:180-188).
    func frameIsComplete(at index: Int) -> Bool {
        guard index >= 0, index < frameBufferCache.count else { return false }
        return frameBufferCache[index].isComplete
    }

    /// ScalableImageDecoder::frameHasAlphaAtIndex (ScalableImageDecoder.cpp:190-200).
    func frameHasAlpha(at index: Int) -> Bool {
        guard index >= 0, index < frameBufferCache.count else { return true }
        let frame = frameBufferCache[index]
        if !frame.isComplete {
            return true
        }
        return frame.hasAlpha
    }

    /// ScalableImageDecoder::frameDurationAtIndex (ScalableImageDecoder.cpp:202-220), in seconds.
    func frameDuration(at index: Int) -> Double {
        guard index >= 0, index < frameBufferCache.count else { return 0 }
        let frame = frameBufferCache[index]
        if !frame.isComplete {
            return 0
        }
        // Many annoying ads specify a 0 duration to make an image flash as quickly as possible.
        // We follow Firefox's behavior and use a duration of 100 ms for any frames that specify
        // a duration of <= 10 ms. See <rdar://problem/7689300> and <http://webkit.org/b/36082>
        // for more information.
        let duration = frame.duration
        if duration < 11.0 / 1000 { // 11_ms == Seconds::fromMilliseconds(11)
            return 100.0 / 1000 // 100_ms
        }
        return duration
    }

    /// ScalableImageDecoder::createFrameImageAtIndex (ScalableImageDecoder.cpp:222-236),
    /// minus the lock. Returns the index of a frame with a backing store.
    mutating func frameForImage(at index: Int) -> Int? {
        // Zero-height images can cause problems for some ports. If we have an empty image dimension, just bail.
        if size().isEmpty {
            return nil
        }
        guard let bufferIndex = Format.frameBufferAtIndex(&self, index) else { return nil }
        let buffer = frameBufferCache[bufferIndex]
        if buffer.isInvalid || !buffer.hasBackingStore {
            return nil
        }
        return bufferIndex
    }
}

// MARK: - The decoder

/// WebCore::ScalableImageDecoder with a concrete format inside.
final class ScalableImageDecoderCore<Format: ScalableImageDecoderFormat>: Sendable {
    private let state: Mutex<ScalableImageDecoderState<Format>>

    /// ScalableImageDecoder(AlphaOption, GammaAndColorProfileOption) (ScalableImageDecoder.h:51-55).
    init(format: sending Format, alphaOption: AlphaOption, gammaAndColorProfileOption: GammaAndColorProfileOption, cairoMaxImageSize: Int32? = nil) {
        state = Mutex(ScalableImageDecoderState(
            format: format,
            premultiplyAlpha: alphaOption == .premultiplied,
            ignoreGammaAndColorProfile: gammaAndColorProfileOption == .ignored,
            cairoMaxImageSize: cairoMaxImageSize))
    }

    /// Runs `body` with the lock held: what a C++ member function with
    /// `Locker locker { m_lock }` does.
    func withLockedState<Result: Sendable>(_ body: (inout ScalableImageDecoderState<Format>) -> Result) -> Result {
        state.withLock { body(&$0) }
    }

    var premultiplyAlpha: Bool { state.withLock { $0.premultiplyAlpha } }
    func setIgnoreGammaAndColorProfile(_ flag: Bool) { state.withLock { $0.ignoreGammaAndColorProfile = flag } }
    var ignoresGammaAndColorProfile: Bool { state.withLock { $0.ignoreGammaAndColorProfile } }
    var failed: Bool { state.withLock { $0.failed } }
}

extension ScalableImageDecoderCore: PixelBufferImageDecoding {
    /// Frame indices are C++ size_t. A negative Int is what a size_t >= 2^63
    /// becomes through the bridge, so it is mapped to Int.max: beyond every
    /// frame, as in C++ (and never a negative subscript in a format's hook).
    private static func frameIndex(_ index: Int) -> Int { index < 0 ? Int.max : index }

    /// ScalableImageDecoder.h:146.
    func bytesDecodedToDetermineProperties() -> Int { 0 }
    func encodedDataStatus() -> EncodedDataStatus { state.withLock { $0.encodedDataStatus } }
    func isSizeAvailable() -> Bool { state.withLock { $0.isSizeAvailable } }
    func size() -> PixelSize { state.withLock { $0.size() } }
    func frameCount() -> Int { state.withLock { Format.decodeIfNeededAndGetFrameCount(&$0) } }
    func repetitionCount() -> Int32 { state.withLock { Format.repetitionCount(&$0) } }
    func filenameExtension() -> String { Format.filenameExtension }
    func hotSpot() -> PixelPoint? { state.withLock { Format.hotSpot(&$0) } }

    func frameSize(at index: Int, subsampling: SubsamplingLevel) -> PixelSize {
        state.withLock { Format.frameSize(&$0, at: Self.frameIndex(index), subsampling: subsampling) }
    }

    func frameIsComplete(at index: Int) -> Bool { state.withLock { $0.frameIsComplete(at: index) } }
    func frameHasAlpha(at index: Int) -> Bool { state.withLock { $0.frameHasAlpha(at: index) } }
    func frameDuration(at index: Int) -> Double { state.withLock { $0.frameDuration(at: index) } }

    /// ScalableImageDecoder.h:141-142 (final).
    func frameOrientation(at index: Int) -> ImageOrientation { state.withLock { $0.orientation } }
    func frameDensityCorrectedSize(at index: Int) -> PixelSize? { state.withLock { $0.densityCorrectedSize } }

    /// ScalableImageDecoder::createFrameImageAtIndex (ScalableImageDecoder.cpp:222-236)
    /// up to `buffer->backingStore()->image()`, which is the adapter's.
    ///
    /// Divergence: C++ image() wraps the live pixel buffer (the DataSegment is
    /// ref'd by the native image), so decoding that continues into the same
    /// frame after this call is visible through the image. This is a snapshot
    /// (copy-on-write of the [UInt32]; the adapter's copy into a new
    /// ImageBackingStore is a second, O(pixels) copy).
    func createFramePixels(at index: Int, subsampling: SubsamplingLevel, options: DecodingOptions) -> ImageDecoderFramePixels? {
        state.withLock { state -> ImageDecoderFramePixels? in
            guard let bufferIndex = state.frameForImage(at: Self.frameIndex(index)),
                  let store = state.frameBufferCache[bufferIndex].backingStore else { return nil }
            return store.framePixels
        }
    }

    /// ImageDecoder::fetchFrameMetaDataAtIndex (ImageDecoder.cpp; ScalableImageDecoder
    /// does not override it): the protocol default's values, read under ONE lock
    /// acquisition so the snapshot is consistent (C++ makes five separately
    /// locked virtual calls, which a concurrent setData can interleave).
    func fetchFrameMetadata(at index: Int, subsampling: SubsamplingLevel, options: DecodingOptions) -> ImageFrameMetadata? {
        let index = Self.frameIndex(index)
        return state.withLock { state -> ImageFrameMetadata? in
            ImageFrameMetadata(
                naturalSize: Format.frameSize(&state, at: index, subsampling: subsampling),
                density: nil,
                densityCorrectedSize: state.densityCorrectedSize,
                subsamplingLevel: subsampling,
                hasAlpha: state.frameHasAlpha(at: index),
                orientation: state.orientation,
                decodingStatus: state.frameIsComplete(at: index) ? .complete : .partial)
        }
    }

    func setData(_ data: [UInt8], allDataReceived: Bool) {
        state.withLock { $0.setData(data, allDataReceived: allDataReceived) }
    }

    func isAllDataReceived() -> Bool { state.withLock { $0.isAllDataReceived } }

    /// ScalableImageDecoder::clearFrameBufferCache (ScalableImageDecoder.cpp:244-248).
    func clearFrameBufferCache(_ index: Int) {
        state.withLock { Format.clearDecodedPixelDataIfNeeded(&$0, Self.frameIndex(index)) }
    }
}

// MARK: - ImageBackingStore -> the platform-neutral frame output

extension ImageBackingStore {
    /// The store as it crosses into C++: size, alpha mode and pixel words,
    /// exactly what every port's image() reads (m_size, m_premultiplyAlpha,
    /// m_pixelsSpan; m_frameRect is not used by any of them). Never nil for a
    /// constructed store: create()/setSize() establish the same invariant
    /// (pixelCount) that ImageDecoderFramePixels checks; nil would mean "no
    /// image", the C++ image()'s own failure result.
    ///
    /// The words are DEEP-copied into a fresh buffer (called under the core's
    /// lock), so the value that leaves the lock shares no storage with the
    /// frame cache. Returning `pixels` itself would hand out a copy-on-write
    /// reference to the buffer the decoder keeps writing; the later in-place
    /// write then depends on the reader's release being ordered before the
    /// writer's uniqueness check inside the Swift runtime, an ordering TSan
    /// cannot see (measured: 10 TSan reports in 300 sessions with the shared
    /// buffer, 0 with this copy).
    var framePixels: ImageDecoderFramePixels? {
        var words: [UInt32] = []
        words.reserveCapacity(pixels.count)
        words.append(contentsOf: pixels)
        return ImageDecoderFramePixels(width: size.width, height: size.height, premultiplyAlpha: premultiplyAlpha, pixels: words)
    }
}

#endif // ENABLE_IMAGE_DECODERS_SWIFT
