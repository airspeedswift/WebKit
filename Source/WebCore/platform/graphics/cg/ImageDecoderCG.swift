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

// PROTOTYPE: the WebCore-type-free core of ImageDecoderCG.cpp. Not yet in
// WebCore.xcodeproj. ImageDecoderCG stays a C++ class (it subclasses the
// virtual, ref-counted ImageDecoder, which Swift cannot do); its method
// bodies become thin forwarders into the functions below.
//
// Safety rules this file follows, and why:
//  * Every CF value read out of a properties dictionary is type-checked with
//    CFGetTypeID. `x as! CFNumber` is NOT checked in Swift (it compiles and
//    silently type-confuses, exactly like the C++ `(CFNumberRef)` casts this
//    replaces), and `x as? NSNumber` accepts CFBoolean.
//  * Every array access is bounds-checked (the C++ indexes FrameInfo with a
//    frame index it never checks against the array's count).
//  * Numbers are read with CFNumberGetValue, not `as? Int`/`as? Float`, so
//    lossy-conversion behaviour matches the C++ exactly, through the sealed
//    wrapper in platform/cf/SafeCFNumber.swift. This file has no unsafe code.
//  * Byte sniffing reads a Span<UInt8>; there is no pointer arithmetic.
//  * ImageDecoderCGCore (end of file) is the only stateful type. Its mutable
//    state lives in two Mutexes (the CGImageSource in one, the small cached
//    values in the other), so it is Sendable without @unchecked. No ImageIO
//    decode runs under either lock: createFrameImage(using:...) decodes on the
//    caller's reference to the same source, and a CGImage from the synchronous
//    path is decoded lazily by ImageIO at draw time, possibly concurrently with
//    setData's CGImageSourceUpdateData. That relies on ImageIO's own per-source
//    thread safety exactly as the C++ does (see "Locking" on the class); the
//    Mutexes do not fix races of the bugs.webkit.org/273801 class that live
//    inside ImageIO.

// ENABLE(IMAGE_DECODER_CG_SWIFT) (wtf/PlatformEnableCocoa.h, off by default).
#if ENABLE_IMAGE_DECODER_CG_SWIFT

// The generated C++ header (WebCoreSwift-Generated.h) puts this module's types in
// namespace WebCore, next to the C++ types they mirror (DecodingOptions,
// EncodedDataStatus, ImageOrientation, ...), and with WebCore's
// -emit-clang-header-min-access internal it emits an unavailable stub class
// for every internal type, which would redefine them. So every type here that
// is not a deliberate bridge type is @_expose(!Cxx).

import Foundation
import ImageIO
import Synchronization

// MARK: - Checked access to ImageIO property dictionaries

/// Converts an arbitrary bridged value to a CF type only after checking its
/// type ID. This is Swift's dynamic_cf_cast.
private enum CFCast {
    static func number(_ value: Any?) -> CFNumber? { CFNumber.checked(value) }

    static func string(_ value: Any?) -> CFString? {
        guard let value else { return nil }
        let object = value as CFTypeRef
        return CFGetTypeID(object) == CFStringGetTypeID() ? (object as! CFString) : nil
    }

    static func dictionary(_ value: Any?) -> ImageProperties? {
        guard let value else { return nil }
        let object = value as CFTypeRef
        return CFGetTypeID(object) == CFDictionaryGetTypeID() ? ImageProperties(object as! CFDictionary) : nil
    }

    static func array(_ value: Any?) -> ImagePropertyArray? {
        guard let value else { return nil }
        let object = value as CFTypeRef
        return CFGetTypeID(object) == CFArrayGetTypeID() ? ImagePropertyArray(object as! CFArray) : nil
    }
}

/// A read-only ImageIO properties dictionary whose accessors return nil
/// for a missing key *or* a value of the wrong CF type.
@_expose(!Cxx)
struct ImageProperties {
    private let storage: NSDictionary

    init(_ dictionary: CFDictionary) { storage = dictionary as NSDictionary }

    init?(_ dictionary: CFDictionary?) {
        guard let dictionary else { return nil }
        self.init(dictionary)
    }

    func contains(_ key: CFString) -> Bool { storage[key] != nil }
    func number(_ key: CFString) -> CFNumber? { CFCast.number(storage[key]) }
    func string(_ key: CFString) -> CFString? { CFCast.string(storage[key]) }
    func dictionary(_ key: CFString) -> ImageProperties? { CFCast.dictionary(storage[key]) }
    func array(_ key: CFString) -> ImagePropertyArray? { CFCast.array(storage[key]) }
}

/// A read-only CFArray with bounds- and type-checked element access.
@_expose(!Cxx)
struct ImagePropertyArray {
    private let storage: NSArray

    init(_ array: CFArray) { storage = array as NSArray }

    var count: Int { storage.count }

    private func element(_ index: Int) -> Any? {
        (0..<storage.count).contains(index) ? storage[index] : nil
    }

    func number(at index: Int) -> CFNumber? { CFCast.number(element(index)) }
    func string(at index: Int) -> CFString? { CFCast.string(element(index)) }
    func dictionary(at index: Int) -> ImageProperties? { CFCast.dictionary(element(index)) }
}

// MARK: - Image source options

// SubsamplingLevel and DecodingDestination: declared in ../ImageDecoding.swift (platform-neutral).

/// Process-wide inputs the C++ reads from ProcessCapabilities and HAVE()/USE()
/// macros. Passed in once, so the Swift side has no hidden global state.
@_expose(!Cxx)
struct ImageSourceConfiguration: Sendable {
    var hardwareAcceleratedDecodingDisabled = false
    var enableRestrictedDecoding = false
    var createUnpremultipliedPNG = false
    var spiKeys = ImageSourceSPIKeys()
}

/// The values of the three ImageIO SPI option keys the C++ takes from
/// <pal/spi/cg/ImageIOSPI.h>. WebCore has no Swift view of that header, so the
/// C++ adapter passes the SDK symbols' values (AnyCGImageDecoder.makeForImageSource).
/// The defaults are the keys' own names, which is what those symbols hold
/// (measured against ImageIO on macOS 27); only the standalone harnesses use them.
@_expose(!Cxx)
struct ImageSourceSPIKeys: Sendable {
    var shouldPreferRGB32 = "kCGImageSourceShouldPreferRGB32"
    var skipMetadata = "kCGImageSourceSkipMetadata"
    var useHardwareAcceleration = "kCGImageSourceUseHardwareAcceleration"
}

