import Foundation
import Darwin

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
/// The crash log is a retained report file next to `PluginLog`, not a copy of
/// the live log. Each entry is a short structured report: when the session died,
/// what kind of failure it was, the last plugin activity, an exception or call
/// stack when one exists, and only a few context lines from the plugin log. The
/// system's own crash report remains the place to look for a full stack trace.
///
/// Signal crashes are the common case on iOS (a Swift `fatalError`, a bad access
/// in a native hook, a trap in a C framework), and they never reach
/// `NSSetUncaughtExceptionHandler`. This file installs handlers for the fatal
/// POSIX signals and writes a small report with the signal name, the last
/// activity the runtime recorded, and a best-effort backtrace before re-raising
/// the signal so the system still produces its own crash report. It also mirrors
/// `stderr` into a file because a Swift trap prints its message there and that
/// message is often the actual reason (`Index out of range`, a force unwrap,
/// an assertion).
public final class PluginCrashGuard {
    public static let shared = PluginCrashGuard()

    /// The single global switch. A value here disables *every* plugin; there is
    /// no per-plugin safe mode, because the user cannot know which plugin is
    /// responsible until the client starts again.
    public static let safeModeKey = "extera.plugins.safe_mode"
    private static let lastCrashKey = "extera.plugins.last_crash"
    private static let sentinelFileName = "extera-plugin-session.txt"
    private static let crashLogFileName = "extera-plugin-crashes.log"
    private static let stderrLogFileName = "extera-plugin-stderr.log"
    private static let tgWsEventLogFileName = "extera-tgws-events.log"
    private static let crashLogLimit = 512 * 1024
    /// Bumped when the report format changes. Older entries pasted the live log
    /// tail, which made the crash screen look like the normal log; the first
    /// launch of this format drops those entries instead of showing them again.
    private static let crashLogFormatKey = "extera.plugins.crash_log_format"
    private static let currentCrashLogFormat = 3

    private let lock = NSLock()
    private let crashLogLock = NSLock()
    private var hasBegunSession = false
    private var currentActivity = "launch"
    private var signalHandlersInstalled = false

    /// C storage the signal handler can read without allocating. All three are
    /// filled in `beginSession`, before any handler is installed.
    private static var signalActivityBuffer: UnsafeMutablePointer<CChar>?
    private static var signalCrashLogPath: UnsafeMutablePointer<CChar>?
    private static var signalBacktraceBuffer: UnsafeMutablePointer<UnsafeMutableRawPointer?>?
    private static var isHandlingFatalSignal = false

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

    private static var stderrLogURL: URL {
        return self.libraryDirectory.appendingPathComponent(self.stderrLogFileName)
    }

    /// Written by `TgWsProxyService` in TelegramCore, which cannot import this
    /// module. The path is a convention between the two, just like `PluginLog`.
    private static var tgWsEventLogURL: URL {
        return self.libraryDirectory.appendingPathComponent(self.tgWsEventLogFileName)
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

        // The previous session's `stderr` is the only place a Swift trap leaves
        // its message. Read it before the redirect truncates it for this run.
        let previousRuntime = PluginCrashGuard.tailLines(of: PluginCrashGuard.stderrLogURL, maxBytes: 64 * 1024, lines: 30)

        self.prepareSignalBuffers()
        self.installExceptionHandler()
        self.installSignalHandlers()
        self.installStderrRedirect()
        self.migrateCrashLogIfNeeded()

        var crashed = false
        if let sentinel = try? String(contentsOf: PluginCrashGuard.sentinelURL, encoding: .utf8) {
            crashed = true
            var summary = PluginCrashGuard.summary(from: sentinel)
            // The last proxy event is often the most useful thing on the Safe
            // Mode row: it separates "the app died while the tunnel was coming
            // up" from "the app died while it was idle".
            let recentTgWs = PluginCrashGuard.tailLines(of: PluginCrashGuard.tgWsEventLogURL, maxBytes: 32 * 1024, lines: 1)
            if let lastEvent = recentTgWs.last, !lastEvent.isEmpty {
                summary += " · " + String(lastEvent.suffix(120))
            }
            self.isSafeModeEnabled = true
            UserDefaults.standard.set(summary, forKey: PluginCrashGuard.lastCrashKey)
            var details = [
                "Safe Mode was enabled automatically.",
                "Last activity: \(PluginCrashGuard.activity(from: sentinel))",
            ]
            if previousRuntime.isEmpty {
                details.append("No runtime output was captured. If there is also no fatal-signal report above, the system may have killed the process (for example, memory pressure) instead of the app raising a signal.")
            } else {
                details.append("Runtime output before the crash (last \(previousRuntime.count) lines):")
                details.append(contentsOf: previousRuntime)
            }
            self.appendCrashLog(
                title: "Previous session ended unexpectedly",
                details: details
            )
        }

        // A fresh sentinel for this session. It is removed when the app enters
        // the background, so a normal swipe-to-quit is not a crash.
        let activity = crashed ? "launch after crash" : "launch"
        self.lock.lock()
        self.currentActivity = activity
        PluginCrashGuard.copyActivityToSignalBuffer(activity)
        self.lock.unlock()
        self.writeSentinel(activity: activity)
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
        PluginCrashGuard.copyActivityToSignalBuffer(clean)
        self.lock.unlock()
        self.writeSentinel(activity: clean)
    }

