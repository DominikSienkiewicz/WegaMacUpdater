import Testing
import Foundation
@testable import MacUpdaterCore

/// Guards the runtime localization system: every Polish base string passed to `tr(...)`
/// or `trf(...)` in the UI must have an English counterpart in `Translations.en`.
///
/// The custom `tr()` mechanism falls back to the Polish text when a key is missing, so a
/// forgotten translation is otherwise an *invisible* defect — the English UI silently
/// shows Polish. This test turns that into a build failure: it scans the app sources for
/// every `tr("…")` / `trf("…")` literal and asserts each key is translated.
@Suite("LocalizationCompleteness")
struct LocalizationCompletenessTests {

    /// Keys that reach `tr(...)` dynamically (not as a literal) and so can't be found by
    /// the source scan. `InventoryView` calls `tr(opt.rawValue)` over `SourceFilter`,
    /// whose raw values are these Polish strings. Keep in sync with that enum.
    private static let dynamicKeys: Set<String> = ["Wszystkie", "Brew", "App Store", "Ręcznie"]

    /// M9 — `Translations.en` is composed from sections whose keys "never overlap", and a
    /// repeated key silently keeps the first section's English. The UX-review section must
    /// add only keys no other section already has.
    @Test func theUXReviewSectionRepeatsNoKeyOfAnotherSection() {
        let others: [[String: String]] = [
            Translations.base, Translations.operations, Translations.vendorCompletion, Translations.rollbackScope,
            DockerRestartTranslations.english, Translations.dockerShutdown, Translations.dockerDesktop,
            Translations.unconfirmedCaskAssociation, Translations.serviceVendors, Translations.cleanup,
            Translations.cleanupHygiene, MicrosoftAutoUpdateTranslations.english, Translations.uninstallTexts,
            Translations.updatesActionBar,
        ]
        let elsewhere = others.reduce(into: Set<String>()) { $0.formUnion($1.keys) }
        let repeated = Set(Translations.uxReview.keys).intersection(elsewhere).sorted()
        #expect(repeated.isEmpty, "M9: Translations+UXReview.swift repeats \(repeated)")
    }

    /// UXP-25 — bases this round moved from `trf` to `trp`.
    static let pluralised: Set<String> = [
        "Zaktualizować %@ pozycji?", "Zaktualizowano %@ pakietów", "Gotowe! %@ pakietów odświeżonych.",
        "%@ casków bez aplikacji", "Usunięto %@ nieaktualnych casków",
        "Homebrew nadal śledzi %@ casków bez aplikacji — szczegóły są w logach.",
        "%@ resztek do Kosza", "Pominięto %@ aplikacji — powody poniżej.",
        "Nie udało się przenieść %@ resztek do Kosza.", "%@ aplikacji", "odinstalowanie %@ aplikacji",
        "Odinstalować %@ aplikacji?", "%@ aplikacji nie jest zarządzanych przez Homebrew — trafią do Kosza.",
        "Obchód skończony — %@ aplikacji pod opieką.", "Zwęszyłam %@ aplikacji do przeniesienia do Homebrew.",
        "Zeskanowano /Applications · znalazłam %@ aplikacji poza zarządzaniem",
        "Znalazłam %@ rzeczy do uporządkowania.", "Znalazłam %@ aktualizacji", "%@ źródeł nie odpowiedziało",
        "Pominięto %@ najstarszych wpisów",
        // Final review M4 — the release-notes history's tail.
        "…i %@ wcześniejszych wydań",
    ]

    @Test func everyTrpKeyHasPolishAndEnglishForms() throws {
        let keys = try usedKeys(functions: ["trp"])
        let missing = keys.filter { Plurals.forms($0, language: .pl) == nil || Plurals.forms($0, language: .en) == nil }
        #expect(missing.isEmpty, "trp keys without both languages: \(missing.sorted())")
        #expect(keys.isSuperset(of: Self.pluralised))
    }

    @Test func noCountedNounGoesThroughTrf() throws {
        let trf = try usedKeys(functions: ["trf"])
        #expect(trf.isDisjoint(with: Self.pluralised))
        for glued in ["Odinstalować %@ %@?", "%@ %@ przez brew — trafi do Kosza.", "Pominięto %d najstarszych wpisów",
                      "%@ zaznaczonych z %@", "%@ do zainstalowania + %@ ręcznych", "dezinstalacja %@ aplikacji"] {
            #expect(!trf.contains(glued), "\(glued)")
        }
    }

