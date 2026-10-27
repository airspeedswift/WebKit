import JavaScriptCore
import CJSCKeepAlive

// The SafeJSC model: a JS value is a ~Escapable JSRef, rooted by the library
// frame its closure runs under. The API shape came from porting a large existing
// ObjC-API JavaScriptCore client onto it:
//
// - A closure only where a JS value has to reach user code. Leaves (strings,
//   numbers, bools, nested decodables) are read and written as Swift values,
//   inside the library's frame: `o.string("id")`, `o.set("ok", true)`.
// - Values the VM itself roots are plain getters with a borrow dependence on
//   the VM: `vm.global`. That dependence is honest because the VM's context
//   retain IS the root (JSGlobalContextRetain = gcProtect(globalObject)).
// - One-op paths and calls: `o.property("services", name) { }`,
//   `handler.invoke("handle", request) { result in }`, `result.then { } _: { }`.
// - Roots belong to the VM (RootTable), not to the context: a JSRooted no
//   longer retains the context, so host state holding roots cannot keep a
//   dropped VM alive.

// MARK: - The one primitive

@inlinable @inline(always)
func withStackRoot<R: ~Copyable, E: Error>(
    _ raw: JSValueRef, in ctx: JSContextRef, _ body: (JSRef) throws(E) -> R
) throws(E) -> R {
    defer { unsafe keepAlive(raw) }
    return try body(unsafe JSRef(raw, ctx))
}

@inlinable @inline(always)
func keepAlive(_ raw: JSValueRef) {
    unsafe jsc_keep_alive(UnsafeRawPointer(raw))
}

// MARK: - Scope: what a conversion needs to make values

/// The context a value is being made in. ~Escapable: valid only inside the
/// closure or callback that handed it out. `JSConvertible` conformances get one.
@safe public struct JSScope: ~Escapable {
    @usableFromInline let ctx: JSContextRef
    @unsafe @_lifetime(immortal) @usableFromInline
    init(_ ctx: JSContextRef) { unsafe self.ctx = ctx }

    /// A new empty object / array, rooted by the access: `let o = args.scope.newObject`.
    @available(*, noasync)
    public var newObject: JSObject {
        @_lifetime(copy self) yielding borrow {
            var lock = unsafe jsc_scope_lock(ctx)
            defer { unsafe jsc_scope_unlock(&lock) }
            let raw = unsafe JSObjectMake(ctx, nil, nil)!
            yield unsafe JSObject(unchecked: JSRef(raw, ctx))
            unsafe keepAlive(raw)
        }
    }
    @available(*, noasync)
    public var newArray: JSArray {
        @_lifetime(copy self) yielding borrow {
            var lock = unsafe jsc_scope_lock(ctx)
            defer { unsafe jsc_scope_unlock(&lock) }
            let raw = unsafe JSObjectMakeArray(ctx, 0, nil, nil)!
            yield unsafe JSArray(unchecked: JSRef(raw, ctx))
            unsafe keepAlive(raw)
        }
    }
    /// A Swift value converted to JS, rooted by the call's frame.
    @available(*, noasync) @_lifetime(copy self) @yield_once
    public func make(_ value: some JSConvertible) throws yields (JSRef) -> () {
        var lock = unsafe jsc_scope_lock(ctx)
        defer { unsafe jsc_scope_unlock(&lock) }
        let raw = try unsafe value.withJSValue(in: self) { unsafe $0.raw }
        yield unsafe JSRef(raw, ctx)
        unsafe keepAlive(raw)
    }

    // Closure forms, for the library's own conformances.
    @usableFromInline
    func makeObject<R: ~Copyable>(_ body: (JSRef) throws -> R) rethrows -> R {
        try unsafe withStackRoot(JSObjectMake(ctx, nil, nil)!, in: ctx, body)
    }

    @usableFromInline
    func makeArray<R: ~Copyable>(_ body: (JSRef) throws -> R) rethrows -> R {
        try unsafe withStackRoot(JSObjectMakeArray(ctx, 0, nil, nil)!, in: ctx, body)
    }



    /// The global object. The context roots it, so this needs no closure.
    public var global: JSObject {
        @_lifetime(copy self) get { unsafe JSObject(unchecked: JSRef(JSContextGetGlobalObject(ctx)!, ctx)) }
    }
}

