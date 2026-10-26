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

// PROTOTYPE: Swift port of WebCore::ImageBackingStore (graphics/ImageBackingStore.h)
// and WebCore::ScalableImageDecoderFrame (image-decoders/ScalableImageDecoderFrame.{h,cpp}).
// Not yet in WebCore.xcodeproj.
//
//  * Pixels are a Swift-owned [UInt32] (one ARGB word per pixel, the layout of
//    ImageBackingStore::m_pixelsSpan). No pointer ever escapes, so the file has
//    no `unsafe`. Both types are value types: copying one is the C++ copy
//    constructor / operator= (ImageBackingStore(const ImageBackingStore&),
//    ScalableImageDecoderFrame::operator=), with copy-on-write doing the deep copy.
//  * Pixel addresses are flat indices (`pixelIndex(x:y:)`) instead of
//    std::span<uint32_t> / uint32_t&; every subscript is bounds-checked.
//  * Sizes are WebCore's `int` (Int32). Every size product is computed with
//    overflow reporting and takes the C++ failure path (create() == nullptr /
//    initialize() == false) on overflow, including where Int is 32 bits.
//  * The colour arithmetic (fastDivideBy255, premultipliedFlooring,
//    unpremultiplied, PackedColor::ARGB) is copied from the Color headers;
//    each function cites its source line.

#if ENABLE_IMAGE_DECODERS_SWIFT

// MARK: - IntRect

/// Mirrors WebCore::IntRect for the operations ImageBackingStore uses. maxX/maxY
/// are computed in Int64: C++ `x() + width()` is int arithmetic that overflows
/// (UB) for extreme rects; for every non-overflowing rect the results agree.
struct PixelRect: Equatable {
    var x: Int32
    var y: Int32
    var width: Int32
    var height: Int32

    init(x: Int32, y: Int32, width: Int32, height: Int32) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    init(size: PixelSize) {
        self.init(x: 0, y: 0, width: size.width, height: size.height)
    }

    var maxX: Int64 { Int64(x) + Int64(width) }
    var maxY: Int64 { Int64(y) + Int64(height) }

    /// IntSize::isEmpty (IntSize.h:77): handles negative widths too.
    var isEmpty: Bool { width <= 0 || height <= 0 }

    /// IntRect::contains(const IntRect&) (IntRect.cpp:61-65).
    func contains(_ other: PixelRect) -> Bool {
        Int64(x) <= Int64(other.x) && maxX >= other.maxX && Int64(y) <= Int64(other.y) && maxY >= other.maxY
    }

    /// IntRect::contains(int, int) (IntRect.h:176-177).
    func contains(x px: Int32, y py: Int32) -> Bool {
        Int64(px) >= Int64(x) && Int64(px) < maxX && Int64(py) >= Int64(y) && Int64(py) < maxY
    }
}

extension PixelSize {
    /// IntSize::isEmpty (IntSize.h:77).
    var isEmpty: Bool { width <= 0 || height <= 0 }
}

// MARK: - Colour arithmetic

/// SRGBA<uint8_t>.
struct SRGBA8: Equatable {
    var red: UInt8
    var green: UInt8
    var blue: UInt8
    var alpha: UInt8
}

enum ImageBackingStoreColor {
    /// ColorUtilities.h:252-255 fastMultiplyBy255: `(value << 8) - value` in uint16_t.
    /// Only called with value <= 255 (a colour component), where it cannot overflow.
    static func fastMultiplyBy255(_ value: UInt16) -> UInt16 {
        (value << 8) - value
    }

    /// ColorUtilities.h:257-263 fastDivideBy255. Exact for every 16-bit input
    /// (verified exhaustively against the C++ in the harness); no intermediate
    /// can overflow: approximation*255 <= value, remainder + 1 <= 511.
    static func fastDivideBy255(_ value: UInt16) -> UInt16 {
        let approximation = value >> 8
        let remainder = value - (approximation * 255) + 1
        return approximation + (remainder >> 8)
    }

