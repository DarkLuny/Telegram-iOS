import Foundation

/// The YAML reader the Elyx loader needs, not a general YAML implementation.
///
/// `metainfo.yml` and `refmap.yml` are both shallow documents: a mapping of
/// string keys to scalars, occasionally one level of nesting (a `dependencies`
/// block, a `platforms` list) and never anchors, tags, multi-document streams or
/// merge keys. Pulling a full YAML library into the IPA for that would add a
/// dependency and a build step for maybe a hundred and fifty lines of parsing.
///
/// What this covers: block mappings by indentation, block sequences written as
/// `- item`, `key: value` with an optional `#` comment, single- and double-quoted
/// scalars, `|` and `>` block scalars, `true`/`false`/`null`/`~`, and empty values
/// that open a nested block. A JSON document is accepted too — `metainfo.json` is
/// a legal Elyx metainfo name, and JSON goes straight to `JSONSerialization`
/// rather than through the YAML path.
///
/// What it does not cover, and does not pretend to: flow mappings and sequences
/// (`{a: b}`, `[1, 2]`) are kept as their literal text, anchors and aliases are
/// not resolved, and a multi-document stream keeps only the first document. The
/// Elyx format uses none of those; a file that does reads as strings, which the
/// caller sees as a missing field rather than a silently wrong value.
///
/// Scalars are strings unless they are `true`, `false`, `null` or `~`. Numbers are
/// deliberately *not* converted: a plugin id or a version is a name as often as a
/// number, and `1.10` becoming the float `1.1` would silently change a comparison
/// the plugin makes against it.
public struct PluginYAML {
    public let root: [String: Any]

    public enum ParseError: Error, CustomStringConvertible {
        case notAMapping
        case badIndentation(line: Int)

        public var description: String {
            switch self {
            case .notAMapping:
                return "the document is not a mapping at its top level"
            case let .badIndentation(line):
                return "line \(line) is indented more than its parent but does not open a block"
            }
        }
    }

