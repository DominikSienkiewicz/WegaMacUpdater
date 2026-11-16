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

        "PATH": "PATH",
        "PATH jest przybliżony, więc Wega nie sprawdza jego wpisów. Kliknij „Odczytaj PATH”, a potem „Skanuj”.":
            "PATH is approximate, so Wega does not check its entries. Click “Read PATH”, then “Scan”.",
        "Wpisy PATH są w porządku.": "The PATH entries are in order.",
        "Mapa, która przypisuje te wpisy do konkretnych kopii, jest wyłączona. Włącz ją w Ustawieniach.":
            "The map that ties these entries to specific copies is off. Turn it on in Settings.",
        "Mapa jest włączona. Kliknij „Skanuj”, żeby ją odczytać.": "The map is on. Click “Scan” to read it.",
        "Pełny dostęp do dysku, którego Wega potrzebuje do mapy, macOS daje też każdemu programowi, który Wega uruchamia: brew, npm, mas i powłoce, z której Wega odczytuje PATH. Gdy skończysz przeglądać mapę, usuń Wegę z listy Pełny dostęp do dysku.":
            "macOS also gives the Full Disk Access Wega needs for the map to every program Wega starts: brew, npm, mas and the shell Wega reads PATH from. When you have finished looking at the map, remove Wega from Full Disk Access.",
        "Wpisów Pełnego dostępu do dysku Wega nie mapuje: macOS trzyma je w bazie systemowej.":
            "Wega does not map Full Disk Access entries: macOS keeps them in the system database.",
        "może mieć wpisy": "may have entries",
        "kopie w PATH: %@": "copies on PATH: %@",
        "wpisy w „Pliki i foldery”: %@": "Files and Folders entries: %@",
    ]
}
