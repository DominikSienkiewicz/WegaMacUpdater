# MAS App Detection & Update Integration — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Detect apps installed from the Mac App Store (via `_MASReceipt/receipt`), classify them correctly in the inventory, exclude them from the manual/sparkle scan, and populate their App Store IDs via `mas list`.

**Architecture:** `ApplicationScanner` gains receipt detection (synchronous file check, no new dependencies). `MasService` gains a `list()` method backed by a new `MasListParser`. `InventoryView` calls `masService.list()` after scanning to populate `masAppID`, then shows an "App Store" filter/badge. `UpdateView.scanManualUpdates()` excludes MAS apps — they are already handled by the existing `masOutdated` flow.

**Tech Stack:** Swift 5.9, XCTest, `NSRegularExpression`, `FileManager`

---

## File Map

| Action | Path |
|--------|------|
| Modify | `Sources/MacUpdaterCore/Models.swift` |
| Create | `Sources/MacUpdaterCore/MasListParser.swift` |
| Modify | `Sources/MacUpdaterCore/MasService.swift` |
| Modify | `Sources/MacUpdaterCore/ApplicationScanner.swift` |
| Create | `Tests/MacUpdaterTests/Fixtures/mas-list.txt` |
| Create | `Tests/MacUpdaterTests/MasListParserTests.swift` |
| Create | `Tests/MacUpdaterTests/ApplicationScannerMasTests.swift` |
| Modify | `Sources/MacUpdater/InventoryView.swift` |
| Modify | `Sources/MacUpdater/UpdateView.swift` |

---

## Task 1: Extend data model

**Files:**
- Modify: `Sources/MacUpdaterCore/Models.swift`

- [ ] **Step 1: Add `isManagedByMas` and `masAppID` to `ApplicationInfo`**

In `Models.swift`, add two fields to `ApplicationInfo` — after `isManagedByBrew`:

```swift
public var isManagedByMas: Bool
public var masAppID: String?
```

Update the initializer to include them (add after `isManagedByBrew: Bool, caskToken: String? = nil`):

```swift
isManagedByMas: Bool = false,
masAppID: String? = nil
```

And assign them in the body:

```swift
self.isManagedByMas = isManagedByMas
self.masAppID = masAppID
```

- [ ] **Step 2: Add `MasInstalledApp` struct**

After `MasOutdatedApp` in `Models.swift`, add:

```swift
public struct MasInstalledApp: Equatable, Sendable {
    public var appStoreID: String
    public var name: String
    public var version: String?

    public init(appStoreID: String, name: String, version: String?) {
        self.appStoreID = appStoreID
        self.name = name
        self.version = version
    }
}
```

- [ ] **Step 3: Add `.mas` case to `ManualOutdatedApp.UpdateSource`**

In the `UpdateSource` enum, add after `.cask(token: String)`:

```swift
case mas(appStoreID: String)
```

- [ ] **Step 4: Build to confirm no regressions**

```bash
cd /Users/dominiksienkiewicz/Dev/Projects/public/WegaMacUpdater && swift build 2>&1
```

Expected: build succeeds (existing callers of `ApplicationInfo.init` use default values for new fields).

- [ ] **Step 5: Commit**

```bash
git add Sources/MacUpdaterCore/Models.swift
git commit -m "feat: add isManagedByMas, masAppID to ApplicationInfo; add MasInstalledApp and .mas update source"
```

---

## Task 2: `MasListParser` — parse `mas list` output

**Files:**
- Create: `Sources/MacUpdaterCore/MasListParser.swift`
- Create: `Tests/MacUpdaterTests/Fixtures/mas-list.txt`
- Create: `Tests/MacUpdaterTests/MasListParserTests.swift`

- [ ] **Step 1: Create the fixture file**

Create `Tests/MacUpdaterTests/Fixtures/mas-list.txt` with this content (real `mas list` format: `<id>  <name>  (<version>)`):

```
1569813296  1Password for Safari (2.29.0)
497799835   Xcode (16.1)
409183694   Keynote (14.3)
```

- [ ] **Step 2: Write the failing test**

Create `Tests/MacUpdaterTests/MasListParserTests.swift`:

