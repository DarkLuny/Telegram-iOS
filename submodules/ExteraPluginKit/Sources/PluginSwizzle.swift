import Foundation
import ObjectiveC.runtime
import JavaScriptCore

/// An Objective-C swizzling surface for plugins, the iOS shape of exteraGram's
/// Xposed hooks.
///
/// On Android a plugin hooks a Java method by class name and signature and gets
/// `beforeHookedMethod`/`afterHookedMethod` callbacks with a `MethodHookParam`
/// that can read and replace the arguments and the result. Xposed rewrites the
/// method body inside ART's runtime; if the hook does not call `setResult`, the
/// original method still runs and its value is what the caller gets.
///
/// There is no ART here, and a plugin cannot be handed the Objective-C runtime
/// directly — one `class_getInstanceMethod` on the wrong class and the app is
/// undefined behaviour. So the surface is narrower but real: a plugin names a
/// class, a selector and whether it wants the *instance* or *class* method, and
/// the host installs a block that re-enters the plugin with the receiver and the
/// arguments, calls the original implementation when the plugin did not replace
/// the result, and passes that result to `afterHookedMethod`. The plugin never
/// touches the runtime itself.
///
/// What this can hook: an Objective-C method that already exists on a class the
/// app has loaded, taking zero, one or two object arguments, with an object or
/// void return. What it cannot: Swift methods not exposed to Objective-C (no
/// `@objc`), C functions, methods taking structs or primitives, and anything
/// that would need the method to exist before this runs. A signature outside
/// that set is reported as an error rather than installed with a block whose ABI
/// does not match — a mismatched block does not crash immediately, it corrupts
/// the return value of every call, which is far harder to find later.
///
/// The plugin callbacks are held in the JavaScript side's token map, and the
/// block only ever calls one stable entry point on the plugin's own
/// `JSContext`. A `JSValue` is not retained across the bridge: the context is
/// re-entered on the script queue with a token, which is the only thread-safe
/// way to run plugin code.
///
/// Lifecycle: a swizzle is installed once per (class, selector) and kept in
/// `installed`. Installing the same hook twice is a no-op. `removeAll` is called
/// when plugins unload, restoring the original IMPs, because a removed plugin's
/// block must not keep running.
final class PluginSwizzle {
    static let shared = PluginSwizzle()

    private let lock = NSLock()
    /// One entry per hooked method, keyed so a re-hook is detected.
    private var installed: [String: Installed] = [:]

    /// A hook the plugin asked for: the class, the selector, the method kind,
    /// and the two callback tokens, which the block resolves through the
    /// plugin's own `__extera.runSwizzleCallback` on the script queue.
    struct Hook {
        let pluginId: String
        let className: String
        let selectorName: String
        let isClassMethod: Bool
        let context: JSContext
        let beforeToken: String?
        let afterToken: String?
    }

    private struct Installed {
        let method: Method
        let originalIMP: IMP
    }

    enum InstallError: Error, CustomStringConvertible {
        case unknownClass(String)
        case unknownMethod(String, String)
        case unsupportedSignature(String, String, String)

        var description: String {
            switch self {
            case let .unknownClass(name):
                return "class \(name) is not loaded, so it cannot be hooked"
            case let .unknownMethod(name, selector):
                return "\(name) has no method \(selector) on iOS"
            case let .unsupportedSignature(name, selector, types):
                return "\(name).\(selector) takes arguments or returns a type this hook cannot forward (\(types)); only object arguments with an object or void return are supported"
            }
        }
    }