    // MARK: - Crash log

    private func migrateCrashLogIfNeeded() {
        let stored = UserDefaults.standard.integer(forKey: PluginCrashGuard.crashLogFormatKey)
        guard stored < PluginCrashGuard.currentCrashLogFormat else {
            return
        }
        // Keep an entry that already carries a fatal-signal report. It may have
        // been written seconds ago, before UserDefaults flushed the format
        // marker; deleting it here would throw away exactly the cause this
        // build is meant to capture. Old entries without a signal are dropped.
        let existing = (try? String(contentsOf: PluginCrashGuard.crashLogURL, encoding: .utf8)) ?? ""
        if !existing.contains("Type: Fatal signal") {
            try? FileManager.default.removeItem(at: PluginCrashGuard.crashLogURL)
        }
        UserDefaults.standard.set(PluginCrashGuard.currentCrashLogFormat, forKey: PluginCrashGuard.crashLogFormatKey)
    }

    public func logText() -> String {
        guard let text = try? String(contentsOf: PluginCrashGuard.crashLogURL, encoding: .utf8) else {
            return ""
        }
        return text
    }

    public func clearLog() {
        self.crashLogLock.lock()
        try? FileManager.default.removeItem(at: PluginCrashGuard.crashLogURL)
        try? FileManager.default.removeItem(at: PluginCrashGuard.stderrLogURL)
        try? FileManager.default.removeItem(at: PluginCrashGuard.tgWsEventLogURL)
        self.crashLogLock.unlock()
        // `stderr` is still redirected to the inode that was just unlinked;
        // reopen it so the next crash still has runtime output to attach.
        self.installStderrRedirect()
        UserDefaults.standard.removeObject(forKey: PluginCrashGuard.lastCrashKey)
    }

    /// Called from the uncaught-exception handler. Signal crashes do not pass
    /// through here, but the signal handlers below cover them.
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

        var text = "================================================================\n"
        text += "CRASH REPORT\n"
        text += "When: \(stamp)\n"
        text += "Type: \(title)\n"
        for detail in details {
            text += "\(detail)\n"
        }
        // Only a short context excerpt. The live log is a separate screen; a
        // crash report that pasted 200 log lines looked identical to it.
        let tail = PluginLog.recentLines(limit: 10)
        if tail.isEmpty {
            text += "Context: no plugin log lines were recorded.\n"
        } else {
            text += "Context (last \(tail.count) plugin log lines, not the live log):\n"
            text += tail.joined(separator: "\n")
            text += "\n"
        }
        // The TG WS engine writes its own small event log because it lives in
        // TelegramCore and cannot call into this module. Its last lines are the
        // proxy's side of the story when the crash happened after the client
        // started using the local proxy.
        let tgWsTail = PluginCrashGuard.tailLines(of: PluginCrashGuard.tgWsEventLogURL, maxBytes: 32 * 1024, lines: 20)
        if !tgWsTail.isEmpty {
            text += "TG WS events (last \(tgWsTail.count) lines):\n"
            text += tgWsTail.joined(separator: "\n")
            text += "\n"
        }
        text += "================================================================\n\n"

        let data = Data(text.utf8)
        let url = PluginCrashGuard.crashLogURL
        self.crashLogLock.lock()
        defer {
            self.crashLogLock.unlock()
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            try? handle.write(contentsOf: data)
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

    // MARK: - Exception and signal handlers

    private func installExceptionHandler() {
        NSSetUncaughtExceptionHandler { exception in
            PluginCrashGuard.shared.recordException(exception)
        }
    }

    private func installSignalHandlers() {
        guard !self.signalHandlersInstalled else {
            return
        }
        self.signalHandlersInstalled = true
        // A broken pipe on a client socket is a normal disconnect, not a crash.
        _ = Darwin.signal(SIGPIPE, SIG_IGN)
        for number in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP] {
            _ = Darwin.signal(number, pluginCrashSignalHandler)
        }
    }

