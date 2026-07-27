import Testing
import Foundation
@testable import MacUpdaterCore
@testable import WegaMacUpdater

/// The label names the operation that will actually run. "Install" must never cover a click
/// that only downloads a disk image for the user to finish by hand.
@Suite("SelfUpdate action label")
struct SelfUpdateActionLabelTests {
    private func asset(_ name: String) -> ReleaseAsset {
        ReleaseAsset(name: name, url: URL(string: "https://example.com/\(name)")!)
    }

    @Test func installAndOpenReadDifferently() {
        let install = SelfUpdatePresentation.actionLabel(.install(pkg: asset("Wega.pkg")))
        let open = SelfUpdatePresentation.actionLabel(.downloadAndOpen(asset: asset("Wega.dmg")))

        #expect(install != open)
        #expect(!install.isEmpty)
        #expect(!open.isEmpty)
    }
}
