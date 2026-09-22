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
// THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
// EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
// PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
// CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
// EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
// PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
// PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
// OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

// Every case label below was emitted mechanically from ShareableCVPixelFormat.cpp
// by ~/src/webkit-swift-ports/cvpixfmt/gen.py, and is checked against the C++ by
// compiling and RUNNING both sides over every format (diff.py, same directory).
// Do not hand-edit a case label: edit the C++ and regenerate.

#if ENABLE_SHAREABLE_CV_PIXEL_FORMAT_SWIFT

internal import CoreVideo

/// Mirror of `WebCore::ShareableCVPixelFormat` in ShareableCVPixelFormat.h.
///
/// The raw values are the C++ enumerators' implicit values, spelled explicitly
/// here because the two declarations are separate texts that must agree: the
/// value crosses the `@_cdecl` boundary below as a `uint8_t`.
enum ShareableCVPixelFormat: UInt8 {
    case Type_1Monochrome = 0
    case Type_2Indexed = 1
    case Type_4Indexed = 2
    case Type_8Indexed = 3
    case Type_1IndexedGray_WhiteIsZero = 4
    case Type_2IndexedGray_WhiteIsZero = 5
    case Type_4IndexedGray_WhiteIsZero = 6
    case Type_8IndexedGray_WhiteIsZero = 7
    case Type_16BE555 = 8
    case Type_16LE555 = 9
    case Type_16LE5551 = 10
    case Type_16BE565 = 11
    case Type_16LE565 = 12
    case Type_24RGB = 13
    case Type_24BGR = 14
    case Type_32ARGB = 15
    case Type_32BGRA = 16
    case Type_32ABGR = 17
    case Type_32RGBA = 18
    case Type_64ARGB = 19
    case Type_64RGBALE = 20
    case Type_48RGB = 21
    case Type_32AlphaGray = 22
    case Type_16Gray = 23
    case Type_30RGB = 24
    case Type_30RGB_r210 = 25
    case Type_422YpCbCr8 = 26
    case Type_4444YpCbCrA8 = 27
    case Type_4444YpCbCrA8R = 28
    case Type_4444AYpCbCr8 = 29
    case Type_4444AYpCbCr16 = 30
    case Type_4444AYpCbCrFloat = 31
    case Type_444YpCbCr8 = 32
    case Type_422YpCbCr16 = 33
    case Type_422YpCbCr10 = 34
    case Type_444YpCbCr10 = 35
    case Type_420YpCbCr8Planar = 36
    case Type_420YpCbCr8PlanarFullRange = 37
    case Type_422YpCbCr_4A_8BiPlanar = 38
    case Type_420YpCbCr8BiPlanarVideoRange = 39
    case Type_420YpCbCr8BiPlanarFullRange = 40
    case Type_422YpCbCr8BiPlanarVideoRange = 41
    case Type_422YpCbCr8BiPlanarFullRange = 42
    case Type_444YpCbCr8BiPlanarVideoRange = 43
    case Type_444YpCbCr8BiPlanarFullRange = 44
    case Type_422YpCbCr8_yuvs = 45
    case Type_422YpCbCr8FullRange = 46
    case Type_OneComponent8 = 47
    case Type_TwoComponent8 = 48
    case Type_30RGBLEPackedWideGamut = 49
    case Type_ARGB2101010LEPacked = 50
    case Type_40ARGBLEWideGamut = 51
    case Type_40ARGBLEWideGamutPremultiplied = 52
    case Type_OneComponent10 = 53
    case Type_OneComponent12 = 54
    case Type_OneComponent16 = 55
    case Type_TwoComponent16 = 56
    case Type_OneComponent16Half = 57
    case Type_OneComponent32Float = 58
    case Type_TwoComponent16Half = 59
    case Type_TwoComponent32Float = 60
    case Type_64RGBAHalf = 61
    case Type_128RGBAFloat = 62
    case Type_14Bayer_GRBG = 63
    case Type_14Bayer_RGGB = 64
    case Type_14Bayer_BGGR = 65
    case Type_14Bayer_GBRG = 66
    case Type_DisparityFloat16 = 67
    case Type_DisparityFloat32 = 68
    case Type_DepthFloat16 = 69
    case Type_DepthFloat32 = 70
    case Type_420YpCbCr10BiPlanarVideoRange = 71
    case Type_422YpCbCr10BiPlanarVideoRange = 72
    case Type_444YpCbCr10BiPlanarVideoRange = 73
    case Type_420YpCbCr10BiPlanarFullRange = 74
    case Type_422YpCbCr10BiPlanarFullRange = 75
    case Type_444YpCbCr10BiPlanarFullRange = 76
    case Type_420YpCbCr8VideoRange_8A_TriPlanar = 77
    case Type_16VersatileBayer = 78
    case Type_96VersatileBayerPacked12 = 79
    case Type_64RGBA_DownscaledProResRAW = 80
    case Type_422YpCbCr16BiPlanarVideoRange = 81
    case Type_444YpCbCr16BiPlanarVideoRange = 82
    case Type_444YpCbCr16VideoRange_16A_TriPlanar = 83
    case Type_30RGBLE_8A_BiPlanar = 84
    case Type_Lossless_32BGRA = 85
    case Type_Lossless_64RGBAHalf = 86
    case Type_Lossless_420YpCbCr8BiPlanarVideoRange = 87
    case Type_Lossless_420YpCbCr8BiPlanarFullRange = 88
    case Type_Lossless_420YpCbCr10PackedBiPlanarVideoRange = 89
    case Type_Lossless_422YpCbCr10PackedBiPlanarVideoRange = 90
    case Type_Lossless_420YpCbCr10PackedBiPlanarFullRange = 91
    case Type_Lossless_30RGBLE_8A_BiPlanar = 92
    case Type_Lossless_30RGBLEPackedWideGamut = 93
    case Type_Lossy_32BGRA = 94
    case Type_Lossy_420YpCbCr8BiPlanarVideoRange = 95
    case Type_Lossy_420YpCbCr8BiPlanarFullRange = 96
    case Type_Lossy_420YpCbCr10PackedBiPlanarVideoRange = 97
    case Type_Lossy_422YpCbCr10PackedBiPlanarVideoRange = 98
}

