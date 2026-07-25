import Foundation
import Testing
@testable import MacUpdaterCore

private final class MigrationTerminationRunner: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedRequests: [ProcessRequest] = []

    var requests: [ProcessRequest] {
        lock.withLock { recordedRequests }
    }

    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        lock.withLock { recordedRequests.append(request) }
        return ProcessResult(exitCode: 0, stdout: "", stderr: "")
    }

    func events(for request: ProcessRequest) -> AsyncThrowingStream<ProcessOutputEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

@Suite("Migration running application target")
struct MigrationRunningApplicationTargetTests {
    @Test func exactStandardizedBundlePathWinsOverDuplicateBundleIdentifiers() {
        let app = application(
            path: URL(fileURLWithPath: "/Applications/Utilities/../Acme.app"),
            bundleIdentifier: "com.acme.app"
        )
        let exact = target(
            pid: 11,
            path: "/Applications/Acme.app",
            bundleIdentifier: "com.acme.app"
        )
        let duplicate = target(
            pid: 22,
            path: "/Users/me/Applications/Acme.app",
            bundleIdentifier: "com.acme.app"
        )

        #expect(
            MigrationRunningApplicationResolver.resolve(app: app, running: [duplicate, exact])
                == .running(exact)
        )
    }

    @Test func resolvedSymlinkBundlePathIsAnExactMatch() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let realBundle = temporary.appendingPathComponent("Acme.app", isDirectory: true)
        let symlink = temporary.appendingPathComponent("Acme-link.app")
        try FileManager.default.createDirectory(at: realBundle, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: realBundle)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let exact = target(pid: 11, url: realBundle, bundleIdentifier: nil)

        #expect(
            MigrationRunningApplicationResolver.resolve(
                app: application(path: symlink, bundleIdentifier: nil),
                running: [exact]
            ) == .running(exact)
        )
    }

    @Test func aUniqueBundleIdentifierIsUsedWhenNoPathMatches() {
        let unique = target(
            pid: 11,
            path: "/Applications/Relocated.app",
            bundleIdentifier: "com.acme.app"
        )

        #expect(
            MigrationRunningApplicationResolver.resolve(
                app: application(
                    path: URL(fileURLWithPath: "/Users/me/Applications/Acme.app"),
                    bundleIdentifier: "com.acme.app"
                ),
                running: [unique]
            ) == .running(unique)
        )
    }

    @Test func duplicateBundleIdentifierWithoutAnExactPathFailsClosed() {
        let first = target(
            pid: 11,
            path: "/Applications/First.app",
            bundleIdentifier: "com.acme.app"
        )
        let second = target(
            pid: 22,
            path: "/Applications/Second.app",
            bundleIdentifier: "com.acme.app"
        )

        #expect(
            MigrationRunningApplicationResolver.resolve(
                app: application(
                    path: URL(fileURLWithPath: "/Users/me/Applications/Acme.app"),
                    bundleIdentifier: "com.acme.app"
                ),
                running: [first, second]
            ) == .ambiguousBundleIdentifier("com.acme.app")
        )
    }

    @Test func exactPathWorksWithoutABundleIdentifier() {
        let exact = target(pid: 11, path: "/Applications/Acme.app", bundleIdentifier: nil)

        #expect(
            MigrationRunningApplicationResolver.resolve(
                app: application(
                    path: URL(fileURLWithPath: "/Applications/Acme.app"),
                    bundleIdentifier: nil
                ),
                running: [exact]
            ) == .running(exact)
        )
    }

    @Test func forceConsentReidentifiesTheTargetBeforeForceQuitAndMigration() throws {
        let text = try String(
            contentsOf: packageRoot().appendingPathComponent("Sources/MacUpdater/MigrationView.swift"),
            encoding: .utf8
        )
        let start = try #require(text.range(of: "private func forceTerminateAndMigrate"))
        let end = try #require(
            text.range(of: "private func performMigration", range: start.upperBound..<text.endIndex)
        )
        let body = String(text[start.lowerBound..<end.lowerBound])
        let identify = try #require(body.range(of: "resolveRunningTarget(for: request.app)"))
        let force = try #require(
            body.range(of: "processes.forceKill(processIdentifier: currentTarget.processIdentifier)")
        )
        let confirmStopped = try #require(
            body.range(of: "waitForApplicationToStop(request.app)", range: force.upperBound..<body.endIndex)
        )
        let migrateAfterConfirmation = try #require(
            body.range(
                of: "performMigration(request.app, token: token)",
                range: confirmStopped.upperBound..<body.endIndex
            )
        )

        #expect(identify.lowerBound < force.lowerBound)
        #expect(force.lowerBound < confirmStopped.lowerBound)
        #expect(confirmStopped.lowerBound < migrateAfterConfirmation.lowerBound)
    }

    @Test func migrationDetectionUsesTheInjectableInspectorInsteadOfRestartMap() throws {
        let text = try String(
            contentsOf: packageRoot().appendingPathComponent("Sources/MacUpdater/MigrationView.swift"),
            encoding: .utf8
        )
        let start = try #require(text.range(of: "private func migrate(_ app: ApplicationInfo) async"))
        let end = try #require(
            text.range(of: "private func forceTerminateAndMigrate", range: start.upperBound..<text.endIndex)
        )
        let body = String(text[start.lowerBound..<end.lowerBound])

        #expect(text.contains("runningApplicationInspector: any RunningApplicationInspecting"))
        #expect(body.contains("resolveRunningTarget(for: app)"))
        #expect(!body.contains("restartMap"))
    }

    @Test func gracefulQuitUsesTheExactResolvedTarget() throws {
        let text = try String(
            contentsOf: packageRoot().appendingPathComponent("Sources/MacUpdater/MigrationView.swift"),
            encoding: .utf8
        )
        let start = try #require(text.range(of: "private func migrate(_ app: ApplicationInfo) async"))
        let end = try #require(
            text.range(of: "private func forceTerminateAndMigrate", range: start.upperBound..<text.endIndex)
        )
        let body = String(text[start.lowerBound..<end.lowerBound])

        #expect(text.contains("runningApplicationTerminator: any RunningApplicationTargetTerminating"))
        #expect(body.contains("runningApplicationTerminator.requestGracefulTermination(target)"))
        #expect(!body.contains("processes.requestGracefulTermination"))
    }

    @Test func forceKillTargetsOnlyTheConfirmedProcessIdentifier() async {
        let runner = MigrationTerminationRunner()
        let kill = URL(fileURLWithPath: "/test/kill")
        let service = RunningProcessService(runner: runner, killURL: kill)

        let result = await service.forceKill(processIdentifier: 4242)

        #expect(result)
        #expect(runner.requests == [ProcessRequest(
            executableURL: kill,
            arguments: ["-KILL", "4242"]
        )])
    }

    private func application(path: URL, bundleIdentifier: String?) -> ApplicationInfo {
        ApplicationInfo(
            path: path,
            name: "Acme",
            bundleIdentifier: bundleIdentifier,
            version: nil,
            installDate: nil,
            updateDate: nil,
            isManagedByBrew: false,
            caskToken: "acme"
        )
    }

    private func target(
        pid: Int32,
        path: String,
        bundleIdentifier: String?
    ) -> RunningApplicationTarget {
        target(
            pid: pid,
            url: URL(fileURLWithPath: path),
            bundleIdentifier: bundleIdentifier
        )
    }

    private func target(
        pid: Int32,
        url: URL,
        bundleIdentifier: String?
    ) -> RunningApplicationTarget {
        RunningApplicationTarget(
            processIdentifier: pid,
            bundleURL: url,
            bundleIdentifier: bundleIdentifier,
            appName: "Acme",
            processName: "Acme"
        )
    }

    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
