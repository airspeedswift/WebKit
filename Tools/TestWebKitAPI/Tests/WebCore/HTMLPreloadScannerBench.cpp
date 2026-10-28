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
#include "TestPlatformStrategies.h"
#include <WebCore/DocumentInlines.h>
#include <WebCore/HTMLDocument.h>
#include <WebCore/HTMLParserOptions.h>
#include <WebCore/HTMLPreloadScanner.h>
#include <WebCore/HTMLResourcePreloader.h>
#include <WebCore/ProcessWarming.h>
#include <WebCore/SegmentedString.h>
#include <WebCore/Settings.h>
#include <array>
#include <cstdio>
#include <cstdlib>
#include <iomanip>
#include <string>
#include <wtf/FileSystem.h>
#include <wtf/MonotonicTime.h>
#include <wtf/URL.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/StringBuilder.h>
#include <wtf/text/WTFString.h>

// Throughput of WebCore's HTML preload scanner (HTMLPreloadScanner::scanRequests), one TEST per kind of input. The
// input is appended to one scanner in network-sized chunks, and the scanner is asked for its requests after each
// chunk, as HTMLDocumentParser does while a script blocks it. The document is frameless, so the requests are taken
// before HTMLResourcePreloader, which would drop them. By default each TEST scans its input once and checks the
// checksum of the requests. With WEBKIT_RUN_BENCHMARKS=1 in the environment it then repeats the scan for about a
// second and prints "<Name>: <ms> ms <MB/s> MB/s checksum=<hex>", with the same checksum. Nothing asserts on time.

using namespace WebCore;

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

    void add(uint64_t word)
    {
        for (unsigned i = 0; i < 8; ++i) {
            value ^= (word >> (8 * i)) & 0xff;
            value *= 1099511628211ull;
        }
    }

    void add(const String& string)
    {
        add(string.length());
        for (unsigned i = 0; i < string.length(); ++i) {
            char16_t character = string[i];
            value ^= character & 0xff;
            value *= 1099511628211ull;
            value ^= character >> 8;
            value *= 1099511628211ull;
        }
    }
};

// The input as the scanner receives it: a list of chunks.
struct Input {
    Vector<String> chunks;
    size_t bytes { 0 };
};

static Input networkChunks(const String& document)
{
    static constexpr unsigned chunkLength = 1460;
    Input input;
    for (unsigned offset = 0; offset < document.length(); offset += chunkLength)
        input.chunks.append(document.substring(offset, chunkLength));
    input.bytes = document.length() * (document.is8Bit() ? 1 : 2);
    return input;
}

struct Summary {
    unsigned scans { 0 };
    unsigned requests { 0 };
    uint64_t types { 0 };

    friend bool operator==(const Summary&, const Summary&) = default;
};

template<typename ScanFunction>
static void scanInput(Document& document, const Input& input, ScanFunction&& takeRequests)
{
    HTMLParserOptions options(document);
    HTMLPreloadScanner scanner(options, document.url(), document.deviceScaleFactor());
    for (auto& chunk : input.chunks) {
        scanner.appendToEnd(SegmentedString(chunk));
        takeRequests(scanner.scanRequests(document));
    }
}

static void addRequests(Summary& summary, const PreloadRequestStream& requests)
{
    ++summary.scans;
    summary.requests += requests.size();
    for (auto& request : requests)
        summary.types = summary.types * 31 + static_cast<unsigned>(request->resourceType());
}

static bool runsBenchmarks()
{
    auto* value = getenv("WEBKIT_RUN_BENCHMARKS");
    return value && *value && StringView::fromLatin1(value) != "0"_s;
}

static void expectChecksum(const Checksum& checksum, uint64_t expected)
{
    EXPECT_EQ(checksum.value, expected) << "checksum=" << std::hex << std::setfill('0') << std::setw(16) << checksum.value;
}

