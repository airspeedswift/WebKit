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

#include <WebCore/CombinedFiltersAlphabet.h>
#include <WebCore/ContentExtensionsDebugging.h>
#include <WebCore/NFA.h>
#include <wtf/Function.h>
#include <wtf/Forward.h>

namespace WebCore {

namespace ContentExtensions {

struct PrefixTreeVertex;

// Whether the C++ builder is compiled in at all. Off means the island is the only implementation,
// which is the MEASUREMENT MODE that answers *deletable* -- what could be dropped if the Swift
// permanently replaced the C++ path -- as opposed to *deleted*, which stays 0 by decision because
// keeping the fallback is the schedule.
//
// It has to be a build mode and not an `nm` inspection: with both arms compiled in, every symbol
// in the C++ arm links whatever the island's coverage is, so its presence in a symbol table says
// nothing at all. Guarding the bodies out makes the COMPILER the oracle -- it either links, in
// which case the guarded lines are deletable and the set is enumerated by construction, or it
// names the reference that keeps one alive.
//
// Spelled once, here, rather than repeated as a two-clause `#if` at each guarded region. A
// measurement whose boundary is written out eight times is one whose boundary can drift between
// them, and the count it produces is the thing being reported.
#if defined(USE_SWIFT_COMBINED_URL_FILTERS_NO_FALLBACK) && USE_SWIFT_COMBINED_URL_FILTERS_NO_FALLBACK
#if !defined(USE_SWIFT_COMBINED_URL_FILTERS) || !USE_SWIFT_COMBINED_URL_FILTERS
// Diagnosed here rather than left to produce a pile of link errors naming `generateNFAForSubtree`,
// which is what removing every builder from a build that still selects one looks like.
#error "WK_USE_SWIFT_COMBINED_URL_FILTERS_NO_FALLBACK=YES requires WK_USE_SWIFT_COMBINED_URL_FILTERS=YES: it removes the only other builder."
#endif
#define COMBINED_URL_FILTERS_CPP_BUILDER_COMPILED_IN 0
#else
#define COMBINED_URL_FILTERS_CPP_BUILDER_COMPILED_IN 1
#endif

class WEBCORE_EXPORT CombinedURLFilters {
public:
    // Which implementation holds the prefix tree and walks it. Both are compiled in -- keeping the
    // C++ in tree until every WebKit platform has Swift is the schedule, not a hedge -- and the
    // island is CombinedURLFiltersSwift.swift.
    //
    // The default comes from a build setting so a whole build can be flipped, and the constructor
    // takes it as a parameter so that ONE process can run both arms. That is not a convenience:
    // the differential oracle diffs the two implementations' NFAs over nine corpora, and an
    // instrument that needs a rebuild to change arms cannot rule out the rebuild.
    //
    // `defined() &&` rather than a `#if !defined / #define 0` prologue, because WebCore builds
    // with -Werror,-Wundef. Same arrangement as `CSSCalc::Serializer`.
    enum class Builder : bool { Cpp, Swift };
    static constexpr Builder defaultBuilder =
#if defined(USE_SWIFT_COMBINED_URL_FILTERS) && USE_SWIFT_COMBINED_URL_FILTERS
        Builder::Swift;
#else
        Builder::Cpp;
#endif

    explicit CombinedURLFilters(Builder = defaultBuilder);
    ~CombinedURLFilters();

    void addPattern(uint64_t actionId, const Vector<Term>& pattern);
    bool processNFAs(size_t maxNFASize, Function<bool(NFA&&)>&&);
    bool NODELETE isEmpty() const;

    // Not `&& COMBINED_URL_FILTERS_CPP_BUILDER_COMPILED_IN`, unlike print() below: both arms
    // answer this one, so ContentExtensionCompiler's LOG_LARGE_STRUCTURES calls compile in the
    // measurement mode too. Guarded on it, that mode did not build with reporting on.
#if CONTENT_EXTENSIONS_PERFORMANCE_REPORTING
    size_t memoryUsed() const;
#endif
#if CONTENT_EXTENSIONS_STATE_MACHINE_DEBUGGING && COMBINED_URL_FILTERS_CPP_BUILDER_COMPILED_IN
    void print() const;
#endif

private:
    // Holds the Swift island. Out of line because the type comes from WebCoreSwift-Generated.h,
    // which only translation units that can see every island's boundary header may include -- so
    // it cannot be named in a public header. Null on the `Builder::Cpp` arm, and the members
    // below are then the whole state; non-null on `Builder::Swift`, and the prefix tree and the
    // action side table live in the island instead. `m_alphabet` is shared by both arms: interning
    // is where a `Term` becomes an id, and the island only ever holds ids.
    struct SwiftIsland;

    CombinedFiltersAlphabet m_alphabet;
#if COMBINED_URL_FILTERS_CPP_BUILDER_COMPILED_IN
    const UniqueRef<PrefixTreeVertex> m_prefixTreeRoot;
    HashMap<const PrefixTreeVertex*, ActionList> m_actions;
#endif
    const std::unique_ptr<SwiftIsland> m_island;
};

} // namespace ContentExtensions
} // namespace WebCore

#endif // ENABLE(CONTENT_EXTENSIONS)
