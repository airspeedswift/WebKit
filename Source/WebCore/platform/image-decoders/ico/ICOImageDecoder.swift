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

// Swift port of ICOImageDecoder.cpp/.h (ICO and CUR) on the Swift ICODirectory
// (directory parsing, ico/ICODirectory.swift), BMPImageReader
// (bmp/BMPImageReader.swift) and the ScalableImageDecoder substrate, through
// the BMP-family pieces in bmp/BMPImageDecoder.swift. Imports nothing.
//
//  * One BMPImageReader per directory entry, by index (m_bmpReaders), each run
//    with the entry's size as the parent's size() (m_frameSize) and failing the
//    decoder when the reader's size does not match the entry (setSize).
//  * PNG entries are decoded by C++ (PNGImageDecoder) through the
//    EmbeddedPNGDecoding hook. Everything that comes back through it is
//    treated as untrusted: the size is compared with the directory entry
//    exactly as ICOImageDecoder.cpp:216-219 does, and the frame is rebuilt
//    through ScalableImageDecoderFrame's own API from ImageDecoderFramePixels,
//    whose initializer checks pixels.count == width * height. A frame that
//    cannot be represented (DecodingStatus.decoding, an unallocatable size)
//    fails the decoder instead of trapping.
//  * Frame cache sizing (ICOImageDecoder.cpp:171-175): sized once, to the
//    number of directory entries, at the end of the first decode() call that
//    finds it empty, and never resized after that.
//  * The frames are ordered as ICODirectory orders the entries: a STABLE sort,
//    where the C++ std::sort leaves equal (area, bit count) entries in an
//    unspecified order. The two can differ only in which of such entries is
//    frame N (P1-C).
//
// Divergences, both only where the C++ itself faults:
//  * ICOImageDecoder::decode (ICOImageDecoder.cpp:166-169) clears
//    m_bmpReaders[index] and m_pngDecoders[index] when the frame is complete,
//    even when decodeAtIndex just failed the decoder (which emptied both
//    vectors) and not all data has arrived. That index is then out of bounds
//    (WTF::Vector crashes; reachable when an embedded PNG decoder fails after
//    completing its first frame). Here the clear is skipped when the arrays are
//    empty.
//  * setDataForPNGDecoderAtIndex (ICOImageDecoder.cpp:142-153) takes
//    `subspan(imageOffset)`, which is out of bounds if the data has shrunk
//    below the entry's offset since the PNG decoder was created (the C++ traps
//    or is UB). Here the PNG decoder is given empty data instead.

#if ENABLE_IMAGE_DECODERS_SWIFT

// MARK: - The embedded-PNG hook

/// One frame as an embedded PNG decoder reports it: the fields that
/// ScalableImageDecoderFrame::operator= (ScalableImageDecoderFrame.cpp:37-54)
/// copies out of `*firstFrameBuffer()`.
struct EmbeddedPNGFrame {
    var decodingStatus: DecodingStatus
    /// hasAlpha() of the frame.
    var hasAlpha: Bool
    /// Seconds.
    var duration: Double
    var disposalMethod: ScalableImageDecoderFrame.DisposalMethod
    var orientation: ImageOrientation
    /// The backing store's size, alpha mode and pixel words; nil if the frame
    /// has no backing store.
    var pixels: ImageDecoderFramePixels?
}

/// A PNGImageDecoder for one ICO entry (C++ m_pngDecoders[index]). Phase 4:
/// implemented over the C++ PNGImageDecoder. Called only with the ICO decoder's
/// lock held, from one thread at a time.
///
/// Its answers are untrusted: the ICO decoder uses them only as the C++
/// ICOImageDecoder does (status and size compared, frame copied, failed()
/// checked), and checks the frame's invariants itself.
protocol EmbeddedPNGDecoding: AnyObject {
    /// ScalableImageDecoder::setData(SharedBuffer(entry bytes), allDataReceived).
    func setData(_ data: [UInt8], allDataReceived: Bool)
    /// ScalableImageDecoder::encodedDataStatus().
    func encodedDataStatus() -> EncodedDataStatus
    /// ScalableImageDecoder::size().
    func size() -> PixelSize
    /// ScalableImageDecoder::failed().
    func failed() -> Bool
    /// PNGImageDecoder::firstFrameBuffer() (PNGImageDecoder.cpp:276-280), which
    /// decodes as much of the first frame as the data allows. nil for nullptr.
    func decodeFirstFrame() -> EmbeddedPNGFrame?
}

