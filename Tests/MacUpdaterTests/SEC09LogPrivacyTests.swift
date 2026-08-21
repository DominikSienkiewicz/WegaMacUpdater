import XCTest
@testable import MacUpdaterCore

/// SEC-09 — the unified log must not leak the user's app profile, and the on-disk
/// log/snapshot must be readable only by their owner.
///
/// Three seams are pinned here:
///   * `LogRedaction` strips filesystem paths and URL query strings out of a message
///     *before it reaches OSLog* (the channel any process can read).
///   * `LogStore` / `FileScanSnapshotIO` create their directories `0700` and their
///     files `0600`, explicitly, rather than at the mercy of the process `umask`.
///   * `LogStore` signals a failed file write instead of swallowing it.
///
/// Per-field OSLog privacy (`.private` for the user-data message) cannot be observed
/// from a unit test — OSLog output is not introspectable — so it is pinned by source
/// inspection, the same technique `ObservabilityLoggingTests` uses for the app wiring.
final class SEC09LogPrivacyTests: XCTestCase {

    // MARK: - Redaction (criterion 1 & 5)

    func testRedactsAbsoluteFilesystemPath() {
        let out = LogRedaction.redact("Skanuję /Users/alice/Applications/Foo.app teraz")
        XCTAssertFalse(out.contains("alice"), out)
        XCTAssertFalse(out.contains("/Users/"), out)
        XCTAssertTrue(out.contains("[path]"), out)
        XCTAssertTrue(out.contains("Skanuję"), "non-sensitive text must survive: \(out)")
        XCTAssertTrue(out.contains("teraz"), out)
    }

    func testRedactsFileURL() {
        let out = LogRedaction.redact("Zapis do file:///Users/bob/Library/Logs/wega.log nieudany")
        XCTAssertFalse(out.contains("bob"), out)
        XCTAssertFalse(out.contains("Library/Logs"), out)
        XCTAssertTrue(out.contains("[path]"), out)
        XCTAssertTrue(out.contains("nieudany"), out)
    }

    func testRedactsURLQueryString() {
        let out = LogRedaction.redact("GET https://example.com/api/update?token=secret&v=2 done")
        XCTAssertFalse(out.contains("token=secret"), out)
        XCTAssertFalse(out.contains("secret"), out)
        XCTAssertTrue(out.contains("[query]"), out)
        XCTAssertTrue(out.contains("done"), out)
    }

    func testLeavesOrdinaryMessageUnchanged() {
        let message = "GitHub · TestApp: błąd odpowiedzi lub parsowania"
        XCTAssertEqual(LogRedaction.redact(message), message)
    }

    // MARK: - Per-field OSLog privacy (criterion 2 & 5, source inspection)

