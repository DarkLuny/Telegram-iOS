import Foundation
import UIKit
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import TextFormat
import AccountContext
import UndoUI
import Display
import PresentationDataUtils

/// Connects the plugin runtime to the running app.
///
/// `PluginManager` knows how to run plugin JavaScript and what a hook decided,
/// but it deliberately knows nothing about accounts, transports or controllers.
/// This type supplies the missing half: it implements `PluginActions`, installs
/// the `PluginHookPoints` closures the core calls, and forwards app lifecycle
/// events to plugins.
///
/// Everything here is installed once, at launch. The core checks each hook for
/// `nil`, so an app that never calls `activate` behaves exactly as before.
public final class PluginRuntime {
    public static let shared = PluginRuntime()

    private var foregroundDisposable: Disposable?
    private var lifecycleDisposable: Disposable?
    /// Keeps the screenshot switch (RFS) in step with the plugins.
    private var screenshotOverrideDisposable: Disposable?
    /// The answer last applied, so a rebuild that changed nothing does not walk
    /// the window tree again. `nil` until the first apply.
    private var screenshotOverrideApplied: Bool?
    /// The context `activate` last ran for.
    ///
    /// Launch reaches `activate` once, but the app delegate's launch signal is
    /// built from account-manager transactions and can emit again when shared
    /// data changes. Re-activating reruns `startLoading`, which re-evaluates every
    /// plugin and calls `on_plugin_load` again without ever calling
    /// `on_plugin_unload`. The logs of the first on-device test showed exactly
    /// that: five `loaded` lines and not one `unload`, plus a stale menu item and
    /// a leaked `JSContext` per repeat.
    private weak var activatedContext: SharedAccountContext?
    /// Last foreground value seen from `applicationBindings`, so a repeat
    /// emission does not produce a second RESUME/PAUSE pair.
    private var wasInForeground: Bool?

    private let actions = PluginActionsImpl()

    private init() {
    }

    // MARK: - Activation

    /// Starts the runtime: loads the installed plugins and wires every hook.
    ///
    /// Idempotent, because `AppDelegate` can legitimately reach its launch path
    /// more than once when the scene is recreated.
    public func activate(sharedContext: SharedAccountContext) {
        // Installing the hooks and starting the load are both idempotent in the
        // narrow sense, but reloading is not: it re-evaluates every script and
        // fires `on_plugin_load` again. A second activation for the same context
        // therefore only refreshes what can go stale, and leaves the plugins
        // alone; the test log showed five loads and no unloads without this.
        if let activatedContext = self.activatedContext, activatedContext === sharedContext {
            self.actions.sharedContext = sharedContext
            return
        }
        self.activatedContext = sharedContext

        self.actions.sharedContext = sharedContext

        // Every signed-in account, keyed by the id a plugin passes as `account=`.
        // exteraGram's ids are indices into this list; here they are the real
        // account ids, and an unknown one falls back to the primary account. The
        // primary is what a bare helper means, so it is tracked separately.
        self.foregroundDisposable?.dispose()
        self.foregroundDisposable = (sharedContext.activeAccountContexts
        |> deliverOnMainQueue).start(next: { [weak self] primary, accounts, _ in
            guard let self else {
                return
            }
            var contexts: [Int64: AccountContext] = [:]
            for (id, context, _) in accounts {
                contexts[id.int64] = context
            }
            self.actions.contexts = contexts
            self.actions.primaryAccountId = primary?.account.id.int64
            // JS keeps its own copy so `get_selected_account()` answers without a
            // bridge round-trip on every call; pushing it when the set changes is
            // what makes an account switch visible to a plugin.
            if let primary = primary {
                PluginManager.shared.updateSelectedAccount(primary.account.id.int64)
            }
        })

        let manager = PluginManager.shared
        manager.actions = self.actions
        manager.configure(bootstrapSource: pluginBootstrapJavaScript)

        self.installHooks()
        self.observeLifecycle(sharedContext: sharedContext)

        // Loading and `START` both happen on the script queue, so launch is not
        // held up by plugin evaluation. `START` is delivered after the load, as
        // exteraGram does: a plugin's `on_plugin_load` has already run by then.
        manager.startLoading(startEvent: "START")
    }

