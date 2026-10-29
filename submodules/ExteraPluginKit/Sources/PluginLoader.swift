import Foundation
import JavaScriptCore

/// Which host-side facilities a plugin is allowed to reach through `__host`.
///
/// The runtime is the *only* bridge between plugin JavaScript and Telegram. A
/// plugin gets exactly the members listed here; there is no scripting bridge into
/// arbitrary Objective-C objects, which keeps a plugin from walking into
/// Telegram's internals the way exteraGram's Java reflection can on Android.
public protocol PluginHost: AnyObject {
    /// Route for `plugin.log(...)`.
    func pluginLog(pluginId: String, text: String)
    /// Current persisted values for the plugin, handed to `get_setting`.
    func pluginSettings(pluginId: String) -> [String: Any]
    func pluginSetSetting(pluginId: String, key: String, value: Any?, reload: Bool)
    /// Remember that the plugin wants a request/update/send hook.
    func pluginAddHook(pluginId: String, name: String, matchSubstring: Bool)
    func pluginAddOnSendMessageHook(pluginId: String)
    func pluginAddMenuItem(pluginId: String, item: PluginMenuItem)
    func pluginRemoveMenuItem(pluginId: String, itemId: String)
    func pluginSendText(pluginId: String, peerId: Int64, text: String, options: PluginSendOptions)
    func pluginSendFile(pluginId: String, kind: String, peerId: Int64, path: String, options: PluginSendOptions)
    func pluginShowBulletin(pluginId: String, kind: String, text: String)
    func pluginSchedule(pluginId: String, delayMilliseconds: Double, token: String)
}

public struct PluginMenuItem {
    public let itemId: String
    public let menuType: String
    public let text: String
    public let icon: String?
    public let subtext: String?
    public let condition: String?
    public let priority: Int

    public init?(json: [String: Any]) {
        guard let itemId = json["item_id"] as? String,
              let menuType = json["menu_type"] as? String,
              let text = json["text"] as? String else {
            return nil
        }
        self.itemId = itemId
        self.menuType = menuType
        self.text = text
        self.icon = json["icon"] as? String
        self.subtext = json["subtext"] as? String
        self.condition = json["condition"] as? String
        self.priority = (json["priority"] as? NSNumber)?.intValue ?? 0
    }
}

public struct PluginSendOptions {
    public let replyToMessageId: Int64?
    public let silent: Bool
    public let caption: String?
    public let parseMode: String?

    public init(json: [String: Any]) {
        self.replyToMessageId = (json["replyToMsg"] as? NSNumber)?.int64Value
        self.silent = (json["notify"] as? Bool) == false
        self.caption = json["caption"] as? String
        self.parseMode = json["parse_mode"] as? String
    }
}

/// Loads plugin source into a sandboxed `JSContext`.
///
/// Each plugin gets its own context: a plugin cannot see another plugin's
/// variables, and an exception in one cannot corrupt the others. The bootstrap
/// script is evaluated first, then the plugin body, then the plugin registers
/// its class by calling `__extera.register(...)`.
public final class PluginLoader {
    private let bootstrapSource: String
    private let host: PluginHost

    public init(bootstrapSource: String, host: PluginHost) {
        self.bootstrapSource = bootstrapSource
        self.host = host
    }

    public func load(source: String, manifest: PluginManifest, directory: URL) throws -> LoadedPlugin {
        guard let context = JSContext() else {
            throw PluginError.runtimeUnavailable
        }
        context.name = manifest.id

        var exceptionText: String?
        context.exceptionHandler = { _, exception in
            exceptionText = exception?.toString()
        }

        self.installBridge(in: context)

        context.evaluateScript(self.bootstrapSource)
        if let error = exceptionText {
            throw PluginError.evaluationFailed("bootstrap: \(error)")
        }

        context.evaluateScript("__extera.setIdentity(\(jsString(manifest.id)), \(jsString(manifest.name)))")
        context.evaluateScript(source)
        if let error = exceptionText {
            throw PluginError.evaluationFailed(error)
        }

        // A ported exteraGram plugin declares `class Plugin(BasePlugin)` and the
        // runtime instantiates it; `finalize()` covers that, and also accepts a
        // plugin that called `__extera.register` itself.
        context.evaluateScript("__extera.finalize()")
        if let error = exceptionText {
            throw PluginError.evaluationFailed(error)
        }

        guard let instance = context.objectForKeyedSubscript("__extera")?.objectForKeyedSubscript("instance"),
              !instance.isUndefined, !instance.isNull else {
            throw PluginError.noPluginClass
        }

        let plugin = LoadedPlugin(manifest: manifest, directory: directory, context: context, instance: instance)
        plugin.settings = self.host.pluginSettings(pluginId: manifest.id)
        return plugin
    }

