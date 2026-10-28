// Copyright (C) 2026 Apple Inc. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions
// are met:
// 1. Redistributions of source code must retain the above copyright
//    notice, this list of conditions and the following disclaimer.
// 2. Redistributions in binary form must reproduce the above copyright
//    notice, this list of conditions and the following disclaimer in the
//    documentation and/or other materials provided with the distribution.
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

#if USE_SWIFT_HTML_PRELOAD_SCANNER

internal import WebCore_Private.Core.SegmentedString
internal import WebCore_Private.Core.HTMLToken
internal import WebCore_Private.Core.HTMLTokenizer
internal import WebCore_Private.Core.HTMLResourcePreloader
internal import WebCore_Private.Core.CSSPreloadScanner
internal import WebCore_Private.Core.HTMLPreloadScanner
internal import WebCore_Private.Core.Document
internal import WebCore_Private.Core.HTMLImageElement
internal import WebCore_Private.Core.LinkLoader
// Operators that WebCore's headers declare use these JavaScriptCore and WTF types. Without their definitions, ==, !,
// << and * do not typecheck in this file.
#if canImport(JavaScriptCore_Private) // Not a module outside Apple platforms, where the headers are textual.
internal import JavaScriptCore_Private.Cxx.Snippet
internal import JavaScriptCore_Private.Cxx.DOMJITCallDOMGetterSnippet
internal import JavaScriptCore_Private.Cxx.WasmInstanceAnchor
internal import JavaScriptCore_Private.Cxx.WasmCalleeGroup
internal import JavaScriptCore_Private.Cxx.WasmModule
internal import JavaScriptCore_Private.Cxx.WasmModuleDebugInfo
#endif
internal import wtf.Core.Stopwatch

/// Runs the loop of HTMLPreloadScanner::scanRequests: tokenizes the scanner's source until it runs out, and scans each
/// token, appending the requests it makes to the scan's requests.
///
/// HTMLPreloadScanner::scanRequests passes `*this` as `preloadScanner`, the document it scans for, and the document's
/// lazyImageLoadingEnabled, disabledAdaptationsMetaTagEnabled and shouldRestrictBaseURLSchemes settings. Nothing else
/// may change the scanner, its tokenizer, its source or its TokenPreloadScanner until this returns. The C++ called
/// from here:
/// - processHTMLTokenizerToken (HTMLTokenizer.swift) and the C++ its comment lists; HTMLToken's type, attributeCount,
///   attributeName, attributeValue and clear, htmlTokenName, htmlTokenCharacters and cssPreloadScannerBuffer;
/// - TokenPreloadScanner::updatePredictedBaseURL, which calls findAttribute, StringImpl::create8BitIfPossible, URL's
///   constructor, URL::isValid and SecurityPolicy::isBaseURLSchemeAllowed;
/// - TokenPreloadScanner::appendRequest, which makes a PreloadRequest (initiatorFor, URL::isolatedCopy,
///   String::isolatedCopy) and appends it to the scan's requests, a local of scanRequests;
/// - preloadScannerFetchPriority, preloadScannerReferrerPolicy, preloadScannerIsShadowRootMode,
///   HTMLImageElement::isSupportedImageSourceType, and TokenPreloadScanner's hasLazyLoadableAttributeValue,
///   determineScriptType and isDataOrAboutURL, which parse a value (MIMETypeRegistry);
/// - preloadScannerLinkRel (LinkRelAttribute's constructor), Markable's asOptional,
///   LinkLoader::resourceTypeFromAsAttribute and LinkLoader::isSupportedType, which read the document's settings;
/// - mediaMatches (MQ::MediaQueryParser and MQ::MediaQueryEvaluator) and bestFitImageURL (SizesAttributeParser and
///   bestFitSourceForImageAttributes), which read the document's settings, view, frame, initial style and render view;
/// - Document::processViewport, which updates the document's viewport arguments and tells the chrome client, and
///   Document::processDisabledAdaptations, which updates its disabled adaptations;
/// - the Vector functions of PreloadScannerPictureState and of CSSPreloadScanner's buffers,
///   PreloadScannerPictureState's constructors and assignment, and String's and URL's constructors, destructors,
///   isNull, isEmpty and assignment.
///
/// None of these reaches the scanner, its tokenizer, its source or its TokenPreloadScanner except through what this
/// file passes it, runs script or the parser, or uses another thread.
@_expose(Cxx)
func scanHTMLPreloadScannerTokens(
    _ preloadScanner: inout WebCore.HTMLPreloadScanner,
    _ document: WebCore.Document,
    _ lazyImageLoadingEnabled: Bool,
    _ disabledAdaptationsMetaTagEnabled: Bool,
    _ shouldRestrictBaseURLSchemes: Bool
) {
    preloadScanner.scan(
        document,
        PreloadScannerSettings(
            lazyImageLoadingEnabled: lazyImageLoadingEnabled,
            disabledAdaptationsMetaTagEnabled: disabledAdaptationsMetaTagEnabled,
            shouldRestrictBaseURLSchemes: shouldRestrictBaseURLSchemes
        )
    )
}

extension WebCore.HTMLPreloadScanner {
    fileprivate mutating func scan(_ document: WebCore.Document, _ settings: PreloadScannerSettings) {
        scanTokens(&m_tokenizer, &m_source, &m_scanner, document, settings)
    }
}

/// The document settings a scan reads.
internal struct PreloadScannerSettings {
    var lazyImageLoadingEnabled: Bool
    var disabledAdaptationsMetaTagEnabled: Bool
    var shouldRestrictBaseURLSchemes: Bool
}

private func scanTokens(
    _ tokenizer: inout WebCore.HTMLTokenizer,
    _ source: inout WebCore.SegmentedString,
    _ scanner: inout WebCore.TokenPreloadScanner,
    _ document: WebCore.Document,
    _ settings: PreloadScannerSettings
) {
    while tokenizer.nextPreloadScannerToken(
        &source,
        { token in
            scanner.scan(token, document, settings)
        }
    ) {
    }
}

extension WebCore.TokenPreloadScanner {
    /// TokenPreloadScanner::scan.
    fileprivate mutating func scan(
        _ token: borrowing WebCore.HTMLToken,
        _ document: WebCore.Document,
        _ settings: PreloadScannerSettings
    ) {
        switch token.type() {
        case .Character:
            guard m_inStyle else {
                return
            }
            let predictedBaseElementURL = m_predictedBaseElementURL
            let characters: Span<UInt16> = WebCore.htmlTokenCharacters(token)
            let nullString = WTF.String()
            m_cssScanner.scan(characters) { url in
                Self.appendRequest(
                    PreloadScannerTagId.style.rawValue,
                    url,
                    predictedBaseElementURL,
                    .CSSStyleSheet,
                    nullString,
                    .Classic,
                    .EmptyString,
                    .Auto,
                    nullString,
                    nullString,
                    nullString,
                    false,
                    nullString
                )
            }
        case .EndTag:
            let name: Span<UInt16> = WebCore.htmlTokenName(token)
            scanEndTag(PreloadScannerTagId(name))
        case .StartTag:
            scanStartTag(token, document, settings)
        default:
            return
        }
    }

