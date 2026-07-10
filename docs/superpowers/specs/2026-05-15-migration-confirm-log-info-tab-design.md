# Design: Migration Confirmation + Live Log + Info Tab

**Date:** 2026-05-15
**Status:** Approved

---

## Feature 1: Migration — potwierdzenie i live log

### Problem

`migrate()` jest stubem (1.2s sleep). Użytkownik klika "Przepnij" bez żadnego ostrzeżenia ani informacji o tym co się stanie. Brak widoczności postępu ani informacji o błędzie.

### Rozwiązanie

Przepływ: klik "Przepnij" → sheet z potwierdzeniem → po akceptacji: uruchomienie `brew install --cask <token>` z live logiem → banner sukcesu lub błędu.

### Zmiany w `MigrationView`

**Nowe `@State`:**
```swift
@State private var confirmingApp: ApplicationInfo? = nil
@State private var logLines:      [String]          = []
@State private var migrating:     String?            = nil   // zastępuje busy: String?
```

Obecne `@State private var busy: String?` zostaje usunięte — zastępuje je `migrating`.

**Sheet potwierdzenia** (`.sheet(item: $confirmingApp)`):

Trigger: `MigrationRow` ustawia `confirmingApp = app` zamiast bezpośrednio wywoływać `migrate`.

Zawartość sheeta (`MigrationConfirmSheet`):
- `PackageLetterIcon` + nazwa aplikacji
- Blok monospace z komendą: `brew install --cask <token>`
- Opis: "Homebrew pobierze najnowszą wersję i zastąpi aktualną instalację w /Applications. Zamknij aplikację przed kontynuowaniem."
- Przyciski: "Anuluj" (dismiss) + "Migruj" (uruchamia `migrate(app)`, dismiss)

**`migrate(_ app:)` — pełna implementacja** (zastępuje stub):
```swift
private func migrate(_ app: ApplicationInfo) async {
    guard migrating == nil, let token = app.caskToken else { return }
    migrating = token
    logLines = []
    onWegaState?(WegaState(pose: .sniff, line: "Instaluję \(app.name) przez Homebrew…"))

    do {
        let stream = try model.brewService.events(arguments: ["install", "--cask", token])
        var exitCode: Int32 = 0
        for try await event in stream {
            switch event {
            case .stdout(let line), .stderr(let line):
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    await MainActor.run {
                        logLines.append(trimmed)
                        if logLines.count > 200 { logLines.removeFirst() }
                    }
                }
            case .finished(let result):
                exitCode = result.exitCode
            }
        }
        if exitCode == 0 {
            migrated.insert(token)
            await MainActor.run { logLines = [] }
            banner = BannerData(variant: .success,
                                title: "\(app.name) pod Homebrew",
                                message: "Token: \(token)")
            onWegaState?(WegaState(pose: .happy, line: "\(app.name) przejęty! Idziemy dalej."))
        } else {
            errorMessage = "Instalacja \(token) zakończyła się błędem (kod \(exitCode)). Sprawdź log poniżej."
            onWegaState?(WegaState(pose: .sad, line: "Ups. Brew zgłosił problem z \(app.name)."))
        }
    } catch {
        errorMessage = error.localizedDescription
        onWegaState?(WegaState(pose: .sad, line: "Błąd podczas migracji \(app.name)."))
    }
    migrating = nil
}
```

**`MigrationRow`** — zmiana: przycisk "Przepnij" ustawia `confirmingApp = app` (nie wywołuje `migrate` bezpośrednio). `isBusy` używa `migrating == app.caskToken`.

**`MigrationLogView`** — nowy prywatny widok:
- Wyświetlany w `resultsView` między sekcją "Można przepiąć" a "App Store", gdy `!logLines.isEmpty || migrating != nil`
- `ScrollViewReader` z auto-scrollem do ostatniej linii przy każdej zmianie `logLines`
- Monospace font 11pt, ciemne tło (`Color.black.opacity(0.85)`), białe litery
- Nagłówek: "Log migracji" + `ProgressView` gdy `migrating != nil`
- Wysokość: `min(CGFloat(logLines.count) * 18 + 32, 280)` (max ~280px)

**`MigrationConfirmSheet`** — nowy prywatny struct `View`:
- Przyjmuje `app: ApplicationInfo` i `onConfirm: () -> Void`
- Prezentowany jako `.sheet(item: $confirmingApp)`

### Brak nowych metod w `BrewService`

`BrewService.events(arguments:)` już istnieje — wywołanie z `["install", "--cask", token]` wystarczy.

---

## Feature 2: Zakładka Info

### Zmiany w `SidebarTab`

Nowy case `.info` na końcu enuma:

```swift
case info = "info"
// label: "Info"
// systemImage: "info.circle"
// hint: "O aplikacji"
```

