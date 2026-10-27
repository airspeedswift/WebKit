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

// PROTOTYPE: the platform-neutral Swift-side contract of WebCore::ImageDecoder
// (ImageDecoder.h). Not yet in WebCore.xcodeproj.
//
// This file imports nothing: it is compiled for GTK/WPE (no CoreGraphics, no
// Foundation) as well as for Cocoa. The Cocoa-only half (CGImage output,
// ImageDecoderCGCore's conformance, the CG factory) is cg/ImageDecodingCG.swift.
//
// Shape, and why:
//  * `protocol ImageDecoding` has one requirement per ImageDecoder.h virtual
//    EXCEPT the two whose C++ return type is per port: createFrameImageAtIndex
//    (PlatformImagePtr = RetainPtr<CGImageRef> / RefPtr<cairo_surface_t> /
//    sk_sp<SkImage>, PlatformImage.h:44-48) and frameGainMapAtIndex. Swift has
//    no type that is all three, so frame output is a refinement per output
//    representation, each with its requirement PURE (no silent nil default):
//      - `PixelBufferImageDecoding` (here): frames leave Swift as Swift-owned
//        pixels, `ImageDecoderFramePixels`. The ScalableImageDecoder family
//        (GIF/BMP/ICO/PNG/JPEG/WebP) conforms; the C++ adapter turns the pixels
//        into the port's native image with the EXISTING per-port
//        ImageBackingStore::image() (cg/ImageBackingStoreCG.cpp:37-56,
//        image-decoders/skia/ImageBackingStoreSkia.cpp:36-44,
//        image-decoders/cairo/ImageBackingStoreCairo.cpp:34-47). No Swift code
//        creates a native image for this family.
//      - `CGImageDecoding` (cg/ImageDecodingCG.swift, Cocoa only): the
//        ImageIO-backed decoder, whose frames are CGImages created by ImageIO.
//    The 14 remaining pure virtuals are plain requirements; the 17 virtuals
//    with a body in ImageDecoder.h/.cpp that are not per port get that body,
//    verbatim, in the protocol extension below. A requirement with a default
//    dispatches dynamically like a C++ virtual: a conformer's implementation
//    wins, even when called through `any ImageDecoding`.
//  * The protocol is `AnyObject, Sendable` because ImageDecoder is shared
//    between the main thread and ImageFrameWorkQueue (bugs.webkit.org/273801).
//    A conformer with unprotected mutable state does not compile.
//  * A protocol cannot be exposed to C++ (Swift 6.4: "can not yet be
//    represented in C++"), so C++ holds `AnyImageDecoder`, a final class that
//    boxes `any ImageDecoding`. Its API uses only C++-representable types
//    (integers, Bool, Float, Double, String, Array, Optional and the small
//    exposed structs below); enums cross as their C++ raw values. A method
//    whose signature is not representable (Span, closures, function pointers),
//    or that is declared in an extension, is silently dropped from the
//    generated header, so every exposed method lives in the class body.
//  * Every value mirror is declared here, including those the CG decoder uses
//    (EncodedDataStatus, PixelSize, Density, SubsamplingLevel,
//    DecodingDestination, DecodingMode), so this file compiles on its own (with
//    image-decoders/ImageFrameBuffer.swift and ScalableImageDecoderCore.swift)
//    on every port. cg/ImageDecoderCG.swift therefore needs this file.

// ENABLE(IMAGE_DECODER_CG_SWIFT) (Cocoa, wtf/PlatformEnableCocoa.h) or
// ENABLE(IMAGE_DECODERS_SWIFT) (the ScalableImageDecoder family); both off by default.
#if ENABLE_IMAGE_DECODER_CG_SWIFT || ENABLE_IMAGE_DECODERS_SWIFT

// The generated C++ header (WebCoreSwift-Generated.h) puts this module's types in
// namespace WebCore, next to the C++ types they mirror (DecodingOptions,
// EncodedDataStatus, ImageOrientation, ...), and with WebCore's
// -emit-clang-header-min-access internal it emits an unavailable stub class
// for every internal type, which would redefine them. So every type here that
// is not a deliberate bridge type is @_expose(!Cxx).

// MARK: - Value mirrors (raw values match the C++ enumerators)

/// Mirrors WebCore::SubsamplingLevel (0 is Default).
typealias SubsamplingLevel = Int

