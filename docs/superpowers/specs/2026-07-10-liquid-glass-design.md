# Wega Mac Updater — Liquid Glass redesign

**Date:** 2026-07-10
**Status:** approved design, not yet implemented
**Base:** `main` @ `a598b92`
**Scope:** restyle the existing interface onto macOS 26 Liquid Glass. No new product features.

---

## 1. Goal

Adopt Liquid Glass for the chrome of the existing five-tab window, so the app reads as a
native macOS 26 (Tahoe) application rather than a hand-drawn approximation of one.

Nothing about *what* the app does changes. Scanning, upgrading, migration, uninstall and logs
keep their behaviour. Only the chrome around them — sidebar, toolbar, inspector, footer,
floating elements — is rebuilt.

## 2. Why the chrome must be rewritten, not repainted

Liquid Glass is delivered mainly through native containers. `NavigationSplitView` renders a
glass sidebar, a real `.toolbar` renders glass controls in the unified title bar,
`.inspector()` renders a glass trailing pane, and a `ScrollView` under a toolbar earns the
scroll edge effect.

The current window uses none of them. `ContentView` is
`HStack { SidebarView; Divider(); ContentArea }` inside `.windowStyle(.titleBar)`. The bar
across the top of the content is a plain 44 pt `HStack`, not a toolbar. There is no surface
for the system to treat as chrome.

Painting `.glassEffect()` onto those hand-rolled surfaces was rejected: Apple reserves glass
for the floating-controls layer. Large glass backgrounds produce a material that does not
respond to window motion, has no edge refraction, and drifts out of step with the system.

## 3. Decisions

| # | Decision | Consequence |
|---|---|---|
| D1 | Raise the deployment target to macOS 26 | One visual path, no `if #available`. Drops macOS 14 and 15. |
| D2 | Full native container adoption | `NavigationSplitView` + `.toolbar` + `.inspector()`. Sidebar selection must collapse to one value. |
| D3 | Neutral glass, honey accent | Chrome carries no tint. `wegaHoney` appears only where it means something. |
| D4 | Mascot stays, on glass, event-driven | `WegaSpeechBubble` becomes a floating glass capsule; random-timer quips become state-change quips. |
| D5 | The scan control moves into the toolbar | Prerequisite for the `Sprawdź ↔ Anuluj` morph (§5.1). A genuine behavioural change, not a restyle. |

### D3 in detail

Three tint strategies were mocked at 1:1 scale over the same wallpaper
(`foundations/glass-tint/index.html` in the Claude Design project). Honey-tinted chrome was
rejected on functional, not aesthetic, grounds:

- In dark mode the tint turns the sidebar into an opaque orange slab — glass stops reading as
  glass.
- The selected row is also honey, so it loses contrast against its own tinted background and
  no longer signals position.
- Tinted glass has no stable appearance: it vanishes over warm wallpaper, muddies over cold.

Fully neutral chrome was rejected because it hands selection to the user's system accent, so
the app inherits an arbitrary colour and loses its identity outside icon and mascot.

