# Zakładka „Logi" + klikalny szczegół błędu — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **⚠️ Git — zasada projektu (nadrzędna):** użytkownik **zabrania** operacji git
> (`commit`, `add`, `branch`, `push` itd.). Dlatego **kroki „Checkpoint" zastępują
> commity** — to znaczy: zbuduj, uruchom testy, potwierdź zielone. Commit wykonuje
> **wyłącznie użytkownik**. Nigdzie w tym planie nie wolno wołać git.

**Goal:** Dodać widoczny, trwały log aktywności (zakładka „Logi") oraz uczynić
banner ostrzegawczy klikalnym — z przejściem do logów z pre-filtrem błędów.

**Architecture:** Nowy `LogStore` (obserwowalny ring-buffer w pamięci + zapis do
`~/Library/Logs/WegaMacUpdater/wega.log` z rotacją) zasilany fasadą `WegaLog`,
która równolegle forwarduje do istniejącego OSLog `AppLogger`. Skan i checkery
logują przez fasadę; zakładka `LogsView` obserwuje store; banner zyskuje akcję
`.openLogs`.

**Tech Stack:** Swift 6, SwiftUI (macOS 14+), SPM. Testy: XCTest (jak
`BrewCaskDriftFilterTests`). OSLog (`os.Logger`).

---

## File Structure

**Create:**
- `Sources/MacUpdaterCore/LogStore.swift` — `LogLevel`, `LogCategory`, `LogEntry` (+ format linii), `LogStore`.
- `Sources/MacUpdaterCore/WegaLog.swift` — fasada logowania (OSLog + LogStore).
- `Sources/MacUpdaterCore/LogFiltering.swift` — `LogLevelFilter` (bez `label`) + czysta `filterLogEntries`. **W Core**, bo target testów zależy tylko od `MacUpdaterCore` (executable `MacUpdater` nie jest importowalny w testach — taka jest konwencja repo).
- `Sources/MacUpdater/LogsView.swift` — rozszerzenie `LogLevelFilter.label` (używa `tr`, które żyje w `MacUpdater`) + widok zakładki.
- `Tests/MacUpdaterTests/LogStoreTests.swift` — testy modelu, formatu, store, rotacji.
- `Tests/MacUpdaterTests/LogFilterTests.swift` — `@testable import MacUpdaterCore`; testy `filterLogEntries` i `LogLevelFilter.includes`.

> **Uwaga architektoniczna:** `tr()`/`trf()` są w `Sources/MacUpdater/Localization.swift`
> (executable), więc kod używający `tr` musi być w `MacUpdater`. Testowalna logika
> (filtrowanie) nie używa `tr` i idzie do `MacUpdaterCore`. SwiftUI-owe `BannerData`/
> `BannerView` zostają w `MacUpdater` i **nie są unit-testowane** (build + istniejące
> testy weryfikują kompilację) — zgodnie z istniejącą konwencją (żaden test nie
> importuje `MacUpdater`).

**Modify:**
- `Sources/MacUpdaterCore/ManualUpdateScanner.swift` — helper `logged(...)` opakowujący checkery.
- `Sources/MacUpdater/SharedViews.swift` — `BannerData.action`, `BannerView.onAction`.
- `Sources/MacUpdater/ContentView.swift` — `SidebarTab.logs`, `toolTabs`, switch w `ContentArea`, `onNavigate`, badge błędów przy `.logs`, danger-wariant badge w `SidebarTabRow`.
- `Sources/MacUpdater/UpdateView.swift` — `WegaLog` w `runScan`, `action: .openLogs` na bannerach, parametr `onNavigate`.
- `Sources/MacUpdaterCore/Translations.swift` — wpisy EN dla nowych stringów PL.
- `README.md` — opis zakładki Logi + lokalizacja pliku logu.

---

## Task 1: Model logu — `LogLevel`, `LogCategory`, `LogEntry` + format linii

**Files:**
- Create: `Sources/MacUpdaterCore/LogStore.swift`
- Test: `Tests/MacUpdaterTests/LogStoreTests.swift`

- [ ] **Step 1: Write the failing test**

`Tests/MacUpdaterTests/LogStoreTests.swift`:
```swift
import XCTest
@testable import MacUpdaterCore

final class LogStoreTests: XCTestCase {

    func testLineRoundTripForEveryLevelAndCategory() {
        let date = Date(timeIntervalSince1970: 1_749_490_441) // stały punkt
        for level in LogLevel.allCases {
            for category in LogCategory.allCases {
                let entry = LogEntry(id: UUID(), date: date, level: level,
                                     category: category, message: "hello world")
                let line = entry.fileLine
                let parsed = LogEntry.parse(line)
                XCTAssertNotNil(parsed, "nie sparsowano: \(line)")
                XCTAssertEqual(parsed?.level, level)
                XCTAssertEqual(parsed?.category, category)
                XCTAssertEqual(parsed?.message, "hello world")
                // czas z dokładnością do sekundy (ISO-8601 bez frakcji)
                XCTAssertEqual(Int(parsed!.date.timeIntervalSince1970),
                               Int(date.timeIntervalSince1970))
            }
        }
    }

    func testNewlinesInMessageAreFlattened() {
        let entry = LogEntry(id: UUID(), date: Date(), level: .error,
                             category: .homebrew, message: "linia 1\nlinia 2")
        XCTAssertFalse(entry.fileLine.contains("\n"))
        XCTAssertEqual(LogEntry.parse(entry.fileLine)?.message, "linia 1 linia 2")
    }

    func testParseRejectsMalformedLine() {
        XCTAssertNil(LogEntry.parse("to nie jest log"))
        XCTAssertNil(LogEntry.parse(""))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter LogStoreTests`
Expected: FAIL — `cannot find 'LogLevel'/'LogCategory'/'LogEntry' in scope`.

- [ ] **Step 3: Write minimal implementation**

`Sources/MacUpdaterCore/LogStore.swift` (na razie tylko model + format):
```swift
import Foundation

public enum LogLevel: String, Sendable, CaseIterable {
    case debug, info, warning, error
}

public enum LogCategory: String, Sendable, CaseIterable {
    case app, process, homebrew, scanner, network, helper

    /// Czytelna etykieta używana w linii pliku i w UI.
    public var label: String {
        switch self {
        case .app:      return "App"
        case .process:  return "Process"
        case .homebrew: return "Homebrew"
        case .scanner:  return "Scanner"
        case .network:  return "Network"
        case .helper:   return "Helper"
        }
    }

    static func from(label: String) -> LogCategory? {
        LogCategory.allCases.first { $0.label == label }
    }
}

public struct LogEntry: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let date: Date
    public let level: LogLevel
    public let category: LogCategory
    public let message: String

    public init(id: UUID = UUID(), date: Date, level: LogLevel,
                category: LogCategory, message: String) {
        self.id = id
        self.date = date
        self.level = level
        self.category = category
        self.message = message
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    /// Linia pliku: `2026-06-09T17:34:01Z [ERROR] [Homebrew] message`
    public var fileLine: String {
        let flat = message.replacingOccurrences(of: "\n", with: " ")
                          .replacingOccurrences(of: "\r", with: " ")
        return "\(Self.isoFormatter.string(from: date)) [\(level.rawValue.uppercased())] [\(category.label)] \(flat)"
    }

    /// Parsuje linię pliku. Zwraca `nil` dla uszkodzonej/niepełnej linii.
    public static func parse(_ line: String) -> LogEntry? {
        // <iso> [LEVEL] [Category] <message...>
        let pattern = #"^(\S+) \[([A-Z]+)\] \[([^\]]+)\] (.*)$"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(line.startIndex..., in: line)
        guard let m = re.firstMatch(in: line, range: range), m.numberOfRanges == 5,
              let isoR = Range(m.range(at: 1), in: line),
              let lvlR = Range(m.range(at: 2), in: line),
              let catR = Range(m.range(at: 3), in: line),
              let msgR = Range(m.range(at: 4), in: line) else { return nil }
        guard let date = isoFormatter.date(from: String(line[isoR])),
              let level = LogLevel(rawValue: String(line[lvlR]).lowercased()),
              let category = LogCategory.from(label: String(line[catR])) else { return nil }
        return LogEntry(date: date, level: level, category: category,
                        message: String(line[msgR]))
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter LogStoreTests`
Expected: PASS (3 testy).

- [ ] **Step 5: Checkpoint**

Run: `swift build` — Expected: `Build complete!`. (Commit wykonuje użytkownik.)

---

## Task 2: `LogStore` — bufor, plik, rotacja, load, clear

**Files:**
- Modify: `Sources/MacUpdaterCore/LogStore.swift`
- Test: `Tests/MacUpdaterTests/LogStoreTests.swift`

- [ ] **Step 1: Write the failing test**

Dopisz do `LogStoreTests`:
```swift
    @MainActor
    private func makeStore() -> (LogStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wega-logtest-\(UUID().uuidString)", isDirectory: true)
        let store = LogStore(directory: dir, memoryCap: 5, fileMaxBytes: 400, loadTailLines: 100)
        return (store, dir)
    }

    @MainActor
    func testAppendTrimsToMemoryCapKeepingNewest() {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        for i in 0..<8 {
            store.append(LogEntry(date: Date(), level: .info, category: .app, message: "m\(i)"))
        }
        XCTAssertEqual(store.entries.count, 5)
        XCTAssertEqual(store.entries.first?.message, "m3") // najstarsze (m0..m2) wypadły
        XCTAssertEqual(store.entries.last?.message, "m7")
    }

    @MainActor
    func testFilePersistsAndLoadsBack() {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        store.append(LogEntry(date: Date(), level: .error, category: .homebrew, message: "boom"))
        store.flushForTests()
        let reloaded = LogStore(directory: dir, memoryCap: 5, fileMaxBytes: 400, loadTailLines: 100)
        XCTAssertEqual(reloaded.entries.last?.message, "boom")
        XCTAssertEqual(reloaded.entries.last?.level, .error)
    }

    @MainActor
    func testRotationKeepsRecentEntryAndCreatesBackup() {
        let (store, dir) = makeStore() // fileMaxBytes = 400
        defer { try? FileManager.default.removeItem(at: dir) }
        for i in 0..<60 {
            store.append(LogEntry(date: Date(), level: .info, category: .scanner,
                                  message: "wpis numer \(i) z trochę dłuższym tekstem"))
        }
        store.flushForTests()
        let backup = dir.appendingPathComponent("wega.log.1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path), "brak backupu po rotacji")
        // świeży plik zawiera najnowszy wpis
        let reloaded = LogStore(directory: dir, memoryCap: 100, fileMaxBytes: 400, loadTailLines: 100)
        XCTAssertEqual(reloaded.entries.last?.message, "wpis numer 59 z trochę dłuższym tekstem")
    }

    @MainActor
    func testClearEmptiesEntriesAndFile() {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        store.append(LogEntry(date: Date(), level: .info, category: .app, message: "x"))
        store.flushForTests()
        store.clear()
        XCTAssertTrue(store.entries.isEmpty)
        let reloaded = LogStore(directory: dir, memoryCap: 5, fileMaxBytes: 400, loadTailLines: 100)
        XCTAssertTrue(reloaded.entries.isEmpty)
    }

    @MainActor
    func testCorruptLineInFileIsSkippedOnLoad() {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("wega.log")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let good = LogEntry(date: Date(), level: .warning, category: .network, message: "ok")
        try? "śmieci\n\(good.fileLine)\nwięcej śmieci\n".write(to: url, atomically: true, encoding: .utf8)
        let reloaded = LogStore(directory: dir, memoryCap: 5, fileMaxBytes: 400, loadTailLines: 100)
        XCTAssertEqual(reloaded.entries.count, 1)
        XCTAssertEqual(reloaded.entries.first?.message, "ok")
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter LogStoreTests`
Expected: FAIL — `LogStore` nie istnieje / brak `init(directory:...)`.

- [ ] **Step 3: Write minimal implementation**

Dopisz do `Sources/MacUpdaterCore/LogStore.swift`:
```swift
@MainActor
public final class LogStore: ObservableObject {
    public static let shared = LogStore()

    @Published public private(set) var entries: [LogEntry] = []

    private let directory: URL
    private let memoryCap: Int
    private let fileMaxBytes: Int
    private let loadTailLines: Int
    private let fileQueue = DispatchQueue(label: "wega.logstore.file")

    public var logFileURL: URL { directory.appendingPathComponent("wega.log") }
    private var backupURL: URL { directory.appendingPathComponent("wega.log.1") }

    public init(
        directory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/WegaMacUpdater", isDirectory: true),
        memoryCap: Int = 2000,
        fileMaxBytes: Int = 5 * 1024 * 1024,
        loadTailLines: Int = 2000
    ) {
        self.directory = directory
        self.memoryCap = memoryCap
        self.fileMaxBytes = fileMaxBytes
        self.loadTailLines = loadTailLines
        loadFromFile()
    }

    public func append(_ entry: LogEntry) {
        entries.append(entry)
        if entries.count > memoryCap { entries.removeFirst(entries.count - memoryCap) }
        let line = entry.fileLine
        let dir = directory, fileURL = logFileURL, backup = backupURL, maxBytes = fileMaxBytes
        fileQueue.async {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            Self.rotateIfNeeded(fileURL: fileURL, backup: backup, maxBytes: maxBytes,
                                incoming: line.utf8.count + 1)
            Self.appendLine(line, to: fileURL)
        }
    }

    public func clear() {
        entries.removeAll()
        let fileURL = logFileURL, backup = backupURL
        fileQueue.async {
            try? FileManager.default.removeItem(at: fileURL)
            try? FileManager.default.removeItem(at: backup)
        }
    }

    /// Blokuje do opróżnienia kolejki zapisu — wyłącznie do testów.
    public func flushForTests() {
        fileQueue.sync { }
    }

    public func loadFromFile() {
        guard let content = try? String(contentsOf: logFileURL, encoding: .utf8) else { return }
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let tail = lines.suffix(loadTailLines)
        let parsed = tail.compactMap { LogEntry.parse($0) }
        entries = Array(parsed.suffix(memoryCap))
    }

    private static func rotateIfNeeded(fileURL: URL, backup: URL, maxBytes: Int, incoming: Int) {
        let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? 0
        guard let current = size, current + incoming > maxBytes, current > 0 else { return }
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.moveItem(at: fileURL, to: backup)
    }

    private static func appendLine(_ line: String, to fileURL: URL) {
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL)
        }
    }
}
```

> Uwaga: w `rotateIfNeeded` `size` jest `Int?` z rzutowania — `guard let current = size`
> rozpakowuje. Jeśli kompilator zgłosi „initializer for conditional binding must have
> Optional type", zmień na `let current = ((try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size]) as? Int) ?? 0`
> i warunek `guard current + incoming > maxBytes, current > 0`.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter LogStoreTests`
Expected: PASS (wszystkie testy z Task 1 + Task 2).

- [ ] **Step 5: Checkpoint**

Run: `swift build` — Expected: `Build complete!`.

---

## Task 3: Fasada `WegaLog` (OSLog + LogStore)

**Files:**
- Create: `Sources/MacUpdaterCore/WegaLog.swift`
- Test: `Tests/MacUpdaterTests/LogStoreTests.swift`

- [ ] **Step 1: Write the failing test**

Dopisz do `LogStoreTests`:
```swift
    @MainActor
    func testWegaLogWritesToSharedStore() {
        let before = LogStore.shared.entries.count
        WegaLog.error(.homebrew, "test-fasady-123")
        let added = LogStore.shared.entries.suffix(from: before)
        XCTAssertTrue(added.contains { $0.message == "test-fasady-123" && $0.level == .error && $0.category == .homebrew })
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter LogStoreTests`
Expected: FAIL — `cannot find 'WegaLog' in scope`.

- [ ] **Step 3: Write minimal implementation**

`Sources/MacUpdaterCore/WegaLog.swift`:
```swift
import OSLog

public enum WegaLog {
    public static func debug(_ category: LogCategory, _ message: String)   { log(.debug, category, message) }
    public static func info(_ category: LogCategory, _ message: String)    { log(.info, category, message) }
    public static func warning(_ category: LogCategory, _ message: String) { log(.warning, category, message) }
    public static func error(_ category: LogCategory, _ message: String)   { log(.error, category, message) }

    public static func log(_ level: LogLevel, _ category: LogCategory, _ message: String) {
        let entry = LogEntry(date: Date(), level: level, category: category, message: message)

        let logger = osLogger(for: category)
        switch level {
        case .debug:   logger.debug("\(message, privacy: .public)")
        case .info:    logger.info("\(message, privacy: .public)")
        case .warning: logger.notice("\(message, privacy: .public)")
        case .error:   logger.error("\(message, privacy: .public)")
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

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter LogStoreTests`
Expected: PASS. (Test używa `LogStore.shared`; `WegaLog.log` hopuje na MainActor — test też jest `@MainActor`, więc `Task` wykona się synchronicznie po `await`-cie? Jeśli test okaże się flaky przez asynchroniczny `Task`, zmień asercję na oczekiwanie: dodaj `await Task.yield()` przed odczytem `entries`.)

> Jeśli test jest niestabilny: oznacz go `func testWegaLogWritesToSharedStore() async` i
> dodaj `await Task.yield()` po `WegaLog.error(...)` przed asercją.

- [ ] **Step 5: Checkpoint**

Run: `swift build` — Expected: `Build complete!`.

---

## Task 4: `ManualUpdateScanner` — logowanie nieudanych checkerów

**Files:**
- Modify: `Sources/MacUpdaterCore/ManualUpdateScanner.swift`
- Test: `Tests/MacUpdaterTests/LogStoreTests.swift`

- [ ] **Step 1: Write the failing test**

Dopisz do `LogStoreTests` (test helpera `logged` przez efekt w `LogStore.shared`):
```swift
    @MainActor
    func testScannerLoggedWrapperLogsOnFailure() async {
        let before = LogStore.shared.entries.count
        let app = ApplicationInfo(
            name: "TestApp",
            path: URL(fileURLWithPath: "/Applications/TestApp.app"),
            version: "1.0",
            bundleIdentifier: "com.test.app",
            isManagedByBrew: false,
            isManagedByMas: false,
            caskToken: nil
        )
        let wrapped = ManualUpdateScanner.logged("GitHub", app) { .failed }
        let result = await wrapped()
        await Task.yield()
        XCTAssertEqual(result, .failed)
        let added = LogStore.shared.entries.suffix(from: before)
        XCTAssertTrue(added.contains { $0.message.contains("GitHub") && $0.message.contains("TestApp") && $0.level == .error })
    }

    @MainActor
    func testScannerLoggedWrapperSilentOnSuccess() async {
        let before = LogStore.shared.entries.count
        let app = ApplicationInfo(
            name: "TestApp",
            path: URL(fileURLWithPath: "/Applications/TestApp.app"),
            version: "1.0",
            bundleIdentifier: "com.test.app",
            isManagedByBrew: false,
            isManagedByMas: false,
            caskToken: nil
        )
        let wrapped = ManualUpdateScanner.logged("GitHub", app) { .upToDate }
        _ = await wrapped()
        await Task.yield()
        let added = LogStore.shared.entries.suffix(from: before)
        XCTAssertFalse(added.contains { $0.message.contains("GitHub · TestApp") })
    }
```

> **Najpierw zweryfikuj kształt `ApplicationInfo`**: otwórz
> `Sources/MacUpdaterCore/ApplicationScanner.swift` (lub plik definiujący
> `ApplicationInfo`) i dopasuj wywołanie `init` powyżej do realnych pól/etykiet.
> Jeśli `ApplicationInfo` ma inny zestaw pól, popraw oba testy zanim uruchomisz.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter LogStoreTests`
Expected: FAIL — `type 'ManualUpdateScanner' has no member 'logged'`.

- [ ] **Step 3: Write minimal implementation**

W `Sources/MacUpdaterCore/ManualUpdateScanner.swift` dodaj statyczny helper w `struct ManualUpdateScanner`:
```swift
    /// Opakowuje check tak, by przy `.failed` zalogować, które źródło dla której
    /// aplikacji zamilkło. `runBounded` nie zachowuje kolejności wyników, więc
    /// logujemy tutaj, w domknięciu, gdzie etykieta jest w zasięgu.
    static func logged(
        _ source: String,
        _ app: ApplicationInfo,
        _ run: @escaping @Sendable () async -> ManualCheckResult
    ) -> @Sendable () async -> ManualCheckResult {
        let appName = app.name
        return {
            let result = await run()
            if case .failed = result {
                WegaLog.error(.network, "\(source) · \(appName): brak odpowiedzi lub błąd parsowania")
            }
            return result
        }
    }
```

Następnie w metodzie `scan(...)` owiń każde dokładane domknięcie. Zastąp blok
budowania `work` (linie ~70–99) tak, by używał helpera:
```swift
        for app in appsToCheck {
            if let token = app.caskToken {
                let brewTracked = brewCaskVersions[token]
                work.append(Self.logged("Cask", app) {
                    guard let latest = await brew.caskLatestVersion(token: token) else { return .upToDate }
                    let reference = brewTracked ?? app.version
                    guard let installed = reference,
                          !versionsEqual(latest, installed),
                          isUpgrade(installed: installed, latest: latest) else { return .upToDate }
                    return .outdated(ManualOutdatedApp(
                        name: app.name, path: app.path,
                        installedVersion: app.version ?? installed,
                        availableVersion: versionVariants(latest).first ?? latest,
                        source: .cask(token: token)
                    ))
                })
            }
            work.append(Self.logged("JetBrains", app)   { await jetbrainsChecker.check(app: app) })
            work.append(Self.logged("GitHub", app)      { await githubChecker.check(app: app) })
            work.append(Self.logged("Synology", app)    { await synologyChecker.check(app: app) })
            work.append(Self.logged("Antigravity", app) { await antigravityChecker.check(app: app) })
            work.append(Self.logged("Parallels", app)   { await parallelsChecker.check(app: app) })
            work.append(Self.logged("Google Drive", app){ await googleDriveChecker.check(app: app) })
            work.append(Self.logged("ChatGPT", app)     { await chatGPTChecker.check(app: app) })
            work.append(Self.logged("Sparkle", app)     { await sparkleChecker.check(app: app) })
        }
```

> **Uwaga (Cask check):** „Cask" przy `.upToDate` jest najczęstszym wynikiem i
> NIE loguje (helper loguje tylko `.failed`) — szum zerowy. Ale czysty cask-check
> nigdy nie zwraca `.failed` (zwraca `.upToDate`/`.outdated`), więc owinięcie go
> jest neutralne; zostawione dla spójności.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter LogStoreTests`
Expected: PASS.

- [ ] **Step 5: Checkpoint**

Run: `swift test` — Expected: cały zestaw zielony (regresja: scanner i checkery dalej działają). Następnie `swift build`.

---

## Task 5: Banner — opcjonalna akcja `.openLogs`

**Files:**
- Modify: `Sources/MacUpdater/SharedViews.swift:246-284`
- Test: `Tests/MacUpdaterTests/LogFilterTests.swift` (sekcja BannerData)

- [ ] **Step 1: Write the failing test**

`Tests/MacUpdaterTests/LogFilterTests.swift` (na razie tylko BannerData):
```swift
import XCTest
@testable import MacUpdater

final class LogFilterTests: XCTestCase {
    func testBannerDataEquatableWithAndWithoutAction() {
        let a = BannerData(variant: .danger, title: "t", message: "m")
        let b = BannerData(variant: .danger, title: "t", message: "m", action: .openLogs)
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a, BannerData(variant: .danger, title: "t", message: "m"))
        XCTAssertNil(a.action)
        XCTAssertEqual(b.action, .openLogs)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter LogFilterTests`
Expected: FAIL — `extra argument 'action'` / `cannot find '.openLogs'`.

- [ ] **Step 3: Write minimal implementation**

W `Sources/MacUpdater/SharedViews.swift` zmień `BannerData` i `BannerView`:
```swift
enum BannerAction: Equatable { case openLogs }

struct BannerData: Equatable {
    enum Variant { case success, danger }
    let variant: Variant
    let title: String
    let message: String
    var action: BannerAction? = nil
}

struct BannerView: View {
    let data: BannerData
    var onAction: ((BannerAction) -> Void)? = nil
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: data.variant == .success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(data.variant == .success ? Color.wegaSuccess : Color.wegaDanger)
            VStack(alignment: .leading, spacing: 2) {
                Text(data.title).font(.system(size: 13, weight: .semibold))
                Text(data.message).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            if let action = data.action {
                Button { onAction?(action) } label: {
                    Label(tr("Zobacz w logach"), systemImage: "info.circle")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.wegaHoney)
                .accessibilityLabel(tr("Zobacz w logach"))
            }
            Button { onClose() } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .accessibilityLabel(tr("Zamknij"))
        }
        .padding(14)
        .background(
            data.variant == .success ? Color.wegaSuccess.opacity(0.08) : Color.wegaDanger.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    data.variant == .success ? Color.wegaSuccess.opacity(0.3) : Color.wegaDanger.opacity(0.3),
                    lineWidth: 1
                )
        )
    }
}
```

> Istniejące wywołania `BannerView(data: b) { banner = nil }` dalej kompilują się —
> `onAction` ma domyślne `nil`, a domknięcie trailing trafia w `onClose`.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter LogFilterTests`
Expected: PASS.

- [ ] **Step 5: Checkpoint**

Run: `swift build` — Expected: `Build complete!` (sprawdza, że MigrationView i UpdateView dalej kompilują z nowym `BannerView`).

---

## Task 6: Czysta funkcja filtrowania + `LogsView`

**Files:**
- Create: `Sources/MacUpdater/LogsView.swift`
- Test: `Tests/MacUpdaterTests/LogFilterTests.swift`

- [ ] **Step 1: Write the failing test**

Dopisz do `LogFilterTests`:
```swift
    private func entry(_ level: LogLevel, _ msg: String, _ cat: LogCategory = .app) -> LogEntry {
        LogEntry(date: Date(), level: level, category: cat, message: msg)
    }

    func testFilterByLevel() {
        let all = [entry(.info, "a"), entry(.warning, "b"), entry(.error, "c"), entry(.debug, "d")]
        XCTAssertEqual(filterLogEntries(all, level: .all, search: "").count, 4)
        XCTAssertEqual(filterLogEntries(all, level: .errorsOnly, search: "").map(\.message), ["c"])
        XCTAssertEqual(Set(filterLogEntries(all, level: .warningsAndUp, search: "").map(\.message)), ["b", "c"])
    }

    func testFilterBySearchMatchesMessageAndCategory() {
        let all = [entry(.info, "hello", .homebrew), entry(.info, "world", .network)]
        XCTAssertEqual(filterLogEntries(all, level: .all, search: "hel").map(\.message), ["hello"])
        XCTAssertEqual(filterLogEntries(all, level: .all, search: "network").map(\.message), ["world"])
        XCTAssertEqual(filterLogEntries(all, level: .all, search: "HELLO").map(\.message), ["hello"]) // case-insensitive
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter LogFilterTests`
Expected: FAIL — `cannot find 'filterLogEntries'/'LogLevelFilter'`.

- [ ] **Step 3: Write minimal implementation**

`Sources/MacUpdater/LogsView.swift`:
```swift
import SwiftUI
import AppKit
import MacUpdaterCore

enum LogLevelFilter: CaseIterable, Identifiable {
    case all, warningsAndUp, errorsOnly
    var id: Self { self }
    var label: String {
        switch self {
        case .all:          return tr("Wszystkie")
        case .warningsAndUp: return tr("Ostrzeżenia+")
        case .errorsOnly:   return tr("Tylko błędy")
        }
    }
    func includes(_ level: LogLevel) -> Bool {
        switch self {
        case .all:           return true
        case .warningsAndUp: return level == .warning || level == .error
        case .errorsOnly:    return level == .error
        }
    }
}

/// Czysta funkcja filtrowania — testowalna bez UI.
func filterLogEntries(_ entries: [LogEntry], level: LogLevelFilter, search: String) -> [LogEntry] {
    let q = search.trimmingCharacters(in: .whitespaces).lowercased()
    return entries.filter { e in
        guard level.includes(e.level) else { return false }
        guard !q.isEmpty else { return true }
        return e.message.lowercased().contains(q) || e.category.label.lowercased().contains(q)
    }
}

struct LogsView: View {
    @ObservedObject var store = LogStore.shared
    var onWegaState: ((WegaState) -> Void)?
    var initialFilter: LogLevelFilter = .all

    @State private var filter: LogLevelFilter = .all
    @State private var search: String = ""
    @State private var confirmingClear = false

    private var visible: [LogEntry] {
        // Najnowsze na górze.
        filterLogEntries(store.entries, level: filter, search: search).reversed()
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().opacity(0.5)
            if visible.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(visible) { row($0) }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .onAppear {
            filter = initialFilter
            onWegaState?(WegaState(pose: .sniff, line: tr("Zaglądam do notatek…")))
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Picker("", selection: $filter) {
                ForEach(LogLevelFilter.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 320)

            TextField(tr("Szukaj w logach…"), text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 240)

            Spacer()

            Button { revealInFinder() } label: { Label(tr("Pokaż w Finderze"), systemImage: "folder") }
                .buttonStyle(.plain).foregroundStyle(Color.wegaHoney)
            Button { copyVisible() } label: { Label(tr("Kopiuj"), systemImage: "doc.on.doc") }
                .buttonStyle(.plain).foregroundStyle(Color.wegaHoney)
            Button { confirmingClear = true } label: { Label(tr("Wyczyść"), systemImage: "trash") }
                .buttonStyle(.plain).foregroundStyle(Color.wegaDanger)
                .confirmationDialog(tr("Wyczyścić logi?"), isPresented: $confirmingClear) {
                    Button(tr("Wyczyść"), role: .destructive) { store.clear() }
                    Button(tr("Anuluj"), role: .cancel) {}
                }
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
    }

    private func row(_ e: LogEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(Self.timeFormatter.string(from: e.date))
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
                .frame(width: 64, alignment: .leading)
            Text(e.level.rawValue.uppercased())
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(levelColor(e.level))
                .frame(width: 64, alignment: .leading)
            Text(e.category.label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.wegaHoney)
                .frame(width: 84, alignment: .leading)
            Text(e.message)
                .font(.system(size: 11.5, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16).padding(.vertical, 4)
    }

    private func levelColor(_ level: LogLevel) -> Color {
        switch level {
        case .error:   return Color.wegaDanger
        case .warning: return Color.wegaToffee
        case .info, .debug: return .secondary
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            WegaFull(pose: .idle, size: 120)
            Text(tr("Cicho jak makiem zasiał — żadnych zdarzeń."))
                .font(.system(size: 13)).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([store.logFileURL])
    }

    private func copyVisible() {
        let text = visible.map(\.fileLine).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()
}
```

> **Sprawdź nazwę widoku pozy Wegi:** w `emptyState` użyto `WegaFull(pose:size:)`
> (jak w `BrewRequiredView`). Jeśli sygnatura jest inna, dostosuj.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter LogFilterTests`
Expected: PASS.

- [ ] **Step 5: Checkpoint**

Run: `swift build` — Expected: `Build complete!`.

---

## Task 7: Nawigacja — `SidebarTab.logs`, `ContentArea`, `onNavigate`, pre-filtr

**Files:**
- Modify: `Sources/MacUpdater/ContentView.swift`
- Modify: `Sources/MacUpdater/WegaTheme.swift:42-54` (`WegaState.forTab` — case `.logs`)
- Modify: `Sources/MacUpdater/UpdateView.swift` (parametr `onNavigate`)

- [ ] **Step 1: Add the `.logs` tab to `SidebarTab`**

W `Sources/MacUpdater/ContentView.swift`, w `enum SidebarTab`:
```swift
    case update    = "update"
    case uninstall = "uninstall"
    case migration = "migration"
    case inventory = "inventory"
    case logs      = "logs"
    case info      = "info"
```
W `label`:
```swift
        case .logs:      return tr("Logi")
```
W `systemImage`:
```swift
        case .logs:      return "doc.text.magnifyingglass"
```
W `hint`:
```swift
        case .logs:      return tr("Co się działo")
```
W `toolTabs`:
```swift
    static var toolTabs: [SidebarTab] { [.update, .uninstall, .migration, .inventory, .logs] }
```

- [ ] **Step 2: Add `.logs` case to `WegaState.forTab`**

W `Sources/MacUpdater/WegaTheme.swift`, w `forTab`:
```swift
        case .logs:      return WegaState(pose: .sniff, line: tr("Co się ostatnio działo?"))
```

- [ ] **Step 3: Add `onNavigate` to `UpdateView` and wire banner actions**

W `Sources/MacUpdater/UpdateView.swift`:
1. Dodaj property obok istniejących callbacków (`onWegaState`, `onBadgeChange`):
```swift
    var onNavigate: ((SidebarTab) -> Void)?
```
2. Zmień wywołanie `BannerView` (linia ~154) tak, by przekazywało `onAction`:
```swift
                BannerView(data: b, onAction: { action in
                    switch action {
                    case .openLogs: onNavigate?(.logs)
                    }
                }) { banner = nil }
```
3. Na trzech bannerach błędu dodaj `action: .openLogs` (linie ~321, ~326, ~330–337):
```swift
                banner = BannerData(variant: .danger, title: tr("Błąd Homebrew"), message: msg, action: .openLogs)
```
(oba „Błąd Homebrew"), oraz:
```swift
        case .checkFailed:
            banner = BannerData(variant: .danger,
                                title: tr("Nie udało się sprawdzić aktualizacji"),
                                message: errorMessage ?? tr("Część źródeł nie odpowiedziała — sprawdź połączenie z internetem i spróbuj ponownie."),
                                action: .openLogs)
        case .partialFailure(let updates, let failed):
            banner = BannerData(variant: .danger,
                                title: tr("Lista może być niepełna"),
                                message: trf("Znalazłam %@ aktualizacji, ale %@ źródeł nie odpowiedziało — sprawdź połączenie i odśwież.", "\(updates)", "\(failed)"),
                                action: .openLogs)
```

- [ ] **Step 4: Add `.logs` case to `ContentArea` switch + pass `onNavigate` + pre-filter**

W `Sources/MacUpdater/ContentView.swift`, w `ContentArea`:
1. Dodaj stan na pre-filtr:
```swift
    @State private var logsInitialFilter: LogLevelFilter = .all
```
2. W switchu `activeTab`:
```swift
                case .update:
                    UpdateView(
                        onWegaState:   { wegaState = $0 },
                        onBadgeChange: { updateBadge = $0 },
                        onNavigate:    { tab in
                            if tab == .logs { logsInitialFilter = .errorsOnly }
                            activeTab = tab
                            wegaState = .forTab(tab)
                        }
                    )
```
3. Dodaj case `.logs`:
```swift
                case .logs:
                    LogsView(onWegaState: { wegaState = $0 }, initialFilter: logsInitialFilter)
                        .id(logsInitialFilter)   // wymusza zastosowanie initialFilter przy zmianie kontekstu wejścia
```

> `.id(logsInitialFilter)` gwarantuje, że `LogsView` przeczyta nowy `initialFilter`
> w `onAppear`, gdy wchodzimy z bannera (errorsOnly) vs z menu (all). Wejście z menu
> bocznego ustawia `logsInitialFilter` z powrotem na `.all` — patrz Step 5.

- [ ] **Step 5: Reset pre-filter on sidebar navigation to Logs**

W `Sources/MacUpdater/ContentView.swift`, `SidebarView` woła `onSelect`, który ustawia
`activeTab`. Żeby kliknięcie „Logi" w menu dawało `.all`, rozszerz `onSelect` w
`ContentView`/`SidebarView` o reset. Najprościej: w `SidebarTabRow.onSelect` dla
`.logs` zerujemy filtr. `SidebarView` nie zna `logsInitialFilter`, więc przenosimy
reset do domknięcia w `ContentView` body, gdzie tworzony jest `SidebarView`:

W `ContentView.body`, `SidebarView(...)` nie ma `onSelect` (tab-rows mają własne).
Reset zrób w `ContentArea` przez obserwację zmiany `activeTab`:
```swift
        .onChange(of: activeTab) { _, newTab in
            // Wejście do Logów spoza bannera (np. z menu) → filtr „Wszystkie".
            // Banner ustawia logsInitialFilter = .errorsOnly *przed* zmianą activeTab,
            // więc tu resetujemy tylko gdy to nie było przejście z bannera.
        }
```

> **Uproszczenie (zalecane):** zamiast śledzić źródło wejścia, użyj jawnego sygnału.
> Trzymaj `logsInitialFilter` ustawiany WYŁĄCZNIE przez `onNavigate` z bannera, a w
> `SidebarTabRow` dla `.logs` (w `SidebarView`) dodaj osobny callback resetujący.
> Konkretnie: rozszerz `SidebarView` o `onResetLogsFilter: () -> Void`, wołany w
> `onSelect` gdy `tab == .logs`; w `ContentView` przekaż `{ logsInitialFilter = .all }`.
> Usuń pusty `.onChange` powyżej.

Zaimplementuj wariant „uproszczenie": 
- `SidebarView` zyskuje `var onResetLogsFilter: () -> Void`.
- W pętli `ForEach(SidebarTab.toolTabs)` w `onSelect`:
```swift
                        onSelect: {
                            if tab == .logs { onResetLogsFilter() }
                            activeTab = tab
                            wegaState = .forTab(tab)
                        }
```
- `logsInitialFilter` przenieś z `ContentArea` do `ContentView` (żeby `SidebarView`
  i `ContentArea` współdzieliły) jako `@State`, przekaż do `ContentArea` przez
  `@Binding` i do `SidebarView` reset jako `{ logsInitialFilter = .all }`.

- [ ] **Step 6: Build + manual verify**

Run: `swift build` — Expected: `Build complete!`.
Manualnie (opcjonalnie, patrz „Weryfikacja end-to-end" na końcu): uruchom app,
wejdź w „Logi" z menu (filtr „Wszystkie"), potem wymuś błąd źródła i kliknij
„Zobacz w logach" na bannerze → zakładka Logi z filtrem „Tylko błędy".

- [ ] **Step 7: Checkpoint**

Run: `swift test` — Expected: cały zestaw zielony.

---

## Task 8: Badge błędów przy zakładce „Logi"

**Files:**
- Modify: `Sources/MacUpdater/ContentView.swift` (`SidebarView`, `SidebarTabRow`)
- Modify: `Sources/MacUpdater/UpdateView.swift` (`onBadgeChange`-podobny sygnał błędów)

- [ ] **Step 1: Propagate last-scan error count**

W `Sources/MacUpdater/UpdateView.swift` dodaj callback:
```swift
    var onErrorCount: ((Int) -> Void)?
```
Na końcu `runScan`, po ustaleniu `failedSources`, zaraz przy `onBadgeChange?(...)`:
```swift
        onErrorCount?(failedSources)
```

- [ ] **Step 2: Hold the count in `ContentView` and clear on entering Logs**

W `ContentView`:
```swift
    @State private var logsErrorBadge: Int = 0
```
Przekaż do `ContentArea` (binding) i do `UpdateView`:
```swift
                        onErrorCount: { logsErrorBadge = $0 }
```
W `onResetLogsFilter`/wejściu w Logi wyzeruj badge:
```swift
    // gdy activeTab staje się .logs:
    // logsErrorBadge = 0
```
Najprościej: w `SidebarTabRow.onSelect` dla `.logs` (już rozszerzonym w Task 7)
dodaj `logsErrorBadge = 0` (przez dodatkowy callback `onEnterLogs` albo łącząc z
`onResetLogsFilter`). Połącz oba w jeden callback `onEnterLogs: () -> Void` =
`{ logsInitialFilter = .all; logsErrorBadge = 0 }`.

- [ ] **Step 3: Render danger badge on the Logs row**

W `SidebarView`, w `ForEach(SidebarTab.toolTabs)`:
```swift
                    SidebarTabRow(
                        tab:      tab,
                        isActive: activeTab == tab,
                        badge:    badgeValue(for: tab),
                        badgeIsDanger: tab == .logs,
                        onSelect: { ... }
                    )
```
gdzie:
```swift
    private func badgeValue(for tab: SidebarTab) -> Int? {
        switch tab {
        case .update: return updateBadge > 0 ? updateBadge : nil
        case .logs:   return logsErrorBadge > 0 ? logsErrorBadge : nil
        default:      return nil
        }
    }
```
(`SidebarView` musi dostać `logsErrorBadge: Int` jako property.)

Rozszerz `SidebarTabRow` o `badgeIsDanger`:
```swift
private struct SidebarTabRow: View {
    let tab:      SidebarTab
    let isActive: Bool
    let badge:    Int?
    var badgeIsDanger: Bool = false
    let onSelect: () -> Void
    ...
```
W renderze badge zamień kolory na warianty zależne od `badgeIsDanger`:
```swift
                if let b = badge {
                    let fg: Color = badgeIsDanger
                        ? .white
                        : (isActive ? Color(red: 0.16, green: 0.11, blue: 0.07) : Color.wegaHoney)
                    let bg: Color = badgeIsDanger
                        ? Color.wegaDanger
                        : (isActive ? Color.wegaHoney : Color.wegaHoney.opacity(0.18))
                    Text("\(b)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(fg)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(bg, in: Capsule())
                }
```

- [ ] **Step 4: Build + verify**

Run: `swift build` — Expected: `Build complete!`.

- [ ] **Step 5: Checkpoint**

Run: `swift test` — Expected: zielony.

---

## Task 9: Lokalizacja (EN) — `Translations.swift`

**Files:**
- Modify: `Sources/MacUpdaterCore/Translations.swift`
- Test (istniejący): `Tests/MacUpdaterTests/LocalizationCompletenessTests.swift`

- [ ] **Step 1: Run the completeness test to see what's missing**

Run: `swift test --filter LocalizationCompleteness`
Expected: FAIL — `everyUIKeyHasEnglishTranslation` zgłasza brakujące klucze PL
(nowe stringi z Tasków 6–8).

> Ten test jest naszym „failing test" dla tego zadania — wymusza wpisy EN dla
> każdego użytego `tr(...)`.

- [ ] **Step 2: Add the EN entries**

W `Sources/MacUpdaterCore/Translations.swift`, do mapy PL→EN dodaj:
```swift
        "Logi": "Logs",
        "Co się działo": "What happened",
        "Co się ostatnio działo?": "What happened recently?",
        "Zaglądam do notatek…": "Checking my notes…",
        "Wszystkie": "All",
        "Ostrzeżenia+": "Warnings+",
        "Tylko błędy": "Errors only",
        "Szukaj w logach…": "Search logs…",
        "Pokaż w Finderze": "Show in Finder",
        "Kopiuj": "Copy",
        "Wyczyść": "Clear",
        "Wyczyścić logi?": "Clear the logs?",
        "Anuluj": "Cancel",
        "Zobacz w logach": "View in logs",
        "Cicho jak makiem zasiał — żadnych zdarzeń.": "All quiet — no events.",
```

> Jeśli któryś klucz (np. „Anuluj", „Kopiuj") już istnieje w mapie, **nie dubluj** —
> usuń duplikat z powyższej listy (kompilator zgłosi „Duplicate key").

- [ ] **Step 3: Run the completeness test to verify it passes**

Run: `swift test --filter LocalizationCompleteness`
Expected: PASS.

- [ ] **Step 4: Checkpoint**

Run: `swift test` — Expected: cały zestaw zielony.

---

## Task 10: README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update README**

Dodaj opis nowej zakładki i lokalizacji pliku logu. W sekcji opisującej UI/funkcje
dopisz akapit:
```markdown
### Logi

Zakładka **Logi** pokazuje pełny log aktywności aplikacji (skany, odpowiedzi
źródeł, wyniki instalacji, błędy) — od najnowszych. Filtruj po poziomie
(Wszystkie / Ostrzeżenia+ / Tylko błędy), przeszukuj, kopiuj lub pokaż plik w
Finderze. Gdy źródło nie odpowie, ostrzeżenie na liście aktualizacji ma przycisk
**„Zobacz w logach"**, który przenosi do zakładki Logi z filtrem błędów.

Log jest też zapisywany do pliku `~/Library/Logs/WegaMacUpdater/wega.log`
(z jednym backupem `wega.log.1` po przekroczeniu ~5 MB).
```

- [ ] **Step 2: Checkpoint**

Brak testów. Zweryfikuj, że README czyta się spójnie z resztą. (Commit — użytkownik.)

---

## Weryfikacja end-to-end (po wszystkich taskach)

- [ ] `swift test` — cały zestaw zielony.
- [ ] `swift build -c release --arch arm64` — kompiluje.
- [ ] Złóż minimalny `.app` (jak w sesji wcześniej: skopiuj binarkę + bundle
      `WegaMacUpdater_MacUpdaterCore.bundle` + `Info.plist`, ad-hoc `codesign`),
      uruchom, i sprawdź:
  - Zakładka „Logi" widoczna w menu; po skanie ma wpisy.
  - Wejście w „Logi" z menu → filtr „Wszystkie".
  - Banner „Lista może być niepełna" ma przycisk „Zobacz w logach" → przenosi do
    Logów z filtrem „Tylko błędy".
  - Po skanie z nieodpowiadającym źródłem przy „Logi" pojawia się badge błędów;
    wejście w zakładkę go zeruje.
  - `~/Library/Logs/WegaMacUpdater/wega.log` powstaje i rośnie.

---

## Self-Review (wypełnione przy pisaniu planu)

- **Pokrycie spec:** LogStore+plik+rotacja (T1–T2), fasada (T3), pełny log/błędy
  ze szczegółem (T3 w runScan opisane w T7-Step3 + T4 scanner), zakładka Logi z
  filtrami/akcjami (T6), nawigacja+pre-filtr (T7), badge błędów (T8), lokalizacja
  (T9), README (T10), testy (T1–T6, T9). ✔
  - ⚠️ Logowanie brew/mas/npm w `runScan` (`WegaLog.error`/`info`) — **dodane w
    Task 7? Nie.** Patrz uzupełnienie niżej.
- **Placeholdery:** brak „TBD/TODO"; kroki mają pełny kod.
- **Spójność typów:** `LogLevelFilter` (.all/.warningsAndUp/.errorsOnly),
  `filterLogEntries`, `BannerAction.openLogs`, `LogStore.shared`, `WegaLog.error`
  — używane spójnie w T5–T9.

### Uzupełnienie pominięte w numeracji: logowanie źródeł w `runScan`

Dodaj jako **Task 7, Step 3a** (przed bannerami) w `Sources/MacUpdater/UpdateView.swift`
`runScan`, w blokach catch i wokół skanu:
```swift
        WegaLog.info(.scanner, tr("Skan rozpoczęty"))           // na początku runScan
        // brew:
        catch { errorMessage = error.localizedDescription; brewOutdated = nil; failedSources += 1
                WegaLog.error(.homebrew, "brew outdated: \(error.localizedDescription)") }
        // mas:
        catch { masOutdated = []; failedSources += 1
                WegaLog.error(.app, "mas outdated: \(error.localizedDescription)") }
        // npm:
        catch { npmOutdated = []; failedSources += 1
                WegaLog.error(.network, "npm outdated: \(error.localizedDescription)") }
        // przed switch scanState:
        WegaLog.info(.scanner, "Skan zakończony: \(total) aktualizacji, \(failedSources) źródeł nie odpowiedziało")
```
> `tr("Skan rozpoczęty")` wymaga wpisu EN — dodaj `"Skan rozpoczęty": "Scan started"`
> do listy w Task 9. (Pozostałe komunikaty logu są diagnostyczne i mogą zostać po
> polsku bez `tr` — log nie jest tłumaczony per-wpis; `LocalizationCompleteness`
> sprawdza tylko stringi w `tr(...)`.)
