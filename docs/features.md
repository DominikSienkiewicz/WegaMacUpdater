# Features

Every screen and every guard, in the order you meet them. The pipeline underneath is in [how-it-works.md](how-it-works.md).

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
successful rollback. A bundle-identity mismatch preserves it in the same way.

#### When the package manager installed nothing

Homebrew exits 0 without touching the disk whenever its own Caskroom record already names the
version the cask offers — a state a self-updating app can leave behind, and one the confirming
rescan cannot see, because that rescan asks `brew` and brew's record is the thing that is
wrong. Observed with Obsidian: `Caskroom/obsidian/1.13.7` alongside an
`/Applications/Obsidian.app` still reporting `1.13.6`, so `brew outdated --cask --greedy`
printed nothing while every scan — which reads the bundle's `Info.plist`, not brew's record —
kept calling it outdated. Each upgrade was announced as applied and the next scan contradicted
it.

So before any gate describing the artifact, Wega asks whether an artifact arrived at all. The
snapshot **is** the pre-upgrade bundle, so the version on disk is compared against it directly,
read straight from `Info.plist` rather than through `Bundle(url:)` and its per-URL cache. An
unchanged version is `notUpgraded`: journaled as **aborted** — never `verified`, never
`committed`, and its snapshot restores nothing — reported as **still outdated**, and left out
of the rollback ledger in both directions, since a run that changed nothing must not disturb
what the ledger already remembered. The check comes first on purpose: run later, the canary
would inspect the *old* app, pass it, and talk the no-op up into a success. An unreadable
version on either side counts as replaced — absence of evidence must not turn every unparsable
bundle into a failed upgrade.

#### Launch smoke test

The identity, Gatekeeper and publisher gates all describe what the new bundle **is**; none
of them says whether it **runs**. A correctly signed build from the right publisher that
dies on startup — a missing framework, an incompatible architecture, a truncated bundle —
cleared every one of them and landed on the user as a working update.

So the canary ends with a fourth gate. Once the other three have approved the build, Wega
launches it through `NSWorkspace` **hidden and non-activating**, watches the instance for
five seconds, and then stops it (polite quit, short grace, then a kill, the same escalation
a cancelled subprocess gets). An instance that exits before the window closes, or a launch
the system refuses outright, restores the pre-upgrade snapshot through the same
`restoreSnapshot` path every other gate uses — so the verdict keeps flowing into the
rollback ledger and the LT-01 journal, and there is no second way to undo an update.

The gate runs last on purpose: a bundle whose identity or publisher is in doubt is the last
thing that should be executed. Five cases produce no evidence and therefore never trigger
a rollback — an app the user already has open (Wega will not quit it to make room), a cask
with nothing launchable, a run cancelled mid-window, and the two that exist because stopping
the app would be destructive rather than tidy: an instance holding an **open system
authorization prompt**, and a cask named as doing a **privileged first run**.

That last pair is the Docker Desktop lesson. An app whose bundle was just replaced may come
up asking for authorization to reinstate privileged state — Docker rebuilds its `vmnetd`
configuration this way. The prompt is drawn by a helper process that dies with its parent, so
the teardown cancels an installation the user is still answering: Docker's password dialog was
killed 7.4 seconds after it appeared (the five-second window plus the two-second grace), and
because the privileged step never finished, every later launch re-prompted and crashed. So an
open prompt — detected through `SecurityAgent`, which exists only while an authorization sheet
is on screen — suspends the teardown and leaves the instance running for the user to answer.
Detection alone would race, since Docker's dialog took about four seconds to appear against a
five-second window, so casks known to repair privileged state on first run are never launched
by the smoke test at all. Both are "no evidence", never a failure: not learning whether an app
runs must not be spent as a reason to undo an upgrade.

Liveness is read repeatedly while
the window is open **and once more on its closing edge**, and always through the handle the
launch returned rather than by process name, so neither a death in the last poll gap nor a
recycled pid can pass as a survivor. The test is on by default and can be switched off in
**Settings → Post-update launch test**; it costs about five seconds per cask.

#### The rollback net

Each Homebrew cask row carries a **🛡 rollback badge**: a shield where snapshot → canary →
auto-rollback covers the upgrade, and an honest **"no protection"** slash where it cannot (a
cask that installs no `.app` — a bare `pkg` or `installer` — has nothing to clone; that hole
is now logged as a warning instead of being skipped silently). Sources Wega cannot roll
back at all — formulae, the Mac App Store, npm and vendor-direct apps — say so under
their section headers instead of implying the net.

