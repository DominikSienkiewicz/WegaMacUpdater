import Testing
import Foundation
@testable import MacUpdaterCore

/// UX-06 / the self-update design: the plan decides which published asset the click is about,
/// so the button label and the code that runs can never disagree.
///
/// The asset itself is chosen on security grounds (SEC-04, `preferredAsset`) and the helper
/// does not get a vote; what `helperEnabled` decides is only whether that asset is installed
/// headlessly or handed to the user.
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

    /// SEC-04 — **the missing helper does not downgrade the channel.** This assertion was
    /// inverted before the merge: the planner used to fall back to the `.dmg` whenever it
    /// could not install headlessly, which put the most common self-update path back on a
    /// Gatekeeper-only check ("notarized by some Apple developer", not "published by Wega").
    /// Without the helper the `.pkg` is still what gets downloaded — the user simply runs it.
    @Test func withoutAHelperTheOfferedAssetIsStillThePackage() {
        let pkg = asset("Wega.pkg")
        #expect(
            SelfUpdatePlanner.action(helperEnabled: false, assets: [asset("Wega.dmg"), pkg])
                == .downloadAndOpen(asset: pkg)
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
