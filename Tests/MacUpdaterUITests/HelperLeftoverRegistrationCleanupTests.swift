import Foundation
import Testing
import MacUpdaterCore
import WegaHelperKit

@testable import WegaMacUpdater

/// Z14, review RC2: at launch Wega removes a helper registration left from a copy it may not use,
/// unless a trusted copy may own it, and says so in a sticky banner that opens the helper card.
@Suite("Leftover helper registration: launch cleanup")
@MainActor
struct HelperLeftoverRegistrationCleanupTests {
    private static let refused = HelperBundleTrust.refused(.notOwnedByRoot(.bundle))

    @Test func aLeftoverIsRemovedAndReportedOnce() async {
        let harness = Harness(status: .enabled, ownTrust: Self.refused, copies: [Self.refused])
        let cleanup = HelperLeftoverRegistrationCleanup(dependencies: harness.dependencies)

        await cleanup.run()

        #expect(harness.unregisterCalls == 1)
        #expect(cleanup.removedRegistration)
        #expect(cleanup.consumeNotice())
        #expect(!cleanup.consumeNotice(), "the banner is raised once")
        #expect(!cleanup.removedRegistration)
    }

    @Test func aTrustedRunningCopyIsLeftAloneWithoutListingCopies() async {
        let harness = Harness(status: .enabled, ownTrust: .trusted, copies: [Self.refused])
        let cleanup = HelperLeftoverRegistrationCleanup(dependencies: harness.dependencies)

        await cleanup.run()

        #expect(harness.unregisterCalls == 0)
        #expect(harness.copyListings == 0)
        #expect(!cleanup.consumeNotice())
    }

    @Test func aRegistrationATrustedCopyMayOwnStays() async {
        let harness = Harness(status: .enabled, ownTrust: Self.refused, copies: [Self.refused, .trusted])
        let cleanup = HelperLeftoverRegistrationCleanup(dependencies: harness.dependencies)

        await cleanup.run()

        #expect(harness.unregisterCalls == 0)
        #expect(!cleanup.consumeNotice())
    }

    @Test func withoutARegistrationNothingIsListedOrRemoved() async {
        let harness = Harness(status: .notRegistered, ownTrust: Self.refused, copies: [])
        let cleanup = HelperLeftoverRegistrationCleanup(dependencies: harness.dependencies)

        await cleanup.run()

        #expect(harness.unregisterCalls == 0)
        #expect(harness.copyListings == 0)
    }

    /// Final security review, finding 1: while a helper installation is pending its bundle may be
    /// half replaced, and the helper doing it must not be booted out.
    @Test func nothingHappensWhileAHelperInstallationIsPending() async {
        let harness = Harness(status: .enabled, ownTrust: Self.refused, copies: [], installationPending: true)
        let cleanup = HelperLeftoverRegistrationCleanup(dependencies: harness.dependencies)

        await cleanup.run()

        #expect(harness.copyListings == 0)
        #expect(harness.unregisterCalls == 0)
        #expect(!cleanup.consumeNotice())
    }

    /// Final security review, finding 5: the banner is raised only when the registration is gone.
    @Test(arguments: [PrivilegedHelperClient.Status.enabled, .requiresApproval])
    func aRegistrationThatSurvivesTheRemovalRaisesNoBanner(after: PrivilegedHelperClient.Status) async {
        let harness = Harness(status: .enabled, ownTrust: Self.refused, copies: [], statusAfterUnregister: after)
        let cleanup = HelperLeftoverRegistrationCleanup(dependencies: harness.dependencies)

        await cleanup.run()

        #expect(harness.unregisterCalls == 1)
        #expect(!cleanup.consumeNotice())
    }

    /// The card still offers removal; no banner claims a removal that did not happen.
    @Test func aFailedRemovalRaisesNoBanner() async {
        let harness = Harness(status: .enabled, ownTrust: Self.refused, copies: [], unregisterFails: true)
        let cleanup = HelperLeftoverRegistrationCleanup(dependencies: harness.dependencies)

        await cleanup.run()

        #expect(harness.unregisterCalls == 1)
        #expect(!cleanup.consumeNotice())
    }

    @Test func theBannerSaysWhatHappenedAndOpensTheHelperCard() {
        let banner = HelperLeftoverRegistrationCleanup.banner
        #expect(banner.variant == .danger)
        #expect(banner.action == .openHelperSettings)
        #expect(banner.title == "Usunęłam pomocnika Wegi")
        #expect(banner.message == "Był zarejestrowany z kopii Wegi, którą może zmienić ktoś inny niż root, a macOS uruchamia go jako root. Jeśli go potrzebujesz, zainstaluj Wegę z pakietu .pkg.")
        withLanguage(.en) {
            let english = HelperLeftoverRegistrationCleanup.banner
            #expect(english.title == "I removed the Wega helper")
            #expect(english.message == "It was registered from a copy of Wega that someone other than root can change, and macOS runs it as root. If you need it, install Wega from the .pkg.")
        }
    }

    /// The launch, the banner and its action are wired where no unit test reaches.
    @Test func theCleanupRunsAtLaunchAndItsBannerOpensTheHelperCard() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func source(_ path: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8).filter { !$0.isWhitespace }
        }
        let app = try source("Sources/MacUpdater/MacUpdaterApp.swift")
        #expect(app.contains("Task{@MainActorinawaitHelperLeftoverRegistrationCleanup.shared.run()}"))
        #expect(app.contains(".onReceive(HelperLeftoverRegistrationCleanup.shared.$removedRegistration){removedin"
            + "ifremoved,HelperLeftoverRegistrationCleanup.shared.consumeNotice(){scan.showStickyBanner(HelperLeftoverRegistrationCleanup.banner)}}"))
        let host = try source("Sources/MacUpdater/ScanBannerHost.swift")
        #expect(host.contains("case.openHelperSettings:SettingsRoute.shared.open(.helper,with:openSettings)"))
    }

    @MainActor
    private final class Harness {
        private(set) var status: PrivilegedHelperClient.Status
        let ownTrust: HelperBundleTrust
        let copies: [HelperBundleTrust]
        let unregisterFails: Bool
        let installationPending: Bool
        let statusAfterUnregister: PrivilegedHelperClient.Status
        var unregisterCalls = 0
        var copyListings = 0

        init(
            status: PrivilegedHelperClient.Status, ownTrust: HelperBundleTrust, copies: [HelperBundleTrust],
            unregisterFails: Bool = false, installationPending: Bool = false,
            statusAfterUnregister: PrivilegedHelperClient.Status = .notRegistered
        ) {
            self.status = status
            self.ownTrust = ownTrust
            self.copies = copies
            self.unregisterFails = unregisterFails
            self.installationPending = installationPending
            self.statusAfterUnregister = statusAfterUnregister
        }

        var dependencies: HelperLeftoverRegistrationCleanup.Dependencies {
            HelperLeftoverRegistrationCleanup.Dependencies(
                status: { self.status },
                ownTrust: { self.ownTrust },
                installationPending: { self.installationPending },
                copies: {
                    self.copyListings += 1
                    return self.copies
                },
                unregister: {
                    self.unregisterCalls += 1
                    if self.unregisterFails { throw POSIXError(.EPERM) }
                    self.status = self.statusAfterUnregister
                }
            )
        }
    }
}
