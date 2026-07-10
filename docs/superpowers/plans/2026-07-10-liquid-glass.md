# Liquid Glass Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restyle Wega's existing five-tab window onto macOS 26 Liquid Glass by adopting native SwiftUI containers, without changing what the app does.

**Architecture:** The hand-rolled chrome (`HStack` sidebar, fake 44 pt toolbar, custom footer) is replaced by `NavigationSplitView` + real `.toolbar` + `.inspector()`, which is where the system supplies glass. The two-dimensional navigation state collapses into one `SidebarSelection` enum living in `MacUpdaterCore` so it is unit-testable. Glass is applied by hand only to genuinely floating elements; content surfaces stay opaque.

**Tech Stack:** Swift 6, SwiftUI, SwiftPM (`swift-tools-version: 6.0`), XCTest, SwiftLint.

**Spec:** `docs/superpowers/specs/2026-07-10-liquid-glass-design.md`

## Global Constraints

- Deployment target is `platforms: [ .macOS("26.0") ]`. **Not** `.macOS(.v26)` — that case is unavailable at `swift-tools-version: 6.0` and the manifest fails with `error: 'v26' is unavailable`.
- Every task ends green on `scripts/check.sh` — `swift build`, `swift test`, `swiftlint lint --strict`. SwiftLint runs with `--strict`, so a warning fails the build.
- No `if #available` anywhere. macOS 14 and 15 are dropped deliberately (spec D1).
- New logic that must be tested goes in `Sources/MacUpdaterCore`. `Tests/MacUpdaterTests` depends on `MacUpdaterCore` only; the `WegaMacUpdater` app target is not testable. The Sonar gate requires ≥ 80 % coverage on new code.
- Tests use `XCTest` and `@testable import MacUpdaterCore`, matching `Tests/MacUpdaterTests/AppOriginTests.swift`.
- Commit messages: Conventional Commits, English, no AI attribution of any kind.
- Never glass the content layer. Cards and the log panel stay opaque (spec §5).
- Colour rule: `wegaHoney` fills, `wegaCaramel` writes.
- Building requires full Xcode (`xcode-select -p` must not point at CommandLineTools); `check.sh` fails fast otherwise.

---

## File Structure

| File | Responsibility |
|---|---|
| `Sources/MacUpdaterCore/SidebarSelection.swift` | The single navigation coordinate. Raw-value persistence, legacy migration, filter projection. Pure, testable. |
| `Tests/MacUpdaterTests/SidebarSelectionTests.swift` | Pins round-trip, filter projection and legacy migration. |
| `Sources/MacUpdater/SidebarSelection+UI.swift` | App-target extension: `label`, `hint`, `systemImage`, `tab`. Needs `tr()` and `SidebarTab`. |
| `Sources/MacUpdater/ContentView.swift` | Root only: `NavigationSplitView`, selection state, `@AppStorage` migration. |
| `Sources/MacUpdater/SidebarList.swift` | The `List(selection:)` sidebar with its three sections and badges. |
| `Sources/MacUpdater/DetailColumn.swift` | Detail column: banners, the always-mounted tab body, footer. |
| `Sources/MacUpdater/ScanControl.swift` | The morphing toolbar scan control (spec D5). |
| `Sources/MacUpdater/WegaTheme.swift` | `Color.wegaInk` token. |
| `Sources/MacUpdater/WegaViews.swift` | Receives `WegaSpeechBubble` and `HelperChip` from `ContentView`. |

`ContentView.swift` currently holds nine types in 684 lines. The split above follows the boundary the rewrite already creates; nothing unrelated is restructured.

---

### Task 1: Platform bump

Independent of every other task, and everything else depends on it. Nothing about the UI changes; this only moves the floor.

**Files:**
- Modify: `Package.swift:9`
- Modify: `.github/workflows/ci.yml` (three `runs-on:` lines)
- Modify: `README.md`

**Interfaces:**
- Consumes: nothing.
- Produces: a package whose deployment target is macOS 26, so `glassEffect`, `GlassEffectContainer`, `ToolbarSpacer`, `.buttonStyle(.glass)` and `.scrollEdgeEffectStyle` are available to every later task without availability gates.

- [ ] **Step 1: Confirm the naive form fails, so nobody re-introduces it later**

```bash
sed -i '' 's/\.macOS(\.v14)/.macOS(.v26)/' Package.swift
swift package describe --type json >/dev/null
```

Expected: FAIL — `error: 'v26' is unavailable`.

- [ ] **Step 2: Apply the string form**

Revert the probe and edit `Package.swift:9` so the `platforms` array reads:

```swift
    platforms: [
        .macOS("26.0")
    ],
```

- [ ] **Step 3: Verify the manifest loads and the package still builds**

```bash
swift package describe --type json >/dev/null && echo MANIFEST_OK
swift build
```

Expected: `MANIFEST_OK`, then a clean build.

- [ ] **Step 4: Move CI to a runner that can execute a macOS 26 binary**

In `.github/workflows/ci.yml`, change all three occurrences of `runs-on: macos-15` to `runs-on: macos-26`. Leave `runs-on: ubuntu-latest` alone.

A macOS 15 runner cannot *run* a binary whose deployment target is macOS 26, so `swift test` would fail there even if `swift build` succeeded. `macos-26` has been generally available since 2026-02-26.

- [ ] **Step 5: Update README**

In `README.md`, change the SwiftUI badge text from `SwiftUI-macOS_14%2B` to `SwiftUI-macOS_26%2B`, and update any prose stating the minimum macOS version to 26 (Tahoe).

- [ ] **Step 6: Run the gate**

```bash
./scripts/check.sh
```

Expected: `✅ build + test + lint OK`.

- [ ] **Step 7: Commit**

```bash
git add Package.swift .github/workflows/ci.yml README.md
git commit -m "build: raise the deployment target to macOS 26

Liquid Glass needs macOS 26. The .v26 platform case is unavailable at
swift-tools-version 6.0, so the string literal is used instead. CI moves to the
macos-26 runner because a macOS 15 runner cannot execute the resulting binary."
```

---

### Task 2: `SidebarSelection` in Core

`NavigationSplitView` selects on one `Hashable` value. Today navigation is `activeTab: SidebarTab` × `updateFilter: UpdateFilter`. This task collapses them, in the one place that unit tests can reach.

**Files:**
- Create: `Sources/MacUpdaterCore/SidebarSelection.swift`
- Test: `Tests/MacUpdaterTests/SidebarSelectionTests.swift`

