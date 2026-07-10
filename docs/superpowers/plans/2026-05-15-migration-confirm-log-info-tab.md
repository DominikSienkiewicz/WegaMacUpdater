# Migration Confirmation + Live Log + Info Tab Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a confirmation sheet + live brew log to the Migration view, and add a new Info sidebar tab with system diagnostics.

**Architecture:** `MigrationView` gets a `confirmingApp` state that drives a `.sheet(item:)` confirmation dialog; on confirm, the existing `migrate()` stub is replaced with real `BrewService.events()` streaming into `logLines`, rendered by a new `MigrationLogView`. A new `SidebarTab.info` case is added; `ContentView` sidebar switches from `ForEach(allCases)` to explicit rows + `Divider()` + Info row at bottom; `InfoView.swift` is created with 4 cards and async diagnostics.

**Tech Stack:** SwiftUI, Swift Concurrency (`AsyncThrowingStream`, `MainActor`), `BrewService.events(arguments:)`, `BinaryLocator`, `ProcessRunner`, `utsname`/`uname(3)` for CPU arch.

---

## File Map

| File | Action | Responsibility |
|---|---|---|
| `Sources/MacUpdater/ContentView.swift` | Modify | Add `.info` case to `SidebarTab`; replace `ForEach(allCases)` with explicit rows + divider |
| `Sources/MacUpdater/WegaTheme.swift` | Modify | Add `.info` case to `WegaState.forTab(_:)` |
| `Sources/MacUpdater/InfoView.swift` | Create | 4-card Info tab: app info, diagnostics, licenses, environment |
| `Sources/MacUpdater/MigrationView.swift` | Modify | `confirmingApp` state, real `migrate()`, `MigrationLogView`, `MigrationConfirmSheet` |

---

### Task 1: `SidebarTab.info` + sidebar layout + `WegaState.forTab` update

**Files:**
- Modify: `Sources/MacUpdater/ContentView.swift:5-37` (SidebarTab enum)
- Modify: `Sources/MacUpdater/ContentView.swift:95-116` (ForEach → explicit rows)
- Modify: `Sources/MacUpdater/ContentView.swift:326-340` (ContentArea switch)
- Modify: `Sources/MacUpdater/WegaTheme.swift` (forTab switch)

- [ ] **Step 1: Add `.info` case to `SidebarTab` in `ContentView.swift`**

Replace the enum body (lines 5–37) with:

```swift
enum SidebarTab: String, CaseIterable, Identifiable {
    case update    = "update"
    case uninstall = "uninstall"
    case migration = "migration"
    case inventory = "inventory"
    case info      = "info"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .update:    return "Update"
        case .uninstall: return "Uninstall"
        case .migration: return "Migration"
        case .inventory: return "Inventory"
        case .info:      return "Info"
        }
    }
    var systemImage: String {
        switch self {
        case .update:    return "arrow.triangle.2.circlepath"
        case .uninstall: return "trash"
        case .migration: return "arrow.right.doc.on.clipboard"
        case .inventory: return "tablecells"
        case .info:      return "info.circle"
        }
    }
    var hint: String {
        switch self {
        case .update:    return "Co do odświeżenia"
        case .uninstall: return "Usuń aplikacje"
        case .migration: return "Przepnij pod Brew"
        case .inventory: return "Pełny obchód"
        case .info:      return "O aplikacji"
        }
    }
}
```

- [ ] **Step 2: Replace `ForEach(SidebarTab.allCases)` with explicit rows + divider**

In `SidebarView.body`, replace the `VStack` containing `ForEach(SidebarTab.allCases)` (lines 95–116):

```swift
VStack(alignment: .leading, spacing: 1) {
    Text("Narzędzia")
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.tertiary)
        .textCase(.uppercase)
        .tracking(1)
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 4)

    ForEach([SidebarTab.update, .uninstall, .migration, .inventory]) { tab in
        SidebarTabRow(
            tab:      tab,
            isActive: activeTab == tab,
            badge:    tab == .update && updateBadge > 0 ? updateBadge : nil,
            onSelect: {
                activeTab = tab
                wegaState = .forTab(tab)
            }
        )
    }

    Divider().opacity(0.4).padding(.vertical, 4)

    SidebarTabRow(
        tab:      .info,
        isActive: activeTab == .info,
        badge:    nil,
        onSelect: {
            activeTab = .info
            wegaState = .forTab(.info)
        }
    )
}
.padding(.horizontal, 8)
.padding(.top, 6)
```

