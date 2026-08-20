# Strukturalny kontekst awarii + zgłaszanie błędów z logów — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Spec:** `docs/superpowers/specs/2026-08-20-log-detail-and-bug-report-design.md`
**Gałąź:** `feat/log-detail-and-bug-report-2026-08-20`
**Worktree:** `.worktrees/log-detail-and-bug-report`

**Goal:** Wpis w logu może nieść strukturalny kontekst awarii (komenda, kod wyjścia, ogon `stderr`), a użytkownik może zaznaczyć wpisy i wysłać z nich zgłoszenie błędu — e-mailem do domyślnego klienta poczty albo jako prefillowane issue na GitHubie.

**Architecture:** Nowy `LogDetail` w `MacUpdaterCore` dopina się do `LogEntry` jako pole opcjonalne i serializuje do `wega.log` jako linie kontynuacji z prefiksem `\t| `, niewidoczne dla starego parsera. Budowanie zgłoszenia to czysta funkcja w Core (`BugReportBuilder`) wspólna dla obu kanałów; warstwa aplikacji tylko zbiera dane, pokazuje podgląd i otwiera URL. Percent-encoding i przycinanie zostają wyciągnięte z `CatalogIssueBuilder` do wspólnego `PrefilledURLBody`.

**Tech Stack:** Swift 6, SwiftUI (macOS 26), SPM. Testy: **Swift Testing** (`import Testing`, `@Suite`, `@Test`, `#expect`) — dominujący framework w obu targetach dla nowych plików. Lint: SwiftLint `--strict`.

## Global Constraints

- **Nie uruchamiaj pakietów testowych z automatu.** Zgodnie z AGENTS.md użytkownika testy odpalane są wyłącznie na wyraźną prośbę w danej sesji. Kroki „Weryfikacja Red/Green" poniżej są **warunkowe** — gdy użytkownik nie prosił o uruchomienie testów, pomiń je i zaraportuj w handoffie, że potwierdzenie Red-Green pozostaje niewykonane. Domyślną bramką jakości jest `swiftlint lint --strict`.
- **Nigdy nie pracuj na `main`.** Cała praca w worktree `.worktrees/log-detail-and-bug-report` na gałęzi `feat/log-detail-and-bug-report-2026-08-20`.
- **Integracja to rola użytkownika.** Agent nie scala, nie przestawia bazy, nie wypycha ani nie przenosi commitów między gałęziami. Gotową gałąź zostawia się użytkownikowi wraz z komendą do wklejenia.
- **Żadnej atrybucji AI** w commitach, tytułach ani opisach.
- **Żadnych literalnych URI w Swift** — każdy zewnętrzny adres pochodzi z `endpoints.json`.
- **Wszystko, co opuszcza maszynę, przechodzi przez `LogRedaction.redactForExport`.** Brak ścieżki „raw" jest wymogiem strukturalnym, nie konwencją.
- **Każdy nowy string UI** przechodzi przez `tr(...)` i **musi** dostać wpis w `Translations.operations` w `Sources/MacUpdaterCore/Translations.swift` — pilnuje tego `LocalizationCompletenessTests`.
- **Treść samego zgłoszenia jest po angielsku**, ze stabilnymi etykietami — jak `DiagnosticsBundle` i `InventoryExport`.
- **SwiftLint 0.65.0 nie zna opcji `--path`** — ścieżki podaje się pozycyjnie:
  `swiftlint lint --strict <plik>`. Wariant z `--path` kończy się błędem
  `Unknown option '--path'`, czyli lint w ogóle się nie wykonuje.
- **`swift test --filter` dopasowuje NAZWY TYPÓW, nie nazwy wyświetlane z `@Suite("…")`.**
  Filtr po nazwie z `@Suite` nie uruchamia **żadnego** testu, a SwiftPM sygnalizuje to
  wyłącznie ostrzeżeniem `warning: No matching test cases were run` przy kodzie wyjścia 0 —
  czyli wygląda jak sukces. Zawsze filtruj po nazwie typu (`LogsSelectionTests`, nie
  `"Logs selection"`) i sprawdź w wyjściu linię `Test run with N tests`; `N` musi być > 0.
- Limity: `stderr` 40 linii **i** 4000 znaków; cały detal po serializacji 8000 znaków; URL `mailto:` 2000 znaków; URL GitHub 8000 znaków.

---

## File Structure

**Create (Core):**
- `Sources/MacUpdaterCore/LogDetail.swift` — `LogDetail`, `LogDetail.Field`, limity, serializacja do/z linii kontynuacji.
- `Sources/MacUpdaterCore/PrefilledURLBody.swift` — percent-encoding RFC 3986 unreserved + przycinanie binsearchem.
- `Sources/MacUpdaterCore/BugReport.swift` — `BugReportDraft`, `BugReportChannel`, `BugReportBody`, `BugReportBuilder`.
- `Sources/MacUpdaterCore/BugReportEnvironment.swift` — `ReportField` + `DiagnosticsSnapshot` → `[ReportField]`.

**Create (App):**
- `Sources/MacUpdater/URLOpening.swift` — protokół `URLOpening` + `WorkspaceURLOpener`.
- `Sources/MacUpdater/BugReportController.swift` — `@MainActor` model okna zgłoszenia.
- `Sources/MacUpdater/BugReportSheet.swift` — widok okna zgłoszenia.

**Modify:**
- `Sources/MacUpdaterCore/LogStore.swift` — `LogEntry.detail`, `fileText`, `parseLog`, zapis i odczyt.
- `Sources/MacUpdaterCore/WegaLog.swift` — przeciążenia z `detail:`, redakcja detalu do OSLog.
- `Sources/MacUpdaterCore/CatalogIssueBuilder.swift` — delegacja do `PrefilledURLBody`.
- `Sources/MacUpdaterCore/AppEndpoints.swift` — pole `supportEmail` + `supportEmailAddress`.
- `Sources/MacUpdaterCore/Resources/endpoints.json` — wartość `supportEmail`.
- `Sources/MacUpdaterCore/Translations.swift` — nowe klucze w `operations`.
- `Sources/MacUpdaterCore/ProcessRunner.swift` — detal przy niezerowym kodzie wyjścia.
- `Sources/MacUpdater/ScanStore+Updating.swift` — diagnostyka brew jako detal jednego wpisu.
- `Sources/MacUpdater/LogsView.swift` — `List(selection:)`, disclosure detalu, przycisk „Zgłoś błąd…".
- `docs/features.md`, `USER_GUIDE.md`.

**Test:**
- `Tests/MacUpdaterTests/LogDetailTests.swift`
- `Tests/MacUpdaterTests/LogEntryDetailSerializationTests.swift`
- `Tests/MacUpdaterTests/ProcessRunnerDetailTests.swift`
- `Tests/MacUpdaterTests/PrefilledURLBodyTests.swift`
- `Tests/MacUpdaterTests/BugReportBuilderTests.swift`
- `Tests/MacUpdaterTests/BugReportEnvironmentTests.swift`
- `Tests/MacUpdaterTests/AppEndpointsTests.swift` (rozszerzenie)
- `Tests/MacUpdaterUITests/BugReportControllerTests.swift`
- `Tests/MacUpdaterUITests/LogsSelectionTests.swift`

---

## Task 1: `LogDetail` — model i serializacja

**Files:**
- Create: `Sources/MacUpdaterCore/LogDetail.swift`
- Test: `Tests/MacUpdaterTests/LogDetailTests.swift`

**Interfaces:**
- Consumes: nic (pierwsze zadanie).
- Produces: `LogDetail`, `LogDetail.Field(key:value:)`, `LogDetail.continuationPrefix`, `LogDetail.outputMarker`, `LogDetail.maxOutputLines`, `LogDetail.maxOutputCharacters`, `LogDetail.maxSerializedCharacters`, `init(fields:output:)`, `init?(command:exitCode:stderr:subject:source:)`, `var continuationLines: [String]`, `static func parse(continuationLines:) -> LogDetail?`.

Format na dysku. Pola idą pierwsze, po jednym w linii; opcjonalne wyjście poprzedza znacznik, po którym każda kolejna linia jest dosłowną treścią:

```
\t| command: brew upgrade --cask foo
\t| exit: 1
\t| ---
\t| Error: Failure while executing…
\t| second line of stderr
```

Znacznik `---` jest jednoznaczny, więc `stderr` zawierające `": "` nie może zostać wzięte za pole. (Specyfikacja pokazywała w przykładzie `| stderr:`; to doprecyzowanie tej samej idei.)

- [ ] **Step 1: Napisz test**

`Tests/MacUpdaterTests/LogDetailTests.swift`:

```swift
import Foundation
import Testing
@testable import MacUpdaterCore

@Suite("LogDetail")
struct LogDetailTests {

    @Test func serializesFieldsAndOutputWithTheContinuationPrefix() {
        let detail = LogDetail(command: "brew upgrade --cask foo", exitCode: 1, stderr: "boom\nsecond")
        #expect(detail?.continuationLines == [
            "\t| command: brew upgrade --cask foo",
            "\t| exit: 1",
            "\t| ---",
            "\t| boom",
            "\t| second",
        ])
    }

    @Test func roundTripsThroughContinuationLines() throws {
        let original = try #require(LogDetail(
            command: "/usr/bin/env brew",
            exitCode: 2,
            stderr: "Error: something: with a colon",
            subject: "foo",
            source: "cask"
        ))
        #expect(LogDetail.parse(continuationLines: original.continuationLines) == original)
    }

    @Test func outputContainingTheFieldSeparatorIsNotMistakenForAField() {
        let detail = LogDetail(fields: [], output: "key: value")
        let parsed = LogDetail.parse(continuationLines: detail.continuationLines)
        #expect(parsed?.fields.isEmpty == true)
        #expect(parsed?.output == "key: value")
    }

    @Test func keepsTheTailOfAnOverlongOutput() throws {
        let lines = (1...200).map { "line \($0)" }.joined(separator: "\n")
        let detail = LogDetail(fields: [], output: lines)
        let kept = try #require(detail.output).split(separator: "\n")
        #expect(kept.count == LogDetail.maxOutputLines)
        #expect(kept.last == "line 200", "the tail matters — the failure is at the end")
    }

    @Test func capsOutputCharacterCount() {
        let detail = LogDetail(fields: [], output: String(repeating: "x", count: 10_000))
        #expect((detail.output ?? "").count <= LogDetail.maxOutputCharacters)
    }

    @Test func capsTheWholeSerializedDetail() {
        let fat = (1...100).map { _ in String(repeating: "y", count: 200) }.joined(separator: "\n")
        let detail = LogDetail(fields: [.init(key: "command", value: "brew")], output: fat)
        #expect(detail.continuationLines.joined(separator: "\n").count <= LogDetail.maxSerializedCharacters)
    }

    @Test func flattensNewlinesInsideAFieldValue() {
        let detail = LogDetail(fields: [.init(key: "command", value: "a\nb")], output: nil)
        #expect(detail.continuationLines == ["\t| command: a b"])
    }

    @Test func emptyInputParsesToNil() {
        #expect(LogDetail.parse(continuationLines: []) == nil)
    }

    @Test func aDetailWithNeitherFieldsNorOutputIsNil() {
        #expect(LogDetail(command: nil, exitCode: nil, stderr: nil) == nil)
    }
}
```

- [ ] **Step 2: (warunkowo) uruchom test i potwierdź Red**

Tylko jeśli użytkownik poprosił w tej sesji o uruchomienie testów:

```bash
swift test --filter LogDetail
```

Oczekiwane: FAIL — `cannot find 'LogDetail' in scope`.

- [ ] **Step 3: Zaimplementuj `LogDetail`**

`Sources/MacUpdaterCore/LogDetail.swift`:

```swift
import Foundation

/// Strukturalny kontekst jednej awarii, dopięty do wpisu logu, który wyjaśnia.
///
/// Istnieje, bo `LogEntry.message` jest jednym płaskim stringiem: `stderr`, kod wyjścia
/// i uruchomiona komenda nie miały gdzie wylądować i ginęły w `localizedDescription`.
/// Wpis mówił „aktualizacja nie powiodła się", a nie *dlaczego*.
///
/// Serializuje się do linii kontynuacji poprzedzonych ``continuationPrefix``. Stary
/// `LogEntry.parse` zwraca dla nich `nil`, a `LogStore.loadFromFile` je odfiltrowuje —
/// więc starsza wersja aplikacji czytająca nowszy plik gubi detal, zamiast się wywrócić.
public struct LogDetail: Equatable, Sendable {

    /// Jeden fakt o awarii: `command`, `exit`, `subject`, `source`.
    public struct Field: Equatable, Sendable {
        public let key: String
        public let value: String

        public init(key: String, value: String) {
            self.key = key
            self.value = Self.flattened(value)
        }

        /// Wartość pola zajmuje dokładnie jedną linię — inaczej rozerwałaby format.
        private static func flattened(_ value: String) -> String {
            value.replacingOccurrences(of: "\n", with: " ")
                 .replacingOccurrences(of: "\r", with: " ")
        }
    }

    /// Prefiks każdej linii detalu w pliku logu.
    public static let continuationPrefix = "\t| "
    /// Oddziela pola od dosłownego wyjścia. Jednoznaczny, więc `stderr` zawierające
    /// `": "` nie może zostać sparsowane jako pole.
    public static let outputMarker = "---"

    public static let maxOutputLines = 40
    public static let maxOutputCharacters = 4000
    public static let maxSerializedCharacters = 8000

    public let fields: [Field]
    public let output: String?

    public init(fields: [Field], output: String?) {
        self.fields = fields
        self.output = Self.capped(output)
    }

    /// Wygodny konstruktor dla typowej awarii procesu. Zwraca `nil`, gdy nie ma czego
    /// zapisać — wpis bez detalu serializuje się wtedy bajt w bajt tak jak dotąd.
    public init?(
        command: String? = nil,
        exitCode: Int32? = nil,
        stderr: String? = nil,
        subject: String? = nil,
        source: String? = nil
    ) {
        var fields: [Field] = []
        if let subject, !subject.isEmpty { fields.append(Field(key: "subject", value: subject)) }
        if let source, !source.isEmpty { fields.append(Field(key: "source", value: source)) }
        if let command, !command.isEmpty { fields.append(Field(key: "command", value: command)) }
        if let exitCode { fields.append(Field(key: "exit", value: String(exitCode))) }

        let trimmed = stderr?.trimmingCharacters(in: .whitespacesAndNewlines)
        let output = (trimmed?.isEmpty ?? true) ? nil : trimmed
        guard !fields.isEmpty || output != nil else { return nil }
        self.init(fields: fields, output: output)
    }

    /// Linie do zapisania w `wega.log`, z prefiksem włącznie.
    public var continuationLines: [String] {
        var lines = fields.map { "\(Self.continuationPrefix)\($0.key): \($0.value)" }
        if let output {
            lines.append("\(Self.continuationPrefix)\(Self.outputMarker)")
            lines.append(contentsOf: output.components(separatedBy: "\n")
                .map { "\(Self.continuationPrefix)\($0)" })
        }
        return Self.cappedSerialization(lines)
    }

    /// Odtwarza detal z linii kontynuacji. `nil`, gdy nie ma żadnych.
    public static func parse(continuationLines lines: [String]) -> LogDetail? {
        guard !lines.isEmpty else { return nil }
        var fields: [Field] = []
        var outputLines: [String] = []
        var inOutput = false

        for line in lines {
            let body = line.hasPrefix(continuationPrefix)
                ? String(line.dropFirst(continuationPrefix.count))
                : line
            if !inOutput, body == outputMarker { inOutput = true; continue }
            if inOutput { outputLines.append(body); continue }
            guard let separator = body.range(of: ": ") else { continue }
            fields.append(Field(
                key: String(body[body.startIndex..<separator.lowerBound]),
                value: String(body[separator.upperBound...])
            ))
        }
        guard !fields.isEmpty || inOutput else { return nil }
        return LogDetail(fields: fields, output: inOutput ? outputLines.joined(separator: "\n") : nil)
    }

    // MARK: - Limity

    /// Zachowuje **ogon** wyjścia: awaria jest na końcu, nie na początku.
    private static func capped(_ output: String?) -> String? {
        guard let output else { return nil }
        var lines = output.components(separatedBy: "\n")
        if lines.count > maxOutputLines { lines = Array(lines.suffix(maxOutputLines)) }
        var text = lines.joined(separator: "\n")
        if text.count > maxOutputCharacters { text = String(text.suffix(maxOutputCharacters)) }
        return text
    }

    /// Ostatnia bariera: jeden rozgadany proces nie może wyczerpać budżetu rotacji pliku
    /// jednym wpisem. Ucinane są najstarsze linie wyjścia, nigdy pola.
    private static func cappedSerialization(_ lines: [String]) -> [String] {
        var lines = lines
        let marker = "\(continuationPrefix)\(outputMarker)"
        while lines.joined(separator: "\n").count > maxSerializedCharacters,
              let markerIndex = lines.firstIndex(of: marker),
              lines.count > markerIndex + 1 {
            lines.remove(at: markerIndex + 1)
        }
        return lines
    }
}
```

- [ ] **Step 4: (warunkowo) uruchom test i potwierdź Green**

```bash
swift test --filter LogDetail
```

- [ ] **Step 5: Lint**

```bash
swiftlint lint --strict Sources/MacUpdaterCore/LogDetail.swift
```

- [ ] **Step 6: Commit**

```bash
git add Sources/MacUpdaterCore/LogDetail.swift Tests/MacUpdaterTests/LogDetailTests.swift
```

```bash
git commit -m "feat(logs): add a structured failure detail that serialises to continuation lines"
```

---

## Task 2: `LogEntry` niesie detal, `LogStore` go zapisuje i odczytuje

**Files:**
- Modify: `Sources/MacUpdaterCore/LogStore.swift`
- Test: `Tests/MacUpdaterTests/LogEntryDetailSerializationTests.swift`

**Interfaces:**
- Consumes: `LogDetail`, `LogDetail.continuationPrefix`, `LogDetail.parse(continuationLines:)`, `LogDetail.continuationLines` (Task 1).
- Produces: `LogEntry.detail: LogDetail?`, `LogEntry.init(id:date:level:category:message:detail:)`, `LogEntry.fileText: String`, `LogEntry.parseLog(_:) -> [LogEntry]`. `LogEntry.fileLine` i `LogEntry.parse(_:)` zachowują dotychczasowe zachowanie.

- [ ] **Step 1: Napisz test**

`Tests/MacUpdaterTests/LogEntryDetailSerializationTests.swift`:

```swift
import Foundation
import Testing
@testable import MacUpdaterCore

@Suite("LogEntry detail serialization")
struct LogEntryDetailSerializationTests {

    private func entry(_ message: String, detail: LogDetail? = nil) -> LogEntry {
        LogEntry(date: Date(timeIntervalSince1970: 1_770_000_000),
                 level: .error, category: .homebrew, message: message, detail: detail)
    }

    @Test func anEntryWithoutADetailSerialisesExactlyAsBefore() {
        let plain = entry("foo się wywalił")
        #expect(plain.fileText == plain.fileLine)
        #expect(plain.fileText.contains("\n") == false)
    }

    @Test func anEntryWithADetailAppendsContinuationLines() {
        let detailed = entry("foo się wywalił",
                             detail: LogDetail(command: "brew upgrade --cask foo", exitCode: 1, stderr: "boom"))
        let lines = detailed.fileText.components(separatedBy: "\n")
        #expect(lines.first == detailed.fileLine)
        #expect(lines.dropFirst().allSatisfy { $0.hasPrefix(LogDetail.continuationPrefix) })
    }

    @Test func parseLogRoundTripsAnEntryWithItsDetail() {
        let original = entry("foo się wywalił",
                             detail: LogDetail(command: "brew upgrade --cask foo", exitCode: 1, stderr: "boom"))
        let parsed = LogEntry.parseLog(original.fileText)
        #expect(parsed.count == 1)
        #expect(parsed.first?.message == original.message)
        #expect(parsed.first?.detail == original.detail)
    }

    @Test func theLegacySingleLineParserStillIgnoresContinuationLines() {
        // Gwarancja wstecz: starsza wersja aplikacji czytająca nowszy plik gubi detal,
        // ale nie tworzy z niego fałszywego wpisu i nie wywraca się.
        #expect(LogEntry.parse("\t| command: brew upgrade --cask foo") == nil)
    }

    @Test func orphanContinuationLinesAtTheStartOfATailAreDropped() {
        // `loadFromFile` bierze ogon pliku, który może zaczynać się w środku wpisu.
        let text = ["\t| exit: 1", "\t| ---", "\t| boom", entry("kolejny wpis").fileLine]
            .joined(separator: "\n")
        let parsed = LogEntry.parseLog(text)
        #expect(parsed.count == 1)
        #expect(parsed.first?.message == "kolejny wpis")
        #expect(parsed.first?.detail == nil, "sieroce linie nie mogą przykleić się do następnego wpisu")
    }

    @MainActor
    @Test func aStoreRoundTripsADetailThroughTheRealFile() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wega-logdetail-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = LogStore(directory: directory)
        let detail = LogDetail(command: "brew upgrade --cask foo", exitCode: 1, stderr: "boom")
        store.append(entry("foo się wywalił", detail: detail))
        store.flushForTests()

        let reloaded = LogStore(directory: directory)
        #expect(reloaded.entries.count == 1)
        #expect(reloaded.entries.first?.detail == detail)
    }
}
```

- [ ] **Step 2: (warunkowo) uruchom test i potwierdź Red**

```bash
swift test --filter LogEntryDetailSerializationTests
```

Oczekiwane: FAIL — brak argumentu `detail:` w `LogEntry.init` oraz brak `fileText` / `parseLog`.

- [ ] **Step 3: Rozszerz `LogEntry`**

W `Sources/MacUpdaterCore/LogStore.swift`, w `struct LogEntry`, dodaj pole i rozszerz inicjalizator:

```swift
    public let message: String
    /// Strukturalny kontekst awarii, gdy wpis go niesie. Opcjonalny, więc każde
    /// istniejące wywołanie `WegaLog.error(...)` kompiluje się bez zmian.
    public let detail: LogDetail?

    public init(id: UUID = UUID(), date: Date, level: LogLevel,
                category: LogCategory, message: String, detail: LogDetail? = nil) {
        self.id = id
        self.date = date
        self.level = level
        self.category = category
        self.message = message
        self.detail = detail
    }
```

Pod istniejącym `fileLine` dodaj:

```swift
    /// Wszystko, co ten wpis zapisuje do pliku: linia nagłówka plus linie detalu.
    /// Dla wpisu bez detalu jest bajt w bajt równe ``fileLine``, więc żaden istniejący
    /// `wega.log` nie wymaga migracji.
    public var fileText: String {
        guard let detail else { return fileLine }
        return ([fileLine] + detail.continuationLines).joined(separator: "\n")
    }

    /// Parsuje cały fragment pliku, sklejając linie kontynuacji z wpisem, który je
    /// poprzedza. Sieroce linie kontynuacji — ogon pliku potrafi zacząć się w środku
    /// wpisu — są odrzucane, nie doklejane do następnego wpisu.
    public static func parseLog(_ text: String) -> [LogEntry] {
        var entries: [LogEntry] = []
        var pendingHeader: LogEntry?
        var pendingDetail: [String] = []

        func flush() {
            guard let header = pendingHeader else { pendingDetail = []; return }
            entries.append(LogEntry(
                id: header.id, date: header.date, level: header.level,
                category: header.category, message: header.message,
                detail: LogDetail.parse(continuationLines: pendingDetail)
            ))
            pendingHeader = nil
            pendingDetail = []
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) {
            if line.hasPrefix(LogDetail.continuationPrefix) {
                if pendingHeader != nil { pendingDetail.append(line) }
                continue
            }
            flush()
            pendingHeader = LogEntry.parse(line)
        }
        flush()
        return entries
    }
```

- [ ] **Step 4: Zapisuj i odczytuj `fileText` w `LogStore`**

W `LogStore.append(_:)` zamień `let line = entry.fileLine` na:

```swift
        let line = entry.fileText
```

W `LogStore.loadFromFile()` zamień ciało na:

