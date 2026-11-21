import Foundation
import Testing
import MacUpdaterCore
import WegaHelperKit

@testable import WegaMacUpdater

/// Z14, design §4 and §7 with review R6: while this copy of Wega may not use its root helper, the
/// helper card says so, says why in words that fit the case, says how to install from the .pkg, links
/// the Releases page, and still lets the user remove a registration that is left.
@Suite("Helper card: a bundle that may not host the helper")
@MainActor
struct HelperBundleCardTests {
    private static let bundleName = "WegaMacUpdater.app"

    private func presentation(
        _ refusal: HelperBundleRefusal, status: PrivilegedHelperClient.Status = .notRegistered
    ) throws -> HelperBundleRefusalPresentation {
        try #require(HelperBundleRefusalPresentation(trust: .refused(refusal), status: status, bundleName: Self.bundleName))
    }

    @Test func aTrustedBundleShowsTheUsualCard() {
        for status in [PrivilegedHelperClient.Status.notRegistered, .requiresApproval, .enabled, .notFound, .unknown] {
            #expect(HelperBundleRefusalPresentation(trust: .trusted, status: status, bundleName: Self.bundleName) == nil)
        }
    }

    /// A registration left from this copy can still be removed; with none there is nothing to remove.
    @Test func removalIsOfferedOnlyWhileARegistrationIsThere() throws {
        #expect(try presentation(.notOwnedByRoot(.bundle), status: .enabled).offersRemoval)
        #expect(try presentation(.notOwnedByRoot(.bundle), status: .requiresApproval).offersRemoval)
        for status in [PrivilegedHelperClient.Status.notRegistered, .notFound, .unknown] {
            let card = try presentation(.notOwnedByRoot(.bundle), status: status)
            #expect(!card.offersRemoval, "\(status)")
            #expect(card.registrationNote == nil, "\(status)")
        }
        #expect(try presentation(.notOwnedByRoot(.bundle), status: .enabled).registrationNote
            == "Pomocnik jest nadal zarejestrowany. Jeśli Wega z pakietu .pkg nie jest zainstalowana na tym Macu, usuń go.")
    }

    @Test func theReasonFitsTheCase() throws {
        #expect(try presentation(.notInApplications).reason
            == "Wega nie działa z folderu /Applications (na przykład z Pobranych albo z obrazu dysku).")
        #expect(try presentation(.notOwnedByRoot(.contents)).reason
            == "Pliki Wegi nie należą do roota, tak jak po przeciągnięciu aplikacji z obrazu .dmg.")
        let changeable = "Część plików Wegi (%@) może zmienić ktoś inny niż root albo nie da się tego sprawdzić."
        let cases: [(HelperBundleRefusal, String)] = [
            (.writableByGroupOrOthers(.macOS), "Contents/MacOS"),
            (.accessControlList(.launchdPlist), "Contents/Library/LaunchDaemons/\(WegaHelper.plistName)"),
            (.symbolicLink(.contents), "Contents"),
            (.unexpectedKind(.helperExecutable), "Contents/MacOS/WegaPrivilegedHelper"),
            (.unreadable(.library), "Contents/Library"),
            (.writableByGroupOrOthers(.bundle), Self.bundleName),
        ]
        for (refusal, name) in cases {
            #expect(try presentation(refusal).reason == changeable.replacingOccurrences(of: "%@", with: name), "\(refusal)")
        }
    }

    /// Review R6: a disk image is read-only and a folder inside /Applications is still /Applications,
    /// so the location case does not claim the user's account can change the bundle.
    @Test func theExplanationFitsTheCase() throws {
        let location = try presentation(.notInApplications).explanation
        let changeable = try presentation(.notOwnedByRoot(.bundle)).explanation
        #expect(location == "Pomocnik działa jako root, a macOS uruchamia go z pakietu aplikacji. Wega używa go tylko wtedy, gdy działa bezpośrednio z folderu /Applications, z pakietu, którego nie może zmienić nikt poza rootem.")
        #expect(changeable == "Pomocnik działa jako root, a macOS uruchamia go z pakietu aplikacji. Gdy pakiet może zmienić ktoś inny niż root, może też podmienić pomocnika, więc Wega nie rejestruje go ani nie używa.")
        #expect(try presentation(.accessControlList(.macOS)).explanation == changeable)
    }

    /// RC3: the pkg installs into /Applications; a dragged copy elsewhere can go to the Trash.
    @Test func theCardSaysHowToInstallFromThePackage() throws {
        let card = try presentation(.notOwnedByRoot(.bundle))
        #expect(card.headline == "Ta kopia Wegi nie może używać pomocnika.")
        #expect(card.howTo == "Pobierz WegaMacUpdater.pkg ze strony wydań, zakończ Wegę, otwórz pakiet i przejdź instalator. Instalator umieści Wegę w /Applications jako własność roota. Potem otwórz Wegę z /Applications i zainstaluj pomocnika. Kopię przeciągniętą w inne miejsce możesz przenieść do Kosza.")
        #expect(HelperBundleRefusalPresentation.badge == "Niedostępny")
        #expect(HelperBundleRefusalPresentation.releasesButton == "Otwórz stronę wydań")
        #expect(AppEndpoints.shared.latestReleaseURL.absoluteString
            == "https://github.com/DominikSienkiewicz/WegaMacUpdater/releases/latest")
    }

    @Test func everyLineHasItsEnglishText() throws {
        try withLanguage(.en) {
            let card = try presentation(.writableByGroupOrOthers(.macOS), status: .enabled)
            #expect(card.headline == "This copy of Wega can't use the helper.")
            #expect(card.reason == "Some of Wega's files (Contents/MacOS) can be changed by someone other than root, or can't be checked.")
            #expect(card.explanation == "The helper runs as root, and macOS starts it from the app bundle. When someone other than root can change the bundle, they can replace the helper too, so Wega neither registers nor uses it.")
            #expect(card.howTo == "Download WegaMacUpdater.pkg from the Releases page, quit Wega, open the package and follow the installer. It puts Wega in /Applications, owned by root. Then open Wega from /Applications and install the helper. You can move a copy you dragged anywhere else to the Trash.")
            #expect(card.registrationNote == "A helper is still registered. If Wega from the .pkg isn't installed on this Mac, remove it.")
            #expect(try presentation(.notInApplications).reason
                == "Wega isn't running from the /Applications folder (for example, from Downloads or a disk image).")
            #expect(try presentation(.notInApplications).explanation
                == "The helper runs as root, and macOS starts it from the app bundle. Wega uses it only while it runs directly from the /Applications folder, from a bundle nobody but root can change.")
            #expect(try presentation(.notOwnedByRoot(.bundle)).reason
                == "Wega's files don't belong to root, as happens after you drag the app from the .dmg.")
            #expect(HelperBundleRefusalPresentation.badge == "Unavailable")
            #expect(HelperBundleRefusalPresentation.releasesButton == "Open Releases Page")
        }
    }

    // MARK: - The card

    /// The view is not unit tested, so its wiring is pinned: a refusal replaces the install actions,
    /// sets the badge, links the newest release and keeps **Remove Helper** while a registration is left.
    @Test func theCardShowsTheRefusalInsteadOfTheInstallActions() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/MacUpdater/InfoView.swift")
        let view = try String(contentsOf: file, encoding: .utf8)
        let compact = view.filter { !$0.isWhitespace }
        #expect(compact.contains("HelperBundleRefusalPresentation(trust:operations.helperBundleTrust,status:helperStatus,bundleName:InfoOperationsController.bundleName)"))
        #expect(compact.contains("iflethelperBundleRefusal{helperBundleRefusalSection(helperBundleRefusal)}else{helperActions}"))
        #expect(compact.contains("WegaBadge(label:HelperBundleRefusalPresentation.badge,variant:.manual)"))
        let section = try #require(view.range(of: "private func helperBundleRefusalSection("))
        let body = view[section.upperBound...].prefix(2_000)
        #expect(body.contains("AppEndpoints.shared.latestReleaseURL"))
        #expect(body.contains("if refusal.offersRemoval"))
        #expect(body.contains("Task { await removeHelper() }"))
        #expect(!body.contains("installHelper()"), "a refused bundle offers no install")
    }

    // MARK: - The controller

    /// Final review, minor 3: a refused copy never shows the usual card for a frame before the
    /// first refresh.
    @Test func aNewControllerAlreadyKnowsTheBundle() {
        let harness = Harness(trust: .refused(.notInApplications))

        let controller = InfoOperationsController(dependencies: harness.dependencies)

        #expect(controller.helperBundleTrust == .refused(.notInApplications))
    }

    @Test func theControllerReadsTheBundleWithTheRegistration() {
        let harness = Harness(trust: .refused(.notOwnedByRoot(.bundle)))
        let controller = InfoOperationsController(dependencies: harness.dependencies)

        controller.refreshPersistentState()
        #expect(controller.helperBundleTrust == .refused(.notOwnedByRoot(.bundle)))

        harness.trust = .trusted
        controller.refreshHelperStatus()
        #expect(controller.helperBundleTrust == .trusted)
    }

    @Test func installingFromARefusedBundleNeverRegisters() async {
        let harness = Harness(trust: .refused(.notInApplications))
        let controller = InfoOperationsController(dependencies: harness.dependencies)

        await controller.installHelper { _ in Issue.record("a refused bundle must not announce the helper") }

        #expect(harness.registerCalls == 0)
        #expect(controller.helperError == "Ta kopia Wegi nie może używać pomocnika. Wega nie działa z folderu /Applications (na przykład z Pobranych albo z obrazu dysku).")
        #expect(!controller.helperBusy)
    }

    @Test func installingFromATrustedBundleRegisters() async {
        let harness = Harness(trust: .trusted)
        let controller = InfoOperationsController(dependencies: harness.dependencies)

        await controller.installHelper { _ in }

        #expect(harness.registerCalls == 1)
        #expect(controller.helperError == nil)
    }

    @MainActor
    private final class Harness {
        var trust: HelperBundleTrust
        var registerCalls = 0

        init(trust: HelperBundleTrust) { self.trust = trust }

        var dependencies: InfoOperationsController.Dependencies {
            InfoOperationsController.Dependencies(
                helperStatus: { .notRegistered },
                helperBundleTrust: { self.trust },
                hasGitHubToken: { false },
                setGitHubToken: { _ in true },
                clearGitHubToken: {},
                openLoginItemsSettings: {},
                teamIDConfigured: { true },
                registerHelper: { self.registerCalls += 1 },
                authenticate: { _ in .success },
                unregisterHelper: {},
                refreshCatalog: { .updated },
                readDiagnostics: { DiagnosticsResult(brewVersion: nil, masVersion: nil) }
            )
        }
    }
}