// MARK: - Errors

/// A JavaScript exception, copied out as a plain Swift value.
public struct JSError: Error, CustomStringConvertible, Sendable {
    public let message: String
    /// What the VM's `exceptionMapper` made of the exception, read while the exception
    /// value was still rooted (for example a client error type with line, stack and userInfo).
    public let underlying: (any Error & Sendable)?
    public init(message: String) { self.message = message; self.underlying = nil }
    public init(message: String, underlying: (any Error & Sendable)?) {
        self.message = message
        self.underlying = underlying
    }
    public var description: String { "JS exception: \(message)" }
}

@inlinable
func checked<T>(in ctx: JSContextRef, _ call: (UnsafeMutablePointer<JSValueRef?>) -> T) throws(JSError) -> T {
    var exception: JSValueRef? = nil
    let result = unsafe call(&exception)
    if let exception = unsafe exception {
        throw unsafe makeError(exception, in: ctx)
    }
    return result
}

/// A thrown exception as a JSError. The exception is rooted here (a local on this frame,
/// kept alive past the mapper) while the VM's mapper reads it.
@usableFromInline
func makeError(_ exception: JSValueRef, in ctx: JSContextRef) -> JSError {
    let message = unsafe jsString(of: exception, in: ctx)
    guard let mapper = unsafe rootTableIfRegistered(for: ctx)?.exceptionMapper else {
        return JSError(message: message)
    }
    let underlying = unsafe withStackRoot(exception, in: ctx) { mapper($0) }
    return JSError(message: message, underlying: underlying)
}

/// ToString of any value, as a Swift String.
@usableFromInline
func jsString(of raw: JSValueRef, in ctx: JSContextRef) -> String {
    guard let s = unsafe JSValueToStringCopy(ctx, raw, nil) else { return "<unprintable>" }
    defer { unsafe JSStringRelease(s) }
    return unsafe swiftString(s)
}

/// A value known to be a string, as a Swift String: with the internals backend, its characters
/// go to UTF-8 in one step (no OpaqueJSString); otherwise through ToString.
@usableFromInline
func stringOfStringValue(_ raw: JSValueRef, _ ctx: JSContextRef) -> String {
    if let internals = unsafe jsc_active() {
        let small: String? = unsafe withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 256) { buffer in
            let n = unsafe internals.pointee.stringUTF8(ctx, raw, UnsafeMutableRawPointer(buffer.baseAddress!).assumingMemoryBound(to: CChar.self), 256)
            return n < 0 ? nil : unsafe String(decoding: UnsafeBufferPointer(rebasing: buffer[..<n]), as: UTF8.self)
        }
        if let small { return small }
        let needed = unsafe -internals.pointee.stringUTF8(ctx, raw, UnsafeMutablePointer<CChar>(bitPattern: 1)!, 0)
        return unsafe String(unsafeUninitializedCapacity: needed) { buffer in
            unsafe internals.pointee.stringUTF8(ctx, raw, UnsafeMutableRawPointer(buffer.baseAddress!).assumingMemoryBound(to: CChar.self), needed)
        }
    }
    return unsafe jsString(of: raw, in: ctx)
}

/// A JSStringRef's characters as a Swift String, transcoded once: JSC writes UTF-8 straight into
/// a stack buffer, and String validates and copies it (or keeps it inline when it is small). No
/// CFString, no autoreleased bridge, no second transcoding pass.
///
/// JSStringGetUTF8CString stops at a lone surrogate on some JSC versions (macOS 27.5's does;
/// newer ones write U+FFFD). So the UTF-16 length of what it wrote is checked against the
/// string's: a short write is redone from the UTF-16 characters, which Swift repairs to U+FFFD
/// exactly as the CFString bridge did.
@usableFromInline
func swiftString(_ s: JSStringRef) -> String {
    let max = unsafe JSStringGetMaximumUTF8CStringSize(s)       // 3 * length + 1
    if max <= 1 { return "" }
    let length = unsafe JSStringGetLength(s)
    let fast: String? = unsafe withUnsafeTemporaryAllocation(of: UInt8.self, capacity: max) { buffer in
        let n = unsafe JSStringGetUTF8CString(s, UnsafeMutableRawPointer(buffer.baseAddress!).assumingMemoryBound(to: CChar.self), max) - 1
        let bytes = unsafe UnsafeBufferPointer(rebasing: buffer[..<n])
        // UTF-16 units written: one per non-continuation byte, two for a 4-byte sequence.
        var units = 0
        for unsafe b in unsafe bytes { units &+= (b & 0xC0 != 0x80 ? 1 : 0) &+ (b >= 0xF0 ? 1 : 0) }
        return units == length ? unsafe String(decoding: bytes, as: UTF8.self) : nil
    }
    if let fast { return fast }
    let characters = unsafe UnsafeBufferPointer(start: JSStringGetCharactersPtr(s), count: length)
    return unsafe String(decoding: characters, as: UTF16.self)
}

