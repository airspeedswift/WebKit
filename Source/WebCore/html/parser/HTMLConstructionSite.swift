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
internal import WebCore_Private.Core.Comment
internal import WebCore_Private.Core.ContainerNode
internal import WebCore_Private.Core.CustomElementRegistry
internal import WebCore_Private.Core.Document
internal import WebCore_Private.Core.DocumentFragment
internal import WebCore_Private.Core.DocumentType
internal import WebCore_Private.Core.Element
internal import WebCore_Private.Core.ElementInlines
internal import WebCore_Private.Core.ExceptionOr
internal import WebCore_Private.Core.HTMLDocumentParser
internal import WebCore_Private.Core.HTMLElement
internal import WebCore_Private.Core.HTMLElementFactory
internal import WebCore_Private.Core.HTMLFormElement
internal import WebCore_Private.Core.HTMLHtmlElement
internal import WebCore_Private.Core.HTMLImageElement
internal import WebCore_Private.Core.HTMLMaybeFormAssociatedCustomElement
internal import WebCore_Private.Core.HTMLScriptElement
internal import WebCore_Private.Core.HTMLTemplateElement
internal import WebCore_Private.Core.HTMLTokenizer
internal import WebCore_Private.Core.HTMLTreeBuilderSwiftSupport
internal import WebCore_Private.Core.HTMLUnknownElement
internal import WebCore_Private.Core.JSCustomElementInterface
internal import WebCore_Private.Core.Node
internal import WebCore_Private.Core.NodeName
internal import WebCore_Private.Core.ProcessingInstruction
internal import WebCore_Private.Core.QualifiedName
internal import WebCore_Private.Core.Settings
internal import WebCore_Private.Core.ShadowRoot
internal import WebCore_Private.Core.Text
internal import JavaScriptCore_Private.Cxx.Snippet
internal import JavaScriptCore_Private.Cxx.DOMJITCallDOMGetterSnippet
internal import JavaScriptCore_Private.Cxx.WasmInstanceAnchor
internal import JavaScriptCore_Private.Cxx.WasmCalleeGroup
internal import JavaScriptCore_Private.Cxx.WasmModule
internal import JavaScriptCore_Private.Cxx.WasmModuleDebugInfo
internal import wtf.Core.Stopwatch

/// A token for tree construction, made from what HTMLDocumentParser::nextTokenForTreeBuilder fills in, or by the
/// tree builder itself (a start tag to reconstruct an element, the fake tags it inserts). The attributes move out
/// of it into the stack item of the element made for it.
struct AtomHTMLToken: ~Copyable {
    var type: WebCore.HTMLToken.`Type`
    var tagName: WebCore.TagName = .Unknown
    /// For a tag, null unless tagName is unknown or the token was made with a name; for a DOCTYPE, its name; for a
    /// processing instruction, its target.
    var storedName = WTF.AtomString()
    var attributes = WebCore.AttributeVector()
    var hasDuplicateAttribute = false
    var selfClosing = false
    var isReplacedNullCharacter = false
    var forceQuirks = false
    /// The characters, the comment, or the processing instruction's data.
    var data = WTF.String()
    var publicIdentifier = WTF.String()
    var systemIdentifier = WTF.String()

    /// Moves the token out of `parts`, which is left ready for the next token.
    init(_ parts: inout WebCore.HTMLTokenAttributes) {
        type = parts.type
        tagName = parts.tagName
        swap(&storedName, &parts.name)
        attributes.swap(&parts.attributes)
        hasDuplicateAttribute = parts.hasDuplicateAttribute
        selfClosing = parts.selfClosing
        isReplacedNullCharacter = parts.isReplacedNullCharacter
        forceQuirks = parts.forceQuirks
        swap(&data, &parts.data)
        swap(&publicIdentifier, &parts.publicIdentifier)
        swap(&systemIdentifier, &parts.systemIdentifier)
        parts.tagName = .Unknown
        parts.hasDuplicateAttribute = false
    }

    /// A start or end tag.
    init(
        _ type: WebCore.HTMLToken.`Type`,
        _ tagName: WebCore.TagName,
        name: WTF.AtomString = WTF.AtomString(),
        attributes: consuming WebCore.AttributeVector = WebCore.AttributeVector()
    ) {
        self.type = type
        self.tagName = tagName
        self.storedName = name
        self.attributes = attributes
    }

    /// The tag's name, or the DOCTYPE's.
    var name: WTF.AtomString {
        if !storedName.isNull() {
            return storedName
        }
        return WebCore.tagNameString(tagName)
    }

    /// Moves the attributes out.
    mutating func takeAttributes() -> WebCore.AttributeVector {
        var taken = WebCore.AttributeVector()
        taken.swap(&attributes)
        return taken
    }
}

/// A DOM change the construction site makes after the token's own changes to its state, in
/// HTMLConstructionSite.executeQueuedTasks.
struct HTMLConstructionSiteTask {
    enum Operation {
        case insert
        case insertAlreadyParsedChild
        case reparent
        case takeAllChildrenAndReparent
    }

    var operation: Operation
    var parent: WebCore.ContainerNode?
    var nextChild: WebCore.Node?
    var child: WebCore.Node?
    /// takeAllChildrenAndReparent's old parent, whose children move to parent.
    var oldParent: WebCore.ContainerNode?
    var selfClosing = false

    init(_ operation: Operation) {
        self.operation = operation
    }
}

private func hasImpliedEndTag(_ elementName: WebCore.ElementName) -> Bool {
    switch elementName {
    case .HTML_dd, .HTML_dt, .HTML_li, .HTML_option, .HTML_optgroup, .HTML_p, .HTML_rb, .HTML_rp, .HTML_rt,
        .HTML_rtc:
        return true
    default:
        return false
    }
}

private func shouldUseLengthLimit(_ node: WebCore.ContainerNode) -> Bool {
    guard let element = WebCore.dynamicDowncastElement(node) else {
        return true
    }
    switch element.elementName() {
    case .HTML_script, .HTML_style, .SVG_script:
        return false
    default:
        return true
    }
}

private func causesFosterParenting(_ elementName: WebCore.ElementName) -> Bool {
    switch elementName {
    case .HTML_table, .HTML_tbody, .HTML_tfoot, .HTML_thead, .HTML_tr:
        return true
    default:
        return false
    }
}

