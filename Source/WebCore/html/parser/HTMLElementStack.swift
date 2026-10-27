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
internal import WebCore_Private.Core.DocumentFragment
internal import WebCore_Private.Core.Element
internal import WebCore_Private.Core.ElementInlines
internal import WebCore_Private.Core.HTMLTreeBuilderSwiftSupport
internal import WebCore_Private.Core.NodeName
internal import WebCore_Private.Core.QualifiedName
internal import JavaScriptCore_Private.Cxx.Snippet
internal import JavaScriptCore_Private.Cxx.DOMJITCallDOMGetterSnippet
internal import JavaScriptCore_Private.Cxx.WasmInstanceAnchor
internal import JavaScriptCore_Private.Cxx.WasmCalleeGroup
internal import JavaScriptCore_Private.Cxx.WasmModule
internal import JavaScriptCore_Private.Cxx.WasmModuleDebugInfo
internal import wtf.Core.Stopwatch

/// An element on the stack of open elements, or the document fragment or context element of a fragment parse.
///
/// An item does not change once made. The stack holds its items in its own storage, so pushing an element allocates
/// nothing but the storage's growth. An item has no attributes: only formatting elements need their token's
/// attributes again, and the list of active formatting elements keeps them (HTMLFormattingItem).
struct HTMLStackItem {
    let node: WebCore.ContainerNode
    /// Nil only for a document fragment.
    let element: WebCore.Element?
    let elementName: WebCore.ElementName
    let nodeNamespace: WebCore.Namespace
    /// The item's stack word, which each initializer sets last from the fields above.
    private(set) var stackWord: UInt32 = 0

    init(element: WebCore.Element) {
        self.node = element
        self.element = element
        self.elementName = element.elementName()
        self.nodeNamespace = element.nodeNamespace()
        self.stackWord = computedStackWord
    }

    /// The item for a formatting element's entry.
    init(_ item: HTMLFormattingItem) {
        self.node = item.element
        self.element = item.element
        self.elementName = item.elementName
        self.nodeNamespace = item.nodeNamespace
        self.stackWord = computedStackWord
    }

    init(fragment: WebCore.DocumentFragment) {
        self.node = fragment
        self.element = nil
        self.elementName = .Unknown
        self.nodeNamespace = .Unknown
        self.stackWord = computedStackWord
    }

    var isElement: Bool { element != nil }
    var isDocumentFragment: Bool { element == nil }

    var localName: WTF.AtomString { element.map { WebCore.elementLocalName($0) } ?? WTF.AtomString() }
    var namespaceURI: WTF.AtomString { element.map { WebCore.elementNamespaceURI($0) } ?? WTF.AtomString() }

    func matchesHTMLTag(_ name: WTF.AtomString) -> Bool {
        localName == name && nodeNamespace == .HTML
    }

    /// Whether this item and `other` are the same node.
    func isSame(_ other: borrowing HTMLStackItem) -> Bool { node.isSameNode(other.node) }

    /// A document fragment takes the place of the document element when parsing fragments and thus is treated as if
    /// it was in the HTML namespace.
    var isInHTMLNamespace: Bool { nodeNamespace == .HTML || isDocumentFragment }

    var isNumberedHeaderElement: Bool {
        switch elementName {
        case .HTML_h1, .HTML_h2, .HTML_h3, .HTML_h4, .HTML_h5, .HTML_h6:
            return true
        default:
            return false
        }
    }

    /// https://html.spec.whatwg.org/multipage/parsing.html#special
    var isSpecialNode: Bool {
        if isDocumentFragment {
            return true
        }
        switch elementName {
        case .HTML_address, .HTML_applet, .HTML_area, .HTML_article, .HTML_aside, .HTML_base, .HTML_basefont,
            .HTML_bgsound, .HTML_blockquote, .HTML_body, .HTML_br, .HTML_button, .HTML_caption, .HTML_center,
            .HTML_col, .HTML_colgroup, .HTML_dd, .HTML_details, .HTML_dir, .HTML_div, .HTML_dl, .HTML_dt,
            .HTML_embed, .HTML_fieldset, .HTML_figcaption, .HTML_figure, .HTML_footer, .HTML_form, .HTML_frame,
            .HTML_frameset, .HTML_h1, .HTML_h2, .HTML_h3, .HTML_h4, .HTML_h5, .HTML_h6, .HTML_head, .HTML_header,
            .HTML_hgroup, .HTML_hr, .HTML_html, .HTML_iframe, .HTML_img, .HTML_input, .HTML_li, .HTML_link,
            .HTML_listing, .HTML_main, .HTML_marquee, .HTML_menu, .HTML_meta, .HTML_nav, .HTML_noembed,
            .HTML_noframes, .HTML_noscript, .HTML_object, .HTML_ol, .HTML_p, .HTML_param, .HTML_plaintext,
            .HTML_pre, .HTML_script, .HTML_search, .HTML_section, .HTML_select, .HTML_style, .HTML_summary,
            .HTML_table, .HTML_tbody, .HTML_td, .HTML_template, .HTML_textarea, .HTML_tfoot, .HTML_th,
            .HTML_thead, .HTML_tr, .HTML_ul, .HTML_wbr, .HTML_xmp, .MathML_annotation_xml, .MathML_mi,
            .MathML_mo, .MathML_mn, .MathML_ms, .MathML_mtext, .SVG_desc, .SVG_foreignObject, .SVG_title:
            return true
        default:
            return false
        }
    }