static void printResult(ASCIILiteral name, double seconds, double bytes, const Checksum& checksum)
{
    SAFE_PRINTF("%s: %.1f ms %.1f MB/s checksum=%016llx\n", name, seconds * 1000, bytes / seconds / 1e6, static_cast<unsigned long long>(checksum.value));
}

static Ref<HTMLDocument> createDocument(const Settings& settings)
{
    return HTMLDocument::create(nullptr, settings, URL { "https://example.com/pages/index.html"_s });
}

static Checksum checksumOfOnePass(Document& document, const Input& input, Summary& summary)
{
    Checksum checksum;
    scanInput(document, input, [&](PreloadRequestStream&& requests) {
        addRequests(summary, requests);
        checksum.add(requests.size());
        for (auto& request : requests)
            checksum.add(request->descriptionForTesting());
    });
    checksum.add(summary.scans);
    checksum.add(summary.requests);
    return checksum;
}

static void runBenchmark(ASCIILiteral name, const Input& input, unsigned iterations, uint64_t expectedChecksum)
{
    ensureTestPlatformStrategiesInstalled();
    ProcessWarming::initializeNames();

    auto settings = Settings::create(nullptr);
    settings->setLazyImageLoadingEnabled(true);
    auto document = createDocument(settings);

    Summary summary;
    auto checksum = checksumOfOnePass(document, input, summary);
    expectChecksum(checksum, expectedChecksum);

    if (!runsBenchmarks())
        return;

    unsigned mismatches = 0;
    auto start = MonotonicTime::now();
    for (unsigned i = 0; i < iterations; ++i) {
        Summary iterationSummary;
        scanInput(document, input, [&](PreloadRequestStream&& requests) {
            addRequests(iterationSummary, requests);
        });
        if (iterationSummary != summary)
            ++mismatches;
    }
    double seconds = (MonotonicTime::now() - start).seconds();
    EXPECT_EQ(mismatches, 0u);

    printResult(name, seconds, static_cast<double>(input.bytes) * iterations, checksum);
}

// The HTML specification, the input of PerformanceTests/Parser/html-parser.html.
static String specPage()
{
    String path = String::fromUTF8(__FILE__);
    for (unsigned i = 0; i < 5; ++i)
        path = FileSystem::parentPath(path);
    std::array<StringView, 4> components { "PerformanceTests"_s, "Parser"_s, "resources"_s, "html5.html"_s };
    path = FileSystem::pathByAppendingComponents(path, components);
    auto contents = FileSystem::readEntireFile(path);
    EXPECT_TRUE(contents.has_value()) << "cannot read PerformanceTests/Parser/resources/html5.html";
    if (!contents)
        return emptyString();
    return String::fromUTF8(contents->span());
}

static const ASCIILiteral proseWords[] = { "the"_s, "scanner"_s, "finds"_s, "images"_s, "scripts"_s, "and"_s, "style"_s, "sheets"_s,
    "before"_s, "parser"_s, "lorem"_s, "ipsum"_s, "dolor"_s, "sit"_s, "amet"_s, "consectetur"_s, "adipiscing"_s, "elit"_s };

static void appendProse(StringBuilder& builder, Generator& generator, unsigned length)
{
    unsigned appended = 0;
    while (appended < length) {
        unsigned pick = generator.below(64);
        if (!pick) {
            builder.append(".\n"_s);
            appended += 2;
        } else {
            auto word = proseWords[generator.below(std::size(proseWords))];
            builder.append(word, ' ');
            appended += word.length() + 1;
        }
    }
}

static void appendHead(StringBuilder& builder, ASCIILiteral title)
{
    builder.append("<!DOCTYPE html>\n<html lang=\"en\"><head><meta charset=\"utf-8\"><title>"_s, title,
        "</title>\n<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n</head><body>\n"_s);
}

static const ASCIILiteral sizesValues[] = { "100vw"_s, "(max-width: 600px) 100vw, 50vw"_s, "(min-width: 1200px) 33vw, (min-width: 800px) 50vw, 100vw"_s,
    "320px"_s, "calc(100vw - 2em)"_s };

