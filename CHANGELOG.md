# Changelog

All notable changes to **Wega Mac Updater** are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The version lives in exactly one place — `AppMetadata.version`
(`Sources/WegaHelperKit/AppMetadata.swift`); the release workflow refuses to publish
a tag whose version doesn't match it. Keep the `[Unreleased]` section ahead of each
bump; `scripts/release.sh` moves its entries under the new version heading when cutting a
release, so that step is never done by hand — see [RELEASING.md](RELEASING.md).

## [Unreleased]

### Added
- macOS's **App Management** permission is now a recognized failure mode instead of raw
  `stderr`. Since macOS 13, replacing a bundle in `/Applications` needs that grant — and it
  applies to child processes, so a missing grant makes the `ditto` inside `brew upgrade`
  fail with `ditto: /Applications/X.app: Operation not permitted`, naming no cask. Wega now
  detects that refusal, shows a banner that names the permission with a button opening
  **System Settings → Privacy & Security → App Management**, says the same in the
  background-update notification, and adds an optional preflight row to **Info →
  Diagnostyka systemu** so a missing grant is visible before the first upgrade. Unattended
  rounds are held back for 24 h after an observed refusal rather than failing identically
  every interval, and the hold lifts by itself once a round succeeds.
- **The self-update shows every release you are behind, not just the newest.** Three versions
  behind used to mean reading one third of the change. The card now lists each release between
  the installed version and the newest one, newest first, with markup stripped in Core.
- **A completed headless self-update ends in an explicit *installed, restart to use it*
  state.** A `.pkg` install swaps the bundle under a live process, so the card now offers a
  restart button instead of pretending the new version is already running — and that button
  stays disabled while any mutating operation holds the write gate. Nothing restarts the app
  on its own.
- A rebuilt window chrome on `NavigationSplitView`: a List-backed sidebar driven by one
  `SidebarSelection` value instead of two navigation axes, the scan control hoisted into
  the toolbar so its states can morph, the details pane moved into the native
  `.inspector()` container, and glass on the floating layer in place of the hand-drawn
  washes. This is the change that raises the minimum macOS to 26 — see **Changed** below.
- **The post-update canary now checks that the app actually starts.** Gatekeeper and the
  publisher comparison describe what a bundle *is*; neither says whether it runs, so a
  correctly signed build that dies on startup — a missing framework, a wrong architecture,
  a truncated bundle — passed every gate and was announced as a successful update. After
  those checks Wega now starts the upgraded app hidden and non-activating, watches it for
  five seconds, and restores the pre-upgrade snapshot through the existing rollback path if
  it exits early or refuses to launch at all. An app that is already open is skipped rather
  than quit to make room, and skipping never triggers a rollback. On by default, with a
  switch in **Settings → Post-update launch test**.
- **Migration no longer refuses every app in the curated cask table.** `CaskMatchScorer` judged
  a match partly by *how* it was found — a curated entry in `customCaskMappings`, an exact
  token, one of a cask's display names — but that route was decided inside `CaskMatcher` and
  thrown away, since `CaskMatch` carried only the token. Both call sites could therefore pass
  nothing but literals, so two of the four signals were dead and collapsed to the lowest
  score. Because `MigrationAutoTakeover` turns the lowest score into *blocked*, and because
  every entry in the curated table is there precisely because the app's name does not
  normalize to its cask token, all six — Docker, zoom.us, Parallels Desktop, CleanMyMac_5,
  Gemini 2, logioptionsplus — had their automatic takeover refused. The route is now part of
  `CaskMatch` as `CaskMatchProvenance`, travels on the scanned app, and is what the scorer
  takes, so a caller can no longer get it silently wrong. A display-name match now asks for
  confirmation instead of being refused; an app tied to no cask is what stays blocked; a
  publisher mismatch still overrules everything.

- **Clicking a notification now opens what it is about.** Wega posts three kinds — updates
  available, the summary of an unattended round, and a report that an interrupted update was
  repaired — and clicking any of them did the system default: bring the app forward, to
  whatever screen it last showed. So *"Wega naprawiła przerwaną aktualizację"* landed on the
  updates list with no way to find out what it had restored. The destination now travels in the
  notification itself: updates open the list, a round with a failed rollback or a changed
  publisher opens the **Logs** view where the reason is, and a recovery report always opens the
  log. A notification left over from an older build still just brings Wega forward — an
  unrecognised destination is treated as none, never as a fallback screen.

- `DiscordUpdateChecker`, `SignalUpdateChecker` and `ChromeUpdateChecker` — three more
  self-updating apps whose Homebrew casks are `auto_updates` and lag the real channel, so
  neither `brew outdated` nor the cask-version check sees the new build. Discord
  (stable / PTB / Canary) is read from its Squirrel.Mac feed, Signal Desktop from its
  `electron-updater` `latest-mac.yml`, and Chrome (stable / beta / dev / canary) from
  Google's public Version History API — taking the **max** version, because that feed's
  order is not contractually newest-first.
- `ObsidianUpdateChecker` — Obsidian loads self-updated `obsidian-X.Y.Z.asar` packages from
  Application Support independently of the installer in `/Applications` and of its
  `auto_updates` cask. The checker reads the effective ASAR version, follows the `beta`
  version when `obsidian.json` enables the Catalyst insider channel, and runs even when
  Brew correctly reports the installer cask as current; the action opens Obsidian so its
  own signed in-app updater applies the package.
- Homebrew is now **optional**, behind a soft gate. Without it Wega still checks the Mac
  App Store, Sparkle, the vendor feeds and npm, and shows an *"install Homebrew to unlock
  more updates"* card instead of a wall. A tool that is not installed is classified as
  **not applicable** (`SourceCheckOutcome.notInstalled`) rather than as a failed check — so
  a machine without brew stops wearing a permanent red *"the list may be incomplete"*
  banner over a list that is complete.
