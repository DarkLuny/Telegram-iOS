import Foundation

/// The filesystem surface `file_utils` exposes to plugins.
///
/// exteraGram hands plugins a path and lets them call `open()`: the Python
/// process already runs inside the app, so nothing is checked. Here the
/// JavaScript is sandboxed but the *files* are not, and a plugin is arbitrary
/// code from the internet. Every path therefore has to resolve inside one of two
/// roots — the plugin's own folder and the app's Documents directory — before any
/// byte is read or written. `..` cannot be used to climb out, and an absolute
/// path outside those roots is refused rather than silently redirected.
///
/// The result of an operation is a JSON value (a string, a bool, or an array of
/// names), because the bridge carries text only.
enum PluginFileAccess {
    /// Roots a plugin may touch. A plugin directory is inside Documents, so the
    /// second root alone would be enough for it; keeping both makes the check
    /// read like the exteraGram docs, where "the plugins dir" and "the app files
    /// dir" are distinct places.
    static func allowedRoots(for pluginId: String) -> [URL] {
        var roots: [URL] = []
        roots.append(PluginStore.shared.directory(for: pluginId))
        if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            roots.append(documents)
        }
        return roots.map { $0.standardizedFileURL }
    }

    /// Resolves `path` against the roots, or nil when it escapes all of them.
    ///
    /// A relative path is taken relative to the plugin's own directory, which is
    /// what a plugin that writes `"cache.json"` expects.
    static func resolve(path: String, pluginId: String) -> URL? {
        let roots = allowedRoots(for: pluginId)
        guard let base = roots.first else {
            return nil
        }
        let expanded = (path as NSString).expandingTildeInPath
        let candidate = expanded.hasPrefix("/")
            ? URL(fileURLWithPath: expanded)
            : base.appendingPathComponent(expanded)
        let standardized = candidate.standardizedFileURL

        for root in roots {
            let rootPath = root.path
            let candidatePath = standardized.path
            if candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/") {
                return standardized
            }
        }
        return nil
    }

    /// Standard directories that do not need a path argument.
    static func directory(for op: String, pluginId: String) -> String? {
        let plugins = PluginStore.shared.directory(for: pluginId)
        let fileManager = FileManager.default
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
        switch op {
        case "cache_dir":
            return caches?.appendingPathComponent("Plugins").appendingPathComponent(pluginId).path
        case "files_dir", "documents_dir":
            return documents?.path
        case "images_dir":
            return documents?.appendingPathComponent("Images").path
        case "videos_dir":
            return documents?.appendingPathComponent("Videos").path
        case "audios_dir":
            return documents?.appendingPathComponent("Audio").path
        default:
            return plugins.path
        }
    }

    /// Runs one `file_utils` call and returns a JSON document.
    ///
    /// The bridge carries text only, so every value is encoded the same way:
    /// `"a/path"`, `true`, `null`, `["a.txt"]`. The JavaScript side decodes it
    /// with `JSON.parse`, which keeps booleans booleans — a plugin writing
    /// `if not write_file(...)` must see `false`, not the string `"false"`.
    static func perform(pluginId: String, op: String, path: String, payload: String?) -> String? {
        let fileManager = FileManager.default

        if ["cache_dir", "files_dir", "images_dir", "videos_dir", "audios_dir", "documents_dir", "plugins_dir"].contains(op) {
            return encode(directory(for: op, pluginId: pluginId))
        }

        guard let url = resolve(path: path, pluginId: pluginId) else {
            PluginLog.write(pluginId: pluginId, text: "file_utils refused a path outside the plugin folder: \(path)")
            return "false"
        }

        switch op {
        case "ensure_dir":
            do {
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
                return "true"
            } catch {
                PluginLog.write(pluginId: pluginId, text: "ensure_dir failed: \(error)")
                return "false"
            }

        case "read_text":
            // `String(contentsOf:encoding:)` is deprecated in the current SDK
            // and the build treats warnings as errors, so the bytes are read
            // first and decoded explicitly.
            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8) else {
                return "null"
            }
            return encode(text)

        case "write_text":
            do {
                try (payload ?? "").write(to: url, atomically: true, encoding: .utf8)
                return "true"
            } catch {
                PluginLog.write(pluginId: pluginId, text: "write_file failed: \(error)")
                return "false"
            }

        case "read_bytes":
            // Base64 rather than a byte array: the bridge is string-only, and
            // this is the form that survives it unchanged.
            guard let data = try? Data(contentsOf: url) else {
                return "null"
            }
            return encode(data.base64EncodedString())

        case "write_bytes":
            guard let data = Data(base64Encoded: payload ?? "") else {
                return "false"
            }
            do {
                try data.write(to: url, options: .atomic)
                return "true"
            } catch {
                PluginLog.write(pluginId: pluginId, text: "write_file_bytes failed: \(error)")
                return "false"
            }

        case "list_dir":
            return listDirectory(at: url, optionsJSON: payload)

        case "delete":
            do {
                try fileManager.removeItem(at: url)
                return "true"
            } catch {
                return "false"
            }

        case "exists":
            return fileManager.fileExists(atPath: url.path) ? "true" : "false"

        default:
            PluginLog.write(pluginId: pluginId, text: "unknown file_utils operation: \(op)")
            return "false"
        }
    }

    /// `list_dir(path, recursive=..., include_files=..., include_dirs=...,
    /// extensions=[...])` from the SDK.
    ///
    /// The options arrive as a JSON object in `payload`, because the bridge has
    /// one string slot for them. Names are relative to `url` when recursing, which
    /// is what a caller walking a tree expects; a filtered list simply skips the
    /// entries that do not match.
    private static func listDirectory(at url: URL, optionsJSON: String?) -> String {
        var recursive = false
        var includeFiles = true
        var includeDirs = false
        var extensions: [String] = []

        if let optionsJSON = optionsJSON, let data = optionsJSON.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            recursive = (object["recursive"] as? Bool) ?? false
            includeFiles = (object["include_files"] as? Bool) ?? true
            includeDirs = (object["include_dirs"] as? Bool) ?? false
            extensions = ((object["extensions"] as? [Any]) ?? []).compactMap { value in
                (value as? String)?.lowercased()
            }
        }

        let fileManager = FileManager.default
        var names: [String] = []

        func visit(_ directory: URL, prefix: String) {
            let contents = (try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for entry in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                let name = prefix.isEmpty ? entry.lastPathComponent : prefix + "/" + entry.lastPathComponent
                if isDirectory {
                    if includeDirs {
                        names.append(name)
                    }
                    if recursive {
                        visit(entry, prefix: name)
                    }
                } else if includeFiles {
                    if extensions.isEmpty || extensions.contains(entry.pathExtension.lowercased()) {
                        names.append(name)
                    }
                }
            }
        }

        visit(url, prefix: "")

        guard let data = try? JSONSerialization.data(withJSONObject: names, options: []),
              let text = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return text
    }

    /// A string as a JSON literal, `null` when there is no value.
    private static func encode(_ value: String?) -> String {
        guard let value = value,
              let data = try? JSONSerialization.data(withJSONObject: [value], options: []),
              let text = String(data: data, encoding: .utf8) else {
            return "null"
        }
        // `["..."]` -> `"..."`: the array wrapper is only there to make
        // `JSONSerialization` accept a bare string.
        return String(text.dropFirst().dropLast())
    }
}