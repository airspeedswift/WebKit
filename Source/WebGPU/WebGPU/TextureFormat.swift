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

import WebGPU_Private.WebGPU

/// What a `WGPUTextureFormat` is, as tables over the enumeration.
///
/// Every member is a total function of the format and of nothing else: no
/// receiver, no `Device`, no Metal. The properties that do consult the device --
/// whether a format is renderable, supports multisampling, resolve, blending or
/// a storage binding -- stay on `Texture` in C++, where the `Device` they read
/// lives.
///
/// One exposed type rather than one exposure per table, so the boundary
/// `Texture.mm` calls across is a single name. The cost is that these read as
/// `TextureFormat::texelBlockWidth(format)` in C++ where they used to read as
/// `Texture::texelBlockWidth(format)`; the `Texture` spellings are kept, as
/// members that forward.
///
/// A class rather than a struct, and one nothing ever instantiates: `init` is
/// private, so the only way in is the static members. A struct with no stored
/// properties is zero-sized and `@_expose(Cxx)` declines it outright -- "it
/// cannot be exposed to C++ yet" -- and a struct given a stored `format` to make
/// it non-empty exposes its initializer as a static member spelled `init`, so
/// every C++ call site would read `TextureFormat::init(format).getTexelBlockWidth()`.
/// The cost of the shape taken instead is that the generated header presents
/// this as a reference-counted class; no instance is ever made, so no reference
/// is ever counted.
@_expose(Cxx)
final class TextureFormat {
    private init() {}

    /// `format` is not a compressed format. Negative, so that Texture.mm can
    /// recover the C++ arm's `std::nullopt` from a value no family can take.
    private static let compressedFormatNone: Int32 = -1
    /// The three values of `Texture::CompressFormat`, in the order Texture.h
    /// declares them. Texture.mm static_asserts that correspondence.
    private static let compressedFormatASTC: Int32 = 0
    private static let compressedFormatBC: Int32 = 1
    private static let compressedFormatETC: Int32 = 2

    /// Whether `format` is one of the compressed formats.
    static func isCompressedFormat(_ format: WGPUTextureFormat) -> Bool {
        compressedFormatType(format) != compressedFormatNone
    }

    /// Whether `format` has a depth aspect.
    static func containsDepthAspect(_ format: WGPUTextureFormat) -> Bool {
        depthSpecificFormat(format) != WGPUTextureFormat_Undefined
    }

    /// Whether `format` has a stencil aspect.
    static func containsStencilAspect(_ format: WGPUTextureFormat) -> Bool {
        stencilSpecificFormat(format) != WGPUTextureFormat_Undefined
    }

    /// Whether `format` has a depth aspect, a stencil aspect, or both.
    ///
    /// https://gpuweb.github.io/gpuweb/#depth-formats
    static func isDepthOrStencilFormat(_ format: WGPUTextureFormat) -> Bool {
        containsDepthAspect(format) || containsStencilAspect(format)
    }

    /// The width in texels of one texel block of `format`.
    ///
    /// https://gpuweb.github.io/gpuweb/#texel-block-width
    static func texelBlockWidth(_ format: WGPUTextureFormat) -> UInt32 {
        switch format {
        case WGPUTextureFormat_BC1RGBAUnorm,
            WGPUTextureFormat_BC1RGBAUnormSrgb,
            WGPUTextureFormat_BC2RGBAUnorm,
            WGPUTextureFormat_BC2RGBAUnormSrgb,
            WGPUTextureFormat_BC3RGBAUnorm,
            WGPUTextureFormat_BC3RGBAUnormSrgb,
            WGPUTextureFormat_BC4RUnorm,
            WGPUTextureFormat_BC4RSnorm,
            WGPUTextureFormat_BC5RGUnorm,
            WGPUTextureFormat_BC5RGSnorm,
            WGPUTextureFormat_BC6HRGBUfloat,
            WGPUTextureFormat_BC6HRGBFloat,
            WGPUTextureFormat_BC7RGBAUnorm,
            WGPUTextureFormat_BC7RGBAUnormSrgb:
            return 4
        case WGPUTextureFormat_ETC2RGB8Unorm,
            WGPUTextureFormat_ETC2RGB8UnormSrgb,
            WGPUTextureFormat_ETC2RGB8A1Unorm,
            WGPUTextureFormat_ETC2RGB8A1UnormSrgb,
            WGPUTextureFormat_ETC2RGBA8Unorm,
            WGPUTextureFormat_ETC2RGBA8UnormSrgb,
            WGPUTextureFormat_EACR11Unorm,
            WGPUTextureFormat_EACR11Snorm,
            WGPUTextureFormat_EACRG11Unorm,
            WGPUTextureFormat_EACRG11Snorm:
            return 4
        case WGPUTextureFormat_ASTC4x4Unorm,
            WGPUTextureFormat_ASTC4x4UnormSrgb:
            return 4
        case WGPUTextureFormat_ASTC5x4Unorm,
            WGPUTextureFormat_ASTC5x4UnormSrgb,
            WGPUTextureFormat_ASTC5x5Unorm,
            WGPUTextureFormat_ASTC5x5UnormSrgb:
            return 5
        case WGPUTextureFormat_ASTC6x5Unorm,
            WGPUTextureFormat_ASTC6x5UnormSrgb,
            WGPUTextureFormat_ASTC6x6Unorm,
            WGPUTextureFormat_ASTC6x6UnormSrgb:
            return 6
        case WGPUTextureFormat_ASTC8x5Unorm,
            WGPUTextureFormat_ASTC8x5UnormSrgb,
            WGPUTextureFormat_ASTC8x6Unorm,
            WGPUTextureFormat_ASTC8x6UnormSrgb,
            WGPUTextureFormat_ASTC8x8Unorm,
            WGPUTextureFormat_ASTC8x8UnormSrgb:
            return 8
        case WGPUTextureFormat_ASTC10x5Unorm,
            WGPUTextureFormat_ASTC10x5UnormSrgb,
            WGPUTextureFormat_ASTC10x6Unorm,
            WGPUTextureFormat_ASTC10x6UnormSrgb,
            WGPUTextureFormat_ASTC10x8Unorm,
            WGPUTextureFormat_ASTC10x8UnormSrgb,
            WGPUTextureFormat_ASTC10x10Unorm,
            WGPUTextureFormat_ASTC10x10UnormSrgb:
            return 10
        case WGPUTextureFormat_ASTC12x10Unorm,
            WGPUTextureFormat_ASTC12x10UnormSrgb,
            WGPUTextureFormat_ASTC12x12Unorm,
            WGPUTextureFormat_ASTC12x12UnormSrgb:
            return 12
        case WGPUTextureFormat_R8Unorm,
            WGPUTextureFormat_R8Snorm,
            WGPUTextureFormat_R8Uint,
            WGPUTextureFormat_R8Sint,
            WGPUTextureFormat_R16Uint,
            WGPUTextureFormat_R16Sint,
            WGPUTextureFormat_R16Unorm,
            WGPUTextureFormat_R16Snorm,
            WGPUTextureFormat_RG16Unorm,
            WGPUTextureFormat_RG16Snorm,
            WGPUTextureFormat_RGBA16Unorm,
            WGPUTextureFormat_RGBA16Snorm,
            WGPUTextureFormat_R16Float,
            WGPUTextureFormat_RG8Unorm,
            WGPUTextureFormat_RG8Snorm,
            WGPUTextureFormat_RG8Uint,
            WGPUTextureFormat_RG8Sint,
            WGPUTextureFormat_R32Float,
            WGPUTextureFormat_R32Uint,
            WGPUTextureFormat_R32Sint,
            WGPUTextureFormat_RG16Uint,
            WGPUTextureFormat_RG16Sint,
            WGPUTextureFormat_RG16Float,
            WGPUTextureFormat_RGBA8Unorm,
            WGPUTextureFormat_RGBA8UnormSrgb,
            WGPUTextureFormat_RGBA8Snorm,
            WGPUTextureFormat_RGBA8Uint,
            WGPUTextureFormat_RGBA8Sint,
            WGPUTextureFormat_BGRA8Unorm,
            WGPUTextureFormat_BGRA8UnormSrgb,
            WGPUTextureFormat_RGB10A2Unorm,
            WGPUTextureFormat_RG11B10Ufloat,
            WGPUTextureFormat_RGB9E5Ufloat,
            WGPUTextureFormat_RGB10A2Uint,
            WGPUTextureFormat_RG32Float,
            WGPUTextureFormat_RG32Uint,
            WGPUTextureFormat_RG32Sint,
            WGPUTextureFormat_RGBA16Uint,
            WGPUTextureFormat_RGBA16Sint,
            WGPUTextureFormat_RGBA16Float,
            WGPUTextureFormat_RGBA32Float,
            WGPUTextureFormat_RGBA32Uint,
            WGPUTextureFormat_RGBA32Sint,
            WGPUTextureFormat_Stencil8,
            WGPUTextureFormat_Depth16Unorm,
            WGPUTextureFormat_Depth24Plus,
            WGPUTextureFormat_Depth24PlusStencil8,
            WGPUTextureFormat_Depth32Float,
            WGPUTextureFormat_Depth32FloatStencil8:
            return 1
        case WGPUTextureFormat_Undefined:
            return 0
        case WGPUTextureFormat_Force32:
            assertionFailure()
            return 0
        default:
            return 0
        }
    }