```swift
    public func loadFromFile() {
        guard let content = try? String(contentsOf: logFileURL, encoding: .utf8) else { return }
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let tail = lines.suffix(loadTailLines)
        entries = Array(LogEntry.parseLog(tail.joined(separator: "\n")).suffix(memoryCap))
    }
```

`rotateIfNeeded(incoming:)` liczy już `line.utf8.count + 1`, a `line` jest teraz pełnym `fileText` — nic więcej nie trzeba zmieniać.

- [ ] **Step 5: (warunkowo) uruchom testy i potwierdź Green**

```bash
swift test --filter LogEntryDetailSerializationTests
```

```bash
swift test --filter LogStore
```

Drugi filtr to regresja: istniejące testy `LogStore` muszą przejść bez zmian.

- [ ] **Step 6: Lint i commit**

```bash
swiftlint lint --strict Sources/MacUpdaterCore/LogStore.swift
```

```bash
git add Sources/MacUpdaterCore/LogStore.swift Tests/MacUpdaterTests/LogEntryDetailSerializationTests.swift
```

```bash
git commit -m "feat(logs): carry a failure detail on a log entry and persist it as continuation lines"
```

---

## Task 3: `WegaLog` przyjmuje detal i redaguje go do OSLog

**Files:**
- Modify: `Sources/MacUpdaterCore/WegaLog.swift`
- Modify: `Sources/MacUpdaterCore/LogDetail.swift`
- Test: `Tests/MacUpdaterTests/LogDetailTests.swift` (dopisanie suite'a)

**Interfaces:**
- Consumes: `LogDetail` (Task 1), `LogEntry.init(…detail:)` (Task 2).
- Produces: `WegaLog.error(_:_:detail:)`, `WegaLog.warning(_:_:detail:)`, `WegaLog.info(_:_:detail:)`, `WegaLog.debug(_:_:detail:)`, `WegaLog.log(_:_:_:detail:)`, `LogDetail.redacted(using:)`.

- [ ] **Step 1: Napisz test**

Dopisz na końcu `Tests/MacUpdaterTests/LogDetailTests.swift`:

```swift
@Suite("LogDetail redaction")
struct LogDetailRedactionTests {

    @Test func redactionReachesBothFieldsAndOutput() {
        let detail = LogDetail(
            fields: [.init(key: "command", value: "cp /Users/ala/Desktop/a.app /Applications")],
            output: "token=ghp_0123456789abcdefghij failed"
        )
        let redacted = detail.redacted(using: LogRedaction.redact)
        #expect(redacted.fields.first?.value.contains("/Users/ala") == false)
        #expect(redacted.fields.first?.value.contains(LogRedaction.pathPlaceholder) == true)
        #expect(redacted.output?.contains("ghp_0123456789abcdefghij") == false)
    }
}
```

- [ ] **Step 2: (warunkowo) uruchom test i potwierdź Red**

```bash
swift test --filter LogDetailRedactionTests
```

Oczekiwane: FAIL — `value of type 'LogDetail' has no member 'redacted'`.

- [ ] **Step 3: Dodaj `redacted(using:)` do `LogDetail`**

W `Sources/MacUpdaterCore/LogDetail.swift`, wewnątrz `public struct LogDetail`, po `parse(continuationLines:)`:

```swift
    /// Ten sam detal z każdą wartością przepuszczoną przez `transform`. Używane, żeby
    /// kanał OSLog dostał tekst zredagowany dokładnie tak jak `message`.
    public func redacted(using transform: (String) -> String) -> LogDetail {
        LogDetail(
            fields: fields.map { Field(key: $0.key, value: transform($0.value)) },
            output: output.map(transform)
        )
    }
```

- [ ] **Step 4: Rozszerz `WegaLog`**

Zamień całą zawartość `Sources/MacUpdaterCore/WegaLog.swift` na:

```swift
import OSLog

public enum WegaLog {
    public static func debug(_ category: LogCategory, _ message: String, detail: LogDetail? = nil) {
        log(.debug, category, message, detail: detail)
    }
    public static func info(_ category: LogCategory, _ message: String, detail: LogDetail? = nil) {
        log(.info, category, message, detail: detail)
    }
    public static func warning(_ category: LogCategory, _ message: String, detail: LogDetail? = nil) {
        log(.warning, category, message, detail: detail)
    }
    public static func error(_ category: LogCategory, _ message: String, detail: LogDetail? = nil) {
        log(.error, category, message, detail: detail)
    }

    public static func log(_ level: LogLevel, _ category: LogCategory, _ message: String,
                           detail: LogDetail? = nil) {
        let entry = LogEntry(date: Date(), level: level, category: category,
                             message: message, detail: detail)

        // SEC-09: privacy is set per field. The category is structural, not user data,
        // so it stays `.public`; the message is user data and is `.private` by default —
        // OSLog renders it `<private>` to any other process reading the unified log. The
        // message is additionally redacted (paths and query strings stripped) so that even
        // a build configured to show private data cannot reconstruct the user's app profile
        // from the system log. The full, un-redacted line still reaches the `0600` `wega.log`.
        //
        // The failure detail carries the same class of data — a command line, a `stderr`
        // block — so it takes the same route: redacted, `.private`, folded onto the line.
        let logger = osLogger(for: category)
        let suffix = detail
            .map { " " + $0.redacted(using: LogRedaction.redact).continuationLines.joined(separator: " ") }
            ?? ""
        let text = LogRedaction.redact(message) + suffix
        switch level {
        case .debug:   logger.debug("\(category.label, privacy: .public): \(text, privacy: .private)")
        case .info:    logger.info("\(category.label, privacy: .public): \(text, privacy: .private)")
        case .warning: logger.notice("\(category.label, privacy: .public): \(text, privacy: .private)")
        case .error:   logger.error("\(category.label, privacy: .public): \(text, privacy: .private)")
        }

        Task { @MainActor in LogStore.shared.append(entry) }
    }

    private static func osLogger(for category: LogCategory) -> Logger {
        switch category {
        case .app:      return AppLogger.app
        case .process:  return AppLogger.process
        case .homebrew: return AppLogger.homebrew
        case .scanner:  return AppLogger.scanner
        case .network:  return AppLogger.network
        case .helper:   return AppLogger.helper
        }
    }
}
```

- [ ] **Step 5: (warunkowo) uruchom testy i potwierdź Green**

```bash
swift test --filter LogDetail
```

- [ ] **Step 6: Lint i commit**

```bash
swiftlint lint --strict Sources/MacUpdaterCore/WegaLog.swift
```

```bash
git add Sources/MacUpdaterCore/WegaLog.swift Sources/MacUpdaterCore/LogDetail.swift Tests/MacUpdaterTests/LogDetailTests.swift
```

```bash
git commit -m "feat(logs): accept a failure detail on the logging facade and redact it for OSLog"
```

---

## Task 4: Podłącz detal tam, gdzie `stderr` dziś ginie

**Files:**
- Modify: `Sources/MacUpdaterCore/ProcessRunner.swift` (blok niezerowego kodu wyjścia, ok. linii 317–322)
- Modify: `Sources/MacUpdater/ScanStore+Updating.swift` (ok. linii 364–370)
- Test: `Tests/MacUpdaterTests/ProcessRunnerDetailTests.swift`

**Interfaces:**
- Consumes: `LogDetail.init?(command:exitCode:stderr:subject:source:)` (Task 1), `WegaLog.debug(_:_:detail:)` / `WegaLog.error(_:_:detail:)` (Task 3).
- Produces: nic dla dalszych zadań.

Dwa miejsca, bo to one dziś **bezpowrotnie** tracą `stderr`. Pozostałe z 71 wywołań `WegaLog.error` migrują przy okazji — świadomie poza zakresem tej gałęzi.

- [ ] **Step 1: Napisz test**

`Tests/MacUpdaterTests/ProcessRunnerDetailTests.swift`:

```swift
import Foundation
import Testing
@testable import MacUpdaterCore

@Suite("ProcessRunner failure detail")
struct ProcessRunnerDetailTests {

    /// Gwarancja przypięta w źródle: cofnięcie tej zmiany oznacza, że każda awaria
    /// procesu znów mówi tylko „exited 1", bez powodu.
    @Test func nonZeroExitAttachesCommandAndStderrToTheLogEntry() throws {
        let source = try Self.source("Sources/MacUpdaterCore/ProcessRunner.swift")
        #expect(source.contains("detail: LogDetail("))
        #expect(source.contains("stderr: result.stderr"))
        #expect(source.contains("exitCode: result.exitCode"))
    }

    @Test func aFailedRunCarriesStderrInTheDetail() async throws {
        let result = try await ProcessRunner().run(ProcessRequest(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "echo boom >&2; exit 3"],
            environment: [:],
            inheritParentEnvironment: false,
            timeouts: .quick
        ))
        #expect(result.exitCode == 3)
        let detail = try #require(LogDetail(
            command: "sh", exitCode: result.exitCode, stderr: result.stderr
        ))
        #expect(detail.output?.contains("boom") == true)
        #expect(detail.fields.contains(LogDetail.Field(key: "exit", value: "3")))
    }

    private static func source(_ relativePath: String, file: String = #filePath) throws -> String {
        let root = URL(fileURLWithPath: file)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
```

- [ ] **Step 2: (warunkowo) uruchom test i potwierdź Red**

```bash
swift test --filter ProcessRunnerDetailTests
```

Oczekiwane: FAIL na `source.contains("detail: LogDetail(")`.

- [ ] **Step 3: Dopnij detal w `ProcessRunner`**

W `Sources/MacUpdaterCore/ProcessRunner.swift` zamień blok niezerowego wyjścia na:

```swift
        // Non-zero is often domain-meaningful (handled by callers), so keep it at
        // debug — available for diagnosis without escalating it to a warning/error.
        // The detail is what makes it diagnosable at all: without it the line said
        // "exited 1" and threw the tool's own explanation away.
        if result.exitCode != 0 {
            WegaLog.debug(
                .process,
                "\(request.executableURL.lastPathComponent) exited \(result.exitCode)",
                detail: LogDetail(
                    command: ([request.executableURL.lastPathComponent] + request.arguments)
                        .joined(separator: " "),
                    exitCode: result.exitCode,
                    stderr: result.stderr
                )
            )
        }
```

- [ ] **Step 4: Zwiń diagnostykę brew w jeden wpis z detalem**

W `Sources/MacUpdater/ScanStore+Updating.swift` zamień osobny wpis „Aktualizacja niekompletna" **wraz z** następującą po nim pętlą `for line in summary.diagnostics { WegaLog.error(.homebrew, line) }` na:

```swift
        // Surface *why* each upgrade failed — the brew error block, not just the token
        // name — so the log explains the failure instead of only flagging it. The block
        // rides on the failure entry as one detail rather than as N loose lines, so
        // selecting that entry for a bug report carries the explanation with it.
        WegaLog.error(
            .homebrew,
            "Aktualizacja niekompletna: \(failedNames.isEmpty ? "Brew zgłosił błąd" : failedNames.joined(separator: ", "))",
            detail: LogDetail(
                source: "cask",
                stderr: summary.diagnostics.joined(separator: "\n")
            )
        )
```

Pętla `for outcome in summary.notUpgraded { … }` zostaje bez zmian.

- [ ] **Step 5: (warunkowo) uruchom testy i potwierdź Green**

```bash
swift test --filter ProcessRunnerDetailTests
```

- [ ] **Step 6: Lint i commit**

```bash
swiftlint lint --strict
```

```bash
git add Sources/MacUpdaterCore/ProcessRunner.swift Sources/MacUpdater/ScanStore+Updating.swift Tests/MacUpdaterTests/ProcessRunnerDetailTests.swift
```

```bash
git commit -m "feat(logs): attach the command, exit code and stderr to process and cask failures"
```

---

## Task 5: `PrefilledURLBody` — wspólne kodowanie i przycinanie

**Files:**
- Create: `Sources/MacUpdaterCore/PrefilledURLBody.swift`
- Modify: `Sources/MacUpdaterCore/CatalogIssueBuilder.swift` (sekcja `MARK: - Percent-encoding`)
- Test: `Tests/MacUpdaterTests/PrefilledURLBodyTests.swift`

**Interfaces:**
- Consumes: nic.
- Produces: `PrefilledURLBody.percentEncoded(_:) -> String`, `PrefilledURLBody.truncatedEncoded(_:toEncodedLength:) -> String`.

Refaktor bez zmiany zachowania. Istniejące `CatalogIssueBuilderTests` są siatką bezpieczeństwa — **muszą przejść bez żadnej modyfikacji**.

- [ ] **Step 1: Napisz test**

`Tests/MacUpdaterTests/PrefilledURLBodyTests.swift`:

```swift
import Foundation
import Testing
@testable import MacUpdaterCore

@Suite("PrefilledURLBody")
struct PrefilledURLBodyTests {

    @Test func encodesEverythingOutsideTheUnreservedSet() {
        #expect(PrefilledURLBody.percentEncoded("a b&c#d/e?f:g+h") ==
                "a%20b%26c%23d%2Fe%3Ff%3Ag%2Bh")
    }

    @Test func leavesUnreservedCharactersAlone() {
        #expect(PrefilledURLBody.percentEncoded("aZ0-._~") == "aZ0-._~")
    }

    @Test func truncationNeverSplitsAPercentTriplet() {
        let raw = String(repeating: "ł", count: 50)   // każdy znak koduje się na %C5%82
        for limit in 0...60 {
            let encoded = PrefilledURLBody.truncatedEncoded(raw, toEncodedLength: limit)
            #expect(encoded.count <= limit)
            #expect(encoded.count % 6 == 0, "granica musi wypadać na całym znaku")
        }
    }

    @Test func truncationKeepsTheLongestFittingPrefix() {
        #expect(PrefilledURLBody.truncatedEncoded("abcdef", toEncodedLength: 4) == "abcd")
    }
}
```

- [ ] **Step 2: (warunkowo) uruchom test i potwierdź Red**

```bash
swift test --filter PrefilledURLBody
```

Oczekiwane: FAIL — `cannot find 'PrefilledURLBody' in scope`.

- [ ] **Step 3: Utwórz `PrefilledURLBody`**

`Sources/MacUpdaterCore/PrefilledURLBody.swift`:

```swift
import Foundation

/// Kodowanie i przycinanie treści wstawianej do prefillowanego URL-a — wspólne dla
/// zgłoszenia do katalogu (``CatalogIssueBuilder``) i zgłoszenia błędu (``BugReportBuilder``).
///
/// Wydzielone, bo obie ścieżki muszą przycinać *dokładnie tak samo*: granica na całym
/// znaku, nigdy w środku trypletu `%XX`. Dwie kopie tej logiki to dwie okazje, żeby jedna
/// z nich zaczęła produkować URL-e, których odbiorca nie zdekoduje.
public enum PrefilledURLBody {

    /// RFC 3986 unreserved characters only, so nothing that could break out of a query value
    /// (spaces, `&`, `#`, `+`, `/`, `?`, `:` …) survives unescaped.
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    public static func percentEncoded(_ string: String) -> String {
        string.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    /// Returns the percent-encoded form of the longest whole-character prefix of `raw` whose
    /// encoding fits `limit`. Because encoded length grows monotonically with the prefix
    /// length, the boundary is found with a binary search — and cutting on `Character`
    /// boundaries guarantees a `%XX` triplet is never split.
    public static func truncatedEncoded(_ raw: String, toEncodedLength limit: Int) -> String {
        let chars = Array(raw)
        var low = 0
        var high = chars.count
        var best = 0
        while low <= high {
            let mid = (low + high) / 2
            if percentEncoded(String(chars[0..<mid])).count <= limit {
                best = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return percentEncoded(String(chars[0..<best]))
    }
}
```

- [ ] **Step 4: Oddeleguj `CatalogIssueBuilder`**

W `Sources/MacUpdaterCore/CatalogIssueBuilder.swift` usuń prywatną stałą `unreserved` oraz ciała obu metod i zostaw delegacje (sygnatury zostają — istniejące testy ich używają):

```swift
    // MARK: - Percent-encoding
    //
    // Sama mechanika żyje w `PrefilledURLBody`, wspólnie ze zgłoszeniem błędu: obie
    // ścieżki muszą przycinać identycznie, a jedna implementacja to gwarantuje.

    static func percentEncoded(_ string: String) -> String {
        PrefilledURLBody.percentEncoded(string)
    }

    static func truncatedEncodedBody(_ raw: String, toEncodedLength limit: Int) -> String {
        PrefilledURLBody.truncatedEncoded(raw, toEncodedLength: limit)
    }
```

- [ ] **Step 5: (warunkowo) uruchom testy i potwierdź Green**

```bash
swift test --filter PrefilledURLBody
```

```bash
swift test --filter CatalogIssueBuilder
```

Drugi filtr jest istotą tego zadania: refaktor jest poprawny wtedy i tylko wtedy, gdy nietknięte testy `CatalogIssueBuilder` przechodzą.

- [ ] **Step 6: Lint i commit**

```bash
swiftlint lint --strict Sources/MacUpdaterCore/PrefilledURLBody.swift
```

```bash
git add Sources/MacUpdaterCore/PrefilledURLBody.swift Sources/MacUpdaterCore/CatalogIssueBuilder.swift Tests/MacUpdaterTests/PrefilledURLBodyTests.swift
```

```bash
git commit -m "refactor(core): share percent-encoding and truncation between prefilled-URL builders"
```

---

## Task 6: `supportEmail` w konfiguracji endpointów

**Files:**
- Modify: `Sources/MacUpdaterCore/Resources/endpoints.json`
- Modify: `Sources/MacUpdaterCore/AppEndpoints.swift`
- Test: `Tests/MacUpdaterTests/AppEndpointsTests.swift`

**Interfaces:**
- Consumes: nic.
- Produces: `AppEndpoints.supportEmail: String`, `AppEndpoints.supportEmailAddress: String`.

`AppEndpoints` jest `Decodable` z pól nieopcjonalnych — **brak klucza w JSON to `fatalError` przy starcie**, więc JSON i typ zmieniają się w jednym kroku.

`AppEndpointsTests` używa XCTest; nowy test dopisujemy w tym samym stylu co plik, do którego trafia.

- [ ] **Step 1: Napisz test**

Dopisz do `Tests/MacUpdaterTests/AppEndpointsTests.swift`, obok `testProjectNewIssueEndpointIsConfigured`:

```swift
    // Zgłoszenie błędu z zakładki Logi otwiera domyślnego klienta poczty pod tym adresem,
    // więc musi być obecny w konfiguracji — inaczej kanał e-mail cicho przestaje istnieć.
    func testSupportEmailIsConfigured() throws {
        let e = try AppEndpoints.loadBundled()
        XCTAssertEqual(e.supportEmailAddress, "wegamacupdater.unbroken239@passmail.net")
        XCTAssertTrue(e.supportEmailAddress.contains("@"), "musi być adresem, nie URL-em")
        XCTAssertFalse(e.supportEmailAddress.hasPrefix("mailto:"),
                       "schemat dokłada builder — konfiguracja trzyma sam adres")
    }
```

- [ ] **Step 2: (warunkowo) uruchom test i potwierdź Red**

```bash
swift test --filter AppEndpoints
```

Oczekiwane: FAIL — `value of type 'AppEndpoints' has no member 'supportEmailAddress'`.

- [ ] **Step 3: Dodaj wartość do JSON**

W `Sources/MacUpdaterCore/Resources/endpoints.json`, bezpośrednio po linii `"projectNewIssue"`:

```json
  "supportEmail": "wegamacupdater.unbroken239@passmail.net",
```

- [ ] **Step 4: Dodaj pole i akcesor**

W `Sources/MacUpdaterCore/AppEndpoints.swift`, po deklaracji `public let projectNewIssue: String`:

```swift
    /// Odbiorca zgłoszeń błędów wysyłanych z zakładki Logi. Trzymany jako sam adres —
    /// schemat `mailto:` dokłada ``BugReportBuilder``, więc overlay użytkownika nie może
    /// podmienić go na URL o innym schemacie.
    public let supportEmail: String
```

W sekcji `MARK: Fixed endpoints`, obok `projectNewIssueURL`:

```swift
    public var supportEmailAddress: String { supportEmail }
```

- [ ] **Step 5: (warunkowo) uruchom test i potwierdź Green**

```bash
swift test --filter AppEndpoints
```

- [ ] **Step 6: Lint i commit**

```bash
swiftlint lint --strict Sources/MacUpdaterCore/AppEndpoints.swift
```

```bash
git add Sources/MacUpdaterCore/AppEndpoints.swift Sources/MacUpdaterCore/Resources/endpoints.json Tests/MacUpdaterTests/AppEndpointsTests.swift
```

```bash
git commit -m "feat(config): configure the bug-report recipient address in endpoints.json"
```

---

## Task 7: Metryczka środowiska z `DiagnosticsSnapshot`

**Files:**
- Create: `Sources/MacUpdaterCore/BugReportEnvironment.swift`
- Test: `Tests/MacUpdaterTests/BugReportEnvironmentTests.swift`

**Interfaces:**
- Consumes: `DiagnosticsSnapshot` (istniejący, inicjalizator `init(runtime:managers:helper:schedule:scan:system:artifacts:)`).
- Produces: `ReportField(label:value:)`, `BugReportEnvironment.fields(from: DiagnosticsSnapshot) -> [ReportField]`.

`ReportField` powstaje tutaj, bo tutaj jest jego pierwszy producent; `BugReportDraft` w Task 8 go konsumuje.

- [ ] **Step 1: Napisz test**

`Tests/MacUpdaterTests/BugReportEnvironmentTests.swift`:

```swift
import Foundation
import Testing
@testable import MacUpdaterCore

@Suite("BugReportEnvironment")
struct BugReportEnvironmentTests {

    static func snapshot(lastScanAt: Date? = Date(timeIntervalSince1970: 1_769_990_000),
                         complete: Bool = true) -> DiagnosticsSnapshot {
        DiagnosticsSnapshot(
            runtime: .init(
                generatedAt: Date(timeIntervalSince1970: 1_770_000_000),
                appVersion: "1.4.2", appBuild: "812",
                bundleIdentifier: "pl.wega.MacUpdater",
                osVersion: "Version 26.1 (Build 26A1)",
                architecture: "arm64", processorCount: 12
            ),
            managers: [
                .init(name: "Homebrew", version: "4.3.0", detected: true),
                .init(name: "mas-cli", version: nil, detected: false),
            ],
            helper: .init(status: "enabled", expectedVersion: "3",
                          reportedVersion: "3", teamIDConfigured: true),
            schedule: .init(interval: "daily", lastCheck: nil, nextCheck: nil,
                            lastCheckFailed: false, launchAtLogin: true,
                            backgroundUpdatesEnabled: false),
            scan: .init(lastScanAt: lastScanAt, complete: complete, sourceResults: []),
            system: .init(freeDiskBytes: nil, signatures: [],
                          appManagementPermission: "granted"),
            artifacts: .init(history: [], logFiles: [], logWriteFailureCount: 0)
        )
    }

    private func byLabel(_ snapshot: DiagnosticsSnapshot) -> [String: String] {
        Dictionary(uniqueKeysWithValues:
            BugReportEnvironment.fields(from: snapshot).map { ($0.label, $0.value) })
    }

    @Test func reportsTheFactsAMaintainerAlwaysAsksFor() {
        let fields = byLabel(Self.snapshot())
        #expect(fields["Wega"] == "1.4.2 (812)")
        #expect(fields["macOS"] == "Version 26.1 (Build 26A1) (arm64)")
        #expect(fields["Homebrew"] == "4.3.0")
        #expect(fields["mas-cli"] == "not detected")
        #expect(fields["Privileged helper"] == "enabled")
    }

    @Test func labelsAreStableAndOrdered() {
        let labels = BugReportEnvironment.fields(from: Self.snapshot()).map(\.label)
        #expect(labels.first == "Wega")
        #expect(labels.contains("Last scan"))
    }

    @Test func aScanThatNeverRanSaysSoRatherThanBeingOmitted() {
        #expect(byLabel(Self.snapshot(lastScanAt: nil, complete: false))["Last scan"] == "never")
    }

    @Test func anIncompleteScanIsMarkedAsSuch() throws {
        let value = try #require(byLabel(Self.snapshot(complete: false))["Last scan"])
        #expect(value.hasSuffix("(incomplete)"))
    }
}
```

- [ ] **Step 2: (warunkowo) uruchom test i potwierdź Red**

```bash
swift test --filter BugReportEnvironment
```

Oczekiwane: FAIL — `cannot find 'BugReportEnvironment' in scope`.

- [ ] **Step 3: Zaimplementuj**

`Sources/MacUpdaterCore/BugReportEnvironment.swift`:

```swift
import Foundation

/// Jeden wiersz metryczki środowiska w zgłoszeniu: `- Homebrew: 4.3.0`.
///
/// Etykiety są angielskie i stabilne — zgłoszenie to wymiana danych między użytkownikiem
/// a maintainerem i musi czytać się tak samo niezależnie od języka UI, dokładnie jak
/// ``DiagnosticsBundle``.
public struct ReportField: Sendable, Equatable {
    public let label: String
    public let value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

/// Zwęża ``DiagnosticsSnapshot`` do tych kilku faktów, o które maintainer i tak zawsze
/// dopytuje. Nie zbiera niczego sam: pełny snapshot jest już budowany na potrzeby paczki
/// diagnostycznej, a to jest jego widok, nie drugie źródło prawdy.
public enum BugReportEnvironment {

    public static func fields(from snapshot: DiagnosticsSnapshot) -> [ReportField] {
        var fields: [ReportField] = [
            ReportField(label: "Wega", value: "\(snapshot.appVersion) (\(snapshot.appBuild))"),
            ReportField(label: "macOS", value: "\(snapshot.osVersion) (\(snapshot.architecture))"),
        ]
        for manager in snapshot.managers {
            fields.append(ReportField(
                label: manager.name,
                value: manager.detected ? (manager.version ?? "detected, version unknown") : "not detected"
            ))
        }
        fields.append(ReportField(label: "Privileged helper", value: snapshot.helper.status))
        fields.append(ReportField(label: "Last scan", value: lastScan(snapshot)))
        return fields
    }

    private static func lastScan(_ snapshot: DiagnosticsSnapshot) -> String {
        guard let date = snapshot.lastScanAt else { return "never" }
        let stamp = iso.string(from: date)
        return snapshot.lastScanComplete ? "\(stamp) (complete)" : "\(stamp) (incomplete)"
    }

    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()
}
```

- [ ] **Step 4: (warunkowo) uruchom test i potwierdź Green**

```bash
swift test --filter BugReportEnvironment
```

- [ ] **Step 5: Lint i commit**

```bash
swiftlint lint --strict Sources/MacUpdaterCore/BugReportEnvironment.swift
```

```bash
git add Sources/MacUpdaterCore/BugReportEnvironment.swift Tests/MacUpdaterTests/BugReportEnvironmentTests.swift
```

```bash
git commit -m "feat(report): narrow a diagnostics snapshot to the environment a bug report needs"
```

---

## Task 8: `BugReportBuilder` — tytuł, treść, przycinanie, URL

**Files:**
- Create: `Sources/MacUpdaterCore/BugReport.swift`
- Test: `Tests/MacUpdaterTests/BugReportBuilderTests.swift`

**Interfaces:**
- Consumes: `ReportField` (Task 7), `LogEntry` / `LogEntry.fileText` (Task 2), `PrefilledURLBody` (Task 5), `LogRedaction.redactForExport(_:userNames:)` (istniejący).
- Produces: `BugReportDraft(userDescription:environment:entries:)`, `BugReportChannel.email(address:)` / `.gitHubIssue(endpoint:)` / `.urlLengthLimit`, `BugReportBody(text:omittedEntryCount:)`, `BugReportBuilder(redact:)`, `.title(_:)`, `.body(_:channel:)`, `.url(_:channel:)`, `BugReportBuilder.maxTitleLength`.

- [ ] **Step 1: Napisz test**

`Tests/MacUpdaterTests/BugReportBuilderTests.swift`:

```swift
import Foundation
import Testing
@testable import MacUpdaterCore

@Suite("BugReportBuilder")
struct BugReportBuilderTests {

    private let gitHub = BugReportChannel.gitHubIssue(
        endpoint: URL(string: "https://github.com/owner/repo/issues/new")!
    )
    private let email = BugReportChannel.email(address: "bugs@example.test")

    private func entry(_ message: String, level: LogLevel = .error,
                       at seconds: TimeInterval = 1_770_000_000,
                       detail: LogDetail? = nil) -> LogEntry {
        LogEntry(date: Date(timeIntervalSince1970: seconds), level: level,
                 category: .homebrew, message: message, detail: detail)
    }

    private func draft(entries: [LogEntry],
                       description: String = "Kliknąłem aktualizuj.") -> BugReportDraft {
        BugReportDraft(
            userDescription: description,
            environment: [ReportField(label: "Wega", value: "1.4.2 (812)")],
            entries: entries
        )
    }

    private func fatDraft() -> BugReportDraft {
        draft(entries: (1...300).map {
            entry("entry-\($0) " + String(repeating: "x", count: 200), at: TimeInterval($0))
        })
    }

    private static func queryItems(_ url: URL) throws -> [String: String] {
        let comps = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        return Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    // MARK: Tytuł

    @Test func titleComesFromTheNewestErrorEntry() {
        let title = BugReportBuilder().title(draft(entries: [
            entry("stary błąd", at: 1),
            entry("świeży błąd", at: 2),
            entry("zwykła informacja", level: .info, at: 3),
        ]))
        #expect(title == "[Bug] świeży błąd")
    }

    @Test func titleFallsBackToTheNewestEntryWhenNothingFailed() {
        let title = BugReportBuilder().title(draft(entries: [entry("wszystko gra", level: .info)]))
        #expect(title == "[Bug] wszystko gra")
    }

    @Test func titleIsNeverTruncatedByTheURLLimit() throws {
        let builder = BugReportBuilder()
        let d = fatDraft()
        let url = try #require(builder.url(d, channel: email))
        let items = try Self.queryItems(url)
        #expect(items["subject"] == builder.title(d))
    }

    // MARK: Treść

    @Test func bodyCarriesDescriptionEnvironmentAndEntries() {
        let text = BugReportBuilder().body(draft(entries: [entry("foo padł")]), channel: gitHub).text
        #expect(text.contains("## What happened"))
        #expect(text.contains("Kliknąłem aktualizuj."))
        #expect(text.contains("- Wega: 1.4.2 (812)"))
        #expect(text.contains("foo padł"))
        #expect(text.contains("This report is redacted"))
    }

    @Test func anAbsentDescriptionIsMarkedRatherThanLeftBlank() {
        let text = BugReportBuilder()
            .body(draft(entries: [entry("foo padł")], description: "   "), channel: gitHub).text
        #expect(text.contains("(not provided)"))
    }

    @Test func entriesCarryTheirFailureDetail() {
        let detailed = entry("foo padł",
                             detail: LogDetail(command: "brew upgrade", exitCode: 1, stderr: "boom"))
        let text = BugReportBuilder().body(draft(entries: [detailed]), channel: gitHub).text
        #expect(text.contains("boom"))
        #expect(text.contains("exit: 1"))
    }

    // MARK: Redakcja

    @Test func nothingUnredactedLeavesTheMachine() {
        let builder = BugReportBuilder(redact: {
            LogRedaction.redactForExport($0, userNames: ["ala", "Ala Kowalska"])
        })
        let leaky = entry("nie mogę zapisać /Users/ala/Library/Caches/foo — token=ghp_0123456789abcdefghij")
        let text = builder.body(draft(entries: [leaky], description: "moje konto to ala"),
                                channel: gitHub).text
        #expect(text.contains("/Users/ala") == false)
        #expect(text.contains("ghp_0123456789abcdefghij") == false)
        #expect(text.contains("[user]"), "nazwa konta z opisu użytkownika też jest redagowana")
    }

    // MARK: Przycinanie

    @Test func anOverlongBodyIsTruncatedAtAnEntryBoundaryWithAMarker() {
        let body = BugReportBuilder().body(fatDraft(), channel: email)
        #expect(body.omittedEntryCount > 0)
        #expect(body.text.contains("[truncated — \(body.omittedEntryCount) earlier entries omitted]"))
    }

    @Test func truncationDropsTheOldestEntriesAndKeepsTheNewest() {
        let body = BugReportBuilder().body(fatDraft(), channel: email)
        #expect(body.text.contains("entry-300"), "awaria jest ostatnia — ostatnie wpisy zostają")
        #expect(body.text.contains("entry-1 ") == false)
    }

    @Test func theEnvironmentAndDescriptionSurviveTruncation() {
        let body = BugReportBuilder().body(fatDraft(), channel: email)
        #expect(body.text.contains("- Wega: 1.4.2 (812)"))
        #expect(body.text.contains("Kliknąłem aktualizuj."))
    }

    @Test func everyChannelStaysUnderItsOwnLimit() throws {
        let builder = BugReportBuilder()
        for channel in [email, gitHub] {
            let url = try #require(builder.url(fatDraft(), channel: channel))
            #expect(url.absoluteString.count <= channel.urlLengthLimit)
        }
    }

    // MARK: URL

    @Test func theEmailChannelBuildsAMailtoURL() throws {
        let url = try #require(BugReportBuilder().url(draft(entries: [entry("foo padł")]), channel: email))
        #expect(url.scheme == "mailto")
        #expect(url.absoluteString.hasPrefix("mailto:bugs@example.test?subject="))
        let items = try Self.queryItems(url)
        #expect(items["body"]?.contains("foo padł") == true)
    }

    @Test func theGitHubChannelBuildsATitleAndBodyQuery() throws {
        let url = try #require(BugReportBuilder().url(draft(entries: [entry("foo padł")]), channel: gitHub))
        #expect(url.absoluteString.hasPrefix("https://github.com/owner/repo/issues/new?title="))
        let items = try Self.queryItems(url)
        #expect(items["title"]?.hasPrefix("[Bug] ") == true)
    }

    @Test func spacesAndAmpersandsAreEscaped() throws {
        let url = try #require(BugReportBuilder().url(draft(entries: [entry("foo & bar padły")]),
                                                      channel: gitHub))
        #expect(url.absoluteString.contains(" ") == false)
        #expect(url.absoluteString.contains("%26"))
    }
}
```

- [ ] **Step 2: (warunkowo) uruchom test i potwierdź Red**

```bash
swift test --filter BugReportBuilder
```

Oczekiwane: FAIL — `cannot find 'BugReportBuilder' in scope`.

- [ ] **Step 3: Zaimplementuj**

`Sources/MacUpdaterCore/BugReport.swift`:

```swift
import Foundation

/// Wszystko, co użytkownik zgłasza: jego własny opis, metryczka środowiska i wpisy
/// z logu, które zaznaczył.
public struct BugReportDraft: Sendable, Equatable {
    public var userDescription: String
    public var environment: [ReportField]
    public var entries: [LogEntry]

    public init(userDescription: String, environment: [ReportField], entries: [LogEntry]) {
        self.userDescription = userDescription
        self.environment = environment
        self.entries = entries
    }
}

/// Dokąd zgłoszenie trafia. Kanał niesie własny limit długości URL-a, żeby żadne
/// wywołanie nie mogło zbudować treści pod limit innego kanału.
public enum BugReportChannel: Sendable, Equatable {
    case email(address: String)
    case gitHubIssue(endpoint: URL)

    /// `mailto:` jest ograniczone nie przez standard, lecz przez najciaśniejszego klienta —
    /// Outlook przycina około 2048 znaków całego URL-a. GitHub przyjmuje tyle, ile stosuje
    /// już ``CatalogIssueBuilder``.
    public var urlLengthLimit: Int {
        switch self {
        case .email:       return 2000
        case .gitHubIssue: return 8000
        }
    }
}

/// Gotowa treść wraz z informacją, ile wpisów się w niej nie zmieściło.
public struct BugReportBody: Sendable, Equatable {
    public let text: String
    public let omittedEntryCount: Int

    public init(text: String, omittedEntryCount: Int) {
        self.text = text
        self.omittedEntryCount = omittedEntryCount
    }
}

/// Buduje zgłoszenie błędu z zaznaczonych wpisów logu.
///
/// Dwie własności są tu wymuszone strukturalnie, nie konwencją:
///
/// 1. **Wszystko jest zredagowane.** Żaden tekst nie trafia do treści inaczej niż przez
///    ``redact``, więc pole dodane później nie może zapomnieć o redakcji.
/// 2. **Ten sam `draft` zasila oba kanały.** Treść jest jedna; kanał zmienia wyłącznie
///    opakowanie w URL. Dzięki temu „co opuszcza maszynę" testuje się raz, nie dwa razy.
public struct BugReportBuilder: Sendable {

    public typealias Redactor = @Sendable (String) -> String

    /// Maksymalna długość tytułu, zanim zostanie skrócony. Tytuł **nigdy** nie jest
    /// przycinany przez limit URL-a — budżet zabierają mu wyłącznie wpisy.
    public static let maxTitleLength = 90

    private let redact: Redactor

    public init(redact: @escaping Redactor = { LogRedaction.redactForExport($0) }) {
        self.redact = redact
    }

    // MARK: - Tytuł

    public func title(_ draft: BugReportDraft) -> String {
        let newestError = draft.entries.filter { $0.level == .error }.max { $0.date < $1.date }
        guard let subject = newestError ?? draft.entries.max(by: { $0.date < $1.date }) else {
            return "[Bug] Wega Mac Updater"
        }
        let text = redact(subject.message)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = text.count > Self.maxTitleLength
            ? String(text.prefix(Self.maxTitleLength)).trimmingCharacters(in: .whitespaces) + "…"
            : text
        return "[Bug] \(trimmed)"
    }

    // MARK: - Treść

    public func body(_ draft: BugReportDraft, channel: BugReportChannel) -> BugReportBody {
        let fixed = fixedSections(draft)
        let entryTexts = draft.entries
            .sorted { $0.date < $1.date }
            .map { redactLines($0.fileText) }

        // Budżet dla wpisów to limit kanału pomniejszony o wszystko, czego nie wolno ciąć:
        // prefiks URL-a, tytuł i sekcje stałe.
        let budget = channel.urlLengthLimit - encodedOverhead(draft, channel: channel, fixed: fixed)

        var kept: [String] = []
        var omitted = 0
        for text in entryTexts.reversed() {   // od najnowszego: awaria jest ostatnia
            let candidate = ([text] + kept).joined(separator: "\n")
            if PrefilledURLBody.percentEncoded(candidate).count <= budget {
                kept.insert(text, at: 0)
            } else {
                omitted += 1
            }
        }

        var lines = fixed.head
        lines.append("## Log entries (\(draft.entries.count) selected)")
        if omitted > 0 { lines.append("[truncated — \(omitted) earlier entries omitted]") }
        lines.append(contentsOf: kept)
        lines.append(contentsOf: fixed.tail)
        return BugReportBody(text: lines.joined(separator: "\n"), omittedEntryCount: omitted)
    }

    // MARK: - URL

    public func url(_ draft: BugReportDraft, channel: BugReportChannel) -> URL? {
        let encodedTitle = PrefilledURLBody.percentEncoded(title(draft))
        let encodedBody = PrefilledURLBody.percentEncoded(body(draft, channel: channel).text)
        switch channel {
        case .email(let address):
            return URL(string: "mailto:\(address)?subject=\(encodedTitle)&body=\(encodedBody)")
        case .gitHubIssue(let endpoint):
            return URL(string: "\(endpoint.absoluteString)?title=\(encodedTitle)&body=\(encodedBody)")
        }
    }

    // MARK: - Sekcje stałe

    private struct FixedSections {
        let head: [String]
        let tail: [String]
    }

    private func fixedSections(_ draft: BugReportDraft) -> FixedSections {
        let described = draft.userDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        var head: [String] = [
            "## What happened",
            described.isEmpty ? "(not provided)" : redact(described),
            "",
            "## Environment",
        ]
        head.append(contentsOf: draft.environment.map { "- \(redact($0.label)): \(redact($0.value))" })
        head.append("")
        let tail = [
            "",
            "## Note",
            "This report is redacted: paths, query strings, credentials, e-mail addresses",
            "and account names are replaced with placeholders.",
        ]
        return FixedSections(head: head, tail: tail)
    }

    /// Zakodowana długość `"\n"`. Sekcje stałe i blok wpisów są w finalnym tekście
    /// spajane jednym dodatkowym separatorem, którego nie widać w żadnej z nich osobno.
    private static let separatorCost = PrefilledURLBody.percentEncoded("\n").count

    /// Ile z limitu kanału zjada wszystko poza wpisami — tego przycinanie nie rusza.
    /// Znacznik przycięcia wliczany jest zawsze, w najdłuższej możliwej postaci, żeby
    /// jego późniejsze dopisanie nie mogło przepchnąć URL-a ponad limit.
    private func encodedOverhead(_ draft: BugReportDraft, channel: BugReportChannel,
                                 fixed: FixedSections) -> Int {
        let scheme: String
        switch channel {
        case .email(let address):        scheme = "mailto:\(address)?subject=&body="
        case .gitHubIssue(let endpoint): scheme = "\(endpoint.absoluteString)?title=&body="
        }
        let header = "## Log entries (\(draft.entries.count) selected)"
        let marker = "[truncated — \(draft.entries.count) earlier entries omitted]"
        let fixedText = (fixed.head + [header, marker] + fixed.tail).joined(separator: "\n")
        return scheme.count
            + PrefilledURLBody.percentEncoded(title(draft)).count
            + PrefilledURLBody.percentEncoded(fixedText).count
            + Self.separatorCost
    }

    /// Redaguje wpis linia po linii, żeby wzorce zakotwiczone na początku linii — jak
    /// prefiks detalu — nadal pasowały.
    private func redactLines(_ text: String) -> String {
        text.components(separatedBy: "\n").map(redact).joined(separator: "\n")
    }
}
```

- [ ] **Step 4: (warunkowo) uruchom test i potwierdź Green**

```bash
swift test --filter BugReportBuilder
```

- [ ] **Step 5: Lint i commit**

```bash
swiftlint lint --strict Sources/MacUpdaterCore/BugReport.swift
```

```bash
git add Sources/MacUpdaterCore/BugReport.swift Tests/MacUpdaterTests/BugReportBuilderTests.swift
```

```bash
git commit -m "feat(report): build a redacted bug report from selected log entries for both channels"
```

---

## Task 9: `URLOpening` i `BugReportController`

**Files:**
- Create: `Sources/MacUpdater/URLOpening.swift`
- Create: `Sources/MacUpdater/BugReportController.swift`
- Test: `Tests/MacUpdaterUITests/BugReportControllerTests.swift`

**Interfaces:**
- Consumes: `BugReportDraft`, `BugReportChannel`, `BugReportBody`, `BugReportBuilder` (Task 8), `BugReportEnvironment.fields(from:)` i `ReportField` (Task 7), `AppEndpoints.supportEmailAddress` (Task 6), `DiagnosticsExportController.snapshot()` (istniejący).
- Produces: `URLOpening` (`canOpen(_:) -> Bool`, `open(_:) -> Bool`), `WorkspaceURLOpener`, `BugReportController(entries:opener:)` z `.userDescription`, `.environment`, `.outcome`, `.isReady`, `.emailChannel`, `.gitHubChannel`, `.loadEnvironment()`, `.preview(for:)`, `.title()`, `.url(for:)`, `.send(_:)`, `.applyEnvironmentForTests(_:)`, oraz `BugReportController.Outcome`.

- [ ] **Step 1: Napisz test**

`Tests/MacUpdaterUITests/BugReportControllerTests.swift`:

```swift
import Foundation
import MacUpdaterCore
import Testing

@testable import WegaMacUpdater

/// Zachowanie okna zgłoszenia bez dotykania prawdziwego `NSWorkspace` — inaczej
/// „brak klienta poczty" dałoby się sprawdzić tylko odinstalowując klienta poczty
/// z maszyny, na której lecą testy.
@Suite("BugReportController")
@MainActor
struct BugReportControllerTests {

    private final class SpyOpener: URLOpening, @unchecked Sendable {
        var handles = true
        private(set) var opened: [URL] = []
        func canOpen(_ url: URL) -> Bool { handles }
        func open(_ url: URL) -> Bool {
            guard handles else { return false }
            opened.append(url)
            return true
        }
    }

    private func entry(_ message: String) -> LogEntry {
        LogEntry(date: Date(timeIntervalSince1970: 1_770_000_000), level: .error,
                 category: .homebrew, message: message)
    }

    private func ready(_ opener: SpyOpener) -> BugReportController {
        let controller = BugReportController(entries: [entry("foo padł")], opener: opener)
        controller.applyEnvironmentForTests([ReportField(label: "Wega", value: "1.4.2 (812)")])
        return controller
    }

    @Test func sendingOpensTheChannelURL() {
        let opener = SpyOpener()
        let controller = ready(opener)
        controller.send(controller.emailChannel)
        #expect(opener.opened.count == 1)
        #expect(opener.opened.first?.scheme == "mailto")
        #expect(controller.outcome == .opened(controller.emailChannel))
    }

    @Test func aMissingMailClientYieldsNoHandlerRatherThanAnError() {
        let opener = SpyOpener()
        opener.handles = false
        let controller = ready(opener)
        controller.send(controller.emailChannel)
        #expect(opener.opened.isEmpty)
        #expect(controller.outcome == .noHandler(controller.emailChannel))
    }

    @Test func theGitHubChannelTargetsTheConfiguredNewIssueEndpoint() {
        let opener = SpyOpener()
        let controller = ready(opener)
        controller.send(controller.gitHubChannel)
        #expect(opener.opened.first?.absoluteString.hasPrefix(
            AppEndpoints.shared.projectNewIssueURL.absoluteString + "?title=") == true)
    }

    @Test func theEmailChannelUsesTheConfiguredSupportAddress() {
        let opener = SpyOpener()
        let controller = ready(opener)
        controller.send(controller.emailChannel)
        #expect(opener.opened.first?.absoluteString.hasPrefix(
            "mailto:" + AppEndpoints.shared.supportEmailAddress) == true)
    }

    @Test func thePreviewIsExactlyWhatTheURLCarries() {
        let controller = ready(SpyOpener())
        controller.userDescription = "Kliknąłem aktualizuj."
        let preview = controller.preview(for: controller.emailChannel)
        #expect(preview.text.contains("Kliknąłem aktualizuj."))
        #expect(preview.text.contains("- Wega: 1.4.2 (812)"))
        #expect(preview.text.contains("foo padł"))
    }

    @Test func sendingIsBlockedUntilTheEnvironmentIsGathered() {
        let pending = BugReportController(entries: [entry("foo padł")], opener: SpyOpener())
        #expect(pending.isReady == false)
        pending.applyEnvironmentForTests([])
        #expect(pending.isReady)
    }
}
```

- [ ] **Step 2: (warunkowo) uruchom test i potwierdź Red**

```bash
swift test --filter BugReportController
```

Oczekiwane: FAIL — `cannot find 'BugReportController' in scope`.

- [ ] **Step 3: Utwórz `URLOpening`**

`Sources/MacUpdater/URLOpening.swift`:

```swift
import AppKit
import Foundation