    /// clampedComponent (ColorTypes.h:66-72) for SRGBA<uint8_t>, componentInfo [0, 255].
    private static func clampedComponent(_ value: UInt16) -> UInt8 {
        UInt8(min(value, 255))
    }

    /// premultipliedFlooring(SRGBA<uint8_t>) (ColorUtilities.cpp:45-53).
    static func premultipliedFlooring(_ color: SRGBA8) -> SRGBA8 {
        let a = color.alpha
        if a == 0 {
            return SRGBA8(red: 0, green: 0, blue: 0, alpha: 0)
        }
        if a == 255 {
            return color
        }
        func premultiply(_ c: UInt8) -> UInt8 { clampedComponent(fastDivideBy255(UInt16(c) * UInt16(a))) }
        return SRGBA8(red: premultiply(color.red), green: premultiply(color.green), blue: premultiply(color.blue), alpha: a)
    }

    /// unpremultipliedComponentByte (ColorUtilities.cpp:65-68):
    /// `(fastMultiplyBy255(c) + a - 1) / a`, int arithmetic, returned as uint16_t.
    /// a >= 1 here; the numerator is at most 65025 + 254.
    private static func unpremultipliedComponentByte(_ c: UInt8, _ a: UInt8) -> UInt16 {
        UInt16((UInt32(fastMultiplyBy255(UInt16(c))) + UInt32(a) - 1) / UInt32(a))
    }

    /// unpremultiplied(SRGBA<uint8_t>) (ColorUtilities.cpp:70-76).
    static func unpremultiplied(_ color: SRGBA8) -> SRGBA8 {
        let a = color.alpha
        if a == 0 || a == 255 {
            return color
        }
        return SRGBA8(
            red: clampedComponent(unpremultipliedComponentByte(color.red, a)),
            green: clampedComponent(unpremultipliedComponentByte(color.green, a)),
            blue: clampedComponent(unpremultipliedComponentByte(color.blue, a)),
            alpha: a)
    }

    /// PackedColor::ARGB(ResolvedColorType<SRGBA<uint8_t>>) (ColorTypes.h:742-745).
    static func packARGB(_ color: SRGBA8) -> UInt32 {
        UInt32(color.alpha) << 24 | UInt32(color.red) << 16 | UInt32(color.green) << 8 | UInt32(color.blue)
    }

    /// asSRGBA(PackedColor::ARGB) (ColorTypes.h:762-765).
    static func unpackARGB(_ value: UInt32) -> SRGBA8 {
        SRGBA8(red: UInt8(truncatingIfNeeded: value >> 16), green: UInt8(truncatingIfNeeded: value >> 8), blue: UInt8(truncatingIfNeeded: value), alpha: UInt8(truncatingIfNeeded: value >> 24))
    }
}

// MARK: - ImageBackingStore

/// Port of WebCore::ImageBackingStore (ImageBackingStore.h:45-258), minus image(),
/// which is platform code (see ScalableImageDecoderCore.swift for the CG one).
struct ImageBackingStore: Equatable {
    /// ImageBackingStore.h:42 cairoMaxImageSize (USE(CAIRO) only).
    static let cairoMaxImageSize: Int32 = 32768

    /// ImageBackingStore.h:205 MaxPixels.
    static let maxPixels: UInt64 = (1 << 29) - 1

    private(set) var pixels: [UInt32]
    private(set) var size: PixelSize
    private(set) var frameRect: PixelRect
    let premultiplyAlpha: Bool

    /// ImageBackingStore::create(const IntSize&, bool) (ImageBackingStore.h:48-54).
    ///
    /// Divergence (stricter): the C++ constructor only ASSERTs
    /// `!size.isEmpty() && !isOverSize(size)` and then RELEASE_ASSERTs setSize()
    /// (CrashOnOverflow on area()*4, or allocation failure). Here an empty,
    /// over-size or overflowing size returns nil: the C++ failure path of
    /// create() (nullptr), which ScalableImageDecoderFrame::initialize turns into
    /// `false`.
    static func create(size: PixelSize, premultiplyAlpha: Bool = true) -> ImageBackingStore? {
        guard !size.isEmpty, !isOverSize(size, cairoMaxImageSize: nil) else { return nil }
        var store = ImageBackingStore(premultiplyAlpha: premultiplyAlpha)
        guard store.setSize(size) else { return nil }
        return store
    }