    fileprivate var isRootNode: Bool { isDocumentFragment || elementName == .HTML_html }

    fileprivate var isScopeMarker: Bool {
        switch elementName {
        case .HTML_applet, .HTML_caption, .HTML_marquee, .HTML_object, .HTML_select, .HTML_table, .HTML_td,
            .HTML_th, .HTML_template, .MathML_mi, .MathML_mo, .MathML_mn, .MathML_ms, .MathML_mtext,
            .MathML_annotation_xml, .SVG_foreignObject, .SVG_desc, .SVG_title:
            return true
        default:
            return isRootNode
        }
    }

    fileprivate var isListItemScopeMarker: Bool {
        isScopeMarker || elementName == .HTML_ol || elementName == .HTML_ul
    }

    fileprivate var isTableScopeMarker: Bool {
        elementName == .HTML_table || elementName == .HTML_template || isRootNode
    }

    fileprivate var isTableBodyScopeMarker: Bool {
        elementName == .HTML_tbody || elementName == .HTML_tfoot || elementName == .HTML_thead
            || elementName == .HTML_template || isRootNode
    }

    fileprivate var isTableRowScopeMarker: Bool {
        elementName == .HTML_tr || elementName == .HTML_template || isRootNode
    }

    fileprivate var isButtonScopeMarker: Bool { isScopeMarker || elementName == .HTML_button }

    /// The element name and the scope marker, special and foreign content predicates, as HTMLElementStack's scope walks and the
    /// tree builder's per-token checks read them. Each predicate depends only on the element name, the namespace and
    /// whether the item is a document fragment, which do not change. An annotation-xml element's encoding attribute
    /// can change, so whether it is an HTML integration point is not part of the word.
    private var computedStackWord: UInt32 {
        var word = UInt32(elementName.rawValue)
        if isScopeMarker {
            word |= HTMLElementStack.scopeMarkerBit
        }
        if isListItemScopeMarker {
            word |= HTMLElementStack.listItemScopeMarkerBit
        }
        if isTableScopeMarker {
            word |= HTMLElementStack.tableScopeMarkerBit
        }
        if isButtonScopeMarker {
            word |= HTMLElementStack.buttonScopeMarkerBit
        }
        if isNumberedHeaderElement {
            word |= HTMLElementStack.numberedHeaderElementBit
        }
        if isInHTMLNamespace {
            word |= HTMLElementStack.htmlNamespaceBit
        }
        if isMathMLTextIntegrationPoint {
            word |= HTMLElementStack.mathMLTextIntegrationPointBit
        }
        if elementName == .SVG_foreignObject || elementName == .SVG_desc || elementName == .SVG_title {
            word |= HTMLElementStack.svgHTMLIntegrationPointBit
        }
        if isSpecialNode {
            word |= HTMLElementStack.specialNodeBit
        }
        return word
    }

    /// https://html.spec.whatwg.org/multipage/parsing.html#mathml-text-integration-point
    var isMathMLTextIntegrationPoint: Bool {
        elementName == .MathML_mi || elementName == .MathML_mo || elementName == .MathML_mn
            || elementName == .MathML_ms || elementName == .MathML_mtext
    }

    /// https://html.spec.whatwg.org/multipage/parsing.html#html-integration-point
    func isHTMLIntegrationPoint(encodingName: WebCore.QualifiedName) -> Bool {
        if elementName == .MathML_annotation_xml {
            guard let element else {
                return false
            }
            return annotationXMLIsHTMLIntegrationPoint(element, encodingName)
        }
        return elementName == .SVG_foreignObject || elementName == .SVG_desc || elementName == .SVG_title
    }
}

/// Whether an annotation-xml element is an HTML integration point, from its encoding attribute. The attribute is read
/// off the element: a fragment's context element has no token.
func annotationXMLIsHTMLIntegrationPoint(_ element: WebCore.Element, _ encodingName: WebCore.QualifiedName) -> Bool {
    var encoding = WebCore.elementAttributeWithoutSynchronization(element, encodingName)
    let value = encoding.releaseString()
    return equalLettersIgnoringASCIICase(value, "text/html")
        || equalLettersIgnoringASCIICase(value, "application/xhtml+xml")
}

/// An entry of the list of active formatting elements: the element, with the attributes of the token that made it,
/// from which the element is made again when it is reconstructed or the adoption agency algorithm replaces it.
///
/// An item does not change once made. While its element is on the stack of open elements, the entry is the one the
/// element was pushed with.
final class HTMLFormattingItem {
    let element: WebCore.Element
    let elementName: WebCore.ElementName
    let nodeNamespace: WebCore.Namespace
    let attributes: WebCore.AttributeVector

