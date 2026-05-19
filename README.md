# Wega Mac Updater
**Architected & Developed by [Dominik](https://www.linkedin.com/in/dominik-sienkiewicz/)** *Principal AI Engineer | Full Stack Architect*

Native macOS app that keeps every application on your Mac up to date — Homebrew casks, Mac App Store, JetBrains IDEs, GitHub Releases, and Sparkle apps — from a single window, without ever opening a terminal.

![Swift](https://img.shields.io/badge/Swift-6.0-orange?style=for-the-badge&logo=swift&logoColor=white)
![SwiftUI](https://img.shields.io/badge/SwiftUI-macOS_14%2B-blue?style=for-the-badge&logo=apple&logoColor=white)
![Version](https://img.shields.io/badge/Version-0.0.1-lightgrey?style=for-the-badge)
![Homebrew](https://img.shields.io/badge/Homebrew-required-FBB040?style=for-the-badge&logo=homebrew&logoColor=white)
![Architecture](https://img.shields.io/badge/Architecture-SPM_Modules-purple?style=for-the-badge)

## The Vision: one window, zero terminals

Package managers have proliferated — Homebrew casks, formulae, Mac App Store, Sparkle auto-updaters, JetBrains Toolbox, GitHub Releases. Each lives in a different UI or CLI. Wega centralises all of them: one native SwiftUI window that knows where every app came from and how to update it correctly. No `brew upgrade` in muscle memory, no App Store tab left open, no missed JetBrains IDE because Toolbox uses `auto_updates: true` and `brew outdated` never fires.

## How it works

```
Homebrew casks ────────────────────────────────────────────────────────────────────────┐
Homebrew formulae ──────────────────────────────────────────────────────────────────── ┤
Mac App Store (mas-cli) ────────────────────────────────────────────────────────────── ┤
JetBrains Data Services API ────────────────────────────────────────────────────────── ┤─► Version comparison
GitHub Releases API ────────────────────────────────────────────────────────────────── ┤   (priority dedup)  ──► Update list
Synology Release Notes API ─────────────────────────────────────────────────────────── ┤
Sparkle (SUFeedURL from Info.plist) ────────────────────────────────────────────────── ┤
npm globals (npm ls -g + npm view) ────────────────────────────────────────────────── ┤
/Applications + ~/Applications scan ───────────────────────────────────────────────────┘
```

1. **Scan** — `ApplicationScanner` walks `/Applications`, `~/Applications`, and every immediate non-.app subdirectory (e.g. `/Applications/JetBrains/`). It reads `Contents/Info.plist` directly via `PropertyListSerialization` — never `Bundle(url:)` — so freshly updated apps are always seen with their real version, not a stale cached one.
2. **Classify** — each app is tagged: `isManagedByBrew` (token found in `brew list --cask`, **filtered to casks that actually install an `.app` artifact** — guards against a CLI cask like `codex` claiming an unrelated `Codex.app`), `isManagedByMas` (receipt at `Contents/_MASReceipt/receipt`), or manual.
3. **Check** — five parallel checkers run per app. Results are deduplicated by path, keeping the highest-priority source:

| Priority | Source | When it fires |
|----------|--------|---------------|
| 4 | JetBrains Data Services | IntelliJ IDEA, PyCharm, WebStorm, GoLand, CLion, Rider, DataGrip, RubyMine, PHPStorm, DataSpell, Aqua, RustRover (14 IDEs) |
| 3 | GitHub Releases API | VS Code, Obsidian, Rectangle, AltTab, Stats, Maccy, MonitorControl, LinearMouse, IINA, HandBrake, Keka, GitHub Desktop |
| 3 | Synology Release Notes API | Synology Drive Client (`/api/releaseNote/findChangeLog?identify=…`); compares the build number after the dash (e.g. `4.0.3-17892`) against `CFBundleVersion` because Synology's CFBundleShortVersionString and installer version use unrelated numbering schemes |
| 2 | Homebrew Cask | Any cask where `brew info` reports a newer version; uses `brew list --cask --versions` as authoritative installed reference |
| 1 | Sparkle | Any non-brew app that exposes `SUFeedURL` in its `Info.plist`, plus a curated override map for Electron-based apps (e.g. Codex) that ship Sparkle but set the feed URL programmatically |

4. **Version normalisation** — a shared `VersionComparison` module handles every version format seen in the wild: `7.0.0 (77593)` vs `7.0.0.77593` (Zoom), `125.0` vs `125.0.0` (Google Drive), `5.3.1,50301` Homebrew comma-format, `0.4.13+1` semver build metadata, and `v1.12.7` / `release-3.5.8` / `v1.4.2-build164` GitHub tag prefixes. `isUpgrade` uses `lexicographicallyPrecedes` so a locally-ahead app (e.g. Logi Options 10.9.0 when brew tracks 10.7.0) is never reported as outdated.
5. **Act** — each update source drives its own action: brew casks run `brew install --cask` with a live log panel; JetBrains apps open Toolbox; GitHub apps open the Releases page; Sparkle apps prompt inside the app itself; npm globals are bumped with `npm install -g <pkg>@latest`.

Before any of this, `runCheck()` calls `brew update` so a freshly-published cask/formula version that hasn't landed locally yet is still seen.

### npm globals (sixth source)
`NpmGlobalChecker` lists user-installed global packages with `npm ls -g --json --depth=0`, then resolves the latest version per package with `npm view <pkg> version`. `npm` itself and `corepack` are filtered out (managed by the Node distribution, not user-actionable here). The npm binary is located across Homebrew, Volta, fnm, and nvm install layouts — and as a last resort by asking the login shell (`$SHELL -lc 'command -v npm'`). This is what catches cases like the OpenAI Codex CLI being installed both as a Homebrew cask (up-to-date) and as `@openai/codex` under fnm (outdated) — brew alone would report nothing to do.

## Features

### Update
Checks Homebrew formulae + casks (greedy), Mac App Store, npm globals, and all four manual-app checkers in one pass. Selectable list — update all or pick individually. Live log streamed into an inline panel. After update, running apps are detected and offered a one-click restart. Stale casks are cleaned and `brew update` runs before the outdated check.

### Uninstall
Scans every app on the system regardless of origin. Brew casks are removed with `brew uninstall --cask --zap`; App Store and manually installed apps are moved to Trash. Confirmation dialog shows exact counts — how many casks will be zapped, how many go to Trash.

### Migration
Finds manually-installed apps that have a Homebrew Cask equivalent and offers to migrate them with `brew install --cask`. Runs `mas search` in parallel for apps without a cask match to find App Store equivalents. After successful brew migration, scans `~/Library` for leftover preference files and offers to clean them with a checkbox sheet. **npm ↔ brew duplicate row** — for CLIs installed via both `npm -g` and Homebrew (e.g. `@openai/codex` + `codex` cask), inline "Usuń z npm" / "Usuń z brew" buttons run the corresponding uninstall (`npm uninstall -g <pkg>` via `NpmGlobalService.uninstallEvents`, or `brew uninstall <token>`) after a confirmation alert; the duplicate disappears from the list on exit 0.

### Inventory
Full list of every `.app` on the system with source badge (Brew / App Store / Manual), version, bundle ID, and last-modified date. Filterable by source, sortable by any column, searchable by name or bundle ID. Four stat cards at the top show counts per category — tap any card to filter.

### Info
Real-time diagnostics: Homebrew version, mas-cli version, Privileged Helper status, macOS version, CPU architecture. App version, build, links. License block for bundled open-source tools. **Touch ID for sudo card** — on Macs with biometry hardware, shows whether `pam_tid.so` is wired into `/etc/pam.d/sudo_local` and offers a one-click enable.

## Architecture

```
WegaMacUpdater (SwiftUI app target)
├── ContentView          — sidebar + tab routing; brew-not-found gate
├── UpdateView           — multi-source update orchestrator
├── UninstallView        — all-app-type uninstaller
├── MigrationView        — manual→brew/mas migration wizard
├── InventoryView        — full app catalogue
├── InfoView             — diagnostics + about
└── SharedViews          — buildScanDirs(), WegaBadge, WegaCard, PackageRow, EmptyHero…

MacUpdaterCore (library target — no SwiftUI dependency)
├── ApplicationScanner   — filesystem scan, Info.plist parsing, brew/mas tagging
├── BrewService          — brew outdated (greedy), install, uninstall, cask versions
├── MasService           — mas outdated, list, search, upgrade
├── JetBrainsUpdateChecker — data.services.jetbrains.com, 14 IDE mappings
├── GitHubReleasesChecker  — api.github.com/releases/latest, 12 app mappings
├── SynologyUpdateChecker  — synology.com/api/releaseNote/findChangeLog, compares build number from versionString (`4.0.3-17892` → `17892`) against CFBundleVersion
├── SparkleUpdateChecker   — Info.plist (PropertyListSerialization, never Bundle(url:)) + CFPreferencesCopyAppValue fallback + `SparkleFeedOverrides` map for apps that set the feed URL at runtime
├── NpmBrewDuplicateDetector — finds CLIs installed via both `npm -g` and Homebrew (surfaced in Migration)
├── NpmGlobalChecker       — `npm ls -g` + `npm view <pkg> version`; NpmLocator scans brew/Volta/fnm/nvm + login-shell fallback
├── VersionComparison    — versionsEqual, isUpgrade, normalizeGitTag (public, tested)
├── CaskDatabaseClient   — full cask database fetch + disk cache
├── CaskMatcher          — bundle-id / name → cask token matching
├── StaleCaskDetector    — detects casks where installed .app is gone
├── BinaryLocator        — resolves brew + mas executable paths
├── AskpassHelper        — writes ~/Library/Application Support/WegaMacUpdater/askpass.sh (0700) wrapping `osascript`; HomebrewEnvironment exports SUDO_ASKPASS so brew's cask hooks can `sudo` without a controlling terminal
├── TouchIDSudoConfigurator — pure state parser for /etc/pam.d/sudo_local + LocalAuthentication biometry check; renders an idempotent shell command to atomically (mktemp + mv) install `auth sufficient pam_tid.so`, invoked via osascript with administrator privileges from InfoView
└── Models               — ApplicationInfo, ManualOutdatedApp, UpdateSource…

MacUpdaterTests
└── VersionComparisonTests, ApplicationScannerMasTests, BrewInfoParserTests…
```

No stored passwords. Homebrew runs as the logged-in user. Some casks (Zoom, kernel-extension installers, anything that registers launchd services or calls `pkgutil --forget`) invoke `sudo` internally during install/uninstall hooks — Wega has two layered fallbacks:

1. **Touch ID (preferred)** — Info tab detects whether `/usr/lib/pam/pam_tid.so.2` exists, biometry is available (`LAContext.canEvaluatePolicy`), and `/etc/pam.d/sudo_local` already contains an active `auth sufficient pam_tid.so` line. If not, a one-click "Włącz Touch ID dla sudo" button runs `osascript … with administrator privileges` to append the directive (writes to `sudo_local`, never to `sudo` itself, because the latter is overwritten on every macOS update). After that, brew's internal `sudo` calls trigger the native macOS biometric sheet.
2. **Askpass (fallback)** — on first launch Wega writes `askpass.sh` (mode `0700`) to `~/Library/Application Support/WegaMacUpdater/` and exports `SUDO_ASKPASS` to brew. When sudo runs without a controlling terminal and biometry fails or is unavailable, it invokes the script, which delegates to `osascript` for a hidden-answer dialog. This is what catches the Zoom symptom (`sudo: a terminal is required` → `Error: zoom: Broken pipe`) on machines without Touch ID.

Privileged operations beyond that (future) go through a signed XPC helper with typed, allowlisted requests — never a shell-string API.

## Requirements

- macOS 14 or newer
- Xcode 26 or Swift 6.0 toolchain
- Homebrew installed at `/opt/homebrew/bin/brew` or `/usr/local/bin/brew`
- Optional: `mas` at `/opt/homebrew/bin/mas` or `/usr/local/bin/mas` (App Store features degrade gracefully without it)

GUI apps do not inherit an interactive shell environment. Wega resolves all tool paths from fixed locations — no `.zshrc`, no `$PATH` dependency.

## Build and test

```bash
swift build               # compile all targets
swift test                # run all tests
swift run WegaMacUpdater  # launch app
```

Open `Package.swift` directly in Xcode for the full IDE experience. A signed `.app` bundle requires a separate Xcode project or `xcodebuild` invocation with a provisioning profile.

## Distribution

Intended channel: Developer ID, outside the Mac App Store.

- Developer ID Application signing
- Hardened Runtime
- Notarization
- DMG placing `Wega Mac Updater.app` in `/Applications`

The future privileged helper lives inside the bundle at `Contents/Library/LaunchDaemons` and registers via `SMAppService.daemon(plistName:)`.

## License

[MIT](LICENSE)