/// Otwieranie URL-a przez system, za wstrzykiwaną granicą.
///
/// Istnieje wyłącznie po to, żeby ścieżka „na tej maszynie nie ma klienta poczty" była
/// testowalna. Bez niej dałoby się ją sprawdzić tylko odinstalowując klienta poczty
/// z maszyny, na której lecą testy.
protocol URLOpening: Sendable {
    /// Czy system ma czymkolwiek obsłużyć ten URL.
    func canOpen(_ url: URL) -> Bool
    /// Otwiera URL. `false`, gdy system odmówił.
    @discardableResult
    func open(_ url: URL) -> Bool
}

struct WorkspaceURLOpener: URLOpening {
    func canOpen(_ url: URL) -> Bool {
        NSWorkspace.shared.urlForApplication(toOpen: url) != nil
    }

    @discardableResult
    func open(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }
}
```

- [ ] **Step 4: Utwórz `BugReportController`**

`Sources/MacUpdater/BugReportController.swift`:

```swift
import Foundation
import MacUpdaterCore
import SwiftUI

/// Model okna „Zgłoś błąd": trzyma zaznaczone wpisy i opis użytkownika, dociąga metryczkę
/// środowiska i otwiera wybrany kanał.
///
/// Metryczkę bierze z ``DiagnosticsExportController/snapshot()`` — tego samego kodu, który
/// zbiera dane do paczki diagnostycznej. Drugi zbieracz oznaczałby dwa opisy tej samej
/// maszyny, które z czasem zaczęłyby się różnić.
///
/// To wywołanie odpytuje `brew --version` i podobne z pięciosekundowym limitem, więc okno
/// otwiera się natychmiast z wpisami i polem opisu, a metryczka dopina się asynchronicznie.
@MainActor
final class BugReportController: ObservableObject {

