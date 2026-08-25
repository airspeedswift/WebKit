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

// The only file that includes the generated Swift header for the JSON parser
// island. See LiteralParserSwiftTypes.h for why the indirection exists: the
// island is compiled by the `JavaScriptCore` framework target, but its C++
// consumer is compiled into `libJavaScriptCore`, which cannot see that target's
// generated header. This file is compiled by the framework target, so it can.

#include "config.h"
#include "LiteralParserSwiftTypes.h"

#if defined(JSC_SUPPORTS_SWIFT) && JSC_SUPPORTS_SWIFT

#include "JavaScriptCore-Swift.h"

namespace JSC {

uint8_t jsonSwiftParseDocument16(std::span<const char16_t> input, JSONSwiftObjectModel& model)
{
    return JavaScriptCore::jsonParseDocument16(input, &model);
}

} // namespace JSC

#endif // JSC_SUPPORTS_SWIFT
