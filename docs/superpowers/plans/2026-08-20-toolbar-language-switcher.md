# Toolbar Language Switcher Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Put a language switcher in the main window's toolbar, so changing the interface language no longer requires finding it inside the Settings window.

**Architecture:** One new `ToolbarItem` in the detail column of `ContentView` — a `Menu` labelled with the `globe` SF Symbol, holding an inline `Picker` bound to `$localization.language`. It drives the same `LocalizationManager` publisher the existing Settings card drives, so no new state is introduced and the existing `.id(localization.language)` at the scene root already rebuilds the view tree on change.

**Tech Stack:** Swift 6, SwiftUI (macOS 26 SDK), SwiftPM, XCTest, SwiftLint.

**Spec:** `docs/superpowers/specs/2026-08-20-toolbar-language-switcher-design.md`

## Global Constraints

- Never work on `main`. This plan is executed on branch `feat/toolbar-language-switcher-2026-08-20`, in the worktree `.worktrees/language-switcher`.
- No new translation keys. `"Język interfejsu"` already exists in `Sources/MacUpdaterCore/Translations.swift` as `"Interface language"`. Every user-visible string goes through `tr(...)`.
- Every icon-only toolbar control must carry BOTH `.help(tr(...))` and a matching `.accessibilityLabel(tr(...))`. `ToolbarIconAccessibilityTests` counts the two and fails when they diverge.
- SwiftLint runs in `--strict` mode: warnings fail. Line length warns at 360 characters.
- The Settings card `languageCard` in `Sources/MacUpdater/InfoView.swift` STAYS. Do not delete or move it.
- Do not touch `showInspector`. Its reset on a language switch is a known, accepted consequence recorded in the spec, explicitly out of scope.
- Per the repository's AGENTS.md, full test suites are opt-in. This plan runs only the filtered `ToolbarIconAccessibilityTests` plus `swift build` and `swiftlint`. Do not run `./scripts/check.sh` or a bare `swift test` unless the user asks.

---

### Task 1: Globe language menu in the main window toolbar

**Files:**
- Modify: `Sources/MacUpdater/ContentView.swift` — property block around line 46, toolbar block at lines 111-129
- Modify: `Tests/MacUpdaterUITests/ToolbarIconAccessibilityTests.swift` — append one test case before the private `source(_:)` helper
- Modify: `USER_GUIDE.md:14-17` — the "Language" callout

**Interfaces:**
- Consumes: `LocalizationManager` (from `Sources/MacUpdater/Localization.swift`) — a `@MainActor ObservableObject` with `@Published public var language: AppLanguage`. Already injected into `ContentView` at `MacUpdaterApp.swift:31`; `ContentView` merely needs to declare it. `AppLanguage` (from `MacUpdaterCore`) — `CaseIterable, Identifiable` enum with `displayName: String` and `flag: String`. `MacUpdaterCore` is already imported at `ContentView.swift:2`.
- Produces: nothing other tasks depend on. This is the only task.

- [ ] **Step 1: Write the failing test**

Open `Tests/MacUpdaterUITests/ToolbarIconAccessibilityTests.swift`. Insert this method after `testEveryHelpOnlyToolbarIconAlsoCarriesAnAccessibilityLabel()` and before the `private func source(...)` helper:

```swift
    /// The language switcher used to live only in the Settings window, three cards down behind
    /// the gear icon. A user who cannot read the interface cannot read their way to it either —
    /// so the main window's toolbar carries a `globe` menu, an icon that needs no translation.
    ///
    /// Source inspection, like its neighbours: a package test target cannot drive
    /// `XCUIApplication`, so the SwiftUI wiring is pinned here instead.
    func testToolbarCarriesAGlobeLanguageMenu() throws {
        let content = try source("Sources/MacUpdater/ContentView.swift")
        XCTAssertTrue(
            content.contains(#"Image(systemName: "globe")"#),
            "The main window's toolbar must offer a globe control for switching language."
        )
        XCTAssertTrue(
            content.contains("selection: $localization.language"),
            "The globe menu must drive LocalizationManager.language, not a local copy of it."
        )
        XCTAssertTrue(
            content.contains(#".accessibilityLabel(tr("Język interfejsu"))"#),
            "The globe icon must spell its name for VoiceOver, not only .help()."
        )
    }
```

