# Klikalna etykieta rozwijania i aktualizacja przez samą aplikację — plan implementacji

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cały nagłówek rozwijania staje się celem kliknięcia, a apka z własnym updaterem dostaje „Otwórz aplikację" zamiast odesłania do przeglądarki.

**Architecture:** Jeden komponent `WegaDisclosure` (nagłówek = jeden `Button`) zastępuje trzy `DisclosureGroup`. Niezależnie od tego flaga `selfUpdates` w katalogu wchodzi do ładunku `UpdateSource.github` i rozstrzyga nowy `UpdateActionKind.launchAppWithReleases` — źródło wersji zostaje oddzielone od sposobu instalacji.

**Tech Stack:** Swift 6, SwiftUI, SwiftPM. Testy: XCTest (`MacUpdaterTests`) i swift-testing (`MacUpdaterUITests`) — **każdy plik trzyma się frameworka, którego już używa**.

Spec: `docs/superpowers/specs/2026-08-12-disclosure-target-and-github-self-update-design.md`

## Global Constraints

- **Gałąź:** `feat/disclosure-and-github-self-update-2026-08-12`, worktree `.worktrees/disclosure-self-update`. Nie dotykać `main`.
- **Testy pisane, nie uruchamiane.** Zgodnie ze stałą zasadą użytkownika żaden zestaw testów nie jest odpalany. Każdy krok „Red" podaje powód, dla którego test byłby czerwony — potwierdzenie Red→Green pozostaje zaległe i musi trafić do handoffu.
- **Bramka po każdej zmianie kodu:** `swift build` i `swiftlint lint --strict`. **Nie** `scripts/check.sh` — ono uruchamia pełne `swift test`.
- **Nie ruszać `UpdateSource.priority`.** `.github` zostaje 3, `.sparkle` zostaje 1 (uzasadnienie w spec → Zakres).
- **Tekst UI:** każdy literał w `tr("…")` musi mieć wpis angielski w `Sources/MacUpdaterCore/Translations.swift`, inaczej `LocalizationCompletenessTests` oblewa.
- **Bez atrybucji AI** w commitach.
- **Katalog jest podpisany.** Zadanie 4 zostawia `app-catalog.json` w postaci płaskiej; przepodpisanie wymaga klucza prywatnego, którego agent nie ma — to pozycja handoffu, nie krok planu.

---

### Task 1: `WegaDisclosure` i trzy miejsca użycia

**Files:**
- Modify: `Sources/MacUpdater/SharedViews.swift` (dopisz komponent na końcu pliku)
- Modify: `Sources/MacUpdater/UpdateView.swift:456`
- Modify: `Sources/MacUpdater/UpdateViewSupport.swift:639`
- Modify: `Sources/MacUpdater/InfoView.swift:496`
- Modify: `Sources/MacUpdaterCore/Translations.swift`
- Test: `Tests/MacUpdaterUITests/UX02ActionableControlsTests.swift`

**Interfaces:**
- Produces: `WegaDisclosure<Content: View, Label: View>` z inicjalizatorem `WegaDisclosure(isExpanded: Binding<Bool>, content: () -> Content, label: () -> Label)`. Kolejność `content` przed `label` jest celowa — powiela układ `DisclosureGroup(isExpanded:content:label:)`, więc dwa z trzech miejsc użycia zmieniają wyłącznie nazwę typu.

- [ ] **Step 1: Dopisz guard test**

W `Tests/MacUpdaterUITests/UX02ActionableControlsTests.swift`, wewnątrz `struct UX02ActionableControlsTests`, przed sekcją `// MARK: Helpers`. Plik używa swift-testing (`@Test` / `#expect`) — trzymaj się tego.

