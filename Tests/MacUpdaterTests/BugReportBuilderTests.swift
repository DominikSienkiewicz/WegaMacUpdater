import Foundation
import Testing
@testable import MacUpdaterCore

@Suite("BugReportBuilder")
struct BugReportBuilderTests {

    private let gitHub = BugReportChannel.gitHubIssue(
        endpoint: URL(string: "https://github.com/owner/repo/issues/new")!
    )
    private let email = BugReportChannel.email(address: "bugs@example.test")

    private func entry(_ message: String, level: LogLevel = .error,
                       at seconds: TimeInterval = 1_770_000_000,
                       detail: LogDetail? = nil) -> LogEntry {
        LogEntry(date: Date(timeIntervalSince1970: seconds), level: level,
                 category: .homebrew, message: message, detail: detail)
    }

    private func draft(entries: [LogEntry],
                       description: String = "Kliknąłem aktualizuj.") -> BugReportDraft {
        BugReportDraft(
            userDescription: description,
            environment: [ReportField(label: "Wega", value: "1.4.2 (812)")],
            entries: entries
        )
    }

    private func fatDraft() -> BugReportDraft {
        draft(entries: (1...300).map {
            entry("entry-\($0) " + String(repeating: "x", count: 200), at: TimeInterval($0))
        })
    }

