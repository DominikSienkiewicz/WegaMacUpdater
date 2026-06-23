import XCTest
@testable import MacUpdaterCore

/// The Inventory window and the Updates window must never disagree about an app's
/// origin (Brew / App Store / manual). Both derive it from this ONE classifier, so a
/// brew-managed app like Docker can't show "Brew" in one window and "Ręcznie
/// zainstalowane" in the other. These tests pin that single source of truth.
final class AppOriginTests: XCTestCase {
    private func app(brew: Bool, mas: Bool) -> ApplicationInfo {
        ApplicationInfo(
            path: URL(fileURLWithPath: "/Applications/Sample.app"),
            name: "Sample",
            bundleIdentifier: "com.example.sample",
            version: "1.0",
            installDate: nil,
            updateDate: nil,
            isManagedByBrew: brew,
            caskToken: brew ? "sample" : nil,
            isManagedByMas: mas,
            masAppID: mas ? "123456" : nil
        )
    }

    func testBrewCaskAppClassifiesAsBrew() {
        XCTAssertEqual(AppOrigin.of(app(brew: true, mas: false)), .brew)
    }

    func testMasReceiptAppClassifiesAsAppStore() {
        XCTAssertEqual(AppOrigin.of(app(brew: false, mas: true)), .appStore)
    }

    func testUnmanagedAppClassifiesAsManual() {
        XCTAssertEqual(AppOrigin.of(app(brew: false, mas: false)), .manual)
    }

    // The Inventory badge shows "App Store" ahead of "Brew" when both flags are set;
    // the shared classifier must apply the same precedence so the windows agree.
    func testAppStoreTakesPrecedenceOverBrew() {
        XCTAssertEqual(AppOrigin.of(app(brew: true, mas: true)), .appStore)
    }
}
