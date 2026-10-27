import JavaScriptCore
import CJSCKeepAlive

// Raw C-API steps shared by JSRef and the typed references. Library-internal, @inlinable (and
// @usableFromInline), so a client's read or write compiles to the C calls themselves: no
// cross-module call, no closure context, no existential. Each takes the object as a
// JSObjectRef the caller has already established is an object (a JSObject, or ToObject's
// result), which is what lets a typed reference skip JSValueToObject.

@inlinable @inline(always)
func rawGet(_ ctx: JSContextRef, _ object: JSObjectRef, _ name: JSStringRef) throws(JSError) -> JSValueRef {
    var exception: JSValueRef? = nil
    let v = unsafe jsc_get(ctx, object, name, &exception)
    if let exception = unsafe exception { throw unsafe makeError(exception, in: ctx) }
    return unsafe v!
}

@inlinable @inline(always)
func rawGet(_ ctx: JSContextRef, _ object: JSObjectRef, _ key: some JSKey) throws(JSError) -> JSValueRef {
    try unsafe key.withJSString { name throws(JSError) in try unsafe rawGet(ctx, object, name) }
}

@inlinable @inline(always)
func rawGet(_ ctx: JSContextRef, _ object: JSObjectRef, _ index: Int) throws(JSError) -> JSValueRef {
    var exception: JSValueRef? = nil
    let v = unsafe jsc_get_index(ctx, object, UInt32(truncatingIfNeeded: index), &exception)
    if let exception = unsafe exception { throw unsafe makeError(exception, in: ctx) }
    return unsafe v!
}

@inlinable @inline(always)
func rawSet(_ ctx: JSContextRef, _ object: JSObjectRef, _ name: JSStringRef, _ value: JSValueRef) throws(JSError) {
    var exception: JSValueRef? = nil
    unsafe jsc_set(ctx, object, name, value, &exception)
    if let exception = unsafe exception { throw unsafe makeError(exception, in: ctx) }
}

@inlinable @inline(always)
func rawSet(_ ctx: JSContextRef, _ object: JSObjectRef, _ key: some JSKey, _ value: JSValueRef) throws(JSError) {
    try unsafe key.withJSString { name throws(JSError) in try unsafe rawSet(ctx, object, name, value) }
}

@inlinable @inline(always)
func rawSet(_ ctx: JSContextRef, _ object: JSObjectRef, _ index: Int, _ value: JSValueRef) throws(JSError) {
    var exception: JSValueRef? = nil
    unsafe jsc_set_index(ctx, object, UInt32(truncatingIfNeeded: index), value, &exception)
    if let exception = unsafe exception { throw unsafe makeError(exception, in: ctx) }
}

/// `object[key] = value` for any Swift value. The leaves (numbers, booleans, strings) are made
/// directly, without the conversion's closure; a string is a heap cell, kept alive here until
/// the set has stored it.
@inlinable @inline(always)
func rawSet<V: JSConvertible>(_ ctx: JSContextRef, _ object: JSObjectRef, _ key: some JSKey, convertible value: V) throws {
    if let leaf = unsafe rawLeaf(ctx, value) {     // one locked C call (making a leaf takes no lock)
        try unsafe rawSet(ctx, object, key, leaf)
        unsafe keepAlive(leaf)
        return
    }
    var lock = unsafe jsc_scope_lock(ctx)       // a conversion makes several C calls: take JSC's lock once
    defer { unsafe jsc_scope_unlock(&lock) }
    try value.withJSValue(in: unsafe JSScope(ctx)) { v in try unsafe rawSet(ctx, object, key, v.raw) }
}

@inlinable @inline(always)
func rawSet<V: JSConvertible>(_ ctx: JSContextRef, _ object: JSObjectRef, _ index: Int, convertible value: V) throws {
    if let leaf = unsafe rawLeaf(ctx, value) {     // one locked C call (making a leaf takes no lock)
        try unsafe rawSet(ctx, object, index, leaf)
        unsafe keepAlive(leaf)
        return
    }
    var lock = unsafe jsc_scope_lock(ctx)       // a conversion makes several C calls: take JSC's lock once
    defer { unsafe jsc_scope_unlock(&lock) }
    try value.withJSValue(in: unsafe JSScope(ctx)) { v in try unsafe rawSet(ctx, object, index, v.raw) }
}

/// A leaf Swift value as a JS value, made directly; nil for anything that needs its conversion.
/// After specialization the casts fold away: `rawLeaf(ctx, 1.0)` is `JSValueMakeNumber`.
/// The caller must keep a string's result alive (it is a cell) until it is stored.
@inlinable @inline(always)
func rawLeaf<V: JSConvertible>(_ ctx: JSContextRef, _ value: V) -> JSValueRef? {
    if V.self == Double.self { return unsafe JSValueMakeNumber(ctx, unsafeBitCast(value, to: Double.self)) }
    if V.self == Int.self { return unsafe JSValueMakeNumber(ctx, Double(unsafeBitCast(value, to: Int.self))) }
    if V.self == Bool.self { return unsafe JSValueMakeBoolean(ctx, unsafeBitCast(value, to: Bool.self)) }
    if V.self == String.self { return unsafe makeJSString(ctx, unsafeBitCast(value, to: String.self)) }
    return nil
}