/// Resolves the DOM-derived part of the foster site recorded by recordFosterSite: script can move or remove the
/// table before the task runs.
private func resolveFosterSite(_ task: inout HTMLConstructionSiteTask) {
    guard let nextChild = task.nextChild else {
        return
    }
    if let referenceParent = nextChild.parentNode() {
        task.parent = referenceParent
    } else {
        task.nextChild = nil
    }
}

private func insert(_ task: inout HTMLConstructionSiteTask) {
    resolveFosterSite(&task)

    if let templateElement = WebCore.dynamicDowncastHTMLTemplateElement(task.parent) {
        task.parent = templateElement.fragmentForInsertion()
        task.nextChild = nil
    } else if let document = WebCore.dynamicDowncastDocument(task.parent) {
        if !document.canAcceptChild(task.child!, task.nextChild, .InsertOrAdd) {
            return
        }
    }

    let child = task.child!
    let parent = task.parent!

    if WebCore.containsIncludingHostElements(child, parent) {
        return
    }

    if let nextChild = task.nextChild {
        parent.parserInsertBefore(child, nextChild)
    } else {
        parent.parserAppendChild(child)
    }
}

private func executeInsertTask(_ task: inout HTMLConstructionSiteTask) {
    insert(&task)

    guard let element = WebCore.dynamicDowncastElement(task.child) else {
        return
    }
    element.beginParsingChildren()
    if task.selfClosing {
        element.finishParsingChildren()
    }
}

private func executeReparentTask(_ task: inout HTMLConstructionSiteTask) {
    let child = task.child!
    if let parent = child.parentNode() {
        parent.parserRemoveChild(child)
    }
    if child.parentNode() != nil || child.contains(task.parent) {
        return
    }
    task.parent!.parserAppendChild(child)
}

private func executeInsertAlreadyParsedChildTask(_ task: inout HTMLConstructionSiteTask) {
    let child = task.child!
    if let parent = child.parentNode() {
        parent.parserRemoveChild(child)
    }
    if child.parentNode() != nil {
        return
    }
    insert(&task)
}

private func executeTakeAllChildrenAndReparentTask(_ task: inout HTMLConstructionSiteTask) {
    let furthestBlock = task.oldParent!
    let parent = task.parent!
    parent.takeAllChildrenFrom(furthestBlock)
    precondition(parent.parentNode() == nil)
    furthestBlock.parserAppendChild(parent)
}

private func executeTask(_ task: inout HTMLConstructionSiteTask) {
    switch task.operation {
    case .insert:
        executeInsertTask(&task)
    // All the cases below are only used by the adoption agency.
    case .insertAlreadyParsedChild:
        executeInsertAlreadyParsedChildTask(&task)
    case .reparent:
        executeReparentTask(&task)
    case .takeAllChildrenAndReparent:
        executeTakeAllChildrenAndReparentTask(&task)
    }
}

/// Makes the nodes for the tree builder's tokens and puts them in the tree
/// (https://html.spec.whatwg.org/multipage/parsing.html#creating-and-inserting-nodes), and holds the stack of open
/// elements and the list of active formatting elements.
///
/// Insertions other than text are queued, and run by executeQueuedTasks once the token's changes to the stacks are
/// made. A queued insertion can run script, which can parse more of the document (document.write): the queue is
/// moved out before it runs, so the nested parse queues its own insertions.
final class HTMLConstructionSite {
    let openElements = HTMLElementStack()
    let activeFormattingElements = HTMLFormattingElementList()
    private(set) var head: HTMLStackItem?

    /// A fragment parse's fragment, the root it attaches nodes to, and the fragment's document. Null for a document.
    private let fragment: WebCore.DocumentFragment?
    private let fragmentDocument: WebCore.Document?

    /// The parser and its document for the call from the parser in progress, which the tree builder sets with
    /// enter and leave. The tree builder does not keep them between calls: the document holds the parser.
    private var parserForCall: WebCore.HTMLDocumentParser?
    private var documentForCall: WebCore.Document?

    private(set) var form: WebCore.HTMLFormElement?

    /// Only `queueTask` and `executeQueuedTasks` change `firstTask`, `taskQueue` and `spareTaskQueue`. The oldest
    /// queued task is in `firstTask`, and the rest in `taskQueue`, which is empty when `firstTask` is null.
    private var firstTask: HTMLConstructionSiteTask?
    private var taskQueue = UniqueArray<HTMLConstructionSiteTask>()
    /// An empty queue whose storage the next executeQueuedTasks reuses.
    private var spareTaskQueue = UniqueArray<HTMLConstructionSiteTask>()

    let parserContentPolicy: UInt8
    private let registry: WebCore.CustomElementRegistry?
    /// The attributes of the start tag whose custom element the parser is constructing.
    private var customElementAttributes = WebCore.AttributeVector()
    let isParsingFragment: Bool

    /// https://html.spec.whatwg.org/multipage/parsing.html#parsing-main-intable
    /// In the "in table" insertion mode, a node that would be inserted into the current node is sometimes foster
    /// parented instead. This tracks whether that is the case.
    private(set) var redirectAttachToFosterParent = false

    private let maximumDOMTreeDepth: UInt32
    private(set) var inQuirksMode: Bool
    private(set) var hasReachedMaxDOMTreeDepth = false

    /// The last text node the parser appended to, whose characters the parser's text buffer holds.
    private var currentTextNode: WebCore.Text?
    /// The declarative shadow root attributes' names, made for the first template element.
    private var shadowRootAttributeNames: ShadowRootAttributeNames?
    /// HTMLNames' xhtmlNamespaceURI, made for the first element with a tag name HTMLNames does not have.
    private var xhtmlNamespaceURI: WTF.AtomString?

    init(document: WebCore.Document, parserContentPolicy: UInt8, maximumDOMTreeDepth: UInt32) {
        fragment = nil
        fragmentDocument = nil
        self.parserContentPolicy = parserContentPolicy
        registry = nil
        isParsingFragment = false
        self.maximumDOMTreeDepth = maximumDOMTreeDepth
        inQuirksMode = document.inQuirksMode()
    }

