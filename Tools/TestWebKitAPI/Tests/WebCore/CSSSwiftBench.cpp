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

// A benchmark, not a test: skipped unless CSSBENCH_MODE is set. The Windows counterpart of the
// Mac probes calcparsebench and calcserializebench (webkit-swift-ports calc-owned/bench,
// gluecut-0929/serbench), plus whole-sheet parsing, for comparing a WK_USE_SWIFT_CSS WebCore with a
// C++ one. Only exported WebCore API is used, so one TestWebCore.exe runs against either WebCore.dll.
//
//   CSSBENCH_MODE     sheet | calcparse | calcserialize
//   CSSBENCH_FILES    ';'-separated stylesheet paths
//   CSSBENCH_REPS     passes over the inputs per window
//   CSSBENCH_WINDOWS  timed windows, after one untimed warm-up pass
//
// One line per window on stdout: "CSSBENCH <mode> <window> <thread cycles> <ns> <operations> <checksum>".
// Thread cycles are QueryThreadCycleTime's, which counts this thread only but at the TSC rate, not
// the core clock. There are no retired-instruction counts on Windows without a PMU driver.

#include "config.h"

#if PLATFORM(WIN)

#include <WebCore/CSSParser.h>
#include <WebCore/CSSParserContext.h>
#include <WebCore/CSSSerializationContext.h>
#include <WebCore/CSSValue.h>
#include <WebCore/MutableStyleProperties.h>
#include <WebCore/StyleProperties.h>
#include <WebCore/StylePropertiesInlines.h>
#include <WebCore/StyleSheetContents.h>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>
#include <windows.h>
#include <wtf/text/WTFString.h>

namespace TestWebKitAPI {

static std::string readFile(const std::string& path)
{
    FILE* file = fopen(path.c_str(), "rb");
    if (!file)
        return { };
    std::string out;
    char buffer[65536];
    size_t count;
    while ((count = fread(buffer, 1, sizeof buffer, file)) > 0)
        out.append(buffer, count);
    fclose(file);
    return out;
}

// Innermost-brace bodies, as the Mac probes extract them.
static std::vector<std::string> declarationBlocks(const std::string& source)
{
    std::vector<std::string> out;
    size_t depth = 0;
    size_t start = 0;
    bool inner = false;
    for (size_t i = 0; i < source.size(); ++i) {
        char c = source[i];
        if (c == '/' && i + 1 < source.size() && source[i + 1] == '*') {
            size_t end = source.find("*/", i + 2);
            i = end == std::string::npos ? source.size() : end + 1;
            continue;
        }
        if (c == '{') {
            ++depth;
            start = i + 1;
            inner = false;
        } else if (c == '}') {
            if (depth && !inner && i > start)
                out.push_back(source.substr(start, i - start));
            if (depth)
                --depth;
            inner = true;
            start = i + 1;
        }
    }
    return out;
}

static bool hasMathFunction(const std::string& text)
{
    return text.find("calc(") != std::string::npos || text.find("min(") != std::string::npos
        || text.find("max(") != std::string::npos || text.find("clamp(") != std::string::npos;
}

static bool hasMathFunction(const String& text)
{
    return text.contains("calc("_s) || text.contains("min("_s) || text.contains("max("_s) || text.contains("clamp("_s);
}

// Runs this thread on the most performant core class, so that windows are not split between
// P-cores and E-cores.
static void preferPerformanceCores()
{
    ULONG length = 0;
    GetSystemCpuSetInformation(nullptr, 0, &length, GetCurrentProcess(), 0);
    std::vector<char> buffer(length);
    auto* first = reinterpret_cast<SYSTEM_CPU_SET_INFORMATION*>(buffer.data());
    if (!GetSystemCpuSetInformation(first, length, &length, GetCurrentProcess(), 0))
        return;
    BYTE best = 0;
    for (ULONG offset = 0; offset < length;) {
        auto* info = reinterpret_cast<SYSTEM_CPU_SET_INFORMATION*>(buffer.data() + offset);
        best = std::max(best, info->CpuSet.EfficiencyClass);
        offset += info->Size;
    }
    std::vector<ULONG> ids;
    for (ULONG offset = 0; offset < length;) {
        auto* info = reinterpret_cast<SYSTEM_CPU_SET_INFORMATION*>(buffer.data() + offset);
        if (info->CpuSet.EfficiencyClass == best)
            ids.push_back(info->CpuSet.Id);
        offset += info->Size;
    }
    SetThreadSelectedCpuSets(GetCurrentThread(), ids.data(), static_cast<ULONG>(ids.size()));
    SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_HIGHEST);
    fprintf(stderr, "# pinned to %zu cpu sets of efficiency class %u\n", ids.size(), best);
}

static void printLoadedWebCore()
{
    HMODULE module = nullptr;
    auto address = reinterpret_cast<LPCSTR>(&WebCore::CSSParser::parseDeclarationList);
    if (!GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT, address, &module))
        return;
    char path[MAX_PATH];
    if (GetModuleFileNameA(module, path, MAX_PATH))
        fprintf(stderr, "# LOADED WebCore = %s\n", path);
}

static std::string environment(const char* name)
{
    const char* value = getenv(name);
    return value ? value : "";
}