@inlinable
func withJSString<R, E: Error>(_ s: String, _ body: (JSStringRef) throws(E) -> R) throws(E) -> R {
    let js = unsafe JSStringCreateWithUTF8CString(s)!
    defer { unsafe JSStringRelease(js) }
    return try unsafe body(js)
}

// MARK: - Names

/// A property name made once. Sendable: a JSStringRef is an immutable,
/// thread-safe reference-counted string, not a GC object, so
/// `static let id = JSName("id")` is fine in Swift 6.
@safe public final class JSName: Sendable {
    @usableFromInline nonisolated(unsafe) let string: JSStringRef
    public init(_ name: String) { unsafe string = JSStringCreateWithUTF8CString(name)! }
    deinit { unsafe JSStringRelease(string) }
}

/// Names the library itself reads on every call that needs them.
@usableFromInline enum Names {
    @usableFromInline static let length = JSName("length")
    @usableFromInline static let then = JSName("then")
    @usableFromInline static let promise = JSName("Promise")
}

/// A property key: a String literal / value, or a premade JSName.
public protocol JSKey { func withJSString<R, E: Error>(_ body: (JSStringRef) throws(E) -> R) throws(E) -> R }
extension String: JSKey {
    @inlinable public func withJSString<R, E: Error>(_ body: (JSStringRef) throws(E) -> R) throws(E) -> R {
        try unsafe SafeJSC.withJSString(self, body)
    }
}
extension JSName: JSKey {
    @inlinable public func withJSString<R, E: Error>(_ body: (JSStringRef) throws(E) -> R) throws(E) -> R {
        try unsafe body(string)
    }
}

/// `a.length` of an object known to be an array.
@usableFromInline
func arrayLength(_ array: JSValueRef, _ ctx: JSContextRef) -> Int {
    guard let n = unsafe JSObjectGetProperty(ctx, array, Names.length.string, nil) else { return 0 }
    return Int(unsafe JSValueToNumber(ctx, n, nil))
}

// MARK: - Backend switch (benchmarks)

/// Whether SafeJSC accesses hold JSC's API lock for their extent (the default) or leave every
/// C call to take it (the public-C-API-only backend). For A/B measurement; set it only while no
/// access is active.
@_spi(Benchmark) public var scopeLockEnabled: Bool {
    get { jsc_scope_lock_get_enabled() }
    set { jsc_scope_lock_set_enabled(newValue) }
}

/// Whether the JSC-internals backend (Internals/, route A) is loaded for the running
/// JavaScriptCore, and whether SafeJSC uses it. For A/B measurement.
@_spi(Benchmark) public var internalsLoaded: Bool { jsc_internals_resolve(); return jsc_internals_loaded() }
@_spi(Benchmark) public var internalsEnabled: Bool {
    get { jsc_internals_get_enabled() }
    set { jsc_internals_set_enabled(newValue) }
}

/// The lock state an internals call sees, for the check that crosses an ObjC/C callback inside
/// an access: what SafeJSC's record says, what JSC says, and whether the last internals call on
/// this thread took the lock itself. nil fields: no internals backend loaded.
@_spi(Benchmark) public func lockState(_ v: JSRef) -> (recordSaysHeld: Bool, jscHeld: Bool?, lastInternalsCallLocked: Bool?) {
    let internals = unsafe jsc_active()
    return (unsafe jsc_scope_record_says_held(v.ctx),
            unsafe internals.map { unsafe $0.pointee.holdsLock(v.ctx) },
            unsafe internals.map { unsafe $0.pointee.lastCallLocked() })
}