```swift
    /// Rozwijanie na macOS przełącza się z samego chevronu — celu o szerokości około 12 pt,
    /// obok martwej etykiety, która wygląda na część tej samej kontrolki. `WegaDisclosure`
    /// wkłada chevron i etykietę do jednego `Button`, więc cel to cały nagłówek.
    ///
    /// Czerwony przed zmianą: `UpdateView`, `UpdateViewSupport` i `InfoView` niosły
    /// `DisclosureGroup`.
    @Test func noDisclosureGroupSurvivesInTheAppTarget() throws {
        var offenders: [String] = []

        for url in try appTargetSources() {
            let text = executableSource(try String(contentsOf: url, encoding: .utf8))
            if text.contains("DisclosureGroup(") { offenders.append(url.lastPathComponent) }
        }

        #expect(offenders.isEmpty,
                """
                UX-02: \(offenders.joined(separator: ", ")) używa DisclosureGroup, którego \
                etykieta nie jest celem kliknięcia. Użyj WegaDisclosure.
                """)
    }
```

- [ ] **Step 2: Odnotuj powód czerwieni (bez uruchamiania)**

Czerwony, bo `appTargetSources()` znajdzie `DisclosureGroup(` w trzech plikach:
`UpdateView.swift`, `UpdateViewSupport.swift`, `InfoView.swift`. Zauważ, że
`executableSource` odsiewa linie komentarza, więc doc-comment powyżej nie zalicza się sam.

- [ ] **Step 3: Dodaj komponent**

Na końcu `Sources/MacUpdater/SharedViews.swift`:

```swift
// MARK: - WegaDisclosure

/// Rozwijanie, w którym całym celem kliknięcia jest nagłówek.
///
/// `DisclosureGroup` na macOS przełącza się wyłącznie z chevronu, a etykieta obok — mimo że
/// wygląda na część kontrolki — nic nie robi. Tutaj chevron i etykieta siedzą w jednym
/// `Button`, więc trafienie w dowolne miejsce nagłówka przełącza sekcję.
///
/// UX-02: `Button`, nie `.onTapGesture`. Rola dla VoiceOver, fokus i aktywacja spacją
/// przychodzą razem z nim, a gest oblałby guard w `UX02ActionableControlsTests`.
///
/// Kolejność `content` przed `label` powiela `DisclosureGroup(isExpanded:content:label:)`,
/// żeby podmiana w istniejących miejscach była zmianą nazwy typu, a nie przepisywaniem.
struct WegaDisclosure<Content: View, Label: View>: View {
    @Binding var isExpanded: Bool
    @ViewBuilder var content: () -> Content
    @ViewBuilder var label: () -> Label

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.wega(.subheadline))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    label()
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(tr(isExpanded ? "rozwinięte" : "zwinięte"))

            if isExpanded { content() }
        }
    }
}
```

- [ ] **Step 4: Dodaj tłumaczenia**

W `Sources/MacUpdaterCore/Translations.swift`, do słownika `en`, obok wpisu
`"Pokaż, co dokładnie zrobię"` (okolice linii 611):

```swift
        // Stan rozwinięcia czyta VoiceOver — sam chevron nic nie mówi.
        "rozwinięte": "expanded",
        "zwinięte": "collapsed",
```

- [ ] **Step 5: Podmień miejsce 1 — podgląd planu**

`Sources/MacUpdater/UpdateView.swift:456`. Zmiana dotyczy jednej linii: `DisclosureGroup(` →
`WegaDisclosure(`. Binding, treść, etykieta, `.padding` i `.onChange` zostają bez zmian.

```swift
            WegaDisclosure(isExpanded: $scan.showPlanPreview) {
```

- [ ] **Step 6: Podmień miejsce 2 — „Co nowego"**

`Sources/MacUpdater/UpdateViewSupport.swift:639`, w `ReleaseNotesDisclosure`. Również jedna
linia:

```swift
            WegaDisclosure(isExpanded: $expanded) {
```

- [ ] **Step 7: Podmień miejsce 3 — notatki self-update w `InfoView`**

