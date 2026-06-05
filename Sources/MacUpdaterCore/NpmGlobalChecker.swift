import Foundation

public struct NpmGlobalPackage: Equatable, Sendable {
    public var name: String
    public var installedVersion: String

    public init(name: String, installedVersion: String) {
        self.name = name
        self.installedVersion = installedVersion
    }
}

public struct NpmGlobalOutdated: Equatable, Sendable {
    public var name: String
    public var installedVersion: String
    public var latestVersion: String

    public init(name: String, installedVersion: String, latestVersion: String) {
        self.name = name
        self.installedVersion = installedVersion
        self.latestVersion = latestVersion
    }
}

public enum NpmServiceError: Error, LocalizedError {
    case npmNotFound
    case commandFailed(arguments: [String], result: ProcessResult)

    public var errorDescription: String? {
        switch self {
        case .npmNotFound:
            return "npm was not found in any of the expected locations or in the user's login shell."
        case .commandFailed(let arguments, let result):
            return "npm \(arguments.joined(separator: " ")) failed with exit code \(result.exitCode): \(result.stderr)"
        }
    }
}

public struct NpmListParser {
    public init() { /* stateless; explicit so the initializer is public across the module boundary */ }

    public func parse(_ data: Data) throws -> [NpmGlobalPackage] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let deps = json["dependencies"] as? [String: Any] else { return [] }

        var out: [NpmGlobalPackage] = []
        for (name, raw) in deps {
            // npm itself is upgraded via brew/installer, not user-actionable here.
            if name == "npm" || name == "corepack" { continue }
            guard let entry = raw as? [String: Any],
                  let version = entry["version"] as? String,
                  !version.isEmpty else { continue }
            out.append(NpmGlobalPackage(name: name, installedVersion: version))
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func parse(_ json: String) throws -> [NpmGlobalPackage] {
        try parse(Data(json.utf8))
    }
}

public final class NpmLocator: @unchecked Sendable {
    private let fileManager: FileManager
    private let extraCandidates: [URL]

    public init(fileManager: FileManager = .default, extraCandidates: [URL] = []) {
        self.fileManager = fileManager
        self.extraCandidates = extraCandidates
    }

    public func locate() -> URL? {
        for url in candidates() where fileManager.isExecutableFile(atPath: url.path) {
            return url
        }
        return resolveFromLoginShell()
    }

    private func candidates() -> [URL] {
        let home = fileManager.homeDirectoryForCurrentUser
        var urls: [URL] = SystemPaths.npmCandidates + [
            home.appendingPathComponent(".volta/bin/npm")
        ]
        urls.append(contentsOf: extraCandidates)
        urls.append(contentsOf: glob(home.appendingPathComponent(".local/share/fnm/node-versions"), suffix: "installation/bin/npm"))
        urls.append(contentsOf: glob(home.appendingPathComponent(".fnm/node-versions"),            suffix: "installation/bin/npm"))
        urls.append(contentsOf: glob(home.appendingPathComponent(".nvm/versions/node"),             suffix: "bin/npm"))
        return urls
    }

    /// Returns the newest matching binary inside `root/<version>/<suffix>`, sorted by version-name descending.
    private func glob(_ root: URL, suffix: String) -> [URL] {
        guard let entries = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        return entries
            .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
            .map { $0.appendingPathComponent(suffix) }
    }

    private func resolveFromLoginShell() -> URL? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? SystemPaths.defaultLoginShell
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lc", "command -v npm"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, fileManager.isExecutableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }
}

public final class NpmGlobalService: @unchecked Sendable {
    private let locator: NpmLocator
    private let runner: ProcessRunning
    private let listParser: NpmListParser

    public init(
        locator: NpmLocator = NpmLocator(),
        runner: ProcessRunning = ProcessRunner(),
        listParser: NpmListParser = NpmListParser()
    ) {
        self.locator = locator
        self.runner = runner
        self.listParser = listParser
    }

    public func installedGlobals() async throws -> [NpmGlobalPackage] {
        let arguments = ["ls", "-g", "--json", "--depth=0"]
        let result = try await runNpm(arguments)
        // npm sometimes returns non-zero with extraneous peer-dep warnings while still emitting valid JSON.
        guard let data = result.stdout.data(using: .utf8) else { return [] }
        return (try? listParser.parse(data)) ?? []
    }

    public func latestVersion(of name: String) async throws -> String? {
        let arguments = ["view", name, "version"]
        let result = try await runNpm(arguments)
        guard result.exitCode == 0 else { return nil }
        let version = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return version.isEmpty ? nil : version
    }

    public func outdated() async throws -> [NpmGlobalOutdated] {
        let installed = try await installedGlobals()
        return await withTaskGroup(of: NpmGlobalOutdated?.self) { group in
            for pkg in installed {
                group.addTask {
                    guard let latest = try? await self.latestVersion(of: pkg.name) else { return nil }
                    guard !versionsEqual(latest, pkg.installedVersion),
                          isUpgrade(installed: pkg.installedVersion, latest: latest) else { return nil }
                    return NpmGlobalOutdated(
                        name: pkg.name,
                        installedVersion: pkg.installedVersion,
                        latestVersion: latest
                    )
                }
            }
            var collected: [NpmGlobalOutdated] = []
            for await item in group {
                if let item { collected.append(item) }
            }
            return collected.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    public func upgradeEvents(name: String) throws -> AsyncThrowingStream<ProcessOutputEvent, Error> {
        guard let npmURL = locator.locate() else {
            throw NpmServiceError.npmNotFound
        }
        return runner.events(
            for: ProcessRequest(
                executableURL: npmURL,
                arguments: ["install", "-g", "\(name)@latest"],
                environment: environment(for: npmURL),
                timeout: nil
            )
        )
    }

    public func uninstallEvents(name: String) throws -> AsyncThrowingStream<ProcessOutputEvent, Error> {
        guard let npmURL = locator.locate() else {
            throw NpmServiceError.npmNotFound
        }
        return runner.events(
            for: ProcessRequest(
                executableURL: npmURL,
                arguments: Self.uninstallArguments(for: name),
                environment: environment(for: npmURL),
                timeout: nil
            )
        )
    }

    public static func uninstallArguments(for name: String) -> [String] {
        ["uninstall", "-g", name]
    }

    private func runNpm(_ arguments: [String]) async throws -> ProcessResult {
        guard let npmURL = locator.locate() else {
            throw NpmServiceError.npmNotFound
        }
        return try await runner.run(
            ProcessRequest(
                executableURL: npmURL,
                arguments: arguments,
                environment: environment(for: npmURL),
                timeout: 30
            )
        )
    }

    /// npm needs `node` on PATH; prepend the directory containing npm so the
    /// matching node binary (from the same toolchain) is discovered.
    private func environment(for npmURL: URL) -> [String: String] {
        let npmDir = npmURL.deletingLastPathComponent().path
        let path = "\(npmDir):\(HomebrewEnvironment.processPath)"
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = path
        return env
    }
}
