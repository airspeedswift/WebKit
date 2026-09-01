/*
 * Copyright (C) 2025 Apple Inc. All rights reserved.
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

// The CombinedURLFilters island's boundary. Its own explicit module in WebCore_Private.modulemap,
// like CSSTokenizerSwiftTypes and CSSCalcSwiftTypes, because importing WebCore_Private.Core's
// umbrella from Swift does not build.
//
// Almost everything the island needs was ALREADY importable and is simply named here: `Term`,
// `NFA`, `ImmutableNFANodeBuilder` and `CombinedFiltersAlphabet` all carry SWIFT_SAFE at their
// type declarations and cost zero `unsafe` markers (cxprobe/termimport). What this header adds is
// the two things a C++ caller cannot hand Swift directly: the NFA sink, because a `WTF::Function`
// cannot be called from Swift, and the pattern in flight, because a Swift function exposed to C++
// cannot take a `Span` (filings register §27) and a `Term` has no crossing that is both cheap and
// honest about lifetime. Both are borrowed for one call and never stored.

#if ENABLE(CONTENT_EXTENSIONS)

#include <WebCore/CombinedFiltersAlphabet.h>
#include <WebCore/ImmutableNFANodeBuilder.h>
#include <WebCore/NFA.h>
#include <WebCore/Term.h>
#include <wtf/Function.h>
#include <wtf/SwiftBridging.h>
#include <wtf/Vector.h>

namespace WebCore {

namespace ContentExtensions {

// One pattern in flight, as the island can see it: the `Vector<Term>` that
// `CombinedURLFilters::addPattern` was handed, plus the alphabet that turns a `Term` into an id.
//
// WHY IT EXISTS. The island stores term ids and cannot hold a `Term` -- `Term` is a union with a
// `Vector<Term>` alternative, so a Term crossing by value is a deep copy, and a Term crossing by
// reference is a lifetime claim `CombinedFiltersAlphabet.h` declined to make. So before this, the
// caller interned EVERY term up front and handed over ids. That is behaviour-identical to the
// C++'s lazy interning (same set, same order, same ids -- 3e2a32f8ecb3) and it is not
// performance-identical: it turns 102,588 `interned()` calls into 1,112,304 on a real 26,664-rule
// blocker list, and the alphabet went from 4.7% of the C++'s insert self-time to 47.3% of the
// island's. Revisit log R124.
//
// This is the island asking the two questions the C++ sibling scan asks, about a term it never
// sees: "does the term named by this id equal the pattern's term at this index" and, only on a
// miss, "intern that term". No representation is translated and nothing is buffered -- it is the
// same borrowed-callable shape as `CombinedURLFiltersNFASink` below, in the same direction.
//
// It also makes the boundary PER PATTERN rather than per term, which is the shape
// `CombinedURLFilters::addPattern` already has. That is not a convenience either: Swift's dynamic
// exclusivity enforcement is per access to a stored property of a class, and a per-term boundary
// forced ~1.1M of them where a per-pattern one takes a single `inout` access covering the whole
// pattern (R124 measured 1,979,975 `swift_beginAccess` calls against the C++ arm's zero).
//
// SWIFT_SAFE: both members are references the caller owns across the whole call. The object is
// constructed on `CombinedURLFilters::addPattern`'s stack, passed to Swift by reference for the
// duration of that one call, and never stored on the Swift side.
class SWIFT_SAFE CombinedURLFiltersPattern {
public:
    CombinedURLFiltersPattern(CombinedFiltersAlphabet& alphabet, const Vector<Term>& terms)
        : m_alphabet(alphabet)
        , m_terms(terms)
    {
    }

    // `size_t`, not `uint32_t`, and deliberately: an index that narrows at the boundary is exactly
    // the defect R125 shipped, and `Vector::size()` is a `size_t`. Swift spells it `UInt`.
    size_t termCount() const { return m_terms.size(); }

    // `CombinedURLFilters::addPattern`'s sibling-scan comparison, by id on one side and by index
    // on the other. Both subscripts are bounds-checked: `Vector::at` calls `CrashOnOverflow`.
    bool termMatches(size_t index, uint32_t termId) const
    {
        return m_alphabet.term(termId) == m_terms[index];
    }

    // Interns the pattern's term at `index`, which the C++ does only when it appends an edge.
    uint32_t intern(size_t index) { return m_alphabet.interned(m_terms[index]); }

private:
    CombinedFiltersAlphabet& m_alphabet;
    const Vector<Term>& m_terms;
};

// `processNFAs` hands every finished NFA to a `Function<bool(NFA&&)>`, and a WTF::Function is not
// something Swift can call. This is the same shape the CSS tokenizer island uses for the reverse
// direction (CSSSwiftTokenSink): a borrowed reference to the C++ callable, with one method, no
// representation translated and nothing buffered.
//
// SWIFT_SAFE: the sole member is a reference to a Function the caller owns across the whole call.
// It is constructed on `CombinedURLFilters::processNFAs`' stack, passed to Swift by reference for
// the duration of that one call, and never stored on the Swift side.
class SWIFT_SAFE CombinedURLFiltersNFASink {
public:
    explicit CombinedURLFiltersNFASink(Function<bool(NFA&&)>& handler)
        : m_handler(handler)
    {
    }

    // Takes the NFA by reference and moves out of it, leaving Swift's value empty -- which is
    // exactly what `handler(WTF::move(nfa))` does to the C++ local it is called with. Returning
    // false is the caller asking processNFAs to stop.
    bool takeNFA(NFA& nfa) const { return m_handler(WTF::move(nfa)); }

private:
    Function<bool(NFA&&)>& m_handler;
};

} // namespace ContentExtensions
} // namespace WebCore

#endif // ENABLE(CONTENT_EXTENSIONS)
