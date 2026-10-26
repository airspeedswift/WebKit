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

// PROTOTYPE: the Cocoa-only half of the Swift ImageDecoder contract (the
// platform-neutral half is ../ImageDecoding.swift). Not yet in
// WebCore.xcodeproj.
//
//  * `CGImageDecoding` is the USE(CG) arm of ImageDecoder::createFrameImageAtIndex
//    (PlatformImagePtr = RetainPtr<CGImageRef>, PlatformImage.h:44) plus
//    frameGainMapAtIndex, whose raw input is a CFDictionary. Only an
//    ImageIO-backed decoder conforms: its CGImages are made by ImageIO
//    (CGImageSourceCreateImageAtIndex / CreateThumbnailAtIndex), never from a
//    Swift pixel buffer. The ScalableImageDecoder family does not conform on
//    any port; on Cocoa too its frames leave Swift as ImageDecoderFramePixels
//    and become CGImages in ImageBackingStoreCG.cpp:37-56 (C++).
//  * ImageDecoderCGCore's ImageDecoding conformance lives here: each body is
//    the ImageDecoderCG.cpp override; where ImageDecoderCG.h does not override,
//    the protocol default applies, as in C++.
//  * AnyCGImageDecoder is the C++-facing box for the CG decoder. Exposed
//    members must be in a class body (imagedecoder_bridge_measurements P4), so
//    it is a separate final class, not an extension of AnyImageDecoder; the
//    shared metadata API is its `decoder` (an AnyImageDecoder over the same
//    core).

// ENABLE(IMAGE_DECODER_CG_SWIFT) (wtf/PlatformEnableCocoa.h, off by default).
#if ENABLE_IMAGE_DECODER_CG_SWIFT

// The generated C++ header (WebCoreSwift-Generated.h) puts this module's types in
// namespace WebCore, next to the C++ types they mirror (DecodingOptions,
// EncodedDataStatus, ImageOrientation, ...), and with WebCore's
// -emit-clang-header-min-access internal it emits an unavailable stub class
// for every internal type, which would redefine them. So every type here that
// is not a deliberate bridge type is @_expose(!Cxx).

// CoreGraphics and ImageIO are `public import`s only because the C++-facing
// declarations below are @usableFromInline (see AnyCGImageDecoder) and their
// signatures use CGImage, CGImageSource and CF types.
public import CoreGraphics
import Foundation
public import ImageIO

// MARK: - The Cocoa-only refinement

@_expose(!Cxx)
protocol CGImageDecoding: ImageDecoding {
    /// ImageDecoder::createFrameImageAtIndex on USE(CG).
    func createFrameImage(at index: Int, subsampling: SubsamplingLevel, options: DecodingOptions) -> CGImage?
    /// The same, on the caller's own reference to the decoder's image source,
    /// with no lock of the decoder held while ImageIO decodes (the C++ adapter's
    /// path; see ImageDecoderCGCore "Locking").
    func createFrameImage(using source: CGImageSource, at index: Int, subsampling: SubsamplingLevel, options: DecodingOptions) -> CGImage?
    /// The raw ImageIO auxiliary-data dictionary behind frameGainMapAtIndex;
    /// GainMap construction stays C++.
    func frameGainMapInfo(at index: Int, options: DecodingOptions) -> CFDictionary?
    /// ImageDecoderCG::setData with the CFData the C++ hands ImageIO
    /// (AnyCGImageDecoder.setData), passed through without a copy.
    /// ImageDecoderCGCore's own setData(_:allDataReceived:).
    func setData(_ data: sending CFData, allDataReceived: Bool)
}

extension CGImageDecoding {
    // The C++ default arguments (SubsamplingLevel::Default,
    // DecodingOptions(DecodingMode::Synchronous)).
    func createFrameImage(at index: Int) -> CGImage? { createFrameImage(at: index, subsampling: 0, options: DecodingOptions()) }

    /// ImageDecoder.h default (nullopt).
    func frameGainMapInfo(at index: Int, options: DecodingOptions) -> CFDictionary? { nil }
}