    private init(premultiplyAlpha: Bool) {
        pixels = []
        size = PixelSize(width: 0, height: 0)
        frameRect = PixelRect(x: 0, y: 0, width: 0, height: 0)
        self.premultiplyAlpha = premultiplyAlpha
    }

    /// The number of pixels (and of UInt32 words) of `size`, or nil when the
    /// size is empty or `width*height*4` (ImageBackingStore.h:71, the byte count)
    /// does not fit in the C++ `Checked<unsigned>` or in Int.
    static func pixelCount(_ size: PixelSize) -> Int? {
        guard !size.isEmpty else { return nil }
        let (area, areaOverflow) = Int(size.width).multipliedReportingOverflow(by: Int(size.height))
        guard !areaOverflow else { return nil }
        let (bytes, bytesOverflow) = area.multipliedReportingOverflow(by: 4)
        guard !bytesOverflow, UInt64(bytes) <= UInt64(UInt32.max) else { return nil }
        return area
    }

    /// ImageBackingStore::setSize (ImageBackingStore.h:65-83).
    mutating func setSize(_ newSize: PixelSize) -> Bool {
        guard let count = Self.pixelCount(newSize) else { return false }
        pixels = Array(repeating: 0, count: count)
        size = newSize
        frameRect = PixelRect(size: newSize)
        return true
    }

    /// ImageBackingStore::setFrameRect (ImageBackingStore.h:85-90). The C++
    /// ASSERTs are preconditions here.
    mutating func setFrameRect(_ rect: PixelRect) {
        precondition(!size.isEmpty)
        precondition(inBounds(rect))
        frameRect = rect
    }

    /// ImageBackingStore::clear (ImageBackingStore.h:95-98).
    mutating func clear() {
        for i in pixels.indices {
            pixels[i] = 0
        }
    }

    /// ImageBackingStore::clearRect (ImageBackingStore.h:100-111). No-op for an
    /// empty or out-of-bounds rect.
    mutating func clearRect(_ rect: PixelRect) {
        fill(rect, with: 0)
    }

    /// ImageBackingStore::fillRect (ImageBackingStore.h:113-126). No-op for an
    /// empty or out-of-bounds rect.
    mutating func fillRect(_ rect: PixelRect, r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        fill(rect, with: pixelValue(r: r, g: g, b: b, a: a))
    }

    private mutating func fill(_ rect: PixelRect, with value: UInt32) {
        guard !rect.isEmpty, inBounds(rect) else { return }
        // In bounds: every index below is < width*height, which fits in Int.
        let rowWidth = Int(size.width)
        let rectWidth = Int(rect.width)
        for row in 0..<Int(rect.height) {
            let start = (Int(rect.y) + row) * rowWidth + Int(rect.x)
            for i in start..<(start + rectWidth) {
                pixels[i] = value
            }
        }
    }

    /// ImageBackingStore::repeatFirstRow (ImageBackingStore.h:128-141): copies
    /// the rect's first row into each following row of the rect.
    ///
    /// Divergence: for a one-row rect on the last row with x > 0, C++
    /// `sourcePixels.subspan(m_size.width())` (ImageBackingStore.h:134) has an
    /// offset past the span's end; hardened libc++ traps (UB without hardening),
    /// although the loop then copies nothing. Here it copies nothing.
    mutating func repeatFirstRow(_ rect: PixelRect) {
        guard !rect.isEmpty, inBounds(rect) else { return }
        let rowWidth = Int(size.width)
        let rectWidth = Int(rect.width)
        let source = Int(rect.y) * rowWidth + Int(rect.x)
        var destination = source
        for _ in 1..<Int(rect.height) { // height >= 1: the rect is not empty
            destination += rowWidth
            for j in 0..<rectWidth {
                pixels[destination + j] = pixels[source + j]
            }
        }
    }