    private func installHooks() {
        let manager = PluginManager.shared
        let hooks = PluginHookPoints.shared

        // Rewrites the outgoing text in place, or drops the message entirely.
        // Runs for every enqueue, so it must stay cheap when no plugin listens.
        hooks.sendMessage = { accountId, peerId, text in
            guard PluginManager.shared.hasSendMessageHook else {
                return true
            }
            // A message a plugin sends itself goes through the same enqueue path.
            // Re-entering the hook would let two plugins rewrite each other's
            // output forever, so the runtime marks its own sends.
            if PluginRuntime.isSendingFromPlugin {
                return true
            }
            var params: [String: Any] = [
                "message": text,
                "peer": peerId,
                "account": accountId
            ]
            let outcome = manager.dispatchSendMessage(account: accountId, params: &params)
            if outcome.isCancelled {
                return false
            }
            if let updated = outcome.payload["message"] as? String {
                text = updated
            }
            return true
        }

        hooks.preRequest = { name, accountId, parametersJSON in
            var payload = PluginRuntime.parseObject(parametersJSON)
            let outcome = manager.dispatchPreRequest(name: name, account: accountId, request: &payload)
            return !outcome.isCancelled
        }

        // Asked before the parameters are flattened. A lock lookup only: it never
        // runs plugin JavaScript, so it is safe on the network queue.
        hooks.wantsRequest = { name in
            return manager.hasRequestHook(name: name)
        }

        hooks.postRequest = { name, accountId, responseJSON, error in
            var errorPayload: [String: Any]?
            if let error = error {
                errorPayload = ["message": error]
            }
            // `wantsRequest` already filtered this name on the way in, and the
            // manager checks again before scripting; doing a third lookup here
            // would only duplicate that.
            manager.dispatchPostRequest(name: name, account: accountId, responseJSON: responseJSON, error: errorPayload)
        }

        // Updates are observational: a plugin is told what arrived, and nothing it
        // returns reaches the state machine. Dispatch is detached because updates
        // arrive on the account state's own queue far more often than requests,
        // and script evaluation must not run there.
        hooks.wantsUpdate = { name in
            return manager.hasUpdateHook(name: name)
        }

        hooks.receivedUpdate = { accountId, name, json in
            manager.dispatchUpdateDetached(name: name, account: accountId, json: json, isContainer: false)
        }

        hooks.receivedUpdates = { accountId, batchJSON in
            manager.dispatchUpdateDetached(name: "updates", account: accountId, json: batchJSON, isContainer: true)
        }

        // The four appearance hooks. Each is asked while a screen is being built,
        // so each answers with a value and the UI decides how to apply it. The
        // JSON in and out keeps the plugin from holding any Swift object.

        hooks.attachMenuExclusions = { accountId, peerId, keys in
            return manager.dispatchAttachMenuExclusions(account: accountId, peerId: peerId, keys: keys)
        }

        hooks.settingsRowExclusions = { accountId, keys in
            return manager.dispatchSettingsRowExclusions(account: accountId, keys: keys)
        }

        hooks.insertionAnimation = { accountId, messageJSON, isDate, width, height in
            guard manager.hasLoadedPlugins else {
                return nil
            }
            return manager.dispatchInsertionAnimation(account: accountId, messageJSON: messageJSON, isDate: isDate, width: width, height: height)
        }

        hooks.nameColors = { accountId in
            return manager.dispatchNameColors(account: accountId)
        }

        hooks.themeOverride = { accountId in
            guard manager.hasLoadedPlugins else {
                return nil
            }
            return manager.dispatchThemeOverride(account: accountId)
        }

        hooks.messageDetails = { accountId, messageJSON in
            guard manager.hasLoadedPlugins else {
                return []
            }
            return manager.dispatchMessageDetails(account: accountId, messageJSON: messageJSON)
        }

        // Asked per row while a chat list is built, and only after
        // `wantsHideMessage` said a plugin listens: the caller gates the loop
        // with that one question, so there is no second `hasPluginForHook` here.
        // Re-asking it per row would double every row's round trip into the
        // script queue for an answer that cannot change mid-loop.
        hooks.hideMessage = { accountId, messageJSON in
            guard manager.hasLoadedPlugins else {
                return false
            }
            return manager.dispatchHideMessage(account: accountId, messageJSON: messageJSON)
        }

        // Asked once per history view. A chat with a thousand messages must not
        // encode each of them only to be told nobody listens.
        hooks.wantsHideMessage = {
            guard manager.hasLoadedPlugins else {
                return false
            }
            return manager.hasPluginForHook("on_hide_message")
        }

        // The messages the user deletes himself. The server never announces
        // them, so this is the only chance a plugin gets to keep them; the
        // caller asks `wantsMessagesWillBeDeleted` once, before describing any
        // message, and then hands the description to a detached dispatch.
        hooks.wantsMessagesWillBeDeleted = {
            guard manager.hasLoadedPlugins else {
                return false
            }
            // Read from the flag `loadAllOnQueue` warms once per load, not from
            // `hasPluginForHook`: the account state asks this on its own queue
            // right before opening a postbox transaction, and running script
            // there would block every database reader behind plugin code.
            return manager.messagesWillBeDeletedHookCached
        }

        hooks.messagesWillBeDeleted = { accountId, messagesJSON in
            guard manager.hasLoadedPlugins else {
                return
            }
            manager.dispatchMessagesWillBeDeleted(account: accountId, messagesJSON: messagesJSON)
        }

        // Rows a plugin kept after the message was deleted. Asked once per
        // history view and only when `wantsDeletedMessages` said a plugin keeps
        // copies: a chat with a thousand messages must not run script for a
        // plugin that never stored anything.
        hooks.wantsDeletedMessages = {
            guard manager.hasLoadedPlugins else {
                return false
            }
            return manager.deletedMessagesHookCached
        }

        hooks.deletedMessages = { accountId, peerId in
            guard manager.hasLoadedPlugins else {
                return []
            }
            return manager.dispatchDeletedMessages(account: accountId, peerId: peerId)
        }

        // Forgetting a saved copy when the user deletes its row. A saved row is
        // not in the database, so the delete path cannot drop it; it asks here
        // and the list rebuilds without the row. `canForgetDeletedMessages` reads
        // the flag warmed at load, so the delete path never runs script itself.
        hooks.canForgetDeletedMessages = {
            guard manager.hasLoadedPlugins else {
                return false
            }
            return manager.canForgetDeletedMessagesHookCached
        }

        hooks.forgetDeletedMessages = { accountId, peerId, messageIds in
            guard manager.hasLoadedPlugins else {
                return
            }
            manager.dispatchForgetDeletedMessages(account: accountId, peerId: peerId, messageIds: messageIds)
        }

        // The screenshots switch (RFS). Applied once, at startup and whenever a
        // setting changes, rather than per screen: the answer flips one flag in
        // the layer primitive that every protected layer goes through.
        //
        // The initial apply has to run on the main queue and after the plugins
        // have loaded — protection is requested while the first frame is built,
        // which is before `startLoading` gets to run the scripts. `PluginManager`
        // already pushes an appearance-changed event once its load finished, and
        // that is the signal this reads.
        self.screenshotOverrideDisposable?.dispose()
        self.screenshotOverrideDisposable = (PluginHookPoints.shared.appearanceChanged
        |> deliverOnMainQueue).start(next: { [weak self] in
            self?.applyScreenshotOverride()
        })
    }

