# Changelog

All notable changes to **Wega Mac Updater** are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The version lives in exactly one place — `AppMetadata.version`
(`Sources/WegaHelperKit/AppMetadata.swift`); the release workflow refuses to publish
a tag whose version doesn't match it. `[Unreleased]` entries are written ahead of each
release; the release notes are approved at release time, and `scripts/release.sh` writes
them verbatim under the new version heading, so that step is never done by hand — see
[RELEASING.md](RELEASING.md).

## [Unreleased]

### Fixed
- **A rescan shows that it is running.** While a scan runs over results already on screen, the
  binary code Wega sniffs streams across the band behind her again, as it does on the first
  scan; with nothing to update it streams behind the *Everything up to date* heading. The rows
  stay uncovered. Increase Contrast leaves the stream out and Reduce Motion holds it still.

## [0.9.0] — 2026-11-21

Updates now run, check and finish in the band: the list stays readable the whole time, and a
run ends in a summary that puts every app in exactly one result. Touch ID for `sudo` can be
turned on and off safely from Settings, Wega asks for no administrator password while the
settings `sudo` reads cannot be trusted, and the root helper runs only from a root-owned copy
of Wega. Cleanup lets you choose which copy of a tool stays and shows what needs action first.

### Added
- **An update runs in the band.** While an update installs, the band says **Updating · since
  08:14**, names the stage (**Installing firefox — 3 of 7**, or **Installing packages — 3 of
  7** while several run at once), counts whole packages in a ring and holds **Stop After
  Active Installs**; the log opens by itself under the list, and **Show log** returns it after
  you close it. The list stays readable
  and locked, with a note in its header, and nothing covers it. Casks and npm packages say
  on their own row whether they are *waiting*, *installing…*, *installed, checking*, *failed*
  or *won't start*; Homebrew formulae and the App Store say *in progress* once on the group,
  and updates the vendor finishes say *with the vendor*.
- **The check after a run happens in place, and the run ends in a summary.** The post-run
  check no longer takes over the window: the band says **Checking the result** while the list
  stays on screen, locked. The result is then a summary in the band and the list instead of
  the "Updated N packages", "Update incomplete" and "Update stopped" banners: every app the
  run planned lands in exactly one result (updated, failed, rolled back, not confirmed, not
  started) with a one-line reason, **Undo** and **Trust the New Signature** where they apply,
  and the updates left to finish with the developer. A package counts as updated only after
  the check confirms it. **Close summary** (or the link to the remaining updates) returns to
  the normal list; a changed-publisher warning still unresolved at that point returns as the
  sticky banner, and a failed rollback keeps its red banner. An undo started from the summary
  rescans in place too.
- **Turn Touch ID for sudo off from Settings.** With the Wega helper installed, the Touch ID
  card has **Turn Off Touch ID for sudo**. The helper removes only the exact
  `auth       sufficient     pam_tid.so` directive from `/etc/pam.d/sudo_local`, whoever wrote it, swaps the new file in atomically, checks it and puts the old file
  back if anything fails. It refuses a file that someone other than root can change, and the guide
  says how to inspect and repair that safely. With an older helper the Touch ID card says it is
  out of date and asks you to reinstall it or restart your Mac, and can show the command that
  turns Touch ID off without the helper.
- **Turning Touch ID for sudo on is checked like turning it off.** Through the helper it now
  needs an administrator signed in at the Mac, and refuses an unsafe `/etc/pam.d`,
  `sudo_local` or, when there is no `sudo_local`, `sudo_local.template` (someone other than root can change it, it is not a
  regular file, it is over 64 KiB or it is not plain text) instead of replacing it with
  Apple's template as before. It writes nothing when `sudo_local` already has the line and
  checks the result before the card says it worked. The card explains each refusal and no
  longer offers the Terminal command after one; for an unsafe policy it says to repair it
  from recoveryOS. With a helper still running from an earlier Wega the card says it is out of
  date, and can offer the Terminal command instead, until you restart your Mac or reinstall the
  helper.
- **Turn Touch ID for sudo off without the helper.** When the helper is missing or out of date,
  the Touch ID card shows a command to copy (**Copy command**) or run in Terminal (**Open in
  Terminal**) next to the guide link, but only when Touch ID is on, the settings `sudo` reads
  are safe, no later policy file would take over and Wega's own read of `sudo_local` shows the
  exact directive can be removed. The command removes only that line and changes nothing, and
  says why, when the file has a backslash, other settings, a NUL byte or text that is not UTF-8,
  is too large, or when a later policy path or a linked `/usr/local` directory exists.
