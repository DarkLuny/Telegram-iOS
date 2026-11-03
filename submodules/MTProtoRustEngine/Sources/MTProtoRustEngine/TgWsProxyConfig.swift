import Foundation
import MTProtoEngineFFI

/// The CloudFlare-fronted Telegram Web endpoint that `tg_ws_proxy.plugin` asks
/// the engine to use.
///
/// Telegram Web's front names a datacenter in the host — `kws1.web.telegram.org`
/// through `kws5.web.telegram.org` — and tg-ws-proxy's trick is to put a
/// CloudFlare zone in front of the same names, so a network that drops packets
/// to Telegram's own addresses still reaches the web front over WSS. The engine
/// already knows how to carry MTProto over that front (`mt_session_set_web_endpoint`,
/// the path its tests exercise); it only needed a way to be told which host to
/// use without a rebuild.
///
/// The plugin cannot call into Swift, so the hand-over is a small JSON document
/// in the app's Documents directory, which is inside the folder `file_utils`
/// lets a plugin write to:
///
///     {"enabled": true, "domain": "pclead.co.uk"}
///
/// The host for a datacenter is then `kws<dc>.<domain>`. An optional `"dc"`
/// object can pin a datacenter to a full host instead:
///
///     {"enabled": true, "domain": "pclead.co.uk", "dc": {"2": "kws2.offshore.example"}}
///
/// A missing, disabled or malformed document means "leave the engine alone", so
/// an uninstalled plugin or a mistyped domain falls back to Telegram's own web
/// hosts rather than breaking the account.
///
/// The document is polled while the app runs, so switching the plugin on takes
/// effect in the running client: every live session is given the new endpoint
/// and the engine is told to reset its connections, the same path a network
/// change takes. No restart is needed. What the client actually applied is
/// written back to `tg_ws_proxy_status.json`, so the plugin can show a
/// confirmation instead of assuming one.
enum TgWsProxyConfig {
    struct Settings: Equatable {
        let domain: String
        let datacenterOverrides: [Int: String]

        func host(datacenterId: Int) -> String {
            if let override = self.datacenterOverrides[datacenterId] {
                return override
            }
            return "kws\(datacenterId).\(self.domain)"
        }

        /// The value the change watcher compares between polls.
        var configurationKey: String {
            let overrides = self.datacenterOverrides.keys.sorted().map {
                "\($0)=\(self.datacenterOverrides[$0] ?? "")"
            }
            return "on:\(self.domain):\(overrides.joined(separator: ","))"
        }
    }

    /// The file `tg_ws_proxy.plugin` writes.
    static let fileName = "tg_ws_proxy.json"

    /// Where the client records the endpoint it last handed the engine, for the
    /// plugin to display.
    static let statusFileName = "tg_ws_proxy_status.json"

    /// Posted when the plugin's document changes while the app is running. Live
    /// sessions re-apply the endpoint and the engine's connections are reset.
    static let didChangeNotification = Notification.Name("TgWsProxyConfigDidChange")

    /// The settings the plugin last wrote, or nil when the transport is off.
    static func current() -> Settings? {
        guard let documents = self.documentsDirectory() else {
            return nil
        }
        let url = documents.appendingPathComponent(self.fileName)
        guard let data = try? Data(contentsOf: url),
              let parsed = try? JSONSerialization.jsonObject(with: data),
              let object = parsed as? [String: Any] else {
            return nil
        }
        guard (object["enabled"] as? Bool) == true else {
            return nil
        }
        guard let rawDomain = object["domain"] as? String, let domain = self.normalize(rawDomain) else {
            return nil
        }
        var overrides: [Int: String] = [:]
        if let entries = object["dc"] as? [String: Any] {
            for (key, value) in entries {
                guard let datacenterId = Int(key),
                      let raw = value as? String,
                      let host = self.normalize(raw) else {
                    continue
                }
                overrides[datacenterId] = host
            }
        }
        return Settings(domain: domain, datacenterOverrides: overrides)
    }

    /// The host to hand `mt_session_set_web_endpoint` for one datacenter, or nil
    /// when the plugin did not ask for a custom front.
    static func host(datacenterId: Int) -> String? {
        return self.current()?.host(datacenterId: datacenterId)
    }

    // MARK: - Live changes

