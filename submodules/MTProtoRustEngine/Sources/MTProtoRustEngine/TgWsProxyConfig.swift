import Foundation

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
enum TgWsProxyConfig {
    struct Settings {
        let domain: String
        let datacenterOverrides: [Int: String]

        func host(datacenterId: Int) -> String {
            if let override = self.datacenterOverrides[datacenterId] {
                return override
            }
            return "kws\(datacenterId).\(self.domain)"
        }
    }

    /// The file `tg_ws_proxy.plugin` writes.
    static let fileName = "tg_ws_proxy.json"

    /// The settings the plugin last wrote, or nil when the transport is off.
    static func current() -> Settings? {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
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