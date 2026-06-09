# Wega Mac Updater
**Architected & Developed by [Dominik](https://www.linkedin.com/in/dominik-sienkiewicz/)** *Principal AI Engineer | Full Stack Architect*

Native macOS app that keeps every application on your Mac up to date — Homebrew casks, Mac App Store, JetBrains IDEs, GitHub Releases, and Sparkle apps — from a single window, without ever opening a terminal.

![Swift](https://img.shields.io/badge/Swift-6.0-orange?style=for-the-badge&logo=swift&logoColor=white)
![SwiftUI](https://img.shields.io/badge/SwiftUI-macOS_14%2B-blue?style=for-the-badge&logo=apple&logoColor=white)
![Version](https://img.shields.io/badge/Version-0.1.0-lightgrey?style=for-the-badge)
![Homebrew](https://img.shields.io/badge/Homebrew-required-FBB040?style=for-the-badge&logo=homebrew&logoColor=white)
![Architecture](https://img.shields.io/badge/Architecture-SPM_Modules-purple?style=for-the-badge)
[![CI](https://github.com/DominikSienkiewicz/WegaMacUpdater/actions/workflows/ci.yml/badge.svg)](https://github.com/DominikSienkiewicz/WegaMacUpdater/actions/workflows/ci.yml)

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
Antigravity update API ─────────────────────────────────────────────────────────────── ┤
ChatGPT public appcast ─────────────────────────────────────────────────────────────── ┤
Sparkle (SUFeedURL from Info.plist) ────────────────────────────────────────────────── ┤
npm globals (npm ls -g + npm view) ────────────────────────────────────────────────── ┤
/Applications + ~/Applications scan ───────────────────────────────────────────────────┘
```

1. **Scan** — `ApplicationScanner` walks `/Applications`, `~/Applications`, and every immediate non-.app subdirectory (e.g. `/Applications/JetBrains/`). It reads `Contents/Info.plist` directly via `PropertyListSerialization` — never `Bundle(url:)` — so freshly updated apps are always seen with their real version, not a stale cached one.
2. **Classify** — each app is tagged: `isManagedByBrew` (token found in `brew list --cask`, **filtered to casks that actually install an `.app` artifact** — guards against a CLI cask like `codex` claiming an unrelated `Codex.app`), `isManagedByMas` (receipt at `Contents/_MASReceipt/receipt`), or manual.
3. **Check** — the per-app checkers run in parallel. Results are deduplicated by path, keeping the highest-priority source:

| Priority | Source | When it fires |
|----------|--------|---------------|
| 5 | Antigravity update API | Google's Antigravity IDE (`com.google.antigravity-ide`, a distinct product from plain "Antigravity" `com.google.antigravity`). Its Homebrew cask is frozen at an old version while the app self-updates, so brew/cask comparison never fires; the product version is read from Google's own update endpoint (the `X.Y.Z` segment of the download URL, since the JSON's `name`/`productVersion` carry the VS Code base version instead) |
| 5 | Parallels update XML | Parallels Desktop (`com.parallels.desktop.console`). The Homebrew cask `parallels` lags upstream by days/weeks while the app self-updates from `update.parallels.com/desktop/v<major>/parallels/parallels_updates.xml`; the checker derives `<major>` from the installed `CFBundleShortVersionString`, reads `<Major>.<Minor>.<SubMinor>` from the feed, and routes the update through the app's own updater (never brew, which would downgrade) |
| 5 | Google Drive Omaha (canary) | Google Drive for desktop (`com.google.drivefs`). Drive ships via GoogleSoftwareUpdate (Omaha) and the public release-notes page never lists patches (only majors like `Version 126.0`). The checker POSTs an Omaha v3 request to `tools.google.com/service/update2` pinning `appid="com.google.drivefs" ap="canary"` — Stable / 50-percent / 5-percent cohorts return the staged-rollout version which is usually *older* than what's actually installed, while canary tracks the head and reveals patches like `126.0.4 → 126.0.5` that no other public source advertises. Installed version is read from `CFBundleVersion` (4-segment, what Omaha compares against), not `CFBundleShortVersionString` (`126.0`, which would always look outdated) |
| 5 | ChatGPT public appcast | OpenAI's ChatGPT desktop app (`com.openai.chat`). The Homebrew cask `chatgpt` is `auto_updates` and its metadata trails OpenAI's release channel; the app self-updates via Sparkle but resolves its feed URL programmatically at runtime (no `SUFeedURL` in `Info.plist` or the prefs domain), so the generic Sparkle checker can't find it. The checker queries OpenAI's public appcast (`persistent.oaistatic.com/sidekick/public/sparkle_public_appcast.xml`, the same feed the cask's livecheck uses) and picks the **max** `sparkle:shortVersionString` across all items — feed items are not reliably ordered (older builds can carry a more recent `pubDate`). Routes the update through the app's own updater, never brew |
| 4 | JetBrains Data Services | IntelliJ IDEA, PyCharm, WebStorm, GoLand, CLion, Rider, DataGrip, RubyMine, PHPStorm, DataSpell, Aqua, RustRover (14 IDEs) |
| 3 | GitHub Releases API | VS Code, Obsidian, Rectangle, AltTab, Stats, Maccy, MonitorControl, LinearMouse, IINA, HandBrake, Keka, GitHub Desktop |
| 3 | Synology Release Notes API | Synology Drive Client (`/api/releaseNote/findChangeLog?identify=…`); compares the build number after the dash (e.g. `4.0.3-17892`) against `CFBundleVersion` because Synology's CFBundleShortVersionString and installer version use unrelated numbering schemes |
| 2 | Homebrew Cask | Any cask where `brew info` reports a newer version; uses `brew list --cask --versions` as authoritative installed reference |
| 1 | Sparkle | Any non-brew app that exposes `SUFeedURL` in its `Info.plist`, plus a curated override map for Electron-based apps (e.g. Codex) that ship Sparkle but set the feed URL programmatically |

4. **Version normalisation** — a shared `VersionComparison` module handles every version format seen in the wild: `7.0.0 (77593)` vs `7.0.0.77593` (Zoom), `125.0` vs `125.0.0` (Google Drive), `5.3.1,50301` Homebrew comma-format, `0.4.13+1` semver build metadata, and `v1.12.7` / `release-3.5.8` / `v1.4.2-build164` GitHub tag prefixes. `isUpgrade` uses `lexicographicallyPrecedes` so a locally-ahead app (e.g. Logi Options 10.9.0 when brew tracks 10.7.0) is never reported as outdated.
5. **Act** — each update source drives its own action: brew casks run `brew install --cask` with a live log panel; JetBrains apps open Toolbox; GitHub apps open the Releases page; Sparkle apps prompt inside the app itself; Antigravity is launched so its own updater takes over (never routed through brew, which would downgrade it to the stale cask); npm globals are bumped with `npm install -g <pkg>@latest`.

Before any of this, `runCheck()` calls `brew update` so a freshly-published cask/formula version that hasn't landed locally yet is still seen.

### npm globals (sixth source)
`NpmGlobalChecker` lists user-installed global packages with `npm ls -g --json --depth=0`, then resolves the latest version per package with `npm view <pkg> version`. `npm` itself and `corepack` are filtered out (managed by the Node distribution, not user-actionable here). The npm binary is located across Homebrew, Volta, fnm, and nvm install layouts — and as a last resort by asking the login shell (`$SHELL -lc 'command -v npm'`). This is what catches cases like the OpenAI Codex CLI being installed both as a Homebrew cask (up-to-date) and as `@openai/codex` under fnm (outdated) — brew alone would report nothing to do.

## Features

### Update
Checks Homebrew formulae + casks (greedy), Mac App Store, npm globals, and all five manual-app checkers in one pass. Selectable list — update all or pick individually. Live log streamed into an inline panel. After update, running apps are detected and offered a one-click restart. Stale casks are cleaned and `brew update` runs before the outdated check. When a check can't complete (offline, source down), the screen says **"couldn't check — check your connection"** instead of falsely reporting "everything up to date". **Right-click any update** to **ignore** it ("don't update Zoom") or **pin a version** ("pin Parallels to 18" — only updates up to that ceiling are shown); rules are managed from the Info tab and persist across launches.

### Uninstall
Scans every app on the system regardless of origin. Brew casks are removed with `brew uninstall --cask --zap`; App Store and manually installed apps are moved to Trash. Confirmation dialog shows exact counts — how many casks will be zapped, how many go to Trash.

### Migration
Finds manually-installed apps that have a Homebrew Cask equivalent and offers to migrate them with `brew install --cask`. Runs `mas search` in parallel for apps without a cask match to find App Store equivalents. After successful brew migration, scans `~/Library` for leftover preference files and offers to clean them with a checkbox sheet. **npm ↔ brew duplicate row** — for CLIs installed via both `npm -g` and Homebrew (e.g. `@openai/codex` + `codex` cask), inline "Usuń z npm" / "Usuń z brew" buttons run the corresponding uninstall (`npm uninstall -g <pkg>` via `NpmGlobalService.uninstallEvents`, or `brew uninstall <token>`) after a confirmation alert; the duplicate disappears from the list on exit 0.

### Inventory
Full list of every `.app` on the system with source badge (Brew / App Store / Manual), version, bundle ID, and last-modified date. Filterable by source, sortable by any column, searchable by name or bundle ID. Four stat cards at the top show counts per category — tap any card to filter.

### Info
Real-time diagnostics: Homebrew version, mas-cli version, Privileged Helper status, macOS version, CPU architecture. App version, build, links. License block for bundled open-source tools. **Language card** — switch the interface between **Polski** (default) and **English**; the choice is persisted and applies live. **Ignored & pinned card** — lists every ignore / version-pin rule with a one-click remove. **Touch ID for sudo card** — on Macs with biometry hardware, shows whether `pam_tid.so` is wired into `/etc/pam.d/sudo_local` and offers a one-click enable. **App catalog card** — pulls the latest `AppCatalog` overlay from its canonical source on demand (the app also refreshes it on launch); reports the outcome and notes that a fetched update applies on the next launch.

### Logi
Full activity log covering scans, source responses, install results, and errors — newest entry first. Filter by severity (All / Warnings+ / Errors only), search by text, copy entries to the clipboard, or reveal the log file in Finder. When a source fails to respond and the Updates screen shows the "list may be incomplete" warning, the **"Zobacz w logach"** button jumps straight to this tab pre-filtered to errors. The log is also written to `~/Library/Logs/WegaMacUpdater/wega.log`; once the file exceeds ~5 MB it rotates to `wega.log.1`, keeping one backup.

### Menu-bar agent
A box icon lives in the menu bar, **badged with the number of available updates**. On a configurable schedule (off / hourly / every 6 hours / daily, default every 6 hours) it runs a **read-only** background check — never `brew update`, never a mutation — and posts a notification when new updates appear. The dropdown shows the current status, last-check time, **Check now**, **Open Wega**, the interval picker, and **Quit**. Closing the window keeps the agent running (`applicationShouldTerminateAfterLastWindowClosed → false`); ignore/pin rules are honoured by the background count too. Notifications are gated on a real app bundle, so `swift run` degrades gracefully.

## Architecture

```
WegaMacUpdater (SwiftUI app target)
├── ContentView          — sidebar + tab routing; brew-not-found gate
├── UpdateView           — multi-source update orchestrator
├── UninstallView        — all-app-type uninstaller
├── MigrationView        — manual→brew/mas migration wizard
├── InventoryView        — full app catalogue
├── InfoView             — diagnostics + about
├── SharedViews          — buildScanDirs(), WegaBadge, WegaCard, PackageRow, EmptyHero…
├── MenuBarAgent / MenuBarScene — menu-bar `MenuBarExtra` (badge + dropdown) driven by `MenuBarAgent` (timer loop, notifications, persisted interval); `AppDelegate` keeps the process alive after the window closes
└── Localization         — `tr()` / `trf()` route every UI string through `LocalizationManager` (default **Polski**, switchable to **English** from the Info tab, persisted in UserDefaults — the language switches **live**, without relaunch). Polish is the base text in the views; the translation table (`Translations.en`) lives in **MacUpdaterCore** so it's unit-testable, and `LocalizationCompletenessTests` scans the app sources for every `tr("…")` / `trf("…")` literal and **fails CI if any key lacks an English counterpart** — turning a would-be silent Polish fallback into a build error. `LocalizationManager` (the live-switch `ObservableObject`) stays app-side. The runtime-switchable design is deliberate: native String Catalogs (`.xcstrings`) resolve at the system locale and can't switch in-app without a relaunch

MacUpdaterCore (library target — no SwiftUI dependency)
├── ApplicationScanner   — filesystem scan, Info.plist parsing, brew/mas tagging
├── BrewService          — brew outdated (greedy), install, uninstall, cask versions
├── MasService           — mas outdated, list, search, upgrade
├── HTTPClient           — one shared HTTP client behind all nine checkers + CaskDatabaseClient: uniform 15s/30s timeouts, a single `User-Agent` (`WegaMacUpdater/<version>`), transient-failure retry with exponential backoff (429 + 5xx + network errors), and ETag conditional requests. The GitHub checker enables ETag so a `304 Not Modified` reuses the cached body **and does not count against GitHub's unauthenticated 60-req/h rate limit**. The transport is a protocol seam (`HTTPTransport`) so the retry/ETag logic is unit-tested with a fake, no network
├── ManualCheckResult    — every manual checker returns `.notApplicable` / `.upToDate` / `.outdated` / `.unavailable` / `.failed` instead of a bare `Optional`, so a network failure is no longer indistinguishable from "current". `.unavailable` (a transport error or 5xx server response) is a transient upstream outage: it logs at WARNING and is **not** counted toward the "list may be incomplete" banner, while `.failed` (a 4xx, or a 200 we couldn't parse) logs at ERROR and is counted. `UpdatePlanner.scanState` folds the totals into `upToDate` / `outdated` / `checkFailed` / `partialFailure`, and the Update screen shows "couldn't check — check your connection" instead of a false "everything up to date" when offline
├── UpdatePlanner        — pure orchestration logic lifted out of UpdateView: builds the selectable outdated list (with load-bearing source-tagged keys), routes a selection back to per-manager upgrade commands, dedupes manual results by source priority, summarises upgrade outcomes, and derives the post-scan `ScanState` — all unit-tested without SwiftUI
├── ManualUpdateScanner  — runs all eight manual checkers + the brew-cask version check over every installed app and dedupes by source priority; shared by the Update screen and the menu-bar agent (one implementation, no divergence). `AppScanDirectories` provides the scan roots. The per-app checks fan out through `runBounded` (`BoundedConcurrency`) with a configurable cap (default 12 in-flight) so a large `/Applications` doesn't open one connection per (app × checker) and hammer the remote update APIs
├── MenuBarUpdateChecker  — read-only count of available updates (brew/mas/npm + ManualUpdateScanner, with policies applied) for the menu-bar badge and notifications; never mutates the system
├── UpdateSchedule       — pure scheduling decisions (`shouldCheck` / `secondsUntilNextCheck`) + `CheckInterval` (off / hourly / 6h / daily), unit-tested without timers
├── UpdatePolicy         — per-app ignore / version-pin rules ("don't update Zoom", "pin Parallels to 18"). `UpdatePlanner.applyPolicies` filters both the brew/mas/npm list and the manual list: `.ignored` hides an item outright, `.pinned(version:)` hides only updates *beyond* the pinned ceiling (via `isUpgrade`). Identity is the source-tagged key for tracked items and `manual:<name>` for manual apps. Pure and unit-tested; persisted app-side by `UpdatePolicyStore` (UserDefaults JSON)
├── MigrationPlanner     — pure orchestration logic lifted out of MigrationView: partitions scanned apps into matchable / App-Store / unmatched, filters the migration pool, builds `~/Library` leftover paths, and owns `DuplicateRemoval` (npm↔brew command preview) — unit-tested without SwiftUI
├── AppCatalog           — single source of truth for every per-app mapping (GitHub repos, JetBrains IDE codes, Synology identifiers, Sparkle feed overrides); decoded from the bundled `Resources/app-catalog.json` and overlaid (if present) by a user-writable `~/Library/Application Support/WegaMacUpdater/app-catalog.json`, so the catalog can be refreshed out-of-band without a new app build
├── CatalogRefresher     — fetches the overlay catalog from a remote JSON source over the shared `HTTPClient` (ETag-conditional), **validates it by decoding before writing**, then writes it atomically to `AppCatalog.overlayURL` — so a malformed or hostile body can never clobber a good overlay. The source URL is injected from `AppEndpoints` (the `appCatalog` endpoint, raw-hosted on GitHub) and the refresh is triggered both on app launch (fire-and-forget, ETag-conditional) and on demand from the Info tab's **App catalog** card
├── AppEndpoints         — single source of truth for every outbound URL (update feeds, GitHub/Synology/Parallels/Antigravity APIs, the `AppCatalog` overlay source, the Homebrew install command, UI links); decoded from the bundled `Resources/endpoints.json` as `{placeholder}` templates and overlaid (if present) by a user-writable `~/Library/Application Support/WegaMacUpdater/endpoints.json`, so a vendor that moves a feed can be followed without a new build. Keeping the literal URIs out of Swift is what lets each call site read its endpoint from a customizable parameter. Fixed macOS/Homebrew paths live separately in `SystemPaths` (deliberately hard-coded — routing e.g. `/usr/bin/sudo` through a writable file would be a security hole)
├── JetBrainsUpdateChecker — data.services.jetbrains.com, 14 IDE mappings (from AppCatalog)
├── GitHubReleasesChecker  — api.github.com/releases/latest, 12 app mappings (from AppCatalog)
├── WegaSelfUpdateChecker  — Wega's own update check: latest GitHub Release tag vs `AppMetadata.version`, resolves the published `.dmg`/`.pkg` asset (surfaced in the Info tab). Pure, HTTPClient-injectable, unit-tested
├── SynologyUpdateChecker  — synology.com/api/releaseNote/findChangeLog, compares build number from versionString (`4.0.3-17892` → `17892`) against CFBundleVersion
├── AntigravityUpdateChecker — Google Antigravity IDE update endpoint; reads the product version from the download URL path (cask is stale, app self-updates)
├── ParallelsUpdateChecker  — `update.parallels.com/desktop/v<major>/parallels/parallels_updates.xml`; major derived from installed bundle, `<Major>.<Minor>.<SubMinor>` read from the feed (cask `parallels` lags, app self-updates)
├── GoogleDriveUpdateChecker — POSTs an Omaha v3 update-check to `tools.google.com/service/update2` with `appid="com.google.drivefs" ap="canary"` and parses `<manifest version="X.Y.Z.W"/>`; canary cohort reveals the patches (e.g. `126.0.5.0`) that Stable / 50-percent never advertise. Compares against `CFBundleVersion` (not `CFBundleShortVersionString`, which is only `126.0`)
├── SparkleUpdateChecker   — Info.plist (PropertyListSerialization, never Bundle(url:)) + CFPreferencesCopyAppValue fallback + `SparkleFeedOverrides` map (backed by AppCatalog) for apps that set the feed URL at runtime
├── NpmBrewDuplicateDetector — finds CLIs installed via both `npm -g` and Homebrew (surfaced in Migration)
├── NpmGlobalChecker       — `npm ls -g` + `npm view <pkg> version`; NpmLocator scans brew/Volta/fnm/nvm + login-shell fallback
├── VersionComparison    — versionsEqual, isUpgrade, normalizeGitTag (public, tested)
├── CaskDatabaseClient   — full cask database fetch + disk cache
├── CaskMatcher          — bundle-id / name → cask token matching
├── StaleCaskDetector    — detects casks where installed .app is gone
├── BrewCaskDriftFilter  — hides casks whose on-disk `CFBundleShortVersionString` already matches `current_version`; covers self-updating apps like Google Chrome that bump their bundle outside Homebrew, leaving brew's `installed_versions` metadata stale
├── BinaryLocator        — resolves brew + mas executable paths
├── RunningProcessService — detect (`pgrep -x`), terminate (`killall`), relaunch (`open -a`) running apps for the restart-after-update and quit-before-migrate flows; routed through the `ProcessRunning` seam (one implementation shared by UpdateView + MigrationView, unit-tested with a fake instead of spawning real processes)
├── AskpassHelper        — writes ~/Library/Application Support/WegaMacUpdater/askpass.sh (0700) wrapping `osascript`; HomebrewEnvironment exports SUDO_ASKPASS so brew's cask hooks can `sudo` without a controlling terminal
├── SudoShim             — writes ~/Library/Application Support/WegaMacUpdater/sudo-shim/sudo (0700) that re-execs `/usr/bin/sudo -A "$@"`; HomebrewEnvironment prepends this dir to PATH so `mas upgrade` (which shells out to `sudo softwareupdate` for Safari extensions without passing `-A`) still triggers the askpass dialog
├── TouchIDSudoConfigurator — pure state parser for /etc/pam.d/sudo_local + biometry check (LocalAuthentication, with an IOKit hardware-presence fallback); renders an idempotent shell command that installs `auth sufficient pam_tid.so` via `tee /etc/pam.d/sudo_local` (write-in-place, **not** `mv` from /var/folders — that rename is blocked by TCC on Sequoia with `Operation not permitted` even as root), invoked via osascript with administrator privileges from InfoView. When TCC blocks even the `tee` path (Sequoia's App Management bucket protects /etc/pam.d/ against unentitled GUI apps and their osascript-elevated children regardless of effective UID), `TouchIDSudoEnableOutcome.classify` flips InfoView into a manual-Terminal fallback: shows `manualEnableTerminalCommand` (a `grep -q` guarded `sudo tee -a` one-liner) with "Skopiuj komendę" + "Otwórz w Terminalu" buttons — Terminal.app is its own TCC principal and the write succeeds there on first prompt.
└── Models               — ApplicationInfo, ManualOutdatedApp, UpdateSource…

MacUpdaterTests
└── VersionComparisonTests, ApplicationScannerMasTests, BrewInfoParserTests…
```

No stored passwords. Homebrew runs as the logged-in user. Some casks (Zoom, kernel-extension installers, anything that registers launchd services or calls `pkgutil --forget`) invoke `sudo` internally during install/uninstall hooks — Wega has two layered fallbacks:

1. **Touch ID (preferred)** — Info tab detects whether `/usr/lib/pam/pam_tid.so.2` exists, the Mac has a Touch ID sensor (`LAContext.canEvaluatePolicy`, falling back to an IOKit `AppleBiometricSensor` probe when biometrics are only *transiently* unusable for the app — e.g. clamshell mode, just after boot — so the card is not wrongly hidden), and `/etc/pam.d/sudo_local` already contains an active `auth sufficient pam_tid.so` line. If not, a one-click "Włącz Touch ID dla sudo" button runs `osascript … with administrator privileges` to append the directive (writes to `sudo_local`, never to `sudo` itself, because the latter is overwritten on every macOS update). After that, brew's internal `sudo` calls trigger the native macOS biometric sheet.
2. **Askpass (fallback)** — on first launch Wega writes `askpass.sh` (mode `0700`) to `~/Library/Application Support/WegaMacUpdater/` and exports `SUDO_ASKPASS` to brew. When sudo runs without a controlling terminal and biometry fails or is unavailable, it invokes the script, which delegates to `osascript` for a hidden-answer dialog. This is what catches the Zoom symptom (`sudo: a terminal is required` → `Error: zoom: Broken pipe`) on machines without Touch ID. The same first-launch step also writes a `sudo` PATH-shim under `sudo-shim/` and prepends it to the child-process `PATH`; the shim re-execs `/usr/bin/sudo -A "$@"` for any wrapped CLI that calls `sudo` by name. **Both the shim and `SUDO_ASKPASS` are gated on Touch ID state** — when `sudo_local` has `pam_tid.so` active, `HomebrewEnvironment.environment` drops both from brew's child env so sudo goes through PAM unmodified and pam_tid pops the biometric sheet; otherwise (-A in the shim would make sudo skip pam_tid entirely and surface the askpass password dialog, the exact symptom of the Parallels-upgrade-asks-for-password bug). `MasService.prewarmSudoTimestamp` follows the same rule: `sudo -v` when Touch ID is enabled, `sudo -A -v` otherwise. **mas upgrade** is special — it shells out to `/usr/bin/sudo` by absolute path for Safari extensions like Proton Pass, so the shim is bypassed; `MasService.upgrade` detects the canonical `sudo: a terminal is required` stderr signature, runs `/usr/bin/sudo -A -v` once to prime the no-tty sudo timestamp via the askpass dialog, then retries `mas upgrade` so its internal sudo call finds a valid cached credential.

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

The package targets the **Swift 6 language mode** (`swift-tools-version: 6.0`), so the whole codebase compiles under strict concurrency checking. Every push and pull request to `main` runs four GitHub Actions jobs (`.github/workflows/ci.yml`) on a `macos-15` runner with the latest stable Xcode (the SonarCloud job runs on `ubuntu-latest`):

- **Build & Test** — `swift build --build-tests` + `swift test`, both with `--enable-code-coverage`. `scripts/coverage-sonarqube.sh` then converts SwiftPM's llvm-cov output into a SonarQube generic coverage report (`sonarqube-generic-coverage.xml`) that is uploaded as an artifact for the SonarCloud job (which runs on Linux and can't run the macOS tests itself).
- **SwiftLint** — `swiftlint lint --strict` against `.swiftlint.yml` (warnings fail the job). The config keeps the high-signal correctness rules and metric guardrails while disabling the purely-cosmetic rules that conflict with the codebase's house style, so it gates regressions without reformatting.
- **Package** — runs `scripts/build-pkg.sh` to prove the whole packaging path composes, asserts the binary is **universal** (arm64 + x86_64) and that both `app-catalog.json` and `endpoints.json` are bundled (the latter is required at launch — `AppEndpoints.shared` fatal-errors without it), and uploads the resulting `.pkg` as an artifact.
- **SonarCloud** — runs the SonarQube/SonarCloud scanner against `sonar-project.properties` (after **Build & Test**, whose coverage report it downloads and feeds via `sonar.coverageReportPaths`). Skipped until a `SONAR_TOKEN` secret is configured, so it never blocks CI before setup. Outbound URLs are sourced from `endpoints.json` via `AppEndpoints`, so `S1075` ("hard-coded URI") only fires on genuinely configurable endpoints; tests and the fixed-system-path files are excluded in the properties file. Coverage is measured on the `MacUpdaterCore` library; the SwiftUI app/View layer and the constant-only `SystemPaths.swift` are excluded via `sonar.coverage.exclusions` (the gate requires ≥ 80% coverage on new code).

`scripts/build-pkg.sh` builds a universal binary by default (override with `ARCHS="arm64"`) and copies the SPM resource bundle (`app-catalog.json`) into the `.app`, so `Bundle.module` resolves at runtime.

Open `Package.swift` directly in Xcode for the full IDE experience. A signed `.app` bundle requires a separate Xcode project or `xcodebuild` invocation with a provisioning profile.

### Version — single source of truth

The app version lives in exactly one place: `AppMetadata.version` (`Sources/MacUpdaterCore/AppMetadata.swift`). The running app reads it (falling back to it when no bundle `Info.plist` is present, e.g. under `swift run`), and `scripts/build-pkg.sh` extracts it from there when stamping the generated `Info.plist` and the `.pkg` — so bumping the version is a one-line edit. The release workflow **enforces** this: a tag `vX.Y.Z` whose version doesn't equal `AppMetadata.version` fails the build before anything is published.

## Distribution

Intended channel: Developer ID, outside the Mac App Store.

- Developer ID Application signing
- Hardened Runtime
- Notarization
- DMG placing `Wega Mac Updater.app` in `/Applications`

### Cutting a release

`scripts/build-pkg.sh` builds a universal, ad-hoc-or-signed `.pkg` **and** a drag-to-Applications `.dmg`. Pushing a version tag drives the rest:

```bash
# bump AppMetadata.version first, then:
git tag v0.1.0 && git push origin v0.1.0
```

Move the `[Unreleased]` entries in [`CHANGELOG.md`](CHANGELOG.md) under the new version heading as part of the bump.

`.github/workflows/release.yml` (on `push: tags: v*`) verifies tag == `AppMetadata.version`, runs the tests, builds the artifacts, and publishes a GitHub Release with the `.pkg` + `.dmg`. **Signing and notarization are optional and activate automatically once the secrets exist** — until then the job still publishes *unsigned* artifacts so the pipeline is verifiable end-to-end without an Apple Developer account. Secrets (all optional): `DEVELOPER_ID_IDENTITY`, `DEVELOPER_ID_CERT_P12`, `DEVELOPER_ID_CERT_PASSWORD`, `KEYCHAIN_PASSWORD`, and `AC_API_KEY_ID` / `AC_API_ISSUER_ID` / `AC_API_KEY_P8` for `notarytool`.

### Self-update

Wega updates **itself** by dogfooding the same machinery it uses for everyone else. `WegaSelfUpdateChecker` (MacUpdaterCore) asks the GitHub Releases API for the latest tag, compares it against `AppMetadata.version` with the shared `VersionComparison` logic, and resolves the published installer asset (preferring the `.dmg`, falling back to the `.pkg`). The **Info tab** surfaces it: it auto-checks once when the tab opens (ETag-conditional, so revisits are free) and offers a manual re-check; when a newer release exists, it shows the version and a "Download and install" button (downloads the asset and hands it to Installer / DiskImageMounter, falling back to opening the asset in the browser) plus a link to the release notes. No embedded framework, no appcast to host. (Sparkle-style silent background updates remain a possible later upgrade; the runtime cost — embedding the framework in the hand-rolled bundle, EdDSA-signed appcast hosting — isn't worth it for a tool you open deliberately.)

The future privileged helper lives inside the bundle at `Contents/Library/LaunchDaemons` and registers via `SMAppService.daemon(plistName:)`.

## License

[MIT](LICENSE)
