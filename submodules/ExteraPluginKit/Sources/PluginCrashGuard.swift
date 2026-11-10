import Foundation

/// Keeps the one piece of state that has to survive a crash: whether the client
/// got as far as the next launch while a plugin was running.
///
/// The plugin manager cannot catch a crash in plugin JavaScript from inside the
/// same process — the process is already gone. What it can do is leave a small
/// file behind while it is alive, remove it when the app goes to the background,
/// and notice on the next launch that the file is still there. That is the
/// signal Safe Mode uses: the previous foreground session ended without the app
/// reaching a normal background transition, so a plugin was the most likely
/// cause and no plugin should run this time.
///
/// The crash log is deliberately a plain text file next to `PluginLog`, not a
/// symbolicated crash report. It records the last plugin activity the manager
/// saw and the tail of the plugin log, which is what identifies the plugin that
/// was running when the client died; the system's own crash report remains the
/// place to look for a stack trace.
public final class PluginCrashGuard {
    public static let shared = PluginCrashGuard()

    /// The single global switch. A value here disables *every* plugin; there is
    /// no per-plugin safe mode, because the user cannot know which plugin is
    /// responsible until the client starts again.
    public static let safeModeKey = "extera.plugins.safe_mode"
    private static let lastCrashKey = "extera.plugins.last_crash"
    private static let sentinelFileName = "extera-plugin-session.txt"
    private static let crashLogFileName = "extera-plugin-crashes.log"
    private static let crashLogLimit = 512 * 1024

    private let lock = NSLock()
    private var hasBegunSession = false
    private var currentActivity = "launch"

    private init() {
    }

    // MARK: - Paths

    private static var libraryDirectory: URL {
        return FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
    }

    public static var crashLogURL: URL {
        return self.libraryDirectory.appendingPathComponent(self.crashLogFileName)
    }

    private static var sentinelURL: URL {
        return self.libraryDirectory.appendingPathComponent(self.sentinelFileName)
    }

    // MARK: - Safe Mode

    public var isSafeModeEnabled: Bool {
        get {
            return UserDefaults.standard.bool(forKey: PluginCrashGuard.safeModeKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: PluginCrashGuard.safeModeKey)
        }
    }

    /// A short description of the last crash, shown under the Safe Mode switch.
    public var lastCrashSummary: String? {
        return UserDefaults.standard.string(forKey: PluginCrashGuard.lastCrashKey)
    }

    // MARK: - Session lifecycle

    /// Called once, before the first plugin is evaluated.
    ///
    /// A sentinel left by the previous process means that process did not reach
    /// the background handler. The crash is appended to the retained log and
    /// Safe Mode is switched on *before* `PluginManager.startLoading` gets a
    /// chance to evaluate anything, so the next launch is the clean one.
    @discardableResult
    public func beginSession() -> Bool {
        self.lock.lock()
        let alreadyBegan = self.hasBegunSession
        self.hasBegunSession = true
        self.lock.unlock()
        guard !alreadyBegan else {
            return false
        }

        self.installExceptionHandler()

        var crashed = false
        if let sentinel = try? String(contentsOf: PluginCrashGuard.sentinelURL, encoding: .utf8) {
            crashed = true
            let summary = PluginCrashGuard.summary(from: sentinel)
            self.isSafeModeEnabled = true
            UserDefaults.standard.set(summary, forKey: PluginCrashGuard.lastCrashKey)
            self.appendCrashLog(
                title: "Previous session ended unexpectedly",
                details: [
                    "Safe Mode was enabled automatically.",
                    "Last activity: \(PluginCrashGuard.activity(from: sentinel))",
                ]
            )
        }

        // A fresh sentinel for this session. It is removed when the app enters
        // the background, so a normal swipe-to-quit is not a crash.
        self.writeSentinel(activity: crashed ? "launch after crash" : "launch")
        self.currentActivity = "launch"
        return crashed
    }

    /// The app is going to the background. From this point it can be killed by
    /// the system or by the user without that being a crash.
    public func endForegroundSession() {
        try? FileManager.default.removeItem(at: PluginCrashGuard.sentinelURL)
    }

