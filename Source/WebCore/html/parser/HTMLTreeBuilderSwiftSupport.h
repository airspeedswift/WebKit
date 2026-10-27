/*
 * Copyright (C) 2026 Apple Inc. All rights reserved.
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

#if !defined(USE_SWIFT_HTML_TREE_BUILDER)
#define USE_SWIFT_HTML_TREE_BUILDER 0
#endif

#if USE_SWIFT_HTML_TREE_BUILDER

#include "Attribute.h"
#include "CustomElementRegistry.h"
#include "Document.h"
#include "ElementInlines.h"
#include "FormAssociatedElement.h"
#include "HTMLElement.h"
#include "HTMLFormElement.h"
#include "HTMLImageElement.h"
#include "HTMLNames.h"
#include "HTMLPictureElement.h"
#include "HTMLTemplateElement.h"
#include "NodeName.h"
#include "ShadowRoot.h"
#include "ShadowRootMode.h"
#include "SlotAssignmentMode.h"
#include "TagName.h"
#include "Text.h"
#include "TreeScopeInlines.h"

// What HTMLTreeBuilder.swift needs from C++ that it cannot spell itself: casts, the names it compares and makes
// attributes with (HTMLNames and the other name tables are not visible to Swift), and HTMLConstructionSite.cpp's
// break iterator for splitting long text.

namespace WebCore {

using AttributeVector = Vector<Attribute>;

// The index at or before proposedBreakIndex at which a text node can end without splitting a grapheme cluster.
unsigned findBreakIndex(const String&, unsigned currentPosition, unsigned proposedBreakIndex);
// The frame's document start user scripts, for the document element.
void injectDocumentStartUserScripts(Document&);

inline HTMLTemplateElement* dynamicDowncastHTMLTemplateElement(Node* node) { return dynamicDowncast<HTMLTemplateElement>(node); }
inline Text* dynamicDowncastText(Node* node) { return dynamicDowncast<Text>(node); }
inline HTMLFormElement* dynamicDowncastHTMLFormElement(Node* node) { return dynamicDowncast<HTMLFormElement>(node); }
inline HTMLPictureElement* dynamicDowncastHTMLPictureElement(Node* node) { return dynamicDowncast<HTMLPictureElement>(node); }
inline HTMLImageElement* dynamicDowncastHTMLImageElement(Node* node) { return dynamicDowncast<HTMLImageElement>(node); }
inline Document* dynamicDowncastDocument(Node* node) { return dynamicDowncast<Document>(node); }
inline Element* dynamicDowncastElement(Node* node) { return dynamicDowncast<Element>(node); }
inline void setFormSetByParser(HTMLElement& element, HTMLFormElement* form)
{
    if (auto* formAssociated = element.asFormAssociatedElement())
        formAssociated->setFormSetByParser(form);
}
inline QualifiedName qualifiedNameForElementName(ElementName name) { return qualifiedNameForNodeName(name); }
inline AtomString elementLocalName(const Element& element) { return element.localName(); }
inline AtomString elementNamespaceURI(const Element& element) { return element.namespaceURI(); }
inline AtomString elementAttributeWithoutSynchronization(const Element& element, const QualifiedName& name) { return element.attributeWithoutSynchronization(name); }
inline QualifiedName attributeName(const Attribute& attribute) { return attribute.name(); }
inline AtomString attributeLocalName(const Attribute& attribute) { return attribute.localName(); }
inline void parserSetAttributeName(AttributeVector& attributes, size_t index, const QualifiedName& name) { attributes[index].parserSetName(name); }
inline AtomString attributeValue(const Attribute& attribute) { return attribute.value(); }
// Element::parserSetAttributes with the vector's span made in C++: an empty vector's span has no data pointer, which
// Swift cannot pass back to C++.
inline void parserSetAttributes(Element& element, const AttributeVector& attributes) { element.parserSetAttributes(attributes.span()); }
inline void appendAttribute(AttributeVector& attributes, const QualifiedName& name, const AtomString& value) { attributes.append(Attribute(name, value)); }
inline AtomString tagNameString(TagName tagName) { return tagNameAsString(tagName); }
inline bool elementHasNonce(const Element& element) { return element.hasAttributeWithoutSynchronization(HTMLNames::nonceAttr) || !element.nonce().isEmpty(); }

// The root of the tree scope an element made for the current node goes in: its template content's for a template.
inline ContainerNode& treeScopeRootForInsertion(ContainerNode& currentNode)
{
    if (RefPtr templateElement = dynamicDowncast<HTMLTemplateElement>(currentNode))
        return templateElement->fragmentForInsertion().treeScope().rootNode();
    return currentNode.treeScope().rootNode();
}
inline CustomElementRegistry* customElementRegistryForInsertion(ContainerNode& currentNode, ContainerNode& treeScopeRoot)
{
    if (auto* templateElement = dynamicDowncast<HTMLTemplateElement>(currentNode)) {
        Ref templateFragmentTreeScope = templateElement->fragmentForInsertion().treeScope();
        if (templateFragmentTreeScope->rootNode().usesNullCustomElementRegistry())
            return nullptr;
    }
    return CustomElementRegistry::registryForNodeOrTreeScope(currentNode, treeScopeRoot.treeScope());
}
inline bool isScopedRegistryOutsideTreeScope(CustomElementRegistry& registry, ContainerNode& treeScopeRoot)
{
    return registry.isScoped() && &registry != treeScopeRoot.treeScope().customElementRegistry();
}

// UserAgent for no mode.
inline ShadowRootMode parseShadowRootModeAttribute(const AtomString& value) { return parseShadowRootMode(value).value_or(ShadowRootMode::UserAgent); }
inline SlotAssignmentMode parseSlotAssignmentModeAttribute(const AtomString& value) { return parseSlotAssignmentMode(value); }

inline QualifiedName htmlNonceAttr() { return HTMLNames::nonceAttr; }
inline QualifiedName htmlCustomelementregistryAttr() { return HTMLNames::customelementregistryAttr; }

} // namespace WebCore

#endif // USE_SWIFT_HTML_TREE_BUILDER