    /// The height in texels of one texel block of `format`.
    ///
    /// https://gpuweb.github.io/gpuweb/#texel-block-height
    static func texelBlockHeight(_ format: WGPUTextureFormat) -> UInt32 {
        switch format {
        case WGPUTextureFormat_BC1RGBAUnorm,
            WGPUTextureFormat_BC1RGBAUnormSrgb,
            WGPUTextureFormat_BC2RGBAUnorm,
            WGPUTextureFormat_BC2RGBAUnormSrgb,
            WGPUTextureFormat_BC3RGBAUnorm,
            WGPUTextureFormat_BC3RGBAUnormSrgb,
            WGPUTextureFormat_BC4RUnorm,
            WGPUTextureFormat_BC4RSnorm,
            WGPUTextureFormat_BC5RGUnorm,
            WGPUTextureFormat_BC5RGSnorm,
            WGPUTextureFormat_BC6HRGBUfloat,
            WGPUTextureFormat_BC6HRGBFloat,
            WGPUTextureFormat_BC7RGBAUnorm,
            WGPUTextureFormat_BC7RGBAUnormSrgb:
            return 4
        case WGPUTextureFormat_ETC2RGB8Unorm,
            WGPUTextureFormat_ETC2RGB8UnormSrgb,
            WGPUTextureFormat_ETC2RGB8A1Unorm,
            WGPUTextureFormat_ETC2RGB8A1UnormSrgb,
            WGPUTextureFormat_ETC2RGBA8Unorm,
            WGPUTextureFormat_ETC2RGBA8UnormSrgb,
            WGPUTextureFormat_EACR11Unorm,
            WGPUTextureFormat_EACR11Snorm,
            WGPUTextureFormat_EACRG11Unorm,
            WGPUTextureFormat_EACRG11Snorm:
            return 4
        case WGPUTextureFormat_ASTC4x4Unorm,
            WGPUTextureFormat_ASTC4x4UnormSrgb,
            WGPUTextureFormat_ASTC5x4Unorm,
            WGPUTextureFormat_ASTC5x4UnormSrgb:
            return 4
        case WGPUTextureFormat_ASTC5x5Unorm,
            WGPUTextureFormat_ASTC5x5UnormSrgb,
            WGPUTextureFormat_ASTC6x5Unorm,
            WGPUTextureFormat_ASTC6x5UnormSrgb:
            return 5
        case WGPUTextureFormat_ASTC6x6Unorm,
            WGPUTextureFormat_ASTC6x6UnormSrgb:
            return 6
        case WGPUTextureFormat_ASTC8x5Unorm,
            WGPUTextureFormat_ASTC8x5UnormSrgb:
            return 5
        case WGPUTextureFormat_ASTC8x6Unorm,
            WGPUTextureFormat_ASTC8x6UnormSrgb:
            return 6
        case WGPUTextureFormat_ASTC8x8Unorm,
            WGPUTextureFormat_ASTC8x8UnormSrgb:
            return 8
        case WGPUTextureFormat_ASTC10x5Unorm,
            WGPUTextureFormat_ASTC10x5UnormSrgb:
            return 5
        case WGPUTextureFormat_ASTC10x6Unorm,
            WGPUTextureFormat_ASTC10x6UnormSrgb:
            return 6
        case WGPUTextureFormat_ASTC10x8Unorm,
            WGPUTextureFormat_ASTC10x8UnormSrgb:
            return 8
        case WGPUTextureFormat_ASTC10x10Unorm,
            WGPUTextureFormat_ASTC10x10UnormSrgb,
            WGPUTextureFormat_ASTC12x10Unorm,
            WGPUTextureFormat_ASTC12x10UnormSrgb:
            return 10
        case WGPUTextureFormat_ASTC12x12Unorm,
            WGPUTextureFormat_ASTC12x12UnormSrgb:
            return 12
        case WGPUTextureFormat_R8Unorm,
            WGPUTextureFormat_R8Snorm,
            WGPUTextureFormat_R8Uint,
            WGPUTextureFormat_R8Sint,
            WGPUTextureFormat_R16Uint,
            WGPUTextureFormat_R16Sint,
            WGPUTextureFormat_R16Unorm,
            WGPUTextureFormat_R16Snorm,
            WGPUTextureFormat_RG16Unorm,
            WGPUTextureFormat_RG16Snorm,
            WGPUTextureFormat_RGBA16Unorm,
            WGPUTextureFormat_RGBA16Snorm,
            WGPUTextureFormat_R16Float,
            WGPUTextureFormat_RG8Unorm,
            WGPUTextureFormat_RG8Snorm,
            WGPUTextureFormat_RG8Uint,
            WGPUTextureFormat_RG8Sint,
            WGPUTextureFormat_R32Float,
            WGPUTextureFormat_R32Uint,
            WGPUTextureFormat_R32Sint,
            WGPUTextureFormat_RG16Uint,
            WGPUTextureFormat_RG16Sint,
            WGPUTextureFormat_RG16Float,
            WGPUTextureFormat_RGBA8Unorm,
            WGPUTextureFormat_RGBA8UnormSrgb,
            WGPUTextureFormat_RGBA8Snorm,
            WGPUTextureFormat_RGBA8Uint,
            WGPUTextureFormat_RGBA8Sint,
            WGPUTextureFormat_BGRA8Unorm,
            WGPUTextureFormat_BGRA8UnormSrgb,
            WGPUTextureFormat_RGB10A2Unorm,
            WGPUTextureFormat_RG11B10Ufloat,
            WGPUTextureFormat_RGB9E5Ufloat,
            WGPUTextureFormat_RGB10A2Uint,
            WGPUTextureFormat_RG32Float,
            WGPUTextureFormat_RG32Uint,
            WGPUTextureFormat_RG32Sint,
            WGPUTextureFormat_RGBA16Uint,
            WGPUTextureFormat_RGBA16Sint,
            WGPUTextureFormat_RGBA16Float,
            WGPUTextureFormat_RGBA32Float,
            WGPUTextureFormat_RGBA32Uint,
            WGPUTextureFormat_RGBA32Sint,
            WGPUTextureFormat_Stencil8,
            WGPUTextureFormat_Depth16Unorm,
            WGPUTextureFormat_Depth24Plus,
            WGPUTextureFormat_Depth24PlusStencil8,
            WGPUTextureFormat_Depth32Float,
            WGPUTextureFormat_Depth32FloatStencil8:
            return 1
        case WGPUTextureFormat_Undefined:
            return 0
        case WGPUTextureFormat_Force32:
            assertionFailure()
            return 0
        default:
            return 0
        }
    }

