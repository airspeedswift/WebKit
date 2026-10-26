//
// Copyright (c) 2008-2009 Google Inc. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are
// met:
//
//     * Redistributions of source code must retain the above copyright
// notice, this list of conditions and the following disclaimer.
//     * Redistributions in binary form must reproduce the above
// copyright notice, this list of conditions and the following disclaimer
// in the documentation and/or other materials provided with the
// distribution.
//     * Neither the name of Google Inc. nor the names of its
// contributors may be used to endorse or promote products derived from
// this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
// "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
// LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
// A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
// OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
// SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
// LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
// DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
// THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//

// Swift port of the ICO/CUR directory parsing in ICOImageDecoder.cpp:
// processDirectory, processDirectoryEntries (incl. the quality sort), readDirectoryEntry,
// compareEntries, imageTypeAtIndex, hotSpotAtIndex, frameSizeAtIndex, size/setSize.
// WebCore-free: the bytes arrive as a Span<UInt8> (the decoder's whole data so far), and
// every read is bounds-checked. No unsafe code.
//
// Behavioural notes (differential-tested against the verbatim C++ in /tmp/imgdec/P1-C):
//  * decodeDirectory() returns .needMoreData where the C++ returns false without failing,
//    .failed where it calls setFailed(), .ok where it returns true. Calling it again after
//    .failed returns .failed and does nothing (ICOImageDecoder::decode's failed() check).
//  * After the ICONDIR is accepted, `entries` holds idCount zero-valued entries until the
//    entries themselves are read, exactly like the C++ m_dirEntries.resize(idCount).
//  * The entries are ordered best-first with a STABLE sort. The C++ uses std::sort, whose
//    order among entries of equal (area, bitCount) is unspecified; the two can differ there
//    and only there (e.g. which of a 16x32 and a 32x16 icon, or which of two equal-quality
//    cursors' hot spots, is entry 0).
//  * Out-of-range indices: the C++ ASSERT_WITH_SECURITY_IMPLICATION(index < count) in
//    imageTypeAtIndex is replaced by returning .unknown.

struct ICODirectory {
    // Number of bytes in .ICO/.CUR used to store the directory and its entries.
    static let sizeOfDirectory = 6
    static let sizeOfDirEntry = 16

    enum FileType: UInt16 {
        case icon = 1
        case cursor = 2
    }

    enum ImageType {
        case unknown
        case bmp
        case png
    }

    enum Status {
        case needMoreData
        case failed
        case ok
    }

    struct IntSize: Equatable, Hashable {
        var width: Int
        var height: Int
        static let zero = IntSize(width: 0, height: 0)
        var isEmpty: Bool { width <= 0 || height <= 0 }
    }

    struct IntPoint: Equatable, Hashable {
        var x: Int
        var y: Int
        static let zero = IntPoint(x: 0, y: 0)
    }

    struct Entry: Equatable, Hashable {
        var size: IntSize // each of width, height in 1...256 once read
        var bitCount: UInt16
        var hotSpot: IntPoint
        var imageOffset: UInt32
        static let zero = Entry(size: .zero, bitCount: 0, hotSpot: .zero, imageOffset: 0)
    }

    /// How much of the data this parser has consumed (m_decodedOffset).
    private(set) var decodedOffset = 0
    /// nil until the ICONDIR has been accepted (m_fileType).
    private(set) var fileType: FileType?
    private(set) var entries: [Entry] = []
    private(set) var failed = false
    /// The size recorded by setSize() (ScalableImageDecoder::m_size), if any.
    private var recordedSize: IntSize?

    init() { }

    // MARK: - Public queries

    /// ICOImageDecoder::size(): the largest entry's size once the directory is decoded.
    var size: IntSize {
        // m_frameSize is always empty outside BMP decoding, so this is ScalableImageDecoder::size().
        guard !failed, let recordedSize else { return .zero }
        return recordedSize
    }

    /// ICOImageDecoder::frameSizeAtIndex.
    func frameSize(at index: Int) -> IntSize {
        (index > 0 && index < entries.count) ? entries[index].size : size
    }

    /// ICOImageDecoder::hotSpotAtIndex.
    func hotSpot(at index: Int) -> IntPoint? {
        guard index >= 0, index < entries.count, fileType == .cursor else { return nil }
        return entries[index].hotSpot
    }

    /// ICOImageDecoder::imageTypeAtIndex: needs 4 bytes at the entry's offset.
    func imageType(at index: Int, in data: Span<UInt8>) -> ImageType {
        guard index >= 0, index < entries.count else { return .unknown }
        // C++: `imageOffset > size || size - imageOffset < 4` -> Unknown. An
        // offset that does not fit in Int (>= 2^31, 32-bit Int only) is > size,
        // so it is Unknown as well; no trapping Int() on the file field.
        guard let imageOffset = Int(exactly: entries[index].imageOffset),
            imageOffset <= data.count, data.count - imageOffset >= 4 else {
            return .unknown
        }
        let isPNG = data[imageOffset] == 0x89 && data[imageOffset + 1] == 0x50
            && data[imageOffset + 2] == 0x4E && data[imageOffset + 3] == 0x47 // "\x89PNG"
        return isPNG ? .png : .bmp
    }

    // MARK: - Decoding