To jedyne miejsce wymagające przebudowy: dzisiejszy `DisclosureGroup` siedzi w `ForEach`
i nie ma bindingu (korzysta z wewnętrznego stanu `DisclosureGroup`), a `ForEach` nie może
trzymać `@State` per element. Wiersz wyjeżdża do osobnego widoku.

W `Sources/MacUpdater/InfoView.swift` zastąp ciało `ForEach` (linie 495–511) wywołaniem:

```swift
                ForEach(history.notes) { note in
                    SelfUpdateNoteDisclosure(note: note)
                }
```

i dopisz na końcu pliku:

```swift
/// Notatki jednego wydania, domyślnie zwinięte.
///
/// Wydzielone z `InfoView.selfUpdateNotes`, bo `WegaDisclosure` potrzebuje bindingu,
/// a `ForEach` nie może trzymać `@State` dla każdego elementu z osobna.
private struct SelfUpdateNoteDisclosure: View {
    let note: ReleaseNote

    @State private var isExpanded = false

    var body: some View {
        WegaDisclosure(isExpanded: $isExpanded) {
            Text(note.body.isEmpty ? tr("Brak opublikowanych notatek") : note.body)
                .font(.wega(.subheadline))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        } label: {
            HStack(spacing: 6) {
                Text(note.version).font(.wega(.callout, weight: .medium))
                if let published = note.publishedAt {
                    Text(published, style: .date)
                        .font(.wega(.subheadline))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
```

`ReleaseNote` pochodzi z `MacUpdaterCore`, który `InfoView.swift` już importuje.

- [ ] **Step 8: Bramka**

```bash
swift build && swiftlint lint --strict
```

- [ ] **Step 9: Commit**

```bash
git add Sources/MacUpdater/SharedViews.swift Sources/MacUpdater/UpdateView.swift Sources/MacUpdater/UpdateViewSupport.swift Sources/MacUpdater/InfoView.swift Sources/MacUpdaterCore/Translations.swift Tests/MacUpdaterUITests/UX02ActionableControlsTests.swift
git commit -m "feat: make the whole disclosure header a click target"
```

---

### Task 2: `selfUpdates` w schemacie katalogu

**Files:**
- Modify: `Sources/MacUpdaterCore/AppCatalog.swift:6-10`
- Test: `Tests/MacUpdaterTests/AppCatalogTests.swift`

**Interfaces:**
- Produces: `GitHubCatalogEntry.selfUpdates: Bool` — czytane w zadaniu 3 przez `GitHubReleasesChecker` jako `mapping.selfUpdates`.

- [ ] **Step 1: Napisz test**

Dopisz do `Tests/MacUpdaterTests/AppCatalogTests.swift`. Plik używa XCTest — trzymaj się tego.

```swift
    /// Katalog jest podpisany i pobierany zdalnie, więc dokument starszej generacji, który
    /// nie zna tego pola, musi nadal dekodować się poprawnie. Domyślka „nie" znaczy też, że
    /// nowy wpis nie obiecuje uruchomienia, które niczego nie zrobi.
    func testSelfUpdatesDefaultsToFalseWhenTheKeyIsAbsent() throws {
        let json = Data("""
        {"github":[{"bundleId":"com.example.App","repo":"o/r","caskToken":"app"}]}
        """.utf8)

        let entry = try XCTUnwrap(AppCatalog.decode(json).githubRepos["com.example.App"])

        XCTAssertFalse(entry.selfUpdates)
    }

    func testSelfUpdatesIsCarriedWhenDeclared() throws {
        let json = Data("""
        {"github":[{"bundleId":"com.example.App","repo":"o/r","caskToken":"app","selfUpdates":true}]}
        """.utf8)

        let entry = try XCTUnwrap(AppCatalog.decode(json).githubRepos["com.example.App"])

        XCTAssertTrue(entry.selfUpdates)
    }
```

- [ ] **Step 2: Odnotuj powód czerwieni (bez uruchamiania)**