    /// Captures the text a Swift trap prints before it raises `SIGTRAP`/`SIGILL`.
    /// The file is truncated each launch; the previous run's copy is read in
    /// `beginSession` and attached to the report when the sentinel is present.
    private func installStderrRedirect() {
        let path = PluginCrashGuard.stderrLogURL.path
        path.withCString { cPath in
            _ = freopen(cPath, "w", stderr)
        }
    }

    private func prepareSignalBuffers() {
        if PluginCrashGuard.signalActivityBuffer == nil {
            let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: 512)
            buffer.initialize(repeating: 0, count: 512)
            PluginCrashGuard.signalActivityBuffer = buffer
        }
        if PluginCrashGuard.signalCrashLogPath == nil {
            PluginCrashGuard.signalCrashLogPath = strdup(PluginCrashGuard.crashLogURL.path)
        }
        if PluginCrashGuard.signalBacktraceBuffer == nil {
            let buffer = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: 64)
            buffer.initialize(repeating: nil, count: 64)
            PluginCrashGuard.signalBacktraceBuffer = buffer
        }
    }

    private static func copyActivityToSignalBuffer(_ text: String) {
        guard let buffer = self.signalActivityBuffer else {
            return
        }
        text.withCString { source in
            _ = strlcpy(buffer, source, 512)
        }
    }

    fileprivate func handleFatalSignal(_ signalNumber: Int32) {
        if PluginCrashGuard.isHandlingFatalSignal {
            _exit(128 + signalNumber)
        }
        PluginCrashGuard.isHandlingFatalSignal = true

        if let path = PluginCrashGuard.signalCrashLogPath {
            let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
            if fd >= 0 {
                PluginCrashGuard.writeLiteral("\n================================================================\n", to: fd)
                PluginCrashGuard.writeLiteral("CRASH REPORT\n", to: fd)
                PluginCrashGuard.writeLiteral("Type: Fatal signal ", to: fd)
                PluginCrashGuard.writeSignalName(signalNumber, to: fd)
                PluginCrashGuard.writeLiteral("\n", to: fd)
                PluginCrashGuard.writeLiteral("Last activity: ", to: fd)
                if let activity = PluginCrashGuard.signalActivityBuffer {
                    _ = write(fd, UnsafeRawPointer(activity), strlen(activity))
                } else {
                    PluginCrashGuard.writeLiteral("unknown", to: fd)
                }
                PluginCrashGuard.writeLiteral("\nCall stack (best effort):\n", to: fd)
                if let frames = PluginCrashGuard.signalBacktraceBuffer {
                    let count = backtrace(frames, 64)
                    if count > 0 {
                        backtrace_symbols_fd(frames, count, fd)
                    }
                }
                PluginCrashGuard.writeLiteral("================================================================\n\n", to: fd)
                _ = close(fd)
            }
        }

        // Put the default handler back and deliver the same signal again, so the
        // system still writes its own crash log and the app is not left hanging.
        _ = Darwin.signal(signalNumber, SIG_DFL)
        _ = raise(signalNumber)
        _exit(128 + signalNumber)
    }

    private static func writeLiteral(_ text: StaticString, to fd: Int32) {
        guard text.utf8CodeUnitCount > 0 else {
            return
        }
        _ = write(fd, UnsafeRawPointer(text.utf8Start), text.utf8CodeUnitCount)
    }

    private static func writeSignalName(_ number: Int32, to fd: Int32) {
        switch number {
        case SIGABRT:
            self.writeLiteral("SIGABRT (abort)", to: fd)
        case SIGSEGV:
            self.writeLiteral("SIGSEGV (bad access)", to: fd)
        case SIGBUS:
            self.writeLiteral("SIGBUS (bus error)", to: fd)
        case SIGILL:
            self.writeLiteral("SIGILL (illegal instruction)", to: fd)
        case SIGFPE:
            self.writeLiteral("SIGFPE (arithmetic exception)", to: fd)
        case SIGTRAP:
            self.writeLiteral("SIGTRAP (Swift trap or fatalError)", to: fd)
        default:
            self.writeLiteral("unknown signal", to: fd)
        }
    }

    // MARK: - File tails

    private static func tailLines(of url: URL, maxBytes: Int, lines: Int) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return []
        }
        defer { try? handle.close() }
        let size = handle.seekToEndOfFile()
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        handle.seek(toFileOffset: start)
        let data = handle.readDataToEndOfFile()
        guard !data.isEmpty else {
            return []
        }
        let text = String(decoding: data, as: UTF8.self)
        let all = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        return Array(all.suffix(lines))
    }
}

/// A C-compatible entry point: `signal` cannot call a closure, and the handler
/// must not allocate a context object.
private func pluginCrashSignalHandler(_ signalNumber: Int32) {
    PluginCrashGuard.shared.handleFatalSignal(signalNumber)
}