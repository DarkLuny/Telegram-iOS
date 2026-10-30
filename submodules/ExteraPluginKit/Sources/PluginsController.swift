import Foundation
import UIKit
import Display
import AccountContext
import TelegramPresentationData
import PresentationDataUtils
import SwiftSignalKit
import ItemListUI

/// The plugin manager screen, reached from Settings.
///
/// exteraGram lists every installed plugin and, under each one, whatever its
/// `create_settings()` returned. This reproduces that shape: a list with one row
/// per plugin, and a second level that renders the plugin's own controls.
///
/// The list is rebuilt from `PluginManager` on every state emission instead of
/// being cached in a model, so installing, removing or reloading a plugin needs
/// only a signal push.

private enum PluginsSection: Int32 {
    case plugins
    case log
}

private enum PluginsControllerEntry: ItemListNodeEntry {
    case pluginsHeader
    case plugin(index: Int, summary: PluginManager.PluginSummary)
    case pluginsEmpty
    case install
    case pluginsFooter
    case logHeader
    case logValue
    case logFooter

    var section: ItemListSectionId {
        switch self {
        case .pluginsHeader, .plugin, .pluginsEmpty, .install, .pluginsFooter:
            return PluginsSection.plugins.rawValue
        case .logHeader, .logValue, .logFooter:
            return PluginsSection.log.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case .pluginsHeader:
            return 0
        case let .plugin(index, _):
            return 1 + Int32(index)
        case .pluginsEmpty:
            return 9000
        case .install:
            return 9001
        case .pluginsFooter:
            return 9002
        case .logHeader:
            return 9003
        case .logValue:
            return 9004
        case .logFooter:
            return 9005
        }
    }

    static func < (lhs: PluginsControllerEntry, rhs: PluginsControllerEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! PluginsControllerArguments
        switch self {
        case .pluginsHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "Plugins", sectionId: self.section)
        case let .plugin(_, summary):
            var label = "v\(summary.version)"
            if !summary.author.isEmpty {
                label = "\(summary.author) · \(label)"
            }
            // A plugin that is enabled but failed to load must not look like a
            // working one: the row says so and carries the reason as its detail.
            if summary.isEnabled && !summary.isLoaded {
                label = "Failed"
            } else if !summary.isEnabled {
                label = "Off"
            }
            let subtitle: String? = summary.isEnabled ? summary.loadError : nil
            return ItemListDisclosureItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: summary.name,
                enabled: true,
                label: label,
                labelStyle: .text,
                additionalDetailLabel: subtitle,
                sectionId: self.section,
                style: .blocks,
                disclosureStyle: .arrow,
                action: {
                    arguments.openPlugin(summary.id)
                }
            )
        case .pluginsEmpty:
            return ItemListTextItem(presentationData: presentationData, text: .plain("No plugins installed."), sectionId: self.section)
        case .install:
            return ItemListActionItem(
                presentationData: presentationData,
                title: "Install Plugin…",
                kind: .generic,
                alignment: .natural,
                sectionId: self.section,
                style: .blocks,
                action: {
                    arguments.installPlugin()
                }
            )
        case .pluginsFooter:
            return ItemListTextItem(presentationData: presentationData, text: .plain("Plugins are JavaScript (.plugin or .js) files written against exteraGram's plugin API. “Install Plugin…” opens the system file picker; the chosen file is checked and copied into the app's private folder, which no other app can read. Files.app does not show that folder, so this picker is the only way to get a plugin in."), sectionId: self.section)
        case .logHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "Log", sectionId: self.section)
        case .logValue:
            return ItemListDisclosureItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: "Show Log",
                label: "",
                labelStyle: .text,
                sectionId: self.section,
                style: .blocks,
                disclosureStyle: .arrow,
                action: {
                    arguments.openLog()
                }
            )
        case .logFooter:
            return ItemListTextItem(presentationData: presentationData, text: .plain("Log lines from every plugin, newest last. Useful when a plugin does not behave as expected."), sectionId: self.section)
        }
    }
}

