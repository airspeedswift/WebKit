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

// Include this rather than PALSwift-Generated.h. The generated header is emitted once for all of
// PAL's Swift, so every translation unit including it needs the C++ types of every Swift file, which
// are listed here.
//
// A project header, not a private one: pal's `Core` module is `umbrella "."` over the installed
// headers, and would sweep in an installed copy that includes a header that is never installed.
//
// Angle includes, because PAL builds with -fmodules and a quoted include of the same file is a second
// identity for it, which fails with a redefinition error.
#include <pal/crypto/CryptoTypes.h>
#include <pal/text/TextCodecUTF8DecoderTypes.h>
#include <wtf/Compiler.h>
#include <wtf/EscapableByteSpan.h>

// FIXME: Remove once the generated header's `SWIFT_ENUM` stops expanding to the Objective-C
// fixed-enum forward declaration in C++, which -Welaborated-enum-base rejects. JSC_CF_ENUM works
// around the same problem in `CF_ENUM`.
IGNORE_CLANG_WARNINGS_BEGIN("elaborated-enum-base")
#include "PALSwift-Generated.h"
IGNORE_CLANG_WARNINGS_END
