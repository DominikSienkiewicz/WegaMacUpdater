# Install progress design

What the window shows **while an update is being installed**. Today the answer is: a spinner
inside the button, a stop button, and a live brew log. Nothing says how much of the batch is
done or how much is left.

The scan already solved this problem honestly — `ScanPhase` / `ScanProgress`
([`Sources/MacUpdaterCore/ScanPhase.swift`](Sources/MacUpdaterCore/ScanPhase.swift)) drive a
determinate bar whose value is *work finished*, not work guessed. This document extends the
same idea to the upgrade run.

---

## 1. What the upgrade run actually does

`ScanStore.runUpdateCoordinated`
([`Sources/MacUpdater/ScanStore+Updating.swift`](Sources/MacUpdater/ScanStore+Updating.swift))
executes strictly in this order:

1. **preparation** — snapshots of every planned cask plus the publisher watchdog
   (`prepareForegroundCasks`);
2. **formulae** — one `brew upgrade <names…>` call;
3. **casks** — one `brew upgrade --cask <tokens…>` call, plus at most one `--force` retry for
   tokens left over from an interrupted upgrade;
4. **npm** — one call per package, in a loop;
5. **mas** — one `mas upgrade <ids…>` call;
6. **rescan** — `runCheck(lightweight:)`, which decides what the list says afterwards.

Every brew and npm call already streams stdout and stderr chunk by chunk through
`ProcessEventStream.drain`, and the chunk handler already writes them into `brewLog`. That
handler is the whole integration point: the progress model is fed from the stream that is
already flowing, not from a second process, a timer, or a poll.

## 2. What brew tells us, and what it does not

Verified against the installed Homebrew (`/opt/homebrew/Library/Homebrew`), because the
design stands or falls on which markers really appear in a **piped** (non-TTY) run:

| Marker | Source | Meaning |
|---|---|---|
| `==> Upgrading <token>` | `upgrade.rb:214`, `cask/upgrade.rb:405` | a package's install starts — serial, ordered, both formulae and casks |
| `==> Installing Cask <token>` | `cask/installer.rb:172` | same, cask path |
| `==> Downloading <url>` | `curl_download_strategy.rb:67` | a download starts |
| `==> Fetching downloads for: <name>` | `formula_installer.rb:1479` | downloads start for a formula |
| `🍺 <token> was successfully upgraded!` | `cask/installer.rb:252` | a cask finished |

Two findings constrain the design, and both are the reason this document does not promise a
percentage:

- **There is no download percentage.** Homebrew adds `--silent` to curl whenever stdout is
  not a TTY (`utils/curl.rb:160`), and Wega runs brew through pipes. The `####  45.2%` lines
  a terminal shows never reach us. Giving brew a pseudo-terminal would produce them, but a
  controlling TTY also invites `sudo` to prompt on that terminal instead of going through
  `SUDO_ASKPASS`, which is a hang, not a feature. Ruled out.
- **Downloads are parallel.** `HOMEBREW_DOWNLOAD_CONCURRENCY` defaults to `auto`
  (`env_config.rb:324`) — twice the core count. So the *order* of `==> Downloading` lines
  says nothing about which package is next, and no line reports a download finishing.

What remains is reliable: the serial `Upgrading` / `Installing Cask` / `🍺` markers. Package
granularity is therefore the honest ceiling, and the bar is built on exactly that.

Formulae end with `🍺  /opt/homebrew/Cellar/<name>/<version>: 12 files, 1.2MB` — a path, not
a token — so that shape is deliberately ignored and formulae are closed by the boundary rule
instead (§4).

## 3. Model (MacUpdaterCore)

New file `Sources/MacUpdaterCore/UpgradeProgress.swift`:

```swift
/// What an upgrade run is doing right now, in the order it happens.
public enum UpgradeStage: Equatable, Sendable {
    case preparing
    /// `nil` while brew downloads several artifacts at once and no single
    /// package can honestly be named (§4 says when it may be named).
    case downloading(token: String?)
    /// `nil` for the App Store batch, which moves several apps behind one
    /// opaque call and can name none of them.
    case installing(token: String?)
}

public struct UpgradeProgress: Equatable, Sendable {
    public let completedUnits: Int
    public let totalUnits: Int
    public let stage: UpgradeStage

    /// Finished work, never work in flight — the same rule `ScanPhase` follows.
    public var fractionCompleted: Double
}
```

No localized text lives here. `ScanPhase.commandLabel` returns the raw `brew outdated`; in the
same spirit `UpgradeStage` carries a token and the view composes the sentence through
`tr`/`trf`. That also keeps the new Polish strings inside the app target, where
`LocalizationCompletenessTests` can see them.

**One planned row is one unit.** No weighting by download size or package kind: a 1.5 GB cask
and a 2 MB formula both count as one, because any other weight would be a number we cannot
substantiate. Total units = the planned items the run captured before it started.

## 4. Parser and tracker (MacUpdaterCore)

`BrewUpgradeProgressParser` — pure, one line in, at most one event out, no state:

```swift
public enum BrewProgressEvent: Equatable, Sendable {
    /// `nil` unless brew named the package it fetches for: a parallel batch
    /// names URLs, and a URL is not a package.
    case downloadStarted(token: String?)
    case packageStarted(token: String)
    case packageFinished(token: String)
}
```

`UpgradeProgressTracker` — the state, and the only place the rules live:

- **boundary rule**: `packageStarted(next)` implies whatever was in flight is finished. This
  is what closes formulae, which have no per-token success line.
