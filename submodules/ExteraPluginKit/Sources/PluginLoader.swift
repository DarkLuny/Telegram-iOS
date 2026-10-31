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
    /// `account` is the exteraGram account id, or nil for "the selected one".
    func pluginSendText(pluginId: String, account: Int64?, peerId: Int64, text: String, options: PluginSendOptions)
    func pluginSendFile(pluginId: String, account: Int64?, kind: String, peerId: Int64, path: String, options: PluginSendOptions)
    func pluginEditMessage(pluginId: String, account: Int64?, peerId: Int64, messageId: Int64, text: String, options: PluginSendOptions)
    func pluginShowBulletin(pluginId: String, kind: String, json: String)
    func pluginShowAlert(pluginId: String, json: String)
    func pluginDismissAlert(pluginId: String)
    /// Filesystem request: `op` names the mode, `payload` is the text or base64.
    func pluginFileOperation(pluginId: String, op: String, path: String, payload: String?) -> String?
    /// The account selected in the UI, so `get_selected_account()` has a value.
    func pluginSelectedAccount(pluginId: String) -> Int64?
    /// The colours the running theme uses, as a JSON object of `0xRRGGBB`
    /// numbers keyed by the names the plugin asked for.
    ///
    /// A plugin that offers "take the colour from the theme" has to show the
    /// user what each source currently is; on Android it read
    /// `Theme.getColor(Theme.key_*)` directly. Synchronous because it reads an
    /// already-built value and never waits on anything.
    func pluginThemeColors(pluginId: String, namesJSON: String) -> String?
    /// Puts text on the system clipboard and reports it, like
    /// `android_utils.copy_to_clipboard`.
    func pluginCopyToClipboard(pluginId: String, text: String)
    /// Opens a URL with the app's own rules: `https`/`http` in the in-app browser,
    /// everything else through the system handler.
    ///
    /// Returns whether the URL was accepted, so `open_url` can answer the plugin
    /// the way `Browser.openUrl` answers a boolean on Android.
    func pluginOpenUrl(pluginId: String, url: String) -> Bool
    /// The running app's version, e.g. `"13.1.1"`.
    ///
    /// On Android a plugin reads `BuildVars.BUILD_VERSION_STRING` to gate a
    /// feature on the client build; there is no such class here, so the same
    /// string comes from the bundle. Synchronous because it is a constant.
    func pluginAppVersion(pluginId: String) -> String
    func pluginSchedule(pluginId: String, delayMilliseconds: Double, token: String)

    // Network and proxy. All five are asynchronous: the answer is delivered by
    // calling `__extera.resolveBridge(token, json)` once the work finishes, so a
    // plugin never blocks the script queue waiting for a socket or a database
    // transaction. exteraGram's plugins reach these through Python's `urllib`
    // and Java reflection; here they are explicit host calls.
    //
    /// `http_get` — `headersJSON` is a JSON object of request headers, `timeout`
    /// is in seconds (0 means the default). The callback receives either
    /// `{"ok": true, "status": 200, "text": "...", "headers": {...}}` or
    /// `{"ok": false, "error": "..."}`.
    func pluginHttpGet(pluginId: String, url: String, headersJSON: String, timeout: Double, callbackToken: String)
    /// The proxy list as `{"ok": true, "servers": [{"link": "tg://...", "kind": "mtproto|web|socks", "host": "...", "port": 443}]}`.
    func pluginProxyList(pluginId: String, callbackToken: String)
    /// Adds every parseable link in `linksJSON`. Answers
    /// `{"ok": true, "added": 0, "duplicates": 0, "invalid": 0}`.
    func pluginProxyAdd(pluginId: String, linksJSON: String, callbackToken: String)
    /// Empties the list and turns proxying off. Answers `{"ok": true, "removed": 0}`.
    func pluginProxyRemoveAll(pluginId: String, callbackToken: String)
    /// The id of the account's own user, which is also the Saved Messages peer.
    /// Answers `{"ok": true, "peer_id": 123}`.
    func pluginOwnPeerId(pluginId: String, account: Int64?, callbackToken: String)
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
    /// Entities the plugin already produced, as JSON.
    ///
    /// The bootstrap parses `parse_mode` on the JavaScript side, so text arrives
    /// with its formatting already resolved into entities. They stay encoded here
    /// rather than as `[MessageTextEntity]` because this type lives in the module
    /// that must not depend on TelegramCore.
    public let entitiesJSON: String?
    /// Same, for a media caption.
    public let captionEntitiesJSON: String?

    public init(json: [String: Any]) {
        self.replyToMessageId = (json["replyToMsg"] as? NSNumber)?.int64Value
        self.silent = (json["notify"] as? Bool) == false
        self.caption = json["caption"] as? String
        self.parseMode = json["parse_mode"] as? String
        self.entitiesJSON = PluginSendOptions.jsonString(json["entities"])
        self.captionEntitiesJSON = PluginSendOptions.jsonString(json["caption_entities"])
    }

    private static func jsonString(_ value: Any?) -> String? {
        guard let value = value, !(value is NSNull),
              JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return text
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

    /// The id a plugin declares, or nil when it declares none.
    ///
    /// Reads only `__id__`, from the text, without touching the rest of the
    /// manifest: installing a bundled plugin has to know where to write the file
    /// before anything is evaluated, and a plugin whose `__id__` is missing is
    /// still worth writing out so the loader can report the precise failure.
    public func manifestIdentifier(in source: String) -> String? {
        guard let value = self.literalString(in: source, named: "__id__"), !value.isEmpty else {
            return nil
        }
        return value
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
        // A `.plugin` file in the wild is usually Python: exteraGram's SDK is
        // Python, and the six plugins that could not be ported all look like
        // this. Evaluating one produces "Unexpected identifier" from JavaScriptCore,
        // which says nothing about why. Recognising the shape here turns a
        // cryptic syntax error into an instruction.
        if self.looksLikePython(source) {
            throw PluginError.pythonSource
        }
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

    /// Whether the source is Python rather than JavaScript.
    ///
    /// Deliberately conservative: it fires on lines that start at column zero
    /// with a Python-only keyword, plus the two decorators and the
    /// `class X(BasePlugin)` declaration exteraGram plugins use. JavaScript has no
    /// statement that begins with `import x` followed by a bare module name,
    /// `def`, `elif`, or `pass`, and a comment mentioning Python does not trip it.
    /// Getting this wrong in the other direction — refusing a real JavaScript
    /// plugin — is the failure that matters, so every marker is anchored.
    private func looksLikePython(_ source: String) -> Bool {
        var sawDefinition = false
        var sawClass = false
        for rawLine in source.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") {
                continue
            }
            // `def name(...):` and `async def` only exist in Python where a
            // JavaScript function would need `function`.
            if line.hasPrefix("def ") && line.hasSuffix(":") {
                sawDefinition = true
            } else if line.hasPrefix("async def ") {
                sawDefinition = true
            }
            // `class Name(BasePlugin):` — the base in parentheses and the colon
            // are both Python; JavaScript would write `class Name extends`.
            if line.hasPrefix("class ") && line.hasSuffix(":") && line.contains("(") {
                sawClass = true
            }
            if sawDefinition && sawClass {
                return true
            }
            // A decorator is unambiguous on its own: `@joverride` above a
            // function is the exteraGram idiom.
            if line.hasPrefix("@") && !line.hasPrefix("@media") {
                let rest = line.dropFirst()
                if rest.range(of: "^[A-Za-z_][A-Za-z0-9_.]*$", options: .regularExpression) != nil {
                    return true
                }
            }
            // `from module import name` is Python; JavaScript has no `from`
            // statement at the start of a line.
            if line.hasPrefix("from ") && line.contains(" import ") {
                return true
            }
        }
        // The fallback pair: a file with both a `def` and a `BasePlugin` class is
        // Python even if the class was written in one line.
        return sawDefinition && source.contains("BasePlugin")
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

        let sendText: @convention(block) (String, Double, Double, String, String) -> Void = { id, account, peerId, text, optionsJSON in
            host.pluginSendText(pluginId: id, account: PluginLoader.accountValue(account), peerId: Int64(peerId), text: text, options: parseSendOptions(optionsJSON))
        }
        hostObject.setObject(sendText as AnyObject, forKeyedSubscript: "sendText" as NSString)

        let sendFile: @convention(block) (String, Double, String, Double, String, String) -> Void = { id, account, kind, peerId, path, optionsJSON in
            host.pluginSendFile(pluginId: id, account: PluginLoader.accountValue(account), kind: kind, peerId: Int64(peerId), path: path, options: parseSendOptions(optionsJSON))
        }
        hostObject.setObject(sendFile as AnyObject, forKeyedSubscript: "sendFile" as NSString)

        let editMessage: @convention(block) (String, Double, Double, Double, String, String) -> Void = { id, account, peerId, messageId, text, optionsJSON in
            host.pluginEditMessage(pluginId: id, account: PluginLoader.accountValue(account), peerId: Int64(peerId), messageId: Int64(messageId), text: text, options: parseSendOptions(optionsJSON))
        }
        hostObject.setObject(editMessage as AnyObject, forKeyedSubscript: "editMessage" as NSString)

        // The bulletin payload is JSON: a plain message is one object, and the
        // richer variants add a button or an undo action whose callbacks are
        // tokens the plugin stored.
        let showBulletin: @convention(block) (String, String, String) -> Void = { id, kind, json in
            host.pluginShowBulletin(pluginId: id, kind: kind, json: json)
        }
        hostObject.setObject(showBulletin as AnyObject, forKeyedSubscript: "showBulletin" as NSString)

        let showAlert: @convention(block) (String, String) -> Void = { id, json in
            host.pluginShowAlert(pluginId: id, json: json)
        }
        hostObject.setObject(showAlert as AnyObject, forKeyedSubscript: "showAlert" as NSString)

        let dismissAlert: @convention(block) (String) -> Void = { id in
            host.pluginDismissAlert(pluginId: id)
        }
        hostObject.setObject(dismissAlert as AnyObject, forKeyedSubscript: "dismissAlert" as NSString)

        let fileOp: @convention(block) (String, String, String, String?) -> String? = { id, op, path, payload in
            return host.pluginFileOperation(pluginId: id, op: op, path: path, payload: payload)
        }
        hostObject.setObject(fileOp as AnyObject, forKeyedSubscript: "fileOp" as NSString)

        let selectedAccount: @convention(block) (String) -> Double = { id in
            return Double(host.pluginSelectedAccount(pluginId: id) ?? 0)
        }
        hostObject.setObject(selectedAccount as AnyObject, forKeyedSubscript: "selectedAccount" as NSString)

        let themeColors: @convention(block) (String, String) -> String? = { id, namesJSON in
            return host.pluginThemeColors(pluginId: id, namesJSON: namesJSON)
        }
        hostObject.setObject(themeColors as AnyObject, forKeyedSubscript: "themeColors" as NSString)

        let copyToClipboard: @convention(block) (String, String) -> Void = { id, text in
            host.pluginCopyToClipboard(pluginId: id, text: text)
        }
        hostObject.setObject(copyToClipboard as AnyObject, forKeyedSubscript: "copyToClipboard" as NSString)

        let openUrl: @convention(block) (String, String) -> Bool = { id, url in
            return host.pluginOpenUrl(pluginId: id, url: url)
        }
        hostObject.setObject(openUrl as AnyObject, forKeyedSubscript: "openUrl" as NSString)

        let appVersion: @convention(block) (String) -> String = { id in
            return host.pluginAppVersion(pluginId: id)
        }
        hostObject.setObject(appVersion as AnyObject, forKeyedSubscript: "appVersion" as NSString)

        let pluginDirectory: @convention(block) (String) -> String = { id in
            PluginStore.shared.directory(for: id).path
        }
        hostObject.setObject(pluginDirectory as AnyObject, forKeyedSubscript: "pluginDirectory" as NSString)

        let schedule: @convention(block) (String, Double, String) -> Void = { id, delay, token in
            host.pluginSchedule(pluginId: id, delayMilliseconds: delay, token: token)
        }
        hostObject.setObject(schedule as AnyObject, forKeyedSubscript: "schedulePlugin" as NSString)

        // Network and proxy. Each takes a callback token rather than returning a
        // value: the script queue must not block on a socket, and the answer is
        // delivered by `__extera.resolveBridge(token, json)` when it arrives.
        let httpGet: @convention(block) (String, String, String, Double, String) -> Void = { id, url, headersJSON, timeout, token in
            host.pluginHttpGet(pluginId: id, url: url, headersJSON: headersJSON, timeout: timeout, callbackToken: token)
        }
        hostObject.setObject(httpGet as AnyObject, forKeyedSubscript: "httpGet" as NSString)

        let proxyList: @convention(block) (String, String) -> Void = { id, token in
            host.pluginProxyList(pluginId: id, callbackToken: token)
        }
        hostObject.setObject(proxyList as AnyObject, forKeyedSubscript: "proxyList" as NSString)

        let proxyAdd: @convention(block) (String, String, String) -> Void = { id, linksJSON, token in
            host.pluginProxyAdd(pluginId: id, linksJSON: linksJSON, callbackToken: token)
        }
        hostObject.setObject(proxyAdd as AnyObject, forKeyedSubscript: "proxyAdd" as NSString)

        let proxyRemoveAll: @convention(block) (String, String) -> Void = { id, token in
            host.pluginProxyRemoveAll(pluginId: id, callbackToken: token)
        }
        hostObject.setObject(proxyRemoveAll as AnyObject, forKeyedSubscript: "proxyRemoveAll" as NSString)

        let ownPeerId: @convention(block) (String, Double, String) -> Void = { id, account, token in
            host.pluginOwnPeerId(pluginId: id, account: PluginLoader.accountValue(account), callbackToken: token)
        }
        hostObject.setObject(ownPeerId as AnyObject, forKeyedSubscript: "ownPeerId" as NSString)

        context.setObject(hostObject, forKeyedSubscript: "__host" as NSString)
    }

    /// The bridge carries `account` as a number; JavaScript has no integers, so
    /// an "unset" account arrives as NaN. `Int64` would trap on that, so the
    /// conversion is explicit and NaN means "selected account".
    private static func accountValue(_ value: Double) -> Int64? {
        guard value.isFinite else {
            return nil
        }
        return Int64(value)
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
