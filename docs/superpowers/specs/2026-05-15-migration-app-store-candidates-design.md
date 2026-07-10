# Design: Migration View — App Store Candidates

**Date:** 2026-05-15
**Status:** Approved

## Problem

The Migration view currently finds only apps that can be migrated to Homebrew. Manually-installed apps that have an equivalent in the Mac App Store are shown in the "no Homebrew match" section with no actionable guidance. Users have no way to discover that these apps could be managed via the App Store instead.

## Goal

When the Migration view scans non-Homebrew apps, also identify which ones have an App Store equivalent via `mas search`, and present them in a dedicated section with a direct "Open in App Store" action.

## Non-Goals

- Fuzzy/partial name matching (only exact normalized match)
- Automatically installing or replacing apps via `mas install`
- Caching search results between scans
- Per-app progress indicators

## Detection Method

For each manually-installed app that:
- is NOT managed by Homebrew (`isManagedByBrew == false`)
- is NOT already in the App Store (`isManagedByMas == false`)
- has no Homebrew cask match (`caskToken == nil`)

…run `mas search <appName>` and compare results using `StringNormalizer.normalize()`. If any result name matches the local app name exactly (after normalization), that result's App Store ID becomes the migration candidate. Take the first matching result only.

Apps with `isManagedByMas == true` are excluded from migration candidates entirely — they are already App Store managed.

## Architecture

### New: `MasSearchParser`

Location: `Sources/MacUpdaterCore/MasSearchParser.swift`

Parses `mas search` output. Format: `  123456789  App Name    1.0.0`

```swift
public struct MasSearchResult: Equatable, Sendable {
    public let appStoreID: String
    public let name: String
}

public struct MasSearchParser {
    public func parse(_ output: String) -> [MasSearchResult]
    // Regex: ^\s*(\d+)\s+(.+?)\s{2,}\S.*$
    // Returns list of (id, name) pairs
}
```

### Extended: `MasService`

New method added to existing `MasService`:

```swift
public func search(name: String) async throws -> String?
// Runs: mas search <name>
// Parses with MasSearchParser
// Returns first result whose normalize(name) == normalize(query), or nil
```

### Modified: `MigrationView.scan()`

New filtering logic:

```swift
let nonBrew = all.filter { !$0.isManagedByBrew && !$0.isManagedByMas }
let brewCandidates = nonBrew.filter { $0.caskToken != nil }
let toSearch = nonBrew.filter { $0.caskToken == nil }

// Parallel App Store search
var masCandidates: [(app: ApplicationInfo, masID: String)] = []
var unmatched: [ApplicationInfo] = []

await withTaskGroup(of: (ApplicationInfo, String?).self) { group in
    for app in toSearch {
        group.addTask {
            let id = try? await model.masService.search(name: app.name)
            return (app, id)
        }
    }
    for await (app, id) in group {
        if let id { masCandidates.append((app, id)) }
        else { unmatched.append(app) }
    }
}
```

State properties added to `MigrationView`:
- `@State private var masCandidates: [(app: ApplicationInfo, masID: String)] = []`

### Modified: `MigrationView` UI

Three sections (order: Homebrew → App Store → Unmatched):

**Existing section:** "Można przepiąć pod Homebrew" — unchanged

**New section:** "Można przenieść do App Store"
- Shown only if `masCandidates` is non-empty
- Each row: app name + `WegaBadge(label: masID, variant: .appStore)` + button "Otwórz w App Store"
- Button action: `NSWorkspace.shared.open(URL(string: "macappstore://apps.apple.com/app/id\(masID)")!)`

**Existing section:** "Bez odpowiednika" — now only shows apps with no brew AND no MAS match

### `migrate()` stub

The existing `migrate()` function is for Homebrew migration. No equivalent is added for App Store — the action is "Open in App Store" (user completes migration manually). No stub needed.

## Error Handling

| Scenario | Behavior |
|---|---|
| `mas` not installed | `search()` throws → TaskGroup treats as nil → app goes to Unmatched |
| No internet connection | `mas search` returns empty output → nil → app goes to Unmatched |
| Timeout / process error | Caught by try? → nil → app goes to Unmatched |
| Multiple exact matches | First match wins |
| Zero candidates to search | TaskGroup not started |

## Tests

### `MasSearchParserTests`
- Parses valid line: returns correct ID and name
- No match when name differs: returns empty
- Multiple results: returns all, caller filters
- Malformed lines: skipped gracefully

### `MasServiceSearchTests`
- Correct match: `StubProcessRunner` returns fixture with matching app → returns ID
- No match: fixture has no matching name → returns nil
- Empty output: returns nil

### `MigrationViewScanTests` (if feasible with current test setup)
- Apps with `isManagedByMas == true` are excluded from toSearch list

## File Changes Summary

| File | Change |
|---|---|
| `Sources/MacUpdaterCore/MasSearchParser.swift` | New file |
| `Sources/MacUpdaterCore/MasService.swift` | Add `search(name:)` method |
| `Sources/MacUpdater/MigrationView.swift` | New filtering logic + new UI section |
| `Tests/MacUpdaterTests/MasSearchParserTests.swift` | New test file |
| `Tests/MacUpdaterTests/Fixtures/mas-search-spotify.txt` | New fixture |
| `Tests/MacUpdaterTests/MasServiceSearchTests.swift` | New test file |

## Implementation Notes

- All changes go directly to the `main` branch (no worktrees)
- `StringNormalizer.normalize()` already exists — reuse for both sides of comparison
- `WegaBadge(label:variant:)` with `.appStore` already exists from previous feature
- `masService` is already injected into the view model — no new DI needed
