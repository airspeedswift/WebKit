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

// Everything WebCore's Swift CSS islands are allowed to see of WebCore, and nothing else:
// the tokenizer island (CSSTokenizerSwift.swift) and the colour fast-path island
// (CSSParserFastPathsSwift.swift).
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

#include <array>
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

// MARK: - The colour fast-path island's boundary (CSSParserFastPathsSwift.swift)

// How many code units of a candidate colour string the island is shown.
//
// Bounded below by coverage and above by the calling convention, and both bounds are tight.
//
// It must be at least 21, because the longest CSS named colour is `lightgoldenrodyellow` at 20 --
// which is not a guess but the `MAX_WORD_LENGTH = 20` gperf computes from ColorData.gperf's 152
// keys, visible in the generated DerivedSources/WebCore/ColorData.cpp. A hex colour needs only
// nine (`#` plus eight digits). So a candidate longer than this is not a colour of either kind,
// which is why the island answers `notAColor` rather than declining for one; the C++ glue ASSERTs
// that against parseNamedColorInternal on every debug run, and colorcheck sweeps every length
// from 0 to 70 against the C++ to prove it.
//
// It must be at most 24, and that is a *measured* bound rather than a taste. A
// `CSSSwiftColorText<Latin1Character>` at capacity 24 is 28 bytes and the interop ABI hands it to
// Swift in registers; at capacity 32 it is 36 bytes, crosses by address, and the island copies it
// onto its own frame -- `ldp q0, q1` / `stp q0, q1` in the entry's prologue, a second copy on top
// of the one makeSwiftColorText already made. That cost 0.63-0.68 of the C++ on the colour
// micro-benchmark. Probe and the full matrix: cssprobe/probes/colorboundary/matrix.sh.
static constexpr size_t cssSwiftColorTextCapacity = 24;

// A candidate colour string, crossing into Swift *by value*.
//
// This is why the colour island has no `unsafe` marker at all, where the tokenizer island
// has two. An island entry point is a Swift *callee*, and `@_expose(Cxx)` cannot express a
// `Span<T>` parameter -- the generated header emits "Parameter is not representable in C++"
// in place of the function (filings register §27) -- so an entry that receives a *buffer*
// has to take an imported `std::span` and convert it with `Span(_unsafeCxxSpan:)`, which is
// `@unsafe` and `@_unsafeNonescapableResult`. `std::span` is itself an `@unsafe` imported
// type, so even indexing one costs a marker; there is no spelling of a borrowed buffer that
// crosses this direction safely today.
//
// A value carries no lifetime, so the whole question disappears. `std::array<T, N>` holds no
// pointer, is therefore not an unsafe imported type, and its `operator[]` imports as an
// ordinary Swift subscript -- so the island reads `text.units[i]` with no marker, and the
// index is provably below the *constant* capacity rather than below something the importer
// has to be trusted about. Nothing is asserted that is not true: the input really is a
// value here.
//
// `length` is the string's true length, which may exceed the capacity; `units` holds its
// first `min(length, capacity)` code units and is zero-filled beyond them, so no index below
// the capacity is indeterminate and the boundary carries no fill-length convention. The island
// spells the capacity as a literal, because `InlineArray`'s count must be one and a `let` global
// initialised from this constant would be lazily initialised behind a `swift_once` on a hot path;
// CSSParserFastPaths.cpp static_asserts the two together.
// A template so one definition serves both of StringImpl's widths, since a colour string
// reaches the fast path before any tokenizer exists and is whatever width the property value
// was stored at.
template<typename CharacterType> struct CSSSwiftColorText {
    std::array<CharacterType, cssSwiftColorTextCapacity> units;
    uint32_t length;
};

// Named aliases, because Swift cannot spell a C++ template instantiation directly.
using CSSSwiftColorText8 = CSSSwiftColorText<Latin1Character>;
using CSSSwiftColorText16 = CSSSwiftColorText<char16_t>;

// What a colour scan produces: a packed sRGB colour and which of three things happened.
//
// `argb` is `PackedColor::ARGB`'s representation -- 0xAARRGGBB -- for every outcome the
// island produces, including the 8-digit hex form whose input order is RGBA, so the C++ side
// has exactly one conversion (`asSRGBA(PackedColor::ARGB { argb })`) rather than one per
// form. `outcome` is a `CSSSwiftColorOutcome` raw value; the numbering is declared once, in
// Swift, and static_asserted against these names in CSSParserFastPaths.cpp.
struct CSSSwiftColor {
    uint32_t argb;
    uint8_t outcome;
};

// The named-colour table lookup, which stays in C++ because it is generated.
//
// `findColor` is gperf output over ColorData.gperf's 152 keys (HashTools.h:29) and returns a
// pointer into a static table, so the island calls it rather than copying it -- a duplicated
// table is exactly the kind of hand-transcribed goop this port exists to avoid. This wrapper
// is the safe shape of that call: `__counted_by` plus `noescape` makes the importer hand
// Swift a single `Span<Latin1Character>` parameter, so the island passes its folded buffer
// down with no pointer, no length beside it and no `unsafe`.
//
// It also drops a NUL the callee never needed. `finishParsingNamedColor` writes
// `buffer.back() = '\0'` and passes `buffer.size() - 1`, but gperf's `findColorImpl` reads
// only `str[0 .. len-1]` -- the `s[len] == '\0'` it tests is the *table* entry's terminator,
// not the argument's -- so the terminator, the +1 on the span it is written into, and the
// `size() - 1` that undoes it are all dead. Taking a plain span removes an unchecked
// decrement and a `back()` on a span whose non-emptiness only the caller's arithmetic
// established.
CSSSwiftColor cssSwiftFindNamedColor(const Latin1Character *__counted_by(length) name __attribute__((noescape)), size_t length);

} // namespace WebCore