    /// The entry for the element of `item`, which keeps `attributes` with no spare capacity.
    init(_ item: borrowing HTMLStackItem, attributes: consuming WebCore.AttributeVector) {
        self.element = item.element!
        self.elementName = item.elementName
        self.nodeNamespace = item.nodeNamespace
        if attributes.size() < attributes.capacity() {
            attributes.shrinkToFit()
        }
        self.attributes = attributes
    }

    var localName: WTF.AtomString { WebCore.elementLocalName(element) }
    var namespaceURI: WTF.AtomString { WebCore.elementNamespaceURI(element) }

    /// The value of the token's attribute with the name, if it had one.
    func findAttributeValue(_ name: WebCore.QualifiedName) -> WTF.AtomString? {
        let attributes: Span<WebCore.Attribute> = self.attributes.span()
        for index in attributes.indices where WebCore.attributeName(attributes[index]).matches(name) {
            return WebCore.attributeValue(attributes[index])
        }
        return nil
    }
}

/// WTF's equalLettersIgnoringASCIICase for a literal of lowercase letters, digits and punctuation: each character,
/// with the 0x20 bit set, equals the literal's.
func equalLettersIgnoringASCIICase(_ string: WTF.String, _ lowercaseLetters: Swift.String) -> Bool {
    guard Int(string.length()) == lowercaseLetters.utf8.count else {
        return false
    }
    return hasPrefixWithLettersIgnoringASCIICase(string, lowercaseLetters)
}

/// WTF's startsWithLettersIgnoringASCIICase for such a literal.
func startsWithLettersIgnoringASCIICase(_ string: WTF.String, _ lowercaseLetters: Swift.String) -> Bool {
    guard Int(string.length()) >= lowercaseLetters.utf8.count else {
        return false
    }
    return hasPrefixWithLettersIgnoringASCIICase(string, lowercaseLetters)
}

private func hasPrefixWithLettersIgnoringASCIICase(_ string: WTF.String, _ lowercaseLetters: Swift.String) -> Bool {
    if string.is8Bit() {
        let characters: Span<WTF.Latin1Character> = string.span8()
        var index = 0
        for letter in lowercaseLetters.utf8 {
            if characters[index].value | 0x20 != letter {
                return false
            }
            index += 1
        }
        return true
    }
    let characters: Span<UInt16> = string.span16()
    var index = 0
    for letter in lowercaseLetters.utf8 {
        if characters[index] | 0x20 != UInt16(letter) {
            return false
        }
        index += 1
    }
    return true
}

/// The stack of open elements (https://html.spec.whatwg.org/multipage/parsing.html#stack-of-open-elements), which
/// grows upwards: its top is the current node. The root (the html element, or the fragment) is pushed first and
/// never popped. The stack remembers the root, head and body as they are pushed.
///
/// An element is on the stack at most once, so an item's node identifies its record: the tree builder holds items
/// or elements, not positions, across calls that change the stack, where the C++ held ElementRecord pointers, and
/// the stack finds their positions again. No access to the storage is open across a call into the DOM: popping
/// takes the item off the stack before it calls finishParsingChildren, which can run script.
final class HTMLElementStack {
    fileprivate static let elementNameMask: UInt32 = 0xFFFF
    fileprivate static let scopeMarkerBit: UInt32 = 1 << 16
    fileprivate static let listItemScopeMarkerBit: UInt32 = 1 << 17
    fileprivate static let tableScopeMarkerBit: UInt32 = 1 << 18
    fileprivate static let buttonScopeMarkerBit: UInt32 = 1 << 19
    fileprivate static let numberedHeaderElementBit: UInt32 = 1 << 20
    fileprivate static let htmlNamespaceBit: UInt32 = 1 << 21
    fileprivate static let mathMLTextIntegrationPointBit: UInt32 = 1 << 22
    fileprivate static let svgHTMLIntegrationPointBit: UInt32 = 1 << 23
    fileprivate static let specialNodeBit: UInt32 = 1 << 24

    /// For a stack word: whether the item is in the HTML namespace or is the document fragment.
    static func isInHTMLNamespace(_ word: UInt32) -> Bool { word & htmlNamespaceBit != 0 }
    static func isMathMLTextIntegrationPoint(_ word: UInt32) -> Bool { word & mathMLTextIntegrationPointBit != 0 }
    /// Whether the item is one of the SVG elements that are HTML integration points.
    static func isSVGHTMLIntegrationPoint(_ word: UInt32) -> Bool { word & svgHTMLIntegrationPointBit != 0 }
    static func isMathMLAnnotationXML(_ word: UInt32) -> Bool {
        word & elementNameMask == UInt32(WebCore.ElementName.MathML_annotation_xml.rawValue)
    }
    static func isNumberedHeaderElement(_ word: UInt32) -> Bool { word & numberedHeaderElementBit != 0 }

