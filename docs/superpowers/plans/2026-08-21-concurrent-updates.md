# Concurrent Update Run Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A selection of two or more updates runs its package-manager processes concurrently — one `brew`/`npm` process per selected row, at most three at a time — instead of one after another.

**Architecture:** `runUpdateCoordinated` stops being a chain of phases and becomes four lanes started together (formulae, casks, npm, App Store). The cask and npm lanes drive one process per row through a bounded pool; casks that may raise an admin-password prompt run in a strictly serial sub-lane. Everything stays `@MainActor`-isolated — the parallelism comes from separate `brew` processes and from `await` releasing the actor, not from threads — so no shared mutable state, no locks, no data races are introduced.

**Tech Stack:** Swift 6 (tools-version 6.0), SwiftPM, macOS 26, Swift Testing (`import Testing`, `@Suite`/`@Test`/`#expect`), SwiftLint.

## Global Constraints

- **Spec:** `docs/superpowers/specs/2026-08-21-concurrent-updates-design.md`. Every decision table row there is binding.
- **Worktree:** `/Users/dominiksienkiewicz/Dev/public/other/WegaMacUpdater/.worktrees/concurrent-updates`, branch `feat/concurrent-updates-2026-08-21`. Never touch `main`.
- **Do not run test suites.** Per the user's `AGENTS.md`, tests are opt-in. Write each test so its Red reason is obvious from reading it, then implement. The per-task verification gate is `swift build` **and** `swiftlint lint --strict` — never `swift test`, never `./scripts/check.sh` (it runs the full suite).
- **Concurrency limit:** exactly `3`, as `MacUpdaterConstants.maxConcurrentUpgrades`. No settings UI, no adaptive value.
- **Formulae stay one `brew upgrade` call.** App Store stays one `mas upgrade` call. Do not split either.
- **No new user-facing English strings without a `Translations.en` entry** — `LocalizationCompletenessTests` fails otherwise. Every `tr(`/`trf(` base string added must get a line in `Sources/MacUpdaterCore/Translations.swift`.
- **Do not modify pre-existing tests.** If a change appears to require it, stop and report instead.
- **Comment style:** this codebase writes comments that explain *why*, referencing the card marker (`REL-12`, `ARCH-08`, `F2`…). Match it. Do not add narrative comments restating the code.
- **UI strings are Polish base text** passed through `tr`/`trf`; log prefixes are package tokens and are **not** translated.

---

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `Sources/MacUpdaterCore/CaskUpgradeLanes.swift` | create | pure split of cask tokens into the concurrent pool and the serial admin lane |
| `Sources/MacUpdaterCore/UpgradeLogPrefix.swift` | create | prefixing streamed log lines with the package they came from |
| `Sources/MacUpdaterCore/Constants.swift` | modify | `maxConcurrentUpgrades` |
| `Sources/MacUpdaterCore/BrewUpgradeOutcome.swift` | modify | `isHomebrewLockCollision` |
| `Sources/MacUpdaterCore/BoundedConcurrency.swift` | modify | `runBoundedOnMainActor` overload |
| `Sources/MacUpdater/ScanStore+UpgradeLanes.swift` | create | one process per row: the brew/npm calls, their retries, their progress unit, the lanes that drive them |
| `Sources/MacUpdater/ScanStore+Updating.swift` | modify | orchestration and reporting only; per-item execution moves out |
| `Sources/MacUpdater/ScanStore.swift` | modify | `inFlightItemCount` |
| `Sources/MacUpdaterCore/Translations.swift` | modify | English for the one new log string |
| `docs/features.md` | modify | one sentence on concurrent updates |
| `Tests/MacUpdaterTests/CaskUpgradeLanesTests.swift` | create | lane split |
| `Tests/MacUpdaterTests/BrewLockCollisionTests.swift` | create | lock-collision recognition |
| `Tests/MacUpdaterTests/UpgradeLogPrefixTests.swift` | create | prefixing |
| `Tests/MacUpdaterTests/BoundedConcurrencyMainActorTests.swift` | create | pool cap and completeness |
| `Tests/MacUpdaterTests/ConcurrentUpdateRunTests.swift` | create | source-level guards on the `ScanStore` wiring |

`ScanStoreSources` discovers `ScanStore*.swift` by prefix, so the new `ScanStore+UpgradeLanes.swift` is picked up by every existing source-level guard automatically.

---

### Task 1: Lane split and the concurrency limit

**Files:**
- Create: `Sources/MacUpdaterCore/CaskUpgradeLanes.swift`
- Modify: `Sources/MacUpdaterCore/Constants.swift`
- Test: `Tests/MacUpdaterTests/CaskUpgradeLanesTests.swift`

**Interfaces:**
- Consumes: `CaskArtifactProfile` (`Sources/MacUpdaterCore/Models.swift`), whose `mayRequireAdminPassword` is `!artifactKinds.isDisjoint(with: [.pkg, .installer, .preflight])`.
- Produces: `CaskUpgradeLanes(tokens:profiles:)` with `.concurrent: [String]` and `.serial: [String]`; `MacUpdaterConstants.maxConcurrentUpgrades: Int`.

- [ ] **Step 1: Write the failing test**

Create `Tests/MacUpdaterTests/CaskUpgradeLanesTests.swift`:

```swift
import Testing
import Foundation
@testable import MacUpdaterCore

/// Which casks may be upgraded side by side.
///
/// A cask with a `pkg` / `installer` / `preflight` stanza can raise an admin-password
/// prompt, and two prompts on screen at once is not a thing a user can answer. Those run
/// one at a time; the rest share the pool.
@Suite("CaskUpgradeLanes")
struct CaskUpgradeLanesTests {

    private func profile(_ token: String, kinds: Set<CaskArtifactKind>) -> CaskArtifactProfile {
        CaskArtifactProfile(
            token: token,
            artifacts: kinds.map { CaskArtifact(kind: $0, names: ["\(token).thing"]) }
        )
    }

    @Test func appOnlyCasksShareThePool() {
        let lanes = CaskUpgradeLanes(
            tokens: ["figma", "slack"],
            profiles: [
                "figma": profile("figma", kinds: [.app]),
                "slack": profile("slack", kinds: [.app]),
            ]
        )

        #expect(lanes.concurrent == ["figma", "slack"])
        #expect(lanes.serial.isEmpty)
    }

    @Test func aPasswordPromptingCaskIsSerialised() {
        let lanes = CaskUpgradeLanes(
            tokens: ["figma", "zoom"],
            profiles: [
                "figma": profile("figma", kinds: [.app]),
                "zoom": profile("zoom", kinds: [.pkg]),
            ]
        )

        #expect(lanes.concurrent == ["figma"])
        #expect(lanes.serial == ["zoom"])
    }

    /// The map is only ever filled by a full scan: after `restoreLastScan()` it is empty.
    /// An unknown cask must not be assumed harmless — that is exactly the case that would
    /// put two Touch ID sheets on screen.
    @Test func anUnknownProfileIsTreatedAsPasswordPrompting() {
        let lanes = CaskUpgradeLanes(tokens: ["figma", "mystery"],
                                     profiles: ["figma": profile("figma", kinds: [.app])])

        #expect(lanes.concurrent == ["figma"])
        #expect(lanes.serial == ["mystery"])
    }

    /// Every token given must come back exactly once: a cask silently dropped by the split
    /// is a cask the run never upgrades and never reports.
    @Test func theSplitLosesNothing() {
        let tokens = ["a", "b", "c", "d"]
        let lanes = CaskUpgradeLanes(
            tokens: tokens,
            profiles: [
                "a": profile("a", kinds: [.app]),
                "b": profile("b", kinds: [.installer]),
                "c": profile("c", kinds: [.app, .binary]),
            ]
        )

        #expect(Set(lanes.concurrent + lanes.serial) == Set(tokens))
        #expect(lanes.concurrent.count + lanes.serial.count == tokens.count)
    }
}
```

