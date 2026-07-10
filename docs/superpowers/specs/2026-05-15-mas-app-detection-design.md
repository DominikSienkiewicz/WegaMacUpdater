# MAS App Detection & Update Integration

**Date:** 2026-05-15  
**Status:** Approved

## Summary

Detect apps installed from the Mac App Store among "Manual" (non-brew) apps, classify them correctly in the inventory, and surface available updates in the Update view alongside Homebrew casks.

## Decisions

- **Detection signal:** `Contents/_MASReceipt/receipt` file presence — offline, no dependencies, reliable.
- **App Store ID source:** `mas list` output — required for targeted upgrade, optional (graceful degradation if `mas` absent).
- **Priority rule:** Receipt presence wins. If `isManagedByMas == true`, then `isManagedByBrew = false` and `caskToken = nil` regardless of cask candidate match.
- **Approach:** Receipt check in `ApplicationScanner` (synchronous file op), new `MasService.list()` for IDs, correlation in `AppViewModel`.

## Section 1: Data Model

### `ApplicationInfo` — two new fields

```swift
public var isManagedByMas: Bool    // true when _MASReceipt/receipt exists
public var masAppID: String?        // populated from mas list; nil if mas unavailable
```

### New model `MasInstalledApp` in `Models.swift`

```swift
public struct MasInstalledApp: Equatable, Sendable {
    public var appStoreID: String
    public var name: String
    public var bundleIdentifier: String?
    public var version: String?
}
```

### `ManualOutdatedApp.UpdateSource` — new case

```swift
case mas(appStoreID: String)
```

### Priority rule

In `ApplicationScanner.appInfo(for:installedCasks:availableCasks:)`:

```
if hasMasReceipt(at: appURL):
    isManagedByMas = true
    isManagedByBrew = false
    caskToken = nil
```

## Section 2: Services

### `ApplicationScanner`

New private method:

```swift
private func hasMasReceipt(at appURL: URL) -> Bool {
    let receiptURL = appURL
        .appendingPathComponent("Contents")
        .appendingPathComponent("_MASReceipt")
        .appendingPathComponent("receipt")
    return fileManager.fileExists(atPath: receiptURL.path)
}
```

Called synchronously for every app during scan. No new dependencies.

### `MasService.list()`

New method returning all installed MAS apps:

```swift
public func list() async throws -> [MasInstalledApp]
```

- Calls `mas list`
- Parses lines of format: `<id>  <name>  (<version>)`
- Throws `MasServiceError.masNotFound` if `mas` binary absent — caller handles gracefully
- New `MasListParser` (mirrors existing `MasOutdatedParser` pattern)

### `AppViewModel` — correlation

After scanning, ViewModel runs in parallel:
- `masService.list()` — all installed MAS apps with IDs
- `masService.outdated()` — MAS apps with available updates

Correlation key: `bundleIdentifier` (primary), normalized name via `StringNormalizer` (fallback).

For each app with `isManagedByMas == true`:
1. Look up `masAppID` from `list()` result → populate `masAppID`
2. If found in `outdated()` → create `ManualOutdatedApp` with `.mas(appStoreID:)`

If `mas list` throws `masNotFound`: skip ID population, leave `masAppID = nil`. MAS outdated list is empty. No crash.

## Section 3: UI

### `InventoryView`

- Apps with `isManagedByMas == true` → badge "App Store" instead of "Manual"
- Badge shown regardless of whether `masAppID` is populated (receipt is the source of truth)

### `UpdateView`

- MAS apps appear in the same list as brew casks
- Each row shows installed version and available version (same layout as brew items)
- "Update" button → `mas upgrade <appStoreID>`
- "Update All" → `mas upgrade` (no ID = upgrades all MAS outdated)

### Degraded state (no `mas` installed)

When `mas` is unavailable:
- Inventory: "App Store" badges still shown (receipt-based)
- Update view: MAS section shows inline message: "Install `mas` via Homebrew to update App Store apps" — no empty list, no crash

## Testing

- `ApplicationScanner` unit test: mock `FileManager` to return receipt file → verify `isManagedByMas = true`, `isManagedByBrew = false`, `caskToken = nil`
- `MasListParser` unit test: fixture with known `mas list` output → verify parsed `MasInstalledApp` array
- `AppViewModel` integration test: mock `MasService` returning `masNotFound` → verify graceful degradation (no crash, badges still shown)
- Priority rule test: app matches brew cask candidate AND has receipt → verify MAS wins

## Out of Scope

- Purchasing apps from the App Store via the app
- Detecting MAS apps outside `/Applications`
- Per-app `mas upgrade <id>` progress streaming (reuses existing upgrade flow)