    /// Bottom first. Only the storage functions below change `items`, `words`, `topWord` and `topElementName`, so
    /// they always agree.
    private var items = UniqueArray<HTMLStackItem>()
    /// Each item's `stackWord`, so that the scope walks read no item.
    private var words = UniqueArray<UInt32>()
    /// The top item's `stackWord`, or 0 when the stack is empty.
    private(set) var topWord: UInt32 = 0
    /// The top item's element name, or Unknown when the stack is empty.
    private(set) var topElementName: WebCore.ElementName = .Unknown
    private var root: HTMLStackItem?
    private var head: WebCore.Element?
    private var body: WebCore.Element?
    /// As the C++'s m_stackDepth: popAll sets it to zero before popping, and a pop lowers it after
    /// finishParsingChildren.
    private(set) var stackDepth: UInt32 = 0
    private var templateElementCount: UInt32 = 0

    var itemCount: Int { items.count }
    var topNode: WebCore.ContainerNode { items[topIndex].node }
    var topElement: WebCore.Element { items[topIndex].element! }
    var topIsElement: Bool { items[topIndex].isElement }
    var topLocalName: WTF.AtomString { items[topIndex].localName }
    var topNamespaceURI: WTF.AtomString { items[topIndex].namespaceURI }

    func topMatchesHTMLTag(_ name: WTF.AtomString) -> Bool { items[topIndex].matchesHTMLTag(name) }

    /// The top item's position; reading the storage there traps when the stack is empty.
    private var topIndex: Int { items.count &- 1 }  // Cannot overflow: a count is not negative.

    var containsTemplateElement: Bool { templateElementCount != 0 }

    /// The root is pushed first and never popped, and a template can only be pushed above it, so the count is
    /// enough.
    var hasTemplateInHTMLScope: Bool { templateElementCount != 0 }

    var hasOnlyOneElement: Bool { items.count == 1 }

    /// For the fragment case of body and frameset in the in body insertion mode: a body element, if any, is always
    /// the second element on the stack.
    var secondElementIsHTMLBodyElement: Bool { body != nil }

    var rootNode: WebCore.ContainerNode { root!.node }
    var htmlElement: WebCore.Element { root!.element! }
    var headElement: WebCore.Element { head! }
    var bodyElement: WebCore.Element { body! }

    // MARK: Storage

    /// The storage functions move the arrays out while they change, so that no access to the stored properties is
    /// open while the arrays allocate or free memory or release an item, and the compiler can check those accesses
    /// without run-time checks. They must not call into the DOM.
    @inline(always)
    private func takeStorage(_ items: inout UniqueArray<HTMLStackItem>, _ words: inout UniqueArray<UInt32>) {
        swap(&items, &self.items)
        swap(&words, &self.words)
    }

    /// Puts the arrays back, with the top item's word and element name.
    @inline(always)
    private func restoreStorage(
        _ items: inout UniqueArray<HTMLStackItem>,
        _ words: inout UniqueArray<UInt32>,
        topWord: UInt32,
        topElementName: WebCore.ElementName
    ) {
        swap(&items, &self.items)
        swap(&words, &self.words)
        self.topWord = topWord
        self.topElementName = topElementName
    }

    /// Puts the arrays back, reading the top item's word and element name from them.
    @inline(always)
    private func restoreStorage(_ items: inout UniqueArray<HTMLStackItem>, _ words: inout UniqueArray<UInt32>) {
        let topIndex = items.count &- 1  // Cannot overflow: a count is not negative.
        let topWord: UInt32 = topIndex < 0 ? 0 : items[topIndex].stackWord
        let topElementName: WebCore.ElementName = topIndex < 0 ? .Unknown : items[topIndex].elementName
        restoreStorage(&items, &words, topWord: topWord, topElementName: topElementName)
    }

    private func appendToStorage(_ item: consuming HTMLStackItem) {
        let word = item.stackWord
        let elementName = item.elementName
        var items = UniqueArray<HTMLStackItem>()
        var words = UniqueArray<UInt32>()
        takeStorage(&items, &words)
        items.append(consume item)
        words.append(word)
        restoreStorage(&items, &words, topWord: word, topElementName: elementName)
    }

    private func insertIntoStorage(_ item: consuming HTMLStackItem, at index: Int) {
        let word = item.stackWord
        var items = UniqueArray<HTMLStackItem>()
        var words = UniqueArray<UInt32>()
        takeStorage(&items, &words)
        items.insert(consume item, at: index)
        words.insert(word, at: index)
        restoreStorage(&items, &words)
    }

    private func removeLastFromStorage() -> HTMLStackItem {
        var items = UniqueArray<HTMLStackItem>()
        var words = UniqueArray<UInt32>()
        takeStorage(&items, &words)
        _ = words.removeLast()
        let removed = items.removeLast()
        restoreStorage(&items, &words)
        return removed
    }

    private func removeFromStorage(at index: Int) -> HTMLStackItem {
        var items = UniqueArray<HTMLStackItem>()
        var words = UniqueArray<UInt32>()
        takeStorage(&items, &words)
        _ = words.remove(at: index)
        let removed = items.remove(at: index)
        restoreStorage(&items, &words)
        return removed
    }