    private static let sectionsBeforeUXReview: [[String: String]] = [
        Translations.base, Translations.operations, Translations.vendorCompletion, Translations.rollbackScope,
        DockerRestartTranslations.english, Translations.dockerShutdown, Translations.dockerDesktop,
        Translations.unconfirmedCaskAssociation, Translations.serviceVendors, Translations.cleanup,
        Translations.cleanupHygiene, MicrosoftAutoUpdateTranslations.english, Translations.uninstallTexts,
        Translations.updatesActionBar,
    ]

    /// M9 — the next round's section repeats no key of any other section, `uxReview` included.
    @Test func theNextUXReviewSectionRepeatsNoKeyOfAnotherSection() {
        let others = Self.sectionsBeforeUXReview + [Translations.uxReview]
        let elsewhere = others.reduce(into: Set<String>()) { $0.formUnion($1.keys) }
        let repeated = Set(Translations.uxReviewNext.keys).intersection(elsewhere).sorted()
        #expect(repeated.isEmpty, "M9: Translations+UXReviewNext.swift repeats \(repeated)")
    }

    /// M9 — this round's section repeats no key of any other section.
    @Test func theRestUXReviewSectionRepeatsNoKeyOfAnotherSection() {
        let others = Self.sectionsBeforeUXReview + [Translations.uxReview, Translations.uxReviewNext]
        let elsewhere = others.reduce(into: Set<String>()) { $0.formUnion($1.keys) }
        let repeated = Set(Translations.uxReviewRest.keys).intersection(elsewhere).sorted()
        #expect(repeated.isEmpty, "M9: Translations+UXReviewRest.swift repeats \(repeated)")
    }

    /// M9 — the next batch's section repeats no key of any other section.
    @Test func theNextBatchSectionRepeatsNoKeyOfAnotherSection() {
        let others = Self.sectionsBeforeUXReview + [Translations.uxReview, Translations.uxReviewNext, Translations.uxReviewRest]
        let elsewhere = others.reduce(into: Set<String>()) { $0.formUnion($1.keys) }
        let repeated = Set(Translations.uxNextBatch.keys).intersection(elsewhere).sorted()
        #expect(repeated.isEmpty, "M9: Translations+UXNextBatch.swift repeats \(repeated)")
    }

    /// M9 — the Touch ID turn-off section repeats no key of any other section.
    @Test func theTouchIDDisableSectionRepeatsNoKeyOfAnotherSection() {
        let others = Self.sectionsBeforeUXReview + [
            Translations.uxReview, Translations.uxReviewNext, Translations.uxReviewRest, Translations.uxNextBatch,
        ]
        let elsewhere = others.reduce(into: Set<String>()) { $0.formUnion($1.keys) }
        let repeated = Set(Translations.touchIDDisable.keys).intersection(elsewhere).sorted()
        #expect(repeated.isEmpty, "M9: Translations+TouchIDDisable.swift repeats \(repeated)")
    }

