import Testing
import Foundation

/// UX-05 — wiring that lives in SwiftUI views the unit suite cannot instantiate headless, pinned
/// at source level exactly as `RollbackNetAfterRestoreTests` pins the REL-03 upgrade wiring.
///
/// Three acceptance criteria are guarded here:
///  1. the inspector passes the **full** trust model (path + checksum signal) for a regular cask,
///     rather than the old `path: nil, caskChecksum: nil` that always rendered `.unavailable`;
///  2. the inspector shares the list's release-notes sanitizer, so it can never show raw HTML;
///  3. the manual-update actions name their real effect instead of suggesting an install.
@Suite("InspectorTrustWiring")
struct InspectorTrustWiringTests {

    private func packageRoot(file: String = #filePath) -> URL {
        URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ name: String) throws -> String {
        try String(contentsOf: packageRoot().appendingPathComponent("Sources/MacUpdater/\(name)"),
                   encoding: .utf8)
    }

    @Test func regularCasksGetTheFullTrustModel() throws {
        let inspector = try source("InspectorPane.swift")
        #expect(!inspector.contains("TrustPanel(path: nil, caskChecksum: nil"),
                "UX-05: a regular cask must no longer probe with an always-unavailable empty model")
        #expect(inspector.contains("caskChecksumSignal(token: token, downloads: caskDownloads)"),
                "UX-05: the outdated-cask branch must resolve its checksum signal from caskDownloads")
        #expect(inspector.contains("path: item.kind == .cask ? iconPath : nil"),
                "UX-05: a regular cask must probe its resolved .app bundle, not nil")
    }

    @Test func inspectorSharesTheReleaseNotesSanitizer() throws {
        let inspector = try source("InspectorPane.swift")
        #expect(inspector.contains("ReleaseNotesText.plain(fromHTML:"),
                "UX-05: the inspector's What's-New must run notes through the shared sanitizer")
    }

    @Test func manualActionsNameTheirRealEffect() throws {
        let actions = try source("UpdateViewSupport.swift")
        #expect(actions.contains(#"tr("Otwórz aplikację")"#),
                "UX-05: the self-updating action must say it opens the app")
        #expect(actions.contains(#"tr("Otwórz stronę pobierania")"#),
                "UX-05: the vendor-page action must say it opens the download page")
        #expect(!actions.contains(#"tr("Otwórz i zaktualizuj")"#),
                "UX-05: the misleading 'open and update' label must be gone")
        #expect(!actions.contains(#"tr("Pobierz najnowszą wersję")"#),
                "UX-05: the misleading 'download the latest version' label must be gone")
        #expect(!actions.contains(#"tr("Pobierz ze strony Synology")"#),
                "UX-05: the misleading 'download from the Synology site' label must be gone")
    }
}