    /// Reads every plugin's answer to "allow screenshots" and applies the result.
    ///
    /// Runs on the main queue: the answer decides what the next
    /// `setLayerDisableScreenshots` call does, and clearing the layers that were
    /// already protected means walking the window tree.
    private func applyScreenshotOverride() {
        let manager = PluginManager.shared
        guard manager.hasLoadedPlugins else {
            // No plugin, or every plugin was just unloaded: put the stock
            // behaviour back, or a removed plugin would keep the screenshots
            // allowed for the rest of the session.
            self.setScreenshotOverride(false, clearProtected: false)
            return
        }
        let account = self.actions.primaryAccountId
        let allowed = manager.dispatchAllowScreenshots(account: account)
        self.setScreenshotOverride(allowed, clearProtected: allowed)
    }

    /// Applies the answer, and clears the layers that were protected before it.
    ///
    /// A layer marked earlier keeps its marking: the flag only stops *future*
    /// requests from taking effect. Turning the switch on therefore has to walk
    /// what is on screen and unmark it, or the chat the user is looking at would
    /// stay uncapturable until it is rebuilt. Turning it off only removes the
    /// flag: the screens the app rebuilds mark themselves again, and re-marking
    /// every layer in the tree would protect views that are not media at all.
    ///
    /// The sweep runs only when the answer changes, not on every appearance
    /// rebuild: once the flag is on, no new layer is marked, so there is nothing
    /// left to clear and walking the tree again would cost a full pass per theme
    /// change for no effect.
    private func setScreenshotOverride(_ allowed: Bool, clearProtected: Bool) {
        if self.screenshotOverrideApplied == allowed {
            return
        }
        self.screenshotOverrideApplied = allowed
        setScreenshotsAllowedGlobally(allowed)
        guard clearProtected else {
            return
        }
        // `UIApplication.shared.windows` is deprecated, and this target builds with
        // warnings as errors; the scenes are the supported route and they also
        // cover a second, non-key window (an overlay one).
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else {
                continue
            }
            for window in windowScene.windows {
                Self.clearScreenshotProtection(in: window.layer)
            }
        }
    }

    /// Unmarks every protected layer below `layer`, depth first.
    ///
    /// `setScreenshotProtection` is cheap for an unmarked layer (one associated
    /// object read), so walking everything is simpler and safer than trying to
    /// find the media nodes among it.
    private static func clearScreenshotProtection(in layer: CALayer) {
        if isScreenshotProtected(layer) {
            setScreenshotProtection(layer, false)
        }
        for sublayer in layer.sublayers ?? [] {
            clearScreenshotProtection(in: sublayer)
        }
    }

    /// Mirrors exteraGram's `on_app_event`: `START` at launch, then `PAUSE` and
    /// `RESUME` as the app moves between the two. Driving this from the
    /// application-bindings signal keeps the fix inside one file instead of
    /// spreading it over every `UIApplicationDelegate` callback.
    /// Tells every plugin the app is going away.
    ///
    /// `applicationWillTerminate` is the only place an iOS app is told this, and
    /// it is not guaranteed on a kill from the app switcher; it is the closest
    /// equivalent of the SDK's `STOP` event followed by its unload-on-shutdown.
    /// Unlike the running-app lifecycle events this has to be synchronous: the
    /// process can be torn down as soon as the delegate method returns, so a
    /// dispatched event would simply never run.
    public func shutdown() {
        PluginManager.shared.shutdown()
    }

    private func observeLifecycle(sharedContext: SharedAccountContext) {
        self.lifecycleDisposable?.dispose()
        self.lifecycleDisposable = (sharedContext.applicationBindings.applicationInForeground
        |> deliverOnMainQueue).start(next: { [weak self] value in
            // The first emission describes the state the app is already in, not a
            // transition; `START` already reported it, and a launch straight into
            // the background must not tell a plugin the app became visible.
            guard let self = self else {
                return
            }
            let previous = self.wasInForeground
            self.wasInForeground = value
            if previous == nil || previous == value {
                return
            }
            PluginManager.shared.broadcastAppEvent(value ? "RESUME" : "PAUSE")
        })
    }

    // MARK: - Helpers

    /// True while the runtime is enqueueing a message a plugin asked for.
    ///
    /// Thread-local rather than a shared flag: `enqueueMessages` calls the send
    /// hook synchronously on the calling thread, and two sends on different
    /// queues must not see each other's marker.
    private static let pluginSendKey = "extera.pluginkit.sendingFromPlugin"

    static var isSendingFromPlugin: Bool {
        return (Thread.current.threadDictionary[PluginRuntime.pluginSendKey] as? Bool) ?? false
    }

    static func withPluginSend<T>(_ body: () -> T) -> T {
        Thread.current.threadDictionary[PluginRuntime.pluginSendKey] = true
        defer {
            Thread.current.threadDictionary.removeObject(forKey: PluginRuntime.pluginSendKey)
        }
        return body()
    }

    /// Shared with `PluginActionsImpl`, the other type in this file that parses
    /// the same JSON documents; `private` would confine it to `PluginRuntime`.
    fileprivate static func parseObject(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object
    }
}

/// The side effects plugins can ask for, implemented against a real account.
///
/// Every entry point hops to the main queue first: these methods are called from
/// inside plugin JavaScript while the manager holds its script queue, and a
/// plugin must never be able to stall (or deadlock) the network queue it was
/// called from.
private final class PluginActionsImpl: PluginActions {
    weak var sharedContext: SharedAccountContext?

    /// Every signed-in account, by the id a plugin passes as `account=`.
    ///
    /// Main-queue only: `activate` fills it from `activeAccountContexts`, and all
    /// the methods below read it after hopping to the main queue. exteraGram's
    /// account ids are indices into the logged-in list; here they are the real
    /// account ids, and an unknown one falls back to the primary account rather
    /// than failing a send the plugin expected to work.
    var contexts: [Int64: AccountContext] = [:]
    var primaryAccountId: Int64?

