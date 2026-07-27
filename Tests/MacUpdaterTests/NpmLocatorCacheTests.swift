import XCTest
@testable import MacUpdaterCore

/// ARCH-03: the resolved npm location is cached for the scan, so repeated lookups do
/// not re-scan the candidate list (which is where the nvm/fnm directory globs and the
/// login-shell fallback live).
final class NpmLocatorCacheTests: XCTestCase {
    func testLocateCachesResolvedPathAndSkipsResolutionOnSecondCall() {
        // The only executable is an extra candidate, which sits after the built-in
        // candidates — so a full resolve must probe several paths, while a cache hit
        // re-validates exactly one.
        let npm = URL(fileURLWithPath: "/tmp/wega-fake-npm")
        let fileManager = ExecutableCountingFileManager(executablePath: npm.path)
        let locator = NpmLocator(fileManager: fileManager, extraCandidates: [npm])

        XCTAssertEqual(locator.locate(), npm)
        let checksAfterFirstResolve = fileManager.executableCheckCount
        XCTAssertGreaterThan(checksAfterFirstResolve, 1, "first resolve scans multiple candidates")

        XCTAssertEqual(locator.locate(), npm)
        XCTAssertEqual(
            fileManager.executableCheckCount - checksAfterFirstResolve,
            1,
            "a cache hit re-validates the cached path once instead of re-scanning candidates"
        )
    }

    func testLocateReresolvesWhenCachedBinaryMoves() {
        // Both paths are built-in npm candidates, so re-resolution stays deterministic
        // (no login shell): once the cached binary stops being executable, a fresh
        // resolve finds the moved one instead of returning the stale path.
        let fileManager = ExecutableCountingFileManager(executablePath: "/opt/homebrew/bin/npm")
        let locator = NpmLocator(fileManager: fileManager)

        XCTAssertEqual(locator.locate(), URL(fileURLWithPath: "/opt/homebrew/bin/npm"))

        fileManager.executablePath = "/usr/local/bin/npm"
        XCTAssertEqual(locator.locate(), URL(fileURLWithPath: "/usr/local/bin/npm"))
    }
}

/// A `FileManager` whose executable check is fully controlled and counted, so npm
/// resolution is deterministic and a test can tell a cache hit (one check) apart from
/// a full re-scan of the candidate list (several).
private final class ExecutableCountingFileManager: FileManager, @unchecked Sendable {
    var executablePath: String?
    private(set) var executableCheckCount = 0

    init(executablePath: String?) {
        self.executablePath = executablePath
        super.init()
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func isExecutableFile(atPath path: String) -> Bool {
        executableCheckCount += 1
        return path == executablePath
    }
}
