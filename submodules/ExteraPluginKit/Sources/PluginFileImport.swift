import Foundation
import UIKit
import UniformTypeIdentifiers
import SwiftSignalKit
import Display
import AccountContext
import TelegramCore
import TelegramPresentationData
import PresentationDataUtils
import UndoUI

/// Installs a plugin from a file the user picks with the system document picker.
///
/// exteraGram's "install plugin" reads a file the user downloaded, because on
/// Android the plugin folder is either app-private or a shared Downloads
/// directory. On iOS nothing outside the sandbox is reachable without the
/// picker: `UIFileSharingEnabled` is off in both Info.plist files, so the app's
/// Documents folder is not visible in Files.app at all. The picker is therefore
/// the only way in, and it works on a free-Apple-ID re-signed build because it
/// needs no entitlement beyond the app's own sandbox.
///
/// `UIDocumentPickerViewController` holds its delegate weakly, so this object
/// keeps a reference to itself until the picker reports back.
public final class PluginFileImporter: NSObject, UIDocumentPickerDelegate {
    private var selfReference: PluginFileImporter?
    private let onFinished: (_ installed: PluginManager.PluginInstallOutcome?, _ error: String?) -> Void

    /// `onFinished` receives either the installed plugin or a human-readable
    /// failure reason, never both. It is always called on the main queue.
    public init(onFinished: @escaping (_ installed: PluginManager.PluginInstallOutcome?, _ error: String?) -> Void) {
        self.onFinished = onFinished
        super.init()
    }

    /// Presents the picker. Must be called on the main queue.
    public func present(sharedContext: SharedAccountContext) {
        // `.text` covers `.js`; `.data` covers a plugin saved with an extension
        // the system does not know. Anything that slips through is rejected by
        // the manifest check, which gives a precise reason instead of silently
        // listing nothing.
        var types: [UTType] = [.text, .data]
        // An unknown extension maps to a dynamic type, which the picker accepts;
        // adding it explicitly is what makes a `.plugin` file selectable.
        if let pluginType = UTType(filenameExtension: "plugin"), !types.contains(pluginType) {
            types.insert(pluginType, at: 0)
        }

        // `asCopy` hands over a file inside the app's own temporary directory, so
        // no security-scoped access has to survive the read.
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = self
        self.selfReference = self
        sharedContext.applicationBindings.presentNativeController(picker)
    }

    public func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else {
            self.finish(installed: nil, error: "No file was selected.")
            return
        }

        // Reading the file and scanning up to the size limit for the manifest is
        // not work for the thread that is dismissing the picker.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                return
            }
            // Harmless for a copied file, required if the picker hands back the
            // original in place.
            let didAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                self.finish(installed: nil, error: "Could not read the file: \(error.localizedDescription)")
                return
            }

            do {
                let installed = try PluginManager.shared.installPlugin(
                    data: data,
                    fallbackId: url.deletingPathExtension().lastPathComponent
                )
                self.finish(installed: installed, error: nil)
            } catch {
                self.finish(installed: nil, error: "\(error)")
            }
        }
    }

    public func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        // Cancelling is not a failure: the user changed their mind, and a bulletin
        // saying so would be noise. Nothing else happens, so the object is simply
        // released.
        self.selfReference = nil
    }

    private func finish(installed: PluginManager.PluginInstallOutcome?, error: String?) {
        // Reached from the background read as well as from the picker's own
        // callbacks, so the hop to the main queue happens here instead of in
        // every caller.
        Queue.mainQueue().async { [weak self] in
            guard let self = self else {
                return
            }
            self.selfReference = nil
            self.onFinished(installed, error)
        }
    }
}

/// Installs a plugin from a file that is already on disk.
///
/// This is the path a `.plugin` attachment takes: the user taps the file in a
/// chat, the app copies it out of the message's cache, and this asks whether to
/// install it. The document picker in the plugin screen is the same flow with
/// the picker in front, so both end in `PluginManager.installPlugin`.
public final class PluginFileInstaller {
    private static var current: PluginFileInstaller?

