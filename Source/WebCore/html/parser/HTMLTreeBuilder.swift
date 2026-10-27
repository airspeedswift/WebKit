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

#if USE_SWIFT_HTML_TREE_BUILDER

internal import WebCore_Private.Core.Attribute
internal import WebCore_Private.Core.ContainerNode
internal import WebCore_Private.Core.CustomElementRegistry
internal import WebCore_Private.Core.Document
internal import WebCore_Private.Core.DocumentFragment
internal import WebCore_Private.Core.Element
internal import WebCore_Private.Core.HTMLDocument
internal import WebCore_Private.Core.HTMLDocumentParser
internal import WebCore_Private.Core.HTMLFormElement
internal import WebCore_Private.Core.HTMLParserOptions
internal import WebCore_Private.Core.HTMLTokenizer
internal import WebCore_Private.Core.HTMLTreeBuilderSwiftSupport
internal import WebCore_Private.Core.Node
internal import WebCore_Private.Core.NodeName
internal import WebCore_Private.Core.QualifiedName
// Operators that WebCore's headers declare use these JavaScriptCore and WTF types. Without their definitions, ==, !,
// << and * do not typecheck in this file.
internal import JavaScriptCore_Private.Cxx.Snippet
internal import JavaScriptCore_Private.Cxx.DOMJITCallDOMGetterSnippet
internal import JavaScriptCore_Private.Cxx.WasmInstanceAnchor
internal import JavaScriptCore_Private.Cxx.WasmCalleeGroup
internal import JavaScriptCore_Private.Cxx.WasmModule
internal import JavaScriptCore_Private.Cxx.WasmModuleDebugInfo
internal import wtf.Core.Stopwatch

private func isASCIIWhitespace(_ character: UInt16) -> Bool {
    character == 0x20 || character == 0x0A || character == 0x09 || character == 0x0D || character == 0x0C
}

/// WTF's String::containsOnly<isASCIIWhitespace>.
private func containsOnlyASCIIWhitespace(_ string: WTF.String) -> Bool {
    if string.is8Bit() {
        let characters: Span<WTF.Latin1Character> = string.span8()
        for index in characters.indices where !isASCIIWhitespace(UInt16(characters[index].value)) {
            return false
        }
        return true
    }
    let characters: Span<UInt16> = string.span16()
    for index in characters.indices where !isASCIIWhitespace(characters[index]) {
        return false
    }
    return true
}

/// The characters of a character token, or of characters the tree builder makes, as the insertion modes consume
/// them from the front.
///
/// A token's characters are 8-bit exactly when they are all Latin-1, so a part taken out of them is a substring,
/// with the width of the whole.
private struct ExternalCharacterTokenBuffer {
    private let text: WTF.String
    private var start: UInt32 = 0
    private let end: UInt32

    init(_ text: WTF.String) {
        self.text = text
        end = text.length()
    }

    var isEmpty: Bool { start == end }

    private func character(_ index: UInt32) -> UInt16 {
        if text.is8Bit() {
            let characters: Span<WTF.Latin1Character> = text.span8()
            return UInt16(characters[Int(index)].value)
        }
        let characters: Span<UInt16> = text.span16()
        return characters[Int(index)]
    }

    mutating func skipAtMostOneLeadingNewline() {
        if character(start) == 0x0A {
            start += 1
        }
    }

    mutating func skipLeadingWhitespace() {
        while start < end && isASCIIWhitespace(character(start)) {
            start += 1
        }
    }

    mutating func skipLeadingNonWhitespace() {
        while start < end && !isASCIIWhitespace(character(start)) {
            start += 1
        }
    }

    /// The leading whitespace, or the null string if there is none.
    mutating func takeLeadingWhitespace() -> WTF.String {
        let whitespaceStart = start
        skipLeadingWhitespace()
        if start == whitespaceStart {
            return WTF.String()
        }
        return text.substring(whitespaceStart, start - whitespaceStart)
    }

    mutating func takeRemaining() -> WTF.String {
        let remainingStart = start
        start = end
        return text.substring(remainingStart, end - remainingStart)
    }

    /// The whitespace among the remaining characters, as an 8-bit string, or the null string if there is none.
    /// The other characters are dropped.
    mutating func takeRemainingWhitespace() -> WTF.String {
        var whitespace: [UInt8] = []
        while start < end {
            let character = character(start)
            if isASCIIWhitespace(character) {
                whitespace.append(UInt8(truncatingIfNeeded: character))
            }
            start += 1
        }
        // The null string when there is no whitespace, so that no text node is inserted (rather than an empty
        // one).
        if whitespace.isEmpty {
            return WTF.String()
        }
        return WTF.String(WTF.latin1CharactersOfBytes(whitespace.span))
    }
}

/// The characters of `string` as a 16-bit string, as WTF::String makes from a span of UChar.
private func makeString16(_ string: WTF.String) -> WTF.String {
    if !string.is8Bit() || string.isEmpty() {
        return string
    }
    let characters: Span<WTF.Latin1Character> = string.span8()
    var wide = [UInt16](repeating: 0, count: characters.count)
    for index in characters.indices {
        wide[index] = UInt16(characters[index].value)
    }
    return WTF.String(wide.span)
}

/// The character tokens the in table text insertion mode collects
/// (https://html.spec.whatwg.org/multipage/parsing.html#concept-pending-table-character-tokens), as a
/// StringBuilder appending each token's characters as UChar: 8-bit only while every append is one Latin-1
/// character.
private struct PendingTableCharacters {
    private var parts: [WTF.String] = []
    private var is8Bit = true

    var isEmpty: Bool { parts.isEmpty }

    mutating func append(_ characters: WTF.String) {
        if characters.isEmpty() {
            return
        }
        if !(characters.length() == 1 && Self.firstCharacter(characters) <= 0xFF) {
            is8Bit = false
        }
        parts.append(characters)
    }

    /// The characters, which are no longer pending.
    mutating func take() -> WTF.String {
        var taken: [WTF.String] = []
        swap(&taken, &parts)
        let takenIs8Bit = is8Bit
        is8Bit = true
        if taken.isEmpty {
            // Not reached: the in table text insertion mode is entered with characters.
            return WTF.String()
        }
        if taken.count == 1 && taken[0].is8Bit() == takenIs8Bit {
            return taken[0]
        }
        if takenIs8Bit {
            // Each part is one Latin-1 character.
            var characters: [UInt8] = []
            characters.reserveCapacity(taken.count)
            for part in taken {
                characters.append(UInt8(truncatingIfNeeded: Self.firstCharacter(part)))
            }
            return WTF.String(WTF.latin1CharactersOfBytes(characters.span))
        }
        var characters: [UInt16] = []
        for part in taken {
            if part.is8Bit() {
                let span: Span<WTF.Latin1Character> = part.span8()
                for index in span.indices {
                    characters.append(UInt16(span[index].value))
                }
            } else {
                let span: Span<UInt16> = part.span16()
                for index in span.indices {
                    characters.append(span[index])
                }
            }
        }
        return WTF.String(characters.span)
    }

    private static func firstCharacter(_ string: WTF.String) -> UInt16 {
        if string.is8Bit() {
            let characters: Span<WTF.Latin1Character> = string.span8()
            return UInt16(characters[0].value)
        }
        let characters: Span<UInt16> = string.span16()
        return characters[0]
    }
}

/// The parsing error hook of the specification, which WebKit does not report.
@inline(always)
private func parseError() {}

/// HTML tree construction (https://html.spec.whatwg.org/multipage/parsing.html#tree-construction) for one
/// HTMLDocumentParser, and the parser's token loop.
///
/// HTMLDocumentParser owns one, and calls pump for each pump of its tokenizer. The loop takes each token from
/// HTMLDocumentParser::nextTokenForTreeBuilder, which makes the checks the parser makes between tokens, and builds
/// the tree from it. A script or a custom element to construct is handed back to the parser, which runs it before
/// the next token. Script that runs inside a DOM call, and calls document.write, pumps the same parser again: no
/// access to a stored property is open across a call into C++ that can reach script.
@_expose(Cxx)
final class HTMLTreeBuilder {
    enum InsertionMode {
        case Initial
        case BeforeHTML
        case BeforeHead
        case InHead
        case InHeadNoscript
        case AfterHead
        case TemplateContents
        case InBody
        case Text
        case InTable
        case InTableText
        case InCaption
        case InColumnGroup
        case InTableBody
        case InRow
        case InCell
        case AfterBody
        case InFrameset
        case AfterFrameset
        case AfterAfterBody
        case AfterAfterFrameset
    }

    private let tree: HTMLConstructionSite
    /// A fragment parse's context element
    /// (https://html.spec.whatwg.org/multipage/parsing.html#concept-frag-parse-context).
    private let contextElementItem: HTMLStackItem?
    /// The context element's stack word, for the adjusted current node while it is the context element.
    private let contextElementWord: UInt32?
    private let scriptingFlag: Bool
    private let usePreHTML5ParserQuirks: Bool
    private let enhancedSelectQuirk: Bool

    private var insertionMode = InsertionMode.Initial
    private var originalInsertionMode = InsertionMode.Initial
    /// Only `changeTemplateInsertionModes` changes `templateInsertionModes`.
    private var templateInsertionModes = UniqueArray<InsertionMode>()
    private var framesetOk = true
    private var shouldSkipLeadingNewline = false
    private var pendingTableCharacters = PendingTableCharacters()
    /// Where the script element being parsed started, for the parser when the element ends. The start of an SVG
    /// script element is not recorded, so it gets what is here.
    private var scriptToProcessStartPosition = HTMLTreeBuilder.uninitializedPosition
    /// A fragment's tokenizer flags for its context element are set by the first pump, which has the parser.
    private var needsTokenizerUpdateForContextElement: Bool
    /// The attribute names foreign content adjusts, made the first time each table is used.
    private var svgAttributeNames: AdjustedAttributeNames?
    private var mathMLAttributeNames: AdjustedAttributeNames?
    private var foreignAttributeNames: AdjustedAttributeNames?
    /// The type attribute's name, and the font element's attributes that leave foreign content, made on first use.
    private var typeAttributeName: WebCore.QualifiedName?
    private var fontAttributeNames: FontAttributeNames?
    /// The foreign content namespaces and annotation-xml's encoding attribute name, made on first use.
    private var madeForeignContentNames: ForeignContentNames?

    private var foreignContentNames: ForeignContentNames {
        if let names = madeForeignContentNames {
            return names
        }
        let names = ForeignContentNames()
        madeForeignContentNames = names
        return names
    }

    /// HTMLNames' typeAttr.
    private func typeAttribute() -> WebCore.QualifiedName {
        if let name = typeAttributeName {
            return name
        }
        let name = makeAttributeName("type")
        typeAttributeName = name
        return name
    }

    private static var uninitializedPosition: WTF.TextPosition {
        WTF.TextPosition(WTF.OrdinalNumber.fromOneBasedInt(-1), WTF.OrdinalNumber())
    }

    /// A document's tree builder.
    @_expose(Cxx)
    init(document: WebCore.HTMLDocument, policy: UInt8, options: WebCore.HTMLParserOptions) {
        tree = HTMLConstructionSite(
            document: document, parserContentPolicy: policy, maximumDOMTreeDepth: options.maximumDOMTreeDepth
        )
        contextElementItem = nil
        contextElementWord = nil
        scriptingFlag = options.scriptingFlag
        usePreHTML5ParserQuirks = options.usePreHTML5ParserQuirks
        enhancedSelectQuirk = options.enhancedSelectQuirk
        needsTokenizerUpdateForContextElement = false
    }

