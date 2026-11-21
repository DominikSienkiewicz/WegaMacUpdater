import Foundation
import Testing
import MacUpdaterCore

@testable import WegaMacUpdater

/// Z14: when the copy of Wega the user runs may not use its root helper (its bundle fails
/// `HelperBundleGate`), a root-owned app is not promised to the helper, and the reason says what
/// helps — installing Wega from the .pkg — instead of "turn the helper on" or "reinstall it".
@Suite("Uninstall when this copy of Wega may not use the helper")
struct UninstallUntrustedBundleTests {
    private func facts(admin: Bool = true, helper: UninstallHelperAvailability) -> UninstallBundleFacts {
        UninstallBundleFacts(
            ownerUID: 0, currentUserUID: 501, isWritableByUser: false, isTopLevelInApplications: true,
            hasBundleIdentifier: true, isAdministrator: admin, helper: helper
        )
    }

    @Test func aRootOwnedAppSaysToInstallWegaFromThePackage() {
        #expect(UninstallRoute.preflight(facts(helper: .untrustedBundle)) == .blocked(.helperNeedsPackageInstall))
        #expect(UninstallRoute.afterPermissionDenied(facts(helper: .untrustedBundle)) == .blocked(.helperNeedsPackageInstall))
    }

    @Test func aStandardUserStillNeedsAnAdministratorFirst() {
        #expect(UninstallRoute.afterPermissionDenied(facts(admin: false, helper: .untrustedBundle))
            == .blocked(.needsAdministratorAccount))
    }

    /// Review R3: every availability has its own route, so a value added later cannot fall through
    /// to the helper.
    @Test func everyAvailabilityHasItsOwnRoute() {
        let expected: [UninstallHelperAvailability: UninstallRouteDecision] = [
            .notSupported: .blocked(.needsAdministratorRights),
            .off: .blocked(.needsHelper),
            .stale: .blocked(.helperNeedsReinstall),
            .untrustedBundle: .blocked(.helperNeedsPackageInstall),
            .enabled: .helper,
        ]
        for (helper, route) in expected {
            #expect(UninstallRoute.afterPermissionDenied(facts(helper: helper)) == route, "\(helper)")
        }
    }

    /// The client refuses before it connects, so nothing was sent and the app is still in place.
    @Test(arguments: [false, true])
    @MainActor func aRefusalFromTheClientSaysToInstallFromThePackage(requestSent: Bool) {
        let error = PrivilegedHelperClient.HelperError.bundleNotTrusted(.notOwnedByRoot(.bundle))

        #expect(UninstallCoordinator.helperFailure(error, requestSent: requestSent) == .blocked(.helperNeedsPackageInstall))
    }

    @Test @MainActor func theReasonNamesThePackageAndTheHelperCard() {
        let reason = UninstallResultPresentation.blockReason(.helperNeedsPackageInstall)

        #expect(reason == "wymaga pomocnika Wegi, a ta kopia Wegi nie może go używać — zainstaluj Wegę z pakietu .pkg (Ustawienia → Pomocnik Wegi).")
        #expect(reason != UninstallResultPresentation.blockReason(.needsHelper))
        #expect(reason != UninstallResultPresentation.blockReason(.helperNeedsReinstall))
        withLanguage(.en) {
            #expect(UninstallResultPresentation.blockReason(.helperNeedsPackageInstall)
                == "needs the Wega helper, which this copy of Wega can't use — install Wega from the .pkg (Settings → Wega helper).")
        }
    }

    @Test @MainActor func theResultOpensTheHelperCardOrShowsTheApp() {
        let path = URL(fileURLWithPath: "/Applications/Root.app")
        let app = ApplicationInfo(
            path: path, name: "Root", bundleIdentifier: "com.example.root", version: "1.0",
            installDate: nil, updateDate: nil, isManagedByBrew: false, caskToken: nil
        )

        #expect(UninstallResultPresentation.actions(for: .blocked(.helperNeedsPackageInstall), app: app)
            == [.openHelperSettings, .showInFinder(path)])
    }
}