// MARK: - ImageDecoderCG's conformance

extension ImageDecoderCGCore: CGImageDecoding {
    func size() -> PixelSize { PixelSize(width: 0, height: 0) } // IntSize()
    func hotSpot() -> PixelPoint? { hotSpotCoordinates().map { PixelPoint(x: $0.x, y: $0.y) } }
    func frameOrientation(at index: Int) -> ImageOrientation { ImageOrientation(exifValue: frameEXIFOrientation(at: index)) }
    func clearFrameBufferCache(_ index: Int) { }

    /// The C++ makes its contiguous copy of the FragmentedSharedBuffer; this is
    /// that copy.
    func setData(_ data: [UInt8], allDataReceived: Bool) {
        setData(Data(data), allDataReceived: allDataReceived)
    }

    func createFrameImage(at index: Int, subsampling: SubsamplingLevel, options: DecodingOptions) -> CGImage? {
        createFrameImage(at: index, subsampling: subsampling, mode: options.mode, destination: options.destination, sizeForDrawing: options.sizeForDrawing)
    }

    func createFrameImage(using source: CGImageSource, at index: Int, subsampling: SubsamplingLevel, options: DecodingOptions) -> CGImage? {
        createFrameImage(using: source, at: index, subsampling: subsampling, mode: options.mode, destination: options.destination, sizeForDrawing: options.sizeForDrawing)
    }

    /// ImageDecoderCG::fetchFrameMetaDataAtIndex: unlike the base body it
    /// fails without properties and writes the density.
    func fetchFrameMetadata(at index: Int, subsampling: SubsamplingLevel, options: DecodingOptions) -> ImageFrameMetadata? {
        guard let metadata = frameMetadata(at: index, subsampling: subsampling) else { return nil }
        return ImageFrameMetadata(
            naturalSize: metadata.naturalSize,
            density: metadata.density,
            densityCorrectedSize: metadata.densityCorrectedSize,
            subsamplingLevel: subsampling,
            hasAlpha: metadata.hasAlpha,
            orientation: ImageOrientation(exifValue: metadata.exifOrientation),
            decodingStatus: metadata.isComplete ? .complete : .partial)
    }

    // ENABLE(SPATIAL_IMAGE_CONTROLS) / ENABLE(QUICKLOOK_FULLSCREEN): the pure
    // functions over frame 0's size (ImageDecoderCG.cpp:819-838), with ONE
    // locked frameSize read each (no TOCTOU between two reads).
    func isMaybePanoramic() -> Bool { ImageDecoderCGProperties.isMaybePanoramic(frameSize: frameSize(at: 0, subsampling: 0)) }
    func isPanorama() -> Bool { ImageDecoderCGProperties.isPanorama(frameSize: frameSize(at: 0, subsampling: 0)) }

    /// ENABLE(SPATIAL_IMAGE_DETECTION): ImageDecoderCG::spatialEyePropertiesAtIndex
    /// (cpp:960-993), via ImageDecoderCGCore.spatialEyeMetadata(at:).
    /// isSpatial/spatialLeftEyeFrameIndex/spatialRightEyeFrameIndex are
    /// ImageDecoderCGCore's own methods (ImageDecoderCG.swift), which witness the
    /// requirements directly.
    func spatialEyeProperties(at index: UInt32) -> SpatialImageEyeProperties? {
        spatialEyeMetadata(at: index).map {
            SpatialImageEyeProperties(groupIndex: $0.groupIndex, disparityAdjustment: $0.disparityAdjustment,
                                      extrinsicsPosition: $0.extrinsicsPosition, extrinsicsRotation: $0.extrinsicsRotation,
                                      intrinsicsMatrix: $0.intrinsicsMatrix)
        }
    }

    // Not overridden here, and still C++ in the adapter: accessibilityDescription
    // (soft-linked MediaAccessibility), frameGainMapAtIndex (SPI auxiliary data).
}

// MARK: - The C++-facing box

