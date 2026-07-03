#!/usr/bin/env bash
set -euo pipefail

# clean.sh — dokłada checkery self-update (Discord/Signal/Chrome) i commituje na main.
# Użycie:
#   ./clean.sh                      # tylko naniesienie zmian + commit na main
#   ./clean.sh <branch-do-usuniecia># dodatkowo usuwa wskazany branch (bezpiecznie, -d)
#   SKIP_TESTS=1 ./clean.sh         # pomija `swift test` (zostawia sam `swift build`)

BRANCH_TO_DELETE="${1:-}"

cd "$(git rev-parse --show-toplevel)"
command -v python3 >/dev/null || { echo "python3 wymagany"; exit 1; }
[ "$(git symbolic-ref --short HEAD)" = "main" ] || { echo "Jesteś na '$(git symbolic-ref --short HEAD)'. Przełącz się na main (git checkout main) i uruchom ponownie."; exit 1; }
git diff --quiet && git diff --cached --quiet || { echo "Working tree niepusty — zacommituj/zstashuj zmiany przed uruchomieniem."; exit 1; }

echo "== 1/5 Nowe pliki źródłowe i testy =="

cat > Sources/MacUpdaterCore/DiscordUpdateChecker.swift <<'SWIFT'
import Foundation

/// Parses Discord's Squirrel.Mac update feed. Discord's desktop host self-updates
/// through a Squirrel-compatible server: `GET .../updates/{channel}?platform=osx&version={v}`
/// answers **200** `{"name":"0.0.XXXX", …}` with the version to offer, or **204** when current.
public enum DiscordUpdateParser {
    private struct SquirrelResponse: Decodable { let name: String }
    public static func latestVersion(fromSquirrelJSON data: Data) -> String? {
        guard !data.isEmpty,
              let decoded = try? JSONDecoder().decode(SquirrelResponse.self, from: data) else { return nil }
        let trimmed = decoded.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Detects updates for Discord (stable / PTB / Canary), which self-updates via
/// Squirrel.Mac (no Sparkle `SUFeedURL`) while its `discord*` casks are `auto_updates`
/// and lag — so neither `brew outdated` nor the cask-version check sees the new build.
/// Same approach as Postman and ChatGPT.
public struct DiscordUpdateChecker: Sendable {
    public static let channelsByBundleID: [String: String] = [
        "com.hnc.Discord":       "stable",
        "com.hnc.DiscordPTB":    "ptb",
        "com.hnc.DiscordCanary": "canary"
    ]
    public static func updateURL(channel: String, version: String) -> URL? {
        AppEndpoints.shared.discordUpdateURL(channel: channel, version: version)
    }

    private let client: HTTPClient
    public init(client: HTTPClient = .shared) { self.client = client }

    public func check(app: ApplicationInfo) async -> ManualCheckResult {
        guard let bundleID = app.bundleIdentifier,
              let channel = Self.channelsByBundleID[bundleID],
              let installed = app.version, !installed.isEmpty,
              let url = Self.updateURL(channel: channel, version: installed) else { return .notApplicable }

        guard let response = try? await client.get(url, enableETag: true) else { return .unavailable }
        if response.statusCode == 204 { return .upToDate }
        guard response.statusCode == 200 else { return response.statusCode >= 500 ? .unavailable : .failed }
        guard let latest = DiscordUpdateParser.latestVersion(fromSquirrelJSON: response.data) else { return .upToDate }
        guard isUpgrade(installed: installed, latest: latest) else { return .upToDate }

        return .outdated(ManualOutdatedApp(
            name: app.name, path: app.path,
            installedVersion: installed, availableVersion: latest, source: .discord))
    }
}
SWIFT

cat > Sources/MacUpdaterCore/SignalUpdateChecker.swift <<'SWIFT'
import Foundation

/// Parses Signal Desktop's `electron-updater` feed (`.../desktop/latest-mac.yml`),
/// whose first top-level `version:` line carries the latest version, e.g. `version: 7.68.0`.
public enum SignalUpdateParser {
    public static func latestVersion(fromYAML data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("version:") else { continue }
            let value = String(line.dropFirst("version:".count))
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t'\""))
            return value.isEmpty ? nil : value
        }
        return nil
    }
}

/// Detects updates for Signal Desktop, which self-updates via electron-updater (no
/// Sparkle `SUFeedURL`) while its `signal` cask is `auto_updates` and lags. Same
/// approach as Postman and ChatGPT.
public struct SignalUpdateChecker: Sendable {
    public static let bundleIdentifier = "org.whispersystems.signal-desktop"
    public static var updateURL: URL { AppEndpoints.shared.signalUpdateURL }

