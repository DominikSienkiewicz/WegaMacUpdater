import Foundation

/// Turns vendor release-note HTML into text Wega is willing to render (F1).
///
/// The input comes from Sparkle appcasts and the JetBrains API — written by whoever ships
/// the app, fetched over the network, and displayed inside our window. That makes it
/// untrusted. This does not "sanitize HTML" in the sense of keeping safe tags: it keeps no
/// tags at all. `<script>` and `<style>` bodies are dropped whole, because stripping only
/// their tags would leave their contents on screen as text.
///
/// Deliberately hand-rolled rather than `NSAttributedString(html:)`: that initialiser runs
/// WebKit, must be called on the main thread, and will happily fetch remote subresources.
public enum ReleaseNotesText {
    /// Elements whose *contents* are not text and must not survive.
    private static let strippedElements = ["script", "style", "head"]

    /// Tags that end a line rather than a word.
    private static let breakingTags = ["br", "br/", "br /", "/p", "/li", "/div", "/h1", "/h2", "/h3", "/tr"]

    public static func plain(fromHTML html: String) -> String {
        var text = html
        for element in strippedElements {
            text = removingElement(element, from: text)
        }
        text = replacingBreakingTags(in: text)
        text = removingRemainingTags(from: text)
        text = decodingEntities(in: text)
        return collapsingWhitespace(in: text)
    }

    /// Drops `<tag …> … </tag>` including everything between. An unclosed opening tag drops
    /// to the end of the string — the conservative reading for `<script>` with no `</script>`.
    private static func removingElement(_ element: String, from html: String) -> String {
        var result = ""
        var rest = Substring(html)
        while let open = rest.range(of: "<\(element)", options: [.caseInsensitive]) {
            result += rest[rest.startIndex..<open.lowerBound]
            let after = rest[open.lowerBound...]
            guard let close = after.range(of: "</\(element)>", options: [.caseInsensitive]) else {
                return result
            }
            rest = after[close.upperBound...]
        }
        return result + rest
    }

    private static func replacingBreakingTags(in html: String) -> String {
        var text = html
        for tag in breakingTags {
            text = text.replacingOccurrences(
                of: "<\(tag)>", with: "\n", options: [.caseInsensitive]
            )
        }
        return text
    }

    private static func removingRemainingTags(from html: String) -> String {
        var result = ""
        var insideTag = false
        for character in html {
            if character == "<" {
                insideTag = true
            } else if character == ">" {
                insideTag = false
            } else if !insideTag {
                result.append(character)
            }
        }
        return result
    }

    /// `&amp;` last: decoding it first would let `&amp;lt;` turn into `<`.
    private static func decodingEntities(in text: String) -> String {
        var result = text
        for (entity, character) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
                                    ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " ")] {
            result = result.replacingOccurrences(of: entity, with: character, options: [.caseInsensitive])
        }
        return result.replacingOccurrences(of: "&amp;", with: "&", options: [.caseInsensitive])
    }

    /// Collapses runs of spaces and tabs, drops blank lines, trims the result.
    private static func collapsingWhitespace(in text: String) -> String {
        text
            .components(separatedBy: .newlines)
            .map { line in
                line.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
