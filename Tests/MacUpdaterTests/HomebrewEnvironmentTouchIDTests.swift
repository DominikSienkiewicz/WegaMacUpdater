import XCTest
@testable import MacUpdaterCore

/// Why this exists: the sudo PATH-shim and `SUDO_ASKPASS` were introduced for
/// the no-TTY/no-Touch-ID fallback (commit `5db8da0 Fix touch id`). They were
/// originally wired into the global `HomebrewEnvironment.environment`, which
/// inadvertently applied to brew too — and `sudo -A` (the shim's effect) makes
/// `pam_tid.so` skip biometric prompting, so a Touch-ID-enabled user trying to
/// upgrade Parallels saw the askpass *password* dialog instead of the Touch ID
/// sheet. These tests pin the corrected behaviour: when Touch ID is enabled,
/// brew's env is pristine so pam_tid prompts natively.
final class HomebrewEnvironmentTouchIDTests: XCTestCase {

    override func setUp() {
        HomebrewEnvironment.touchIDStateOverride = nil
        HomebrewEnvironment.sudoShimDirectory = "/tmp/fake-shim-dir"
        HomebrewEnvironment.askpassPath = "/tmp/fake-askpass.sh"
    }

    override func tearDown() {
        HomebrewEnvironment.touchIDStateOverride = nil
        HomebrewEnvironment.sudoShimDirectory = nil
        HomebrewEnvironment.askpassPath = nil
    }

    func testTouchIDEnabledDropsShimFromPath() {
        HomebrewEnvironment.touchIDStateOverride = .enabled
        let path = HomebrewEnvironment.environment["PATH"] ?? ""
        XCTAssertFalse(path.contains("/tmp/fake-shim-dir"),
                       "Touch ID enabled: shim must NOT be on PATH (otherwise `sudo -A` would skip pam_tid). Got: \(path)")
    }

    func testTouchIDEnabledOmitsSUDOASKPASSEnvVar() {
        HomebrewEnvironment.touchIDStateOverride = .enabled
        let env = HomebrewEnvironment.environment
        XCTAssertNil(env["SUDO_ASKPASS"],
                     "Touch ID enabled: do not advertise askpass; let sudo go through PAM (pam_tid prompts biometrically).")
    }

    func testTouchIDAvailableKeepsShimOnPath() {
        // Touch ID hardware present but not yet wired into sudo_local —
        // fall back to askpass so brew's cask hooks still survive a no-TTY
        // sudo (otherwise Zoom-style "Broken pipe" returns).
        HomebrewEnvironment.touchIDStateOverride = .available
        let path = HomebrewEnvironment.environment["PATH"] ?? ""
        XCTAssertTrue(path.hasPrefix("/tmp/fake-shim-dir:"),
                      "Touch ID available but not enabled: shim must be first on PATH. Got: \(path)")
        XCTAssertEqual(HomebrewEnvironment.environment["SUDO_ASKPASS"], "/tmp/fake-askpass.sh")
    }

    func testTouchIDNotSupportedKeepsShimOnPath() {
        HomebrewEnvironment.touchIDStateOverride = .notSupported
        let path = HomebrewEnvironment.environment["PATH"] ?? ""
        XCTAssertTrue(path.hasPrefix("/tmp/fake-shim-dir:"),
                      "No Touch ID at all: shim is the only path that lets brew's sudo succeed without a TTY. Got: \(path)")
        XCTAssertEqual(HomebrewEnvironment.environment["SUDO_ASKPASS"], "/tmp/fake-askpass.sh")
    }
}
