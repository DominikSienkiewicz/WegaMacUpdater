# Wega Mac Updater
**Architected & Developed by [Dominik](https://www.linkedin.com/in/dominik-sienkiewicz/)** *Principal AI Engineer | Full Stack Architect*

Native macOS app that keeps every application on your Mac up to date — Homebrew casks, Mac App Store, JetBrains IDEs, GitHub Releases, and Sparkle apps — from a single window, without ever opening a terminal.

![Swift](https://img.shields.io/badge/Swift-6.0-orange?style=for-the-badge&logo=swift&logoColor=white)
![SwiftUI](https://img.shields.io/badge/SwiftUI-macOS_26%2B-blue?style=for-the-badge&logo=apple&logoColor=white)
![Version](https://img.shields.io/badge/Version-0.1.0-lightgrey?style=for-the-badge)
![Homebrew](https://img.shields.io/badge/Homebrew-optional-FBB040?style=for-the-badge&logo=homebrew&logoColor=white)
![Architecture](https://img.shields.io/badge/Architecture-SPM_Modules-purple?style=for-the-badge)
[![CI](https://github.com/DominikSienkiewicz/WegaMacUpdater/actions/workflows/ci.yml/badge.svg)](https://github.com/DominikSienkiewicz/WegaMacUpdater/actions/workflows/ci.yml)

## Contents

- [Documentation](#documentation) — which file answers which question
- [The Vision: one window, zero terminals](#the-vision-one-window-zero-terminals)
- [How it works](#how-it-works) — scan → classify → check → compare → act
  - [npm globals (third package manager)](#npm-globals-third-package-manager)
- [Features](#features)
  - [Update](#update) — [what it checks](#what-it-checks) ·
    [dry-run panel](#before-anything-runs--the-dry-run-panel) ·
    [one count](#one-count-everywhere) ·
    [restored scans](#the-window-opens-with-a-result-not-an-empty-screen) ·
    [running the update](#running-the-update) ·
    [failed checks](#when-a-check-cant-complete) ·
    [publisher baseline](#publisher-baseline-safety) ·
    [rollback net](#the-rollback-net) ·
    [green banners](#what-a-green-banner-means) ·
    [per-row control](#per-row-control) ·
    [inspector](#the-detail-inspector)
  - [Accessibility](#accessibility)
  - [Uninstall](#uninstall)
  - [Migration](#migration)
  - [Inventory](#inventory)
  - [Settings](#settings)
  - [Logs](#logs)
  - [Menu-bar agent](#menu-bar-agent)
- [Architecture](#architecture) — module tree and the sudo/helper boundary
- [Requirements](#requirements)
- [Build and test](#build-and-test)
  - [Version — single source of truth](#version--single-source-of-truth)
- [Distribution](#distribution)
  - [Cutting a release](#cutting-a-release)
  - [Self-update](#self-update)
- [License](#license)

## Documentation

Wega's docs are split by audience:

- **Using the app** → **[User Guide](USER_GUIDE.md)** — a task-oriented walkthrough:
  *installation → first scan → update → diagnostics*. Start here if you just want to keep
  your Mac up to date.
- **Contributing code** → **[CONTRIBUTING.md](CONTRIBUTING.md)** — build/test setup, the CI
  gates, and how to change the app catalog past the **catalog-signature** gate.
- **Reporting a vulnerability** → **[SECURITY.md](SECURITY.md)** — the private disclosure
  channel (please don't use public issues for security problems).
- **Cutting a release** → **[RELEASING.md](RELEASING.md)** — the two-phase `release.sh` flow,
  the optional signing/notarization secrets, and how the *first* release is cut from a
  repository that has no tags yet.

The rest of this README is the developer/architecture reference.

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
Postman Squirrel feed ──────────────────────────────────────────────────────────────── ┤
Obsidian desktop releases feed ────────────────────────────────────────────────────── ┤
Sparkle (SUFeedURL from Info.plist) ────────────────────────────────────────────────── ┤
npm globals (npm outdated -g --json) ───────────────────────────────────────────────── ┤
/Applications + ~/Applications scan ───────────────────────────────────────────────────┘
```

1. **Scan** — `ApplicationScanner` walks `/Applications`, `~/Applications`, and every immediate non-.app subdirectory (e.g. `/Applications/JetBrains/`). **The scan set is configurable (UX-16)**: `AppScanDirectories.all(configuration:)` adds the user's own roots (persisted as **security-scoped bookmarks**, so apps on other volumes and in non-standard locations are visible), honours **exclusions**, and descends to a **controlled recursion depth** (default 1 = immediate children) instead of only ever the direct children. The directory list is deduplicated by **resolved** (symlink-followed) path so a folder and a symlink pointing at it don't scan every app twice — while the returned paths stay lexical, matching the purely-lexical installation identity from REL-16. It reads `Contents/Info.plist` directly via `PropertyListSerialization` — never `Bundle(url:)` — so freshly updated apps are always seen with their real version, not a stale cached one.
2. **Classify** — each app is tagged: `isManagedByBrew` (token found in `brew list --cask`, **filtered to casks that actually install an `.app` artifact** — guards against a CLI cask like `codex` claiming an unrelated `Codex.app`), `isManagedByMas` (receipt at `Contents/_MASReceipt/receipt`), or manual.
3. **Check** — the per-app checkers run in parallel. Results are deduplicated by path, keeping the highest-priority source:

| Priority | Source | When it fires |
|----------|--------|---------------|
| 6 | Wega self-update | Wega's own pending release (UX-15). Highest on purpose, so the authoritative self-update entry wins any path collision with a coincidental scan match of Wega's own bundle |
| 5 | Antigravity update API | Google's Antigravity IDE (`com.google.antigravity-ide`, a distinct product from plain "Antigravity" `com.google.antigravity`). Its Homebrew cask is frozen at an old version while the app self-updates, so brew/cask comparison never fires; the product version is read from Google's own update endpoint (the `X.Y.Z` segment of the download URL, since the JSON's `name`/`productVersion` carry the VS Code base version instead) |
| 5 | Parallels update XML | Parallels Desktop (`com.parallels.desktop.console`). The Homebrew cask `parallels` lags upstream by days/weeks while the app self-updates from `update.parallels.com/desktop/v<major>/parallels/parallels_updates.xml`; the checker derives `<major>` from the installed `CFBundleShortVersionString`, reads `<Major>.<Minor>.<SubMinor>` from the feed, and routes the update through the app's own updater (never brew, which would downgrade) |
| 5 | Google Drive Omaha (canary) | Google Drive for desktop (`com.google.drivefs`). Drive ships via GoogleSoftwareUpdate (Omaha) and the public release-notes page never lists patches (only majors like `Version 126.0`). The checker POSTs an Omaha v3 request to `tools.google.com/service/update2` pinning `appid="com.google.drivefs" ap="canary"` — Stable / 50-percent / 5-percent cohorts return the staged-rollout version which is usually *older* than what's actually installed, while canary tracks the head and reveals patches like `126.0.4 → 126.0.5` that no other public source advertises. Installed version is read from `CFBundleVersion` (4-segment, what Omaha compares against), not `CFBundleShortVersionString` (`126.0`, which would always look outdated) |
| 5 | ChatGPT public appcast | OpenAI's ChatGPT desktop app (`com.openai.chat`). The Homebrew cask `chatgpt` is `auto_updates` and its metadata trails OpenAI's release channel; the app self-updates via Sparkle but resolves its feed URL programmatically at runtime (no `SUFeedURL` in `Info.plist` or the prefs domain), so the generic Sparkle checker can't find it. The checker queries OpenAI's public appcast (`persistent.oaistatic.com/sidekick/public/sparkle_public_appcast.xml`, the same feed the cask's livecheck uses) and picks the **max** `sparkle:shortVersionString` across all items — feed items are not reliably ordered (older builds can carry a more recent `pubDate`). Routes the update through the app's own updater, never brew |
| 5 | Postman Squirrel feed | Postman (`com.postmanlabs.mac`). Self-updates via Squirrel.Mac (ships **no** Sparkle `SUFeedURL`, so the generic Sparkle path can't see it) while the Homebrew cask `postman` is `auto_updates` and its version lags the real channel — so `brew outdated` and the cask-version check both report it current (the exact case MacUpdater catches but `brew` misses). The checker GETs Postman's own Squirrel feed `dl.pstmn.io/update/osx_64/<installed>` and reads the `name` field (200 = newer build available; 204 = current). Uses the `osx_64` channel deliberately — it carries the live universal build even on Apple Silicon, where `osx_arm64` is stale. Routes the update through the app's own updater, never brew (the cask would reinstall the older build) |
| 5 | Discord Squirrel feed | Discord stable / PTB / Canary (`com.hnc.Discord`, `…PTB`, `…Canary`). The desktop host self-updates through a Squirrel.Mac server and ships **no** Sparkle `SUFeedURL`, while the `discord*` casks are `auto_updates` and lag — so neither `brew outdated` nor the cask-version check sees the new build. The checker GETs `.../updates/<channel>?platform=osx&version=<installed>` and reads `name` (200 = newer build, 204 = current), the same vendor-feed pattern as Postman and ChatGPT |
| 5 | Signal release feed | Signal Desktop (`org.whispersystems.signal-desktop`). Self-updates via electron-updater with no Sparkle feed, while the `signal` cask is `auto_updates` and lags. The checker reads the first top-level `version:` line of Signal's `latest-mac.yml` electron-updater feed |
| 5 | Chrome Version History API | Google Chrome stable / beta / dev / canary (`com.google.Chrome`, `…beta`, `…dev`, `…canary`). Chrome bumps its own bundle through Keystone outside Homebrew, so the `google-chrome*` casks' metadata goes stale (`BrewCaskDriftFilter` only hides that after the fact). The checker queries Chrome's public Version History API per channel and takes the **max** version, because the feed order is not contractually newest-first |
| 5 | Obsidian desktop releases feed | Obsidian (`md.obsidian`) loads self-updated `obsidian-X.Y.Z.asar` packages from Application Support independently of the installer in `/Applications` and the `auto_updates` Homebrew cask. The checker reads the effective ASAR version, follows the `beta` version when `obsidian.json` enables the Catalyst insider channel, and runs even when Brew correctly reports the installer cask as current. The action opens Obsidian so its signed in-app updater downloads and applies the package |
| 4 | JetBrains Data Services | IntelliJ IDEA, PyCharm, WebStorm, GoLand, CLion, Rider, DataGrip, RubyMine, PHPStorm, DataSpell, Aqua, RustRover (14 IDEs) |
| 3 | GitHub Releases API | VS Code, Rectangle, AltTab, Stats, Maccy, MonitorControl, LinearMouse, IINA, HandBrake, Keka, GitHub Desktop |
| 3 | Synology Release Notes API | Synology Drive Client (`/api/releaseNote/findChangeLog?identify=…`); compares the build number after the dash (e.g. `4.0.3-17892`) against `CFBundleVersion` because Synology's CFBundleShortVersionString and installer version use unrelated numbering schemes |
| 2 | Homebrew Cask | Any cask where `brew info` reports a newer version; uses `brew list --cask --versions` as authoritative installed reference |
| 1 | Sparkle | Any non-brew app that exposes `SUFeedURL` in its `Info.plist`, plus a curated override map for Electron-based apps (e.g. Codex) that ship Sparkle but set the feed URL programmatically |

4. **Version normalisation** — a shared `VersionComparison` module handles every version format seen in the wild: `7.0.0 (77593)` vs `7.0.0.77593` (Zoom), `125.0` vs `125.0.0` (Google Drive), `5.3.1,50301` Homebrew comma-format, `0.4.13+1` semver build metadata, and `v1.12.7` / `release-3.5.8` / `v1.4.2-build164` GitHub tag prefixes. `isUpgrade` uses `lexicographicallyPrecedes` so a locally-ahead app (e.g. Logi Options 10.9.0 when brew tracks 10.7.0) is never reported as outdated. Comparison respects each source's semantics (REL-11): `compareVersions(_:_:scheme:)` reads npm and GitHub versions as strict **SemVer** — a prerelease ranks *below* its release, and a `-NNN` hyphen is a prerelease identifier — while vendor/Sparkle/Homebrew sources use `.buildNumbered`, where the same `-NNN` (and Zoom-style `" (NNN)"`) is a *build number* that only breaks a tie when both sides carry one, so `7.0.0` vs `7.0.0 (77593)` is not a phantom upgrade in either direction. An unparseable value (e.g. a git-hash "version") yields `.unknown`, and `isUpgrade` gates on it rather than inventing an order.
5. **Act** — each update source drives its own action: brew casks run `brew install --cask` with a live log panel; JetBrains apps open Toolbox; GitHub apps open the Releases page; Sparkle apps prompt inside the app itself; self-updating apps whose cask lags (Antigravity, ChatGPT, Postman, Parallels) are launched so their own updater takes over (never routed through brew, which would reinstall the stale cask); npm globals are bumped with `npm install -g <pkg>@latest`.

Before any of this, `runCheck()` calls `brew update` so a freshly-published cask/formula version that hasn't landed locally yet is still seen.

### npm globals (third package manager)
`NpmGlobalChecker` finds outdated global packages in a **single** `npm outdated -g --json` process — one Node run for the whole scan, instead of the old unbounded `npm view <pkg> version` fan-out (one Node process per installed global) (ARCH-03). `npm` itself and `corepack` are filtered out (managed by the Node distribution, not user-actionable here). The npm binary is located across Homebrew, Volta, fnm, and nvm install layouts — and as a last resort by asking the login shell (`$SHELL -lc 'command -v npm'`) — and that resolved location is **cached for the scan**, so the globs and login-shell spawn don't repeat. When npm reports a registry/network error (a bare failure, or an `{"error": …}` payload), the scan **surfaces it as a failed source** rather than silently reporting an empty list, so a partial or total npm failure is flagged honestly instead of read as "nothing to update". (Installed globals are still enumerated with `npm ls -g --json --depth=0` for the inventory view.) This is what catches cases like the OpenAI Codex CLI being installed both as a Homebrew cask (up-to-date) and as `@openai/codex` under fnm (outdated) — brew alone would report nothing to do.

## Features

### Update

One screen that checks every source in one pass, shows the exact commands before running
them, and reports one honest outcome per item afterwards.

#### What it checks

Homebrew formulae + casks (greedy), Mac App Store, npm globals, and every manual-app
checker, in one pass.

- **Homebrew is optional.** Without it Wega still checks the Mac App Store, Sparkle, the 13
  vendor feeds and npm, and shows an *"install Homebrew to unlock more updates"* card
  instead of a wall.
- **A missing tool is not a failure.** A tool that is not installed is classified as **not
  applicable** (`SourceCheckOutcome.notInstalled`), never as a failed check — so a machine
  without brew no longer wears a permanent red "the list may be incomplete" banner over a
  list that is complete.
- **Grouped by install origin.** Updates are grouped by the same `AppOrigin` the Inventory
  window badges by, so a self-updating Homebrew cask like Docker or Postman appears under
  **Homebrew Casks** — never "Manually installed" — keeping the two windows in agreement.
- Selectable list — update all or pick individually.

#### Before anything runs — the dry-run panel

**"Show exactly what I will do"** expands a **dry-run panel** above the update button. It
shows the literal commands (`brew upgrade --cask -- a b`, `npm install -g -- x@latest`, …,
where the `--` fences package names off from option parsing — SEC-10) read from
`UpdatePlanner.commands(for:)` — *the same call the upgrade itself executes*, so the preview
cannot drift from reality, and **nothing outside that list runs**: an update no longer ends
with a global `brew cleanup` (it used to, even after an npm-only or App-Store-only run and
after a failed one, wiping the cached previous versions a recovery would reinstall from).

Per cask it also shows:

- the download host;
- whether Homebrew will verify its checksum;
- whether the rollback net covers it;
- whether it **may** ask for an admin password (a `pkg`/`installer`/`preflight` stanza is
  visible in the JSON; its contents are not, hence *may*);
- the download size from a `HEAD` probe. Homebrew's JSON carries no size, and a CDN may
  withhold `Content-Length`, so **"size unknown"** is a first-class answer shown as itself.
  The same measured sizes feed `DownloadGate` instead of the hard-coded 200 MB it used to
  assume.

#### One count, everywhere

The window header, the sidebar badge, the menu-bar badge and the background notification all
read the same `UpdatePlanner.unifiedCount`, and the header names both halves of it — *"12 to
install + 3 manual"* — because they behave differently. The **Update all (N)** button counts
only the installable half, so it never promises an upgrade Wega cannot perform. A scan run
from the window reports its result to the menu-bar agent, which is the single owner of the
dock badge.

#### The window opens with a result, not an empty screen

The last scan is restored the moment the window appears — from disk (`ScanResultStore`, a
`Codable` snapshot) or from the lists the menu-bar agent already built during its last
background check, whichever is newer. An old result never passes for a fresh one:
`ScanFreshness` decides, and anything a day old reads *"Found 12 Jul, 21:14"* in a warning
tint instead of a bare time. Progress during a scan is **real** — the scan is strictly
sequential (brew → mas → npm → manual), the bar reports the phase it is genuinely in, and
**Cancel** stops it where it stands. Live log streamed into an inline panel.

#### Running the update

- **Checking never mutates your system.** `brew update` runs before the outdated check — but
  **not** on the post-upgrade re-query, which is a plain `brew outdated` with no second
  metadata refresh and no second stale-cask sweep. Casks Homebrew still tracks but whose app
  is gone are *detected*, excluded from the list (so the count never offers an upgrade for an
  app you don't have), and offered as a **"Deregister"** card — Wega does not run
  `brew uninstall --force` behind a button labelled "check for updates".
- **An interrupted previous upgrade recovers itself.** A cask upgrade that fails because
  brew bails with "already an App at '…/Caskroom/…'" — the leftover staged app from a
  cut-short upgrade (the tell-tale `…upgrading` version) blocking it — is **automatically
  retried once with `--force`**, which overwrites the leftover and completes; without that it
  would fail on every attempt until cleaned by hand.
- **Restart after update.** Any running app whose bundle the upgrade just replaced is
  detected **by bundle URL — across the whole catalog, not a 16-app hardcoded list** — and
  offered a one-click restart (`RunningCaskDetector` matches each upgraded cask's resolved
  bundle against the live applications; the restart map only *overrides* the process/app name
  to quit and reopen for apps whose running process is named unusually, e.g. the `zoom` cask
  running as `zoom.us`).

#### When a check can't complete

Offline or with a source down, the screen says **"couldn't check — check your connection"**
instead of falsely reporting "everything up to date" — **and it stays said across a
restart**: the snapshot records what each source answered, its error and whether the scan was
complete (`ScanSourceReports`), a Brew result that never arrived is stored as *absent* rather
than as an empty list, and a failed `brew update` counts as a silent source instead of being
discarded. A restored scan that was incomplete raises its own banner, and an empty list from
one reads *"I can't tell whether everything is up to date"*.

#### Publisher baseline safety

Immediately before a cask upgrade, Wega reads the installed
bundle's Team ID and compares it with the known-good publisher. If the installed bundle
already differs, Wega blocks that cask before snapshotting or running `brew` and raises a
sticky security alert. A different post-upgrade Team ID never replaces the baseline: Wega
restores the pre-upgrade snapshot from a working copy. Replacement flows carry the
pre-mutation Team ID directly into the canary and resolve the installed bundle again after
Homebrew returns, so validation and rollback follow an app that moves between
`~/Applications` and `/Applications`. Resolution retains the exact snapshotted artifact
name and bundle ID, so a cask that installs several apps cannot redirect validation or
rollback to its first arbitrary artifact; a missing or ambiguous target fails closed and
retains the snapshot. In particular, the same artifact existing in both `/Applications`
and `~/Applications` is ambiguous rather than resolved by preferring one directory.
After a publisher mismatch, the original snapshot remains available even after a
successful rollback. A bundle-identity mismatch preserves it in the same way; only a fully
healthy upgrade deletes it after the canary window.

#### The rollback net

Each Homebrew cask row carries a **🛡 rollback badge**: a shield where snapshot → canary →
auto-rollback covers the upgrade, and an honest **"no protection"** slash where it cannot (a
cask that installs no `.app` — a bare `pkg` or `installer` — has nothing to clone; that hole
is now logged as a warning instead of being skipped silently).

The badge promises only what happens *during* the upgrade; there is no general manual
"Undo": healthy upgrades delete their snapshots after the canary window, while
publisher-mismatch snapshots are retained for recovery. The bundles the guard clones are
located **when the upgrade starts** (`CaskAppPathResolver`), not when the scan ran — so the
net also covers the most ordinary flow there is: open Wega, look at the list it restored from
disk, press *Update all*. Banners **queue** rather than overwrite, so a *publisher changed*
alert is sticky and survives the upgrade summary that used to clobber it.

#### What a green banner means

**A green banner means every phase succeeded.** An upgrade is one result per item
(`UpdateRunOutcome`) built from all four phases — the package manager's own verdict, the
Gatekeeper canary, the rollback, and the post-upgrade rescan — and *"Zaktualizowano N
pakietów"* appears only when every item cleared all of them.

- A `mas upgrade` that failed, a cask the canary rolled back, and an item the fresh scan
  still lists all read as **"Aktualizacja niekompletna"**, naming what did not make it.
- An upgrade the rescan could not confirm (its source went silent) says so instead of passing
  as verified.
- A **rollback that failed** — the new version rejected *and* the old one not restored —
  raises its own **red sticky banner** telling you to check that app before using it, rather
  than a line in the collapsible log under a green headline.

#### Per-row control

**Use the ⋯ menu on any row** — or right-click it — to **ignore** an update ("don't update
Zoom") or **pin a version** ("pin Parallels to 18" — only updates up to that ceiling are
shown); rules are managed from the Settings window (⌘,) and persist across launches.

Two colour codings carry meaning:

- **The version target** is coded by change kind: **honey** (normal bump), **caramel** (major
  version bump), **toffee** (forced/`--force` update), **red** (security fix).
- **The source badge** is coded by **provenance family** (`Provenance`, unit-tested in Core)
  rather than one flat blue: Homebrew (honey), App Store (blue/info), JetBrains (coral),
  GitHub (lavender), Sparkle (lavender), Synology (blue/info), and the self-updating
  vendor-direct apps — Antigravity, Parallels, Google Drive, ChatGPT, Postman, Discord,
  Signal, Chrome — share **success green**. So the 16 update sources — 13 vendor checkers
  plus Homebrew, the Mac App Store and npm — read as 7 visually distinct families at a
  glance.

#### The detail inspector

The inspector starts collapsed so the main window can complete its initial layout safely,
then opens automatically when you **select any update** — click its row (the checkbox still
toggles it for batch update independently). The toolbar button can show or hide it at any
time. On the right it carries the app icon, name and version arrow up top, then four
sections:

- **Zaufanie (Trust)** is the differentiator — for a real installed `.app` it verifies, **off
  the main thread**, the code signature (Gatekeeper), the signing **Team ID against a local
  ledger** (a *changed publisher* is flagged loudly as a possible takeover — a supply-chain
  signal no competitor surfaces, reusing the same `TeamIDLedger` the post-update watchdog
  writes — for a Homebrew cask it reconciles the watchdog's `cask:<token>` key with the app's
  real bundle id, so a cask whose publisher the watchdog has been tracking correlates as
  *unchanged/changed* instead of falsely reading as a first sighting — but **read-only** so
  inspecting never mutates the baseline), and, for Homebrew casks, whether the download is
  **checksum-verified**. Batch items with no inspectable bundle (formulae, npm, App Store)
  honestly read *"weryfikacja niedostępna"* rather than a faked verdict.
- **Szczegóły** lists versions, install origin and path.
- **Co nowego** shows real release notes when the source provides them (with the AI-triaged
  "possible security fix" advisory) and says so plainly when it doesn't; the same notes are
  now also **inline on the row**, behind a *What's new* disclosure, for every manually-checked
  app whose source publishes them (GitHub release bodies, Sparkle `<description>`, JetBrains
  `whatsnew`). Vendor HTML is untrusted input — `ReleaseNotesText` in Core strips every tag
  and drops `<script>` / `<style>` bodies whole before anything reaches the window, without
  going near WebKit.
- **Akcje** reuses the row's own per-source update control.

The probe runs in a `.task(id:)` that **cancels and restarts** as you change selection, so it
never blocks the list or shows a stale verdict.

### Accessibility
Update and uninstall selections are native keyboard-focusable controls with VoiceOver labels and explicit selected/not-selected values. In the package-manager update list, **Return** opens the focused row in the inspector and **Space** toggles its batch selection; on manual-update rows either key opens details because those rows have no batch-selection checkbox. Select-all controls are buttons rather than pointer-only gestures. The uninstall confirmation is a correctly sized native sheet with destructive/cancel roles, **Enter** and **Esc** shortcuts, and the exact frozen targets shown before execution; long target and ambiguity lists scroll while the action buttons remain pinned, including at large text sizes. Its **App only** / **App + leftovers** choice also announces the selected state to VoiceOver. Selection rows use semantic fonts so large environment text can reflow. The **Updates scan status on the sidebar icon** no longer relies on colour alone: a failed scan swaps the icon's **symbol** (a warning glyph, not just a red tint), and every scan state — checking, checked-clean, failed — is announced to VoiceOver as the row's value, so the outcome reaches users who cannot distinguish the colours. With **Reduce Motion** enabled, the rotating sidebar artwork, cycling thought bubble, Wega motion and binary stream all render without continuous movement; rebuilding its parent does not replace the static binary frame. An **Aktualizacje** menu carries the app's keyboard shortcuts, macOS-conventional: **⌘R** *Sprawdź teraz* (start a scan), **⌘⏎** *Aktualizuj* (opens the same update confirmation the toolbar button does, on the Updates destination), **⌘1…⌘5** to jump to the five sidebar sections in order (Updates, To reattach, Inventory, Uninstall, Logs), and **⌘F** *Find in inventory*, which opens the Inventory list and focuses its search field. Each shortcut is greyed out exactly when its on-screen control is unavailable.

### Uninstall
Scans every app on the system regardless of origin. Brew casks are removed with `brew uninstall --cask`; App Store and manually installed apps are moved to Trash. The confirmation dialog offers **"App only"** (the default, and the recommended one) or **"App + leftovers"** (`--zap`, which also deletes preferences, caches and Application Support) — the irreversible option is a deliberate choice, never the preselected one. It shows exact counts: how many casks are affected, how many go to Trash. If the selected `--zap` operation fails, Wega reports that item as incomplete and leaves it selected; it never silently retries without zap using `--force` or counts that changed operation as success. **"App + leftovers" is no longer brew-only** (UX-13): for App Store and manually installed apps the dialog lists the `~/Library` items the app left behind — built by the same `MigrationPlanner` per-bundle-id planner Wega already trusts (`LeftoverCleanup`) — as checkboxes, each ticked by default, and moves the ones you keep ticked to the **Trash** (recoverable, never a permanent delete). So the "app + leftovers" promise now holds whatever the app was installed from; leftover moves that fail are reported, not swallowed. **A scan that can't read a source is never shown as an empty machine**: when it finds nothing it says *"the scan failed"* rather than *"no apps found"*, and when it still found some apps the confirmation dialog warns that the target list may be incomplete before anything is removed — a destructive choice is never made on silently partial data. **Right-click any row** to reveal it in Finder, copy its path, or toggle whether it is marked for removal — the same per-row context menu the update list already offers.

### Migration
Finds manually-installed apps that have a Homebrew Cask equivalent and offers to migrate them with `brew install --cask`. Runs `mas search` in parallel for apps without a cask match to find App Store equivalents. Running detection covers every matched app: the exact standardized/resolved bundle path wins, with a unique bundle ID as fallback; ambiguous duplicate bundle IDs stop the migration. Wega sends that exact process a normal application **Quit** request and waits for it to stop. Only an app that remains open produces a separate warning about unsaved data; after explicit consent Wega identifies the target again, sends `SIGKILL` only to that PID, and confirms the app stopped. A failed or ambiguous force-quit cancels the migration instead of being ignored. A match too weak to trust (the **"niepewne"** / low confidence level) is refused before anything runs: since `brew install --cask --force` overwrites the app in place, a low-confidence `.app`→cask match could replace it with a *different* program, so Wega blocks the automatic takeover and asks you to verify the token manually (`MigrationAutoTakeover` consuming `CaskMatchConfidence.allowsAutoConfirm` — the confidence score now gates execution, not just the badge). Before Homebrew replaces an existing `.app`, migration takes the shared upgrade mutex, passes the same hard disk/network/power gate as an upgrade, verifies and preserves the installed publisher baseline, and requires a copy-on-write snapshot. The installed result must pass the shared Gatekeeper/Team-ID canary; otherwise Wega restores the snapshot and reports failure. The manual cask-adoption action in Updates uses this same protected transaction, so neither `brew install --cask --force` entry point can bypass it. A successful brew migration ends there: Wega **touches nothing in `~/Library`**. The old "clean leftovers" sheet was removed (SEC-01) — for a migration the app keeps its bundle id, so those "leftovers" are the live Application Support, preferences and container of the app you just adopted, and the sheet offered to delete them permanently with everything preselected. **npm ↔ brew duplicate row** — for CLIs installed via both `npm -g` and Homebrew (e.g. `@openai/codex` + `codex` cask), inline "Usuń z npm" / "Usuń z brew" buttons run the corresponding uninstall (`npm uninstall -g -- <pkg>` via `NpmGlobalService.uninstallEvents`, or `brew uninstall -- <token>`; the `--` terminator is SEC-10) after a confirmation alert; the duplicate disappears from the list on exit 0.

### Inventory
Full list of every `.app` on the system with source badge (Brew / App Store / Manual), version, bundle ID, and last-modified date. Filterable by source, sortable by any column, searchable by name or bundle ID. Four stat cards at the top show counts per category — tap any card to filter. Any app Wega has **no known way to update** — not managed by Homebrew or the Mac App Store, and absent from the `AppCatalog` (so a hand-installed app the catalog already tracks does *not* qualify) — carries a **report button** in its source cell: one tap opens a prefilled GitHub issue (built by `CatalogIssueBuilder`) asking the maintainers to add update support, closing the community-catalog loop from the UI. **A failed scan is never passed off as a complete one**: each source (Homebrew, the cask catalog, the filesystem, App Store, npm) is tried independently, and any that fail are collected per source and raised as a banner over the table naming them — so a partial list reads as partial instead of as an authoritative empty or short list. **Export** — the toolbar's *Eksportuj* menu writes the whole inventory (not the filtered view) to a chosen location as a **Brewfile** (a `brew bundle` manifest: Homebrew casks and Mac App Store apps become installable `cask` / `mas` entries, while manual apps and global npm packages are preserved as comments so the file stays a faithful record even though `brew` cannot reinstall them) or as a **CSV** (one row per app, followed by the npm globals). The bytes are built by `InventoryExport` in the core module — deterministic and locale-independent, so re-exporting an unchanged inventory yields an identical file — and unit-tested without a save panel.

### Settings
App settings live in the **native macOS Settings window**, opened with **⌘,** or the **gear button** in the window toolbar — not a sidebar tab (macOS users expect app settings there). Real-time diagnostics: Homebrew version, mas-cli version, Privileged Helper status, macOS version, CPU architecture. App version, build, links. License block for bundled open-source tools. **Language card** — switch the interface between **Polski** and **English**; the choice is persisted and applies live, and switching it keeps the current scan results (and a running upgrade) intact. Until you pick one, the language follows the system locale — Polish only when macOS reports it ahead of the other languages Wega ships, **English otherwise**. **Scan directories card (UX-16)** — add your own scan roots via a directory picker (stored as **security-scoped bookmarks**, so apps on other volumes and in non-standard locations are found), list **exclusions** that are never searched, and set the **recursion depth** (how many sub-levels below each root to descend, default 1). The scan seams read these keys from `UserDefaults` on every scan, so a change takes effect on the next scan. **Resource gate card** — configures the large/unknown download estimate, low-battery threshold, unpacked-size multiplier, and free-disk safety margin used by both window and unattended preflights. **Ignored & pinned card** — lists every ignore / version-pin rule with a one-click remove. **Touch ID for sudo card** — on Macs with biometry hardware, shows whether `pam_tid.so` is wired into `/etc/pam.d/sudo_local` and offers a one-click enable. **App catalog card** — pulls the latest `AppCatalog` overlay from its canonical source on demand (the app also refreshes it on launch); reports the outcome and notes that a fetched update applies on the next launch.. **Unverified endpoints configuration card (SEC-08)** — appears only when an `endpoints.json` overlay is applied without a valid signature, surfacing the presence of that unverified configuration to the user rather than leaving it in the log.

### Logs
Full activity log covering scans, source responses, install results, and errors — newest entry first. It retains menu-bar and background-source failures (including Brew stderr), exhausted HTTP retries, process aborts, rejected self-update signatures, helper installation failures, and failed rollbacks, so **"Zobacz w logach"** leads to the underlying cause rather than only a summary. Filter by severity (All / Warnings+ / Errors only), search by text, copy entries to the clipboard, or reveal the log file in Finder. When a source fails to respond and the Updates screen shows the "list may be incomplete" warning, the button jumps straight to this tab pre-filtered to errors. The log is also written to `~/Library/Logs/WegaMacUpdater/wega.log`; once the file exceeds ~5 MB it rotates to `wega.log.1`, keeping one backup. The privileged root helper separately writes rejected XPC connections and per-operation audit results to macOS Unified Logging.

### Menu-bar agent
A box icon lives in the menu bar, **badged with the number of available updates**. On a configurable schedule (off / hourly / every 6 hours / daily, default every 6 hours) it runs a **read-only** background check — never `brew update`, never a mutation — and posts a notification when new updates appear. **A background check never raises the macOS permission dialog**: the first time the agent has something to announce, Wega shows an explanation card in its own window, and only a user who accepts it spends the one-shot system prompt (`NotificationPrompt` in Core decides this; declining is remembered, so the card never returns).

**Background updates (opt-in, per app)** — from a row's ⋯ menu you can let Wega upgrade a cask unattended. The Settings window keeps a durable audit of every consent—including packages no longer present in the current update list—with its grant date, revoke action and a current per-package reason: ignored/pinned policy, no update waiting, unresolved installed app, running app, unsafe metadata, or readiness for the final checks. While Settings is visible, that verdict refreshes after app launches or exits, after returning to the active lifecycle, and periodically for Homebrew's outdated state; rapid lifecycle events are debounced and every Homebrew read shares the app-wide read/write coordinator. Every safety condition must hold, and the default answer is no: you opted this app in; the cask installs an `.app` and only `app`/`binary`/`zap` artifacts (no `pkg`/`installer`/`preflight` hook); Homebrew has a concrete `sha256`; no ignore/pin rule applies; and the app is not running. Metadata alone is not enough: Wega must resolve the installed `.app` and successfully create its copy-on-write snapshot in that exact round. A missing path or failed snapshot vetoes that token before `brew` starts, leaving it for the user-present window flow. Snapshot feasibility, resources and publisher safety are deliberately checked only immediately before the unattended update, not speculatively from Settings. After acquiring the upgrade mutex, Wega checks policies and running processes again so a decision made while the round waited cannot be stale. Sudo-requiring and binary-only casks are excluded *by construction*, not by preference. Before any snapshot or payload download, the same hard resource gate used by the window checks metered/Low Data Mode networking, battery level, thermal throttling and free disk. Its disk budget is the download plus estimated unpacked payload plus the full allocated size of the rollback snapshot plus a safety margin. Unknown sizes use the configured estimate; an unreadable capacity fails closed. A veto postpones the round and persists its reason in Wega's log.

The upgrade runs through the **same** snapshot → Gatekeeper-canary → auto-rollback chain as a foreground one (`CaskRollbackGuard`, shared by both) — automatic recovery is precisely what makes updating unattended defensible. A mutex guarantees a background upgrade and a window upgrade never overlap; the window always wins. Any non-zero global brew exit invalidates every token in the unattended batch, even if brew names only one failure. The completion notification reports **every** outcome of the round, not just the successes: how many were upgraded, how many were rolled back, which one's rollback *failed*, and which one changed its publisher's Team ID. The unattended path re-queries `brew outdated` afterwards, so a cask that still shows up as outdated is not counted as upgraded. The badge and notification are derived from one post-upgrade result, and newness is compared by the update identifiers' fingerprint rather than their count. This is **not a daemon**: it lives in the menu-bar agent, so nothing happens while Wega is closed — which used to mean the schedule, badge, notifications and silent updates all died at the first restart of the Mac, until you launched Wega again by hand (background mode was a promise that held only until the first reboot). **Settings (⌘,) now carries an explicit „Uruchamiaj przy logowaniu" (Launch at login) toggle** (BG-02), built on `SMAppService.mainApp` — the same modern registration mechanism the privileged helper uses (`SMAppService.daemon`), one tier up. It shows the login item's **real system status** (never a stored guess), lets you switch it off, and when on, macOS relaunches Wega at login so `AppDelegate` restarts the menu-bar agent and background mode keeps working across a reboot instead of dying at it. The honest framing is *safe = automatic, the rest = one click*. The dropdown shows the current status, last-check time, **the names of the apps that have updates** (UX-11g — so it says *which* apps, not only *how many*; the list is filtered by the same ignore/pin rules as the badge and capped, with the rest folded into an „i jeszcze N" line), **Check now**, **Open Wega**, the interval picker, and **Quit**. Closing the window keeps the agent running; ignore/pin rules are honoured by the background count too. Notifications are gated on a real app bundle, so `swift run` degrades gracefully.

## Architecture

```
WegaMacUpdater (SwiftUI app target)
├── ContentView          — sidebar + tab routing; brew-not-found gate; toolbar `SettingsLink` (gear → Settings window). The sidebar's helper chip reports the privileged helper's **real** `SMAppService` status in three states (active / needs approval / inactive, mapped by `HelperChipState` in Core) — a green dot is earned, not hard-coded, and the "needs approval" state opens Login Items on click
├── SettingsView         — native `Settings {}` scene (⌘,); hosts `InfoView` where macOS users expect app settings
├── CaskReplacementSafety — shared preflight/snapshot/canary transaction for UI paths that replace an existing app with `brew install --cask --force`
├── UpgradeCoordinator    — app-side state machine for every Homebrew/app-bundle mutation; routes foreground upgrade, background upgrade, metadata refresh, migration, duplicate cleanup, uninstall and self-update installation/opening through the shared read/write operation boundary
├── UpdateView           — multi-source update orchestrator (renders `ScanStore`; owns no scan state itself)
├── ScanStore            — `@StateObject` held by the `App`, **above** the `.id(localization.language)` re-key: owns the scan/upgrade state and the tasks that write it, so switching language mid-scan neither drops the results nor orphans a running upgrade
├── UninstallCoordinator / UninstallView — stateful scan/uninstall boundary plus the all-app-type uninstaller UI; Homebrew and Trash I/O stay in the coordinator
├── MigrationStore / MigrationView — app-owned manual→brew/mas migration state machine plus its wizard; all scan, process, network, filesystem and App Store-opening work lives in the store while the view only binds state and sends intents. The store is injected above `.id(localization.language)`, so a language switch preserves a running migration, consent sheet, log and results
├── InventoryStore / InventoryView — read-gated Homebrew/MAS/npm/filesystem inventory loader plus its bindings-and-intents UI; the complete snapshot holds one shared read lease, so it cannot observe a half-finished mutation
├── SelfUpdateController / TouchIDSetupController — injectable state machines that own self-update network/filesystem work and bounded Touch ID helper/manual-Terminal setup outside `InfoView`; the self-update install/open phase shares the exclusive mutation gate and quit guard with Homebrew operations
├── InfoOperationsController / InfoView — Settings-side diagnostics, catalog, Keychain and helper I/O live in the controller; `InfoView` is the bindings-and-intents UI hosted in the Settings window, not a sidebar tab
├── SharedViews          — buildScanDirs(), WegaBadge, WegaCard, PackageRow, EmptyHero…
├── MenuBarAgent / MenuBarScene — menu-bar `MenuBarExtra` (badge + dropdown) driven by `MenuBarAgent` (timer loop, notifications, persisted interval); `AppDelegate` keeps the process alive after the window closes, and on launch enforces a **single running instance** (`SingleInstanceGuard` + `NSRunningApplication` by bundle id) so a second copy stands down instead of driving `brew` in parallel with the first and racing for its lock
├── LaunchAtLoginController / LaunchAtLoginSettingsCard — BG-02 „Uruchamiaj przy logowaniu" toggle: registers/unregisters the app itself as a login item through `LoginItemService` (a `LoginItemManaging` seam over `SMAppService.mainApp`, in Core) and always re-reads the **real** system status afterwards (`LoginItemState`, mapped like `HelperChipState`), so macOS relaunches Wega at login and the menu-bar agent's background mode survives a restart of the Mac
└── Localization         — `tr()` / `trf()` / `trp()` route every UI string through `LocalizationManager`, switchable between **Polski** and **English** from the Settings window (⌘,) and persisted in UserDefaults — the language switches **live**, without relaunch. With nothing persisted the first launch resolves the language from the system locale via `defaultLanguage(preferredLanguages:)` in **MacUpdaterCore** (`AppLanguage.swift`): the first preferred language Wega actually ships wins, and everything else — including an empty list — falls back to **English**. Polish is the base text in the views; the translation table (`Translations.en`) lives in **MacUpdaterCore** so it's unit-testable, and `LocalizationCompletenessTests` scans the app sources for every `tr("…")` / `trf("…")` literal and **fails CI if any key lacks an English counterpart** — turning a would-be silent Polish fallback into a build error. Counter strings use `trp(base, count)` (**UX-08**), which picks the grammatically-correct one/few/many form from `Plurals` — Polish rules (1 · 2–4 except 12–14 · the rest), with English collapsing to singular/plural — so the menu bar reads „1 aktualizacja dostępna", not „1 aktualizacji dostępnych". `LocalizationManager` (the live-switch `ObservableObject`) stays app-side. The runtime-switchable design is deliberate: native String Catalogs (`.xcstrings`) resolve at the system locale and can't switch in-app without a relaunch

MacUpdaterCore (library target — no SwiftUI dependency)
├── OperationCoordinator — fair, cancellation-aware actor-based read/write gate: reads may overlap, writes are FIFO and exclusive, and a queued write prevents later reads from starving it. Identifiable cancelled waiters are removed before their closures can run; explicit, validated leases allow safe write→read nesting while foreign, expired and read→write leases fail fast instead of deadlocking. Nested operations are retained until their own async closures finish, so even a child task cannot outlive the outer lease and accidentally admit a conflicting writer
├── ApplicationScanner   — filesystem scan, Info.plist parsing, brew/mas tagging
├── BrewService          — brew outdated (greedy), install, uninstall, cask versions
├── MasService           — mas outdated, list, search, upgrade
├── HTTPClient           — one shared HTTP client behind all 13 vendor checkers + CaskDatabaseClient: uniform 15s/30s timeouts, a single `User-Agent` (`WegaMacUpdater/<version>`), transient-failure retry with exponential backoff (429 + 5xx + network errors), and ETag conditional requests. The GitHub checker enables ETag so a `304 Not Modified` reuses the cached body **and does not count against GitHub's unauthenticated 60-req/h rate limit**. The transport is a protocol seam (`HTTPTransport`) so the retry/ETag logic is unit-tested with a fake, no network
├── ManualCheckResult    — every manual checker returns `.notApplicable` / `.upToDate` / `.outdated` / `.unavailable` / `.failed` instead of a bare `Optional`, so a network failure is no longer indistinguishable from "current". `.unavailable` (a transport error or 5xx server response) is a transient upstream outage: it logs at WARNING and is **not** counted toward the "list may be incomplete" banner, while `.failed` (a 4xx, or a 200 we couldn't parse) logs at ERROR and is counted. `UpdatePlanner.scanState` folds the totals into `upToDate` / `outdated` / `checkFailed` / `partialFailure`, and the Update screen shows "couldn't check — check your connection" instead of a false "everything up to date" when offline
├── UpdatePlanner        — pure orchestration logic lifted out of UpdateView: builds the selectable outdated list (with load-bearing source-tagged keys), routes a selection back to per-manager upgrade commands, dedupes manual results by source priority, groups them by install origin (`groupManual`, so the Updates window's sections match the Inventory badges), derives the post-scan `ScanState`, and flags outdated casks Homebrew will install **without** a checksum (`casksWithoutChecksum`, the FEAT-03 "no checksum" banner — matched by cask **token**, since a cask row's `.name` carries the token while its `.key` carries the `c:` source tag) — all unit-tested without SwiftUI
├── AppOrigin            — the **single** install-origin classifier (Brew / App Store / npm / manual) shared by both windows: the Inventory badge and the Updates-window grouping (`UpdatePlanner.groupManual`) both derive from `AppOrigin.of(_:)`, so the two can never disagree about where an app came from (the Docker "Brew in one window, Manually installed in the other" class of bug). `ManualUpdateScanner` stamps it onto every outdated result; pinned by `AppOriginTests` + the grouping tests
├── InventoryExport      — **UX-11f**: pure, view-independent generation of the two inventory exports offered by the Inventory toolbar — a **Brewfile** (`brew bundle` manifest: Homebrew casks and Mac App Store apps as installable `cask` / `mas` entries, everything `brew` cannot address de-duplicated and sorted into comments) and an RFC 4180 **CSV** (one row per app, then the npm globals). Deterministic and locale-independent, so re-exporting an unchanged inventory yields byte-identical output; `InventoryView` only chooses a destination and writes the string. Pinned by `InventoryExportTests`
├── ManualUpdateScanner  — runs all nine manual checkers + the brew-cask version check over every installed app, stamps each result's install origin (via `AppOrigin`) and dedupes by source priority; shared by the Update screen and the menu-bar agent (one implementation, no divergence). `AppScanDirectories` provides the scan roots. The per-app checks fan out through `runBounded` (`BoundedConcurrency`) with a configurable cap (default 12 in-flight) so a large `/Applications` doesn't open one connection per (app × checker) and hammer the remote update APIs
├── MenuBarUpdateChecker  — read-only count of available updates (brew/mas/npm + ManualUpdateScanner, with policies applied) for the menu-bar badge and notifications; the complete round holds the shared read lease and never mutates the system
├── UpdateRunOutcome     — **one result per item and source**, covering every phase an upgrade has to clear: execution, canary validation, rollback and the post-upgrade rescan (`ItemUpdateVerdict`, plus `CaskValidationVerdict` for the canary's half). Both upgrade paths — the window and the background updater — accumulate into it phase by phase and read one `UpdateRunSummary` from it, so "we updated N packages" is a single computation instead of two hand-rolled inferences that each dropped a different phase. A later phase can only ever make a verdict *worse*, so a `healthy` canary over a bundle brew never replaced cannot talk a failed install back up into a success. It also carries the per-failure **detail lines** — the brew `Error:` block, or a synthesized exit-code note when brew said nothing — written verbatim to the log so a failed cask upgrade explains *why*, not just *that*, plus one line per item naming the phase it fell over in. Success is announced only when every item cleared every phase; `.rollbackFailed` and `.publisherChanged` are marked critical and reach the user as sticky banners and their own notification, never as a line in a collapsed log
├── UpdateFingerprint    — the identity of "what is available right now" (the sorted, source-tagged keys of every visible update, SHA-256'd), used as the background notification's watermark. It replaces a count comparison, which stayed silent whenever one update was installed and another appeared between two rounds. Stable across launches, because it is persisted between them
├── UpdateSchedule       — pure scheduling decisions (`shouldCheck` / `secondsUntilNextCheck`) + `CheckInterval` (off / hourly / 6h / daily), unit-tested without timers
├── UpdatePolicy         — per-app ignore / version-pin rules ("don't update Zoom", "pin Parallels to 18"). `UpdatePlanner.applyPolicies` filters both the brew/mas/npm list and the manual list: `.ignored` hides an item outright, `.pinned(version:)` hides only updates *beyond* the pinned ceiling (via `isUpgrade`). Identity is the source-tagged key for tracked items and `manual:<bundle ID>|<path>` for manual apps — the stable installation identity (REL-11), so a pin/ignore survives the vendor renaming the app across versions and keeps two copies of one app (`/Applications` vs `~/Applications`) as distinct targets. Pure and unit-tested; persisted app-side by `UpdatePolicyStore` (UserDefaults JSON)
├── MigrationPlanner     — pure orchestration logic lifted out of MigrationView: partitions scanned apps into matchable / App-Store / unmatched, filters the migration pool, builds `~/Library` leftover paths, and owns `DuplicateRemoval` (npm↔brew command preview) — unit-tested without SwiftUI
├── LeftoverCleanup      — UX-13 "app + leftovers" for apps installed outside Homebrew: `plan` reuses `MigrationPlanner`'s per-bundle-id builder and keeps only the `~/Library` items on disk; `removeToTrash` moves the consented ones to the Trash (never `removeItem` — SEC-01), reporting each success/failure. Both are pure (filesystem access injected), so the uninstall-and-clean path is unit-tested without a real home directory or Trash
├── MigrationAutoTakeover — pure gate that turns a `CaskMatchConfidence` into allowed / requires-confirmation / **blocked**, keyed off `allowsAutoConfirm`; `MigrationStore` consults it before `brew install --cask --force`, so a low-confidence match can no longer silently overwrite the wrong app (the score's first production consumer)
├── SingleInstanceGuard  — pure launch decision (`decide(otherInstanceCount:)`): another running copy ⇒ stand down. `AppDelegate` enumerates other instances by bundle id and terminates the duplicate, closing the one mutation race the in-process coordinator cannot see — two separate processes each driving `brew`
├── AppCatalog           — single source of truth for every per-app mapping (GitHub repos, JetBrains IDE codes, Synology identifiers, Sparkle feed overrides); decoded from the bundled `Resources/app-catalog.json` and overlaid (if present) by a user-writable `~/Library/Application Support/WegaMacUpdater/app-catalog.json`, so the catalog can be refreshed out-of-band without a new app build. **URL-typed fields are validated while decoding** — `synology.downloadPage` (handed straight to `NSWorkspace.open`) and `sparkleFeedOverrides.feedURL` must be absolute **https** URLs with a non-empty host (the same strict `URLComponents` contract `AppEndpoints` uses for its overlay), so a hostile catalog entry is rejected at decode time rather than opened / fetched later
├── CatalogIssueBuilder  — pure builder for a prefilled GitHub *new issue* URL that asks maintainers to add an app the catalog does not know (inputs: app name, bundle ID, optional detected `SUFeedURL`, optional version format). Percent-encodes title and body down to the RFC 3986 unreserved set and enforces a hard ~8000-char URL cap by truncating the body (never the title) on whole-character boundaries. Zero I/O, no `NSWorkspace` — the caller injects the repo's `issues/new` endpoint and opens the result
├── CatalogSignature    — Ed25519 (`CryptoKit`) verification of the signed config overlays. The publisher key is **injected**, not read from a `static let` inside `verify` — that is what makes the fail-closed branch testable, and it is how a find-and-replace that once pasted a real key over the placeholder sentinel *and* over the comparison it was compared against (reducing `isConfigured` to `key != key`, permanently false, every signature check silently off) is now caught by a test rather than by a reader
├── ConfigOverlayTrust  — the two overlays are trusted differently on purpose. `app-catalog.json` arrives from a repository that accepts pull requests and is **fail-closed**: no valid detached signature, no overlay. `endpoints.json` is a file the user places on their own disk to follow a moved feed, where a signature would protect nothing (whoever can write it can already do worse) — so it stays usable **unsigned** and each unsigned use is logged. Both refuse a signature that is present and *wrong*: that is tampering, not convenience
├── CatalogRefresher     — fetches the overlay catalog from a remote JSON source over the shared `HTTPClient` (ETag-conditional), **validates it by decoding before writing**, verifies its detached Ed25519 signature (`<source>.sig`), then writes **both** the catalog and the signature it verified. A body that is a valid catalog but whose signature does not match it reports **`signatureMismatch`**, distinct from `invalid` — the two are cryptographically indistinguishable causes (a tampered catalog, or a CDN that paired a fresh JSON with a cached `.sig`), and the UI says what happened rather than guessing who to blame. The previous overlay survives either way — `AppCatalog.loadOverlay` checks the signature again on the next launch, so the window between *written* and *read* is guarded too. The JSON lands first: a crash between the two writes leaves a catalog with no signature, which is rejected on read (falling back to the bundled catalog) rather than a signature vouching for the previous bytes — so a malformed or hostile body can never clobber a good overlay. The source URL is injected from `AppEndpoints` (the `appCatalog` endpoint, raw-hosted on GitHub) and the refresh is triggered both on app launch (fire-and-forget, ETag-conditional) and on demand from the Settings window's **App catalog** card
├── AppEndpoints         — single source of truth for every outbound URL (update feeds, GitHub/Synology/Parallels/Antigravity APIs, the `AppCatalog` overlay source, the Homebrew install command, UI links); decoded from the bundled `Resources/endpoints.json` as `{placeholder}` templates and overlaid (if present) by a user-writable `~/Library/Application Support/WegaMacUpdater/endpoints.json`, so a vendor that moves a feed can be followed without a new build. That overlay is applied **unsigned** by policy; an overlay carrying an *invalid* signature is refused. **SEC-08 keeps the whole config channel fail-closed, not just the catalog:** every overlaid field is validated or dropped before it can take effect — fixed endpoints must be absolute http(s) URLs with a host, **templated endpoints additionally require https and a host on the allowlist the bundled baseline already talks to** (an override that leaves that set or downgrades to http silently falls back to the baseline), and the **Homebrew install command is a shell string excluded from the overlay entirely** (always taken from the bundled baseline, never overridable). An applied unsigned overlay is **surfaced in the Info window** as a first-class warning (`overlayStatus`), not signalled by a log line alone. Keeping the literal URIs out of Swift is what lets each call site read its endpoint from a customizable parameter. Fixed macOS/Homebrew paths live separately in `SystemPaths` (deliberately hard-coded — routing e.g. `/usr/bin/sudo` through a writable file would be a security hole)
├── JetBrainsUpdateChecker — data.services.jetbrains.com, 14 IDE mappings (from AppCatalog)
├── GitHubReleasesChecker  — api.github.com/releases/latest, app mappings from AppCatalog
├── ObsidianUpdateChecker  — reads Obsidian's effective ASAR version and stable/Catalyst channel from its official desktop-releases feed; runs even for a Brew-managed cask
├── WegaSelfUpdateChecker  — Wega's own update check: latest GitHub Release tag vs `AppMetadata.version`, resolves the published `.dmg`/`.pkg` asset (surfaced in the Settings window). Pure, HTTPClient-injectable, unit-tested
├── SynologyUpdateChecker  — synology.com/api/releaseNote/findChangeLog, compares build number from versionString (`4.0.3-17892` → `17892`) against CFBundleVersion
├── AntigravityUpdateChecker — Google Antigravity IDE update endpoint; reads the product version from the download URL path (cask is stale, app self-updates)
├── ParallelsUpdateChecker  — `update.parallels.com/desktop/v<major>/parallels/parallels_updates.xml`; major derived from installed bundle, `<Major>.<Minor>.<SubMinor>` read from the feed (cask `parallels` lags, app self-updates)
├── GoogleDriveUpdateChecker — POSTs an Omaha v3 update-check to `tools.google.com/service/update2` with `appid="com.google.drivefs" ap="canary"` and parses `<manifest version="X.Y.Z.W"/>`; canary cohort reveals the patches (e.g. `126.0.5.0`) that Stable / 50-percent never advertise. Compares against `CFBundleVersion` (not `CFBundleShortVersionString`, which is only `126.0`)
├── PostmanUpdateChecker   — GETs Postman's Squirrel.Mac feed `dl.pstmn.io/update/osx_64/<installed>` and reads `name` (200 = newer, 204 = current); cask `postman` lags and the app ships no Sparkle feed, so this is the only source that sees the update. HTTPClient-injectable, unit-tested
├── ChromeUpdateChecker    — Google's version history API for the stable channel; Chrome bumps its own bundle outside Homebrew, so brew's metadata goes stale and this is what notices
├── ChatGPTUpdateChecker   — OpenAI's desktop appcast; the cask lags behind the app's own updater
├── DiscordUpdateChecker   — Discord's `updates/distributions/app` endpoint; another self-updating cask whose brew metadata cannot be trusted
├── SignalUpdateChecker    — Signal's release feed; same pattern — the app updates itself, brew reports the version it installed
├── SparkleUpdateChecker   — Info.plist (PropertyListSerialization, never Bundle(url:)) + CFPreferencesCopyAppValue fallback + `SparkleFeedOverrides` map (backed by AppCatalog) for apps that set the feed URL at runtime
├── NpmBrewDuplicateDetector — finds CLIs installed via both `npm -g` and Homebrew (surfaced in Migration)
├── NpmGlobalChecker       — outdated scan via one `npm outdated -g --json` process (`npm ls -g` for inventory); NpmLocator scans brew/Volta/fnm/nvm + login-shell fallback, resolved path cached per scan
├── VersionComparison    — versionsEqual, isUpgrade, compareVersions(scheme:) (SemVer vs build-numbered), normalizeGitTag (public, tested)
├── CaskDatabaseClient   — full cask database fetch + disk cache
├── CaskMatcher          — bundle-id / name → cask token matching
├── StaleCaskDetector    — detects casks where installed .app is gone
├── BrewCaskDriftFilter  — hides casks whose on-disk `CFBundleShortVersionString` already matches `current_version`; covers self-updating apps like Google Chrome that bump their bundle outside Homebrew, leaving brew's `installed_versions` metadata stale
├── CaskAppPathResolver  — token → installed `.app` bundle (system-wide `/Applications` preferred over `~/Applications`, a cask with nothing on disk simply absent); the one place both upgrade paths ask where a bundle lives, resolved at upgrade time so the snapshot → canary → rollback chain no longer depends on a map only a full scan filled
├── BinaryLocator        — resolves brew + mas executable paths
├── RunningProcessService — terminate (`killall`) and relaunch (`open -a`) running apps for the restart-after-update and quit-before-migrate flows; routed through the `ProcessRunning` seam (one implementation shared by UpdateView + MigrationView, unit-tested with a fake instead of spawning real processes)
├── RunningCaskDetector   — REL-15: which upgraded casks own an app running right now, matched **generically by bundle URL** (`WorkspaceRunningApplicationInspector`) so it covers the whole catalog, not 16 hardcoded tokens; `restartMap` is consulted only as an override for atypically-named processes
├── AuthorizationComponentResolver — resolves compiled askpass and sudo-shim executables exclusively from the root-owned PKG installation under `/Library/Application Support/WegaMacUpdater/Authorization`; it validates the complete path and code signatures (including Mach-O page hashes and pinned Team ID/signing identifiers) before every environment attachment
├── AuthorizationEnvironment — finite environment allowlist shared by brew, mas and the compiled sudo shim; inherited loader/shell injection variables, `PATH`, `SUDO_ASKPASS` and `WEGA_SUDO_REAL` are dropped, while trusted `PATH`/`SUDO_ASKPASS` values can be attached only as explicit verified overrides
├── TouchIDSudoConfigurator — pure state parser for `/etc/pam.d/sudo_local` + biometry check (LocalAuthentication with an IOKit hardware fallback); the bounded root helper writes through `SudoLocalTransactionalWriter` (backup → atomic write → readback → rollback). If the helper is unavailable, Settings exposes an explicit Terminal command with the same transactional guarantees and an anchored grep that ignores commented `pam_tid.so` entries
└── Models               — ApplicationInfo, ManualOutdatedApp, UpdateSource…

WegaHelperKit (SEC-10 — minimal contract + helper-security library; the root daemon links THIS, not MacUpdaterCore)
├── WegaHelperProtocol   — the XPC contract: the finite `WegaPrivilegedOps` verb whitelist + `WegaHelper` identity/requirement constants (Team ID, Mach service, code-signing requirements, protocol `version`)
├── CodeSignatureVerifier — Team-ID-pinned SecStaticCode / Gatekeeper verification the helper re-runs **as root** before it installs or replaces anything
├── TouchIDSudoConfigurator / SudoLocalTransactionalWriter — the root-side PAM writer (backup → atomic write → readback → rollback)
├── SystemPaths          — the fixed, deliberately hard-coded macOS/Homebrew paths
└── AppMetadata          — bundle id + version constants
    · all re-exported by MacUpdaterCore (`@_exported import`), so every existing `import MacUpdaterCore` call site is unchanged; `WegaPrivilegedHelper` depends on this target alone, so the privileged root process no longer links the app's HTTP / parser / UI code

MacUpdaterTests
└── VersionComparisonTests, ApplicationScannerMasTests, BrewInfoParserTests…
```

No stored passwords. Homebrew runs as the logged-in user. Some casks (Zoom, kernel-extension installers, anything that registers launchd services or calls `pkgutil --forget`) invoke `sudo` internally during install/uninstall hooks — Wega has two layered fallbacks:

1. **Touch ID (preferred)** — the Settings window detects whether `/usr/lib/pam/pam_tid.so.2` exists, the Mac has a Touch ID sensor (`LAContext.canEvaluatePolicy`, falling back to an IOKit `AppleBiometricSensor` probe when biometrics are only *transiently* unusable for the app — e.g. clamshell mode, just after boot — so the card is not wrongly hidden), and `/etc/pam.d/sudo_local` already contains an active `auth sufficient pam_tid.so` line. If not, the bounded, signed root helper enables it without accepting a path or shell command from the GUI. Before replacing `sudo_local`, it makes a backup; the new file is written atomically, locked to `0644 root:wheel`, read back byte-for-byte and rolled back on any error. Without the helper Wega does not execute an elevated shell string: it displays an explicit, transactional Terminal command instead. Its anchored grep ignores commented directives. After a successful setup, brew's internal `sudo` calls trigger the native macOS biometric sheet.
2. **Askpass (fallback)** — when Touch ID is not wired into sudo, Wega exports a compiled AppKit askpass executable and prepends a compiled sudo wrapper to `PATH`. Both are signed before the outer app, and the PKG installs the signed binaries under the system-wide `/Library/Application Support/WegaMacUpdater/Authorization`, with root ownership, `0755` directories and `0555` executables. Runtime accepts only this system payload: immediately before every brew/mas spawn — and again inside the sudo shim — Wega validates both code signatures, their pinned identifiers, signed byte hashes and the complete symlink-free, root-owned, non-user-writable path. A missing or mismatched system payload fails closed by attaching no askpass path. The copies under `Contents/Helpers` are retained only as signed packaging input for the PKG; a DMG, network/FUSE volume, user-owned app bundle or writable copy cannot provide runtime authorization components. The child environment is rebuilt from a finite allowlist: inherited `PATH` and `SUDO_ASKPASS` are discarded alongside `WEGA_SUDO_REAL`, `DYLD_*`, shell startup hooks and other injection variables, and trusted execution paths enter only through verified overrides. **Both components remain gated on Touch ID state** — when `sudo_local` has `pam_tid.so` active, they are omitted so sudo goes through PAM naturally. `MasService.prewarmSudoTimestamp` still uses `sudo -v` with Touch ID and `sudo -A -v` otherwise. Running without a PKG-installed system payload intentionally disables the password fallback; sudo-requiring operations then fail normally instead of executing untrusted code.

Privileged operations beyond that go through a signed XPC helper with typed, allowlisted requests — never a shell-string API. **SEC-10** hardens that boundary: the root daemon links only `WegaHelperKit` (the contract + validation above), not the full app library, so its attack surface is the minimum it needs; every XPC call from the client is **deadline-bounded** (an unresponsive or crashed helper resolves to a timeout error, never a hang); and a **version handshake** (`helperVersion()`, itself deadline-bounded) runs before each privileged mutation, so the app refuses to drive a stale helper left behind by an update.

## Requirements

- macOS 26 (Tahoe) or newer
- Xcode 26 — the full app, not the Command Line Tools alone: the build needs the
  `FoundationModelsMacros` plugin, which ships only with Xcode (`scripts/check.sh` stops
  early and says so when `xcode-select -p` points elsewhere)
- Optional: Homebrew at `/opt/homebrew/bin/brew` or `/usr/local/bin/brew` — without it Wega
  still checks the Mac App Store, npm and every vendor feed, and says so instead of failing
- Optional: `mas` at `/opt/homebrew/bin/mas` or `/usr/local/bin/mas` (App Store features degrade gracefully without it)

GUI apps do not inherit an interactive shell environment. Wega resolves all tool paths from fixed locations — no `.zshrc`, no `$PATH` dependency.

## Build and test

```bash
swift build               # compile all targets
swift test                # run all tests
./scripts/verify-catalog.sh   # check app-catalog.json.sig matches the catalog (no secret needed)
WEGA_CATALOG_KEY=~/.secrets/wega-catalog.pem ./scripts/sign-catalog.sh   # re-sign after editing the catalog
swift run WegaMacUpdater  # launch app
```

**The signing key must live outside the working tree.** `scripts/sign-catalog.sh` refuses — exit 2, before it touches OpenSSL — any private key that resolves to a path inside this repository: its root, any subdirectory, and any linked worktree, whether given as an absolute path, a relative one, a `~` path, or reached through a symlink in either direction. This repository is public, and `.gitignore` only stops an *accidental* `git add`; it does nothing against `git add -f`, an edited ignore rule, or a backup of the folder — any one of which discloses a production key and forces a rotation of the OTA catalog signature for every installation. Keep the key in `~/.secrets/wega-catalog.pem` (`chmod 700` the directory, `600` the file) and point at it with `WEGA_CATALOG_KEY`. `scripts/test-sign-catalog-guard.sh` is the regression test for that refusal; it runs in `scripts/check.sh` and in CI, and only ever uses dummy key files.

**Integrating a feature branch** goes through `./scripts/merge.sh <branch> "<merge message>"`, run from anywhere in the repo. It fetches `origin/main` and stops if the local one is behind, rehearses the merge with `git merge-tree` so a conflicting branch is reported *before* `main` is touched, names any untracked file the merge would overwrite instead of aborting halfway through, and only then merges with `--no-ff`. The quality gate runs on the **merged** result, and the branch and its worktree are deleted only once it is green — a red gate leaves both in place to fix and prints the `git reset --hard ORIG_HEAD` undo rather than performing it. `--no-verify` skips the gate (for a machine without a full Xcode toolchain; CI still runs it), `--force` discards local changes when removing the worktree. `scripts/test-merge.sh` covers those refusals in throwaway repositories and runs inside `scripts/check.sh`.

The repository intentionally has no root `clean.sh`: the former file was a completed
one-shot code generator whose misleading name hid source overwrites, `git add -A`, a
direct commit to `main`, and optional worktree/branch deletion. Use the narrowly named
scripts under `scripts/` for maintenance. `scripts/test-clean-script-guard.sh` prevents
that destructive entry point from returning and runs inside `scripts/check.sh`.

The package targets the **Swift 6 language mode** (`swift-tools-version: 6.0`), so the whole codebase compiles under strict concurrency checking. CI and the release pipeline share **one reusable workflow** (`.github/workflows/build.yml`, `on: workflow_call`) so they can never drift: the same `macos-26` runner and the same **pinned toolchain** — Xcode 26 and SwiftLint 0.65.0, never `latest-stable` or `brew install swiftlint`, because a floating toolchain would break the `--strict` lint gate the day a new rule ships, on a toolchain no commit ever chose. Every push and pull request to `main` (`.github/workflows/ci.yml`) invokes it, running these jobs (the Catalog signature and SonarCloud jobs run on `ubuntu-latest`):

- **Build & Test** — `swift build --build-tests` + `swift test`, both with `--enable-code-coverage`. `scripts/coverage-sonarqube.sh` then converts SwiftPM's llvm-cov output into a SonarQube generic coverage report (`sonarqube-generic-coverage.xml`) that is uploaded as an artifact for the SonarCloud job (which runs on Linux and can't run the macOS tests itself).
- **SwiftLint** — `swiftlint lint --strict` against `.swiftlint.yml` (warnings fail the job). The config keeps the high-signal correctness rules and metric guardrails while disabling the purely-cosmetic rules that conflict with the codebase's house style, so it gates regressions without reformatting.
- **Package** — runs `scripts/build-pkg.sh` to prove the whole packaging path composes, then runs `scripts/verify-bundle.sh` — the **same artifact gate the release uses** — over the built `.app`: bundle layout, a **universal** binary (arm64 + x86_64), a valid helper/app signature, and that both `app-catalog.json` and `endpoints.json` are bundled (the latter is required at launch — `AppEndpoints.shared` fatal-errors without it). On the ad-hoc-signed CI build the notarization and stapling checks are reported as skipped. It then uploads the resulting `.pkg` as an artifact.
- **Catalog signature** — `scripts/verify-catalog.sh` checks that `app-catalog.json.sig` verifies against `app-catalog.json`, using the public key already committed in `CatalogSignature.swift`. **No secret and no write access**: Ed25519 is deterministic, so verifying proves exactly what re-signing would, without ever handing CI the private key. `raw.githubusercontent` serves the catalog and its signature as two separate cache entries, so the commit is the only place their consistency can be enforced — this gate goes red the moment the catalog changes without the signature being regenerated. Skipped (exit 3) while the key is still the placeholder.
- **SonarCloud** — runs the SonarQube/SonarCloud scanner against `sonar-project.properties` (after **Build & Test**, whose coverage report it downloads and feeds via `sonar.coverageReportPaths`). Skipped until a `SONAR_TOKEN` secret is configured, so it never blocks CI before setup. Outbound URLs are sourced from `endpoints.json` via `AppEndpoints`, so `S1075` ("hard-coded URI") only fires on genuinely configurable endpoints; tests and the fixed-system-path files are excluded in the properties file. Coverage is measured on `MacUpdaterCore` **and** the reachable parts of the `WegaMacUpdater` app: the `MacUpdaterUITests` bundle depends on the app target and `@testable import`s it, so the app's orchestrators (`ScanStore`, `BackgroundUpdater`, `MenuBarAgent`, the `*Store`/`*Controller`/`*Coordinator` types) and the I/O services with a tested pure core are all counted. `sonar.coverage.exclusions` is deliberately narrow — only files with no unit-testable branch logic (the SwiftUI `View`/`Scene`/`App`/`Commands` layer, the constant-only `SystemPaths.swift`, and the XPC/root/network glue whose decisions live in Core) are excluded (the gate requires ≥ 80% coverage on new code).

`scripts/build-pkg.sh` builds a universal binary by default (override with `ARCHS="arm64"`) and copies the SPM resource bundle (`app-catalog.json`) into the `.app`, so `Bundle.module` resolves at runtime.

Open `Package.swift` directly in Xcode for the full IDE experience. No Xcode project or provisioning profile is needed for signing: `scripts/build-pkg.sh` signs the hand-rolled bundle with `codesign` (hardened runtime + timestamp, inside-out: authorization components and privileged helper first, then the app) when given Developer ID identities as arguments — see [Cutting a release](#cutting-a-release).

### Version — single source of truth

The app version lives in exactly one place: `AppMetadata.version` (`Sources/WegaHelperKit/AppMetadata.swift`). The running app reads it (falling back to it when no bundle `Info.plist` is present, e.g. under `swift run`), and `scripts/build-pkg.sh` extracts it from there when stamping the generated `Info.plist` and the `.pkg` — so bumping the version is a one-line edit. The release workflow **enforces** this: a tag `vX.Y.Z` whose version doesn't equal `AppMetadata.version` fails the build before anything is published.

## Distribution

Intended channel: Developer ID, outside the Mac App Store.

- **Developer ID Application** signing for the `.app` (and nested privileged helper) + `.dmg`
- **Developer ID Installer** signing for the `.pkg` — a distinct certificate type; `pkgbuild` refuses Application certs
- Hardened Runtime
- Notarization
- DMG placing `WegaMacUpdater.app` in `/Applications` (the name `scripts/build-pkg.sh` builds)

The Team ID is pinned in code (`WegaHelper.teamIdentifier`) — XPC peer pinning and
self-update verification only trust binaries signed by that team, so release signing
**must** use certificates from the same Apple Developer team.

### Cutting a release

`scripts/build-pkg.sh` builds a universal, ad-hoc-or-signed `.pkg` **and** a drag-to-Applications `.dmg`. Pushing a version tag drives the rest, and `scripts/release.sh` is what creates that tag — in two phases, with a review gate in between:

```bash
./scripts/release.sh patch      # prepare: bump AppMetadata.version, draft notes, stage
# review CHANGELOG.md, edit until the notes read well
./scripts/release.sh --continue # finalise: commit + annotated tag
git push origin main --follow-tags
```

Never edit `AppMetadata.version` or move the `[Unreleased]` entries by hand — the script owns
both, and the workflow refuses any tag that disagrees with the version. The full procedure,
the signing secrets and the first-release case (**the project has no tags yet**, so the first
release is cut from `[Unreleased]` alone and its version must be higher than `0.1.0`) are in
**[RELEASING.md](RELEASING.md)**.

`.github/workflows/release.yml` (on `push: tags: v*`) first runs the **same reusable quality workflow CI runs** — build, test, lint, catalog verification, packaging and the bundle gate, on the same pinned `macos-26`/Xcode 26 toolchain. The publishing job `needs:` it, so a release can never be built on a different toolchain than CI proved green, nor published ahead of the quality gates. It then verifies tag == `AppMetadata.version`, builds the artifacts, notarizes and staples them, and runs `scripts/verify-bundle.sh` over the result — bundle layout, helper signature, notarization, stapling and required resources — as a final gate before it publishes a GitHub Release with the `.pkg` + `.dmg`. **Signing and notarization are optional and activate automatically once the secrets exist** — until then the job still publishes *unsigned* artifacts so the pipeline is verifiable end-to-end without an Apple Developer account (the **Preflight** step in each run prints which signing/notary secrets are configured).

Secrets (all optional):

| Secret | Purpose |
| --- | --- |
| `DEVELOPER_ID_IDENTITY` | `"Developer ID Application: Name (TEAMID)"` — signs `.app`, helper, `.dmg` |
| `DEVELOPER_ID_INSTALLER_IDENTITY` | `"Developer ID Installer: Name (TEAMID)"` — signs the `.pkg` (distinct cert type; without it the `.pkg` ships unsigned and is skipped by notarization) |
| `DEVELOPER_ID_CERT_P12` | base64 of a `.p12` exported from Keychain — export **both** identities (Application + Installer) into this one file |
| `DEVELOPER_ID_CERT_PASSWORD` | password of the `.p12` |
| `KEYCHAIN_PASSWORD` | any throwaway password for the CI temp keychain |
| `AC_API_KEY_ID` / `AC_API_ISSUER_ID` / `AC_API_KEY_P8` | App Store Connect API key (role *Developer*) for `notarytool`; `AC_API_KEY_P8` is the full `.p8` file contents |

### Self-update

Wega updates **itself** by dogfooding the same machinery it uses for everyone else. `WegaSelfUpdateChecker` (MacUpdaterCore) asks the GitHub Releases API for the latest tag, compares it against `AppMetadata.version` with the shared `VersionComparison` logic, and resolves the published installer asset (preferring the `.dmg`, falling back to the `.pkg`). The **Settings window** surfaces the full install flow: it auto-checks once when the window opens (ETag-conditional, so revisits are free) and offers a manual re-check; when a newer release exists, it shows the version and a "Download and install" button (downloads the asset and hands it to Installer / DiskImageMounter, falling back to opening the asset in the browser) plus a link to the release notes. No embedded framework, no appcast to host. (Sparkle-style silent background updates remain a possible later upgrade; the runtime cost — embedding the framework in the hand-rolled bundle, EdDSA-signed appcast hosting — isn't worth it for a tool you open deliberately.)

**One count, everywhere applies to Wega too (UX-15).** The self-update no longer hides in Settings: `ManualUpdateScanner` runs the same check on every background and window scan and folds an available release into its results as an ordinary `ManualOutdatedApp` (a `.wega` update source). So a pending Wega update is **counted in the badge, named in the background notification, and listed as a "Wega" row under "Ręcznie zainstalowane" in the Updates window** — exactly like any other manually-updated app. Its row action opens the release page (the guided download-and-install stays in Settings, where signature verification and the privileged-helper install live); the row still carries the version arrow, release notes and the security-fix badge like every vendor row.

The privileged helper — shipped, not planned — lives inside the bundle at `Contents/Library/LaunchDaemons` and registers via `SMAppService.daemon(plistName:)`.

## License

[MIT](LICENSE)
