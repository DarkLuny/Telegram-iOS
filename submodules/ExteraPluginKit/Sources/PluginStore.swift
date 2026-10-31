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
        // Installing it back clears the "user deleted this" mark, so a later
        // launch does not skip the bundled copy for a plugin the user has again.
        var removed = Set((UserDefaults.standard.array(forKey: self.removedKey) as? [String]) ?? [])
        removed.remove(pluginId)
        UserDefaults.standard.set(Array(removed), forKey: self.removedKey)
        // And the file is the user's now, so an app update no longer rewrites it.
        var bundled = Set((UserDefaults.standard.array(forKey: self.bundledKey) as? [String]) ?? [])
        bundled.remove(pluginId)
        UserDefaults.standard.set(Array(bundled), forKey: self.bundledKey)
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
        // Remembered so the bundled copy is not put back on the next launch: a
        // plugin the user removed must stay removed, even though the app ships
        // with it.
        var removed = Set((UserDefaults.standard.array(forKey: self.removedKey) as? [String]) ?? [])
        removed.insert(pluginId)
        UserDefaults.standard.set(Array(removed), forKey: self.removedKey)
        var bundled = Set((UserDefaults.standard.array(forKey: self.bundledKey) as? [String]) ?? [])
        bundled.remove(pluginId)
        UserDefaults.standard.set(Array(bundled), forKey: self.bundledKey)
    }

    /// Ids of bundled plugins the user deleted on purpose.
    ///
    /// Separate from the "disabled" list: disabling keeps the file and lets the
    /// user turn it back on, while removing it means the app should stop offering
    /// it. Without this a removed plugin would reappear on every launch, because
    /// the bundle would reinstall it.
    private var removedKey: String { "extera.plugin.removed" }

    public func isRemoved(_ pluginId: String) -> Bool {
        let removed = (UserDefaults.standard.array(forKey: self.removedKey) as? [String]) ?? []
        return removed.contains(pluginId)
    }

    /// Installs a plugin that ships with the app.
    ///
    /// Answers whether anything was written. Three cases:
    ///
    ///   - The user removed it: left removed, so the app does not put back a
    ///     plugin somebody deleted on purpose.
    ///   - The user installed their own copy (or a newer one) with the file
    ///     picker: left alone. The bundle is a starting point, not an update
    ///     channel for third-party code.
    ///   - The copy on disk is the one this app wrote: rewritten. A port fix then
    ///     reaches the device with the IPA instead of needing a reinstall of the
    ///     plugin by hand.
    @discardableResult
    public func installBundled(pluginId: String, source: String) -> Bool {
        guard !self.isRemoved(pluginId) else {
            return false
        }
        let directory = self.directory(for: pluginId)
        let file = directory.appendingPathComponent("main.plugin")
        let bundled = Set((UserDefaults.standard.array(forKey: self.bundledKey) as? [String]) ?? [])
        if self.fileManager.fileExists(atPath: file.path) && !bundled.contains(pluginId) {
            return false
        }
        // A flat `<id>.plugin` or a bundle with `main.js` is something the user
        // put there; `pluginSources()` reads either, so writing `main.plugin`
        // next to it would install the plugin twice.
        if !bundled.contains(pluginId) {
            for candidate in [directory.appendingPathComponent("main.js"),
                              self.pluginsDirectory.appendingPathComponent("\(pluginId).plugin"),
                              self.pluginsDirectory.appendingPathComponent("\(pluginId).js")] {
                if self.fileManager.fileExists(atPath: candidate.path) {
                    return false
                }
            }
        }
        do {
            try self.fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
            // `String(contentsOf:encoding:)` is deprecated in the current SDK and
            // the build treats warnings as errors, so the bytes are compared
            // instead: an unchanged file is not rewritten on every launch.
            if let existing = try? Data(contentsOf: file), existing == Data(source.utf8) {
                return false
            }
            try source.write(to: file, atomically: true, encoding: .utf8)
            var updated = bundled
            updated.insert(pluginId)
            UserDefaults.standard.set(Array(updated), forKey: self.bundledKey)
            return true
        } catch {
            return false
        }
    }

    /// Ids whose file on disk came from the app bundle.
    ///
    /// Lets a later launch tell "this is our copy, keep it current" from "the
    /// user installed this themselves, do not touch it" without comparing bytes.
    private var bundledKey: String { "extera.plugin.bundled" }

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