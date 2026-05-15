# Wega Mac Updater

macOS-first SwiftUI rewrite of the old TypeScript `mac-updater` CLI.

## Status

This repository currently contains the first buildable Swift foundation:

- `WegaMacUpdater` SwiftUI shell with Update, Uninstall, Migration, Inventory, and Info views.
- `MacUpdaterCore` for process execution, Homebrew/MAS parsing, app scanning, cask matching, stale cask detection, and helper path validation.
- Inventory marks apps as `Brew`, `App Store`, or `Manual`. App Store apps are detected via `Contents/_MASReceipt/receipt`. App Store IDs are populated via `mas list` (requires optional `mas` install).
- Migration scans non-Homebrew, non-App Store apps for migration candidates. It checks Homebrew Cask availability and uses `mas search` in parallel to find Mac App Store equivalents (requires optional `mas` install and network access). Homebrew migration shows a confirmation dialog with the exact `brew install --cask <token>` command before executing, then streams live brew output into an inline log panel. On success the app moves to the migrated set; on failure the log is preserved for inspection.
- Info tab shows app version and build number, GitHub and issue-tracker links, real-time system diagnostics (Homebrew version, mas-cli version, Privileged Helper presence), external tool licenses (Homebrew BSD 2-Clause, mas-cli MIT), and macOS version with CPU architecture.
- `MacUpdaterHelperClient` for `SMAppService` helper status and registration.
- `WegaMacUpdaterPrivilegedHelper` placeholder executable for the future signed LaunchDaemon/XPC helper.
- `MacUpdaterTests` with fixture-based parser and validation tests, including `VersionComparisonTests` covering all version-comparison edge cases.
- `VersionComparison` module in `MacUpdaterCore` provides shared, public functions for version normalization and comparison:
  - `versionsEqual` handles Homebrew comma-format (`5.3.1,50301`), semver `+` build metadata (`0.4.13+1`), parenthesized build numbers (`7.0.0 (77593)`), and trailing-zero padding (`125.0` == `125.0.0`).
  - `isUpgrade` guards against false positives and downgrade reporting using `lexicographicallyPrecedes`.
  - `normalizeGitTag` strips `v`, `V`, `release-` prefixes and `-alpha`/`-beta`/`-build…` suffixes from GitHub release tags.
- `JetBrainsUpdateChecker` in `MacUpdaterCore` detects updates for 14 JetBrains IDEs by querying the JetBrains Data Services API (`data.services.jetbrains.com`). This handles IDEs installed via Toolbox (where `brew outdated` never fires because the cask has `auto_updates: true`). The action in Update view opens JetBrains Toolbox.
- `GitHubReleasesChecker` in `MacUpdaterCore` detects updates for 12 popular open-source apps (VS Code, Obsidian, Rectangle, AltTab, Stats, Maccy, MonitorControl, LinearMouse, IINA, HandBrake, Keka, GitHub Desktop) via the GitHub Releases API. The action in Update view opens the app's GitHub Releases page.
- Update detection source priority: JetBrains (4) > GitHub (3) > Cask (2) > Sparkle (1). When multiple checkers match the same app, the highest-priority source wins to avoid duplicates and prefer the most accurate update path.
- Both GitHub and JetBrains requests use `URLRequest.cachePolicy = .reloadRevalidatingCacheData` to send conditional HTTP headers (`If-None-Match` / `If-Modified-Since`) and avoid redundant transfers on repeated checks.
- Uninstall view supports all app types: Homebrew casks (`brew uninstall --cask`), App Store, and manually installed apps (moved to Trash via `FileManager`). Displays per-row source badges and a confirmation dialog that shows both the brew zap count and the trash count.
- All scan-directory logic (`/Applications`, `~/Applications`, and their immediate non-.app subdirectories) is centralized in the `buildScanDirs()` helper in `SharedViews.swift` and shared by Update, Inventory, Uninstall, and Migration views.
- `ApplicationScanner` reads `Contents/Info.plist` directly via `PropertyListSerialization` instead of `Bundle(url:)` to avoid stale bundle caching after in-place app updates (e.g. JetBrains Toolbox replacing an IDE in-place).

The old `sudo` password storage model is intentionally not ported. Privileged work must go through a signed helper with typed, allowlisted operations.

## Requirements

- macOS 14 or newer.
- Xcode 26 or compatible Swift toolchain.
- Homebrew installed at one of:
  - `/opt/homebrew/bin/brew`
  - `/usr/local/bin/brew`
- Optional `mas` installed at one of:
  - `/opt/homebrew/bin/mas`
  - `/usr/local/bin/mas`

GUI apps do not inherit an interactive shell environment, so the app resolves Homebrew and `mas` through fixed executable paths instead of relying on `.zshrc` or `$PATH`.

## Build And Test

```bash
swift build
swift test
swift run WegaMacUpdater
```

The package can be opened directly in Xcode via `Package.swift`. A dedicated signed `.app`/installer project is still needed before Developer ID distribution and notarization.

## Security Model

- Homebrew commands run as the logged-in user.
- `brew upgrade`, `brew uninstall`, and `mas upgrade` are not run as root.
- The future helper must not expose `runCommand(String)` or any shell-string API.
- Helper operations are constrained to typed requests:
  - remove an app bundle only when the canonical path is allowlisted and the bundle identifier matches;
  - remove approved user-library cleanup paths only;
  - verify writability or return a clear explanation;
  - optionally repair ownership for known Homebrew paths after explicit policy review.
- Admin passwords are never stored in Keychain.

## Distribution Notes

The intended distribution channel is outside the Mac App Store:

- Developer ID signing.
- Hardened Runtime.
- Notarization.
- DMG or installer that places `Wega Mac Updater.app` in `/Applications`.

The privileged helper should live inside the signed app bundle under `Contents/Library/LaunchDaemons` and be registered through `SMAppService.daemon(plistName:)`. If macOS reports that approval is required, the app should send the user to Login Items & Background Items in System Settings.

## Porting Scope

The TypeScript sources in `../mac-updater` map to the new Swift modules as follows:

| Old file | New area |
| --- | --- |
| `src/services/updater.ts` | `BrewService`, `MasService`, Update UI flow |
| `src/services/scanner.ts` | `ApplicationScanner`, `CaskDatabaseClient`, `CaskMatcher` |
| `src/services/uninstaller.ts` | Uninstall UI flow, `BrewService.uninstallCask` |
| `src/services/migrator.ts` | Migration UI flow, future helper cleanup |
| `src/utils/exec.ts` | `BinaryLocator`, `ProcessRunner`, `StaleCaskDetector` |
| `src/utils/sudo.ts` | Replaced by helper/XPC design; not ported |
| `src/constants.ts` | `MacUpdaterConstants` |
