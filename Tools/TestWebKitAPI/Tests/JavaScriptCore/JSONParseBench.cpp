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

#include "config.h"

#include "Helpers/Test.h"
#include <JavaScriptCore/APICast.h>
#include <JavaScriptCore/InitializeThreading.h>
#include <JavaScriptCore/JSCJSValueInlines.h>
#include <JavaScriptCore/JSContextRef.h>
#include <JavaScriptCore/JSGlobalObject.h>
#include <JavaScriptCore/JSLock.h>
#include <JavaScriptCore/JSONObject.h>
#include <JavaScriptCore/JSObjectRef.h>
#include <JavaScriptCore/JSRetainPtr.h>
#include <JavaScriptCore/JSStringRef.h>
#include <JavaScriptCore/JSValueRef.h>
#include <JavaScriptCore/OpaqueJSString.h>
#include <array>
#include <cstdio>
#include <cstdlib>
#include <iomanip>
#include <wtf/FileSystem.h>
#include <wtf/MonotonicTime.h>
#include <wtf/text/StringBuilder.h>
#include <wtf/text/WTFString.h>

// Throughput of JavaScriptCore's JSON parser, one TEST per kind of input. The strict tests call JSONParse, as
// WebCore does. Reviver, SloppyEval and JSONP go through JSEvaluateScript: JSON.parse with a reviver, indirect eval
// of a parenthesized literal, and programs made only of assignments of literals. By default each TEST parses its
// input once and checks a checksum of the values (their JSON.stringify text). With WEBKIT_RUN_BENCHMARKS=1 in the
// environment it then repeats the parse for about a second and prints "<Name>: <ms> ms <MB/s> MB/s checksum=<hex>",
// with the same checksum. Nothing asserts on time.

namespace TestWebKitAPI {

namespace {

class Generator {
public:
    explicit Generator(uint32_t seed)
        : m_state(seed)
    {
    }

    unsigned below(unsigned n)
    {
        m_state = m_state * 1664525u + 1013904223u;
        return (m_state >> 8) % n;
    }

private:
    uint32_t m_state;
};

struct Checksum {
    uint64_t value { 1469598103934665603ull };

    void addByte(uint8_t byte)
    {
        value ^= byte;
        value *= 1099511628211ull;
    }

    void add(uint64_t word)
    {
        for (unsigned i = 0; i < 8; ++i)
            addByte((word >> (8 * i)) & 0xff);
    }

    // The string's width is part of what is checked: the parser chooses it.
    void add(const String& string)
    {
        if (string.isNull()) {
            add(~0ull);
            return;
        }
        add(string.length());
        add(string.is8Bit());
        for (unsigned i = 0; i < string.length(); ++i) {
            char16_t character = string[i];
            addByte(character & 0xff);
            addByte(character >> 8);
        }
    }
};

enum class Entry : uint8_t { JSONParse, Reviver, SloppyEval, JSONP };

struct Input {
    Vector<String> documents;
    size_t bytes { 0 };
};

static size_t byteLength(const String& string)
{
    return string.length() * (string.is8Bit() ? 1 : 2);
}

static Input documentsInput(Vector<String>&& documents)
{
    Input input;
    for (auto& document : documents)
        input.bytes += byteLength(document);
    input.documents = WTF::move(documents);
    return input;
}

static bool runsBenchmarks()
{
    auto* value = getenv("WEBKIT_RUN_BENCHMARKS");
    return value && *value && StringView::fromLatin1(value) != "0"_s;
}

static JSRetainPtr<JSStringRef> scriptString(const String& string)
{
    if (string.is8Bit())
        return adopt(&OpaqueJSString::create(string.span8()).leakRef());
    return adopt(&OpaqueJSString::create(string.span16()).leakRef());
}

class Context {
public:
    Context()
        : m_context(JSGlobalContextCreate(nullptr))
    {
    }

    ~Context()
    {
        JSGlobalContextRelease(m_context);
    }

    JSGlobalContextRef context() const { return m_context; }
    JSC::JSGlobalObject* globalObject() const { return toJS(m_context); }

