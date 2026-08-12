# Stale Catalog Overlay Generation Guard — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop a user catalog overlay whose `generation` is older than the bundled catalog's from shadowing freshly shipped catalog data, and stop the refresher from writing such an overlay in the first place.

**Architecture:** One rule enforced on both ends of the catalog channel — never serve or store catalog data older than the build. On read, `AppCatalog.loadShared()` compares the overlay's generation against the bundled catalog's through the existing `CatalogGenerationPolicy.accepts` and drops the whole overlay when it is older. On fetch, `CatalogGenerationLedger` gains a floor that `CatalogRefresher` defaults to the build's own generation, so a below-floor catalog is refused as `.replayRejected` instead of landing on disk.

**Tech Stack:** Swift 5.9+ / SwiftPM, XCTest (`Tests/MacUpdaterTests`), swift-testing (`@Suite`/`@Test`, used by `SEC07CatalogEnvelopeTests`), SwiftLint.

**Spec:** `docs/superpowers/specs/2026-08-12-stale-catalog-overlay-generation-guard-design.md`

## Global Constraints

- Branch: `fix/stale-catalog-overlay-generation-guard-2026-08-12`, worktree `.claude/worktrees/gifted-lederberg-aa11ac`. Never commit to `main`.
- The gate after every code change is `swift build && swiftlint lint --strict`. **Do not run test suites** — the user has not asked for a test run. Write the tests, leave Red→Green unconfirmed, and say so in the handoff.
- User-facing log strings are Polish, matching the existing `WegaLog` calls in `AppCatalog.swift`.
- Never add AI attribution (`Co-Authored-By`, "Generated with…") to any commit.
- `Tests/MacUpdaterTests` is the Core test target; it already depends on `WegaTestSupport` (see `Package.swift:64`), so `TestDefaults.isolated(_:)` is importable there.
- `ArchitectureReviewRegressionTests` fails the build if a test builds a `UserDefaults` suite by hand — always use `TestDefaults.isolated(_:)`.
- The bundled catalog currently ships `generation: 3` (inside the signed envelope in `Sources/MacUpdaterCore/Resources/app-catalog.json`). Never hard-code `3` in a test; tests construct their own catalogs in memory.
- Equality must stay accepted (`>=`, not `>`): re-serving the same publication is ordinary, not an attack.

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `Sources/MacUpdaterCore/AppCatalog.swift` | Catalog model, merge, load. Gains `bundledGeneration` and the IO-free `resolve(bundled:overlay:)` guard. | Modify |
| `Sources/MacUpdaterCore/CatalogGeneration.swift` | Generation policy + persisted watermark. Gains the injectable `floor`. | Modify |
| `Sources/MacUpdaterCore/CatalogRefresher.swift` | OTA fetch. Its default ledger is floored at the build's generation. | Modify |
| `Tests/MacUpdaterTests/AppCatalogTests.swift` | Regression coverage for the load-time guard and the ledger floor. | Modify (append) |
| `Tests/MacUpdaterTests/SEC07CatalogEnvelopeTests.swift` | One new refresher-level test for the floor. | Modify (append test) |
| `Tests/MacUpdaterTests/CatalogRefresherTests.swift` | One pre-existing test gets a floor-0 ledger injected. | Modify (approved) |
| `Tests/MacUpdaterTests/CatalogSignaturePersistenceTests.swift` | Three pre-existing tests get a floor-0 ledger injected. | Modify (approved) |
| `RELEASING.md` | Publishing rule: generation must also be ≥ the shipping build's. | Modify |

---

### Task 1: Load-time guard — a stale overlay stops winning

**Files:**
- Modify: `Sources/MacUpdaterCore/AppCatalog.swift:219-232` (`overlaying(_:)` doc comment), `:250-254` (`loadShared`)
- Test: `Tests/MacUpdaterTests/AppCatalogTests.swift` (append before the closing brace)

**Interfaces:**
- Consumes: `CatalogGenerationPolicy.accepts(candidate: Int, accepted: Int) -> Bool` (existing, `Sources/MacUpdaterCore/CatalogGeneration.swift:18`); `WegaLog.error(_:_:)` as already called at `AppCatalog.swift:284`.
- Produces:
  - `AppCatalog.bundledGeneration: Int` (`public static let`) — consumed by Task 3.
  - `AppCatalog.resolve(bundled: AppCatalog, overlay: AppCatalog) -> AppCatalog` (internal `static`) — consumed by this task's tests only.

