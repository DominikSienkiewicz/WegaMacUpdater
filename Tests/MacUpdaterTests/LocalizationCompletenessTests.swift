import Testing
import Foundation
@testable import MacUpdaterCore

/// Guards the runtime localization system: every Polish base string passed to `tr(...)`
/// or `trf(...)` in the UI must have an English counterpart in `Translations.en`.
///
/// The custom `tr()` mechanism falls back to the Polish text when a key is missing, so a
/// forgotten translation is otherwise an *invisible* defect — the English UI silently
/// shows Polish. This test turns that into a build failure: it scans the app sources for
/// every `tr("…")` / `trf("…")` literal and asserts each key is translated.
@Suite("LocalizationCompleteness")
struct LocalizationCompletenessTests {

    /// Keys that reach `tr(...)` dynamically (not as a literal) and so can't be found by
    /// the source scan. `InventoryView` calls `tr(opt.rawValue)` over `SourceFilter`,
    /// whose raw values are these Polish strings. Keep in sync with that enum.
    private static let dynamicKeys: Set<String> = ["Wszystkie", "Brew", "App Store", "Ręcznie"]

    private func packageRoot(file: String = #filePath) -> URL {
        // <root>/Tests/MacUpdaterTests/<thisFile>.swift → up 3 = <root>
        URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// Unescape a Swift string literal body so it matches the real dictionary key,
    /// including `\u{XXXX}` unicode escapes (used e.g. for the Polish „ " quotes).
    private func unescape(_ raw: String) -> String {
        let chars = Array(raw)
        var out = ""
        var i = 0
        while i < chars.count {
            let ch = chars[i]; i += 1
            guard ch == "\\", i < chars.count else { out.append(ch); continue }
            let esc = chars[i]; i += 1
            switch esc {
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "\"": out.append("\"")
            case "\\": out.append("\\")
            case "u" where i < chars.count && chars[i] == "{":
                i += 1   // consume "{"
                var hex = ""
                while i < chars.count, chars[i] != "}" { hex.append(chars[i]); i += 1 }
                if i < chars.count { i += 1 }   // consume "}"
                if let value = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(value) {
                    out.append(Character(scalar))
                }
            default: out.append(esc)   // unknown escape: keep the char
            }
        }
        return out
    }

    private func usedKeys() throws -> Set<String> {
        let appSources = packageRoot().appendingPathComponent("Sources/MacUpdater")
        let files = try FileManager.default
            .contentsOfDirectory(at: appSources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }

        // `tr(` or `trf(`, optional whitespace, then a single-line "double-quoted" literal
        // whose body may contain escaped characters. Newlines are excluded from the body so
        // the match can't run across statements into the next string literal.
        let regex = try NSRegularExpression(pattern: #"\b(?:tr|trf)\(\s*"((?:\\.|[^"\\\n])*)""#)

        var keys = Set<String>()
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: range) {
                guard let r = Range(match.range(at: 1), in: text) else { continue }
                keys.insert(unescape(String(text[r])))
            }
        }
        return keys
    }

    @Test func everyUIKeyHasEnglishTranslation() throws {
        let used = try usedKeys().union(Self.dynamicKeys)
        #expect(used.count > 100, "Sanity: the scan should find the bulk of the UI strings")

        let translated = Set(Translations.en.keys)
        let missing = used.subtracting(translated).sorted()

        let report = "Missing English translations for \(missing.count) key(s):\n"
            + missing.map { "  • \($0)" }.joined(separator: "\n")
        #expect(missing.isEmpty, "\(report)")
    }
}
