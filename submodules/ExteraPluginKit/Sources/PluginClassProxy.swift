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
/// signature is "receiver, up to two object arguments, object return" can be
/// added, because that is the block ABI the runtime accepts here. A method that
/// needs a struct argument, a primitive return or a variadic call is reported,
/// not silently added with a wrong ABI.
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

    /// One method to add: the selector and the token of the JavaScript callback
    /// that implements it.
    struct MethodSpec {
        let selector: String
        let token: String
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
        name.withCString { cName in
            subclass = objc_allocateClassPair(superclass, cName, 0)
        }
        guard let subclass = subclass else {
            throw BuildError.badName(name)
        }

        for method in methods {
            let selector = NSSelectorFromString(method.selector)
            let token = method.token
            // The block ABI the runtime accepts for a method added this way:
            // the receiver, then the arguments, returning an object. A selector
            // whose real signature differs is added with this shape anyway, and
            // a mismatch is the plugin's to report — the same latitude DexMaker
            // gives when the declared types do not match.
            let block: @convention(block) (AnyObject, AnyObject?, AnyObject?) -> AnyObject? = { receiver, arg0, arg1 in
                let receiverDescription = String(describing: receiver)
                let argsJSON = PluginClassProxy.encodeArgs([arg0, arg1])
                var result: AnyObject?
                PluginManager.shared.runOnJSQueueAndWait {
                    if let value = PluginClassProxy.call(context: context, token: token, receiver: receiverDescription, argsJSON: argsJSON),
                       !value.isUndefined, !value.isNull {
                        result = value.toObject() as AnyObject?
                    }
                }
                return result
            }
            let implementation = imp_implementationWithBlock(block)
            // `class_addMethod` wants a C string of type encodings; the Swift
            // string has to be handed over inside its own scope.
            let types = "v@:@@"
            types.withCString { encodings in
                class_addMethod(subclass, selector, implementation, encodings)
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

    private static func call(context: JSContext, token: String, receiver: String, argsJSON: String) -> JSValue? {
        guard let runner = context.objectForKeyedSubscript("__extera")?.objectForKeyedSubscript("runSwizzleCallback"), !runner.isUndefined else {
            return nil
        }
        // The same entry point the swizzle hooks use: a callback token resolves
        // to the plugin function, which is called with the receiver and the
        // arguments. One token map serves both, because both are "call this
        // plugin function from the runtime".
        return runner.call(withArguments: [token, receiver, argsJSON])
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
