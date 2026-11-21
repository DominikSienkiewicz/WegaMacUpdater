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
> macOS language; you can switch it any time from the **globe** button in the main window's
> toolbar, or in the **Settings** window (**⌘,** → **General** → *Interface language*). The menu and button names in
> this guide are given by what they do — your app may show them in Polish.

---

## 1. Installation

### Requirements

- **macOS 26 (Tahoe) or newer.**
- **Homebrew is optional.** Without it, Wega still checks the Mac App Store, Sparkle apps,
  the built-in vendor feeds and npm globals — it simply shows an *"install Homebrew to
  unlock more updates"* card instead of Homebrew results.
- **`mas` (Mac App Store CLI) is optional.** App Store features degrade gracefully when it
  is absent.

You do **not** need to open a terminal for everyday use, and Wega never asks for your Homebrew
or App Store passwords. Two setups can still send you there: installing Homebrew itself (the
*"install Homebrew"* card shows the command and a **Copy command** button), and turning on
Touch ID for `sudo` when the optional Wega helper is not installed (the Touch ID card then
shows a one-line command to paste into Terminal, to turn it on or off).

### Install the app

1. Download **WegaMacUpdater.pkg** (recommended — it can ask for your administrator password when
   an update needs it) from the
   [Releases page](https://github.com/DominikSienkiewicz/WegaMacUpdater/releases). The `.dmg`
   can't ask for your administrator password, so some updates will fail unless Touch ID is on.
2. **`.pkg`** — double-click it and follow the installer. The PKG also installs the components
   that ask for your password. The Wega helper is a separate, optional setup.
   **`.dmg`** — open it and drag **Wega Mac Updater** into your **Applications** folder.
3. Launch Wega from Applications or Spotlight.

Stable releases are notarized, so macOS opens them without a warning.

Once installed, Wega can keep **itself** up to date: **Settings → General** checks for a
newer release. With the optional Wega helper switched on the button reads **Download and
install**; without it, it reads **Download and open the installer** and the downloaded
package is handed to you to run yourself (see [The Wega helper](#the-wega-helper)).

---

## 2. Your first scan

1. Open Wega. The window opens on the **Updates** screen, showing the last scan's result
   straight away, and starts refreshing it by itself. That refresh runs in the band above
   the list — the rows stay put and readable, and **Cancel** stops it. On a first launch
   there is nothing to show yet, so the scan takes the window instead, with Wega sniffing.
   If Homebrew's catalog was refreshed less than 30 minutes ago, this launch scan keeps it
   instead of running `brew update` again, and the band says so with a chip — **"Homebrew
   catalog from 12 min ago"**. Anything that does not look at the clock — **Check now**
   (**⌘R**) included — always refreshes the catalog first. The queue still waits until the
   scan ends either way.
2. Press **⌘R** (or **Check now**) whenever you want another scan. **⌘R** works on every
   screen; the **Check now** button appears only on **Updates**, **To Homebrew** ("Do Homebrew")
   and **Undo updates** ("Cofnij aktualizacje"), the screens that show the result of a scan.

**What a scan shows.** The scan runs in the band, and nothing covers the rows:

- a line that names the step Wega is on — for example **"Refreshing the Homebrew
  catalog…"** first, then Homebrew, the App Store, npm and the vendors;
- the time the patrol has taken, counted up, never estimated down;
- once the vendor step starts, a counter such as **"Vendors: 12 of 31 apps"**; until then,
  the note **"Selecting comes back when the scan finishes."**;
- a ring and a chip per source (Homebrew, App Store, npm, vendors), each done, running or
  not yet started;
- the rows stay visible, but you cannot tick them until the scan ends, and **Cancel** stops
  the scan where it stands.

**A scan never installs, removes or cleans anything.** Checking for updates does not touch
your apps. It does refresh Homebrew's own catalog (`brew update`) — unless the launch scan
reuses one refreshed in the last 30 minutes — which is why the first step is the slowest. An app missing from the list is not proof it is up to date — the line
**"Can't see an app? Missing from the list doesn't mean up to date — check its status in
Inventory"** under the list (and under its empty states) opens **Inventory**, where each app's
check status is shown.

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

- The list shows every app with an available update, grouped by what to do next:
  **Possible security fixes** first, then **Apps** and **CLI tools** Wega can update for you,
  then **Needs your action** for updates the vendor or you finish. Each row carries the app's
  name, with the Homebrew token — the name Homebrew knows it by, such as `visual-studio-code`
  — in small type under it when the token says something the name does not, and its source.
  Pick **Group › by source** next to the categories to group by where each app came from
  (**Homebrew apps**, **App Store**, **Manually installed**, …) — the same grouping the
  Inventory window uses.
- The band above the list counts the updates ("N updates") and sums up your queue, for
  example **"4 queued · 2 to finish with the developer"**. Apps Wega installs for you and
  apps whose own updater or store page has to finish the job are counted apart, so the
  button never promises something Wega can't do; the second half counts the apps you finish
  with the developer in the category on screen, and shows only while something is queued. Under
  it the band says how far an undo reaches (**"Undo: 3 of 4"**, or **"Checking undo
  availability"** while that is still being worked out; an app Wega could not check counts as
  not covered). Its button reads **Update N**, or **Nothing selected** while the queue is
  empty.
- **The window opens with a result, not a blank screen.** Wega restores your last scan
  from disk (or from the background menu-bar check, whichever is newer). If a restored
  result is stale it says so — e.g. *"Found 12 Jul, 21:14"* in a warning tint — rather than
  passing an old result off as fresh.

**Finding an app.** Press **⌘F** on **Updates** and type a name; the field is **Find an app**.
The list does not narrow. One answer row appears above it instead. When the app is among the
updates, the row says so (**On the update list:**) and links to the matching rows. When it is not, the row says what Wega knows about it: that it is
up to date and how that was checked, that Wega does not know where to update it from (with
**Report app ›**, the same report Inventory offers, so it can be added to the catalog), that the
check failed or that Wega has no current result and will check it next scan, or that one of
your rules hides it, with **Show Rules** to open them. When Inventory has never been read, the
row says so; searching never starts that read itself. **Show Rules** comes with an answer
about your rules, **Open Inventory** with the others. An answer from an Inventory read that may
have changed, or that was incomplete, says so. When the
name matches nothing on this Mac, the row says it can't see the app among the apps here.

Updates that your own rules (**Don't update**, **Skip this version**, a pin) hide from the
list are not lost: a line at the bottom reads **"Hidden by your rules: N · Show"** and opens
them.

### Checking status in Inventory

The **Sprawdzenie** (Check status) column describes an update check of that particular
installed copy, separately from its Brew/App Store/manual origin. Click the status for
the sources, last attempt and last complete check. **Wymaga sprawdzenia** (Needs checking)
filters missing evidence, unknown sources, partial failures and stale results, including
updates found alongside a source failure. Ignored, pinned or skipped available updates
read **Ukryte przez politykę** (Hidden by policy); the check itself still ran.

Inventory keeps its last read while you move between screens, and says when it was made —
**"Read today, 08:12"**. After something changes the installed apps (an update run, a background
update, a Cleanup removal, a move to Homebrew, an uninstall — also while the window was closed),
the line turns to **"Read today, 08:12 — the list may have changed"**. An install
from the list through Homebrew, a reinstall and an undo count the same way. Two buttons sit beside it and do different things: **Refresh Inventory** only
reads the disk again and does not look for new versions (its tooltip says so), while **Check for
updates** starts the same scan as **Check now** (**⌘R**) and takes you to Updates, where it can
be stopped. When the filters hide every app, the list says **"No apps match these filters."**
with a **Clear Filters** button; when no app was found in the scan folders, it says so and
suggests checking the scan folders or refreshing the inventory.

A result is stale after 24 hours or when a refreshed inventory finds a changed version/build. Moving an
app or replacing it with another bundle ID requires a new check. Old saved scans without
per-installation evidence show **Brak potwierdzenia** (Not confirmed), never “current”.
**Refresh Inventory** reads local installations; use **Check for updates** in Inventory or **Check now**
(**⌘R**) for a new update check. Opening this status does not add network requests.

An App Store receipt alone, a cask name match without a resolved installation path, or a
missing comparison version cannot prove that a specific copy is current. For App Store
apps, Wega validates the ID of the exact installed path against `mas list` and its version,
then applies the completed update query. Missing IDs, duplicate copies and incomplete
queries remain unconfirmed or failed. Refresh the update scan to replace older evidence.

Installer applications and JDKs need an exact link to their cask before a package result
can describe that installed copy. A receipt or declared application path can provide that
link; an ambiguous receipt or another copy cannot. Java runtimes remain in the scan report
when no source is confirmed, and an update already listed by Homebrew is not listed twice.
If an installed package cask is a possible match but the link cannot be confirmed, the
status reads **Powiązanie z Homebrew niepotwierdzone** (Homebrew association unconfirmed).
Open it to see the possible cask and the missing confirmation. For example, WARP and Google
Drive can show this status when installer receipts do not identify the copy. The note
cannot mark the app current or enable a cask update for that copy. Independent updates,
failures and stale results keep their usual status; the possible source remains in the
details. Run **Check now** after upgrading Wega to rebuild this evidence.

### Vendor-managed applications

Homebrew ownership does not hide vendor releases. When both sources report comparable
versions for the same verified installation, Updates presents the newer offer with its
appropriate action. A hidden older Homebrew offer is also excluded from automatic updates.
Versions that cannot be compared safely remain separate.

WARP and Logi Options+ updates appear as vendor handoffs and are excluded from batch and
background Homebrew updates. Open the application's status in Inventory for the vendor
instructions, even when no update version is known. If WARP is managed by your organization,
use the version and update controls provided by your administrator. Wega does not change
MDM settings or stop these services to force an update.

Bitdefender Antivirus for Mac shows its installed product version and build separately from
product and threat-signature freshness. Those freshness values remain unconfirmed: a running
antivirus, a recent file date or a signature refresh does not prove that the product is current.
Bitdefender Agent, VPN and App Store scanners are not treated as the antivirus product.

### Firefox, Thunderbird, Bruno, UTM and Zed

These applications can be checked when installed directly, without Homebrew:

| Application | Version source | Update action |
|---|---|---|
| Firefox | Mozilla feed for the installed Release, ESR or Beta channel | Open Firefox's updater |
| Thunderbird | Mozilla feed for the installed Release, ESR or Beta channel | Open Thunderbird's updater |
| Bruno | Official stable GitHub releases | Open Bruno, with the release page as a fallback |
| UTM | Official stable GitHub releases containing `UTM.dmg` | Open the official releases list |
| Zed | Official Stable or Preview update feed | Open Zed, with its channel release page as a fallback |

Wega reads Mozilla channel metadata from the particular installed bundle. Missing or
ambiguous channel metadata leaves the check unconfirmed; Wega does not assume Stable.
A Beta copy exposing only a base version such as `146.0`, without `b9`, stays unconfirmed.
An ESR installation is compared with its supported ESR branch rather than the latest
regular release. Homebrew offers and migration candidates for a different channel are excluded. Zed development
and custom builds do not inherit Stable offers.

UTM installed through the App Store keeps its App Store update route. An installation
advertising its own Sparkle feed retains that native update channel. Wega checks versions
and hands control to the appropriate updater or release page; a later version check must
confirm the installed copy actually reached the offered version.

### Microsoft Office and AutoUpdate

For vendor-installed Word, Excel, PowerPoint, Outlook and OneNote, Wega queries Microsoft
AutoUpdate (MAU) without installing anything. macOS may request permission for MAU during
its first query. A recognized newer offer appears in Updates; its action opens MAU, where
you decide what to install. Inventory also provides the MAU/support handoff without an offer.
Office installed from the App Store stays on the App Store route.

A `No updates available` response does not identify the registered path of each Office copy,
so Wega keeps that copy unconfirmed. Unknown output, command failures and missing version
evidence never become an “up to date” result. When MAU is not found at its standard location, the source remains unconfirmed and
provides Microsoft's support instructions. Opening MAU does not record an
installation success; completion requires independent evidence from the selected copy.

### Release notes for Homebrew casks

Select a cask row and click **Sprawdź notatki wydania** (Check release notes) in its inspector.
Wega reads the resolved app's Sparkle feed or its catalogued GitHub releases only on request;
it does not add another update or change the Brew installation route. Notes describe the
offered release, which can be older than the newest release in the feed.

A Sparkle display version and build are distinct: `1.0,101` from Brew matches `1.0 (101)`.
A display-only `1.0` shared by several feed builds is ambiguous, so Wega withholds the notes.
GitHub tags must match the offered version after removing the tag prefix. Missing notes
are shown separately from a failed request; failed requests offer Retry.

### Finishing an update with the vendor

For apps updated through their own updater, Toolbox, Creative Cloud or a vendor download
page, opening the destination leaves a pending handoff in Wega. Finish the update there,
then choose **“Check this app”** in the row or inspector. The check is also available when
you have already updated the app outside Wega. It reads this exact bundle from disk and
contacts only its selected vendor source; it does not refresh Homebrew or scan other apps.

An update is confirmed only when the bundle identifier still matches, the source reports
it current and the on-disk version reaches the offered target using the source's version
semantics (including Sparkle build numbers). The row then disappears and the diagnostic
update history records an **external** update. This verifies the version on disk; it does
not validate the signature or prove that an already-running process has restarted.

If the source fails, the app moves or disappears, the version stays too old, or the bundle
changes during the check, the row remains with a reason and a retry action. A newer release
reported by the source updates the pending row. Checks use the existing bounded HTTP retry
and timeout policy; Wega does not poll the vendor updater. **Cancel** stops verification,
not the external updater. Pending handoffs survive restarting Wega and language changes.
**Stop tracking** dismisses the handoff without recording success or removing the app; an
outdated row remains until a subsequent check resolves it. A full scan also closes the
handoff when its selected source reports this exact bundle current and the scan does not
list it as outdated; the history records an **external** update, without a banner. A
failed or skipped source leaves the handoff pending. A handoff whose source no longer checks
the app, such as GitHub Releases for Obsidian, is dropped without recording an update.

Older saved scan results lack a machine-readable verification target. They can be checked
again to refresh an outdated offer; if already current, run a full check.
Obsidian loads in-app updates from a shared ASAR package while its app bundle keeps the
installer version, so for Obsidian the source reading that package as current confirms the
update; the bundle version is not compared.

### Brew cache retention

Wega's Brew requests set `HOMEBREW_NO_INSTALL_CLEANUP=1`, including streamed adoption and
reinstall operations. This prevents Brew's automatic post-install cleanup; it does not
disable dependency checks or guarantee that every package can be rolled back. MAS and npm
do not receive this Wega-specific Brew setting. Cached downloads and old package versions
can occupy more disk space. You may run `brew cleanup` yourself when you no longer need
those artifacts. See the [Homebrew manual](https://docs.brew.sh/Manpage#environment).

### The menu-bar agent

Wega's head lives in your menu bar, **badged with the number of available updates**. It is
drawn as a template image, so it follows the bar — dark on a light bar, light on a dark one,
and inverted while its menu is open.
On a schedule you choose (off / hourly / every 6 hours / daily — default every 6 hours) it
runs a quiet background check and notifies you when new updates appear. The menu-bar check is
read-only unless you allowed background updates for specific apps; then the button reads
**Check and update in background (N)**, with N the number of apps you allowed, because a
check may then install those apps' updates. The agent installs an update on its own only for
an app you opted in to background updates, and only when every safety condition holds.
The dropdown names the apps that have updates, one row each for the first 10 and then a line
such as **and 3 more apps**, with the versions when they are known (**Slack 4.47 → 4.48**); a **⚠︎** in front of a name means its release notes may describe a
security fix. Clicking a row opens Wega on the Updates screen with that update's details
showing. Under the status, the dropdown dates the last check in words — **"Checked yesterday,
21:14"** — and, while automatic checks are on, says when the next one is due: **"Next attempt:
today, 15:00, while Wega is running. Closing the window doesn't quit the app."** While a check you started in the main window
runs, the menu says **Checking for updates in the Wega window…**, its check button waits, and
the agent's own scheduled attempt waits for that check. While an update you started in the main
window runs, it shows how far the run has got ("Updating 2 of 5…") with a **Stop After
Active Installs** button, even with the window closed; once clicked, the button reads
**Finishing active installs, not starting new ones**. Updates the agent installs in the
background are not shown there.
Closing the main window keeps this agent running; use **Quit Wega** in its dropdown to stop it.

> The first time the agent has something to announce, Wega asks in her card at the bottom
> of the sidebar before she ever raises the macOS notification prompt — so a background
> check never surprises you with a system dialog. If you answer **Keep Notifications Off**,
> she does not ask again, and you can change your mind any time under
> **Settings → General → Notifications**, where **Notify me about new updates** switches them on or off
> (and **Open Notification Settings** appears if macOS itself has turned them off).

**Clicking a notification takes you to what it is about**, not just to whatever screen Wega
last showed. If the window is closed, it opens again, and the list already shows the result of
the check that sent the notification. "Updates available" opens the updates list; the summary of an unattended round
opens that list too, unless something in the round needs attention — a rollback that failed, a
developer signature that changed — in which case it opens the **Logs** view, because that is where the
reason is written. A report that Wega repaired an interrupted update always opens the log, for
the same reason. A notification left over from an older version simply brings Wega forward, as
it always did.

---

## 3. Updating your apps

### Before your first update

Until your first update finishes with everything installed, a card above the list —
**Before I update your first app** — says what that update may need:

- **Checking works without any permissions.**
- **Replacing apps in /Applications — macOS has to allow it.** **Check now** asks macOS; if it
  refuses, **Open privacy settings** opens the pane that grants it.
- **Some apps ask for your administrator password when they update.** This is ticked when
  Touch ID for `sudo` is on or Wega was installed from the `.pkg`, which brings the
  components that ask for the password. **Enable Touch ID** opens Settings on the **Touch ID for
  administrator commands** card, in the **Permissions & Privacy** tab, when Touch ID can be turned on; **What does the helper do?** explains the optional Wega helper, which does
  not answer these password prompts.
- **Notify you about new updates?** — only until you answer it.

**Later** hides the card for now; **Got it** closes it for good.

### Choose what to update

- Tick individual apps, a whole group with its header checkbox, or everything with the
  select-all checkbox above the list. Each ticked row joins the queue, which the band above
  the list counts (for example **4 queued**).
- Each row is **one Tab stop per group**: Tab moves between groups, **↑** and **↓** move
  between the rows inside one, **Space** adds the focused row to the queue or takes it out,
  and **Return** shows its details. The **⋯** menu is a Tab stop of its own, and Space on it
  opens the menu without queueing anything. VoiceOver reads a row as one sentence — the app,
  the versions, the source, whether an automatic undo is possible and whether it is queued —
  and offers **Show details**, **Don't update** and **Skip this version** as actions on it.
- **Show exactly what I will do**, in the band, previews the exact commands. Then choose
  **Update** to run them. The button takes only what you queued; with nothing queued it
  reads **Nothing selected**.
- **Show exactly what I will do** opens the **dry-run panel**:
  the literal commands Wega will run (`brew upgrade --cask …`, `npm install -g x@latest`,
  …) — read from the *same* code that performs the upgrade, so the preview can't drift from
  reality. Per cask it also shows the download host, whether Homebrew will verify the
  checksum, whether rollback protection covers it, whether it **may** ask for an admin
  password, and the download size (shown as **"size unknown"** when the server won't say).

### Watching an update run

The run happens in the band above the list, and nothing covers the rows. The band's small
heading reads **"UPDATING · SINCE 08:14"** — when the run started, never a guess at when it
will end — and under it a line names what the run is doing: preparing backups, downloading, or
installing. It names the package too — "Installing firefox — 3 of 7" — but only while that
package is the only one installing; once several are running at once the line reads
"Installing packages — 3 of 7" instead, because naming one of three would misdescribe the
other two. A ring beside it shows **3/7**, and the band holds **Stop After Active Installs**;
the log opens by itself under the list when the run starts, and **Show log** appears in the band
only after you close it. It counts **whole packages**. When the last package is done, Wega re-checks
the list and the scan's band takes over.

The list stays readable but locked, and its header says **"The list stays locked until the
update ends."** Casks and npm packages say what is happening to them on their own row:
*waiting*, *installing…*, *installed, checking*, *failed*, or *won't start* for a row the run
will not begin after a stop request or a vendor's changed signature. Formulae and App Store
updates run as one batch each, so their state stands once in the group's header rather than on
every row. An update the vendor finishes says *with the vendor*. There is nothing for
**Reduce Transparency** to turn off: no veil is drawn, so the rows are as bright as they were.

There is no download percentage, and that is deliberate. Homebrew silences its download
meter whenever it is not printing to a terminal, so the bytes are genuinely invisible to
Wega; showing a percentage would mean inventing one. A single large app therefore holds the
ring at the same place while it downloads — the line keeps saying what is happening.

A run that fails part-way stops short of the end: six of seven packages upgraded leaves the
ring at 6/7, and the banner explains the rest.

The **log panel** under the list opens by itself when a run starts, and **Show log** in the band
brings it back after you close it. It streams what the package managers are printing. Because several packages install at once, **every line is prefixed
with the package it came from** — `[figma] ==> Downloading…`, `[mas] error: …` — so three
interleaved downloads stay tellable apart. That prefix is the package's own token and is
never translated, whatever language the interface is in: it is the name Homebrew, `mas` or
npm uses, so a log you paste into a bug report stays searchable by it.

### Stopping an update

While an update runs, the Updates screen belongs to it: the list, its checkboxes, banner
actions and manual installs stay visible but greyed out, and the list header says why. The
band shows the progress, the package being installed and **Stop After Active Installs**, plus
**Show log** once you have closed the log that opens with the run. The sidebar and the menu-bar dropdown show the run too, so you can leave this
screen and still see how far it has got. Nothing can be selected or started until the run
lands. Stopping is the one control the run keeps; **⌘.** and the menu-bar dropdown's button do
the same. Wega stops at the **next package boundary** — the installs already running are
allowed to finish (up to three at a time), because a package manager killed halfway through a download or an app
replacement is exactly how a broken app happens. Once you ask, the button reads **Finishing
active installs, not starting new ones**. Nothing new is started and everything still
queued is skipped, and the summary says how many packages were updated and how many were
left untouched, so a stopped run is never reported as a finished one. An update still
waiting for another operation to release the system is dropped immediately, since it has
changed nothing yet.

Cancelling — and every timeout — now really stops the tool Wega started, together with any
helper process it spawned: Wega asks it to quit, gives it a moment to unwind, and kills it
if it refuses. Every command also has both a maximum runtime and an inactivity limit, so a
package manager that hangs silently can no longer hold the window forever.

If the post-update launch test cannot confirm that an app's queued Squirrel/ShipIt update
was withdrawn, it leaves the app running and records the skipped teardown in Logs. This
prevents Wega's own quit from starting an unconfirmed installer. It does not prove that the
app's updater can never change the bundle later. Repair also checks build and prerelease
changes; Brew reporting success alone does not prove that the offered build arrived.

### The rollback shield

Each Homebrew cask row carries a **🛡 shield badge** when Wega can protect the upgrade with
its backup → canary → auto-rollback net: it clones the installed app first, verifies the
new version's code signature and developer signature (Team ID) after Homebrew finishes, and
**restores the previous version automatically** if the new one fails verification. A cask
that can't be protected (for example one that installs no `.app`) shows an honest
**"no protection"** badge instead of a false shield. Sources Wega cannot roll back at
all — formulae, the Mac App Store, npm and vendor-direct apps — say so under their
section headers.

> **Signature-change safety.** If the app's code-signing identity changes to an unexpected
> developer signature, Wega blocks the upgrade and raises a sticky security alert rather than
> silently trusting it. **Trust the New Signature** is there for the rare case where the
> developer really did change accounts; it asks for your confirmation first.

Those checks say what the new file *is*; they don't say whether it starts. So after they
pass, Wega **launches the updated app hidden in the background and watches it for five
seconds**. If it crashes straight away — or macOS refuses to start it at all — the previous
version comes back from the pre-update copy, the same way any other failed check is undone. An app
you already have open is skipped, never quit to make room, and skipping never undoes an
update. The check is on by default; you can turn it off under **Settings → Advanced → Post-update
launch test** if one of your apps takes badly to being started and closed unattended.

### Undo update

For **7 days** after an upgrade, Wega keeps the pre-upgrade copy of each updated app
(only Homebrew cask updates that replace an `.app`, as in the rollback shield above; the other
sources have nothing to restore, and the copy never includes an app's data). The Undo screen
shows the result of every undo, including when it could not be done. The
**„Cofnij aktualizacje" (Undo updates)** section of the sidebar lists **one entry per app** —
the step back from the version you are running now — naming the version it would bring back
and the date the copy expires; the badge next to it counts the apps, not the copies. An app
updated several times inside those 7 days therefore appears once, offering the most recent
update back; take it, and the step before it becomes the next offer, for as long as its copy
is still retained. Undoing restores the previous app and **pins that version**, so the update
you just took back is not offered again until you lift the pin in **Settings → Checking &
Background → Paused updates**.
That pin also covers vendor-feed and Homebrew metadata-repair offers for the same resolved
installation. A second copy at another path keeps its own update offers.

Protected cask upgrades write a **journal** before starting the package manager. If that
write fails, Wega postpones the update and reports the reason; background updates also
stop before starting Brew. This applies to adopting and migrating an existing app too.
At the next launch, the journal helps Wega inspect an interrupted operation and restore
a missing or rejected app from its pre-update copy. An unreadable journal, or an older journal
whose recorded phase cannot prove that installation never started, does not authorize
deleting its pre-update copies. Those copies remain available for investigation in
`~/Library/Application Support/WegaMacUpdater/update-operations/`; check Logs for details.

### What "updating" means per source

Wega routes each app through the right updater:

- **Homebrew casks/formulae** — `brew upgrade`, with a live log panel.
- **Mac App Store** — `mas` upgrade.
- **npm globals** — `npm install -g <pkg>@latest`.
- **JetBrains IDEs** — opens JetBrains Toolbox.
- **GitHub-released apps** — those that carry their own updater (Visual Studio Code,
  Rectangle, GitHub Desktop…) open so that updater can take over, with a **GitHub Releases**
  link kept beside the button for when it has been switched off. The rest open the Releases
  page.
- **Sparkle and self-updating apps** (ChatGPT, Postman, Parallels, Antigravity, Google
  Drive, Obsidian…) — Wega launches the app so its own signed updater takes over, instead
  of forcing a stale Homebrew cask over it.
- **Adobe Creative Cloud apps** — opens the Creative Cloud app on your Mac, which is the
  only thing that can install an Adobe update. If you do not have it, the button opens
  Adobe's page instead.
- **Java runtimes** — updated through Homebrew like any other cask. A JDK is installed by a
  package rather than copied into place, so Wega cannot make a pre-update copy of it first: this
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

### Keyboard shortcuts

Every shortcut is in the **Updates** menu of the menu bar, and **Help → Wega User Guide**
opens this guide.

| Shortcut | What it does |
| --- | --- |
| **⌘R** | **Check now** — works on every screen. |
| **⌘↩** | **Update** the queue — only on **Updates**, and only when something is queued. |
| **⌘.** | **Cancel Scan**, or, while an update runs, **Stop After Active Installs**. |
| **⇧⌘A** | **Select All Visible** rows — only on **Updates**. |
| **⌥⌘I** | **Show Inspector** — opens or closes the details panel. |
| **⌘F** | **Find on This Screen** — focuses the search field on **Updates** (**Find an app**), **Logs**, **Uninstall** and **Inventory**; disabled on the other screens, which have none. |
| **⇧⌘F** | **Find in inventory** — goes to **Inventory** and focuses its search field, from any screen. |
| **⌘1** to **⌘7** | Go to a section of the sidebar. |

### When something fails

On **Updates**, during an update run and on **Undo updates**, every error banner says what to do
next and has a button for it. Most of them are **Show in Logs**, which opens **Logs** with the
entry that explains the failure; a permission
failure leads with the permission instead (for example **macOS needs your permission**, with
**Open privacy settings**) and never sends you to Logs for it. When a banner names many apps or
packages it shows the first few and a **Show All** button that expands the rest; a new banner
replacing an old one starts collapsed again. The red banners on **To Homebrew** that report a failed duplicate removal also have **Show in
Logs**. The other error banners on **To Homebrew**, and those on **Inventory**, **Cleanup** and
**Uninstall**, name the failure but have no button.

### Skip or pin updates

Use the **⋯** menu on a Homebrew, App Store or npm row to (rows the developer finishes have
the same choices in the context menu — right-click the row):

- **Don't update** an app — *"don't update Zoom"*.
- **Skip this version** — hide just that version; the next one is shown.
- **Pin version…** — *"pin Parallels to 18"*; only updates up to that ceiling are shown.

**Don't update** and **Skip this version** hide the row at once, and an **Undo** toast stays
for 8 seconds — one click takes the change back. VoiceOver reads the toast out, and while
VoiceOver is on it stays until you close it. **Pin version…** shows no toast; it hides the row
when the offered version is above the pin. Any time, the line **"Hidden by your rules: N ·
Show"** under the list opens the rules, where **Restore** removes any of them. A restored row
comes back to the list, never into the queue.

Manage these rules any time from the **Settings** window (**⌘,** → **Checking & Background** →
**Paused updates**); they persist across launches and the menu-bar badge honours them too. After
an undo, Wega pins the restored version and the message names this card as the place to lift
the pin.

---

### Docker Desktop

Docker updates appear in their own section. **Open Docker Desktop** opens the installed
app; choose **Check for updates** in Docker's menu. Opening the app only starts tracking:
use **Check this app** afterward to verify the offered version on disk. That check does
not prove the engine is running. If Wega cannot resolve the installation path, the row
explains why an action is unavailable.

**Use Homebrew…** is a separate choice with a confirmation dialog. It may interrupt
running containers: Wega first asks Docker Desktop to stop through its bundled CLI and
checks that its application processes exited. Unsupported shutdown, a timeout, cancellation
or an uncertain result postpones replacement. Wega repeats this check at retry and restore
boundaries. Docker is excluded from the queue's **Update** button and unattended
updates, even if it was previously allowed in background settings.

After a successful Homebrew replacement, the restart offer is optional. Only your click
starts Docker and waits for the local engine. An engine timeout leaves the restart action
available and does not rewrite the installation result as a success or failure.

The rollback shield and **Undo update** protect **only the `.app` bundle**. They do not
back up or restore Docker settings, VM disks, images, containers or volumes, and cannot
promise compatibility with data migrated by a newer Docker version. Use Docker's own
[backup and restore guidance](https://docs.docker.com/desktop/settings-and-maintenance/backup-and-restore/)
for that data. Wega neither runs a factory reset nor launches Docker as an automatic smoke
test, including when its application bundle was renamed.

## 4. Diagnostics & troubleshooting

### The Logs tab

Every scan, source response, install result and error is recorded in the **Logs** tab
(sidebar), newest first. You can:

- filter by severity (**All / Warnings+ / Errors only**),
- search the text — including the extra failure detail behind a disclosure arrow, not just
  the visible line,
- copy entries to the clipboard (**not redacted** — see the warning below),
- **Reveal in Finder** the underlying log file, or
- **Export diagnostics** — the whole troubleshooting package in one file (below). Wega then
  says how it went in a line under the toolbar: **"Diagnostics saved."** with **Show in
  Finder**, or the reason it failed with a hint to try again. Cancelling the save panel
  shows nothing.

> **"Kopiuj" hands over the raw text.** It copies the visible entries exactly as they are
> written to `wega.log`: full filesystem paths, URL query strings, and the raw `stderr` of
> whatever command failed. That is deliberate — it is the shortcut for reading your own log
> in your own editor. **"Zgłoś błąd…"** and **"Eksportuj diagnostykę"** are the two paths
> that redact, because they are the ones meant to leave your computer. So read what you
> pasted before it goes into an issue tracker, a chat or an e-mail.

The log also lives on disk at
`~/Library/Logs/WegaMacUpdater/wega.log` (it rotates to `wega.log.1` past ~5 MB). When a
scan couldn't reach a source and the Updates screen shows a *"the list may be incomplete"*
warning, its button jumps straight here, pre-filtered to errors — so you land on the cause,
not just a summary.

### Reporting a bug

Some log entries carry extra detail behind a disclosure arrow — the command that ran, its
exit code, and the tail of `stderr`. To turn one or more of them into a bug report:

1. Open the **Logs** tab. If you know roughly when it happened, filter to **Errors only**
   to find it faster.
2. Select the entries that describe the problem — ⌘-click adds one, ⇧-click a range.
   Expand any disclosure arrow first if you want to see the extra detail before reporting.
3. Click **"Zgłoś błąd…"** (Report a problem…) in the toolbar. It works with nothing
   selected too; then the report carries only the environment context. **Zgłoś błąd** (Report
   a bug) on **Settings → General** opens the same sheet.
4. Describe briefly what you were doing when it happened — optional, but it helps.
5. Pick a channel: **"Wyślij e-mailem"** (Send by e-mail) or **"Zgłoś na GitHubie"** (Report
   on GitHub). The preview below switches to match.
6. Read the preview. It is exactly the text that will leave your computer, redacted the
   same way **Export diagnostics** is (below): paths, URL query strings, credentials,
   e-mail addresses and account names are replaced with placeholders.
7. Click **"Otwórz szkic e-maila"** (Open Email Draft) or **"Otwórz zgłoszenie na GitHubie"**
   (Open Issue on GitHub), whichever the channel is. Wega opens your mail app or a prefilled
   GitHub issue form — it never sends the report itself; you still have to press send there.

Selecting a lot of entries can push the report past the channel's size limit (e-mail and
GitHub allow different amounts); when that happens the oldest selected entries are dropped
and the preview says so plainly. A very long description can overflow the limit all by
itself — e-mail is the tighter of the two — and then it is shortened as well, after every
entry has already been dropped, with a visible `[truncated — …]` note where it was cut.
Both are visible in the preview before you send anything: the report is kept inside the
limit rather than handed to a mail client that would quietly cut it off mid-word. Because a `mailto:` link cannot carry attachments in any
mail client, this flow only ever carries the entries you selected — for the full log files
and environment report, use **"Eksportuj diagnostykę"** in the same toolbar instead. If
your Mac has no app that can open the channel you picked, the window falls back to a
copyable subject and body, plus — for e-mail, the recipient address; for GitHub, the
issue-page link — so the report is never a dead end.

### Settings, tab by tab

**Settings** (**⌘,**) has five tabs, so each setting has one place:

| Tab | What lives there |
| --- | --- |
| **General** | The app card (version, **Check for Wega updates**, **Report a bug**), **Interface language**, **Launch at login**, **Notifications**. |
| **Checking & Background** | **Paused updates** (your **Don't update**, **Skip this version** and pin rules), **Background update permissions**, **Scan directories**, and **Update conditions** (the free-space, network, battery and temperature checks before a download). |
| **Permissions & Privacy** | **What Wega does**, the **Wega helper** and **Touch ID for administrator commands**. |
| **Cleanup** | **Project folders** and the **Files and Folders map** Cleanup uses. |
| **Advanced** | **Post-update launch test**, **Crash reporting**, **Application catalog**, **GitHub token (optional)**, **System diagnostics** (including **Export diagnostics**), **Environment** and **External tools**. |

A button that changes something shows its result right under it, on its own card, since
Settings has no Wega to say it. Anything elsewhere in Wega that needs a setting — the
readiness card's **Enable Touch ID**, a helper message, the note after an undo — opens Settings
on the tab and card it means.

**What Wega does** sits at the top of **Permissions & Privacy**. It has three sections.
**Permissions** explains each permission in the same three things: why Wega asks, what
happens without it, and how to take it back — the Wega helper, Touch ID for administrator
commands, App Management (with its current state) and Full Disk Access (needed only by
Cleanup's Files and Folders map). **Connections** says that checking for updates installs and
removes nothing (the exception is apps you allowed to update in the background), that Wega
sends nothing about you — no telemetry and no analytics — and which services it talks to;
**Show Fixed Addresses** lists the fixed hosts, and a line below says the rest: the update
addresses stored in your installed apps, the npm registry and App Store servers.
**Local data and reports** says logs, the last scan result and pre-update copies (kept up to 7
days) stay on this Mac, and that you can review a problem report before it opens e-mail or
GitHub.

### The Wega helper

The helper is an **optional** component. Without it, everything in this guide still works;
with it, Wega can finish a few things that need administrator rights without asking you to
type a password. It runs as root and can do only four things: install a verified Wega
package, turn Touch ID for `sudo` on or off, restore an app's pre-update copy, and move a
root-owned app to the Trash. It checks on every connection that Wega is signed with a
Developer ID signature from the same developer. The helper stops by itself after a minute
with no connection and no work in progress (an installation in the background counts as work);
macOS starts it again from the installed Wega for the next request, so after you update Wega
the new helper runs within about a minute of idle. A helper from before this change keeps
running until you restart your Mac or reinstall the helper.

To switch it on, open **Settings** (**⌘,**) → **Permissions & Privacy** and use the **Wega
helper** card: **Install Helper**. If macOS asks for approval, the card shows **Open Settings → Login
Items** and **Check again**; **Remove Helper** switches it off again. On the Updates
screen, **What does the helper do?** in the readiness card shows the same explanation.

### Touch ID for administrator commands

Some cask updates run `sudo`. With Touch ID turned on for `sudo`, those prompts show the
system Touch ID sheet instead of asking for a password. It applies to **all** of `sudo` on
your Mac, in Terminal too, not only to Wega. Turn it on with **Use Touch ID Instead of Your Admin Password** on
the **Touch ID for administrator commands** card (**Settings → Permissions & Privacy**); it
needs administrator rights once, to write `/etc/pam.d/sudo_local`. With the helper installed,
Wega does that for you, and only an administrator signed in at this Mac can ask for it. The
helper checks `/etc/pam.d`, `sudo_local` and Apple's `sudo_local.template` first, and changes
nothing when one of them can be changed by someone other than root, is not a regular file,
is larger than 64 KiB or is not plain text. It writes nothing when `sudo_local` already has
the line, and reads the file again afterwards; the card shows success only when that file does
have it. Each refusal is explained on the card, and after a refusal the card does not offer the
Terminal command, since that command goes through `sudo` too. When the helper is missing, or
out of date for turning Touch ID on (it needs protocol 8), the card shows a one-line command to copy
(**Copy command**) or to run in Terminal (**Open in Terminal**). It runs `/usr/bin/sudo`, not
whatever `sudo` comes first on your `PATH`, and it refuses, changing nothing, an existing
`sudo_local` that is a link, is not a regular file, is not owned by root or can be written by
group or others; if the last line of the file has no line break, it ends that line before
adding the directive.

**When the card offers no command and no button.** The card then names the problem, says to
repair it from recoveryOS and not to type a password into `sudo` until then, even when Wega
asks for one during an update, because `sudo` reads these settings before it asks for anything.
That happens when `sudo_local` is not a regular file, when `sudo_local` or `/etc/pam.d` can be
changed by someone other than root or looks different from what it should (whether Wega saw it
or the helper reported it), when someone other than root can change `/etc/pam.d/sudo`, and
when Wega cannot establish that these settings are safe. The repair steps are in
[Turning off Touch ID for sudo](#turning-off-touch-id-for-sudo) below.

To turn it off again, use **Turn Off Touch ID for sudo** on the same card; it appears when the
Wega helper is installed and up to date. If the helper is missing or out of date, the card shows
a command to copy (**Copy command**) or run in Terminal (**Open in Terminal**), next to the link to
the manual steps, but only when Touch ID is on, the settings `sudo` reads are safe, no later
policy file would take over, and Wega's own read of `sudo_local` shows the exact directive can
be removed. The command runs through `/usr/bin/sudo` and removes only that line. It changes
nothing, and says why, when the file has a backslash, other settings, a NUL byte or text that is not
UTF-8, is too large, or when a later policy file or a linked `/usr/local` directory exists;
under the command the card warns when a directory on the `/usr/local` chain can be changed by
someone other than root. **Check again** reads the state anew. When the command is not shown,
the card says what Wega found, or, without the helper, that you can turn it off by hand. If the
helper is out of date, the card says so and asks you to remove and reinstall it or restart your
Mac; a helper from before protocol 8 can still turn Touch ID off, restore an app, move an app
to the Trash and finish a self-update, and only turning Touch ID on needs the restart or the
reinstall. **What Wega does** links to
[Turning off Touch ID for sudo](#turning-off-touch-id-for-sudo) below.

### Settings diagnostics

**Settings → Advanced** shows live diagnostics: the **System diagnostics** card lists the
Homebrew and `mas` versions and the **Environment** card the macOS version and CPU
architecture — the first things to check if a source behaves oddly. The **App Management**
permission and the Wega helper's status are on **Permissions & Privacy**. The App
Management state is a preflight (see below): it reads granted, denied or not yet known, and
**What Wega does** offers **Open privacy settings** when it is denied. It is an indication, not a
verdict — an upgrade that actually hits the refusal has the last word.
**Advanced** also has an **Application catalog** card that refreshes Wega's list of
supported apps on demand (it also refreshes on launch); a fetched update applies on the
next launch.

When a newer Wega is available, the same window lists **every release since the one you
have** — not just the latest — so three versions behind reads as three change-lists, not
one. Each is collapsed to its version and date; expand any to read its notes. If GitHub
can't be reached, it says so plainly instead of showing nothing — either way, this never
holds up the update itself.

Wega always downloads the **`.pkg`** when a release publishes one, and falls back to the
`.dmg` only when it does not. That is a security choice, not a convenience one: the `.pkg`
and the fallback DMG are both checked against Wega's developer certificate. What
changes when the privileged helper is switched on is only *who finishes the job* — with the
helper, Wega installs it for you and then asks you to restart; without it, the same file is
handed to you to run yourself. A release that publishes neither offers no update button at
all rather than something Wega cannot verify. Before opening or installing a package, Wega
checks its product identity, promised version and signed app payload. A helper installation
is reported as successful only after checking the expected app and version on disk.

### When a self-update cannot be confirmed

If a self-update loses contact with the helper, **Settings → General** shows **Installation completion
is unconfirmed**. The installer may still be running. Wega keeps further changes blocked,
including after Wega is closed and opened again. Use **Check installation status** to query
the same operation; this does not start another installer. A confirmed terminal result
releases the block. If the helper itself restarted, its previous installer cannot safely
be assumed to have stopped: inspect **Logs**, and restart macOS before checking the state
again if completion cannot be established. Wega does not kill the installer on a timeout.
This recovery path requires helper protocol 6 or later; after replacing an older Wega build,
update and re-register its bundled helper.

### Multiple installations

Manually detected update rows show the installed path. Separate copies of the same app
are checked independently and can have separate ignore/pin policies. If several copies
match one Homebrew cask, only the resolved Homebrew installation keeps that cask action;
other copies use their vendor's update source when one is available.

### Sparkle versions

Sparkle checks compare the app's build number (`CFBundleVersion`) with the feed's
`sparkle:version`. The visible version is a separate label: for example, `1.0 (101)`
can be newer than `1.0 (100)`. Release notes retain those builds separately and use
the same ordering. Wega accepts both XML elements and enclosure attributes, including
feeds that publish a build without a short version when the local app also exposes its build.
Without a local build, only explicit short versions are comparable; a build-only feed leaves
the check unconfirmed. ChatGPT's dedicated appcast checker
uses the same rules. Build comparisons support dotted numeric identifiers. Non-numeric
builds and app-specific custom comparators are not inferred; an unparseable comparison
is reported as a failed check.

### Export diagnostics

**Settings → Advanced → System diagnostics → Export diagnostics** (also in the **Logs** toolbar)
saves a single `.zip` with everything a bug report needs, so filing one never means
collecting it by hand:

| In the zip | What it holds |
| --- | --- |
| `report.txt` | App version and build, macOS version and CPU, detected package managers and their versions, Wega helper status and version, schedule status, the last scan's result per source, free disk space and the signature state. |
| `update-history.txt` | The last 40 upgrade runs, item by item: update → validation → rollback, including which apps were rolled back and where a developer's Team ID changed. |
| `logs/wega.log`, `logs/wega.log.1` | **Both** log files — the current one and the rotated one. |
| `logs/trace-<run-id>.jsonl` | Persistent event traces for update operations: stages, Wega log messages, command output and exit results, HTTP attempts and observed vendor-check outcomes, correlated by run and process identifiers. |
| `logs/trace-manifest.json` | Trace retention limits, incomplete runs, truncation and recording/read failures, so missing evidence is visible. |

Traces are stored locally in `~/Library/Logs/WegaMacUpdater/traces`. Each run is limited
to 8 MiB; command output stops at 75% of that budget to leave room for later stage and
completion events. Each process stream (stdout and stderr separately) is also capped
at 2 MiB after redaction. Capture waits for complete lines before redaction, with a
64 KiB pending-line cap; an unfinished final line is redacted at EOF. Overlong lines
and output beyond the limits stop trace capture for that stream and produce explicit
omission markers and counters; the command and its live output continue unchanged.
The trace does not claim to contain the complete stream. Retention keeps up to 50 run
files, 14 days and 64 MiB in total.
Active runs are preserved while retention removes older files, so these totals can be
temporarily exceeded. Truncation and failures are reported in the export manifest.

The trace records what Wega and the commands it starts can observe. A run without a
completion event is incomplete evidence, not proof of a successful update. HTTP events
exclude request/response bodies, headers, URL credentials and query parameters. The
export does not collect Docker daemon logs or other applications' private logs, and it
cannot by itself establish the internal cause of a vendor updater's crash.

Two things about this file are deliberate:

- **It is redacted.** Filesystem paths, URL query strings, credentials (API keys, bearer
  tokens, `Authorization` headers, private keys), e-mail addresses and your account names
  are replaced with `[path]`, `[query]`, `[secret]`, `[email]` and `[user]` before anything
  is written. The failure itself survives; the identity behind it does not. Team ID values
  are not exported either — the history records *that* a developer signature changed, not who.
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
  runs — so without it `brew` can fail with `ditto: /Applications/X.app: Operation not
  permitted` or an explicit ownership error saying the terminal does not have App
  Management permissions (for example, when updating Parallels Desktop). Wega recognizes
  both refusals and shows the permission banner. Click **Open privacy settings** on the
  banner (or **Open privacy settings** in **Settings → Permissions & Privacy → What Wega does**), enable **Wega** under **Privacy & Security → App
  Management**, then run the update again. If macOS attributes the operation to a terminal
  used to launch Wega, enable that terminal instead. `sudo` does not bypass this permission.
  Until it is granted, background updates pause for 24 hours at a time instead of retrying
  — and failing — on every scheduled check.
- **An incomplete scan banner.** If a scan finished but some sources stayed silent, Wega
  marks the list as partial rather than passing it off as complete. Open **Logs** (filtered
  to errors) to see which source failed.
  When manual checks find no updates because sources failed, the failure banner names the
  affected sources and apps. Temporary network failures and a failed check for Wega itself
  count too. Older cached scans retain their lists but stay unconfirmed until refreshed;
  saving or reopening them does not make them complete.
### Crash reporting (off by default)

The **Crash reporting** card (**Settings → Advanced**) can collect Wega's own crash and hang reports, so
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

### Uninstalling Wega

Wega is a normal app, so removing it is a few manual steps. Nothing here is automatic, and
Wega does not delete anything for you: you stay in control of every command.

1. **Turn off Launch at login.** Settings → **General** → **Launch at login**.
2. **Remove the helper**, if you installed it. Settings → **Permissions & Privacy** →
   **Wega helper** → **Remove Helper**.
3. **Turn off Touch ID for `sudo`** (optional), if Wega turned it on. Use **Turn Off Touch ID
   for sudo** on the Touch ID card, or follow the manual steps in
   [Turning off Touch ID for sudo](#turning-off-touch-id-for-sudo) below. Either also works on
   its own, while Wega stays installed.
4. **Quit Wega.** Use **Quit Wega** in the menu-bar menu. Closing the window does not quit the
   app.
5. **Move `WegaMacUpdater.app` to the Trash.**

Steps 1 to 5 remove the app. What follows is optional, and each item is separate. Deleting
the copies Wega keeps means **you can no longer undo an update she made**, so skip that
one if you might still need it.

- `~/Library/Application Support/WegaMacUpdater/` holds, among other files, `update-operations/`
  (the copies of apps made before each update, used by Undo update and the rollback shield)
  and `last-scan.json` (the last scan result).
- `~/Library/Logs/WegaMacUpdater/` holds the logs.
- `~/Library/Caches/WegaMacUpdater/`, `~/Library/Caches/com.wega.WegaMacUpdater/` and
  `~/Library/HTTPStorages/com.wega.WegaMacUpdater`, if they exist, are caches. The second one
  holds the downloaded Homebrew cask database (`casks-v4.json`) and Wega's copy of Adobe's
  product catalog (`adobe-products.json`); both are downloaded again when needed.
- Settings: `defaults delete com.wega.WegaMacUpdater`.
- A GitHub token, if you saved one, is in Keychain Access under the service
  `com.wega.WegaMacUpdater.github`. Delete it there, or in Terminal:
  `security delete-generic-password -s com.wega.WegaMacUpdater.github -a github-pat`.
- Root-owned files. The `.pkg` payload, which a self-update installs also for people who
  first installed from the DMG, and the helper leave folders owned by root. The helper's
  folders can exist even when no package was ever installed, for example after a DMG
  install that used the helper, so check each of them on its own:

  ```
  ls "/Library/Application Support/WegaMacUpdater"
  ls "/Library/Application Support/com.wega.WegaMacUpdater"
  ls "/var/db/com.wega.WegaMacUpdater"
  pkgutil --pkgs | grep com.wega.WegaMacUpdater
  ```

  Remove only the ones that exist, one by one in Terminal (each needs your password and
  cannot be undone):

  ```
  sudo rm -r "/Library/Application Support/WegaMacUpdater"
  sudo rm -r "/Library/Application Support/com.wega.WegaMacUpdater"
  sudo rm -r "/var/db/com.wega.WegaMacUpdater"
  ```

  The first holds the authorization helpers that the `.pkg` installs, the second the
  helper's staging folders, and the third the helper's installation record. A folder that
  does not exist is not an error you need to act on. Run the last command only if the
  `pkgutil` line above printed `com.wega.WegaMacUpdater`; it removes the package receipt:

  ```
  sudo pkgutil --forget com.wega.WegaMacUpdater
  ```

#### Turning off Touch ID for sudo

Wega turns on Touch ID for `sudo` by adding one line to `/etc/pam.d/sudo_local`. The main
`sudo` configuration includes that file, so a half-deleted line can break **every** `sudo`,
including the one you would need to repair it. The change applies to all of `sudo` on your Mac,
not only to Wega: afterwards every `sudo` prompt asks for your password again.

**In Wega.** With the Wega helper installed (and up to date), open **Settings → Permissions &
Privacy → Touch ID for administrator commands** and click **Turn Off Touch ID for sudo**. The
helper removes only the line `auth       sufficient     pam_tid.so` from
`/etc/pam.d/sudo_local` and leaves Apple's template in place. It swaps the new file in
atomically, checks it, and puts the old file back if anything goes wrong; no backup stays
behind unless something fails, including the last cleanup step. Then open a new Terminal
window and run `sudo -k; sudo true`; it should ask for your password. Wega will not touch the
file when it holds other settings, a line written differently, or anything else it did not
expect; it says so, and you use the manual steps below. Without the helper, or with one that is
out of date, the card can show a Terminal command that does the same removal; see above. If the card instead shows a red note
that someone other than root can change the file or directory, or that the file looks different
from what it should, read the repair advice below; that note can appear even
without the helper.

**By hand.** Follow these steps in this order.

1. Open a root shell with `sudo -s` and **keep it open until the end**.
2. Back up the file: `cp /etc/pam.d/sudo_local /etc/pam.d/sudo_local.bak`
3. Open `/etc/pam.d/sudo_local` (`nano /etc/pam.d/sudo_local`). Delete, or comment out with
   a leading `#`, only the line that reads exactly `auth       sufficient     pam_tid.so`.
   Apple's example line that starts with `#auth` stays as it is.
4. Check it in a **new** Terminal window: run `sudo -k; sudo true`. It should now ask for your
   password instead of Touch ID.
5. If that fails, restore the file from the root shell that is still open:
   `cp /etc/pam.d/sudo_local.bak /etc/pam.d/sudo_local`. Then close the shell with `exit`.
6. If it worked, close the root shell with `exit` as well. You may then delete the backup,
   `/etc/pam.d/sudo_local.bak`; it is no longer needed.

**When Wega refuses because someone other than root can change the file.** If the card says
that `/etc/pam.d/sudo_local` or the `/etc/pam.d` directory can be changed by someone other than
root, take it seriously: whoever can write there can get root without a password. Wega changed
nothing. Look first, as you, without `sudo`:

```
ls -leO@ /etc/pam.d/sudo_local
ls -ldeO@ /etc/pam.d
cat /etc/pam.d/sudo_local
```

Look for write permission for a group or for everyone, an owner other than `root`, an ACL entry
or a flag you did not set, and any line in the file that you did not add. Do not repair it by
typing your password into `sudo`: `sudo` reads that very file, so a tampered file is not a safe
place to type it, and the same goes for an `osascript` administrator prompt: use recoveryOS only.

*From recoveryOS.* Restart into recoveryOS, unlock your disk in Disk Utility first if it uses
FileVault and mount your Data volume, then open Terminal. There `/etc/pam.d` is recoveryOS's
own, not your Mac's; your files are under the mounted Data volume, for example
`/Volumes/Macintosh HD - Data/private/etc/pam.d/sudo_local` (the volume's name may differ):

```
chown root:wheel "/Volumes/Macintosh HD - Data/private/etc/pam.d/sudo_local"
chmod go-w "/Volumes/Macintosh HD - Data/private/etc/pam.d/sudo_local"
chmod -N "/Volumes/Macintosh HD - Data/private/etc/pam.d/sudo_local"
```

The last command removes the ACL. When the directory is the problem, only recoveryOS is safe:
run the same commands for the directory, `/Volumes/<name> - Data/private/etc/pam.d` (for example
`/Volumes/Macintosh HD - Data/private/etc/pam.d`), without the `-N` one, and check
`ls -ldeO@` on that path again afterwards.

**When Wega names another policy file or directory.** Wega also stops when, once its line is
gone, `sudo` would read another PAM file: `/etc/pam.conf`, `/usr/local/etc/pam.conf`,
`/usr/local/etc/pam.d/sudo_local` or `/usr/share/pam.d/sudo_local`. It also warns when any
existing directory on the chain `/usr/local`, `/usr/local/etc`, `/usr/local/etc/pam.d` can be
changed by someone other than root. Read the
file with `cat`; if you did not create it, treat it like the case above. Wega does not edit
those files.

**When the write and its restore both failed.** Wega names a file such as
`/etc/pam.d/.sudo_local.wega-swap-<UUID>` that holds the previous `sudo_local`. Inspect both
files with `cat /etc/pam.d/.sudo_local.wega-swap-<UUID>` and `cat /etc/pam.d/sudo_local` (use the
real name from the message; `ls -a /etc/pam.d` lists it). If `sudo_local` is damaged or missing,
put the saved one back with `mv /etc/pam.d/.sudo_local.wega-swap-<UUID> /etc/pam.d/sudo_local`,
under the same rule: from recoveryOS (with the Data volume's path
`/Volumes/<name> - Data/private/etc/pam.d/` in place of `/etc/pam.d/`), not with a password typed
into `sudo`.

**After "the file changed while I was working".** A `.sudo_local.wega-swap-*` file may be left
in `/etc/pam.d`. Check it the same way. Once `sudo_local` is confirmed correct, the leftover
file can be removed.

### Cleanup: what each action does

In **Cleanup**, the confirmation sheet for a finding says, under the question, what the action
does and whether Wega can take it back:

- **Moves to the Trash — you can restore it until you empty the Trash.** For the actions that
  trash files or folders.
- **Runs a Homebrew command — Wega can't undo it.** For the actions that run `brew`.
- **Only copies the command; nothing is removed now.** For the findings that hand you a
  command (for example `unlink`) to run yourself.

The confirm button is red. An action that removes nothing, such as one that only explains a
step or opens **Uninstall apps** with an app selected, shows no such line.

### Uninstalling apps

The **Uninstall** screen removes any app regardless of origin (casks via `brew uninstall
--cask`; App Store and manual apps to the Trash). The confirmation dialog defaults to the
safe **"App only"**; the irreversible **"App + leftovers"** (which also deletes
preferences, caches and Application Support) is never pre-selected. If a scan couldn't read
a source, the dialog warns that the target list may be incomplete before anything is
removed. **Right-click any app in the list** to show it in Finder, copy its path, or toggle
whether it's marked for removal.

For apps Homebrew doesn't manage, the dialog also lists **App leftovers** found in your home
folder: items Homebrew's zap list for the app's cask names, items stored under the app's
bundle identifier, and folders named after the app. Bundle-identifier items are ticked, and
so are Homebrew-list items when the app clearly matches that cask, the item is inside
`~/Library` and the item's name points to the app (its bundle identifier, its name or its
cask's name). A folder the list names for a whole vendor or for several apps (Microsoft's
folder for Word, Google's updater for Chrome) is marked "Homebrew list (shared folder?)" and
stays unticked, as do items from a cask matched only by name, anything outside `~/Library`
and folders found only by name; they are listed under **Probable — check before ticking**.
An item that another installed app still uses is shown unticked and marked "also used by",
and an item shared by two apps you remove together goes only when both are removed.
**Select all** ticks the main list only; **Deselect all** clears the whole list, probable
items included. Sizes appear a moment after the dialog opens (items in Containers and Group
Containers show "size unknown"). If the app list couldn't be read completely, nothing is
ticked by default. Ticked items go to the Trash, never a permanent delete; system-wide
folders are not touched.

An app owned by root, which the Trash will not take without a password, is removed by the
**Wega helper** when it is switched on (the row says so: it will be moved to the Trash without
a password). Without the helper, or when the helper is outdated or does not answer, the row
says what to do — turn it on in **Settings → Permissions & Privacy**, or remove it and install
it again — instead of asking for a password. The helper is reported as having removed the app
only when it confirms it; if it does not, the refreshed list shows whether the app is still in
`/Applications`.

---

Need something this guide doesn't cover? Open a
[discussion or issue](https://github.com/DominikSienkiewicz/WegaMacUpdater/issues) — but
for anything security-sensitive, use the private channel in [`SECURITY.md`](SECURITY.md)
instead of a public issue.
