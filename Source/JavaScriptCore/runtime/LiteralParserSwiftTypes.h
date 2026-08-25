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

// Boundary types for the Swift JSON parser island (LiteralParserSwift.swift).
//
// Everything the island and LiteralParser share is defined here in C++, and resilience is not
// the reason — `@frozen` plus `@usableFromInline` gives a Swift-defined struct inline storage
// of the real size even under BUILD_LIBRARY_FOR_DISTRIBUTION. What no annotation changes is
// that the generated C++ class keeps a *private* default constructor and routes destroy, copy
// and copy-assign through the value witness table behind a metadata accessor, however
// trivially copyable its fields are. So it is never a C++ aggregate: WTF's Vector would run
// initialization over the whole buffer (`CSSSwiftToken` documents that trap on the WebCore
// side) and every copy would be an indirect call. Usable for a single returned value, which is
// all JSONSwiftColdResult has to be, and for nothing the two sides share by address.
//
// Self-contained on purpose — only <cstdint>, <cstddef> and <span> — so it can be
// exposed to Swift as its own narrow module in JavaScriptCore_Private.modulemap
// without dragging JavaScriptCore internals into a Clang module.

#pragma once

#include <cstddef>
#include <cstdint>
#include <span>

namespace JSC {

// The source text, as a std::span because Swift's `Span` is not C++-representable. Named
// typedefs rather than the templates inline, because `@_expose(Cxx)` needs a concrete type.
using JSONLexerSpan16 = std::span<const char16_t>;

// `uint8_t` rather than `Latin1Character` only because this header carries no WTF include;
// they are the same type. This is the width that decides whether the island runs in production
// at all, a `JSString` being 8-bit whenever every character is Latin1.
using JSONLexerSpan8 = std::span<const uint8_t>;

// Mirrors JSC::TokenType (LiteralParser.h:59) for the values the island can produce.
//
// It exists as the *proxy* by which the two numberings are checked. The island's Swift
// `JSONTokenType` is what crosses the boundary, in `literalValue`, and no C++ assertion can
// name a Swift enum — so this is transcribed by hand and LiteralParser.cpp asserts all 21
// values against `TokenType`. Delete it and the keyword path is an unchecked coincidence.
enum JSONSwiftTokenType : uint8_t {
    JSONSwiftTokLBracket = 0,
    JSONSwiftTokRBracket = 1,
    JSONSwiftTokLBrace = 2,
    JSONSwiftTokRBrace = 3,
    JSONSwiftTokString = 4,
    JSONSwiftTokIdentifier = 5,
    JSONSwiftTokNumber = 6,
    JSONSwiftTokNumberInt32 = 7,
    JSONSwiftTokColon = 8,
    JSONSwiftTokLParen = 9,
    JSONSwiftTokRParen = 10,
    JSONSwiftTokComma = 11,
    JSONSwiftTokTrue = 12,
    JSONSwiftTokFalse = 13,
    JSONSwiftTokNull = 14,
    JSONSwiftTokEnd = 15,
    JSONSwiftTokDot = 16,
    JSONSwiftTokAssign = 17,
    JSONSwiftTokSemi = 18,
    JSONSwiftTokError = 19,
    JSONSwiftTokErrorSpace = 20,