    /// In-flight bridge requests, in the order they started.
    ///
    /// A bridge answer arrives asynchronously and the signal stops if its
    /// disposable is released, so every one has to stay alive somewhere. This is
    /// that place: `startBridge` appends, the `completed:` closure removes. Guarded
    /// by `bridgeLock` because `ownPeerId` resolves on the main queue while an HTTP
    /// answer arrives on a session queue.
    fileprivate var pendingBridges: [MetaDisposable] = []
    fileprivate let bridgeLock = NSLock()

    private func resolve(_ account: Int64?) -> AccountContext? {
        if let account = account, let context = self.contexts[account] {
            return context
        }
        if let primary = self.primaryAccountId, let context = self.contexts[primary] {
            return context
        }
        return self.contexts.values.first
    }

    // MARK: - Messages

    func sendText(account: Int64?, peerId: Int64, text: String, options: PluginSendOptions) {
        Queue.mainQueue().async {
            guard let context = self.resolve(account) else {
                self.reportMissingAccount()
                return
            }
            // When the plugin asked for `parse_mode`, the bootstrap already turned
            // the text into entities; otherwise only bare links and mentions are
            // detected, which is what the composer does.
            let content = Self.messageContent(text: text, entitiesJSON: options.entitiesJSON)
            let _ = PluginRuntime.withPluginSend {
                enqueuePluginMessage(
                    account: context.account,
                    peerId: peerId,
                    replyToMessageId: options.replyToMessageId,
                    silentPosting: options.silent,
                    content: .text(content.text, content.entities)
                ).start()
            }
        }
    }

    func editMessage(account: Int64?, peerId: Int64, messageId: Int64, text: String, options: PluginSendOptions) {
        Queue.mainQueue().async {
            guard let context = self.resolve(account) else {
                self.reportMissingAccount()
                return
            }
            let content = Self.messageContent(text: text, entitiesJSON: options.entitiesJSON)
            let _ = editPluginMessage(
                account: context.account,
                peerId: peerId,
                messageId: messageId,
                text: content.text,
                entities: content.entities
            ).start()
        }
    }

    func sendFile(account: Int64?, kind: String, peerId: Int64, path: String, options: PluginSendOptions) {
        Queue.mainQueue().async {
            guard let context = self.resolve(account) else {
                self.reportMissingAccount()
                return
            }
            let fileManager = FileManager.default
            guard fileManager.fileExists(atPath: path) else {
                self.presentBulletin(json: "{\"kind\":\"error\",\"text\":\"Plugin file not found\"}", pluginId: nil)
                return
            }
            let size = (try? fileManager.attributesOfItem(atPath: path))?[.size] as? NSNumber

            // A photo is uploaded as an image so it arrives as a picture bubble;
            // anything else (including an undecodable image) goes as a document.
            // Only this layer has a `UIImage`, so the pixel size is measured here
            // and the engine builds the matching media.
            var photoDimensions: PixelDimensions?
            if kind == "photo", let image = UIImage(contentsOfFile: path), image.size.width > 0.0, image.size.height > 0.0 {
                photoDimensions = PixelDimensions(
                    width: Int32(min(image.size.width * image.scale, 4096.0)),
                    height: Int32(min(image.size.height * image.scale, 4096.0))
                )
            }

            let caption = Self.messageContent(text: options.caption ?? "", entitiesJSON: options.captionEntitiesJSON)

            let _ = PluginRuntime.withPluginSend {
                enqueuePluginMessage(
                    account: context.account,
                    peerId: peerId,
                    replyToMessageId: options.replyToMessageId,
                    silentPosting: options.silent,
                    content: .localFile(
                        path: path,
                        mimeType: Self.mimeType(forPath: path),
                        fileName: (path as NSString).lastPathComponent,
                        size: size?.int64Value,
                        photoDimensions: photoDimensions,
                        caption: caption.text,
                        captionEntities: caption.entities
                    )
                ).start()
            }
        }
    }

    func selectedAccountId() -> Int64? {
        return self.primaryAccountId
    }

    /// The colours the running theme uses, keyed by the names a plugin asked for.
    ///
    /// Only the handful of slots a "take the colour from the theme" picker can
    /// offer are mapped; an unknown name is simply absent from the answer, which
    /// the plugin reads as "no such source in this build". Everything comes off
    /// the current `PresentationData`, so the answer is the colour on screen
    /// right now rather than the one that was there at launch.
    func themeColors(names: [String]) -> [String: UInt32] {
        guard let sharedContext = self.sharedContext else {
            return [:]
        }
        let presentationData = sharedContext.currentPresentationData.with { $0 }
        let theme = presentationData.theme
        var result: [String: UInt32] = [:]
        for name in names {
            switch name {
            case "accent", "accentTextColor":
                result[name] = theme.chat.message.outgoing.accentTextColor.rgb
            case "button", "addButton":
                result[name] = theme.list.itemAccentColor.rgb
            case "header", "accentHeader":
                result[name] = theme.rootController.navigationBar.accentTextColor.rgb
            case "link", "linkText":
                result[name] = theme.chat.message.incoming.linkTextColor.rgb
            case "floatingButton", "actionControl":
                result[name] = theme.chat.inputPanel.panelControlAccentColor.rgb
            case "outgoing", "outBubble":
                result[name] = theme.chat.message.outgoing.bubble.withWallpaper.fill.first?.rgb
                    ?? theme.chat.message.outgoing.bubble.withoutWallpaper.fill.first?.rgb
                    ?? theme.list.itemAccentColor.rgb
            case "navigationBar":
                result[name] = theme.rootController.navigationBar.buttonColor.rgb
            case "actionSheet":
                result[name] = theme.actionSheet.controlAccentColor.rgb
            default:
                break
            }
        }
        return result
    }

