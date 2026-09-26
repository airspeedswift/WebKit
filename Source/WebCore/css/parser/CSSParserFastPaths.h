// Copyright 2014 The Chromium Authors. All rights reserved.
// Copyright (C) 2016-2020 Apple Inc. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are
// met:
//
//    * Redistributions of source code must retain the above copyright
// notice, this list of conditions and the following disclaimer.
//    * Redistributions in binary form must reproduce the above
// copyright notice, this list of conditions and the following disclaimer
// in the documentation and/or other materials provided with the
// distribution.
//    * Neither the name of Google Inc. nor the names of its
// contributors may be used to endorse or promote products derived from
// this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
// "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
// LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
// A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
// OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
// SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
// LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
// DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
// THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

#pragma once

#include <WebCore/CSSValueKeywords.h>
#include <WebCore/ColorTypes.h>
#include <cstddef>
#include <optional>
#include <wtf/Forward.h>

namespace WebCore {

namespace CSS {
struct PropertyParserState;
struct Range;
}

class CSSValue;
struct CSSParserContext;
enum CSSPropertyID : uint16_t;

class CSSParserFastPaths {
public:
    // Parses simple values like '10px' or 'green', but makes no guarantees about handling any property completely.
    static RefPtr<CSSValue> maybeParseValue(CSSPropertyID, StringView, CSS::PropertyParserState&);

    // Test instrumentation: while enabled, counts the maybeParseValue calls that return a value, so a
    // layout test can tell a fast-path parse from the full parser's identical answer. Reset by
    // Internals::resetToConsistentState.
    static WEBCORE_EXPORT void setHitCountingEnabledForTesting(bool);
    static WEBCORE_EXPORT uint64_t hitCountForTesting();

    // Returns the allowed numeric value range for a length value if the property supports a single length value.
    // FIXME: This should be generated from CSSProperties.json
    static std::optional<CSS::Range> NODELETE lengthValueRangeForPropertiesSupportingSimpleLengths(CSSPropertyID);

    // Parses numeric and named colors.
    static WEBCORE_EXPORT std::optional<SRGBA<uint8_t>> parseSimpleColor(StringView, const CSSParserContext&);
    static std::optional<SRGBA<uint8_t>> NODELETE parseHexColor(StringView); // Hex colors of length 3, 4, 6, or 8, without leading "#".
    static std::optional<SRGBA<uint8_t>> parseNamedColor(StringView);
};

// The longest CSS named color is `lightgoldenrodyellow`, at 20 characters. The generated
// ColorData.cpp holds the same bound as gperf's `MAX_WORD_LENGTH`, which no header exports.
static constexpr size_t maximumColorNameLength = 20;

// With USE(SWIFT_CSS) the color and transform fast paths are CSSParserFastPathsSwift.swift's, and
// the C++ implementations are not compiled.
#if USE(SWIFT_CSS)
#define CSS_CPP_COLOR_FAST_PATHS_COMPILED_IN 0
#else
#define CSS_CPP_COLOR_FAST_PATHS_COMPILED_IN 1
#endif

#define CSS_CPP_TRANSFORM_FAST_PATH_COMPILED_IN CSS_CPP_COLOR_FAST_PATHS_COMPILED_IN


} // namespace WebCore