    /// A fragment's tree builder, with no custom element registry given.
    @_expose(Cxx)
    convenience init(
        fragment: WebCore.DocumentFragment,
        contextElement: WebCore.Element,
        policy: UInt8,
        options: WebCore.HTMLParserOptions
    ) {
        self.init(
            fragment: fragment, contextElement: contextElement, policy: policy, options: options,
            optionalRegistry: nil
        )
    }

    /// A fragment's tree builder that looks up custom elements in `registry`.
    @_expose(Cxx)
    convenience init(
        fragment: WebCore.DocumentFragment,
        contextElement: WebCore.Element,
        policy: UInt8,
        options: WebCore.HTMLParserOptions,
        registry: consuming WebCore.CustomElementRegistry
    ) {
        self.init(
            fragment: fragment, contextElement: contextElement, policy: policy, options: options,
            optionalRegistry: registry
        )
    }

    /// A fragment's tree builder (https://html.spec.whatwg.org/multipage/parsing.html#parsing-html-fragments):
    /// `contextElement`'s insertion mode and form, and the tokenizer flags for it, which the first pump sets.
    private init(
        fragment: WebCore.DocumentFragment,
        contextElement: WebCore.Element,
        policy: UInt8,
        options: WebCore.HTMLParserOptions,
        optionalRegistry registry: WebCore.CustomElementRegistry?
    ) {
        tree = HTMLConstructionSite(
            fragment: fragment, parserContentPolicy: policy, maximumDOMTreeDepth: options.maximumDOMTreeDepth,
            registry: registry
        )
        let contextItem = HTMLStackItem(element: contextElement)
        contextElementItem = contextItem
        contextElementWord = contextItem.stackWord
        scriptingFlag = options.scriptingFlag
        usePreHTML5ParserQuirks = options.usePreHTML5ParserQuirks
        enhancedSelectQuirk = options.enhancedSelectQuirk
        needsTokenizerUpdateForContextElement = true

        // For efficiency, step 5 ("Let root be a new html element with no attributes") is skipped, and the
        // DocumentFragment is the root node instead.
        tree.openElements.pushRootNode(HTMLStackItem(fragment: fragment))

        if contextElement.elementName() == .HTML_template {
            changeTemplateInsertionModes { $0.append(.TemplateContents) }
        }

        resetInsertionModeAppropriately()

        let formElement = WebCore.dynamicDowncastHTMLFormElement(contextElement)
        tree.setForm(formElement ?? WebCore.HTMLFormElement.findClosestFormAncestor(contextElement))
    }

    /// Builds the tree from the parser's tokens until the parser stops, waits for a script or yields. Returns true
    /// if the parser should resume later (it yielded).
    @_expose(Cxx)
    func pump(_ parser: consuming WebCore.HTMLDocumentParser, allowYield: Bool) -> Bool {
        let saved = tree.enter(parser)
        defer { tree.leave(saved) }

        if needsTokenizerUpdateForContextElement {
            // Characters are tokenized before any token reaches the tree builder, so the tokenizer flags implied
            // by the context element are set before the first token rather than after it.
            needsTokenizerUpdateForContextElement = false
            updateTokenizerForAdjustedCurrentNode()
        }

        var parts = WebCore.HTMLTokenAttributes()
        repeat {
            switch parser.nextTokenForTreeBuilder(&parts) {
            case .Token:
                break
            case .Yield:
                return true
            default:
                return false
            }
            var token = AtomHTMLToken(&parts)
            constructTree(&token)
        } while !parser.isStopped()
        return false
    }


    /// The end of the document: tells the document that parsing has finished, which can destroy the parser.
    @_expose(Cxx)
    func finished(_ parser: consuming WebCore.HTMLDocumentParser) {
        if tree.isParsingFragment {
            return
        }
        // The parser and this can be destroyed as an indirect result of finishing the parsing.
        tree.finishedParsing(parser.document()!)
    }

    /// Inserts the custom element, or its fallback, that the parser constructed for the last start tag, with that
    /// tag's attributes.
    @_expose(Cxx)
    func didCreateCustomOrFallbackElement(_ parser: consuming WebCore.HTMLDocumentParser, _ element: WebCore.Element) {
        let saved = tree.enter(parser)
        tree.insertCustomElement(element)
        tree.leave(saved)
    }

    @_expose(Cxx)
    func isOnStackOfOpenElements(_ element: WebCore.Element) -> Bool {
        tree.openElements.contains(element)
    }

    /// TextDocumentParser's <meta name=color-scheme content="light dark"> and <pre>, whose first newline is kept.
    @_expose(Cxx)
    func insertTextDocumentFakeElements(_ parser: consuming WebCore.HTMLDocumentParser) {
        let saved = tree.enter(parser)
        defer { tree.leave(saved) }

        var metaAttributes = WebCore.AttributeVector()
        WebCore.appendAttribute(&metaAttributes, makeAttributeName("name"), makeAtomString("color-scheme"))
        WebCore.appendAttribute(&metaAttributes, makeAttributeName("content"), makeAtomString("light dark"))
        var fakeMeta = AtomHTMLToken(.StartTag, .meta, attributes: metaAttributes)
        constructTree(&fakeMeta)

        var preAttributes = WebCore.AttributeVector()
        WebCore.appendAttribute(
            &preAttributes, makeAttributeName("style"), makeAtomString("word-wrap: break-word; white-space: pre-wrap;")
        )
        var fakePre = AtomHTMLToken(.StartTag, .pre, attributes: preAttributes)
        constructTree(&fakePre)

        // Normally the first newline after a <pre> is skipped, but not in a text document.
        shouldSkipLeadingNewline = false
    }

    // MARK: Storage

    /// Makes a change to the template insertion modes. They are moved out while they change, so that no access to the
    /// stored property is open while the storage allocates or frees memory, and the compiler can check the accesses
    /// without run-time checks.
    @inline(always)
    private func changeTemplateInsertionModes(_ change: (inout UniqueArray<InsertionMode>) -> Void) {
        var modes = UniqueArray<InsertionMode>()
        swap(&modes, &templateInsertionModes)
        change(&modes)
        swap(&modes, &templateInsertionModes)
    }

    /// The pending table characters are moved out while they grow, for the same reason.
    private func appendPendingTableCharacters(_ characters: WTF.String) {
        var pending = PendingTableCharacters()
        swap(&pending, &pendingTableCharacters)
        pending.append(characters)
        swap(&pending, &pendingTableCharacters)
    }

    // MARK: Tree construction

    private var parser: WebCore.HTMLDocumentParser { tree.parser }
    private var isParsingFragment: Bool { tree.isParsingFragment }

    private var isParsingTemplateContents: Bool {
        if tree.openElements.containsTemplateElement && tree.openElements.hasTemplateInHTMLScope {
            return true
        }
        return contextElementItem?.elementName == .HTML_template
    }

    private var isParsingFragmentOrTemplateContents: Bool { isParsingFragment || isParsingTemplateContents }

    private var scriptingContentIsAllowed: Bool {
        tree.parserContentPolicy & WebCore.ParserContentPolicy.AllowScriptingContent.rawValue != 0
    }

    /// Builds the tree for one token, then runs the DOM changes it queued, which can run script.
    func constructTree(_ token: inout AtomHTMLToken) {
        if shouldProcessTokenInForeignContent(token) {
            processTokenInForeignContent(&token)
        } else {
            processToken(&token)
        }

        updateTokenizerForAdjustedCurrentNode()

        tree.executeQueuedTasks()
        // The parser might have been detached as an indirect result of executing the queued tasks.
    }

    private func updateTokenizerForAdjustedCurrentNode() {
        // Both flags are computed from the adjusted current node, matching the tree construction dispatcher. When
        // fragment-parsing with only one element on the stack, the adjusted current node is the context element,
        // not the DocumentFragment.
        //
        // These two flags use different conditions:
        // - shouldAllowCDATA follows the tokenizer's markup declaration open state, which switches to the CDATA
        //   section state whenever there is an adjusted current node and it is not an element in the HTML
        //   namespace. Integration points are NOT a consideration there, so CDATA sections are allowed even when
        //   the adjusted current node is an integration point.
        //   https://html.spec.whatwg.org/multipage/parsing.html#markup-declaration-open-state
        // - forceNullCharacterReplacement follows the dispatcher's notion of foreign content (used to replace
        //   U+0000 NULL with U+FFFD), which treats integration points as HTML content and thus excludes them.
        //   https://html.spec.whatwg.org/multipage/parsing.html#tree-construction
        let word = adjustedCurrentNodeWord
        let adjustedCurrentNodeIsForeign = !tree.isEmpty && !HTMLElementStack.isInHTMLNamespace(word)
        let inForeignContent =
            adjustedCurrentNodeIsForeign
            && !adjustedCurrentNodeIsHTMLIntegrationPoint(word)
            && !HTMLElementStack.isMathMLTextIntegrationPoint(word)

        let parser = self.parser
        parser.setTokenizerForceNullCharacterReplacement(inForeignContent)
        parser.setTokenizerShouldAllowCDATA(adjustedCurrentNodeIsForeign)
    }

    private func processToken(_ token: inout AtomHTMLToken) {
        switch token.type {
        case .DOCTYPE:
            shouldSkipLeadingNewline = false
            processDoctypeToken(&token)
        case .StartTag:
            shouldSkipLeadingNewline = false
            processStartTag(&token)
        case .EndTag:
            shouldSkipLeadingNewline = false
            processEndTag(&token)
        case .Comment:
            shouldSkipLeadingNewline = false
            processComment(&token)
        case .ProcessingInstruction:
            shouldSkipLeadingNewline = false
            processProcessingInstruction(&token)
        case .Character:
            processCharacter(&token)
        case .EndOfFile:
            shouldSkipLeadingNewline = false
            processEndOfFile(&token)
        default:
            // Uninitialized.
            break
        }
    }

    private func processDoctypeToken(_ token: inout AtomHTMLToken) {
        if insertionMode == .Initial {
            tree.insertDoctype(&token)
            insertionMode = .BeforeHTML
            return
        }
        if insertionMode == .InTableText {
            defaultForInTableText()
            processDoctypeToken(&token)
            return
        }
        parseError()
    }

    private func processFakeStartTag(
        _ tagName: WebCore.TagName,
        _ attributes: consuming WebCore.AttributeVector = WebCore.AttributeVector()
    ) {
        // FIXME: We'll need a fancier conversion than just "localName" for SVG/MathML tags.
        var fakeToken = AtomHTMLToken(.StartTag, tagName, attributes: attributes)
        processStartTag(&fakeToken)
    }

    private func processFakeEndTag(_ tagName: WebCore.TagName) {
        var fakeToken = AtomHTMLToken(.EndTag, tagName)
        processEndTag(&fakeToken)
    }

    private func processFakeEndTag(_ elementName: WebCore.ElementName, localName: WTF.AtomString) {
        var fakeToken = AtomHTMLToken(.EndTag, WebCore.tagNameForElementName(elementName), name: localName)
        processEndTag(&fakeToken)
    }

    /// Processes an end tag for the current node.
    private func processFakeEndTagForCurrentNode() {
        processFakeEndTag(tree.currentElementName, localName: tree.openElements.topLocalName)
    }

    private func processFakePEndTagIfPInButtonScope() {
        if !tree.openElements.inButtonScope(.HTML_p) {
            return
        }
        var endP = AtomHTMLToken(.EndTag, .p)
        processEndTag(&endP)
    }

