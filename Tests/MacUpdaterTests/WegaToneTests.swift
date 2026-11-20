import Foundation
import Testing
@testable import MacUpdaterCore

/// UXP-27 — Wega jokes where nothing is at stake and speaks calmly where something is: an
/// error, a changed publisher, a password prompt or a removal confirmation never carries
/// „Ups” or „Hau”.
@Suite("Wega's tone")
struct WegaToneTests {
    /// Jokes live only where nothing is at stake: a finished scan with news, a scan in progress.
    static let playful: Set<String> = ["Hau! Nowe paczki?", "Hau, ta wersja pachnie świeżo!"]

    @Test func onlyCalmMomentsJoke() {
        let polish = Set(Translations.en.keys.filter { $0.contains("Ups") || $0.contains("Hau") })
        #expect(polish == Self.playful)
        let english = Set(Translations.en.filter { $0.value.contains("Oops") || $0.value.contains("Woof") }.keys)
        #expect(english.isSubset(of: Self.playful))
    }

    @Test func noSourceSaysUps() throws {
        for file in try appSourceFiles() {
            #expect(!(try String(contentsOf: file, encoding: .utf8)).contains("\"Ups"), "\(file.lastPathComponent)")
        }
    }

    /// Every Swift file of the app target, as `LocalizationCompletenessTests.usedKeys()` reads them.
    private func appSourceFiles(file: String = #filePath) throws -> [URL] {
        let root = URL(fileURLWithPath: file)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try FileManager.default
            .contentsOfDirectory(at: root.appendingPathComponent("Sources/MacUpdater"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
    }
}
