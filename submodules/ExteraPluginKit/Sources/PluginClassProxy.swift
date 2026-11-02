import Foundation
import ObjectiveC.runtime
import JavaScriptCore

/// Runtime class creation for plugins, the iOS shape of exteraGram's DexMaker
/// subclassing.
///
/// On Android `extera_utils.classes.jclassbuilder` builds a new Java class at
/// runtime — a subclass of an existing one, with overridden methods — and hands
/// back a constructor. A plugin uses it to pass a listener or a callback object
/// into an API that wants an interface.
///
/// Objective-C has the same primitive under a different name:
/// `objc_allocateClassPair` makes a subclass, `class_addMethod` adds a method
/// whose implementation is a block, and `objc_registerClassPair` publishes it.
/// That is what this wraps. The plugin describes the class in JSON — the
/// superclass name, a list of methods with a selector, and for each a JavaScript
/// callback — and gets back the new class's name, which it can then instantiate
/// through `makeInstance`.
///
/// What is the same: the class really exists in the runtime, is a real subclass,
/// and its methods really call the plugin. What is different: only methods whose
/// signature is "receiver, zero to two object arguments, object return" can be
/// added, because that is the block ABI the runtime accepts here, and the arity
/// is taken from the JavaScript function the plugin supplied — the only place
/// that knows how many arguments the method is called with. A method that needs a
/// struct argument, a primitive return or a variadic call is reported, not
/// silently added with a wrong ABI.
///
/// The generated classes are owned by the plugin that asked for them and are
/// never freed: `objc_disposeClassPair` on a class that something still
/// references is a crash, and a plugin's objects may outlive the plugin. The
/// class name carries the plugin id and a counter, so two plugins cannot collide.
final class PluginClassProxy {
    static let shared = PluginClassProxy()

    private let lock = NSLock()
    /// Classes created, by the name handed back to the plugin. Kept so a second
    /// build with the same description reuses the class rather than allocating
    /// one per call, which the runtime would refuse anyway for a repeated name.
    private var created: [String: String] = [:]
    private var counter = 0

    /// One method to add: the selector, the token of the JavaScript callback that
    /// implements it, and how many arguments that callback declared.
    struct MethodSpec {
        let selector: String
        let token: String
        let argumentCount: Int
    }

    enum BuildError: Error, CustomStringConvertible {
        case unknownSuperclass(String)
        case badName(String)
        case reservedName(String)

        var description: String {
            switch self {
            case let .unknownSuperclass(name):
                return "superclass \(name) is not loaded"
            case let .badName(name):
                return "\(name) is not a usable class name"
            case let .reservedName(name):
                return "\(name) collides with a class the app already has"
            }
        }
    }

    /// Builds a subclass of `superclassName` with the given methods and returns
    /// its runtime name. `ownerId` namespaces the generated name.
    func build(ownerId: String, superclassName: String, methods: [MethodSpec], context: JSContext) throws -> String {
        guard let superclass = NSClassFromString(superclassName) else {
            throw BuildError.unknownSuperclass(superclassName)
        }
        let name = self.nextToken(ownerId: ownerId)

        self.lock.lock()
        if let existing = self.created[name] {
            self.lock.unlock()
            return existing
        }
        self.lock.unlock()

        var subclass: AnyClass?
        name.withCString { cName -> Void in
            subclass = objc_allocateClassPair(superclass, cName, 0)
        }
        guard let subclass = subclass else {
            throw BuildError.badName(name)
        }

        for method in methods {
            let selector = NSSelectorFromString(method.selector)
            let token = method.token
            // The block ABI the runtime accepts for a method added this way is
            // "receiver, N object arguments, object return". `N` has to be what
            // the plugin's callback declared: a block that reads two arguments
            // from a one-argument method still runs, but it reads a register the
            // caller never wrote, and the value it forwards to the plugin is
            // whatever happened to be there.
            let implementation: IMP
            let types: String
            switch method.argumentCount {
            case 0:
                let block: @convention(block) (AnyObject) -> AnyObject? = { receiver in
                    return PluginClassProxy.callAndWait(context: context, token: token, receiver: receiver, arguments: [])
                }
                implementation = imp_implementationWithBlock(block)
                types = "@@:"
            case 1:
                let block: @convention(block) (AnyObject, AnyObject?) -> AnyObject? = { receiver, arg0 in
                    return PluginClassProxy.callAndWait(context: context, token: token, receiver: receiver, arguments: [arg0])
                }
                implementation = imp_implementationWithBlock(block)
                types = "@@:@"
            default:
                let block: @convention(block) (AnyObject, AnyObject?, AnyObject?) -> AnyObject? = { receiver, arg0, arg1 in
                    return PluginClassProxy.callAndWait(context: context, token: token, receiver: receiver, arguments: [arg0, arg1])
                }
                implementation = imp_implementationWithBlock(block)
                types = "@@:@@"
            }
            // `class_addMethod` wants a C string of type encodings, so the Swift
            // string is handed over inside its own scope. The return is `@`, not
            // `v`: a method declared as returning nothing makes the runtime drop
            // the object the plugin built, and the caller then reads the return
            // register uninitialised.
            //
            // It answers false when the class already implements the selector —
            // which is the normal case for an override, since the superclass's
            // method is what the plugin wants to replace. Adding then does
            // nothing at all and the plugin's method is never called, so the
            // failure path replaces instead.
            var added = false
            types.withCString { encodings -> Void in
                added = class_addMethod(subclass, selector, implementation, encodings)
            }
            if !added {
                types.withCString { encodings -> Void in
                    _ = class_replaceMethod(subclass, selector, implementation, encodings)
                }
            }
        }

        objc_registerClassPair(subclass)

        self.lock.lock()
        self.created[name] = name
        self.lock.unlock()
        return name
    }

