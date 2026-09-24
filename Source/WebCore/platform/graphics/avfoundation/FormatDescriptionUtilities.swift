/*
 * Copyright (C) 2021-2026 Apple Inc. All rights reserved.
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
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

// The CMFormatDescription readers of FormatDescriptionUtilities.cpp, in Swift: the track type,
// presentation size, colour space, field count, field detail, and protected-content test of a
// format description. Every input is handled here, including a null or malformed description.
//
// The boundary is @_cdecl because WebCore sets SWIFT_INSTALL_OBJC_HEADER = NO, so C++ cannot
// name a Swift declaration. Each result crosses as a scalar, and FormatDescriptionUtilities.cpp
// rebuilds the C++ type from it:
// - track type, field count, field detail: the enumerator's raw value as a uint8_t. A disengaged
//   field count is 0 (no enumerator has that value); a disengaged field detail is 0xFF.
// - presentation size: a CGSize, zero for a null description.
// - colour space: a uint64_t. 0 is std::nullopt. Otherwise bit 63 is set and each byte holds one
//   field: 0 for a disengaged field, else the enumerator's raw value + 1 (for fullRange, 1 is
//   false and 2 is true). Bits 0-7 primaries, 8-15 transfer, 16-23 matrix, 24-31 fullRange,
//   32-39 chromaLocation.
//
// CoreMedia and VideoToolbox are soft-linked by WebCore, so every function and constant from
// them is reached through its PAL soft-link accessor, never through the SDK symbol. CoreVideo
// constants go through WebCore's own soft-link accessors, as the C++ does.
//
// The gate has no parentheses on purpose: generate-platform-args passes
// -DENABLE_FORMAT_DESCRIPTION_UTILITIES_SWIFT to swiftc for a truthy ENABLE() macro, so the
// Swift spelling of the same gate is a bare identifier.

#if ENABLE_FORMAT_DESCRIPTION_UTILITIES_SWIFT

internal import CoreFoundation
internal import CoreGraphics
internal import CoreMedia
internal import Foundation
internal import WebCore_Private
internal import pal.Core.cf.CoreMediaSoftLink
internal import pal.Core.cf.VideoToolboxSoftLink

// MARK: - Mirrors of the C++ enums

// Each enum below mirrors a C++ enum class. The raw values are the C++ enumerators' values,
// spelled explicitly because the two declarations are separate texts that must agree: the value
// crosses the @_cdecl boundary as a uint8_t. WebIDL-only aliases (Smpte432, PQ, HLG, Bt2020Ncl,
// Bt2020Cl) name values already listed and are omitted.

/// Mirror of `WebCore::TrackInfoTrackType` in TrackInfo.h.
private enum TrackInfoTrackType: Swift.UInt8 {
    case Unknown = 0
    case Audio = 1
    case Video = 2
    case Text = 3
}

/// Mirror of `WebCore::PlatformVideoFieldCount` in TrackInfo.h.
private enum PlatformVideoFieldCount: Swift.UInt8 {
    case Progressive = 1
    case Interlaced = 2
}

/// Mirror of `WebCore::PlatformVideoFieldDetail` in TrackInfo.h.
private enum PlatformVideoFieldDetail: Swift.UInt8 {
    case TemporalTopFirst = 0
    case TemporalBottomFirst = 1
    case SpatialFirstLineEarly = 2
    case SpatialFirstLineLate = 3
}

/// Mirror of `WebCore::PlatformVideoColorPrimaries` in PlatformVideoColorPrimaries.h.
private enum PlatformVideoColorPrimaries: Swift.UInt8 {
    case Bt709 = 0
    case Bt470bg = 1
    case Smpte170m = 2
    case Bt470m = 3
    case Smpte240m = 4
    case Film = 5
    case Bt2020 = 6
    case SmpteSt4281 = 7
    case SmpteRp431 = 8
    case SmpteEg432 = 9
    case JedecP22Phosphors = 10
    case Unspecified = 11
}

/// Mirror of `WebCore::PlatformVideoTransferCharacteristics` in
/// PlatformVideoTransferCharacteristics.h.
private enum PlatformVideoTransferCharacteristics: Swift.UInt8 {
    case Bt709 = 0
    case Smpte170m = 1
    case Iec6196621 = 2
    case Gamma22curve = 3
    case Gamma28curve = 4
    case Smpte240m = 5
    case Linear = 6
    case Log = 7
    case LogSqrt = 8
    case Iec6196624 = 9
    case Bt1361ExtendedColourGamut = 10
    case Bt2020_10bit = 11
    case Bt2020_12bit = 12
    case SmpteSt2084 = 13
    case SmpteSt4281 = 14
    case AribStdB67Hlg = 15
    case Unspecified = 16
}

/// Mirror of `WebCore::PlatformVideoMatrixCoefficients` in PlatformVideoMatrixCoefficients.h.
private enum PlatformVideoMatrixCoefficients: Swift.UInt8 {
    case Rgb = 0
    case Bt709 = 1
    case Bt470bg = 2
    case Smpte170m = 3
    case Smpte240m = 4
    case Fcc = 5
    case YCgCo = 6
    case Bt2020NonconstantLuminance = 7
    case Bt2020ConstantLuminance = 8
    case Unspecified = 9
}

/// Mirror of `WebCore::PlatformVideoChromaLocation` in PlatformVideoChromaLocation.h.
private enum PlatformVideoChromaLocation: Swift.UInt8 {
    case Left = 0
    case Center = 1
    case TopLeft = 2
    case Top = 3
    case BottomLeft = 4
    case Bottom = 5
    case Dv420 = 6
    case Unspecified = 7
}

/// The Swift counterpart of `WebCore::PlatformVideoColorSpace`: five independently optional
/// fields, all disengaged until set. It exists only inside this file; `packed()` is the form
/// that crosses to C++.
private struct PlatformVideoColorSpace {
    var primaries: PlatformVideoColorPrimaries?
    var transfer: PlatformVideoTransferCharacteristics?
    var matrix: PlatformVideoMatrixCoefficients?
    var fullRange: Swift.Bool?
    var chromaLocation: PlatformVideoChromaLocation?

    /// The engaged-optional encoding described at the top of this file. Never 0.
    func packed() -> Swift.UInt64 {
        var bits: Swift.UInt64 = 1 << 63
        if let primaries {
            bits |= Swift.UInt64(primaries.rawValue) + 1
        }
        if let transfer {
            bits |= (Swift.UInt64(transfer.rawValue) + 1) << 8
        }
        if let matrix {
            bits |= (Swift.UInt64(matrix.rawValue) + 1) << 16
        }
        if let fullRange {
            bits |= Swift.UInt64(fullRange ? 2 : 1) << 24
        }
        if let chromaLocation {
            bits |= (Swift.UInt64(chromaLocation.rawValue) + 1) << 32
        }
        return bits
    }
}

// MARK: - Soft-linked constants

/// Every CoreVideo and CoreMedia constant the colour-space reader compares against, read in one
/// expression so the Unmanaged-to-managed claim is made once for all of them.
private struct ColorSpaceConstants {
    let colorPrimariesKey: CFString?
    let transferFunctionKey: CFString?
    let yCbCrMatrixKey: CFString?
    let gammaLevelKey: CFString?
    let fullRangeVideoKey: CFString?
    let chromaLocationTopFieldKey: CFString?
    let chromaLocationBottomFieldKey: CFString?

    let colorPrimaries_ITU_R_709_2: CFString?
    let colorPrimaries_EBU_3213: CFString?
    let colorPrimaries_P22: CFString?
    let colorPrimaries_SMPTE_C: CFString?
    let colorPrimaries_DCI_P3: CFString?
    let colorPrimaries_P3_D65: CFString?
    let colorPrimaries_ITU_R_2020: CFString?

    let transferFunction_ITU_R_709_2: CFString?
    let transferFunction_SMPTE_240M_1995: CFString?
    let transferFunction_UseGamma: CFString?
    let transferFunction_SMPTE_ST_2084_PQ: CFString?
    let transferFunction_ITU_R_2020: CFString?
    let transferFunction_SMPTE_ST_428_1: CFString?
    let transferFunction_ITU_R_2100_HLG: CFString?
    let transferFunction_sRGB: CFString?
    let transferFunction_Linear: CFString?

    let yCbCrMatrix_ITU_R_2020: CFString?
    let yCbCrMatrix_ITU_R_601_4: CFString?
    let yCbCrMatrix_ITU_R_709_2: CFString?
    let yCbCrMatrix_SMPTE_240M_1995: CFString?

    let chromaLocation_Left: CFString?
    let chromaLocation_Center: CFString?
    let chromaLocation_TopLeft: CFString?
    let chromaLocation_Top: CFString?
    let chromaLocation_BottomLeft: CFString?
    let chromaLocation_Bottom: CFString?
    let chromaLocation_DV420: CFString?

    static func load() -> ColorSpaceConstants {
        // SAFETY: each get_*Singleton() returns a +0 reference to an immutable CFString constant
        // exported by CoreVideo or CoreMedia, which stays loaded for the life of the process, so
        // takeUnretainedValue() yields a live object that the managed reference then retains.
        // Not provable today because SOFT_LINK_CONSTANT_FOR_HEADER declares the getters outside
        // any CF-audited region and without CF_RETURNS_NOT_RETAINED, so Swift imports their
        // CFStringRef results as Unmanaged and cannot know the +0 convention.
        unsafe ColorSpaceConstants(
            colorPrimariesKey: WebCore_Private.WebCore.get_CoreVideo_kCVImageBufferColorPrimariesKeySingleton()?.takeUnretainedValue(),
            transferFunctionKey: WebCore_Private.WebCore.get_CoreVideo_kCVImageBufferTransferFunctionKeySingleton()?.takeUnretainedValue(),
            yCbCrMatrixKey: WebCore_Private.WebCore.get_CoreVideo_kCVImageBufferYCbCrMatrixKeySingleton()?.takeUnretainedValue(),
            gammaLevelKey: WebCore_Private.WebCore.get_CoreVideo_kCVImageBufferGammaLevelKeySingleton()?.takeUnretainedValue(),
            fullRangeVideoKey: PAL.get_CoreMedia_kCMFormatDescriptionExtension_FullRangeVideoSingleton()?.takeUnretainedValue(),
            chromaLocationTopFieldKey: WebCore_Private.WebCore.get_CoreVideo_kCVImageBufferChromaLocationTopFieldKeySingleton()?.takeUnretainedValue(),
            chromaLocationBottomFieldKey: WebCore_Private.WebCore.get_CoreVideo_kCVImageBufferChromaLocationBottomFieldKeySingleton()?.takeUnretainedValue(),
            colorPrimaries_ITU_R_709_2: WebCore_Private.WebCore.get_CoreVideo_kCVImageBufferColorPrimaries_ITU_R_709_2Singleton()?.takeUnretainedValue(),
            colorPrimaries_EBU_3213: WebCore_Private.WebCore.get_CoreVideo_kCVImageBufferColorPrimaries_EBU_3213Singleton()?.takeUnretainedValue(),
            colorPrimaries_P22: WebCore_Private.WebCore.get_CoreVideo_kCVImageBufferColorPrimaries_P22Singleton()?.takeUnretainedValue(),
            colorPrimaries_SMPTE_C: WebCore_Private.WebCore.get_CoreVideo_kCVImageBufferColorPrimaries_SMPTE_CSingleton()?.takeUnretainedValue(),
            colorPrimaries_DCI_P3: WebCore_Private.WebCore.get_CoreVideo_kCVImageBufferColorPrimaries_DCI_P3Singleton()?.takeUnretainedValue(),
            colorPrimaries_P3_D65: WebCore_Private.WebCore.get_CoreVideo_kCVImageBufferColorPrimaries_P3_D65Singleton()?.takeUnretainedValue(),
            colorPrimaries_ITU_R_2020: WebCore_Private.WebCore.get_CoreVideo_kCVImageBufferColorPrimaries_ITU_R_2020Singleton()?.takeUnretainedValue(),
            transferFunction_ITU_R_709_2: WebCore_Private.WebCore.get_CoreVideo_kCVImageBufferTransferFunction_ITU_R_709_2Singleton()?.takeUnretainedValue(),
            transferFunction_SMPTE_240M_1995: WebCore_Private.WebCore.get_CoreVideo_kCVImageBufferTransferFunction_SMPTE_240M_1995Singleton()?.takeUnretainedValue(),
            transferFunction_UseGamma: WebCore_Private.WebCore.get_CoreVideo_kCVImageBufferTransferFunction_UseGammaSingleton()?.takeUnretainedValue(),
            transferFunction_SMPTE_ST_2084_PQ: PAL.get_CoreMedia_kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQSingleton()?.takeUnretainedValue(),
            transferFunction_ITU_R_2020: PAL.get_CoreMedia_kCMFormatDescriptionTransferFunction_ITU_R_2020Singleton()?.takeUnretainedValue(),
            transferFunction_SMPTE_ST_428_1: PAL.get_CoreMedia_kCMFormatDescriptionTransferFunction_SMPTE_ST_428_1Singleton()?.takeUnretainedValue(),
            transferFunction_ITU_R_2100_HLG: PAL.get_CoreMedia_kCMFormatDescriptionTransferFunction_ITU_R_2100_HLGSingleton()?.takeUnretainedValue(),
            transferFunction_sRGB: PAL.get_CoreMedia_kCMFormatDescriptionTransferFunction_sRGBSingleton()?.takeUnretainedValue(),
            transferFunction_Linear: PAL.get_CoreMedia_kCMFormatDescriptionTransferFunction_LinearSingleton()?.takeUnretainedValue(),
            yCbCrMatrix_ITU_R_2020: WebCore_Private.WebCore.get_CoreVideo_kCVImageBufferYCbCrMatrix_ITU_R_2020Singleton()?.takeUnretainedValue(),
            yCbCrMatrix_ITU_R_601_4: WebCore_Private.WebCore.get_CoreVideo_kCVImageBufferYCbCrMatrix_ITU_R_601_4Singleton()?.takeUnretainedValue(),
            yCbCrMatrix_ITU_R_709_2: WebCore_Private.WebCore.get_CoreVideo_kCVImageBufferYCbCrMatrix_ITU_R_709_2Singleton()?.takeUnretainedValue(),
            yCbCrMatrix_SMPTE_240M_1995: WebCore_Private.WebCore.get_CoreVideo_kCVImageBufferYCbCrMatrix_SMPTE_240M_1995Singleton()?.takeUnretainedValue(),
            chromaLocation_Left: WebCore_Private.WebCore.get_CoreVideo_kCVImageBufferChromaLocation_LeftSingleton()?.takeUnretainedValue(),
            chromaLocation_Center: WebCore_Private.WebCore.get_CoreVideo_kCVImageBufferChromaLocation_CenterSingleton()?.takeUnretainedValue(),
            chromaLocation_TopLeft: WebCore_Private.WebCore.get_CoreVideo_kCVImageBufferChromaLocation_TopLeftSingleton()?.takeUnretainedValue(),
            chromaLocation_Top: WebCore_Private.WebCore.get_CoreVideo_kCVImageBufferChromaLocation_TopSingleton()?.takeUnretainedValue(),
            chromaLocation_BottomLeft: WebCore_Private.WebCore.get_CoreVideo_kCVImageBufferChromaLocation_BottomLeftSingleton()?.takeUnretainedValue(),
            chromaLocation_Bottom: WebCore_Private.WebCore.get_CoreVideo_kCVImageBufferChromaLocation_BottomSingleton()?.takeUnretainedValue(),
            chromaLocation_DV420: WebCore_Private.WebCore.get_CoreVideo_kCVImageBufferChromaLocation_DV420Singleton()?.takeUnretainedValue()
        )
    }
}

/// The CoreVideo constants the field-count and field-detail readers use.
private struct FieldConstants {
    let fieldCountKey: CFString?
    let fieldDetailKey: CFString?
    let fieldDetailTemporalTopFirst: CFString?
    let fieldDetailTemporalBottomFirst: CFString?
    let fieldDetailSpatialFirstLineEarly: CFString?
    let fieldDetailSpatialFirstLineLate: CFString?

    static func load() -> FieldConstants {
        // SAFETY: each get_*Singleton() returns a +0 reference to an immutable CFString constant
        // exported by CoreVideo, which stays loaded for the life of the process, so
        // takeUnretainedValue() yields a live object that the managed reference then retains.
        // Not provable today because SOFT_LINK_CONSTANT_FOR_HEADER declares the getters outside
        // any CF-audited region and without CF_RETURNS_NOT_RETAINED, so Swift imports their
        // CFStringRef results as Unmanaged and cannot know the +0 convention.
        unsafe FieldConstants(
            fieldCountKey: WebCore_Private.WebCore.get_CoreVideo_kCVImageBufferFieldCountKeySingleton()?.takeUnretainedValue(),
            fieldDetailKey: WebCore_Private.WebCore.get_CoreVideo_kCVImageBufferFieldDetailKeySingleton()?.takeUnretainedValue(),
            fieldDetailTemporalTopFirst: WebCore_Private.WebCore.get_CoreVideo_kCVImageBufferFieldDetailTemporalTopFirstSingleton()?.takeUnretainedValue(),
            fieldDetailTemporalBottomFirst: WebCore_Private.WebCore.get_CoreVideo_kCVImageBufferFieldDetailTemporalBottomFirstSingleton()?.takeUnretainedValue(),
            fieldDetailSpatialFirstLineEarly: WebCore_Private.WebCore.get_CoreVideo_kCVImageBufferFieldDetailSpatialFirstLineEarlySingleton()?.takeUnretainedValue(),
            fieldDetailSpatialFirstLineLate: WebCore_Private.WebCore.get_CoreVideo_kCVImageBufferFieldDetailSpatialFirstLineLateSingleton()?.takeUnretainedValue()
        )
    }
}

// MARK: - CF helpers

/// `formatDescription`'s extension for `key`, or nil if it has none.
private func formatDescriptionExtension(_ formatDescription: CMFormatDescription, _ key: CFString?) -> Swift.AnyObject? {
    // SAFETY: CMFormatDescriptionGetExtension follows the CF Get rule: the result is +0 and is
    // owned by the extensions dictionary of `formatDescription`, which is immutable and which
    // the caller keeps alive across this call, so takeUnretainedValue() yields a live object
    // that the managed reference then retains.
    // Not provable today because the PAL soft-link wrapper is a C++ inline function without
    // CF_RETURNS_NOT_RETAINED, so Swift imports its CFPropertyListRef result as Unmanaged.
    unsafe PAL.softLink_CoreMedia_CMFormatDescriptionGetExtension(formatDescription, key)?.takeUnretainedValue()
}

/// `object` as a `T` if its CF type is `typeID`, else nil: WTF's `dynamic_cf_cast`.
///
/// A Swift `as?` to a CF type does not consult the CF type ID and succeeds for every CF object,
/// so the check is made here with CFGetTypeID. Each caller below passes the type ID that
/// belongs to `T`.
private func dynamicCFCast<T: Swift.AnyObject>(_ object: Swift.AnyObject?, typeID: CFTypeID, as _: T.Type) -> T? {
    guard let object, CFGetTypeID(object) == typeID else {
        return nil
    }
    return (object as! T)
}

private func dynamicCFString(_ object: Swift.AnyObject?) -> CFString? {
    dynamicCFCast(object, typeID: CFStringGetTypeID(), as: CFString.self)
}

private func dynamicCFNumber(_ object: Swift.AnyObject?) -> CFNumber? {
    dynamicCFCast(object, typeID: CFNumberGetTypeID(), as: CFNumber.self)
}

private func dynamicCFBoolean(_ object: Swift.AnyObject?) -> CFBoolean? {
    dynamicCFCast(object, typeID: CFBooleanGetTypeID(), as: CFBoolean.self)
}

/// WTF's `safeCFEqual` for a non-null left-hand side: false if `constant` is nil.
private func cfEqual(_ string: CFString, _ constant: CFString?) -> Swift.Bool {
    guard let constant else {
        return false
    }
    return CFEqual(string, constant)
}

/// A scalar type CFNumberGetValue can write, paired with the CFNumberType of exactly its layout.
/// BitwiseCopyable lets the compiler check that `T` holds no object reference CFNumberGetValue
/// could overwrite.
private protocol CFNumberScalar: Swift.BitwiseCopyable {
    static var cfNumberType: CFNumberType { get }
    init()
}

extension Swift.Double: CFNumberScalar {
    fileprivate static var cfNumberType: CFNumberType { .float64Type }
}

extension Swift.Int32: CFNumberScalar {
    // kCFNumberIntType is C `int`, which is 32 bits on every Apple platform.
    fileprivate static var cfNumberType: CFNumberType { .intType }
}

/// CFNumberGetValue into a zero-initialised `T`: its Boolean result (false for a lossy
/// conversion) and whatever it wrote.
private func cfNumberValue<T: CFNumberScalar>(_ number: CFNumber, as _: T.Type) -> (converted: Swift.Bool, value: T) {
    var value = T()
    // SAFETY: `&value` is a pointer to a live, exclusively accessed `T` for the duration of the
    // call, and T.cfNumberType names a CF number type whose size and layout are exactly T's, so
    // CFNumberGetValue writes only within `value`.
    // Not provable today because CFNumberGetValue takes an untyped `void *` whose required size
    // depends on the runtime CFNumberType argument.
    let converted = unsafe CFNumberGetValue(number, T.cfNumberType, &value)
    return (converted, value)
}

/// A float dimension as the size_t VTGetDefaultColorAttributesWithHints takes, converted as C++
/// converts a `float` to `size_t`: truncated toward zero.
///
/// That conversion is defined in C++ only for values in (-1, 2^64). Values in (-1, 2^63) are
/// converted exactly as C++ does. Everything else (negative, NaN, infinite, or too large for
/// Int) is undefined behaviour in the C++ and would trap here, so it becomes 0 instead; a
/// presentation dimension is never any of those for a real format description, where it is a
/// non-negative pixel count.
private func sizeHint(_ dimension: Swift.Float) -> Swift.Int {
    guard dimension > -1, dimension < 0x1p63 else {
        return 0
    }
    return Swift.Int(dimension)
}

/// VTGetDefaultColorAttributesWithHints' defaults for a codec and size: primaries, transfer
/// function, and YCbCr matrix, each nil if VideoToolbox supplied none. Its OSStatus is ignored,
/// as the C++ ignores it; an out-parameter it does not write stays nil.
private func defaultColorAttributes(codecType: Swift.UInt32, width: Swift.Int, height: Swift.Int) -> (primaries: CFString?, transfer: CFString?, matrix: CFString?) {
    var primaries: Unmanaged<CFString>? = nil
    var transfer: Unmanaged<CFString>? = nil
    var matrix: Unmanaged<CFString>? = nil
    // SAFETY: each `&` argument is a pointer to a live local Optional<Unmanaged<CFString>>,
    // initialised to nil, that VideoToolbox writes a CFStringRef into or leaves alone; nothing
    // else accesses the locals during the call.
    // Not provable today because the soft-link wrapper takes `CFStringRef *` out-parameters,
    // which Swift imports as unsafe pointers to Unmanaged.
    _ = unsafe PAL.softLink_VideoToolbox_VTGetDefaultColorAttributesWithHints(codecType, nil, width, height, &primaries, &transfer, &matrix)
    // SAFETY: VTGetDefaultColorAttributesWithHints returns its out-parameters at +0, and they
    // are VideoToolbox's own immutable CFString constants, which stay loaded for the life of the
    // process, so takeUnretainedValue() yields live objects that the managed references retain.
    // Not provable today because the out-parameters carry no CF_RETURNS_NOT_RETAINED
    // annotation, so Swift cannot know their ownership convention and leaves them Unmanaged.
    return unsafe (primaries?.takeUnretainedValue(), transfer?.takeUnretainedValue(), matrix?.takeUnretainedValue())
}

// MARK: - Readers

/// The display size of `formatDescription`, with pixel aspect ratio and clean aperture applied,
/// narrowed to the `float` precision of `WebCore::FloatSize`. Zero for nil.
private func presentationSize(_ formatDescription: CMFormatDescription?) -> (width: Swift.Float, height: Swift.Float) {
    let size = webCoreFormatDescriptionPresentationSize(formatDescription)
    return (Swift.Float(size.width), Swift.Float(size.height))
}

private func colorSpace(_ formatDescription: CMFormatDescription) -> PlatformVideoColorSpace {
    let constants = ColorSpaceConstants.load()
    var colorSpace = PlatformVideoColorSpace()

    var primaries = dynamicCFString(formatDescriptionExtension(formatDescription, constants.colorPrimariesKey))
    var transfer = dynamicCFString(formatDescriptionExtension(formatDescription, constants.transferFunctionKey))
    var matrix = dynamicCFString(formatDescriptionExtension(formatDescription, constants.yCbCrMatrixKey))

    // VideoToolbox's defaults stand in only for an absent or non-string primaries, transfer or
    // matrix; a value the format description carries is never replaced.
    if primaries == nil || transfer == nil || matrix == nil {
        let size = presentationSize(formatDescription)
        let codecType = PAL.softLink_CoreMedia_CMFormatDescriptionGetMediaSubType(formatDescription)
        let defaults = defaultColorAttributes(codecType: codecType, width: sizeHint(size.width), height: sizeHint(size.height))
        if primaries == nil, let defaultPrimaries = defaults.primaries {
            primaries = defaultPrimaries
        }
        if transfer == nil, let defaultTransfer = defaults.transfer {
            transfer = defaultTransfer
        }
        if matrix == nil, let defaultMatrix = defaults.matrix {
            matrix = defaultMatrix
        }
    }

    if let primaries {
        if cfEqual(primaries, constants.colorPrimaries_ITU_R_709_2) {
            colorSpace.primaries = .Bt709
        } else if cfEqual(primaries, constants.colorPrimaries_EBU_3213) {
            colorSpace.primaries = .JedecP22Phosphors
        } else if cfEqual(primaries, constants.colorPrimaries_P22) {
            colorSpace.primaries = .JedecP22Phosphors
        } else if cfEqual(primaries, constants.colorPrimaries_SMPTE_C) {
            colorSpace.primaries = .Smpte170m
        } else if cfEqual(primaries, constants.colorPrimaries_DCI_P3) {
            colorSpace.primaries = .SmpteRp431
        } else if cfEqual(primaries, constants.colorPrimaries_P3_D65) {
            colorSpace.primaries = .SmpteEg432
        } else if cfEqual(primaries, constants.colorPrimaries_ITU_R_2020) {
            colorSpace.primaries = .Bt2020
        }
    }

    if let transfer {
        if cfEqual(transfer, constants.transferFunction_ITU_R_709_2) {
            colorSpace.transfer = .Bt709
        } else if cfEqual(transfer, constants.transferFunction_SMPTE_240M_1995) {
            colorSpace.transfer = .Smpte240m
        } else if cfEqual(transfer, constants.transferFunction_UseGamma) {
            // Without a numeric gamma level the transfer stays unset. CFNumberGetValue's result
            // is ignored: a lossy conversion still yields its best-effort value. NaN is not
            // below 2.5, so it takes the 2.8 curve.
            if let gammaLevel = dynamicCFNumber(formatDescriptionExtension(formatDescription, constants.gammaLevelKey)) {
                let gamma = cfNumberValue(gammaLevel, as: Swift.Double.self).value
                if gamma < 2.5 {
                    colorSpace.transfer = .Gamma22curve
                } else {
                    colorSpace.transfer = .Gamma28curve
                }
            }
        } else if cfEqual(transfer, constants.transferFunction_SMPTE_ST_2084_PQ) {
            colorSpace.transfer = .SmpteSt2084
        } else if cfEqual(transfer, constants.transferFunction_ITU_R_2020) {
            colorSpace.transfer = .Bt2020_10bit
        } else if cfEqual(transfer, constants.transferFunction_SMPTE_ST_428_1) {
            colorSpace.transfer = .SmpteSt4281
        } else if cfEqual(transfer, constants.transferFunction_ITU_R_2100_HLG) {
            colorSpace.transfer = .AribStdB67Hlg
        } else if cfEqual(transfer, constants.transferFunction_sRGB) {
            colorSpace.transfer = .Iec6196621
        } else if cfEqual(transfer, constants.transferFunction_Linear) {
            colorSpace.transfer = .Linear
        }
    }

    if let matrix {
        if cfEqual(matrix, constants.yCbCrMatrix_ITU_R_2020) {
            colorSpace.matrix = .Bt2020NonconstantLuminance
        } else if cfEqual(matrix, constants.yCbCrMatrix_ITU_R_601_4) {
            colorSpace.matrix = .Bt470bg
        } else if cfEqual(matrix, constants.yCbCrMatrix_ITU_R_709_2) {
            colorSpace.matrix = .Bt709
        } else if cfEqual(matrix, constants.yCbCrMatrix_SMPTE_240M_1995) {
            colorSpace.matrix = .Smpte240m
        }
    }

    if let fullRange = dynamicCFBoolean(formatDescriptionExtension(formatDescription, constants.fullRangeVideoKey)) {
        colorSpace.fullRange = CFBooleanGetValue(fullRange)
    }

    // Progressive content carries the same location in both fields. There is no default to fall
    // back on: an absent key means the decoder picks its own siting. The bottom field is read
    // only when the top field has no string, not when it has an unrecognised one.
    var chromaLocation = dynamicCFString(formatDescriptionExtension(formatDescription, constants.chromaLocationTopFieldKey))
    if chromaLocation == nil {
        chromaLocation = dynamicCFString(formatDescriptionExtension(formatDescription, constants.chromaLocationBottomFieldKey))
    }

    if let chromaLocation {
        if cfEqual(chromaLocation, constants.chromaLocation_Left) {
            colorSpace.chromaLocation = .Left
        } else if cfEqual(chromaLocation, constants.chromaLocation_Center) {
            colorSpace.chromaLocation = .Center
        } else if cfEqual(chromaLocation, constants.chromaLocation_TopLeft) {
            colorSpace.chromaLocation = .TopLeft
        } else if cfEqual(chromaLocation, constants.chromaLocation_Top) {
            colorSpace.chromaLocation = .Top
        } else if cfEqual(chromaLocation, constants.chromaLocation_BottomLeft) {
            colorSpace.chromaLocation = .BottomLeft
        } else if cfEqual(chromaLocation, constants.chromaLocation_Bottom) {
            colorSpace.chromaLocation = .Bottom
        } else if cfEqual(chromaLocation, constants.chromaLocation_DV420) {
            colorSpace.chromaLocation = .Dv420
        }
    }

    return colorSpace
}

private func fieldCount(_ formatDescription: CMFormatDescription) -> PlatformVideoFieldCount? {
    let constants = FieldConstants.load()
    guard let fieldCount = dynamicCFNumber(formatDescriptionExtension(formatDescription, constants.fieldCountKey)) else {
        return nil
    }
    let (converted, value) = cfNumberValue(fieldCount, as: Swift.Int32.self)
    guard converted else {
        return nil
    }
    switch value {
    case 1:
        return .Progressive
    case 2:
        return .Interlaced
    default:
        return nil
    }
}

private func fieldDetail(_ formatDescription: CMFormatDescription) -> PlatformVideoFieldDetail? {
    let constants = FieldConstants.load()
    guard let fieldDetail = dynamicCFString(formatDescriptionExtension(formatDescription, constants.fieldDetailKey)) else {
        return nil
    }
    if cfEqual(fieldDetail, constants.fieldDetailTemporalTopFirst) {
        return .TemporalTopFirst
    }
    if cfEqual(fieldDetail, constants.fieldDetailTemporalBottomFirst) {
        return .TemporalBottomFirst
    }
    if cfEqual(fieldDetail, constants.fieldDetailSpatialFirstLineEarly) {
        return .SpatialFirstLineEarly
    }
    if cfEqual(fieldDetail, constants.fieldDetailSpatialFirstLineLate) {
        return .SpatialFirstLineLate
    }
    return nil
}

/// The extension key under which protected content records its original format: CoreMedia's
/// constant where this CoreMedia exports it, else the string that constant holds.
private func protectedContentOriginalFormatKey() -> CFString? {
    guard PAL.canLoad_CoreMedia_kCMFormatDescriptionExtension_ProtectedContentOriginalFormat() else {
        return "CommonEncryptionOriginalFormat" as CFString
    }
    // SAFETY: canLoad_ has just confirmed the symbol exists, and the getter returns a +0
    // reference to an immutable CFString constant exported by CoreMedia, which stays loaded for
    // the life of the process, so takeUnretainedValue() yields a live object.
    // Not provable today because SOFT_LINK_CONSTANT_MAY_FAIL_FOR_HEADER declares the getter
    // outside any CF-audited region and without CF_RETURNS_NOT_RETAINED, so Swift imports its
    // CFStringRef result as Unmanaged.
    return unsafe PAL.get_CoreMedia_kCMFormatDescriptionExtension_ProtectedContentOriginalFormatSingleton()?.takeUnretainedValue()
}

// MARK: - The C boundary

/// `WebCore::typeFromFormatDescription`: the TrackInfoTrackType raw value for the media type of
/// `formatDescription`. A nil description has media type 0, which is Unknown.
@_cdecl("WebCoreFormatDescriptionTrackType")
internal func webCoreFormatDescriptionTrackType(_ formatDescription: CMFormatDescription?) -> Swift.UInt8 {
    let trackType: TrackInfoTrackType
    switch PAL.softLink_CoreMedia_CMFormatDescriptionGetMediaType(formatDescription) {
    case CMMediaType(kCMMediaType_Video):
        trackType = .Video
    case CMMediaType(kCMMediaType_Audio):
        trackType = .Audio
    case CMMediaType(kCMMediaType_Text), CMMediaType(kCMMediaType_ClosedCaption), CMMediaType(kCMMediaType_Subtitle):
        trackType = .Text
    default:
        trackType = .Unknown
    }
    return trackType.rawValue
}

/// `WebCore::presentationSizeFromFormatDescription`: CGSize.zero for nil.
@_cdecl("WebCoreFormatDescriptionPresentationSize")
internal func webCoreFormatDescriptionPresentationSize(_ formatDescription: CMFormatDescription?) -> CoreGraphics.CGSize {
    guard let formatDescription else {
        return .zero
    }
    return PAL.softLink_CoreMedia_CMVideoFormatDescriptionGetPresentationDimensions(formatDescription, true, true)
}

/// `WebCore::colorSpaceFromFormatDescription`: 0 for nil, else the packed colour space.
@_cdecl("WebCoreFormatDescriptionColorSpace")
internal func webCoreFormatDescriptionColorSpace(_ formatDescription: CMFormatDescription?) -> Swift.UInt64 {
    guard let formatDescription else {
        return 0
    }
    return colorSpace(formatDescription).packed()
}

/// `WebCore::fieldCountFromFormatDescription`: 0 for std::nullopt, else the
/// PlatformVideoFieldCount raw value.
@_cdecl("WebCoreFormatDescriptionFieldCount")
internal func webCoreFormatDescriptionFieldCount(_ formatDescription: CMFormatDescription?) -> Swift.UInt8 {
    guard let formatDescription, let fieldCount = fieldCount(formatDescription) else {
        return 0
    }
    return fieldCount.rawValue
}

/// `WebCore::fieldDetailFromFormatDescription`: 0xFF for std::nullopt, else the
/// PlatformVideoFieldDetail raw value.
@_cdecl("WebCoreFormatDescriptionFieldDetail")
internal func webCoreFormatDescriptionFieldDetail(_ formatDescription: CMFormatDescription?) -> Swift.UInt8 {
    guard let formatDescription, let fieldDetail = fieldDetail(formatDescription) else {
        return 0xFF
    }
    return fieldDetail.rawValue
}

/// `WebCore::formatDescriptionIsProtected`: whether `formatDescription` records a numeric
/// original format. This assumes only-and-all content which is protected carries that key.
@_cdecl("WebCoreFormatDescriptionIsProtected")
internal func webCoreFormatDescriptionIsProtected(_ formatDescription: CMFormatDescription?) -> Swift.Bool {
    guard let formatDescription else {
        return false
    }
    return dynamicCFNumber(formatDescriptionExtension(formatDescription, protectedContentOriginalFormatKey())) != nil
}

#endif // ENABLE_FORMAT_DESCRIPTION_UTILITIES_SWIFT