The fixture matches the real initialisers: `CaskArtifactProfile(token:homepage:artifacts:)` with `homepage` defaulted, and `CaskArtifact(kind:names:)` (`Sources/MacUpdaterCore/Models.swift:363` and `:379`).

- [ ] **Step 2: Confirm the Red reason by reading**

`CaskUpgradeLanes` does not exist, so the suite does not compile. Do **not** run the suite.

- [ ] **Step 3: Write the implementation**

Create `Sources/MacUpdaterCore/CaskUpgradeLanes.swift`:

```swift
import Foundation

/// How one run's casks are split between the concurrent pool and the serial lane.
///
/// Casks are independent of each other — unlike formulae, which share dependencies — so
/// several may be upgraded at once. The exception is the admin-password prompt: `brew`
/// raises it from inside the cask's own `pkg` / `installer` / `preflight` stanza, and two
/// prompts racing for the screen is not a state a user can resolve. Those casks therefore
/// run one at a time, however much of the pool is free.
///
/// A cask with **no** known profile lands in the serial lane too. `caskProfiles` is filled
/// only by a full scan, so after `restoreLastScan()` it is empty — and "we don't know" must
/// not resolve to "safe to run three at once".
public struct CaskUpgradeLanes: Equatable, Sendable {
    /// Casks that install user-space artifacts only: safe several at a time.
    public let concurrent: [String]
    /// Casks that may raise an admin-password prompt, and casks whose profile is unknown.
    public let serial: [String]

    public init(tokens: [String], profiles: [String: CaskArtifactProfile]) {
        var concurrent: [String] = []
        var serial: [String] = []
        for token in tokens {
            if profiles[token]?.mayRequireAdminPassword == false {
                concurrent.append(token)
            } else {
                serial.append(token)
            }
        }
        self.concurrent = concurrent
        self.serial = serial
    }
}
```

Note the `== false` comparison: it makes the unknown-profile case (`nil`) fall to `serial` without a second branch, which is the behaviour the fourth test pins.

- [ ] **Step 4: Add the constant**

In `Sources/MacUpdaterCore/Constants.swift`, inside `public enum MacUpdaterConstants`, after `restartMap`:

```swift
    /// How many package-manager processes one update run may have in flight.
    ///
    /// A cask install is bound by disk and network, not by cores: past roughly three the
    /// wall-clock gain flattens while the chance of two `brew` processes colliding on a
    /// lock they both need — and the peak disk usage of several staged apps at once —
    /// keeps climbing. Deliberately a constant and not a setting: a fixed value keeps a
    /// "it was slow" report reproducible.
    public static let maxConcurrentUpgrades = 3
```

- [ ] **Step 5: Build and lint**

```bash
swift build && swiftlint lint --strict
```

Expected: builds clean, zero violations.

- [ ] **Step 6: Commit**

```bash
git add Sources/MacUpdaterCore/CaskUpgradeLanes.swift Sources/MacUpdaterCore/Constants.swift Tests/MacUpdaterTests/CaskUpgradeLanesTests.swift && git commit -m "feat(updates): split casks into a concurrent pool and a serial admin lane"
```

---

### Task 2: Recognise a Homebrew lock collision

**Files:**
- Modify: `Sources/MacUpdaterCore/BrewUpgradeOutcome.swift`
- Test: `Tests/MacUpdaterTests/BrewLockCollisionTests.swift`

**Interfaces:**
- Consumes: `BrewUpgradeOutcome.analyze(exitCode:output:)`, `.errorLines`.
- Produces: `BrewUpgradeOutcome.isHomebrewLockCollision: Bool`.

**Background:** Homebrew's `LockFile#lock` raises `OperationInProgressError`, whose message (`/opt/homebrew/Library/Homebrew/exceptions.rb`) reads:

```
Error: A `brew upgrade --cask figma` process has already locked /opt/homebrew/Caskroom/figma.
Please wait for it to finish or terminate it to continue.
```

The lock is per locked path, so two casks rarely collide — but a shared dependency or Homebrew's own bookkeeping can still make it happen once the run has three processes out. The stable phrase is `process has already locked`; the command inside the backticks varies, so it may not be matched on.

- [ ] **Step 1: Write the failing test**

Create `Tests/MacUpdaterTests/BrewLockCollisionTests.swift`:

```swift
import Testing
import Foundation
@testable import MacUpdaterCore

/// Running several `brew` processes at once introduces one failure the sequential run could
/// never produce: brew refusing because another brew already holds a lock it needs. Nothing
/// was installed when this happens, so it is the one brew failure that is safe to retry.
@Suite("BrewLockCollision")
struct BrewLockCollisionTests {

    private static let collision = """
    ==> Upgrading figma
    Error: A `brew upgrade --cask figma` process has already locked /opt/homebrew/Caskroom/figma.
    Please wait for it to finish or terminate it to continue.
    """

    @Test func aLockedPathIsRecognised() {
        let outcome = BrewUpgradeOutcome.analyze(exitCode: 1, output: Self.collision)
        #expect(outcome.isHomebrewLockCollision)
    }

    /// An ordinary cask failure must not be retried as if nothing had run — a retry after a
    /// real install failure repeats the failure and doubles the time it costs.
    @Test func anOrdinaryFailureIsNotALockCollision() {
        let output = """
        ==> Upgrading figma
        Error: figma: It seems there is already an App at '/Applications/Figma.app'.
        """
        #expect(!BrewUpgradeOutcome.analyze(exitCode: 1, output: output).isHomebrewLockCollision)
    }

    @Test func aCleanRunIsNotALockCollision() {
        let output = "==> Upgrading figma\nfigma was successfully upgraded!"
        #expect(!BrewUpgradeOutcome.analyze(exitCode: 0, output: output).isHomebrewLockCollision)
    }
}
```