    /// Closes the topmost element named `first` or `second`, if no special element other than address, div and p is
    /// above it, and inserts the token's element.
    private func processCloseWhenNestedTag(
        _ token: inout AtomHTMLToken,
        _ first: WebCore.ElementName,
        _ second: WebCore.ElementName
    ) {
        framesetOk = false
        let openElements = tree.openElements
        if let index = openElements.indexOfTopmostClosedWhenNested(first, second) {
            processFakeEndTag(openElements.elementName(at: index), localName: openElements.localName(at: index))
        }
        processFakePEndTagIfPInButtonScope()
        tree.insertHTMLElement(&token)
    }

    // MARK: Start tags

    private func processStartTagForInBody(_ token: inout AtomHTMLToken) {
        switch token.tagName {
        case .html:
            processHtmlStartTagForInBody(&token)
            return
        case .base, .basefont, .bgsound, .link, .meta, .noframes, .script, .style:
            if enhancedSelectQuirk && tree.openElements.inScope(.HTML_select) {
                parseError()
                return
            }
            fallthrough
        case .title:
            _ = processStartTagForInHead(&token)
            return
        case .body:
            parseError()
            let fragmentOrTemplateCase =
                !tree.openElements.secondElementIsHTMLBodyElement || tree.openElements.hasOnlyOneElement
                || tree.openElements.hasTemplateInHTMLScope
            if fragmentOrTemplateCase {
                return
            }
            framesetOk = false
            tree.insertHTMLBodyStartTagInBody(&token)
            return
        case .frameset:
            parseError()
            if !tree.openElements.secondElementIsHTMLBodyElement || tree.openElements.hasOnlyOneElement {
                return
            }
            if !framesetOk {
                return
            }
            removeFromParent(tree.openElements.bodyElement)
            tree.openElements.popUntil(tree.openElements.bodyElement)
            tree.openElements.popHTMLBodyElement()
            // In the fragment case the root is a DocumentFragment instead of a proper html element, which is a quirk
            // / optimization in WebKit.
            tree.insertHTMLElement(&token)
            insertionMode = .InFrameset
            return
        case .address, .article, .aside, .blockquote, .center, .details, .dialog, .dir, .div, .dl, .fieldset,
            .figcaption, .figure, .footer, .header, .hgroup, .main, .menu, .nav, .ol, .p, .search, .section,
            .summary, .ul:
            processFakePEndTagIfPInButtonScope()
            tree.insertHTMLElement(&token)
            return
        case .h1, .h2, .h3, .h4, .h5, .h6:
            processFakePEndTagIfPInButtonScope()
            if HTMLElementStack.isNumberedHeaderElement(tree.openElements.topWord) {
                parseError()
                tree.openElements.pop()
            }
            tree.insertHTMLElement(&token)
            return
        case .pre, .listing:
            processFakePEndTagIfPInButtonScope()
            tree.insertHTMLElement(&token)
            shouldSkipLeadingNewline = true
            framesetOk = false
            return
        case .form:
            if tree.form != nil && !isParsingTemplateContents {
                parseError()
                return
            }
            processFakePEndTagIfPInButtonScope()
            tree.insertHTMLFormElement(&token, isParsingTemplateContents: isParsingTemplateContents)
            return
        case .li:
            processCloseWhenNestedTag(&token, .HTML_li, .HTML_li)
            return
        case .dd, .dt:
            processCloseWhenNestedTag(&token, .HTML_dd, .HTML_dt)
            return
        case .plaintext:
            processFakePEndTagIfPInButtonScope()
            tree.insertHTMLElement(&token)
            parser.setTokenizerPLAINTEXTState()
            return
        case .button:
            if tree.openElements.inScope(.HTML_button) {
                parseError()
                processFakeEndTag(.button)
                processStartTag(&token)  // FIXME: Could we just fall through here?
                return
            }
            tree.reconstructTheActiveFormattingElements()
            tree.insertHTMLElement(&token)
            framesetOk = false
            return
        case .a:
            if let activeATag = tree.activeFormattingElements.closestElementInScopeWithName(.HTML_a) {
                parseError()
                processFakeEndTag(.a)
                tree.activeFormattingElements.remove(activeATag)
                if tree.openElements.contains(activeATag) {
                    tree.openElements.remove(activeATag)
                }
            }
            tree.reconstructTheActiveFormattingElements()
            tree.insertFormattingElement(&token)
            return
        case .b, .big, .code, .em, .font, .i, .s, .small_, .strike, .strong, .tt, .u:
            tree.reconstructTheActiveFormattingElements()
            tree.insertFormattingElement(&token)
            return
        case .nobr:
            tree.reconstructTheActiveFormattingElements()
            if tree.openElements.inScope(.HTML_nobr) {
                parseError()
                processFakeEndTag(.nobr)
                tree.reconstructTheActiveFormattingElements()
            }
            tree.insertFormattingElement(&token)
            return
        case .applet, .object, .marquee:
            tree.reconstructTheActiveFormattingElements()
            tree.insertHTMLElement(&token)
            tree.activeFormattingElements.appendMarker()
            framesetOk = false
            return
        case .table:
            if !tree.inQuirksMode && tree.openElements.inButtonScope(.HTML_p) {
                processFakeEndTag(.p)
            }
            tree.insertHTMLElement(&token)
            framesetOk = false
            insertionMode = .InTable
            if tree.hasReachedMaxDOMTreeDepth {
                resetInsertionModeAppropriately()
            }
            return
        case .image:
            parseError()
            // Apparently we're not supposed to ask.
            token.tagName = .img
            fallthrough
        case .area, .br, .embed, .img, .keygen, .wbr:
            tree.reconstructTheActiveFormattingElements()
            tree.insertSelfClosingHTMLElement(&token)
            framesetOk = false
            return
        case .input:
            if isParsingFragment && contextElementItem!.elementName == .HTML_select {
                parseError()
                return
            }
            if tree.openElements.inScope(.HTML_select) {
                parseError()
                tree.openElements.popUntilPopped(.HTML_select)
            }
            tree.reconstructTheActiveFormattingElements()
            let shouldClearFramesetOK: Bool
            if let typeAttribute = findAttributeValue(token, typeAttribute()) {
                var type = typeAttribute
                shouldClearFramesetOK = !equalLettersIgnoringASCIICase(type.releaseString(), "hidden")
            } else {
                shouldClearFramesetOK = true
            }
            tree.insertSelfClosingHTMLElement(&token)
            if shouldClearFramesetOK {
                framesetOk = false
            }
            return
        case .param, .source, .track:
            tree.insertSelfClosingHTMLElement(&token)
            return
        case .hr:
            processFakePEndTagIfPInButtonScope()
            if tree.openElements.inScope(.HTML_select) {
                tree.generateImpliedEndTags()
                if tree.openElements.inScope(.HTML_option) || tree.openElements.inScope(.HTML_optgroup) {
                    parseError()
                }
            }
            tree.insertSelfClosingHTMLElement(&token)
            framesetOk = false
            return
        case .textarea:
            tree.insertHTMLElement(&token)
            shouldSkipLeadingNewline = true
            parser.setTokenizerRCDATAState()
            originalInsertionMode = insertionMode
            framesetOk = false
            insertionMode = .Text
            return
        case .xmp:
            processFakePEndTagIfPInButtonScope()
            tree.reconstructTheActiveFormattingElements()
            framesetOk = false
            processGenericRawTextStartTag(&token)
            return
        case .iframe:
            framesetOk = false
            processGenericRawTextStartTag(&token)
            return
        case .noembed:
            processGenericRawTextStartTag(&token)
            return
        case .noscript:
            if scriptingFlag {
                processGenericRawTextStartTag(&token)
                return
            }
        case .select:
            if isParsingFragment && contextElementItem!.elementName == .HTML_select {
                parseError()
                return
            }
            if tree.openElements.inScope(.HTML_select) {
                parseError()
                tree.openElements.popUntilPopped(.HTML_select)
                return
            }
            tree.reconstructTheActiveFormattingElements()
            tree.insertHTMLElement(&token)
            framesetOk = false
            return
        case .optgroup:
            if tree.openElements.inScope(.HTML_select) {
                tree.generateImpliedEndTags()
                if tree.openElements.inScope(.HTML_option) || tree.openElements.inScope(.HTML_optgroup) {
                    parseError()
                }
            } else if tree.currentElementName == .HTML_option {
                processFakeEndTag(.option)
            }

            tree.reconstructTheActiveFormattingElements()
            tree.insertHTMLElement(&token)
            return
        case .option:
            if tree.openElements.inScope(.HTML_select) {
                tree.generateImpliedEndTagsWithExclusion(.HTML_optgroup)
                if tree.openElements.inScope(.HTML_option) {
                    parseError()
                }
            } else if tree.currentElementName == .HTML_option {
                processFakeEndTag(.option)
            }

            tree.reconstructTheActiveFormattingElements()
            tree.insertHTMLElement(&token)
            return
        case .rb, .rtc:
            if tree.openElements.inScope(.HTML_ruby) {
                tree.generateImpliedEndTags()
                if tree.currentElementName != .HTML_ruby {
                    parseError()
                }
            }
            tree.insertHTMLElement(&token)
            return
        case .rt, .rp:
            if tree.openElements.inScope(.HTML_ruby) {
                tree.generateImpliedEndTagsWithExclusion(.HTML_rtc)
                if tree.currentElementName != .HTML_ruby && tree.currentElementName != .HTML_rtc {
                    parseError()
                }
            }
            tree.insertHTMLElement(&token)
            return
        case .math:
            tree.reconstructTheActiveFormattingElements()
            adjustMathMLAttributes(&token)
            adjustForeignAttributes(&token)
            tree.insertForeignElement(&token, foreignContentNames.mathMLNamespace)
            return
        case .svg:
            tree.reconstructTheActiveFormattingElements()
            adjustSVGAttributes(&token)
            adjustForeignAttributes(&token)
            tree.insertForeignElement(&token, foreignContentNames.svgNamespace)
            return
        case .caption, .col, .colgroup, .frame, .head, .tbody, .tfoot, .thead, .th, .td, .tr:
            parseError()
            return
        case .template_:
            framesetOk = false
            processTemplateStartTag(&token)
            return
        default:
            break
        }
        tree.reconstructTheActiveFormattingElements()
        insertGenericHTMLElement(&token)
    }

    /// Inserts the element, or hands a custom element to construct to the parser.
    private func insertGenericHTMLElement(_ token: inout AtomHTMLToken) {
        _ = tree.insertHTMLElementOrFindCustomElementInterface(&token)
    }

    private func processTemplateStartTag(_ token: inout AtomHTMLToken) {
        tree.activeFormattingElements.appendMarker()
        tree.insertHTMLTemplateElement(&token)
        framesetOk = false
        changeTemplateInsertionModes { $0.append(.TemplateContents) }
        insertionMode = .TemplateContents
    }

    @discardableResult
    private func processTemplateEndTag(_ token: inout AtomHTMLToken) -> Bool {
        if !tree.openElements.hasTemplateInHTMLScope {
            parseError()
            return false
        }
        tree.generateImpliedEndTags()
        if tree.currentElementName != .HTML_template {
            parseError()
        }
        tree.openElements.popUntil(.HTML_template)
        // The template is kept alive while it is popped.
        let templateElement = tree.openElements.topElement
        withExtendedLifetime(templateElement) {
            tree.openElements.pop()
        }

        tree.activeFormattingElements.clearToLastMarker()
        changeTemplateInsertionModes { _ = $0.removeLast() }
        resetInsertionModeAppropriately()

        return true
    }

