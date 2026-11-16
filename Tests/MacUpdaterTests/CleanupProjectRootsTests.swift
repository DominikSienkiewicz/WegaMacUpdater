import WegaTestSupport
import XCTest
@testable import MacUpdaterCore

final class CleanupProjectRootsTests: XCTestCase {
    private let home = URL(filePath: "/Users/wega", directoryHint: .isDirectory)

    private func locationGuard(_ mounts: [String] = ["/"]) -> ProtectedLocationGuard {
        ProtectedLocationGuard(home: home, mounts: FixedMountTable(mounts))
    }

    private func folder(_ path: String) -> URL {
        URL(filePath: path, directoryHint: .isDirectory)
    }

    func testDefaultIsDevUnderHome() {
        let (defaults, teardown) = TestDefaults.isolated("cleanup-project-roots-default")
        defer { teardown() }

        XCTAssertEqual(CleanupProjectRoots.roots(from: defaults, home: home).map(\.path), ["/Users/wega/Dev"])
    }

    func testExplicitEmptyListStaysEmpty() {
        let (defaults, teardown) = TestDefaults.isolated("cleanup-project-roots-empty")
        defer { teardown() }

        XCTAssertNil(CleanupProjectRoots.add(folder("/Users/wega/code"), to: defaults, home: home, protectedLocations: locationGuard()))
        CleanupProjectRoots.remove(folder("/Users/wega/Dev"), from: defaults, home: home)
        CleanupProjectRoots.remove(folder("/Users/wega/code"), from: defaults, home: home)

        XCTAssertEqual(defaults.stringArray(forKey: CleanupProjectRoots.defaultsKey), [])
        XCTAssertEqual(CleanupProjectRoots.roots(from: defaults, home: home), [])
    }

    func testProtectedRootIsRejected() {
        let (defaults, teardown) = TestDefaults.isolated("cleanup-project-roots-protected")
        defer { teardown() }
        let locationGuard = locationGuard()

        for path in ["/Users/wega/Documents/code", "/Volumes/x", "/Users/wega", "/Users/wega/Library"] {
            XCTAssertEqual(
                CleanupProjectRoots.add(folder(path), to: defaults, home: home, protectedLocations: locationGuard),
                .protectedLocation, path
            )
        }
        let withVolume = self.locationGuard(["/", "/Volumes/x"])
        XCTAssertEqual(
            CleanupProjectRoots.add(folder("/Volumes/x/code"), to: defaults, home: home, protectedLocations: withVolume),
            .protectedLocation
        )
        XCTAssertNil(defaults.object(forKey: CleanupProjectRoots.defaultsKey), "a rejected root stores nothing")
    }

    func testDuplicateIsRejectedByComponents() {
        let (defaults, teardown) = TestDefaults.isolated("cleanup-project-roots-duplicate")
        defer { teardown() }
        let locationGuard = locationGuard()

        XCTAssertNil(CleanupProjectRoots.add(folder("/Users/wega/code"), to: defaults, home: home, protectedLocations: locationGuard))
        XCTAssertEqual(
            CleanupProjectRoots.add(folder("/Users/wega/code/"), to: defaults, home: home, protectedLocations: locationGuard),
            .alreadyListed
        )
        XCTAssertEqual(
            CleanupProjectRoots.add(folder("/Users/wega/Dev"), to: defaults, home: home, protectedLocations: locationGuard),
            .alreadyListed, "the default root counts as listed"
        )
        XCTAssertNil(CleanupProjectRoots.add(folder("/Users/wega/codex"), to: defaults, home: home, protectedLocations: locationGuard))
        XCTAssertEqual(
            CleanupProjectRoots.roots(from: defaults, home: home).map(\.path),
            ["/Users/wega/Dev", "/Users/wega/code", "/Users/wega/codex"]
        )
    }
}
