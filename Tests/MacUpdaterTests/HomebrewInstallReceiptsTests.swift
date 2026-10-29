import Foundation
import Testing
@testable import MacUpdaterCore

/// Where an installed package came from is recorded by Homebrew itself, in the install
/// receipt's `source.tap` — the same record `brew doctor` reads to decide which installed
/// items an untrusted tap provides. A token that merely shares a tap's name proves nothing.
@Suite("Tap trust — reading Homebrew install receipts")
struct HomebrewInstallReceiptsTests {
    @Test func givenCaskReceiptsWhenReadThenEachCaskReportsTheTapItCameFrom() throws {
        let prefix = try Self.makePrefix()
        defer { try? FileManager.default.removeItem(at: prefix) }
        try Self.writeReceipt(tap: "homebrew/cask", at: prefix, path: "Caskroom/cmux/.metadata")
        try Self.writeReceipt(tap: "steipete/tap", at: prefix, path: "Caskroom/codexbar/.metadata")

        let installed = Set(HomebrewInstallReceipts(prefix: prefix).installedPackages())

        #expect(installed == [
            InstalledPackageOrigin(kind: .cask, name: "cmux", tap: "homebrew/cask"),
            InstalledPackageOrigin(kind: .cask, name: "codexbar", tap: "steipete/tap"),
        ])
    }

    @Test func givenFormulaKegReceiptsWhenReadThenEachFormulaReportsItsTap() throws {
        let prefix = try Self.makePrefix()
        defer { try? FileManager.default.removeItem(at: prefix) }
        try Self.writeReceipt(tap: "steipete/tap", at: prefix, path: "Cellar/peekaboo/3.0.1")
        try Self.writeReceipt(tap: "homebrew/core", at: prefix, path: "Cellar/git/2.51.0")

        let installed = Set(HomebrewInstallReceipts(prefix: prefix).installedPackages())

        #expect(installed == [
            InstalledPackageOrigin(kind: .formula, name: "peekaboo", tap: "steipete/tap"),
            InstalledPackageOrigin(kind: .formula, name: "git", tap: "homebrew/core"),
        ])
    }

    /// No receipt, an unreadable one, or one without a tap leaves the package's origin unknown;
    /// it is left out instead of being attributed to any tap.
    @Test func givenMissingOrUnreadableReceiptsWhenReadThenThosePackagesAreLeftOut() throws {
        let prefix = try Self.makePrefix()
        defer { try? FileManager.default.removeItem(at: prefix) }
        try FileManager.default.createDirectory(
            at: prefix.appendingPathComponent("Caskroom/legacy/1.0"),
            withIntermediateDirectories: true
        )
        let broken = prefix.appendingPathComponent("Cellar/broken/1.0")
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: broken.appendingPathComponent("INSTALL_RECEIPT.json"))
        try Self.writeReceipt(tap: nil, at: prefix, path: "Cellar/local/1.0")

        #expect(HomebrewInstallReceipts(prefix: prefix).installedPackages().isEmpty)
    }

    private static func makePrefix() throws -> URL {
        let prefix = FileManager.default.temporaryDirectory
            .appendingPathComponent("tap-trust-receipts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        return prefix
    }

    private static func writeReceipt(tap: String?, at prefix: URL, path: String) throws {
        let directory = prefix.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source: [String: Any] = tap.map { ["tap": $0, "version": "1.0"] } ?? ["version": "1.0"]
        let receipt: [String: Any] = ["homebrew_version": "7.0.11", "source": source]
        try JSONSerialization.data(withJSONObject: receipt)
            .write(to: directory.appendingPathComponent("INSTALL_RECEIPT.json"))
    }
}