    /// Instantiates a class this type built. Answers nil when the name is not
    /// one of ours, so a plugin cannot use this to construct an arbitrary app
    /// class by name.
    func makeInstance(className: String) -> AnyObject? {
        self.lock.lock()
        let owned = self.created[className] != nil
        self.lock.unlock()
        guard owned, let cls = NSClassFromString(className) else {
            return nil
        }
        guard let instance = (cls as? NSObject.Type)?.init() else {
            return nil
        }
        return instance
    }

    private func nextToken(ownerId: String) -> String {
        self.lock.lock()
        self.counter += 1
        let value = self.counter
        self.lock.unlock()
        // Objective-C class names are ASCII identifiers; the plugin id may hold
        // characters that are not, so it is reduced to letters and digits.
        let safe = ownerId.unicodeScalars.map { scalar -> Character in
            let c = Character(scalar)
            return c.isLetter || c.isNumber ? c : "_"
        }
        let stem = String(safe)
        return "__ExteraProxy_\(stem)_\(value)"
    }

    private static func callAndWait(context: JSContext, token: String, receiver: AnyObject, arguments: [AnyObject?]) -> AnyObject? {
        let receiverDescription = String(describing: receiver)
        let argsJSON = PluginClassProxy.encodeArgs(arguments)
        var result: AnyObject?
        var didReturn = false
        PluginManager.shared.runOnJSQueueAndWait {
            guard let value = PluginClassProxy.call(context: context, token: token, receiver: receiverDescription, argsJSON: argsJSON),
                  let parsed = PluginClassProxy.decodeResult(value) else {
                return
            }
            result = parsed
            didReturn = true
        }
        return didReturn ? result : nil
    }

    private static func call(context: JSContext, token: String, receiver: String, argsJSON: String) -> JSValue? {
        guard let runner = context.objectForKeyedSubscript("__extera")?.objectForKeyedSubscript("runSwizzleCallback"), !runner.isUndefined else {
            return nil
        }
        // The same entry point the swizzle hooks use: a callback token resolves
        // to the plugin function, which is called with the receiver and the
        // arguments. One token map serves both, because both are "call this
        // plugin function from the runtime".
        return runner.call(withArguments: [token, receiver, argsJSON, NSNull()])
    }

    /// The JSON a plugin method's return value became, back as a real object.
    ///
    /// `runSwizzleCallback` answers with JSON text, and handing that text to the
    /// caller would make a method declared to return an array return the string
    /// `"[]"`. A parsed `null` is a legitimate `nil` return, so it is not the same
    /// as "the plugin returned nothing".
    private static func decodeResult(_ value: JSValue) -> AnyObject?? {
        guard !value.isUndefined, !value.isNull else {
            return nil
        }
        guard let json = value.toString(), let data = json.data(using: .utf8) else {
            return nil
        }
        if let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            if parsed is NSNull {
                return .some(nil)
            }
            return .some(parsed as AnyObject)
        }
        return .some(json as AnyObject)
    }

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
}