    /// The bytes one pixel of `format` costs against the render target budget.
    ///
    /// https://gpuweb.github.io/gpuweb/#renderable-format
    static func renderTargetPixelByteCost(_ format: WGPUTextureFormat) -> UInt32 {
        switch format {
        case WGPUTextureFormat_R8Unorm,
            WGPUTextureFormat_R8Uint,
            WGPUTextureFormat_R8Sint:
            return 1
        case WGPUTextureFormat_R16Uint,
            WGPUTextureFormat_R16Sint,
            WGPUTextureFormat_R16Float,
            WGPUTextureFormat_RG8Unorm,
            WGPUTextureFormat_RG8Uint,
            WGPUTextureFormat_RG8Sint,
            WGPUTextureFormat_R16Unorm,
            WGPUTextureFormat_R16Snorm:
            return 2
        case WGPUTextureFormat_R32Float,
            WGPUTextureFormat_R32Uint,
            WGPUTextureFormat_R32Sint,
            WGPUTextureFormat_RG16Uint,
            WGPUTextureFormat_RG16Sint,
            WGPUTextureFormat_RG16Float,
            WGPUTextureFormat_RG16Unorm,
            WGPUTextureFormat_RG16Snorm:
            return 4
        case WGPUTextureFormat_RGBA8Unorm,
            WGPUTextureFormat_RGBA8UnormSrgb:
            return 8
        case WGPUTextureFormat_RGBA8Uint,
            WGPUTextureFormat_RGBA8Sint:
            return 4
        case WGPUTextureFormat_BGRA8Unorm,
            WGPUTextureFormat_BGRA8UnormSrgb,
            WGPUTextureFormat_RGB10A2Uint,
            WGPUTextureFormat_RGB10A2Unorm,
            WGPUTextureFormat_RG32Float,
            WGPUTextureFormat_RG32Uint,
            WGPUTextureFormat_RG32Sint,
            WGPUTextureFormat_RGBA16Uint,
            WGPUTextureFormat_RGBA16Sint,
            WGPUTextureFormat_RGBA16Float,
            WGPUTextureFormat_RGBA16Unorm,
            WGPUTextureFormat_RGBA16Snorm:
            return 8
        case WGPUTextureFormat_RGBA32Float,
            WGPUTextureFormat_RGBA32Uint,
            WGPUTextureFormat_RGBA32Sint:
            return 16
        case WGPUTextureFormat_RG11B10Ufloat:
            return 8
        case WGPUTextureFormat_Stencil8,
            WGPUTextureFormat_Depth16Unorm,
            WGPUTextureFormat_Depth24Plus,
            WGPUTextureFormat_Depth24PlusStencil8,
            WGPUTextureFormat_Depth32Float,
            WGPUTextureFormat_Depth32FloatStencil8,
            WGPUTextureFormat_R8Snorm,
            WGPUTextureFormat_RG8Snorm,
            WGPUTextureFormat_RGBA8Snorm,
            WGPUTextureFormat_RGB9E5Ufloat,
            WGPUTextureFormat_BC1RGBAUnorm,
            WGPUTextureFormat_BC1RGBAUnormSrgb,
            WGPUTextureFormat_BC2RGBAUnorm,
            WGPUTextureFormat_BC2RGBAUnormSrgb,
            WGPUTextureFormat_BC3RGBAUnorm,
            WGPUTextureFormat_BC3RGBAUnormSrgb,
            WGPUTextureFormat_BC4RUnorm,
            WGPUTextureFormat_BC4RSnorm,
            WGPUTextureFormat_BC5RGUnorm,
            WGPUTextureFormat_BC5RGSnorm,
            WGPUTextureFormat_BC6HRGBUfloat,
            WGPUTextureFormat_BC6HRGBFloat,
            WGPUTextureFormat_BC7RGBAUnorm,
            WGPUTextureFormat_BC7RGBAUnormSrgb,
            WGPUTextureFormat_ETC2RGB8Unorm,
            WGPUTextureFormat_ETC2RGB8UnormSrgb,
            WGPUTextureFormat_ETC2RGB8A1Unorm,
            WGPUTextureFormat_ETC2RGB8A1UnormSrgb,
            WGPUTextureFormat_ETC2RGBA8Unorm,
            WGPUTextureFormat_ETC2RGBA8UnormSrgb,
            WGPUTextureFormat_EACR11Unorm,
            WGPUTextureFormat_EACR11Snorm,
            WGPUTextureFormat_EACRG11Unorm,
            WGPUTextureFormat_EACRG11Snorm,
            WGPUTextureFormat_ASTC4x4Unorm,
            WGPUTextureFormat_ASTC4x4UnormSrgb,
            WGPUTextureFormat_ASTC5x4Unorm,
            WGPUTextureFormat_ASTC5x4UnormSrgb,
            WGPUTextureFormat_ASTC5x5Unorm,
            WGPUTextureFormat_ASTC5x5UnormSrgb,
            WGPUTextureFormat_ASTC6x5Unorm,
            WGPUTextureFormat_ASTC6x5UnormSrgb,
            WGPUTextureFormat_ASTC6x6Unorm,
            WGPUTextureFormat_ASTC6x6UnormSrgb,
            WGPUTextureFormat_ASTC8x5Unorm,
            WGPUTextureFormat_ASTC8x5UnormSrgb,
            WGPUTextureFormat_ASTC8x6Unorm,
            WGPUTextureFormat_ASTC8x6UnormSrgb,
            WGPUTextureFormat_ASTC8x8Unorm,
            WGPUTextureFormat_ASTC8x8UnormSrgb,
            WGPUTextureFormat_ASTC10x5Unorm,
            WGPUTextureFormat_ASTC10x5UnormSrgb,
            WGPUTextureFormat_ASTC10x6Unorm,
            WGPUTextureFormat_ASTC10x6UnormSrgb,
            WGPUTextureFormat_ASTC10x8Unorm,
            WGPUTextureFormat_ASTC10x8UnormSrgb,
            WGPUTextureFormat_ASTC10x10Unorm,
            WGPUTextureFormat_ASTC10x10UnormSrgb,
            WGPUTextureFormat_ASTC12x10Unorm,
            WGPUTextureFormat_ASTC12x10UnormSrgb,
            WGPUTextureFormat_ASTC12x12Unorm,
            WGPUTextureFormat_ASTC12x12UnormSrgb:
            return 0
        case WGPUTextureFormat_Undefined:
            return 0
        case WGPUTextureFormat_Force32:
            assertionFailure()
            return 0
        default:
            return 0
        }
    }

    /// The alignment in bytes a pixel of `format` requires in a render target.
    ///
    /// https://gpuweb.github.io/gpuweb/#renderable-format
    static func renderTargetPixelByteAlignment(_ format: WGPUTextureFormat) -> UInt32 {
        switch format {
        case WGPUTextureFormat_R8Unorm,
            WGPUTextureFormat_R8Uint,
            WGPUTextureFormat_R8Sint,
            WGPUTextureFormat_RG8Unorm,
            WGPUTextureFormat_RG8Uint,
            WGPUTextureFormat_RG8Sint,
            WGPUTextureFormat_RGBA8Unorm,
            WGPUTextureFormat_RGBA8UnormSrgb,
            WGPUTextureFormat_RGBA8Uint,
            WGPUTextureFormat_RGBA8Sint,
            WGPUTextureFormat_BGRA8Unorm,
            WGPUTextureFormat_BGRA8UnormSrgb:
            return 1
        case WGPUTextureFormat_R16Uint,
            WGPUTextureFormat_R16Sint,
            WGPUTextureFormat_R16Float,
            WGPUTextureFormat_R16Unorm,
            WGPUTextureFormat_R16Snorm,
            WGPUTextureFormat_RG16Uint,
            WGPUTextureFormat_RG16Sint,
            WGPUTextureFormat_RG16Float,
            WGPUTextureFormat_RG16Unorm,
            WGPUTextureFormat_RG16Snorm,
            WGPUTextureFormat_RGBA16Uint,
            WGPUTextureFormat_RGBA16Sint,
            WGPUTextureFormat_RGBA16Float,
            WGPUTextureFormat_RGBA16Unorm,
            WGPUTextureFormat_RGBA16Snorm:
            return 2
        case WGPUTextureFormat_R32Float,
            WGPUTextureFormat_R32Uint,
            WGPUTextureFormat_R32Sint,
            WGPUTextureFormat_RGB10A2Uint,
            WGPUTextureFormat_RGB10A2Unorm,
            WGPUTextureFormat_RG32Float,
            WGPUTextureFormat_RG11B10Ufloat,
            WGPUTextureFormat_RG32Uint,
            WGPUTextureFormat_RG32Sint,
            WGPUTextureFormat_RGBA32Float,
            WGPUTextureFormat_RGBA32Uint,
            WGPUTextureFormat_RGBA32Sint:
            return 4
        case WGPUTextureFormat_Stencil8,
            WGPUTextureFormat_Depth16Unorm,
            WGPUTextureFormat_Depth24Plus,
            WGPUTextureFormat_Depth24PlusStencil8,
            WGPUTextureFormat_Depth32Float,
            WGPUTextureFormat_Depth32FloatStencil8,
            WGPUTextureFormat_R8Snorm,
            WGPUTextureFormat_RG8Snorm,
            WGPUTextureFormat_RGBA8Snorm,
            WGPUTextureFormat_RGB9E5Ufloat,
            WGPUTextureFormat_BC1RGBAUnorm,
            WGPUTextureFormat_BC1RGBAUnormSrgb,
            WGPUTextureFormat_BC2RGBAUnorm,
            WGPUTextureFormat_BC2RGBAUnormSrgb,
            WGPUTextureFormat_BC3RGBAUnorm,
            WGPUTextureFormat_BC3RGBAUnormSrgb,
            WGPUTextureFormat_BC4RUnorm,
            WGPUTextureFormat_BC4RSnorm,
            WGPUTextureFormat_BC5RGUnorm,
            WGPUTextureFormat_BC5RGSnorm,
            WGPUTextureFormat_BC6HRGBUfloat,
            WGPUTextureFormat_BC6HRGBFloat,
            WGPUTextureFormat_BC7RGBAUnorm,
            WGPUTextureFormat_BC7RGBAUnormSrgb,
            WGPUTextureFormat_ETC2RGB8Unorm,
            WGPUTextureFormat_ETC2RGB8UnormSrgb,
            WGPUTextureFormat_ETC2RGB8A1Unorm,
            WGPUTextureFormat_ETC2RGB8A1UnormSrgb,
            WGPUTextureFormat_ETC2RGBA8Unorm,
            WGPUTextureFormat_ETC2RGBA8UnormSrgb,
            WGPUTextureFormat_EACR11Unorm,
            WGPUTextureFormat_EACR11Snorm,
            WGPUTextureFormat_EACRG11Unorm,
            WGPUTextureFormat_EACRG11Snorm,
            WGPUTextureFormat_ASTC4x4Unorm,
            WGPUTextureFormat_ASTC4x4UnormSrgb,
            WGPUTextureFormat_ASTC5x4Unorm,
            WGPUTextureFormat_ASTC5x4UnormSrgb,
            WGPUTextureFormat_ASTC5x5Unorm,
            WGPUTextureFormat_ASTC5x5UnormSrgb,
            WGPUTextureFormat_ASTC6x5Unorm,
            WGPUTextureFormat_ASTC6x5UnormSrgb,
            WGPUTextureFormat_ASTC6x6Unorm,
            WGPUTextureFormat_ASTC6x6UnormSrgb,
            WGPUTextureFormat_ASTC8x5Unorm,
            WGPUTextureFormat_ASTC8x5UnormSrgb,
            WGPUTextureFormat_ASTC8x6Unorm,
            WGPUTextureFormat_ASTC8x6UnormSrgb,
            WGPUTextureFormat_ASTC8x8Unorm,
            WGPUTextureFormat_ASTC8x8UnormSrgb,
            WGPUTextureFormat_ASTC10x5Unorm,
            WGPUTextureFormat_ASTC10x5UnormSrgb,
            WGPUTextureFormat_ASTC10x6Unorm,
            WGPUTextureFormat_ASTC10x6UnormSrgb,
            WGPUTextureFormat_ASTC10x8Unorm,
            WGPUTextureFormat_ASTC10x8UnormSrgb,
            WGPUTextureFormat_ASTC10x10Unorm,
            WGPUTextureFormat_ASTC10x10UnormSrgb,
            WGPUTextureFormat_ASTC12x10Unorm,
            WGPUTextureFormat_ASTC12x10UnormSrgb,
            WGPUTextureFormat_ASTC12x12Unorm,
            WGPUTextureFormat_ASTC12x12UnormSrgb:
            return 0
        case WGPUTextureFormat_Undefined:
            return 0
        case WGPUTextureFormat_Force32:
            assertionFailure()
            return 0
        default:
            return 0
        }
    }

