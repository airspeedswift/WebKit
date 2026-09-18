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

// Throughput for TextCodecUTF8::decode, across input shapes.
//
// Build twice against the same source, once with WK_USE_SWIFT_TEXT_CODEC_UTF8=YES and once without,
// since the decoder is selected at compile time. Run both with:
//
//     TestWebKitAPI --gtest_filter=TextCodecUTF8Bench.*
//
// and divide one build's MB/s by the other's, band by band.
//
// Each generator produces a deterministic 8 MiB buffer, decoded in 16 KiB chunks. Only a period
// coprime with the chunk size puts multi-byte sequences across chunk boundaries and so exercises
// partial sequences at all; mixed-234 is the band that does, at period 9.

#include "config.h"

#include <algorithm>
#include <pal/text/TextCodec.h>
#include <pal/text/TextEncoding.h>
#include <pal/text/TextEncodingRegistry.h>
#include <wtf/DataLog.h>
#include <wtf/MonotonicTime.h>
#include <wtf/Vector.h>
#include <wtf/text/WTFString.h>

namespace TestWebKitAPI {

static constexpr size_t bufferBytes = 8 * 1024 * 1024;
static constexpr size_t chunkBytes = 16 * 1024;
static constexpr unsigned iterations = 20;

// Pure ASCII cycling through printable characters 0x20..0x7E.
static Vector<uint8_t> makeASCII(size_t bytes)
{
    Vector<uint8_t> data;
    data.reserveInitialCapacity(bytes);
    for (size_t i = 0; i < bytes; ++i)
        data.append(static_cast<uint8_t>(0x20 + (i % 0x5F)));
    return data;
}

// Pure 2-byte Latin-1: U+0080..U+00FF encoded as 0xC2/0xC3 sequences.
// Output stays in the 8-bit StringBuffer throughout, never flipping to 16-bit.
static Vector<uint8_t> makeLatin1Only(size_t bytes)
{
    Vector<uint8_t> data;
    data.reserveInitialCapacity(bytes);
    for (size_t i = 0; data.size() + 2 <= bytes; ++i) {
        uint32_t cp = 0x80 + (i % 0x80); // U+0080..U+00FF
        data.append(static_cast<uint8_t>(0xC0 | (cp >> 6)));
        data.append(static_cast<uint8_t>(0x80 | (cp & 0x3F)));
    }
    return data;
}

// 64 ASCII bytes + one 2-byte Latin-1 sequence. Period 66, and GCD(16384, 66) = 2, so sequences do
// not straddle chunk boundaries.
static Vector<uint8_t> makeLatin1P66(size_t bytes)
{
    Vector<uint8_t> data;
    data.reserveInitialCapacity(bytes);
    for (size_t cycle = 0; data.size() < bytes; ++cycle) {
        for (int j = 0; j < 64 && data.size() < bytes; ++j)
            data.append(static_cast<uint8_t>(0x20 + ((cycle * 64 + j) % 0x5F)));
        if (data.size() + 2 <= bytes) {
            uint32_t cp = 0xA0 + (cycle % 0x20); // U+00A0..U+00BF
            data.append(static_cast<uint8_t>(0xC0 | (cp >> 6)));
            data.append(static_cast<uint8_t>(0x80 | (cp & 0x3F)));
        }
    }
    return data;
}

// 198 ASCII bytes + one 2-byte Latin-1 sequence. Period 200, GCD(16384, 200) = 8, so again no
// straddling.
static Vector<uint8_t> makeLatin1P200(size_t bytes)
{
    Vector<uint8_t> data;
    data.reserveInitialCapacity(bytes);
    for (size_t cycle = 0; data.size() < bytes; ++cycle) {
        for (int j = 0; j < 198 && data.size() < bytes; ++j)
            data.append(static_cast<uint8_t>(0x20 + ((cycle * 198 + j) % 0x5F)));
        if (data.size() + 2 <= bytes) {
            uint32_t cp = 0xA0 + (cycle % 0x20);
            data.append(static_cast<uint8_t>(0xC0 | (cp >> 6)));
            data.append(static_cast<uint8_t>(0x80 | (cp & 0x3F)));
        }
    }
    return data;
}

// All 2-byte sequences, cycling through the whole lead-byte range 0xC2..0xDF (U+0080..U+07FF): the
// 8-bit path until the first character above U+00FF (lead 0xC4), 16-bit after.
static Vector<uint8_t> makeNonASCIIOnly(size_t bytes)
{
    Vector<uint8_t> data;
    data.reserveInitialCapacity(bytes);
    for (size_t i = 0; data.size() + 2 <= bytes; ++i) {
        // 30 lead values * 64 continuations = 1920 sequences per sweep.
        uint8_t lead = static_cast<uint8_t>(0xC2 + ((i / 64) % 30));
        uint8_t cont = static_cast<uint8_t>(0x80 + (i % 64));
        data.append(lead);
        data.append(cont);
    }
    return data;
}

// Only 2-byte sequences above Latin-1: lead bytes 0xC4..0xDF (U+0100..U+07FF).
// Output is 16-bit from the first character.
static Vector<uint8_t> makeTwobyteWideOnly(size_t bytes)
{
    Vector<uint8_t> data;
    data.reserveInitialCapacity(bytes);
    for (size_t i = 0; data.size() + 2 <= bytes; ++i) {
        uint8_t lead = static_cast<uint8_t>(0xC4 + ((i / 64) % 28)); // 0xC4..0xDF
        uint8_t cont = static_cast<uint8_t>(0x80 + (i % 64));
        data.append(lead);
        data.append(cont);
    }
    return data;
}

// All 4-byte sequences cycling through U+10000..U+13FFF.
// Each character produces a surrogate pair; output is always 16-bit.
static Vector<uint8_t> makeFourbyteOnly(size_t bytes)
{
    Vector<uint8_t> data;
    data.reserveInitialCapacity(bytes);
    for (size_t i = 0; data.size() + 4 <= bytes; ++i) {
        uint32_t cp = 0x10000 + (i % 0x4000);
        data.append(static_cast<uint8_t>(0xF0 | ((cp >> 18) & 0x07)));
        data.append(static_cast<uint8_t>(0x80 | ((cp >> 12) & 0x3F)));
        data.append(static_cast<uint8_t>(0x80 | ((cp >> 6)  & 0x3F)));
        data.append(static_cast<uint8_t>(0x80 | ( cp        & 0x3F)));
    }
    return data;
}

// 63 ASCII bytes + one 3-byte CJK character (U+4E00..U+4E3F). Period 66, no straddling.
static Vector<uint8_t> makeCJKP66(size_t bytes)
{
    Vector<uint8_t> data;
    data.reserveInitialCapacity(bytes);
    for (size_t cycle = 0; data.size() < bytes; ++cycle) {
        for (int j = 0; j < 63 && data.size() < bytes; ++j)
            data.append(static_cast<uint8_t>(0x20 + ((cycle * 63 + j) % 0x5F)));
        if (data.size() + 3 <= bytes) {
            uint32_t cp = 0x4E00 + (cycle % 0x40);
            data.append(static_cast<uint8_t>(0xE0 | ( cp >> 12)));
            data.append(static_cast<uint8_t>(0x80 | ((cp >> 6) & 0x3F)));
            data.append(static_cast<uint8_t>(0x80 | ( cp       & 0x3F)));
        }
    }
    return data;
}

// 197 ASCII bytes + one 3-byte CJK character. Period 200, no straddling.
static Vector<uint8_t> makeCJKP200(size_t bytes)
{
    Vector<uint8_t> data;
    data.reserveInitialCapacity(bytes);
    for (size_t cycle = 0; data.size() < bytes; ++cycle) {
        for (int j = 0; j < 197 && data.size() < bytes; ++j)
            data.append(static_cast<uint8_t>(0x20 + ((cycle * 197 + j) % 0x5F)));
        if (data.size() + 3 <= bytes) {
            uint32_t cp = 0x4E00 + (cycle % 0x40);
            data.append(static_cast<uint8_t>(0xE0 | ( cp >> 12)));
            data.append(static_cast<uint8_t>(0x80 | ((cp >> 6) & 0x3F)));
            data.append(static_cast<uint8_t>(0x80 | ( cp       & 0x3F)));
        }
    }
    return data;
}

// 196 ASCII bytes + one 4-byte emoji (U+1F600..U+1F63F). Period 200, no straddling.
static Vector<uint8_t> makeEmojiP200(size_t bytes)
{
    Vector<uint8_t> data;
    data.reserveInitialCapacity(bytes);
    for (size_t cycle = 0; data.size() < bytes; ++cycle) {
        for (int j = 0; j < 196 && data.size() < bytes; ++j)
            data.append(static_cast<uint8_t>(0x20 + ((cycle * 196 + j) % 0x5F)));
        if (data.size() + 4 <= bytes) {
            uint32_t cp = 0x1F600 + (cycle % 0x40);
            data.append(static_cast<uint8_t>(0xF0 | ((cp >> 18) & 0x07)));
            data.append(static_cast<uint8_t>(0x80 | ((cp >> 12) & 0x3F)));
            data.append(static_cast<uint8_t>(0x80 | ((cp >> 6)  & 0x3F)));
            data.append(static_cast<uint8_t>(0x80 | ( cp        & 0x3F)));
        }
    }
    return data;
}

// Cycling 2-byte (Latin-1), 3-byte (CJK) and 4-byte (emoji) sequences, no ASCII. Period 9, and
// GCD(16384, 9) = 1, so chunk boundaries hit every offset within the period and partial sequences
// are exercised.
static Vector<uint8_t> makeMixed234(size_t bytes)
{
    Vector<uint8_t> data;
    data.reserveInitialCapacity(bytes);
    while (data.size() < bytes) {
        // U+00A0 NO-BREAK SPACE: Latin-1, so 8-bit at first.
        if (data.size() + 2 > bytes) break;
        data.append(0xC2); data.append(0xA0);
        // U+4E2D, which forces the flip to 16-bit.
        if (data.size() + 3 > bytes) break;
        data.append(0xE4); data.append(0xB8); data.append(0xAD);
        // U+1F600, a surrogate pair.
        if (data.size() + 4 > bytes) break;
        data.append(0xF0); data.append(0x9F); data.append(0x98); data.append(0x80);
    }
    return data;
}

// Sparse ill-formed: 7 ASCII bytes + 0xFF, which is never a valid UTF-8 byte. Every 0xFF produces a
// U+FFFD, since these run with stopOnError false.
static Vector<uint8_t> makeIllformedP8(size_t bytes)
{
    Vector<uint8_t> data;
    data.reserveInitialCapacity(bytes);
    for (size_t i = 0; i < bytes; ++i)
        data.append((i % 8 == 7) ? 0xFF : static_cast<uint8_t>(0x20 + (i % 0x5F)));
    return data;
}

// Dense ill-formed: bare continuation bytes, so every byte is an error and produces one U+FFFD.
static Vector<uint8_t> makeIllformedDense(size_t bytes)
{
    Vector<uint8_t> data;
    data.reserveInitialCapacity(bytes);
    for (size_t i = 0; i < bytes; ++i)
        data.append(0x80);
    return data;
}

struct BenchResult {
    double mbPerSecond;
    double medianMs;
};

static BenchResult runBench(const Vector<uint8_t>& data)
{
    Vector<double> samples;
    samples.reserveInitialCapacity(iterations);

    for (unsigned iter = 0; iter < iterations; ++iter) {
        auto codec = newTextCodec(PAL::TextEncoding { "UTF-8"_s });
        bool sawError = false;

        auto start = MonotonicTime::now();
        for (size_t offset = 0; offset < data.size(); offset += chunkBytes) {
            size_t count = std::min(chunkBytes, data.size() - offset);
            bool flush = (offset + count >= data.size());
            auto result = codec->decode(data.span().subspan(offset, count), flush, /* stopOnError */ false, sawError);
            // Consume result so it cannot be optimised away.
            if (result.length() == std::numeric_limits<unsigned>::max()) [[unlikely]]
                dataLogLn("impossible");
        }
        samples.append((MonotonicTime::now() - start).milliseconds());
    }

    std::sort(samples.begin(), samples.end());
    double median = samples[iterations / 2];
    return { (static_cast<double>(data.size()) / (median / 1000.0)) / (1024.0 * 1024.0), median };
}

static void report(const char* label, const BenchResult& r)
{
    dataLogLn(label, ":  ", r.medianMs, " ms  ", r.mbPerSecond, " MB/s");
}

TEST(TextCodecUTF8Bench, ASCII)
{
    report("ascii", runBench(makeASCII(bufferBytes)));
}

TEST(TextCodecUTF8Bench, Latin1Only)
{
    report("latin1-only", runBench(makeLatin1Only(bufferBytes)));
}

TEST(TextCodecUTF8Bench, Latin1P66)
{
    report("latin1-p66", runBench(makeLatin1P66(bufferBytes)));
}

TEST(TextCodecUTF8Bench, Latin1P200)
{
    report("latin1-p200", runBench(makeLatin1P200(bufferBytes)));
}

TEST(TextCodecUTF8Bench, NonASCIIOnly)
{
    report("nonascii-only", runBench(makeNonASCIIOnly(bufferBytes)));
}

TEST(TextCodecUTF8Bench, TwobyteWideOnly)
{
    report("twobyte-wide-only", runBench(makeTwobyteWideOnly(bufferBytes)));
}

TEST(TextCodecUTF8Bench, FourbyteOnly)
{
    report("fourbyte-only", runBench(makeFourbyteOnly(bufferBytes)));
}

TEST(TextCodecUTF8Bench, CJKP66)
{
    report("cjk-p66", runBench(makeCJKP66(bufferBytes)));
}

TEST(TextCodecUTF8Bench, CJKP200)
{
    report("cjk-p200", runBench(makeCJKP200(bufferBytes)));
}

TEST(TextCodecUTF8Bench, EmojiP200)
{
    report("emoji-p200", runBench(makeEmojiP200(bufferBytes)));
}

TEST(TextCodecUTF8Bench, Mixed234)
{
    report("mixed-234", runBench(makeMixed234(bufferBytes)));
}

TEST(TextCodecUTF8Bench, IllformedP8)
{
    report("illformed-p8", runBench(makeIllformedP8(bufferBytes)));
}

TEST(TextCodecUTF8Bench, IllformedDense)
{
    report("illformed-dense", runBench(makeIllformedDense(bufferBytes)));
}

} // namespace TestWebKitAPI