    init(
        fragment: WebCore.DocumentFragment,
        parserContentPolicy: UInt8,
        maximumDOMTreeDepth: UInt32,
        registry: WebCore.CustomElementRegistry?
    ) {
        self.fragment = fragment
        let document = fragment.document()
        fragmentDocument = document
        self.parserContentPolicy = parserContentPolicy
        self.registry = registry
        isParsingFragment = true
        self.maximumDOMTreeDepth = maximumDOMTreeDepth
        inQuirksMode = document.inQuirksMode()
    }

    // MARK: Calls from the parser

    struct SavedCall {
        fileprivate let parser: WebCore.HTMLDocumentParser?
        fileprivate let document: WebCore.Document?
    }

    /// Starts a call from `parser`. A nested call (document.write from script the call runs) starts its own.
    func enter(_ parser: WebCore.HTMLDocumentParser) -> SavedCall {
        let saved = SavedCall(parser: parserForCall, document: documentForCall)
        parserForCall = parser
        documentForCall = fragmentDocument ?? parser.document()!
        return saved
    }

    func leave(_ saved: SavedCall) {
        parserForCall = saved.parser
        documentForCall = saved.document
    }

    /// The parser of the call in progress.
    var parser: WebCore.HTMLDocumentParser { parserForCall! }

    private var document: WebCore.Document { fragmentDocument ?? documentForCall! }
    private var attachmentRoot: WebCore.ContainerNode { fragment ?? documentForCall! }

    private var scriptingContentIsAllowed: Bool {
        parserContentPolicy & WebCore.ParserContentPolicy.AllowScriptingContent.rawValue != 0
    }

    // MARK: The current node

    var isEmpty: Bool { openElements.stackDepth == 0 }
    var currentNode: WebCore.ContainerNode { openElements.topNode }
    var currentElement: WebCore.Element { openElements.topElement }
    var currentElementName: WebCore.ElementName { openElements.topElementName }
    var currentIsRootNode: Bool { openElements.rootNode.isSameNode(openElements.topNode) }
    var headElement: WebCore.Element { head!.element! }

    private var containerForCurrentNode: WebCore.ContainerNode {
        let currentNode = self.currentNode
        if let templateElement = WebCore.dynamicDowncastHTMLTemplateElement(currentNode) {
            return templateElement.fragmentForInsertion()
        }
        return currentNode
    }

    private var ownerDocumentForCurrentNode: WebCore.Document {
        let currentNode = self.currentNode
        if let templateElement = WebCore.dynamicDowncastHTMLTemplateElement(currentNode) {
            return templateElement.fragmentForInsertion().document()
        }
        return currentNode.document()
    }

    // MARK: The task queue

    private func attachLater(_ parent: WebCore.ContainerNode, _ child: WebCore.Node, selfClosing: Bool = false) {
        if shouldFosterParent {
            fosterParent(child)
            return
        }

        var task = HTMLConstructionSiteTask(.insert)
        task.parent = parent
        task.child = child
        task.selfClosing = selfClosing

        // Close the last open tag and add as a sibling of the parent if the maximum depth is reached.
        if openElements.stackDepth >= maximumDOMTreeDepth && parent.parentNode() != nil {
            openElements.pop()
            task.parent = parent.parentNode()
            hasReachedMaxDOMTreeDepth = true
        }

        queueTask(task)
    }

    /// Adds `task` to the queue. The queue is moved out while it grows, so that no access to the stored property is
    /// open while the storage allocates or frees memory, and the compiler can check the accesses without run-time
    /// checks.
    private func queueTask(_ task: consuming HTMLConstructionSiteTask) {
        if firstTask == nil {
            firstTask = task
            return
        }
        var queue = UniqueArray<HTMLConstructionSiteTask>()
        swap(&queue, &taskQueue)
        queue.append(task)
        swap(&queue, &taskQueue)
    }

    func executeQueuedTasks() {
        // Move the queue into locals, as a task can re-enter the parser.
        guard var task = firstTask.take() else {
            return
        }
        if taskQueue.isEmpty {
            executeTask(&task)
            return
        }
        var queue = UniqueArray<HTMLConstructionSiteTask>()
        swap(&queue, &spareTaskQueue)
        swap(&queue, &taskQueue)

        executeTask(&task)
        for index in queue.indices {
            executeTask(&queue[index])
        }

        // The parser might be detached now. The tasks are destroyed in queue order.
        _ = consume task
        queue.removeAll()
        swap(&queue, &spareTaskQueue)
    }

    // MARK: Attributes

    private func setAttributes(
        _ element: WebCore.Element,
        _ attributes: inout WebCore.AttributeVector,
        hasDuplicateAttribute: Bool
    ) {
        if !scriptingContentIsAllowed {
            element.stripScriptingAttributes(&attributes)
        }
        WebCore.parserSetAttributes(element, attributes)
        element.setHasDuplicateAttribute(hasDuplicateAttribute)
    }

    private func setAttributes(_ element: WebCore.Element, _ token: inout AtomHTMLToken) {
        setAttributes(element, &token.attributes, hasDuplicateAttribute: token.hasDuplicateAttribute)
    }

    private func mergeAttributesFromTokenIntoElement(_ token: inout AtomHTMLToken, _ element: WebCore.Element) {
        var attributes = token.takeAttributes()
        if !scriptingContentIsAllowed {
            element.stripScriptingAttributes(&attributes)
        }
        let nonceAttr = WebCore.htmlNonceAttr()
        let span: Span<WebCore.Attribute> = attributes.span()
        for index in span.indices {
            let attributeName = WebCore.attributeName(span[index])
            let value = WebCore.attributeValue(span[index])
            if attributeName == nonceAttr {
                if WebCore.elementHasNonce(element) {
                    continue
                }
                // Make sure the nonce attribute remains hidden.
                element.setAttribute(attributeName, value)
                element.hideNonce()
            } else {
                element.setAttributeWithoutOverwriting(attributeName, value)
            }
        }
    }

    // MARK: The document element, head and body

    private func dispatchDocumentElementAvailableIfNeeded() {
        if isParsingFragment {
            return
        }
        WebCore.injectDocumentStartUserScripts(document)
    }

    func insertHTMLHtmlStartTagBeforeHTML(_ token: inout AtomHTMLToken) {
        let element = WebCore.HTMLHtmlElement.create(document).get()
        setAttributes(element, &token)
        attachLater(attachmentRoot, element)
        openElements.pushHTMLHtmlElement(HTMLStackItem(element: element))

        executeQueuedTasks()
        dispatchDocumentElementAvailableIfNeeded()
    }