/// Mirrors WebCore::DecodingDestination.
@_expose(!Cxx)
enum DecodingDestination: UInt8 {
    case base
    case baseAndGainMap
    case shouldDecodeToHDR
}

/// Mirrors WebCore::DecodingMode.
@_expose(!Cxx)
enum DecodingMode: UInt8 {
    case auto
    case synchronous
    case asynchronous
}

/// Mirrors WebCore::EncodedDataStatus.
@_expose(!Cxx)
enum EncodedDataStatus: UInt8 {
    case error, unknown, typeAvailable, sizeAvailable, complete
}

/// Mirrors WebCore::IntSize.
@_expose(!Cxx)
struct PixelSize: Equatable {
    var width: Int32
    var height: Int32
}

/// Mirrors WebCore::FloatSize as used for an image's density.
@_expose(!Cxx)
struct Density: Equatable {
    static let defaultResolution: Float = 72 // ImageResolution::DefaultResolution
    static let `default` = Density(x: defaultResolution, y: defaultResolution)
    var x: Float
    var y: Float
}

/// Mirrors WebCore::DecodingStatus.
@_expose(!Cxx)
enum DecodingStatus: UInt8 {
    case invalid, partial, complete, decoding
}

/// Mirrors WebCore::RepetitionCount (a typedef'd int with three named values).
@_expose(!Cxx)
enum RepetitionCount {
    static let none: Int32 = 0
    static let once: Int32 = 1
    static let infinite: Int32 = -1
}

/// Mirrors WebCore::AlphaOption.
@_expose(!Cxx)
enum AlphaOption: UInt8 {
    case premultiplied, notPremultiplied
}

/// Mirrors WebCore::GammaAndColorProfileOption.
@_expose(!Cxx)
enum GammaAndColorProfileOption: UInt8 {
    case applied, ignored
}

/// Mirrors WebCore::ImageOrientation::Orientation.
@_expose(!Cxx)
enum ImageOrientation: UInt8 {
    case fromImage = 0
    case originTopLeft = 1
    case originTopRight = 2
    case originBottomRight = 3
    case originBottomLeft = 4
    case originLeftTop = 5
    case originRightTop = 6
    case originRightBottom = 7
    case originLeftBottom = 8

    static let none = ImageOrientation.originTopLeft

    /// ImageOrientation::fromEXIFValue: 1...8, anything else is None.
    init(exifValue: Int32?) {
        guard let exifValue, (1...8).contains(exifValue), let orientation = ImageOrientation(rawValue: UInt8(exifValue)) else {
            self = .none
            return
        }
        self = orientation
    }
}

/// Mirrors WebCore::IntPoint, for hotSpot().
@_expose(!Cxx)
struct PixelPoint: Equatable {
    var x: Int32
    var y: Int32
}

/// Mirrors WebCore::DecodingOptions.
@_expose(!Cxx)
struct DecodingOptions: Equatable {
    var mode: DecodingMode = .synchronous
    var destination: DecodingDestination = .base
    var sizeForDrawing: PixelSize?

    var hasSizeForDrawing: Bool { sizeForDrawing != nil }
}

/// Mirrors WebCore::SpatialImageEyeProperties (ENABLE(SPATIAL_IMAGE_DETECTION)).
@_expose(!Cxx)
struct SpatialImageEyeProperties: Equatable {
    var groupIndex: UInt32 = 0
    var disparityAdjustment: Float = 0
    var extrinsicsPosition: [Float] = [0, 0, 0]
    var extrinsicsRotation: [Float] = Array(repeating: 0, count: 9)
    var intrinsicsMatrix: [Float] = Array(repeating: 0, count: 9)
}

/// What fetchFrameMetaDataAtIndex writes into ImageFrame. Swift cannot be
/// ImageFrame's friend, so the C++ adapter does the writes; it also sets
/// m_size from the native image when options.hasSizeForDrawing.
@_expose(!Cxx)
struct ImageFrameMetadata: Equatable {
    var naturalSize: PixelSize
    /// nil = not written (the base-class body leaves m_density untouched).
    var density: Density?
    var densityCorrectedSize: PixelSize?
    var subsamplingLevel: SubsamplingLevel
    var hasAlpha: Bool
    var orientation: ImageOrientation
    var decodingStatus: DecodingStatus
}

