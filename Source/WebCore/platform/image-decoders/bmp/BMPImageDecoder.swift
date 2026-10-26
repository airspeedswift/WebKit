/*
 * Copyright (c) 2008-2009 Google Inc. All rights reserved.
 * Copyright (C) 2026 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are
 * met:
 *
 *     * Redistributions of source code must retain the above copyright
 * notice, this list of conditions and the following disclaimer.
 *     * Redistributions in binary form must reproduce the above
 * copyright notice, this list of conditions and the following disclaimer
 * in the documentation and/or other materials provided with the
 * distribution.
 *     * Neither the name of Google Inc. nor the names of its
 * contributors may be used to endorse or promote products derived from
 * this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
 * "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
 * LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
 * A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
 * OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
 * SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
 * LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
 * DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
 * THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

// Swift port of BMPImageDecoder.cpp/.h: the orchestration around the Swift
// BMPImageReader (BMPImageReader.swift), on the Swift ScalableImageDecoder
// substrate (ImageFrameBuffer.swift, ScalableImageDecoderCore.swift).
// Platform-neutral: frames leave Swift as ImageDecoderFramePixels
// (graphics/ImageDecoding.swift). Imports nothing.
//
// Also the pieces ICOImageDecoder.swift shares with this file:
//  * BMPReaderHostFormat + BMPReaderSink: how a format lends its locked state
//    to a running BMPImageReader (C++: the reader's m_parent and m_buffer).
//  * BMPFamilyImageDecoder: ScalableImageDecoderCore plus the C++ subclass's
//    setData() override, which ScalableImageDecoderFormat has no hook for.
//
// Shape, and why:
//  * C++ BMPImageReader calls back into its parent (m_parent->size(),
//    setSize(), setFailed(), premultiplyAlpha()) and writes through m_buffer
//    into the parent's frame cache while it runs. Here the reader is a value
//    taken OUT of the format while it runs, and the decoder's whole state is
//    lent to it as the BMPPixelSink (BMPReaderSink), so every callback runs the
//    same virtual (Format.size/setSize/setFailed) at the same moment the C++
//    does. The C++ "setFailed() deletes the reader that is running" hazard
//    (BMPImageDecoder.h:51-54, ICOImageDecoder.h:56-59) cannot occur: the
//    reader is put back only if the decoder has not failed.
//  * The reader holds no data. C++ BMPImageReader::setData stores a pointer to
//    the SharedBuffer it was last given (BMPImageReader.h:68), and
//    BMPImageDecoder::setData gives it the new buffer only AFTER
//    ScalableImageDecoder::setData has run tryDecodeSize (BMPImageDecoder.cpp:
//    49-57), so the size probe inside setData reads the PREVIOUS data. That is
//    kept: `readerData` is exactly the reader's m_data.
//  * Availability: BMPImageReader and ICODirectory take Span<UInt8>. It is
//    taken from an ArraySlice of the decoder's [UInt8] (`data[...].span`, as
//    GIFImageDecoder.swift does): Array.span needs macOS/iOS 26 on Apple
//    platforms, ArraySlice.span does not (measured at arm64-apple-macos15.0 and
//    arm64_32-apple-watchos11.0), so no @available is needed.
//
// Locking: as ScalableImageDecoderCore, one Mutex over everything, including
// the setData override (C++ BMPImageDecoder::setData calls m_reader->setData
// after ScalableImageDecoder::setData has released m_lock).

#if ENABLE_IMAGE_DECODERS_SWIFT

// MARK: - A format whose frames are decoded by BMPImageReader

/// A ScalableImageDecoderFormat that runs BMPImageReaders into its frame cache.
protocol BMPReaderHostFormat: ScalableImageDecoderFormat {
    /// A throwaway value that stands in for the real format while the real
    /// state is lent to a running reader (see `runReader`). Never decoded with.
    static func placeholder() -> Self
}

/// The C++ subclass's `setData()` override (BMPImageDecoder.cpp:49-57,
/// ICOImageDecoder.cpp:56-70), called with the lock held. It must begin with
/// `if state.failed { return }` and call `state.setData` (the base body), as
/// the C++ overrides do.
protocol BMPFamilyFormat: BMPReaderHostFormat {
    static func setData(_ state: inout ScalableImageDecoderState<Self>, _ data: [UInt8], allDataReceived: Bool)
}

/// BMPImageReader's view of its parent decoder and of the frame it decodes
/// into (C++ `m_parent`, `m_buffer` = &m_frameBufferCache[frameIndex]). Owns
/// the decoder's state for the duration of one decodeBMP() call.
struct BMPReaderSink<Format: BMPReaderHostFormat>: BMPPixelSink {
    var state: ScalableImageDecoderState<Format>
    /// Index of `m_buffer` in the frame cache.
    let frameIndex: Int

    /// m_parent->size(): the virtual, so ICO answers the directory entry's size
    /// while a BMP entry is being decoded (ICOImageDecoder.cpp:72-75).
    var size: BMPIntSize {
        let size = state.size()
        return BMPIntSize(width: size.width, height: size.height)
    }

    /// m_parent->setSize() (virtual: ScalableImageDecoder.h:116-123 for BMP,
    /// ICOImageDecoder.cpp:82-87 for ICO). A rejecting setSize has already
    /// called the format's setFailed().
    mutating func setSize(_ size: BMPIntSize) -> Bool {
        state.setSize(PixelSize(width: size.width, height: size.height))
    }

    var premultiplyAlpha: Bool { state.premultiplyAlpha }

    // m_buffer. The owners set the frame index only to an existing cache entry
    // before a decode that can reach the frame (C++ ASSERT(m_buffer),
    // BMPImageReader.cpp:85); an out-of-range index behaves as a frame that
    // cannot be allocated instead of trapping.
    private var hasFrame: Bool { frameIndex >= 0 && frameIndex < state.frameBufferCache.count }

    var frameIsInvalid: Bool { hasFrame ? state.frameBufferCache[frameIndex].isInvalid : true }

    mutating func initializeFrame(size: BMPIntSize, premultiplyAlpha: Bool) -> Bool {
        guard hasFrame else { return false }
        return state.frameBufferCache[frameIndex].initialize(size: PixelSize(width: size.width, height: size.height), premultiplyAlpha: premultiplyAlpha)
    }

    mutating func setStatusPartial() {
        guard hasFrame else { return }
        state.frameBufferCache[frameIndex].decodingStatus = .partial
    }

    mutating func setStatusComplete() {
        guard hasFrame else { return }
        state.frameBufferCache[frameIndex].decodingStatus = .complete
    }

    var hasAlpha: Bool {
        get { hasFrame ? state.frameBufferCache[frameIndex].hasAlpha : true }
        set {
            guard hasFrame else { return }
            state.frameBufferCache[frameIndex].setHasAlpha(newValue)
        }
    }

    // Coordinates: the reader only passes in-bounds pixels and rects of the
    // frame (BMPPixelSink contract), whose sides are < 65536
    // (BMPImageReader isInfoHeaderValid) or <= 256 (ICO entries), so
    // Int32(clamping:) is exact; it is used so that no conversion can trap.
    // An out-of-bounds pixel would still trap in ImageBackingStore.pixelIndex,
    // as the C++ hardened m_pixelsSpan[] does.
    mutating func setPixel(x: Int, y: Int, r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        guard hasFrame else { return }
        state.frameBufferCache[frameIndex].withBackingStore { store in
            store.setPixel(x: Int32(clamping: x), y: Int32(clamping: y), r: r, g: g, b: b, a: a)
        }
    }

    mutating func fillRect(x: Int, y: Int, width: Int, height: Int, r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        guard hasFrame else { return }
        let rect = PixelRect(x: Int32(clamping: x), y: Int32(clamping: y), width: Int32(clamping: width), height: Int32(clamping: height))
        state.frameBufferCache[frameIndex].withBackingStore { store in
            store.fillRect(rect, r: r, g: g, b: b, a: a)
        }
    }

    mutating func clearAll() {
        guard hasFrame else { return }
        state.frameBufferCache[frameIndex].withBackingStore { store in
            store.clear()
        }
    }
}

extension ScalableImageDecoderState where Format: BMPReaderHostFormat {
    /// `m_reader->decodeBMP(onlySize)` with `m_reader->setBuffer(&m_frameBufferCache[frameIndex])`.
    ///
    /// The caller has taken `reader` out of the format, so the reader cannot be
    /// destroyed or aliased while it runs; the whole state is moved into the
    /// sink (a placeholder sits in its place, under the same lock, and is
    /// discarded) and moved back afterwards. Returns the C++ bool:
    /// `.failed` is C++ `return m_parent->setFailed()`, run here once the reader
    /// has returned (the reader never touches the sink after deciding to fail);
    /// `.sizeRejected` means the virtual setSize already failed the decoder.
    mutating func runReader(_ reader: inout BMPImageReader, data: Span<UInt8>, onlySize: Bool, frameIndex: Int) -> Bool {
        var sink = BMPReaderSink(
            state: ScalableImageDecoderState(format: Format.placeholder(), premultiplyAlpha: premultiplyAlpha,
                ignoreGammaAndColorProfile: ignoreGammaAndColorProfile, cairoMaxImageSize: cairoMaxImageSize),
            frameIndex: frameIndex)
        swap(&self, &sink.state)
        let result = reader.decodeBMP(data, onlySize: onlySize, sink: &sink)
        swap(&self, &sink.state)
        switch result {
        case .success:
            return true
        case .insufficientData, .sizeRejected:
            return false
        case .failed:
            return setFailed()
        }
    }
}

// MARK: - ScalableImageDecoderCore plus the setData override

/// ScalableImageDecoderCore<Format> whose setData() is the format's override.
///
/// Every member forwards to the core, except setData, which runs
/// Format.setData under the core's lock. (ScalableImageDecoderFormat has no
/// setData hook; with one, this class would be the core itself. See the P3-B
/// report for the diff.)
final class BMPFamilyImageDecoder<Format: BMPFamilyFormat>: Sendable {
    let core: ScalableImageDecoderCore<Format>

    init(format: sending Format, alphaOption: AlphaOption, gammaAndColorProfileOption: GammaAndColorProfileOption, cairoMaxImageSize: Int32? = nil) {
        core = ScalableImageDecoderCore(format: format, alphaOption: alphaOption, gammaAndColorProfileOption: gammaAndColorProfileOption, cairoMaxImageSize: cairoMaxImageSize)
    }

    var premultiplyAlpha: Bool { core.premultiplyAlpha }
    func setIgnoreGammaAndColorProfile(_ flag: Bool) { core.setIgnoreGammaAndColorProfile(flag) }
    var ignoresGammaAndColorProfile: Bool { core.ignoresGammaAndColorProfile }
    var failed: Bool { core.failed }
}

extension BMPFamilyImageDecoder: PixelBufferImageDecoding {
    func bytesDecodedToDetermineProperties() -> Int { core.bytesDecodedToDetermineProperties() }
    func encodedDataStatus() -> EncodedDataStatus { core.encodedDataStatus() }
    func isSizeAvailable() -> Bool { core.isSizeAvailable() }
    func size() -> PixelSize { core.size() }
    func frameCount() -> Int { core.frameCount() }
    func repetitionCount() -> Int32 { core.repetitionCount() }
    func filenameExtension() -> String { core.filenameExtension() }
    func hotSpot() -> PixelPoint? { core.hotSpot() }
    func frameSize(at index: Int, subsampling: SubsamplingLevel) -> PixelSize { core.frameSize(at: index, subsampling: subsampling) }
    func frameIsComplete(at index: Int) -> Bool { core.frameIsComplete(at: index) }
    func frameHasAlpha(at index: Int) -> Bool { core.frameHasAlpha(at: index) }
    func frameDuration(at index: Int) -> Double { core.frameDuration(at: index) }
    func frameOrientation(at index: Int) -> ImageOrientation { core.frameOrientation(at: index) }
    func frameDensityCorrectedSize(at index: Int) -> PixelSize? { core.frameDensityCorrectedSize(at: index) }

    func createFramePixels(at index: Int, subsampling: SubsamplingLevel, options: DecodingOptions) -> ImageDecoderFramePixels? {
        core.createFramePixels(at: index, subsampling: subsampling, options: options)
    }

    func fetchFrameMetadata(at index: Int, subsampling: SubsamplingLevel, options: DecodingOptions) -> ImageFrameMetadata? {
        core.fetchFrameMetadata(at: index, subsampling: subsampling, options: options)
    }

    /// The format's setData override, under the lock.
    func setData(_ data: [UInt8], allDataReceived: Bool) {
        core.withLockedState { state in
            Format.setData(&state, data, allDataReceived: allDataReceived)
        }
    }

    func isAllDataReceived() -> Bool { core.isAllDataReceived() }
    func clearFrameBufferCache(_ index: Int) { core.clearFrameBufferCache(index) }
}

// MARK: - BMPImageDecoder

/// BMPImageDecoder's members (BMPImageDecoder.h:67-82) and virtual overrides.
struct BMPImageDecoderFormat: BMPFamilyFormat {
    /// Number of bytes in .BMP used to store the file header
    /// (BMPImageDecoder.cpp:41).
    static let sizeOfFileHeader = 14

    /// m_decodedOffset: how much of the data this class has decoded (only the
    /// file header; the reader tracks the rest).
    private(set) var decodedOffset = 0
    /// m_reader.
    private(set) var reader: BMPImageReader?
    /// The reader's m_data (BMPImageReader::setData, BMPImageReader.h:68).
    private(set) var readerData: [UInt8] = []

    init() { }

    static func placeholder() -> Self { Self() }

    /// BMPImageDecoder.h:43.
    static var filenameExtension: String { "bmp" }

    /// BMPImageDecoder.h:58.
    static func tryDecodeSize(_ state: inout ScalableImageDecoderState<Self>, allDataReceived: Bool) {
        decode(&state, onlySize: true, allDataReceived: allDataReceived)
    }

    /// BMPImageDecoder::setData (BMPImageDecoder.cpp:49-57).
    static func setData(_ state: inout ScalableImageDecoderState<Self>, _ data: [UInt8], allDataReceived: Bool) {
        if state.failed {
            return
        }

        state.setData(data, allDataReceived: allDataReceived)
        if state.format.reader != nil {
            state.format.readerData = state.data
        }
    }

    /// BMPImageDecoder::frameBufferAtIndex (BMPImageDecoder.cpp:59-72).
    static func frameBufferAtIndex(_ state: inout ScalableImageDecoderState<Self>, _ index: Int) -> Int? {
        if index != 0 {
            return nil
        }

        if state.frameBufferCache.isEmpty {
            state.frameBufferCache.append(ScalableImageDecoderFrame())
        }

        if !state.frameBufferCache[0].isComplete {
            decode(&state, onlySize: false, allDataReceived: state.isAllDataReceived)
        }
        return 0
    }

    /// BMPImageDecoder::setFailed (BMPImageDecoder.cpp:74-78).
    static func setFailed(_ state: inout ScalableImageDecoderState<Self>) -> Bool {
        state.format.reader = nil
        state.format.readerData = []
        return state.baseSetFailed()
    }

    /// BMPImageDecoder::decode (BMPImageDecoder.cpp:80-94).
    private static func decode(_ state: inout ScalableImageDecoderState<Self>, onlySize: Bool, allDataReceived: Bool) {
        if state.failed {
            return
        }

        // If we couldn't decode the image but we've received all the data, decoding
        // has failed.
        if !decodeHelper(&state, onlySize: onlySize) && allDataReceived {
            state.setFailed()
        } else if !state.frameBufferCache.isEmpty && state.frameBufferCache[0].isComplete {
            // If we're done decoding the image, we don't need the BMPImageReader
            // anymore. (If we failed, the reader has already been cleared.)
            state.format.reader = nil
            state.format.readerData = []
        }
    }

    /// BMPImageDecoder::decodeHelper (BMPImageDecoder.cpp:96-112).
    private static func decodeHelper(_ state: inout ScalableImageDecoderState<Self>, onlySize: Bool) -> Bool {
        var imgDataOffset = 0
        if state.format.decodedOffset < sizeOfFileHeader {
            // processFileHeader (BMPImageDecoder.cpp:114-142).
            let data = state.data[...]
            switch BMPImageReader.bmpFileHeader(data.span) {
            case .needMoreData:
                return false
            case .notBMP:
                state.format.decodedOffset = sizeOfFileHeader
                return state.setFailed()
            case .ok(let offset):
                imgDataOffset = offset
                state.format.decodedOffset = sizeOfFileHeader
            }
        }

        if state.format.reader == nil {
            state.format.reader = BMPImageReader(decodedAndHeaderOffset: state.format.decodedOffset, imgDataOffset: imgDataOffset, usesAndMask: false)
            state.format.readerData = state.data
        }

        // The reader's m_buffer is &m_frameBufferCache.first() once the cache
        // has a frame (the C++ sets it only then; with an empty cache only a
        // size-only decode runs, which never reaches the frame).
        guard var reader = state.format.reader else {
            return false
        }
        state.format.reader = nil
        let data = state.format.readerData[...]
        let result = state.runReader(&reader, data: data.span, onlySize: onlySize, frameIndex: 0)
        if !state.failed {
            state.format.reader = reader
        }
        return result
    }
}

typealias BMPImageDecoder = BMPFamilyImageDecoder<BMPImageDecoderFormat>

extension BMPFamilyImageDecoder where Format == BMPImageDecoderFormat {
    /// BMPImageDecoder::create (BMPImageDecoder.h:38-41). `cairoMaxImageSize`
    /// is ImageBackingStore::cairoMaxImageSize on USE(CAIRO) builds, else nil.
    static func create(alphaOption: AlphaOption, gammaAndColorProfileOption: GammaAndColorProfileOption, cairoMaxImageSize: Int32? = nil) -> BMPImageDecoder {
        BMPImageDecoder(format: BMPImageDecoderFormat(), alphaOption: alphaOption, gammaAndColorProfileOption: gammaAndColorProfileOption, cairoMaxImageSize: cairoMaxImageSize)
    }
}

#endif // ENABLE_IMAGE_DECODERS_SWIFT