    /// `format` with its sRGB suffix dropped, or `format` when it has none.
    static func removeSRGBSuffix(_ format: WGPUTextureFormat) -> WGPUTextureFormat {
        switch format {
        case WGPUTextureFormat_R8Unorm,
            WGPUTextureFormat_R8Snorm,
            WGPUTextureFormat_R8Uint,
            WGPUTextureFormat_R8Sint,
            WGPUTextureFormat_R16Unorm,
            WGPUTextureFormat_R16Snorm,
            WGPUTextureFormat_R16Uint,
            WGPUTextureFormat_R16Sint,
            WGPUTextureFormat_R16Float,
            WGPUTextureFormat_RG8Unorm,
            WGPUTextureFormat_RG8Snorm,
            WGPUTextureFormat_RG8Uint,
            WGPUTextureFormat_RG8Sint,
            WGPUTextureFormat_R32Float,
            WGPUTextureFormat_R32Uint,
            WGPUTextureFormat_R32Sint,
            WGPUTextureFormat_RG16Unorm,
            WGPUTextureFormat_RG16Snorm,
            WGPUTextureFormat_RG16Uint,
            WGPUTextureFormat_RG16Sint,
            WGPUTextureFormat_RG16Float:
            return format
        case WGPUTextureFormat_RGBA8Unorm,
            WGPUTextureFormat_RGBA8UnormSrgb:
            return WGPUTextureFormat_RGBA8Unorm
        case WGPUTextureFormat_RGBA8Snorm,
            WGPUTextureFormat_RGBA8Uint,
            WGPUTextureFormat_RGBA8Sint:
            return format
        case WGPUTextureFormat_BGRA8Unorm,
            WGPUTextureFormat_BGRA8UnormSrgb:
            return WGPUTextureFormat_BGRA8Unorm
        case WGPUTextureFormat_RGB10A2Unorm,
            WGPUTextureFormat_RG11B10Ufloat,
            WGPUTextureFormat_RGB9E5Ufloat,
            WGPUTextureFormat_RGB10A2Uint,
            WGPUTextureFormat_RG32Float,
            WGPUTextureFormat_RG32Uint,
            WGPUTextureFormat_RG32Sint,
            WGPUTextureFormat_RGBA16Unorm,
            WGPUTextureFormat_RGBA16Snorm,
            WGPUTextureFormat_RGBA16Uint,
            WGPUTextureFormat_RGBA16Sint,
            WGPUTextureFormat_RGBA16Float,
            WGPUTextureFormat_RGBA32Float,
            WGPUTextureFormat_RGBA32Uint,
            WGPUTextureFormat_RGBA32Sint,
            WGPUTextureFormat_Stencil8,
            WGPUTextureFormat_Depth16Unorm,
            WGPUTextureFormat_Depth24Plus,
            WGPUTextureFormat_Depth24PlusStencil8,
            WGPUTextureFormat_Depth32Float,
            WGPUTextureFormat_Depth32FloatStencil8:
            return format
        case WGPUTextureFormat_BC1RGBAUnorm,
            WGPUTextureFormat_BC1RGBAUnormSrgb:
            return WGPUTextureFormat_BC1RGBAUnorm
        case WGPUTextureFormat_BC2RGBAUnorm,
            WGPUTextureFormat_BC2RGBAUnormSrgb:
            return WGPUTextureFormat_BC2RGBAUnorm
        case WGPUTextureFormat_BC3RGBAUnorm,
            WGPUTextureFormat_BC3RGBAUnormSrgb:
            return WGPUTextureFormat_BC3RGBAUnorm
        case WGPUTextureFormat_BC4RUnorm,
            WGPUTextureFormat_BC4RSnorm,
            WGPUTextureFormat_BC5RGUnorm,
            WGPUTextureFormat_BC5RGSnorm,
            WGPUTextureFormat_BC6HRGBUfloat,
            WGPUTextureFormat_BC6HRGBFloat:
            return format
        case WGPUTextureFormat_BC7RGBAUnorm,
            WGPUTextureFormat_BC7RGBAUnormSrgb:
            return WGPUTextureFormat_BC7RGBAUnorm
        case WGPUTextureFormat_ETC2RGB8Unorm,
            WGPUTextureFormat_ETC2RGB8UnormSrgb:
            return WGPUTextureFormat_ETC2RGB8Unorm
        case WGPUTextureFormat_ETC2RGB8A1Unorm,
            WGPUTextureFormat_ETC2RGB8A1UnormSrgb:
            return WGPUTextureFormat_ETC2RGB8A1Unorm
        case WGPUTextureFormat_ETC2RGBA8Unorm,
            WGPUTextureFormat_ETC2RGBA8UnormSrgb:
            return WGPUTextureFormat_ETC2RGBA8Unorm
        case WGPUTextureFormat_EACR11Unorm,
            WGPUTextureFormat_EACR11Snorm,
            WGPUTextureFormat_EACRG11Unorm,
            WGPUTextureFormat_EACRG11Snorm:
            return format
        case WGPUTextureFormat_ASTC4x4Unorm,
            WGPUTextureFormat_ASTC4x4UnormSrgb:
            return WGPUTextureFormat_ASTC4x4Unorm
        case WGPUTextureFormat_ASTC5x4Unorm,
            WGPUTextureFormat_ASTC5x4UnormSrgb:
            return WGPUTextureFormat_ASTC5x4Unorm
        case WGPUTextureFormat_ASTC5x5Unorm,
            WGPUTextureFormat_ASTC5x5UnormSrgb:
            return WGPUTextureFormat_ASTC5x5Unorm
        case WGPUTextureFormat_ASTC6x5Unorm,
            WGPUTextureFormat_ASTC6x5UnormSrgb:
            return WGPUTextureFormat_ASTC6x5Unorm
        case WGPUTextureFormat_ASTC6x6Unorm,
            WGPUTextureFormat_ASTC6x6UnormSrgb:
            return WGPUTextureFormat_ASTC6x6Unorm
        case WGPUTextureFormat_ASTC8x5Unorm,
            WGPUTextureFormat_ASTC8x5UnormSrgb:
            return WGPUTextureFormat_ASTC8x5Unorm
        case WGPUTextureFormat_ASTC8x6Unorm,
            WGPUTextureFormat_ASTC8x6UnormSrgb:
            return WGPUTextureFormat_ASTC8x6Unorm
        case WGPUTextureFormat_ASTC8x8Unorm,
            WGPUTextureFormat_ASTC8x8UnormSrgb:
            return WGPUTextureFormat_ASTC8x8Unorm
        case WGPUTextureFormat_ASTC10x5Unorm,
            WGPUTextureFormat_ASTC10x5UnormSrgb:
            return WGPUTextureFormat_ASTC10x5Unorm
        case WGPUTextureFormat_ASTC10x6Unorm,
            WGPUTextureFormat_ASTC10x6UnormSrgb:
            return WGPUTextureFormat_ASTC10x6Unorm
        case WGPUTextureFormat_ASTC10x8Unorm,
            WGPUTextureFormat_ASTC10x8UnormSrgb:
            return WGPUTextureFormat_ASTC10x8Unorm
        case WGPUTextureFormat_ASTC10x10Unorm,
            WGPUTextureFormat_ASTC10x10UnormSrgb:
            return WGPUTextureFormat_ASTC10x10Unorm
        case WGPUTextureFormat_ASTC12x10Unorm,
            WGPUTextureFormat_ASTC12x10UnormSrgb:
            return WGPUTextureFormat_ASTC12x10Unorm
        case WGPUTextureFormat_ASTC12x12Unorm,
            WGPUTextureFormat_ASTC12x12UnormSrgb:
            return WGPUTextureFormat_ASTC12x12Unorm
        case WGPUTextureFormat_Undefined:
            return WGPUTextureFormat_Undefined
        case WGPUTextureFormat_Force32:
            assertionFailure()
            return WGPUTextureFormat_Undefined
        default:
            return WGPUTextureFormat_Undefined
        }
    }

