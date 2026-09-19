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

import WebGPU_Internal.Device
import WebGPU_Private.WebGPU

/// The `WGPUTextureFormat` properties that depend on which features a device has
/// enabled.
///
/// Each member takes the feature flags it consults as `Bool` parameters, which is
/// what separates these from the tables on `TextureFormat`: those are functions of
/// the format alone. A format renderable on one device is not renderable on
/// another whose adapter declined the feature that grants it.
///
/// The flags arrive as values rather than as a `Device` to ask. `Device::hasFeature`
/// is a lookup in a set fixed at construction, so reading the flags before the
/// switch gives the same answers as reading them inside it, and the caller keeps
/// its `const Device&` — an exposed Swift member taking a `SWIFT_SHARED_REFERENCE`
/// type receives it as a non-const pointer, which a `const` caller can only supply
/// by casting the `const` away.
///
/// A class rather than a struct, and one nothing ever instantiates: `init` is
/// private, so the only way in is the static members.
@_expose(Cxx)
final class TextureFormatDeviceCapabilities {
    private init() {}

    /// Whether `format` may be used as a color attachment.
    ///
    /// https://gpuweb.github.io/gpuweb/#renderable-format
    static func isColorRenderableFormat(
        _ format: WGPUTextureFormat,
        hasTextureFormatsTier1: Bool,
        hasRG11B10UfloatRenderable: Bool
    ) -> Bool {
        switch format {
        case WGPUTextureFormat_R8Unorm,
            WGPUTextureFormat_R8Uint,
            WGPUTextureFormat_R8Sint,
            WGPUTextureFormat_R16Uint,
            WGPUTextureFormat_R16Sint,
            WGPUTextureFormat_R16Float,
            WGPUTextureFormat_RG8Unorm,
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
            WGPUTextureFormat_RGBA8Uint,
            WGPUTextureFormat_RGBA8Sint,
            WGPUTextureFormat_BGRA8Unorm,
            WGPUTextureFormat_BGRA8UnormSrgb,
            WGPUTextureFormat_RGB10A2Uint,
            WGPUTextureFormat_RGB10A2Unorm,
            WGPUTextureFormat_RG32Float,
            WGPUTextureFormat_RG32Uint,
            WGPUTextureFormat_RG32Sint,
            WGPUTextureFormat_RGBA16Uint,
            WGPUTextureFormat_RGBA16Sint,
            WGPUTextureFormat_RGBA16Float,
            WGPUTextureFormat_RGBA32Float,
            WGPUTextureFormat_RGBA32Uint,
            WGPUTextureFormat_RGBA32Sint:
            return true
        case WGPUTextureFormat_R16Unorm,
            WGPUTextureFormat_R16Snorm,
            WGPUTextureFormat_RG16Unorm,
            WGPUTextureFormat_RG16Snorm,
            WGPUTextureFormat_RGBA16Unorm,
            WGPUTextureFormat_RGBA16Snorm:
            return hasTextureFormatsTier1
        case WGPUTextureFormat_RG11B10Ufloat:
            return hasTextureFormatsTier1 || hasRG11B10UfloatRenderable
        case WGPUTextureFormat_Stencil8,
            WGPUTextureFormat_Depth16Unorm,
            WGPUTextureFormat_Depth24Plus,
            WGPUTextureFormat_Depth24PlusStencil8,
            WGPUTextureFormat_Depth32Float,
            WGPUTextureFormat_Depth32FloatStencil8:
            return false
        case WGPUTextureFormat_R8Snorm,
            WGPUTextureFormat_RG8Snorm,
            WGPUTextureFormat_RGBA8Snorm:
            return hasTextureFormatsTier1
        case WGPUTextureFormat_RGB9E5Ufloat,
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
            return false
        case WGPUTextureFormat_Undefined:
            return false
        case WGPUTextureFormat_Force32:
            assertionFailure()
            return false
        default:
            return false
        }
    }

