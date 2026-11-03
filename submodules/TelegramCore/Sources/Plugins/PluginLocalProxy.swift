import Foundation
import CommonCrypto
import Network
import Security
import SwiftSignalKit
import Postbox

/// A local MTProto proxy a plugin can switch on, and the proxy entry that makes
/// the client use it.
///
/// This is the capability `tg_ws_proxy.plugin` needed and could not build in
/// JavaScript: a plugin has no sockets, so a local proxy has to live in Swift.
/// It is deliberately generic rather than shaped around that one plugin — any
/// plugin that can name a CloudFlare zone can start it with
/// `__extera.localProxy({action: "start", domain: …})`, and nothing about it
/// needs the client to change again.
///
/// What it does, and why it is the same thing the reference app does:
///
///   - it listens on `127.0.0.1` and speaks the MTProxy obfuscated2 protocol
///     (the `dd` secret, abridged/intermediate/padded framing);
///   - for each client connection it derives the datacenter from the encrypted
///     header and dials Telegram Web's front — `kws<dc>.<zone>`, then Telegram's
///     own `kws<dc>.web.telegram.org`, then the datacenter address — carrying the
///     same obfuscated stream inside WebSocket frames;
///   - it adds `127.0.0.1:<port>` with the secret to the proxy list and makes it
///     the active proxy, which is why an MTProto proxy entry appears in
///     Telegram's own list;
///   - switching it off removes that entry and, if it was active, puts the
///     client back on direct connections.
///
/// A network that drops packets to Telegram's addresses reaches the same
/// datacenters through the zone; a network that does not still works, because
/// the proxy's upstream is a normal Telegram Web socket.
public final class PluginLocalProxy {
    public static let shared = PluginLocalProxy()

    public struct Status {
        public var running: Bool
        public var host: String
        public var port: Int
        /// The `dd`-marked secret the client is given, or empty before one was made.
        public var secret: Data
        public var domain: String
        /// Whether the entry is the client's active proxy right now.
        public var active: Bool
        public var error: String?
        /// Client connections the listener has open, and how many of them have
        /// an upstream socket that finished its WebSocket upgrade. A pair of
        /// non-zero numbers is the proof that traffic is actually moving;
        /// "running" alone only says the entry is in the list.
        public var connections: Int = 0
        public var upstreams: Int = 0
        /// Why the last upstream attempt gave up, if it did.
        public var upstreamError: String?

        public var link: String? {
            guard self.running, self.port > 0, self.secret.count > 0 else {
                return nil
            }
            return "tg://proxy?server=\(self.host)&port=\(self.port)&secret=\(self.secret.map { String(format: "%02x", $0) }.joined())"
        }

        public var json: [String: Any] {
            var result: [String: Any] = [
                "running": self.running,
                "host": self.host,
                "port": self.port,
                "domain": self.domain,
                "active": self.active,
                "connections": self.connections,
                "upstreams": self.upstreams,
            ]
            if let link = self.link {
                result["link"] = link
            }
            if let error = self.error {
                result["error"] = error
            }
            if let upstreamError = self.upstreamError {
                result["upstream_error"] = upstreamError
            }
            return result
        }
    }

    /// The port the reference app uses, and the one the proxy entry keeps.
    public static let preferredPort: UInt16 = 1443

    private static let secretDefaultsKey = "org.telegram.tgwsproxy.secret"

    private let operationQueue = DispatchQueue(label: "org.telegram.MTProtoRust.tgwsproxy.controller")
    private let stateLock = NSLock()
    private var statusValue = Status(running: false, host: "127.0.0.1", port: 0, secret: Data(), domain: "", active: false, error: nil)
    private var server: LocalMTProxyServer?

    private init() {
    }

    public func currentStatus() -> Status {
        self.stateLock.lock()
        defer {
            self.stateLock.unlock()
        }
        return self.statusValue
    }

    private func setStatus(_ status: Status) {
        self.stateLock.lock()
        self.statusValue = status
        self.stateLock.unlock()
    }

    /// Live traffic counters, pushed by the listener. Kept separate from
    /// `setStatus` because they change far more often than the proxy's shape.
    private func setActivity(connections: Int, upstreams: Int, error: String?) {
        self.stateLock.lock()
        self.statusValue.connections = connections
        self.statusValue.upstreams = upstreams
        if let error = error, !error.isEmpty {
            self.statusValue.upstreamError = error
        }
        self.stateLock.unlock()
    }

    // MARK: - Starting and stopping

    /// Starts the listener and makes its entry the client's proxy.
    ///
    /// `completion` runs once the entry is in place (or once the reason it could
    /// not be is known) and always on a background queue.
    public func start(domain rawDomain: String, accountManager: AccountManager<TelegramAccountManagerTypes>, completion: @escaping (Status) -> Void) {
        let domain = PluginLocalProxy.normalizeDomain(rawDomain)
        self.operationQueue.async {
            guard !domain.isEmpty else {
                var status = self.currentStatus()
                status.running = false
                status.error = "not a host name: \(rawDomain)"
                self.setStatus(status)
                completion(status)
                return
            }
            let secret = self.storedSecret()
            // A running server for the same zone only needs its entry restored:
            // this happens when the app reconnects and the plugin loads again.
            if let server = self.server, server.domain == domain, server.port > 0 {
                self.activate(accountManager: accountManager, secret: secret, port: server.port, domain: domain, completion: completion)
                return
            }
            self.server?.stop()
            self.server = nil

            var status = self.currentStatus()
            status.running = false
            status.host = "127.0.0.1"
            status.port = 0
            status.secret = secret
            status.domain = domain
            status.active = false
            status.error = nil
            status.connections = 0
            status.upstreams = 0
            status.upstreamError = nil
            self.setStatus(status)

            let server = LocalMTProxyServer(secret: secret, domain: domain)
            server.onActivity = { [weak self] connections, upstreams, error in
                self?.setActivity(connections: connections, upstreams: upstreams, error: error)
            }
            server.onReady = { [weak self, weak server] port in
                guard let self = self else {
                    return
                }
                // The server calls back on its own queue; the controller's state
                // lives on `operationQueue`, so it is only touched from there.
                self.operationQueue.async {
                    guard let server = server, self.server === server else {
                        return
                    }
                    self.activate(accountManager: accountManager, secret: secret, port: port, domain: domain, completion: completion)
                }
            }
            server.onFailure = { [weak self, weak server] message in
                guard let self = self else {
                    return
                }
                self.operationQueue.async {
                    guard let server = server, self.server === server else {
                        return
                    }
                    self.server = nil
                    var status = self.currentStatus()
                    status.running = false
                    status.port = 0
                    status.active = false
                    status.error = message
                    self.setStatus(status)
                    completion(status)
                }
            }
            self.server = server
            server.start(preferredPort: PluginLocalProxy.preferredPort)
        }
    }

