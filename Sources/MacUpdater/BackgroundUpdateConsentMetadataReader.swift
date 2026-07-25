import MacUpdaterCore

protocol BackgroundUpdateConsentMetadataProviding: Sendable {
    func caskArtifactProfiles(tokens: [String]) async throws -> [CaskArtifactProfile]
    func caskDownloadInfo(tokens: [String]) async throws -> [CaskDownloadInfo]
    func outdatedGreedy() async throws -> BrewOutdated
    func caskInstallationInfo(tokens: [String]) async throws -> [BrewCaskInstallationInfo]
}

extension BrewService: BackgroundUpdateConsentMetadataProviding {}

struct BackgroundUpdateConsentMetadata: Sendable {
    let profiles: [CaskArtifactProfile]
    let downloads: [CaskDownloadInfo]
    let outdated: BrewOutdated
    let installations: [BrewCaskInstallationInfo]
}

struct BackgroundUpdateConsentMetadataReader: Sendable {
    private let provider: any BackgroundUpdateConsentMetadataProviding
    private let operations: OperationCoordinator?

    init(
        provider: any BackgroundUpdateConsentMetadataProviding = BrewService(),
        operations: OperationCoordinator? = nil
    ) {
        self.provider = provider
        self.operations = operations
    }

    func read(tokens: [String]) async throws -> BackgroundUpdateConsentMetadata {
        if let operations {
            return try await read(tokens: tokens, using: operations)
        }
        return try await OperationCoordinator.shared.withRead(
            label: "background consent metadata"
        ) {
            try await load(tokens: tokens)
        }
    }

    private func read(
        tokens: [String],
        using operations: OperationCoordinator
    ) async throws -> BackgroundUpdateConsentMetadata {
        try await operations.withRead(label: "background consent metadata") {
            try await load(tokens: tokens)
        }
    }

    private func load(tokens: [String]) async throws -> BackgroundUpdateConsentMetadata {
        async let profileRequest = provider.caskArtifactProfiles(tokens: tokens)
        async let downloadRequest = provider.caskDownloadInfo(tokens: tokens)
        async let outdatedRequest = provider.outdatedGreedy()
        async let installationRequest = provider.caskInstallationInfo(tokens: tokens)
        return try await BackgroundUpdateConsentMetadata(
            profiles: profileRequest,
            downloads: downloadRequest,
            outdated: outdatedRequest,
            installations: installationRequest
        )
    }
}