    func insertHTMLHtmlStartTagInBody(_ token: inout AtomHTMLToken) {
        // Fragments do not have a root HTML element, so any additional HTML elements encountered during fragment
        // parsing are ignored.
        if isParsingFragment {
            return
        }
        mergeAttributesFromTokenIntoElement(&token, openElements.htmlElement)
    }

    func insertHTMLBodyStartTagInBody(_ token: inout AtomHTMLToken) {
        mergeAttributesFromTokenIntoElement(&token, openElements.bodyElement)
    }

    func insertHTMLHeadElement(_ token: inout AtomHTMLToken) {
        let element = createHTMLElement(&token)
        let item = HTMLStackItem(element: element)
        head = copy item
        attachLater(currentNode, element)
        openElements.pushHTMLHeadElement(item)
    }

    func insertHTMLBodyElement(_ token: inout AtomHTMLToken) {
        let body = createHTMLElement(&token)
        attachLater(currentNode, body)
        openElements.pushHTMLBodyElement(HTMLStackItem(element: body))
    }

    // MARK: Compatibility mode

    func setDefaultCompatibilityMode() {
        if isParsingFragment {
            return
        }
        if document.isSrcdocDocument() {
            return
        }
        setCompatibilityMode(.QuirksMode)
    }

    private func setCompatibilityMode(_ mode: WebCore.DocumentCompatibilityMode) {
        inQuirksMode = mode == .QuirksMode
        document.setCompatibilityMode(mode)
    }

    /// There are three compatibility modes. Quirks emulates WinIE and NS4; CSS parsing is also relaxed in it, e.g.
    /// unit types can be omitted from numbers. Limited quirks is no quirks but for its treatment of line-height in
    /// the inline box model. No quirks follows the specifications.
    private func setCompatibilityModeFromDoctype(
        _ name: WTF.AtomString,
        _ publicId: WTF.String,
        _ systemId: WTF.String
    ) {
        let isNameHTML = name == makeAtomString("html")
        if (isNameHTML && publicId.isEmpty() && systemId.isEmpty()) || document.isSrcdocDocument() {
            setCompatibilityMode(.NoQuirksMode)
            return
        }

        if !isNameHTML || isQuirksDoctype(publicId, systemId) {
            setCompatibilityMode(.QuirksMode)
            return
        }

        if startsWithLettersIgnoringASCIICase(publicId, "-//w3c//dtd xhtml 1.0 frameset//")
            || startsWithLettersIgnoringASCIICase(publicId, "-//w3c//dtd xhtml 1.0 transitional//")
            || (!systemId.isEmpty() && startsWithLettersIgnoringASCIICase(publicId, "-//w3c//dtd html 4.01 frameset//"))
            || (!systemId.isEmpty()
                && startsWithLettersIgnoringASCIICase(publicId, "-//w3c//dtd html 4.01 transitional//"))
        {
            setCompatibilityMode(.LimitedQuirksMode)
            return
        }

        setCompatibilityMode(.NoQuirksMode)
    }

    private static let quirksPublicIdentifierPrefixes = [
        "+//silmaril//dtd html pro v0r11 19970101//",
        "-//advasoft ltd//dtd html 3.0 aswedit + extensions//",
        "-//as//dtd html 3.0 aswedit + extensions//",
        "-//ietf//dtd html 2.0 level 1//",
        "-//ietf//dtd html 2.0 level 2//",
        "-//ietf//dtd html 2.0 strict level 1//",
        "-//ietf//dtd html 2.0 strict level 2//",
        "-//ietf//dtd html 2.0 strict//",
        "-//ietf//dtd html 2.0//",
        "-//ietf//dtd html 2.1e//",
        "-//ietf//dtd html 3.0//",
        "-//ietf//dtd html 3.2 final//",
        "-//ietf//dtd html 3.2//",
        "-//ietf//dtd html 3//",
        "-//ietf//dtd html level 0//",
        "-//ietf//dtd html level 1//",
        "-//ietf//dtd html level 2//",
        "-//ietf//dtd html level 3//",
        "-//ietf//dtd html strict level 0//",
        "-//ietf//dtd html strict level 1//",
        "-//ietf//dtd html strict level 2//",
        "-//ietf//dtd html strict level 3//",
        "-//ietf//dtd html strict//",
        "-//ietf//dtd html//",
        "-//metrius//dtd metrius presentational//",
        "-//microsoft//dtd internet explorer 2.0 html strict//",
        "-//microsoft//dtd internet explorer 2.0 html//",
        "-//microsoft//dtd internet explorer 2.0 tables//",
        "-//microsoft//dtd internet explorer 3.0 html strict//",
        "-//microsoft//dtd internet explorer 3.0 html//",
        "-//microsoft//dtd internet explorer 3.0 tables//",
        "-//netscape comm. corp.//dtd html//",
        "-//netscape comm. corp.//dtd strict html//",
        "-//o'reilly and associates//dtd html 2.0//",
        "-//o'reilly and associates//dtd html extended 1.0//",
        "-//o'reilly and associates//dtd html extended relaxed 1.0//",
        "-//softquad software//dtd hotmetal pro 6.0::19990601::extensions to html 4.0//",
        "-//softquad//dtd hotmetal pro 4.0::19971010::extensions to html 4.0//",
        "-//spyglass//dtd html 2.0 extended//",
        "-//sq//dtd html 2.0 hotmetal + extensions//",
        "-//sun microsystems corp.//dtd hotjava html//",
        "-//sun microsystems corp.//dtd hotjava strict html//",
        "-//w3c//dtd html 3 1995-03-24//",
        "-//w3c//dtd html 3.2 draft//",
        "-//w3c//dtd html 3.2 final//",
        "-//w3c//dtd html 3.2//",
        "-//w3c//dtd html 3.2s draft//",
        "-//w3c//dtd html 4.0 frameset//",
        "-//w3c//dtd html 4.0 transitional//",
        "-//w3c//dtd html experimental 19960712//",
        "-//w3c//dtd html experimental 970421//",
        "-//w3c//dtd w3 html//",
        "-//w3o//dtd w3 html 3.0//",
    ]