    /// Stops the listener and takes its entry out of the proxy list.
    public func stop(accountManager: AccountManager<TelegramAccountManagerTypes>, completion: @escaping (Status) -> Void) {
        self.operationQueue.async {
            self.server?.stop()
            self.server = nil
            let secret = self.currentStatus().secret
            var status = self.currentStatus()
            status.running = false
            status.port = 0
            status.active = false
            status.error = nil
            status.connections = 0
            status.upstreams = 0
            self.setStatus(status)
            guard secret.count == 17 else {
                completion(status)
                return
            }
            _ = PluginProxyAccess.deactivateLocal(accountManager: accountManager, host: "127.0.0.1", secrets: [secret]).start(next: { _ in
                completion(self.currentStatus())
            })
        }
    }

    private func activate(accountManager: AccountManager<TelegramAccountManagerTypes>, secret: Data, port: UInt16, domain: String, completion: @escaping (Status) -> Void) {
        let server = ProxyServerSettings(host: "127.0.0.1", port: Int32(port), connection: .mtp(secret: secret))
        // The listener is already up at this point, so the status says so before
        // the list transaction runs; `active` follows it.
        var status = self.currentStatus()
        status.running = true
        status.host = "127.0.0.1"
        status.port = Int(port)
        status.secret = secret
        status.domain = domain
        status.active = false
        status.error = nil
        self.setStatus(status)

        // The transaction sets `activeServer` either way; its Bool only says
        // whether the settings changed, and an entry that was already active is
        // a success too. Reporting that as a failure is what would have shown
        // "added, but not active" every time the proxy was started twice.
        _ = PluginProxyAccess.activate(accountManager: accountManager, server: server).start(next: { _ in
            var activated = self.currentStatus()
            activated.active = true
            self.setStatus(activated)
            completion(activated)
        })
    }

    // MARK: - Secret

    /// The secret survives launches so the entry the client already stores keeps
    /// working; the marker is `dd`, which is what a padded-intermediate MTProxy
    /// secret looks like and what the reference app puts in its link.
    private func storedSecret() -> Data {
        if let stored = UserDefaults.standard.data(forKey: PluginLocalProxy.secretDefaultsKey), stored.count == 17, stored.first == 0xdd {
            return stored
        }
        let secret = Data([0xdd]) + LocalMTProxyCrypto.randomBytes(16)
        UserDefaults.standard.set(secret, forKey: PluginLocalProxy.secretDefaultsKey)
        return secret
    }

    // MARK: - Host names

    /// The rule the engine and `tg_ws_proxy.plugin` share: lower case, two or
    /// more ASCII labels, not a bare address.
    public static func normalizeDomain(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while value.hasSuffix(".") {
            value.removeLast()
        }
        guard !value.isEmpty, value.utf8.count <= 253,
              !value.contains("/"), !value.contains(":"), !value.contains("@"), !value.contains(" ") else {
            return ""
        }
        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else {
            return ""
        }
        for label in labels {
            guard !label.isEmpty, label.utf8.count <= 63,
                  label.first != "-", label.last != "-",
                  label.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else {
                return ""
            }
        }
        guard let last = labels.last, !last.allSatisfy({ $0.isNumber }) else {
            return ""
        }
        return value
    }
}

// MARK: - Cryptography

private enum LocalMTProxyCrypto {
    static func sha256(_ parts: [Data]) -> Data {
        var context = CC_SHA256_CTX()
        CC_SHA256_Init(&context)
        for part in parts {
            part.withUnsafeBytes { bytes in
                if let base = bytes.baseAddress {
                    CC_SHA256_Update(&context, base, CC_LONG(bytes.count))
                }
            }
        }
        var digest = Data(count: Int(CC_SHA256_DIGEST_LENGTH))
        digest.withUnsafeMutableBytes { bytes in
            CC_SHA256_Final(bytes.baseAddress!.assumingMemoryBound(to: UInt8.self), &context)
        }
        return digest
    }

    static func sha1(_ data: Data) -> Data {
        var digest = Data(count: Int(CC_SHA1_DIGEST_LENGTH))
        digest.withUnsafeMutableBytes { bytes in
            data.withUnsafeBytes { input in
                CC_SHA1(input.baseAddress, CC_LONG(input.count), bytes.baseAddress!.assumingMemoryBound(to: UInt8.self))
            }
        }
        return digest
    }

    static func randomBytes(_ count: Int) -> Data {
        var data = Data(count: count)
        _ = data.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, count, bytes.baseAddress!)
        }
        return data
    }
}

