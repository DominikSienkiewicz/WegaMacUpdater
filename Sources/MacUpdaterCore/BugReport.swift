import Foundation

/// Wszystko, co użytkownik zgłasza: jego własny opis, metryczka środowiska i wpisy
/// z logu, które zaznaczył.
public struct BugReportDraft: Sendable, Equatable {
    public var userDescription: String
    public var environment: [ReportField]
    public var entries: [LogEntry]

    public init(userDescription: String, environment: [ReportField], entries: [LogEntry]) {
        self.userDescription = userDescription
        self.environment = environment
        self.entries = entries
    }
}

/// Dokąd zgłoszenie trafia. Kanał niesie własny limit długości URL-a, żeby żadne
/// wywołanie nie mogło zbudować treści pod limit innego kanału.
public enum BugReportChannel: Sendable, Equatable {
    case email(address: String)
    case gitHubIssue(endpoint: URL)

    /// `mailto:` jest ograniczone nie przez standard, lecz przez najciaśniejszego klienta —
    /// Outlook przycina około 2048 znaków całego URL-a. GitHub przyjmuje tyle, ile stosuje
    /// już ``CatalogIssueBuilder``.
    public var urlLengthLimit: Int {
        switch self {
        case .email:       return 2000
        case .gitHubIssue: return 8000
        }
    }
}

/// Gotowa treść wraz z informacją, ile wpisów się w niej nie zmieściło.
public struct BugReportBody: Sendable, Equatable {
    public let text: String
    public let omittedEntryCount: Int

    public init(text: String, omittedEntryCount: Int) {
        self.text = text
        self.omittedEntryCount = omittedEntryCount
    }
}

/// Buduje zgłoszenie błędu z zaznaczonych wpisów logu.
///
/// Dwie własności są tu wymuszone strukturalnie, nie konwencją:
///
/// 1. **Wszystko jest zredagowane.** Żaden tekst nie trafia do treści inaczej niż przez
///    ``redact``, więc pole dodane później nie może zapomnieć o redakcji.
/// 2. **Ten sam `draft` zasila oba kanały.** Treść jest jedna; kanał zmienia wyłącznie
///    opakowanie w URL. Dzięki temu „co opuszcza maszynę" testuje się raz, nie dwa razy.
public struct BugReportBuilder: Sendable {

    public typealias Redactor = @Sendable (String) -> String

    /// Maksymalna długość tytułu, zanim zostanie skrócony. Tytuł **nigdy** nie jest
    /// przycinany przez limit URL-a — budżet zabierają mu wyłącznie wpisy.
    public static let maxTitleLength = 90

    private let redact: Redactor

    public init(redact: @escaping Redactor = { LogRedaction.redactForExport($0) }) {
        self.redact = redact
    }

    // MARK: - Tytuł

    public func title(_ draft: BugReportDraft) -> String {
        let newestError = draft.entries.filter { $0.level == .error }.max { $0.date < $1.date }
        guard let subject = newestError ?? draft.entries.max(by: { $0.date < $1.date }) else {
            return "[Bug] Wega Mac Updater"
        }
        let text = redact(subject.message)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = text.count > Self.maxTitleLength
            ? String(text.prefix(Self.maxTitleLength)).trimmingCharacters(in: .whitespaces) + "…"
            : text
        return "[Bug] \(trimmed)"
    }

    // MARK: - Treść

    public func body(_ draft: BugReportDraft, channel: BugReportChannel) -> BugReportBody {
        let fixed = fixedSections(draft)
        let entryTexts = draft.entries
            .sorted { $0.date < $1.date }
            .map { redactLines($0.fileText) }

        // Budżet dla wpisów to limit kanału pomniejszony o wszystko, czego nie wolno ciąć:
        // prefiks URL-a, tytuł i sekcje stałe.
        let budget = channel.urlLengthLimit - encodedOverhead(draft, channel: channel, fixed: fixed)

        var kept: [String] = []
        var omitted = 0
        for text in entryTexts.reversed() {   // od najnowszego: awaria jest ostatnia
            let candidate = ([text] + kept).joined(separator: "\n")
            if PrefilledURLBody.percentEncoded(candidate).count <= budget {
                kept.insert(text, at: 0)
            } else {
                omitted += 1
            }
        }

        var lines = fixed.head
        lines.append("## Log entries (\(draft.entries.count) selected)")
        if omitted > 0 { lines.append("[truncated — \(omitted) earlier entries omitted]") }
        lines.append(contentsOf: kept)
        lines.append(contentsOf: fixed.tail)
        return BugReportBody(text: lines.joined(separator: "\n"), omittedEntryCount: omitted)
    }

