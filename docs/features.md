# Features

Every screen and every guard, in the order you meet them. The pipeline underneath is in [how-it-works.md](how-it-works.md).

## Features

### Update

Vendor handoffs retain pending state and offer **Check this app** in both the update row
and inspector. Verification targets one path and source, confirms the offered version/build
on disk (for Obsidian's shared package, the source's own answer) and records an external update in diagnostic history; a full scan whose selected
source finds the same bundle current closes the handoff the same way. Failure remains actionable;
no full Brew scan or background updater monitoring is started. See the
[completion workflow and limitations](../USER_GUIDE.md#finishing-an-update-with-the-vendor).

One screen that checks every source in one pass, shows the exact commands before running
them, and reports one honest outcome per item afterwards.

A band above the list carries the flow. It counts the updates (*"N updates"*), sums up the
queue (*"4 queued · 2 to finish with the developer"*), says how far an undo reaches (*"Undo: 3 of
4"*, or *"Checking undo availability"* while a cask's verdict is still open — a cask without a
verdict is never counted as protected, and once the check has finished it counts as not covered),
links to the dry-run plan (**Show exactly what I will
do**) and holds the screen's one prominent action: **Update N**, or **Nothing selected** while
nothing is queued. The band keeps one height at every window width. Above the rows a scope bar
filters by category and the list-wide checkbox ticks the visible rows. Package rows and manually updated apps share one row layout: a row with nothing to
select keeps the checkbox column empty, so icons line up, and the version sits in the version
column. Release notes are read in the inspector instead of unfolding inside the list. Shared
cards and rows use consistent spacing, larger application icons and readable version changes.
Source labels stay neutral; warning, rollback and security states retain their semantic
colours. The inspector puts trust information, release notes and actions before routine
metadata. Selection, keyboard actions and vendor-update handoffs keep the same rules.

Every notice on the main screens is one shape, `WegaCallout`: a tinted field whose level
(information, success, warning, urgent) alone sets its colour and symbol, with the message
capped at three lines. The Homebrew invitation, result and error banners, the stale-cask
offer and the missing-checksum warning all use it. Wega has a fixed-height card at the
bottom of the sidebar on every destination: it says her line for the current screen, comments
on a scan that just finished, shows when she last looked and asks the one-time notification
question. It replaced the status footer, whose counts were already the sidebar's badges, and
the speech bubble that appeared over the list. Every minute or so a ball rolls along the card; Wega
glances after it, runs off the card's edge and comes back carrying it. The full Wega on the
"everything up to date" screen opens her repertoire of tricks with the same chase. Both are
offset-only animations that never move the layout, and "Reduce motion" turns them off. The
ball waits while an error, an update run or a confirmation is open. Wega's lines speak for
her in the first person and say only what happened: a check that failed reads as *"I couldn't
install X"*, never as cheer, and her cheerful line appears only after a complete check.

The sidebar has one **Updates** row; its badge turns red while a security fix is waiting.
The category — all, apps, CLI tools or security fixes — is a scope bar above the list, each
segment with its count, and becomes a pop-up menu when the window is too narrow for it.
The chosen scope is kept with the window's selection, so clicking the Updates row again does
not reset it. The toolbar carries the scan control (on Updates, To Homebrew and Undo updates only), the language menu (an icon that needs no
translation) and the inspector toggle, which disappears outside Updates instead of dimming.

The app icon uses the approved Wega portrait: broad ears with rounded tips, dark brows and
eye rims, a dark muzzle and a white chin. The animated mascot is her head, drawn the same
way. Its poses,
blinks and Reduce Motion handling remain available. The monochrome menu-bar icon uses
the same head and ear silhouette.

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
- **Grouped by urgency, or by install origin.** By default the list is grouped by what you
  do next: **Possible security fixes** (the manually updated apps whose release notes read as
  a security fix, the same set as the security scope), **Apps** and **CLI tools** that Wega
  updates in a batch, and **Needs your action** for what the vendor's updater or you finish.
  Those cards mix sources, so each package row names its source, and a row the rollback net
  cannot cover carries a muted shield whose tooltip says why. **Group › by source** restores
  the grouping by the same `AppOrigin` the Inventory window badges by, so a self-updating
  Homebrew cask like Postman appears under **Homebrew apps** — never "Manually installed" —
  keeping the two windows in agreement. The choice is remembered.
- Selectable list — update all or pick individually.

#### Installer applications and Java runtimes

The per-installation report resolves `.pkg` and script-installed applications separately
from direct `.app` cask artifacts. `PackageCaskAttribution` uses all owning `pkgutil`
receipt identifiers and literal absolute `.app` paths from a cask's `uninstall.delete`.
It ignores wildcard, relative and `zap` paths. Claims must identify one installation and
one installed cask; ambiguous claims, duplicate copies and App Store installations cannot
borrow another copy's Homebrew result. The catalog cache uses `casks-v4.json` so an older
cache without the added uninstall-path metadata does not silently hide that evidence; v4 also
keeps each cask's zap paths for the uninstall leftovers list, so the first run after updating
downloads the catalog once more.
An installed package cask matched by the catalog but lacking verified ownership remains
visible as an unconfirmed association. Inventory shows its candidate token and an explanation,
including when receipts are missing or ownership claims conflict. The note survives saved
scans, supplies no action token or policy alias, and cannot certify a current installation.

Java runtimes are scanned under the system and per-user `JavaVirtualMachines` directories.
`JavaRuntimeAttribution` preserves every discovered `.jdk` in the report, canonicalizes
symlink aliases and uses unambiguous package receipts to resolve a cask. A versioned cask
must match the runtime's Java major version. Installed and tracked runtimes can inherit
Homebrew's per-package outcome; a runtime already listed by `brew outdated` remains visible
without creating a duplicate manual update. Missing or conflicting evidence stays unconfirmed.

These are reporting associations. `CaskAppPathResolver` still supplies only direct app
artifacts to the snapshot and replacement machinery; recognizing a package's installation
does not promise a snapshot or rollback for it.

#### Vendor ownership and per-installation checks

A completed Mac App Store query can certify a copy only after its exact-path App Store ID
and installed version agree with `mas list`. Partial output, duplicate IDs and unresolved
copies cannot borrow a successful result. Vendor feeds run independently of Homebrew
management; comparable package/vendor offers retain the newer version and its action once,
including in background candidate selection. Raw evidence and incomparable offers remain.

WARP and Logi Options+ use vendor handoffs, with no batch/background Homebrew installation
or generic cask adoption. Exact package ownership may provide the handoff target; ambiguous
paths expose instructions instead of opening a guessed copy. Organizational WARP controls
remain with the vendor/administrator. Bitdefender's exact antivirus identity exposes product
version/build and separately unconfirmed product/signature freshness; Agent and VPN do not
supply the antivirus version.

Vendor-installed Office applications use a bounded MAU list query and a user-opened MAU
flow. Recognized newer offers are tracked; no-update messages lack per-copy registration
proof and remain unconfirmed. The parser recognizes the published text offer shape
and the locally observed ANSI progress/no-update variant, and fails closed on unknown
formats. App Store copies retain their own update route. No Office install or configuration
command is run by Wega.

#### Before anything runs — the dry-run panel

**"Show exactly what I will do"** in the band opens the **dry-run panel** as a sheet. It
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
read the same `UpdatePlanner.unifiedCount`. Next to the queue the band names the updates you finish
with the developer in the category on screen — *"4 queued · 2 to finish with the developer"* —
because Wega never queues those: she hands them over instead of installing them. With nothing
queued it says only *"0 queued"*. The button counts only what Wega installs
itself, so it never promises an upgrade Wega cannot perform. A scan run from the
window reports its result to the menu-bar agent, which is the single owner of the dock badge.

#### Nothing is updated that you did not tick

The band's **Update** button acts on the queued rows and on nothing else. With an empty queue
it is disabled and says so — *"Nothing selected"* — rather than reading *Update all* and
upgrading every visible row on the first click. `UpdatePlanner.plan` no longer treats an
empty key set as "everything" either, so no caller can arrive without a selection and mutate
the whole machine.

Selecting in bulk is a choice you make, not a default you inherit: the list-wide checkbox
ticks visible package-manager rows, and each section header — *Homebrew tools*, *Homebrew apps*,
*Mac App Store*, *npm globalne* — carries its own tri-state checkbox that ticks or clears
just that group, leaving the other sections alone. All three controls share one column and
one glyph, so "select this row", "select this group" and "select everything" read as the same
choice at different widths.

Eligible app-bundle repairs and takeovers under **Updates through Homebrew** can be ticked
individually. The batch confirmation identifies the app and its path. Wega checks the
installation and catalog offer again before running the protected Homebrew action.
These replacements run one at a time as part of the same update run.

#### The window opens with a result, not an empty screen

The last scan is restored the moment the window appears — from disk (`ScanResultStore`, a
`Codable` snapshot) or from the lists the menu-bar agent already built during its last
background check, whichever is newer. An old result never passes for a fresh one:
`ScanFreshness` decides, and anything a day old reads *"Found 12 Jul, 21:14"* in a warning
tint instead of a bare time. Progress during a scan is **real** — the scan is strictly
sequential (brew → mas → npm → manual), the bar reports the phase it is genuinely in, and
**Cancel** stops it where it stands. Live log streamed into an inline panel.

**A young Homebrew catalog is kept at launch.** The launch scan skips `brew update` when the
last successful refresh is under 30 minutes old (`BrewCatalogFreshness`; a missing or future
stamp refreshes), and the band says so with a chip — *"Homebrew catalog from 12 min ago"*, the
age counted to the scan's start. **Check now**, **⌘R** and every other scan always refresh the
catalog first, and the queue waits until the scan ends either way.

Every scan that starts with a result on screen — the launch refresh, **Check now** and **⌘R** —
runs *in the band* rather than replacing the list. The band says
what the scan is doing: a line naming the step (*"Refreshing the Homebrew catalog…"* while
`brew update` runs, then one line per source — Homebrew, App Store, npm, vendors), the time the
patrol has taken (counted up from the start, never estimated down), what has been found so far,
and a ring and a chip per source, each done, running or not yet started. Once the vendor step
starts it adds a counter, *"Vendors: 12 of 31 apps"*; a vendor step with no app to ask keeps the
note instead of a counter of zero. Wega sniffs through the whole scan, with the binary code she
sniffs streaming behind her across the band (behind the *"Everything up to date"* heading when
there is no band); Increase Contrast leaves it out and Reduce Motion holds it still. The rows stay
readable but stop accepting selections. The scanner lies on them: the window's background at half
strength, a honey line sweeping down the visible list, and a lock label, *"The list unlocks when the
scan finishes"*; nothing is blurred, and the list still scrolls. Reduce Transparency leaves the veil
out and Reduce Motion stops the line. A note — *"Selecting comes back when the scan
finishes."* — says why: in the band, and in the list header where it fits, yielding to the scope
bar at the narrowest width. Only a scan with nothing to keep on screen — the very first one —
takes the whole window with the sniffing scene, with the same step caption. The check after an
update run and the rescan after any undo, whichever screen started it, run in the band as well
while results are on screen, with the list in place (see *The check after a run and the summary* below).
An empty state — *everything up to date*, or a list the last scan could not confirm — has no rows
to hold still, and Wega stays clear of it. The band's **Update** and its **⌘⏎**
shortcut are held back while the scan runs, because a batch approved against the restored rows
would otherwise install whatever the scan had settled on by the time the dialog was answered;
the button's tooltip names the running scan instead of blaming an empty selection.

**Finding an app on Updates.** **⌘F** (and **Find an app** in the toolbar) does not filter the
list. It shows one answer row above it. When the app is among the updates, the row links to the
matching rows. Otherwise it says what Inventory
knows: up to date and how it was checked, no known source to update from (with **Report app ›**,
Inventory's catalog report for that app), the check failed, no
current result, hidden by one of your rules, or not on this Mac. **Show Rules** accompanies an
answer about your rules, **Open Inventory** the others. It never starts an Inventory read; when
Inventory was never read it says so. An answer from an Inventory read that may have changed, or
that was incomplete, carries that caveat.

**The scan button where the scan shows.** The scan button is a small round button on the Updates
screen, not in the toolbar: beside the band's big **Update** circle (above it in the narrowest
band), beside the *"Everything up to date"* heading when there is no band, and beside the first
scan's progress bar. It shows ↻ **Check now**, and ■ **Cancel Scan** while a scan runs that can
be cancelled; the check after an update run cannot be, so it shows a greyed-out ↻. It is one size
in every state, so nothing beside it moves. To Homebrew keeps its own **Scan again** and Undo
updates re-reads its list on arrival, so neither carries it. **⌘R** and **⌘.** work on every
screen.

**Rules that hide updates.** *Don't update*, *Skip this version* and *Pin version…* (the **⋯**
menu on Homebrew, App Store and npm rows; the context menu on rows the developer finishes) each
write a rule. *Don't update* and *Skip this version* hide the row at once, and an **Undo** toast offers
the change back for 8 seconds; VoiceOver hears the toast, and while VoiceOver runs it stays until
it is closed. *Pin version…* has no toast and hides the row when the offer is above the
pin. A row any rule hides leaves the queue, wherever the rule was made. The line *"Hidden by your
rules: N · Show"* under the list (it also shows under the empty state, so hiding the last update
never leaves the list without the way back) opens the sheet of rules, where **Restore** removes
one; the row comes back to the list, never into the queue; the same rules are listed under **Settings → Checking & Background →
Paused updates**. A scan's note on a skipped version
says the next one will be shown.