    private func processEndOfFileForInTemplateContents(_ token: inout AtomHTMLToken) -> Bool {
        var endTemplate = AtomHTMLToken(.EndTag, .template_)
        if !processTemplateEndTag(&endTemplate) {
            return false
        }

        processEndOfFile(&token)
        return true
    }

    @discardableResult
    private func processColgroupEndTagForInColumnGroup() -> Bool {
        let ignoreFakeEndTag = tree.currentIsRootNode || tree.currentElementName == .HTML_template

        if ignoreFakeEndTag {
            // FIXME: parse error
            return false
        }
        tree.openElements.pop()
        insertionMode = .InTable
        return true
    }

    /// https://html.spec.whatwg.org/multipage/parsing.html#close-the-cell
    private func closeTheCell() {
        if tree.openElements.inTableScope(.HTML_td) {
            processFakeEndTag(.td)
            return
        }
        processFakeEndTag(.th)
    }

    private func processStartTagForInTable(_ token: inout AtomHTMLToken) {
        switch token.tagName {
        case .caption:
            tree.openElements.popUntilTableScopeMarker()
            tree.activeFormattingElements.appendMarker()
            tree.insertHTMLElement(&token)
            insertionMode = .InCaption
            if tree.hasReachedMaxDOMTreeDepth {
                resetInsertionModeAppropriately()
            }
            return
        case .colgroup:
            tree.openElements.popUntilTableScopeMarker()
            tree.insertHTMLElement(&token)
            insertionMode = .InColumnGroup
            if tree.hasReachedMaxDOMTreeDepth {
                resetInsertionModeAppropriately()
            }
            return
        case .col:
            processFakeStartTag(.colgroup)
            processStartTag(&token)
            return
        case .tbody, .tfoot, .thead:
            tree.openElements.popUntilTableScopeMarker()
            tree.insertHTMLElement(&token)
            insertionMode = .InTableBody
            if tree.hasReachedMaxDOMTreeDepth {
                resetInsertionModeAppropriately()
            }
            return
        case .th, .td, .tr:
            processFakeStartTag(.tbody)
            processStartTag(&token)
            return
        case .table:
            parseError()
            if !processTableEndTagForInTable() {
                return
            }
            processStartTag(&token)
            return
        case .style, .script:
            _ = processStartTagForInHead(&token)
            return
        case .input:
            if let typeAttribute = findAttributeValue(token, typeAttribute()) {
                var type = typeAttribute
                if equalLettersIgnoringASCIICase(type.releaseString(), "hidden") {
                    parseError()
                    tree.insertSelfClosingHTMLElement(&token)
                    return
                }
            }
            // Break out to "anything else" case.
        case .form:
            parseError()
            if tree.form != nil && !isParsingTemplateContents {
                return
            }
            tree.insertHTMLFormElement(&token, isParsingTemplateContents: isParsingTemplateContents)
            tree.openElements.pop()
            return
        case .template_:
            processTemplateStartTag(&token)
            return
        default:
            break
        }
        parseError()
        tree.withRedirectToFosterParent {
            processStartTagForInBody(&token)
        }
    }

    private func processStartTag(_ token: inout AtomHTMLToken) {
        switch insertionMode {
        case .Initial:
            defaultForInitial()
            fallthrough
        case .BeforeHTML:
            if token.tagName == .html {
                tree.insertHTMLHtmlStartTagBeforeHTML(&token)
                insertionMode = .BeforeHead
                return
            }
            defaultForBeforeHTML()
            fallthrough
        case .BeforeHead:
            if token.tagName == .html {
                processHtmlStartTagForInBody(&token)
                return
            }
            if token.tagName == .head {
                tree.insertHTMLHeadElement(&token)
                insertionMode = .InHead
                return
            }
            defaultForBeforeHead()
            fallthrough
        case .InHead:
            if processStartTagForInHead(&token) {
                return
            }
            defaultForInHead()
            fallthrough
        case .AfterHead:
            switch token.tagName {
            case .html:
                processHtmlStartTagForInBody(&token)
                return
            case .body:
                framesetOk = false
                tree.insertHTMLBodyElement(&token)
                insertionMode = .InBody
                return
            case .frameset:
                tree.insertHTMLElement(&token)
                insertionMode = .InFrameset
                return
            case .base, .basefont, .bgsound, .link, .meta, .noframes, .script, .style, .template_, .title:
                parseError()
                let head = tree.head!
                let headElement = head.element!
                tree.openElements.pushHTMLHeadElement(head)
                _ = processStartTagForInHead(&token)
                tree.openElements.removeHTMLHeadElement(headElement)
                return
            case .head:
                parseError()
                return
            default:
                break
            }
            defaultForAfterHead()
            fallthrough
        case .InBody:
            processStartTagForInBody(&token)
        case .InTable:
            processStartTagForInTable(&token)
        case .InCaption:
            switch token.tagName {
            case .caption, .col, .colgroup, .tbody, .tfoot, .thead, .th, .td, .tr:
                parseError()
                if !processCaptionEndTagForInCaption() {
                    return
                }
                processStartTag(&token)
                return
            default:
                break
            }
            processStartTagForInBody(&token)
        case .InColumnGroup:
            switch token.tagName {
            case .html:
                processHtmlStartTagForInBody(&token)
                return
            case .col:
                tree.insertSelfClosingHTMLElement(&token)
                return
            case .template_:
                processTemplateStartTag(&token)
                return
            default:
                break
            }
            if !processColgroupEndTagForInColumnGroup() {
                return
            }
            processStartTag(&token)
        case .InTableBody:
            switch token.tagName {
            case .tr:
                tree.openElements.popUntilTableBodyScopeMarker()  // How is there ever anything to pop?
                tree.insertHTMLElement(&token)
                insertionMode = .InRow
                if tree.hasReachedMaxDOMTreeDepth {
                    resetInsertionModeAppropriately()
                }
                return
            case .th, .td:
                parseError()
                processFakeStartTag(.tr)
                processStartTag(&token)
                return
            case .caption, .col, .colgroup, .tbody, .tfoot, .thead:
                if !tree.openElements.hasAnyInTableScope(.HTML_tbody, .HTML_thead, .HTML_tfoot) {
                    parseError()
                    return
                }
                tree.openElements.popUntilTableBodyScopeMarker()
                processFakeEndTagForCurrentNode()
                processStartTag(&token)
                return
            default:
                break
            }
            processStartTagForInTable(&token)
        case .InRow:
            switch token.tagName {
            case .th, .td:
                tree.openElements.popUntilTableRowScopeMarker()
                tree.insertHTMLElement(&token)
                insertionMode = .InCell
                if tree.hasReachedMaxDOMTreeDepth {
                    resetInsertionModeAppropriately()
                }
                tree.activeFormattingElements.appendMarker()
                return
            case .tr, .caption, .col, .colgroup, .tbody, .tfoot, .thead:
                if !processTrEndTagForInRow() {
                    return
                }
                processStartTag(&token)
                return
            default:
                break
            }
            processStartTagForInTable(&token)
        case .InCell:
            switch token.tagName {
            case .caption, .col, .colgroup, .th, .td, .tr, .tbody, .tfoot, .thead:
                if !tree.openElements.hasAnyInTableScope(.HTML_td, .HTML_th) {
                    parseError()
                    return
                }
                closeTheCell()
                processStartTag(&token)
                return
            default:
                break
            }
            processStartTagForInBody(&token)
            if insertionMode == .InCell && tree.hasReachedMaxDOMTreeDepth
                && !tree.openElements.hasAnyInTableScope(.HTML_td, .HTML_th)
            {
                resetInsertionModeAppropriately()
            }
        case .AfterBody, .AfterAfterBody:
            if token.tagName == .html {
                processHtmlStartTagForInBody(&token)
                return
            }
            insertionMode = .InBody
            processStartTag(&token)
        case .InHeadNoscript:
            switch token.tagName {
            case .html:
                processHtmlStartTagForInBody(&token)
                return
            case .basefont, .bgsound, .link, .meta, .noframes, .style:
                _ = processStartTagForInHead(&token)
                return
            case .head, .noscript:
                parseError()
                return
            default:
                break
            }
            defaultForInHeadNoscript()
            processToken(&token)
        case .InFrameset:
            switch token.tagName {
            case .html:
                processHtmlStartTagForInBody(&token)
                return
            case .frameset:
                tree.insertHTMLElement(&token)
                return
            case .frame:
                tree.insertSelfClosingHTMLElement(&token)
                return
            case .noframes:
                _ = processStartTagForInHead(&token)
                return
            default:
                break
            }
            parseError()
        case .AfterFrameset, .AfterAfterFrameset:
            switch token.tagName {
            case .html:
                processHtmlStartTagForInBody(&token)
                return
            case .noframes:
                _ = processStartTagForInHead(&token)
                return
            default:
                break
            }
            parseError()
        case .InTableText:
            defaultForInTableText()
            processStartTag(&token)
        case .Text:
            break
        case .TemplateContents:
            let templateMode: InsertionMode
            switch token.tagName {
            case .template_:
                processTemplateStartTag(&token)
                return
            case .link, .meta, .script, .style:
                _ = processStartTagForInHead(&token)
                return
            case .caption, .colgroup, .tbody, .tfoot, .thead:
                templateMode = .InTable
            case .col:
                templateMode = .InColumnGroup
            case .tr:
                templateMode = .InTableBody
            case .td, .th:
                templateMode = .InRow
            default:
                templateMode = .InBody
            }
            changeTemplateInsertionModes { $0[$0.count - 1] = templateMode }
            insertionMode = templateMode
            processStartTag(&token)
        }
    }

    private func processHtmlStartTagForInBody(_ token: inout AtomHTMLToken) {
        parseError()
        if tree.openElements.hasTemplateInHTMLScope {
            return
        }
        tree.insertHTMLHtmlStartTagInBody(&token)
    }

    private func processStartTagForInHead(_ token: inout AtomHTMLToken) -> Bool {
        switch token.tagName {
        case .html:
            processHtmlStartTagForInBody(&token)
            return true
        case .base, .basefont, .bgsound, .link, .meta:
            tree.insertSelfClosingHTMLElement(&token)
            // Note: The custom processing for the <meta> tag is done in HTMLMetaElement::process().
            return true
        case .title:
            processGenericRCDATAStartTag(&token)
            return true
        case .noscript:
            if scriptingFlag {
                processGenericRawTextStartTag(&token)
                return true
            }
            tree.insertHTMLElement(&token)
            insertionMode = .InHeadNoscript
            return true
        case .noframes, .style:
            processGenericRawTextStartTag(&token)
            return true
        case .script:
            let isSelfClosing = token.selfClosing
            processScriptStartTag(&token)
            if usePreHTML5ParserQuirks && isSelfClosing {
                processFakeEndTag(.script)
            }
            return true
        case .template_:
            framesetOk = false
            processTemplateStartTag(&token)
            return true
        case .head:
            parseError()
            return true
        default:
            break
        }
        return false
    }

    private func processGenericRCDATAStartTag(_ token: inout AtomHTMLToken) {
        tree.insertHTMLElement(&token)
        parser.setTokenizerRCDATAState()
        originalInsertionMode = insertionMode
        insertionMode = .Text
    }

    private func processGenericRawTextStartTag(_ token: inout AtomHTMLToken) {
        tree.insertHTMLElement(&token)
        parser.setTokenizerRAWTEXTState()
        originalInsertionMode = insertionMode
        insertionMode = .Text
    }