**Interfaces:**
- Consumes: `UpdateFilter` (already public in `Sources/MacUpdaterCore/UpdateFilter.swift`, cases `.all, .apps, .cli, .security`).
- Produces:
  - `public enum SidebarSelection: Hashable, Sendable` with cases `.updates(UpdateFilter)`, `.migration`, `.inventory`, `.uninstall`, `.logs`
  - `public init?(rawValue: String)` / `public var rawValue: String`
  - `public var filter: UpdateFilter?`
  - `public static let `default`: SidebarSelection`
  - `public static func migrating(legacyTab: String?) -> SidebarSelection?`

- [ ] **Step 1: Write the failing tests**

Create `Tests/MacUpdaterTests/SidebarSelectionTests.swift`:

```swift
import XCTest
@testable import MacUpdaterCore

/// `NavigationSplitView` selects on a single value, so the sidebar's two axes — which tab is
/// active, and which category the Updates list is filtered to — collapse into one enum. These
/// tests pin the three things that can break silently: the string round trip that `@AppStorage`
/// depends on, the filter projection the Updates list reads, and the one-shot migration from
/// the pre-macOS-26 `wega.activeTab` key.
final class SidebarSelectionTests: XCTestCase {

    private let everyCase: [SidebarSelection] = [
        .updates(.all), .updates(.apps), .updates(.cli), .updates(.security),
        .migration, .inventory, .uninstall, .logs
    ]

    func testRawValueRoundTripsForEveryCase() {
        for selection in everyCase {
            XCTAssertEqual(
                SidebarSelection(rawValue: selection.rawValue),
                selection,
                "round trip failed for \(selection.rawValue)"
            )
        }
    }

    func testRawValuesAreDistinct() {
        let raws = everyCase.map(\.rawValue)
        XCTAssertEqual(Set(raws).count, everyCase.count, "two cases share a raw value: \(raws)")
    }

    func testUnknownRawValueIsRejected() {
        XCTAssertNil(SidebarSelection(rawValue: "updates"))
        XCTAssertNil(SidebarSelection(rawValue: "updates.everything"))
        XCTAssertNil(SidebarSelection(rawValue: ""))
    }

    func testFilterIsPresentOnlyForUpdates() {
        XCTAssertEqual(SidebarSelection.updates(.security).filter, .security)
        XCTAssertEqual(SidebarSelection.updates(.all).filter, .all)
        XCTAssertNil(SidebarSelection.logs.filter)
        XCTAssertNil(SidebarSelection.migration.filter)
        XCTAssertNil(SidebarSelection.inventory.filter)
        XCTAssertNil(SidebarSelection.uninstall.filter)
    }

    func testDefaultIsAllUpdates() {
        XCTAssertEqual(SidebarSelection.default, .updates(.all))
    }

    /// The old key stored only the tab, never the filter, so `update` restores the `.all` list.
    func testLegacyTabMigration() {
        XCTAssertEqual(SidebarSelection.migrating(legacyTab: "update"), .updates(.all))
        XCTAssertEqual(SidebarSelection.migrating(legacyTab: "uninstall"), .uninstall)
        XCTAssertEqual(SidebarSelection.migrating(legacyTab: "migration"), .migration)
        XCTAssertEqual(SidebarSelection.migrating(legacyTab: "inventory"), .inventory)
        XCTAssertEqual(SidebarSelection.migrating(legacyTab: "logs"), .logs)
    }

    func testLegacyTabMigrationRejectsUnknownAndNil() {
        XCTAssertNil(SidebarSelection.migrating(legacyTab: "nope"))
        XCTAssertNil(SidebarSelection.migrating(legacyTab: ""))
        XCTAssertNil(SidebarSelection.migrating(legacyTab: nil))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
swift test --filter SidebarSelectionTests
```

Expected: FAIL to compile — `cannot find 'SidebarSelection' in scope`.

- [ ] **Step 3: Write the minimal implementation**

Create `Sources/MacUpdaterCore/SidebarSelection.swift`:

```swift
import Foundation

/// The sidebar's single navigation coordinate.
///
/// The window used to track two independent values: which tab is active, and — for the Updates
/// tab only — which category filter is applied. `NavigationSplitView` selects on one `Hashable`
/// value, so the two axes collapse here.
public enum SidebarSelection: Hashable, Sendable {
    case updates(UpdateFilter)
    case migration
    case inventory
    case uninstall
    case logs
}

extension SidebarSelection: RawRepresentable {
    public init?(rawValue: String) {
        switch rawValue {
        case "updates.all":      self = .updates(.all)
        case "updates.apps":     self = .updates(.apps)
        case "updates.cli":      self = .updates(.cli)
        case "updates.security": self = .updates(.security)
        case "migration":        self = .migration
        case "inventory":        self = .inventory
        case "uninstall":        self = .uninstall
        case "logs":             self = .logs
        default:                 return nil
        }
    }

    public var rawValue: String {
        switch self {
        case .updates(.all):      return "updates.all"
        case .updates(.apps):     return "updates.apps"
        case .updates(.cli):      return "updates.cli"
        case .updates(.security): return "updates.security"
        case .migration:          return "migration"
        case .inventory:          return "inventory"
        case .uninstall:          return "uninstall"
        case .logs:               return "logs"
        }
    }
}

public extension SidebarSelection {
    /// The category filter for the Updates list; `nil` on every other destination.
    var filter: UpdateFilter? {
        guard case .updates(let filter) = self else { return nil }
        return filter
    }

    static let `default`: SidebarSelection = .updates(.all)

    /// Maps a pre-macOS-26 `@AppStorage("wega.activeTab")` value onto the new selection.
    /// That key stored only the tab, never the filter, so `update` restores the unfiltered list.
    /// Returns `nil` for an absent or unrecognised value, so the caller falls back to `default`.
    static func migrating(legacyTab: String?) -> SidebarSelection? {
        switch legacyTab {
        case "update":    return .updates(.all)
        case "uninstall": return .uninstall
        case "migration": return .migration
        case "inventory": return .inventory
        case "logs":      return .logs
        default:          return nil
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
swift test --filter SidebarSelectionTests
```

Expected: PASS, 6 tests.

- [ ] **Step 5: Run the gate**

```bash
./scripts/check.sh
```

Expected: `✅ build + test + lint OK`.

- [ ] **Step 6: Commit**

```bash
git add Sources/MacUpdaterCore/SidebarSelection.swift Tests/MacUpdaterTests/SidebarSelectionTests.swift
git commit -m "feat(core): collapse the sidebar's two navigation axes into SidebarSelection

NavigationSplitView selects on one Hashable value, but navigation was tracked as
activeTab x updateFilter. The enum lives in Core so the raw-value round trip and
the legacy wega.activeTab migration are covered by tests; the app target is not
reachable from the test target."
```