// Figures of <img> with src, srcset (width or density descriptors) and sizes, some lazy, some with a fetch priority,
// referrer policy or cross-origin mode.
static String imageGallery()
{
    Generator generator(7);
    StringBuilder builder;
    appendHead(builder, "Gallery"_s);
    for (unsigned n = 0; builder.length() < 1 << 20; ++n) {
        builder.append("<figure class=\"card\"><img src=\"/photos/p"_s, n, ".jpg\""_s);
        unsigned srcset = generator.below(4);
        if (srcset == 1 || srcset == 2)
            builder.append(" srcset=\"/photos/p"_s, n, "-320.jpg 320w, /photos/p"_s, n, "-640.jpg 640w, /photos/p"_s, n, "-1280.jpg 1280w\""_s);
        else if (srcset == 3)
            builder.append(" srcset=\"/photos/p"_s, n, ".jpg 1x, /photos/p"_s, n, "@2x.jpg 2x\""_s);
        if (srcset == 1 || srcset == 2) {
            auto sizes = sizesValues[generator.below(std::size(sizesValues))];
            builder.append(" sizes=\""_s, sizes, '"');
        }
        unsigned extra = generator.below(8);
        if (extra == 0)
            builder.append(" loading=\"lazy\""_s);
        else if (extra == 1)
            builder.append(" loading=\"eager\" fetchpriority=\"high\""_s);
        else if (extra == 2)
            builder.append(" referrerpolicy=\"no-referrer\""_s);
        else if (extra == 3)
            builder.append(" crossorigin=\"anonymous\""_s);
        builder.append(" alt=\"Photo "_s, n, "\" width=\"640\" height=\"480\"><figcaption>"_s);
        appendProse(builder, generator, 40);
        builder.append("</figcaption></figure>\n"_s);
    }
    builder.append("</body></html>\n"_s);
    return builder.toString();
}

// A head and body of external and inline scripts (classic, module, nomodule, async, with nonce and integrity) and
// links (style sheets, preloads of each destination, module preloads, icons, alternates, prefetches).
static String scriptsAndLinks()
{
    static const ASCIILiteral preloadAs[] = { "script"_s, "style"_s, "font"_s, "image"_s, "fetch"_s, "track"_s, "video"_s, "unknown"_s };
    static const ASCIILiteral rels[] = { "icon"_s, "alternate stylesheet"_s, "dns-prefetch"_s, "preconnect"_s, "modulepreload"_s, "prefetch"_s,
        "canonical"_s, "manifest"_s };
    Generator generator(11);
    StringBuilder builder;
    appendHead(builder, "Scripts and links"_s);
    for (unsigned n = 0; builder.length() < 1 << 20; ++n) {
        unsigned kind = generator.below(12);
        switch (kind) {
        case 0:
            builder.append("<script src=\"/js/app"_s, n, ".js\"></script>\n"_s);
            break;
        case 1:
            builder.append("<script async src=\"https://cdn.example.net/lib/v"_s, n, "/lib.min.js\" integrity=\"sha384-oqVuAfXRKap7fdgcCY5uykM6+R9GqQ8K/uxy9rx7HNQlGYl1kPzQho1wx4JwY8wC\" crossorigin=\"anonymous\"></script>\n"_s);
            break;
        case 2:
            builder.append("<script type=\"module\" src=\"/js/module"_s, n, ".mjs\" nonce=\"r4nd0m"_s, n, "\"></script>\n"_s);
            break;
        case 3:
            builder.append("<script nomodule src=\"/js/legacy"_s, n, ".js\" defer></script>\n"_s);
            break;
        case 4:
            builder.append("<script>window.dataLayer = window.dataLayer || []; dataLayer.push({ id: "_s, n, ", page: '/index' });</script>\n"_s);
            break;
        case 5:
            builder.append("<script type=\"text/template\" id=\"t"_s, n, "\"><div class=\"item\"><img src=\"/never"_s, n, ".png\"></div></script>\n"_s);
            break;
        case 6:
            builder.append("<link rel=\"stylesheet\" href=\"/css/site"_s, n, ".css\" media=\"screen\">\n"_s);
            break;
        case 7: {
            auto as = preloadAs[generator.below(std::size(preloadAs))];
            builder.append("<link rel=\"preload\" href=\"/assets/a"_s, n, "\" as=\""_s, as, "\" crossorigin>\n"_s);
            break;
        }
        case 8: {
            auto rel = rels[generator.below(std::size(rels))];
            builder.append("<link rel=\""_s, rel, "\" href=\"/r/"_s, n, "\">\n"_s);
            break;
        }
        case 9:
            builder.append("<link rel=\"stylesheet\" href=\"/css/print"_s, n, ".css\" media=\"print\" referrerpolicy=\"origin\" fetchpriority=\"low\">\n"_s);
            break;
        case 10:
            builder.append("<link rel=\"preload\" as=\"image\" href=\"/hero"_s, n, ".jpg\" imagesrcset=\"/hero"_s, n, "-800.jpg 800w, /hero"_s, n, "-1600.jpg 1600w\" imagesizes=\"100vw\">\n"_s);
            break;
        default:
            builder.append("<p>"_s);
            appendProse(builder, generator, 120);
            builder.append("</p>\n"_s);
            break;
        }
    }
    builder.append("</body></html>\n"_s);
    return builder.toString();
}