#### Running the update

The band shows the run in progress. Its heading reads *"Updating ·
since 08:14"* (the start time, never an estimate of the end), the stage line names the work
(*"Installing firefox — 3 of 7"*; *"Installing packages — 3 of 7"* while several run at once),
a ring counts whole packages as *3/7*, and the band holds **Stop After Active Installs** (and **Show log** once you have closed the log
that opens with the run). During installation the list dims and reads *"The list unlocks
when the update finishes"*. Its checkboxes and install actions are disabled. **Reduce
Transparency** keeps the text and removes the dimming. Casks and npm
globals show their own state on the row — *waiting*, *installing…*, *installed, checking*,
*failed* or *won't start* (a row the run will not begin after a stop request or a vendor
signature change); the Homebrew formula batch and the App Store batch say *in progress* once in
the group header, and an update the vendor finishes says *with the vendor*. A row keeps its
height when its state appears. The log panel under the list opens by itself when the run starts; **Show log** in the band reopens it after you close it. The band is the
one place the stop button lives, so it stays enabled while the list is locked.

- **Selected updates run side by side.** A run no longer walks its selection one package at a
  time: each cask and each npm global gets its own package-manager process, with **at most
  three in flight**, while the Homebrew formula batch and the App Store batch run alongside
  them. Formulae stay one `brew upgrade` on purpose — they share dependencies, and a process
  each would rebuild the same dependency several times over, which is slower rather than
  faster. Casks whose stanza can raise an admin-password prompt (`pkg`, `installer`,
  `preflight`) are upgraded strictly **one at a time**, as is any cask whose artifact profile
  is not known, so two Touch ID sheets can never compete for the screen. Concurrency adds
  exactly one new failure — brew refusing because another brew already holds a lock it needs
  — and because nothing was installed when that happens, that cask is **retried once**. The
  live log prefixes every line with the package it came from (`[figma] ==> Downloading…`),
  and the band counts whole packages, naming the one that is installing only while it
  is the only one. **Stop** still stops at a package boundary: the processes already running
  finish, nothing new is started, and everything still queued is reported as skipped rather
  than as anything else.
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

#### Untrusted Homebrew taps — fixed from the brew log

Homebrew 7 ignores formulae, casks and commands from third-party taps you have not trusted,
and prints a tap-trust warning into the output of most brew commands. When the brew log on
the Updates screen carries that warning, a notice above the log offers the fix as buttons —
no commands to copy into a terminal:

- **A tap something installed came from** gets the **narrowest trust**: *"Zaufaj
  zainstalowanym caskom"* / *"…formułom"* runs `brew trust --cask -- <tap>/<token>` (or
  `--formula`) for exactly those installed items. Whole-tap trust, which also covers
  everything the tap publishes in the future, is never offered.
- **A tap nothing installed came from** is unused: **Remove Unused Package Sources** runs
  `brew untap -- <tap>`, Homebrew's own first suggestion. Each tap has its own action,
  so a failure on another tap never retries a removal that already succeeded.
- **"Came from" is read from Homebrew's install receipts** (`source.tap` in
  `Caskroom/<token>/.metadata/INSTALL_RECEIPT.json` and
  `Cellar/<name>/<version>/INSTALL_RECEIPT.json`), never from a token that happens to share
  a tap's name — a `cmux` cask installed from `homebrew/cask` does not keep the
  `manaflow-ai/cmux` tap in use.
- **Nothing runs until you click**, and each row shows the exact command its button runs.
  The command goes through the same write gate, mutex and quit guard as every other brew
  change; its output is appended under the warning. A button is withdrawn only after a
  successful exit; failed or unfinished actions remain available. The list is locked during
  an update, so it offers no buttons.
- **A trust refusal during untap has a separate recovery action.** Homebrew can load a
  same-named package from the tap before checking its install receipt, even when the
  installed copy came from another tap. Wega recognizes the exact cask/formula refusal
  for the attempted untap and offers `brew trust --cask -- <tap>/<token>` (or `--formula`)
  for that definition. This does not assert that the installed copy came from that tap.
  The row explains that the trust remains saved. Trust requires its own click, and untap
  requires a separate retry; neither runs automatically. Wega does not use whole-tap trust,
  `untap --force`, or disable Homebrew's trust checks as a fallback.

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

