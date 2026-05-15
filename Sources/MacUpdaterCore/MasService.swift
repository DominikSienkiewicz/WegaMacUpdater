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
        let result = try await runMas(arguments)
        try ensureSuccess(result, arguments: arguments)
        return result
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