static const ASCIILiteral imageTypes[] = { "image/avif"_s, "image/webp"_s, "image/jxl"_s, "image/jpeg"_s, "image/png"_s, "image/x-unknown"_s };
static const ASCIILiteral sourceMedia[] = { "(min-width: 800px)"_s, "(max-width: 799px)"_s, "screen and (orientation: landscape)"_s, "print"_s,
    "(prefers-color-scheme: dark)"_s, "all"_s };

// <picture> elements with one to four <source>s (type, media, srcset with descriptors), then an <img> (some lazy,
// some missing). The alt text is not Latin-1, so the document is 16-bit.
static String pictureSources()
{
    Generator generator(13);
    StringBuilder builder;
    appendHead(builder, "Pictures"_s);
    for (unsigned n = 0; builder.length() < 1 << 20; ++n) {
        builder.append("<picture>"_s);
        unsigned sources = 1 + generator.below(4);
        for (unsigned i = 0; i < sources; ++i) {
            builder.append("<source srcset=\"/img/i"_s, n, '-', i, ".img 1x, /img/i"_s, n, '-', i, "@2x.img 2x\""_s);
            unsigned attributes = generator.below(4);
            if (attributes & 1) {
                auto type = imageTypes[generator.below(std::size(imageTypes))];
                builder.append(" type=\""_s, type, '"');
            }
            if (attributes & 2) {
                auto media = sourceMedia[generator.below(std::size(sourceMedia))];
                builder.append(" media=\""_s, media, '"');
            }
            builder.append('>');
        }
        unsigned image = generator.below(6);
        if (image) {
            builder.append("<img src=\"/img/i"_s, n, ".jpg\" alt=\""_s, std::span<const char16_t>(u"\u5199\u771F", 2), ' ', n, '"');
            if (image == 1)
                builder.append(" loading=\"lazy\""_s);
            builder.append('>');
        }
        builder.append("</picture>\n<p>"_s);
        appendProse(builder, generator, 60);
        builder.append("</p>\n"_s);
    }
    builder.append("</body></html>\n"_s);
    return builder.toString();
}

static const ASCIILiteral importForms[] = { "@import url(\"/css/a.css\");"_s, "@import url(/css/b.css);"_s, "@import '/css/c.css';"_s,
    "@import \"/css/d.css\" layer;"_s, "@import url('/css/e.css') layer(base);"_s, "@import \"/css/f.css\" screen;"_s,
    "@import url( /css/g.css );"_s, "@IMPORT \"/css/h.css\";"_s, "@layer reset, base;"_s, "/* imports */"_s, "@import url(\"/css/i\\\".css\");"_s };

