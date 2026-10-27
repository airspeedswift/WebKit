import JavaScriptCore
import CJSCKeepAlive

/// A JS value rooted by a library frame for as long as Swift uses it.
/// Copyable and ~Escapable.
///
/// The frame is a coroutine's, not a closure's. A read or a call is a
/// `yielding borrow throws` accessor: the accessor holds the pointer in its
/// frame (on the caller's stack) across the yield and keeps it alive after,
/// so `let x = try o["k"]` is rooted until `x`'s last use, with no closure.
/// One `let` per access: `o["a"]["b"]` chains a temporary access and is
/// rejected; write `o["a", "b"]` (one access) or two lets.
@safe public struct JSRef: ~Escapable {
    @usableFromInline let raw: JSValueRef
    @usableFromInline let ctx: JSContextRef

    @unsafe @_lifetime(immortal) @usableFromInline
    init(_ raw: JSValueRef, _ ctx: JSContextRef) {
        unsafe self.raw = raw
        unsafe self.ctx = ctx
    }

    public var scope: JSScope { @_lifetime(copy self) get { unsafe JSScope(ctx) } }

    // MARK: Predicates and leaf values
    //
    // @inlinable: each is one or two C calls, which the client's loop should call directly.

    @inlinable public var isUndefined: Bool { unsafe JSValueIsUndefined(ctx, raw) }
    @inlinable public var isNull: Bool { unsafe JSValueIsNull(ctx, raw) }
    @inlinable public var isNullish: Bool { unsafe JSValueIsUndefined(ctx, raw) || JSValueIsNull(ctx, raw) }
    @inlinable public var isString: Bool { unsafe JSValueIsString(ctx, raw) }
    @inlinable public var isNumber: Bool { unsafe JSValueIsNumber(ctx, raw) }
    @inlinable public var isBool: Bool { unsafe JSValueIsBoolean(ctx, raw) }
    @inlinable public var isObject: Bool { unsafe JSValueIsObject(ctx, raw) }
    @inlinable public var isArray: Bool { unsafe jsc_is_array(ctx, raw) }
    @inlinable public var isFunction: Bool { isObject && (unsafe jsc_is_function(ctx, raw)) }
    public var isPromise: Bool {
        var lock = unsafe jsc_scope_lock(ctx)
        defer { unsafe jsc_scope_unlock(&lock) }
        guard isObject else { return false }
        let global = unsafe JSContextGetGlobalObject(ctx)!
        guard let promise = unsafe JSObjectGetProperty(ctx, global, Names.promise.string, nil) else { return false }
        return unsafe JSValueIsInstanceOfConstructor(ctx, raw, promise, nil)
    }
    public func isStrictlyEqual(to other: JSRef) -> Bool { unsafe JSValueIsStrictEqual(ctx, raw, other.raw) }

    @inlinable public var stringValue: String? { isString ? unsafe stringOfStringValue(raw, ctx) : nil }
    public var description: String { unsafe jsString(of: raw, in: ctx) }
    @inlinable public var numberValue: Double? { isNumber ? unsafe jsc_to_number(ctx, raw) : nil }
    @inlinable public var boolValue: Bool? { isBool ? unsafe jsc_to_boolean(ctx, raw) : nil }
    public var count: Int? {
        guard isArray else { return nil }
        return unsafe arrayLength(raw, ctx)
    }

    // MARK: Reads: throwing yielding accessors (no closures)

    /// `self[key]`.
    @available(*, noasync) @inlinable
    public subscript(_ key: some JSKey) -> JSRef {
        @_lifetime(borrow self) yielding borrow throws {
            var lock = unsafe jsc_scope_lock(ctx)
            defer { unsafe jsc_scope_unlock(&lock) }
            let raw = try unsafe rawGet(ctx, asObject(), key)
            yield unsafe JSRef(raw, ctx)
            unsafe keepAlive(raw)
        }
    }

    /// `self.a.b...` as ONE access: only the last value is held; the
    /// intermediates are dead once the next is read.
    @available(*, noasync) @inlinable
    public subscript(_ first: String, _ second: String, _ rest: String...) -> JSRef {
        @_lifetime(borrow self) yielding borrow throws {
            var lock = unsafe jsc_scope_lock(ctx)
            defer { unsafe jsc_scope_unlock(&lock) }
            var raw = try unsafe getRaw(first)
            unsafe raw = try JSRef(raw, ctx).getRaw(second)
            for key in rest { unsafe raw = try JSRef(raw, ctx).getRaw(key) }
            yield unsafe JSRef(raw, ctx)
            unsafe keepAlive(raw)
        }
    }

    /// `self[index]`.
    @available(*, noasync) @inlinable
    public subscript(_ index: Int) -> JSRef {
        @_lifetime(borrow self) yielding borrow throws {
            var lock = unsafe jsc_scope_lock(ctx)
            defer { unsafe jsc_scope_unlock(&lock) }
            let raw = try unsafe rawGet(ctx, asObject(), index)
            yield unsafe JSRef(raw, ctx)
            unsafe keepAlive(raw)
        }
    }