```swift
import XCTest
@testable import MacUpdaterCore

final class MasListParserTests: XCTestCase {
    func testParsesFixture() throws {
        let output = try fixtureString(named: "mas-list", extension: "txt")

        let apps = MasListParser().parse(output)

        XCTAssertEqual(apps.count, 3)
        XCTAssertEqual(apps[0].appStoreID, "1569813296")
        XCTAssertEqual(apps[0].name, "1Password for Safari")
        XCTAssertEqual(apps[0].version, "2.29.0")
        XCTAssertEqual(apps[1].appStoreID, "497799835")
        XCTAssertEqual(apps[1].name, "Xcode")
        XCTAssertEqual(apps[1].version, "16.1")
        XCTAssertEqual(apps[2].appStoreID, "409183694")
        XCTAssertEqual(apps[2].name, "Keynote")
        XCTAssertEqual(apps[2].version, "14.3")
    }

    func testIgnoresBlankLines() {
        let output = "\n1569813296  1Password for Safari (2.29.0)\n\n"
        let apps = MasListParser().parse(output)
        XCTAssertEqual(apps.count, 1)
    }

    func testIgnoresMalformedLines() {
        let output = "not a valid line\n1569813296  AppName (1.0)"
        let apps = MasListParser().parse(output)
        XCTAssertEqual(apps.count, 1)
        XCTAssertEqual(apps[0].name, "AppName")
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

```bash
cd /Users/dominiksienkiewicz/Dev/Projects/public/WegaMacUpdater && swift test --filter MasListParserTests 2>&1
```

Expected: compile error — `MasListParser` not found.

- [ ] **Step 4: Implement `MasListParser`**

Create `Sources/MacUpdaterCore/MasListParser.swift`:

```swift
import Foundation

public struct MasListParser {
    public init() {}

    public func parse(_ output: String) -> [MasInstalledApp] {
        output
            .split(whereSeparator: \.isNewline)
            .compactMap { parseLine(String($0)) }
    }