    /// The C++'s quirks test, in its order: its prefixes, then its exact matches among the last ones.
    private func isQuirksDoctype(_ publicId: WTF.String, _ systemId: WTF.String) -> Bool {
        for prefix in Self.quirksPublicIdentifierPrefixes where startsWithLettersIgnoringASCIICase(publicId, prefix) {
            return true
        }
        return equalLettersIgnoringASCIICase(publicId, "-//w3o//dtd w3 html strict 3.0//en//")
            || startsWithLettersIgnoringASCIICase(publicId, "-//webtechs//dtd mozilla html 2.0//")
            || startsWithLettersIgnoringASCIICase(publicId, "-//webtechs//dtd mozilla html//")
            || equalLettersIgnoringASCIICase(publicId, "-/w3c/dtd html 4.0 transitional/en")
            || equalLettersIgnoringASCIICase(publicId, "html")
            || equalLettersIgnoringASCIICase(systemId, "http://www.ibm.com/data/dtd/v11/ibmxhtml1-transitional.dtd")
            || (systemId.isEmpty() && startsWithLettersIgnoringASCIICase(publicId, "-//w3c//dtd html 4.01 frameset//"))
            || (systemId.isEmpty()
                && startsWithLettersIgnoringASCIICase(publicId, "-//w3c//dtd html 4.01 transitional//"))
    }

    /// The end of the document. Tells the document, which can destroy the parser and this.
    func finishedParsing(_ document: WebCore.Document) {
        currentTextNode = nil
        document.finishedParsing()
    }

    // MARK: Inserting nodes

    func insertDoctype(_ token: inout AtomHTMLToken) {
        let publicId = token.publicIdentifier
        let systemId = token.systemIdentifier
        let document = self.document
        var name = token.name
        let doctype = WebCore.DocumentType.create(document, name.releaseString(), publicId, systemId).get()
        attachLater(attachmentRoot, doctype)

        // DOCTYPE nodes are only processed when parsing fragments without context elements, which never occurs.
        // Such a fragment would determine its own quirks mode, so the document's must not change here.
        if isParsingFragment {
            return
        }

        if token.forceQuirks && !document.isSrcdocDocument() {
            setCompatibilityMode(.QuirksMode)
        } else {
            setCompatibilityModeFromDoctype(token.name, publicId, systemId)
        }
    }

    func insertProcessingInstruction(_ token: inout AtomHTMLToken) {
        let instruction = WebCore.ProcessingInstruction.create(
            ownerDocumentForCurrentNode, token.storedName, token.data
        ).get()
        attachLater(currentNode, instruction)
    }

    func insertProcessingInstructionOnDocument(_ token: inout AtomHTMLToken) {
        let instruction = WebCore.ProcessingInstruction.create(document, token.storedName, token.data).get()
        attachLater(attachmentRoot, instruction)
    }

    func insertProcessingInstructionOnHTMLHtmlElement(_ token: inout AtomHTMLToken) {
        let root = openElements.rootNode
        let instruction = WebCore.ProcessingInstruction.create(root.document(), token.storedName, token.data).get()
        attachLater(root, instruction)
    }

    private static func takeComment(_ token: inout AtomHTMLToken) -> WTF.String {
        var comment = WTF.String()
        swap(&comment, &token.data)
        return comment
    }

    func insertComment(_ token: inout AtomHTMLToken) {
        let parent = currentNode
        let comment = WebCore.Comment.create(ownerDocumentForCurrentNode, consuming: Self.takeComment(&token)).get()
        attachLater(parent, comment)
    }

    func insertCommentOnDocument(_ token: inout AtomHTMLToken) {
        let comment = WebCore.Comment.create(document, consuming: Self.takeComment(&token)).get()
        attachLater(attachmentRoot, comment)
    }

    func insertCommentOnHTMLHtmlElement(_ token: inout AtomHTMLToken) {
        let parent = openElements.rootNode
        let comment = WebCore.Comment.create(parent.document(), consuming: Self.takeComment(&token)).get()
        attachLater(parent, comment)
    }

    func insertHTMLFormElement(_ token: inout AtomHTMLToken, isParsingTemplateContents: Bool) {
        let element = createHTMLElement(&token)
        let formElement = WebCore.dynamicDowncastHTMLFormElement(element)!
        // If the parser is not parsing template contents, the form element pointer points to the element made.
        if !isParsingTemplateContents {
            form = formElement
        }
        attachLater(currentNode, element)
        openElements.push(HTMLStackItem(element: element))
    }

    func insertHTMLElement(_ token: inout AtomHTMLToken) {
        let element = createHTMLElement(&token)
        attachLater(currentNode, element)
        openElements.push(HTMLStackItem(element: element))
    }

    func insertHTMLTemplateElement(_ token: inout AtomHTMLToken) {
        if parserContentPolicy & WebCore.ParserContentPolicy.AllowDeclarativeShadowRoots.rawValue != 0 {
            var mode = WebCore.ShadowRootMode.UserAgent
            var delegatesFocus = WebCore.ShadowRootDelegatesFocus.No
            var clonable = WebCore.ShadowRootClonable.No
            var serializable = WebCore.ShadowRootSerializable.No
            var slotAssignment = WebCore.SlotAssignmentMode.Named
            var referenceTarget = WTF.String()
            var registryKind = WebCore.Element.CustomElementRegistryKind.Window
            let referenceTargetEnabled = document.settings().shadowRootReferenceTargetEnabled()
            let names: ShadowRootAttributeNames
            if let madeNames = shadowRootAttributeNames {
                names = madeNames
            } else {
                names = ShadowRootAttributeNames()
                shadowRootAttributeNames = names
            }
            do {
                let span: Span<WebCore.Attribute> = token.attributes.span()
                for index in span.indices {
                    let name = WebCore.attributeName(span[index])
                    if name == names.mode {
                        mode = WebCore.parseShadowRootModeAttribute(WebCore.attributeValue(span[index]))
                    } else if name == names.delegatesFocus {
                        delegatesFocus = .Yes
                    } else if name == names.clonable {
                        clonable = .Yes
                    } else if name == names.serializable {
                        serializable = .Yes
                    } else if name == names.slotAssignment {
                        slotAssignment = WebCore.parseSlotAssignmentModeAttribute(WebCore.attributeValue(span[index]))
                    } else if referenceTargetEnabled && name == names.referenceTarget {
                        var value = WebCore.attributeValue(span[index])
                        referenceTarget = value.releaseString()
                    } else if name == names.customElementRegistry {
                        registryKind = .Null
                    }
                }
            }
            // UserAgent is no mode: the attribute is missing or its value is neither open nor closed.
            if mode != .UserAgent, let host = WebCore.dynamicDowncastElement(currentNode) {
                var result = host.attachDeclarativeShadow(
                    mode, delegatesFocus, clonable, serializable, slotAssignment, referenceTarget, registryKind)
                if !result.hasException() {
                    let shadowRoot: WebCore.ShadowRoot = result.releaseReturnValue()
                    let element = createHTMLElement(&token)
                    WebCore.dynamicDowncastHTMLTemplateElement(element)!.setDeclarativeShadowRoot(shadowRoot)
                    openElements.push(HTMLStackItem(element: element))
                    return
                }
            }
        }
        insertHTMLElement(&token)
    }

