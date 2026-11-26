import Foundation

public struct SimulatorRuntime: Decodable, Hashable, Sendable {
    public let identifier: String
    public let name: String
    public let version: String
    public let buildVersion: String?
    public let isAvailable: Bool

    private enum CodingKeys: String, CodingKey {
        case identifier, name, version, isAvailable
        case buildVersion = "buildversion"
    }

    public var platform: String {
        let versionSuffix = " " + version
        if name.hasSuffix(versionSuffix) { return String(name.dropLast(versionSuffix.count)) }
        return name
    }

    fileprivate static func precedes(_ lhs: Self, _ rhs: Self) -> Bool {
        if lhs.platform != rhs.platform { return lhs.platform.localizedStandardCompare(rhs.platform) == .orderedAscending }
        if lhs.version != rhs.version { return lhs.version.localizedStandardCompare(rhs.version) == .orderedDescending }
        if lhs.buildVersion != rhs.buildVersion {
            return (lhs.buildVersion ?? "").localizedStandardCompare(rhs.buildVersion ?? "") == .orderedDescending
        }
        return lhs.identifier < rhs.identifier
    }
}

public struct SimulatorRuntimeReport: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case loaded([SimulatorRuntime])
        case toolUnavailable
        case failed
    }

    public let status: Status
    public let xcodeApplication: URL?

    public init(status: Status, xcodeApplication: URL?) {
        self.status = status
        self.xcodeApplication = xcodeApplication
    }
}

public struct SimulatorRuntimeInventory: Sendable {
    private struct SimctlList: Decodable {
        let runtimes: [SimulatorRuntime]
    }

    private let run: @Sendable (ProcessRequest) async throws -> ProcessResult
    private let hasExecutable: @Sendable (String) -> Bool

    public init() {
        let runner = ProcessRunner()
        self.init(run: { try await runner.run($0) }, hasExecutable: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    init(run: @escaping @Sendable (ProcessRequest) async throws -> ProcessResult,
         hasExecutable: @escaping @Sendable (String) -> Bool) {
        self.run = run
        self.hasExecutable = hasExecutable
    }

    public func read() async -> SimulatorRuntimeReport {
        var appURL: URL?
        do {
            let selection = try await run(request(SystemPaths.xcodeSelect, arguments: ["--print-path"]))
            let path = selection.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard selection.exitCode == 0, path.hasPrefix("/") else {
                return SimulatorRuntimeReport(status: .toolUnavailable, xcodeApplication: nil)
            }
            let directory = URL(filePath: path, directoryHint: .isDirectory)
            let app = directory.deletingLastPathComponent().deletingLastPathComponent()
            if app.pathExtension == "app" { appURL = app }
            guard hasExecutable(directory.appending(path: "usr/bin/simctl").path) else {
                return SimulatorRuntimeReport(status: .toolUnavailable, xcodeApplication: appURL)
            }
            let listing = try await run(request(SystemPaths.xcrun, arguments: ["simctl", "list", "--json", "runtimes"],
                                                environment: ["DEVELOPER_DIR": path]))
            guard listing.exitCode == 0 else { return SimulatorRuntimeReport(status: .failed, xcodeApplication: appURL) }
            let entries = try JSONDecoder().decode(SimctlList.self, from: Data(listing.stdout.utf8)).runtimes
            let runtimes = Set(entries).sorted(by: SimulatorRuntime.precedes)
            return SimulatorRuntimeReport(status: .loaded(runtimes), xcodeApplication: appURL)
        } catch {
            return SimulatorRuntimeReport(status: .failed, xcodeApplication: appURL)
        }
    }

    private func request(_ executable: URL, arguments: [String], environment: [String: String] = [:]) -> ProcessRequest {
        var query = ProcessRequest(executableURL: executable, arguments: arguments, environment: environment, timeouts: .quick)
        query.standardInput = .nullDevice
        query.outputLogging = .suppressed
        query.outputDrainLimit = 1
        return query
    }
}