@_expose(!Cxx)
enum ImageSourceOptions {
    private static var enableRestrictedDecodingKey: CFString { "kCGImageSourceEnableRestrictedDecoding" as CFString }
    private static var createUnpremultipliedPNGKey: CFString { "kCGImageSourceCreateUnpremultipliedPNG" as CFString }

    static func base(_ configuration: ImageSourceConfiguration) -> [CFString: Any] {
        var options: [CFString: Any] = [
            kCGImageSourceShouldCache: true,
            configuration.spiKeys.shouldPreferRGB32 as CFString: true,
            configuration.spiKeys.skipMetadata as CFString: true,
        ]
        if configuration.hardwareAcceleratedDecodingDisabled {
            options[configuration.spiKeys.useHardwareAcceleration as CFString] = false
        }
        if configuration.enableRestrictedDecoding {
            options[enableRestrictedDecodingKey] = true
        }
        if configuration.createUnpremultipliedPNG {
            options[createUnpremultipliedPNGKey] = true
        }
        return options
    }

    static func metadata(_ configuration: ImageSourceConfiguration) -> CFDictionary {
        var options = base(configuration)
        options[configuration.spiKeys.skipMetadata as CFString] = false
        return options as CFDictionary
    }

    static func decode(_ configuration: ImageSourceConfiguration, subsampling: SubsamplingLevel = 0, destination: DecodingDestination = .base) -> CFDictionary {
        var options = base(configuration)
        appendSubsampling(&options, subsampling)
        appendDestination(&options, destination)
        return options as CFDictionary
    }

    static func thumbnail(_ configuration: ImageSourceConfiguration, subsampling: SubsamplingLevel, maxPixelSize: Int32, destination: DecodingDestination = .base) -> CFDictionary {
        var options = base(configuration)
        options[kCGImageSourceShouldCacheImmediately] = true
        options[kCGImageSourceCreateThumbnailFromImageAlways] = true
        appendSubsampling(&options, subsampling)
        options[kCGImageSourceThumbnailMaxPixelSize] = maxPixelSize
        appendDestination(&options, destination)
        return options as CFDictionary
    }

    private static func appendSubsampling(_ options: inout [CFString: Any], _ level: SubsamplingLevel) {
        guard level != 0 else { return }
        // [0..3] => [1, 2, 4, 8]. Clamping first makes the shift total.
        options[kCGImageSourceSubsampleFactor] = Int32(1) << Int32(min(3, max(0, level)))
    }

    private static func appendDestination(_ options: inout [CFString: Any], _ destination: DecodingDestination) {
        if destination == .shouldDecodeToHDR {
            options[kCGImageSourceDecodeRequest] = kCGImageSourceDecodeToHDR
        }
    }
}

// MARK: - Frame properties

// PixelSize and Density: declared in ../ImageDecoding.swift (platform-neutral).

/// The inputs to ImageResolution::densityCorrectedSize, which stays in C++.
@_expose(!Cxx)
struct DensityCorrectionMetadata: Equatable {
    var sourceSize: (width: Float, height: Float)
    var preferredSize: (width: Float, height: Float)
    var resolution: (x: Float, y: Float)
    var resolutionUnit: Int32

    static func == (a: Self, b: Self) -> Bool {
        a.sourceSize == b.sourceSize && a.preferredSize == b.preferredSize && a.resolution == b.resolution && a.resolutionUnit == b.resolutionUnit
    }
}

@_expose(!Cxx)
enum ImageDecoderCGProperties {
    static var avisDictionary: CFString { "{AVIS}" as CFString }
    static var heicsDictionary: CFString { "{HEICS}" as CFString }
    static var frameInfoArray: CFString { "FrameInfo" as CFString }
    static var unclampedDelayTime: CFString { "UnclampedDelayTime" as CFString }
    static var delayTime: CFString { "DelayTime" as CFString }
    static var loopCount: CFString { "LoopCount" as CFString }

    static func frameSize(_ properties: ImageProperties?) -> PixelSize {
        guard let properties else { return PixelSize(width: 0, height: 0) }
        func dimension(_ key: CFString) -> Int32 { properties.number(key)?.value(as: Int32.self).value ?? 0 }
        return PixelSize(width: dimension(kCGImagePropertyPixelWidth), height: dimension(kCGImagePropertyPixelHeight))
    }

    static func animationProperties(_ properties: ImageProperties?) -> ImageProperties? {
        guard let properties else { return nil }
        let keys = [kCGImagePropertyGIFDictionary, kCGImagePropertyWebPDictionary, kCGImagePropertyPNGDictionary, avisDictionary, heicsDictionary]
        return keys.lazy.compactMap { properties.dictionary($0) }.first
    }

    /// HEIF containers keep per-frame info in "{HEICS}" = { FrameInfo = ( {...}, ... ) }.
    static func animationProperties(_ properties: ImageProperties?, container: CFString, frame index: Int) -> ImageProperties? {
        properties?.dictionary(container)?.array(frameInfoArray)?.dictionary(at: index)
    }

    /// Returns the raw EXIF orientation (1...8), or nil for "None".
    static func exifOrientation(_ properties: ImageProperties) -> Int32? {
        properties.number(kCGImagePropertyOrientation)?.value(as: Int32.self).value
    }

    static func density(_ properties: ImageProperties) -> Density {
        guard let x = properties.number(kCGImagePropertyDPIWidth), let y = properties.number(kCGImagePropertyDPIHeight) else {
            return .default
        }
        return Density(x: x.value(as: Float.self).value, y: y.value(as: Float.self).value)
    }

    static func mayHaveDensityCorrectedSize(_ properties: ImageProperties) -> Bool {
        density(properties) != .default
    }

