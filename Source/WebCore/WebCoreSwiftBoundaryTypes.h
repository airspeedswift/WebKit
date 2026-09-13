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
// must declare. Leaving out a boundary's header fails the generated thunk for that
// boundary's entry points in whichever unrelated file happens to include this one first.
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

// The media codec-configuration parsers (CodecParsersSwift.swift): the crossing value, and
// the records the Swift arm constructs and returns directly.
#include "platform/graphics/CodecParsersSwiftTypes.h"

#include "WebCoreSwift-Generated.h"