    /// Whether `aspect` of a depth-or-stencil `format` may be copied from.
    ///
    /// https://gpuweb.github.io/gpuweb/#depth-formats
    static func isValidDepthStencilCopySource(
        _ format: WGPUTextureFormat, _ aspect: WGPUTextureAspect
    ) -> Bool {
        assert(isDepthOrStencilFormat(format))
        switch format {
        case WGPUTextureFormat_Undefined,
            WGPUTextureFormat_R8Unorm,
            WGPUTextureFormat_R8Snorm,
            WGPUTextureFormat_R8Uint,
            WGPUTextureFormat_R8Sint,
            WGPUTextureFormat_R16Unorm,
            WGPUTextureFormat_R16Snorm,
            WGPUTextureFormat_R16Uint,
            WGPUTextureFormat_R16Sint,
            WGPUTextureFormat_R16Float,
            WGPUTextureFormat_RG8Unorm,
            WGPUTextureFormat_RG8Snorm,
            WGPUTextureFormat_RG8Uint,
            WGPUTextureFormat_RG8Sint,
            WGPUTextureFormat_R32Float,
            WGPUTextureFormat_R32Uint,
            WGPUTextureFormat_R32Sint,
            WGPUTextureFormat_RG16Unorm,
            WGPUTextureFormat_RG16Snorm,
            WGPUTextureFormat_RG16Uint,
            WGPUTextureFormat_RG16Sint,
            WGPUTextureFormat_RG16Float,
            WGPUTextureFormat_RGBA8Unorm,
            WGPUTextureFormat_RGBA8UnormSrgb,
            WGPUTextureFormat_RGBA8Snorm,
            WGPUTextureFormat_RGBA8Uint,
            WGPUTextureFormat_RGBA8Sint,
            WGPUTextureFormat_BGRA8Unorm,
            WGPUTextureFormat_BGRA8UnormSrgb,
            WGPUTextureFormat_RGB10A2Unorm,
            WGPUTextureFormat_RG11B10Ufloat,
            WGPUTextureFormat_RGB9E5Ufloat,
            WGPUTextureFormat_RGB10A2Uint,
            WGPUTextureFormat_RG32Float,
            WGPUTextureFormat_RG32Uint,
            WGPUTextureFormat_RG32Sint,
            WGPUTextureFormat_RGBA16Unorm,
            WGPUTextureFormat_RGBA16Snorm,
            WGPUTextureFormat_RGBA16Uint,
            WGPUTextureFormat_RGBA16Sint,
            WGPUTextureFormat_RGBA16Float,
            WGPUTextureFormat_RGBA32Float,
            WGPUTextureFormat_RGBA32Uint,
            WGPUTextureFormat_RGBA32Sint:
            assertionFailure()
            return false
        case WGPUTextureFormat_Stencil8,
            WGPUTextureFormat_Depth16Unorm:
            return true
        case WGPUTextureFormat_Depth24Plus:
            return false
        case WGPUTextureFormat_Depth24PlusStencil8:
            return aspect == WGPUTextureAspect_StencilOnly
        case WGPUTextureFormat_Depth32Float,
            WGPUTextureFormat_Depth32FloatStencil8:
            return true
        case WGPUTextureFormat_BC1RGBAUnorm,
            WGPUTextureFormat_BC1RGBAUnormSrgb,
            WGPUTextureFormat_BC2RGBAUnorm,
            WGPUTextureFormat_BC2RGBAUnormSrgb,
            WGPUTextureFormat_BC3RGBAUnorm,
            WGPUTextureFormat_BC3RGBAUnormSrgb,
            WGPUTextureFormat_BC4RUnorm,
            WGPUTextureFormat_BC4RSnorm,
            WGPUTextureFormat_BC5RGUnorm,
            WGPUTextureFormat_BC5RGSnorm,
            WGPUTextureFormat_BC6HRGBUfloat,
            WGPUTextureFormat_BC6HRGBFloat,
            WGPUTextureFormat_BC7RGBAUnorm,
            WGPUTextureFormat_BC7RGBAUnormSrgb,
            WGPUTextureFormat_ETC2RGB8Unorm,
            WGPUTextureFormat_ETC2RGB8UnormSrgb,
            WGPUTextureFormat_ETC2RGB8A1Unorm,
            WGPUTextureFormat_ETC2RGB8A1UnormSrgb,
            WGPUTextureFormat_ETC2RGBA8Unorm,
            WGPUTextureFormat_ETC2RGBA8UnormSrgb,
            WGPUTextureFormat_EACR11Unorm,
            WGPUTextureFormat_EACR11Snorm,
            WGPUTextureFormat_EACRG11Unorm,
            WGPUTextureFormat_EACRG11Snorm,
            WGPUTextureFormat_ASTC4x4Unorm,
            WGPUTextureFormat_ASTC4x4UnormSrgb,
            WGPUTextureFormat_ASTC5x4Unorm,
            WGPUTextureFormat_ASTC5x4UnormSrgb,
            WGPUTextureFormat_ASTC5x5Unorm,
            WGPUTextureFormat_ASTC5x5UnormSrgb,
            WGPUTextureFormat_ASTC6x5Unorm,
            WGPUTextureFormat_ASTC6x5UnormSrgb,
            WGPUTextureFormat_ASTC6x6Unorm,
            WGPUTextureFormat_ASTC6x6UnormSrgb,
            WGPUTextureFormat_ASTC8x5Unorm,
            WGPUTextureFormat_ASTC8x5UnormSrgb,
            WGPUTextureFormat_ASTC8x6Unorm,
            WGPUTextureFormat_ASTC8x6UnormSrgb,
            WGPUTextureFormat_ASTC8x8Unorm,
            WGPUTextureFormat_ASTC8x8UnormSrgb,
            WGPUTextureFormat_ASTC10x5Unorm,
            WGPUTextureFormat_ASTC10x5UnormSrgb,
            WGPUTextureFormat_ASTC10x6Unorm,
            WGPUTextureFormat_ASTC10x6UnormSrgb,
            WGPUTextureFormat_ASTC10x8Unorm,
            WGPUTextureFormat_ASTC10x8UnormSrgb,
            WGPUTextureFormat_ASTC10x10Unorm,
            WGPUTextureFormat_ASTC10x10UnormSrgb,
            WGPUTextureFormat_ASTC12x10Unorm,
            WGPUTextureFormat_ASTC12x10UnormSrgb,
            WGPUTextureFormat_ASTC12x12Unorm,
            WGPUTextureFormat_ASTC12x12UnormSrgb,
            WGPUTextureFormat_Force32:
            assertionFailure()
            return false
        default:
            return false
        }
    }

