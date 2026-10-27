import JavaScriptCore
import CJSCKeepAlive

// Typed references: a JSRef whose JS type has been checked once.
// The check is a failable projection (`guard let service = try vm["services", name].object`),
// and the type then carries it: an object's reads skip ToObject, only a function
// has `call`, only a promise has `then`/`settle`.
//
// Each wraps the same pointer under the same root as the JSRef it came from, so
// a projection's lifetime is a copy of its source's. No new JS value is made.

// MARK: - One protocol over the typed references

/// JSRef, JSObject, JSCallable, JSArray, JSPromise.
public protocol JSTyped: ~Escapable {
    /// The untyped value.
    var ref: JSRef { @_lifetime(copy self) get }
    /// The checked projection: nil unless `ref` is of this kind.
    @_lifetime(copy ref) init?(_ ref: JSRef)
}

extension JSRef: JSTyped {
    public var ref: JSRef { @_lifetime(copy self) get { self } }
    @_lifetime(copy ref) public init?(_ ref: JSRef) { self = ref }
}

extension JSRef {
    @inlinable public var object: JSObject? { @_lifetime(copy self) get { JSObject(self) } }
    @inlinable public var function: JSCallable? { @_lifetime(copy self) get { JSCallable(self) } }
    @inlinable public var array: JSArray? { @_lifetime(copy self) get { JSArray(self) } }
    public var promise: JSPromise? { @_lifetime(copy self) get { JSPromise(self) } }
    /// The generic form, for generic code: `v.as(JSCallable.self)`.
    @_lifetime(copy self) public func `as`<T: JSTyped & ~Escapable>(_: T.Type) -> T? { T(self) }
}

extension JSTyped where Self: ~Escapable {
    /// `===`, across kinds.
    public func isSame(as other: some JSTyped & ~Escapable) -> Bool { ref.isStrictlyEqual(to: other.ref) }
    /// A precise, VM-owned root that keeps the kind: `callback.handle()` is a JSHandle<JSCallable>.
    public func handle() -> JSHandle<Self> { JSHandle(rooting: ref.root()) }
}

// MARK: - Object

@safe public struct JSObject: JSTyped, ~Escapable {
    public let ref: JSRef
    @_lifetime(copy ref) @inlinable public init?(_ ref: JSRef) {
        guard ref.isObject else { return nil }
        self.ref = ref
    }
    @unsafe @_lifetime(copy ref) @usableFromInline init(unchecked ref: JSRef) { self.ref = ref }

    @inlinable var raw: JavaScriptCore.JSObjectRef { unsafe ref.raw }
    @inlinable var ctx: JSContextRef { unsafe ref.ctx }

    public var function: JSCallable? { @_lifetime(copy self) get { ref.function } }
    public var array: JSArray? { @_lifetime(copy self) get { ref.array } }

    /// `self[key]`: no ToObject check, this is an object.
    @available(*, noasync) @inlinable
    public subscript(_ key: some JSKey) -> JSRef {
        @_lifetime(borrow self) yielding borrow throws {
            var lock = unsafe jsc_scope_lock(ctx)
            defer { unsafe jsc_scope_unlock(&lock) }
            let raw = try unsafe rawGet(ctx, self.raw, key)
            yield unsafe JSRef(raw, ctx)
            unsafe keepAlive(raw)
        }
    }
    /// `self.a.b...` as one access.
    @available(*, noasync)
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

    @inlinable
    func getRaw(_ key: some JSKey) throws(JSError) -> JSValueRef {
        try unsafe rawGet(ctx, raw, key)
    }

    @inlinable public func set(_ key: some JSKey, _ value: some JSConvertible) throws {
        try unsafe rawSet(ctx, raw, key, convertible: value)
    }
    /// Any typed value: a JSRef, JSObject, JSCallable, ...
    @inlinable public func set(_ key: some JSKey, _ value: some JSTyped & ~Escapable) throws {
        try unsafe rawSet(ctx, raw, key, value.ref.raw)
    }
    public func delete(_ key: some JSKey) throws { try ref.delete(key) }