/// The `ShareableCVPixelFormat` naming the CoreVideo pixel format `pixelFormat`.
///
/// Traps on a format the enumeration does not name, as the C++ arm's
/// `RELEASE_ASSERT_NOT_REACHED()` does.
func fromCVPixelFormat(_ pixelFormat: OSType) -> ShareableCVPixelFormat {
    switch pixelFormat {
    case kCVPixelFormatType_1Monochrome:
        return .Type_1Monochrome
    case kCVPixelFormatType_2Indexed:
        return .Type_2Indexed
    case kCVPixelFormatType_4Indexed:
        return .Type_4Indexed
    case kCVPixelFormatType_8Indexed:
        return .Type_8Indexed
    case kCVPixelFormatType_1IndexedGray_WhiteIsZero:
        return .Type_1IndexedGray_WhiteIsZero
    case kCVPixelFormatType_2IndexedGray_WhiteIsZero:
        return .Type_2IndexedGray_WhiteIsZero
    case kCVPixelFormatType_4IndexedGray_WhiteIsZero:
        return .Type_4IndexedGray_WhiteIsZero
    case kCVPixelFormatType_8IndexedGray_WhiteIsZero:
        return .Type_8IndexedGray_WhiteIsZero
    case kCVPixelFormatType_16BE555:
        return .Type_16BE555
    case kCVPixelFormatType_16LE555:
        return .Type_16LE555
    case kCVPixelFormatType_16LE5551:
        return .Type_16LE5551
    case kCVPixelFormatType_16BE565:
        return .Type_16BE565
    case kCVPixelFormatType_16LE565:
        return .Type_16LE565
    case kCVPixelFormatType_24RGB:
        return .Type_24RGB
    case kCVPixelFormatType_24BGR:
        return .Type_24BGR
    case kCVPixelFormatType_32ARGB:
        return .Type_32ARGB
    case kCVPixelFormatType_32BGRA:
        return .Type_32BGRA
    case kCVPixelFormatType_32ABGR:
        return .Type_32ABGR
    case kCVPixelFormatType_32RGBA:
        return .Type_32RGBA
    case kCVPixelFormatType_64ARGB:
        return .Type_64ARGB
    case kCVPixelFormatType_64RGBALE:
        return .Type_64RGBALE
    case kCVPixelFormatType_48RGB:
        return .Type_48RGB
    case kCVPixelFormatType_32AlphaGray:
        return .Type_32AlphaGray
    case kCVPixelFormatType_16Gray:
        return .Type_16Gray
    case kCVPixelFormatType_30RGB:
        return .Type_30RGB
    case kCVPixelFormatType_30RGB_r210:
        return .Type_30RGB_r210
    case kCVPixelFormatType_422YpCbCr8:
        return .Type_422YpCbCr8
    case kCVPixelFormatType_4444YpCbCrA8:
        return .Type_4444YpCbCrA8
    case kCVPixelFormatType_4444YpCbCrA8R:
        return .Type_4444YpCbCrA8R
    case kCVPixelFormatType_4444AYpCbCr8:
        return .Type_4444AYpCbCr8
    case kCVPixelFormatType_4444AYpCbCr16:
        return .Type_4444AYpCbCr16
    case kCVPixelFormatType_4444AYpCbCrFloat:
        return .Type_4444AYpCbCrFloat
    case kCVPixelFormatType_444YpCbCr8:
        return .Type_444YpCbCr8
    case kCVPixelFormatType_422YpCbCr16:
        return .Type_422YpCbCr16
    case kCVPixelFormatType_422YpCbCr10:
        return .Type_422YpCbCr10
    case kCVPixelFormatType_444YpCbCr10:
        return .Type_444YpCbCr10
    case kCVPixelFormatType_420YpCbCr8Planar:
        return .Type_420YpCbCr8Planar
    case kCVPixelFormatType_420YpCbCr8PlanarFullRange:
        return .Type_420YpCbCr8PlanarFullRange
    case kCVPixelFormatType_422YpCbCr_4A_8BiPlanar:
        return .Type_422YpCbCr_4A_8BiPlanar
    case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
        return .Type_420YpCbCr8BiPlanarVideoRange
    case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
        return .Type_420YpCbCr8BiPlanarFullRange
    case kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange:
        return .Type_422YpCbCr8BiPlanarVideoRange
    case kCVPixelFormatType_422YpCbCr8BiPlanarFullRange:
        return .Type_422YpCbCr8BiPlanarFullRange
    case kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange:
        return .Type_444YpCbCr8BiPlanarVideoRange
    case kCVPixelFormatType_444YpCbCr8BiPlanarFullRange:
        return .Type_444YpCbCr8BiPlanarFullRange
    case kCVPixelFormatType_422YpCbCr8_yuvs:
        return .Type_422YpCbCr8_yuvs
    case kCVPixelFormatType_422YpCbCr8FullRange:
        return .Type_422YpCbCr8FullRange
    case kCVPixelFormatType_OneComponent8:
        return .Type_OneComponent8
    case kCVPixelFormatType_TwoComponent8:
        return .Type_TwoComponent8
    case kCVPixelFormatType_30RGBLEPackedWideGamut:
        return .Type_30RGBLEPackedWideGamut
    case kCVPixelFormatType_ARGB2101010LEPacked:
        return .Type_ARGB2101010LEPacked
    case kCVPixelFormatType_40ARGBLEWideGamut:
        return .Type_40ARGBLEWideGamut
    case kCVPixelFormatType_40ARGBLEWideGamutPremultiplied:
        return .Type_40ARGBLEWideGamutPremultiplied
    case kCVPixelFormatType_OneComponent10:
        return .Type_OneComponent10
    case kCVPixelFormatType_OneComponent12:
        return .Type_OneComponent12
    case kCVPixelFormatType_OneComponent16:
        return .Type_OneComponent16
    case kCVPixelFormatType_TwoComponent16:
        return .Type_TwoComponent16
    case kCVPixelFormatType_OneComponent16Half:
        return .Type_OneComponent16Half
    case kCVPixelFormatType_OneComponent32Float:
        return .Type_OneComponent32Float
    case kCVPixelFormatType_TwoComponent16Half:
        return .Type_TwoComponent16Half
    case kCVPixelFormatType_TwoComponent32Float:
        return .Type_TwoComponent32Float
    case kCVPixelFormatType_64RGBAHalf:
        return .Type_64RGBAHalf
    case kCVPixelFormatType_128RGBAFloat:
        return .Type_128RGBAFloat
    case kCVPixelFormatType_14Bayer_GRBG:
        return .Type_14Bayer_GRBG
    case kCVPixelFormatType_14Bayer_RGGB:
        return .Type_14Bayer_RGGB
    case kCVPixelFormatType_14Bayer_BGGR:
        return .Type_14Bayer_BGGR
    case kCVPixelFormatType_14Bayer_GBRG:
        return .Type_14Bayer_GBRG
    case kCVPixelFormatType_DisparityFloat16:
        return .Type_DisparityFloat16
    case kCVPixelFormatType_DisparityFloat32:
        return .Type_DisparityFloat32
    case kCVPixelFormatType_DepthFloat16:
        return .Type_DepthFloat16
    case kCVPixelFormatType_DepthFloat32:
        return .Type_DepthFloat32
    case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
        return .Type_420YpCbCr10BiPlanarVideoRange
    case kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange:
        return .Type_422YpCbCr10BiPlanarVideoRange
    case kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange:
        return .Type_444YpCbCr10BiPlanarVideoRange
    case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
        return .Type_420YpCbCr10BiPlanarFullRange
    case kCVPixelFormatType_422YpCbCr10BiPlanarFullRange:
        return .Type_422YpCbCr10BiPlanarFullRange
    case kCVPixelFormatType_444YpCbCr10BiPlanarFullRange:
        return .Type_444YpCbCr10BiPlanarFullRange
    case kCVPixelFormatType_420YpCbCr8VideoRange_8A_TriPlanar:
        return .Type_420YpCbCr8VideoRange_8A_TriPlanar
    case kCVPixelFormatType_16VersatileBayer:
        return .Type_16VersatileBayer
    case kCVPixelFormatType_96VersatileBayerPacked12:
        return .Type_96VersatileBayerPacked12
    case kCVPixelFormatType_64RGBA_DownscaledProResRAW:
        return .Type_64RGBA_DownscaledProResRAW
    case kCVPixelFormatType_422YpCbCr16BiPlanarVideoRange:
        return .Type_422YpCbCr16BiPlanarVideoRange
    case kCVPixelFormatType_444YpCbCr16BiPlanarVideoRange:
        return .Type_444YpCbCr16BiPlanarVideoRange
    case kCVPixelFormatType_444YpCbCr16VideoRange_16A_TriPlanar:
        return .Type_444YpCbCr16VideoRange_16A_TriPlanar
    case kCVPixelFormatType_30RGBLE_8A_BiPlanar:
        return .Type_30RGBLE_8A_BiPlanar
    case kCVPixelFormatType_Lossless_32BGRA:
        return .Type_Lossless_32BGRA
    case kCVPixelFormatType_Lossless_64RGBAHalf:
        return .Type_Lossless_64RGBAHalf
    case kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarVideoRange:
        return .Type_Lossless_420YpCbCr8BiPlanarVideoRange
    case kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarFullRange:
        return .Type_Lossless_420YpCbCr8BiPlanarFullRange
    case kCVPixelFormatType_Lossless_420YpCbCr10PackedBiPlanarVideoRange:
        return .Type_Lossless_420YpCbCr10PackedBiPlanarVideoRange
    case kCVPixelFormatType_Lossless_422YpCbCr10PackedBiPlanarVideoRange:
        return .Type_Lossless_422YpCbCr10PackedBiPlanarVideoRange
    case kCVPixelFormatType_Lossless_420YpCbCr10PackedBiPlanarFullRange:
        return .Type_Lossless_420YpCbCr10PackedBiPlanarFullRange
    case kCVPixelFormatType_Lossless_30RGBLE_8A_BiPlanar:
        return .Type_Lossless_30RGBLE_8A_BiPlanar
    case kCVPixelFormatType_Lossless_30RGBLEPackedWideGamut:
        return .Type_Lossless_30RGBLEPackedWideGamut
    case kCVPixelFormatType_Lossy_32BGRA:
        return .Type_Lossy_32BGRA
    case kCVPixelFormatType_Lossy_420YpCbCr8BiPlanarVideoRange:
        return .Type_Lossy_420YpCbCr8BiPlanarVideoRange
    case kCVPixelFormatType_Lossy_420YpCbCr8BiPlanarFullRange:
        return .Type_Lossy_420YpCbCr8BiPlanarFullRange
    case kCVPixelFormatType_Lossy_420YpCbCr10PackedBiPlanarVideoRange:
        return .Type_Lossy_420YpCbCr10PackedBiPlanarVideoRange
    case kCVPixelFormatType_Lossy_422YpCbCr10PackedBiPlanarVideoRange:
        return .Type_Lossy_422YpCbCr10PackedBiPlanarVideoRange
    default:
        fatalError("unhandled CoreVideo pixel format")
    }
}