    private mutating func scanEndTag(_ tagId: PreloadScannerTagId) {
        if tagId == .template {
            if m_templateCount != 0 {
                m_templateCount -= 1
            }
            return
        }
        if m_templateCount != 0 {
            return
        }
        if tagId == .style {
            if m_inStyle {
                m_cssScanner.reset()
            }
            m_inStyle = false
        } else if tagId == .picture && !m_pictureSourceState.isEmpty() {
            // A <picture> that closes without an <img> drops its matched <source>'s request.
            m_pictureSourceState.removeLast()
        } else if tagId == .svg && m_foreignContentCount != 0 {
            m_foreignContentCount -= 1
        }
    }

    private mutating func scanStartTag(
        _ token: borrowing WebCore.HTMLToken,
        _ document: WebCore.Document,
        _ settings: PreloadScannerSettings
    ) {
        let tagId = PreloadScannerTagId(WebCore.htmlTokenName(token))
        if tagId == .template {
            var isDeclarativeShadowRoot = false
            for index in 0..<token.attributeCount() {
                let name: Span<UInt16> = token.attributeName(index)
                if nameIs(
                    name,
                    packed("s", "h", "a", "d"),
                    packed("o", "w", "r", "o"),
                    packed("o", "t", "m", "o"),
                    packed("d", "e")
                ) {
                    let value: Span<UInt16> = token.attributeValue(index)
                    isDeclarativeShadowRoot = WebCore.preloadScannerIsShadowRootMode(value)
                    break
                }
            }
            // A declarative shadow root's <template shadowrootmode> outside any other <template> is not counted.
            if !(isDeclarativeShadowRoot && m_templateCount == 0) {
                // Wraps at 2^32, as ++ on the unsigned member does in C++.
                m_templateCount &+= 1
            }
        }
        if m_templateCount != 0 {
            return
        }
        switch tagId {
        case .style:
            m_inStyle = true
            return
        case .base:
            // The first <base> element is the one that wins.
            if !m_predictedBaseElementURL.isEmpty() {
                return
            }
            updatePredictedBaseURL(token, settings.shouldRestrictBaseURLSchemes)
            return
        case .picture:
            m_pictureSourceState.append(consuming: WebCore.PreloadScannerPictureState())
            return
        case .svg:
            // Wraps at 2^32, as ++ on the unsigned member does in C++.
            m_foreignContentCount &+= 1
            return
        case .template, .unknown:
            // Neither has attributes to scan.
            return
        default:
            break
        }

        // In SVG foreign content, <script> uses href, and <image> is SVG's image element, not an HTML <img>.
        if m_foreignContentCount != 0 {
            if tagId == .script {
                return
            }
            if tagId == .img && nameIs(WebCore.htmlTokenName(token), packed("i", "m", "a", "g"), packed("e")) {
                return
            }
        }

        var scanner = PreloadScannerStartTagScanner()
        let sourceMatch = processAttributes(token, tagId, &scanner, document, settings)
        let request = scanner.requestType(tagId, document)

        // Inside a <picture>, a matched <source>'s request waits for the picture's <img>, which drops it if it loads
        // lazily.
        let pictureCount = m_pictureSourceState.size()
        if tagId == .source && pictureCount != 0 {
            if request != nil {
                var state = WebCore.PreloadScannerPictureState()
                state.sourceMatched = sourceMatch.matched
                state.bufferedSourceURL = scanner.urlToLoad
                state.bufferedSourceBaseURL = m_predictedBaseElementURL
                state.bufferedSourceMedia = scanner.mediaAttribute
                m_pictureSourceState[pictureCount - 1] = state
            } else if sourceMatch.matchedNow {
                m_pictureSourceState[pictureCount - 1].sourceMatched = true
            }
            return
        }
        if tagId == .img && pictureCount != 0 {
            let isLazyloadingImage = scanner.isLazyloadingImage(tagId)
            if !m_pictureSourceState[pictureCount - 1].bufferedSourceURL.isNull() {
                let state = m_pictureSourceState[pictureCount - 1]
                var flushed = WebCore.PreloadScannerPictureState()
                flushed.sourceMatched = state.sourceMatched
                m_pictureSourceState[pictureCount - 1] = flushed
                if !isLazyloadingImage {
                    Self.appendRequest(
                        PreloadScannerTagId.source.rawValue,
                        state.bufferedSourceURL,
                        state.bufferedSourceBaseURL,
                        .ImageResource,
                        state.bufferedSourceMedia,
                        .Classic,
                        .EmptyString,
                        .Auto,
                        WTF.String(),
                        WTF.String(),
                        WTF.String(),
                        false,
                        WTF.String()
                    )
                }
            }
        }

        if let request {
            Self.appendRequest(
                tagId.rawValue,
                scanner.urlToLoad,
                m_predictedBaseElementURL,
                request.type,
                scanner.mediaAttribute,
                request.scriptType,
                scanner.referrerPolicy,
                scanner.fetchPriority,
                scanner.crossOriginMode,
                scanner.nonceAttribute,
                scanner.integrityAttribute,
                scanner.scriptIsAsync,
                scanner.charset
            )
        }
    }