- A dry-run plan preview above the update button (**"Show exactly what I will do"**),
  rendering `UpdatePlanner.commands(for:)` — *the same call the upgrade itself executes*, so
  the preview cannot drift from what runs — plus, per cask, the download host, whether
  Homebrew will verify its checksum, whether the rollback net covers it, whether it **may**
  ask for an admin password, and a `HEAD`-probed download size (**"size unknown"** is a
  first-class answer shown as itself, and the measured sizes feed `DownloadGate`).
- One unified update count (`UpdatePlanner.unifiedCount`) shared by the window header, the
  sidebar badge, the menu-bar badge and the background notification. The header names both
  halves of it — *"12 to install + 3 manual"* — and the **Update all (N)** button counts
  only the installable half, so it never promises an upgrade Wega cannot perform.
- Real scan progress and a working **Cancel**: the scan is strictly sequential
  (brew → mas → npm → manual) and the bar reports the phase it is genuinely in. The window
  also opens with the last scan already restored — from `ScanResultStore` on disk or from
  the menu-bar agent's last background check, whichever is newer — instead of an empty
  screen followed by a second scan, with `ScanFreshness` marking a day-old result as such
  rather than letting it pass for fresh.
- Opt-in unattended upgrades for a deliberately narrow subset of casks, decided by the pure
  `BackgroundUpdateEligibility` predicate and granted per app from a row's ⋯ menu, with a
  durable consent audit in the Settings window.
- Release notes wherever the source publishes them: Sparkle `<description>` and JetBrains
  `whatsnew` are parsed and shown inline on the row behind a *What's new* disclosure as well
  as in the inspector. Vendor HTML is untrusted input — `ReleaseNotesText` in Core strips
  every tag and drops `<script>` / `<style>` bodies whole, without going near WebKit.
- The interface language now resolves from the system locale on first launch
  (`AppLanguage.defaultLanguage(preferredLanguages:)` in Core): Polish only when macOS
  reports it ahead of the other languages Wega ships, **English otherwise** — including for
  an empty list. Switching the language keeps the current scan results, and a running
  upgrade, intact.
- The committed catalog and its detached signature are gated against each other in CI
  (`scripts/verify-catalog.sh`), so the catalog can no longer change without its signature
  being regenerated. A catalog's URL-typed fields are validated **while decoding** (absolute
  https with a non-empty host), so a hostile entry is rejected at decode time rather than
  opened or fetched later, and `CatalogIssueBuilder` turns an app Wega has no known way to
  update into a prefilled GitHub issue straight from its Inventory row.
- The **🛡 rollback badge** on every Homebrew cask row — a shield where snapshot → canary →
  auto-rollback covers the upgrade, and an honest *"no protection"* slash where it cannot (a
  cask that installs no `.app` has nothing to clone). Banners now **queue** rather than
  overwrite, so a *publisher changed* alert survives the upgrade summary that used to
  clobber it.
- A hard download resource gate shared by window and unattended cask upgrades. Before
  snapshotting or downloading it vetoes metered/Low Data Mode networking, low battery,
  thermal throttling and insufficient (or unreadable) disk capacity. Required space is
  budgeted as download + unpacked payload + rollback snapshot + safety margin; the
  thresholds and estimates are persisted and configurable in the native Settings window.
  Background deferrals retain their reason in the activity log.
- **Export diagnostics** — one action, in **Settings → System diagnostics** and in the
  **Logs** toolbar, that saves a redacted `.zip` containing everything a bug report needs:
  app version and build, macOS version and CPU, detected package managers and their
  versions, Privileged Helper status and version, schedule status, the last scan's result
  per source, free disk space, the signature state, and **both** log files — including the
  rotated `wega.log.1`, which nothing in the app had ever read back. Filesystem paths, URL
  query strings, credentials, e-mail addresses and account names are replaced with
  placeholders before anything is written, and nothing is uploaded anywhere: a save panel
  asks where the file goes, every time.
- A durable **update → validation → rollback history**. Run verdicts used to live only in
  the banner they produced, so a background round that rolled an app back left nothing
  behind once the window closed. The last 40 runs are now recorded — per item, per phase,
  including rollbacks and publisher changes — and travel in the diagnostics export. The
  record carries no Team ID values and no verbatim tool output; it says *that* a publisher
  changed, not who.
- Replay and downgrade protection for the over-the-air app catalog. A signature answers
  "did the publisher write this?", never "is this the current one" — so an old catalog with
  its own old, perfectly valid signature used to be valid forever, and anyone able to choose
  which bytes reached a client could pin it to a catalog published before a fix. The catalog
  now carries a monotonic `generation` inside the signed bytes; Wega remembers the highest it
  has accepted, across relaunches, and refuses anything lower. `schemaVersion` is enforced
  instead of ignored: a catalog in a format this build does not implement is refused with
  "update Wega" rather than decoding as a valid, empty catalog that would have switched every
  catalog-driven checker off in silence.
- A one-document envelope format for the published catalog (`payload` + `signature` in one
  file). The old layout served the JSON and its `.sig` as two separate CDN entries, so a
  client could fetch a fresh catalog beside a cached signature and see a mismatch that is
  cryptographically identical to tampering; one document cannot skew against itself. Wega
  reads both formats, so publishing can switch over at any time with
  `./scripts/sign-catalog.sh --envelope`.
- Opt-in crash reporting for Wega itself, through MetricKit. macOS hands the app its own
  crash and hang reports shortly after the next launch, so a crash no longer has to be
  reconstructed from a system report dug out and mailed in by hand. The switch lives in
  Settings and is **off by default**, and the reports never leave the Mac: there is no
  endpoint and no upload path — collecting is one decision, sending is a separate one the
  user makes by copying a report out. Locale, Mac model, memory-region dumps and slid runtime
  addresses are dropped at the parser; every stored string goes through the same redaction as
  a log line, so no filesystem path or URL query survives. Turning it on collects from that
  point forward — diagnostics recorded before consent are not swept up — and at most 20
  reports are kept, for 90 days, owner-only next to `wega.log`.
- Unit tests for `JetBrainsUpdateChecker` and `SparkleUpdateChecker` — the two manual
  checkers that previously had no dedicated coverage despite driving 14 JetBrains IDEs
  and every generic Sparkle app. Both are exercised through the injected `HTTPClient`
  seam with a fake transport (no network).
