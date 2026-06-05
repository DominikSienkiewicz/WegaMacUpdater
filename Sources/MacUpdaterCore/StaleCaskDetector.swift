import Foundation

public struct StaleCaskDetector {
    private let applicationsDirectory: URL
    private let userApplicationsDirectory: URL
    private let fileExists: (URL) -> Bool

    public init(
        applicationsDirectory: URL = SystemPaths.applicationsDirectory,
        userApplicationsDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true),
        fileExists: @escaping (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) {
        self.applicationsDirectory = applicationsDirectory
        self.userApplicationsDirectory = userApplicationsDirectory
        self.fileExists = fileExists
    }

    public func staleCasks(from installationInfo: [BrewCaskInstallationInfo]) -> [String] {
        installationInfo.compactMap { info in
            guard !info.appArtifacts.isEmpty else { return nil }

            let allAppsMissing = info.appArtifacts.allSatisfy { appName in
                let systemPath = applicationsDirectory.appendingPathComponent(appName)
                let userPath = userApplicationsDirectory.appendingPathComponent(appName)
                return !fileExists(systemPath) && !fileExists(userPath)
            }

            return allAppsMissing ? info.token : nil
        }
    }
}
