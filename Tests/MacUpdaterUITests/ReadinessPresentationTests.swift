import AppKit
import SwiftUI
import Testing
import MacUpdaterCore
@testable import WegaMacUpdater

@Suite("Readiness card") @MainActor
struct ReadinessPresentationTests {
    @Test func showsOnlyBeforeTheFirstRunAndOnlyWithUpdates() {
        let base = { (d: Bool, u: Bool) in ReadinessPresentation(dismissed: d, hasUpdates: u, appManagement: .unknown,
                     touchID: .available, passwordPromptInstalled: false, sudoDistrust: nil, notificationsUnanswered: true) }
        #expect(base(false, true).isVisible)
        #expect(!base(true, true).isVisible)
        #expect(!base(false, false).isVisible)
    }

    /// M5 — the privileged helper cannot answer brew's `sudo`: its XPC protocol has no such
    /// operation and `HomebrewEnvironment` never consults it. What can is Touch ID in
    /// `sudo_local` or the askpass the `.pkg` installs — the same two the callout checks.
    @Test func passwordIsReadyWithTouchIDOrTheInstalledPrompt() {
        func password(installed: Bool, touchID: TouchIDSudoConfigurator.State) -> ReadinessPresentation.Row? {
            ReadinessPresentation(dismissed: false, hasUpdates: true, appManagement: .granted, touchID: touchID,
                                  passwordPromptInstalled: installed, sudoDistrust: nil, notificationsUnanswered: false)
                .rows.first { if case .password = $0 { true } else { false } }
        }
        #expect(password(installed: false, touchID: .enabled) == .password(ready: true))
        #expect(password(installed: true, touchID: .available) == .password(ready: true))
        #expect(password(installed: false, touchID: .available) == .password(ready: false))
        #expect(password(installed: false, touchID: .notSupported) == .password(ready: false))
        #expect(!ReadinessPresentation(dismissed: false, hasUpdates: true, appManagement: .granted, touchID: .enabled,
                                       passwordPromptInstalled: false, sudoDistrust: nil, notificationsUnanswered: false)
            .rows.contains(.notifications))
    }

    /// The card's ✓ and the callout's warning answer the same question, so they can never
    /// disagree: whenever the callout would warn, the card's password row is open, and back.
    @Test(arguments: [true, false], [TouchIDSudoConfigurator.State.notSupported, .available, .enabled])
    func theCardAndTheCalloutAgree(installed: Bool, touchID: TouchIDSudoConfigurator.State) {
        let card = ReadinessPresentation(dismissed: false, hasUpdates: true, appManagement: .granted, touchID: touchID,
                                         passwordPromptInstalled: installed, sudoDistrust: nil, notificationsUnanswered: false)
        let warns = PasswordPromptNotice.shouldWarn(installed: installed, touchID: touchID, queuedNeedingPassword: ["zoom"])
        #expect(card.rows.contains(.password(ready: !warns)))
    }

    /// Owner decision 2026-11-21 — while the settings `sudo` reads cannot be trusted, Wega asks for
    /// no administrator password and the run skips what may need one, so neither Touch ID nor the
    /// `.pkg` askpass may tick the row: it says so instead, as the warning above the list does.
    @Test(arguments: [SudoPolicyDistrust.unsafePolicy(.notRegularFile), .unsafeSudoFile, .noProofOfSafety])
    func whileSudoCannotBeTrustedThePasswordRowSaysWegaWillNotAsk(distrust: SudoPolicyDistrust) {
        for installed in [true, false] {
            for touchID in [TouchIDSudoConfigurator.State.notSupported, .available, .enabled] {
                let probe = PasswordPromptNotice.Probe(installed: installed, touchID: touchID, sudoDistrust: distrust)
                #expect(PasswordPromptNotice.holdsPrompts(probe: probe, queuedNeedingPassword: ["zoom"]))
                let card = ReadinessPresentation(dismissed: false, hasUpdates: true, appManagement: .granted,
                                                 touchID: touchID, passwordPromptInstalled: installed,
                                                 sudoDistrust: distrust, notificationsUnanswered: false)
                #expect(card.rows == [.checking, .replaceApps(.granted), .passwordHeld], "\(installed), \(touchID)")
            }
        }
    }

    @Test func theHeldRowSaysWegaWillNotAskUntilTheSettingsAreRepaired() {
        withLanguage(.pl) {
            #expect(ReadinessPresentation.passwordHeldText
                    == "Nie poproszę o hasło administratora, dopóki ustawienia, które czyta sudo, nie zostaną naprawione.")
        }
        withLanguage(.en) {
            #expect(ReadinessPresentation.passwordHeldText
                    == "I won't ask for the administrator password until the settings sudo reads are repaired.")
        }
    }

    @Test func theCardAsksNothingItDoesNotNeed() {
        let p = ReadinessPresentation(dismissed: false, hasUpdates: true, appManagement: .denied,
                 touchID: .notSupported, passwordPromptInstalled: false, sudoDistrust: nil, notificationsUnanswered: true)
        #expect(p.rows == [.checking, .replaceApps(.denied), .password(ready: false), .notifications])
    }

    /// I2 — the card's height is fixed, and the frame clips. With every row present the
    /// buttons that close the card („Później”, „Wszystko jasne”) were cut off, so the fixed
    /// height has to hold the worst row set: App Management denied, Touch ID available,
    /// notifications unanswered — at the narrowest detail column and the widest, in both languages.
    /// The password row is either open or held (the longer text, owner decision 2026-11-21).
    @Test(arguments: [AppLanguage.pl, .en], [CGFloat(420), 680])
    func theWorstRowSetFitsTheFixedHeight(language: AppLanguage, detailWidth: CGFloat) {
        for password in [ReadinessPresentation.Row.password(ready: false), .passwordHeld] {
            let worst: [ReadinessPresentation.Row] = [.checking, .replaceApps(.denied), password, .notifications]
            let natural = withLanguage(language) {
                NSHostingView(rootView: ReadinessCardContent(rows: worst, touchID: .available, probing: false)
                    .padding(.horizontal, WegaLayout.listGutter)
                    .frame(width: detailWidth)).fittingSize.height
            }
            #expect(natural <= ReadinessCard.baseHeight,
                    "I2: \(language) at \(detailWidth) pt with \(password) needs \(natural) pt, the card is \(ReadinessCard.baseHeight) pt")
        }
    }
}