    // Island-internal, listed to keep the transcription complete: the grammar handles
    // both itself through the facade's cold paths below.
    JSONSwiftTokNeedsSlowString = 21,
    JSONSwiftTokNeedsDoubleParse = 22,
};

// Deliberately outside `#if JSC_SUPPORTS_SWIFT`, and load-bearing: nothing passes
// `-Xcc -DJSC_SUPPORTS_SWIFT=1` to the ClangImporter, so a declaration under that guard
// is invisible to Swift, with the importer reporting "'X' is not a member type of enum
// '__ObjC.JSC'". Only the implementation needs guarding.

// MARK: - The object-model facade the Swift grammar builds through
//
// Derived from what `parseRecursively` does to the object model
// (LiteralParser.cpp:1512), not invented, and shaped by three constraints:
//
//  1. Swift must not name a cell type. Materializing `JSC::Structure` fails because WTF
//     templates over JSC types instantiate inside module `wtf`, where the definitions
//     are unreachable, and three of the five failures are wtf-internal.
//  2. Swift must not hold a cell, in a frame or inside a `JSValue` — the
//     conservative-stack-scan question, which cells never reaching Swift's hands closes.
//  3. The store sequence must stay atomic: between `nukeStructureAndSetButterfly` and
//     `setStructure` a conservatively-scanned cell is a release `die()`
//     (heap/SlotVisitor.cpp:188), so no Swift frame may sit inside it.
//
// So the facade owns the value stack and the `ThrowScope`, and the island only says what it
// saw, in document order, getting back a keep-going flag. The containers live in a fixed-size
// array inside `JSONSwiftObjectModelState`, which is a local of the C++ entry point: the
// conservative stack scan roots them, and the grammar declines a document nested deeper than
// the array holds. Strings cross as offsets, so no buffer and no lifetime crosses.

// `SWIFT_UNSAFE_REFERENCE` from wtf/SwiftBridging.h, spelled out rather than included
// because as a Clang module `wtf` is where the instantiation failures in (1) live. Unsafe
// rather than immortal because a cell's lifetime is the collector's business, and it is
// enforced: WebKit builds Swift with `-Werror StrictMemorySafety`
// (Configurations/CommonBase.xcconfig).
#if defined(__has_attribute) && __has_attribute(swift_attr)
#define JSC_SWIFT_UNSAFE_REFERENCE                    \
    __attribute__((swift_attr("import_reference")))    \
    __attribute__((swift_attr("retain:immortal")))     \
    __attribute__((swift_attr("release:immortal")))    \
    __attribute__((swift_attr("unsafe")))
#else
#define JSC_SWIFT_UNSAFE_REFERENCE
#endif

// `SWIFT_SAFE` (wtf/SwiftBridging.h:394), spelled out for the same reason as the reference
// annotation above, and the counterpart to it: the class is unsafe, each *call* on it is not.
// SE-0458's `@safe` takes responsibility for the unsafe-typed direct arguments of a call, the
// `self` included, which is what a facade method that neither escapes the receiver nor
// outlives the call can honestly promise. Deliberately weaker than
// `SWIFT_IMMORTAL_REFERENCE`, which would be a lie: an *escape* of the receiver still
// diagnoses. Diagnostic only, so no member below changes shape.
#if defined(__has_attribute) && __has_attribute(swift_attr)
#define JSC_SWIFT_SAFE __attribute__((swift_attr("safe")))
#else
#define JSC_SWIFT_SAFE
#endif

// Defined in LiteralParser.cpp, where the object model's headers are available. Only a
// pointer to it appears here, so this header stays free of JavaScriptCore internals.
struct JSONSwiftObjectModelState;

// Why the island's parse stopped. A declined document is re-parsed by the C++ from the top,
// which keeps the error text byte-identical for free and is safe because StrictJSON runs no
// user code, so the half-built graph is unobservable.
enum JSONSwiftParseStatus : uint8_t {
    // The document is complete and the state holds the result.
    JSONSwiftParseOK = 0,
    // Nesting deeper than its stack, or a malformed document whose diagnostic the island
    // does not produce yet. Re-parse in C++.
    JSONSwiftParseDeclined = 1,
    // The object model told the island to stop; `sawException` says whether an exception
    // must be propagated or the document re-parses.
    JSONSwiftParseStopped = 2,
    // Malformed, and the island said *which* way: it formatted the message itself through
    // `errorMessage` below, so the C++ does not lex the document a second time. That is the
    // whole of the distinction from `Declined`, which runs the C++ lexer over every
    // attacker-chosen byte again.
    JSONSwiftParseFailed = 3,
};

// MARK: - Which diagnostic a failed parse produces
//
// Every message strict `JSON.parse` can spell is prefix + a quoted run of the document +
// suffix, with `getErrorMessage`'s "JSON Parse error: " (LiteralParser.h:146) already inside
// the prefix. So the literals live in Swift, beside the code that detects each condition, and
// what crosses is two spans of ASCII and the offsets of the run — see `errorMessage` below. No
// error *kind* crosses the boundary, so there is no table on this side to keep in step.
//
// Two rules the island has to keep, both from the C++'s own structure:
//
//  1. A lexer-level diagnostic wins over a grammar-level one, always: `getErrorMessage`
//     prefers `m_lexErrorMessage` to `m_parseErrorMessage`, and every `return TokError` site
//     in the lexer sets a message within three lines of the return. So whoever detects first
//     formats, and the grammar must never overwrite what the lexer reported — get it backwards
//     and `[1e]` reports "Expected ']'" instead of "Invalid number". Enforced on both sides:
//     the island reports at the point of detection, and `errorMessage` keeps the first message.
//  2. Three of the file's messages are unreachable here and are deliberately absent.
//     "Could not parse value expression" is always shadowed by rule 1; "Attempted to redefine
//     __proto__ property" is guarded by `parserMode != StrictJSON` (LiteralParser.cpp:1578);
//     "Unexpected content at end of JSON literal" belongs to
//     `tryLiteralParsePrimitiveValue`, i.e. `JSON.rawJSON`.

// `__counted_by(n)` plus `noescape` is what makes the importer synthesize a `Span`-taking
// overload beside the pointer+count one, so the island hands text across with no `unsafe` at
// the call site and no table on this side (`CSSSwiftTokenSink::takeChunk` is the same mechanism
// in WebCore). Both attributes are required: `counted_by` alone imports as
// `UnsafeBufferPointer`, `noescape` alone as pointer+count. They must also be repeated on the
// definition, which in C++ is a different type without them.
//
// Spelled here rather than included because this header stays free of WTF, and guarded
// because a compiler without them still has to compile the C++ side — where the fallback
// costs the island its safe overload, so `JSC_SUPPORTS_SWIFT` would not build.
#if defined(__counted_by)
#define JSC_SWIFT_COUNTED_BY(x) __counted_by(x)
#else
#define JSC_SWIFT_COUNTED_BY(x)
#endif
#if defined(__has_attribute) && __has_attribute(noescape)
#define JSC_SWIFT_NOESCAPE __attribute__((noescape))
#else
#define JSC_SWIFT_NOESCAPE
#endif

// What a cold path did. `endOffset` is where the island's lexer resumes, in code units from
// the start of the input, and is only meaningful for JSONSwiftParseOK.
struct JSONSwiftColdResult {
    // ptrdiff_t so that Swift sees an `Int` and the island's cursor needs no conversion.
    ptrdiff_t endOffset { 0 };
    // A JSONSwiftParseStatus, so the island can return it unchanged.
    uint8_t status { JSONSwiftParseOK };
};

class JSC_SWIFT_UNSAFE_REFERENCE JSONSwiftObjectModel {
public:
    // Non-copyable and non-movable, like the cells it stands in front of, which is what
    // makes the annotation above necessary: without it the importer drops the class for
    // having no Swift value representation.
    JSONSwiftObjectModel(const JSONSwiftObjectModel&) = delete;
    JSONSwiftObjectModel& operator=(const JSONSwiftObjectModel&) = delete;
    JSONSwiftObjectModel(JSONSwiftObjectModel&&) = delete;
    JSONSwiftObjectModel& operator=(JSONSwiftObjectModel&&) = delete;