- **Anuluj for a running update (REL-12).** The Updates screen's longest operation — a
  multi-gigabyte, multi-minute upgrade — used to turn its button into a spinner with no way
  out. It now offers a stop button that takes effect at the next package boundary: the
  install already running is never cut in half, everything after it is skipped, and the
  report says how many packages were updated and how many were left untouched instead of
  announcing a finished run. An upgrade still queued behind another operation is dropped
  outright, since it has changed nothing yet.
- Shared `FakeHTTPTransport` test double in `TestDoubles.swift` for HTTP-level checker
  tests.
- Diagnostic logging through `WegaLog` (OSLog, the in-app Logs tab and the rotating
  `wega.log` file): `HTTPClient` records retry attempts and final transport failures,
  while `ProcessRunner` records non-zero exits, timeouts and cancellations. The menu-bar
  and unattended scans retain source errors and Brew stderr, self-update signature and
  helper failures are persisted, and the root helper audits rejected XPC connections and
  every whitelisted operation. Adds `network`, `process` and `helper` log categories.
- `CatalogRefresher` is now wired into the running app: the bundled `endpoints.json`
  carries an `appCatalog` source URL, and the **Info → Katalog aplikacji** card offers
  a one-click "Odśwież katalog" with status feedback. The overlay is refreshed
  out-of-band without shipping a new build.
- VoiceOver accessibility labels on icon-only controls across the UI (menu-bar agent,
  close buttons, sort headers, select-all toggle, and source/status badges).
- `PostmanUpdateChecker` — Postman self-updates via Squirrel.Mac (no Sparkle feed) while
  its Homebrew cask `postman` lags the real channel, so `brew outdated` and the
  cask-version check both saw it as current. The checker queries Postman's own Squirrel
  feed (`dl.pstmn.io/update/osx_64/<installed>`, the `osx_64` channel that carries the
  live build even on Apple Silicon) — the same vendor-feed pattern as ChatGPT/Parallels.
  Unit-tested through the injected `HTTPClient` seam.
- `AppOrigin` — one install-origin classifier (Brew / App Store / npm / manual) shared by
  the Inventory badge and the Updates-window grouping (`UpdatePlanner.groupManual`), so
  the two windows can never disagree about where an app came from. `ManualUpdateScanner`
  stamps it onto every outdated result. Pinned by `AppOriginTests` and the grouping tests.
- Richer Logs view (`ScanLog`, unit-tested): each scan now logs **what** it found
  (one line per update — `Docker 4.78.0 → 4.79.0 · Homebrew cask`), a **per-source
  breakdown** (`formuły: 1, caski: 1, MAS: 0, npm: 0, ręczne: 2`) with the silent sources
  named instead of a bare count, the **real brew `Error:` line** behind a failed
  install/upgrade (not just `kod 1`) plus the command that was run, and **per-checker
  DEBUG lines** with timing for the checks that engaged a source.
- This `CHANGELOG.md`.
- **A headless self-update ends with a restart, not silently.** Installing the `.pkg` swaps
  the bundle under the running process; the app now says so and offers a restart button,
  disabled while any mutating operation holds the write gate. It never restarts on its own.

### Changed
- Selection checkboxes in the update and uninstall lists, and in the leftover picker, are
  real `Toggle`s behind a custom style that keeps Wega's honey glyph. VoiceOver now
  announces them as a checkbox with a state instead of a button carrying a value, and the
  space bar activates them as a system control. The tri-state "select all" control stays a
  button on purpose — a two-state checkbox cannot say "some", so it keeps the spoken count.
  Migration and npm/brew duplicate rows name the app in their action labels, so identical
  buttons are distinguishable without sight.
- **Wega's own update row leads to the in-app installer, not to a browser.** The row used to
  open the release page, stepping around the signature verification and helper install that
  the Settings screen performs. *Check for Wega Updates…* is now in the app menu as well,
  where macOS users look for it.
- **Install-vs-open is decided in one place, from the full release.** The checker reported a
  single pre-selected asset, so the planner could only comment on a decision already made.
  It now reports **every** published asset and `SelfUpdatePlanner` is the single decision
  site: with the privileged helper enabled a `.pkg` is installed headlessly, otherwise the
  same artifact is handed to the user to finish. The **choice of artifact is not part of that
  decision** — it stays `.pkg` → `.dmg` on security grounds (see SEC-04 below), so turning
  the helper off changes how an update is applied, never which bytes are fetched.
- ⚠️ **BREAKING — the minimum supported macOS is now 26 (Tahoe).** The deployment target
  moved from macOS 14 to macOS 26 (`Package.swift`) because the rebuilt window chrome is
  built on **Liquid Glass**, which macOS 26 introduces; CI moved to the `macos-26` runner in
  the same change, because a macOS 15 runner cannot execute the resulting binary. There is
  no fallback rendering path and no compatibility shim: **on macOS 14 or 15 this build will
  not install or run.** If your Mac is below macOS 26, do not take this update — it will not
  leave you with a working app. Building from source correspondingly requires **Xcode 26**
  (the full app, not the Command Line Tools alone).
- Hardened the no-TTY sudo path (`SEC-05`). Production no longer writes or executes
  user-modifiable askpass/sudo shell scripts from Application Support. The packaged app
  embeds compiled `WegaAskpass` and `WegaSudoShim` executables, signs them inside-out,
  and cryptographically revalidates their code bytes before every environment attachment.
  Brew and mas now run with an explicit environment allowlist, so loader variables and
  inherited escape hatches such as `WEGA_SUDO_REAL` never reach the authorization path.
  Inherited `PATH` and `SUDO_ASKPASS` are now override-only; the latter can come only from
  a successful trusted-component resolution, including a fresh resolution inside the sudo
  shim. Runtime accepts the signed components exclusively from the symlink-free, root-owned
  and non-user-writable system payload under
  `/Library/Application Support/WegaMacUpdater/Authorization`. The PKG installs it as
  root-owned `0755` directories and `0555` executables. Bundle, DMG and network/FUSE
  locations are no longer runtime fallbacks, removing their validation-to-use race.
  The PAM writer uses backup → atomic replacement → readback verification → rollback;
  without the signed helper the UI fails closed and offers a transactional Terminal command
  whose active-directive check ignores commented `pam_tid.so` lines.
