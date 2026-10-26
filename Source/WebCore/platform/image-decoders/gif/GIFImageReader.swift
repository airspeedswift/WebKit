/* -*- Mode: C; tab-width: 2; indent-tabs-mode: nil; c-basic-offset: 2 -*- */
/* ***** BEGIN LICENSE BLOCK *****
 * Version: MPL 1.1/GPL 2.0/LGPL 2.1
 *
 * The contents of this file are subject to the Mozilla Public License Version
 * 1.1 (the "License"); you may not use this file except in compliance with
 * the License. You may obtain a copy of the License at
 * http://www.mozilla.org/MPL/
 *
 * Software distributed under the License is distributed on an "AS IS" basis,
 * WITHOUT WARRANTY OF ANY KIND, either express or implied. See the License
 * for the specific language governing rights and limitations under the
 * License.
 *
 * The Original Code is mozilla.org code.
 *
 * The Initial Developer of the Original Code is
 * Netscape Communications Corporation.
 * Portions created by the Initial Developer are Copyright (C) 1998
 * the Initial Developer. All Rights Reserved.
 *
 * Contributor(s):
 *   Chris Saari <saari@netscape.com>
 *   Apple Inc.
 *
 * Alternatively, the contents of this file may be used under the terms of
 * either the GNU General Public License Version 2 or later (the "GPL"), or
 * the GNU Lesser General Public License Version 2.1 or later (the "LGPL"),
 * in which case the provisions of the GPL or the LGPL are applicable instead
 * of those above. If you wish to allow use of your version of this file only
 * under the terms of either the GPL or the LGPL, and not to allow others to
 * use your version of this file under the terms of the MPL, indicate your
 * decision by deleting the provisions above and replace them with the notice
 * and other provisions required by the GPL or the LGPL. If you do not delete
 * the provisions above, a recipient may use your version of this file under
 * the terms of any one of the MPL, the GPL or the LGPL.
 *
 * ***** END LICENSE BLOCK ***** */

// Swift port of GIFImageReader.cpp / GIFImageReader.h.
//
// Differences in shape (not behaviour) from the C++:
//  - WebCore-free: the GIFImageDecoder callbacks are a generic GIFReaderClient
//    passed `inout` to decode(), instead of a stored client pointer.
//  - The reader does not retain the encoded data. Every decode() call takes the
//    current data as a Span; the reader stores only offsets into it, and
//    colormaps are exposed as Range<Int> into that data.
//  - The LZW context does not point back at its frame; the frame passes itself
//    (a value copy, whose fields cannot change while it is being decoded) to the
//    LZW routines.
//  - C `int`/`unsigned`/`size_t` fields are Swift `Int`. Every value involved is
//    derived from 8- or 16-bit fields of the stream or from LZW table indices,
//    and the bound that keeps it far from Int overflow is noted where it is not
//    obvious. The two places where the C++ relies on narrowing (to unsigned char)
//    use truncatingIfNeeded and say so.

#if ENABLE_IMAGE_DECODERS_SWIFT

let gifMaxLZWBits = 12
let gifMaxBytes = 4097 // 2^MAX_LZW_BITS + 1
let gifLoopCountNotSeen = -2 // cLoopCountNotSeen
let gifRepetitionCountInfinite = -1 // WebCore::RepetitionCountInfinite

enum GIFQuery: Sendable {
    case full
    case size
    case frameCount
}

// Values match ScalableImageDecoderFrame::DisposalMethod and the GIF spec.
enum GIFDisposalMethod: Int, Sendable {
    case unspecified = 0
    case doNotDispose = 1
    case restoreToBackground = 2
    case restoreToPrevious = 3
}

protocol GIFReaderClient {
    // Return false to make the reader fail (GIFImageDecoder::setSize).
    mutating func setSize(width: Int, height: Int) -> Bool

    // `row` is the whole row buffer (C++ passes the Vector; its count == width).
    // It is the Array itself, not a Span: Array.span needs macOS/iOS 26 and
    // WebKit's deployment minimum is macOS 15 / iOS 18. Passing it does not copy.
    // `frame` is the frame being decoded, i.e. what the C++ client reads back via
    // GIFImageReader::frameContext(), and `globalColormap` is
    // GIFImageReader::globalColormap() as a range into the data passed to decode().
    mutating func haveDecodedRow(frameIndex: Int, row: [UInt8], width: Int, rowNumber: Int, repeatCount: Int,
        writeTransparentPixels: Bool, frame: GIFFrameContext, globalColormap: Range<Int>) -> Bool

    mutating func frameComplete(frameIndex: Int, delayTime: Int, disposal: GIFDisposalMethod) -> Bool
    mutating func gifComplete()
}