    // MARK: - URL

    public func url(_ draft: BugReportDraft, channel: BugReportChannel) -> URL? {
        let encodedTitle = PrefilledURLBody.percentEncoded(title(draft))
        let encodedBody = PrefilledURLBody.percentEncoded(body(draft, channel: channel).text)
        switch channel {
        case .email(let address):
            // SEC: `address` ultimately comes from `endpoints.json`, which a user-writable
            // overlay (`~/Library/Application Support/WegaMacUpdater/endpoints.json`) can
            // replace — and unlike every other endpoint, it is not validated as a URL when
            // the overlay is merged. An address containing `?`/`&` (e.g.
            // "victim@example.com?bcc=attacker@evil.com&body=") would otherwise inject extra
            // mailto headers the user never sees before their mail client opens. Percent-
            // encoding it closes that off; encoding `@` to `%40` is valid in a mailto URI.
            let encodedAddress = PrefilledURLBody.percentEncoded(address)
            return URL(string: "mailto:\(encodedAddress)?subject=\(encodedTitle)&body=\(encodedBody)")
        case .gitHubIssue(let endpoint):
            return URL(string: "\(endpoint.absoluteString)?title=\(encodedTitle)&body=\(encodedBody)")
        }
    }

    // MARK: - Sekcje stałe

    private struct FixedSections {
        let head: [String]
        let tail: [String]
    }

    private func fixedSections(_ draft: BugReportDraft) -> FixedSections {
        let described = draft.userDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        var head: [String] = [
            "## What happened",
            described.isEmpty ? "(not provided)" : redact(described),
            "",
            "## Environment",
        ]
        head.append(contentsOf: draft.environment.map { "- \(redact($0.label)): \(redact($0.value))" })
        head.append("")
        let tail = [
            "",
            "## Note",
            "This report is redacted: paths, query strings, credentials, e-mail addresses",
            "and account names are replaced with placeholders.",
        ]
        return FixedSections(head: head, tail: tail)
    }

    /// Zakodowana długość `"\n"`. Sekcje stałe i blok wpisów są w finalnym tekście
    /// spajane jednym dodatkowym separatorem, którego nie widać w żadnej z nich osobno.
    private static let separatorCost = PrefilledURLBody.percentEncoded("\n").count

    /// Ile z limitu kanału zjada wszystko poza wpisami — tego przycinanie nie rusza.
    /// Znacznik przycięcia wliczany jest zawsze, w najdłuższej możliwej postaci, żeby
    /// jego późniejsze dopisanie nie mogło przepchnąć URL-a ponad limit.
    private func encodedOverhead(_ draft: BugReportDraft, channel: BugReportChannel,
                                 fixed: FixedSections) -> Int {
        let scheme: String
        switch channel {
        case .email(let address):
            let encodedAddress = PrefilledURLBody.percentEncoded(address)
            scheme = "mailto:\(encodedAddress)?subject=&body="
        case .gitHubIssue(let endpoint):
            scheme = "\(endpoint.absoluteString)?title=&body="
        }
        let header = "## Log entries (\(draft.entries.count) selected)"
        let marker = "[truncated — \(draft.entries.count) earlier entries omitted]"
        let fixedText = (fixed.head + [header, marker] + fixed.tail).joined(separator: "\n")
        return scheme.count
            + PrefilledURLBody.percentEncoded(title(draft)).count
            + PrefilledURLBody.percentEncoded(fixedText).count
            + Self.separatorCost
    }

    /// Redaguje wpis linia po linii, żeby wzorce zakotwiczone na początku linii — jak
    /// prefiks detalu — nadal pasowały.
    private func redactLines(_ text: String) -> String {
        text.components(separatedBy: "\n").map(redact).joined(separator: "\n")
    }
}
