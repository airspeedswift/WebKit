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

// Every Swift boundary's C++ types, followed by the Swift compatibility header that
// declares the entry points into Swift. Include this from any translation unit that calls
// into Swift; do not include WebCoreSwift-Generated.h directly.
//
// WebCoreSwift-Generated.h is emitted once for the whole module, so every C++ translation
// unit that includes it must be able to see every boundary's types -- the per-boundary
// Clang modules in WebCore_Private.modulemap isolate what Swift may reach, not what C++
// must declare. Leave out CSSCalcSwiftTypes.h and the generated thunk for
// cssCalcSerializeSwift fails with "no member named 'CSSCalcSwiftNode' in namespace
// 'WebCore::CSSCalc'" in a file that has nothing to do with calc().
//
// This header states that module-wide requirement once, so adding a new boundary's headers
// means editing this file rather than every consumer of the generated header. A consumer
// still includes the boundary header it actually uses, next to its other includes, since
// that is an ordinary direct dependency.
//
// This is a Project header in WebCore's Headers build phase, not a Private one.
// WebCore_Private.modulemap's `Core` module is `umbrella "PrivateHeaders"`, so an
// installed copy would be swept into `Core` -- which excludes the headers below precisely
// because each lives in its own `explicit module`, and a `Core` header that included them
// would reach definitions `Core` does not import. Nothing outside WebCore's own sources
// needs this.

#include <wtf/Compiler.h>

// The CSS tokenizer (CSSTokenizerSwift.swift) and the colour fast-path parser
// (CSSParserFastPathsSwift.swift) boundary types, whose named-colour lookup this header
// also declares.
#include "CSSTokenizerSwiftTypes.h"

// The calc() serialization boundary types (CSSCalcSerializationSwift.swift).
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
//
// Suppressing it here is what lets these `@c` enums -- CSSTokenTypeSwift, CSSBlockTypeSwift,
// CSSSwiftColorOutcome -- be declared *once*, in Swift. CSSUnitType is no longer among
// them: it runs the other way now, with C++ declaring it in CSSUnitType.h and Swift
// importing it.
IGNORE_CLANG_WARNINGS_BEGIN("elaborated-enum-base")
#include "WebCoreSwift-Generated.h"
IGNORE_CLANG_WARNINGS_END
