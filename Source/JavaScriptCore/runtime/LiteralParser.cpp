/*
 * Copyright (C) 2009-2024 Apple Inc. All rights reserved.
 * Copyright (C) 2012 Mathias Bynens (mathias@qiwi.be)
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
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE. 
 */

#include "config.h"
#include "LiteralParser.h"

#include "CodeBlock.h"
#include "JSArray.h"
#include "JSCInlines.h"
#include "JSONAtomStringCacheInlines.h"
#include "Lexer.h"
#include "MarkedVector.h"
#include "ObjectConstructor.h"
#include <wtf/ASCIICType.h>
#include <wtf/ForbidHeapAllocation.h>
#include <wtf/Range.h>
#include <wtf/text/FastCharacterComparison.h>
#include <wtf/text/MakeString.h>

#include "KeywordLookup.h"

// The island's boundary types. Included here rather than in LiteralParser.h because
// nothing in that header names one: the facade and its state are defined in this file, and
// so are the calls to the two Swift entry points this header declares. Nothing above this
// point in the file knows the island exists.
#if JSC_SUPPORTS_SWIFT
#include "LiteralParserSwiftTypes.h"
#endif

WTF_ALLOW_UNSAFE_BUFFER_USAGE_BEGIN

namespace JSC {

template<typename CharType, JSONReviverMode reviverMode>
inline const CharType* LiteralParser<CharType, reviverMode>::Lexer::currentTokenStart() const
{
    if constexpr (reviverMode == JSONReviverMode::Enabled)
        return m_currentTokenStart;
    return nullptr;
}

template<typename CharType, JSONReviverMode reviverMode>
inline const CharType* LiteralParser<CharType, reviverMode>::Lexer::currentTokenEnd() const
{
    if constexpr (reviverMode == JSONReviverMode::Enabled)
        return m_currentTokenEnd;
    return nullptr;
}

template<typename CharType, JSONReviverMode reviverMode>
bool LiteralParser<CharType, reviverMode>::tryJSONPParse(Vector<JSONPData>& results, bool needsFullSourceInfo)
    requires (reviverMode == JSONReviverMode::Disabled)
{
    ASSERT(m_mode == JSONP);
    VM& vm = m_globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    if (m_lexer.next() != TokIdentifier)
        return false;
    do {
        Vector<JSONPPathEntry> path;
        // Unguarded next to start off the lexer
        Identifier name = Identifier::fromString(vm, m_lexer.currentToken()->identifier());
        JSONPPathEntry entry;
        if (name == vm.propertyNames->varKeyword) {
            if (m_lexer.next() != TokIdentifier)
                return false;
            entry.m_type = JSONPPathEntryTypeDeclareVar;
            entry.m_pathEntryName = Identifier::fromString(vm, m_lexer.currentToken()->identifier());
            path.append(entry);
        } else {
            entry.m_type = JSONPPathEntryTypeDot;
            entry.m_pathEntryName = Identifier::fromString(vm, m_lexer.currentToken()->identifier());
            path.append(entry);
        }
        if (isLexerKeyword(entry.m_pathEntryName))
            return false;
        TokenType tokenType = m_lexer.next();
        if (entry.m_type == JSONPPathEntryTypeDeclareVar && tokenType != TokAssign)
            return false;
        while (tokenType != TokAssign) {
            switch (tokenType) {
            case TokLBracket: {
                entry.m_type = JSONPPathEntryTypeLookup;
                TokenType numberType = m_lexer.next();
                if (numberType != TokNumber && numberType != TokNumberInt32)
                    return false;
                auto token = m_lexer.currentToken();
                int index;
                if (token->type == TokNumberInt32)
                    index = token->int32Token;
                else {
                    double doubleIndex = token->numberToken;
                    index = truncateDoubleToInt32(doubleIndex);
                    if (index != doubleIndex)
                        return false;
                }
                if (index < 0)
                    return false;
                entry.m_pathIndex = index;
                if (m_lexer.next() != TokRBracket)
                    return false;
                break;
            }
            case TokDot: {
                entry.m_type = JSONPPathEntryTypeDot;
                if (m_lexer.next() != TokIdentifier)
                    return false;
                entry.m_pathEntryName = Identifier::fromString(vm, m_lexer.currentToken()->identifier());
                break;
            }
            case TokLParen: {
                if (path.last().m_type != JSONPPathEntryTypeDot || needsFullSourceInfo)
                    return false;
                path.last().m_type = JSONPPathEntryTypeCall;
                entry = path.last();
                goto startJSON;
            }
            default:
                return false;
            }
            path.append(entry);
            tokenType = m_lexer.next();
        }
    startJSON:
        m_lexer.next();
        results.append(JSONPData());
        JSValue startParseExpressionValue = parse(vm, StartParseExpression, nullptr);
        RETURN_IF_EXCEPTION(scope, false);
        results.last().m_value.set(vm, startParseExpressionValue);
        if (!results.last().m_value)
            return false;
        results.last().m_path.swap(path);
        if (entry.m_type == JSONPPathEntryTypeCall) {
            if (m_lexer.currentToken()->type != TokRParen)
                return false;
            m_lexer.next();
        }
        if (m_lexer.currentToken()->type != TokSemi)
            break;
        m_lexer.next();
    } while (m_lexer.currentToken()->type == TokIdentifier);
    return m_lexer.currentToken()->type == TokEnd;
}

template<typename CharType, JSONReviverMode reviverMode>
ALWAYS_INLINE bool LiteralParser<CharType, reviverMode>::equalIdentifier(UniquedStringImpl* rep, typename Lexer::LiteralParserTokenPtr token)
{
    // In the literal parser, we don't want to follow property addition transitions if the property name is a symbol.
    if (rep->isSymbol())
        return false;
    if (token->type == TokIdentifier)
        return WTF::equal(rep, token->identifier());
    ASSERT(token->type == TokString);
    if (token->stringIs8Bit)
        return WTF::equal(rep, token->string8());
    return WTF::equal(rep, token->string16());
}

template<typename CharType, JSONReviverMode reviverMode>
ALWAYS_INLINE AtomStringImpl* LiteralParser<CharType, reviverMode>::existingIdentifier(VM& vm, typename Lexer::LiteralParserTokenPtr token)
{
    if (token->type == TokIdentifier)
        return vm.jsonAtomStringCache.existingIdentifier(token->identifier());
    ASSERT(token->type == TokString);
    if (token->stringIs8Bit)
        return vm.jsonAtomStringCache.existingIdentifier(token->string8());
    return vm.jsonAtomStringCache.existingIdentifier(token->string16());
}

template<typename CharType, JSONReviverMode reviverMode>
ALWAYS_INLINE Identifier LiteralParser<CharType, reviverMode>::makeIdentifier(VM& vm, typename Lexer::LiteralParserTokenPtr token)
{
    if (token->type == TokIdentifier)
        return Identifier::fromString(vm, vm.jsonAtomStringCache.makeIdentifier(token->identifier()));
    ASSERT(token->type == TokString);
    if (token->stringIs8Bit)
        return Identifier::fromString(vm, vm.jsonAtomStringCache.makeIdentifier(token->string8()));
    return Identifier::fromString(vm, vm.jsonAtomStringCache.makeIdentifier(token->string16()));
}

template<typename CharType, JSONReviverMode reviverMode>
ALWAYS_INLINE JSString* LiteralParser<CharType, reviverMode>::makeJSString(VM& vm, typename Lexer::LiteralParserTokenPtr token)
{
    if (token->stringIs8Bit)
        return vm.jsonAtomStringCache.makeJSString(token->string8());
    return vm.jsonAtomStringCache.makeJSString(token->string16());
}

[[maybe_unused]] static ALWAYS_INLINE bool NODELETE cannotBeIdentPartOrEscapeStart(Latin1Character)
{
    RELEASE_ASSERT_NOT_REACHED();
}

[[maybe_unused]] static ALWAYS_INLINE bool NODELETE cannotBeIdentPartOrEscapeStart(char16_t)
{
    RELEASE_ASSERT_NOT_REACHED();
}

// 256 Latin-1 codes
// The JSON RFC 4627 defines a list of allowed characters to be considered
// insignificant white space: http://www.ietf.org/rfc/rfc4627.txt (2. JSON Grammar).
static constexpr const TokenType tokenTypesOfLatin1Characters[256] = {
/*   0 - Null               */ TokError,
/*   1 - Start of Heading   */ TokError,
/*   2 - Start of Text      */ TokError,
/*   3 - End of Text        */ TokError,
/*   4 - End of Transm.     */ TokError,
/*   5 - Enquiry            */ TokError,
/*   6 - Acknowledgment     */ TokError,
/*   7 - Bell               */ TokError,
/*   8 - Back Space         */ TokError,
/*   9 - Horizontal Tab     */ TokErrorSpace,
/*  10 - Line Feed          */ TokErrorSpace,
/*  11 - Vertical Tab       */ TokError,
/*  12 - Form Feed          */ TokError,
/*  13 - Carriage Return    */ TokErrorSpace,
/*  14 - Shift Out          */ TokError,
/*  15 - Shift In           */ TokError,
/*  16 - Data Line Escape   */ TokError,
/*  17 - Device Control 1   */ TokError,
/*  18 - Device Control 2   */ TokError,
/*  19 - Device Control 3   */ TokError,
/*  20 - Device Control 4   */ TokError,
/*  21 - Negative Ack.      */ TokError,
/*  22 - Synchronous Idle   */ TokError,
/*  23 - End of Transmit    */ TokError,
/*  24 - Cancel             */ TokError,
/*  25 - End of Medium      */ TokError,
/*  26 - Substitute         */ TokError,
/*  27 - Escape             */ TokError,
/*  28 - File Separator     */ TokError,
/*  29 - Group Separator    */ TokError,
/*  30 - Record Separator   */ TokError,
/*  31 - Unit Separator     */ TokError,
/*  32 - Space              */ TokErrorSpace,
/*  33 - !                  */ TokError,
/*  34 - "                  */ TokString,
/*  35 - #                  */ TokError,
/*  36 - $                  */ TokIdentifier,
/*  37 - %                  */ TokError,
/*  38 - &                  */ TokError,
/*  39 - '                  */ TokString,
/*  40 - (                  */ TokLParen,
/*  41 - )                  */ TokRParen,
/*  42 - *                  */ TokError,
/*  43 - +                  */ TokError,
/*  44 - ,                  */ TokComma,
/*  45 - -                  */ TokNumber,
/*  46 - .                  */ TokDot,
/*  47 - /                  */ TokError,
/*  48 - 0                  */ TokNumber,
/*  49 - 1                  */ TokNumber,
/*  50 - 2                  */ TokNumber,
/*  51 - 3                  */ TokNumber,
/*  52 - 4                  */ TokNumber,
/*  53 - 5                  */ TokNumber,
/*  54 - 6                  */ TokNumber,
/*  55 - 7                  */ TokNumber,
/*  56 - 8                  */ TokNumber,
/*  57 - 9                  */ TokNumber,
/*  58 - :                  */ TokColon,
/*  59 - ;                  */ TokSemi,
/*  60 - <                  */ TokError,
/*  61 - =                  */ TokAssign,
/*  62 - >                  */ TokError,
/*  63 - ?                  */ TokError,
/*  64 - @                  */ TokError,
/*  65 - A                  */ TokIdentifier,
/*  66 - B                  */ TokIdentifier,
/*  67 - C                  */ TokIdentifier,
/*  68 - D                  */ TokIdentifier,
/*  69 - E                  */ TokIdentifier,
/*  70 - F                  */ TokIdentifier,
/*  71 - G                  */ TokIdentifier,
/*  72 - H                  */ TokIdentifier,
/*  73 - I                  */ TokIdentifier,
/*  74 - J                  */ TokIdentifier,
/*  75 - K                  */ TokIdentifier,
/*  76 - L                  */ TokIdentifier,
/*  77 - M                  */ TokIdentifier,
/*  78 - N                  */ TokIdentifier,
/*  79 - O                  */ TokIdentifier,
/*  80 - P                  */ TokIdentifier,
/*  81 - Q                  */ TokIdentifier,
/*  82 - R                  */ TokIdentifier,
/*  83 - S                  */ TokIdentifier,
/*  84 - T                  */ TokIdentifier,
/*  85 - U                  */ TokIdentifier,
/*  86 - V                  */ TokIdentifier,
/*  87 - W                  */ TokIdentifier,
/*  88 - X                  */ TokIdentifier,
/*  89 - Y                  */ TokIdentifier,
/*  90 - Z                  */ TokIdentifier,
/*  91 - [                  */ TokLBracket,
/*  92 - \                  */ TokError,
/*  93 - ]                  */ TokRBracket,
/*  94 - ^                  */ TokError,
/*  95 - _                  */ TokIdentifier,
/*  96 - `                  */ TokError,
/*  97 - a                  */ TokIdentifier,
/*  98 - b                  */ TokIdentifier,
/*  99 - c                  */ TokIdentifier,
/* 100 - d                  */ TokIdentifier,
/* 101 - e                  */ TokIdentifier,
/* 102 - f                  */ TokIdentifier,
/* 103 - g                  */ TokIdentifier,
/* 104 - h                  */ TokIdentifier,
/* 105 - i                  */ TokIdentifier,
/* 106 - j                  */ TokIdentifier,
/* 107 - k                  */ TokIdentifier,
/* 108 - l                  */ TokIdentifier,
/* 109 - m                  */ TokIdentifier,
/* 110 - n                  */ TokIdentifier,
/* 111 - o                  */ TokIdentifier,
/* 112 - p                  */ TokIdentifier,
/* 113 - q                  */ TokIdentifier,
/* 114 - r                  */ TokIdentifier,
/* 115 - s                  */ TokIdentifier,
/* 116 - t                  */ TokIdentifier,
/* 117 - u                  */ TokIdentifier,
/* 118 - v                  */ TokIdentifier,
/* 119 - w                  */ TokIdentifier,
/* 120 - x                  */ TokIdentifier,
/* 121 - y                  */ TokIdentifier,
/* 122 - z                  */ TokIdentifier,
/* 123 - {                  */ TokLBrace,
/* 124 - |                  */ TokError,
/* 125 - }                  */ TokRBrace,
/* 126 - ~                  */ TokError,
/* 127 - Delete             */ TokError,
/* 128 - Cc category        */ TokError,
/* 129 - Cc category        */ TokError,
/* 130 - Cc category        */ TokError,
/* 131 - Cc category        */ TokError,
/* 132 - Cc category        */ TokError,
/* 133 - Cc category        */ TokError,
/* 134 - Cc category        */ TokError,
/* 135 - Cc category        */ TokError,
/* 136 - Cc category        */ TokError,
/* 137 - Cc category        */ TokError,
/* 138 - Cc category        */ TokError,
/* 139 - Cc category        */ TokError,
/* 140 - Cc category        */ TokError,
/* 141 - Cc category        */ TokError,
/* 142 - Cc category        */ TokError,
/* 143 - Cc category        */ TokError,
/* 144 - Cc category        */ TokError,
/* 145 - Cc category        */ TokError,
/* 146 - Cc category        */ TokError,
/* 147 - Cc category        */ TokError,
/* 148 - Cc category        */ TokError,
/* 149 - Cc category        */ TokError,
/* 150 - Cc category        */ TokError,
/* 151 - Cc category        */ TokError,
/* 152 - Cc category        */ TokError,
/* 153 - Cc category        */ TokError,
/* 154 - Cc category        */ TokError,
/* 155 - Cc category        */ TokError,
/* 156 - Cc category        */ TokError,
/* 157 - Cc category        */ TokError,
/* 158 - Cc category        */ TokError,
/* 159 - Cc category        */ TokError,
/* 160 - Zs category (nbsp) */ TokError,
/* 161 - Po category        */ TokError,
/* 162 - Sc category        */ TokError,
/* 163 - Sc category        */ TokError,
/* 164 - Sc category        */ TokError,
/* 165 - Sc category        */ TokError,
/* 166 - So category        */ TokError,
/* 167 - So category        */ TokError,
/* 168 - Sk category        */ TokError,
/* 169 - So category        */ TokError,
/* 170 - Ll category        */ TokError,
/* 171 - Pi category        */ TokError,
/* 172 - Sm category        */ TokError,
/* 173 - Cf category        */ TokError,
/* 174 - So category        */ TokError,
/* 175 - Sk category        */ TokError,
/* 176 - So category        */ TokError,
/* 177 - Sm category        */ TokError,
/* 178 - No category        */ TokError,
/* 179 - No category        */ TokError,
/* 180 - Sk category        */ TokError,
/* 181 - Ll category        */ TokError,
/* 182 - So category        */ TokError,
/* 183 - Po category        */ TokError,
/* 184 - Sk category        */ TokError,
/* 185 - No category        */ TokError,
/* 186 - Ll category        */ TokError,
/* 187 - Pf category        */ TokError,
/* 188 - No category        */ TokError,
/* 189 - No category        */ TokError,
/* 190 - No category        */ TokError,
/* 191 - Po category        */ TokError,
/* 192 - Lu category        */ TokError,
/* 193 - Lu category        */ TokError,
/* 194 - Lu category        */ TokError,
/* 195 - Lu category        */ TokError,
/* 196 - Lu category        */ TokError,
/* 197 - Lu category        */ TokError,
/* 198 - Lu category        */ TokError,
/* 199 - Lu category        */ TokError,
/* 200 - Lu category        */ TokError,
/* 201 - Lu category        */ TokError,
/* 202 - Lu category        */ TokError,
/* 203 - Lu category        */ TokError,
/* 204 - Lu category        */ TokError,
/* 205 - Lu category        */ TokError,
/* 206 - Lu category        */ TokError,
/* 207 - Lu category        */ TokError,
/* 208 - Lu category        */ TokError,
/* 209 - Lu category        */ TokError,
/* 210 - Lu category        */ TokError,
/* 211 - Lu category        */ TokError,
/* 212 - Lu category        */ TokError,
/* 213 - Lu category        */ TokError,
/* 214 - Lu category        */ TokError,
/* 215 - Sm category        */ TokError,
/* 216 - Lu category        */ TokError,
/* 217 - Lu category        */ TokError,
/* 218 - Lu category        */ TokError,
/* 219 - Lu category        */ TokError,
/* 220 - Lu category        */ TokError,
/* 221 - Lu category        */ TokError,
/* 222 - Lu category        */ TokError,
/* 223 - Ll category        */ TokError,
/* 224 - Ll category        */ TokError,
/* 225 - Ll category        */ TokError,
/* 226 - Ll category        */ TokError,
/* 227 - Ll category        */ TokError,
/* 228 - Ll category        */ TokError,
/* 229 - Ll category        */ TokError,
/* 230 - Ll category        */ TokError,
/* 231 - Ll category        */ TokError,
/* 232 - Ll category        */ TokError,
/* 233 - Ll category        */ TokError,
/* 234 - Ll category        */ TokError,
/* 235 - Ll category        */ TokError,
/* 236 - Ll category        */ TokError,
/* 237 - Ll category        */ TokError,
/* 238 - Ll category        */ TokError,
/* 239 - Ll category        */ TokError,
/* 240 - Ll category        */ TokError,
/* 241 - Ll category        */ TokError,
/* 242 - Ll category        */ TokError,
/* 243 - Ll category        */ TokError,
/* 244 - Ll category        */ TokError,
/* 245 - Ll category        */ TokError,
/* 246 - Ll category        */ TokError,
/* 247 - Sm category        */ TokError,
/* 248 - Ll category        */ TokError,
/* 249 - Ll category        */ TokError,
/* 250 - Ll category        */ TokError,
/* 251 - Ll category        */ TokError,
/* 252 - Ll category        */ TokError,
/* 253 - Ll category        */ TokError,
/* 254 - Ll category        */ TokError,
/* 255 - Ll category        */ TokError
};

// 256 Latin-1 codes
static constexpr const bool safeStringLatin1CharactersInStrictJSON[256] = {
/*   0 - Null               */ false,
/*   1 - Start of Heading   */ false,
/*   2 - Start of Text      */ false,
/*   3 - End of Text        */ false,
/*   4 - End of Transm.     */ false,
/*   5 - Enquiry            */ false,
/*   6 - Acknowledgment     */ false,
/*   7 - Bell               */ false,
/*   8 - Back Space         */ false,
/*   9 - Horizontal Tab     */ false,
/*  10 - Line Feed          */ false,
/*  11 - Vertical Tab       */ false,
/*  12 - Form Feed          */ false,
/*  13 - Carriage Return    */ false,
/*  14 - Shift Out          */ false,
/*  15 - Shift In           */ false,
/*  16 - Data Line Escape   */ false,
/*  17 - Device Control 1   */ false,
/*  18 - Device Control 2   */ false,
/*  19 - Device Control 3   */ false,
/*  20 - Device Control 4   */ false,
/*  21 - Negative Ack.      */ false,
/*  22 - Synchronous Idle   */ false,
/*  23 - End of Transmit    */ false,
/*  24 - Cancel             */ false,
/*  25 - End of Medium      */ false,
/*  26 - Substitute         */ false,
/*  27 - Escape             */ false,
/*  28 - File Separator     */ false,
/*  29 - Group Separator    */ false,
/*  30 - Record Separator   */ false,
/*  31 - Unit Separator     */ false,
/*  32 - Space              */ true,
/*  33 - !                  */ true,
/*  34 - "                  */ false,
/*  35 - #                  */ true,
/*  36 - $                  */ true,
/*  37 - %                  */ true,
/*  38 - &                  */ true,
/*  39 - '                  */ true,
/*  40 - (                  */ true,
/*  41 - )                  */ true,
/*  42 - *                  */ true,
/*  43 - +                  */ true,
/*  44 - ,                  */ true,
/*  45 - -                  */ true,
/*  46 - .                  */ true,
/*  47 - /                  */ true,
/*  48 - 0                  */ true,
/*  49 - 1                  */ true,
/*  50 - 2                  */ true,
/*  51 - 3                  */ true,
/*  52 - 4                  */ true,
/*  53 - 5                  */ true,
/*  54 - 6                  */ true,
/*  55 - 7                  */ true,
/*  56 - 8                  */ true,
/*  57 - 9                  */ true,
/*  58 - :                  */ true,
/*  59 - ;                  */ true,
/*  60 - <                  */ true,
/*  61 - =                  */ true,
/*  62 - >                  */ true,
/*  63 - ?                  */ true,
/*  64 - @                  */ true,
/*  65 - A                  */ true,
/*  66 - B                  */ true,
/*  67 - C                  */ true,
/*  68 - D                  */ true,
/*  69 - E                  */ true,
/*  70 - F                  */ true,
/*  71 - G                  */ true,
/*  72 - H                  */ true,
/*  73 - I                  */ true,
/*  74 - J                  */ true,
/*  75 - K                  */ true,
/*  76 - L                  */ true,
/*  77 - M                  */ true,
/*  78 - N                  */ true,
/*  79 - O                  */ true,
/*  80 - P                  */ true,
/*  81 - Q                  */ true,
/*  82 - R                  */ true,
/*  83 - S                  */ true,
/*  84 - T                  */ true,
/*  85 - U                  */ true,
/*  86 - V                  */ true,
/*  87 - W                  */ true,
/*  88 - X                  */ true,
/*  89 - Y                  */ true,
/*  90 - Z                  */ true,
/*  91 - [                  */ true,
/*  92 - \                  */ false,
/*  93 - ]                  */ true,
/*  94 - ^                  */ true,
/*  95 - _                  */ true,
/*  96 - `                  */ true,
/*  97 - a                  */ true,
/*  98 - b                  */ true,
/*  99 - c                  */ true,
/* 100 - d                  */ true,
/* 101 - e                  */ true,
/* 102 - f                  */ true,
/* 103 - g                  */ true,
/* 104 - h                  */ true,
/* 105 - i                  */ true,
/* 106 - j                  */ true,
/* 107 - k                  */ true,
/* 108 - l                  */ true,
/* 109 - m                  */ true,
/* 110 - n                  */ true,
/* 111 - o                  */ true,
/* 112 - p                  */ true,
/* 113 - q                  */ true,
/* 114 - r                  */ true,
/* 115 - s                  */ true,
/* 116 - t                  */ true,
/* 117 - u                  */ true,
/* 118 - v                  */ true,
/* 119 - w                  */ true,
/* 120 - x                  */ true,
/* 121 - y                  */ true,
/* 122 - z                  */ true,
/* 123 - {                  */ true,
/* 124 - |                  */ true,
/* 125 - }                  */ true,
/* 126 - ~                  */ true,
/* 127 - Delete             */ true,
/* 128 - Cc category        */ true,
/* 129 - Cc category        */ true,
/* 130 - Cc category        */ true,
/* 131 - Cc category        */ true,
/* 132 - Cc category        */ true,
/* 133 - Cc category        */ true,
/* 134 - Cc category        */ true,
/* 135 - Cc category        */ true,
/* 136 - Cc category        */ true,
/* 137 - Cc category        */ true,
/* 138 - Cc category        */ true,
/* 139 - Cc category        */ true,
/* 140 - Cc category        */ true,
/* 141 - Cc category        */ true,
/* 142 - Cc category        */ true,
/* 143 - Cc category        */ true,
/* 144 - Cc category        */ true,
/* 145 - Cc category        */ true,
/* 146 - Cc category        */ true,
/* 147 - Cc category        */ true,
/* 148 - Cc category        */ true,
/* 149 - Cc category        */ true,
/* 150 - Cc category        */ true,
/* 151 - Cc category        */ true,
/* 152 - Cc category        */ true,
/* 153 - Cc category        */ true,
/* 154 - Cc category        */ true,
/* 155 - Cc category        */ true,
/* 156 - Cc category        */ true,
/* 157 - Cc category        */ true,
/* 158 - Cc category        */ true,
/* 159 - Cc category        */ true,
/* 160 - Zs category (nbsp) */ true,
/* 161 - Po category        */ true,
/* 162 - Sc category        */ true,
/* 163 - Sc category        */ true,
/* 164 - Sc category        */ true,
/* 165 - Sc category        */ true,
/* 166 - So category        */ true,
/* 167 - So category        */ true,
/* 168 - Sk category        */ true,
/* 169 - So category        */ true,
/* 170 - Ll category        */ true,
/* 171 - Pi category        */ true,
/* 172 - Sm category        */ true,
/* 173 - Cf category        */ true,
/* 174 - So category        */ true,
/* 175 - Sk category        */ true,
/* 176 - So category        */ true,
/* 177 - Sm category        */ true,
/* 178 - No category        */ true,
/* 179 - No category        */ true,
/* 180 - Sk category        */ true,
/* 181 - Ll category        */ true,
/* 182 - So category        */ true,
/* 183 - Po category        */ true,
/* 184 - Sk category        */ true,
/* 185 - No category        */ true,
/* 186 - Ll category        */ true,
/* 187 - Pf category        */ true,
/* 188 - No category        */ true,
/* 189 - No category        */ true,
/* 190 - No category        */ true,
/* 191 - Po category        */ true,
/* 192 - Lu category        */ true,
/* 193 - Lu category        */ true,
/* 194 - Lu category        */ true,
/* 195 - Lu category        */ true,
/* 196 - Lu category        */ true,
/* 197 - Lu category        */ true,
/* 198 - Lu category        */ true,
/* 199 - Lu category        */ true,
/* 200 - Lu category        */ true,
/* 201 - Lu category        */ true,
/* 202 - Lu category        */ true,
/* 203 - Lu category        */ true,
/* 204 - Lu category        */ true,
/* 205 - Lu category        */ true,
/* 206 - Lu category        */ true,
/* 207 - Lu category        */ true,
/* 208 - Lu category        */ true,
/* 209 - Lu category        */ true,
/* 210 - Lu category        */ true,
/* 211 - Lu category        */ true,
/* 212 - Lu category        */ true,
/* 213 - Lu category        */ true,
/* 214 - Lu category        */ true,
/* 215 - Sm category        */ true,
/* 216 - Lu category        */ true,
/* 217 - Lu category        */ true,
/* 218 - Lu category        */ true,
/* 219 - Lu category        */ true,
/* 220 - Lu category        */ true,
/* 221 - Lu category        */ true,
/* 222 - Lu category        */ true,
/* 223 - Ll category        */ true,
/* 224 - Ll category        */ true,
/* 225 - Ll category        */ true,
/* 226 - Ll category        */ true,
/* 227 - Ll category        */ true,
/* 228 - Ll category        */ true,
/* 229 - Ll category        */ true,
/* 230 - Ll category        */ true,
/* 231 - Ll category        */ true,
/* 232 - Ll category        */ true,
/* 233 - Ll category        */ true,
/* 234 - Ll category        */ true,
/* 235 - Ll category        */ true,
/* 236 - Ll category        */ true,
/* 237 - Ll category        */ true,
/* 238 - Ll category        */ true,
/* 239 - Ll category        */ true,
/* 240 - Ll category        */ true,
/* 241 - Ll category        */ true,
/* 242 - Ll category        */ true,
/* 243 - Ll category        */ true,
/* 244 - Ll category        */ true,
/* 245 - Ll category        */ true,
/* 246 - Ll category        */ true,
/* 247 - Sm category        */ true,
/* 248 - Ll category        */ true,
/* 249 - Ll category        */ true,
/* 250 - Ll category        */ true,
/* 251 - Ll category        */ true,
/* 252 - Ll category        */ true,
/* 253 - Ll category        */ true,
/* 254 - Ll category        */ true,
/* 255 - Ll category        */ true,
};

template <typename CharType>
static ALWAYS_INLINE bool NODELETE isJSONWhiteSpace(const CharType& c)
{
    return tokenTypesOfLatin1Characters[static_cast<uint8_t>(c)] == TokErrorSpace && isLatin1(c);
}

template<typename CharType, JSONReviverMode reviverMode>
template <JSONIdentifierHint hint>
ALWAYS_INLINE TokenType LiteralParser<CharType, reviverMode>::Lexer::lex(LiteralParserToken<CharType>& token)
{
#if ASSERT_ENABLED
    m_currentTokenID++;
#endif

    while (m_ptr < m_end && isJSONWhiteSpace(*m_ptr))
        ++m_ptr;

    if constexpr (reviverMode == JSONReviverMode::Enabled) {
        m_currentTokenStart = m_ptr;
        m_currentTokenEnd = m_ptr;
    }

    ASSERT(m_ptr <= m_end);
    if (m_ptr == m_end) {
        token.type = TokEnd;
        return TokEnd;
    }
    ASSERT(m_ptr < m_end);
    token.type = TokError;
    CharType character = *m_ptr;
    if (isLatin1(character)) [[likely]] {
        TokenType tokenType = tokenTypesOfLatin1Characters[character];
        switch (tokenType) {
        case TokString: {
            if (character == '\'' && m_mode == StrictJSON) [[unlikely]] {
                m_lexErrorMessage = "Single quotes (\') are not allowed in JSON"_s;
                if constexpr (reviverMode == JSONReviverMode::Enabled)
                    m_currentTokenEnd = m_ptr;
                return TokError;
            }
            auto result = lexString<hint>(token, character);
            if constexpr (reviverMode == JSONReviverMode::Enabled)
                m_currentTokenEnd = m_ptr;
            return result;
        }

        case TokIdentifier: {
            switch (character) {
            case 't':
                if (m_end - m_ptr >= 4 && compareCharacters(m_ptr + 1, 'r', 'u', 'e')) {
                    m_ptr += 4;
                    token.type = TokTrue;
                    if constexpr (reviverMode == JSONReviverMode::Enabled)
                        m_currentTokenEnd = m_ptr;
                    return TokTrue;
                }
                break;
            case 'f':
                if (m_end - m_ptr >= 5 && compareCharacters(m_ptr + 1, 'a', 'l', 's', 'e')) {
                    m_ptr += 5;
                    token.type = TokFalse;
                    if constexpr (reviverMode == JSONReviverMode::Enabled)
                        m_currentTokenEnd = m_ptr;
                    return TokFalse;
                }
                break;
            case 'n':
                if (m_end - m_ptr >= 4 && compareCharacters(m_ptr + 1, 'u', 'l', 'l')) {
                    m_ptr += 4;
                    token.type = TokNull;
                    if constexpr (reviverMode == JSONReviverMode::Enabled)
                        m_currentTokenEnd = m_ptr;
                    return TokNull;
                }
                break;
            }
            auto result = lexIdentifier(token);
            if constexpr (reviverMode == JSONReviverMode::Enabled)
                m_currentTokenEnd = m_ptr;
            return result;
        }

        case TokNumber: {
            auto result = lexNumber(token);
            if constexpr (reviverMode == JSONReviverMode::Enabled)
                m_currentTokenEnd = m_ptr;
            return result;
        }

        case TokError:
        case TokErrorSpace:
            break;

        default:
            ASSERT(tokenType == TokLBracket
                || tokenType == TokRBracket
                || tokenType == TokLBrace
                || tokenType == TokRBrace
                || tokenType == TokColon
                || tokenType == TokLParen
                || tokenType == TokRParen
                || tokenType == TokComma
                || tokenType == TokDot
                || tokenType == TokAssign
                || tokenType == TokSemi);
            token.type = tokenType;
            ++m_ptr;
            if constexpr (reviverMode == JSONReviverMode::Enabled)
                m_currentTokenEnd = m_ptr;
            return tokenType;
        }
    }
    m_lexErrorMessage = makeString("Unrecognized token '"_s, span(*m_ptr), '\'');
    if constexpr (reviverMode == JSONReviverMode::Enabled)
        m_currentTokenEnd = m_ptr;
    return TokError;
}

template <typename CharType>
ALWAYS_INLINE static bool isValidIdentifierCharacter(CharType c)
{
    if constexpr (sizeof(CharType) == 1)
        return isASCIIAlphanumeric(c) || c == '_' || c == '$';
    else
        return isASCIIAlphanumeric(c) || c == '_' || c == '$' || c == 0x200C || c == 0x200D;
}

template<typename CharType, JSONReviverMode reviverMode>
ALWAYS_INLINE TokenType LiteralParser<CharType, reviverMode>::Lexer::lexIdentifier(LiteralParserToken<CharType>& token)
{
    token.identifierStart = m_ptr;
    while (m_ptr < m_end && isValidIdentifierCharacter(*m_ptr))
        ++m_ptr;
    token.stringOrIdentifierLength = m_ptr - token.identifierStart;
    token.type = TokIdentifier;
    return TokIdentifier;
}

template<typename CharType, JSONReviverMode reviverMode>
ALWAYS_INLINE TokenType LiteralParser<CharType, reviverMode>::Lexer::next()
{
    TokenType result = lex<JSONIdentifierHint::Unknown>(m_currentToken);
    ASSERT(m_currentToken.type == result);
    return result;
}

template<typename CharType, JSONReviverMode reviverMode>
ALWAYS_INLINE TokenType LiteralParser<CharType, reviverMode>::Lexer::nextMaybeIdentifier()
{
    TokenType result = lex<JSONIdentifierHint::MaybeIdentifier>(m_currentToken);
    ASSERT(m_currentToken.type == result);
    return result;
}

#if JSC_SUPPORTS_SWIFT

// The island reports token types as its own Swift `JSONTokenType` and this file reads
// them as `TokenType` with no conversion — `literalValue` below switches a raw value
// that came out of Swift straight onto `TokTrue`/`TokFalse`/`TokNull` — so the two
// numberings have to agree. Nothing in C++ can assert against a Swift enum, so
// `JSONSwiftTokenType` (LiteralParserSwiftTypes.h) is transcribed from it by hand and
// these assert *that* against `TokenType`. The enum is therefore not scaffolding to be
// tidied away with the last C++ user of a `JSONSwiftTok*` constant: it is the only thing
// keeping the Swift numbering, the C++ numbering and this file's casts in step.
static_assert(static_cast<uint8_t>(TokLBracket) == JSONSwiftTokLBracket);
static_assert(static_cast<uint8_t>(TokRBracket) == JSONSwiftTokRBracket);
static_assert(static_cast<uint8_t>(TokLBrace) == JSONSwiftTokLBrace);
static_assert(static_cast<uint8_t>(TokRBrace) == JSONSwiftTokRBrace);
static_assert(static_cast<uint8_t>(TokString) == JSONSwiftTokString);
static_assert(static_cast<uint8_t>(TokIdentifier) == JSONSwiftTokIdentifier);
static_assert(static_cast<uint8_t>(TokNumber) == JSONSwiftTokNumber);
static_assert(static_cast<uint8_t>(TokNumberInt32) == JSONSwiftTokNumberInt32);
static_assert(static_cast<uint8_t>(TokColon) == JSONSwiftTokColon);
static_assert(static_cast<uint8_t>(TokLParen) == JSONSwiftTokLParen);
static_assert(static_cast<uint8_t>(TokRParen) == JSONSwiftTokRParen);
static_assert(static_cast<uint8_t>(TokComma) == JSONSwiftTokComma);
static_assert(static_cast<uint8_t>(TokTrue) == JSONSwiftTokTrue);
static_assert(static_cast<uint8_t>(TokFalse) == JSONSwiftTokFalse);
static_assert(static_cast<uint8_t>(TokNull) == JSONSwiftTokNull);
static_assert(static_cast<uint8_t>(TokEnd) == JSONSwiftTokEnd);
static_assert(static_cast<uint8_t>(TokDot) == JSONSwiftTokDot);
static_assert(static_cast<uint8_t>(TokAssign) == JSONSwiftTokAssign);
static_assert(static_cast<uint8_t>(TokSemi) == JSONSwiftTokSemi);
static_assert(static_cast<uint8_t>(TokError) == JSONSwiftTokError);
static_assert(static_cast<uint8_t>(TokErrorSpace) == JSONSwiftTokErrorSpace);

#endif // JSC_SUPPORTS_SWIFT

template <>
ALWAYS_INLINE void setParserTokenString<Latin1Character>(LiteralParserToken<Latin1Character>& token, const Latin1Character* string)
{
    token.stringIs8Bit = 1;
    token.stringStart8 = string;
}

template <>
ALWAYS_INLINE void setParserTokenString<char16_t>(LiteralParserToken<char16_t>& token, const char16_t* string)
{
    token.stringIs8Bit = 0;
    token.stringStart16 = string;
}

enum class SafeStringCharacterSet { Strict, Sloppy };

template <SafeStringCharacterSet set>
static ALWAYS_INLINE bool NODELETE isSafeStringCharacter(Latin1Character c, Latin1Character terminator)
{
    if constexpr (set == SafeStringCharacterSet::Strict)
        return safeStringLatin1CharactersInStrictJSON[c];
    else
        return (c >= ' ' && c != '\\' && c != terminator) || (c == '\t');
}

template <SafeStringCharacterSet set>
static ALWAYS_INLINE bool NODELETE isSafeStringCharacter(char16_t c, char16_t terminator)
{
    if (!isLatin1(c))
        return true;
    return isSafeStringCharacter<set>(static_cast<Latin1Character>(c), static_cast<Latin1Character>(terminator));
}

template <SafeStringCharacterSet set>
static ALWAYS_INLINE bool NODELETE isSafeStringCharacterForIdentifier(char16_t c, char16_t terminator)
{
    if constexpr (set == SafeStringCharacterSet::Strict)
        return isSafeStringCharacter<set>(static_cast<Latin1Character>(c), static_cast<Latin1Character>(terminator)) || !isLatin1(c);
    else
        return (c >= ' ' && isLatin1(c) && c != '\\' && c != terminator) || (c == '\t');
}

template<typename CharType, JSONReviverMode reviverMode>
template <JSONIdentifierHint hint>
ALWAYS_INLINE TokenType LiteralParser<CharType, reviverMode>::Lexer::lexString(LiteralParserToken<CharType>& token, CharType terminator)
{
    ++m_ptr;
    const CharType* runStart = m_ptr;

    if (m_mode == StrictJSON) {
        ASSERT(terminator == '"');
        if constexpr (hint == JSONIdentifierHint::MaybeIdentifier) {
            while (m_ptr < m_end && isSafeStringCharacterForIdentifier<SafeStringCharacterSet::Strict>(*m_ptr, terminator))
                ++m_ptr;
        } else {
            using UnsignedType = SameSizeUnsignedInteger<CharType>;
            constexpr auto quoteMask = SIMD::splat<UnsignedType>('"');
            constexpr auto escapeMask = SIMD::splat<UnsignedType>('\\');
            constexpr auto controlMask = SIMD::splat<UnsignedType>(' ');
            auto vectorMatch = [&](auto input) ALWAYS_INLINE_LAMBDA {
                auto quotes = SIMD::equal(input, quoteMask);
                auto escapes = SIMD::equal(input, escapeMask);
                auto controls = SIMD::lessThan(input, controlMask);
                auto mask = SIMD::bitOr(quotes, escapes, controls);
                return SIMD::findFirstNonZeroIndex(mask);
            };

            auto scalarMatch = [&](CharType character) ALWAYS_INLINE_LAMBDA {
                return !isSafeStringCharacter<SafeStringCharacterSet::Strict>(character, terminator);
            };

            m_ptr = SIMD::find(std::span { m_ptr, m_end }, vectorMatch, scalarMatch);
        }
    } else {
        if constexpr (hint == JSONIdentifierHint::MaybeIdentifier) {
            while (m_ptr < m_end && isSafeStringCharacterForIdentifier<SafeStringCharacterSet::Sloppy>(*m_ptr, terminator))
                ++m_ptr;
        } else {
            using UnsignedType = SameSizeUnsignedInteger<CharType>;
            auto quoteMask = SIMD::splat<UnsignedType>(terminator);
            constexpr auto escapeMask = SIMD::splat<UnsignedType>('\\');
            constexpr auto controlMask = SIMD::splat<UnsignedType>(' ');
            constexpr auto tabMask = SIMD::splat<UnsignedType>('\t');
            auto vectorMatch = [&](auto input) ALWAYS_INLINE_LAMBDA {
                auto quotes = SIMD::equal(input, quoteMask);
                auto escapes = SIMD::equal(input, escapeMask);
                auto controls = SIMD::lessThan(input, controlMask);
                auto notTabs = SIMD::bitNot(SIMD::equal(input, tabMask));
                auto controlsExceptTabs = SIMD::bitAnd(notTabs, controls);
                auto mask = SIMD::bitOr(quotes, escapes, controlsExceptTabs);
                return SIMD::findFirstNonZeroIndex(mask);
            };

            auto scalarMatch = [&](auto character) ALWAYS_INLINE_LAMBDA {
                return !isSafeStringCharacter<SafeStringCharacterSet::Sloppy>(character, terminator);
            };

            m_ptr = SIMD::find(std::span { m_ptr, m_end }, vectorMatch, scalarMatch);
        }
    }

    if (m_ptr < m_end && *m_ptr == terminator) [[likely]] {
        setParserTokenString<CharType>(token, runStart);
        token.stringOrIdentifierLength = m_ptr++ - runStart;
        token.type = TokString;
        return TokString;
    }
    return lexStringSlow(token, runStart, terminator);
}

template<typename CharType, JSONReviverMode reviverMode>
TokenType LiteralParser<CharType, reviverMode>::Lexer::lexStringSlow(LiteralParserToken<CharType>& token, const CharType* runStart, CharType terminator)
{
    m_builder.clear();
    goto slowPathBegin;
    do {
        runStart = m_ptr;
        if (m_mode == StrictJSON) {
            while (m_ptr < m_end && isSafeStringCharacter<SafeStringCharacterSet::Strict>(*m_ptr, terminator))
                ++m_ptr;
        } else {
            while (m_ptr < m_end && isSafeStringCharacter<SafeStringCharacterSet::Sloppy>(*m_ptr, terminator))
                ++m_ptr;
        }

        if (!m_builder.isEmpty())
            m_builder.append(std::span { runStart, m_ptr });

slowPathBegin:
        if ((m_mode != SloppyJSON) && m_ptr < m_end && *m_ptr == '\\') {
            if (m_builder.isEmpty() && runStart < m_ptr)
                m_builder.append(std::span { runStart, m_ptr });
            ++m_ptr;
            if (m_ptr >= m_end) {
                m_lexErrorMessage = "Unterminated string"_s;
                return TokError;
            }
            switch (*m_ptr) {
                case '"':
                    m_builder.append('"');
                    m_ptr++;
                    break;
                case '\\':
                    m_builder.append('\\');
                    m_ptr++;
                    break;
                case '/':
                    m_builder.append('/');
                    m_ptr++;
                    break;
                case 'b':
                    m_builder.append('\b');
                    m_ptr++;
                    break;
                case 'f':
                    m_builder.append('\f');
                    m_ptr++;
                    break;
                case 'n':
                    m_builder.append('\n');
                    m_ptr++;
                    break;
                case 'r':
                    m_builder.append('\r');
                    m_ptr++;
                    break;
                case 't':
                    m_builder.append('\t');
                    m_ptr++;
                    break;

                case 'u':
                    if ((m_end - m_ptr) < 5) { 
                        m_lexErrorMessage = "\\u must be followed by 4 hex digits"_s;
                        return TokError;
                    } // uNNNN == 5 characters
                    for (int i = 1; i < 5; i++) {
                        if (!isASCIIHexDigit(m_ptr[i])) {
                            m_lexErrorMessage = makeString("\"\\"_s, std::span { m_ptr, 5 }, "\" is not a valid unicode escape"_s);
                            return TokError;
                        }
                    }
                    m_builder.append(JSC::Lexer<CharType>::convertUnicode(m_ptr[1], m_ptr[2], m_ptr[3], m_ptr[4]));
                    m_ptr += 5;
                    break;

                default:
                    if (*m_ptr == '\'' && m_mode != StrictJSON) {
                        m_builder.append('\'');
                        m_ptr++;
                        break;
                    }
                    m_lexErrorMessage = makeString("Invalid escape character "_s, span(*m_ptr));
                    return TokError;
            }
        }
    } while ((m_mode != SloppyJSON) && m_ptr != runStart && (m_ptr < m_end) && *m_ptr != terminator);

    if (m_ptr >= m_end || *m_ptr != terminator) {
        m_lexErrorMessage = "Unterminated string"_s;
        return TokError;
    }

    if (m_builder.isEmpty()) {
        setParserTokenString<CharType>(token, runStart);
        token.stringOrIdentifierLength = m_ptr - runStart;
    } else {
        if (m_builder.is8Bit()) {
            token.stringIs8Bit = 1;
            token.stringStart8 = m_builder.span8().data();
        } else {
            token.stringIs8Bit = 0;
            token.stringStart16 = m_builder.span16().data();
        }
        token.stringOrIdentifierLength = m_builder.length();
    }
    token.type = TokString;
    ++m_ptr;
    return TokString;
}

template<typename CharType, JSONReviverMode reviverMode>
TokenType LiteralParser<CharType, reviverMode>::Lexer::lexNumber(LiteralParserToken<CharType>& token)
{
    // ES5 and json.org define numbers as
    // number
    //     int
    //     int frac? exp?
    //
    // int
    //     -? 0
    //     -? digit1-9 digits?
    //
    // digits
    //     digit digits?
    //
    // -?(0 | [1-9][0-9]*) ('.' [0-9]+)? ([eE][+-]? [0-9]+)?

    auto* initial = m_ptr;
    bool negative = false;
    if (m_ptr < m_end && *m_ptr == '-') {
        // -?
        negative = true;
        ++m_ptr;
    }
    auto* start = m_ptr; // Do not include '-'.

    // (0 | [1-9][0-9]*)
    uint32_t accumulated = 0;
    if (m_ptr < m_end && isASCIIDigit(*m_ptr)) [[likely]] {
        auto character = *m_ptr++;
        accumulated = character - '0';
        if (character != '0') {
            // [0-9]*
            while (m_ptr < m_end && isASCIIDigit(*m_ptr)) {
                accumulated = accumulated * 10 + (*m_ptr - '0');
                ++m_ptr;
            }
        }
    } else {
        m_lexErrorMessage = "Invalid number"_s;
        return TokError;
    }

    const int numberOfDigitsForSafeInt32 = 9; // The numbers from -999999999 to 999999999 are always in range of Int32.
    if (m_ptr < m_end && (*m_ptr != '.' && *m_ptr != 'e' && *m_ptr != 'E') && (m_ptr - start) <= numberOfDigitsForSafeInt32) {
        int32_t result = static_cast<int32_t>(accumulated);

        if (!negative) [[likely]] {
            token.type = TokNumberInt32;
            token.int32Token = result;
            return TokNumberInt32;
        }
        if (!result) [[unlikely]] {
            token.type = TokNumber;
            token.numberToken = -0.0;
            return TokNumber;
        }
        token.type = TokNumberInt32;
        token.int32Token = -result;
        return TokNumberInt32;
    }

    size_t parsedLength = 0;
    auto result = WTF::parseJSONDouble(std::span { initial, m_end }, parsedLength);
    if (result) [[likely]] {
        m_ptr = initial + parsedLength;
        token.type = TokNumber;
        token.numberToken = result.value();
        return TokNumber;
    }

    return lexNumberError(token);
}

template<typename CharType, JSONReviverMode reviverMode>
NEVER_INLINE TokenType LiteralParser<CharType, reviverMode>::Lexer::lexNumberError(LiteralParserToken<CharType>&)
{
    // ('.' [0-9]+)?
    if (m_ptr < m_end && *m_ptr == '.') {
        ++m_ptr;
        // [0-9]+
        if (m_ptr >= m_end || !isASCIIDigit(*m_ptr)) {
            m_lexErrorMessage = "Invalid digits after decimal point"_s;
            return TokError;
        }

        ++m_ptr;
        while (m_ptr < m_end && isASCIIDigit(*m_ptr))
            ++m_ptr;
    }

    //  ([eE][+-]? [0-9]+)?
    if (m_ptr < m_end && (*m_ptr == 'e' || *m_ptr == 'E')) { // [eE]
        ++m_ptr;

        // [-+]?
        if (m_ptr < m_end && (*m_ptr == '-' || *m_ptr == '+'))
            ++m_ptr;

        // [0-9]+
        if (m_ptr >= m_end || !isASCIIDigit(*m_ptr)) {
            m_lexErrorMessage = "Exponent symbols should be followed by an optional '+' or '-' and then by at least one number"_s;
            return TokError;
        }

        ++m_ptr;
        while (m_ptr < m_end && isASCIIDigit(*m_ptr))
            ++m_ptr;
    }

    ASSERT_NOT_REACHED();
    m_lexErrorMessage = "Invalid number"_s;
    return TokError;
}

template<typename CharType, JSONReviverMode reviverMode>
void LiteralParser<CharType, reviverMode>::setErrorMessageForToken(TokenType tokenType)
{
    switch (tokenType) {
    case TokRBrace:
        m_parseErrorMessage = "Expected '}'"_s;
        break;
    case TokRBracket:
        m_parseErrorMessage = "Expected ']'"_s;
        break;
    case TokColon:
        m_parseErrorMessage = "Expected ':' before value in object property definition"_s;
        break;
    default: {
        RELEASE_ASSERT_NOT_REACHED();
    }
    }
}

template<typename CharType, JSONReviverMode reviverMode>
ALWAYS_INLINE JSValue LiteralParser<CharType, reviverMode>::parsePrimitiveValue(VM& vm)
{
    switch (m_lexer.currentToken()->type) {
    case TokString: {
        JSString* result = makeJSString(vm, m_lexer.currentToken());
        m_lexer.next();
        return result;
    }
    case TokNumberInt32: {
        JSValue result = jsNumber(m_lexer.currentToken()->int32Token);
        m_lexer.next();
        return result;
    }
    case TokNumber: {
        JSValue result = jsNumber(m_lexer.currentToken()->numberToken);
        m_lexer.next();
        return result;
    }
    case TokNull:
        m_lexer.next();
        return jsNull();
    case TokTrue:
        m_lexer.next();
        return jsBoolean(true);
    case TokFalse:
        m_lexer.next();
        return jsBoolean(false);
    case TokRBracket:
        m_parseErrorMessage = "Unexpected token ']'"_s;
        return { };
    case TokRBrace:
        m_parseErrorMessage = "Unexpected token '}'"_s;
        return { };
    case TokIdentifier: {
        auto token = m_lexer.currentToken();

        auto tryMakeErrorString = [&] (unsigned length) -> String {
            bool addEllipsis = length != token->stringOrIdentifierLength;
            return tryMakeString("Unexpected identifier \""_s, std::span { token->identifierStart, length }, addEllipsis ? "..."_s : ""_s, '"');
        };

        constexpr unsigned maxLength = 200;

        String errorString = tryMakeErrorString(std::min(token->stringOrIdentifierLength, maxLength));
        if (!errorString) {
            constexpr unsigned shortLength = 10;
            if (token->stringOrIdentifierLength > shortLength)
                errorString = tryMakeErrorString(shortLength);
            if (!errorString)
                errorString = "Unexpected identifier"_s;
        }

        m_parseErrorMessage = errorString;
        return { };
    }
    case TokColon:
        m_parseErrorMessage = "Unexpected token ':'"_s;
        return { };
    case TokLParen:
        m_parseErrorMessage = "Unexpected token '('"_s;
        return { };
    case TokRParen:
        m_parseErrorMessage = "Unexpected token ')'"_s;
        return { };
    case TokComma:
        m_parseErrorMessage = "Unexpected token ','"_s;
        return { };
    case TokDot:
        m_parseErrorMessage = "Unexpected token '.'"_s;
        return { };
    case TokAssign:
        m_parseErrorMessage = "Unexpected token '='"_s;
        return { };
    case TokSemi:
        m_parseErrorMessage = "Unexpected token ';'"_s;
        return { };
    case TokEnd:
        m_parseErrorMessage = "Unexpected EOF"_s;
        return { };
    case TokError:
    default:
        // Error
        m_parseErrorMessage = "Could not parse value expression"_s;
        return { };
    }
}

template<typename CharType, JSONReviverMode reviverMode>
JSValue LiteralParser<CharType, reviverMode>::parseRecursivelyEntry(VM& vm)
    requires (reviverMode == JSONReviverMode::Disabled)
{
    ASSERT(m_mode == StrictJSON);
    if (!Options::useRecursiveJSONParse()) [[unlikely]]
        return parse(vm, StartParseExpression, nullptr);
    TokenType type = m_lexer.currentToken()->type;
    if (type == TokLBrace || type == TokLBracket)
        return parseRecursively<ParserMode::StrictJSON>(vm, std::bit_cast<uint8_t*>(vm.softStackLimit()));
    return parsePrimitiveValue(vm);
}

template<typename CharType, JSONReviverMode reviverMode>
JSValue LiteralParser<CharType, reviverMode>::evalRecursivelyEntry(VM& vm)
    requires (reviverMode == JSONReviverMode::Disabled)
{
    ASSERT(m_mode == SloppyJSON);
    if (!Options::useRecursiveJSONParse()) [[unlikely]]
        return parse(vm, StartParseStatement, nullptr);
    TokenType type = m_lexer.currentToken()->type;
    if (type == TokLParen) {
        type = m_lexer.next();

        JSValue result;
        if (type == TokLBrace || type == TokLBracket)
            result = parseRecursively<ParserMode::SloppyJSON>(vm, std::bit_cast<uint8_t*>(vm.softStackLimit()));
        else
            result = parsePrimitiveValue(vm);

        if (m_lexer.currentToken()->type != TokRParen) [[unlikely]] {
            m_parseErrorMessage = "Unexpected content at end of JSON literal"_s;
            return { };
        }
        m_lexer.next();
        return result;
    }

    if (type == TokLBrace) [[unlikely]] {
        m_parseErrorMessage = "Unexpected token '{'"_s;
        return { };
    }

    if (type == TokLBracket)
        return parseRecursively<ParserMode::SloppyJSON>(vm, std::bit_cast<uint8_t*>(vm.softStackLimit()));
    return parsePrimitiveValue(vm);
}

template<typename CharType, JSONReviverMode reviverMode>
JSArray* LiteralParser<CharType, reviverMode>::materializeArray(VM& vm, unsigned stackBase)
{
    auto scope = DECLARE_THROW_SCOPE(vm);

    unsigned length = m_elementStack.size() - stackBase;
    JSValue* values = m_elementStack.begin() + stackBase;
    ASSERT(length);

    // putDirectIndex would have discovered this while growing the butterfly one element at a time.
    IndexingType indexingType = ArrayWithInt32;
    for (unsigned i = 0; i < length; ++i) {
        JSValue value = values[i];
        if (value.isInt32())
            continue;
        if (value.isDouble()) {
            indexingType = ArrayWithDouble;
            continue;
        }
        indexingType = ArrayWithContiguous;
        break;
    }

    {
        ObjectInitializationScope initializationScope(vm);
        Structure* structure = m_globalObject->arrayStructureForIndexingTypeDuringAllocation(indexingType);
        if (JSArray* array = JSArray::tryCreateUninitializedRestricted(initializationScope, structure, length)) [[likely]] {
            for (unsigned i = 0; i < length; ++i)
                array->initializeIndex(initializationScope, i, values[i]);
            return array;
        }
    }

    // Lengths beyond what a contiguous vector can hold, and allocation failures, grow an empty array
    // instead so that they report out of memory rather than crashing.
    JSArray* array = constructEmptyArray(m_globalObject, nullptr);
    RETURN_IF_EXCEPTION(scope, nullptr);
    for (unsigned i = 0; i < length; ++i) {
        array->putDirectIndex(m_globalObject, i, values[i]);
        RETURN_IF_EXCEPTION(scope, nullptr);
    }
    return array;
}

template<typename CharType, JSONReviverMode reviverMode>
template<ParserMode parserMode>
JSValue LiteralParser<CharType, reviverMode>::parseRecursively(VM& vm, uint8_t* stackLimit)
    requires (reviverMode == JSONReviverMode::Disabled)
{
    if (std::bit_cast<uint8_t*>(currentStackPointer()) < stackLimit) [[unlikely]]
        return parse(vm, StartParseExpression, nullptr);

    auto scope = DECLARE_THROW_SCOPE(vm);
    TokenType type = m_lexer.currentToken()->type;
    if (type == TokLBracket) {
        TokenType type = m_lexer.next();
        if (type == TokRBracket) {
            m_lexer.next();
            RELEASE_AND_RETURN(scope, constructEmptyArray(m_globalObject, nullptr));
        }

        // Elements are collected first so that the array is allocated once at its final length and
        // indexing type, rather than growing a butterfly once per element.
        unsigned stackBase = m_elementStack.size();
        while (true) {
            JSValue value;
            if (type == TokLBrace || type == TokLBracket)
                value = parseRecursively<parserMode>(vm, stackLimit);
            else
                value = parsePrimitiveValue(vm);
            EXCEPTION_ASSERT((!!scope.exception() || !m_parseErrorMessage.isNull()) == !value);
            if (!value) [[unlikely]] {
                m_elementStack.shrink(stackBase);
                return { };
            }
            m_elementStack.append(value);
            if (m_elementStack.hasOverflowed()) [[unlikely]] {
                m_elementStack.shrink(stackBase);
                throwOutOfMemoryError(m_globalObject, scope);
                return { };
            }

            type = m_lexer.currentToken()->type;
            if (type == TokComma) {
                type = m_lexer.next();
                if (type == TokRBracket) [[unlikely]] {
                    m_parseErrorMessage = "Unexpected comma at the end of array expression"_s;
                    m_elementStack.shrink(stackBase);
                    return { };
                }
                continue;
            }

            if (type != TokRBracket) [[unlikely]] {
                setErrorMessageForToken(TokRBracket);
                m_elementStack.shrink(stackBase);
                return { };
            }

            m_lexer.next();
            break;
        }

        JSArray* array = materializeArray(vm, stackBase);
        m_elementStack.shrink(stackBase);
        RETURN_IF_EXCEPTION(scope, { });
        return array;
    }

    ASSERT(type == TokLBrace);
    JSObject* object = constructEmptyObject(m_globalObject);
    if constexpr (sizeof(CharType) == 2)
        type = m_lexer.nextMaybeIdentifier();
    else
        type = m_lexer.next();

    bool isPropertyKey = type == TokString;
    if constexpr (parserMode != StrictJSON)
        isPropertyKey |= type == TokIdentifier;

    if (isPropertyKey) {
        while (true) {
            struct ExistingProperty {
                Structure* structure;
                PropertyOffset offset;
            };

            auto* originalStructure = object->structure();
            auto property = [&, &vm = vm] ALWAYS_INLINE_LAMBDA -> Variant<ExistingProperty, Identifier> {
                if (Structure* transition = originalStructure->trySingleTransition()) {
                    // This check avoids hash lookup and refcount churn in the common case of a matching single transition.
                    SUPPRESS_UNCOUNTED_ARG if (transition->transitionKind() == TransitionKind::PropertyAddition
                        && !transition->transitionPropertyAttributes()
                        && equalIdentifier(transition->transitionPropertyName(), m_lexer.currentToken())) {
                        if constexpr (parserMode == StrictJSON)
                            return ExistingProperty { transition, transition->transitionOffset() };
                        else if (transition->transitionPropertyName() != vm.propertyNames->underscoreProto && m_visitedUnderscoreProto.isEmpty())
                            return ExistingProperty { transition, transition->transitionOffset() };
                    }
                } else if (!originalStructure->isDictionary()) {
                    // This check avoids refcount churn in the common case of a cached Identifier.
                    if (SUPPRESS_UNCOUNTED_LOCAL AtomStringImpl* ident = existingIdentifier(vm, m_lexer.currentToken())) {
                        PropertyOffset offset = 0;
                        Structure* newStructure = Structure::addPropertyTransitionToExistingStructure(originalStructure, ident, 0, offset);
                        if (newStructure) [[likely]] {
                            if constexpr (parserMode == StrictJSON)
                                return ExistingProperty { newStructure, offset };
                            else if (newStructure->transitionPropertyName() != vm.propertyNames->underscoreProto && m_visitedUnderscoreProto.isEmpty())
                                return ExistingProperty { newStructure, offset };
                        }
                        return Identifier::fromString(vm, ident);
                    }
                }

                return makeIdentifier(vm, m_lexer.currentToken());
            }();

            if (m_lexer.next() != TokColon) [[unlikely]] {
                setErrorMessageForToken(TokColon);
                return { };
            }

            type = m_lexer.next();
            JSValue value;
            if (type == TokLBrace || type == TokLBracket)
                value = parseRecursively<parserMode>(vm, stackLimit);
            else
                value = parsePrimitiveValue(vm);
            EXCEPTION_ASSERT((!!scope.exception() || !m_parseErrorMessage.isNull()) == !value);
            if (!value) [[unlikely]]
                return { };

            // After parseRecursively, user code may have run (e.g. due to a __proto__ setter in a
            // nested object), which may have changed the structure of the object. This invalidates
            // any cached transition, so reset it to Identifier to take the slow path.
            if constexpr (parserMode != StrictJSON) {
                if (object->structure() != originalStructure && std::holds_alternative<ExistingProperty>(property)) [[unlikely]]
                    property = Identifier::fromUid(vm, std::get<ExistingProperty>(property).structure->transitionPropertyName());
            } else {
                // StrictJSON can skip this entirely! There is no replacer/reviver and __proto__ setters in
                // a strict JSON value cannot run user code, so the parent object's structure is guaranteed not to have
                // transitioned during the recursive parse of `value`.
                ASSERT(object->structure() == originalStructure);
            }

            // When creating JSON object in this fast path, we know the following.
            //   1. The object is definitely JSFinalObject.
            //   2. The object rarely has duplicate properties.
            //   3. Many same-shaped objects would be created from JSON. Thus very likely, there is already an existing Structure.
            // Let's make the above case super fast, and fallback to the normal implementation when it is not true.
            if (std::holds_alternative<ExistingProperty>(property)) {
                auto& [newStructure, offset] = std::get<ExistingProperty>(property);

                Butterfly* newButterfly = object->butterfly();
                // Both capacities are zero while the properties still fit in inline storage, which
                // is the common case, and reading them means touching two Structures.
                if (offset >= firstOutOfLineOffset && originalStructure->outOfLineCapacity() != newStructure->outOfLineCapacity()) [[unlikely]] {
                    ASSERT(newStructure != originalStructure);
                    newButterfly = object->allocateMoreOutOfLineStorage(vm, originalStructure->outOfLineCapacity(), newStructure->outOfLineCapacity());
                    object->nukeStructureAndSetButterfly(vm, originalStructure->id(), newButterfly);
                }

                validateOffset(offset);
                ASSERT(newStructure->isValidOffset(offset));

                // This assertion verifies that the concurrent GC won't read garbage if the concurrentGC
                // is running at the same time we put without transitioning.
                ASSERT(!object->getDirect(offset) || !JSValue::encode(object->getDirect(offset)));
                object->putDirectOffset(vm, offset, value);
                object->setStructure(vm, newStructure);
                ASSERT(!newStructure->mayBePrototype()); // There is no way to make it prototype object.
            } else {
                ASSERT(std::holds_alternative<Identifier>(property));
                auto& ident = std::get<Identifier>(property);
                if (parserMode != StrictJSON && ident == vm.propertyNames->underscoreProto) [[unlikely]] {
                    if (!m_visitedUnderscoreProto.add(object).isNewEntry) [[unlikely]] {
                        m_parseErrorMessage = "Attempted to redefine __proto__ property"_s;
                        return { };
                    }
                    PutPropertySlot slot(object, m_nullOrCodeBlock && m_nullOrCodeBlock->ownerExecutable()->isInStrictContext());
                    JSValue(object).put(m_globalObject, ident, value, slot);
                    RETURN_IF_EXCEPTION(scope, { });
                } else if (std::optional<uint32_t> index = parseIndex(ident)) {
                    object->putDirectIndex(m_globalObject, index.value(), value);
                    RETURN_IF_EXCEPTION(scope, { });
                } else
                    object->putDirect(vm, ident, value);
            }

            type = m_lexer.currentToken()->type;
            if (type == TokComma) {
                type = m_lexer.next();
                bool isPropertyKey = type == TokString;
                if constexpr (parserMode != StrictJSON)
                    isPropertyKey |= type == TokIdentifier;
                if (!isPropertyKey) [[unlikely]] {
                    m_parseErrorMessage = "Property name must be a string literal"_s;
                    return { };
                }
                continue;
            }

            if (type != TokRBrace) [[unlikely]] {
                setErrorMessageForToken(TokRBrace);
                return { };
            }

            m_lexer.next();
            return object;
        }
    }

    if (type != TokRBrace) [[unlikely]] {
        setErrorMessageForToken(TokRBrace);
        return { };
    }

    m_lexer.next();
    return object;
}

constexpr unsigned maximumRangesStackRecursion = 4500;

template <typename CharType, JSONReviverMode reviverMode>
JSValue LiteralParser<CharType, reviverMode>::parse(VM& vm, ParserState initialState, JSONRanges* sourceRanges)
{
    auto scope = DECLARE_THROW_SCOPE(vm);
    ParserState state = initialState;
    JSValue lastValue;
    JSONRanges::Entry lastValueRange;

    while (1) {
        switch(state) {
        startParseArray:
        case StartParseArray: {
            JSArray* array = constructEmptyArray(m_globalObject, nullptr);
            RETURN_IF_EXCEPTION(scope, { });
            m_objectStack.appendWithCrashOnOverflow(array);
            if constexpr (reviverMode == JSONReviverMode::Enabled) {
                if (sourceRanges) {
                    if (m_rangesStack.size() >= maximumRangesStackRecursion) [[unlikely]]
                        return throwStackOverflowError(m_globalObject, scope);

                    unsigned startOffset = static_cast<unsigned>(m_lexer.currentTokenStart() - m_lexer.start());
                    m_rangesStack.append({
                        sourceRanges->record(array),
                        WTF::Range<unsigned> { startOffset },
                        JSONRanges::Array { }
                    });
                }
            }
        }
        doParseArrayStartExpression:
        [[fallthrough]];
        case DoParseArrayStartExpression: {
            TokenType lastToken = m_lexer.currentToken()->type;
            if (m_lexer.next() == TokRBracket) {
                if (lastToken == TokComma) [[unlikely]] {
                    m_parseErrorMessage = "Unexpected comma at the end of array expression"_s;
                    return { };
                }
                if constexpr (reviverMode == JSONReviverMode::Enabled) {
                    if (sourceRanges) {
                        auto entry = m_rangesStack.takeLast();
                        entry.range = { entry.range.begin(), static_cast<unsigned>(m_lexer.currentTokenEnd() - m_lexer.start()) };
                        lastValueRange = WTF::move(entry);
                    }
                }
                m_lexer.next();
                lastValue = m_objectStack.takeLast();
                break;
            }

            m_stateStack.append(DoParseArrayEndExpression);
            goto startParseExpression;
        }
        case DoParseArrayEndExpression: {
            JSArray* array = asArray(m_objectStack.last());
            array->putDirectIndex(m_globalObject, array->length(), lastValue);
            RETURN_IF_EXCEPTION(scope, { });
            if constexpr (reviverMode == JSONReviverMode::Enabled) {
                if (sourceRanges)
                    std::get<JSONRanges::Array>(m_rangesStack.last().properties).append(WTF::move(lastValueRange));
            }

            if (m_lexer.currentToken()->type == TokComma)
                goto doParseArrayStartExpression;

            if (m_lexer.currentToken()->type != TokRBracket) [[unlikely]] {
                setErrorMessageForToken(TokRBracket);
                return { };
            }
            
            if constexpr (reviverMode == JSONReviverMode::Enabled) {
                if (sourceRanges) {
                    auto entry = m_rangesStack.takeLast();
                    entry.range = { entry.range.begin(), static_cast<unsigned>(m_lexer.currentTokenEnd() - m_lexer.start()) };
                    lastValueRange = WTF::move(entry);
                }
            }
            m_lexer.next();
            lastValue = m_objectStack.takeLast();
            break;
        }
        startParseObject:
        case StartParseObject: {
            JSObject* object = constructEmptyObject(m_globalObject);
            if constexpr (reviverMode == JSONReviverMode::Enabled) {
                if (sourceRanges) {
                    if (m_rangesStack.size() >= maximumRangesStackRecursion) [[unlikely]]
                        return throwStackOverflowError(m_globalObject, scope);

                    unsigned startOffset = static_cast<unsigned>(m_lexer.currentTokenStart() - m_lexer.start());
                    m_rangesStack.append({
                        sourceRanges->record(object),
                        WTF::Range<unsigned> { startOffset },
                        JSONRanges::Object { }
                    });
                }
            }

            TokenType type = m_lexer.next();
            if (type == TokString || (m_mode != StrictJSON && type == TokIdentifier)) {
                while (true) {
                    Identifier ident = makeIdentifier(vm, m_lexer.currentToken());

                    if (m_lexer.next() != TokColon) [[unlikely]] {
                        setErrorMessageForToken(TokColon);
                        return { };
                    }

                    TokenType nextType = m_lexer.next();
                    if (nextType == TokLBrace || nextType == TokLBracket) {
                        m_objectStack.appendWithCrashOnOverflow(object);
                        m_identifierStack.append(WTF::move(ident));
                        m_stateStack.append(DoParseObjectEndExpression);
                        if (nextType == TokLBrace)
                            goto startParseObject;
                        ASSERT(nextType == TokLBracket);
                        goto startParseArray;
                    }

                    // Leaf object construction fast path.
                    WTF::Range<unsigned> propertyRange {
                        static_cast<unsigned>(m_lexer.currentTokenStart() - m_lexer.start()),
                        static_cast<unsigned>(m_lexer.currentTokenEnd() - m_lexer.start())
                    };
                    JSValue primitive = parsePrimitiveValue(vm);
                    if (!primitive) [[unlikely]]
                        return { };

                    if (m_mode != StrictJSON && ident == vm.propertyNames->underscoreProto) [[unlikely]] {
                        ASSERT(!sourceRanges);
                        if (!m_visitedUnderscoreProto.add(object).isNewEntry) [[unlikely]] {
                            m_parseErrorMessage = "Attempted to redefine __proto__ property"_s;
                            return { };
                        }
                        PutPropertySlot slot(object, m_nullOrCodeBlock && m_nullOrCodeBlock->ownerExecutable()->isInStrictContext());
                        JSValue(object).put(m_globalObject, ident, primitive, slot);
                        RETURN_IF_EXCEPTION(scope, { });
                    } else {
                        if (std::optional<uint32_t> index = parseIndex(ident)) {
                            object->putDirectIndex(m_globalObject, index.value(), primitive);
                            RETURN_IF_EXCEPTION(scope, { });
                        } else
                            object->putDirect(vm, ident, primitive);

                        if constexpr (reviverMode == JSONReviverMode::Enabled) {
                            if (sourceRanges) {
                                std::get<JSONRanges::Object>(m_rangesStack.last().properties).set(
                                    ident.impl(),
                                    JSONRanges::Entry {
                                        sourceRanges->record(primitive),
                                        propertyRange,
                                        { }
                                    });
                            }
                        }
                    }

                    if (m_lexer.currentToken()->type != TokComma)
                        break;

                    nextType = m_lexer.next();
                    if (nextType != TokString && (m_mode == StrictJSON || nextType != TokIdentifier)) [[unlikely]] {
                        m_parseErrorMessage = "Property name must be a string literal"_s;
                        return { };
                    }
                }

                if (m_lexer.currentToken()->type != TokRBrace) [[unlikely]] {
                    setErrorMessageForToken(TokRBrace);
                    return { };
                }

                if constexpr (reviverMode == JSONReviverMode::Enabled) {
                    if (sourceRanges) {
                        auto entry = m_rangesStack.takeLast();
                        entry.range = { entry.range.begin(), static_cast<unsigned>(m_lexer.currentTokenEnd() - m_lexer.start()) };
                        lastValueRange = WTF::move(entry);
                    }
                }
                m_lexer.next();
                lastValue = object;
                break;
            }

            if (type != TokRBrace) [[unlikely]] {
                setErrorMessageForToken(TokRBrace);
                return { };
            }

            if constexpr (reviverMode == JSONReviverMode::Enabled) {
                if (sourceRanges) {
                    auto entry = m_rangesStack.takeLast();
                    entry.range = { entry.range.begin(), static_cast<unsigned>(m_lexer.currentTokenEnd() - m_lexer.start()) };
                    lastValueRange = WTF::move(entry);
                }
            }
            m_lexer.next();
            lastValue = object;
            break;
        }
        doParseObjectStartExpression:
        case DoParseObjectStartExpression: {
            TokenType type = m_lexer.next();
            if (type != TokString && (m_mode == StrictJSON || type != TokIdentifier)) [[unlikely]] {
                m_parseErrorMessage = "Property name must be a string literal"_s;
                return { };
            }
            m_identifierStack.append(makeIdentifier(vm, m_lexer.currentToken()));

            // Check for colon
            if (m_lexer.next() != TokColon) [[unlikely]] {
                setErrorMessageForToken(TokColon);
                return { };
            }

            m_lexer.next();
            m_stateStack.append(DoParseObjectEndExpression);
            goto startParseExpression;
        }
        case DoParseObjectEndExpression:
        {
            JSObject* object = asObject(m_objectStack.last());
            Identifier ident = m_identifierStack.takeLast();
            if (m_mode != StrictJSON && ident == vm.propertyNames->underscoreProto) [[unlikely]] {
                ASSERT(!sourceRanges);
                if (!m_visitedUnderscoreProto.add(object).isNewEntry) [[unlikely]] {
                    m_parseErrorMessage = "Attempted to redefine __proto__ property"_s;
                    return { };
                }
                PutPropertySlot slot(object, m_nullOrCodeBlock && m_nullOrCodeBlock->ownerExecutable()->isInStrictContext());
                JSValue(object).put(m_globalObject, ident, lastValue, slot);
                RETURN_IF_EXCEPTION(scope, { });
            } else {
                if (std::optional<uint32_t> index = parseIndex(ident)) {
                    object->putDirectIndex(m_globalObject, index.value(), lastValue);
                    RETURN_IF_EXCEPTION(scope, { });
                } else
                    object->putDirect(vm, ident, lastValue);

                if constexpr (reviverMode == JSONReviverMode::Enabled) {
                    if (sourceRanges)
                        std::get<JSONRanges::Object>(m_rangesStack.last().properties).set(ident.impl(), WTF::move(lastValueRange));
                }
            }
            if (m_lexer.currentToken()->type == TokComma)
                goto doParseObjectStartExpression;
            if (m_lexer.currentToken()->type != TokRBrace) [[unlikely]] {
                setErrorMessageForToken(TokRBrace);
                return { };
            }

            if constexpr (reviverMode == JSONReviverMode::Enabled) {
                if (sourceRanges) {
                    auto entry = m_rangesStack.takeLast();
                    entry.range = { entry.range.begin(), static_cast<unsigned>(m_lexer.currentTokenEnd() - m_lexer.start()) };
                    lastValueRange = WTF::move(entry);
                }
            }
            m_lexer.next();
            lastValue = m_objectStack.takeLast();
            break;
        }
        startParseExpression:
        case StartParseExpression: {
            TokenType type = m_lexer.currentToken()->type;
            if (type == TokLBracket)
                goto startParseArray;
            if (type == TokLBrace)
                goto startParseObject;

            if constexpr (reviverMode == JSONReviverMode::Enabled) {
                if (sourceRanges) {
                    lastValueRange = JSONRanges::Entry {
                        JSValue(),
                        {
                            static_cast<unsigned>(m_lexer.currentTokenStart() - m_lexer.start()),
                            static_cast<unsigned>(m_lexer.currentTokenEnd() - m_lexer.start())
                        },
                        { }
                    };
                }
            }
            lastValue = parsePrimitiveValue(vm);
            if (!lastValue) [[unlikely]]
                return { };
            if constexpr (reviverMode == JSONReviverMode::Enabled) {
                if (sourceRanges)
                    lastValueRange.value = sourceRanges->record(lastValue);
            }
            break;
        }
        case StartParseStatement: {
            ASSERT(!sourceRanges);
            switch (m_lexer.currentToken()->type) {
            case TokLBracket:
            case TokNumber:
            case TokNumberInt32:
            case TokString: {
                lastValue = parsePrimitiveValue(vm);
                if (!lastValue) [[unlikely]]
                    return { };
                break;
            }

            case TokLParen: {
                m_lexer.next();
                m_stateStack.append(StartParseStatementEndStatement);
                goto startParseExpression;
            }
            case TokRBracket:
                m_parseErrorMessage = "Unexpected token ']'"_s;
                return { };
            case TokLBrace:
                m_parseErrorMessage = "Unexpected token '{'"_s;
                return { };
            case TokRBrace:
                m_parseErrorMessage = "Unexpected token '}'"_s;
                return { };
            case TokIdentifier:
                m_parseErrorMessage = "Unexpected identifier"_s;
                return { };
            case TokColon:
                m_parseErrorMessage = "Unexpected token ':'"_s;
                return { };
            case TokRParen:
                m_parseErrorMessage = "Unexpected token ')'"_s;
                return { };
            case TokComma:
                m_parseErrorMessage = "Unexpected token ','"_s;
                return { };
            case TokTrue:
                m_parseErrorMessage = "Unexpected token 'true'"_s;
                return { };
            case TokFalse:
                m_parseErrorMessage = "Unexpected token 'false'"_s;
                return { };
            case TokNull:
                m_parseErrorMessage = "Unexpected token 'null'"_s;
                return { };
            case TokEnd:
                m_parseErrorMessage = "Unexpected EOF"_s;
                return { };
            case TokDot:
                m_parseErrorMessage = "Unexpected token '.'"_s;
                return { };
            case TokAssign:
                m_parseErrorMessage = "Unexpected token '='"_s;
                return { };
            case TokSemi:
                m_parseErrorMessage = "Unexpected token ';'"_s;
                return { };
            case TokError:
            default:
                m_parseErrorMessage = "Could not parse statement"_s;
                return { };
            }
            break;
        }
        case StartParseStatementEndStatement: {
            ASSERT(!sourceRanges);
            ASSERT(m_stateStack.isEmpty());
            if (m_lexer.currentToken()->type != TokRParen)
                return { };
            if (m_lexer.next() == TokEnd)
                return lastValue;
            m_parseErrorMessage = "Unexpected content at end of JSON literal"_s;
            return { };
        }
        default:
            RELEASE_ASSERT_NOT_REACHED();
        }
        if (m_stateStack.isEmpty()) {
            if constexpr (reviverMode == JSONReviverMode::Enabled) {
                if (sourceRanges)
                    sourceRanges->setRoot(WTF::move(lastValueRange));
            }
            return lastValue;
        }
        state = m_stateStack.takeLast();
        continue;
    }
}

#if JSC_SUPPORTS_SWIFT

// MARK: - The object-model facade the Swift grammar builds through
//
// Declared in LiteralParserSwiftTypes.h, which has the reasons the interface is not one
// that hands `JSValue`s to Swift. The rule this file enforces: no cell ever leaves here.
// Swift holds a `JSONSwiftObjectModel*` and nothing else, and every cell lives either in
// the state below — whose container stack and element buffer the conservative stack scan
// finds, the state itself being a local of `parseJSONWithSwiftIsland` — or in a local of
// one of these functions.

struct JSONSwiftObjectModelState {
    // Every cell this holds is rooted by the conservative stack scan and nothing else, so
    // it has to be on a stack. Machine-checked rather than left to the comment on
    // `containers`, which is the argument that depends on it.
    WTF_FORBID_HEAP_ALLOCATION;
public:

    JSONSwiftObjectModelState(VM& vm, JSGlobalObject* globalObject,
        std::span<const char16_t> input, String* errorMessage)
        : vm(vm)
        , globalObject(globalObject)
        , input16(input)
        , errorMessage(errorMessage)
    {
    }

    JSONSwiftObjectModelState(VM& vm, JSGlobalObject* globalObject,
        std::span<const Latin1Character> input, String* errorMessage)
        : vm(vm)
        , globalObject(globalObject)
        , input8(input)
        , is8Bit(true)
        , errorMessage(errorMessage)
    {
    }

    VM& vm;
    JSGlobalObject* globalObject { nullptr };
    // The document, at whichever width it is: exactly one of the two is set. This is
    // everything the island takes from its caller — there is no LiteralParser behind it,
    // which is why the caller does not build one until the island declines.
    std::span<const char16_t> input16;
    std::span<const Latin1Character> input8;
    // Which of the two above is live. Constant for a whole document, so every branch on it
    // is perfectly predicted; it is read once per string, once per property store and once
    // per cold path.
    bool is8Bit { false };

    // The characters of a token, at whichever width this parse is. A template rather
    // than two members so that the store's name handling stays one piece of source.
    template<typename CharType>
    std::span<const CharType> input() const;

    // The open containers, innermost last, with `frames.size()` as the depth: the two are
    // pushed and popped together, so a second count would be the same number twice.
    //
    // Rooted rather than registered: this state is a local of `parseJSONWithSwiftIsland`, so
    // the conservative stack scan finds every cell in here the way it finds any other frame's,
    // and `WTF_FORBID_HEAP_ALLOCATION` above is what machine-checks that the state really is
    // on a stack. A growable container would instead have to register itself in the mark set
    // once it mallocs; the fixed 64 slots remove that case, because the grammar refuses to
    // open a 65th container (`JSONSwiftGrammar.pushContainer`, whose mask is 64 bits wide) and
    // `jsonSwiftPushContainer` bounds the write in release rather than trusting that across
    // the language boundary.
    //
    // Uninitialised on purpose. Slots at or above the depth hold stale or garbage bits,
    // which is what the conservative scanner exists to handle; a stale entry is a cell that
    // was stored into its parent and so is live anyway.
    static constexpr unsigned maxDepth = 64;
    JSObject* containers[maxDepth];
    // Per open container: the next array index, whether it is an object, and the property
    // name waiting for a value. One vector because they are pushed and popped together.
    //
    // The pending key has to be per frame rather than one field on the state, or
    // `{"a":{"b":1}}` loses the outer name to the inner object's `key()` and every object
    // directly inside an object declines — which is invisible, since the C++ re-parse
    // returns the same value.
    //
    // Trivially copyable on purpose, so push and pop stay a store and a decrement: a name
    // is offsets, and the rare escaped one an index into `resolvedKeys`.
    enum class PendingKey : uint8_t { None, Offsets, Resolved };
    struct Frame {
        unsigned nextIndex;
        // PendingKey::Offsets: the name's position in the input.
        uint32_t keyStart;
        uint32_t keyLength;
        // PendingKey::Resolved: one-based index into `resolvedKeys`, 0 for none.
        uint32_t resolvedKeyIndex;
        PendingKey pendingKey;
        bool isObject;
    };
    Vector<Frame, 32> frames;