    /// StartTagScanner::processAttributes.
    ///
    /// For a <source> in a <picture>, returns whether the picture has a matched source after it, and whether this one
    /// is the match. The caller records that in the picture's state.
    private mutating func processAttributes(
        _ token: borrowing WebCore.HTMLToken,
        _ tagId: PreloadScannerTagId,
        _ scanner: inout PreloadScannerStartTagScanner,
        _ document: WebCore.Document,
        _ settings: PreloadScannerSettings
    ) -> (matched: Bool, matchedNow: Bool) {
        let pictureCount = m_pictureSourceState.size()
        let alreadyMatchedSource = pictureCount != 0 && m_pictureSourceState[pictureCount - 1].sourceMatched
        for index in 0..<token.attributeCount() {
            let name: Span<UInt16> = token.attributeName(index)
            let value: Span<UInt16> = token.attributeValue(index)
            scanner.processAttribute(
                tagId,
                PreloadScannerAttribute(name),
                value,
                alreadyMatchedSource,
                document,
                settings
            )
        }

        var matchedNow = false
        // A null media attribute matches, as an empty media query list does.
        if tagId == .source && pictureCount != 0 && !alreadyMatchedSource
            && scanner.typeMatched && !scanner.srcSetAttribute.isEmpty()
            && (scanner.mediaAttribute.isNull()
                || WebCore.TokenPreloadScanner.mediaMatches(document, scanner.mediaAttribute))
        {
            var hasCandidate = false
            let url = Self.bestFitImageURL(
                document,
                m_deviceScaleFactor,
                scanner.urlToLoad,
                scanner.srcSetAttribute,
                scanner.sizesAttribute,
                &hasCandidate
            )
            if hasCandidate {
                matchedNow = true
                scanner.setURLToLoadAllowingReplacement(url)
            }
        }

        // Resolve between src and srcset for an <img>.
        if tagId == .img && !scanner.srcSetAttribute.isEmpty() {
            var hasCandidate = false
            let url = Self.bestFitImageURL(
                document,
                m_deviceScaleFactor,
                scanner.urlToLoad,
                scanner.srcSetAttribute,
                scanner.sizesAttribute,
                &hasCandidate
            )
            scanner.setURLToLoadAllowingReplacement(url)
        }

        // Resolve between href and imagesrcset for <link rel=preload as=image>, as LinkLoader::preloadIfNeeded does.
        if tagId == .link && scanner.linkIsPreload && !scanner.srcSetAttribute.isEmpty()
            && scanner.resourceType(tagId, document) == .ImageResource
        {
            var hasCandidate = false
            let url = Self.bestFitImageURL(
                document,
                m_deviceScaleFactor,
                scanner.urlToLoad,
                scanner.srcSetAttribute,
                scanner.sizesAttribute,
                &hasCandidate
            )
            scanner.setURLToLoadAllowingReplacement(url)
        }

        if !scanner.metaContent.isNull() {
            if scanner.metaIsViewport {
                document.processViewport(scanner.metaContent, .ViewportMeta)
            }
            if scanner.metaIsDisabledAdaptations {
                document.processDisabledAdaptations(scanner.metaContent)
            }
        }
        return (alreadyMatchedSource || matchedNow, matchedNow)
    }
}

/// The state HTMLTokenizer::updateStateFor sets for the tag `name`, or nil if it leaves the state.
internal func stateForTagName(_ name: Span<UInt16>, scriptingFlag: Bool) -> TokenizerState? {
    switch name.count {
    case 3:
        return nameIs(name, packed("x", "m", "p")) ? .rawtext : nil
    case 5:
        return nameIs(name, packed("t", "i", "t", "l"), packed("e"))
            ? .rcdata
            : nameIs(name, packed("s", "t", "y", "l"), packed("e")) ? .rawtext : nil
    case 6:
        return nameIs(name, packed("s", "c", "r", "i"), packed("p", "t"))
            ? .scriptData
            : nameIs(name, packed("i", "f", "r", "a"), packed("m", "e")) ? .rawtext : nil
    case 7:
        return nameIs(name, packed("n", "o", "e", "m"), packed("b", "e", "d")) ? .rawtext : nil
    case 8:
        if nameIs(name, packed("t", "e", "x", "t"), packed("a", "r", "e", "a")) {
            return .rcdata
        }
        if nameIs(name, packed("n", "o", "f", "r"), packed("a", "m", "e", "s"))
            || (scriptingFlag && nameIs(name, packed("n", "o", "s", "c"), packed("r", "i", "p", "t")))
        {
            return .rawtext
        }
        return nil
    case 9:
        return nameIs(name, packed("p", "l", "a", "i"), packed("n", "t", "e", "x"), packed("t")) ? .plaintext : nil
    default:
        return nil
    }
}

/// TokenPreloadScanner::TagId, in the same order, which TokenPreloadScanner::appendRequest checks with a static_assert.
internal enum PreloadScannerTagId: UInt8 {
    // These tags are scanned by the StartTagScanner.
    case img
    case input
    case link
    case script
    case meta
    case source
    case video

    // These tags are not scanned by the StartTagScanner.
    case unknown
    case style
    case base
    case template
    case picture
    case svg

    /// TokenPreloadScanner::tagIdFor: the tag whose name has the characters of `name`.
    init(_ name: Span<UInt16>) {
        switch name.count {
        case 3:
            self =
                nameIs(name, packed("i", "m", "g"))
                ? .img
                : nameIs(name, packed("s", "v", "g")) ? .svg : .unknown
        case 4:
            self =
                nameIs(name, packed("b", "a", "s", "e"))
                ? .base
                : nameIs(name, packed("l", "i", "n", "k"))
                    ? .link
                    : nameIs(name, packed("m", "e", "t", "a")) ? .meta : .unknown
        case 5:
            self =
                nameIs(name, packed("i", "m", "a", "g"), packed("e"))
                ? .img
                : nameIs(name, packed("i", "n", "p", "u"), packed("t"))
                    ? .input
                    : nameIs(name, packed("s", "t", "y", "l"), packed("e"))
                        ? .style
                        : nameIs(name, packed("v", "i", "d", "e"), packed("o")) ? .video : .unknown
        case 6:
            self =
                nameIs(name, packed("s", "c", "r", "i"), packed("p", "t"))
                ? .script
                : nameIs(name, packed("s", "o", "u", "r"), packed("c", "e")) ? .source : .unknown
        case 7:
            self = nameIs(name, packed("p", "i", "c", "t"), packed("u", "r", "e")) ? .picture : .unknown
        case 8:
            self = nameIs(name, packed("t", "e", "m", "p"), packed("l", "a", "t", "e")) ? .template : .unknown
        default:
            self = .unknown
        }
    }
}

/// The attributes StartTagScanner reads, by local name.
internal enum PreloadScannerAttribute {
    case asAttribute
    case async
    case charset
    case content
    case crossorigin
    case disabled
    case fetchpriority
    case href
    case imagesizes
    case imagesrcset
    case integrity
    case language
    case loading
    case media
    case name
    case nomodule
    case nonce
    case poster
    case referrerpolicy
    case rel
    case sizes
    case src
    case srcset
    case type
    case other