- **The helper exits when idle.** The helper now exits after a minute with no connection and
  no work in progress (a background installation counts as work), and macOS starts it again
  from the installed Wega for the next request, so after a Wega update the new helper runs
  within about a minute of idle. The app retries the version check once after a dropped
  connection.
- **Find an app on Updates.** **⌘F** shows one answer row above the list instead of
  narrowing it: where the app is on the list, what Inventory knows when it is not (up to
  date, no known source with **Report app ›** to suggest it for the catalog as in Inventory,
  the check failed, hidden by one of your rules with **Show Rules**, or not on this Mac), with **Show Rules** beside an answer about your rules and **Open Inventory**
  beside the others, and says when the Inventory read may have changed or was incomplete.
- **The menu knows when the window is checking.** While a check from the Wega window runs, the
  menu-bar menu says **Checking for updates in the Wega window…**, and its check button and
  the agent's own scheduled attempt wait.
- **A scan shows where it is, in the band.** While Wega checks, the band names the step
  (**Refreshing the Homebrew catalog…** first, then Homebrew, the App Store, npm and the
  vendors), counts the time the check has taken and the updates found so far, shows a ring
  and a chip per source, and once the vendors start counts them (**Vendors: 12 of 31 apps**).
  Wega sniffs throughout, and nothing covers the rows: they stay readable, and a note says
  selecting comes back when the scan finishes.
- **Undo a hidden update at once.** **Don't update** and **Skip this version** hide the row
  right away and show an **Undo** toast for 8 seconds; VoiceOver reads it, and with VoiceOver
  on it stays until you close it. The line **Hidden by your rules: N · Show** under the list
  opens your rules, where **Restore** takes one back to the list, never into the queue.
- **Choose which copy of a tool stays.** In Cleanup, a tool installed more than once now has a
  **keep** choice on each of its copies, so the copy you keep is no longer just the one first on
  `PATH`; the other copies offer their removal, and Wega remembers the choice for later scans.
  A copy that came with an app offers **Uninstall <app>…**, which opens Uninstall apps with
  that app selected. While `PATH` is only approximate, nothing is chosen for you. A link left
  dangling afterwards gets a copyable **`unlink`** (or **`sudo unlink`** outside your home) command.
- **Settings in five tabs, and a card that says what Wega does.** Settings is now **General**,
  **Checking & Background**, **Permissions & Privacy**, **Cleanup** and **Advanced**, so each
  setting has one place, and a button, a banner or a menu item that needs a setting opens its
  tab and card. The self-update, Wega helper and Touch ID cards show the result of their
  buttons under them. **What Wega does**
  tops **Permissions & Privacy**: why each permission is needed, what happens without it and
  how to take it back; that checking installs nothing, that nothing about you is sent and which
  fixed addresses Wega contacts (**Show Fixed Addresses**); and what stays on your Mac.
- **The menu-bar menu is specific.** Each app with an update is a row that opens the update in
  the window, with its versions and a **⚠︎** when its notes may describe a security fix; after
  the first 10 rows a line says **and N more apps**. The
  menu says **Checked yesterday, 21:14** and **Next attempt: today, 15:00, while Wega is running**,
  and the check button reads **Check and update in background (N)** when N apps are allowed to
  update in the background.
- **Inventory keeps its result.** It says when it was read (**Read today, 08:12**), marks the
  read **the list may have changed** after an update (one installed in the background too), a
  Cleanup removal, a move to Homebrew or an uninstall, also when the window was closed meanwhile,
  and no longer reads the disk again every time you open it. **Refresh Inventory**
  only reads; **Check for updates** runs the same scan as **⌘R** and takes you to Updates. A
  filter that hides every app says so and offers **Clear Filters**.
- **Rows you can use from the keyboard and with VoiceOver.** Each group of rows is one Tab stop,
  **↑** and **↓** move within it, **Space** queues the row and **Return** shows its details;
  VoiceOver reads a row as one sentence with its actions. A row shows the app's name with the
  Homebrew token under it.