    private func processScriptStartTag(_ token: inout AtomHTMLToken) {
        tree.insertScriptElement(&token)
        let parser = self.parser
        parser.setTokenizerScriptDataState()
        originalInsertionMode = insertionMode

        let position = parser.textPosition()

        scriptToProcessStartPosition = position

        insertionMode = .Text
    }

    /// Hands the script element to the parser, which runs it before the next token, with where it started.
    private func setScriptToProcess(_ element: WebCore.Element) {
        let position = scriptToProcessStartPosition
        // The position goes with the script, as HTMLDocumentParser takes it.
        scriptToProcessStartPosition = Self.uninitializedPosition
        parser.setScriptToProcess(element, position)
    }

    // MARK: End tags

    @discardableResult
    private func processBodyEndTagForInBody(_ token: inout AtomHTMLToken) -> Bool {
        if !tree.openElements.inScope(.HTML_body) {
            parseError()
            return false
        }
        // Emit a more specific parse error based on stack contents.
        insertionMode = .AfterBody
        return true
    }

    private func processAnyOtherEndTagForInBody(_ token: inout AtomHTMLToken) {
        let elementName = WebCore.elementNameForTag(.HTML, token.tagName)
        let openElements = tree.openElements
        if elementName != .Unknown {
            guard let index = openElements.indexOfAnyOtherEndTagTarget(elementName) else {
                parseError()
                return
            }
            let element = openElements.element(at: index)!
            tree.generateImpliedEndTagsWithExclusion(elementName)
            if tree.currentElementName != elementName {
                parseError()
            }
            openElements.popUntilPopped(element)
            return
        }
        let name = token.name
        guard let index = openElements.indexOfAnyOtherEndTagTarget(localName: name) else {
            parseError()
            return
        }
        let element = openElements.element(at: index)!
        tree.generateImpliedEndTagsWithExclusion(name)
        if !openElements.topMatchesHTMLTag(name) {
            parseError()
        }
        openElements.popUntilPopped(element)
    }

    /// https://html.spec.whatwg.org/multipage/parsing.html#adoption-agency-algorithm
    private func callTheAdoptionAgency(_ token: inout AtomHTMLToken) {
        // The adoption agency algorithm is N^2. The number of iterations is limited to stop from hanging the whole
        // browser. This limit is specified in the adoption agency algorithm.
        let outerIterationLimit = 8
        let innerIterationLimit = 3

        let subject = WebCore.elementNameForTag(.HTML, token.tagName)
        let openElements = tree.openElements
        let activeFormattingElements = tree.activeFormattingElements

        // 2. If the current node is an HTML element whose tag name is subject, and the current node is not in the
        // list of active formatting elements, then pop the current node off the stack of open elements and return.
        if !tree.isEmpty && openElements.topIsElement && tree.currentElement.elementName() == subject
            && !activeFormattingElements.contains(tree.currentElement)
        {
            openElements.pop()
            return
        }

        // 4 is covered by the loop.
        for _ in 0..<outerIterationLimit {
            // 4.3.
            guard let formattingElement = activeFormattingElements.closestElementInScopeWithName(subject) else {
                return processAnyOtherEndTagForInBody(&token)
            }
            // 4.5.
            if openElements.contains(formattingElement) && !openElements.inScope(formattingElement) {
                parseError()
                // Check the stack of open elements for a more specific parse error.
                return
            }
            // 4.4.
            guard let formattingElementRecord = openElements.find(formattingElement) else {
                parseError()
                activeFormattingElements.remove(formattingElement)
                return
            }
            // 4.6.
            if !formattingElement.isSameNode(tree.currentElement) {
                parseError()
            }
            // 4.7.
            // 4.8.
            guard let furthestBlock = openElements.furthestBlockForFormattingElement(formattingElement) else {
                openElements.popUntilPopped(formattingElement)
                activeFormattingElements.remove(formattingElement)
                return
            }
            // 4.9.
            let commonAncestor = openElements.next(formattingElementRecord)!
            // 4.10.
            var bookmark = activeFormattingElements.bookmarkFor(formattingElement)
            // 4.11.
            var node = furthestBlock
            var lastNode = furthestBlock
            var nextNode = openElements.next(node)
            // 4.13.
            var innerLoopCounter = 0
            while true {
                innerLoopCounter += 1
                // 4.13.2.
                node = nextNode!
                // Save the next record for the next iteration in case node is removed in the next step.
                nextNode = openElements.next(node)
                // 4.13.3.
                if node.isSame(formattingElementRecord) {
                    break
                }
                // 4.13.4.
                let nodeElement = node.element!
                let nodeIsInListOfActiveFormattingElements = activeFormattingElements.contains(nodeElement)
                if innerLoopCounter > innerIterationLimit && nodeIsInListOfActiveFormattingElements {
                    activeFormattingElements.removeUpdatingBookmark(nodeElement, &bookmark)
                }
                // 4.13.5.
                guard let nodeEntryIndex = activeFormattingElements.find(nodeElement) else {
                    openElements.remove(nodeElement)
                    continue
                }
                // 4.13.6. The entry is the one node was pushed with.
                let newEntry = tree.createElementFromSavedToken(activeFormattingElements.at(nodeEntryIndex)!)
                let newItem = HTMLStackItem(newEntry)

                activeFormattingElements.replaceElement(at: nodeEntryIndex, with: newEntry)
                // The new item takes the record's place on the stack, and is the record from here on.
                openElements.replaceElement(node, with: newItem)
                node = newItem

                // 4.13.7.
                if lastNode.isSame(furthestBlock) {
                    bookmark.moveToAfter(nodeEntryIndex)
                }
                // 4.13.8.
                tree.reparent(node, lastNode)
                // 4.13.9.
                lastNode = node
            }
            // 14.
            tree.insertAlreadyParsedChild(commonAncestor, lastNode)
            // 15. The formatting element's entry is the one it was pushed with.
            let newEntry = tree.createElementFromSavedToken(
                activeFormattingElements.at(activeFormattingElements.find(formattingElement)!)!
            )
            let newItem = HTMLStackItem(newEntry)
            // 16.
            tree.takeAllChildrenAndReparent(newItem, furthestBlock)
            openElements.insertAbove(newItem, furthestBlock)
            // 18.
            activeFormattingElements.swapTo(formattingElement, newEntry, bookmark)
            // 19.
            openElements.remove(formattingElement)
        }
    }

    /// https://html.spec.whatwg.org/multipage/parsing.html#reset-the-insertion-mode-appropriately
    private func resetInsertionModeAppropriately() {
        let openElements = tree.openElements
        let rootNode = openElements.rootNode
        var last = false
        var index = openElements.itemCount - 1
        while true {
            var node = openElements.node(at: index)
            var elementName = openElements.elementName(at: index)

            if node.isSameNode(rootNode) {
                last = true
                if isParsingFragment {
                    node = contextElementItem!.node
                    elementName = contextElementItem!.elementName
                }
            }

            switch elementName {
            case .HTML_template:
                insertionMode = templateInsertionModes[templateInsertionModes.count - 1]
                return
            case .HTML_td, .HTML_th:
                insertionMode = .InCell
                return
            case .HTML_tr:
                insertionMode = .InRow
                return
            case .HTML_tbody, .HTML_thead, .HTML_tfoot:
                insertionMode = .InTableBody
                return
            case .HTML_caption:
                insertionMode = .InCaption
                return
            case .HTML_colgroup:
                insertionMode = .InColumnGroup
                return
            case .HTML_table:
                insertionMode = .InTable
                return
            case .HTML_head:
                if !isParsingFragment || !contextElementItem!.node.isSameNode(node) {
                    insertionMode = .InHead
                    return
                }
                insertionMode = .InBody
                return
            case .HTML_body:
                insertionMode = .InBody
                return
            case .HTML_frameset:
                insertionMode = .InFrameset
                return
            case .HTML_html:
                if tree.head != nil {
                    insertionMode = .AfterHead
                    return
                }
                insertionMode = .BeforeHead
                return
            default:
                if last {
                    insertionMode = .InBody
                    return
                }
            }
            index -= 1
        }
    }

    private func processEndTagForInBody(_ token: inout AtomHTMLToken) {
        switch token.tagName {
        case .body:
            processBodyEndTagForInBody(&token)
            return
        case .html:
            var endBody = AtomHTMLToken(.EndTag, .body)
            if processBodyEndTagForInBody(&endBody) {
                processEndTag(&token)
            }
            return
        case .address, .article, .aside, .blockquote, .button, .center, .details, .dialog, .dir, .div, .dl,
            .fieldset, .figcaption, .figure, .footer, .header, .hgroup, .listing, .main, .menu, .nav, .ol, .pre,
            .search, .section, .select, .summary, .ul:
            let elementName = WebCore.elementNameForTag(.HTML, token.tagName)
            if !tree.openElements.inScope(elementName) {
                parseError()
                return
            }
            tree.generateImpliedEndTags()
            if tree.currentElementName != elementName {
                parseError()
            }
            tree.openElements.popUntilPopped(elementName)
            return
        case .form:
            if !isParsingTemplateContents {
                let formElement = tree.takeForm()
                guard let formElement, tree.openElements.inScope(formElement) else {
                    parseError()
                    return
                }
                tree.generateImpliedEndTags()
                if !tree.currentNode.isSameNode(formElement) {
                    parseError()
                }
                tree.openElements.remove(formElement)
            } else {
                if !tree.openElements.inScope(.HTML_form) {
                    parseError()
                    return
                }
                tree.generateImpliedEndTags()
                if tree.currentElementName != .HTML_form {
                    parseError()
                }
                tree.openElements.popUntilPopped(.HTML_form)
            }
            return
        case .p:
            if !tree.openElements.inButtonScope(.HTML_p) {
                parseError()
                processFakeStartTag(.p)
                processEndTag(&token)
                return
            }
            tree.generateImpliedEndTagsWithExclusion(.HTML_p)
            if tree.currentElementName != .HTML_p {
                parseError()
            }
            tree.openElements.popUntilPopped(.HTML_p)
            return
        case .li:
            if !tree.openElements.inListItemScope(.HTML_li) {
                parseError()
                return
            }
            tree.generateImpliedEndTagsWithExclusion(.HTML_li)
            if tree.currentElementName != .HTML_li {
                parseError()
            }
            tree.openElements.popUntilPopped(.HTML_li)
            return
        case .dd, .dt:
            let elementName = WebCore.elementNameForTag(.HTML, token.tagName)
            if !tree.openElements.inScope(elementName) {
                parseError()
                return
            }
            tree.generateImpliedEndTagsWithExclusion(elementName)
            if tree.currentElementName != elementName {
                parseError()
            }
            tree.openElements.popUntilPopped(elementName)
            return
        case .h1, .h2, .h3, .h4, .h5, .h6:
            if !tree.openElements.hasNumberedHeaderElementInScope() {
                parseError()
                return
            }
            tree.generateImpliedEndTags()
            if tree.currentElementName != WebCore.elementNameForTag(.HTML, token.tagName) {
                parseError()
            }
            tree.openElements.popUntilNumberedHeaderElementPopped()
            return
        case .a, .b, .big, .code, .em, .font, .i, .nobr, .s, .small_, .strike, .strong, .tt, .u:
            callTheAdoptionAgency(&token)
            return
        case .applet, .marquee, .object:
            let elementName = WebCore.elementNameForTag(.HTML, token.tagName)
            if !tree.openElements.inScope(elementName) {
                parseError()
                return
            }
            tree.generateImpliedEndTags()
            if tree.currentElementName != elementName {
                parseError()
            }
            tree.openElements.popUntilPopped(elementName)
            tree.activeFormattingElements.clearToLastMarker()
            return
        case .br:
            parseError()
            processFakeStartTag(.br)
            return
        case .template_:
            processTemplateEndTag(&token)
            return
        default:
            break
        }
        processAnyOtherEndTagForInBody(&token)
    }

