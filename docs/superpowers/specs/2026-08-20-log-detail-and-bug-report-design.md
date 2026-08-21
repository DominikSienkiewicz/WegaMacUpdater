# Strukturalny kontekst awarii w logach + zgłaszanie błędów z zaznaczonych wpisów

**Data:** 2026-08-20
**Gałąź:** `feat/log-detail-and-bug-report-2026-08-20`

## Cel

Dwie powiązane rzeczy:

1. **Awaria ma się sama opisywać.** Dziś wpis w logu to jedna płaska linia, więc `stderr`,
   kod wyjścia i uruchomiona komenda giną w `error.localizedDescription`. Log mówi
   „aktualizacja nie powiodła się", a nie *dlaczego*.
2. **Zgłoszenie błędu ma być kliknięciem, nie ćwiczeniem.** Użytkownik zaznacza wpisy
   z logu, dopisuje własny opis i wysyła — e-mailem do domyślnego klienta poczty albo
   jako prefillowane issue na GitHubie. Bez serwera, bez backendu, bez telemetrii.

## Stan wyjściowy

| Element | Gdzie | Co robi dziś |
|---|---|---|
| `LogEntry` | `Sources/MacUpdaterCore/LogStore.swift` | `data + poziom + kategoria + płaski string` |
| `LogsView` | `Sources/MacUpdater/LogsView.swift` | `ScrollView` + `LazyVStack`, tylko do odczytu, bez modelu zaznaczenia |
| `LogRedaction` | `Sources/MacUpdaterCore/LogRedaction.swift` | `redact` (OSLog) i `redactForExport` (wszystko, co opuszcza maszynę) |
| `DiagnosticsBundle` | `Sources/MacUpdaterCore/DiagnosticsBundle.swift` | pełna redagowana paczka zip przez `NSSavePanel` |
| `CatalogIssueBuilder` | `Sources/MacUpdaterCore/CatalogIssueBuilder.swift` | prefillowane issue GitHub — działający wzorzec (UX-14) |
| `AppEndpoints` | `Sources/MacUpdaterCore/AppEndpoints.swift` + `Resources/endpoints.json` | wszystkie zewnętrzne adresy w konfiguracji, nie w Swift |

Karty `OBS-01` (błędy omijają zakładkę Logi) i `OBS-02` (centrum diagnostyki) są zamknięte.
Ta praca stoi na nich i idzie dalej.

## Decyzje projektowe

| Decyzja | Wybór | Uzasadnienie |
|---|---|---|
| Zakres „szerszych logów" | strukturalny kontekst przy wpisie | awaria opisuje się sama; zgłoszenie ma treść zamiast „coś nie wyszło" |
| Treść zgłoszenia | wpisy + zwięzła metryczka środowiska + opis użytkownika | ~10 linii, o które maintainer i tak zawsze dopytuje; źródło już istnieje (`DiagnosticsSnapshot`) |
| Redakcja | zawsze `redactForExport` + pełny podgląd w aplikacji | zasada OBS-02: nic nieredagowanego nie opuszcza maszyny; podgląd obsługuje też fallback |
| Zaznaczanie | natywny `List(selection:)` | zachowanie zgodne z macOS, klawiatura i VoiceOver za darmo |
| Adres odbiorcy | nowe pole w `endpoints.json` | konwencja repo: żadnych literalnych URI w Swift; zmiana bez nowego builda |
| Przekroczenie limitu URL | przycięcie z widocznym znacznikiem | zgłoszenie zawsze się otwiera, a maintainer widzi, że czegoś brakuje |

---

## Część 1 — `LogDetail`: strukturalny kontekst awarii

### Model

Nowy typ w `MacUpdaterCore`:

```swift
public struct LogDetail: Equatable, Sendable {
    public struct Field: Equatable, Sendable {
        public let key: String
        public let value: String
    }
    /// Uporządkowane fakty: command, exit, subject, source…
    public let fields: [Field]
    /// Dosłowny ogon stderr, już przycięty do limitu.
    public let output: String?
}
```

