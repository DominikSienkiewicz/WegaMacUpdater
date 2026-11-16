import Foundation

/// One runtime version a version manager has installed.
public struct CleanupRuntimeInstall: Equatable, Sendable {
    public let manager: CleanupVersionManager
    public let tool: String
    public let version: String
    public let url: URL
    public let removal: CleanupAction

    public init(manager: CleanupVersionManager, tool: String, version: String, url: URL, removal: CleanupAction) {
        self.manager = manager
        self.tool = tool
        self.version = version
        self.url = url
        self.removal = removal
    }
}

/// A name a version manager links beside its installs to a place inside one of them, such as
/// pyenv-virtualenv's `~/.pyenv/versions/<env>` for the env it keeps in `<version>/envs/<env>`.
struct CleanupRuntimeAlias: Equatable, Sendable {
    let tool: String
    let name: String
    let target: URL
}

/// Lists what each version manager has installed and which version it uses by default, by reading
/// directories and settings files only; no manager is ever executed. Symlinked and dot entries are
/// never installs (`current`, `latest` and friends only point at one).
public struct CleanupRuntimeInventory: Sendable {
    private static let maxSettingsBytes = 262_144

    private let fileSystem: CleanupFileSystem
    private let home: URL

    public init(fileSystem: CleanupFileSystem, home: URL) {
        self.fileSystem = fileSystem
        self.home = home
    }

    // MARK: Installs

    public func installs() -> [CleanupRuntimeInstall] {
        uvInstalls() + pyenvInstalls() + fnmInstalls() + nvmInstalls() + sdkmanInstalls()
            + rustupInstalls() + miseInstalls() + asdfInstalls() + voltaInstalls() + pnpmInstalls()
    }

    private func uvInstalls() -> [CleanupRuntimeInstall] {
        directories(uvPythonRoot).compactMap { child in
            let parts = child.url.lastPathComponent.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 2, parts[0] == "cpython", !parts[1].isEmpty else { return nil }
            return runtime(.uv, ("python", parts[1]), child.url, ["uv", "python", "uninstall", parts[1]])
        }
    }

    private func pyenvInstalls() -> [CleanupRuntimeInstall] {
        directories(path(".pyenv/versions")).map { child in
            let version = child.url.lastPathComponent
            return runtime(.pyenv, ("python", version), child.url, ["pyenv", "uninstall", version])
        }
    }

    private func fnmInstalls() -> [CleanupRuntimeInstall] {
        fnmRoots.flatMap { root in
            directories(root.appending(path: "node-versions", directoryHint: .isDirectory)).compactMap { child in
                guard let version = Self.strippingV(child.url.lastPathComponent) else { return nil }
                return runtime(.fnm, ("node", version), child.url, ["fnm", "uninstall", version])
            }
        }
    }

    private func nvmInstalls() -> [CleanupRuntimeInstall] {
        directories(path(".nvm/versions/node")).compactMap { child in
            guard let version = Self.strippingV(child.url.lastPathComponent) else { return nil }
            return runtime(.nvm, ("node", version), child.url, ["nvm", "uninstall", version])
        }
    }

    private func sdkmanInstalls() -> [CleanupRuntimeInstall] {
        directories(path(".sdkman/candidates")).flatMap { candidate in
            let name = candidate.url.lastPathComponent
            return directories(candidate.url).map { child in
                let version = child.url.lastPathComponent
                return runtime(.sdkman, (name, version), child.url, ["sdk", "uninstall", name, version])
            }
        }
    }

    private func rustupInstalls() -> [CleanupRuntimeInstall] {
        directories(path(".rustup/toolchains")).map { child in
            let name = child.url.lastPathComponent
            return runtime(.rustup, ("rust", name), child.url, ["rustup", "toolchain", "uninstall", name])
        }
    }

    private func miseInstalls() -> [CleanupRuntimeInstall] {
        pluginInstalls(path(".local/share/mise/installs"), manager: .mise) { ["mise", "uninstall", "\($0)@\($1)"] }
    }

    private func asdfInstalls() -> [CleanupRuntimeInstall] {
        pluginInstalls(path(".asdf/installs"), manager: .asdf) { ["asdf", "uninstall", $0, $1] }
    }