- **planned tokens only**: `brew upgrade <names…>` also upgrades the outdated *dependents* of
  what it was asked for, announcing each with the same `==> Upgrading` marker. Only a token
  the run planned may be credited, matched on the bare name (the part after the last `/`) so
  brew's tapped form `homebrew/core/node` credits a planned `node` — and credits it once. A
  dependent still closes the planned package it interrupted, and is still named on screen,
  because both are true; it just never counts.
- **completion set**: finished tokens are kept in a `Set`, so the `🍺` line and the boundary
  rule cannot credit the same package twice.
- **known limit of a name-keyed set**: a run planning both the formula *and* the cask of one
  name — `docker` is both — puts 2 in the total and can be credited only 1, so the bar stops
  one short. Fixing it means keying the set by kind as well as name, which brew's markers do
  not carry: they print the bare name in both phases. Left as it is, because the error runs
  the same direction as every other rule here — understating finished work, never overstating.
- **monotonic**: `completedUnits` never decreases. The `--force` retry re-runs tokens that
  have already been counted, and a bar that walks backwards reads as a bug.
- **clamped**: never above `totalUnits`, whatever brew prints.
- **explicit advances**: `npm` is a loop that already knows its package, so it advances one
  unit per successful iteration; `mas` reports nothing per app, so its whole group advances
  at once — and only when the call returned without error. A failed `mas upgrade` credits
  nothing, because we have no evidence any single app was updated.
- **explicit naming**: those same two sources also set the stage, since neither prints a
  marker this parser reads. Without it a run holding only npm or only App Store rows would
  stay in `.preparing` from start to finish, and a run that ends in npm would keep naming the
  cask that finished before it.
- **naming a download**: `.downloading` carries a token in exactly two cases — brew named it
  (`==> Fetching downloads for: <name>`), or the run plans a single package, in which case
  there is nothing else the download could be. Otherwise the token is `nil` and the view says
  so. This is the rule that covers the common "one app, one big download" run without
  guessing during a parallel batch.

A run that fails part-way ends below 100% — six of seven packages upgraded leaves the bar at
6/7. Packages the publisher watchdog vetoed during preparation never run, so they never
complete either: they stay in the total and the bar stops short. The bar reports what
happened; the banner already explains it.

## 5. Wiring (Sources/MacUpdater)

- `ScanStore` gains `@Published var upgradeProgress: UpgradeProgress?`, next to the existing
  `progress`.
- `runUpdateCoordinated` owns one tracker per run: `.preparing` before `prepareForegroundCasks`,
  `.installing` named before each npm package and before the `mas` batch, `nil` wherever
  `updating` is set back to `false`. The closing `runCheck` is not a stage of this bar: it
  replaces the results view with the scan's own screen, which carries its own honest bar, so
  the two hand over to each other.
- `runBrewUpgrade` feeds the tracker from inside the existing `onChunk` closure, next to the
  line that appends to `brewLog`. No new streaming loop — the architecture test
  `brewNpmEventStreamingRunsThroughOneSharedHelper` requires exactly one, and this design does
  not add a second.

## 6. UI

New `UpgradeProgressBar` in
[`Sources/MacUpdater/UpdateViewSupport.swift`](Sources/MacUpdater/UpdateViewSupport.swift)
(not in `UpdateView.swift`, which is already 705 lines against a 1050-line lint warning),
rendered under the results header while `scan.updating`:

- linear `ProgressView` tinted `Color.wegaHoney`, with `.frame(minWidth: 0, maxWidth: .infinity)`.
  That frame is not cosmetic: a linear bar reports a nonzero intrinsic width, and without an
  upper bound it widens the detail column until the sidebar is pushed off-screen — the trap
  documented at [`UpdateView.swift:190`](Sources/MacUpdater/UpdateView.swift:190).
- **indeterminate** while `.preparing` (there is nothing to count yet), determinate from the
  first package onwards.
- a label naming the activity, the counter, and the package whenever one can be named:
  `Instaluję firefox — 3 z 7`, or `Pobieram firefox — 3 z 7` when the download can be
  attributed (§4). Where no single package can honestly be named it says so instead of
  inventing one: `Pobieram pakiety — 3 z 7` during a parallel download batch, and
  `Instaluję pakiety — 3 z 7` for the App Store's one opaque call.
- accessibility: label `Postęp aktualizacji`, value `3 z 7`.

The existing stop button and the button's own spinner stay exactly as they are.

## 7. Scope

In: the batch update behind **Zaktualizuj wybrane / wszystkie**.

Out, deliberately: the single manual install (`ScanStore+Adoption`) keeps its per-row spinner;
background updates and Wega's self-update have no window to render a bar in, and giving them
one is a different feature (menu bar / notifications), not this one.

## 8. Tests

Written as part of the change; running them is a separate, explicit request.

- `BrewUpgradeProgressParserTests` — real transcript lines for the formula path, the cask
  path, the `--force` retry, and unrelated noise (`Warning:`, `==> Purging files`,
  `🍺  /opt/homebrew/Cellar/…`) that must produce no event.
- `UpgradeProgressTrackerTests` — the boundary rule closes a formula; `🍺` and the boundary
  rule together credit a cask once; a `--force` retry does not move the count backwards; the
  count clamps at the total; npm advances per iteration and a failed `mas` batch credits
  nothing; a single-package run names its download, a multi-package one does not.

## 9. Documentation

`USER_GUIDE.md` §3 (*Updating your apps*) and `CHANGELOG.md` gain the new behaviour, since it
is visible to users. No public API or configuration changes.
