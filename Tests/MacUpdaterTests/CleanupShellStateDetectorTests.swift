import XCTest
@testable import MacUpdaterCore

final class CleanupShellStateDetectorTests: XCTestCase {
    private static let bootMilliseconds: Int64 = 1_794_297_600_000
    private var tmp: CleanupTempHome!
    private var fileSystem: CleanupFileSystem!

    override func setUpWithError() throws {
        tmp = try CleanupTempHome()
        fileSystem = GuardedCleanupFileSystem(
            base: LiveCleanupFileSystem(trash: { _ in }),
            guard: ProtectedLocationGuard(home: tmp.home, mounts: FixedMountTable(["/"]))
        )
    }

    private let directory = ".local/state/fnm_multishells"

    private func findings() throws -> [CleanupFinding] {
        try CleanupShellStateDetector(
            fileSystem: fileSystem, home: tmp.home, tmpDirectory: tmp.url("tmp"),
            inspector: FakeProcessInspector(
                processes: [], bootTime: Date(timeIntervalSince1970: Double(Self.bootMilliseconds) / 1000)
            )
        ).findings()
    }

    @discardableResult
    private func link(_ name: String, in relativeDirectory: String? = nil) throws -> URL {
        try tmp.symlink("\(relativeDirectory ?? directory)/\(name)", to: "/nonexistent-node")
    }

    private func before(_ offset: Int64) -> Int64 { Self.bootMilliseconds - offset }

    func testEntriesBeforeBootAreStaleWhateverTheirPid() throws {
        let stale = [
            try link("1_\(before(1_000))"),
            try link("99999_\(before(86_400_000))_ab12"),
            try link("4242_\(before(5_000_000_000))"),
        ]
        try link("77_\(Self.bootMilliseconds + 1_000)")
        try link("78_\(Self.bootMilliseconds)_x")

        let all = try findings()

        let batch = try XCTUnwrap(all.first { $0.status == .stale })
        XCTAssertEqual(batch.detector, .shellState)
        XCTAssertEqual(batch.tool, "fnm")
        XCTAssertEqual(batch.path, tmp.url(directory))
        XCTAssertEqual(batch.action, .trashBatch(parent: tmp.url(directory), entries: stale.sorted { $0.lastPathComponent < $1.lastPathComponent }))
        XCTAssertEqual(batch.reason, .staleSinceBoot(count: 3))
        XCTAssertEqual(batch.bucket, .safe)
        XCTAssertEqual(batch.risk, .low)
        XCTAssertNotNil(batch.identity)
        let kept = try XCTUnwrap(all.first { $0.status == .info })
        XCTAssertEqual(kept.reason, .keptSinceBoot(count: 2))
        XCTAssertEqual(kept.action, .none)
        XCTAssertEqual(kept.bucket, .excluded)
        XCTAssertEqual(all.count, 2)
    }

    func testEntriesAfterBootAreKeptEvenWithADeadPid() throws {
        let fresh = try link("1_\(Self.bootMilliseconds + 60_000)")

        let all = try findings()

        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.status, .info)
        XCTAssertEqual(all.first?.reason, .keptSinceBoot(count: 1))
        XCTAssertFalse(all.contains { finding in
            if case let .trashBatch(_, entries) = finding.action { return entries.contains(fresh) }
            return false
        })
    }

    func testThreePartNamesParse() {
        XCTAssertEqual(
            CleanupShellStateDetector.timestamp(ofEntryNamed: "81234_1762761600000_ab12"),
            Date(timeIntervalSince1970: 1_762_761_600)
        )
        XCTAssertEqual(
            CleanupShellStateDetector.timestamp(ofEntryNamed: "81234_1762761600000"),
            Date(timeIntervalSince1970: 1_762_761_600)
        )
    }

    func testMalformedNamesDoNotParse() {
        for name in ["default", "abc_def", "12_123456789", "12_1762761600000_", "_1762761600000", "12_1762761600000x", "١٢_1762761600000"] {
            XCTAssertNil(CleanupShellStateDetector.timestamp(ofEntryNamed: name), name)
        }
    }

    func testUnparseableNamesAreKept() throws {
        try link("default")
        try link("abc_def")

        XCTAssertEqual(try findings(), [])
    }

    func testOnlySymlinksAreCandidates() throws {
        try tmp.file("\(directory)/5_\(before(1_000))", size: 10)
        try tmp.directory("\(directory)/6_\(before(1_000))")

        XCTAssertEqual(try findings(), [])
    }

    func testSizeIsTheLinksNotTheTargets() throws {
        try tmp.file("payload/big.bin", size: 5_000_000)
        try tmp.symlink("\(directory)/1_\(before(1_000))", to: tmp.url("payload").path)
        try tmp.symlink("\(directory)/2_\(before(2_000))", to: tmp.url("payload").path)

        let size = try XCTUnwrap(try findings().first?.size)

        XCTAssertLessThan(size, 64 * 1024)
    }

    func testTheTemporaryDirectoryLocationIsScannedToo() throws {
        let stale = try link("3_\(before(1_000))", in: "tmp/fnm_multishells")

        let batch = try XCTUnwrap(try findings().first)

        XCTAssertEqual(batch.path, tmp.url("tmp/fnm_multishells"))
        XCTAssertEqual(batch.action, .trashBatch(parent: tmp.url("tmp/fnm_multishells"), entries: [stale]))
    }

    func testMissingLocationsYieldNothing() throws {
        XCTAssertEqual(try findings(), [])
    }

    func testAFileSystemErrorPropagates() throws {
        try tmp.directory(".local/state")
        try tmp.file(directory, size: 1)

        XCTAssertThrowsError(try findings())
    }
}
