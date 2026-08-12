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

// Throughput benchmark for TextCodecUTF8::decode(), used as the baseline and
// measurement harness for the Swift island-vs-fine-grained experiment.
// See ~/Documents/webkit-swift-adoption-notes.md §6.
//
// Not a correctness test: TextCodec.cpp covers that. These cases exist to make
// the decode loop's throughput measurable and to separate the input shapes that
// stress different parts of it.
//
// Run with:
//   WebKitBuild/Release/TestWebKitAPI --gtest_filter='TextCodecUTF8Bench.*'
//
// Results print to stdout as MB/s; gtest reports pass as long as decoding
// produced the expected number of characters, so a silent behaviour change
// shows up as a failure rather than as a fast-but-wrong number.

#include "config.h"

#include <pal/text/TextCodec.h>
#include <pal/text/TextEncoding.h>
#include <pal/text/TextEncodingRegistry.h>
#include <wtf/DataLog.h>
#include <wtf/MonotonicTime.h>
#include <wtf/Vector.h>
#include <wtf/text/StringBuilder.h>
#include <wtf/text/WTFString.h>

namespace TestWebKitAPI {

namespace {

constexpr size_t bufferBytes = 8 * 1024 * 1024;
constexpr unsigned iterations = 15;

// MARK: - Input generation
//
// Deterministic (no rand()) so runs are comparable across builds and machines.

Vector<uint8_t> makePureASCII(size_t bytes)
{
    Vector<uint8_t> data(bytes);
    for (size_t i = 0; i < bytes; ++i)
        data[i] = static_cast<uint8_t>(0x20 + (i % 0x5F)); // printable ASCII
    return data;
}

// Every character is a 2-byte sequence in U+00C0..U+00FF, which is Latin-1
// representable, so decoding stays in the 8-bit StringBuffer and never takes
// the `goto upConvertTo16Bit` path.
Vector<uint8_t> makeLatin1TwoByte(size_t bytes)
{
    Vector<uint8_t> data;
    data.reserveInitialCapacity(bytes);
    while (data.size() + 2 <= bytes) {
        data.append(0xC3);
        data.append(static_cast<uint8_t>(0x80 + (data.size() % 0x40)));
    }
    return data;
}

// Every character is a 3-byte CJK sequence: not Latin-1, so this forces
// up-conversion to the 16-bit buffer immediately, and pays one
// decodeNonASCIISequence() call per character.
Vector<uint8_t> makeCJKThreeByte(size_t bytes)
{
    Vector<uint8_t> data;
    data.reserveInitialCapacity(bytes);
    while (data.size() + 3 <= bytes) {
        data.append(0xE4);
        data.append(0xB8);
        data.append(static_cast<uint8_t>(0x80 + (data.size() % 0x3F)));
    }
    return data;
}

// Mostly ASCII with a 2-byte sequence roughly every 64 bytes. Approximates
// western-language web text, and is the case that matters most in practice:
// the machine-word ASCII fast path does most of the work but is interrupted
// often enough that per-sequence costs are visible.
Vector<uint8_t> makeMixed(size_t bytes)
{
    Vector<uint8_t> data;
    data.reserveInitialCapacity(bytes);
    size_t sinceNonASCII = 0;
    while (data.size() + 2 <= bytes) {
        if (sinceNonASCII >= 64) {
            data.append(0xC3);
            data.append(0xA9); // é
            sinceNonASCII = 0;
            continue;
        }
        data.append(static_cast<uint8_t>(0x20 + (data.size() % 0x5F)));
        ++sinceNonASCII;
    }
    return data;
}

// MARK: - Timing

struct Result {
    double megabytesPerSecond { 0 };
    double medianMilliseconds { 0 };
    size_t charactersDecoded { 0 };
    String decoded;
};

// `chunkSize` of 0 means "decode the whole buffer in one call".
//
// A nonzero value must be COPRIME with the generator's period, or chunk
// boundaries can never land inside a multi-byte sequence and the
// partial-sequence path is never exercised. makeMixed() has period 66
// (64 ASCII + one 2-byte sequence); a straddle needs
// chunkSize * m == 65 (mod 66) to have a solution, which requires
// gcd(chunkSize, 66) to divide 65 — i.e. gcd == 1. Note 1000 gives gcd 2 and
// 1001 gives gcd 11, so both silently test nothing. 997 is prime.
Result timeDecode(const Vector<uint8_t>& data, size_t chunkSize = 0)
{
    Vector<double> samples;
    samples.reserveInitialCapacity(iterations);
    size_t charactersDecoded = 0;

    // Timed runs: only the decode calls are inside the timed region. Building a
    // String of the whole result is done once afterwards, untimed, so that
    // content verification does not distort the throughput numbers.
    for (unsigned iteration = 0; iteration < iterations; ++iteration) {
        auto codec = newTextCodec(PAL::TextEncoding { "UTF-8"_s });
        bool sawError = false;
        size_t characters = 0;

        auto start = MonotonicTime::now();
        if (!chunkSize) {
            characters += codec->decode(data.span(), true, false, sawError).length();
        } else {
            for (size_t offset = 0; offset < data.size(); offset += chunkSize) {
                size_t thisChunk = std::min(chunkSize, data.size() - offset);
                bool last = offset + thisChunk >= data.size();
                characters += codec->decode(data.span().subspan(offset, thisChunk), last, false, sawError).length();
            }
        }
        auto elapsed = MonotonicTime::now() - start;

        samples.append(elapsed.milliseconds());
        charactersDecoded = characters;
        EXPECT_FALSE(sawError);
    }

    // Untimed verification pass: reconstruct the full decoded text so callers
    // can compare CONTENT, not just length.
    String decoded;
    {
        auto codec = newTextCodec(PAL::TextEncoding { "UTF-8"_s });
        bool sawError = false;
        StringBuilder builder;
        if (!chunkSize)
            builder.append(codec->decode(data.span(), true, false, sawError));
        else {
            for (size_t offset = 0; offset < data.size(); offset += chunkSize) {
                size_t thisChunk = std::min(chunkSize, data.size() - offset);
                bool last = offset + thisChunk >= data.size();
                builder.append(codec->decode(data.span().subspan(offset, thisChunk), last, false, sawError));
            }
        }
        decoded = builder.toString();
    }

    std::sort(samples.begin(), samples.end());
    double median = samples[samples.size() / 2];
    double bytesPerSecond = median > 0 ? data.size() / (median / 1000.0) : 0;
    return { bytesPerSecond / (1024.0 * 1024.0), median, charactersDecoded, decoded };
}

void report(ASCIILiteral label, const Result& result)
{
    dataLogLn(label, ": ", result.medianMilliseconds, " ms median, ",
        result.megabytesPerSecond, " MB/s, ", result.charactersDecoded, " chars");
}

} // namespace

// MARK: - Cases
//
// Each case asserts the decoded character count as well as reporting
// throughput, so an implementation that is fast because it is wrong fails
// rather than scoring well. Counts are derived from the generators:
//   pure ASCII    1 char per byte
//   2-byte        1 char per 2 bytes
//   3-byte        1 char per 3 bytes

TEST(TextCodecUTF8Bench, PureASCII)
{
    auto data = makePureASCII(bufferBytes);
    auto result = timeDecode(data);
    EXPECT_EQ(result.charactersDecoded, data.size());
    report("pure ASCII (word-at-a-time fast path only)"_s, result);
}

TEST(TextCodecUTF8Bench, Latin1TwoByte)
{
    auto data = makeLatin1TwoByte(bufferBytes);
    auto result = timeDecode(data);
    EXPECT_EQ(result.charactersDecoded, data.size() / 2);
    report("2-byte latin1 (8-bit buffer, no up-convert)"_s, result);
}

TEST(TextCodecUTF8Bench, CJKThreeByte)
{
    auto data = makeCJKThreeByte(bufferBytes);
    auto result = timeDecode(data);
    EXPECT_EQ(result.charactersDecoded, data.size() / 3);
    report("3-byte CJK (forces 16-bit up-convert)"_s, result);
}

TEST(TextCodecUTF8Bench, MixedWesternText)
{
    auto data = makeMixed(bufferBytes);
    auto result = timeDecode(data);
    report("mixed ~1.5% non-ASCII (realistic web text)"_s, result);
}

TEST(TextCodecUTF8Bench, ChunkedSplittingSequences)
{
    auto data = makeMixed(bufferBytes);

    // Whole-buffer decode is the reference. Comparing decoded CONTENT (not just
    // length) is essential here: a decoder that drops a split sequence emits a
    // replacement character and re-decodes its neighbour, which can conserve the
    // character count exactly while corrupting the output. A length-only check
    // passes on such a bug.
    auto reference = timeDecode(data);
    auto result = timeDecode(data, 997);

    EXPECT_EQ(result.decoded.length(), reference.decoded.length());
    EXPECT_TRUE(result.decoded == reference.decoded);
    report("chunked at 997 bytes (partial-sequence path)"_s, result);
}

} // namespace TestWebKitAPI
