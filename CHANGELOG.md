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

## [0.5.5] — 2026-10-18

### Fixed
- A scan that missed some sources no longer counts as complete after the app restarts.
  Scans saved by older versions stay unconfirmed until the next check.
- When manual checks fail, the banner and the error log name the sources that could not be
  checked.
- Homebrew updates that macOS App Management refuses, such as Parallels, now offer
  **Open privacy settings** and pause background retries for a day.

## [0.5.4] — 2026-10-05

### Fixed
- Apps whose vendor changed its Developer ID (e.g. Proton Mail) can be trusted again with
  **Trust the new publisher** instead of staying blocked.

## [0.5.3] — 2026-09-30

### Fixed
- Apps updated in-app no longer stay listed once a scan finds them current.
- Checking Obsidian by hand now confirms its in-app update.

## [0.5.2] — 2026-09-29

### Fixed
- When GitHub's rate limit is used up, scans no longer wait minutes for it to reset.
- Stop retrying when the server asks for a wait longer than a minute. (a030fb6)

## [0.5.1] — 2026-09-29

### Fixed
- When the helper can't be reached, self-update opens the verified installer instead of stopping.

## [0.5.0] — 2026-09-29

### Added
- Wega can check whether an update done by the app's own updater actually landed. Pending
  checks survive a restart.
- Inventory shows when and where each app was last checked, with a “Needs checking” filter.
- Cask rows can fetch release notes for the exact version on offer.

### Changed
- The Updates screen is locked while an update runs; only Cancel stays available.

### Fixed
- Self-updates confirm the installed app and version before reporting success.
- A lost helper reply or a timeout no longer starts a second installer.
- Two copies of the same app are checked and updated separately.
- Sparkle builds are compared by build number, not display version.
- A version pinned by Undo stays pinned across every update source.
- Failed or incomplete checks no longer show as “up to date”.
- Updates stop safely if the recovery journal can't be saved.
- Brew keeps downloaded files so a failed update can be repaired.

## [0.4.0] — 2026-09-23

### Added
- **Every update shows what it brings before you apply it** — release notes from Sparkle feeds
  and GitHub Releases appear in the row, one entry per version between yours and the newest.
  Linked notes load when you expand the row; Homebrew, App Store and npm rows show them too
  when another source found notes for the same version.
- **Wega refreshes itself on launch without hiding the last result** — the restored list stays
  on screen, dimmed under a progress ring, and can't be selected until the scan finishes.
- **„Nic nie zainstalowano" gets a „Przeinstaluj przez Brew" button**, which runs
  `brew reinstall --cask` with the same snapshot, verification and rollback as the update.
- **The scan log names casks hidden as already current** — apps that update themselves (Zed,
  Arc, Raycast) no longer look as if they were never checked.
- **updates:** Reinstall the cask straight from the "Nic nie zainstalowano" banner. (a98044a)
- **updates:** Show release notes on Homebrew, App Store and npm rows too. (4b6aac8)
- **ui:** Load a linked release-notes page when the row is expanded. (ceb7b4d)
- **core:** Fetch a linked release-notes page on demand, capped and sanitized. (c731481)
- **updates:** Carry real release notes from Sparkle and GitHub into every manual row. (8faae1b)
- **sparkle:** Read every release between installed and newest from the appcast. (0c60847)
- **core:** One type for what an update brings. (79cbce8)
- **scan:** Turn the busy ring slowly while the fill waits on a phase. (abf842a)
- **scan:** Draw the running scan over the list it is replacing. (620f6f3)
- **menu-bar:** Draw Wega's head instead of a shipping box. (a0bb035)
- **scan:** Refresh at launch without hiding the restored list. (fad3165)
- **scan:** Name the casks hidden as already current. (feea0c5)

### Changed
- **The menu bar shows Wega's head instead of a cardboard box**, tinted for light and dark mode.
- **The security badge reads every release on offer**, not only the newest one.
- **core:** One reading of a GitHub releases list, shared by both callers. (3da5f3d)
- **scan:** Give the scan one face on both screens. (10d627a)

