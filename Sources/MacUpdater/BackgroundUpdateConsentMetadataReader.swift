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
    private let operations: OperationCoordinator

    init(
        provider: any BackgroundUpdateConsentMetadataProviding = BrewService(),
        operations: OperationCoordinator = .shared
    ) {
        self.provider = provider
        self.operations = operations
    }

    func read(tokens: [String]) async throws -> BackgroundUpdateConsentMetadata {
        try await operations.withRead(label: "background consent metadata") {
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
}
