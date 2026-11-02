# Wega Mac Updater
**Designed and maintained by [Dominik](https://www.linkedin.com/in/dominik-sienkiewicz/), built with AI coding agents:** I set the architecture, write the specifications, define the quality gates enforced in CI and review every change.

Native macOS app that keeps every application on your Mac up to date — Homebrew casks, Mac App Store, JetBrains IDEs, GitHub Releases, and Sparkle apps — from a single window, without ever opening a terminal.

![Swift](https://img.shields.io/badge/Swift-6.0-orange?style=for-the-badge&logo=swift&logoColor=white)
![SwiftUI](https://img.shields.io/badge/SwiftUI-macOS_26%2B-blue?style=for-the-badge&logo=apple&logoColor=white)
![Version](https://img.shields.io/badge/Version-0.2.0-lightgrey?style=for-the-badge)
![Homebrew](https://img.shields.io/badge/Homebrew-optional-FBB040?style=for-the-badge&logo=homebrew&logoColor=white)
![Architecture](https://img.shields.io/badge/Architecture-SPM_Modules-purple?style=for-the-badge)
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

Homebrew casks, Mac App Store apps, JetBrains IDEs, GitHub Releases and Sparkle apps — five
sources behind one list, with npm globals as a third package manager. Every update runs behind
a dry-run panel that tells you what will happen before anything does, and a rollback net that
puts the old bundle back when a cask upgrade replaces nothing. Details in
[Features](docs/features.md).

## Diagnostics

Update operations keep local JSONL traces with a run identifier, stage events, subprocess
output and exits, HTTP attempts, and observed vendor-check results. **Export diagnostics**
includes these traces and a manifest of retention limits, incomplete runs and recording
failures in the existing redacted ZIP. It saves locally through a file picker; nothing is
uploaded. Traces are bounded to 8 MiB per run and retained for up to 14 days, 50 files or
64 MiB in total. They describe what Wega observed, including an interrupted operation;
they do not establish why a vendor's own updater crashed. See
[Diagnostics & troubleshooting](USER_GUIDE.md#4-diagnostics--troubleshooting).

## Requirements

macOS 26+, Apple silicon or Intel. Homebrew is optional — without it the cask source is simply
absent and the other four keep working. Full list in [Building and testing](docs/building.md).

## Testing

Tests cover Core policies and app orchestration. Tap-remedy and foreground-diagnostics
checks run in sequential XCTest suites, separately from Swift Testing migration checks
that share the update mutex. Source guards also check the protected reinstall call chain
and the smoke-test opt-out before launch. Commands and quality gates are documented in
[Building and testing](docs/building.md#build-and-test).

## License

[MIT](LICENSE)