// MARK: - Frame pixels (the platform-neutral frame output)

/// One decoded frame as Swift-owned pixels: what ScalableImageDecoder's
/// createFrameImageAtIndex hands to ImageBackingStore::image()
/// (ScalableImageDecoder.cpp:222-236), taken BEFORE any native image exists.
///
/// `pixels` has the layout of ImageBackingStore::m_pixelsSpan
/// (graphics/ImageBackingStore.h:253-254): one 32-bit ARGB word per pixel
/// (ImageBackingStore::pixelValue, PackedColor::ARGB), row-major, no row
/// padding, rows of exactly `width` words. Words, not bytes: the adapter copies
/// them into a std::span<uint32_t>, so byte order is the host's on both sides,
/// as in the C++.
///
/// Invariant, checked by the only initializer: width > 0, height > 0 and
/// pixels.count == width * height, with width * height * 4 representable in
/// both Int and UInt32 (ImageBackingStore::setSize's
/// `Checked<unsigned> bufferSize`, ImageBackingStore.h:71). This is the
/// "bytesPerRow * height == data size" precondition of every port's image()
/// (CGDataProviderCreateWithData's size at ImageBackingStoreCG.cpp:46,
/// cairo_image_surface_create_for_data's stride at ImageBackingStoreCairo.cpp:37-39,
/// SkPixmap's rowBytes at ImageBackingStoreSkia.cpp:39-40), made a checked
/// property of the value that crosses into C++. The adapter must still verify
/// `pixels.getCount() == backingStore->size().area()` before copying.
@_expose(Cxx)
@usableFromInline
struct ImageDecoderFramePixels: Equatable, Sendable {
    @usableFromInline let width: Int32
    @usableFromInline let height: Int32
    /// ImageBackingStore::m_premultiplyAlpha (premultipliedFirst vs first on
    /// CG, kPremul vs kUnpremul on Skia; Cairo is always premultiplied ARGB32).
    @usableFromInline let premultiplyAlpha: Bool
    @usableFromInline let pixels: [UInt32]

    /// nil unless the invariant above holds.
    init?(width: Int32, height: Int32, premultiplyAlpha: Bool, pixels: [UInt32]) {
        guard width > 0, height > 0 else { return nil }
        let (area, areaOverflow) = Int(width).multipliedReportingOverflow(by: Int(height))
        guard !areaOverflow, area == pixels.count else { return nil }
        let (bytes, bytesOverflow) = area.multipliedReportingOverflow(by: 4)
        guard !bytesOverflow, UInt64(bytes) <= UInt64(UInt32.max) else { return nil }
        self.width = width
        self.height = height
        self.premultiplyAlpha = premultiplyAlpha
        self.pixels = pixels
    }

    @_expose(!Cxx)
    var size: PixelSize { PixelSize(width: width, height: height) }
}

// MARK: - The decoder contract

@_expose(!Cxx)
protocol ImageDecoding: AnyObject, Sendable {
    // Pure virtuals in ImageDecoder.h (createFrameImageAtIndex is per output
    // representation: PixelBufferImageDecoding below, CGImageDecoding on Cocoa).
    func bytesDecodedToDetermineProperties() -> Int
    func encodedDataStatus() -> EncodedDataStatus
    func size() -> PixelSize
    func frameCount() -> Int
    func repetitionCount() -> Int32
    func filenameExtension() -> String
    func hotSpot() -> PixelPoint?
    func frameSize(at index: Int, subsampling: SubsamplingLevel) -> PixelSize
    func frameIsComplete(at index: Int) -> Bool
    func frameDuration(at index: Int) -> Double // Seconds
    func frameHasAlpha(at index: Int) -> Bool
    /// setData(const FragmentedSharedBuffer&, bool). The bytes are the whole
    /// encoded data so far (C++ callers pass the growing buffer each time).
    func setData(_ data: [UInt8], allDataReceived: Bool)
    func isAllDataReceived() -> Bool
    func clearFrameBufferCache(_ index: Int)