    enum Outcome: Equatable {
        case idle
        /// Kanał otwarty — wiadomość czeka w kliencie użytkownika.
        case opened(BugReportChannel)
        /// System nie ma czym obsłużyć tego kanału. To nie błąd: okno pokazuje wtedy
        /// adres, temat i treść do skopiowania.
        case noHandler(BugReportChannel)
    }

    let entries: [LogEntry]

    @Published var userDescription: String = ""
    @Published private(set) var environment: [ReportField]?
    @Published private(set) var outcome: Outcome = .idle

    private let opener: URLOpening
    private let builder = BugReportBuilder()

    init(entries: [LogEntry], opener: URLOpening = WorkspaceURLOpener()) {
        self.entries = entries
        self.opener = opener
    }

    /// Metryczka jest dociągana asynchronicznie, więc wysyłka czeka, aż będzie komplet.
    var isReady: Bool { environment != nil }

    var emailChannel: BugReportChannel { .email(address: AppEndpoints.shared.supportEmailAddress) }
    var gitHubChannel: BugReportChannel { .gitHubIssue(endpoint: AppEndpoints.shared.projectNewIssueURL) }

    func loadEnvironment() async {
        guard environment == nil else { return }
        let snapshot = await DiagnosticsExportController().snapshot()
        environment = BugReportEnvironment.fields(from: snapshot)
    }

