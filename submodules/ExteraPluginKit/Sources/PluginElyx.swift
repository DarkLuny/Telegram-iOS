import Foundation

/// Reads an Elyx archive: the ZIP-compatible multi-file plugin format.
///
/// exteraGram's Elyx turns the one-file plugin into a project — `metainfo.yml`,
/// `refmap.yml`, an entry module, resources and translations — and gives every
/// installed plugin its own Python namespace. The format is ported here; the
/// Python runtime under it is not, because this app evaluates plugin code with
/// JavaScriptCore. So the archive shape, `metainfo`, `refmap`, `assets`,
/// `strings` and per-plugin module isolation all carry over, while `main.py`,
/// `import_module` in Python semantics, bundled wheels and `mvel_execute` do
/// not — a `.elyx` whose entry module is Python is reported as such by the
/// loader, the same way a `.plugin` with Python inside is.
public enum PluginElyx {

    /// The names an archive may use, in the order the SDK discovers them.
    public static let archiveExtensions = ["elyx", "eaf"]
    /// `refmap` is discovered under any of these names, first match wins.
    static let refmapNames = ["refmap.yaml", "refmap.yml", "refmap.json"]
    static let metainfoNames = ["metainfo.yaml", "metainfo.yml", "metainfo.json"]
    /// The entry module, when `refmap` does not name one.
    static let defaultMain = "main.py"
    /// How deep a path may go inside the archive before it is treated as a
    /// wrapper directory rather than a project file.
    static let maxDepth = 6

    public struct Descriptor {
        /// The project root as extracted on disk.
        public let directory: URL
        public let metainfo: [String: Any]
        public let refmap: [String: Any]
        public let mainPath: String
        public let mainSource: String
        public let assetsDirectory: URL?
        public let stringsDirectory: URL?
    }

    public enum ElyxError: Error, CustomStringConvertible {
        case notAnArchive
        case noProjectRoot
        case missingMetainfo
        case missingMain(String)
        case metainfoInvalid(String)

        public var description: String {
            switch self {
            case .notAnArchive:
                return "the file is not a ZIP archive, so it is not an Elyx plugin"
            case .noProjectRoot:
                return "the archive has a wrapper directory; Elyx project files must sit at its root"
            case .missingMetainfo:
                return "no metainfo file at the archive root (looked for \(metainfoNames.joined(separator: ", ")))"
            case let .missingMain(path):
                return "the entry module \"\(path)\" is not in the archive"
            case let .metainfoInvalid(reason):
                return "metainfo is invalid: \(reason)"
            }
        }
    }

    /// Whether a picked file is meant to be an Elyx archive.
    ///
    /// The picker hands over a URL, so the extension is what is known before the
    /// bytes are read. `.elyx.zip` and `.eaf.zip` end in `.zip`, which is why the
    /// stem is checked as well as the extension.
    public static func looksLikeArchive(url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        if archiveExtensions.contains(where: { name.hasSuffix("." + $0) }) {
            return true
        }
        return archiveExtensions.contains(where: { name.hasSuffix("." + $0 + ".zip") })
    }

    /// The plugin id an archive will install under, read without extracting.
    ///
    /// The install path needs the id before anything is written: the directory
    /// is named after it and a reinstall replaces that directory. Reading
    /// `metainfo` out of the central directory costs one small member, where a
    /// full extraction before knowing the id would unpack assets that a rejected
    /// archive leaves behind.
    public static func identifier(inArchiveAt url: URL) throws -> String {
        guard let archive = PluginZip(url: url) else {
            throw ElyxError.notAnArchive
        }
        guard let metainfoPath = archive.firstPath(named: metainfoNames) else {
            // A `refmap` may point at a metainfo under a different name; read it
            // to find out rather than failing the install.
            if let refmapPath = archive.firstPath(named: refmapNames),
               let refmapText = archive.contents(of: refmapPath),
               let refmap = PluginYAML.mapping(text: refmapText),
               let pointer = refmap["metainfo"] as? String,
               let metainfoText = archive.contents(of: pointer),
               let metainfo = PluginYAML.mapping(text: metainfoText),
               let id = metainfo["id"] as? String {
                return id
            }
            throw ElyxError.missingMetainfo
        }
        guard let text = archive.contents(of: metainfoPath),
              let metainfo = PluginYAML.mapping(text: text) else {
            throw ElyxError.metainfoInvalid("it does not parse as YAML")
        }
        guard let id = metainfo["id"] as? String, !id.isEmpty else {
            throw ElyxError.metainfoInvalid("id is required")
        }
        return id
    }

    /// Extracts `url` into `directory` and reads the project description.
    ///
    /// `directory` is created fresh by the caller; everything inside the archive
    /// is written under it, and a path that would escape it is refused, so a
    /// crafted archive cannot write outside the plugin's own folder.
    public static func extract(archiveAt url: URL, into directory: URL) throws -> Descriptor {
        guard let archive = PluginZip(url: url) else {
            throw ElyxError.notAnArchive
        }
        let projectRoot = try archive.projectRoot()
        guard projectRoot != nil else {
            throw ElyxError.noProjectRoot
        }

        try archive.extractAll(into: directory)

        // Re-read what was just written from disk rather than from memory, so
        // the descriptor describes the installed project and a later edit to a
        // file is picked up by a reload.
        func diskPath(_ relative: String) -> URL {
            directory.appendingPathComponent(relative)
        }

        var refmap: [String: Any] = [:]
        if let refmapName = refmapNames.first(where: { archive.contains(path: $0) }) {
            refmap = PluginYAML.mapping(contentsOf: diskPath(refmapName)) ?? [:]
        } else if let refmapPath = archive.firstPath(named: refmapNames) {
            refmap = PluginYAML.mapping(contentsOf: diskPath(refmapPath)) ?? [:]
        }

        let metainfoPath = (refmap["metainfo"] as? String)
            ?? archive.firstPath(named: metainfoNames)
            ?? metainfoNames.first(where: { archive.contains(path: $0) })
        guard let metainfoPath = metainfoPath else {
            throw ElyxError.missingMetainfo
        }
        let metainfoText = (try? String(contentsOf: diskPath(metainfoPath), encoding: .utf8)) ?? ""
        guard let metainfo = PluginYAML.mapping(text: metainfoText) else {
            throw ElyxError.metainfoInvalid("it does not parse as YAML")
        }
        guard let id = metainfo["id"] as? String, !id.isEmpty else {
            throw ElyxError.metainfoInvalid("id is required")
        }
        guard metainfo["name"] is String else {
            throw ElyxError.metainfoInvalid("name is required")
        }

        let mainRelative = (refmap["main"] as? String) ?? defaultMain
        guard archive.contains(path: mainRelative), let mainSource = try? String(contentsOf: diskPath(mainRelative), encoding: .utf8) else {
            throw ElyxError.missingMain(mainRelative)
        }

        let assetsRelative = (refmap["assets"] as? String) ?? "assets"
        let assetsDirectory = FileManager.default.fileExists(atPath: diskPath(assetsRelative).path) ? diskPath(assetsRelative) : nil

        let stringsRelative = (refmap["strings"] as? String) ?? "strings"
        let stringsDirectory = FileManager.default.fileExists(atPath: diskPath(stringsRelative).path) ? diskPath(stringsRelative) : nil

        return Descriptor(
            directory: directory,
            metainfo: metainfo,
            refmap: refmap,
            mainPath: mainRelative,
            mainSource: mainSource,
            assetsDirectory: assetsDirectory,
            stringsDirectory: stringsDirectory
        )
    }
}
