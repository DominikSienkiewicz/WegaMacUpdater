import XCTest
@testable import MacUpdaterCore

/// ARCH-05b regression: the cask database must be traversed once per scan to
/// build a reusable matching index — not re-scanned linearly for every
/// application.
///
/// `CountingCaskSequence` increments a counter each time it is enumerated.
/// Building the index enumerates it once; matching N applications against that
/// prebuilt index must not enumerate it again, so the count stays at 1
/// regardless of how many applications are matched.
final class CaskMatcherIndexReuseTests: XCTestCase {
    private final class CountingCaskSequence: Sequence {
        private(set) var enumerationCount = 0
        private let casks: [BrewCask]

        init(_ casks: [BrewCask]) {
            self.casks = casks
        }

        func makeIterator() -> IndexingIterator<[BrewCask]> {
            enumerationCount += 1
            return casks.makeIterator()
        }
    }

    func testDatabaseIsScannedOncePerScanNotOncePerApplication() {
        let database = (0..<500).map { BrewCask(token: "cask-\($0)", name: ["App \($0)"]) }
        let counting = CountingCaskSequence(database)
        let matcher = CaskMatcher(customMappings: [:])

        let index = matcher.makeIndex(installedCasks: [], availableCasks: counting)
        XCTAssertEqual(counting.enumerationCount, 1, "Building the index must scan the database exactly once")

        let applicationNames = (0..<200).map { "App \($0)" }
        for name in applicationNames {
            _ = matcher.match(applicationName: name, using: index)
        }

        XCTAssertEqual(
            counting.enumerationCount,
            1,
            "Matching \(applicationNames.count) applications must not re-scan the cask database"
        )
    }

    func testIndexMatchReturnsSameResultAsArrayScan() {
        let database = [
            BrewCask(token: "visual-studio-code", name: ["Visual Studio Code"]),
            BrewCask(token: "parallels", name: ["Parallels Desktop"])
        ]
        let matcher = CaskMatcher(customMappings: [:])

        for (installedCasks, applicationName) in [
            (Set<String>(["visual-studio-code"]), "Visual Studio Code"),
            ([], "Parallels Desktop"),
            ([], "Unknown Application")
        ] as [(Set<String>, String)] {
            let index = matcher.makeIndex(installedCasks: installedCasks, availableCasks: database)

            XCTAssertEqual(
                matcher.match(applicationName: applicationName, using: index),
                matcher.match(
                    applicationName: applicationName,
                    installedCasks: installedCasks,
                    availableCasks: database
                ),
                "Index-based match must equal the array-based match for \(applicationName)"
            )
        }
    }
}
