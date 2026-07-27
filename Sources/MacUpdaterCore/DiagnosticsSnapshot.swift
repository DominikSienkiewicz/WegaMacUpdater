import Foundation

/// OBS-02 — everything a diagnostics bundle reports on, gathered into one value.
///
/// A plain struct with no behaviour and no live dependencies: the app target reads the
/// running system into it, and the whole bundle — text, redaction, archive bytes — is then
/// produced from this value alone. That is what makes "the exported package contains X"
/// and "the exported package does not leak Y" testable claims rather than claims about a
/// SwiftUI view running on somebody's Mac.
public struct DiagnosticsSnapshot: Sendable {

    /// A package manager Wega knows how to drive.
    public struct Manager: Sendable, Equatable {
        public let name: String
        /// `nil` when the tool was not found on this machine.
        public let version: String?
        public let detected: Bool

        public init(name: String, version: String?, detected: Bool) {
            self.name = name
            self.version = version
            self.detected = detected
        }
    }

    /// The privileged helper: whether it is registered, and which protocol version it
    /// answers with versus the one this build expects.
    public struct Helper: Sendable, Equatable {
        public let status: String
        public let expectedVersion: String
        public let reportedVersion: String?
        public let teamIDConfigured: Bool

        public init(status: String, expectedVersion: String, reportedVersion: String?, teamIDConfigured: Bool) {
            self.status = status
            self.expectedVersion = expectedVersion
            self.reportedVersion = reportedVersion
            self.teamIDConfigured = teamIDConfigured
        }
    }

    /// Automatic checking and unattended updates, as configured right now.
    public struct Schedule: Sendable, Equatable {
        public let interval: String
        public let lastCheck: Date?
        public let nextCheck: Date?
        public let lastCheckFailed: Bool
        public let launchAtLogin: Bool
        public let backgroundUpdatesEnabled: Bool

        public init(
            interval: String,
            lastCheck: Date?,
            nextCheck: Date?,
            lastCheckFailed: Bool,
            launchAtLogin: Bool,
            backgroundUpdatesEnabled: Bool
        ) {
            self.interval = interval
            self.lastCheck = lastCheck
            self.nextCheck = nextCheck
            self.lastCheckFailed = lastCheckFailed
            self.launchAtLogin = launchAtLogin
            self.backgroundUpdatesEnabled = backgroundUpdatesEnabled
        }
    }

    /// What the last scan concluded for one source.
    public struct SourceResult: Sendable, Equatable {
        public let source: String
        public let outcome: String
        public let error: String?

        public init(source: String, outcome: String, error: String?) {
            self.source = source
            self.outcome = outcome
            self.error = error
        }
    }

    /// The signature verdict for one app, by name — never by path.
    public struct SignatureRecord: Sendable, Equatable {
        public let subject: String
        public let verdict: String

        public init(subject: String, verdict: String) {
            self.subject = subject
            self.verdict = verdict
        }
    }

    /// One log file as read from disk, verbatim. It is redacted on the way into the
    /// archive, not here — the snapshot carries what was found, the bundle decides what
    /// may leave.
    public struct LogFile: Sendable, Equatable {
        public let name: String
        public let contents: String

        public init(name: String, contents: String) {
            self.name = name
            self.contents = contents
        }
    }

    public let generatedAt: Date
    public let appVersion: String
    public let appBuild: String
    public let bundleIdentifier: String
    public let osVersion: String
    public let architecture: String
    public let processorCount: Int
    public let managers: [Manager]
    public let helper: Helper
    public let schedule: Schedule
    public let lastScanAt: Date?
    public let lastScanComplete: Bool
    public let sourceResults: [SourceResult]
    public let freeDiskBytes: Int64?
    public let signatures: [SignatureRecord]
    public let appManagementPermission: String
    public let history: [UpdateJournalEntry]
    public let logFiles: [LogFile]
    public let logWriteFailureCount: Int

    public init(
        generatedAt: Date,
        appVersion: String,
        appBuild: String,
        bundleIdentifier: String,
        osVersion: String,
        architecture: String,
        processorCount: Int,
        managers: [Manager],
        helper: Helper,
        schedule: Schedule,
        lastScanAt: Date?,
        lastScanComplete: Bool,
        sourceResults: [SourceResult],
        freeDiskBytes: Int64?,
        signatures: [SignatureRecord],
        appManagementPermission: String,
        history: [UpdateJournalEntry],
        logFiles: [LogFile],
        logWriteFailureCount: Int
    ) {
        self.generatedAt = generatedAt
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.bundleIdentifier = bundleIdentifier
        self.osVersion = osVersion
        self.architecture = architecture
        self.processorCount = processorCount
        self.managers = managers
        self.helper = helper
        self.schedule = schedule
        self.lastScanAt = lastScanAt
        self.lastScanComplete = lastScanComplete
        self.sourceResults = sourceResults
        self.freeDiskBytes = freeDiskBytes
        self.signatures = signatures
        self.appManagementPermission = appManagementPermission
        self.history = history
        self.logFiles = logFiles
        self.logWriteFailureCount = logWriteFailureCount
    }
}
