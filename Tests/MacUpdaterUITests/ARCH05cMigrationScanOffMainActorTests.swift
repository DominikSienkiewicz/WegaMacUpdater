import Foundation
import MacUpdaterCore
import Testing

@testable import WegaMacUpdater

/// ARCH-05c — the migration scan's `/Applications` walk (directory enumeration and each app's
/// `Info.plist` read) must not run on the MainActor. This exercises the seam behaviorally: the
/// injected per-directory scan closure records whether it ran on the main thread. If
/// `MigrationStore.scanApplicationDirectories` were MainActor-isolated, the closure would observe
/// the main thread and this test would fail.
@Suite("ARCH-05c migration scan off the MainActor")
struct ARCH05cMigrationScanOffMainActorTests {
    @Test func applicationDirectoryScanRunsOffTheMainThread() async {
        let probe = MainThreadProbe()
        let scanned = ApplicationInfo(
            path: URL(fileURLWithPath: "/Applications/Probe.app"),
            name: "Probe",
            bundleIdentifier: "example.probe",
            version: "1.0",
            installDate: nil,
            updateDate: nil,
            isManagedByBrew: false,
            caskToken: nil
        )

        let apps = await MigrationStore.scanApplicationDirectories(
            [URL(fileURLWithPath: "/Applications")],
            installedCasks: [],
            availableCasks: [],
            scan: { _, _, _ in
                probe.record(isMainThread: Thread.isMainThread)
                return [scanned]
            }
        )

        #expect(apps == [scanned])
        #expect(probe.observedMainThread == false)
    }
}

/// A `Sendable` box the injected (synchronous) scan closure can write to across the executor hop.
private final class MainThreadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool?

    func record(isMainThread: Bool) {
        lock.lock()
        defer { lock.unlock() }
        value = isMainThread
    }

    var observedMainThread: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