    static func densityCorrectionMetadata(_ properties: ImageProperties) -> DensityCorrectionMetadata? {
        guard let exif = properties.dictionary(kCGImagePropertyExifDictionary),
              let tiff = properties.dictionary(kCGImagePropertyTIFFDictionary) else { return nil }

        // The C++ checks every input for null *except* the pixel width and
        // height, which it then passes to CFNumberGetValue. Here they are
        // checked like the rest.
        func exactFloat(_ number: CFNumber?) -> Float? {
            guard let result = number?.value(as: Float.self), result.exact else { return nil }
            return result.value
        }
        guard let sourceWidth = exactFloat(properties.number(kCGImagePropertyPixelWidth)),
              let sourceHeight = exactFloat(properties.number(kCGImagePropertyPixelHeight)),
              let preferredWidth = exactFloat(exif.number(kCGImagePropertyExifPixelXDimension)),
              let preferredHeight = exactFloat(exif.number(kCGImagePropertyExifPixelYDimension)),
              let resolutionX = exactFloat(properties.number(kCGImagePropertyDPIWidth)),
              let resolutionY = exactFloat(properties.number(kCGImagePropertyDPIHeight)),
              let unit = tiff.number(kCGImagePropertyTIFFResolutionUnit)?.value(as: Int32.self), unit.exact else { return nil }

        return DensityCorrectionMetadata(
            sourceSize: (sourceWidth, sourceHeight),
            preferredSize: (preferredWidth, preferredHeight),
            resolution: (resolutionX, resolutionY),
            resolutionUnit: unit.value)
    }

    static func hotSpot(_ properties: ImageProperties?) -> (x: Int32, y: Int32)? {
        guard let properties,
              let x = properties.number("hotspotX" as CFString)?.value(as: Int32.self), x.exact,
              let y = properties.number("hotspotY" as CFString)?.value(as: Int32.self), y.exact,
              x.value >= 0, y.value >= 0 else { return nil }
        return (x.value, y.value)
    }

    /// Matches WebCore's RepetitionCount: 0 = none, 1 = once, -1 = infinite.
    static func repetitionCount(containerProperties: ImageProperties?) -> Int32 {
        guard let animation = animationProperties(containerProperties) else { return 0 }
        guard let loopCount = animation.number(loopCount) else { return 1 }
        let count = loopCount.value(as: Int32.self).value
        return count == 0 ? -1 : count
    }

    /// Frame duration in seconds, with WebKit's 100 ms floor for <= 10 ms frames.
    /// `containerProperties` is only fetched when the frame has no animation
    /// dictionary of its own, as in the C++.
    static func frameDuration(frameProperties: ImageProperties?, containerProperties: () -> ImageProperties?, frame index: Int) -> Double {
        var animation = animationProperties(frameProperties)
        if frameProperties != nil, animation == nil {
            let container = containerProperties()
            animation = animationProperties(container, container: avisDictionary, frame: index)
                ?? animationProperties(container, container: heicsDictionary, frame: index)
        }

        let delay = (animation?.number(unclampedDelayTime) ?? animation?.number(delayTime))?.value(as: Float.self).value ?? 0
        let duration = Double(delay)
        // Many ads specify a 0 duration to flash as quickly as possible; follow
        // Firefox and use 100 ms for anything under 11 ms. <rdar://7689300>
        return duration < 0.011 ? 0.1 : duration
    }

    static func hasHDRGainMap(containerMetadataProperties properties: ImageProperties?) -> Bool {
        guard let auxiliaryData = properties?
            .dictionary(kCGImagePropertyFileContentsDictionary)?
            .array(kCGImagePropertyImages)?
            .dictionary(at: 0)?
            .array(kCGImagePropertyAuxiliaryData) else { return false }

        let gainMapTypes = [kCGImageAuxiliaryDataTypeHDRGainMap, kCGImageAuxiliaryDataTypeISOGainMap]
        return (0..<auxiliaryData.count).contains { index in
            guard let type = auxiliaryData.dictionary(at: index)?.string(kCGImagePropertyAuxiliaryDataType) else { return false }
            return gainMapTypes.contains { CFStringCompare(type, $0, []) == .compareEqualTo }
        }
    }
}

// MARK: - Panorama (ENABLE(QUICKLOOK_FULLSCREEN))

extension ImageDecoderCGProperties {
    static let panoramicImageAspectRatioThreshold: Float = 2
    static let panoramicImageMinDimension: Float = 800
    static let panoramicImageMaxDimension: Float = 30000

    /// FloatSize(frameSizeAtIndex(0)).aspectRatio(): Float division, so 0/0
    /// is NaN and n/0 is infinity, as in C++.
    private static func aspectRatio(_ size: PixelSize) -> Float { Float(size.width) / Float(size.height) }

    /// ImageDecoderCG::isMaybePanoramic, given frame 0's size.
    static func isMaybePanoramic(frameSize size: PixelSize) -> Bool {
        aspectRatio(size) > panoramicImageAspectRatioThreshold
    }

    /// ImageDecoderCG::isPanorama, given frame 0's size. Written as `<=` then
    /// return, like the C++, so a NaN ratio falls through to the dimension test.
    static func isPanorama(frameSize size: PixelSize) -> Bool {
        if aspectRatio(size) <= panoramicImageAspectRatioThreshold { return false }
        let width = Float(size.width), height = Float(size.height)
        return min(width, height) > panoramicImageMinDimension && max(width, height) < panoramicImageMaxDimension
    }
}

// MARK: - Spatial (stereo pair) metadata (ENABLE(SPATIAL_IMAGE_DETECTION))

/// Which image of a stereo-pair group.
@_expose(!Cxx)
enum SpatialEye: Sendable {
    case left, right

    /// kCGImagePropertyGroupImageIndexLeft / ...Right.
    var groupImageIndexKey: CFString {
        switch self {
        case .left: kCGImagePropertyGroupImageIndexLeft
        case .right: kCGImagePropertyGroupImageIndexRight
        }
    }
}

/// Mirrors WebCore::SpatialImageEyeProperties (SpatialImageTypes.h), with the
/// std::array members as fixed-count arrays. Unread camera values are 0; in the
/// C++ they are left uninitialized (`SpatialImageEyeProperties result;`
/// default-initializes the std::array<float> members).
@_expose(!Cxx)
struct SpatialEyeMetadata: Equatable, Sendable {
    static let positionCount = 3
    static let rotationCount = 9
    static let intrinsicsCount = 9

