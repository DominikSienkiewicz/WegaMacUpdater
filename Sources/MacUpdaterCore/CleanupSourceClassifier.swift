import Foundation

/// A tool whose versions live in `~/<versionsDirectory>/<version>` and whose active copy is
/// named by the symlink `~/<pointer>`.
public struct CleanupNativeLayout: Equatable, Sendable {
    public let tool: String
    public let versionsDirectory: String
    public let pointer: String

    public init(tool: String, versionsDirectory: String, pointer: String) {
        self.tool = tool
        self.versionsDirectory = versionsDirectory
        self.pointer = pointer
    }
}

/// A location owned by an application that manages its own CLI copies. Report-only.
public struct CleanupAppManagedLocation: Equatable, Sendable {
    public let owner: String
    public let path: String

    public init(owner: String, path: String) {
        self.owner = owner
        self.path = path
    }
}

public enum CleanupKnownLayouts {
    public static let nativeVersionDirectories = [
        CleanupNativeLayout(
            tool: "claude",
            versionsDirectory: ".local/share/claude/versions",
            pointer: ".local/bin/claude"
        ),
    ]

    public static let appManagedLocations = [
        CleanupAppManagedLocation(owner: "Claude", path: "Library/Application Support/Claude/claude-code"),
        CleanupAppManagedLocation(owner: "Claude", path: "Library/Application Support/Claude/claude-code-vm"),
    ]
}

/// Decides, from a copy's resolved real path alone, which installer owns it. Pure: it never
/// touches the disk, and all comparisons are case-sensitive on Unicode-scalar components because
/// the input is a physical realpath.
public struct CleanupSourceClassifier: Sendable {
    public static let defaultSystemPrefixes = [
        "/usr/bin", "/bin", "/usr/sbin", "/sbin", "/System",
        "/Library/Developer/CommandLineTools",
        "/Applications/Xcode*.app/Contents/Developer",
    ]

    public static let rustupProxyNames: Set<String> = [
        "cargo", "cargo-clippy", "cargo-fmt", "clippy-driver", "rls", "rust-analyzer",
        "rust-gdb", "rust-gdbgui", "rust-lldb", "rustc", "rustdoc", "rustfmt", "rustup",
    ]

    private static let versionManagerRoots: [(manager: CleanupVersionManager, path: String)] = [
        (.uv, ".local/share/uv/python"), (.uv, ".local/share/uv/tools"),
        (.fnm, ".local/share/fnm"), (.fnm, ".fnm"),
        (.nvm, ".nvm/versions"),
        (.pyenv, ".pyenv/versions"),
        (.sdkman, ".sdkman/candidates"),
        (.rustup, ".rustup/toolchains"),
        (.mise, ".local/share/mise/installs"),
        (.asdf, ".asdf/installs"),
        (.volta, ".volta/tools"),
        (.pnpmEnv, "Library/pnpm/nodejs"),
    ]

    private static let packageManagerRoots: [(manager: CleanupPackageManager, path: String)] = [
        (.pipx, ".local/pipx/venvs"), (.pipx, ".local/share/pipx/venvs"),
        (.go, "go/bin"), (.bun, ".bun"),
    ]

    private let homeComponents: [String]
    private let brewComponents: [String]?
    private let systemPrefixes: [[String]]

    public init(
        home: URL,
        brewPrefix: URL?,
        systemPrefixes: [String] = CleanupSourceClassifier.defaultSystemPrefixes
    ) {
        homeComponents = CleanupPathText.components(of: home.path)
        brewComponents = brewPrefix.map { CleanupPathText.components(of: $0.path) }
        self.systemPrefixes = systemPrefixes.map { CleanupPathText.components(of: $0) }
    }

    public func classify(_ realpath: URL) -> CleanupSource {
        let path = CleanupPathText.components(of: realpath.path)
        let rules: [([String]) -> CleanupSource?] = [
            appManagedSource, systemSource, appBundleSource, cellarSource, caskroomSource,
            npmSource, pnpmGlobalSource, versionManagerSource, cargoSource, packageManagerSource,
            nativeSource,
        ]
        for rule in rules {
            if let source = rule(path) { return source }
        }
        return .standalone
    }

    private func underHome(_ relative: String) -> [String] {
        homeComponents + CleanupPathText.components(of: relative)
    }

    private func appManagedSource(_ path: [String]) -> CleanupSource? {
        CleanupKnownLayouts.appManagedLocations
            .first { Self.isUnder(path, underHome($0.path)) }
            .map { .appManaged(owner: $0.owner) }
    }

    private func appBundleSource(_ path: [String]) -> CleanupSource? {
        for index in path.indices.dropLast() where path[index + 1] == "Contents" {
            let component = path[index]
            if Self.hasScalarSuffix(component, ".app") {
                return .appBundle(name: String(component.unicodeScalars.dropLast(4)))
            }
        }
        return nil
    }

    private func cellarSource(_ path: [String]) -> CleanupSource? {
        brewChild(path, directory: "Cellar").map { .homebrewFormula(name: $0) }
    }

    private func caskroomSource(_ path: [String]) -> CleanupSource? {
        brewChild(path, directory: "Caskroom").map { .homebrewCask(token: $0) }
    }