@inlinable @inline(always)
func makeJSString(_ ctx: JSContextRef, _ s: String) -> JSValueRef {
    if let internals = unsafe jsc_active() {
        var s = s
        return unsafe s.withUTF8 { unsafe internals.pointee.makeStringUTF8(ctx, UnsafeRawPointer($0.baseAddress!).assumingMemoryBound(to: CChar.self), $0.count) }
    }
    return unsafe withJSString(s) { unsafe JSValueMakeString(ctx, $0) }!
}

/// `f.call(this, argv)`.
@inlinable @inline(always)
func rawCall(_ ctx: JSContextRef, _ f: JSObjectRef, this: JSObjectRef?, _ argc: Int, _ argv: UnsafePointer<JSValueRef?>?) throws(JSError) -> JSValueRef {
    var exception: JSValueRef? = nil
    let v = unsafe JSObjectCallAsFunction(ctx, f, this, argc, argv, &exception)
    if let exception = unsafe exception { throw unsafe makeError(exception, in: ctx) }
    return unsafe v!
}

/// Calls `f` with one Swift argument, converted (and rooted by its conversion's frame) for the call.
@inlinable @inline(always)
func rawCall<A: JSConvertible>(_ ctx: JSContextRef, _ f: JSObjectRef, this: JSObjectRef?, _ a: A) throws -> JSValueRef {
    if let leaf = unsafe rawLeaf(ctx, a) {
        var argv: JSValueRef? = unsafe leaf
        defer { unsafe keepAlive(leaf) }
        return try unsafe rawCall(ctx, f, this: this, 1, &argv)
    }
    return try unsafe a.withJSValue(in: unsafe JSScope(ctx)) { av in
        var argv: JSValueRef? = unsafe av.raw
        return try unsafe rawCall(ctx, f, this: this, 1, &argv)
    }
}

@inlinable @inline(always)
// The conversion closures are untyped `throws`: passing a `throws(JSError)` closure to an
// untyped-`throws` generic parameter here crashes the Swift compiler's IRGen.
func rawCall<A: JSConvertible, B: JSConvertible>(_ ctx: JSContextRef, _ f: JSObjectRef, this: JSObjectRef?, _ a: A, _ b: B) throws -> JSValueRef {
    try unsafe a.withJSValue(in: unsafe JSScope(ctx)) { av in
        let ar = unsafe av.raw     // rooted by a's conversion frame, which encloses the call
        return try unsafe b.withJSValue(in: unsafe JSScope(ctx)) { bv in
            var argv: (JSValueRef?, JSValueRef?) = unsafe (ar, bv.raw)
            return try unsafe withUnsafePointer(to: &argv) { p throws(JSError) in
                try unsafe p.withMemoryRebound(to: JSValueRef?.self, capacity: 2) { argv throws(JSError) in
                    try unsafe rawCall(ctx, f, this: this, 2, argv)
                }
            }
        }
    }
}

/// `object[method](a)`, the method checked to be a function.
@inlinable @inline(always)
func rawCall<A: JSConvertible>(_ ctx: JSContextRef, method: some JSKey, on object: JSObjectRef, _ a: A) throws -> JSValueRef {
    let f = try unsafe rawGet(ctx, object, method)
    guard unsafe JSValueIsObject(ctx, f) && jsc_is_function(ctx, f) else {
        throw JSError(message: "TypeError: \(unsafe jsString(of: f, in: ctx)) is not a function")
    }
    return try unsafe rawCall(ctx, f, this: object, a)
}

/// The elements of an array (`array` is one), each decoded as T.
@inlinable
func decodeArrayElements<T: JSDecodable>(_ array: JSObjectRef, _ ctx: JSContextRef, as: T.Type, dropFailures: Bool) throws -> [T] {
    var lock = unsafe jsc_scope_lock(ctx)       // two or more C calls: take JSC's lock once
    defer { unsafe jsc_scope_unlock(&lock) }
    let n = unsafe arrayLength(array, ctx)
    var out: [T] = []
    out.reserveCapacity(n)
    for i in 0..<n {
        let e = try unsafe rawGet(ctx, array, i)
        defer { unsafe keepAlive(e) }
        if dropFailures {
            if let t = try? T(js: unsafe JSRef(e, ctx)) { out.append(t) }
        } else {
            out.append(try T(js: unsafe JSRef(e, ctx)))
        }
    }
    return out
}