    private func pluginInstalls(
        _ root: URL, manager: CleanupVersionManager, command: (String, String) -> [String]
    ) -> [CleanupRuntimeInstall] {
        directories(root).flatMap { plugin in
            let name = plugin.url.lastPathComponent
            return directories(plugin.url).map { child in
                let version = child.url.lastPathComponent
                return runtime(manager, (Self.normalisedTool(name), version), child.url, command(name, version), names: [name, version])
            }
        }
    }

    private func voltaInstalls() -> [CleanupRuntimeInstall] {
        directories(path(".volta/tools/image/node")).map { child in
            CleanupRuntimeInstall(
                manager: .volta, tool: "node", version: child.url.lastPathComponent, url: child.url,
                removal: .instruction(.removeWithCreatingTool)
            )
        }
    }

    private func pnpmInstalls() -> [CleanupRuntimeInstall] {
        pnpmNodeRoot.map { child in
            let version = child.url.lastPathComponent
            return runtime(.pnpmEnv, ("node", version), child.url, ["pnpm", "env", "remove", "--global", version])
        }
    }

    private var pnpmNodeRoot: [CleanupEntry] { directories(path("Library/pnpm/nodejs")) }

    /// A command is only offered when every name taken from the disk is a safe token.
    private func runtime(
        _ manager: CleanupVersionManager, _ identity: (tool: String, version: String), _ url: URL, _ command: [String]
    ) -> CleanupRuntimeInstall {
        runtime(manager, identity, url, command, names: [identity.tool, identity.version])
    }

    private func runtime(
        _ manager: CleanupVersionManager, _ identity: (tool: String, version: String), _ url: URL,
        _ command: [String], names: [String]
    ) -> CleanupRuntimeInstall {
        let safe = names.allSatisfy { CleanupDuplicateFindings.isSafeToolToken($0) }
        let removal: CleanupAction = safe ? .command(command.joined(separator: " ")) : .instruction(.removeWithCreatingTool)
        return CleanupRuntimeInstall(manager: manager, tool: identity.tool, version: identity.version, url: url, removal: removal)
    }

    // MARK: Aliases

    /// The links in `~/.pyenv/versions` whose physical path lies inside a pyenv install: a pin
    /// naming one names that install. A link that does not resolve, or resolves elsewhere, is none.
    func aliases() -> [CleanupRuntimeAlias] {
        let installRoots = pyenvInstalls().flatMap { install -> [[String]] in
            var roots = [CleanupPathText.components(of: install.url.path)]
            if let real = try? fileSystem.realpath(install.url) { roots.append(CleanupPathText.components(of: real.path)) }
            return roots
        }
        return links(in: path(".pyenv/versions")).compactMap { link in
            guard let name = CleanupPathText.components(of: link.url.path).last,
                  let target = try? fileSystem.realpath(link.url) else { return nil }
            let components = CleanupPathText.components(of: target.path)
            guard installRoots.contains(where: { components.starts(with: $0) }) else { return nil }
            return CleanupRuntimeAlias(tool: "python", name: name, target: target)
        }
    }

    // MARK: Defaults

    /// A default that cannot be read must not make the active runtime look unused: every tool the
    /// manager has installed gets an `unresolvable` requirement instead, so the newest stays kept.
    public func defaults() -> [CleanupRequirement] {
        let all = installs()
        func tools(_ manager: CleanupVersionManager) -> [String] {
            Array(Set(all.filter { $0.manager == manager }.map(\.tool))).sorted()
        }
        return uvDefaults(tools: tools(.uv))
            + fileDefaults(file(".pyenv/version"), .pythonVersion, tools: tools(.pyenv))
            + fnmDefaults(tools: tools(.fnm))
            + fileDefaults(file(".nvm/alias/default"), .nvmrc, tools: tools(.nvm))
            + sdkmanDefaults(tools: tools(.sdkman))
            + rustupDefaults(tools: tools(.rustup))
            + fileDefaults(file(".config/mise/config.toml"), .miseToml, tools: tools(.mise))
            + fileDefaults(file(".tool-versions"), .toolVersions, tools: tools(.asdf))
            + voltaDefaults(tools: tools(.volta))
            + pnpmDefaults(tools: tools(.pnpmEnv))
    }