private final class PluginsControllerArguments {
    let openPlugin: (String) -> Void
    let openLog: () -> Void
    let installPlugin: () -> Void
    /// The signal that builds the rows captures these arguments, so the plugin
    /// manager's change notifications keep rebuilding the list while the screen
    /// is open. `deinit` unsubscribes once the controller is gone.
    private let changesDisposable: Disposable

    init(openPlugin: @escaping (String) -> Void, openLog: @escaping () -> Void, installPlugin: @escaping () -> Void, changesDisposable: Disposable) {
        self.openPlugin = openPlugin
        self.openLog = openLog
        self.installPlugin = installPlugin
        self.changesDisposable = changesDisposable
    }

    deinit {
        self.changesDisposable.dispose()
    }
}

private func pluginsControllerEntries(installed: [PluginManager.PluginSummary]) -> [PluginsControllerEntry] {
    var entries: [PluginsControllerEntry] = []
    entries.append(.pluginsHeader)
    for (index, summary) in installed.enumerated() {
        entries.append(.plugin(index: index, summary: summary))
    }
    if installed.isEmpty {
        entries.append(.pluginsEmpty)
    }
    entries.append(.install)
    entries.append(.pluginsFooter)
    entries.append(.logHeader)
    entries.append(.logValue)
    entries.append(.logFooter)
    return entries
}

/// Entry point for the settings row.
public func pluginsController(context: AccountContext) -> ViewController {
    let manager = PluginManager.shared
    // Bumped whenever the list behind this controller changes: a plugin was
    // installed, removed, enabled or reloaded while the screen was open.
    let statePromise = ValuePromise<Int32>(0, ignoreRepeated: true)
    let stateValue = Atomic(value: Int32(0))
    let changesDisposable: Disposable = (manager.changes
    |> deliverOnMainQueue).start(next: { _ in
        _ = stateValue.modify { value in
            return value &+ 1
        }
        statePromise.set(stateValue.with { $0 })
    })

    let arguments = PluginsControllerArguments(
        openPlugin: { pluginId in
            context.sharedContext.presentGlobalController(pluginSettingsController(context: context, pluginId: pluginId), nil)
        },
        openLog: {
            context.sharedContext.presentGlobalController(pluginLogController(context: context), nil)
        },
        installPlugin: {
            // The importer outlives this closure: `UIDocumentPickerViewController`
            // holds its delegate weakly, so `PluginFileImporter` keeps a reference
            // to itself until the picker reports back.
            let importer = PluginFileImporter(onFinished: { installed, error in
                let sharedContext = context.sharedContext
                if let error = error {
                    showPluginInstallResult(kind: "error", text: error, sharedContext: sharedContext)
                } else if let installed = installed {
                    // Installing does not reload synchronously; the list rebuilds
                    // when `PluginManager.changes` fires.
                    showPluginInstallResult(kind: "success", text: "Installed \(installed.name).", sharedContext: sharedContext)
                }
            })
            importer.present(sharedContext: context.sharedContext)
        },
        changesDisposable: changesDisposable
    )

    let signal = combineLatest(
        context.sharedContext.presentationData,
        statePromise.get()
    )
    |> deliverOnMainQueue
    |> map { presentationData, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text("Plugins"),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
        )
        let listState = ItemListNodeState(
            presentationData: ItemListPresentationData(presentationData),
            entries: pluginsControllerEntries(installed: manager.installedPlugins()),
            style: .blocks,
            animateChanges: true
        )
        return (controllerState, (listState, arguments))
    }

    // The screen opens as a pushed settings page, so it inherits the back button
    // rather than presenting as a modal.
    let controller = ItemListController(context: context, state: signal)
    return controller
}

// MARK: - One plugin's settings

private enum PluginSettingsSection: Int32 {
    case controls
    case actions
}

