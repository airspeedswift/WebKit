#pragma once

/// JSC's ensureStillAliveHere idiom, for Swift, which cannot write inline asm.
///
/// An empty asm statement that claims to read `p` in a register. The compiler
/// must therefore keep `p` live (in a register or stack slot, where the
/// conservative scan sees it) up to this point. It emits no instructions and
/// has no memory clobber, so it does not force any loads or stores.
static inline __attribute__((always_inline)) void jsc_keep_alive(const void *p) {
    __asm__ volatile("" : : "r"(p));
}

// MARK: - Scope lock (backend below the public C API)
//
// Every JavaScriptCore C API call takes the VM's API lock (a JSLockHolder) and releases it on
// return; outside JS (and inside a C callback, which drops all locks first) that is a full
// acquire and release each time: on this machine ~11 ns of a ~25-45 ns property read. A
// SafeJSC access (a yielding accessor or yield-once call) is a scope on the caller's stack, so
// it can take the lock once for its extent; the C calls inside it then take it recursively,
// which is a counter increment.
//
// There is no public C API for this (proposed: JSGlobalContextLock / JSGlobalContextUnlock,
// see REPORT-perf.md), so this calls JSC's own JSC::JSLockHolder(JSGlobalObject*) constructor
// and destructor, which JavaScriptCore exports for WebKit (and the SDK's .tbd lists). A
// JSLockHolder is one RefPtr<VM>; a JSContextRef is the JSGlobalObject* (APICast.h).
#include <JavaScriptCore/JavaScriptCore.h>
#include "SafeJSCInternals.h"

/// One JSC::JSLockHolder (a RefPtr<VM>), and the owner it replaced.
typedef struct { void *_Nullable holder; const void *_Nullable previous; } JSCScopeLock;

extern void jsc_JSLockHolder_init(void *_Nonnull self, const void *_Nonnull globalObject)
    __asm__("__ZN3JSC12JSLockHolderC1EPNS_14JSGlobalObjectE");
extern void jsc_JSLockHolder_destroy(void *_Nonnull self)
    __asm__("__ZN3JSC12JSLockHolderD1Ev");

/// Whether accesses take the scope lock (set once, before any access; the benchmark toggles it
/// between arms, never inside an access).
extern _Bool jsc_scope_lock_enabled;

/// The context whose lock this thread's outermost SafeJSC scope holds, if any. A nested scope
/// on the same context takes nothing: even JSC's recursive re-entry is two atomic RefPtr<VM>
/// operations and a call (perf-bench e: ~6 ns a pair). Scopes nest (coroutine frames are on the
/// stack), so each restores the owner it found. A native function's trampoline clears it for
/// its body, because JSC dropped all locks before calling it.
extern _Thread_local const void *_Nullable jsc_scope_lock_owner;

static inline __attribute__((always_inline)) JSCScopeLock jsc_scope_lock(JSContextRef _Nonnull ctx) {
    JSCScopeLock lock = { 0, 0 };
    if (jsc_scope_lock_enabled && jsc_scope_lock_owner != (const void *)ctx) {
        jsc_JSLockHolder_init(&lock.holder, ctx);
        lock.previous = jsc_scope_lock_owner;
        jsc_scope_lock_owner = ctx;
    }
    return lock;
}

static inline __attribute__((always_inline)) void jsc_scope_unlock(JSCScopeLock *_Nonnull lock) {
    if (lock->holder) {
        // Restore the owner first: releasing the outermost lock drains the microtask queue,
        // and the reactions it runs must take the lock for themselves.
        jsc_scope_lock_owner = lock->previous;
        jsc_JSLockHolder_destroy(&lock->holder);
        lock->holder = 0;
    }
}

/// For a native function's body: JSC has dropped every lock, so no enclosing scope holds one.
static inline __attribute__((always_inline)) const void *_Nullable jsc_scope_lock_enter_callback(void) {
    const void *saved = jsc_scope_lock_owner;
    jsc_scope_lock_owner = 0;
    return saved;
}
static inline __attribute__((always_inline)) void jsc_scope_lock_leave_callback(const void *_Nullable saved) {
    jsc_scope_lock_owner = saved;
}

static inline _Bool jsc_scope_lock_get_enabled(void) { return jsc_scope_lock_enabled; }
static inline void jsc_scope_lock_set_enabled(_Bool on) { jsc_scope_lock_enabled = on; }

// MARK: - JSC-internals backend (route A), when loaded
//
// The C calls SafeJSC makes go through these. With the internals table (a dylib built against
// the running JavaScriptCore's PrivateHeaders, Internals/), a call inside a scope that holds the
// lock takes no lock at all, type checks and number/boolean reads are inline JSValue decodes,
// and strings go to UTF-8 without an OpaqueJSString. Without it: the public C API.

