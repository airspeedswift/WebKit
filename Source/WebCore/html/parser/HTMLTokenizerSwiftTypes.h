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

// Everything the Swift HTML tokenizer island (HTMLTokenizerSwift.swift) is allowed to
// see of WebCore, which is one span alias — the island takes characters and returns a
// token, and everything else about the boundary lives on the C++ side in
// HTMLTokenizerSwiftBridge.cpp.
//
// It is its own Clang module for the reason CSSTokenizerSwiftTypes.h is; see the
// comment there.

#pragma once

#include <span>
#include <wtf/text/Latin1Character.h>

namespace WebCore {

// Named alias for the span type SegmentedString::currentSubstringSpan8() returns, so
// Swift can refer to it at an interop boundary (Swift cannot spell std::span<const T>
// directly). Same pattern as WebGPU's CxxBridgingPublic.h SpanConstUInt8 and
// PAL::Crypto::SpanConstUInt8.
using SegmentedStringSpan8 = std::span<const Latin1Character>;

} // namespace WebCore