    /// Whether `format` may be used as a depth-or-stencil attachment.
    ///
    /// https://gpuweb.github.io/gpuweb/#renderable-format
    static func isDepthStencilRenderableFormat(_ format: WGPUTextureFormat) -> Bool {
        switch format {
        case WGPUTextureFormat_R8Unorm,
            WGPUTextureFormat_R8Uint,
            WGPUTextureFormat_R8Sint,
            WGPUTextureFormat_R16Uint,
            WGPUTextureFormat_R16Sint,
            WGPUTextureFormat_R16Float,
            WGPUTextureFormat_RG8Unorm,
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
            WGPUTextureFormat_RGBA8Uint,
            WGPUTextureFormat_RGBA8Sint,
            WGPUTextureFormat_BGRA8Unorm,
            WGPUTextureFormat_BGRA8UnormSrgb,
            WGPUTextureFormat_RGB10A2Uint,
            WGPUTextureFormat_RGB10A2Unorm,
            WGPUTextureFormat_RG32Float,
            WGPUTextureFormat_RG32Uint,
            WGPUTextureFormat_RG32Sint,
            WGPUTextureFormat_RGBA16Uint,
            WGPUTextureFormat_RGBA16Sint,
            WGPUTextureFormat_RGBA16Float,
            WGPUTextureFormat_RGBA32Float,
            WGPUTextureFormat_RGBA32Uint,
            WGPUTextureFormat_RGBA32Sint,
            WGPUTextureFormat_RG11B10Ufloat,
            WGPUTextureFormat_R16Unorm,
            WGPUTextureFormat_R16Snorm,
            WGPUTextureFormat_RG16Unorm,
            WGPUTextureFormat_RG16Snorm,
            WGPUTextureFormat_RGBA16Unorm,
            WGPUTextureFormat_RGBA16Snorm:
            return false
        case WGPUTextureFormat_Stencil8,
            WGPUTextureFormat_Depth16Unorm,
            WGPUTextureFormat_Depth24Plus,
            WGPUTextureFormat_Depth24PlusStencil8,
            WGPUTextureFormat_Depth32Float,
            WGPUTextureFormat_Depth32FloatStencil8:
            return true
        case WGPUTextureFormat_R8Snorm,
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
            return false
        case WGPUTextureFormat_Undefined:
            return false
        case WGPUTextureFormat_Force32:
            assertionFailure()
            return false
        default:
            return false
        }
    }

    /// Whether `format` may be used as a render attachment of either kind.
    ///
    /// https://gpuweb.github.io/gpuweb/#renderable-format
    static func isRenderableFormat(_ format: WGPUTextureFormat, hasTextureFormatsTier1: Bool, hasRG11B10UfloatRenderable: Bool) -> Bool {
        switch format {
        case WGPUTextureFormat_R8Unorm,
            WGPUTextureFormat_R8Uint,
            WGPUTextureFormat_R8Sint,
            WGPUTextureFormat_R16Uint,
            WGPUTextureFormat_R16Sint,
            WGPUTextureFormat_R16Float,
            WGPUTextureFormat_RG8Unorm,
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
            WGPUTextureFormat_RGBA8Uint,
            WGPUTextureFormat_RGBA8Sint,
            WGPUTextureFormat_BGRA8Unorm,
            WGPUTextureFormat_BGRA8UnormSrgb,
            WGPUTextureFormat_RGB10A2Uint,
            WGPUTextureFormat_RGB10A2Unorm,
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
            return true
        case WGPUTextureFormat_R16Unorm,
            WGPUTextureFormat_R16Snorm,
            WGPUTextureFormat_RG16Unorm,
            WGPUTextureFormat_RG16Snorm,
            WGPUTextureFormat_RGBA16Unorm,
            WGPUTextureFormat_RGBA16Snorm,
            WGPUTextureFormat_R8Snorm,
            WGPUTextureFormat_RG8Snorm,
            WGPUTextureFormat_RGBA8Snorm:
            return hasTextureFormatsTier1
        case WGPUTextureFormat_RG11B10Ufloat:
            return hasTextureFormatsTier1 || hasRG11B10UfloatRenderable
        case WGPUTextureFormat_RGB9E5Ufloat,
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
            return false
        case WGPUTextureFormat_Undefined:
            return false
        case WGPUTextureFormat_Force32:
            assertionFailure()
            return false
        default:
            return false
        }
    }