private enum PluginSettingsEntry: ItemListNodeEntry {
    case enabled(Bool)
    case header(index: Int, text: String)
    case note(index: Int, text: String)
    case toggle(index: Int, key: String, title: String, subtitle: String?, value: Bool)
    case selector(index: Int, key: String, title: String, subtitle: String?, label: String)
    case input(index: Int, key: String, title: String, value: String, placeholder: String, multiline: Bool, maxLength: Int)
    /// A `Text`/`Custom` row with an `on_click`, rendered as a button.
    case action(index: Int, key: String, title: String, subtitle: String?, accent: Bool, red: Bool, long: Bool)
    /// A row whose `create_sub_fragment` opens another settings page.
    case subPage(index: Int, key: String, title: String, subtitle: String?)
    case empty
    case reload
    case remove

    // `ItemListController` walks the entries in order and expects sections never
    // to go backwards, and `stableId` alone decides that order. The enable switch
    // therefore belongs to the first section, like every control row; only the
    // two action buttons sit in the trailing one.
    var section: ItemListSectionId {
        switch self {
        case .reload, .remove:
            return PluginSettingsSection.actions.rawValue
        default:
            return PluginSettingsSection.controls.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case .enabled:
            return 0
        case let .header(index, _), let .note(index, _), let .toggle(index, _, _, _, _),
             let .selector(index, _, _, _, _), let .input(index, _, _, _, _, _, _),
             let .action(index, _, _, _, _, _, _), let .subPage(index, _, _, _):
            return Int32(index) + 1
        case .empty:
            return 100000
        case .reload:
            return 100001
        case .remove:
            return 100002
        }
    }

    static func < (lhs: PluginSettingsEntry, rhs: PluginSettingsEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! PluginSettingsControllerArguments
        switch self {
        case let .enabled(value):
            return ItemListSwitchItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: "Enabled",
                value: value,
                sectionId: self.section,
                style: .blocks,
                updated: { value in
                    arguments.setEnabled(value)
                }
            )
        case let .header(_, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .note(_, text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .toggle(_, key, title, subtitle, value):
            return ItemListSwitchItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: title,
                text: subtitle,
                value: value,
                sectionId: self.section,
                style: .blocks,
                updated: { value in
                    arguments.updateValue(key, value)
                }
            )
        case let .selector(_, key, title, subtitle, label):
            return ItemListDisclosureItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: title,
                label: label,
                labelStyle: .text,
                additionalDetailLabel: subtitle,
                sectionId: self.section,
                style: .blocks,
                disclosureStyle: .arrow,
                action: {
                    arguments.presentSelector(key, title)
                }
            )
        case let .input(_, key, title, value, placeholder, multiline, maxLength):
            if multiline {
                return ItemListMultilineInputItem(
                    presentationData: presentationData,
                    text: value,
                    placeholder: placeholder,
                    maxLength: maxLength > 0 ? ItemListMultilineInputItemTextLimit(value: maxLength, display: true) : nil,
                    sectionId: self.section,
                    style: .blocks,
                    textUpdated: { text in
                        arguments.updateValue(key, text)
                    },
                    action: nil
                )
            } else {
                return ItemListSingleLineInputItem(
                    presentationData: presentationData,
                    title: NSAttributedString(string: title, font: Font.regular(17.0), textColor: presentationData.theme.list.itemPrimaryTextColor),
                    text: value,
                    placeholder: placeholder,
                    maxLength: maxLength,
                    sectionId: self.section,
                    textUpdated: { text in
                        arguments.updateValue(key, text)
                    },
                    action: {}
                )
            }
        case .empty:
            return ItemListTextItem(presentationData: presentationData, text: .plain("This plugin has no settings."), sectionId: self.section)
        case let .action(_, key, title, subtitle, accent, red, long):
            // exteraGram's `Text(on_click=...)` and `Custom(on_click=...)` rows
            // are buttons: the title is the label and there is nowhere else for
            // the tap to go, so the disclosure arrow is suppressed. Both
            // `accent` and `red` mean "this row stands out", and the list style
            // only distinguishes primary from accent text, so they share one.
            return ItemListDisclosureItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: title,
                titleColor: (accent || red) ? .accent : .primary,
                label: "",
                labelStyle: .text,
                additionalDetailLabel: subtitle,
                sectionId: self.section,
                style: .blocks,
                disclosureStyle: .none,
                action: {
                    arguments.clickRow(key, long)
                }
            )
        case let .subPage(_, key, title, subtitle):
            return ItemListDisclosureItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: title,
                label: "",
                labelStyle: .text,
                additionalDetailLabel: subtitle,
                sectionId: self.section,
                style: .blocks,
                disclosureStyle: .arrow,
                action: {
                    arguments.openSubPage(key, title)
                }
            )
        case .reload:
            return ItemListActionItem(presentationData: presentationData, title: "Reload Plugin", kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.reload()
            })
        case .remove:
            return ItemListActionItem(presentationData: presentationData, title: "Remove Plugin", kind: .destructive, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.remove()
            })
        }
    }
}

