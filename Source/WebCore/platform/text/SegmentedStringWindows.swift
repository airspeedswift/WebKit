// Copyright (C) 2026 Apple Inc. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions
// are met:
// 1. Redistributions of source code must retain the above copyright
// notice, this list of conditions and the following disclaimer.
// 2. Redistributions in binary form must reproduce the above copyright
// notice, this list of conditions and the following disclaimer in the
// documentation and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
// THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
// PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
// BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
// THE POSSIBILITY OF SUCH DAMAGE.
// /

#if os(Windows) && USE_SWIFT_HTML_TOKENIZER

internal import WebCore_Private.Core.SegmentedString

// With the MSVC standard library, Swift does not import SegmentedString's LIFETIME_BOUND std::span
// accessors, so it cannot generate their Span overloads either. These are those overloads, over the
// independent-value copies SegmentedString.h declares for Windows: the span points into the string's
// current substring, which lives as long as the borrow of the string.
extension WebCore.SegmentedString {
    @_lifetime(borrow self)
    func currentSubstringSpan8() -> Span<UInt8> {
        let span = unsafe Span(_unsafeCxxSpan: currentSubstringSpan8ForSwift())
        return unsafe _overrideLifetime(span, borrowing: self)
    }

    @_lifetime(borrow self)
    func currentSubstringSpan16() -> Span<UInt16> {
        let span = unsafe Span(_unsafeCxxSpan: currentSubstringSpan16ForSwift())
        return unsafe _overrideLifetime(span, borrowing: self)
    }
}

#endif
