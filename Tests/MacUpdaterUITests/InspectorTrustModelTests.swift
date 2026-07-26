import Foundation
import MacUpdaterCore
import XCTest

@testable import WegaMacUpdater

/// UX-05 — the inspector's Trust panel must tell "we have no data yet" apart from "we checked
/// and there is no checksum". `restoreLastScan()` brings back the outdated lists but NOT
/// `caskDownloads` (only a full scan fills that), so right after a relaunch every cask has no
/// download info. That is *missing data* — it must read as `.unknown`, never as the red
/// `.absent` verdict that would give every cask a false "no checksum" shield after every restart.
final class InspectorTrustModelTests: XCTestCase {

    /// A `ScanSnapshotIO` that hands back a fixed snapshot and swallows writes, so the restore
    /// path can be exercised without touching the disk.
    private struct StubIO: ScanSnapshotIO {
        let data: Data?
        func read() throws -> Data? { data }
        func write(_ data: Data) throws {}
    }

    private func store(with snapshot: ScanSnapshot) throws -> ScanStore {
        let data = try JSONEncoder().encode(snapshot)
        return ScanStore(resultStore: ScanResultStore(io: StubIO(data: data)))
    }

    /// The regression: after `restoreLastScan`, a cask with no restored `caskDownloads` entry
    /// is `.unknown`, not `.absent`.
    @MainActor
    func testRestoredCaskWithoutDownloadInfoIsUnknownNotAbsent() throws {
        // A random token so a real persisted ignore/pin policy can never filter this cask out.
        let token = "ux05-cask-\(UUID().uuidString)"
        let snapshot = ScanSnapshot(
            scannedAt: Date(timeIntervalSince1970: 1_700_000_000),
            brew: BrewOutdated(
                formulae: [],
                casks: [BrewOutdatedItem(name: token, installedVersions: ["1"], currentVersion: "2")]
            ),
            mas: [],
            npm: [],
            manual: []
        )

        let scan = try store(with: snapshot)
        scan.restoreLastScan()

        XCTAssertEqual(scan.status, .results, "the restored snapshot should populate the list")
        XCTAssertTrue(scan.caskDownloads.isEmpty, "restore must not fabricate download info")

        let cask = scan.allItems.first { $0.kind == .cask && $0.name == token }
        let restoredCask = try XCTUnwrap(cask, "the restored cask should be present in the list")

        let signal = caskChecksumSignal(token: restoredCask.name, downloads: scan.caskDownloads)
        XCTAssertEqual(
            signal, .unknown,
            "UX-05: a cask with no restored download info is unknown, not a negative verdict")
        XCTAssertNotEqual(signal, .absent, "UX-05: missing data must never render as 'no checksum'")
    }

    /// Once a scan *has* populated `caskDownloads`, the same resolver reports a real verdict:
    /// present for a genuine sha256, absent for a `no_check` cask. This proves the `.unknown`
    /// above is specifically about missing data, not a blanket suppression of the signal.
    @MainActor
    func testPopulatedDownloadsReportRealChecksumVerdict() throws {
        let token = "ux05-cask-\(UUID().uuidString)"

        let present = caskChecksumSignal(
            token: token,
            downloads: [token: CaskDownloadInfo(token: token, url: nil, sha256: "e3b0c44298fc")])
        XCTAssertEqual(present, .present)

        let absent = caskChecksumSignal(
            token: token,
            downloads: [token: CaskDownloadInfo(token: token, url: nil, sha256: "no_check")])
        XCTAssertEqual(absent, .absent)
    }
}
