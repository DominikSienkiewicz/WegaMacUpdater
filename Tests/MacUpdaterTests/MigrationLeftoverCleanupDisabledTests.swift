import Testing
import Foundation

/// SEC-01 regression guard: the post-migration "clean leftovers" step must not exist.
///
/// The step used to scan `~/Library` after a successful `brew install --cask` and offer
/// the *live* Application Support / Preferences / Caches / Saved State / Container of the
/// very same bundle id as "leftovers" — every entry preselected, deleted with `removeItem`
/// (permanent, bypassing the Trash the rest of the app uses), per-item failures swallowed
/// and `urls.count` reported back as the success count. That is unrecoverable data loss
/// behind a button the user was nudged towards.
///
/// The step is gone. These tests are a source-level guard because the deletion lived in a
/// `private` SwiftUI view that cannot be exercised from a unit test — so the contract is
/// stated where it can be checked: no code in the app targets builds `~/Library` deletion
/// paths, and the migration screen deletes nothing at all.
///
/// `MigrationPlanner.libraryLeftoverCandidates` deliberately stays in Core (pure path
/// construction, deletes nothing) for UX-13 to redesign this area on top of.
@Suite("MigrationLeftoverCleanupDisabled")
struct MigrationLeftoverCleanupDisabledTests {

    private func packageRoot(file: String = #filePath) -> URL {
        // <root>/Tests/MacUpdaterTests/<thisFile>.swift → up 3 = <root>
        URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func swiftSources(under relativePath: String) throws -> [(name: String, text: String)] {
        let root = packageRoot().appendingPathComponent(relativePath)
        let files = try FileManager.default
            .contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        return try files.map { (name: "\(relativePath)/\($0.lastPathComponent)",
                                text: try String(contentsOf: $0, encoding: .utf8)) }
    }

    /// Nothing in the shipped app may turn the pure candidate list into real paths on disk:
    /// with no consumer there is no code path from migration to a `~/Library` deletion.
    @Test func appTargetsHaveNoConsumerOfLibraryLeftoverCandidates() throws {
        let sources = try swiftSources(under: "Sources/MacUpdater")
            + swiftSources(under: "Sources/WegaPrivilegedHelper")
        #expect(sources.count > 10, "Sanity: the scan should see the app sources")

        let offenders = sources
            .filter { $0.text.contains("libraryLeftoverCandidates") }
            .map(\.name)
        #expect(offenders.isEmpty,
                "SEC-01: no app code may consume libraryLeftoverCandidates — found in \(offenders)")
    }

    /// The migration screen performs no filesystem deletion of any kind — neither the
    /// permanent `removeItem` the step used, nor a `trashItem` softening of it.
    @Test func migrationViewDeletesNothingFromTheFilesystem() throws {
        let text = try String(
            contentsOf: packageRoot().appendingPathComponent("Sources/MacUpdater/MigrationView.swift"),
            encoding: .utf8
        )
        #expect(!text.contains("removeItem"), "SEC-01: MigrationView must not call removeItem")
        #expect(!text.contains("trashItem"), "SEC-01: MigrationView must not delete files at all")
    }

    /// The checkbox sheet that presented active data as disposable leftovers is gone,
    /// together with the state that drove it.
    @Test func leftoverCleanupSheetIsRemoved() throws {
        let sources = try swiftSources(under: "Sources/MacUpdater")
        let banned = ["LibraryCleanupSheet", "showLibraryCleanup", "libraryLeftovers", "scanLibraryLeftovers"]
        for symbol in banned {
            let offenders = sources.filter { $0.text.contains(symbol) }.map(\.name)
            #expect(offenders.isEmpty, "SEC-01: `\(symbol)` must not exist — found in \(offenders)")
        }
    }
}
