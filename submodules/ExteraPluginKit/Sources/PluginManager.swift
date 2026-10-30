import Foundation
import JavaScriptCore
import SwiftSignalKit

/// Owns every loaded plugin and dispatches hook traffic to them.
///
/// This is the piece that corresponds to exteraGram's plugin manager: it decides
/// what a plugin may intercept, keeps the registry, and turns the JS callbacks
/// into the `HookOutcome` values the Telegram integration acts on.
public final class PluginManager: PluginHost {
    public static let shared = PluginManager()

    private let store = PluginStore.shared
    private var loaded: [String: LoadedPlugin] = [:]
    private let lock = NSLock()

    /// Every call into plugin JavaScript runs here, and only here.
    ///
    /// `JSContext` is not thread-safe, while hooks arrive from the network
    /// queue, sends from whichever queue enqueued the message, and settings from
    /// the main queue. One serial queue keeps a plugin's script from running
    /// twice at once; the identity check makes a nested call (a plugin calling
    /// Swift which calls back into JS) run inline instead of deadlocking.
    private let jsQueue = DispatchQueue(label: "extera.pluginkit.js")
    private static let jsQueueKey = DispatchSpecificKey<UInt8>()
    private static let jsQueueToken: UInt8 = 1

    /// Menu items registered by plugins, keyed by item id.
    private var menuItems: [String: (pluginId: String, item: PluginMenuItem)] = [:]

    /// Hooks a plugin asked for while its script was still evaluating. A plugin
    /// may call `add_hook` at class-body level or in its constructor, not only
    /// from `on_plugin_load`, and at that point it is not in `loaded` yet.
    private var pendingHooks: [String: (requests: [String], substrings: [String], wantsSend: Bool)] = [:]

    /// Why a plugin on disk did not load, keyed by id. Kept so the list screen can
    /// say so instead of showing the plugin as merely disabled.
    private var failures: [String: String] = [:]

    /// Set by the app once the bridge can act on real accounts.
    public var actions: PluginActions?

    /// Called when a plugin's settings should be re-rendered.
    public var settingsChanged: ((String) -> Void)?

    /// Fires whenever the set of installed/loaded plugins changes, so open
    /// screens rebuild their rows. Every mutation goes through `reloadPlugins` or
    /// `setEnabled`, and both push here.
    private let changesPipe = ValuePipe<Void>()

    public var changes: Signal<Void, NoError> {
        return self.changesPipe.signal()
    }

    private func notifyChanged() {
        self.changesPipe.putNext(Void())
    }

    private init() {
        self.jsQueue.setSpecific(key: PluginManager.jsQueueKey, value: PluginManager.jsQueueToken)
    }

    /// True when the calling thread is already inside `jsQueue`.
    private var isOnJSQueue: Bool {
        return DispatchQueue.getSpecific(key: PluginManager.jsQueueKey) == PluginManager.jsQueueToken
    }

    /// Runs `body` on the script queue, inline when already there.
    private func withJSQueue<T>(_ body: () -> T) -> T {
        if self.isOnJSQueue {
            return body()
        }
        return self.jsQueue.sync(execute: body)
    }

    /// Like `withJSQueue` but never blocks the caller.
    ///
    /// Used for work that originates on the main thread and has no result the
    /// caller needs: a lifecycle event must not wait behind a slow plugin, and the
    /// main thread must never block on script evaluation.
    private func asyncOnJSQueue(_ body: @escaping () -> Void) {
        if self.isOnJSQueue {
            body()
        } else {
            self.jsQueue.async(execute: body)
        }
    }

    public private(set) var pluginSource: String?

    /// Sets the bootstrap script the loader evaluates in each context. Must be
    /// called before `startLoading`; the app passes the bundled `bootstrap.js`.
    public func configure(bootstrapSource: String) {
        self.pluginSource = bootstrapSource
    }

    // MARK: - Loading

    /// Loads every plugin and then delivers the start event, all on the script
    /// queue and without blocking the caller.
    ///
    /// Launch uses this rather than `loadAll()`: plugin code is arbitrary, and
    /// `loadAll()` called from the main queue would evaluate every script on the
    /// main thread while the first frame is still being built. Nothing else
    /// needs to wait for the load, because no hook fires before the app is up.
    public func startLoading(startEvent: String?) {
        self.jsQueue.async { [weak self] in
            guard let self = self else {
                return
            }
            self.loadAllOnQueue()
            if let startEvent = startEvent {
                // Already on the script queue, so this runs inline instead of
                // deadlocking against the queue it is being called from.
                self.broadcastAppEvent(startEvent)
            }
        }
    }

