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

### The rollback shield

Each Homebrew cask row carries a **🛡 shield badge** when Wega can protect the upgrade with
its snapshot → canary → auto-rollback net: it clones the installed app first, verifies the
new version's code signature and publisher (Team ID) after Homebrew finishes, and
**restores the previous version automatically** if the new one fails verification. A cask
that can't be protected (for example one that installs no `.app`) shows an honest
**"no protection"** badge instead of a false shield. The badge describes what happens
*during* the upgrade — there is no general "undo" afterwards.

> **Publisher-change safety.** If the app's code-signing identity changes to an unexpected
> publisher, Wega blocks the upgrade and raises a sticky security alert rather than
> silently trusting it.

### What "updating" means per source

Wega routes each app through the right updater:

- **Homebrew casks/formulae** — `brew upgrade`, with a live log panel.
- **Mac App Store** — `mas` upgrade.
- **npm globals** — `npm install -g <pkg>@latest`.
- **JetBrains IDEs** — opens JetBrains Toolbox.
- **GitHub-released apps** — opens the Releases page.
- **Sparkle and self-updating apps** (ChatGPT, Postman, Parallels, Antigravity, Google
  Drive, Obsidian…) — Wega launches the app so its own signed updater takes over, instead
  of forcing a stale Homebrew cask over it.

After an upgrade, Wega detects apps that were running and offers a one-click **restart**.

### Honest results

A green *"Updated N packages"* banner appears **only when every step of every item
succeeded** — the package manager, the security canary, the rollback net and the follow-up
re-scan. If something didn't make it, Wega says **"Update incomplete"** and names what
failed. A failed rollback (new version rejected *and* old one not restored) raises its own
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
- copy entries to the clipboard, or
- **Reveal in Finder** the underlying log file.

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