- [ ] **Step 3: Add `.info` case to `ContentArea` switch**

In `ContentArea.body`, the `switch activeTab` block (around lines 327–339), add before the closing brace:

```swift
case .info:
    InfoView(onWegaState: { wegaState = $0 })
```

- [ ] **Step 4: Add `.info` case to `WegaState.forTab` in `WegaTheme.swift`**

In `WegaTheme.swift`, the `forTab` static function — add the `.info` case:

```swift
case .info: return WegaState(pose: .idle, line: "Oto co o sobie wiem.")
```

- [ ] **Step 5: Verify build compiles**

```bash
swift build 2>&1 | grep -E "error:|Build complete"
```

Expected: `Build complete!`

---

### Task 2: `InfoView.swift` — static cards (app info, links, licenses, environment)

**Files:**
- Create: `Sources/MacUpdater/InfoView.swift`

- [ ] **Step 1: Create `InfoView.swift` with the 4 static cards**

```swift
import SwiftUI
import MacUpdaterCore

struct InfoView: View {
    var onWegaState: ((WegaState) -> Void)?

    @State private var diagnostics: DiagnosticsResult? = nil

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                appCard
                diagnosticsCard
                licensesCard
                environmentCard
            }
            .padding(16)
        }
        .onAppear {
            onWegaState?(WegaState(pose: .idle, line: "Oto co o sobie wiem."))
            Task { await loadDiagnostics() }
        }
    }

    // MARK: - App card

    private var appCard: some View {
        WegaCard {
            HStack(spacing: 14) {
                WegaIcon(size: 56, radius: 14)
                VStack(alignment: .leading, spacing: 4) {
                    Text("WegaMacUpdater")
                        .font(.system(size: 20, weight: .bold))
                    HStack(spacing: 16) {
                        LabeledValue(label: "Wersja", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                        LabeledValue(label: "Build", value: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—")
                    }
                }
                Spacer()
            }

            Divider().padding(.vertical, 6)

            HStack(spacing: 16) {
                Link("GitHub", destination: URL(string: "https://github.com/DominikSienkiewicz/WegaMacUpdater")!)
                    .font(.system(size: 13))
                Link("Zgłoś błąd", destination: URL(string: "https://github.com/DominikSienkiewicz/WegaMacUpdater/issues")!)
                    .font(.system(size: 13))
            }
        }
    }

    // MARK: - Diagnostics card

    private var diagnosticsCard: some View {
        WegaCard {
            HStack(spacing: 8) {
                Image(systemName: "stethoscope").foregroundStyle(Color.wegaHoney)
                Text("Diagnostyka systemu")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            .padding(.bottom, 6)

            if let d = diagnostics {
                VStack(alignment: .leading, spacing: 8) {
                    DiagRow(label: "Homebrew", value: d.brewVersion, required: true)
                    DiagRow(label: "mas-cli", value: d.masVersion, required: false)
                    DiagRow(label: "Privileged Helper", active: d.helperActive)
                }
            } else {
                HStack { ProgressView().controlSize(.small); Spacer() }
            }
        }
    }

    // MARK: - Licenses card

    private var licensesCard: some View {
        WegaCard {
            HStack(spacing: 8) {
                Image(systemName: "doc.text").foregroundStyle(Color.wegaHoney)
                Text("Zewnętrzne narzędzia")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            .padding(.bottom, 6)

            VStack(alignment: .leading, spacing: 8) {
                LicenseRow(name: "Homebrew", license: "BSD 2-Clause", url: URL(string: "https://brew.sh")!)
                LicenseRow(name: "mas-cli", license: "MIT", url: URL(string: "https://github.com/mas-cli/mas")!)
            }
        }
    }

    // MARK: - Environment card

    private var environmentCard: some View {
        WegaCard {
            HStack(spacing: 8) {
                Image(systemName: "cpu").foregroundStyle(Color.wegaHoney)
                Text("Środowisko")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            .padding(.bottom, 6)

            VStack(alignment: .leading, spacing: 6) {
                LabeledValue(label: "macOS", value: ProcessInfo.processInfo.operatingSystemVersionString)
                LabeledValue(label: "CPU", value: "\(ProcessInfo.processInfo.processorCount) rdzenie · \(Self.cpuArch())")
            }
        }
    }

    // MARK: - Helpers

    private static func cpuArch() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) {
            String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
    }

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
            helperActive: helperActive
        )
    }
}

// MARK: - Supporting types

struct DiagnosticsResult {
    var brewVersion: String?
    var masVersion:  String?
    var helperActive: Bool
}

// MARK: - Sub-views

private struct LabeledValue: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
                .tracking(0.5)
            Text(value)
                .font(.system(size: 12, design: .monospaced))
        }
    }
}

private struct DiagRow: View {
    let label: String
    let required: Bool
    var value: String? = nil
    var active: Bool? = nil

    private var statusColor: Color {
        if let v = value { return v != nil ? .wegaSuccess : (required ? .wegaWarning : .secondary) }
        if let a = active { return a ? .wegaSuccess : .secondary }
        return .secondary
    }

    private var statusText: String {
        if let v = value { return v }
        if let a = active { return a ? "aktywny" : "nieaktywny" }
        return required ? "nie znaleziono" : "niedostępny"
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(statusColor).frame(width: 8, height: 8)
            Text(label).font(.system(size: 12))
            Spacer()
            Text(statusText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }
}

private struct LicenseRow: View {
    let name: String
    let license: String
    let url: URL

    var body: some View {
        HStack(spacing: 8) {
            Text(name).font(.system(size: 12, weight: .medium))
            Text(license)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Link("↗", destination: url)
                .font(.system(size: 12))
        }
    }
}
```