`LogEntry` zyskuje `public let detail: LogDetail?`. Pole jest opcjonalne z domyślną wartością
`nil`, więc **każde z 71 istniejących wywołań `WegaLog.error(...)` kompiluje się bez zmian**.
Dochodzi przeciążenie `WegaLog.error(_:_:detail:)` oraz wygodny konstruktor
`LogDetail(command:exitCode:stderr:subject:source:)` przyjmujący `ProcessResult`.

### Format pliku — zgodny wstecz w obie strony

Wpis bez detalu zapisuje się **bajt w bajt tak jak dziś**, więc żaden istniejący `wega.log`
nie wymaga migracji. Detal to linie kontynuacji z prefiksem `\t| `:

```
2026-08-20T10:11:12Z [ERROR] [Homebrew] foo: aktualizacja nie powiodła się
	| command: brew upgrade --cask foo
	| exit: 1
	| stderr:
	| Error: Failure while executing; `/usr/bin/sudo …` exited with 1.
```

Obecny `LogEntry.parse` zwraca `nil` dla linii kontynuacji, a `LogStore.loadFromFile`
używa `compactMap` — **starsza wersja aplikacji czytająca nowszy plik gubi detal zamiast
się wywrócić**. Nowy parser składa linie kontynuacji z ostatnim sparsowanym wpisem
(fold po liniach zamiast `compactMap`).

`loadTailLines` liczy linie pliku, nie wpisy — linie kontynuacji konsumują ten budżet.
Jest to akceptowane: efektem jest mniej wpisów w ogonie, nigdy wpis niekompletny.

### Limity

- ogon `stderr`: 40 linii **i** 4000 znaków (co pierwsze),
- cały detal (pola + output) po serializacji: 8000 znaków,

żeby jeden rozgadany proces nie wyczerpał 5 MB rotacji jednym wpisem.

### Redakcja

Detal przechodzi przez `LogRedaction.redact` przed OSLog dokładnie jak `message` i pozostaje
`privacy: .private`. Pełny tekst trafia do `wega.log` (prawa `0600`).

### Gdzie powstaje detal

Nie migrujemy wszystkich 71 miejsc naraz. Priorytet tam, gdzie `stderr` ginie bezpowrotnie:

- awarie `ProcessRunner` (`ProcessResult` ma już `exitCode` / `stdout` / `stderr`),
- ścieżki brew / mas / npm — skan i upgrade,
- błędy instalacji przez uprzywilejowany helper,
- odrzucenie self-update przez weryfikację podpisu,
- nieudany rollback.

### UI

Wiersz z detalem dostaje disclosure; rozwinięty pokazuje blok monospace pod linią.

### Efekt uboczny

`DiagnosticsBundle` czyta surowe pliki logów, więc detale wchodzą do paczki zip
**bez żadnej zmiany w kodzie eksportu**.

---

## Część 2 — zgłoszenie błędu z zaznaczonych wpisów

### Rdzeń w `MacUpdaterCore`

```swift
/// Jeden wiersz metryczki środowiska: `- Homebrew: 4.3.0`.
public struct ReportField: Sendable, Equatable {
    public let label: String
    public let value: String
}

public struct BugReportDraft: Sendable, Equatable {
    public var userDescription: String
    public var environment: [ReportField]
    public var entries: [LogEntry]
}

public enum BugReportChannel: Sendable, Equatable {
    case email(address: String)
    case gitHubIssue(endpoint: URL)

    /// Limit długości całego URL-a dla tego kanału. Kanał nosi własny limit, żeby żadne
    /// wywołanie nie mogło zbudować treści pod limit innego kanału.
    public var urlLengthLimit: Int { get }
}

public struct BugReportBody: Sendable, Equatable {
    public let text: String
    public let omittedEntryCount: Int
}

public struct BugReportBuilder: Sendable {
    public func title(_ draft: BugReportDraft) -> String
    public func body(_ draft: BugReportDraft, channel: BugReportChannel) -> BugReportBody
    public func url(_ draft: BugReportDraft, channel: BugReportChannel) -> URL?
}
```

`body(_:channel:)` jest publiczne osobno od `url(_:channel:)`, bo podgląd w oknie tworzenia
zgłoszenia pokazuje dokładnie ten tekst, który trafi do URL-a — łącznie z przycięciem.
Podgląd i wysyłka nie mogą się rozjechać.