// List of possible parsing states (GIFState).
enum GIFState: Sendable {
    case type
    case globalHeader
    case globalColormap
    case imageStart
    case imageHeader
    case imageColormap
    case imageBody
    case lzwStart
    case lzw
    case subBlock
    case `extension`
    case controlExtension
    case consumeBlock
    case skipBlock
    case done
    case commentExtension
    case applicationExtension
    case netscapeExtensionBlock
    case consumeNetscapeExtension
    case consumeComment
}

// LZW decoder state machine.
struct GIFLZWContext {
    private var stackp = 0 // Current stack pointer, 0...gifMaxBytes.
    // codesize <= 12 and codemask <= 4095 (see doLZW); bits < 20 and datum < 2^27.
    private var codesize = 0
    private var codemask = 0
    private var clearCode = 0 // Codeword used to trigger dictionary reset.
    private var avail = 0 // Index of next available slot in dictionary, <= 4096.
    private var oldcode = 0
    private var firstchar: UInt8 = 0
    private var bits = 0 // Number of unread bits in "datum".
    private var datum = 0 // Input buffer.
    private var ipass = 0 // Interlace pass; Ranges 1-4 if interlaced.
    private var irow = 0 // Current output row, starting at zero.
    private var rowPosition = 0
    private(set) var rowsRemaining = 0 // Rows remaining to be output.

    private var prefix: [UInt16] = []
    private var suffix: [UInt8] = []
    private var stack: [UInt8] = []
    private var rowBuffer: [UInt8] = [] // Single scanline temporary buffer.

    var hasRemainingRows: Bool { rowsRemaining != 0 }

    mutating func prepareToDecode(_ frame: GIFFrameContext) -> Bool {
        precondition(frame.isDataSizeDefined && frame.isHeaderDefined)

        // Since we use a codesize of 1 more than the datasize, we need to ensure
        // that our datasize is strictly less than the MAX_LZW_BITS value (12).
        // This sets the largest possible codemask correctly at 4095.
        if frame.datasize >= gifMaxLZWBits {
            return false
        }
        // datasize is 0...11 here (it is a byte), so clearCode <= 2048.
        clearCode = 1 << frame.datasize
        if clearCode >= gifMaxBytes {
            return false
        }

        avail = clearCode + 2
        oldcode = -1
        codesize = frame.datasize + 1
        codemask = (1 << codesize) - 1
        datum = 0
        bits = 0
        ipass = frame.interlaced ? 1 : 0
        irow = 0

        // Initialize the tables lazily, this allows frame count query to use less memory.
        // Clearing the whole suffix table lets us be more tolerant of bad data.
        suffix = [UInt8](repeating: 0, count: gifMaxBytes)
        stack = [UInt8](repeating: 0, count: gifMaxBytes)
        prefix = [UInt16](repeating: 0, count: gifMaxBytes)

        // Initialize output row buffer.
        rowBuffer = [UInt8](repeating: 0, count: frame.width)
        rowPosition = 0
        rowsRemaining = frame.height

        for i in 0..<clearCode {
            // C++ `suffix[i] = i` stores into unsigned char; clearCode can be up to
            // 2048, so the C++ relies on the narrowing for datasize >= 9.
            suffix[i] = UInt8(truncatingIfNeeded: i)
        }
        stackp = 0
        return true
    }