// <style> elements that start with comments, @charset and @import rules in each form the scanner reads, then rules,
// with text between them.
static String styleImports()
{
    Generator generator(17);
    StringBuilder builder;
    appendHead(builder, "Style"_s);
    while (builder.length() < 1 << 20) {
        builder.append("<style>\n"_s);
        if (!generator.below(3))
            builder.append("@charset \"utf-8\";\n"_s);
        unsigned imports = 2 + generator.below(10);
        for (unsigned i = 0; i < imports; ++i) {
            auto form = importForms[generator.below(std::size(importForms))];
            builder.append("  "_s, form, '\n');
        }
        unsigned rules = generator.below(6);
        for (unsigned i = 0; i < rules; ++i)
            builder.append(".rule"_s, i, " { color: #333; margin: 0 auto; background: url(/img/bg"_s, i, ".png) }\n"_s);
        builder.append("</style>\n<p>"_s);
        appendProse(builder, generator, 80);
        builder.append("</p>\n"_s);
    }
    builder.append("</body></html>\n"_s);
    return builder.toString();
}

static const ASCIILiteral unrelatedNames[] = { "id"_s, "class"_s, "title"_s, "style"_s, "role"_s, "tabindex"_s, "hidden"_s, "draggable"_s,
    "data-id"_s, "data-index"_s, "data-state"_s, "data-testid"_s, "data-track"_s, "aria-label"_s, "aria-hidden"_s, "aria-describedby"_s,
    "aria-expanded"_s, "itemprop"_s, "itemscope"_s, "lang"_s, "dir"_s, "translate"_s, "width"_s, "height"_s, "decoding"_s, "name"_s,
    "value"_s, "placeholder"_s, "autocomplete"_s, "onclick"_s, "onload"_s, "is"_s };
static const ASCIILiteral unrelatedValues[] = { ""_s, "x"_s, "1"_s, "true"_s, "main"_s, "item active"_s, "btn btn-primary"_s,
    "display:none"_s, "Open menu"_s, "auto"_s, "ltr"_s, "en-US"_s, "640"_s };
static const ASCIILiteral scannedTags[] = { "img"_s, "link"_s, "script"_s, "input"_s, "video"_s, "meta"_s, "source"_s };

// Scanned tags (img, link, script, input, video, meta, source) with 10 to 30 attributes the scanner does not read,
// and the one it does.
static String manyAttributes()
{
    Generator generator(19);
    StringBuilder builder;
    appendHead(builder, "Attributes"_s);
    for (unsigned n = 0; builder.length() < 1 << 20; ++n) {
        unsigned tag = generator.below(std::size(scannedTags));
        builder.append('<', scannedTags[tag]);
        unsigned count = 10 + generator.below(21);
        unsigned key = generator.below(count);
        for (unsigned i = 0; i < count; ++i) {
            if (i == key) {
                switch (tag) {
                case 0:
                    builder.append(" src=\"/a/"_s, n, ".png\""_s);
                    break;
                case 1:
                    builder.append(" rel=\"stylesheet\" href=\"/a/"_s, n, ".css\""_s);
                    break;
                case 2:
                    builder.append(" src=\"/a/"_s, n, ".js\""_s);
                    break;
                case 3:
                    builder.append(" type=\"image\" src=\"/a/"_s, n, ".gif\""_s);
                    break;
                case 4:
                    builder.append(" poster=\"/a/"_s, n, ".jpg\""_s);
                    break;
                default:
                    builder.append(" content=\"c"_s, n, '"');
                    break;
                }
            }
            auto name = unrelatedNames[generator.below(std::size(unrelatedNames))];
            auto value = unrelatedValues[generator.below(std::size(unrelatedValues))];
            builder.append(' ', name, "=\""_s, value, '"');
        }
        builder.append(tag == 2 ? "></script>\n"_s : ">\n"_s);
    }
    builder.append("</body></html>\n"_s);
    return builder.toString();
}

