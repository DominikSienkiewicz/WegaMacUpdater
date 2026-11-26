import XCTest
@testable import MacUpdaterCore

final class InventoryGrowthTests: XCTestCase {
    func testInventoryCanShowWhichInstallationsGrewMostSinceThePreviousMeasurement() throws {
        let growth = try XCTUnwrap(InventorySortKey(rawValue: "diskGrowth"), "Inventory must be able to rank changes since the previous measurement.")
        XCTAssertFalse(growth.initiallyAscending)
    }
}

@MainActor
extension InventoryGrowthTests {
    private func app(_ path: String, id: String = "example.app") -> ApplicationInfo {
        ApplicationInfo(path: URL(filePath: path), name: "App", bundleIdentifier: id, version: nil,
                        installDate: nil, updateDate: nil, isManagedByBrew: false)
    }

    private func size(_ bundle: Int64, _ cache: Int64?, _ data: Int64?, library: Bool = true) -> InventoryFootprint {
        InventoryFootprint(bundleBytes: bundle, cacheBytes: cache, dataBytes: data, includesLibrary: library)
    }

    func testComparesComponentsAcrossLaunchesAndKeepsTheBaselineForTheSameInventoryRead() async throws {
        let fixture = try CleanupTempHome()
        let file = fixture.url("Measurements/latest.json")
        let firstRead = Date(timeIntervalSince1970: 1_700_000_000)
        let secondRead = firstRead.addingTimeInterval(100)
        let firstApp = app("/Applications/A.app"), secondApp = app("/Applications/B.app", id: "example.second")
        let apps = [firstApp, secondApp]
        let first = try await InventoryFootprintHistory(fileURL: file).record(
            [firstApp.installation: size(30, 10, 20), secondApp.installation: size(10, 3, 2)],
            apps: apps, readAt: firstRead, measuredAt: firstRead)
        XCTAssertNil(first.previousDate)
        XCTAssertTrue(first.saved)
        let history = InventoryFootprintHistory(fileURL: file)
        let measured = [firstApp.installation: size(25, 50, 20), secondApp.installation: size(8, 2, 1)]
        let second = try await history.record(measured, apps: apps, readAt: secondRead, measuredAt: secondRead)
        let change = try XCTUnwrap(second.changes[firstApp.installation])
        XCTAssertEqual(second.previousDate, firstRead)
        XCTAssertEqual(change.bundleBytes, -5)
        XCTAssertEqual(change.cacheBytes, 40)
        XCTAssertEqual(change.dataBytes, 0)
        XCTAssertEqual(change.totalBytes, 35)
        XCTAssertEqual(second.changes[secondApp.installation]?.totalBytes, -4)
        let repeated = try await history.record(measured, apps: apps, readAt: secondRead, measuredAt: secondRead.addingTimeInterval(1))
        XCTAssertEqual(repeated.changes, second.changes)
        let newApp = app("/Applications/New.app")
        let ranked = InventorySort.sorted([newApp, secondApp, firstApp], by: .diskGrowth, ascending: false, changes: second.changes)
        XCTAssertEqual(ranked.map(\.installation), [firstApp, secondApp, newApp].map(\.installation))
    }

    func testReplacementsMovesAndChangesInAttributionDoNotProduceFalseGrowth() async throws {
        let fixture = try CleanupTempHome()
        let history = InventoryFootprintHistory(fileURL: fixture.url("Measurements/latest.json"))
        let firstRead = Date(timeIntervalSince1970: 100)
        let replaced = app("/Applications/A.app"), shared = app("/Applications/B.app"), missing = app("/Applications/C.app")
        let moved = app("/Other/C.app"), partial = app("/Applications/D.app")
        _ = try await history.record(
            [replaced.installation: size(1, 2, 3), shared.installation: size(2, 3, 4),
             missing.installation: size(3, 4, 5), partial.installation: size(10, nil, 10)],
            apps: [replaced, shared, missing, partial], readAt: firstRead)
        let newOwner = app(replaced.path.path, id: "example.other")
        let second = try await history.record(
            [newOwner.installation: size(20, 30, 40), shared.installation: size(8, nil, nil, library: false),
             moved.installation: size(5, 6, 7), partial.installation: size(8, 10, 20)],
            apps: [newOwner, shared, moved, partial], readAt: firstRead.addingTimeInterval(1))
        XCTAssertNil(second.changes[newOwner.installation])
        XCTAssertNil(second.changes[moved.installation])
        XCTAssertNil(second.changes[shared.installation]?.totalBytes)
        XCTAssertEqual(second.changes[shared.installation]?.bundleBytes, 6)
        let difference = try XCTUnwrap(second.changes[partial.installation])
        XCTAssertEqual(difference.bundleBytes, -2)
        XCTAssertEqual(difference.dataBytes, 10)
        XCTAssertNil(difference.cacheBytes)
        XCTAssertNil(difference.totalBytes)
    }
}