    /// UXP-24 — one name per concept. These keys were replaced; nothing may use or translate them.
    static let retiredKeys: Set<String> = [
        "Pomocnik Wegi działa jako root i umie tylko cztery rzeczy: zainstalować zweryfikowany pakiet Wegi, włączyć Touch ID dla sudo, przywrócić kopię aplikacji sprzed aktualizacji, przenieść do Kosza aplikację należącą do roota. Przy każdym połączeniu sprawdza podpis Wegi. Jest opcjonalny.",
        "Zastępuje hasło administratora odciskiem palca w poleceniach sudo, także w Terminalu. Bez niego wpisujesz hasło. Jak je wyłączyć, opisuje przewodnik.",
        "Komponent uprzywilejowany",
        "Zainstaluj komponent",
        "Usuń komponent",
        "Komponent uprzywilejowany gotowy.",
        "Potwierdź usunięcie komponentu uprzywilejowanego",
        "wymaga pomocnika Wega — włącz go w ustawieniach.",
        "pomocnik Wega usunie ją bez hasła",
        "pomocnik Wega jest nieaktualny lub nie odpowiada — w ustawieniach usuń go i zainstaluj ponownie.",
        "%@ do Kosza przez pomocnika Wega",
        "Pomocnik Wega nie potwierdził usunięcia — aplikacja mogła już opuścić /Applications. Odświeżona lista pokazuje, czy nadal tam jest.",
        "Do przepięcia",
        "Zwęszyłam %@ aplikacji do przepięcia.",
        "Przepnij pod Brew",
        "Przepnij",
        "Przepnij %@ do Homebrew",
        "Homebrew Casks",
        "Homebrew Formulae",
        "Homebrew (cask)",
        "Homebrew (formuła)",
        "Odepnij nieużywane tapy",
        "Odpięto nieużywane tapy",
        "Homebrew pomija pakiety z niezaufanych tapów",
        "Nie udało się zmienić tapów",
        "Bramka zasobów",
        "Ignorowane i przypięte",
        "Ukryte przez politykę",
        "Brak reguł. Kliknij aktualizację prawym przyciskiem, aby ją zignorować lub przypiąć wersję.",
        "Przywróciłam %@ do wersji %@. Nie będę proponować nowszych, dopóki tego nie zmienisz w Ustawieniach → Ignorowane i przypięte.",
        "Rollback się nie powiódł",
        "Nie udało się utworzyć snapshotu dla: %@.",
        "Nie udało się utworzyć wymaganego snapshotu.",
        "Wega sprawdza miejsce, łącze, baterię i temperaturę przed snapshotem i pobraniem.",
        "Kontrola Gatekeepera i wydawcy mówi, czym plik jest — nie mówi, czy da się go uruchomić. Po tych kontrolach Wega startuje zaktualizowaną aplikację ukrytą, w tle, i sprawdza, czy przeżyje pięć sekund. Jeśli padnie od razu, poprzednia wersja wraca ze snapshotu.",
        "Przed każdą aktualizacją Wega ponownie sprawdza, czy aplikacja nie działa, nie jest zignorowana lub przypięta oraz czy można utworzyć snapshot.",
        "Status każdego pakietu uwzględnia bieżącą aktualizację, reguły i uruchomioną aplikację. Snapshot, zasoby i bezpieczeństwo wydawcy są sprawdzane dopiero bezpośrednio przed aktualizacją.",
        "Nie można rozpoznać zainstalowanej aplikacji .app wymaganej do snapshotu i kontroli wyniku.",
        "Cask nie instaluje aplikacji .app, więc nie można utworzyć snapshotu ani sprawdzić wyniku.",
        "Wydawca (Team ID)",
        "Wydawca się zmienił:",
        "pierwsze sprawdzenie wydawcy",
        "wydawca bez zmian",
        "Zmiana wydawcy",
        "Zaufaj nowemu wydawcy",
        "Zaufano nowemu wydawcy",
        "Wydawca już zaufany",
        "Zaufać nowemu wydawcy %@?",
        "Zobacz u wydawcy",
        "%@: Team ID już różnił się od zaufanego baseline (%@ → %@). Aktualizację zablokowano przed uruchomieniem.",
        "Bez automatycznego cofnięcia — poprzednią wersję pobierzesz od wydawcy.",
        "sprawdzenie niepełne",
        "Wymaga Twojego ruchu",
        "apki",
        "Homebrew nie pilnuje wersji tych apek (auto_updates) — robią to same. Wega sprawdza je u źródła.",
        "Czy ta apka żyje poza brew?",
        "%@: Team ID zmienił się (%@ → %@). Zweryfikuj.",
        "%@: Team ID zmienił się (%@ → %@). Przywrócono poprzednią zaufaną wersję.",
        "%@: zmienił się Team ID wydawcy — przywrócono poprzednią zaufaną wersję.",
        "%@ zmieniło wydawcę (Team ID) — zweryfikuj.",
        "Teraz podpisuje ją Team ID %@ zamiast zaufanego %@. Potwierdź tylko, jeśli wiesz, że producent zmienił konto deweloperskie.",
        "%@: aplikację podpisano ponownie innym Team ID (%@ zamiast %@). Nie zmieniono zaufania.",
        "%@: Team ID %@ jest teraz zaufanym wydawcą.",
        "%@: zainstalowana aplikacja jest podpisana zaufanym Team ID.",
        "Uwaga: wydawca %@ zmienił Team ID (%@ → %@). Zweryfikuj, zanim zaufasz.",
    ]

    /// Fragments of the retired families. Every key that carried one was replaced.
    static let retiredFragments = [
        "omponent uprzywilejowan", "Przepnij", "przepięcia", "Homebrew Casks", "Homebrew Formulae",
        "Homebrew (cask)", "Homebrew (formuła)", "Bramka zasobów", "Ignorowane i przypięte",
        "napshot", "pomocnik Wega ", "pomocnika Wega", "Pomocnik Wega ",
    ]

    @Test func theGlossaryRetiredEveryVariant() throws {
        let used = try usedKeys(functions: ["tr", "trf", "trp"])
        #expect(used.isDisjoint(with: Self.retiredKeys), "\(used.intersection(Self.retiredKeys).sorted())")
        #expect(Set(Translations.en.keys).isDisjoint(with: Self.retiredKeys))
        for fragment in Self.retiredFragments {
            #expect(!used.contains { $0.contains(fragment) }, "\(fragment)")
        }
        let english = Translations.en.values.joined(separator: "\n")
        for variant in ["rivileged component", "Reattach", "Adopt ", "Resource gate", "Ignored & pinned", "Hidden by policy",
                        "Untap", "Homebrew Casks", "Homebrew Formulae", "napshot", "Wega's helper", "new publisher",
                        "Publisher (Team ID)"] {
            #expect(!english.contains(variant), "\(variant)")
        }
        #expect(Translations.en["Pomocnik Wegi"] == "Wega helper")
        #expect(Translations.en["Wstrzymane aktualizacje"] == "Paused updates")
        #expect(Translations.en["Do Homebrew"] == "To Homebrew")
    }