W sidebarze (`ContentView`) sidebar przestaje używać `ForEach(SidebarTab.allCases)`. Zamiast tego: cztery główne taby (update/uninstall/migration/inventory) renderowane jawnie + `Divider()` + `SidebarTabRow` dla `.info` na dole. Pozwala to kontrolować pozycję bez zmiany kolejności w enum.

### `InfoView.swift` — nowy plik

Lokalizacja: `Sources/MacUpdater/InfoView.swift`

`WegaState` przy wejściu: `.idle` + "Oto co o sobie wiem."

**Karta 1 — Aplikacja:**
- `WegaIcon(size: 56)` + "WegaMacUpdater" (bold, 20pt)
- Wersja: `Bundle.main.infoDictionary?["CFBundleShortVersionString"]` (fallback: "—")
- Build: `Bundle.main.infoDictionary?["CFBundleVersion"]` (fallback: "—")
- Separator
- Link: `Link("GitHub", destination: URL(string: "https://github.com/DominikSienkiewicz/WegaMacUpdater")!)`
- Link: `Link("Zgłoś błąd", destination: URL(string: "https://github.com/DominikSienkiewicz/WegaMacUpdater/issues")!)`

**Karta 2 — Diagnostyka systemu** (ładowana async w `onAppear`):
- Homebrew: sprawdzenie przez `BinaryLocator.locateBrew()` + `brew --version`
- `mas`: sprawdzenie przez `BinaryLocator.locateMas()` + `mas version`
- Privileged Helper: sprawdzenie czy plik `/Library/PrivilegedHelperTools/com.wega.WegaMacUpdaterPrivilegedHelper` istnieje
- Każdy wiersz: `Image(systemName: "circle.fill")` (zielona/żółta/szara) + label + wersja lub status

Stan ładowania: `@State private var diagnostics: DiagnosticsResult? = nil` z `ProgressView` gdy `nil`.

```swift
struct DiagnosticsResult {
    var brewVersion:   String?  // nil = nie znaleziono
    var masVersion:    String?  // nil = nie znaleziono (opcjonalne)
    var helperActive:  Bool
    var macOSVersion:  String
    var architecture:  String
}
```

**Karta 3 — Zewnętrzne narzędzia:**
- Statyczna lista:
  - Homebrew — BSD 2-Clause — `https://brew.sh`
  - mas-cli — MIT — `https://github.com/mas-cli/mas`
- Każdy wiersz: nazwa + licencja + `Link("↗", destination:)`

**Karta 4 — Środowisko:**
- macOS: `ProcessInfo.processInfo.operatingSystemVersionString`
- CPU: `ProcessInfo.processInfo.processorCount` + architektura z `uname -m`

### Diagnostics loading

```swift
private func loadDiagnostics() async {
    let locator = BinaryLocator()
    var brewV: String? = nil
    var masV: String? = nil

    if let brewURL = locator.locateBrew(),
       let result = try? await ProcessRunner().run(ProcessRequest(
           executableURL: brewURL, arguments: ["--version"],
           environment: HomebrewEnvironment.environment, timeout: 5)) {
        brewV = result.stdout.split(separator: "\n").first.map(String.init)
    }

    if let masURL = locator.locateMas(),
       let result = try? await ProcessRunner().run(ProcessRequest(
           executableURL: masURL, arguments: ["version"],
           environment: HomebrewEnvironment.environment, timeout: 5)) {
        masV = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    let helperPath = "/Library/PrivilegedHelperTools/com.wega.WegaMacUpdaterPrivilegedHelper"
    let helperActive = FileManager.default.fileExists(atPath: helperPath)

    diagnostics = DiagnosticsResult(
        brewVersion: brewV,
        masVersion: masV,
        helperActive: helperActive,
        macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
        architecture: Self.cpuArch()  // "arm64" lub "x86_64" z uname(3)
    )
}
```

---

## Zmiany w plikach

| Plik | Zmiana |
|---|---|
| `Sources/MacUpdater/MigrationView.swift` | Nowe `@State`, `migrate()` z live stream, `MigrationLogView`, `MigrationConfirmSheet` |
| `Sources/MacUpdater/ContentView.swift` | Nowy case `.info` w `SidebarTab`, sidebar z separatorem przed Info |
| `Sources/MacUpdater/InfoView.swift` | Nowy plik |

## Non-goals

- Odinstalowanie starej wersji po migracji (osobna funkcja)
- Testowanie `InfoView` (SwiftUI view, trudne do unit testowania)
- Lokalizacja (PL hardcoded jak w reszcie UI)
- `cpuArch()` implementacja: `var info = utsname(); uname(&info); return withUnsafeBytes(of: &info.machine) { String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self)) }`
