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

#include <array>
#include <span>
#include <wtf/text/Latin1Character.h>

namespace PAL {

// Swift cannot name a template instantiation, so the spans crossing into TextCodecUTF8.swift have
// aliases.
using TextCodecUTF8SwiftInput = std::span<const uint8_t>;
using TextCodecUTF8SwiftNarrowDest = std::span<Latin1Character>;
using TextCodecUTF8SwiftWideDest = std::span<char16_t>;
// `TextCodecUTF8::m_partialSequence`; only the first `partialSequenceSize` bytes are meaningful.
using TextCodecUTF8SwiftPartialSequence = std::array<uint8_t, 4>;

// Codec state crosses by value in both directions, so Swift never holds a pointer to the codec. A
// `needsWide` result from the 8-bit half is passed unchanged to the 16-bit half, which resumes from it.
struct TextCodecUTF8SwiftResult {
    uint32_t consumedBytes { 0 };
    uint32_t producedCharacters { 0 };
    TextCodecUTF8SwiftPartialSequence partialSequence { };
    uint8_t partialSequenceSize { 0 };
    bool sawError { false };
    bool stoppedOnError { false };
    bool needsWide { false };
    bool shouldStripByteOrderMark { false };
};

} // namespace PAL
