# Know what an update brings, before applying it

**Date:** 2026-09-22
**Status:** approved

## Problem

Wega offers an update and says only how the version number changes. For every source but one,
it cannot answer the question the user actually has — *what do I get if I press this?*

The material is already on the wire and thrown away:

- `AppcastParser` parses `<description>` and `<sparkle:releaseNotesLink>` into `AppcastItem`
  ([`SparkleUpdateChecker.swift`](../../../Sources/MacUpdaterCore/SparkleUpdateChecker.swift)),
  and then `SparkleUpdateChecker.plan(for:)` calls `AppcastParser.parse(data:)`, whose entire
  return value is a version string. Every Sparkle-fed app — most self-updating `.app`s on a
  Mac — loses its notes at that line.
- `GitHubReleasesChecker` is the only vendor checker that fills `VendorCandidate.releaseNotes`,
  and it fills it with the body of `/releases/latest` alone. Three versions behind, the user is
  told about one of them.
- `OutdatedItem.releaseNotes` exists in the model and is never assigned, so no Homebrew,
  App Store or npm row in the batch list has ever shown notes.

The presentation layer, by contrast, is finished and waiting: an inline "Co nowego" disclosure
in manual rows, a What's-New section in the inspector, and the advisory
"możliwa poprawka bezpieczeństwa" badge driven by `ReleaseNotesTriage`.

Wega's own self-update is the exception that proves the point. `ReleaseHistoryFetcher` already
answers the cumulative question for Wega — every release between installed and newest, newest
first, sanitized, capped, with a count of what the cap omitted — and `InfoView` renders it.
No other application gets that treatment.

## Decision

Reuse what exists. No new update sources, no new vendors, no inferring a repository from a
cask's homepage. Everything below is extracted from feeds Wega already fetches, plus one
on-demand request for feeds that publish a link instead of a body.

### 1. One notes type in Core

`releaseNotes` is a bare `String?` holding raw vendor HTML, sanitized separately by each view.
It becomes a type that carries both shapes the feeds actually produce:

```swift
public struct ReleaseNotes: Codable, Equatable, Sendable {
    public var history: ReleaseHistory   // entries already in hand; may be empty
    public var link: URL?                // HTTPS only (SEC-09); fetched on demand
    public var plainText: String         // joined bodies — the input to triage
    public var isEmpty: Bool             // no entries and no link
}
```

`ReleaseNote` and `ReleaseHistory` already exist in
[`ReleaseHistory.swift`](../../../Sources/MacUpdaterCore/ReleaseHistory.swift) and gain
`Codable`. They become the single description of "what this update brings" everywhere in the
app, Wega's own update included.

The field changes type in three places: `ManualOutdatedApp.releaseNotes`,
`VendorCandidate.releaseNotes`, `OutdatedItem.releaseNotes`.

**Sanitization moves into Core.** Today two views call `ReleaseNotesText.plain(fromHTML:)`
independently, at render time. After this change `ReleaseNote.body` is plain text by contract —
which is what its own documentation already promises — and the views only draw it. One
sanitizer, one call site per source, no view holding vendor HTML.

**Legacy snapshots.** `ManualOutdatedApp` is persisted in the scan snapshot, and
[`ScanResultStore.swift`](../../../Sources/MacUpdaterCore/ScanResultStore.swift) decodes it with
`try?`: a file written by the previous version, with `releaseNotes` as a string, would fail to
decode and the whole snapshot would silently become `nil` — the first launch after updating
would show an empty list until a rescan. `ReleaseNotes` therefore decodes a bare string as a
one-entry history whose `version` is empty and whose `publishedAt` is `nil` — the honest
reading, since the old shape recorded neither. The next scan replaces it with a real history.

### 2. Sparkle — stop discarding what is already parsed

`AppcastParser` gains `parseHistory(data:installed:limit:)`: items on Sparkle's default channel
whose version is newer than the installed one, ordered newest first, capped at 10, with the
remainder reported as `omitted` rather than dropped silently. That is the rule
`ReleaseHistoryFetcher` already applies to Wega's own releases — same limit, same `omitted`
contract — applied to an appcast.

The parser starts reading `<pubDate>` so an entry can carry its date. Bodies pass through
`ReleaseNotesText.plain(fromHTML:)` inside the parser, before anything else sees them.

`SparkleUpdateChecker.plan(for:)` builds `ReleaseNotes(history:link:)`, where `link` is the
chosen item's `releaseNotesLink`. The existing version-only `AppcastParser.parse(data:)` stays:
`SparkleFeedOverridesTests` and the checker's own tests use it, and nothing is served by
deleting it.

This is the whole cost of "every version I am behind" for Sparkle. The feed is already
fetched and every `<item>` already parsed.

### 3. GitHub — one request, the same history

`GitHubReleasesChecker` asks `githubLatestReleaseURL`, so it can only ever know about one
release. It switches to the releases list — same host, same rate limit, still exactly one
request per app — and the draft/prerelease filtering and SemVer ordering move into a shared
helper that `ReleaseHistoryFetcher` uses too. That logic currently exists twice; afterwards it
exists once.

The trade this makes is explicit: selecting "the latest release" moves from GitHub's server to
our code. Drafts and prereleases must be filtered client-side, and REL-11's rule (a prerelease
ranks below its own release under `.semver`) applies to the selection, not just the comparison.
Both are pinned by tests.

