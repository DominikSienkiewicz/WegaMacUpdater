import Foundation

/// What a project file asks of one runtime.
public enum CleanupVersionSpec: Equatable, Sendable {
    case pin(String)
    case range(String)
    case path(String)
    case unresolvable(String)
}

public struct CleanupRequirement: Equatable, Sendable {
    public let tool: String
    public let spec: CleanupVersionSpec
    public let source: URL

    public init(tool: String, spec: CleanupVersionSpec, source: URL) {
        self.tool = tool
        self.spec = spec
        self.source = source
    }
}

/// Reads runtime requirements out of project files with line-based parsing only. The text comes
/// from user projects, so anything unparseable yields fewer requirements, never a failure.
public enum CleanupRequirementParser {
    private static let maxLineLength = 4096
    private static let unresolvableAliases: Set<String> = ["node", "stable", "latest", "lts", "current"]

    public static func requirements(in file: CleanupProjectFile) -> [CleanupRequirement] {
        let text = file.text.hasPrefix("\u{FEFF}") ? String(file.text.dropFirst()) : file.text
        guard !text.contains("\0") else { return [] }
        let found: [(tool: String, spec: CleanupVersionSpec)]
        switch file.kind {
        case .pythonVersion: found = pythonVersions(text)
        case .nvmrc, .nodeVersion: found = nodeVersions(text)
        case .toolVersions: found = toolVersions(text)
        case .miseToml: found = miseTools(text)
        case .pyprojectToml: found = pyprojectRanges(text)
        case .packageJson: found = packageJsonNode(text)
        case .sdkmanrc: found = sdkmanCandidates(text)
        case .rustToolchain: found = rustToolchain(text)
        case .rustToolchainToml: found = rustToolchainToml(text)
        case .pyvenvCfg: found = pyvenvHome(text)
        case .gradleWrapperProperties, .gradleDaemonJvmProperties, .gradleBuildScript: found = []
        }
        return found.map { CleanupRequirement(tool: $0.tool, spec: $0.spec, source: file.url) }
    }

    private typealias Found = [(tool: String, spec: CleanupVersionSpec)]

    // MARK: Line plumbing