    // Virtuals with a default body (see the extension).
    func setEncodedDataStatusChangeCallback(_ callback: (@Sendable (EncodedDataStatus) -> Void)?)
    func isSizeAvailable() -> Bool
    func hasHDRGainMap() -> Bool
    func primaryFrameIndex() -> Int
    func uti() -> String
    func accessibilityDescription() -> String
    func isPanorama() -> Bool // ENABLE(QUICKLOOK_FULLSCREEN)
    func isSpatial() -> Bool // ENABLE(SPATIAL_IMAGE_DETECTION)
    func spatialLeftEyeFrameIndex() -> UInt32? // ENABLE(SPATIAL_IMAGE_DETECTION)
    func spatialRightEyeFrameIndex() -> UInt32? // ENABLE(SPATIAL_IMAGE_DETECTION)
    func spatialEyeProperties(at index: UInt32) -> SpatialImageEyeProperties? // ENABLE(SPATIAL_IMAGE_DETECTION)
    func isMaybePanoramic() -> Bool // ENABLE(SPATIAL_IMAGE_CONTROLS)
    func frameDensity(at index: Int) -> Density
    func frameOrientation(at index: Int) -> ImageOrientation
    func frameDensityCorrectedSize(at index: Int) -> PixelSize?
    func fetchFrameMetadata(at index: Int, subsampling: SubsamplingLevel, options: DecodingOptions) -> ImageFrameMetadata?
    func setExpectedContentSize(_ size: Int64)
}

extension ImageDecoding {
    // The C++ default argument SubsamplingLevel::Default.
    func frameSize(at index: Int) -> PixelSize { frameSize(at: index, subsampling: 0) }

    // The default bodies, verbatim.
    func setEncodedDataStatusChangeCallback(_ callback: (@Sendable (EncodedDataStatus) -> Void)?) { }
    func isSizeAvailable() -> Bool { encodedDataStatus().rawValue >= EncodedDataStatus.sizeAvailable.rawValue }
    func hasHDRGainMap() -> Bool { false }
    func primaryFrameIndex() -> Int { 0 }
    func uti() -> String { "" }
    func accessibilityDescription() -> String { "" }
    func isPanorama() -> Bool { false }
    func isSpatial() -> Bool { false }
    func spatialLeftEyeFrameIndex() -> UInt32? { nil }
    func spatialRightEyeFrameIndex() -> UInt32? { nil }
    func spatialEyeProperties(at index: UInt32) -> SpatialImageEyeProperties? { nil }
    func isMaybePanoramic() -> Bool { false }
    func frameDensity(at index: Int) -> Density { .default }
    func frameOrientation(at index: Int) -> ImageOrientation { .none }
    func frameDensityCorrectedSize(at index: Int) -> PixelSize? { nil }
    func setExpectedContentSize(_ size: Int64) { }

    /// ImageDecoder::fetchFrameMetaDataAtIndex (ImageDecoder.cpp). Always
    /// succeeds; does not write m_density.
    func fetchFrameMetadata(at index: Int, subsampling: SubsamplingLevel, options: DecodingOptions) -> ImageFrameMetadata? {
        ImageFrameMetadata(
            naturalSize: frameSize(at: index, subsampling: subsampling),
            density: nil,
            densityCorrectedSize: frameDensityCorrectedSize(at: index),
            subsamplingLevel: subsampling,
            hasAlpha: frameHasAlpha(at: index),
            orientation: frameOrientation(at: index),
            decodingStatus: frameIsComplete(at: index) ? .complete : .partial)
    }
}

/// A decoder whose frames leave Swift as pixels (the ScalableImageDecoder
/// family). createFrameImageAtIndex is split at the point where the C++ calls
/// `buffer->backingStore()->image()`: everything before it is here, image() is
/// the port's existing C++.
@_expose(!Cxx)
protocol PixelBufferImageDecoding: ImageDecoding {
    /// ImageDecoder::createFrameImageAtIndex up to (not including) the native
    /// image: nil exactly where the C++ returns nullptr before image().
    func createFramePixels(at index: Int, subsampling: SubsamplingLevel, options: DecodingOptions) -> ImageDecoderFramePixels?
}

extension PixelBufferImageDecoding {
    // The C++ default arguments (SubsamplingLevel::Default,
    // DecodingOptions(DecodingMode::Synchronous)).
    func createFramePixels(at index: Int) -> ImageDecoderFramePixels? {
        createFramePixels(at: index, subsampling: 0, options: DecodingOptions())
    }
}

// MARK: - The C++-facing box

