import Foundation

public enum MasServiceError: Error, Equatable, LocalizedError {
    case masNotFound
    case commandFailed(arguments: [String], result: ProcessResult)

    public var errorDescription: String? {
        switch self {
        case .masNotFound:
            return "mas was not found at /opt/homebrew/bin/mas or /usr/local/bin/mas."
        case .commandFailed(let arguments, let result):
            return "mas \(arguments.joined(separator: " ")) failed with exit code \(result.exitCode): \(result.stderr)"
        }
    }
}

public final class MasService: @unchecked Sendable {
    private let locator: BinaryLocator
    private let runner: ProcessRunning
    private let parser: MasOutdatedParser
    private let listParser: MasListParser
    private let searchParser: MasSearchParser

    public init(
        locator: BinaryLocator = BinaryLocator(),
        runner: ProcessRunning = ProcessRunner(),
        parser: MasOutdatedParser = MasOutdatedParser(),
        listParser: MasListParser = MasListParser(),
        searchParser: MasSearchParser = MasSearchParser()
    ) {
        self.locator = locator
        self.runner = runner
        self.parser = parser
        self.listParser = listParser
        self.searchParser = searchParser
    }

    public func outdated() async throws -> [MasOutdatedApp] {
        let arguments = ["outdated"]
        let result = try await runMas(arguments)
        try ensureSuccess(result, arguments: arguments)
        return parser.parse(result.stdout)
    }

    public func upgrade() async throws -> ProcessResult {
        let arguments = ["upgrade"]
        let first = try await runMas(arguments)
        if first.exitCode == 0 {
            return first
        }
        // `mas upgrade` shells out to `sudo softwareupdate …` for Safari
        // extensions and similar MAS items, using `/usr/bin/sudo` directly —
        // which bypasses our PATH shim and fails on a missing TTY. Recover
        // by priming the no-tty sudo timestamp via `sudo -A -v` (askpass
        // renders the password dialog) and retrying once.
        guard Self.outputIndicatesMissingSudoTTY(first) else {
            try ensureSuccess(first, arguments: arguments)
            return first
        }
        try await prewarmSudoTimestamp()
        let retry = try await runMas(arguments)
        try ensureSuccess(retry, arguments: arguments)
        return retry
    }

    /// True when mas's stderr contains the canonical sudo "no terminal /
    /// password required" signature. Matched on raw substrings rather than
    /// regex to stay robust against minor wording shifts between sudo
    /// versions on different macOS releases.
    static func outputIndicatesMissingSudoTTY(_ result: ProcessResult) -> Bool {
        let blob = result.stderr + "\n" + result.stdout
        return blob.contains("sudo: a terminal is required to read the password")
            || blob.contains("sudo: a password is required")
    }

    private func prewarmSudoTimestamp() async throws {
        // Use the absolute path on purpose: this is exactly the `sudo` that
        // mas will invoke internally, so the timestamp it caches is the one
        // mas will look up. Going through the PATH shim here would cache a
        // different ticket (the shim re-execs sudo as a child process).
        //
        // `-A` vs no `-A`: with Touch ID wired into sudo_local, `-A` would
        // make sudo skip pam_tid.so entirely and pop the askpass *password*
        // dialog instead of the biometric sheet. Dropping `-A` lets PAM run
        // normally — pam_tid shows the Touch ID prompt, succeeds, timestamp
        // cached. Without Touch ID, askpass remains the only viable path.
        let sudoURL = URL(fileURLWithPath: "/usr/bin/sudo")
        let touchIDEnabled = (HomebrewEnvironment.touchIDStateOverride
                              ?? TouchIDSudoConfigurator.currentState()) == .enabled
        let args = touchIDEnabled ? ["-v"] : ["-A", "-v"]
        _ = try await runner.run(
            ProcessRequest(
                executableURL: sudoURL,
                arguments: args,
                environment: HomebrewEnvironment.environment,
                timeout: 120
            )
        )
    }

    public func list() async throws -> [MasInstalledApp] {
        let arguments = ["list"]
        let result = try await runMas(arguments)
        try ensureSuccess(result, arguments: arguments)
        return listParser.parse(result.stdout)
    }

    public func search(name: String) async throws -> String? {
        guard let masURL = locator.locateMas() else {
            throw MasServiceError.masNotFound
        }
        let arguments = ["search", name]
        let result = try await runner.run(
            ProcessRequest(
                executableURL: masURL,
                arguments: arguments,
                environment: HomebrewEnvironment.environment,
                timeout: 15
            )
        )
        // mas search exits 1 when no results — treat as empty, not an error
        if result.exitCode == 1 { return nil }
        guard result.exitCode == 0 else {
            throw MasServiceError.commandFailed(arguments: arguments, result: result)
        }
        let normalizedQuery = StringNormalizer.normalize(name)
        return searchParser.parse(result.stdout)
            .first { StringNormalizer.normalize($0.name) == normalizedQuery }?
            .appStoreID
    }

    private func runMas(_ arguments: [String]) async throws -> ProcessResult {
        guard let masURL = locator.locateMas() else {
            throw MasServiceError.masNotFound
        }

        return try await runner.run(
            ProcessRequest(
                executableURL: masURL,
                arguments: arguments,
                environment: HomebrewEnvironment.environment,
                timeout: nil
            )
        )
    }

    private func ensureSuccess(_ result: ProcessResult, arguments: [String]) throws {
        guard result.exitCode == 0 else {
            throw MasServiceError.commandFailed(arguments: arguments, result: result)
        }
    }
}