/// AES-256 in CTR mode with the big-endian counter MTProto uses. CommonCrypto
/// keeps the counter across `process` calls, so one instance is one direction of
/// an obfuscated stream for its whole life.
private final class LocalMTProxyAesCtr {
    private var cryptor: CCCryptorRef?

    init?(key: Data, iv: Data) {
        guard key.count == 32, iv.count == 16 else {
            return nil
        }
        var reference: CCCryptorRef?
        let status = key.withUnsafeBytes { keyBytes -> CCCryptorStatus in
            iv.withUnsafeBytes { ivBytes -> CCCryptorStatus in
                CCCryptorCreateWithMode(
                    CCOperation(kCCEncrypt),
                    CCMode(kCCModeCTR),
                    CCAlgorithm(kCCAlgorithmAES),
                    CCPadding(ccNoPadding),
                    ivBytes.baseAddress,
                    keyBytes.baseAddress,
                    key.count,
                    nil,
                    0,
                    0,
                    CCModeOptions(2), // kCCModeOptionCTR_BE
                    &reference
                )
            }
        }
        guard status == kCCSuccess, let cryptor = reference else {
            return nil
        }
        self.cryptor = cryptor
    }

    deinit {
        if let cryptor = self.cryptor {
            CCCryptorRelease(cryptor)
        }
    }

    /// Encrypts or decrypts (the same operation in CTR). Always returns as many
    /// bytes as it was given.
    func process(_ input: Data) -> Data {
        guard let cryptor = self.cryptor, !input.isEmpty else {
            return Data()
        }
        var output = Data(count: input.count)
        var moved = 0
        let status = input.withUnsafeBytes { inputBytes -> CCCryptorStatus in
            output.withUnsafeMutableBytes { outputBytes -> CCCryptorStatus in
                CCCryptorUpdate(cryptor, inputBytes.baseAddress, input.count, outputBytes.baseAddress, output.count, &moved)
            }
        }
        guard status == kCCSuccess, moved == input.count else {
            return Data()
        }
        return output
    }
}

// MARK: - The obfuscated header

private struct LocalMTProxyClientKeys {
    /// Client → proxy, already advanced past the 64-byte header.
    let decryptor: LocalMTProxyAesCtr
    /// Proxy → client, fresh.
    let encryptor: LocalMTProxyAesCtr
    let tag: UInt32
    let datacenterId: Int16
}

private enum LocalMTProxyObfuscation {
    static let tagAbridged: UInt32 = 0xefefefef
    static let tagIntermediate: UInt32 = 0xeeeeeeee
    static let tagPaddedIntermediate: UInt32 = 0xdddddddd

    /// Reads the client's header. The first 56 bytes travel in the clear; the
    /// last 8 are encrypted and carry the framing tag and the datacenter.
    static func accept(header: Data, secret: Data) -> LocalMTProxyClientKeys? {
        guard header.count == 64, secret.count == 16 else {
            return nil
        }
        let bytes = [UInt8](header)
        let reversed = Data(bytes.reversed())
        guard let decryptor = LocalMTProxyAesCtr(
            key: LocalMTProxyCrypto.sha256([Data(bytes[8 ..< 40]), secret]),
            iv: Data(bytes[40 ..< 56])
        ) else {
            return nil
        }
        let plain = decryptor.process(header)
        guard plain.count == 64 else {
            return nil
        }
        let plainBytes = [UInt8](plain)
        let tag = UInt32(plainBytes[56])
            | (UInt32(plainBytes[57]) << 8)
            | (UInt32(plainBytes[58]) << 16)
            | (UInt32(plainBytes[59]) << 24)
        guard tag == tagAbridged || tag == tagIntermediate || tag == tagPaddedIntermediate else {
            return nil
        }
        let datacenterId = Int16(bitPattern: UInt16(plainBytes[60]) | (UInt16(plainBytes[61]) << 8))
        guard let encryptor = LocalMTProxyAesCtr(
            key: LocalMTProxyCrypto.sha256([Data(reversed[8 ..< 40]), secret]),
            iv: Data(reversed[40 ..< 56])
        ) else {
            return nil
        }
        return LocalMTProxyClientKeys(decryptor: decryptor, encryptor: encryptor, tag: tag, datacenterId: datacenterId)
    }

    /// Builds the proxy's own header toward the datacenter, and the streams that
    /// go with it. This mirrors `obfuscated_init` in the engine: the header's
    /// last 8 bytes are written as ciphertext so a server can learn the framing
    /// and the datacenter without decrypting the random prefix.
    static func makeRelay(tag: UInt32, datacenterId: Int16) -> (header: Data, encryptor: LocalMTProxyAesCtr, parser: LocalMTProxyAesCtr, decryptor: LocalMTProxyAesCtr)? {
        var header = [UInt8](repeating: 0, count: 64)
        var attempts = 0
        repeat {
            header = [UInt8](LocalMTProxyCrypto.randomBytes(64))
            attempts += 1
        } while attempts < 8 && !isPlausible(header)
        header[56] = UInt8(tag & 0xff)
        header[57] = UInt8((tag >> 8) & 0xff)
        header[58] = UInt8((tag >> 16) & 0xff)
        header[59] = UInt8((tag >> 24) & 0xff)
        header[60] = UInt8(UInt16(bitPattern: datacenterId) & 0xff)
        header[61] = UInt8((UInt16(bitPattern: datacenterId) >> 8) & 0xff)

        let reversed = Data(header.reversed())
        let key = Data(header[8 ..< 40])
        let iv = Data(header[40 ..< 56])
        guard let encryptor = LocalMTProxyAesCtr(key: key, iv: iv),
              let parser = LocalMTProxyAesCtr(key: key, iv: iv),
              let decryptor = LocalMTProxyAesCtr(key: Data(reversed[8 ..< 40]), iv: Data(reversed[40 ..< 56])) else {
            return nil
        }
        let keystream = encryptor.process(Data(count: 64))
        _ = parser.process(Data(count: 64))
        guard keystream.count == 64 else {
            return nil
        }
        for index in 56 ..< 64 {
            header[index] ^= keystream[index]
        }
        return (Data(header), encryptor, parser, decryptor)
    }

