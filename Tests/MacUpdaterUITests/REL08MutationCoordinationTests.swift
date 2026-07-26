import Foundation
import Testing
import MacUpdaterCore
@testable import WegaMacUpdater

/// REL-08 — every mutation, including the `--force` side paths, must pass through the one
/// coordinator that serialises writes, snapshots, and validates. This suite covers the
/// pieces that closed the remaining gaps: the single-instance guard at launch, the
/// low-confidence takeover block, and deterministic serialisation of overlapping flows.
@Suite("REL-08 mutation coordination")
@MainActor
struct REL08MutationCoordinationTests {
    private func packageRoot(file: String = #filePath) -> URL {
        URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: packageRoot().appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// AC6 — the launch path must consult `SingleInstanceGuard`, enumerating other copies by
    /// bundle identifier, and stand down (`terminate`) *before* it registers mutation sources
    /// or starts the background loop. The wiring lives behind AppKit's launch sequence, so it
    /// is asserted at the source level like the REL-06 termination wiring.
    @Test func singleInstanceGuardBlocksASecondInstanceAtStartup() throws {
        let text = try source("Sources/MacUpdater/MacUpdaterApp.swift")

        let launch = try #require(text.range(of: "func applicationDidFinishLaunching("))
        let enforce = try #require(text.range(of: "enforceSingleInstance()"))
        let register = try #require(text.range(of: "registerMutationSources()"))

        #expect(launch.lowerBound < enforce.lowerBound,
                "REL-08: the single-instance check must run inside applicationDidFinishLaunching")
        #expect(enforce.lowerBound < register.lowerBound,
                "REL-08: a second instance must stand down before it registers mutation sources")

        // The guard enumerates other copies by bundle identifier, decides, and terminates.
        #expect(text.contains("SingleInstanceGuard.decide("))
        #expect(text.contains("runningApplications(withBundleIdentifier:"))
        #expect(text.contains("NSApp.terminate("))
    }

    /// AC5 — the migration execution path must consult the match confidence before it runs
    /// `brew install --cask --force`. This locks the production call-site of
    /// `allowsAutoConfirm`, which had none: the score was computed for a badge and thrown away.
    @Test func migrationConsultsMatchConfidenceBeforeTakeover() throws {
        let text = try source("Sources/MacUpdater/MigrationStore.swift")
        #expect(text.contains("CaskMatchScorer.score("),
                "REL-08: migration must score the .app→cask match before overwriting the app")
        #expect(text.contains("MigrationAutoTakeover.decide("),
                "REL-08: the takeover decision must gate execution, not just paint a badge")
    }

    /// AC5 (behaviour) — a low-confidence match must not auto-take-over the app. The guard
    /// runs before any running-application inspection, so a blocked migration never even
    /// queries the workspace; the recording inspector proves the flow stopped at the gate.
    @Test func lowConfidenceMigrationDoesNotProceedAutomatically() async {
        let inspector = RecordingRunningApplicationInspector()
        let store = MigrationStore(runningApplicationInspector: inspector)
        // "VS Code" vs token "visual-studio-code" scores `.low` (fuzzy only) — see P1BackendsTests.
        let app = ApplicationInfo(
            path: URL(fileURLWithPath: "/Applications/VS Code.app"),
            name: "VS Code",
            bundleIdentifier: "com.microsoft.VSCode",
            version: "1.0",
            installDate: nil,
            updateDate: nil,
            isManagedByBrew: false,
            caskToken: "visual-studio-code"
        )

        await store.migrate(app, model: AppViewModel(), onWegaState: nil)

        #expect(store.errorMessage != nil,
                "REL-08: a low-confidence takeover must tell the user why it stopped")
        #expect(store.migrating == nil,
                "REL-08: a blocked migration must not mark itself in-flight")
        #expect(store.migrated.isEmpty,
                "REL-08: a blocked migration must not record the token as adopted")
        #expect(inspector.callCount == 0,
                "REL-08: the block must precede any execution — not even the workspace is queried")
    }

    /// AC1/AC7 — overlapping mutations from different flows must serialise through the one
    /// shared write gate, deterministically, with no window where both hold the brew lock.
    @Test func overlappingMutationFlowsSerialiseThroughTheSharedCoordinator() async {
        let operations = OperationCoordinator()
        let coordinator = UpgradeCoordinator(operations: operations)
        let probe = OverlapProbe()

        let migrationStarted = UILatch()
        let releaseMigration = UILatch()

        let migration = Task {
            await coordinator.performWrite(.migration) {
                probe.enter(.migration)
                migrationStarted.open()
                await releaseMigration.wait()
                probe.leave()
            }
        }
        await migrationStarted.wait()

        let cleanup = Task {
            await coordinator.performWrite(.cleanup) {
                probe.enter(.cleanup)
                probe.leave()
            }
        }

        // The cleanup write must queue behind the in-flight migration, not run beside it.
        while (await operations.snapshot()).queuedWrites == 0 {
            await Task.yield()
        }
        #expect(!probe.cleanupEntered,
                "REL-08: cleanup must wait behind the in-flight migration, not run beside it")

        releaseMigration.open()
        await migration.value
        await cleanup.value

        #expect(probe.cleanupEntered)
        #expect(probe.maxConcurrent == 1,
                "REL-08: two mutation flows must never hold the write gate at once")
    }
}

@MainActor
private final class RecordingRunningApplicationInspector: RunningApplicationInspecting {
    private(set) var callCount = 0

    func runningApplications() -> [RunningApplicationTarget] {
        callCount += 1
        return []
    }
}

@MainActor
private final class OverlapProbe {
    enum Flow: Equatable { case migration, cleanup }

    private var active = 0
    private(set) var maxConcurrent = 0
    private(set) var cleanupEntered = false

    func enter(_ flow: Flow) {
        if flow == .cleanup { cleanupEntered = true }
        active += 1
        maxConcurrent = max(maxConcurrent, active)
    }

    func leave() {
        active -= 1
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