    // Send the data to the display front-end.
    private mutating func outputRow(_ frame: GIFFrameContext, globalColormap: Range<Int>, client: inout some GIFReaderClient) -> Bool {
        // frame.height >= 1 (zero sizes are rejected by the header parser) and <= 65535.
        let height = frame.height
        var drowStart = irow
        var drowEnd = irow

        // Haeberli-inspired hack for interlaced GIFs: Replicate lines while
        // displaying to diminish the "venetian-blind" effect as the image is
        // loaded. Adjust pixel vertical positions to avoid the appearance of the
        // image crawling up the screen as successive passes are drawn.
        if frame.progressiveDisplay && frame.interlaced && ipass < 4 {
            var rowDup = 0
            var rowShift = 0

            switch ipass {
            case 1:
                rowDup = 7
                rowShift = 3
            case 2:
                rowDup = 3
                rowShift = 1
            case 3:
                rowDup = 1
                rowShift = 0
            default:
                break
            }

            drowStart -= rowShift
            drowEnd = drowStart + rowDup

            // Extend if bottom edge isn't covered because of the shift upward.
            // C++: ((height - 1) - drowEnd) <= rowShift in unsigned arithmetic.
            // drowEnd >= 0 here, so a negative difference wraps to a value far
            // above rowShift (<= 3) and the condition is false.
            let bottomGap = (height - 1) - drowEnd
            if bottomGap >= 0 && bottomGap <= rowShift {
                drowEnd = height - 1
            }

            // Clamp first and last rows to upper and lower edge of image.
            if drowStart < 0 {
                drowStart = 0
            }

            if drowEnd >= height {
                drowEnd = height - 1
            }
        }

        // Protect against too much image data. (C++ compares (unsigned)drowStart;
        // drowStart is never negative here.)
        if drowStart >= height {
            return true
        }

        // CALLBACK: Let the client know we have decoded a row.
        if !client.haveDecodedRow(frameIndex: frame.frameId, row: rowBuffer, width: frame.width,
            rowNumber: drowStart, repeatCount: drowEnd - drowStart + 1,
            writeTransparentPixels: frame.progressiveDisplay && frame.interlaced && ipass > 1,
            frame: frame, globalColormap: globalColormap) {
            return false
        }

        if !frame.interlaced {
            irow += 1
        } else {
            repeat {
                switch ipass {
                case 1:
                    irow += 8
                    if irow >= height {
                        ipass += 1
                        irow = 4
                    }
                case 2:
                    irow += 8
                    if irow >= height {
                        ipass += 1
                        irow = 2
                    }
                case 3:
                    irow += 4
                    if irow >= height {
                        ipass += 1
                        irow = 1
                    }
                case 4:
                    irow += 2
                    if irow >= height {
                        ipass += 1
                        irow = 0
                    }
                default:
                    break
                }
            } while irow > height - 1
        }
        return true
    }

    private enum RowResult {
        case continueDecoding
        case fail
        case allRowsDone
    }

    // The OUTPUT_ROW macro.
    private mutating func outputRowAndAdvance(_ frame: GIFFrameContext, globalColormap: Range<Int>, client: inout some GIFReaderClient) -> RowResult {
        if !outputRow(frame, globalColormap: globalColormap, client: &client) {
            return .fail
        }
        rowsRemaining -= 1
        rowPosition = 0
        if rowsRemaining == 0 {
            return .allRowsDone
        }
        return .continueDecoding
    }

    // Perform Lempel-Ziv-Welch decoding.
    // Returns true if decoding was successful. In this case the block will have been completely consumed and/or rowsRemaining will be 0.
    // Otherwise, decoding failed; returns false in this case, which will always cause the GIFImageReader to set the "decode failed" flag.
    mutating func doLZW(_ block: Span<UInt8>, frame: GIFFrameContext, globalColormap: Range<Int>, client: inout some GIFReaderClient) -> Bool {
        if rowPosition == rowBuffer.count {
            return true
        }

        for index in block.indices {
            // Feed the next byte into the decoder's input buffer.
            datum += Int(block[index]) << bits
            bits += 8

            // Check for underflow of decoder's input buffer.
            while bits >= codesize {
                // Get the leading variable-length symbol from the data stream.
                // code <= codemask <= 4095: codemask starts at 2^(datasize+1)-1 <= 4095 and only grows
                // (codemask += avail) when avail & codemask == 0 and avail < 4096, which keeps it < 4096.
                var code = datum & codemask
                datum >>= codesize
                bits -= codesize

                // Reset the dictionary to its original state, if requested.
                if code == clearCode {
                    codesize = frame.datasize + 1
                    codemask = (1 << codesize) - 1
                    avail = clearCode + 2
                    oldcode = -1
                    continue
                }

                // Check for explicit end-of-stream code.
                if code == clearCode + 1 {
                    // end-of-stream should only appear after all image data.
                    if rowsRemaining == 0 {
                        return true
                    }
                    return false
                }

                if oldcode == -1 {
                    rowBuffer[rowPosition] = suffix[code]
                    rowPosition += 1
                    if rowPosition == rowBuffer.count {
                        switch outputRowAndAdvance(frame, globalColormap: globalColormap, client: &client) {
                        case .fail: return false
                        case .allRowsDone: return true
                        case .continueDecoding: break
                        }
                    }

                    // C++ `firstchar = oldcode = code` narrows code into unsigned char;
                    // code can exceed 255 here (any code >= 256 right after a clear).
                    oldcode = code
                    firstchar = UInt8(truncatingIfNeeded: code)
                    continue
                }

                let incode = code
                if code >= avail {
                    stack[stackp] = firstchar
                    stackp += 1
                    code = oldcode

                    if stackp == gifMaxBytes {
                        return false
                    }
                }

                while code >= clearCode {
                    if code >= gifMaxBytes || code == Int(prefix[code]) {
                        return false
                    }

                    // Even though suffix[] only holds characters through suffix[avail - 1],
                    // allowing code >= avail here lets us be more tolerant of malformed
                    // data. As long as code < MAX_BYTES, the only risk is a garbled image,
                    // which is no worse than refusing to display it.
                    stack[stackp] = suffix[code]
                    stackp += 1
                    code = Int(prefix[code])

                    if stackp == gifMaxBytes {
                        return false
                    }
                }

                firstchar = suffix[code]
                stack[stackp] = firstchar
                stackp += 1

                // Define a new codeword in the dictionary.
                if avail < 4096 {
                    // oldcode is a previous code here (not -1), so 0 <= oldcode <= 4095.
                    prefix[avail] = UInt16(oldcode)
                    suffix[avail] = firstchar
                    avail += 1

                    // If we've used up all the codewords of a given length
                    // increase the length of codewords by one bit, but don't
                    // exceed the specified maximum codeword size of 12 bits.
                    if (avail & codemask) == 0 && avail < 4096 {
                        codesize += 1
                        codemask += avail
                    }
                }
                oldcode = incode

                // Copy the decoded data out to the scanline buffer.
                repeat {
                    stackp -= 1
                    rowBuffer[rowPosition] = stack[stackp]
                    rowPosition += 1
                    if rowPosition == rowBuffer.count {
                        switch outputRowAndAdvance(frame, globalColormap: globalColormap, client: &client) {
                        case .fail: return false
                        case .allRowsDone: return true
                        case .continueDecoding: break
                        }
                    }
                } while stackp > 0
            }
        }

        return true
    }
}

