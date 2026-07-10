# Design: Zakładka „Logi" + klikalny szczegół błędu

**Date:** 2026-06-09
**Status:** Approved

---

## Problem

Gdy część źródeł nie odpowiada, aplikacja pokazuje banner „Lista może być
niepełna — znalazłam N aktualizacji, ale M źródeł nie odpowiedziało". Użytkownik
nie ma jak sprawdzić **które** źródło zamilkło ani **dlaczego**:

- Błędy skanu są redukowane do licznika `failedSources: Int` w
  `UpdateView.runScan` — nazwa źródła i komunikat giną (poza błędem Homebrew,
  który i tak jest nadpisywany ogólnym tekstem w wariancie `partialFailure`).
- Logowanie (`AppLogger`) idzie wyłącznie do OSLog (Console.app) — niewidoczne
  w aplikacji, bez własnego pliku, nieosiągalne dla użytkownika.
- Banner (`BannerData` / `BannerView`) jest statyczny: ikona + tytuł + treść + X.
  Brak akcji, brak linku do szczegółów.

## Cel

1. **Pełny log aktywności** widoczny w aplikacji, **trwały** (zapis do pliku,
   przeżywa restart).
2. **Zakładka „Logi"** w menu bocznym — przegląd, filtrowanie, kopiowanie,
   eksport.
3. **Klikalny szczegół błędu**: banner ostrzegawczy zyskuje afordancję „i" →
   przenosi do zakładki Logi z pre-filtrem „Tylko błędy".

## Decyzje (zatwierdzone)

- Źródło danych: **własny `LogStore`** (bufor w pamięci) + zapis do pliku,
  zasilany fasadą `WegaLog`, która równolegle forwarduje do istniejącego OSLog
  `AppLogger`. (Odrzucone: `OSLogStore` — kapryśne uprawnienia/trwałość; czysty
  logger plikowy — słaby podgląd na żywo.)
- Zawartość: **pełny log aktywności** (start/koniec skanu, odpowiedzi źródeł,
  wyniki instalacji, błędy).