    /// Inserts the element for the start tag, or, for a custom element the parser must construct, hands it to the
    /// parser with the token's name and attributes and returns true.
    func insertHTMLElementOrFindCustomElementInterface(_ token: inout AtomHTMLToken) -> Bool {
        switch createHTMLElementOrFindCustomElementInterface(&token) {
        case .element(let element):
            attachLater(currentNode, element)
            openElements.push(HTMLStackItem(element: element))
            return false
        case .customElement(let elementInterface, let registry):
            var attributes = token.takeAttributes()
            attributes.swap(&customElementAttributes)
            parserForCall!.setCustomElementToConstruct(elementInterface, registry, token.name)
            return true
        }
    }

    func insertCustomElement(_ element: WebCore.Element) {
        var attributes = WebCore.AttributeVector()
        attributes.swap(&customElementAttributes)
        setAttributes(element, &attributes, hasDuplicateAttribute: false)
        attachLater(currentNode, element)
        openElements.push(HTMLStackItem(element: element))
        executeQueuedTasks()
    }

    /// A self-closing element is never on the stack, so it is finished when it is inserted.
    func insertSelfClosingHTMLElement(_ token: inout AtomHTMLToken) {
        let element = createHTMLElement(&token)
        attachLater(currentNode, element, selfClosing: true)
        // FIXME: Do we want to acknowledge the token's self-closing flag?
        // http://www.whatwg.org/specs/web-apps/current-work/multipage/tokenization.html#acknowledge-self-closing-flag
    }

    /// Possible active formatting elements are a, b, big, code, em, font, i, nobr, s, small, strike, strong, tt
    /// and u.
    func insertFormattingElement(_ token: inout AtomHTMLToken) {
        let element = createHTMLElement(&token)
        attachLater(currentNode, element)
        let item = HTMLStackItem(element: element)
        let formattingItem = HTMLFormattingItem(item, attributes: token.takeAttributes())
        openElements.push(item)
        activeFormattingElements.append(formattingItem)
    }

    /// For createContextualFragment, the specifications say to mark the script parser-inserted and already started,
    /// and later unmark it. Script cannot observe those flags in the fragment, so the unmarking is skipped.
    func insertScriptElement(_ token: inout AtomHTMLToken) {
        let parserInserted =
            parserContentPolicy & WebCore.ParserContentPolicy.DoNotMarkAlreadyStarted.rawValue == 0
        let alreadyStarted = isParsingFragment && parserInserted
        let element = WebCore.HTMLScriptElement.create(
            WebCore.qualifiedNameForElementName(.HTML_script), ownerDocumentForCurrentNode, parserInserted,
            alreadyStarted
        ).get()
        setAttributes(element, &token)
        if scriptingContentIsAllowed {
            attachLater(currentNode, element)
        }
        openElements.push(HTMLStackItem(element: element))
    }

    func insertForeignElement(_ token: inout AtomHTMLToken, _ namespaceURI: WTF.AtomString) {
        let element = createElement(&token, namespaceURI)
        if scriptingContentIsAllowed || element.elementName() != .SVG_script {
            attachLater(currentNode, element, selfClosing: token.selfClosing)
        }
        if !token.selfClosing {
            openElements.push(HTMLStackItem(element: element))
        }
    }

    // MARK: Text

    /// Inserts the characters into the current node, or its foster parent: at once, not queued, appending to a
    /// text node just before the insertion point, and in nodes of at most Text::defaultLengthLimit characters,
    /// split on grapheme cluster boundaries, but in script and style elements.
    func insertTextNode(_ characters: WTF.String) {
        var task = HTMLConstructionSiteTask(.insert)
        task.parent = currentNode

        if shouldFosterParent {
            recordFosterSite(&task)
            // The parent is read below and these tasks run at once, so resolve the site now rather than in insert.
            resolveFosterSite(&task)
        }

        let length = characters.length()
        var currentPosition: UInt32 = 0
        let lengthLimit: UInt32 = shouldUseLengthLimit(task.parent!) ? WebCore.Text.defaultLengthLimit : UInt32.max

        // FIXME: Splitting text nodes into smaller chunks contradicts HTML5 spec, but is currently necessary
        // for performance, see <https://bugs.webkit.org/show_bug.cgi?id=55898>.

        let previousChild: WebCore.Node?
        if let nextChild = task.nextChild {
            previousChild = nextChild.previousSibling()
        } else if let templateParent = WebCore.dynamicDowncastHTMLTemplateElement(task.parent) {
            previousChild = templateParent.contentIfAvailable()?.lastChild()
        } else {
            previousChild = task.parent!.lastChild()
        }
        if let previousTextChild = WebCore.dynamicDowncastText(previousChild),
            previousTextChild.length() < lengthLimit
        {
            // FIXME: We're only supposed to append to this text node if it was the last text node inserted by the
            // parser.
            let proposedBreakIndex = min(length, lengthLimit - previousTextChild.length())
            let breakIndex = findBreakIndex(characters, 0, proposedBreakIndex)
            if breakIndex != 0 {
                let isNewTextNode = !previousTextChild.isSameNode(currentTextNode)
                if isNewTextNode {
                    currentTextNode = previousTextChild
                }
                parserForCall!.appendToTextNode(previousTextChild, characters, breakIndex, isNewTextNode)
                currentPosition = breakIndex
            }
        }

        while currentPosition < length {
            // Wraps only for an unlimited node, which starts at 0 here: the C++'s unsigned sum, kept.
            let proposedBreakIndex = min(currentPosition &+ lengthLimit, length)
            var breakIndex = findBreakIndex(characters, currentPosition, proposedBreakIndex)
            // If no break index is found (unbreakable characters), the text is not split.
            if breakIndex == currentPosition {
                breakIndex = length
            }

            // The C++'s unsigned difference: breakIndex is not below currentPosition.
            let substring = characters.substring(currentPosition, breakIndex &- currentPosition)
            let textNode = WebCore.Text.create(task.parent!.document(), consuming: substring).get()

            currentPosition &+= textNode.length()  // Cannot overflow: at most the characters' length.
            task.child = textNode

            executeTask(&task)
        }
    }

