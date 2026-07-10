# Migration App Store Candidates Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the Migration view to also identify manually-installed apps that have a Mac App Store equivalent, using `mas search`, and present them with an "Open in App Store" action.

**Architecture:** A new `MasSearchParser` struct parses `mas search` output; `MasService` gains a `search(name:)` method that runs the search and matches by normalized name; `MigrationView` runs searches in parallel via `TaskGroup` and displays a new "App Store candidates" section.

**Tech Stack:** Swift 5.9+, SwiftUI, XCTest, `mas` CLI, `NSWorkspace`

---

### Task 1: `MasSearchParser` — parse `mas search` output

**Files:**
- Create: `Sources/MacUpdaterCore/MasSearchParser.swift`
- Create: `Tests/MacUpdaterTests/MasSearchParserTests.swift`
- Create: `Tests/MacUpdaterTests/Fixtures/mas-search.txt`

- [ ] **Step 1: Create the fixture file**

Create `Tests/MacUpdaterTests/Fixtures/mas-search.txt` with this content (two spaces between columns, as `mas search` produces):

```
  324684580  Spotify - Music and Podcasts             1.2.13.841
  497799835  Xcode                                    16.2
  409183694  Keynote                                  14.3
```

- [ ] **Step 2: Write the failing tests**

Create `Tests/MacUpdaterTests/MasSearchParserTests.swift`:

```swift
import XCTest
@testable import MacUpdaterCore

final class MasSearchParserTests: XCTestCase {
    private let parser = MasSearchParser()

    func testParsesFixture() throws {
        let output = try fixtureString(named: "mas-search", extension: "txt")
        let results = parser.parse(output)

        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(results[0].appStoreID, "324684580")
        XCTAssertEqual(results[0].name, "Spotify - Music and Podcasts")
        XCTAssertEqual(results[1].appStoreID, "497799835")
        XCTAssertEqual(results[1].name, "Xcode")
        XCTAssertEqual(results[2].appStoreID, "409183694")
        XCTAssertEqual(results[2].name, "Keynote")
    }

    func testIgnoresBlankLines() {
        let output = "\n  324684580  Spotify - Music and Podcasts             1.2.13\n\n"
        let results = parser.parse(output)
        XCTAssertEqual(results.count, 1)
    }

    func testIgnoresMalformedLines() {
        let output = "not a valid line\n  324684580  Spotify - Music and Podcasts             1.2.13"
        let results = parser.parse(output)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].appStoreID, "324684580")
    }

    func testReturnsEmptyForEmptyInput() {
        XCTAssertTrue(parser.parse("").isEmpty)
    }
}
```

- [ ] **Step 3: Run tests to confirm they fail**

```bash
swift test --filter MasSearchParserTests 2>&1
```

Expected: compile error — `MasSearchParser` does not exist yet.

- [ ] **Step 4: Create `MasSearchParser`**

Create `Sources/MacUpdaterCore/MasSearchParser.swift`:

```swift
import Foundation

public struct MasSearchResult: Equatable, Sendable {
    public let appStoreID: String
    public let name: String

    public init(appStoreID: String, name: String) {
        self.appStoreID = appStoreID
        self.name = name
    }
}

public struct MasSearchParser {
    public init() {}

    public func parse(_ output: String) -> [MasSearchResult] {
        output
            .split(whereSeparator: \.isNewline)
            .compactMap { parseLine(String($0)) }
    }

    private func parseLine(_ line: String) -> MasSearchResult? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Format: "  123456789  App Name             1.0.0"
        // Two or more spaces separate name from version.
        let pattern = #"^(\d+)\s+(.+?)\s{2,}\S.*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        guard let match = regex.firstMatch(in: trimmed, range: range),
              match.numberOfRanges == 3 else { return nil }

        let id   = substring(in: trimmed, range: match.range(at: 1))
        let name = substring(in: trimmed, range: match.range(at: 2))
        guard !id.isEmpty, !name.isEmpty else { return nil }

        return MasSearchResult(appStoreID: id, name: name)
    }

    private func substring(in value: String, range: NSRange) -> String {
        guard range.location != NSNotFound,
              let swiftRange = Range(range, in: value) else { return "" }
        return String(value[swiftRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
```

- [ ] **Step 5: Run tests to confirm they pass**

```bash
swift test --filter MasSearchParserTests 2>&1
```

Expected: 4 tests pass, 0 failures.

---

### Task 2: `MasService.search(name:)` — find App Store ID by name

**Files:**
- Modify: `Sources/MacUpdaterCore/MasService.swift`
- Create: `Tests/MacUpdaterTests/MasServiceSearchTests.swift`

- [ ] **Step 1: Write failing tests**

Create `Tests/MacUpdaterTests/MasServiceSearchTests.swift`:

