# Runtime verification checklist

Fifteen backlog cards are implemented, merged into `main` and behind a green
`./scripts/check.sh`. None of them is waiting on code. They are waiting on one person, at a
running Mac, confirming the things a unit test structurally cannot: what macOS actually does,
what a real package manager actually prints, what VoiceOver actually announces.

This document exists so that pass can be done in one sitting instead of card by card. It is
grouped by **what you need to have in front of you**, not by card ID, because several cards
share a setup and one app launch can settle six of them.

Each entry states what to do, what counts as a pass, what counts as a failure, and — where it
applies — what would still block the card from closing even if the check passes.

> Where a check has a known highest-risk failure mode, it is called out as **⚠ Biggest risk**.
> Those are the ones worth doing carefully; the rest are usually a glance.

---

## Read this first: three cards are not actually blocked on runtime

`LT-05` and `OBS-02` carry `runtime_verification_required: false`. They are `in_progress`
because their implementation notes recorded an open item, not because the backlog demands a
live measurement, and both of those items have since been closed in code. They are the two
cheapest to settle. (`LT-03`, listed here previously, is closed.)

## Before you start

```bash
./scripts/check.sh
```

Everything below assumes a build of the current `main`. Two checks (`LT-05`, `SEC-04`) behave
differently for a Developer ID-signed build than for a local debug build; both say so where it
matters.

---

## A. One run of the app — no package manager, no external infrastructure

Six cards settle here. Do them in this order: the accessibility passes want the app open and
idle, and the login-item check ends in a restart, so it goes last.

### A1 · `OBS-02` — diagnostics export

**Do:** open **Settings → System diagnostics → Export diagnostics**, save the `.zip`. Then open the **Logs** view and
use the **Export diagnostics** button in its toolbar. Unzip both and read the contents.

**Pass:** both buttons produce a `.zip` that opens in Finder; the archive contains **both** log
files (including the rotated `wega.log.1`), app and OS version, detected managers, helper
status and version, schedule status, per-source last results, free disk space, signature state,
and the update → validation → rollback history.

**Fail:** a save panel that does nothing, an archive Finder refuses to open, or a missing
section.

**⚠ Biggest risk:** redaction against *your real* `wega.log`, not the test fixture. Search the
extracted files for your account name, any `Authorization:` header value, and any token-shaped
string. The test asserts on raw ZIP bytes for a synthetic snapshot where every field is bait —
it cannot know what your actual log contains.

**Also check the deep link.** Trigger a background round and click its notification: a clean
round opens the updates list, a round with a failed rollback or a changed publisher opens
**Logs**. Click a recovery notification too — it always opens Logs. What a unit test cannot
cover is whether macOS delivers the click to the delegate at all, which needs a bundled app, a
login session and a granted permission.

### A2 · `UX-02` — keyboard and VoiceOver on the selection lists

**Do:** turn VoiceOver on (⌘F5). Walk the **updates**, **uninstall** and **migration** lists
using only the keyboard. Open the uninstall dialog and press Esc, then reopen it and press
Enter.

**Pass:** every row is reachable by keyboard; Space toggles a selection in both lists; the
uninstall sheet closes on Esc and confirms on Enter; each row announces which app it refers to.

**⚠ Biggest risk:** the selection checkbox uses a **custom** `WegaCheckboxToggleStyle`, chosen
so the lists keep their look. The open question is whether VoiceOver announces it as a
*checkbox* or as a *button*. If it says button, the fix is to fall back to
`.toggleStyle(.checkbox)` and accept the appearance change — that is a decision for you, and
the card cannot close until it is made.

**Note:** the "select all" row is deliberately a `Button`, not a `Toggle` — it has three states
(none / some / all) and a checkbox would misreport the mixed one. It announces the selected
count instead. That is intended, not a defect.

### A3 · `UX-03` — text scaling, palette, contrast, Reduce Motion

**Do:** four separate things.

1. Set **System Settings → Accessibility → Display → Text size** to its largest step and walk
   the main window.
2. Measure the contrast of body text against its background with a contrast meter, in **light,
   dark, and increased-contrast** modes.
3. Turn **Reduce Motion** on and off **while a scan is running**, not before it starts.
4. Drag the Settings window to a small size and a large one.

**Pass:** no clipped or overlapping text at the largest step; measured contrast ≥ **4.5:1** in
all three modes; continuous animations stop and resume without leaving a frozen half-frame;
the Settings window resizes instead of sitting at a fixed size.

**⚠ Biggest risk:** contrast. The tests pin the *declared* colour values; they say nothing
about what the compositor actually renders once translucency is layered over the material. A
meter on screen is the only real answer.

### A4 · `SEC-07` (partial) — the ETag survives a restart