//
// M2 (-O -wmo): swiftc does not count the generated header as a use, so under
// whole-module optimization it dead-strips internal methods of an exposed class
// and the C++ link fails. Every declaration C++ reaches is therefore
// @usableFromInline: ABI-visible (kept) but still internal to Swift source, and
// still subject to the min-access-internal header, so no other type changes.
@_expose(Cxx)
@usableFromInline
final class AnyCGImageDecoder: Sendable {
    let base: any CGImageDecoding

    /// The platform-neutral API (metadata, data, status) of the same decoder.
    @usableFromInline
    let decoder: AnyImageDecoder

    init(_ base: any CGImageDecoding) {
        self.base = base
        self.decoder = AnyImageDecoder(base)
    }

    /// The CG decoder. `supportedImageTypes` and `preferredExtensions`
    /// (parallel to `extensionTypes`) snapshot WebCore's UTIRegistry policy.
    ///
    /// isSpatialMedia: this exposed factory has the feature-off behaviour
    /// (isSpatial() false, eye indices/properties nil). The PhotosFormats soft
    /// link cannot be passed from C++: a parameter of type
    /// `@convention(c) (CGImageSource) -> Bool`, `@convention(block)` or a Swift
    /// closure is silently dropped from the generated header (measured,
    /// Swift 6.4). Phase 4 declares the soft-linked call in a header the Swift
    /// module imports and passes it through the overload below.
    static func makeCG(typeIdentifierHint: String, supportedImageTypes: [String], extensionTypes: [String], preferredExtensions: [String], hardwareAcceleratedDecodingDisabled: Bool, enableRestrictedDecoding: Bool, createUnpremultipliedPNG: Bool) -> AnyCGImageDecoder {
        makeCG(typeIdentifierHint: typeIdentifierHint, supportedImageTypes: supportedImageTypes, extensionTypes: extensionTypes, preferredExtensions: preferredExtensions,
               hardwareAcceleratedDecodingDisabled: hardwareAcceleratedDecodingDisabled, enableRestrictedDecoding: enableRestrictedDecoding,
               createUnpremultipliedPNG: createUnpremultipliedPNG, isSpatialMedia: { _ in false })
    }

    /// makeCG with ImageDecoderCG::isSpatial's body injected
    /// (canLoad_PhotosFormats_PFMetadataImageSourceIsSpatialMedia() &&
    /// softLink_PhotosFormats_PFMetadataImageSourceIsSpatialMedia(source)).
    static func makeCG(typeIdentifierHint: String, supportedImageTypes: [String], extensionTypes: [String], preferredExtensions: [String], hardwareAcceleratedDecodingDisabled: Bool, enableRestrictedDecoding: Bool, createUnpremultipliedPNG: Bool, isSpatialMedia: @escaping @Sendable (CGImageSource) -> Bool) -> AnyCGImageDecoder {
        let supported = Set(supportedImageTypes)
        let extensions = Dictionary(zip(extensionTypes, preferredExtensions), uniquingKeysWith: { first, _ in first })
        let configuration = ImageSourceConfiguration(
            hardwareAcceleratedDecodingDisabled: hardwareAcceleratedDecodingDisabled,
            enableRestrictedDecoding: enableRestrictedDecoding,
            createUnpremultipliedPNG: createUnpremultipliedPNG)
        let core = ImageDecoderCGCore(
            typeIdentifierHint: typeIdentifierHint.isEmpty ? nil : typeIdentifierHint,
            configuration: configuration,
            isSupportedImageType: { supported.contains($0) },
            preferredFilenameExtension: { extensions[$0] ?? "" },
            isSpatialMedia: isSpatialMedia)
        return AnyCGImageDecoder(core)
    }

