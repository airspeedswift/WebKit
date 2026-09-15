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

// The input a decode attempt reads. Named because Swift cannot spell a C++ template
// instantiation directly, and `TextCodecUTF8::decode` already holds its argument in exactly
// this form -- so nothing is converted, packed or copied to produce it.
using TextCodecUTF8SwiftInput = std::span<const uint8_t>;

// Where the narrow phase writes its Latin-1 output. The Swift arm writes directly into
// `TextCodecUTF8::decode`'s own `StringBuffer<Latin1Character>`, bypassing any intermediate
// scratch buffer. Swift initialises a `MutableSpan<UInt8>` from this span with
// `_unsafeCxxSpan:`; the borrow is valid for the duration of the synchronous call.
using TextCodecUTF8SwiftNarrowDest = std::span<Latin1Character>;

// Where the wide phase writes its UTF-16 output. C++ allocates a `StringBuffer<char16_t>`
// and passes a subspan starting at the narrow prefix length, so the wide arm writes from
// index zero of what it receives. Same borrow guarantee as the narrow destination.
using TextCodecUTF8SwiftWideDest = std::span<char16_t>;

// What one attempt reports back. A value, so the whole thing crosses in registers.
//
// `answered` false means the Swift arm DECLINED: it read something outside the subset it
// covers and did no useful work, so `TextCodecUTF8::decode` runs its own loop over the same
// input from the top. The two park fields below are applied only when `answered` is true --
// a decline leaves every byte of codec state as it found it, which is what makes the fallback
// a re-run rather than a resume.
struct TextCodecUTF8SwiftResult {
    // Bytes of the input the Swift arm took, INCLUDING any that went into the partial sequence
    // it reports below. That park can mix bytes that were already parked with bytes from this
    // call, so it is not recoverable from the input the way a park made only of trailing bytes
    // would be: it crosses explicitly, and the byte count says how far the input advanced.
    uint32_t consumedBytes { 0 };
    // Characters written to the destination. Used to advance `destination` in the narrow case
    // and to size `buffer16.shrink` in the wide case.
    //
    // A `uint32_t` and not derivable from `consumedBytes`: a character costs one to four input
    // bytes, and a four-byte sequence produces TWO code units. Checked by a security assertion
    // in the C++ caller before being used to advance any pointer.
    uint32_t producedCharacters { 0 };
    // The partial sequence to park, PACKED: byte `i` of the sequence sits at bit `8 * i`, and
    // only the low `partialSequenceSize` bytes carry anything. The same packing is what
    // `TextCodecUTF8::decode` hands Swift for the sequence already parked on entry.
    uint32_t partialSequence { 0 };
    // How many bytes of `partialSequence` are live, 0 to 4.
    uint8_t partialSequenceSize { 0 };
    // Whether the arm met an ill-formed sequence. ORed into `decode`'s `sawError`.
    bool sawError { false };
    // Whether `stopOnError` ended the decode at an ill-formed sequence with input still
    // undecoded. The one thing that breaks "the arm consumed the whole input".
    bool stoppedOnError { false };
    // Whether the narrow arm stopped because it met a character above U+00FF. The caller
    // allocates a 16-bit buffer, widens the narrow prefix, and calls the wide arm to continue.
    // Mutually exclusive with `stoppedOnError`: the narrow arm sets this only when it has NOT
    // stopped early, and the wide arm never sets it.
    bool needsWide { false };
    bool answered { false };
};

// Coverage, and it is here from the first commit rather than retrofitted.
//
// A DECLINE IS INVISIBLE. A declining arm and an agreeing arm produce byte-identical output
// by construction -- the fallback is the very code the differential compares against -- so
// no correctness harness can tell them apart. These two counters are the only thing that
// does. Relaxed: a census read after a run, never a synchronisation mechanism.
struct TextCodecUTF8SwiftCounters {
    std::atomic<uint64_t> answered { 0 };
    std::atomic<uint64_t> declined { 0 };
};

PAL_EXPORT TextCodecUTF8SwiftCounters& textCodecUTF8SwiftCounters();

} // namespace PAL