    /// Installs one hook. Idempotent for the same class and selector: a second
    /// install for a pair already hooked returns without touching the runtime,
    /// so two plugins hooking the same method keep the first one's ordering and
    /// neither corrupts the other.
    func install(_ hook: Hook) throws {
        let key = PluginSwizzle.key(hook.className, hook.selectorName, hook.isClassMethod)
        self.lock.lock()
        defer { self.lock.unlock() }
        if self.installed[key] != nil {
            return
        }
        guard let cls = NSClassFromString(hook.className) else {
            throw InstallError.unknownClass(hook.className)
        }
        let selector = NSSelectorFromString(hook.selectorName)
        // For a class method, `object_getClass` reaches the metaclass, which is
        // where an Objective-C class method's implementation lives. The cast
        // through `AnyClass` is what `class_getInstanceMethod` expects either way.
        let lookup: AnyClass = hook.isClassMethod ? (object_getClass(cls) ?? cls) : cls
        guard let method = class_getInstanceMethod(lookup, selector) else {
            throw InstallError.unknownMethod(hook.className, hook.selectorName)
        }
        guard let signature = PluginSwizzle.signature(of: method) else {
            let types = method_getTypeEncoding(method).map { String(cString: $0) } ?? "?"
            throw InstallError.unsupportedSignature(hook.className, hook.selectorName, types)
        }
        let argumentCount = signature.argumentCount
        let original = method_getImplementation(method)

        // The block is typed through `imp_implementationWithBlock`, which passes
        // the receiver and the method's own arguments. The block's arity has to
        // match the method's: a block that reads two arguments from a one-argument
        // method still "works", but it reads a register the caller never set.
        //
        // A `void` method is dispatched through its own `@convention(c)` type that
        // returns nothing. Casting it to an object-returning function and reading
        // the result would take whatever happened to be in the return register —
        // usually a leftover pointer — and hand that to the plugin as the method's
        // return value.
        let context = hook.context
        let beforeToken = hook.beforeToken
        let afterToken = hook.afterToken
        let returnsObject = signature.returnsObject

        let implementation: IMP
        switch (argumentCount, returnsObject) {
        case (0, true):
            typealias Original = @convention(c) (AnyObject, Selector) -> AnyObject?
            let originalFunction = unsafeBitCast(original, to: Original.self)
            let block: @convention(block) (AnyObject) -> AnyObject? = { receiver in
                return PluginSwizzle.run(
                    context: context,
                    beforeToken: beforeToken,
                    afterToken: afterToken,
                    receiver: receiver,
                    arguments: [],
                    original: { originalFunction(receiver, selector) }
                )
            }
            implementation = imp_implementationWithBlock(block)
        case (0, false):
            typealias Original = @convention(c) (AnyObject, Selector) -> Void
            let originalFunction = unsafeBitCast(original, to: Original.self)
            let block: @convention(block) (AnyObject) -> Void = { receiver in
                _ = PluginSwizzle.run(
                    context: context,
                    beforeToken: beforeToken,
                    afterToken: afterToken,
                    receiver: receiver,
                    arguments: [],
                    original: { originalFunction(receiver, selector); return nil }
                )
            }
            implementation = imp_implementationWithBlock(block)
        case (1, true):
            typealias Original = @convention(c) (AnyObject, Selector, AnyObject?) -> AnyObject?
            let originalFunction = unsafeBitCast(original, to: Original.self)
            let block: @convention(block) (AnyObject, AnyObject?) -> AnyObject? = { receiver, arg0 in
                return PluginSwizzle.run(
                    context: context,
                    beforeToken: beforeToken,
                    afterToken: afterToken,
                    receiver: receiver,
                    arguments: [arg0],
                    original: { originalFunction(receiver, selector, arg0) }
                )
            }
            implementation = imp_implementationWithBlock(block)
        case (1, false):
            typealias Original = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
            let originalFunction = unsafeBitCast(original, to: Original.self)
            let block: @convention(block) (AnyObject, AnyObject?) -> Void = { receiver, arg0 in
                _ = PluginSwizzle.run(
                    context: context,
                    beforeToken: beforeToken,
                    afterToken: afterToken,
                    receiver: receiver,
                    arguments: [arg0],
                    original: { originalFunction(receiver, selector, arg0); return nil }
                )
            }
            implementation = imp_implementationWithBlock(block)
        case (2, true):
            typealias Original = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?) -> AnyObject?
            let originalFunction = unsafeBitCast(original, to: Original.self)
            let block: @convention(block) (AnyObject, AnyObject?, AnyObject?) -> AnyObject? = { receiver, arg0, arg1 in
                return PluginSwizzle.run(
                    context: context,
                    beforeToken: beforeToken,
                    afterToken: afterToken,
                    receiver: receiver,
                    arguments: [arg0, arg1],
                    original: { originalFunction(receiver, selector, arg0, arg1) }
                )
            }
            implementation = imp_implementationWithBlock(block)
        default:
            typealias Original = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?) -> Void
            let originalFunction = unsafeBitCast(original, to: Original.self)
            let block: @convention(block) (AnyObject, AnyObject?, AnyObject?) -> Void = { receiver, arg0, arg1 in
                _ = PluginSwizzle.run(
                    context: context,
                    beforeToken: beforeToken,
                    afterToken: afterToken,
                    receiver: receiver,
                    arguments: [arg0, arg1],
                    original: { originalFunction(receiver, selector, arg0, arg1); return nil }
                )
            }
            implementation = imp_implementationWithBlock(block)
        }

        method_setImplementation(method, implementation)
        self.installed[key] = Installed(method: method, originalIMP: original)
    }

    /// Runs `before`, the original (unless `before` replaced the result), then
    /// `after` with the original's result available to it.
    ///
    /// This is the Xposed contract: a hook that says nothing lets the method run;
    /// `setResult` in `before` short-circuits it; `setResult` in `after` replaces
    /// what the original returned. The earlier version of this file replaced the
    /// implementation and never called the original at all, so every hooked
    /// method silently became a `nil`-returning stub.
    private static func run(
        context: JSContext,
        beforeToken: String?,
        afterToken: String?,
        receiver: AnyObject,
        arguments: [AnyObject?],
        original: () -> AnyObject?
    ) -> AnyObject? {
        let receiverDescription = PluginSwizzle.describe(receiver)
        let argsJSON = PluginSwizzle.encodeArgs(arguments)

        var replaced: AnyObject?
        var didReplace = false
        PluginManager.shared.runOnJSQueueAndWait {
            if let beforeToken = beforeToken,
               let value = PluginSwizzle.call(context: context, token: beforeToken, receiver: receiverDescription, argsJSON: argsJSON, resultJSON: nil),
               let parsed = PluginSwizzle.decodeResult(value) {
                replaced = parsed
                didReplace = true
            }
        }
        if didReplace {
            return replaced
        }

        let originalValue = original()

        PluginManager.shared.runOnJSQueueAndWait {
            if let afterToken = afterToken,
               let value = PluginSwizzle.call(context: context, token: afterToken, receiver: receiverDescription, argsJSON: argsJSON, resultJSON: PluginSwizzle.encodeResult(originalValue)),
               let parsed = PluginSwizzle.decodeResult(value) {
                replaced = parsed
                didReplace = true
            }
        }
        return didReplace ? replaced : originalValue
    }

    /// Runs the plugin's `__extera.runSwizzleCallback(token, receiver, args, result)`
    /// and returns its value. The entry point does the token lookup and the call,
    /// so no `JSValue` outlives the call.
    private static func call(context: JSContext, token: String, receiver: String, argsJSON: String, resultJSON: String?) -> JSValue? {
        guard let runner = context.objectForKeyedSubscript("__extera")?.objectForKeyedSubscript("runSwizzleCallback"), !runner.isUndefined else {
            return nil
        }
        return runner.call(withArguments: [token, receiver, argsJSON, resultJSON ?? NSNull()])
    }

    /// The JSON a plugin's `setResult` produced, back as a real object.
    ///
    /// The bridge is string-only, so the callback answers with JSON text. Handing
    /// that text straight back to the hooked method's caller — which an earlier
    /// version did — meant a method that should return an array returned the
    /// string `"[]"`, and one that should return `nil` returned `"null"`.
    private static func decodeResult(_ value: JSValue) -> AnyObject?? {
        guard !value.isUndefined, !value.isNull else {
            return nil
        }
        guard let json = value.toString(), let data = json.data(using: .utf8) else {
            return nil
        }
        // `NSNull` is a legitimate result the plugin may have set, so a parse
        // failure and a parsed `null` must not be confused: the outer optional is
        // "did the plugin replace anything", the inner is the value itself.
        if let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            if parsed is NSNull {
                return .some(nil)
            }
            return .some(parsed as AnyObject)
        }
        // Not JSON: a bare string the plugin returned without encoding it.
        return .some(json as AnyObject)
    }

    private static func encodeResult(_ value: AnyObject?) -> String? {
        guard let value = value else {
            return nil
        }
        // A one-element array keeps a bare string legal JSON; the brackets are
        // stripped afterwards. A value `JSONSerialization` refuses — an arbitrary
        // Obj-C object — falls back to its description, so an `after` hook still
        // sees *something* rather than a misleading null.
        if let data = try? JSONSerialization.data(withJSONObject: [value], options: []),
           let json = String(data: data, encoding: .utf8) {
            return String(json.dropFirst().dropLast())
        }
        let description = String(describing: value)
        if let data = try? JSONSerialization.data(withJSONObject: [description], options: []),
           let json = String(data: data, encoding: .utf8) {
            return String(json.dropFirst().dropLast())
        }
        return nil
    }

    /// Restores every hooked method. Called when the plugin runtime unloads:
    /// after this no plugin block is reachable from the runtime.
    func removeAll() {
        self.lock.lock()
        defer { self.lock.unlock() }
        for (_, entry) in self.installed {
            method_setImplementation(entry.method, entry.originalIMP)
        }
        self.installed.removeAll()
    }

    /// What a hookable method's signature looks like, or nil when this hook cannot
    /// forward it.
    private struct Signature {
        let argumentCount: Int
        let returnsObject: Bool
    }

    /// Reads a method's type encoding, or nil when the hook cannot forward it.
    ///
    /// The encoding is `<return><self><cmd><args...>`, where each type may be
    /// preceded by qualifiers (`r`, `n`, `N`, `o`, `O`, `R`, `V`) and a frame
    /// offset digit, and an object type may be followed by a quoted class name.
    ///
    /// A method whose return is a struct or a primitive is refused: the block
    /// built here returns an object, and a caller that expects a `CGFloat` in the
    /// return register would read the pointer's low half. A `void` return is fine
    /// and is dispatched through its own block type.
    private static func signature(of method: Method) -> Signature? {
        guard let encoding = method_getTypeEncoding(method) else {
            return nil
        }
        var types: [Character] = []
        let characters = Array(String(cString: encoding))
        var index = 0
        while index < characters.count {
            let c = characters[index]
            if "rnNoORV".contains(c) {
                index += 1
                continue
            }
            if c.isNumber {
                index += 1
                continue
            }
            types.append(c)
            index += 1
            if c == "@", index < characters.count, characters[index] == "\"" {
                index += 1
                while index < characters.count && characters[index] != "\"" {
                    index += 1
                }
                index += 1
            }
        }
        guard types.count >= 3 else {
            return nil
        }
        let returnsObject: Bool
        switch types[0] {
        case "@":
            returnsObject = true
        case "v":
            returnsObject = false
        default:
            return nil
        }
        guard types[1] == "@", types[2] == ":" else {
            return nil
        }
        let arguments = types.dropFirst(3)
        guard arguments.allSatisfy({ $0 == "@" }) else {
            return nil
        }
        guard arguments.count <= 2 else {
            return nil
        }
        return Signature(argumentCount: arguments.count, returnsObject: returnsObject)
    }

    /// Object arguments as a JSON array, so a plugin sees the same `args` list
    /// Xposed builds from a Java method's parameters.
    private static func encodeArgs(_ args: [AnyObject?]) -> String {
        var encoded: [Any] = []
        for arg in args {
            if let arg = arg {
                encoded.append(String(describing: arg))
            } else {
                encoded.append(NSNull())
            }
        }
        if let data = try? JSONSerialization.data(withJSONObject: encoded) {
            return String(data: data, encoding: .utf8) ?? "[]"
        }
        return "[]"
    }

    private static func describe(_ object: AnyObject) -> String {
        if let value = object as? NSObject {
            return value.description
        }
        return String(describing: object)
    }

    private static func key(_ className: String, _ selector: String, _ isClassMethod: Bool) -> String {
        return (isClassMethod ? "c:" : "i:") + className + "." + selector
    }
}