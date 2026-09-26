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

// Every Swift boundary's C++ types, followed by the Swift compatibility header. Include this from
// any translation unit that calls into Swift, rather than WebCoreSwift-Generated.h directly.
//
// WebCoreSwift-Generated.h is emitted once for the whole module, so a translation unit including
// it must see every boundary's types. Leave out CSSCalcSwiftTypes.h and the thunk for
// cssCalcSerializeSwift fails with "no member named 'CSSCalcSwiftSink' in namespace
// 'WebCore::CSSCalc'" in a file unrelated to calc(). A new boundary's headers are added here.
//
// A Project header, not a Private one: WebCore_Private.modulemap's `Core` module is
// `umbrella "PrivateHeaders"`, so an installed copy would be swept into `Core`, which excludes
// the boundary headers below because each has its own `explicit module`.

#include "CSSCalcSwiftTypes.h"
#include "CSSTokenizerSwiftTypes.h"
#include <wtf/Compiler.h>

// FIXME: Remove this suppression once the Swift compatibility header's `SWIFT_ENUM` stops
// handing C++ the Objective-C spelling. Under C++ it expands
// `typedef SWIFT_ENUM(uint8_t, CSSCalcSwiftOutcome, closed) {` to
// `enum CSSCalcSwiftOutcome : uint8_t CSSCalcSwiftOutcome;`, which only Objective-C accepts, and
// -Welaborated-enum-base is fatal under -Werror. JSC_CF_ENUM (JavaScriptCore's API/JSBase.h)
// shows the fix: branch on `__cplusplus` and emit the plain `enum X : T { ... }`.
IGNORE_CLANG_WARNINGS_BEGIN("elaborated-enum-base")
#include "WebCoreSwift-Generated.h"
IGNORE_CLANG_WARNINGS_END
