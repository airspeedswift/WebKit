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

// Differential coverage for the UTF-8 decoder, for as long as PAL can be built with either the C++
// decoder or the Swift one (USE_SWIFT_TEXT_CODEC_UTF8).
//
// TextCodec.cpp pins what a whole-input decode produces, one hand-written case at a time. This file
// pins something those cases cannot: that splitting the same input anywhere changes nothing. That
// property is the oracle, so there are no expected strings here and no reference decoder is needed --
// the single-chunk decode of the same bytes is the expectation, and every chunking of them is the
// test. Chunk boundaries are where the two decoders differ in structure, since a boundary is the
// only thing that leaves a partial sequence, and that sequence is the whole of what crosses between
// C++ and Swift.
//
// The second thing here is a direct differential, which chunking invariance is not: a decoder that
// is wrong the same way at every chunking passes that oracle. The two implementations cannot both be
// in one binary, so the comparison is across builds: every case's outcome folds into a digest, and
// the same digest has to come out of a gate-on build and a gate-off build. That is the only check
// here that can see a rule copied wrongly rather than inconsistently, which is what the two
// byte-order-mark rules are, since they disagree with each other by design.
//
// When the digest differs, set TEXT_CODEC_UTF8_DUMP to a path in each build and diff the two files:
// every case is one line, so the diff names the inputs and chunkings that moved.

#include "config.h"

#include <pal/text/TextCodec.h>
#include <pal/text/TextCodecUTF8SwiftTypes.h>
#include <pal/text/TextEncoding.h>
#include <pal/text/TextEncodingRegistry.h>
#include <stdio.h>
#include <stdlib.h>
#include <wtf/HexNumber.h>
#include <wtf/text/CString.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/StringBuilder.h>

namespace TestWebKitAPI {

namespace {

// `CString::data()` is `const char8_t*`, and gtest's `Message::operator<<` for pointers is deleted
// for it. Every failure message here goes through this.
static const char* utf8Chars(const CString& string)
{
    return reinterpret_cast<const char*>(string.data());
}

// Hex bytes with optional spaces, as in TextCodec.cpp.
static Vector<uint8_t> hexBytes(ASCIILiteral input)
{
    Vector<uint8_t> result;
    auto span = input.span8();
    for (size_t i = 0; i < span.size(); ) {
        if (span[i] == ' ') {
            ++i;
            continue;
        }
        RELEASE_ASSERT(i + 1 < span.size());
        RELEASE_ASSERT(isASCIIHexDigit(span[i]) && isASCIIHexDigit(span[i + 1]));
        result.append(toASCIIHexValue(span[i], span[i + 1]));
        i += 2;
    }
    return result;
}

static String describeBytes(std::span<const uint8_t> bytes)
{
    StringBuilder builder;
    for (auto byte : bytes) {
        if (!builder.isEmpty())
            builder.append(' ');
        builder.append(hex(byte, 2));
    }
    return builder.toString();
}

// Code units, not code points: a decoder bug that emits a lone surrogate or splits one differently
// has to be visible, and code-point iteration would paper over it.
static String describeString(const String& string)
{
    StringBuilder builder;
    builder.append('"');
    for (unsigned i = 0; i < string.length(); ++i) {
        char16_t unit = string[i];
        if (unit >= 0x20 && unit < 0x7F)
            builder.append(static_cast<char>(unit));
        else
            builder.append('{', hex(unit, 4), '}');
    }
    builder.append('"');
    return builder.toString();
}

struct Outcome {
    String text;
    bool sawError { false };

    bool operator==(const Outcome& other) const
    {
        return text == other.text && sawError == other.sawError;
    }
};

// `splits` are byte offsets where a new chunk begins, ascending, each in [0, bytes.size()]. An empty
// list is the single-chunk decode. A split at 0 or at size deliberately produces an empty chunk: a
// split at size is the flush-only final call that every streamed decode ends with.
//
// Accumulates one line per case, so that two builds of two different decoders can be compared
// without either being able to see the other. FNV-1a over the line's UTF-8, which is enough: this is
// a fingerprint for spotting disagreement, not a security digest, and the dump file is what locates
// it.
class CaseDigest {
public:
    CaseDigest()
    {
        if (const char* path = getenv("TEXT_CODEC_UTF8_DUMP"))
            m_dump = fopen(path, "w");
    }

    ~CaseDigest()
    {
        if (m_dump)
            fclose(m_dump);
    }

    void add(const String& line)
    {
        auto utf8 = line.utf8();
        for (auto byte : utf8.span()) {
            m_value ^= static_cast<uint64_t>(static_cast<uint8_t>(byte));
            m_value *= 1099511628211ULL;
        }
        ++m_cases;
        if (m_dump)
            fprintf(m_dump, "%s\n", utf8Chars(utf8));
    }

