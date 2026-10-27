// SafeJSC's JSC-internals backend (route A of REPORT-perf.md): the C API's hot entry points,
// re-implemented on JSC's own C++ API, without the per-call API lock when the caller's SafeJSC
// scope already holds it, and without the OpaqueJSString round trip for string values.
//
// Each function is the body of its C API namesake (wk-pristine Source/JavaScriptCore/API,
// JSObjectRef.cpp / JSValueRef.cpp, 77b6dc251967) with `JSLockHolder locker(vm)` made
// conditional on JSC's OWN answer to "does this thread hold the API lock"
// (JSLock::currentThreadIsHoldingLock), never on SafeJSC's bookkeeping: that record goes stale
// whenever JSC drops all locks to call out (every C-API callback, JSClass getter, setter and
// finalizer-adjacent callout does, APICallbackFunction.h / JSCallbackObjectFunctions.h; ObjC
// blocks and JSExport methods re-take the lock, ObjCCallbackFunction.mm), and an internal call
// made then without the lock races the collector. PerfBench check section 8 exercises both. The only calls that take no
// lock are reads the public C API also makes unlocked on 64-bit (JSValueGetType, IsObject:
// value bits and the cell's type) or of data that never changes for a live cell (a structure's
// ClassInfo).
// Differences, on purpose: an exception caught here is not reported to the Web Inspector
// (handleExceptionIfNeeded's reportAPIException: JSGlobalObjectInspectorController is not a
// private header).
//
// It must be compiled against the PrivateHeaders of the JavaScriptCore it runs with: the
// layouts it inlines (JSObject, JSString, Structure) are not ABI. build-internals.sh builds it
// against one WebKit build and bakes that build's path in; safejsc_internals_v1() returns NULL
// when a different JavaScriptCore is loaded, and SafeJSC then stays on the public C API.
#include <wtf/Platform.h>
#include <wtf/ExportMacros.h>
#include <JavaScriptCore/JSExportMacros.h>
#include <JavaScriptCore/APICast.h>
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/OpaqueJSString.h>
#include <JavaScriptCore/TopExceptionScope.h>
#include <JavaScriptCore/ObjectConstructor.h>
#include <JavaScriptCore/JSArray.h>
#include <wtf/text/StringCommon.h>
#include <wtf/unicode/UTF8Conversion.h>
#include <dlfcn.h>
#include <optional>
#include <string.h>

#include "SafeJSCInternals.h"

using namespace JSC;

