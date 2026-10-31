import Foundation
import SwiftSignalKit
import MtProtoKit

/// Proxy list operations for the plugin runtime.
///
/// Lives in TelegramCore, next to `ProxySettings`, for the same reason
/// `PluginMessage` does: `ExteraPluginKit` must not import Postbox or the MTProto
/// engine, and the proxy list is an account-level setting stored in Postbox.
///
/// Everything is a `Signal` rather than a synchronous call. The account manager
/// owns its own queue, so a plugin asking for the proxy list would otherwise
/// block whichever queue it happened to run on — including the main queue while a
/// settings screen is being built. The plugin's JavaScript is already
/// callback-shaped, so it waits for the answer instead.
public enum PluginProxyAccess {
    /// Reads the list the client currently has.
    public static func servers(accountManager: AccountManager<TelegramAccountManagerTypes>) -> Signal<[ProxyServerSettings], NoError> {
        return accountManager.sharedData(keys: [SharedDataKeys.proxySettings])
        |> take(1)
        |> map { sharedData -> [ProxyServerSettings] in
            return sharedData.entries[SharedDataKeys.proxySettings]?.get(ProxySettings.self)?.servers ?? []
        }
    }

    /// Adds every link that parses and is not already in the list.
    ///
    /// Duplicates are counted rather than skipped silently: a plugin that fetches
    /// a subscription list on every launch adds nothing after the first run, and
    /// its report would otherwise say "0 added" with no explanation.
    public static func add(accountManager: AccountManager<TelegramAccountManagerTypes>, links: [String]) -> Signal<(added: Int, duplicates: Int, invalid: Int), NoError> {
        return accountManager.transaction { transaction -> (added: Int, duplicates: Int, invalid: Int) in
            var added = 0
            var duplicates = 0
            var invalid = 0
            _ = updateProxySettingsInteractively(transaction: transaction, { settings in
                var settings = settings
                for link in links {
                    guard let server = PluginProxyAccess.parseLink(link) else {
                        invalid += 1
                        continue
                    }
                    if settings.servers.contains(server) {
                        duplicates += 1
                        continue
                    }
                    settings.servers.append(server)
                    added += 1
                }
                // Adding a server never switches to it: a plugin that ships a
                // subscription should not silently reroute the user's traffic.
                return settings
            })
            return (added, duplicates, invalid)
        }
    }

    /// Empties the list and turns proxying off, because a list with no active
    /// server cannot stay enabled.
    public static func removeAll(accountManager: AccountManager<TelegramAccountManagerTypes>) -> Signal<Int, NoError> {
        return accountManager.transaction { transaction -> Int in
            var removed = 0
            _ = updateProxySettingsInteractively(transaction: transaction, { settings in
                var settings = settings
                removed = settings.servers.count
                settings.servers = []
                settings.activeServer = nil
                settings.enabled = false
                return settings
            })
            return removed
        }
    }

    // MARK: - Links

    /// Parses the three proxy links Telegram accepts.
    ///
    /// `tg://webproxy` is delegated to TelegramCore's own parser so the base-path
    /// rules (a marked secret is mandatory when a path is present) are exactly the
    /// ones the rest of the app enforces. The other two are plain query links, and
    /// the MTProto secret is validated with `MTProxySecret` so a malformed one is
    /// rejected here rather than by the transport after a failed connection.
    public static func parseLink(_ value: String) -> ProxyServerSettings? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        if let web = parseWebProxySettingsLink(trimmed) {
            return web
        }
        guard let components = URLComponents(string: trimmed), components.scheme?.lowercased() == "tg" else {
            return nil
        }
        let parameters = queryDictionary(components.queryItems ?? [])
        guard let host = parameters["server"], !host.isEmpty, let port = parameters["port"].flatMap(Int32.init) else {
            return nil
        }
        switch components.host?.lowercased() {
        case "proxy":
            // MTProtoKit is the authority on what a secret is: 16 bytes of
            // padding, `dd` + 16, or `ee` + 16 + a domain. A secret it cannot
            // parse produces a server that is listed but can never connect, so
            // it is rejected here and counted as invalid instead — the plugin
            // reports that number rather than leaving a broken entry behind.
            guard let secretString = parameters["secret"],
                  let secret = hexData(secretString),
                  let parsed = MTProxySecret.parseData(secret) else {
                return nil
            }
            return ProxyServerSettings(host: host, port: port, connection: .mtp(secret: parsed.serialize() as Data))
        case "socks":
            return ProxyServerSettings(host: host, port: port, connection: .socks5(username: parameters["user"], password: parameters["pass"]))
        default:
            return nil
        }
    }

    /// The link that reproduces `server`.
    ///
    /// Used for export: the plugin writes a text file of links, and every link
    /// has to be one this same parser accepts again.
    public static func link(for server: ProxyServerSettings) -> String? {
        switch server.connection {
        case .web:
            return webProxySettingsLink(server)
        case let .mtp(secret):
            return "tg://proxy?server=\(server.host)&port=\(server.port)&secret=\(hexString(secret))"
        case let .socks5(username, password):
            var link = "tg://socks?server=\(server.host)&port=\(server.port)"
            if let username = username, !username.isEmpty {
                link += "&user=\(urlEncoded(username))"
            }
            if let password = password, !password.isEmpty {
                link += "&pass=\(urlEncoded(password))"
            }
            return link
        }
    }

    /// `FakeTLS` for a secret that carries the `ee` marker, `Padding` otherwise.
    ///
    /// The distinction is only cosmetic — both are MTProto secrets — but it is
    /// what the plugin's protocol filter and its export sections group by.
    public static func kind(for server: ProxyServerSettings) -> String {
        switch server.connection {
        case .web:
            return "web"
        case .mtp:
            return "mtproto"
        case .socks5:
            return "socks"
        }
    }

    private static func queryDictionary(_ items: [URLQueryItem]) -> [String: String] {
        var result: [String: String] = [:]
        for item in items {
            if let value = item.value {
                result[item.name.lowercased()] = value
            }
        }
        return result
    }

    private static func hexData(_ value: String) -> Data? {
        let text = value.hasPrefix("0x") ? String(value.dropFirst(2)) : value
        guard text.count % 2 == 0, !text.isEmpty else {
            return nil
        }
        var data = Data()
        data.reserveCapacity(text.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index ..< next], radix: 16) else {
                return nil
            }
            data.append(byte)
            index = next
        }
        return data
    }

    private static func hexString(_ data: Data) -> String {
        return data.map { String(format: "%02x", $0) }.joined()
    }

    private static func urlEncoded(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}