    // The property names that had to be unescaped, which are not in the input at all and
    // so cannot be offsets. Appended to rather than overwritten, because a cold key can
    // be pending on any number of open frames at once; `takeResolvedKey` moves the entry
    // out, leaving the slot empty.
    Vector<Identifier, 4> resolvedKeys;

    // The completed document, once the outermost container closes — or the single value, for
    // a document that is a bare primitive. Rooted the same way `containers` is: this state is
    // a local of `parseJSONWithSwiftIsland`, so the collector scans it as it scans any frame.
    JSValue result;
    bool hasResult { false };

    // Whether the island stopped because an exception is pending, which is the one
    // reason the C++ must propagate rather than re-parse.
    bool sawException { false };

    // MARK: The diagnostic, for a document the island refused rather than declined
    //
    // The island formats the text and `errorMessage` writes it straight into the caller's
    // `String` — a pointer to it and nothing else, so this costs one null store in the
    // prologue and no destructor, where a `String` member would cost both. A caller that
    // does not want the text (`JSONParse`) passes nothing, and then nothing is built.
    //
    // `hasMessage` is what makes a `Failed` status that produced no text — a range the
    // island's offsets did not bound, or an allocation that failed — decline to the C++
    // re-parse rather than throw an empty syntax error, and it is what implements rule 1's
    // first-writer-wins on this side.
    String* errorMessage { nullptr };
    bool hasErrorMessage { false };