- [ ] **Step 1: Write the failing tests**

Append inside `final class AppCatalogTests: XCTestCase`, before its closing brace:

```swift
    // MARK: Overlay generation guard — a stale overlay must not shadow the build
    //
    // Zgłoszone 2026-08-12: flaga `selfUpdates` pojechała w buildzie generacji 3, a overlay
    // generacji 1 sprzed istnienia tego klucza dalej zasłaniał wpis VS Code — akcja została
    // „GitHub Releases" zamiast „Otwórz aplikację", bo `selfUpdates` zdekodowało się do
    // domyślnego `false`.

    func testStaleOverlayDoesNotShadowTheBundledCatalog() throws {
        let bundled = AppCatalog(
            generation: 3,
            github: [GitHubCatalogEntry(
                bundleId: "com.microsoft.VSCode",
                repo: "microsoft/vscode",
                caskToken: "visual-studio-code",
                selfUpdates: true
            )]
        )
        let overlay = AppCatalog(
            generation: 1,
            github: [GitHubCatalogEntry(
                bundleId: "com.microsoft.VSCode",
                repo: "microsoft/vscode",
                caskToken: "visual-studio-code"
            )]
        )

        let entry = try XCTUnwrap(
            AppCatalog.resolve(bundled: bundled, overlay: overlay).githubRepos["com.microsoft.VSCode"]
        )

        XCTAssertTrue(entry.selfUpdates, "overlay starszej generacji nie może zasłonić builda")
    }

    /// Overlay starszej generacji jest odrzucany **w całości**: generacja opisuje publikację,
    /// nie wpis, więc mieszanie dałoby katalog, dla którego żadna generacja nie jest prawdziwa.
    func testStaleOverlayIsRejectedWholesaleIncludingItsNewApps() {
        let bundled = AppCatalog(generation: 3)
        let overlay = AppCatalog(
            generation: 1,
            github: [GitHubCatalogEntry(bundleId: "com.example.fresh", repo: "fresh/repo", caskToken: "fresh")]
        )

        let resolved = AppCatalog.resolve(bundled: bundled, overlay: overlay)

        XCTAssertNil(resolved.githubRepos["com.example.fresh"])
        XCTAssertEqual(resolved.generation, 3)
    }

    /// Kopia OTA tej samej publikacji to normalny stan, nie atak — równość musi przechodzić.
    func testOverlayOfEqualGenerationStillApplies() {
        let bundled = AppCatalog(generation: 3)
        let overlay = AppCatalog(
            generation: 3,
            github: [GitHubCatalogEntry(bundleId: "com.example.fresh", repo: "fresh/repo", caskToken: "fresh")]
        )

        let resolved = AppCatalog.resolve(bundled: bundled, overlay: overlay)

        XCTAssertEqual(resolved.githubRepos["com.example.fresh"]?.repo, "fresh/repo")
    }

    func testNewerOverlayStillWinsOnCollisionAndSetsTheMergedGeneration() {
        let bundled = AppCatalog(
            generation: 3,
            github: [GitHubCatalogEntry(bundleId: "com.example.app", repo: "old/repo", caskToken: "example")]
        )
        let overlay = AppCatalog(
            generation: 4,
            github: [GitHubCatalogEntry(bundleId: "com.example.app", repo: "new/repo", caskToken: "example")]
        )

        let resolved = AppCatalog.resolve(bundled: bundled, overlay: overlay)

        XCTAssertEqual(resolved.githubRepos["com.example.app"]?.repo, "new/repo")
        XCTAssertEqual(resolved.generation, 4, "scalony katalog raportuje generację danych w użyciu")
    }

    /// Katalog z builda niesie generację, przeciw której mierzy się każdy overlay.
    func testBundledGenerationMatchesTheShippedCatalog() throws {
        XCTAssertEqual(AppCatalog.bundledGeneration, try AppCatalog.loadBundled().generation)
    }
```

- [ ] **Step 2: Confirm the tests are Red by reading, not running**