    /// ICOImageDecoder::decodeDirectory. `data` is all the data received so far.
    mutating func decodeDirectory(_ data: Span<UInt8>) -> Status {
        if failed {
            return .failed
        }
        // Read and process directory.
        if decodedOffset < Self.sizeOfDirectory && !processDirectory(data) {
            return failed ? .failed : .needMoreData
        }
        // Read and process directory entries.
        if decodedOffset >= Self.sizeOfDirectory + entries.count * Self.sizeOfDirEntry {
            return .ok
        }
        if processDirectoryEntries(data) {
            return .ok
        }
        return failed ? .failed : .needMoreData
    }

    // MARK: - Private

    private func readUint16(_ data: Span<UInt8>, _ offset: Int) -> UInt16 {
        let at = decodedOffset + offset
        return UInt16(data[at]) | UInt16(data[at + 1]) << 8
    }

    private func readUint32(_ data: Span<UInt8>, _ offset: Int) -> UInt32 {
        let at = decodedOffset + offset
        return UInt32(data[at]) | UInt32(data[at + 1]) << 8 | UInt32(data[at + 2]) << 16 | UInt32(data[at + 3]) << 24
    }

    private mutating func setFailed() -> Bool {
        failed = true
        return false
    }

    /// ScalableImageDecoder::setSize (ICOImageDecoder::setSize with an empty m_frameSize).
    private mutating func setSize(_ size: IntSize) -> Bool {
        // ImageBackingStore::isOverSize: more than (1 << 29) - 1 pixels. Entry sizes are
        // at most 256 x 256, so this cannot fire; kept for parity.
        let maxPixels = (1 << 29) - 1
        if size.width * size.height > maxPixels {
            return setFailed()
        }
        recordedSize = size
        return true
    }

    private mutating func processDirectory(_ data: Span<UInt8>) -> Bool {
        assert(decodedOffset == 0)
        if data.count < Self.sizeOfDirectory {
            return false
        }
        let fileType = readUint16(data, 2)
        let idCount = readUint16(data, 4)
        decodedOffset = Self.sizeOfDirectory

        // See if this is an icon filetype we understand, and make sure we have at
        // least one entry in the directory.
        guard let type = FileType(rawValue: fileType), idCount != 0 else {
            return setFailed()
        }
        self.fileType = type
        entries = Array(repeating: .zero, count: Int(idCount))
        return true
    }

    private mutating func processDirectoryEntries(_ data: Span<UInt8>) -> Bool {
        assert(decodedOffset == Self.sizeOfDirectory)
        if decodedOffset > data.count || data.count - decodedOffset < entries.count * Self.sizeOfDirEntry {
            return false
        }
        for index in entries.indices {
            entries[index] = readDirectoryEntry(data) // Updates decodedOffset.
        }

        // Make sure the specified image offsets are past the end of the directory entries.
        // C++ compares uint32_t with size_t; compare in UInt (exact for both
        // operands: UInt(UInt32) widens, decodedOffset >= 0) so a file offset
        // >= 2^31 cannot trap in Int() with 32-bit Int.
        for entry in entries where UInt(entry.imageOffset) < UInt(decodedOffset) {
            return setFailed()
        }

        // Arrange frames in decreasing quality order (stable among equals).
        entries = entries.enumerated().sorted { a, b in
            if Self.isBetter(a.element, than: b.element) {
                return true
            }
            if Self.isBetter(b.element, than: a.element) {
                return false
            }
            return a.offset < b.offset
        }.map(\.element)

        // The image size is the size of the largest entry.
        return setSize(entries[0].size)
    }

    /// ICOImageDecoder::compareEntries: larger icons are better; after that, higher bit depth.
    static func isBetter(_ a: Entry, than b: Entry) -> Bool {
        let aEntryArea = a.size.width * a.size.height
        let bEntryArea = b.size.width * b.size.height
        return aEntryArea == bEntryArea ? a.bitCount > b.bitCount : aEntryArea > bEntryArea
    }

    private mutating func readDirectoryEntry(_ data: Span<UInt8>) -> Entry {
        // A zero byte for width or height means 256.
        var width = Int(data[decodedOffset])
        if width == 0 {
            width = 256
        }
        var height = Int(data[decodedOffset + 1])
        if height == 0 {
            height = 256
        }
        var bitCount: UInt16
        let hotSpot: IntPoint
        if fileType == .cursor {
            bitCount = 0
            hotSpot = IntPoint(x: Int(readUint16(data, 4)), y: Int(readUint16(data, 6)))
        } else {
            bitCount = readUint16(data, 6)
            hotSpot = .zero
        }
        let imageOffset = readUint32(data, 12)

        // Some icons don't have a bit depth, only a color count. Convert the color count to
        // the minimum necessary bit depth (at most 8).
        if bitCount == 0 {
            var colorCount = Int(data[decodedOffset + 2])
            if colorCount == 0 {
                colorCount = 256 // Vague in the spec, needed by real-world icons.
            }
            colorCount -= 1
            while colorCount != 0 {
                bitCount += 1
                colorCount >>= 1
            }
        }

        decodedOffset += Self.sizeOfDirEntry
        return Entry(size: IntSize(width: width, height: height), bitCount: bitCount, hotSpot: hotSpot, imageOffset: imageOffset)
    }
}
