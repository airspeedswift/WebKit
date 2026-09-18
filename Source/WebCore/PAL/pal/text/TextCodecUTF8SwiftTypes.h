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
    bool answered { false };
};

// Which decoder handled an input, since both produce byte-identical output by construction and these
// counters are the only thing that can tell them apart. Relaxed: read after a run, never a
// synchronisation mechanism.
struct TextCodecUTF8SwiftCounters {
    std::atomic<uint64_t> answered { 0 };
    std::atomic<uint64_t> declined { 0 };
};

PAL_EXPORT TextCodecUTF8SwiftCounters& textCodecUTF8SwiftCounters();

} // namespace PAL