    var groupIndex: UInt32 = 0
    var disparityAdjustment: Float = 0
    var extrinsicsPosition = [Float](repeating: 0, count: positionCount)
    var extrinsicsRotation = [Float](repeating: 0, count: rotationCount)
    var intrinsicsMatrix = [Float](repeating: 0, count: intrinsicsCount)
}

extension ImageDecoderCGProperties {
    /// The first entry of the container's kCGImagePropertyGroups array, if it
    /// is a dictionary (shared by spatialEyeFrameIndex and
    /// spatialEyePropertiesAtIndex in the C++).
    static func spatialGroupInfo(containerProperties: ImageProperties?) -> ImageProperties? {
        guard let groups = containerProperties?.array(kCGImagePropertyGroups), groups.count > 0 else { return nil }
        return groups.dictionary(at: 0)
    }

    /// The C++ reads these into `unsigned` through kCFNumberIntType: the
    /// 32-bit result reinterpreted, so -1 becomes 4294967295. Kept faithfully;
    /// an out-of-range frame index is rejected later by the frame lookups.
    private static func unsignedThroughIntType(_ number: CFNumber) -> UInt32 {
        UInt32(bitPattern: number.value(as: Int32.self).value)
    }

    /// ImageDecoderCG::spatialEyeFrameIndex after its isSpatial() check.
    static func spatialEyeFrameIndex(containerProperties: ImageProperties?, eye: SpatialEye) -> UInt32? {
        guard let number = spatialGroupInfo(containerProperties: containerProperties)?.number(eye.groupImageIndexKey) else { return nil }
        return unsignedThroughIntType(number)
    }

    /// spatialImageEyePropertiesFromDictionary(props, groupInfo).
    static func spatialEyeMetadata(frameProperties: ImageProperties?, groupInfo: ImageProperties?) -> SpatialEyeMetadata? {
        guard let frameProperties, let groupInfo else { return nil }
        var result = SpatialEyeMetadata()

        if let groupIndex = groupInfo.number(kCGImagePropertyGroupIndex) {
            result.groupIndex = unsignedThroughIntType(groupIndex)
        }
        if let disparity = groupInfo.number(kCGImagePropertyGroupImageDisparityAdjustment) {
            result.disparityAdjustment = disparity.value(as: Float.self).value
        }

        if let heif = frameProperties.dictionary(kCGImagePropertyHEIFDictionary) {
            let extrinsics = heif.dictionary(kIIOMetadata_CameraExtrinsicsKey)
            readFloats(extrinsics?.array(kIIOCameraExtrinsics_Position), into: &result.extrinsicsPosition)
            readFloats(extrinsics?.array(kIIOCameraExtrinsics_Rotation), into: &result.extrinsicsRotation)
            readFloats(heif.dictionary(kIIOMetadata_CameraModelKey)?.array(kIIOCameraModel_Intrinsics), into: &result.intrinsicsMatrix)
        }
        return result
    }

    /// Reads `array` element-wise into `values` only when the counts are equal
    /// (the C++ `CFArrayGetCount(...) != N` early return); an element that is
    /// not a CFNumber leaves its slot unchanged.
    private static func readFloats(_ array: ImagePropertyArray?, into values: inout [Float]) {
        guard let array, array.count == values.count else { return }
        for index in values.indices {
            if let number = array.number(at: index) {
                values[index] = number.value(as: Float.self).value
            }
        }
    }
}

// MARK: - Encoded data status

// EncodedDataStatus: declared in ../ImageDecoding.swift (platform-neutral).

extension EncodedDataStatus {
    /// The next status, given the previous one. `frame0Properties` is called
    /// only for an incomplete source whose size is not yet known.
    static func next(after previous: EncodedDataStatus, uti: String, isSupportedImageType: (String) -> Bool, sourceStatus: CGImageSourceStatus, allDataReceived: Bool, frame0Properties: () -> ImageProperties?) -> EncodedDataStatus {
        if previous == .error || previous == .complete { return previous }
        // The image source UTI can change while receiving more encoded data.
        if uti.isEmpty { return .unknown }
        if !isSupportedImageType(uti) { return .error }

        switch sourceStatus {
        case .statusUnknownType:
            return .error
        case .statusUnexpectedEOF, .statusInvalidData, .statusReadingHeader:
            // Ragnaros yells: TOO SOON! You have awakened me TOO SOON, Executus!
            return allDataReceived ? .error : .unknown
        case .statusIncomplete:
            if previous == .sizeAvailable { return previous }
            guard let properties = frame0Properties(),
                  properties.contains(kCGImagePropertyPixelWidth),
                  properties.contains(kCGImagePropertyPixelHeight) else { return .typeAvailable }
            return .sizeAvailable
        case .statusComplete:
            return .complete
        @unknown default:
            // The C++ switch leaves the status unchanged for an unknown value.
            return previous
        }
    }
}

// MARK: - UTI refinement (HEIF vs. AVIF)

@_expose(!Cxx)
enum ImageDecoderCGUTI {
    /// ImageIO reports AVIF as HEIF; look for an "avif"/"avis" brand in the
    /// leading ftyp box to tell them apart.
    ///
    /// aligned(8) class GeneralTypeBox(code) extends Box(code) {
    ///     unsigned int(32) major_brand;
    ///     unsigned int(32) minor_version;
    ///     unsigned int(32) compatible_brands[]; // to end of the box
    /// }
    ///
    /// This overload is for a caller holding all the bytes; it is
    /// refine(uti, prefix: data, byteCount: data.count).
    static func refine(_ uti: String, data: Span<UInt8>) -> String {
        refine(uti, prefix: data, byteCount: data.count)
    }

    /// The most bytes refine reads: the size, type, major_brand and
    /// minor_version words, then at most 100 compatible_brands.
    static let maximumBytesRead = 4 * (4 + 100)

    /// What refine needs of the whole encoded data, for ImageDecoderCG::setData:
    /// its first min(length, maximumBytesRead) bytes and its full length. Made
    /// from the CFData ImageIO is given; NSData.subdata copies exactly that
    /// range (bridging the CFData to Data, or Data(referencing:), would copy the
    /// whole buffer: measured, P4-FIX). Sendable, so it can be taken before the
    /// decoder's source lock and used under it.
    struct LeadingBytes: Sendable {
        let prefix: Data
        let byteCount: Int

