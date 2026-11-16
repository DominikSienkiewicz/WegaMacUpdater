import Foundation
import Testing
import WegaHelperKit

@testable import MacUpdaterCore

@Suite("Uninstall eligibility")
struct UninstallEligibilityTests {
    private let ownURL = URL(fileURLWithPath: "/Applications/WegaMacUpdater.app")

    private func app(_ path: String, bundleID: String? = "com.example.foo") -> ApplicationInfo {
        ApplicationInfo(
            path: URL(fileURLWithPath: path),
            name: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
            bundleIdentifier: bundleID,
            version: "1.0",
            installDate: nil,
            updateDate: nil,
            isManagedByBrew: false,
            caskToken: nil
        )
    }

    private func protection(
        _ app: ApplicationInfo,
        destination: String? = nil
    ) -> UninstallProtection? {
        UninstallEligibility.protection(
            for: app,
            ownBundleIdentifier: WegaHelper.appBundleID,
            ownBundleURL: ownURL,
            symlinkDestination: { _ in destination.map { URL(fileURLWithPath: $0) } }
        )
    }

    @Test func wegaIsProtectedByBundleIdentifier() {
        let wega = app("/Users/me/Applications/WegaMacUpdater.app", bundleID: WegaHelper.appBundleID)
        #expect(protection(wega) == .wegaItself)
    }

    @Test func wegaIsProtectedByOwnPath() {
        #expect(protection(app("/Applications/WegaMacUpdater.app", bundleID: nil)) == .wegaItself)
    }

    @Test func cryptexSafariIsASystemApplication() {
        let safari = app("/Applications/Safari.app", bundleID: "com.apple.Safari")
        #expect(protection(safari, destination: "/System/Cryptexes/App/System/Applications/Safari.app")
            == .systemApplication)
    }

    @Test func otherSymlinkIsProtected() {
        #expect(protection(app("/Applications/Foo.app"), destination: "/Volumes/Apps/Foo.app")
            == .symlink(destination: "/Volumes/Apps/Foo.app"))
    }

    @Test func ordinaryBundleIsEligible() {
        #expect(protection(app("/Applications/Foo.app")) == nil)
    }

    @Test func systemPrefixLookalikeIsEligible() {
        #expect(protection(app("/Applications/Foo.app"), destination: "/SystemTools/Foo.app")
            == .symlink(destination: "/SystemTools/Foo.app"))
    }

    @Test func removableDropsProtected() {
        let a = app("/Applications/A.app"), b = app("/Applications/B.app"), c = app("/Applications/C.app")
        let kept = UninstallEligibility.removable([a, b, c], protections: [b.id: .systemApplication])
        #expect(kept.map(\.id) == [a.id, c.id])
    }
}