    uint64_t value() const { return m_value; }
    unsigned cases() const { return m_cases; }

private:
    uint64_t m_value { 14695981039346656037ULL };
    unsigned m_cases { 0 };
    FILE* m_dump { nullptr };
};

static Outcome decodeInChunks(std::span<const uint8_t> bytes, std::span<const size_t> splits, bool stopOnError, bool stripByteOrderMark)
{
    auto codec = newTextCodec(PAL::TextEncoding { "UTF-8"_s });
    if (stripByteOrderMark)
        codec->stripByteOrderMark();

    StringBuilder builder;
    bool sawError = false;
    size_t offset = 0;
    for (size_t i = 0; i <= splits.size(); ++i) {
        size_t end = i < splits.size() ? splits[i] : bytes.size();
        RELEASE_ASSERT(end >= offset && end <= bytes.size());
        bool last = i == splits.size();
        bool chunkSawError = false;
        builder.append(codec->decode(bytes.subspan(offset, end - offset), last, stopOnError, chunkSawError));
        sawError |= chunkSawError;
        offset = end;
    }
    return { builder.toString(), sawError };
}

static String context(std::span<const uint8_t> bytes, std::span<const size_t> splits, bool stopOnError, bool stripByteOrderMark)
{
    StringBuilder builder;
    builder.append("input ["_s, describeBytes(bytes), "] split at {"_s);
    for (size_t i = 0; i < splits.size(); ++i) {
        if (i)
            builder.append(',');
        builder.append(splits[i]);
    }
    builder.append("} stopOnError="_s, stopOnError ? "true"_s : "false"_s,
        " stripByteOrderMark="_s, stripByteOrderMark ? "true"_s : "false"_s);
    return builder.toString();
}

// Every input is run at every chunking, under both byte-order-mark settings.
static ASCIILiteral corpusLiterals[] = {
    // Empty, and the shortest things there are.
    ""_s,
    "61"_s,
    "00"_s,
    "7F"_s,

    // ASCII long enough to reach the machine-word loop, and lengths either side of a word so the
    // word loop's tail is exercised. Splitting these at every offset also walks the input across
    // every alignment the word loop can start from.
    "61 62 63 64 65 66 67"_s,
    "61 62 63 64 65 66 67 68"_s,
    "61 62 63 64 65 66 67 68 69"_s,
    "61 62 63 64 65 66 67 68 69 6A 6B 6C 6D 6E 6F 70 71 72 73 74"_s,

    // One of each sequence length, alone and with ASCII either side.
    "C2 B6"_s,
    "78 C2 B6"_s,
    "C2 B6 78"_s,
    "E2 98 83"_s,
    "78 E2 98 83 78"_s,
    "F0 9F 92 A9"_s,
    "78 F0 9F 92 A9 78"_s,
    // The Latin-1/wide boundary: U+00FF fits the narrow buffer, U+0100 forces the upconvert.
    "C3 BF"_s,
    "C4 80"_s,
    "61 C3 BF 61 C4 80 61"_s,

    // Byte order marks: leading (stripped when asked), repeated, mid-string (never stripped), and
    // truncated across what will become a chunk boundary.
    "EF BB BF"_s,
    "EF BB BF 61"_s,
    "EF BB BF EF BB BF 61"_s,
    "61 EF BB BF 62"_s,
    "EF BB BF C2 B6"_s,
    "EF BB BF F0 9F 92 A9"_s,
    "EF BB BF 61 62 63 64 65 66 67 68"_s,
    "EF"_s,
    "EF BB"_s,
    // A byte order mark that can only be settled out of a held partial sequence, next to one that
    // cannot be a mark at all, and one followed straight by an error: the rule that applies to a
    // held sequence is position-independent while the main loop's is not, so these are where the two
    // rules can be told apart.
    "61 EF BB"_s,
    "EF BB 61"_s,
    "EF BB BF EF BB"_s,
    "EF BB BF 80"_s,

    // Truncated sequences: a held partial sequence is the only state that crosses the boundary, and
    // on flush each of these has to become a replacement character.
    "C2"_s,
    "E2"_s,
    "E2 98"_s,
    "F0"_s,
    "F0 9F"_s,
    "F0 9F 92"_s,
    "61 61 61 61 61 61 61 61 F0 9F 92"_s,

    // Ill-formed leads and continuations.
    "80"_s,
    "80 80 80"_s,
    "FE"_s,
    "FF"_s,
    "FE 80"_s,
    "C0 80"_s,
    "C1 BF"_s,
    "E0 80 80"_s,
    "E0 9F BF"_s,
    "F0 80 80 80"_s,
    "F5 80 80 80"_s,
    "F4 90 80 80"_s,
    "FB BF BF BF BF"_s,
    "FD BF BF BF BF BF"_s,
    // Surrogates, singly and as a CESU-8 style pair.
    "ED A0 80"_s,
    "ED BF BF"_s,
    "ED A0 BD ED B2 A9"_s,
    // An error inside an otherwise valid run, which upconverts mid-buffer.
    "61 62 E0 A5 3F 63"_s,
    "C2 B6 E0 A5 3F"_s,

    // Mixtures, including one long enough that the narrow decode gets going before it upconverts.
    "61 C2 B6 E2 98 83 F0 9F 92 A9 62"_s,
    "61 61 61 61 61 61 61 61 61 61 61 61 E2 98 83"_s,
    "61 61 61 61 61 61 61 61 61 61 61 61 80 61"_s,
    "EF BB BF 61 61 61 61 61 61 61 61 F0 9F 92 A9 80 C2"_s,
};

// Beyond this length only single splits are tried; the pair sweep is quadratic and adds nothing once
// an input is longer than the longest sequence plus a word.
constexpr size_t maximumLengthForSplitPairs = 12;

static void checkAllChunkings(std::span<const uint8_t> bytes, bool stripByteOrderMark, unsigned& casesRun, CaseDigest& digest)
{
    // The oracle: one chunk, no early stop.
    auto reference = decodeInChunks(bytes, { }, false, stripByteOrderMark);

    Vector<Vector<size_t>> splitSets;
    splitSets.append({ });
    for (size_t i = 0; i <= bytes.size(); ++i)
        splitSets.append({ i });
    if (bytes.size() <= maximumLengthForSplitPairs) {
        for (size_t i = 0; i <= bytes.size(); ++i) {
            for (size_t j = i; j <= bytes.size(); ++j)
                splitSets.append({ i, j });
        }
    }

    for (auto& splits : splitSets) {
        ++casesRun;

        auto chunked = decodeInChunks(bytes, splits.span(), false, stripByteOrderMark);
        if (!(chunked == reference)) {
            auto detail = makeString(
                context(bytes, splits.span(), false, stripByteOrderMark),
                "\n  chunked:  "_s, describeString(chunked.text), chunked.sawError ? " ERROR"_s : ""_s,
                "\n  one shot: "_s, describeString(reference.text), reference.sawError ? " ERROR"_s : ""_s).utf8();
            ADD_FAILURE() << utf8Chars(detail);
        }

        // What the cross-build comparison is made of. The case's identity is in the line too, so a
        // corpus that has drifted shows up as a different digest rather than as a coincidence.
        digest.add(makeString(
            context(bytes, splits.span(), false, stripByteOrderMark),
            " -> "_s, describeString(chunked.text), chunked.sawError ? " ERROR"_s : ""_s));

        // `stopOnError` truncates the decode at the first error, so it is only equivalent on input
        // that has no errors to stop at. On input that does, the flag's behaviour is pinned by the
        // hand-written cases in TextCodec.cpp and by the digest below; here it is exercised for
        // crashes, not compared.
        auto stopped = decodeInChunks(bytes, splits.span(), true, stripByteOrderMark);
        if (!reference.sawError && !(stopped == reference)) {
            auto detail = makeString(
                context(bytes, splits.span(), true, stripByteOrderMark),
                "\n  stopOnError: "_s, describeString(stopped.text),
                "\n  one shot:    "_s, describeString(reference.text)).utf8();
            ADD_FAILURE() << utf8Chars(detail);
        }

        digest.add(makeString(
            context(bytes, splits.span(), true, stripByteOrderMark),
            " -> "_s, describeString(stopped.text), stopped.sawError ? " ERROR"_s : ""_s));
    }
}

} // namespace

// Splitting an input must not change what it decodes to. The digest of every case's outcome is
// reported so that a gate-on and a gate-off build can be compared: see the note at the top.
TEST(TextCodecUTF8Differential, ChunkingInvariance)
{
    unsigned casesRun = 0;
    CaseDigest digest;
    for (auto literal : corpusLiterals) {
        auto bytes = hexBytes(literal);
        checkAllChunkings(bytes.span(), false, casesRun, digest);
        checkAllChunkings(bytes.span(), true, casesRun, digest);
    }
    EXPECT_GT(casesRun, 1000u);

    // The cross-build differential. The C++ decoder and the Swift one cannot be in one binary, so
    // this is how they are compared: both builds decode the same corpus at the same chunkings and
    // have to fold to the same number. A change to the corpus changes it too, which is why the case
    // count is checked alongside -- the pair says which corpus agreed.
    //
    // Established on the C++ decoder (WK_USE_SWIFT_TEXT_CODEC_UTF8=NO), which is the specification
    // the Swift decoder is a port of. If a deliberate behaviour change ever makes the two differ,
    // the C++ build is the one that says what the new number is.
    //
    // Two lines per case, `stopOnError` off and on.
    EXPECT_EQ(digest.cases(), 2 * casesRun);
    EXPECT_EQ(digest.value(), 12125241242428093179ULL)
        << "the decoder in this build disagrees with the one the digest was taken from; set "
        << "TEXT_CODEC_UTF8_DUMP in both builds and diff the two files";
}

// Which decoder the digest above came out of. Not an assertion about behaviour -- the two are
// supposed to be indistinguishable -- but the line that makes a run self-describing, so that two
// dumps can be told apart after the fact.
TEST(TextCodecUTF8Differential, WhichDecoder)
{
    if (PAL::textCodecUTF8SwiftEnabled())
        printf("UTF-8 decoder in this build: Swift (USE_SWIFT_TEXT_CODEC_UTF8)\n");
    else
        printf("UTF-8 decoder in this build: C++\n");
}

} // namespace TestWebKitAPI