    private func replaceInStorage(at index: Int, with item: consuming HTMLStackItem) -> HTMLStackItem {
        let word = item.stackWord
        var items = UniqueArray<HTMLStackItem>()
        var words = UniqueArray<UInt32>()
        takeStorage(&items, &words)
        var replaced = item
        swap(&items[index], &replaced)
        words[index] = word
        restoreStorage(&items, &words)
        return replaced
    }

    // MARK: Records

    /// The node of the record at `index`, counted from the bottom.
    func node(at index: Int) -> WebCore.ContainerNode { items[index].node }

    /// The element of the record at `index`, or nil for the document fragment.
    func element(at index: Int) -> WebCore.Element? { items[index].element }

    func localName(at index: Int) -> WTF.AtomString { items[index].localName }

    func elementName(at index: Int) -> WebCore.ElementName { items[index].elementName }

    /// The stack word of the record at `index`.
    func word(at index: Int) -> UInt32 { words[index] }

    /// The position of the record for `item`'s node, counted from the bottom.
    private func index(of item: borrowing HTMLStackItem) -> Int? {
        var index = items.count
        while index > 0 {
            index -= 1
            if item.node.isSameNode(items[index].node) {
                return index
            }
        }
        return nil
    }

    /// The item below `item`'s record.
    func next(_ item: borrowing HTMLStackItem) -> HTMLStackItem? {
        guard let index = index(of: item), index > 0 else {
            return nil
        }
        return items[index - 1]
    }

    /// Puts `newItem` in place of `item`'s record, which stays where it is on the stack.
    func replaceElement(_ item: borrowing HTMLStackItem, with newItem: consuming HTMLStackItem) {
        // The C++ does not call finishParsingChildren on the element replaced.
        _ = replaceInStorage(at: index(of: item)!, with: newItem)
    }

    private func index(of element: WebCore.Element) -> Int? {
        var index = items.count
        while index > 0 {
            index -= 1
            if element.isSameNode(items[index].node) {
                return index
            }
        }
        return nil
    }

    func find(_ element: WebCore.Element) -> HTMLStackItem? {
        guard let index = index(of: element) else {
            return nil
        }
        return items[index]
    }

    func contains(_ element: WebCore.Element) -> Bool { index(of: element) != nil }

    /// The position of the topmost record named `elementName`.
    func indexOfTopmost(_ elementName: WebCore.ElementName) -> Int? {
        var index = words.count
        while index > 0 {
            index -= 1
            if words[index] & Self.elementNameMask == UInt32(elementName.rawValue) {
                return index
            }
        }
        return nil
    }

    func furthestBlockForFormattingElement(_ formattingElement: WebCore.Element) -> HTMLStackItem? {
        var furthestBlock: Int?
        var index = min(items.count, words.count)
        while index > 0 {
            index -= 1
            if formattingElement.isSameNode(items[index].element) {
                guard let furthestBlock else {
                    return nil
                }
                return items[furthestBlock]
            }
            if words[index] & Self.specialNodeBit != 0 {
                furthestBlock = index
            }
        }
        return nil
    }

    /// For an end tag in the in body insertion mode that has no steps of its own
    /// (https://html.spec.whatwg.org/multipage/parsing.html#parsing-main-inbody, "any other end tag"): the position
    /// of the topmost record named `elementName`, which is not Unknown, or nil if a special record is above it.
    func indexOfAnyOtherEndTagTarget(_ elementName: WebCore.ElementName) -> Int? {
        let target = UInt32(elementName.rawValue)
        var index = words.count
        while index > 0 {
            index -= 1
            let word = words[index]
            if word & Self.elementNameMask == target {
                return index
            }
            if word & Self.specialNodeBit != 0 {
                return nil
            }
        }
        return nil  // The root is always on the stack and is special.
    }

    /// The same for an end tag whose name is not a known HTML element name: the position of the topmost HTML element
    /// with the local name `name`, or nil if a special record is above it.
    func indexOfAnyOtherEndTagTarget(localName name: WTF.AtomString) -> Int? {
        var index = min(items.count, words.count)
        while index > 0 {
            index -= 1
            if items[index].matchesHTMLTag(name) {
                return index
            }
            if words[index] & Self.specialNodeBit != 0 {
                return nil
            }
        }
        return nil  // The root is always on the stack and is special.
    }

    /// For li, dd and dt start tags in the in body insertion mode: the position of the topmost record named `first`
    /// or `second`, or nil if a special record other than address, div and p is above it.
    func indexOfTopmostClosedWhenNested(_ first: WebCore.ElementName, _ second: WebCore.ElementName) -> Int? {
        let first = UInt32(first.rawValue)
        let second = UInt32(second.rawValue)
        let address = UInt32(WebCore.ElementName.HTML_address.rawValue)
        let div = UInt32(WebCore.ElementName.HTML_div.rawValue)
        let p = UInt32(WebCore.ElementName.HTML_p.rawValue)
        var index = words.count
        while index > 0 {
            index -= 1
            let word = words[index]
            let name = word & Self.elementNameMask
            if name == first || name == second {
                return index
            }
            if word & Self.specialNodeBit != 0 && name != address && name != div && name != p {
                return nil
            }
        }
        return nil  // The root is always on the stack and is special.
    }