    /// Whether a texture of `format` may have more than one sample per pixel.
    ///
    /// https://gpuweb.github.io/gpuweb/#texture-format-caps
    static func supportsMultisampling(_ format: WGPUTextureFormat, hasTextureFormatsTier1: Bool, hasRG11B10UfloatRenderable: Bool) -> Bool {
        switch format {
        // https://gpuweb.github.io/gpuweb/#texture-format-caps
        case WGPUTextureFormat_R8Unorm,
            WGPUTextureFormat_R8Uint,
            WGPUTextureFormat_R8Sint,
            WGPUTextureFormat_R16Uint,
            WGPUTextureFormat_R16Sint,
            WGPUTextureFormat_R16Float,
            WGPUTextureFormat_RG8Unorm,
            WGPUTextureFormat_RG8Uint,
            WGPUTextureFormat_RG8Sint,
            WGPUTextureFormat_R32Float,
            WGPUTextureFormat_RG16Uint,
            WGPUTextureFormat_RG16Sint,
            WGPUTextureFormat_RG16Float,
            WGPUTextureFormat_RGBA8Unorm,
            WGPUTextureFormat_RGBA8UnormSrgb,
            WGPUTextureFormat_RGBA8Uint,
            WGPUTextureFormat_RGBA8Sint,
            WGPUTextureFormat_BGRA8Unorm,
            WGPUTextureFormat_BGRA8UnormSrgb,
            WGPUTextureFormat_RGB10A2Unorm,
            WGPUTextureFormat_RGB10A2Uint,
            WGPUTextureFormat_RGBA16Uint,
            WGPUTextureFormat_RGBA16Sint,
            WGPUTextureFormat_RGBA16Float,
            // https://gpuweb.github.io/gpuweb/#depth-formats
            WGPUTextureFormat_Stencil8,
            WGPUTextureFormat_Depth16Unorm,
            WGPUTextureFormat_Depth24Plus,
            WGPUTextureFormat_Depth24PlusStencil8,
            WGPUTextureFormat_Depth32Float,
            WGPUTextureFormat_Depth32FloatStencil8:
            return true
        case WGPUTextureFormat_R8Snorm,
            WGPUTextureFormat_RG8Snorm,
            WGPUTextureFormat_RGBA8Snorm:
            return hasTextureFormatsTier1
        case WGPUTextureFormat_R16Unorm,
            WGPUTextureFormat_R16Snorm,
            WGPUTextureFormat_RG16Unorm,
            WGPUTextureFormat_RG16Snorm,
            WGPUTextureFormat_RGBA16Unorm,
            WGPUTextureFormat_RGBA16Snorm:
            return hasTextureFormatsTier1
        case WGPUTextureFormat_RG11B10Ufloat:
            return hasTextureFormatsTier1 || hasRG11B10UfloatRenderable
        case WGPUTextureFormat_R32Uint,
            WGPUTextureFormat_R32Sint,
            WGPUTextureFormat_RG32Float,
            WGPUTextureFormat_RG32Uint,
            WGPUTextureFormat_RG32Sint,
            WGPUTextureFormat_RGBA32Float,
            WGPUTextureFormat_RGBA32Uint,
            WGPUTextureFormat_RGBA32Sint,
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
            return false
        case WGPUTextureFormat_Undefined:
            return false
        case WGPUTextureFormat_Force32:
            assertionFailure()
            return false
        default:
            return false
        }
    }

    /// Whether a multisampled texture of `format` may be resolved.
    ///
    /// https://gpuweb.github.io/gpuweb/#texture-format-caps
    static func supportsResolve(_ format: WGPUTextureFormat, hasTextureFormatsTier1: Bool, hasRG11B10UfloatRenderable: Bool) -> Bool {
        switch format {
        case WGPUTextureFormat_R8Unorm,
            WGPUTextureFormat_R16Float,
            WGPUTextureFormat_RG8Unorm,
            WGPUTextureFormat_RG16Float,
            WGPUTextureFormat_RGBA8Unorm,
            WGPUTextureFormat_RGBA8UnormSrgb,
            WGPUTextureFormat_BGRA8Unorm,
            WGPUTextureFormat_BGRA8UnormSrgb,
            WGPUTextureFormat_RGB10A2Unorm,
            WGPUTextureFormat_RGBA16Float:
            return true
        case WGPUTextureFormat_R16Unorm,
            WGPUTextureFormat_R16Snorm,
            WGPUTextureFormat_RG16Unorm,
            WGPUTextureFormat_RG16Snorm,
            WGPUTextureFormat_RGBA16Unorm,
            WGPUTextureFormat_RGBA16Snorm:
            return false
        case WGPUTextureFormat_R8Snorm,
            WGPUTextureFormat_RG8Snorm,
            WGPUTextureFormat_RGBA8Snorm:
            return hasTextureFormatsTier1
        case WGPUTextureFormat_RG11B10Ufloat:
            return hasTextureFormatsTier1 || hasRG11B10UfloatRenderable
        case WGPUTextureFormat_R32Float,
            WGPUTextureFormat_Stencil8,
            WGPUTextureFormat_Depth16Unorm,
            WGPUTextureFormat_Depth24Plus,
            WGPUTextureFormat_Depth24PlusStencil8,
            WGPUTextureFormat_Depth32Float,
            WGPUTextureFormat_Depth32FloatStencil8,
            WGPUTextureFormat_R8Uint,
            WGPUTextureFormat_R8Sint,
            WGPUTextureFormat_R16Uint,
            WGPUTextureFormat_R16Sint,
            WGPUTextureFormat_RG8Uint,
            WGPUTextureFormat_RG8Sint,
            WGPUTextureFormat_RG16Uint,
            WGPUTextureFormat_RG16Sint,
            WGPUTextureFormat_RGBA8Uint,
            WGPUTextureFormat_RGBA8Sint,
            WGPUTextureFormat_RGB10A2Uint,
            WGPUTextureFormat_RGBA16Uint,
            WGPUTextureFormat_RGBA16Sint,
            WGPUTextureFormat_R32Uint,
            WGPUTextureFormat_R32Sint,
            WGPUTextureFormat_RG32Float,
            WGPUTextureFormat_RG32Uint,
            WGPUTextureFormat_RG32Sint,
            WGPUTextureFormat_RGBA32Float,
            WGPUTextureFormat_RGBA32Uint,
            WGPUTextureFormat_RGBA32Sint,
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
            return false
        case WGPUTextureFormat_Undefined:
            return false
        case WGPUTextureFormat_Force32:
            preconditionFailure()
        default:
            return false
        }
    }