// Data structure for one LZW block.
struct GIFLZWBlock {
    var blockPosition: Int
    var blockSize: Int
}

// Frame output state machine.
struct GIFFrameContext {
    var frameId: Int
    // C++ unsigned; all four come from 16-bit fields.
    var xOffset = 0
    var yOffset = 0 // With respect to "screen" origin.
    var width = 0
    var height = 0
    var tpixel = 0 // Index of transparent pixel.
    var disposalMethod = GIFDisposalMethod.unspecified // Restore to background, leave in place, etc.
    var localColormapPosition = 0 // Per-image colormap.
    var localColormapSize = 0 // Size of local colormap array (in 3-byte units)
    private(set) var datasize = 0

    var isLocalColormapDefined = false
    var progressiveDisplay = false // If true, do Haeberli interlace hack.
    var interlaced = false // True, if scanlines arrive interlaced order.
    var isTransparent = false // TRUE, if tpixel is valid.

    var delayTime = 0 // Display time, in milliseconds, for this image in a multi-image GIF.

    private var lzwContext: GIFLZWContext?
    private var lzwBlocks: [GIFLZWBlock] = [] // LZW blocks for this frame.
    private var currentLzwBlock = 0
    private(set) var isComplete = false
    private(set) var isHeaderDefined = false
    private(set) var isDataSizeDefined = false

    init(frameId: Int) {
        self.frameId = frameId
    }

    // GIFImageReader::localColormap(frame) as a range into the decoded data; empty when not defined.
    var localColormapRange: Range<Int> {
        isLocalColormapDefined ? localColormapPosition..<(localColormapPosition + localColormapSize * 3) : 0..<0
    }

    mutating func addLzwBlock(position: Int, size: Int) {
        lzwBlocks.append(GIFLZWBlock(blockPosition: position, blockSize: size))
    }

    mutating func setComplete() { isComplete = true }
    mutating func setHeaderDefined() { isHeaderDefined = true }
    mutating func setDataSize(_ size: Int) {
        datasize = size
        isDataSizeDefined = true
    }

    // Perform decoding for this frame. frameDecoded will be true if the entire frame is decoded.
    // Returns false if a decoding error occurred. This is a fatal error and causes the GIFImageReader to set the "decode failed" flag.
    // Otherwise, either not enough data is available to decode further than before, or the new data has been decoded successfully; returns true in this case.
    mutating func decode(_ data: Span<UInt8>, globalColormap: Range<Int>, client: inout some GIFReaderClient, frameDecoded: inout Bool) -> Bool {
        frameDecoded = false
        var context: GIFLZWContext
        if let existing = lzwContext {
            context = existing
            lzwContext = nil // Hand the tables over without copying them.
        } else {
            // Wait for more data to properly initialize GIFLZWContext.
            if !isDataSizeDefined || !isHeaderDefined {
                return true
            }

            context = GIFLZWContext()
            if !context.prepareToDecode(self) {
                return false
            }

            currentLzwBlock = 0
        }

        // The frame's fields cannot change while it is being decoded (only the
        // header-parsing states write them, and those run before datasize is defined).
        let frame = self

        // Some bad GIFs have extra blocks beyond the last row, which we don't want to decode.
        while currentLzwBlock < lzwBlocks.count && context.hasRemainingRows {
            let blockPosition = lzwBlocks[currentLzwBlock].blockPosition
            let blockSize = lzwBlocks[currentLzwBlock].blockSize
            if data.count < blockSize || blockPosition > data.count - blockSize {
                lzwContext = context // C++ keeps m_lzwContext on failure.
                return false
            }
            if !context.doLZW(data.extracting(blockPosition..<(blockPosition + blockSize)), frame: frame, globalColormap: globalColormap, client: &client) {
                lzwContext = context // C++ keeps m_lzwContext on failure.
                return false
            }
            currentLzwBlock += 1
        }

        // If this frame is data complete then the previous loop must have completely decoded all LZW blocks.
        // There will be no more decoding for this frame so it's time to cleanup.
        if isComplete {
            frameDecoded = true
        } else {
            lzwContext = context
        }
        return true
    }
}