    /// Puts text on the pasteboard and confirms it, which is what
    /// `copy_to_clipboard` shows on Android. The confirmation is the plugin's own
    /// bulletin if it asks for one; here it is the app's standard "copied" toast,
    /// so a plugin that copies and says nothing still gives feedback.
    func copyToClipboard(pluginId: String, text: String) {
        Queue.mainQueue().async {
            UIPasteboard.general.string = text
            guard let sharedContext = self.sharedContext else {
                return
            }
            let presentationData = sharedContext.currentPresentationData.with { $0 }
            sharedContext.presentGlobalController(
                UndoOverlayController(
                    presentationData: presentationData,
                    content: .copy(text: presentationData.strings.Conversation_TextCopied),
                    elevatedLayout: false,
                    action: { _ in return false }
                ),
                nil
            )
        }
    }

    /// `android_utils.open_url`. `Browser.openUrl` on Android picks the in-app
    /// browser for web pages and the system handler for other schemes; the app's
    /// own `openUrl` binding already makes that same decision, so this is a thin
    /// hop to the main queue.
    func openUrl(pluginId: String, url: URL) {
        Queue.mainQueue().async {
            self.sharedContext?.applicationBindings.openUrl(url.absoluteString)
        }
    }

    /// Opens the plugin list screen, which is what a row with
    /// `link_alias="plugins"` points at.
    ///
    /// The screen is pushed in its own navigation controller and presented over
    /// the current window, because the row that asked for it is inside a plugin
    /// settings page that may itself have been presented, and there is no shared
    /// navigation stack the runtime can reach. Presenting the same list the
    /// settings entry shows keeps one implementation of the screen.
    func openPluginSettings() {
        Queue.mainQueue().async {
            guard let sharedContext = self.sharedContext,
                  let context = self.resolve(self.primaryAccountId) else {
                return
            }
            let controller = pluginsController(context: context)
            let navigation = UINavigationController(rootViewController: controller)
            navigation.modalPresentationStyle = .formSheet
            sharedContext.applicationBindings.presentNativeController(navigation)
        }
    }

    // MARK: - Network and proxy
    //
    // These five bridges are the reason a plugin does not need Python: fetching a
    // subscription, editing the proxy list and finding Saved Messages all live
    // here, behind one callback token each. Nothing in this section touches the
    // account manager's queue synchronously: the answer is always delivered by
    // `resolveBridgeCallback` after the signal emits.

    /// `http_get`: one GET request, resolved into the plugin's callback.
    ///
    /// Every non-2xx status and every transport failure comes back as
    /// `{"ok": false, "error": "..."}` rather than a thrown exception, because a
    /// plugin's refresh routine usually walks several mirrors and has to report
    /// which one failed. A `2xx` answer carries the body, the status and the
    /// lowercased headers.
    func httpGet(pluginId: String, url: String, headersJSON: String, timeout: Double, callbackToken: String) {
        self.performHttp(
            pluginId: pluginId,
            method: "GET",
            url: url,
            headersJSON: headersJSON,
            body: nil,
            timeout: timeout,
            callbackToken: callbackToken
        )
    }

    /// A request with an explicit method and body, for `http.post` and the rest.
    ///
    /// `bodyBase64` carries the body because the bridge is text-only and an
    /// upload is not necessarily UTF-8; a body that does not decode is reported
    /// to the plugin as a failure rather than sent empty, which would be a
    /// silently different request.
    func httpRequest(pluginId: String, method: String, url: String, headersJSON: String, bodyBase64: String?, timeout: Double, callbackToken: String) {
        var body: Data?
        if let bodyBase64 = bodyBase64, !bodyBase64.isEmpty {
            guard let decoded = Data(base64Encoded: bodyBase64) else {
                PluginManager.shared.resolveBridgeCallback(
                    pluginId: pluginId,
                    token: callbackToken,
                    response: ["ok": false, "error": "the request body is not valid base64"]
                )
                return
            }
            body = decoded
        }
        self.performHttp(
            pluginId: pluginId,
            method: method,
            url: url,
            headersJSON: headersJSON,
            body: body,
            timeout: timeout,
            callbackToken: callbackToken
        )
    }

    private func performHttp(pluginId: String, method: String, url: String, headersJSON: String, body: Data?, timeout: Double, callbackToken: String) {
        var headers: [String: String] = [:]
        if let data = headersJSON.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (key, value) in object {
                if let value = value as? String {
                    headers[key] = value
                }
            }
        }