**Do:** launch the app, let the catalog refresh, quit it fully, launch again and watch the
network request for the catalog.

**Pass:** the second launch sends a conditional request and gets **304**, rather than
re-downloading the whole catalog.

**Fail:** a full download on every launch — the ETag is not reaching disk.

The rest of `SEC-07` needs the production CDN; see [C3](#c3--sec-07--the-envelope-on-the-production-cdn).

### A5 · `LT-05` — a crash report actually arrives

**Do:**

```bash
killall -ABRT WegaMacUpdater
```

Then relaunch and check **Settings → Crash reporting**, and grep `wega.log` for
`Raport awarii Wegi:`.

**Pass:** the card lists a stored report, and the log line is there.

**Fail:** nothing arrives. Two documented reasons are *not* failures: MetricKit delivers the
payload to a **running** app, so a crash on every single start would never report itself, and
`metrickitd` needs a login session.

**⚠ Biggest risk:** this is the one check that behaves differently for a **Developer ID-signed
build** than for a local debug build. A debug build not arriving proves nothing; do this on a
signed build before concluding anything. It confirms two things at once — that payloads are
delivered at all, and that MetricKit's `jsonRepresentation` keys still match the parser.

**Privacy is already pinned by tests, not by this check:** nothing is uploaded (a source test
forbids `URLSession` / `URLRequest` / `HTTPClient` / `http(s)` across five files), collection is
off by default, and `pastDiagnosticPayloads` is deliberately never drained — consent works
forwards only.

### A6 · `BG-02` — launch at login survives a restart

**Do:** in Settings, toggle **Launch at login** on. Open **System Settings → General → Login
Items** and confirm Wega is listed. Toggle it back off in Wega and confirm it disappears from
that list. Turn it on again, then **restart the Mac** and do not launch Wega by hand.

**Pass:** the toggle reflects the real system state in both directions, and after the restart
the schedule, the badge, notifications and silent background updates all work without you
opening the app.

**Fail:** the toggle shows a state System Settings disagrees with, or background updates are
dead until the app is launched manually — which is exactly the bug this card was opened for.

**⚠ Biggest risk:** `SMAppService` behaviour on a **clean macOS 26 install** was never measured;
the audit was static. If you have a spare machine or a fresh VM, that is the honest test bed.
Your daily Mac has approved this app before and may not represent a first run.

---

## B. Needs a real package-manager operation

These cannot be faked. Each one wants a genuine upgrade against live `brew` or `mas`.

### B1 · `REL-01` — selecting one App Store app updates only that one

**Do:** with at least two outdated App Store apps, select **one**. Open the dry-run preview
("Show exactly what I will do") and read the command. Then run it.

**Pass:** the preview shows `mas upgrade <id>` **with the identifier**, and only the selected
app is upgraded.

**Fail:** the other App Store apps update too.

**⚠ Biggest risk / open fork:** the card's own last criterion is conditional. If your `mas`
version does **not** honour per-ID selectivity, the correct outcome is not a bug report — it is
to present MAS as one indivisible "update all" group instead of individually selectable rows.
Which branch applies can only be decided by watching a real `mas` do it.

### B2 · `REL-07` — a rolled-back cask does not read as current

**Do:** cause a real auto-rollback on a live cask, then run a scan.

**Pass:** the app forces the rolled-back cask back onto the update list with the
**"rolled back — retry"** label, even though `brew outdated` no longer reports it; a conscious
retry through "Update via Brew" repairs the Caskroom metadata and clears the mark.

**Fail:** the rolled-back app silently reads as up to date — the exact invisibility this card
was opened for.

**⚠ Biggest risk:** confirming what `brew outdated` really does after a rollback. The audit
could only reason about it statically.

### B3 · `REL-12` — cancel, and the idle timeouts

**Do:** three things.

1. Press **Cancel** during a real `brew upgrade` of a **large** cask.
2. Cancel a scan during `brew update`.
3. Run a **multi-gigabyte** download to completion without cancelling — ideally a
   `mas upgrade`.

**Pass:** (1) the in-flight package finishes, no further packages start, `pgrep` shows no
orphans, and the upgrade mutex is released — the window is usable again. (2) same. (3) the
download completes.

**⚠ Biggest risk — this is the one to watch:** **false idle-timeout alarms**. The new limits are
`quick 30/20`, `query 600/180`, `download 7200/900`. Fifteen minutes of silence kills a
download, and a large `mas upgrade` can be quiet for a long time while genuinely working. If a
real download dies with an inactivity error, that is a regression in the limits, not a stuck
process — raise the `download` idle budget rather than accepting the kill.

### B4 · `REL-05` — the App Management denial

**Do:** revoke Wega's **App Management** permission (System Settings → Privacy & Security →
App Management) and run a cask upgrade that replaces a bundle in `/Applications`.

