import Foundation
import Testing
import WegaHelperKit

@testable import MacUpdaterCore

@Suite("Live uninstall bundle facts")
struct UninstallBundleFactsLiveTests {
    @Test func ownBundleInTempIsWritableAndOwnedByCurrentUser() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bundle = dir.appendingPathComponent("Mine.app")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let facts = UninstallBundleFacts.live(path: bundle, hasBundleIdentifier: true, helper: .off)

        #expect(facts.ownerUID == getuid())
        #expect(facts.currentUserUID == getuid())
        #expect(facts.isWritableByUser)
        #expect(!facts.isTopLevelInApplications)
        #expect(facts.hasBundleIdentifier)
        #expect(facts.helper == .off)
    }

    /// The facts carry the helper's availability as the caller read it, on every inspection
    /// path; they never probe the daemon themselves.
    @Test(arguments: [UninstallHelperAvailability.enabled, .off])
    func liveFactsCarryTheHelperAvailabilityTheyAreGiven(_ helper: UninstallHelperAvailability) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bundle = dir.appendingPathComponent("Mine.app")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/Gone.app")

        #expect(UninstallBundleFacts.live(path: bundle, hasBundleIdentifier: true, helper: helper).helper == helper)
        #expect(UninstallBundleFacts.live(path: missing, hasBundleIdentifier: true, helper: helper).helper == helper)
    }

    @Test func missingBundleRoutesToUserTrashSoTheRealErrorSurfaces() {
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/Gone.app")

        let facts = UninstallBundleFacts.live(path: missing, hasBundleIdentifier: true, helper: .enabled)

        #expect(UninstallRoute.preflight(facts) == .userTrash)
    }

    @Test func otherInspectionFailureStaysFailClosed() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let underAFile = file.appendingPathComponent("Odd.app")

        let facts = UninstallBundleFacts.live(path: underAFile, hasBundleIdentifier: true, helper: .enabled)

        #expect(facts.ownerUID == UInt32.max)
        #expect(!facts.isWritableByUser)
        #expect(UninstallRoute.preflight(facts) != .userTrash)
    }

    @Test func readOnlyParentMakesTheBundleNotWritable() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bundle = dir.appendingPathComponent("Locked.app")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }

        let facts = UninstallBundleFacts.live(path: bundle, hasBundleIdentifier: true, helper: .off)

        #expect(!facts.isWritableByUser)
    }
}