- **Shortcuts for finding and selecting.** **⌘F** finds on Updates, Logs, Uninstall, Inventory
  and Cleanup, **⇧⌘F** finds in Inventory, **⇧⌘A** selects every visible row on Updates, **⌥⌘I**
  shows or hides the details panel, **⌘.** cancels a scan as well as stopping an update, and
  **Help → Wega User Guide** opens the guide.
- **How to remove Wega, and where to look for a missing app.** The guide has the steps to
  remove Wega and every root-owned leftover, and a safe way to turn Touch ID for `sudo` off
  again; Uninstall and the Touch ID card link to them. Under the update list, **Can't see an
  app?** opens Inventory, since a missing app is not proof it is up to date.

### Changed
- **Shorter, plainer wording.** The note for a scan that could not reach every source is
  shorter in Polish (**skan niepełny**, now also in Inventory, the menu bar and the VoiceOver
  announcement) and reads **check incomplete** in English, the group that waits for you is
  **Needs your action**, the fourth source is **vendors**, and the messages about a changed
  signature now say **developer signature** instead of Team ID.
- **The band names your queue.** It reads **4 queued · 2 to finish with the developer**
  (the second half only while something is queued, counted in the category on screen), says
  how far an undo reaches (**Undo: 3 of 4**, or **Checking undo availability** while a cask is
  still being checked; a cask Wega could not check counts as not covered), and its button is
  **Update N**, or **Nothing selected** when the queue is empty.
- **Every counted noun takes its plural form.** Polish and English texts that count apps,
  packages, casks and leftovers now use the right form for 1, 2, 5, 12 and 22.
- **Report a problem names what it opens.** **Zgłoś błąd…** in Logs works without selecting
  entries, the buttons read **Open Email Draft** and **Open Issue on GitHub**, **Zgłoś błąd**
  in Settings opens the same report sheet, and the sheet says it replaced the sensitive data
  it found. **Eksportuj diagnostykę** says whether the zip was saved (with **Show in Finder**)
  or why it was not.
- **Wega speaks plainly about checks and moves.** Scan lines say what is being looked at, and
  the sheet before moving an app to Homebrew asks **Move <app> to Homebrew?**, names the
  backup Wega makes and says it is restored if the new version fails its signature check.
- **A calmer tone when something goes wrong.** Errors are first-person and plain (**I couldn't
  install <app>**), Wega puts her ball down while an error, an update run or a confirmation is
  open, and the Cleanup scan has her sniffing like the others.
- **The scan button only where a scan shows.** **Check now** appears only on Updates, To
  Homebrew and Undo updates; **⌘R** still works everywhere. The npm card in Inventory is a
  counter, no longer a button that did nothing.
- **"May fix security issues" instead of "urgent".** The band counts the updates that may
  fix security issues, Wega's card says that their release notes mention security, and the
  inspector shows which words were found, because the match is a guess from the notes'
  wording.
- **A readiness card before the first update.** After the first result, a card says which
  permissions the first update may need (replacing apps in /Applications, an administrator
  password), lets you check them or turn on Touch ID, and asks once about notifications.
- **The .pkg is the recommended download.** The user guide and the release notes explain
  that the .dmg cannot ask for an administrator password.
- **A young Homebrew catalog is kept at launch.** Opening Wega less than 30 minutes after the
  last refresh of Homebrew's catalog no longer runs `brew update` again, and the band says
  **Homebrew catalog from 12 min ago**. **Check now** and **⌘R** always refresh it.
- **One name for each thing.** The optional component is **Wega helper** (**Install Helper**,
  **Remove Helper**), ignored and pinned updates are **Paused updates**, the Homebrew screen is
  **To Homebrew**, apps and tools from Homebrew are **Homebrew apps** and **Homebrew tools**, a
  changed developer signature is a **signature** that you can **Trust the New Signature**
  for, and the copy made before an update is a backup. **Update conditions** replaces the
  resource gate and **Show in Logs** replaces the old log links.
- **Cleanup says what each action does.** Under the question, the confirmation says whether the
  action moves to the Trash and can be restored, runs a Homebrew command Wega cannot undo, or only
  copies a command, and its confirm button is red.
- **Cleanup shows what needs action first.** Each section lists the tools that need
  action at the top and folds the rest into **No action**, with tools that
  share a source and folder gathered into one line. The header reads **N to do**,
  and a search field (**⌘F**) finds a tool or path across the whole report.

