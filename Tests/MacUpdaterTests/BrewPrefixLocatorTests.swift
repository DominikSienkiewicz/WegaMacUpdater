import Foundation
import Testing
@testable import MacUpdaterCore

/// The install receipts live under Homebrew's prefix, which is the directory above the `bin`
/// holding the `brew` Wega runs: `/opt/homebrew` on Apple silicon, `/usr/local` on Intel.
/// Deriving it from the same located binary keeps the receipts and the commands on one
/// Homebrew installation.
@Suite("Tap trust — locating the Homebrew prefix")
struct BrewPrefixLocatorTests {
    @Test func givenAnExecutableBrewWhenLocatingThePrefixThenItIsTheDirectoryAboveBin() throws {
        let prefix = FileManager.default.temporaryDirectory
            .appendingPathComponent("brew-prefix-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: prefix) }
        let bin = prefix.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let brew = bin.appendingPathComponent("brew")
        try Data("#!/bin/sh\n".utf8).write(to: brew)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: brew.path)

        let located = BinaryLocator(brewCandidates: [brew], masCandidates: []).locateBrewPrefix()

        #expect(located?.standardizedFileURL.path == prefix.standardizedFileURL.path)
    }

    @Test func givenNoBrewWhenLocatingThePrefixThenThereIsNone() {
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/bin/brew")

        #expect(BinaryLocator(brewCandidates: [missing], masCandidates: []).locateBrewPrefix() == nil)
    }
}