```swift
import XCTest
@testable import MacUpdaterCore

final class MasServiceSearchTests: XCTestCase {
    private func makeService(stdout: String, exitCode: Int32 = 0) -> MasService {
        let result = ProcessResult(exitCode: exitCode, stdout: stdout, stderr: "")
        let runner = StubProcessRunner(result: result)
        let locator = BinaryLocator(masCandidates: [URL(fileURLWithPath: "/usr/bin/true")])
        return MasService(locator: locator, runner: runner)
    }

    func testReturnsIDWhenExactNormalizedMatch() async throws {
        // "Spotify - Music and Podcasts" normalizes to "spotifymusicandpodcasts"
        let stdout = "  324684580  Spotify - Music and Podcasts             1.2.13\n"
        let service = makeService(stdout: stdout)

        let id = try await service.search(name: "Spotify - Music and Podcasts")

        XCTAssertEqual(id, "324684580")
    }

    func testReturnsNilWhenNoExactMatch() async throws {
        let stdout = "  324684580  Spotify - Music and Podcasts             1.2.13\n"
        let service = makeService(stdout: stdout)

        let id = try await service.search(name: "Firefox")

        XCTAssertNil(id)
    }

    func testReturnsNilWhenMasExitsNonZero() async throws {
        // mas search returns exit 1 when no results — treat as nil, not error
        let service = makeService(stdout: "", exitCode: 1)

        let id = try await service.search(name: "AnyApp")

        XCTAssertNil(id)
    }

    func testReturnsNilWhenEmptyOutput() async throws {
        let service = makeService(stdout: "")

        let id = try await service.search(name: "AnyApp")

        XCTAssertNil(id)
    }

    func testThrowsWhenMasNotInstalled() async {
        let locator = BinaryLocator(masCandidates: [])
        let service = MasService(
            locator: locator,
            runner: StubProcessRunner(result: ProcessResult(exitCode: 0, stdout: "", stderr: ""))
        )

        do {
            _ = try await service.search(name: "AnyApp")
            XCTFail("Expected masNotFound")
        } catch MasServiceError.masNotFound {
            // expected
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }
}
```

- [ ] **Step 2: Run tests to confirm they fail**

```bash
swift test --filter MasServiceSearchTests 2>&1
```

Expected: compile error — `search(name:)` does not exist on `MasService`.

- [ ] **Step 3: Add `search(name:)` to `MasService`**

In `Sources/MacUpdaterCore/MasService.swift`, add `searchParser` property and inject it:

```swift
public final class MasService {
    private let locator: BinaryLocator
    private let runner: ProcessRunning
    private let parser: MasOutdatedParser
    private let listParser: MasListParser
    private let searchParser: MasSearchParser    // ← add this line

    public init(
        locator: BinaryLocator = BinaryLocator(),
        runner: ProcessRunning = ProcessRunner(),
        parser: MasOutdatedParser = MasOutdatedParser(),
        listParser: MasListParser = MasListParser(),
        searchParser: MasSearchParser = MasSearchParser()  // ← add this parameter
    ) {
        self.locator = locator
        self.runner = runner
        self.parser = parser
        self.listParser = listParser
        self.searchParser = searchParser  // ← add this line
    }
    // ... keep all existing methods unchanged ...
}
```

Then add the new method after `list()`:

```swift
public func search(name: String) async throws -> String? {
    let arguments = ["search", name]
    let result = try await runMas(arguments)
    // mas search exits 1 when no results — treat as empty, not an error
    guard result.exitCode == 0 else { return nil }
    let normalizedQuery = StringNormalizer.normalize(name)
    return searchParser.parse(result.stdout)
        .first { StringNormalizer.normalize($0.name) == normalizedQuery }?
        .appStoreID
}
```

- [ ] **Step 4: Run tests to confirm they pass**

```bash
swift test --filter MasServiceSearchTests 2>&1
```

Expected: 5 tests pass, 0 failures.

- [ ] **Step 5: Run all tests to catch regressions**

```bash
swift test 2>&1
```

Expected: all tests pass.

---

### Task 3: `MigrationView` — filtering, parallel search, new UI section

**Files:**
- Modify: `Sources/MacUpdater/MigrationView.swift`

- [ ] **Step 1: Add new state property**

In `MigrationView`, find the existing `@State` block (lines 11–16) and add one new property:

```swift
@State private var masCandidates: [(app: ApplicationInfo, masID: String)] = []
```

The full `@State` block becomes:

```swift
@State private var status:        MigrationStatus                             = .ready
@State private var candidates:    [ApplicationInfo]                           = []
@State private var masCandidates: [(app: ApplicationInfo, masID: String)]     = []
@State private var migrated:      Set<String>                                 = []
@State private var busy:          String?                                     = nil
@State private var errorMessage:  String?                                     = nil
@State private var banner:        BannerData?                                 = nil
```

- [ ] **Step 2: Update `unmatched` computed property**

Replace the existing `unmatched` computed property:

```swift
// OLD
private var unmatched: [ApplicationInfo] { candidates.filter { $0.caskToken == nil } }
```

With:

```swift
// NEW — exclude apps that already have a MAS candidate match
private var unmatched: [ApplicationInfo] {
    let masIDs = Set(masCandidates.map { $0.app.id })
    return candidates.filter { $0.caskToken == nil && !masIDs.contains($0.id) }
}
```