- The catalog's conditional-GET validator (ETag) is now persisted, so a relaunch
  revalidates instead of re-downloading the whole catalog. The catalog is fetched once per
  launch, which is precisely when a process-lifetime validator is guaranteed to be empty.
- Text sizes across the window come from a semantic scale instead of ~225 hard-coded point
  sizes between 8 and 28 pt (`UX-03`). Every call site goes through one alias in `WegaTheme`
  (`Font.wega(_:weight:monospaced:)`), which resolves to a macOS text style — so the
  interface follows the system's text-size setting rather than staying frozen at whatever
  size was typed into each view. Two fixed sizes remain on purpose and say so on the spot:
  the letter drawn inside a package's fallback tile and the decorative binary rain, both of
  which are drawings sized by their own container rather than running text.
- Perpetual animations now answer **Ogranicz ruch** (Reduce Motion) through one shared
  policy rather than one condition per view (`UX-03`). Wega's bouncing ball, her blink, her
  idle "tricks" on empty states and the sweeping bar under a running check all stop, and
  each of them notices the setting being switched on while it is already running instead of
  only at first appearance. Where a moving element carried information, the information
  stays: the check-in-progress bar drops its sweep rather than freezing at full width, which
  would read as "finished", and the spinner and command line beside it still report the
  state.
- The **Settings** window (⌘,) is resizable instead of pinned to exactly 640×600
  (`UX-03`). It still opens at that size; at larger system text sizes it can now grow rather
  than clipping its own content.
- Split `ScanStore` across two files along the seam it already had: `ScanStore.swift`
  keeps the published state and the small operations over it, and the scan/upgrade
  actions move to `ScanStore+Actions.swift`. The type, its API and its behaviour are
  unchanged; the members the actions half reaches for are `internal` rather than
  `private` now that the two no longer share a file, except `sourceReports` /
  `lastScanComplete`, which keep their `private(set)` behind `applyScanSourceReports(_:)`
  so the view tree still cannot assign them. At 1041 lines the file had ~9 lines left
  under the `file_length` warning that `swiftlint --strict` fails on; it is now 324 and
  742.
- Tightened the SwiftLint metric guardrails (`file_length`, `function_body_length`,
  `cyclomatic_complexity`, `type_body_length`) from "thresholds the tree happens to
  clear" to values just above the current maxima, so they catch genuine growth instead
  of only catastrophic blow-ups.
- Corrected the SonarCloud coverage-exclusion rationale: the SwiftUI app is an
  `executableTarget` that the `MacUpdaterCore`-only XCTest bundle structurally cannot
  `@testable import`, so it's excluded from "lines to cover" by necessity (not as an
  architecture-preference penalty). Real coverage gains come from moving logic down
  into the tested Core planners — which the new checker tests above extend.
- Cleared the open SonarCloud code smells: de-nested ternaries (`S3358` in
  `BrewUpgradeOutcome`/`ContentView`), explained the intentionally-empty closures
  (`S1186`), one-declaration-per-line (`S1659`), and named the unused XPC delegate
  parameter `_` (`S1172`). The four `S1075` "hard-coded URI" hits in
  `CodeSignatureVerifier` (`/usr/sbin/spctl`, `/usr/sbin/pkgutil`) and `HelperDelegate`
  (`/usr/sbin/installer`, the `/Applications/` boundary) are documented-suppressed in
  `sonar-project.properties` — like the existing `SystemPaths`/`SudoShim` entries, these
  run as root and making them configurable would be a privilege-escalation vector.
- Extended `sonar.coverage.exclusions` to the structurally-untestable I/O infrastructure
  (XPC helper target + `BrewService`/`MasService`/`NpmGlobalChecker`/`CaskDatabaseClient`
  shells, `ManualUpdateScanner`/`MenuBarUpdateChecker` orchestration, `AppScanDirectories`/
  `LiveConditions`, and the `BiometricGate`/`CodeSignatureVerifier` system-framework
  wrappers). Their pure logic is already extracted into tested parsers/planners; the
  remaining glue can't be reached by the XCTest bundle without a real system/root/network
  — same rationale as the already-excluded SwiftUI app, documented inline.

### Removed
- The obsolete root `clean.sh` one-shot generator (`QA-08`). Despite its cleanup-like
  name, it overwrote application sources, staged the whole repository, committed
  directly to `main`, and could delete a worktree and branch. A regression guard in
  `scripts/check.sh` prevents this destructive entry point from returning.
- The unreachable **on-device model tier** of release-notes triage (`LT-04`). Wega shipped
  a second triage path built on Apple's Foundation Models, meant to produce a
  natural-language summary beside the "possible security fix" badge. Nothing ever called
  it and no screen ever displayed that summary, but it still made the `FoundationModelsMacros`
  plugin a hard build requirement — so contributors needed the full Xcode for a feature no
  user could reach, and the documentation described the app as doing on-device AI triage
  that never ran. The badge is unchanged: it has always come from the deterministic keyword
  scan, which stays and is now covered by `ReleaseNotesTriageTests`. `README.md` and
  `CONTRIBUTING.md` now describe the badge and the toolchain requirement accurately.
- The post-migration **"clean leftovers"** step (`SEC-01`). After a successful
  `brew install --cask` the Migration screen scanned `~/Library` for the app's bundle id
  and offered every hit as a leftover of the old installation. A migration doesn't change
  the bundle id, so those paths — `Application Support`, `Preferences`, `Caches`,
  `Saved Application State`, `Containers` — were the *live* data of the app just adopted.
  Every entry was preselected, deletion went through `removeItem` (permanent, bypassing
  the Trash the rest of the app uses), per-item failures were swallowed, and the sheet
  reported `urls.count` as the success count — so it always claimed full success, even
  when it had deleted nothing. A migration now ends at the success banner and touches
  nothing in `~/Library`. `MigrationPlanner.libraryLeftoverCandidates` stays (pure path
  construction, deletes nothing) and is guarded against regaining a caller by
  `MigrationLeftoverCleanupDisabledTests`.

