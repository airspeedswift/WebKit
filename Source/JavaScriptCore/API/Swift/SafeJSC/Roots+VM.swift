import JavaScriptCore
import CJSCKeepAlive
import Synchronization

// MARK: - Roots owned by the VM, which avoids a teardown leak
//
// An earlier design had the root type retain the global context. A root held in state that a host
// function's closure captures then formed a cycle: the context could not die
// while the root existed, and the root was released only by the host object's
// finalizer, which needs the context to die. Here a root does NOT retain the
// context. It points at its VM's RootTable; JSVM.deinit marks the table dead
// before releasing the context, and a root whose table is dead does nothing
// on deinit (the heap it pointed into is being, or has been, torn down).

@usableFromInline
@safe final class RootTable: @unchecked Sendable {   // touched only on the VM's thread; registry lookup is locked
    @usableFromInline let ctx: JSGlobalContextRef
    @usableFromInline var alive = true
    /// Set by `JSVM.exceptionMapper`; read on the VM's thread when an exception is caught.
    var exceptionMapper: ((JSRef) -> any Error & Sendable)?
    init(_ ctx: JSGlobalContextRef) { unsafe self.ctx = ctx }
}

let rootTables = Mutex<[UInt: RootTable]>([:])

func rootTable(for ctx: JSContextRef) -> RootTable {
    let global = unsafe JSContextGetGlobalContext(ctx)!
    let key = UInt(bitPattern: unsafe UnsafeRawPointer(global))
    return rootTables.withLock { $0[key]! }
}

func rootTableIfRegistered(for ctx: JSContextRef) -> RootTable? {
    guard let global = unsafe JSContextGetGlobalContext(ctx) else { return nil }
    let key = UInt(bitPattern: unsafe UnsafeRawPointer(global))
    return rootTables.withLock { $0[key] }
}

/// A precisely rooted JS value: Escapable, ~Copyable (one protect count).
@safe public struct JSRooted: ~Copyable {
    @usableFromInline let raw: JSValueRef
    @usableFromInline let table: RootTable

    @unsafe
    init(protecting raw: JSValueRef, in ctx: JSContextRef) {
        let table = unsafe rootTable(for: ctx)
        unsafe JSValueProtect(table.ctx, raw)
        unsafe self.raw = raw
        self.table = table
    }

    deinit {
        if table.alive { unsafe JSValueUnprotect(table.ctx, raw) }
    }

    /// Re-enters a stack-rooted scope (library-internal: clients use `.value`).
    @usableFromInline
    func with<R: ~Copyable, E: Error>(_ body: (JSRef) throws(E) -> R) throws(E) -> R {
        precondition(table.alive, "JSRooted used after its JSVM was deinitialized")
        return try unsafe withStackRoot(raw, in: table.ctx, body)
    }

    /// The value, closure-free: this root owns it, so a borrow of the root is
    /// its real lifetime (no stack frame needed).
    public var value: JSRef {
        @_lifetime(borrow self) get {
            precondition(table.alive, "JSRooted used after its JSVM was deinitialized")
            return unsafe JSRef(raw, table.ctx)
        }
    }

    public func clone() -> JSRooted { unsafe JSRooted(protecting: raw, in: table.ctx) }
}

/// A stored JS value: a precise, VM-owned root that keeps its kind
/// (`JSHandle<JSCallable>`), so it is not re-checked on use. Make one with
/// `value.handle()`. A JSConvertible, so a kept value can be passed anywhere a
/// Swift value can.
public final class JSHandle<T: JSTyped & ~Escapable>: JSConvertible {
    let rooted: JSRooted
    init(rooting rooted: consuming JSRooted) { self.rooted = rooted }
    /// A borrow of the handle, which owns the root.
    public var value: T { @_lifetime(borrow self) get { T(rooted.value)! } }
    public func withJSValue<R: ~Copyable>(in scope: JSScope, _ body: (JSRef) throws -> R) throws -> R { try rooted.with(body) }
}

// MARK: - VM

/// Owns one global context. Not Sendable: use it from one thread (for example a
/// dedicated worker thread), or make it an actor's state.
@safe public final class JSVM {
    @usableFromInline let ctx: JSGlobalContextRef
    let table: RootTable
    private let syncGC: (@convention(c) (JSContextRef?) -> Void)?

    public convenience init() {
        let ctx = unsafe JSGlobalContextCreate(nil)!
        unsafe self.init(adopting: ctx)
    }

    /// Takes over one retain of `ctx`.
    @unsafe init(adopting ctx: JSGlobalContextRef) {
        unsafe self.ctx = ctx
        jsc_internals_resolve()
        let t = unsafe RootTable(ctx)
        table = t
        rootTables.withLock { $0[UInt(bitPattern: unsafe UnsafeRawPointer(ctx))] = t }
        if let sym = unsafe dlsym(UnsafeMutableRawPointer(bitPattern: -2), "JSSynchronousGarbageCollectForDebugging") {
            unsafe syncGC = unsafeBitCast(sym, to: (@convention(c) (JSContextRef?) -> Void).self)
        } else {
            unsafe syncGC = nil
        }
    }