    JSValueRef evaluate(const String& script)
    {
        auto string = scriptString(script);
        JSValueRef exception = nullptr;
        auto* result = JSEvaluateScript(m_context, string.get(), nullptr, nullptr, 1, &exception);
        EXPECT_FALSE(exception) << script.left(80) << ": " << describe(exception);
        return result;
    }

    JSValueRef evaluate(JSStringRef script)
    {
        JSValueRef exception = nullptr;
        auto* result = JSEvaluateScript(m_context, script, nullptr, nullptr, 1, &exception);
        EXPECT_FALSE(exception) << describe(exception);
        return result;
    }

    String describe(JSValueRef value)
    {
        if (!value)
            return { };
        auto* globalObject = this->globalObject();
        return toJS(globalObject, value).toWTFString(globalObject);
    }

    void setGlobal(ASCIILiteral name, JSValueRef value)
    {
        auto nameString = adopt(JSStringCreateWithUTF8CString(name.characters()));
        JSObjectSetProperty(m_context, JSContextGetGlobalObject(m_context), nameString.get(), value, kJSPropertyAttributeNone, nullptr);
    }

    void setGlobalStrings(ASCIILiteral name, const Vector<String>& strings)
    {
        // Each string is stored as soon as it is made, so that a collection cannot free it.
        JSObjectRef array = JSObjectMakeArray(m_context, 0, nullptr, nullptr);
        setGlobal(name, array);
        for (unsigned i = 0; i < strings.size(); ++i)
            JSObjectSetPropertyAtIndex(m_context, array, i, JSValueMakeString(m_context, scriptString(strings[i]).get()), nullptr);
    }

    String stringify(JSValueRef value)
    {
        auto* globalObject = this->globalObject();
        return JSC::JSONStringify(globalObject, toJS(globalObject, value), 0u);
    }

    String stringify(JSC::JSValue value)
    {
        return JSC::JSONStringify(globalObject(), value, 0u);
    }

private:
    JSGlobalContextRef m_context;
};

// One pass over the input. With a checksum, every result is digested; without, the results are only checked to exist.
static void parseStrict(Context& context, const Input& input, Checksum* checksum)
{
    auto* globalObject = context.globalObject();
    for (auto& document : input.documents) {
        JSC::JSValue value = JSC::JSONParse(globalObject, document);
        if (checksum) {
            checksum->add(!!value);
            if (value)
                checksum->add(context.stringify(value));
        }
    }
}

static constexpr auto reviverScript = "JSON.parse(input, function (key, value) { return value; })"_s;
static constexpr auto sloppyEvalScript = "(function () { var results = []; for (var i = 0; i < inputs.length; ++i) results.push((0, eval)(inputs[i])); return results; })()"_s;
static constexpr auto errorMessagesScript = "(function () { var messages = []; for (var i = 0; i < inputs.length; ++i) { try { JSON.parse(inputs[i]); messages.push(''); } catch (error) { messages.push(error.name + ': ' + error.message); } } return messages; })()"_s;
static constexpr auto jsonpSetupScript = "var x = null; var a = { b: [], c: null };"_s;
static constexpr auto jsonpResultScript = "[x, a]"_s;

class Benchmark {
public:
    Benchmark(Entry entry, Input&& input)
        : m_entry(entry)
        , m_input(WTF::move(input))
    {
        JSC::JSLockHolder locker(context().globalObject()->vm());
        switch (m_entry) {
        case Entry::JSONParse:
            break;
        case Entry::Reviver:
            ASSERT(m_input.documents.size() == 1);
            m_context.setGlobal("input"_s, JSValueMakeString(m_context.context(), scriptString(m_input.documents[0]).get()));
            m_script = scriptString(reviverScript);
            break;
        case Entry::SloppyEval:
            m_context.setGlobalStrings("inputs"_s, m_input.documents);
            m_script = scriptString(sloppyEvalScript);
            break;
        case Entry::JSONP:
            m_context.evaluate(jsonpSetupScript);
            for (auto& document : m_input.documents)
                m_programs.append(scriptString(document));
            break;
        }
    }

    Context& context() { return m_context; }