### Fixed
- **Manual cask adoption bypassed the upgrade safety boundary (P1).** Both the Updates
  screen's manual `brew install --cask --force` action and the Migration wizard now take
  the shared upgrade mutex and pass the hard disk/network/power gate before downloading.
  They read the installed app's Team ID before replacement, reject a mismatch without
  changing the trusted baseline, require a copy-on-write rollback snapshot, and run the
  shared Gatekeeper/publisher canary afterwards. A rejected replacement is rolled back
  and cannot produce a success banner. The pre-mutation Team ID now travels directly into
  that canary, and the installed app path is resolved again after Homebrew finishes, so a
  move between `~/Applications` and `/Applications` cannot make Wega verify or restore the
  stale source path. The replacement keeps the concrete artifact name and bundle ID, so a
  multi-app cask cannot redirect the canary or rollback to its first declared app. A missing
  post-install target, or the same artifact existing in both application directories, fails
  closed and retains the snapshot. Bundle-identity mismatch rollback now also restores from
  a working copy so the original snapshot survives successful automatic recovery.
- Three Auto Layout constraint loops the rebuilt window chrome introduced — at startup with
  the inspector, during a scan, and on scan completion — which logged continuously and could
  take the toolbar layout down with them. A UI test reproduces the scan-toolbar case. The
  sidebar also stays steady and inset while a scan runs, the scan button is disabled while an
  update is installing, and the duplicate scan progress bar and duplicate rescan button the
  chrome rewrite left behind are gone.
- **Every child process the update pipeline waits on is now bounded.** The existing guard
  refused `timeout: nil` anywhere in `Sources/`, which closed the front door and left the back
  one open: a `Process()` built directly and waited on with `waitUntilExit()` never sees
  `ProcessRequest`, so it has no deadline, no inactivity limit and no SIGTERM → grace → SIGKILL
  escalation. One had survived exactly there — the npm locator ran `$SHELL -lc "command -v npm"`
  that way, so a login shell hanging on a network mount in someone's `.zprofile` hung the
  locator, and through it every npm operation in a scan. Two smaller cases of the same class:
  the diagnostics export paired a 5-second deadline with an inherited 180-second inactivity
  limit that could never be reached, and `pgrep`/`killall`/`open` ran on the ten-minute policy
  sized for a network metadata query, while that policy's own documentation names those three
  commands as belonging to the short one.
- The typography guard follows the code instead of a folder. It scanned one directory,
  non-recursively, sweeping in 32 files there that build no views while being unable to see a
  new subdirectory or a second SwiftUI target; it now scans every module and selects on
  `import SwiftUI`, so a file gains views and gains the guard in the same edit. The migration
  log's last hard-coded surfaces moved into the palette as well — still deliberately dark in
  both appearances, the way a console is, but owned by the theme rather than written into a
  view.
- **The helper status chip is a real button when it does something.** It opened **System
  Settings → Login Items** from a bare tap gesture on a stack of views — no button role, no
  keyboard path, nothing for VoiceOver to announce as actionable, reachable only by aiming a
  mouse at it. It is now a button exactly in the one state that has somewhere to go, and stays
  a plain label in the two that do not: a disabled button would still announce itself and still
  take a tab stop that leads nowhere.
- **A damaged disk image can no longer hang the self-update.** The signature verifier waited
  on `codesign`, `spctl`, `pkgutil` and `hdiutil` with no deadline at all — and the self-update
  mounts its `.dmg` through exactly that `hdiutil attach`, so a truncated or damaged image left
  the update wedged with nothing to cancel. Those commands live in the base module the root
  daemon links, which is out of reach of the runner that bounds everything in the update
  pipeline, so they now go through a small synchronous equivalent with the same
  signal-then-grace-then-kill escalation. Both layers name their limits from one shared policy
  rather than restating them.
- **Launching at login no longer takes the keyboard away.** The main window's appearance
  triggered an unconditional focus grab, so enabling "Launch at login" meant every login put
  Wega's window over whatever you were doing. Activation now happens only where you asked for
  it — the menu bar's "Otwórz Wega", and the alert that must be seen before the app quits
  mid-mutation. The window still opens at login; it no longer interrupts.
- **A granted App Management permission unblocks unattended rounds again.** Both update paths
  armed the 24-hour hold after macOS refused to replace a bundle, but only the unattended one
  ever released it. Granting the permission and completing an update from the window left the
  hold in place with nothing left to justify it, and nothing on screen said why — the cost
  landed in the path you were not watching.
- **The app no longer aborts at launch when run unbundled.** `UNUserNotificationCenter` raises
  an exception rather than failing softly when there is no bundle identifier, so the
  notification router's startup call killed every `swift run` and the subprocess the layout
  regression test drives. A bundled `.app` never showed the difference.
- README's checker counts are tied to the code that defines them. It claimed nine manual
  checkers against the thirteen actually built, and named four of the eight sources routed
  through an app's own updater; a guard now compares both files and requires the count as a
  digit, since a spelled-out number is what went stale.
- **Destructive fallbacks no longer change meaning without consent (UX-04).** A
  migration now identifies every running candidate by its resolved bundle path (or one
  unambiguous bundle ID), asks that exact app to quit normally and waits; only an app that
  remains open produces a separate unsaved-data warning. After explicit approval Wega
  resolves the target again, sends `SIGKILL` only to that PID, and confirms it stopped
  before Homebrew starts. Ambiguous duplicate bundle IDs fail closed.
  A failed `brew uninstall --zap` is no longer retried silently as `--force` without
  zap or counted as success: it stays selected and is reported as an incomplete
  uninstall.
