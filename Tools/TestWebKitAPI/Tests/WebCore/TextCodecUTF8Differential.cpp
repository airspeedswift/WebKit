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
// test. Chunk boundaries are where the two decoders differ in structure, since a boundary is the only
// thing that leaves a partial sequence, and that sequence is the whole of what crosses between C++ and
// Swift.
//
// The second thing here is a coverage count: how much input Swift decoded. The rest goes to the C++
// loop, which produces identical output by construction, so a build where Swift decoded nothing
// passes every correctness test in the suite. Only the counters can tell those apart.
//
// The third is a direct differential, which chunking invariance is not: a decoder that is wrong the
// same way at every chunking passes that oracle, and now that Swift decodes every input the C++ loop
// is unreachable and cannot contradict it. `setTextCodecUTF8SwiftDisabledForTesting` forces the C++
// loop, so that both implementations can decode the same bytes in one process. This is the only check
// here that can see a rule copied wrongly rather than inconsistently, which is what the two
// byte-order-mark rules are, since they disagree with each other by design.

#include "config.h"

#include <pal/text/TextCodec.h>
#include <pal/text/TextCodecUTF8SwiftTypes.h>
#include <pal/text/TextEncoding.h>
#include <pal/text/TextEncodingRegistry.h>
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
// list is the single-chunk decode. A split at 0 or at size deliberately produces an EMPTY chunk:
// those are not degenerate cases but the two the production gate currently refuses to hand to Swift,
// and a split at size is the flush-only final call that every streamed decode ends with.
// Forces `TextCodecUTF8::decode` down its own C++ loop for the lifetime of the scope, so the two
// implementations can be compared against each other.
class ForceCppDecoder {
public:
    ForceCppDecoder() { PAL::setTextCodecUTF8SwiftDisabledForTesting(true); }
    ~ForceCppDecoder() { PAL::setTextCodecUTF8SwiftDisabledForTesting(false); }
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
    // cannot be a mark at all, and one followed straight by an error: the rule that applies to a held
    // sequence is position-independent while the main loop's is not, so these are where the two rules
    // can be told apart.
    "61 EF BB"_s,
    "EF BB 61"_s,
    "EF BB BF EF BB"_s,
    "EF BB BF 80"_s,

    // Truncated sequences: a held partial sequence is the only state that crosses the boundary, and on
    // flush each of these has to become a replacement character.
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

static void checkAllChunkings(std::span<const uint8_t> bytes, bool stripByteOrderMark, unsigned& casesRun)
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

        // The same chunking through the C++ decoder. Unlike the oracle above this compares the two
        // IMPLEMENTATIONS, so it is what catches a rule transcribed wrongly rather than
        // inconsistently -- above all the byte order mark, whose two C++ rules differ from each
        // other and whose position rule has to survive the narrow-to-wide handoff.
        Outcome viaCpp;
        {
            ForceCppDecoder forceCpp;
            viaCpp = decodeInChunks(bytes, splits.span(), false, stripByteOrderMark);
        }
        if (!(viaCpp == chunked)) {
            auto detail = makeString(
                context(bytes, splits.span(), false, stripByteOrderMark),
                "\n  as built: "_s, describeString(chunked.text), chunked.sawError ? " ERROR"_s : ""_s,
                "\n  C++ loop: "_s, describeString(viaCpp.text), viaCpp.sawError ? " ERROR"_s : ""_s).utf8();
            ADD_FAILURE() << utf8Chars(detail);
        }

        // `stopOnError` truncates the decode at the first error, so it is only equivalent on input
        // that has no errors to stop at. On input that does, the flag's behaviour is pinned by the
        // hand-written cases in TextCodec.cpp; here it is exercised for crashes and for the
        // coverage count, not compared.
        auto stopped = decodeInChunks(bytes, splits.span(), true, stripByteOrderMark);
        if (!reference.sawError && !(stopped == reference)) {
            auto detail = makeString(
                context(bytes, splits.span(), true, stripByteOrderMark),
                "\n  stopOnError: "_s, describeString(stopped.text),
                "\n  one shot:    "_s, describeString(reference.text)).utf8();
            ADD_FAILURE() << utf8Chars(detail);
        }

