import Foundation
import UIKit
import Display
import AccountContext
import TelegramCore
import TelegramPresentationData
import PresentationDataUtils
import SwiftSignalKit
import ItemListUI

/// The settings page for the TG WS Proxy transport.
///
/// The transport itself already lives in the client (`TgWsProxyService` in
/// TelegramCore), and the standalone tg-ws-proxy app is a UI plus a background
/// task around the same idea. Embedding it here means the listener runs in
/// Telegram's own process: no `BackgroundManager`, no second app, and nothing
/// keeps running after Telegram leaves the foreground. The switch adds and
/// removes the `127.0.0.1` entry in Telegram's proxy list exactly as the plugin
/// did, so traffic uses the tunnel as soon as it is started.
enum TgWsProxySettings {
    static let enabledKey = "extera.extensions.tgwsproxy.enabled"
    static let zoneKey = "extera.extensions.tgwsproxy.zone_index"
    static let customDomainKey = "extera.extensions.tgwsproxy.custom_domain"

    /// `cfproxyEnc` from tg-ws-proxy.go. The core decodes each entry into the
    /// `.co.uk` zone it actually dials; keeping the encoded form here means the
    /// list is the same one the reference app uses.
    static let encodedZones = [
        "virkgj.com",
        "vmmzovy.com",
        "mkuosckvso.com",
        "zaewayzmplad.com",
        "twdmbzcm.com",
    ]

    static var zones: [String] {
        return self.encodedZones.map { TgWsProxySettings.decode($0) }
    }

    static var enabled: Bool {
        return UserDefaults.standard.bool(forKey: self.enabledKey)
    }

    static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: self.enabledKey)
    }

    static var zoneIndex: Int {
        let stored = UserDefaults.standard.integer(forKey: self.zoneKey)
        if stored < 0 || stored > self.zones.count {
            return 0
        }
        return stored
    }

    static func setZoneIndex(_ index: Int) {
        let clamped = max(0, min(index, self.zones.count))
        UserDefaults.standard.set(clamped, forKey: self.zoneKey)
    }

    static var customDomain: String {
        return UserDefaults.standard.string(forKey: self.customDomainKey) ?? ""
    }

    static func setCustomDomain(_ value: String) {
        UserDefaults.standard.set(value, forKey: self.customDomainKey)
    }

    static var zoneLabel: String {
        let index = self.zoneIndex
        if index == 0 {
            return "Automatic"
        }
        return self.zones[index - 1]
    }

    /// The zone the listener is asked to try first. "Automatic" still needs a
    /// concrete host, so it starts with the first known zone and keeps the rest
    /// as fallbacks; returning `""` here made the switch fail with
    /// "not a host name:".
    static func preferredDomain() -> String {
        let custom = self.normalizeHost(self.customDomain)
        if !custom.isEmpty {
            return custom
        }
        let index = self.zoneIndex
        if index > 0 {
            return self.zones[index - 1]
        }
        return self.zones.first ?? ""
    }

    /// The preferred zone followed by every other known zone. The listener tries
    /// them in order, so one dead front does not end the tunnel.
    static func zonesInOrder(preferred: String) -> [String] {
        var result: [String] = []
        if !preferred.isEmpty {
            result.append(preferred)
        }
        for zone in self.zones where !result.contains(zone) {
            result.append(zone)
        }
        return result
    }

    static func normalizeHost(_ value: String) -> String {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while text.hasSuffix(".") {
            text.removeLast()
        }
        if text.isEmpty || text.count > 253 {
            return ""
        }
        if text.rangeOfCharacter(from: CharacterSet(charactersIn: "/:@ \t\r\n")) != nil {
            return ""
        }
        let labels = text.split(separator: ".", omittingEmptySubsequences: false)
        if labels.count < 2 {
            return ""
        }
        for label in labels {
            if label.isEmpty || label.count > 63 {
                return ""
            }
            if label.hasPrefix("-") || label.hasSuffix("-") {
                return ""
            }
            for scalar in label.unicodeScalars {
                let value = scalar.value
                let isLetter = value >= 97 && value <= 122
                let isDigit = value >= 48 && value <= 57
                if !isLetter && !isDigit && value != 45 {
                    return ""
                }
            }
        }
        if let last = labels.last, last.unicodeScalars.allSatisfy({ $0.value >= 48 && $0.value <= 57 }) {
            return ""
        }
        return text
    }

    /// `decodeCfDomain` from tg-ws-proxy.go: every letter before `.com` moves
    /// back by the number of letters in that part, and `.com` becomes `.co.uk`.
    static func decode(_ value: String) -> String {
        guard value.hasSuffix(".com") else {
            return value
        }
        let stem = String(value.dropLast(4))
        var letters = 0
        for scalar in stem.unicodeScalars {
            let value = scalar.value
            if (value >= 65 && value <= 90) || (value >= 97 && value <= 122) {
                letters += 1
            }
        }
        let shift = letters % 26
        var result = ""
        for scalar in stem.unicodeScalars {
            let value = scalar.value
            if value >= 97 && value <= 122 {
                let shifted = (Int(value) - 97 - shift + 26) % 26 + 97
                result.append(Character(UnicodeScalar(UInt32(shifted))!))
            } else if value >= 65 && value <= 90 {
                let shifted = (Int(value) - 65 - shift + 26) % 26 + 65
                result.append(Character(UnicodeScalar(UInt32(shifted))!))
            } else {
                result.append(Character(scalar))
            }
        }
        return result + ".co.uk"
    }
}