    /// The attribute whose local name has the characters of `name`.
    init(_ name: Span<UInt16>) {
        switch name.count {
        case 2:
            self = nameIs(name, packed("a", "s")) ? .asAttribute : .other
        case 3:
            self =
                nameIs(name, packed("s", "r", "c"))
                ? .src
                : nameIs(name, packed("r", "e", "l")) ? .rel : .other
        case 4:
            self =
                nameIs(name, packed("h", "r", "e", "f"))
                ? .href
                : nameIs(name, packed("t", "y", "p", "e"))
                    ? .type
                    : nameIs(name, packed("n", "a", "m", "e")) ? .name : .other
        case 5:
            self =
                nameIs(name, packed("s", "i", "z", "e"), packed("s"))
                ? .sizes
                : nameIs(name, packed("m", "e", "d", "i"), packed("a"))
                    ? .media
                    : nameIs(name, packed("n", "o", "n", "c"), packed("e"))
                        ? .nonce
                        : nameIs(name, packed("a", "s", "y", "n"), packed("c")) ? .async : .other
        case 6:
            self =
                nameIs(name, packed("s", "r", "c", "s"), packed("e", "t"))
                ? .srcset
                : nameIs(name, packed("p", "o", "s", "t"), packed("e", "r")) ? .poster : .other
        case 7:
            self =
                nameIs(name, packed("l", "o", "a", "d"), packed("i", "n", "g"))
                ? .loading
                : nameIs(name, packed("c", "h", "a", "r"), packed("s", "e", "t"))
                    ? .charset
                    : nameIs(name, packed("c", "o", "n", "t"), packed("e", "n", "t")) ? .content : .other
        case 8:
            self =
                nameIs(name, packed("l", "a", "n", "g"), packed("u", "a", "g", "e"))
                ? .language
                : nameIs(name, packed("n", "o", "m", "o"), packed("d", "u", "l", "e"))
                    ? .nomodule
                    : nameIs(name, packed("d", "i", "s", "a"), packed("b", "l", "e", "d")) ? .disabled : .other
        case 9:
            self =
                nameIs(name, packed("i", "n", "t", "e"), packed("g", "r", "i", "t"), packed("y")) ? .integrity : .other
        case 10:
            self =
                nameIs(
                    name,
                    packed("i", "m", "a", "g"),
                    packed("e", "s", "i", "z"),
                    packed("e", "s")
                ) ? .imagesizes : .other
        case 11:
            self =
                nameIs(
                    name,
                    packed("c", "r", "o", "s"),
                    packed("s", "o", "r", "i"),
                    packed("g", "i", "n")
                )
                ? .crossorigin
                : nameIs(
                    name,
                    packed("i", "m", "a", "g"),
                    packed("e", "s", "r", "c"),
                    packed("s", "e", "t")
                ) ? .imagesrcset : .other
        case 13:
            self =
                nameIs(
                    name,
                    packed("f", "e", "t", "c"),
                    packed("h", "p", "r", "i"),
                    packed("o", "r", "i", "t"),
                    packed("y")
                ) ? .fetchpriority : .other
        case 14:
            self =
                nameIs(
                    name,
                    packed("r", "e", "f", "e"),
                    packed("r", "r", "e", "r"),
                    packed("p", "o", "l", "i"),
                    packed("c", "y")
                ) ? .referrerpolicy : .other
        default:
            self = .other
        }
    }
}

/// TokenPreloadScanner::StartTagScanner: what a start tag's attributes say about the request it makes.
internal struct PreloadScannerStartTagScanner: ~Copyable {
    var urlToLoad = WTF.String()
    var srcSetAttribute = WTF.String()
    var sizesAttribute = WTF.String()
    var typeMatched = true
    var charset = WTF.String()
    var crossOriginMode = WTF.String()
    var linkIsStyleSheet = false
    var linkIsPreload = false
    var linkIsDisabled = false
    var mediaAttribute = WTF.String()
    var nonceAttribute = WTF.String()
    var metaContent = WTF.String()
    var asAttribute = WTF.String()
    var typeAttribute = WTF.String()
    var languageAttribute = WTF.String()
    var integrityAttribute = WTF.String()
    var lazyloadAttribute = WTF.String()
    var metaIsViewport = false
    var metaIsDisabledAdaptations = false
    var inputIsImage = false
    var scriptIsNomodule = false
    var scriptIsAsync = false
    var referrerPolicy = WebCore.ReferrerPolicy.EmptyString
    var fetchPriority = WebCore.RequestPriority.Auto

    /// StartTagScanner::processAttribute.
    fileprivate mutating func processAttribute(
        _ tagId: PreloadScannerTagId,
        _ attribute: PreloadScannerAttribute,
        _ value: Span<UInt16>,
        _ alreadyMatchedSource: Bool,
        _ document: WebCore.Document,
        _ settings: PreloadScannerSettings
    ) {
        switch tagId {
        case .img:
            // Even when a sibling <source> already matched, the <img>'s loading attribute still governs whether the
            // matched source's request is made: read it first.
            if settings.lazyImageLoadingEnabled && attribute == .loading && lazyloadAttribute.isNull() {
                lazyloadAttribute = WTF.String(value)
                return
            }
            if alreadyMatchedSource {
                return
            }
            if attribute == .srcset && srcSetAttribute.isNull() {
                srcSetAttribute = WTF.String(value)
                return
            }
            if attribute == .sizes && sizesAttribute.isNull() {
                sizesAttribute = WTF.String(value)
                return
            }
            if attribute == .fetchpriority {
                fetchPriority = WebCore.preloadScannerFetchPriority(value)
                return
            }
            if attribute == .referrerpolicy {
                referrerPolicy = WebCore.preloadScannerReferrerPolicy(WTF.String(value))
                return
            }
            processImageAndScriptAttribute(attribute, value)
        case .source:
            if alreadyMatchedSource {
                return
            }
            if attribute == .srcset && srcSetAttribute.isNull() {
                srcSetAttribute = WTF.String(value)
                return
            }
            if attribute == .sizes && sizesAttribute.isNull() {
                sizesAttribute = WTF.String(value)
                return
            }
            if attribute == .media && mediaAttribute.isNull() {
                mediaAttribute = WTF.String(value)
            }
            if attribute == .type && typeAttribute.isNull() {
                // The first type attribute wins, as for the image element.
                typeAttribute = WTF.String(value)
                let isSupported = WebCore.HTMLImageElement.isSupportedImageSourceType(typeAttribute)
                typeMatched = typeMatched && isSupported
            }
        case .script:
            switch attribute {
            case .type:
                typeAttribute = WTF.String(value)
            case .language:
                languageAttribute = WTF.String(value)
            case .nonce:
                nonceAttribute = WTF.String(value)
            case .integrity:
                integrityAttribute = WTF.String(value)
            case .referrerpolicy:
                referrerPolicy = WebCore.preloadScannerReferrerPolicy(WTF.String(value))
            case .nomodule:
                scriptIsNomodule = true
            case .async:
                scriptIsAsync = true
            case .fetchpriority:
                fetchPriority = WebCore.preloadScannerFetchPriority(value)
            default:
                processImageAndScriptAttribute(attribute, value)
            }
        case .link:
            switch attribute {
            case .href:
                setURLToLoad(value)
            case .rel:
                let rel = WebCore.preloadScannerLinkRel(document, WTF.String(value))
                linkIsStyleSheet =
                    rel.isStyleSheet && !rel.isAlternate && rel.iconType.asOptional().value == nil
                    && !rel.isDNSPrefetch
                linkIsPreload = rel.isLinkPreload
            case .media:
                mediaAttribute = WTF.String(value)
            case .charset:
                charset = WTF.String(value)
            case .crossorigin:
                crossOriginMode = WTF.String(trimmingASCIIWhitespace(value))
            case .nonce:
                nonceAttribute = WTF.String(value)
            case .asAttribute:
                asAttribute = WTF.String(value)
            case .type:
                typeAttribute = WTF.String(value)
            case .referrerpolicy:
                referrerPolicy = WebCore.preloadScannerReferrerPolicy(WTF.String(value))
            case .fetchpriority:
                fetchPriority = WebCore.preloadScannerFetchPriority(value)
            case .disabled:
                linkIsDisabled = true
            case .imagesrcset:
                if srcSetAttribute.isNull() {
                    srcSetAttribute = WTF.String(value)
                }
            case .imagesizes:
                if sizesAttribute.isNull() {
                    sizesAttribute = WTF.String(value)
                }
            default:
                break
            }
        case .input:
            if attribute == .src {
                setURLToLoad(value)
            } else if attribute == .type {
                inputIsImage = equalLettersIgnoringASCIICase(value, packed("i", "m", "a", "g"), packed("e"))
            }
        case .meta:
            if attribute == .content {
                metaContent = WTF.String(value)
            } else if attribute == .name {
                metaIsViewport = equalLettersIgnoringASCIICase(
                    value,
                    packed("v", "i", "e", "w"),
                    packed("p", "o", "r", "t")
                )
                if settings.disabledAdaptationsMetaTagEnabled {
                    metaIsDisabledAdaptations = equalLettersIgnoringASCIICase(
                        value,
                        packed("d", "i", "s", "a"),
                        packed("b", "l", "e", "d"),
                        packed("-", "a", "d", "a"),
                        packed("p", "t", "a", "t"),
                        packed("i", "o", "n", "s")
                    )
                }
            }
        case .video:
            if attribute == .poster {
                setURLToLoad(value)
            } else if attribute == .crossorigin {
                crossOriginMode = WTF.String(trimmingASCIIWhitespace(value))
            }
        default:
            break
        }
    }