- [ ] **Step 2: Confirm the Red reason by reading**

`isHomebrewLockCollision` does not exist, so the suite does not compile.

- [ ] **Step 3: Write the implementation**

In `Sources/MacUpdaterCore/BrewUpgradeOutcome.swift`, next to `tokensRetryableWithForce`:

```swift
    /// True when brew refused because another brew process already held a lock this one
    /// needs (`LockFile#lock` → `OperationInProgressError`).
    ///
    /// The only failure mode running casks concurrently adds. It is also the only brew
    /// failure where nothing was installed at all, which is what makes retrying it safe —
    /// unlike a failed install, where a blind retry just repeats the failure. Matched on
    /// the invariant half of the message: the command inside the backticks is whatever
    /// brew happened to be running, and the locked path is whatever it happened to lock.
    public var isHomebrewLockCollision: Bool {
        errorLines.contains { $0.contains("process has already locked") }
    }
```

- [ ] **Step 4: Build and lint**

```bash
swift build && swiftlint lint --strict
```

- [ ] **Step 5: Commit**

```bash
git add Sources/MacUpdaterCore/BrewUpgradeOutcome.swift Tests/MacUpdaterTests/BrewLockCollisionTests.swift && git commit -m "feat(updates): recognise a Homebrew lock collision as retryable"
```

---

### Task 3: Prefix streamed log lines with their package

**Files:**
- Create: `Sources/MacUpdaterCore/UpgradeLogPrefix.swift`
- Test: `Tests/MacUpdaterTests/UpgradeLogPrefixTests.swift`

**Interfaces:**
- Produces: `UpgradeLogPrefix.line(_:from:) -> String` and `UpgradeLogPrefix.lines(_:from:) -> [String]`.

- [ ] **Step 1: Write the failing test**

Create `Tests/MacUpdaterTests/UpgradeLogPrefixTests.swift`:

```swift
import Testing
import Foundation
@testable import MacUpdaterCore

/// With three processes streaming into one log, a line without a source is a line the
/// reader cannot attribute to anything.
@Suite("UpgradeLogPrefix")
struct UpgradeLogPrefixTests {

    @Test func aLineCarriesItsSource() {
        #expect(UpgradeLogPrefix.line("==> Downloading…", from: "figma") == "[figma] ==> Downloading…")
    }

    @Test func everyLineOfABatchCarriesIt() {
        let prefixed = UpgradeLogPrefix.lines(["a", "b"], from: "slack")
        #expect(prefixed == ["[slack] a", "[slack] b"])
    }

    /// An empty source would render as a bare `[] ` — noise that says nothing. The line is
    /// returned untouched instead.
    @Test func anEmptySourceAddsNothing() {
        #expect(UpgradeLogPrefix.line("plain", from: "") == "plain")
        #expect(UpgradeLogPrefix.lines(["plain"], from: "") == ["plain"])
    }
}
```

- [ ] **Step 2: Confirm the Red reason by reading**

`UpgradeLogPrefix` does not exist, so the suite does not compile.

- [ ] **Step 3: Write the implementation**

Create `Sources/MacUpdaterCore/UpgradeLogPrefix.swift`:

```swift
import Foundation

/// Marks a streamed log line with the package it came from.
///
/// The log panel is one flat list, and a run now feeds it from several processes at once.
/// Chronological order is still the honest order — but without a source a reader cannot
/// tell which of three concurrent downloads a `==> Downloading` line belongs to.
///
/// The prefix is a package token, not interface text: it is never translated.
public enum UpgradeLogPrefix {
    public static func line(_ line: String, from source: String) -> String {
        source.isEmpty ? line : "[\(source)] \(line)"
    }

    public static func lines(_ lines: [String], from source: String) -> [String] {
        guard !source.isEmpty else { return lines }
        return lines.map { "[\(source)] \($0)" }
    }
}
```

- [ ] **Step 4: Build and lint**

```bash
swift build && swiftlint lint --strict
```

- [ ] **Step 5: Commit**

```bash
git add Sources/MacUpdaterCore/UpgradeLogPrefix.swift Tests/MacUpdaterTests/UpgradeLogPrefixTests.swift && git commit -m "feat(updates): mark streamed log lines with the package they came from"
```

---

### Task 4: One process per row (still driven sequentially)

This task is a behaviour-preserving refactor: after it, the run does the same things in the same order, but a cask is upgraded by its **own** `brew` process rather than by one batched call. Nothing runs concurrently yet — that is Tasks 5 and 6. Splitting it this way means the risky "per-item outcome, per-item retry, per-item rollback verdict" change can be reviewed on its own, with the ordering unchanged.

**Files:**
- Create: `Sources/MacUpdater/ScanStore+UpgradeLanes.swift`
- Modify: `Sources/MacUpdater/ScanStore.swift` (add `inFlightItemCount`)
- Modify: `Sources/MacUpdater/ScanStore+Updating.swift` (remove `runBrewUpgrade`/`runNpmUpgrade`, call the new per-item path)
- Modify: `Sources/MacUpdaterCore/Translations.swift`

**Interfaces:**
- Consumes: `CaskUpgradeLanes`, `UpgradeLogPrefix`, `BrewUpgradeOutcome.isHomebrewLockCollision` (Tasks 1–3); `UpdatePlanner.caskUpgradeCommand(tokens:)`, `.forcedCaskCommand(tokens:)`; `ProcessEventStream.drain(_:onChunk:)` (`@MainActor`, returns `Int32`); `postCaskUpgrade(_:appPaths:snapshots:operation:)`; `ForegroundCaskPreparation` (`appPaths`, `snapshots`, `trustedCaskNames`, `operation`).
- Produces: `ScanStore.LaneItemResult`; `ScanStore.upgradeOneCask(item:appPaths:snapshots:operation:)`; `ScanStore.upgradeOneNpmPackage(item:)`; `ScanStore.runBrewUpgrade(arguments:logSource:streamsProgress:)`; `ScanStore.beginItem(named:)` / `endItem()` / `creditUnit()`.

- [ ] **Step 1: Add the in-flight counter**

In `Sources/MacUpdater/ScanStore.swift`, beside the other upgrade state (near `upgradeTracker` / `upgradeProgress`), add:

```swift
    /// How many planned rows have a process running right now.
    ///
    /// Not `@Published`: nothing renders the number itself. It decides only whether the
    /// progress bar may name the package it is installing — with several processes out,
    /// any single name is a claim about the other two as well.
    var inFlightItemCount = 0
```

- [ ] **Step 2: Create the per-item file**

Create `Sources/MacUpdater/ScanStore+UpgradeLanes.swift`:

```swift
import Foundation
import MacUpdaterCore