private enum TgWsProxySection: Int32 {
    case settings
    case status
}

private enum TgWsProxyEntry: ItemListNodeEntry {
    case header
    case enabled(isOn: Bool, running: Bool)
    case zone(label: String)
    case customDomain(value: String)
    case settingsFooter
    case statusHeader
    case status(text: String)
    case copyLink
    case refresh
    case restart
    case statusFooter

    var section: ItemListSectionId {
        switch self {
        case .header, .enabled, .zone, .customDomain, .settingsFooter:
            return TgWsProxySection.settings.rawValue
        case .statusHeader, .status, .copyLink, .refresh, .restart, .statusFooter:
            return TgWsProxySection.status.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case .header:
            return 0
        case .enabled:
            return 1
        case .zone:
            return 2
        case .customDomain:
            return 3
        case .settingsFooter:
            return 4
        case .statusHeader:
            return 10
        case .status:
            return 11
        case .copyLink:
            return 12
        case .refresh:
            return 13
        case .restart:
            return 14
        case .statusFooter:
            return 15
        }
    }

    static func < (lhs: TgWsProxyEntry, rhs: TgWsProxyEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! TgWsProxyControllerArguments
        switch self {
        case .header:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "TG WS Proxy", sectionId: self.section)
        case let .enabled(isOn, running):
            let detail: String
            if running {
                detail = "Traffic is going through the local proxy"
            } else if isOn {
                detail = "Starting…"
            } else {
                detail = "Using Telegram's direct connection"
            }
            return ItemListSwitchItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: "Local MTProxy",
                text: detail,
                value: isOn,
                sectionId: self.section,
                style: .blocks,
                updated: { value in
                    arguments.setEnabled(value)
                }
            )
        case let .zone(label):
            return ItemListDisclosureItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: "CloudFlare zone",
                label: label,
                labelStyle: .text,
                sectionId: self.section,
                style: .blocks,
                disclosureStyle: .arrow,
                action: {
                    arguments.presentZonePicker()
                }
            )
        case let .customDomain(value):
            return ItemListSingleLineInputItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: NSAttributedString(string: "Custom domain", font: Font.regular(17.0), textColor: presentationData.theme.list.itemPrimaryTextColor),
                text: value,
                placeholder: "Use the zone above",
                type: .regular(capitalization: false, autocorrection: false),
                returnKeyType: .done,
                clearType: .always,
                sectionId: self.section,
                textUpdated: { text in
                    arguments.setCustomDomain(text)
                },
                updatedFocus: { focused in
                    if !focused {
                        arguments.applyCustomDomain()
                    }
                },
                action: {
                    arguments.applyCustomDomain()
                }
            )
        case .settingsFooter:
            return ItemListTextItem(presentationData: presentationData, text: .plain("Leave the zone on Automatic to let the client try the known CloudFlare fronts. A custom domain overrides the zone selector. The proxy starts with the switch above and stops when the client goes to the background, so there is no background task to keep alive."), sectionId: self.section)
        case .statusHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "Status", sectionId: self.section)
        case let .status(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case .copyLink:
            return ItemListActionItem(
                presentationData: presentationData,
                title: "Copy Proxy Link",
                kind: .generic,
                alignment: .natural,
                sectionId: self.section,
                style: .blocks,
                action: {
                    arguments.copyLink()
                }
            )
        case .refresh:
            return ItemListActionItem(
                presentationData: presentationData,
                title: "Refresh Status",
                kind: .generic,
                alignment: .natural,
                sectionId: self.section,
                style: .blocks,
                action: {
                    arguments.refresh()
                }
            )
        case .restart:
            return ItemListActionItem(
                presentationData: presentationData,
                title: "Restart Proxy",
                kind: .generic,
                alignment: .natural,
                sectionId: self.section,
                style: .blocks,
                action: {
                    arguments.restart()
                }
            )
        case .statusFooter:
            return ItemListTextItem(presentationData: presentationData, text: .plain("The listener runs inside Telegram on 127.0.0.1 and carries the obfuscated MTProto stream inside CloudFlare WebSocket frames. It is the same transport as the standalone TG WS Proxy app, with the app's background work removed: when Telegram is not in the foreground, nothing here is expected to run."), sectionId: self.section)
        }
    }
}