Ten sam `draft` produkuje oba kanały — treść jest jedna, różni się wyłącznie opakowanie
w URL. Dzięki temu „co wychodzi z maszyny" testuje się raz, nie dwa razy.

### Treść

Po angielsku, ze stabilnymi etykietami — z tego samego powodu, dla którego tak robią już
`DiagnosticsBundle` i `InventoryExport`: zgłoszenie to wymiana danych między użytkownikiem
a maintainerem i musi czytać się tak samo niezależnie od języka UI.

```
## What happened
<opis użytkownika albo "(not provided)">

## Environment
- Wega: 1.4.2 (812)
- macOS: 26.1 (arm64)
- Homebrew: 4.3.0
- mas-cli: not detected
- npm: detected
- Privileged helper: enabled
- Last scan: 2026-08-20T09:00:00Z (complete)

## Log entries (7 selected)
[truncated — 12 earlier entries omitted]
2026-08-20T10:11:12Z [ERROR] [Homebrew] foo: aktualizacja nie powiodła się
	| command: brew upgrade --cask foo
	| exit: 1
	| stderr: Error: Failure while executing…

## Note
This report is redacted: paths, query strings, credentials, e-mail addresses
and account names are replaced with placeholders.
```

**Tytuł** powstaje z najnowszego zaznaczonego wpisu o poziomie `error` (a gdy takiego nie
ma — z najnowszego zaznaczonego wpisu), skrócony do 90 znaków, prefiks `[Bug] `.
Tytuł **nigdy nie jest przycinany** przez limit URL-a.

### Przycinanie

Przycinanie zjada **wyłącznie wpisy, od najstarszych** — awaria jest zwykle ostatnia —
na granicy całego wpisu, nigdy w połowie linii. Znacznik `[truncated — N earlier entries
omitted]` stoi nad zachowanymi wpisami. Metryczka środowiska i opis użytkownika są
nietykalne.

### Limity długości

| Kanał | Limit | Dlaczego |
|---|---|---|
| GitHub issue | 8000 | tyle stosuje już `CatalogIssueBuilder` |
| `mailto:` | 2000 | wiążącym ograniczeniem jest Outlook (~2048 znaków na cały URL) |

Testy przypinają **zachowanie** (znacznik obecny, długość ≤ limit, `%XX` nierozcięte),
nie samą liczbę — strojenie stałej nie przepisuje testów.

### Refaktor przy okazji

`CatalogIssueBuilder` zawiera percent-encoding do zbioru RFC 3986 unreserved oraz
przycinanie binsearchem, które nigdy nie rozcina trypletu `%XX`. Logika ta zostaje
wyciągnięta do wspólnego `PrefilledURLBody` w `MacUpdaterCore`; `CatalogIssueBuilder`
i `BugReportBuilder` z niego korzystają. **Bez zmiany zachowania** — istniejące
`CatalogIssueBuilderTests` są siatką bezpieczeństwa tego przeniesienia.

### Warstwa aplikacji

**`LogsView`** — `ScrollView` + `LazyVStack` zastąpione przez `List(visible, selection: $selected)`
z `Set<LogEntry.ID>`. Styl wiersza przenosi się przez `.listStyle(.plain)`, ukryte separatory
i `.listRowInsets`. Nowy przycisk **„Zgłoś błąd…"** (`exclamationmark.bubble`), nieaktywny przy
pustym zaznaczeniu. Istniejące „Kopiuj" / „Eksportuj diagnostykę" / „Wyczyść" zostają.

Zmiana filtra lub frazy **przycina zaznaczenie do widocznych wpisów** — inaczej dałoby się
zaznaczyć 5 linii, zmienić filtr i wysłać 12.

**`BugReportSheet`** — pole opisu, pod nim podgląd pełnej zredagowanej treści (monospace,
przewijalny, tylko do odczytu), ostrzeżenie o przycięciu gdy dotyczy, i cztery akcje:
**Wyślij e-mailem · Zgłoś na GitHubie · Kopiuj treść · Anuluj**.