- **The publisher check on a migration match was computed but never asked (LT-03).** The
  match scorer's strongest signal — does the installed app's signing Team ID agree with the
  publisher Wega has recorded for that cask? — accepted both identities and was handed
  neither, so whether `brew install --cask --force <token>` overwrote the right program came
  down to how similar two names looked. The publisher history the cask watchdog already
  keeps is now correlated with the installed bundle's Developer ID: a mismatch drops the
  match to the lowest confidence, refuses the automatic takeover, and says which publisher
  was found versus expected; agreement lifts a match too fuzzy to trust by name alone. The
  ledger is consulted before the signature, so a scan opens only the bundles whose cask has
  a recorded publisher and the confidence badge still costs the view no I/O.
- **A publisher change legalized itself as the new trusted baseline (SEC-02).** The cask
  guard now reads and records the installed app's Team ID before `brew` can mutate it.
  `TeamIDLedger` never replaces a known-good value when classification returns `.changed`;
  the new bundle is rolled back, the alert preserves both Team IDs, and a failed restore
  leaves the snapshot in place instead of deleting the only recovery copy. A foreground
  publisher veto also remains a critical visible result when snapshotting a different cask
  later fails; the whole batch stops before `brew` without discarding the security alert.
- **Cancelling or timing out an operation now really stops the process (REL-12).**
  Stopping a subprocess is a sequence rather than a single blow: SIGTERM to the whole
  process group, a short grace period so the package manager can release its lock and clean
  up a half-written staging directory, then SIGKILL — which still fires for a process that
  ignores the polite signal, so cancelling can no longer hang on a stubborn CLI. Every
  external command is also bounded twice: a wall-clock deadline *and* an inactivity timeout,
  the limit that actually catches a `brew`/`mas`/`npm` that is alive, silent and holding the
  UI. The streamed brew, MAS and npm commands ran with no limit at all until now.
- **Unattended upgrades could run without a rollback snapshot (BG-01).** Background
  candidates now require a resolved `.app` and a successfully created copy-on-write
  snapshot before `brew` may start. Policy and running-process vetoes are sampled again
  after acquiring the upgrade mutex, binary-only casks stay in the user-present flow, and
  any non-zero global brew exit invalidates the whole unattended batch instead of allowing
  the unnamed tokens to be reported as upgraded.
- **The palette assumed a dark window (`UX-03`).** The eight brand colours were fixed RGB
  triples chosen against a dark background, so on a light desktop honey text landed at
  roughly 1.8:1 against the window — well under the 4.5:1 WCAG asks of text, and effectively
  unreadable. Each colour now resolves per appearance, with a separate pair for **Increase
  contrast** in System Settings › Accessibility. Every value clears 4.5:1 twice over: once
  against the window background and once against the 12 %-tinted badge fill it also has to
  sit on, with the increased-contrast pair clearing 7:1; the tests grade the components
  arithmetically, so a future edit cannot quietly reintroduce an unreadable value. Filled
  controls whose label is Wega's dark ink keep a separate, lighter fill value, since a fill
  that darkened with the text would have taken its own label down with it. Hairlines and
  recessed surfaces written as `Color.white.opacity(…)` / `Color.black.opacity(…)` — visible
  only on a dark background — now use the system's adaptive separator and page colours. The
  mascot's own coat colours are unchanged: a drawing is not text.
- **Background rounds silently re-failed an interrupted cask upgrade every time (BG-04).**
  A cask stranded by a cut-short previous upgrade (`Error: <token>: … already an App at …`)
  failed on every scheduled background round with no recovery — the one-time `--force` retry
  the window already performs was missing from the unattended path. The background round now
  reuses `BrewUpgradeOutcome.tokensRetryableWithForce` to retry exactly those tokens once with
  `--force`, inside the same coordinated `.backgroundUpgrade` write lease and after the
  rollback snapshot, so the leftover is overwritten instead of recurring. Whatever still
  fails is folded into the run outcome and its count reaches the notification, turning a
  silent per-round loop into a single visible event.
- **Filtered selections could mutate rows the user could not see (UX-01).** The Updates
  view now derives its button count, select-all state, plan preview and execution targets
  from the active sidebar filter, then names and freezes that exact batch in a confirmation
  dialog; selected App Store rows are passed to `mas upgrade` by ID instead of expanding
  into a global upgrade. The Uninstall view drops selections as search hides them, counts
  only visible targets, lists every approved application and path in its confirmation, and
  passes that frozen collection into execution instead of resolving the filter again afterward.
- **A restart turned a network outage into "everything up to date" (REL-09).** The
  `brew update` failure was discarded on the spot (`_ = try?`), the persisted snapshot
  recorded no per-source result, and a missing Brew answer was written to disk as an empty
  list — so after a relaunch a scan that had established nothing looked exactly like a
  clean bill of health. The snapshot now carries **what each source answered, its error and
  a completeness flag** (`ScanSourceReports`, built from the `SourceCheckOutcome` the scan
  already computes), a missing Brew result stays absent instead of becoming "nothing
  outdated", and a failed metadata refresh counts as a silent source — so it reaches the
  usual *"the list may be incomplete"* banner and the error badge instead of being ignored.
  A restored scan that was incomplete says so with its own banner, and the empty-state hero
  reads *"I can't tell whether everything is up to date"* rather than *"Everything up to
  date"*. `ScanSnapshot` moves to schema 2; a version-1 file is **migrated**
  rather than discarded — its lists still open the window — and comes back marked
  *incomplete*, which is the honest reading of a file that has no way to say whether every
  source answered. A file from a newer build still fails soft to nothing.
- **A hidden global `brew cleanup` after every update (REL-04).** The dry-run panel
  promises the literal set of commands an update will run; the update then finished with
  a `brew cleanup` that appeared in no preview — after an npm-only or App-Store-only run,
  and after a failed one too. Its scope was the whole Homebrew installation, not the plan,
  and it deleted the cached previous versions that recovering from a bad upgrade needs.
  The step is gone; an update now executes exactly the commands it showed. The unused
  `BrewService.cleanup()` was removed with it — a cleanup should return, if at all, as an
  explicit action with its own preview.