- [ ] **Step 2: Run the test and verify it fails**

Run:

```bash
swift test --filter ToolbarIconAccessibilityTests.testToolbarCarriesAGlobeLanguageMenu
```

Expected: FAIL on the first assertion — "The main window's toolbar must offer a globe control for switching language." `ContentView.swift` contains no `globe` symbol today; its toolbar has only `ScanControl`, the `gearshape` `SettingsLink` and the `sidebar.trailing` inspector toggle.

- [ ] **Step 3: Declare the localization manager on `ContentView`**

In `Sources/MacUpdater/ContentView.swift`, in the property block of `struct ContentView`, immediately after the `legacyTab` declaration:

```swift
    /// The pre-macOS-26 key. Read once by `migrateLegacyTab()`, then cleared.
    @AppStorage("wega.activeTab") private var legacyTab: String = ""

    /// Drives the toolbar's globe menu. Injected at the scene root (`MacUpdaterApp.swift`),
    /// which also re-keys this tree on change — so the switch takes effect everywhere at once.
    @EnvironmentObject private var localization: LocalizationManager
```

- [ ] **Step 4: Add the toolbar item**

In the same file, inside `.toolbar { ... }`, insert a new `ToolbarItem` between the existing `ToolbarSpacer(.fixed)` and the `ToolbarItem` holding the `SettingsLink`. The result reads:

```swift
                ToolbarSpacer(.fixed)
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Picker(tr("Język interfejsu"), selection: $localization.language) {
                            ForEach(AppLanguage.allCases) { lang in
                                Text("\(lang.flag)  \(lang.displayName)").tag(lang)
                            }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Image(systemName: "globe")
                    }
                    .help(tr("Język interfejsu"))
                    .accessibilityLabel(tr("Język interfejsu"))
                }
                ToolbarItem(placement: .primaryAction) {
                    SettingsLink { Image(systemName: "gearshape") }
                        .help(tr("Ustawienia"))
                        .accessibilityLabel(tr("Ustawienia"))
                }
```

The globe sits after the spacer on purpose: the toolbar then reads as "scan action | window settings", and the globe never looks like part of the scan control. The `Picker` label is left visible — an inline picker inside a `Menu` renders it as the section header, which tells the user what the two flags are for.

- [ ] **Step 5: Run the test and verify it passes**

Run:

```bash
swift test --filter ToolbarIconAccessibilityTests
```

Expected: PASS — all four tests in the class, including the pre-existing `.help(` / `.accessibilityLabel(` balance count, which now sees one more of each.

- [ ] **Step 6: Build and lint**

Run:

```bash
swift build && swiftlint lint --strict
```

Expected: build succeeds, zero lint violations. If `swiftlint` reports that it cannot load SourceKit, `xcode-select -p` is pointing at the Command Line Tools rather than `Xcode.app` — report that rather than skipping the lint gate.

- [ ] **Step 7: Update the user guide**

`USER_GUIDE.md` currently sends the reader to the Settings window as the only route. Replace the sentence at `USER_GUIDE.md:14-17` so it names the toolbar first:

```markdown
> **Language.** Wega ships in **Polski** and **English**. On first launch it follows your
> macOS language; you can switch it any time from the **globe** button in the main window's
> toolbar, or in the **Settings** window (**⌘,** → *Language*). The menu and button names in
> this guide are given by what they do — your app may show them in Polish.
```

- [ ] **Step 8: Commit**

```bash
git add Sources/MacUpdater/ContentView.swift Tests/MacUpdaterUITests/ToolbarIconAccessibilityTests.swift USER_GUIDE.md
git commit -m "feat(ui): offer the language switcher from the main window toolbar"
```

---

## Verification still outstanding after this plan

- **Visual check.** No automated test renders the toolbar. Launch the app, confirm the globe appears between the scan control and the gear, that the menu lists both languages with a checkmark on the active one, and that picking the other one flips the whole window immediately.
- **Full suite.** Only `ToolbarIconAccessibilityTests` is run above. `MacUpdaterTests` and the rest of `MacUpdaterUITests` are untouched by this change but unverified; `./scripts/check.sh` runs them along with the bash guards when the user wants the full gate.
