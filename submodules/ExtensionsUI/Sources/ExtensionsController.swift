import Foundation
import UIKit
import Display
import AccountContext
import TelegramCore
import TelegramPresentationData
import PresentationDataUtils
import SwiftSignalKit
import ItemListUI

/// The top-level Extensions menu.
///
/// Extensions are built into the client, not installed as plugins and not
/// evaluated by the plugin runtime. This list is the app's own entry point for
/// them; the TG WS Proxy transport lives in TelegramCore and keeps working when
/// plugins are disabled.
private enum ExtensionsSection: Int32 {
    case extensions
}

private enum ExtensionsEntry: ItemListNodeEntry {
    case header
    case tgWsProxy(enabled: Bool, running: Bool)
    case footer

    var section: ItemListSectionId {
        return ExtensionsSection.extensions.rawValue
    }

    var stableId: Int32 {
        switch self {
        case .header:
            return 0
        case .tgWsProxy:
            return 1
        case .footer:
            return 2
        }
    }

    var sortIndex: Int32 {
        switch self {
        case .header:
            return 0
        case .tgWsProxy:
            return 1
        case .footer:
            return 2
        }
    }

    static func < (lhs: ExtensionsEntry, rhs: ExtensionsEntry) -> Bool {
        return lhs.sortIndex < rhs.sortIndex
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! ExtensionsControllerArguments
        switch self {
        case .header:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "Built-in", sectionId: self.section)
        case let .tgWsProxy(enabled, running):
            let label: String
            if running {
                label = "On"
            } else if enabled {
                label = "Starting…"
            } else {
                label = "Off"
            }
            return ItemListDisclosureItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: "TG WS Proxy",
                label: label,
                labelStyle: .text,
                additionalDetailLabel: "CloudFlare WebSocket tunnel",
                sectionId: self.section,
                style: .blocks,
                disclosureStyle: .arrow,
                action: {
                    arguments.openTgWsProxy()
                }
            )
        case .footer:
            return ItemListTextItem(
                presentationData: presentationData,
                text: .plain("Extensions are part of Telegram itself. They are not plugins: they do not need JavaScript, they are not listed under Plugins, and they keep working with plugins disabled. TG WS Proxy runs on 127.0.0.1 inside the client and does not schedule background work."),
                sectionId: self.section
            )
        }
    }
}

private final class ExtensionsControllerArguments {
    private let context: AccountContext
    private let statePromise = ValuePromise<Int32>(0, ignoreRepeated: true)
    private let stateValue = Atomic(value: Int32(0))
    private var refreshTimer: Foundation.Timer?
    fileprivate weak var controller: ViewController?

    init(context: AccountContext) {
        self.context = context
        self.refreshTimer = Foundation.Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true, block: { [weak self] _ in
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

    func openTgWsProxy() {
        let controller = tgWsProxyController(context: self.context)
        if let navigationController = self.controller?.navigationController {
            navigationController.pushViewController(controller, animated: true)
        } else {
            self.context.sharedContext.presentGlobalController(controller, nil)
        }
    }
}

public func extensionsController(context: AccountContext) -> ViewController {
    let arguments = ExtensionsControllerArguments(context: context)

    let signal = combineLatest(
        context.sharedContext.presentationData,
        arguments.state
    )
    |> deliverOnMainQueue
    |> map { presentationData, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let status = TgWsProxyService.shared.currentStatus()
        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text("Extensions"),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
        )
        let entries: [ExtensionsEntry] = [
                .header,
                .tgWsProxy(enabled: TgWsProxySettings.enabled, running: status.running),
                .footer
            ]
        let listState = ItemListNodeState(
            presentationData: ItemListPresentationData(presentationData),
            entries: entries,
            style: .blocks,
            animateChanges: true
        )
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    arguments.controller = controller
    return controller
}