### Fixed
- **Inventory knows about installs and undos.** It marks its read **the list may have
  changed** after an install from the list through Homebrew, a reinstall and an undo of an
  update too, so it no longer shows a stale list as current.
- **Migration errors lead to the log.** The red banners for a failed duplicate removal on
  To Homebrew now have **Show in Logs**.
- **An incomplete check no longer says everything is up to date.** If some sources did not
  answer, the menu-bar icon, its menu, Wega's card and VoiceOver now say the check was
  incomplete instead of "all up to date", and Wega's cheerful line appears only after a
  complete check.
- **Undo results are visible.** The Undo screen now shows whether an undo worked or why it
  could not be done, and keeps saying that the version is pinned. Its empty state no longer
  promises a copy after every update: only supported Homebrew app updates keep one, for 7
  days, and never the app's data.
- **The plan and postponement messages say only what has happened, in your language.** The
  plan no longer claims a checksum was verified before anything is downloaded, the reasons
  an update was postponed follow the interface language, and the administrator-password
  prompt follows the system language.
- **Uninstall and restart are safer.** The destructive button in Uninstall is no longer the
  one Return presses, and its footer counts the apps and the leftovers you selected and says
  where each goes. **Restart** after an update first asks the app to quit and offers **Force
  quit** only when it refuses, warning that unsaved work may be lost; Return never forces it,
  and Escape leaves the app open.
- **Notifications can be changed again.** Answering **Keep Notifications Off** is no longer
  final: **Settings → General → Notifications** switches them on or off. Clicking a notification opens
  the window with the new updates already listed, even if it was closed, and brings an open
  window forward instead of opening a second one. The texts use the right plural forms and
  name the apps that are new first.
- **Installing from the .dmg no longer fails silently on password prompts.** Wega says when
  this copy cannot ask for an administrator password and which update will not install, and
  recommends the .pkg.
- **Updates that run now show everywhere.** The sidebar, VoiceOver and the menu-bar dropdown
  show "Updating 2 of 5" instead of "Checking", and the dropdown has a stop button even
  with the window closed. The button now reads **Stop After Active Installs**, which is what
  it does: installs already running finish, nothing new starts. Once clicked, the dropdown
  says so too.
- **VoiceOver announces when work ends.** Finished scans, finished or stopped update runs and
  uninstalls that removed nothing are announced, and the list stays readable during a run.
- **Fewer false alarms on release notes.** A flagged term now has to start a word, so
  ordinary words that merely contain one no longer put an update among the urgent ones or
  give it the red warning label.
- **The list stays readable while Wega checks again.** During **Check now** or **⌘R** the
  rows used to vanish behind a frosted layer, so the screen looked empty and frozen. They
  now stay visible and readable while the check reports itself in the band above the list.
- **The list stays readable while updates install.** During an update run the rows used to
  vanish behind the same frosted layer. They now stay visible and locked, and the run is
  reported in the band above them.
- **Errors say what to do next.** On Updates, during an update run and on Undo updates, every
  error banner has a button — mostly **Show in Logs** — and a permission failure leads with the
  permission instead of sending you to Logs. A banner naming many apps shows the first few and
  **Show All**. A failed backup before an update says to check free disk space. The two
  duplicate-removal banners on To Homebrew have **Show in Logs** too; its other error banners and
  those on Inventory, Cleanup and Uninstall still name the failure without a button.
- **Reduce Transparency no longer hides the rows an update is installing.** Nothing is drawn
  over the list any more; it stays locked and its header says why. State texts are easier to
  read, and the close buttons of banners and the log are larger targets.
- **Cleanup no longer offers to uninstall your version manager.** A mise, asdf or pyenv shim
  (such as `~/.local/share/mise/shims/node`) runs the version the manager selects, but Cleanup
  took it for one more copy of the tool: each mise shim offered **Uninstall…**, which runs
  `brew uninstall mise`, and a pyenv or asdf shim offered **Move to Trash…**. A shim is now
  *expected* and offers nothing, and when a shim comes first on `PATH`, the copies behind it
  offer nothing either, since the manager may fall back to them as its `system` version. The
  **Reclaimable** total counts a removal that several copies share once, so 36 mise shims no
  longer add up to 8.8 GB.