    private func processEndTag(_ token: inout AtomHTMLToken) {
        switch insertionMode {
        case .Initial:
            defaultForInitial()
            fallthrough
        case .BeforeHTML:
            switch token.tagName {
            case .head, .body, .html, .br:
                break
            default:
                parseError()
                return
            }
            defaultForBeforeHTML()
            fallthrough
        case .BeforeHead:
            switch token.tagName {
            case .head, .body, .html, .br:
                break
            default:
                parseError()
                return
            }
            defaultForBeforeHead()
            fallthrough
        case .InHead:
            // FIXME: This case should be broken out into processEndTagForInHead, because other end tag cases now
            // refer to it ("process the token for using the rules of the "in head" insertion mode"). But because
            // the logic falls through to AfterHead, that gets a little messy.
            switch token.tagName {
            case .template_:
                processTemplateEndTag(&token)
                return
            case .head:
                tree.openElements.popHTMLHeadElement()
                insertionMode = .AfterHead
                return
            case .body, .html, .br:
                break
            default:
                parseError()
                return
            }
            defaultForInHead()
            fallthrough
        case .AfterHead:
            switch token.tagName {
            case .body, .html, .br:
                break
            default:
                parseError()
                return
            }
            defaultForAfterHead()
            fallthrough
        case .InBody:
            processEndTagForInBody(&token)
        case .InTable:
            processEndTagForInTable(&token)
        case .InCaption:
            switch token.tagName {
            case .caption:
                processCaptionEndTagForInCaption()
                return
            case .table:
                parseError()
                if !processCaptionEndTagForInCaption() {
                    return
                }
                processEndTag(&token)
                return
            case .body, .col, .colgroup, .html, .tbody, .thead, .tfoot, .th, .td, .tr:
                parseError()
                return
            default:
                break
            }
            processEndTagForInBody(&token)
        case .InColumnGroup:
            switch token.tagName {
            case .colgroup:
                processColgroupEndTagForInColumnGroup()
                return
            case .col:
                parseError()
                return
            case .template_:
                processTemplateEndTag(&token)
                return
            default:
                break
            }
            if !processColgroupEndTagForInColumnGroup() {
                return
            }
            processEndTag(&token)
        case .InRow:
            processEndTagForInRow(&token)
        case .InCell:
            processEndTagForInCell(&token)
        case .InTableBody:
            processEndTagForInTableBody(&token)
        case .AfterBody:
            if token.tagName == .html {
                if isParsingFragment {
                    parseError()
                    return
                }
                insertionMode = .AfterAfterBody
                return
            }
            fallthrough
        case .AfterAfterBody:
            parseError()
            insertionMode = .InBody
            processEndTag(&token)
        case .InHeadNoscript:
            switch token.tagName {
            case .noscript:
                tree.openElements.pop()
                insertionMode = .InHead
                return
            case .br:
                break
            default:
                parseError()
                return
            }
            defaultForInHeadNoscript()
            processToken(&token)
        case .Text:
            if token.tagName == .script {
                // Pause so that parsing stops until the script can be processed by the caller.
                if scriptingContentIsAllowed {
                    setScriptToProcess(tree.currentElement)
                }
                tree.openElements.pop()
                insertionMode = originalInsertionMode

                // This token will not have been created by the tokenizer if a self-closing script tag was
                // encountered and pre-HTML5 parser quirks are enabled. The tokenizer's state must be set to
                // DataState explicitly if the tokenizer didn't have a chance to.
                parser.setTokenizerDataState()
                return
            }
            tree.openElements.pop()
            insertionMode = originalInsertionMode
        case .InFrameset:
            if token.tagName == .frameset {
                let ignoreFramesetForFragmentParsing =
                    tree.currentIsRootNode || tree.openElements.hasTemplateInHTMLScope
                if ignoreFramesetForFragmentParsing {
                    parseError()
                    return
                }
                tree.openElements.pop()
                if !isParsingFragment && tree.currentElementName != .HTML_frameset {
                    insertionMode = .AfterFrameset
                }
                return
            }
        case .AfterFrameset:
            if token.tagName == .html {
                insertionMode = .AfterAfterFrameset
                return
            }
            fallthrough
        case .AfterAfterFrameset:
            parseError()
        case .InTableText:
            defaultForInTableText()
            processEndTag(&token)
        case .TemplateContents:
            if token.tagName == .template_ {
                processTemplateEndTag(&token)
                return
            }
        }
    }

    private func processEndTagForInTableBody(_ token: inout AtomHTMLToken) {
        switch token.tagName {
        case .tbody, .tfoot, .thead:
            if !tree.openElements.inTableScope(WebCore.elementNameForTag(.HTML, token.tagName)) {
                parseError()
                return
            }
            tree.openElements.popUntilTableBodyScopeMarker()
            tree.openElements.pop()
            insertionMode = .InTable
            return
        case .table:
            if !tree.openElements.hasAnyInTableScope(.HTML_tbody, .HTML_thead, .HTML_tfoot) {
                if !isParsingFragmentOrTemplateContents {
                    resetInsertionModeAppropriately()
                }
                parseError()
                return
            }
            tree.openElements.popUntilTableBodyScopeMarker()
            processFakeEndTagForCurrentNode()
            processEndTag(&token)
            return
        case .body, .caption, .col, .colgroup, .html, .th, .td, .tr:
            parseError()
            return
        default:
            break
        }
        processEndTagForInTable(&token)
    }

    private func processEndTagForInRow(_ token: inout AtomHTMLToken) {
        switch token.tagName {
        case .tr:
            processTrEndTagForInRow()
            return
        case .table:
            if !processTrEndTagForInRow() {
                return
            }
            processEndTag(&token)
            return
        case .tbody, .tfoot, .thead:
            if !tree.openElements.inTableScope(WebCore.elementNameForTag(.HTML, token.tagName)) {
                parseError()
                return
            }
            processFakeEndTag(.tr)
            processEndTag(&token)
            return
        case .body, .caption, .col, .colgroup, .html, .th, .td:
            parseError()
            return
        default:
            break
        }
        processEndTagForInTable(&token)
    }

    private func processEndTagForInCell(_ token: inout AtomHTMLToken) {
        switch token.tagName {
        case .th, .td:
            let elementName = WebCore.elementNameForTag(.HTML, token.tagName)
            if !tree.openElements.inTableScope(elementName) {
                parseError()
                return
            }
            tree.generateImpliedEndTags()
            if tree.currentElementName != elementName {
                parseError()
            }
            tree.openElements.popUntilPopped(elementName)
            tree.activeFormattingElements.clearToLastMarker()
            insertionMode = .InRow
            return
        case .body, .caption, .col, .colgroup, .html:
            parseError()
            return
        case .table, .tr, .tbody, .tfoot, .thead:
            if !tree.openElements.inTableScope(WebCore.elementNameForTag(.HTML, token.tagName)) {
                parseError()
                return
            }
            closeTheCell()
            processEndTag(&token)
            return
        default:
            break
        }
        processEndTagForInBody(&token)
    }

    @discardableResult
    private func processCaptionEndTagForInCaption() -> Bool {
        if !tree.openElements.inTableScope(.HTML_caption) {
            // FIXME: parse error
            return false
        }
        tree.generateImpliedEndTags()
        // FIXME: parse error if (m_tree.currentStackItem().elementName() != HTML::caption)
        tree.openElements.popUntilPopped(.HTML_caption)
        tree.activeFormattingElements.clearToLastMarker()
        insertionMode = .InTable
        return true
    }

    @discardableResult
    private func processTrEndTagForInRow() -> Bool {
        if !tree.openElements.inTableScope(.HTML_tr) {
            if !isParsingFragmentOrTemplateContents {
                resetInsertionModeAppropriately()
            }
            // FIXME: parse error
            return false
        }
        tree.openElements.popUntilTableRowScopeMarker()
        tree.openElements.pop()
        insertionMode = .InTableBody
        return true
    }

    @discardableResult
    private func processTableEndTagForInTable() -> Bool {
        if !tree.openElements.inTableScope(.HTML_table) {
            if !isParsingFragmentOrTemplateContents {
                resetInsertionModeAppropriately()
            }
            // FIXME: parse error.
            return false
        }
        tree.openElements.popUntilPopped(.HTML_table)
        resetInsertionModeAppropriately()
        return true
    }

    private func processEndTagForInTable(_ token: inout AtomHTMLToken) {
        switch token.tagName {
        case .table:
            processTableEndTagForInTable()
            return
        case .body, .caption, .col, .colgroup, .html, .tbody, .tfoot, .thead, .th, .td, .tr:
            parseError()
            return
        default:
            break
        }
        parseError()
        // Is this redirection necessary here?
        tree.withRedirectToFosterParent {
            processEndTagForInBody(&token)
        }
    }

    // MARK: Other tokens

    private func processProcessingInstruction(_ token: inout AtomHTMLToken) {
        if insertionMode == .Initial || insertionMode == .BeforeHTML || insertionMode == .AfterAfterBody
            || insertionMode == .AfterAfterFrameset
        {
            tree.insertProcessingInstructionOnDocument(&token)
            return
        }
        if insertionMode == .AfterBody {
            tree.insertProcessingInstructionOnHTMLHtmlElement(&token)
            return
        }
        if insertionMode == .InTableText {
            defaultForInTableText()
            processProcessingInstruction(&token)
            return
        }
        tree.insertProcessingInstruction(&token)
    }

    private func processComment(_ token: inout AtomHTMLToken) {
        if insertionMode == .Initial || insertionMode == .BeforeHTML || insertionMode == .AfterAfterBody
            || insertionMode == .AfterAfterFrameset
        {
            tree.insertCommentOnDocument(&token)
            return
        }
        if insertionMode == .AfterBody {
            tree.insertCommentOnHTMLHtmlElement(&token)
            return
        }
        if insertionMode == .InTableText {
            defaultForInTableText()
            processComment(&token)
            return
        }
        tree.insertComment(&token)
    }

    private func processCharacter(_ token: inout AtomHTMLToken) {
        if token.isReplacedNullCharacter {
            return
        }
        var characters = WTF.String()
        swap(&characters, &token.data)
        var buffer = ExternalCharacterTokenBuffer(characters)
        processCharacterBuffer(&buffer)
    }

    private func consumeAndInsertWhitespace(_ buffer: inout ExternalCharacterTokenBuffer) -> Bool {
        let leadingWhitespace = buffer.takeLeadingWhitespace()
        if !leadingWhitespace.isEmpty() {
            tree.insertTextNode(leadingWhitespace)
        }
        if buffer.isEmpty {
            return true
        }
        return false
    }

