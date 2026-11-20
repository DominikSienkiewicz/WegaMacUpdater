import AppKit
import Foundation
import SwiftUI
import Testing
import MacUpdaterCore
@testable import WegaMacUpdater

@Suite("Password prompt notice") @MainActor
struct PasswordPromptNoticeTests {
    /// C1 — at launch nothing has been probed, so the callout has nothing to draw. The probe
    /// must still run: a task on a view with no content never starts, and the warning it
    /// exists for would never appear.
    @Test func theProbeRunsWhileTheCalloutIsStillEmpty() async throws {
        PasswordPromptProbeCache.value = nil
        defer { PasswordPromptProbeCache.value = nil }
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 420, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        // Hosted the way `UpdateView.screenBody` hosts it: one child of a stack, between siblings.
        window.contentView = NSHostingView(rootView: VStack(spacing: 0) {
            Text(verbatim: "above")
            PasswordPromptCallout(queuedNeedingPassword: ["zoom"])
            Text(verbatim: "below")
        }.frame(width: 420))
        window.orderFrontRegardless()

        let deadline = Date().addingTimeInterval(5)
        while PasswordPromptProbeCache.value == nil, Date() < deadline {
            window.contentView?.layoutSubtreeIfNeeded()
            pumpMainRunLoop(for: 0.02)
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(PasswordPromptProbeCache.value != nil, "C1: the probe never ran, so the warning can never appear")
    }

    @Test func warnsOnlyWhenNothingCanAskForThePassword() {
        #expect(PasswordPromptNotice.shouldWarn(installed: false, touchID: .available, queuedNeedingPassword: ["zoom"]))
        #expect(!PasswordPromptNotice.shouldWarn(installed: true, touchID: .available, queuedNeedingPassword: ["zoom"]))
        #expect(!PasswordPromptNotice.shouldWarn(installed: false, touchID: .enabled, queuedNeedingPassword: ["zoom"]))
        #expect(!PasswordPromptNotice.shouldWarn(installed: false, touchID: .available, queuedNeedingPassword: []))
    }

    @Test func theMessageNamesTheApp() {
        #expect(PasswordPromptNotice.message(firstApp: "zoom")
                == trf("Ta kopia Wegi nie umie poprosić o hasło administratora, więc %@ się nie zaktualizuje. Zainstaluj Wegę z pliku .pkg albo włącz Touch ID.", "zoom"))
    }

    @Test func anUnprobedStateShowsNoBanner() {
        #expect(!PasswordPromptNotice.shouldWarn(probe: nil, queuedNeedingPassword: ["zoom"]))
        #expect(PasswordPromptNotice.shouldWarn(probe: PasswordPromptNotice.Probe(installed: false, touchID: .available), queuedNeedingPassword: ["zoom"]))
        #expect(!PasswordPromptNotice.shouldWarn(probe: PasswordPromptNotice.Probe(installed: false, touchID: .enabled), queuedNeedingPassword: ["zoom"]))
    }
}

/// Lets AppKit and SwiftUI process one turn of the main run loop. Synchronous on purpose:
/// `RunLoop.run(until:)` is unavailable from async contexts.
@MainActor
private func pumpMainRunLoop(for interval: TimeInterval) {
    RunLoop.main.run(until: Date().addingTimeInterval(interval))
}