    // MARK: Pushing

    func pushRootNode(_ item: consuming HTMLStackItem) {
        pushRootNodeCommon(item)
    }

    func pushHTMLHtmlElement(_ item: consuming HTMLStackItem) {
        pushRootNodeCommon(item)
    }

    private func pushRootNodeCommon(_ item: consuming HTMLStackItem) {
        root = copy item
        pushCommon(item)
    }

    func pushHTMLHeadElement(_ item: consuming HTMLStackItem) {
        head = item.element
        pushCommon(item)
    }

    func pushHTMLBodyElement(_ item: consuming HTMLStackItem) {
        body = item.element
        pushCommon(item)
    }

    func push(_ item: consuming HTMLStackItem) {
        pushCommon(item)
    }

    private func pushCommon(_ item: consuming HTMLStackItem) {
        if WebCore.dynamicDowncastHTMLTemplateElement(item.node) != nil {
            templateElementCount &+= 1  // Cannot overflow: one per element on the stack.
        }
        stackDepth &+= 1  // Cannot overflow: one per element on the stack.
        appendToStorage(item)
    }

    /// Inserts `item` directly above the record for `itemBelow`.
    func insertAbove(_ item: consuming HTMLStackItem, _ itemBelow: borrowing HTMLStackItem) {
        if itemBelow.isSame(items[topIndex]) {
            push(item)
            return
        }
        guard let below = index(of: itemBelow) else {
            return
        }
        let element = item.element!
        stackDepth &+= 1  // Cannot overflow: one per element on the stack.
        insertIntoStorage(item, at: below + 1)
        element.beginParsingChildren()
    }

    // MARK: Popping

    func pop() {
        popCommon()
    }

    func popHTMLHeadElement() {
        head = nil
        popCommon()
    }

    func popHTMLBodyElement() {
        body = nil
        popCommon()
    }

    private func popCommon() {
        let oldTop = removeLastFromStorage()
        let element = oldTop.element!
        if WebCore.dynamicDowncastHTMLTemplateElement(element) != nil {
            templateElementCount &-= 1  // Cannot overflow: the element was counted when pushed.
        }
        element.finishParsingChildren()
        stackDepth &-= 1  // Cannot overflow: the element was counted when pushed.
    }

    func popAll() {
        root = nil
        head = nil
        body = nil
        stackDepth = 0
        while !items.isEmpty {
            let element = removeLastFromStorage().element
            element?.finishParsingChildren()
        }
    }

    func popUntil(_ elementName: WebCore.ElementName) {
        while topElementName != elementName {
            pop()
        }
    }

    func popUntilPopped(_ elementName: WebCore.ElementName) {
        popUntil(elementName)
        pop()
    }

    func popUntilNumberedHeaderElementPopped() {
        while topWord & Self.numberedHeaderElementBit == 0 {
            pop()
        }
        pop()
    }

    private func topIsSameNode(_ element: WebCore.Element) -> Bool {
        element.isSameNode(items[topIndex].node)
    }

    func popUntil(_ element: WebCore.Element) {
        while !topIsSameNode(element) {
            pop()
        }
    }

    func popUntilPopped(_ element: WebCore.Element) {
        popUntil(element)
        pop()
    }

    /// https://html.spec.whatwg.org/multipage/parsing.html#clear-the-stack-back-to-a-table-context
    func popUntilTableScopeMarker() {
        while topWord & Self.tableScopeMarkerBit == 0 {
            pop()
        }
    }

    /// https://html.spec.whatwg.org/multipage/parsing.html#clear-the-stack-back-to-a-table-body-context
    func popUntilTableBodyScopeMarker() {
        while !items[topIndex].isTableBodyScopeMarker {
            pop()
        }
    }

    /// https://html.spec.whatwg.org/multipage/parsing.html#clear-the-stack-back-to-a-table-row-context
    func popUntilTableRowScopeMarker() {
        while !items[topIndex].isTableRowScopeMarker {
            pop()
        }
    }

    func popUntilForeignContentScopeMarker(encodingName: WebCore.QualifiedName) {
        while !topIsForeignContentScopeMarker(encodingName: encodingName) {
            pop()
        }
    }

    /// Whether the top record is a MathML text integration point, an HTML integration point, or in the HTML
    /// namespace.
    private func topIsForeignContentScopeMarker(encodingName: WebCore.QualifiedName) -> Bool {
        let word = topWord
        if word & (Self.mathMLTextIntegrationPointBit | Self.svgHTMLIntegrationPointBit | Self.htmlNamespaceBit) != 0 {
            return true
        }
        return Self.isMathMLAnnotationXML(word) && annotationXMLIsHTMLIntegrationPoint(topElement, encodingName)
    }

    // MARK: Removing

    func removeHTMLHeadElement(_ element: WebCore.Element) {
        if topIsSameNode(element) {
            popHTMLHeadElement()
            return
        }
        head = nil
        removeNonTopCommon(element)
    }

