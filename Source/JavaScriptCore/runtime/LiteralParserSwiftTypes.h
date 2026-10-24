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

// The types LiteralParser and its Swift implementation (LiteralParserSwift.swift) share. This header
// includes only the standard library, so Swift imports it as its own module.

#pragma once

#include <cstddef>
#include <cstdint>
#include <span>

namespace JSC {

// The characters to parse. uint8_t is Latin1Character.
using JSONParseInput8 = std::span<const uint8_t>;
using JSONParseInput16 = std::span<const char16_t>;

// What to parse, which also chooses the lexer's ParserMode.
enum class JSONParseEntry : uint8_t {
    Value, // tryLiteralParse: StrictJSON.
    PrimitiveValue, // tryLiteralParsePrimitiveValue: StrictJSON, no containers.
    Eval, // tryEval: SloppyJSON, an optional trailing ';'.
    Program, // tryJSONPParse: JSONP statements.
};

// A literal value: true, false or null.
enum class JSONParseLiteral : uint8_t { False, True, Null };

// Why a parse failed, which LiteralParser::getErrorMessage() turns into its message: a JSONParseErrorKind from
// LiteralParserSwift.swift, and the characters the message quotes, at [offset, offset + length).
struct JSONParseFailure {
    uint8_t kind;
    size_t offset;
    size_t length;
};

// The text of LiteralParser::getErrorMessage(), which Swift builds. Like JSONParseSink below, Swift sees it only as an
// inout parameter, and only the derived class in LiteralParserSwiftFacade.cpp can construct one.
class __attribute__((swift_attr("~Sendable"))) JSONParseErrorMessage {
public:
    JSONParseErrorMessage(const JSONParseErrorMessage&) = delete;
    JSONParseErrorMessage& operator=(const JSONParseErrorMessage&) = delete;
    [[noreturn]] JSONParseErrorMessage(JSONParseErrorMessage&&) { __builtin_trap(); }
    ~JSONParseErrorMessage() { }

    // Appends characters8, or characters16 when it is not empty, and returns false if the text could not be
    // allocated; or empties it.
    bool append(JSONParseInput8 characters8 [[clang::noescape]], JSONParseInput16 characters16 [[clang::noescape]]);
    void clear();

protected:
    JSONParseErrorMessage() = default;
};

// Which parses a JSONParseSink serves: a StrictJSON or SloppyJSON parse that is not iterative, and so records no
// source ranges, or any parse.
enum class JSONParseSinkMode : uint8_t { Strict, Sloppy, Any };

// The parse's values: what Swift finds is reported here, and the C++ makes and holds every JavaScript value on
// the stack of the C++ function that parses. Swift sees this class only as an inout parameter. CharType is the
// width of the characters parsed, and with sinkMode it is fixed at compile time in each member function.
//
// Only the derived class in LiteralParserSwiftFacade.cpp can construct one, and each member function reaches its
// state with a static_cast. That is sound only while every object of this type is that derived object, at its own
// address, so: it has no data members; it cannot be copied; and Swift relocates a noncopyable C++ object only through
// its move constructor, which crashes. The destructor is user-provided so that Swift passes the object by address.
//
// Member functions are non-virtual. They take values, offsets and lengths into the characters being parsed, which
// they check before they read or record them, and spans of the input that remains or of characters Swift decoded.
// Those that return bool return false when the parse must stop, with an exception pending or an error message
// recorded.
template<typename CharType, JSONParseSinkMode sinkMode>
class __attribute__((swift_attr("~Sendable"))) JSONParseSink {
public:
    JSONParseSink(const JSONParseSink&) = delete;
    JSONParseSink& operator=(const JSONParseSink&) = delete;
    [[noreturn]] JSONParseSink(JSONParseSink&&) { __builtin_trap(); }
    ~JSONParseSink() { }

    // Containers, from the offset of '[' or '{' and to the offset after ']' or '}'.
    bool beginArray(size_t start);
    bool endArray(size_t end);
    bool beginObject(size_t start);
    bool endObject(size_t end);
    // JSONCache::ParsingScope for the rest of the parse.
    void beginCacheScope();

    // The next key of the innermost object: characters of the input, from which charactersToEnd characters remain
    // to its end, or a key with escapes, decoded into characters8, or into characters16 when it is not empty.
    void key(std::span<const CharType> characters [[clang::noescape]], size_t charactersToEnd);
    void decodedKey(JSONParseInput8 characters8 [[clang::noescape]], JSONParseInput16 characters16 [[clang::noescape]]);
    // A key at the start of the remaining input that JSONCache predicts, as LiteralParser compares it to the source:
    // the length of the key and its colon, or 0 when it matched none.
    size_t consumeCachedKey(std::span<const CharType> remaining [[clang::noescape]]);

    // Values. The source range of the next value that is not a container, when ranges are recorded.
    void setValueRange(size_t start, size_t end);
    // The length characters of the input at start. With cache, later parses take this string for the text from the
    // quote before start to the one after start + length.
    bool stringValue(size_t start, size_t length, bool cache);
    bool decodedStringValue(JSONParseInput8 characters8 [[clang::noescape]], JSONParseInput16 characters16 [[clang::noescape]]);
    // A string at the start of the remaining input that JSONCache holds; length is set to its length when there is one.
    bool cachedStringValue(std::span<const CharType> remaining [[clang::noescape]], size_t& length);
    bool int32Value(int32_t);
    bool numberValue(double);
    bool literalValue(JSONParseLiteral);
    // The number WTF::parseJSONDouble reads at the start of the remaining input; length is 0 when it reads none.
    double parseNumber(std::span<const CharType> remaining [[clang::noescape]], size_t& length);

    // Why the parse failed, when it stops with neither an exception nor a message of its own.
    void fail(JSONParseFailure);

    // JSONP: a statement's path, one JSONPPathEntryType at a time, with the name at [start, start + length) or the
    // index; false if the name is a keyword. Then its value.
    bool appendJSONPPathEntry(uint8_t type, size_t start, size_t length, int32_t index);
    void beginJSONPValue();
    void endJSONPValue();

protected:
    JSONParseSink() = default;
};

using JSONParseSink8 = JSONParseSink<uint8_t, JSONParseSinkMode::Any>;
using JSONParseSink16 = JSONParseSink<char16_t, JSONParseSinkMode::Any>;
using JSONParseSinkStrict8 = JSONParseSink<uint8_t, JSONParseSinkMode::Strict>;
using JSONParseSinkStrict16 = JSONParseSink<char16_t, JSONParseSinkMode::Strict>;
using JSONParseSinkSloppy8 = JSONParseSink<uint8_t, JSONParseSinkMode::Sloppy>;
using JSONParseSinkSloppy16 = JSONParseSink<char16_t, JSONParseSinkMode::Sloppy>;

} // namespace JSC
