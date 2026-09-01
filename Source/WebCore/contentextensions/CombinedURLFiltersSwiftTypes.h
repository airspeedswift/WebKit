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
// type declarations and cost zero `unsafe` markers (cxprobe/termimport). The one thing this header
// adds is the NFA sink below, because a `WTF::Function` cannot be called from Swift.

#if ENABLE(CONTENT_EXTENSIONS)

#include <WebCore/CombinedFiltersAlphabet.h>
#include <WebCore/ImmutableNFANodeBuilder.h>
#include <WebCore/NFA.h>
#include <WebCore/Term.h>
#include <wtf/Function.h>
#include <wtf/SwiftBridging.h>

namespace WebCore {

namespace ContentExtensions {

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