    /// Turns a caught JS exception into the Swift error carried as `JSError.underlying`.
    /// Called on the VM's thread with the exception rooted. A client can map it to its own
    /// error type (line, column, stack, userInfo) and report it to its exception observers.
    public var exceptionMapper: ((JSRef) -> any Error & Sendable)? {
        get { table.exceptionMapper }
        set { table.exceptionMapper = newValue }
    }

    deinit {
        table.alive = false
        rootTables.withLock { _ = $0.removeValue(forKey: UInt(bitPattern: unsafe UnsafeRawPointer(ctx))) }
        unsafe JSGlobalContextRelease(ctx)
    }

    /// The global object, closure-free: the VM's context retain is its root,
    /// so the borrow dependence on the VM is the real lifetime.
    public var global: JSObject {
        @_lifetime(borrow self) get { unsafe JSObject(unchecked: JSRef(JSContextGetGlobalObject(ctx)!, ctx)) }
    }

    /// `globalThis.a` / `globalThis.a.b...` as one access: `let s = try vm["services", name]`.
    @available(*, noasync)
    public subscript(_ key: String) -> JSRef {
        @_lifetime(borrow self) yielding borrow throws { yield try global[key] }
    }
    @available(*, noasync)
    public subscript(_ first: String, _ second: String, _ rest: String...) -> JSRef {
        @_lifetime(borrow self) yielding borrow throws {
            var lock = unsafe jsc_scope_lock(ctx)
            defer { unsafe jsc_scope_unlock(&lock) }
            var raw = try unsafe global.getRaw(first)
            unsafe raw = try JSRef(raw, ctx).getRaw(second)
            for key in rest { unsafe raw = try JSRef(raw, ctx).getRaw(key) }
            yield unsafe JSRef(raw, ctx)
            unsafe keepAlive(raw)
        }
    }

    /// A new empty object / array, rooted by the access: `let o = vm.newObject`.
    @available(*, noasync)
    public var newObject: JSObject {
        @_lifetime(borrow self) yielding borrow {
            var lock = unsafe jsc_scope_lock(ctx)
            defer { unsafe jsc_scope_unlock(&lock) }
            let raw = unsafe JSObjectMake(ctx, nil, nil)!
            yield unsafe JSObject(unchecked: JSRef(raw, ctx))
            unsafe keepAlive(raw)
        }
    }
    @available(*, noasync)
    public var newArray: JSArray {
        @_lifetime(borrow self) yielding borrow {
            var lock = unsafe jsc_scope_lock(ctx)
            defer { unsafe jsc_scope_unlock(&lock) }
            let raw = unsafe JSObjectMakeArray(ctx, 0, nil, nil)!
            yield unsafe JSArray(unchecked: JSRef(raw, ctx))
            unsafe keepAlive(raw)
        }
    }
    /// A Swift value converted to JS, rooted by the call's frame: `let v = try vm.make(request)`.
    @available(*, noasync) @_lifetime(borrow self) @yield_once
    public func make(_ value: some JSConvertible) throws yields (JSRef) -> () {
        var lock = unsafe jsc_scope_lock(ctx)
        defer { unsafe jsc_scope_unlock(&lock) }
        let raw = try unsafe value.withJSValue(in: scope) { unsafe $0.raw }
        yield unsafe JSRef(raw, ctx)
        unsafe keepAlive(raw)
    }

    /// For making values: `vm.scope.makeObject { }`.
    public var scope: JSScope { @_lifetime(borrow self) get { unsafe JSScope(ctx) } }

    /// Evaluates `source`; the result is rooted by the call's frame: `let page = try vm.evaluate("benchPage")`.
    @available(*, noasync) @_lifetime(borrow self) @yield_once
    public func evaluate(_ source: String, sourceURL: String? = nil) throws yields (JSRef) -> () {
        var lock = unsafe jsc_scope_lock(ctx)
        defer { unsafe jsc_scope_unlock(&lock) }
        let raw = try unsafe evaluateRaw(source, sourceURL: sourceURL)
        yield unsafe JSRef(raw, ctx)
        unsafe keepAlive(raw)
    }

    func evaluateRaw(_ source: String, sourceURL: String?) throws(JSError) -> JSValueRef {
        try unsafe withJSString(source) { script throws(JSError) in
            if let sourceURL {
                return try unsafe withJSString(sourceURL) { url throws(JSError) in
                    try unsafe checked(in: ctx) { unsafe JSEvaluateScript(ctx, script, nil, url, 1, $0) }
                }
            }
            return try unsafe checked(in: ctx) { unsafe JSEvaluateScript(ctx, script, nil, nil, 1, $0) }
        }!
    }

    /// Evaluates `source` for its effects.
    public func run(_ source: String, sourceURL: String? = nil) throws {
        _ = try unsafe evaluateRaw(source, sourceURL: sourceURL)
    }

    /// A full synchronous collection (debug entry point if exported, else a request).
    public func collectGarbage() {
        withUnsafeTemporaryAllocation(byteCount: 64 * 1024, alignment: 16) { buffer in
            _ = unsafe memset_s(buffer.baseAddress, buffer.count, 0, buffer.count)
        }
        if let syncGC = unsafe syncGC { unsafe syncGC(ctx) } else { unsafe JSGarbageCollect(ctx) }
    }
}