    /// The app version a plugin's `__app_version__` is compared against.
    ///
    /// Read from the bundle rather than passed in, so the manager needs no
    /// TelegramCore dependency and the value is always the running build.
    private var bundleAppVersion: String {
        return (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
    }

    /// The exteraGram SDK level this runtime claims.
    ///
    /// exteraGram's own latest is 1.4.5.0; the surface here covers everything
    /// the 1.4.4.3 docs describe except the Android-only parts (Xposed hooks,
    /// Java class proxies, Android intents), and 1.4.5.0 only adds the
    /// `account=` helpers plus `AccountClient`, which are implemented. So a
    /// plugin that gates a feature on `__sdk_version__` gets the true answer.
    static let supportedSDKVersion = "1.4.5.0"

    private func loadAllOnQueue() {
        guard let bootstrapSource = self.pluginSource else {
            return
        }
        let loader = PluginLoader(bootstrapSource: bootstrapSource, host: self)
        let appVersion = self.bundleAppVersion

        var prepared: [LoadedPlugin] = []
        self.lock.lock()
        self.failures.removeAll()
        self.lock.unlock()
        for (fallbackId, url) in self.store.pluginSources() {
            // Tracked so a failure is filed under the id the manifest declared,
            // which is what the list screen matches rows against; before the
            // manifest is read only the file name is known.
            var reportedId = fallbackId
            do {
                guard let source = try? String(contentsOf: url, encoding: .utf8) else {
                    continue
                }
                let manifest = try loader.readManifest(from: source, fallbackId: fallbackId)
                reportedId = manifest.id
                // The settings screen stores the switch against the declared id,
                // while a bundle-style plugin's folder may be named differently.
                // Checking the declared id here keeps a disabled plugin disabled.
                guard self.store.isEnabled(manifest.id) else {
                    continue
                }
                // Gate before evaluating anything: a plugin written for a newer
                // app may call API this build does not have, and its top-level
                // code must not run just to find that out.
                if let requirement = manifest.appVersionRequirement,
                   !pluginVersionRequirementIsSatisfied(requirement, actual: appVersion) {
                    throw PluginError.unsupportedVersion(required: requirement, actual: appVersion)
                }
                // `__sdk_version__` gates the *plugin API*, not the app version.
                // A plugin written for a newer SDK may call something this
                // runtime does not implement, and its top-level code must not
                // run just to find that out.
                if let requirement = manifest.sdkVersionRequirement,
                   !pluginVersionRequirementIsSatisfied(requirement, actual: PluginManager.supportedSDKVersion) {
                    throw PluginError.unsupportedSDKVersion(required: requirement, actual: PluginManager.supportedSDKVersion)
                }
                // `__requirements__` names Python packages. They cannot be
                // installed, but a plugin often lists one it no longer uses, so a
                // declared package is a warning in the log rather than a refusal:
                // a plugin that truly needs it fails visibly when it runs.
                if !manifest.requirements.isEmpty {
                    self.pluginLog(pluginId: manifest.id, text: "ignoring __requirements__ (Python packages): \(manifest.requirements.joined(separator: ", "))")
                }
                let plugin = try loader.load(source: source, manifest: manifest, directory: self.store.directory(for: manifest.id))
                self.attachCallbacks(plugin)
                prepared.append(plugin)
            } catch {
                // A broken plugin must not stop the others from loading.
                self.pluginLog(pluginId: reportedId, text: "load failed: \(error)")
                self.lock.lock()
                self.failures[reportedId] = "\(error)"
                self.lock.unlock()
            }
        }

        for (index, plugin) in prepared.enumerated() {
            plugin.loadIndex = index
            self.lock.lock()
            self.loaded[plugin.manifest.id] = plugin
            if let pending = self.pendingHooks.removeValue(forKey: plugin.manifest.id) {
                plugin.registeredRequestHooks = pending.requests
                plugin.registeredSubstringHooks = pending.substrings
                plugin.wantsSendMessageHook = pending.wantsSend
            }
            self.lock.unlock()
            self.callLifecycle(plugin, "on_plugin_load")
        }
    }

    private func unloadAllOnQueue() {
        self.lock.lock()
        let plugins = Array(self.loaded.values)
        self.lock.unlock()

        // Plugin code runs outside the lock: `on_plugin_unload` may call back
        // into the manager, and a recursive lock from inside NSLock would hang.
        for plugin in plugins {
            self.callLifecycle(plugin, "on_plugin_unload")
        }

        self.lock.lock()
        self.loaded.removeAll()
        self.menuItems.removeAll()
        self.lock.unlock()
    }

    public var loadedPlugins: [LoadedPlugin] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.loaded.values.sorted { $0.manifest.name < $1.manifest.name }
    }

    private func plugin(id: String) -> LoadedPlugin? {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.loaded[id]
    }

    /// Runs a lifecycle method through the bootstrap, which owns the instance and
    /// therefore the correct `this`. Exceptions are logged and swallowed: a
    /// plugin bug must degrade the feature, not crash the app.
    private func callLifecycle(_ plugin: LoadedPlugin, _ name: String, context: [String: Any] = [:]) {
        _ = self.callJS(
            plugin: plugin,
            function: "__extera.callLifecycleJSON",
            arguments: [name, self.jsonString(context)]
        )
    }

    private func attachCallbacks(_ plugin: LoadedPlugin) {
        // Keep the JSContext from being deallocated while the plugin is loaded.
        // The id is captured instead of the plugin, because the context owns the
        // handler: capturing the plugin would make context -> handler -> plugin ->
        // context a cycle that outlives unloading.
        let pluginId = plugin.manifest.id
        plugin.context.exceptionHandler = { [weak self] _, exception in
            let text = exception?.toString() ?? "unknown"
            self?.pluginLog(pluginId: pluginId, text: "plugin exception: \(text)")
        }
    }

