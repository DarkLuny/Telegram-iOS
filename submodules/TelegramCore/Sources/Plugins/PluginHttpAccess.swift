import Foundation
import SwiftSignalKit

/// Plain HTTP reads for the plugin runtime.
///
/// A plugin that maintains a subscription (a proxy list, a blocklist, an
/// announcement) has to fetch a URL. `fetchHttpResource` would work, but it is
/// shaped as a media fetch: it yields `MediaResourceDataFetchResult` parts and
/// reports every failure as `.generic`, which gives a plugin nothing to log. A
/// direct `URLSession` request keeps the status code, the headers and the body,
/// which is what a plugin branching on a 404 or a 429 needs.
///
/// The session is ephemeral: subscription data is not something to keep in a disk
/// cache, and a plugin has its own folder if it wants to cache the result.
///
/// Requests are throttled per plugin. A plugin that loops on a URL must not
/// saturate the connection for the whole app; the limit is generous enough for a
/// refresh that walks several mirrors.
public enum PluginHttpAccess {
    public struct Response {
        public let status: Int
        public let body: Data
        public let headers: [String: String]
    }

    public enum Failure: Error, CustomStringConvertible {
        case invalidURL(String)
        case transport(String)
        case tooManyRequests

        public var description: String {
            switch self {
            case let .invalidURL(value):
                return "not a valid http(s) URL: \(value)"
            case let .transport(message):
                return message
            case .tooManyRequests:
                return "too many requests in a short time; try again later"
            }
        }
    }

    /// Requests in flight, per plugin id. Guarded by `lock`.
    ///
    /// Static because the throttle is per plugin, not per call site, and a plugin
    /// can reach this from `http_*` and from its own `run_on_queue` work alike.
    private static let lock = NSLock()
    private static var inFlight: [String: Int] = [:]
    private static let maximumInFlightPerPlugin = 4

    /// One shared session: creating a session per request would leak a connection
    /// pool each time, and a subscription refresh is a handful of small reads.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20.0
        configuration.timeoutIntervalForResource = 30.0
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    public static func get(pluginId: String, url: String, headers: [String: String], timeout: Double) -> Signal<Response, Failure> {
        return self.request(pluginId: pluginId, method: "GET", url: url, headers: headers, body: nil, timeout: timeout)
    }

    /// A request with an explicit method and optional body.
    ///
    /// `get` is the read a subscription needs; a plugin that posts a result, a
    /// webhook callback or a form calls through here. The method is validated
    /// against the small set a plugin realistically needs, and the body is
    /// attached as raw bytes with a `Content-Type` the caller supplies, because
    /// guessing between form, JSON and text is exactly the decision the plugin
    /// already made.
    public static func request(
        pluginId: String,
        method: String,
        url: String,
        headers: [String: String],
        body: Data?,
        timeout: Double
    ) -> Signal<Response, Failure> {
        guard let parsed = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = parsed.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return .fail(.invalidURL(url))
        }
        let verb = method.uppercased()
        guard ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"].contains(verb) else {
            return .fail(.transport("unsupported HTTP method: \(method)"))
        }

        return Signal { subscriber in
            // Reserved inside the generator, not before it: `start` can be called
            // more than once for one signal value, and a reservation taken before
            // the closure would be counted but never released.
            guard PluginHttpAccess.reserve(pluginId: pluginId) else {
                subscriber.putError(.tooManyRequests)
                return EmptyDisposable
            }

            var request = URLRequest(url: parsed)
            request.httpMethod = verb
            // A plugin that fetches a JSON subscription should get the bytes, not
            // whatever the CDN negotiated; a fixed Accept keeps two runs identical.
            request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
            if timeout > 0.0 {
                request.timeoutInterval = timeout
            }
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
            if let body = body, verb != "GET", verb != "HEAD" {
                request.httpBody = body
            }

            let task = PluginHttpAccess.session.dataTask(with: request) { data, response, error in
                defer {
                    PluginHttpAccess.release(pluginId: pluginId)
                }
                if let error = error {
                    subscriber.putError(.transport(error.localizedDescription))
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    subscriber.putError(.transport("the response was not HTTP"))
                    return
                }
                subscriber.putNext(Response(
                    status: http.statusCode,
                    body: data ?? Data(),
                    headers: PluginHttpAccess.stringHeaders(http.allHeaderFields)
                ))
                subscriber.putCompletion()
            }
            task.resume()

            return ActionDisposable {
                task.cancel()
            }
        }
    }

    private static func reserve(pluginId: String) -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        let current = self.inFlight[pluginId] ?? 0
        guard current < self.maximumInFlightPerPlugin else {
            return false
        }
        self.inFlight[pluginId] = current + 1
        return true
    }

    private static func release(pluginId: String) {
        self.lock.lock()
        defer { self.lock.unlock() }
        let current = (self.inFlight[pluginId] ?? 1) - 1
        if current <= 0 {
            self.inFlight.removeValue(forKey: pluginId)
        } else {
            self.inFlight[pluginId] = current
        }
    }

    /// Header names are compared case-insensitively by HTTP but the dictionary
    /// keeps whatever casing the server used; normalising means a plugin can look
    /// up `content-type` and get an answer.
    private static func stringHeaders(_ headers: [AnyHashable: Any]) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in headers {
            guard let key = key as? String, let value = value as? String else {
                continue
            }
            result[key.lowercased()] = value
        }
        return result
    }
}