A Team ID read from a signature is only that signature's claim: an ad-hoc signature can claim
any Team ID, and a bundle edited after signing still reports its publisher's. The check after
an upgrade and **Trust the New Signature** count a Team ID only when a Developer ID certificate
carries it and the whole bundle validates against it, in every architecture, including nested
code and under the strict rules (`CodeSignatureVerifier.validatedTeamID`). The same team's Apple
Development or Apple Distribution certificate, which any team member can make, does not count. A
bundle that fails validation reads as having no Team ID there: against a baseline the check
after an upgrade rolls it back, and trust is refused. Everything else still reads the claim:
the check before an upgrade (which also records a first-seen baseline), adoption's pre-check,
the helper's rollback gate, the Trust panel, Uninstall's leftovers, migration and diagnostics.
So a Mac App Store build keeps its Team ID there (its leaf certificate is Apple's), an
installed app whose own signature broke does not block the update that replaces it, and the
helper can still roll back an upgrade whose signature fails as long as the failed bundle claims
the snapshot's Team ID (its gate refuses a bundle with no Team ID or a different one, as before).

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

What decides whether the reading may be applied is not which brew command ran, but whether the
run promised to move the version at all. `brew upgrade` always does, by definition of the item
being outdated. `brew install --cask --force` — which no Caskroom record can make skip — serves
two intents through one command, and only one of them makes that promise:

- **Moving an app to Homebrew** (adoption) adopts an app that already *is* the version the cask ships. Nothing is
  expected to move, an unchanged version says nothing about whether the bundle was replaced, and
  the check stands down so the takeover is reported as the success it is. That the app arrived
  where the cask says it did is established before validation, by artifact resolution, whose
  failure fails closed.
- **"Aktualizuj przez Brew"** runs against a cask offering something newer than the bundle, so
  an unchanged version afterwards is the same no-op an upgrade would have caught, and is read
  as one.

Keying the stand-down on the command instead let the loop through a second time, on the path
the first fix did not cover: Discord, `Caskroom/discord/0.0.413` recorded against an
`/Applications/Discord.app` still reporting `0.0.412`, announced as applied on 10, 15 and 22
September while every following scan listed it as outdated again.

When the check fires on an adoption, the "Nic nie zainstalowano" banner offers **„Przeinstaluj
przez Brew"**: `brew reinstall --cask -- <token>` run through the same protected transaction.
Unlike `install --force`, `reinstall` does not trust the stale Caskroom record — it removes the
cask and downloads it again, rebuilding the record and the bundle together. The banner names
that button rather than a command to type in a terminal. If that run lands nothing either, the
banner says so and offers the log instead of the same repair again.

The banner is the fallback, not the usual path. Before "Aktualizuj przez Brew" runs anything it
asks Homebrew what its Caskroom records for the cask (`brew info --installed --json=v2`); when
that record already equals the version the row offers, `install --force` is a guaranteed no-op
("Not upgrading …, the latest version is already installed"), so the update runs `reinstall`
straight away (`CaskAdoptionCommand`). The log names the command that actually ran. That is the
state an app's own updater leaves after it puts an older build back over a brew install — see
the Squirrel note under the launch smoke test below — and the state a REL-07 rollback leaves.

#### Docker Desktop

`DockerDesktopUpdatePolicy` keeps Docker out of batch targets, previews and background
eligibility. The supervised row prefers the vendor updater, preserves pending handoffs,
and offers Homebrew behind an explicit confirmation. An unresolved installation stays
visible without an executable action. Local completion of a cask-sourced handoff checks
the installed identity and offered version/build with two stable reads; it does not claim
the engine is ready or replace a real vendor check for other sources.

`DockerDesktopStopper` uses the CLI inside the resolved Docker bundle, a bounded stop and
local process probes. Bundle replacement, force retry, migration, automatic recovery and
Undo all require a confirmed stop; there is no force-kill or factory-reset fallback.
`DockerDesktopRestarter` runs only on an explicit restart, starts the installed Desktop
and polls its local user socket with a bounded deadline. The installation result and
engine readiness are reported separately. A failed readiness check leaves a retry action.

`RollbackProtection.Scope` and the rollback UI identify Docker protection as application
bundle only. Settings, VM disks, images, containers and volumes are outside that snapshot;
restoring the bundle cannot guarantee compatibility with migrated data.

Manual cask repair also compares build and prerelease information. An unchanged
`0.4.16+1` does not satisfy an offered `0.4.16,2`, and unchanged `1.2.3-beta` does not prove
installation of `1.2.3`. A zero Brew exit does not commit such an unchanged older bundle.
An intentional same-version takeover keeps its existing semantics.

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
up asking for authorization to reinstate privileged state. Older Docker Desktop versions
used this path for `vmnetd`; the historical incident below does not imply that every
current release uses that helper. The prompt is drawn by a helper process that dies with its parent, so
the teardown cancels an installation the user is still answering: Docker's password dialog was
killed 7.4 seconds after it appeared (the five-second window plus the two-second grace), and
because the privileged step never finished, every later launch re-prompted and crashed. So an
open prompt — detected through `SecurityAgent`, which exists only while an authorization sheet
is on screen — suspends the teardown and leaves the instance running for the user to answer.
Detection alone would race, since Docker's dialog took about four seconds to appear against a
five-second window, so casks known to repair privileged state on first run are never launched
by the smoke test at all. Docker aliases and tap-qualified tokens retain this exemption,
and the uncached `com.docker.docker` bundle identity blocks a renamed app before any launch.
Both are "no evidence", never a failure: not learning whether an app
runs must not be spent as a reason to undo an upgrade.

The teardown also has to keep the app's **own updater** from taking the quit as its cue.
Electron apps update through Squirrel.Mac: once one has downloaded an update, Squirrel submits
ShipIt as a launchd job that waits for the app to quit and then swaps the bundle. Discord's feed
lags its cask and answers any other version, newer ones included, with its current build — so a
freshly upgraded Discord downloaded the older build inside the five-second window, and the
smoke test's quit let ShipIt put it back two seconds later (`0.0.420` → `0.0.419`, twice on
2026-10-27), after the update had already been reported as applied. So before it asks the
instance to quit, the teardown removes every ShipIt job whose program lives inside the bundle
under test (`SquirrelShipItJob`, the same `launchctl remove` Homebrew's `discord` cask runs on
uninstall). ShipIt touches nothing while the app it updates is running, so this cancels an
install that has not begun; Squirrel downloads the update again whenever it next decides one is
due. The withdrawal runs even when the update is being cancelled. If listing or inspecting
jobs, reading their program paths, or removing an owned job fails, teardown is suspended:
the app remains running and the smoke result is `skipped(selfUpdatePending)`. Diagnostics
record the incomplete inspection or failed labels; this is not proof that no updater remains. Once the instance is gone — quit, killed or dead on its own — the teardown also
waits (up to 20 s) until no ShipIt job of the bundle is running, because ShipIt swaps the bundle
seconds after the app exits and nothing may read or restore it mid-swap. Should an install slip
through anyway, the guard reads the bundle's version once more after the test: a version that changed while the app was running is reported as **replaced by the
app's own updater** (`replacedByAppUpdater`) — not as an update and not as a rollback — and the
item is settled as aborted, so no "Cofnij aktualizację" entry points at a version that is gone.

On 24 November 2026 Discord Stable's updater restored 0.0.423 over Homebrew's 0.0.424
during validation, even after the ShipIt withdrawal was logged. A bundle identified as
`com.hnc.Discord` now skips unattended launch and records `skipped(selfUpdaterMayDowngrade)`.
The Gatekeeper, publisher, and on-disk version checks still run.

Liveness is read repeatedly while
the window is open **and once more on its closing edge**, and always through the handle the
launch returned rather than by process name, so neither a death in the last poll gap nor a
recycled pid can pass as a survivor. The test is on by default and can be switched off in
**Settings → Advanced → Post-update launch test**; it costs about five seconds per cask.

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
net also covers the most ordinary flow there is: open Wega, tick the list it restored from
disk, press **Update**. Banners **queue** rather than overwrite, so a *publisher changed*
alert is sticky: while the upgrade summary is open the warning is folded into it, and when the
summary closes it comes back as the sticky notice.

#### The check after a run and the summary

When the last install finishes, the window stays as it is: the post-run check runs in the band,
under *"Checking the result · 0:07"*, with the same phase chips and source ring as a scan, Wega
sniffing and the line *"I'll show the result after the check."* The list stays locked and the
rows of updated apps leave it as each source answers; nothing takes over the window. Only then
does Wega say how the run went. **Update** stays held back while the check runs, **Check now**
is disabled and there is no **Cancel** for it, because the check cannot be cancelled.

**A package counts as updated only when every phase succeeded.** An upgrade is one result per
item (`UpdateRunOutcome`) built from all four phases — the package manager's own verdict, the
Gatekeeper canary, the rollback, and the post-upgrade rescan. The result is then summed up
once, in an `UpdateRunReport` that places **every item the run planned in exactly one result**:
updated, failed, rolled back, not confirmed, or not started (stopped before its turn, or never
run). An item that produced no outcome is never dropped, and a run is never called successful
just because the items that did report all passed.

- After the check, the band and list show the remaining updates. A compact status reports
  how the run ended and flags a result that needs attention. If the run emptied the current
  category while other updates remain, the list switches to **All**.
- **Show summary** opens the detailed results. They group what needs your attention (*Needs attention*:
  failed, rolled back, not confirmed, a changed developer signature), one for what was not started
  (*Not started*), one for the updates left to finish with the developer (*To finish with the
  developer*), and one for what was updated (*Updated*). Each row says in one line what happened
  and, where it helps, offers the action — **Undo** on an updated cask whose pre-update copy is
  still kept (the note then reads *undone to …* afterwards), **Trust the New Signature** on a
  changed signature (also in *Not started*, for a publisher mismatch found before the upgrade),
  and a **Show log** link that opens the run's log (in *Not started* too). A cask row shows the
  app's name with its token beneath it.
- A cask whose publisher changed during the run does not count as confirmed until the check
  agrees: if the check still lists it, or could not answer for it, the summary says so rather
  than calling it updated. An update Wega never offered is never added to the summary.
- A **rollback that failed** — the new version rejected *and* the old one not restored —
  still raises its own **red sticky banner** telling you to check that app before using it,
  in addition to its row in the summary.
- Collapsing the details keeps the latest result available in the current session. You can
  choose and start the next update on the normal list. A new check or update replaces the
  report, and an unresolved publisher warning stays visible.
- What stays a banner: errors of the check itself (an incomplete or failed scan, a Homebrew
  error), a missing App Management permission, the Touch ID hint, a failed undo, and a failed
  rollback. The old result banners (*Updated N packages*, *Update incomplete*, *Update stopped*)
  are gone; the summary replaces them.

#### Error banners say what to do next

A foreground cask update blocked by the disk check shows the estimated additional space
needed. **Review Cleanup** opens Cleanup and **Back to Updates** restores the previous
update filter. A retry checks capacity again. If a mixed run already updated some apps,
only still-offered replacements held for insufficient space stay selected.

On Updates, during an update run and on Undo updates, every error banner carries a button. Most
are **Show in Logs**, which opens Logs on the entry that explains the failure; a failure of macOS permission leads with the permission, offers
**Open privacy settings** and never points at Logs, and a developer-signature change offers
**Trust the New Signature**, which asks for confirmation. A banner that names many apps or
packages shows the first few and a **Show All** button for the rest, and a banner that replaces
another starts collapsed. A failed pre-update backup says to check free disk space and try
again. The red banners on To Homebrew that report a failed duplicate removal also carry **Show in
Logs**; the other error banners on To Homebrew, and those on Inventory, Cleanup and Uninstall,
name the failure but carry no button. The word *snapshot* no longer appears in what Wega says: the user-facing name is
the backup, or the pre-update copy.

**"Why isn't my app here?"** Under the rows and under both empty states, a line — *"Can't see
an app? Missing from the list doesn't mean up to date — check its status in Inventory"* —
opens Inventory, since an app that is missing from Updates has not necessarily been checked.

#### Per-row control

