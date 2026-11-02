import Foundation
import zlib

/// Reads the members of a ZIP archive.
///
/// Both Elyx (`.elyx` / `.eaf`) and a plugin file that the user zipped are ZIP
/// archives, and Foundation on iOS has no unzip API — `FileManager` unpacks
/// `.zip` only through `NSFileCoordinator`'s `.forUploading` pseudo-archive,
/// which writes a different shape than it reads. So the format is read here:
/// the end-of-central-directory record, the central directory, then each local
/// header, with `zlib`'s `inflate` for the compressed bytes.
///
/// Supported: stored (0) and deflate (8), ZIP64 entry counts and sizes, and the
/// data descriptor bit. Not supported, and refused rather than guessed: the
/// legacy encryption flag, and compression methods other than deflate.
final class PluginZip {
    struct Entry {
        let path: String
        let compressedSize: Int
        let uncompressedSize: Int
        let compressionMethod: Int
        let localHeaderOffset: Int
        let isDirectory: Bool
    }

    /// The archive's bytes, or nil when the file is not a ZIP at all.
    private let data: Data
    private let entries: [Entry]
    private var byPath: [String: Entry] = [:]

    /// Opens the archive. Returns nil when the file is missing, too small, or
    /// does not start with a ZIP signature.
    init?(url: URL) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return nil
        }
        guard data.count >= 22 else {
            return nil
        }
        self.data = data
        guard let parsed = PluginZip.readCentralDirectory(data) else {
            return nil
        }
        self.entries = parsed
        for entry in parsed {
            self.byPath[entry.path] = entry
        }
    }

    // MARK: - Lookup

    func contains(path: String) -> Bool {
        return self.byPath[path] != nil
    }

    /// The first existing path among `names`, preferring the exact name and then
    /// the same name under a single wrapper directory.
    ///
    /// Elyx requires project files at the archive root, but an archive that
    /// zipped its folder rather than its contents is a common mistake, and
    /// finding the file anyway lets the error explain which one it was.
    func firstPath(named names: [String]) -> String? {
        for name in names where self.byPath[name] != nil {
            return name
        }
        for entry in self.entries where !entry.isDirectory {
            let last = (entry.path as NSString).lastPathComponent
            if names.contains(last), entry.path.components(separatedBy: "/").count == 2 {
                return entry.path
            }
        }
        return nil
    }

    /// The directory every project file sits under, or `""` when the files are
    /// already at the root.
    ///
    /// Returns nil when the archive holds more than one top-level directory —
    /// that is not a single project, and picking one of them would be a guess.
    func projectRoot() throws -> String? {
        var roots = Set<String>()
        var hasRootFile = false
        for entry in self.entries where !entry.isDirectory {
            let components = entry.path.components(separatedBy: "/")
            if components.count == 1 {
                hasRootFile = true
            } else {
                roots.insert(components[0])
            }
        }
        if hasRootFile {
            return ""
        }
        guard roots.count == 1, let only = roots.first else {
            return roots.count > 1 ? nil : ""
        }
        // A wrapper is only a wrapper when it holds the description files. A
        // project whose own layout is `src/...` with its `main.py` at a deeper
        // path would otherwise be mistaken for a wrapped one.
        let marker = PluginElyx.refmapNames + PluginElyx.metainfoNames
        for name in marker where self.byPath["\(only)/\(name)"] != nil {
            return only
        }
        return ""
    }

    // MARK: - Reading

    /// The decompressed bytes of one member, or nil when the path is absent or
    /// the member cannot be decompressed.
    func contents(of path: String) -> String? {
        guard let entry = self.byPath[path] else {
            return nil
        }
        guard let bytes = self.bytes(of: entry) else {
            return nil
        }
        return String(data: bytes, encoding: .utf8)
    }

    func rawContents(of path: String) -> Data? {
        guard let entry = self.byPath[path] else {
            return nil
        }
        return self.bytes(of: entry)
    }

    /// Every file path in the archive, for a caller that walks the project.
    var filePaths: [String] {
        return self.entries.filter { !$0.isDirectory }.map { $0.path }
    }

    /// Writes every member under `directory`, keeping the archive's own paths.
    ///
    /// A path that resolves outside `directory` is refused: `..` in a crafted
    /// archive must not be able to overwrite a file elsewhere in the app's
    /// container. Absolute paths and backslashes are normalised away first.
    func extractAll(into directory: URL) throws {
        let fileManager = FileManager.default
        let base = directory.standardizedFileURL.path
        for entry in self.entries where !entry.isDirectory {
            let safe = PluginZip.sanitize(entry.path)
            guard !safe.isEmpty else {
                continue
            }
            let target = directory.appendingPathComponent(safe)
            let resolved = target.standardizedFileURL.path
            guard resolved.hasPrefix(base + "/") else {
                throw PluginElyx.ElyxError.metainfoInvalid("the archive has a path that escapes the plugin directory: \(entry.path)")
            }
            try fileManager.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )
            guard let bytes = self.bytes(of: entry) else {
                throw PluginElyx.ElyxError.metainfoInvalid("member \(entry.path) could not be decompressed")
            }
            try bytes.write(to: target, options: .atomic)
        }
    }

    /// Strips a leading slash and any `..` component, so the result is a
    /// relative path that stays inside a directory when appended to one.
    private static func sanitize(_ path: String) -> String {
        let normalised = path.replacingOccurrences(of: "\\", with: "/")
        var parts: [String] = []
        for component in normalised.components(separatedBy: "/") {
            switch component {
            case "", ".":
                continue
            case "..":
                if !parts.isEmpty {
                    parts.removeLast()
                }
            default:
                parts.append(component)
            }
        }
        return parts.joined(separator: "/")
    }

    /// Decompresses one member out of the archive bytes.
    private func bytes(of entry: Entry) -> Data? {
        guard entry.localHeaderOffset + 30 <= self.data.count else {
            return nil
        }
        guard let payload = PluginZip.localPayload(
            data: self.data,
            offset: entry.localHeaderOffset,
            compressedSize: entry.compressedSize,
            uncompressedSize: entry.uncompressedSize
        ) else {
            return nil
        }
        switch entry.compressionMethod {
        case 0:
            return payload
        case 8:
            return PluginZip.inflate(payload, expectedSize: entry.uncompressedSize)
        default:
            return nil
        }
    }

    // MARK: - Central directory

    /// Finds the end-of-central-directory record, walks the central directory,
    /// and returns one entry per member.
    ///
    /// The EOCD is located by scanning backwards for its signature, because a
    /// ZIP comment may sit after it and its length is only known once the record
    /// is found.
    private static func readCentralDirectory(_ data: Data) -> [Entry]? {
        let eocdSignature = UInt32(0x06054b50)
        let zip64LocatorSignature = UInt32(0x07064b50)
        let searchLimit = min(data.count, 22 + 65535)
        var eocdOffset: Int?
        var index = data.count - 22
        let lowest = data.count - searchLimit
        while index >= lowest && index >= 0 {
            if data.readUInt32LE(at: index) == eocdSignature {
                eocdOffset = index
                break
            }
            index -= 1
        }
        guard let eocd = eocdOffset else {
            return nil
        }

        var entryCount = Int(data.readUInt16LE(at: eocd + 10) ?? 0)
        var directoryOffset = Int(data.readUInt32LE(at: eocd + 16) ?? 0)
        var directorySize = Int(data.readUInt32LE(at: eocd + 12) ?? 0)

        // ZIP64: the 32-bit fields are sentinels and the real values sit in the
        // ZIP64 record the locator points at.
        if entryCount == 0xFFFF || directoryOffset == 0xFFFFFFFF || directorySize == 0xFFFFFFFF {
            if eocd >= 20, data.readUInt32LE(at: eocd - 20) == zip64LocatorSignature,
               let zip64Offset = data.readUInt64LE(at: eocd - 20 + 8) {
                let zip64 = Int(zip64Offset)
                if let count = data.readUInt64LE(at: zip64 + 32) {
                    entryCount = Int(count)
                }
                if let size = data.readUInt64LE(at: zip64 + 40) {
                    directorySize = Int(size)
                }
                if let offset = data.readUInt64LE(at: zip64 + 48) {
                    directoryOffset = Int(offset)
                }
            }
        }

        var entries: [Entry] = []
        var cursor = directoryOffset
        let end = directoryOffset + directorySize
        let centralSignature = UInt32(0x02014b50)
        while cursor + 46 <= data.count && cursor < end {
            guard data.readUInt32LE(at: cursor) == centralSignature else {
                break
            }
            let flags = data.readUInt16LE(at: cursor + 8) ?? 0
            // Bit 0 is the legacy encryption flag. A password-protected member
            // cannot be read, and the archive is refused by producing no entry
            // for it, which makes the missing-file error name the reason.
            if flags & 0x0001 != 0 {
                cursor += 46
                let nameLength = Int(data.readUInt16LE(at: cursor - 46 + 28) ?? 0)
                let extraLength = Int(data.readUInt16LE(at: cursor - 46 + 30) ?? 0)
                let commentLength = Int(data.readUInt16LE(at: cursor - 46 + 32) ?? 0)
                cursor += nameLength + extraLength + commentLength
                continue
            }
            let compressionMethod = Int(data.readUInt16LE(at: cursor + 10) ?? 0)
            var compressedSize = Int(data.readUInt32LE(at: cursor + 20) ?? 0)
            var uncompressedSize = Int(data.readUInt32LE(at: cursor + 24) ?? 0)
            let nameLength = Int(data.readUInt16LE(at: cursor + 28) ?? 0)
            let extraLength = Int(data.readUInt16LE(at: cursor + 30) ?? 0)
            let commentLength = Int(data.readUInt16LE(at: cursor + 32) ?? 0)
            var localOffset = Int(data.readUInt32LE(at: cursor + 42) ?? 0)
            let nameStart = cursor + 46
            guard nameStart + nameLength <= data.count else {
                break
            }
            let nameData = data.subdata(in: nameStart ..< nameStart + nameLength)
            let name = String(data: nameData, encoding: .utf8) ?? ""

            // ZIP64 extra field: sizes and offset of 0xFFFFFFFF live here, in
            // this order, and only the fields that are sentinels are present.
            if compressedSize == 0xFFFFFFFF || uncompressedSize == 0xFFFFFFFF || localOffset == 0xFFFFFFFF {
                let extraStart = nameStart + nameLength
                if extraStart + extraLength <= data.count {
                    var extra = extraStart
                    let extraEnd = extraStart + extraLength
                    while extra + 4 <= extraEnd {
                        let headerId = data.readUInt16LE(at: extra) ?? 0
                        let dataSize = Int(data.readUInt16LE(at: extra + 2) ?? 0)
                        if headerId == 0x0001 {
                            var field = extra + 4
                            let fieldEnd = field + dataSize
                            if uncompressedSize == 0xFFFFFFFF, field + 8 <= fieldEnd, let value = data.readUInt64LE(at: field) {
                                uncompressedSize = Int(value)
                                field += 8
                            }
                            if compressedSize == 0xFFFFFFFF, field + 8 <= fieldEnd, let value = data.readUInt64LE(at: field) {
                                compressedSize = Int(value)
                                field += 8
                            }
                            if localOffset == 0xFFFFFFFF, field + 8 <= fieldEnd, let value = data.readUInt64LE(at: field) {
                                localOffset = Int(value)
                            }
                            break
                        }
                        extra += 4 + dataSize
                    }
                }
            }

            entries.append(Entry(
                path: name,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                compressionMethod: compressionMethod,
                localHeaderOffset: localOffset,
                isDirectory: name.hasSuffix("/")
            ))
            cursor = nameStart + nameLength + extraLength + commentLength
        }
        return entries.isEmpty ? nil : entries
    }

    /// Skips the local header and returns the compressed bytes of one member.
    ///
    /// The local header's own name and extra lengths are used rather than the
    /// central directory's: the two may differ, and only the local header's
    /// extra field describes what actually precedes the data.
    private static func localPayload(
        data: Data,
        offset: Int,
        compressedSize: Int,
        uncompressedSize: Int
    ) -> Data? {
        let localSignature = UInt32(0x04034b50)
        guard data.readUInt32LE(at: offset) == localSignature else {
            return nil
        }
        let nameLength = Int(data.readUInt16LE(at: offset + 26) ?? 0)
        let extraLength = Int(data.readUInt16LE(at: offset + 28) ?? 0)
        let start = offset + 30 + nameLength + extraLength
        guard start <= data.count else {
            return nil
        }
        let available = data.count - start
        let size = compressedSize > 0 ? compressedSize : max(uncompressedSize, available)
        let end = min(data.count, start + size)
        guard start < end else {
            return nil
        }
        return data.subdata(in: start ..< end)
    }

    // MARK: - Inflate

    /// Raw-deflate decompression. `expectedSize` sizes the buffer; the stream's
    /// own end marker still decides how much actually came out.
    private static func inflate(_ input: Data, expectedSize: Int) -> Data? {
        guard !input.isEmpty else {
            return expectedSize == 0 ? Data() : nil
        }
        if expectedSize == 0 {
            return Data()
        }
        var output = Data(count: expectedSize)
        let written: Int? = output.withUnsafeMutableBytes { outputBuffer -> Int? in
            guard let outputBase = outputBuffer.bindMemory(to: UInt8.self).baseAddress else {
                return nil
            }
            return input.withUnsafeBytes { inputBuffer -> Int? in
                guard let inputBase = inputBuffer.bindMemory(to: UInt8.self).baseAddress else {
                    return nil
                }
                var stream = z_stream()
                stream.next_in = UnsafeMutablePointer<Bytef>(mutating: inputBase)
                stream.avail_in = uInt(input.count)
                stream.next_out = outputBase
                stream.avail_out = uInt(expectedSize)
                // Negative window bits select raw deflate, which is what a ZIP
                // member stores; the zlib wrapper is not present.
                guard inflateInit2_(&stream, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
                    return nil
                }
                defer { inflateEnd(&stream) }
                let status = inflate(&stream, Z_FINISH)
                guard status == Z_STREAM_END || status == Z_OK else {
                    return nil
                }
                return Int(stream.total_out)
            }
        }
        guard let count = written, count <= expectedSize else {
            return nil
        }
        return output.prefix(count)
    }
}

// MARK: - Little-endian reads

/// Bounds-checked little-endian reads over the archive bytes.
///
/// A ZIP truncation or a corrupt offset must produce a nil rather than a trap:
/// the input is an arbitrary file the user picked, so every field is read as if
/// it could be out of range.
extension Data {
    func readUInt16LE(at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= self.count else {
            return nil
        }
        let base = self.startIndex + offset
        return UInt16(self[base]) | (UInt16(self[base + 1]) << 8)
    }

    func readUInt32LE(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= self.count else {
            return nil
        }
        let base = self.startIndex + offset
        var value: UInt32 = 0
        for index in (0 ..< 4).reversed() {
            value = (value << 8) | UInt32(self[base + index])
        }
        return value
    }

    func readUInt64LE(at offset: Int) -> UInt64? {
        guard offset >= 0, offset + 8 <= self.count else {
            return nil
        }
        let base = self.startIndex + offset
        var value: UInt64 = 0
        for index in (0 ..< 8).reversed() {
            value = (value << 8) | UInt64(self[base + index])
        }
        return value
    }
}