### Fixed
- **„Aktualizuj przez Brew" no longer reports an update that never happened** — a forced
  reinstall that leaves the old version on disk is now reported as not upgraded.
- **Updates can't be started while the list is being refreshed** — „Update selected" and ⌘⏎
  wait for the scan to finish.
- **App icons survive a relaunch** instead of turning into letter placeholders.
- **A nightly or beta build is no longer offered its own stable release as an update** — e.g.
  Little Snitch `6.5 nightly` was read as `6.0.0`.
- **A Sparkle feed that isn't sorted newest-first no longer hides the real update**, and beta
  or nightly channels are skipped unless nothing else is published.
- **ui:** Don't report a collapsed release-notes fetch as a failure. (565aab6)
- **scan:** Draw the overlay's scan at the same size as the full screen. (b2ec5ab)
- **brew:** Detect a no-op update behind 'Aktualizuj przez Brew'. (0363ac0)
- **scan:** Never offer a downgrade as an update (MKT-02). (938a69f)

## [0.3.0] — 2026-08-21

### Added
- **Selected updates run concurrently** — each cask and each npm global gets its own process,
  at most three in flight, with the Homebrew formula batch and the App Store batch in lanes
  beside them instead of after them.
- **Casks that can raise an admin-password prompt stay in a serial lane**, so two Touch ID
  sheets never compete for the screen, and a Homebrew lock collision is retried once because
  it installs nothing when it happens.
- **Every line of the update log names the package it came from** (`[figma] ==> Downloading…`),
  as an untranslated package token, so a flat log fed by several processes stays readable.
- **The interface language switches from the main window toolbar**, not only from a card three
  scrolls down in Settings.
- **A bug report can be composed from the Logs tab** — select entries, expand their failure
  details, and send a redacted report by mail or as a GitHub issue, with a full preview and a
  fallback when no mail client is configured.
- **Process and cask failures carry structured details** — the command, its exit code and its
  stderr — which are persisted with the log entry and redacted before they leave the app.
- **Updating requires an explicit selection**, and every checkbox now sits in one column.
- **The bug-report recipient address is configured in `endpoints.json`**, like every other
  endpoint.

### Fixed
- **„Cofnij aktualizacje" lists one entry per app** — the newest retained snapshot — instead of
  one row per copy kept inside the 7-day retention window.
- **Switching the language no longer closes the details panel**, because the flag moved above
  the view-tree re-key that every `tr(...)` depends on.
- **A cask upgrade that never replaced the bundle is reported as a failure**, not as a success.
- **A same-version takeover no longer reports „nothing installed"**.
- **Redaction works on whole entries and whole files**, so a multi-line PEM key can no longer
  survive it, and truncation no longer stops at the first miss.
- **The overlay's support address is validated** — list separators and percent-encoding are
  rejected, and the `mailto` separator is no longer encoded.
- **A bug report stays under the channel's URL limit**, its preview matches the channel that
  actually sends it, and an unbuildable URL is reported instead of silently dropped.
- **The Logs tab drops its selection when the log is cleared**, a capped stderr block announces
  what it dropped, search reaches the failure detail, and disclosure rows meet the click-target
  guard.
- **The compose window has an identity of its own**, and the success log names the channel it
  opened.
- **An app that is mid-authorization is no longer torn down** (LT-02).

## [0.2.0] — 2026-08-13

### Added
**Wega Mac Updater keeps every application on your Mac up to date from one native window —
whatever installed them.** Homebrew, the App Store and npm each know about their own apps and
nothing else; the rest update themselves, or quietly don't. Wega reads all of them in one pass,
and takes care to distinguish *"everything is current"* from *"I could not find out"*.

#### What it can update

- **Homebrew** — formulae and casks, including the greedy ones a plain `brew outdated` skips.
- **Mac App Store**, through `mas`.
- **npm** — globally installed packages.
- **Apps that update themselves**, on channels their Homebrew cask lags behind or that no package
  manager knows about at all: the JetBrains IDEs, Chrome, Discord, Signal, Obsidian, Postman,
  ChatGPT, Parallels Desktop, Google Drive, Synology Drive, Antigravity, Adobe Creative Cloud
  applications, anything published through GitHub Releases, and any app shipping a Sparkle feed.
  An app that two sources both claim appears once, under the source that should actually perform
  the update.