    private static func isPlausible(_ header: [UInt8]) -> Bool {
        if header[0] == 0xef {
            return false
        }
        let first = UInt32(header[0]) | (UInt32(header[1]) << 8) | (UInt32(header[2]) << 16) | (UInt32(header[3]) << 24)
        let forbidden: [UInt32] = [0x44414548, 0x54534f50, 0x20544547, 0x4954504f, tagPaddedIntermediate, tagIntermediate, 0x02010316]
        if forbidden.contains(first) {
            return false
        }
        return header[4] != 0 || header[5] != 0 || header[6] != 0 || header[7] != 0
    }
}

// MARK: - The listener

private final class LocalMTProxyServer {
    let secret: Data
    let domain: String
    var onReady: ((UInt16) -> Void)?
    var onFailure: ((String) -> Void)?
    /// Client and live-upstream counts, and the last upstream failure.
    var onActivity: ((Int, Int, String?) -> Void)?

    private let queue = DispatchQueue(label: "org.telegram.MTProtoRust.tgwsproxy.server")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: LocalMTProxyConnection] = [:]
    private(set) var port: UInt16 = 0
    private var didBecomeReady = false
    private var isStopped = false
    private var clientCount = 0
    private var readyUpstreamCount = 0
    private var lastUpstreamError: String?

    private func publishActivity() {
        self.onActivity?(self.clientCount, self.readyUpstreamCount, self.lastUpstreamError)
    }

    private static let datacenterAddresses: [Int: String] = [
        1: "149.154.175.50",
        2: "149.154.167.51",
        3: "149.154.175.100",
        4: "149.154.167.91",
        5: "149.154.171.5",
        203: "91.105.192.100",
    ]

    init(secret: Data, domain: String) {
        self.secret = secret
        self.domain = domain
    }

    func start(preferredPort: UInt16) {
        self.queue.async {
            self.startLocked(port: preferredPort, allowFallback: preferredPort != 0)
        }
    }

    private func startLocked(port: UInt16, allowFallback: Bool) {
        guard !self.isStopped else {
            return
        }
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.includePeerToPeer = false
            guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
                self.onFailure?("invalid port \(port)")
                return
            }
            let listener = try NWListener(using: parameters, on: endpointPort)
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self = self, let listener = listener, self.listener === listener else {
                    return
                }
                switch state {
                case .ready:
                    self.didBecomeReady = true
                    self.port = listener.port?.rawValue ?? port
                    self.onReady?(self.port)
                case let .failed(error):
                    self.listener = nil
                    if allowFallback {
                        self.startLocked(port: 0, allowFallback: false)
                    } else {
                        self.onFailure?(error.localizedDescription)
                    }
                default:
                    break
                }
            }
            self.listener = listener
            listener.start(queue: self.queue)
        } catch {
            if allowFallback {
                self.startLocked(port: 0, allowFallback: false)
            } else {
                self.onFailure?(error.localizedDescription)
            }
        }
    }

    func stop() {
        self.queue.sync {
            self.isStopped = true
            self.listener?.cancel()
            self.listener = nil
            for connection in self.connections.values {
                connection.stop()
            }
            self.connections.removeAll()
            self.clientCount = 0
            self.readyUpstreamCount = 0
            self.onActivity = nil
        }
    }

    private func accept(_ connection: NWConnection) {
        guard !self.isStopped else {
            connection.cancel()
            return
        }
        // The listener is not bound to loopback (Network.framework has no such
        // switch for listeners), so anything that is not this device is refused.
        guard LocalMTProxyServer.isLoopback(connection.endpoint) else {
            connection.cancel()
            return
        }
        let identifier = ObjectIdentifier(connection)
        let client = LocalMTProxyConnection(
            connection: connection,
            secret: self.secret.dropFirstData(),
            domain: self.domain,
            datacenterAddress: { datacenter in
                return LocalMTProxyServer.datacenterAddresses[datacenter] ?? ""
            },
            onClose: { [weak self] in
                // The connection runs on its own queue; the map belongs to the
                // server's, so removal goes back through it.
                guard let self = self else {
                    return
                }
                self.queue.async {
                    self.connections.removeValue(forKey: identifier)
                    self.clientCount = max(0, self.clientCount - 1)
                    self.publishActivity()
                }
            },
            onUpstreamState: { [weak self] ready in
                guard let self = self else {
                    return
                }
                self.queue.async {
                    self.readyUpstreamCount = max(0, self.readyUpstreamCount + (ready ? 1 : -1))
                    self.publishActivity()
                }
            },
            onUpstreamError: { [weak self] message in
                guard let self = self else {
                    return
                }
                self.queue.async {
                    self.lastUpstreamError = message
                    self.publishActivity()
                }
            }
        )
        self.connections[identifier] = client
        self.clientCount += 1
        self.publishActivity()
        client.start()
    }

    private static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint else {
            return false
        }
        switch host {
        case let .ipv4(address):
            return address == IPv4Address("127.0.0.1")
        case let .ipv6(address):
            return address == IPv6Address("::1")
        case .name:
            // `localhost` resolves before the connection is made; a name here is
            // an interface-scoped peer, which is not this device.
            return false
        @unknown default:
            return false
        }
    }
}