    /// Reads the `__id__`, `__name__`, ... constants a plugin declares.
    ///
    /// exteraGram parses these from the Python AST before executing the module,
    /// so nothing runs before the plugin is known to be valid. Evaluating the
    /// file here would run its top-level code twice (once for the manifest, once
    /// for the load) and could touch the network or the filesystem before the
    /// version gate decided. These are literal assignments, so they are read as
    /// text instead.
    public func readManifest(from source: String, fallbackId: String) throws -> PluginManifest {
        let rawId = self.literalString(in: source, named: "__id__") ?? fallbackId
        guard !rawId.isEmpty else {
            throw PluginError.missingIdentifier
        }
        guard self.isValidIdentifier(rawId) else {
            throw PluginError.invalidId(rawId)
        }
        guard let name = self.literalString(in: source, named: "__name__"), !name.isEmpty else {
            throw PluginError.missingName
        }

        return PluginManifest(
            id: rawId,
            name: name,
            description: self.literalString(in: source, named: "__description__") ?? "",
            author: self.literalString(in: source, named: "__author__") ?? "",
            version: self.literalString(in: source, named: "__version__") ?? "1.0",
            icon: self.literalString(in: source, named: "__icon__"),
            appVersionRequirement: self.literalString(in: source, named: "__app_version__") ?? self.literalString(in: source, named: "__min_version__"),
            sdkVersionRequirement: self.literalString(in: source, named: "__sdk_version__"),
            requirements: self.literalStringArray(in: source, named: "__requirements__") ?? []
        )
    }

    /// Finds `__name__ = "value"`, `__name__ = 'value'`, or the `var __name__ =`
    /// form a ported plugin may carry over from its Python original.
    private func literalString(in source: String, named name: String) -> String? {
        let quoted = "(?:(?:^|[^A-Za-z0-9_])\(name)\\s*=\\s*\"((?:\\\\.|[^\"\\\\])*)\")"
        let single = "|(?:(?:^|[^A-Za-z0-9_])\(name)\\s*=\\s*'((?:\\\\.|[^'\\\\])*)')"
        guard let regex = try? NSRegularExpression(pattern: quoted + single, options: []) else {
            return nil
        }
        let range = NSRange(source.startIndex ..< source.endIndex, in: source)
        guard let match = regex.firstMatch(in: source, options: [], range: range) else {
            return nil
        }
        for group in [1, 2] {
            if let valueRange = Range(match.range(at: group), in: source) {
                return self.unescape(String(source[valueRange]))
            }
        }
        return nil
    }

    /// Resolves the escapes a plugin is likely to use inside a metadata literal.
    private func unescape(_ value: String) -> String {
        guard value.contains("\\") else {
            return value
        }
        var result = ""
        var iterator = value.makeIterator()
        while let character = iterator.next() {
            guard character == "\\" else {
                result.append(character)
                continue
            }
            guard let escaped = iterator.next() else {
                result.append("\\")
                break
            }
            switch escaped {
            case "n": result.append("\n")
            case "t": result.append("\t")
            case "r": result.append("\r")
            case "\\": result.append("\\")
            case "\"": result.append("\"")
            case "'": result.append("'")
            default:
                result.append(escaped)
            }
        }
        return result
    }