    private enum Lookup<Value> {
        case absent
        case found(Value)
        case failed
    }

    /// Nothing there (nil or `.notFound`) is `absent`; any other error is `failed`.
    private func lookup<Value>(_ body: () throws -> Value?) -> Lookup<Value> {
        do {
            guard let value = try body() else { return .absent }
            return .found(value)
        } catch CleanupFileSystemError.notFound {
            return .absent
        } catch {
            return .failed
        }
    }

    private func unreadable(_ url: URL, tools: [String]) -> [CleanupRequirement] {
        tools.map { CleanupRequirement(tool: $0, spec: .unresolvable(url.lastPathComponent), source: url) }
    }

    private func uvDefaults(tools: [String]) -> [CleanupRequirement] {
        let installs = directories(uvPythonRoot).flatMap { install -> [[String]] in
            var roots = [CleanupPathText.components(of: install.url.path)]
            if let real = try? fileSystem.realpath(install.url) { roots.append(CleanupPathText.components(of: real.path)) }
            return roots
        }
        let isPython: (CleanupEntry) -> Bool = { $0.url.lastPathComponent.hasPrefix("python") }
        return linkDefaults(in: path(".local/bin"), tools: tools, matching: isPython, transform: { link in
            switch lookup({ try fileSystem.realpath(link.url) }) {
            case .absent: return []
            case .failed: return unreadable(link.url, tools: tools)
            case .found(let resolved):
                let target = CleanupPathText.components(of: resolved.path)
                guard installs.contains(where: { target.starts(with: $0) }) else { return [] }
                return [CleanupRequirement(tool: "python", spec: .path(resolved.path), source: link.url)]
            }
        })
    }

    private func fnmDefaults(tools: [String]) -> [CleanupRequirement] {
        fnmRoots.flatMap { root in
            let aliases = root.appending(path: "aliases", directoryHint: .isDirectory)
            return linkDefaults(in: aliases, tools: tools, matching: { _ in true }, transform: {
                linkRequirement($0, tool: "node", tools: tools)
            })
        }
    }

    private func sdkmanDefaults(tools: [String]) -> [CleanupRequirement] {
        directories(path(".sdkman/candidates")).flatMap { candidate -> [CleanupRequirement] in
            let link = candidate.url.appending(component: "current", directoryHint: .notDirectory)
            switch lookup({ try fileSystem.entry(at: link) }) {
            case .absent: return []
            case .failed: return unreadable(link, tools: tools)
            case .found(let entry):
                guard entry.kind == .symlink else { return [] }
                return linkRequirement(entry, tool: candidate.url.lastPathComponent, tools: tools)
            }
        }
    }

    private func rustupDefaults(tools: [String]) -> [CleanupRequirement] {
        let url = file(".rustup/settings.toml")
        return withText(at: url, tools: tools) { text in
            Self.rustupToolchains(in: text).map { CleanupRequirement(tool: "rust", spec: .pin($0), source: url) }
        }
    }

