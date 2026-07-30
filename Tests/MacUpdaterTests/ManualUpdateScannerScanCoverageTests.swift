import Foundation
import Testing
@testable import MacUpdaterCore

@Suite("Manual update scanner integration")
struct ManualUpdateScannerScanCoverageTests {
    @Test func scanCombinesCaskSelfUpdateAndRollbackRowsWithoutExternalIO() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let applications = root.appendingPathComponent("Applications", isDirectory: true)
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let candidatePath = try makeApp(
            named: "Candidate",
            bundleIdentifier: "com.coverage.candidate",
            version: "1.0",
            in: applications
        )
        let managedPath = try makeApp(
            named: "Managed",
            bundleIdentifier: "com.coverage.managed",
            version: "0.9",
            in: applications
        )
        _ = try makeApp(
            named: "Skipped",
            bundleIdentifier: "com.coverage.skipped",
            version: "1.0",
            in: applications
        )
        _ = try makeApp(
            named: "StoreOnly",
            bundleIdentifier: "com.coverage.store-only",
            version: "1.0",
            in: applications,
            hasAppStoreReceipt: true
        )

        let cacheURL = root.appendingPathComponent("casks.json")
        try CaskDatabaseCache(fileURL: cacheURL).save([
            BrewCask(token: "candidate", name: ["Candidate"]),
            BrewCask(token: "skipped", name: ["Skipped"]),
        ])

        let defaultsSuite = "ManualUpdateScannerScanCoverageTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsSuite))
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        let ledger = CaskRollbackLedger(defaults: defaults)
        ledger.recordRollback(token: "managed", reason: .checkFailed)

        let runner = ManualScannerBrewRunner()
        let brew = BrewService(
            locator: BinaryLocator(brewCandidates: [URL(fileURLWithPath: "/usr/bin/true")]),
            runner: runner
        )
        let selfUpdate = WegaSelfUpdateChecker(
            repo: "coverage/wega",
            currentVersion: "0.0.0",
            client: FakeHTTP.client(ok: Self.selfUpdateRelease)
        )
        let scanner = ManualUpdateScanner(
            brewService: brew,
            scanDirectories: [applications, applications],
            caskCacheURL: cacheURL,
            maxConcurrentChecks: 1,
            selfUpdateChecker: selfUpdate,
            rollbackLedger: ledger
        )

        let result = await scanner.scan(brewOutdatedCasks: ["skipped"])

        #expect(result.failedChecks == 0)
        #expect(result.apps.count == 3)

        let candidate = try #require(result.apps.first {
            $0.path.standardizedFileURL.path == candidatePath.standardizedFileURL.path
        })
        #expect(candidate.name == "Candidate")
        #expect(candidate.installedVersion == "1.0")
        #expect(candidate.availableVersion == "2.0")
        #expect(candidate.source == .cask(token: "candidate"))
        #expect(candidate.origin == .manual)
        #expect(candidate.bundleIdentifier == "com.coverage.candidate")

        let rolledBack = try #require(result.apps.first {
            $0.path.standardizedFileURL.path == managedPath.standardizedFileURL.path
        })
        #expect(rolledBack.source == .cask(token: "managed"))
        #expect(rolledBack.installedVersion == "0.9")
        #expect(rolledBack.availableVersion == "1.0")
        #expect(rolledBack.origin == .brew)
        #expect(rolledBack.rolledBack)

        let wega = try #require(result.apps.first { app in
            if case .wega = app.source { return true }
            return false
        })
        #expect(wega.name == "Wega")
        #expect(wega.availableVersion == "999.0.0")
        #expect(wega.releaseNotes == "Coverage release")

        #expect(!result.apps.contains { $0.name == "Skipped" })
        #expect(!result.apps.contains { $0.name == "StoreOnly" })
        #expect(runner.requestedArguments.count == 4)
    }

    private static let selfUpdateRelease = """
        {
          "tag_name": "v999.0.0",
          "draft": false,
          "prerelease": false,
          "body": "Coverage release",
          "html_url": "https://example.com/wega/releases/v999.0.0",
          "assets": [
            {
              "name": "WegaMacUpdater.pkg",
              "browser_download_url": "https://example.com/WegaMacUpdater.pkg"
            }
          ]
        }
        """

    @discardableResult
    private func makeApp(
        named name: String,
        bundleIdentifier: String,
        version: String,
        in directory: URL,
        hasAppStoreReceipt: Bool = false
    ) throws -> URL {
        let appURL = directory.appendingPathComponent("\(name).app", isDirectory: true)
        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleName": name,
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleShortVersionString": version,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contentsURL.appendingPathComponent("Info.plist"))
        if hasAppStoreReceipt {
            let receipt = contentsURL.appendingPathComponent("_MASReceipt/receipt")
            try FileManager.default.createDirectory(
                at: receipt.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data().write(to: receipt)
        }
        return appURL
    }
}

private final class ManualScannerBrewRunner: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [[String]] = []

    var requestedArguments: [[String]] {
        lock.withLock { requests }
    }

    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        lock.withLock { requests.append(request.arguments) }

        switch request.arguments {
        case ["list", "--cask", "-1"]:
            return success("managed\ncli-only\n")
        case ["info", "--installed", "--json=v2"]:
            return success(#"{"casks":[{"token":"managed","installed":"1.0"}]}"#)
        case let arguments where arguments.starts(with: ["info", "--cask", "--json=v2"])
            && !arguments.contains("--"):
            return success(
                #"{"casks":[{"token":"managed","artifacts":[{"app":["Managed.app"]}]},{"token":"cli-only","artifacts":[{"binary":["cli-only"]}]}]}"#
            )
        case let arguments where arguments.starts(with: ["info", "--cask", "--json=v2", "--"]):
            return success(#"{"casks":[{"token":"candidate","version":"2.0"}]}"#)
        default:
            return ProcessResult(exitCode: 2, stdout: "", stderr: "unexpected arguments")
        }
    }

    func events(for request: ProcessRequest) -> AsyncThrowingStream<ProcessOutputEvent, Error> {
        AsyncThrowingStream { continuation in continuation.finish() }
    }

    private func success(_ stdout: String) -> ProcessResult {
        ProcessResult(exitCode: 0, stdout: stdout, stderr: "")
    }
}