        init(_ data: CFData) {
            byteCount = CFDataGetLength(data)
            prefix = (data as NSData).subdata(with: NSRange(location: 0, length: min(byteCount, ImageDecoderCGUTI.maximumBytesRead)))
        }
    }

    static func refine(_ uti: String, leading data: LeadingBytes) -> String {
        refine(uti, prefix: data.prefix.span, byteCount: data.byteCount)
    }

    /// `prefix` is the first min(byteCount, maximumBytesRead) bytes of data
    /// whose full size is `byteCount`. The box size is compared against the FULL
    /// size, as the C++ compares it against data.size(). Reading only the prefix
    /// is equivalent: every word index read is below min(boxWordCount, 104), and
    /// boxWordCount <= byteCount / 4, so it is below min(104, byteCount / 4),
    /// which is the prefix's word count.
    static func refine(_ uti: String, prefix data: Span<UInt8>, byteCount: Int) -> String {
        guard isHEIFFamily(uti) else { return uti }
        assert(data.count >= min(byteCount, maximumBytesRead) && data.count <= byteCount, "refine needs the leading min(byteCount, maximumBytesRead) bytes")

        func brand(_ word: UInt32) -> String? {
            switch word {
            case fourCC("avif"): "public.avif"
            case fourCC("avis"): "public.avis"
            default: nil
            }
        }

        let wordCount = data.count / 4
        // Big-endian 32-bit word `index`, or nil past the end. Every read is
        // bounds-checked by Span, and the nil makes a short box a non-match
        // rather than a trap.
        func word(_ index: Int) -> UInt32? {
            guard index < wordCount else { return nil }
            let base = index * 4
            return UInt32(data[base]) << 24 | UInt32(data[base + 1]) << 16 | UInt32(data[base + 2]) << 8 | UInt32(data[base + 3])
        }

        // A box starts with its size in bytes, including the size field.
        guard let boxByteSize = word(0), boxByteSize % 4 == 0, boxByteSize <= byteCount else { return uti }
        let boxWordCount = Int(boxByteSize / 4)
        guard boxWordCount >= 4, word(1) == fourCC("ftyp") else { return uti }

        if let major = word(2), let avif = brand(major) { return avif }

        // Skip minor_version (word 3); 100 is a reasonable limit for compatible_brands.
        for index in 4..<min(boxWordCount, 4 + 100) {
            if let compatible = word(index), let avif = brand(compatible) { return avif }
        }
        return uti
    }

    private static func isHEIFFamily(_ uti: String) -> Bool {
        uti == "public.heif" || uti == "public.heic" || uti == "public.heics"
    }

    private static func fourCC(_ code: StaticString) -> UInt32 {
        precondition(code.utf8CodeUnitCount == 4)
        var value: UInt32 = 0
        for byte in String(describing: code).utf8 { value = value << 8 | UInt32(byte) }
        return value
    }
}

// MARK: - Density-corrected size (ImageResolution::densityCorrectedSize)

extension DensityCorrectionMetadata {
    /// ImageResolution::ResolutionUnit::Inches.
    static let inches: Int32 = 2

    /// The verbatim arithmetic of ImageResolution::densityCorrectedSize: all
    /// in Float, element-wise, exact equality, then roundedIntSize.
    var correctedSize: PixelSize? {
        func isEmpty(_ size: (width: Float, height: Float)) -> Bool { size.width <= 0 || size.height <= 0 }
        guard resolutionUnit == Self.inches, !isEmpty((resolution.x, resolution.y)), !isEmpty(preferredSize) else { return nil }

        let defaultResolution = Density.defaultResolution
        let fromResolution = (width: sourceSize.width * defaultResolution / resolution.x, height: sourceSize.height * defaultResolution / resolution.y)
        guard fromResolution == preferredSize else { return nil }
        return PixelSize(width: Self.clampToInt32(preferredSize.width.rounded()), height: Self.clampToInt32(preferredSize.height.rounded()))
    }

    /// WTF::clampTo<int>(float). Never sees NaN: preferredSize compared equal above.
    private static func clampToInt32(_ value: Float) -> Int32 {
        if value >= Float(Int32.max) { return .max }
        if value <= Float(Int32.min) { return .min }
        return Int32(value)
    }
}

// MARK: - The stateful decoder core

// DecodingMode: declared in ../ImageDecoding.swift (platform-neutral).

/// The Sendable, lock-protected state of one ImageDecoderCG. Every method is
/// the body of the same-named ImageDecoderCG.cpp method, with WebCore types
/// replaced by the mirrors above; anything that needs WebCore or SPI (MIME
/// registry, soft-linked frameworks, frameGainMapAtIndex's SPI auxiliary-data
/// calls and GainMap construction, iOS caching
/// flags, xbm masking) stays in the C++ adapter, which is given what it needs
/// (isXBitmapImage, raw CGImage, raw auxiliary-data dictionary).
///
/// Locking. Two Mutexes; the order is `source` then `status`, never the
/// reverse, and no closure run under either calls back into this object's
/// locking methods.
///  * `status` holds the small values the C++ kept as plain members (uti,
///    isAllDataReceived, the cached encodedDataStatus, isXBitmapImage). It is
///    only ever held to read or write those values, never across an ImageIO
///    call, so uti(), isAllDataReceived(), isXBitmapImage() and a cached
///    Error/Complete encodedDataStatus() never wait for ImageIO.
///  * `source` holds the CGImageSource. It is held across the cheap ImageIO
///    calls (properties, status, count, CGImageSourceUpdateData), which keeps
///    setData's update + UTI refinement atomic with respect to them, as the
///    one lock did before.
///  * No ImageIO decode runs under either lock. createFrameImage(using:...)
///    (the path the C++ adapter takes) is given the adapter's own reference to
///    the same CGImageSource and calls CGImageSourceCreateImageAtIndex /
///    CGImageSourceCreateThumbnailAtIndex with no Swift lock held. This relies
///    on ImageIO's per-source thread safety: CGImageSource is documented
///    thread-safe, and the C++ ImageDecoderCG already depends on it, because
///    ImageFrameWorkQueue decodes on a background WorkQueue while the main
///    thread calls setData/frameCount on the same source unlocked, and every
///    CGImage from the synchronous path is decoded lazily, at draw time, outside
///    any lock. Swift cannot hold a non-Sendable CGImageSource outside a Mutex in
///    a Sendable class without @unchecked, so the reference that is used
///    unlocked is the caller's, and it is checked to be this decoder's source
///    (sourceIdentity) before use. The region checker still certifies that no
///    CF object read under a lock escapes it except values created fresh for
///    the caller (CGImage, CFDictionary copies).
@_expose(!Cxx)
final class ImageDecoderCGCore: Sendable {
    private struct Status: Sendable {
        var isAllDataReceived = false
        var isXBitmapImage = false
        var encodedDataStatus = EncodedDataStatus.unknown
        var uti = ""
    }