    private static func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).compactMap { raw in
            raw.count > maxLineLength ? nil : String(raw)
        }
    }

    private static func contentLines(_ text: String, commentMarker: Character = "#") -> [String] {
        lines(text).compactMap { line in
            let content = stripComment(line, marker: commentMarker).trimmingCharacters(in: .whitespaces)
            return content.isEmpty ? nil : content
        }
    }

    /// Cuts at the first marker outside a quoted string.
    private static func stripComment(_ line: String, marker: Character) -> String {
        var quote: Character?
        var result = ""
        for character in line {
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == marker {
                break
            }
            result.append(character)
        }
        return result
    }

    private static func unquoted(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2, let first = trimmed.first, first == trimmed.last, first == "\"" || first == "'" else {
            return trimmed
        }
        return String(trimmed.dropFirst().dropLast())
    }

    private static func keyValue(_ line: String) -> (key: String, value: String)? {
        guard let equals = line.firstIndex(of: "=") else { return nil }
        let key = unquoted(String(line[..<equals]))
        let value = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
        return key.isEmpty ? nil : (key, value)
    }

    private static func sectionName(_ line: String) -> String? {
        guard line.hasPrefix("["), line.hasSuffix("]") else { return nil }
        return line.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")).lowercased()
    }

    /// The `key = value` pairs directly under `[section]`, with multi-line arrays joined.
    private static func entries(in text: String, section wanted: String) -> [(key: String, value: String)] {
        var current = ""
        var pending: (key: String, value: String)?
        var result: [(key: String, value: String)] = []
        for line in contentLines(text) {
            if var open = pending {
                open.value += " " + line
                if line.contains("]") { result.append(open); pending = nil } else { pending = open }
                continue
            }
            if let name = sectionName(line) { current = name; continue }
            guard current == wanted, let pair = keyValue(line) else { continue }
            if pair.value.hasPrefix("["), !pair.value.contains("]") { pending = pair } else { result.append(pair) }
        }
        return result
    }

    // MARK: Version text

    private static func nodeSpec(_ raw: String) -> CleanupVersionSpec {
        let lowered = raw.lowercased()
        if lowered.hasPrefix("lts") || unresolvableAliases.contains(lowered) { return .unresolvable(raw) }
        let stripped = lowered.hasPrefix("v") ? String(raw.dropFirst()) : raw
        return stripped.isEmpty ? .unresolvable(raw) : .pin(stripped)
    }

    private static func normalisedTool(_ name: String) -> String {
        let lowered = name.lowercased()
        return lowered == "nodejs" ? "node" : lowered
    }

    private static func quotedStrings(in text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quote: Character?
        for character in text {
            if let open = quote {
                if character == open { result.append(current); current = ""; quote = nil } else { current.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
            }
        }
        return result
    }

    // MARK: Per kind

    private static func pythonVersions(_ text: String) -> Found {
        contentLines(text).filter { $0.lowercased() != "system" }.map { ("python", .pin($0)) }
    }

    private static func nodeVersions(_ text: String) -> Found {
        contentLines(text).prefix(1).map { ("node", nodeSpec($0)) }
    }

    private static func toolVersions(_ text: String) -> Found {
        var result: Found = []
        for line in contentLines(text) {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard parts.count >= 2 else { continue }
            let tool = normalisedTool(parts[0])
            for version in parts.dropFirst() where !isSkippedToolVersion(version) {
                result.append((tool, versionAliasSpec(version)))
            }
        }
        return result
    }

    private static func isSkippedToolVersion(_ version: String) -> Bool {
        version == "system" || version.hasPrefix("ref:") || version.hasPrefix("path:")
    }

    private static func miseTools(_ text: String) -> Found {
        var result: Found = []
        for pair in entries(in: text, section: "tools") {
            let tool = normalisedTool(pair.key)
            if pair.value.hasPrefix("{") {
                result.append((tool, miseTableSpec(pair.value)))
            } else if pair.value.hasPrefix("[") {
                result.append(contentsOf: quotedStrings(in: pair.value).map { (tool, miseSpec($0)) })
            } else {
                result.append((tool, miseSpec(unquoted(pair.value))))
            }
        }
        return result
    }

    /// Aliases resolve at install time, so no installed version can be matched against them.
    private static func versionAliasSpec(_ version: String) -> CleanupVersionSpec {
        let lowered = version.lowercased()
        let isAlias = lowered == "latest" || lowered == "lts" || lowered.hasPrefix("latest:")
            || lowered.hasPrefix("lts/") || lowered.hasPrefix("lts-") || lowered.hasPrefix("prefix:")
        return isAlias ? .unresolvable(version) : .pin(version)
    }

    private static func miseSpec(_ version: String) -> CleanupVersionSpec {
        let lowered = version.lowercased()
        return version.isEmpty ? .unresolvable(version) : versionAliasSpec(version)
    }

    private static func miseTableSpec(_ table: String) -> CleanupVersionSpec {
        let body = table.trimmingCharacters(in: CharacterSet(charactersIn: "{} "))
        for field in body.split(separator: ",") {
            if let pair = keyValue(String(field)), pair.key == "version" { return miseSpec(unquoted(pair.value)) }
        }
        return .unresolvable(table)
    }

    private static func pyprojectRanges(_ text: String) -> Found {
        var result: Found = []
        for pair in entries(in: text, section: "project") where pair.key == "requires-python" {
            result.append(("python", .range(unquoted(pair.value))))
        }
        for pair in entries(in: text, section: "tool.poetry.dependencies") where pair.key == "python" {
            result.append(("python", .range(unquoted(pair.value))))
        }
        return result.filter { if case .range(let value) = $0.spec { return !value.isEmpty } else { return true } }
    }

    private static func packageJsonNode(_ text: String) -> Found {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var result: Found = []
        if let engines = root["engines"] as? [String: Any], let node = engines["node"] as? String, !node.isEmpty {
            result.append(("node", .range(node)))
        }
        if let volta = root["volta"] as? [String: Any], let node = volta["node"] as? String, !node.isEmpty {
            result.append(("node", .pin(node)))
        }
        return result
    }

    private static func sdkmanCandidates(_ text: String) -> Found {
        contentLines(text).compactMap { line in
            guard let pair = keyValue(line), !pair.value.isEmpty else { return nil }
            return (normalisedTool(pair.key), .pin(unquoted(pair.value)))
        }
    }

    private static func rustToolchain(_ text: String) -> Found {
        let content = contentLines(text)
        let isToml = content.contains { sectionName($0) == "toolchain" || keyValue($0)?.key == "channel" }
        if isToml { return content.compactMap(channelPin) }
        guard let first = content.first else { return [] }
        return [("rust", .pin(first))]
    }

    private static func rustToolchainToml(_ text: String) -> Found {
        entries(in: text, section: "toolchain").filter { $0.key == "channel" }.compactMap { pair in
            let channel = unquoted(pair.value)
            return channel.isEmpty ? nil : ("rust", .pin(channel))
        }
    }

    private static func channelPin(_ line: String) -> (tool: String, spec: CleanupVersionSpec)? {
        guard let pair = keyValue(line), pair.key == "channel" else { return nil }
        let channel = unquoted(pair.value)
        return channel.isEmpty ? nil : ("rust", .pin(channel))
    }

    private static func pyvenvHome(_ text: String) -> Found {
        lines(text).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let pair = keyValue(line), pair.key.lowercased() == "home", !pair.value.isEmpty else { return nil }
            return ("python", .path(pair.value))
        }
    }
}