    private func brewChild(_ path: [String], directory: String) -> String? {
        guard let brewComponents else { return nil }
        let root = brewComponents + [directory]
        guard Self.isUnder(path, root), path.count > root.count else { return nil }
        return path[root.count]
    }

    private func npmSource(_ path: [String]) -> CleanupSource? {
        Self.containsAdjacent(path, "lib", "node_modules") ? .packageManager(.npm) : nil
    }

    private func pnpmGlobalSource(_ path: [String]) -> CleanupSource? {
        Self.isUnder(path, underHome("Library/pnpm/global")) ? .packageManager(.pnpm) : nil
    }

    private func versionManagerSource(_ path: [String]) -> CleanupSource? {
        Self.versionManagerRoots
            .first { Self.isUnder(path, underHome($0.path)) }
            .map { .versionManager($0.manager) }
    }

    private func cargoSource(_ path: [String]) -> CleanupSource? {
        let root = underHome(".cargo/bin")
        guard Self.isUnder(path, root), path.count > root.count else { return nil }
        return Self.rustupProxyNames.contains(path[root.count]) ? .versionManager(.rustup) : .packageManager(.cargo)
    }

    private func packageManagerSource(_ path: [String]) -> CleanupSource? {
        Self.packageManagerRoots
            .first { Self.isUnder(path, underHome($0.path)) }
            .map { .packageManager($0.manager) }
    }

    private func nativeSource(_ path: [String]) -> CleanupSource? {
        CleanupKnownLayouts.nativeVersionDirectories
            .first { Self.isUnder(path, underHome($0.versionsDirectory)) }
            .map { .nativeVersionDirectory(tool: $0.tool) }
    }

    private func systemSource(_ path: [String]) -> CleanupSource? {
        systemPrefixes.contains { Self.isUnder(path, $0, allowingWildcards: true) } ? .system : nil
    }

    static func isUnder(_ path: [String], _ prefix: [String], allowingWildcards: Bool = false) -> Bool {
        guard path.count >= prefix.count else { return false }
        return zip(path, prefix).allSatisfy { component, expected in
            allowingWildcards ? matches(component, pattern: expected) : component == expected
        }
    }

    static func hasScalarSuffix(_ text: String, _ suffix: String) -> Bool {
        text.unicodeScalars.count > suffix.unicodeScalars.count
            && text.unicodeScalars.suffix(suffix.unicodeScalars.count).elementsEqual(suffix.unicodeScalars)
    }

    private static func matches(_ component: String, pattern: String) -> Bool {
        let parts = pattern.unicodeScalars.split(separator: "*", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return component == pattern }
        let scalars = component.unicodeScalars
        let head = parts[0]
        let tail = parts[1]
        return scalars.count >= head.count + tail.count
            && scalars.prefix(head.count).elementsEqual(head)
            && scalars.suffix(tail.count).elementsEqual(tail)
    }

    private static func containsAdjacent(_ path: [String], _ first: String, _ second: String) -> Bool {
        zip(path, path.dropFirst()).contains { $0 == first && $1 == second }
    }
}

/// Reads a version out of well-known path shapes. No execution, no disk access.
public enum CleanupVersionExtractor {
    public static func version(fromRealpath realpath: URL, source: CleanupSource) -> String? {
        let path = CleanupPathText.components(of: realpath.path)
        switch source {
        case let .homebrewFormula(name):
            return component(in: path, after: [name], following: "Cellar")
        case let .homebrewCask(token):
            return component(in: path, after: [token], following: "Caskroom")
        case .nativeVersionDirectory:
            return component(in: path, after: [], following: "versions")
        case .versionManager(.uv):
            return cpythonVersion(in: path)
        case .versionManager(.fnm):
            return nodeVersion(in: path, directory: ["node-versions"])
        case .versionManager(.nvm):
            return nodeVersion(in: path, directory: ["versions", "node"])
        default:
            return nil
        }
    }

    /// The component that follows `directory` and then the given `skipping` names.
    private static func component(in path: [String], after skipping: [String], following directory: String) -> String? {
        guard let index = path.firstIndex(of: directory) else { return nil }
        let start = index + 1
        guard path.count > start + skipping.count,
              Array(path[start ..< start + skipping.count]) == skipping else { return nil }
        return path[start + skipping.count]
    }

    private static func cpythonVersion(in path: [String]) -> String? {
        let marker = "cpython-".unicodeScalars
        for item in path {
            let scalars = item.unicodeScalars
            guard scalars.starts(with: marker) else { continue }
            let version = scalars.dropFirst(marker.count).prefix { $0 != "-" }
            if !version.isEmpty { return String(String.UnicodeScalarView(version)) }
        }
        return nil
    }

    private static func nodeVersion(in path: [String], directory: [String]) -> String? {
        for index in path.indices {
            let end = index + directory.count
            guard end < path.count, Array(path[index ..< end]) == directory else { continue }
            let scalars = path[end].unicodeScalars
            guard scalars.first == "v", let digit = scalars.dropFirst().first, digit.isASCII,
                  ("0" ... "9").contains(digit) else { continue }
            return String(String.UnicodeScalarView(scalars.dropFirst()))
        }
        return nil
    }
}
