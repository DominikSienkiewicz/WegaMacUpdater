import Foundation
import MacUpdaterCore
import Testing
@testable import WegaMacUpdater

/// UX-02 — a control that does something has to be a control.
///
/// The card replaced the selection lists' tap gestures with real `Toggle`s and `Button`s, and
/// left one behind: `HelperChip` opened **System Settings → Login Items** from a bare
/// `onTapGesture` on an `HStack`. No button role, no keyboard path, nothing for VoiceOver to
/// announce as actionable — reachable only by aiming a mouse at it, which is the whole class of
/// defect this card exists for. It is easy to miss precisely because it looks like a status
/// label, and most of the time that is exactly what it is.
///
/// So the rule is conditional, and the condition is the one `HelperChipState` already decides:
/// the chip is a `Button` when it opens something, and a plain label when it does not. A
/// disabled `Button` would be worse than either — it still announces as a button and still
/// offers a tab stop, one that leads nowhere.
@MainActor
@Suite("UX-02 — an actionable chip is a button, an inert one is a label")
struct UX02ActionableControlsTests {

    /// The state machine that decides it. Two of the three states open nothing, and the chip
    /// must not present itself as actionable in either.
    @Test func onlyTheApprovalStateOpensAnything() {
        #expect(HelperChipState.needsApproval.opensLoginItemsSettings,
                "UX-02: an approval-pending helper is the one case with somewhere to go")
        #expect(!HelperChipState.active.opensLoginItemsSettings)
        #expect(!HelperChipState.inactive.opensLoginItemsSettings)
    }

    /// The wiring, at source level: the view layer has no seam a unit test can drive, and
    /// rendering SwiftUI to inspect its accessibility tree needs a running app.
    ///
    /// Red before the fix: `HelperChip` carried `.onTapGesture` and no `Button`.
    @Test func theHelperChipOpensSettingsThroughAButtonNotATapGesture() throws {
        let chip = executableSource(try slice(read("Sources/MacUpdater/WegaViews.swift"),
                                              from: "struct HelperChip: View {",
                                              to: "// MARK: - PawPrint"))

        #expect(!chip.contains("onTapGesture"),
                """
                UX-02: HelperChip opens Login Items from a tap gesture. A gesture has no role, \
                no keyboard path and nothing to announce — it is reachable by mouse only.
                """)
        #expect(chip.contains("Button {"),
                "UX-02: the actionable branch is a real Button")
        #expect(chip.contains("if state.opensLoginItemsSettings {"),
                """
                UX-02: and only that branch — a chip with nowhere to go stays a label rather \
                than a disabled button offering a tab stop that leads nowhere.
                """)
    }

    /// The rest of the card's surface, kept honest: nothing that changes state or opens a
    /// window may hide behind a gesture. `SharedViews` keeps one deliberately — the row body's
    /// click-to-inspect, which sits beside `.focusable` + `.onKeyPress` giving it the keyboard
    /// path a gesture cannot.
    @Test func noSelectionControlIsDrivenByAGestureAlone() throws {
        var offenders: [String] = []

        for url in try appTargetSources() {
            let text = executableSource(try String(contentsOf: url, encoding: .utf8))
            guard text.contains("onTapGesture") else { continue }
            guard !text.contains("onKeyPress") else { continue }
            offenders.append(url.lastPathComponent)
        }

        #expect(offenders.isEmpty,
                """
                UX-02: \(offenders.joined(separator: ", ")) drives something from a tap gesture \
                with no keyboard equivalent anywhere in the file.
                """)
    }

    /// Rozwijanie na macOS przełącza się z samego chevronu — celu o szerokości około 12 pt,
    /// obok martwej etykiety, która wygląda na część tej samej kontrolki. `WegaDisclosure`
    /// wkłada chevron i etykietę do jednego `Button`, więc cel to cały nagłówek.
    ///
    /// Czerwony przed zmianą: `UpdateView`, `UpdateViewSupport` i `InfoView` niosły
    /// `DisclosureGroup`.
    @Test func noDisclosureGroupSurvivesInTheAppTarget() throws {
        var offenders: [String] = []

        for url in try appTargetSources() {
            let text = executableSource(try String(contentsOf: url, encoding: .utf8))
            if text.contains("DisclosureGroup(") { offenders.append(url.lastPathComponent) }
        }

        #expect(offenders.isEmpty,
                """
                UX-02: \(offenders.joined(separator: ", ")) używa DisclosureGroup, którego \
                etykieta nie jest celem kliknięcia. Użyj WegaDisclosure.
                """)
    }

    // MARK: Helpers

    private func packageRoot(file: String = #filePath) -> URL {
        URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func read(_ relativePath: String) throws -> String {
        try String(contentsOf: packageRoot().appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func appTargetSources() throws -> [URL] {
        let enumerator = FileManager.default.enumerator(
            at: packageRoot().appendingPathComponent("Sources/MacUpdater"),
            includingPropertiesForKeys: nil
        )
        var urls: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            if url.pathExtension == "swift" { urls.append(url) }
        }
        return urls
    }

    /// Comments describe; only code runs. Without this, the doc comment explaining why
    /// `HelperChip` no longer uses `onTapGesture` would itself trip the check for it.
    private func executableSource(_ text: String) -> String {
        text
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private func slice(_ text: String, from: String, to: String) throws -> String {
        let start = try #require(text.range(of: from))
        let region = text[start.lowerBound...]
        let end = try #require(region.range(of: to))
        return String(region[..<end.lowerBound])
    }
}