### Security
- **The Wega helper only from a copy of Wega that belongs to root.** The helper runs as root, and
  macOS starts it from Wega's app bundle. A copy dragged from the `.dmg` belongs to your account,
  so any program running as you could replace the helper in it. Wega now installs and uses the
  helper only when it runs directly from `/Applications` and the bundle, `Contents`,
  `Contents/MacOS`, the helper, `Contents/Library`, `Contents/Library/LaunchDaemons` and the
  helper's launchd file all belong to root, lie on the volume of `/Applications`, which must
  honour ownership (no file system mounted into the bundle), and nobody else can change them,
  which is how the `.pkg` installs it. Otherwise the helper card shows **Unavailable**, says why and how to install
  from the `.pkg` (**Open Releases Page**); restoring an app, Wega's own update and Touch ID for
  sudo work as without the helper, and Uninstall says a root-owned app needs Wega from the `.pkg`.
  When such a copy finds an installation whose result is unknown, changes stay blocked and
  Settings says to quit it and open the Wega installed from the `.pkg` in `/Applications`, which
  can check that installation. A helper registered earlier from such a copy is removed when
  Wega starts, with a banner, unless another copy of Wega on this Mac passes the check. The helper
  checks the bundle it was started from as well and refuses every connection when it fails. The
  package build checks that it installs such a bundle, and the diagnostics report shows the
  result. This is helper protocol v9: Wega sends every action only to a v9 helper, so a helper
  still running from an earlier Wega (released Wega has v6, or v5 up to 0.6.0) is out of date for restoring
  apps, self-updates through the helper, the Trash and Touch ID until you restart your Mac or
  remove and reinstall the helper; a self-update a v6 helper started is still settled through it.
- **No sudo route while the settings sudo reads are unsafe or unproven.** When `sudo_local` is
  not a regular file, `sudo_local` or `/etc/pam.d` can be changed by someone other than root
  (whether Wega saw it or the helper reported it), `/etc/pam.d/sudo` is unsafe, or Wega cannot
  establish that they are safe, the Touch ID card shows no button and no command and says to
  repair it from recoveryOS and to type no password into `sudo` meanwhile. The guide no longer
  offers an `osascript` administrator-prompt repair; recoveryOS is the only route.
- **Wega asks for no administrator password while those settings cannot be trusted.** `sudo`
  reads them before it asks, so a module someone added there could keep the password. Whenever
  the Touch ID card shows its recoveryOS note, an update run starts none of the casks that may
  ask for the password (a `pkg`, `installer` or `preflight` stanza, or one Wega knows nothing
  about yet): they take no part in the run's preparation, their rows say **skipping — may need a
  password**, the summary lists them under **Not started** with **Open Touch ID card**, and the
  list warns before the run which of them it will skip. The readiness card's password row is
  then never ticked, even with Touch ID on or the `.pkg` installed: it says Wega won't ask for
  the password until those settings are repaired and offers **Open Touch ID card**.
  An App Store update that stops where it
  would need `sudo` is not primed for it; the summary shows it under **Needs attention** as not
  finished, with the same button. Everything else updates as before. Wega checks right before
  the run and again before each such cask, so settings that turn unsafe during a run stop the
  prompts too. Behind that, the brew environment names no askpass and puts no `sudo -A` shim
  first, the shim runs `sudo -n` instead, and the askpass exits without showing a password field.
  With Touch ID for `sudo` off, a cask that still runs `sudo` on its own fails without a prompt;
  with it on, such a `sudo` may still show the Touch ID sheet, but never a password field. The
  failure banner then offers **Open Touch ID card** instead of **Enable Touch ID**.
