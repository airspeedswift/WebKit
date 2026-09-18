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

// Every PAL Swift boundary's C++ types, followed by the compatibility header that declares the entry
// points into Swift. Include this from a translation unit that calls into Swift and is not itself
// one of the crypto bridges; never include PALSwift-Generated.h directly.
//
// That header is emitted once for the whole module, so a translation unit including it must see
// every boundary's types, not just its own. The crypto bridges each satisfy that by hand, which
// works only while crypto is PAL's sole boundary: including the generated header from a second one
// fails with twenty errors naming types that file never mentions. Stating the requirement here means
// a new boundary adds its types to this file rather than to every consumer.
//
// A project header rather than a private one, and mechanically so: pal's `Core` module is
// `umbrella "."` over the installed header directory, so an installed copy would be swept into that
// module and would then try to include PALSwift-Generated.h, a derived file that is never installed.

#include <wtf/Compiler.h>

// The crypto shims (CryptoKitShim.swift). CryptoTypes.h declares all six PAL::Crypto types the
// generated header names; EscapableByteSpan is how those entries take a buffer.
//
// The angle form, matching how the crypto headers spell it. PAL builds with -fmodules, so
// `<pal/crypto/CryptoTypes.h>` resolves to the `pal` clang module while `"CryptoTypes.h"` is a
// textual include of the same file -- two identities of one header, and a translation unit reaching
// it both ways fails with `redefinition of 'CryptoDigestHashFunction'`.
#include <pal/crypto/CryptoTypes.h>
#include <wtf/EscapableByteSpan.h>

// The UTF-8 decoder (TextCodecUTF8Swift.swift): the span aliases and the result value.
#include <pal/text/TextCodecUTF8SwiftTypes.h>

// FIXME: Remove this suppression once the Swift compatibility header's `SWIFT_ENUM` stops handing
// C++ the Objective-C spelling. It treats C++11 as implying support for the Objective-C fixed-enum
// forward declaration, so in C++ it expands `typedef SWIFT_ENUM(uint8_t, Name, closed) {` to
// `enum Name : uint8_t Name;`, which only Objective-C accepts; -Welaborated-enum-base plus -Werror
// makes it fatal. `CF_ENUM` has the identical bug, and JSC_CF_ENUM already works around it the way
// the generated header should.
//
// Here before PAL needs it, deliberately: the generated header is module-scoped, so the first `@c`
// enum any PAL Swift boundary declares would otherwise break every translation unit including this
// file, none of which has anything to do with that boundary.
IGNORE_CLANG_WARNINGS_BEGIN("elaborated-enum-base")
#include "PALSwift-Generated.h"
IGNORE_CLANG_WARNINGS_END
