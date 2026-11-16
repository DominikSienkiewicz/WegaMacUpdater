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

    // MARK: Defaults

    public func defaults() -> [CleanupRequirement] {
        uvDefaults() + fileDefaults(file(".pyenv/version"), .pythonVersion, tool: "python")
            + fnmDefaults() + fileDefaults(file(".nvm/alias/default"), .nvmrc, tool: "node")
            + sdkmanDefaults() + rustupDefaults()
            + fileDefaults(file(".config/mise/config.toml"), .miseToml, tool: "mise")
            + fileDefaults(file(".tool-versions"), .toolVersions, tool: "asdf")
            + voltaDefaults() + pnpmDefaults()
    }

    private func uvDefaults() -> [CleanupRequirement] {
        let installs = directories(uvPythonRoot).map { CleanupPathText.components(of: $0.url.path) }
        return links(in: path(".local/bin")).filter { $0.url.lastPathComponent.hasPrefix("python") }.compactMap { link in
            guard let resolved = try? fileSystem.realpath(link.url) else { return nil }
            let target = CleanupPathText.components(of: resolved.path)
            guard installs.contains(where: { target.starts(with: $0) }) else { return nil }
            return CleanupRequirement(tool: "python", spec: .path(resolved.path), source: link.url)
        }
    }

    private func fnmDefaults() -> [CleanupRequirement] {
        fnmRoots.flatMap { root in
            links(in: root.appending(path: "aliases", directoryHint: .isDirectory)).compactMap {
                linkRequirement($0, tool: "node")
            }
        }
    }

    private func sdkmanDefaults() -> [CleanupRequirement] {
        directories(path(".sdkman/candidates")).compactMap { candidate in
            let link = candidate.url.appending(component: "current", directoryHint: .notDirectory)
            guard let entry = try? fileSystem.entry(at: link), entry.kind == .symlink else { return nil }
            return linkRequirement(entry, tool: candidate.url.lastPathComponent)
        }
    }

    private func rustupDefaults() -> [CleanupRequirement] {
        let url = file(".rustup/settings.toml")
        guard (try? fileSystem.entry(at: url)) != nil else { return [] }
        guard let text = try? fileSystem.readText(url, maxBytes: Self.maxSettingsBytes) else {
            return [CleanupRequirement(tool: "rust", spec: .unresolvable("settings.toml"), source: url)]
        }
        return Self.rustupToolchains(in: text).map { CleanupRequirement(tool: "rust", spec: .pin($0), source: url) }
    }

    private static func rustupToolchains(in text: String) -> [String] {
        var section = ""
        var result: [String] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { section = line.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")); continue }
            guard let equals = line.lastIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: equals)...].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            guard !value.isEmpty, (section.isEmpty && key == "default_toolchain") || section == "overrides" else { continue }
            result.append(value)
        }
        return result
    }

    private func voltaDefaults() -> [CleanupRequirement] {
        let url = file(".volta/tools/user/platform.json")
        guard (try? fileSystem.entry(at: url)) != nil else { return [] }
        let unresolvable = [CleanupRequirement(tool: "node", spec: .unresolvable("platform.json"), source: url)]
        guard let text = try? fileSystem.readText(url, maxBytes: Self.maxSettingsBytes),
              let root = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let node = root["node"] as? [String: Any], let runtime = node["runtime"] as? String, !runtime.isEmpty
        else { return unresolvable }
        return [CleanupRequirement(tool: "node", spec: .pin(runtime), source: url)]
    }

    private func pnpmDefaults() -> [CleanupRequirement] {
        let link = file("Library/pnpm/nodejs_current")
        guard let entry = try? fileSystem.entry(at: link) else {
            return pnpmNodeRoot.isEmpty ? [] : [CleanupRequirement(tool: "node", spec: .unresolvable("nodejs_current"), source: link)]
        }
        return linkRequirement(entry, tool: "node").map { [$0] } ?? []
    }

    /// A requirement from the settings file the Task 5 parser already understands.
    private func fileDefaults(_ url: URL, _ kind: CleanupProjectFileKind, tool: String) -> [CleanupRequirement] {
        guard (try? fileSystem.entry(at: url)) != nil else { return [] }
        guard let text = try? fileSystem.readText(url, maxBytes: Self.maxSettingsBytes) else {
            return [CleanupRequirement(tool: tool, spec: .unresolvable(url.lastPathComponent), source: url)]
        }
        return CleanupRequirementParser.requirements(in: CleanupProjectFile(url: url, kind: kind, text: text))
    }

    private func linkRequirement(_ link: CleanupEntry, tool: String) -> CleanupRequirement? {
        guard let resolved = try? fileSystem.realpath(link.url) else { return nil }
        return CleanupRequirement(tool: tool, spec: .path(resolved.path), source: link.url)
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