namespace {

/// Whether the last internals call on this thread took the lock itself (for SafeJSC's check).
thread_local bool lastCallTookLock = false;

struct Locker {
    std::optional<JSLockHolder> holder;
    explicit Locker(VM& vm)
    {
        lastCallTookLock = !vm.apiLock().currentThreadIsHoldingLock();
        if (lastCallTookLock)
            holder.emplace(vm);
    }
};

inline bool caught(TopExceptionScope& scope, JSGlobalObject* globalObject, JSValueRef* exception)
{
    if (scope.exception()) [[unlikely]] {
        if (exception)
            *exception = toRef(globalObject, scope.exception()->value());
        scope.clearException();
        return true;
    }
    return false;
}

/// OpaqueJSString::identifier (not exported), from the inline accessors.
inline Identifier identifierOf(VM& vm, JSStringRef name)
{
    if (!name->length())
        return Identifier(Identifier::EmptyIdentifierFlag::EmptyIdentifier);
    if (name->is8Bit())
        return Identifier::fromString(vm, name->span8());
    return Identifier::fromString(vm, name->span16());
}

JSValueRef get(JSContextRef ctx, JSObjectRef object, JSStringRef name, JSValueRef* exception)
{
    JSGlobalObject* globalObject = toJS(ctx);
    VM& vm = globalObject->vm();
    Locker locker(vm);
    auto scope = DECLARE_TOP_EXCEPTION_SCOPE(vm);
    JSValue v = toJS(object)->get(globalObject, identifierOf(vm, name));
    if (caught(scope, globalObject, exception))
        return nullptr;
    return toRef(globalObject, v);
}

JSValueRef getIndex(JSContextRef ctx, JSObjectRef object, unsigned index, JSValueRef* exception)
{
    JSGlobalObject* globalObject = toJS(ctx);
    VM& vm = globalObject->vm();
    Locker locker(vm);
    auto scope = DECLARE_TOP_EXCEPTION_SCOPE(vm);
    JSValue v = toJS(object)->get(globalObject, index);
    if (caught(scope, globalObject, exception))
        return nullptr;
    return toRef(globalObject, v);
}

void set(JSContextRef ctx, JSObjectRef object, JSStringRef name, JSValueRef value, JSValueRef* exception)
{
    JSGlobalObject* globalObject = toJS(ctx);
    VM& vm = globalObject->vm();
    Locker locker(vm);
    auto scope = DECLARE_TOP_EXCEPTION_SCOPE(vm);
    JSObject* jsObject = toJS(object);
    Identifier identifier = identifierOf(vm, name);
    JSValue jsValue = toJS(globalObject, value);
    // JSObjectSetProperty with attributes 0: a plain [[Set]] (not strict).
    PutPropertySlot slot(jsObject);
    jsObject->methodTable()->put(jsObject, globalObject, identifier, jsValue, slot);
    caught(scope, globalObject, exception);
}

void setIndex(JSContextRef ctx, JSObjectRef object, unsigned index, JSValueRef value, JSValueRef* exception)
{
    JSGlobalObject* globalObject = toJS(ctx);
    VM& vm = globalObject->vm();
    Locker locker(vm);
    auto scope = DECLARE_TOP_EXCEPTION_SCOPE(vm);
    JSObject* jsObject = toJS(object);
    jsObject->methodTable()->putByIndex(jsObject, globalObject, index, toJS(globalObject, value), false);
    caught(scope, globalObject, exception);
}

double toNumber(JSContextRef ctx, JSValueRef value, JSValueRef* exception)
{
    JSValue v = toJS(value);
    if (v.isNumber())
        return v.asNumber();             // no user code, no allocation: no lock needed
    // Anything else may run user code (valueOf) or be a BigInt: the C API's own path.
    return JSValueToNumber(ctx, value, exception);
}

bool toBoolean(JSContextRef ctx, JSValueRef value)
{
    JSValue v = toJS(value);
    if (v.isBoolean())
        return v.isTrue();
    JSGlobalObject* globalObject = toJS(ctx);
    Locker locker(globalObject->vm());
    return toJS(globalObject, value).toBoolean(globalObject);
}

bool isArray(JSContextRef ctx, JSValueRef value)
{
    return toJS(value).inherits<JSArray>();      // a type check: no lock needed
}

bool isFunction(JSContextRef ctx, JSObjectRef object)
{
    // isCallable can consult a proxy's target or a class's callbacks: locked, as the C API does.
    Locker locker(toJS(ctx)->vm());
    return toJS(object)->isCallable();
}

bool holdsLock(JSContextRef ctx)
{
    return toJS(ctx)->vm().apiLock().currentThreadIsHoldingLock();
}

bool lastCallLocked()
{
    return lastCallTookLock;
}

JSObjectRef toObject(JSContextRef ctx, JSValueRef value, JSValueRef* exception)
{
    JSValue v = toJS(value);
    if (v.isObject())
        return toRef(asObject(v));               // the common case: already an object
    JSGlobalObject* globalObject = toJS(ctx);
    VM& vm = globalObject->vm();
    Locker locker(vm);
    auto scope = DECLARE_TOP_EXCEPTION_SCOPE(vm);
    JSObject* object = toJS(globalObject, value).toObject(globalObject);
    if (caught(scope, globalObject, exception))
        return nullptr;
    return toRef(object);
}

/// A string value's characters as UTF-8 into buffer (no OpaqueJSString, no isolatedCopy).
/// Returns the byte count; if capacity is too small, returns -(bytes needed). Lone surrogates
/// become U+FFFD. Not a string: 0.
long stringUTF8(JSContextRef ctx, JSValueRef value, char* buffer, size_t capacity)
{
    JSValue v = toJS(value);
    if (!v.isString())
        return 0;
    JSGlobalObject* globalObject = toJS(ctx);
    VM& vm = globalObject->vm();
    Locker locker(vm);                     // resolving a rope allocates
    auto scope = DECLARE_TOP_EXCEPTION_SCOPE(vm);
    const String& s = asString(v)->value(globalObject);
    if (scope.exception()) [[unlikely]] {
        scope.clearException();
        return 0;
    }
    size_t worst = s.is8Bit() ? s.length() * 2 : s.length() * 3;
    if (worst > capacity)
        return -static_cast<long>(worst);
    std::span<char8_t> target { reinterpret_cast<char8_t*>(buffer), capacity };
    if (s.is8Bit()) {
        auto span = s.span8();
        if (charactersAreAllASCII(span)) {
            memcpy(buffer, span.data(), span.size());
            return static_cast<long>(span.size());
        }
        return static_cast<long>(WTF::Unicode::convert(span, target).buffer.size());
    }
    return static_cast<long>(WTF::Unicode::convertReplacingInvalidSequences(s.span16(), target).buffer.size());
}

JSObjectRef makeObject(JSContextRef ctx)
{
    JSGlobalObject* globalObject = toJS(ctx);
    Locker locker(globalObject->vm());
    return toRef(constructEmptyObject(globalObject));
}

JSValueRef makeStringUTF8(JSContextRef ctx, const char* bytes, size_t count)
{
    JSGlobalObject* globalObject = toJS(ctx);
    VM& vm = globalObject->vm();
    Locker locker(vm);
    return toRef(globalObject, jsString(vm, String::fromUTF8ReplacingInvalidSequences(std::span { reinterpret_cast<const char8_t*>(bytes), count })));
}

const SafeJSCInternals table = {
    SAFEJSC_INTERNALS_VERSION,
    get, getIndex, set, setIndex, toNumber, toBoolean, isArray, isFunction, toObject, stringUTF8,
    makeObject, makeStringUTF8, holdsLock, lastCallLocked,
};

} // namespace

extern "C" __attribute__((visibility("default"))) const SafeJSCInternals* safejsc_internals_v1(void)
{
    // Only with the JavaScriptCore this was compiled against.
    Dl_info info;
    if (!dladdr(reinterpret_cast<const void*>(&JSObjectGetProperty), &info) || !info.dli_fname)
        return nullptr;
    if (strcmp(info.dli_fname, SAFEJSC_INTERNALS_JSC_IMAGE))
        return nullptr;
    return &table;
}
