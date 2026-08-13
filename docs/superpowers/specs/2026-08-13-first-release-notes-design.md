# First-release notes — describe the app, not the diff

**Date:** 2026-08-13
**Status:** approved

## Problem

`v0.2.0` is the project's first published release. `git tag -l` returns nothing, and `0.1.0`
shipped untagged, so no user has ever run a previous version.

The GitHub Release description is not written separately: `.github/workflows/release.yml`
extracts the `## [<version>]` section from `CHANGELOG.md` with `awk` and passes it to
`gh release create --notes-file`, deliberately without `--generate-notes`. The changelog section
*is* the release page.

That section ran to roughly 677 lines of `Added` / `Changed` / `Removed` / `Fixed` / `Security`
entries written as deltas against `0.1.0`. For the first person to install Wega, two thirds of it
describes bugs they could never have met and behaviour removed from something they never had. The
one entry that genuinely concerns them — the macOS 26 minimum — was filed under
`⚠️ BREAKING`, which is meaningless without a predecessor.

## Decision

The release section describes **what the application does**, not what changed in it.

### Content

One `### Added` heading, with `#### ` subsections inside it:

| Subsection | Covers |
|---|---|
| What it can update | Homebrew formulae and casks, Mac App Store, npm globals, self-updating apps by name, Wega itself; Homebrew optional |
| It shows you the commands before it runs them | the dry-run plan preview and the per-cask facts it reports |
| Nothing is replaced without a way back | snapshot → Gatekeeper → publisher comparison → hidden launch test → automatic rollback; the shield badge; Undo updates; the resource gate |
| It reports what happened, not what was hoped for | verdict per item and phase, whole-package progress, no invented download percentage, cancellation at a package boundary |
| Removing and migrating | uninstall, migration onto a cask, npm ↔ brew duplicates |
| Inventory | every `.app` with source, version, bundle ID, date |
| While you are not looking | menu-bar badge, schedule, opt-in unattended upgrades, notification destinations |
| Staying in control | ignore and pin rules, inline release notes, logs, run history, diagnostics export |
| What stays on your Mac | nothing uploaded, redaction, crash reporting off by default |
| It works the way macOS works | languages, text size, VoiceOver, Reduce Motion, contrast, Touch ID |
| Requirements | macOS 26, universal build, optional tooling, App Management permission, `.pkg` vs `.dmg` |
| Free, open, and offered without warranty | MIT, no warranty, no liability, no vendor affiliation |

Deliberately excluded, as descriptions of construction rather than of what a user gets: the
signed over-the-air app catalog with replay/downgrade protection, the SEC-05 sudo-path hardening,
and the XPC privileged-helper architecture.

No counts appear in the prose. The draft originally claimed "thirteen vendor checkers" from
`README.md`; `ManualUpdateScanner` in fact builds fourteen, because `AdobeUpdateChecker` is
constructed conditionally and with arguments and so escapes the counting regex in
`QA04CheckerCountDriftTests`. Naming the applications avoids depending on a number that is
already wrong and would go stale again.

### Placement

The text goes under `## [Unreleased]`, not under a hand-written `## [0.2.0]` heading.

`scripts/release.sh --continue` refuses to create the release commit when any file other than
`AppMetadata.swift` and `CHANGELOG.md` is modified, and this change also touches `RELEASING.md`
and `README.md`. The prepared release in the working tree is therefore discarded, this branch
lands as an ordinary `docs:` commit, and the release is prepared afterwards from the merged state.

Two properties of `release.sh` make that safe, both verified against the script:

- With no `v*` tag and no `chore(release):` commit in history, the baseline is empty and the
  notes come from `[Unreleased]` alone — no commit-derived entries are appended.
- Content placed above the first `### ` heading inside `[Unreleased]` is dropped by
  `split_sections()`, and a non-canonical heading is re-emitted with every non-letter stripped
  (`### Known issues` → `### Knownissues`). Everything therefore lives under `### Added`, and the
  internal structure uses `#### `, which passes through as ordinary content.

### Removals

- The `Changed`, `Removed`, `Fixed` and `Security` bodies.
- The whole `## [0.1.0] — 2026-06-05` section, including its block quote explaining that the
  version was never tagged.
- The trailing HTML comment about missing tags, replaced by a shorter one that no longer
  references `[0.1.0]` and records why this release is a description rather than a delta.

Everything removed remains in git history.

### Consequential edits

- `RELEASING.md` § 9 stated that the `[0.1.0]` section stays in `CHANGELOG.md` and that its
  link was removed on purpose. Rewritten for a changelog that has no `[0.1.0]`, and extended
  with why `[Unreleased]` currently describes the application instead of a delta.
- `README.md` version badge `0.1.0` → `0.2.0`. No guard ties the badge to `AppMetadata.version`,
  so this is a manual edit and produces no failing test in the interval before the version bump.

## Release sequence

1. `./scripts/release.sh --abort` in the main checkout — discards the prepared bump and heading.
2. Merge this branch.
3. `./scripts/release.sh 0.2.0` — moves `[Unreleased]` under `## [0.2.0] — <date>` and bumps
   `AppMetadata.version`.
4. `./scripts/release.sh --continue` — creates the release commit and the tag.

## Out of scope

Two defects found while verifying this change, both filed separately:

- `release.sh` mangles non-canonical changelog headings, and silently drops content above the
  first `### ` heading.
- `QA04CheckerCountDriftTests` cannot see `AdobeUpdateChecker`, so `README.md` understates the
  checker count it is supposed to keep honest.