// MARK: - One planned row at a time
//
// ARCH-08 — the per-row half of an update run: the package-manager process for a single
// selected item, the two retries that apply to it, its progress unit and its log prefix.
// Deciding *what* to run is `ScanStore+UpdatePlan`; sequencing the lanes and reporting the
// run is `ScanStore+Updating`; the snapshot/canary net around a cask is `ScanStore+Rollback`.
extension ScanStore {

    /// What one lane produced for one planned row.
    ///
    /// A lane never touches the run's `UpdateRunOutcome`. It hands back what it produced and
    /// the orchestrator folds every lane's answer in once, in the plan's order — so the
    /// report never depends on which process happened to finish first.
    struct LaneItemResult: Sendable {
        let item: OutdatedItem
        /// `nil` when the run stopped before this row started. Never attempted is not the
        /// same as attempted and failed, and only one of the two may be reported.
        let outcome: BrewUpgradeOutcome?
        let validation: CaskValidationVerdict?

        init(item: OutdatedItem, outcome: BrewUpgradeOutcome?, validation: CaskValidationVerdict? = nil) {
            self.item = item
            self.outcome = outcome
            self.validation = validation
        }
    }

    // MARK: Progress accounting

    /// A row's process is starting.
    ///
    /// The bar may name the package only while it is the only one running: with several
    /// processes in flight, naming one of them misdescribes the other two, so the run falls
    /// back to the unnamed batch label the App Store phase already uses.
    func beginItem(named token: String) {
        inFlightItemCount += 1
        if inFlightItemCount > 1 {
            upgradeTracker?.beginInstallingBatch()
        } else {
            upgradeTracker?.beginInstalling(token: token)
        }
        upgradeProgress = upgradeTracker?.progress
    }

    func endItem() {
        inFlightItemCount = max(0, inFlightItemCount - 1)
    }

    /// One planned row finished successfully.
    ///
    /// Per-row lanes never feed the tracker's stream parser: it keeps a single line buffer
    /// and a single in-flight token, so several concurrent streams would corrupt both. They
    /// advance it explicitly instead — exactly as the npm loop always has.
    func creditUnit() {
        upgradeTracker?.completeUnits(1)
        upgradeProgress = upgradeTracker?.progress
    }

    // MARK: One cask

    /// Upgrades exactly one cask and returns its outcome together with the canary/rollback
    /// verdict for the same token.
    ///
    /// The verdict is produced here rather than in a phase after the whole run, so a build
    /// that fails the canary is restored while the other rows are still working.
    func upgradeOneCask(
        item: OutdatedItem,
        appPaths: [String: URL],
        snapshots: [String: URL],
        operation: UpdateOperationSession
    ) async -> LaneItemResult {
        let token = item.name
        beginItem(named: token)
        defer { endItem() }

        var outcome = await runBrewUpgrade(
            arguments: UpdatePlanner.caskUpgradeCommand(tokens: [token]).arguments,
            logSource: token,
            streamsProgress: false
        )

        // Two brew processes can collide on a lock they both need. Nothing was installed
        // when that happens — which is what makes one retry safe, and is the whole running
        // cost of upgrading casks concurrently.
        if outcome.isHomebrewLockCollision {
            brewLog.append(UpgradeLogPrefix.line(
                "↻ " + trf("Homebrew był zajęty (%@) — ponawiam.", "\(token)"), from: token))
            WegaLog.info(.homebrew, "Kolizja blokad Homebrew — ponawiam \(token)")
            try? await Task.sleep(for: .seconds(2))
            outcome = await runBrewUpgrade(
                arguments: UpdatePlanner.caskUpgradeCommand(tokens: [token]).arguments,
                logSource: token,
                streamsProgress: false
            )
        }

        // Auto-recover an interrupted upgrade: brew bails because a stale staged app from a
        // previous, cut-short run occupies the destination. `--force` overwrites it.
        if outcome.tokensRetryableWithForce.contains(token) {
            brewLog.append(UpgradeLogPrefix.line(
                "↻ " + trf("Przerwana aktualizacja (%@) — ponawiam z --force.", "\(token)"), from: token))
            WegaLog.info(.homebrew, "Przerwana aktualizacja casku — ponawiam z --force: \(token)")
            let retry = await runBrewUpgrade(
                arguments: UpdatePlanner.forcedCaskCommand(tokens: [token]).arguments,
                logSource: token,
                streamsProgress: false
            )
            outcome = BrewUpgradeOutcome.merging(original: outcome, forcedRetry: retry, retriedTokens: [token])
        }

        let verdicts = await postCaskUpgrade(
            [token], appPaths: appPaths, snapshots: snapshots, operation: operation
        )
        if outcome.isSuccessful { creditUnit() }
        return LaneItemResult(item: item, outcome: outcome, validation: verdicts[token])
    }

    // MARK: One npm package

    func upgradeOneNpmPackage(item: OutdatedItem) async -> LaneItemResult {
        let name = item.name
        beginItem(named: name)
        defer { endItem() }

        let outcome = await runNpmUpgrade(name: name)
        if outcome.isSuccessful { creditUnit() }
        return LaneItemResult(item: item, outcome: outcome)
    }

    // MARK: The processes

    /// Runs `brew <arguments>` streaming output into the log, and returns an outcome that
    /// reflects whether brew *actually* succeeded — exit code 0 alone is unreliable for cask
    /// upgrades.
    ///
    /// `streamsProgress` is true only for the single formula call. The tracker parses one
    /// stream with one line buffer, so nothing else may feed it: see `creditUnit()`.
    func runBrewUpgrade(
        arguments: [String],
        logSource: String,
        streamsProgress: Bool
    ) async -> BrewUpgradeOutcome {
        guard let model else { return BrewUpgradeOutcome(exitCode: -1, failedTokens: [], errorLines: []) }
        brewLog.append(UpgradeLogPrefix.line("$ brew \(arguments.joined(separator: " "))", from: logSource))
        var captured = ""
        var exitCode: Int32 = 0
        do {
            let stream = try model.brewService.events(arguments: arguments)
            exitCode = try await ProcessEventStream.drain(stream) { chunk in
                captured += chunk
                brewLog = ProcessEventStream.appendingCapped(
                    UpgradeLogPrefix.lines(ProcessEventStream.lines(from: chunk), from: logSource),
                    to: brewLog
                )
                if streamsProgress { upgradeProgress = upgradeTracker?.consume(chunk: chunk) }
            }
        } catch {
            brewLog.append(UpgradeLogPrefix.line("error: \(error.localizedDescription)", from: logSource))
            if streamsProgress {
                upgradeTracker?.brewCallFinished(succeeded: false)
                upgradeProgress = upgradeTracker?.progress
            }
            return BrewUpgradeOutcome(exitCode: -1, failedTokens: [], errorLines: [error.localizedDescription])
        }
        let outcome = BrewUpgradeOutcome.analyze(exitCode: exitCode, output: captured)
        if streamsProgress {
            upgradeTracker?.brewCallFinished(succeeded: outcome.isSuccessful)
            upgradeProgress = upgradeTracker?.progress
        }
        return outcome
    }

