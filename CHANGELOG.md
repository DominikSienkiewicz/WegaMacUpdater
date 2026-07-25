# Changelog

All notable changes to **Wega Mac Updater** are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The version lives in exactly one place — `AppMetadata.version`
(`Sources/MacUpdaterCore/AppMetadata.swift`); the release workflow refuses to publish
a tag whose version doesn't match it. Keep the `[Unreleased]` section ahead of each
bump and move its entries under the new version heading when cutting a release.

## [Unreleased]

### Added
- Unit tests for `JetBrainsUpdateChecker` and `SparkleUpdateChecker` — the two manual
  checkers that previously had no dedicated coverage despite driving 14 JetBrains IDEs
  and every generic Sparkle app. Both are exercised through the injected `HTTPClient`
  seam with a fake transport (no network).
- Shared `FakeHTTPTransport` test double in `TestDoubles.swift` for HTTP-level checker
  tests.
- Diagnostic logging through `AppLogger` (OSLog): `HTTPClient` records retry attempts
  and final transport failures, and `ProcessRunner` records non-zero exits, timeouts,
  and cancellations — so a swallowed network/process error is now visible in
  Console.app instead of vanishing. Adds a `network` logging category.
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

### Changed
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
  date"*. `ScanSnapshot` moves to schema 2; a version-1 file is rejected on read (it cannot
  say whether it was complete) and the next scan writes a fresh one.
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

First tagged release. One native SwiftUI window that updates every app on a Mac from a
single place.

### Added
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

[Unreleased]: https://github.com/DominikSienkiewicz/WegaMacUpdater/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/DominikSienkiewicz/WegaMacUpdater/releases/tag/v0.1.0
