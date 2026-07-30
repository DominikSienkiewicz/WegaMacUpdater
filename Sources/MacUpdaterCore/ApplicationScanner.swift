import Foundation
import WegaHelperKit

public struct ApplicationScanner {
    private let fileManager: FileManager
    private let matcher: CaskMatcher

    public init(fileManager: FileManager = .default, matcher: CaskMatcher = CaskMatcher()) {
        self.fileManager = fileManager
        self.matcher = matcher
    }

    public func scanApplications(
        in applicationsDirectory: URL = SystemPaths.applicationsDirectory,
        installedCasks: Set<String> = [],
        availableCasks: [BrewCask] = []
    ) throws -> [ApplicationInfo] {
        let appURLs = try fileManager.contentsOfDirectory(
            at: applicationsDirectory,
            includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "app" }
        .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }

        // ARCH-05b: build the cask matching index once per scan and reuse it for
        // every application, instead of re-scanning the whole cask database per app.
        let caskIndex = matcher.makeIndex(installedCasks: installedCasks, availableCasks: availableCasks)

        return appURLs.map { url in
            appInfo(for: url, caskIndex: caskIndex)
        }
    }

    private func appInfo(
        for appURL: URL,
        caskIndex: CaskMatcher.Index
    ) -> ApplicationInfo {
        // Read Info.plist directly to avoid NSBundle's per-path cache, which causes
        // stale version strings after in-place app updates (e.g. JetBrains Toolbox).
        let infoPlistURL = appURL.appendingPathComponent("Contents/Info.plist")
        let infoDict = (try? Data(contentsOf: infoPlistURL))
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
            ?? [:]

        let appName = infoDict["CFBundleName"] as? String
            ?? appURL.deletingPathExtension().lastPathComponent
        let version = infoDict["CFBundleShortVersionString"] as? String
            ?? infoDict["CFBundleVersion"] as? String
        let bundleIdentifier = infoDict["CFBundleIdentifier"] as? String
        let resourceValues = try? appURL.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])

        var isManagedByBrew = false
        var caskToken: String?
        // LT-03 — the route is recorded alongside the token. The migration gate reads it back
        // off the app; re-deriving it there is what left the scorer's signals dead.
        var caskMatchProvenance: CaskMatchProvenance?
        switch matcher.match(
            applicationName: appName,
            bundleIdentifier: bundleIdentifier,
            using: caskIndex
        ) {
        case let .managed(token, provenance):
            isManagedByBrew = true
            caskToken = token
            caskMatchProvenance = provenance
        case let .candidate(token, provenance):
            caskToken = token
            caskMatchProvenance = provenance
        case .none:
            break
        }

        let managedByMas = hasMasReceipt(at: appURL)
        if managedByMas {
            isManagedByBrew = false
            caskToken = nil
            caskMatchProvenance = nil
        }

        return ApplicationInfo(
            path: appURL,
            name: appName,
            bundleIdentifier: bundleIdentifier,
            version: version,
            installDate: resourceValues?.creationDate,
            updateDate: resourceValues?.contentModificationDate,
            isManagedByBrew: isManagedByBrew,
            caskToken: caskToken,
            caskMatchProvenance: caskMatchProvenance,
            isManagedByMas: managedByMas
        )
    }

    private func hasMasReceipt(at appURL: URL) -> Bool {
        let receiptURL = appURL
            .appendingPathComponent("Contents")
            .appendingPathComponent("_MASReceipt")
            .appendingPathComponent("receipt")
        return fileManager.fileExists(atPath: receiptURL.path)
    }
}