private extension Data {
    /// The 16-byte key behind a `dd`-marked secret.
    func dropFirstData() -> Data {
        if self.count == 17, self.first == 0xdd {
            return self.subdata(in: 1 ..< 17)
        }
        return self
    }
}

// MARK: - One client connection

private final class LocalMTProxyConnection {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let secret: Data
    private let domain: String
    private let datacenterAddress: (Int) -> String
    private let onClose: () -> Void
    private let onUpstreamState: (Bool) -> Void
    private let onUpstreamError: (String) -> Void

    private var headerBuffer = Data()
    private var keys: LocalMTProxyClientKeys?
    private var upstream: LocalMTProxyUpstream?
    private var upstreamReady = false

    /// Client ciphertext that has not reached the upstream yet, and the same
    /// bytes as plaintext, for finding packet boundaries.
    private var packetBuffer = Data()
    private var framingBuffer = Data()
    private var splittingDisabled = false
    private var isClosed = false

    private static let maximumBufferedBytes = 8 * 1024 * 1024

    /// The reference's `dcOverrides`: DC 203 has no web front, and the front that
    /// serves it is the one named after DC 2.
    private static func webDatacenter(_ datacenter: Int) -> Int {
        if datacenter == 203 {
            return 2
        }
        return datacenter
    }

    init(connection: NWConnection, secret: Data, domain: String, datacenterAddress: @escaping (Int) -> String, onClose: @escaping () -> Void, onUpstreamState: @escaping (Bool) -> Void, onUpstreamError: @escaping (String) -> Void) {
        self.connection = connection
        self.secret = secret
        self.domain = domain
        self.datacenterAddress = datacenterAddress
        self.onClose = onClose
        self.onUpstreamState = onUpstreamState
        self.onUpstreamError = onUpstreamError
        self.queue = DispatchQueue(label: "org.telegram.MTProtoRust.tgwsproxy.client")
    }