    /// Finds `__requirements__ = ["a", "b"]`; empty for a plugin that has none.
    ///
    /// These name Python packages, which this runtime cannot install, so the
    /// value is only ever used to explain why a plugin will not run.
    private func literalStringArray(in source: String, named name: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: "(?:^|[^A-Za-z0-9_])\(name)\\s*=\\s*\\[([^\\]]*)\\]", options: []) else {
            return nil
        }
        let range = NSRange(source.startIndex ..< source.endIndex, in: source)
        guard let match = regex.firstMatch(in: source, options: [], range: range),
              let bodyRange = Range(match.range(at: 1), in: source) else {
            return []
        }
        let body = String(source[bodyRange])
        guard let itemRegex = try? NSRegularExpression(pattern: "\"([^\"]*)\"|'([^']*)'", options: []) else {
            return []
        }
        let itemRange = NSRange(body.startIndex ..< body.endIndex, in: body)
        return itemRegex.matches(in: body, options: [], range: itemRange).compactMap { match in
            for group in [1, 2] {
                if let valueRange = Range(match.range(at: group), in: body) {
                    return String(body[valueRange])
                }
            }
            return nil
        }
    }

    private func isValidIdentifier(_ value: String) -> Bool {
        guard value.count >= 2, value.count <= 32 else {
            return false
        }
        return value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
    }

    // MARK: - Bridge

    private func installBridge(in context: JSContext) {
        guard let hostObject = JSValue(newObjectIn: context) else {
            return
        }
        let host = self.host

        let log: @convention(block) (String, String) -> Void = { id, text in
            host.pluginLog(pluginId: id, text: text)
        }
        hostObject.setObject(log as AnyObject, forKeyedSubscript: "log" as NSString)

        let getSetting: @convention(block) (String, String) -> Any? = { id, key in
            return host.pluginSettings(pluginId: id)[key]
        }
        hostObject.setObject(getSetting as AnyObject, forKeyedSubscript: "getSetting" as NSString)

        let setSetting: @convention(block) (String, String, Any?, Bool) -> Void = { id, key, value, reload in
            host.pluginSetSetting(pluginId: id, key: key, value: value, reload: reload)
        }
        hostObject.setObject(setSetting as AnyObject, forKeyedSubscript: "setSetting" as NSString)

        let exportSettings: @convention(block) (String) -> Any? = { id in
            host.pluginSettings(pluginId: id)
        }
        hostObject.setObject(exportSettings as AnyObject, forKeyedSubscript: "exportSettings" as NSString)

        let importSettings: @convention(block) (String, [String: Any], Bool) -> Void = { id, values, reload in
            for (key, value) in values {
                host.pluginSetSetting(pluginId: id, key: key, value: value, reload: false)
            }
            if reload {
                host.pluginSetSetting(pluginId: id, key: "__reload__", value: nil, reload: true)
            }
        }
        hostObject.setObject(importSettings as AnyObject, forKeyedSubscript: "importSettings" as NSString)

        let addHook: @convention(block) (String, String, Bool) -> Void = { id, name, matchSubstring in
            host.pluginAddHook(pluginId: id, name: name, matchSubstring: matchSubstring)
        }
        hostObject.setObject(addHook as AnyObject, forKeyedSubscript: "addHook" as NSString)

        let addSendHook: @convention(block) (String) -> Void = { id in
            host.pluginAddOnSendMessageHook(pluginId: id)
        }
        hostObject.setObject(addSendHook as AnyObject, forKeyedSubscript: "addOnSendMessageHook" as NSString)

        let addMenuItem: @convention(block) (String, String) -> String? = { id, json in
            guard let data = json.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let item = PluginMenuItem(json: object) else {
                return nil
            }
            host.pluginAddMenuItem(pluginId: id, item: item)
            return item.itemId
        }
        hostObject.setObject(addMenuItem as AnyObject, forKeyedSubscript: "addMenuItem" as NSString)

        let removeMenuItem: @convention(block) (String, String) -> Void = { id, itemId in
            host.pluginRemoveMenuItem(pluginId: id, itemId: itemId)
        }
        hostObject.setObject(removeMenuItem as AnyObject, forKeyedSubscript: "removeMenuItem" as NSString)

        let sendText: @convention(block) (String, Double, String, String) -> Void = { id, peerId, text, optionsJSON in
            host.pluginSendText(pluginId: id, peerId: Int64(peerId), text: text, options: parseSendOptions(optionsJSON))
        }
        hostObject.setObject(sendText as AnyObject, forKeyedSubscript: "sendText" as NSString)

        let sendFile: @convention(block) (String, String, Double, String, String) -> Void = { id, kind, peerId, path, optionsJSON in
            host.pluginSendFile(pluginId: id, kind: kind, peerId: Int64(peerId), path: path, options: parseSendOptions(optionsJSON))
        }
        hostObject.setObject(sendFile as AnyObject, forKeyedSubscript: "sendFile" as NSString)

        let showBulletin: @convention(block) (String, String, String) -> Void = { id, kind, text in
            host.pluginShowBulletin(pluginId: id, kind: kind, text: text)
        }
        hostObject.setObject(showBulletin as AnyObject, forKeyedSubscript: "showBulletin" as NSString)

        let pluginDirectory: @convention(block) (String) -> String = { id in
            PluginStore.shared.directory(for: id).path
        }
        hostObject.setObject(pluginDirectory as AnyObject, forKeyedSubscript: "pluginDirectory" as NSString)

        let schedule: @convention(block) (String, Double, String) -> Void = { id, delay, token in
            host.pluginSchedule(pluginId: id, delayMilliseconds: delay, token: token)
        }
        hostObject.setObject(schedule as AnyObject, forKeyedSubscript: "schedulePlugin" as NSString)

        context.setObject(hostObject, forKeyedSubscript: "__host" as NSString)
    }
}

/// Turns a JSON options blob from JavaScript into typed options; a malformed
/// blob yields defaults rather than throwing across the bridge.
private func parseSendOptions(_ json: String) -> PluginSendOptions {
    guard let data = json.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return PluginSendOptions(json: [:])
    }
    return PluginSendOptions(json: object)
}

/// Quotes a Swift string as a JavaScript literal, escaping the characters that
/// would otherwise terminate the string or break the script.
func jsString(_ value: String) -> String {
    var result = "\""
    for character in value.unicodeScalars {
        switch character {
        case "\"": result += "\\\""
        case "\\": result += "\\\\"
        case "\n": result += "\\n"
        case "\r": result += "\\r"
        case "\t": result += "\\t"
        default:
            if character.value < 0x20 {
                result += String(format: "\\u%04x", character.value)
            } else {
                result.unicodeScalars.append(character)
            }
        }
    }
    return result + "\""
}