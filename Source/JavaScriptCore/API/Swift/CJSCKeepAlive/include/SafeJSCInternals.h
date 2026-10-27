#pragma once
// The JSC-internals backend's entry points (Internals/SafeJSCInternals.cpp). SafeJSC finds the
// table at run time (dlsym "safejsc_internals_v1"); without it, or with a JavaScriptCore other
// than the one it was built against, SafeJSC stays on the public C API.
#include <JavaScriptCore/JavaScriptCore.h>
#include <stdbool.h>

#define SAFEJSC_INTERNALS_VERSION 2

#ifdef __cplusplus
extern "C" {
#endif

/// Each takes JSC's API lock itself unless JSC says this thread already holds it.
typedef struct {
    unsigned version;
    JSValueRef _Nullable (*_Nonnull get)(JSContextRef _Nonnull, JSObjectRef _Nonnull, JSStringRef _Nonnull, JSValueRef _Nullable *_Nullable);
    JSValueRef _Nullable (*_Nonnull getIndex)(JSContextRef _Nonnull, JSObjectRef _Nonnull, unsigned, JSValueRef _Nullable *_Nullable);
    void (*_Nonnull set)(JSContextRef _Nonnull, JSObjectRef _Nonnull, JSStringRef _Nonnull, JSValueRef _Nonnull, JSValueRef _Nullable *_Nullable);
    void (*_Nonnull setIndex)(JSContextRef _Nonnull, JSObjectRef _Nonnull, unsigned, JSValueRef _Nonnull, JSValueRef _Nullable *_Nullable);
    double (*_Nonnull toNumber)(JSContextRef _Nonnull, JSValueRef _Nonnull, JSValueRef _Nullable *_Nullable);
    bool (*_Nonnull toBoolean)(JSContextRef _Nonnull, JSValueRef _Nonnull);
    bool (*_Nonnull isArray)(JSContextRef _Nonnull, JSValueRef _Nonnull);
    bool (*_Nonnull isFunction)(JSContextRef _Nonnull, JSObjectRef _Nonnull);
    JSObjectRef _Nullable (*_Nonnull toObject)(JSContextRef _Nonnull, JSValueRef _Nonnull, JSValueRef _Nullable *_Nullable);
    long (*_Nonnull stringUTF8)(JSContextRef _Nonnull, JSValueRef _Nonnull, char *_Nonnull, size_t);
    JSObjectRef _Nonnull (*_Nonnull makeObject)(JSContextRef _Nonnull);
    JSValueRef _Nonnull (*_Nonnull makeStringUTF8)(JSContextRef _Nonnull, const char *_Nonnull, size_t);
    /// JSC's own answer: does this thread hold the context's API lock?
    bool (*_Nonnull holdsLock)(JSContextRef _Nonnull);
    /// Whether this thread's last internals call had to take the lock itself.
    bool (*_Nonnull lastCallLocked)(void);
} SafeJSCInternals;

#ifdef __cplusplus
}
#endif
