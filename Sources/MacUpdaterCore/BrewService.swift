import Foundation

public enum BrewServiceError: Error, Equatable, LocalizedError {
    case brewNotFound
    case commandFailed(arguments: [String], result: ProcessResult)

    public var errorDescription: String? {
        switch self {
        case .brewNotFound:
            return "Homebrew was not found at /opt/homebrew/bin/brew or /usr/local/bin/brew."
        case .commandFailed(let arguments, let result):
            return "brew \(arguments.joined(separator: " ")) failed with exit code \(result.exitCode): \(result.stderr)"
        }
    }
}

public final class BrewService: @unchecked Sendable {
    private let locator: BinaryLocator
    private let runner: ProcessRunning
    private let outdatedParser: BrewOutdatedParser
    private let infoParser: BrewInfoParser

    public init(
        locator: BinaryLocator = BinaryLocator(),
        runner: ProcessRunning = ProcessRunner(),
        outdatedParser: BrewOutdatedParser = BrewOutdatedParser(),
        infoParser: BrewInfoParser = BrewInfoParser()
    ) {
        self.locator = locator
        self.runner = runner
        self.outdatedParser = outdatedParser
        self.infoParser = infoParser
    }

    public func update() async throws -> ProcessResult {
        try await runBrew(["update"])
    }

    public func outdatedGreedy() async throws -> BrewOutdated {
        let result = try await runBrew(["outdated", "--json=v2", "--greedy", "--greedy-latest", "--greedy-auto-updates"])
        try ensureSuccess(result, arguments: ["outdated", "--json=v2", "--greedy", "--greedy-latest", "--greedy-auto-updates"])
        return try outdatedParser.parse(result.stdout)
    }

    public func installedCasks() async throws -> Set<String> {
        let result = try await runBrew(["list", "--cask", "-1"])
        try ensureSuccess(result, arguments: ["list", "--cask", "-1"])
        return Set(result.stdout.split(whereSeparator: \.isNewline).map(String.init))
    }

    public func caskVersions() async throws -> [String: String] {
        let result = try await runBrew(["list", "--cask", "--versions"])
        try ensureSuccess(result, arguments: ["list", "--cask", "--versions"])
        return result.stdout.split(whereSeparator: \.isNewline).reduce(into: [:]) { partial, line in
            let parts = line.split(separator: " ").map(String.init)
            guard let token = parts.first else { return }
            partial[token] = parts.dropFirst().last ?? ""
        }
    }

    public func caskInstallationInfo(tokens: [String]) async throws -> [BrewCaskInstallationInfo] {
        guard !tokens.isEmpty else { return [] }
        let arguments = ["info", "--cask", "--json=v2"] + tokens
        let result = try await runBrew(arguments)
        try ensureSuccess(result, arguments: arguments)
        return try infoParser.parseCaskInstallations(result.stdout)
    }

    /// DEBT-05: robust installed-cask versions via JSON (alternative to the
    /// text-parsed `caskVersions()`). Heavier (`--installed` enumerates everything),
    /// so the scanner keeps the fast text path by default; swap here if drift appears.
    public func caskInstalledVersions() async throws -> [String: String] {
        let arguments = ["info", "--installed", "--json=v2"]
        let result = try await runBrew(arguments)
        try ensureSuccess(result, arguments: arguments)
        return try infoParser.parseInstalledVersions(result.stdout)
    }

    /// FEAT-03: pre-install download transparency (host + checksum status) for casks.
    public func caskDownloadInfo(tokens: [String]) async throws -> [CaskDownloadInfo] {
        guard !tokens.isEmpty else { return [] }
        let arguments = ["info", "--cask", "--json=v2"] + tokens
        let result = try await runBrew(arguments)
        try ensureSuccess(result, arguments: arguments)
        return try infoParser.parseDownloadInfo(result.stdout)
    }

    public func upgradeCask(token: String, force: Bool = false) async throws -> ProcessResult {
        var arguments = ["upgrade", "--cask", "--greedy", "--greedy-auto-updates"]
        if force {
            arguments.append("--force")
        }
        arguments.append(token)
        let result = try await runBrew(arguments)
        try ensureSuccess(result, arguments: arguments)
        return result
    }

    public func uninstallCask(token: String, zap: Bool = false, force: Bool = false) async throws -> ProcessResult {
        var arguments = ["uninstall", "--cask"]
        if zap {
            arguments.append("--zap")
        }
        if force {
            arguments.append("--force")
        }
        arguments.append(token)
        let result = try await runBrew(arguments)
        try ensureSuccess(result, arguments: arguments)
        return result
    }

    public func upgradeFormulae() async throws -> ProcessResult {
        let arguments = ["upgrade", "--formula"]
        let result = try await runBrew(arguments)
        try ensureSuccess(result, arguments: arguments)
        return result
    }

    public func cleanup() async throws -> ProcessResult {
        let arguments = ["cleanup"]
        let result = try await runBrew(arguments)
        try ensureSuccess(result, arguments: arguments)
        return result
    }

    public func installCask(token: String) async throws -> ProcessResult {
        let arguments = ["install", "--cask", token]
        let result = try await runBrew(arguments)
        try ensureSuccess(result, arguments: arguments)
        return result
    }

    /// Arguments for the "Aktualizuj przez Brew" action — adopting/refreshing a
    /// self-updating cask whose `.app` is already on disk while its Caskroom is empty
    /// (Docker, etc.). A plain `install --cask` bails with "It seems there is already an
    /// App at '/Applications/…'" and then PURGES the cask's Caskroom record, leaving brew
    /// with no trace of an app that's still installed. `--force` overwrites the existing
    /// app and re-records it, so the action both updates and re-adopts in one step (the
    /// same `--force` the batch upgrade path falls back to on this exact error). Streamed
    /// via `events(arguments:)`, so the args live here to stay testable.
    public static func adoptCaskArguments(token: String) -> [String] {
        ["install", "--cask", "--force", token]
    }

    /// Returns the latest version string from the cask database for a given token, or nil on failure.
    public func caskLatestVersion(token: String) async -> String? {
        guard let result = try? await runBrew(["info", "--cask", "--json=v2", token]),
              result.exitCode == 0,
              let data = result.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let casks = json["casks"] as? [[String: Any]],
              let first = casks.first,
              let version = first["version"] as? String else { return nil }
        return version
    }

    public func events(arguments: [String]) throws -> AsyncThrowingStream<ProcessOutputEvent, Error> {
        guard let brewURL = locator.locateBrew() else {
            throw BrewServiceError.brewNotFound
        }
        return runner.events(
            for: ProcessRequest(
                executableURL: brewURL,
                arguments: arguments,
                environment: HomebrewEnvironment.environment,
                timeout: nil
            )
        )
    }

    private func runBrew(_ arguments: [String], timeout: TimeInterval? = nil) async throws -> ProcessResult {
        guard let brewURL = locator.locateBrew() else {
            throw BrewServiceError.brewNotFound
        }

        return try await runner.run(
            ProcessRequest(
                executableURL: brewURL,
                arguments: arguments,
                environment: HomebrewEnvironment.environment,
                timeout: timeout
            )
        )
    }

    private func ensureSuccess(_ result: ProcessResult, arguments: [String]) throws {
        guard result.exitCode == 0 else {
            throw BrewServiceError.commandFailed(arguments: arguments, result: result)
        }
    }
}