    func remove(_ element: WebCore.Element) {
        if topIsSameNode(element) {
            pop()
            return
        }
        removeNonTopCommon(element)
    }

    private func removeNonTopCommon(_ element: WebCore.Element) {
        var index = items.count
        while index > 1 {
            index -= 1
            if element.isSameNode(items[index - 1].element) {
                _ = removeFromStorage(at: index - 1)
                stackDepth &-= 1  // Cannot overflow: the element was counted when pushed.
                if WebCore.dynamicDowncastHTMLTemplateElement(element) != nil {
                    templateElementCount &-= 1  // Cannot overflow: the element was counted when pushed.
                }
                // FIXME: Is it OK to call finishParsingChildren() when the children aren't actually finished?
                element.finishParsingChildren()
                return
            }
        }
        // The C++ walks past the bottom record here.
        fatalError("HTMLElementStack.remove: the element is not on the stack")
    }

    // MARK: Scope

    @inline(always)
    private func inScopeCommon(_ targetElement: WebCore.ElementName, _ markerBit: UInt32) -> Bool {
        let target = UInt32(targetElement.rawValue)
        var index = words.count
        while index > 0 {
            index -= 1
            let word = words[index]
            if word & Self.elementNameMask == target {
                return true
            }
            if word & markerBit != 0 {
                return false
            }
        }
        return false  // The root is always on the stack and is a scope marker.
    }

    func inScope(_ targetElement: WebCore.ElementName) -> Bool {
        inScopeCommon(targetElement, Self.scopeMarkerBit)
    }

    func inListItemScope(_ targetElement: WebCore.ElementName) -> Bool {
        inScopeCommon(targetElement, Self.listItemScopeMarkerBit)
    }

    func inTableScope(_ targetElement: WebCore.ElementName) -> Bool {
        inScopeCommon(targetElement, Self.tableScopeMarkerBit)
    }

    func inButtonScope(_ targetElement: WebCore.ElementName) -> Bool {
        inScopeCommon(targetElement, Self.buttonScopeMarkerBit)
    }

    func hasAnyInTableScope(
        _ first: WebCore.ElementName,
        _ second: WebCore.ElementName,
        _ third: WebCore.ElementName? = nil
    ) -> Bool {
        let first = UInt32(first.rawValue)
        let second = UInt32(second.rawValue)
        let third = third.map { UInt32($0.rawValue) }
        var index = words.count
        while index > 0 {
            index -= 1
            let word = words[index]
            let name = word & Self.elementNameMask
            if name == first || name == second || name == third {
                return true
            }
            if word & Self.tableScopeMarkerBit != 0 {
                return false
            }
        }
        return false
    }

    func hasNumberedHeaderElementInScope() -> Bool {
        var index = words.count
        while index > 0 {
            index -= 1
            let word = words[index]
            if word & Self.numberedHeaderElementBit != 0 {
                return true
            }
            if word & Self.scopeMarkerBit != 0 {
                return false
            }
        }
        return false
    }

    func inScope(_ targetElement: WebCore.Element) -> Bool {
        var index = min(items.count, words.count)
        while index > 0 {
            index -= 1
            if targetElement.isSameNode(items[index].node) {
                return true
            }
            if words[index] & Self.scopeMarkerBit != 0 {
                return false
            }
        }
        return false
    }
}

/// The list of active formatting elements
/// (https://html.spec.whatwg.org/multipage/parsing.html#list-of-active-formatting-elements). A nil entry is a marker.
final class HTMLFormattingElementList {
    /// Only `changeEntries` changes `entries`.
    private var entries = UniqueArray<HTMLFormattingItem?>()

    /// A position in the list that the adoption agency algorithm moves and inserts at.
    struct Bookmark {
        fileprivate(set) var index: Int
        private(set) var hasBeenMoved = false

        fileprivate init(index: Int) {
            self.index = index
        }

        /// Moves the bookmark to the entry at `index`, which the new entry goes before.
        mutating func moveToAfter(_ index: Int) {
            hasBeenMoved = true
            self.index = index
        }
    }

    var isEmpty: Bool { entries.isEmpty }
    var count: Int { entries.count }

    func at(_ index: Int) -> HTMLFormattingItem? { entries[index] }

    /// The element of the entry at `index`, or nil for a marker.
    func element(at index: Int) -> WebCore.Element? { entries[index]?.element }

    /// Makes a change to the entries. They are moved out while they change, so that no access to the stored property
    /// is open while the storage allocates or frees memory, and the compiler can check the accesses without run-time
    /// checks. An entry the change takes out is returned, and released after the entries are back.
    @inline(always)
    private func changeEntries<Result>(_ change: (inout UniqueArray<HTMLFormattingItem?>) -> Result) -> Result {
        var entries = UniqueArray<HTMLFormattingItem?>()
        swap(&entries, &self.entries)
        let result = change(&entries)
        swap(&entries, &self.entries)
        return result
    }

    private func replaceEntry(at index: Int, with item: HTMLFormattingItem) -> HTMLFormattingItem? {
        changeEntries { entries in
            var replaced: HTMLFormattingItem? = item
            swap(&entries[index], &replaced)
            return replaced
        }
    }