**`BugReportController`** (`@MainActor`) — buduje metryczkę przez
`DiagnosticsExportController.snapshot()`, czyli **ten sam kod, który zbiera dane do paczki
zip**; nie powstaje drugi zbieracz. To wywołanie odpytuje `brew --version` i podobne
z 5-sekundowym timeoutem, więc sheet otwiera się natychmiast z wpisami i polem opisu,
a blok środowiska dopina się asynchronicznie („Zbieram informacje o środowisku…");
przyciski wysyłki czekają na jego gotowość.

Po udanym otwarciu kanału leci wpis `WegaLog.info(.app, …)` z liczbą wpisów i nazwą kanału.

### Fallback — brak klienta poczty

Wykrycie: `NSWorkspace.urlForApplication(toOpen:)` dla `mailto:` zwraca `nil`, albo samo
`NSWorkspace.open` zwraca `false`. Wtedy sheet **nie zamyka się i nie pokazuje błędu** —
przełącza się w stan informacyjny: adres, temat i treść, każde z własnym „Kopiuj".
Zero ślepych zaułków.

Dostęp do `NSWorkspace` idzie przez wstrzykiwany protokół, żeby stan fallbacku
był testowalny bez odinstalowywania klienta poczty z maszyny CI.

### Konfiguracja

`endpoints.json` zyskuje pole:

```json
"supportEmail": "wegamacupdater.unbroken239@passmail.net"
```

plus akcesor `AppEndpoints.supportEmailAddress`, pokryty tym samym testem obecności co
`projectNewIssue` w `AppEndpointsTests`.

### Lokalizacja

Nowe stringi UI przez `tr()` z wpisami w `Translations.en` — pilnuje tego istniejący
`LocalizationCompletenessTests`. Treść samego zgłoszenia pozostaje po angielsku.

---

## Testy

### `Tests/MacUpdaterTests` (Core, czyste)

- round-trip `LogDetail` przez linię pliku: zapis → parse → wartość identyczna,
- stara linia bez detalu nadal parsuje się poprawnie,
- linia kontynuacji nie tworzy fałszywego wpisu,
- limity `stderr` (40 linii / 4000 znaków) egzekwowane,
- `BugReportBuilder`: tytuł nigdy nieprzycięty,
- metryczka środowiska zawsze obecna, także po przycięciu,
- przekroczenie limitu → znacznik obecny **i** długość URL ≤ limit,
- przycięcie następuje na granicy wpisu, nie w środku linii,
- percent-encoding nie rozcina trypletu `%XX`,
- **wyjście nie zawiera `/Users/<nazwa>` ani nazwy konta** — próbka wstrzyknięta przez
  `userNames:`, więc gwarancja jest weryfikowalna na dowolnej maszynie,
- kształt URL-a: `mailto:<adres>?subject=…&body=…`,
- `AppEndpointsTests` rozszerzony o `supportEmail`.

### `Tests/MacUpdaterUITests` (`@testable import WegaMacUpdater`)

- puste zaznaczenie → przycisk „Zgłoś błąd…" nieaktywny; niepuste → aktywny,
- zmiana filtra przycina zaznaczenie do widocznych wpisów,
- brak klienta poczty → sheet w stanie informacyjnym z adresem, tematem i treścią
  (przez wstrzyknięty probe, nie realny `NSWorkspace`).

## Dokumentacja

- `docs/features.md` — nowa funkcja,
- `USER_GUIDE.md` — jak zgłosić błąd,
- `README.md` — jeśli router tego wymaga,
- `CHANGELOG.md` — przy wydaniu.

## Poza zakresem

- załączanie paczki zip do maila — `mailto:` tego nie potrafi w żadnym kliencie,
- wysyłka przez SMTP, własny backend, telemetria,
- automatyczne wysłanie czegokolwiek bez kliknięcia użytkownika,
- correlation ID / grupowanie logów po operacji — rozważane i świadomie odłożone,
- migracja wszystkich 71 miejsc logujących błędy na `detail` naraz.

## Do zweryfikowania w trakcie implementacji

- **wydajność `List` przy 2000 wpisów** — obecny `LazyVStack` jest lekki; jeśli `List`
  z niestandardowym stylem wiersza okaże się wolny, alternatywą jest ograniczenie
  liczby renderowanych wierszy, nie rezygnacja z natywnego zaznaczania,
- rzeczywista tolerancja Apple Mail na długi `mailto:` — stała 2000 jest konserwatywna
  i może zostać podniesiona po pomiarze.
