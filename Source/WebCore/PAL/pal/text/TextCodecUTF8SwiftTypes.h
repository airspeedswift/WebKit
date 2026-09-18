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

#pragma once

#include <atomic>
#include <pal/ExportMacros.h>
#include <span>
#include <wtf/text/Latin1Character.h>

namespace PAL {

// Named aliases because Swift cannot spell a C++ template instantiation directly.
// `TextCodecUTF8::decode` already holds its input in this form, so nothing is converted or copied.
using TextCodecUTF8SwiftInput = std::span<const uint8_t>;

// The 8-bit half writes straight into `decode`'s own `StringBuffer<Latin1Character>`; the 16-bit
// half into a `StringBuffer<char16_t>`, as a subspan starting past the widened 8-bit prefix, so it
// writes from index zero of what it receives. Swift opens each as a `MutableSpan` with
// `_unsafeCxxSpan:`; the borrow is valid for the duration of the synchronous call.
using TextCodecUTF8SwiftNarrowDest = std::span<Latin1Character>;
using TextCodecUTF8SwiftWideDest = std::span<char16_t>;

// Which shape went to the C++ loop, so that a remaining count names one rather than being a lump.
// Both are partial sequences that only that loop can leave behind -- see
// `handlePartialSequenceNarrow` -- so both go away once nothing but Swift leaves one.
enum class TextCodecUTF8SwiftDeclineReason : uint8_t {
    None = 0,
    // The held sequence's first byte is ASCII.
    ParkedLeadIsASCII = 1,
    // The held sequence is longer than its lead byte's sequence length.
    ParkExceedsLeadLength = 2,
};

// What one decode reports back, as a value, so the whole thing crosses in registers.
//
// `answered` false means Swift read something outside what it covers and did no useful work, so
// `TextCodecUTF8::decode` runs its own loop over the same input from the top. The fields above are
// applied only when it is true, so that case leaves every byte of codec state as it found it, which
// is what makes the C++ loop a re-run rather than a resume.
struct TextCodecUTF8SwiftResult {
    // Bytes taken, including any that went into `partialSequence` below, which can mix bytes held
    // from an earlier call with bytes from this one and so is not recoverable from the input.
    uint32_t consumedBytes { 0 };
    // Characters written. Not derivable from `consumedBytes` -- a character costs one to four input
    // bytes and a four-byte sequence produces two code units -- so the caller cross-checks it with a
    // security assertion before advancing anything.
    uint32_t producedCharacters { 0 };
    // The partial sequence to hold for the next call, packed: byte `i` at bit `8 * i`, only the low
    // `partialSequenceSize` bytes live. Same packing in both directions.
    uint32_t partialSequence { 0 };
    uint8_t partialSequenceSize { 0 };
    // ORed into `decode`'s `sawError`.
    bool sawError { false };
    // `stopOnError` ended the decode with input still undecoded: the one result that leaves
    // `consumedBytes` short of the input.
    bool stoppedOnError { false };
    // The 8-bit half met a character above U+00FF. Mutually exclusive with `stoppedOnError`, and
    // never set by the 16-bit half.
    bool needsWide { false };
    // `m_shouldStripByteOrderMark`'s new value. It crosses in as an argument and back out here, so
    // that Swift is never handed a pointer to codec state. Only the 16-bit half changes it, because
    // only the two 16-bit paths of the decoder this was ported from did: handling a partial
    // sequence, which spends the flag on any character it decodes, and the main loop, which spends
    // it only for a U+FEFF landing at index 0 of the final buffer.
    bool shouldStripByteOrderMark { false };
    TextCodecUTF8SwiftDeclineReason declineReason { TextCodecUTF8SwiftDeclineReason::None };
    bool answered { false };
};

// Which decoder handled an input, since both produce byte-identical output by construction and these
// counters are the only thing that can tell them apart. Relaxed: read after a run, never a
// synchronisation mechanism.
//
// `declined` counts every decode the C++ loop had to handle, which is now the same as the number of
// calls that returned `answered == false`, Swift being offered every decode. The per-reason counters
// sum to it and say which shape is still getting through.
struct TextCodecUTF8SwiftCounters {
    std::atomic<uint64_t> answered { 0 };
    std::atomic<uint64_t> declined { 0 };
    std::atomic<uint64_t> declinedParkedLeadIsASCII { 0 };
    std::atomic<uint64_t> declinedParkExceedsLeadLength { 0 };
};

PAL_EXPORT TextCodecUTF8SwiftCounters& textCodecUTF8SwiftCounters();

// Whether this PAL was built with USE_SWIFT_TEXT_CODEC_UTF8, which is to say which decoder is in
// this binary. The define is private to the PAL target, so a test binary cannot ask the
// preprocessor, and the two decoders are meant to be indistinguishable from their output.
PAL_EXPORT bool textCodecUTF8SwiftEnabled();

// Testing hook: forces `TextCodecUTF8::decode` down its own C++ loop, so that a differential can run
// the same input through both implementations in one process. Without it that loop is unreachable on
// any input Swift handles, which is now every input, leaving only chunking invariance -- which a
// decoder that is wrong the same way in every chunking passes. Not thread-safe; goes away with the
// C++ decoder.
PAL_EXPORT void setTextCodecUTF8SwiftDisabledForTesting(bool);

} // namespace PAL