    /// The file being installed. A chat document is only known as a message
    /// resource until the download finishes, so this starts empty there and is
    /// filled in when the file lands.
    private var url: URL
    /// The name shown in the confirmation and used as the fallback plugin id.
    ///
    /// Kept separately from `url` because after a download the file on disk is a
    /// cache path with a generated name, while the name the user recognises is
    /// the one from the message.
    private var installerFileName: String
    private var downloadDisposable: Disposable?
    private let sharedContext: SharedAccountContext

    private init(url: URL, sharedContext: SharedAccountContext) {
        self.url = url
        self.installerFileName = url.lastPathComponent
        self.sharedContext = sharedContext
    }

    /// Whether a URL is a plugin file this app should offer to install.
    ///
    /// `.plugin` is the extension exteraGram uses; `.js` is accepted because the
    /// store reads it too, and a plugin shared as plain JavaScript would
    /// otherwise be a dead file. A `.tgios-theme` or any other document is left
    /// to the stock handlers.
    public static func canInstall(url: URL) -> Bool {
        guard url.isFileURL else {
            return false
        }
        let extensionName = url.pathExtension.lowercased()
        return extensionName == "plugin" || extensionName == "js"
    }

    /// Whether a document in a chat is a plugin, judged before it is downloaded.
    ///
    /// The chat path has no file on disk yet, so the decision has to come from
    /// the message's metadata: the file name, and the MIME type a `.plugin` sent
    /// from a computer is usually given. The extension is the real signal — a
    /// plugin renamed to `.txt` is not something to offer to install.
    public static func canInstall(fileName: String?, mimeType: String?) -> Bool {
        if let fileName = fileName {
            let extensionName = (fileName as NSString).pathExtension.lowercased()
            if extensionName == "plugin" {
                return true
            }
            // `.js` is accepted only when the MIME type agrees, because a chat
            // carries plenty of genuine JavaScript (bot code, snippets) and
            // offering to install every one of them would be noise. The check is
            // a `contains` rather than an equality because clients and servers
            // label the same file `application/javascript`, `text/javascript` or
            // the older `application/x-javascript`.
            if extensionName == "js", let mimeType = mimeType {
                return mimeType.lowercased().contains("javascript")
            }
        }
        return false
    }

    /// Presents the install confirmation. Must be called on the main queue.
    ///
    /// The file is read before the user is asked, because "this is not a plugin"
    /// is a better answer than offering to install something that will fail.
    public static func present(url: URL, sharedContext: SharedAccountContext) {
        // Held in a static so the alert's actions can reach this object after
        // `present` returns; released when the alert is dismissed.
        let installer = PluginFileInstaller(url: url, sharedContext: sharedContext)
        PluginFileInstaller.current = installer
        installer.confirmRead()
    }

    /// Presents the confirmation for a document attached to a chat message.
    ///
    /// `existingURL` is the completed path when the file happens to be cached;
    /// otherwise the resource is downloaded first. The download is what makes
    /// this work for a plugin that arrived as an unsaved attachment — on iOS the
    /// document only lands on disk once something asks for it.
    ///
    /// Must be called on the main queue.
    public static func present(file: TelegramMediaFile, context: AccountContext, existingURL: URL?) {
        let sharedContext = context.sharedContext
        if let existingURL = existingURL {
            PluginFileInstaller.present(url: existingURL, sharedContext: sharedContext)
            return
        }
        let installer = PluginFileInstaller(url: URL(fileURLWithPath: ""), sharedContext: sharedContext)
        // The alert and the fallback id use the name from the message: the file
        // in the cache is named after its resource id, not after what the sender
        // called it.
        if let fileName = file.fileName {
            installer.installerFileName = fileName
        }
        PluginFileInstaller.current = installer
        installer.download(file: file, context: context)
    }