    void runOnce(Checksum* checksum)
    {
        JSC::JSLockHolder locker(m_context.globalObject()->vm());
        switch (m_entry) {
        case Entry::JSONParse:
            parseStrict(m_context, m_input, checksum);
            break;
        case Entry::Reviver:
        case Entry::SloppyEval: {
            auto* result = m_context.evaluate(m_script.get());
            if (checksum)
                checksum->add(m_context.stringify(result));
            break;
        }
        case Entry::JSONP:
            for (auto& program : m_programs) {
                m_context.evaluate(program.get());
                if (checksum)
                    checksum->add(m_context.stringify(m_context.evaluate(jsonpResultScript)));
            }
            break;
        }
    }

    // The error messages the strict parser gives for each document, through JSON.parse, for the checksum only.
    void addErrorMessages(Checksum& checksum)
    {
        JSC::JSLockHolder locker(m_context.globalObject()->vm());
        m_context.setGlobalStrings("inputs"_s, m_input.documents);
        checksum.add(m_context.stringify(m_context.evaluate(errorMessagesScript)));
    }

    const Input& input() const { return m_input; }

private:
    Entry m_entry;
    Input m_input;
    Context m_context;
    JSRetainPtr<JSStringRef> m_script;
    Vector<JSRetainPtr<JSStringRef>> m_programs;
};

static void runBenchmark(ASCIILiteral name, Entry entry, Input&& input, unsigned iterations, uint64_t expectedChecksum, bool checksErrorMessages = false)
{
    JSC::initialize();
    Benchmark benchmark(entry, WTF::move(input));

    Checksum checksum;
    benchmark.runOnce(&checksum);
    if (checksErrorMessages)
        benchmark.addErrorMessages(checksum);
    EXPECT_EQ(checksum.value, expectedChecksum) << "checksum=" << std::hex << std::setfill('0') << std::setw(16) << checksum.value;

    if (!runsBenchmarks())
        return;

    auto start = MonotonicTime::now();
    for (unsigned i = 0; i < iterations; ++i)
        benchmark.runOnce(nullptr);
    double seconds = (MonotonicTime::now() - start).seconds();

    double bytes = static_cast<double>(benchmark.input().bytes) * iterations;
    SAFE_PRINTF("%s: %.1f ms %.1f MB/s checksum=%016llx\n", name, seconds * 1000, bytes / seconds / 1e6, static_cast<unsigned long long>(checksum.value));
}

// Payloads checked into PerformanceTests and Websites.
static String treeFile(std::initializer_list<StringView> components)
{
    String path = String::fromUTF8(__FILE__);
    for (unsigned i = 0; i < 5; ++i)
        path = FileSystem::parentPath(path);
    for (auto component : components)
        path = FileSystem::pathByAppendingComponent(path, component);
    auto contents = FileSystem::readEntireFile(path);
    EXPECT_TRUE(contents.has_value()) << "cannot read " << path;
    if (!contents)
        return emptyString();
    return String::fromUTF8(contents->span());
}

// Messages recorded from a Web Inspector session; the script assigns a JSON array to a variable.
static Input realInspectorInput()
{
    String script = treeFile({ "PerformanceTests"_s, "JetStream2"_s, "SeaMonster"_s, "inspector-json-payload.js"_s });
    size_t start = script.find("let obj = "_s);
    size_t end = script.reverseFind(';');
    EXPECT_NE(start, notFound);
    EXPECT_NE(end, notFound);
    if (start == notFound || end == notFound)
        return { };
    start += strlen("let obj = ");
    return documentsInput({ script.substring(start, end - start) });
}

static Input realSp3ManifestInput()
{
    return documentsInput({ treeFile({ "Websites"_s, "browserbench.org"_s, "Speedometer3.1"_s, "resources"_s, "perf.webkit.org"_s, "public"_s, "data"_s, "manifest.json"_s }) });
}

static Input realPackageLockInput()
{
    return documentsInput({ treeFile({ "PerformanceTests"_s, "Speedometer2.1"_s, "resources"_s, "todomvc"_s, "architecture-examples"_s, "angular"_s, "package-lock.json"_s }) });
}

static Input realSpirvInput()
{
    return documentsInput({ treeFile({ "PerformanceTests"_s, "JetStream2"_s, "WSL"_s, "spirv.core.grammar.json"_s }) });
}

static const ASCIILiteral words[] = { "list"_s, "title"_s, "item"_s, "state"_s, "order"_s, "child"_s, "type"_s, "user"_s, "count"_s,
    "name"_s, "kind"_s, "group"_s, "model"_s, "label"_s, "value"_s, "index"_s, "parent"_s, "active"_s, "done"_s, "todo"_s };

static ASCIILiteral word(Generator& generator)
{
    return words[generator.below(std::size(words))];
}

static void appendWords(StringBuilder& builder, Generator& generator, unsigned count)
{
    for (unsigned i = 0; i < count; ++i) {
        if (i)
            builder.append(' ');
        builder.append(word(generator));
    }
}

// Quotes are '"' for strict JSON and '\'' for the sloppy form; sloppy keys are identifiers.
struct Style {
    char quote { '"' };
    bool identifierKeys { false };
};

static void appendKey(StringBuilder& builder, const Style& style, ASCIILiteral key)
{
    if (style.identifierKeys)
        builder.append(key, ':');
    else
        builder.append(style.quote, key, style.quote, ':');
}

// A Speedometer-style list of to-do items.
static void appendTodoList(StringBuilder& builder, Generator& generator, unsigned items, const Style& style = { })
{
    builder.append('{');
    appendKey(builder, style, "version"_s);
    builder.append("3,"_s);
    appendKey(builder, style, "generated"_s);
    builder.append(1755000000 + generator.below(100000), ',');
    appendKey(builder, style, "locale"_s);
    builder.append(style.quote, "en-US"_s, style.quote, ',');
    appendKey(builder, style, "items"_s);
    builder.append('[');
    for (unsigned i = 0; i < items; ++i) {
        if (i)
            builder.append(',');
        builder.append('{');
        appendKey(builder, style, "id"_s);
        builder.append(i, ',');
        appendKey(builder, style, "text"_s);
        builder.append(style.quote);
        appendWords(builder, generator, 1 + generator.below(6));
        builder.append(style.quote, ',');
        appendKey(builder, style, "completed"_s);
        builder.append(generator.below(3) ? "false"_s : "true"_s, ',');
        appendKey(builder, style, "order"_s);
        builder.append(i * 10, ',');
        appendKey(builder, style, "parent"_s);
        if (generator.below(4))
            builder.append("null"_s);
        else
            builder.append(static_cast<int>(generator.below(i + 1)) - 1);
        builder.append(',');
        appendKey(builder, style, "tags"_s);
        builder.append('[');
        unsigned tags = generator.below(4);
        for (unsigned j = 0; j < tags; ++j) {
            if (j)
                builder.append(',');
            builder.append(style.quote, word(generator), style.quote);
        }
        builder.append("],"_s);
        appendKey(builder, style, "meta"_s);
        builder.append('{');
        appendKey(builder, style, "created"_s);
        builder.append(1750000000 + i * 37, ',');
        appendKey(builder, style, "revision"_s);
        builder.append(1 + generator.below(9));
        if (!generator.below(8)) {
            builder.append(',');
            appendKey(builder, style, "priority"_s);
            builder.append(generator.below(5));
        }
        builder.append("}}"_s);
    }
    builder.append("]}"_s);
}

static Input sp3ishInput()
{
    Generator generator(1);
    Vector<String> documents;
    for (unsigned i = 0; i < 20; ++i) {
        StringBuilder builder;
        appendTodoList(builder, generator, 300 + generator.below(400));
        documents.append(builder.toString());
    }
    return documentsInput(WTF::move(documents));
}

static Input smallObjectsInput()
{
    Generator generator(2);
    StringBuilder builder;
    builder.append('[');
    for (unsigned i = 0; i < 100000; ++i) {
        if (i)
            builder.append(',');
        switch (generator.below(4)) {
        case 0: {
            unsigned a = generator.below(100);
            bool b = generator.below(2);
            builder.append("{\"a\":"_s, a, ",\"b\":"_s, b ? "true"_s : "false"_s, '}');
            break;
        }
        case 1:
            builder.append("{\"a\":"_s, generator.below(100), ",\"b\":false,\"c\":null}"_s);
            break;
        case 2: {
            unsigned x = generator.below(1000);
            unsigned y = generator.below(1000);
            builder.append("{\"x\":"_s, x, ",\"y\":"_s, y, '}');
            break;
        }
        default:
            builder.append("{\"id\":"_s, i, ",\"ok\":true}"_s);
            break;
        }
    }
    builder.append(']');
    return documentsInput({ builder.toString() });
}

static Input intArraysInput()
{
    Generator generator(3);
    StringBuilder builder;
    builder.append('[');
    for (unsigned i = 0; i < 400; ++i) {
        if (i)
            builder.append(',');
        builder.append('[');
        for (unsigned j = 0; j < 1000; ++j) {
            if (j)
                builder.append(',');
            switch (generator.below(8)) {
            case 0:
                builder.append(-static_cast<int>(generator.below(100000)));
                break;
            case 1:
                builder.append(static_cast<int>(1000000000 + generator.below(1000000000)));
                break;
            case 2:
                builder.append(generator.below(10));
                break;
            case 3:
                builder.append(generator.below(100000000));
                break;
            default:
                builder.append(generator.below(1000));
                break;
            }
        }
        builder.append(']');
    }
    builder.append(']');
    return documentsInput({ builder.toString() });
}

static Input doubleArraysInput()
{
    Generator generator(4);
    StringBuilder builder;
    builder.append('[');
    for (unsigned i = 0; i < 300; ++i) {
        if (i)
            builder.append(',');
        builder.append('[');
        for (unsigned j = 0; j < 1000; ++j) {
            if (j)
                builder.append(',');
            switch (generator.below(6)) {
            case 0: {
                unsigned integer = generator.below(1000);
                unsigned fraction = generator.below(1000000);
                builder.append(integer, '.', fraction);
                break;
            }
            case 1: {
                unsigned integer = generator.below(10);
                unsigned fraction = generator.below(100000);
                bool negativeExponent = generator.below(2);
                unsigned exponent = generator.below(300);
                builder.append('-', integer, '.', fraction, 'e', negativeExponent ? '-' : '+', exponent);
                break;
            }
            case 2:
                builder.append("0."_s, generator.below(1000));
                break;
            case 3: {
                unsigned significand = generator.below(100);
                unsigned exponent = generator.below(20);
                builder.append(significand, 'E', exponent);
                break;
            }
            case 4: {
                unsigned high = generator.below(100000000);
                unsigned low = generator.below(100000000);
                builder.append(high, low, ".5"_s);
                break;
            }
            default: {
                unsigned integer = generator.below(1000);
                unsigned fraction = generator.below(100);
                builder.append('-', integer, '.', fraction);
                break;
            }
            }
        }
        builder.append(']');
    }
    builder.append(']');
    return documentsInput({ builder.toString() });
}

static void appendRandomLetters(StringBuilder& builder, Generator& generator, unsigned length)
{
    for (unsigned i = 0; i < length; ++i)
        builder.append(static_cast<char>('a' + generator.below(26)));
}

static Input shortStringsInput()
{
    Generator generator(5);
    StringBuilder builder;
    builder.append('[');
    for (unsigned i = 0; i < 2000; ++i) {
        if (i)
            builder.append(',');
        builder.append('[');
        for (unsigned j = 0; j < 100; ++j) {
            if (j)
                builder.append(',');
            builder.append('"');
            if (generator.below(2))
                builder.append(word(generator));
            else
                appendRandomLetters(builder, generator, generator.below(16));
            builder.append('"');
        }
        builder.append(']');
    }
    builder.append(']');
    return documentsInput({ builder.toString() });
}

static Input longStringsInput()
{
    Generator generator(6);
    StringBuilder builder;
    builder.append('[');
    for (unsigned i = 0; i < 64; ++i) {
        if (i)
            builder.append(',');
        builder.append('"');
        unsigned length = 1024 + generator.below(63 * 1024);
        for (unsigned j = 0; j < length; ++j) {
            unsigned pick = generator.below(64);
            if (!pick)
                builder.append(static_cast<Latin1Character>(0xE9));
            else if (pick < 10)
                builder.append(' ');
            else
                builder.append(static_cast<char>('a' + pick % 26));
        }
        builder.append('"');
    }
    builder.append(']');
    return documentsInput({ builder.toString() });
}

static const ASCIILiteral escapes[] = { "\\n"_s, "\\t"_s, "\\\""_s, "\\\\"_s, "\\/"_s, "\\b"_s, "\\f"_s, "\\r"_s, "\\u00e9"_s, "\\u0041"_s,
    "\\u3042"_s, "\\ud83d\\ude00"_s };

static Input escapesInput()
{
    Generator generator(7);
    StringBuilder builder;
    builder.append('[');
    for (unsigned i = 0; i < 20000; ++i) {
        if (i)
            builder.append(',');
        builder.append('"');
        unsigned length = 10 + generator.below(190);
        // Most strings stay 8-bit; one in eight holds an escape outside Latin-1.
        bool wide = !generator.below(8);
        for (unsigned j = 0; j < length; ++j) {
            if (generator.below(8))
                builder.append(static_cast<char>('a' + generator.below(26)));
            else
                builder.append(escapes[generator.below(wide ? std::size(escapes) : std::size(escapes) - 2)]);
        }
        builder.append('"');
    }
    builder.append(']');
    return documentsInput({ builder.toString() });
}

static void appendWideText(StringBuilder& builder, Generator& generator, unsigned length)
{
    for (unsigned i = 0; i < length; ++i) {
        switch (generator.below(8)) {
        case 0:
            builder.append(static_cast<char>('a' + generator.below(26)));
            break;
        case 1:
            builder.append(static_cast<char16_t>(0x3041 + generator.below(0x56)));
            break;
        default:
            builder.append(static_cast<char16_t>(0x4E00 + generator.below(0x5000)));
            break;
        }
    }
}

// 16-bit documents: CJK keys and values, with some ASCII keys.
static Input wideTextInput()
{
    Generator generator(8);
    static const char16_t keys[][3] = { { 0x540D, 0x524D, 0 }, { 0x8AAC, 0x660E, 0 }, { 0x4FA1, 0x683C, 0 }, { 0x5730, 0x57DF, 0 } };
    Vector<String> documents;
    for (unsigned d = 0; d < 10; ++d) {
        StringBuilder builder;
        builder.append('[');
        for (unsigned i = 0; i < 1000; ++i) {
            if (i)
                builder.append(',');
            builder.append('{');
            for (unsigned k = 0; k < std::size(keys); ++k) {
                builder.append('"', std::span<const char16_t>(keys[k], 2), "\":\""_s);
                appendWideText(builder, generator, 2 + generator.below(k == 1 ? 60 : 10));
                builder.append("\","_s);
            }
            builder.append("\"id\":"_s, i, ",\"tag\":\""_s, word(generator), "\"}"_s);
        }
        builder.append(']');
        documents.append(builder.toString());
        EXPECT_FALSE(documents.last().is8Bit());
    }
    return documentsInput(WTF::move(documents));
}

static String nested(unsigned depth, ASCIILiteral open, ASCIILiteral leaf, ASCIILiteral close)
{
    StringBuilder builder;
    for (unsigned i = 0; i < depth; ++i)
        builder.append(open);
    builder.append(leaf);
    for (unsigned i = 0; i < depth; ++i)
        builder.append(close);
    return builder.toString();
}

static Input deepNestingInput()
{
    Generator generator(9);
    Vector<String> documents;
    documents.append(nested(10000, "["_s, "1"_s, "]"_s));
    documents.append(nested(10000, "{\"a\":"_s, "true"_s, "}"_s));
    documents.append(nested(5000, "[{\"k\":"_s, "\"leaf\""_s, "}]"_s));
    // Many documents of moderate depth, with siblings at each level.
    for (unsigned d = 0; d < 200; ++d) {
        StringBuilder builder;
        unsigned depth = 20 + generator.below(100);
        for (unsigned i = 0; i < depth; ++i)
            builder.append(generator.below(2) ? "[0,"_s : "{\"n\":1,\"v\":"_s);
        builder.append("null"_s);
        String text = builder.toString();
        StringBuilder closing;
        for (unsigned i = text.length(); i--;) {
            if (text[i] == '[')
                closing.append(']');
            else if (text[i] == '{')
                closing.append('}');
        }
        documents.append(makeString(text, closing.toString()));
    }
    return documentsInput(WTF::move(documents));
}

static Input emptyContainersInput()
{
    Generator generator(10);
    static const ASCIILiteral pieces[] = { "[]"_s, "{}"_s, "[[],{}]"_s, "{\"a\":[],\"b\":{}}"_s, "[[[]]]"_s, "[ ]"_s, "{ }"_s };
    StringBuilder builder;
    builder.append('[');
    for (unsigned i = 0; i < 200000; ++i) {
        if (i)
            builder.append(',');
        builder.append(pieces[generator.below(std::size(pieces))]);
    }
    builder.append(']');
    return documentsInput({ builder.toString() });
}

// Each malformed piece follows a valid prefix of a varying length; "\u3042" pieces make the document 16-bit.
static const ASCIILiteral malformedPieces[] = { "1."_s, "\"\\q\""_s, "1e"_s, "1e+"_s, "-"_s, "\"\\u00zz\""_s, "tru"_s, "\"a\tb\""_s,
    "\"\\u00"_s, "'a'"_s, "@"_s, "\"abc\\"_s, "\"abc"_s, "01"_s, "[1,]"_s, "{\"a\" 1}"_s, "{\"a\":1,}"_s, "{a:1}"_s, "[1 2]"_s,
    "nul"_s, "\"\\x41\""_s, "1.e1"_s, "-01"_s, "}"_s, "["_s, "\"ok\"]] {}"_s };

static Input errorsInput()
{
    Generator generator(11);
    Vector<String> documents;
    for (unsigned i = 0; i < 4000; ++i) {
        StringBuilder builder;
        builder.append("[{\"start\":"_s, i, '}');
        unsigned items = generator.below(30);
        for (unsigned j = 0; j < items; ++j) {
            auto text = word(generator);
            bool done = generator.below(2);
            builder.append(",{\"id\":"_s, j, ",\"text\":\""_s, text, "\",\"done\":"_s, done ? "true"_s : "false"_s, '}');
        }
        builder.append(',');
        unsigned piece = generator.below(std::size(malformedPieces) + 1);
        if (piece == std::size(malformedPieces))
            builder.append(static_cast<char16_t>(0x3042));
        else
            builder.append(malformedPieces[piece]);
        documents.append(builder.toString());
    }
    return documentsInput(WTF::move(documents));
}

static Input reviverInput()
{
    Generator generator(12);
    StringBuilder builder;
    appendTodoList(builder, generator, 4000);
    return documentsInput({ builder.toString() });
}

static Input sloppyEvalInput()
{
    Generator generator(13);
    Vector<String> documents;
    for (unsigned i = 0; i < 400; ++i) {
        StringBuilder builder;
        switch (i % 4) {
        case 0:
            builder.append('(');
            appendTodoList(builder, generator, 10 + generator.below(30), { '\'', true });
            builder.append(')');
            break;
        case 1:
            builder.append('(');
            appendTodoList(builder, generator, 10 + generator.below(30), { '"', true });
            builder.append(')');
            break;
        case 2:
            builder.append('(');
            appendTodoList(builder, generator, 10 + generator.below(30), { '\'', false });
            builder.append(')');
            break;
        default:
            builder.append('[');
            for (unsigned j = 0; j < 200; ++j) {
                auto text = word(generator);
                builder.append(j ? ","_s : ""_s, '\'', text, "',"_s, generator.below(1000));
            }
            builder.append(']');
            break;
        }
        documents.append(builder.toString());
    }
    return documentsInput(WTF::move(documents));
}

static Input jsonpInput()
{
    Generator generator(14);
    Vector<String> documents;
    for (unsigned i = 0; i < 100; ++i) {
        StringBuilder builder;
        builder.append("var x = "_s);
        appendTodoList(builder, generator, 20 + generator.below(40));
        builder.append(";\na.b[3] = "_s);
        appendTodoList(builder, generator, 10 + generator.below(20));
        builder.append(";\na.c = ["_s);
        for (unsigned j = 0; j < 100; ++j)
            builder.append(j ? ","_s : ""_s, generator.below(100000));
        builder.append("];\n"_s);
        documents.append(builder.toString());
    }
    return documentsInput(WTF::move(documents));
}

} // namespace

TEST(JSONParseBench, RealInspector)
{
    runBenchmark("RealInspector"_s, Entry::JSONParse, realInspectorInput(), 330, 0x24d9965e473dd06bull);
}

TEST(JSONParseBench, RealSp3Manifest)
{
    runBenchmark("RealSp3Manifest"_s, Entry::JSONParse, realSp3ManifestInput(), 1100, 0x43af40bf8f9cf644ull);
}

TEST(JSONParseBench, RealPackageLock)
{
    runBenchmark("RealPackageLock"_s, Entry::JSONParse, realPackageLockInput(), 4800, 0xbf389f8bba6740b5ull);
}

TEST(JSONParseBench, RealSpirv)
{
    runBenchmark("RealSpirv"_s, Entry::JSONParse, realSpirvInput(), 7200, 0x8476afb73b76a086ull);
}

TEST(JSONParseBench, Sp3ish)
{
    runBenchmark("Sp3ish"_s, Entry::JSONParse, sp3ishInput(), 800, 0x9f0b0df46080c6adull);
}

TEST(JSONParseBench, SmallObjects)
{
    runBenchmark("SmallObjects"_s, Entry::JSONParse, smallObjectsInput(), 470, 0xc57d0d35cbac11bcull);
}

TEST(JSONParseBench, IntArrays)
{
    runBenchmark("IntArrays"_s, Entry::JSONParse, intArraysInput(), 420, 0x4249df23c188f652ull);
}

TEST(JSONParseBench, DoubleArrays)
{
    runBenchmark("DoubleArrays"_s, Entry::JSONParse, doubleArraysInput(), 200, 0x2ac2b5ba9f2929e2ull);
}

TEST(JSONParseBench, ShortStrings)
{
    runBenchmark("ShortStrings"_s, Entry::JSONParse, shortStringsInput(), 210, 0x94c10bc3c9c51504ull);
}

TEST(JSONParseBench, LongStrings)
{
    runBenchmark("LongStrings"_s, Entry::JSONParse, longStringsInput(), 9300, 0xcd4493101e92595full);
}

TEST(JSONParseBench, Escapes)
{
    runBenchmark("Escapes"_s, Entry::JSONParse, escapesInput(), 160, 0xe2084f8e6611fb93ull);
}

TEST(JSONParseBench, WideText)
{
    runBenchmark("WideText"_s, Entry::JSONParse, wideTextInput(), 500, 0xbbcc2280b1652e8aull);
}

TEST(JSONParseBench, DeepNesting)
{
    runBenchmark("DeepNesting"_s, Entry::JSONParse, deepNestingInput(), 1100, 0x0506b0cc9aeb6d92ull);
}

TEST(JSONParseBench, EmptyContainers)
{
    runBenchmark("EmptyContainers"_s, Entry::JSONParse, emptyContainersInput(), 220, 0x4287e9b700c355eaull);
}

TEST(JSONParseBench, Errors)
{
    runBenchmark("Errors"_s, Entry::JSONParse, errorsInput(), 650, 0xffcad6e692a6ec39ull, true);
}

TEST(JSONParseBench, Reviver)
{
    runBenchmark("Reviver"_s, Entry::Reviver, reviverInput(), 340, 0x7b38a27e0dd1c8efull);
}

TEST(JSONParseBench, SloppyEval)
{
    runBenchmark("SloppyEval"_s, Entry::SloppyEval, sloppyEvalInput(), 680, 0x9502dc78f6b7cc6aull);
}

TEST(JSONParseBench, JSONP)
{
    runBenchmark("JSONP"_s, Entry::JSONP, jsonpInput(), 800, 0xfdde43c1750495ccull);
}

} // namespace TestWebKitAPI