### 4. A link instead of a body — fetched when the user asks

Many appcasts carry `<sparkle:releaseNotesLink>` and no inline description. A new
`ReleaseNotesLinkFetcher` in Core resolves those: HTTPS only, injectable `HTTPClient`, response
run through `ReleaseNotesText`, with a hard cap on both the response size (256 KB, refused
beyond that rather than truncated mid-entity) and the resulting text (20 000 characters,
truncated with the fact stated on screen) — a vendor's release-notes page is a whole web page
and can be megabytes.

`ReleaseNotesDisclosure` gains `idle → loading → loaded | failed`, entered on first expansion.
A row nobody expands costs nothing: no request is made during a scan. A failure renders a short
message and the link itself, never an empty box.

### 5. Batch rows

`UpdateSection` renders the same disclosure the manual rows use. The data comes from what the
scan already collected: an index of notes by application path, built from `manualOutdated`,
joined for casks through the token → app-path map that already exists as `caskIconPaths`
([`ScanStore+Scanning.swift`](../../../Sources/MacUpdater/ScanStore+Scanning.swift)). A note
attaches only when the version it describes matches the row's target version.

**A limitation to state rather than paper over:** under the chosen sources, Homebrew formulae,
npm packages and App Store rows will essentially never carry notes. Wega does not have them and
will not invent them. A row without notes shows nothing at all — the rule the code already
follows, and the reason it reads "the UI says nothing rather than inventing a 'no changes' that
it cannot know".

### 6. Security triage improves for free

`ReleaseNotesTriage.heuristic` runs over `ReleaseNotes.plainText` — the whole history — instead
of one release body. The advisory badge, `ScanStore.isSecurityApp`, the "tylko bezpieczeństwo"
filter and the footer count all start seeing a security fix published two releases back, which
today is invisible to every one of them.

The triage contract does not change: advisory only, never a gate, never an auto-apply.

### 7. Security properties

Everything here is third-party text, fetched over the network, rendered inside Wega's window.

- Feeds and notes links are HTTPS only (SEC-09). A plain-HTTP link is dropped, exactly as
  `AppcastParser` already drops it.
- No markup is rendered. `ReleaseNotesText` keeps no tags, and drops `<script>`, `<style>` and
  `<head>` bodies whole. It is applied in Core, once per source.
- Fetched pages are capped in both bytes and characters, so a hostile or merely enormous page
  cannot exhaust memory.
- No HTML is stored in the snapshot: what is persisted is already plain text.

### 8. Testing

Written, not executed — per the project's working agreement, the gate is the formatter and the
linter, and test runs are opt-in. The handoff will name what is left to run.

Core:

- appcast history — channel selection, ordering, the cap and its `omitted` count, CDATA bodies,
  items with no `pubDate`, an appcast whose only notes are a link;
- GitHub history — drafts and prereleases excluded, SemVer ordering, a release list where the
  newest tag is not first;
- `ReleaseNotesLinkFetcher` — an `http://` link refused, the size cap enforced, a transport
  failure reported as a failure rather than as empty notes;
- `ReleaseNotes` decoding a legacy string-shaped snapshot.

Application layer:

- the disclosure's state machine, including the failure path;
- the batch-row join: matching version attaches, mismatched version does not;
- `LocalizationCompletenessTests` covers the new `tr(...)` strings, which need English
  counterparts in `Translations.en`.

### 9. One pre-existing test changes, with approval

[`InspectorTrustWiringTests.inspectorSharesTheReleaseNotesSanitizer`](../../../Tests/MacUpdaterTests/InspectorTrustWiringTests.swift)
asserts that `InspectorPane.swift` literally contains `ReleaseNotesText.plain(fromHTML:`. Its
purpose (UX-05) is that the inspector must never render unsanitized vendor HTML. Moving
sanitization into Core satisfies that purpose more strongly — the inspector no longer has HTML
to mishandle — while removing the literal the test looks for.

The guard is rewritten to assert the new invariant: the inspector renders `ReleaseNote.body`
and does not reach for raw HTML anywhere. The protected property survives; only its wording
changes. The owner approved this modification on 2026-09-22 before implementation began.

## Out of scope

- Mac App Store notes via the iTunes Lookup API, npm changelogs, and inferring a GitHub
  repository from a cask's homepage. All three were considered and declined: they add request
  volume, new failure modes, and — for homepage inference — a real chance of showing somebody
  else's notes.
- A separate "what will change" sheet before a batch update. Notes belong in the rows.
- Wega's own self-update path. `ReleaseHistoryFetcher` and `SelfUpdateController` already do
  this correctly; they are reused, not rewritten.

## Risks

- **Appcast variety.** Feeds differ wildly in how they express versions and channels. The
  history parser inherits `parseItem`'s existing channel rule, so a feed that only publishes on
  a named channel still works, and one with no comparable versions yields no history rather
  than a wrong one.
- **Duplicate rows.** A brew-managed cask that is outdated in `brew outdated` and also has a
  Sparkle feed can already appear in both the batch section and the manual section. This change
  does not create that situation and does not fix it; it will now show the same notes in both
  places. Worth a separate look.
- **GitHub rate limit.** Unchanged in request count, but the releases list is a larger response
  than `/releases/latest`. ETag conditional requests still apply, and SEC-08's optional token
  still raises the limit.
