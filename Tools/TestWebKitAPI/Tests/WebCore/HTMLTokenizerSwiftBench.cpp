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

// In-tree A/B of the Swift HTML tokenizer island against a C++ reference with
// identical semantics. Both live in WebCore; see
// ~/Documents/webkit-swift-adoption-notes.md §8.
//
//   WebKitBuild/Release/TestWebKitAPI --gtest_filter='HTMLTokenizerSwiftBench.*'
//
// Correctness is asserted first: both must agree on token count AND name
// checksum. A benchmark that is fast because it is wrong fails instead of
// scoring well (§6d taught this the hard way).

#include "config.h"

#include <algorithm>
#include <wtf/DataLog.h>
#include <wtf/MonotonicTime.h>
#include <wtf/Vector.h>
#include <wtf/text/StringBuilder.h>

extern "C" {
void webCoreTokenizeBenchSwift(const uint8_t*, size_t, size_t*, uint64_t*);
void webCoreTokenizeBenchCpp(const uint8_t*, size_t, size_t*, uint64_t*);
}

namespace TestWebKitAPI {

namespace {

constexpr unsigned iterations = 15;

Vector<uint8_t> makeMarkup(size_t targetBytes)
{
    // Representative markup: text runs, quoted and unquoted attributes, nesting.
    auto chunk = "<p class=\"para\" id=main>Some body text that is reasonably long and mostly plain.</p>"
        "<div data-role='widget' hidden><span>nested</span> more text here</div>"
        "<a href=\"https://example.com/path?q=1\" title=\"a link\">anchor text</a>"_span8;
    Vector<uint8_t> data;
    data.reserveInitialCapacity(targetBytes + chunk.size());
    while (data.size() < targetBytes) {
        for (auto character : chunk)
            data.append(static_cast<uint8_t>(character));
    }
    return data;
}

struct Timing {
    double medianMilliseconds { 0 };
    double megabytesPerSecond { 0 };
};

using TokenizeFunction = void (*)(const uint8_t*, size_t, size_t*, uint64_t*);

Timing time(TokenizeFunction function, const Vector<uint8_t>& data)
{
    Vector<double> samples;
    samples.reserveInitialCapacity(iterations);
    for (unsigned i = 0; i < iterations; ++i) {
        size_t tokens = 0;
        uint64_t checksum = 0;
        auto start = MonotonicTime::now();
        function(data.span().data(), data.size(), &tokens, &checksum);
        samples.append((MonotonicTime::now() - start).milliseconds());
        if (!tokens)
            dataLogLn("unexpected: no tokens");
    }
    std::sort(samples.begin(), samples.end());
    double median = samples[samples.size() / 2];
    double rate = median > 0 ? (data.size() / (median / 1000.0)) / (1024.0 * 1024.0) : 0;
    return { median, rate };
}

} // namespace

TEST(HTMLTokenizerSwiftBench, SwiftIslandMatchesCppAndIsCompetitive)
{
    auto data = makeMarkup(8 * 1024 * 1024);

    // Correctness gate: identical token count and name checksum.
    size_t swiftTokens = 0, cppTokens = 0;
    uint64_t swiftChecksum = 0, cppChecksum = 0;
    webCoreTokenizeBenchSwift(data.span().data(), data.size(), &swiftTokens, &swiftChecksum);
    webCoreTokenizeBenchCpp(data.span().data(), data.size(), &cppTokens, &cppChecksum);

    EXPECT_GT(swiftTokens, 0u);
    EXPECT_EQ(swiftTokens, cppTokens);
    EXPECT_EQ(swiftChecksum, cppChecksum);

    auto swift = time(webCoreTokenizeBenchSwift, data);
    auto cpp = time(webCoreTokenizeBenchCpp, data);

    dataLogLn("HTML tokenizer, ", data.size() / (1024 * 1024), " MiB, median of ", iterations, ":");
    dataLogLn("  C++   (goto threading): ", cpp.medianMilliseconds, " ms, ", cpp.megabytesPerSecond, " MB/s");
    dataLogLn("  Swift (loop+switch)   : ", swift.medianMilliseconds, " ms, ", swift.megabytesPerSecond, " MB/s");
    dataLogLn("  ratio swift/c++       : ", swift.megabytesPerSecond / cpp.megabytesPerSecond);
    dataLogLn("  tokens=", swiftTokens, " checksum=", swiftChecksum);
}

} // namespace TestWebKitAPI