struct GIFImageReader {
    // Parsing state machine.
    private var state = GIFState.type // Current decoder master state.
    private var bytesToConsume = 6 // Number of bytes to consume for next stage of parsing.
    private var bytesRead = 0 // Number of bytes processed.

    // Global (multi-image) state.
    private var screenBgcolor = 0 // Logical screen background color.
    private var version = 0 // Either 89 for GIF89 or 87 for GIF87.
    private var screenWidth = 0 // Logical screen width & height (16-bit values).
    private var screenHeight = 0
    private var isGlobalColormapDefined = false
    private var globalColormapPosition = 0
    private var globalColormapSize = 0 // Size of global colormap array (in 3-byte units)
    private(set) var loopCount = gifLoopCountNotSeen // Netscape specific extension block to control the number of animation loops a GIF renders.

    private(set) var frames: [GIFFrameContext] = []
    private var currentDecodingFrame = 0

    private var parseCompleted = false

    init() { }

    var imagesCount: Int {
        guard let last = frames.last else {
            return 0
        }

        // This avoids counting an empty frame when the file is truncated right after
        // GIFControlExtension but before GIFImageHeader.
        return last.isHeaderDefined ? frames.count : frames.count - 1
    }

    // Ranges into the data passed to decode(); empty when the colormap is not defined.
    var globalColormapRange: Range<Int> {
        isGlobalColormapDefined ? globalColormapPosition..<(globalColormapPosition + globalColormapSize * 3) : 0..<0
    }

    func localColormapRange(_ frame: GIFFrameContext) -> Range<Int> {
        frame.localColormapRange
    }

    // The frame currently being decoded.
    var frameContext: GIFFrameContext? {
        currentDecodingFrame < frames.count ? frames[currentDecodingFrame] : nil
    }

    func frameContext(at frame: Int) -> GIFFrameContext? {
        frame >= 0 && frame < frames.count ? frames[frame] : nil
    }

    // Decode all frames before haltAtFrame.
    // This method uses GIFFrameContext:decode() to decode each frame; decoding error is reported to client as a critical failure.
    // Return true if decoding has progressed. Return false if an error has occurred.
    mutating func decode(_ data: Span<UInt8>, query: GIFQuery, haltAtFrame: UInt32, client: inout some GIFReaderClient) -> Bool {
        // C++ only ASSERTs this (data never shrinks); a release C++ build would
        // read out of bounds, so fail instead.
        guard bytesRead <= data.count else {
            return false
        }

        if !parse(data, dataPosition: bytesRead, length: data.count - bytesRead, parseSizeOnly: query == .size, client: &client) {
            return false
        }

        if query != .full {
            return true
        }

        // Already decoded frames can be deleted from the cache and then they require to be decoded again, so
        // the haltAtFrame value we receive here may be lower than m_currentDecodingFrame. In this case
        // we position m_currentDecodingFrame to haltAtFrame - 1 and decode from there.
        // See bug https://bugs.webkit.org/show_bug.cgi?id=176089.
        // C++: static_cast<size_t>(haltAtFrame) - 1, which is SIZE_MAX (a no-op min) for 0.
        // haltAtFrame as Int without a trapping Int(): exact with 64-bit Int;
        // with 32-bit Int a value >= 2^31 becomes Int.max, which like the C++
        // value exceeds frames.count (and so currentDecodingFrame <= frames.count),
        // making both min()s below the same no-ops they are in the C++.
        let haltAtFrame = Int(clamping: haltAtFrame)
        if haltAtFrame != 0 {
            currentDecodingFrame = min(currentDecodingFrame, haltAtFrame - 1)
        }

        let globalColormap = globalColormapRange
        while currentDecodingFrame < min(frames.count, haltAtFrame) {
            var frameDecoded = false
            let index = currentDecodingFrame

            if !frames[index].decode(data, globalColormap: globalColormap, client: &client, frameDecoded: &frameDecoded) {
                return false
            }

            // We need more data to continue decoding.
            if !frameDecoded {
                break
            }

            if !client.frameComplete(frameIndex: index, delayTime: frames[index].delayTime, disposal: frames[index].disposalMethod) {
                return false
            }
            currentDecodingFrame += 1
        }

        // All frames decoded.
        if currentDecodingFrame == frames.count && parseCompleted {
            client.gifComplete()
        }
        return true
    }