private final class TgWsProxyControllerArguments {
    private let context: AccountContext
    private let statePromise: ValuePromise<Int32>
    private let stateValue: Atomic<Int32>
    private var refreshTimer: Foundation.Timer?

    init(context: AccountContext) {
        self.context = context
        self.statePromise = ValuePromise<Int32>(0, ignoreRepeated: true)
        self.stateValue = Atomic(value: Int32(0))
        self.refreshTimer = Foundation.Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true, block: { [weak self] _ in
            self?.bump()
        })
    }

    deinit {
        self.refreshTimer?.invalidate()
    }

    var state: Signal<Int32, NoError> {
        return self.statePromise.get()
    }

    func bump() {
        _ = self.stateValue.modify { value in
            return value &+ 1
        }
        self.statePromise.set(self.stateValue.with { $0 })
    }

    func startIfNeeded() {
        guard TgWsProxySettings.enabled, !TgWsProxyService.shared.currentStatus().running else {
            return
        }
        self.start()
    }

    func setEnabled(_ enabled: Bool) {
        if enabled {
            TgWsProxySettings.setEnabled(true)
            self.start()
        } else {
            TgWsProxySettings.setEnabled(false)
            self.stop()
        }
    }

    func setCustomDomain(_ value: String) {
        // The field already shows what was typed. Rebuilding the list on every
        // keystroke would fight the text field's focus; the value is applied
        // when editing ends, in `applyCustomDomain`.
        TgWsProxySettings.setCustomDomain(value)
    }

    /// Applies the text field when the user presses Done or leaves the field.
    /// Editing used to be stored but not dialled: the tunnel kept the old zone
    /// until "Restart Proxy" was tapped, which read as if the domain was ignored.
    func applyCustomDomain() {
        guard TgWsProxySettings.enabled else {
            self.bump()
            return
        }
        let preferred = TgWsProxySettings.preferredDomain()
        let status = TgWsProxyService.shared.currentStatus()
        // `domain` is already set while the listener is starting, so this also
        // ignores a second Done from the same edit instead of restarting the
        // tunnel that is still coming up. A recorded error means the previous
        // attempt failed and the new value is worth another try.
        if status.domain == preferred && status.error == nil {
            self.bump()
            return
        }
        self.start()
    }

    func setZone(_ index: Int) {
        TgWsProxySettings.setZoneIndex(index)
        if TgWsProxyService.shared.currentStatus().running {
            self.start()
        } else {
            self.bump()
        }
    }

    func presentZonePicker() {
        let presentationData = self.context.sharedContext.currentPresentationData.with { $0 }
        let actionSheet = ActionSheetController(presentationData: presentationData)
        var items: [ActionSheetItem] = []
        let current = TgWsProxySettings.zoneIndex
        let titles = ["Automatic"] + TgWsProxySettings.zones
        for (index, title) in titles.enumerated() {
            items.append(ActionSheetCheckboxItem(title: title, label: "", value: index == current, action: { [weak actionSheet] _ in
                actionSheet?.dismissAnimated()
                self.setZone(index)
            }))
        }
        items.append(ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
            actionSheet?.dismissAnimated()
        }))
        actionSheet.setItemGroups([ActionSheetItemGroup(items: items)])
        self.context.sharedContext.presentGlobalController(actionSheet, nil)
    }

    func refresh() {
        self.bump()
    }

    func restart() {
        guard TgWsProxyService.shared.currentStatus().running || TgWsProxySettings.enabled else {
            return
        }
        self.start()
    }

    func copyLink() {
        guard let link = TgWsProxyService.shared.currentStatus().link else {
            return
        }
        UIPasteboard.general.string = link
    }

    private func start() {
        let preferred = TgWsProxySettings.preferredDomain()
        let zones = TgWsProxySettings.zonesInOrder(preferred: preferred)
        TgWsProxySettings.setEnabled(true)
        self.bump()
        TgWsProxyService.shared.start(
            domain: preferred,
            zones: zones,
            accountManager: self.context.sharedContext.accountManager,
            completion: { [weak self] status in
                Queue.mainQueue().async {
                    guard let self = self else {
                        return
                    }
                    if !status.running {
                        TgWsProxySettings.setEnabled(false)
                    }
                    self.bump()
                }
            }
        )
    }

    private func stop() {
        self.bump()
        TgWsProxyService.shared.stop(
            accountManager: self.context.sharedContext.accountManager,
            completion: { [weak self] _ in
                Queue.mainQueue().async {
                    self?.bump()
                }
            }
        )
    }
}

