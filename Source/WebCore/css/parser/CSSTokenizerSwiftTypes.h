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

// Everything the Swift CSS tokenizer is allowed to see of WebCore, and nothing else.
//
// This header is its own Clang module (WebCore_Private.modulemap), so it can state
// exactly what Swift may reach. Importing all of WebCore_Private walks into
// JavaScriptCore's private headers, where AbstractModuleRecord::ImportEntry and
// JSModuleNamespaceObject::ExportEntry sit in explicit submodules nothing imports,
// which breaks WTF::KeyValuePair's instantiation over them.
//
// Same shape as JavaScriptCore's LiteralParserSwiftTypes.h, for the same reason.
// Self-contained, so it drags no WebCore internals into a module of its own.

#pragma once

#include <cstddef>
#include <cstdint>
#include <span>
#include <WebCore/CSSParserTokenBits.h>
#include <WebCore/PlatformExportMacros.h>
#include <wtf/SwiftBridging.h>
#include <wtf/ThreadSafeRefCounted.h>
#include <wtf/text/Latin1Character.h>

namespace WebCore {

class CSSParserObserverWrapper;
class CSSTokenizer;

// A view of an already-preprocessed stylesheet. Named aliases because Swift cannot spell
// std::span<const T> directly.
using CSSTokenizerSpan8 = std::span<const Latin1Character>;
using CSSTokenizerSpan16 = std::span<const char16_t>;

// The source offsets the web inspector's observer wrapper needs, which a finished token does
// not carry: CSSParserTokenBits stores no extent and must not grow. One record per thing the
// wrapper is told about, in source order; a comment needs one too, because addComment wants its
// extent and the number of tokens preceding it.
struct CSSSwiftObserverRecord {
    uint32_t start;
    uint32_t end;
    // Nonzero for a comment, which addComment reports without advancing the token index. Not a
    // bool, so the record stays a 12-byte aggregate of one type.
    uint32_t isComment;
};

// Receives each chunk of tokens the Swift tokenizer produces and materialises them into the
// CSSTokenizer that owns this sink. `__counted_by` plus `noescape` on the buffer parameters is
// what makes the importer present them to Swift as `Span`s; dropping either annotation puts a
// pointer, and an `unsafe` marker, back on the Swift side.
class CSSSwiftTokenSink final : public ThreadSafeRefCounted<CSSSwiftTokenSink> {
public:
#if !defined(__swift__)
    // Hidden from the importer: it returns +1 as a raw pointer without the
    // SWIFT_RETURNED_AS_UNRETAINED_BY_DEFAULT that tells the importer what to do with a returned
    // reference. Only CSSTokenizer creates a sink, and Swift only ever receives one.
    WEBCORE_EXPORT static CSSSwiftTokenSink* create(CSSTokenizer&, CSSParserObserverWrapper*);
#endif

    // Materialises one chunk of finished tokens. A token's parked value offset becomes a pointer
    // here, and a numeric token's double is converted here so that rounding stays bit-identical
    // with the C++ scanner. A value whose offset carries cssParserTokenBitsUnescapedValueTag
    // indexes `unescapedUnits` rather than the input, and is interned into the string pool.
    // `records` is empty unless wantsObserverRecords(). Returns false on allocation failure.
    WEBCORE_EXPORT bool takeChunk(
        const CSSParserTokenBits *__counted_by(tokenCount) tokens __attribute__((noescape)), size_t tokenCount,
        const char16_t *__counted_by(unitCount) unescapedUnits __attribute__((noescape)), size_t unitCount,
        const CSSSwiftObserverRecord *__counted_by(recordCount) records __attribute__((noescape)), size_t recordCount);

    // Whether to fill the observer record buffer at all. Read once per tokenization.
    bool wantsObserverRecords() const { return m_wrapper; }

    // Called after the last chunk, to give the observer wrapper its final offset.
    WEBCORE_EXPORT void finish();

#ifdef __swift__
    // FIXME: rdar://165684636 means these have to be redeclared at this level of the
    // hierarchy for the importer to see them.
    void ref() const { ThreadSafeRefCounted<CSSSwiftTokenSink>::ref(); }
    void deref() const { ThreadSafeRefCounted<CSSSwiftTokenSink>::deref(); }
#endif

private:
    CSSSwiftTokenSink(CSSTokenizer& tokenizer, CSSParserObserverWrapper* wrapper, std::span<const uint8_t> inputBytes, unsigned characterSize)
        : m_tokenizer(tokenizer)
        , m_wrapper(wrapper)
        , m_inputBytes(inputBytes)
        , m_characterSize(characterSize)
    {
    }

    CSSTokenizer& m_tokenizer;
    CSSParserObserverWrapper* m_wrapper;
    // The input as bytes, for resolveValuePointer, plus the width the offsets are counted in.
    std::span<const uint8_t> m_inputBytes;
    unsigned m_characterSize { 1 };
    // Where the next reported token starts.
    unsigned m_observerOffset { 0 };
} SWIFT_SHARED_REFERENCE(.ref, .deref);

} // namespace WebCore