/// The CoreVideo pixel format `pixelFormat` names.
func toCVPixelFormat(_ pixelFormat: ShareableCVPixelFormat) -> OSType {
    switch pixelFormat {
    case .Type_1Monochrome:
        return kCVPixelFormatType_1Monochrome
    case .Type_2Indexed:
        return kCVPixelFormatType_2Indexed
    case .Type_4Indexed:
        return kCVPixelFormatType_4Indexed
    case .Type_8Indexed:
        return kCVPixelFormatType_8Indexed
    case .Type_1IndexedGray_WhiteIsZero:
        return kCVPixelFormatType_1IndexedGray_WhiteIsZero
    case .Type_2IndexedGray_WhiteIsZero:
        return kCVPixelFormatType_2IndexedGray_WhiteIsZero
    case .Type_4IndexedGray_WhiteIsZero:
        return kCVPixelFormatType_4IndexedGray_WhiteIsZero
    case .Type_8IndexedGray_WhiteIsZero:
        return kCVPixelFormatType_8IndexedGray_WhiteIsZero
    case .Type_16BE555:
        return kCVPixelFormatType_16BE555
    case .Type_16LE555:
        return kCVPixelFormatType_16LE555
    case .Type_16LE5551:
        return kCVPixelFormatType_16LE5551
    case .Type_16BE565:
        return kCVPixelFormatType_16BE565
    case .Type_16LE565:
        return kCVPixelFormatType_16LE565
    case .Type_24RGB:
        return kCVPixelFormatType_24RGB
    case .Type_24BGR:
        return kCVPixelFormatType_24BGR
    case .Type_32ARGB:
        return kCVPixelFormatType_32ARGB
    case .Type_32BGRA:
        return kCVPixelFormatType_32BGRA
    case .Type_32ABGR:
        return kCVPixelFormatType_32ABGR
    case .Type_32RGBA:
        return kCVPixelFormatType_32RGBA
    case .Type_64ARGB:
        return kCVPixelFormatType_64ARGB
    case .Type_64RGBALE:
        return kCVPixelFormatType_64RGBALE
    case .Type_48RGB:
        return kCVPixelFormatType_48RGB
    case .Type_32AlphaGray:
        return kCVPixelFormatType_32AlphaGray
    case .Type_16Gray:
        return kCVPixelFormatType_16Gray
    case .Type_30RGB:
        return kCVPixelFormatType_30RGB
    case .Type_30RGB_r210:
        return kCVPixelFormatType_30RGB_r210
    case .Type_422YpCbCr8:
        return kCVPixelFormatType_422YpCbCr8
    case .Type_4444YpCbCrA8:
        return kCVPixelFormatType_4444YpCbCrA8
    case .Type_4444YpCbCrA8R:
        return kCVPixelFormatType_4444YpCbCrA8R
    case .Type_4444AYpCbCr8:
        return kCVPixelFormatType_4444AYpCbCr8
    case .Type_4444AYpCbCr16:
        return kCVPixelFormatType_4444AYpCbCr16
    case .Type_4444AYpCbCrFloat:
        return kCVPixelFormatType_4444AYpCbCrFloat
    case .Type_444YpCbCr8:
        return kCVPixelFormatType_444YpCbCr8
    case .Type_422YpCbCr16:
        return kCVPixelFormatType_422YpCbCr16
    case .Type_422YpCbCr10:
        return kCVPixelFormatType_422YpCbCr10
    case .Type_444YpCbCr10:
        return kCVPixelFormatType_444YpCbCr10
    case .Type_420YpCbCr8Planar:
        return kCVPixelFormatType_420YpCbCr8Planar
    case .Type_420YpCbCr8PlanarFullRange:
        return kCVPixelFormatType_420YpCbCr8PlanarFullRange
    case .Type_422YpCbCr_4A_8BiPlanar:
        return kCVPixelFormatType_422YpCbCr_4A_8BiPlanar
    case .Type_420YpCbCr8BiPlanarVideoRange:
        return kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    case .Type_420YpCbCr8BiPlanarFullRange:
        return kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    case .Type_422YpCbCr8BiPlanarVideoRange:
        return kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange
    case .Type_422YpCbCr8BiPlanarFullRange:
        return kCVPixelFormatType_422YpCbCr8BiPlanarFullRange
    case .Type_444YpCbCr8BiPlanarVideoRange:
        return kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange
    case .Type_444YpCbCr8BiPlanarFullRange:
        return kCVPixelFormatType_444YpCbCr8BiPlanarFullRange
    case .Type_422YpCbCr8_yuvs:
        return kCVPixelFormatType_422YpCbCr8_yuvs
    case .Type_422YpCbCr8FullRange:
        return kCVPixelFormatType_422YpCbCr8FullRange
    case .Type_OneComponent8:
        return kCVPixelFormatType_OneComponent8
    case .Type_TwoComponent8:
        return kCVPixelFormatType_TwoComponent8
    case .Type_30RGBLEPackedWideGamut:
        return kCVPixelFormatType_30RGBLEPackedWideGamut
    case .Type_ARGB2101010LEPacked:
        return kCVPixelFormatType_ARGB2101010LEPacked
    case .Type_40ARGBLEWideGamut:
        return kCVPixelFormatType_40ARGBLEWideGamut
    case .Type_40ARGBLEWideGamutPremultiplied:
        return kCVPixelFormatType_40ARGBLEWideGamutPremultiplied
    case .Type_OneComponent10:
        return kCVPixelFormatType_OneComponent10
    case .Type_OneComponent12:
        return kCVPixelFormatType_OneComponent12
    case .Type_OneComponent16:
        return kCVPixelFormatType_OneComponent16
    case .Type_TwoComponent16:
        return kCVPixelFormatType_TwoComponent16
    case .Type_OneComponent16Half:
        return kCVPixelFormatType_OneComponent16Half
    case .Type_OneComponent32Float:
        return kCVPixelFormatType_OneComponent32Float
    case .Type_TwoComponent16Half:
        return kCVPixelFormatType_TwoComponent16Half
    case .Type_TwoComponent32Float:
        return kCVPixelFormatType_TwoComponent32Float
    case .Type_64RGBAHalf:
        return kCVPixelFormatType_64RGBAHalf
    case .Type_128RGBAFloat:
        return kCVPixelFormatType_128RGBAFloat
    case .Type_14Bayer_GRBG:
        return kCVPixelFormatType_14Bayer_GRBG
    case .Type_14Bayer_RGGB:
        return kCVPixelFormatType_14Bayer_RGGB
    case .Type_14Bayer_BGGR:
        return kCVPixelFormatType_14Bayer_BGGR
    case .Type_14Bayer_GBRG:
        return kCVPixelFormatType_14Bayer_GBRG
    case .Type_DisparityFloat16:
        return kCVPixelFormatType_DisparityFloat16
    case .Type_DisparityFloat32:
        return kCVPixelFormatType_DisparityFloat32
    case .Type_DepthFloat16:
        return kCVPixelFormatType_DepthFloat16
    case .Type_DepthFloat32:
        return kCVPixelFormatType_DepthFloat32
    case .Type_420YpCbCr10BiPlanarVideoRange:
        return kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
    case .Type_422YpCbCr10BiPlanarVideoRange:
        return kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
    case .Type_444YpCbCr10BiPlanarVideoRange:
        return kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange
    case .Type_420YpCbCr10BiPlanarFullRange:
        return kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
    case .Type_422YpCbCr10BiPlanarFullRange:
        return kCVPixelFormatType_422YpCbCr10BiPlanarFullRange
    case .Type_444YpCbCr10BiPlanarFullRange:
        return kCVPixelFormatType_444YpCbCr10BiPlanarFullRange
    case .Type_420YpCbCr8VideoRange_8A_TriPlanar:
        return kCVPixelFormatType_420YpCbCr8VideoRange_8A_TriPlanar
    case .Type_16VersatileBayer:
        return kCVPixelFormatType_16VersatileBayer
    case .Type_96VersatileBayerPacked12:
        return kCVPixelFormatType_96VersatileBayerPacked12
    case .Type_64RGBA_DownscaledProResRAW:
        return kCVPixelFormatType_64RGBA_DownscaledProResRAW
    case .Type_422YpCbCr16BiPlanarVideoRange:
        return kCVPixelFormatType_422YpCbCr16BiPlanarVideoRange
    case .Type_444YpCbCr16BiPlanarVideoRange:
        return kCVPixelFormatType_444YpCbCr16BiPlanarVideoRange
    case .Type_444YpCbCr16VideoRange_16A_TriPlanar:
        return kCVPixelFormatType_444YpCbCr16VideoRange_16A_TriPlanar
    case .Type_30RGBLE_8A_BiPlanar:
        return kCVPixelFormatType_30RGBLE_8A_BiPlanar
    case .Type_Lossless_32BGRA:
        return kCVPixelFormatType_Lossless_32BGRA
    case .Type_Lossless_64RGBAHalf:
        return kCVPixelFormatType_Lossless_64RGBAHalf
    case .Type_Lossless_420YpCbCr8BiPlanarVideoRange:
        return kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarVideoRange
    case .Type_Lossless_420YpCbCr8BiPlanarFullRange:
        return kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarFullRange
    case .Type_Lossless_420YpCbCr10PackedBiPlanarVideoRange:
        return kCVPixelFormatType_Lossless_420YpCbCr10PackedBiPlanarVideoRange
    case .Type_Lossless_422YpCbCr10PackedBiPlanarVideoRange:
        return kCVPixelFormatType_Lossless_422YpCbCr10PackedBiPlanarVideoRange
    case .Type_Lossless_420YpCbCr10PackedBiPlanarFullRange:
        return kCVPixelFormatType_Lossless_420YpCbCr10PackedBiPlanarFullRange
    case .Type_Lossless_30RGBLE_8A_BiPlanar:
        return kCVPixelFormatType_Lossless_30RGBLE_8A_BiPlanar
    case .Type_Lossless_30RGBLEPackedWideGamut:
        return kCVPixelFormatType_Lossless_30RGBLEPackedWideGamut
    case .Type_Lossy_32BGRA:
        return kCVPixelFormatType_Lossy_32BGRA
    case .Type_Lossy_420YpCbCr8BiPlanarVideoRange:
        return kCVPixelFormatType_Lossy_420YpCbCr8BiPlanarVideoRange
    case .Type_Lossy_420YpCbCr8BiPlanarFullRange:
        return kCVPixelFormatType_Lossy_420YpCbCr8BiPlanarFullRange
    case .Type_Lossy_420YpCbCr10PackedBiPlanarVideoRange:
        return kCVPixelFormatType_Lossy_420YpCbCr10PackedBiPlanarVideoRange
    case .Type_Lossy_422YpCbCr10PackedBiPlanarVideoRange:
        return kCVPixelFormatType_Lossy_422YpCbCr10PackedBiPlanarVideoRange
    }
}