private final class PluginSettingsControllerArguments {
    let updateValue: (String, Any?) -> Void
    let presentSelector: (String, String) -> Void
    let clickRow: (String, Bool) -> Void
    let openSubPage: (String, String) -> Void
    let setEnabled: (Bool) -> Void
    let reload: () -> Void
    let remove: () -> Void

    init(
        updateValue: @escaping (String, Any?) -> Void,
        presentSelector: @escaping (String, String) -> Void,
        clickRow: @escaping (String, Bool) -> Void,
        openSubPage: @escaping (String, String) -> Void,
        setEnabled: @escaping (Bool) -> Void,
        reload: @escaping () -> Void,
        remove: @escaping () -> Void
    ) {
        self.updateValue = updateValue
        self.presentSelector = presentSelector
        self.clickRow = clickRow
        self.openSubPage = openSubPage
        self.setEnabled = setEnabled
        self.reload = reload
        self.remove = remove
    }
}

/// Turns the controls a plugin returned into rows.
///
/// Shared by the plugin's own page and by any page opened from it, so a nested
/// page renders exactly like the top level. `startIndex` only shifts the stable
/// ids, which have to stay unique (and ascending) within one list.
private func pluginControlEntries(controls: [PluginManager.SettingsControl], startIndex: Int) -> [PluginSettingsEntry] {
    var entries: [PluginSettingsEntry] = []
    var index = startIndex
    for control in controls {
        index += 1
        switch control.type {
        case "header":
            entries.append(.header(index: index, text: control.text ?? ""))
        case "divider":
            entries.append(.note(index: index, text: control.text ?? ""))
        case "switch":
            guard let key = control.key else {
                continue
            }
            entries.append(.toggle(
                index: index,
                key: key,
                title: control.text ?? key,
                subtitle: control.subtext,
                value: (control.value as? Bool) ?? false
            ))
        case "selector":
            guard let key = control.key else {
                continue
            }
            let current = (control.value as? NSNumber)?.intValue ?? 0
            let label = (current >= 0 && current < control.items.count) ? control.items[current] : ""
            entries.append(.selector(
                index: index,
                key: key,
                title: control.text ?? key,
                subtitle: control.subtext,
                label: label
            ))
        case "input", "edit_text":
            guard let key = control.key else {
                continue
            }
            entries.append(.input(
                index: index,
                key: key,
                title: control.text ?? key,
                value: (control.value as? String) ?? "",
                placeholder: control.hint ?? "",
                multiline: control.type == "edit_text" || control.multiline,
                maxLength: control.maxLength
            ))
        case "text", "custom":
            // Three shapes reach here: a row that opens another page, a row that
            // runs a callback, and a plain caption. `has_sub_fragment` wins,
            // because exteraGram's builder asks for the page on tap and would
            // otherwise have its click dropped.
            let title = control.text ?? control.subtext ?? ""
            if control.hasSubFragment, let key = control.key {
                entries.append(.subPage(index: index, key: key, title: title, subtitle: control.subtext))
            } else if let key = control.key, control.hasClick || control.hasLongClick {
                // A list row only reports a tap, so a `on_long_click`-only row
                // uses it for the long press; having both would mean two
                // callbacks on one gesture, and the plain click is the one a
                // plugin expects from a tap.
                entries.append(.action(
                    index: index,
                    key: key,
                    title: title,
                    subtitle: control.subtext,
                    accent: control.accent,
                    red: control.red,
                    long: control.hasLongClick && !control.hasClick
                ))
            } else if !title.isEmpty {
                entries.append(.note(index: index, text: control.subtext.map { "\(title)\n\($0)" } ?? title))
            }
        default:
            continue
        }
    }
    return entries
}