**Rule: honey fills, caramel writes.** `wegaHoney` (#e8b87a) for fills, selection capsules and
the primary action. `wegaCaramel` (#b07540) for text on light backgrounds.

## 4. Architecture

### 4.1 Sidebar selection

Navigation state is two-dimensional today: `activeTab: SidebarTab` × `updateFilter:
UpdateFilter`. The four top rows share `activeTab == .update` and differ only by filter.
`NavigationSplitView` requires a single `Hashable` selection.

```swift
public enum SidebarSelection: Hashable, Sendable {
    case updates(UpdateFilter)
    case migration, inventory, uninstall, logs
}
```

It lives in `MacUpdaterCore`, alongside the `UpdateFilter` it wraps, because
`Tests/MacUpdaterTests` depends on `MacUpdaterCore` only — the app target is not testable, and
the Sonar gate requires ≥ 80 % coverage on new code.

`filter: UpdateFilter?` is computed in Core, which already owns `UpdateFilter`.

`label`, `hint` and `systemImage` call `tr()`, and `tab: SidebarTab` names a type declared in
`ContentView.swift` — all four live in the app target, so they form an extension declared in
`Sources/MacUpdater`. `WegaState.forTab(_:)` keeps working unchanged.

`@AppStorage` cannot persist an enum with associated values directly; `SidebarSelection`
conforms to `RawRepresentable` with string raw values (`"updates.security"`, `"logs"`, …).

### 4.2 View tree

```swift
NavigationSplitView {
    List(selection: $selection) { /* three sections, as today */ }
        .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 300)
} detail: {
    DetailColumn(selection: selection)
        .navigationTitle(selection.label)
        .navigationSubtitle(selection.hint)
        .toolbar {
            ToolbarItem { ScanControl(namespace: glass) }   // morphs, see §5.1
            ToolbarSpacer(.fixed)
            ToolbarItem { SettingsLink { Image(systemName: "gearshape") } }
        }
        .inspector(isPresented: $showInspector) { InspectorPane(update: inspected) }
        .safeAreaInset(edge: .top) { Banners() }
        .safeAreaInset(edge: .bottom) { StatusFooter(…) }
}
```

### 4.3 What the system now owns

Deleted, because a native container does it better: `SidebarItemRow` and its manual hover and
selection fills; the 44 pt `HStack` that imitated a toolbar (`.navigationTitle` /
`.navigationSubtitle` carry exactly the `label` and `hint` it displayed); the `Divider()`
between the columns; `WegaLayout.sidebarWidth`.

### 4.4 Opaque backgrounds must go

`ContentView.swift:111` sets `.background(Color(NSColor.windowBackgroundColor))` on the whole
window. While that is present, every glass surface beneath it refracts an opaque rectangle and
the material is invisible. The same applies to the sidebar's
`Color(NSColor.windowBackgroundColor).opacity(0.6)` (`:272`) and to the
`Color.wegaHoney.opacity(0.02)` washes on the toolbar strip (`:565`), the footer (`:681`) and
`InspectorPane.swift:45`.

Those washes must also go for accessibility: system glass degrades automatically under
*Reduce Transparency* and *Increase Contrast*; hand-rolled opacity does not.

### 4.5 The always-mounted UpdateView is load-bearing

`ContentView` keeps `UpdateView` mounted for the whole session and merely hides it with
`opacity(0)`, rather than swapping it in and out with a `switch`. A `switch` would remove the
view from the tree, tear down its `@State` and orphan any in-flight `Task`, so a running scan
would vanish on every tab change.

Rebuilding the detail column as a `switch` over `SidebarSelection` reintroduces exactly that
bug. **The `ZStack` + `opacity` arrangement must survive the rewrite**, and its explanatory
comment travels with it.

### 4.6 Banners

`BrewInviteCard` and `NotificationExplanationCard` span the full window width above the split
today. That is structurally impossible under `NavigationSplitView` without cutting across the
sidebar and toolbar glass. They move into `.safeAreaInset(edge: .top)` on the detail column:
still above the working UI rather than in front of it, but scoped to the right-hand column.
The sidebar stays clean.

## 5. Glass map

Applied explicitly — everything else inherits from its container:

| Element | Modifier | Rationale |
|---|---|---|
| Toolbar scan control | `GlassEffectContainer` + `.glassEffectID(_:in:)` | Hosts the morph; see §5.1 |
| `WegaSpeechBubble` | `.glassEffect(in: .capsule)` | Already floats (shadow + `controlBackgroundColor`) |
| `StatusFooter` | `.glassEffect()` inside `.safeAreaInset(edge: .bottom)` | Chrome above scrolling content |
| “Zaktualizuj wszystkie/wybrane” | `.buttonStyle(.glassProminent)` + `.tint(.wegaHoney)` | The bulk action, stays in the results top bar |
| `ScrollView` per tab | `.scrollEdgeEffectStyle(.soft, for: .top)` | Content blurs under the toolbar instead of clipping |

**Never glass:** the app cards in `SharedViews`, and the log panel in `LogsView`. These are
content, not chrome; glass on glass double-blurs. The cards' `white.opacity(0.06)` stroke
(`SharedViews.swift:144`) — a hand-drawn imitation of depth — is removed.

### 5.1 The scan control, and why D5 exists

`UpdateView` is a three-state machine (`UpdateView.swift:78–81`): `readyView` shows a large
“Sprawdź aktualizacje” CTA inside `EmptyHero`; `checkingView` shows a `ProgressView` with an
“Anuluj” button beside it (`:114`); `resultsView` shows the list.

Those two buttons live in structurally different views with no common parent, so
`.glassEffectID` cannot morph between them — the API requires both states inside one
`GlassEffectContainer`.

Therefore the **scan lifecycle control moves into the toolbar** as a single `ScanControl`:

- idle → “Sprawdź teraz”
- scanning → progress + “Anuluj”

One control, one container, one namespace: the glass morphs between states instead of jumping.
This is the only justified use of `GlassEffectContainer` in the app.

`readyView`'s hero CTA stays as an empty-state affordance, restyled `.buttonStyle(.glass)` and
demoted to secondary — it now delegates to the same `scan.startCheck()`.

The bulk “Zaktualizuj wszystkie / wybrane” button (`UpdateView.swift:178–183`) is a *different*
action and stays in the results top bar.

### 5.2 Colour tokens

`Color(red: 0.16, green: 0.11, blue: 0.07)` — the ink used on honey fills — is repeated
verbatim **11 times across 7 files**: `ContentView` (×3), `MigrationView` (×3), `UpdateView`
(×2), `SniffingScene`, `UpdateViewSupport`, `UninstallView`. It becomes `Color.wegaInk` in
`WegaTheme`, and all 11 sites are swept. The substitution is mechanical and changes no
rendered colour.

The badge in `SidebarItemRow` (`ContentView.swift:303`) draws `wegaHoney` text on a
`wegaHoney.opacity(0.18)` fill: light on light, already below WCAG contrast in light mode and
worse once glass sits behind it. Per *honey fills, caramel writes* the foreground becomes
`wegaCaramel`.

### 5.3 Mascot

`WegaSpeechBubble` gains glass. Quips fire on state changes — scan finished, updates found,
nothing to do — instead of the random 18–40 s timer at `ContentView.swift:635`.
`SniffingScene` and `PlayfulWega` are untouched.

## 6. Files

| File | Change |
|---|---|
| `Package.swift` | `.macOS(.v14)` → `.macOS("26.0")` — see §6.1 |
| `.github/workflows/ci.yml` | three `runs-on: macos-15` → `macos-26` |
| `Sources/MacUpdaterCore/SidebarSelection.swift` | new — enum, `RawRepresentable`, `@AppStorage` migration |
| `Tests/MacUpdaterTests/SidebarSelectionTests.swift` | new — raw-value round trip, tab/filter mapping, migration |
| `Sources/MacUpdater/ContentView.swift` | rewritten as the `NavigationSplitView` root |
| `Sources/MacUpdater/SidebarList.swift` | new — extracted from `ContentView` |
| `Sources/MacUpdater/DetailColumn.swift` | new — extracted from `ContentView`; owns banners and footer |
| `Sources/MacUpdater/ScanControl.swift` | new — the morphing toolbar control (D5) |
| `Sources/MacUpdater/WegaViews.swift` | receives `WegaSpeechBubble` and `HelperChip` |
| `Sources/MacUpdater/WegaTheme.swift` | `+ Color.wegaInk`, `− WegaLayout.sidebarWidth` |
| `Sources/MacUpdater/UpdateView.swift` | scan control extracted to toolbar; `.scrollEdgeEffectStyle` |
| `Sources/MacUpdater/InspectorPane.swift` | drop the honey wash |
| `Sources/MacUpdater/SharedViews.swift` | drop the card stroke |
| `Sources/MacUpdater/MacUpdaterApp.swift` | `+ .tint(.wegaHoney)` |
| `MigrationView`, `SniffingScene`, `UpdateViewSupport`, `UninstallView` | `Color.wegaInk` substitution only |
| `README.md` | deployment target macOS 14 → 26 |

`ContentView.swift` holds nine types in 684 lines. Since its chrome is rewritten anyway, it is
split along the boundary the rewrite creates. No unrelated file is restructured — the four
files at the bottom of the table receive a token substitution and nothing else.

### 6.1 The platform literal

`.macOS(.v26)` does not compile under this package's `swift-tools-version: 6.0` — the manifest
fails with `error: 'v26' is unavailable`. The `.v26` case is gated behind a newer tools
version.

Use the string form, which `swift package describe` accepts unchanged at tools 6.0:

```swift
platforms: [ .macOS("26.0") ]
```

Raising `swift-tools-version` to unlock `.v26` is the alternative. It is rejected here: the
tools-version bump changes manifest and build semantics across the whole package for no gain
beyond one enum case.

## 7. Risks

1. **Background scan regresses.** The natural `NavigationSplitView` rewrite drives the detail
   column toward a `switch` over the selection, which is precisely the bug §4.5 describes.
   Mitigation: keep `ZStack` + `opacity`; carry the comment across.
2. **The persisted tab is lost.** `@AppStorage("wega.activeTab")` no longer matches the new
   enum. Mitigation: a one-shot migration that reads the old key, maps it, clears it. It lives
   in Core and is covered by a test.
3. **D5 changes behaviour, not just looks.** Moving the scan control into the toolbar means it
   is reachable from every tab, not only Updates. That is an improvement, but it is a change,
   and `readyView` / `checkingView` lose their buttons.
4. **macOS 14 and 15 are dropped.** Accepted under D1. README and CI must say so consistently.
5. **`swiftlint --strict`** treats warnings as errors; new files must be clean.

## 8. Testing

The SwiftUI layer is not unit-tested in this project and this change does not set out to make
it so — that is separate work.

What is testable, and is what can break silently, is `SidebarSelection`: raw-value round trip,
exhaustive mapping onto `SidebarTab` and `UpdateFilter`, and the `@AppStorage` migration. Per
the project's test-first rule these tests are written before the enum and must fail first.

Gate: `scripts/check.sh` — `swift build`, `swift test`, `swiftlint lint --strict`.

Visual verification is a build running on macOS 26. The HTML mock-ups approximate layout,
hierarchy and tint; they cannot approximate the material — CSS `backdrop-filter` has no edge
refraction, no specular response to window motion, and no adaptive contrast.

## 9. Non-goals

- No new product features. Scanning, upgrading, migration, uninstall and logs keep their logic.
- No unit tests for the SwiftUI layer.
- No restructuring outside the files listed in §6.
- No Liquid Glass on the content layer.
