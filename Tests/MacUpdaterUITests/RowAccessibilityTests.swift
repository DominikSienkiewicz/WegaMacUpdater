import AppKit
import Foundation
import MacUpdaterCore
import SwiftUI
import Testing
@testable import WegaMacUpdater

/// UXP-21 — a row reads as one sentence, Space queues it and Return opens it, the arrows move
/// within its group, and the sidebar says what its red badge means.
@Suite("Row accessibility") @MainActor
struct RowAccessibilityTests {
    @Test func theRowReadsAsOneSentence() {
        withLanguage(.pl) {
            #expect(PackageRowAccessibility.label(name: "Slack", from: "4.47", to: "4.48", source: "Homebrew", rollback: .protected, isQueued: true)
                    == "Slack, aktualizacja 4.47 do 4.48, Homebrew, z automatycznym cofnięciem, w kolejce")
            #expect(PackageRowAccessibility.label(name: "wget", from: "1.24", to: "1.25", source: nil, rollback: nil, isQueued: false)
                    == "wget, aktualizacja 1.24 do 1.25, poza kolejką")
            #expect(PackageRowAccessibility.label(name: "Foo", from: nil, to: "2", source: nil, rollback: .unprotected(.noAppBundle), isQueued: false)
                    == "Foo, bez automatycznego cofnięcia, poza kolejką")
            #expect(PackageRowAccessibility.hint(isQueued: false) == "Spacja dodaje do kolejki, Return pokazuje szczegóły.")
            #expect(PackageRowAccessibility.hint(isQueued: true) == "Spacja usuwa z kolejki, Return pokazuje szczegóły.")
        }
        withLanguage(.en) {
            #expect(PackageRowAccessibility.label(name: "Slack", from: "4.47", to: "4.48", source: "Homebrew", rollback: .protected, isQueued: true)
                    == "Slack, update 4.47 to 4.48, Homebrew, can be undone automatically, queued")
            #expect(PackageRowAccessibility.label(name: "Foo", from: nil, to: "2", source: nil, rollback: .unprotected(.noAppBundle), isQueued: false)
                    == "Foo, can't be undone automatically, not queued")
            #expect(PackageRowAccessibility.hint(isQueued: false) == "Space adds to the queue, Return shows details.")
            #expect(PackageRowAccessibility.hint(isQueued: true) == "Space removes from the queue, Return shows details.")
            #expect(trf("Kolejka: %@", "Slack") == "Queue: Slack" && trf("Więcej działań dla %@", "Slack") == "More actions for Slack")
        }
    }

    /// The label says what the row shows: the token line when it differs from the name (two casks
    /// of one app), and the short versions rather than Homebrew's build hashes.
    @Test func theSentenceFollowsTheVisibleRow() {
        withLanguage(.pl) {
            #expect(PackageRowAccessibility.label(name: "Firefox", token: "firefox@beta", from: "1", to: "2", source: "Homebrew", rollback: nil, isQueued: false)
                    == "Firefox, firefox@beta, aktualizacja 1 do 2, Homebrew, poza kolejką")
            #expect(PackageRowAccessibility.label(
                name: "Zoom",
                from: "6.6395.1,8fc566f7b97e371bae421fc79c260de86c6a4106",
                to: "6.28899.2,155ca43c0ad5a4bd5734795688543b65b464cf47",
                source: nil, rollback: nil, isQueued: false
            ) == "Zoom, aktualizacja 6.6395.1 do 6.28899.2, poza kolejką")
        }
    }

    /// A row whose source keeps no previous version says so with a shield; the sentence says it too,
    /// unless the row already carries a rollback verdict of its own.
    @Test func theShieldIsSpokenToo() {
        withLanguage(.pl) {
            #expect(PackageRowAccessibility.label(name: "wget", from: "1", to: "2", source: "Homebrew", rollbackUnavailable: true, isQueued: false)
                    == "wget, aktualizacja 1 do 2, Homebrew, bez automatycznego cofnięcia, poza kolejką")
            #expect(PackageRowAccessibility.label(name: "Slack", from: "1", to: "2", rollback: .protected, rollbackUnavailable: true, isQueued: false)
                    == "Slack, aktualizacja 1 do 2, z automatycznym cofnięciem, poza kolejką")
        }
        withLanguage(.en) {
            #expect(PackageRowAccessibility.label(name: "wget", from: "1", to: "2", rollbackUnavailable: true, isQueued: true)
                    == "wget, update 1 to 2, can't be undone automatically, queued")
        }
    }

    /// The token is read only when it says something the name does not: case and the separators
    /// space, "-" and "_" are not news, a channel such as "@beta" is.
    @Test func theTokenIsReadOnlyWhenItAddsSomething() {
        withLanguage(.pl) {
            for (name, token) in [("Firefox", "firefox"), ("Google Chrome", "google-chrome"), ("Visual Studio Code", "visual_studio_code")] {
                #expect(PackageRowAccessibility.label(name: name, token: token, from: nil, to: nil, isQueued: false) == "\(name), poza kolejką")
            }
            #expect(PackageRowAccessibility.label(name: "Firefox", token: "firefox@beta", from: nil, to: nil, isQueued: false)
                    == "Firefox, firefox@beta, poza kolejką")
        }
    }

    @Test func focusRovesInsideAGroup() {
        let keys = ["a", "b", "c"]
        #expect(UpdateRowFocus.isTabStop("a", in: keys, focused: nil, onScreen: true))
        #expect(!UpdateRowFocus.isTabStop("b", in: keys, focused: nil, onScreen: true))
        #expect(UpdateRowFocus.isTabStop("b", in: keys, focused: "b", onScreen: true)
                && !UpdateRowFocus.isTabStop("a", in: keys, focused: "b", onScreen: true))
        #expect(UpdateRowFocus.isTabStop("a", in: keys, focused: "gone", onScreen: true),
                "a key that left the list gives the stop back to the first row")
        #expect(UpdateRowFocus.neighbour(of: "b", in: keys, direction: .down) == "c")
        #expect(UpdateRowFocus.neighbour(of: "b", in: keys, direction: .up) == "a")
        #expect(UpdateRowFocus.neighbour(of: "a", in: keys, direction: .up) == nil)
        #expect(UpdateRowFocus.neighbour(of: "c", in: keys, direction: .down) == nil)
        #expect(UpdateRowFocus.neighbour(of: "gone", in: keys, direction: .down) == nil)
    }

    /// Final review M6 — another destination covers the Updates screen, which stays mounted. Its
    /// rows must not be Tab stops then, or Tab from Logs could land on a row nobody sees and Space
    /// would queue it.
    @Test func aCoveredUpdatesScreenHasNoTabStop() {
        let keys = ["a", "b", "c"]
        for focused in [nil, "b", "gone"] as [String?] {
            for key in keys {
                #expect(!UpdateRowFocus.isTabStop(key, in: keys, focused: focused, onScreen: false), "\(key), \(String(describing: focused))")
            }
        }
    }

    /// The gate covers the rows, their ⋯ and every control on the hidden screen, while the menu
    /// commands the screen publishes (⌘R, ⌘⏎, ⌘., ⇧⌘A) stay outside it and keep working.
    @Test func aCoveredUpdatesScreenStaysMountedAndKeepsItsMenuCommands() throws {
        let detail = try source("Sources/MacUpdater/DetailColumn.swift")
        let mounted = try #require(detail.range(of: "ZStack {\n            UpdateView(")).upperBound
        let modifiers = detail[mounted...]
        for literal in [".opacity(selection.tab == .update ? 1 : 0)", ".allowsHitTesting(selection.tab == .update)",
                        ".accessibilityHidden(selection.tab != .update)", ".environment(\\.updatesOnScreen, selection.tab == .update)"] {
            #expect(modifiers.prefix(1300).contains(literal), "\(literal)")
        }

        let view = try source("Sources/MacUpdater/UpdateView.swift")
        let bodyStart = try #require(view.range(of: "    var body: some View {\n")).upperBound
        let bodyEnd = try #require(view.range(of: "    private var content: some View {")).lowerBound
        let body = view[bodyStart..<bodyEnd]
        #expect(body.hasPrefix("        content\n            .disabled(!onScreen)\n"),
                "the gate wraps the screen's content only, never the modifiers that publish its commands")
        #expect(body.components(separatedBy: ".disabled(").count == 2)
        #expect(body.components(separatedBy: ".focusedSceneValue(").count == 5, "⌘R, ⌘⏎, ⌘. and ⇧⌘A")
        #expect(view.contains("@Environment(\\.updatesOnScreen) private var onScreen"))

        let support = try source("Sources/MacUpdater/UpdateViewSupport.swift")
        #expect(support.components(separatedBy: "@Environment(\\.updatesOnScreen) private var onScreen").count == 3,
                "UpdateSection and ManualUpdateSection")
    }

    /// C2 stage 3 review — with the run's veil gone, `.disabled` alone stood between the keyboard
    /// and the rows during a run or a scan in place, and nothing proved it keeps a focusable row out
    /// of the Tab loop; a row focused before the run started still answered Space. Whatever
    /// disables the list now also takes its Tab stops away, and the rows ignore Return and Space.
    @Test func aDisabledListHasNoTabStopAndIgnoresSpaceAndReturn() throws {
        let support = try source("Sources/MacUpdater/UpdateViewSupport.swift")
        #expect(support.components(separatedBy: "@Environment(\\.isEnabled) private var isEnabled").count == 3,
                "UpdateSection and ManualUpdateSection read whether the list is enabled")
        let section = try #require(support.range(of: "struct UpdateSection: View")).upperBound
        let sectionEnd = try #require(support.range(of: "private struct UpdatePolicyMenu: View")).lowerBound
        #expect(support[section..<sectionEnd].contains(
            "isTabStop:      UpdateRowFocus.isTabStop(item.key, in: keys, focused: tabStop, onScreen: onScreen && isEnabled)"
        ), "a package row is a Tab stop only while the list is on screen and enabled")
        let manual = try #require(support.range(of: "struct ManualUpdateSection: View")).upperBound
        let manualEnd = try #require(support.range(of: "struct ManualUpdateActionView: View")).lowerBound
        let manualRows = support[manual..<manualEnd]
        #expect(manualRows.contains(
            ".focusable(onInspect != nil && UpdateRowFocus.isTabStop(key, in: keys, focused: tabStop, onScreen: onScreen && isEnabled))"
        ), "so is a manual row")
        for key in ["a", "b"] {
            #expect(!UpdateRowFocus.isTabStop(key, in: ["a", "b"], focused: key, onScreen: false), "a disabled list hands the gate false")
        }

        let shared = try source("Sources/MacUpdater/SharedViews.swift")
        let row = try #require(shared.range(of: "struct PackageRow: View")).lowerBound
        let rowEnd = try #require(shared.range(of: "// MARK: - Rollback badge", range: row..<shared.endIndex)).lowerBound
        let packageRow = shared[row..<rowEnd]
        for (rows, name, indent) in [(packageRow, "PackageRow", "            "), (manualRows, "manual row", "                    ")] {
            for key in [".return", ".space"] {
                #expect(rows.contains(".onKeyPress(\(key)) {\n\(indent)guard isEnabled else { return .ignored }"),
                        "\(name): \(key) is ignored first thing while the list is disabled")
            }
        }
    }

    /// Final review R-I2 — with the veil gone, a right-click reached „Nie aktualizuj”, „Pomiń tę
    /// wersję” and „Przypnij wersję…” behind nothing but `.disabled`. A disabled list now offers
    /// no rule menu at all, by the same signal its Tab stops and keys follow.
    @Test func aDisabledListOffersNoRuleMenu() throws {
        let support = try source("Sources/MacUpdater/UpdateViewSupport.swift")
        let gated = ".contextMenu {\n                    if isEnabled {\n                        UpdatePolicyMenu("
        #expect(support.components(separatedBy: ".contextMenu {").count == 3, "UpdateSection and ManualUpdateSection")
        #expect(support.components(separatedBy: gated).count == 3, "both menus are empty while the list is disabled")
    }

    @Test func theSidebarSaysWhatTheRedBadgeMeans() {
        #expect(SidebarBadgeCopy.text(count: 3, isDanger: true) == "⚠︎ 3" && SidebarBadgeCopy.text(count: 3, isDanger: false) == "3")
        withLanguage(.pl) {
            #expect(SidebarBadgeCopy.updatesLabel(count: 5, security: 1) == "Aktualizacje: 5, w tym 1 z możliwą poprawką bezpieczeństwa")
            #expect(SidebarBadgeCopy.updatesLabel(count: 0, security: 0) == "Aktualizacje", "no badge, no count")
        }
        withLanguage(.en) {
            #expect(SidebarBadgeCopy.updatesLabel(count: 5, security: 2) == "Updates: 5, 2 may fix security issues")
            #expect(SidebarBadgeCopy.updatesLabel(count: 5, security: 0) == "Updates: 5")
            #expect(trf("Usuń regułę dla %@", "Zoom") == "Remove rule for Zoom" && trf("Przywróć %@", "Zoom") == "Restore Zoom")
        }
    }

    @Test func theRowIsWiredForKeyboardAndVoiceOver() throws {
        let shared = try source("Sources/MacUpdater/SharedViews.swift")
        let row = try #require(shared.range(of: "struct PackageRow: View")).lowerBound
        let end = try #require(shared.range(of: "// MARK: - Rollback badge")).lowerBound
        let body = shared[row..<end]
        for literal in [".accessibilityElement(children: .contain)", ".accessibilityHint(PackageRowAccessibility.hint(isQueued: isSelected))",
                        ".accessibilityActions {", ".onKeyPress(.downArrow)", ".onKeyPress(.upArrow)",
                        ".focusable(onSelect != nil && isTabStop)", "trf(\"Kolejka: %@\", name)", "trf(\"Więcej działań dla %@\", name)",
                        ".frame(width: 28, height: 28)", ".focusable(false)", ".focusable(isTabStop)",
                        "PackageRowAccessibility.label(name: name, token: shownToken", "rollbackUnavailable: rollbackUnavailableReason != nil"] {
            #expect(body.contains(literal), "\(literal)")
        }
        #expect(!body.contains("trf(\"W kolejce: %@\", name)"))
        let actions = try #require(body.range(of: ".accessibilityActions {")).upperBound
        #expect(body[actions...].prefix(80).contains("if isEnabled {"),
                "VoiceOver's ignore and skip stand down with the ⋯ menu while a scan or a run disables the list")
        #expect(body.contains("@Environment(\\.isEnabled) private var isEnabled"))
        let support = try source("Sources/MacUpdater/UpdateViewSupport.swift")
        #expect(support.components(separatedBy: "@FocusState private var focusedKey: String?").count == 3, "UpdateSection and ManualUpdateSection")
        #expect(support.contains(".focused($focusedKey, equals: item.key)"))
        #expect(support.components(separatedBy: ".focusSection()").count == 3, "one focus section per group")
        #expect(support.components(separatedBy: ".onChange(of: focusedKey)").count == 3,
                "the stop stays on the row focus left, not on whatever focusedKey reads once focus moves on")
        #expect(try source("Sources/MacUpdater/PolicyRules.swift").contains(".accessibilityLabel(trf(\"Przywróć %@\", entry.displayName))"),
                "the spoken name starts with the visible word, so Voice Control's \"click Restore\" finds it")
    }

    /// Space on a focused ⋯ opens the menu; it must not bubble to the row and queue it.
    @Test func spaceOnTheMenuNeverQueuesTheRow() throws {
        let shared = try source("Sources/MacUpdater/SharedViews.swift")
        let row = try #require(shared.range(of: "struct PackageRow: View")).lowerBound
        let end = try #require(shared.range(of: "// MARK: - Rollback badge")).lowerBound
        let body = shared[row..<end]
        #expect(body.contains("@FocusState private var menuFocused: Bool"))
        #expect(body.contains(".focusable(isTabStop)\n                .focused($menuFocused)"))
        let space = try #require(body.range(of: ".onKeyPress(.space) {")).upperBound
        #expect(body[space...].prefix(120).contains("guard !menuFocused else { return .ignored }"))
    }

    /// Only the Tab stop is focusable, so a click has to move the stop and focus with it: otherwise
    /// Space and the arrows would still act on the row the stop was on before.
    @Test func aClickMovesTheStopAndFocus() throws {
        let support = try source("Sources/MacUpdater/UpdateViewSupport.swift")
        #expect(support.components(separatedBy: "private func focus(_ key: String) {\n        tabStop = key\n        focusedKey = key\n    }").count == 3)
        #expect(support.components(separatedBy: ".onChange(of: focusedKey) { _, key in if let key { focus(key) } }").count == 3)
        #expect(support.components(separatedBy: "focus(next)").count == 3, "move goes through focus(_:)")
        let section = try #require(support.range(of: "struct UpdateSection: View")).upperBound
        let sectionEnd = try #require(support.range(of: "private struct UpdatePolicyMenu: View")).lowerBound
        let update = support[section..<sectionEnd]
        for literal in ["onSelect:       { focus(item.key); onInspect?(item) }",
                        "isTabStop:      UpdateRowFocus.isTabStop(item.key, in: keys, focused: tabStop, onScreen: onScreen && isEnabled)",
                        "onMove:         { move(from: item.key, in: keys, $0) }"] {
            #expect(update.contains(literal), "\(literal)")
        }
        #expect(support.contains(".gesture(TapGesture().onEnded { focus(key); onInspect?(item) })"))
    }

    /// Manual rows move with the arrows and announce what Return and Space do for each row.
    @Test func manualRowsRoveToo() throws {
        let support = try source("Sources/MacUpdater/UpdateViewSupport.swift")
        let start = try #require(support.range(of: "struct ManualUpdateSection: View")).upperBound
        let end = try #require(support.range(of: "struct ManualUpdateActionView: View")).lowerBound
        let manual = support[start..<end]
        for literal in [".onKeyPress(.downArrow)", ".onKeyPress(.upArrow)", ".focused($focusedKey, equals: key)",
                        ".focusable(onInspect != nil && UpdateRowFocus.isTabStop(key, in: keys, focused: tabStop, onScreen: onScreen && isEnabled))",
                        ".accessibilityHint(isQueueable",
                        "? tr(\"Naciśnij Return, aby pokazać szczegóły, lub spację, aby zmienić kolejkę.\")",
                        ": tr(\"Naciśnij Return lub spację, aby pokazać szczegóły.\"))"] {
            #expect(manual.contains(literal), "\(literal)")
        }
    }

    @Test func theSidebarAndTheRulesUseTheirCopy() throws {
        let sidebar = try source("Sources/MacUpdater/SidebarList.swift")
        #expect(sidebar.contains("SidebarBadgeCopy.text(count: count, isDanger: isDanger)"))
        #expect(sidebar.contains(".accessibilityLabel(SidebarBadgeCopy.updatesLabel(count: appsBadge + cliBadge, security: securityBadge))"))
        let rules = try source("Sources/MacUpdater/PolicyRules.swift")
        #expect(rules.contains(".help(trf(\"Usuń regułę dla %@\", entry.displayName))"))
        let grouping = try source("Sources/MacUpdater/UpdateScopeBar.swift")
        let icon = try #require(grouping.range(of: "Image(systemName: \"list.bullet.indent\")")).upperBound
        #expect(grouping[icon...].prefix(250).contains(".accessibilityValue(selection.title)"), "the icon says which grouping is on")
    }

    private func source(_ relativePath: String, file: String = #filePath) throws -> String {
        let root = URL(fileURLWithPath: file).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