    /// Whether `aspect` of a depth-or-stencil `format` may be copied to.
    ///
    /// https://gpuweb.github.io/gpuweb/#depth-formats
    static func isValidDepthStencilCopyDestination(
        _ format: WGPUTextureFormat, _ aspect: WGPUTextureAspect
    ) -> Bool {
        assert(isDepthOrStencilFormat(format))
        switch format {
        case WGPUTextureFormat_Undefined,
            WGPUTextureFormat_R8Unorm,
            WGPUTextureFormat_R8Snorm,
            WGPUTextureFormat_R8Uint,
            WGPUTextureFormat_R8Sint,
            WGPUTextureFormat_R16Unorm,
            WGPUTextureFormat_R16Snorm,
            WGPUTextureFormat_R16Uint,
            WGPUTextureFormat_R16Sint,
            WGPUTextureFormat_R16Float,
            WGPUTextureFormat_RG8Unorm,
            WGPUTextureFormat_RG8Snorm,
            WGPUTextureFormat_RG8Uint,
            WGPUTextureFormat_RG8Sint,
            WGPUTextureFormat_R32Float,
            WGPUTextureFormat_R32Uint,
            WGPUTextureFormat_R32Sint,
            WGPUTextureFormat_RG16Unorm,
            WGPUTextureFormat_RG16Snorm,
            WGPUTextureFormat_RG16Uint,
            WGPUTextureFormat_RG16Sint,
            WGPUTextureFormat_RG16Float,
            WGPUTextureFormat_RGBA8Unorm,
            WGPUTextureFormat_RGBA8UnormSrgb,
            WGPUTextureFormat_RGBA8Snorm,
            WGPUTextureFormat_RGBA8Uint,
            WGPUTextureFormat_RGBA8Sint,
            WGPUTextureFormat_BGRA8Unorm,
            WGPUTextureFormat_BGRA8UnormSrgb,
            WGPUTextureFormat_RGB10A2Unorm,
            WGPUTextureFormat_RG11B10Ufloat,
            WGPUTextureFormat_RGB9E5Ufloat,
            WGPUTextureFormat_RGB10A2Uint,
            WGPUTextureFormat_RG32Float,
            WGPUTextureFormat_RG32Uint,
            WGPUTextureFormat_RG32Sint,
            WGPUTextureFormat_RGBA16Unorm,
            WGPUTextureFormat_RGBA16Snorm,
            WGPUTextureFormat_RGBA16Uint,
            WGPUTextureFormat_RGBA16Sint,
            WGPUTextureFormat_RGBA16Float,
            WGPUTextureFormat_RGBA32Float,
            WGPUTextureFormat_RGBA32Uint,
            WGPUTextureFormat_RGBA32Sint:
            return false
        case WGPUTextureFormat_Stencil8,
            WGPUTextureFormat_Depth16Unorm:
            return true
        case WGPUTextureFormat_Depth24Plus:
            return false
        case WGPUTextureFormat_Depth24PlusStencil8:
            return aspect == WGPUTextureAspect_StencilOnly
        case WGPUTextureFormat_Depth32Float:
            return false
        case WGPUTextureFormat_Depth32FloatStencil8:
            return aspect == WGPUTextureAspect_StencilOnly
        case WGPUTextureFormat_BC1RGBAUnorm,
            WGPUTextureFormat_BC1RGBAUnormSrgb,
            WGPUTextureFormat_BC2RGBAUnorm,
            WGPUTextureFormat_BC2RGBAUnormSrgb,
            WGPUTextureFormat_BC3RGBAUnorm,
            WGPUTextureFormat_BC3RGBAUnormSrgb,
            WGPUTextureFormat_BC4RUnorm,
            WGPUTextureFormat_BC4RSnorm,
            WGPUTextureFormat_BC5RGUnorm,
            WGPUTextureFormat_BC5RGSnorm,
            WGPUTextureFormat_BC6HRGBUfloat,
            WGPUTextureFormat_BC6HRGBFloat,
            WGPUTextureFormat_BC7RGBAUnorm,
            WGPUTextureFormat_BC7RGBAUnormSrgb,
            WGPUTextureFormat_ETC2RGB8Unorm,
            WGPUTextureFormat_ETC2RGB8UnormSrgb,
            WGPUTextureFormat_ETC2RGB8A1Unorm,
            WGPUTextureFormat_ETC2RGB8A1UnormSrgb,
            WGPUTextureFormat_ETC2RGBA8Unorm,
            WGPUTextureFormat_ETC2RGBA8UnormSrgb,
            WGPUTextureFormat_EACR11Unorm,
            WGPUTextureFormat_EACR11Snorm,
            WGPUTextureFormat_EACRG11Unorm,
            WGPUTextureFormat_EACRG11Snorm,
            WGPUTextureFormat_ASTC4x4Unorm,
            WGPUTextureFormat_ASTC4x4UnormSrgb,
            WGPUTextureFormat_ASTC5x4Unorm,
            WGPUTextureFormat_ASTC5x4UnormSrgb,
            WGPUTextureFormat_ASTC5x5Unorm,
            WGPUTextureFormat_ASTC5x5UnormSrgb,
            WGPUTextureFormat_ASTC6x5Unorm,
            WGPUTextureFormat_ASTC6x5UnormSrgb,
            WGPUTextureFormat_ASTC6x6Unorm,
            WGPUTextureFormat_ASTC6x6UnormSrgb,
            WGPUTextureFormat_ASTC8x5Unorm,
            WGPUTextureFormat_ASTC8x5UnormSrgb,
            WGPUTextureFormat_ASTC8x6Unorm,
            WGPUTextureFormat_ASTC8x6UnormSrgb,
            WGPUTextureFormat_ASTC8x8Unorm,
            WGPUTextureFormat_ASTC8x8UnormSrgb,
            WGPUTextureFormat_ASTC10x5Unorm,
            WGPUTextureFormat_ASTC10x5UnormSrgb,
            WGPUTextureFormat_ASTC10x6Unorm,
            WGPUTextureFormat_ASTC10x6UnormSrgb,
            WGPUTextureFormat_ASTC10x8Unorm,
            WGPUTextureFormat_ASTC10x8UnormSrgb,
            WGPUTextureFormat_ASTC10x10Unorm,
            WGPUTextureFormat_ASTC10x10UnormSrgb,
            WGPUTextureFormat_ASTC12x10Unorm,
            WGPUTextureFormat_ASTC12x10UnormSrgb,
            WGPUTextureFormat_ASTC12x12Unorm,
            WGPUTextureFormat_ASTC12x12UnormSrgb:
            return false
        case WGPUTextureFormat_Force32:
            assertionFailure()
            return false
        default:
            return false
        }
    }

