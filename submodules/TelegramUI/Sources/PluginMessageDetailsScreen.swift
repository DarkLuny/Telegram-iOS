import Foundation
import UIKit
import Display
import TelegramCore
import TelegramPresentationData
import AccountContext

/// Builds the "message details" sheet for rows a plugin asked to show.
///
/// iOS has no details screen of its own for a message; the Android app grew one
/// and the plugin fills it. Rather than invent a navigation stack for it, the rows
/// go into an action sheet — the platform already scrolls, themes and dismisses
/// those, and the caller already knows how to present one.
///
/// Every row is a title/value pair on one line, because a details sheet is read as
/// a list of keyed values and a two-line row doubles the scrolling for nothing.
/// Tapping a row copies it; one button copies the whole list, which is what a
/// details screen is almost always opened for.
enum PluginMessageDetailsSheet {
    static func make(presentationData: PresentationData, items: [PluginDetailItem]) -> ActionSheetController? {
        guard !items.isEmpty else {
            return nil
        }
        let actionSheet = ActionSheetController(presentationData: presentationData)

        let details = items.map { item -> ActionSheetItem in
            return ActionSheetTextItem(title: "**\(pluginDetailsEscaped(item.title)):** \(pluginDetailsEscaped(item.value))", parseMarkdown: true)
        }

        let whole = items.map { "\($0.title): \($0.value)" }.joined(separator: "\n")
        actionSheet.setItemGroups([
            ActionSheetItemGroup(items: details),
            ActionSheetItemGroup(items: [
                ActionSheetButtonItem(title: presentationData.strings.Conversation_ContextMenuCopy, action: { [weak actionSheet] in
                    UIPasteboard.general.string = whole
                    actionSheet?.dismissAnimated()
                })
            ]),
            ActionSheetItemGroup(items: [
                ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, font: .bold, action: { [weak actionSheet] in
                    actionSheet?.dismissAnimated()
                })
            ])
        ])
        return actionSheet
    }

    /// Escapes the characters markdown would otherwise eat.
    ///
    /// A message's file name can contain `*` or `_`, and an unescaped value would
    /// silently turn half a details row bold or italic. The text item is rendered
    /// as markdown because that is how the bold title is produced, so the values
    /// have to be neutralized first.
    private static func pluginDetailsEscaped(_ text: String) -> String {
        var result = text
        for character in ["\\", "*", "_", "`", "[", "]"] {
            result = result.replacingOccurrences(of: character, with: "\\" + character)
        }
        return result
    }
}