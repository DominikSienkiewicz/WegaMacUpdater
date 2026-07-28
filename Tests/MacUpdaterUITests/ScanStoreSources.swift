import Foundation

/// ARCH-08 — where `ScanStore`'s implementation is, for the tests that read it.
///
/// A dozen source-level guards inspect `ScanStore` because it lives in the app target this
/// bundle cannot import. Each of them used to name the files by hand, and several concatenated
/// two or three of them, so splitting the type by responsibility broke all of them at once and
/// every fix was a chance to point a guard at the wrong file — where it would pass on text that
/// no longer contains what it is checking for.
///
/// The same helper exists in `MacUpdaterTests`. Neither test target can import the other and
/// the package has no shared test module, so the ten lines of path discovery are duplicated
/// rather than reached for — the alternative is thirteen hand-written file lists again.
///
/// So the file list exists once per target. `everything` is the whole type as one text, which is what a
/// guard about a *behaviour* wants: behaviour does not care which extension it landed in, and a
/// guard that did care would break again on the next split. Discovery is by prefix rather than
/// a written list, so a new `ScanStore+…` file is covered the moment it exists.
enum ScanStoreSources {
    static var directory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/MacUpdater")
    }

    /// Every file holding part of `ScanStore`, sorted so the concatenation is stable between
    /// runs (a guard that asserts on ordering must not depend on the filesystem's).
    static func files() throws -> [URL] {
        try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent.hasPrefix("ScanStore") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// The type as one text.
    static func everything() throws -> String {
        try files()
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
    }
}