    /// The compressed family `format` belongs to, or `compressedFormatNone`.
    ///
    /// Returns the family as an `Int32` rather than as an enumeration, because
    /// `Texture::CompressFormat` is declared in Texture.h and the C++ arm's
    /// `std::optional<CompressFormat>` has no representation across
    /// `@_expose(Cxx)`. Texture.mm turns the value back into the optional, and
    /// static_asserts there that the four values below are the ones it maps.
    ///
    /// https://gpuweb.github.io/gpuweb/#packed-formats
    static func compressedFormatType(_ format: WGPUTextureFormat) -> Int32 {
        switch format {
        case WGPUTextureFormat_BC1RGBAUnorm,
            WGPUTextureFormat_BC1RGBAUnormSrgb,
            WGPUTextureFormat_BC2RGBAUnorm,
            WGPUTextureFormat_BC2RGBAUnormSrgb,
            WGPUTextureFormat_BC3RGBAUnorm,
            WGPUTextureFormat_BC3RGBAUnormSrgb,
            WGPUTextureFormat_BC4RUnorm,
            WGPUTextureFormat_BC4RSnorm,
            WGPUTextureFormat_BC5RGUnorm,
            WGPUTextureFormat_BC5RGSnorm,
            WGPUTextureFormat_BC6HRGBUfloat,
            WGPUTextureFormat_BC6HRGBFloat,
            WGPUTextureFormat_BC7RGBAUnorm,
            WGPUTextureFormat_BC7RGBAUnormSrgb:
            return compressedFormatBC
        case WGPUTextureFormat_ETC2RGB8Unorm,
            WGPUTextureFormat_ETC2RGB8UnormSrgb,
            WGPUTextureFormat_ETC2RGB8A1Unorm,
            WGPUTextureFormat_ETC2RGB8A1UnormSrgb,
            WGPUTextureFormat_ETC2RGBA8Unorm,
            WGPUTextureFormat_ETC2RGBA8UnormSrgb,
            WGPUTextureFormat_EACR11Unorm,
            WGPUTextureFormat_EACR11Snorm,
            WGPUTextureFormat_EACRG11Unorm,
            WGPUTextureFormat_EACRG11Snorm:
            return compressedFormatETC
        case WGPUTextureFormat_ASTC4x4Unorm,
            WGPUTextureFormat_ASTC4x4UnormSrgb,
            WGPUTextureFormat_ASTC5x4Unorm,
            WGPUTextureFormat_ASTC5x4UnormSrgb,
            WGPUTextureFormat_ASTC5x5Unorm,
            WGPUTextureFormat_ASTC5x5UnormSrgb,
            WGPUTextureFormat_ASTC6x5Unorm,
            WGPUTextureFormat_ASTC6x5UnormSrgb,
            WGPUTextureFormat_ASTC6x6Unorm,
            WGPUTextureFormat_ASTC6x6UnormSrgb,
            WGPUTextureFormat_ASTC8x5Unorm,
            WGPUTextureFormat_ASTC8x5UnormSrgb,
            WGPUTextureFormat_ASTC8x6Unorm,
            WGPUTextureFormat_ASTC8x6UnormSrgb,
            WGPUTextureFormat_ASTC8x8Unorm,
            WGPUTextureFormat_ASTC8x8UnormSrgb,
            WGPUTextureFormat_ASTC10x5Unorm,
            WGPUTextureFormat_ASTC10x5UnormSrgb,
            WGPUTextureFormat_ASTC10x6Unorm,
            WGPUTextureFormat_ASTC10x6UnormSrgb,
            WGPUTextureFormat_ASTC10x8Unorm,
            WGPUTextureFormat_ASTC10x8UnormSrgb,
            WGPUTextureFormat_ASTC10x10Unorm,
            WGPUTextureFormat_ASTC10x10UnormSrgb,
            WGPUTextureFormat_ASTC12x10Unorm,
            WGPUTextureFormat_ASTC12x10UnormSrgb,
            WGPUTextureFormat_ASTC12x12Unorm,
            WGPUTextureFormat_ASTC12x12UnormSrgb:
            return compressedFormatASTC
        case WGPUTextureFormat_R16Unorm,
            WGPUTextureFormat_R16Snorm,
            WGPUTextureFormat_RG16Unorm,
            WGPUTextureFormat_RG16Snorm,
            WGPUTextureFormat_RGBA16Unorm,
            WGPUTextureFormat_RGBA16Snorm,
            WGPUTextureFormat_R8Unorm,
            WGPUTextureFormat_R8Snorm,
            WGPUTextureFormat_R8Uint,
            WGPUTextureFormat_R8Sint,
            WGPUTextureFormat_R16Uint,
            WGPUTextureFormat_R16Sint,
            WGPUTextureFormat_R16Float,
            WGPUTextureFormat_RG8Unorm,
            WGPUTextureFormat_RG8Snorm,
            WGPUTextureFormat_RG8Uint,
            WGPUTextureFormat_RG8Sint,
            WGPUTextureFormat_R32Float,
            WGPUTextureFormat_R32Uint,
            WGPUTextureFormat_R32Sint,
            WGPUTextureFormat_RG16Uint,
            WGPUTextureFormat_RG16Sint,
            WGPUTextureFormat_RG16Float,
            WGPUTextureFormat_RGBA8Unorm,
            WGPUTextureFormat_RGBA8UnormSrgb,
            WGPUTextureFormat_RGBA8Snorm,
            WGPUTextureFormat_RGBA8Uint,
            WGPUTextureFormat_RGBA8Sint,
            WGPUTextureFormat_BGRA8Unorm,
            WGPUTextureFormat_BGRA8UnormSrgb,
            WGPUTextureFormat_RGB10A2Unorm,
            WGPUTextureFormat_RG11B10Ufloat,
            WGPUTextureFormat_RGB9E5Ufloat,
            WGPUTextureFormat_RGB10A2Uint,
            WGPUTextureFormat_RG32Float,
            WGPUTextureFormat_RG32Uint,
            WGPUTextureFormat_RG32Sint,
            WGPUTextureFormat_RGBA16Uint,
            WGPUTextureFormat_RGBA16Sint,
            WGPUTextureFormat_RGBA16Float,
            WGPUTextureFormat_RGBA32Float,
            WGPUTextureFormat_RGBA32Uint,
            WGPUTextureFormat_RGBA32Sint,
            WGPUTextureFormat_Stencil8,
            WGPUTextureFormat_Depth16Unorm,
            WGPUTextureFormat_Depth24Plus,
            WGPUTextureFormat_Depth24PlusStencil8,
            WGPUTextureFormat_Depth32Float,
            WGPUTextureFormat_Depth32FloatStencil8:
            return compressedFormatNone
        case WGPUTextureFormat_Undefined:
            return compressedFormatNone
        case WGPUTextureFormat_Force32:
            assertionFailure()
            return compressedFormatNone
        default:
            return compressedFormatNone
        }
    }

    /// The depth aspect of `format` as a format of its own, or
    /// `WGPUTextureFormat_Undefined` when `format` has no depth aspect.
    ///
    /// https://gpuweb.github.io/gpuweb/#aspect-specific-format
    static func depthSpecificFormat(_ format: WGPUTextureFormat) -> WGPUTextureFormat {
        switch format {
        case WGPUTextureFormat_R8Unorm,
            WGPUTextureFormat_R8Snorm,
            WGPUTextureFormat_R8Uint,
            WGPUTextureFormat_R8Sint,
            WGPUTextureFormat_R16Uint,
            WGPUTextureFormat_R16Sint,
            WGPUTextureFormat_R16Unorm,
            WGPUTextureFormat_R16Snorm,
            WGPUTextureFormat_RG16Unorm,
            WGPUTextureFormat_RG16Snorm,
            WGPUTextureFormat_RGBA16Unorm,
            WGPUTextureFormat_RGBA16Snorm,
            WGPUTextureFormat_R16Float,
            WGPUTextureFormat_RG8Unorm,
            WGPUTextureFormat_RG8Snorm,
            WGPUTextureFormat_RG8Uint,
            WGPUTextureFormat_RG8Sint,
            WGPUTextureFormat_R32Float,
            WGPUTextureFormat_R32Uint,
            WGPUTextureFormat_R32Sint,
            WGPUTextureFormat_RG16Uint,
            WGPUTextureFormat_RG16Sint,
            WGPUTextureFormat_RG16Float,
            WGPUTextureFormat_RGBA8Unorm,
            WGPUTextureFormat_RGBA8UnormSrgb,
            WGPUTextureFormat_RGBA8Snorm,
            WGPUTextureFormat_RGBA8Uint,
            WGPUTextureFormat_RGBA8Sint,
            WGPUTextureFormat_BGRA8Unorm,
            WGPUTextureFormat_BGRA8UnormSrgb,
            WGPUTextureFormat_RGB10A2Unorm,
            WGPUTextureFormat_RG11B10Ufloat,
            WGPUTextureFormat_RGB9E5Ufloat,
            WGPUTextureFormat_RGB10A2Uint,
            WGPUTextureFormat_RG32Float,
            WGPUTextureFormat_RG32Uint,
            WGPUTextureFormat_RG32Sint,
            WGPUTextureFormat_RGBA16Uint,
            WGPUTextureFormat_RGBA16Sint,
            WGPUTextureFormat_RGBA16Float,
            WGPUTextureFormat_RGBA32Float,
            WGPUTextureFormat_RGBA32Uint,
            WGPUTextureFormat_RGBA32Sint,
            WGPUTextureFormat_Stencil8:
            return WGPUTextureFormat_Undefined
        case WGPUTextureFormat_Depth16Unorm:
            return WGPUTextureFormat_Depth16Unorm
        case WGPUTextureFormat_Depth24Plus:
            return WGPUTextureFormat_Depth24Plus
        case WGPUTextureFormat_Depth24PlusStencil8:
            return WGPUTextureFormat_Depth24Plus
        case WGPUTextureFormat_Depth32Float:
            return WGPUTextureFormat_Depth32Float
        case WGPUTextureFormat_Depth32FloatStencil8:
            return WGPUTextureFormat_Depth32Float
        case WGPUTextureFormat_BC1RGBAUnorm,
            WGPUTextureFormat_BC1RGBAUnormSrgb,
            WGPUTextureFormat_BC2RGBAUnorm,
            WGPUTextureFormat_BC2RGBAUnormSrgb,
            WGPUTextureFormat_BC3RGBAUnorm,
            WGPUTextureFormat_BC3RGBAUnormSrgb,
            WGPUTextureFormat_BC4RUnorm,
            WGPUTextureFormat_BC4RSnorm,
            WGPUTextureFormat_BC5RGUnorm,
            WGPUTextureFormat_BC5RGSnorm,
            WGPUTextureFormat_BC6HRGBUfloat,
            WGPUTextureFormat_BC6HRGBFloat,
            WGPUTextureFormat_BC7RGBAUnorm,
            WGPUTextureFormat_BC7RGBAUnormSrgb,
            WGPUTextureFormat_ETC2RGB8Unorm,
            WGPUTextureFormat_ETC2RGB8UnormSrgb,
            WGPUTextureFormat_ETC2RGB8A1Unorm,
            WGPUTextureFormat_ETC2RGB8A1UnormSrgb,
            WGPUTextureFormat_ETC2RGBA8Unorm,
            WGPUTextureFormat_ETC2RGBA8UnormSrgb,
            WGPUTextureFormat_EACR11Unorm,
            WGPUTextureFormat_EACR11Snorm,
            WGPUTextureFormat_EACRG11Unorm,
            WGPUTextureFormat_EACRG11Snorm,
            WGPUTextureFormat_ASTC4x4Unorm,
            WGPUTextureFormat_ASTC4x4UnormSrgb,
            WGPUTextureFormat_ASTC5x4Unorm,
            WGPUTextureFormat_ASTC5x4UnormSrgb,
            WGPUTextureFormat_ASTC5x5Unorm,
            WGPUTextureFormat_ASTC5x5UnormSrgb,
            WGPUTextureFormat_ASTC6x5Unorm,
            WGPUTextureFormat_ASTC6x5UnormSrgb,
            WGPUTextureFormat_ASTC6x6Unorm,
            WGPUTextureFormat_ASTC6x6UnormSrgb,
            WGPUTextureFormat_ASTC8x5Unorm,
            WGPUTextureFormat_ASTC8x5UnormSrgb,
            WGPUTextureFormat_ASTC8x6Unorm,
            WGPUTextureFormat_ASTC8x6UnormSrgb,
            WGPUTextureFormat_ASTC8x8Unorm,
            WGPUTextureFormat_ASTC8x8UnormSrgb,
            WGPUTextureFormat_ASTC10x5Unorm,
            WGPUTextureFormat_ASTC10x5UnormSrgb,
            WGPUTextureFormat_ASTC10x6Unorm,
            WGPUTextureFormat_ASTC10x6UnormSrgb,
            WGPUTextureFormat_ASTC10x8Unorm,
            WGPUTextureFormat_ASTC10x8UnormSrgb,
            WGPUTextureFormat_ASTC10x10Unorm,
            WGPUTextureFormat_ASTC10x10UnormSrgb,
            WGPUTextureFormat_ASTC12x10Unorm,
            WGPUTextureFormat_ASTC12x10UnormSrgb,
            WGPUTextureFormat_ASTC12x12Unorm,
            WGPUTextureFormat_ASTC12x12UnormSrgb:
            return WGPUTextureFormat_Undefined
        case WGPUTextureFormat_Undefined:
            return WGPUTextureFormat_Undefined
        case WGPUTextureFormat_Force32:
            assertionFailure()
            return WGPUTextureFormat_Undefined
        default:
            return WGPUTextureFormat_Undefined
        }
    }

