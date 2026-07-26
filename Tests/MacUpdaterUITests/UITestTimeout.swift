import Foundation

/// Wall-clock limit for UI tests that spawn the real `WegaMacUpdater` executable.
///
/// The limit defaults to ten seconds — the value the layout regression was originally pinned to —
/// but is read from the `WEGA_UI_TEST_TIMEOUT` environment variable when set, so a slower or
/// heavily loaded machine (or CI) can raise it without editing the test (QA-10c). A missing,
/// empty, non-numeric or non-positive override is ignored and the default is used.
enum UITestTimeout {
    /// Environment variable that overrides the default spawn timeout, in seconds.
    static let environmentKey = "WEGA_UI_TEST_TIMEOUT"

    /// Fallback used whenever the environment does not carry a valid override.
    static let `default`: TimeInterval = 10

    static func resolved(
        from environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> TimeInterval {
        guard let raw = environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let parsed = TimeInterval(raw),
              parsed > 0
        else {
            return UITestTimeout.default
        }
        return parsed
    }
}