    /// Downloads a chat document and then behaves like the on-disk path.
    private func download(file: TelegramMediaFile, context: AccountContext) {
        let resource = EngineMediaResource(file.resource)
        // `fetchedResource` reports completion, not progress: it emits no value
        // and completes once the whole file is on disk. Subscribing to `next`
        // here would wait forever, which is exactly the bug this replaces.
        let disposable = context.engine.resources.fetchedResource(resource: resource).start(error: { [weak self] _ in
            Queue.mainQueue().async {
                self?.finish(error: "Could not download the plugin file.")
            }
        }, completed: { [weak self] in
            guard let self = self else {
                return
            }
            Queue.mainQueue().async {
                self.downloadDisposable = nil
                guard let path = context.engine.resources.completedResourcePath(id: EngineMediaResource.Id(file.resource.id)) else {
                    self.finish(error: "Could not download the plugin file.")
                    return
                }
                self.url = URL(fileURLWithPath: path)
                self.confirmRead()
            }
        })
        self.downloadDisposable = disposable
    }

    /// Reads `self.url` and asks whether to install it.
    private func confirmRead() {
        let url = self.url
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let didAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            let data = try? Data(contentsOf: url)
            Queue.mainQueue().async {
                guard let self = self else {
                    return
                }
                guard let data = data else {
                    self.finish(error: "Could not read the file.")
                    return
                }
                self.confirm(data: data)
            }
        }
    }

    private func confirm(data: Data) {
        let presentationData = self.sharedContext.currentPresentationData.with { $0 }
        let name = self.installerFileName
        let alert = textAlertController(
            sharedContext: self.sharedContext,
            title: "Install plugin?",
            text: "\(name)\n\nPlugins are JavaScript files with full access to the app's plugin API. Install only plugins you trust.",
            actions: [
                TextAlertAction(type: .genericAction, title: presentationData.strings.Common_Cancel, action: { [weak self] in
                    self?.release()
                }),
                TextAlertAction(type: .defaultAction, title: "Install", action: { [weak self] in
                    self?.install(data: data)
                })
            ]
        )
        self.sharedContext.presentGlobalController(alert, nil)
    }

    private func install(data: Data) {
        // The plugin's own `__id__` is what matters; the file name is only a
        // fallback for a file whose manifest the loader cannot read. A chat file
        // is named by its sender, and a cache path has no extension at all, so
        // this may legitimately end up empty.
        let fallbackId = (self.installerFileName as NSString).deletingPathExtension
        let resolvedId = fallbackId.isEmpty ? "plugin" : fallbackId
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result: Result<PluginManager.PluginInstallOutcome, Error>
            do {
                result = .success(try PluginManager.shared.installPlugin(data: data, fallbackId: resolvedId))
            } catch {
                result = .failure(error)
            }
            Queue.mainQueue().async {
                guard let self = self else {
                    return
                }
                switch result {
                case let .success(outcome):
                    showPluginInstallResult(kind: "success", text: "Installed \(outcome.name).", sharedContext: self.sharedContext)
                case let .failure(error):
                    showPluginInstallResult(kind: "error", text: "\(error)", sharedContext: self.sharedContext)
                }
                self.release()
            }
        }
    }

    private func finish(error: String) {
        showPluginInstallResult(kind: "error", text: error, sharedContext: self.sharedContext)
        self.release()
    }

    private func release() {
        // A cancelled download must not keep the manager's fetch alive: the file
        // would finish in the background with nobody to ask about it.
        self.downloadDisposable?.dispose()
        self.downloadDisposable = nil
        if PluginFileInstaller.current === self {
            PluginFileInstaller.current = nil
        }
    }
}

/// Reports the outcome of an install.
///
/// Goes through `presentGlobalController`, the same route the plugin bulletins
/// use, so the message appears above the settings screen rather than behind it.
public func showPluginInstallResult(kind: String, text: String, sharedContext: SharedAccountContext) {
    let presentationData = sharedContext.currentPresentationData.with { $0 }
    let content: UndoOverlayContent
    if kind == "error" {
        content = .info(title: "Plugin", text: text, timeout: 5.0, customUndoText: nil)
    } else {
        content = .succeed(text: text, timeout: 3.0, customUndoText: nil)
    }
    sharedContext.presentGlobalController(
        UndoOverlayController(presentationData: presentationData, content: content, elevatedLayout: false, action: { _ in
            return false
        }),
        nil
    )
}