    /// Whether a color attachment of `format` may have blending enabled.
    ///
    /// https://gpuweb.github.io/gpuweb/#texture-format-caps
    static func supportsBlending(
        _ format: WGPUTextureFormat,
        hasTextureFormatsTier1: Bool,
        hasRG11B10UfloatRenderable: Bool,
        hasFloat32Blendable: Bool
    ) -> Bool {
        switch format {
        // https://gpuweb.github.io/gpuweb/#texture-format-caps
        case WGPUTextureFormat_R8Unorm,
            WGPUTextureFormat_RG8Unorm,
            WGPUTextureFormat_RGBA8Unorm,
            WGPUTextureFormat_RGBA8UnormSrgb,
            WGPUTextureFormat_BGRA8Unorm,
            WGPUTextureFormat_BGRA8UnormSrgb,
            WGPUTextureFormat_R16Float,
            WGPUTextureFormat_RG16Float,
            WGPUTextureFormat_RGBA16Float,
            WGPUTextureFormat_RGB10A2Unorm:
            return true
        case WGPUTextureFormat_R16Unorm,
            WGPUTextureFormat_R16Snorm,
            WGPUTextureFormat_RG16Unorm,
            WGPUTextureFormat_RG16Snorm,
            WGPUTextureFormat_RGBA16Unorm,
            WGPUTextureFormat_RGBA16Snorm:
            return hasTextureFormatsTier1
        case WGPUTextureFormat_RG11B10Ufloat:
            return hasTextureFormatsTier1 || hasRG11B10UfloatRenderable
        case WGPUTextureFormat_R32Float,
            WGPUTextureFormat_RG32Float,
            WGPUTextureFormat_RGBA32Float:
            return hasFloat32Blendable
        case WGPUTextureFormat_R8Snorm,
            WGPUTextureFormat_RG8Snorm,
            WGPUTextureFormat_RGBA8Snorm:
            return hasTextureFormatsTier1
        case WGPUTextureFormat_R8Uint,
            WGPUTextureFormat_R8Sint,
            WGPUTextureFormat_R16Uint,
            WGPUTextureFormat_R16Sint,
            WGPUTextureFormat_RG8Uint,
            WGPUTextureFormat_RG8Sint,
            WGPUTextureFormat_RG16Uint,
            WGPUTextureFormat_RG16Sint,
            WGPUTextureFormat_RGBA8Uint,
            WGPUTextureFormat_RGBA8Sint,
            WGPUTextureFormat_RGB10A2Uint,
            WGPUTextureFormat_RGBA16Uint,
            WGPUTextureFormat_RGBA16Sint,
            WGPUTextureFormat_Stencil8,
            WGPUTextureFormat_Depth16Unorm,
            WGPUTextureFormat_Depth24Plus,
            WGPUTextureFormat_Depth24PlusStencil8,
            WGPUTextureFormat_Depth32Float,
            WGPUTextureFormat_Depth32FloatStencil8,
            WGPUTextureFormat_R32Uint,
            WGPUTextureFormat_R32Sint,
            WGPUTextureFormat_RG32Uint,
            WGPUTextureFormat_RG32Sint,
            WGPUTextureFormat_RGBA32Uint,
            WGPUTextureFormat_RGBA32Sint,
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
            return false
        case WGPUTextureFormat_Undefined:
            return false
        case WGPUTextureFormat_Force32:
            assertionFailure()
            return false
        default:
            return false
        }
    }