    // MARK: - Hooks

    /// Mirror of exteraGram's `pre_request_hook`. Called before a TL request is
    /// sent; a plugin may let it through, cancel it, or supply a replacement.
    public func dispatchPreRequest(name: String, account: Int64, request: inout [String: Any]) -> HookOutcome {
        return self.dispatch(pluginEvent: "pre_request_hook", hookName: name, account: account, payload: &request)
    }

    /// Mirror of `post_request_hook`.
    ///
    /// `post_request_hook` is observational in this runtime: nothing it returns
    /// reaches the caller. Running a plugin's script inline would stall the
    /// engine's completion queue for as long as that script takes, so the work is
    /// handed to the script queue instead, exactly like update delivery.
    public func dispatchPostRequest(name: String, account: Int64, responseJSON: String, error: [String: Any]?) {
        self.jsQueue.async { [weak self] in
            guard let self = self else {
                return
            }
            var payload = self.parseJSONObject(responseJSON) ?? [:]
            _ = self.dispatch(pluginEvent: "post_request_hook", hookName: name, account: account, payload: &payload, error: error)
        }
    }

    /// Dispatches an update without blocking the caller.
    ///
    /// Updates arrive on the account state's network queue, at a far higher rate
    /// than requests, and plugin JavaScript must never stall it. The hook is
    /// observational anyway: nothing a plugin returns can change the update.
    public func dispatchUpdateDetached(name: String, account: Int64, json: String, isContainer: Bool) {
        self.jsQueue.async { [weak self] in
            guard let self = self else {
                return
            }
            let pluginEvent = isContainer ? "on_updates_hook" : "on_update_hook"
            var payload = self.parseJSONObject(json) ?? [:]
            _ = self.dispatch(pluginEvent: pluginEvent, hookName: name, account: account, payload: &payload)
        }
    }

    /// Whether a plugin listens for this update constructor. `*` matches every
    /// one, as in exteraGram.
    public func hasUpdateHook(name: String) -> Bool {
        return self.hasRequestHook(name: name)
    }

    /// Mirror of `on_send_message_hook`. Runs for every plugin that asked for it.
    public func dispatchSendMessage(account: Int64, params: inout [String: Any]) -> HookOutcome {
        return self.dispatch(pluginEvent: "on_send_message_hook", hookName: "send", account: account, payload: &params)
    }