    @inlinable
    func getRaw(_ key: some JSKey) throws(JSError) -> JSValueRef {
        try unsafe rawGet(ctx, asObject(), key)
    }

    // MARK: Leaf reads of a property (Swift values), and decoding

    @inlinable public func string(_ key: some JSKey) throws -> String? { try self[key].stringValue }
    @inlinable public func number(_ key: some JSKey) throws -> Double? { try self[key].numberValue }
    @inlinable public func bool(_ key: some JSKey) throws -> Bool? { try self[key].boolValue }

    @inlinable public func decode<T: JSDecodable>(_ key: some JSKey, as: T.Type = T.self) throws -> T {
        let v = try self[key]
        return try T(js: v)
    }
    @inlinable public func decodeIfPresent<T: JSDecodable>(_ key: some JSKey, as: T.Type = T.self) throws -> T? {
        let v = try self[key]
        return v.isNullish ? nil : try T(js: v)
    }
    /// nil if the property is not an array; `dropFailures` skips elements that fail to decode.
    @inlinable public func decodeArray<T: JSDecodable>(_ key: some JSKey, as: T.Type = T.self, dropFailures: Bool = false) throws -> [T]? {
        let v = try self[key]
        return try v.decodeElements(as: T.self, dropFailures: dropFailures)
    }
    @inlinable public func decodeElements<T: JSDecodable>(as: T.Type = T.self, dropFailures: Bool = false) throws -> [T]? {
        guard isArray else { return nil }
        return try unsafe decodeArrayElements(raw, ctx, as: T.self, dropFailures: dropFailures)
    }

    // MARK: Writes

    @inlinable
    public func set(_ key: some JSKey, _ value: some JSConvertible) throws {
        try unsafe rawSet(ctx, asObject(), key, convertible: value)
    }
    /// `self[key] = value` for a value already in JS, of any kind.
    @inlinable
    public func set(_ key: some JSKey, _ value: some JSTyped & ~Escapable) throws {
        var lock = unsafe jsc_scope_lock(ctx)
        defer { unsafe jsc_scope_unlock(&lock) }
        try unsafe rawSet(ctx, asObject(), key, value.ref.raw)
    }
    @usableFromInline
    func setRaw(_ key: some JSKey, _ valueRaw: JSValueRef) throws {
        try unsafe rawSet(ctx, asObject(), key, valueRaw)
    }
    @inlinable
    public func set(_ index: Int, _ value: JSRef) throws {
        try unsafe rawSet(ctx, asObject(), index, value.raw)
    }
    @inlinable
    public func set(_ index: Int, _ value: some JSConvertible) throws {
        try unsafe rawSet(ctx, asObject(), index, convertible: value)
    }
    public func delete(_ key: some JSKey) throws {
        let object = try unsafe asObject()
        _ = try unsafe key.withJSString { name throws(JSError) in
            try unsafe checked(in: ctx) { unsafe JSObjectDeleteProperty(ctx, object, name, $0) }
        }
    }

    // MARK: Calls: yield-once functions
    //
    // A call evaluates to its result, which the function's frame (on the
    // caller's stack) roots until the caller's last use of it:
    //     let result = try handler.invoke("handle", options)
    // An unused result ends the call with the statement (@discardableResult).
    // Arguments: Swift values (variadic), or values already in JS of any kind
    // (generic overloads). All are noasync until the compiler keeps coroutine
    // frames of async functions on the thread stack.
    // One and two Swift arguments have their own overloads: no argument array, no
    // existential boxes, and leaves made directly.

    @available(*, noasync) @discardableResult @_lifetime(borrow self) @yield_once
    public func invoke(_ method: some JSKey, _ args: any JSConvertible...) throws yields (JSRef) -> () {
        var lock = unsafe jsc_scope_lock(ctx)
        defer { unsafe jsc_scope_unlock(&lock) }
        let raw = try unsafe invokeRaw(method, args[...])
        yield unsafe JSRef(raw, ctx)
        unsafe keepAlive(raw)
    }
    @available(*, noasync) @discardableResult @_lifetime(borrow self) @yield_once @inlinable
    public func invoke<A: JSConvertible>(_ method: some JSKey, _ a: A) throws yields (JSRef) -> () {
        var lock = unsafe jsc_scope_lock(ctx)
        defer { unsafe jsc_scope_unlock(&lock) }
        let raw = try unsafe rawCall(ctx, method: method, on: asObject(), a)
        yield unsafe JSRef(raw, ctx)
        unsafe keepAlive(raw)
    }
    @available(*, noasync) @discardableResult @_lifetime(borrow self) @yield_once
    public func invoke<A: JSTyped & ~Escapable>(_ method: some JSKey, _ a: A) throws yields (JSRef) -> () {
        var lock = unsafe jsc_scope_lock(ctx)
        defer { unsafe jsc_scope_unlock(&lock) }
        let raw = try unsafe invokeRaw(method, [a.ref.raw])
        yield unsafe JSRef(raw, ctx)
        unsafe keepAlive(raw)
    }
    @available(*, noasync) @discardableResult @_lifetime(borrow self) @yield_once
    public func invoke<A: JSTyped & ~Escapable, B: JSTyped & ~Escapable>(_ method: some JSKey, _ a: A, _ b: B) throws yields (JSRef) -> () {
        var lock = unsafe jsc_scope_lock(ctx)
        defer { unsafe jsc_scope_unlock(&lock) }
        let raw = try unsafe invokeRaw(method, [a.ref.raw, b.ref.raw])
        yield unsafe JSRef(raw, ctx)
        unsafe keepAlive(raw)
    }