    public init(text: String) throws {
        var body = text
        if body.hasPrefix("\u{feff}") {
            body.removeFirst()
        }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ParseError.notAMapping
        }
        if trimmed.hasPrefix("{") {
            guard let data = trimmed.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let mapping = object as? [String: Any] else {
                throw ParseError.notAMapping
            }
            self.root = mapping
            return
        }
        var lines: [Line] = []
        var number = 0
        for raw in body.components(separatedBy: .newlines) {
            number += 1
            if let line = PluginYAML.prepare(raw, number: number) {
                lines.append(line)
            }
        }
        guard !lines.isEmpty else {
            throw ParseError.notAMapping
        }
        var index = 0
        let value = try PluginYAML.parseBlock(lines, &index, indent: lines[0].indent)
        guard let mapping = value as? [String: Any] else {
            throw ParseError.notAMapping
        }
        self.root = mapping
    }

    /// The document as a mapping, or nil when it does not parse as one.
    ///
    /// The install path wants "read it if it is valid, otherwise try the next
    /// candidate", which is what `try?` at every call site looks like. One helper
    /// keeps that shape readable and keeps the `try` noise out of `PluginElyx`.
    public static func mapping(text: String) -> [String: Any]? {
        guard let document = try? PluginYAML(text: text) else {
            return nil
        }
        return document.root
    }

    /// The same, read from disk. An unreadable file is "no document", not an
    /// error: the caller falls back to the next name it knows.
    public static func mapping(contentsOf url: URL) -> [String: Any]? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        return PluginYAML.mapping(text: text)
    }

    // MARK: - Lines

    /// One non-blank, non-comment line with its indentation measured.
    ///
    /// `text` has the comment stripped and both ends trimmed, which is what
    /// structure parsing wants. `raw` keeps the line as written past its
    /// indentation, because a block scalar's content is text, not syntax: a `#`
    /// inside a `description: |` block belongs to the description.
    private struct Line {
        let indent: Int
        let text: String
        let raw: String
        let number: Int
    }

    /// Measures indentation and strips a comment, or answers nil for a line that
    /// carries nothing.
    ///
    /// A `#` starts a comment only at the beginning of a line or after
    /// whitespace, and never inside a quoted scalar — `name: "a # b"` keeps the
    /// hash. Tabs count as two columns: YAML forbids them for indentation, but a
    /// hand-edited file on Windows has them, and refusing the whole document over
    /// that is worse than reading it.
    private static func prepare(_ raw: String, number: Int) -> Line? {
        var indent = 0
        var position = raw.startIndex
        while position < raw.endIndex {
            let character = raw[position]
            if character == " " {
                indent += 1
            } else if character == "\t" {
                indent += 2
            } else {
                break
            }
            position = raw.index(after: position)
        }
        let content = String(raw[position...])
        let stripped = stripComment(content).trimmingCharacters(in: .whitespaces)
        if stripped.isEmpty {
            return nil
        }
        return Line(indent: indent, text: stripped, raw: content, number: number)
    }

    private static func stripComment(_ text: String) -> String {
        var inSingle = false
        var inDouble = false
        var index = text.startIndex
        var previous: Character = " "
        while index < text.endIndex {
            let character = text[index]
            if character == "'" && !inDouble {
                inSingle.toggle()
            } else if character == "\"" && !inSingle {
                // A backslash escapes the next character inside a double-quoted
                // scalar, so `"a \" # b"` is not a comment either.
                if previous == "\\" {
                    previous = character
                    index = text.index(after: index)
                    continue
                }
                inDouble.toggle()
            } else if character == "#" && !inSingle && !inDouble {
                if previous == " " || previous == "\t" {
                    return String(text[text.startIndex ..< index])
                }
            }
            previous = character
            index = text.index(after: index)
        }
        return text
    }

    // MARK: - Blocks

    private static func parseBlock(_ lines: [Line], _ index: inout Int, indent: Int) throws -> Any {
        guard index < lines.count else {
            return [String: Any]()
        }
        if lines[index].text.hasPrefix("-") {
            return try parseSequence(lines, &index, indent: indent)
        }
        return try parseMapping(lines, &index, indent: indent)
    }

    private static func parseMapping(_ lines: [Line], _ index: inout Int, indent: Int) throws -> [String: Any] {
        var result: [String: Any] = [:]
        while index < lines.count {
            let line = lines[index]
            if line.indent < indent {
                break
            }
            if line.indent > indent {
                throw ParseError.badIndentation(line: line.number)
            }
            guard let split = splitKey(line.text) else {
                // A line with no colon at mapping level is malformed. Skipping it
                // keeps the fields around it readable, which matters more than
                // rejecting the file over one stray line.
                index += 1
                continue
            }
            index += 1
            let rawValue = split.value.trimmingCharacters(in: .whitespaces)
            if rawValue.isEmpty {
                // An empty value opens a nested block when the next line is
                // deeper, and is the empty string when there is none.
                if index < lines.count && lines[index].indent > indent {
                    result[split.key] = try parseBlock(lines, &index, indent: lines[index].indent)
                } else {
                    result[split.key] = ""
                }
                continue
            }
            if rawValue == "|" || rawValue == ">" || rawValue == "|-" || rawValue == ">-" || rawValue == "|+" || rawValue == ">+" {
                result[split.key] = parseBlockScalar(lines, &index, indent: indent, folded: rawValue.hasPrefix(">"), keepTrailing: !rawValue.hasSuffix("-"))
                continue
            }
            result[split.key] = decodeScalar(rawValue)
        }
        return result
    }

    private static func parseSequence(_ lines: [Line], _ index: inout Int, indent: Int) throws -> [Any] {
        var result: [Any] = []
        while index < lines.count {
            let line = lines[index]
            if line.indent < indent {
                break
            }
            if line.indent > indent {
                throw ParseError.badIndentation(line: line.number)
            }
            guard line.text.hasPrefix("-") else {
                break
            }
            let rest = String(line.text.dropFirst()).trimmingCharacters(in: .whitespaces)
            index += 1
            if rest.isEmpty {
                if index < lines.count && lines[index].indent > indent {
                    result.append(try parseBlock(lines, &index, indent: lines[index].indent))
                } else {
                    result.append("")
                }
                continue
            }
            // `- key: value` starts a mapping whose first line is inline with the
            // dash; the rest of that mapping is indented one step further.
            if let split = splitKey(rest) {
                var entry: [String: Any] = [:]
                let value = split.value.trimmingCharacters(in: .whitespaces)
                if value.isEmpty {
                    if index < lines.count && lines[index].indent > indent {
                        entry[split.key] = try parseBlock(lines, &index, indent: lines[index].indent)
                    } else {
                        entry[split.key] = ""
                    }
                } else {
                    entry[split.key] = decodeScalar(value)
                }
                if index < lines.count && lines[index].indent > indent && !lines[index].text.hasPrefix("-") {
                    let nested = try parseMapping(lines, &index, indent: lines[index].indent)
                    for (key, nestedValue) in nested {
                        entry[key] = nestedValue
                    }
                }
                result.append(entry)
                continue
            }
            result.append(decodeScalar(rest))
        }
        return result
    }

    /// Joins the lines under a `|` or `>` marker.
    ///
    /// The content is taken from `raw`, so a `#` inside a description stays part
    /// of it, and from the first non-space column, so the block's own indentation
    /// does not leak into the value.
    private static func parseBlockScalar(_ lines: [Line], _ index: inout Int, indent: Int, folded: Bool, keepTrailing: Bool) -> String {
        var collected: [String] = []
        while index < lines.count && lines[index].indent > indent {
            collected.append(lines[index].raw.trimmingCharacters(in: .whitespaces))
            index += 1
        }
        var joined = folded ? collected.joined(separator: " ") : collected.joined(separator: "\n")
        if keepTrailing {
            joined += "\n"
        }
        return joined.trimmingCharacters(in: .newlines)
    }

    /// Splits `key: value` at the first colon that is followed by whitespace or
    /// ends the line, so `https://example.com` inside a value is not split.
    private static func splitKey(_ text: String) -> (key: String, value: String)? {
        var inSingle = false
        var inDouble = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "'" && !inDouble {
                inSingle.toggle()
            } else if character == "\"" && !inSingle {
                inDouble.toggle()
            } else if character == ":" && !inSingle && !inDouble {
                let after = text.index(after: index)
                if after == text.endIndex || text[after] == " " || text[after] == "\t" {
                    let key = unquote(String(text[text.startIndex ..< index]).trimmingCharacters(in: .whitespaces))
                    let value = after == text.endIndex ? "" : String(text[after...])
                    return (key, value)
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    // MARK: - Scalars

    private static func decodeScalar(_ text: String) -> Any {
        let unquoted = unquote(text)
        switch unquoted {
        case "null", "~", "Null", "NULL":
            return NSNull()
        case "true", "True", "TRUE":
            return true
        case "false", "False", "FALSE":
            return false
        default:
            return unquoted
        }
    }

    /// Removes matching surrounding quotes and resolves the escapes a
    /// double-quoted scalar allows. Returns the text unchanged when it is not
    /// quoted, which is what an unquoted value is.
    private static func unquote(_ text: String) -> String {
        guard text.count >= 2 else {
            return text
        }
        if text.hasPrefix("\"") && text.hasSuffix("\"") {
            let inner = String(text.dropFirst().dropLast())
            return inner
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\t", with: "\t")
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
        if text.hasPrefix("'") && text.hasSuffix("'") {
            let inner = String(text.dropFirst().dropLast())
            // In a single-quoted YAML scalar the only escape is `''` for a quote.
            return inner.replacingOccurrences(of: "''", with: "'")
        }
        return text
    }
}