    /// Whether any plugin wants the send hook. The caller checks this before
    /// building the payload, so an app with nothing installed pays one lock.
    public var hasSendMessageHook: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.loaded.values.contains { $0.wantsSendMessageHook }
    }

    /// Whether a plugin subscribed to this name, either exactly or, when it
    /// registered with `match_substring`, because the name contains its pattern.
    ///
    /// exteraGram's `add_hook(name, match_substring=True)` exists so one
    /// registration can cover a request family (`messages.`). `*` still means
    /// everything, as it does there.
    ///
    /// Names are matched in both spellings. exteraGram registers hooks by TL
    /// constructor (`TL_messages_setTyping`, `TL_updateNewMessage`) and passes
    /// that spelling to the callback, while TelegramCore reports the dotted one
    /// (`messages.setTyping`). A plugin ported from Android would otherwise
    /// register a hook that never fires, which is the worst failure mode: it
    /// looks like it works.
    private static func pluginWants(_ plugin: LoadedPlugin, hookName: String) -> Bool {
        let candidates = PluginManager.hookNameCandidates(hookName)
        for candidate in candidates where plugin.registeredRequestHooks.contains(candidate) {
            return true
        }
        if plugin.registeredRequestHooks.contains("*") {
            return true
        }
        for pattern in plugin.registeredSubstringHooks {
            if pattern == "*" {
                return true
            }
            for candidate in candidates where candidate.contains(pattern) {
                return true
            }
        }
        return false
    }

    /// The dotted name plus its `TL_` spelling, so either registration matches.
    static func hookNameCandidates(_ name: String) -> [String] {
        if name == "*" {
            return ["*"]
        }
        var result = [name]
        if name.hasPrefix("TL_") {
            let stripped = String(name.dropFirst(3))
            if !result.contains(stripped) {
                result.append(stripped)
            }
            // The dotted form of a TL name is not a plain substitution — an
            // update (`TL_updateNewMessage`) has no namespace — so the first
            // separator is the only one that can become a dot.
            if let separator = stripped.range(of: "_") {
                let dotted = stripped.replacingCharacters(in: separator, with: ".")
                if !result.contains(dotted) {
                    result.append(dotted)
                }
            }
        } else {
            let prefixed = "TL_" + name.replacingOccurrences(of: ".", with: "_")
            if !result.contains(prefixed) {
                result.append(prefixed)
            }
        }
        return result
    }

    /// What a plugin's hook receives: exteraGram spells these with the `TL_`
    /// prefix (`TL_messages_setTyping`, `TL_updateNewMessage`).
    static func tlHookName(_ name: String) -> String {
        if name.hasPrefix("TL_") {
            return name
        }
        return "TL_" + name.replacingOccurrences(of: ".", with: "_")
    }

    /// Whether a specific request name has a listener. `*` matches everything, as
    /// in exteraGram, so a plugin that wants every request still gets called.
    public func hasRequestHook(name: String) -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.loaded.values.contains { PluginManager.pluginWants($0, hookName: name) }
    }

    /// Runs one plugin event across every interested plugin, in load order.
    ///
    /// The first `cancel` stops the chain, matching exteraGram. `modify` replaces
    /// the payload for the plugins after it and for the caller; `modify_final`
    /// also stops the chain.
    private func dispatch(pluginEvent: String, hookName: String, account: Int64, payload: inout [String: Any], error: [String: Any]? = nil) -> HookOutcome {
        self.lock.lock()
        let plugins = self.loaded.values.filter { plugin in
            if pluginEvent == "on_send_message_hook" {
                return plugin.wantsSendMessageHook
            }
            return PluginManager.pluginWants(plugin, hookName: hookName)
        }.sorted { $0.loadIndex < $1.loadIndex }
        self.lock.unlock()

        let field: String
        switch pluginEvent {
        case "pre_request_hook":
            field = "request"
        case "post_request_hook":
            field = "response"
        case "on_send_message_hook":
            field = "params"
        case "on_updates_hook":
            field = "updates"
        default:
            field = "update"
        }

        for plugin in plugins {
            // Everything crosses the bridge as a JSON string: JS objects and
            // block callbacks are not marshalled, so the only failure mode is a
            // malformed document, which is caught and logged below.
            var context: [String: Any] = [
                "name": hookName,
                "tlName": PluginManager.tlHookName(hookName),
                "account": account,
                "field": field
            ]
            if let error = error {
                context["error"] = error
            }
            guard let resultJSON = self.callJS(
                plugin: plugin,
                function: "__extera.runHook",
                arguments: [pluginEvent, self.jsonString(payload), self.jsonString(context)]
            ) else {
                continue
            }
            guard let dictionary = self.parseJSONObject(resultJSON) else {
                continue
            }
            let strategy = (dictionary["strategy"] as? String) ?? "default"
            if let modified = dictionary["payload"] as? [String: Any] {
                payload = modified
            }
            switch strategy {
            case "cancel":
                return .cancel(pluginId: plugin.manifest.id)
            case "modify_final":
                return .modifyFinal(pluginId: plugin.manifest.id, payload: payload)
            default:
                continue
            }
        }
        return .passthrough(payload)
    }

    /// Calls `function` on the plugin's context with string arguments and returns
    /// the string result, or nil when the function threw or is absent.
    ///
    /// Every cross-bridge argument is serialized with `JSON.stringify`, so no JS
    /// value is retained past the call and a plugin cannot hold a Swift object.
    ///
    /// Always script-queue serialized: hooks arrive on the network queue and
    /// settings on the main queue, and `JSContext` tolerates neither concurrency
    /// nor a `JSValue` escaping its thread. Host callbacks reachable from a plugin
    /// (`__host.*`) therefore must never block on the main queue, or a plugin that
    /// asks the UI for something would deadlock against this sync.
    private func callJS(plugin: LoadedPlugin, function: String, arguments: [String]) -> String? {
        return self.withJSQueue {
            self.callJSOnQueue(plugin: plugin, function: function, arguments: arguments)
        }
    }

    private func callJSOnQueue(plugin: LoadedPlugin, function: String, arguments: [String]) -> String? {
        let context = plugin.context
        guard let target = context.objectForKeyedSubscript("__extera")?.objectForKeyedSubscript(String(function.dropFirst("__extera.".count))),
              !target.isUndefined else {
            return nil
        }
        var previousException: JSValue?
        var threw = false
        let previousHandler = context.exceptionHandler
        context.exceptionHandler = { _, exception in
            threw = true
            previousException = exception
        }
        defer { context.exceptionHandler = previousHandler }
        let values: [Any] = arguments.map { $0 as NSString }
        let result = target.call(withArguments: values)
        if threw {
            let text = previousException?.toString() ?? "unknown"
            self.pluginLog(pluginId: plugin.manifest.id, text: "\(function) threw: \(text)")
            return nil
        }
        guard let result = result, !result.isUndefined, !result.isNull else {
            return nil
        }
        return result.toString()
    }

    private func jsonString(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    private func parseJSONObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    // MARK: - PluginHost

    public func pluginLog(pluginId: String, text: String) {
        PluginLog.write(pluginId: pluginId, text: text)
    }

    public func pluginSettings(pluginId: String) -> [String: Any] {
        return self.store.settings(for: pluginId)
    }

    public func pluginSetSetting(pluginId: String, key: String, value: Any?, reload: Bool) {
        self.store.setSetting(key, value: value, for: pluginId)
        if reload {
            self.settingsChanged?(pluginId)
        }
    }

    public func pluginAddHook(pluginId: String, name: String, matchSubstring: Bool) {
        self.lock.lock()
        if let plugin = self.loaded[pluginId] {
            // `add_hook` may run in the constructor and again in
            // `on_plugin_load`; a duplicate would make the hook fire twice.
            if matchSubstring {
                if !plugin.registeredSubstringHooks.contains(name) {
                    plugin.registeredSubstringHooks.append(name)
                }
            } else if !plugin.registeredRequestHooks.contains(name) {
                plugin.registeredRequestHooks.append(name)
            }
        } else {
            var pending = self.pendingHooks[pluginId] ?? (requests: [], substrings: [], wantsSend: false)
            if matchSubstring {
                if !pending.substrings.contains(name) {
                    pending.substrings.append(name)
                }
            } else if !pending.requests.contains(name) {
                pending.requests.append(name)
            }
            self.pendingHooks[pluginId] = pending
        }
        self.lock.unlock()
    }

    public func pluginAddOnSendMessageHook(pluginId: String) {
        self.lock.lock()
        if let plugin = self.loaded[pluginId] {
            plugin.wantsSendMessageHook = true
        } else {
            var pending = self.pendingHooks[pluginId] ?? (requests: [], substrings: [], wantsSend: false)
            pending.wantsSend = true
            self.pendingHooks[pluginId] = pending
        }
        self.lock.unlock()
    }

    public func pluginAddMenuItem(pluginId: String, item: PluginMenuItem) {
        self.lock.lock()
        self.menuItems[item.itemId] = (pluginId, item)
        self.lock.unlock()
    }

    public func pluginRemoveMenuItem(pluginId: String, itemId: String) {
        self.lock.lock()
        self.menuItems.removeValue(forKey: itemId)
        self.lock.unlock()
    }

    public func pluginSendText(pluginId: String, account: Int64?, peerId: Int64, text: String, options: PluginSendOptions) {
        self.actions?.sendText(account: account, peerId: peerId, text: text, options: options)
    }

    public func pluginSendFile(pluginId: String, account: Int64?, kind: String, peerId: Int64, path: String, options: PluginSendOptions) {
        self.actions?.sendFile(account: account, kind: kind, peerId: peerId, path: path, options: options)
    }

    public func pluginEditMessage(pluginId: String, account: Int64?, peerId: Int64, messageId: Int64, text: String, options: PluginSendOptions) {
        self.actions?.editMessage(account: account, peerId: peerId, messageId: messageId, text: text, options: options)
    }

    public func pluginShowBulletin(pluginId: String, kind: String, json: String) {
        self.actions?.showBulletin(pluginId: pluginId, kind: kind, json: json)
    }

    public func pluginShowAlert(pluginId: String, json: String) {
        self.actions?.showAlert(pluginId: pluginId, json: json)
    }

    public func pluginDismissAlert(pluginId: String) {
        self.actions?.dismissAlert(pluginId: pluginId)
    }

    public func pluginFileOperation(pluginId: String, op: String, path: String, payload: String?) -> String? {
        return PluginFileAccess.perform(pluginId: pluginId, op: op, path: path, payload: payload)
    }

    public func pluginSelectedAccount(pluginId: String) -> Int64? {
        return self.actions?.selectedAccountId()
    }

    public func pluginCopyToClipboard(pluginId: String, text: String) {
        self.actions?.copyToClipboard(pluginId: pluginId, text: text)
    }

    public func pluginSchedule(pluginId: String, delayMilliseconds: Double, token: String) {
        // The plugin stored its callback under `token`; the host keeps only the
        // token, so the delayed work has to come back through `runScheduled`.
        // Everything runs on the main queue and `callJS` is main-queue only, so
        // a zero delay is dispatched rather than called inline: `run_on_queue` in
        // exteraGram never runs the block before the call that scheduled it
        // returns.
        let run: () -> Void = { [weak self] in
            guard let self = self, let plugin = self.plugin(id: pluginId) else {
                // The plugin was unloaded or reloaded while the timer was pending;
                // its registered callback went away with the old context.
                return
            }
            _ = self.callJS(plugin: plugin, function: "__extera.runScheduled", arguments: [token])
        }
        let delay = max(0.0, delayMilliseconds) / 1000.0
        if delay <= 0.0 {
            DispatchQueue.main.async(execute: run)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: run)
        }
    }

    // MARK: - Plugin-visible callbacks

    /// Runs a callback the plugin stored under `token`.
    ///
    /// Bulletin buttons and alert buttons take a function, which cannot cross the
    /// bridge; the bootstrap keeps the function and hands the host a token. This
    /// is called from the main queue when the user taps, and synchronizes onto the
    /// script queue to run it.
    public func runPluginCallback(pluginId: String, token: String) {
        guard let plugin = self.plugin(id: pluginId) else {
            return
        }
        _ = self.callJS(plugin: plugin, function: "__extera.runCallback", arguments: [token, "[]"])
    }

    /// Tells every loaded plugin which account the UI has selected.
    ///
    /// `get_selected_account()` is a hot path — a plugin may call it on every
    /// update — so the value lives in JS and is refreshed when it changes rather
    /// than resolved through the bridge each time.
    public func updateSelectedAccount(_ account: Int64) {
        self.asyncOnJSQueue { [weak self] in
            guard let self = self else {
                return
            }
            for plugin in self.loadedPlugins {
                _ = self.callJS(plugin: plugin, function: "__extera.setSelectedAccount", arguments: [String(account)])
            }
        }
    }

    /// Menu items that apply to one menu, most important first.
    public func menuItems(for menuType: String) -> [(pluginId: String, item: PluginMenuItem)] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.menuItems.values
            .filter { $0.item.menuType == menuType }
            .sorted { $0.item.priority > $1.item.priority }
            .map { ($0.pluginId, $0.item) }
    }

    /// One menu item as the UI shows it.
    public struct MenuItemDescription {
        public let pluginId: String
        public let itemId: String
        public let text: String
        public let subtext: String?
        public let icon: String?
    }

    /// Asks every plugin with a `menuType` item which of them are visible right
    /// now, most important first.
    ///
    /// exteraGram evaluates an item's `condition` in Python when the menu opens;
    /// here the condition is a JavaScript function, so the host cannot answer from
    /// its own registry and has to ask the plugin. `context` is what the menu knows
    /// about the tapped message, encoded as strings only.
    public func visibleMenuItems(menuType: String, context: [String: Any]) -> [MenuItemDescription] {
        // Only plugins that registered an item for this menu are asked. Building
        // the menu runs on the main thread, and a synchronous trip into the
        // script queue per plugin would make opening it cost one JS call per
        // installed plugin, most of which have nothing to show here.
        self.lock.lock()
        let interested = Set(self.menuItems.values.filter { $0.item.menuType == menuType }.map { $0.pluginId })
        self.lock.unlock()
        guard !interested.isEmpty else {
            return []
        }

        let contextJSON = self.jsonString(context)
        var result: [(priority: Int, description: MenuItemDescription)] = []

        for plugin in self.loadedPlugins where interested.contains(plugin.manifest.id) {
            guard let json = self.callJS(plugin: plugin, function: "__extera.collectMenuItems", arguments: [menuType, contextJSON]),
                  let data = json.data(using: .utf8),
                  let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                continue
            }
            for object in list {
                guard let itemId = object["item_id"] as? String,
                      let text = object["text"] as? String else {
                    continue
                }
                result.append((
                    (object["priority"] as? NSNumber)?.intValue ?? 0,
                    MenuItemDescription(
                        pluginId: plugin.manifest.id,
                        itemId: itemId,
                        text: text,
                        subtext: object["subtext"] as? String,
                        icon: object["icon"] as? String
                    )
                ))
            }
        }
        return result.sorted { $0.priority > $1.priority }.map { $0.description }
    }

    /// Runs the click handler of a menu item. The item may have been removed or
    /// its plugin unloaded between the menu opening and the tap, so a missing
    /// plugin is a no-op rather than an error.
    public func performMenuItem(pluginId: String, itemId: String, context: [String: Any]) {
        guard let plugin = self.plugin(id: pluginId) else {
            return
        }
        _ = self.callJS(
            plugin: plugin,
            function: "__extera.runMenuItem",
            arguments: [itemId, self.jsonString(context)]
        )
    }

    // MARK: - Settings screen support

    /// One installed plugin as the list screen shows it. Covers plugins that are
    /// on disk but failed to load, so a broken plugin is still visible (and
    /// removable) rather than silently missing.
    ///
    /// `Equatable` because a list entry holds one and `ItemListNodeEntry` compares
    /// entries on every state emission to decide whether a row changed.
    public struct PluginSummary: Equatable {
        public let id: String
        public let name: String
        public let description: String
        public let author: String
        public let version: String
        public let isEnabled: Bool
        public let isLoaded: Bool
        public let loadError: String?
    }

    /// Every plugin on disk, loaded or not, sorted by name.
    public func installedPlugins() -> [PluginSummary] {
        let loader: PluginLoader? = self.pluginSource.map { PluginLoader(bootstrapSource: $0, host: self) }
        var result: [PluginSummary] = []

        self.lock.lock()
        let loadedSnapshot = self.loaded
        let failures = self.failures
        self.lock.unlock()

        for (fallbackId, url) in self.store.pluginSources() {
            guard let source = try? String(contentsOf: url, encoding: .utf8) else {
                continue
            }
            let manifest = (try? loader?.readManifest(from: source, fallbackId: fallbackId)) ?? PluginManifest(id: fallbackId, name: fallbackId)
            let loaded = loadedSnapshot[manifest.id]
            let failure = failures[manifest.id]
            result.append(PluginSummary(
                id: manifest.id,
                name: manifest.name,
                description: manifest.description,
                author: manifest.author,
                version: manifest.version,
                isEnabled: self.store.isEnabled(manifest.id),
                isLoaded: loaded != nil,
                loadError: failure
            ))
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The manifest of a plugin, whether or not it loaded successfully.
    public func manifest(for pluginId: String) -> PluginManifest? {
        self.lock.lock()
        let loaded = self.loaded[pluginId]
        self.lock.unlock()
        if let loaded = loaded {
            return loaded.manifest
        }
        guard let source = self.pluginSource else {
            return nil
        }
        for (fallbackId, url) in self.store.pluginSources() where fallbackId == pluginId || url.lastPathComponent.hasPrefix(pluginId) {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                continue
            }
            return try? PluginLoader(bootstrapSource: source, host: self).readManifest(from: text, fallbackId: fallbackId)
        }
        return nil
    }

    /// What an install produced: enough to confirm the result to the user without
    /// re-reading the file from disk.
    public struct PluginInstallOutcome: Equatable {
        public let id: String
        public let name: String

        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    /// Validates a plugin file the user picked and stores it, then reloads.
    ///
    /// Validation and copying happen in one place so every install path gets the
    /// same checks: the bytes must be UTF-8 text, the manifest must declare a
    /// usable id and a name, and the `__app_version__` gate must pass. A file
    /// that fails any of them is never written to disk, so a rejected plugin
    /// cannot end up half-installed.
    ///
    /// A plugin that is already installed under the same `__id__` is replaced;
    /// that is what "install" means when someone re-picks an updated build.
    public func installPlugin(data: Data, fallbackId: String) throws -> PluginInstallOutcome {
        // A plugin is source text, and the picker lets the user choose any text
        // file. No genuine plugin is anywhere near this size, so refusing the
        // outliers keeps the manifest scan bounded.
        guard data.count <= 4 * 1024 * 1024 else {
            throw PluginError.tooLarge
        }
        guard let source = String(data: data, encoding: .utf8) else {
            throw PluginError.notTextFile
        }
        guard let bootstrapSource = self.pluginSource else {
            throw PluginError.runtimeUnavailable
        }

        // The id is derived from the file name only when the plugin has no
        // `__id__`, and a file name may contain spaces or non-ASCII characters
        // that the identifier rule rejects. Normalising first means such a
        // plugin installs instead of failing with a confusing id error. The
        // identifier rule caps the length at 32, so a long file name is cut.
        let sanitized = String(fallbackId.prefix(32).map { character -> Character in
            if character.isLetter || character.isNumber || character == "_" || character == "-" {
                return character
            }
            return "-"
        })
        let manifest = try PluginLoader(bootstrapSource: bootstrapSource, host: self).readManifest(
            from: source,
            fallbackId: sanitized.isEmpty ? "plugin" : sanitized
        )

        let appVersion = self.bundleAppVersion
        if let requirement = manifest.appVersionRequirement,
           !pluginVersionRequirementIsSatisfied(requirement, actual: appVersion) {
            throw PluginError.unsupportedVersion(required: requirement, actual: appVersion)
        }
        if let requirement = manifest.sdkVersionRequirement,
           !pluginVersionRequirementIsSatisfied(requirement, actual: PluginManager.supportedSDKVersion) {
            throw PluginError.unsupportedSDKVersion(required: requirement, actual: PluginManager.supportedSDKVersion)
        }

        try self.store.install(data: data, pluginId: manifest.id)
        self.pluginLog(pluginId: manifest.id, text: "installed \(manifest.name) v\(manifest.version)")
        self.reloadPlugins()
        return PluginInstallOutcome(id: manifest.id, name: manifest.name)
    }

    /// Reloads every plugin. Used after installing, toggling or removing one.
    ///
    /// Runs off the main thread: re-evaluating every script does not belong on
    /// the thread that draws, and nothing on screen needs the result immediately.
    /// The change notification is pushed afterwards, so a list that is open
    /// rebuilds once the reload has actually happened.
    public func reloadPlugins() {
        self.asyncOnJSQueue { [weak self] in
            guard let self = self else {
                return
            }
            self.unloadAllOnQueue()
            self.loadAllOnQueue()
            self.notifyChanged()
        }
    }

    /// One row a plugin's `create_settings()` produced, as the renderer needs it.
    public struct SettingsControl {
        public let type: String
        public let key: String?
        public let text: String?
        public let subtext: String?
        public let hint: String?
        public let icon: String?
        public let value: Any?
        public let items: [String]
        public let multiline: Bool
        public let maxLength: Int
        public let accent: Bool
        public let red: Bool
        public let hasCallbacks: Bool
        /// A `Text`/`Custom` row with `on_click`, so it has to be tappable.
        public let hasClick: Bool
        public let hasLongClick: Bool
        /// The row opens another settings page built by `create_sub_fragment`.
        public let hasSubFragment: Bool
    }

    /// Asks the plugin for its settings list. Called on the main queue when the
    /// screen is built, so the values are current at that moment.
    public func settings(for pluginId: String) -> [SettingsControl] {
        guard let plugin = self.plugin(id: pluginId) else {
            return []
        }
        guard let json = self.callJS(plugin: plugin, function: "__extera.collectSettings", arguments: []),
              let data = json.data(using: .utf8),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return list.compactMap { object in
            PluginManager.settingsControl(from: object)
        }
    }

    /// The controls of a nested settings page, built by the `create_sub_fragment`
    /// of the row whose key is `parentKey`.
    public func subSettings(for pluginId: String, parentKey: String) -> [SettingsControl] {
        guard let plugin = self.plugin(id: pluginId) else {
            return []
        }
        guard let json = self.callJS(plugin: plugin, function: "__extera.collectSubSettings", arguments: [parentKey]),
              let data = json.data(using: .utf8),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return list.compactMap { object in
            PluginManager.settingsControl(from: object)
        }
    }

    /// One control out of the JSON the bootstrap produces. Shared by the top-level
    /// and the nested list so a row renders identically on both.
    private static func settingsControl(from object: [String: Any]) -> SettingsControl? {
        guard let type = object["type"] as? String else {
            return nil
        }
        return SettingsControl(
            type: type,
            key: object["key"] as? String,
            text: object["text"] as? String,
            subtext: object["subtext"] as? String,
            hint: object["hint"] as? String,
            icon: object["icon"] as? String,
            value: object["value"],
            items: (object["items"] as? [Any])?.compactMap { $0 as? String } ?? [],
            multiline: (object["multiline"] as? Bool) ?? false,
            maxLength: (object["max_length"] as? NSNumber)?.intValue ?? 0,
            accent: (object["accent"] as? Bool) ?? false,
            red: (object["red"] as? Bool) ?? false,
            hasCallbacks: (object["has_callbacks"] as? Bool) ?? false,
            hasClick: (object["has_click"] as? Bool) ?? false,
            hasLongClick: (object["has_long_click"] as? Bool) ?? false,
            hasSubFragment: (object["has_sub_fragment"] as? Bool) ?? false
        )
    }

    /// Runs the `on_click` (or `on_long_click`) of a settings row.
    ///
    /// The callback is looked up by key on the plugin side, so nothing but
    /// strings crosses the bridge. Like `setSetting`, this is safe to call from
    /// the main queue: it synchronizes onto the script queue once.
    public func invokeSettingClick(pluginId: String, key: String, long: Bool) {
        guard let plugin = self.plugin(id: pluginId) else {
            return
        }
        _ = self.callJS(
            plugin: plugin,
            function: "__extera.invokeSettingCallback",
            arguments: [key, long ? "long_click" : "click", "null"]
        )
    }

    /// Stores a new value for a control and notifies the plugin. The callback is
    /// invoked by key, so no closure crosses the bridge.
    public func setSetting(pluginId: String, key: String, value: Any?) {
        self.store.setSetting(key, value: value, for: pluginId)
        self.settingsChanged?(pluginId)
        guard let plugin = self.plugin(id: pluginId) else {
            return
        }
        _ = self.callJS(
            plugin: plugin,
            function: "__extera.invokeSettingCallback",
            arguments: [key, "change", self.jsonString(["value": value ?? NSNull()])]
        )
    }

    /// Sends an `AppEvent` to every plugin, mirroring exteraGram's
    /// `on_app_event(START/STOP/PAUSE/RESUME)`.
    ///
    /// Dispatched rather than called inline: this is reached from the main queue
    /// (lifecycle) and from the script queue (`startLoading`), and the main side
    /// must not block on script evaluation.
    public func broadcastAppEvent(_ event: String) {
        self.asyncOnJSQueue { [weak self] in
            guard let self = self else {
                return
            }
            for plugin in self.loadedPlugins {
                self.callLifecycle(plugin, "on_app_event", context: ["event": event])
            }
        }
    }

    /// Delivers `STOP` and unloads every plugin, synchronously.
    ///
    /// This is the shutdown path, not the lifecycle one: once
    /// `applicationWillTerminate` returns the process can be reclaimed, so the
    /// events have to run before it does. Nothing here blocks on another queue —
    /// it already owns the script queue — so `sync` cannot deadlock.
    public func shutdown() {
        self.withJSQueue {
            for plugin in self.loadedPlugins {
                self.callLifecycle(plugin, "on_app_event", context: ["event": "STOP"])
            }
            self.unloadAllOnQueue()
        }
    }
}

/// What the dispatcher decided for one hook invocation.
public enum HookOutcome {
    case passthrough([String: Any])
    case cancel(pluginId: String)
    case modifyFinal(pluginId: String, payload: [String: Any])

    public var isCancelled: Bool {
        if case .cancel = self {
            return true
        }
        return false
    }

    public var payload: [String: Any] {
        switch self {
        case let .passthrough(value), let .modifyFinal(_, value):
            return value
        case .cancel:
            return [:]
        }
    }
}

/// The side effects a plugin can ask for. Implemented by the app layer, which
/// is the only place that knows about accounts and controllers.
///
/// Every method here is reached from inside plugin JavaScript, i.e. while
/// `PluginManager` holds its script queue. An implementation must therefore hand
/// work to the main queue asynchronously and never block on it, or a plugin that
/// asks the UI for something would deadlock against the dispatcher.
public protocol PluginActions: AnyObject {
    /// `account` is the exteraGram account id the plugin named, or nil when it
    /// let the runtime choose: the account a hook is running for, else the one
    /// selected in the UI.
    func sendText(account: Int64?, peerId: Int64, text: String, options: PluginSendOptions)
    func sendFile(account: Int64?, kind: String, peerId: Int64, path: String, options: PluginSendOptions)
    func editMessage(account: Int64?, peerId: Int64, messageId: Int64, text: String, options: PluginSendOptions)
    func showBulletin(pluginId: String, kind: String, json: String)
    func showAlert(pluginId: String, json: String)
    func dismissAlert(pluginId: String)
    /// The account id a bare `account` defaults to, for `get_selected_account()`.
    func selectedAccountId() -> Int64?
    /// `android_utils.copy_to_clipboard`.
    func copyToClipboard(pluginId: String, text: String)
}