/// PNGImageDecoder::create(AlphaOption, GammaAndColorProfileOption).
typealias EmbeddedPNGDecoderFactory = @Sendable (AlphaOption, GammaAndColorProfileOption) -> any EmbeddedPNGDecoding

/// The decoder in ICOImageDecoderFormat.placeholder(), which is never decoded with.
private final class NoEmbeddedPNGDecoder: EmbeddedPNGDecoding {
    func setData(_ data: [UInt8], allDataReceived: Bool) { }
    func encodedDataStatus() -> EncodedDataStatus { .error }
    func size() -> PixelSize { PixelSize(width: 0, height: 0) }
    func failed() -> Bool { true }
    func decodeFirstFrame() -> EmbeddedPNGFrame? { nil }
}

extension ScalableImageDecoderFrame {
    /// `ScalableImageDecoderFrame& operator=(const ScalableImageDecoderFrame&)`
    /// from an embedded decoder's frame, or nil when the frame cannot be
    /// represented: status .decoding (C++ only ASSERTs against it,
    /// ScalableImageDecoderFrame.cpp:56-60) or a backing store that
    /// ImageBackingStore cannot allocate.
    init?(embedded frame: EmbeddedPNGFrame) {
        self.init()
        guard frame.decodingStatus != .decoding else {
            return nil
        }
        decodingStatus = frame.decodingStatus
        if let pixels = frame.pixels {
            guard initialize(size: pixels.size, premultiplyAlpha: pixels.premultiplyAlpha) else {
                return nil
            }
            // pixels.pixels.count == width * height == the new store's word
            // count (both checked by their initializers), so every index is in
            // bounds.
            withBackingStore { store in
                for index in pixels.pixels.indices {
                    store[index] = pixels.pixels[index]
                }
            }
        }
        disposalMethod = frame.disposalMethod
        orientation = frame.orientation
        duration = frame.duration
        setHasAlpha(frame.hasAlpha)
    }
}

// MARK: - ICOImageDecoder

/// ICOImageDecoder's members (ICOImageDecoder.h:134-153) and virtual overrides.
struct ICOImageDecoderFormat: BMPFamilyFormat {
    /// m_decodedOffset, m_fileType, m_dirEntries.
    private(set) var directory = ICODirectory()
    /// Whether processDirectoryEntries() has run and called setSize().
    private var directoryEntriesProcessed = false
    /// m_bmpReaders.
    private var bmpReaders: [BMPImageReader?] = []
    /// m_pngDecoders.
    private var pngDecoders: [(any EmbeddedPNGDecoding)?] = []
    /// m_frameSize: valid only while a BMPImageReader is decoding.
    private var frameSize = PixelSize(width: 0, height: 0)
    /// PNGImageDecoder::create.
    private let makePNGDecoder: EmbeddedPNGDecoderFactory

    init(makePNGDecoder: @escaping EmbeddedPNGDecoderFactory) {
        self.makePNGDecoder = makePNGDecoder
    }

    static func placeholder() -> Self {
        Self(makePNGDecoder: { _, _ in NoEmbeddedPNGDecoder() })
    }

    /// ICOImageDecoder.h:45.
    static var filenameExtension: String { "ico" }

    private static func pixelSize(_ size: ICODirectory.IntSize) -> PixelSize {
        // Entry sides are 0 (not yet read) or 1...256: exact.
        PixelSize(width: Int32(clamping: size.width), height: Int32(clamping: size.height))
    }