    // `self.method(...)`: Swift values, or values already in JS (Task F1 allows the overloads).
    @available(*, noasync) @discardableResult @_lifetime(borrow self) @yield_once
    public func invoke(_ method: some JSKey, _ args: any JSConvertible...) throws yields (JSRef) -> () {
        var lock = unsafe jsc_scope_lock(ctx)
        defer { unsafe jsc_scope_unlock(&lock) }
        let raw = try unsafe ref.invokeRaw(method, args[...])
        yield unsafe JSRef(raw, ctx)
        unsafe keepAlive(raw)
    }
    @available(*, noasync) @discardableResult @_lifetime(borrow self) @yield_once @inlinable
    public func invoke<A: JSConvertible>(_ method: some JSKey, _ a: A) throws yields (JSRef) -> () {
        var lock = unsafe jsc_scope_lock(ctx)
        defer { unsafe jsc_scope_unlock(&lock) }
        let raw = try unsafe rawCall(ctx, method: method, on: raw, a)
        yield unsafe JSRef(raw, ctx)
        unsafe keepAlive(raw)
    }
    @available(*, noasync) @discardableResult @_lifetime(borrow self) @yield_once
    public func invoke<A: JSTyped & ~Escapable>(_ method: some JSKey, _ a: A) throws yields (JSRef) -> () {
        var lock = unsafe jsc_scope_lock(ctx)
        defer { unsafe jsc_scope_unlock(&lock) }
        let raw = try unsafe ref.invokeRaw(method, [a.ref.raw])
        yield unsafe JSRef(raw, ctx)
        unsafe keepAlive(raw)
    }
    @available(*, noasync) @discardableResult @_lifetime(borrow self) @yield_once
    public func invoke<A: JSTyped & ~Escapable, B: JSTyped & ~Escapable>(_ method: some JSKey, _ a: A, _ b: B) throws yields (JSRef) -> () {
        var lock = unsafe jsc_scope_lock(ctx)
        defer { unsafe jsc_scope_unlock(&lock) }
        let raw = try unsafe ref.invokeRaw(method, [a.ref.raw, b.ref.raw])
        yield unsafe JSRef(raw, ctx)
        unsafe keepAlive(raw)
    }

    // Typed reads, so a nested model or an array is one expression.
    @inlinable public func decode<T: JSDecodable>(_ key: some JSKey, as: T.Type = T.self) throws -> T {
        let v = try self[key]
        return try T(js: v)
    }
    @inlinable public func decodeIfPresent<T: JSDecodable>(_ key: some JSKey, as: T.Type = T.self) throws -> T? {
        let v = try self[key]
        return v.isNullish ? nil : try T(js: v)
    }
}

// MARK: - Function

@safe public struct JSCallable: JSTyped, ~Escapable {
    public let ref: JSRef
    @inlinable var raw: JavaScriptCore.JSObjectRef { unsafe ref.raw }
    @_lifetime(copy ref) @inlinable public init?(_ ref: JSRef) {
        guard ref.isFunction else { return nil }
        self.ref = ref
    }

    public var object: JSObject { @_lifetime(copy self) get { unsafe JSObject(unchecked: ref) } }