    /// The app came back to the foreground. A crash while it is visible leaves
    /// this sentinel behind for the next launch.
    public func beginForegroundSession() {
        self.lock.lock()
        let activity = self.currentActivity
        self.lock.unlock()
        self.writeSentinel(activity: activity)
    }

    /// Records what the manager is about to run. Kept in the sentinel so a crash
    /// during load names the plugin that was being evaluated.
    public func recordActivity(_ text: String) {
        let clean = text.replacingOccurrences(of: "\n", with: " ")
        self.lock.lock()
        self.currentActivity = clean
        self.lock.unlock()
        self.writeSentinel(activity: clean)
    }

    // MARK: - Crash log

    public func logText() -> String {
        guard let text = try? String(contentsOf: PluginCrashGuard.crashLogURL, encoding: .utf8) else {
            return "No crashes have been recorded."
        }
        return text
    }

    public func clearLog() {
        try? FileManager.default.removeItem(at: PluginCrashGuard.crashLogURL)
        UserDefaults.standard.removeObject(forKey: PluginCrashGuard.lastCrashKey)
    }

    /// Called from the uncaught-exception handler. Signal crashes (a Swift
    /// `fatalError`, a bad access in a native hook) do not pass through here, but
    /// they also leave the sentinel behind, so the next launch still logs them.
    fileprivate func recordException(_ exception: NSException) {
        let reason = exception.reason ?? "unknown"
        var details = [
            "Name: \(exception.name.rawValue)",
            "Reason: \(reason)",
        ]
        let symbols = exception.callStackSymbols
        if !symbols.isEmpty {
            details.append("Call stack:")
            details.append(contentsOf: symbols.prefix(40))
        }
        self.appendCrashLog(title: "Uncaught exception", details: details)
    }

    private func appendCrashLog(title: String, details: [String]) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let stamp = formatter.string(from: Date())

        var text = "=== \(stamp) ===\n\(title)\n"
        for detail in details {
            text += "\(detail)\n"
        }
        let tail = PluginLog.recentLines(limit: 200)
        if tail.isEmpty {
            text += "Plugin log: empty\n"
        } else {
            text += "Plugin log (last \(tail.count) lines):\n"
            text += tail.joined(separator: "\n")
            text += "\n"
        }
        text += "\n"

        let data = Data(text.utf8)
        let url = PluginCrashGuard.crashLogURL
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(data)
            if handle.offsetInFile > UInt64(PluginCrashGuard.crashLogLimit) {
                let keep = PluginCrashGuard.crashLogLimit / 2
                let start = handle.offsetInFile - UInt64(keep)
                handle.seek(toFileOffset: start)
                let retained = handle.readDataToEndOfFile()
                try? retained.write(to: url, options: .atomic)
            }
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: - Sentinel

    private func writeSentinel(activity: String) {
        let text = "started=\(Date().timeIntervalSince1970)\nactivity=\(activity)\n"
        try? Data(text.utf8).write(to: PluginCrashGuard.sentinelURL, options: .atomic)
    }

    private static func activity(from sentinel: String) -> String {
        for line in sentinel.split(separator: "\n") {
            if line.hasPrefix("activity=") {
                let value = String(line.dropFirst("activity=".count))
                return value.isEmpty ? "unknown" : value
            }
        }
        return "unknown"
    }

    private static func summary(from sentinel: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"

        var started: Date?
        for line in sentinel.split(separator: "\n") {
            if line.hasPrefix("started=") {
                let value = String(line.dropFirst("started=".count))
                if let seconds = Double(value) {
                    started = Date(timeIntervalSince1970: seconds)
                }
            }
        }
        let activity = self.activity(from: sentinel)
        if let started = started {
            return "\(formatter.string(from: started)) · \(activity)"
        }
        return activity
    }

    // MARK: - Exception handler

    private func installExceptionHandler() {
        NSSetUncaughtExceptionHandler { exception in
            PluginCrashGuard.shared.recordException(exception)
        }
    }
}