TEST(CSSSwiftBench, Run)
{
    auto mode = environment("CSSBENCH_MODE");
    if (mode.empty())
        GTEST_SKIP() << "CSSBENCH_MODE is not set";

    int reps = atoi(environment("CSSBENCH_REPS").c_str());
    int windows = atoi(environment("CSSBENCH_WINDOWS").c_str());
    ASSERT_GT(reps, 0);
    ASSERT_GT(windows, 0);

    std::vector<std::string> sheets;
    auto files = environment("CSSBENCH_FILES");
    for (size_t start = 0; start < files.size();) {
        size_t end = files.find(';', start);
        if (end == std::string::npos)
            end = files.size();
        auto path = files.substr(start, end - start);
        if (!path.empty()) {
            auto contents = readFile(path);
            ASSERT_FALSE(contents.empty()) << "cannot read " << path;
            sheets.push_back(WTF::move(contents));
        }
        start = end + 1;
    }
    ASSERT_FALSE(sheets.empty());

    printLoadedWebCore();
    auto& context = WebCore::strictCSSParserContext();

    std::vector<String> sheetTexts;
    std::vector<String> calcBlocks;
    std::vector<Ref<WebCore::CSSValue>> calcValues;
    if (mode == "sheet") {
        for (auto& sheet : sheets)
            sheetTexts.push_back(String::fromLatin1(sheet.c_str()));
        fprintf(stderr, "# %zu sheets x %d reps per window\n", sheetTexts.size(), reps);
    } else if (mode == "calcparse") {
        for (auto& sheet : sheets) {
            for (auto& block : declarationBlocks(sheet)) {
                if (hasMathFunction(block))
                    calcBlocks.push_back(String::fromLatin1(block.c_str()));
            }
        }
        ASSERT_GE(calcBlocks.size(), 100u) << "too few calc blocks";
        fprintf(stderr, "# %zu calc declaration blocks x %d reps per window\n", calcBlocks.size(), reps);
    } else if (mode == "calcserialize") {
        // Values, not whole blocks, so that a window is dominated by the calc serializer.
        for (auto& sheet : sheets) {
            for (auto& block : declarationBlocks(sheet)) {
                if (!hasMathFunction(block))
                    continue;
                auto properties = WebCore::MutableStyleProperties::create();
                WebCore::CSSParser::parseDeclarationList(properties.get(), String::fromLatin1(block.c_str()), context);
                for (unsigned i = 0; i < properties->propertyCount(); ++i) {
                    auto value = properties->getPropertyCSSValue(properties->propertyAt(i).id());
                    if (!value)
                        continue;
                    if (hasMathFunction(value->cssText(WebCore::CSS::defaultSerializationContext())))
                        calcValues.push_back(value.releaseNonNull());
                }
            }
        }
        ASSERT_GE(calcValues.size(), 100u) << "too few calc values";
        fprintf(stderr, "# %zu calc-bearing values x %d reps per window\n", calcValues.size(), reps);
    } else
        FAIL() << "unknown CSSBENCH_MODE " << mode;

    auto pass = [&](uint64_t& checksum, uint64_t& operations) {
        for (int r = 0; r < reps; ++r) {
            if (mode == "sheet") {
                for (auto& text : sheetTexts) {
                    auto contents = WebCore::StyleSheetContents::create(String(), context);
                    contents->parseString(text);
                    checksum = checksum * 31 + contents->childRules().size() + contents->importRules().size();
                    ++operations;
                }
            } else if (mode == "calcparse") {
                for (auto& text : calcBlocks) {
                    auto properties = WebCore::MutableStyleProperties::create();
                    bool changed = WebCore::CSSParser::parseDeclarationList(properties.get(), text, context);
                    checksum = checksum * 31 + (changed ? 1 : 0) + properties->propertyCount();
                    ++operations;
                }
            } else {
                for (auto& value : calcValues) {
                    auto text = value->cssText(WebCore::CSS::defaultSerializationContext());
                    checksum = checksum * 31 + text.hash();
                    ++operations;
                }
            }
        }
    };

    preferPerformanceCores();
    {
        uint64_t checksum = 0;
        uint64_t operations = 0;
        pass(checksum, operations);
    }

    LARGE_INTEGER frequency;
    QueryPerformanceFrequency(&frequency);
    for (int w = 0; w < windows; ++w) {
        uint64_t checksum = 0;
        uint64_t operations = 0;
        ULONG64 cyclesBefore = 0;
        ULONG64 cyclesAfter = 0;
        LARGE_INTEGER before;
        LARGE_INTEGER after;
        QueryPerformanceCounter(&before);
        QueryThreadCycleTime(GetCurrentThread(), &cyclesBefore);
        pass(checksum, operations);
        QueryThreadCycleTime(GetCurrentThread(), &cyclesAfter);
        QueryPerformanceCounter(&after);
        auto ns = static_cast<unsigned long long>((after.QuadPart - before.QuadPart) * 1000000000.0 / frequency.QuadPart);
        printf("CSSBENCH %s %d %llu %llu %llu %llu\n", mode.c_str(), w, static_cast<unsigned long long>(cyclesAfter - cyclesBefore),
            ns, static_cast<unsigned long long>(operations), static_cast<unsigned long long>(checksum));
        fflush(stdout);
    }
}

} // namespace TestWebKitAPI

#endif // PLATFORM(WIN)
