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

// Throughput of the UTF-8 decoder, one test per input shape. Each test decodes an 8 MiB byte sequence
// in 16 KiB chunks through a new codec, flushing on the last chunk, and prints one line
// "<shape>: 8 MiB in 16 KiB chunks, <n> MB/s", the median of five repetitions of at least 250 ms.
// The rate counts every byte passed to the decoder, including bytes it does not decode after it stops
// on an error.
// Nothing asserts on time; each test checks only whether the decoder saw an error.

#include "config.h"

#include <algorithm>
#include <cstdio>
#include <pal/text/TextCodec.h>
#include <pal/text/TextEncoding.h>
#include <pal/text/TextEncodingRegistry.h>
#include <wtf/MonotonicTime.h>
#include <wtf/Vector.h>
#include <wtf/text/WTFString.h>

namespace TestWebKitAPI {

static Vector<uint8_t> makeASCII(size_t bytes)
{
    Vector<uint8_t> data;
    data.reserveInitialCapacity(bytes);
    for (size_t i = 0; i < bytes; ++i)
        data.append(static_cast<uint8_t>(0x20 + (i % 0x5F)));
    return data;
}

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

// Periods 66 and 200 leave every Latin-1 sequence inside one chunk. The same holds for cjk-p200 and
// emoji-p200; in cjk-p66 a three-byte sequence straddles every 33rd chunk boundary.
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

// One ASCII byte, then two-byte Latin-1 characters, so a two-byte sequence straddles every chunk boundary.
static Vector<uint8_t> makeLatin1ChunkSplit(size_t bytes)
{
    Vector<uint8_t> data;
    data.reserveInitialCapacity(bytes);
    data.append('a');
    for (size_t i = 0; data.size() + 2 <= bytes; ++i) {
        uint32_t cp = 0x80 + (i % 0x80); // U+0080..U+00FF
        data.append(static_cast<uint8_t>(0xC0 | (cp >> 6)));
        data.append(static_cast<uint8_t>(0x80 | (cp & 0x3F)));
    }
    return data;
}

// 8-bit until the first character above U+00FF, 16-bit after.
static Vector<uint8_t> makeNonASCIIOnly(size_t bytes)
{
    Vector<uint8_t> data;
    data.reserveInitialCapacity(bytes);
    for (size_t i = 0; data.size() + 2 <= bytes; ++i) {
        uint8_t lead = static_cast<uint8_t>(0xC2 + ((i / 64) % 30));
        uint8_t cont = static_cast<uint8_t>(0x80 + (i % 64));
        data.append(lead);
        data.append(cont);
    }
    return data;
}

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

static Vector<uint8_t> makeFourbyteOnly(size_t bytes)
{
    Vector<uint8_t> data;
    data.reserveInitialCapacity(bytes);
    for (size_t i = 0; data.size() + 4 <= bytes; ++i) {
        uint32_t cp = 0x10000 + (i % 0x4000);
        data.append(static_cast<uint8_t>(0xF0 | ((cp >> 18) & 0x07)));
        data.append(static_cast<uint8_t>(0x80 | ((cp >> 12) & 0x3F)));
        data.append(static_cast<uint8_t>(0x80 | ((cp >> 6) & 0x3F)));
        data.append(static_cast<uint8_t>(0x80 | (cp & 0x3F)));
    }
    return data;
}

static Vector<uint8_t> makeCJKP66(size_t bytes)
{
    Vector<uint8_t> data;
    data.reserveInitialCapacity(bytes);
    for (size_t cycle = 0; data.size() < bytes; ++cycle) {
        for (int j = 0; j < 63 && data.size() < bytes; ++j)
            data.append(static_cast<uint8_t>(0x20 + ((cycle * 63 + j) % 0x5F)));
        if (data.size() + 3 <= bytes) {
            uint32_t cp = 0x4E00 + (cycle % 0x40);
            data.append(static_cast<uint8_t>(0xE0 | (cp >> 12)));
            data.append(static_cast<uint8_t>(0x80 | ((cp >> 6) & 0x3F)));
            data.append(static_cast<uint8_t>(0x80 | (cp & 0x3F)));
        }
    }
    return data;
}

static Vector<uint8_t> makeCJKP200(size_t bytes)
{
    Vector<uint8_t> data;
    data.reserveInitialCapacity(bytes);
    for (size_t cycle = 0; data.size() < bytes; ++cycle) {
        for (int j = 0; j < 197 && data.size() < bytes; ++j)
            data.append(static_cast<uint8_t>(0x20 + ((cycle * 197 + j) % 0x5F)));
        if (data.size() + 3 <= bytes) {
            uint32_t cp = 0x4E00 + (cycle % 0x40);
            data.append(static_cast<uint8_t>(0xE0 | (cp >> 12)));
            data.append(static_cast<uint8_t>(0x80 | ((cp >> 6) & 0x3F)));
            data.append(static_cast<uint8_t>(0x80 | (cp & 0x3F)));
        }
    }
    return data;
}

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
            data.append(static_cast<uint8_t>(0x80 | ((cp >> 6) & 0x3F)));
            data.append(static_cast<uint8_t>(0x80 | (cp & 0x3F)));
        }
    }
    return data;
}