- **An update started from a restored scan ran without the safety net (REL-03).** The
  snapshot → canary → auto-rollback chain read the token → `.app` map that only a full
  scan ever filled, so in the most ordinary session there is — launch Wega, look at the
  list it restored from disk, press *Zaktualizuj wszystkie* — the map was empty: nothing
  was cloned and the canary skipped every cask. The bundles are now resolved **at upgrade
  time**, immediately before the snapshot, through one shared `CaskAppPathResolver` that
  the window and the unattended path both use instead of each keeping its own copy of the
  loop, and they are **passed** to the snapshot and the canary rather than read from shared
  state on the way past — a snapshot can no longer be taken without saying which bundles it
  covers. The chain covers every upgrade now, not only one that follows a full scan in the
  same session.
- **Quitting mid-change cut it in half (REL-06).** ⌘Q, *Zakończ Wega*, log-out and shutdown
  ended the process instantly — including in the middle of an upgrade, a background round, an
  uninstall or a migration — leaving a half-written Caskroom with the old version already moved
  aside and the new one not yet in place. The app now defers the quit
  (`applicationShouldTerminate` → `.terminateLater`), names what is running and offers to wait
  for it, and holds a `suddenTerminationDisabled` activity assertion so a log-out cannot kill it
  unasked. Foreground updates, background rounds, migrations, duplicate removals and uninstalls
  all report in.
- **Installation identity is the app's path, not its bundle ID (REL-16).** Inventory,
  uninstall and migration de-duplicated the scan by bundle identifier, so a second copy
  of an application in another folder never appeared in the list and a destructive
  operation silently acted on whichever copy was scanned first. Copies are now identified
  by their standardized path and listed separately; the bundle identifier only groups
  them, and a row whose identifier is installed more than once shows the folder it lives in.
- **Uninstalling a cask now says which copy Homebrew will remove (REL-16).** Homebrew
  removes a cask by token, so for an app installed in more than one place it deletes the
  copy it manages — not necessarily the row that was ticked. The confirmation names every
  folder the app occupies and states that brew picks among them.
- **Descending sort no longer breaks strict ordering (REL-16).** Reversing a column
  negated the comparison (`!less(a, b)`), which returns `true` for both `(a, b)` and
  `(b, a)` when two rows compare equal — not the strict weak ordering `sort(by:)` requires.
  Descending now reverses the operands and breaks ties on the installation path.
- Sparkle-based apps are no longer reported as outdated when the installed
  build is newer than the feed, or when only the version format differs
  (`7.0.0 (77593)` vs `7.0.0`). The checker now compares versions with the
  shared `isUpgrade` comparator instead of matching version strings exactly,
  so it can no longer offer a downgrade as an update (REL-10).
- **A green "everything is done" over a failed update (REL-02).** Six independent paths
  ended in the same lie, and one result type closes all of them: `UpdateRunOutcome` keeps
  **one verdict per item and source**, covering execution, the Gatekeeper canary, the
  rollback **and** the post-upgrade rescan, and success is announced only once every item
  has cleared every phase. Concretely, what changes for you:
  - a `mas upgrade` that fails now names the App Store apps it did not update, instead of
    writing the error into the collapsible log and letting the banner say *"Wszystko
    gotowe"*;
  - a cask the canary rejected and rolled back is reported as not updated — its verdict
    used to arrive after the summary had already been computed and could not enter it;
  - a **rollback that failed** — the new version rejected *and* the old one not restored —
    raises a red **sticky** banner telling you to check that app, instead of a line in a
    collapsed log underneath a green headline;
  - an item the post-upgrade rescan still lists as outdated is not counted as updated, and
    an upgrade the rescan could not confirm (its source went silent) is reported as
    unconfirmed rather than verified;
  - the background notification reports every outcome of the round — rollbacks, failed
    rollbacks, publisher (Team ID) changes and plain failures — and posts even when one of
    those is the round's *only* result, which previously went out silently;
  - the menu-bar badge and the notification are now derived from **one** result taken after
    the background upgrade, and "is this new?" compares the fingerprint of the update
    identifiers instead of their count — installing one update while another appears leaves
    the count unchanged, and the new one used to go unannounced.
- `.pkg` signing in `scripts/build-pkg.sh` and the release workflow: the package was
  signed with the same identity as the app, but `pkgbuild` only accepts a
  **Developer ID Installer** certificate — a "Developer ID Application" identity would
  have failed the first real signed release. The installer identity is now a separate
  second argument (`DEVELOPER_ID_INSTALLER_IDENTITY` secret in CI); without it the
  `.pkg` builds unsigned with a warning and is skipped by notarization (an unsigned
  submission would come back "Invalid"), while the `.dmg` still notarizes. Notarization
  is also gated on a Developer ID being configured at all — a notary key alone with
  ad-hoc artifacts would fail every submission.
- The Updates and Inventory windows no longer contradict each other about an app's
  origin. A self-updating Homebrew cask (e.g. **Docker**) showed "Brew" in the Inventory
  but landed under "Ręcznie zainstalowane" (Manually installed) in the Updates window,
  because brew can't track a version for casks with empty Caskroom metadata. The Updates
  window now groups manual updates by `AppOrigin` (the same classifier the Inventory
  badges by), so such casks appear under **Homebrew Casks** in both windows.
- **Postman** updates were invisible: MacUpdater saw them but Wega did not. Its Homebrew
  cask lags upstream and it ships no Sparkle feed, so no existing source surfaced the
  newer build. The new `PostmanUpdateChecker` queries Postman's own update feed.
- The per-app "Aktualizuj przez Brew" action no longer fails on (and corrupts the brew
  record of) a self-updating cask. It adopted via a plain `install --cask`, which bails
  with "It seems there is already an App at '/Applications/…'" and then **purges** the
  cask's Caskroom entry — leaving brew with no trace of an app still on disk (e.g. Docker
  would flip from "Brew" to "Manually installed"). The action now passes `--force`
  (`BrewService.adoptCaskArguments`), overwriting the existing app and re-recording it —
  the same `--force` the batch upgrade path already used as a fallback for this error.