private func tgWsProxyEntries(enabled: Bool, running: Bool, zoneLabel: String, customDomain: String, statusText: String, link: String?) -> [TgWsProxyEntry] {
    var entries: [TgWsProxyEntry] = []
    entries.append(.header)
    entries.append(.enabled(isOn: enabled, running: running))
    entries.append(.zone(label: zoneLabel))
    entries.append(.customDomain(value: customDomain))
    entries.append(.settingsFooter)
    entries.append(.statusHeader)
    entries.append(.status(text: statusText))
    if link != nil {
        entries.append(.copyLink)
    }
    entries.append(.refresh)
    if running {
        entries.append(.restart)
    }
    entries.append(.statusFooter)
    return entries
}

private func tgWsProxyStatusText() -> String {
    let status = TgWsProxyService.shared.currentStatus()
    if status.running {
        var lines = ["Running on \(status.host):\(status.port)"]
        lines.append("Zone: \(status.domain.isEmpty ? "automatic" : status.domain)")
        lines.append("Active in Telegram: \(status.active ? "yes" : "no")")
        lines.append("Connections: \(status.connections) · upstreams: \(status.upstreams)")
        if let error = status.error, !error.isEmpty {
            lines.append("Error: \(error)")
        }
        if let upstreamError = status.upstreamError, !upstreamError.isEmpty {
            lines.append("Last upstream error: \(upstreamError)")
        }
        return lines.joined(separator: "\n")
    }
    if let error = status.error, !error.isEmpty {
        return "Stopped.\nError: \(error)"
    }
    return "Stopped."
}

/// Starts the extension at launch when the user left its switch on.
///
/// Called from `AppDelegate` as part of the app's own launch path, not from the
/// plugin runtime. The caller skips it while Safe Mode is on, so a session that
/// ended in a crash does not immediately start the same extension again. No UI
/// is touched here; the settings screen observes the same shared
/// `TgWsProxyService`.
public func startTgWsProxyIfEnabled(sharedContext: SharedAccountContext) {
    guard TgWsProxySettings.enabled else {
        return
    }
    guard !TgWsProxyService.shared.currentStatus().running else {
        return
    }
    let preferred = TgWsProxySettings.preferredDomain()
    let zones = TgWsProxySettings.zonesInOrder(preferred: preferred)
    TgWsProxyService.shared.start(
        domain: preferred,
        zones: zones,
        accountManager: sharedContext.accountManager,
        completion: { status in
            if !status.running {
                TgWsProxySettings.setEnabled(false)
            }
        }
    )
}

public func tgWsProxyController(context: AccountContext) -> ViewController {
    let arguments = TgWsProxyControllerArguments(context: context)
    if TgWsProxyService.shared.currentStatus().running {
        // The installed plugin may have started the same listener. The switch
        // should show the truth instead of "off" while traffic is tunnelled.
        TgWsProxySettings.setEnabled(true)
    } else {
        arguments.startIfNeeded()
    }

    let signal = combineLatest(
        context.sharedContext.presentationData,
        arguments.state
    )
    |> deliverOnMainQueue
    |> map { presentationData, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let status = TgWsProxyService.shared.currentStatus()
        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text("TG WS Proxy"),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
        )
        let listState = ItemListNodeState(
            presentationData: ItemListPresentationData(presentationData),
            entries: tgWsProxyEntries(
                enabled: TgWsProxySettings.enabled,
                running: status.running,
                zoneLabel: TgWsProxySettings.zoneLabel,
                customDomain: TgWsProxySettings.customDomain,
                statusText: tgWsProxyStatusText(),
                link: status.link
            ),
            style: .blocks,
            animateChanges: true
        )
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    return controller
}