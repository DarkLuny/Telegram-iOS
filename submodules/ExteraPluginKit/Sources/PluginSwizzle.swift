import Foundation
import ObjectiveC.runtime
import JavaScriptCore

/// An Objective-C swizzling surface for plugins, the iOS shape of exteraGram's
/// Xposed hooks.
///
/// On Android a plugin hooks a Java method by class name and signature and gets
/// `beforeHookedMethod`/`afterHookedMethod` callbacks with a `MethodHookParam`
/// that can read and replace the arguments and the result. Xposed rewrites the
/// method body inside ART's runtime.
///
/// There is no ART here, and a plugin cannot be handed the Objective-C runtime
/// directly — one `class_getInstanceMethod` on the wrong class and the app is
/// undefined behaviour. So the surface is narrower but real: a plugin names a
/// class, a selector and whether it wants the *instance* or *class* method, and
/// the host installs a block that re-enters the plugin with the receiver and the
/// arguments, and honors a result the plugin returns. The plugin never touches
/// the runtime itself.
///
/// What this can hook: an Objective-C method that already exists on a class the
/// app has loaded. What it cannot: Swift methods not exposed to Objective-C (no
/// `@objc`), C functions, and anything that would need the method to exist
/// before this runs. A name that resolves to nothing is reported, not created.
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

        var description: String {
            switch self {
            case let .unknownClass(name):
                return "class \(name) is not loaded, so it cannot be hooked"
            case let .unknownMethod(name, selector):
                return "\(name) has no method \(selector) on iOS"
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
        let original = method_getImplementation(method)

        // The block is typed through `imp_implementationWithBlock`, which passes
        // the receiver and the method's own arguments. Only a fixed arity can be
        // represented here, so the hook forwards up to two object arguments as
        // JSON and reads back an optional result. A method with a different
        // shape still runs; its arguments arrive as the two-object slice, which
        // is what the SDK's `args` list is on Android too.
        let context = hook.context
        let beforeToken = hook.beforeToken
        let afterToken = hook.afterToken

        let block: @convention(block) (AnyObject, AnyObject?, AnyObject?) -> AnyObject? = { receiver, arg0, arg1 in
            // Re-entering JavaScript from an arbitrary thread: the plugin's
            // `before`/`after` run on the script queue, and this thread waits.
            // A hook that ran synchronously on the calling thread would take the
            // plugin lock while holding the app's own lock, which is a deadlock
            // waiting to happen.
            let receiverDescription = PluginSwizzle.describe(receiver)
            let argsJSON = PluginSwizzle.encodeArgs([arg0, arg1])
            var replacement: AnyObject?
            PluginManager.shared.runOnJSQueueAndWait {
                if let beforeToken = beforeToken,
                   let value = PluginSwizzle.call(context: context, token: beforeToken, receiver: receiverDescription, argsJSON: argsJSON),
                   !value.isUndefined, !value.isNull {
                    replacement = value.toObject() as AnyObject?
                }
                if let afterToken = afterToken,
                   let value = PluginSwizzle.call(context: context, token: afterToken, receiver: receiverDescription, argsJSON: argsJSON),
                   !value.isUndefined, !value.isNull {
                    replacement = value.toObject() as AnyObject?
                }
            }
            // A `before` (or a late `after`) that returned a value replaces the
            // method's result and the original is skipped — the same contract as
            // Xposed's `setResult` plus `returnConstant`. A hook that returned
            // nothing lets the original value stand, which is the common case.
            return replacement
        }

        method_setImplementation(method, imp_implementationWithBlock(block))
        self.installed[key] = Installed(method: method, originalIMP: original)
    }

    /// Runs the plugin's `__extera.runSwizzleCallback(token, receiver, args)` and
    /// returns its value. The entry point does the token lookup and the call, so
    /// no `JSValue` outlives the call.
    private static func call(context: JSContext, token: String, receiver: String, argsJSON: String) -> JSValue? {
        guard let runner = context.objectForKeyedSubscript("__extera")?.objectForKeyedSubscript("runSwizzleCallback"), !runner.isUndefined else {
            return nil
        }
        return runner.call(withArguments: [token, receiver, argsJSON])
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

    /// Up to two object arguments as a JSON array, so a plugin sees the same
    /// `args` list Xposed builds from a Java method's parameters.
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