    // MARK: The escaped string's buffer — the island owns the scan, this holds the result
    //
    // The island decodes escapes itself and emits the result as alternating runs of literal
    // input and single decoded units; they land here until the string is complete. A
    // `StringBuilder` and nothing narrower because it owns the 8-bit-to-16-bit upconversion
    // policy, and that policy decides the resulting string's representation: `lexStringSlow`
    // builds an escaped string in one of these too, so a string the island decoded is
    // interned and represented exactly as the C++ path's would be. Splitting the path here is
    // what lets the *scan* — unchecked pointer arithmetic, a hand-rolled five-unit lookahead
    // for `\uNNNN`, and a `goto` into the middle of a do-while — live in Swift over a
    // bounds-checked span, leaving C++ only the call into `StringBuilder`.
    //
    // Built on the first escape rather than with the state, because almost every string in
    // real payloads contains no escape at all and a document with none must not pay for a
    // buffer: it pays one flag store and one not-taken branch in the destructor.
    std::optional<StringBuilder> escapeBuilder;

    // Every entry that touches the buffer goes through this, so a run or a unit arriving
    // without an `escapeBegin` before it is a decline rather than an empty-optional
    // dereference — the same rule as the offsets below: an invariant of the other language is
    // checked, not trusted.
    StringBuilder* escapeBuffer() { return escapeBuilder ? &escapeBuilder.value() : nullptr; }

