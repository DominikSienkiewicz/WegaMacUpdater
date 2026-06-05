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

### Fixed
- README version badge now reflects the real version (`0.1.0`).

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