**Undo update (LT-01).** Every upgrade runs inside a *journaled operation*: the phases
`planned → snapshotted → installing → verified → committed/rolledBack` are written to
disk, per cask, in a unique directory per operation
(`~/Library/Application Support/WegaMacUpdater/update-operations/<uuid>/`), before the
mutation they describe. A healthy upgrade no longer deletes its snapshot — it is kept
for a **7-day retention window**, which is what makes a manual **„Cofnij aktualizację"**
(Undo update) possible: the Updates window lists committed upgrades whose pre-upgrade
copy is still retained, and undoing one restores that copy through the same code path as
the canary (root-helper fallback included) and then **auto-pins the restored version**,
so the update you just took back is not offered again on the next scan. A crash, kill or
power loss mid-upgrade is settled at the next launch: operations whose journal stopped
before `installing` never touched the disk and are swept; one stuck at `installing` is
probed — an untouched disk settles as aborted, a landed-but-unvalidated upgrade is run
through the same canary chain (and can roll back), an app missing outright is put back
from its snapshot — and anything restored this way is announced, never silent. Expired
snapshots are pruned at launch and after each run.

The bundles the guard clones are
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
  Signal, Chrome — share **success green**. So the 17 update sources — 14 vendor checkers
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
- **Co nowego** shows real release notes when the source provides them (with the advisory
  "possible security fix" badge a deterministic keyword scan raises — advisory only, it
  never gates or auto-applies anything) and says so plainly when it doesn't; the same notes are
  now also **inline on the row**, behind a *What's new* disclosure, for every manually-checked
  app whose source publishes them (GitHub release bodies, Sparkle `<description>`, JetBrains
  `whatsnew`). Vendor HTML is untrusted input — `ReleaseNotesText` in Core strips every tag
  and drops `<script>` / `<style>` bodies whole before anything reaches the window, without
  going near WebKit.
- **Akcje** reuses the row's own per-source update control.

The probe runs in a `.task(id:)` that **cancels and restarts** as you change selection, so it
never blocks the list or shows a stale verdict.

### Accessibility
Update and uninstall selections are native keyboard-focusable controls with VoiceOver labels and explicit selected/not-selected values. In the package-manager update list, **Return** opens the focused row in the inspector and **Space** toggles its batch selection; on manual-update rows either key opens details because those rows have no batch-selection checkbox. Select-all controls are buttons rather than pointer-only gestures. The uninstall confirmation is a correctly sized native sheet with destructive/cancel roles, **Enter** and **Esc** shortcuts, and the exact frozen targets shown before execution; long target and ambiguity lists scroll while the action buttons remain pinned, including at large text sizes. Its **App only** / **App + leftovers** choice also announces the selected state to VoiceOver. Selection rows use semantic fonts so large environment text can reflow. The **Updates scan status on the sidebar icon** no longer relies on colour alone: a failed scan swaps the icon's **symbol** (a warning glyph, not just a red tint), and every scan state — checking, checked-clean, failed — is announced to VoiceOver as the row's value, so the outcome reaches users who cannot distinguish the colours. With **Reduce Motion** enabled, the rotating sidebar artwork, cycling thought bubble, Wega motion and binary stream all render without continuous movement; rebuilding its parent does not replace the static binary frame. That coverage is now complete and centralized: Wega's bouncing ball, her blink and her idle *tricks* on empty states, and the sweeping bar under a running check, all stop as well, and each notices the setting being switched on **while it is already running** rather than only at first appearance — one `ContinuousMotion` policy decides for every never-ending animation in the app, and a regression test refuses a `repeatForever` that does not go through it. Where a moving element carried information, the information stays: the check-in-progress bar drops its sweep instead of freezing at full width, which would read as *finished*. **Text sizes** across the whole window come from a semantic scale (`Font.wega(…)`, one alias in `WegaTheme`) rather than ~225 hard-coded point sizes, so the interface follows the system text-size setting; the only two fixed sizes left are drawings sized by their own container, and they say so on the spot. The **palette is appearance-adaptive**: the eight brand colours were tuned against a dark window and read at roughly 1.8:1 on a light desktop, and now resolve per appearance — with a separate pair for **Increase contrast** — clearing 4.5:1 both on the window background and on the 12 %-tinted badge fill they also sit on (7:1 for the increased-contrast pair), graded arithmetically in tests rather than by eye. Filled controls whose label is Wega's dark ink keep a separate, lighter fill value, and the mascot's own coat colours stay fixed — a drawing is not text. The **Settings** window (⌘,) is resizable instead of pinned to 640×600, so it can grow at large text sizes instead of clipping. An **Aktualizacje** menu carries the app's keyboard shortcuts, macOS-conventional: **⌘R** *Sprawdź teraz* (start a scan), **⌘⏎** *Aktualizuj* (opens the same update confirmation the toolbar button does, on the Updates destination), **⌘1…⌘5** to jump to the five sidebar sections in order (Updates, To reattach, Inventory, Uninstall, Logs), and **⌘F** *Find in inventory*, which opens the Inventory list and focuses its search field. Each shortcut is greyed out exactly when its on-screen control is unavailable. The app menu, under **About Wega Mac Updater**, adds **Sprawdź aktualizacje Wegi…** — the macOS-conventional place for an app's own update check — which opens the Settings window, where the self-update screen owns the operation.