    let configuration: ImageSourceConfiguration
    private let isSupportedImageType: @Sendable (String) -> Bool
    private let preferredFilenameExtension: @Sendable (String) -> String
    private let isSpatialMedia: @Sendable (CGImageSource) -> Bool
    /// The identity of the source in `source`. That source is retained for the
    /// lifetime of this object, so its identifier cannot be reused meanwhile.
    private let sourceIdentity: ObjectIdentifier
    private let source: Mutex<CGImageSource>
    private let status = Mutex(Status())

    /// `typeIdentifierHint` is what the C++ constructor gets from the SPI
    /// CGImageSourceGetTypeWithData(data) when data.size() >= 32; nil otherwise.
    /// `isSupportedImageType` is WebCore::isSupportedImageType (UTIRegistry) and
    /// `preferredFilenameExtension` is WebCore::preferredExtensionForImageType;
    /// both are WebCore policy, so they are injected rather than re-derived.
    /// `isSpatialMedia` is the body of ImageDecoderCG::isSpatial: the
    /// soft-linked PhotosFormats PFMetadataImageSourceIsSpatialMedia, false
    /// when it cannot be loaded. The soft link stays C++; the adapter passes it
    /// under ENABLE(SPATIAL_IMAGE_DETECTION), and the default (false) is the
    /// feature-off behaviour, where the C++ has no override at all.
    convenience init(typeIdentifierHint: String?, configuration: ImageSourceConfiguration, isSupportedImageType: @escaping @Sendable (String) -> Bool, preferredFilenameExtension: @escaping @Sendable (String) -> String, isSpatialMedia: @escaping @Sendable (CGImageSource) -> Bool = { _ in false }) {
        let options: CFDictionary? = typeIdentifierHint.map { [kCGImageSourceTypeIdentifierHint: $0 as CFString] as CFDictionary }
        self.init(source: CGImageSourceCreateIncremental(options), configuration: configuration, isSupportedImageType: isSupportedImageType,
                  preferredFilenameExtension: preferredFilenameExtension, isSpatialMedia: isSpatialMedia)
    }

    /// Over a source the caller created (the C++ constructor's
    /// CGImageSourceCreateIncremental). `sending` is what the region checker
    /// sees; in WebCore the C++ adapter keeps its own reference for the
    /// features that stay C++ (soft-linked MediaAccessibility/PhotosFormats,
    /// SPI gain-map data) and for createFrameImage(using:...), and uses it
    /// outside these Mutexes, exactly as the C++ decoder uses its source today.
    init(source: sending CGImageSource, configuration: ImageSourceConfiguration, isSupportedImageType: @escaping @Sendable (String) -> Bool, preferredFilenameExtension: @escaping @Sendable (String) -> String, isSpatialMedia: @escaping @Sendable (CGImageSource) -> Bool = { _ in false }) {
        self.configuration = configuration
        self.isSupportedImageType = isSupportedImageType
        self.preferredFilenameExtension = preferredFilenameExtension
        self.isSpatialMedia = isSpatialMedia
        sourceIdentity = ObjectIdentifier(source)
        self.source = Mutex(source)
    }

    /// Measured by tracing malloc/calloc calls on Mac OS 10.6.6, x86_64 (see the C++).
    func bytesDecodedToDetermineProperties() -> Int { 13088 }

    // MARK: Encoded data

    /// ImageDecoderCG::setData. `data` is the CFData the C++ hands
    /// CGImageSourceUpdateData (SharedBuffer::createCFData(), which wraps the
    /// buffer without copying), passed through unchanged: no Swift copy of the
    /// encoded bytes is made, and ImageIO retains only the caller's object. The
    /// UTI refinement copies at most ImageDecoderCGUTI.maximumBytesRead bytes.
    /// `sending`: the CFData goes into the source's region (ImageIO keeps it),
    /// so the caller hands it over; from C++ that is a +1 reference.
    func setData(_ data: sending CFData, allDataReceived: Bool) {
        // The same object ImageIO reads; taken before the lock (it is Sendable).
        let leadingBytes = ImageDecoderCGUTI.LeadingBytes(data)
        // withLock's closure is not `sending`, so a CFData it captures stays in
        // the caller's region, and handing it to ImageIO with the locked source
        // would merge the two (RegionIsolation error). The uncontended local
        // Mutex carries the `sending` value across as a disconnected one.
        let carrier = Mutex<CFData?>(data)
        source.withLock { source in
            status.withLock { $0.isAllDataReceived = allDataReceived }
            if let data = carrier.withLock({ $0.take() }) {
                CGImageSourceUpdateData(source, data, allDataReceived)
            }
            let sourceType = (CGImageSourceGetType(source) as String?) ?? ""
            let uti = ImageDecoderCGUTI.refine(sourceType, leading: leadingBytes)
            status.withLock { status in
                status.uti = uti
                status.isXBitmapImage = uti == "public.xbitmap-image"
            }
        }
    }

    /// For Swift callers that hold the bytes as Data (the harnesses).
    func setData(_ data: Data, allDataReceived: Bool) {
        setData(data as CFData, allDataReceived: allDataReceived)
    }

    func isAllDataReceived() -> Bool { status.withLock { $0.isAllDataReceived } }
    func isXBitmapImage() -> Bool { status.withLock { $0.isXBitmapImage } }
    func uti() -> String { status.withLock { $0.uti } }
    func filenameExtension() -> String { preferredFilenameExtension(uti()) }