private func pluginSettingsEntries(controls: [PluginManager.SettingsControl], isEnabled: Bool, loadError: String?) -> [PluginSettingsEntry] {
    var entries: [PluginSettingsEntry] = []
    entries.append(.enabled(isEnabled))
    if let loadError = loadError {
        // A plugin that did not load has no settings to show, and saying only
        // "This plugin has no settings" would hide the real reason.
        entries.append(.note(index: 0, text: "This plugin failed to load: \(loadError)"))
    }

    let controlEntries = pluginControlEntries(controls: controls, startIndex: entries.count)
    entries.append(contentsOf: controlEntries)
    if controlEntries.isEmpty && loadError == nil {
        entries.append(.empty)
    }
    entries.append(.reload)
    entries.append(.remove)
    return entries
}

private func pluginSubSettingsEntries(controls: [PluginManager.SettingsControl]) -> [PluginSettingsEntry] {
    let entries = pluginControlEntries(controls: controls, startIndex: 0)
    if entries.isEmpty {
        return [.empty]
    }
    return entries
}

/// Holds the controller a settings page's rows can push onto.
///
/// The arguments are built before their controller (the controller's state
/// closure captures them), so the "open a nested page" callback needs somewhere
/// to find it afterwards; weak, because the controller owns the list that owns
/// the arguments.
private final class PluginSettingsHost {
    weak var controller: ViewController?
}

private func pluginSettingsArguments(context: AccountContext, pluginId: String, bump: @escaping () -> Void, host: PluginSettingsHost) -> PluginSettingsControllerArguments {
    let manager = PluginManager.shared
    let store = PluginStore.shared
    return PluginSettingsControllerArguments(
        updateValue: { key, value in
            manager.setSetting(pluginId: pluginId, key: key, value: value)
        },
        presentSelector: { key, title in
            guard let control = manager.settings(for: pluginId).first(where: { $0.key == key }) else {
                return
            }
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            let actionSheet = ActionSheetController(presentationData: presentationData)
            var items: [ActionSheetItem] = []
            for (index, item) in control.items.enumerated() {
                items.append(ActionSheetButtonItem(title: item, color: .accent, action: { [weak actionSheet] in
                    actionSheet?.dismissAnimated()
                    manager.setSetting(pluginId: pluginId, key: key, value: index)
                    bump()
                }))
            }
            items.append(ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                actionSheet?.dismissAnimated()
            }))
            actionSheet.setItemGroups([ActionSheetItemGroup(items: items)])
            context.sharedContext.presentGlobalController(actionSheet, nil)
        },
        clickRow: { key, long in
            // The callback itself is looked up inside the plugin by key, so only
            // strings cross here and the plugin decides what the row means.
            manager.invokeSettingClick(pluginId: pluginId, key: key, long: long)
        },
        openSubPage: { key, title in
            host.controller?.push(pluginSubSettingsController(context: context, pluginId: pluginId, parentKey: key, title: title))
        },
        setEnabled: { enabled in
            store.setEnabled(enabled, pluginId: pluginId)
            manager.reloadPlugins()
            bump()
        },
        reload: {
            manager.reloadPlugins()
            bump()
        },
        remove: {
            store.remove(pluginId: pluginId)
            manager.reloadPlugins()
            bump()
        }
    )
}