    void escapeBegin()
    {
        if (escapeBuilder) [[likely]]
            escapeBuilder->clear();
        else
            escapeBuilder.emplace();
    }

    // The island's offsets are bounded by its own cursor, but that is an invariant of the
    // *other* language, and this side turns them into `subspan` and `data() + start`,
    // neither of which checks. So every entry that takes one asserts it.
    // `JSON_ISLAND_CHECKED_LOADS` is the Swift half of the same question.
    bool isValidRange(uint32_t start, uint32_t length) const
    {
        size_t size = is8Bit ? input8.size() : input16.size();
        return static_cast<size_t>(start) + static_cast<size_t>(length) <= size;
    }

    // `parseJSONDouble` for a number outside the island's int32 fast path, which stays in C++
    // and should: it is a correctly-rounded decimal-to-double conversion shared with the rest
    // of WTF. No lexNumberError call — a malformed number makes the island decline, and the
    // C++ parse that then runs from the top produces the message.
    template<typename CharType>
    bool parseDouble(uint32_t initial, double& value, ptrdiff_t& endOffset) const
    {
        auto characters = input<CharType>();
        ASSERT(initial <= characters.size());
        size_t parsedLength = 0;
        auto parsed = WTF::parseJSONDouble(characters.subspan(initial), parsedLength);
        if (!parsed) [[unlikely]]
            return false;
        value = parsed.value();
        endOffset = static_cast<ptrdiff_t>(initial) + static_cast<ptrdiff_t>(parsedLength);
        return true;
    }

