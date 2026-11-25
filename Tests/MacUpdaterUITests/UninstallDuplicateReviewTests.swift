import Foundation
import MacUpdaterCore
import XCTest
@testable import WegaMacUpdater

final class UninstallDuplicateReviewTests: XCTestCase {
    func testVerifiedCaskLinkRoutesOnlyItsActualCopyToHomebrew() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.linkCask(to: fixture.second.path)
        let review = fixture.review()

        let first = try XCTUnwrap(review.target(for: fixture.first))
        let second = try XCTUnwrap(review.target(for: fixture.second))
        XCTAssertFalse(first.isManagedByBrew)
        XCTAssertNil(first.caskToken)
        XCTAssertTrue(second.isManagedByBrew)
        XCTAssertEqual(second.caskToken, "discord")
        XCTAssertTrue(review.stillAllows(first))

        try FileManager.default.removeItem(at: fixture.second.path)
        XCTAssertFalse(review.stillAllows(first))
    }

    func testCaskWithUninstallHooksOnlyOffersTheIndependentCopy() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.linkCask(to: fixture.first.path, hasUninstallHook: true)
        let review = fixture.review()

        XCTAssertNil(review.target(for: fixture.first))
        XCTAssertEqual(review.target(for: fixture.second)?.isManagedByBrew, false)
    }

    func testCaskLinkMustAgreeWithItsRecordedAppLocation() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.linkCask(to: fixture.first.path, declaredTarget: fixture.second.path)
        let review = fixture.review()

        XCTAssertNil(review.target(for: fixture.first))
        XCTAssertNil(review.target(for: fixture.second))
    }

    func testMissingOwnershipEvidenceNeverGuessesWhichCopyBrewWouldRemove() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let review = fixture.review()
        XCTAssertNil(review.target(for: fixture.first))
        XCTAssertNil(review.target(for: fixture.second))
    }

    private struct Fixture {
        let root: URL
        let first: ApplicationInfo
        let second: ApplicationInfo

        init() throws {
            root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
            first = try Self.bundle(at: root.appending(path: "Applications/Discord.app", directoryHint: .isDirectory))
            second = try Self.bundle(at: root.appending(path: "OtherApplications/Discord.app", directoryHint: .isDirectory))
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
        }

        func linkCask(to target: URL, declaredTarget: URL? = nil, hasUninstallHook: Bool = false) throws {
            let stage = root.appending(path: "Homebrew/Caskroom/discord/0.0.424", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
            let link = stage.appending(component: "Discord.app", directoryHint: .notDirectory)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            let metadata = stage.deletingLastPathComponent().appending(component: ".metadata", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
            var artifacts: [[String: Any]] = [["app": ["Discord.app"]]]
            if hasUninstallHook { artifacts.append(["uninstall": [["launchctl": "com.discord.discord.ShipIt"]]]) }
            try JSONSerialization.data(withJSONObject: [
                "loaded_from_api": true, "uninstall_flight_blocks": false, "uninstall_artifacts": artifacts,
            ]).write(to: metadata.appending(component: "INSTALL_RECEIPT.json", directoryHint: .notDirectory))
            try JSONSerialization.data(withJSONObject: [
                "default": ["appdir": (declaredTarget ?? target).deletingLastPathComponent().path],
            ]).write(to: metadata.appending(component: "config.json", directoryHint: .notDirectory))
        }

        func review() -> UninstallDuplicateReview {
            UninstallDuplicateReview(
                bundleIdentifier: "com.hnc.Discord", apps: [first, second], scanComplete: true,
                brewPrefix: root.appending(component: "Homebrew", directoryHint: .isDirectory)
            )
        }

        private static func bundle(at path: URL) throws -> ApplicationInfo {
            let contents = path.appending(component: "Contents", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let plist = try PropertyListSerialization.data(
                fromPropertyList: ["CFBundleIdentifier": "com.hnc.Discord"], format: .binary, options: 0
            )
            try plist.write(to: contents.appending(component: "Info.plist", directoryHint: .notDirectory))
            return ApplicationInfo(
                path: path, name: "Discord", bundleIdentifier: "com.hnc.Discord", version: "0.0.424",
                installDate: nil, updateDate: nil, isManagedByBrew: true, caskToken: "discord"
            )
        }
    }
}