- [ ] **Step 3: Update `scan()` — filtering and MAS search**

Replace the line `candidates = all.filter { !$0.isManagedByBrew }` (currently line 207) and everything after it up to the closing brace of the `do` block, with:

```swift
// Exclude brew-managed apps AND apps already in the App Store
let migrationPool = all.filter { !$0.isManagedByBrew && !$0.isManagedByMas }
candidates = migrationPool

// Parallel App Store search for apps with no Homebrew match
let toSearch = migrationPool.filter { $0.caskToken == nil }
if !toSearch.isEmpty {
    let masService = model.masService
    var found: [(app: ApplicationInfo, masID: String)] = []
    await withTaskGroup(of: (ApplicationInfo, String?).self) { group in
        for app in toSearch {
            group.addTask {
                let id = try? await masService.search(name: app.name)
                return (app, id)
            }
        }
        for await (app, maybeID) in group {
            if let id = maybeID { found.append((app: app, masID: id)) }
        }
    }
    masCandidates = found
}
```

- [ ] **Step 4: Update `scan()` — reset state and WegaState message**

At the top of `scan()`, after `status = .scanning; errorMessage = nil`, add `masCandidates = []`:

```swift
status = .scanning; errorMessage = nil; masCandidates = []
```

At the bottom of `scan()`, replace the final `onWegaState` call:

```swift
// OLD
let n = candidates.filter { $0.caskToken != nil }.count
onWegaState?(WegaState(pose: n > 0 ? .alert : .happy,
                       line: n > 0 ? "Zwęszyłam \(n) aplikacji poza Homebrew." : "Wszystko porządku. Wega nie znalazła uciekinierów."))
```

```swift
// NEW
let brewCount = candidates.filter { $0.caskToken != nil }.count
let total = brewCount + masCandidates.count
onWegaState?(WegaState(
    pose: total > 0 ? .alert : .happy,
    line: total > 0
        ? "Zwęszyłam \(total) aplikacji do przepięcia."
        : "Wszystko porządku. Wega nie znalazła uciekinierów."
))
```

- [ ] **Step 5: Update results header subtitle**

In `resultsView`, replace the subtitle `Text(...)` that says `"Zeskanowano /Applications · Wega znalazła..."`:

```swift
// OLD
Text("Zeskanowano /Applications · Wega znalazła \(matchable.count + migrated.count) aplikacji do przepięcia")
    .font(.system(size: 11))
    .foregroundStyle(.tertiary)
```

```swift
// NEW
Text("Zeskanowano /Applications · \(matchable.count + migrated.count + masCandidates.count) aplikacji do przepięcia")
    .font(.system(size: 11))
    .foregroundStyle(.tertiary)
```

- [ ] **Step 6: Add App Store candidates section to `resultsView`**

In `resultsView`, after the closing brace of the "matchable" `WegaCard` block (after line 127) and before the `if !unmatched.isEmpty` block, insert the new section:

```swift
// App Store candidates section
if !masCandidates.isEmpty {
    WegaCard(padded: false) {
        HStack(spacing: 8) {
            Image(systemName: "basket.fill").foregroundStyle(Color.wegaInfo)
            Text("Można przenieść do App Store")
                .font(.system(size: 13, weight: .semibold))
            Text("\(masCandidates.count)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Divider().opacity(0.5) }

        ForEach(masCandidates, id: \.app.id) { item in
            AppStoreMigrationRow(app: item.app, masID: item.masID)
            if item.app.id != masCandidates.last?.app.id {
                Divider().opacity(0.4).padding(.leading, 54)
            }
        }
    }
}
```

- [ ] **Step 7: Add `AppStoreMigrationRow` view**

After the closing brace of `MigrationRow` (at end of file), add:

```swift
private struct AppStoreMigrationRow: View {
    let app:   ApplicationInfo
    let masID: String

    var body: some View {
        HStack(spacing: 12) {
            PackageLetterIcon(name: app.name, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(app.name).font(.system(size: 13, weight: .medium))
                    if let v = app.version {
                        Text(v)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
                Text(app.path.path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            WegaBadge(label: masID, variant: .appStore)
            Button {
                if let url = URL(string: "macappstore://apps.apple.com/app/id\(masID)") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Label("Otwórz w App Store", systemImage: "basket")
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}
```

- [ ] **Step 8: Build to confirm no compile errors**

```bash
swift build 2>&1
```

Expected: `Build complete!` with no errors.

---

### Task 4: README update

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update README.md line 11**

`README.md` line 11 currently reads:
```
- Inventory marks apps as `Brew`, `App Store`, or `Manual`. App Store apps are detected via `Contents/_MASReceipt/receipt`. App Store IDs are populated via `mas list` (requires optional `mas` install).
```

After that line, add:
```
- Migration scans non-Homebrew, non-App Store apps for migration candidates. It checks Homebrew Cask availability and uses `mas search` in parallel to find Mac App Store equivalents (requires optional `mas` install and network access).
```

- [ ] **Step 2: Build final check**

```bash
swift build 2>&1
```

Expected: `Build complete!`
