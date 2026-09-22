# Release Notes Before Updating — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every update Wega offers can say what it brings, using only the feeds Wega already fetches, and shows it in the row before the user applies it.

**Architecture:** One Core type, `ReleaseNotes`, carries either the release entries already in hand or an HTTPS link to fetch on demand. The Sparkle appcast parser stops discarding the `<description>` bodies it already parses; the GitHub checker moves from `/releases/latest` to the releases list so it can see every version the user is behind. Sanitization moves out of the views into Core, so no view ever holds vendor HTML. Batch rows (Homebrew / App Store / npm) render the same disclosure the manual rows already use, fed by a join on the cask token → app path map the scan already builds.

**Tech Stack:** Swift 6, SwiftPM, SwiftUI (macOS), swift-testing (`@Suite` / `@Test` / `#expect`), SwiftLint.

**Spec:** [`docs/superpowers/specs/2026-09-22-release-notes-before-updating-design.md`](../specs/2026-09-22-release-notes-before-updating-design.md)

## Global Constraints

- **No new update sources.** Sparkle appcasts and GitHub Releases only. No iTunes Lookup, no npm registry, no inferring a repository from a cask homepage.
- **HTTPS only (SEC-09).** A feed URL or notes link on plain HTTP is dropped, never fetched.
- **No markup reaches a view.** `ReleaseNotesText.plain(fromHTML:)` runs in Core, once per source. `ReleaseNote.body` is plain text by contract.
- **History cap: 10 entries**, with the remainder reported as `ReleaseHistory.omitted`. Same value `ReleaseHistoryFetcher` already uses.
- **Fetched page caps: 256 KB response, 20 000 characters of text.** Over the byte cap the page is refused; over the character cap it is truncated and the truncation is stated on screen.
- **UI strings are Polish base + English in `Sources/MacUpdaterCore/Translations.swift`.** `LocalizationCompletenessTests` fails the build for any `tr(...)`/`trf(...)` literal with no English counterpart.
- **Focused test runs only.** Each task runs `swift test --filter <Suite>` exactly where its steps say so — the RED/GREEN cycle is what proves a test tests anything. The commit gate is that filter plus `swift build` and `swiftlint lint --strict`. Never run the whole `swift test`, and never `scripts/check.sh` (it bundles build, the full suite and lint): the full suite is the owner's call, and the handoff names it as outstanding.
- **No AI attribution** in any commit message.

---

### Task 1: The `ReleaseNotes` type

**Files:**
- Create: `Sources/MacUpdaterCore/ReleaseNotes.swift`
- Modify: `Sources/MacUpdaterCore/ReleaseHistory.swift` (add `Codable` to `ReleaseNote` and `ReleaseHistory`)
- Test: `Tests/MacUpdaterTests/ReleaseNotesTests.swift`

**Interfaces:**
- Consumes: `ReleaseNote`, `ReleaseHistory` (existing, `ReleaseHistory.swift`), `ReleaseNotesText.plain(fromHTML:)`
- Produces: `ReleaseNotes(history:link:)`, `ReleaseNotes(html:version:publishedAt:)`, `.plainText`, `.isEmpty`, `Codable` conformance that also decodes a legacy bare string.

- [ ] **Step 1: Write the failing test**

Create `Tests/MacUpdaterTests/ReleaseNotesTests.swift`:

```swift
import Testing
import Foundation
@testable import MacUpdaterCore

@Suite("ReleaseNotes")
struct ReleaseNotesTests {

    @Test func htmlInitialiserStripsMarkupIntoOneEntry() {
        let notes = ReleaseNotes(html: "<p>Fixed <b>a crash</b></p>", version: "2.0.0")

        #expect(notes.history.notes.count == 1)
        #expect(notes.history.notes.first?.version == "2.0.0")
        #expect(notes.history.notes.first?.body == "Fixed a crash")
        #expect(notes.isEmpty == false)
    }

    @Test func htmlThatCollapsesToNothingProducesEmptyNotes() {
        let notes = ReleaseNotes(html: "<style>.a{color:red}</style>")

        #expect(notes.history.notes.isEmpty)
        #expect(notes.isEmpty)
    }

    @Test func aLinkAloneIsNotEmpty() {
        let notes = ReleaseNotes(history: ReleaseHistory(notes: [], omitted: 0),
                                 link: URL(string: "https://example.com/notes")!)

        #expect(notes.history.notes.isEmpty)
        #expect(notes.isEmpty == false)
    }

    @Test func plainTextJoinsEveryEntryForTriage() {
        let notes = ReleaseNotes(history: ReleaseHistory(notes: [
            ReleaseNote(version: "2.0.0", publishedAt: nil, body: "New icon"),
            ReleaseNote(version: "1.9.0", publishedAt: nil, body: "Fixes CVE-2026-1234"),
        ], omitted: 0), link: nil)

        #expect(ReleaseNotesTriage.heuristic(notes.plainText).isLikelySecurityFix)
    }

    @Test func decodesTheLegacyStringShape() throws {
        // A snapshot written before this change stored raw HTML in a bare string.
        let json = Data(#"{"releaseNotes":"<p>Old &amp; crusty</p>"}"#.utf8)
        struct Box: Decodable { var releaseNotes: ReleaseNotes? }

        let box = try JSONDecoder().decode(Box.self, from: json)

        #expect(box.releaseNotes?.history.notes.count == 1)
        #expect(box.releaseNotes?.history.notes.first?.body == "Old & crusty")
        #expect(box.releaseNotes?.history.notes.first?.version == "")
        #expect(box.releaseNotes?.history.notes.first?.publishedAt == nil)
    }

    @Test func roundTripsTheCurrentShape() throws {
        let original = ReleaseNotes(
            history: ReleaseHistory(notes: [ReleaseNote(version: "3.1.0", publishedAt: nil, body: "Faster")], omitted: 4),
            link: URL(string: "https://example.com/notes")!
        )

        let restored = try JSONDecoder().decode(
            ReleaseNotes.self, from: JSONEncoder().encode(original)
        )

        #expect(restored == original)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter ReleaseNotes`
Expected: FAIL — `cannot find 'ReleaseNotes' in scope`.

- [ ] **Step 3: Add `Codable` to the existing history types**

In `Sources/MacUpdaterCore/ReleaseHistory.swift`, extend both declarations (change only the conformance lists):

```swift
public struct ReleaseNote: Codable, Equatable, Sendable, Identifiable {
```

```swift
public struct ReleaseHistory: Codable, Equatable, Sendable {
```

- [ ] **Step 4: Write the implementation**

Create `Sources/MacUpdaterCore/ReleaseNotes.swift`:

```swift
import Foundation

/// What an update brings, in the two shapes update feeds actually publish: the release
/// entries themselves, or a link to a page carrying them.
///
/// Both may be present — a Sparkle appcast often has an inline `<description>` *and* a
/// `<sparkle:releaseNotesLink>`. Neither is a promise: a source that publishes nothing
/// yields `isEmpty`, and the UI then says nothing rather than inventing a "no changes"
/// it cannot know.
///
/// Every body here is already plain text. Sanitisation happens once, at the source that
/// produced the notes, so no view ever holds vendor HTML (UX-05).
public struct ReleaseNotes: Equatable, Sendable {
    /// Releases between the installed version and the newest one, newest first.
    public var history: ReleaseHistory
    /// A page carrying the notes, fetched only when the user asks for it. HTTPS only
    /// (SEC-09) — the parsers drop a plain-HTTP link before it ever reaches this type.
    public var link: URL?

    public init(history: ReleaseHistory, link: URL? = nil) {
        self.history = history
        self.link = link
    }

    /// One release's notes from a markup body — the shape a source that publishes a single
    /// release gives us (Wega's own self-update, a GitHub release with no predecessors).
    /// Markup that collapses to nothing yields no entry at all, not an empty one.
    public init(html: String, version: String = "", publishedAt: Date? = nil, link: URL? = nil) {
        let body = ReleaseNotesText.plain(fromHTML: html)
        let notes = body.isEmpty ? [] : [ReleaseNote(version: version, publishedAt: publishedAt, body: body)]
        self.init(history: ReleaseHistory(notes: notes, omitted: 0), link: link)
    }

    /// Nothing to show and nothing to fetch.
    public var isEmpty: Bool { history.notes.isEmpty && link == nil }

    /// Every entry's body, joined — the input `ReleaseNotesTriage` reads. Joining rather
    /// than taking the newest is the point: a security fix published two releases back is
    /// still a security fix the user has not got yet.
    public var plainText: String {
        history.notes.map(\.body).joined(separator: "\n")
    }
}

extension ReleaseNotes: Codable {
    private enum CodingKeys: String, CodingKey { case history, link }

    /// Tolerates the shape this field had before it became a type: a bare string of raw
    /// HTML. `ScanResultStore` decodes the whole snapshot with `try?`, so a failure here
    /// would not degrade one field — it would drop the entire last scan and leave the
    /// first launch after an update showing an empty list.
    ///
    /// The legacy shape recorded neither a version nor a date, so the entry claims
    /// neither. The next scan replaces it with a real history.
    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(),
           let legacy = try? single.decode(String.self) {
            self.init(html: legacy)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.history = try container.decode(ReleaseHistory.self, forKey: .history)
        self.link = try container.decodeIfPresent(URL.self, forKey: .link)
    }
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `swift test --filter ReleaseNotes`
Expected: PASS (6 tests).

- [ ] **Step 6: Build and lint**

```bash
swift build && swiftlint lint --strict
```

- [ ] **Step 7: Commit**

```bash
git add Sources/MacUpdaterCore/ReleaseNotes.swift Sources/MacUpdaterCore/ReleaseHistory.swift Tests/MacUpdaterTests/ReleaseNotesTests.swift
git commit -m "feat(core): one type for what an update brings"
```

---

### Task 2: The appcast parser keeps the notes it already reads

**Files:**
- Modify: `Sources/MacUpdaterCore/SparkleUpdateChecker.swift` (the `AppcastItem` / `AppcastParser` section, from line 78)
- Test: `Tests/MacUpdaterTests/SparkleUpdateCheckerTests.swift`

**Interfaces:**
- Consumes: `ReleaseNotes`, `ReleaseNote`, `ReleaseHistory` (Task 1); `isUpgrade(installed:latest:)`, `compareVersions(_:_:scheme:)`, `ReleaseNotesText.plain(fromHTML:)` (existing).
- Produces: `AppcastItem.publishedAt: Date?`; `AppcastResult { latest: AppcastItem, history: ReleaseHistory }`; `AppcastParser.parseResult(data:installedVersion:limit:) -> AppcastResult?`. `AppcastParser.parse(data:)` and `.parseItem(data:)` keep their current behaviour and signatures.

- [ ] **Step 1: Write the failing test**

Append to `Tests/MacUpdaterTests/SparkleUpdateCheckerTests.swift`, inside the existing suite:

```swift
    private func feed(_ items: String) -> Data {
        Data("""
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
        \(items)
        </channel></rss>
        """.utf8)
    }

    private func item(version: String, description: String? = nil, pubDate: String? = nil) -> String {
        """
        <item>
          <sparkle:shortVersionString>\(version)</sparkle:shortVersionString>
          \(pubDate.map { "<pubDate>\($0)</pubDate>" } ?? "")
          \(description.map { "<description><![CDATA[\($0)]]></description>" } ?? "")
        </item>
        """
    }

    @Test func historyKeepsEveryReleaseNewerThanTheInstalledOne() {
        let data = feed(
            item(version: "1.0.0", description: "<p>Old</p>")
            + item(version: "1.1.0", description: "<p>Middle</p>")
            + item(version: "1.2.0", description: "<p>New</p>")
        )

        let result = AppcastParser.parseResult(data: data, installedVersion: "1.0.0")

        #expect(result?.latest.version == "1.2.0")
        #expect(result?.history.notes.map(\.version) == ["1.2.0", "1.1.0"])
        #expect(result?.history.notes.first?.body == "New")
        #expect(result?.history.omitted == 0)
    }

    @Test func historyCapsAndReportsWhatItLeftOut() {
        let items = (1...12).map { item(version: "1.0.\($0)", description: "<p>Note \($0)</p>") }.joined()

        let result = AppcastParser.parseResult(data: feed(items), installedVersion: "1.0.0", limit: 10)

        #expect(result?.history.notes.count == 10)
        #expect(result?.history.notes.first?.version == "1.0.12")
        #expect(result?.history.omitted == 2)
    }

    @Test func historyReadsThePublicationDate() {
        let data = feed(item(version: "2.0.0", description: "<p>New</p>",
                             pubDate: "Mon, 20 Jul 2026 10:00:00 +0000"))

        let note = AppcastParser.parseResult(data: data, installedVersion: "1.0.0")?.history.notes.first

        #expect(note?.publishedAt != nil)
    }

    @Test func entriesWithNoDescriptionAreLeftOutRatherThanShownEmpty() {
        let data = feed(item(version: "1.1.0") + item(version: "1.2.0", description: "<p>New</p>"))

        let result = AppcastParser.parseResult(data: data, installedVersion: "1.0.0")

        #expect(result?.history.notes.map(\.version) == ["1.2.0"])
        #expect(result?.history.omitted == 0)
    }

    @Test func aFeedWithNoUsableItemIsNoResultAtAll() {
        #expect(AppcastParser.parseResult(data: Data("not xml".utf8), installedVersion: "1.0.0") == nil)
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter SparkleUpdateChecker`
Expected: FAIL — `type 'AppcastParser' has no member 'parseResult'`.

- [ ] **Step 3: Teach the parser about `<pubDate>`**

In `Sources/MacUpdaterCore/SparkleUpdateChecker.swift`, add the field to `AppcastItem`:

```swift
struct AppcastItem: Equatable {
    var version: String?
    var descriptionHTML: String?
    var releaseNotesLink: URL?
    /// RSS `<pubDate>` (RFC 822), when the feed carries one.
    var publishedAt: Date?
}
```

Add the parser's instance field beside `private var releaseNotesLink: URL?`:

```swift
    private var publishedAt: Date?
```

Reset it where the other item fields are reset, inside `didStartElement` under `if el == "item"`:

```swift
            publishedAt = nil
```

Add the case to the `switch local` in `didEndElement`, beside `"releaseNotesLink"`:

```swift
            case "pubDate":
                if publishedAt == nil { publishedAt = Self.rfc822Date(from: trimmed) }
```

Carry it into the appended item, replacing the existing `AppcastItem(...)` construction:

```swift
                    AppcastItem(version: version, descriptionHTML: descriptionHTML,
                                releaseNotesLink: releaseNotesLink, publishedAt: publishedAt),
```

Add the formatter as a static member of `AppcastParser`:

```swift
    /// RSS dates are RFC 822. Fixed locale and zero time zone so a user's regional
    /// settings cannot change whether a feed's date parses.
    private static let rfc822Formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter
    }()

    static func rfc822Date(from string: String) -> Date? {
        rfc822Formatter.date(from: string)
    }
```

- [ ] **Step 4: Share the candidate selection and add `parseResult`**

Still in `SparkleUpdateChecker.swift`, replace the body of `parseItem(data:)` with a call to a shared collector and add the new entry point next to it:

```swift
    /// Every item Sparkle would offer this user: the default channel when the feed has one,
    /// otherwise all items. An item carrying `<sparkle:channel>` is offered by Sparkle only
    /// to users who opted into that channel.
    private static func candidates(data: Data) -> [AppcastItem] {
        let delegate = AppcastParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        let defaultChannel = delegate.items.filter { $0.channel == nil }
        return (defaultChannel.isEmpty ? delegate.items : defaultChannel).map(\.item)
    }

    static func parseItem(data: Data) -> AppcastItem? {
        // max(by:) wants an ascending predicate: $0 precedes $1 when $1 is the newer version.
        candidates(data: data).max { lhs, rhs in
            isUpgrade(installed: lhs.version ?? "", latest: rhs.version ?? "")
        }
    }

    /// The chosen item plus every release published between `installedVersion` and it —
    /// the answer to *what do I get if I update*, which the newest item alone cannot give
    /// once more than one release has passed.
    ///
    /// Entries whose description collapses to nothing are left out rather than listed
    /// empty; `omitted` counts only what the cap dropped.
    static func parseResult(data: Data, installedVersion: String, limit: Int = 10) -> AppcastResult? {
        let items = candidates(data: data)
        guard let latest = items.max(by: { isUpgrade(installed: $0.version ?? "", latest: $1.version ?? "") })
        else { return nil }

        let newer = items
            .filter { isUpgrade(installed: installedVersion, latest: $0.version ?? "") }
            .filter { !ReleaseNotesText.plain(fromHTML: $0.descriptionHTML ?? "").isEmpty }
            // `compareVersions` takes no default scheme — appcasts are `.buildNumbered`,
            // the same scheme `isUpgrade(installed:latest:)` applies above.
            .sorted { compareVersions($0.version ?? "", $1.version ?? "", scheme: .buildNumbered) == .orderedDescending }

        let kept = newer.prefix(limit).map { entry in
            ReleaseNote(
                version: entry.version ?? "",
                publishedAt: entry.publishedAt,
                body: ReleaseNotesText.plain(fromHTML: entry.descriptionHTML ?? "")
            )
        }

        return AppcastResult(
            latest: latest,
            history: ReleaseHistory(notes: Array(kept), omitted: max(0, newer.count - kept.count))
        )
    }