- [ ] **Step 2: Fix `DiagRow` init — the initializer has ambiguity due to two optional parameters**

The `DiagRow` struct has two callers:
- `DiagRow(label: "Homebrew", value: d.brewVersion, required: true)` — passes `value`
- `DiagRow(label: "Privileged Helper", active: d.helperActive)` — passes `active`

The struct as written is correct — Swift allows calling with only some optional-defaulted parameters. Verify the compiler agrees:

```bash
swift build 2>&1 | grep -E "error:|Build complete"
```

Expected: `Build complete!`

---

### Task 3: `MigrationView` — `MigrationConfirmSheet` + `confirmingApp` state + `MigrationRow` rewire

**Files:**
- Modify: `Sources/MacUpdater/MigrationView.swift`

- [ ] **Step 1: Replace `@State private var busy: String?` with `migrating` and add `confirmingApp` and `logLines`**

In `MigrationView`, replace:

```swift
@State private var busy:       String?
```

with:

```swift
@State private var migrating:      String?
@State private var confirmingApp:  ApplicationInfo? = nil
@State private var logLines:       [String]          = []
```

- [ ] **Step 2: Update `matchable` computed property to use `migrating` instead of `busy`**

`matchable` itself doesn't reference `busy`. But `MigrationRow` passes `isBusy: busy == app.caskToken` — update that reference in `resultsView` to use `migrating`:

In `resultsView`, find:

```swift
MigrationRow(
    app:      app,
    isBusy:   busy == app.caskToken,
    onMigrate: { Task { await migrate(app) } }
)
```

Replace with:

```swift
MigrationRow(
    app:      app,
    isBusy:   migrating == app.caskToken,
    onMigrate: { confirmingApp = app }
)
```

- [ ] **Step 3: Add `.sheet(item: $confirmingApp)` to `resultsView`**

`resultsView` is a computed var returning `some View`. The `.sheet` modifier must be on the outermost view. Change the return to:

```swift
private var resultsView: some View {
    ScrollView {
        VStack(spacing: 14) {
            // ... existing content unchanged ...
        }
        .padding(16)
    }
    .sheet(item: $confirmingApp) { app in
        MigrationConfirmSheet(app: app) {
            confirmingApp = nil
            Task { await migrate(app) }
        }
    }
}
```

- [ ] **Step 4: Add `MigrationConfirmSheet` private struct at the bottom of `MigrationView.swift`**

After the `AppStoreMigrationRow` struct, add:

```swift
private struct MigrationConfirmSheet: View {
    let app: ApplicationInfo
    let onConfirm: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                PackageLetterIcon(name: app.name, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Migracja do Homebrew")
                        .font(.system(size: 16, weight: .bold))
                    Text(app.name)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }

            if let token = app.caskToken {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Polecenie:")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    Text("brew install --cask \(token)")
                        .font(.system(size: 12, design: .monospaced))
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                }
            }

            Text("Homebrew pobierze najnowszą wersję i zastąpi aktualną instalację w /Applications. Zamknij aplikację przed kontynuowaniem.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Anuluj") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Migruj") {
                    onConfirm()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(Color.wegaHoney)
                .foregroundStyle(Color(red: 0.16, green: 0.11, blue: 0.07))
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}
```

- [ ] **Step 5: Verify build**

```bash
swift build 2>&1 | grep -E "error:|Build complete"
```

Expected: `Build complete!`

---

### Task 4: `MigrationView` — real `migrate()` with `BrewService.events()` streaming

**Files:**
- Modify: `Sources/MacUpdater/MigrationView.swift`

- [ ] **Step 1: Replace the stub `migrate()` with the real streaming implementation**

Replace the current `migrate(_ app:)` function (lines 274–285 in the original file, now adjusted after previous tasks):

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

- [ ] **Step 2: Verify `BrewService.events(arguments:)` exists and has the right signature**

```bash
grep -n "func events" /Users/dominiksienkiewicz/Dev/Projects/public/WegaMacUpdater/Sources/MacUpdaterCore/BrewService.swift
```

Expected output should show a function returning `AsyncThrowingStream<ProcessOutputEvent, Error>` or similar. If it exists, proceed. If not, stop and report BLOCKED.

- [ ] **Step 3: Verify build**

```bash
swift build 2>&1 | grep -E "error:|Build complete"
```

Expected: `Build complete!`

---

### Task 5: `MigrationView` — `MigrationLogView` inline log panel with auto-scroll

**Files:**
- Modify: `Sources/MacUpdater/MigrationView.swift`

- [ ] **Step 1: Add `MigrationLogView` private struct at the bottom of `MigrationView.swift`**

After `MigrationConfirmSheet`, add:

```swift
private struct MigrationLogView: View {
    let logLines:  [String]
    let migrating: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Log migracji")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                if migrating != nil {
                    ProgressView().controlSize(.mini)
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.6))

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(logLines.enumerated()), id: \.offset) { idx, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Color.white.opacity(0.85))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(idx)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
                .frame(height: min(CGFloat(logLines.count) * 18 + 32, 280))
                .onChange(of: logLines.count) { _, count in
                    if count > 0 {
                        proxy.scrollTo(count - 1, anchor: .bottom)
                    }
                }
            }
        }
        .background(Color.black.opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
```

- [ ] **Step 2: Insert `MigrationLogView` into `resultsView`**

In `resultsView`, between the "Można przepiąć pod Homebrew" card and the App Store candidates card, insert the log panel conditionally:

```swift
// Log panel — shown during and after migration until success clears logLines
if !logLines.isEmpty || migrating != nil {
    MigrationLogView(logLines: logLines, migrating: migrating)
}
```

The insertion point is after the closing brace of the Homebrew section `WegaCard`, before the `if !masCandidates.isEmpty` block.

- [ ] **Step 3: Verify build**

```bash
swift build 2>&1 | grep -E "error:|Build complete"
```

Expected: `Build complete!`

---

### Task 6: README update

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update the Status section to reflect the new features**

In `README.md`, update the Status bullet list to include:

- Migration now shows a confirmation sheet with the exact `brew install --cask <token>` command before executing. After confirmation, installation runs with a live streaming log panel showing brew output in real time.
- A new **Info** tab shows app version/build, GitHub links, system diagnostics (Homebrew version, mas-cli version, Privileged Helper status), external tool licenses, and macOS/CPU environment info.

The updated Status section should read:

```markdown
## Status

This repository currently contains the first buildable Swift foundation:

- `WegaMacUpdater` SwiftUI shell with Dashboard, Update, Uninstall, Migration, Inventory, and Info views.
- `MacUpdaterCore` for process execution, Homebrew/MAS parsing, app scanning, cask matching, stale cask detection, and helper path validation.
- Inventory marks apps as `Brew`, `App Store`, or `Manual`. App Store apps are detected via `Contents/_MASReceipt/receipt`. App Store IDs are populated via `mas list` (requires optional `mas` install).
- Migration scans non-Homebrew, non-App Store apps for migration candidates. It checks Homebrew Cask availability and uses `mas search` in parallel to find Mac App Store equivalents (requires optional `mas` install and network access). Homebrew migration shows a confirmation dialog with the exact command before executing, and streams live brew output into an inline log panel. On success, the app moves to the "migrated" set.
- Info tab displays app version, GitHub and issue-tracker links, real-time system diagnostics (Homebrew version, mas-cli version, Privileged Helper presence), external tool licenses (Homebrew BSD 2-Clause, mas-cli MIT), and the current macOS version and CPU architecture.
- `MacUpdaterHelperClient` for `SMAppService` helper status and registration.
- `WegaMacUpdaterPrivilegedHelper` placeholder executable for the future signed LaunchDaemon/XPC helper.
- `MacUpdaterTests` with fixture-based parser and validation tests.
```

- [ ] **Step 2: Verify file looks correct**

Read `README.md` to confirm the edit is clean. No further action needed.

---

## Self-Review

**Spec coverage:**

| Spec requirement | Task covering it |
|---|---|
| `confirmingApp: ApplicationInfo?` state | Task 3 Step 1 |
| `migrating: String?` replaces `busy` | Task 3 Step 1–2 |
| `MigrationRow` triggers sheet instead of direct `migrate()` | Task 3 Step 2 |
| `MigrationConfirmSheet` with `PackageLetterIcon`, command block, description, Cancel/Migruj | Task 3 Step 4 |
| `.sheet(item: $confirmingApp)` on resultsView | Task 3 Step 3 |
| Real `migrate()` with `BrewService.events(["install","--cask",token])` | Task 4 Step 1 |
| `logLines` append + 200-line cap + `MainActor.run` | Task 4 Step 1 |
| Success: `migrated.insert` + clear logLines + banner + WegaState happy | Task 4 Step 1 |
| Failure: `errorMessage` + WegaState sad | Task 4 Step 1 |
| `MigrationLogView` with `ScrollViewReader` auto-scroll | Task 5 Step 1 |
| Log panel shown when `!logLines.isEmpty || migrating != nil` | Task 5 Step 2 |
| Log: monospace 11pt, dark background, white text | Task 5 Step 1 |
| Log: `ProgressView` in header when `migrating != nil` | Task 5 Step 1 |
| Log: height `min(count * 18 + 32, 280)` | Task 5 Step 1 |
| `.info` case in `SidebarTab` | Task 1 Step 1 |
| Sidebar: ForEach for 4 main tabs + Divider + Info row at bottom | Task 1 Step 2 |
| `ContentArea` switch: `.info → InfoView` | Task 1 Step 3 |
| `WegaState.forTab(.info)` | Task 1 Step 4 |
| `InfoView`: app name, version, build from Bundle | Task 2 Step 1 |
| `InfoView`: GitHub + issue links | Task 2 Step 1 |
| `InfoView`: async diagnostics (brew version, mas version, helper active) | Task 2 Step 1 |
| `InfoView`: licenses card (Homebrew BSD 2-Clause, mas-cli MIT) | Task 2 Step 1 |
| `InfoView`: environment card (macOS, CPU count + arch) | Task 2 Step 1 |
| `cpuArch()` via `utsname` / `uname(3)` | Task 2 Step 1 |
| `DiagnosticsResult` struct | Task 2 Step 1 |
| README updated | Task 6 |

**Placeholder scan:** No TBDs or TODOs found.

**Type consistency:** 
- `ApplicationInfo` used identically across all tasks (`item: $confirmingApp` requires `Identifiable` — `ApplicationInfo` already conforms per existing codebase)
- `logLines: [String]` and `migrating: String?` consistent across Task 3–5
- `DiagnosticsResult` defined in Task 2 and only used in Task 2
- `MigrationConfirmSheet(app:onConfirm:)` defined Task 3, referenced in Task 3
- `MigrationLogView(logLines:migrating:)` defined Task 5, referenced in Task 5
