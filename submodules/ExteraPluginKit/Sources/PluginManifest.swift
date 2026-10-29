import Foundation
import JavaScriptCore

/// A plugin's metadata, parsed from the top-level `__id__`, `__name__`, ...
/// constants. exteraGram parses these from Python source with `ast`; here the
/// plugin is plain JavaScript, so the loader reads them out of the evaluated
/// JSContext. They must stay plain literal assignments for that to work.
public struct PluginManifest: Equatable {
    public let id: String
    public let name: String
    public let description: String
    public let author: String
    public let version: String
    public let icon: String?
    public let appVersionRequirement: String?
    public let sdkVersionRequirement: String?
    public let requirements: [String]

    public init(
        id: String,
        name: String,
        description: String = "",
        author: String = "",
        version: String = "1.0",
        icon: String? = nil,
        appVersionRequirement: String? = nil,
        sdkVersionRequirement: String? = nil,
        requirements: [String] = []
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.author = author
        self.version = version
        self.icon = icon
        self.appVersionRequirement = appVersionRequirement
        self.sdkVersionRequirement = sdkVersionRequirement
        self.requirements = requirements
    }
}

public enum PluginError: Error, CustomStringConvertible {
    case invalidId(String)
    case missingIdentifier
    case missingName
    case unsupportedVersion(required: String, actual: String)
    case requirementsNotSupported([String])
    case evaluationFailed(String)
    case noPluginClass
    case runtimeUnavailable
    case notTextFile
    case tooLarge

    public var description: String {
        switch self {
        case let .invalidId(value):
            return "plugin id \"\(value)\" must be 2-32 characters of letters, digits, _ or -"
        case .missingIdentifier:
            return "__id__ is required"
        case .missingName:
            return "__name__ is required"
        case .notTextFile:
            return "the file is not UTF-8 text, so it cannot be a plugin"
        case .tooLarge:
            return "the file is larger than 4 MB, which no plugin needs"
        case let .unsupportedVersion(required, actual):
            return "plugin requires app version \(required), this build is \(actual)"
        case let .requirementsNotSupported(packages):
            return "__requirements__ needs Python packages, which this runtime cannot install: \(packages.joined(separator: ", "))"
        case let .evaluationFailed(message):
            return "plugin failed to load: \(message)"
        case .noPluginClass:
            return "plugin does not register a class extending BasePlugin"
        case .runtimeUnavailable:
            return "the JavaScript runtime is unavailable"
        }
    }
}

/// Compares dotted version strings the way exteraGram's `__app_version__` does:
/// `>=12.5.1`, `<=1.2`, `==1.0`, `>1`, `<2`. A bare version means `>=`.
///
/// The requirement describes what the *plugin* needs, so the comparison is
/// `actual <op> required` — `>=12.5.1` passes on 13.1.1 and fails on 12.5.0.
public func pluginVersionRequirementIsSatisfied(_ requirement: String, actual: String) -> Bool {
    var text = requirement.trimmingCharacters(in: .whitespaces)
    var comparison = ">="
    for candidate in [">=", "<=", "==", ">", "<"] where text.hasPrefix(candidate) {
        comparison = candidate
        text = String(text.dropFirst(candidate.count)).trimmingCharacters(in: .whitespaces)
        break
    }

    // Result of comparing the running app's version to the required one.
    let order = comparePluginVersions(actual, text)
    switch comparison {
    case ">=":
        return order >= 0
    case "<=":
        return order <= 0
    case "==":
        return order == 0
    case ">":
        return order > 0
    case "<":
        return order < 0
    default:
        return false
    }
}

/// Returns -1, 0 or 1 for `lhs` against `rhs`, padding the shorter string with
/// zeros so `12.5` and `12.5.0` compare equal.
func comparePluginVersions(_ lhs: String, _ rhs: String) -> Int {
    let left = lhs.split(separator: ".").map { Int($0) ?? 0 }
    let right = rhs.split(separator: ".").map { Int($0) ?? 0 }
    let count = max(left.count, right.count)
    for index in 0 ..< count {
        let l = index < left.count ? left[index] : 0
        let r = index < right.count ? right[index] : 0
        if l < r {
            return -1
        }
        if l > r {
            return 1
        }
    }
    return 0
}

/// One loaded plugin: its context, its instance, and the hooks it asked for.
public final class LoadedPlugin {
    public let manifest: PluginManifest
    public let directory: URL
    public let context: JSContext
    public let instance: JSValue
    public internal(set) var registeredRequestHooks: [String] = []
    /// Hook names registered with `match_substring`, i.e. a plugin that wants
    /// every request whose name contains a string (`messages.` for the whole
    /// namespace). Kept apart so matching stays a prefix/contains test rather
    /// than turning every entry into a scan pattern.
    public internal(set) var registeredSubstringHooks: [String] = []
    public internal(set) var wantsSendMessageHook: Bool = false
    public internal(set) var settings: [String: Any] = [:]
    public internal(set) var isEnabled: Bool = true
    /// Position in the load order. Hook chains run in this order, so a plugin's
    /// decision is reproducible instead of depending on dictionary iteration.
    public internal(set) var loadIndex: Int = 0

    init(manifest: PluginManifest, directory: URL, context: JSContext, instance: JSValue) {
        self.manifest = manifest
        self.directory = directory
        self.context = context
        self.instance = instance
    }
}