    private static func queryItems(_ url: URL) throws -> [String: String] {
        let comps = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        return Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    // MARK: Tytuł

    @Test func titleComesFromTheNewestErrorEntry() {
        let title = BugReportBuilder().title(draft(entries: [
            entry("stary błąd", at: 1),
            entry("świeży błąd", at: 2),
            entry("zwykła informacja", level: .info, at: 3),
        ]))
        #expect(title == "[Bug] świeży błąd")
    }

    @Test func titleFallsBackToTheNewestEntryWhenNothingFailed() {
        let title = BugReportBuilder().title(draft(entries: [entry("wszystko gra", level: .info)]))
        #expect(title == "[Bug] wszystko gra")
    }

    @Test func titleIsNeverTruncatedByTheURLLimit() throws {
        let builder = BugReportBuilder()
        let d = fatDraft()
        let url = try #require(builder.url(d, channel: email))
        let items = try Self.queryItems(url)
        #expect(items["subject"] == builder.title(d))
    }

    // MARK: Treść

    @Test func bodyCarriesDescriptionEnvironmentAndEntries() {
        let text = BugReportBuilder().body(draft(entries: [entry("foo padł")]), channel: gitHub).text
        #expect(text.contains("## What happened"))
        #expect(text.contains("Kliknąłem aktualizuj."))
        #expect(text.contains("- Wega: 1.4.2 (812)"))
        #expect(text.contains("foo padł"))
        #expect(text.contains("This report is redacted"))
    }

    @Test func anAbsentDescriptionIsMarkedRatherThanLeftBlank() {
        let text = BugReportBuilder()
            .body(draft(entries: [entry("foo padł")], description: "   "), channel: gitHub).text
        #expect(text.contains("(not provided)"))
    }

    @Test func entriesCarryTheirFailureDetail() {
        let detailed = entry("foo padł",
                             detail: LogDetail(command: "brew upgrade", exitCode: 1, stderr: "boom"))
        let text = BugReportBuilder().body(draft(entries: [detailed]), channel: gitHub).text
        #expect(text.contains("boom"))
        #expect(text.contains("exit: 1"))
    }

    // MARK: Redakcja

    @Test func nothingUnredactedLeavesTheMachine() {
        let builder = BugReportBuilder(redact: {
            LogRedaction.redactForExport($0, userNames: ["ala", "Ala Kowalska"])
        })
        let leaky = entry("nie mogę zapisać /Users/ala/Library/Caches/foo — token=ghp_0123456789abcdefghij")
        let text = builder.body(draft(entries: [leaky], description: "moje konto to ala"),
                                channel: gitHub).text
        #expect(text.contains("/Users/ala") == false)
        #expect(text.contains("ghp_0123456789abcdefghij") == false)
        #expect(text.contains("[user]"), "nazwa konta z opisu użytkownika też jest redagowana")
    }

    @Test func aMultiLinePEMKeyInADetailCannotSurviveRedaction() {
        // LogRedaction's pemBlock pattern spans "-----BEGIN … PRIVATE KEY-----" through
        // "-----END … PRIVATE KEY-----" and must see both markers in one pass. A failed
        // git/ssh/gpg invocation can land a PEM key in a detail's stderr, which serialises
        // to several separate continuation lines — redacting those lines one at a time
        // would never present the whole block to the pattern at once.
        let pemKey = """
        -----BEGIN PRIVATE KEY-----
        MIIBVQIBADANBgkqhkiG9w0BAQEFAASCAT8wggE7AgEAAkEAy1QXJ9k2ZP0abcd
        NHVv3fQeLp8sTz1mWkX7yBc4RdE6gHj2KfA9uYo0IiPz5nSrTlVwOxCq8bMdEjF
        -----END PRIVATE KEY-----
        """
        let leaking = entry("git push padł",
                            detail: LogDetail(command: "git push", exitCode: 1, stderr: pemKey))
        let text = BugReportBuilder().body(draft(entries: [leaking]), channel: gitHub).text
        #expect(text.contains("-----BEGIN PRIVATE KEY-----") == false)
        #expect(text.contains("MIIBVQIBADANBgkqhkiG9w0BAQEFAASCAT8wggE7AgEAAkEAy1QXJ9k2ZP0abcd") == false)
        #expect(text.contains("NHVv3fQeLp8sTz1mWkX7yBc4RdE6gHj2KfA9uYo0IiPz5nSrTlVwOxCq8bMdEjF") == false)
    }

    @Test func theMailtoAddressCannotInjectExtraHeaders() throws {
        // The address comes from a user-writable overlay (endpoints.json) that is not
        // validated as a URL, so it can carry `?`/`&` that would otherwise smuggle extra
        // mailto headers (e.g. a hidden `bcc`) into the URL the user's mail client opens.
        let injecting = BugReportChannel.email(
            address: "victim@example.test?bcc=attacker@evil.test&body="
        )
        let url = try #require(BugReportBuilder().url(draft(entries: [entry("foo padł")]), channel: injecting))
        #expect(url.absoluteString.contains("?bcc=") == false)
    }

    // MARK: Przycinanie

    @Test func anOverlongBodyIsTruncatedAtAnEntryBoundaryWithAMarker() {
        let body = BugReportBuilder().body(fatDraft(), channel: email)
        #expect(body.omittedEntryCount > 0)
        #expect(body.text.contains("[truncated — \(body.omittedEntryCount) earlier entries omitted]"))
    }

    @Test func truncationDropsTheOldestEntriesAndKeepsTheNewest() {
        let body = BugReportBuilder().body(fatDraft(), channel: email)
        #expect(body.text.contains("entry-300"), "awaria jest ostatnia — ostatnie wpisy zostają")
        #expect(body.text.contains("entry-1 ") == false)
    }

    @Test func theEnvironmentAndDescriptionSurviveTruncation() {
        let body = BugReportBuilder().body(fatDraft(), channel: email)
        #expect(body.text.contains("- Wega: 1.4.2 (812)"))
        #expect(body.text.contains("Kliknąłem aktualizuj."))
    }

    @Test func truncationKeepsAContiguousRunOfTheNewestEntries() {
        // oldest → newest: short, very long (already exceeds the budget alone), short.
        // Newest-first probing must STOP at the first miss — an older, shorter entry must
        // not sneak back in after a newer, longer one was rejected, or the kept set stops
        // being "the newest entries" and starts being "whichever entries happen to fit".
        let longMessage = String(repeating: "y", count: 5000)
        let d = draft(entries: [
            entry("first-short", at: 1),
            entry(longMessage, at: 2),
            entry("third-short", at: 3),
        ])
        let body = BugReportBuilder().body(d, channel: email)
        let hasFirst = body.text.contains("first-short")
        let hasSecond = body.text.contains(longMessage)
        let hasThird = body.text.contains("third-short")
        #expect(hasThird, "the newest entry must survive if anything does")
        #expect(hasSecond == false, "the oversized middle entry cannot fit under any ordering")
        #expect(hasFirst == false, "an older entry must not survive while a newer one was dropped")
        #expect(body.omittedEntryCount == 2)
    }

    @Test func everyChannelStaysUnderItsOwnLimit() throws {
        let builder = BugReportBuilder()
        for channel in [email, gitHub] {
            let url = try #require(builder.url(fatDraft(), channel: channel))
            #expect(url.absoluteString.count <= channel.urlLengthLimit)
        }
    }

    // MARK: URL

    @Test func theEmailChannelBuildsAMailtoURL() throws {
        let url = try #require(BugReportBuilder().url(draft(entries: [entry("foo padł")]), channel: email))
        #expect(url.scheme == "mailto")
        #expect(url.absoluteString.hasPrefix("mailto:bugs%40example.test?subject="))
        let items = try Self.queryItems(url)
        #expect(items["body"]?.contains("foo padł") == true)
    }

    @Test func theGitHubChannelBuildsATitleAndBodyQuery() throws {
        let url = try #require(BugReportBuilder().url(draft(entries: [entry("foo padł")]), channel: gitHub))
        #expect(url.absoluteString.hasPrefix("https://github.com/owner/repo/issues/new?title="))
        let items = try Self.queryItems(url)
        #expect(items["title"]?.hasPrefix("[Bug] ") == true)
    }

    @Test func spacesAndAmpersandsAreEscaped() throws {
        let url = try #require(BugReportBuilder().url(draft(entries: [entry("foo & bar padły")]),
                                                      channel: gitHub))
        #expect(url.absoluteString.contains(" ") == false)
        #expect(url.absoluteString.contains("%26"))
    }
}
