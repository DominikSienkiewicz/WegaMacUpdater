# Klikalna etykieta rozwijania i aktualizacja przez samą aplikację

Data: 2026-08-12

## Problem

Dwie niezależne usterki, obie zgłoszone z jednego zrzutu ekranu zakładki Aktualizacje.

### 1. W chevron trzeba trafić

`DisclosureGroup` na macOS przełącza się **wyłącznie** z chevronu — celu o szerokości około
12 pt. Etykieta obok, mimo że wygląda na część kontrolki, jest martwa. Dotyczy to trzech
miejsc: podglądu planu „Pokaż, co dokładnie zrobię" (`UpdateView.planPreview`), notatek
wydania „Co nowego" przy wierszu apki (`ReleaseNotesDisclosure`) oraz listy notatek
self-update w `InfoView.selfUpdateNotes`.

### 2. Apka, która sama się aktualizuje, dostaje link do przeglądarki

Visual Studio Code trafia do sekcji „Ręcznie zainstalowane" z akcją „GitHub Releases", czyli
z odesłaniem do strony WWW. Tymczasem VS Code niesie własny updater (Squirrel.Mac):
uruchomienie apki pobiera i przygotowuje nową wersję samo. Użytkownik dostaje więc najdłuższą
z możliwych dróg — ręczne pobranie ZIP-a i podmianę `.app` — do czegoś, co apka zrobiłaby
sama.

Źródłem jest zlanie dwóch różnych rzeczy w jednym `case`. `.github` mówi, **skąd znamy
wersję**, a jest używane jako odpowiedź na pytanie, **jak się instaluje**. To nie jest
przypadek jednej apki: `UpdateSource.priority` daje `.github` wartość 3, a `.sparkle`
wartość 1, więc `UpdatePlanner.dedupedByPriority` wybiera wiersz GitHuba także dla dziewięciu
apek sparkle'owych z katalogu (Rectangle, Maccy, IINA, HandBrake, Keka, Stats, AltTab,
MonitorControl, LinearMouse). Każda z nich ma działający updater w środku i każda dostaje
link do przeglądarki.

## Rozwiązanie

1. Własny komponent `WegaDisclosure`, w którym całym celem kliknięcia jest nagłówek —
   chevron **i** etykieta.
2. Flaga `selfUpdates` w katalogu, która oddziela źródło wersji od sposobu instalacji.
   Wpis oznaczony flagą dostaje „Otwórz aplikację" jako akcję główną, a „GitHub Releases"
   zostaje obok jako wyjście awaryjne.

### Zakres

**Nie** zmieniamy `UpdateSource.priority`. Podniesienie `.sparkle` ponad `.github` naprawiłoby
te dziewięć apek za darmo, ale priorytet decyduje również o tym, **którą wersję** raportujemy
— appcast Sparkle kontra tag wydania na GitHubie. To szersze pole rażenia niż niniejsza
zmiana, a flaga w katalogu pokrywa wszystkie dwanaście wpisów bez dotykania tego porządku.

