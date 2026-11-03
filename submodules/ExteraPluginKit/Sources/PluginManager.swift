import Foundation
import CoreFoundation
import JavaScriptCore
import SwiftSignalKit
// The appearance hooks' value types (`PluginInsertionAnimation`,
// `PluginNameColorsOverride`, `PluginThemeOverride`, `PluginDetailItem`) live in
// the core, so the dispatchers that parse them name those types here.
import TelegramCore

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

    /// Cached answer to "does any plugin implement `on_messages_will_be_deleted`".
    /// See `messagesWillBeDeletedHookAvailable`.
    private var cachedMessagesWillBeDeletedHook: Bool?

    /// Cached answer to "does any plugin implement `on_deleted_messages`", the
    /// callback that lists the copies it kept. Warmed and cleared exactly like
    /// the flag above.
    private var cachedDeletedMessagesHook: Bool?

    /// Cached answer to "does any plugin implement `on_forget_deleted_messages`",
    /// the callback that drops a copy when the user deletes its row. Warmed and
    /// cleared exactly like the flags above.
    private var cachedForgetDeletedMessagesHook: Bool?

    /// Why a plugin on disk did not load, keyed by id. Kept so the list screen can
    /// say so instead of showing the plugin as merely disabled.
    private var failures: [String: String] = [:]

    /// Set by the app once the bridge can act on real accounts.
    public var actions: PluginActions?

    /// Fires with the plugin id when a setting was saved, so an open settings page
    /// can re-read the controls it rendered.
    ///
    /// A signal rather than a closure because two pages of the same plugin are on
    /// screen at once whenever the user opened a nested page: both hold rows from
    /// that plugin and both have to redraw.
    private let settingsChangedPipe = ValuePipe<String>()

    public var settingsChanged: Signal<String, NoError> {
        return self.settingsChangedPipe.signal()
    }

    /// Fires whenever the set of installed/loaded plugins changes, so open
    /// screens rebuild their rows. Every mutation goes through `reloadPlugins` or
    /// `setEnabled`, and both push here.
    private let changesPipe = ValuePipe<Void>()

    public var changes: Signal<Void, NoError> {
        return self.changesPipe.signal()
    }

    private func notifyChanged() {
        self.changesPipe.putNext(Void())
        // A different set of plugins can mean a different accent, so the
        // interface is rebuilt as well as the plugin list. Hopped to the main
        // queue because this runs on the script queue and the rebuild reads
        // `PresentationData` and touches UI.
        Queue.mainQueue().async {
            PluginHookPoints.shared.notifyAppearanceChanged()
        }
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

    /// The same entry point, visible to `PluginSwizzle`.
    ///
    /// A swizzled method runs on whatever thread called it — the main thread for
    /// UI, the network queue for a callback — and has to re-enter plugin
    /// JavaScript, which is only safe on the script queue. This blocks that
    /// caller until the plugin's `before`/`after` has run, which is what an
    /// Xposed hook does too: the hooked method does not proceed until the hook
    /// returns.
    public func runOnJSQueueAndWait(_ body: () -> Void) {
        // No `_ =` here: `withJSQueue` is generic over the body's return type, so
        // with a `Void` body it returns `Void`, and discarding a `Void` result is
        // an error under `-warnings-as-errors` rather than a no-op.
        self.withJSQueue(body)
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
        // A build from before the plugins became files wrote its own copies into
        // the plugins directory and recorded them under a key this build does not
        // use. Nothing updates those copies any more, so a fixed plugin kept
        // running its old script after an update — which is exactly what the
        // report about a stale bulletin was. They are dropped before anything is
        // read, so not one hook can be answered by a copy the user did not
        // install.
        let removedLegacy = self.store.removeLegacyBundledPlugins()
        if !removedLegacy.isEmpty {
            for pluginId in removedLegacy {
                self.pluginLog(pluginId: pluginId, text: "removed a copy written by an older build; install the .plugin again if you want it")
            }
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

        // A newly loaded plugin may implement `on_messages_will_be_deleted`, and
        // the cached answer was computed before it existed. Computed here, on the
        // script queue, so the account state never has to run script itself.
        self.invalidateHookCaches()
        _ = self.messagesWillBeDeletedHookAvailable()
        _ = self.deletedMessagesHookAvailable()
        _ = self.forgetDeletedMessagesHookAvailable()

        // The theme, the peer-name palette and the settings rows were all built
        // before this point: plugin scripts are evaluated after the first frame,
        // and `applyPluginThemeOverride` read `nil` from every plugin that had not
        // loaded yet. Without asking for one rebuild here, a colour plugin only
        // takes effect at the next settings change, which reads as "the plugin
        // does not work".
        //
        // Sent only when something actually loaded, so a build with no plugins
        // does not repaint the interface for nothing.
        if !prepared.isEmpty {
            Queue.mainQueue().async {
                PluginHookPoints.shared.notifyAppearanceChanged()
            }
        }
    }

    private func unloadAllOnQueue() {
        // Bridge answers that arrive after this point have no plugin to reach, so
        // the in-flight requests are dropped first. A plugin that was removed
        // while a subscription refresh was running must not keep its socket open.
        self.actions?.cancelPendingBridges()

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
        self.cachedMessagesWillBeDeletedHook = nil
        self.cachedDeletedMessagesHook = nil
        self.cachedForgetDeletedMessagesHook = nil
        self.lock.unlock()

        // Swizzled methods are installed in the Objective-C runtime, not in a
        // `JSContext`, so they outlive the context that owns them. A removed
        // plugin's block would otherwise keep running and keep a dead context
        // alive. Restoring the original IMPs here is what makes unload complete.
        PluginSwizzle.shared.removeAll()
    }

    public var loadedPlugins: [LoadedPlugin] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.loaded.values.sorted { $0.manifest.name < $1.manifest.name }
    }

    /// Whether any plugin is loaded at all.
    ///
    /// The appearance hooks are consulted while rows and names are being built,
    /// which happens far more often than anything else in this runtime. Asking
    /// this first turns "no plugins installed" into one lock and no JSON, instead
    /// of building a payload for a list that is known empty.
    public var hasLoadedPlugins: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return !self.loaded.isEmpty
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

    /// Tells plugins that messages are about to be deleted from this device.
    ///
    /// Detached like the update hooks and for the same reason: this runs inside
    /// a postbox transaction, and plugin JavaScript must never take the locks a
    /// transaction holds. Nothing a plugin answers can reach the caller.
    public func dispatchMessagesWillBeDeleted(account: Int64, messagesJSON: String) {
        self.jsQueue.async { [weak self] in
            guard let self = self else {
                return
            }
            var payload = self.parseJSONObject(messagesJSON) ?? [:]
            _ = self.dispatch(pluginEvent: "on_messages_will_be_deleted", hookName: "messages", account: account, payload: &payload)
        }
    }

    /// Whether any plugin implements `on_messages_will_be_deleted`.
    ///
    /// Asked once per delete before any message is described; see
    /// `PluginHookPoints.wantsMessagesWillBeDeleted`.
    public func hasMessagesWillBeDeletedHook() -> Bool {
        // Cached: the local delete path asks this before opening a transaction,
        // and the answer must not run script on that queue.
        return self.messagesWillBeDeletedHookCached
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
            if pluginEvent == "on_messages_will_be_deleted" {
                // Not a TL update, so there is no constructor name to register
                // against: the callback's presence is the subscription. The
                // caller asked `hasMessagesWillBeDeletedHook` before paying for
                // the payload, and a plugin without the callback answers
                // "default" immediately in `runHook`.
                return true
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
        var values = self.store.settings(for: pluginId)
        // A switch is stored as a `CFBoolean`, which arrives here as an
        // `NSNumber`. JavaScriptCore turns an `NSNumber` into a JavaScript
        // *number*, so `get_setting("hide_gallery", false)` answered `1` and a
        // plugin written the usual way — `=== true`, or exteraGram's own
        // `bool(get_setting(...))` on the Android side, where Python returned a
        // real `bool` — saw a value that was not `true`. Converting here, at the
        // one funnel every `get_setting` call goes through, gives a script the
        // boolean it expects without each plugin having to coerce.
        for (key, value) in values {
            if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
                values[key] = number.boolValue
            }
        }
        return values
    }

    public func pluginSetSetting(pluginId: String, key: String, value: Any?, reload: Bool) {
        self.store.setSetting(key, value: value, for: pluginId)
        if reload {
            self.settingsChangedPipe.putNext(pluginId)
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

    /// Reads a sibling module for the multi-file loader.
    ///
    /// Resolution is confined to the plugin's own directory. `path` may carry
    /// `./` and `../` from relative imports, so it is normalised and then checked
    /// against the directory: a resolved path outside it reads nothing, which is
    /// what keeps `require('../../other_plugin/main')` from crossing between
    /// plugins. The text is returned as-is; whether it is valid JavaScript is
    /// decided by the context that evaluates it, which reports a syntax error
    /// with the file name attached.
    public func pluginReadModule(pluginId: String, path: String) -> String? {
        guard let url = self.moduleURL(pluginId: pluginId, path: path) else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    public func pluginModuleExists(pluginId: String, path: String) -> Bool {
        guard let url = self.moduleURL(pluginId: pluginId, path: path) else {
            return false
        }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    /// Whether an Objective-C class with this name is loaded.
    ///
    /// `NSClassFromString` is exactly what `PluginSwizzle` uses to resolve a
    /// hook target, so the answer a plugin gets from `find_class` and the one the
    /// install gets cannot disagree.
    public func pluginClassExists(pluginId: String, className: String) -> Bool {
        return NSClassFromString(className) != nil
    }

    /// Runs the plugins' global intent before-handlers for a URL that is about to
    /// be opened, and answers whether one of them stopped it.
    ///
    /// The client calls this from `handleOpenURL` before it hands the URL to its
    /// own opener. `true` means a plugin registered a before-handler that matches
    /// this URL and returned `true`, which on Android is `param.setResult(true)`
    /// stopping the original handling; the client then does not open the URL.
    ///
    /// Ordering: plugins are asked in load order and the first `true` short-
    /// circuits, because once the URL is stopped there is nothing more to stop.
    /// Each plugin's own handlers are already sorted by ascending priority.
    public func dispatchUrlIntent(url: String) -> Bool {
        for plugin in self.loadedPlugins {
            guard plugin.isEnabled else {
                continue
            }
            if let answer = self.callJS(plugin: plugin, function: "__extera.dispatchUrlIntent", arguments: [url]), answer == "true" {
                return true
            }
        }
        return false
    }

    /// Runs the plugins' global intent after-handlers once the URL has been
    /// handled. Never stops anything; a throw is logged and the rest still run.
    public func dispatchUrlIntentAfter(url: String) {
        for plugin in self.loadedPlugins {
            guard plugin.isEnabled else {
                continue
            }
            _ = self.callJS(plugin: plugin, function: "__extera.dispatchUrlIntentAfter", arguments: [url])
        }
    }

    /// Builds a runtime subclass, the host half of `jclassbuilder`.
    ///
    /// Answers a class name on success and a `"!"`-prefixed reason on failure.
    /// The bridge carries one string, and a plugin that asked for a subclass of a
    /// class this build does not have should log why, not catch an exception
    /// across the JavaScriptCore boundary.
    public func pluginBuildClass(pluginId: String, superclassName: String, methodsJSON: String, context: JSContext) -> String {
        var specs: [PluginClassProxy.MethodSpec] = []
        if let data = methodsJSON.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data),
           let parsed = object as? [[String: Any]] {
            for entry in parsed {
                guard let selector = entry["selector"] as? String, let token = entry["token"] as? String else {
                    continue
                }
                // The plugin's declared arity, which the bootstrap read from the
                // function's `length`. Missing means "no arguments", the safe
                // default: a block that reads a register the caller did not write
                // is worse than one that ignores an argument.
                let argumentCount: Int
                if let count = entry["argumentCount"] as? Int {
                    argumentCount = max(0, min(count, 2))
                } else if let count = entry["argumentCount"] as? NSNumber {
                    argumentCount = max(0, min(count.intValue, 2))
                } else {
                    argumentCount = 0
                }
                specs.append(PluginClassProxy.MethodSpec(selector: selector, token: token, argumentCount: argumentCount))
            }
        }
        do {
            return try PluginClassProxy.shared.build(
                ownerId: pluginId,
                superclassName: superclassName,
                methods: specs,
                context: context
            )
        } catch {
            return "!" + String(describing: error)
        }
    }

    /// Instantiates a class `pluginBuildClass` built. Only classes this runtime
    /// made can be instantiated through here.
    public func pluginMakeClassInstance(pluginId: String, className: String) -> AnyObject? {
        return PluginClassProxy.shared.makeInstance(className: className)
    }

    /// Opens the screen a settings row's `link_alias` names.
    ///
    /// The alias is the SDK's own vocabulary (`plugins`, `appearance`,
    /// `notifications`, ...). Only the ones this app actually has are honoured;
    /// an unknown name is logged and ignored, because opening the wrong screen
    /// is worse than a row that does nothing.
    public func pluginOpenSettingLink(pluginId: String, alias: String) {
        let normalised = alias.trimmingCharacters(in: .whitespaces).lowercased()
        switch normalised {
        case "plugins", "plugin_settings":
            self.actions?.openPluginSettings()
        default:
            self.pluginLog(pluginId: pluginId, text: "link_alias \"\(alias)\" has no matching screen on iOS")
        }
    }

    /// Installs an Objective-C swizzle for a plugin, through `PluginSwizzle`.
    ///
    /// The plugin gives a class and a selector and gets `before`/`after`
    /// callbacks, which is the iOS shape of an Xposed hook. A class or a method
    /// that does not exist is answered with a reason, not a thrown error across
    /// the bridge: a ported plugin usually hooks several methods and wants to
    /// log the ones this build does not have and keep going.
    public func pluginInstallSwizzle(
        pluginId: String,
        className: String,
        selector: String,
        isClassMethod: Bool,
        beforeToken: String?,
        afterToken: String?,
        context: JSContext
    ) -> String? {
        let hook = PluginSwizzle.Hook(
            pluginId: pluginId,
            className: className,
            selectorName: selector,
            isClassMethod: isClassMethod,
            context: context,
            beforeToken: beforeToken,
            afterToken: afterToken
        )
        do {
            try PluginSwizzle.shared.install(hook)
            return nil
        } catch {
            return "\(error)"
        }
    }

    /// Resolves a module path inside one plugin's directory, or nil when the
    /// result would leave it.
    private func moduleURL(pluginId: String, path: String) -> URL? {
        let base = self.store.directory(for: pluginId).standardizedFileURL
        let candidate = base.appendingPathComponent(path).standardizedFileURL
        let basePath = base.path.hasSuffix("/") ? base.path : base.path + "/"
        // The entry module itself resolves to the directory, which is not a
        // file; `hasPrefix` on the directory plus a separator rejects a bare
        // `..` that lands exactly on the parent without rejecting the base.
        guard candidate.path == base.path || candidate.path.hasPrefix(basePath) else {
            return nil
        }
        return candidate
    }

    public func pluginSelectedAccount(pluginId: String) -> Int64? {
        return self.actions?.selectedAccountId()
    }

    /// Answers `themeColors` from the live theme.
    ///
    /// The parse and the encode happen here rather than in the runtime so the
    /// runtime only has to map a name to a colour; a plugin asks once per
    /// settings rebuild, so this is not on a hot path.
    public func pluginThemeColors(pluginId: String, namesJSON: String) -> String? {
        guard let names = (try? JSONSerialization.jsonObject(with: Data(namesJSON.utf8))) as? [String] else {
            return "{}"
        }
        let colors = self.actions?.themeColors(names: names) ?? [:]
        var object: [String: Any] = [:]
        for (name, value) in colors {
            object[name] = Int(value)
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object) else {
            return "{}"
        }
        return String(data: data, encoding: .utf8)
    }

    public func pluginCopyToClipboard(pluginId: String, text: String) {
        self.actions?.copyToClipboard(pluginId: pluginId, text: text)
    }

    /// Answers `open_url`. The action is asynchronous, so the return value means
    /// "accepted", not "finished loading": a plugin that only wants a button to
    /// do something never reads it.
    public func pluginOpenUrl(pluginId: String, url: String) -> Bool {
        guard let url = URL(string: url), !url.absoluteString.isEmpty else {
            return false
        }
        guard let actions = self.actions else {
            return false
        }
        actions.openUrl(pluginId: pluginId, url: url)
        return true
    }

    /// Answers `appVersion` with the build the app is running.
    ///
    /// The same value the manifest gate compares against, read from the bundle
    /// so the two can never disagree.
    public func pluginAppVersion(pluginId: String) -> String {
        return self.bundleAppVersion
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

    public func pluginHttpGet(pluginId: String, url: String, headersJSON: String, timeout: Double, callbackToken: String) {
        guard let actions = self.actions else {
            self.resolveBridgeCallback(pluginId: pluginId, token: callbackToken, response: ["ok": false, "error": "the plugin runtime is not active"])
            return
        }
        actions.httpGet(pluginId: pluginId, url: url, headersJSON: headersJSON, timeout: timeout, callbackToken: callbackToken)
    }

    public func pluginHttpRequest(pluginId: String, method: String, url: String, headersJSON: String, bodyBase64: String?, timeout: Double, callbackToken: String) {
        guard let actions = self.actions else {
            self.resolveBridgeCallback(pluginId: pluginId, token: callbackToken, response: ["ok": false, "error": "the plugin runtime is not active"])
            return
        }
        actions.httpRequest(pluginId: pluginId, method: method, url: url, headersJSON: headersJSON, bodyBase64: bodyBase64, timeout: timeout, callbackToken: callbackToken)
    }

    public func pluginProxyList(pluginId: String, callbackToken: String) {
        guard let actions = self.actions else {
            self.resolveBridgeCallback(pluginId: pluginId, token: callbackToken, response: ["ok": false, "error": "the plugin runtime is not active"])
            return
        }
        actions.proxyList(pluginId: pluginId, callbackToken: callbackToken)
    }

    public func pluginProxyAdd(pluginId: String, linksJSON: String, callbackToken: String) {
        guard let actions = self.actions else {
            self.resolveBridgeCallback(pluginId: pluginId, token: callbackToken, response: ["ok": false, "error": "the plugin runtime is not active"])
            return
        }
        actions.proxyAdd(pluginId: pluginId, linksJSON: linksJSON, callbackToken: callbackToken)
    }

    public func pluginProxyRemoveAll(pluginId: String, callbackToken: String) {
        guard let actions = self.actions else {
            self.resolveBridgeCallback(pluginId: pluginId, token: callbackToken, response: ["ok": false, "error": "the plugin runtime is not active"])
            return
        }
        actions.proxyRemoveAll(pluginId: pluginId, callbackToken: callbackToken)
    }

    /// Starts, stops or reports the in-app local MTProxy. Answers through
    /// `resolveBridgeCallback(pluginId:token:...)`.
    public func pluginLocalProxy(pluginId: String, requestJSON: String, callbackToken: String) {
        guard let actions = self.actions else {
            self.resolveBridgeCallback(pluginId: pluginId, token: callbackToken, response: ["ok": false, "error": "the plugin runtime is not active"])
            return
        }
        actions.localProxy(pluginId: pluginId, requestJSON: requestJSON, callbackToken: callbackToken)
    }

    /// The local proxy's current status as JSON, synchronously.
    public func pluginLocalProxyStatus(pluginId: String) -> String {
        guard let actions = self.actions else {
            return "{\"ok\":false,\"running\":false,\"error\":\"the plugin runtime is not active\"}"
        }
        return actions.localProxyStatus(pluginId: pluginId)
    }

    public func pluginOwnPeerId(pluginId: String, account: Int64?, callbackToken: String) {
        guard let actions = self.actions else {
            self.resolveBridgeCallback(pluginId: pluginId, token: callbackToken, response: ["ok": false, "error": "the plugin runtime is not active"])
            return
        }
        actions.ownPeerId(pluginId: pluginId, account: account, callbackToken: callbackToken)
    }

    public func pluginPeerInfo(pluginId: String, account: Int64?, peerId: Int64, callbackToken: String) {
        guard let actions = self.actions else {
            self.resolveBridgeCallback(pluginId: pluginId, token: callbackToken, response: ["ok": false, "error": "the plugin runtime is not active"])
            return
        }
        actions.peerInfo(pluginId: pluginId, account: account, peerId: peerId, callbackToken: callbackToken)
    }

    public func pluginChatMessages(pluginId: String, account: Int64?, peerId: Int64, limit: Int, callbackToken: String) {
        guard let actions = self.actions else {
            self.resolveBridgeCallback(pluginId: pluginId, token: callbackToken, response: ["ok": false, "error": "the plugin runtime is not active"])
            return
        }
        actions.chatMessages(pluginId: pluginId, account: account, peerId: peerId, limit: limit, callbackToken: callbackToken)
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

    /// Delivers a resolved value to a plugin's pending bridge callback.
    ///
    /// Called from whatever queue the work finished on. `callJS` serializes onto
    /// the script queue itself, so nothing here has to hop first; a plugin whose
    /// context was unloaded in the meantime is simply dropped, which is the same
    /// rule `runScheduled` follows.
    ///
    /// These tokens live in a separate map from the bulletin/alert ones: a
    /// bulletin callback is one-shot and takes no arguments, while a bridge
    /// callback receives the result object and may be the only thing the plugin
    /// was waiting for.
    public func resolveBridgeCallback(pluginId: String, token: String, response: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: response),
              let text = String(data: data, encoding: .utf8) else {
            self.resolveBridgeCallback(pluginId: pluginId, token: token, responseJSON: "{\"ok\":false,\"error\":\"the response could not be encoded\"}")
            return
        }
        self.resolveBridgeCallback(pluginId: pluginId, token: token, responseJSON: text)
    }

    public func resolveBridgeCallback(pluginId: String, token: String, responseJSON: String) {
        guard let plugin = self.plugin(id: pluginId) else {
            return
        }
        _ = self.callJS(plugin: plugin, function: "__extera.resolveBridge", arguments: [token, responseJSON])
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

    // MARK: - Appearance queries

    /// Asks one plugin for the answer to a `query` callback.
    ///
    /// The bootstrap returns `{ "value": ... }` so that "the plugin has nothing
    /// to say" (`undefined`, or no such method) is distinguishable from a real
    /// `null` answer. Both become `nil` here: from the app's side there is no
    /// difference between a plugin that opts out and one that is not installed.
    private func queryValue(plugin: LoadedPlugin, event: String, payloadJSON: String, context: [String: Any]) -> Any? {
        guard let json = self.callJS(
            plugin: plugin,
            function: "__extera.query",
            arguments: [event, payloadJSON, self.jsonString(context)]
        ) else {
            return nil
        }
        guard let object = self.parseJSONObject(json) else {
            return nil
        }
        guard let value = object["value"], !(value is NSNull) else {
            return nil
        }
        return value
    }

    /// Encodes any JSON-able value, not only a dictionary. The query payloads are
    /// sometimes arrays (the attach-menu key list), and `JSONSerialization` will
    /// take those at the top level on iOS 13 and later.
    private func jsonText(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else {
            return "null"
        }
        return text
    }

    /// Plugins in load order, which is the order hook chains run in. The list
    /// screen uses `loadedPlugins` (name order) because a user reads names; a
    /// decision across plugins has to be reproducible, so it uses this instead.
    private var pluginsInLoadOrder: [LoadedPlugin] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.loaded.values.sorted { $0.loadIndex < $1.loadIndex }
    }

    /// The attach-menu keys the plugins want hidden, in menu order.
    ///
    /// Each plugin sees the list the previous one left behind, so two plugins
    /// that hide different buttons both apply. A plugin that answers with a key
    /// that was not in its input is ignored rather than trusted, because the
    /// answer decides which buttons the user can reach.
    public func dispatchAttachMenuExclusions(account: Int64, peerId: Int64?, keys: [String]) -> [String] {
        guard !keys.isEmpty else {
            return keys
        }
        var current = keys
        var context: [String: Any] = ["account": account]
        if let peerId = peerId {
            context["peer"] = peerId
        }
        for plugin in self.pluginsInLoadOrder {
            let payload = self.jsonText(["keys": current])
            guard let answer = self.queryValue(plugin: plugin, event: "on_attach_menu_hook", payloadJSON: payload, context: context) else {
                continue
            }
            guard let list = answer as? [Any] else {
                continue
            }
            var requested = Set<String>()
            for entry in list {
                if let key = entry as? String {
                    requested.insert(key)
                }
            }
            // Keep only what was offered, so a typo cannot remove an unseen key.
            current = current.filter { requested.contains($0) }
        }
        return current
    }

    /// The settings rows the plugins want hidden, in screen order.
    ///
    /// Same contract as the attach menu: each plugin sees what the previous one
    /// kept, and a key that was not offered is ignored. There is no peer here
    /// because every settings row belongs to the account itself.
    public func dispatchSettingsRowExclusions(account: Int64, keys: [String]) -> [String] {
        guard !keys.isEmpty else {
            return keys
        }
        var current = keys
        let context: [String: Any] = ["account": account]
        for plugin in self.pluginsInLoadOrder {
            let payload = self.jsonText(["keys": current])
            guard let answer = self.queryValue(plugin: plugin, event: "on_settings_rows_hook", payloadJSON: payload, context: context) else {
                continue
            }
            guard let list = answer as? [Any] else {
                continue
            }
            var requested = Set<String>()
            for entry in list {
                if let key = entry as? String {
                    requested.insert(key)
                }
            }
            current = current.filter { requested.contains($0) }
        }
        return current
    }

    /// How a message row or date separator should animate in, or `nil` for the
    /// stock insertion.
    ///
    /// Plugins are asked in load order and the first answer wins: two plugins
    /// animating the same row would produce one animation playing over another,
    /// which is not something either of them asked for.
    public func dispatchInsertionAnimation(account: Int64, messageJSON: String, isDate: Bool, width: Double, height: Double) -> PluginInsertionAnimation? {
        let context: [String: Any] = [
            "account": account,
            "isDate": isDate,
            "width": width,
            "height": height
        ]
        for plugin in self.pluginsInLoadOrder {
            guard let answer = self.queryValue(plugin: plugin, event: "on_message_inserted", payloadJSON: messageJSON, context: context) else {
                continue
            }
            guard let dictionary = answer as? [String: Any] else {
                continue
            }
            if let animation = PluginInsertionAnimation(json: dictionary) {
                return animation
            }
        }
        return nil
    }

    /// The colour override a plugin wants for peer names, or `nil` for the theme.
    public func dispatchNameColors(account: Int64?) -> PluginNameColorsOverride? {
        var context: [String: Any] = [:]
        if let account = account {
            context["account"] = account
        }
        for plugin in self.pluginsInLoadOrder {
            guard let answer = self.queryValue(plugin: plugin, event: "on_name_colors", payloadJSON: "null", context: context) else {
                continue
            }
            guard let dictionary = answer as? [String: Any] else {
                continue
            }
            if let override = PluginNameColorsOverride(json: dictionary) {
                return override
            }
        }
        return nil
    }

    /// The accent a plugin wants for the whole interface, or `nil` for the theme.
    ///
    /// Asked through its own callback, `on_theme_colors`, rather than sharing
    /// `on_name_colors`: recolouring names and recolouring the interface are two
    /// separate promises, and a plugin that only does one of them must not be
    /// forced to answer for the other. First answer wins, for the same reason as
    /// the animation hook — two accents cannot both be applied.
    public func dispatchThemeOverride(account: Int64?) -> PluginThemeOverride? {
        var context: [String: Any] = [:]
        if let account = account {
            context["account"] = account
        }
        for plugin in self.pluginsInLoadOrder {
            guard let answer = self.queryValue(plugin: plugin, event: "on_theme_colors", payloadJSON: "null", context: context) else {
                continue
            }
            guard let dictionary = answer as? [String: Any] else {
                continue
            }
            if let override = PluginThemeOverride(json: dictionary) {
                return override
            }
        }
        return nil
    }

    /// Whether a plugin wants a message row hidden.
    ///
    /// Asked per row while the list is built, so it has to stay cheap when no
    /// plugin listens: the caller checks `hasPluginForHook` before building the
    /// message JSON. The first plugin that answers `true` wins — hiding a row is
    /// not a value two plugins can negotiate.
    public func dispatchHideMessage(account: Int64, messageJSON: String) -> Bool {
        let context: [String: Any] = ["account": account]
        for plugin in self.pluginsInLoadOrder {
            guard let answer = self.queryValue(plugin: plugin, event: "on_hide_message", payloadJSON: messageJSON, context: context) else {
                continue
            }
            if let visible = answer as? Bool {
                return visible
            }
            // An object answer is accepted too, so a plugin can say why it hid a
            // row without the runtime having to know the reason's shape.
            if let dictionary = answer as? [String: Any], (dictionary["hide"] as? Bool) == true {
                return true
            }
        }
        return false
    }

    /// Whether any plugin implements an appearance callback such as `on_hide_message`.
    ///
    /// Runs the bootstrap's `hasHook`, which answers whether the plugin instance
    /// has the method. Called once per history view, never per row, so
    /// synchronizing onto the script queue is affordable; touching a `JSContext`
    /// from the caller's thread would not be.
    public func hasPluginForHook(_ event: String) -> Bool {
        for plugin in self.pluginsInLoadOrder {
            guard let answer = self.callJS(plugin: plugin, function: "__extera.hasHook", arguments: [event]) else {
                continue
            }
            if answer == "true" {
                return true
            }
        }
        return false
    }

    /// Whether a plugin implements `on_messages_will_be_deleted`, answered without
    /// touching a `JSContext`.
    ///
    /// The account state asks this before opening a transaction for a batch that
    /// may carry a delete. Running script there would block every database reader
    /// — and this queue — behind plugin code, so the answer is a plain cached
    /// read. It is warmed while the script queue is held (see `loadAllOnQueue`),
    /// which is why the first batch already sees a real answer.
    public var messagesWillBeDeletedHookCached: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.cachedMessagesWillBeDeletedHook ?? false
    }

    /// The uncached form, which runs plugin JavaScript. Must only be called from
    /// the script queue, where the call is inline rather than a queue hop.
    public func messagesWillBeDeletedHookAvailable() -> Bool {
        self.lock.lock()
        if let cached = self.cachedMessagesWillBeDeletedHook {
            self.lock.unlock()
            return cached
        }
        self.lock.unlock()
        let answer = self.hasPluginForHook("on_messages_will_be_deleted")
        self.lock.lock()
        self.cachedMessagesWillBeDeletedHook = answer
        self.lock.unlock()
        return answer
    }

    /// Forgets the cached answer above. Called whenever the loaded set changes,
    /// because a plugin that defines the callback may have arrived or gone.
    private func invalidateHookCaches() {
        self.lock.lock()
        self.cachedMessagesWillBeDeletedHook = nil
        self.cachedDeletedMessagesHook = nil
        self.cachedForgetDeletedMessagesHook = nil
        self.lock.unlock()
    }

    /// Whether any plugin keeps copies of deleted messages for a chat.
    ///
    /// The history list asks this once per build, before the row loop, so it
    /// must not run script on a queue the list is being built on. It answers
    /// from a flag warmed while the script queue is held, exactly like
    /// `messagesWillBeDeletedHookCached`.
    public var deletedMessagesHookCached: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.cachedDeletedMessagesHook ?? false
    }

    /// The uncached form, which runs plugin JavaScript on the script queue.
    public func deletedMessagesHookAvailable() -> Bool {
        self.lock.lock()
        if let cached = self.cachedDeletedMessagesHook {
            self.lock.unlock()
            return cached
        }
        self.lock.unlock()
        let answer = self.hasPluginForHook("on_deleted_messages")
        self.lock.lock()
        self.cachedDeletedMessagesHook = answer
        self.lock.unlock()
        return answer
    }

    /// The messages a plugin kept after they were deleted, for one chat.
    ///
    /// The message is gone from the database, so this is the only source the
    /// list can build the row from. Plugins are asked in load order and the
    /// answers are concatenated: two plugins can each keep a copy of a different
    /// message, and dropping one of them because another answered would lose a
    /// row the user's own switch asked to keep. A duplicate of the same
    /// `(peer, id)` is collapsed, because two copies of one message would be two
    /// identical rows.
    public func dispatchDeletedMessages(account: Int64, peerId: Int64) -> [PluginStoredMessage] {        let context: [String: Any] = ["account": account, "peer": peerId]
        let payload = self.jsonText(["peer_id": peerId])
        var result: [PluginStoredMessage] = []
        var seen = Set<String>()
        for plugin in self.pluginsInLoadOrder {
            guard let answer = self.queryValue(plugin: plugin, event: "on_deleted_messages", payloadJSON: payload, context: context) else {
                continue
            }
            guard let list = answer as? [Any] else {
                continue
            }
            for entry in list {
                guard let object = entry as? [String: Any],
                      let message = self.storedMessage(from: object, peerId: peerId) else {
                    continue
                }
                let key = "\(message.peerId):\(message.messageId)"
                if seen.insert(key).inserted {
                    result.append(message)
                }
            }
        }
        // The list is built newest first in some modes and oldest first in
        // others; the caller merges by index, so the order here is only what a
        // reader of the payload would expect.
        return result.sorted { $0.timestamp < $1.timestamp }
    }

    /// Whether any plugin can forget saved copies.
    ///
    /// Read by the delete path on the main queue, so it answers from the flag
    /// warmed while the script queue is held rather than calling into script.
    public var canForgetDeletedMessagesHookCached: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.cachedForgetDeletedMessagesHook ?? false
    }

    /// The uncached form, which runs plugin JavaScript on the script queue.
    public func forgetDeletedMessagesHookAvailable() -> Bool {
        self.lock.lock()
        if let cached = self.cachedForgetDeletedMessagesHook {
            self.lock.unlock()
            return cached
        }
        self.lock.unlock()
        let answer = self.hasPluginForHook("on_forget_deleted_messages")
        self.lock.lock()
        self.cachedForgetDeletedMessagesHook = answer
        self.lock.unlock()
        return answer
    }

    /// Tells the plugins to forget the copies they kept for the given messages.
    ///
    /// A saved row exists only in the plugin's store, so the client cannot drop
    /// it: it asks here and then rebuilds the list. Every plugin that listens is
    /// told — a copy can live in more than one store — and the answer is ignored,
    /// because forgetting is not a value two plugins negotiate.
    public func dispatchForgetDeletedMessages(account: Int64, peerId: Int64, messageIds: [Int32]) {
        guard !messageIds.isEmpty else {
            return
        }
        let context: [String: Any] = ["account": account, "peer": peerId]
        let payload = self.jsonText(["peer_id": peerId, "message_ids": messageIds])
        for plugin in self.pluginsInLoadOrder {
            _ = self.queryValue(plugin: plugin, event: "on_forget_deleted_messages", payloadJSON: payload, context: context)
        }
    }

    /// One stored row, or `nil` when the plugin's answer cannot describe a
    /// message a chat row can show.
    ///
    /// A missing id or timestamp is refused rather than defaulted: both are what
    /// place the row among the live messages, and a zero would put every broken
    /// entry at the very bottom of the chat.
    private func storedMessage(from object: [String: Any], peerId: Int64) -> PluginStoredMessage? {
        // `messageId` is `Int32` on the wire, so it is read as one here rather
        // than widened to `Int` and narrowed back at the call.
        guard let id = (object["id"] as? NSNumber)?.int32Value, id != 0 else {
            return nil
        }
        let timestamp = (object["date"] as? NSNumber)?.int32Value ?? 0
        guard timestamp > 0 else {
            return nil
        }
        let sender = (object["sender_id"] as? NSNumber)?.int64Value
        let mediaKind = (object["media_kind"] as? String).flatMap { $0 == "none" || $0.isEmpty ? nil : $0 }
        // Passed through untouched: the plugin is only carrying the bytes the
        // host gave it, and decoding is the caller's job, where the fallback to
        // `mediaKind` lives if the bytes turn out to be unreadable.
        let mediaData = (object["media_data"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return PluginStoredMessage(
            peerId: peerId,
            messageId: id,
            timestamp: timestamp,
            text: (object["text"] as? String) ?? "",
            mediaKind: mediaKind,
            mediaData: mediaData,
            senderId: sender == nil || sender == 0 ? nil : sender,
            isOutgoing: (object["is_out"] as? Bool) ?? false
        )
    }

    /// Whether a plugin wants screenshots allowed for every screen.
    ///
    /// The Android original (RFS) cleared `FLAG_SECURE` from the window and from
    /// every view added to it. iOS has no window flag: protection is per layer,
    /// and every protected layer is marked through one function, so the answer
    /// here is applied once to that function instead of to a screen at a time.
    /// First plugin that answers `true` wins — there is no "half allowed".
    ///
    /// Asked on load, on an app event and whenever a setting was saved, never per
    /// row, so it needs no cached flag.
    public func dispatchAllowScreenshots(account: Int64?) -> Bool {
        var context: [String: Any] = [:]
        if let account = account {
            context["account"] = account
        }
        for plugin in self.pluginsInLoadOrder {
            guard let answer = self.queryValue(plugin: plugin, event: "on_allow_screenshots", payloadJSON: "null", context: context) else {
                continue
            }
            if let allowed = answer as? Bool, allowed {
                return true
            }
            // A plugin may answer with a reason, the same way `on_hide_message`
            // may; the shape of the reason is the plugin's business.
            if let dictionary = answer as? [String: Any], (dictionary["allow"] as? Bool) == true {
                return true
            }
        }
        return false
    }

    /// Extra rows for the message-details screen, in plugin and item order.
    public func dispatchMessageDetails(account: Int64, messageJSON: String) -> [PluginDetailItem] {
        let context: [String: Any] = ["account": account]
        var result: [PluginDetailItem] = []
        for plugin in self.pluginsInLoadOrder {
            guard let answer = self.queryValue(plugin: plugin, event: "on_message_details", payloadJSON: messageJSON, context: context) else {
                continue
            }
            guard let list = answer as? [Any] else {
                continue
            }
            for entry in list {
                guard let dictionary = entry as? [String: Any],
                      let title = dictionary["title"] as? String,
                      let value = dictionary["value"] as? String else {
                    continue
                }
                result.append(PluginDetailItem(title: title, value: value))
            }
        }
        return result
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
        self.settingsChangedPipe.putNext(pluginId)
        // A colour plugin's accent usually lives in a setting, so a change has to
        // reach the theme that was already built. The callback below answers with
        // the new colour; this asks the interface to rebuild and read it. Sent
        // after the callback so the plugin has already seen the new value.
        Queue.mainQueue().async {
            PluginHookPoints.shared.notifyAppearanceChanged()
        }
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
            for plugin in self.pluginsInLoadOrder {
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
            for plugin in self.pluginsInLoadOrder {
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
    /// `Theme.getColor` for the names a plugin asked about, as `0xRRGGBB`.
    func themeColors(names: [String]) -> [String: UInt32]
    /// `android_utils.copy_to_clipboard`.
    func copyToClipboard(pluginId: String, text: String)
    /// `android_utils.open_url`: hand a URL to the app's own opener.
    func openUrl(pluginId: String, url: URL)

    // Network and proxy. Each answers by calling
    // `PluginManager.resolveBridgeCallback(pluginId:token:...)` — never
    // synchronously, and never by blocking the script queue.
    func httpGet(pluginId: String, url: String, headersJSON: String, timeout: Double, callbackToken: String)
    func httpRequest(pluginId: String, method: String, url: String, headersJSON: String, bodyBase64: String?, timeout: Double, callbackToken: String)
    /// Opens the app's own plugin settings screen, the target of a settings row
    /// whose `link_alias` is `plugins`.
    func openPluginSettings()
    func proxyList(pluginId: String, callbackToken: String)
    func proxyAdd(pluginId: String, linksJSON: String, callbackToken: String)
    func proxyRemoveAll(pluginId: String, callbackToken: String)
    /// Starts, stops or reports the local MTProxy a plugin asked for, and adds
    /// or removes its entry in the proxy list. `requestJSON` is
    /// `{"action": "start" | "stop" | "status", "domain": "zone"}`.
    func localProxy(pluginId: String, requestJSON: String, callbackToken: String)
    /// The same status the `status` action answers with, for a settings row that
    /// cannot wait for a callback.
    func localProxyStatus(pluginId: String) -> String
    func ownPeerId(pluginId: String, account: Int64?, callbackToken: String)

    /// The profile of one peer, the data behind
    /// `get_contacts_controller().get_peer(...)`. Answers through
    /// `resolveBridgeCallback`; `peerId` is the signed numeric id a plugin
    /// already uses elsewhere.
    func peerInfo(pluginId: String, account: Int64?, peerId: Int64, callbackToken: String)
    /// The most recent messages of one chat, the data behind
    /// `get_messages_controller().get_messages(...)`. `limit` is the page size.
    func chatMessages(pluginId: String, account: Int64?, peerId: Int64, limit: Int, callbackToken: String)

    /// Drops every in-flight bridge request.
    ///
    /// Declared as a requirement, not only as an extension member, so the call
    /// reaches the implementation through the existential: a method that exists
    /// only in an extension is dispatched statically, and the runtime's own
    /// `cancelPendingBridges` would never run.
    func cancelPendingBridges()
}

public extension PluginActions {
    /// Called before the plugins are unloaded: a request whose plugin no longer
    /// exists has nowhere to deliver its answer, and keeping the socket open
    /// would let a removed plugin keep talking to the network. Defaulted so an
    /// implementation that never starts one does not have to write it.
    func cancelPendingBridges() {
    }

    /// A build that never reads a theme colour answers with an empty map instead
    /// of failing the plugin's settings screen.
    func themeColors(names: [String]) -> [String: UInt32] {
        return [:]
    }
}
