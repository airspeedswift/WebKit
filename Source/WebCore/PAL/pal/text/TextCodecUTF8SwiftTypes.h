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
#include <memory>
#include <pal/ExportMacros.h>
#include <span>
#include <wtf/SwiftBridging.h>
#include <wtf/ThreadSafeRefCounted.h>
#include <wtf/text/Latin1Character.h>
#include <wtf/text/StringBuffer.h>

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
// not advancing the destination, and the two park fields below are applied only when
// `answered` is true -- a decline leaves every byte of codec state as it found it, which is
// what makes the fallback a re-run rather than a resume.
struct TextCodecUTF8SwiftResult {
    // Bytes of the input the Swift arm took, INCLUDING any that went into the partial sequence
    // it reports below. That park can mix bytes that were already parked with bytes from this
    // call, so it is not recoverable from the input the way a park made only of trailing bytes
    // would be: it crosses explicitly, and the byte count says how far the input advanced.
    uint32_t consumedBytes { 0 };
    // Characters produced, which is NOT derivable from `consumedBytes`: a character costs one,
    // two, three or four input bytes, and a four-byte one produces TWO code units. The caller
    // checks this against the sink's own count, because nothing else would notice a Swift
    // accounting bug -- the sink's bound check is against the buffer, not against the arm's
    // arithmetic, so a miscount would hand back a correctly filled buffer shrunk to the wrong
    // length.
    uint32_t producedCharacters { 0 };
    // The partial sequence to park, PACKED: byte `i` of the sequence sits at bit `8 * i`, and
    // only the low `partialSequenceSize` bytes carry anything. The same packing is what
    // `TextCodecUTF8::decode` hands Swift for the sequence already parked on entry.
    //
    // A `uint32_t` and not a `uint8_t[4]`: an array member imports awkwardly into Swift, and a
    // `std::span` over `m_partialSequence` would need the unsafe C++-span initializer on the
    // other side, while four bytes and a count cross in registers with no array import at all.
    // The bit position is the byte's index within the sequence and NOTHING ELSE, so the value
    // means the same on a big-endian host as on a little-endian one -- stated because an
    // arm64-only differential cannot catch a packing-order mistake here.
    uint32_t partialSequence { 0 };
    // How many bytes of `partialSequence` are live, 0 to 4. Only ever non-zero when the arm
    // answered and `flush` was false: `TextCodecUTF8::decode` ends a flushing call with
    // `m_partialSequenceSize = 0` whichever exit it takes, so a park never survives one.
    uint8_t partialSequenceSize { 0 };
    // Whether the arm met an ill-formed sequence. It is ORed into `TextCodecUTF8::decode`'s
    // `sawError` out parameter rather than assigned: that parameter is a sticky flag owned by
    // the caller -- `TextResourceDecoder` never clears it -- and the C++ only ever sets it
    // true, so the arm may set it as freely as the loops do.
    bool sawError { false };
    // Whether `stopOnError` ended the decode at an ill-formed sequence with input still
    // undecoded.
    //
    // This is the one thing that breaks "the arm consumed the whole input", and it breaks it
    // deliberately: `stopOnError` makes each loop `break`, which SILENTLY DISCARDS the bytes it
    // has not reached, so the arm reports where it stopped and the caller drops the remainder.
    // A field rather than something the caller derives from `sawError && stopOnError`, which
    // does imply it: the rule the loops depend on is that they have nothing left to decode, and
    // that is worth stating by the arm that knows it rather than reconstructing.
    bool stoppedOnError { false };
    bool answered { false };
};

// Receives the characters a decode attempt produces, at either output width.
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

    // Appends one chunk of finished 16-bit characters, and on its first call takes ownership of
    // the 16-bit buffer they go into.
    //
    // WHY THE WIDTH IS SWIFT'S TO CHOOSE, LAZILY, AND NOT THE CALLER'S UP FRONT. Which width an
    // input needs depends on validity, not on byte values -- `0xC3 0x41` decodes to U+00C3
    // followed by a replacement character, so it forces 16-bit output when `stopOnError` is
    // false and stays 8-bit when it is true -- so a correct pre-scan IS a decode, and pricing
    // one would also mean the 8-bit loop this island replaces could never become dead code.
    // Always producing 16-bit and narrowing afterwards is worse still: `StringImpl::adopt`
    // retains the allocation as it stands, so an all-ASCII decode would hold a 2N-byte buffer
    // for the string's lifetime and every `is8Bit()` in the engine would change answer.
    //
    // So the flip happens where the first character above U+00FF is met, and it is one-way: the
    // characters already written to the 8-bit destination are widened into the new buffer, and
    // every chunk after that arrives here. `m_written` spans the flip, so `writtenCharacters()`
    // keeps meaning what it meant. `takeChunk` asserts the ordering rather than trusting it.
    PAL_EXPORT void takeWideChunk(const char16_t *__counted_by(count) characters __attribute__((noescape)), size_t count);

    size_t writtenCharacters() const { return m_written; }

#if !defined(__swift__)
    // Null unless the decode widened, and hidden from the importer for `create`'s reason: it
    // hands out a pointer into WTF-owned storage, which is not a convention worth teaching the
    // importer when only `TextCodecUTF8::decode` ever reads it.
    StringBuffer<char16_t>* wideBuffer() LIFETIME_BOUND { return m_wideBuffer.get(); }
#endif

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
    // Allocated on the first `takeWideChunk`, so the Latin-1 majority never pays for it.
    std::unique_ptr<StringBuffer<char16_t>> m_wideBuffer;
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