    /// `f(args...)` or, with `this:`, `f.call(this, args...)`: a method value
    /// called on its object, looked up once. Already checked to be a function: no re-check.
    @available(*, noasync) @discardableResult @_lifetime(borrow self) @yield_once
    public func call(this: JSObject? = nil, _ args: any JSConvertible...) throws yields (JSRef) -> () {
        var lock = unsafe jsc_scope_lock(ref.ctx)
        defer { unsafe jsc_scope_unlock(&lock) }
        let raw = try unsafe ref.callRaw(this: this?.ref, args: args[...])
        yield unsafe JSRef(raw, ref.ctx)
        unsafe keepAlive(raw)
    }
    @available(*, noasync) @discardableResult @_lifetime(borrow self) @yield_once @inlinable
    public func call(this: JSObject? = nil) throws yields (JSRef) -> () {
        var lock = unsafe jsc_scope_lock(ref.ctx)
        defer { unsafe jsc_scope_unlock(&lock) }
        let raw = try unsafe rawCall(ref.ctx, ref.raw, this: this?.raw, 0, nil)
        yield unsafe JSRef(raw, ref.ctx)
        unsafe keepAlive(raw)
    }
    @available(*, noasync) @discardableResult @_lifetime(borrow self) @yield_once @inlinable
    public func call<A: JSConvertible>(this: JSObject? = nil, _ a: A) throws yields (JSRef) -> () {
        var lock = unsafe jsc_scope_lock(ref.ctx)
        defer { unsafe jsc_scope_unlock(&lock) }
        let raw = try unsafe rawCall(ref.ctx, ref.raw, this: this?.raw, a)
        yield unsafe JSRef(raw, ref.ctx)
        unsafe keepAlive(raw)
    }
    @available(*, noasync) @discardableResult @_lifetime(borrow self) @yield_once @inlinable
    public func call<A: JSConvertible, B: JSConvertible>(this: JSObject? = nil, _ a: A, _ b: B) throws yields (JSRef) -> () {
        var lock = unsafe jsc_scope_lock(ref.ctx)
        defer { unsafe jsc_scope_unlock(&lock) }
        let raw = try unsafe rawCall(ref.ctx, ref.raw, this: this?.raw, a, b)
        yield unsafe JSRef(raw, ref.ctx)
        unsafe keepAlive(raw)
    }
    /// Arguments already in JS, of any kind.
    @available(*, noasync) @discardableResult @_lifetime(borrow self) @yield_once @inlinable
    public func call<A: JSTyped & ~Escapable>(this: JSObject? = nil, _ a: A) throws yields (JSRef) -> () {
        var lock = unsafe jsc_scope_lock(ref.ctx)
        defer { unsafe jsc_scope_unlock(&lock) }
        var argv: JSValueRef? = unsafe a.ref.raw
        let raw = try unsafe rawCall(ref.ctx, ref.raw, this: this?.raw, 1, &argv)
        yield unsafe JSRef(raw, ref.ctx)
        unsafe keepAlive(raw)
    }
    @available(*, noasync) @discardableResult @_lifetime(borrow self) @yield_once
    public func call<A: JSTyped & ~Escapable, B: JSTyped & ~Escapable>(this: JSObject? = nil, _ a: A, _ b: B) throws yields (JSRef) -> () {
        var lock = unsafe jsc_scope_lock(ref.ctx)
        defer { unsafe jsc_scope_unlock(&lock) }
        let raw = try unsafe ref.uncheckedCallRaw(this: this?.ref.raw, [a.ref.raw, b.ref.raw])
        yield unsafe JSRef(raw, ref.ctx)
        unsafe keepAlive(raw)
    }
}

// MARK: - Array

@safe public struct JSArray: JSTyped, ~Escapable {
    public let ref: JSRef
    @_lifetime(copy ref) @inlinable public init?(_ ref: JSRef) {
        guard ref.isArray else { return nil }
        self.ref = ref
    }
    @unsafe @_lifetime(copy ref) @usableFromInline init(unchecked ref: JSRef) { self.ref = ref }

    public var object: JSObject { @_lifetime(copy self) get { unsafe JSObject(unchecked: ref) } }
    @inlinable public var count: Int { unsafe arrayLength(ref.raw, ref.ctx) }

    @available(*, noasync) @inlinable
    public subscript(_ index: Int) -> JSRef {
        @_lifetime(borrow self) yielding borrow throws {
            var lock = unsafe jsc_scope_lock(ref.ctx)
            defer { unsafe jsc_scope_unlock(&lock) }
            let raw = try unsafe rawGet(ref.ctx, ref.raw, index)
            yield unsafe JSRef(raw, ref.ctx)
            unsafe keepAlive(raw)
        }
    }

    @inlinable public func decode<T: JSDecodable>(as: T.Type = T.self, dropFailures: Bool = false) throws -> [T] {
        try unsafe decodeArrayElements(ref.raw, ref.ctx, as: T.self, dropFailures: dropFailures)
    }
}

// MARK: - Promise

@safe public struct JSPromise: JSTyped, ~Escapable {
    public let ref: JSRef
    @_lifetime(copy ref) public init?(_ ref: JSRef) {
        guard ref.isPromise else { return nil }
        self.ref = ref
    }

    /// `promise.then(onFulfilled, onRejected)` with Swift continuations, called
    /// later (when the microtask queue drains) with the settled value rooted by JSC's frame.
    public func then(_ onFulfilled: @escaping (JSRef) throws -> Void,
                     _ onRejected: @escaping (JSRef) throws -> Void) throws {
        try ref.then(onFulfilled, onRejected)
    }

    /// Settle into a Swift value: the fulfilled value is decoded as T inside
    /// JSC's callback frame; a rejection becomes JSError(message:).
    public func then<T: JSDecodable>(as: T.Type, _ completion: @escaping (Result<T, Error>) -> Void) throws {
        try ref.then({ settled in completion(Result { try T(js: settled) }) },
                     { completion(.failure(JSError(message: $0.description))) })
    }
}