- **Wega itself**, through the same machinery it uses for everything else.

Homebrew is optional. Without it Wega still checks the App Store, Sparkle, the vendor feeds and
npm, and offers to unlock the rest — rather than meeting you with a wall.

#### It shows you the commands before it runs them

**Show exactly what I will do** renders the literal list of commands an update will execute — the
same call the upgrade itself makes, so the preview cannot drift from the run. For each cask it
also names the download host, whether Homebrew will verify the checksum, whether the rollback net
covers it, whether it may ask for an admin password, and how large the download is. *Size unknown*
is shown as itself rather than guessed.

#### Nothing is replaced without a way back

Replacing an app in `/Applications` is a destructive act, so every Homebrew cask upgrade runs
inside a net:

1. a copy-on-write **snapshot** of the installed app, taken before anything is downloaded;
2. **Gatekeeper** is asked whether the new bundle is acceptable at all;
3. the **publisher** is compared against the Developer ID recorded for that app when it was last
   known-good — a changed signer never quietly becomes the new baseline;
4. the upgraded app is **started hidden for five seconds**, because a correctly signed build can
   still fail to launch;
5. anything that fails **rolls back on its own**, and the app tells you it did.

A shield on each row says in advance whether that net covers it — and shows an honest *no
protection* mark where it cannot, because a cask that installs no `.app` has nothing to clone.
Everything the net keeps is listed under **Undo updates**, with a count of the pre-upgrade copies
still on disk.

Before any of it starts, Wega checks that the conditions are right: it refuses to download on a
metered connection or in Low Data Mode, on low battery, while the Mac is thermally throttled, or
without room for the download, the unpacked payload and the snapshot together. The thresholds are
yours to change.

#### It reports what happened, not what was hoped for

A run is called successful only once every item has cleared every phase, including the rescan
afterwards. A progress bar counts whole packages — *"Installing firefox — 3 of 7"* — and counts
only finished work. There is no download percentage, because Homebrew publishes none when it is
not attached to a terminal, and an invented number is worse than no number. An update can be
**stopped** at the next package boundary: the install already running is never cut in half, and
the report says how many packages were updated and how many were left untouched.

#### Removing and migrating

- **Uninstall** any app regardless of how it arrived — `brew uninstall --cask --zap`, or a move to
  the Trash — after a confirmation naming every application and folder it will touch. Two copies
  of the same app in different folders are listed separately, because they are two installations.
- **Migrate** a manually installed app onto its Homebrew cask, so it can be kept current with
  everything else. The installed app's signing identity is checked against the publisher known for
  that cask first, and a mismatch stops the takeover rather than overwriting the wrong program.
- **Resolve npm ↔ Homebrew duplicates**, where the same tool ended up installed twice.

#### Inventory

Every `.app` on the Mac with its source, version, bundle identifier and last-modified date —
filterable, sortable, searchable. An app Wega has no known way to update can be turned into a
prefilled GitHub issue straight from its row.

#### While you are not looking

A menu-bar item carries the number of available updates and can check on a schedule — hourly,
every six hours, daily, or never. Notifications open the screen they are about: an
updates-available notice opens the list, and a report about an update that was rolled back or
repaired opens the log that explains it.

Unattended upgrades are **opt-in and deliberately narrow**. They are granted one app at a time,
only for casks that qualify, and every grant is written to a consent record you can read back.

#### Staying in control

- **Ignore** an update, or **pin** a version ceiling. The rules survive relaunches and are honoured
  by the background check too.
- **Release notes** appear inline wherever the source publishes them, with a badge marking a
  release that reads like a security fix. Vendor HTML is stripped completely before display — no
  WebKit is involved in showing it.
- **Logs** name what each scan found, which sources answered, which stayed silent, and the real
  error behind a failed install instead of an exit code.
- **History** of the last 40 runs, per item and per phase, rollbacks included.
- **Export diagnostics** writes one redacted `.zip` with everything a bug report needs.