    private mutating func processImageAndScriptAttribute(_ attribute: PreloadScannerAttribute, _ value: Span<UInt16>) {
        switch attribute {
        case .src:
            setURLToLoad(value)
        case .crossorigin:
            crossOriginMode = WTF.String(trimmingASCIIWhitespace(value))
        case .charset:
            charset = WTF.String(value)
        default:
            break
        }
    }

    /// Only the first src or href counts.
    private mutating func setURLToLoad(_ value: Span<UInt16>) {
        if !urlToLoad.isEmpty() {
            return
        }
        let trimmedURL = trimmingASCIIWhitespace(value)
        if trimmedURL.isEmpty {
            return
        }
        urlToLoad = WTF.String(trimmedURL)
    }

    /// Replaces the URL with `url`, an image candidate's trimmed URL, unless it is null.
    fileprivate mutating func setURLToLoadAllowingReplacement(_ url: WTF.String) {
        if url.isNull() {
            return
        }
        urlToLoad = url
    }

    /// StartTagScanner::resourceType, or nil for a <link rel=preload> whose as attribute names no type.
    fileprivate func resourceType(
        _ tagId: PreloadScannerTagId,
        _ document: WebCore.Document
    ) -> WebCore.PreloadScannerResourceType? {
        switch tagId {
        case .script:
            return .Script
        case .img, .input, .source, .video:
            return .ImageResource
        case .link:
            if linkIsStyleSheet {
                return .CSSStyleSheet
            }
            if linkIsPreload {
                return WebCore.LinkLoader.resourceTypeFromAsAttribute(asAttribute, document, .No, .No).value
            }
            return .RawResource
        default:
            return .RawResource
        }
    }

    /// The resource and script types of the request StartTagScanner::createPreloadRequest makes, or nil if it makes
    /// none.
    fileprivate func requestType(
        _ tagId: PreloadScannerTagId,
        _ document: WebCore.Document
    ) -> (type: WebCore.PreloadScannerResourceType, scriptType: WebCore.ScriptType)? {
        // StartTagScanner::shouldPreload.
        if urlToLoad.isEmpty() {
            return nil
        }
        if WebCore.TokenPreloadScanner.isDataOrAboutURL(urlToLoad) {
            return nil
        }
        if tagId == .link && !linkIsStyleSheet && !linkIsPreload {
            return nil
        }
        if tagId == .link && linkIsDisabled {
            return nil
        }
        if tagId == .input && !inputIsImage {
            return nil
        }

        guard let type = resourceType(tagId, document) else {
            return nil
        }
        if tagId == .link && !WebCore.LinkLoader.isSupportedType(type, typeAttribute, document) {
            return nil
        }
        // Do not preload if lazy loading is possible but metadata fetch is disabled.
        if hasLazyLoadableAttributeValue() {
            return nil
        }
        var scriptType = WebCore.ScriptType.Classic
        if tagId == .script {
            let result = WebCore.TokenPreloadScanner.determineScriptType(typeAttribute, languageAttribute)
            guard let determinedType = result.value else {
                return nil
            }
            scriptType = determinedType
            if scriptType != .Module && scriptIsNomodule {
                return nil
            }
        }
        return (type, scriptType)
    }

    /// StartTagScanner::isLazyloadingImage.
    fileprivate func isLazyloadingImage(_ tagId: PreloadScannerTagId) -> Bool {
        tagId == .img && hasLazyLoadableAttributeValue()
    }

    private func hasLazyLoadableAttributeValue() -> Bool {
        // Only an <img>'s loading attribute is read, and a null value is not lazy.
        !lazyloadAttribute.isNull() && WebCore.TokenPreloadScanner.hasLazyLoadableAttributeValue(lazyloadAttribute)
    }
}

/// CSSPreloadScanner::State, in the same order, which CSSPreloadScanner's constructor checks with a static_assert.
///
/// Its raw value is m_state's.
internal enum PreloadScannerCSSState: UInt32 {
    case initial
    case maybeComment
    case comment
    case maybeCommentEnd
    case ruleStart
    case rule
    case afterRule
    case ruleValue
    case afterRuleValue
    case ruleConditions
    case doneParsingImportRules
}

extension WebCore.CSSPreloadScanner {
    /// CSSPreloadScanner::reset.
    fileprivate mutating func reset() {
        m_state = State(rawValue: State.RawValue(PreloadScannerCSSState.initial.rawValue))
        m_rule.clear()
        m_ruleValue.clear()
        m_ruleConditions.clear()
    }