    private let client: HTTPClient
    public init(client: HTTPClient = .shared) { self.client = client }

    public func check(app: ApplicationInfo) async -> ManualCheckResult {
        guard app.bundleIdentifier == Self.bundleIdentifier,
              let installed = app.version, !installed.isEmpty else { return .notApplicable }

        guard let response = try? await client.get(Self.updateURL, enableETag: true) else { return .unavailable }
        guard response.statusCode == 200 else { return response.statusCode >= 500 ? .unavailable : .failed }
        guard let latest = SignalUpdateParser.latestVersion(fromYAML: response.data) else { return .failed }
        guard isUpgrade(installed: installed, latest: latest) else { return .upToDate }

        return .outdated(ManualOutdatedApp(
            name: app.name, path: app.path,
            installedVersion: installed, availableVersion: latest, source: .signal))
    }
}
SWIFT

cat > Sources/MacUpdaterCore/ChromeUpdateChecker.swift <<'SWIFT'
import Foundation

/// Parses Chrome's public Version History API
/// (`.../v1/chrome/platforms/mac/channels/{channel}/versions`) → `{"versions":[{"version":"…"}]}`.
/// The feed order isn't contractually newest-first, so we pick the max by version compare.
public enum ChromeUpdateParser {
    private struct Response: Decodable {
        struct Version: Decodable { let version: String }
        let versions: [Version]
    }
    public static func newestVersion(fromVersionHistoryJSON data: Data) -> String? {
        guard !data.isEmpty,
              let decoded = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        let versions = decoded.versions.map(\.version).filter { !$0.isEmpty }
        return versions.max(by: { isUpgrade(installed: $0, latest: $1) })
    }
}

/// Detects updates for Google Chrome (stable / beta / dev / canary), which self-updates
/// via Keystone (Omaha) while its `google-chrome*` casks are `auto_updates` and lag
/// (the brew drift filter only hides the stale cask after the fact). Queries Chrome's
/// public Version History API per channel.
public struct ChromeUpdateChecker: Sendable {
    public static let channelsByBundleID: [String: String] = [
        "com.google.Chrome":        "stable",
        "com.google.Chrome.beta":   "beta",
        "com.google.Chrome.dev":    "dev",
        "com.google.Chrome.canary": "canary"
    ]
    public static func versionsURL(channel: String) -> URL? {
        AppEndpoints.shared.chromeVersionsURL(channel: channel)
    }

    private let client: HTTPClient
    public init(client: HTTPClient = .shared) { self.client = client }