/// Bridge structs: the only non-scalar types AnyImageDecoder's API uses.
@_expose(Cxx)
@usableFromInline
struct ImageDecoderIntSize: Equatable {
    @usableFromInline var width: Int32
    @usableFromInline var height: Int32

    /// ImageDecoderIntSize::init(width, height) in C++ (the synthesized
    /// memberwise initializer would not be @usableFromInline).
    @usableFromInline
    init(width: Int32, height: Int32) {
        self.width = width
        self.height = height
    }
}

@_expose(Cxx)
@usableFromInline
struct ImageDecoderFrameMetadata {
    @usableFromInline var naturalWidth: Int32
    @usableFromInline var naturalHeight: Int32
    @usableFromInline var hasDensity: Bool
    @usableFromInline var densityWidth: Float
    @usableFromInline var densityHeight: Float
    @usableFromInline var densityCorrectedSize: ImageDecoderIntSize?
    @usableFromInline var subsamplingLevel: Int
    @usableFromInline var hasAlpha: Bool
    @usableFromInline var orientation: UInt8
    @usableFromInline var decodingStatus: UInt8
}

/// One concrete, exposable class whatever decoder is inside. Every method is
/// a dynamic call through the protocol, so a conformer's override and a
/// protocol default both reach C++ correctly. C++ imports these methods as
/// non-const; the adapter holds this as a `mutable` member.
///
/// Frame output: createFramePixelsAtIndex for a PixelBufferImageDecoding
/// decoder. A CG decoder is boxed by AnyCGImageDecoder (cg/ImageDecodingCG.swift),
/// whose `decoder` is one of these for the shared metadata API and which
/// itself exposes createFrameImageAtIndex -> CGImage; for such a box
/// createFramePixelsAtIndex returns nil (the CG adapter never calls it).
//
// -O -wmo: swiftc does not count the generated header as a use and would
// dead-strip internal members of the exposed types, so the C++ link would fail.
// Every declaration C++ reaches is @usableFromInline (ABI-visible, still internal
// to Swift source). See AnyCGImageDecoder in cg/ImageDecodingCG.swift.
@_expose(Cxx)
@usableFromInline
final class AnyImageDecoder: Sendable {
    let base: any ImageDecoding
    let pixelSource: (any PixelBufferImageDecoding)?

    /// A decoder with no pixel output (its frames come from a platform box).
    init(_ base: any ImageDecoding) {
        self.base = base
        self.pixelSource = nil
    }

    /// A decoder whose frames leave Swift as ImageDecoderFramePixels.
    init(pixels base: any PixelBufferImageDecoding) {
        self.base = base
        self.pixelSource = base
    }

    @_expose(!Cxx)
    static func bridge(_ size: PixelSize) -> ImageDecoderIntSize { ImageDecoderIntSize(width: size.width, height: size.height) }
    @_expose(!Cxx)
    static func options(_ mode: UInt8, _ destination: UInt8, _ sizeForDrawing: ImageDecoderIntSize?) -> DecodingOptions {
        DecodingOptions(mode: DecodingMode(rawValue: mode) ?? .synchronous,
                        destination: DecodingDestination(rawValue: destination) ?? .base,
                        sizeForDrawing: sizeForDrawing.map { PixelSize(width: $0.width, height: $0.height) })
    }