    /// The largest capacity, in code units, a rule buffer keeps from one rule to the next.
    private static var maximumRetainedRuleBufferCapacity: Int { 256 }

    /// Empties the rule buffers for the next rule.
    ///
    /// Each keeps its storage unless it grew past maximumRetainedRuleBufferCapacity. reset() frees all three.
    private mutating func clearRuleBuffers() {
        if m_rule.capacity() > Self.maximumRetainedRuleBufferCapacity {
            m_rule.clear()
        } else {
            m_rule.shrink(0)
        }
        if m_ruleValue.capacity() > Self.maximumRetainedRuleBufferCapacity {
            m_ruleValue.clear()
        } else {
            m_ruleValue.shrink(0)
        }
        if m_ruleConditions.capacity() > Self.maximumRetainedRuleBufferCapacity {
            m_ruleConditions.clear()
        } else {
            m_ruleConditions.shrink(0)
        }
    }

    /// CSSPreloadScanner::scan: looks for @import rules in the characters of a <style>, and passes each one's URL to
    /// `appendImport`.
    fileprivate mutating func scan(_ data: Span<UInt16>, _ appendImport: (WTF.String) -> Void) {
        // No case handles an m_state outside State.
        guard
            var state = PreloadScannerCSSState(
                rawValue: PreloadScannerCSSState.RawValue(truncatingIfNeeded: m_state.rawValue)
            )
        else {
            return
        }
        // CSSPreloadScanner::tokenize, a state per run of characters: each state's loop finds where its run ends, and the
        // character that ends it picks the next state. Only @import rules matter, so this is not a real tokenizer.
        let count = data.count
        var index = 0
        tokenizing: while index < count {
            switch state {
            case .initial:
                while index < count && isASCIIWhitespace(data[index]) {
                    index += 1
                }
                if index == count {
                    break tokenizing
                }
                let character = data[index]
                index += 1
                if character == UInt16(UInt8(ascii: "@")) {
                    state = .ruleStart
                } else if character == UInt16(UInt8(ascii: "/")) {
                    state = .maybeComment
                } else {
                    state = .doneParsingImportRules
                }
            case .maybeComment:
                state = data[index] == UInt16(UInt8(ascii: "*")) ? .comment : .initial
                index += 1
            case .comment:
                while index < count && data[index] != UInt16(UInt8(ascii: "*")) {
                    index += 1
                }
                if index == count {
                    break tokenizing
                }
                // The loop stopped at a '*' before count, so this cannot overflow.
                index &+= 1
                state = .maybeCommentEnd
            case .maybeCommentEnd:
                while index < count && data[index] == UInt16(UInt8(ascii: "*")) {
                    index += 1
                }
                if index == count {
                    break tokenizing
                }
                state = data[index] == UInt16(UInt8(ascii: "/")) ? .initial : .comment
                index += 1
            case .ruleStart:
                let character = data[index]
                index += 1
                if isASCIIAlpha(character) {
                    clearRuleBuffers()
                    // A rule that ends before the end of data is read in place; one that reaches it is buffered.
                    var ruleEnd = index - 1
                    if scanRule(data, &ruleEnd, &state, appendImport) {
                        index = ruleEnd
                    } else {
                        m_rule.append(consuming: character)
                        state = .rule
                    }
                } else {
                    state = .initial
                }
            case .rule:
                let start = index
                while index < count {
                    let character = data[index]
                    if isASCIIWhitespace(character) || character == UInt16(UInt8(ascii: ";")) {
                        break
                    }
                    index += 1
                }
                for runIndex in start..<index {
                    m_rule.append(consuming: data[runIndex])
                }
                if index == count {
                    break tokenizing
                }
                state = data[index] == UInt16(UInt8(ascii: ";")) ? .initial : .afterRule
                index += 1
            case .afterRule:
                while index < count && isASCIIWhitespace(data[index]) {
                    index += 1
                }
                if index == count {
                    break tokenizing
                }
                let character = data[index]
                index += 1
                if character == UInt16(UInt8(ascii: ";")) {
                    state = .initial
                } else if character == UInt16(UInt8(ascii: "{")) {
                    state = .doneParsingImportRules
                } else {
                    state = .ruleValue
                    m_ruleValue.append(consuming: character)
                }
            case .ruleValue:
                scanRuleValue(data, &index, &state)
            case .afterRuleValue:
                while index < count && isASCIIWhitespace(data[index]) {
                    index += 1
                }
                if index == count {
                    break tokenizing
                }
                let character = data[index]
                index += 1
                if character == UInt16(UInt8(ascii: ";")) {
                    emitRule(&state, appendImport)
                } else if character == UInt16(UInt8(ascii: "{")) {
                    state = .doneParsingImportRules
                } else {
                    state = .ruleConditions
                    m_ruleConditions.append(consuming: character)
                }
            case .ruleConditions:
                let start = index
                while index < count {
                    let character = data[index]
                    if character == UInt16(UInt8(ascii: ";")) || character == UInt16(UInt8(ascii: "{")) {
                        break
                    }
                    index += 1
                }
                for runIndex in start..<index {
                    m_ruleConditions.append(consuming: data[runIndex])
                }
                if index == count {
                    break tokenizing
                }
                let character = data[index]
                index += 1
                if character == UInt16(UInt8(ascii: ";")) {
                    emitRule(&state, appendImport)
                } else {
                    state = .doneParsingImportRules
                }
            case .doneParsingImportRules:
                break tokenizing
            }
        }
        if state == .ruleValue || state == .afterRuleValue {
            emitRule(&state, appendImport)
        }
        // State's raw type is the C++ enum's underlying type: unsigned on Apple platforms, int under MSVC.
        m_state = State(rawValue: State.RawValue(state.rawValue))
    }

    /// The RuleValue state of CSSPreloadScanner::tokenize, from `data[index]` to the end of the rule value's run.
    ///
    /// The value ends at whitespace, which it does not keep, or after a character that makes hasFinishedRuleValue
    /// true: the quote the value starts with, or else ')', when the character before it is not '\'.
    private mutating func scanRuleValue(_ data: Span<UInt16>, _ index: inout Int, _ state: inout PreloadScannerCSSState) {
        let count = data.count
        let size = m_ruleValue.size()
        guard size != 0 else {
            // hasFinishedRuleValue is false for a value shorter than two characters.
            let character = data[index]
            index += 1
            if isASCIIWhitespace(character) {
                state = .afterRuleValue
            } else {
                m_ruleValue.append(consuming: character)
            }
            return
        }
        let first = m_ruleValue[0]
        let terminator =
            first == UInt16(UInt8(ascii: "'")) || first == UInt16(UInt8(ascii: "\"")) ? first : UInt16(UInt8(ascii: ")"))
        var previous = m_ruleValue[size - 1]
        let start = index
        var end = index
        var finished = false
        while end < count {
            let character = data[end]
            if isASCIIWhitespace(character) {
                index = end + 1
                finished = true
                break
            }
            end += 1
            if character == terminator && previous != UInt16(UInt8(ascii: "\\")) {
                index = end
                finished = true
                break
            }
            previous = character
        }
        if !finished {
            index = end
        }
        for runIndex in start..<end {
            m_ruleValue.append(consuming: data[runIndex])
        }
        if finished {
            state = .afterRuleValue
        }
    }