    // The C++ entry point owns both the state and this, on its own stack.
    explicit JSONSwiftObjectModel(JSONSwiftObjectModelState& state)
        : m_state(&state)
    {
    }

    // Every one returns false to mean "stop" — an exception is pending, or the document
    // is structurally bad — and the C++ reads the reason out of the state.
    JSC_SWIFT_SAFE bool beginObject();
    JSC_SWIFT_SAFE bool beginArray();
    JSC_SWIFT_SAFE bool endContainer();
    // `[]`, which the grammar recognises as a token pair and so knows the length the
    // general close has to derive. Its own entry because the C++ short-circuits the same
    // shape before it ever pushes an element-stack base (:1479).
    JSC_SWIFT_SAFE bool emptyArray();

    // The pending property name, as an offset into the input. Resolution happens at the
    // store rather than here, so no `Structure*` is held across the value's parse — which
    // is equivalent for StrictJSON, where no user code can run, and makes the store
    // atomic.
    JSC_SWIFT_SAFE bool key(uint32_t start, uint32_t length);

    JSC_SWIFT_SAFE bool stringValue(uint32_t start, uint32_t length);
    JSC_SWIFT_SAFE bool intValue(int32_t);
    JSC_SWIFT_SAFE bool doubleValue(double);
    // A `JSONTokenType` raw value: true, false or null.
    JSC_SWIFT_SAFE bool literalValue(uint8_t code);

    // MARK: The one remaining cold path, reached from inside the island's grammar loop
    //
    // `parseJSONDouble` stays in C++ and should: it is a correctly-rounded decimal-to-double
    // conversion shared with the rest of WTF, so porting it would be replacing vetted code
    // with new code, with bit-exactness as the acceptance test and no safety to gain.
    //
    // Reached from inside the grammar loop rather than by unwinding and being re-entered,
    // which is what keeps the island's shape the same as the C++ parse's. `initial` is the C++
    // `initial`, i.e. the optional '-'; where the island's scan stopped is not passed, since
    // `parseJSONDouble` re-scans from there.
    JSC_SWIFT_SAFE JSONSwiftColdResult slowNumberValue(uint32_t initial);

