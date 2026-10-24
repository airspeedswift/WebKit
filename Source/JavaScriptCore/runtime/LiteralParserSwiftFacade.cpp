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

// LiteralParser's entry points, which parse in Swift (LiteralParserSwift.swift), and the JSONParseSink the Swift
// reports to. This file is in the framework target, the one that compiles the Swift and so has its generated header.

#include "config.h"
#include "LiteralParser.h"

#if USE_SWIFT_JSON_PARSER

#include "CodeBlock.h"
#include "JSArray.h"
#include "JSCInlines.h"
#include "JSONCacheInlines.h"
#include "Lexer.h"
#include "ObjectConstructor.h"
#include <wtf/ForbidHeapAllocation.h>
#include <wtf/Range.h>
#include <wtf/SIMDHelpers.h>

#include "JavaScriptCore-Swift.h"

namespace JSC {

namespace {

constexpr unsigned maximumRangesStackRecursion = 4500;

enum class FrameKind : uint8_t { None, Array, Object };

// Every value the parse makes, on the stack of the entry point, so the collector finds each one. The innermost
// container is `top`, a member, so its Structures stay on the stack too. The 32 frames around it are in
// `savedFrames`, also a member; frames beyond those, and every frame of a parse that records source ranges, are in
// `frames`, with their cells in `frameCells`. A sink for one mode parses only that mode.
template<typename CharType, JSONParseSinkMode sinkMode>
struct JSONParseState final : public JSONParseSink<CharType, sinkMode> {
    WTF_FORBID_HEAP_ALLOCATION;
public:
    struct Frame {
        FrameKind kind;
        unsigned elementStackBase;
        JSObject* container;
        Structure* structure;
        uint8_t structureNameIndex;
        // The pending property: a transition to propertyStructure at propertyOffset, or else propertyName.
        Structure* originalStructure;
        Structure* propertyStructure;
        PropertyOffset propertyOffset;
        Identifier propertyName;
    };

    JSONParseState(JSGlobalObject* globalObject, CodeBlock* nullOrCodeBlock, ParserMode mode, bool iterative, std::span<const CharType> input, JSONRanges* ranges, Vector<JSONPData>* jsonpResults)
        : globalObject(globalObject)
        , vm(globalObject->vm())
        , jsonCache(vm.jsonCache())
        , nullOrCodeBlock(nullOrCodeBlock)
        , parserMode(mode)
        , isIterative(iterative)
        , input(input)
        , sourceRanges(ranges)
        , jsonpResults(jsonpResults)
    {
        // Source ranges are recorded only by the iterative parse, which keeps every frame in frames.
        RELEASE_ASSERT(!ranges || iterative);
        RELEASE_ASSERT(sinkMode == JSONParseSinkMode::Any || (!iterative && mode == this->mode()));
    }

    ~JSONParseState()
    {
        // A moved-from frame owns nothing: only propertyName has a destructor, and moving it leaves it null. A copy or
        // move of the state would destroy the saved frames twice.
        static_assert(std::is_nothrow_move_constructible_v<Frame> && !std::is_copy_constructible_v<JSONParseState> && !std::is_move_constructible_v<JSONParseState>);
        for (auto& saved : std::span { savedFrames }.first(savedFrameCount))
            std::destroy_at(&saved.frame);
    }

    ParserMode mode() const { return sinkMode == JSONParseSinkMode::Strict ? StrictJSON : sinkMode == JSONParseSinkMode::Sloppy ? SloppyJSON : parserMode; }
    bool iterative() const { return sinkMode == JSONParseSinkMode::Any && isIterative; }
    JSONRanges* ranges() const { return sinkMode == JSONParseSinkMode::Any ? sourceRanges : nullptr; }

    ALWAYS_INLINE bool beginContainer(Frame&& frame, size_t start)
    {
        if (!ranges() && savedFrameCount < savedFrames.size()) [[likely]] {
            std::construct_at(&savedFrames[savedFrameCount++].frame, WTF::move(top));
            // Field by field: assigning the whole frame stores it to the stack and reads it back with loads wider
            // than those stores, which x86-64 does not forward from them.
            top.kind = frame.kind;
            top.elementStackBase = frame.elementStackBase;
            top.container = frame.container;
            top.structure = frame.structure;
            top.structureNameIndex = frame.structureNameIndex;
            top.originalStructure = frame.originalStructure;
            top.propertyStructure = frame.propertyStructure;
            top.propertyOffset = frame.propertyOffset;
            return true;
        }
        return beginContainerSlow(WTF::move(frame), start);
    }

    ALWAYS_INLINE bool endContainer(JSValue value, size_t end)
    {
        if (frames.isEmpty()) [[likely]] {
            RELEASE_ASSERT(savedFrameCount);
            top = WTF::move(savedFrames[--savedFrameCount].frame);
            return storeValue(value);
        }
        return endContainerSlow(value, end);
    }

    NEVER_INLINE bool beginContainerSlow(Frame&&, size_t start);
    NEVER_INLINE bool endContainerSlow(JSValue, size_t end);
    bool deliver(JSValue);
    bool storeProperty(Frame&, JSValue);