    /// The flat index of (x, y): pixelsStartingAt / pixelAt
    /// (ImageBackingStore.h:143-153). The C++ ASSERT(inBounds) is a precondition.
    func pixelIndex(x: Int32, y: Int32) -> Int {
        precondition(inBounds(x: x, y: y))
        return Int(y) * Int(size.width) + Int(x)
    }

    /// Raw ARGB access by flat index (the C++ `uint32_t&` from pixelAt or a span).
    subscript(index: Int) -> UInt32 {
        get { pixels[index] }
        set { pixels[index] = newValue }
    }

    func pixelAt(x: Int32, y: Int32) -> UInt32 {
        pixels[pixelIndex(x: x, y: y)]
    }

    /// ImageBackingStore::setPixel(uint32_t&, ...) (ImageBackingStore.h:155-158).
    mutating func setPixel(at index: Int, r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        pixels[index] = pixelValue(r: r, g: g, b: b, a: a)
    }

    /// ImageBackingStore::setPixel(int, int, ...) (ImageBackingStore.h:160-163).
    mutating func setPixel(x: Int32, y: Int32, r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        setPixel(at: pixelIndex(x: x, y: y), r: r, g: g, b: b, a: a)
    }

    /// ImageBackingStore::blendPixel (ImageBackingStore.h:165-193).
    ///
    /// Every UInt8 conversion below is exact: r*a + c*(255-a) <= 255*255, so the
    /// quotient is <= 255, and alpha + (255-alpha')*alpha/255 <= 255.
    mutating func blendPixel(at index: Int, r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        if a == 0 {
            return
        }

        var pixel = ImageBackingStoreColor.unpackARGB(pixels[index])

        if a >= 255 || pixel.alpha == 0 {
            setPixel(at: index, r: r, g: g, b: b, a: a)
            return
        }

        if !premultiplyAlpha {
            pixel = ImageBackingStoreColor.premultipliedFlooring(pixel)
        }

        let d = 255 - a

        func blend(_ source: UInt8, _ destination: UInt8) -> UInt8 {
            UInt8(ImageBackingStoreColor.fastDivideBy255(UInt16(source) * UInt16(a) + UInt16(destination) * UInt16(d)))
        }

        var result = SRGBA8(
            red: blend(r, pixel.red),
            green: blend(g, pixel.green),
            blue: blend(b, pixel.blue),
            alpha: a + UInt8(ImageBackingStoreColor.fastDivideBy255(UInt16(d) * UInt16(pixel.alpha))))

        if !premultiplyAlpha {
            result = ImageBackingStoreColor.unpremultiplied(result)
        }

        pixels[index] = ImageBackingStoreColor.packARGB(result)
    }

    mutating func blendPixel(x: Int32, y: Int32, r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        blendPixel(at: pixelIndex(x: x, y: y), r: r, g: g, b: b, a: a)
    }

    /// ImageBackingStore::isOverSize (ImageBackingStore.h:195-208).
    /// `cairoMaxImageSize` is ImageBackingStore.h:42 when built USE(CAIRO), else nil.
    ///
    /// The product is C++ `unsigned long long` arithmetic on the sign-extended
    /// ints, which wraps mod 2^64 for negative sizes; it is reproduced exactly.
    static func isOverSize(_ size: PixelSize, cairoMaxImageSize: Int32?) -> Bool {
        if let cairoMaxImageSize, size.width > cairoMaxImageSize || size.height > cairoMaxImageSize {
            return true
        }
        let width = UInt64(truncatingIfNeeded: Int64(size.width))
        let height = UInt64(truncatingIfNeeded: Int64(size.height))
        let pixels = width &* height // wrapping: C++ unsigned long long multiplication (ImageBackingStore.h:206) is modular
        return pixels > maxPixels
    }

