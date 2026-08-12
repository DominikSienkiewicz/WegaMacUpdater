# Wega Mac Updater — User Guide

This guide takes you from a fresh install to a confident daily workflow, in four steps:

1. [Installation](#1-installation)
2. [Your first scan](#2-your-first-scan)
3. [Updating your apps](#3-updating-your-apps)
4. [Diagnostics & troubleshooting](#4-diagnostics--troubleshooting)

It is written for people who **use** Wega. If you want to build the app or send a change,
see [`CONTRIBUTING.md`](CONTRIBUTING.md). To report a security problem, see
[`SECURITY.md`](SECURITY.md).

> **Language.** Wega ships in **Polski** and **English**. On first launch it follows your
> macOS language; you can switch it any time in the **Settings** window (**⌘,** →
> *Language*). The menu and button names in this guide are given by what they do — your
> app may show them in Polish.

---

## 1. Installation

### Requirements

- **macOS 26 (Tahoe) or newer.**
- **Homebrew is optional.** Without it, Wega still checks the Mac App Store, Sparkle apps,
  the built-in vendor feeds and npm globals — it simply shows an *"install Homebrew to
  unlock more updates"* card instead of Homebrew results.
- **`mas` (Mac App Store CLI) is optional.** App Store features degrade gracefully when it
  is absent.

You do **not** need to open a terminal to use Wega, and Wega never asks for your Homebrew
or App Store passwords.

### Install the app

1. Download the latest **`.dmg`** (or **`.pkg`**) from the
   [Releases page](https://github.com/DominikSienkiewicz/WegaMacUpdater/releases).
2. **`.dmg`** — open it and drag **Wega Mac Updater** into your **Applications** folder.
   **`.pkg`** — double-click it and follow the installer.
3. Launch Wega from Applications or Spotlight.

> **First-launch security prompt.** Depending on how the release was signed, macOS
> Gatekeeper may warn that the app is from an unidentified developer. If so, right-click
> the app → **Open**, then confirm — you only need to do this once.

Once installed, Wega can keep **itself** up to date: the **Settings** window checks for a
newer release and offers a one-click **Download and install**.

---

## 2. Your first scan

1. Open Wega. The window opens on the **Updates** screen.
2. Press **⌘R** (or **Check now**) to start a scan. The sidebar icon shows a spinner while
   it runs, and you can press **Cancel** to stop it where it stands.

**A scan never changes your system.** Checking for updates is read-only — Wega does not
install, remove, or `brew cleanup` anything during a scan.

### What Wega checks

In one pass, Wega looks at Homebrew casks and formulae, the Mac App Store, npm global
packages, Sparkle auto-updaters, and a set of vendor feeds (JetBrains, GitHub Releases,
Synology, Parallels, Google Drive, ChatGPT, Postman, Obsidian, Antigravity, and more). It
walks `/Applications` and `~/Applications`, reads each app's real installed version, and
picks the best source for each app.

Two kinds of software live outside `/Applications` or outside every package manager, and
Wega goes and gets them anyway:

- **Java runtimes** — the `.jdk` bundles in `/Library/Java/JavaVirtualMachines`. Wega asks
  macOS which installer package put each one there and matches that against Homebrew's cask
  database, so an outdated `temurin-26.jdk` shows up as an ordinary Brew update.
- **Adobe Creative Cloud apps** — Lightroom, Photoshop, Illustrator and the rest. Adobe
  publishes no update feed that other tools can read and Homebrew packages almost none of
  these apps, so Wega reads Creative Cloud's own record of what you have installed and
  compares it against Adobe's published product catalog.

### Reading the results

- The list shows every app with an available update, grouped by where it came from
  (**Homebrew Casks**, **App Store**, **Manually installed**, …) — the same grouping the
  Inventory window uses.
- The header names two numbers, for example **"12 to install + 3 manual"**. The two halves
  behave differently: the *install* half is what Wega can upgrade for you; the *manual*
  half are apps whose own updater or store page has to finish the job. The **Update all
  (N)** button counts only the installable half, so it never promises something Wega
  can't do.
- **The window opens with a result, not a blank screen.** Wega restores your last scan
  from disk (or from the background menu-bar check, whichever is newer). If a restored
  result is stale it says so — e.g. *"Found 12 Jul, 21:14"* in a warning tint — rather than
  passing an old result off as fresh.

### The menu-bar agent

A small box icon lives in your menu bar, **badged with the number of available updates**.
On a schedule you choose (off / hourly / every 6 hours / daily — default every 6 hours) it
runs a quiet, **read-only** background check and notifies you when new updates appear.
Closing the main window keeps this agent running; use **Quit** in its dropdown to stop it.

> The first time the agent has something to announce, Wega shows an explanation card in
> its own window before it ever raises the macOS notification prompt — so a background
> check never surprises you with a system dialog.

**Clicking a notification takes you to what it is about**, not just to whatever screen Wega
last showed. "Updates available" opens the updates list; the summary of an unattended round
opens that list too, unless something in the round needs attention — a rollback that failed, a
publisher that changed — in which case it opens the **Logs** view, because that is where the
reason is written. A report that Wega repaired an interrupted update always opens the log, for
the same reason. A notification left over from an older version simply brings Wega forward, as
it always did.

---

## 3. Updating your apps

### Choose what to update

- Tick individual apps, or use **Update all (N)** to take every installable update at once.
- Before committing, expand **"Show exactly what I will do"** to see a **dry-run panel**:
  the literal commands Wega will run (`brew upgrade --cask …`, `npm install -g x@latest`,
  …) — read from the *same* code that performs the upgrade, so the preview can't drift from
  reality. Per cask it also shows the download host, whether Homebrew will verify the
  checksum, whether rollback protection covers it, whether it **may** ask for an admin
  password, and the download size (shown as **"size unknown"** when the server won't say).

### Watching an update run

While an update installs, a progress bar sits under the header. It counts **whole
packages** — "Installing firefox — 3 of 7" — and the line under it names what the run is
doing: preparing backups, downloading, or installing. When the last package is done, Wega
re-checks the list and the scan's own progress bar takes over.

There is no download percentage, and that is deliberate. Homebrew silences its download
meter whenever it is not printing to a terminal, so the bytes are genuinely invisible to
Wega; showing a percentage would mean inventing one. A single large app therefore holds the
bar at the same place while it downloads — the label keeps saying what is happening.

A run that fails part-way stops short of the end: six of seven packages upgraded leaves the
bar at 6/7, and the banner explains the rest.

### Stopping an update

An update in progress can be stopped: while it runs, the **Update** button is joined by
**Cancel**. Wega stops at the **next package boundary** — the install already running is
allowed to finish, because a package manager killed halfway through a download or an app
replacement is exactly how a broken app happens. Everything after that package is skipped,
and the summary says how many packages were updated and how many were left untouched, so a
stopped run is never reported as a finished one. An update still waiting for another
operation to release the system is dropped immediately, since it has changed nothing yet.

Cancelling — and every timeout — now really stops the tool Wega started, together with any
helper process it spawned: Wega asks it to quit, gives it a moment to unwind, and kills it
if it refuses. Every command also has both a maximum runtime and an inactivity limit, so a
package manager that hangs silently can no longer hold the window forever.

### The rollback shield

Each Homebrew cask row carries a **🛡 shield badge** when Wega can protect the upgrade with
its snapshot → canary → auto-rollback net: it clones the installed app first, verifies the
new version's code signature and publisher (Team ID) after Homebrew finishes, and
**restores the previous version automatically** if the new one fails verification. A cask
that can't be protected (for example one that installs no `.app`) shows an honest
**"no protection"** badge instead of a false shield. Sources Wega cannot roll back at
all — formulae, the Mac App Store, npm and vendor-direct apps — say so under their
section headers.

> **Publisher-change safety.** If the app's code-signing identity changes to an unexpected
> publisher, Wega blocks the upgrade and raises a sticky security alert rather than
> silently trusting it.

Those checks say what the new file *is*; they don't say whether it starts. So after they
pass, Wega **launches the updated app hidden in the background and watches it for five
seconds**. If it crashes straight away — or macOS refuses to start it at all — the previous
version comes back from the snapshot, the same way any other failed check is undone. An app
you already have open is skipped, never quit to make room, and skipping never undoes an
update. The check is on by default; you can turn it off under **Settings → Post-update
launch test** if one of your apps takes badly to being started and closed unattended.

### Undo update

For **7 days** after an upgrade, Wega keeps the pre-upgrade copy of each updated app
(casks only — the sources listed above without a shield have nothing to restore). The
**„Cofnij aktualizacje" (Undo updates)** section of the sidebar lists every copy still
retained, naming the version it would bring back and the date the copy expires; the badge
next to it counts them. Undoing restores the previous app and **pins that version**, so the
update you just took back is not offered again until you lift the pin in Settings.

Every upgrade also writes a **journal** of its phases, so a crash or power cut in the
middle does not leave an app half-installed: at the next launch Wega settles what was
interrupted — finishes or rolls back the landed upgrade, puts back an app that went
missing, and tells you whenever it restored something.

### What "updating" means per source

Wega routes each app through the right updater:

- **Homebrew casks/formulae** — `brew upgrade`, with a live log panel.
- **Mac App Store** — `mas` upgrade.
- **npm globals** — `npm install -g <pkg>@latest`.
- **JetBrains IDEs** — opens JetBrains Toolbox.
- **GitHub-released apps** — those that carry their own updater (Visual Studio Code,
  Obsidian, GitHub Desktop…) open so that updater can take over, with a **GitHub Releases**
  link kept beside the button for when it has been switched off. The rest open the Releases
  page.
- **Sparkle and self-updating apps** (ChatGPT, Postman, Parallels, Antigravity, Google
  Drive, Obsidian…) — Wega launches the app so its own signed updater takes over, instead
  of forcing a stale Homebrew cask over it.
- **Adobe Creative Cloud apps** — opens the Creative Cloud app on your Mac, which is the
  only thing that can install an Adobe update. If you do not have it, the button opens
  Adobe's page instead.
- **Java runtimes** — updated through Homebrew like any other cask. A JDK is installed by a
  package rather than copied into place, so Wega cannot take a snapshot of it first: this
  one update runs without the automatic rollback, and the log says so before it starts.

After an upgrade, Wega detects apps that were running and offers a one-click **restart**.

### Honest results

A green *"Updated N packages"* banner appears **only when every step of every item
succeeded** — the package manager, the security canary, the rollback net and the follow-up
re-scan. It fades out on its own after about three seconds: it confirms something finished
and asks nothing of you. If something didn't make it, Wega says **"Update incomplete"** and
names what failed — and *that* banner stays until you close it, as does any banner offering
a button. A failed rollback (new version rejected *and* old one not restored) raises its own
**red sticky banner** telling you to check that app before using it.

### Skip or pin updates

Use the **⋯** menu on any row (or right-click it) to:

- **Ignore** an app — *"don't update Zoom"*.
- **Pin a version** — *"pin Parallels to 18"*; only updates up to that ceiling are shown.

Manage these rules any time from the **Settings** window (**⌘,** → *Ignored & pinned*);
they persist across launches and the menu-bar badge honours them too.

---

## 4. Diagnostics & troubleshooting

### The Logs tab

Every scan, source response, install result and error is recorded in the **Logs** tab
(sidebar), newest first. You can:

- filter by severity (**All / Warnings+ / Errors only**),
- search the text,
- copy entries to the clipboard,
- **Reveal in Finder** the underlying log file, or
- **Export diagnostics** — the whole troubleshooting package in one file (below).

The log also lives on disk at
`~/Library/Logs/WegaMacUpdater/wega.log` (it rotates to `wega.log.1` past ~5 MB). When a
scan couldn't reach a source and the Updates screen shows a *"the list may be incomplete"*
warning, its button jumps straight here, pre-filtered to errors — so you land on the cause,
not just a summary.

### Settings diagnostics

The **Settings** window (**⌘,**) shows live diagnostics: Homebrew version, `mas` version,
the **App Management** permission, Privileged Helper status, macOS version and CPU
architecture — the first things to check if a source behaves oddly. The App Management row
is a preflight (see below): it reads `granted`, `denied` or `undetermined`, and offers a
link straight to the settings pane when the answer is `denied`. It is an indication, not a
verdict — an upgrade that actually hits the refusal has the last word.
It also has an **App catalog** card that refreshes Wega's list of
supported apps on demand (it also refreshes on launch); a fetched update applies on the
next launch.

When a newer Wega is available, the same window lists **every release since the one you
have** — not just the latest — so three versions behind reads as three change-lists, not
one. Each is collapsed to its version and date; expand any to read its notes. If GitHub
can't be reached, it says so plainly instead of showing nothing — either way, this never
holds up the update itself.

Wega always downloads the **`.pkg`** when a release publishes one, and falls back to the
`.dmg` only when it does not. That is a security choice, not a convenience one: the `.pkg`
is the only artifact Wega can check all the way back to its own developer certificate. What
changes when the privileged helper is switched on is only *who finishes the job* — with the
helper, Wega installs it for you and then asks you to restart; without it, the same file is
handed to you to run yourself. A release that publishes neither offers no update button at
all rather than something Wega cannot verify.

### Export diagnostics

**Settings → System diagnostics → Export diagnostics** (also in the **Logs** toolbar)
saves a single `.zip` with everything a bug report needs, so filing one never means
collecting it by hand:

| In the zip | What it holds |
| --- | --- |
| `report.txt` | App version and build, macOS version and CPU, detected package managers and their versions, Privileged Helper status and version, schedule status, the last scan's result per source, free disk space and the signature state. |
| `update-history.txt` | The last 40 upgrade runs, item by item: update → validation → rollback, including which apps were rolled back and where a publisher's Team ID changed. |
| `logs/wega.log`, `logs/wega.log.1` | **Both** log files — the current one and the rotated one. |

Two things about this file are deliberate:

- **It is redacted.** Filesystem paths, URL query strings, credentials (API keys, bearer
  tokens, `Authorization` headers, private keys), e-mail addresses and your account names
  are replaced with `[path]`, `[query]`, `[secret]`, `[email]` and `[user]` before anything
  is written. The failure itself survives; the identity behind it does not. Team ID values
  are not exported either — the history records *that* a publisher changed, not who.
- **Nothing is sent anywhere.** Wega has no upload, no share sheet and no default
  destination. A save panel asks where to put the file, and the file goes exactly there.
  Attaching it to an issue is your decision, separately.

Open the zip and read `report.txt` before attaching it if you want to see precisely what
you are sharing.

### Common situations

- **"Couldn't check — check your connection."** A source was unreachable, so Wega says so
  instead of falsely reporting *"everything up to date."* This state survives a restart.
- **"App Management permission missing."** Since macOS 13, replacing an app in
  `/Applications` requires the **App Management** permission, and it covers the tools Wega
  runs — so without it `brew` fails with `ditto: /Applications/X.app: Operation not
  permitted` and nothing is updated. Click **Open privacy settings** on the banner (or the
  link in Settings diagnostics), enable **Wega** under **Privacy & Security → App
  Management**, then run the update again. Until it is granted, background updates pause
  for 24 hours at a time instead of retrying — and failing — on every scheduled check.
- **An incomplete scan banner.** If a scan finished but some sources stayed silent, Wega
  marks the list as partial rather than passing it off as complete. Open **Logs** (filtered
  to errors) to see which source failed.
### Crash reporting (off by default)

The **Crash reporting** card in Settings can collect Wega's own crash and hang reports, so
that if Wega ever dies on you the evidence is already waiting instead of having to be dug out
of Console. It is **off until you turn it on**, and everything about it is local:

- macOS (MetricKit) hands Wega its own report shortly after the *next* launch — a crash is
  never reported by the run that crashed, and an app that crashes on every launch cannot
  report itself at all.
- Reports **stay on this Mac**. Wega has nowhere to send them; there is no upload, no
  "anonymous statistics", not even an opt-out one.
- What is kept: Wega's version and build, the macOS version, CPU architecture, the
  termination reason and the stack trace. What is not: your locale, your Mac model, memory
  contents, and any filesystem path or URL — those are stripped the same way log lines are.
- Turning it on collects from that moment on. Crashes recorded before you agreed are not
  swept up.
- Up to 20 reports are kept for 90 days, in `~/Library/Logs/WegaMacUpdater/`, readable only
  by you. **Copy reports** puts them on the clipboard so you can attach them to a bug report;
  **Delete reports** wipes them. Sending one is always your decision.

- **Homebrew results are missing / an "install Homebrew" card shows.** Homebrew isn't
  installed (or isn't at `/opt/homebrew/bin/brew` or `/usr/local/bin/brew`). Install it to
  unlock cask and formula updates; everything else keeps working without it.
- **An app is managed by Homebrew but its app is gone.** Wega detects the orphaned cask,
  keeps it out of the update count, and offers a **Deregister** card — it never runs
  `brew uninstall --force` behind a "check for updates" button.
- **A JetBrains / GitHub / App Store app won't update in-app.** Those are *manual* sources
  by design — Wega opens Toolbox, the Releases page or the App Store so their own flow
  finishes the update.

### Uninstalling apps

The **Uninstall** screen removes any app regardless of origin (casks via `brew uninstall
--cask`; App Store and manual apps to the Trash). The confirmation dialog defaults to the
safe **"App only"**; the irreversible **"App + leftovers"** (which also deletes
preferences, caches and Application Support) is never pre-selected. If a scan couldn't read
a source, the dialog warns that the target list may be incomplete before anything is
removed. **Right-click any app in the list** to show it in Finder, copy its path, or toggle
whether it's marked for removal.

---

Need something this guide doesn't cover? Open a
[discussion or issue](https://github.com/DominikSienkiewicz/WegaMacUpdater/issues) — but
for anything security-sensitive, use the private channel in [`SECURITY.md`](SECURITY.md)
instead of a public issue.
