/*
 * Copyright (C) 2008 Apple Inc. All rights reserved.
 * Copyright (C) 2010 Google Inc. All rights reserved.
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
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE. 
 */

#pragma once

#include "CSSPreloadScanner.h"
#include "HTMLTokenizer.h"
#include "SegmentedString.h"
#include <memory>
#include <wtf/TZoneMalloc.h>

#if !defined(USE_SWIFT_HTML_PRELOAD_SCANNER)
#define USE_SWIFT_HTML_PRELOAD_SCANNER 0
#endif

#if USE_SWIFT_HTML_PRELOAD_SCANNER
#include "HTMLImageElement.h"
#include "JSRequestPriority.h"
#include "LinkIconType.h"
#include "LinkRelAttribute.h"
#include "ReferrerPolicy.h"
#include "ScriptElement.h"
#include "ShadowRootMode.h"
#include <wtf/SwiftBridging.h>
#endif

namespace WebCore {

// Per-<picture> state used by the preload scanner. The matched <source>
// candidate's preload is buffered here until we see the inner <img>: if the
// <img> has loading=lazy we discard it, otherwise we flush it to the request
// stream. This avoids speculatively fetching alternative-format <source>
// candidates (e.g. JXL/WebP/AVIF) for images that are still far below the
// viewport.
struct PreloadScannerPictureState {
    bool sourceMatched { false };
#if !USE_SWIFT_HTML_PRELOAD_SCANNER
    std::unique_ptr<PreloadRequest> bufferedSourceRequest;
#else
    // The matched <source>'s request, made at the <img>: its URL (null if there is none), and the base URL and media
    // it was seen with.
    String bufferedSourceURL;
    URL bufferedSourceBaseURL;
    String bufferedSourceMedia;
#endif
};

#if USE_SWIFT_HTML_PRELOAD_SCANNER
class SWIFT_PRIVATE_FILEID("WebCore/HTMLPreloadScanner.swift") TokenPreloadScanner;
class SWIFT_PRIVATE_FILEID("WebCore/HTMLPreloadScanner.swift") HTMLPreloadScanner;
#endif

class TokenPreloadScanner {
    WTF_MAKE_TZONE_ALLOCATED(TokenPreloadScanner);
    WTF_MAKE_NONCOPYABLE(TokenPreloadScanner);
public:
    explicit TokenPreloadScanner(const URL& documentURL, float deviceScaleFactor = 1.0);
#if USE_SWIFT_HTML_PRELOAD_SCANNER
    // Swift imports a class only if it can be moved.
    TokenPreloadScanner(TokenPreloadScanner&&) = default;
#endif

#if !USE_SWIFT_HTML_PRELOAD_SCANNER
    void scan(const HTMLToken&, PreloadRequestStream&, Document&);
#endif

    void setPredictedBaseElementURL(const URL& url) { m_predictedBaseElementURL = url; }

    bool inPicture() { return !m_pictureSourceState.isEmpty(); }

#if USE_SWIFT_HTML_PRELOAD_SCANNER
    // For HTMLPreloadScanner.swift: the attribute parsers and checks a start tag's scan uses.
    static bool mediaMatches(Document&, const String& media);
    static ALWAYS_INLINE bool hasLazyLoadableAttributeValue(const String& value) { return HTMLImageElement::hasLazyLoadableAttributeValue(value); }
    // The URL of the image candidate the source set selects, trimmed, or a null String if it is empty.
    static String bestFitImageURL(Document&, float deviceScaleFactor, const String& url, const String& srcset, const String& sizes, bool& hasCandidate);
    static ALWAYS_INLINE std::optional<ScriptType> determineScriptType(const String& type, const String& language) { return ScriptElement::determineScriptType(type, language); }
    static ALWAYS_INLINE bool isDataOrAboutURL(const String& url) { return protocolIs(url, "data"_s) || protocolIs(url, "about"_s); }
#endif

private:
#if USE_SWIFT_HTML_PRELOAD_SCANNER
    // For HTMLPreloadScanner.swift: append the request for a tag (a TagId's value; Style for an @import in a <style>)
    // to the requests of the scan in progress.
    static void appendRequest(uint8_t tagId, const String& url, const URL& baseURL, CachedResource::Type, const String& media, ScriptType, ReferrerPolicy, RequestPriority, const String& crossOriginMode, const String& nonce, const String& integrity, bool scriptIsAsync, const String& charset);
#endif

