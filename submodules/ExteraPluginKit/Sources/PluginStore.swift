import Foundation

/// Where plugins live and how their state is persisted.
///
/// exteraGram keeps plugins inside Android's private app storage and its
/// settings in SharedPreferences. On iOS the equivalent is the app's Documents
/// directory (visible in Files when the app opts in) and UserDefaults. Nothing
/// here needs the App Group, so it keeps working after a sideload re-sign.
public final class PluginStore {
    public static let shared = PluginStore()

    private let fileManager = FileManager.default

    public init() {
    }

    /// `<Documents>/Plugins`. Created on first access.
    public var pluginsDirectory: URL {
        let documents = self.fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = documents.appendingPathComponent("Plugins", isDirectory: true)
        if !self.fileManager.fileExists(atPath: url.path) {
            try? self.fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
        }
        return url
    }

    public func directory(for pluginId: String) -> URL {
        return self.pluginsDirectory.appendingPathComponent(pluginId, isDirectory: true)
    }

    /// Every plugin source file, sorted for a stable load order.
    ///
    /// `.plugin` matches exteraGram's extension so a plugin can be dropped in
    /// unchanged; `.js` is accepted so authors can use ordinary tooling.
    public func pluginSources() -> [(id: String, url: URL)] {
        let contents = (try? self.fileManager.contentsOfDirectory(
            at: self.pluginsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var result: [(String, URL)] = []
        for url in contents {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory {
                // A bundle-style plugin: `<id>/main.plugin` or `<id>/main.js`.
                for candidate in ["main.plugin", "main.js", "plugin.js"] {
                    let file = url.appendingPathComponent(candidate)
                    if self.fileManager.fileExists(atPath: file.path) {
                        result.append((url.lastPathComponent, file))
                        break
                    }
                }
            } else if url.pathExtension == "plugin" || url.pathExtension == "js" {
                result.append((url.deletingPathExtension().lastPathComponent, url))
            }
        }
        return result.sorted { $0.0 < $1.0 }
    }

    /// Installs (or replaces) a plugin from the bytes of a picked file.
    ///
    /// The old directory is removed first: a plugin previously installed as a
    /// bundle (`<id>/main.js`) would otherwise keep that file next to the new
    /// `main.plugin`, and `pluginSources()` prefers `main.plugin`, so the two
    /// could disagree about what the plugin is. Reinstalling also clears a
    /// "disabled" flag left behind by an earlier removal.
    public func install(data: Data, pluginId: String) throws {
        let directory = self.directory(for: pluginId)
        try? self.fileManager.removeItem(at: directory)
        try self.fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        try data.write(to: directory.appendingPathComponent("main.plugin"), options: .atomic)
        self.setEnabled(true, pluginId: pluginId)
    }

    /// Removes the plugin and everything the user configured for it, so a later
    /// install of the same id starts from its own defaults instead of inheriting
    /// settings that belonged to the removed copy.
    public func remove(pluginId: String) {
        try? self.fileManager.removeItem(at: self.directory(for: pluginId))
        // A plugin dropped in by hand may be a flat `<id>.plugin` / `<id>.js`
        // rather than a bundle folder; both shapes are removed.
        for suffix in ["plugin", "js"] {
            try? self.fileManager.removeItem(at: self.pluginsDirectory.appendingPathComponent("\(pluginId).\(suffix)"))
        }
        UserDefaults.standard.removeObject(forKey: self.settingsPrefix + pluginId)
        self.setEnabled(true, pluginId: pluginId)
    }

    // MARK: - Settings

    private var settingsPrefix: String { "extera.plugin.settings." }

    public func settings(for pluginId: String) -> [String: Any] {
        return (UserDefaults.standard.dictionary(forKey: self.settingsPrefix + pluginId)) ?? [:]
    }

    public func setSettings(_ values: [String: Any], for pluginId: String) {
        UserDefaults.standard.set(values, forKey: self.settingsPrefix + pluginId)
    }

    public func setSetting(_ key: String, value: Any?, for pluginId: String) {
        var current = self.settings(for: pluginId)
        if let value = value {
            current[key] = value
        } else {
            current.removeValue(forKey: key)
        }
        self.setSettings(current, for: pluginId)
    }

    // MARK: - Enabled state

    private var enabledKey: String { "extera.plugin.enabled" }

    public func isEnabled(_ pluginId: String) -> Bool {
        let disabled = (UserDefaults.standard.array(forKey: self.enabledKey) as? [String]) ?? []
        return !disabled.contains(pluginId)
    }

    public func setEnabled(_ enabled: Bool, pluginId: String) {
        var disabled = Set((UserDefaults.standard.array(forKey: self.enabledKey) as? [String]) ?? [])
        if enabled {
            disabled.remove(pluginId)
        } else {
            disabled.insert(pluginId)
        }
        UserDefaults.standard.set(Array(disabled), forKey: self.enabledKey)
    }
}