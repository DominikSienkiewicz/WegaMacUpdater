import Foundation
import Testing
import MacUpdaterCore
@testable import WegaMacUpdater

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
            #expect(announcer.texts.count == 1)
            #expect(announcer.texts.last?.hasPrefix("Skan zakończony") == true)
        }
    }

    @Test func aLightweightRescanIsNotAnnounced() async {
        let announcer = RecordingAnnouncer()
        let harness = makeScanStoreRuntimeHarness(runner: ScanStoreRuntimeProcessRunner { request in
            ProcessResult(exitCode: 0, stdout: request.arguments.contains("--json=v2")
                          ? "{\"formulae\":[],\"casks\":[]}" : "", stderr: "")
        }, announcer: announcer)
        await harness.store.runCheck(emitActivity: false, lightweight: true)
        #expect(announcer.texts.isEmpty)
    }

    @Test func stoppedRunAndNothingRemovedHaveTheirOwnCopy() {
        LocalizedStrings.withScopedLanguage(.pl) {
            #expect(AnnouncementCopy.runStopped(updated: 2, total: 5) == "Aktualizacja zatrzymana: zaktualizowano 2 z 5.")
            #expect(AnnouncementCopy.uninstallNothingRemoved() == "Nic nie odinstalowano. Szczegóły są na liście wyników.")
            #expect(AnnouncementCopy.runFinished(updated: 3, total: 5, needsAttention: ["Slack"])
                    == "Aktualizacja zakończona: 3 z 5. Slack wymaga uwagi.")
            #expect(AnnouncementCopy.runFinished(updated: 3, total: 5, needsAttention: ["Slack", "Zoom"])
                    == "Aktualizacja zakończona: 3 z 5. Slack, Zoom wymagają uwagi.")
        }
        LocalizedStrings.withScopedLanguage(.en) {
            #expect(AnnouncementCopy.runStopped(updated: 2, total: 5) == "Update stopped: 2 of 5 updated.")
            #expect(AnnouncementCopy.uninstallNothingRemoved() == "Nothing was uninstalled. Details are in the results list.")
            #expect(AnnouncementCopy.runFinished(updated: 3, total: 5, needsAttention: ["Slack", "Zoom"])
                    == "Update finished: 3 of 5. Slack, Zoom need attention.")
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

    /// M8a — the harness used to default to `LiveAccessibilityAnnouncer`, so every test that
    /// finished a scan or a run through it posted a real VoiceOver announcement.
    @Test func theHarnessNeverSpeaksThroughVoiceOver() {
        let harness = makeScanStoreRuntimeHarness(runner: ScanStoreRuntimeProcessRunner { _ in
            ProcessResult(exitCode: 0, stdout: "", stderr: "") })
        #expect(harness.store.announcer is RecordingAnnouncer)
    }

    @Test func theListStaysReadableDuringARun() throws {
        let view = try source("Sources/MacUpdater/UpdateView.swift")
        #expect(!view.contains(".accessibilityHidden(scan.updating)"))
    }
}