**Use the ⋯ menu on a Homebrew, App Store or npm row** — or right-click any row, which is
the only way on rows the developer finishes — to choose **Don't update** ("don't update Zoom"),
**Skip this version** (hide just that version; the next one is shown) or **Pin version…** ("pin
Parallels to 18" — only updates up to that ceiling are shown). **Don't update** and **Skip this
version** hide the row at once with an **Undo** toast that offers the change back for 8 seconds;
**Pin version…** shows no toast. The line **"Hidden by your rules: N · Show"** under the list
opens the rules, where **Restore** removes one. Rules are also managed under **Settings →
Checking & Background → Paused updates** and persist across launches.

**A row names the app, with the token under it.** The name is the app's own; the Homebrew
token (`visual-studio-code`) sits in small monospaced type under it, joined to the source
(`token · source`), and only when it differs from the name. The undo toast, the inspector and
the confirmation dialogs use the name too, and the dialog tells same-named casks apart by token.
**Keyboard and VoiceOver.** Each group of rows is one Tab stop: **Tab** moves between groups,
**↑** and **↓** between the rows inside one, **Space** queues or unqueues the focused row and
**Return** opens its details; a click moves the group's Tab stop to the clicked row. The **⋯**
button is a 28 × 28 pt target and its own Tab stop, and Space on it opens the menu without
queueing the row. VoiceOver reads a row as one sentence — name, token, versions, source,
whether an automatic undo is possible, queued or not — with the hint *"Space adds to the queue,
Return shows details."*, and offers **Show details**, **Don't update** and **Skip this version**
as custom actions.

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
- **Co nowego** shows the real release notes for every version you are behind, not just the
  newest one, wherever the source publishes them — a Sparkle appcast or a GitHub release. When
  the feed publishes a link instead of the text, Wega fetches that page when you open the
  inspector, never during a scan. Sources that publish nothing show nothing. The advisory
  "možliwa poprawka bezpieczeństwa" badge reads the whole history, so a security fix two
  releases back is still flagged.
- **Akcje** reuses the row's own per-source update control.
- **Szczegóły** lists versions, install origin and path.

Homebrew casks also offer **Check release notes** in the inspector, even when
duplicate suppression skipped their manual checker. Fetching is deferred until requested;
only the offered Sparkle version/build or GitHub tag is shown, never a guessed newer release.

The probe runs in a `.task(id:)` that **cancels and restarts** as you change selection, so it
never blocks the list or shows a stale verdict.

### Accessibility
Update and uninstall selections are native keyboard-focusable controls with VoiceOver labels and explicit selected/not-selected values. In the package-manager update list, **Return** opens the focused row in the inspector and **Space** toggles its batch selection; on manual-update rows either key opens details because those rows have no batch-selection checkbox. Select-all controls are buttons rather than pointer-only gestures. The uninstall confirmation is a correctly sized native sheet with destructive/cancel roles, **Enter** and **Esc** shortcuts, and the exact frozen targets shown before execution; long target and ambiguity lists scroll while the action buttons remain pinned, including at large text sizes. Its **App only** / **App + leftovers** choice also announces the selected state to VoiceOver. Selection rows use semantic fonts so large environment text can reflow. The **Updates scan status on the sidebar icon** no longer relies on colour alone: a failed scan swaps the icon's **symbol** (a warning glyph, not just a red tint), and every scan state — checking, checked-clean, failed — is announced to VoiceOver as the row's value, so the outcome reaches users who cannot distinguish the colours. With **Reduce Motion** enabled, the rotating sidebar artwork, cycling thought bubble, Wega motion and binary stream all render without continuous movement; rebuilding its parent does not replace the static binary frame. That coverage is now complete and centralized: Wega's bouncing ball, her blink and her idle *tricks* on empty states, and the sweeping bar under a running check, all stop as well, and each notices the setting being switched on **while it is already running** rather than only at first appearance — one `ContinuousMotion` policy decides for every never-ending animation in the app, and a regression test refuses a `repeatForever` that does not go through it. Where a moving element carried information, the information stays: the check-in-progress bar drops its sweep instead of freezing at full width, which would read as *finished*. **Text sizes** across the whole window come from a semantic scale (`Font.wega(…)`, one alias in `WegaTheme`) rather than ~225 hard-coded point sizes, so the interface follows the system text-size setting; the only two fixed sizes left are drawings sized by their own container, and they say so on the spot. The **palette is appearance-adaptive**: the eight brand colours were tuned against a dark window and read at roughly 1.8:1 on a light desktop, and now resolve per appearance — with a separate pair for **Increase contrast** — clearing 4.5:1 both on the window background and on the 12 %-tinted badge fill they also sit on (7:1 for the increased-contrast pair), graded arithmetically in tests rather than by eye. Filled controls whose label is Wega's dark ink keep a separate, lighter fill value, and the mascot's own coat colours stay fixed — a drawing is not text. The **Settings** window (⌘,) is resizable instead of pinned to 640×600, so it can grow at large text sizes instead of clipping. An **Updates** menu carries the app's keyboard shortcuts, macOS-conventional: **⌘R** *Check now* (start a scan), **⌘⏎** *Update* (opens the same update confirmation the toolbar button does, on the Updates destination), **⌘.** *Cancel Scan* — or *Stop After Active Installs* while a run is going —, **⇧⌘A** *Select All Visible* (the visible rows on Updates), **⌥⌘I** *Show Inspector* (the details panel), **⌘F** *Find on This Screen*, **⇧⌘F** *Find in inventory* and **⌘1…⌘7** to jump to the seven sidebar sections in order (Updates, To Homebrew, Inventory, Rollback, Uninstall, Cleanup, Logs). **⌘F** focuses the search field of Updates, Logs, Uninstall, Inventory and Cleanup and is disabled on the screens that have none; **⇧⌘F** goes to Inventory from anywhere and focuses its field. Each shortcut is greyed out exactly when its on-screen control is unavailable. The **Help** menu's **Wega User Guide** opens the user guide in the browser. The app menu, under **About Wega Mac Updater**, adds **Check for Wega updates…** — the macOS-conventional place for an app's own update check — which opens the Settings window, where the self-update screen owns the operation. The small state texts — an update's stage, trust states, a pending scan phase and the download-size probe — use the secondary text colour rather than the faint tertiary one, so they stay readable.

### Uninstall
Scans every app on the system regardless of origin. Brew casks are removed with `brew uninstall --cask`; App Store and manually installed apps that you can move yourself go to the Trash. One owned by root — most App Store apps and apps installed by a `.pkg` installer — goes to the Trash through the Wega helper, without a password prompt, when the helper is on and you are an administrator (and Wega itself was installed from the `.pkg`; a copy that does not belong to root says so instead). This applies to an app directly in `/Applications` or in one folder beneath it. The helper moves the app out of `/Applications` into a staging folder that belongs to you (under `/Library/Application Support/com.wega.WegaMacUpdater/UninstallStaging/`), and Wega then moves it to your own Trash as you; the helper never writes into your home folder. Without the helper, Wega reports that the app needs the Wega helper and offers **Otwórz ustawienia pomocnika** (Open helper settings, which opens the Settings window with the helper's card) and **Show in Finder**. Before the confirmation sheet opens for such an app, Wega checks the helper's version once (up to 10 seconds). When the helper is on but older than this Wega build (it needs helper protocol 6), or does not answer that check, the sheet already says the helper is outdated or not responding and must be removed and installed again in Settings; that app is not asked to quit and is left in place, with the same two buttons. A helper that stops responding after the sheet was confirmed is reported the same way as long as nothing had been sent to it. On a standard account it reports that the app needs an administrator account. A root-owned app elsewhere, or one owned by another account, needs administrator rights and offers **Show in Finder**, so you can drag it to the Trash and confirm with your password. The confirmation dialog offers **"App only"** (the default, and the recommended one) or **"App + leftovers"** (`--zap`, which also deletes preferences, caches and Application Support) — the irreversible option is a deliberate choice, never the preselected one. It shows exact counts: how many casks are affected, how many go to Trash, and how many cannot be removed (a blocked app is never counted as going to Trash, and when every app is blocked the confirm button no longer says it moves them to Trash). If the selected `--zap` operation fails, Wega reports that item as incomplete and leaves it selected; it never silently retries without zap using `--force` or counts that changed operation as success. **"App + leftovers" is no longer brew-only** (UX-13): for apps Homebrew does not manage, the dialog lists an **App leftovers** section per app, built from three sources, all inside your home folder and nothing system-wide. (1) The matching cask's `zap` list from the cask catalog: only `trash`/`delete` entries starting with `~/` are used, with wildcards allowed only in the last path component and only with at least three literal characters. An item is ticked by default only when the match is strong (the cask's zap list names the app's bundle id, or Wega's own app-to-cask tables map the app), the item is inside `~/Library`, and its own name points to the app: without a `.plist`, `.savedState`, `.binarycookies` or `.sfl` suffix it equals the app's display name, `.app` file name or cask token, or it contains the app's bundle id bounded by dots or the ends of the name (`md.obsidian.plist`, `com.tinyspeck.slackmacgap.ShipIt`); a wildcard match is judged by its own name on disk. Vendor-wide or shared folders a strong cask lists — `Application Support/Microsoft` for Word, Google's updater (`~/Library/Google/GoogleSoftwareUpdate`, `Caches/com.google.Keystone`) for Chrome — are labelled "Homebrew list (shared folder?)" and stay unticked. A cask matched only by name gives items labelled "Homebrew list (matched by name)" that stay unticked, and any zap item outside `~/Library` (for example `~/.config/zed`) is always unticked and labelled "outside ~/Library". (2) Fixed bundle-id locations, ticked: Application Support, Preferences (including the app's own `ByHost` plists, `<id>.<host id>.plist`), Caches, Saved Application State, Containers, HTTPStorages, WebKit, Logs, Application Scripts, Cookies, the Group Containers entries (`<TEAMID>.<id>`, with the team ID read from the app's code signature, and `group.<id>`) and the app's recent-documents list. (3) Folders named after the app in Application Support, Caches and Logs (display name and `.app` file name, case-insensitive), shown as probable and unticked; generic or vendor names (Google, Microsoft, Adobe, Data, Cache, Logs, Helper and similar) and names shorter than three characters are never used. Each app's list has a main part and a **Probable — check before ticking** part that holds the probable and shared items; every row shows its name, size, source label (Homebrew list, bundle id, app name, and so on) and path, and the header reads "<count> · <size> ticked". **Zaznacz wszystko** (Select all) ticks the main list only, so probable items are ticked one by one; **Odznacz wszystko** (Deselect all) clears the whole list, probable items included. Which of the two the button shows depends on the main list. An item another installed app still uses stays visible but unticked and is labelled "also used by <App>": the same bundle id (another copy), a longer bundle id (Chrome Canary next to Chrome), that app's group or team containers, a folder found only by name (in Application Support, Caches or Logs) that is named after that app as well, or a path its own Homebrew zap list names, including a folder that contains such a path; for this check an app's cask counts even when Wega's release-channel rules keep that cask from the app's own leftovers. When two apps removed in the same run share an item, it goes to the Trash only if both were actually removed. Never offered: anything outside the home folder; Desktop, Documents, Downloads, Pictures, Movies, Music, Public, iCloud Drive, CloudStorage, Mail, Messages, Safari and Keychains; the CloudDocs, FileProvider and MobileSync folders in Application Support; anything inside another app's container (only a container folder itself, `Containers/<id>` or `Group Containers/<name>`, can be offered); LaunchAgents and component folders such as Internet Plug-Ins, Audio, Services, QuickLook, PreferencePanes, Fonts, Input Methods, Screen Savers, Spotlight, ColorPickers, Contextual Menu Items and Extensions (left to a later stage); anything with `com.apple.` in its name except the app's own recent-documents list; and anything reached through a symlinked folder inside the home folder (a symlinked item itself is moved as the link only). Sizes are measured after the sheet opens, one item at a time, and the header shows "…" until they are done; items in Containers and Group Containers are not measured and show "size unknown". Wega does not look inside other apps' containers to plan or size leftovers; it only checks that the container folder itself exists. The sheet uses the on-disk cask cache whatever its age and downloads it only when it is missing or corrupt (no retries; 15 s request and 30 s resource timeouts), so a stale cache is accepted here while other windows keep their 24-hour refresh. When the catalog is unavailable, the sheet opens without Homebrew-list items and says "The Homebrew list is unavailable — showing only leftovers found by bundle id and name." When the Uninstall list's application scan failed, nothing is ticked by default and the section says "The app list is incomplete — nothing is ticked by default."; a Homebrew-only failure does not trigger this. Ticked items move to the **Trash** (recoverable, never a permanent delete) and only for apps that were actually removed; leftover moves that fail are counted in the result, not swallowed, while an item that is already gone at its turn (a ticked folder above it went first) counts as moved. **A scan that can't read a source is never shown as an empty machine**: when it finds nothing it says *"the scan failed"* rather than *"no apps found"*, and when it still found some apps the confirmation dialog warns that the target list may be incomplete before anything is removed — a destructive choice is never made on silently partial data. **Right-click any row** to reveal it in Finder, copy its path, or toggle whether it is marked for removal — the same per-row context menu the update list already offers.

Before anything is removed, Wega asks each running target it will remove to quit and waits for it to stop. An app the confirmation already shows as impossible to remove is never asked to quit, never force-quit and offers no leftovers; when every selected app is in that state, the confirm button only reports why and is not styled as destructive. An app that refuses is named in a separate warning that forcing it to quit can lose unsaved work; only after your explicit consent does Wega send `SIGKILL`, and only to the process that app resolves to at that moment. You can also skip those apps, and cancelling leaves everything untouched. An app whose process cannot be told apart from another copy of the same app (an ambiguous bundle identifier) is never asked to quit or killed; it is skipped. Right before an app is removed, Wega checks its process once more: an app that was started again while you answered the warning, or while the removal waited for a running update, is skipped and its leftovers stay. Some rows cannot be selected at all: Wega itself, macOS system apps, and a symlink, which is shown with the destination it points to. The leftovers you ticked are moved to the Trash only for apps that were actually removed; the data of an app that stays installed is never touched.

The confirmation sheet shows what will happen to each app that does not go through Homebrew: it goes to the Trash, the Wega helper will remove it without a password, or it cannot be removed and why. After the run, the success banner names each removed app and how it went (through Homebrew, to the Trash, or to the Trash through the Wega helper). If the helper moved an app but the Trash then refused it, the app stays in its staging folder, out of `/Applications` and not deleted; its row shows that path with **Show in Finder**, and its leftovers stay. If the helper accepted the version check but then does not answer the removal request within 10 minutes, or the connection to it is lost after the request was sent, the app's row says that the helper did not confirm the removal and that the app may already have left `/Applications`; the list refreshed after the run shows whether it is still there. Its leftovers stay as well. Every app that was not removed gets its own row under a one-line summary: its name, the folder it lives in when another copy shares its name, its reason and the button that helps; a long list scrolls instead of being cut off, and refreshing the list clears the result. An app macOS refuses to let Wega modify (App Management) opens the System Settings pane that grants it; an app owned by another user, a root-owned app the helper does not handle (outside the top of `/Applications`), or one whose bundle or folder you cannot write to, needs administrator rights and offers **Show in Finder**; an app that needs the Wega helper, or needs it reinstalled, also offers the button that opens the Settings window. The generic "uninstall incomplete" line is kept for removals that failed with an error of their own and names those apps; each one's row shows the error's key line (Homebrew's `Error:` line for a cask), and when the error is longer, its complete text under **Szczegóły**.

