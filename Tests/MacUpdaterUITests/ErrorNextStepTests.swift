import Foundation
import Testing
@testable import MacUpdaterCore
@testable import WegaMacUpdater

/// UXP-18 — an error banner says what to do next and leads to the log.
@Suite("Errors with a next step") @MainActor
struct ErrorNextStepTests {
    private func packageRoot(file: String = #filePath) -> URL {
        URL(fileURLWithPath: file)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: packageRoot().appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func scanStoreSources() throws -> [URL] {
        let directory = packageRoot().appendingPathComponent("Sources/MacUpdater")
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("ScanStore") && $0.pathExtension == "swift" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Every `BannerData(` call, from its anchor to the matching closing parenthesis.
    private func bannerCalls(in text: String) -> [String] {
        let characters = Array(text)
        let anchor = Array("BannerData(")
        var calls: [String] = []
        var index = 0
        while index + anchor.count <= characters.count {
            guard Array(characters[index..<index + anchor.count]) == anchor else { index += 1; continue }
            var depth = 0
            var end = index
            while end < characters.count {
                if characters[end] == "(" { depth += 1 }
                if characters[end] == ")" { depth -= 1; if depth == 0 { break } }
                end += 1
            }
            calls.append(String(characters[index..<min(end + 1, characters.count)]))
            index = end + 1
        }
        return calls
    }

    @Test func everyDangerBannerOnTheUpdatesPathOffersAnAction() throws {
        var seen = 0
        for file in try scanStoreSources() {
            for call in bannerCalls(in: try String(contentsOf: file, encoding: .utf8)) where call.contains("variant: .danger") {
                seen += 1
                #expect(call.contains("action:"), "\(file.lastPathComponent): \(call.prefix(90))")
                #expect(!call.contains(": nil)"), "\(file.lastPathComponent): a conditional action falls back to the log")
            }
        }
        #expect(seen > 10)
    }

    @Test func aFailedUpdateSaysWhatToDoNext() {
        withLanguage(.pl) {
            #expect(BannerCopy.updateFailed(names: ["Slack"]) == .init(
                message: "Nie udało się zaktualizować: Slack. Spróbuj jeszcze raz; jeśli to się powtórzy, otwórz Logi.", fullMessage: nil))
            #expect(BannerCopy.updateFailed(names: ["Slack", "Zoom", "Figma"]).fullMessage == nil, "three names fit")
            let six = BannerCopy.updateFailed(names: ["Slack", "Zoom", "A", "B", "C", "D"])
            #expect(six.message == "Nie udało się zaktualizować: Slack, Zoom i 4 inne. Spróbuj jeszcze raz; jeśli to się powtórzy, otwórz Logi.")
            #expect(six.fullMessage == "Nie udało się zaktualizować: Slack, Zoom, A, B, C, D. Spróbuj jeszcze raz; jeśli to się powtórzy, otwórz Logi.")
            #expect(BannerCopy.updateFailed(names: []).message == "Homebrew zgłosił błąd. Spróbuj jeszcze raz; jeśli to się powtórzy, otwórz Logi.")
        }
        withLanguage(.en) {
            #expect(BannerCopy.updateFailed(names: ["Slack", "Zoom", "A", "B", "C", "D"]).message
                    == "Couldn't update: Slack, Zoom and 4 more. Try again; if it happens again, open Logs.")
            #expect(tr("Pokaż w logach") == "Show in Logs" && tr("Pokaż wszystkie") == "Show All")
        }
    }

    @Test func theBannerCanShowEveryNameAndPointsToTheLog() throws {
        let callout = try source("Sources/MacUpdater/WegaCallout.swift")
        #expect(callout.contains("Button(tr(\"Pokaż wszystkie\"))"))
        #expect(callout.contains("@State private var showsAll = false"))
        let shared = try source("Sources/MacUpdater/SharedViews.swift")
        #expect(shared.contains("fullMessage: data.fullMessage"))
        #expect(shared.contains("case .openLogs:     return tr(\"Pokaż w logach\")"))
        let updating = try source("Sources/MacUpdater/ScanStore+Updating.swift")
        #expect(updating.contains("action: summary.needsSudoPassword ? .openSettings : .openLogs"))
    }
}