    NEVER_INLINE COLD bool throwOutOfMemory()
    {
        auto scope = DECLARE_THROW_SCOPE(vm);
        throwOutOfMemoryError(globalObject, scope);
        return false;
    }

    NEVER_INLINE void recordValueRange(JSValue value)
    {
        lastValueRange = { ranges()->record(value), valueRange, { } };
    }

    NEVER_INLINE void growOutOfLineStorage(JSObject* object, Structure* originalStructure, Structure* newStructure)
    {
        if (originalStructure->outOfLineCapacity() == newStructure->outOfLineCapacity())
            return;
        ASSERT(newStructure != originalStructure);
        Butterfly* newButterfly = object->allocateMoreOutOfLineStorage(vm, originalStructure->outOfLineCapacity(), newStructure->outOfLineCapacity());
        object->nukeStructureAndSetButterfly(vm, originalStructure->id(), newButterfly);
    }

    ALWAYS_INLINE bool storeTransition(Frame& frame, JSValue value)
    {
        JSObject* object = frame.container;
        Structure* newStructure = std::exchange(frame.propertyStructure, nullptr);
        Structure* originalStructure = frame.originalStructure;
        PropertyOffset offset = frame.propertyOffset;
        // Both capacities are zero while the properties still fit in inline storage, which
        // is the common case, and reading them means touching two Structures.
        if (offset >= firstOutOfLineOffset) [[unlikely]]
            growOutOfLineStorage(object, originalStructure, newStructure);

        validateOffset(offset);
        ASSERT(newStructure->isValidOffset(offset));
        // A property addition transition keeps the cell's type, inline flags, and indexing type,
        // so only the StructureID changes, and one barrier covers both stores.
        ASSERT(newStructure->typeInfo().type() == originalStructure->typeInfo().type());
        ASSERT(newStructure->indexingModeIncludingHistory() == originalStructure->indexingModeIncludingHistory());
        object->putDirectWithoutBarrier(offset, value);
        object->setStructureIDDirectly(newStructure->id());
        vm.writeBarrier(object);
        ASSERT(!newStructure->mayBePrototype());
        frame.structure = newStructure;
        return true;
    }

    // Same as deliver(), with the common cases of a parse without source ranges in line. A leaf value runs
    // no user code, so the object's structure is still the one its pending transition starts from, in any mode.
    template<bool isLeaf = false>
    ALWAYS_INLINE bool storeValue(JSValue value)
    {
        if (!iterative()) {
            if (top.kind == FrameKind::Array) {
                elementStack.append(value);
                if (elementStack.hasOverflowed()) [[unlikely]]
                    return throwOutOfMemory();
                return true;
            }
            if (top.kind == FrameKind::Object && (isLeaf || mode() == StrictJSON) && top.propertyStructure)
                return storeTransition(top, value);
        } else if (isLeaf && top.kind == FrameKind::Object && top.propertyStructure)
            return storeTransition(top, value);
        return deliver(value);
    }

    template<typename KeyCharType> ALWAYS_INLINE void resolveKey(std::span<const KeyCharType>, size_t charactersToEnd);
    JSArray* materializeArray(unsigned stackBase);
    ALWAYS_INLINE bool leafValue(JSValue value)
    {
        if (ranges())
            recordValueRange(value);
        return storeValue<true>(value);
    }

