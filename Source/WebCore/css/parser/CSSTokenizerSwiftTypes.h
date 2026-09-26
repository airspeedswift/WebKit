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

// The WebCore declarations visible to the Swift CSS tokenizer (CSSTokenizerSwift.swift).
//
// This header is its own Clang module (WebCore_Private.modulemap) and must stay self-contained:
// importing all of WebCore_Private reaches JavaScriptCore private headers whose inner structs sit
// in explicit submodules that nothing imports.

#pragma once

#include <WebCore/CSSParserTokenBits.h>
#include <WebCore/PlatformExportMacros.h>
#include <cstddef>
#include <cstdint>
#include <span>
#include <wtf/Assertions.h>
#include <wtf/SwiftBridging.h>
#include <wtf/text/Latin1Character.h>

namespace WebCore {

class CSSParserObserverWrapper;
class CSSTokenizer;

// A view of an already-preprocessed stylesheet. Named aliases because Swift cannot spell
// std::span<const T> directly.
using CSSTokenizerSpan8 = std::span<const Latin1Character>;
using CSSTokenizerSpan16 = std::span<const char16_t>;

// Source offsets for the Web Inspector's observer wrapper, which CSSParserTokenBits has no room
// for. One record per token or comment, in source order.
struct CSSSwiftObserverRecord {
    uint32_t start;
    uint32_t end;
    // Nonzero for a comment, which addComment reports without advancing the token index.
    uint32_t isComment;
};

// Receives each chunk of tokens the Swift tokenizer produces and appends them to the owning
// CSSTokenizer. `__counted_by` plus `noescape` is what makes the importer present the buffer
// parameters to Swift as `Span`s; without either, Swift sees a pointer.
//
// Lives on the caller's stack for the one Swift call it is passed to. `SWIFT_SAFE` asserts that
// the raw pointers below are encapsulated, which holds while every Swift signature takes the sink
// `inout` and no Swift type stores one.
class SWIFT_SAFE CSSSwiftTokenSink {
public:
    CSSSwiftTokenSink(CSSTokenizer& tokenizer LIFETIME_BOUND, CSSParserObserverWrapper* wrapper)
        : m_tokenizer(&tokenizer)
        , m_wrapper(wrapper)
    {
    }

    // Resolves each token's parked value offset, converts numeric values with the C++ scanner's
    // routine, and interns values tagged cssParserTokenBitsUnescapedValueTag, which index
    // `unescapedUnits`. `records` is empty unless wantsObserverRecords(). Returns false on
    // allocation failure or inconsistent input.
    WEBCORE_EXPORT bool takeChunk(
        const CSSParserTokenBits *__counted_by(tokenCount) tokens __attribute__((noescape)), size_t tokenCount,
        const char16_t *__counted_by(unitCount) unescapedUnits __attribute__((noescape)), size_t unitCount,
        const CSSSwiftObserverRecord *__counted_by(recordCount) records __attribute__((noescape)), size_t recordCount);

    // Read once per tokenization.
    bool wantsObserverRecords() const { return m_wrapper; }

    // Called after the last chunk.
    WEBCORE_EXPORT void finish();

private:
    CSSTokenizer* m_tokenizer;
    CSSParserObserverWrapper* m_wrapper;
    unsigned m_observerOffset { 0 };
};

} // namespace WebCore
