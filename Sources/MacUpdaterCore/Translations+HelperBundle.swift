import Foundation

extension Translations {
    /// Z14 (2026-11-21): the helper only from a bundle that belongs to root — every new
    /// Polish-to-English pair of that change.
    static let helperBundle: [String: String] = [
        "wymaga pomocnika Wegi, a ta kopia Wegi nie może go używać — zainstaluj Wegę z pakietu .pkg (Ustawienia → Pomocnik Wegi).":
            "needs the Wega helper, which this copy of Wega can't use — install Wega from the .pkg (Settings → Wega helper).",
        "Ta kopia Wegi nie może używać pomocnika.": "This copy of Wega can't use the helper.",
        "Wega nie działa z folderu /Applications (na przykład z Pobranych albo z obrazu dysku).":
            "Wega isn't running from the /Applications folder (for example, from Downloads or a disk image).",
        "Pliki Wegi nie należą do roota, tak jak po przeciągnięciu aplikacji z obrazu .dmg.":
            "Wega's files don't belong to root, as happens after you drag the app from the .dmg.",
        "Część plików Wegi (%@) może zmienić ktoś inny niż root albo nie da się tego sprawdzić.":
            "Some of Wega's files (%@) can be changed by someone other than root, or can't be checked.",
        "Pomocnik działa jako root, a macOS uruchamia go z pakietu aplikacji. Wega używa go tylko wtedy, gdy działa bezpośrednio z folderu /Applications, z pakietu, którego nie może zmienić nikt poza rootem.":
            "The helper runs as root, and macOS starts it from the app bundle. Wega uses it only while it runs directly from the /Applications folder, from a bundle nobody but root can change.",
        "Pomocnik działa jako root, a macOS uruchamia go z pakietu aplikacji. Gdy pakiet może zmienić ktoś inny niż root, może też podmienić pomocnika, więc Wega nie rejestruje go ani nie używa.":
            "The helper runs as root, and macOS starts it from the app bundle. When someone other than root can change the bundle, they can replace the helper too, so Wega neither registers nor uses it.",
        "Pobierz WegaMacUpdater.pkg ze strony wydań, zakończ Wegę, otwórz pakiet i przejdź instalator. Instalator umieści Wegę w /Applications jako własność roota. Potem otwórz Wegę z /Applications i zainstaluj pomocnika. Kopię przeciągniętą w inne miejsce możesz przenieść do Kosza.":
            "Download WegaMacUpdater.pkg from the Releases page, quit Wega, open the package and follow the installer. It puts Wega in /Applications, owned by root. Then open Wega from /Applications and install the helper. You can move a copy you dragged anywhere else to the Trash.",
        "Pomocnik jest nadal zarejestrowany. Jeśli Wega z pakietu .pkg nie jest zainstalowana na tym Macu, usuń go.":
            "A helper is still registered. If Wega from the .pkg isn't installed on this Mac, remove it.",
        "Niedostępny": "Unavailable",
        "Otwórz stronę wydań": "Open Releases Page",
    ]
}