    /// Dokładnie ten tekst, który trafi do URL-a — łącznie z przycięciem. Podgląd
    /// i wysyłka nie mogą się rozjechać, więc obie liczą to samo.
    func preview(for channel: BugReportChannel) -> BugReportBody {
        builder.body(draft, channel: channel)
    }

    func title() -> String { builder.title(draft) }

    func url(for channel: BugReportChannel) -> URL? { builder.url(draft, channel: channel) }

    func send(_ channel: BugReportChannel) {
        guard let url = url(for: channel) else { return }
        guard opener.canOpen(url), opener.open(url) else {
            outcome = .noHandler(channel)
            return
        }
        outcome = .opened(channel)
        WegaLog.info(.app, "Utworzono zgłoszenie błędu (\(entries.count) wpisów).")
    }

    /// Wstrzykuje gotową metryczkę, żeby testy nie musiały odpytywać realnego systemu.
    func applyEnvironmentForTests(_ fields: [ReportField]) {
        environment = fields
    }

    private var draft: BugReportDraft {
        BugReportDraft(
            userDescription: userDescription,
            environment: environment ?? [],
            entries: entries
        )
    }
}

extension BugReportController: Identifiable {
    nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }
}
```

- [ ] **Step 5: (warunkowo) uruchom test i potwierdź Green**

```bash
swift test --filter BugReportController
```

- [ ] **Step 6: Lint i commit**

```bash
swiftlint lint --strict Sources/MacUpdater/BugReportController.swift
```

```bash
git add Sources/MacUpdater/URLOpening.swift Sources/MacUpdater/BugReportController.swift Tests/MacUpdaterUITests/BugReportControllerTests.swift
```

```bash
git commit -m "feat(report): drive the bug-report channels behind an injectable URL opener"
```

---

## Task 10: `BugReportSheet` — opis, podgląd, fallback

**Files:**
- Create: `Sources/MacUpdater/BugReportSheet.swift`
- Modify: `Sources/MacUpdaterCore/Translations.swift` (słownik `operations`)

**Interfaces:**
- Consumes: `BugReportController` i jego API (Task 9), `AppEndpoints.supportEmailAddress` (Task 6).
- Produces: `BugReportSheet(controller:onClose:)`.

- [ ] **Step 1: Sprawdź, których kluczy jeszcze nie ma**

```bash
grep -n '"Anuluj"\|"Zamknij"\|"Adres"\|"Temat"\|"Treść"' Sources/MacUpdaterCore/Translations.swift
```

Sekcje `base` i `operations` są addytywne i **klucze nie mogą się dublować** — pomiń te, które już istnieją.

- [ ] **Step 2: Dodaj brakujące tłumaczenia**

W `Sources/MacUpdaterCore/Translations.swift`, w słowniku `operations`:

```swift
        // Zgłaszanie błędów z zakładki Logi.
        "Zgłoś błąd…": "Report a problem…",
        "Opisz, co się stało": "Describe what happened",
        "Co robiłeś, zanim to się wydarzyło? (opcjonalne)":
            "What were you doing when it happened? (optional)",
        "Podgląd zgłoszenia": "Report preview",
        "Zbieram informacje o środowisku…": "Gathering environment information…",
        "Wyślij e-mailem": "Send by e-mail",
        "Zgłoś na GitHubie": "Report on GitHub",
        "Kopiuj treść": "Copy contents",
        "Kopiuj %@": "Copy %@",
        "Pominięto %d najstarszych wpisów": "%d oldest entries omitted",
        "Nie znaleziono klienta poczty": "No mail client found",
        "Ta maszyna nie ma skonfigurowanego klienta poczty. Skopiuj poniższe dane i wyślij zgłoszenie ręcznie.":
            "This machine has no mail client configured. Copy the details below and send the report manually.",
        "Adres": "Address",
        "Temat": "Subject",
        "Treść": "Contents",
        "Zgłoszenie jest redagowane — ścieżki, tokeny i nazwy użytkownika są zastąpione znacznikami.":
            "The report is redacted: paths, tokens and account names are replaced with placeholders.",
        "Zaznacz wpisy w logu, żeby zgłosić błąd": "Select log entries to report a problem",