    /// Scans a rule whose name starts at `data[index]`, if it ends before the end of `data`.
    ///
    /// Reads the rule's name, value and conditions as runs of `data`, emits it, and sets `index` and `state` past it.
    /// Returns false, leaving `index` and `state` alone, when the rule reaches the end of `data`.
    private func scanRule(
        _ data: Span<UInt16>,
        _ index: inout Int,
        _ state: inout PreloadScannerCSSState,
        _ appendImport: (WTF.String) -> Void
    ) -> Bool {
        let count = data.count
        let ruleStart = index
        var position = index + 1
        // Rule: ends at whitespace or ';'.
        while position < count {
            let character = data[position]
            if isASCIIWhitespace(character) || character == UInt16(UInt8(ascii: ";")) {
                break
            }
            position += 1
        }
        if position == count {
            return false
        }
        let ruleEnd = position
        if data[position] == UInt16(UInt8(ascii: ";")) {
            index = position + 1
            state = .initial
            return true
        }
        position += 1
        // AfterRule.
        while position < count && isASCIIWhitespace(data[position]) {
            position += 1
        }
        if position == count {
            return false
        }
        let first = data[position]
        if first == UInt16(UInt8(ascii: ";")) || first == UInt16(UInt8(ascii: "{")) {
            index = position + 1
            state = first == UInt16(UInt8(ascii: ";")) ? .initial : .doneParsingImportRules
            return true
        }
        // RuleValue, as scanRuleValue.
        let valueStart = position
        let terminator =
            first == UInt16(UInt8(ascii: "'")) || first == UInt16(UInt8(ascii: "\"")) ? first : UInt16(UInt8(ascii: ")"))
        var previous = first
        position += 1
        var valueEnd = position
        while true {
            if position == count {
                return false
            }
            let character = data[position]
            if isASCIIWhitespace(character) {
                valueEnd = position
                position += 1
                break
            }
            position += 1
            if character == terminator && previous != UInt16(UInt8(ascii: "\\")) {
                valueEnd = position
                break
            }
            previous = character
        }
        // AfterRuleValue.
        while position < count && isASCIIWhitespace(data[position]) {
            position += 1
        }
        if position == count {
            return false
        }
        let conditionsStart = position
        var conditionsEnd = position
        if data[position] != UInt16(UInt8(ascii: ";")) {
            if data[position] == UInt16(UInt8(ascii: "{")) {
                index = position + 1
                state = .doneParsingImportRules
                return true
            }
            // RuleConditions: ends at ';' or '{'.
            position += 1
            while position < count {
                let character = data[position]
                if character == UInt16(UInt8(ascii: ";")) || character == UInt16(UInt8(ascii: "{")) {
                    break
                }
                position += 1
            }
            if position == count {
                return false
            }
            if data[position] == UInt16(UInt8(ascii: "{")) {
                index = position + 1
                state = .doneParsingImportRules
                return true
            }
            conditionsEnd = position
        }
        index = position + 1
        state = Self.readRule(
            data.extracting(ruleStart..<ruleEnd),
            data.extracting(valueStart..<valueEnd),
            data.extracting(conditionsStart..<conditionsEnd),
            appendImport
        )
        return true
    }

    /// CSSPreloadScanner::emitRule.
    private mutating func emitRule(_ state: inout PreloadScannerCSSState, _ appendImport: (WTF.String) -> Void) {
        state = Self.readRule(
            WebCore.cssPreloadScannerBuffer(self, 0),
            WebCore.cssPreloadScannerBuffer(self, 1),
            WebCore.cssPreloadScannerBuffer(self, 2),
            appendImport
        )
        clearRuleBuffers()
    }

    /// The part of CSSPreloadScanner::emitRule that reads a rule's name, value and conditions: passes an @import's URL
    /// to `appendImport`, and returns the state that follows the rule.
    private static func readRule(
        _ rule: Span<UInt16>,
        _ value: Span<UInt16>,
        _ conditions: Span<UInt16>,
        _ appendImport: (WTF.String) -> Void
    ) -> PreloadScannerCSSState {
        if equalLettersIgnoringASCIICase(rule, packed("i", "m", "p", "o"), packed("r", "t")) {
            let url = cssStringOrURL(value)
            if !url.isEmpty() && hasValidImportConditions(conditions) {
                // FIXME: Should this be including the charset in the preload request?
                appendImport(url)
            }
            return .initial
        }
        if equalLettersIgnoringASCIICase(rule, packed("c", "h", "a", "r"), packed("s", "e", "t"))
            || equalLettersIgnoringASCIICase(rule, packed("l", "a", "y", "e"), packed("r"))
        {
            return .initial
        }
        return .doneParsingImportRules
    }
}

/// parseCSSStringOrURL (CSSPreloadScanner.cpp): the URL of an @import, without whitespace, url( and ) and quotes.
private func cssStringOrURL(_ characters: Span<UInt16>) -> WTF.String {
    // offset + length stays at most characters.count, so the index arithmetic below cannot overflow.
    var offset = 0
    var length = characters.count

    // Remove whitespace from the rule start and end.
    while length != 0 && isASCIIWhitespace(characters[offset]) {
        offset += 1
        length -= 1
    }
    while length != 0 && isASCIIWhitespace(characters[offset &+ length &- 1]) {
        length -= 1
    }

    // Skip the "url(" prefix and the ")" suffix.
    if length >= 5
        && (characters[offset] == UInt16(UInt8(ascii: "u")) || characters[offset] == UInt16(UInt8(ascii: "U")))
        && (characters[offset + 1] == UInt16(UInt8(ascii: "r")) || characters[offset + 1] == UInt16(UInt8(ascii: "R")))
        && (characters[offset + 2] == UInt16(UInt8(ascii: "l")) || characters[offset + 2] == UInt16(UInt8(ascii: "L")))
        && characters[offset + 3] == UInt16(UInt8(ascii: "("))
        && characters[offset &+ length &- 1] == UInt16(UInt8(ascii: ")"))
    {
        offset &+= 4
        length -= 5
    }

    // Skip whitespace before and after the URL inside the "url()" parenthesis.
    while length != 0 && isASCIIWhitespace(characters[offset]) {
        offset += 1
        length -= 1
    }
    while length != 0 && isASCIIWhitespace(characters[offset &+ length &- 1]) {
        length -= 1
    }

    // Remove single-quotes or double-quotes from the URL.
    if length >= 2 && characters[offset] == characters[offset &+ length &- 1]
        && (characters[offset] == UInt16(UInt8(ascii: "'")) || characters[offset] == UInt16(UInt8(ascii: "\"")))
    {
        offset += 1
        length -= 2
    }

    // An empty URL makes no request.
    if length == 0 {
        return WTF.String()
    }
    return WTF.String(characters.extracting(offset..<offset &+ length))
}

