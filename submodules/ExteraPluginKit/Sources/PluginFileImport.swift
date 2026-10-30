import Foundation
import UIKit
import UniformTypeIdentifiers
import SwiftSignalKit
import AccountContext
import TelegramPresentationData
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