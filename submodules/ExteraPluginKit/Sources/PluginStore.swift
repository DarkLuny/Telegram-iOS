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

    /// Serialises the two things that write to the plugins directory: an install,
    /// and the sweep that removes what an older build left behind. They can run on
    /// different queues — an install from the main queue after a picked file, the
    /// sweep from the script queue — and without this one could delete the file
    /// the other had just written.
    private let fileLock = NSLock()

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
        self.fileLock.lock()
        defer { self.fileLock.unlock() }
        let directory = self.directory(for: pluginId)
        try? self.fileManager.removeItem(at: directory)
        try self.fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        try data.write(to: directory.appendingPathComponent("main.plugin"), options: .atomic)
        self.setEnabled(true, pluginId: pluginId)
        // This file is the user's now, so the sweep that removes what an older
        // build wrote must never claim it. The id is dropped from that list here
        // rather than relying on the sweep having already run: a plugin installed
        // while the app is loading would otherwise be deleted a moment later.
        self.clearLegacyBundledMark(pluginId: pluginId)
    }

    /// Removes the plugin and everything the user configured for it, so a later
    /// install of the same id starts from its own defaults instead of inheriting
    /// settings that belonged to the removed copy.
    public func remove(pluginId: String) {
        self.fileLock.lock()
        defer { self.fileLock.unlock() }
        try? self.fileManager.removeItem(at: self.directory(for: pluginId))
        // A plugin dropped in by hand may be a flat `<id>.plugin` / `<id>.js`
        // rather than a bundle folder; both shapes are removed.
        for suffix in ["plugin", "js"] {
            try? self.fileManager.removeItem(at: self.pluginsDirectory.appendingPathComponent("\(pluginId).\(suffix)"))
        }
        UserDefaults.standard.removeObject(forKey: self.settingsPrefix + pluginId)
        self.setEnabled(true, pluginId: pluginId)
        self.clearLegacyBundledMark(pluginId: pluginId)
    }

    // MARK: - Copies an older build wrote

    /// Ids whose file on disk came from an older build that shipped the plugins
    /// inside the binary.
    ///
    /// That build wrote `<id>/main.plugin` itself and recorded the id here, which
    /// is how it told "our copy, keep it current" from "the user installed this".
    /// Since a plugin now arrives as a `.plugin` file, nothing updates those
    /// copies any more: an app update leaves a stale script on disk that keeps
    /// running, which is what made a fixed plugin still show its old text.
    private var legacyBundledKey: String { "extera.plugin.bundled" }

    /// Forgets that `pluginId` ever came from an older build's binary.
    ///
    /// Called when the user installs the plugin themselves: from that moment the
    /// file on disk is theirs, and the sweep below must not touch it even if it
    /// has not run yet.
    private func clearLegacyBundledMark(pluginId: String) {
        guard var ids = UserDefaults.standard.array(forKey: self.legacyBundledKey) as? [String],
              ids.contains(pluginId) else {
            return
        }
        ids.removeAll { $0 == pluginId }
        if ids.isEmpty {
            UserDefaults.standard.removeObject(forKey: self.legacyBundledKey)
        } else {
            UserDefaults.standard.set(ids, forKey: self.legacyBundledKey)
        }
    }

    /// Deletes the plugins an older build installed, once.
    ///
    /// Only ids recorded in `extera.plugin.bundled` are touched, so a plugin the
    /// user installed from a file is never removed. Settings are left alone: the
    /// code is what is stale, not the switches, and reinstalling the same
    /// `.plugin` should find the configuration the user already had.
    ///
    /// Runs before the first load so a stale script cannot answer a single hook.
    /// A backfill for the build that shipped seven plugins: once it has removed
    /// what that build left behind the key is gone, so this is a no-op.
    ///
    /// Returns the ids it removed, so the caller can say so in the log instead of
    /// letting the plugins vanish silently.
    @discardableResult
    public func removeLegacyBundledPlugins() -> [String] {
        self.fileLock.lock()
        defer { self.fileLock.unlock() }
        guard let ids = UserDefaults.standard.array(forKey: self.legacyBundledKey) as? [String], !ids.isEmpty else {
            return []
        }
        for pluginId in ids {
            // A directory form is a whole installation; the flat forms are what
            // `pluginSources()` also reads, and either shape is ours to remove.
            try? self.fileManager.removeItem(at: self.directory(for: pluginId))
            for suffix in ["plugin", "js"] {
                try? self.fileManager.removeItem(at: self.pluginsDirectory.appendingPathComponent("\(pluginId).\(suffix)"))
            }
        }
        UserDefaults.standard.removeObject(forKey: self.legacyBundledKey)
        // The sibling key that old build used for "the user deleted our copy".
        // It names ids that are not on disk either way, so leaving it would only
        // keep a second stale list alive.
        UserDefaults.standard.removeObject(forKey: "extera.plugin.removed")
        return ids
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