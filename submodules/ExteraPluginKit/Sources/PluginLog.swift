import Foundation

/// Minimal logger so the plugin runtime has no dependency on TelegramCore.
///
/// `os_log` would be tidier, but keeping this to Foundation means the module
/// compiles and unit-tests without the rest of the app. Everything goes to the
/// shared log file in the app's Library directory, which is what a user needs
/// when a plugin misbehaves on a sideloaded build with no debugger attached.
public enum PluginLog {
    private static let queue = DispatchQueue(label: "extera.pluginkit.log")
    private static let maxBytes = 256 * 1024

    public static var logFileURL: URL {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("extera-plugins.log")
    }

    public static func write(pluginId: String, text: String) {
        let line = "[\(pluginId)] \(text)\n"
        #if DEBUG
        print("PluginKit \(line)", terminator: "")
        #endif
        self.queue.async {
            let url = self.logFileURL
            let data = Data(line.utf8)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                handle.write(data)
                if handle.offsetInFile > UInt64(self.maxBytes) {
                    try? handle.truncate(atOffset: 0)
                }
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    /// Last `lines` log lines, newest last. Used by the plugin manager screen.
    public static func recentLines(limit: Int) -> [String] {
        guard let text = try? String(contentsOf: self.logFileURL, encoding: .utf8) else {
            return []
        }
        let all = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        return Array(all.suffix(limit))
    }

    public static func clear() {
        try? FileManager.default.removeItem(at: self.logFileURL)
    }
}