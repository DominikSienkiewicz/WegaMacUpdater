import MacUpdaterCore

protocol BackgroundUpdateConsentMetadataProviding: Sendable {
    func caskArtifactProfiles(tokens: [String]) async throws -> [CaskArtifactProfile]
    func caskDownloadInfo(tokens: [String]) async throws -> [CaskDownloadInfo]
    func outdatedGreedy() async throws -> BrewOutdated
    func caskInstallationInfo(tokens: [String]) async throws -> [BrewCaskInstallationInfo]
    /// ARCH-04: wszystkie trzy widoki z jednego przebiegu `brew info`.
    func caskInfo(tokens: [String]) async throws -> BrewCaskInfo
}

extension BackgroundUpdateConsentMetadataProviding {
    /// Domyślna implementacja dla atrap w testach: składa widoki z trzech osobnych zapytań.
    /// `BrewService` nadpisuje ją jednym przebiegiem — to właśnie jest sedno ARCH-04.
    func caskInfo(tokens: [String]) async throws -> BrewCaskInfo {
        async let profiles = caskArtifactProfiles(tokens: tokens)
        async let downloads = caskDownloadInfo(tokens: tokens)
        async let installations = caskInstallationInfo(tokens: tokens)
        return try await BrewCaskInfo(profiles: profiles, downloads: downloads, installations: installations)
    }
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
        // ARCH-04: jedno zapytanie o cask info zamiast trzech identycznych. `outdatedGreedy`
        // to inna komenda brew i zostaje osobno — nadal równolegle.
        async let infoRequest = provider.caskInfo(tokens: tokens)
        async let outdatedRequest = provider.outdatedGreedy()
        let info = try await infoRequest
        return try await BackgroundUpdateConsentMetadata(
            profiles: info.profiles,
            downloads: info.downloads,
            outdated: outdatedRequest,
            installations: info.installations
        )
    }
}