```

- [ ] **Step 3: Utwórz widok**

`Sources/MacUpdater/BugReportSheet.swift`:

```swift
import AppKit
import MacUpdaterCore
import SwiftUI

/// Okno „Zgłoś błąd": opis użytkownika, podgląd dokładnie tej treści, która wyjdzie,
/// i wybór kanału.
///
/// Podgląd jest pełny z rozmysłem: zgłoszenie opuszcza maszynę, więc użytkownik ma
/// zobaczyć, co wysyła, zanim cokolwiek się otworzy. To samo okno obsługuje przypadek
/// „na tej maszynie nie ma klienta poczty", więc nie ma tu ślepego zaułka.
struct BugReportSheet: View {
    @ObservedObject var controller: BugReportController
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch controller.outcome {
            case .noHandler(let channel):
                manualInstructions(for: channel)
            case .idle, .opened:
                composer
            }
        }
        .padding(20)
        .frame(width: 620, height: 560)
        .task { await controller.loadEnvironment() }
        .onChange(of: controller.outcome) { _, outcome in
            if case .opened = outcome { onClose() }
        }
    }

    // MARK: - Tworzenie zgłoszenia

    private var composer: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(tr("Opisz, co się stało")).font(.wega(.headline))

            TextEditor(text: $controller.userDescription)
                .font(.wega(.body))
                .frame(height: 90)
                .overlay(alignment: .topLeading) {
                    if controller.userDescription.isEmpty {
                        Text(tr("Co robiłeś, zanim to się wydarzyło? (opcjonalne)"))
                            .font(.wega(.body)).foregroundStyle(.tertiary)
                            .padding(.horizontal, 6).padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                }

            HStack {
                Text(tr("Podgląd zgłoszenia")).font(.wega(.headline))
                Spacer()
                if preview.omittedEntryCount > 0 {
                    Label(
                        trf("Pominięto %d najstarszych wpisów", preview.omittedEntryCount),
                        systemImage: "scissors"
                    )
                    .font(.wega(.footnote)).foregroundStyle(Color.wegaToffee)
                }
            }

            if controller.isReady {
                previewBox(preview.text)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(tr("Zbieram informacje o środowisku…"))
                        .font(.wega(.callout)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Text(tr("Zgłoszenie jest redagowane — ścieżki, tokeny i nazwy użytkownika są zastąpione znacznikami."))
                .font(.wega(.footnote)).foregroundStyle(.tertiary)

            HStack {
                Button(tr("Kopiuj treść")) { copy(preview.text) }
                Spacer()
                Button(tr("Anuluj"), role: .cancel, action: onClose)
                Button(tr("Zgłoś na GitHubie")) { controller.send(controller.gitHubChannel) }
                    .disabled(!controller.isReady)
                Button(tr("Wyślij e-mailem")) { controller.send(controller.emailChannel) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!controller.isReady)
            }
        }
    }

    // MARK: - Brak klienta poczty

    @ViewBuilder
    private func manualInstructions(for channel: BugReportChannel) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(tr("Nie znaleziono klienta poczty"), systemImage: "envelope.badge.shield.half.filled")
                .font(.wega(.headline)).foregroundStyle(Color.wegaToffee)
            Text(tr("Ta maszyna nie ma skonfigurowanego klienta poczty. Skopiuj poniższe dane i wyślij zgłoszenie ręcznie."))
                .font(.wega(.callout)).foregroundStyle(.secondary)

            copyableRow(tr("Adres"), value: AppEndpoints.shared.supportEmailAddress)
            copyableRow(tr("Temat"), value: controller.title())

            HStack {
                Text(tr("Treść")).font(.wega(.subheadline, weight: .medium))
                Spacer()
                Button(tr("Kopiuj treść")) { copy(controller.preview(for: channel).text) }
                    .controlSize(.small)
            }
            previewBox(controller.preview(for: channel).text)

            HStack {
                Spacer()
                Button(tr("Zamknij"), action: onClose).keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - Elementy wspólne

    private func previewBox(_ text: String) -> some View {
        ScrollView {
            Text(text)
                .font(.wega(.footnote, monospaced: true))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .frame(maxHeight: .infinity)
    }

    private func copyableRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label).font(.wega(.subheadline, weight: .medium))
            Text(value).font(.wega(.subheadline, monospaced: true)).textSelection(.enabled)
            Spacer()
            Button(trf("Kopiuj %@", label.lowercased())) { copy(value) }.controlSize(.small)
        }
    }

    private var preview: BugReportBody {
        controller.preview(for: controller.emailChannel)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
```

- [ ] **Step 4: Lint**

```bash
swiftlint lint --strict Sources/MacUpdater/BugReportSheet.swift
```

- [ ] **Step 5: (warunkowo) uruchom test kompletności tłumaczeń**

```bash
swift test --filter LocalizationCompleteness
```

Oczekiwane: PASS. FAIL wskaże dokładnie te klucze `tr(...)`, którym brakuje angielskiego odpowiednika.

- [ ] **Step 6: Commit**

```bash
git add Sources/MacUpdater/BugReportSheet.swift Sources/MacUpdaterCore/Translations.swift
```

```bash
git commit -m "feat(report): add the compose sheet with a full preview and a no-mail-client fallback"
```

---

## Task 11: `LogsView` — zaznaczanie, disclosure detalu, przycisk zgłoszenia

**Files:**
- Modify: `Sources/MacUpdater/LogsView.swift`
- Test: `Tests/MacUpdaterUITests/LogsSelectionTests.swift`

**Interfaces:**
- Consumes: `LogEntry.detail` i `LogEntry.fileText` (Task 2), `BugReportController` (Task 9), `BugReportSheet` (Task 10).
- Produces: `LogSelection.pruned(_:toVisible:) -> Set<LogEntry.ID>`.

- [ ] **Step 1: Napisz test**

`Tests/MacUpdaterUITests/LogsSelectionTests.swift`:

```swift
import Foundation
import MacUpdaterCore
import Testing

@testable import WegaMacUpdater

@Suite("Logs selection")
struct LogsSelectionTests {

    private func entry(_ message: String) -> LogEntry {
        LogEntry(date: Date(timeIntervalSince1970: 1_770_000_000), level: .error,
                 category: .homebrew, message: message)
    }

    @Test func selectionIsPrunedToTheVisibleEntries() {
        let visible = [entry("a"), entry("b")]
        let hidden = entry("c")
        // Bez przycięcia dałoby się zaznaczyć wpis, zmienić filtr i wysłać coś,
        // czego użytkownik już nie widzi.
        #expect(LogSelection.pruned([visible[0].id, hidden.id], toVisible: visible) == [visible[0].id])
    }

    @Test func anEmptySelectionStaysEmpty() {
        #expect(LogSelection.pruned([], toVisible: [entry("a")]).isEmpty)
    }

    @Test func theReportButtonIsGatedOnANonEmptySelection() throws {
        let source = try Self.source("Sources/MacUpdater/LogsView.swift")
        #expect(source.contains(".disabled(selection.isEmpty)"))
        #expect(source.contains("tr(\"Zgłoś błąd…\")"))
    }

    @Test func theListCarriesASelectionBinding() throws {
        let source = try Self.source("Sources/MacUpdater/LogsView.swift")
        #expect(source.contains("List(visible, selection: $selection)"))
    }

    @Test func anEntryWithADetailRendersADisclosure() throws {
        let source = try Self.source("Sources/MacUpdater/LogsView.swift")
        #expect(source.contains("if let detail = entry.detail"))
        #expect(source.contains("DisclosureGroup"))
    }

    private static func source(_ relativePath: String, file: String = #filePath) throws -> String {
        let root = URL(fileURLWithPath: file)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
```

- [ ] **Step 2: (warunkowo) uruchom test i potwierdź Red**

```bash
swift test --filter LogsSelectionTests
```

Oczekiwane: FAIL — `cannot find 'LogSelection' in scope`.

- [ ] **Step 3: Dodaj czystą regułę przycinania**

W `Sources/MacUpdater/LogsView.swift`, pod `extension LogLevelFilter`:

```swift
/// Przycinanie zaznaczenia do tego, co użytkownik faktycznie widzi.
///
/// Wydzielone z widoku, bo to jedyna reguła w tej zakładce, którą da się złamać cicho:
/// bez niej można zaznaczyć pięć wpisów, zmienić filtr i wysłać dwanaście.
enum LogSelection {
    static func pruned(_ selection: Set<LogEntry.ID>, toVisible visible: [LogEntry]) -> Set<LogEntry.ID> {
        selection.intersection(Set(visible.map(\.id)))
    }
}
```

- [ ] **Step 4: Zamień listę na `List` z zaznaczaniem**

W `struct LogsView` dodaj stan obok istniejących `@State`:

```swift
    @State private var selection: Set<LogEntry.ID> = []
    @State private var reportController: BugReportController?
```

Zamień gałąź `else` w `body` (obecny `ScrollView` z `LazyVStack`) na:

```swift
                List(visible, selection: $selection) { entry in
                    row(entry)
                        .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                        .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
                .scrollEdgeEffectStyle(.soft, for: .top)
```

Dopnij modyfikatory do `body`, obok istniejącego `.searchable`:

```swift
        .onChange(of: filter) { _, _ in selection = LogSelection.pruned(selection, toVisible: visible) }
        .onChange(of: search) { _, _ in selection = LogSelection.pruned(selection, toVisible: visible) }
        .sheet(item: $reportController) { controller in
            BugReportSheet(controller: controller) { reportController = nil }
        }
```

- [ ] **Step 5: Dodaj przycisk zgłoszenia do paska**

W `LogsView.toolbar`, przed przyciskiem „Wyczyść":

```swift
            Button { startReport() } label: {
                Label(tr("Zgłoś błąd…"), systemImage: "exclamationmark.bubble")
            }
            .buttonStyle(.plain).foregroundStyle(Color.wegaHoney)
            .disabled(selection.isEmpty)
            .help(tr("Zaznacz wpisy w logu, żeby zgłosić błąd"))
```

I metodę obok `copyVisible()`:

```swift
    private func startReport() {
        let selected = visible.filter { selection.contains($0.id) }
                              .sorted { $0.date < $1.date }
        guard !selected.isEmpty else { return }
        reportController = BugReportController(entries: selected)
    }
```

- [ ] **Step 6: Pokaż detal jako disclosure**

Zamień `private func row(_ e: LogEntry) -> some View` na parę metod:

```swift
    @ViewBuilder
    private func row(_ entry: LogEntry) -> some View {
        if let detail = entry.detail {
            DisclosureGroup {
                Text(detail.continuationLines.joined(separator: "\n"))
                    .font(.wega(.footnote, monospaced: true))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 8)
            } label: {
                rowLine(entry)
            }
        } else {
            rowLine(entry)
        }
    }

    private func rowLine(_ e: LogEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(Self.timeFormatter.string(from: e.date))
                .font(.wega(.subheadline, monospaced: true)).foregroundStyle(.tertiary)
                .frame(width: 64, alignment: .leading)
            Text(e.level.rawValue.uppercased())
                .font(.wega(.footnote, weight: .bold, monospaced: true))
                .foregroundStyle(levelColor(e.level))
                .frame(width: 64, alignment: .leading)
            Text(e.category.label)
                .font(.wega(.footnote, weight: .medium))
                .foregroundStyle(Color.wegaHoney)
                .frame(width: 84, alignment: .leading)
            Text(e.message)
                .font(.wega(.subheadline, monospaced: true))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }
```

- [ ] **Step 7: Kopiuj pełny tekst wpisu, nie samą linię nagłówka**

W `copyVisible()` zamień `visible.map(\.fileLine)` na:

```swift
        let text = visible.map(\.fileText).joined(separator: "\n")
```

- [ ] **Step 8: (warunkowo) uruchom testy i potwierdź Green**

```bash
swift test --filter LogsSelectionTests
```

- [ ] **Step 9: Zweryfikuj wydajność listy w działającej aplikacji**

Zbuduj i uruchom aplikację tak, jak robi to ten projekt — sprawdź `scripts/` i wybierz
skrypt budujący pakiet `.app` (SwiftUI-owa scena potrzebuje bundla, więc samo
`swift run` nie jest tu wiarygodnym testem).

Przejdź do zakładki Logi z pełnym buforem (2000 wpisów) i przewiń listę. Jeśli przewijanie zauważalnie zacina się względem poprzedniego `LazyVStack`, **nie** wracaj do `LazyVStack` — ogranicz liczbę renderowanych wierszy (np. najnowsze 500 z przyciskiem „pokaż starsze") i zapisz tę decyzję w `docs/features.md`. Natywne zaznaczanie zostaje.

- [ ] **Step 10: Lint i commit**

```bash
swiftlint lint --strict Sources/MacUpdater/LogsView.swift
```

```bash
git add Sources/MacUpdater/LogsView.swift Tests/MacUpdaterUITests/LogsSelectionTests.swift
```

```bash
git commit -m "feat(logs): select entries, expand failure details and report a problem from the log tab"
```

---

## Task 12: Dokumentacja

**Files:**
- Modify: `docs/features.md`
- Modify: `USER_GUIDE.md`

**Interfaces:**
- Consumes: całość.
- Produces: nic.

`docs/features.md` jest jednym z pięciu dokumentów wymienionych z nazwy w `.gitignore` — jest śledzony i można go commitować. **Nie twórz nowych plików w `docs/`** bez dopisania dla nich linii negacji w `.gitignore`; `/docs/*` jest domyślnie ignorowany.

- [ ] **Step 1: Opisz funkcję w `docs/features.md`**

Dopisz w sekcji o diagnostyce:

```markdown
### Zgłaszanie błędów z zakładki Logi

Wpisy opisujące awarię niosą strukturalny kontekst: uruchomioną komendę, kod wyjścia
i ogon `stderr`. W zakładce Logi rozwija się go strzałką przy wpisie.

Zaznacz jeden lub więcej wpisów (⌘-klik, ⇧-klik) i użyj „Zgłoś błąd…". Otworzy się okno
z polem na opis i pełnym podglądem treści, która wyjdzie z maszyny. Zgłoszenie można
wysłać na dwa sposoby:

- **Wyślij e-mailem** — otwiera domyślnego klienta poczty z wypełnionym adresem, tematem
  i treścią. Gdy na maszynie nie ma skonfigurowanego klienta, okno pokazuje adres, temat
  i treść do skopiowania.
- **Zgłoś na GitHubie** — otwiera formularz nowego zgłoszenia z wypełnionym tytułem
  i treścią.

Treść jest zawsze redagowana: ścieżki, ciągi zapytań, poświadczenia, adresy e-mail
i nazwy kont zastępowane są znacznikami. Aplikacja nie wysyła niczego sama — kanał otwiera
się dopiero po kliknięciu, a wiadomość wysyła użytkownik.

Adres odbiorcy pochodzi z pola `supportEmail` w `endpoints.json` i może zostać nadpisany
przez overlay w `~/Library/Application Support/WegaMacUpdater/endpoints.json`.
```

- [ ] **Step 2: Opisz krok po kroku w `USER_GUIDE.md`**

```markdown
## Jak zgłosić błąd

1. Otwórz zakładkę **Logi**.
2. Ustaw filtr na **Tylko błędy**, żeby szybciej znaleźć moment awarii.
3. Zaznacz wpisy opisujące problem — ⌘-klik dodaje pojedynczy wpis, ⇧-klik zakres.
4. Kliknij **Zgłoś błąd…**.
5. Opisz krótko, co robiłeś, zanim to się stało.
6. Przejrzyj podgląd — to dokładnie ta treść, która opuści Twój komputer.
7. Wybierz **Wyślij e-mailem** albo **Zgłoś na GitHubie**.

Jeśli zaznaczysz bardzo dużo wpisów, najstarsze zostaną pominięte, a w treści pojawi się
o tym wyraźna adnotacja. Gdy potrzebny jest pełny materiał, użyj **Eksportuj diagnostykę**
w tej samej zakładce i dołącz zapisaną paczkę zip ręcznie — wiadomość `mailto:` nie potrafi
nieść załączników.
```

- [ ] **Step 3: Commit**

```bash
git add docs/features.md USER_GUIDE.md
```

```bash
git commit -m "docs: describe failure details in the log tab and the bug-report flow"
```

---

## Task 13: Bramka jakości i handoff

**Files:** brak zmian w kodzie.

- [ ] **Step 1: Build**

```bash
swift build
```

- [ ] **Step 2: Pełny lint**

```bash
swiftlint lint --strict
```

- [ ] **Step 3: Sprawdź czystość drzewa**

```bash
git status --short --untracked-files=all --ignored=matching
```

Regenerowalne wytwory builda (`.build/`) są raportowane i usuwane razem z worktree. Wszystko inne nieskommitowane rozwiąż tutaj, a nie flagą pomijającą.

- [ ] **Step 4: Zsynchronizuj gałąź ze stanem `main`**

Agent **nie** wykonuje integracji — to rola użytkownika. Jeśli `main` przesunął się w trakcie prac, zgłoś to użytkownikowi wraz z listą plików, w których spodziewany jest konflikt. Najbardziej prawdopodobne: `Sources/MacUpdater/LogsView.swift` (przebudowa listy) oraz `Sources/MacUpdaterCore/Translations.swift` (nowe klucze).

- [ ] **Step 5: Raport dla użytkownika**

Podaj: nazwę gałęzi, ścieżkę worktree, listę zmian, uruchomione bramki oraz **wyraźnie**, że pakiety testowe nie były uruchamiane (o ile użytkownik o to nie poprosił), więc potwierdzenie Red-Green pozostaje do wykonania. Wymień suity warte uruchomienia:

```bash
swift test --filter "LogDetailTests|LogEntryDetailSerializationTests|WegaLogDetailTests|ProcessRunnerDetailTests|PrefilledURLBodyTests|CatalogIssueBuilderTests|BugReport|AppEndpointsTests|LogsSelectionTests|LocalizationCompletenessTests|LogStoreTests"
```

Zakończ gotową do wklejenia komendą integracji — jedną na blok — którą uruchamia **użytkownik**, nie agent. Skrypt przyjmuje dwa argumenty: gałąź i niepusty komunikat commita scalającego.
PLAN
