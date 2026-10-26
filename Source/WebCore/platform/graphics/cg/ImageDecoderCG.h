/*
 * Copyright (C) 2016-2024 Apple Inc. All rights reserved.
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
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#pragma once

#include <WebCore/ImageDecoder.h>
#include <atomic>
#include <wtf/TZoneMalloc.h>

#if USE(CG)

namespace WebCore {

class SharedBuffer;
#if ENABLE(IMAGE_DECODER_CG_SWIFT)
class AnyCGImageDecoder; // Swift (ImageDecodingCG.swift); complete only in ImageDecoderCG.cpp.
#endif

class ImageDecoderCG final : public ImageDecoder {
    WTF_MAKE_TZONE_ALLOCATED(ImageDecoderCG);
public:
    ImageDecoderCG(FragmentedSharedBuffer& data, AlphaOption, GammaAndColorProfileOption);
#if ENABLE(IMAGE_DECODER_CG_SWIFT)
    ~ImageDecoderCG();
#endif

    static Ref<ImageDecoderCG> create(FragmentedSharedBuffer& data, AlphaOption alphaOption, GammaAndColorProfileOption gammaAndColorProfileOption)
    {
        return adoptRef(*new ImageDecoderCG(data, alphaOption, gammaAndColorProfileOption));
    }

    static bool supportsMediaType(MediaType type) { return type == MediaType::Image; }
    static bool canDecodeType(const String&);

    size_t bytesDecodedToDetermineProperties() const final;

    EncodedDataStatus encodedDataStatus() const final;
    bool hasHDRGainMap() const final;
    IntSize size() const final { return IntSize(); }
    size_t frameCount() const final;
    size_t primaryFrameIndex() const final;
    RepetitionCount repetitionCount() const final;
#if ENABLE(IMAGE_DECODER_CG_SWIFT)
    String uti() const final;
#else
    String uti() const final { return m_uti; }
#endif
    String filenameExtension() const final;
    String accessibilityDescription() const final;
    std::optional<IntPoint> hotSpot() const final;

    IntSize frameSizeAtIndex(size_t, SubsamplingLevel = SubsamplingLevel::Default) const final;
    FloatSize frameDensityAtIndex(size_t) const final;
    bool frameIsCompleteAtIndex(size_t) const final;
    ImageOrientation frameOrientationAtIndex(size_t) const final;
    std::optional<IntSize> frameDensityCorrectedSizeAtIndex(size_t) const final;

    Seconds frameDurationAtIndex(size_t) const final;
    bool frameHasAlphaAtIndex(size_t) const final;

    bool fetchFrameMetaDataAtIndex(size_t, SubsamplingLevel, const DecodingOptions&, ImageFrame&) const final;

    std::optional<GainMap> frameGainMapAtIndex(size_t, const DecodingOptions&) final;
    PlatformImagePtr createFrameImageAtIndex(size_t, SubsamplingLevel = SubsamplingLevel::Default, const DecodingOptions& = DecodingOptions(DecodingMode::Synchronous)) final;

    void setData(const FragmentedSharedBuffer&, bool allDataReceived) final;
#if ENABLE(IMAGE_DECODER_CG_SWIFT)
    bool isAllDataReceived() const final;
#else
    bool isAllDataReceived() const final { return m_isAllDataReceived; }
#endif
    void clearFrameBufferCache(size_t) final { }

    static String decodeUTI(CGImageSourceRef, const SharedBuffer&);

private:
    bool hasAlpha() const;
    String decodeUTI(const SharedBuffer&) const;

#if ENABLE(QUICKLOOK_FULLSCREEN)
    bool isMaybePanoramic() const;
    bool isPanorama() const;
#endif

#if ENABLE(SPATIAL_IMAGE_DETECTION)
    bool isSpatial() const;
    std::optional<unsigned> spatialEyeFrameIndex(const CFStringRef) const;
    std::optional<unsigned> spatialLeftEyeFrameIndex() const;
    std::optional<unsigned> spatialRightEyeFrameIndex() const;
    std::optional<SpatialImageEyeProperties> spatialEyePropertiesAtIndex(unsigned) const;
#endif

#if !ENABLE(IMAGE_DECODER_CG_SWIFT)
    bool m_isAllDataReceived { false };
#endif
    std::atomic<bool> m_isXBitmapImage { false };
#if ENABLE(IMAGE_DECODER_CG_SWIFT)
    // Owns the data, UTI and encoded-data status; shares m_nativeDecoder (see ImageDecoderCG.cpp).
    const std::unique_ptr<AnyCGImageDecoder> m_swiftDecoder;
#else
    mutable EncodedDataStatus m_encodedDataStatus { EncodedDataStatus::Unknown };
    String m_uti;
#endif
    const RetainPtr<CGImageSourceRef> m_nativeDecoder;
};

} // namespace WebCore

#endif // USE(CG)
