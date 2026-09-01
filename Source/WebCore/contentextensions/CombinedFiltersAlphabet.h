/*
 * Copyright (C) 2015 Apple Inc. All rights reserved.
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

#if ENABLE(CONTENT_EXTENSIONS)

#include <WebCore/ContentExtensionsDebugging.h>
#include <WebCore/Term.h>
#include <limits>
#include <wtf/HashMap.h>
#include <wtf/SwiftBridging.h>
#include <wtf/Vector.h>

namespace WebCore {

namespace ContentExtensions {

// No term is ever given this id: it is the "this prefix tree edge carries no term" sentinel,
// replacing the null `const Term*` that used to mark a leaf for deleting.
//
// It sits at namespace scope rather than inside the alphabet because Swift's C++ importer does
// not import `static constexpr` data members at all -- measured, not assumed: a `static
// constexpr uint32_t` on a plain struct and on a SWIFT_SAFE one are both dropped with "has no
// member", while this exact constant at namespace scope imports (cxprobe/termimport).
constexpr uint32_t invalidTermId = std::numeric_limits<uint32_t>::max();

// SWIFT_SAFE: Swift imports the alphabet as unsafe because `m_uniqueTerms` is keyed on raw
// `const Term*` into `m_internedTermsStorage`, which the alphabet itself owns for its whole
// lifetime -- the pointers are interior to the object and cannot dangle while it is alive.
// Without this, every mention of the alphabet from Swift costs an `unsafe` marker.
//
// Those pointers stay strictly private. An interned term is named outside the alphabet by a
// dense `uint32_t` id -- an index into the storage vector -- so nothing that crosses the
// boundary carries a lifetime. The importer suggests SWIFT_RETURNS_INDEPENDENT_VALUE for a
// `const Term*` return, which would be a false claim about the pointee; an id needs no claim at
// all, and it makes term identity and NFA node identity the same kind of thing.
class SWIFT_SAFE CombinedFiltersAlphabet {
public:
    // Returns the id of the unique interned copy of `term`, interning it if it is new. Equal
    // terms always get the same id, so comparing two ids is the identity comparison the raw
    // pointer comparison used to be, not a value comparison.
    uint32_t interned(const Term&);

    // Resolving an id is bounds-checked -- `Vector::operator[]` traps on an out-of-range index --
    // where dereferencing an edge's `const Term*` was not checked at all.
    //
    // Swift drops THIS one, and the SWIFT_RETURNS_INDEPENDENT_VALUE the importer suggests would
    // be as false here as it was on the old `interned`: the result is a projection of the
    // alphabet's storage, and [[clang::lifetimebound]] on it changes nothing. It is left
    // unannotated, and the id-taking queries below are the answer instead -- a port wanting a Term
    // per edge visit would be asking for a deep copy of one anyway.
    const Term& term(uint32_t termId) const LIFETIME_BOUND { return *m_internedTermsStorage[termId]; }

    // The three operations a prefix-tree walk performs on a term, offered BY ID, because a caller
    // holding an id cannot get to the Term: `term()` above does not import, and the annotation the
    // importer suggests for it would be a false lifetime claim.
    //
    // These are forwarding one-liners on purpose. Nothing is recomputed and no Term crosses a
    // boundary -- a Term crossing by value would be a deep copy of a Group's Vector<Term>, and a
    // Term crossing by reference is the lifetime claim we declined to make. The alphabet is the
    // right place for them because it is what owns the mapping in the first place.
    bool hasFixedLength(uint32_t termId) const { return term(termId).hasFixedLength(); }

    ImmutableCharNFANodeBuilder generateGraph(uint32_t termId, NFA& nfa, ImmutableCharNFANodeBuilder& source, ActionList&& finalActions) const
    {
        return term(termId).generateGraph(nfa, source, WTF::move(finalActions));
    }

    void generateGraph(uint32_t termId, NFA& nfa, ImmutableCharNFANodeBuilder& source, uint32_t destination) const
    {
        term(termId).generateGraph(nfa, source, destination);
    }

#if CONTENT_EXTENSIONS_PERFORMANCE_REPORTING
    size_t memoryUsed() const;
#endif

private:
    struct TermPointerHash {
        static unsigned hash(const Term* key) { return computeHash(*key); }
        static inline bool equal(const Term* a, const Term* b)
        {
            return *a == *b;
        }
        static const bool safeToCompareToEmptyOrDeleted = false;
    };

    // Keyed on the interned term's address, which `std::unique_ptr` keeps stable across the
    // storage vector growing; the value is that term's index in the storage vector.
    HashMap<const Term*, uint32_t, TermPointerHash> m_uniqueTerms;
    Vector<std::unique_ptr<Term>> m_internedTermsStorage;
};

} // namespace ContentExtensions
} // namespace WebCore

#endif // ENABLE(CONTENT_EXTENSIONS)
