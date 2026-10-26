/*
 * Copyright (C) 2006 Apple Inc. All rights reserved.
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
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

// PROTOTYPE: Swift port of WebCore::GIFImageDecoder (gif/GIFImageDecoder.{h,cpp})
// on top of the Swift GIFImageReader (GIFImageReader.swift) and the Swift
// ScalableImageDecoder substrate (ScalableImageDecoderCore.swift,
// ImageFrameBuffer.swift). Not yet in WebCore.xcodeproj / CMake.
//
// Shape, and why:
//  * `GIFImageDecoderFormat` is the GIF subclass's state and virtual overrides
//    (ScalableImageDecoderFormat). It lives inside the core's locked state, so
//    every member below is only touched with the core's Mutex held.
//  * `GIFImageDecoder` is the object handed out (PixelBufferImageDecoding). It
//    forwards to the core and overrides setData, which the C++ subclass
//    overrides too (GIFImageDecoder.cpp:43-50) and the core has no hook for.
//  * The reader is WebCore-free: decode() takes the data as a Span and the
//    client `inout`. The client is the locked decoder state itself
//    (ScalableImageDecoderState<GIFImageDecoderFormat>: GIFReaderClient). For
//    the duration of a reader call the reader is MOVED OUT of the state into a
//    local, so the callbacks can mutate the state without overlapping access.
//    What the C++ does to m_reader inside a callback (setFailed() and
//    gifComplete() destroy it) is recorded in flags and applied when the reader
//    returns: the C++ never touches the reader after either (setFailed is
//    followed by `return false` up the stack, gifComplete is the reader's last
//    statement), so the observable result is the same.
//  * The reader keeps its own reference to the data (C++ m_reader->m_data):
//    `readerData`. It is refreshed exactly where the C++ calls
//    m_reader->setData(), i.e. after the base setData has run (so a
//    tryDecodeSize from setData decodes with the reader's previous data, as in
//    C++), and when the reader is created.
//  * Integer widths: every coordinate comes from 16-bit GIF fields
//    (offsets/sizes <= 65535) and frame indices are Int; sums stay below 2^18, so
//    Int arithmetic is exact on 32-bit targets too, and every conversion to Int32
//    is checked (clamping, exact in range) or guarded.

#if ENABLE_IMAGE_DECODERS_SWIFT

// MARK: - The format (GIFImageDecoder's members and virtual overrides)

struct GIFImageDecoderFormat: ScalableImageDecoderFormat {
    /// m_reader. nil while a reader call is in progress (the reader is then a
    /// local of runReader) and after setFailed()/gifComplete().
    fileprivate var reader: GIFImageReader?
    /// m_reader->m_data: what the C++ reader decodes (GIFImageReader::setData).
    fileprivate var readerData: [UInt8] = []
    /// m_currentBufferSawAlpha. The C++ member has no initializer, but every read
    /// (frameComplete) follows a write by initFrameBuffer on the same decoder.
    fileprivate var currentBufferSawAlpha = false
    /// m_repetitionCount (mutable cache, GIFImageDecoder.h:83).
    fileprivate var cachedRepetitionCount: Int32 = RepetitionCount.once
    /// The frame rects (xOffset, yOffset, width, height) of the reader's frames
    /// with a defined header, i.e. what initFrameBuffer() reads through
    /// m_reader->frameContext() when it is reached from frameComplete(), where
    /// the Swift reader cannot be read (it is the callee). Header fields never
    /// change once defined; the list is rebuilt for every new reader.
    fileprivate var frameRects: [GIFFrameRect] = []
    /// Set by setFailed()/gifComplete() while the reader is moved out.
    fileprivate var readerDestroyed = false
    fileprivate var gifCompleted = false

    init() { }

    /// GIFImageDecoder.h:49.
    static var filenameExtension: String { "gif" }

    /// GIFImageDecoder.h:66: tryDecodeSize(bool allDataReceived) { decode(0, GIFSizeQuery, allDataReceived); }
    static func tryDecodeSize(_ state: inout ScalableImageDecoderState<Self>, allDataReceived: Bool) {
        decode(&state, haltAtFrame: 0, query: .size, allDataReceived: allDataReceived)
    }

    /// GIFImageDecoder::setSize (GIFImageDecoder.cpp:52-58).
    static func setSize(_ state: inout ScalableImageDecoderState<Self>, _ size: PixelSize) -> Bool {
        if state.encodedDataStatus.rawValue >= EncodedDataStatus.sizeAvailable.rawValue && state.size() == size {
            return true
        }
        return state.baseSetSize(size)
    }

    /// GIFImageDecoder::decodeIfNeededAndGetFrameCount (GIFImageDecoder.cpp:60-65).
    static func decodeIfNeededAndGetFrameCount(_ state: inout ScalableImageDecoderState<Self>) -> Int {
        decode(&state, haltAtFrame: UInt32.max, query: .frameCount, allDataReceived: state.isAllDataReceived)
        return state.frameBufferCache.count
    }

    /// GIFImageDecoder::repetitionCount (GIFImageDecoder.cpp:67-101); see the
    /// C++ comment there for the rules.
    static func repetitionCount(_ state: inout ScalableImageDecoderState<Self>) -> Int32 {
        updateRepetitionCount(&state, imagesCount: state.format.reader?.imagesCount, loopCount: state.format.reader?.loopCount)
    }

    /// The body of repetitionCount() with m_reader's two values (nil: no reader).
    @discardableResult
    fileprivate static func updateRepetitionCount(_ state: inout ScalableImageDecoderState<Self>, imagesCount: Int?, loopCount: Int?) -> Int32 {
        if state.failed || imagesCount == 0 {
            state.format.cachedRepetitionCount = RepetitionCount.once
        } else if let loopCount, loopCount != gifLoopCountNotSeen {
            // loopCount is a 16-bit stream field, RepetitionCountInfinite (-1) or
            // cLoopCountNotSeen (-2), so loopCount + 1 <= 65536 and the clamping
            // conversion is exact.
            state.format.cachedRepetitionCount = Int32(clamping: loopCount > 0 ? loopCount + 1 : loopCount)
        }
        return state.format.cachedRepetitionCount
    }

    /// GIFImageDecoder::findFirstRequiredFrameToDecode (GIFImageDecoder.cpp:103-135).
    static func findFirstRequiredFrameToDecode(_ state: inout ScalableImageDecoderState<Self>, _ frameIndex: Int) -> Int {
        // The first frame doesn't depend on any other.
        if frameIndex == 0 {
            return 0
        }

        var i = frameIndex
        while i > 0 {
            defer { i -= 1 }
            let disposalMethod = state.frameBufferCache[i - 1].disposalMethod

            // Frames with disposal method RestoreToPrevious are useless, skip them.
            if disposalMethod == .restoreToPrevious {
                continue
            }

            // At this point the disposal method can be Unspecified, DoNotDispose or RestoreToBackground.
            // In every case, if the frame is complete we can start decoding the next one.
            if state.frameBufferCache[i - 1].isComplete {
                return i
            }

            // If the disposal method of this frame is RestoreToBackground and it fills the whole area,
            // the next frame's backing store is initialized to transparent, so we start decoding with it.
            if disposalMethod == .restoreToBackground {
                // The values come from the reader context (the frame's backing store
                // was cleared when the frame was removed from the cache).
                //
                // C++ dereferences m_reader->frameContext(i - 1) unchecked (only an
                // ASSERT). That is never reached: the disposal method is set only by
                // frameComplete(), together with the Complete status, and clear()
                // resets both, so an incomplete frame is always Unspecified. Should
                // it ever be reached without a reader, the frame is treated as not
                // covering the image (keep scanning) instead of crashing.
                if let frameContext = state.format.reader?.frameContext(at: i - 1) {
                    let frameRect = GIFFrameRect(frameContext).pixelRect
                    if frameRect.contains(PixelRect(size: state.size())) {
                        return i
                    }
                }
            }
        }

        return 0
    }

    /// GIFImageDecoder::frameBufferAtIndex (GIFImageDecoder.cpp:137-149).
    static func frameBufferAtIndex(_ state: inout ScalableImageDecoderState<Self>, _ index: Int) -> Int? {
        if index >= decodeIfNeededAndGetFrameCount(&state) {
            return nil
        }

        if !state.frameBufferCache[index].isComplete {
            var i = findFirstRequiredFrameToDecode(&state, index)
            while i <= index {
                // C++ decode(i + 1, ...) converts size_t to unsigned implicitly
                // (modulo 2^32); i < the frame count, far below 2^32 for any input
                // that fits in memory, so the conversion is exact in practice and
                // identical to the C++ always.
                decode(&state, haltAtFrame: UInt32(truncatingIfNeeded: i + 1), query: .full, allDataReceived: state.isAllDataReceived)
                i += 1
            }
        }

        // C++ returns &m_frameBufferCache[index] taken before the decodes; the cache
        // is only ever resized to the reader's image count of the same data, which
        // the decodes above cannot change, so the index is still valid. Checked
        // anyway: never a dangling frame.
        return index < state.frameBufferCache.count ? index : nil
    }

    /// GIFImageDecoder::setFailed (GIFImageDecoder.cpp:151-155).
    static func setFailed(_ state: inout ScalableImageDecoderState<Self>) -> Bool {
        state.format.reader = nil
        state.format.readerDestroyed = true
        return state.baseSetFailed()
    }

    /// GIFImageDecoder::clearDecodedPixelDataIfNeeded (GIFImageDecoder.cpp:157-213),
    /// with indices instead of iterators.
    static func clearDecodedPixelDataIfNeeded(_ state: inout ScalableImageDecoderState<Self>, _ clearBeforeFrame: Int) {
        // In some cases, like if the decoder was destroyed while animating, we
        // can be asked to clear more frames than we currently have.
        if state.frameBufferCache.isEmpty {
            return // Nothing to do.
        }

        // We never want to clear the very last frame in the cache: it's empty,
        // partial, or could be needed to construct the next frame after a future
        // setData() (see GIFImageDecoder.cpp:166-174). count >= 1 here.
        let end = min(clearBeforeFrame, state.frameBufferCache.count - 1)

        // Scan backwards from |end| past empty frames and RestoreToPrevious frames
        // (clearing the complete ones other than |end|); stop at the first frame
        // that a future initFrameBuffer() may copy from (GIFImageDecoder.cpp:180-202).
        var i = end
        while i != 0 && (state.frameBufferCache[i].isInvalid || state.frameBufferCache[i].disposalMethod == .restoreToPrevious) {
            if state.frameBufferCache[i].isComplete && i != end {
                state.frameBufferCache[i].clear()
            }
            i -= 1
        }

        // Now |i| holds the last frame we need to preserve; clear prior frames.
        // (C++ ASSERT(!j->isPartial()) is debug-only; release clears a partial
        // frame like any other non-empty one, and so does this.)
        for j in 0..<i where !state.frameBufferCache[j].isInvalid {
            state.frameBufferCache[j].clear()
        }
    }

    /// GIFImageDecoder::decode (GIFImageDecoder.cpp:332-371).
    fileprivate static func decode(_ state: inout ScalableImageDecoderState<Self>, haltAtFrame: UInt32, query: GIFQuery, allDataReceived: Bool) {
        if state.failed {
            return
        }

        if state.format.reader == nil {
            state.format.reader = GIFImageReader()
            state.format.readerData = state.data
            state.format.frameRects = []
        }

        if query == .size {
            if !runReader(&state, query: .size, haltAtFrame: haltAtFrame) {
                state.setFailed()
            }
            return
        }

        if !runReader(&state, query: .frameCount, haltAtFrame: haltAtFrame) {
            state.setFailed()
            return
        }

        // A successful frame-count query cannot destroy the reader (only
        // setFailed(), which makes it return false, and gifComplete(), which only
        // a full query reaches, do). C++ dereferences m_reader here unchecked.
        guard let reader = state.format.reader else {
            return
        }
        let imagesCount = reader.imagesCount
        // Record the rects of the newly header-defined frames (see frameRects).
        while state.format.frameRects.count < imagesCount, let frameContext = reader.frameContext(at: state.format.frameRects.count) {
            state.format.frameRects.append(GIFFrameRect(frameContext))
        }

        // m_frameBufferCache.resize(m_reader->imagesCount()).
        if state.frameBufferCache.count > imagesCount {
            state.frameBufferCache.removeLast(state.frameBufferCache.count - imagesCount)
        } else {
            while state.frameBufferCache.count < imagesCount {
                state.frameBufferCache.append(ScalableImageDecoderFrame())
            }
        }

        if query == .frameCount {
            return
        }

        if !runReader(&state, query: .full, haltAtFrame: haltAtFrame) {
            state.setFailed()
            return
        }

        // It is also a fatal error if all data is received but we failed to decode
        // all frames completely. (C++ compares unsigned with size_t.)
        if allDataReceived && UInt64(haltAtFrame) >= UInt64(state.frameBufferCache.count) && state.format.reader != nil {
            state.setFailed()
        }
    }

    /// One `m_reader->decode(query, haltAtFrame)` call, with the reader moved out
    /// of the state for its duration (the state is the reader's client).
    private static func runReader(_ state: inout ScalableImageDecoderState<Self>, query: GIFQuery, haltAtFrame: UInt32) -> Bool {
        guard var reader = state.format.reader else {
            return false // Unreachable: decode() creates the reader first.
        }
        state.format.reader = nil
        state.format.readerDestroyed = false
        state.format.gifCompleted = false

        let data = state.format.readerData
        let bytes = data[...]
        let result = reader.decode(bytes.span, query: query, haltAtFrame: haltAtFrame, client: &state)

        if state.format.gifCompleted {
            // GIFImageDecoder::gifComplete (GIFImageDecoder.cpp:323-330), the
            // reader's last statement before `return true`: cache the repetition
            // count, which is now as authoritative as it's ever going to be, and
            // destroy the reader.
            state.format.gifCompleted = false
            updateRepetitionCount(&state, imagesCount: reader.imagesCount, loopCount: reader.loopCount)
        } else if !state.format.readerDestroyed {
            state.format.reader = reader
        }
        state.format.readerDestroyed = false
        return result
    }
}

/// IntRect(frameContext->xOffset, frameContext->yOffset, frameContext->width,
/// frameContext->height). Every field is a 16-bit stream value (<= 65535).
struct GIFFrameRect {
    let x: Int
    let y: Int
    let width: Int
    let height: Int

    init(_ frame: GIFFrameContext) {
        x = frame.xOffset
        y = frame.yOffset
        width = frame.width
        height = frame.height
    }

    /// Exact: each field is <= 65535 (clamping only so the conversion cannot trap).
    var pixelRect: PixelRect {
        PixelRect(x: Int32(clamping: x), y: Int32(clamping: y), width: Int32(clamping: width), height: Int32(clamping: height))
    }

    /// IntRect::intersect (IntRect.cpp:67-86) with IntRect(IntPoint(), size).
    /// Int arithmetic: the sums are <= 131070, so no overflow on any target.
    func intersected(with size: PixelSize) -> PixelRect {
        var l = max(x, 0)
        var t = max(y, 0)
        var r = min(x + width, Int(size.width))
        var b = min(y + height, Int(size.height))

        // Return a clean empty rectangle for non-intersecting cases.
        if l >= r || t >= b {
            l = 0
            t = 0
            r = 0
            b = 0
        }

        // 0 <= l < r <= size.width (and likewise vertically), so all fit in Int32.
        return PixelRect(x: Int32(clamping: l), y: Int32(clamping: t), width: Int32(clamping: r - l), height: Int32(clamping: b - t))
    }
}

extension GIFImageDecoderFormat {
    /// Read-only introspection (tests, debugging): whether m_reader exists and the
    /// cached m_repetitionCount.
    var hasReader: Bool { reader != nil }
    var repetitionCountCache: Int32 { cachedRepetitionCount }
}

// MARK: - The reader callbacks (GIFImageDecoder.cpp:215-321, 373-445)

extension ScalableImageDecoderState: GIFReaderClient where Format == GIFImageDecoderFormat {
    /// GIFImageReader's `m_client->setSize(IntSize(m_screenWidth, m_screenHeight))`.
    mutating func setSize(width: Int, height: Int) -> Bool {
        // 16-bit stream values: always representable.
        guard let width = Int32(exactly: width), let height = Int32(exactly: height) else {
            return setFailed()
        }
        return setSize(PixelSize(width: width, height: height))
    }

    /// GIFImageDecoder::haveDecodedRow (GIFImageDecoder.cpp:215-271). `frame` is
    /// m_reader->frameContext() and `globalColormap` m_reader->globalColormap(),
    /// as a range into the reader's data.
    mutating func haveDecodedRow(frameIndex: Int, row: [UInt8], width: Int, rowNumber: Int, repeatCount: Int,
        writeTransparentPixels: Bool, frame: GIFFrameContext, globalColormap: Range<Int>) -> Bool {
        // The pixel data and coordinates supplied to us are relative to the frame's
        // origin within the entire image size, i.e. (xOffset, yOffset). There is no
        // guarantee that width == (size().width() - xOffset), so we must ensure we
        // don't run off the end of either the source data or the row's X-coordinates.
        // (offsets, width, rowNumber < 65536 and repeatCount <= 8: no overflow.)
        let size = self.size()
        let xBegin = frame.xOffset
        let yBegin = frame.yOffset + rowNumber
        let xEnd = min(frame.xOffset + width, Int(size.width))
        let yEnd = min(frame.yOffset + rowNumber + repeatCount, Int(size.height))
        if row.isEmpty || xEnd <= xBegin || yEnd <= yBegin {
            return true
        }

        // Get the colormap.
        let colorMap = frame.isLocalColormapDefined ? frame.localColormapRange : globalColormap
        if colorMap.isEmpty {
            return true
        }
        // The colormap was parsed out of this data (and data never shrinks under
        // the reader, which fails first if it did), so the range is in bounds.
        // C++ would trap in span::subspan otherwise; fail the decode instead.
        let data = format.readerData
        guard colorMap.lowerBound >= 0, colorMap.upperBound <= data.count else {
            return false
        }

        // Initialize the frame if necessary.
        if (frameBufferCache[frameIndex].isInvalid && !initFrameBuffer(frameIndex, GIFFrameRect(frame))) || !frameBufferCache[frameIndex].hasBackingStore {
            return false
        }

        // 0 <= xBegin < xEnd <= size.width and 0 <= yBegin < yEnd <= size.height,
        // so these conversions are exact and (xBegin, yBegin) is in bounds.
        let x0 = Int32(clamping: xBegin)
        let y0 = Int32(clamping: yBegin)
        let rect = PixelRect(x: x0, y: y0, width: Int32(clamping: xEnd - xBegin), height: Int32(clamping: yEnd - yBegin))
        let colorMapBase = colorMap.lowerBound
        let colorMapSize = colorMap.count
        let isTransparent = frame.isTransparent
        let tpixel = frame.tpixel
        let xOffset = frame.xOffset
        var sawAlpha = false

        frameBufferCache[frameIndex].withBackingStore { store in
            var currentAddress = store.pixelIndex(x: x0, y: y0)
            // Write one row's worth of data into the frame.
            for x in xBegin..<xEnd {
                // x - xOffset < width == row.count (xEnd <= xOffset + width).
                let sourceValue = row[x - xOffset]
                let colorIndex = Int(sourceValue) * 3
                if (!isTransparent || Int(sourceValue) != tpixel) && colorIndex + 2 < colorMapSize {
                    store.setPixel(at: currentAddress, r: data[colorMapBase + colorIndex], g: data[colorMapBase + colorIndex + 1], b: data[colorMapBase + colorIndex + 2], a: 255)
                } else {
                    sawAlpha = true
                    // We may or may not need to write transparent pixels to the buffer.
                    // If we're compositing against a previous image, it's wrong, and if
                    // we're writing atop a cleared, fully transparent buffer, it's
                    // unnecessary; but if we're decoding an interlaced gif and
                    // displaying it "Haeberli"-style, we must write these for passes
                    // beyond the first, or the initial passes will "show through" the
                    // later ones.
                    if writeTransparentPixels {
                        store.setPixel(at: currentAddress, r: 0, g: 0, b: 0, a: 0)
                    }
                }
                currentAddress += 1
            }

            // Tell the frame to copy the row data if need be.
            if repeatCount > 1 {
                store.repeatFirstRow(rect)
            }
        }
        if sawAlpha {
            format.currentBufferSawAlpha = true
        }

        return true
    }

    /// GIFImageDecoder::frameComplete (GIFImageDecoder.cpp:273-321).
    mutating func frameComplete(frameIndex: Int, delayTime: Int, disposal: GIFDisposalMethod) -> Bool {
        // Initialize the frame if necessary. Some GIFs insert do-nothing frames,
        // in which case we never reach haveDecodedRow() before getting here.
        if frameBufferCache[frameIndex].isInvalid {
            // The frame being completed was header-defined when this decode began,
            // so its rect is recorded (see frameRects).
            guard frameIndex < format.frameRects.count else {
                return setFailed()
            }
            if !initFrameBuffer(frameIndex, format.frameRects[frameIndex]) {
                return false // initFrameBuffer() has already called setFailed().
            }
        }

        frameBufferCache[frameIndex].decodingStatus = .complete
        // Seconds::fromMilliseconds(frameDuration): milliseconds / 1000 in double.
        frameBufferCache[frameIndex].duration = Double(delayTime) / 1000
        frameBufferCache[frameIndex].disposalMethod = ScalableImageDecoderFrame.DisposalMethod(disposal)

        if !format.currentBufferSawAlpha {
            // A non-invalid frame always has a backing store (initFrameBuffer gives
            // it one before setting Partial); C++ dereferences it unchecked.
            guard let rect = frameBufferCache[frameIndex].backingStore?.frameRect else {
                return true
            }

            // The whole frame was non-transparent, so it's possible that the entire
            // resulting buffer was non-transparent, and we can setHasAlpha(false).
            if rect.contains(PixelRect(size: size())) {
                frameBufferCache[frameIndex].setHasAlpha(false)
            } else if frameIndex != 0 {
                // Tricky case. This frame does not have alpha only if everywhere
                // outside its rect doesn't have alpha. To know whether this is
                // true, we check the start state of the frame -- if it doesn't have
                // alpha, we're safe.
                //
                // First skip over prior RestoreToPrevious frames (since they don't
                // affect the start state of this frame) the same way we do in
                // initFrameBuffer().
                var previousIndex = frameIndex - 1
                while previousIndex != 0 && frameBufferCache[previousIndex].disposalMethod == .restoreToPrevious {
                    previousIndex -= 1
                }

                // Now, if we're at an Unspecified or DoNotDispose frame, then we can
                // say we have no alpha if that frame had no alpha. But since in
                // initFrameBuffer() we already copied that frame's alpha state into
                // the current frame's, we need do nothing at all here.
                //
                // The only remaining case is a RestoreToBackground frame. If it had
                // no alpha, and its rect is contained in the current frame's rect, we
                // know the current frame has no alpha.
                //
                // A frame evicted from the cache has no backing store, so its rect is
                // unknown and this frame's opacity cannot be established from it.
                let previous = frameBufferCache[previousIndex]
                if let previousRect = previous.backingStore?.frameRect {
                    if previous.disposalMethod == .restoreToBackground && !previous.hasAlpha && rect.contains(previousRect) {
                        frameBufferCache[frameIndex].setHasAlpha(false)
                    }
                }
            }
        }

        return true
    }

    /// GIFImageDecoder::gifComplete (GIFImageDecoder.cpp:323-330). Its body runs
    /// in runReader when the reader returns (this is the reader's last action).
    mutating func gifComplete() {
        format.gifCompleted = true
    }

    /// GIFImageDecoder::initFrameBuffer (GIFImageDecoder.cpp:373-443). `frameRect`
    /// is m_reader->frameContext()'s rect (the frame being decoded).
    fileprivate mutating func initFrameBuffer(_ frameIndex: Int, _ frameRect: GIFFrameRect) -> Bool {
        let size = self.size()

        if frameIndex == 0 {
            // This is the first frame, so we're not relying on any previous data.
            if !frameBufferCache[frameIndex].initialize(size: size, premultiplyAlpha: premultiplyAlpha) {
                return setFailed()
            }
        } else {
            // The starting state for this frame depends on the previous frame's
            // disposal method.
            //
            // Frames that use the RestoreToPrevious method are effectively no-ops in
            // terms of changing the starting state of a frame compared to the
            // starting state of the previous frame, so skip over them. (If the first
            // frame specifies this method, it will get treated like
            // RestoreToBackground below and reset to a completely empty image.)
            var previousIndex = frameIndex - 1
            var previousMethod = frameBufferCache[previousIndex].disposalMethod
            while previousIndex != 0 && previousMethod == .restoreToPrevious {
                previousIndex -= 1
                previousMethod = frameBufferCache[previousIndex].disposalMethod
            }

            guard let previousStore = frameBufferCache[previousIndex].backingStore else {
                return setFailed()
            }

            if previousMethod == .unspecified || previousMethod == .doNotDispose {
                // Preserve the last frame as the starting state for this frame.
                if !frameBufferCache[frameIndex].initialize(copying: previousStore) {
                    return setFailed()
                }
            } else {
                // We want to clear the previous frame to transparent, without
                // affecting pixels in the image outside of the frame.
                let previousRect = previousStore.frameRect
                if previousIndex == 0 || previousRect.contains(PixelRect(size: size)) {
                    // Clearing the first frame, or a frame the size of the whole
                    // image, results in a completely empty image.
                    if !frameBufferCache[frameIndex].initialize(size: size, premultiplyAlpha: premultiplyAlpha) {
                        return setFailed()
                    }
                } else {
                    // Copy the whole previous buffer, then clear just its frame.
                    if !frameBufferCache[frameIndex].initialize(copying: previousStore) {
                        return setFailed()
                    }
                    frameBufferCache[frameIndex].withBackingStore { $0.clearRect(previousRect) }
                    frameBufferCache[frameIndex].setHasAlpha(true)
                }
            }
        }

        // A frame offset can exceed the canvas, since the logical screen size is only
        // published for the first frame. A subtracted extent would be negative there.
        let rect = frameRect.intersected(with: size)
        frameBufferCache[frameIndex].withBackingStore { $0.setFrameRect(rect) }

        // Update our status to be partially complete.
        frameBufferCache[frameIndex].decodingStatus = .partial

        // Reset the alpha pixel tracker for this frame.
        format.currentBufferSawAlpha = false
        return true
    }
}

extension ScalableImageDecoderFrame.DisposalMethod {
    /// GIFImageReader passes the GIF disposal method as
    /// ScalableImageDecoderFrame::DisposalMethod (same values, 0...3).
    init(_ method: GIFDisposalMethod) {
        switch method {
        case .unspecified: self = .unspecified
        case .doNotDispose: self = .doNotDispose
        case .restoreToBackground: self = .restoreToBackground
        case .restoreToPrevious: self = .restoreToPrevious
        }
    }
}

// MARK: - The decoder object

/// WebCore::GIFImageDecoder: a ScalableImageDecoderCore<GIFImageDecoderFormat>
/// plus the setData override.
final class GIFImageDecoder: PixelBufferImageDecoding {
    let core: ScalableImageDecoderCore<GIFImageDecoderFormat>

    /// GIFImageDecoder::create (GIFImageDecoder.h:39-42).
    init(alphaOption: AlphaOption, gammaAndColorProfileOption: GammaAndColorProfileOption) {
        core = ScalableImageDecoderCore(format: GIFImageDecoderFormat(), alphaOption: alphaOption, gammaAndColorProfileOption: gammaAndColorProfileOption)
    }

    /// GIFImageDecoder::setData (GIFImageDecoder.cpp:43-50): the base setData,
    /// then `m_reader->setData(*m_data)`. One lock acquisition covers all of it
    /// (C++ reads failed() and calls m_reader->setData without the lock).
    func setData(_ data: [UInt8], allDataReceived: Bool) {
        core.withLockedState { state in
            if state.failed {
                return
            }
            state.setData(data, allDataReceived: allDataReceived)
            if state.format.reader != nil {
                state.format.readerData = state.data
            }
        }
    }

    // Everything else is the ScalableImageDecoder base (the core).
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
    func fetchFrameMetadata(at index: Int, subsampling: SubsamplingLevel, options: DecodingOptions) -> ImageFrameMetadata? {
        core.fetchFrameMetadata(at: index, subsampling: subsampling, options: options)
    }
    func createFramePixels(at index: Int, subsampling: SubsamplingLevel, options: DecodingOptions) -> ImageDecoderFramePixels? {
        core.createFramePixels(at: index, subsampling: subsampling, options: options)
    }
    func isAllDataReceived() -> Bool { core.isAllDataReceived() }
    func clearFrameBufferCache(_ index: Int) { core.clearFrameBufferCache(index) }

    var premultiplyAlpha: Bool { core.premultiplyAlpha }
    func setIgnoreGammaAndColorProfile(_ flag: Bool) { core.setIgnoreGammaAndColorProfile(flag) }
    var ignoresGammaAndColorProfile: Bool { core.ignoresGammaAndColorProfile }
    var failed: Bool { core.failed }
}

#endif // ENABLE_IMAGE_DECODERS_SWIFT