### Cleanup

The scan groups physical application bundles with the same bundle identifier and displays
each path and version. **Review copies** opens an Uninstall list scoped to the group with
no selection. Wega rechecks that the chosen bundle and a surviving copy are still present.
Shared application data is preserved. For a managed copy, the Homebrew route requires
a verified link from the cask's record to the selected installation and a receipt that
declares only the app bundle for removal.
The **Porządki** sidebar section (⌘6) finds duplicate copies of command-line tools and what installers and shell tools leave behind. The scan is **read-only** and runs in these steps: the directories on `PATH` (D1), tool-owned version directories (D3), the Homebrew status of each duplicate, Homebrew leftovers (D4), one walk over your project folders, unused runtime versions (D5), Gradle distributions and JDKs (D6), old JetBrains IDE folders (D7) per-shell state (D8), `PATH` hygiene (D9) and, only when you switch it on, the Files and Folders map (D10). A detector that fails is reported as such while the others still report.

- **Duplicates on `PATH` (D1).** Every command that resolves in more than one `PATH` directory is grouped; the first hit is *active*, later ones are *shadowed*. Each copy is classified by where it really lives: a Homebrew formula or cask, an app bundle, a version manager (uv, fnm, nvm, pyenv, SDKMAN, rustup, mise, asdf, Volta, pnpm), a package manager (npm, pnpm, bun, pipx, cargo, go), a native installer's version directory, a system location, or standalone. System copies are shown as *expected* and never offered for removal. So is a version manager's shim, found by the `PATH` directory it sits in (`~/.local/share/mise/shims`, `~/.asdf/shims`, `~/.pyenv/shims`) rather than by what it resolves to: it runs the version the manager selects. A shim that comes first on `PATH` is what Terminal runs, so the copies behind it are *shadowed* but offer nothing, since the manager may fall back to any of them as its `system` version. In a tool with two or more candidate copies (active or shadowed; system copies, shims and broken links are not candidates) a **zostaw** radio on each copy picks the one that stays, by default the active copy; the badge keeps saying what `PATH` does. Every other candidate offers the removal that fits its source, the active copy included, and moving the radio moves the buttons at once, without a scan. The choice is remembered per tool (the kept copy's `PATH` path and its source, stored locally and never exported) and dropped when a later scan no longer finds that copy from that source. A copy that came with an app offers **"Odinstaluj <App>…"**, which opens **Odinstaluj aplikacje** with that app selected (a protected or unlisted app opens it with nothing selected); nothing is removed until you confirm there. When the same app also provides a copy that stays, in this tool or another, the row keeps the instruction to remove the link with administrator rights instead. Removing the copy Terminal uses now adds, in the confirmation sheet, which copy Terminal will use afterwards. A broken link gets a copyable `unlink <path>` (`sudo unlink <path>` outside your home folder) only when Wega, resolving it again, finds its target missing or a link loop; a link it could not follow, such as one into a protected location, gets nothing to paste.
- **App-managed copies (D2).** A copy owned by an application is labelled as such and never offered for removal. The known table currently holds the Claude desktop app's `claude-code` and `claude-code-vm` directories under Application Support.
- **Version directories (D3).** Old versions kept by a recognised native installer layout (currently Claude's `~/.local/share/claude/versions`) are offered for the Trash only when they compare as older than the current one (SemVer order); a newer version, or one that cannot be shown to be older, is reported as needing a decision and left to the tool, and entries that are not version-like (a lock, temporary or dot file) are ignored. A directory with several version-like siblings that matches no known layout is only reported, never offered, and a version used by a running process needs a second confirmation.
- **Shell state (D8).** `fnm_multishells` entries (under `~/.local/state` and the temporary directory) are *stale* only when the millisecond timestamp in their name is earlier than the last boot; a process ID alone proves nothing. Stale entries are moved to the Trash together; entries created since boot are only counted.
- **`PATH` hygiene (D9).** Runs only on a `PATH` read from your shell; an approximate `PATH` is not checked and the **PATH** section says to press **"Odczytaj PATH"** first. Each distinct entry is looked at through the guarded file system and reported, information only and never offered for removal, when its directory no longer exists (*dead entry*), when it is listed more than once, when it resolves to the same place as an earlier entry, or when it lies inside another entry; plus **older copy wins**, when the active copy of a tool is older (SemVer) than a shadowed copy found by the duplicates step. The entries macOS adds itself through `/etc/paths.d/10-cryptex`, under `/var/run/com.apple.security.cryptexd` (or its `/private` spelling), often do not exist and come back with every system update, so they are left out and never looked at. Every finding says which shell files and lines add the entry as `file:line`, never the line's text: for zsh the system and personal `zshenv`, `zprofile`, `zshrc` and `zlogin`, for bash `profile`, `bashrc`, `.bash_profile`, `.bash_login`, `.profile` and `.bashrc`, plus the system `paths` file and every file in the system `paths.d` folder, and only those listed files are read, comment lines skipped. An entry found in none of them (added by `eval`, a sourced file, a plugin manager or `ZDOTDIR`) says so. The advice follows the reason: a dead entry, or one that is the same place as an earlier entry, is removed where it is added; for a repeated entry you keep only one of the lines that add it; for an entry inside another you check whether you need both; when an older copy wins you put the newer copy's folder earlier in `PATH` or remove the older copy. Neither of the last two tells you to remove the entry, which would take a whole folder of tools off `PATH`. Wega never edits a shell file; the row tells you what to edit.
- **Files and Folders map (D10).** Off by default; **Settings → Cleanup → Files and Folders map** switches it on. A command-line tool has no app bundle, so macOS records its Files and Folders consents per path; with the switch on, a scan opens the user's `TCC.db` read-only (never changed, schema checked first, an unknown layout is reported instead of guessed) and shows one row per client for the Desktop, Documents, Downloads, network and removable volumes and all-files services, each grant allowed or denied. A path entry is tied to the copy the duplicates or version-directory steps found (active copy, copy that can go, copy that stays, or an app-managed copy; for a copy with a keep choice the label follows the choice: the copy you keep, or a copy that can go); an entry whose file no longer exists is a dead entry, and an entry for a copy that can go is shown with the instruction to switch it off in System Settings → Privacy & Security → Files and Folders. An app's entry gets a `tccutil reset <service> <bundle id>` command per service to copy. **It needs Full Disk Access, and macOS gives that access to every program Wega starts: Homebrew (cask scripts included), npm (package scripts included), mas and the shell that "Odczytaj PATH" runs.** Grant it only while you read the map, then remove Wega from Full Disk Access. The section has these states: off, on but not scanned yet, database unreadable (usually no Full Disk Access), unsupported database layout, empty, and the map itself; after every scan that opened the database (the map, an empty one or an unsupported layout) it repeats the reminder to remove Wega from Full Disk Access. Switching the map off forgets a stored map at once: the report on screen, its saved copy and every export lose it, also while a scan or removal is running (neither is interrupted; a running scan no longer opens `TCC.db` and the report it stores carries no map). Full Disk Access entries themselves live in the system database and are not mapped.
- **Homebrew.** Duplicates are checked against `brew` with `HOMEBREW_NO_AUTO_UPDATE` and `HOMEBREW_NO_ANALYTICS` set. A formula that other installed packages depend on is shown as a dependency with its dependents and is not offered for removal; if the dependents cannot be determined, no removal is offered. Every Homebrew copy that offers the keep choice is checked, the active one included. A copy from the same formula or cask as the kept copy (for example a versioned `Cellar/<formula>/<version>/bin` on `PATH` beside the prefix's `bin`) is not offered either, because `brew uninstall` would remove the kept copy with it. Casks and formulae are removed with `brew uninstall --cask -- <token>` / `brew uninstall --formula -- <name>` (never `--zap` or `--force`), spelled in the confirmation sheet and the export exactly as Wega runs it, the dependents are checked again just before removal.
- **Homebrew leftovers (D4).** Wega asks Homebrew what `brew cleanup --dry-run` and `brew autoremove --dry-run` would remove and groups the answer per package: the old versions and cached downloads of each formula or cask. Each package is offered on its own as `brew cleanup -- <name>`, never as a global `brew cleanup`, with the sizes Homebrew printed, and always needs a decision. A package whose newest version folder under `Cellar/<name>` or `Caskroom/<name>` changed in the last 7 days keeps its previous versions and is not offered, so a fresh upgrade can still be rolled back; an old version a running process uses needs a second confirmation. What only a global `brew cleanup` removes — old logs under `~/Library/Logs/Homebrew`, kegs `brew reinstall` set aside, API caches — is shown as one information-only row, and so is a package that keeps two or more versions on purpose (a pinned formula, a cask that updates itself). Formulae that nothing depends on any more (`brew autoremove` candidates) are listed individually and offered as `brew uninstall --formula -- <name>`, never as a blanket autoremove; they need a decision too. When Homebrew does not answer, the section says so instead of looking empty.
- **Unused runtime versions (D5).** Versions installed by uv, pyenv, fnm, nvm, SDKMAN, rustup, mise, asdf, Volta and pnpm env are compared with what your project folders ask for (`.python-version`, `.nvmrc`, `.node-version`, `.tool-versions`, `mise.toml`, `pyproject.toml`, `package.json`, `.sdkmanrc`, `rust-toolchain`, a `.venv`'s `pyvenv.cfg`) and with each manager's own default. A version something requires is kept and shows what requires it. An alias (`lts/*`, `latest`, a custom nvm alias) or a default Wega cannot read keeps the newest version of each manager, and a pyenv-virtualenv name keeps the interpreter its environment lives in. A version nothing requires needs a decision; a running process using it marks it *in use* but does not keep it. Wega never removes runtime versions itself and offers no Trash button for them: the row shows the manager's own uninstall command with a **Kopiuj polecenie** ("Copy command") button or, for Volta and for names that are not safe in a command, an instruction to remove the version with the tool that installed it. Pythons installed by Homebrew are not listed here; their old versions appear under Homebrew leftovers.
- **Gradle (D6).** Wrapper distributions under `~/.gradle/wrapper/dists` are checked against the `gradle-wrapper.properties` files in your project folders; of `distributionUrl` Wega keeps only the distribution's version and type, and it never reads `gradle.properties`. A distribution no wrapper names is offered for the Trash (the wrapper downloads it again when needed) and counts as safe only after a complete walk of the project folders; when no folder was searched, the walk was cut short or a folder was refused, it needs a decision. JDKs Gradle downloaded to `~/.gradle/jdks` are checked against the daemon JVM criteria (`toolchainVersion`) and toolchain calls (`jvmToolchain(…)`, `JavaLanguageVersion.of(…)`) in your projects; one nothing asks for is offered for the Trash but always needs a decision. JDKs in `/Library/Java/JavaVirtualMachines`, and a downloaded JDK whose Java version cannot be read, are shown for context only. A distribution or JDK a running process uses, or names in its arguments as a Gradle daemon does, needs a second confirmation.
- **JetBrains (D7).** Folders JetBrains IDEs left under `~/Library/Application Support/JetBrains`, `~/Library/Caches/JetBrains` and `~/Library/Logs/JetBrains` are compared with the IDEs installed in `/Applications`, `~/Applications` and the Toolbox's install folder, read from each IDE's `product-info.json` and never run. A folder of a version that an installed IDE of the same product replaced is safe to move to the Trash (**Do Kosza…**); its row recommends the IDE's own **Help → Delete Leftover IDE Directories**, which knows its folders best, and says that Wega can also move the folder to the Trash. A folder of a product with no IDE found, or newer than every installed one, may belong to an IDE outside those folders, so it needs a decision; a product whose IDE has an unreadable `product-info.json` is left alone, and an installed IDE's own folders are never reported.
- **Project folders.** The runtime and Gradle checks read your projects, so **Settings → Cleanup → Project folders** chooses where to look. The default is `~/Dev`; a protected location, or a folder that contains one (such as your whole home folder), is refused. Wega walks those folders through the same guard, without following links, and reads only the version files named above. When no project folder could be searched, or there were more folders than one scan reads, both sections say so: the runtime check still reports against the managers' own defaults and offers its commands, Gradle distributions drop to *needs a decision* but keep their Trash button, and JDKs are offered as before.
- **Stopped scan.** Stopping a scan keeps the previous report and says so.
- **`PATH` is read on demand.** A Finder-launched app only inherits the minimal system `PATH`, so Wega shows an approximate one until you press **"Odczytaj PATH"**. Its order (`/etc/paths` first) can make a different copy active than your shell does, so while `PATH` is approximate Wega does not pick the copy to keep: a tool without a remembered choice shows every candidate copy undecided, with no removal and outside both totals, and the export marks it so. Once you pick a copy (or a remembered choice applies) the other copies offer their removal, but none counts as safe. That is the only time your login shell (zsh or bash) is run, once, after a warning that its startup files execute; only the list of directories is kept, never the shell's output. The read waits at most 2 seconds for the shell's output to end after it exits, so a background job left by a startup file cannot hold it, and **Anuluj** stops it, keeping the stored `PATH`. The scan itself never starts your shell and never runs a found binary (no `--version`).
- **Protected locations are never touched.** Desktop, Documents, Downloads, iCloud Drive (`Mobile Documents`), Containers, Group Containers, Mail, Messages, Safari, CloudStorage, `/Volumes` and any path on another volume are skipped and listed as skipped, so a scan never triggers a privacy prompt for them. Every read and every move goes through one guard that checks the real location of each path.
- **Layout and search.** Each section lists the tools that need action first and folds the rest into a collapsed **Bez akcji** group, where tools that share a source and directory become one line; the section header says how many tools are left to do. The search field (⌘F) matches tool names, row titles and details across the whole report and shows every match expanded.
- **Removal needs confirmation; what Wega removes itself goes to the Trash.** Findings are sorted into *safe* and *needs a decision*; nothing is selected for you. The totals at the top count a removal that several findings share (one Homebrew formula behind two copies) once, under *needs a decision* when any of them needs one. A confirmation sheet shows the exact items, sizes and, for an item a running process uses, the process (arguments are shown there and never saved); long details and process lists scroll inside the sheet, each process line cut to three lines with the whole line in its help tag, while the in-use acknowledgement and the buttons stay pinned. Files Wega removes itself are moved to the Trash, never deleted permanently; `brew uninstall` and `brew cleanup` are Homebrew's own commands and delete what they remove, so the sheet names the exact command. Immediately before acting, under the shared write lock, Wega re-checks that the item is unchanged since the scan, is not what its tool now points to, for a copy of a duplicated tool, that the copy you keep still works (it still exists, is executable, is not the item itself and, for `brew uninstall`, does not come from the same package; a copy that names no kept copy, or a different one than the scan recorded, is refused), and is not in use unless you acknowledged it. Before `brew cleanup -- <name>` it runs a fresh dry run for that package alone and dates the same-named `Cellar` and `Caskroom` folders again, and refuses when nothing is left or a version there changed in the last 7 days; before a Gradle distribution, JDK or JetBrains folder goes to the Trash it reads the project folders and the installed IDEs again. Whatever no longer holds asks for a rescan. A per-package `brew cleanup` also lets Homebrew delete downloads in its cache that no package refers to any more; its dry run does not list those. Commands and instructions are shown to copy and run yourself. An npm global is removed with `npm uninstall -g --prefix <prefix> <package>`, where the prefix is the node installation the shadowed copy really lives in (Homebrew's node, fnm, nvm, …), not the one whose `npm` comes first on `PATH` and provides the active copy; a prefix with characters outside `[A-Za-z0-9._+@/-]` gets an instruction instead. The export writes the prefix inside your home folder with `~` as well, so the home folder never stays in an exported command.
- **Each confirmation says what the action does.** Under its question, the sheet reads *"Moves
  to the Trash — you can restore it until you empty the Trash."* for a trash action, *"Runs a
  Homebrew command — Wega can't undo it."* for a `brew` action and *"Only copies the command;
  nothing is removed now."* for a command you run yourself; an action that removes nothing
  (an instruction, or the hand-off to Uninstall apps) shows no such line. The confirm button is
  red.
- **Report export.** *Eksportuj* writes the scan as plain text or JSON with `~` in place of your home folder; process arguments, shell output and environment are never included. The last report and `PATH` snapshot are also kept in `~/Library/Application Support/WegaMacUpdater/`.

### Migration
Finds manually-installed apps that have a Homebrew Cask equivalent and offers to migrate them with `brew install --cask`. The row's **Move** button (the screen is **To Homebrew**) opens a sheet titled *"Move <app> to Homebrew?"* that names the backup Wega makes first and says the backup is restored if the new version fails the signature check; its **Move** button starts the migration. Runs `mas search` in parallel for apps without a cask match to find App Store equivalents. Running detection covers every matched app: the exact standardized/resolved bundle path wins, with a unique bundle ID as fallback; ambiguous duplicate bundle IDs stop the migration. Wega sends that exact process a normal application **Quit** request and waits for it to stop. Only an app that remains open produces a separate warning about unsaved data; after explicit consent Wega identifies the target again, sends `SIGKILL` only to that PID, and confirms the app stopped. A failed or ambiguous force-quit cancels the migration instead of being ignored. A match too weak to trust (the **"niepewne"** / low confidence level) is refused before anything runs: since `brew install --cask --force` overwrites the app in place, a low-confidence `.app`→cask match could replace it with a *different* program, so Wega blocks the automatic takeover and asks you to verify the token manually (`MigrationAutoTakeover` consuming `CaskMatchConfidence.allowsAutoConfirm` — the confidence score now gates execution, not just the badge). The confidence comes from **how** the match was found (`CaskMatchProvenance`, decided by `CaskMatcher` and carried on the scanned app): an already-installed cask, a curated entry in `customCaskMappings` or an exact token hit is certain; a match on one of a cask's display names is plausible and asks for confirmation; an app tied to no cask at all is the case that stays blocked. A publisher mismatch still overrules all of it. Previously the scorer re-derived this from strings its callers could not supply, so the curated table — whose whole purpose is apps whose name does not normalize to their token — scored lowest and had every one of its entries refused. Before Homebrew replaces an existing `.app`, migration takes the shared upgrade mutex, passes the same hard disk/network/power gate as an upgrade, verifies and preserves the installed publisher baseline, and requires a copy-on-write snapshot. The installed result must pass the shared Gatekeeper/Team-ID canary; otherwise Wega restores the snapshot and reports failure. The manual cask-adoption action in Updates uses this same protected transaction, so neither `brew install --cask --force` entry point can bypass it. A cask that installs **no `.app` at all** — a `pkg` cask such as `zoom` or `google-drive` — is refused up front with "Nie można przejąć", before brew runs: there is no bundle to snapshot, nothing for the Gatekeeper/Team-ID canary to validate, and nothing to restore. Adoption previously ran the force-install on these anyway and then reported the missing app artifact as `.rollbackFailed` ("the new version failed the check and could not be restored"), which described neither a check nor a rollback — both had been skipped. This is the same `RollbackProtection` question the batch upgrade path already asks, now asked by the adoption path too. A successful brew migration ends there: Wega **touches nothing in `~/Library`**. The old "clean leftovers" sheet was removed (SEC-01) — for a migration the app keeps its bundle id, so those "leftovers" are the live Application Support, preferences and container of the app you just adopted, and the sheet offered to delete them permanently with everything preselected. **npm ↔ brew duplicate row** — for CLIs installed via both `npm -g` and Homebrew (e.g. `@openai/codex` + `codex` cask), inline "Usuń z npm" / "Usuń z brew" buttons run the corresponding uninstall (`npm uninstall -g -- <pkg>` via `NpmGlobalService.uninstallEvents`, or `brew uninstall -- <token>`; the `--` terminator is SEC-10) after a confirmation alert; the duplicate disappears from the list on exit 0.

Docker migration uses the controlled Desktop shutdown gate instead of generic force
termination, including when a stale confirmation requests force termination.

### Inventory
The **Check status** column and **Needs checking** filter expose the latest per-installation
update-check evidence: current, update available, incomplete, no recognized source,
policy-hidden, unconfirmed or stale. Details include sources, attempt time and the last
complete check. This is separate from install origin and the file's modification time.
Missing per-path evidence (including App Store) stays unconfirmed. See the
[status rules and limitations](../USER_GUIDE.md#checking-status-in-inventory).

**The read is kept.** Inventory is one store shared with the window, so its last read survives
moving between screens: the line *"Read today, 08:12"* (the day moves at midnight, after sleep
and after a clock change) turns to *"Read today, 08:12 — the list may have changed"* when an
update run, a background round that installed something, an install from the list through
Homebrew, a reinstall, an undo, a Cleanup removal, a move to Homebrew or an uninstall finishes, also while the window is closed (the stores that run them count each
one, and the inventory compares the counts with those of its last read). **Refresh Inventory**
only reads the disk again and says so in its tooltip (*"Does not check for new versions"*);
**Check for updates** starts the same scan as **⌘R** and navigates to Updates. When the filters
hide every app the list says *"No apps match these filters."* and offers **Clear Filters**; when
the read found nothing, it points at the scan directories.

Full list of every `.app` on the system with source badge (Brew / App Store / Manual), version, bundle ID, and last-modified date. Filterable by source, sortable by any column, searchable by name or bundle ID. Four stat cards at the top show counts per category — tap a source card to filter; the npm card is a counter of global packages and does nothing when clicked. Any app Wega has **no known way to update** — not managed by Homebrew or the Mac App Store, and absent from the `AppCatalog` (so a hand-installed app the catalog already tracks does *not* qualify) — carries a **report button** in its source cell: one tap opens a prefilled GitHub issue (built by `CatalogIssueBuilder`) asking the maintainers to add update support, closing the community-catalog loop from the UI. **A failed scan is never passed off as a complete one**: each source (Homebrew, the cask catalog, the filesystem, App Store, npm) is tried independently, and any that fail are collected per source and raised as a banner over the table naming them — so a partial list reads as partial instead of as an authoritative empty or short list. **Export** — the toolbar's *Eksportuj* menu writes the whole inventory (not the filtered view) to a chosen location as a **Brewfile** (a `brew bundle` manifest: Homebrew casks and Mac App Store apps become installable `cask` / `mas` entries, while manual apps and global npm packages are preserved as comments so the file stays a faithful record even though `brew` cannot reinstall them) or as a **CSV** (one row per app, followed by the npm globals). The bytes are built by `InventoryExport` in the core module — deterministic and locale-independent, so re-exporting an unchanged inventory yields an identical file — and unit-tested without a save panel.

### Settings
App settings live in the **native macOS Settings window**, opened with **⌘,** or **Wega › Settings…** in the menu bar — not a sidebar tab or a toolbar button (macOS users expect app settings there). It has **five tabs**, and a card that something elsewhere points at opens on its tab and scrolls to it (`SettingsRoute`); the self-update, Wega helper and Touch ID cards show the result of their buttons under them, because Settings has no Wega.

- **General.** The app card (version, build, **Check for Wega updates**, **Report a bug**, links and the self-update state), the **Language card** — switch the interface between **Polski** and **English**; the choice is persisted and applies live, and switching it keeps the current scan results (and a running upgrade) intact. Until you pick one, the language follows the system locale — Polish only when macOS reports it ahead of the other languages Wega ships, **English otherwise**. **Launch at login** and **Notifications**.
- **Checking & Background.** **Paused updates** — lists every ignore / version-pin rule with a one-click remove. **Background update permissions** — the audit of per-app unattended-update consents. **Scan directories card (UX-16)** — add your own scan roots via a directory picker (stored as **security-scoped bookmarks**, so apps on other volumes and in non-standard locations are found), list **exclusions** that are never searched, and set the **recursion depth** (how many sub-levels below each root to descend, default 1). The scan seams read these keys from `UserDefaults` on every scan, so a change takes effect on the next scan. **Update conditions card** — configures the large/unknown download estimate, low-battery threshold, unpacked-size multiplier and free-disk safety margin used by both window and unattended preflights.
- **Permissions & Privacy.** The **What Wega does** trust card on top, then the **Wega helper** card (**Install Helper** / **Remove Helper**) and the **Touch ID for administrator commands** card — on Macs with biometry hardware, it shows whether `pam_tid.so` is wired into `/etc/pam.d/sudo_local` and offers **Use Touch ID Instead of Your Admin Password**, and, when the Wega helper is installed and current, **Turn Off Touch ID for sudo**. The helper removes only the exact `auth       sufficient     pam_tid.so` line from `/etc/pam.d/sudo_local`, keeps Apple's template, swaps the new file in atomically, checks it and puts the old file back if anything fails (a backup stays behind only when something fails, including the last cleanup step: the write and its restore both fail, the file changes meanwhile, or the cleanup of the swap file fails; the helper reports it); it refuses a file or directory that someone other than root can change. With an older helper the card says the helper is out of date (protocol 8 is needed only to turn Touch ID on; a v6 helper, which every released Wega ships, still does rollback, self-update and Trash, and a v7 one also turns Touch ID off, until the Mac restarts or the helper is reinstalled). Without a current helper, **Turn Off Touch ID for sudo** is replaced by a copyable command (**Copy command**, **Open in Terminal**; `TouchIDSudoConfigurator.manualDisableTerminalCommand`, run through `/usr/bin/sudo` in the C locale) beside the guide link. It is shown only when Touch ID is on, the app's own preflight found `/etc/pam.d`, `sudo_local` and `/etc/pam.d/sudo` safe, no later policy file exists and the app's own read of `sudo_local` plans a removal by the helper's rules. The command removes only the exact line and refuses, changing nothing, a file with a backslash, other settings, a NUL byte, non-UTF-8 text or a size over 64 KiB, and a later policy path or a linked `/usr/local` directory; **Check again** recomputes the offer. In every other case the card says what the app found, or that you can turn it off by hand. Turning Touch ID on goes through the helper too and, like turning it off, needs an administrator signed in at the console. The helper first checks `/etc/pam.d`, `sudo_local` and, only when there is no `sudo_local`, `sudo_local.template` (owner, mode and ACL, with an ACL failing closed; a regular file; at most 64 KiB; UTF-8 with no NUL) and refuses an unsafe one instead of replacing it with the template; it writes nothing when `sudo_local` already has the line, and checks the result through the verified directory. The card explains each refusal and does not offer the manual Terminal command after one. The manual enable command, shown when the helper is missing or too old to enable, runs through `/usr/bin/sudo` in the C locale, refuses an existing `sudo_local` that is a link, not a regular file, not owned by root, writable by group or others or with an ACL, and an existing `sudo_local.template` that is a link, not root's, group/other-writable or with an ACL (a missing template is accepted), and ends an unterminated last line before adding the directive. RecoveryOS-only advice replaces every button and command, and says not to type a password into `sudo`, when `sudo_local` is not a regular file, when it or `/etc/pam.d` is unsafe (seen by the app or reported by the helper), when `/etc/pam.d/sudo` can be changed by someone other than root, or when the app cannot prove the setup safe (the English card calls it macOS Recovery). While that advice shows, Wega asks for no administrator password itself (`SudoPasswordPromptGate`): an update run holds the casks that may ask for one (or have no known profile) out of its preparation, marks them **skipping — may need a password** and lists them under **Not started** with **Open Touch ID card**; an App Store batch that stops where it would need `sudo` is not primed for it and shows as not finished under **Needs attention**; the list warns before the run; the brew environment drops `SUDO_ASKPASS` and the `sudo -A` shim, the shim runs `sudo -n`, the askpass exits without a password field, and the failure banner offers **Open Touch ID card**. With Touch ID for `sudo` on, a `sudo` a cask or `mas` runs on its own may still show the Touch ID sheet, never a password field. The run checks right before it starts and before each such cask. The helper exits after a minute with no connection and no work in progress and is started again for the next request, from the installed Wega. The helper does four things: install a verified Wega package, turn Touch ID for `sudo` on or off, restore an app's pre-update copy, and move a root-owned app to the Trash. The trust card has three sections. **Permissions** gives, for the Wega helper, Touch ID, App Management (with its current state) and Full Disk Access, why it is needed, what happens without it and how to take it back, and links the steps for turning Touch ID for `sudo` off. **Connections** says that checking installs and removes nothing (the exception being apps allowed to update in the background), that Wega sends no telemetry or analytics, and lists the fixed hosts behind **Show Fixed Addresses** — read from `endpoints.json`, so the list cannot drift from what Wega contacts — with a caption for the dynamic ones (update addresses stored in installed apps, the npm registry, App Store servers). **Local data and reports** says logs, the last scan and pre-update copies (up to 7 days) stay on the Mac.
- **Cleanup.** The **Project folders card** — the folders Cleanup reads project version files from (default `~/Dev`); *Dodaj katalog…* adds one and each row's trash button removes it. A protected location, or a folder that contains one, is refused with the reason, and a list you empty stays empty instead of falling back to `~/Dev`. The next scan, and every removal's re-check, read the list as it is then. The **Files and Folders map card** — the off-by-default switch for D10 with the Full Disk Access warning and a button that opens that pane in System Settings; it does not probe whether Wega has the access, the next scan shows it.
- **Advanced.** **Post-update launch test**, **Crash reporting**, the **Application catalog card** — pulls the latest `AppCatalog` overlay from its canonical source on demand (the app also refreshes it on launch), reports the outcome and notes that a fetched update applies on the next launch; the **GitHub token** card, **System diagnostics** (Homebrew and mas-cli versions, and **Export diagnostics**), **Environment** (macOS, CPU architecture) and the license block for bundled open-source tools.

On a copy of Wega that does not belong to root, such as one dragged from the `.dmg`, the **Wega helper** card shows **Unavailable** instead of **Install Helper**, with the reason, how to install Wega from the `.pkg`, **Open Releases Page**, and **Remove Helper** while a registration is left.

The **unverified endpoints configuration card (SEC-08)** tops every tab when an `endpoints.json` overlay is applied without a valid signature, surfacing the presence of that unverified configuration to the user rather than leaving it in the log. The window's minimum width keeps all five tabs in the toolbar instead of its overflow menu.

### Logs
Full activity log covering scans, source responses, install results, and errors — newest entry first. It retains menu-bar and background-source failures (including Brew stderr), exhausted HTTP retries, process aborts, rejected self-update signatures, helper installation failures, and failed rollbacks, so **Show in Logs** leads to the underlying cause rather than only a summary. Filter by severity (All / Warnings+ / Errors only), search by text, copy entries to the clipboard, or reveal the log file in Finder. **Eksportuj diagnostykę** reports its result in a line under the toolbar: *"Diagnostics saved."* with **Show in Finder**, the reason it failed with a hint to try again, and nothing at all when you cancel the save panel. When a source fails to respond and the Updates screen shows the "list may be incomplete" warning, the button jumps straight to this tab pre-filtered to errors. The log is also written to `~/Library/Logs/WegaMacUpdater/wega.log`; once the file exceeds ~5 MB it rotates to `wega.log.1`, keeping one backup. The privileged root helper separately writes rejected XPC connections and per-operation audit results to macOS Unified Logging.

**Reporting a bug from a log entry.** An entry that carries structural failure detail — the command that ran, its exit code, and the tail of `stderr` — expands in place behind a disclosure arrow next to the row. Select one or more entries (⌘-click, ⇧-click) and use the toolbar's **"Zgłoś błąd…"** button to open the bug-report window; it works with nothing selected too (the report then carries only the environment context), and **"Zgłoś błąd"** in the Settings window opens the same sheet. That window is one composer with a single button that names what it opens — **"Otwórz szkic e-maila"** or **"Otwórz zgłoszenie na GitHubie"** — not two separate ones: a description field, a segmented **channel picker** (**"Wyślij e-mailem"** / **"Zgłoś na GitHubie"**), and a preview of the exact text that will leave the machine — all driven by the one selected channel, so switching it recomputes the preview, the truncation notice and the **"Kopiuj treść"** button together, and what you copy can never diverge from what you send. E-mail and GitHub carry different URL-length limits (2000 and 8000 characters); a large selection keeps the newest entries and drops the oldest ones to fit, and when it does, both the preview header and the report body itself say how many were omitted. The body is redacted through the same `LogRedaction.redactForExport` pass Export diagnostics uses — paths, URL query strings, credentials, e-mail addresses and account names become placeholders — and Wega never sends anything on its own: the channel only opens a prefilled mail-compose window or a prefilled GitHub issue form, and sending is the user's own action. `mailto:` cannot carry attachments in any client, so the full diagnostics zip stays the separate **"Eksportuj diagnostykę"** action in the same toolbar. When the machine has nothing that can open the chosen URL, the same window falls back to a copyable subject and body plus, per channel, the recipient address or the issue-page link — so a report is never a dead end. The e-mail recipient comes from `supportEmail` in `endpoints.json` and can be overridden by the user-writable overlay at `~/Library/Application Support/WegaMacUpdater/endpoints.json`.

**Persistent update traces.** Update operations also write bounded JSONL traces under
`~/Library/Logs/WegaMacUpdater/traces`, separate from the visible activity log. Run and
process identifiers connect stage decisions, existing Wega log messages with their severity
and category, command stdout/stderr, exit/cancellation
results, HTTP attempts/retries/cache responses and vendor version comparisons. HTTP
tracing runs only within a diagnostic operation and excludes bodies, headers, URL
credentials and query parameters. These events observe the existing update path; they
do not change retries, installation or vendor handoff decisions.

**Export diagnostics** includes the retained `trace-<run-id>.jsonl` files and
`trace-manifest.json` beside both ordinary log files. The manifest makes incomplete runs,
truncation, read/write failures and retention limits explicit. Limits are 8 MiB per run
(command output uses at most 75%), 50 run files, 64 MiB total and 14 days; active runs
are preserved during retention. Each process stream is capped separately at 2 MiB of
redacted output, and pending incomplete lines at 64 KiB. Complete lines and the final
partial line at EOF are redacted before storage; explicit markers and counters report
omitted lines or bytes. Reaching either stream cap stops trace capture for that stream
without changing the running command, its result buffers or its live output.
Export remains a redacted local ZIP selected through the
save panel. It does not collect private vendor or Docker daemon logs and does not prove
the internal cause of a vendor updater failure.

### Menu-bar agent
A Wega silhouette lives in the menu bar, **badged with the number of available updates**. On a configurable schedule (off / hourly / every 6 hours / daily, default every 6 hours) it runs a background check — **read-only unless you allowed background updates for specific apps**, in which case the menu's check button reads **Check and update in background (N)** — and posts a notification when new updates appear. **A background check never raises the macOS permission dialog**: the first time the agent has something to announce, Wega asks in her card at the bottom of the sidebar, and only a user who accepts there spends the one-shot system prompt (`NotificationPrompt` in Core decides this; declining is remembered, so the question does not return on its own; **Settings → General → Notifications** switches notifications on or off at any time).

**Docker Desktop is always excluded from unattended upgrades**, even with saved opt-in
consent; Settings shows the reason.

**The menu is specific about what it does.** Under the status line the menu dates the last
check in words (*"Checked 21:14"*, *"Checked yesterday, 21:14"*, or the date), and, while checks
are on, says *"Next attempt: today, 15:00, while Wega is running. Closing the window doesn't
quit the app."* — nothing while a check runs. While the Wega window runs a check, the menu says *"Checking for updates in the Wega window…"*, its check button waits, and the agent's own scheduled attempt waits too; a run you started in the window takes precedence over a check. The words move at midnight, after a clock change
and after sleep. Each app with an update is a row (the first 10, then a count of the rest),
with its versions when known (*Slack 4.47 → 4.48*) and a **⚠︎** when its release notes may
describe a security fix; clicking a row brings Wega forward on Updates with that update in the
inspector. The check button reads **Check now**, or **Check and update in background (N)** with
N the apps allowed to update in the background; the menu's other items are **Open Wega** and
**Quit Wega**.

**Background updates (opt-in, per app)** — from a row's ⋯ menu you can let Wega upgrade a cask unattended. The Settings window keeps a durable audit of every consent—including packages no longer present in the current update list—with its grant date, revoke action and a current per-package reason: ignored/pinned policy, no update waiting, unresolved installed app, running app, unsafe metadata, or readiness for the final checks. While Settings is visible, that verdict refreshes after app launches or exits, after returning to the active lifecycle, and periodically for Homebrew's outdated state; rapid lifecycle events are debounced and every Homebrew read shares the app-wide read/write coordinator. Every safety condition must hold, and the default answer is no: you opted this app in; the cask installs an `.app` and only `app`/`binary`/`zap` artifacts (no `pkg`/`installer`/`preflight` hook); Homebrew has a concrete `sha256`; no ignore/pin rule applies; and the app is not running. Metadata alone is not enough: Wega must resolve the installed `.app` and successfully create its copy-on-write snapshot in that exact round. A missing path or failed snapshot vetoes that token before `brew` starts, leaving it for the user-present window flow. Snapshot feasibility, resources and publisher safety are deliberately checked only immediately before the unattended update, not speculatively from Settings. After acquiring the upgrade mutex, Wega checks policies and running processes again so a decision made while the round waited cannot be stale. Sudo-requiring and binary-only casks are excluded *by construction*, not by preference. Before any snapshot or payload download, the same hard resource gate used by the window checks metered/Low Data Mode networking, battery level, thermal throttling and free disk. Its disk budget is the download plus estimated unpacked payload plus the full allocated size of the rollback snapshot plus a safety margin. Unknown sizes use the configured estimate; an unreadable capacity fails closed. A veto postpones the round and persists its reason in Wega's log.

The upgrade runs through the **same** snapshot → Gatekeeper-canary → auto-rollback chain as a foreground one (`CaskRollbackGuard`, shared by both) — automatic recovery is precisely what makes updating unattended defensible. A mutex guarantees a background upgrade and a window upgrade never overlap; the window always wins. Any non-zero global brew exit invalidates every token in the unattended batch, even if brew names only one failure. The completion notification reports **every** outcome of the round, not just the successes: how many were upgraded, how many were rolled back, which one's rollback *failed*, and which one changed its publisher's Team ID. The unattended path re-queries `brew outdated` afterwards, so a cask that still shows up as outdated is not counted as upgraded. The badge and notification are derived from one post-upgrade result, and newness is compared by the update identifiers' fingerprint rather than their count. This is **not a daemon**: it lives in the menu-bar agent, so nothing happens while Wega is closed — which used to mean the schedule, badge, notifications and silent updates all died at the first restart of the Mac, until you launched Wega again by hand (background mode was a promise that held only until the first reboot). **Settings (⌘,) now carries an explicit „Uruchamiaj przy logowaniu" (Launch at login) toggle** (BG-02), built on `SMAppService.mainApp` — the same modern registration mechanism the privileged helper uses (`SMAppService.daemon`), one tier up. It shows the login item's **real system status** (never a stored guess), lets you switch it off, and when on, macOS relaunches Wega at login so `AppDelegate` restarts the menu-bar agent and background mode keeps working across a reboot instead of dying at it. The honest framing is *safe = automatic, the rest = one click*. The dropdown shows the current status, last-check time, **the names of the apps that have updates** (UX-11g — so it says *which* apps, not only *how many*; the list is filtered by the same ignore/pin rules as the badge and capped, with the rest folded into an „i jeszcze N" line), **Check now**, **Open Wega**, the interval picker, and **Quit**. Closing the window keeps the agent running; ignore/pin rules are honoured by the background count too. Notifications are gated on a real app bundle, so `swift run` degrades gracefully.