    @Test func theGlossaryLeftoversAreGone() throws {
        let used = try usedKeys(functions: ["tr", "trf", "trp"])
        #expect(used.filter { $0.contains("Team ID") } == ["Brak skonfigurowanego Team ID — helper zadziała dopiero w podpisanym buildzie."],
                "Team ID only in the developer-build message; people read 'podpis producenta'")
        for fragment in ["apki", "apek", "apka", "Twojego ruchu", "zaufanym wydawcą"] {
            #expect(!used.contains { $0.contains(fragment) }, "\(fragment)")
        }
        let english = Translations.en.values.filter { $0.contains("Team ID") }
        #expect(english == ["No Team ID configured — the helper works only in a signed build."])
        for variant in ["Needs your move", "trusted publisher", "changed publisher"] {
            #expect(!Translations.en.values.contains { $0.contains(variant) }, "\(variant)")
        }
        #expect(Translations.en["skan niepełny"] == "check incomplete")
        #expect(Translations.en["Wymaga Twojego działania"] == "Needs your action")
        #expect(Translations.en["producenci"] == "vendors")
    }

    private func packageRoot(file: String = #filePath) -> URL {
        // <root>/Tests/MacUpdaterTests/<thisFile>.swift → up 3 = <root>
        URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// Unescape a Swift string literal body so it matches the real dictionary key,
    /// including `\u{XXXX}` unicode escapes (used e.g. for the Polish „ " quotes).
    private func unescape(_ raw: String) -> String {
        let chars = Array(raw)
        var out = ""
        var i = 0
        while i < chars.count {
            let ch = chars[i]; i += 1
            guard ch == "\\", i < chars.count else { out.append(ch); continue }
            let esc = chars[i]; i += 1
            switch esc {
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "\"": out.append("\"")
            case "\\": out.append("\\")
            case "u" where i < chars.count && chars[i] == "{":
                i += 1   // consume "{"
                var hex = ""
                while i < chars.count, chars[i] != "}" { hex.append(chars[i]); i += 1 }
                if i < chars.count { i += 1 }   // consume "}"
                if let value = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(value) {
                    out.append(Character(scalar))
                }
            default: out.append(esc)   // unknown escape: keep the char
            }
        }
        return out
    }

    private func usedKeys(functions: [String] = ["tr", "trf"]) throws -> Set<String> {
        let appSources = packageRoot().appendingPathComponent("Sources/MacUpdater")
        let files = try FileManager.default
            .contentsOfDirectory(at: appSources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }

        // `tr(` or `trf(`, optional whitespace, then a single-line "double-quoted" literal
        // whose body may contain escaped characters. Newlines are excluded from the body so
        // the match can't run across statements into the next string literal.
        let alternatives = functions.joined(separator: "|")
        let regex = try NSRegularExpression(pattern: #"\b(?:"# + alternatives + #")\(\s*"((?:\\.|[^"\\\n])*)""#)

        var keys = Set<String>()
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: range) {
                guard let r = Range(match.range(at: 1), in: text) else { continue }
                keys.insert(unescape(String(text[r])))
            }
        }
        return keys
    }

    @Test func everyUIKeyHasEnglishTranslation() throws {
        let used = try usedKeys().union(Self.dynamicKeys)
        #expect(used.count > 100, "Sanity: the scan should find the bulk of the UI strings")

        let translated = Set(Translations.en.keys)
        let missing = used.subtracting(translated).sorted()

        let report = "Missing English translations for \(missing.count) key(s):\n"
            + missing.map { "  • \($0)" }.joined(separator: "\n")
        #expect(missing.isEmpty, "\(report)")
    }

    /// UX-11a regression: the Uninstall view's reload button shipped the raw English base
    /// string `tr("Reload")`. Because `tr(base)` returns the base verbatim in the default
    /// Polish language, that surfaced the English word "Reload" in the Polish UI. Guard that
    /// no UI key is the bare English "Reload" — the reload action uses the Polish "Odśwież",
    /// matching the identical button in `InventoryView`.
    @Test func reloadLabelIsNotEnglish() throws {
        let used = try usedKeys()
        #expect(
            !used.contains("Reload"),
            #"UX-11a: no UI string may use the English base key "Reload"; use the Polish "Odśwież"."#
        )
    }
}
