import Foundation
import MacUpdaterCore

/// Live inputs for the pure `DownloadGate`, shared by window and unattended paths.
enum DownloadResourcePreflight {
    static func probe(
        tokens: [String],
        downloads: [String: CaskDownloadInfo]
    ) async -> [String: DownloadSizeProbeResult] {
        let probe = DownloadSizeProbe()
        var results: [String: DownloadSizeProbeResult] = [:]
        for token in tokens {
            guard let url = downloads[token]?.url else {
                results[token] = .unknown
                continue
            }
            results[token] = await probe.probe(urlString: url)
        }
        return results
    }

    static func decision(
        tokens: [String],
        downloadSizes: [String: DownloadSizeProbeResult],
        appPaths: [String: URL]
    ) async -> DownloadGate.Decision {
        let configuration = DownloadGate.Configuration.load()
        let downloadBytes = tokens.reduce(Int64(0)) { total, token in
            let bytes: Int64
            if case .known(let known) = downloadSizes[token] {
                bytes = known
            } else {
                bytes = configuration.largeDownloadThresholdBytes
            }
            let (sum, overflow) = total.addingReportingOverflow(bytes)
            return overflow ? Int64.max : sum
        }
        let resources = DownloadGate.Resources(
            downloadBytes: downloadBytes,
            snapshotBytes: DiskResourceProbe.snapshotBytes(
                appURLs: tokens.compactMap { appPaths[$0] }
            )
        )
        let conditions = await LiveConditions.snapshot()
        return DownloadGate.decide(
            resources: resources,
            availableDiskBytes: DiskResourceProbe.availableBytes(),
            network: conditions.network,
            power: conditions.power,
            configuration: configuration
        )
    }
}