// Period 9, so sequences straddle chunk boundaries at every offset and exercise partial sequences.
static Vector<uint8_t> makeMixed234(size_t bytes)
{
    Vector<uint8_t> data;
    data.reserveInitialCapacity(bytes);
    while (data.size() < bytes) {
        if (data.size() + 2 > bytes)
            break;
        data.append(0xC2);
        data.append(0xA0);
        if (data.size() + 3 > bytes)
            break;
        data.append(0xE4);
        data.append(0xB8);
        data.append(0xAD);
        if (data.size() + 4 > bytes)
            break;
        data.append(0xF0);
        data.append(0x9F);
        data.append(0x98);
        data.append(0x80);
    }
    return data;
}

static Vector<uint8_t> makeIllformedP8(size_t bytes)
{
    Vector<uint8_t> data;
    data.reserveInitialCapacity(bytes);
    for (size_t i = 0; i < bytes; ++i)
        data.append((i % 8 == 7) ? 0xFF : static_cast<uint8_t>(0x20 + (i % 0x5F)));
    return data;
}

static Vector<uint8_t> makeIllformedDense(size_t bytes)
{
    Vector<uint8_t> data;
    data.reserveInitialCapacity(bytes);
    for (size_t i = 0; i < bytes; ++i)
        data.append(0x80);
    return data;
}

// A byte order mark, then ASCII.
static Vector<uint8_t> makeByteOrderMarkASCII(size_t bytes)
{
    Vector<uint8_t> data;
    data.reserveInitialCapacity(bytes);
    data.append(0xEF);
    data.append(0xBB);
    data.append(0xBF);
    for (size_t i = 0; data.size() < bytes; ++i)
        data.append(static_cast<uint8_t>(0x20 + (i % 0x5F)));
    return data;
}

// Dense three-byte characters, mostly CJK ideographs, with a fullwidth comma every 20 characters.
static Vector<uint8_t> makeCJKOnly(size_t bytes)
{
    Vector<uint8_t> data;
    data.reserveInitialCapacity(bytes);
    for (size_t i = 0; data.size() + 3 <= bytes; ++i) {
        uint32_t cp = (i % 20 == 19) ? 0xFF0C : 0x4E00 + ((i * 2654435761u) % 0x5200);
        data.append(static_cast<uint8_t>(0xE0 | (cp >> 12)));
        data.append(static_cast<uint8_t>(0x80 | ((cp >> 6) & 0x3F)));
        data.append(static_cast<uint8_t>(0x80 | (cp & 0x3F)));
    }
    return data;
}

// Russian-like prose: words of 2..11 Cyrillic letters (U+0430..U+044F) separated by one ASCII space,
// with ", " or ". " every ~8 words.
static Vector<uint8_t> makeCyrillicWords(size_t bytes)
{
    Vector<uint8_t> data;
    data.reserveInitialCapacity(bytes);
    uint64_t x = 88172645463325252ull;
    auto next = [&] { x ^= x << 13; x ^= x >> 7; x ^= x << 17; return x; };
    while (data.size() + 32 <= bytes) {
        unsigned letters = 2 + next() % 10;
        for (unsigned l = 0; l < letters; ++l) {
            uint32_t cp = 0x430 + next() % 32;
            data.append(static_cast<uint8_t>(0xC0 | (cp >> 6)));
            data.append(static_cast<uint8_t>(0x80 | (cp & 0x3F)));
        }
        if (next() % 8 == 0) data.append(next() % 2 ? ',' : '.');
        data.append(' ');
    }
    while (data.size() < bytes) data.append(' ');
    return data;
}

static constexpr size_t inputBytes = 8 * 1024 * 1024;
static constexpr size_t chunkBytes = 16 * 1024;
static constexpr unsigned repetitions = 5;
static constexpr Seconds minimumRepetitionTime = 250_ms;

static uint64_t decodedLengthSink;

struct DecodeOptions {
    bool stopOnError { false };
    bool stripByteOrderMark { false };
};