```

Add the result type beside `AppcastItem`:

```swift
/// What one appcast says: which item to offer, and everything published on the way to it.
struct AppcastResult: Equatable {
    var latest: AppcastItem
    var history: ReleaseHistory
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter SparkleUpdateChecker`
Expected: PASS — the five new tests plus every pre-existing one in the suite (`parse` and `parseItem` behaviour is unchanged).

- [ ] **Step 6: Build and lint**

```bash
swift build && swiftlint lint --strict
```

- [ ] **Step 7: Commit**

```bash
git add Sources/MacUpdaterCore/SparkleUpdateChecker.swift Tests/MacUpdaterTests/SparkleUpdateCheckerTests.swift
git commit -m "feat(sparkle): read every release between installed and newest from the appcast"
```

---

### Task 3: One GitHub release-history helper, used by both readers

**Files:**
- Create: `Sources/MacUpdaterCore/GitHubReleaseHistory.swift`
- Modify: `Sources/MacUpdaterCore/ReleaseHistory.swift` (`ReleaseHistoryFetcher.notesNewerThan` delegates to the helper)
- Test: `Tests/MacUpdaterTests/GitHubReleaseHistoryTests.swift`

**Interfaces:**
- Consumes: `GitHubRelease` (internal, `GitHubRelease.swift`), `normalizeGitTag`, `isUpgrade`, `compareVersions`, `ReleaseNote`, `ReleaseHistory`.
- Produces: `GitHubReleaseHistory.stableReleases(from:) -> [GitHubRelease]?`, `.newest(_:) -> GitHubRelease?`, `.history(_:newerThan:limit:) -> ReleaseHistory`.

- [ ] **Step 1: Write the failing test**

Create `Tests/MacUpdaterTests/GitHubReleaseHistoryTests.swift`:

```swift
import Testing
import Foundation
@testable import MacUpdaterCore

@Suite("GitHubReleaseHistory")
struct GitHubReleaseHistoryTests {

    private func release(
        tag: String,
        body: String = "notes",
        draft: Bool = false,
        prerelease: Bool = false
    ) -> String {
        """
        {"tag_name":"\(tag)","draft":\(draft),"prerelease":\(prerelease),
         "body":"\(body)","published_at":"2026-07-20T10:00:00Z"}
        """
    }

    private func data(_ releases: [String]) -> Data {
        Data("[\(releases.joined(separator: ","))]".utf8)
    }

    @Test func dropsDraftsAndPrereleases() throws {
        let releases = try #require(GitHubReleaseHistory.stableReleases(from: data([
            release(tag: "v2.0.0-rc1", prerelease: true),
            release(tag: "v1.9.0", draft: true),
            release(tag: "v1.8.0"),
        ])))

        #expect(releases.map(\.tagName) == ["v1.8.0"])
    }

    @Test func malformedJsonIsNoAnswerRatherThanAnEmptyOne() {
        #expect(GitHubReleaseHistory.stableReleases(from: Data("nope".utf8)) == nil)
    }

    @Test func newestIsTheHighestTagNotTheFirstRow() throws {
        let releases = try #require(GitHubReleaseHistory.stableReleases(from: data([
            release(tag: "v1.8.0"),
            release(tag: "v1.10.0"),
            release(tag: "v1.9.0"),
        ])))

        #expect(GitHubReleaseHistory.newest(releases)?.tagName == "v1.10.0")
    }

    @Test func historyKeepsOnlyWhatTheUserHasNotGot() throws {
        let releases = try #require(GitHubReleaseHistory.stableReleases(from: data([
            release(tag: "v1.2.0", body: "Newest"),
            release(tag: "v1.1.0", body: "Middle"),
            release(tag: "v1.0.0", body: "Oldest"),
        ])))

        let history = GitHubReleaseHistory.history(releases, newerThan: "1.0.0", limit: 10)

        #expect(history.notes.map(\.version) == ["1.2.0", "1.1.0"])
        #expect(history.notes.first?.body == "Newest")
        #expect(history.omitted == 0)
    }

    @Test func historyCapsAndCountsTheRest() throws {
        let releases = try #require(GitHubReleaseHistory.stableReleases(
            from: data((1...12).map { release(tag: "v1.0.\($0)") })
        ))

        let history = GitHubReleaseHistory.history(releases, newerThan: "1.0.0", limit: 10)

        #expect(history.notes.count == 10)
        #expect(history.omitted == 2)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter GitHubReleaseHistory`
Expected: FAIL — `cannot find 'GitHubReleaseHistory' in scope`.

- [ ] **Step 3: Write the helper**

Create `Sources/MacUpdaterCore/GitHubReleaseHistory.swift`:

```swift
import Foundation

/// The shared reading of a GitHub releases list: which releases count, which one is newest,
/// and what a user on a given version has not seen yet.
///
/// Both readers of that endpoint go through here — `ReleaseHistoryFetcher` for Wega's own
/// update and `GitHubReleasesChecker` for catalogued apps — so the draft/prerelease rule and
/// REL-11's SemVer ordering are stated once instead of once per caller.
enum GitHubReleaseHistory {
    /// `nil` when the payload could not be read at all — distinct from a repository that has
    /// published nothing stable, which is an empty array.
    static func stableReleases(from data: Data) -> [GitHubRelease]? {
        guard let releases = try? JSONDecoder().decode([GitHubRelease].self, from: data) else {
            return nil
        }
        return releases.filter { !$0.draft && !$0.prerelease }
    }

    /// The highest version among them — never merely the first row. GitHub orders the list by
    /// creation date, which is not the same as by version once a patch for an older line ships
    /// after a newer minor.
    static func newest(_ releases: [GitHubRelease]) -> GitHubRelease? {
        releases.max { lhs, rhs in
            compareVersions(normalizeGitTag(lhs.tagName), normalizeGitTag(rhs.tagName), scheme: .semver)
                == .orderedAscending
        }
    }

    /// Everything published above `installed`, newest first, capped, with the remainder
    /// counted in `omitted` rather than dropped silently. Bodies are sanitised here, so what
    /// leaves this function is plain text.
    static func history(_ releases: [GitHubRelease], newerThan installed: String, limit: Int) -> ReleaseHistory {
        let newer = releases
            .map { (release: $0, version: normalizeGitTag($0.tagName)) }
            .filter { isUpgrade(installed: installed, latest: $0.version, scheme: .semver) }
            .sorted { compareVersions($0.version, $1.version, scheme: .semver) == .orderedDescending }

        let kept = newer.prefix(limit).map { entry in
            ReleaseNote(
                version: entry.version,
                publishedAt: entry.release.publishedAt.flatMap(iso8601Date(from:)),
                body: ReleaseNotesText.plain(fromHTML: entry.release.body ?? "")
            )
        }

        return ReleaseHistory(notes: Array(kept), omitted: max(0, newer.count - kept.count))
    }

    static func iso8601Date(from iso: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)
    }
}
```

- [ ] **Step 4: Point `ReleaseHistoryFetcher` at the helper**

In `Sources/MacUpdaterCore/ReleaseHistory.swift`, replace the body of `notesNewerThan(_:limit:)` after the response guard, and delete the now-unused private `date(from:)`:

```swift
    public func notesNewerThan(_ installed: String, limit: Int = 10) async -> Outcome {
        guard let url = AppEndpoints.shared.githubReleasesURL(repo: repo) else { return .unavailable }

        guard let response = try? await client.get(
            url,
            headers: GitHubAuth.headers(),
            enableETag: true
        ), response.statusCode == 200,
            let releases = GitHubReleaseHistory.stableReleases(from: response.data) else {
            return .unavailable
        }

        return .history(GitHubReleaseHistory.history(releases, newerThan: installed, limit: limit))
    }
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter "GitHubReleaseHistory|ReleaseHistoryFetcher"`
Expected: PASS — the five new tests, and every pre-existing `ReleaseHistoryTests` case still green (the behaviour moved, it did not change).

- [ ] **Step 6: Build and lint**

```bash
swift build && swiftlint lint --strict
```

- [ ] **Step 7: Commit**

```bash
git add Sources/MacUpdaterCore/GitHubReleaseHistory.swift Sources/MacUpdaterCore/ReleaseHistory.swift Tests/MacUpdaterTests/GitHubReleaseHistoryTests.swift
git commit -m "refactor(core): one reading of a GitHub releases list, shared by both callers"
```

---

### Task 4: Vendor results carry `ReleaseNotes`

This is the type migration. It touches every consumer of `ManualOutdatedApp.releaseNotes` at once, because Swift will not compile a half-migrated field.

