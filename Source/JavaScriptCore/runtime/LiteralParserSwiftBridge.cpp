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

// FIXME: Remove this suppression once the Swift compatibility header's `SWIFT_ENUM` stops
// handing C++ the Objective-C spelling. It selects with
//
//     #if (defined(__cplusplus) && __cplusplus >= 201103L) || ... || __has_feature(objc_fixed_enum)
//
// treating C++11 as implying support for the Objective-C fixed-enum forward declaration, so the
// C++ arm expands `typedef SWIFT_ENUM(uint8_t, JSONTokenType, closed) {` to
// `typedef enum JSONTokenType : uint8_t JSONTokenType;` — an elaborated-enum-specifier with a
// fixed base in a non-defining position, which only Objective-C accepts. Clang takes it as an
// extension and warns; -Werror makes it fatal. `CF_ENUM` has the identical bug, and this
// framework already works around it the way the generated header should: JSC_CF_ENUM
// (API/JSBase.h) branches on `__cplusplus` and emits the plain `enum X : T { ... }`.
// Also see Sanitizers.xcconfig, which carries -Wno-elaborated-enum-base for the static
// analyzer against <rdar://121475724>. Recorded as a to-file item, filings register §26.
//
// Suppressing it here is what lets the token numbering be declared *once*, in Swift, rather
// than hand-transcribed into a C++ enum in the boundary header for the asserts below to name.
IGNORE_CLANG_WARNINGS_BEGIN("elaborated-enum-base")
#include "JavaScriptCore-Swift.h"
IGNORE_CLANG_WARNINGS_END

// For `TokenType`, which the asserts below tie to the island's numbering.
#include "LiteralParser.h"

namespace JSC {

// The island reports token types as its own Swift `JSONTokenType`, and this is where the two
// numberings are checked against each other. `literalValue` switches a raw value that came out
// of Swift straight onto `TokTrue`/`TokFalse`/`TokNull`, so they have to agree.
//
// The Swift enum is `@c` (SE-0495), so it is emitted into JavaScriptCore-Swift.h above and
// these assert against *it* rather than against a hand-transcribed copy -- which is what
// `JSONSwiftTokenType` in the boundary header used to be, 34 lines of it. The asserts have to
// live here because this is the only file that can see the generated header: the framework
// target compiles it, while `LiteralParser.cpp` is compiled into libJavaScriptCore, which
// cannot. They are inside the `JSC_SUPPORTS_SWIFT` guard for the same reason -- with Swift off
// there is no generated header, and no island whose numbering could drift.
//
// The two island-only cases (NeedsSlowString, NeedsDoubleParse) have no `TokenType`
// counterpart by design and so are not asserted.
static_assert(static_cast<uint8_t>(TokLBracket) == JSONTokenTypeLbracket);
static_assert(static_cast<uint8_t>(TokRBracket) == JSONTokenTypeRbracket);
static_assert(static_cast<uint8_t>(TokLBrace) == JSONTokenTypeLbrace);
static_assert(static_cast<uint8_t>(TokRBrace) == JSONTokenTypeRbrace);
static_assert(static_cast<uint8_t>(TokString) == JSONTokenTypeString);
static_assert(static_cast<uint8_t>(TokIdentifier) == JSONTokenTypeIdentifier);
static_assert(static_cast<uint8_t>(TokNumber) == JSONTokenTypeNumber);
static_assert(static_cast<uint8_t>(TokNumberInt32) == JSONTokenTypeNumberInt32);
static_assert(static_cast<uint8_t>(TokColon) == JSONTokenTypeColon);
static_assert(static_cast<uint8_t>(TokLParen) == JSONTokenTypeLparen);
static_assert(static_cast<uint8_t>(TokRParen) == JSONTokenTypeRparen);
static_assert(static_cast<uint8_t>(TokComma) == JSONTokenTypeComma);
static_assert(static_cast<uint8_t>(TokTrue) == JSONTokenTypeTrue);
static_assert(static_cast<uint8_t>(TokFalse) == JSONTokenTypeFalse);
static_assert(static_cast<uint8_t>(TokNull) == JSONTokenTypeNull);
static_assert(static_cast<uint8_t>(TokEnd) == JSONTokenTypeEnd);
static_assert(static_cast<uint8_t>(TokDot) == JSONTokenTypeDot);
static_assert(static_cast<uint8_t>(TokAssign) == JSONTokenTypeAssign);
static_assert(static_cast<uint8_t>(TokSemi) == JSONTokenTypeSemi);
static_assert(static_cast<uint8_t>(TokError) == JSONTokenTypeError);
static_assert(static_cast<uint8_t>(TokErrorSpace) == JSONTokenTypeErrorSpace);

// The `noescape` annotations are repeated on the definitions: an unannotated definition is a
// different declaration to Clang, and the mismatch is not always diagnosed (interop notes §67).
uint8_t jsonSwiftParseDocument16(std::span<const char16_t> input JSC_SWIFT_NOESCAPE, JSONSwiftObjectModel& model)
{
    return JavaScriptCore::jsonParseDocument16(input, &model);
}

uint8_t jsonSwiftParseDocument8(std::span<const uint8_t> input JSC_SWIFT_NOESCAPE, JSONSwiftObjectModel& model)
{
    return JavaScriptCore::jsonParseDocument8(input, &model);
}

} // namespace JSC

#endif // JSC_SUPPORTS_SWIFT