**Nie** zmieniamy podpisu sekcji („Bez automatycznego cofnięcia — poprzednią wersję pobierzesz
od wydawcy") — pozostaje prawdziwy: Wega nadal nie trzyma snapshotu tych apek.

## Architektura

### 1. `WegaDisclosure` (`Sources/MacUpdater/SharedViews.swift`)

```swift
struct WegaDisclosure<Label: View, Content: View>: View {
    @Binding var isExpanded: Bool
    @ViewBuilder var label: () -> Label
    @ViewBuilder var content: () -> Content
}
```

Nagłówek to jeden `Button` w stylu `.plain`, obejmujący obracany chevron
(`chevron.right`, `rotationEffect` 0°/90°) i etykietę, z `.contentShape(Rectangle())`, żeby
odstępy między nimi też były celem. Treść renderuje się pod nagłówkiem, gdy `isExpanded`.
Przełączenie idzie przez `withAnimation(.easeInOut(duration: 0.15))`.

Wybór `Button` zamiast `.onTapGesture` nie jest kwestią gustu. `UX02ActionableControlsTests`
skanuje każdy plik w `Sources/MacUpdater` i oblewa ten, który steruje czymkolwiek z gestu bez
ścieżki klawiaturowej — a `DisclosureGroup` z gestem na etykiecie byłby dokładnie tym
przypadkiem. `Button` daje rolę, fokus i aktywację spacją za darmo.

Dostępność: `.accessibilityValue(tr(isExpanded ? "rozwinięte" : "zwinięte"))`. To dwa nowe
teksty w `Translations.swift`.

Rezygnacja z natywnego `DisclosureGroup` jest świadoma: aplikacja ma już własny system
komponentów (`WegaCard`, `WegaBadge`, `.font(.wega(…))`), a jeden komponent w trzech
miejscach gwarantuje identyczne zachowanie z definicji, nie z czujności.

### 2. Trzy miejsca użycia

- `UpdateView.planPreview` — binding `$scan.showPlanPreview` bez zmian; `.onChange`
  uruchamiające `probeDownloadSizes` zostaje na widoku zewnętrznym i działa dalej.
- `ReleaseNotesDisclosure` (`UpdateViewSupport.swift`) — lokalny `@State`, bez zmian
  w kontrakcie.
- `InfoView.selfUpdateNotes` — jedyne miejsce wymagające przebudowy. Dzisiejszy
  `DisclosureGroup` siedzi w `ForEach` i nie ma żadnego bindingu (korzysta z domyślnego stanu
  `DisclosureGroup`). `ForEach` nie może trzymać `@State` per element, więc wiersz wyjeżdża do
  osobnego, prywatnego widoku z własnym `@State` — tak jak `ReleaseNotesDisclosure`.

### 3. `GitHubCatalogEntry.selfUpdates` (`MacUpdaterCore/AppCatalog.swift`)

Nowe pole `public let selfUpdates: Bool`, dekodowane przez `decodeIfPresent(…) ?? false`.
Domyślne `false` jest tu istotne: katalog jest podpisany i pobierany zdalnie przez
`CatalogRefresher`, więc katalog starszej generacji musi nadal dekodować się poprawnie.
Domyślka „nie" znaczy też, że nowy wpis nie obiecuje uruchomienia, które niczego nie zrobi —
obietnica wymaga świadomej decyzji.

### 4. `UpdateSource.github` niesie flagę (`MacUpdaterCore/Models.swift`)

`case github(repo: String, selfUpdates: Bool)`. Ładunek `enum` musi urosnąć, bo
`updateActionKind` jest funkcją źródła i nie ma innej drogi do tej informacji. `priority`
i `badgeLabel` pozostają bez zmian (dalej odpowiednio 3 i `"GitHub"`). Jedyne miejsce
konstruujące ten `case` w produkcji to `GitHubReleasesChecker`, który przekazuje
`mapping.selfUpdates`.

### 5. `UpdateActionKind.launchAppWithReleases` (`MacUpdaterCore/VendorUpdateAction.swift`)

```swift
case launchAppWithReleases(URL?)
```

Osobny `case` zamiast rozszerzenia istniejącego `.launchApp` — dziewięciu vendorów
self-update nie ma żadnej strony wydań do pokazania i ich wiersz nie powinien urosnąć
o kontrolkę.

```swift
case .github(let repo, let selfUpdates):
    let releases = AppEndpoints.shared.githubReleasesPageURL(repo: repo)
    return selfUpdates ? .launchAppWithReleases(releases)
                       : .openURL(releases, style: .githubReleases)
```

### 6. Render (`MacUpdater/UpdateViewSupport.swift`)

Nowa gałąź w `ManualUpdateActionView.actionControl`: przycisk „Otwórz aplikację"
(`arrow.up.forward.app`, identycznie jak `.launchApp`) plus „GitHub Releases" jako kontrolka
drugorzędna — `.buttonStyle(.plain)` z `Color.wegaHoney` i bez ikony, czyli idiom, którym
`LogsView` rysuje dziś akcje poboczne (`.buttonStyle(.link)` nie występuje nigdzie w tym
projekcie). Gdy URL jest `nil`, zostaje sam przycisk otwarcia. Oba teksty już istnieją
w `Translations.swift`.

### 7. Dane katalogu

`selfUpdates: true` na wszystkich dwunastu wpisach `github`
w `Sources/MacUpdaterCore/Resources/app-catalog.json`, po czym przepodpisanie przez
`scripts/sign-catalog.sh`.

## Dowody

Mechanizm aktualizacji sprawdzony bezpośrednio tylko dla apek zainstalowanych na maszynie
(obecność `Sparkle.framework` i `SUFeedURL` w `Info.plist` kontra `Squirrel` w `Frameworks`):

| Wpis | Mechanizm | Podstawa |
| --- | --- | --- |
| `com.microsoft.VSCode` | Squirrel.Mac | zweryfikowane lokalnie |
| `md.obsidian` | Squirrel.Mac | zweryfikowane lokalnie |
| `com.github.GitHubClient` | Squirrel.Mac | deklaracja wydawcy, apka niezainstalowana |
| Rectangle, AltTab, Stats, Maccy, MonitorControl, LinearMouse, IINA, HandBrake, Keka | Sparkle | deklaracja wydawcy, apki niezainstalowane |

Konsekwencja błędu w drugiej grupie jest łagodna i to jest powód, dla którego link zapasowy
z punktu 6 jest nośny, a nie ozdobny: wiersz urósłby o przycisk, który nic nie robi, obok
działającego linku do wydań. Żadna ścieżka instalacji się nie psuje.

`md.obsidian` ma już `.obsidian` (priorytet 5) wygrywający z `.github` (3), więc flaga jest dla
niego dziś bez skutku. Ustawiamy ją mimo to — opisuje apkę, nie bieżący wynik deduplikacji.

## Testy

Wszystkie poniższe są pisane, nie uruchamiane (zgodnie z ustaleniem, że zestawy testów
odpalane są na wyraźną prośbę).

- **Guard rozwijania** (`UX02ActionableControlsTests`, idiom inspekcji źródła): żaden plik
  w `Sources/MacUpdater` nie zawiera `DisclosureGroup(`. Czerwony przed zmianą w trzech
  plikach.
- **`AppCatalogTests`**: wpis bez klucza `selfUpdates` dekoduje się do `false`; wpis
  z `true` niesie `true`.
- **`VendorUpdateCheckerTests` / nowe asercje akcji**: `.github(repo:selfUpdates: true)` daje
  `.launchAppWithReleases` z adresem strony wydań, a `selfUpdates: false` nadal daje
  `.openURL(_, style: .githubReleases)`. Czerwony przed zmianą — dziś obie ścieżki dają
  `.openURL`.
- **`SEC07CatalogEnvelopeTests` / `CatalogSignatureTests`**: przechodzą po przepodpisaniu;
  jeśli oblewają, podpis nie został odświeżony.
- **`LocalizationCompletenessTests`**: wymusza wpisy angielskie dla „rozwinięte" i „zwinięte".

## Dokumentacja

`USER_GUIDE.md` opisuje akcje w sekcji „Ręcznie zainstalowane" — wymaga zdania o tym, że apka
z własnym updaterem otwiera się zamiast odsyłać do wydań. `README.md` jednak *opisuje*
rozstrzyganie akcji per źródło — punkt 5. „Act" wylicza je zdanie po zdaniu — i przegląd
całej gałęzi wykrył, że to zdanie się zdezaktualizowało: zapis „GitHub apps open the Releases
page" był już fałszywy, skoro wszystkie dwanaście wpisów katalogu GitHub ma `selfUpdates: true`
i renderuje przycisk uruchamiający apkę, ze stroną wydań jako drugorzędnym linkiem obok. Zdanie
poprawiono na „GitHub apps launch the app itself, with the Releases page kept as a secondary
link", spójnie z sąsiednim opisem pozostałych samo-aktualizujących się vendorów.