extern const SafeJSCInternals *_Nullable jsc_internals;
extern _Bool jsc_internals_enabled;
/// Looks the table up once (dlsym "safejsc_internals_v1"); cheap to call again.
void jsc_internals_resolve(void);

static inline __attribute__((always_inline)) const SafeJSCInternals *_Nullable jsc_active(void) {
    return jsc_internals_enabled ? jsc_internals : 0;
}
/// Whether this thread's SafeJSC bookkeeping says an enclosing access holds ctx's lock. A hint
/// for skipping our own JSLockHolder only; it is stale inside any callback JSC makes with its
/// locks dropped, so nothing that needs the lock for safety may trust it (the internals check
/// JSC itself).
static inline __attribute__((always_inline)) _Bool jsc_scope_record_says_held(JSContextRef _Nonnull ctx) {
    return jsc_scope_lock_owner == (const void *)ctx;
}

static inline __attribute__((always_inline))
JSValueRef _Nullable jsc_get(JSContextRef _Nonnull ctx, JSObjectRef _Nonnull o, JSStringRef _Nonnull n, JSValueRef _Nullable *_Nullable exc) {
    const SafeJSCInternals *i = jsc_active();
    return i ? i->get(ctx, o, n, exc) : JSObjectGetProperty(ctx, o, n, exc);
}
static inline __attribute__((always_inline))
JSValueRef _Nullable jsc_get_index(JSContextRef _Nonnull ctx, JSObjectRef _Nonnull o, unsigned index, JSValueRef _Nullable *_Nullable exc) {
    const SafeJSCInternals *i = jsc_active();
    return i ? i->getIndex(ctx, o, index, exc) : JSObjectGetPropertyAtIndex(ctx, o, index, exc);
}
static inline __attribute__((always_inline))
void jsc_set(JSContextRef _Nonnull ctx, JSObjectRef _Nonnull o, JSStringRef _Nonnull n, JSValueRef _Nonnull v, JSValueRef _Nullable *_Nullable exc) {
    const SafeJSCInternals *i = jsc_active();
    if (i) i->set(ctx, o, n, v, exc); else JSObjectSetProperty(ctx, o, n, v, 0, exc);
}
static inline __attribute__((always_inline))
void jsc_set_index(JSContextRef _Nonnull ctx, JSObjectRef _Nonnull o, unsigned index, JSValueRef _Nonnull v, JSValueRef _Nullable *_Nullable exc) {
    const SafeJSCInternals *i = jsc_active();
    if (i) i->setIndex(ctx, o, index, v, exc); else JSObjectSetPropertyAtIndex(ctx, o, index, v, exc);
}
static inline __attribute__((always_inline))
double jsc_to_number(JSContextRef _Nonnull ctx, JSValueRef _Nonnull v) {
    const SafeJSCInternals *i = jsc_active();
    return i ? i->toNumber(ctx, v, 0) : JSValueToNumber(ctx, v, 0);
}
static inline __attribute__((always_inline))
_Bool jsc_to_boolean(JSContextRef _Nonnull ctx, JSValueRef _Nonnull v) {
    const SafeJSCInternals *i = jsc_active();
    return i ? i->toBoolean(ctx, v) : JSValueToBoolean(ctx, v);
}
static inline __attribute__((always_inline))
_Bool jsc_is_array(JSContextRef _Nonnull ctx, JSValueRef _Nonnull v) {
    const SafeJSCInternals *i = jsc_active();
    return i ? i->isArray(ctx, v) : JSValueIsArray(ctx, v);
}
static inline __attribute__((always_inline))
_Bool jsc_is_function(JSContextRef _Nonnull ctx, JSObjectRef _Nonnull o) {
    const SafeJSCInternals *i = jsc_active();
    return i ? i->isFunction(ctx, o) : JSObjectIsFunction(ctx, o);
}
static inline __attribute__((always_inline))
JSObjectRef _Nullable jsc_to_object(JSContextRef _Nonnull ctx, JSValueRef _Nonnull v, JSValueRef _Nullable *_Nullable exc) {
    const SafeJSCInternals *i = jsc_active();
    return i ? i->toObject(ctx, v, exc) : JSValueToObject(ctx, v, exc);
}
static inline __attribute__((always_inline))
JSObjectRef _Nonnull jsc_make_object(JSContextRef _Nonnull ctx) {
    const SafeJSCInternals *i = jsc_active();
    return i ? i->makeObject(ctx) : JSObjectMake(ctx, 0, 0);
}

static inline _Bool jsc_internals_get_enabled(void) { return jsc_internals_enabled; }
static inline void jsc_internals_set_enabled(_Bool on) { jsc_internals_enabled = on; }
static inline _Bool jsc_internals_loaded(void) { return jsc_internals != 0; }
