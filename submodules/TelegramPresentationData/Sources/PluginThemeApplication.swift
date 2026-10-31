import Foundation
import UIKit
import Display
import TelegramCore
import TelegramUIPreferences

/// Asks the plugins what accent they want and repaints `theme` with it.
///
/// The call goes through the hook rather than a stored value so the answer is
/// always the plugin's current one: a plugin that repaints itself after a
/// setting change speaks again on the next rebuild. With no plugins loaded the
/// hook returns `nil` and the theme is returned untouched.
///
/// No account id is passed. The theme is built once per shared context, before
/// any single account owns the screen, and the colour a plugin wants is not
/// per-account anyway -- exteraGram has one accent for the whole app.
public func applyPluginThemeOverride(_ theme: PresentationTheme) -> PresentationTheme {
    return applyPluginThemeOverride(theme, override: PluginHookPoints.shared.themeOverride?(nil))
}

/// Repaints a built theme with an explicit override, or returns it unchanged.
public func applyPluginThemeOverride(_ theme: PresentationTheme, override: PluginThemeOverride?) -> PresentationTheme {
    guard let override = override else {
        return theme
    }
    let accent = UIColor(rgb: override.main)
    // Without an explicit bubble colour the existing bubbles are passed back in,
    // so recolouring the interface does not silently repaint sent messages. With
    // one, both ends of the gradient are the plugin's colour and the derived
    // tints (highlight, text, links) come out consistent on their own.
    let bubbles: [UInt32]
    if let requested = override.bubbleColors {
        bubbles = requested
    } else if let current = theme.chat.message.outgoing.bubble.withWallpaper.fill.first {
        bubbles = [current.rgb]
    } else {
        bubbles = []
    }
    return customizePresentationTheme(
        theme,
        editing: true,
        title: nil,
        accentColor: accent,
        outgoingAccentColor: nil,
        backgroundColors: [],
        bubbleColors: bubbles,
        animateBubbleColors: false,
        wallpaper: nil
    )
}