    /// inBounds(const IntPoint&) (ImageBackingStore.h:229-232).
    func inBounds(x: Int32, y: Int32) -> Bool {
        PixelRect(size: size).contains(x: x, y: y)
    }

    /// inBounds(const IntRect&) (ImageBackingStore.h:234-237).
    func inBounds(_ rect: PixelRect) -> Bool {
        PixelRect(size: size).contains(rect)
    }

    /// pixelValue (ImageBackingStore.h:239-250).
    func pixelValue(r: UInt8, g: UInt8, b: UInt8, a: UInt8) -> UInt32 {
        if premultiplyAlpha && a == 0 {
            return 0
        }

        var result = SRGBA8(red: r, green: g, blue: b, alpha: a)

        if premultiplyAlpha && a < 255 {
            result = ImageBackingStoreColor.premultipliedFlooring(result)
        }

        return ImageBackingStoreColor.packARGB(result)
    }
}

// MARK: - ScalableImageDecoderFrame

/// Port of WebCore::ScalableImageDecoderFrame (ScalableImageDecoderFrame.{h,cpp}).
/// Assignment is ScalableImageDecoderFrame::operator= (a deep copy of the
/// backing store); `ScalableImageDecoderFrame()` is the default constructor.
struct ScalableImageDecoderFrame: Equatable {
    enum DisposalMethod: UInt8 {
        case unspecified, doNotDispose, restoreToBackground, restoreToPrevious
    }

    private var status: DecodingStatus = .invalid
    private(set) var backingStore: ImageBackingStore?
    var disposalMethod: DisposalMethod = .unspecified
    var orientation: ImageOrientation = .none
    /// Seconds.
    var duration: Double = 0
    private var hasAlphaFlag = true

    init() { }

    /// ScalableImageDecoderFrame::clear (ScalableImageDecoderFrame.cpp:68-71).
    mutating func clear() {
        self = ScalableImageDecoderFrame()
    }

    /// initialize(const ImageBackingStore&) (ScalableImageDecoderFrame.cpp:73-80).
    /// ImageBackingStore::create(other) cannot fail for a constructed store.
    @discardableResult
    mutating func initialize(copying other: ImageBackingStore) -> Bool {
        backingStore = other
        return true
    }

    /// initialize(const IntSize&, bool) (ScalableImageDecoderFrame.cpp:82-89).
    @discardableResult
    mutating func initialize(size: PixelSize, premultiplyAlpha: Bool) -> Bool {
        if size.isEmpty {
            return false
        }
        backingStore = ImageBackingStore.create(size: size, premultiplyAlpha: premultiplyAlpha)
        return backingStore != nil
    }

    /// ScalableImageDecoderFrame.cpp:56-66; the ASSERTs are preconditions.
    var decodingStatus: DecodingStatus {
        get {
            precondition(status != .decoding)
            return status
        }
        set {
            precondition(newValue != .decoding)
            status = newValue
        }
    }

    var isInvalid: Bool { status == .invalid }
    var isPartial: Bool { status == .partial }
    var isComplete: Bool { status == .complete }

    /// ScalableImageDecoderFrame.cpp:91-96.
    var size: PixelSize { backingStore?.size ?? PixelSize(width: 0, height: 0) }

    mutating func setHasAlpha(_ hasAlpha: Bool) { hasAlphaFlag = hasAlpha }
    var hasAlpha: Bool { !hasMetadata || hasAlphaFlag }
    var hasMetadata: Bool { !size.isEmpty }
    var hasBackingStore: Bool { backingStore != nil }

    /// Mutates the backing store in place; does nothing without one (C++
    /// callers null-check backingStore() first).
    mutating func withBackingStore<R>(_ body: (inout ImageBackingStore) -> R) -> R? {
        guard backingStore != nil else { return nil }
        return body(&backingStore!)
    }
}

#endif // ENABLE_IMAGE_DECODERS_SWIFT
