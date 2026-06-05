import Foundation

public struct ToolchainLocations: Equatable, Sendable {
    public var brew: URL?
    public var mas: URL?

    public init(brew: URL?, mas: URL?) {
        self.brew = brew
        self.mas = mas
    }
}

public struct BinaryLocator {
    public static let defaultBrewCandidates = SystemPaths.brewCandidates

    public static let defaultMasCandidates = SystemPaths.masCandidates

    private let fileManager: FileManager
    private let brewCandidates: [URL]
    private let masCandidates: [URL]

    public init(
        fileManager: FileManager = .default,
        brewCandidates: [URL] = Self.defaultBrewCandidates,
        masCandidates: [URL] = Self.defaultMasCandidates
    ) {
        self.fileManager = fileManager
        self.brewCandidates = brewCandidates
        self.masCandidates = masCandidates
    }

    public func locateBrew() -> URL? {
        firstExecutable(in: brewCandidates)
    }

    public func locateMas() -> URL? {
        firstExecutable(in: masCandidates)
    }

    public func locateToolchain() -> ToolchainLocations {
        ToolchainLocations(brew: locateBrew(), mas: locateMas())
    }

    private func firstExecutable(in candidates: [URL]) -> URL? {
        candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }
}
