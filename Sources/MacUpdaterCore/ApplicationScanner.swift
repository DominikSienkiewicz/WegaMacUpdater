import Foundation

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

        return appURLs.map { url in
            appInfo(
                for: url,
                installedCasks: installedCasks,
                availableCasks: availableCasks
            )
        }
    }

    private func appInfo(
        for appURL: URL,
        installedCasks: Set<String>,
        availableCasks: [BrewCask]
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
        switch matcher.match(applicationName: appName, installedCasks: installedCasks, availableCasks: availableCasks) {
        case .managed(let token):
            isManagedByBrew = true
            caskToken = token
        case .candidate(let token):
            caskToken = token
        case .none:
            break
        }

        let managedByMas = hasMasReceipt(at: appURL)
        if managedByMas {
            isManagedByBrew = false
            caskToken = nil
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
