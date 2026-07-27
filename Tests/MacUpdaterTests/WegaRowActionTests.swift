import Testing
import Foundation
@testable import MacUpdaterCore

/// The row for Wega's own update leads to the in-app installer — signature verification, the
/// headless install and the restart all live there. Sending the user to a browser would step
/// around every one of them.
@Suite("Wega row action")
struct WegaRowActionTests {
    @Test func routesToTheSelfUpdateScreen() {
        let releaseURL = URL(string: "https://github.com/owner/repo/releases/tag/v1.2.0")!
        let source = ManualOutdatedApp.UpdateSource.wega(releaseURL: releaseURL)

        #expect(source.updateActionKind == .openSelfUpdate(releaseURL: releaseURL))
    }
}