    private static func rustupToolchains(in text: String) -> [String] {
        var section = ""
        var result: [String] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = stripComment(String(raw)).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { section = line.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")); continue }
            guard let equals = line.lastIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: equals)...].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            guard !value.isEmpty, (section.isEmpty && key == "default_toolchain") || section == "overrides" else { continue }
            result.append(value)
        }
        return result
    }

    /// Cuts at the first `#` outside a quoted string.
    private static func stripComment(_ line: String) -> String {
        var quote: Character?
        var result = ""
        for character in line {
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "#" {
                break
            }
            result.append(character)
        }
        return result
    }

    private func voltaDefaults(tools: [String]) -> [CleanupRequirement] {
        let url = file(".volta/tools/user/platform.json")
        guard case .found = lookup({ try fileSystem.entry(at: url) }) else {
            return lookupFailed(url) ? unreadable(url, tools: tools) : []
        }
        let parsed: [CleanupRequirement]? = (try? fileSystem.readText(url, maxBytes: Self.maxSettingsBytes)).flatMap { text in
            guard let root = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  let node = root["node"] as? [String: Any], let runtime = node["runtime"] as? String, !runtime.isEmpty
            else { return nil }
            return [CleanupRequirement(tool: "node", spec: .pin(runtime), source: url)]
        }
        return parsed ?? unreadable(url, tools: tools)
    }

    private func lookupFailed(_ url: URL) -> Bool {
        if case .failed = lookup({ try fileSystem.entry(at: url) }) { return true }
        return false
    }

    private func pnpmDefaults(tools: [String]) -> [CleanupRequirement] {
        let link = file("Library/pnpm/nodejs_current")
        switch lookup({ try fileSystem.entry(at: link) }) {
        case .absent:
            return pnpmNodeRoot.isEmpty ? [] : [CleanupRequirement(tool: "node", spec: .unresolvable("nodejs_current"), source: link)]
        case .failed:
            return unreadable(link, tools: tools)
        case .found(let entry):
            return linkRequirement(entry, tool: "node", tools: tools)
        }
    }

    /// A requirement from the settings file the Task 5 parser already understands.
    private func fileDefaults(_ url: URL, _ kind: CleanupProjectFileKind, tools: [String]) -> [CleanupRequirement] {
        withText(at: url, tools: tools) { text in
            CleanupRequirementParser.requirements(in: CleanupProjectFile(url: url, kind: kind, text: text))
        }
    }

    private func withText(
        at url: URL, tools: [String], _ parse: (String) -> [CleanupRequirement]
    ) -> [CleanupRequirement] {
        switch lookup({ try fileSystem.entry(at: url) }) {
        case .absent: return []
        case .failed: return unreadable(url, tools: tools)
        case .found:
            switch lookup({ try fileSystem.readText(url, maxBytes: Self.maxSettingsBytes) }) {
            case .absent: return []
            case .failed: return unreadable(url, tools: tools)
            case .found(let text): return parse(text)
            }
        }
    }

    private func linkRequirement(_ link: CleanupEntry, tool: String, tools: [String]) -> [CleanupRequirement] {
        switch lookup({ try fileSystem.realpath(link.url) }) {
        case .absent: return []
        case .failed: return unreadable(link.url, tools: tools)
        case .found(let resolved): return [CleanupRequirement(tool: tool, spec: .path(resolved.path), source: link.url)]
        }
    }

    /// Maps each symlink directly inside `directory`; a listing that fails for a reason other than
    /// "not there" reports the manager's tools as unresolvable.
    private func linkDefaults(
        in directory: URL, tools: [String], matching: (CleanupEntry) -> Bool,
        transform: (CleanupEntry) -> [CleanupRequirement]
    ) -> [CleanupRequirement] {
        switch lookup({ try fileSystem.contents(of: directory) }) {
        case .absent: return []
        case .failed: return unreadable(directory, tools: tools)
        case .found(let children):
            return children.filter { !$0.url.lastPathComponent.hasPrefix(".") && $0.kind == .symlink && matching($0) }
                .flatMap(transform)
        }
    }

    // MARK: Plumbing

    private var uvPythonRoot: URL { path(".local/share/uv/python") }

    private var fnmRoots: [URL] { [path(".local/share/fnm"), path(".fnm")] }

    private func file(_ relative: String) -> URL {
        home.appending(path: relative, directoryHint: .notDirectory)
    }

    private func path(_ relative: String) -> URL {
        home.appending(path: relative, directoryHint: .isDirectory)
    }

    private func entries(in directory: URL) -> [CleanupEntry] {
        ((try? fileSystem.contents(of: directory)) ?? []).filter { !$0.url.lastPathComponent.hasPrefix(".") }
    }

    private func directories(_ directory: URL) -> [CleanupEntry] {
        entries(in: directory).filter { $0.kind == .directory }
    }

    private func links(in directory: URL) -> [CleanupEntry] {
        entries(in: directory).filter { $0.kind == .symlink }
    }

    private static func strippingV(_ name: String) -> String? {
        name.hasPrefix("v") && name.count > 1 ? String(name.dropFirst()) : nil
    }

    private static func normalisedTool(_ name: String) -> String {
        let lowered = name.lowercased()
        return lowered == "nodejs" ? "node" : lowered
    }
}