- **The manual command to turn Touch ID on is safer.** It runs through `/usr/bin/sudo` in the C
  locale, refuses an existing `sudo_local` that is a link, is not a regular file, is not owned
  by root, is writable by group or others or has an ACL, refuses an unsafe `sudo_local.template`
  (a link, not root's, writable by group or others, or with an ACL; a missing one is fine), and ends an unterminated last line before adding
  the directive.
- **The helper and the app pin each other to a Developer ID signature.** Both XPC code
  requirements now demand a Developer ID certificate chain (the intermediate and leaf markers),
  besides the Team ID and the identifier, so a signature from the same team that is not
  Developer ID no longer qualifies. The release artifact check verifies the signed app and helper
  against both requirements.
- **The publisher check after an update and Trust the New Signature need a valid signature.** A
  developer's Team ID counts there only when a Developer ID certificate carries it and the whole
  app checks out against it, in every architecture and in its nested code. An app changed after
  it was signed, one signed ad hoc with another developer's Team ID, or one signed with a team
  member's development certificate, reads as having no Team ID: when Wega knows the app's
  developer, the update is rolled back, and Trust the New
  Signature changes nothing. The check before an update still reads the Team ID the signature
  names, so an app whose own signature broke can still be updated.
- **Wega checks its own update in full.** A downloaded `.dmg` and the app inside it, the app
  inside a downloaded `.pkg`, the app the installer leaves in `/Applications`, and the askpass
  helpers must carry Wega's Developer ID signature, and every architecture and nested program
  must match it, the root helper included. Before, the check read only the slice this Mac runs,
  did not check the contents of the nested programs, and also accepted the same team's
  development certificate. The release check now runs the same check on the signed app,
  askpass, the sudo shim, the `.dmg`, and the app and both askpass helpers inside the `.pkg`,
  so a release that Wega would refuse to install is never published.

## [0.8.0] — 2026-11-20

A new Updates screen. A band at the top says when Wega last looked, how much she found and
what she will update, and one round button starts it. The list is grouped by how urgent each
update is, checks and update runs no longer take the list away, and Wega moves into a card of
her own at the bottom of the sidebar, where now and then she chases a ball.

### Added
- **Wega chases her ball.** Now and then a ball rolls past her card in the sidebar; she
  glances after it, runs off and comes back carrying it. On the "everything up to date"
  screen the full Wega does the same chase as her first trick. Off under Reduce motion.

### Changed
- **A band at the top of Updates.** Once a scan has found updates, the band says when Wega
  last checked and which of Homebrew, the App Store, npm and the vendors answered, how many
  updates and urgent items there are, and what she makes of them. It also shows what is
  queued and how much of it can be undone automatically. **Show exactly what I will do**
  opens the dry-run plan as a sheet, and a round **Update N** button starts the run.
  **Check now** is no longer styled as the main action.
- **Grouped by urgency.** Updates Wega flags from their release notes come first, then the
  apps and CLI tools she updates in one batch, then the ones the vendor or you finish. Group
  headers are numbered, every row says where its update comes from, and a row shows when
  automatic rollback cannot cover it. The grouping the Inventory window uses is one choice
  away under **Group**, and Wega remembers it.
- **A queue you can see.** Updates Wega will install wear a honey circle with a tick instead
  of a checkbox; updates the vendor or you finish wear a ↗ circle. **Select all** sits next
  to the categories above the list, and the row open in the inspector is filled lavender and
  outlined.
- **Categories in a scope bar.** The sidebar keeps a single Updates row, whose badge turns
  red while a flagged update waits. All, Apps, CLI tools and the updates Wega flags are a
  scope bar above the list, with counts. The toolbar loses its Settings gear (use ⌘, or the
  app menu), and the inspector toggle shows only on Updates.
- **Scans run in place.** **Check now** and **⌘R** keep the list on screen, stood down,
  while the band shows how far the check has got: Homebrew, the App Store, npm, then the
  vendors. Only the very first scan shows the full scanning scene.
- **A running update lives in the bottom bar.** Progress, the log and **Stop after this
  one** sit in a bar at the bottom of the list instead of a card in the middle of the
  screen; the list stays stood down behind a note until the run lands.
- **One row layout.** Manually updated apps line up with Homebrew rows: same icon column,
  version in the version column. Release notes open in the inspector instead of unfolding
  inside the list; notes a feed only links to are still fetched in the app.
- **Wega has a card at the bottom of the sidebar.** It shows her line for the current
  screen, her comment on a finished scan, when she last checked, and the one-time
  notification question. The status footer and the speech bubble over the list are gone.
- **One look for every notice.** The Homebrew invitation, result and error banners, the
  stale-cask offer and the missing-checksum warning share one shape; only their level
  (information, success, warning, urgent) changes the colour and symbol.
- **A new app icon.** The icon is Wega's new portrait; her animated portrait in the window
  and her silhouette in the menu bar match it.

### Fixed
- **Scans work wherever Wega was started from.** Every `brew`, `npm` and `mas` call, the
  Touch ID setup script and the relaunch after a self-update now start in `/`. Started from
  a folder that was later deleted, every check used to fail ("$PWD must be set",
  `uv_cwd ENOENT`). A launch from Finder or the Dock already started in `/`.
- **Long versions stay on one line.** A version like `6.6395.1,8fc566f7b97e…` or
  `26.1111.71704 (29030)` no longer wraps a row into several lines: the list shows the
  readable part, and the full version is in the tooltip and the inspector.
- **A Homebrew record of a vendor app that is gone or already up to date is not an update.**
  Logi Options+ or Cloudflare WARP left in Homebrew after the app is gone, or already at the
  version Homebrew offers, no longer shows up as an update, in the window or in the menu-bar
  count, nor twice. A vendor hand-off now closes on its own once a scan finds the app at the
  target version, or finds it gone.

## [0.7.1] — 2026-11-17

### Added
- **Porządki (⌘6): clean up after your tools.** A read-only scan that shows what is installed
  more than once and what can safely go:
  - **Duplicate commands on your `PATH`**, the usual cause of repeated "Files and Folders"
    prompts: old versions kept by native installers, Homebrew copies hidden by another
    install, copies managed by an app (shown, never offered for removal) and stale `fnm`
    shell entries from before the last restart.
  - **Homebrew leftovers, one package at a time**: `brew cleanup` per formula or cask
    (skipping anything upgraded in the last 7 days) and unused formulae via
    `brew uninstall --formula`.
  - **Runtime versions no project needs** from uv, pyenv, fnm, nvm, SDKMAN, rustup, mise,
    asdf, Volta and pnpm, shown as commands to copy; Wega never removes these itself. The new
    "Katalogi projektów" card in Settings (default `~/Dev`) says where your projects live.
  - **Gradle and JetBrains**: unused Gradle wrapper distributions, downloaded JDKs and
    folders of JetBrains IDE versions that are no longer installed.
  - **A `PATH` check**: missing, repeated and nested entries, and tools whose active copy is
    older than one it hides, each with the shell file and line that adds it and what to
    change there. Wega never edits your shell files.
  - **An optional Files and Folders map** (off by default, switched on in Settings): which
    programs hold Files and Folders permission, matched to the copies the scan found, with a
    `tccutil reset` command for each. It needs Full Disk Access, which macOS then gives to
    every program Wega starts, so grant it only while you read the map.
  - **Safe by default**: nothing is removed until you confirm, and confirmed items go to the
    Trash or are removed with Homebrew. Documents, Desktop, Downloads, iCloud and other
    protected folders are never opened. Your shell runs only when you press "Odczytaj PATH",
    and "Anuluj" stops it. Reports export as text or JSON with `~` in place of your home
    folder.
- **Uninstall removes apps owned by `root`**, such as those installed from a `.pkg`: Wega's
  helper moves them to your Trash. This needs the helper switched on in Settings and an
  administrator account; otherwise the app stays where it is and Wega says what to do. If
  Uninstall reports that the helper is out of date after this update, remove and reinstall it
  in Settings.

### Changed
- **Uninstall is safer.**
  - Running apps are asked to quit first. An app that won't close is force quit only after
    you confirm (its unsaved changes are lost), and every app is checked again right before
    it is removed.
  - Only the copy you selected counts: the same app running from another folder is left
    alone.
  - Wega itself, apps that are part of macOS and apps reached through a symbolic link can't
    be selected, and the list says why.
  - Every app that wasn't removed is listed with its reason and, where it helps, a button to
    show it in Finder.
- **Uninstall finds more leftovers** of apps Homebrew doesn't manage, and says why each one is
  listed: the app's Homebrew zap list, locations tied to its bundle identifier, and folders
  named after it (marked "probable" and left unticked). Shared vendor folders start unticked
  as "shared folder?", items another installed app still uses as "also used by", and every
  item shows its size. Leftovers go to the Trash, only from your home folder and only for apps
  that were actually removed.
- The Logs shortcut moved from ⌘6 to ⌘7 to make room for Porządki.

### Fixed
- **Fewer phantom updates.**
  - **ChatGPT** offers only the release that OpenAI's staged rollout serves to everyone.
  - **Google Chrome and Google Drive** no longer show Chrome versions still rolling out or
    Drive canary builds.
  - **Obsidian** no longer keeps showing an update it has already installed, and an older
    Homebrew record no longer brings that row back.
  - **Apps that update themselves**, such as Logi Options+, no longer reappear as outdated
    after every scan, and such an app is listed once when its vendor and its Homebrew cask
    name the same release.
  - **Versions written as tags**, such as Raspberry Pi Imager's `v2.0.12`, no longer cause an
    update that `brew reinstall` could never clear.
- **Background updates** no longer count, announce or install casks whose app has already
  updated itself, so the menu-bar badge matches the window and an older cask can never be
  installed over a newer app.
- **Homebrew tap trust**: a fix that fails stays available to retry. When an untap is blocked
  by an untrusted package, Wega offers a separate `brew trust` for that exact package, and
  unused taps are removed one at a time, so a later failure doesn't repeat taps already
  removed.

## [0.6.0] — 2026-11-02

### Added
- Check standalone Firefox and Thunderbird updates within the installed Release, ESR or
  Beta channel, and Zed updates within Stable or Preview. Update actions open the installed
  application's own updater.
- Check official Bruno and UTM releases without requiring a Homebrew installation.
- Show Microsoft AutoUpdate offers for vendor-installed Office apps and open MAU explicitly;
  App Store copies retain their App Store update route.
- Route WARP and Logi Options+ updates through their vendors, and recognize Bitdefender's
  installed product version without claiming that its software or threat signatures are current.
- Offer one-click fixes for Homebrew tap-trust warnings. Each action shows its command,
  trusts only packages installed from the affected taps, or removes taps with no installed packages.
- Export bounded, redacted local diagnostic traces covering update stages, subprocess output,
  HTTP attempts and observed vendor results. Diagnostic exports remain local.

### Changed
- Docker Desktop defaults to its vendor updater and is excluded from bulk and background
  updates. Explicit Homebrew replacement and rollback require confirmed shutdown; an optional
  restart checks engine readiness. Rollback covers the application bundle only.
- Vendor update checks run independently of Homebrew ownership and reconcile comparable offers
  for the same verified installation.
- Inventory distinguishes exact installer and JDK ownership from unconfirmed Homebrew
  associations, and retains installations whose update status cannot be verified.

### Fixed
- App Store checks confirm each installed copy using its own identity and version; missing
  identities and duplicate installations remain unconfirmed.
- **Update via Brew** reinstalls a cask when Homebrew already records the offered version but
  the application on disk is older. Cask repair verifies version and build changes before
  reporting success.
- Post-update launch checks wait for Electron's built-in updater and withdraw staged ShipIt
  installs, including on cancellation. When withdrawal cannot be confirmed, Wega leaves the
  application running rather than triggering its queued installer by quitting it.
- Report an application that replaces itself during a launch check instead of reporting the
  original update as successfully applied.

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

[Unreleased]: https://github.com/DominikSienkiewicz/WegaMacUpdater/compare/v0.9.0...HEAD
[0.9.0]: https://github.com/DominikSienkiewicz/WegaMacUpdater/compare/v0.8.0...v0.9.0
[0.8.0]: https://github.com/DominikSienkiewicz/WegaMacUpdater/compare/v0.7.1...v0.8.0
[0.7.1]: https://github.com/DominikSienkiewicz/WegaMacUpdater/compare/v0.6.0...v0.7.1
[0.6.0]: https://github.com/DominikSienkiewicz/WegaMacUpdater/compare/v0.5.5...v0.6.0
[0.5.5]: https://github.com/DominikSienkiewicz/WegaMacUpdater/compare/v0.5.4...v0.5.5
[0.5.4]: https://github.com/DominikSienkiewicz/WegaMacUpdater/compare/v0.5.3...v0.5.4
[0.5.3]: https://github.com/DominikSienkiewicz/WegaMacUpdater/compare/v0.5.2...v0.5.3
[0.5.2]: https://github.com/DominikSienkiewicz/WegaMacUpdater/compare/v0.5.1...v0.5.2
[0.5.1]: https://github.com/DominikSienkiewicz/WegaMacUpdater/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/DominikSienkiewicz/WegaMacUpdater/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/DominikSienkiewicz/WegaMacUpdater/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/DominikSienkiewicz/WegaMacUpdater/compare/v0.2.0...v0.3.0


[0.2.0]: https://github.com/DominikSienkiewicz/WegaMacUpdater/releases/tag/v0.2.0
