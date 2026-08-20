import Foundation

/// Strukturalny kontekst jednej awarii, dopięty do wpisu logu, który wyjaśnia.
///
/// Istnieje, bo `LogEntry.message` jest jednym płaskim stringiem: `stderr`, kod wyjścia
/// i uruchomiona komenda nie miały gdzie wylądować i ginęły w `localizedDescription`.
/// Wpis mówił „aktualizacja nie powiodła się", a nie *dlaczego*.
///
/// Serializuje się do linii kontynuacji poprzedzonych ``continuationPrefix``. Stary
/// `LogEntry.parse` zwraca dla nich `nil`, a `LogStore.loadFromFile` je odfiltrowuje —
/// więc starsza wersja aplikacji czytająca nowszy plik gubi detal, zamiast się wywrócić.
public struct LogDetail: Equatable, Sendable {

    /// Jeden fakt o awarii: `command`, `exit`, `subject`, `source`.
    public struct Field: Equatable, Sendable {
        public let key: String
        public let value: String

        public init(key: String, value: String) {
            self.key = key
            self.value = Self.flattened(value)
        }

        /// Wartość pola zajmuje dokładnie jedną linię — inaczej rozerwałaby format.
        private static func flattened(_ value: String) -> String {
            value.replacingOccurrences(of: "\n", with: " ")
                 .replacingOccurrences(of: "\r", with: " ")
        }
    }

    /// Prefiks każdej linii detalu w pliku logu.
    public static let continuationPrefix = "\t| "
    /// Oddziela pola od dosłownego wyjścia. Jednoznaczny, więc `stderr` zawierające
    /// `": "` nie może zostać sparsowane jako pole.
    public static let outputMarker = "---"

    public static let maxOutputLines = 40
    public static let maxOutputCharacters = 4000
    public static let maxSerializedCharacters = 8000

    public let fields: [Field]
    public let output: String?

    public init(fields: [Field], output: String?) {
        self.fields = fields
        self.output = Self.capped(output)
    }

    /// Wygodny konstruktor dla typowej awarii procesu. Zwraca `nil`, gdy nie ma czego
    /// zapisać — wpis bez detalu serializuje się wtedy bajt w bajt tak jak dotąd.
    public init?(
        command: String? = nil,
        exitCode: Int32? = nil,
        stderr: String? = nil,
        subject: String? = nil,
        source: String? = nil
    ) {
        var fields: [Field] = []
        if let subject, !subject.isEmpty { fields.append(Field(key: "subject", value: subject)) }
        if let source, !source.isEmpty { fields.append(Field(key: "source", value: source)) }
        if let command, !command.isEmpty { fields.append(Field(key: "command", value: command)) }
        if let exitCode { fields.append(Field(key: "exit", value: String(exitCode))) }

        let trimmed = stderr?.trimmingCharacters(in: .whitespacesAndNewlines)
        let output = (trimmed?.isEmpty ?? true) ? nil : trimmed
        guard !fields.isEmpty || output != nil else { return nil }
        self.init(fields: fields, output: output)
    }

    /// Linie do zapisania w `wega.log`, z prefiksem włącznie.
    public var continuationLines: [String] {
        var lines = fields.map { "\(Self.continuationPrefix)\($0.key): \($0.value)" }
        if let output {
            lines.append("\(Self.continuationPrefix)\(Self.outputMarker)")
            lines.append(contentsOf: output.components(separatedBy: "\n")
                .map { "\(Self.continuationPrefix)\($0)" })
        }
        return Self.cappedSerialization(lines)
    }

    /// Odtwarza detal z linii kontynuacji. `nil`, gdy nie ma żadnych.
    public static func parse(continuationLines lines: [String]) -> LogDetail? {
        guard !lines.isEmpty else { return nil }
        var fields: [Field] = []
        var outputLines: [String] = []
        var inOutput = false

        for line in lines {
            let body = line.hasPrefix(continuationPrefix)
                ? String(line.dropFirst(continuationPrefix.count))
                : line
            if !inOutput, body == outputMarker { inOutput = true; continue }
            if inOutput { outputLines.append(body); continue }
            guard let separator = body.range(of: ": ") else { continue }
            fields.append(Field(
                key: String(body[body.startIndex..<separator.lowerBound]),
                value: String(body[separator.upperBound...])
            ))
        }
        guard !fields.isEmpty || inOutput else { return nil }
        return LogDetail(fields: fields, output: inOutput ? outputLines.joined(separator: "\n") : nil)
    }

    /// Ten sam detal z każdą wartością przepuszczoną przez `transform`. Używane, żeby
    /// kanał OSLog dostał tekst zredagowany dokładnie tak jak `message`.
    public func redacted(using transform: (String) -> String) -> LogDetail {
        LogDetail(
            fields: fields.map { Field(key: $0.key, value: transform($0.value)) },
            output: output.map(transform)
        )
    }

    // MARK: - Limity

    /// Zachowuje **ogon** wyjścia: awaria jest na końcu, nie na początku.
    private static func capped(_ output: String?) -> String? {
        guard let output else { return nil }
        var lines = output.components(separatedBy: "\n")
        if lines.count > maxOutputLines { lines = Array(lines.suffix(maxOutputLines)) }
        var text = lines.joined(separator: "\n")
        if text.count > maxOutputCharacters { text = String(text.suffix(maxOutputCharacters)) }
        return text
    }

    /// Ostatnia bariera: jeden rozgadany proces nie może wyczerpać budżetu rotacji pliku
    /// jednym wpisem. Ucinane są najstarsze linie wyjścia, nigdy pola.
    private static func cappedSerialization(_ lines: [String]) -> [String] {
        var lines = lines
        let marker = "\(continuationPrefix)\(outputMarker)"
        while lines.joined(separator: "\n").count > maxSerializedCharacters,
              let markerIndex = lines.firstIndex(of: marker),
              lines.count > markerIndex + 1 {
            lines.remove(at: markerIndex + 1)
        }
        return lines
    }
}