    /// ImageDecoderCG::encodedDataStatus, which is `const` but caches into a
    /// `mutable` member; here the cache is part of `status`. A cached
    /// Error/Complete, and the empty-UTI Unknown, are answered from `status`
    /// alone, without waiting for the source lock (as the C++ answers them
    /// without touching ImageIO).
    func encodedDataStatus() -> EncodedDataStatus {
        let cached = status.withLock { $0 }
        if cached.encodedDataStatus == .error || cached.encodedDataStatus == .complete { return cached.encodedDataStatus }
        // The C++ returns Unknown for an empty UTI *without* storing it.
        if cached.uti.isEmpty { return .unknown }

        return source.withLock { source in
            // Re-read under the source lock: a setData that held it may have
            // changed the UTI or the status since the read above.
            let current = status.withLock { $0 }
            let previous = current.encodedDataStatus
            if previous == .error || previous == .complete { return previous }
            if current.uti.isEmpty { return .unknown }
            let options = ImageSourceOptions.decode(configuration)
            let next = EncodedDataStatus.next(
                after: previous, uti: current.uti, isSupportedImageType: isSupportedImageType,
                sourceStatus: CGImageSourceGetStatus(source), allDataReceived: current.isAllDataReceived,
                frame0Properties: { ImageProperties(CGImageSourceCopyPropertiesAtIndex(source, 0, options)) })
            status.withLock { $0.encodedDataStatus = next }
            return next
        }
    }

    // MARK: Container

    func frameCount() -> Int { source.withLock { CGImageSourceGetCount($0) } }
    func primaryFrameIndex() -> Int { source.withLock { CGImageSourceGetPrimaryImageIndex($0) } }

    func repetitionCount() -> Int32 {
        source.withLock { source in
            let properties = ImageProperties(CGImageSourceCopyProperties(source, ImageSourceOptions.decode(configuration)))
            return ImageDecoderCGProperties.repetitionCount(containerProperties: properties)
        }
    }

    /// HAVE(SUPPORT_HDR_DISPLAY) arm; the adapter returns false where it is not defined.
    func hasHDRGainMap() -> Bool {
        source.withLock { source in
            let properties = ImageProperties(CGImageSourceCopyProperties(source, ImageSourceOptions.metadata(configuration)))
            return ImageDecoderCGProperties.hasHDRGainMap(containerMetadataProperties: properties)
        }
    }

    // MARK: Spatial (ENABLE(SPATIAL_IMAGE_DETECTION))

    /// ImageDecoderCG::isSpatial.
    func isSpatial() -> Bool {
        source.withLock { isSpatialMedia($0) }
    }

    /// ImageDecoderCG::spatialLeftEyeFrameIndex.
    func spatialLeftEyeFrameIndex() -> UInt32? { spatialEyeFrameIndex(.left) }

    /// ImageDecoderCG::spatialRightEyeFrameIndex.
    func spatialRightEyeFrameIndex() -> UInt32? { spatialEyeFrameIndex(.right) }

    /// ImageDecoderCG::spatialEyeFrameIndex: container properties fetched with
    /// null options, as in the C++.
    private func spatialEyeFrameIndex(_ eye: SpatialEye) -> UInt32? {
        source.withLock { source in
            guard isSpatialMedia(source) else { return nil }
            let container = ImageProperties(CGImageSourceCopyProperties(source, nil))
            return ImageDecoderCGProperties.spatialEyeFrameIndex(containerProperties: container, eye: eye)
        }
    }

    /// ImageDecoderCG::spatialEyePropertiesAtIndex. Named differently from the
    /// ImageDecoding requirement because SpatialImageEyeProperties lives in
    /// ImageDecoding.swift, which the differential harness does not compile.
    func spatialEyeMetadata(at index: UInt32) -> SpatialEyeMetadata? {
        source.withLock { source in
            guard isSpatialMedia(source) else { return nil }
            let container = ImageProperties(CGImageSourceCopyProperties(source, nil))
            guard let groupInfo = ImageDecoderCGProperties.spatialGroupInfo(containerProperties: container),
                  // size_t(unsigned): cannot fail on 64-bit; on a 32-bit Int a
                  // huge index is one ImageIO would reject anyway (null props).
                  let frameIndex = Int(exactly: index) else { return nil }
            let properties = ImageProperties(CGImageSourceCopyPropertiesAtIndex(source, frameIndex, ImageSourceOptions.metadata(configuration)))
            return ImageDecoderCGProperties.spatialEyeMetadata(frameProperties: properties, groupInfo: groupInfo)
        }
    }

    func hotSpotCoordinates() -> (x: Int32, y: Int32)? {
        source.withLock { source in
            ImageDecoderCGProperties.hotSpot(ImageProperties(CGImageSourceCopyPropertiesAtIndex(source, 0, ImageSourceOptions.decode(configuration))))
        }
    }

    // MARK: Frames

    private static func properties(_ source: CGImageSource, at index: Int, _ options: CFDictionary) -> ImageProperties? {
        ImageProperties(CGImageSourceCopyPropertiesAtIndex(source, index, options))
    }

    func frameSize(at index: Int, subsampling: SubsamplingLevel = 0) -> PixelSize {
        source.withLock { ImageDecoderCGProperties.frameSize(Self.properties($0, at: index, ImageSourceOptions.decode(configuration, subsampling: subsampling))) }
    }

    /// The C++ passes a null dictionary to CFDictionaryGetValue (crash) when
    /// the frame has no properties; here that is the default density.
    func frameDensity(at index: Int) -> Density {
        source.withLock { Self.properties($0, at: index, ImageSourceOptions.decode(configuration)).map(ImageDecoderCGProperties.density) ?? .default }
    }

    /// Raw EXIF orientation, or nil for ImageOrientation::Orientation::None.
    func frameEXIFOrientation(at index: Int) -> Int32? {
        source.withLock { Self.properties($0, at: index, ImageSourceOptions.decode(configuration)).flatMap(ImageDecoderCGProperties.exifOrientation) }
    }

    func frameDensityCorrectedSize(at index: Int) -> PixelSize? {
        source.withLock { source in
            guard let properties = Self.properties(source, at: index, ImageSourceOptions.decode(configuration)),
                  ImageDecoderCGProperties.mayHaveDensityCorrectedSize(properties),
                  let withMetadata = Self.properties(source, at: index, ImageSourceOptions.metadata(configuration)) else { return nil }
            return ImageDecoderCGProperties.densityCorrectionMetadata(withMetadata)?.correctedSize
        }
    }

