import AppKit
import Foundation
import MacUpdaterCore
import SwiftUI
import Testing
@testable import WegaMacUpdater

/// UXP-15 — Settings were one column of 18 cards: Touch ID was 15th, the helper 16th, and the
/// banner "Włącz Touch ID" opened the window at its top. Now five tabs hold the cards, a banner
/// opens the tab and the card it is about, and a card's own message stays under its button
/// instead of going to a Wega the Settings window does not have.
@Suite("Settings categories") @MainActor
struct SettingsCategoriesTests {
    @Test func everyCardSitsInItsCategory() throws {
        let info = try source("Sources/MacUpdater/InfoView.swift")
        let page = try #require(info.range(of: "private func page<")).upperBound
        #expect(info[page...].prefix(500).contains("unverifiedOverlayCard"), "the endpoints warning tops every tab")
        let expected: [String: [String]] = [
            "general":     ["appCard", "languageCard", "LaunchAtLoginSettingsCard()", "NotificationsSettingsCard()"],
            "checking":    ["policiesCard", "BackgroundUpdateConsentSettingsCard()", "ScanDirectoriesSettingsCard()", "ResourceGateSettingsCard()"],
            "permissions": ["privilegedHelperCard", "touchIDCard"],
            "cleanup":     ["CleanupProjectRootsSettingsCard()", "CleanupTCCMapSettingsCard()"],
            "advanced":    ["LaunchSmokeTestSettingsCard()", "CrashReportingSettingsCard()", "catalogCard", "githubTokenCard",
                            "diagnosticsCard", "environmentCard", "licensesCard"],
        ]
        for (name, cards) in expected {
            #expect(info.contains("value: SettingsTab.\(name)) { \(name)Tab }"), "\(name): the tab draws its page")
            let body = try tab(name, in: info)
            #expect(body.contains("page(.\(name)) {"), "\(name): the page knows its own tab")
            for card in cards { #expect(body.contains(card), "\(name): \(card)") }
        }
        #expect(SettingsTab.allCases.map(\.rawValue) == ["general", "checking", "permissions", "cleanup", "advanced"])
    }

    @Test func everyTabHasItsNameAndSymbol() {
        #expect(SettingsTab.allCases.map(\.systemImage)
                == ["gearshape", "arrow.triangle.2.circlepath", "lock.shield", "sparkles", "slider.horizontal.3"])
        withLanguage(.pl) {
            #expect(SettingsTab.allCases.map(\.title)
                    == ["Ogólne", "Sprawdzanie i tło", "Uprawnienia i prywatność", "Porządki", "Zaawansowane"])
        }
        withLanguage(.en) {
            #expect(SettingsTab.allCases.map(\.title)
                    == ["General", "Checking & Background", "Permissions & Privacy", "Cleanup", "Advanced"])
        }
    }

    @Test func theRouteOpensTheCardThatWasAskedFor() {
        let route = SettingsRoute()
        #expect(route.tab == .general, "Settings open on General")
        route.show(.touchID)
        #expect(route.tab == .permissions)
        #expect(route.consumeFocus(on: .general) == nil, "the page being left does not take the card")
        #expect(route.consumeFocus(on: .permissions) == .touchID)
        #expect(route.consumeFocus(on: .permissions) == nil, "consumed once")
        route.show(.selfUpdate)
        #expect(route.tab == .general)
        #expect([SettingsCard.policies, .trust, .helper].map(\.tab) == [.checking, .permissions, .permissions])
    }

    /// The page being left still hears the change, after it has disappeared. Were it to take the
    /// card, the page that holds it would open at its top.
    @Test func aBannerOpensTheCardWhileSettingsShowAnotherTab() async throws {
        let route = SettingsRoute()
        let window = host(route)
        defer { window.close() }
        try await settle(window) { visibleScrollOffset(in: window) != nil }

        route.show(.touchID)
        try await settle(window) { (visibleScrollOffset(in: window) ?? 0) > 0 }

        #expect((visibleScrollOffset(in: window) ?? 0) > 1_000, "the Touch ID card is scrolled into view")
        #expect(route.focusedCard == nil, "the card is consumed by its own page")
    }

    @Test func aWindowOpenedForACardStartsAtThatCard() async throws {
        let route = SettingsRoute()
        route.show(.touchID)
        let window = host(route)
        defer { window.close() }
        try await settle(window) { (visibleScrollOffset(in: window) ?? 0) > 0 }

        #expect((visibleScrollOffset(in: window) ?? 0) > 1_000)
        #expect(route.focusedCard == nil)
    }

    @Test func aCardThatHelpsSaysSoUnderItsOwnButton() throws {
        let info = try source("Sources/MacUpdater/InfoView.swift")
        for card in ["helper", "selfUpdate", "touchID"] {
            #expect(info.contains("relay(.\(card))"), "\(card)")
            #expect(info.contains("SettingsCardHint(text: cardHints[.\(card)])"), "\(card)")
        }
        try expectOrder(in: try slice(info, from: "private var privilegedHelperCard", to: "private var helperStatusBadge"),
                        "helperActions", "SettingsCardHint(text: cardHints[.helper])")
        try expectOrder(in: try slice(info, from: "private var appCard", to: "selfUpdateNotes"),
                        "selfUpdateRow", "SettingsCardHint(text: cardHints[.selfUpdate])")
        try expectOrder(in: try slice(info, from: "private var touchIDCard", to: "// MARK: - GitHub token"),
                        "tr(\"Włącz Touch ID dla sudo\")", "SettingsCardHint(text: cardHints[.touchID])")
        #expect(!(try source("Sources/MacUpdater/SettingsView.swift")).contains("onWegaState: { _ in"))
        withLanguage(.en) {
            #expect(tr("Zatwierdź pomocnika w Ustawieniach systemowych → Elementy logowania, potem wróć tutaj.")
                    == "Approve the helper in System Settings → Login Items, then come back here.")
        }
    }

    /// The window's minimum width, less the page's and the card's padding: the hint wraps there
    /// instead of widening the card, and draws nothing until a card has something to say.
    @Test func aHintWrapsInsideTheNarrowestCardAndNilDrawsNothing() {
        let width = WegaLayout.settingsMinWidth - 2 * 16 - 2 * 14
        let message = "Zatwierdź pomocnika w Ustawieniach systemowych → Elementy logowania, potem wróć tutaj."
        for language in [AppLanguage.pl, .en] {
            withLanguage(language) {
                let line = NSHostingView(rootView: SettingsCardHint(text: "Wega").frame(width: width)).fittingSize.height
                let hint = NSHostingView(rootView: SettingsCardHint(text: tr(message)).frame(width: width)).fittingSize
                #expect(line > 0, "\(language)")
                #expect(hint.width == width, "\(language)")
                #expect(hint.height >= 2 * line - 1, "\(language): wraps onto a second line, \(hint.height) vs \(line)")
            }
        }
        #expect(NSHostingView(rootView: SettingsCardHint(text: nil)).fittingSize.height == 0)
    }

    @Test func theTouchIDPromptsOpenTheTouchIDCard() throws {
        for file in ["ScanBannerHost", "PasswordPromptNotice", "ReadinessCard"] {
            #expect(try source("Sources/MacUpdater/\(file).swift").contains("SettingsRoute.shared.open(.touchID, with: openSettings)"), "\(file)")
        }
        #expect(try source("Sources/MacUpdater/UninstallView.swift").contains("SettingsRoute.shared.open(.helper, with: openSettings)"))
        #expect(try source("Sources/MacUpdater/UpdateViewSupport.swift").contains("SettingsRoute.shared.open(.selfUpdate, with: openSettings)"))
        #expect(try source("Sources/MacUpdater/WegaCommands.swift").contains("SettingsRoute.shared.open(.selfUpdate, with: openSettings)"))
    }

    @Test func theKnobsSpeakPlainly() {
        withLanguage(.en) {
            #expect(tr("Zapas na rozpakowanie") == "Unpacking headroom")
            #expect(tr("Zapas wolnego miejsca") == "Free-space buffer")
            #expect(tr("Głębokość podfolderów") == "Subfolder depth")
            #expect(tr("Opcjonalny token zmniejsza przerwy przez limity zapytań GitHuba. Jest w pęku kluczy.")
                    == "An optional token reduces interruptions from GitHub request limits. It is kept in the Keychain.")
            #expect(SettingsTab.checking.title == "Checking & Background")
        }
    }

    // MARK: - Helpers

    /// The body of `private var <name>Tab: some View`, up to the next `private var` or `// MARK:`.
    private func tab(_ name: String, in info: String) throws -> Substring {
        let start = try #require(info.range(of: "private var \(name)Tab: some View")).upperBound
        let rest = info[start...]
        let ends = ["private var", "// MARK:"].compactMap { rest.range(of: $0)?.lowerBound }
        return rest[..<(ends.min() ?? rest.endIndex)]
    }

    private func slice(_ text: String, from start: String, to end: String) throws -> Substring {
        let lower = try #require(text.range(of: start)).upperBound
        let upper = try #require(text[lower...].range(of: end)).lowerBound
        return text[lower..<upper]
    }

    private func expectOrder(in text: Substring, _ first: String, _ second: String) throws {
        let a = try #require(text.range(of: first), "\(first)")
        let b = try #require(text.range(of: second), "\(second)")
        #expect(a.upperBound <= b.lowerBound, "\(second) sits under \(first)")
    }

    private func host(_ route: SettingsRoute) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 480, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: TwoPages(route: route).frame(width: 480, height: 400))
        window.orderFrontRegardless()
        return window
    }

    private func settle(_ window: NSWindow, until done: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !done(), Date() < deadline {
            pump(window, for: 0.02)
            try await Task.sleep(for: .milliseconds(20))
        }
        pump(window, for: 0.1)
    }

    /// Synchronous on purpose: `RunLoop.run(until:)` is unavailable from async contexts.
    private func pump(_ window: NSWindow, for interval: TimeInterval) {
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(interval))
    }

    /// How far the scroll view on screen is scrolled; nil while none is on screen.
    private func visibleScrollOffset(in window: NSWindow) -> CGFloat? {
        func find(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView, !scroll.isHiddenOrHasHiddenAncestor { return scroll }
            return view.subviews.lazy.compactMap(find).first
        }
        return window.contentView.flatMap(find)?.contentView.bounds.origin.y
    }

    private func source(_ relativePath: String, file: String = #filePath) throws -> String {
        let root = URL(filePath: file, directoryHint: .notDirectory)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appending(path: relativePath, directoryHint: .notDirectory), encoding: .utf8)
    }
}

/// Two Settings pages the way `InfoView` draws them; the Touch ID card sits far down its page.
private struct TwoPages: View {
    @ObservedObject var route: SettingsRoute

    var body: some View {
        TabView(selection: $route.tab) {
            Tab(SettingsTab.general.title, systemImage: SettingsTab.general.systemImage, value: SettingsTab.general) {
                SettingsPage(tab: .general, route: route) { filler(0..<24) }
            }
            Tab(SettingsTab.permissions.title, systemImage: SettingsTab.permissions.systemImage, value: SettingsTab.permissions) {
                SettingsPage(tab: .permissions, route: route) {
                    filler(0..<12)
                    Color.red.frame(height: 40).id(SettingsCard.touchID)
                    filler(12..<24)
                }
            }
        }
    }

    private func filler(_ rows: Range<Int>) -> some View {
        ForEach(rows, id: \.self) { _ in Color.gray.frame(height: 100) }
    }
}