        self.startBridge { completed in
            return PluginHttpAccess.request(pluginId: pluginId, method: method, url: url, headers: headers, body: body, timeout: timeout).start(next: { response in
                var result: [String: Any] = [
                    "ok": response.status >= 200 && response.status < 300,
                    "status": response.status,
                    "text": String(data: response.body, encoding: .utf8) ?? "",
                    "headers": response.headers,
                ]
                if response.status < 200 || response.status >= 300 {
                    result["error"] = "HTTP \(response.status)"
                }
                PluginManager.shared.resolveBridgeCallback(pluginId: pluginId, token: callbackToken, response: result)
            }, error: { failure in
                PluginManager.shared.resolveBridgeCallback(
                    pluginId: pluginId,
                    token: callbackToken,
                    response: ["ok": false, "error": failure.description]
                )
                // A signal that fails never calls `completed:`, and the bridge
                // handle is released only from that closure. Releasing it here
                // is what keeps a rejected request (a bad URL, the throttle)
                // from staying in the in-flight list for the session.
                completed()
            }, completed: completed)
        }
    }

    /// The proxy list as the app currently holds it.
    ///
    /// Each entry is re-serialised as a link instead of raw host/port, so a plugin
    /// that exports the list produces exactly the `tg://` links the client itself
    /// would have written. `kind` is derived from the connection so a plugin can
    /// filter without re-parsing the link.
    func proxyList(pluginId: String, callbackToken: String) {
        guard let sharedContext = self.sharedContext else {
            self.failBridge(pluginId: pluginId, token: callbackToken, error: "no account is available")
            return
        }
        self.startBridge { completed in
            return PluginProxyAccess.servers(accountManager: sharedContext.accountManager).start(next: { servers in
                let entries: [[String: Any]] = servers.map { server in
                    return [
                        "link": PluginProxyAccess.link(for: server) ?? "",
                        "kind": PluginProxyAccess.kind(for: server),
                        "host": server.host,
                        "port": Int(server.port),
                    ]
                }
                PluginManager.shared.resolveBridgeCallback(
                    pluginId: pluginId,
                    token: callbackToken,
                    response: ["ok": true, "servers": entries]
                )
            }, completed: completed)
        }
    }

    /// Adds the links a plugin collected.
    ///
    /// Duplicates are counted rather than treated as an error: a subscription that
    /// refreshes on every launch adds nothing the second time, and the plugin's
    /// report can say so.
    func proxyAdd(pluginId: String, linksJSON: String, callbackToken: String) {
        guard let sharedContext = self.sharedContext else {
            self.failBridge(pluginId: pluginId, token: callbackToken, error: "no account is available")
            return
        }
        var links: [String] = []
        if let data = linksJSON.data(using: .utf8),
           let list = try? JSONSerialization.jsonObject(with: data) as? [Any] {
            links = list.compactMap { $0 as? String }
        }
        self.startBridge { completed in
            return PluginProxyAccess.add(accountManager: sharedContext.accountManager, links: links).start(next: { result in
                PluginManager.shared.resolveBridgeCallback(
                    pluginId: pluginId,
                    token: callbackToken,
                    response: [
                        "ok": true,
                        "added": result.added,
                        "duplicates": result.duplicates,
                        "invalid": result.invalid,
                    ]
                )
            }, completed: completed)
        }
    }

    /// Empties the proxy list and reports how many entries were dropped.
    func proxyRemoveAll(pluginId: String, callbackToken: String) {
        guard let sharedContext = self.sharedContext else {
            self.failBridge(pluginId: pluginId, token: callbackToken, error: "no account is available")
            return
        }
        self.startBridge { completed in
            return PluginProxyAccess.removeAll(accountManager: sharedContext.accountManager).start(next: { removed in
                PluginManager.shared.resolveBridgeCallback(
                    pluginId: pluginId,
                    token: callbackToken,
                    response: ["ok": true, "removed": removed]
                )
            }, completed: completed)
        }
    }

    /// The account's own user id, which is exactly Saved Messages: exporting a
    /// proxy list to yourself is a send to this peer.
    func ownPeerId(pluginId: String, account: Int64?, callbackToken: String) {
        Queue.mainQueue().async {
            guard let context = self.resolve(account) else {
                self.failBridge(pluginId: pluginId, token: callbackToken, error: "no account is available")
                return
            }
            // `account.peerId` is a Postbox `PeerId`; the conversion lives in
            // TelegramCore so this module stays free of Postbox.
            PluginManager.shared.resolveBridgeCallback(
                pluginId: pluginId,
                token: callbackToken,
                response: ["ok": true, "peer_id": pluginSavedMessagesPeerId(account: context.account)]
            )
        }
    }

    private func failBridge(pluginId: String, token: String, error: String) {
        PluginManager.shared.resolveBridgeCallback(
            pluginId: pluginId,
            token: token,
            response: ["ok": false, "error": error]
        )
    }

    /// One peer's profile, behind `get_contacts_controller().get_peer(...)`.
    ///
    /// `PluginControllerAccess` resolves it off the account's own queues and
    /// hands back plain values, so nothing engine-shaped crosses into the bridge.
    /// A peer the client has never seen answers `{"ok": true, "peer": null}`
    /// rather than an error: "no such peer" is a legitimate answer a plugin
    /// branches on, not a failure.
    func peerInfo(pluginId: String, account: Int64?, peerId: Int64, callbackToken: String) {
        Queue.mainQueue().async {
            guard let context = self.resolve(account) else {
                self.failBridge(pluginId: pluginId, token: callbackToken, error: "no account is available")
                return
            }
            self.startBridge { completed in
                return PluginControllerAccess.peerInfo(account: context.account, peerId: peerId).start(next: { info in
                    PluginManager.shared.resolveBridgeCallback(
                        pluginId: pluginId,
                        token: callbackToken,
                        response: ["ok": true, "peer": info?.json ?? NSNull()]
                    )
                }, completed: completed)
            }
        }
    }

    /// The most recent messages of one chat, behind
    /// `get_messages_controller().get_messages(...)`.
    func chatMessages(pluginId: String, account: Int64?, peerId: Int64, limit: Int, callbackToken: String) {
        Queue.mainQueue().async {
            guard let context = self.resolve(account) else {
                self.failBridge(pluginId: pluginId, token: callbackToken, error: "no account is available")
                return
            }
            self.startBridge { completed in
                return PluginControllerAccess.chatMessages(account: context.account, peerId: peerId, limit: limit).start(next: { messages in
                    PluginManager.shared.resolveBridgeCallback(
                        pluginId: pluginId,
                        token: callbackToken,
                        response: ["ok": true, "messages": messages.map { $0.json }]
                    )
                }, completed: completed)
            }
        }
    }

    // MARK: - Bridge lifetime
    //
    // `Signal.start` hands back the disposable that keeps the work alive, so
    // dropping it right after the call would cancel every request before it
    // finished. Each one is kept here until its signal completes, then released:
    // a plugin that refreshes on every launch must not accumulate subscriptions.

    /// Starts `body`, retaining the disposable until it completes.
    ///
    /// `body` receives the closure it must pass as `completed:`; all the bridge
    /// signals emit once and then complete, so that is exactly the lifetime of
    /// one request. A `MetaDisposable` holds the subscription while it runs and
    /// is removed from the list the moment it finishes.
    @discardableResult
    private func startBridge(_ body: (@escaping () -> Void) -> Disposable) -> Disposable {
        let handle = MetaDisposable()
        // Registered before the body runs: a signal that fails validation
        // completes synchronously inside `start`, and the completion path would
        // then remove a handle that had not been appended yet, leaking it.
        self.bridgeLock.lock()
        self.pendingBridges.append(handle)
        self.bridgeLock.unlock()

        let disposable = body { [weak self, weak handle] in
            guard let self = self, let handle = handle else {
                return
            }
            self.releaseBridge(handle)
        }
        // A handle released by a synchronous completion is already disposed, and
        // `MetaDisposable.set` disposes the subscription straight away in that
        // case instead of starting work nobody will collect.
        handle.set(disposable)
        return handle
    }

    private func releaseBridge(_ handle: MetaDisposable) {
        self.bridgeLock.lock()
        if let index = self.pendingBridges.firstIndex(where: { $0 === handle }) {
            self.pendingBridges.remove(at: index)
        }
        self.bridgeLock.unlock()
        handle.dispose()
    }

    /// Drops every in-flight bridge request.
    ///
    /// Called when the runtime goes away; a request whose plugin no longer exists
    /// has nowhere to deliver its answer.
    func cancelPendingBridges() {
        self.bridgeLock.lock()
        let pending = self.pendingBridges
        self.pendingBridges = []
        self.bridgeLock.unlock()
        for handle in pending {
            handle.dispose()
        }
    }

    // MARK: - Bulletins

    /// Shows one of `ui.bulletin`'s variants.
    ///
    /// The JSON is whatever the bootstrap built: a `kind`, the text, and for the
    /// variants that carry one, a token standing in for a callback. A token is
    /// handed back to `runPluginCallback` when the user taps, because a function
    /// cannot cross the bridge.
    func showBulletin(pluginId: String, kind: String, json: String) {
        Queue.mainQueue().async {
            self.presentBulletin(json: json, pluginId: pluginId, fallbackKind: kind)
        }
    }

    private func presentBulletin(json: String, pluginId: String?, fallbackKind: String = "info") {
        guard let sharedContext = self.sharedContext else {
            return
        }
        let object = PluginRuntime.parseObject(json)
        let kind = (object["kind"] as? String) ?? fallbackKind
        let text = (object["text"] as? String) ?? ""
        let title = object["title"] as? String
        let presentationData = sharedContext.currentPresentationData.with { $0 }
        let content: UndoOverlayContent
        var action: (UndoOverlayAction) -> Bool = { _ in return false }

        switch kind {
        case "button":
            // exteraGram's `show_with_button`: an info bulletin whose right-hand
            // button runs a callback. The button is the toast's trailing button,
            // and pressing it reports `.undo` (the toast's own "action" role).
            let buttonText = (object["button"] as? String) ?? presentationData.strings.Common_OK
            let token = object["token"] as? String
            content = .info(title: title, text: text, timeout: Self.timeout(object), customUndoText: buttonText)
            action = { value in
                switch value {
                case .undo, .info:
                    if let token = token {
                        Self.runCallback(token: token, pluginId: pluginId)
                    }
                default:
                    break
                }
                return true
            }

        case "undo":
            let undoText = (object["undo_text"] as? String) ?? presentationData.strings.Undo_Undo
            let undoToken = object["undo_token"] as? String
            let actionToken = object["action_token"] as? String
            content = .actionSucceeded(
                title: title,
                text: text,
                cancel: undoText,
                destructive: (object["destructive"] as? Bool) ?? false
            )
            action = { value in
                switch value {
                case .undo:
                    if let undoToken = undoToken {
                        Self.runCallback(token: undoToken, pluginId: pluginId)
                    }
                case .commit:
                    if let actionToken = actionToken {
                        Self.runCallback(token: actionToken, pluginId: pluginId)
                    }
                default:
                    break
                }
                return true
            }

        case "copied":
            content = .copy(text: text.isEmpty ? presentationData.strings.Conversation_TextCopied : text)

        case "link_copied":
            content = .linkCopied(title: title, text: text.isEmpty ? presentationData.strings.Conversation_LinkCopied : text)

        case "saved_gallery":
            let isVideo = (object["video"] as? Bool) ?? false
            content = .mediaSaved(text: isVideo ? presentationData.strings.Gallery_VideoSaved : presentationData.strings.Gallery_ImageSaved)

        case "saved_downloads":
            content = .mediaSaved(text: text.isEmpty ? presentationData.strings.Gallery_ImagesAndVideosSaved : text)

        case "success", "succeed", "ok":
            content = .succeed(text: text, timeout: Self.timeout(object), customUndoText: nil)

        case "error", "failure":
            // There is no dedicated error bulletin; an info one carrying the
            // plugin's own wording is what exteraGram shows too.
            content = .info(title: title ?? "Plugin", text: text, timeout: Self.timeout(object), customUndoText: nil)

        default:
            content = .info(title: title, text: text, timeout: Self.timeout(object), customUndoText: nil)
        }

        sharedContext.presentGlobalController(
            UndoOverlayController(
                presentationData: presentationData,
                content: content,
                elevatedLayout: false,
                action: action
            ),
            nil
        )
    }

    /// `ui.bulletin.DURATION_*` are milliseconds; `UndoOverlayContent` wants
    /// seconds. A missing value falls back to the three-second default.
    private static func timeout(_ object: [String: Any]) -> Double {
        if let value = object["duration"] as? NSNumber, value.doubleValue > 0.0 {
            return value.doubleValue / 1000.0
        }
        return 3.0
    }

    private static func runCallback(token: String, pluginId: String?) {
        guard let pluginId = pluginId else {
            return
        }
        PluginManager.shared.runPluginCallback(pluginId: pluginId, token: token)
    }

    // MARK: - Alerts

    /// `ui.alert.AlertDialogBuilder().show()`.
    ///
    /// One alert is tracked per plugin, so a `dismiss()` from the plugin closes
    /// the dialog the same plugin opened and nothing else.
    func showAlert(pluginId: String, json: String) {
        // `[weak self]` on the outer closure, not just the per-button one: an
        // inner capture list cannot weaken a `self` the enclosing closure has
        // already captured strongly, and the compiler rejects the mismatch.
        Queue.mainQueue().async { [weak self] in
            guard let sharedContext = self?.sharedContext else {
                return
            }
            let object = PluginRuntime.parseObject(json)
            let title = object["title"] as? String
            let message = (object["message"] as? String) ?? ""
            let buttons = (object["buttons"] as? [[String: Any]]) ?? []
            let presentationData = sharedContext.currentPresentationData.with { $0 }

            // No `self` in here at all: the alert controller outlives this
            // closure (it is kept in `alerts`), so the button action must not
            // hold the runtime's implementation alive through the controller it
            // owns. `runCallback` is a one-line forward to the manager, so
            // calling it directly is the same thing without the capture.
            let runToken: (String) -> Void = { token in
                PluginManager.shared.runPluginCallback(pluginId: pluginId, token: token)
            }

            var actions: [TextAlertAction] = []
            for button in buttons {
                guard let text = button["text"] as? String else {
                    continue
                }
                let token = button["token"] as? String
                let role = (button["role"] as? String) ?? "positive"
                // exteraGram's `set_negative_button` is the destructive one on
                // Android; the same role reads correctly here.
                let type: TextAlertActionType
                switch role {
                case "negative":
                    type = .defaultDestructiveAction
                case "neutral":
                    type = .genericAction
                default:
                    type = .defaultAction
                }
                actions.append(TextAlertAction(type: type, title: text, action: {
                    if let token = token {
                        runToken(token)
                    }
                }))
            }
            if actions.isEmpty {
                actions.append(TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {}))
            }

            let controller = textAlertController(
                sharedContext: sharedContext,
                title: title,
                text: message,
                actions: actions,
                dismissOnOutsideTap: (object["cancelable"] as? Bool) ?? true
            )
            // Remembered so `dismiss()` can close this exact dialog, and replaced
            // when the plugin shows another one. Nothing else in the app knows
            // about it, so a dialog the user swiped away simply stays referenced
            // until the plugin's next alert or its unload.
            self?.alerts[pluginId] = controller
            sharedContext.presentGlobalController(controller, nil)
        }
    }

    func dismissAlert(pluginId: String) {
        Queue.mainQueue().async {
            guard let controller = self.alerts.removeValue(forKey: pluginId) else {
                return
            }
            controller.dismiss()
        }
    }

    private var alerts: [String: ViewController] = [:]

    private func reportMissingAccount() {
        guard let sharedContext = self.sharedContext else {
            return
        }
        let presentationData = sharedContext.currentPresentationData.with { $0 }
        sharedContext.presentGlobalController(
            UndoOverlayController(presentationData: presentationData, content: .info(title: "Plugin", text: "No account is signed in.", timeout: 3.0, customUndoText: nil), elevatedLayout: false, action: { _ in
                return false
            }),
            nil
        )
    }

    // MARK: - Message building

    /// Turns plugin text into entities.
    ///
    /// When the plugin used `parse_mode`, the JavaScript side already resolved the
    /// formatting into entities, and `entitiesJSON` carries them: HTML and Markdown
    /// are parsed by exactly one implementation there, instead of duplicated here
    /// with its own set of supported tags. Without `parse_mode` only bare links,
    /// mentions and hashtags are detected, which is what sending plain text does.
    ///
    /// Only entities cross the module boundary: wrapping them in a
    /// `TextEntitiesMessageAttribute` is the engine's job, because that attribute
    /// is a Postbox type.
    private static func messageContent(text: String, entitiesJSON: String?) -> (text: String, entities: [MessageTextEntity]) {
        if let entitiesJSON = entitiesJSON,
           let data = entitiesJSON.data(using: .utf8),
           let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
           !list.isEmpty {
            return (text, list.compactMap { messageEntity(from: $0) })
        }
        return (text, generateTextEntities(text, enabledTypes: .all))
    }

    /// One entity as the bootstrap encoded it.
    ///
    /// The offsets are UTF-16 units, which is what both JavaScript and
    /// `NSAttributedString` count in, so no conversion is needed here.
    private static func messageEntity(from object: [String: Any]) -> MessageTextEntity? {
        guard let offset = (object["offset"] as? NSNumber)?.intValue,
              let length = (object["length"] as? NSNumber)?.intValue,
              length > 0 else {
            return nil
        }
        let type = (object["type"] as? String) ?? ""
        let entityType: MessageTextEntityType
        switch type {
        case "bold":
            entityType = .Bold
        case "italic":
            entityType = .Italic
        case "underline":
            entityType = .Underline
        case "strikethrough":
            entityType = .Strikethrough
        case "spoiler":
            entityType = .Spoiler
        case "code":
            entityType = .Code
        case "pre":
            entityType = .Pre(language: object["language"] as? String)
        case "text_link":
            entityType = .TextUrl(url: (object["url"] as? String) ?? "")
        case "blockquote":
            entityType = .BlockQuote(isCollapsed: (object["collapsed"] as? Bool) ?? false)
        case "custom_emoji":
            let fileId = (object["document_id"] as? NSString)?.longLongValue ?? 0
            entityType = .CustomEmoji(stickerPack: nil, fileId: fileId)
        default:
            return nil
        }
        return MessageTextEntity(range: offset ..< (offset + length), type: entityType)
    }

    private static func mimeType(forPath path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg":
            return "image/jpeg"
        case "png":
            return "image/png"
        case "gif":
            return "image/gif"
        case "webp":
            return "image/webp"
        case "mp4", "m4v":
            return "video/mp4"
        case "mov":
            return "video/quicktime"
        case "mp3":
            return "audio/mpeg"
        case "m4a":
            return "audio/mp4"
        case "ogg", "opus":
            return "audio/ogg"
        case "pdf":
            return "application/pdf"
        case "zip":
            return "application/zip"
        case "txt":
            return "text/plain"
        case "json":
            return "application/json"
        default:
            return "application/octet-stream"
        }
    }
}