    func start() {
        self.connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.receiveLoop()
            case .failed, .cancelled:
                self?.close()
            default:
                break
            }
        }
        self.connection.start(queue: self.queue)
    }

    func stop() {
        self.queue.async {
            self.close()
        }
    }

    private func close() {
        guard !self.isClosed else {
            return
        }
        self.isClosed = true
        self.setUpstreamReady(false)
        self.upstream?.stop()
        self.upstream = nil
        self.connection.cancel()
        self.onClose()
    }

    private func setUpstreamReady(_ ready: Bool) {
        if self.upstreamReady == ready {
            return
        }
        self.upstreamReady = ready
        self.onUpstreamState?(ready)
    }

    private func receiveLoop() {
        self.connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self = self, !self.isClosed else {
                return
            }
            if let data = data, !data.isEmpty {
                if self.keys == nil {
                    self.headerBuffer.append(data)
                    if self.headerBuffer.count >= 64 {
                        let header = Data(self.headerBuffer.prefix(64))
                        let rest = self.headerBuffer.count > 64 ? Data(self.headerBuffer.suffix(from: 64)) : Data()
                        self.headerBuffer = Data()
                        self.acceptHeader(header, rest: rest)
                    }
                } else {
                    self.handleClientData(data)
                }
            }
            if let error = error {
                self.close()
                return
            }
            if isComplete {
                self.close()
                return
            }
            if self.keys == nil && self.headerBuffer.count >= 64 {
                // `acceptHeader` closed the connection; nothing more to read.
                return
            }
            self.receiveLoop()
        }
    }

    private func acceptHeader(_ header: Data, rest: Data) {
        // An HTTP request here is a scanner or a browser; the reference core
        // answers 404 and hangs up, and so does this.
        if LocalMTProxyConnection.looksLikeHTTP(header) {
            self.writeClient(Data("HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n".utf8))
            self.close()
            return
        }
        guard let keys = LocalMTProxyObfuscation.accept(header: header, secret: self.secret) else {
            self.close()
            return
        }
        self.keys = keys
        self.openUpstream(datacenterId: keys.datacenterId, tag: keys.tag)
        if !rest.isEmpty {
            self.handleClientData(rest)
        }
    }

    private static func looksLikeHTTP(_ header: Data) -> Bool {
        guard header.count >= 4 else {
            return false
        }
        let prefix = String(decoding: header.prefix(4), as: UTF8.self)
        return prefix == "GET " || prefix.hasPrefix("POST") || prefix.hasPrefix("HEAD") || prefix.hasPrefix("OPTI")
    }

    private func openUpstream(datacenterId: Int16, tag: UInt32) {
        guard let relay = LocalMTProxyObfuscation.makeRelay(tag: tag, datacenterId: datacenterId) else {
            self.close()
            return
        }
        let datacenter = abs(Int(datacenterId))
        let isMedia = datacenterId < 0
        var targets: [LocalMTProxyUpstream.Target] = []
        if datacenter > 0 {
            // The CloudFlare zone fronts `kws<dc>` for every datacenter,
            // including the media ones (the reference's `tryCfproxyBaseDomain`
            // uses the unsigned id there).
            targets.append(.webSocket(host: "kws\(datacenter).\(self.domain)"))
            // Telegram's own web front numbers media datacenters differently and
            // has no `kws203`, so it uses the same override the reference does.
            let webDatacenter = LocalMTProxyConnection.webDatacenter(datacenter)
            if isMedia {
                targets.append(.webSocket(host: "kws\(webDatacenter)-1.web.telegram.org"))
                targets.append(.webSocket(host: "kws\(webDatacenter).web.telegram.org"))
            } else {
                targets.append(.webSocket(host: "kws\(webDatacenter).web.telegram.org"))
                targets.append(.webSocket(host: "kws\(webDatacenter)-1.web.telegram.org"))
            }
        }
        let address = self.datacenterAddress(datacenter)
        if !address.isEmpty {
            targets.append(.tcp(host: address, port: 443))
        }

        // The client's framing decides how the stream is cut into WebSocket
        // frames; the parser is a second stream with the same state, so it can
        // read the plaintext of bytes the encryptor has already produced.
        self.splittingDisabled = false
        self.packetBuffer = Data()
        self.framingBuffer = Data()

        let upstream = LocalMTProxyUpstream(
            queue: self.queue,
            targets: targets,
            initialHeader: relay.header,
            decryptor: relay.decryptor,
            onPayload: { [weak self] payload in
                self?.handleUpstreamData(payload)
            },
            onReadyState: { [weak self] ready in
                self?.setUpstreamReady(ready)
            },
            onError: { [weak self] message in
                self?.onUpstreamError?(message)
            },
            onClose: { [weak self] in
                self?.close()
            }
        )
        let framing = LocalMTProxyConnection.Framing(tag: tag)
        self.upstream = upstream
        self.upstreamEncryptor = relay.encryptor
        self.framingParser = relay.parser
        self.framing = framing
    }

    private var upstreamEncryptor: LocalMTProxyAesCtr?
    private var framingParser: LocalMTProxyAesCtr?
    private var framing: Framing?

    private struct Framing {
        let tag: UInt32

        var isAbridged: Bool {
            return self.tag == LocalMTProxyObfuscation.tagAbridged
        }
    }

    private func handleClientData(_ data: Data) {
        guard let keys = self.keys, let encryptor = self.upstreamEncryptor, let parser = self.framingParser, let framing = self.framing else {
            return
        }
        let plain = keys.decryptor.process(data)
        let cipher = encryptor.process(plain)
        let mirrored = parser.process(cipher)
        guard !cipher.isEmpty, mirrored.count == cipher.count else {
            return
        }
        self.packetBuffer.append(cipher)
        self.framingBuffer.append(mirrored)
        if self.packetBuffer.count > LocalMTProxyConnection.maximumBufferedBytes {
            self.close()
            return
        }
        if self.splittingDisabled {
            self.sendPackets([self.packetBuffer])
            self.packetBuffer = Data()
            self.framingBuffer = Data()
            return
        }
        for packet in self.takePackets(framing: framing) {
            self.upstream?.send(packet)
        }
    }

    /// Cuts the buffered stream at MTProto packet boundaries. The proxy sends
    /// one packet per WebSocket frame, which is what the web front expects.
    private func takePackets(framing: Framing) -> [Data] {
        var packets: [Data] = []
        while true {
            guard let (headerLength, payloadLength) = self.nextPacketLength(framing: framing) else {
                break
            }
            if payloadLength == 0 {
                // A zero length means the framing cannot be followed any more;
                // the reference core stops splitting and forwards the rest as is.
                // Whatever is already buffered goes with this flush: waiting for
                // the next chunk would stall a session that has nothing more to
                // send.
                self.splittingDisabled = true
                if !self.packetBuffer.isEmpty {
                    packets.append(self.packetBuffer)
                    self.packetBuffer = Data()
                    self.framingBuffer = Data()
                }
                return packets
            }
            let total = headerLength + payloadLength
            guard self.packetBuffer.count >= total, self.framingBuffer.count >= total else {
                break
            }
            packets.append(Data(self.packetBuffer.prefix(total)))
            self.packetBuffer.removeFirst(total)
            self.framingBuffer.removeFirst(total)
        }
        return packets
    }

    private func nextPacketLength(framing: Framing) -> (header: Int, payload: Int)? {
        if framing.isAbridged {
            guard let first = self.framingBuffer.first else {
                return nil
            }
            if first & 0x7f == 0x7f {
                guard self.framingBuffer.count >= 4 else {
                    return nil
                }
                let bytes = [UInt8](self.framingBuffer.prefix(4))
                let length = Int(bytes[1]) | (Int(bytes[2]) << 8) | (Int(bytes[3]) << 16)
                return (4, length * 4)
            }
            return (1, Int(first & 0x7f) * 4)
        }
        guard self.framingBuffer.count >= 4 else {
            return nil
        }
        let bytes = [UInt8](self.framingBuffer.prefix(4))
        let length = (Int(bytes[0]) | (Int(bytes[1]) << 8) | (Int(bytes[2]) << 16) | (Int(bytes[3]) << 24)) & 0x7fffffff
        return (4, length)
    }

    private func sendPackets(_ packets: [Data]) {
        for packet in packets {
            self.upstream?.send(packet)
        }
    }

    private func handleUpstreamData(_ data: Data) {
        guard let keys = self.keys else {
            return
        }
        let plain = keys.encryptor.process(data)
        if !plain.isEmpty {
            self.writeClient(plain)
        }
    }

    private func writeClient(_ data: Data) {
        self.connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if error != nil {
                self?.close()
            }
        })
    }
}

// MARK: - The upstream side (WebSocket over TLS, then raw TCP)

private final class LocalMTProxyUpstream {
    enum Target {
        case webSocket(host: String)
        case tcp(host: String, port: UInt16)
    }

    private let queue: DispatchQueue
    private var targets: [Target]
    private let initialHeader: Data
    private let decryptor: LocalMTProxyAesCtr
    private let onPayload: (Data) -> Void
    private let onReadyState: (Bool) -> Void
    private let onError: (String) -> Void
    private let onClose: () -> Void

    private var connection: NWConnection?
    private var receiveBuffer = Data()
    private var isWebSocket = false
    private var isReady = false
    private var reportedReady = false
    private var isClosed = false
    private var queued: [Data] = []
    private var pingTimer: DispatchSourceTimer?
    private var lastTargetDescription = ""

