import XCTest
import MacUpdaterCore
@testable import WegaMacUpdater

/// A Cleanup row hands one app bundle to "Odinstaluj aplikacje": only that app, and only while it
/// is selectable, starts selected.
final class UninstallSelectionPreselectionTests: XCTestCase {
    private func app(_ path: String) -> ApplicationInfo {
        let url = URL(filePath: path, directoryHint: .isDirectory)
        return ApplicationInfo(
            path: url, name: url.deletingPathExtension().lastPathComponent, bundleIdentifier: "com.example.\(url.lastPathComponent)",
            version: "1.0", installDate: nil, updateDate: nil, isManagedByBrew: false
        )
    }

    func testPreselectsTheMatchingApp() {
        let ollama = app("/Applications/Ollama.app")
        let other = app("/Applications/Other.app")
        let bundle = URL(filePath: "/Applications/Ollama.app/", directoryHint: .isDirectory)

        XCTAssertEqual(UninstallSelection.preselection(for: bundle, in: [other, ollama], protections: [:]), [ollama.id])
        XCTAssertEqual(
            UninstallSelection.preselection(
                for: URL(filePath: "/Applications/./Ollama.app", directoryHint: .isDirectory), in: [other, ollama], protections: [:]
            ),
            [ollama.id],
            "compared as standardized paths"
        )
    }

    func testProtectedOrMissingAppIsNotPreselected() {
        let ollama = app("/Applications/Ollama.app")
        let bundle = URL(filePath: "/Applications/Ollama.app/", directoryHint: .isDirectory)

        XCTAssertEqual(
            UninstallSelection.preselection(for: bundle, in: [ollama], protections: [ollama.id: .symlink(destination: "/x")]), []
        )
        XCTAssertEqual(UninstallSelection.preselection(for: bundle, in: [app("/Applications/Other.app")], protections: [:]), [])
        XCTAssertEqual(
            UninstallSelection.preselection(
                for: URL(filePath: "/Applications/Ollama", directoryHint: .isDirectory), in: [ollama], protections: [:]
            ),
            []
        )
    }
}