**Pass:** you get the dedicated banner naming the permission, with a button that opens the
right System Settings panel — not raw `stderr`. The background round does **not** report a
successful update, and does not retry every interval (it holds for 24 h after an observed
denial). Grant the permission and confirm the hold lifts on the next successful round.

**Three things to confirm specifically:**

1. Whether the denial really surfaces as the parsed `"Operation not permitted"` + `.app` path
   pattern on macOS 26.
2. Whether the optional preflight row in **Settings → System diagnostics** is honest. It probes by
   opening a write handle inside another app's bundle. If `open(O_WRONLY)` does **not** return
   `EPERM` without the permission, that row will read *granted* while the permission is
   missing. The observed denial remains the authoritative signal and is immune to this, so a
   wrong diagnostic row is a cosmetic defect, not a safety hole — but it should be known.
3. Whether the deep link opens the correct panel on macOS 26.

### B5 · Rider on any real cask upgrade — the `LT-02` five-second window

Not a card (`LT-02` is closed), but it is the freshest unmeasured risk in this area and it costs
nothing to watch while you are doing B1–B4 anyway.

After a successful cask upgrade, the app now launches the upgraded app **hidden** and watches it
for five seconds before accepting the update.

**Watch for:** a *good* update being rolled back because a slow-starting app (Electron,
JetBrains from cold) did not survive five seconds. That is a false positive, and it is worse
than the crash the check exists to catch. Also watch that no window flashes and that focus is
not stolen.

**If it happens:** the knob is `LaunchSmokeTestConfiguration.defaultWindow` in
`Sources/MacUpdaterCore/LaunchSmokeTest.swift`. The whole check can be switched off in
**Settings → Post-update launch test**.

---

## C. Needs infrastructure outside the app

### C1 · `QA-03` — the release pipeline end to end

**Do:** confirm the Developer ID / notarytool secrets exist in GitHub, then push a real `v*`
tag and let the pipeline run.

**Pass:** CI and release share the reusable workflow and the same runner; Xcode and SwiftLint
are pinned; the release gate checks bundle layout, helper signature, notarization, stapling and
required resources — not just `swift test`; and the release cannot outrun the quality gates.

**Blocked until then:** this is the card that gates `SEC-04` too. Without the secrets, every tag
publishes as a **prerelease** by design.

### C2 · `SEC-04` — self-update publisher pinning

**Do:** with the release secrets in place, produce a real signed `.pkg` and `.dmg` and take the
self-update path end to end.

**Four things to confirm:**

1. Whether `SecStaticCodeCreateWithPath` actually reads the signature of a `.dmg` **image**.
   If it does not, the `.dmg` path fails closed and is effectively dead.
2. The full `.dmg` flow end to end.
3. The exact shape of `pkgutil --check-signature` output on a genuinely signed `.pkg`. A parse
   miss is now a **rejection**, not a skip — so a formatting surprise blocks self-update rather
   than silently passing it.
4. That the GitHub secrets are present at all. Until they are, `STABLE_RELEASE` keeps every tag
   a prerelease, and `WegaSelfUpdateChecker` ignores prereleases — so an unsigned artifact
   cannot be offered as an update. That is the intended fail-closed state, not a bug.