    private func removeEntry(at index: Int) -> HTMLFormattingItem? {
        changeEntries { $0.remove(at: index) }
    }

    func closestElementInScopeWithName(_ targetElement: WebCore.ElementName) -> WebCore.Element? {
        var index = entries.count
        while index > 0 {
            index -= 1
            guard let item = entries[index] else {
                return nil
            }
            if item.elementName == targetElement {
                return item.element
            }
        }
        return nil
    }

    /// The position of the last entry for `element`.
    func find(_ element: WebCore.Element) -> Int? {
        var index = entries.count
        while index > 0 {
            index -= 1
            if let item = entries[index], element.isSameNode(item.element) {
                return index
            }
        }
        return nil
    }

    func contains(_ element: WebCore.Element) -> Bool { find(element) != nil }

    func append(_ item: HTMLFormattingItem) {
        ensureNoahsArkCondition(item)
        changeEntries { $0.append(item) }
    }

    func remove(_ element: WebCore.Element) {
        if let index = find(element) {
            _ = removeEntry(at: index)
        }
    }

    func removeUpdatingBookmark(_ element: WebCore.Element, _ bookmark: inout Bookmark) {
        guard let index = find(element) else {
            return
        }
        precondition(bookmark.index <= entries.count)
        _ = removeEntry(at: index)
        // Removing an entry before the bookmarked one moves it down.
        if bookmark.index > index {
            bookmark.index -= 1
        }
    }

    func bookmarkFor(_ element: WebCore.Element) -> Bookmark {
        Bookmark(index: find(element)!)
    }

    func replaceElement(at index: Int, with item: HTMLFormattingItem) {
        _ = replaceEntry(at: index, with: item)
    }

    func swapTo(_ oldElement: WebCore.Element, _ newItem: HTMLFormattingItem, _ bookmark: Bookmark) {
        if !bookmark.hasBeenMoved {
            _ = replaceEntry(at: bookmark.index, with: newItem)
            return
        }
        changeEntries { $0.insert(newItem, at: bookmark.index) }
        remove(oldElement)
    }

    func appendMarker() {
        changeEntries { $0.append(nil) }
    }

    /// https://html.spec.whatwg.org/multipage/parsing.html#clear-the-list-of-active-formatting-elements-up-to-the-last-marker
    /// Clears the marker too.
    func clearToLastMarker() {
        while !entries.isEmpty {
            if changeEntries({ $0.removeLast() }) == nil {
                break
            }
        }
    }

    // MARK: Noah's Ark

    /// Biblically, Noah's Ark only had room for two of each animal, but in the Book of Hixie, Noah's Ark of
    /// Formatting Elements can fit three of each element.
    private static let noahsArkCapacity = 3

    private static func itemsHaveMatchingNames(_ a: HTMLFormattingItem, _ b: HTMLFormattingItem) -> Bool {
        if a.elementName != b.elementName {
            return false
        }
        if a.elementName != .Unknown {
            return true
        }
        return a.localName == b.localName && a.namespaceURI == b.namespaceURI
    }

    /// The entries since the last marker whose names and attribute counts match `newItem`'s, latest first, if there
    /// are as many as the ark holds.
    private func noahsArkCandidates(_ newItem: HTMLFormattingItem) -> [HTMLFormattingItem] {
        if entries.count < Self.noahsArkCapacity {
            return []
        }
        let newItemAttributeCount = newItem.attributes.size()
        var candidates: [HTMLFormattingItem] = []
        var index = entries.count
        while index > 0 {
            index -= 1
            guard let candidate = entries[index] else {
                break
            }
            if !Self.itemsHaveMatchingNames(newItem, candidate) {
                continue
            }
            if candidate.attributes.size() != newItemAttributeCount {
                continue
            }
            candidates.append(candidate)
        }
        if candidates.count < Self.noahsArkCapacity {
            return []
        }
        return candidates
    }

    private func ensureNoahsArkCondition(_ newItem: HTMLFormattingItem) {
        var candidates = noahsArkCandidates(newItem)
        if candidates.isEmpty {
            return
        }
        var remainingCandidates: [HTMLFormattingItem] = []
        remainingCandidates.reserveCapacity(candidates.count)
        let attributes: Span<WebCore.Attribute> = newItem.attributes.span()
        for attributeIndex in attributes.indices {
            let attribute = attributes[attributeIndex]
            for candidate in candidates {
                if let value = candidate.findAttributeValue(WebCore.attributeName(attribute)),
                    value == WebCore.attributeValue(attribute)
                {
                    remainingCandidates.append(candidate)
                }
            }
            if remainingCandidates.count < Self.noahsArkCapacity {
                return
            }
            swap(&candidates, &remainingCandidates)
            remainingCandidates.removeAll(keepingCapacity: true)
        }
        // Inductively, this loop should not run many times. It can run more than once because of how the list gets
        // permuted.
        for i in (Self.noahsArkCapacity - 1)..<candidates.count {
            remove(candidates[i].element)
        }
    }
}

#endif