Oba testy nie kompilują się: `GitHubCatalogEntry` nie ma składowej `selfUpdates`. To jest
czerwień — brak symbolu, nie zła wartość.

- [ ] **Step 3: Dodaj pole**

`Sources/MacUpdaterCore/AppCatalog.swift`, zastąp `GitHubCatalogEntry` w całości:

```swift
/// One app the `GitHubReleasesChecker` knows how to track.
public struct GitHubCatalogEntry: Decodable, Sendable, Equatable {
    public let bundleId: String
    public let repo: String
    public let caskToken: String
    /// Czy apka niesie własny updater (Squirrel.Mac, Sparkle, electron-updater…).
    ///
    /// GitHub mówi, **skąd znamy wersję**, a nie **jak się instaluje**. Dla wpisu z tą flagą
    /// akcją wiersza jest uruchomienie apki, a strona wydań zostaje obok jako wyjście
    /// awaryjne — gdy wbudowany updater jest wyłączony albo nie ma prawa zapisu do bundle'a.
    ///
    /// Domyślne `false`: katalog starszej generacji nie zna tego klucza i musi nadal
    /// dekodować się poprawnie, a milczenie nie może być obietnicą.
    public let selfUpdates: Bool

    private enum CodingKeys: String, CodingKey {
        case bundleId, repo, caskToken, selfUpdates
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bundleId = try container.decode(String.self, forKey: .bundleId)
        repo = try container.decode(String.self, forKey: .repo)
        caskToken = try container.decode(String.self, forKey: .caskToken)
        selfUpdates = try container.decodeIfPresent(Bool.self, forKey: .selfUpdates) ?? false
    }
}
```

- [ ] **Step 4: Bramka**

```bash
swift build && swiftlint lint --strict
```

- [ ] **Step 5: Commit**

```bash
git add Sources/MacUpdaterCore/AppCatalog.swift Tests/MacUpdaterTests/AppCatalogTests.swift
git commit -m "feat: let a catalog entry declare that the app updates itself"
```

---

### Task 3: Flaga wchodzi do źródła i rozstrzyga akcję

**Files:**
- Modify: `Sources/MacUpdaterCore/Models.swift:186` (`case github`)
- Modify: `Sources/MacUpdaterCore/VendorUpdateAction.swift:10-32` i `:76-77`
- Modify: `Sources/MacUpdaterCore/GitHubReleasesChecker.swift:39`
- Modify: `Tests/MacUpdaterTests/VendorUpdateCheckerTests.swift:140`
- Modify: `Tests/MacUpdaterTests/ProvenanceTests.swift:21`
- Modify: `Tests/MacUpdaterTests/ScanResultStoreTests.swift:43`
- Modify: `Tests/MacUpdaterTests/CaskChecksumSignalTests.swift:23`
- Modify: `Tests/MacUpdaterUITests/ScanStoreRuntimeScanningTests.swift:40`
- Modify: `Sources/MacUpdater/UpdateViewSupport.swift:531-578` (`actionControl`)

**Interfaces:**
- Consumes: `GitHubCatalogEntry.selfUpdates` (zadanie 2).
- Produces: `UpdateActionKind.launchAppWithReleases(URL?)`, renderowane w tym samym zadaniu —
  nowy przypadek czyni `switch` w `ManualUpdateActionView` niewyczerpującym, więc rozdzielenie
  zostawiłoby commit, który się nie kompiluje.
  `UpdateSource.github(repo: String, selfUpdates: Bool)` — nowy ładunek, pięć miejsc
  konstrukcji w testach do poprawienia.

- [ ] **Step 1: Napisz test akcji**

W `Tests/MacUpdaterTests/VendorUpdateCheckerTests.swift` zastąp
`testNonLaunchActionKindsAreResolvedFromData` (linie 135–144) poniższym oraz dopisz nowy test
pod nim:

```swift
    func testNonLaunchActionKindsAreResolvedFromData() {
        XCTAssertEqual(ManualOutdatedApp.UpdateSource.cask(token: "docker").updateActionKind, .brewInstall(token: "docker"))
        XCTAssertEqual(ManualOutdatedApp.UpdateSource.mas(appStoreID: "1").updateActionKind, .appStore)
        XCTAssertEqual(ManualOutdatedApp.UpdateSource.jetbrains(caskToken: "idea").updateActionKind, .jetBrainsToolbox)

        guard case .openURL(_, let style) = ManualOutdatedApp.UpdateSource
            .github(repo: "o/r", selfUpdates: false).updateActionKind else {
            return XCTFail("a GitHub entry that does not self-update should resolve to an openURL action")
        }
        XCTAssertEqual(style, .githubReleases)
    }

    /// `.github` mówi, skąd znamy wersję, a nie jak się instaluje. Apka z własnym updaterem
    /// (VS Code, Obsidian, GitHub Desktop) ma dostać uruchomienie jako akcję główną —
    /// odesłanie do przeglądarki to najdłuższa droga do czegoś, co apka zrobi sama.
    func testASelfUpdatingGitHubEntryLaunchesTheAppAndKeepsTheReleasesPage() {
        let kind = ManualOutdatedApp.UpdateSource
            .github(repo: "microsoft/vscode", selfUpdates: true).updateActionKind

        guard case .launchAppWithReleases(let url) = kind else {
            return XCTFail("a self-updating GitHub entry should resolve to launchAppWithReleases")
        }
        XCTAssertEqual(url, AppEndpoints.shared.githubReleasesPageURL(repo: "microsoft/vscode"),
                       "the releases page stays reachable as the way out when the built-in updater is off")
    }
```

- [ ] **Step 2: Odnotuj powód czerwieni (bez uruchamiania)**

Nie kompiluje się: `github` nie przyjmuje etykiety `selfUpdates:`, a `UpdateActionKind` nie ma
przypadku `launchAppWithReleases`.

- [ ] **Step 3: Rozszerz ładunek źródła**

`Sources/MacUpdaterCore/Models.swift`, linia 186:

```swift
        case github(repo: String, selfUpdates: Bool)
```

`priority` (3) i `provenance` pozostają bez zmian — `case .github` bez wiązania wartości
dalej pasuje.

- [ ] **Step 4: Dodaj przypadek akcji**

`Sources/MacUpdaterCore/VendorUpdateAction.swift`, w `enum UpdateActionKind` pod `.launchApp`:

```swift
    /// Apka z własnym updaterem, której wersję znamy z GitHuba: uruchomienie jest akcją
    /// główną, a strona wydań zostaje jako wyjście awaryjne — updater bywa wyłączony
    /// (VS Code ma `update.mode`), a bundle poza `/Applications` bywa bez prawa zapisu.
    /// Osobny przypadek zamiast rozszerzenia `.launchApp`: dziewięciu pozostałych vendorów
    /// nie ma żadnej strony wydań i ich wiersz nie powinien urosnąć o kontrolkę.
    case launchAppWithReleases(URL?)
```

- [ ] **Step 5: Rozstrzygnij akcję z flagi**

W tym samym pliku zastąp `case .github` w `updateActionKind` (linie 76–77):

```swift
        case .github(let repo, let selfUpdates):
            let releases = AppEndpoints.shared.githubReleasesPageURL(repo: repo)
            return selfUpdates ? .launchAppWithReleases(releases)
                               : .openURL(releases, style: .githubReleases)
```

- [ ] **Step 6: Przekaż flagę z katalogu**

`Sources/MacUpdaterCore/GitHubReleasesChecker.swift`, linia 39:

```swift
                source: .github(repo: mapping.repo, selfUpdates: mapping.selfUpdates),
```

- [ ] **Step 7: Popraw pozostałe cztery miejsca konstrukcji w testach**