---

### Task 3: The `wegaInk` token

Pure substitution, no behaviour change, no test. Doing it before the rewrite means the new chrome is written against the token instead of against a magic triple.

**Files:**
- Modify: `Sources/MacUpdater/WegaTheme.swift`
- Modify: `Sources/MacUpdater/ContentView.swift` (3 sites), `MigrationView.swift` (3), `UpdateView.swift` (2), `SniffingScene.swift` (1), `UpdateViewSupport.swift` (1), `UninstallView.swift` (1)

**Interfaces:**
- Consumes: nothing.
- Produces: `Color.wegaInk` — the dark brown drawn on top of `wegaHoney` fills.

- [ ] **Step 1: Enumerate the sites, so none is missed**

```bash
grep -rn "red: 0.16, green: 0.11, blue: 0.07" Sources/ | wc -l
```

Expected: `11`.

- [ ] **Step 2: Substitute every site**

Do this *before* declaring the token, so the substitution cannot rewrite the declaration into
`static let wegaInk = Color.wegaInk`.

```bash
grep -rl "red: 0.16, green: 0.11, blue: 0.07" Sources/MacUpdater \
  | xargs sed -i '' 's/Color(red: 0\.16, green: 0\.11, blue: 0\.07)/Color.wegaInk/g'
```

- [ ] **Step 3: Declare the token**

In `Sources/MacUpdater/WegaTheme.swift`, inside `extension Color`, directly below `wegaCaramel`:

```swift
    /// Ink drawn on top of `wegaHoney` fills — honey is a light colour, so labels on it must
    /// be dark. Extracted from eleven verbatim copies of the same literal.
    static let wegaInk = Color(red: 0.16, green: 0.11, blue: 0.07)
```

- [ ] **Step 4: Verify no literal survives and nothing else changed**

```bash
grep -rn "red: 0.16, green: 0.11, blue: 0.07" Sources/
```

Expected: exactly one hit — the declaration in `WegaTheme.swift`.

- [ ] **Step 5: Run the gate**

```bash
./scripts/check.sh
```

Expected: `✅ build + test + lint OK`. The rendered colour is unchanged; only the spelling is.

- [ ] **Step 6: Commit**

```bash
git add Sources/MacUpdater
git commit -m "refactor(ui): extract Color.wegaInk from eleven copies of the same literal

Color(red: 0.16, green: 0.11, blue: 0.07) is the ink drawn on honey fills. It was
spelled out verbatim in six files. No rendered colour changes."
```

---

### Task 4a: The sidebar, built but not yet wired

Adds the two files the new sidebar needs. The old chrome still runs; nothing the user sees
changes. This task compiles and ships on its own, so a reviewer can reject the sidebar's shape
without touching the root rewrite in 4b.

**Files:**
- Create: `Sources/MacUpdater/SidebarSelection+UI.swift`
- Create: `Sources/MacUpdater/SidebarList.swift`

**Interfaces:**
- Consumes: `SidebarSelection` (Task 2) — cases, `.filter`. `SidebarTab`, `UpdateActivity`, `tr(_:)`, `Color.wegaHoney/.wegaCaramel/.wegaDanger/.wegaSuccess` — all pre-existing in the app target.
- Produces:
  - `extension SidebarSelection` with `var tab: SidebarTab`, `var label: String`, `var hint: String`, `var systemImage: String`
  - `struct SidebarList: View`, init `(selection: Binding<SidebarSelection>, appsBadge: Int, cliBadge: Int, securityBadge: Int, logsErrorBadge: Int, updateActivity: UpdateActivity)`

- [ ] **Step 1: Add the app-target extension**

`SidebarTab` and `tr()` are declared in the app target, so this cannot live in Core. Create
`Sources/MacUpdater/SidebarSelection+UI.swift`:

```swift
import SwiftUI
import MacUpdaterCore

/// Presentation for `SidebarSelection`. Lives in the app target because `tr()` and `SidebarTab`
/// do; only `filter` could be computed in Core.
extension SidebarSelection {
    /// The legacy tab this selection belongs to. `WegaState.forTab(_:)` still keys off it, and
    /// `UpdateView.onNavigate` still speaks it.
    var tab: SidebarTab {
        switch self {
        case .updates:   return .update
        case .migration: return .migration
        case .inventory: return .inventory
        case .uninstall: return .uninstall
        case .logs:      return .logs
        }
    }

    var label: String {
        switch self {
        case .updates(.all):      return tr("Wszystkie")
        case .updates(.apps):     return tr("Aplikacje")
        case .updates(.cli):      return tr("Narzędzia CLI")
        case .updates(.security): return tr("Poprawki bezp.")
        case .migration:          return tr("Do przepięcia")
        case .inventory:          return tr("Spis aplikacji")
        case .uninstall:          return tr("Odinstaluj aplikacje")
        case .logs:               return tr("Logi")
        }
    }

    /// Shown as `.navigationSubtitle`, where the deleted 44 pt strip showed `SidebarTab.hint`.
    var hint: String { tab.hint }

    var systemImage: String {
        switch self {
        case .updates(.all):      return "arrow.triangle.2.circlepath"
        case .updates(.apps):     return "square.grid.2x2"
        case .updates(.cli):      return "terminal"
        case .updates(.security): return "shield.lefthalf.filled"
        case .migration:          return "arrow.right.doc.on.clipboard"
        case .inventory:          return "tablecells"
        case .uninstall:          return "trash"
        case .logs:               return "doc.text.magnifyingglass"
        }
    }

    /// Widens `UpdateView.onNavigate`'s `SidebarTab` back into a selection.
    static func forTab(_ tab: SidebarTab) -> SidebarSelection {
        switch tab {
        case .update:    return .updates(.all)
        case .uninstall: return .uninstall
        case .migration: return .migration
        case .inventory: return .inventory
        case .logs:      return .logs
        }
    }
}
```

- [ ] **Step 2: Build to confirm it compiles against the real `SidebarTab`**

```bash
swift build
```

Expected: success. If `SidebarTab` is not visible, it is `private` inside `ContentView.swift` —
remove the access modifier so it is internal. Do not move it.

- [ ] **Step 3: Write `SidebarList`**

Create `Sources/MacUpdater/SidebarList.swift`. Row height, hover fill and the selection capsule
now come from `List(selection:)` and the scene `.tint`. Only the badge is ours, and its
foreground becomes `wegaCaramel`: the old `wegaHoney` on `wegaHoney.opacity(0.18)` was light
text on a light fill, below WCAG contrast in light mode and worse with glass behind it.