    func runNpmUpgrade(name: String) async -> BrewUpgradeOutcome {
        guard let model else { return BrewUpgradeOutcome(exitCode: -1, failedTokens: [name], errorLines: []) }
        brewLog.append(UpgradeLogPrefix.line("$ npm install -g -- \(name)@latest", from: name))
        var exitCode: Int32 = 0
        do {
            let stream = try await model.npmService.upgradeEvents(name: name)
            exitCode = try await ProcessEventStream.drain(stream) { chunk in
                brewLog = ProcessEventStream.appendingCapped(
                    UpgradeLogPrefix.lines(ProcessEventStream.lines(from: chunk), from: name),
                    to: brewLog
                )
            }
        } catch {
            brewLog.append(UpgradeLogPrefix.line("error: \(error.localizedDescription)", from: name))
            return BrewUpgradeOutcome(exitCode: -1, failedTokens: [name], errorLines: [error.localizedDescription])
        }
        return BrewUpgradeOutcome(exitCode: exitCode, failedTokens: exitCode == 0 ? [] : [name], errorLines: [])
    }
}
```

Two notes for the implementer:

- `runNpmUpgrade` no longer takes `arguments:`. The old signature accepted them and then ignored them — `npmService.upgradeEvents(name:)` builds its own. The `$ npm …` log line is now written from the same shape `UpdatePlanner` emits (`install -g -- <pkg>@latest`), which is what the preview panel shows.
- `postCaskUpgrade` already writes its own `brewLog` lines. Leave them unprefixed for now; they already name their token in the message text.

- [ ] **Step 3: Delete the old batch call sites**

In `Sources/MacUpdater/ScanStore+Updating.swift`:

- Delete the `private func runBrewUpgrade(arguments:)` and `private func runNpmUpgrade(name:arguments:)` definitions — they now live in `ScanStore+UpgradeLanes.swift` with the new signatures.
- In the cask block, replace the batched call, the `--force` retry and the `run.record(trustedItems, outcome:)` / `run.applyValidation(await postCaskUpgrade(…))` pair with a loop over the trusted casks (still sequential in this task):

```swift
            if !caskNames.isEmpty {
                // LT-01 — the last line before the mutation: a crash after it reads as
                // "disk state unknown, probe me", a crash before it reads as "never ran".
                caskPreparation.operation.recordInstalling()
                for token in caskNames {
                    guard let item = plannedItems.first(where: { $0.kind == .cask && $0.name == token }) else { continue }
                    let result = await upgradeOneCask(
                        item: item,
                        appPaths: appPaths,
                        snapshots: snapshots,
                        operation: caskPreparation.operation
                    )
                    fold(result, into: &run)
                }
            } else {
```

- Replace the npm loop body's call with the per-item one:

```swift
        for (index, pkg) in npmNames.enumerated() {
            if shouldStopUpdate(before: boundaries.fromNpmPackage(at: index)) { break }
            guard let item = plannedItems.first(where: { $0.kind == .npm && $0.name == pkg }) else { continue }
            fold(await upgradeOneNpmPackage(item: item), into: &run)
        }
```

  `npmCommands` and the `zip(...)` become unused — delete the `let npmCommands = …` binding.

- The formula call keeps the batched shape and is the only caller that streams progress:

```swift
        if let formulaArgs {
            let outcome = await runBrewUpgrade(arguments: formulaArgs, logSource: "brew", streamsProgress: true)
            run.record(plannedItems.filter { $0.kind == .formula }, outcome: outcome)
        }
```

- Add the folding helper at the end of the extension in `ScanStore+Updating.swift`:

```swift
    /// Folds one row's lane result into the run.
    ///
    /// A result with no outcome is a row the stop switch caught before it started: it is
    /// already recorded as skipped by `shouldStopUpdate`, and adding a verdict for it here
    /// would report a row nothing ever attempted.
    func fold(_ result: LaneItemResult, into run: inout UpdateRunOutcome) {
        guard let outcome = result.outcome else { return }
        run.record([result.item], outcome: outcome)
        if let validation = result.validation {
            run.applyValidation([result.item.name: validation])
        }
    }
```

- The `$ mas upgrade …` log line gains its prefix:

```swift
            brewLog.append(UpgradeLogPrefix.line("$ mas upgrade " + masAppStoreIDs.joined(separator: " "), from: "mas"))
```

  and the lines it appends from `result.stdout`:

```swift
                brewLog.append(contentsOf: UpgradeLogPrefix.lines(lines, from: "mas"))
```

  and its error line:

```swift
                brewLog.append(UpgradeLogPrefix.line("error: \(error.localizedDescription)", from: "mas"))
```

- [ ] **Step 4: Add the English string**

In `Sources/MacUpdaterCore/Translations.swift`, beside the existing `"Przerwana aktualizacja (%@) — ponawiam z --force."` entry:

```swift
        "Homebrew był zajęty (%@) — ponawiam.": "Homebrew was busy (%@) — retrying.",
```

- [ ] **Step 5: Build and lint**

```bash
swift build && swiftlint lint --strict
```

Expected: builds clean. If SwiftLint reports `function_body_length` on `runUpdateCoordinated`, that is real signal — the orchestrator is doing too much and Task 6 shrinks it. Do not add a suppression; if the violation appears in this task, move the cask block into a `runCaskPhase(...)` method in `ScanStore+UpgradeLanes.swift` now rather than later.

- [ ] **Step 6: Commit**

```bash
git add Sources/MacUpdater Sources/MacUpdaterCore/Translations.swift && git commit -m "refactor(updates): give every cask and npm package its own process"
```

---

### Task 5: Bounded lanes and a per-row stop gate

**Files:**
- Modify: `Sources/MacUpdaterCore/BoundedConcurrency.swift`
- Modify: `Sources/MacUpdater/ScanStore+UpgradeLanes.swift`
- Modify: `Sources/MacUpdater/ScanStore+Updating.swift`
- Test: `Tests/MacUpdaterTests/BoundedConcurrencyMainActorTests.swift`

**Interfaces:**
- Consumes: `runBounded(limit:_:)`, `MacUpdaterConstants.maxConcurrentUpgrades`, `CaskUpgradeLanes`, `shouldStopUpdate(before:)`.
- Produces: `runBoundedOnMainActor(limit:_:)`; `ScanStore.runCaskLane(items:preparation:)`; `ScanStore.runNpmLane(items:names:)`.

- [ ] **Step 1: Write the failing test for the pool**

Create `Tests/MacUpdaterTests/BoundedConcurrencyMainActorTests.swift`:

```swift
import Testing
import Foundation
@testable import MacUpdaterCore

/// The upgrade pool runs on the main actor: every task in it spends its life awaiting a
/// subprocess, and an `await` releases the actor, so the work overlaps while the state it
/// touches stays on one actor and needs no lock.
@Suite("BoundedConcurrencyOnMainActor")
struct BoundedConcurrencyMainActorTests {

    /// Counts how many jobs were in flight at once. Main-actor isolated, so the counter
    /// needs no synchronisation of its own — which is the property under test.
    @MainActor
    final class Meter {
        var inFlight = 0
        var peak = 0
        func enter() { inFlight += 1; peak = max(peak, inFlight) }
        func leave() { inFlight -= 1 }
    }

    @MainActor
    @Test func neverMoreThanTheLimitRunAtOnce() async {
        let meter = Meter()
        let work: [@MainActor () async -> Int] = (0..<9).map { index in
            {
                meter.enter()
                try? await Task.sleep(for: .milliseconds(20))
                meter.leave()
                return index
            }
        }

        let results = await runBoundedOnMainActor(limit: 3, work)

        #expect(meter.peak <= 3)
        #expect(results.sorted() == Array(0..<9))
    }

    /// A cap larger than the work list must not stall waiting for tasks that do not exist.
    @MainActor
    @Test func aLimitAboveTheWorkCountStillCompletes() async {
        let work: [@MainActor () async -> Int] = [{ 1 }, { 2 }]
        #expect(await runBoundedOnMainActor(limit: 10, work).sorted() == [1, 2])
    }

    @MainActor
    @Test func anEmptyWorkListReturnsNothing() async {
        let work: [@MainActor () async -> Int] = []
        #expect(await runBoundedOnMainActor(limit: 3, work).isEmpty)
    }
}
```

- [ ] **Step 2: Confirm the Red reason by reading**

`runBoundedOnMainActor` does not exist, so the suite does not compile.

- [ ] **Step 3: Add the main-actor pool**

Append to `Sources/MacUpdaterCore/BoundedConcurrency.swift`:

```swift
/// The `@MainActor` variant of `runBounded`.
///
/// An upgrade's work is not CPU work: each of these tasks starts a package-manager process
/// and then waits for it. `await` releases the actor, so the processes genuinely overlap
/// while every piece of state the tasks touch — the log, the progress tracker, the rollback
/// ledger, the operation journal — stays on a single actor. That is why the concurrent
/// upgrade path introduces no lock and no shared mutable buffer.
///
/// A `limit <= 0` is treated as "no cap" (run everything at once).
@MainActor
public func runBoundedOnMainActor<T: Sendable>(
    limit: Int,
    _ work: [@MainActor () async -> T]
) async -> [T] {
    guard !work.isEmpty else { return [] }
    let cap = limit <= 0 ? work.count : min(limit, work.count)

    var results: [T] = []
    results.reserveCapacity(work.count)

    await withTaskGroup(of: T.self) { group in
        var next = 0
        while next < cap {
            let job = work[next]
            group.addTask { @MainActor in await job() }
            next += 1
        }
        for await result in group {
            results.append(result)
            if next < work.count {
                let job = work[next]
                group.addTask { @MainActor in await job() }
                next += 1
            }
        }
    }

    return results
}
```

If Swift 6 rejects capturing `job` in the task closure, mark the parameter `[@MainActor @Sendable () async -> T]` and pass `@MainActor @Sendable` closures at the call sites — a global-actor-isolated closure is `Sendable`. Do not reach for `@unchecked Sendable` or `nonisolated(unsafe)`.

- [ ] **Step 4: Add the lanes**

In `Sources/MacUpdater/ScanStore+UpgradeLanes.swift`, add to the extension:

```swift
    // MARK: Lanes

    /// Every trusted cask of this plan: at most `maxConcurrentUpgrades` at a time, and the
    /// ones that may raise an admin-password prompt strictly one at a time, so at most one
    /// Touch ID sheet is ever on screen.
    ///
    /// Results come back in the plan's order rather than the order the pool finished in: a
    /// report that reordered itself run to run would be unreadable, and the log already
    /// carries the real chronology.
    func runCaskLane(
        items: [OutdatedItem],
        preparation: ForegroundCaskPreparation
    ) async -> [LaneItemResult] {
        let lanes = CaskUpgradeLanes(tokens: preparation.trustedCaskNames, profiles: caskProfiles)
        let itemsByToken = Dictionary(
            items.filter { $0.kind == .cask }.map { ($0.name, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        let pooled: [@MainActor () async -> LaneItemResult] = lanes.concurrent.compactMap { token in
            guard let item = itemsByToken[token] else { return nil }
            return { await self.upgradeCaskGated(item: item, preparation: preparation) }
        }
        var results = await runBoundedOnMainActor(
            limit: MacUpdaterConstants.maxConcurrentUpgrades, pooled
        )

        for token in lanes.serial {
            guard let item = itemsByToken[token] else { continue }
            results.append(await upgradeCaskGated(item: item, preparation: preparation))
        }

        let byKey = Dictionary(results.map { ($0.item.key, $0) }, uniquingKeysWith: { first, _ in first })
        return items.compactMap { byKey[$0.key] }
    }

    func runNpmLane(items: [OutdatedItem], names: [String]) async -> [LaneItemResult] {
        let itemsByName = Dictionary(
            items.filter { $0.kind == .npm }.map { ($0.name, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let pooled: [@MainActor () async -> LaneItemResult] = names.compactMap { name in
            guard let item = itemsByName[name] else { return nil }
            return {
                guard !self.shouldStopUpdate(before: [item.key]) else {
                    return LaneItemResult(item: item, outcome: nil)
                }
                return await self.upgradeOneNpmPackage(item: item)
            }
        }
        let results = await runBoundedOnMainActor(
            limit: MacUpdaterConstants.maxConcurrentUpgrades, pooled
        )
        let byKey = Dictionary(results.map { ($0.item.key, $0) }, uniquingKeysWith: { first, _ in first })
        return items.compactMap { byKey[$0.key] }
    }

    /// REL-12 — the stop switch moved from "before a phase" to "before a row is let out of
    /// the queue". A row already running finishes: killing `brew` mid-install leaves a
    /// half-replaced bundle in /Applications, which is the very state the `--force` retry
    /// exists to repair. A row that never started is recorded as skipped and reports nothing.
    private func upgradeCaskGated(
        item: OutdatedItem,
        preparation: ForegroundCaskPreparation
    ) async -> LaneItemResult {
        guard !shouldStopUpdate(before: [item.key]) else {
            return LaneItemResult(item: item, outcome: nil)
        }
        return await upgradeOneCask(
            item: item,
            appPaths: preparation.appPaths,
            snapshots: preparation.snapshots,
            operation: preparation.operation
        )
    }
```

- [ ] **Step 5: Call the lanes**

In `Sources/MacUpdater/ScanStore+Updating.swift`, replace the sequential cask loop from Task 4 with:

```swift
                for result in await runCaskLane(items: plannedItems, preparation: caskPreparation) {
                    fold(result, into: &run)
                }
```

and the npm loop with:

```swift
        for result in await runNpmLane(items: plannedItems, names: npmNames) {
            fold(result, into: &run)
        }
```

The `boundaries.afterFormulae` and `boundaries.fromNpmPackage(at:)` gates go away — each row now gates on its own key inside the lane. Keep the zeroth boundary (`shouldStopUpdate(before: Array(plannedKeys))`) exactly as it is, and keep `let boundaries = UpgradeBoundaryKeys(...)` only if something still reads it; if nothing does, delete the binding but **leave `UpgradeBoundaryKeys` itself untouched** — it has its own tests, and removing its projections would mean editing pre-existing tests.

- [ ] **Step 6: Build and lint**

```bash
swift build && swiftlint lint --strict
```

- [ ] **Step 7: Commit**

```bash
git add Sources Tests/MacUpdaterTests/BoundedConcurrencyMainActorTests.swift && git commit -m "feat(updates): run casks and npm packages through a bounded pool"
```

---

### Task 6: The four lanes run at the same time

**Files:**
- Modify: `Sources/MacUpdater/ScanStore+Updating.swift`
- Modify: `Sources/MacUpdater/ScanStore+UpgradeLanes.swift`
- Test: `Tests/MacUpdaterTests/ConcurrentUpdateRunTests.swift`

**Interfaces:**
- Consumes: `runCaskLane`, `runNpmLane`, `fold(_:into:)`, `ScanStoreSources`.
- Produces: `ScanStore.runFormulaLane(items:arguments:)`, `ScanStore.runMasLane(items:appStoreIDs:)`.

- [ ] **Step 1: Write the failing guard test**

`ScanStore` lives in the app target, which this bundle cannot import, so its wiring is asserted at source level — the same pattern `UpdatePlanFidelityTests` uses for REL-04.

Create `Tests/MacUpdaterTests/ConcurrentUpdateRunTests.swift`:

```swift
import Testing
import Foundation
@testable import MacUpdaterCore

/// A selection of several updates runs its processes side by side.
///
/// The window's upgrade path lives behind a live `BrewService` a unit test cannot stand in
/// for, so — as `UpdatePlanFidelityTests` does for REL-04 — the wiring is asserted against
/// the source of the type itself.
@Suite("ConcurrentUpdateRun")
struct ConcurrentUpdateRunTests {

    private func scanStore() throws -> String { try ScanStoreSources.everything() }

    /// The regression: casks used to go out as one `brew upgrade --cask a b c`, which brew
    /// then installed one at a time. Each row now owns its process.
    @Test func casksAreNotUpgradedAsOneBatch() throws {
        let text = try scanStore()
        #expect(text.contains("caskUpgradeCommand(tokens: [token])"),
                "each cask must be upgraded by its own brew process, one token per call")
        #expect(!text.contains("caskUpgradeCommand(tokens: caskNames)"),
                "a batched cask upgrade is the sequential behaviour this replaced")
    }

    /// The pool cap is the shared constant, never a number written at the call site.
    @Test func thePoolUsesTheSharedLimit() throws {
        let text = try scanStore()
        #expect(text.contains("MacUpdaterConstants.maxConcurrentUpgrades"),
                "the concurrency limit belongs in one place")
    }

    /// The four lanes overlap. `async let` is what makes an npm package upgrade while brew
    /// is still working, which is most of the wall-clock this change buys.
    @Test func theLanesStartTogether() throws {
        let text = try scanStore()
        #expect(text.contains("async let"),
                "the lanes must be started together, not awaited one after another")
    }

    /// The tracker keeps one line buffer and one in-flight token; several concurrent streams
    /// would corrupt both. Only the single formula call may stream into it.
    @Test func onlyOneCallStreamsIntoTheProgressTracker() throws {
        let text = try scanStore()
        #expect(text.contains("streamsProgress: true"))
        #expect(text.range(of: "streamsProgress: true", options: .backwards) ==
                text.range(of: "streamsProgress: true"),
                "exactly one call site may feed the tracker's stream parser")
    }
}
```

- [ ] **Step 2: Confirm the Red reason by reading**

After Task 5 the source contains `caskUpgradeCommand(tokens: [token])` and the shared constant, so those two pass already — they are regression pins, and pinning them here is the point. `async let` is absent, so `theLanesStartTogether` fails. Do not run the suite.

- [ ] **Step 3: Extract the remaining two lanes**

In `Sources/MacUpdater/ScanStore+UpgradeLanes.swift`:

```swift
    /// The formula batch. One `brew upgrade` for all of them, because they share
    /// dependencies: split into a process each, brew would build the same dependency several
    /// times over and the run would get slower, not faster. This is also the only call that
    /// streams into the progress tracker.
    func runFormulaLane(items: [OutdatedItem], arguments: [String]) async -> [LaneItemResult] {
        let formulae = items.filter { $0.kind == .formula }
        guard !formulae.isEmpty else { return [] }
        let outcome = await runBrewUpgrade(arguments: arguments, logSource: "brew", streamsProgress: true)
        return formulae.map { LaneItemResult(item: $0, outcome: outcome) }
    }

    /// The App Store batch. `mas` reports no per-app result, so one failure becomes the same
    /// failure for every planned row — and the bar advances by the whole batch or not at all,
    /// because a failed `mas upgrade` is no evidence any single app updated.
    func runMasLane(items: [OutdatedItem], appStoreIDs: [String]) async -> (items: [OutdatedItem], failure: String?) {
        let appStoreItems = items.filter { $0.kind == .appStore }
        guard let model, !appStoreIDs.isEmpty, !appStoreItems.isEmpty else { return ([], nil) }
        guard !shouldStopUpdate(before: appStoreItems.map(\.key)) else { return ([], nil) }

        beginItem(named: "")
        defer { endItem() }
        brewLog.append(UpgradeLogPrefix.line("$ mas upgrade " + appStoreIDs.joined(separator: " "), from: "mas"))

        do {
            let result = try await model.masService.upgrade(appStoreIDs: appStoreIDs)
            let lines = result.stdout.components(separatedBy: "\n").filter { !$0.isEmpty }
            brewLog.append(contentsOf: UpgradeLogPrefix.lines(lines, from: "mas"))
            upgradeTracker?.completeUnits(appStoreItems.count)
            upgradeProgress = upgradeTracker?.progress
            return (appStoreItems, nil)
        } catch {
            brewLog.append(UpgradeLogPrefix.line("error: \(error.localizedDescription)", from: "mas"))
            WegaLog.error(.app, "mas upgrade: \(error.localizedDescription)")
            return (appStoreItems, error.localizedDescription)
        }
    }
```

`beginItem(named: "")` deliberately passes an empty token: mas names no app, so the bar must not name one. `beginItem` still increments the in-flight count, which is what makes the other lanes fall back to the batch label while mas is working.

- [ ] **Step 4: Start the lanes together**

In `Sources/MacUpdater/ScanStore+Updating.swift`, replace the sequential lane calls with:

```swift
        // The four lanes overlap: brew's formula batch, the cask pool, the npm pool and the
        // App Store batch touch four different tools and four different sets of paths. The
        // rescan below is what waits for all of them.
        async let formulaResults = runFormulaLane(items: plannedItems, arguments: formulaArgs ?? [])
        async let caskResults    = runCaskLane(items: plannedItems, preparation: caskPreparation)
        async let npmResults     = runNpmLane(items: plannedItems, names: npmNames)
        async let masResult      = runMasLane(items: plannedItems, appStoreIDs: masAppStoreIDs)

        // Folded in the plan's order, never the order the lanes finished in: a report that
        // reshuffled itself run to run would be unreadable, and the log carries the real
        // chronology already.
        for result in await formulaResults + caskResults + npmResults {
            fold(result, into: &run)
        }
        let mas = await masResult
        if !mas.items.isEmpty { run.record(masItems: mas.items, failure: mas.failure) }
```

Restructuring notes the implementer has to resolve:

- `caskPreparation` is an optional. Keep the existing `guard`/`if let` shape: when there is no cask preparation (no casks planned, or the run was stopped before it) the cask lane must not start, and the `abortUnfinished()` / `removeOperation(id:)` clean-up in the `else` branch must stay exactly as it is. The simplest form that preserves it is to compute `let caskItems = caskPreparation.map { … }` before the `async let` block and pass an empty lane when it is `nil`; add a `runCaskLane` overload taking `ForegroundCaskPreparation?` that returns `[]` for `nil` rather than duplicating the branch at the call site.
- `caskPreparation.operation.recordInstalling()` must still run **before** the first cask process starts — move it to the top of `runCaskLane`, guarded so it runs once.
- `run.recordPublisherVetoes(...)` stays where it is, before the lanes: it is about casks that were never attempted.
- Preparation (`prepareForegroundCasks`) stays **before** the lanes, exactly as today. Its `.blocked` path still returns from the whole run. Moving it inside the cask lane would let a resource-gate postponement stop cancelling npm and App Store work, but that is a user-visible behaviour change the spec did not ask for — leave it.

- [ ] **Step 5: Build and lint**

```bash
swift build && swiftlint lint --strict
```

Expected: builds clean. `runUpdateCoordinated` should now be materially shorter than before Task 4.

- [ ] **Step 6: Commit**

```bash
git add Sources Tests/MacUpdaterTests/ConcurrentUpdateRunTests.swift && git commit -m "feat(updates): run the four update lanes at the same time"
```

---

### Task 7: Documentation

**Files:**
- Modify: `docs/features.md`

**Interfaces:** none.

- [ ] **Step 1: Document the user-visible behaviour**

In `docs/features.md`, in the `#### Running the update` section, add a paragraph (the file is written in English, in the same dense style as its neighbours):

```markdown
**Selected updates run side by side.** A run no longer walks its selection one package at a
time: each cask and each npm global gets its own package-manager process, with at most three
in flight, while the Homebrew formula batch and the App Store batch run alongside them.
Formulae stay one `brew upgrade` on purpose — they share dependencies, and a process each
would rebuild the same dependency several times over. Casks whose stanza can raise an
admin-password prompt (`pkg`, `installer`, `preflight`) are upgraded strictly one at a time,
as is any cask whose artifact profile is not known, so two Touch ID sheets can never compete
for the screen. The live log prefixes every line with the package it came from
(`[figma] ==> Downloading…`), and the progress bar counts whole packages — naming the one
that is installing only while it is the only one. **Stop** still stops at a package boundary:
the processes already running finish, nothing new is started, and everything still queued is
reported as skipped rather than as anything else.
```

Check the surrounding lines for the file's wrapping convention and match it.

- [ ] **Step 2: Verify nothing else went stale**

```bash
grep -n "strictly sequential" docs/features.md
```

Expected: one hit, on the **scan** (`brew → mas → npm → manual`). That sentence is about a different operation and stays as it is. If a second hit appears about the update run, fix it.

- [ ] **Step 3: Commit**

```bash
git add docs/features.md && git commit -m "docs(updates): describe concurrent update lanes"
```

---

## Self-Review

**Spec coverage**

| Spec requirement | Task |
|---|---|
| per-cask process, pool of 3 | 1, 4, 5 |
| formulae stay one call | 6 (`runFormulaLane`) |
| App Store stays one call | 6 (`runMasLane`) |
| npm packages in a pool | 5 (`runNpmLane`) |
| four lanes overlap | 6 |
| admin-password casks serialised | 1, 5 |
| unknown profile treated as password-prompting | 1 |
| `@MainActor` model, no locks | 5 (`runBoundedOnMainActor`) |
| log prefix per source | 3, 4 |
| tracker streamed only from the formula call | 4 (`streamsProgress`), 6 (guard test) |
| `beginInstallingBatch()` when several are in flight | 4 (`beginItem`) |
| rollback verdict inside the per-cask pipeline | 4 (`upgradeOneCask`) |
| stop: finish in flight, skip the queue | 5 (`upgradeCaskGated`) |
| lock collision retried once | 2, 4 |
| `--force` retry per row | 4 |
| docs sentence in `features.md` | 7 |

**Known follow-up (not in this plan):** once Task 5 lands, `UpgradeBoundaryKeys.afterFormulae` and `.fromNpmPackage(at:)` have no caller in the app, though their own tests still cover them. Removing them means editing pre-existing tests, which needs the user's approval — report it at handoff rather than doing it.

**Type consistency check:** `LaneItemResult` is spelled the same in Tasks 4, 5 and 6; `runBrewUpgrade(arguments:logSource:streamsProgress:)` keeps that signature from its definition in Task 4 through every call site in Tasks 4–6; `runBoundedOnMainActor(limit:_:)` matches between `BoundedConcurrency.swift`, its test, and both lanes; `MacUpdaterConstants.maxConcurrentUpgrades` is referenced by the same name in Tasks 1, 5 and the Task 6 guard.
