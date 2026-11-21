import AppKit
import Foundation
import MacUpdaterCore

/// Z14, review RC2: removes a helper registration left from a copy Wega may not use, once at launch
/// (`HelperLeftoverRegistration`), and raises one sticky banner when the registration is gone. Nothing
/// happens while a helper installation is pending. A failed removal, or one after which the
/// registration is still there, is logged and claims nothing; the card still offers **Remove Helper**.
@MainActor
final class HelperLeftoverRegistrationCleanup: ObservableObject {
    struct Dependencies {
        var status: @MainActor () -> PrivilegedHelperClient.Status
        var ownTrust: @MainActor () -> HelperBundleTrust
        /// A helper installation is pending: its bundle may be half replaced, and the helper running it
        /// must not be booted out.
        var installationPending: @MainActor () -> Bool
        /// The gate over every copy of Wega LaunchServices knows, read off the main actor.
        var copies: @MainActor () async -> [HelperBundleTrust]
        var unregister: @MainActor () async throws -> Void

        static let live = Dependencies(
            status: { PrivilegedHelperClient.shared.status },
            ownTrust: { PrivilegedHelperClient.shared.bundleTrust },
            installationPending: { PendingHelperInstallationStore.shared.hasPending },
            copies: {
                let paths = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: AppMetadata.bundleIdentifier).map(\.path)
                return await Task.detached(priority: .utility) {
                    paths.map { HelperBundleGate.live(bundlePath: $0) }
                }.value
            },
            unregister: { try await PrivilegedHelperClient.shared.unregister() }
        )
    }

    static let shared = HelperLeftoverRegistrationCleanup(dependencies: .live)

    /// Set when a removal happened and its banner is still to be shown.
    @Published private(set) var removedRegistration = false
    private let dependencies: Dependencies

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    func run() async {
        let status = dependencies.status()
        let ownTrust = dependencies.ownTrust()
        // With no copy at all the answer is the most permissive one, so nothing is listed when it is no.
        guard HelperLeftoverRegistration.shouldUnregister(status: status, ownTrust: ownTrust, copies: []) else { return }
        guard !dependencies.installationPending() else {
            WegaLog.info(.helper, "Rejestracja pomocnika zostaje: trwa instalacja przez pomocnika (\(ownTrust.token)).")
            return
        }
        let copies = await dependencies.copies()
        guard HelperLeftoverRegistration.shouldUnregister(status: status, ownTrust: ownTrust, copies: copies) else {
            WegaLog.info(.helper, "Pomocnik zostaje zarejestrowany: inna kopia Wegi przechodzi bramkę pakietu albo nie da się jej odczytać (\(ownTrust.token)).")
            return
        }
        do {
            try await dependencies.unregister()
        } catch {
            WegaLog.error(.helper, "Nie udało się usunąć rejestracji pomocnika z niezaufanej kopii Wegi: \(error.localizedDescription)")
            return
        }
        let after = dependencies.status()
        guard after == .notRegistered || after == .notFound else {
            WegaLog.warning(.helper, "Pomocnik jest nadal zarejestrowany po próbie usunięcia z niezaufanej kopii Wegi (\(ownTrust.token)).")
            return
        }
        WegaLog.warning(.helper, "Usunięto rejestrację pomocnika z kopii Wegi, której może zmienić ktoś inny niż root (\(ownTrust.token)).")
        removedRegistration = true
    }

    /// `true` once after a removal, so its banner is raised a single time.
    func consumeNotice() -> Bool {
        guard removedRegistration else { return false }
        removedRegistration = false
        return true
    }

    static var banner: BannerData {
        BannerData(
            variant: .danger,
            title: tr("Usunęłam pomocnika Wegi"),
            message: tr("Był zarejestrowany z kopii Wegi, którą może zmienić ktoś inny niż root, a macOS uruchamia go jako root. Jeśli go potrzebujesz, zainstaluj Wegę z pakietu .pkg."),
            action: .openHelperSettings
        )
    }
}