/// hasValidImportConditions (CSSPreloadScanner.cpp): only no condition, layer and layer(...) are supported.
private func hasValidImportConditions(_ characters: Span<UInt16>) -> Bool {
    if characters.isEmpty {
        return true
    }
    let conditions = trimmingASCIIWhitespace(characters)
    // FIXME: Support multiple conditions, media queries and supports().
    var end: Int? = nil
    for index in conditions.indices where conditions[index] == UInt16(UInt8(ascii: ")")) {
        end = index
        break
    }
    if let end {
        return end == conditions.count - 1 && conditions.count >= 6
            && nameIs(conditions.extracting(0..<6), packed("l", "a", "y", "e"), packed("r", "("))
    }
    return nameIs(conditions, packed("l", "a", "y", "e"), packed("r"))
}

#if _endian(big)
#error("codeUnits reads a name's code units into a word with the first in the low bits")
#endif

/// Packs up to four ASCII characters into a word of 16-bit code units, the first in the low bits, as `codeUnits` reads a name.
///
/// A missing character is zero, which no character of a name compared here is.
@inline(always)
private func packed(
    _ a: Unicode.Scalar,
    _ b: Unicode.Scalar = "\0",
    _ c: Unicode.Scalar = "\0",
    _ d: Unicode.Scalar = "\0"
) -> UInt64 {
    UInt64(a.value) | UInt64(b.value) << 16 | UInt64(c.value) << 32 | UInt64(d.value) << 48
}

/// The number of characters `packed` put in `word`.
@inline(always)
private func characterCount(_ word: UInt64) -> Int {
    (64 - word.leadingZeroBitCount + 15) / 16
}

/// The code units of `name` from `index`, up to four, as a word, the first in the low bits; zero past the end of
/// `name`. `index` is below `name.count`.
@inline(always)
private func codeUnits(_ name: Span<UInt16>, _ index: Int) -> UInt64 {
    switch name.count - index {
    case 1:
        return UInt64(name[index])
    case 2:
        return UInt64(name.bytes.load(fromByteOffset: index * 2, as: UInt32.self))
    case 3:
        return UInt64(name.bytes.load(fromByteOffset: index * 2, as: UInt32.self)) | UInt64(name[index + 2]) << 32
    default:
        return name.bytes.load(fromByteOffset: index * 2, as: UInt64.self)
    }
}

/// `codeUnits(name, index)` with 0x20 or'ed into each code unit of `name`, as WTF's toASCIILowerUnchecked does.
@inline(always)
private func codeUnitsFoldingCase(_ name: Span<UInt16>, _ index: Int) -> UInt64 {
    let units = codeUnits(name, index)
    switch name.count - index {
    case 1:
        return units | 0x20
    case 2:
        return units | 0x0020_0020
    case 3:
        return units | 0x0020_0020_0020
    default:
        return units | 0x0020_0020_0020_0020
    }
}

/// Whether `name` has the characters `packed` put in `first`, then in each of the words that follow it.
@inline(always)
private func nameIs(_ name: Span<UInt16>, _ first: UInt64) -> Bool {
    name.count == characterCount(first) && codeUnits(name, 0) == first
}

@inline(always)
private func nameIs(_ name: Span<UInt16>, _ first: UInt64, _ second: UInt64) -> Bool {
    name.count == 4 + characterCount(second) && codeUnits(name, 0) == first && codeUnits(name, 4) == second
}

@inline(always)
private func nameIs(_ name: Span<UInt16>, _ first: UInt64, _ second: UInt64, _ third: UInt64) -> Bool {
    name.count == 8 + characterCount(third) && codeUnits(name, 0) == first && codeUnits(name, 4) == second
        && codeUnits(name, 8) == third
}

@inline(always)
private func nameIs(
    _ name: Span<UInt16>,
    _ first: UInt64,
    _ second: UInt64,
    _ third: UInt64,
    _ fourth: UInt64
) -> Bool {
    name.count == 12 + characterCount(fourth) && codeUnits(name, 0) == first && codeUnits(name, 4) == second
        && codeUnits(name, 8) == third && codeUnits(name, 12) == fourth
}

/// WTF's equalLettersIgnoringASCIICase: whether `characters`, with 0x20 or'ed into each code unit, has the characters
/// `packed` put in `first`, then in each of the words that follow it, which have no uppercase letters.
@inline(always)
private func equalLettersIgnoringASCIICase(_ characters: Span<UInt16>, _ first: UInt64, _ second: UInt64) -> Bool {
    characters.count == 4 + characterCount(second) && codeUnitsFoldingCase(characters, 0) == first
        && codeUnitsFoldingCase(characters, 4) == second
}

@inline(always)
private func equalLettersIgnoringASCIICase(
    _ characters: Span<UInt16>,
    _ first: UInt64,
    _ second: UInt64,
    _ third: UInt64,
    _ fourth: UInt64,
    _ fifth: UInt64
) -> Bool {
    characters.count == 16 + characterCount(fifth) && codeUnitsFoldingCase(characters, 0) == first
        && codeUnitsFoldingCase(characters, 4) == second && codeUnitsFoldingCase(characters, 8) == third
        && codeUnitsFoldingCase(characters, 12) == fourth && codeUnitsFoldingCase(characters, 16) == fifth
}

private func isASCIIWhitespace(_ character: UInt16) -> Bool {
    character == 0x20 || character == 0x0A || character == 0x09 || character == 0x0D || character == 0x0C
}

private func isASCIIAlpha(_ character: UInt16) -> Bool {
    let lowercase = character | 0x20
    return lowercase >= UInt16(UInt8(ascii: "a")) && lowercase <= UInt16(UInt8(ascii: "z"))
}

/// `characters` without leading and trailing ASCII whitespace.
@_lifetime(copy characters)
private func trimmingASCIIWhitespace(_ characters: Span<UInt16>) -> Span<UInt16> {
    var start = 0
    var end = characters.count
    while start < end && isASCIIWhitespace(characters[start]) {
        start += 1
    }
    while end > start && isASCIIWhitespace(characters[end - 1]) {
        end -= 1
    }
    return characters.extracting(start..<end)
}

#endif // USE_SWIFT_HTML_PRELOAD_SCANNER
