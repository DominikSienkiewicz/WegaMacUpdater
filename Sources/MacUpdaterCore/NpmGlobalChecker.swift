import Foundation
import WegaHelperKit

public struct NpmGlobalPackage: Equatable, Sendable {
    public var name: String
    public var installedVersion: String

    public init(name: String, installedVersion: String) {
        self.name = name
        self.installedVersion = installedVersion
    }
}

public struct NpmGlobalOutdated: Codable, Equatable, Sendable {
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

/// Parses the map emitted by `npm outdated -g --json` into the outdated globals worth
/// surfacing. Keys are package names; each value carries `current`/`wanted`/`latest`.
/// `npm` and `corepack` are dropped (upgraded via brew/installer, not user-actionable),
/// as are entries without a concrete installed **and** latest version. npm's
/// "nothing outdated" payload (`{}`) yields an empty list.
public struct NpmOutdatedParser {
    public init() { /* stateless; explicit so the initializer is public across the module boundary */ }

    public func parse(_ data: Data) throws -> [NpmGlobalOutdated] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return parse(object)
    }

    public func parse(_ object: [String: Any]) -> [NpmGlobalOutdated] {
        var out: [NpmGlobalOutdated] = []
        for (name, raw) in object {
            // npm itself is upgraded via brew/installer, not user-actionable here.
            if name == "npm" || name == "corepack" { continue }
            guard let entry = raw as? [String: Any],
                  let current = entry["current"] as? String,
                  let latest = entry["latest"] as? String,
                  !current.isEmpty, !latest.isEmpty,
                  // npm marks a declared-but-uninstalled global as "MISSING": not an installed version.
                  current != "MISSING" else { continue }
            // REL-11: npm publishes strict SemVer, so compare under `.semver`
            // (prerelease ranks below its release; unparseable ⇒ not an upgrade).
            guard isUpgrade(installed: current, latest: latest, scheme: .semver) else { continue }
            out.append(NpmGlobalOutdated(name: name, installedVersion: current, latestVersion: latest))
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func parse(_ json: String) throws -> [NpmGlobalOutdated] {
        try parse(Data(json.utf8))
    }
}

public final class NpmLocator: @unchecked Sendable {
    private let fileManager: FileManager
    private let extraCandidates: [URL]
    private let cacheLock = NSLock()
    private var cachedURL: URL?

    public init(fileManager: FileManager = .default, extraCandidates: [URL] = []) {
        self.fileManager = fileManager
        self.extraCandidates = extraCandidates
    }

    /// ARCH-03: resolve npm once and reuse it. A scan calls `locate()` for every npm
    /// operation; without a cache each call re-ran the nvm/fnm directory globs and
    /// spawned a login shell (`$SHELL -lc "command -v npm"`) from scratch. Only a
    /// positive result is memoised — so an npm installed later is still discovered —
    /// and the cached path is re-validated as executable on each hit, so a moved or
    /// removed binary forces a fresh resolve rather than returning a stale location.
    public func locate() -> URL? {
        if let cached = validatedCachedURL() { return cached }
        let resolved = resolveUncached()
        cache(resolved)
        return resolved
    }

    private func validatedCachedURL() -> URL? {
        cacheLock.lock()
        let cached = cachedURL
        cacheLock.unlock()
        guard let cached else { return nil }
        if fileManager.isExecutableFile(atPath: cached.path) { return cached }
        cacheLock.lock()
        cachedURL = nil
        cacheLock.unlock()
        return nil
    }

    private func cache(_ url: URL?) {
        guard let url else { return }
        cacheLock.lock()
        cachedURL = url
        cacheLock.unlock()
    }

    private func resolveUncached() -> URL? {
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
    private let outdatedParser: NpmOutdatedParser

    public init(
        locator: NpmLocator = NpmLocator(),
        runner: ProcessRunning = ProcessRunner(),
        listParser: NpmListParser = NpmListParser(),
        outdatedParser: NpmOutdatedParser = NpmOutdatedParser()
    ) {
        self.locator = locator
        self.runner = runner
        self.listParser = listParser
        self.outdatedParser = outdatedParser
    }

    public func installedGlobals() async throws -> [NpmGlobalPackage] {
        let arguments = ["ls", "-g", "--json", "--depth=0"]
        let result = try await runNpm(arguments)
        // npm sometimes returns non-zero with extraneous peer-dep warnings while still emitting valid JSON.
        guard let data = result.stdout.data(using: .utf8) else { return [] }
        return (try? listParser.parse(data)) ?? []
    }

    public func outdated() async throws -> [NpmGlobalOutdated] {
        // ARCH-03: one `npm outdated -g --json` process replaces the per-package
        // `npm view` fan-out (one unbounded Node process per installed global).
        // `npm outdated` exits non-zero (1) simply *because* packages are outdated,
        // so the exit code alone cannot flag failure — the JSON body decides.
        let arguments = ["outdated", "-g", "--json"]
        let result = try await runNpm(arguments)
        guard let object = Self.jsonObject(from: result.stdout) else {
            // No parseable JSON. Exit 0 is npm's "nothing outdated / empty output";
            // any other exit means npm failed without emitting a usable report — surface
            // it as an error rather than reporting a falsely-successful empty scan.
            if result.exitCode == 0 { return [] }
            throw NpmServiceError.commandFailed(arguments: arguments, result: result)
        }
        // ARCH-03: npm reports registry/network trouble as `{"error": {...}}`. Treat it
        // as a (possibly partial) failure and signal an incomplete scan instead of
        // swallowing it into an empty — or truncated — list of upgrades.
        if Self.isNpmError(object) {
            throw NpmServiceError.commandFailed(arguments: arguments, result: result)
        }
        return outdatedParser.parse(object)
    }

    /// The JSON object npm printed to stdout, or `nil` when stdout was empty or not a
    /// JSON object (npm printed a bare error line, or nothing at all).
    private static func jsonObject(from stdout: String) -> [String: Any]? {
        let data = Data(stdout.utf8)
        guard !data.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// npm surfaces a failed run as a top-level `error` object (`code`/`summary`/`detail`).
    /// A package literally named "error" instead carries version fields, so the shape —
    /// not merely the key — is what tells the two apart.
    private static func isNpmError(_ object: [String: Any]) -> Bool {
        guard let error = object["error"] as? [String: Any] else { return false }
        return error["current"] == nil && error["latest"] == nil
    }

    public func upgradeEvents(name: String) throws -> AsyncThrowingStream<ProcessOutputEvent, Error> {
        guard let npmURL = locator.locate() else {
            throw NpmServiceError.npmNotFound
        }
        return runner.events(
            for: ProcessRequest(
                executableURL: npmURL,
                // SEC-10: `--` fences the package name off from npm option parsing.
                arguments: ["install", "-g", "--", "\(name)@latest"],
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
        // SEC-10: `--` fences the package name off from npm option parsing.
        ["uninstall", "-g", "--", name]
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
