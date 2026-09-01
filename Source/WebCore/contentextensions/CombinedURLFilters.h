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

#if CONTENT_EXTENSIONS_PERFORMANCE_REPORTING
    size_t memoryUsed() const;
#endif
#if CONTENT_EXTENSIONS_STATE_MACHINE_DEBUGGING
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
    const UniqueRef<PrefixTreeVertex> m_prefixTreeRoot;
    HashMap<const PrefixTreeVertex*, ActionList> m_actions;
    const std::unique_ptr<SwiftIsland> m_island;
};

} // namespace ContentExtensions
} // namespace WebCore

#endif // ENABLE(CONTENT_EXTENSIONS)