    /// The index at or before proposedBreakIndex at which a text node can end without splitting a grapheme
    /// cluster.
    private func findBreakIndex(_ string: WTF.String, _ currentPosition: UInt32, _ proposedBreakIndex: UInt32) -> UInt32
    {
        if proposedBreakIndex == string.length() || string.is8Bit() {
            return proposedBreakIndex
        }
        return WebCore.findBreakIndex(string, currentPosition, proposedBreakIndex)
    }

    // MARK: The adoption agency's tasks

    func reparent(_ newParent: borrowing HTMLStackItem, _ child: borrowing HTMLStackItem) {
        var task = HTMLConstructionSiteTask(.reparent)
        task.parent = newParent.node
        task.child = child.element
        queueTask(task)
    }

    /// Moves `child`, which is already parsed (moved in the tree, not parsed for the first time), so its
    /// beginParsingChildren and finishParsingChildren are not called.
    func insertAlreadyParsedChild(_ newParent: borrowing HTMLStackItem, _ child: borrowing HTMLStackItem) {
        var task = HTMLConstructionSiteTask(.insertAlreadyParsedChild)
        if causesFosterParenting(newParent.elementName) {
            recordFosterSite(&task)
        } else {
            task.parent = newParent.node
        }
        task.child = child.element
        queueTask(task)
    }

    func takeAllChildrenAndReparent(_ newParent: borrowing HTMLStackItem, _ oldParent: borrowing HTMLStackItem) {
        var task = HTMLConstructionSiteTask(.takeAllChildrenAndReparent)
        task.parent = newParent.node
        task.oldParent = oldParent.node
        queueTask(task)
    }

    // MARK: Making elements

    private func qualifiedNameForTag(_ token: borrowing AtomHTMLToken, _ namespaceURI: WTF.AtomString)
        -> WebCore.QualifiedName
    {
        let nodeNamespace = WebCore.findNamespace(namespaceURI)
        let elementName = WebCore.elementNameForTag(nodeNamespace, token.tagName)
        if elementName != .Unknown {
            return WebCore.qualifiedNameForElementName(elementName)
        }
        return WebCore.QualifiedName(WTF.AtomString(), token.name, namespaceURI, nodeNamespace, elementName)
    }

    private func qualifiedNameForHTMLTag(_ token: borrowing AtomHTMLToken) -> WebCore.QualifiedName {
        let elementName = WebCore.elementNameForTag(.HTML, token.tagName)
        if elementName != .Unknown {
            return WebCore.qualifiedNameForElementName(elementName)
        }
        let namespaceURI: WTF.AtomString
        if let madeURI = xhtmlNamespaceURI {
            namespaceURI = madeURI
        } else {
            namespaceURI = makeAtomString("http://www.w3.org/1999/xhtml")
            xhtmlNamespaceURI = namespaceURI
        }
        return WebCore.QualifiedName(WTF.AtomString(), token.name, namespaceURI, .HTML, elementName)
    }

    private func createElement(_ token: inout AtomHTMLToken, _ namespaceURI: WTF.AtomString) -> WebCore.Element {
        let element = ownerDocumentForCurrentNode.createElement(qualifiedNameForTag(token, namespaceURI), true, nil)
            .get()
        setAttributes(element, &token)
        return element
    }

    private enum CreatedElement {
        case element(WebCore.HTMLElement)
        case customElement(WebCore.JSCustomElementInterface, WebCore.CustomElementRegistry)
    }

    private func createHTMLElementOrFindCustomElementInterface(_ token: inout AtomHTMLToken) -> CreatedElement {
        // The current node's tree scope, or its template content's, as its root node: TreeScope is not visible here.
        let treeScopeRoot = WebCore.treeScopeRootForInsertion(currentNode)
        let ownerDocument = treeScopeRoot.document()
        var element = WebCore.HTMLElementFactory.createKnownElement(token.tagName, ownerDocument, true).get()
        let registry =
            openElements.stackDepth > 1
            ? WebCore.customElementRegistryForInsertion(currentNode, treeScopeRoot) : self.registry
        if element == nil {
            if let registry, let elementInterface = registry.findInterface(token.name) {
                var shouldUseNullCustomElementRegistry = false
                let customElementRegistryAttr = WebCore.htmlCustomelementregistryAttr()
                do {
                    let span: Span<WebCore.Attribute> = token.attributes.span()
                    for index in span.indices where WebCore.attributeName(span[index]) == customElementRegistryAttr {
                        shouldUseNullCustomElementRegistry = true
                        break
                    }
                }
                if !shouldUseNullCustomElementRegistry {
                    if !isParsingFragment {
                        return .customElement(elementInterface, registry)
                    }
                    let upgradeCandidate = elementInterface.createElement(ownerDocument).get()
                    upgradeCandidate.setIsCustomElementUpgradeCandidate()
                    upgradeCandidate.enqueueToUpgrade(elementInterface)
                    element = upgradeCandidate
                }
            }
            if element == nil {
                let qualifiedName = qualifiedNameForHTMLTag(token)
                if WebCore.Document.validateCustomElementName(token.name) == .Valid {
                    let customElement = WebCore.HTMLMaybeFormAssociatedCustomElement.create(
                        qualifiedName, ownerDocument
                    ).get()
                    customElement.setIsCustomElementUpgradeCandidate()
                    element = customElement
                } else {
                    element = WebCore.HTMLUnknownElement.create(qualifiedName, ownerDocument).get()
                }
            }
        }
        let createdElement = element!
        if registry == nil && containerForCurrentNode.usesNullCustomElementRegistry() {
            createdElement.setUsesNullCustomElementRegistry()
        }
        if let registry, WebCore.isScopedRegistryOutsideTreeScope(registry, treeScopeRoot) {
            WebCore.CustomElementRegistry.addToScopedCustomElementRegistryMap(createdElement, registry)
        }

        if let form, !openElements.containsTemplateElement {
            WebCore.setFormSetByParser(createdElement, form)
        }

        // FIXME: This is a hack to connect images to pictures before the image has been inserted into the
        // document. It can be removed once asynchronous image loading is working. When this hack is removed, the
        // assertion just before the setPictureElement() call in HTMLImageElement::insertionSteps can be simplified.
        if let currentPictureElement = WebCore.dynamicDowncastHTMLPictureElement(currentNode),
            let imageElement = WebCore.dynamicDowncastHTMLImageElement(createdElement)
        {
            imageElement.setPictureElement(currentPictureElement)
        }

        setAttributes(createdElement, &token)
        return .element(createdElement)
    }

