import Testing
import Foundation
@testable import MacUpdaterCore

/// UX-06 / the self-update design: the plan decides which published asset the click is about,
/// so the button label and the code that runs can never disagree — and a user whose helper
/// *can* install headlessly is never sent to drag an icon instead.
@Suite("SelfUpdatePlanner")
struct SelfUpdatePlannerTests {
    private func asset(_ name: String) -> ReleaseAsset {
        ReleaseAsset(name: name, url: URL(string: "https://example.com/\(name)")!)
    }

    @Test func prefersThePackageWhenTheHelperCanInstallIt() {
        let pkg = asset("Wega.pkg")
        #expect(
            SelfUpdatePlanner.action(helperEnabled: true, assets: [asset("Wega.dmg"), pkg])
                == .install(pkg: pkg)
        )
    }

    @Test func fallsBackToTheDiskImageWithoutAHelper() {
        let dmg = asset("Wega.dmg")
        #expect(
            SelfUpdatePlanner.action(helperEnabled: false, assets: [asset("Wega.pkg"), dmg])
                == .downloadAndOpen(asset: dmg)
        )
    }

    /// Without a helper a `.pkg` is still openable — the system Installer finishes it.
    @Test func opensThePackageWhenItIsTheOnlyAsset() {
        let pkg = asset("Wega.pkg")
        #expect(
            SelfUpdatePlanner.action(helperEnabled: false, assets: [pkg])
                == .downloadAndOpen(asset: pkg)
        )
    }

    /// A helper cannot install a disk image headlessly, so the plan stays honest.
    @Test func neverInstallsADiskImageEvenWithAHelper() {
        let dmg = asset("Wega.dmg")
        #expect(
            SelfUpdatePlanner.action(helperEnabled: true, assets: [dmg])
                == .downloadAndOpen(asset: dmg)
        )
    }

    @Test func extensionMatchIsCaseInsensitive() {
        let pkg = asset("Wega.PKG")
        #expect(
            SelfUpdatePlanner.action(helperEnabled: true, assets: [pkg]) == .install(pkg: pkg)
        )
    }

    @Test func hasNoPlanWithoutAssets() {
        #expect(SelfUpdatePlanner.action(helperEnabled: true, assets: []) == nil)
    }
}