    JSGlobalObject* const globalObject;
    VM& vm;
    JSONCache& jsonCache;
    CodeBlock* const nullOrCodeBlock;
    static constexpr bool is8Bit = std::is_same_v<CharType, Latin1Character>;
    const ParserMode parserMode;
    const bool isIterative;
    const std::span<const CharType> input;
    JSONRanges* const sourceRanges;
    Vector<JSONPData>* const jsonpResults;
    Frame top { };
    // Slots [0, savedFrameCount) hold the saved frames. The rest were never constructed or hold a frame moved from by a
    // pop, which owns nothing, so a push constructs over them and only the saved ones are destroyed.
    union SavedFrame { SavedFrame() { } ~SavedFrame() { } Frame frame; };
    std::array<SavedFrame, 32> savedFrames;
    unsigned savedFrameCount { 0 };
    Vector<Frame, 16> frames;
    MarkedArgumentBuffer frameCells;
    MarkedArgumentBuffer elementStack;
    UncheckedKeyHashSet<JSObject*> visitedUnderscoreProto;
    Vector<JSONRanges::Entry, 8> rangesStack;
    JSONRanges::Entry lastValueRange;
    WTF::Range<unsigned> valueRange;
    std::optional<JSONCache::ParsingScope> parsingScope;
    Vector<JSONPPathEntry> jsonpPath;
    JSONPPathEntry jsonpEntry;
    JSValue result;
    ASCIILiteral errorMessage { };
    JSONParseFailure failure { };
};

struct JSONParseErrorMessageBuilder final : public JSONParseErrorMessage {
    StringBuilder builder { OverflowPolicy::RecordOverflow };
};

template<typename CharType, JSONParseSinkMode sinkMode>
bool JSONParseState<CharType, sinkMode>::beginContainerSlow(Frame&& frame, size_t start)
{
    if (ranges()) {
        if (rangesStack.size() >= maximumRangesStackRecursion) [[unlikely]] {
            auto scope = DECLARE_THROW_SCOPE(vm);
            throwStackOverflowError(globalObject, scope);
            return false;
        }
        RELEASE_ASSERT(start <= input.size());
        WTF::Range<unsigned> range { static_cast<unsigned>(start) };
        if (frame.kind == FrameKind::Array)
            rangesStack.append({ ranges()->record(frame.container), range, JSONRanges::Array { } });
        else
            rangesStack.append({ ranges()->record(frame.container), range, JSONRanges::Object { } });
    }
    frameCells.append(top.container ? JSValue(top.container) : jsNull());
    frameCells.append(top.originalStructure ? JSValue(top.originalStructure) : jsNull());
    frameCells.append(top.propertyStructure ? JSValue(top.propertyStructure) : jsNull());
    if (frameCells.hasOverflowed()) [[unlikely]]
        return throwOutOfMemory();
    frames.append(std::exchange(top, WTF::move(frame)));
    return true;
}

template<typename CharType, JSONParseSinkMode sinkMode>
bool JSONParseState<CharType, sinkMode>::endContainerSlow(JSValue value, size_t end)
{
    RELEASE_ASSERT(!frames.isEmpty() && frameCells.size() >= 3);
    if (ranges()) {
        auto entry = rangesStack.takeLast();
        RELEASE_ASSERT(entry.range.begin() <= end && end <= input.size());
        entry.range = { entry.range.begin(), static_cast<unsigned>(end) };
        lastValueRange = WTF::move(entry);
    }
    top = frames.takeLast();
    frameCells.shrink(frameCells.size() - 3);
    return storeValue(value);
}

template<typename CharType, JSONParseSinkMode sinkMode>
bool JSONParseState<CharType, sinkMode>::deliver(JSValue value)
{
    switch (top.kind) {
    case FrameKind::None:
        result = value;
        if (ranges())
            ranges()->setRoot(WTF::move(lastValueRange));
        return true;
    case FrameKind::Array: {
        auto scope = DECLARE_THROW_SCOPE(vm);
        JSArray* array = asArray(top.container);
        array->putDirectIndex(globalObject, array->length(), value);
        RETURN_IF_EXCEPTION(scope, false);
        if (ranges())
            std::get<JSONRanges::Array>(rangesStack.last().properties).append(WTF::move(lastValueRange));
        return true;
    }
    case FrameKind::Object:
        return storeProperty(top, value);
    }
    RELEASE_ASSERT_NOT_REACHED();
}

template<typename CharType, JSONParseSinkMode sinkMode>
bool JSONParseState<CharType, sinkMode>::storeProperty(Frame& frame, JSValue value)
{
    JSObject* object = frame.container;

    // After a nested value, user code may have run (e.g. due to a __proto__ setter in a nested object), which may
    // have changed the structure of the object. This invalidates any cached transition, so reset it to Identifier
    // to take the slow path. StrictJSON runs no user code.
    if (mode() != StrictJSON && frame.propertyStructure && object->structure() != frame.originalStructure) [[unlikely]] {
        frame.propertyName = Identifier::fromUid(vm, frame.propertyStructure->transitionPropertyName());
        frame.propertyStructure = nullptr;
    }

    if (frame.propertyStructure)
        return storeTransition(frame, value);

    auto scope = DECLARE_THROW_SCOPE(vm);
    Identifier ident = std::exchange(frame.propertyName, Identifier { });
    RELEASE_ASSERT(!ident.isNull());
    if (mode() != StrictJSON && ident == vm.propertyNames->underscoreProto) [[unlikely]] {
        if (!visitedUnderscoreProto.add(object).isNewEntry) [[unlikely]] {
            errorMessage = "Attempted to redefine __proto__ property"_s;
            return false;
        }
        PutPropertySlot slot(object, nullOrCodeBlock && nullOrCodeBlock->ownerExecutable()->isInStrictContext());
        JSValue(object).put(globalObject, ident, value, slot);
        RETURN_IF_EXCEPTION(scope, false);
    } else {
        if (std::optional<uint32_t> index = parseIndex(ident)) {
            object->putDirectIndex(globalObject, index.value(), value);
            RETURN_IF_EXCEPTION(scope, false);
        } else
            object->putDirect(vm, ident, value);
        if (ranges())
            std::get<JSONRanges::Object>(rangesStack.last().properties).set(ident.impl(), WTF::move(lastValueRange));
    }
    if (!ranges()) {
        frame.structure = object->structure();
        if (mode() == StrictJSON)
            frame.structureNameIndex = static_cast<uint8_t>(JSONCache::nameIndex(StructureID::encode(frame.structure)));
    }
    return true;
}

template<typename CharType, JSONParseSinkMode sinkMode> template<typename KeyCharType>
void JSONParseState<CharType, sinkMode>::resolveKey(std::span<const KeyCharType> key, size_t charactersToEnd)
{
    Frame& frame = top;
    RELEASE_ASSERT(frame.kind == FrameKind::Object);
    Structure* originalStructure = frame.structure;
    auto existingProperty = [&](Structure* structure, PropertyOffset offset) ALWAYS_INLINE_LAMBDA {
        if (mode() == StrictJSON)
            frame.structureNameIndex = static_cast<uint8_t>(JSONCache::nameIndex(StructureID::encode(structure)));
        frame.propertyStructure = structure;
        frame.propertyOffset = offset;
    };

    // LiteralParser.cpp's iterative parse() makes an Identifier for every key and caches no transitions, so the
    // JSONCache sees the same calls here. Without source ranges, the property addition putDirect would make is taken
    // directly.
    if (iterative()) {
        Ref<AtomStringImpl> ident = jsonCache.makeIdentifier(vm, key);
        if (!ranges() && !originalStructure->isDictionary()) {
            ASSERT(frame.container->structure() == originalStructure);
            frame.originalStructure = originalStructure;
            PropertyOffset offset = 0;
            if (Structure* newStructure = Structure::addPropertyTransitionToExistingStructure(originalStructure, ident.ptr(), 0, offset)) {
                if (mode() == StrictJSON || (newStructure->transitionPropertyName() != vm.propertyNames->underscoreProto && visitedUnderscoreProto.isEmpty()))
                    return existingProperty(newStructure, offset);
            }
        }
        frame.propertyName = Identifier::fromString(vm, WTF::move(ident));
        return;
    }

    ASSERT(frame.container->structure() == originalStructure);
    frame.originalStructure = originalStructure;

    if (Structure* transition = originalStructure->trySingleTransition()) {
        // This check avoids hash lookup and refcount churn in the common case of a matching single transition.
        // We don't want to follow property addition transitions if the property name is a symbol.
        SUPPRESS_UNCOUNTED_ARG if (transition->transitionKind() == TransitionKind::PropertyAddition
            && !transition->transitionPropertyAttributes()
            && !transition->transitionPropertyName()->isSymbol() && WTF::equal(transition->transitionPropertyName(), key)) {
            if (mode() == StrictJSON) {
                // JSONCache records a Latin1 name read from the source without escapes (charactersToEnd counts from
                // its first character to the end of the source, or is 0) when a name shorter than a stride of 8-bit
                // source has a whole stride after its opening quote.
                SUPPRESS_UNCOUNTED_LOCAL UniquedStringImpl* name = transition->transitionPropertyName();
                constexpr size_t stride8 = SIMD::stride<uint8_t>;
                if (charactersToEnd && name->is8Bit() && (sizeof(KeyCharType) == 2 || name->length() >= stride8 || charactersToEnd >= stride8))
                    jsonCache.addName(originalStructure, transition, transition->transitionOffset());
                return existingProperty(transition, transition->transitionOffset());
            }
            if (transition->transitionPropertyName() != vm.propertyNames->underscoreProto && visitedUnderscoreProto.isEmpty())
                return existingProperty(transition, transition->transitionOffset());
        }
    } else if (!originalStructure->isDictionary()) {
        // A decoded key is cached only at the width of the source.
        bool isCacheable = mode() == StrictJSON && (sizeof(KeyCharType) == 1 || !is8Bit);
        if (isCacheable) {
            if (Structure* transition = jsonCache.getTransition(originalStructure, key)) {
                PropertyOffset offset = transition->transitionOffset();
                jsonCache.addPrefixedName(originalStructure, transition, offset);
                return existingProperty(transition, offset);
            }
        }
        // This check avoids refcount churn in the common case of a cached Identifier.
        if (SUPPRESS_UNCOUNTED_LOCAL AtomStringImpl* ident = jsonCache.existingIdentifier(vm, key)) {
            PropertyOffset offset = 0;
            Structure* newStructure = Structure::addPropertyTransitionToExistingStructure(originalStructure, ident, 0, offset);
            if (newStructure) [[likely]] {
                if (mode() == StrictJSON) {
                    if (isCacheable) {
                        jsonCache.addTransition(originalStructure, newStructure, key);
                        jsonCache.addPrefixedName(originalStructure, newStructure, offset);
                    }
                    return existingProperty(newStructure, offset);
                }
                if (newStructure->transitionPropertyName() != vm.propertyNames->underscoreProto && visitedUnderscoreProto.isEmpty())
                    return existingProperty(newStructure, offset);
            }
            frame.propertyName = Identifier::fromString(vm, ident);
            return;
        }
    }
    frame.propertyName = Identifier::fromString(vm, jsonCache.makeIdentifier(vm, key));
}

template<typename CharType, JSONParseSinkMode sinkMode>
JSArray* JSONParseState<CharType, sinkMode>::materializeArray(unsigned stackBase)
{
    auto scope = DECLARE_THROW_SCOPE(vm);

    RELEASE_ASSERT(stackBase < elementStack.size());
    unsigned length = elementStack.size() - stackBase;
    std::span<const JSValue> values = elementStack.span().subspan(stackBase);

    // putDirectIndex would have discovered this while growing the butterfly one element at a time.
    IndexingType indexingType = ArrayWithInt32;
    for (JSValue value : values) {
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
        Structure* structure = globalObject->arrayStructureForIndexingTypeDuringAllocation(indexingType);
        if (JSArray* array = JSArray::tryCreateUninitializedRestricted(initializationScope, structure, length)) [[likely]] {
            // The structure can have a different shape than requested, for example when double arrays are disabled.
            IndexingType shape = array->indexingType() & IndexingShapeMask;
            WTF_ALLOW_UNSAFE_BUFFER_USAGE_BEGIN
            if (shape == DoubleShape) {
                // JSON has no NaN, so every element can be stored as a double.
                double* data = array->butterfly()->contiguousDouble().data();
                for (unsigned i = 0; i < length; ++i)
                    data[i] = values[i].asNumber();
            } else if (shape == Int32Shape || shape == ContiguousShape) {
                ContiguousJSValues data = array->butterfly()->contiguous();
                for (unsigned i = 0; i < length; ++i)
                    data.at(array, i).setWithoutWriteBarrier(values[i]);
                if (shape == ContiguousShape)
                    vm.writeBarrier(array);
            } else {
                for (unsigned i = 0; i < length; ++i)
                    array->initializeIndex(initializationScope, i, values[i]);
            }
            WTF_ALLOW_UNSAFE_BUFFER_USAGE_END
            return array;
        }
    }

    // Lengths beyond what a contiguous vector can hold, and allocation failures, grow an empty array
    // instead so that they report out of memory rather than crashing.
    JSArray* array = constructEmptyArray(globalObject, nullptr);
    RETURN_IF_EXCEPTION(scope, nullptr);
    for (unsigned i = 0; i < length; ++i) {
        array->putDirectIndex(globalObject, i, values[i]);
        RETURN_IF_EXCEPTION(scope, nullptr);
    }
    return array;
}

} // namespace

// The sink's member functions are always inlined, but not declared inline, so the explicit instantiations below emit
// the symbols the Swift calls.
template<typename CharType, JSONParseSinkMode sinkMode>
ALWAYS_INLINE_LAMBDA bool JSONParseSink<CharType, sinkMode>::beginArray(size_t start)
{
    auto& state = static_cast<JSONParseState<CharType, sinkMode>&>(*this);
    if (!state.iterative())
        return state.beginContainer({ .kind = FrameKind::Array, .elementStackBase = static_cast<unsigned>(state.elementStack.size()) }, start);
    auto scope = DECLARE_THROW_SCOPE(state.vm);
    JSArray* array = constructEmptyArray(state.globalObject, nullptr);
    RETURN_IF_EXCEPTION(scope, false);
    return state.beginContainer({ .kind = FrameKind::Array, .container = array }, start);
}

template<typename CharType, JSONParseSinkMode sinkMode>
ALWAYS_INLINE_LAMBDA bool JSONParseSink<CharType, sinkMode>::endArray(size_t end)
{
    auto& state = static_cast<JSONParseState<CharType, sinkMode>&>(*this);
    RELEASE_ASSERT(state.top.kind == FrameKind::Array);
    if (state.iterative())
        return state.endContainer(state.top.container, end);
    auto scope = DECLARE_THROW_SCOPE(state.vm);
    unsigned stackBase = state.top.elementStackBase;
    JSArray* array = state.elementStack.size() == stackBase ? constructEmptyArray(state.globalObject, nullptr) : state.materializeArray(stackBase);
    state.elementStack.shrink(stackBase);
    RETURN_IF_EXCEPTION(scope, false);
    return state.endContainer(array, end);
}

template<typename CharType, JSONParseSinkMode sinkMode>
ALWAYS_INLINE_LAMBDA bool JSONParseSink<CharType, sinkMode>::beginObject(size_t start)
{
    auto& state = static_cast<JSONParseState<CharType, sinkMode>&>(*this);
    JSObject* object = constructEmptyObject(state.globalObject);
    Structure* structure = object->structure();
    uint8_t structureNameIndex = state.mode() == StrictJSON ? static_cast<uint8_t>(JSONCache::nameIndex(StructureID::encode(structure))) : 0;
    return state.beginContainer({ .kind = FrameKind::Object, .container = object, .structure = structure, .structureNameIndex = structureNameIndex }, start);
}

template<typename CharType, JSONParseSinkMode sinkMode>
ALWAYS_INLINE_LAMBDA bool JSONParseSink<CharType, sinkMode>::endObject(size_t end)
{
    auto& state = static_cast<JSONParseState<CharType, sinkMode>&>(*this);
    RELEASE_ASSERT(state.top.kind == FrameKind::Object);
    return state.endContainer(state.top.container, end);
}

template<typename CharType, JSONParseSinkMode sinkMode>
void JSONParseSink<CharType, sinkMode>::beginCacheScope()
{
    auto& state = static_cast<JSONParseState<CharType, sinkMode>&>(*this);
    RELEASE_ASSERT(!state.parsingScope);
    state.parsingScope.emplace(state.jsonCache);
}

template<typename CharType, JSONParseSinkMode sinkMode>
ALWAYS_INLINE_LAMBDA void JSONParseSink<CharType, sinkMode>::key(std::span<const CharType> characters NOESCAPE, size_t charactersToEnd)
{
    static_cast<JSONParseState<CharType, sinkMode>&>(*this).resolveKey(characters, charactersToEnd);
}

template<typename CharType, JSONParseSinkMode sinkMode>
ALWAYS_INLINE_LAMBDA void JSONParseSink<CharType, sinkMode>::decodedKey(JSONParseInput8 characters8 NOESCAPE, JSONParseInput16 characters16 NOESCAPE)
{
    auto& state = static_cast<JSONParseState<CharType, sinkMode>&>(*this);
    characters16.empty() ? state.resolveKey(characters8, 0) : state.resolveKey(characters16, 0);
}

// The key and the colon after it at remaining, when JSONCache predicts them for the innermost object's Structure,
// which then becomes the pending property: their length, or 0.
template<typename CharType, JSONParseSinkMode sinkMode>
ALWAYS_INLINE_LAMBDA size_t JSONParseSink<CharType, sinkMode>::consumeCachedKey(std::span<const CharType> remaining NOESCAPE)
{
    auto& state = static_cast<JSONParseState<CharType, sinkMode>&>(*this);
    auto& frame = state.top;
    RELEASE_ASSERT(frame.kind == FrameKind::Object && state.mode() == StrictJSON && !state.iterative());
    Structure* structure = frame.structure;
    auto* entry = state.jsonCache.findName(StructureID::encode(structure), frame.structureNameIndex, remaining);
    if (!entry)
        return 0;
    frame.originalStructure = structure;
    frame.structureNameIndex = static_cast<uint8_t>(entry->toNameIndex);
    frame.propertyStructure = entry->to.unvalidatedGet();
    frame.propertyOffset = entry->offset;
    return entry->textLength;
}

template<typename CharType, JSONParseSinkMode sinkMode>
void JSONParseSink<CharType, sinkMode>::setValueRange(size_t start, size_t end)
{
    auto& state = static_cast<JSONParseState<CharType, sinkMode>&>(*this);
    RELEASE_ASSERT(start <= end && end <= state.input.size());
    state.valueRange = { static_cast<unsigned>(start), static_cast<unsigned>(end) };
}

template<typename CharType, JSONParseSinkMode sinkMode>
ALWAYS_INLINE_LAMBDA bool JSONParseSink<CharType, sinkMode>::stringValue(size_t start, size_t length, bool cache)
{
    auto& state = static_cast<JSONParseState<CharType, sinkMode>&>(*this);
    RELEASE_ASSERT(start <= state.input.size() && length <= state.input.size() - start);
    JSString* string = state.jsonCache.makeJSString(state.vm, state.input.subspan(start, length));
    if (cache) {
        // The source text from the opening quote to the closing one is exactly what a later match compares against.
        RELEASE_ASSERT(state.is8Bit && state.mode() == StrictJSON && start && length < state.input.size() - start);
        if constexpr (std::is_same_v<CharType, Latin1Character>)
            state.jsonCache.addString(state.input.subspan(start - 1), length + 2, string);
    }
    return state.leafValue(string);
}

template<typename CharType, JSONParseSinkMode sinkMode>
ALWAYS_INLINE_LAMBDA bool JSONParseSink<CharType, sinkMode>::decodedStringValue(JSONParseInput8 characters8 NOESCAPE, JSONParseInput16 characters16 NOESCAPE)
{
    auto& state = static_cast<JSONParseState<CharType, sinkMode>&>(*this);
    return state.leafValue(characters16.empty() ? state.jsonCache.makeJSString(state.vm, characters8) : state.jsonCache.makeJSString(state.vm, characters16));
}

template<typename CharType, JSONParseSinkMode sinkMode>
ALWAYS_INLINE_LAMBDA bool JSONParseSink<CharType, sinkMode>::cachedStringValue(std::span<const CharType> remaining NOESCAPE, size_t& length)
{
    auto& state = static_cast<JSONParseState<CharType, sinkMode>&>(*this);
    RELEASE_ASSERT(state.is8Bit && state.mode() == StrictJSON);
    if constexpr (std::is_same_v<CharType, Latin1Character>) {
        if (auto* entry = state.jsonCache.findString(remaining)) {
            length = entry->textLength;
            return state.leafValue(entry->string);
        }
    }
    return true;
}

template<typename CharType, JSONParseSinkMode sinkMode>
ALWAYS_INLINE_LAMBDA bool JSONParseSink<CharType, sinkMode>::int32Value(int32_t value)
{
    return static_cast<JSONParseState<CharType, sinkMode>&>(*this).leafValue(jsNumber(value));
}

template<typename CharType, JSONParseSinkMode sinkMode>
ALWAYS_INLINE_LAMBDA bool JSONParseSink<CharType, sinkMode>::numberValue(double value)
{
    return static_cast<JSONParseState<CharType, sinkMode>&>(*this).leafValue(jsNumber(value));
}

template<typename CharType, JSONParseSinkMode sinkMode>
ALWAYS_INLINE_LAMBDA bool JSONParseSink<CharType, sinkMode>::literalValue(JSONParseLiteral literal)
{
    return static_cast<JSONParseState<CharType, sinkMode>&>(*this).leafValue(literal == JSONParseLiteral::Null ? jsNull() : jsBoolean(literal == JSONParseLiteral::True));
}

template<typename CharType, JSONParseSinkMode sinkMode>
ALWAYS_INLINE_LAMBDA double JSONParseSink<CharType, sinkMode>::parseNumber(std::span<const CharType> remaining NOESCAPE, size_t& length)
{
    auto result = WTF::parseJSONDouble(remaining, length);
    if (!result)
        length = 0;
    return result.value_or(0);
}

template<typename CharType, JSONParseSinkMode sinkMode>
void JSONParseSink<CharType, sinkMode>::fail(JSONParseFailure failure)
{
    static_cast<JSONParseState<CharType, sinkMode>&>(*this).failure = failure;
}

static_assert(JSONPPathEntryTypeDeclareVar == 0 && JSONPPathEntryTypeDot == 1 && JSONPPathEntryTypeLookup == 2 && JSONPPathEntryTypeCall == 3);

template<typename CharType, JSONParseSinkMode sinkMode>
bool JSONParseSink<CharType, sinkMode>::appendJSONPPathEntry(uint8_t type, size_t start, size_t length, int32_t index)
{
    auto& state = static_cast<JSONParseState<CharType, sinkMode>&>(*this);
    RELEASE_ASSERT(state.jsonpResults && type <= JSONPPathEntryTypeCall && index >= 0 && start <= state.input.size() && length <= state.input.size() - start);
    if (type == JSONPPathEntryTypeCall) {
        state.jsonpPath.last().m_type = JSONPPathEntryTypeCall;
        state.jsonpEntry = state.jsonpPath.last();
        return true;
    }
    // A statement's path starts empty: endJSONPValue() moves the last one into its JSONPData.
    if (state.jsonpPath.isEmpty())
        state.jsonpEntry = { };
    state.jsonpEntry.m_type = static_cast<JSONPPathEntryType>(type);
    if (type == JSONPPathEntryTypeLookup)
        state.jsonpEntry.m_pathIndex = index;
    else
        state.jsonpEntry.m_pathEntryName = Identifier::fromString(state.vm, state.input.subspan(start, length));
    state.jsonpPath.append(state.jsonpEntry);
    return !isLexerKeyword(state.jsonpEntry.m_pathEntryName);
}

template<typename CharType, JSONParseSinkMode sinkMode>
void JSONParseSink<CharType, sinkMode>::beginJSONPValue()
{
    auto& state = static_cast<JSONParseState<CharType, sinkMode>&>(*this);
    RELEASE_ASSERT(state.jsonpResults);
    state.jsonpResults->append(JSONPData());
    state.result = { };
}

template<typename CharType, JSONParseSinkMode sinkMode>
void JSONParseSink<CharType, sinkMode>::endJSONPValue()
{
    auto& state = static_cast<JSONParseState<CharType, sinkMode>&>(*this);
    RELEASE_ASSERT(state.jsonpResults && !state.jsonpResults->isEmpty() && state.result);
    state.jsonpResults->last().m_value.set(state.vm, state.result);
    state.jsonpResults->last().m_path.swap(state.jsonpPath);
}

// The parser's frames leave copies of the values they made in stack slots that a later call may reserve without
// writing, where the conservative scan would keep the previous result alive. Clear the stack they used.
template<size_t size>
NEVER_INLINE static void clearParserStack()
{
    std::array<uintptr_t, size / sizeof(uintptr_t)> stack { };
    asm volatile("" : : "r"(stack.data()) : "memory");
}

template<JSONParseSinkMode sinkMode, typename CharType>
NEVER_INLINE static JSValue parseWithSink(JSGlobalObject* globalObject, CodeBlock* nullOrCodeBlock, std::span<const CharType> characters, ParserMode mode, JSONParseEntry entry, bool iterative, String& errorMessage, JSONParseFailure& failure, JSONRanges* ranges, Vector<JSONPData>* jsonpResults, bool needsFullSourceInfo)
{
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    JSONParseState<CharType, sinkMode> state(globalObject, nullOrCodeBlock, mode, iterative, characters, ranges, jsonpResults);
    bool succeeded;
    if constexpr (sinkMode == JSONParseSinkMode::Strict && std::is_same_v<CharType, Latin1Character>)
        succeeded = JavaScriptCore::jsonParseStrict8(characters, static_cast<uint8_t>(entry), state);
    else if constexpr (sinkMode == JSONParseSinkMode::Strict)
        succeeded = JavaScriptCore::jsonParseStrict16(characters, static_cast<uint8_t>(entry), state);
    else if constexpr (sinkMode == JSONParseSinkMode::Sloppy && std::is_same_v<CharType, Latin1Character>)
        succeeded = JavaScriptCore::jsonParseSloppy8(characters, state);
    else if constexpr (sinkMode == JSONParseSinkMode::Sloppy)
        succeeded = JavaScriptCore::jsonParseSloppy16(characters, state);
    else if constexpr (std::is_same_v<CharType, Latin1Character>)
        succeeded = JavaScriptCore::jsonParse8(characters, static_cast<uint8_t>(entry), iterative, !!ranges, needsFullSourceInfo, state);
    else
        succeeded = JavaScriptCore::jsonParse16(characters, static_cast<uint8_t>(entry), iterative, !!ranges, needsFullSourceInfo, state);
    clearParserStack<1024>();
    if (succeeded) {
        RELEASE_ASSERT(!scope.exception());
        RELEASE_ASSERT(state.top.kind == FrameKind::None && !state.savedFrameCount && state.frames.isEmpty() && state.rangesStack.isEmpty() && state.elementStack.isEmpty());
        RELEASE_ASSERT(state.result);
        RELEASE_ASSERT(entry != JSONParseEntry::PrimitiveValue || state.result.isPrimitive());
        RELEASE_ASSERT(entry != JSONParseEntry::Program || !jsonpResults->isEmpty());
        return state.result;
    }
    errorMessage = state.errorMessage;
    failure = state.failure;
    return { };
}

template<typename CharType, JSONReviverMode reviverMode>
JSValue LiteralParser<CharType, reviverMode>::parse(JSONParseEntry entry, JSONRanges* ranges, Vector<JSONPData>* jsonpResults, bool needsFullSourceInfo)
{
    // A reviver and a program parse iteratively, and so do JSON.parse and eval when the recursive parse is turned off.
    bool iterative = reviverMode == JSONReviverMode::Enabled || entry == JSONParseEntry::Program || (entry != JSONParseEntry::PrimitiveValue && !Options::useRecursiveJSONParse());
    // JSON.parse and eval parse with a sink for their one mode.
    if (!iterative && m_mode == StrictJSON && (entry == JSONParseEntry::Value || entry == JSONParseEntry::PrimitiveValue))
        return parseWithSink<JSONParseSinkMode::Strict>(m_globalObject, m_nullOrCodeBlock, m_characters, m_mode, entry, iterative, m_errorMessage, m_failure, ranges, jsonpResults, needsFullSourceInfo);
    if (!iterative && m_mode == SloppyJSON && entry == JSONParseEntry::Eval)
        return parseWithSink<JSONParseSinkMode::Sloppy>(m_globalObject, m_nullOrCodeBlock, m_characters, m_mode, entry, iterative, m_errorMessage, m_failure, ranges, jsonpResults, needsFullSourceInfo);
    // A reviver or a program runs over the stack the dead state used, where a stale copy of a cell pointer would be
    // found by the conservative scan and keep the previous result alive. Clear it too.
    JSValue result = parseWithSink<JSONParseSinkMode::Any>(m_globalObject, m_nullOrCodeBlock, m_characters, m_mode, entry, iterative, m_errorMessage, m_failure, ranges, jsonpResults, needsFullSourceInfo);
    clearParserStack<sizeof(JSONParseState<CharType, JSONParseSinkMode::Any>) + 1024>();
    return result;
}

bool JSONParseErrorMessage::append(JSONParseInput8 characters8 NOESCAPE, JSONParseInput16 characters16 NOESCAPE)
{
    auto& builder = static_cast<JSONParseErrorMessageBuilder&>(*this).builder;
    builder.append(characters8);
    builder.append(characters16);
    return !builder.hasOverflowed();
}

void JSONParseErrorMessage::clear()
{
    static_cast<JSONParseErrorMessageBuilder&>(*this).builder.clear();
}

// The message is made from the characters only when it is asked for: every caller asks while the parser, and the
// characters its caller keeps alive for it, are unchanged.
template<typename CharType, JSONReviverMode reviverMode>
String LiteralParser<CharType, reviverMode>::getErrorMessage() const
{
    if (!m_errorMessage.isEmpty())
        return makeString("JSON Parse error: "_s, m_errorMessage);
    JSONParseErrorMessageBuilder message;
    if constexpr (std::is_same_v<CharType, Latin1Character>)
        JavaScriptCore::jsonParseErrorMessage8(m_characters, m_failure, message);
    else
        JavaScriptCore::jsonParseErrorMessage16(m_characters, m_failure, message);
    return message.builder.toString();
}

template class LiteralParser<Latin1Character, JSONReviverMode::Enabled>;
template class LiteralParser<char16_t, JSONReviverMode::Enabled>;
template class LiteralParser<Latin1Character, JSONReviverMode::Disabled>;
template class LiteralParser<char16_t, JSONReviverMode::Disabled>;

template class JSONParseSink<Latin1Character, JSONParseSinkMode::Strict>;
template class JSONParseSink<char16_t, JSONParseSinkMode::Strict>;
template class JSONParseSink<Latin1Character, JSONParseSinkMode::Sloppy>;
template class JSONParseSink<char16_t, JSONParseSinkMode::Sloppy>;
template class JSONParseSink<Latin1Character, JSONParseSinkMode::Any>;
template class JSONParseSink<char16_t, JSONParseSinkMode::Any>;

// Swift moves a noncopyable C++ type that is trivially destructible by copying its bytes, without the move constructor.
static_assert(!std::is_trivially_destructible_v<JSONParseSink8> && !std::is_trivially_destructible_v<JSONParseSink16> && !std::is_trivially_destructible_v<JSONParseErrorMessage>);

} // namespace JSC

#endif // USE_SWIFT_JSON_PARSER
