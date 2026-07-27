import XCTest
@testable import MacUpdaterCore

/// ARCH-08a — `HomebrewEnvironment.environment` used to re-read `sudo_local`, probe
/// the biometry hardware and cryptographically re-verify the signed helper Mach-Os
/// on *every* brew/mas spawn. For a menu-bar app that shells out constantly this is
/// wasted disk I/O and energy. These tests pin the memoisation: a series of spawns
/// resolves the environment once, then reuses it — while a mid-session Touch ID flip
/// still takes effect because the cache is dropped when the wiring can change.
final class HomebrewEnvironmentCacheTests: XCTestCase {

    private let shim = "/tmp/wega-cache-shim-dir"
    private let askpass = "/tmp/wega-cache-askpass.sh"

    override func setUp() {
        resetEnvironmentState()
    }

    override func tearDown() {
        resetEnvironmentState()
    }

    private func resetEnvironmentState() {
        HomebrewEnvironment.touchIDStateOverride = nil
        HomebrewEnvironment.sudoShimDirectory = nil
        HomebrewEnvironment.askpassPath = nil
        HomebrewEnvironment.invalidateCache()
        HomebrewEnvironment.environmentComputeCount = 0
    }

    func testSeriesOfSpawnsResolvesTheEnvironmentExactlyOnce() {
        HomebrewEnvironment.touchIDStateOverride = .available
        HomebrewEnvironment.sudoShimDirectory = shim
        HomebrewEnvironment.askpassPath = askpass
        HomebrewEnvironment.environmentComputeCount = 0

        var spawns: [[String: String]] = []
        for _ in 0..<8 {
            spawns.append(HomebrewEnvironment.environment)
        }

        XCTAssertEqual(HomebrewEnvironment.environmentComputeCount, 1,
                       "A series of spawns must resolve the environment once, then reuse it.")
        XCTAssertTrue(spawns.allSatisfy { $0 == spawns[0] },
                      "Every reused spawn must inherit the identical cached environment.")
        XCTAssertEqual(spawns[0]["PATH"], "\(shim):\(HomebrewEnvironment.processPath)",
                       "The cached environment must still carry the resolved shim-prefixed PATH.")
    }

    func testInvalidateCacheForcesTheNextSpawnToRebuild() {
        HomebrewEnvironment.touchIDStateOverride = .available
        HomebrewEnvironment.sudoShimDirectory = shim
        HomebrewEnvironment.askpassPath = askpass
        HomebrewEnvironment.environmentComputeCount = 0

        _ = HomebrewEnvironment.environment
        _ = HomebrewEnvironment.environment
        XCTAssertEqual(HomebrewEnvironment.environmentComputeCount, 1,
                       "The second spawn must reuse the cache, not recompute.")

        HomebrewEnvironment.invalidateCache()
        _ = HomebrewEnvironment.environment
        XCTAssertEqual(HomebrewEnvironment.environmentComputeCount, 2,
                       "invalidateCache() must force the next spawn to rebuild the environment.")
    }

    func testMidSessionTouchIDEnableIsReflectedDespiteCaching() {
        HomebrewEnvironment.sudoShimDirectory = shim
        HomebrewEnvironment.askpassPath = askpass

        HomebrewEnvironment.touchIDStateOverride = .available
        let before = HomebrewEnvironment.environment
        XCTAssertTrue((before["PATH"] ?? "").hasPrefix("\(shim):"),
                      "Touch ID not yet enabled: the shim must lead PATH. Got: \(before["PATH"] ?? "")")
        XCTAssertEqual(before["SUDO_ASKPASS"], askpass)

        // The user enables Touch ID; production drops the cache via `invalidateCache()`
        // (here the override setter, which invalidates identically).
        HomebrewEnvironment.touchIDStateOverride = .enabled
        let after = HomebrewEnvironment.environment
        XCTAssertFalse((after["PATH"] ?? "").contains(shim),
                       "Enabling Touch ID must drop the shim from the rebuilt env. Got: \(after["PATH"] ?? "")")
        XCTAssertNil(after["SUDO_ASKPASS"],
                     "Enabling Touch ID must stop advertising askpass so pam_tid prompts biometrically.")
    }
}
