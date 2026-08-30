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
    // Which scanner runs the hex and named colour fast paths. Both are compiled in; this
    // chooses which one the entry points below use, at compile time. Explicit rather than
    // implicit in the build configuration so that CSSTokenizerSwiftBridge.cpp's test bridge can
    // select either scanner directly, regardless of the default.
    enum class ColorScanner : bool { Cpp, Swift };

    // `defined() &&` rather than the `#if !defined / #define 0` prologue CSSTokenizer.h:51 uses,
    // which WebCore builds with -Werror,-Wundef would otherwise require: the flag is only ever
    // defined as 1, by WK_USE_SWIFT_CSS_COLOR_FAST_PATHS=YES.
    static constexpr ColorScanner defaultColorScanner =
#if defined(USE_SWIFT_CSS_COLOR_FAST_PATHS) && USE_SWIFT_CSS_COLOR_FAST_PATHS
        ColorScanner::Swift;
#else
        ColorScanner::Cpp;
#endif

    // Parses simple values like '10px' or 'green', but makes no guarantees about handling any property completely.
    static RefPtr<CSSValue> maybeParseValue(CSSPropertyID, StringView, CSS::PropertyParserState&);

    // Returns the allowed numeric value range for a length value if the property supports a single length value.
    // FIXME: This should be generated from CSSProperties.json
    static std::optional<CSS::Range> NODELETE lengthValueRangeForPropertiesSupportingSimpleLengths(CSSPropertyID);

    // Parses numeric and named colors.
    static WEBCORE_EXPORT std::optional<SRGBA<uint8_t>> parseSimpleColor(StringView, const CSSParserContext&, ColorScanner = defaultColorScanner);
    static std::optional<SRGBA<uint8_t>> NODELETE parseHexColor(StringView, ColorScanner = defaultColorScanner); // Hex colors of length 3, 4, 6, or 8, without leading "#".
    static std::optional<SRGBA<uint8_t>> parseNamedColor(StringView, ColorScanner = defaultColorScanner);
};

#if ENABLE(CSS_TOKENIZER_SWIFT_BRIDGE)
// Test-only, reached from CSSTokenizerSwiftBridge.cpp. The counter lives beside the scan it
// instruments rather than in the bridge: a declined scan's C++ fallback produces the same
// output as an outright rejection, so the count has to come from the code that declined.
void webCoreCSSColorFastPathSetForceDecline(bool);
unsigned webCoreCSSColorFastPathDeclineCount();
#endif

} // namespace WebCore
