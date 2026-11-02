import Foundation

public struct MicrosoftAutoUpdateOffer: Equatable, Sendable {
    public let applicationID: String
    public let version: String
    public let build: String?
}

public struct MicrosoftAutoUpdateReport: Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case notInstalled, unavailable, failed, unrecognizedOutput, noUpdatesReported, updatesReported
    }
    public let status: Status
    public var offers: [MicrosoftAutoUpdateOffer] = []
    public var updaterVersion: String?

    public static func parse(_ result: ProcessResult) -> Self { MicrosoftAutoUpdateOutput.parse(result) }

    public func check(app: ApplicationInfo) -> ManualCheckResult {
        guard let applicationID = MicrosoftAutoUpdateSupport.applicationID(for: app) else { return .notApplicable }
        switch status {
        case .unavailable: return .unavailable
        case .failed, .unrecognizedOutput: return .failed
        case .notInstalled, .noUpdatesReported: return .notApplicable
        case .updatesReported:
            guard let offer = offers.first(where: { $0.applicationID == applicationID }),
                  let installed = app.version, MicrosoftAutoUpdateOutput.isNumericVersion(installed),
                  isUpgrade(installed: installed, latest: offer.version, scheme: .buildNumbered) else { return .notApplicable }
            let label = offer.version + (offer.build.map { " (" + $0 + ")" } ?? "")
            return .outdated(.init(name: app.name, path: app.path, installedVersion: installed,
                availableVersion: label, source: .microsoftAutoUpdate(applicationID: applicationID), origin: AppOrigin.of(app),
                bundleIdentifier: app.bundleIdentifier,
                completionRequirement: .init(version: offer.version, field: .shortVersion, scheme: .buildNumbered)))
        }
    }
}

public struct MicrosoftAutoUpdateEvidence: Codable, Equatable, Sendable {
    public let applicationID: String
    public let status: MicrosoftAutoUpdateReport.Status
    public let updaterVersion: String?
}

public struct MicrosoftAutoUpdateClient: Sendable {
    private let runner: any ProcessRunning
    private let applicationURL: URL

    public init(runner: any ProcessRunning = ProcessRunner(), applicationURL: URL = MicrosoftAutoUpdateSupport.applicationURL) {
        self.runner = runner
        self.applicationURL = applicationURL
    }

    public func list() async -> MicrosoftAutoUpdateReport {
        guard FileManager.default.fileExists(atPath: applicationURL.path) else { return .init(status: .notInstalled) }
        let executable = applicationURL.appendingPathComponent("Contents/MacOS/msupdate")
        guard let app = VendorUpdateCompletionChecker.application(at: applicationURL),
              app.bundleIdentifier == "com.microsoft.autoupdate2",
              FileManager.default.isExecutableFile(atPath: executable.path) else { return .init(status: .failed) }
        var report: MicrosoftAutoUpdateReport
        do {
            let result = try await runner.run(.init(executableURL: executable, arguments: ["--list", "--format", "plist"],
                timeout: 120, idleTimeout: 60))
            report = .parse(result)
        } catch {
            report = .init(status: .unavailable)
        }
        report.updaterVersion = app.version
        UpdateDiagnostics.record("microsoft_autoupdate.list", fields: [
            "status": report.status.rawValue, "offers": String(report.offers.count), "updaterVersion": app.version ?? "unknown",
        ])
        return report
    }
}