    /// Calls this value as a function (`this:` optional). Prefer `.function` and JSCallable.call.
    @available(*, noasync) @discardableResult @_lifetime(borrow self) @yield_once
    public func call(this: JSObject? = nil, _ args: any JSConvertible...) throws yields (JSRef) -> () {
        var lock = unsafe jsc_scope_lock(ctx)
        defer { unsafe jsc_scope_unlock(&lock) }
        let raw = try unsafe callRaw(this: this?.ref, args: args[...])
        yield unsafe JSRef(raw, ctx)
        unsafe keepAlive(raw)
    }

    @usableFromInline
    func invokeRaw(_ method: some JSKey, _ raws: [JSValueRef?]) throws -> JSValueRef {
        let f = try unsafe JSRef(getRaw(method), ctx)
        return try unsafe f.callRaw(this: self.raw, raws)
    }

    @usableFromInline
    func invokeRaw(_ method: some JSKey, _ args: ArraySlice<any JSConvertible>) throws -> JSValueRef {
        let f = try unsafe JSRef(getRaw(method), ctx)
        return try unsafe f.callRaw(this: self, args: args)
    }

    /// Converts each Swift argument in its own library scope, nesting so all are
    /// rooted when the call happens. The result leaves as a raw pointer and is
    /// rooted again by the caller's frame before any further JSC call.
    @usableFromInline
    func callRaw(this: JSRef?, args: ArraySlice<any JSConvertible>) throws -> JSValueRef {
        var raws: [JSValueRef?] = unsafe []
        unsafe raws.reserveCapacity(args.count)
        return try unsafe withConverted(args, into: &raws) { raws in try unsafe callRaw(this: this?.raw, raws) }
    }

    func withConverted<R>(_ args: ArraySlice<any JSConvertible>, into raws: inout [JSValueRef?],
                          _ body: ([JSValueRef?]) throws -> R) throws -> R {
        guard let first = args.first else { return try unsafe body(raws) }
        return try first.withJSValue(in: scope) { v in
            unsafe raws.append(v.raw)
            return try unsafe withConverted(args.dropFirst(), into: &raws, body)
        }
    }

    @usableFromInline
    func callRaw(this: JSValueRef?, _ raws: [JSValueRef?]) throws -> JSValueRef {
        guard isFunction else { throw JSError(message: "TypeError: \(description) is not a function") }
        return try unsafe uncheckedCallRaw(this: this, raws)
    }

    /// `callRaw` for a value already known to be a function (a JSCallable).
    @usableFromInline
    func uncheckedCallRaw(this: JSValueRef?, _ raws: [JSValueRef?]) throws(JSError) -> JSValueRef {
        try raws.withUnsafeBufferPointer { buffer throws(JSError) in
            try unsafe rawCall(ctx, raw, this: this, buffer.count, buffer.baseAddress)
        }
    }

    // MARK: Promises

    /// `self.then(onFulfilled, onRejected)`: Swift continuations, called later
    /// with the settled value rooted by JSC's frame. (Events, not scopes: these
    /// stay closures.)
    func then(_ onFulfilled: @escaping (JSRef) throws -> Void,
                     _ onRejected: @escaping (JSRef) throws -> Void) throws {
        var lock = unsafe jsc_scope_lock(ctx)
        defer { unsafe jsc_scope_unlock(&lock) }
        let accept = JSFunction { args in try onFulfilled(args[0]); return .undefined }
        let reject = JSFunction { args in try onRejected(args[0]); return .undefined }
        let object = try unsafe asObject()
        let then = try unsafe rawGet(ctx, object, Names.then.string)
        guard unsafe JSValueIsObject(ctx, then) && jsc_is_function(ctx, then) else {
            throw JSError(message: "TypeError: then is not a function")
        }
        _ = try unsafe rawCall(ctx, then, this: object, accept, reject)
    }

    // MARK: Keeping

    public func root() -> JSRooted { unsafe JSRooted(protecting: raw, in: ctx) }
    public var unsafeRaw: JSValueRef { unsafe raw }

    /// ToObject: the value itself for an object (one C call), a wrapper for a primitive,
    /// a TypeError for null and undefined.
    @inlinable @inline(always)
    func asObject() throws(JSError) -> JSObjectRef {
        var exception: JSValueRef? = nil
        let object = unsafe jsc_to_object(ctx, raw, &exception)
        if let exception = unsafe exception { throw unsafe makeError(exception, in: ctx) }
        return unsafe object!
    }
}
