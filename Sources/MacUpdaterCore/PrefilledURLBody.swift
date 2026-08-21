import Foundation

/// Kodowanie i przycinanie treści wstawianej do prefillowanego URL-a — wspólne dla
/// zgłoszenia do katalogu (``CatalogIssueBuilder``) i zgłoszenia błędu (``BugReportBuilder``).
///
/// Wydzielone, bo obie ścieżki muszą przycinać *dokładnie tak samo*: granica na całym
/// znaku, nigdy w środku trypletu `%XX`. Dwie kopie tej logiki to dwie okazje, żeby jedna
/// z nich zaczęła produkować URL-e, których odbiorca nie zdekoduje.
public enum PrefilledURLBody {

    /// RFC 3986 unreserved characters only, so nothing that could break out of a query value
    /// (spaces, `&`, `#`, `+`, `/`, `?`, `:` …) survives unescaped.
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    public static func percentEncoded(_ string: String) -> String {
        string.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    /// Returns the percent-encoded form of the longest whole-character prefix of `raw` whose
    /// encoding fits `limit`. Because encoded length grows monotonically with the prefix
    /// length, the boundary is found with a binary search — and cutting on `Character`
    /// boundaries guarantees a `%XX` triplet is never split.
    public static func truncatedEncoded(_ raw: String, toEncodedLength limit: Int) -> String {
        percentEncoded(truncated(raw, toEncodedLength: limit))
    }

    /// The same boundary as ``truncatedEncoded(_:toEncodedLength:)``, returned unencoded —
    /// for callers that keep composing readable text and only encode it at the very end.
    public static func truncated(_ raw: String, toEncodedLength limit: Int) -> String {
        let chars = Array(raw)
        var low = 0
        var high = chars.count
        var best = 0
        while low <= high {
            let mid = (low + high) / 2
            if percentEncoded(String(chars[0..<mid])).count <= limit {
                best = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return String(chars[0..<best])
    }
}
