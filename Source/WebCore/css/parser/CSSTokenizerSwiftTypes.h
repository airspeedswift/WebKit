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

// One token as the Swift tokenizer reports it: offsets into the span above, plus
// the small amount of classification CSSParserToken needs. Everything here is
// resolved against the input by CSSTokenizer::tokenizeWithSwiftIsland.
//
// Defined in C++ rather than in Swift on purpose. WebCore compiles Swift with
// -enable-library-evolution, so a Swift struct exposed with @_expose(Cxx) is
// *resilient*: the generated C++ class wraps a heap-allocated opaque box, has no
// default constructor, and its sizeof() is not the Swift struct's size. That is
// fine for a value returned once, but it cannot be an element type of a buffer
// the two languages share. A plain C++ aggregate can, and Swift imports it
// directly.
// Deliberately no default member initializers: with them the type is not
// trivially default constructible, so WTF's Vector runs initialization over the
// whole buffer (VectorTypeOperations::initializeIfNonPOD) before Swift overwrites
// every byte of it. On a large stylesheet that is tens of megabytes of pointless
// zero stores.
struct CSSSwiftToken {
    // Extent of the token in the input.
    uint32_t start;
    uint32_t end;
    // The token's value text: an ident/at-keyword/hash/string/url name, or the
    // unit of a dimension. Normally a range of the input; a range of the chunk's
    // unescape buffer when `flags` has the unescaped bit set.
    uint32_t valueStart;
    uint32_t valueLength;
    // For numeric tokens, the number's text, which is CSSParserToken's
    // originalText and the range converted to a double.
    uint32_t numberStart;
    uint32_t numberLength;
    // Delimiter code point, or the whitespace run length.
    uint32_t extra;

    uint8_t type;
    uint8_t blockType;
    uint8_t flags;
};

// Receives each chunk of tokens the Swift tokenizer produces, and materialises them
// into the CSSTokenizer that owns this sink.
//
// The shape is what makes the boundary safe. Swift owns the buffers and *passes* them,
// which is the direction SafeInteropWrappers can make safe: `__counted_by` plus
// `noescape` on these parameters means Swift sees one method taking two `Span`s, with
// no pointers and no `unsafe`. And the receiver is a refcounted shared reference, which
// Swift imports as an ordinary class reference — the only way for a directly-named
// callee to reach C++ state without a pointer parameter putting the `unsafe` back.
// See swift-cpp-interop-notes.md §67.
class CSSSwiftTokenSink final : public ThreadSafeRefCounted<CSSSwiftTokenSink> {
public:
    WEBCORE_EXPORT static CSSSwiftTokenSink* create(CSSTokenizer&, CSSParserObserverWrapper*);

    // Materialises one chunk. `tokens` index `unescapedUnits` for values that
    // contained escapes, and index the input for everything else. Returns false on
    // allocation failure, which stops the tokenizer.
    WEBCORE_EXPORT bool takeChunk(
        const CSSSwiftToken *__counted_by(tokenCount) tokens __attribute__((noescape)), size_t tokenCount,
        const char16_t *__counted_by(unitCount) unescapedUnits __attribute__((noescape)), size_t unitCount);

    // Called after the last chunk, to give the observer wrapper its final offset.
    WEBCORE_EXPORT void finish();

#ifdef __swift__
    // FIXME: rdar://165684636 means these have to be redeclared at this level of the
    // hierarchy, as WTF::BorrowedBytes also has to.
    void ref() const { ThreadSafeRefCounted<CSSSwiftTokenSink>::ref(); }
    void deref() const { ThreadSafeRefCounted<CSSSwiftTokenSink>::deref(); }
#endif

private:
    CSSSwiftTokenSink(CSSTokenizer& tokenizer, CSSParserObserverWrapper* wrapper)
        : m_tokenizer(tokenizer)
        , m_wrapper(wrapper)
    {
    }

    CSSTokenizer& m_tokenizer;
    CSSParserObserverWrapper* m_wrapper;
    // Mirrors the C++ loop's `offset`: where the next token starts.
    unsigned m_observerOffset { 0 };
} SWIFT_SHARED_REFERENCE(.ref, .deref);

} // namespace WebCore
