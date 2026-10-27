/*
 * Copyright (C) 2026 Apple Inc. All rights reserved.
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

#import "config.h"

#if USE(CG)

#import "Helpers/Test.h"
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <WebCore/ImageDecoder.h>
#import <WebCore/SharedBuffer.h>
#import <cstdio>
#import <cstdlib>
#import <wtf/MonotonicTime.h>
#import <wtf/RetainPtr.h>
#import <wtf/text/WTFString.h>

// Cost of ImageDecoder (ImageDecoderCG on Cocoa) on whole encoded images, one TEST per kind of image. Each
// iteration creates a decoder over the data, asks for the status, size, frame count, repetition count, UTI and
// hot spot, then each frame's size, duration, orientation, alpha and completeness, and (except in the
// *Properties shapes) decodes each frame. The images are encoded in the test with ImageIO. By default each TEST
// runs once and checks the checksum. With WEBKIT_RUN_BENCHMARKS=1 it repeats for about a second and prints
// "<Name>: <ms> ms <iterations/s> it/s checksum=<hex>". Nothing asserts on time.

namespace TestWebKitAPI {

using namespace WebCore;

namespace {

struct Checksum {
    uint64_t value { 1469598103934665603ull };

    void add(uint64_t word)
    {
        for (unsigned i = 0; i < 8; ++i) {
            value ^= (word >> (8 * i)) & 0xff;
            value *= 1099511628211ull;
        }
    }
};

struct Encoded {
    Vector<uint8_t> bytes;
    ASCIILiteral mimeType;
};

}

static RetainPtr<CGImageRef> makeImage(unsigned size, unsigned seed, bool alpha)
{
    auto colorSpace = adoptCF(CGColorSpaceCreateDeviceRGB());
    auto context = adoptCF(CGBitmapContextCreate(nullptr, size, size, 8, 0, colorSpace.get(), alpha ? kCGImageAlphaPremultipliedLast : kCGImageAlphaNoneSkipLast));
    for (unsigned y = 0; y < size; y += 8) {
        for (unsigned x = 0; x < size; x += 8) {
            unsigned v = (x * 7 + y * 13 + seed * 31) & 0xff;
            CGContextSetRGBFillColor(context.get(), v / 255.0, ((v * 3) & 0xff) / 255.0, ((v * 5) & 0xff) / 255.0, alpha ? ((v | 0x40) / 255.0) : 1);
            CGContextFillRect(context.get(), CGRectMake(x, y, 8, 8));
        }
    }
    return adoptCF(CGBitmapContextCreateImage(context.get()));
}

static std::optional<Encoded> encode(CFStringRef type, ASCIILiteral mimeType, unsigned size, unsigned frames, bool alpha)
{
    auto data = adoptCF(CFDataCreateMutable(kCFAllocatorDefault, 0));
    auto destination = adoptCF(CGImageDestinationCreateWithData(data.get(), type, frames, nullptr));
    if (!destination)
        return std::nullopt;
    if (frames > 1) {
        NSDictionary *fileProperties = @{ (id)kCGImagePropertyGIFDictionary: @{ (id)kCGImagePropertyGIFLoopCount: @0 } };
        CGImageDestinationSetProperties(destination.get(), (CFDictionaryRef)fileProperties);
    }
    for (unsigned i = 0; i < frames; ++i) {
        auto image = makeImage(size, i, alpha);
        NSDictionary *frameProperties = frames > 1 ? @{ (id)kCGImagePropertyGIFDictionary: @{ (id)kCGImagePropertyGIFDelayTime: @0.05 } } : @{ };
        CGImageDestinationAddImage(destination.get(), image.get(), (CFDictionaryRef)frameProperties);
    }
    if (!CGImageDestinationFinalize(destination.get()))
        return std::nullopt;
    auto span = std::span { CFDataGetBytePtr(data.get()), static_cast<size_t>(CFDataGetLength(data.get())) };
    return Encoded { Vector<uint8_t> { span }, mimeType };
}

static uint64_t runOnce(const Encoded& encoded, bool decodeFrames)
{
    Checksum checksum;
    Ref buffer = SharedBuffer::create(encoded.bytes.span());
    RefPtr decoder = ImageDecoder::create(buffer.get(), String { encoded.mimeType }, AlphaOption::Premultiplied, GammaAndColorProfileOption::Applied);
    if (!decoder)
        return 0;
    decoder->setData(buffer.get(), true);
    checksum.add(static_cast<uint64_t>(decoder->encodedDataStatus()));
    auto size = decoder->size();
    checksum.add(size.width());
    checksum.add(size.height());
    size_t frameCount = decoder->frameCount();
    checksum.add(frameCount);
    checksum.add(static_cast<uint64_t>(decoder->repetitionCount()));
    checksum.add(decoder->uti().length());
    checksum.add(decoder->hotSpot() ? 1 : 0);
    for (size_t i = 0; i < frameCount; ++i) {
        auto frameSize = decoder->frameSizeAtIndex(i);
        checksum.add(frameSize.width());
        checksum.add(frameSize.height());
        checksum.add(static_cast<uint64_t>(decoder->frameDurationAtIndex(i).milliseconds() * 1000));
        checksum.add(static_cast<uint64_t>(decoder->frameOrientationAtIndex(i).orientation()));
        checksum.add(decoder->frameHasAlphaAtIndex(i));
        checksum.add(decoder->frameIsCompleteAtIndex(i));
        if (decodeFrames) {
            auto image = decoder->createFrameImageAtIndex(i);
            checksum.add(image ? CGImageGetWidth(image.get()) * 65536 + CGImageGetHeight(image.get()) : 0);
        }
    }
    return checksum.value;
}

static void runBenchmark(const char* name, const std::optional<Encoded>& encoded, bool decodeFrames)
{
    if (!encoded) {
        printf("%s: skipped (the SDK cannot encode it)\n", name);
        return;
    }
    uint64_t expected = runOnce(*encoded, decodeFrames);
    EXPECT_NE(expected, 0u);
    if (!getenv("WEBKIT_RUN_BENCHMARKS"))
        return;
    unsigned iterations = 0;
    auto start = MonotonicTime::now();
    Seconds elapsed;
    do {
        for (unsigned i = 0; i < 50; ++i)
            EXPECT_EQ(runOnce(*encoded, decodeFrames), expected);
        iterations += 50;
        elapsed = MonotonicTime::now() - start;
    } while (elapsed < 1_s);
    printf("%s: %.1f ms %.0f it/s checksum=%016llx\n", name, elapsed.milliseconds(), iterations / elapsed.seconds(), static_cast<unsigned long long>(expected));
}

TEST(ImageDecoderCGBench, PNG)
{
    runBenchmark("PNG", encode(CFSTR("public.png"), "image/png"_s, 64, 1, true), true);
}

TEST(ImageDecoderCGBench, JPEG)
{
    runBenchmark("JPEG", encode(CFSTR("public.jpeg"), "image/jpeg"_s, 64, 1, false), true);
}

TEST(ImageDecoderCGBench, GIF)
{
    runBenchmark("GIF", encode(CFSTR("com.compuserve.gif"), "image/gif"_s, 64, 1, false), true);
}

TEST(ImageDecoderCGBench, AnimatedGIF)
{
    runBenchmark("AnimatedGIF", encode(CFSTR("com.compuserve.gif"), "image/gif"_s, 64, 8, false), true);
}

TEST(ImageDecoderCGBench, AnimatedGIFProperties)
{
    runBenchmark("AnimatedGIFProperties", encode(CFSTR("com.compuserve.gif"), "image/gif"_s, 64, 8, false), false);
}

TEST(ImageDecoderCGBench, HEIF)
{
    runBenchmark("HEIF", encode(CFSTR("public.heic"), "image/heic"_s, 64, 1, false), true);
}

} // namespace TestWebKitAPI

#endif // USE(CG)
