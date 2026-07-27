# Self-update design

How Wega notices, presents and installs a newer version of **itself** — the path from a
published `v1.0.1` tag to that build running on the user's Mac.

Distributing the release is a solved problem and out of scope here; see
[RELEASING.md](RELEASING.md). This document starts where that one ends: a GitHub Release
exists, and an installed copy of Wega has to do something about it.

---

## 1. What already works

The path is not new. Today it already:

- asks the GitHub Releases API for `latest`, rejects drafts and prereleases, and compares
  the tag against `AppMetadata.version` under SemVer
  ([`WegaSelfUpdateChecker`](Sources/MacUpdaterCore/WegaSelfUpdateChecker.swift));
- folds the result into the ordinary scan as one more `ManualOutdatedApp` (UX-15), so it
  reaches the badge, the menu-bar count and the background notification through the same
  chokepoint as every other app;
- downloads the asset, **verifies its signature fail-closed** — Team ID, bundle ID and a
  Gatekeeper assessment via `CodeSignatureVerifier` — and deletes the file and opens the
  release page if that fails;
- installs a `.pkg` headlessly through the privileged helper when the helper is enabled,
  and otherwise opens the same downloaded asset for the user to finish — the helper changes
  who completes the install, never which artifact was fetched;
- carries the release body along as `releaseNotes`, which the inspector renders after
  `ReleaseNotesText` has stripped its markup.

Four things are missing, and this design addresses exactly those.

## 2. The four gaps

| # | Gap | Consequence |
|---|---|---|
| 1 | The checker pre-selects a single asset, so the planner can only comment on a decision already made | Install-vs-open is re-derived downstream from the file, and the choice cannot be stated in one place |
| 2 | Nothing restarts the app after a headless install | The bundle is swapped under a running process, and nobody says so |
| 3 | Only the newest release body is available | Three versions behind means seeing one third of the change |
| 4 | No way to silence a specific version | An unwanted release sits in the count permanently |

Gap 4 turns out to cost nothing: `UpdatePlanner.applyPolicies` already runs over
`manualApps`, so the existing ignore / pin rules reach the Wega row. It needs a regression
test, not a feature.

## 3. Principle

**The checker reports facts, the planner decides, the controller acts.**

That separation is what is currently broken: the checker picks the asset, leaving the
planner to comment on a decision already made. Restoring it fixes gap 1 as a side effect
rather than as a special case.

## 4. Detection

Unchanged in cadence — the check rides the ordinary scan, and the Settings card triggers it
on demand. Only the shape of the result changes:

```swift
case updateAvailable(version: String, assets: [Asset], releaseURL: URL, notes: String)
```

The checker no longer chooses among assets; it reports the ones the release published.
Which asset is *preferred* remains a fixed security ordering — `.pkg`, then `.dmg`, then
nothing — expressed exactly once, in `SelfUpdatePlanner.preferredAsset`. `helperEnabled`
selects the install **method**, never the artifact.
`ManualUpdateScanner.selfUpdateApp` maps the result as before, and the Wega row's action
opens the self-update screen instead of a browser.

## 5. Installation and restart

```
SelfUpdatePlanner.action(helperEnabled:assets:) -> .install(pkg) | .downloadAndOpen(asset)
```

`.install` — download, verify, hand to the helper, then enter a new terminal state:

```swift
case installedPendingRestart(version: String)
```

The screen reads *"Installed 1.0.1 — restart to use it"* with a restart button. Restarting
spawns a detached process that reopens the bundle after the current one exits, then calls
`NSApp.terminate`.

Two hard constraints on that button:

- it is **disabled while any mutating operation is in flight** — the `UpgradeCoordinator`
  write gate and `MutationGuard` that self-update already passes through are the authority,
  not a separate flag;
- it never fires without a click. Nothing here restarts the app on its own.

`.downloadAndOpen` keeps today's behaviour but stops being vague about it: the message says
to quit Wega before replacing it.

## 6. Release notes

A new pure type in Core — `ReleaseHistory`:

1. `GET /releases` (a new entry in `AppEndpoints` beside `githubLatestReleaseURL`), decoded
   as `[GitHubRelease]`, reusing the existing model;
2. drop drafts and prereleases;
3. keep versions **newer than the installed one**, ordered descending;
4. cap at 10, reporting how many were omitted rather than truncating silently;
5. pass every body through `ReleaseNotesText`.

Release bodies are untrusted input. They are sanitised, never rendered through WebKit.

The screen shows one collapsible entry per version — number, date, notes. *"No notes
published"* and *"couldn't reach GitHub"* are two different states, shown as themselves.

## 7. Failure behaviour

Every failure already has a defined resting place, and this design keeps them there rather
than inventing new ones: a signature that does not verify deletes the download and opens
the release page; a failed download does the same; the technical cause goes to the log and
the user sees a localized line. A release history that cannot be fetched leaves the update
itself installable — notes are informative, not a gate.

## 8. Tests

Written as part of the work, not executed here (per the project's verification policy —
the formatter and linter are the gate, test runs are opt-in).

- **Planner** — pkg + helper → install; **pkg without helper → open *the pkg*, never the
  dmg** (SEC-04: the missing helper must not downgrade the channel); only a dmg despite a
  helper → open; neither pkg nor dmg → no plan at all; no assets → no plan.
- **`ReleaseHistory`** — version filtering, prerelease exclusion, markup stripping, the cap
  and its omission count, empty result vs. transport error.
- **Controller** — reaching `installedPendingRestart`; the restart refused while the
  mutation gate is held.
- **Regression** — the Wega row stays out of the installable count, and ignore / pin rules
  apply to it.

## 9. Out of scope

A beta channel, silent background downloading, a rootless bundle swap, and a Homebrew tap.
Each can be added on this structure when there is a reason; none is needed to close the
four gaps.

## 10. Stages

| Stage | Content | Standalone value |
|---|---|---|
| E1 | One decision site for install-vs-open (asset preference stays `.pkg` → `.dmg`, SEC-04), `installedPendingRestart`, restart button | One-click update for helper users; no more swapped bundle under a live process |
| E2 | `ReleaseHistory` and the cumulative notes screen | See the whole change before installing it |
| E3 | *Check for Updates…* in the app menu; the Wega row routes to the screen | Discovery where macOS users look for it |

Documentation is updated with the stage that changes behaviour: README's self-update
section and USER_GUIDE.