- README version badge now reflects the real version (`0.1.0`).

### Security
- Configured the real Apple Developer Team ID (`WegaHelper.teamIdentifier`, was the
  `REPLACE_TEAMID` placeholder). This arms every fail-closed path that was dormant:
  XPC peer pinning in both directions (app ↔ privileged helper), helper registration
  via `SMAppService`, and Team-ID verification of self-update installers. Pinned by
  a new `PrivilegedHelperSecurityTests` case that fails CI on any regression to a
  non-Team-ID-shaped value.
- **Self-update now pins the publisher, and an unverifiable build can no longer be a stable
  release.** The update offered the `.dmg` first, and a `.dmg` was accepted on a Gatekeeper
  verdict alone — but Gatekeeper answers "notarized by *some* Apple developer", never
  "published by Wega", so any notarized image from any developer could be presented as a Wega
  update. The `.pkg` is now preferred (it is the channel with a full Team ID pin, and with the
  privileged helper enabled it installs headlessly), and the `.dmg` fallback is pinned too:
  the image's own Developer ID Team ID is checked, the image is mounted **read-only** and
  invisibly, and the single `.app` it carries is verified for Team ID, bundle ID and version
  before anything is opened. A `.pkg` whose Team ID cannot be read is now **rejected** instead
  of quietly falling back to the Gatekeeper verdict, and the version the release promised is
  matched against the payload, so a genuinely signed older build cannot be substituted for the
  update the user was shown. On the publishing side, a tag is released as **stable** only when
  the Developer ID, the installer certificate and the notary key are all configured and the
  artifact gate has confirmed signature, notarization, stapling and Wega's Team ID; anything
  less is published as a **prerelease**, which the self-update ignores. The pipeline stays
  fully runnable without an Apple Developer account — it just cannot call the result stable.
- Hardened the GitHub PAT keychain item (`GitHubCredentialStore`): accessibility moved
  from `AfterFirstUnlock` to **`AfterFirstUnlockThisDeviceOnly`**, so the credential is
  no longer eligible for iCloud Keychain sync or device backups (it can't leak to
  another machine) while staying readable by the background menu-bar check. Resolves
  SonarCloud **S6288** — its only remediation (a `SecAccessControl` requiring Touch ID /
  passcode on every read) is incompatible with the automated/background reads
  (`MenuBarUpdateChecker` → `GitHubReleasesChecker` / `WegaSelfUpdateChecker`), so the
  rule is suppressed for that one file with a written rationale in
  `sonar-project.properties`. Pinned by `GitHubCredentialStoreTests`.

## [0.1.0] — 2026-06-05

One native SwiftUI window that updates every app on a Mac from a single place.

> **This version was never tagged.** `0.1.0` is the state of the tree on the date above, not
> a published release: the repository has no `v*` tag and no GitHub Release, so there is no
> release page to link to and no comparison range to compute against. That is why the heading
> below carries no link. The first tag this project cuts will be **higher than `0.1.0`** —
> `scripts/release.sh` refuses a version that is not greater than `AppMetadata.version`, which
> already reads `0.1.0` — and it will be cut from `[Unreleased]` alone. See
> [RELEASING.md § 9 — Cutting the first release](RELEASING.md#9-cutting-the-first-release).

### Added
- Log redaction now also strips credentials and e-mail addresses, not just filesystem
  paths and URL query strings. `Authorization` headers, bearer tokens, labelled secrets
  (`token=`, `api_key:`, `password=`), PEM private-key blocks, GitHub/Slack/AWS/JWT
  token shapes and addresses are replaced before a line reaches the unified log — where
  any process on the machine could otherwise read it back. The diagnostics export applies
  the same rules **plus** the account's login and display names, which no path-based rule
  can catch on their own.
- **Update** — Homebrew formulae + casks (greedy), Mac App Store (`mas`), npm globals,
  and nine manual-app checkers (JetBrains, GitHub Releases, Synology, Antigravity,
  Parallels, Google Drive Omaha, ChatGPT appcast, Sparkle) deduplicated by source
  priority, with a live log panel and post-update restart of running apps. Distinguishes
  "couldn't check — check your connection" from "everything up to date".
- **Ignore & version-pin rules** — right-click an update to ignore it or pin a version
  ceiling; rules persist and are honoured by the background check too.
- **Uninstall** — removes apps regardless of origin (`brew uninstall --cask --zap`, or
  move to Trash) with an exact-count confirmation.
- **Migration** — moves manually-installed apps onto a Homebrew cask or App Store
  equivalent, cleans `~/Library` leftovers, and resolves npm ↔ brew duplicates.
- **Inventory** — full catalogue of every `.app` with source badge, version, bundle ID,
  and last-modified date; filterable, sortable, searchable.
- **Info** — live diagnostics (Homebrew, mas, macOS, CPU), language switch
  (Polski/English, live, persisted), ignored/pinned rule management, Touch-ID-for-sudo
  setup, and the in-app self-update check.
- **Menu-bar agent** — badge with the available-update count and a scheduled read-only
  background check (off / hourly / 6h / daily) that notifies on new updates.
- **Self-update** — Wega updates itself via the GitHub Releases API using the same
  machinery it uses for every other app.
- Touch ID and askpass fallbacks so casks/`mas` that shell out to `sudo` work without a
  controlling terminal.
- Swift 6 strict-concurrency build, SwiftLint, universal (arm64 + x86_64) packaging,
  and SonarCloud coverage gate in CI.

<!--
  There are no tags yet, so `compare/v0.1.0...HEAD` and `releases/tag/v0.1.0` both 404 —
  they are omitted rather than kept as decoration. `[Unreleased]` therefore points at the
  commit log, and `[0.1.0]` has no reference at all, so its heading renders as plain text.
  `scripts/release.sh` rewrites the `[Unreleased]:` line and appends the new version's own
  reference when the first tag is cut; nothing here needs to be remembered by hand.
-->
[Unreleased]: https://github.com/DominikSienkiewicz/WegaMacUpdater/commits/main