Zmiana mechaniczna — dopisanie `selfUpdates: false` tam, gdzie test nie dotyczy tej flagi:

```swift
// Tests/MacUpdaterTests/ProvenanceTests.swift:21
        XCTAssertEqual(ManualOutdatedApp.UpdateSource.github(repo: "o/r", selfUpdates: false).provenance, .github)

// Tests/MacUpdaterTests/ScanResultStoreTests.swift:43
                    source: .github(repo: "ghostty-org/ghostty", selfUpdates: false),

// Tests/MacUpdaterTests/CaskChecksumSignalTests.swift:23
        XCTAssertNil(caskChecksumToken(of: .github(repo: "owner/repo", selfUpdates: false)))

// Tests/MacUpdaterUITests/ScanStoreRuntimeScanningTests.swift:40
            source: .github(repo: "example/repo", selfUpdates: false)
```

- [ ] **Step 8: Dodaj gałąź renderu**

Nowy przypadek `UpdateActionKind` czyni `switch` w `ManualUpdateActionView` niewyczerpującym,
więc render należy do tego samego zadania — inaczej gałąź zostaje w stanie, który się nie
kompiluje.

W `Sources/MacUpdater/UpdateViewSupport.swift`, w `ManualUpdateActionView.actionControl`,
bezpośrednio po gałęzi `case .launchApp:`:

```swift
        case .launchAppWithReleases(let releasesURL):
            // Akcja główna jest ta sama co w `.launchApp` — updater apki. Strona wydań
            // zostaje obok jako wyjście awaryjne, kontrolką wyraźnie drugorzędną, żeby
            // hierarchia była czytelna na pierwszy rzut oka.
            Button {
                NSWorkspace.shared.open(item.path)
            } label: {
                Label(tr("Otwórz aplikację"), systemImage: "arrow.up.forward.app")
            }
            .controlSize(.small)
            if let releasesURL {
                Button {
                    NSWorkspace.shared.open(releasesURL)
                } label: {
                    Text(tr("GitHub Releases"))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.wegaHoney)
                .controlSize(.small)
            }
```

`.buttonStyle(.plain)` z `Color.wegaHoney` to idiom akcji pobocznych z `LogsView`;
`.buttonStyle(.link)` nie występuje nigdzie w tym projekcie. Oba teksty już są
w `Translations.swift`.

- [ ] **Step 9: Bramka**

```bash
swift build && swiftlint lint --strict
```

- [ ] **Step 10: Commit**

```bash
git add Sources/MacUpdaterCore/Models.swift Sources/MacUpdaterCore/VendorUpdateAction.swift Sources/MacUpdaterCore/GitHubReleasesChecker.swift Sources/MacUpdater/UpdateViewSupport.swift Tests/MacUpdaterTests/VendorUpdateCheckerTests.swift Tests/MacUpdaterTests/ProvenanceTests.swift Tests/MacUpdaterTests/ScanResultStoreTests.swift Tests/MacUpdaterTests/CaskChecksumSignalTests.swift Tests/MacUpdaterUITests/ScanStoreRuntimeScanningTests.swift
git commit -m "feat: separate where a GitHub version comes from and how it installs"
```

---

### Task 4: Dane katalogu i dokumentacja

**Files:**
- Modify: `Sources/MacUpdaterCore/Resources/app-catalog.json`
- Modify: `USER_GUIDE.md`

**Interfaces:**
- Consumes: `GitHubCatalogEntry.selfUpdates` (zadanie 2) — to zadanie tylko wypełnia dane;
  cały kod czytający flagę powstał w zadaniach 2 i 3.

- [ ] **Step 1: Rozpakuj katalog**

`--unwrap` nie wymaga klucza prywatnego.

```bash
./scripts/sign-catalog.sh --unwrap
```

- [ ] **Step 2: Oznacz dwanaście wpisów**

W `Sources/MacUpdaterCore/Resources/app-catalog.json` dopisz `"selfUpdates": true` do
**każdego** z dwunastu wpisów sekcji `github`:

`com.microsoft.VSCode`, `md.obsidian`, `com.knollsoft.Rectangle`, `com.lwouis.alt-tab-macos`,
`eu.exelban.Stats`, `org.p0deje.Maccy`, `me.guillaumeb.MonitorControl`,
`com.linearmouse.linearmouse`, `com.colliderli.iina`, `fr.handbrake.HandBrake`,
`com.aone.keka`, `com.github.GitHubClient`.

Wzór jednego wpisu po zmianie:

```json
{"bundleId": "com.microsoft.VSCode", "repo": "microsoft/vscode", "caskToken": "visual-studio-code", "selfUpdates": true}
```

Podstawa dla każdego wpisu jest w spec → Dowody. Zweryfikowane lokalnie: VS Code i Obsidian.
Pozostałe dziesięć — deklaracja wydawcy; konsekwencja pomyłki jest łagodna, bo link do wydań
zostaje w wierszu obok.

- [ ] **Step 3: Zaktualizuj `USER_GUIDE.md`**

Przewodnik jest **po angielsku** — pisz po angielsku. W sekcji
`### What "updating" means per source` (linia 195) jedna pozycja listy staje się po tej
zmianie nieprawdziwa. Zastąp dokładnie tę linię:

```markdown
- **GitHub-released apps** — opens the Releases page.
```

tym:

```markdown
- **GitHub-released apps** — those that carry their own updater (Visual Studio Code,
  Obsidian, GitHub Desktop…) open so that updater can take over, with a **GitHub Releases**
  link kept beside the button for when it has been switched off. The rest open the Releases
  page.
```

Sąsiedniej pozycji „Sparkle and self-updating apps" **nie** ruszaj — opisuje `.launchApp`,
który się nie zmienia.

- [ ] **Step 4: Bramka**

```bash
swift build && swiftlint lint --strict
```

- [ ] **Step 5: Commit**

```bash
git add Sources/MacUpdaterCore/Resources/app-catalog.json USER_GUIDE.md
git commit -m "feat: mark the GitHub-tracked apps that carry their own updater"
```

- [ ] **Step 6: Odnotuj zaległość podpisu w handoffie**

Katalog jest teraz płaski (bez koperty). Nie próbuj podpisywać — klucz prywatny leży poza
repozytorium i skrypt odmawia użycia klucza z drzewa roboczego. Do handoffu trafia polecenie
dla użytkownika, opisane w sekcji poniżej.

---

## Zaległości do handoffu

Trzy rzeczy zostają do zrobienia po stronie użytkownika i **muszą** znaleźć się w podsumowaniu:

1. **Przepodpisanie katalogu przed scaleniem.** Gałąź niesie płaski `app-catalog.json`; OTA
   pobiera go z raw.githubusercontent i weryfikuje podpis. Bez tego kroku klienci dostaną
   katalog bez ważnego podpisu i `loadOverlay()` go odrzuci.

   ```bash
   WEGA_CATALOG_KEY=~/.secrets/wega-catalog.pem ./scripts/sign-catalog.sh --envelope --bump
   ```

   `app-catalog.json` i `app-catalog.json.sig` muszą trafić do repozytorium w **jednym**
   commicie — raw.githubusercontent cache'uje je osobno.

2. **Potwierdzenie Red→Green.** Żaden test nie był uruchamiany. Do sprawdzenia:
   `UX02ActionableControlsTests`, `AppCatalogTests`, `VendorUpdateCheckerTests`,
   `ProvenanceTests`, `ScanResultStoreTests`, `CaskChecksumSignalTests`,
   `ScanStoreRuntimeScanningTests`, `LocalizationCompletenessTests`,
   `SEC07CatalogEnvelopeTests`.

3. **Weryfikacja dziesięciu wpisów katalogu**, których apek nie ma na maszynie — patrz
   spec → Dowody.
