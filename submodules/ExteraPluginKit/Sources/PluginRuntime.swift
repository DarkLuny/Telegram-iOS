import Foundation
import UIKit
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import TextFormat
import AccountContext
import UndoUI

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

    private weak var activeContext: AccountContext?
    private var foregroundDisposable: Disposable?
    private var lifecycleDisposable: Disposable?
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
        self.actions.sharedContext = sharedContext
        self.actions.activeContext = { [weak self] in
            return self?.activeContext
        }

        // The primary account is what a plugin means by "the current account".
        // Keeping a weak reference instead of subscribing once means switching
        // accounts needs no extra bookkeeping: the next emission replaces it.
        self.foregroundDisposable?.dispose()
        self.foregroundDisposable = (sharedContext.activeAccountContexts
        |> deliverOnMainQueue).start(next: { [weak self] primary, _, _ in
            guard let self else {
                return
            }
            self.activeContext = primary
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
    var activeContext: (() -> AccountContext?)?

    private var context: AccountContext? {
        return self.activeContext?()
    }

    func sendText(peerId: Int64, text: String, options: PluginSendOptions) {
        Queue.mainQueue().async {
            guard let context = self.context else {
                self.reportMissingAccount()
                return
            }
            let content = Self.messageContent(text: text, parseMode: options.parseMode)
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

    func sendFile(kind: String, peerId: Int64, path: String, options: PluginSendOptions) {
        Queue.mainQueue().async {
            guard let context = self.context else {
                self.reportMissingAccount()
                return
            }
            let fileManager = FileManager.default
            guard fileManager.fileExists(atPath: path) else {
                self.showBulletin(kind: "error", text: "Plugin file not found: \((path as NSString).lastPathComponent)")
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

            // The caption is parsed the same way a text message is, so markdown in
            // a caption produces entities instead of literal asterisks.
            let caption = Self.messageContent(text: options.caption ?? "", parseMode: options.parseMode)

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

    func showBulletin(kind: String, text: String) {
        Queue.mainQueue().async {
            guard let sharedContext = self.sharedContext else {
                return
            }
            let presentationData = sharedContext.currentPresentationData.with { $0 }
            let content: UndoOverlayContent
            switch kind {
            case "success", "succeed", "ok":
                content = .succeed(text: text, timeout: 3.0, customUndoText: nil)
            case "error", "failure":
                // There is no dedicated error bulletin; an info one with the
                // plugin's own wording is what exteraGram shows too.
                content = .info(title: "Plugin", text: text, timeout: 4.0, customUndoText: nil)
            default:
                content = .info(title: nil, text: text, timeout: 3.0, customUndoText: nil)
            }
            sharedContext.presentGlobalController(
                UndoOverlayController(presentationData: presentationData, content: content, elevatedLayout: false, action: { _ in
                    return false
                }),
                nil
            )
        }
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

    /// Turns plugin text into entities. `parse_mode: "markdown"` runs the same
    /// converter the composer uses when pasting, so bold/italic/code/pre from a
    /// plugin land as real entities rather than literal asterisks. HTML is not
    /// supported by this runtime, so it is sent as plain text.
    ///
    /// Only entities cross the module boundary: wrapping them in a
    /// `TextEntitiesMessageAttribute` is the engine's job, because that attribute
    /// is a Postbox type.
    private static func messageContent(text: String, parseMode: String?) -> (text: String, entities: [MessageTextEntity]) {
        let mode = (parseMode ?? "").lowercased()
        var entities: [MessageTextEntity] = []
        var finalText = text
        if mode == "markdown" || mode == "md" || mode == "markdownv2" {
            let attributed = convertMarkdownToAttributes(NSAttributedString(string: text))
            finalText = attributed.string
            entities = generateChatInputTextEntities(attributed)
            entities.append(contentsOf: generateTextEntities(finalText, enabledTypes: .allUrl))
        } else {
            entities = generateTextEntities(text, enabledTypes: .all)
        }
        return (finalText, entities)
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