// Long paragraphs with sparse inline markup and an occasional image.
static String textHeavy()
{
    Generator generator(23);
    StringBuilder builder;
    appendHead(builder, "Text"_s);
    for (unsigned n = 0; builder.length() < 1 << 20; ++n) {
        builder.append("<p>"_s);
        for (unsigned i = 0; i < 8; ++i) {
            appendProse(builder, generator, 256);
            unsigned markup = generator.below(8);
            if (markup == 0)
                builder.append("<a href=\"/article/"_s, n, "\">link</a> "_s);
            else if (markup == 1)
                builder.append("<em>emphasis</em> "_s);
            else if (markup == 2)
                builder.append("<b>bold</b> "_s);
        }
        builder.append("</p>\n"_s);
        if (!generator.below(16))
            builder.append("<img src=\"/figure"_s, n, ".png\" alt=\"figure\">\n"_s);
    }
    builder.append("</body></html>\n"_s);
    return builder.toString();
}

// <template>s, whose contents make no requests unless the template is a declarative shadow root (<template
// shadowrootmode>) outside any other template, and SVG, whose <script> and <image> make none, between paragraphs with
// images and scripts.
static String templatesAndForeignContent()
{
    static const ASCIILiteral shadowRootModes[] = { "open"_s, "closed"_s, "OPEN"_s, ""_s, "none"_s };
    Generator generator(29);
    StringBuilder builder;
    appendHead(builder, "Templates and SVG"_s);
    for (unsigned n = 0; builder.length() < 1 << 20; ++n) {
        unsigned kind = generator.below(8);
        switch (kind) {
        case 0:
            builder.append("<template id=\"row\"><tr><td><img src=\"/t/row"_s, n, ".png\"><script src=\"/t/row"_s, n, ".js\"></script></td></tr></template>\n"_s);
            break;
        case 1: {
            auto mode = shadowRootModes[generator.below(std::size(shadowRootModes))];
            builder.append("<div><template shadowrootmode=\""_s, mode, "\"><link rel=\"stylesheet\" href=\"/dsd/card"_s, n, ".css\"><img src=\"/dsd/card"_s, n, ".png\"><slot></slot></template>card</div>\n"_s);
            break;
        }
        case 2:
            builder.append("<template><div><template shadowrootmode=\"open\"><img src=\"/nested/n"_s, n, ".png\"></template></div><style>@import '/t/n"_s, n, ".css';</style></template>\n"_s);
            break;
        case 3:
            builder.append("<svg viewBox=\"0 0 24 24\" width=\"24\"><script href=\"/svg/s"_s, n, ".js\"></script><image href=\"/svg/i"_s, n, ".png\" width=\"24\"/><path d=\"M0 0h24v24H0z\"/></svg>\n"_s);
            break;
        case 4:
            builder.append("<svg><g><svg><script src=\"/svg/nested"_s, n, ".js\"></script></svg><img src=\"/svg/img"_s, n, ".png\"></g></svg><script src=\"/js/after-svg"_s, n, ".js\"></script>\n"_s);
            break;
        case 5:
            builder.append("<image src=\"/image/i"_s, n, ".png\"><math><mi>x</mi></math>\n"_s);
            break;
        default:
            builder.append("<p><img src=\"/p/i"_s, n, ".png\" alt=\"\">"_s);
            appendProse(builder, generator, 160);
            builder.append("</p><script src=\"/p/s"_s, n, ".js\"></script>\n"_s);
            break;
        }
    }
    builder.append("</body></html>\n"_s);
    return builder.toString();
}

static Input specPageInput()
{
    return networkChunks(specPage());
}

static Input imageGalleryInput()
{
    return networkChunks(imageGallery());
}

static Input scriptsAndLinksInput()
{
    return networkChunks(scriptsAndLinks());
}

static Input pictureSourcesInput()
{
    return networkChunks(pictureSources());
}

static Input styleImportsInput()
{
    return networkChunks(styleImports());
}

static Input manyAttributesInput()
{
    return networkChunks(manyAttributes());
}