    // GETN(n, s): requests at least 'n' bytes available, at start of state 's'.
    private mutating func getN(_ count: Int, _ newState: GIFState) {
        bytesToConsume = count
        state = newState
    }

    // Get a 16-bit value stored in little-endian format.
    private static func int16(_ span: Span<UInt8>, _ offset: Int) -> Int {
        Int(span[offset + 1]) << 8 | Int(span[offset])
    }

    private static func hasPrefix(_ span: Span<UInt8>, _ prefix: [UInt8]) -> Bool {
        if span.count < prefix.count {
            return false
        }
        for index in prefix.indices where span[index] != prefix[index] {
            return false
        }
        return true
    }

    private static let gif89a: [UInt8] = Array("GIF89a".utf8)
    private static let gif87a: [UInt8] = Array("GIF87a".utf8)
    private static let netscape20: [UInt8] = Array("NETSCAPE2.0".utf8)
    private static let animexts10: [UInt8] = Array("ANIMEXTS1.0".utf8)

    private var lastFrameIndex: Int {
        precondition(!frames.isEmpty)
        return frames.count - 1
    }

    // Parse incoming GIF data stream into internal data structures.
    // Return true if parsing has progressed or there is not enough data.
    // Return false if a fatal error is encountered.
    private mutating func parse(_ data: Span<UInt8>, dataPosition startPosition: Int, length: Int, parseSizeOnly: Bool, client: inout some GIFReaderClient) -> Bool {
        var dataPosition = startPosition
        var len = length
        if len == 0 {
            // No new data has come in since the last call, just ignore this call.
            return true
        }

        if len < bytesToConsume {
            return true
        }

        // This loop reads as many components from the data as possible.
        // At the beginning of each iteration, dataPosition will be advanced by bytesToConsume to
        // point to the next component. len will be decremented accordingly.
        while len >= bytesToConsume {
            let currentComponentPosition = dataPosition
            let currentComponent = data.extracting(dataPosition..<(dataPosition + bytesToConsume))

            // Mark the current component as consumed.
            dataPosition += bytesToConsume
            len -= bytesToConsume

            switch state {
            case .lzw:
                // bytesToConsume is the current component size because it hasn't been updated.
                frames[lastFrameIndex].addLzwBlock(position: currentComponentPosition, size: bytesToConsume)
                getN(1, .subBlock)

            case .lzwStart:
                frames[lastFrameIndex].setDataSize(Int(currentComponent[0]))
                getN(1, .subBlock)

            case .type:
                // All GIF files begin with "GIF87a" or "GIF89a".
                if Self.hasPrefix(currentComponent, Self.gif89a) {
                    version = 89
                } else if Self.hasPrefix(currentComponent, Self.gif87a) {
                    version = 87
                } else {
                    return false
                }
                getN(7, .globalHeader)

            case .globalHeader:
                // This is the height and width of the "screen" or frame into which images are rendered. The
                // individual images can be smaller than the screen size and located with an origin anywhere
                // within the screen.
                screenWidth = Self.int16(currentComponent, 0)
                screenHeight = Self.int16(currentComponent, 2)

                // CALLBACK: Inform the decoderplugin of our size.
                // Note: A subsequent frame might have dimensions larger than the "screen" dimensions.
                if !client.setSize(width: screenWidth, height: screenHeight) {
                    return false
                }

                screenBgcolor = Int(currentComponent[5])
                globalColormapSize = 2 << (currentComponent[4] & 0x07)

                if (currentComponent[4] & 0x80) != 0 && globalColormapSize > 0 { // global map
                    // Get the global colormap
                    let globalColormapBytes = 3 * globalColormapSize
                    globalColormapPosition = dataPosition

                    if len < globalColormapBytes {
                        // Wait until we have enough bytes to consume the entire colormap at once.
                        getN(globalColormapBytes, .globalColormap)
                        break
                    }

                    isGlobalColormapDefined = true
                    dataPosition += globalColormapBytes
                    len -= globalColormapBytes
                }

                getN(1, .imageStart)

                // currentComponent[6] = Pixel Aspect Ratio
                //   Not used

            case .globalColormap:
                isGlobalColormapDefined = true
                getN(1, .imageStart)

            case .imageStart:
                if currentComponent[0] == UInt8(ascii: ",") { // image separator.
                    getN(9, .imageHeader)
                    break
                }

                if currentComponent[0] == UInt8(ascii: "!") { // extension.
                    getN(2, .extension)
                    break
                }

                // If we get anything other than ',' (image separator), '!'
                // (extension), or ';' (trailer), there is extraneous data
                // between blocks. The GIF87a spec tells us to keep reading
                // until we find an image separator, but GIF89a says such
                // a file is corrupt. We follow major browsers' implementation
                // and proceed as if the file were correctly terminated, so the
                // GIF will display.
                getN(0, .done)

            case .extension:
                var bytesInBlock = Int(currentComponent[1])
                var es = GIFState.skipBlock

                switch currentComponent[0] {
                case 0xf9:
                    es = .controlExtension
                    // The GIF spec mandates that the GIFControlExtension header block length is 4 bytes,
                    // and the parser for this block reads 4 bytes, so we must enforce that the buffer
                    // contains at least this many bytes. If the GIF specifies a different length, we
                    // allow that, so long as it's larger; the additional data will simply be ignored.
                    bytesInBlock = max(bytesInBlock, 4)

                // The plain text extension (0x01) is ignored entirely; the application
                // extension header length is sanity-checked before it is read.
                case 0x01:
                    break

                case 0xff:
                    es = .applicationExtension

                case 0xfe:
                    es = .consumeComment

                default:
                    break
                }

                if bytesInBlock != 0 {
                    getN(bytesInBlock, es)
                } else {
                    getN(1, .imageStart)
                }

            case .consumeBlock:
                if currentComponent[0] == 0 {
                    getN(1, .imageStart)
                } else {
                    getN(Int(currentComponent[0]), .skipBlock)
                }

            case .skipBlock:
                getN(1, .consumeBlock)

            case .controlExtension:
                addFrameIfNecessary()
                let last = lastFrameIndex
                frames[last].isTransparent = (currentComponent[0] & 0x1) != 0
                if frames[last].isTransparent {
                    frames[last].tpixel = Int(currentComponent[3])
                }

                // We ignore the "user input" bit.

                // NOTE: This relies on the values in the DisposalMethod enum
                // matching those in the GIF spec!
                let disposalMethod = Int((currentComponent[0] >> 2) & 0x7)
                if let method = GIFDisposalMethod(rawValue: disposalMethod) {
                    frames[last].disposalMethod = method
                } else if disposalMethod == 4 {
                    // Some specs say that disposal method 3 is "overwrite previous", others that setting
                    // the third bit of the field (i.e. method 4) is. We map both to the same value.
                    frames[last].disposalMethod = .restoreToPrevious
                }
                frames[last].delayTime = Self.int16(currentComponent, 1) * 10
                getN(1, .consumeBlock)

            case .commentExtension:
                if currentComponent[0] != 0 {
                    getN(Int(currentComponent[0]), .consumeComment)
                } else {
                    getN(1, .imageStart)
                }

            case .consumeComment:
                getN(1, .commentExtension)

            case .applicationExtension:
                // Check for netscape application extension.
                if bytesToConsume == 11 && (Self.hasPrefix(currentComponent, Self.netscape20) || Self.hasPrefix(currentComponent, Self.animexts10)) {
                    getN(1, .netscapeExtensionBlock)
                } else {
                    getN(1, .consumeBlock)
                }

            // Netscape-specific GIF extension: animation looping.
            case .netscapeExtensionBlock:
                // GIFConsumeNetscapeExtension always reads 3 bytes from the stream; we should at least wait for this amount.
                if currentComponent[0] != 0 {
                    getN(max(3, Int(currentComponent[0])), .consumeNetscapeExtension)
                } else {
                    getN(1, .imageStart)
                }

            // Parse netscape-specific application extensions
            case .consumeNetscapeExtension:
                let netscapeExtension = currentComponent[0] & 7

                // Loop entire animation specified # of times. Only read the loop count during the first iteration.
                if netscapeExtension == 1 {
                    loopCount = Self.int16(currentComponent, 1)

                    // Zero loop count is infinite animation loop request.
                    if loopCount == 0 {
                        loopCount = gifRepetitionCountInfinite
                    }

                    getN(1, .netscapeExtensionBlock)
                } else if netscapeExtension == 2 {
                    // Wait for specified # of bytes to enter buffer.

                    // Don't do this, this extension doesn't exist (isn't used at all)
                    // and doesn't do anything, as our streaming/buffering takes care of it all...
                    // See: http://semmix.pl/color/exgraf/eeg24.htm
                    getN(1, .netscapeExtensionBlock)
                } else {
                    // 0,3-7 are yet to be defined netscape extension codes
                    return false
                }

            case .imageHeader:
                // Get image offsets, with respect to the screen origin
                var xOffset = Self.int16(currentComponent, 0)
                var yOffset = Self.int16(currentComponent, 2)

                // Get image width and height.
                var width = Self.int16(currentComponent, 4)
                var height = Self.int16(currentComponent, 6)

                // Work around broken GIF files where the logical screen
                // size has weird width or height.  We assume that GIF87a
                // files don't contain animations.
                if currentFrameIsFirstFrame
                    && (screenHeight < height || screenWidth < width || version == 87) {
                    screenHeight = height
                    screenWidth = width
                    xOffset = 0
                    yOffset = 0

                    // CALLBACK: Inform the decoderplugin of our size.
                    if !client.setSize(width: screenWidth, height: screenHeight) {
                        return false
                    }
                }

                // Work around more broken GIF files that have zero image width or height
                if height == 0 || width == 0 {
                    height = screenHeight
                    width = screenWidth
                    if height == 0 || width == 0 {
                        return false
                    }
                }

                if parseSizeOnly {
                    // The decoder needs to stop. Hand back the number of bytes we consumed from
                    // buffer minus 9 (the amount we consumed to read the header).
                    setRemainingBytes(len + 9, dataCount: data.count)
                    getN(9, .imageHeader)
                    return true
                }

                addFrameIfNecessary()
                let last = lastFrameIndex

                frames[last].setHeaderDefined()
                frames[last].xOffset = xOffset
                frames[last].yOffset = yOffset
                frames[last].height = height
                frames[last].width = width
                screenWidth = max(screenWidth, width)
                screenHeight = max(screenHeight, height)
                frames[last].interlaced = (currentComponent[8] & 0x40) != 0

                // Overlaying interlaced, transparent GIFs over
                // existing image data using the Haeberli display hack
                // requires saving the underlying image in order to
                // avoid jaggies at the transparency edges. We are
                // unprepared to deal with that, so don't display such
                // images progressively. Which means only the first
                // frame can be progressively displayed.
                frames[last].progressiveDisplay = currentFrameIsFirstFrame

                let isLocalColormapDefined = (currentComponent[8] & 0x80) != 0
                if isLocalColormapDefined {
                    // The three low-order bits of currentComponent[8] specify the bits per pixel.
                    let numColors = 2 << (currentComponent[8] & 0x7)
                    let localColormapBytes = 3 * numColors

                    // Switch to the new local palette after it loads
                    frames[last].localColormapPosition = dataPosition
                    frames[last].localColormapSize = numColors

                    if len < localColormapBytes {
                        // Wait until we have enough bytes to consume the entire colormap at once.
                        getN(localColormapBytes, .imageColormap)
                        break
                    }

                    frames[last].isLocalColormapDefined = true
                    dataPosition += localColormapBytes
                    len -= localColormapBytes
                } else {
                    // Switch back to the global palette
                    frames[last].isLocalColormapDefined = false
                }
                getN(1, .lzwStart)

            case .imageColormap:
                frames[lastFrameIndex].isLocalColormapDefined = true
                getN(1, .lzwStart)

            case .subBlock:
                let bytesInBlock = Int(currentComponent[0])
                if bytesInBlock != 0 {
                    getN(bytesInBlock, .lzw)
                } else {
                    // Finished parsing one frame; Process next frame.
                    // Note that some broken GIF files do not have enough LZW blocks to fully
                    // decode all rows but we treat it as frame complete.
                    frames[lastFrameIndex].setComplete()
                    getN(1, .imageStart)
                }

            case .done:
                parseCompleted = true
                return true

            case .imageBody:
                // We shouldn't ever get here.
                return false
            }
        }

        setRemainingBytes(len, dataCount: data.count)
        return true
    }

    private mutating func setRemainingBytes(_ remainingBytes: Int, dataCount: Int) {
        precondition(remainingBytes <= dataCount)
        bytesRead = dataCount - remainingBytes
    }

    private mutating func addFrameIfNecessary() {
        if frames.isEmpty || frames[frames.count - 1].isComplete {
            frames.append(GIFFrameContext(frameId: frames.count))
        }
    }

    private var currentFrameIsFirstFrame: Bool {
        frames.isEmpty || (frames.count == 1 && !frames[0].isComplete)
    }
}

#endif // ENABLE_IMAGE_DECODERS_SWIFT