// MARK: - C++ entry points
//
// WebCore sets SWIFT_INSTALL_OBJC_HEADER = NO and declares no
// SWIFT_OBJC_INTERFACE_HEADER_NAME, so unlike PAL there is no generated
// Swift->C++ interface header in this target and C++ cannot name a Swift
// declaration.  These two `@_cdecl` symbols are the whole boundary; the C++
// arm declares them `extern "C"` under the same gate and forwards.  The
// enumeration crosses as its `uint8_t` raw value, which is also the
// underlying type the C++ `enum class` was given.

@_cdecl("WebCoreShareableCVPixelFormatFromCVPixelFormat")
func webCoreShareableCVPixelFormatFromCVPixelFormat(_ pixelFormat: OSType) -> UInt8 {
    fromCVPixelFormat(pixelFormat).rawValue
}

@_cdecl("WebCoreShareableCVPixelFormatToCVPixelFormat")
func webCoreShareableCVPixelFormatToCVPixelFormat(_ pixelFormat: UInt8) -> OSType {
    guard let format = ShareableCVPixelFormat(rawValue: pixelFormat) else {
        fatalError("unhandled ShareableCVPixelFormat raw value")
    }
    return toCVPixelFormat(format)
}

#endif // ENABLE_SHAREABLE_CV_PIXEL_FORMAT_SWIFT