Do **not** run the suite (project rule). Confirm by inspection that `AppCatalog.resolve(bundled:overlay:)` and `AppCatalog.bundledGeneration` do not exist yet, so the file does not compile — that is this task's Red. Record it; the handoff must say Red→Green is unconfirmed.

- [ ] **Step 3: Add the guard**

In `Sources/MacUpdaterCore/AppCatalog.swift`, replace `loadShared()` (currently at `:250-254`):

```swift
    /// The catalog generation compiled into this build — the floor no overlay may go under.
    /// `0` when the bundled resource cannot be read, which keeps a packaging failure from
    /// also disabling the overlay; `testBundledCatalogDecodes` is what guards that resource.
    public static let bundledGeneration: Int = (try? loadBundled())?.generation ?? 0

    static func loadShared() -> AppCatalog {
        let bundled = (try? loadBundled()) ?? AppCatalog()
        guard let overlay = loadOverlay() else { return bundled }
        return resolve(bundled: bundled, overlay: overlay)
    }

    /// Applies `overlay` on top of `bundled` unless it is a step *backwards*.
    ///
    /// `loadOverlay()` answers "did the publisher sign this?", which an old but genuinely
    /// signed document passes forever. The lookup dictionaries resolve collisions with
    /// last-wins, so before this guard an overlay written by a previous install shadowed
    /// every key a newer build had just shipped — and `overlaying(_:)` reported the *newer*
    /// generation while serving the older data, making the staleness invisible.
    ///
    /// Kept free of IO so the guard is unit-testable without touching the real Application
    /// Support overlay, mirroring `AppEndpoints.resolveOverlayStatus`.
    static func resolve(bundled: AppCatalog, overlay: AppCatalog) -> AppCatalog {
        guard CatalogGenerationPolicy.accepts(
            candidate: overlay.generation,
            accepted: bundled.generation
        ) else {
            WegaLog.error(
                .app,
                "app-catalog.json: generacja \(overlay.generation) starsza niż katalog "
                + "z builda (\(bundled.generation)) — overlay zignorowany, używam katalogu z builda."
            )
            return bundled
        }
        return bundled.overlaying(overlay)
    }
```

- [ ] **Step 4: Document the precondition on `overlaying(_:)`**

In the same file, replace the `generation:` line comment inside `overlaying(_:)` (currently `AppCatalog.swift:224`):

```swift
            // The merged catalog is as new as the newest document that fed it. True only
            // because `resolve(bundled:overlay:)` refuses an older overlay upstream: given
            // `other.generation >= generation`, this is exactly the generation of the data
            // in effect. Calling this directly with an older overlay reports a number the
            // merged catalog does not honour.
            generation: max(generation, other.generation),
```

- [ ] **Step 5: Run the gate**

```bash
swift build && swiftlint lint --strict
```

Expected: builds clean, no lint violations. If SwiftLint flags the new test file for type body length, split the new tests into a separate `final class AppCatalogOverlayGenerationTests: XCTestCase` in the same file rather than adding a disable comment.

- [ ] **Step 6: Commit**

```bash
git add Sources/MacUpdaterCore/AppCatalog.swift Tests/MacUpdaterTests/AppCatalogTests.swift
git commit -m "fix(catalog): ignore a user overlay older than the bundled catalog"
```

---

### Task 2: Ledger floor

**Files:**
- Modify: `Sources/MacUpdaterCore/CatalogGeneration.swift:27-53`
- Test: `Tests/MacUpdaterTests/AppCatalogTests.swift` (append)

**Interfaces:**
- Consumes: `TestDefaults.isolated(_ label: String) -> (defaults: UserDefaults, teardown: () -> Void)` from `WegaTestSupport`.
- Produces: `CatalogGenerationLedger.init(defaults: UserDefaults = .standard, floor: Int = 0)` — consumed by Task 3 and Task 4.

- [ ] **Step 1: Write the failing tests**

`Tests/MacUpdaterTests/AppCatalogTests.swift` needs `import WegaTestSupport` at the top if it is not already there (the file currently imports only `XCTest` and `@testable import MacUpdaterCore`). Add it, then append inside the test class:

```swift
    // MARK: Ledger floor — the build's own generation is a floor under the OTA watermark

    func testLedgerRefusesACatalogBelowTheFloor() {
        let (defaults, teardown) = TestDefaults.isolated("catalog-generation-floor")
        defer { teardown() }
        let ledger = CatalogGenerationLedger(defaults: defaults, floor: 3)

        XCTAssertFalse(ledger.accepts(2))
        XCTAssertTrue(ledger.accepts(3), "równa generacja jest normalna, nie atak")
        XCTAssertTrue(ledger.accepts(4))
    }

    /// Bez podłogi rejestr zachowuje się jak dotąd, więc istniejące wstrzyknięcia nie zmieniają
    /// znaczenia.
    func testLedgerWithoutAFloorAcceptsFromZero() {
        let (defaults, teardown) = TestDefaults.isolated("catalog-generation-no-floor")
        defer { teardown() }
        let ledger = CatalogGenerationLedger(defaults: defaults)

        XCTAssertTrue(ledger.accepts(0))
        XCTAssertEqual(ledger.accepted, 0)
    }

    /// Znak wodny dalej znaczy „najwyższa faktycznie przyjęta generacja OTA" i nie wchłania
    /// numeru z builda — dzięki temu downgrade aplikacji wyprowadza podłogę z builda, który
    /// naprawdę działa, zamiast utknąć na liczbie zapisanej przez nowszy build.
    func testRecordingAtTheFloorDoesNotPersistTheBuildsGeneration() {
        let (defaults, teardown) = TestDefaults.isolated("catalog-generation-floor-record")
        defer { teardown() }
        let ledger = CatalogGenerationLedger(defaults: defaults, floor: 3)

        ledger.record(3)

        XCTAssertEqual(defaults.integer(forKey: CatalogGenerationLedger.defaultsKey), 0)
        XCTAssertEqual(ledger.accepted, 3, "podłoga nadal obowiązuje")
    }

    func testRecordingAboveTheFloorPersists() {
        let (defaults, teardown) = TestDefaults.isolated("catalog-generation-above-floor")
        defer { teardown() }
        let ledger = CatalogGenerationLedger(defaults: defaults, floor: 3)

        ledger.record(5)

        XCTAssertEqual(defaults.integer(forKey: CatalogGenerationLedger.defaultsKey), 5)
        XCTAssertEqual(ledger.accepted, 5)
    }
```

- [ ] **Step 2: Confirm Red by reading**

`CatalogGenerationLedger.init` has no `floor:` parameter, so the test file does not compile. That is Red. Do not run the suite.

- [ ] **Step 3: Add the floor**

In `Sources/MacUpdaterCore/CatalogGeneration.swift`, replace the stored property, `init`, and `accepted`:

```swift
    private let defaults: UserDefaults
    /// The generation this build ships, below which no fetched catalog may go.
    ///
    /// The persisted watermark only remembers what arrived over the air, so a build whose
    /// bundled catalog is *newer* than anything fetched would otherwise accept — and write —
    /// a document it already outranks. `0` leaves the ledger behaving exactly as before.
    private let floor: Int

    public init(defaults: UserDefaults = .standard, floor: Int = 0) {
        self.defaults = defaults
        self.floor = floor
    }

    /// `0` when nothing has been accepted yet, which is also the generation of every catalog
    /// published before the field existed — so a first run accepts anything at or above the
    /// floor and tightens from there.
    public var accepted: Int {
        max(defaults.integer(forKey: Self.defaultsKey), floor)
    }
```

Leave `accepts(_:)` and `record(_:)` untouched: `record` already guards on `candidate > accepted`, so a generation at or below the floor stays a no-op.

- [ ] **Step 4: Run the gate**

```bash
swift build && swiftlint lint --strict
```

Expected: builds clean, no violations. Every existing `CatalogGenerationLedger(defaults:)` call site still compiles because `floor` is defaulted.

- [ ] **Step 5: Commit**

```bash
git add Sources/MacUpdaterCore/CatalogGeneration.swift Tests/MacUpdaterTests/AppCatalogTests.swift
git commit -m "feat(catalog): give the generation ledger an injectable floor"
```

---

### Task 3: Floor the refresher at the build's generation