    /// Whether `format` may back a storage binding used with `access`.
    ///
    /// `WGPUStorageTextureAccess_Undefined` asks whether the format supports a
    /// storage binding under any access, which is what the C++ arm spells as a
    /// `std::nullopt` access.
    ///
    /// https://gpuweb.github.io/gpuweb/#plain-color-formats
    static func hasStorageBindingCapability(
        _ format: WGPUTextureFormat,
        _ access: WGPUStorageTextureAccess,
        hasTextureFormatsTier1: Bool,
        hasTextureFormatsTier2: Bool,
        hasBGRA8UnormStorage: Bool
    ) -> Bool {
        switch format {
        // These formats always support read-only and write-only storage access;
        // texture-formats-tier2 additionally grants read-write storage access.
        case WGPUTextureFormat_RGBA8Unorm,
            WGPUTextureFormat_RGBA8Uint,
            WGPUTextureFormat_RGBA8Sint,
            WGPUTextureFormat_RGBA16Uint,
            WGPUTextureFormat_RGBA16Sint,
            WGPUTextureFormat_RGBA16Float,
            WGPUTextureFormat_RGBA32Float,
            WGPUTextureFormat_RGBA32Uint,
            WGPUTextureFormat_RGBA32Sint:
            return (access == WGPUStorageTextureAccess_Undefined || access != WGPUStorageTextureAccess_ReadWrite)
                || hasTextureFormatsTier2
        case WGPUTextureFormat_RGBA8Snorm,
            WGPUTextureFormat_RG32Float,
            WGPUTextureFormat_RG32Uint,
            WGPUTextureFormat_RG32Sint:
            return access == WGPUStorageTextureAccess_Undefined || access != WGPUStorageTextureAccess_ReadWrite
        case WGPUTextureFormat_BGRA8Unorm:
            return (access == WGPUStorageTextureAccess_Undefined || access == WGPUStorageTextureAccess_WriteOnly)
                && hasBGRA8UnormStorage
        case WGPUTextureFormat_R32Float,
            WGPUTextureFormat_R32Uint,
            WGPUTextureFormat_R32Sint:
            return true
        // These formats support storage access only with texture-formats-tier1;
        // texture-formats-tier2 additionally grants read-write storage access.
        case WGPUTextureFormat_R8Unorm,
            WGPUTextureFormat_R8Uint,
            WGPUTextureFormat_R8Sint,
            WGPUTextureFormat_R16Float,
            WGPUTextureFormat_R16Uint,
            WGPUTextureFormat_R16Sint:
            return
                ((access == WGPUStorageTextureAccess_Undefined || access != WGPUStorageTextureAccess_ReadWrite)
                || hasTextureFormatsTier2)
                && hasTextureFormatsTier1
        case WGPUTextureFormat_R8Snorm,
            WGPUTextureFormat_RG8Unorm,
            WGPUTextureFormat_RG8Snorm,
            WGPUTextureFormat_RG8Uint,
            WGPUTextureFormat_RG8Sint,
            WGPUTextureFormat_R16Unorm,
            WGPUTextureFormat_R16Snorm,
            WGPUTextureFormat_RG16Uint,
            WGPUTextureFormat_RG16Sint,
            WGPUTextureFormat_RG16Unorm,
            WGPUTextureFormat_RG16Snorm,
            WGPUTextureFormat_RGBA16Unorm,
            WGPUTextureFormat_RGBA16Snorm,
            WGPUTextureFormat_RGB10A2Uint,
            WGPUTextureFormat_RGB10A2Unorm,
            WGPUTextureFormat_RG11B10Ufloat,
            WGPUTextureFormat_RG16Float:
            return (access == WGPUStorageTextureAccess_Undefined || access != WGPUStorageTextureAccess_ReadWrite)
                && hasTextureFormatsTier1
        case WGPUTextureFormat_RGBA8UnormSrgb,
            WGPUTextureFormat_BGRA8UnormSrgb,
            WGPUTextureFormat_RGB9E5Ufloat,
            WGPUTextureFormat_Stencil8,
            WGPUTextureFormat_Depth16Unorm,
            WGPUTextureFormat_Depth24Plus,
            WGPUTextureFormat_Depth24PlusStencil8,
            WGPUTextureFormat_Depth32Float,
            WGPUTextureFormat_Depth32FloatStencil8,
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
            return false
        case WGPUTextureFormat_Undefined:
            return false
        case WGPUTextureFormat_Force32:
            assertionFailure()
            return false
        default:
            return false
        }
    }
}
