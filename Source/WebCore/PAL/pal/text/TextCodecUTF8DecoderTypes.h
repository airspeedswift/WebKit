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

#include <cstddef>
#include <cstdint>
#include <span>
#include <wtf/text/Latin1Character.h>

// The values that cross between TextCodecUTF8::decode and the Swift UTF-8 decoder
// (TextCodecUTF8.swift).

namespace PAL {

using UTF8ByteSequence = std::span<const uint8_t>;
using Latin1CharacterSpan = std::span<Latin1Character>;
using UTF16CharacterSpan = std::span<char16_t>;

// A TextCodecUTF8's decoding state: the held partial sequence and whether a byte order mark at the
// start of the stream is still to be stripped. The partial sequence's bytes are fields, in order,
// because Swift has no element access to a std::array.
struct TextCodecUTF8DecoderState {
    uint8_t partialSequence0;
    uint8_t partialSequence1;
    uint8_t partialSequence2;
    uint8_t partialSequence3;
    uint8_t partialSequenceSize;
    bool shouldStripByteOrderMark;
};

struct TextCodecUTF8DecodeResult {
    // The decoding state at the end of the call.
    TextCodecUTF8DecoderState state;
    // How many bytes of the byte sequence were consumed.
    size_t bytesRead;
    // How many characters the destination holds, including any characters it held before the call.
    size_t charactersWritten;
    bool sawError;
    // The 8-bit decoder stopped at a character that is not Latin-1, at an invalid partial sequence, or
    // at an invalid sequence in the byte sequence when not stopping on error; decoding continues with
    // the 16-bit decoder from `state` and `bytesRead`.
    bool needsUpconvert;
};

} // namespace PAL