```swift
import SwiftUI
import MacUpdaterCore

/// The glass sidebar. `NavigationSplitView` supplies the material, the selection capsule and
/// the hover fill; the hand-rolled `SidebarItemRow` that used to draw them is gone.
struct SidebarList: View {
    @Binding var selection: SidebarSelection
    let appsBadge:      Int
    let cliBadge:       Int
    let securityBadge:  Int
    let logsErrorBadge: Int
    let updateActivity: UpdateActivity

    var body: some View {
        List(selection: $selection) {
            Section(tr("Do aktualizacji")) {
                row(.updates(.all),      badge: appsBadge + cliBadge, spins: true)
                row(.updates(.apps),     badge: appsBadge)
                row(.updates(.cli),      badge: cliBadge)
                row(.updates(.security), badge: securityBadge, isDanger: true)
            }
            Section(tr("Zainstalowane")) {
                row(.migration)
                row(.inventory)
            }
            Section(tr("Narzędzia")) {
                row(.uninstall)
                row(.logs, badge: logsErrorBadge, isDanger: true)
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private func row(
        _ item: SidebarSelection,
        badge count: Int = 0,
        isDanger: Bool = false,
        spins: Bool = false
    ) -> some View {
        Label {
            Text(item.label)
        } icon: {
            SidebarRowIcon(
                systemImage: item.systemImage,
                activity:    spins ? updateActivity : .idle,
                isActive:    selection == item
            )
        }
        .badge(count > 0 ? Text(badgeText(count, isDanger: isDanger)) : nil)
        .tag(item)
    }

    private func badgeText(_ count: Int, isDanger: Bool) -> AttributedString {
        var text = AttributedString("\(count)")
        text.foregroundColor = isDanger ? .wegaDanger : .wegaCaramel
        return text
    }
}

/// The Updates icon spins while a scan runs, turns green when it finishes cleanly and red when
/// a source failed. Lifted verbatim from the deleted `SidebarItemRow`.
private struct SidebarRowIcon: View {
    let systemImage: String
    let activity:    UpdateActivity
    let isActive:    Bool

    @State private var rotation: Double = 0

    private var iconColor: Color {
        switch activity {
        case .scanning: return .wegaHoney
        case .success:  return .wegaSuccess
        case .error:    return .wegaDanger
        case .idle:     return isActive ? .wegaHoney : .secondary
        }
    }

    /// Continuous spin while scanning; ease back to rest otherwise.
    private func spin(for activity: UpdateActivity) {
        if activity == .scanning {
            withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) { rotation = 360 }
        } else {
            withAnimation(.easeOut(duration: 0.3)) { rotation = 0 }
        }
    }

    var body: some View {
        Image(systemName: systemImage)
            .foregroundStyle(iconColor)
            .rotationEffect(.degrees(rotation))
            .animation(.easeInOut(duration: 0.25), value: iconColor)
            .onChange(of: activity) { _, new in spin(for: new) }
            .onAppear { spin(for: activity) }
    }
}
```

- [ ] **Step 4: Run the gate**

```bash
./scripts/check.sh
```

Expected: `✅ build + test + lint OK`. Both files compile but nothing references `SidebarList`
yet — that is 4b's job.

- [ ] **Step 5: Commit**

```bash
git add Sources/MacUpdater/SidebarSelection+UI.swift Sources/MacUpdater/SidebarList.swift
git commit -m "feat(ui): add the List-backed sidebar and SidebarSelection presentation

NavigationSplitView supplies the glass, the selection capsule and the hover fill,
so the hand-rolled row that drew them by hand is not carried over. The badge
foreground moves from wegaHoney to wegaCaramel: honey on an 18%-honey fill was
light-on-light, below WCAG contrast before any glass sat behind it.

Not wired into the window yet."
```

---

### Task 4b: Swap the root onto `NavigationSplitView`

The riskiest task in the plan. Two traps, both named in the spec: the opaque window background
must go, and the always-mounted `UpdateView` must stay.

**Files:**
- Create: `Sources/MacUpdater/DetailColumn.swift`
- Modify: `Sources/MacUpdater/ContentView.swift` — reduce to the root; delete `SidebarView`, `SidebarItemRow`, `ContentArea`; move `WegaSpeechBubble`, `HelperChip`, `BrewInviteCard`, `NotificationExplanationCard`, `StatusFooter` out
- Modify: `Sources/MacUpdater/WegaViews.swift` — receive `WegaSpeechBubble` and `HelperChip`
- Modify: `Sources/MacUpdater/WegaTheme.swift` — delete `WegaLayout.sidebarWidth`
- Modify: `Sources/MacUpdater/MacUpdaterApp.swift` — add `.tint(Color.wegaHoney)`

**Interfaces:**
- Consumes: `SidebarList`, `SidebarSelection.forTab(_:)`, `.tab`, `.label`, `.hint`, `.filter` (Task 4a). `SidebarSelection.default`, `.migrating(legacyTab:)` (Task 2).
- Produces: `struct DetailColumn: View` with the eleven bindings listed below. `SidebarTab` and `UpdateActivity` stay in `ContentView.swift`, unchanged.

- [ ] **Step 1: Move the two floating views into `WegaViews.swift`**

Cut `WegaSpeechBubble` and `HelperChip` from `ContentView.swift` and paste them verbatim into
`Sources/MacUpdater/WegaViews.swift`. Change `private struct` to `struct` on both, since they
are now referenced from another file. Do not change their bodies — glass lands on
`WegaSpeechBubble` in Task 6, not here.

- [ ] **Step 2: Write `DetailColumn`, preserving the always-mounted `UpdateView`**

Create `Sources/MacUpdater/DetailColumn.swift`. Move `BrewInviteCard`,
`NotificationExplanationCard` and `StatusFooter` here verbatim from `ContentView.swift`
(keeping them `private struct`), then add:

```swift
import SwiftUI
import MacUpdaterCore

/// The right-hand column: banners, the tab body, the mascot's bubble, and the status footer.
///
/// Extracted from the old `ContentArea`, minus the 44 pt strip that imitated a toolbar —
/// `.navigationTitle` and `.navigationSubtitle` carry its label and hint now.
struct DetailColumn: View {
    let selection: SidebarSelection
    @Binding var wegaState:         WegaState
    @Binding var updateBadge:       Int
    @Binding var updateActivity:    UpdateActivity
    @Binding var logsInitialFilter: LogLevelFilter
    @Binding var logsErrorBadge:    Int
    @Binding var lastCheck:         Date?
    @Binding var securityBadge:     Int
    @Binding var appsBadge:         Int
    @Binding var cliBadge:          Int
    @Binding var brewInstalled:     Bool
    let onNavigate: (SidebarSelection) -> Void

    @State private var quip: String? = nil

    private let quips: [String] = [
        tr("Wszystko pod kontrolą!"),
        tr("Kiedy ostatnio robiłeś backup?"),
        tr("Brew to mój najlepszy przyjaciel."),
        tr("Wącham coś ciekawego…"),
        tr("Dobra robota dzisiaj!"),
        tr("Czy macOS jest aktualny?"),
        tr("Mam oko na ten dysk."),
        tr("Hau! Nowe paczki?"),
        tr("Zostań chwilę, sprawdzam…"),
        tr("Stary cask to zły cask.")
    ]

    var body: some View {
        tabBody
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .top, spacing: 0) { banners }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                StatusFooter(
                    lastCheck:     lastCheck,
                    updateCount:   updateBadge,
                    securityCount: securityBadge
                )
            }
            .overlay(alignment: .bottom) {
                if let quip {
                    WegaSpeechBubble(text: quip)
                        .padding(.bottom, 24)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.88, anchor: .bottom)),
                            removal:   .opacity
                        ))
                }
            }
            .animation(.spring(response: 0.38, dampingFraction: 0.72), value: quip != nil)
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(Double.random(in: 18...40)))
                    withAnimation { quip = quips.randomElement() }
                    try? await Task.sleep(for: .seconds(4.5))
                    withAnimation { quip = nil }
                }
            }
    }

    /// F4 — Homebrew's absence is an invitation, not a wall. The card sits above the working UI
    /// rather than in front of it. It is scoped to this column so it cannot cut across the
    /// sidebar and toolbar glass.
    @ViewBuilder
    private var banners: some View {
        VStack(spacing: 0) {
            if !brewInstalled {
                BrewInviteCard { brewInstalled = BinaryLocator().locateBrew() != nil }
            }
            NotificationExplanationCard()
        }
    }

    // UpdateView stays mounted for the whole session (just hidden when another destination is
    // active) instead of being swapped in/out by the `switch`. A `switch` removes the inactive
    // view from the tree, which tears down its `@State` and orphans any in-flight `Task` — so a
    // running scan would vanish and its results reset on every tab change. Keeping it alive lets
    // the user launch a check, jump elsewhere while it keeps scanning in the background, and
    // come back to the same (still-running or finished) results. The other destinations own no
    // long-running work, so they stay mount-on-demand.
    //
    // This arrangement survived the NavigationSplitView rewrite deliberately. Replacing the
    // ZStack with a `switch` over `selection` reintroduces exactly that bug.
    @ViewBuilder
    private var tabBody: some View {
        ZStack {
            UpdateView(
                onWegaState:   { wegaState = $0 },
                onBadgeChange: { updateBadge = $0 },
                onNavigate:    { tab in
                    if tab == .logs { logsInitialFilter = .errorsOnly; logsErrorBadge = 0 }
                    onNavigate(SidebarSelection.forTab(tab))
                },
                onErrorCount:  { logsErrorBadge = $0 },
                onActivity:    { updateActivity = $0 },
                onFooterInfo:  { lastCheck = $0; securityBadge = $1 },
                updateFilter:  selection.filter ?? .all,
                onCategoryCounts: { appsBadge = $0; cliBadge = $1 }
            )
            .opacity(selection.tab == .update ? 1 : 0)
            .allowsHitTesting(selection.tab == .update)
            .accessibilityHidden(selection.tab != .update)

            if selection.tab != .update {
                switch selection {
                case .updates:
                    EmptyView()   // shown by the always-mounted UpdateView above
                case .uninstall:
                    UninstallView(onWegaState: { wegaState = $0 })
                case .migration:
                    MigrationView(onWegaState: { wegaState = $0 })
                case .inventory:
                    InventoryView(onWegaState: { wegaState = $0 })
                case .logs:
                    LogsView(onWegaState: { wegaState = $0 }, initialFilter: logsInitialFilter)
                        .id(logsInitialFilter)
                }
            }
        }
    }
}
```

- [ ] **Step 3: Rewrite `ContentView` as the root**

Replace the `ContentView` struct in `Sources/MacUpdater/ContentView.swift` with exactly this,
and delete `SidebarView`, `SidebarItemRow` and `ContentArea` from the file. Keep `SidebarTab`
and `UpdateActivity` where they are.

`@AppStorage` accepts `SidebarSelection` directly: Task 2 made it `RawRepresentable` with a
`String` raw value.

```swift
struct ContentView: View {
    /// Persisted so a language switch (which re-keys the view tree) doesn't bounce the user off
    /// their current destination — and the last one is restored on next launch.
    @AppStorage("wega.sidebarSelection") private var selection: SidebarSelection = .default
    /// The pre-macOS-26 key. Read once by `migrateLegacyTab()`, then cleared.
    @AppStorage("wega.activeTab") private var legacyTab: String = ""

    @State private var wegaState:         WegaState       = .forTab(.update)
    @State private var updateBadge:       Int             = 0
    @State private var logsInitialFilter: LogLevelFilter  = .all
    @State private var logsErrorBadge:    Int             = 0
    @State private var updateActivity:    UpdateActivity  = .idle
    /// F4 — informational, not a gate: drives the "install Homebrew" invitation card.
    @State private var brewInstalled: Bool
    @State private var lastCheck:     Date? = nil
    @State private var securityBadge: Int   = 0
    @State private var appsBadge:     Int   = 0
    @State private var cliBadge:      Int   = 0

    init() {
        _brewInstalled = State(initialValue: BinaryLocator().locateBrew() != nil)
    }

    var body: some View {
        NavigationSplitView {
            SidebarList(
                selection:      $selection,
                appsBadge:      appsBadge,
                cliBadge:       cliBadge,
                securityBadge:  securityBadge,
                logsErrorBadge: logsErrorBadge,
                updateActivity: updateActivity
            )
            .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 300)
        } detail: {
            DetailColumn(
                selection:         selection,
                wegaState:         $wegaState,
                updateBadge:       $updateBadge,
                updateActivity:    $updateActivity,
                logsInitialFilter: $logsInitialFilter,
                logsErrorBadge:    $logsErrorBadge,
                lastCheck:         $lastCheck,
                securityBadge:     $securityBadge,
                appsBadge:         $appsBadge,
                cliBadge:          $cliBadge,
                brewInstalled:     $brewInstalled,
                onNavigate:        { selection = $0 }
            )
            .navigationTitle(selection.label)
            .navigationSubtitle(selection.hint)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    SettingsLink { Image(systemName: "gearshape") }
                        .help(tr("Ustawienia"))
                }
            }
        }
        // Deliberately no `.background(...)`. An opaque window background would leave every
        // glass surface beneath it refracting a solid rectangle, and the material would vanish.
        .frame(minWidth: WegaLayout.windowMinWidth, minHeight: WegaLayout.windowMinHeight)
        .onChange(of: selection) { _, new in wegaState = .forTab(new.tab) }
        .task { migrateLegacyTab() }
    }

    /// One-shot migration off `wega.activeTab`, which stored only the tab and never the Updates
    /// filter — so `update` restores the unfiltered list. Unknown or absent values fall through
    /// to the `@AppStorage` default.
    private func migrateLegacyTab() {
        guard !legacyTab.isEmpty else { return }
        if let migrated = SidebarSelection.migrating(legacyTab: legacyTab) {
            selection = migrated
        }
        legacyTab = ""
    }
}
```