    private func createHTMLElement(_ token: inout AtomHTMLToken) -> WebCore.HTMLElement {
        guard case .element(let element) = createHTMLElementOrFindCustomElementInterface(&token) else {
            fatalError("HTMLConstructionSite.createHTMLElement: a custom element to construct")
        }
        return element
    }

    /// A new element for a formatting element's entry, made from the entry's token: its tag and a copy of its
    /// attributes.
    func createElementFromSavedToken(_ item: HTMLFormattingItem) -> HTMLFormattingItem {
        let tagName = WebCore.tagNameForElementName(item.elementName)
        let attributes = item.attributes
        var fakeToken = AtomHTMLToken(.StartTag, tagName, name: item.localName, attributes: attributes)
        let element = createHTMLElement(&fakeToken)
        return HTMLFormattingItem(HTMLStackItem(element: element), attributes: fakeToken.takeAttributes())
    }

    // MARK: Formatting elements

    func indexOfFirstUnopenFormattingElement() -> Int? {
        let activeFormattingElements = self.activeFormattingElements
        let openElements = self.openElements
        if activeFormattingElements.isEmpty {
            return nil
        }
        var index = activeFormattingElements.count
        repeat {
            index -= 1
            let element = activeFormattingElements.element(at: index)
            if element == nil || openElements.contains(element!) {
                let firstUnopenElementIndex = index + 1
                return firstUnopenElementIndex < activeFormattingElements.count ? firstUnopenElementIndex : nil
            }
        } while index != 0
        return index
    }

    func reconstructTheActiveFormattingElements() {
        guard var unopenEntryIndex = indexOfFirstUnopenFormattingElement() else {
            return
        }
        while unopenEntryIndex < activeFormattingElements.count {
            let unopenedEntry = activeFormattingElements.at(unopenEntryIndex)!
            let reconstructed = createElementFromSavedToken(unopenedEntry)
            attachLater(currentNode, reconstructed.element)
            openElements.push(HTMLStackItem(reconstructed))
            activeFormattingElements.replaceElement(at: unopenEntryIndex, with: reconstructed)
            unopenEntryIndex += 1
        }
    }

    // MARK: Implied end tags

    func generateImpliedEndTagsWithExclusion(_ elementName: WebCore.ElementName) {
        while hasImpliedEndTag(currentElementName) && currentElementName != elementName {
            openElements.pop()
        }
    }

    func generateImpliedEndTagsWithExclusion(_ tagName: WTF.AtomString) {
        while hasImpliedEndTag(currentElementName) && !openElements.topMatchesHTMLTag(tagName) {
            openElements.pop()
        }
    }

    func generateImpliedEndTags() {
        while hasImpliedEndTag(currentElementName) {
            openElements.pop()
        }
    }

    // MARK: Foster parenting

    /// Records the stack-derived part of the adjusted insertion location for foster parenting, the substeps of step
    /// 3 of https://html.spec.whatwg.org/#appropriate-place-for-inserting-a-node. resolveFosterSite derives the
    /// rest from the DOM, so task.parent is not final here.
    private func recordFosterSite(_ task: inout HTMLConstructionSiteTask) {
        // If the last template or table element on the stack of open elements is a template, that element is the
        // foster parent, not its parent.
        let lastTemplate = openElements.indexOfTopmost(.HTML_template)
        let lastTable = openElements.indexOfTopmost(.HTML_table)
        if let lastTemplate, lastTable == nil || lastTemplate > lastTable! {
            task.parent = openElements.element(at: lastTemplate)
            return
        }

        guard let lastTable else {
            // Fragment case.
            task.parent = openElements.rootNode
            return
        }

        // The table's parent is read when the task runs, so record the element immediately above the table in the
        // stack of open elements as the fallback for when it has no parent by then.
        task.parent = openElements.node(at: lastTable - 1)
        task.nextChild = openElements.element(at: lastTable)
    }

    var shouldFosterParent: Bool {
        redirectAttachToFosterParent && causesFosterParenting(currentElementName)
    }

    func fosterParent(_ node: WebCore.Node) {
        var task = HTMLConstructionSiteTask(.insert)
        recordFosterSite(&task)
        task.child = node
        queueTask(task)
    }

    /// Runs `body` with insertions into the current node foster parented, as the in table insertion mode asks.
    func withRedirectToFosterParent(_ body: () -> Void) {
        let saved = redirectAttachToFosterParent
        redirectAttachToFosterParent = true
        body()
        redirectAttachToFosterParent = saved
    }

    // MARK: The form element pointer

    /// For a fragment parse's context.
    func setForm(_ form: WebCore.HTMLFormElement?) {
        self.form = form
    }

    func takeForm() -> WebCore.HTMLFormElement? {
        let form = self.form
        self.form = nil
        return form
    }
}

/// HTMLNames' declarative shadow root attributes.
private final class ShadowRootAttributeNames {
    let mode = makeAttributeName("shadowrootmode")
    let delegatesFocus = makeAttributeName("shadowrootdelegatesfocus")
    let clonable = makeAttributeName("shadowrootclonable")
    let serializable = makeAttributeName("shadowrootserializable")
    let slotAssignment = makeAttributeName("shadowrootslotassignment")
    let referenceTarget = makeAttributeName("shadowrootreferencetarget")
    let customElementRegistry = makeAttributeName("shadowrootcustomelementregistry")
}

#endif