        Outcome stoppedViaCpp;
        {
            ForceCppDecoder forceCpp;
            stoppedViaCpp = decodeInChunks(bytes, splits.span(), true, stripByteOrderMark);
        }
        if (!(stoppedViaCpp == stopped)) {
            auto detail = makeString(
                context(bytes, splits.span(), true, stripByteOrderMark),
                "\n  as built: "_s, describeString(stopped.text), stopped.sawError ? " ERROR"_s : ""_s,
                "\n  C++ loop: "_s, describeString(stoppedViaCpp.text), stoppedViaCpp.sawError ? " ERROR"_s : ""_s).utf8();
            ADD_FAILURE() << utf8Chars(detail);
        }
    }
}

} // namespace

// Splitting an input must not change what it decodes to, and the two implementations must agree.
TEST(TextCodecUTF8Differential, ChunkingInvariance)
{
    unsigned casesRun = 0;
    for (auto literal : corpusLiterals) {
        auto bytes = hexBytes(literal);
        checkAllChunkings(bytes.span(), false, casesRun);
        checkAllChunkings(bytes.span(), true, casesRun);
    }
    EXPECT_GT(casesRun, 1000u);
}

// The counters are the only way to see which decoder ran, because the two produce identical output
// invisible in the output by construction. This test is the acceptance criterion for deleting the
// C++ decoder: when `declined` is zero across the corpus above, nothing reaches the C++ loop, and
// the `#if` can select one implementation or the other instead of layering them.
TEST(TextCodecUTF8Differential, SwiftDecoderCoverage)
{
    if (!PAL::textCodecUTF8SwiftEnabled()) {
        // Built without the Swift decoder: there is nothing to measure, and asserting zero here
        // would pass for the wrong reason.
        EXPECT_EQ(PAL::textCodecUTF8SwiftCounters().answered.load(std::memory_order_relaxed), 0ULL);
        return;
    }

    auto& counters = PAL::textCodecUTF8SwiftCounters();
    uint64_t answeredBefore = counters.answered.load(std::memory_order_relaxed);
    uint64_t declinedBefore = counters.declined.load(std::memory_order_relaxed);
    uint64_t leadIsASCIIBefore = counters.declinedParkedLeadIsASCII.load(std::memory_order_relaxed);
    uint64_t exceedsLengthBefore = counters.declinedParkExceedsLeadLength.load(std::memory_order_relaxed);

    unsigned casesRun = 0;
    for (auto literal : corpusLiterals) {
        auto bytes = hexBytes(literal);
        checkAllChunkings(bytes.span(), false, casesRun);
        checkAllChunkings(bytes.span(), true, casesRun);
    }

    uint64_t answered = counters.answered.load(std::memory_order_relaxed) - answeredBefore;
    uint64_t declined = counters.declined.load(std::memory_order_relaxed) - declinedBefore;
    uint64_t leadIsASCII = counters.declinedParkedLeadIsASCII.load(std::memory_order_relaxed) - leadIsASCIIBefore;
    uint64_t exceedsLength = counters.declinedParkExceedsLeadLength.load(std::memory_order_relaxed) - exceedsLengthBefore;

    // Not vacuous: the corpus has to have reached Swift at all.
    EXPECT_GT(answered, 0ULL);

    // The goal. Every one of these is input the C++ loop still has to handle, and both remaining shapes
    // are partial sequences only that loop can leave -- so a non-zero count here says some call is
    // still reaching it, and which of the two shapes it left.
    EXPECT_EQ(declined, 0ULL)
        << declined << " of " << (answered + declined)
        << " decodes went to the C++ loop; each one is input the C++ decoder still has to handle."
        << "\n  held lead is ASCII:         " << leadIsASCII
        << "\n  held run exceeds its lead:   " << exceedsLength
        << "\n  unattributed:               " << (declined - leadIsASCII - exceedsLength);
}

} // namespace TestWebKitAPI
