import Foundation
import MacUpdaterCore

/// Z14: what the helper card says while this copy of Wega may not use its root helper, because the
/// bundle it runs from fails `HelperBundleGate`. `nil` for a trusted bundle, whose card is unchanged.
struct HelperBundleRefusalPresentation: Equatable {
    /// A registration is still there, so the card offers **Remove Helper**.
    let offersRemoval: Bool
    let headline: String
    let reason: String
    let explanation: String
    let howTo: String
    let registrationNote: String?

    /// `bundleName` names the bundle itself when the refusal is about it; no full path is ever shown.
    init?(trust: HelperBundleTrust, status: PrivilegedHelperClient.Status, bundleName: String) {
        guard case .refused(let refusal) = trust else { return nil }
        offersRemoval = status == .enabled || status == .requiresApproval
        headline = tr("Ta kopia Wegi nie może używać pomocnika.")
        reason = Self.reason(for: refusal, bundleName: bundleName)
        explanation = refusal == .notInApplications
            ? tr("Pomocnik działa jako root, a macOS uruchamia go z pakietu aplikacji. Wega używa go tylko wtedy, gdy działa bezpośrednio z folderu /Applications, z pakietu, którego nie może zmienić nikt poza rootem.")
            : tr("Pomocnik działa jako root, a macOS uruchamia go z pakietu aplikacji. Gdy pakiet może zmienić ktoś inny niż root, może też podmienić pomocnika, więc Wega nie rejestruje go ani nie używa.")
        howTo = tr("Pobierz WegaMacUpdater.pkg ze strony wydań, zakończ Wegę, otwórz pakiet i przejdź instalator. Instalator umieści Wegę w /Applications jako własność roota. Potem otwórz Wegę z /Applications i zainstaluj pomocnika. Kopię przeciągniętą w inne miejsce możesz przenieść do Kosza.")
        registrationNote = offersRemoval
            ? tr("Pomocnik jest nadal zarejestrowany. Jeśli Wega z pakietu .pkg nie jest zainstalowana na tym Macu, usuń go.")
            : nil
    }

    static var badge: String { tr("Niedostępny") }
    static var releasesButton: String { tr("Otwórz stronę wydań") }

    /// The headline and the reason in one line, for the card's error slot.
    var summary: String { headline + " " + reason }

    private static func reason(for refusal: HelperBundleRefusal, bundleName: String) -> String {
        switch refusal {
        case .notInApplications:
            return tr("Wega nie działa z folderu /Applications (na przykład z Pobranych albo z obrazu dysku).")
        case .notOwnedByRoot:
            return tr("Pliki Wegi nie należą do roota, tak jak po przeciągnięciu aplikacji z obrazu .dmg.")
        case .otherVolume(let entry), .ownershipIgnored(let entry):
            return trf(
                "Część plików Wegi (%@) leży na innym woluminie niż folder /Applications albo na woluminie, który pomija właścicieli plików.",
                name(of: entry, bundleName: bundleName)
            )
        case .unreadable(let entry), .symbolicLink(let entry), .unexpectedKind(let entry),
             .writableByGroupOrOthers(let entry), .accessControlList(let entry):
            return trf(
                "Część plików Wegi (%@) może zmienić ktoś inny niż root albo nie da się tego sprawdzić.",
                name(of: entry, bundleName: bundleName)
            )
        }
    }

    private static func name(of entry: HelperBundleEntry, bundleName: String) -> String {
        entry.relativePath.isEmpty ? bundleName : entry.relativePath
    }
}