- [ ] **Step 4: Delete `WegaLayout.sidebarWidth` and tint the scene**

In `Sources/MacUpdater/WegaTheme.swift`, delete the line `static let sidebarWidth: CGFloat = 240`
— column width is `NavigationSplitView`'s business now. Leave `cardRadius`, `rowRadius`,
`windowMinWidth` and `windowMinHeight`.

In `Sources/MacUpdater/MacUpdaterApp.swift`, add `.tint(Color.wegaHoney)` to the `WindowGroup`
content, directly below `.id(localization.language)`. This is what colours the sidebar's
selection capsule honey instead of the user's system accent.

- [ ] **Step 5: Run the gate**

```bash
./scripts/check.sh
```

Expected: `✅ build + test + lint OK`.

If SwiftLint's `type_body_length` or `file_length` fires on `ContentView.swift`, the deletions
in Step 3 were incomplete — `SidebarView`, `SidebarItemRow` and `ContentArea` must all be gone.
Do not silence the rule.

- [ ] **Step 6: Verify the load-bearing behaviour by hand — this is the point of the task**

Launch the app:

```bash
swift run WegaMacUpdater
```

1. On **Wszystkie**, start a scan. While it runs, click **Logi**, then click back.
   The scan must still be running, or finished. **If it reset, `DetailColumn` lost its
   `ZStack`** — that is the regression this task exists to avoid.
2. Confirm the sidebar is translucent and the wallpaper shifts behind it when you drag the
   window. If it is flat grey, an opaque `.background(...)` survived somewhere.
3. Confirm the window title reads the selection's label and the subtitle reads its hint.
4. Quit and relaunch. The last selection is restored.

- [ ] **Step 7: Commit**

```bash
git add Sources/MacUpdater
git commit -m "feat(ui): rebuild the window chrome on NavigationSplitView

The sidebar, toolbar and column divider were hand-drawn, so the system had no
surface to treat as chrome and no way to supply Liquid Glass. They are replaced by
NavigationSplitView, a real .toolbar, and .navigationTitle/.navigationSubtitle,
which carry exactly the label and hint the 44pt strip displayed.

The opaque window background is removed: it left every glass surface beneath it
refracting a solid rectangle. The always-mounted UpdateView survives the rewrite --
a switch over the selection would tear down its state and kill in-flight scans, so
the ZStack and the comment explaining it both stay.

wega.activeTab migrates once into wega.sidebarSelection."
```

### Task 5: The morphing scan control (spec D5)

`.glassEffectID` can only morph between states that share a `GlassEffectContainer`. The current buttons — “Sprawdź aktualizacje” inside `readyView`'s `EmptyHero`, and “Anuluj” beside `checkingView`'s `ProgressView` — have no common parent. So the scan control moves into the toolbar, where it has one.

This is a behaviour change, not a restyle: the scan becomes reachable from every tab.

**Files:**
- Create: `Sources/MacUpdater/ScanControl.swift`
- Modify: `Sources/MacUpdater/UpdateView.swift` (`readyView` demotes its CTA; `checkingView` loses its cancel button)
- Modify: `Sources/MacUpdater/ContentView.swift` (add the toolbar item)

**Interfaces:**
- Consumes: `ScanStore` — `@Published var status: UpdateStatus` (`.ready`/`.checking`/`.results`), `@Published var progress: ScanProgress?`, `func startCheck()`, `func cancelScan()`. `ScanProgress.fractionCompleted: Double` and `.isCancellable: Bool` are public in `MacUpdaterCore/ScanPhase.swift`.
- Produces: `struct ScanControl: View` — init `(namespace: Namespace.ID)`, reads `ScanStore` from the environment.

- [ ] **Step 1: Write `ScanControl`**

Create `Sources/MacUpdater/ScanControl.swift`:

```swift
import SwiftUI
import MacUpdaterCore

/// The scan lifecycle as one toolbar control.
///
/// `.glassEffectID` morphs glass between states only when both states live inside the same
/// `GlassEffectContainer`. The old buttons sat in `readyView` and `checkingView` — different
/// branches of a `switch`, no common parent — so they could not morph. Hoisting the control
/// into the toolbar gives it one container, one namespace, and the morph for free.
struct ScanControl: View {
    @EnvironmentObject private var scan: ScanStore
    let namespace: Namespace.ID

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            if scan.status == .checking {
                HStack(spacing: 8) {
                    ProgressView(value: scan.progress?.fractionCompleted ?? 0)
                        .progressViewStyle(.linear)
                        .tint(Color.wegaHoney)
                        .frame(width: 90)
                    if scan.progress?.isCancellable == true {
                        Button(tr("Anuluj")) { scan.cancelScan() }
                            .buttonStyle(.glass)
                    }
                }
                .glassEffectID("scan", in: namespace)
            } else {
                Button { scan.startCheck() } label: {
                    Label(tr("Sprawdź teraz"), systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.glassProminent)
                .tint(Color.wegaHoney)
                .foregroundStyle(Color.wegaInk)
                .glassEffectID("scan", in: namespace)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: scan.status)
    }
}
```

- [ ] **Step 2: Mount it in the toolbar**

In `ContentView.swift`, add `@Namespace private var glassNamespace` and extend the `.toolbar`:

```swift
.toolbar {
    ToolbarItem(placement: .primaryAction) {
        ScanControl(namespace: glassNamespace)
    }
    ToolbarSpacer(.fixed)
    ToolbarItem(placement: .primaryAction) {
        SettingsLink { Image(systemName: "gearshape") }
            .help(tr("Ustawienia"))
    }
}
```

- [ ] **Step 3: Demote the hero CTA and remove the duplicate cancel**

In `UpdateView.swift`, `readyView`'s button keeps calling `scan.startCheck()` but becomes secondary:

```swift
                Button { scan.startCheck() } label: {
                    Label(tr("Sprawdź aktualizacje"), systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.glass)
                .controlSize(.large)
```

In `checkingView`, delete the `if scan.progress?.isCancellable == true { Button(tr("Anuluj")) … }` block and its enclosing `HStack` spacing adjustment — the toolbar owns cancellation now. Keep the `ProgressView` and the `phase.commandLabel` line, which report *what* the scan is doing.

- [ ] **Step 4: Run the gate**

```bash
./scripts/check.sh
```

Expected: `✅ build + test + lint OK`.

- [ ] **Step 5: Verify the morph and the reach by hand**

Launch the app. Press **Sprawdź teraz** in the toolbar: the glass capsule must *morph* into the progress + cancel pair, not pop. Switch to **Logi** mid-scan: the toolbar control must still be there and still cancel the scan.

- [ ] **Step 6: Commit**

```bash
git add Sources/MacUpdater
git commit -m "feat(ui): hoist the scan control into the toolbar so its states can morph

glassEffectID morphs only between states sharing a GlassEffectContainer. The check
and cancel buttons lived in different branches of UpdateView's status switch, with
no common parent, so no morph was possible.

One toolbar control now owns the scan lifecycle. Side effect, and an improvement:
a scan can be started and cancelled from every tab, not only from Updates."
```

---

### Task 6: Glass on the floating layer, and the washes removed

Everything the system does not own. Nothing here changes behaviour.

**Files:**
- Modify: `Sources/MacUpdater/WegaViews.swift` (`WegaSpeechBubble`)
- Modify: `Sources/MacUpdater/DetailColumn.swift` (`StatusFooter`)
- Modify: `Sources/MacUpdater/InspectorPane.swift:45`
- Modify: `Sources/MacUpdater/SharedViews.swift:144`
- Modify: `Sources/MacUpdater/UpdateView.swift`, `InventoryView.swift`, `LogsView.swift`, `MigrationView.swift` (scroll edge effect)

**Interfaces:**
- Consumes: nothing new.
- Produces: nothing new. Presentation only.

- [ ] **Step 1: Glass the speech bubble**

In `WegaViews.swift`, replace `WegaSpeechBubble`'s `.background(RoundedRectangle…fill…shadow)` and its `.overlay(…stroke…)` with:

```swift
        .glassEffect(in: .capsule)
```

The shadow and the 12 %-white hairline were a hand-drawn imitation of the depth the material now provides.

- [ ] **Step 2: Glass the footer, drop its wash**

In `DetailColumn.swift`, `StatusFooter` loses `.background(Color.wegaHoney.opacity(0.02))` and its `Divider()` overlay, and gains:

```swift
        .glassEffect()
```

- [ ] **Step 3: Strip the remaining opacity washes**

- `InspectorPane.swift:45` — delete `.background(Color.wegaHoney.opacity(0.02))`. `.inspector()` supplies the surface.
- `SharedViews.swift:144` — delete the `.overlay(RoundedRectangle(cornerRadius: WegaLayout.cardRadius).stroke(Color.white.opacity(0.06), lineWidth: 1))` line. Cards keep their opaque `.background(.background.opacity(0.5))`; they are content, and glass on glass double-blurs.

These washes never degraded under *Reduce Transparency* or *Increase Contrast*. System glass does.

- [ ] **Step 4: Add the scroll edge effect**

On the top-level `ScrollView` in each of `UpdateView.swift`, `InventoryView.swift`, `LogsView.swift`, `MigrationView.swift`:

```swift
        .scrollEdgeEffectStyle(.soft, for: .top)
```

- [ ] **Step 5: Run the gate**

```bash
./scripts/check.sh
```

Expected: `✅ build + test + lint OK`.

- [ ] **Step 6: Verify contrast degradation by hand**

Launch the app. In System Settings → Accessibility → Display, enable **Reduce Transparency**. The sidebar, footer and speech bubble must turn opaque and stay legible. Then enable **Increase Contrast** and confirm the same.

- [ ] **Step 7: Commit**

```bash
git add Sources/MacUpdater
git commit -m "feat(ui): put glass on the floating layer and remove the hand-drawn washes

The speech bubble and status footer genuinely float above content, so they take
glass. Cards and the log panel do not: they are content, and glass on glass
double-blurs.

The 2%-honey washes and the 6%-white card hairline imitated depth the material now
provides, and unlike system glass they never degraded under Reduce Transparency."
```

---

### Task 7: Event-driven quips

The mascot stays (spec D4) but stops interrupting. Today `ContentArea` fires a random line every 18–40 s regardless of what the app is doing.

**Files:**
- Modify: `Sources/MacUpdater/DetailColumn.swift` (the quip `.task` moved here with `ContentArea`)
- Modify: `Sources/MacUpdater/WegaViews.swift`

**Interfaces:**
- Consumes: `ScanStore.status`.
- Produces: nothing new.

- [ ] **Step 1: Delete the timer**

Remove the `.task { while !Task.isCancelled { try? await Task.sleep(for: .seconds(Double.random(in: 18...40))) … } }` block wholesale.

- [ ] **Step 2: Fire on state change instead**

```swift
    .onChange(of: scan.status) { old, new in
        guard old == .checking, new == .results else { return }
        withAnimation { quip = finishedQuip() }
        Task {
            try? await Task.sleep(for: .seconds(4.5))
            withAnimation { quip = nil }
        }
    }
```

```swift
    /// Wega comments on the result, not on the clock.
    private func finishedQuip() -> String {
        if updateBadge == 0      { return tr("Wszystko pod kontrolą!") }
        if securityBadge > 0     { return tr("Znalazłam coś pilnego.") }
        return tr("Hau! Nowe paczki?")
    }
```

Delete the `quips` array; the three lines above replace it. Keep `WegaSpeechBubble`'s existing spring transition.

- [ ] **Step 3: Run the gate**

```bash
./scripts/check.sh
```

Expected: `✅ build + test + lint OK`.

- [ ] **Step 4: Verify by hand**

Launch the app and leave it idle for two minutes. No bubble may appear. Run a scan: exactly one bubble appears when it finishes, and matches the result.

- [ ] **Step 5: Commit**

```bash
git add Sources/MacUpdater
git commit -m "feat(ui): fire Wega's quips on scan results instead of on a random timer

Liquid Glass is built around deference, and a bubble that surfaced every 18-40
seconds regardless of state was the opposite. Wega now comments once, on what the
scan actually found."
```

---

## Self-Review