    private func packageRoot(file: String = #filePath) -> URL {
        URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: packageRoot().appendingPathComponent(relativePath), encoding: .utf8)
    }

    func testWegaLogMarksTheMessageFieldPrivateAndRedactsIt() throws {
        let src = try source("Sources/MacUpdaterCore/WegaLog.swift")
        XCTAssertTrue(src.contains("privacy: .private"),
                      "SEC-09: the user-data message must be logged privacy: .private")
        XCTAssertFalse(src.contains("message, privacy: .public"),
                       "SEC-09: the raw message must no longer be logged privacy: .public")
        XCTAssertTrue(src.contains("LogRedaction.redact"),
                      "SEC-09: the message must be redacted before it reaches OSLog")
    }

    // MARK: - Explicit file permissions (criterion 3)

    private func mode(of url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    @MainActor
    func testLogDirectoryAndFileAreOwnerOnly() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wega-sec09-log-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = LogStore(directory: dir, memoryCap: 5, fileMaxBytes: 4096, loadTailLines: 100)
        store.append(LogEntry(date: Date(), level: .info, category: .app, message: "perm check"))
        store.flushForTests()

        XCTAssertEqual(try mode(of: dir), 0o700, "log directory must be 0700")
        XCTAssertEqual(try mode(of: store.logFileURL), 0o600, "log file must be 0600")
    }

    func testSnapshotDirectoryAndFileAreOwnerOnly() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wega-sec09-snap-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("WegaMacUpdater", isDirectory: true)
            .appendingPathComponent("last-scan.json")

        try FileScanSnapshotIO(fileURL: fileURL).write(Data("{}".utf8))

        XCTAssertEqual(try mode(of: fileURL.deletingLastPathComponent()), 0o700,
                       "snapshot directory must be 0700")
        XCTAssertEqual(try mode(of: fileURL), 0o600, "snapshot file must be 0600")
    }

    // MARK: - Logger write-failure signalling (criterion 4)

    @MainActor
    func testHealthyStoreReportsNoWriteFailure() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wega-sec09-ok-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = LogStore(directory: dir, memoryCap: 5, fileMaxBytes: 4096, loadTailLines: 100)
        store.append(LogEntry(date: Date(), level: .info, category: .app, message: "ok"))
        store.flushForTests()

        XCTAssertEqual(store.writeFailureCount, 0)
        XCTAssertNil(store.lastWriteError)
    }

    @MainActor
    func testWriteFailureIsSignalledNotSwallowed() throws {
        // A regular file where the log store expects a parent directory: creating the
        // store's directory underneath it must fail, and that failure must surface.
        let blocker = FileManager.default.temporaryDirectory
            .appendingPathComponent("wega-sec09-blocker-\(UUID().uuidString)")
        XCTAssertTrue(FileManager.default.createFile(atPath: blocker.path, contents: Data("x".utf8)))
        defer { try? FileManager.default.removeItem(at: blocker) }

        let store = LogStore(directory: blocker.appendingPathComponent("Logs", isDirectory: true),
                             memoryCap: 5, fileMaxBytes: 4096, loadTailLines: 100)
        store.append(LogEntry(date: Date(), level: .error, category: .app, message: "boom"))
        store.flushForTests()

        XCTAssertGreaterThan(store.writeFailureCount, 0,
                             "SEC-09: a failed log write must be signalled, not ignored")
        XCTAssertNotNil(store.lastWriteError)
    }

    // MARK: - Every rule but the PEM block is bounded to a single line (criterion 1 & 5)

    /// `DiagnosticsBundle` hands a whole log file to the redactor in ONE call so the
    /// multi-line `pemBlock` rule can fire at all. That is only safe while every *other*
    /// rule stops at a newline. `labelledSecret`'s quoted branch did not: a
    /// `password: "hunter2` whose closing quote never arrives on that line matched forward
    /// to the next `"` anywhere in the file, replacing every entry in between with a single
    /// `[secret]`.
    func testAnUnbalancedQuoteAfterASecretLabelCannotSwallowLaterEntries() {
        let text = """
        2026-08-20T10:00:00Z [ERROR] [Brew] password: "hunter2
        2026-08-20T10:00:01Z [INFO] [App] Sprawdzam aktualizacje
        2026-08-20T10:00:02Z [INFO] [App] Znaleziono 3 aktualizacje
        2026-08-20T10:00:03Z [ERROR] [Brew] Error: Cask "foo" is not installed
        """

        let out = LogRedaction.redact(text)

        XCTAssertFalse(out.contains("hunter2"), "the labelled value must still go: \(out)")
        XCTAssertTrue(out.contains("2026-08-20T10:00:01Z [INFO] [App] Sprawdzam aktualizacje"), out)
        XCTAssertTrue(out.contains("2026-08-20T10:00:02Z [INFO] [App] Znaleziono 3 aktualizacje"), out)
        XCTAssertTrue(out.contains(#"Error: Cask "foo" is not installed"#), out)
        XCTAssertEqual(out.components(separatedBy: "\n").count, 4,
                       "no entry may be absorbed into another: \(out)")
    }

    /// The apostrophe branch has exactly the same reach — and Homebrew hands us unbalanced
    /// apostrophes routinely (`Error: Cask 'foo' is not installed`), so this is the shape
    /// the over-match actually fires on in the field.
    func testAnUnbalancedApostropheAfterASecretLabelCannotSwallowLaterEntries() {
        let text = """
        2026-08-20T10:00:00Z [ERROR] [Brew] password: 'hunter2
        2026-08-20T10:00:01Z [INFO] [App] Sprawdzam aktualizacje
        2026-08-20T10:00:02Z [ERROR] [Brew] Error: Cask 'foo' is not installed
        """

        let out = LogRedaction.redact(text)

        XCTAssertFalse(out.contains("hunter2"), out)
        XCTAssertTrue(out.contains("2026-08-20T10:00:01Z [INFO] [App] Sprawdzam aktualizacje"), out)
        XCTAssertTrue(out.contains("Error: Cask 'foo' is not installed"), out)
        XCTAssertEqual(out.components(separatedBy: "\n").count, 3,
                       "no entry may be absorbed into another: \(out)")
    }

    /// A line ending on the header name alone — value logged separately, or the line
    /// truncated — let the separator's `\s*` cross the newline so `\S+` ate the *next*
    /// entry's timestamp and welded the two entries together.
    func testAnAuthorizationHeaderAtALineEndCannotSwallowTheNextEntry() {
        let text = """
        2026-08-20T10:00:00Z [DEBUG] [Network] nagłówki żądania: Authorization:
        2026-08-20T10:00:01Z [INFO] [App] Sprawdzam aktualizacje
        """

        let out = LogRedaction.redact(text)

        XCTAssertTrue(out.contains("2026-08-20T10:00:01Z [INFO] [App] Sprawdzam aktualizacje"), out)
        XCTAssertEqual(out.components(separatedBy: "\n").count, 2,
                       "no entry may be absorbed into another: \(out)")
    }

    /// Same shape for the bare `bearer` rule: its `\s+` crossed the newline and the token
    /// class then happily consumed the next entry's `2026-08-20T10`.
    func testABearerLabelAtALineEndCannotSwallowTheNextEntry() {
        let text = """
        2026-08-20T10:00:00Z [DEBUG] [Network] schemat uwierzytelnienia: Bearer
        2026-08-20T10:00:01Z [INFO] [App] Sprawdzam aktualizacje
        """

        let out = LogRedaction.redact(text)

        XCTAssertTrue(out.contains("2026-08-20T10:00:01Z [INFO] [App] Sprawdzam aktualizacje"), out)
        XCTAssertEqual(out.components(separatedBy: "\n").count, 2,
                       "no entry may be absorbed into another: \(out)")
    }

    /// Bounding those three rules to a line must not narrow them *within* one: a genuine
    /// secret sitting on a single line is still removed, in every form each rule accepts.
    func testASameLineSecretIsStillRedactedByEachBoundedRule() {
        let quoted = LogRedaction.redact(#"password: "hunter2" zapisane"#)
        XCTAssertFalse(quoted.contains("hunter2"), quoted)
        XCTAssertTrue(quoted.contains("password"), "the label stays, so the line says what went: \(quoted)")
        XCTAssertTrue(quoted.contains("[secret]"), quoted)
        XCTAssertTrue(quoted.contains("zapisane"), "text after the value must survive: \(quoted)")

        let apostrophed = LogRedaction.redact(#"api_key = 'ala ma kota' ok"#)
        XCTAssertFalse(apostrophed.contains("ala ma kota"), apostrophed)
        XCTAssertTrue(apostrophed.contains("[secret]"), apostrophed)

        let bare = LogRedaction.redact("client_secret=s3cr3t-value dalej")
        XCTAssertFalse(bare.contains("s3cr3t-value"), bare)
        XCTAssertTrue(bare.contains("dalej"), bare)

        let header = LogRedaction.redact("Authorization: Basic YWxpY2phOnNlY3JldA==")
        XCTAssertFalse(header.contains("YWxpY2phOnNlY3JldA=="), header)
        XCTAssertTrue(header.contains("[secret]"), header)

        let spacedHeader = LogRedaction.redact("proxy-authorization\t=\tBearer abcdef1234567890 koniec")
        XCTAssertFalse(spacedHeader.contains("abcdef1234567890"), spacedHeader)
        XCTAssertTrue(spacedHeader.contains("koniec"), spacedHeader)

        let bearer = LogRedaction.redact("curl -H Bearer abcdef1234567890 done")
        XCTAssertFalse(bearer.contains("abcdef1234567890"), bearer)
        XCTAssertTrue(bearer.contains("done"), bearer)
    }
}
