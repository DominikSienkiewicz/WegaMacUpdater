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

    @Test func realBundleUnderSystemIsASystemApplication() {
        #expect(protection(app("/System/Applications/Calculator.app")) == .systemApplication)
    }

    @Test func systemLookalikeBundlePathIsEligible() {
        #expect(protection(app("/SystemTools/Foo.app")) == nil)
    }
}

@Suite("Live symlink reader")
struct LiveSymlinkReaderTests {
    private func sandbox() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wega-symlink-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.resolvingSymlinksInPath()
    }

    private func link(_ url: URL, to target: String) throws {
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: target)
    }

    @Test func absoluteSymlinkResolvesToItsTarget() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("Real.app")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let entry = root.appendingPathComponent("Link.app")
        try link(entry, to: target.path)
        #expect(UninstallEligibility.liveSymlinkDestination(entry)?.path == target.path)
    }

    @Test func relativeSymlinkResolvesAgainstTheLinkParent() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("Real.app")
        let folder = root.appendingPathComponent("Sub")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let entry = folder.appendingPathComponent("Link.app")
        try link(entry, to: "../Real.app")
        #expect(UninstallEligibility.liveSymlinkDestination(entry)?.path == target.path)
    }

    @Test func chainResolvesAllLevels() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("Real.app")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let middle = root.appendingPathComponent("Middle.app")
        let entry = root.appendingPathComponent("Entry.app")
        try link(middle, to: target.path)
        try link(entry, to: middle.path)
        #expect(UninstallEligibility.liveSymlinkDestination(entry)?.path == target.path)
    }

    @Test func plainDirectoryIsNotASymlink() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("Plain.app")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        #expect(UninstallEligibility.liveSymlinkDestination(bundle) == nil)
    }

    @Test func brokenLinkIsStillASymlinkAndProtected() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("Missing.app")
        let entry = root.appendingPathComponent("Broken.app")
        try link(entry, to: missing.path)
        #expect(UninstallEligibility.liveSymlinkDestination(entry)?.path == missing.path)
    }

    @Test func liveProtectionFlagsAChainIntoSystem() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let middle = root.appendingPathComponent("Middle.app")
        let entry = root.appendingPathComponent("Entry.app")
        try link(middle, to: "/System/Applications/Calculator.app")
        try link(entry, to: middle.path)
        let info = ApplicationInfo(
            path: entry, name: "Entry", bundleIdentifier: "com.example.entry", version: "1",
            installDate: nil, updateDate: nil, isManagedByBrew: false, caskToken: nil
        )
        #expect(UninstallEligibility.protections(for: [info])[info.id] == .systemApplication)
    }
}
