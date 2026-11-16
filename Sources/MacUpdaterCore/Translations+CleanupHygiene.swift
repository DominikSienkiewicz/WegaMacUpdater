import Foundation

extension Translations {
    static let cleanupHygiene: [String: String] = [
        "martwy wpis": "dead entry",
        "higiena PATH": "PATH hygiene",
        "mapa „Pliki i foldery”": "Files and Folders map",

        "ten katalog nie istnieje albo nie jest katalogiem, więc nic w nim nie szukamy":
            "this directory does not exist or is not a directory, so nothing is looked up in it",
        "ten sam wpis występuje w PATH %@ razy; liczy się pierwszy":
            "this entry appears in PATH %@ times; the first one counts",
        "to samo miejsce co wcześniejszy wpis %@": "the same place as the earlier entry %@",
        "leży wewnątrz katalogu %@, który też jest w PATH": "lies inside %@, which is also in PATH",
        "aktywna jest wersja %@, a przesłonięta kopia %@ ma nowszą wersję %@":
            "version %@ is the active one, while the shadowed copy %@ has the newer version %@",
        "wpis w „Pliki i foldery”: %@": "Files and Folders entry: %@",
        "wpis w „Pliki i foldery” (%@) wskazuje plik, którego już nie ma":
            "the Files and Folders entry (%@) points at a file that no longer exists",
        "dotyczy aktywnej kopii": "belongs to the active copy",
        "dotyczy kopii do usunięcia": "belongs to a copy that can go",
        "dotyczy kopii, która zostaje": "belongs to a copy that stays",
        "dotyczy kopii aplikacji %@": "belongs to the %@ app's copy",
        "%@ (zezwolono)": "%@ (allowed)",
        "%@ (odmówiono)": "%@ (denied)",
        "Pulpit": "Desktop",
        "Dokumenty": "Documents",
        "Pobrane": "Downloads",
        "woluminy sieciowe": "network volumes",
        "woluminy wymienne": "removable volumes",
        "Pełny dostęp do dysku": "Full Disk Access",

        "Wpisu %@ nie ma w plikach powłoki, które sprawdza Wega. Dodał go prawdopodobnie eval, dołączony plik, menedżer wtyczek albo ZDOTDIR.":
            "%@ is not in the shell files Wega checks. It was most likely added dynamically by eval, a sourced file, a plugin manager or ZDOTDIR.",
        "Usuń wpis %@ z pliku powłoki, który go dodaje: %@.": "Remove the %@ entry from the shell file that adds it: %@.",
        "Wyłącz ten wpis w Ustawieniach systemowych → Prywatność i ochrona → Pliki i foldery.":
            "Switch this entry off in System Settings → Privacy & Security → Files and Folders.",

        "Wega nie mogła odczytać bazy zgód. Brakuje jej Pełnego dostępu do dysku albo pliku bazy nie ma, więc mapy „Pliki i foldery” nie ma w raporcie.":
            "Wega could not read the permissions database. It lacks Full Disk Access or the database file is missing, so the Files and Folders map is not in the report.",
        "Baza zgód ma układ, którego Wega nie zna, więc nie zgaduje i mapy „Pliki i foldery” nie ma w raporcie.":
            "The permissions database has a layout Wega does not know, so it does not guess and the Files and Folders map is not in the report.",
        "Baza zgód nie ma wpisów dla plików i folderów. Pełny dostęp do dysku jest w bazie systemowej, której Wega nie mapuje.":
            "The permissions database has no file or folder entries. Full Disk Access lives in the system database, which Wega does not map.",
    ]
}