    private func processCharacterBuffer(_ buffer: inout ExternalCharacterTokenBuffer) {
        // Each pass of the loop processes the buffer in the insertion mode; a mode that changes it continues.
        while true {
            // https://html.spec.whatwg.org/multipage/parsing.html#parsing-main-inbody
            // Note that this logic is different than the generic \r\n collapsing handled in the input stream
            // preprocessor. This logic is here as an "authoring convenience" so folks can write:
            //
            // <pre>
            // lorem ipsum
            // lorem ipsum
            // </pre>
            //
            // without getting an extra newline at the start of their <pre> element.
            if shouldSkipLeadingNewline {
                shouldSkipLeadingNewline = false
                buffer.skipAtMostOneLeadingNewline()
                if buffer.isEmpty {
                    return
                }
            }

            switch insertionMode {
            case .Initial:
                buffer.skipLeadingWhitespace()
                if buffer.isEmpty {
                    return
                }
                defaultForInitial()
                fallthrough
            case .BeforeHTML:
                buffer.skipLeadingWhitespace()
                if buffer.isEmpty {
                    return
                }
                defaultForBeforeHTML()
                fallthrough
            case .BeforeHead:
                buffer.skipLeadingWhitespace()
                if buffer.isEmpty {
                    return
                }
                defaultForBeforeHead()
                fallthrough
            case .InHead:
                if consumeAndInsertWhitespace(&buffer) {
                    return
                }
                defaultForInHead()
                fallthrough
            case .AfterHead:
                if consumeAndInsertWhitespace(&buffer) {
                    return
                }
                defaultForAfterHead()
                fallthrough
            case .InBody, .InCaption, .InCell, .TemplateContents:
                processCharacterBufferForInBody(&buffer)
                return
            case .InTable, .InTableBody, .InRow:
                let currentElementName = tree.currentElementName
                if currentElementName == .HTML_table || currentElementName == .HTML_tbody
                    || currentElementName == .HTML_tfoot || currentElementName == .HTML_thead
                    || currentElementName == .HTML_tr
                {
                    originalInsertionMode = insertionMode
                    insertionMode = .InTableText
                    // As the in table text insertion mode below.
                    appendPendingTableCharacters(buffer.takeRemaining())
                    return
                }
                tree.withRedirectToFosterParent {
                    processCharacterBufferForInBody(&buffer)
                }
                return
            case .InTableText:
                appendPendingTableCharacters(buffer.takeRemaining())
                return
            case .InColumnGroup:
                if consumeAndInsertWhitespace(&buffer) {
                    return
                }
                if !processColgroupEndTagForInColumnGroup() {
                    // The spec tells us to drop these characters on the floor.
                    buffer.skipLeadingNonWhitespace()
                    if buffer.isEmpty {
                        return
                    }
                }
                continue
            case .AfterBody, .AfterAfterBody:
                if consumeAndInsertWhitespace(&buffer) {
                    return
                }
                // FIXME: parse error
                insertionMode = .InBody
                continue
            case .Text:
                tree.insertTextNode(buffer.takeRemaining())
                return
            case .InHeadNoscript:
                if consumeAndInsertWhitespace(&buffer) {
                    return
                }
                defaultForInHeadNoscript()
                continue
            case .InFrameset, .AfterFrameset:
                let leadingWhitespace = buffer.takeRemainingWhitespace()
                if !leadingWhitespace.isEmpty() {
                    tree.insertTextNode(leadingWhitespace)
                }
                // FIXME: We should generate a parse error if we skipped over any non-whitespace characters.
                return
            case .AfterAfterFrameset:
                let leadingWhitespace = buffer.takeRemainingWhitespace()
                if !leadingWhitespace.isEmpty() {
                    tree.reconstructTheActiveFormattingElements()
                    tree.insertTextNode(leadingWhitespace)
                }
                // FIXME: We should generate a parse error if we skipped over any non-whitespace characters.
                return
            }
        }
    }

    private func processCharacterBufferForInBody(_ buffer: inout ExternalCharacterTokenBuffer) {
        tree.reconstructTheActiveFormattingElements()
        let characters = buffer.takeRemaining()
        tree.insertTextNode(characters)
        if framesetOk && !containsOnlyASCIIWhitespace(characters) {
            framesetOk = false
        }
    }

    private func processEndOfFile(_ token: inout AtomHTMLToken) {
        switch insertionMode {
        case .Initial:
            defaultForInitial()
            fallthrough
        case .BeforeHTML:
            defaultForBeforeHTML()
            fallthrough
        case .BeforeHead:
            defaultForBeforeHead()
            fallthrough
        case .InHead:
            defaultForInHead()
            fallthrough
        case .AfterHead:
            defaultForAfterHead()
            fallthrough
        case .InBody, .InCell, .InCaption, .InRow:
            // Emit parse error based on what elements are still open.
            if !templateInsertionModes.isEmpty {
                if processEndOfFileForInTemplateContents(&token) {
                    return
                }
            }
        case .AfterBody, .AfterAfterBody:
            break
        case .InHeadNoscript:
            defaultForInHeadNoscript()
            processEndOfFile(&token)
            return
        case .AfterFrameset, .AfterAfterFrameset:
            break
        case .InColumnGroup:
            if tree.currentIsRootNode {
                return  // FIXME: Should we break here instead of returning?
            }
            processColgroupEndTagForInColumnGroup()
            fallthrough
        case .InFrameset, .InTable, .InTableBody:
            if !tree.currentNode.isSameNode(tree.openElements.rootNode) {
                parseError()
            }
            if !templateInsertionModes.isEmpty {
                if processEndOfFileForInTemplateContents(&token) {
                    return
                }
            }
        case .InTableText:
            defaultForInTableText()
            processEndOfFile(&token)
            return
        case .Text:
            parseError()
            if tree.currentElementName == .HTML_script {
                // Mark the script element as "already started".
            }
            tree.openElements.pop()
            insertionMode = originalInsertionMode
            processEndOfFile(&token)
            return
        case .TemplateContents:
            if processEndOfFileForInTemplateContents(&token) {
                return
            }
        }
        tree.openElements.popAll()
    }

    // MARK: Anything else

    private func defaultForInitial() {
        tree.setDefaultCompatibilityMode()
        // FIXME: parse error
        insertionMode = .BeforeHTML
    }

    private func defaultForBeforeHTML() {
        var startHTML = AtomHTMLToken(.StartTag, .html)
        tree.insertHTMLHtmlStartTagBeforeHTML(&startHTML)
        insertionMode = .BeforeHead
    }

    private func defaultForBeforeHead() {
        var startHead = AtomHTMLToken(.StartTag, .head)
        processStartTag(&startHead)
    }

    private func defaultForInHead() {
        var endHead = AtomHTMLToken(.EndTag, .head)
        processEndTag(&endHead)
    }

    private func defaultForInHeadNoscript() {
        var endNoscript = AtomHTMLToken(.EndTag, .noscript)
        processEndTag(&endNoscript)
    }

    private func defaultForAfterHead() {
        var startBody = AtomHTMLToken(.StartTag, .body)
        processStartTag(&startBody)
        framesetOk = true
    }

    private func defaultForInTableText() {
        var pending = PendingTableCharacters()
        swap(&pending, &pendingTableCharacters)
        let characters = pending.take()
        if !containsOnlyASCIIWhitespace(characters) {
            // FIXME: parse error
            tree.withRedirectToFosterParent {
                tree.reconstructTheActiveFormattingElements()
                tree.insertTextNode(characters)
            }
            framesetOk = false
            insertionMode = originalInsertionMode
            return
        }
        tree.insertTextNode(characters)
        insertionMode = originalInsertionMode
    }

    // MARK: Foreign content

    /// The namespace URI of the adjusted current node
    /// (https://html.spec.whatwg.org/multipage/parsing.html#adjusted-current-node).
    private var adjustedCurrentNodeNamespaceURI: WTF.AtomString {
        if isParsingFragment && tree.openElements.hasOnlyOneElement {
            return contextElementItem!.namespaceURI
        }
        return tree.openElements.topNamespaceURI
    }

    /// Whether the adjusted current node, an annotation-xml element, is an HTML integration point.
    private var adjustedCurrentAnnotationXMLIsHTMLIntegrationPoint: Bool {
        if isParsingFragment && tree.openElements.hasOnlyOneElement {
            return contextElementItem!.isHTMLIntegrationPoint(encodingName: foreignContentNames.encoding)
        }
        return annotationXMLIsHTMLIntegrationPoint(tree.currentElement, foreignContentNames.encoding)
    }

    /// The adjusted current node's stack word. The stack must not be empty.
    private var adjustedCurrentNodeWord: UInt32 {
        if let contextElementWord, tree.openElements.hasOnlyOneElement {
            return contextElementWord
        }
        return tree.openElements.topWord
    }

    /// https://html.spec.whatwg.org/multipage/parsing.html#html-integration-point, for the adjusted current node
    /// whose stack word is `word`.
    private func adjustedCurrentNodeIsHTMLIntegrationPoint(_ word: UInt32) -> Bool {
        if HTMLElementStack.isSVGHTMLIntegrationPoint(word) {
            return true
        }
        return HTMLElementStack.isMathMLAnnotationXML(word) && adjustedCurrentAnnotationXMLIsHTMLIntegrationPoint
    }

    /// https://html.spec.whatwg.org/multipage/parsing.html#tree-construction
    private func shouldProcessTokenInForeignContent(_ token: borrowing AtomHTMLToken) -> Bool {
        if tree.isEmpty {
            return false
        }
        let word = adjustedCurrentNodeWord
        if HTMLElementStack.isInHTMLNamespace(word) {
            return false
        }
        if HTMLElementStack.isMathMLTextIntegrationPoint(word) {
            if token.type == .StartTag && token.tagName != .mglyph && token.tagName != .malignmark {
                return false
            }
            if token.type == .Character {
                return false
            }
        }
        if HTMLElementStack.isMathMLAnnotationXML(word) && token.type == .StartTag && token.tagName == .svg {
            return false
        }
        if adjustedCurrentNodeIsHTMLIntegrationPoint(word) {
            if token.type == .StartTag {
                return false
            }
            if token.type == .Character {
                return false
            }
        }
        if token.type == .EndOfFile {
            return false
        }
        return true
    }

    private func processTokenInForeignContent(_ token: inout AtomHTMLToken) {
        switch token.type {
        case .DOCTYPE:
            parseError()
        case .StartTag:
            switch token.tagName {
            case .font:
                let fontNames: FontAttributeNames
                if let madeNames = fontAttributeNames {
                    fontNames = madeNames
                } else {
                    fontNames = FontAttributeNames()
                    fontAttributeNames = fontNames
                }
                if !(findAttributeValue(token, fontNames.color) != nil
                    || findAttributeValue(token, fontNames.face) != nil
                    || findAttributeValue(token, fontNames.size) != nil)
                {
                    break
                }
                fallthrough
            case .b, .big, .blockquote, .body, .br, .center, .code, .dd, .div, .dl, .dt, .em, .embed, .h1, .h2, .h3,
                .h4, .h5, .h6, .head, .hr, .i, .img, .li, .listing, .menu, .meta, .nobr, .ol, .p, .pre, .ruby, .s,
                .small_, .span, .strong, .strike, .sub, .sup, .table, .tt, .u, .ul, .var:
                parseError()
                tree.openElements.popUntilForeignContentScopeMarker(encodingName: foreignContentNames.encoding)
                processStartTag(&token)
                return
            default:
                break
            }
            let currentNamespace = adjustedCurrentNodeNamespaceURI
            let names = foreignContentNames
            if currentNamespace == names.mathMLNamespace {
                adjustMathMLAttributes(&token)
            }
            let currentNamespaceIsSVG = currentNamespace == names.svgNamespace
            if currentNamespaceIsSVG {
                adjustSVGTagNameCase(&token)
                adjustSVGAttributes(&token)
            }
            adjustForeignAttributes(&token)

            if token.tagName == .script && token.selfClosing && currentNamespaceIsSVG {
                token.selfClosing = false
                tree.insertForeignElement(&token, currentNamespace)
                var fakeToken = AtomHTMLToken(.EndTag, .script)
                processTokenInForeignContent(&fakeToken)
                return
            }

            tree.insertForeignElement(&token, currentNamespace)
        case .EndTag:
            if adjustedCurrentNodeNamespaceURI == foreignContentNames.svgNamespace {
                adjustSVGTagNameCase(&token)
            }

            if token.tagName == .script && tree.currentElementName == .SVG_script {
                if scriptingContentIsAllowed {
                    setScriptToProcess(tree.currentElement)
                }
                tree.openElements.pop()
                return
            }
            if token.tagName == .br || token.tagName == .p {
                parseError()
                tree.openElements.popUntilForeignContentScopeMarker(encodingName: foreignContentNames.encoding)
                processEndTag(&token)
                return
            }
            if !HTMLElementStack.isInHTMLNamespace(tree.openElements.topWord) {
                let name = token.name
                let openElements = tree.openElements
                var index = openElements.itemCount - 1
                if !(openElements.localName(at: index) == name) {
                    parseError()
                }
                while true {
                    if openElements.localName(at: index) == name {
                        openElements.popUntilPopped(openElements.element(at: index)!)
                        return
                    }
                    index -= 1

                    if HTMLElementStack.isInHTMLNamespace(openElements.word(at: index)) {
                        break
                    }
                }
            }
            // Otherwise, process the token according to the rules given in the section corresponding to the current
            // insertion mode in HTML content.
            processEndTag(&token)
        case .Comment:
            tree.insertComment(&token)
        case .ProcessingInstruction:
            tree.insertProcessingInstruction(&token)
        case .Character:
            // A 16-bit string, as WTF::String makes from the token's UChar characters.
            let characters = makeString16(token.data)
            tree.insertTextNode(characters)
            if framesetOk && !token.isReplacedNullCharacter && !containsOnlyASCIIWhitespace(characters) {
                framesetOk = false
            }
        default:
            // Uninitialized; end of file is never processed in foreign content.
            break
        }
    }

