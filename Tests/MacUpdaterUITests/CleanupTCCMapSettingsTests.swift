import XCTest
import MacUpdaterCore
@testable import WegaMacUpdater

/// The Settings card for the Files and Folders map: where it sits and what it says about Full
/// Disk Access, which macOS also gives to every program Wega starts.
@MainActor
final class CleanupTCCMapSettingsTests: XCTestCase {
    func testCardFollowsTheProjectRootsCard() throws {
        let lines = try source("Sources/MacUpdater/InfoView.swift")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let rootsCard = try XCTUnwrap(lines.firstIndex(of: "CleanupProjectRootsSettingsCard()"))

        XCTAssertLessThan(rootsCard + 1, lines.count)
        XCTAssertEqual(lines[min(rootsCard + 1, lines.count - 1)], "CleanupTCCMapSettingsCard()")
    }

    func testWarningNamesWhatInheritsFullDiskAccess() throws {
        let warning = CleanupTCCMapSettingsCard.fullDiskAccessWarning

        for program in ["brew", "npm", "mas", "PATH"] {
            XCTAssertTrue(warning.contains(program), "the warning names \(program): \(warning)")
        }
        XCTAssertTrue(warning.contains("usuń Wegę"), "it says to remove Wega afterwards: \(warning)")
        XCTAssertFalse(warning.contains("tylko do odczytu TCC.db"), "never \"only to read TCC.db\"")
        let english = try XCTUnwrap(Translations.en[warning])
        for program in ["brew", "npm", "mas", "PATH"] {
            XCTAssertTrue(english.contains(program), "the English warning names \(program): \(english)")
        }
        XCTAssertFalse(english.lowercased().contains("only to read"), english)
    }

    private func source(_ relativePath: String, file: String = #filePath) throws -> String {
        let root = URL(filePath: file, directoryHint: .notDirectory)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appending(path: relativePath, directoryHint: .notDirectory), encoding: .utf8)
    }
}