    // The property name for a cold key, whose characters are not in the input. The fast
    // path resolves the common case from `keyStart`/`keyLength` itself, inside the store,
    // so this is only the unescaped case.
    Identifier takeResolvedKey(Frame& frame)
    {
        ASSERT(frame.pendingKey == PendingKey::Resolved);
        ASSERT(frame.resolvedKeyIndex);
        frame.pendingKey = PendingKey::None;
        return WTF::move(resolvedKeys[frame.resolvedKeyIndex - 1]);
    }

    // MARK: An escaped string's value and name, made out of the buffer
    //
    // The island decoded the escapes itself, so there is no token: the characters are in the
    // buffer above and nowhere else. That is the lifetime improvement over the C++ path,
    // which puts a raw pointer to them in the token and relies on nobody lexing another cold
    // string before it is read. Here the buffer becomes a cell in one step, and no pointer to
    // it exists on either side.
    //
    // `makeJSString` and `makeIdentifier` on the atom-string cache, exactly as
    // `LiteralParser::makeJSString` reaches them for a token whose characters `lexStringSlow`
    // left in its own builder, so the interning is identical.

    JSString* adoptEscapedString()
    {
        StringBuilder* builder = escapeBuffer();
        if (!builder) [[unlikely]]
            return nullptr;
        return builder->is8Bit()
            ? vm.jsonAtomStringCache.makeJSString(builder->span8())
            : vm.jsonAtomStringCache.makeJSString(builder->span16());
    }