### Uninstall
Scans every app on the system regardless of origin. Brew casks are removed with `brew uninstall --cask`; App Store and manually installed apps are moved to Trash. The confirmation dialog offers **"App only"** (the default, and the recommended one) or **"App + leftovers"** (`--zap`, which also deletes preferences, caches and Application Support) — the irreversible option is a deliberate choice, never the preselected one. It shows exact counts: how many casks are affected, how many go to Trash. If the selected `--zap` operation fails, Wega reports that item as incomplete and leaves it selected; it never silently retries without zap using `--force` or counts that changed operation as success. **"App + leftovers" is no longer brew-only** (UX-13): for App Store and manually installed apps the dialog lists the `~/Library` items the app left behind — built by the same `MigrationPlanner` per-bundle-id planner Wega already trusts (`LeftoverCleanup`) — as checkboxes, each ticked by default, and moves the ones you keep ticked to the **Trash** (recoverable, never a permanent delete). So the "app + leftovers" promise now holds whatever the app was installed from; leftover moves that fail are reported, not swallowed. **A scan that can't read a source is never shown as an empty machine**: when it finds nothing it says *"the scan failed"* rather than *"no apps found"*, and when it still found some apps the confirmation dialog warns that the target list may be incomplete before anything is removed — a destructive choice is never made on silently partial data. **Right-click any row** to reveal it in Finder, copy its path, or toggle whether it is marked for removal — the same per-row context menu the update list already offers.

### Migration
Finds manually-installed apps that have a Homebrew Cask equivalent and offers to migrate them with `brew install --cask`. Runs `mas search` in parallel for apps without a cask match to find App Store equivalents. Running detection covers every matched app: the exact standardized/resolved bundle path wins, with a unique bundle ID as fallback; ambiguous duplicate bundle IDs stop the migration. Wega sends that exact process a normal application **Quit** request and waits for it to stop. Only an app that remains open produces a separate warning about unsaved data; after explicit consent Wega identifies the target again, sends `SIGKILL` only to that PID, and confirms the app stopped. A failed or ambiguous force-quit cancels the migration instead of being ignored. A match too weak to trust (the **"niepewne"** / low confidence level) is refused before anything runs: since `brew install --cask --force` overwrites the app in place, a low-confidence `.app`→cask match could replace it with a *different* program, so Wega blocks the automatic takeover and asks you to verify the token manually (`MigrationAutoTakeover` consuming `CaskMatchConfidence.allowsAutoConfirm` — the confidence score now gates execution, not just the badge). The confidence comes from **how** the match was found (`CaskMatchProvenance`, decided by `CaskMatcher` and carried on the scanned app): an already-installed cask, a curated entry in `customCaskMappings` or an exact token hit is certain; a match on one of a cask's display names is plausible and asks for confirmation; an app tied to no cask at all is the case that stays blocked. A publisher mismatch still overrules all of it. Previously the scorer re-derived this from strings its callers could not supply, so the curated table — whose whole purpose is apps whose name does not normalize to their token — scored lowest and had every one of its entries refused. Before Homebrew replaces an existing `.app`, migration takes the shared upgrade mutex, passes the same hard disk/network/power gate as an upgrade, verifies and preserves the installed publisher baseline, and requires a copy-on-write snapshot. The installed result must pass the shared Gatekeeper/Team-ID canary; otherwise Wega restores the snapshot and reports failure. The manual cask-adoption action in Updates uses this same protected transaction, so neither `brew install --cask --force` entry point can bypass it. A cask that installs **no `.app` at all** — a `pkg` cask such as `zoom` or `google-drive` — is refused up front with "Nie można przejąć", before brew runs: there is no bundle to snapshot, nothing for the Gatekeeper/Team-ID canary to validate, and nothing to restore. Adoption previously ran the force-install on these anyway and then reported the missing app artifact as `.rollbackFailed` ("the new version failed the check and could not be restored"), which described neither a check nor a rollback — both had been skipped. This is the same `RollbackProtection` question the batch upgrade path already asks, now asked by the adoption path too. A successful brew migration ends there: Wega **touches nothing in `~/Library`**. The old "clean leftovers" sheet was removed (SEC-01) — for a migration the app keeps its bundle id, so those "leftovers" are the live Application Support, preferences and container of the app you just adopted, and the sheet offered to delete them permanently with everything preselected. **npm ↔ brew duplicate row** — for CLIs installed via both `npm -g` and Homebrew (e.g. `@openai/codex` + `codex` cask), inline "Usuń z npm" / "Usuń z brew" buttons run the corresponding uninstall (`npm uninstall -g -- <pkg>` via `NpmGlobalService.uninstallEvents`, or `brew uninstall -- <token>`; the `--` terminator is SEC-10) after a confirmation alert; the duplicate disappears from the list on exit 0.

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