    /// The decoder ImageDecoderCG.cpp builds under ENABLE(IMAGE_DECODER_CG_SWIFT),
    /// over the CGImageSource its constructor created (it keeps a reference for
    /// accessibilityDescription, the spatial-image queries and frameGainMapAtIndex,
    /// which stay C++). The three SPI keys are the SDK symbols' values
    /// (ImageSourceSPIKeys); supportedImageTypes is WebCore::isSupportedImageType's
    /// set (supportedImageTypes() + additionalSupportedImageTypes()) at creation.
    /// filenameExtension stays C++ (WebCore::preferredExtensionForImageType(uti())),
    /// so no extension table is injected, and isSpatialMedia is feature-off.
    ///
    /// `source` is `sending`, so Swift takes it at +1: the generated C++ thunk does
    /// NOT retain it (measured, Swift 6.4), so the caller must pass a +1
    /// reference (RetainPtr::leakRef()).
    @usableFromInline
    static func makeForImageSource(_ source: sending CGImageSource, _ supportedImageTypes: CFArray, _ shouldPreferRGB32Key: CFString, _ skipMetadataKey: CFString, _ useHardwareAccelerationKey: CFString, _ hardwareAcceleratedDecodingDisabled: Bool, _ enableRestrictedDecoding: Bool, _ createUnpremultipliedPNG: Bool) -> AnyCGImageDecoder {
        let supported = Set((supportedImageTypes as NSArray).compactMap { $0 as? String })
        let configuration = ImageSourceConfiguration(
            hardwareAcceleratedDecodingDisabled: hardwareAcceleratedDecodingDisabled,
            enableRestrictedDecoding: enableRestrictedDecoding,
            createUnpremultipliedPNG: createUnpremultipliedPNG,
            spiKeys: ImageSourceSPIKeys(shouldPreferRGB32: shouldPreferRGB32Key as String, skipMetadata: skipMetadataKey as String,
                                        useHardwareAcceleration: useHardwareAccelerationKey as String))
        let core = ImageDecoderCGCore(
            source: source,
            configuration: configuration,
            isSupportedImageType: { supported.contains($0) },
            preferredFilenameExtension: { _ in "" })
        return AnyCGImageDecoder(core)
    }

    /// ImageDecoderCG::setData: `data` is the C++'s
    /// contiguousData->createCFData(). It goes to CGImageSourceUpdateData
    /// unchanged, as in the C++ (no Data bridging, which would copy every byte
    /// and leave ImageIO holding the copy). `sending`, like makeForImageSource's
    /// source: the generated thunk does not retain it, so the caller passes +1
    /// (RetainPtr::leakRef()) and Swift releases it.
    @usableFromInline
    func setData(_ data: sending CFData, _ allDataReceived: Bool) {
        base.setData(data, allDataReceived: allDataReceived)
    }

    /// Imports as `CGImageRef _Nullable` returned at +1: the adapter must
    /// adoptCF it (measured; see imagedecoder_bridge_measurements P4). The
    /// generated header needs <CoreGraphics/CoreGraphics.h> included first.
    /// For callers without a reference to the source: the decode is serialized
    /// with the decoder's other ImageIO calls under its source lock.
    @usableFromInline
    func createFrameImageAtIndex(_ index: Int, _ subsampling: Int, _ mode: UInt8, _ destination: UInt8, _ sizeForDrawing: ImageDecoderIntSize?) -> CGImage? {
        base.createFrameImage(at: index, subsampling: subsampling, options: AnyImageDecoder.options(mode, destination, sizeForDrawing))
    }

    /// The adapter's path: `source` is the adapter's own m_nativeDecoder, the
    /// source it passed to makeForImageSource (checked; anything else traps),
    /// borrowed (+0) for the call. ImageIO decodes with no Swift lock held, so
    /// uti()/isAllDataReceived()/encodedDataStatus()/frameCount()/setData on
    /// other threads do not wait for the decode. Same +1 result as above.
    @usableFromInline
    func createFrameImageAtIndex(_ source: CGImageSource, _ index: Int, _ subsampling: Int, _ mode: UInt8, _ destination: UInt8, _ sizeForDrawing: ImageDecoderIntSize?) -> CGImage? {
        base.createFrameImage(using: source, at: index, subsampling: subsampling, options: AnyImageDecoder.options(mode, destination, sizeForDrawing))
    }
}

#endif // ENABLE_IMAGE_DECODER_CG_SWIFT