public func pluginSettingsController(context: AccountContext, pluginId: String) -> ViewController {
    let manager = PluginManager.shared
    let store = PluginStore.shared
    let statePromise = ValuePromise<Int32>(0, ignoreRepeated: true)
    let stateValue = Atomic(value: Int32(0))

    let bump: () -> Void = {
        _ = stateValue.modify { value in
            return value &+ 1
        }
        statePromise.set(stateValue.with { $0 })
    }

    let host = PluginSettingsHost()
    let arguments = pluginSettingsArguments(context: context, pluginId: pluginId, bump: bump, host: host)

    let signal = combineLatest(
        context.sharedContext.presentationData,
        statePromise.get()
    )
    |> deliverOnMainQueue
    |> map { presentationData, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let title = manager.manifest(for: pluginId)?.name ?? pluginId
        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(title),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
        )
        let summary = manager.installedPlugins().first { $0.id == pluginId }
        let listState = ItemListNodeState(
            presentationData: ItemListPresentationData(presentationData),
            entries: pluginSettingsEntries(
                controls: manager.settings(for: pluginId),
                isEnabled: store.isEnabled(pluginId),
                loadError: summary?.loadError
            ),
            style: .blocks,
            animateChanges: true
        )
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    controller.navigationPresentation = .modal
    host.controller = controller
    return controller
}

/// A page opened from a plugin's settings row, built by that row's
/// `create_sub_fragment`.
///
/// It uses the same rows and the same arguments as the top level, minus the
/// enable switch and the reload/remove buttons: those belong to the plugin, not
/// to one of its pages.
private func pluginSubSettingsController(context: AccountContext, pluginId: String, parentKey: String, title: String) -> ViewController {
    let manager = PluginManager.shared
    let statePromise = ValuePromise<Int32>(0, ignoreRepeated: true)
    let stateValue = Atomic(value: Int32(0))

    let bump: () -> Void = {
        _ = stateValue.modify { value in
            return value &+ 1
        }
        statePromise.set(stateValue.with { $0 })
    }

    // A nested page may itself open a page, so it gets its own host.
    let host = PluginSettingsHost()
    let arguments = pluginSettingsArguments(context: context, pluginId: pluginId, bump: bump, host: host)

    let signal = combineLatest(
        context.sharedContext.presentationData,
        statePromise.get()
    )
    |> deliverOnMainQueue
    |> map { presentationData, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(title),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
        )
        let listState = ItemListNodeState(
            presentationData: ItemListPresentationData(presentationData),
            entries: pluginSubSettingsEntries(controls: manager.subSettings(for: pluginId, parentKey: parentKey)),
            style: .blocks,
            animateChanges: true
        )
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    controller.navigationPresentation = .modal
    host.controller = controller
    return controller
}

// MARK: - Log viewer

private enum PluginLogEntry: ItemListNodeEntry {
    case empty
    case line(index: Int, text: String)
    case clear

    var section: ItemListSectionId {
        switch self {
        case .clear:
            return 1
        default:
            return 0
        }
    }

    var stableId: Int32 {
        switch self {
        case .empty:
            return 0
        case let .line(index, _):
            return Int32(index) + 1
        case .clear:
            return 1000000
        }
    }

    static func < (lhs: PluginLogEntry, rhs: PluginLogEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        switch self {
        case .empty:
            return ItemListTextItem(presentationData: presentationData, text: .plain("No log entries."), sectionId: self.section)
        case let .line(_, text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case .clear:
            return ItemListActionItem(presentationData: presentationData, title: "Clear Log", kind: .destructive, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                PluginLog.clear()
            })
        }
    }
}

public func pluginLogController(context: AccountContext) -> ViewController {
    let signal = context.sharedContext.presentationData
    |> deliverOnMainQueue
    |> map { presentationData -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let lines = PluginLog.recentLines(limit: 400)
        var entries: [PluginLogEntry] = []
        if lines.isEmpty {
            entries.append(.empty)
        } else {
            for (index, line) in lines.enumerated() {
                entries.append(.line(index: index, text: line))
            }
        }
        entries.append(.clear)
        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text("Plugin Log"),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
        )
        let listState = ItemListNodeState(
            presentationData: ItemListPresentationData(presentationData),
            entries: entries,
            style: .plain,
            animateChanges: false
        )
        return (controllerState, (listState, ()))
    }

    let controller = ItemListController(context: context, state: signal)
    controller.navigationPresentation = .modal
    return controller
}