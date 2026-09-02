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

// EVERY Swift island's C++ boundary types, followed by the Swift compatibility header that
// declares the islands' entry points. Include this from any translation unit that calls into a
// Swift island; do not include WebCoreSwift-Generated.h directly.
//
// WHY IT HAS TO BE ALL OF THEM. WebCoreSwift-Generated.h is emitted once for the whole module, so
// every C++ translation unit that includes it must be able to see *every* island's boundary types
// -- the per-island Clang modules in WebCore_Private.modulemap isolate what SWIFT may reach, not
// what C++ must declare. Leave out CSSCalcSwiftTypes.h and the generated thunk for
// cssCalcSerializeSwift fails with "no member named 'CSSCalcSwiftNode' in namespace
// 'WebCore::CSSCalc'" in a file that has nothing to do with calc().
//
// WHY IT IS ONE HEADER. That requirement is module-wide, so it should be stated once. Before this
// header each consumer repeated the whole list, half of it under a comment saying "not used by
// this file", and adding island N meant editing the N-1 consumers that do not use it -- an edit
// that only grows, and whose omission fails in an unrelated file with a message naming neither
// the new island nor the missing include. Adding an island now edits this file.
//
// A consumer still includes the boundary header of the island it actually USES, next to its other
// includes: that is an ordinary direct dependency and should read as one. What this header
// supplies is the rest of the module's islands, which the consumer needs only because the
// generated header is module-scoped.
//
// DELIBERATELY NOT INSTALLED. This is a Project header in WebCore's Headers build phase, not a
// Private one. WebCore_Private.modulemap's `Core` module is `umbrella "PrivateHeaders"`, so an
// installed copy would be swept into `Core` -- which excludes the island headers below precisely
// because each lives in its own `explicit module`, and a `Core` header that included them would
// reach definitions `Core` does not import. Nothing outside WebCore's own sources needs this.

#include <wtf/Compiler.h>

// The CSS tokenizer island (CSSTokenizerSwift.swift) and the colour fast-path island
// (CSSParserFastPathsSwift.swift), whose named-colour lookup this header also declares.
#include "CSSTokenizerSwiftTypes.h"

// The calc() serialization island (CSSCalcSerializationSwift.swift).
#include "CSSCalcSwiftTypes.h"

// FIXME: Remove this suppression once the Swift compatibility header's `SWIFT_ENUM` stops
// handing C++ the Objective-C spelling. It treats C++11 as implying support for the
// Objective-C fixed-enum forward declaration, so the C++ arm expands
// `typedef SWIFT_ENUM(uint8_t, CSSTokenTypeSwift, closed) {` to
// `enum CSSTokenTypeSwift : uint8_t CSSTokenTypeSwift;` -- a non-defining declaration of an
// enumeration with a fixed underlying type, which only Objective-C accepts. Clang warns
// -Welaborated-enum-base and WebCore's -Werror makes it fatal. `CF_ENUM` has the identical
// bug, and JSC_CF_ENUM (JavaScriptCore's API/JSBase.h) already works around it the way the
// generated header should: branch on `__cplusplus` and emit the plain `enum X : T { ... }`.
// Recorded as a to-file item, filings register §26.
//
// Suppressing it here is what lets each island's `@c` enums -- CSSTokenTypeSwift,
// CSSBlockTypeSwift, CSSSwiftColorOutcome -- be declared *once*, in Swift. CSSUnitType is no
// longer among them: it runs the other way now, C++ declaring it in CSSUnitType.h and the
// island importing it, which is what let its 70-case mirror and 73 static_asserts go.
IGNORE_CLANG_WARNINGS_BEGIN("elaborated-enum-base")
#include "WebCoreSwift-Generated.h"
IGNORE_CLANG_WARNINGS_END