    bool adoptEscapedKey()
    {
        StringBuilder* builder = escapeBuffer();
        if (!builder) [[unlikely]]
            return false;
        if (frames.isEmpty()) [[unlikely]]
            return false;
        Identifier resolved = builder->is8Bit()
            ? Identifier::fromString(vm, vm.jsonAtomStringCache.makeIdentifier(builder->span8()))
            : Identifier::fromString(vm, vm.jsonAtomStringCache.makeIdentifier(builder->span16()));
        resolvedKeys.append(WTF::move(resolved));
        Frame& frame = frames.last();
        frame.resolvedKeyIndex = resolvedKeys.size();
        frame.pendingKey = PendingKey::Resolved;
        return true;
    }
};

template<>
ALWAYS_INLINE std::span<const char16_t> JSONSwiftObjectModelState::input<char16_t>() const
{
    ASSERT(!is8Bit);
    return input16;
}

template<>
ALWAYS_INLINE std::span<const Latin1Character> JSONSwiftObjectModelState::input<Latin1Character>() const
{
    ASSERT(is8Bit);
    return input8;
}

namespace {

// `LiteralParser::equalIdentifier` (:159) against a span rather than a token, since the
// facade's property name is offsets into the input. Templated on the width rather than
// duplicated: `WTF::equal` and the atom-string cache have both overloads already.
template<typename CharType>
ALWAYS_INLINE bool jsonSwiftEqualIdentifier(UniquedStringImpl* rep, std::span<const CharType> name)
{
    // As there: a transition to a symbol-named property must not be followed.
    if (rep->isSymbol())
        return false;
    return WTF::equal(rep, name);
}

// `parseRecursively`'s four-operation store (:1644), and the reason the facade is shaped
// this way rather than as primitives Swift drives: between `nukeStructureAndSetButterfly`
// and `setStructure` the object's StructureID is nuked, and a conservatively-scanned cell
// in that state is a release-mode `die()` (heap/SlotVisitor.cpp:188). Here the whole
// sequence is one C++ call with no Swift frame in it.
ALWAYS_INLINE bool jsonSwiftStoreToExistingProperty(JSONSwiftObjectModelState& state,
    JSObject* object, Structure* originalStructure, Structure* newStructure,
    PropertyOffset offset, JSValue value)
{
    VM& vm = state.vm;
    if (originalStructure->outOfLineCapacity() != newStructure->outOfLineCapacity()) {
        ASSERT(newStructure != originalStructure);
        Butterfly* newButterfly = object->allocateMoreOutOfLineStorage(vm,
            originalStructure->outOfLineCapacity(), newStructure->outOfLineCapacity());
        object->nukeStructureAndSetButterfly(vm, originalStructure->id(), newButterfly);
    }

    validateOffset(offset);
    ASSERT(newStructure->isValidOffset(offset));
    // As in parseRecursively: this is what says the concurrent GC cannot read garbage from
    // a put that does not transition.
    ASSERT(!object->getDirect(offset) || !JSValue::encode(object->getDirect(offset)));
    object->putDirectOffset(vm, offset, value);
    object->setStructure(vm, newStructure);
    ASSERT(!newStructure->mayBePrototype()); // There is no way to make it prototype object.
    return true;
}

// The general store, for a name that did not resolve to an existing transition. No
// `__proto__` handling, and that is not an omission: `parseRecursively`'s
// `m_visitedUnderscoreProto` path is guarded by `parserMode != StrictJSON`, and a strict
// JSON value cannot run user code.
ALWAYS_INLINE bool jsonSwiftStoreWithIdentifier(JSONSwiftObjectModelState& state,
    JSObject* object, const Identifier& ident, JSValue value)
{
    auto scope = DECLARE_THROW_SCOPE(state.vm);
    if (std::optional<uint32_t> index = parseIndex(ident)) {
        object->putDirectIndex(state.globalObject, index.value(), value);
        RETURN_IF_EXCEPTION(scope, (state.sawException = true, false));
    } else
        object->putDirect(state.vm, ident, value);
    return true;
}

// The object half of the store, deliberately out of line and shared. It reaches WTF::equal,
// the atom-string cache's hashing, the transition table lookup, parseIndex and putDirect's
// structure machinery — a few hundred instructions — and every facade entry funnels through
// it, so it must not be inlined: that puts a copy in each of intValue, doubleValue,
// literalValue, stringValue and endContainer, where for an array element all of it is dead
// and only its register pressure is real.
//
// Templated on the width and dispatched once at the bottom of this file. The only
// width-dependent thing in it is the name span, so this is one branch per store, on a flag
// constant for the whole document, against two copies of a few hundred instructions.
template<typename CharType>
NEVER_INLINE bool jsonSwiftStorePropertyValueImpl(JSONSwiftObjectModelState& state,
    JSObject* container, JSValue value)
{
    auto scope = DECLARE_THROW_SCOPE(state.vm);
    {
        using PendingKey = JSONSwiftObjectModelState::PendingKey;
        // The frame of the object being stored into, which is the innermost one: a nested
        // container has already popped its own by the time `endContainer` gets here.
        if (state.frames.isEmpty()) [[unlikely]]
            return false;
        auto& frame = state.frames.last();
        if (frame.pendingKey == PendingKey::None) [[unlikely]]
            return false;

        if (frame.pendingKey != PendingKey::Offsets) [[unlikely]] {
            // An unescaped name: already an Identifier, because the characters were in the
            // lexer's StringBuilder rather than in the input. It skips the resolution fast
            // path, which wants a span to hash.
            RELEASE_AND_RETURN(scope, jsonSwiftStoreWithIdentifier(state, container,
                state.takeResolvedKey(frame), value));
        }

        // `parseRecursively`'s three-way property resolution (:1576). The C++ has to
        // resolve the name *before* parsing the value, its token being transient; the
        // facade holds the name as offsets, which stay valid, so resolution and the store
        // are adjacent and there is no window between them at all.
        std::span<const CharType> name =
            state.input<CharType>().subspan(frame.keyStart, frame.keyLength);
        frame.pendingKey = PendingKey::None;
        VM& vm = state.vm;
        Structure* originalStructure = container->structure();

        if (Structure* transition = originalStructure->trySingleTransition()) {
            // Avoids a hash lookup and refcount churn in the common case of a matching
            // single transition — same-shaped objects, which is what JSON is full of.
            SUPPRESS_UNCOUNTED_ARG if (transition->transitionKind() == TransitionKind::PropertyAddition
                && !transition->transitionPropertyAttributes()
                && jsonSwiftEqualIdentifier(transition->transitionPropertyName(), name)) {
                return jsonSwiftStoreToExistingProperty(state, container, originalStructure,
                    transition, transition->transitionOffset(), value);
            }
        } else if (!originalStructure->isDictionary()) {
            // Avoids refcount churn in the common case of a cached Identifier.
            if (SUPPRESS_UNCOUNTED_LOCAL AtomStringImpl* ident = vm.jsonAtomStringCache.existingIdentifier(name)) {
                PropertyOffset offset = 0;
                Structure* newStructure = Structure::addPropertyTransitionToExistingStructure(originalStructure, ident, 0, offset);
                if (newStructure) [[likely]] {
                    return jsonSwiftStoreToExistingProperty(state, container,
                        originalStructure, newStructure, offset, value);
                }
                RELEASE_AND_RETURN(scope, jsonSwiftStoreWithIdentifier(state, container,
                    Identifier::fromString(vm, ident), value));
            }
        }

        RELEASE_AND_RETURN(scope, jsonSwiftStoreWithIdentifier(state, container,
            Identifier::fromString(vm, vm.jsonAtomStringCache.makeIdentifier(name)), value));
    }
}

// The width dispatch. `NEVER_INLINE` on both this and the two instantiations, so a facade
// entry still pays one call and not two copies of the store: this tail-calls.
NEVER_INLINE bool jsonSwiftStorePropertyValue(JSONSwiftObjectModelState& state,
    JSObject* container, JSValue value)
{
    if (state.is8Bit)
        return jsonSwiftStorePropertyValueImpl<Latin1Character>(state, container, value);
    return jsonSwiftStorePropertyValueImpl<char16_t>(state, container, value);
}

// The array append, written out rather than left to `putDirectIndex`, whose fast path
// calls `JSObject::setIndexQuickly` — a function clang will not inline, because it also
// carries the typed-array, array-storage, undecided and conversion arms. So going through
// it costs a `bl setIndexQuickly` per array element where `parseRecursively` pays nothing,
// its store being inlined into a frame spanning the whole array loop.
//
// This is `setIndexQuickly`'s fast case for the three writable contiguous-family shapes an
// array of JSON values takes, and nothing else. Everything unusual declines to
// `putDirectIndex` and reaches the same code as before: an index past the vector, the
// undecided shape (every array's first element), copy-on-write, array storage, a
// non-`JSArray` container, and a value the shape cannot hold, which is a conversion.
ALWAYS_INLINE bool jsonSwiftFastArrayAppend(VM& vm, JSObject* array, unsigned index,
    JSValue value)
{
    // `indexingMode()` masks in the copy-on-write bit and masks out the cell lock bits and
    // the indexed-accessor history, which is exactly the set `putDirectIndex` switches on.
    // The `IsArray` bit is in these constants and the island's array containers all come
    // from `constructEmptyArray`, so a `NonArrayWith*` shape declining costs nothing.
    switch (array->indexingMode()) {
    case ArrayWithInt32: {
        if (!value.isInt32()) [[unlikely]]
            return false;
        Butterfly* butterfly = array->butterfly();
        if (index >= butterfly->vectorLength()) [[unlikely]]
            return false;
        butterfly->contiguous().at(array, index).setWithoutWriteBarrier(value);
        if (index >= butterfly->publicLength())
            butterfly->setPublicLength(index + 1);
        // No write barrier, and that is not an omission: `setIndexQuickly` reaches its
        // `vm.writeBarrier(this, v)` for an int32 array by falling through to the
        // contiguous case, and the barrier returns immediately for a non-cell value.
        return true;
    }
    case ArrayWithContiguous: {
        Butterfly* butterfly = array->butterfly();
        if (index >= butterfly->vectorLength()) [[unlikely]]
            return false;
        butterfly->contiguous().at(array, index).setWithoutWriteBarrier(value);
        if (index >= butterfly->publicLength())
            butterfly->setPublicLength(index + 1);
        vm.writeBarrier(array, value);
        return true;
    }
    case ArrayWithDouble: {
        if (!value.isNumber()) [[unlikely]]
            return false;
        double number = value.asNumber();
        // A NaN in a double array is how a hole reads, so `setIndexQuickly` converts to
        // contiguous instead of storing it. JSON cannot spell NaN, but `jsNumber` is not
        // told that, so the check stays where the original had it.
        if (number != number) [[unlikely]]
            return false;
        Butterfly* butterfly = array->butterfly();
        if (index >= butterfly->vectorLength()) [[unlikely]]
            return false;
        butterfly->contiguousDouble().at(array, index) = number;
        if (index >= butterfly->publicLength())
            butterfly->setPublicLength(index + 1);
        return true;
    }
    default:
        return false;
    }
}

// The property store's fast half: a structure with exactly one recorded transition that
// adds an unattributed property whose name is the one being stored, which is what a run of
// same-shaped objects hits. Everything else tail-calls the general store above and reaches
// identical code. It declines an escaped name, a transition *table*, a dictionary, a
// symbol-named transition, a name that does not match, and the property that first spills out
// of inline storage.
//
// It must stay out of line. `parseRecursively` pays the general store's prologue once per
// container, while the island pays one function entry per property, which is why this fast
// half exists at all; marking it ALWAYS_INLINE would put a copy of it in each of five facade
// entries, and that loses more on documents that never store a property than it wins where it
// fires.
//
// The condition is `isInlineOffset` rather than the general store's capacity compare: one
// compare against a constant, and it keeps the butterfly reallocation behind the decline,
// so the window in which the object's StructureID is nuked — a release-mode `die()` if the
// collector scans it (heap/SlotVisitor.cpp:188) — stays where it already was. Below
// `firstOutOfLineOffset` both sides have no out-of-line slots, so equal capacity is implied and
// the reallocation provably cannot be the skipped branch; the ASSERT below states that.
NEVER_INLINE bool jsonSwiftStorePropertyValueFast(JSONSwiftObjectModelState& state,
    JSObject* object, JSValue value)
{
    using PendingKey = JSONSwiftObjectModelState::PendingKey;
    if (state.frames.isEmpty()) [[unlikely]]
        return false;
    auto& frame = state.frames.last();
    if (frame.pendingKey != PendingKey::Offsets) [[unlikely]]
        return jsonSwiftStorePropertyValue(state, object, value);

    Structure* originalStructure = object->structure();
    Structure* transition = originalStructure->trySingleTransition();
    if (!transition) [[unlikely]]
        return jsonSwiftStorePropertyValue(state, object, value);
    if (transition->transitionKind() != TransitionKind::PropertyAddition
        || transition->transitionPropertyAttributes()) [[unlikely]]
        return jsonSwiftStorePropertyValue(state, object, value);

    PropertyOffset offset = transition->transitionOffset();
    if (!isInlineOffset(offset)) [[unlikely]]
        return jsonSwiftStorePropertyValue(state, object, value);

    // The one width-dependent step: the name is offsets into the input, so comparing it
    // names a character. The branch is on a flag that is constant for the whole document.
    SUPPRESS_UNCOUNTED_ARG bool nameMatches = state.is8Bit
        ? jsonSwiftEqualIdentifier(transition->transitionPropertyName(),
            state.input8.subspan(frame.keyStart, frame.keyLength))
        : jsonSwiftEqualIdentifier(transition->transitionPropertyName(),
            state.input16.subspan(frame.keyStart, frame.keyLength));
    if (!nameMatches)
        return jsonSwiftStorePropertyValue(state, object, value);

    frame.pendingKey = PendingKey::None;
    validateOffset(offset);
    ASSERT(transition->isValidOffset(offset));
    ASSERT(transition->outOfLineCapacity() == originalStructure->outOfLineCapacity());
    // As in `jsonSwiftStoreToExistingProperty`: what says the concurrent GC cannot read
    // garbage from a put that does not transition.
    ASSERT(!object->getDirect(offset) || !JSValue::encode(object->getDirect(offset)));
    object->putDirectOffset(state.vm, offset, value);
    object->setStructure(state.vm, transition);
    ASSERT(!transition->mayBePrototype()); // There is no way to make it prototype object.
    return true;
}

// What is left inline: the empty check, which container this is, and the array append
// above.
ALWAYS_INLINE bool jsonSwiftStoreValue(JSONSwiftObjectModelState& state, JSValue value)
{
    if (state.frames.isEmpty()) [[unlikely]] {
        // A document that is a bare primitive — `1`, `"x"`, `true` — which the grammar
        // reaches here exactly once, before any container has opened. Recorded as the
        // result rather than declined, because a decline costs the document twice: the
        // island lexes the number, gives up, and the C++ lexes it again from offset zero.
        //
        // Trailing content is still rejected, by the grammar rather than here: at depth 0
        // the position after a value is `.documentEnd`, which accepts nothing but the end
        // token. A second value therefore cannot reach this, and the guard below is for
        // the invariant rather than for a reachable input.
        if (state.hasResult) [[unlikely]]
            return false;
        state.result = value;
        state.hasResult = true;
        return true;
    }

    auto& frame = state.frames.last();
    JSObject* container = state.containers[state.frames.size() - 1];
    if (frame.isObject)
        return jsonSwiftStorePropertyValueFast(state, container, value);

    unsigned index = frame.nextIndex++;
    // Nothing on this path can throw or allocate, so the throw scope is declared below it
    // rather than around it.
    if (jsonSwiftFastArrayAppend(state.vm, container, index, value)) [[likely]]
        return true;

    auto scope = DECLARE_THROW_SCOPE(state.vm);
    container->putDirectIndex(state.globalObject, index, value);
    RETURN_IF_EXCEPTION(scope, (state.sawException = true, false));
    return true;
}

// `isObject` comes from the caller rather than from `container->inherits<JSArray>()`: the
// grammar knows which bracket it lexed, so asking the cell would re-derive at run time
// something the call site has as a constant, once per container.
ALWAYS_INLINE bool jsonSwiftPushContainer(JSONSwiftObjectModelState& state,
    JSObject* container, bool isObject)
{
    if (!container) [[unlikely]] {
        state.sawException = true;
        return false;
    }
    // The grammar refuses a 65th container, so this is a bound on a Swift-side invariant
    // rather than a reachable path — but it is the write into a fixed-size array, and one
    // compare against a constant is what makes this side's memory safety independent of the
    // other language's. `sawException` stays false, so the document is re-parsed in C++.
    size_t depth = state.frames.size();
    if (depth >= JSONSwiftObjectModelState::maxDepth) [[unlikely]]
        return false;
    state.containers[depth] = container;
    // One append and one removeLast per container rather than two: the index counter, the
    // object flag and the pending property name are per-frame state and travel together.
    // The new frame starts with no pending key, which is what leaves the *parent's* name
    // intact while a nested container is built.
    state.frames.append(JSONSwiftObjectModelState::Frame {
        0, 0, 0, 0, JSONSwiftObjectModelState::PendingKey::None, isObject });
    return true;
}

} // namespace

// The eight hot value entries below are always-inline so that an LTO build folds them into
// the island's grammar loop, which is the shape `parseRecursively` has: a prologue once per
// *container* rather than one per *value*. That is worth most on punctuation-dense input, the
// input with the most facade calls per byte; LTO alone folds only `key`, the one entry small
// enough for the cost model. Without LTO nothing here can inline them — the island is their
// only caller — so the island's entry point is bit-identical either way.
//
// Spelled out rather than ALWAYS_INLINE because that macro also supplies `inline`, and
// these must keep emitting an out-of-line symbol for Swift to odr-use from its own
// translation unit. The store is deliberately left out: it stays NEVER_INLINE, so what
// folds in is each entry's prologue and the array path, not eight copies of the store.
#define JSC_JSON_FACADE_ENTRY __attribute__((__always_inline__))

JSC_JSON_FACADE_ENTRY bool JSONSwiftObjectModel::beginObject()
{
    auto& state = *m_state;
    auto scope = DECLARE_THROW_SCOPE(state.vm);
    JSObject* object = constructEmptyObject(state.globalObject);
    RETURN_IF_EXCEPTION(scope, (state.sawException = true, false));
    return jsonSwiftPushContainer(state, object, true);
}

JSC_JSON_FACADE_ENTRY bool JSONSwiftObjectModel::beginArray()
{
    auto& state = *m_state;
    auto scope = DECLARE_THROW_SCOPE(state.vm);
    JSArray* array = constructEmptyArray(state.globalObject, nullptr);
    RETURN_IF_EXCEPTION(scope, (state.sawException = true, false));
    return jsonSwiftPushContainer(state, array, false);
}

JSC_JSON_FACADE_ENTRY bool JSONSwiftObjectModel::endContainer()
{
    auto& state = *m_state;
    size_t depth = state.frames.size();
    if (!depth) [[unlikely]]
        return false;

    JSObject* finished = state.containers[depth - 1];
    state.frames.removeLast();
    if (depth == 1) {
        // The document is complete. `finished` is unrooted between here and the return, as
        // it is on every path below, which is sound for the same reason the stack above is:
        // this is a local of a frame the collector scans.
        state.result = finished;
        state.hasResult = true;
        return true;
    }
    return jsonSwiftStoreValue(state, finished);
}

JSC_JSON_FACADE_ENTRY bool JSONSwiftObjectModel::key(uint32_t start, uint32_t length)
{
    auto& state = *m_state;
    // The name belongs to the object currently being filled, which is the innermost open
    // container. The grammar only reaches a key position inside an object, so the emptiness
    // test is defensive rather than reachable.
    if (state.frames.isEmpty()) [[unlikely]]
        return false;
    ASSERT(state.isValidRange(start, length));
    auto& frame = state.frames.last();
    frame.pendingKey = JSONSwiftObjectModelState::PendingKey::Offsets;
    frame.keyStart = start;
    frame.keyLength = length;
    return true;
}

JSC_JSON_FACADE_ENTRY bool JSONSwiftObjectModel::stringValue(uint32_t start, uint32_t length)
{
    auto& state = *m_state;
    auto scope = DECLARE_THROW_SCOPE(state.vm);
    ASSERT(state.isValidRange(start, length));
    // The same cache `makeJSString` uses (LiteralParser.cpp:196-200), so the island's
    // strings are interned identically to the C++ path's — and identically at both
    // widths, since the cache is templated on the character type and an 8-bit document
    // produces 8-bit `JSString`s exactly as the C++ parse would.
    JSString* string = state.is8Bit
        ? state.vm.jsonAtomStringCache.makeJSString(
            state.input<Latin1Character>().subspan(start, length))
        : state.vm.jsonAtomStringCache.makeJSString(
            state.input<char16_t>().subspan(start, length));
    RETURN_IF_EXCEPTION(scope, (state.sawException = true, false));
    return jsonSwiftStoreValue(state, string);
}

JSC_JSON_FACADE_ENTRY bool JSONSwiftObjectModel::intValue(int32_t value)
{
    return jsonSwiftStoreValue(*m_state, jsNumber(value));
}

JSC_JSON_FACADE_ENTRY bool JSONSwiftObjectModel::doubleValue(double value)
{
    return jsonSwiftStoreValue(*m_state, jsNumber(value));
}

JSC_JSON_FACADE_ENTRY bool JSONSwiftObjectModel::literalValue(uint8_t code)
{
    // A JSONTokenType raw value, which is a TokenType value: the two numberings are
    // asserted equal above.
    //
    // One entry switching on the code rather than a `trueValue`/`falseValue`/`nullValue`
    // trio, which would fold this dispatch at the three call sites that each know their
    // constant. The trade is not the dispatch, it is the duplication: this entry is
    // always-inline and `jsonSwiftStoreValue` is too, so three entries would put three copies
    // of the store's inline body into the grammar loop where there is now one, and the loop's
    // size is what empty-container and punctuation-dense documents charge for.
    JSValue value;
    switch (code) {
    case TokTrue:
        value = jsBoolean(true);
        break;
    case TokFalse:
        value = jsBoolean(false);
        break;
    case TokNull:
        value = jsNull();
        break;
    default:
        return false;
    }
    return jsonSwiftStoreValue(*m_state, value);
}

// MARK: - The one cold path reached from inside the grammar loop
//
// Declared in LiteralParserSwiftTypes.h, which has the reason resolution and the store are
// fused. It does its C++ work on the island's own state — there is no LiteralParser here to
// borrow one from — and only says where the island's cursor resumes. It dispatches on the
// width rather than on a token type.

static bool islandParseDouble(JSONSwiftObjectModelState& state, uint32_t initial,
    double& value, ptrdiff_t& endOffset)
{
    ASSERT(state.isValidRange(initial, 0));
    return state.is8Bit
        ? state.parseDouble<Latin1Character>(initial, value, endOffset)
        : state.parseDouble<char16_t>(initial, value, endOffset);
}

JSONSwiftColdResult JSONSwiftObjectModel::slowNumberValue(uint32_t initial)
{
    auto& state = *m_state;
    double value = 0;
    ptrdiff_t endOffset = 0;
    // No lexNumberError call: a malformed number makes the island decline, and the C++
    // parse that then runs from the top builds the message.
    if (!islandParseDouble(state, initial, value, endOffset))
        return { 0, JSONSwiftParseDeclined };
    if (!jsonSwiftStoreValue(state, jsNumber(value)))
        return { 0, JSONSwiftParseStopped };
    return { endOffset, JSONSwiftParseOK };
}

// MARK: - The escaped-string path the island decodes itself
//
// Declared in LiteralParserSwiftTypes.h, which has the reason the runs cross one at a time
// rather than as a finished buffer. Each of these is a `StringBuilder` call and a range
// assertion; the scan that produces the ranges is in Swift.

bool JSONSwiftObjectModel::escapeBegin()
{
    m_state->escapeBegin();
    return true;
}

bool JSONSwiftObjectModel::escapeRun(uint32_t start, uint32_t length)
{
    auto& state = *m_state;
    StringBuilder* builder = state.escapeBuffer();
    if (!builder) [[unlikely]]
        return false;
    // The one range the island computes that is not bounded by a token it already lexed:
    // it is the span between two escapes. Checked here rather than asserted, because
    // `subspan` does not check.
    if (!state.isValidRange(start, length)) [[unlikely]]
        return false;
    if (state.is8Bit)
        builder->append(state.input<Latin1Character>().subspan(start, length));
    else
        builder->append(state.input<char16_t>().subspan(start, length));
    return true;
}

bool JSONSwiftObjectModel::escapeUnit(uint16_t unit)
{
    StringBuilder* builder = m_state->escapeBuffer();
    if (!builder) [[unlikely]]
        return false;
    // `char16_t` at either width on purpose: this is where a `\uNNNN` above Latin1 forces the
    // builder to 16 bits, which is the policy being kept in C++.
    builder->append(static_cast<char16_t>(unit));
    return true;
}

JSONSwiftColdResult JSONSwiftObjectModel::escapeFinishValue(ptrdiff_t endOffset)
{
    auto& state = *m_state;
    auto scope = DECLARE_THROW_SCOPE(state.vm);
    JSString* string = state.adoptEscapedString();
    RETURN_IF_EXCEPTION(scope, (state.sawException = true,
        JSONSwiftColdResult { 0, JSONSwiftParseStopped }));
    // No buffer to make a string out of, i.e. no `escapeBegin` reached this state. Declines
    // rather than storing a null cell, on the same terms as the range checks.
    if (!string) [[unlikely]]
        return { 0, JSONSwiftParseDeclined };
    if (!jsonSwiftStoreValue(state, string))
        return { 0, JSONSwiftParseStopped };
    return { endOffset, JSONSwiftParseOK };
}

JSONSwiftColdResult JSONSwiftObjectModel::escapeFinishKey(ptrdiff_t endOffset)
{
    auto& state = *m_state;
    auto scope = DECLARE_THROW_SCOPE(state.vm);
    // Resolved here rather than at store time, because the characters live in the builder
    // and the next escaped string clears it. The window is far shorter than the C++ path's,
    // which keeps a raw pointer to them in the token until the value is stored.
    if (!state.adoptEscapedKey())
        return { 0, JSONSwiftParseStopped };
    RETURN_IF_EXCEPTION(scope, (state.sawException = true,
        JSONSwiftColdResult { 0, JSONSwiftParseStopped }));
    return { endOffset, JSONSwiftParseOK };
}

// MARK: - The message the island formatted, made into the caller's `String`
//
// Two ASCII literal parts from the island and a run of the document between them; see the
// declaration in LiteralParserSwiftTypes.h for why the text lives on that side. What is left
// here is the allocation and the bounds check — the whole of what C++ still has to own.
//
// The annotations are repeated from the declaration deliberately: without them this is a
// different type in C++, and the island loses the `Span`-taking overload that keeps its call
// site free of `unsafe`.
void JSONSwiftObjectModel::errorMessage(
    const uint8_t* JSC_SWIFT_COUNTED_BY(prefixLength) JSC_SWIFT_NOESCAPE prefix,
    size_t prefixLength, uint32_t quoteStart, uint32_t quoteLength,
    const uint8_t* JSC_SWIFT_COUNTED_BY(suffixLength) JSC_SWIFT_NOESCAPE suffix,
    size_t suffixLength)
{
    auto& state = *m_state;
    // Nothing to build: this caller throws no syntax error and discards the text, so the
    // parse still reports `Failed` and the C++ lexer still does not run again.
    if (!state.errorMessage)
        return;
    // First writer wins, which is rule 1 in LiteralParserSwiftTypes.h stated on this side as
    // well: a lexer-level diagnostic is formatted before the grammar sees the `.error` token,
    // and `getErrorMessage` would prefer it. The island reports in the same order, so this is
    // a backstop rather than the mechanism.
    if (state.hasErrorMessage) [[unlikely]]
        return;
    // The island's offsets are bounded by its own cursor, but that is an invariant of the
    // other language and `subspan` does not check.
    if (!state.isValidRange(quoteStart, quoteLength)) [[unlikely]]
        return;

    // `Latin1Character` and `uint8_t` are the same type, so the literal parts are 8-bit
    // string pieces and the result is 8-bit unless the quoted run forces otherwise — which
    // is exactly what the C++ parse's `makeString` over the same pieces produced.
    std::span<const Latin1Character> prefixCharacters { prefix, prefixLength };
    std::span<const Latin1Character> suffixCharacters { suffix, suffixLength };
    String message = state.is8Bit
        ? tryMakeString(prefixCharacters,
            state.input<Latin1Character>().subspan(quoteStart, quoteLength), suffixCharacters)
        : tryMakeString(prefixCharacters,
            state.input<char16_t>().subspan(quoteStart, quoteLength), suffixCharacters);
    // An allocation that could not be made leaves the document to the C++ re-parse, which
    // has its own two-step fallback for exactly this (:1324).
    if (!message) [[unlikely]]
        return;
    *state.errorMessage = WTF::move(message);
    state.hasErrorMessage = true;
}

// MARK: - The island's entry point
//
// Builds the state and the facade on its own stack — both ordinary C++ locals, so the
// container stack inside the state is scanned by the collector the way any other frame is —
// hands the island the input, and reads the result out. The input and nothing else: there is
// no `LiteralParser` behind this call, `parseStrictJSON` (LiteralParser.h) building one only
// when this declines. `errorMessage` is where a *failed* parse's diagnostic goes, and it is the
// caller's `String*` rather than a member, so a caller that does not want the text
// (`JSONParse`) passes nothing and nothing is built.

template<typename CharType>
JSValue parseJSONWithSwiftIsland(JSGlobalObject* globalObject,
    std::span<const CharType> characters, bool& handled, String* errorMessage)
{
    handled = false;
    // The island's offsets are 31-bit, which is not a new restriction —
    // LiteralParserToken::stringOrIdentifierLength is `unsigned : 31` — but the
    // island states it as a precondition rather than checking it per token, so it is
    // checked here, once per document.
    if (characters.size() >= (1u << 31)) [[unlikely]]
        return { };

    // One line per width, and nothing else here is width-dependent: the state picks its
    // constructor, the facade is the same class, and the entry point differs only in
    // which specialization of the Swift grammar it names.
    JSONSwiftObjectModelState state(getVM(globalObject), globalObject, characters, errorMessage);
    JSONSwiftObjectModel model(state);

    uint8_t status;
    if constexpr (sizeof(CharType) == 1)
        status = jsonSwiftParseDocument8(characters, model);
    else
        status = jsonSwiftParseDocument16(characters, model);

    if (status == JSONSwiftParseOK && state.hasResult) [[likely]] {
        handled = true;
        return state.result;
    }
    // `OK` without a result cannot happen: the grammar reaches `.documentEnd` only after a
    // value was stored, which is either the outermost container closing or the bare
    // primitive case in `jsonSwiftStoreValue`, and both set this. But `result` would then be
    // the empty JSValue and `handled` would say it was a real answer, so it declines rather
    // than being asserted away, at one compare per document.
    ASSERT(status != JSONSwiftParseOK || state.hasResult);
    if (status == JSONSwiftParseStopped && state.sawException) {
        handled = true;
        return { };
    }

    // Malformed, and the island said which way, so the C++ lexer does not run over the same
    // attacker-chosen bytes a second time. That double lex is what every failing parse used
    // to cost and is the reason this status exists.
    //
    // `hasErrorMessage` is the island's own `errorMessage` call having produced text, and a
    // caller that wanted none is the other way to be handled: either way the message the
    // C++ would have built is not needed. Anything else — an offset that did not bound, an
    // allocation that failed — falls through to the decline, which produces the same text
    // the slow way.
    if (status == JSONSwiftParseFailed && (state.hasErrorMessage || !errorMessage)) {
        handled = true;
        return { };
    }

    // Declined, and there is nothing to undo: the cursor was the island's own, and the
    // half-built object graph is unobservable because no user code can have seen it — this is
    // StrictJSON. The C++ parser the caller builds next starts at offset zero because it has
    // not existed until now.
    //
    // A decline is invisible from the outside — the C++ parse returns the same value, so a
    // validation run passes and a benchmark quietly measures the C++ against itself — so it
    // is logged on request.
    if (Options::verboseSwiftJSONParserDeclines()) [[unlikely]] {
        constexpr size_t prefixLength = 60;
        dataLogLn("JSON island declined (", sizeof(CharType) == 1 ? "8-bit"_s : "16-bit"_s,
            ", status ", status, ", ", characters.size(), " units): ",
            StringView { characters.first(std::min(prefixLength, characters.size())) });
    }
    return { };
}

// The two widths the island covers, instantiated here rather than in the header: its callers
// are the strict-JSON entries in JSONObject.cpp and the two C API ones, all of which parse a
// `JSString`'s characters at whichever width it happens to be.
template JSValue parseJSONWithSwiftIsland<Latin1Character>(JSGlobalObject*,
    std::span<const Latin1Character>, bool&, String*);
template JSValue parseJSONWithSwiftIsland<char16_t>(JSGlobalObject*,
    std::span<const char16_t>, bool&, String*);

#endif // JSC_SUPPORTS_SWIFT

// Instantiate the two flavors of LiteralParser we need instead of putting most of this file in LiteralParser.h
template class LiteralParser<Latin1Character, JSONReviverMode::Enabled>;
template class LiteralParser<char16_t, JSONReviverMode::Enabled>;
template class LiteralParser<Latin1Character, JSONReviverMode::Disabled>;
template class LiteralParser<char16_t, JSONReviverMode::Disabled>;

}

WTF_ALLOW_UNSAFE_BUFFER_USAGE_END