#### What stays on your Mac

Nothing is uploaded anywhere — the diagnostics export asks where to save the file, every time.
Filesystem paths, URL query strings, credentials, e-mail addresses and account names are replaced
with placeholders before a line reaches any log. Crash reporting is **off by default**, collects
only from the moment you switch it on, and has no endpoint to send anything to.

#### It works the way macOS works

Polish and English, chosen from your system language on first launch and switchable at any time
without losing a scan. Text follows the system text-size setting, VoiceOver announces every
control, *Reduce Motion* stops the animations, and every colour clears WCAG contrast in both light
and dark appearances. Touch ID can stand in for the password the package managers occasionally
ask for.

#### Requirements

- **macOS 26 (Tahoe) or newer.** The window is built on Liquid Glass and there is no fallback
  rendering path, so this build will not install or run on macOS 14 or 15.
- Apple silicon and Intel, in one universal build.
- Homebrew, `mas` and npm are all optional — Wega uses whichever are present and says so when one
  is missing.
- macOS requires the **App Management** permission before any app may replace another in
  `/Applications`. Wega recognises a refusal for what it is and links straight to the right pane in
  System Settings, instead of handing you an `Operation not permitted` from a tool that never names
  the app it failed on.
- Install the signed and notarized `.pkg` — it also enables headless self-updates — or the `.dmg`.

#### Free, open, and offered without warranty

Wega is released under the **MIT License** — free of charge, for any purpose including commercial
use, with the complete source available to read, audit, change and pass on. There is no paid tier,
no account and nothing to sign up for. If you want to know exactly what it does before you let it
near `/Applications`, every line of it is in the repository, along with the CI that builds the
artifacts published here.

It is also one person's project, given away as it stands. It is built with care — the safety net
above exists precisely because replacing applications is a risky thing to automate, and the tests,
the lint gate and the signature checks are there to keep it honest — but care is not a guarantee.
Software has bugs, macOS changes underneath it, and a vendor can move a download URL overnight.

So, in the words of the licence itself: the software is provided **"as is", without warranty of any
kind**, and the author is **not liable for any claim, damages or other liability** arising from it
or from its use. The binding text is
[LICENSE](https://github.com/DominikSienkiewicz/WegaMacUpdater/blob/main/LICENSE) — this paragraph
only points at it.

In practice, two honest suggestions: keep the backups you would want to have anyway, and use the
plan preview when an update matters to you. Wega is not affiliated with Apple, Homebrew, or any of
the vendors whose applications it can update; it drives their own published tools and feeds, and
their terms are still theirs.

<!--
  There are no tags yet, so `compare/vX.Y.Z...HEAD` would 404 — `[Unreleased]` points at the
  commit log instead, and is the only reference this file carries. `scripts/release.sh` rewrites
  that line and appends the new version's own reference when the first tag is cut; nothing here
  needs to be remembered by hand. This release describes what the application does rather than
  what changed in it, because there is no published predecessor to have changed from.
-->

[Unreleased]: https://github.com/DominikSienkiewicz/WegaMacUpdater/compare/v0.5.5...HEAD
[0.5.5]: https://github.com/DominikSienkiewicz/WegaMacUpdater/compare/v0.5.4...v0.5.5
[0.5.4]: https://github.com/DominikSienkiewicz/WegaMacUpdater/compare/v0.5.3...v0.5.4
[0.5.3]: https://github.com/DominikSienkiewicz/WegaMacUpdater/compare/v0.5.2...v0.5.3
[0.5.2]: https://github.com/DominikSienkiewicz/WegaMacUpdater/compare/v0.5.1...v0.5.2
[0.5.1]: https://github.com/DominikSienkiewicz/WegaMacUpdater/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/DominikSienkiewicz/WegaMacUpdater/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/DominikSienkiewicz/WegaMacUpdater/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/DominikSienkiewicz/WegaMacUpdater/compare/v0.2.0...v0.3.0


[0.2.0]: https://github.com/DominikSienkiewicz/WegaMacUpdater/releases/tag/v0.2.0
