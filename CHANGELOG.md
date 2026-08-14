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

### Fixed
- **The packaged app can read its own resources, and says so instead of dying when it cannot.**
  `AppEndpoints.loadBundled()` and `AppCatalog.loadBundled()` reached their JSON through
  `Bundle.module`, whose SwiftPM-generated accessor searches the `.app` directory and the build
  directory of the machine that compiled the binary, then calls `fatalError`. A packaged app keeps
  its resources in `Contents/Resources`, which is neither — so the app trapped seconds after
  launch, on every Mac, with a message naming a path on a GitHub runner. Both functions were
  already written to *throw* when the resource is missing, and their callers already handled it;
  a `fatalError` simply ran first. A resolver that searches the packaged layout and returns an
  optional restores that contract, and a test refuses `Bundle.module` anywhere in `Sources/`,
  because reintroducing it compiles, passes every test, and breaks only the shipped app.
  Nothing in the pipeline had ever run the app it published: the build now asks it, through a
  hidden flag, to load both files and report. Watching it launch was measured first and rejected
  — the crashing path came from a throttled background task, so a broken build survived about one
  launch in three.
- **The README's manual-checker count reads 14, and the guard that ties it to the code can see
  every checker (QA-04).** The guard recognised only a checker built with an empty argument list,
  so the Adobe Creative Cloud checker — constructed with a catalog and an inventory, and only
  when Creative Cloud is installed — never reached the count. It read 13, agreed with a README
  that said 13, and so certified a claim the scanner had already outgrown, while the priority
  table listing Adobe as its own source contradicted that same sentence a few hundred lines
  earlier. The count now follows the binding rather than the shape of the call, so the next
  checker that takes a parameter is counted as well, and `ManualUpdateScanner`'s own doc comment
  names Adobe alongside the other thirteen.
- **A release could hang instead of failing.** The signing key was imported with
  `security import -T /usr/bin/codesign`, which is the list of tools allowed to use it without
  a keychain prompt. `codesign` signs the `.app`, so app signing always worked — but the `.pkg`
  is signed by `pkgbuild`, a different binary and therefore not on the list. macOS asked for
  authorization, a runner has nobody to answer, and the job blocked on `→ Tworzę PKG...` until
  GitHub cancelled it at its six-hour maximum, with no error anywhere in the log. Every tool in
  the chain is now named, the publishing job carries its own `timeout-minutes` so a future stall
  costs minutes rather than six hours of macOS runner time, and a new step reports which
  identities the `.p12` actually contained — a `.p12` exported with only the Application
  certificate was the other, equally silent way to reach the same stall.

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
[Unreleased]: https://github.com/DominikSienkiewicz/WegaMacUpdater/commits/main


[Unreleased]: https://github.com/DominikSienkiewicz/WegaMacUpdater/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/DominikSienkiewicz/WegaMacUpdater/releases/tag/v0.2.0
