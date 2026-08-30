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

// Everything the Swift CSS tokenizer island (CSSTokenizerSwift.swift) is allowed to
// see of WebCore, and nothing else.
//
// Kept in its own header because it is also its own Clang module
// (WebCore_Private.modulemap). The island used to `import WebCore_Private`, which is
// an umbrella over every one of WebCore's ~3,500 private headers; walking it reaches
// JavaScriptCore's private headers, where the definitions of
// AbstractModuleRecord::ImportEntry and JSModuleNamespaceObject::ExportEntry sit in
// explicit submodules that nothing imports, and WTF::KeyValuePair's instantiation
// over them then fails to compile. Importing only this header is both the fix and a
// better boundary: it states what the island may reach.
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

// A contiguous view of an already-preprocessed stylesheet. This is what the Swift
// tokenizer island takes instead of the input stream itself, because a token carrying
// offsets into this span is all CSSParserToken needs. Named aliases because Swift
// cannot spell std::span<const T> directly.
using CSSTokenizerSpan8 = std::span<const Latin1Character>;
using CSSTokenizerSpan16 = std::span<const char16_t>;

// What the web inspector's observer wrapper needs and a finished token no longer carries.
//
// The island used to hand every token its extent, because the boundary struct was a
// description of a token rather than a token, and there was room. Now that it emits
// CSSParserTokenBits -- which is CSSParserToken's own storage, and stores no extent -- the two
// offsets have to travel beside the tokens instead. They travel in a *separate* buffer, filled
// only when there is an observer, because the observer is a devtools-only path: production
// tokenization writes no records at all and an empty UniqueArray costs three words and no
// allocation, where widening every token by eight bytes would have cost chunk cache residency
// on every stylesheet ever parsed.
//
// One record per thing the wrapper is told about, in source order, which is why comments need a
// record even though they are not tokens: addComment wants the extent and how many tokens
// preceded it. C++ walks these keeping its own running token index, so nothing has to be
// counted twice.
struct CSSSwiftObserverRecord {
    uint32_t start;
    uint32_t end;
    // A comment: report it with addComment and do not advance the token index. Otherwise a
    // token, reported with addToken. Not a `bool`, so the record stays a 12-byte aggregate of
    // one type.
    uint32_t isComment;
};

// Receives each chunk of tokens the Swift tokenizer produces, and materialises them
// into the CSSTokenizer that owns this sink.
//
// The shape is what makes the boundary safe. Swift owns the buffers and *passes* them,
// which is the direction SafeInteropWrappers can make safe: `__counted_by` plus
// `noescape` on these parameters means Swift sees one method taking three `Span`s, with
// no pointers and no `unsafe`. And the receiver is a refcounted shared reference, which
// Swift imports as an ordinary class reference — the only way for a directly-named
// callee to reach C++ state without a pointer parameter putting the `unsafe` back.
// See swift-cpp-interop-notes.md §67.
class CSSSwiftTokenSink final : public ThreadSafeRefCounted<CSSSwiftTokenSink> {
public:
#if !defined(__swift__)
    // Hidden from the importer deliberately. It returns +1 as a raw pointer, and every other
    // SWIFT_SHARED_REFERENCE in WebKit pairs the annotation with SWIFT_RETURNED_AS_UNRETAINED_BY_DEFAULT
    // (Connection.h, APIObject.h and eight others) precisely so the importer knows what to do
    // with a returned reference. Rather than assert a convention this factory does not follow,
    // hide it: only CSSTokenizer creates the sink, Swift only ever receives one, and a
    // constructor Swift cannot see is a question that cannot be got wrong.
    WEBCORE_EXPORT static CSSSwiftTokenSink* create(CSSTokenizer&, CSSParserObserverWrapper*);
#endif

    // Materialises one chunk of finished tokens.
    //
    // `tokens` are CSSParserToken's own storage, already classified: the only thing left to do
    // to one is turn its parked value offset into a pointer, which is branch-free, and convert
    // the double for a numeric token, which C++ keeps so that rounding stays bit-identical with
    // the C++ scanner. A value whose offset carries cssParserTokenBitsUnescapedValueTag indexes
    // `unescapedUnits` instead of the input and has to be interned into the string pool.
    //
    // `records` is empty unless wantsObserverRecords() said otherwise. Returns false on
    // allocation failure, which stops the tokenizer.
    WEBCORE_EXPORT bool takeChunk(
        const CSSParserTokenBits *__counted_by(tokenCount) tokens __attribute__((noescape)), size_t tokenCount,
        const char16_t *__counted_by(unitCount) unescapedUnits __attribute__((noescape)), size_t unitCount,
        const CSSSwiftObserverRecord *__counted_by(recordCount) records __attribute__((noescape)), size_t recordCount);

    // Whether to fill the observer record buffer at all. The island reads this once, at the top
    // of a tokenization, so that the production path -- which has no observer, and is every
    // stylesheet the engine loads -- writes no records and allocates nothing for them. Asking
    // the sink rather than taking a parameter keeps the two exposed entry points' signatures
    // unchanged, and this is the answer's only home: the wrapper is the sink's business.
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
    // Held here rather than recomputed per chunk because the width is a property of the
    // tokenization: CSSTokenizer branches on it once, to pick which of the island's two
    // specializations to run, and the RefPtr<StringImpl> behind it outlives this sink.
    std::span<const uint8_t> m_inputBytes;
    unsigned m_characterSize { 1 };
    // Mirrors the C++ loop's `offset`: where the next token starts.
    unsigned m_observerOffset { 0 };
} SWIFT_SHARED_REFERENCE(.ref, .deref);

} // namespace WebCore