    private func adjustSVGTagNameCase(_ token: inout AtomHTMLToken) {
        if token.tagName != .Unknown {
            token.tagName = WebCore.adjustSVGTagName(token.tagName)
        }
    }

    /// https://html.spec.whatwg.org/multipage/parsing.html#adjust-mathml-attributes
    private func adjustMathMLAttributes(_ token: inout AtomHTMLToken) {
        if token.attributes.size() == 0 {
            return
        }
        if mathMLAttributeNames == nil {
            mathMLAttributeNames = AdjustedAttributeNames(mathMLAttributeNameTable)
        }
        mathMLAttributeNames?.adjust(&token.attributes)
    }

    /// https://html.spec.whatwg.org/multipage/parsing.html#adjust-svg-attributes
    private func adjustSVGAttributes(_ token: inout AtomHTMLToken) {
        if token.attributes.size() == 0 {
            return
        }
        if svgAttributeNames == nil {
            svgAttributeNames = AdjustedAttributeNames(svgAttributeNameTable)
        }
        svgAttributeNames?.adjust(&token.attributes)
    }

    /// https://html.spec.whatwg.org/multipage/parsing.html#adjust-foreign-attributes
    private func adjustForeignAttributes(_ token: inout AtomHTMLToken) {
        if token.attributes.size() == 0 {
            return
        }
        if foreignAttributeNames == nil {
            foreignAttributeNames = AdjustedAttributeNames(foreignAttributeNameTable)
        }
        foreignAttributeNames?.adjust(&token.attributes)
    }
}

func makeAtomString(_ literal: Swift.String) -> WTF.AtomString {
    let characters = Array(literal.utf8)
    return WTF.AtomString(WTF.String(WTF.latin1CharactersOfBytes(characters.span)))
}

/// An attribute name in no namespace: for a name SVGNames or MathMLNames has, the same QualifiedName.
func makeAttributeName(_ localName: Swift.String) -> WebCore.QualifiedName {
    WebCore.QualifiedName(WTF.AtomString(), makeAtomString(localName), WTF.AtomString())
}

/// HTMLNames' colorAttr, faceAttr and sizeAttr.
private final class FontAttributeNames {
    let color = makeAttributeName("color")
    let face = makeAttributeName("face")
    let size = makeAttributeName("size")
}

/// MathMLNames' and SVGNames' namespace URIs, and MathMLNames' encodingAttr.
private final class ForeignContentNames {
    let mathMLNamespace = makeAtomString("http://www.w3.org/1998/Math/MathML")
    let svgNamespace = makeAtomString("http://www.w3.org/2000/svg")
    let encoding = makeAttributeName("encoding")
}

/// The namespace of an adjusted attribute name.
private enum AdjustedAttributeNamespace {
    case none
    case xlink
    case xml
    case xmlns
}

/// An attribute name the specification adjusts: the local name the tokenizer gives the attribute, and the
/// QualifiedName's parts.
private struct AdjustedAttributeName {
    let key: Swift.String
    let prefix: Swift.String
    let localName: Swift.String
    let namespace: AdjustedAttributeNamespace
}

/// A table of adjusted attribute names, ordered by the length of their keys.
private struct AdjustedAttributeNameTable {
    let names: [AdjustedAttributeName]
    /// The names whose key has length n are at firstIndexForLength[n] ..< firstIndexForLength[n + 1].
    let firstIndexForLength: [Int]

    init(_ names: [AdjustedAttributeName]) {
        self.names = names.sorted { $0.key.utf8.count < $1.key.utf8.count }
        var firstIndexForLength = [Int](repeating: self.names.count, count: (self.names.last?.key.utf8.count ?? 0) + 2)
        for (index, name) in self.names.enumerated().reversed() {
            for length in 0...name.key.utf8.count {
                firstIndexForLength[length] = index
            }
        }
        self.firstIndexForLength = firstIndexForLength
    }
}

/// The SVG attributes (SVGNames) the specification adjusts, keyed by their local names in ASCII lowercase.
private let svgAttributeNameTable = AdjustedAttributeNameTable(
    [
        "attributeName", "attributeType", "baseFrequency", "baseProfile", "calcMode", "clipPathUnits",
        "diffuseConstant", "edgeMode", "filterUnits", "glyphRef", "gradientTransform", "gradientUnits",
        "kernelMatrix", "kernelUnitLength", "keyPoints", "keySplines", "keyTimes", "lengthAdjust",
        "limitingConeAngle", "markerHeight", "markerUnits", "markerWidth", "maskContentUnits", "maskUnits",
        "numOctaves", "pathLength", "patternContentUnits", "patternTransform", "patternUnits", "pointsAtX",
        "pointsAtY", "pointsAtZ", "preserveAlpha", "preserveAspectRatio", "primitiveUnits", "refX", "refY",
        "repeatCount", "repeatDur", "requiredExtensions", "requiredFeatures", "specularConstant", "specularExponent",
        "spreadMethod", "startOffset", "stdDeviation", "stitchTiles", "surfaceScale", "systemLanguage", "tableValues",
        "targetX", "targetY", "textLength", "viewBox", "viewTarget", "xChannelSelector", "yChannelSelector",
        "zoomAndPan"

    ].map { AdjustedAttributeName(key: $0.lowercased(), prefix: "", localName: $0, namespace: .none) }
)

/// MathMLNames::definitionURLAttr, keyed by its local name in ASCII lowercase.
private let mathMLAttributeNameTable = AdjustedAttributeNameTable([
    AdjustedAttributeName(key: "definitionurl", prefix: "", localName: "definitionURL", namespace: .none)
])

/// The XLink, XML and XMLNS attributes (XLinkNames, XMLNames, XMLNSNames) the specification adjusts, keyed by the
/// name as written, with its prefix.
private let foreignAttributeNameTable = AdjustedAttributeNameTable(
    ["actuate", "arcrole", "href", "role", "show", "title", "type"].map {
        AdjustedAttributeName(key: "xlink:" + $0, prefix: "xlink", localName: $0, namespace: .xlink)
    } + ["lang", "space"].map {
        AdjustedAttributeName(key: "xml:" + $0, prefix: "xml", localName: $0, namespace: .xml)
    } + [
        AdjustedAttributeName(key: "xmlns", prefix: "", localName: "xmlns", namespace: .xmlns),
        AdjustedAttributeName(key: "xmlns:xlink", prefix: "xmlns", localName: "xlink", namespace: .xmlns),
    ]
)

/// One parser's atoms and QualifiedNames for a table of adjusted attribute names. The names of one key length are
/// made the first time an attribute of that length is looked up.
private final class AdjustedAttributeNames {
    private let table: AdjustedAttributeNameTable
    private var keys: [WTF.AtomString] = []
    private var names: [WebCore.QualifiedName?] = []
    /// Bit n is set once the names whose key has length n are made.
    private var madeLengths: UInt32 = 0

    init(_ table: AdjustedAttributeNameTable) {
        self.table = table
    }

    /// Renames each attribute whose local name is a key.
    func adjust(_ attributes: inout WebCore.AttributeVector) {
        var index = 0
        while index < attributes.size() {
            let localName = attributeLocalName(attributes, index)
            let length = Int(localName.length())
            if length + 1 < table.firstIndexForLength.count {
                let entries = table.firstIndexForLength[length]..<table.firstIndexForLength[length + 1]
                if !entries.isEmpty {
                    if madeLengths & (1 << length) == 0 {
                        makeNames(entries)
                        madeLengths |= 1 << length
                    }
                    for entry in entries where keys[entry] == localName {
                        if let name = names[entry] {
                            WebCore.parserSetAttributeName(&attributes, index, name)
                        }
                        break
                    }
                }
            }
            index += 1
        }
    }

    private func attributeLocalName(_ attributes: borrowing WebCore.AttributeVector, _ index: Int) -> WTF.AtomString {
        let span: Span<WebCore.Attribute> = attributes.span()
        return WebCore.attributeLocalName(span[index])
    }

    @inline(never)
    private func makeNames(_ entries: Range<Int>) {
        // Moved out and back so that no access to the stored arrays is open while the names are made.
        var keys = self.keys
        var names = self.names
        self.keys = []
        self.names = []
        if keys.isEmpty {
            keys = [WTF.AtomString](repeating: WTF.AtomString(), count: table.names.count)
            names = [WebCore.QualifiedName?](repeating: nil, count: table.names.count)
        }
        for entry in entries {
            let name = table.names[entry]
            let namespaceURI =
                switch name.namespace {
                case .none: WTF.AtomString()
                case .xlink: makeAtomString("http://www.w3.org/1999/xlink")
                case .xml: makeAtomString("http://www.w3.org/XML/1998/namespace")
                case .xmlns: makeAtomString("http://www.w3.org/2000/xmlns/")
                }
            let prefix = name.prefix.isEmpty ? WTF.AtomString() : makeAtomString(name.prefix)
            keys[entry] = makeAtomString(name.key)
            names[entry] = WebCore.QualifiedName(prefix, makeAtomString(name.localName), namespaceURI)
        }
        self.keys = keys
        self.names = names
    }
}

/// The value of the token's attribute with the name, as WebCore's findAttribute finds it.
private func findAttributeValue(_ token: borrowing AtomHTMLToken, _ name: WebCore.QualifiedName) -> WTF.AtomString? {
    let attributes: Span<WebCore.Attribute> = token.attributes.span()
    for index in attributes.indices where WebCore.attributeName(attributes[index]).matches(name) {
        return WebCore.attributeValue(attributes[index])
    }
    return nil
}

/// Node::remove, whose exception is ignored.
private func removeFromParent(_ element: WebCore.Element) {
    _ = element.remove()
}

#endif
