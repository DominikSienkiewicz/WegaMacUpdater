import Foundation
import Testing
import MacUpdaterCore
@testable import WegaMacUpdater

@Suite("Architecture review regressions")
@MainActor
struct ArchitectureReviewRegressionTests {
    @Test func selfUpdateInstallationWaitsForTheSharedWriteGateAndProtectsQuit() async {
        let operations = OperationCoordinator()
        let upgrades = UpgradeCoordinator(operations: operations)
        let blockerStarted = UILatch()
        let releaseBlocker = UILatch()
        let installProbe = SelfUpdateInstallProbe()
        let controller = SelfUpdateController(
            dependencies: .init(
                check: { .upToDate },
                download: { $0 },
                verify: { _ in },
                installOrOpen: { _ in
                    installProbe.record(
                        mutationLabels: MutationGuard.shared.runningLabels
                    )
                    return true
                },
                openFallback: {}
            ),
            upgrades: upgrades
        )

        let blocker = Task {
            await operations.withWrite(label: "blocker") { @MainActor in
                blockerStarted.open()
                await releaseBlocker.wait()
            }
        }
        await blockerStarted.wait()

        let update = Task {
            await controller.downloadAndOpen(URL(fileURLWithPath: "/tmp/Wega.pkg")) { _ in }
        }
        while (await operations.snapshot()).queuedWrites == 0 {
            await Task.yield()
        }
        #expect(!installProbe.didRun)

        releaseBlocker.open()
        await blocker.value
        await update.value

        #expect(installProbe.didRun)
        #expect(installProbe.mutationLabels.contains("self-update"))
    }

    @Test func viewsContainNoRealProcessNetworkOrFilesystemWork() throws {
        let root = packageRoot()
        let info = executableSource(try source("Sources/MacUpdater/InfoView.swift", root: root))
        let migration = executableSource(
            try source("Sources/MacUpdater/MigrationView.swift", root: root)
        )

        for forbidden in [
            "ProcessRunner().run",
            "CatalogRefresher(",
            "PrivilegedHelperClient.shared.register()",
            "PrivilegedHelperClient.shared.unregister()",
            "GitHubCredentialStore.setToken",
            "GitHubCredentialStore.clear()"
        ] {
            #expect(!info.contains(forbidden), "InfoView still owns I/O: \(forbidden)")
        }

        for forbidden in [
            "FileManager.default",
            "CaskDatabaseClient(",
            "model.brewService",
            "model.npmService",
            "model.masService",
            "processes.forceKill",
            "runningApplicationInspector.runningApplications()",
            "runningApplicationTerminator.requestGracefulTermination",
            "NSWorkspace.shared.open"
        ] {
            #expect(!migration.contains(forbidden), "MigrationView still owns I/O: \(forbidden)")
        }
    }