    func frameDuration(at index: Int) -> Double {
        source.withLock { source in
            let options = ImageSourceOptions.decode(configuration)
            return ImageDecoderCGProperties.frameDuration(
                frameProperties: Self.properties(source, at: index, options),
                containerProperties: { ImageProperties(CGImageSourceCopyProperties(source, options)) },
                frame: index)
        }
    }

    func frameIsComplete(at index: Int) -> Bool {
        source.withLock { Self.frameIsComplete($0, at: index) }
    }

    /// CGImageSourceGetStatusAtIndex() only reports Complete for frames that are
    /// neither first nor last; use the source status for the last frame.
    private static func frameIsComplete(_ source: CGImageSource, at index: Int) -> Bool {
        if index == CGImageSourceGetCount(source) - 1 {
            return CGImageSourceGetStatus(source) == .statusComplete
        }
        return CGImageSourceGetStatusAtIndex(source, index) == .statusComplete
    }

    /// ImageDecoderCG::hasAlpha: false only for no type or JPEG.
    private func hasAlpha() -> Bool {
        let uti = uti()
        return !(uti.isEmpty || uti == "public.jpeg")
    }

    func frameHasAlpha(at index: Int) -> Bool {
        source.withLock { !Self.frameIsComplete($0, at: index) || hasAlpha() }
    }

    /// Everything ImageDecoderCG::fetchFrameMetaDataAtIndex computes, read
    /// under one source-lock acquisition. The adapter writes it into ImageFrame
    /// (the friend access Swift cannot have), including m_size for sizeForDrawing.
    struct FrameMetadata {
        var naturalSize: PixelSize
        var density: Density
        var densityCorrectedSize: PixelSize?
        var isComplete: Bool
        var hasAlpha: Bool
        var exifOrientation: Int32?
    }

    func frameMetadata(at index: Int, subsampling: SubsamplingLevel) -> FrameMetadata? {
        source.withLock { source in
            guard let properties = Self.properties(source, at: index, ImageSourceOptions.decode(configuration, subsampling: subsampling)) else { return nil }
            var densityCorrectedSize: PixelSize?
            if ImageDecoderCGProperties.mayHaveDensityCorrectedSize(properties),
               let withMetadata = Self.properties(source, at: index, ImageSourceOptions.metadata(configuration)) {
                densityCorrectedSize = ImageDecoderCGProperties.densityCorrectionMetadata(withMetadata)?.correctedSize
            }
            let isComplete = Self.frameIsComplete(source, at: index)
            return FrameMetadata(
                naturalSize: ImageDecoderCGProperties.frameSize(properties),
                density: ImageDecoderCGProperties.density(properties),
                densityCorrectedSize: densityCorrectedSize,
                isComplete: isComplete,
                hasAlpha: !isComplete || hasAlpha(),
                exifOrientation: ImageDecoderCGProperties.exifOrientation(properties))
        }
    }

    /// The image-source half of ImageDecoderCG::createFrameImageAtIndex, on the
    /// caller's reference to this decoder's source, with no Swift lock held
    /// during the decode (see "Locking" above). This is the path the C++
    /// adapter takes. `source` must be the CGImageSource this decoder was
    /// created over; anything else is a programming error and traps.
    /// The adapter applies kCGImageCachingTemporary (iOS) and, when
    /// isXBitmapImage, CGImageCreateWithMaskingColors, as before.
    /// `mode` must not be .auto (the C++ asserts); .auto decodes as asynchronous.
    func createFrameImage(using source: CGImageSource, at index: Int, subsampling: SubsamplingLevel = 0, mode: DecodingMode = .synchronous, destination: DecodingDestination = .base, sizeForDrawing: PixelSize? = nil) -> CGImage? {
        precondition(ObjectIdentifier(source) == sourceIdentity, "createFrameImage(using:) needs this decoder's own CGImageSource")
        return Self.createFrameImage(source, configuration, at: index, subsampling: subsampling, mode: mode, destination: destination, sizeForDrawing: sizeForDrawing)
    }

    /// The same decode for a Swift caller that holds no reference of its own:
    /// it can only reach the source through the source lock, so this one is
    /// serialized with the other source calls (but never with uti(),
    /// isAllDataReceived() or a cached encodedDataStatus()).
    func createFrameImage(at index: Int, subsampling: SubsamplingLevel = 0, mode: DecodingMode = .synchronous, destination: DecodingDestination = .base, sizeForDrawing: PixelSize? = nil) -> CGImage? {
        source.withLock { Self.createFrameImage($0, configuration, at: index, subsampling: subsampling, mode: mode, destination: destination, sizeForDrawing: sizeForDrawing) }
    }

    private static func createFrameImage(_ source: CGImageSource, _ configuration: ImageSourceConfiguration, at index: Int, subsampling: SubsamplingLevel, mode: DecodingMode, destination: DecodingDestination, sizeForDrawing: PixelSize?) -> CGImage? {
        if mode == .synchronous {
            // The returned CGImage is decoded lazily, at draw time, by ImageIO.
            return CGImageSourceCreateImageAtIndex(source, index, ImageSourceOptions.decode(configuration, subsampling: subsampling, destination: destination))
        }
        // frameSizeAtIndex(index, SubsamplingLevel::Default).
        var size = ImageDecoderCGProperties.frameSize(properties(source, at: index, ImageSourceOptions.decode(configuration)))
        // Don't consider the subsampling level when comparing the native size with sizeForDrawing.
        if let sizeForDrawing, unclampedArea(sizeForDrawing) < unclampedArea(size) {
            size = sizeForDrawing
        }
        // `unsigned maxDimension` stored through kCFNumberIntType.
        let maxDimension = Int32(truncatingIfNeeded: max(size.width, size.height))
        return CGImageSourceCreateThumbnailAtIndex(source, index, ImageSourceOptions.thumbnail(configuration, subsampling: subsampling, maxPixelSize: maxDimension, destination: destination))
    }

    /// IntSize::unclampedArea: |Int64(w) * h|, which cannot overflow Int64.
    private static func unclampedArea(_ size: PixelSize) -> UInt64 {
        (Int64(size.width) * Int64(size.height)).magnitude
    }
}

#endif // ENABLE_IMAGE_DECODER_CG_SWIFT