    /// The stencil aspect of `format` as a format of its own, or
    /// `WGPUTextureFormat_Undefined` when `format` has no stencil aspect.
    ///
    /// https://gpuweb.github.io/gpuweb/#aspect-specific-format
    static func stencilSpecificFormat(_ format: WGPUTextureFormat) -> WGPUTextureFormat {
        switch format {
        case WGPUTextureFormat_R8Unorm,
            WGPUTextureFormat_R8Snorm,
            WGPUTextureFormat_R8Uint,
            WGPUTextureFormat_R8Sint,
            WGPUTextureFormat_R16Uint,
            WGPUTextureFormat_R16Sint,
            WGPUTextureFormat_R16Unorm,
            WGPUTextureFormat_R16Snorm,
            WGPUTextureFormat_RG16Unorm,
            WGPUTextureFormat_RG16Snorm,
            WGPUTextureFormat_RGBA16Unorm,
            WGPUTextureFormat_RGBA16Snorm,
            WGPUTextureFormat_R16Float,
            WGPUTextureFormat_RG8Unorm,
            WGPUTextureFormat_RG8Snorm,
            WGPUTextureFormat_RG8Uint,
            WGPUTextureFormat_RG8Sint,
            WGPUTextureFormat_R32Float,
            WGPUTextureFormat_R32Uint,
            WGPUTextureFormat_R32Sint,
            WGPUTextureFormat_RG16Uint,
            WGPUTextureFormat_RG16Sint,
            WGPUTextureFormat_RG16Float,
            WGPUTextureFormat_RGBA8Unorm,
            WGPUTextureFormat_RGBA8UnormSrgb,
            WGPUTextureFormat_RGBA8Snorm,
            WGPUTextureFormat_RGBA8Uint,
            WGPUTextureFormat_RGBA8Sint,
            WGPUTextureFormat_BGRA8Unorm,
            WGPUTextureFormat_BGRA8UnormSrgb,
            WGPUTextureFormat_RGB10A2Unorm,
            WGPUTextureFormat_RG11B10Ufloat,
            WGPUTextureFormat_RGB9E5Ufloat,
            WGPUTextureFormat_RGB10A2Uint,
            WGPUTextureFormat_RG32Float,
            WGPUTextureFormat_RG32Uint,
            WGPUTextureFormat_RG32Sint,
            WGPUTextureFormat_RGBA16Uint,
            WGPUTextureFormat_RGBA16Sint,
            WGPUTextureFormat_RGBA16Float,
            WGPUTextureFormat_RGBA32Float,
            WGPUTextureFormat_RGBA32Uint,
            WGPUTextureFormat_RGBA32Sint:
            return WGPUTextureFormat_Undefined
        case WGPUTextureFormat_Stencil8:
            return WGPUTextureFormat_Stencil8
        case WGPUTextureFormat_Depth16Unorm,
            WGPUTextureFormat_Depth24Plus:
            return WGPUTextureFormat_Undefined
        case WGPUTextureFormat_Depth24PlusStencil8:
            return WGPUTextureFormat_Stencil8
        case WGPUTextureFormat_Depth32Float:
            return WGPUTextureFormat_Undefined
        case WGPUTextureFormat_Depth32FloatStencil8:
            return WGPUTextureFormat_Stencil8
        case WGPUTextureFormat_BC1RGBAUnorm,
            WGPUTextureFormat_BC1RGBAUnormSrgb,
            WGPUTextureFormat_BC2RGBAUnorm,
            WGPUTextureFormat_BC2RGBAUnormSrgb,
            WGPUTextureFormat_BC3RGBAUnorm,
            WGPUTextureFormat_BC3RGBAUnormSrgb,
            WGPUTextureFormat_BC4RUnorm,
            WGPUTextureFormat_BC4RSnorm,
            WGPUTextureFormat_BC5RGUnorm,
            WGPUTextureFormat_BC5RGSnorm,
            WGPUTextureFormat_BC6HRGBUfloat,
            WGPUTextureFormat_BC6HRGBFloat,
            WGPUTextureFormat_BC7RGBAUnorm,
            WGPUTextureFormat_BC7RGBAUnormSrgb,
            WGPUTextureFormat_ETC2RGB8Unorm,
            WGPUTextureFormat_ETC2RGB8UnormSrgb,
            WGPUTextureFormat_ETC2RGB8A1Unorm,
            WGPUTextureFormat_ETC2RGB8A1UnormSrgb,
            WGPUTextureFormat_ETC2RGBA8Unorm,
            WGPUTextureFormat_ETC2RGBA8UnormSrgb,
            WGPUTextureFormat_EACR11Unorm,
            WGPUTextureFormat_EACR11Snorm,
            WGPUTextureFormat_EACRG11Unorm,
            WGPUTextureFormat_EACRG11Snorm,
            WGPUTextureFormat_ASTC4x4Unorm,
            WGPUTextureFormat_ASTC4x4UnormSrgb,
            WGPUTextureFormat_ASTC5x4Unorm,
            WGPUTextureFormat_ASTC5x4UnormSrgb,
            WGPUTextureFormat_ASTC5x5Unorm,
            WGPUTextureFormat_ASTC5x5UnormSrgb,
            WGPUTextureFormat_ASTC6x5Unorm,
            WGPUTextureFormat_ASTC6x5UnormSrgb,
            WGPUTextureFormat_ASTC6x6Unorm,
            WGPUTextureFormat_ASTC6x6UnormSrgb,
            WGPUTextureFormat_ASTC8x5Unorm,
            WGPUTextureFormat_ASTC8x5UnormSrgb,
            WGPUTextureFormat_ASTC8x6Unorm,
            WGPUTextureFormat_ASTC8x6UnormSrgb,
            WGPUTextureFormat_ASTC8x8Unorm,
            WGPUTextureFormat_ASTC8x8UnormSrgb,
            WGPUTextureFormat_ASTC10x5Unorm,
            WGPUTextureFormat_ASTC10x5UnormSrgb,
            WGPUTextureFormat_ASTC10x6Unorm,
            WGPUTextureFormat_ASTC10x6UnormSrgb,
            WGPUTextureFormat_ASTC10x8Unorm,
            WGPUTextureFormat_ASTC10x8UnormSrgb,
            WGPUTextureFormat_ASTC10x10Unorm,
            WGPUTextureFormat_ASTC10x10UnormSrgb,
            WGPUTextureFormat_ASTC12x10Unorm,
            WGPUTextureFormat_ASTC12x10UnormSrgb,
            WGPUTextureFormat_ASTC12x12Unorm,
            WGPUTextureFormat_ASTC12x12UnormSrgb:
            return WGPUTextureFormat_Undefined
        case WGPUTextureFormat_Undefined:
            return WGPUTextureFormat_Undefined
        case WGPUTextureFormat_Force32:
            assertionFailure()
            return WGPUTextureFormat_Undefined
        default:
            return WGPUTextureFormat_Undefined
        }
    }

}
