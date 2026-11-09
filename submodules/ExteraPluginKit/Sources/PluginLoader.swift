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
    /// Remember that the plugin wants a request/update/send hook. `priority` is
    /// exteraGram's `add_hook(..., priority=)` and
    /// `add_on_send_message_hook(priority=)`: higher runs earlier in the chain.
    /// The SDK does not document the tie-break, so equal priorities keep load
    /// order, which is what this runtime already guarantees.
    func pluginAddHook(pluginId: String, name: String, matchSubstring: Bool, priority: Int32)
    func pluginAddOnSendMessageHook(pluginId: String, priority: Int32)
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

    /// Reads another source file out of the plugin's own directory, for the
    /// multi-file loader.
    ///
    /// An Elyx project's entry module imports its siblings (`require('./src/x')`),
    /// and each of those may import more. Returning the text rather than
    /// evaluating it keeps the recursion in JavaScript, where the module cache,
    /// the cycle guard and the relative-path resolution already are.
    ///
    /// `path` is resolved relative to the plugin's directory; a path that
    /// escapes it returns nil, so one plugin cannot read another's files or the
    /// app's container through the loader.
    func pluginReadModule(pluginId: String, path: String) -> String?
    /// Opens another screen of the app's own settings, the target of a settings
    /// row that carries `link_alias`. `alias` is the SDK's screen name
    /// (`plugins`, `appearance`, ...), not a URL; the host maps it to the screen
    /// it has and does nothing for a name it does not.
    func pluginOpenSettingLink(pluginId: String, alias: String)
    /// Whether a path exists inside the plugin's directory, for the loader to
    /// try the extensions a bare `require` may leave off.
    func pluginModuleExists(pluginId: String, path: String) -> Bool

    /// Whether an Objective-C class with this name is loaded. Answers
    /// `hook_utils.find_class`, so a plugin gets null for a name this build does
    /// not have instead of a handle that fails later.
    func pluginClassExists(pluginId: String, className: String) -> Bool

    /// Builds a runtime subclass with the given methods, the iOS shape of
    /// DexMaker's `jclassbuilder`. `methodsJSON` is an array of
    /// `{"selector": "...", "token": "c1"}`. Returns the new class's name, or a
    /// reason string when the superclass is not loaded.
    func pluginBuildClass(pluginId: String, superclassName: String, methodsJSON: String, context: JSContext) -> String
    /// Instantiates a class `pluginBuildClass` made, or nil for any other name.
    func pluginMakeClassInstance(pluginId: String, className: String) -> AnyObject?

    /// Installs an Objective-C hook, the iOS shape of an Xposed hook.
    ///
    /// The plugin names a class and a selector; the host resolves them against
    /// the loaded runtime and swizzles the method, calling the plugin's `before`
    /// and `after`. Returns nil on success, or a reason string the plugin can
    /// log when the class or the method is not there. `beforeToken`/`afterToken`
    /// are the callback tokens `holdCallback` produced, and `context` is the
    /// plugin's own `JSContext`, which the hook re-enters on the script queue.
    func pluginInstallSwizzle(
        pluginId: String,
        className: String,
        selector: String,
        isClassMethod: Bool,
        beforeToken: String?,
        afterToken: String?,
        context: JSContext
    ) -> String?
    /// Removes one swizzle by class, selector and kind: the iOS shape of
    /// `unhook_method(unhook_obj)`. Returns true when a hook was installed for
    /// that pair, so hooking again after an unhook is a fresh install.
    func pluginRemoveSwizzle(pluginId: String, className: String, selector: String, isClassMethod: Bool) -> Bool

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
    /// A request with an explicit method and optional body, the form `http.post`,
    /// `http.put`, `http.delete` and the rest reach. `bodyBase64` is the request
    /// body already encoded, because the bridge carries text and an upload may
    /// not be UTF-8. Answers the same shape as `pluginHttpGet`.
    func pluginHttpRequest(pluginId: String, method: String, url: String, headersJSON: String, bodyBase64: String?, timeout: Double, callbackToken: String)
    /// The proxy list as `{"ok": true, "servers": [{"link": "tg://...", "kind": "mtproto|web|socks", "host": "...", "port": 443}]}`.
    func pluginProxyList(pluginId: String, callbackToken: String)
    /// Adds every parseable link in `linksJSON`. Answers
    /// `{"ok": true, "added": 0, "duplicates": 0, "invalid": 0}`.
    func pluginProxyAdd(pluginId: String, linksJSON: String, callbackToken: String)
    /// Empties the list and turns proxying off. Answers `{"ok": true, "removed": 0}`.
    func pluginProxyRemoveAll(pluginId: String, callbackToken: String)
    /// Starts, stops or reports the in-app local MTProxy. Answers
    /// `{"ok": true, "status": {"running": true, "host": "127.0.0.1", "port": 1443, "domain": "...", "active": true}}`.
    func pluginLocalProxy(pluginId: String, requestJSON: String, callbackToken: String)
    /// The local proxy's status, synchronously, as the same JSON object.
    func pluginLocalProxyStatus(pluginId: String) -> String
    /// The id of the account's own user, which is also the Saved Messages peer.
    /// Answers `{"ok": true, "peer_id": 123}`.
    func pluginOwnPeerId(pluginId: String, account: Int64?, callbackToken: String)

    // Reads behind the `client_utils.get_*` controller proxies. A plugin that
    // was written against Android's `MessagesController`/`ContactsController`
    // calls these through our proxy objects instead; the answer is the same kind
    // of JSON the network bridges use.
    /// One peer's profile. Answers `{"ok": true, "peer": {...}}` or
    /// `{"ok": false, "error": "..."}`.
    func pluginPeerInfo(pluginId: String, account: Int64?, peerId: Int64, callbackToken: String)
    /// The most recent messages of one chat. Answers
    /// `{"ok": true, "messages": [...]}`.
    func pluginChatMessages(pluginId: String, account: Int64?, peerId: Int64, limit: Int, callbackToken: String)
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
    /// When the message should be sent, as unix seconds; the engine turns it
    /// into the scheduled-message attribute, so it lands in the "scheduled"
    /// list the composer shows.
    public let scheduleDate: Int32?
    /// exteraGram's `has_media_spoilers`: the media bubble arrives covered.
    /// Only the media send honours it; the engine's edit request has no
    /// attribute slot, so an edit cannot add a spoiler the message lacks.
    public let hasMediaSpoilers: Bool
    /// A media replacement for `edit_message`, from its `file_path` argument.
    /// A send ignores both of these.
    public let filePath: String?
    /// How `filePath` should be treated (`photo` decodes as an image bubble);
    /// nil means the edit is text-only.
    public let fileKind: String?

    public init(json: [String: Any]) {
        self.replyToMessageId = (json["replyToMsg"] as? NSNumber)?.int64Value
        self.silent = (json["notify"] as? Bool) == false
        self.caption = json["caption"] as? String
        self.parseMode = json["parse_mode"] as? String
        self.entitiesJSON = PluginSendOptions.jsonString(json["entities"])
        self.captionEntitiesJSON = PluginSendOptions.jsonString(json["caption_entities"])
        // Both spellings are accepted on purpose: the SDK's typed helpers take
        // snake_case keywords while `send_message`'s dict and a ported plugin's
        // own objects mix in camelCase.
        self.scheduleDate = (json["scheduleDate"] as? NSNumber)?.int32Value
            ?? (json["schedule_date"] as? NSNumber)?.int32Value
        self.hasMediaSpoilers = (json["hasMediaSpoilers"] as? Bool) == true
            || (json["has_media_spoilers"] as? Bool) == true
            || (json["with_spoiler"] as? Bool) == true
        self.filePath = json["file_path"] as? String ?? json["filePath"] as? String
        self.fileKind = json["file_kind"] as? String ?? json["fileKind"] as? String
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
            requirements: self.literalStringArray(in: source, named: "__requirements__") ?? [],
            categories: self.declaredCategories(in: source)
        )
    }

    /// The categories a plugin declares: `__category__` as a list literal, or as
    /// a single string a port may carry. Unknown names are dropped rather than
    /// rejected, and the manifest caps the list at three.
    private func declaredCategories(in source: String) -> [String] {
        let raw = self.literalStringArray(in: source, named: "__category__")
            ?? (self.literalString(in: source, named: "__category__").map { [$0] } ?? [])
        return raw.filter { PluginManifest.knownCategories.contains($0) }
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

        let addHook: @convention(block) (String, String, Bool, Double) -> Void = { id, name, matchSubstring, priority in
            host.pluginAddHook(pluginId: id, name: name, matchSubstring: matchSubstring, priority: Int32(priority))
        }
        hostObject.setObject(addHook as AnyObject, forKeyedSubscript: "addHook" as NSString)

        let addSendHook: @convention(block) (String, Double) -> Void = { id, priority in
            host.pluginAddOnSendMessageHook(pluginId: id, priority: Int32(priority))
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

        // Multi-file loading. The text is returned to JavaScript, which compiles
        // and caches it; the host only decides whether the path is inside the
        // plugin's own directory.
        let readModule: @convention(block) (String, String) -> String? = { id, path in
            host.pluginReadModule(pluginId: id, path: path)
        }
        hostObject.setObject(readModule as AnyObject, forKeyedSubscript: "readModule" as NSString)

        let moduleExists: @convention(block) (String, String) -> Bool = { id, path in
            host.pluginModuleExists(pluginId: id, path: path)
        }
        hostObject.setObject(moduleExists as AnyObject, forKeyedSubscript: "moduleExists" as NSString)

        // The plugin's own directory, so `assets` and `strings` can be resolved
        // relative to the entry module before the loader knows the layout.
        let moduleDirectory: @convention(block) (String) -> String = { id in
            PluginStore.shared.directory(for: id).path
        }
        hostObject.setObject(moduleDirectory as AnyObject, forKeyedSubscript: "moduleDirectory" as NSString)

        let openSettingLink: @convention(block) (String, String) -> Void = { id, alias in
            host.pluginOpenSettingLink(pluginId: id, alias: alias)
        }
        hostObject.setObject(openSettingLink as AnyObject, forKeyedSubscript: "openSettingLink" as NSString)

        // The Xposed-shaped hook. The plugin names a class and a selector; the
        // host swizzles the method and calls back into this same context through
        // `__extera.runSwizzleCallback`. The context is the one being set up, so
        // it is captured here rather than looked up later.
        let installSwizzle: @convention(block) (String, String, String, Bool, String?, String?) -> String? = { id, className, selector, isClassMethod, beforeToken, afterToken in
            host.pluginInstallSwizzle(
                pluginId: id,
                className: className,
                selector: selector,
                isClassMethod: isClassMethod,
                beforeToken: beforeToken,
                afterToken: afterToken,
                context: context
            )
        }
        hostObject.setObject(installSwizzle as AnyObject, forKeyedSubscript: "installSwizzle" as NSString)

        let classExists: @convention(block) (String, String) -> Bool = { _, name in
            return NSClassFromString(name) != nil
        }
        hostObject.setObject(classExists as AnyObject, forKeyedSubscript: "classExists" as NSString)

        // The reverse of `installSwizzle`, for `unhook_method`: removing the
        // pair makes a later hook for it a fresh install again.
        let removeSwizzle: @convention(block) (String, String, String, Bool) -> Bool = { id, className, selector, isClassMethod in
            return host.pluginRemoveSwizzle(pluginId: id, className: className, selector: selector, isClassMethod: isClassMethod)
        }
        hostObject.setObject(removeSwizzle as AnyObject, forKeyedSubscript: "removeSwizzle" as NSString)

        // Runtime class construction, the iOS shape of DexMaker. The plugin
        // describes the methods in JSON; the host allocates the subclass, adds a
        // block per method, registers it, and hands back the generated name. It
        // returns a class name on success or a `"!"`-prefixed reason on failure,
        // because the bridge carries one string and a plugin wants to log why
        // rather than catch across the boundary.
        let buildClass: @convention(block) (String, String, String) -> String = { id, superclassName, methodsJSON in
            host.pluginBuildClass(
                pluginId: id,
                superclassName: superclassName,
                methodsJSON: methodsJSON,
                context: context
            )
        }
        hostObject.setObject(buildClass as AnyObject, forKeyedSubscript: "buildClass" as NSString)

        let makeInstanceClass: @convention(block) (String, String) -> AnyObject? = { id, className in
            return host.pluginMakeClassInstance(pluginId: id, className: className)
        }
        hostObject.setObject(makeInstanceClass as AnyObject, forKeyedSubscript: "makeInstanceClass" as NSString)

        // Network and proxy. Each takes a callback token rather than returning a
        // value: the script queue must not block on a socket, and the answer is
        // delivered by `__extera.resolveBridge(token, json)` when it arrives.
        let httpGet: @convention(block) (String, String, String, Double, String) -> Void = { id, url, headersJSON, timeout, token in
            host.pluginHttpGet(pluginId: id, url: url, headersJSON: headersJSON, timeout: timeout, callbackToken: token)
        }
        hostObject.setObject(httpGet as AnyObject, forKeyedSubscript: "httpGet" as NSString)

        let httpRequest: @convention(block) (String, String, String, String, String?, Double, String) -> Void = { id, method, url, headersJSON, bodyBase64, timeout, token in
            host.pluginHttpRequest(pluginId: id, method: method, url: url, headersJSON: headersJSON, bodyBase64: bodyBase64, timeout: timeout, callbackToken: token)
        }
        hostObject.setObject(httpRequest as AnyObject, forKeyedSubscript: "httpRequest" as NSString)

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

        // The local MTProxy. `localProxy` answers through the bridge like the
        // other network calls; `localProxyStatus` is synchronous because it only
        // reads state the client already holds, which is what a settings row
        // being built right now needs.
        let localProxy: @convention(block) (String, String, String) -> Void = { id, requestJSON, token in
            host.pluginLocalProxy(pluginId: id, requestJSON: requestJSON, callbackToken: token)
        }
        hostObject.setObject(localProxy as AnyObject, forKeyedSubscript: "localProxy" as NSString)

        let localProxyStatus: @convention(block) (String) -> String = { id in
            return host.pluginLocalProxyStatus(pluginId: id)
        }
        hostObject.setObject(localProxyStatus as AnyObject, forKeyedSubscript: "localProxyStatus" as NSString)

        let ownPeerId: @convention(block) (String, Double, String) -> Void = { id, account, token in
            host.pluginOwnPeerId(pluginId: id, account: PluginLoader.accountValue(account), callbackToken: token)
        }
        hostObject.setObject(ownPeerId as AnyObject, forKeyedSubscript: "ownPeerId" as NSString)

        let peerInfo: @convention(block) (String, Double, Double, String) -> Void = { id, account, peerId, token in
            host.pluginPeerInfo(pluginId: id, account: PluginLoader.accountValue(account), peerId: Int64(peerId), callbackToken: token)
        }
        hostObject.setObject(peerInfo as AnyObject, forKeyedSubscript: "peerInfo" as NSString)

        let chatMessages: @convention(block) (String, Double, Double, Double, String) -> Void = { id, account, peerId, limit, token in
            host.pluginChatMessages(pluginId: id, account: PluginLoader.accountValue(account), peerId: Int64(peerId), limit: Int(limit), callbackToken: token)
        }
        hostObject.setObject(chatMessages as AnyObject, forKeyedSubscript: "chatMessages" as NSString)

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