**Still blocks closure:** one criterion is infeasible as written — see
[Section D](#d-verification-alone-cannot-close-these).

### C3 · `SEC-07` — the envelope on the production CDN

Implemented and tested, but **not live**: the OTA channel still serves the two-file format.
Switching it is one command, and it is yours because the signing key is not in the repo.

```bash
WEGA_CATALOG_KEY=~/.secrets/wega-catalog.pem ./scripts/sign-catalog.sh --envelope
```

To go back to the editable form: `./scripts/sign-catalog.sh --unwrap`.

**Then confirm:** CI and the app both accept the envelope served from `raw.githubusercontent`;
feeding an **older generation** produces a visible rejection rather than silent acceptance; and
remember that **every publication must bump `generation`** (documented in `CONTRIBUTING.md`).

---

## D. Verification alone cannot close these

Passing a check is not enough here. Each needs work that was left undone, or a decision only
you can make.

| Card | What is open | What it needs from you |
|------|--------------|------------------------|
| `QA-04` | Nothing structural. The two items the implementation note called unfinished — no table of contents, a 5,600-character "Update" wall — were closed after that note was written: README has a nested TOC and the Update section is 12 subsections whose longest paragraph is 1,324 characters. The last real drift (README said *nine* manual checkers against 13 in `ManualUpdateScanner`, and the "Act" step named four of the eight `.launchApp` sources) is fixed and now guarded by `QA04CheckerCountDriftTests`. | Read README against the code once and close it. |
| `OBS-02` | Nothing. The *notification → specific operation/log* deep link, the one criterion left open, is implemented: `NotificationRouting` carries the destination in the notification's `userInfo` and `NotificationRouter` applies it at startup. All thirteen criteria are done. | Verify the click once (see [A1](#a1--obs-02--diagnostics-export)) and close it. |
| `LT-03` | Two things. A **Team ID mismatch is a hard veto** — an app legitimately re-signed with a new certificate is refused until you act. The alternative is stepping down to `requiresConfirmation`. Separately: `caskNames: []` is hardcoded at both call sites, so the **display-name matching branch is also dead** — the same class of bug this card fixed for Team ID, one level over. | Decide the veto strength. Decide whether the dead name branch is a new card. |
| `SEC-04` | *"Digest from a signed manifest"* is infeasible as written — no signed manifest exists anywhere in the pipeline, so there is nothing to read a digest from. Identity pinning (Team ID + bundle ID + version) was implemented instead. | Decide: accept identity pinning as sufficient, or open a card for a signed manifest. |
| `QA-06` | Two things. *"Fix the links after releasing v0.1.0"* is impossible — `scripts/release.sh:302` rejects any version not greater than `AppMetadata.version`, which is already `0.1.0`, so `v0.1.0` can never be cut. The section now says plainly it was never tagged. Separately, a three-line guard was added to `scripts/release.sh` (only accept a `previous_version` that has a real tag) to stop the first release generating a fresh dead link — **that is a code change outside a documentation card's scope**. | Read `[Unreleased]` against your own memory of July and confirm the BREAKING wording. Approve or revert the `release.sh` guard. |
| `REL-01` | The last criterion is a fork, not a check — which branch is correct depends on what live `mas` does (see [B1](#b1--rel-01--selecting-one-app-store-app-updates-only-that-one)). | Pick the branch once you have watched it. |
| `UX-02` | If VoiceOver announces the custom toggle style as a *button*, the fallback is `.toggleStyle(.checkbox)` with an appearance change. | Decide only if the check fails. |

---

## Summary

| Card | Where | Blocked on runtime? |
|------|-------|---------------------|
| `LT-05` | [A5](#a5--lt-05--a-crash-report-actually-arrives) | No (`rvr: false`) — but do the signed-build check |
| `OBS-02` | [A1](#a1--obs-02--diagnostics-export) | No (`rvr: false`) — all criteria done |
| `LT-03` | [D](#d-verification-alone-cannot-close-these) only | No (`rvr: false`) — needs two decisions |
| `UX-02` | [A2](#a2--ux-02--keyboard-and-voiceover-on-the-selection-lists) | Yes |
| `UX-03` | [A3](#a3--ux-03--text-scaling-palette-contrast-reduce-motion) | Yes — contrast meter |
| `BG-02` | [A6](#a6--bg-02--launch-at-login-survives-a-restart) | Yes — clean install preferred |
| `REL-01` | [B1](#b1--rel-01--selecting-one-app-store-app-updates-only-that-one) | Yes — live `mas` |
| `REL-07` | [B2](#b2--rel-07--a-rolled-back-cask-does-not-read-as-current) | Yes — live `brew` |
| `REL-12` | [B3](#b3--rel-12--cancel-and-the-idle-timeouts) | Yes — watch idle timeouts |
| `REL-05` | [B4](#b4--rel-05--the-app-management-denial) | Yes — TCC on macOS 26 |
| `QA-03` | [C1](#c1--qa-03--the-release-pipeline-end-to-end) | Yes — real tag + secrets |
| `SEC-04` | [C2](#c2--sec-04--self-update-publisher-pinning) + [D](#d-verification-alone-cannot-close-these) | Yes — gated by `QA-03` |
| `SEC-07` | [A4](#a4--sec-07-partial--the-etag-survives-a-restart) + [C3](#c3--sec-07--the-envelope-on-the-production-cdn) | Yes — production CDN |
| `QA-04` | [D](#d-verification-alone-cannot-close-these) only | No — needs one read-through |
| `QA-06` | [D](#d-verification-alone-cannot-close-these) only | Reading + one approval |

Statuses move only through the orchestrator API, never by editing a card by hand:

```bash
python3 -c "import sys; sys.path.insert(0,'docs/backlog'); import orchestrator as o; o.DRY_RUN=False; c=o.load_cards(); o.set_status(c['<ID>'],'done',note='<what you verified, and on what>'); o.regenerate_manifest(c)"
```

The note is the only place the reasoning survives — it lands in
`docs/backlog/orchestrator-log.jsonl`. Say what you actually observed, on what build and what
machine; "verified" on its own is worth nothing six months from now.
