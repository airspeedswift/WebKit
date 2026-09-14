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
#include <wtf/SwiftBridging.h>
#include <wtf/ThreadSafeRefCounted.h>
#include <wtf/text/Latin1Character.h>

namespace PAL {

// The input a decode attempt reads. Named because Swift cannot spell a C++ template
// instantiation directly, and `TextCodecUTF8::decode` already holds its argument in exactly
// this form -- so nothing is converted, packed or copied to produce it.
using TextCodecUTF8SwiftInput = std::span<const uint8_t>;

// What one attempt reports back. A value, so the whole thing crosses in registers.
//
// `answered` false means the Swift arm DECLINED: it read something outside the subset it
// covers and did no useful work, so `TextCodecUTF8::decode` runs its own loop over the same
// input from the top. Anything the sink was handed before the decline is discarded by simply
// not advancing the destination -- a decline touches no codec state, which is what makes the
// fallback a re-run rather than a resume.
struct TextCodecUTF8SwiftResult {
    // Input bytes the Swift arm consumed and turned into characters, NOT counting the
    // trailing partial sequence below.
    uint32_t consumedBytes { 0 };
    // Bytes of a truncated sequence at the very end of the input, which the caller parks in
    // `m_partialSequence` to be completed by the next chunk. Only ever non-zero when the
    // arm answered and `flush` was false; a truncated sequence at a flush is a decline,
    // because that is where the C++ turns it into a replacement character and upconverts.
    uint8_t partialSequenceSize { 0 };
    bool answered { false };
};

// Receives the Latin-1 characters a decode attempt produces.
//
// WHY A SINK AND NOT A BUFFER PARAMETER. Swift can PASS a bounds-carrying view to C++ but can
// never RECEIVE one, in either mutability: an `@_expose(Cxx)` parameter of `Span` type is
// silently dropped from the generated header, and an imported `std::span` needs
// `Span(_unsafeCxxSpan:)`, which is `@unsafe`. So "C++ owns the destination and hands Swift a
// `MutableSpan` into it" is not available at `unsafe` = 0. Inverting it is: Swift owns a
// temporary, fills it, and passes it here, where `__counted_by` plus `noescape` makes the
// parameter import as one `Span<Latin1Character>` with no pointer and no `unsafe` marker.
// This is `CSSSwiftTokenSink::takeChunk`'s mechanism, applied to a boundary whose payload is
// bytes rather than tokens.
//
// The cost of that inversion is one extra pass over the output: Swift's temporary, then this
// memcpy. It is chunked so the temporary stays L1-resident, and it is the number to quote
// when pricing rdar://186723514 -- not a reason to reach for the unsafe spelling first.
//
// A reference type, because a directly-named Swift callee can only reach C++ state through a
// receiver; a pointer parameter would put `unsafe` back. Refcounted rather than immortal: the
// sink is a per-`decode` object, and asserting immortality of something that is not immortal
// is the kind of unchecked claim this project declines to make for a couple of atomics.
class TextCodecUTF8SwiftSink final : public ThreadSafeRefCounted<TextCodecUTF8SwiftSink> {
public:
#if !defined(__swift__)
    // Hidden from the importer: it returns +1 as a raw pointer, which is not a convention the
    // importer can be told without also promising SWIFT_RETURNED_AS_UNRETAINED_BY_DEFAULT.
    // Only `TextCodecUTF8::decode` makes one; Swift only ever receives one.
    PAL_EXPORT static TextCodecUTF8SwiftSink* create(std::span<Latin1Character> destination);
#endif

    // Appends one chunk of finished characters. There is nothing to decide here and no
    // dispatch to redo: every character has already been decoded, and what is left is the
    // copy into storage only WTF can allocate.
    PAL_EXPORT void takeChunk(const Latin1Character *__counted_by(count) characters __attribute__((noescape)), size_t count);

    size_t writtenCharacters() const { return m_written; }

#ifdef __swift__
    // FIXME: rdar://165684636 means these have to be redeclared at this level of the
    // hierarchy for the importer to see them.
    void ref() const { ThreadSafeRefCounted<TextCodecUTF8SwiftSink>::ref(); }
    void deref() const { ThreadSafeRefCounted<TextCodecUTF8SwiftSink>::deref(); }
#endif

private:
    // Not hidden from the importer, unlike the stand-in pattern the JSC islands use for
    // containers over inner structs: a `std::span` member would normally make a by-value
    // parameter of this type import `@unsafe`, but a type imported as a *reference* is
    // exempt, and both views therefore agree on the layout with nothing to static_assert.
    explicit TextCodecUTF8SwiftSink(std::span<Latin1Character> destination)
        : m_destination(destination)
    {
    }

    std::span<Latin1Character> m_destination;
    size_t m_written { 0 };
} SWIFT_SHARED_REFERENCE(.ref, .deref);

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