**Files:**
- Modify: `Sources/MacUpdaterCore/CatalogRefresher.swift:38-58` (the `generations` doc comment and `init` default)
- Modify: `Tests/MacUpdaterTests/CatalogRefresherTests.swift:51-56`
- Modify: `Tests/MacUpdaterTests/CatalogSignaturePersistenceTests.swift:38-54`
- Test: `Tests/MacUpdaterTests/SEC07CatalogEnvelopeTests.swift` (append a test to the existing suite)

**Interfaces:**
- Consumes: `AppCatalog.bundledGeneration` (Task 1); `CatalogGenerationLedger.init(defaults:floor:)` (Task 2).
- Produces: no new API — `CatalogRefresher.init`'s `generations` default becomes `CatalogGenerationLedger(floor: AppCatalog.bundledGeneration)`.

- [ ] **Step 1: Write the failing test**

Append to `struct SEC07CatalogEnvelopeTests` in `Tests/MacUpdaterTests/SEC07CatalogEnvelopeTests.swift`, before its closing brace. It reuses that suite's existing private helpers (`source`, `verifier`, `catalogJSON(schemaVersion:generation:token:)`, `envelope(wrapping:version:)`, `tempDestination()`, `EnvelopeFakeTransport`):

```swift
    /// A catalog older than the one compiled into this build is a downgrade even on a fresh
    /// install, where the persisted watermark is still `0`. Refusing it at fetch time is what
    /// keeps the disk from holding a document that `AppCatalog.resolve` would only ignore.
    @Test("A catalog older than the build's own is refused before it is written")
    func generationBelowTheBuildFloorIsRefused() async throws {
        let dest = tempDestination()
        defer { try? FileManager.default.removeItem(at: dest.deletingLastPathComponent()) }
        let (defaults, teardown) = TestDefaults.isolated("sec07-catalog-build-floor")
        defer { teardown() }

        let outcome = await CatalogRefresher(
            source: source, destination: dest,
            client: HTTPClient(transport: EnvelopeFakeTransport([
                .init(data: Data(try envelope(wrapping: catalogJSON(generation: 2)).utf8),
                      status: 200, headers: [:])
            ]), maxRetries: 0, retryBaseDelay: 0),
            signatureVerifier: verifier,
            generations: CatalogGenerationLedger(defaults: defaults, floor: 5)
        ).refresh()

        #expect(outcome == .replayRejected)
        #expect(!FileManager.default.fileExists(atPath: dest.path),
                "katalog spod podłogi builda nie może dotknąć overlaya")
    }
```

If `SEC07CatalogEnvelopeTests.swift` does not already `import WegaTestSupport`, add it — the file uses `TestDefaults.isolated` at `:75` and `:198`, so it does.

- [ ] **Step 2: Confirm Red by reading**

This test is Red only against Task 2's pre-floor ledger; after Task 2 it passes on its own. Its real job is to pin the refresher-level contract. Do not run the suite.

- [ ] **Step 3: Change the production default**

In `Sources/MacUpdaterCore/CatalogRefresher.swift`, replace the `generations` property comment and the `init` default value:

```swift
    /// SEC-07 — the replay watermark, injected so a test can start from a known generation.
    /// Its production floor is the generation compiled into *this build*: the persisted
    /// watermark only remembers what arrived over the air, so without the floor a fresh
    /// install would accept — and write — a catalog its own bundled copy already outranks.
    private let generations: CatalogGenerationLedger

    public init(
        source: URL,
        destination: URL = AppCatalog.overlayURL,
        client: HTTPClient = .shared,
        signatureVerifier: CatalogSignature = .shared,
        generations: CatalogGenerationLedger = CatalogGenerationLedger(floor: AppCatalog.bundledGeneration)
    ) {
```

Leave the rest of `init` and `refresh()` unchanged — `generations.accepts(catalog.generation)` at `:120` already returns `.replayRejected` for a below-floor document.

- [ ] **Step 4: Keep the four pre-existing tests honest**

These four build a refresher without injecting a ledger, on fixtures with **no `generation` key** (generation 0). Under the new default they would be measured against the build's generation, which is not what either suite is about. Inject a floor-0 ledger — the same move `CatalogRefresherTests:55` already makes for `signatureVerifier`. **No assertion changes.**

In `Tests/MacUpdaterTests/CatalogRefresherTests.swift`, in `writesValidCatalogAndReturnsUpdated`, replace the refresher construction at `:51-56`:

```swift
        let refresher = CatalogRefresher(
            source: source,
            destination: dest,
            client: client([ok(json)]),
            signatureVerifier: CatalogSignature(publicKeyBase64: CatalogSignature.unconfiguredPlaceholder),
            // Ten zestaw jest o dekodowaniu i zapisie, nie o podłodze generacji: fixture nie
            // niesie `generation`, więc mierzony przeciw katalogowi z builda byłby downgrade'em.
            generations: CatalogGenerationLedger(floor: 0)
        )
```

In `Tests/MacUpdaterTests/CatalogSignaturePersistenceTests.swift`, in the private `refresher(body:signature:verifier:)` helper at `:48-53`, add the same argument — this covers all three affected tests in that file at once:

```swift
        return CatalogRefresher(
            source: URL(string: "https://example.test/app-catalog.json")!,
            destination: destination,
            client: HTTPClient(transport: FakeHTTPTransport(responses)),
            signatureVerifier: verifier ?? self.verifier,
            // Zestaw jest o trwałości podpisu, nie o podłodze generacji — `catalogJSON` nie
            // niesie `generation`, więc domyślna podłoga z builda odrzuciłaby go jako replay.
            generations: CatalogGenerationLedger(floor: 0)
        )
```

- [ ] **Step 5: Run the gate**

```bash
swift build && swiftlint lint --strict
```

Expected: builds clean, no violations. Verify by inspection that no other `CatalogRefresher(` call site relies on the old default — the only ones left are `Sources/MacUpdater/MacUpdaterApp.swift:201` and `Sources/MacUpdater/InfoOperationsController.swift:33`, both of which *want* the floored production default.

- [ ] **Step 6: Commit**

```bash
git add Sources/MacUpdaterCore/CatalogRefresher.swift Tests/MacUpdaterTests/SEC07CatalogEnvelopeTests.swift Tests/MacUpdaterTests/CatalogRefresherTests.swift Tests/MacUpdaterTests/CatalogSignaturePersistenceTests.swift
git commit -m "fix(catalog): refuse a fetched catalog older than the build's own"
```

---

### Task 4: Document the publishing rule

**Files:**
- Modify: `RELEASING.md:284-288`

**Interfaces:**
- Consumes: nothing. Produces: nothing.

- [ ] **Step 1: Extend the `--bump` paragraph**

Replace the paragraph at `RELEASING.md:284-288` with:

```markdown
`--bump` raises `generation`, the monotonic publication counter **inside** the signed bytes.
Wega remembers the highest generation it has accepted, across relaunches, and refuses
anything lower — which is what stops an old but perfectly-signed catalog from being replayed
at a client forever. Skipping the bump leaves that protection inert, so it is a flag rather
than a step to remember.

The counter has a second reader. Every build carries its own copy of the catalog, and a
client refuses a fetched catalog — and ignores an overlay already on disk — whose generation
is **lower than the one compiled into the running build**. A published generation must
therefore be at least the generation of the catalog in the released app, or the publication
has no effect on anyone running it. In practice this is automatic: the same `--bump` that
raised the file is what the next release ships.
```

- [ ] **Step 2: Run the gate**

```bash
swift build && swiftlint lint --strict
```

Expected: unchanged output — this task touches no Swift. Run it anyway so the commit is gated like the others.

- [ ] **Step 3: Commit**

```bash
git add RELEASING.md
git commit -m "docs(releasing): note the build-generation floor on published catalogs"
```

---

## Verification Summary for the Handoff

State plainly:
- `swift build && swiftlint lint --strict` — run after every task, this is the gate that was applied.
- **Test suites were not run.** Red→Green is unconfirmed by design (project rule: tests are opt-in). The suites the user would want to run are `MacUpdaterTests` — specifically `AppCatalogTests`, `SEC07CatalogEnvelopeTests`, `CatalogRefresherTests`, `CatalogSignaturePersistenceTests`.
- Four pre-existing tests were modified with prior approval; each gained an injected `generations:` argument and no assertion was changed.
- Report the branch (`fix/stale-catalog-overlay-generation-guard-2026-08-12`), the worktree path, and hand the user the merge command rather than integrating.