**Files:**
- Modify: `Sources/MacUpdaterCore/VendorUpdateChecker.swift:31,42,49` (`VendorCandidate.releaseNotes`)
- Modify: `Sources/MacUpdaterCore/Models.swift:265,285,295` (`ManualOutdatedApp.releaseNotes`)
- Modify: `Sources/MacUpdaterCore/SparkleUpdateChecker.swift` (`plan(for:)`)
- Modify: `Sources/MacUpdaterCore/GitHubReleasesChecker.swift` (list endpoint + notes)
- Modify: `Sources/MacUpdaterCore/ManualUpdateScanner.swift:71` (`selfUpdateApp`)
- Modify: `Sources/MacUpdater/UpdateViewSupport.swift:444,471-472,669-695` (row badge + disclosure)
- Modify: `Sources/MacUpdater/InspectorPane.swift:95,255,262-286` (What's New)
- Modify: `Sources/MacUpdater/ScanStore.swift:450` (`isSecurityApp`)
- Modify: `Sources/MacUpdater/InfoView.swift:445` (self-update badge)
- Test: `Tests/MacUpdaterTests/InspectorTrustWiringTests.swift:37-41` (guard rewritten — **owner-approved**, see spec §9)
- Test: `Tests/MacUpdaterTests/SparkleUpdateCheckerTests.swift`, `Tests/MacUpdaterUITests/ScanStoreRuntimeActionTests.swift:165`, `Tests/MacUpdaterUITests/SelfUpdateManualSplitTests.swift:43` (call sites)

**Interfaces:**
- Consumes: `ReleaseNotes` (Task 1), `AppcastParser.parseResult` (Task 2), `GitHubReleaseHistory` (Task 3).
- Produces: `ManualOutdatedApp.releaseNotes: ReleaseNotes?` and `VendorCandidate.releaseNotes: ReleaseNotes?`, consumed by Task 6 and Task 7.

- [ ] **Step 1: Write the failing test**

Append to `Tests/MacUpdaterTests/SparkleUpdateCheckerTests.swift`:

```swift
    @Test func theCheckerHandsTheNotesOnRatherThanDroppingThem() async {
        // `checker(_:)`, `app(bundleID:version:)`, `overrideBundleID` and `FakeHTTP` are the
        // suite's existing helpers — see the "check(app:)" section of this file.
        let xml = """
        <?xml version="1.0"?>
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
            <channel>
                <item><sparkle:shortVersionString>1.0.0</sparkle:shortVersionString>
                      <description><![CDATA[<p>Old</p>]]></description></item>
                <item><sparkle:shortVersionString>2.0.0</sparkle:shortVersionString>
                      <description><![CDATA[<p>Fixes a crash</p>]]></description>
                      <sparkle:releaseNotesLink>https://example.com/notes</sparkle:releaseNotesLink></item>
            </channel>
        </rss>
        """

        let result = await checker(FakeHTTP.client(ok: xml))
            .check(app: app(bundleID: overrideBundleID, version: "1.0.0"))

        guard case .outdated(let outdated) = result else {
            Issue.record("expected .outdated, got \(result)"); return
        }
        #expect(outdated.releaseNotes?.history.notes.map(\.version) == ["2.0.0"])
        #expect(outdated.releaseNotes?.history.notes.first?.body == "Fixes a crash")
        #expect(outdated.releaseNotes?.link == URL(string: "https://example.com/notes"))
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter SparkleUpdateChecker`
Expected: FAIL — `value of type 'String?' has no member 'history'`.

- [ ] **Step 3: Change the two field types**

`Sources/MacUpdaterCore/VendorUpdateChecker.swift` — in `VendorCandidate`, the stored property and the initialiser parameter:

```swift
    public var releaseNotes: ReleaseNotes?
```
```swift
        releaseNotes: ReleaseNotes? = nil,
```

`Sources/MacUpdaterCore/Models.swift` — in `ManualOutdatedApp`, update the property, its doc comment, and the initialiser parameter:

```swift
    /// FEAT-06: what this update brings, when the source publishes it — the release entries
    /// themselves and/or a link to fetch on demand. Already plain text (see ``ReleaseNotes``).
    /// Its joined body feeds `ReleaseNotesTriage` for the advisory "possible security fix" badge.
    public var releaseNotes: ReleaseNotes?
```
```swift
        releaseNotes: ReleaseNotes? = nil,
```

- [ ] **Step 4: Fill it from Sparkle**

In `Sources/MacUpdaterCore/SparkleUpdateChecker.swift`, replace the closure body inside `VendorCheckPlan(request:)`:

```swift
        return VendorCheckPlan(request: HTTPRequest(url: feedURL, enableETag: true)) { data in
            let installed = app.version ?? ""
            guard let result = AppcastParser.parseResult(data: data, installedVersion: installed),
                  let latest = result.latest.version else { return .decided(.failed) }
            guard !installed.isEmpty else { return .decided(.notApplicable) }
            // REL-10: compare versions, not strings. A plain `latest != installed` reports an
            // update whenever the feed lags behind the installed build, or merely formats the
            // version differently ("7.0.0" vs "7.0.0 (77593)") — both offer a downgrade.
            return .candidate(VendorCandidate(
                latest: latest,
                installed: installed,
                recordedInstalled: app.version,
                source: .sparkle,
                releaseNotes: ReleaseNotes(history: result.history, link: result.latest.releaseNotesLink)
            ))
        }
```

- [ ] **Step 5: Move the GitHub checker onto the releases list**

In `Sources/MacUpdaterCore/GitHubReleasesChecker.swift`, replace the endpoint and the evaluation closure:

```swift
        guard let url = AppEndpoints.shared.githubReleasesURL(repo: mapping.repo) else { return nil }

        // ETag-conditional + opcjonalny token (SEC-08). UWAGA: GitHub zwalnia 304
        // z primary rate-limit TYLKO dla żądań autoryzowanych (Bearer). Bez tokenu
        // 304 oszczędza transfer, nie kwotę 60/h — token podnosi limit do 5000/h.
        let request = HTTPRequest(url: url, headers: GitHubAuth.headers(), enableETag: true)
        return VendorCheckPlan(request: request) { data in
            // The list endpoint, not `/releases/latest`: one request either way, but this one
            // also carries every release the user is behind, which is the question the row
            // actually has to answer. Drafts and prereleases are filtered here rather than by
            // GitHub, and REL-11's SemVer ordering decides which release is newest.
            guard let releases = GitHubReleaseHistory.stableReleases(from: data) else {
                return .decided(.failed)
            }
            guard let newest = GitHubReleaseHistory.newest(releases) else { return .decided(.upToDate) }

            let installed = app.version ?? ""
            guard !installed.isEmpty else { return .decided(.notApplicable) }
            return .candidate(VendorCandidate(
                latest: normalizeGitTag(newest.tagName),
                installed: installed,
                recordedInstalled: app.version,
                source: .github(repo: mapping.repo, selfUpdates: mapping.selfUpdates),
                releaseNotes: ReleaseNotes(
                    history: GitHubReleaseHistory.history(releases, newerThan: installed, limit: 10)
                ),
                // REL-11: GitHub release tags are SemVer, so a prerelease must rank
                // below its own release instead of above it.
                scheme: .semver
            ))
        }
```

- [ ] **Step 6: Wrap the self-update notes**

In `Sources/MacUpdaterCore/ManualUpdateScanner.swift`, in `selfUpdateApp(from:appPath:installedVersion:bundleIdentifier:)`:

```swift
            releaseNotes: ReleaseNotes(html: notes, version: version),
```

- [ ] **Step 7: Update the four reading sites**

`Sources/MacUpdater/ScanStore.swift` (`isSecurityApp`):

```swift
    func isSecurityApp(_ app: ManualOutdatedApp) -> Bool {
        app.releaseNotes.map { ReleaseNotesTriage.heuristic($0.plainText).isLikelySecurityFix } ?? false
    }
```

`Sources/MacUpdater/UpdateViewSupport.swift` — the row badge (line 444) and the disclosure call (471-472):

```swift
                        let isSecurity = item.releaseNotes.map { ReleaseNotesTriage.heuristic($0.plainText).isLikelySecurityFix } ?? false
```
```swift
                if let notes = item.releaseNotes, !notes.isEmpty {
                    ReleaseNotesDisclosure(notes: notes)
```

…and replace the whole `ReleaseNotesDisclosure` struct (lines 665-695) with a version that renders the history. Task 6 gives it the link-fetching state; this step only makes it compile against the new type:

```swift
/// F1 — expands a row into the vendor's own release notes, one entry per release published
/// between the installed version and the one on offer.
///
/// The bodies arrived plain: `ReleaseNotes` is sanitised in Core, at the source that produced
/// it, so nothing here ever holds vendor HTML. Long histories are truncated in place with a
/// scroll rather than pushing the update list off screen.
struct ReleaseNotesDisclosure: View {
    let notes: ReleaseNotes

    @State private var expanded = false

    var body: some View {
        WegaDisclosure(isExpanded: $expanded) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(notes.history.notes) { note in
                        VStack(alignment: .leading, spacing: 2) {
                            if !note.version.isEmpty {
                                Text(note.version)
                                    .font(.wega(.subheadline, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }
                            Text(note.body)
                                .font(.wega(.subheadline))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if notes.history.omitted > 0 {
                        Text(trf("…i %@ wcześniejszych wydań", String(notes.history.omitted)))
                            .font(.wega(.subheadline))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.top, 4)
            }
            .frame(maxHeight: 160)
        } label: {
            Text(tr("Co nowego"))
                .font(.wega(.subheadline, weight: .medium))
                .foregroundStyle(.tertiary)
        }
    }
}
```

`Sources/MacUpdater/InspectorPane.swift` — line 95 and the What's-New body. The view stops sanitising, because there is nothing left to sanitise:

```swift
            let isSecurity = app.releaseNotes.map { ReleaseNotesTriage.heuristic($0.plainText).isLikelySecurityFix } ?? false
```

```swift
    @ViewBuilder
    private func whatsNewContent(notes: ReleaseNotes?) -> some View {
        // UX-05: nothing here sanitises, because nothing here holds markup. `ReleaseNotes`
        // is plain text by contract — `ReleaseNotesText` ran in Core, at the source that
        // produced it. Notes that collapsed to nothing never became an entry, so they fall
        // through to the "no notes" line exactly as the list's disclosure does.
        if let notes, !notes.history.notes.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if ReleaseNotesTriage.heuristic(notes.plainText).isLikelySecurityFix {
                    Label(tr("możliwa poprawka bezpieczeństwa"), systemImage: "shield.lefthalf.filled")
                        .font(.wega(.footnote, weight: .medium))
                        .foregroundStyle(Color.wegaDanger)
                }
                ForEach(notes.history.notes) { note in
                    VStack(alignment: .leading, spacing: 2) {
                        if !note.version.isEmpty {
                            Text(note.version)
                                .font(.wega(.subheadline, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        Text(note.body)
                            .font(.wega(.callout))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        } else {
            Text(tr("Brak informacji o zmianach"))
                .font(.wega(.subheadline))
                .foregroundStyle(.tertiary)
        }
    }
```

`Sources/MacUpdater/InfoView.swift:445` — the self-update badge still reads the checker's raw `notes` string, which did not change type. Leave it as it is.

- [ ] **Step 8: Rewrite the approved guard**

In `Tests/MacUpdaterTests/InspectorTrustWiringTests.swift`, replace `inspectorSharesTheReleaseNotesSanitizer`. The property being guarded is unchanged — the inspector must not render vendor markup — but it is now guaranteed upstream, so the guard asserts that the inspector reads the sanitised model and never reaches for HTML:

```swift
    @Test func inspectorRendersOnlySanitizedNotes() throws {
        let inspector = try source("InspectorPane.swift")
        #expect(inspector.contains("notes: ReleaseNotes?"),
                "UX-05: the inspector's What's-New must take the sanitized model, not raw markup")
        #expect(!inspector.contains("fromHTML:"),
                "UX-05: the inspector must never handle vendor HTML — ReleaseNotesText runs in Core")
    }
```

- [ ] **Step 9: Fix the remaining test call sites**

`Tests/MacUpdaterUITests/ScanStoreRuntimeActionTests.swift:165`:

```swift
            releaseNotes: ReleaseNotes(html: "Critical security fix"),
```

`Tests/MacUpdaterUITests/SelfUpdateManualSplitTests.swift:43`:

```swift
            releaseNotes: "",
```
becomes
```swift
            releaseNotes: nil,
```

> **Note for the implementer:** `swift build` will name any call site this list missed. Fix each by wrapping a literal in `ReleaseNotes(html:)` or by reading `.plainText` — do not reintroduce a `String?`.

- [ ] **Step 10: Run the tests to verify they pass**

Run: `swift test --filter "SparkleUpdateChecker|CheckFailureDistinction|InspectorTrustWiring|ManualUpdateScanner"`

`CheckFailureDistinction`, not `GitHubReleases`: the GitHub checker's only behavioural tests live
in `Tests/MacUpdaterTests/CheckFailureDistinctionTests.swift`, an `XCTestCase` with no `@Suite`
name, so a `GitHubReleases` filter matches nothing and silently skips exactly the code this step
changed.
Expected: PASS.

- [ ] **Step 11: Build and lint**

```bash
swift build && swiftlint lint --strict
```

- [ ] **Step 12: Commit**

```bash
git add -A
git commit -m "feat(updates): carry real release notes from Sparkle and GitHub into every manual row"
```

---

### Task 5: Fetching a notes page on demand

**Files:**
- Create: `Sources/MacUpdaterCore/ReleaseNotesLinkFetcher.swift`
- Test: `Tests/MacUpdaterTests/ReleaseNotesLinkFetcherTests.swift`

**Interfaces:**
- Consumes: `HTTPClient`, `ReleaseNotesText.plain(fromHTML:)`.
- Produces: `ReleaseNotesLinkFetcher(client:maxBytes:maxCharacters:)`, `func text(at: URL) async -> ReleaseNotesLinkFetcher.Outcome`, `Outcome.notes(text:truncated:) | .unavailable`. Consumed by Task 6.

- [ ] **Step 1: Write the failing test**

Create `Tests/MacUpdaterTests/ReleaseNotesLinkFetcherTests.swift`:

```swift
import Testing
import Foundation
@testable import MacUpdaterCore

@Suite("ReleaseNotesLinkFetcher")
struct ReleaseNotesLinkFetcherTests {

    /// `FakeHTTP` is the suite-wide double in `Tests/MacUpdaterTests/TestDoubles.swift` —
    /// no bespoke transport needed here.
    private func fetcher(
        body: String,
        status: Int = 200,
        maxBytes: Int = 256 * 1024,
        maxCharacters: Int = 20_000
    ) -> ReleaseNotesLinkFetcher {
        ReleaseNotesLinkFetcher(
            client: status == 200 ? FakeHTTP.client(ok: body) : FakeHTTP.client(status: status, body: body),
            maxBytes: maxBytes,
            maxCharacters: maxCharacters
        )
    }

    @Test func refusesPlainHttpWithoutAskingTheNetwork() async {
        let outcome = await fetcher(body: "<p>Notes</p>")
            .text(at: URL(string: "http://example.com/notes")!)

        #expect(outcome == .unavailable)
    }

    @Test func stripsMarkupFromTheFetchedPage() async {
        let outcome = await fetcher(body: "<html><body><h1>2.0</h1><p>Fixed a crash</p></body></html>")
            .text(at: URL(string: "https://example.com/notes")!)

        #expect(outcome == .notes(text: "2.0\nFixed a crash", truncated: false))
    }

    @Test func aNonOkStatusIsUnavailableNotEmptyNotes() async {
        let outcome = await fetcher(body: "", status: 503)
            .text(at: URL(string: "https://example.com/notes")!)

        #expect(outcome == .unavailable)
    }

    @Test func refusesAPageOverTheByteCap() async {
        let outcome = await fetcher(body: String(repeating: "a", count: 50), maxBytes: 10)
            .text(at: URL(string: "https://example.com/notes")!)

        #expect(outcome == .unavailable)
    }

    @Test func truncatesOverTheCharacterCapAndSaysSo() async {
        let outcome = await fetcher(body: String(repeating: "a", count: 50), maxCharacters: 10)
            .text(at: URL(string: "https://example.com/notes")!)

        #expect(outcome == .notes(text: String(repeating: "a", count: 10), truncated: true))
    }

    @Test func aPageThatIsAllMarkupIsUnavailable() async {
        let outcome = await fetcher(body: "<style>.a{color:red}</style>")
            .text(at: URL(string: "https://example.com/notes")!)

        #expect(outcome == .unavailable)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter ReleaseNotesLinkFetcher`
Expected: FAIL — `cannot find 'ReleaseNotesLinkFetcher' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/MacUpdaterCore/ReleaseNotesLinkFetcher.swift`:

```swift
import Foundation

/// Fetches the page a feed points at instead of carrying its notes inline
/// (`<sparkle:releaseNotesLink>`), on demand — never during a scan.
///
/// What comes back is a whole web page written by a third party, so three things are
/// non-negotiable: HTTPS only (SEC-09), a hard byte cap before anything is decoded, and
/// `ReleaseNotesText` over the result. A page that fails any of them is `.unavailable`,
/// which the UI states — an empty body would read as "this release changed nothing".
public struct ReleaseNotesLinkFetcher: Sendable {
    public enum Outcome: Equatable, Sendable {
        /// `truncated` is true when the character cap cut the text; the UI says so rather
        /// than letting the notes appear to stop mid-sentence for no reason.
        case notes(text: String, truncated: Bool)
        case unavailable
    }

    private let client: HTTPClient
    private let maxBytes: Int
    private let maxCharacters: Int

    public init(
        client: HTTPClient = .shared,
        maxBytes: Int = 256 * 1024,
        maxCharacters: Int = 20_000
    ) {
        self.client = client
        self.maxBytes = maxBytes
        self.maxCharacters = maxCharacters
    }

    public func text(at url: URL) async -> Outcome {
        guard url.scheme?.lowercased() == "https" else { return .unavailable }

        guard let response = try? await client.get(url), response.isOK else { return .unavailable }
        // Refused whole rather than truncated: cutting raw bytes can split a multi-byte
        // character or an entity, and a page this size is not notes anyway.
        guard response.data.count <= maxBytes else { return .unavailable }

        let plain = ReleaseNotesText.plain(fromHTML: String(decoding: response.data, as: UTF8.self))
        guard !plain.isEmpty else { return .unavailable }

        guard plain.count > maxCharacters else { return .notes(text: plain, truncated: false) }
        return .notes(text: String(plain.prefix(maxCharacters)), truncated: true)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter ReleaseNotesLinkFetcher`
Expected: PASS (6 tests).

- [ ] **Step 5: Build and lint**

```bash
swift build && swiftlint lint --strict
```

- [ ] **Step 6: Commit**

```bash
git add Sources/MacUpdaterCore/ReleaseNotesLinkFetcher.swift Tests/MacUpdaterTests/ReleaseNotesLinkFetcherTests.swift
git commit -m "feat(core): fetch a linked release-notes page on demand, capped and sanitized"
```

---

### Task 6: The disclosure loads a linked page when the user expands it

**Files:**
- Create: `Sources/MacUpdater/ReleaseNotesLoader.swift`
- Create: `Sources/MacUpdater/ReleaseNoteView.swift`
- Modify: `Sources/MacUpdaterCore/ReleaseNotes.swift` (add `hasRenderableNotes`)
- Modify: `Sources/MacUpdater/UpdateViewSupport.swift` (`ReleaseNotesDisclosure` from Task 4)
- Modify: `Sources/MacUpdater/InspectorPane.swift` (`whatsNewContent` uses the shared note view)
- Test: `Tests/MacUpdaterUITests/ReleaseNotesLoaderTests.swift`
- Test: `Tests/MacUpdaterTests/ReleaseNotesTests.swift` (add the `hasRenderableNotes` cases)

**Interfaces:**
- Consumes: `ReleaseNotes` (Task 1), `ReleaseNotesLinkFetcher` (Task 5).
- Produces: `ReleaseNotesLoader` (`@MainActor`, `ObservableObject`) with `State { idle, loading, loaded(text:truncated:), failed }`, `init(fetch:)` taking a non-`@Sendable` main-actor closure, `func loadIfNeeded(from link: URL?) async`, `func retry(from link: URL?) async`; `ReleaseNotes.hasRenderableNotes`; `ReleaseNoteView(note:bodyFont:)`.

**Why this task grew** (Task 4's review, three findings ruled by the controller):

1. A `ReleaseNotes` carrying *only* a link passes `!isEmpty`, so Task 4's disclosure renders a control that expands to nothing. That shape is ordinary — a Sparkle feed with `<sparkle:releaseNotesLink>` and no inline `<description>` produces exactly it.
2. The row asked `!notes.isEmpty` (a link counts) while the inspector asked `!notes.history.notes.isEmpty` (a link does not), so the same app could show a disclosure in the list and "Brak informacji o zmianach" in the inspector. Both compile; neither says which question it is asking.
3. The per-note rendering block was duplicated near-verbatim between the row and the inspector. The spec makes `ReleaseNotes` the single description of what an update brings; three renderings of it contradict that.

- [ ] **Step 1: Write the failing test**

Create `Tests/MacUpdaterUITests/ReleaseNotesLoaderTests.swift`:

```swift
import Testing
import Foundation
@testable import WegaMacUpdater
@testable import MacUpdaterCore

@MainActor
@Suite("ReleaseNotesLoader")
struct ReleaseNotesLoaderTests {

    private let link = URL(string: "https://example.com/notes")!

    @Test func startsIdleAndLoadsOnce() async {
        var calls = 0
        let loader = ReleaseNotesLoader { _ in
            calls += 1
            return .notes(text: "Fixed a crash", truncated: false)
        }

        #expect(loader.state == .idle)

        await loader.loadIfNeeded(from: link)
        await loader.loadIfNeeded(from: link)

        #expect(calls == 1)
        #expect(loader.state == .loaded(text: "Fixed a crash", truncated: false))
    }

    @Test func noLinkIsNotAFailedLoad() async {
        let loader = ReleaseNotesLoader { _ in .notes(text: "unused", truncated: false) }

        await loader.loadIfNeeded(from: nil)

        #expect(loader.state == .idle)
    }

    @Test func anUnavailablePageIsReportedAsFailed() async {
        let loader = ReleaseNotesLoader { _ in .unavailable }

        await loader.loadIfNeeded(from: link)

        #expect(loader.state == .failed)
    }

    @Test func aFailedLoadCanBeRetried() async {
        var outcomes: [ReleaseNotesLinkFetcher.Outcome] = [
            .unavailable,
            .notes(text: "Second time lucky", truncated: false),
        ]
        let loader = ReleaseNotesLoader { _ in outcomes.removeFirst() }

        await loader.loadIfNeeded(from: link)
        #expect(loader.state == .failed)

        await loader.retry(from: link)
        #expect(loader.state == .loaded(text: "Second time lucky", truncated: false))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter ReleaseNotesLoader`
Expected: FAIL — `cannot find 'ReleaseNotesLoader' in scope`.

- [ ] **Step 3: Write the loader**

Create `Sources/MacUpdater/ReleaseNotesLoader.swift`:

```swift
import Foundation
import MacUpdaterCore

/// The state behind a row's "Co nowego" when the feed published a link instead of a body.
///
/// Lives outside the view so the rule — load once, on first expansion, never during a scan —
/// is testable without SwiftUI. A row nobody expands makes no request at all, which is the
/// whole reason the fetch is here and not in `ManualUpdateScanner`.
@MainActor
final class ReleaseNotesLoader: ObservableObject {
    enum State: Equatable {
        case idle
        case loading
        case loaded(text: String, truncated: Bool)
        case failed
    }

    @Published private(set) var state: State = .idle

    // Not `@Sendable`: the class is already `@MainActor`, so the closure is main-actor
    // isolated and needs no extra guarantee. Marking it `@Sendable` would also forbid the
    // tests from counting calls in a captured local.
    private let fetch: (URL) async -> ReleaseNotesLinkFetcher.Outcome

    init(fetch: @escaping (URL) async -> ReleaseNotesLinkFetcher.Outcome) {
        self.fetch = fetch
    }

    convenience init(fetcher: ReleaseNotesLinkFetcher = ReleaseNotesLinkFetcher()) {
        self.init { await fetcher.text(at: $0) }
    }

    /// Loads exactly once. A second expansion of the same row re-reads what is already here.
    func loadIfNeeded(from link: URL?) async {
        guard case .idle = state else { return }
        await load(from: link)
    }

    /// The user asking again after a failure — the one way back out of `.failed`.
    func retry(from link: URL?) async {
        guard case .failed = state else { return }
        await load(from: link)
    }

    private func load(from link: URL?) async {
        guard let link else { return }
        state = .loading
        switch await fetch(link) {
        case .notes(let text, let truncated):
            state = .loaded(text: text, truncated: truncated)
        case .unavailable:
            state = .failed
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter ReleaseNotesLoader`
Expected: PASS (4 tests).

- [ ] **Step 5: Name the two questions, and draw a note in one place**

In `Sources/MacUpdaterCore/ReleaseNotes.swift`, add the second predicate beside `isEmpty`:

```swift
    /// Whether there is text to draw *right now*, without fetching anything. A value
    /// carrying only a `link` is not empty — something can still be shown once it is
    /// fetched — but it has nothing to render yet, and the two questions have different
    /// answers often enough that each caller must say which one it is asking.
    public var hasRenderableNotes: Bool { !history.notes.isEmpty }
```

Add the two cases to `Tests/MacUpdaterTests/ReleaseNotesTests.swift`:

```swift
    @Test func aLinkAloneHasNothingToRenderYet() {
        let notes = ReleaseNotes(history: ReleaseHistory(notes: [], omitted: 0),
                                 link: URL(string: "https://example.com/notes")!)

        #expect(notes.isEmpty == false)
        #expect(notes.hasRenderableNotes == false)
    }

    @Test func entriesMeanThereIsSomethingToRender() {
        let notes = ReleaseNotes(html: "Fixed a crash", version: "2.0.0")

        #expect(notes.hasRenderableNotes)
    }
```

Then create `Sources/MacUpdater/ReleaseNoteView.swift` — one rendering of one release, so the row and the inspector cannot drift apart:

```swift
import MacUpdaterCore
import SwiftUI

/// One release's notes: its version, then its body.
///
/// The row and the inspector show the same thing at different sizes, so only the body font
/// varies. Keeping it one view is what stops a change to how a release reads from having to
/// be made twice and being made once.
///
/// `note.body` arrived plain — `ReleaseNotes` is sanitised in Core, at the source that
/// produced it — so nothing here strips markup (UX-05).
struct ReleaseNoteView: View {
    let note: ReleaseNote
    var bodyFont: Font

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // A version is missing only for notes decoded from the pre-`ReleaseNotes`
            // snapshot shape, which recorded none. Better no heading than an empty one.
            if !note.version.isEmpty {
                Text(note.version)
                    .font(.wega(.subheadline, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Text(note.body)
                .font(bodyFont)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
```

Replace the per-note `VStack` inside `InspectorPane.whatsNewContent`'s `ForEach` with `ReleaseNoteView(note: note, bodyFont: .wega(.callout))`, and change that function's guard from `!notes.history.notes.isEmpty` to `notes.hasRenderableNotes` so it states the question it is asking.

- [ ] **Step 6: Wire the loader into the disclosure**

In `Sources/MacUpdater/UpdateViewSupport.swift`, extend `ReleaseNotesDisclosure` from Task 4: it renders the history through the shared view, and gains the linked-page branch. Note the `if notes.hasRenderableNotes` guard around the list — without it, a link-only value renders an empty `VStack` and the user expands a control to nothing.

```swift
struct ReleaseNotesDisclosure: View {
    let notes: ReleaseNotes

    @State private var expanded = false
    @StateObject private var loader = ReleaseNotesLoader()

    var body: some View {
        WegaDisclosure(isExpanded: $expanded) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    // Guarded, not merely empty-looping: a link-only value has no entries
                    // and no omitted count, and without this the disclosure would render an
                    // empty stack the user expands to nothing.
                    if notes.hasRenderableNotes {
                        ForEach(notes.history.notes) { note in
                            ReleaseNoteView(note: note, bodyFont: .wega(.subheadline))
                        }
                        if notes.history.omitted > 0 {
                            Text(trf("…i %@ wcześniejszych wydań", String(notes.history.omitted)))
                                .font(.wega(.subheadline))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    linkedNotes
                }
                .padding(.top, 4)
            }
            .frame(maxHeight: 160)
        } label: {
            Text(tr("Co nowego"))
                .font(.wega(.subheadline, weight: .medium))
                .foregroundStyle(.tertiary)
        }
        // The fetch belongs to the expansion, not to the scan: a row nobody opens costs
        // nothing. `.task(id:)` re-runs on collapse too, which `loadIfNeeded` absorbs.
        .task(id: expanded) {
            guard expanded else { return }
            await loader.loadIfNeeded(from: notes.link)
        }
    }

    /// The branch for a feed that published a link instead of a body.
    @ViewBuilder
    private var linkedNotes: some View {
        switch loader.state {
        case .idle:
            EmptyView()
        case .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(tr("Pobieram notatki wydania…"))
                    .font(.wega(.subheadline))
                    .foregroundStyle(.tertiary)
            }
        case .loaded(let text, let truncated):
            VStack(alignment: .leading, spacing: 4) {
                Text(text)
                    .font(.wega(.subheadline))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if truncated, let link = notes.link {
                    HStack(spacing: 6) {
                        Text(tr("Notatki są dłuższe — to początek"))
                            .font(.wega(.footnote))
                            .foregroundStyle(.tertiary)
                        Link(tr("Zobacz pełne notatki"), destination: link)
                            .font(.wega(.footnote))
                    }
                }
            }
        case .failed:
            HStack(spacing: 6) {
                Text(tr("Nie udało się pobrać notatek wydania"))
                    .font(.wega(.subheadline))
                    .foregroundStyle(.tertiary)
                Button(tr("Spróbuj ponownie")) {
                    Task { await loader.retry(from: notes.link) }
                }
                .controlSize(.small)
                if let link = notes.link {
                    Link(tr("Zobacz u wydawcy"), destination: link).font(.wega(.subheadline))
                }
            }
        }
    }
}
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `swift test --filter "ReleaseNotesLoader|ReleaseNotes"`
Expected: PASS — the loader's four cases plus the two new `hasRenderableNotes` cases, and every pre-existing `ReleaseNotes` case still green.

- [ ] **Step 8: Build and lint**

```bash
swift build && swiftlint lint --strict
```

- [ ] **Step 9: Commit**

```bash
git add Sources/MacUpdaterCore/ReleaseNotes.swift Sources/MacUpdater/ReleaseNotesLoader.swift Sources/MacUpdater/ReleaseNoteView.swift Sources/MacUpdater/UpdateViewSupport.swift Sources/MacUpdater/InspectorPane.swift Tests/MacUpdaterUITests/ReleaseNotesLoaderTests.swift Tests/MacUpdaterTests/ReleaseNotesTests.swift
git commit -m "feat(ui): load a linked release-notes page when the row is expanded"
```

---

### Task 7: Batch rows show what they have

**Files:**
- Modify: `Sources/MacUpdaterCore/UpdatePlanner.swift:23,25,31` (`OutdatedItem.releaseNotes` type) and add `attachingReleaseNotes`
- Modify: `Sources/MacUpdater/ScanStore.swift:411-416` (`allItems`)
- Modify: `Sources/MacUpdater/UpdateViewSupport.swift` (`UpdateSection` row body)
- Modify: `Sources/MacUpdater/InspectorPane.swift` (the `.outdated` case of `whatsNewSection`)
- Test: `Tests/MacUpdaterTests/UpdatePlannerTests.swift`

**Interfaces:**
- Consumes: `ReleaseNotes` (Task 1), `ManualOutdatedApp.releaseNotes` (Task 4), `ReleaseNotesDisclosure` (Task 6).
- Produces: `UpdatePlanner.attachingReleaseNotes(to:manual:caskAppPaths:) -> [OutdatedItem]`.

- [ ] **Step 1: Write the failing test**

Append to `Tests/MacUpdaterTests/UpdatePlannerTests.swift`:

```swift
    @Test func attachesCaskNotesWhenTheVersionOnOfferMatches() {
        let appPath = URL(fileURLWithPath: "/Applications/Example.app")
        let items = [OutdatedItem(key: "c:example", name: "example", from: "1.0.0", to: "2.0.0", kind: .cask)]
        let manual = [ManualOutdatedApp(
            name: "Example", path: appPath,
            installedVersion: "1.0.0", availableVersion: "2.0.0",
            source: .sparkle,
            releaseNotes: ReleaseNotes(html: "Fixed a crash", version: "2.0.0")
        )]

        let joined = UpdatePlanner.attachingReleaseNotes(
            to: items, manual: manual, caskAppPaths: ["example": appPath]
        )

        #expect(joined.first?.releaseNotes?.history.notes.first?.body == "Fixed a crash")
    }

    @Test func refusesNotesDescribingADifferentVersion() {
        let appPath = URL(fileURLWithPath: "/Applications/Example.app")
        let items = [OutdatedItem(key: "c:example", name: "example", from: "1.0.0", to: "2.0.0", kind: .cask)]
        let manual = [ManualOutdatedApp(
            name: "Example", path: appPath,
            installedVersion: "1.0.0", availableVersion: "3.0.0",
            source: .sparkle,
            releaseNotes: ReleaseNotes(html: "Notes for a release nobody offered")
        )]

        let joined = UpdatePlanner.attachingReleaseNotes(
            to: items, manual: manual, caskAppPaths: ["example": appPath]
        )

        #expect(joined.first?.releaseNotes == nil)
    }

    @Test func sourcesWithNoAppPathAreLeftAlone() {
        let items = [
            OutdatedItem(key: "f:jq", name: "jq", from: "1.6", to: "1.7", kind: .formula),
            OutdatedItem(key: "a:497799835", name: "497799835", from: "1.0", to: "2.0", kind: .appStore),
            OutdatedItem(key: "n:typescript", name: "typescript", from: "5.0.0", to: "5.1.0", kind: .npm),
        ]

        let joined = UpdatePlanner.attachingReleaseNotes(to: items, manual: [], caskAppPaths: [:])

        #expect(joined.allSatisfy { $0.releaseNotes == nil })
        #expect(joined.map(\.key) == items.map(\.key))
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter UpdatePlanner`
Expected: FAIL — `type 'UpdatePlanner' has no member 'attachingReleaseNotes'`.

- [ ] **Step 3: Change the field type and add the join**

In `Sources/MacUpdaterCore/UpdatePlanner.swift`, `OutdatedItem`:

```swift
    /// What this update brings (F1), when a source in the same scan could supply it.
    /// Sources that publish nothing leave it `nil`, and the row then shows no disclosure
    /// at all — Wega does not invent a "no changes" it cannot know.
    public var releaseNotes: ReleaseNotes?
```
```swift
    public init(key: String, name: String, from: String?, to: String?, kind: Kind, releaseNotes: ReleaseNotes? = nil) {
```

Add the join as a static member of `UpdatePlanner`:

```swift
    /// Lends each batch row the notes another source in the *same scan* already found for it.
    ///
    /// Only casks can be joined, and only through the token → app-path map the scan builds
    /// anyway (`ScanStore.caskIconPaths`): a formula, an npm package and an App Store row have
    /// no bundle to match against. The version must agree — notes describing a release nobody
    /// is offering would be worse than no notes at all.
    public static func attachingReleaseNotes(
        to items: [OutdatedItem],
        manual: [ManualOutdatedApp],
        caskAppPaths: [String: URL]
    ) -> [OutdatedItem] {
        guard !manual.isEmpty else { return items }
        let notesByPath = Dictionary(
            manual.compactMap { app in app.releaseNotes.map { (app.path, (notes: $0, version: app.availableVersion)) } },
            uniquingKeysWith: { first, _ in first }
        )

        return items.map { item in
            // `target` must exist: two rows that both say "version unknown" are not a match,
            // they are two unknowns, and attaching on that would be guessing.
            guard item.kind == .cask,
                  let target = item.to,
                  let path = caskAppPaths[item.name],
                  let match = notesByPath[path],
                  match.version == target,
                  !match.notes.isEmpty else { return item }
            var enriched = item
            enriched.releaseNotes = match.notes
            return enriched
        }
    }
```

- [ ] **Step 4: Apply the join in the store**

In `Sources/MacUpdater/ScanStore.swift`, `allItems`:

```swift
    var allItems: [OutdatedItem] {
        UpdatePlanner.applyPolicies(
            UpdatePlanner.attachingReleaseNotes(
                to: UpdatePlanner.outdatedItems(brew: brewOutdated, mas: masOutdated, npm: npmOutdated),
                manual: manualOutdated,
                caskAppPaths: caskIconPaths
            ),
            policies: UpdatePolicyStore.shared.policiesMap
        )
    }
```

- [ ] **Step 5: Render the disclosure under a batch row**

In `Sources/MacUpdater/UpdateViewSupport.swift`, inside `UpdateSection`'s `ForEach(items) { item in ... }`, wrap `PackageRow` so the notes sit beneath it — the shape `ManualUpdateSection` already uses. Replace the `PackageRow(...)` call and its modifiers with:

```swift
                VStack(spacing: 0) {
                    PackageRow(
                        name:           item.name,
                        iconPath:       iconPaths[item.name],
                        currentVersion: item.from,
                        latestVersion:  item.to,
                        isSelected:     selected.contains(item.key),
                        isInspected:    item.key == inspectedKey,
                        rollback:       rollbackProtection[item.name],
                        onToggle:       { toggle(item.key) },
                        onSelect:       { onInspect?(item) },
                        onIgnore:       { onIgnore?(item) },
                        onPin:          { onPin?(item) },
                        onSkip:         skipAction(for: item),
                        backgroundUpdateToken: item.kind == .cask ? item.name : nil
                    )
                    // F1 — the same disclosure the manual rows use. Rows whose source
                    // published nothing have none, rather than an empty "no changes".
                    if let notes = item.releaseNotes, !notes.isEmpty {
                        ReleaseNotesDisclosure(notes: notes)
                            .padding(.horizontal, 14)
                            .padding(.bottom, 10)
                    }
                }
                .contextMenu {
                    UpdatePolicyMenu(onIgnore: { onIgnore?(item) }, onPin: { onPin?(item) }, onSkip: skipAction(for: item))
                }
                .overlay(alignment: .bottom) {
                    if item.id != items.last?.id { Divider().opacity(0.4).padding(.leading, 54) }
                }
```

- [ ] **Step 6: Let the inspector show them too**

In `Sources/MacUpdater/InspectorPane.swift`, the `.outdated` case of `whatsNewSection` currently states, unconditionally, that the source has no notes. It now defers to the same renderer as the manual case:

```swift
            // `InspectedUpdate.outdated(OutdatedItem, iconPath: URL?)` — see UpdateView.swift:9.
            case .outdated(let item, _):
                whatsNewContent(notes: item.releaseNotes)
```

The bespoke "Informacje o zmianach niedostępne dla tego źródła" line for this case goes away:
`whatsNewContent` already renders "Brak informacji o zmianach" when there is nothing, and that
is now the truthful answer for a batch row too. Leave the string in `Translations.swift` —
`LocalizationCompletenessTests` only fails on untranslated keys, never on unused ones.

While you are in that function: "nothing to render" and "nothing at all" are not the same, and
the inspector does not fetch. Replace its bare `else` branch so a value that carries only a link
offers the link instead of claiming there are no notes:

```swift
        } else if let link = notes?.link {
            Link(tr("Zobacz notatki wydania"), destination: link)
                .font(.wega(.callout))
        } else {
            Text(tr("Brak informacji o zmianach"))
                .font(.wega(.subheadline))
                .foregroundStyle(.tertiary)
        }
```

`"Zobacz notatki wydania"` is a new `tr(...)` literal — Task 8 adds its English counterpart.

- [ ] **Step 7: Run the tests to verify they pass**

Run: `swift test --filter UpdatePlanner`
Expected: PASS — the three new cases plus every pre-existing one.

- [ ] **Step 8: Build and lint**

```bash
swift build && swiftlint lint --strict
```

- [ ] **Step 9: Commit**

```bash
git add -A
git commit -m "feat(updates): show release notes on Homebrew, App Store and npm rows too"
```

---

### Task 8: Translations, documentation, changelog

**Files:**
- Modify: `Sources/MacUpdaterCore/Translations.swift`
- Modify: `docs/features.md:326`
- Modify: `CHANGELOG.md` (`## [Unreleased]` → `### Added`)
- Test: `Tests/MacUpdaterTests/LocalizationCompletenessTests.swift` (no edit — it must simply pass)

**Interfaces:**
- Consumes: the `tr(...)`/`trf(...)` literals introduced in Task 6.
- Produces: nothing other code depends on.

- [ ] **Step 1: Run the localization guard to see it fail**

Run: `swift test --filter LocalizationCompleteness`
Expected: FAIL — naming the untranslated Polish keys added in Task 6.

- [ ] **Step 2: Add the English counterparts**

In `Sources/MacUpdaterCore/Translations.swift`, beside the existing `"Co nowego": "What's new",` entry:

```swift
        "Pobieram notatki wydania…": "Fetching release notes…",
        "Nie udało się pobrać notatek wydania": "Could not fetch the release notes",
        "Notatki są dłuższe — to początek": "The notes are longer — this is the start",
        "Zobacz pełne notatki": "See the full notes",
        "Zobacz u wydawcy": "See at the publisher",
        "Zobacz notatki wydania": "See the release notes",
        "Spróbuj ponownie": "Try again",
```

Two facts about that dictionary, both checked against the current file:

- `"…i %@ wcześniejszych wydań"` is **already** there — `InfoView`'s self-update history uses
  it. It is keyed by the Polish string, so adding it again is a duplicate-key build error.
- `"Spróbuj ponownie"` is **not** there. `Translations.swift:414` has a longer sentence that
  merely ends with those words; the scanner keys on whole literals, so the short form is new.

- [ ] **Step 3: Run the guard to verify it passes**

Run: `swift test --filter LocalizationCompleteness`
Expected: PASS.

- [ ] **Step 4: Update the feature documentation**

In `docs/features.md`, replace the line at 326:

```markdown
- **Co nowego** shows the real release notes for every version you are behind, not just the
  newest one, wherever the source publishes them — a Sparkle appcast or a GitHub release. When
  the feed publishes a link instead of the text, Wega fetches that page the moment you expand
  the row, never during a scan. Sources that publish nothing show nothing. The advisory
  „możliwa poprawka bezpieczeństwa" badge reads the whole history, so a security fix two
  releases back is still flagged.
```

- [ ] **Step 5: Add the changelog entry**

In `CHANGELOG.md`, under `## [Unreleased]` → `### Added`, as a new first bullet:

```markdown
- **Every update says what it brings, before you apply it** — Wega now keeps the release notes
  it was already downloading. A Sparkle appcast's `<description>` was parsed and thrown away on
  the next line; it is now shown in the row, one entry per release between the version you have
  and the one on offer. Apps tracked through GitHub Releases gained the same history, from the
  same single request. Where a feed publishes a link instead of the text, expanding the row
  fetches that page — capped, stripped of markup, and never during a scan. Homebrew, App Store
  and npm rows render the same disclosure when another source in the same scan found notes for
  that exact version. The advisory security badge now reads the whole history rather than the
  newest release alone.
```

- [ ] **Step 6: Build and lint**

```bash
swift build && swiftlint lint --strict
```

- [ ] **Step 7: Commit**

```bash
git add Sources/MacUpdaterCore/Translations.swift docs/features.md CHANGELOG.md
git commit -m "docs(release-notes): document what an update now tells you before you apply it"
```

---

## Verification before handoff

- [ ] `swift build` clean
- [ ] `swiftlint lint --strict` clean
- [ ] `git status --short --untracked-files=all --ignored=matching` reviewed — nothing uncommitted except regenerable build output
- [ ] Handoff states plainly which suites were run under `--filter` and that **the full suite was never run**, naming what is outstanding: `swift test` in full, and `scripts/check.sh` (which runs build, the full suite, and SwiftLint together)