- Trwałość: **zapis do pliku** `~/Library/Logs/WegaMacUpdater/wega.log`.
- Lista **od najnowszych** (log diagnostyczny — świeży błąd na górze).
- Wejście z bannera ustawia filtr **„Tylko błędy"**; wejście z menu → „Wszystkie".
- Zakładka **„Logi"**, ikona `doc.text.magnifyingglass`.
- **Badge błędów** przy zakładce (jak licznik „4" przy Aktualizacjach): kropka/
  liczba, gdy ostatni skan miał błędy.

---

## Komponent 1: `LogStore` + fasada `WegaLog` (`MacUpdaterCore`)

### `LogEntry`

```swift
public struct LogEntry: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let date: Date
    public let level: LogLevel       // debug, info, warning, error
    public let category: LogCategory // app, process, homebrew, scanner, network, helper
    public let message: String
}

public enum LogLevel: String, Sendable, CaseIterable { case debug, info, warning, error }
public enum LogCategory: String, Sendable, CaseIterable {
    case app, process, homebrew, scanner, network, helper
}
```

`LogCategory` odpowiada 1:1 kategoriom w `AppLogger`, żeby fasada mogła wybrać
właściwy `Logger`.

### Format linii pliku

```
2026-06-09T17:34:01Z [ERROR] [Homebrew] brew outdated: The operation couldn't be completed.
```

- Znacznik czasu: ISO-8601 (UTC, `ISO8601DateFormatter`).
- `[LEVEL]` wielkimi literami z `LogLevel.rawValue.uppercased()`.
- `[Category]` z czytelnej nazwy kategorii (np. `Homebrew`).
- `message` — reszta linii (może zawierać spacje; **nie** zawiera znaków nowej
  linii — wielolinijkowe komunikaty są spłaszczane: `\n` → ` `).

Parsowanie przy `loadFromFile()`: regex/podział na 4 pola (czas, level,
category, reszta). Linia, której nie da się sparsować, jest pomijana (log nie
może się wywrócić na uszkodzonym pliku).

### `LogStore`

```swift
@MainActor public final class LogStore: ObservableObject {
    public static let shared = LogStore()

    @Published public private(set) var entries: [LogEntry] = []

    private let memoryCap = 2000          // wpisów w pamięci
    private let fileMaxBytes = 5 * 1024 * 1024
    private let loadTailLines = 2000      // ile wczytać po starcie
    private let fileQueue = DispatchQueue(label: "wega.logstore.file")

    public var logFileURL: URL { ... }    // ~/Library/Logs/WegaMacUpdater/wega.log

    func append(_ entry: LogEntry)        // dokłada + przycina + zapis do pliku
    func loadFromFile()                   // ogon pliku → entries (przy init)
    func clear()                          // entries = [] + truncate pliku
}
```

- `append`: dodaje na **koniec** `entries` (chronologicznie); przycina od początku
  do `memoryCap`. Asynchronicznie (na `fileQueue`) dopisuje linię do pliku.
- Widok renderuje listę **odwróconą** (najnowsze na górze) — przechowujemy
  chronologicznie, odwracamy przy prezentacji (`entries.reversed()`).
- **Rotacja**: przed zapisem, jeśli rozmiar pliku > `fileMaxBytes` → przenieś
  `wega.log` na `wega.log.1` (nadpisując ewentualny stary backup) i zacznij nowy
  `wega.log`. Dokładnie 1 backup.
- Katalog `~/Library/Logs/WegaMacUpdater/` tworzony leniwie przy pierwszym
  zapisie (`FileManager.createDirectory`).
- `init` woła `loadFromFile()` (synchronicznie wystarczy — ogon 2000 linii jest
  mały; ewentualnie lazy przy pierwszym dostępie do zakładki).

### Fasada `WegaLog`

```swift
public enum WegaLog {
    public static func log(_ level: LogLevel, _ category: LogCategory, _ message: String)
    public static func debug(_ category: LogCategory, _ message: String)
    public static func info(_ category: LogCategory, _ message: String)
    public static func warning(_ category: LogCategory, _ message: String)
    public static func error(_ category: LogCategory, _ message: String)
}
```

- Synchronicznie loguje do odpowiadającego `AppLogger.<category>` na właściwym
  poziomie OSLog (`.debug/.info/.notice/.error`) — bez zmian dla Console.app.
- Dokłada `LogEntry` do `LogStore.shared`. Wywołania mogą być spoza main; fasada
  hopuje: `Task { @MainActor in LogStore.shared.append(entry) }`. Luźna kolejność
  między wpisami z różnych wątków jest akceptowalna dla podglądu logu (znacznik
  czasu jest stemplowany w miejscu wywołania, nie przy zapisie).

> **Uwaga o `Date`:** znacznik czasu pochodzi z `Date()` w momencie logowania.
> To jest właściwe miejsce dla rzeczywistego czasu (kod produkcyjny, nie skrypt
> workflow).

---

## Komponent 2: Zbieranie błędów ze szczegółem

### `UpdateView.runScan` (`MacUpdater`)

Każdy `catch` loguje szczegół zamiast tylko inkrementować licznik:

```swift
do { brewOutdated = try await model.brewService.outdatedGreedy() }
catch {
    errorMessage = error.localizedDescription
    brewOutdated = nil
    failedSources += 1
    WegaLog.error(.homebrew, "brew outdated: \(error.localizedDescription)")
}
// analogicznie mas → .app (lub .network), npm → .network
```

Dodatkowo:
- `WegaLog.info(.scanner, "Skan rozpoczęty (brew + mas + npm + manual)")` na
  początku `runScan`.
- `WegaLog.info(.scanner, "Skan zakończony: N aktualizacji, M źródeł nie odpowiedziało")`
  przed ustawieniem bannera.

`failedSources` nadal steruje bannerem (logika `UpdatePlanner.scanState` bez
zmian) — zmiana jest **addytywna**: dokładamy logowanie, nie zmieniamy ścieżki
decyzyjnej.

### `ManualUpdateScanner` (`MacUpdaterCore`)

Dziś zwraca `(apps, failedChecks: Int)`; `ManualCheckResult.failed` jest **puste**
(checkery łykają błąd przez `try?`), a `work` to płaska tablica domknięć bez
etykiet — więc przy `.failed` nie wiadomo *które* źródło dla *której* aplikacji
zawiodło.

> **Uwaga:** `runBounded` **nie zachowuje kolejności** wyników (dokłada je w
> kolejności ukończenia — „order is not significant"). Dlatego etykiet **nie**
> można zipować po indeksie z wynikami. Logujemy **wewnątrz domknięcia**, gdzie
> źródło i aplikacja są w zasięgu.

**Wybrane rozwiązanie (niski blast radius, scanner-only):** opakowujemy każde
domknięcie helperem, który uruchamia check, a gdy wynik to `.failed`, loguje
źródło + nazwę aplikacji i zwraca wynik bez zmian:

```swift
func logged(_ source: String, _ app: ApplicationInfo,
            _ run: @escaping @Sendable () async -> ManualCheckResult)
    -> @Sendable () async -> ManualCheckResult {
    return {
        let result = await run()
        if case .failed = result {
            WegaLog.error(.network, "\(source) · \(app.name): brak odpowiedzi lub błąd parsowania")
        }
        return result
    }
}
// użycie:
work.append(logged("JetBrains", app) { await jetbrainsChecker.check(app: app) })
```

- `ManualCheckResult.failed` **pozostaje puste** — zero zmian w 8 checkerach i ~6
  testach porównujących `== .failed`.
- `failedChecks: Int` w sygnaturze **bez zmian** — banner liczy po staremu.
- Zysk: log zawiera *które źródło dla której aplikacji* zamilkło — to bezpośrednio
  odpowiada na „które źródło nie odpowiada".

Etykiety źródeł: `"Cask"`, `"JetBrains"`, `"GitHub"`, `"Synology"`, `"Antigravity"`,
`"Parallels"`, `"Google Drive"`, `"ChatGPT"`, `"Sparkle"` — przypisywane w miejscu
budowania `work`.

> **Świadomie poza tym krokiem (Tier 2):** wyciągnięcie *surowego* komunikatu błędu
> z checkerów (odłykanie `try?`, wzbogacenie `.failed` o `reason`) — to dotknęłoby
> wszystkich checkerów i ich testów. brew/mas/npm i tak mają już realny komunikat
> (z `UpdateView`); dla checkerów manualnych „które źródło · która aplikacja" jest
> wystarczające w tej iteracji. Patrz „Poza zakresem".

---

## Komponent 3: Zakładka „Logi" (`MacUpdater`)

### Nawigacja (`ContentView.swift`)

- Nowy case `SidebarTab.logs = "logs"`:
  - `label`: „Logi"
  - `systemImage`: `doc.text.magnifyingglass`
  - `hint`: „Co się działo"
- Dodany do `SidebarTab.toolTabs` (po `.inventory`).
- Case w `ContentArea` switch → `LogsView(...)`.
- **Badge błędów**: `SidebarTabRow` już wspiera `badge: Int?`. Dodajemy lekki
  stan na poziomie `ContentView`/`ContentArea`: po skanie z błędami ustawiamy
  liczbę błędów ostatniego skanu; `SidebarView` pokazuje ją przy `.logs`
  (czerwony wariant — patrz niżej). Czyszczony, gdy użytkownik wejdzie w zakładkę
  Logi (jak „przeczytane").
  - `SidebarTabRow` kolory badge: dla `.logs` z błędami użyć wariantu danger
    (czerwony) zamiast miodowego; drobne rozszerzenie istniejącego renderu badge
    (parametr koloru/wariantu).

### `LogsView`

`@ObservedObject var store = LogStore.shared` — singleton jest długowieczny,
więc `@ObservedObject` jest właściwy (nie `@StateObject`, który zarządzałby
cyklem życia).

Parametry wejściowe:
- `onWegaState: (WegaState) -> Void` (jak inne widoki).
- `initialFilter: LogLevelFilter` — domyślnie `.all`; banner ustawia `.errorsOnly`.

Stan:
- `@State filter: LogLevelFilter` (`all`, `warningsAndUp`, `errorsOnly`).
- `@State searchText: String`.

UI:
- **Pasek narzędzi**:
  - Segmented/Picker filtra poziomu: „Wszystkie" / „Ostrzeżenia+" / „Tylko błędy".
  - Pole wyszukiwania (filtruje po `message` i nazwie kategorii, case-insensitive).
  - Przyciski: „Pokaż w Finderze" (`NSWorkspace.activateFileViewerSelecting`
    `store.logFileURL`), „Kopiuj" (złącz widoczne wpisy do `NSPasteboard`),
    „Wyczyść" (`store.clear()`, poprzedzone `confirmationDialog`, żeby nie
    skasować logu przypadkiem).
- **Lista** (`ScrollView` + `LazyVStack`), `store.entries` przefiltrowane i
  **odwrócone** (najnowsze na górze):
  - Wiersz: `HH:mm:ss` (monospace, tertiary) · chip poziomu (kolor: error =
    `wegaDanger`, warning = `wegaToffee`, info/debug = secondary) · tag kategorii
    (`wegaHoney`, drobny) · `message` (monospace 11.5, `.textSelection(.enabled)`,
    zawijany).
  - Wirtualizacja przez `LazyVStack` (do 2000 wpisów).
- **Pusty stan**: poza Wegi + „Cicho jak makiem zasiał — żadnych zdarzeń."

### Banner → nawigacja (`SharedViews.swift`, `UpdateView.swift`, `ContentView.swift`)

- `BannerData`:
  ```swift
  enum BannerAction: Equatable { case openLogs }
  struct BannerData: Equatable {
      enum Variant { case success, danger }
      let variant: Variant
      let title: String
      let message: String
      var action: BannerAction? = nil   // domyślnie brak — istniejące wywołania bez zmian
  }
  ```
- `BannerView`: dodaje opcjonalne `onAction: ((BannerAction) -> Void)? = nil`.
  Gdy `data.action != nil`, renderuje przed „X" przycisk-link:
  ikona `info.circle` + „Zobacz w logach". Klik → `onAction?(action)`.
- `UpdateView`: dodaje callback `onNavigate: (SidebarTab) -> Void`. Bannery
  `partialFailure`, `checkFailed` oraz „Błąd Homebrew" dostają `action: .openLogs`.
  `BannerView(... onAction:)` → `onNavigate(.logs)` + sygnał, by `LogsView` wszedł
  z filtrem „Tylko błędy".
  - Przekazanie pre-filtra: najprościej przez lekki stan w `ContentArea`
    (`@State logsInitialFilter`), ustawiany tuż przed `activeTab = .logs`, czytany
    przez `LogsView(initialFilter:)`. (Alternatywa: pole na `LogStore` — odrzucone,
    żeby nie mieszać stanu UI do rdzenia.)
- `ContentArea` przekazuje `onNavigate: { tab in activeTab = tab; wegaState = .forTab(tab) }`
  do `UpdateView`.

---

## Lokalizacja

Nowe stringi PL przez `tr`/`trf`; odpowiedniki EN dopisane do mapy w
`Translations.swift`:
- „Logi", „Co się działo", „Wszystkie", „Ostrzeżenia+", „Tylko błędy",
  „Pokaż w Finderze", „Kopiuj", „Wyczyść", „Zobacz w logach",
  „Cicho jak makiem zasiał — żadnych zdarzeń.", „Wyczyścić logi?" (+ potwierdzenie).

---

## Testy (XCTest, test-first w implementacji)

`LogStoreTests`:
- `append` przycina do `memoryCap` (najstarsze wypadają, kolejność zachowana).
- `append` zapisuje parsowalną linię; `loadFromFile` daje round-trip
  (date≈, level, category, message).
- Linia z `\n` w message jest spłaszczana (brak rozjechania parsera).
- Rotacja: po przekroczeniu progu powstaje `wega.log.1`, świeży `wega.log`
  zawiera najnowszy wpis, łączna historia nie ginie.
- Uszkodzona/niepełna linia w pliku jest pomijana przy `loadFromFile`
  (brak crasha, reszta wczytana).
- `clear` opróżnia `entries` i truncuje plik.

`LogEntryFormatTests`:
- encode → string → parse round-trip dla każdego `LogLevel`/`LogCategory`.

`BannerData`:
- `BannerData` z `action` i bez pozostaje `Equatable` (regresja kompilacji
  istniejących wywołań — wszystkie używają domyślnego `action: nil`).

Testy używają tymczasowego katalogu (`FileManager.temporaryDirectory`) wstrzykniętego
do `LogStore` — `LogStore` dostaje `init(directory:)` dla testów (singleton `.shared`
używa domyślnego `~/Library/Logs/...`).

---

## README

Dopisać do README:
- Nowa zakładka **„Logi"** w opisie UI/funkcji.
- Lokalizacja pliku logu: `~/Library/Logs/WegaMacUpdater/wega.log` (+ `.log.1`
  jako backup po rotacji).

---

## Poza zakresem (YAGNI)

- Konfiguracja poziomów logowania w UI.
- Wysyłka/upload logów na zewnątrz.
- Rotacja z więcej niż 1 backupem.
- Ustawienia trwałości per-kategoria.
- Odczyt historycznych logów z OSLog (`OSLogStore`).
- **Tier 2**: surowy komunikat błędu z manualnych checkerów (odłykanie `try?`,
  `ManualCheckResult.failed(reason:)`) — dotyka 8 checkerów + testów; odłożone.

---

## Granice komponentów (isolation check)

- **`LogStore`** — co robi: trzyma i utrwala wpisy logu. Jak używać: `WegaLog.*`
  do zapisu, `@Published entries` do odczytu, `clear()`/`logFileURL` do akcji.
  Zależy od: `FileManager`. Testowalny w izolacji (wstrzyknięty katalog).
- **`WegaLog`** — co robi: jeden punkt logowania → OSLog + `LogStore`. Jak używać:
  statyczne metody. Zależy od: `AppLogger`, `LogStore`.
- **`LogsView`** — co robi: prezentacja + filtrowanie + akcje na logu. Jak używać:
  osadzony w `ContentArea`. Zależy od: `LogStore` (obserwacja), `onWegaState`,
  `initialFilter`.
- **`BannerData/BannerView`** — rozszerzenie addytywne; istniejący kontrakt
  (success/danger + tytuł + treść + zamknięcie) zachowany.
