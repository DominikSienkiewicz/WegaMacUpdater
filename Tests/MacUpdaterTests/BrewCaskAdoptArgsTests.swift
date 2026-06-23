import XCTest
@testable import MacUpdaterCore

/// The "Aktualizuj przez Brew" action adopts a self-updating cask whose `.app` already
/// sits in `/Applications` while its Caskroom is empty (Docker, Postman…). A plain
/// `brew install --cask <token>` bails with `Error: It seems there is already an App
/// at '/Applications/…'` AND purges the Caskroom record — corrupting brew's view of the
/// app. The adopt action must pass `--force`, which overwrites the existing app and
/// re-records it. This pins that the command carries `--force` so the regression can't
/// silently come back.
final class BrewCaskAdoptArgsTests: XCTestCase {
    func testAdoptCaskArgumentsIncludeForce() {
        XCTAssertEqual(
            BrewService.adoptCaskArguments(token: "docker-desktop"),
            ["install", "--cask", "--force", "docker-desktop"]
        )
    }

    func testAdoptCaskArgumentsCarryTheTokenLast() {
        let args = BrewService.adoptCaskArguments(token: "postman")
        XCTAssertEqual(args.last, "postman")
        XCTAssertTrue(args.contains("--force"), "adoption must overwrite the existing app")
    }
}
