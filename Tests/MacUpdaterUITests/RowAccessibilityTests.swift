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
        #expect(UpdateRowFocus.isTabStop("a", in: keys, focused: nil))
        #expect(!UpdateRowFocus.isTabStop("b", in: keys, focused: nil))
        #expect(UpdateRowFocus.isTabStop("b", in: keys, focused: "b") && !UpdateRowFocus.isTabStop("a", in: keys, focused: "b"))
        #expect(UpdateRowFocus.isTabStop("a", in: keys, focused: "gone"), "a key that left the list gives the stop back to the first row")
        #expect(UpdateRowFocus.neighbour(of: "b", in: keys, direction: .down) == "c")
        #expect(UpdateRowFocus.neighbour(of: "b", in: keys, direction: .up) == "a")
        #expect(UpdateRowFocus.neighbour(of: "a", in: keys, direction: .up) == nil)
        #expect(UpdateRowFocus.neighbour(of: "c", in: keys, direction: .down) == nil)
        #expect(UpdateRowFocus.neighbour(of: "gone", in: keys, direction: .down) == nil)
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
                        "isTabStop:      UpdateRowFocus.isTabStop(item.key, in: keys, focused: tabStop)",
                        "onMove:         { move(from: item.key, in: keys, $0) }"] {
            #expect(update.contains(literal), "\(literal)")
        }
        #expect(support.contains(".gesture(TapGesture().onEnded { focus(key); onInspect?(item) })"))
    }

    /// The manual rows keep their own hint (Return and Space both open the inspector) and move
    /// with the arrows like the package rows.
    @Test func manualRowsRoveToo() throws {
        let support = try source("Sources/MacUpdater/UpdateViewSupport.swift")
        let start = try #require(support.range(of: "struct ManualUpdateSection: View")).upperBound
        let end = try #require(support.range(of: "struct ManualUpdateActionView: View")).lowerBound
        let manual = support[start..<end]
        for literal in [".onKeyPress(.downArrow)", ".onKeyPress(.upArrow)", ".focused($focusedKey, equals: key)",
                        ".focusable(onInspect != nil && UpdateRowFocus.isTabStop(key, in: keys, focused: tabStop))",
                        ".accessibilityHint(tr(\"Naciśnij Return lub spację, aby pokazać szczegóły.\"))"] {
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
