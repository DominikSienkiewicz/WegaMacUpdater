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
///
/// `Hashable` (not just `Equatable`) so the value can back a SwiftUI `Picker` selection —
/// `Picker`'s `SelectionValue` requires `Hashable`.
public enum BugReportChannel: Sendable, Hashable {
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

    /// Appended to a description that had to be cut. The spec asks for two things that
    /// cannot both hold — "the description is never truncated" and "the URL never exceeds
    /// the channel limit" — and the limit wins: an over-limit `mailto:` is silently mangled
    /// by the mail client, while a shortened description is something the reader can see.
    /// So it has to be visible; a half-sentence that looks whole is the failure mode this
    /// marker exists to prevent.
    public static let descriptionShortenedMarker =
        "… [truncated — the description did not fit the channel's URL limit]"

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
        body(draft, channel: channel, title: title(draft))
    }

    private func body(_ draft: BugReportDraft, channel: BugReportChannel, title: String) -> BugReportBody {
        let fixed = fixedSections(draft)

        // Wszystko, czego przycinanie wpisów nie rusza — prefiks URL-a, tytuł i sekcje
        // stałe — wycenione BEZ opisu użytkownika. Percent-encoding jest odwzorowaniem
        // znak po znaku, więc zakodowane długości po prostu się sumują i opis da się
        // wycenić osobno.
        let overhead = encodedOverhead(draft, channel: channel, title: title, fixed: fixed)

        // Ostatnia deska ratunku: gdy same sekcje stałe przekraczają limit kanału, ucina się
        // OPIS — bo URL ponad limit klient poczty i tak okroi po cichu, a widocznie skrócony
        // opis użytkownik przynajmniej widzi. Wpisy idą pierwsze: opis rusza się dopiero, gdy
        // budżet i tak spadł do zera. Blok środowiska pozostaje nietykalny, więc dostatecznie
        // rozbudowana metryczka to jedyny przypadek, w którym limitu nie da się dotrzymać.
        let description = shortened(fixed.description,
                                    toEncodedLength: max(0, channel.urlLengthLimit - overhead))
        let budget = max(0, channel.urlLengthLimit - overhead
                            - PrefilledURLBody.percentEncoded(description).count)

        // Od najnowszego: awaria jest ostatnia. Pierwsza, która się nie zmieści, kończy
        // przeglądanie — inaczej krótszy STARSZY wpis mógłby wskoczyć na miejsce dłuższego
        // NOWSZEGO, który odpadł, i zbiór zachowanych wpisów przestałby być ciągły.
        //
        // Redakcja dzieje się W pętli, nie przed nią: pętla i tak zatrzymuje się na
        // pierwszym niemieszczącym się wpisie, więc koszt idzie za tym, co zostaje
        // (zachowane + jeden), a nie za tym, co zaznaczono — a ⌘A w zakładce Logi potrafi
        // podać całe 2000 wpisów bufora, przy przebudowie okna po KAŻDYM znaku opisu.
        //
        // Każdy `fileText` (linia nagłówka plus linie detalu z prefiksem `\t| `) idzie do
        // redaktora w JEDNYM wywołaniu, w całości, nigdy linia po linii. Wzorzec `pemBlock`
        // w `LogRedaction` obejmuje "-----BEGIN … PRIVATE KEY-----" aż po "-----END …
        // PRIVATE KEY-----" i musi zobaczyć oba znaczniki w jednym przebiegu; klucz PEM
        // złapany w `stderr` detalu serializuje się na kilka osobnych linii kontynuacji,
        // więc redakcja per linia nigdy nie pokazałaby wzorcowi całego bloku.
        var kept: [String] = []
        var omitted = 0
        var stillFits = true
        for entry in draft.entries.sorted(by: { $0.date < $1.date }).reversed() {
            if stillFits {
                let text = redact(entry.fileText)
                let candidate = ([text] + kept).joined(separator: "\n")
                if PrefilledURLBody.percentEncoded(candidate).count <= budget {
                    kept.insert(text, at: 0)
                    continue
                }
                stillFits = false
            }
            omitted += 1
        }

        var lines = fixed.lines(description: description)
        lines.append("## Log entries (\(draft.entries.count) selected)")
        if omitted > 0 { lines.append("[truncated — \(omitted) earlier entries omitted]") }
        lines.append(contentsOf: kept)
        lines.append(contentsOf: fixed.tail)
        return BugReportBody(text: lines.joined(separator: "\n"), omittedEntryCount: omitted)
    }

    // MARK: - URL

    public func url(_ draft: BugReportDraft, channel: BugReportChannel) -> URL? {
        // Policzony RAZ i przekazany w dół: `body` wycenia go w narzucie kanału, więc
        // liczony osobno byłby tym samym przebiegiem redakcji zrobionym dwa razy.
        let title = title(draft)
        let encodedTitle = PrefilledURLBody.percentEncoded(title)
        let encodedBody = PrefilledURLBody.percentEncoded(body(draft, channel: channel, title: title).text)
        switch channel {
        case .email(let address):
            // SEC: the address is emitted LITERALLY. `@` is the separator between the local
            // part and the host — RFC 6068's own examples keep it unencoded and escape only
            // specials inside the local part — and per RFC 3986 §2.2 a percent-encoded
            // reserved delimiter is a different URI, not a safer spelling of the same one.
            //
            // What keeps a hostile address out is validation at the boundary, not encoding
            // here: `address` comes from `endpoints.json`, which a user-writable overlay
            // (`~/Library/Application Support/WegaMacUpdater/endpoints.json`) can replace, and
            // `AppEndpoints.overlaying(_:)` refuses any override that is not a plain ASCII
            // address — no `?`, `&`, `#`, whitespace or control characters — falling back to
            // the bundled value. Encoding never addressed the real risk anyway: an overlay
            // silently redirecting every report to someone else's mailbox needs no `?` at all.
            return URL(string: "mailto:\(address)?subject=\(encodedTitle)&body=\(encodedBody)")
        case .gitHubIssue(let endpoint):
            return URL(string: "\(endpoint.absoluteString)?title=\(encodedTitle)&body=\(encodedBody)")
        }
    }

    // MARK: - Sekcje stałe

    private struct FixedSections {
        /// Nagłówek nad opisem użytkownika.
        let head: [String]
        /// Wszystko między opisem a blokiem wpisów — czyli metryczka środowiska.
        let middle: [String]
        let tail: [String]
        /// Zredagowany opis użytkownika, jeszcze w pełnej długości. Trzymany osobno, bo
        /// jako jedyna z sekcji stałych może zostać skrócony — i tylko w ostateczności.
        let description: String

        /// Sekcje stałe ułożone wokół podanego opisu. Liczba elementów nie zależy od jego
        /// treści, więc wycena z pustym opisem ma dokładnie tyle samo separatorów co
        /// finalny tekst.
        func lines(description: String) -> [String] { head + [description] + middle }
    }

    private func fixedSections(_ draft: BugReportDraft) -> FixedSections {
        let described = draft.userDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        var middle: [String] = ["", "## Environment"]
        middle.append(contentsOf: draft.environment.map { "- \(redact($0.label)): \(redact($0.value))" })
        middle.append("")
        return FixedSections(
            head: ["## What happened"],
            middle: middle,
            tail: [
                "",
                "## Note",
                "This report is redacted: paths, query strings, credentials, e-mail addresses",
                "and account names are replaced with placeholders.",
            ],
            description: described.isEmpty ? "(not provided)" : redact(described)
        )
    }

    /// The description cut on a whole-character boundary so its encoding fits `limit`, with
    /// ``descriptionShortenedMarker`` appended so the cut is visible. Returned untouched
    /// when it already fits, which is the ordinary case.
    private func shortened(_ description: String, toEncodedLength limit: Int) -> String {
        guard PrefilledURLBody.percentEncoded(description).count > limit else { return description }
        let markerCost = PrefilledURLBody.percentEncoded(Self.descriptionShortenedMarker).count
        guard limit > markerCost else {
            // Not even the marker fits: the environment block alone has eaten the channel's
            // budget. Say as much as there is room for rather than emitting a fragment of
            // the description that looks whole.
            return PrefilledURLBody.truncated(Self.descriptionShortenedMarker, toEncodedLength: limit)
        }
        return PrefilledURLBody.truncated(description, toEncodedLength: limit - markerCost)
            + Self.descriptionShortenedMarker
    }

    /// Zakodowana długość `"\n"`. Sekcje stałe i blok wpisów są w finalnym tekście
    /// spajane jednym dodatkowym separatorem, którego nie widać w żadnej z nich osobno.
    private static let separatorCost = PrefilledURLBody.percentEncoded("\n").count

    /// Ile z limitu kanału zjada wszystko poza wpisami I opisem użytkownika — tego
    /// przycinanie wpisów nie rusza. Znacznik przycięcia wliczany jest zawsze, w najdłuższej
    /// możliwej postaci, żeby jego późniejsze dopisanie nie mogło przepchnąć URL-a ponad
    /// limit. Opis wyceniany jest osobno, bo jako jedyny bywa skracany.
    private func encodedOverhead(_ draft: BugReportDraft, channel: BugReportChannel,
                                 title: String, fixed: FixedSections) -> Int {
        let scheme: String
        switch channel {
        case .email(let address):
            // Liczone tak, jak `url(_:channel:)` to składa — adres dosłownie, bez kodowania.
            scheme = "mailto:\(address)?subject=&body="
        case .gitHubIssue(let endpoint):
            scheme = "\(endpoint.absoluteString)?title=&body="
        }
        let header = "## Log entries (\(draft.entries.count) selected)"
        let marker = "[truncated — \(draft.entries.count) earlier entries omitted]"
        let fixedText = (fixed.lines(description: "") + [header, marker] + fixed.tail)
            .joined(separator: "\n")
        return scheme.count
            + PrefilledURLBody.percentEncoded(title).count
            + PrefilledURLBody.percentEncoded(fixedText).count
            + Self.separatorCost
    }
}