    public func check(app: ApplicationInfo) async -> ManualCheckResult {
        guard let bundleID = app.bundleIdentifier,
              let channel = Self.channelsByBundleID[bundleID],
              let installed = app.version, !installed.isEmpty,
              let url = Self.versionsURL(channel: channel) else { return .notApplicable }

        guard let response = try? await client.get(url, enableETag: true) else { return .unavailable }
        guard response.statusCode == 200 else { return response.statusCode >= 500 ? .unavailable : .failed }
        guard let latest = ChromeUpdateParser.newestVersion(fromVersionHistoryJSON: response.data) else { return .failed }
        guard isUpgrade(installed: installed, latest: latest) else { return .upToDate }

        return .outdated(ManualOutdatedApp(
            name: app.name, path: app.path,
            installedVersion: installed, availableVersion: latest, source: .chrome))
    }
}
SWIFT

cat > Tests/MacUpdaterTests/DiscordUpdateCheckerTests.swift <<'SWIFT'
import XCTest
@testable import MacUpdaterCore

final class DiscordUpdateCheckerTests: XCTestCase {
    func testParsesNameFromSquirrel200() {
        let json = Data(#"{"name":"0.0.966","pub_date":"2026-01-01","url":"https://x"}"#.utf8)
        XCTAssertEqual(DiscordUpdateParser.latestVersion(fromSquirrelJSON: json), "0.0.966")
    }
    func testEmptyBodyReturnsNil() {
        XCTAssertNil(DiscordUpdateParser.latestVersion(fromSquirrelJSON: Data()))
    }
    func testGarbageReturnsNil() {
        XCTAssertNil(DiscordUpdateParser.latestVersion(fromSquirrelJSON: Data("not json".utf8)))
    }
    func testChannelMapCoversThreeFlavors() {
        XCTAssertEqual(DiscordUpdateChecker.channelsByBundleID["com.hnc.Discord"], "stable")
        XCTAssertEqual(DiscordUpdateChecker.channelsByBundleID["com.hnc.DiscordPTB"], "ptb")
        XCTAssertEqual(DiscordUpdateChecker.channelsByBundleID["com.hnc.DiscordCanary"], "canary")
    }
}
SWIFT

cat > Tests/MacUpdaterTests/SignalUpdateCheckerTests.swift <<'SWIFT'
import XCTest
@testable import MacUpdaterCore

final class SignalUpdateCheckerTests: XCTestCase {
    func testParsesVersionFromYAML() {
        let yaml = Data("""
        version: 7.68.0
        files:
          - url: signal-desktop-mac-arm64-7.68.0.zip
            sha512: abc
        releaseDate: '2026-01-01T00:00:00.000Z'
        """.utf8)
        XCTAssertEqual(SignalUpdateParser.latestVersion(fromYAML: yaml), "7.68.0")
    }
    func testQuotedVersionStripped() {
        XCTAssertEqual(SignalUpdateParser.latestVersion(fromYAML: Data("version: '7.70.1'\n".utf8)), "7.70.1")
    }
    func testMissingVersionReturnsNil() {
        XCTAssertNil(SignalUpdateParser.latestVersion(fromYAML: Data("files: []\n".utf8)))
    }
}
SWIFT

cat > Tests/MacUpdaterTests/ChromeUpdateCheckerTests.swift <<'SWIFT'
import XCTest
@testable import MacUpdaterCore

final class ChromeUpdateCheckerTests: XCTestCase {
    func testPicksNewestVersionRegardlessOfOrder() {
        let json = Data("""
        {"versions":[
          {"version":"146.0.7651.0"},
          {"version":"146.0.7672.0"},
          {"version":"146.0.7600.1"}
        ]}
        """.utf8)
        XCTAssertEqual(ChromeUpdateParser.newestVersion(fromVersionHistoryJSON: json), "146.0.7672.0")
    }
    func testEmptyVersionsReturnsNil() {
        XCTAssertNil(ChromeUpdateParser.newestVersion(fromVersionHistoryJSON: Data(#"{"versions":[]}"#.utf8)))
    }
    func testGarbageReturnsNil() {
        XCTAssertNil(ChromeUpdateParser.newestVersion(fromVersionHistoryJSON: Data("nope".utf8)))
    }
    func testChannelMapCoversFourChannels() {
        XCTAssertEqual(ChromeUpdateChecker.channelsByBundleID["com.google.Chrome"], "stable")
        XCTAssertEqual(ChromeUpdateChecker.channelsByBundleID["com.google.Chrome.canary"], "canary")
    }
}
SWIFT

echo "== 2/5 Edycje in-place (kotwiczone, idempotentne) =="
python3 - <<'PY'
import sys

def read(p):
    with open(p) as f: return f.read()
def write(p, c):
    with open(p, 'w') as f: f.write(c)

def insert_after(p, anchor, text, sentinel):
    c = read(p)
    if sentinel in c:
        print(f"  skip  {p}  ({sentinel!r} już jest)"); return
    n = c.count(anchor)
    if n != 1:
        sys.exit(f"BŁĄD: kotwica występuje {n}× w {p} (oczekiwano 1):\n----\n{anchor}\n----")
    write(p, c.replace(anchor, anchor + text, 1))
    print(f"  ok    {p}")

def insert_before(p, anchor, text, sentinel):
    c = read(p)
    if sentinel in c:
        print(f"  skip  {p}  ({sentinel!r} już jest)"); return
    n = c.count(anchor)
    if n != 1:
        sys.exit(f"BŁĄD: kotwica występuje {n}× w {p} (oczekiwano 1):\n----\n{anchor}\n----")
    write(p, c.replace(anchor, text + anchor, 1))
    print(f"  ok    {p}")

def replace_once(p, old, new, sentinel):
    c = read(p)
    if sentinel in c:
        print(f"  skip  {p}  ({sentinel!r} już jest)"); return
    n = c.count(old)
    if n != 1:
        sys.exit(f"BŁĄD: fragment występuje {n}× w {p} (oczekiwano 1):\n----\n{old}\n----")
    write(p, c.replace(old, new, 1))
    print(f"  ok    {p}")

# --- endpoints.json ---
insert_after(
    "Sources/MacUpdaterCore/Resources/endpoints.json",
    '  "postmanUpdate": "https://dl.pstmn.io/update/osx_64/{version}",',
    '\n  "discordUpdate": "https://discord.com/api/updates/{channel}?platform=osx&version={version}",'
    '\n  "signalUpdate": "https://updates.signal.org/desktop/latest-mac.yml",'
    '\n  "chromeVersions": "https://versionhistory.googleapis.com/v1/chrome/platforms/mac/channels/{channel}/versions",',
    '"discordUpdate"')

# --- AppEndpoints.swift ---
AE = "Sources/MacUpdaterCore/AppEndpoints.swift"
insert_after(AE,
    "    public let postmanUpdate: String\n",
    "    public let discordUpdate: String\n    public let signalUpdate: String\n    public let chromeVersions: String\n",
    "    public let discordUpdate: String\n")
insert_before(AE,
    "    // MARK: Fixed endpoints (force-unwrapped: the bundled config is validated at launch)",
    '''    public func discordUpdateURL(channel: String, version: String) -> URL? {
        URL(string: Self.fill(discordUpdate, ["channel": channel, "version": version]))
    }

    public func chromeVersionsURL(channel: String) -> URL? {
        URL(string: Self.fill(chromeVersions, ["channel": channel]))
    }

''',
    "discordUpdateURL")
insert_after(AE,
    "    public var chatgptAppcastURL: URL { URL(string: chatgptAppcast)! }",
    "\n    public var signalUpdateURL: URL { URL(string: signalUpdate)! }",
    "signalUpdateURL")
insert_after(AE,
    "            postmanUpdate: raw(other.postmanUpdate, postmanUpdate),",
    "\n            discordUpdate: raw(other.discordUpdate, discordUpdate),"
    "\n            signalUpdate: validURL(other.signalUpdate, signalUpdate),"
    "\n            chromeVersions: raw(other.chromeVersions, chromeVersions),",
    "discordUpdate: raw(other.discordUpdate")
insert_after(AE,
    "    public let postmanUpdate: String?",
    "\n    public let discordUpdate: String?\n    public let signalUpdate: String?\n    public let chromeVersions: String?",
    "public let discordUpdate: String?")

# --- Models.swift ---
MD = "Sources/MacUpdaterCore/Models.swift"
insert_after(MD,
    "        case postman\n",
    "        /// Discord (stable / PTB / Canary) — self-updating host via Squirrel.Mac.\n        case discord\n"
    "        /// Signal Desktop — self-updating via electron-updater.\n        case signal\n"
    "        /// Google Chrome (stable / beta / dev / canary) — self-updating via Keystone.\n        case chrome\n",
    "        case discord\n")
insert_after(MD,
    "            case .postman:     return 5",
    "\n            case .discord:     return 5\n            case .signal:      return 5\n            case .chrome:      return 5",
    "case .discord:")

# --- ManualUpdateScanner.swift ---
MS = "Sources/MacUpdaterCore/ManualUpdateScanner.swift"
insert_after(MS,
    "        let postmanChecker = PostmanUpdateChecker()",
    "\n        let discordChecker = DiscordUpdateChecker()\n        let signalChecker = SignalUpdateChecker()\n        let chromeChecker = ChromeUpdateChecker()",
    "discordChecker")
insert_after(MS,
    '                work.append(Self.logged("Postman", app) { await postmanChecker.check(app: app) })',
    '\n                work.append(Self.logged("Discord", app) { await discordChecker.check(app: app) })'
    '\n                work.append(Self.logged("Signal", app) { await signalChecker.check(app: app) })'
    '\n                work.append(Self.logged("Chrome", app) { await chromeChecker.check(app: app) })',
    '"Discord", app')

# --- UpdateViewSupport.swift (3 nowe case'y w przełączniku manualAction) ---
UV = "Sources/MacUpdater/UpdateViewSupport.swift"
old = (
"                .controlSize(.small)\n"
"            }\n"
"        }\n"
)
new = (
"                .controlSize(.small)\n"
"            }\n"
"        case .discord:\n"
"            HStack(spacing: 8) {\n"
'                WegaBadge(label: "Discord", variant: .info)\n'
"                Button {\n"
"                    // Discord self-updates its host via Squirrel; the discord* casks are\n"
"                    // auto_updates and lag, so brew would reinstall a stale build.\n"
"                    NSWorkspace.shared.open(item.path)\n"
"                } label: {\n"
'                    Label(tr("Otwórz i zaktualizuj"), systemImage: "arrow.up.forward.app")\n'
"                }\n"
"                .controlSize(.small)\n"
"            }\n"
"        case .signal:\n"
"            HStack(spacing: 8) {\n"
'                WegaBadge(label: "Signal", variant: .info)\n'
"                Button {\n"
"                    // Signal self-updates via electron-updater; the signal cask is\n"
"                    // auto_updates and lags. Launch it so its own updater applies.\n"
"                    NSWorkspace.shared.open(item.path)\n"
"                } label: {\n"
'                    Label(tr("Otwórz i zaktualizuj"), systemImage: "arrow.up.forward.app")\n'
"                }\n"
"                .controlSize(.small)\n"
"            }\n"
"        case .chrome:\n"
"            HStack(spacing: 8) {\n"
'                WegaBadge(label: "Chrome", variant: .info)\n'
"                Button {\n"
"                    // Chrome self-updates via Keystone; the google-chrome* casks are\n"
"                    // auto_updates and lag. Relaunch applies the staged update.\n"
"                    NSWorkspace.shared.open(item.path)\n"
"                } label: {\n"
'                    Label(tr("Otwórz i zaktualizuj"), systemImage: "arrow.up.forward.app")\n'
"                }\n"
"                .controlSize(.small)\n"
"            }\n"
"        }\n"
)
replace_once(UV, old, new, "case .discord:")

# --- AppEndpointsTests.swift (init overlay MUSI dostać nowe pola + asercje) ---
TS = "Tests/MacUpdaterTests/AppEndpointsTests.swift"
insert_after(TS,
    "            postmanUpdate: nil,",
    "\n            discordUpdate: nil,\n            signalUpdate: nil,\n            chromeVersions: nil,",
    "discordUpdate: nil,")
insert_after(TS,
    '                       "https://dl.pstmn.io/update/osx_64/12.15.6")',
    '\n        XCTAssertEqual(e.discordUpdateURL(channel: "canary", version: "0.0.966")?.absoluteString,'
    '\n                       "https://discord.com/api/updates/canary?platform=osx&version=0.0.966")'
    '\n        XCTAssertEqual(e.chromeVersionsURL(channel: "canary")?.absoluteString,'
    '\n                       "https://versionhistory.googleapis.com/v1/chrome/platforms/mac/channels/canary/versions")',
    "discordUpdateURL(channel:")
insert_after(TS,
    '        XCTAssertEqual(e.masRepositoryURL.absoluteString, "https://github.com/mas-cli/mas")',
    '\n        XCTAssertEqual(e.signalUpdateURL.absoluteString,'
    '\n                       "https://updates.signal.org/desktop/latest-mac.yml")',
    "signalUpdateURL.absoluteString")

print("Edycje naniesione.")
PY

echo "== 3/5 Build + testy =="
swift build
if [ "${SKIP_TESTS:-0}" != "1" ]; then swift test; else echo "  (pominięto swift test — SKIP_TESTS=1)"; fi

echo "== 4/5 Commit na main =="
git add -A
if git diff --cached --quiet; then
  echo "  brak zmian do commita (może auto-commit już je zebrał?)"
else
  git commit -m "feat: checkery self-update dla Discord/Signal/Chrome (casks auto_updates lagi)"
  echo "  zacommitowano na main"
fi

echo "== 5/5 Sprzątanie brancha =="
echo "-- worktrees --"; git worktree list
echo "-- branches  --"; git branch --all
if [ -n "$BRANCH_TO_DELETE" ]; then
  wtpath="$(git worktree list --porcelain | awk -v b="branch refs/heads/$BRANCH_TO_DELETE" '/^worktree /{p=$2} $0==b{print p}')"
  if [ -n "$wtpath" ]; then echo "Usuwam worktree: $wtpath"; git worktree remove "$wtpath"; fi
  git branch -d "$BRANCH_TO_DELETE" && echo "Usunięto branch: $BRANCH_TO_DELETE"
else
  echo "Nie podano brancha do usunięcia — pomijam. Aby usunąć: ./clean.sh <nazwa-brancha>"
fi

echo "GOTOWE."