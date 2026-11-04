# Wega Mac Updater

**Designed and maintained by [Dominik Sienkiewicz](https://www.linkedin.com/in/dominik-sienkiewicz/), built with AI coding agents:** I set the architecture, write the specifications, define the quality gates enforced in CI and review every change.

Native macOS app that keeps every application on your Mac up to date — Homebrew casks, Mac App Store, JetBrains IDEs, GitHub Releases, and Sparkle apps — from a single window, without ever opening a terminal.

![Swift](https://img.shields.io/badge/Swift-6.0-orange?style=for-the-badge&logo=swift&logoColor=white)
![SwiftUI](https://img.shields.io/badge/SwiftUI-macOS_26%2B-blue?style=for-the-badge&logo=apple&logoColor=white)
![Homebrew](https://img.shields.io/badge/Homebrew-optional-FBB040?style=for-the-badge&logo=homebrew&logoColor=white)
![Architecture](https://img.shields.io/badge/Architecture-SPM_Modules-purple?style=for-the-badge)

[![Version](https://img.shields.io/badge/Version-0.6.0-lightgrey?style=for-the-badge)](Sources/WegaHelperKit/AppMetadata.swift)
[![CI](https://github.com/DominikSienkiewicz/WegaMacUpdater/actions/workflows/ci.yml/badge.svg)](https://github.com/DominikSienkiewicz/WegaMacUpdater/actions/workflows/ci.yml)

## The Vision: one window, zero terminals

Package managers have proliferated — Homebrew casks, formulae, Mac App Store, Sparkle auto-updaters, JetBrains Toolbox, GitHub Releases. Each lives in a different UI or CLI. Wega centralises all of them: one native SwiftUI window that knows where every app came from and how to update it correctly. No `brew upgrade` in muscle memory, no App Store tab left open, no missed JetBrains IDE because Toolbox uses `auto_updates: true` and `brew outdated` never fires.

## Documentation

Wega's docs are split by audience. **Start with the one that matches what you want to do.**

| You want to | Read |
|---|---|
| Keep your Mac up to date | **[User Guide](USER_GUIDE.md)** — installation → first scan → update → diagnostics |
| Know what the app actually does | [Features](docs/features.md) — every screen and every guard, in the order you meet them |
| Understand the pipeline | [How it works](docs/how-it-works.md) — scan → classify → check → compare → act |
| Read the module layout | [Architecture](docs/architecture.md) — module tree and the sudo/helper boundary |
| Build or test it | [Building and testing](docs/building.md) — requirements, commands, CI gates, versioning |
| Ship a release | [Distribution](docs/distribution.md) — cutting a release and how the app self-updates |
| Contribute code | [CONTRIBUTING.md](CONTRIBUTING.md) — build/test setup, CI gates, the catalog-signature gate |
| Report a vulnerability | [SECURITY.md](SECURITY.md) — the private disclosure channel; please don't use public issues |
| Follow the release runbook | [RELEASING.md](RELEASING.md) — the two-phase `release.sh` flow and the first-release case |

## What it updates

Homebrew casks, Mac App Store apps, JetBrains IDEs, GitHub Releases, Sparkle apps and
Microsoft AutoUpdate share one list, with npm globals as a third package manager.
Package-manager actions expose their commands in a dry-run panel; supported cask replacements
can restore the previous bundle when replacement fails. Vendor handoffs open the owning
updater. Details in
[Features](docs/features.md).

## Installation evidence and repair

Installer-based apps and Java runtimes are associated with Homebrew through exact
installation evidence: package receipts or literal application paths declared by the cask.
Ambiguous claims and duplicate installations do not inherit a package's update result.
When an installed package cask matches by name but its ownership is unverified, Inventory
shows **Homebrew association unconfirmed** with the candidate token. This note does not
mark the copy current or grant it a cask update action or policy alias.
JDKs remain in the scan report even when their source is unknown or Homebrew already
lists their update. These reporting associations do not extend app-bundle rollback to
installer packages or Java runtimes.

Cask repair checks version and build changes before recording success. During a launch
smoke test, an unconfirmed Squirrel/ShipIt withdrawal leaves the app running instead of
triggering its queued installer by quitting it. Details are in [Features](docs/features.md).

## Vendor and App Store update sources

App Store checks identify each installed copy by its exact-path Spotlight App Store ID,
validated against `mas list` and the installed version. Only successful, complete queries
can confirm a current or outdated copy; missing identities and duplicate copies stay unconfirmed.

Vendor feeds run even when Homebrew tracks an app. Comparable offers for the same verified
installation appear once, using the newer version and its update action. Raw source evidence
is retained; incomparable versions and Obsidian's separate package updates remain distinct.
The same reconciliation controls background update candidates.
Apps already listed by `brew outdated` skip the redundant cask-version lookup while keeping
their independent vendor checks. Missing versions for other cask candidates remain visible
as incomplete checks.

WARP and Logi Options+ updates use the vendor's application instead of bulk or background
Homebrew installation. Inventory also recognizes Bitdefender Antivirus for Mac and shows
its installed product version/build separately from the unverified freshness of the product
and threat signatures. WARP's vendor handoff leaves organizational rollout policy in control.

Vendor-installed Word, Excel, PowerPoint, Outlook and OneNote use a read-only Microsoft
AutoUpdate listing and an explicit MAU handoff. App Store copies retain their App Store route.
Only recognized, newer version offers create update rows; an empty or unknown listing never
certifies a particular copy as current. Wega does not install Office through `msupdate`.

Manually installed Firefox and Thunderbird use Mozilla's channel-specific releases. Wega
reads each bundle's channel metadata and keeps Release, ESR and Beta separate, including
overlapping ESR branches. Unknown channels do not inherit a stable-release result. Beta
copies exposing only a base version without the `bN` sequence remain unconfirmed.
Firefox and Thunderbird update actions open the installed app's own updater.
Bruno and UTM use their official GitHub releases without requiring a Homebrew installation.
Bruno opens its own updater with a release-page fallback; UTM requires a macOS release
asset and opens the official releases list, while App Store copies retain the App Store route. Zed checks Stable and Preview
separately and opens the installed app's updater. Cask channel checks also guard migration candidates
and inherited update policies. Opening an updater alone never confirms
that the installed version changed.

## Diagnostics

If Homebrew refuses to load a package definition while untapping, the brew log offers
trust for that exact cask or formula, with its command and persistent effect shown before
the click. Retrying untap is a separate action. Failed remedies remain available; only
a successful command dismisses its action. Wega never automatically trusts a whole tap
or forces removal to bypass this error. Unused taps are removed through separate actions,
so retrying a failed removal does not include a tap that was already removed.

Update operations keep local JSONL traces with a run identifier, stage events, subprocess
output and exits, HTTP attempts, and observed vendor-check results. **Export diagnostics**
includes these traces and a manifest of retention limits, incomplete runs and recording
failures in the existing redacted ZIP. It saves locally through a file picker; nothing is
uploaded. Traces are bounded to 8 MiB per run and retained for up to 14 days, 50 files or
64 MiB in total. They describe what Wega observed, including an interrupted operation;
they do not establish why a vendor's own updater crashed. See
[Diagnostics & troubleshooting](USER_GUIDE.md#4-diagnostics--troubleshooting).

## Docker Desktop updates

Docker Desktop has a separate supervised update flow. The default action opens its own
updater; Homebrew remains an explicit alternative with confirmation. Docker is excluded
from bulk and background upgrades, including previously saved background consent.
Before a Homebrew replacement or rollback, Wega requires confirmed shutdown through
Docker's bundled CLI. It does not force-kill Docker or reset its settings.

An explicit restart checks the local engine with a bounded wait; installing the package
alone never proves engine readiness. Rollback covers only the application bundle, not
settings, VM disks, images, containers or volumes. Docker is excluded from automatic
launch/quit smoke checks, including aliases and renamed bundles. See
[Docker Desktop](USER_GUIDE.md#docker-desktop) and the focused checks in
[Building and testing](docs/building.md).

## Requirements

macOS 26+, Apple silicon or Intel. Homebrew is optional — without it the cask source is simply
absent and the other sources keep working. Full list in [Building and testing](docs/building.md).

## Testing

Tests cover Core policies and app orchestration. Tap-remedy, foreground-diagnostics and
Docker mutation checks run in sequential XCTest suites, separately from Swift Testing migration checks
that share the update mutex. Source guards also check the protected reinstall call chain,
the smoke-test opt-out before launch, generic restart detection, publisher-veto reporting
before mutation, and token-aware manual rollback before journaling and version pinning.
Standalone-source tests cover channel identity, Mozilla beta ordering, GitHub macOS assets,
unknown/error evidence and updater completion.
Scanner regression tests also cover already-listed casks, independent vendor results and
missing versions for candidates that still require a cask check.
Unit-test settings fixtures keep values in memory and clear them during teardown, avoiding
`wega.tests.*.plist` files in the user's preferences directory. They cover settings logic,
not persistence between processes; see [isolated defaults](CONTRIBUTING.md#isolated-userdefaults).
Commands and quality gates are documented in
[Building and testing](docs/building.md#build-and-test).

## License

[MIT](LICENSE)