    private func parseLine(_ line: String) -> MasInstalledApp? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let pattern = #"^(\d+)\s+(.+?)\s+\((.*?)\)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        guard let match = regex.firstMatch(in: trimmed, range: range), match.numberOfRanges == 4 else {
            return nil
        }

        let id      = substring(in: trimmed, range: match.range(at: 1))
        let name    = substring(in: trimmed, range: match.range(at: 2))
        let version = substring(in: trimmed, range: match.range(at: 3)).nilIfEmpty

        return MasInstalledApp(appStoreID: id, name: name, version: version)
    }

    private func substring(in value: String, range: NSRange) -> String {
        guard range.location != NSNotFound, let swiftRange = Range(range, in: value) else {
            return ""
        }
        return String(value[swiftRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
```

- [ ] **Step 5: Run test to verify it passes**

```bash
cd /Users/dominiksienkiewicz/Dev/Projects/public/WegaMacUpdater && swift test --filter MasListParserTests 2>&1
```

Expected: all 3 tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/MacUpdaterCore/MasListParser.swift \
        Tests/MacUpdaterTests/MasListParserTests.swift \
        Tests/MacUpdaterTests/Fixtures/mas-list.txt
git commit -m "feat: add MasListParser with fixture and tests"
```

---

## Task 3: `MasService.list()`

**Files:**
- Modify: `Sources/MacUpdaterCore/MasService.swift`

- [ ] **Step 1: Write the failing test**

`BinaryLocator` is a concrete struct (no protocol), but accepts custom `masCandidates` in its initializer. Use that for injection. `ProcessRunning` is a protocol — create a stub for it.

Create `Tests/MacUpdaterTests/TestDoubles.swift` (if it doesn't exist):

```swift
import Foundation
@testable import MacUpdaterCore

final class StubProcessRunner: ProcessRunning {
    let result: ProcessResult
    init(result: ProcessResult) { self.result = result }
    func run(_ request: ProcessRequest) async throws -> ProcessResult { result }
    func events(for request: ProcessRequest) -> AsyncThrowingStream<ProcessOutputEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
```

Create `Tests/MacUpdaterTests/MasServiceListTests.swift`:

```swift
import XCTest
@testable import MacUpdaterCore

final class MasServiceListTests: XCTestCase {
    func testListParsesOutput() async throws {
        let fakeResult = ProcessResult(exitCode: 0, stdout: "1569813296  MyApp (1.0)", stderr: "")
        let runner = StubProcessRunner(result: fakeResult)
        // Use /usr/bin/true as a stand-in — runner is stubbed so the binary is never executed
        let locator = BinaryLocator(masCandidates: [URL(fileURLWithPath: "/usr/bin/true")])
        let service = MasService(locator: locator, runner: runner)

        let apps = try await service.list()

        XCTAssertEqual(apps.count, 1)
        XCTAssertEqual(apps[0].appStoreID, "1569813296")
        XCTAssertEqual(apps[0].name, "MyApp")
        XCTAssertEqual(apps[0].version, "1.0")
    }

    func testListThrowsWhenMasMissing() async {
        // Empty candidates → locateMas() returns nil → masNotFound
        let locator = BinaryLocator(masCandidates: [])
        let service = MasService(
            locator: locator,
            runner: StubProcessRunner(result: ProcessResult(exitCode: 0, stdout: "", stderr: ""))
        )

        do {
            _ = try await service.list()
            XCTFail("Expected masNotFound")
        } catch MasServiceError.masNotFound {
            // expected
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd /Users/dominiksienkiewicz/Dev/Projects/public/WegaMacUpdater && swift test --filter MasServiceListTests 2>&1
```

Expected: compile error — `list()` not found on `MasService`.

- [ ] **Step 3: Add `list()` to `MasService`**

In `Sources/MacUpdaterCore/MasService.swift`, add a `listParser` property and `list()` method. First add the parser as an injected dependency:

```swift
private let listParser: MasListParser
```

Update `init` to include it (with default):

```swift
public init(
    locator: BinaryLocator = BinaryLocator(),
    runner: ProcessRunning = ProcessRunner(),
    parser: MasOutdatedParser = MasOutdatedParser(),
    listParser: MasListParser = MasListParser()
) {
    self.locator = locator
    self.runner = runner
    self.parser = parser
    self.listParser = listParser
}
```

Add the method after `upgrade()`:

```swift
public func list() async throws -> [MasInstalledApp] {
    let arguments = ["list"]
    let result = try await runMas(arguments)
    try ensureSuccess(result, arguments: arguments)
    return listParser.parse(result.stdout)
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd /Users/dominiksienkiewicz/Dev/Projects/public/WegaMacUpdater && swift test --filter MasServiceListTests 2>&1
```

Expected: both tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/MacUpdaterCore/MasService.swift \
        Tests/MacUpdaterTests/MasServiceListTests.swift
git commit -m "feat: add MasService.list() backed by MasListParser"
```

---

## Task 4: Receipt detection in `ApplicationScanner`

**Files:**
- Modify: `Sources/MacUpdaterCore/ApplicationScanner.swift`
- Create: `Tests/MacUpdaterTests/ApplicationScannerMasTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/MacUpdaterTests/ApplicationScannerMasTests.swift`:

```swift
import XCTest
@testable import MacUpdaterCore

final class ApplicationScannerMasTests: XCTestCase {
    var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    func makeApp(named name: String, withReceipt: Bool) throws -> URL {
        let appURL = tmpDir.appendingPathComponent("\(name).app")
        let contentsURL = appURL.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)

        // Write a minimal Info.plist so Bundle can read the name
        let plist: [String: Any] = [
            "CFBundleName": name,
            "CFBundleIdentifier": "com.test.\(name.lowercased())",
            "CFBundleShortVersionString": "1.0"
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try plistData.write(to: contentsURL.appendingPathComponent("Info.plist"))

        if withReceipt {
            let receiptDir = contentsURL
                .appendingPathComponent("_MASReceipt", isDirectory: true)
            try FileManager.default.createDirectory(at: receiptDir, withIntermediateDirectories: true)
            try Data().write(to: receiptDir.appendingPathComponent("receipt"))
        }
        return appURL
    }

    func testMasReceiptDetected() throws {
        try makeApp(named: "MasApp", withReceipt: true)
        try makeApp(named: "RegularApp", withReceipt: false)

        let scanner = ApplicationScanner()
        let apps = try scanner.scanApplications(in: tmpDir)

        let masApp = try XCTUnwrap(apps.first { $0.name == "MasApp" })
        let regularApp = try XCTUnwrap(apps.first { $0.name == "RegularApp" })

        XCTAssertTrue(masApp.isManagedByMas)
        XCTAssertFalse(masApp.isManagedByBrew)
        XCTAssertNil(masApp.caskToken)

        XCTAssertFalse(regularApp.isManagedByMas)
    }

    func testMasPriorityOverCaskCandidate() throws {
        try makeApp(named: "Firefox", withReceipt: true)

        let scanner = ApplicationScanner()
        let casks = [BrewCask(token: "firefox", name: ["Firefox"])]
        let apps = try scanner.scanApplications(in: tmpDir, installedCasks: [], availableCasks: casks)

        let app = try XCTUnwrap(apps.first { $0.name == "Firefox" })
        XCTAssertTrue(app.isManagedByMas)
        XCTAssertFalse(app.isManagedByBrew)
        XCTAssertNil(app.caskToken)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd /Users/dominiksienkiewicz/Dev/Projects/public/WegaMacUpdater && swift test --filter ApplicationScannerMasTests 2>&1
```

Expected: compile error — `isManagedByMas` not found (or test fails because receipt is not checked yet).

- [ ] **Step 3: Add receipt detection to `ApplicationScanner`**

In `Sources/MacUpdaterCore/ApplicationScanner.swift`, add a private method after `appInfo(for:installedCasks:availableCasks:)`:

```swift
private func hasMasReceipt(at appURL: URL) -> Bool {
    let receiptURL = appURL
        .appendingPathComponent("Contents")
        .appendingPathComponent("_MASReceipt")
        .appendingPathComponent("receipt")
    return fileManager.fileExists(atPath: receiptURL.path)
}
```

Then update `appInfo(for:installedCasks:availableCasks:)` to apply the priority rule. After the `switch matcher.match(...)` block and before the `return ApplicationInfo(...)`, add:

```swift
let managedByMas = hasMasReceipt(at: appURL)
if managedByMas {
    isManagedByBrew = false
    caskToken = nil
}
```

Update the returned `ApplicationInfo` to include the new fields:

```swift
return ApplicationInfo(
    path: appURL,
    name: appName,
    bundleIdentifier: bundle?.bundleIdentifier,
    version: version,
    installDate: resourceValues?.creationDate,
    updateDate: resourceValues?.contentModificationDate,
    isManagedByBrew: isManagedByBrew,
    caskToken: caskToken,
    isManagedByMas: managedByMas
)
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd /Users/dominiksienkiewicz/Dev/Projects/public/WegaMacUpdater && swift test --filter ApplicationScannerMasTests 2>&1
```

Expected: both tests pass.

- [ ] **Step 5: Run all tests to check for regressions**

```bash
cd /Users/dominiksienkiewicz/Dev/Projects/public/WegaMacUpdater && swift test 2>&1
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/MacUpdaterCore/ApplicationScanner.swift \
        Tests/MacUpdaterTests/ApplicationScannerMasTests.swift
git commit -m "feat: detect MAS apps via _MASReceipt/receipt in ApplicationScanner; MAS wins over cask candidate"
```

---

## Task 5: Update `InventoryView` — App Store filter, badge, ID correlation

**Files:**
- Modify: `Sources/MacUpdater/InventoryView.swift`

- [ ] **Step 1: Add `.appStore` to `SourceFilter`**

In `InventoryView.swift`, change:

```swift
private enum SourceFilter: String, CaseIterable {
    case all    = "Wszystkie"
    case brew   = "Brew"
    case manual = "Ręcznie"
}
```

To:

```swift
private enum SourceFilter: String, CaseIterable {
    case all      = "Wszystkie"
    case brew     = "Brew"
    case appStore = "App Store"
    case manual   = "Ręcznie"
}
```

- [ ] **Step 2: Update computed counts**

Change:

```swift
private var brewCount:   Int { apps.filter(\.isManagedByBrew).count }
private var manualCount: Int { apps.count - brewCount }
```

To:

```swift
private var brewCount:     Int { apps.filter(\.isManagedByBrew).count }
private var masCount:      Int { apps.filter(\.isManagedByMas).count }
private var manualCount:   Int { apps.count - brewCount - masCount }
```

- [ ] **Step 3: Update the filter logic in `filtered`**

Change the `switch filter` inside `filtered`:

```swift
switch filter {
case .all:      true
case .brew:     app.isManagedByBrew
case .appStore: app.isManagedByMas
case .manual:   !app.isManagedByBrew && !app.isManagedByMas
}
```

- [ ] **Step 4: Update sort by source**

Change the `.source` sort case from:

```swift
case .source:   cmp = a.isManagedByBrew && !b.isManagedByBrew
```

To:

```swift
case .source:
    func rank(_ x: ApplicationInfo) -> Int {
        x.isManagedByBrew ? 0 : (x.isManagedByMas ? 1 : 2)
    }
    cmp = rank(a) < rank(b)
```

- [ ] **Step 5: Add App Store stat card**

In the `HStack` with stat cards, add the App Store card after the Homebrew card:

```swift
InventoryStatCard(label: "App Store", value: masCount, sublabel: "ze sklepu", color: .wegaInfo, active: filter == .appStore) { setFilter(.appStore) }
```

The full HStack becomes:

```swift
HStack(spacing: 10) {
    InventoryStatCard(label: "Homebrew",  value: brewCount,   sublabel: "cask + formula", color: .wegaHoney,  active: filter == .brew)      { setFilter(.brew) }
    InventoryStatCard(label: "App Store", value: masCount,    sublabel: "ze sklepu",      color: .wegaInfo,   active: filter == .appStore)   { setFilter(.appStore) }
    InventoryStatCard(label: "Ręcznie",   value: manualCount, sublabel: "poza brew/mas",  color: .wegaDanger, active: filter == .manual)     { setFilter(.manual) }
    InventoryStatCard(label: "Razem",     value: apps.count,  sublabel: "wszystkie",      color: .primary,    active: filter == .all)        { setFilter(.all) }
}
```

- [ ] **Step 6: Update `InventoryRow` badge to show App Store**

In `InventoryRow.body`, change the source HStack:

```swift
HStack(spacing: 6) {
    WegaBadge(label: app.isManagedByBrew ? "Brew" : "Ręcznie",
              variant: app.isManagedByBrew ? .brew : .manual)
    if let token = app.caskToken {
        Text(token)
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundStyle(.quaternary)
            .lineLimit(1)
    }
}
```

To:

```swift
HStack(spacing: 6) {
    if app.isManagedByBrew {
        WegaBadge(label: "Brew", variant: .brew)
        if let token = app.caskToken {
            Text(token)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.quaternary)
                .lineLimit(1)
        }
    } else if app.isManagedByMas {
        WegaBadge(label: "App Store", variant: .appStore)
        if let id = app.masAppID {
            Text(id)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.quaternary)
                .lineLimit(1)
        }
    } else {
        WegaBadge(label: "Ręcznie", variant: .manual)
    }
}
```

- [ ] **Step 7: Add `masService.list()` correlation in `scan()`**

At the end of `scan()`, after `apps = all.sorted(...)`, add:

```swift
// Populate masAppID for App Store apps (graceful: skip if mas unavailable)
if let masApps = try? await model.masService.list(), !masApps.isEmpty {
    let masIndex = Dictionary(
        uniqueKeysWithValues: masApps.map { (StringNormalizer.normalize($0.name), $0.appStoreID) }
    )
    apps = apps.map { app in
        guard app.isManagedByMas, app.masAppID == nil else { return app }
        var updated = app
        updated.masAppID = masIndex[StringNormalizer.normalize(app.name)]
        return updated
    }
}
```

- [ ] **Step 8: Build to verify**

```bash
cd /Users/dominiksienkiewicz/Dev/Projects/public/WegaMacUpdater && swift build 2>&1
```

Expected: build succeeds.

- [ ] **Step 9: Commit**

```bash
git add Sources/MacUpdater/InventoryView.swift
git commit -m "feat: add App Store filter, badge, and masAppID correlation in InventoryView"
```

---

## Task 6: Exclude MAS apps from manual update scan in `UpdateView`

**Files:**
- Modify: `Sources/MacUpdater/UpdateView.swift`

- [ ] **Step 1: Update `scanManualUpdates()` filter**

In `UpdateView.swift`, find `scanManualUpdates()`. Change the filter line:

```swift
for app in found where !app.isManagedByBrew {
```

To:

```swift
for app in found where !app.isManagedByBrew && !app.isManagedByMas {
```

This is the only change needed — MAS apps are already handled by the existing `masOutdated` flow (via `mas outdated` in `runCheck()`).

- [ ] **Step 2: Build and run all tests**

```bash
cd /Users/dominiksienkiewicz/Dev/Projects/public/WegaMacUpdater && swift build 2>&1 && swift test 2>&1
```

Expected: build succeeds, all tests pass.

- [ ] **Step 3: Commit**

```bash
git add Sources/MacUpdater/UpdateView.swift
git commit -m "fix: exclude MAS apps from manual/sparkle scan — they are handled by mas outdated"
```

---

## Task 7: Update README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update the Status section**

In `README.md`, in the Status bullet list, replace the inventory description to mention MAS detection:

Old:
```
- Inventory marks apps as `Brew` or `Manual` by combining `/Applications` metadata with `brew list --cask -1` and the cached Homebrew cask database.
```

New:
```
- Inventory marks apps as `Brew`, `App Store`, or `Manual`. App Store apps are detected via `Contents/_MASReceipt/receipt`. App Store IDs are populated via `mas list` (requires optional `mas` install).
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: update README to reflect App Store app detection"
```