    // MARK: An escaped string, decoded by the island rather than declined
    //
    // The island scans and decodes the escapes and emits the result as alternating runs of
    // literal input and single decoded units; these hold them in a `StringBuilder` the
    // object-model state owns — built on the first escape, since most documents have none —
    // and then make one cell out of it. There is no C++ fallback: the island decodes every
    // escaped string it accepts and declines the rest to the C++ re-parse, which is what keeps
    // the error messages byte-identical for free — and what makes a wrong decoder show up
    // instead of hiding behind a fallback that would produce the same answer.
    //
    // A call per run rather than a decoded buffer handed across, because the buffer is where
    // the 8-bit-to-16-bit upconversion policy lives and that policy decides the resulting
    // string's representation. Chatty by design, and cold per *document*: escapes are 0% to 4%
    // of the strings in real payloads. On escape-dense input these become per-value crossings,
    // so they are marked JSC_JSON_FACADE_ENTRY like the value entries; their only caller is
    // the island's `decodeEscapedString`, which is itself out of line and cold.
    JSC_SWIFT_SAFE bool escapeBegin();
    JSC_SWIFT_SAFE bool escapeRun(uint32_t start, uint32_t length);
    JSC_SWIFT_SAFE bool escapeUnit(uint16_t unit);
    // `endOffset` is the offset just past the closing quote, which the island computed.
    JSC_SWIFT_SAFE JSONSwiftColdResult escapeFinishValue(ptrdiff_t endOffset);
    JSC_SWIFT_SAFE JSONSwiftColdResult escapeFinishKey(ptrdiff_t endOffset);

    // MARK: The message, for a document the island refuses rather than declines
    //
    // The island formats it and this side allocates it: `prefix` and `suffix` are the ASCII
    // literal parts, and `quoteStart`/`quoteLength` name the run of the *document* that goes
    // between them — 0/0 for the messages that quote nothing, which is most of them. One
    // crossing per failing document, and one `tryMakeString` here. The run crosses as offsets
    // rather than characters for the same reason a property name does: the document is already
    // in hand on this side, at a width the island does not have to know, so the 8-bit case
    // stays 8-bit and quoting is a `subspan`.
    //
    // Both offsets are bounds-checked here, being an invariant of the *other* language. A range
    // that does not bound — like a `String` that cannot be allocated — leaves no message at
    // all, which makes the document decline to the C++ re-parse and produce the same text the
    // slow way, so the island needs no fallback of its own (:1324 is the C++'s).
    //
    // Void, and the return path is the status rather than this call, because there is nothing
    // for the object model to say: no cell is made and no exception can be thrown here.
    JSC_SWIFT_SAFE void errorMessage(
        const uint8_t* JSC_SWIFT_COUNTED_BY(prefixLength) JSC_SWIFT_NOESCAPE prefix,
        size_t prefixLength, uint32_t quoteStart, uint32_t quoteLength,
        const uint8_t* JSC_SWIFT_COUNTED_BY(suffixLength) JSC_SWIFT_NOESCAPE suffix,
        size_t suffixLength);

private:
    JSONSwiftObjectModelState* m_state { nullptr };
};

#if defined(JSC_SUPPORTS_SWIFT) && JSC_SUPPORTS_SWIFT

// Reached through plain C++ rather than the generated `JavaScriptCore-Swift.h` thunks,
// because JSC is two targets: the island is compiled by the framework target, while its
// consumer is compiled into libJavaScriptCore, which cannot see that target's generated
// header. So the call into Swift lives in LiteralParserSwiftBridge.cpp, which the
// framework target compiles, and everything else goes through these declarations.
// WebCore needs no equivalent, being a single target.

// Parses a whole document, building it through the facade as it goes: the island owns the
// grammar as well as the lexer, and only a JSONSwiftParseStatus crosses back. Strict JSON, no
// reviver, one entry point per code-unit width, and one call per document — the cold paths are
// reached through the facade from inside the grammar loop, so this is not re-entered
// mid-document. One facade type serves both widths because nothing in its interface names a
// character; what knows the width is `JSONSwiftObjectModelState`, forward-declared above.
uint8_t jsonSwiftParseDocument16(std::span<const char16_t> input, JSONSwiftObjectModel&);
uint8_t jsonSwiftParseDocument8(std::span<const uint8_t> input, JSONSwiftObjectModel&);

#endif // JSC_SUPPORTS_SWIFT

} // namespace JSC