static Input textHeavyInput()
{
    return networkChunks(textHeavy());
}

static Input templatesAndForeignContentInput()
{
    return networkChunks(templatesAndForeignContent());
}

} // namespace

TEST(HTMLPreloadScannerBench, SpecPage)
{
    runBenchmark("SpecPage"_s, specPageInput(), 80, 0xf184214d9b804f84ull);
}

TEST(HTMLPreloadScannerBench, ImageGallery)
{
    runBenchmark("ImageGallery"_s, imageGalleryInput(), 320, 0x178a1b753c27eb78ull);
}

TEST(HTMLPreloadScannerBench, ScriptsAndLinks)
{
    runBenchmark("ScriptsAndLinks"_s, scriptsAndLinksInput(), 330, 0xd7de09584c8db0edull);
}

TEST(HTMLPreloadScannerBench, PictureSources)
{
    runBenchmark("PictureSources"_s, pictureSourcesInput(), 290, 0x5be37178ebcc22c8ull);
}

TEST(HTMLPreloadScannerBench, StyleImports)
{
    runBenchmark("StyleImports"_s, styleImportsInput(), 520, 0x69e5139326039862ull);
}

TEST(HTMLPreloadScannerBench, ManyAttributes)
{
    runBenchmark("ManyAttributes"_s, manyAttributesInput(), 190, 0xea6ac6eadf784a35ull);
}

TEST(HTMLPreloadScannerBench, TextHeavy)
{
    runBenchmark("TextHeavy"_s, textHeavyInput(), 3500, 0xd2989da5803eeae9ull);
}

TEST(HTMLPreloadScannerBench, TemplatesAndForeignContent)
{
    runBenchmark("TemplatesAndForeignContent"_s, templatesAndForeignContentInput(), 360, 0x0819cd5c323cb400ull);
}

// @import rules whose name, URL or conditions are about 256 code units long, the most the Swift scanner keeps
// between rules. Chunk ends cut the name, the conditions and the last URL. A rule cut inside its URL is taken as
// it stands at the end of the chunk, and the rest of that <style> is not scanned.
TEST(HTMLPreloadScannerBench, LongImportRules)
{
    ensureTestPlatformStrategiesInstalled();
    ProcessWarming::initializeNames();

    auto settings = Settings::create(nullptr);
    auto document = createDocument(settings);
    auto repeated = [](char character, unsigned length) {
        return String::fromLatin1(std::string(length, character).c_str());
    };
    auto importRequest = [](const String& url) {
        return makeString("initiator=css url=\""_s, url, "\" base=null charset=null media=null crossOrigin=null nonce=null integrity=null async=0 type=3 scriptType=0 referrerPolicy=0 fetchPriority=2\n"_s);
    };
    for (unsigned length : { 181u, 182u, 255u, 256u, 257u }) {
        Input input;
        input.chunks.append(makeString("<style>@"_s, repeated('a', length / 2)));
        input.chunks.append(makeString(repeated('a', length - length / 2), ";@import 'a.css';@import '"_s, repeated('b', length - 2),
            "';@import 'c.css' layer("_s, repeated('x', length / 2)));
        input.chunks.append(makeString(repeated('x', length - 7 - length / 2), ");@import url("_s, repeated('d', length - 4)));
        input.chunks.append(String { "d);@import 'never.css';</style><style>@import 'e.css';</style>"_s });
        StringBuilder requests;
        scanInput(document, input, [&](PreloadRequestStream&& stream) {
            for (auto& request : stream)
                requests.append(request->descriptionForTesting(), '\n');
        });
        auto expected = makeString(importRequest("a.css"_s), importRequest(repeated('b', length - 2)), importRequest("c.css"_s),
            importRequest(makeString("url("_s, repeated('d', length - 4))), importRequest("e.css"_s));
        EXPECT_EQ(requests.toString().utf8().toStdString(), expected.utf8().toStdString()) << "length " << length;
    }
}

} // namespace TestWebKitAPI