    enum class TagId {
        // These tags are scanned by the StartTagScanner.
        Img,
        Input,
        Link,
        Script,
        Meta,
        Source,
        Video,

        // These tags are not scanned by the StartTagScanner.
        Unknown,
        Style,
        Base,
        Template,
        Picture,
        Svg
    };

#if !USE_SWIFT_HTML_PRELOAD_SCANNER
    class StartTagScanner;

    static TagId tagIdFor(const HTMLToken::DataVector&);
#endif

    static ASCIILiteral initiatorFor(TagId);

    void updatePredictedBaseURL(const HTMLToken&, bool shouldRestrictBaseURLSchemes);

    CSSPreloadScanner m_cssScanner;
    const URL m_documentURL;
    const float m_deviceScaleFactor { 1 };

    URL m_predictedBaseElementURL;
    bool m_inStyle { false };
    
    Vector<PreloadScannerPictureState> m_pictureSourceState;

    unsigned m_templateCount { 0 };
    unsigned m_foreignContentCount { 0 };
};

#if USE_SWIFT_HTML_PRELOAD_SCANNER
// For HTMLPreloadScanner.swift: the parsers of attribute values a start tag's scan uses.
ALWAYS_INLINE LinkRelAttribute preloadScannerLinkRel(Document& document, const String& value) { return { document, value }; }
ALWAYS_INLINE RequestPriority preloadScannerFetchPriority(std::span<const char16_t> value NOESCAPE) { return parseEnumerationFromString<RequestPriority>(StringView(value).toString()).value_or(RequestPriority::Auto); }
ALWAYS_INLINE ReferrerPolicy preloadScannerReferrerPolicy(const String& value) { return parseReferrerPolicy(value, ReferrerPolicySource::ReferrerPolicyAttribute).value_or(ReferrerPolicy::EmptyString); }
ALWAYS_INLINE bool preloadScannerIsShadowRootMode(std::span<const char16_t> value NOESCAPE) { return !!parseShadowRootMode(StringView(value)); }
using PreloadScannerResourceType = CachedResource::Type;

// The token's tag name and characters, for HTMLPreloadScanner.swift and HTMLTokenizer.swift.
inline std::span<const char16_t> htmlTokenName(const HTMLToken& token LIFETIME_BOUND) { return token.name().span(); }
inline std::span<const char16_t> htmlTokenCharacters(const HTMLToken& token LIFETIME_BOUND) { return token.characters().span(); }
#endif

class HTMLPreloadScanner {
    WTF_MAKE_TZONE_ALLOCATED(HTMLPreloadScanner);
public:
    WEBCORE_EXPORT HTMLPreloadScanner(const HTMLParserOptions&, const URL& documentURL, float deviceScaleFactor = 1.0);
    WEBCORE_EXPORT ~HTMLPreloadScanner();
#if USE_SWIFT_HTML_PRELOAD_SCANNER
    // Swift imports a class only if it can be moved.
    HTMLPreloadScanner(HTMLPreloadScanner&&) = default;
#endif

    WEBCORE_EXPORT void appendToEnd(const SegmentedString&);
    void scan(HTMLResourcePreloader&, Document&);
    WEBCORE_EXPORT PreloadRequestStream scanRequests(Document&);

private:
    TokenPreloadScanner m_scanner;
    SegmentedString m_source;
    HTMLTokenizer m_tokenizer;
};

WEBCORE_EXPORT bool testPreloadScannerViewportSupport(Document*);

// For tests: appends each source to one scanner and scans after each append, as HTMLDocumentParser does with
// received data, and returns every request each scan made, then the document's viewport arguments.
WEBCORE_EXPORT String testPreloadScannerRequests(Document&, std::span<const String> sources);

} // namespace WebCore
