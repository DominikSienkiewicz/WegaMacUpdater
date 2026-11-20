import Foundation
import Testing
import MacUpdaterCore
@testable import WegaMacUpdater

@MainActor
final class RecordingAnnouncer: AccessibilityAnnouncing {
    var texts: [String] = []
    func announce(_ text: String) { texts.append(text) }
}

@Suite("Accessibility announcements") @MainActor
struct AccessibilityAnnouncementTests {
    private func source(_ relativePath: String, file: String = #filePath) throws -> String {
        let root = URL(fileURLWithPath: file)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    @Test func aFinishedScanIsAnnounced() async {
        let announcer = RecordingAnnouncer()
        let runner = ScanStoreRuntimeProcessRunner { request in
            switch request.arguments {
            case ["update"]:
                return ProcessResult(exitCode: 0, stdout: "Already up-to-date", stderr: "")
            case ["list", "--cask", "-1"], ["outdated"]:
                return ProcessResult(exitCode: 0, stdout: "", stderr: "")
            case ["outdated", "--json=v2", "--greedy", "--greedy-latest", "--greedy-auto-updates"]:
                return ProcessResult(exitCode: 0, stdout: "{\"formulae\":[],\"casks\":[]}", stderr: "")
            case ["outdated", "-g", "--json"]:
                return ProcessResult(exitCode: 0, stdout: "{}", stderr: "")
            default:
                return ProcessResult(exitCode: 0, stdout: "", stderr: "")
            }
        }
        let harness = makeScanStoreRuntimeHarness(runner: runner, announcer: announcer)
        await LocalizedStrings.withScopedLanguage(.pl) {
            await harness.store.runCheck()
            #expect(announcer.texts.last?.hasPrefix("Skan zakończony") == true)
        }
    }

    @Test func copyHasRightNumbers() {
        LocalizedStrings.withScopedLanguage(.pl) {
            #expect(AnnouncementCopy.scanFinished(updates: 2, complete: true) == "Skan zakończony: 2 aktualizacje.")
            #expect(AnnouncementCopy.scanFinished(updates: 0, complete: false)
                    == "Skan zakończony: 0 aktualizacji. Sprawdzanie niepełne.")
            #expect(AnnouncementCopy.uninstallFinished(removed: 1) == "Odinstalowano 1 aplikację.")
            #expect(AnnouncementCopy.uninstallFinished(removed: 22) == "Odinstalowano 22 aplikacje.")
            #expect(AnnouncementCopy.uninstallFinished(removed: 12) == "Odinstalowano 12 aplikacji.")
        }
        LocalizedStrings.withScopedLanguage(.en) {
            #expect(AnnouncementCopy.runFinished(updated: 4, total: 5, needsAttention: ["Slack"])
                    == "Update finished: 4 of 5. Slack needs attention.")
            #expect(AnnouncementCopy.scanFinished(updates: 1, complete: true) == "Scan finished: 1 update.")
        }
    }

    @Test func theListStaysReadableDuringARun() throws {
        let view = try source("Sources/MacUpdater/UpdateView.swift")
        #expect(!view.contains(".accessibilityHidden(scan.updating)"))
    }
}