    private static let watcherQueue = DispatchQueue(label: "org.telegram.MTProtoRust.tgwsproxy", qos: .utility)
    private static let watcherLock = NSLock()
    private static var watcherTimer: DispatchSourceTimer?
    private static var lastConfigurationKey: String?
    private static var engine: OpaquePointer?

    /// Starts polling the plugin's document, once per process. Called from the
    /// engine runtime, so the pointer is the one every session uses.
    static func startWatching(engine: OpaquePointer) {
        watcherLock.lock()
        defer {
            watcherLock.unlock()
        }
        guard self.watcherTimer == nil else {
            return
        }
        self.engine = engine
        let timer = DispatchSource.makeTimerSource(queue: self.watcherQueue)
        timer.schedule(deadline: .now() + 1.0, repeating: 1.5)
        timer.setEventHandler {
            self.pollConfiguration()
        }
        timer.resume()
        self.watcherTimer = timer
    }

    /// Only on `watcherQueue`. The first poll only records what is there, so
    /// launching the app does not reset connections for no reason.
    private static func pollConfiguration() {
        let key = self.current()?.configurationKey ?? "off"
        self.watcherLock.lock()
        let previous = self.lastConfigurationKey
        self.lastConfigurationKey = key
        let engine = self.engine
        self.watcherLock.unlock()
        guard let previous = previous, previous != key else {
            return
        }
        rustEngineImportantLog("[TGWSProxy] transport configuration changed: \(key)")
        NotificationCenter.default.post(name: self.didChangeNotification, object: nil)
        // Sessions apply on their own queues; the reset follows once they had a
        // moment, and is what makes the engine open new connections at once.
        self.watcherQueue.asyncAfter(deadline: .now() + 0.25) {
            guard let engine = engine else {
                return
            }
            mt_engine_reset_connections(engine)
        }
    }

    // MARK: - What the client applied

    private static let statusQueue = DispatchQueue(label: "org.telegram.MTProtoRust.tgwsproxy.status", qos: .utility)
    private static let statusLock = NSLock()
    private static var lastRecordedHost: String?
    private static var lastRecordedAt: TimeInterval = 0

    /// Records the endpoint a session just configured, for the plugin to show.
    /// `host` is empty when the client went back to Telegram's own web hosts.
    /// Throttled: many sessions start within a second of each other.
    static func recordApplied(host: String, datacenterId: Int) {
        let now = Date().timeIntervalSince1970
        self.statusLock.lock()
        if self.lastRecordedHost == host, now - self.lastRecordedAt < 60.0 {
            self.statusLock.unlock()
            return
        }
        self.lastRecordedHost = host
        self.lastRecordedAt = now
        self.statusLock.unlock()
        self.statusQueue.async {
            guard let documents = self.documentsDirectory() else {
                return
            }
            let url = documents.appendingPathComponent(self.statusFileName)
            // Never create a status file for a device that does not use the
            // plugin; only update or clear one that exists.
            if host.isEmpty && !FileManager.default.fileExists(atPath: url.path) {
                return
            }
            var object: [String: Any] = ["host": host, "at": Int(now)]
            if !host.isEmpty {
                object["dc"] = datacenterId
            }
            guard let data = try? JSONSerialization.data(withJSONObject: object) else {
                return
            }
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: - Helpers

    private static func documentsDirectory() -> URL? {
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }

    /// A hostname the plugin wrote, or nil when it is not one: lower case, no
    /// trailing dot, at least two labels, ASCII letters and digits only, and not
    /// a bare address. The same rules `WebProxyConfiguration.canonicalHost` uses,
    /// minus the path, because this value goes into a Host header and a TLS
    /// server name.
    static func normalize(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while value.hasSuffix(".") {
            value.removeLast()
        }
        guard !value.isEmpty, value.utf8.count <= 253,
              !value.contains("/"), !value.contains(":"), !value.contains("@"), !value.contains(" ") else {
            return nil
        }
        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else {
            return nil
        }
        for label in labels {
            guard !label.isEmpty, label.utf8.count <= 63,
                  label.first != "-", label.last != "-" else {
                return nil
            }
            guard label.allSatisfy({ character in
                character.isASCII && (character.isLetter || character.isNumber || character == "-")
            }) else {
                return nil
            }
        }
        guard let last = labels.last, !last.allSatisfy({ $0.isNumber }) else {
            return nil
        }
        return value
    }
}