static bool decodeInChunks(std::span<const uint8_t> data, DecodeOptions options)
{
    auto codec = PAL::newTextCodec(PAL::TextEncoding { "UTF-8"_s });
    if (options.stripByteOrderMark)
        codec->stripByteOrderMark();
    bool sawError = false;
    for (size_t offset = 0; offset < data.size(); offset += chunkBytes) {
        size_t count = std::min(chunkBytes, data.size() - offset);
        bool flush = offset + count >= data.size();
        auto result = codec->decode(data.subspan(offset, count), flush, options.stopOnError, sawError);
        decodedLengthSink = decodedLengthSink * 1000003u + result.length();
    }
    decodedLengthSink += sawError;
    return sawError;
}

static void measureThroughput(const char* shape, const Vector<uint8_t>& data, bool expectedSawError, DecodeOptions options = { })
{
    EXPECT_EQ(decodeInChunks(data.span(), options), expectedSawError);

    Vector<double> megabytesPerSecond;
    for (unsigned repetition = 0; repetition < repetitions; ++repetition) {
        uint64_t passes = 0;
        auto start = MonotonicTime::now();
        Seconds elapsed;
        do {
            decodeInChunks(data.span(), options);
            ++passes;
            elapsed = MonotonicTime::now() - start;
        } while (elapsed < minimumRepetitionTime);
        megabytesPerSecond.append(static_cast<double>(passes * data.size()) / elapsed.seconds() / 1e6);
    }
    std::sort(megabytesPerSecond.begin(), megabytesPerSecond.end());
    printf("%s: 8 MiB in 16 KiB chunks, %.1f MB/s\n", shape, megabytesPerSecond[repetitions / 2]);
    fflush(stdout);
}

TEST(TextCodecUTF8Bench, ASCII)
{
    measureThroughput("ascii", makeASCII(inputBytes), false);
}

TEST(TextCodecUTF8Bench, Latin1Only)
{
    measureThroughput("latin1-only", makeLatin1Only(inputBytes), false);
}

TEST(TextCodecUTF8Bench, Latin1P66)
{
    measureThroughput("latin1-p66", makeLatin1P66(inputBytes), false);
}

TEST(TextCodecUTF8Bench, Latin1P200)
{
    measureThroughput("latin1-p200", makeLatin1P200(inputBytes), false);
}

TEST(TextCodecUTF8Bench, NonASCIIOnly)
{
    measureThroughput("nonascii-only", makeNonASCIIOnly(inputBytes), false);
}

TEST(TextCodecUTF8Bench, TwobyteWideOnly)
{
    measureThroughput("twobyte-wide-only", makeTwobyteWideOnly(inputBytes), false);
}

TEST(TextCodecUTF8Bench, FourbyteOnly)
{
    measureThroughput("fourbyte-only", makeFourbyteOnly(inputBytes), false);
}

TEST(TextCodecUTF8Bench, CJKP66)
{
    measureThroughput("cjk-p66", makeCJKP66(inputBytes), false);
}

TEST(TextCodecUTF8Bench, CJKP200)
{
    measureThroughput("cjk-p200", makeCJKP200(inputBytes), false);
}

TEST(TextCodecUTF8Bench, EmojiP200)
{
    measureThroughput("emoji-p200", makeEmojiP200(inputBytes), false);
}

TEST(TextCodecUTF8Bench, Mixed234)
{
    measureThroughput("mixed-234", makeMixed234(inputBytes), false);
}

TEST(TextCodecUTF8Bench, IllformedP8)
{
    measureThroughput("illformed-p8", makeIllformedP8(inputBytes), true);
}

TEST(TextCodecUTF8Bench, IllformedDense)
{
    measureThroughput("illformed-dense", makeIllformedDense(inputBytes), true);
}

TEST(TextCodecUTF8Bench, XCJKOnly)
{
    measureThroughput("x-cjk-only", makeCJKOnly(inputBytes), false);
}

TEST(TextCodecUTF8Bench, XCyrillicWords)
{
    measureThroughput("x-cyrillic-words", makeCyrillicWords(inputBytes), false);
}

TEST(TextCodecUTF8Bench, XIllformedP8Stop)
{
    measureThroughput("x-illformed-p8-stop", makeIllformedP8(inputBytes), true, { .stopOnError = true });
}

TEST(TextCodecUTF8Bench, XByteOrderMarkASCII)
{
    measureThroughput("x-bom-ascii", makeByteOrderMarkASCII(inputBytes), false, { .stripByteOrderMark = true });
}

TEST(TextCodecUTF8Bench, XLatin1ChunkSplit)
{
    measureThroughput("x-latin1-chunk-split", makeLatin1ChunkSplit(inputBytes), false);
}

} // namespace TestWebKitAPI