    private static let maximumBufferedBytes = 8 * 1024 * 1024
    private static let pingInterval: TimeInterval = 30.0

    init(queue: DispatchQueue, targets: [Target], initialHeader: Data, decryptor: LocalMTProxyAesCtr, onPayload: @escaping (Data) -> Void, onReadyState: @escaping (Bool) -> Void, onError: @escaping (String) -> Void, onClose: @escaping () -> Void) {
        self.queue = queue
        self.targets = targets
        self.initialHeader = initialHeader
        self.decryptor = decryptor
        self.onPayload = onPayload
        self.onReadyState = onReadyState
        self.onError = onError
        self.onClose = onClose
        self.openNextTarget()
    }

    private func reportReady(_ ready: Bool) {
        guard self.reportedReady != ready else {
            return
        }
        self.reportedReady = ready
        self.onReadyState(ready)
    }

    func send(_ packet: Data) {
        guard !self.isClosed else {
            return
        }
        if self.isReady {
            self.write(packet)
        } else {
            self.queued.append(packet)
        }
    }

    func stop() {
        guard !self.isClosed else {
            return
        }
        self.isClosed = true
        self.reportReady(false)
        self.pingTimer?.cancel()
        self.pingTimer = nil
        self.connection?.cancel()
        self.connection = nil
    }

    private func fail() {
        guard !self.isClosed else {
            return
        }
        self.reportReady(false)
        self.pingTimer?.cancel()
        self.pingTimer = nil
        self.connection?.cancel()
        self.connection = nil
        self.receiveBuffer = Data()
        self.isReady = false
        self.isWebSocket = false
        // Packets already produced for this target are still valid for the next
        // one: the header and the stream state do not change.
        self.openNextTarget()
    }

    private func openNextTarget() {
        guard !self.isClosed else {
            return
        }
        guard !self.targets.isEmpty else {
            self.onError("no upstream answered (\(self.lastTargetDescription))")
            self.close()
            return
        }
        let target = self.targets.removeFirst()
        switch target {
        case let .webSocket(host):
            self.lastTargetDescription = "wss://\(host)/apiws"
            self.openWebSocket(host: host)
        case let .tcp(host, port):
            self.lastTargetDescription = "tcp://\(host):\(port)"
            self.openTCP(host: host, port: port)
        }
    }

    private func close() {
        guard !self.isClosed else {
            return
        }
        self.isClosed = true
        self.reportReady(false)
        self.pingTimer?.cancel()
        self.pingTimer = nil
        self.connection?.cancel()
        self.connection = nil
        self.onClose()
    }