    /// ICOImageDecoder.h:85.
    static func tryDecodeSize(_ state: inout ScalableImageDecoderState<Self>, allDataReceived: Bool) {
        decode(&state, index: 0, onlySize: true, allDataReceived: allDataReceived)
    }

    /// ICOImageDecoder::setData (ICOImageDecoder.cpp:56-70). The BMP readers
    /// read the decoder's data when they run (C++ m_bmpReaders[i]->setData
    /// stores the same buffer), so only the PNG decoders are updated here.
    static func setData(_ state: inout ScalableImageDecoderState<Self>, _ data: [UInt8], allDataReceived: Bool) {
        if state.failed {
            return
        }

        state.setData(data, allDataReceived: allDataReceived)

        for index in state.format.pngDecoders.indices {
            setDataForPNGDecoder(&state, at: index)
        }
    }

    /// ICOImageDecoder::size (ICOImageDecoder.cpp:72-75).
    static func size(_ state: ScalableImageDecoderState<Self>) -> PixelSize {
        state.format.frameSize.isEmpty ? state.baseSize() : state.format.frameSize
    }

    /// ICOImageDecoder::frameSizeAtIndex (ICOImageDecoder.cpp:77-80).
    static func frameSize(_ state: inout ScalableImageDecoderState<Self>, at index: Int, subsampling: SubsamplingLevel) -> PixelSize {
        let entries = state.format.directory.entries
        return (index != 0 && index < entries.count) ? pixelSize(entries[index].size) : state.size()
    }

    /// ICOImageDecoder::setSize (ICOImageDecoder.cpp:82-87): the size
    /// calculated inside the BMPImageReader had better match the one in the
    /// icon directory.
    static func setSize(_ state: inout ScalableImageDecoderState<Self>, _ size: PixelSize) -> Bool {
        state.format.frameSize.isEmpty ? state.baseSetSize(size) : (size == state.format.frameSize || state.setFailed())
    }

    /// ICOImageDecoder::decodeIfNeededAndGetFrameCount (ICOImageDecoder.cpp:89-94).
    static func decodeIfNeededAndGetFrameCount(_ state: inout ScalableImageDecoderState<Self>) -> Int {
        decode(&state, index: 0, onlySize: true, allDataReceived: state.isAllDataReceived)
        return state.frameBufferCache.count
    }

    /// ICOImageDecoder::frameBufferAtIndex (ICOImageDecoder.cpp:96-107).
    static func frameBufferAtIndex(_ state: inout ScalableImageDecoderState<Self>, _ index: Int) -> Int? {
        // Ensure |index| is valid.
        if index >= decodeIfNeededAndGetFrameCount(&state) {
            return nil
        }

        if !state.frameBufferCache[index].isComplete {
            decode(&state, index: index, onlySize: false, allDataReceived: state.isAllDataReceived)
        }
        return index
    }

    /// ICOImageDecoder::setFailed (ICOImageDecoder.cpp:109-114).
    static func setFailed(_ state: inout ScalableImageDecoderState<Self>) -> Bool {
        state.format.bmpReaders.removeAll()
        state.format.pngDecoders.removeAll()
        return state.baseSetFailed()
    }

    /// ICOImageDecoder::hotSpot (ICOImageDecoder.cpp:116-122): when
    /// unspecified, the default frame is always frame 0.
    static func hotSpot(_ state: inout ScalableImageDecoderState<Self>) -> PixelPoint? {
        // hotSpotAtIndex(0) (ICOImageDecoder.cpp:124-130). Hot spot coordinates
        // are uint16_t: exact.
        guard let point = state.format.directory.hotSpot(at: 0) else {
            return nil
        }
        return PixelPoint(x: Int32(clamping: point.x), y: Int32(clamping: point.y))
    }