**Spec coverage.** D1 → Task 1. D2 → Tasks 2 and 4. D3 → Tasks 3, 4 (badge contrast) and 6. D4 → Tasks 6 and 7. D5 → Task 5. §4.4 opaque backgrounds → Tasks 4 and 6. §4.5 always-mounted `UpdateView` → Task 4 steps 5 and 9. §4.6 banners → Task 4 step 5. §5 glass map → Tasks 5 and 6. §5.2 tokens → Task 3. §6.1 platform literal → Task 1. §8 testing → Task 2.

**Gaps accepted.** The spec's `README.md` row is folded into Task 1, which is where the deployment target changes.

**Type consistency.** `SidebarSelection.migrating(legacyTab:)` is named identically in Task 2's implementation, Task 2's tests and Task 4's `migrateLegacyTabIfNeeded`. `SidebarSelection.filter` is produced in Task 2 and consumed in Task 4's `DetailColumn`. `Color.wegaInk` is produced in Task 3 and consumed in Task 5's `ScanControl`. `UpdateActivity` and `SidebarTab` are pre-existing app-target types, unchanged.

**Known unknown.** `ScanControl` reads `ScanStore` via `@EnvironmentObject`; `ScanStore` is currently injected at `MacUpdaterApp` level, so this works — but `UpdateStatus` is declared internal in `ScanStore.swift`, and `ScanControl` compares against it. Both live in the app target, so no access change is needed. If the compiler disagrees, make `UpdateStatus` conform to `Equatable` rather than widening its access.

---

### Task 8: Adopt `.inspector()`, the third native container

Spec decision D2 promises `NavigationSplitView` + `.toolbar` + `.inspector()`. The first two
landed in Tasks 4b and 5. `.inspector()` was silently dropped from this plan's §6, and the
whole-branch review caught it: `InspectorPane` is still an inline 340 pt column inside
`UpdateView`'s `resultsView`, behind a hand-drawn `Divider()` — exactly the content-layer
construction the redesign set out to replace.

Worse, Task 6 deleted `InspectorPane`'s background on the stated grounds that "`.inspector()`
supplies the surface". No `.inspector()` existed. This task makes that comment true.

**Files:**
- Modify: `Sources/MacUpdater/UpdateView.swift` — remove the `HStack` / `Divider()` / fixed-width `InspectorPane`
- Modify: `Sources/MacUpdater/DetailColumn.swift` — attach `.inspector(isPresented:)`
- Modify: `Sources/MacUpdater/ContentView.swift` — own `showInspector`, add the toolbar toggle
- Modify: `Sources/MacUpdaterCore/Translations.swift` — English for the toggle's help string

**Interfaces:**
- Consumes: `ScanStore.inspectedUpdate: InspectedUpdate?`, `.manualBusy: String?`, `.caskDownloads: [String: CaskDownloadInfo]`, `func installManual(token:) async`. `DetailColumn` already holds `@EnvironmentObject private var scan: ScanStore`.
- Produces: nothing new.

- [ ] **Step 1: Strip the inline pane from `resultsView`**

In `Sources/MacUpdater/UpdateView.swift`, replace

```swift
            HStack(spacing: 0) {
                listColumn
                    .frame(maxWidth: .infinity)
                    .layoutPriority(1)
                Divider()
                InspectorPane(
                    update: scan.inspectedUpdate,
                    busyToken: scan.manualBusy,
                    onInstall: { token in Task { await scan.installManual(token: token) } },
                    caskDownloads: scan.caskDownloads
                )
                    .frame(width: 340)
            }
```

with

```swift
            listColumn
                .frame(maxWidth: .infinity)
```

- [ ] **Step 2: Attach the inspector to the detail column**

In `Sources/MacUpdater/DetailColumn.swift`, add a binding and the modifier. The inspector is
only meaningful on the Updates destination — everywhere else `InspectorPane` would show its
"pick an update" empty state, which is nonsense on Logs.

```swift
    @Binding var showInspector: Bool
```

```swift
    /// `.inspector` is attached unconditionally so the detail column is not rebuilt on every
    /// destination change, but it only presents on Updates: `InspectorPane`'s empty state
    /// ("pick an update") is meaningless on Logs or Inventory.
    private var inspectorPresented: Binding<Bool> {
        Binding(
            get: { showInspector && selection.tab == .update },
            set: { showInspector = $0 }
        )
    }
```

and, on the same view the `.safeAreaInset` modifiers hang from:

```swift
            .inspector(isPresented: inspectorPresented) {
                InspectorPane(
                    update: scan.inspectedUpdate,
                    busyToken: scan.manualBusy,
                    onInstall: { token in Task { await scan.installManual(token: token) } },
                    caskDownloads: scan.caskDownloads
                )
                .inspectorColumnWidth(min: 280, ideal: 340, max: 460)
            }
```

- [ ] **Step 3: Own the state and add the toolbar toggle**

In `Sources/MacUpdater/ContentView.swift`:

```swift
    @State private var showInspector: Bool = true
```

Pass `showInspector: $showInspector` to `DetailColumn`. Add to the `.toolbar`, after the
`SettingsLink` item:

```swift
                    ToolbarItem(placement: .primaryAction) {
                        Button { showInspector.toggle() } label: {
                            Image(systemName: "sidebar.trailing")
                        }
                        .help(tr("Panel szczegółów"))
                        .disabled(selection.tab != .update)
                    }
```

- [ ] **Step 4: Add the English translation**

`tr("Panel szczegółów")` is a new string and the `LocalizationCompleteness` test fails without
an English entry. In `Sources/MacUpdaterCore/Translations.swift`, alongside the other UI
strings:

```swift
        "Panel szczegółów": "Details panel",
```

- [ ] **Step 5: Run the gate**

```bash
./scripts/check.sh
```

Expected: `✅ build + test + lint OK`.

- [ ] **Step 6: Verify structurally**

```bash
grep -rn "\.inspector(" Sources/MacUpdater/          # exactly one hit, in DetailColumn.swift
grep -n "InspectorPane(" Sources/MacUpdater/         # exactly one hit, in DetailColumn.swift
grep -n "frame(width: 340)" Sources/MacUpdater/      # zero hits
```

- [ ] **Step 7: Commit**

```bash
git add Sources
git commit -m "feat(ui): move the inspector into the native .inspector() container

Spec D2 promised NavigationSplitView + .toolbar + .inspector(); only the first
two were adopted. InspectorPane remained an inline 340pt column behind a
hand-drawn Divider, and Task 6 had already deleted its background on the false
premise that .inspector() supplied the surface.

The pane now gets the system's glass trailing surface, a resizable column, and a
toolbar toggle. It presents only on Updates, where its empty state makes sense."
```