    @usableFromInline func bytesDecodedToDetermineProperties() -> Int { base.bytesDecodedToDetermineProperties() }
    @usableFromInline func encodedDataStatus() -> UInt8 { base.encodedDataStatus().rawValue }
    @usableFromInline func isSizeAvailable() -> Bool { base.isSizeAvailable() }
    @usableFromInline func hasHDRGainMap() -> Bool { base.hasHDRGainMap() }
    @usableFromInline func size() -> ImageDecoderIntSize { Self.bridge(base.size()) }
    @usableFromInline func frameCount() -> Int { base.frameCount() }
    @usableFromInline func primaryFrameIndex() -> Int { base.primaryFrameIndex() }
    @usableFromInline func repetitionCount() -> Int32 { base.repetitionCount() }
    @usableFromInline func uti() -> String { base.uti() }
    @usableFromInline func filenameExtension() -> String { base.filenameExtension() }
    @usableFromInline func accessibilityDescription() -> String { base.accessibilityDescription() }
    // Not `Int32?`: the generated header allocates the optional's 5 bytes and copies 8 into them.
    @usableFromInline func hasHotSpot() -> Bool { base.hotSpot() != nil }
    @usableFromInline func hotSpotX() -> Int32 { base.hotSpot()?.x ?? 0 }
    @usableFromInline func hotSpotY() -> Int32 { base.hotSpot()?.y ?? 0 }
    @usableFromInline func isPanorama() -> Bool { base.isPanorama() }
    @usableFromInline func isSpatial() -> Bool { base.isSpatial() }
    @usableFromInline func spatialLeftEyeFrameIndex() -> UInt32? { base.spatialLeftEyeFrameIndex() }
    @usableFromInline func spatialRightEyeFrameIndex() -> UInt32? { base.spatialRightEyeFrameIndex() }
    @usableFromInline func isMaybePanoramic() -> Bool { base.isMaybePanoramic() }
    @usableFromInline func frameSizeAtIndex(_ index: Int, _ subsampling: Int) -> ImageDecoderIntSize { Self.bridge(base.frameSize(at: index, subsampling: subsampling)) }
    @usableFromInline func frameDensityWidthAtIndex(_ index: Int) -> Float { base.frameDensity(at: index).x }
    @usableFromInline func frameDensityHeightAtIndex(_ index: Int) -> Float { base.frameDensity(at: index).y }
    @usableFromInline func frameIsCompleteAtIndex(_ index: Int) -> Bool { base.frameIsComplete(at: index) }
    @usableFromInline func frameOrientationAtIndex(_ index: Int) -> UInt8 { base.frameOrientation(at: index).rawValue }
    @usableFromInline func frameDensityCorrectedSizeAtIndex(_ index: Int) -> ImageDecoderIntSize? { base.frameDensityCorrectedSize(at: index).map(Self.bridge) }
    @usableFromInline func frameDurationAtIndex(_ index: Int) -> Double { base.frameDuration(at: index) }
    @usableFromInline func frameHasAlphaAtIndex(_ index: Int) -> Bool { base.frameHasAlpha(at: index) }

    @usableFromInline func fetchFrameMetaDataAtIndex(_ index: Int, _ subsampling: Int, _ mode: UInt8, _ destination: UInt8, _ sizeForDrawing: ImageDecoderIntSize?) -> ImageDecoderFrameMetadata? {
        guard let metadata = base.fetchFrameMetadata(at: index, subsampling: subsampling, options: Self.options(mode, destination, sizeForDrawing)) else { return nil }
        return ImageDecoderFrameMetadata(
            naturalWidth: metadata.naturalSize.width, naturalHeight: metadata.naturalSize.height,
            hasDensity: metadata.density != nil,
            densityWidth: metadata.density?.x ?? 0, densityHeight: metadata.density?.y ?? 0,
            densityCorrectedSize: metadata.densityCorrectedSize.map(Self.bridge),
            subsamplingLevel: metadata.subsamplingLevel,
            hasAlpha: metadata.hasAlpha,
            orientation: metadata.orientation.rawValue,
            decodingStatus: metadata.decodingStatus.rawValue)
    }

    /// The pixels of a frame, for the adapter to wrap with the port's
    /// ImageBackingStore::image(). nil where the C++ returns nullptr before
    /// image(), and always for a box without pixel output.
    @usableFromInline func createFramePixelsAtIndex(_ index: Int, _ subsampling: Int, _ mode: UInt8, _ destination: UInt8, _ sizeForDrawing: ImageDecoderIntSize?) -> ImageDecoderFramePixels? {
        pixelSource?.createFramePixels(at: index, subsampling: subsampling, options: Self.options(mode, destination, sizeForDrawing))
    }

    @usableFromInline func setExpectedContentSize(_ size: Int64) { base.setExpectedContentSize(size) }
    @usableFromInline func setData(_ bytes: [UInt8], _ allDataReceived: Bool) { base.setData(bytes, allDataReceived: allDataReceived) }
    @usableFromInline func isAllDataReceived() -> Bool { base.isAllDataReceived() }
    @usableFromInline func clearFrameBufferCache(_ index: Int) { base.clearFrameBufferCache(index) }
}

#endif // ENABLE_IMAGE_DECODER_CG_SWIFT || ENABLE_IMAGE_DECODERS_SWIFT