    /// ICOImageDecoder::setDataForPNGDecoderAtIndex (ICOImageDecoder.cpp:142-153):
    /// gives the PNG decoder the bytes from the entry's offset to the end.
    private static func setDataForPNGDecoder(_ state: inout ScalableImageDecoderState<Self>, at index: Int) {
        guard index < state.format.pngDecoders.count, let decoder = state.format.pngDecoders[index] else {
            return
        }
        let entries = state.format.directory.entries
        guard index < entries.count else {
            return
        }
        // The decoder exists only once imageTypeAtIndex saw 4 bytes at the
        // offset, so the offset fits in Int and is <= data.count unless the
        // data has since shrunk (C++ out-of-bounds subspan; see the header).
        let pngData: [UInt8]
        if let offset = Int(exactly: entries[index].imageOffset), offset <= state.data.count {
            pngData = Array(state.data[offset...])
        } else {
            pngData = []
        }
        decoder.setData(pngData, allDataReceived: state.isAllDataReceived)
    }

    /// ICOImageDecoder::decode (ICOImageDecoder.cpp:155-178).
    private static func decode(_ state: inout ScalableImageDecoderState<Self>, index: Int, onlySize: Bool, allDataReceived: Bool) {
        if state.failed {
            return
        }

        // If we couldn't decode the image but we've received all the data, decoding
        // has failed.
        if (!decodeDirectory(&state) || (!onlySize && !decodeAtIndex(&state, index))) && allDataReceived {
            state.setFailed()
        } else if state.frameBufferCache.count > index && state.frameBufferCache[index].isComplete {
            // If we're done decoding this frame, we don't need the BMPImageReader or
            // PNG decoder anymore. (If we failed, these have already been
            // cleared; the C++ then indexes the empty vectors, see the header.)
            if index < state.format.bmpReaders.count {
                state.format.bmpReaders[index] = nil
            }
            if index < state.format.pngDecoders.count {
                state.format.pngDecoders[index] = nil
            }
        }

        if state.frameBufferCache.isEmpty {
            state.frameBufferCache = Array(repeating: ScalableImageDecoderFrame(), count: state.format.directory.entries.count)
        }
        // CAUTION (C++): the cache must not be resized again after this.
    }

    /// ICOImageDecoder::decodeDirectory (ICOImageDecoder.cpp:180-188), with
    /// processDirectory/processDirectoryEntries in ICODirectory and their
    /// setFailed()/setSize() calls made here, on the decoder.
    private static func decodeDirectory(_ state: inout ScalableImageDecoderState<Self>) -> Bool {
        let data = state.data[...]
        let status = state.format.directory.decodeDirectory(data.span)

        // processDirectory: m_bmpReaders.resize(idCount), m_pngDecoders.resize(idCount)
        // (ICOImageDecoder.cpp:251-253), once.
        let entryCount = state.format.directory.entries.count
        if status != .failed && state.format.bmpReaders.isEmpty && entryCount > 0 {
            state.format.bmpReaders = Array(repeating: nil, count: entryCount)
            state.format.pngDecoders = Array(repeating: nil, count: entryCount)
        }

        switch status {
        case .needMoreData:
            return false
        case .failed:
            return state.setFailed()
        case .ok:
            if state.format.directoryEntriesProcessed {
                return true
            }
            // processDirectoryEntries: the image size is the size of the
            // largest entry (ICOImageDecoder.cpp:275-280).
            state.format.directoryEntriesProcessed = true
            guard let best = state.format.directory.entries.first else {
                return state.setFailed() // unreachable: idCount >= 1
            }
            return state.setSize(pixelSize(best.size))
        }
    }

    /// ICOImageDecoder::decodeAtIndex (ICOImageDecoder.cpp:190-231).
    private static func decodeAtIndex(_ state: inout ScalableImageDecoderState<Self>, _ index: Int) -> Bool {
        // C++ ASSERT_WITH_SECURITY_IMPLICATION(index < m_dirEntries.size()):
        // frameBufferAtIndex only passes index < frame count == entry count.
        let entries = state.format.directory.entries
        guard index >= 0, index < entries.count, index < state.format.bmpReaders.count, index < state.frameBufferCache.count else {
            return false
        }
        let entry = entries[index]
        let data = state.data[...]
        let imageType = state.format.directory.imageType(at: index, in: data.span)
        switch imageType {
        case .unknown:
            return false // Not enough data to determine image type yet.
        case .bmp:
            return decodeBMPEntry(&state, index, entry: entry)
        case .png:
            return decodePNGEntry(&state, index, entry: entry)
        }
    }