    /// ARCH-07b — the app-scan prologue (loading the Homebrew cask catalog from its on-disk
    /// cache) lives in one shared implementation, and every scan site sources the cache path
    /// from `AppScanDirectories.caskDatabaseCacheURL` instead of rebuilding it by hand.
    @Test func appScanPrologueLoadsTheCaskCatalogThroughOneSharedPath() throws {
        let root = packageRoot()

        // Every scan site that loads the cask catalog before walking the app directories.
        let scanSites = [
            "Sources/MacUpdaterCore/ManualUpdateScanner.swift",
            "Sources/MacUpdater/InventoryStore.swift",
            "Sources/MacUpdater/MigrationStore.swift"
        ]
        for path in scanSites {
            let scan = executableSource(try source(path, root: root))
            #expect(
                !scan.contains("Library/Caches/"),
                "\(path) still hand-builds the cask cache path instead of AppScanDirectories.caskDatabaseCacheURL"
            )
            #expect(
                !scan.contains("CaskDatabaseCache(fileURL:"),
                "\(path) still constructs the catalog client inline instead of the shared CaskDatabaseClient.caskCatalog prologue"
            )
        }

        // The shared prologue is the one place the cache path becomes a catalog client.
        let prologue = executableSource(
            try source("Sources/MacUpdaterCore/CaskDatabaseClient.swift", root: root)
        )
        #expect(
            prologue.contains("AppScanDirectories.caskDatabaseCacheURL"),
            "the shared cask-catalog prologue must source its path from AppScanDirectories.caskDatabaseCacheURL"
        )
    }

    /// ARCH-07a — the brew/npm event-streaming loop and its log-buffer cap live in one
    /// shared helper. Every upgrade/uninstall path drains its process events through
    /// `ProcessEventStream.drain` instead of copying the `for try await event in stream`
    /// loop, and no path hardcodes its own buffer limit (they had drifted to 200 and 500).
    @Test func brewNpmEventStreamingRunsThroughOneSharedHelper() throws {
        let root = packageRoot()

        // Every path that used to inline the streaming loop with its own buffer cap.
        let streamingSites = [
            "Sources/MacUpdater/ScanStore+Actions.swift",
            "Sources/MacUpdater/MigrationStore.swift",
            "Sources/MacUpdater/BackgroundUpdater.swift"
        ]
        for path in streamingSites {
            let site = executableSource(try source(path, root: root))
            #expect(
                site.contains("ProcessEventStream.drain("),
                "\(path) must stream brew/npm events through ProcessEventStream.drain"
            )
            #expect(
                !site.contains("case .finished(let result)"),
                "\(path) still inlines its own ProcessOutputEvent streaming loop"
            )
            #expect(
                !site.contains(".count > 500") && !site.contains(".count > 200"),
                "\(path) still hardcodes its own streamed-log buffer limit"
            )
        }

        // The loop and the buffer limit each exist exactly once — in the shared helper.
        let helper = executableSource(
            try source("Sources/MacUpdater/ProcessEventStream.swift", root: root)
        )
        #expect(
            helper.contains("for try await event in stream"),
            "the shared streaming loop must live in ProcessEventStream.drain"
        )
        #expect(
            helper.contains("static let logLineLimit ="),
            "the streamed-log buffer limit must be defined once in ProcessEventStream"
        )
    }

    /// ARCH-03 — the npm global-update scan runs one `npm outdated -g --json` process
    /// instead of a `npm view` fan-out (one Node per package), and caches the resolved
    /// npm location so a scan's repeated lookups don't re-glob nvm/fnm or respawn a
    /// login shell.
    @Test func npmGlobalScanUsesOneOutdatedProcessAndCachesLocation() throws {
        let root = packageRoot()
        let checker = executableSource(
            try source("Sources/MacUpdaterCore/NpmGlobalChecker.swift", root: root)
        )

        #expect(
            checker.contains("\"outdated\", \"-g\", \"--json\""),
            "the npm outdated scan must run `npm outdated -g --json`"
        )
        #expect(
            !checker.contains("\"view\""),
            "the npm outdated scan must not shell out to `npm view` per package"
        )
        #expect(
            !checker.contains("withTaskGroup"),
            "the npm outdated scan must not fan out one process per package"
        )
        #expect(
            checker.contains("cachedURL"),
            "NpmLocator must cache the resolved npm location for the scan"
        )
    }

    @Test func topLevelHomebrewReadRoundsUseTheSharedGate() throws {
        let root = packageRoot()
        let foreground = executableSource(
            try source("Sources/MacUpdater/ScanStore+Actions.swift", root: root)
        )
        let background = executableSource(
            try source("Sources/MacUpdater/BackgroundUpdater.swift", root: root)
        )

        #expect(foreground.contains("withReadLease(label: \"foreground scan\")"))
        #expect(foreground.contains("OperationCoordinator.shared.withRead("))
        #expect(foreground.contains("holding: operationLease"))
        #expect(background.contains("OperationCoordinator.shared.withReadLease("))
        #expect(background.contains("label: \"background update preflight\""))
    }

    private func packageRoot(file: String = #filePath) -> URL {
        URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ path: String, root: URL) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func executableSource(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }
}

@MainActor
private final class UILatch {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

@MainActor
private final class SelfUpdateInstallProbe {
    private(set) var didRun = false
    private(set) var mutationLabels: [String] = []

    func record(mutationLabels: [String]) {
        didRun = true
        self.mutationLabels = mutationLabels
    }
}
