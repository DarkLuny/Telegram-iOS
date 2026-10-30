import Foundation
import UIKit
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import TextFormat
import AccountContext
import UndoUI
import Display

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
            self.activeContext = primary
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

    private static func parseObject(_ json: String) -> [String: Any] {
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
        Queue.mainQueue().async {
            guard let sharedContext = self.sharedContext else {
                return
            }
            let object = PluginRuntime.parseObject(json)
            let title = object["title"] as? String
            let message = (object["message"] as? String) ?? ""
            let buttons = (object["buttons"] as? [[String: Any]]) ?? []
            let presentationData = sharedContext.currentPresentationData.with { $0 }

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
                actions.append(TextAlertAction(type: type, title: text, action: { [weak self] in
                    if let token = token {
                        self?.runCallback(token: token, pluginId: pluginId)
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
            self.alerts[pluginId] = controller
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

    private func runCallback(token: String, pluginId: String) {
        PluginManager.shared.runPluginCallback(pluginId: pluginId, token: token)
    }

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