    private static func decodeBMPEntry(_ state: inout ScalableImageDecoderState<Self>, _ index: Int, entry: ICODirectory.Entry) -> Bool {
        var reader: BMPImageReader
        if let existing = state.format.bmpReaders[index] {
            reader = existing
        } else {
            // imageType(at:) returned .bmp, which proves imageOffset fits in
            // Int and is <= data.count (F1: never Int(imageOffset)).
            guard let imageOffset = Int(exactly: entry.imageOffset) else {
                return false
            }
            reader = BMPImageReader(decodedAndHeaderOffset: imageOffset, imgDataOffset: 0, usesAndMask: true)
        }
        // The reader is out of the array while it runs (no copy-on-write of its
        // tables, and setFailed() cannot destroy it mid-call); it goes back
        // only if the decoder has not failed.
        state.format.bmpReaders[index] = nil

        state.format.frameSize = pixelSize(entry.size)
        let data = state.data[...]
        let result = state.runReader(&reader, data: data.span, onlySize: false, frameIndex: index)
        state.format.frameSize = PixelSize(width: 0, height: 0)

        if !state.failed && index < state.format.bmpReaders.count {
            state.format.bmpReaders[index] = reader
        }
        return result
    }

    private static func decodePNGEntry(_ state: inout ScalableImageDecoderState<Self>, _ index: Int, entry: ICODirectory.Entry) -> Bool {
        if state.format.pngDecoders[index] == nil {
            state.format.pngDecoders[index] = state.format.makePNGDecoder(
                state.premultiplyAlpha ? .premultiplied : .notPremultiplied,
                state.ignoreGammaAndColorProfile ? .ignored : .applied)
            setDataForPNGDecoder(&state, at: index)
        }
        guard let decoder = state.format.pngDecoders[index] else {
            return false
        }

        // Fail if the size the PNG decoder calculated does not match the size
        // in the directory.
        if decoder.encodedDataStatus().rawValue >= EncodedDataStatus.sizeAvailable.rawValue && decoder.size() != pixelSize(entry.size) {
            return state.setFailed()
        }

        // firstFrameBuffer() is null until the sub-decoder has parsed its own
        // header, which has not happened yet when only part of the embedded PNG
        // has arrived.
        guard let embeddedFrame = decoder.decodeFirstFrame() else {
            return false
        }

        guard let frame = ScalableImageDecoderFrame(embedded: embeddedFrame) else {
            return state.setFailed() // Not representable: untrusted hook result.
        }
        state.frameBufferCache[index] = frame
        return !decoder.failed() || state.setFailed()
    }
}

typealias ICOImageDecoder = BMPFamilyImageDecoder<ICOImageDecoderFormat>

extension BMPFamilyImageDecoder where Format == ICOImageDecoderFormat {
    /// ICOImageDecoder::create (ICOImageDecoder.h:40-43), with the C++
    /// PNGImageDecoder::create as `makePNGDecoder`. `cairoMaxImageSize` is
    /// ImageBackingStore::cairoMaxImageSize on USE(CAIRO) builds, else nil.
    static func create(alphaOption: AlphaOption, gammaAndColorProfileOption: GammaAndColorProfileOption,
        makePNGDecoder: @escaping EmbeddedPNGDecoderFactory, cairoMaxImageSize: Int32? = nil) -> ICOImageDecoder {
        ICOImageDecoder(format: ICOImageDecoderFormat(makePNGDecoder: makePNGDecoder), alphaOption: alphaOption,
            gammaAndColorProfileOption: gammaAndColorProfileOption, cairoMaxImageSize: cairoMaxImageSize)
    }
}

#endif // ENABLE_IMAGE_DECODERS_SWIFT
