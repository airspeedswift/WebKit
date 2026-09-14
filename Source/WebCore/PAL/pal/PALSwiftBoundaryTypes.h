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

// Every Swift boundary's C++ types, followed by the Swift compatibility header that declares
// the entry points into Swift. Include this from a translation unit that calls into Swift and
// is not itself one of the crypto bridges; do not include PALSwift-Generated.h directly.
//
// PALSwift-Generated.h is emitted once for the whole module, so a translation unit that
// includes it must be able to see EVERY boundary's types, not just its own. The crypto bridges
// predate this header and each satisfies that requirement by hand -- their own bridging header
// plus <wtf/EscapableByteSpan.h> happens to cover the module -- which works only because
// crypto was for a long time the only boundary here. It stopped being true the moment a second
// one arrived: including the generated header from pal/text failed with twenty errors naming
// WTF::EscapableByteSpan and PAL::Crypto, in a file that mentions neither.
//
// This header states the module-wide requirement once, so adding a third boundary means
// editing this file rather than every consumer.
//
// A PROJECT HEADER, not a Private one, and unlike its WebCore counterpart the reason is
// mechanical rather than a matter of taste: pal's `Core` module is `umbrella "."` over the
// INSTALLED header directory, so an installed copy would be swept into that module and would
// then try to include PALSwift-Generated.h, which is a derived file and is never installed.

#include <wtf/Compiler.h>

// The crypto shims (CryptoKitShim.swift). CryptoTypes.h is the one header that declares all
// six PAL::Crypto types the generated header names; EscapableByteSpan is how those entries
// take a buffer.
//
// The ANGLE form, matching how the crypto headers themselves spell it. PAL builds with
// -fmodules, so `<pal/crypto/CryptoTypes.h>` resolves to the `pal` clang module while
// `"CryptoTypes.h"` is a textual include of the same file -- two identities of one header, and
// a translation unit that reaches it both ways fails with `redefinition of
// 'CryptoDigestHashFunction'` on a file whose only guard is `#pragma once`.
#include <pal/crypto/CryptoTypes.h>
#include <wtf/EscapableByteSpan.h>

// The UTF-8 decoder (TextCodecUTF8Swift.swift): the input alias, the result value and the
// sink the decoded characters are handed to.
#include <pal/text/TextCodecUTF8SwiftTypes.h>

// FIXME: Remove this suppression once the Swift compatibility header's `SWIFT_ENUM` stops
// handing C++ the Objective-C spelling. It treats C++11 as implying support for the
// Objective-C fixed-enum forward declaration, so the C++ arm expands
// `typedef SWIFT_ENUM(uint8_t, Name, closed) {` to `enum Name : uint8_t Name;` -- a
// non-defining declaration of an enumeration with a fixed underlying type, which only
// Objective-C accepts. Clang warns -Welaborated-enum-base and -Werror makes it fatal.
// `CF_ENUM` has the identical bug, and JSC_CF_ENUM (JavaScriptCore's API/JSBase.h) already
// works around it the way the generated header should: branch on `__cplusplus` and emit the
// plain `enum X : T { ... }`. Filed as toolchain filings §26.
//
// PRESENT BEFORE IT IS NEEDED, deliberately. PAL has no Swift-declared `@c` enum today --
// `typedef SWIFT_ENUM` appears zero times in PALSwift-Generated.h, checked -- so nothing here
// warns yet. It is here because the failure mode does not surface where the enum is written:
// the generated header is module-scoped, so the first `@c` enum any PAL island declares breaks
// every translation unit that includes this file, none of which has anything to do with that
// island. That is the same shape as the four failures this header already exists to prevent,
// and it matches `WebCoreSwiftBoundaryTypes.h`, which needs the suppression today.
IGNORE_CLANG_WARNINGS_BEGIN("elaborated-enum-base")
#include "PALSwift-Generated.h"
IGNORE_CLANG_WARNINGS_END
