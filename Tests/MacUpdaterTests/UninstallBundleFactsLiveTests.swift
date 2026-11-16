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

        let facts = UninstallBundleFacts.live(path: bundle, hasBundleIdentifier: true)

        #expect(facts.ownerUID == getuid())
        #expect(facts.currentUserUID == getuid())
        #expect(facts.isWritableByUser)
        #expect(!facts.isTopLevelInApplications)
        #expect(facts.hasBundleIdentifier)
        #expect(facts.helper == .notSupported)
    }

    @Test func missingBundleFailsTowardABlockedRoute() {
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/Gone.app")

        let facts = UninstallBundleFacts.live(path: missing, hasBundleIdentifier: true)

        #expect(facts.ownerUID == UInt32.max)
        #expect(!facts.isWritableByUser)
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

        let facts = UninstallBundleFacts.live(path: bundle, hasBundleIdentifier: true)

        #expect(!facts.isWritableByUser)
    }
}