    private func makeConnection(host: String, port: UInt16, tls: Bool, serverName: String?) -> NWConnection {
        let parameters: NWParameters
        if tls {
            let tlsOptions = NWProtocolTLS.Options()
            if let serverName = serverName {
                sec_protocol_options_set_tls_server_name(tlsOptions.securityProtocolOptions, serverName)
            }
            let tcpOptions = NWProtocolTCP.Options()
            tcpOptions.noDelay = true
            tcpOptions.connectionTimeout = 10
            parameters = NWParameters(tls: tlsOptions, tcp: tcpOptions)
        } else {
            let tcpOptions = NWProtocolTCP.Options()
            tcpOptions.noDelay = true
            tcpOptions.connectionTimeout = 10
            parameters = NWParameters(tls: nil, tcp: tcpOptions)
        }
        parameters.includePeerToPeer = false
        return NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 443, using: parameters)
    }

    private func openWebSocket(host: String) {
        self.isWebSocket = true
        let connection = self.makeConnection(host: host, port: 443, tls: true, serverName: host)
        self.connection = connection
        let key = LocalMTProxyCrypto.randomBytes(16).base64EncodedString()
        self.pendingWebSocketKey = key
        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self, !self.isClosed, self.connection === connection else {
                return
            }
            switch state {
            case .ready:
                let request = "GET /apiws HTTP/1.1\r\nHost: \(host)\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: \(key)\r\nSec-WebSocket-Protocol: binary\r\n\r\n"
                connection.send(content: Data(request.utf8), completion: .contentProcessed { error in
                    if error != nil {
                        self.fail()
                    }
                })
                self.receiveLoop(on: connection)
            case .failed, .cancelled:
                self.fail()
            default:
                break
            }
        }
        connection.start(queue: self.queue)
    }

    private var pendingWebSocketKey: String?

    private func openTCP(host: String, port: UInt16) {
        self.isWebSocket = false
        let connection = self.makeConnection(host: host, port: port, tls: false, serverName: nil)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self, !self.isClosed, self.connection === connection else {
                return
            }
            switch state {
            case .ready:
                self.isReady = true
                self.reportReady(true)
                self.writeInitial()
                self.flushQueued()
                self.receiveLoop(on: connection)
            case .failed, .cancelled:
                self.fail()
            default:
                break
            }
        }
        connection.start(queue: self.queue)
    }

    private func writeInitial() {
        guard let connection = self.connection else {
            return
        }
        connection.send(content: self.initialHeader, completion: .contentProcessed { [weak self] error in
            if error != nil {
                self?.fail()
            }
        })
    }

    private func flushQueued() {
        guard self.isReady else {
            return
        }
        let packets = self.queued
        self.queued = []
        for packet in packets {
            self.write(packet)
        }
    }

    private func write(_ packet: Data) {
        guard let connection = self.connection else {
            return
        }
        let content = self.isWebSocket ? LocalMTProxyUpstream.maskFrame(packet, opcode: 0x2) : packet
        connection.send(content: content, completion: .contentProcessed { [weak self] error in
            if error != nil {
                self?.fail()
            }
        })
    }

    private func receiveLoop(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self = self, !self.isClosed, self.connection === connection else {
                return
            }
            if let data = data, !data.isEmpty {
                self.receiveBuffer.append(data)
                if self.receiveBuffer.count > LocalMTProxyUpstream.maximumBufferedBytes {
                    self.fail()
                    return
                }
                if self.isWebSocket {
                    if self.isReady {
                        self.consumeFrames()
                    } else {
                        self.consumeHandshake()
                    }
                } else {
                    let payload = self.receiveBuffer
                    self.receiveBuffer = Data()
                    self.onPayload(payload)
                }
            }
            if let error = error {
                _ = error
                self.fail()
                return
            }
            if isComplete {
                self.fail()
                return
            }
            self.receiveLoop(on: connection)
        }
    }

    private func consumeHandshake() {
        let terminator = Data("\r\n\r\n".utf8)
        guard let range = self.receiveBuffer.range(of: terminator) else {
            return
        }
        let head = self.receiveBuffer.subdata(in: 0 ..< range.lowerBound)
        self.receiveBuffer.removeSubrange(0 ..< range.upperBound)
        let text = String(decoding: head, as: UTF8.self)
        guard text.hasPrefix("HTTP/1.1 101") else {
            self.fail()
            return
        }
        if let key = self.pendingWebSocketKey {
            let expected = LocalMTProxyUpstream.webSocketAccept(key: key)
            if let line = text.components(separatedBy: "\r\n").first(where: { $0.lowercased().hasPrefix("sec-websocket-accept:") }) {
                let value = line.split(separator: ":", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                if value != expected {
                    self.fail()
                    return
                }
            }
        }
        self.isReady = true
        self.reportReady(true)
        // The header first, then whatever the client already produced.
        self.writeInitial()
        self.flushQueued()
        self.startPingTimer()
        if !self.receiveBuffer.isEmpty {
            self.consumeFrames()
        }
    }

    private func consumeFrames() {
        while !self.receiveBuffer.isEmpty {
            guard self.receiveBuffer.count >= 2 else {
                return
            }
            let bytes = [UInt8](self.receiveBuffer.prefix(2))
            let opcode = bytes[0] & 0x0f
            let masked = bytes[1] & 0x80 != 0
            var length = Int(bytes[1] & 0x7f)
            var offset = 2
            if length == 126 {
                guard self.receiveBuffer.count >= 4 else {
                    return
                }
                let extended = [UInt8](self.receiveBuffer.prefix(4))
                length = (Int(extended[2]) << 8) | Int(extended[3])
                offset = 4
            } else if length == 127 {
                guard self.receiveBuffer.count >= 10 else {
                    return
                }
                let extended = [UInt8](self.receiveBuffer.prefix(10))
                var value: UInt64 = 0
                for index in 2 ..< 10 {
                    value = (value << 8) | UInt64(extended[index])
                }
                // A front will never send a frame anywhere near this size; a
                // value that does not fit is a broken stream, not a frame.
                guard value <= UInt64(LocalMTProxyUpstream.maximumBufferedBytes) else {
                    self.fail()
                    return
                }
                length = Int(value)
                offset = 10
            }
            let maskLength = masked ? 4 : 0
            guard self.receiveBuffer.count >= offset + maskLength + length else {
                return
            }
            var payload = Data(self.receiveBuffer.subdata(in: (offset + maskLength) ..< (offset + maskLength + length)))
            if masked {
                let mask = [UInt8](self.receiveBuffer.subdata(in: offset ..< (offset + 4)))
                var payloadBytes = [UInt8](payload)
                for index in 0 ..< payloadBytes.count {
                    payloadBytes[index] ^= mask[index & 3]
                }
                payload = Data(payloadBytes)
            }
            self.receiveBuffer.removeFirst(offset + maskLength + length)
            switch opcode {
            case 0x2, 0x0:
                self.onPayload(payload)
            case 0x9:
                if let connection = self.connection {
                    connection.send(content: LocalMTProxyUpstream.maskFrame(payload, opcode: 0xa), completion: .contentProcessed { _ in })
                }
            case 0x8:
                self.fail()
                return
            default:
                break
            }
        }
    }

    private func startPingTimer() {
        self.pingTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: self.queue)
        timer.schedule(deadline: .now() + LocalMTProxyUpstream.pingInterval, repeating: LocalMTProxyUpstream.pingInterval)
        timer.setEventHandler { [weak self] in
            guard let self = self, !self.isClosed, self.isReady, self.isWebSocket, let connection = self.connection else {
                return
            }
            connection.send(content: LocalMTProxyUpstream.maskFrame(Data(), opcode: 0x9), completion: .contentProcessed { _ in })
        }
        self.pingTimer = timer
        timer.resume()
    }

    // MARK: - WebSocket framing

    private static func maskFrame(_ payload: Data, opcode: UInt8) -> Data {
        let length = payload.count
        var frame = Data()
        frame.append(0x80 | opcode)
        if length < 126 {
            frame.append(0x80 | UInt8(length))
        } else if length < 65536 {
            frame.append(0x80 | 126)
            frame.append(UInt8((length >> 8) & 0xff))
            frame.append(UInt8(length & 0xff))
        } else {
            frame.append(0x80 | 127)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((UInt64(length) >> UInt64(shift)) & 0xff))
            }
        }
        let mask = LocalMTProxyCrypto.randomBytes(4)
        frame.append(mask)
        var bytes = [UInt8](mask)
        payload.withUnsafeBytes { raw in
            if let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) {
                for index in 0 ..< length {
                    frame.append(base[index] ^ bytes[index & 3])
                }
            }
        }
        return frame
    }

    private static func webSocketAccept(key: String) -> String {
        let combined = Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8)
        return LocalMTProxyCrypto.sha1(combined).base64EncodedString()
    }
}