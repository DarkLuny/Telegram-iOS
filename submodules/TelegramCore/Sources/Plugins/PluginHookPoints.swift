import Foundation
import MtProtoKit
// Same access level the rest of TelegramCore uses, and all that is needed here:
// no `Api.*` type appears in this file's public surface, only TL values passed
// as `Any` and turned into JSON.
internal import TelegramApi

/// Hook points the plugin runtime attaches to, declared inside TelegramCore so the
/// core does not depend on the plugin module.
///
/// The dependency direction matters: `ExteraPluginKit` needs `AccountContext`, and
/// `AccountContext` needs `TelegramCore`. A direct reference from the core to the
/// plugin runtime would be a cycle. Instead the core exposes these closures and
/// the app wires them up at launch; when nothing is wired every hook is `nil` and
/// the cost is one optional check.
///
/// Arguments cross these closures as JSON text, never as object graphs. A TL
/// request's parameters contain Swift enums and `TLObject`s that
/// `JSONSerialization` refuses, so they are flattened by
/// `pluginRequestParametersJSON` before they get here.
public final class PluginHookPoints {
    public static let shared = PluginHookPoints()

    /// Called before an outgoing message is enqueued. `text` may be rewritten in
    /// place; returning `false` cancels the send.
    ///
    /// Mirrors exteraGram's `on_send_message_hook`, which can both replace the
    /// message and drop it.
    public var sendMessage: ((_ accountId: Int64, _ peerId: Int64, _ text: inout String) -> Bool)?

    /// Whether a plugin listens for this request name (`messages.setTyping`).
    ///
    /// Checked before the parameters are flattened: a build with no plugins must
    /// not pay for building a JSON document on every request, and the flattening
    /// walks every parameter of every TL call. `nil` means nothing intercepts
    /// requests at all.
    public var wantsRequest: ((_ name: String) -> Bool)?

    /// Called before a TL request leaves the device, with the request's parameters
    /// as a JSON object. Returning `false` cancels the request.
    ///
    /// `name` is the schema constructor name with dots (`messages.setTyping`), the
    /// identifier exteraGram's `pre_request_hook` receives.
    public var preRequest: ((_ name: String, _ accountId: Int64, _ parametersJSON: String) -> Bool)?

    /// Called after a TL request finished, whether it succeeded or failed.
    ///
    /// `responseJSON` is the flattened result (constructor fields, like a
    /// request's parameters) and is `"{}"` for a failed call; `error` is the
    /// server's description when there was one. exteraGram's
    /// `post_request_hook(name, account, response, error)` maps onto this.
    public var postRequest: ((_ name: String, _ accountId: Int64, _ responseJSON: String, _ error: String?) -> Void)?

    /// Called for every update the account state receives. `name` is the update's
    /// constructor (`updateNewMessage`), which is what exteraGram's
    /// `on_update_hook` is matched against; `updateJSON` flattens its fields the
    /// same way a request's parameters are flattened.
    ///
    /// Unlike a request hook this cannot cancel or rewrite anything: the update
    /// has already been accepted, and a plugin only observes it.
    public var receivedUpdate: ((_ accountId: Int64, _ name: String, _ updateJSON: String) -> Void)?

    /// Called once per received batch, for plugins that subscribed to `*`. The
    /// JSON is `{"updates": [{"name": ..., "fields": {...}}, ...]}`.
    public var receivedUpdates: ((_ accountId: Int64, _ batchJSON: String) -> Void)?

    /// Whether any plugin cares about an update constructor. Checked before the
    /// fields are flattened, because describing an update is far more expensive
    /// than comparing a name, and app with no plugins should pay neither.
    public var wantsUpdate: ((_ name: String) -> Bool)?

    private init() {
    }
}

/// A request was cancelled by a plugin. Reported to the caller as an ordinary
/// error, because every call site already handles `MTRpcError`.
public let pluginCancelledRequestError: MTRpcError = MTRpcError(errorCode: 406, errorDescription: "PLUGIN_CANCELLED")

/// Flattens TL request parameters into something `JSONSerialization` accepts.
///
/// Primitive values pass through; everything else becomes its description, which
/// for a generated `Api.*` value is the constructor name (`peerUser`) rather than
/// its fields. That is exactly what a plugin can act on, and it cannot leak the
/// whole object graph into a script.
func pluginRequestParametersJSON(_ parameters: [(String, ConstructorParameterDescription)]) -> String {
    var result: [String: Any] = [:]
    for (name, description) in parameters {
        result[name] = pluginJSONValue(description.value)
    }
    return pluginJSONString(result)
}

private func pluginJSONValue(_ value: Any?) -> Any {
    switch value {
    case nil, is NSNull:
        return NSNull()
    case let value as String:
        return value
    case let value as Bool:
        return value
    case let value as Int:
        return value
    case let value as Int32:
        return Int(value)
    case let value as Int64:
        return value
    case let value as Double:
        return value
    case let value as Data:
        return value.base64EncodedString()
    case let value as [Any?]:
        return value.map { pluginJSONValue($0) }
    case let value as [Any]:
        return value.map { pluginJSONValue($0) }
    default:
        // `CustomStringConvertible` on a generated API value prints the constructor
        // name only (see TLObjectSupport), so this stays small and stable.
        if let value = value {
            return String(describing: value)
        }
        return NSNull()
    }
}

/// Any TL value as a JSON object of its fields.
///
/// A generated `Api.*` value describes itself by constructor name plus fields
/// (`TypeConstructorDescription`), which is the shape a plugin's
/// `post_request_hook` gets on Android. Anything that cannot describe itself
/// keeps the constructor-name fallback from `pluginJSONValue`.
func pluginValueJSON(_ value: Any?) -> String {
    var result: [String: Any] = [:]
    if let description = value as? TypeConstructorDescription {
        let (name, parameters) = description.descriptionFields()
        result["_"] = name
        for (fieldName, fieldValue) in parameters {
            result[fieldName] = pluginJSONValue(fieldValue.value)
        }
    } else {
        result["_"] = pluginJSONValue(value)
    }
    return pluginJSONString(result)
}

/// One update as a plugin's `on_update_hook` sees it.
///
/// The constructor name is the identifier exteraGram matches against
/// (`updateNewMessage`), and the fields are flattened exactly like a request's
/// parameters. `descriptionFields()` reads the schema table, so it cannot fail;
/// an update with no fields simply arrives as an empty dictionary.
func pluginUpdateFields(_ update: Api.Update) -> (name: String, fields: [String: Any]) {
    // `Api.Update` conforms to `TypeConstructorDescription`, so this is a plain
    // call rather than a conditional cast; the generated enums describe
    // themselves from the schema table.
    let (name, parameters) = update.descriptionFields()
    var fields: [String: Any] = [:]
    for (fieldName, value) in parameters {
        fields[fieldName] = pluginJSONValue(value.value)
    }
    return (name, fields)
}

/// `JSONSerialization` output as text, `"{}"` when the object cannot be encoded.
///
/// Every value reaching this point already came from `pluginJSONValue`, so a
/// failure means a non-JSON type slipped through; degrading to an empty object
/// keeps a hook from throwing into the account state machine.
func pluginJSONString(_ object: [String: Any]) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
          let text = String(data: data, encoding: .utf8) else {
        return "{}"
    }
    return text
}