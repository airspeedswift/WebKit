// jsc_keep_alive and the scope lock are static inline in include/CJSCKeepAlive.h.
#include "CJSCKeepAlive.h"

_Bool jsc_scope_lock_enabled = 1;
_Thread_local const void *jsc_scope_lock_owner = 0;

#include <dispatch/dispatch.h>
#include <dlfcn.h>

const SafeJSCInternals *jsc_internals = 0;
_Bool jsc_internals_enabled = 1;

static void lookUp(void *unused) {
    const SafeJSCInternals *(*get)(void) = (const SafeJSCInternals *(*)(void))dlsym(RTLD_DEFAULT, "safejsc_internals_v1");
    const SafeJSCInternals *table = get ? get() : 0;
    jsc_internals = (table && table->version == SAFEJSC_INTERNALS_VERSION) ? table : 0;
}

void jsc_internals_resolve(void) {
    static dispatch_once_t once;
    dispatch_once_f(&once, 0, lookUp);
}
