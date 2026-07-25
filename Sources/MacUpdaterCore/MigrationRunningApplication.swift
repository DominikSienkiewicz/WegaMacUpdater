import AppKit
import Foundation

public struct RunningApplicationTarget: Equatable, Sendable {
    public let processIdentifier: Int32
    public let bundleURL: URL?
    public let bundleIdentifier: String?
    public let appName: String
    public let processName: String

    public init(
        processIdentifier: Int32,
        bundleURL: URL?,
        bundleIdentifier: String?,
        appName: String,
        processName: String
    ) {
        self.processIdentifier = processIdentifier
        self.bundleURL = bundleURL
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.processName = processName
    }
}

public enum RunningApplicationResolution: Equatable, Sendable {
    case notRunning
    case running(RunningApplicationTarget)
    case ambiguousBundleIdentifier(String)
}

public enum MigrationRunningApplicationResolver {
    public static func resolve(
        app: ApplicationInfo,
        running: [RunningApplicationTarget]
    ) -> RunningApplicationResolution {
        let expectedURL = canonicalURL(app.path)
        let pathMatches = running.filter { target in
            target.bundleURL.map(canonicalURL) == expectedURL
        }
        if pathMatches.count == 1, let match = pathMatches.first {
            return .running(match)
        }
        if pathMatches.count > 1 {
            return .ambiguousBundleIdentifier(app.bundleIdentifier ?? app.id)
        }

        guard let bundleIdentifier = app.bundleIdentifier else { return .notRunning }
        let identifierMatches = running.filter { $0.bundleIdentifier == bundleIdentifier }
        if identifierMatches.count == 1, let match = identifierMatches.first {
            return .running(match)
        }
        if identifierMatches.count > 1 {
            return .ambiguousBundleIdentifier(bundleIdentifier)
        }
        return .notRunning
    }

    private static func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
}

public protocol RunningApplicationInspecting: Sendable {
    @MainActor
    func runningApplications() -> [RunningApplicationTarget]
}

public struct WorkspaceRunningApplicationInspector: RunningApplicationInspecting {
    public init() {}

    @MainActor
    public func runningApplications() -> [RunningApplicationTarget] {
        NSWorkspace.shared.runningApplications.map { application in
            let appName = application.localizedName
                ?? application.bundleURL?.deletingPathExtension().lastPathComponent
                ?? application.bundleIdentifier
                ?? "PID \(application.processIdentifier)"
            let processName = application.executableURL?.lastPathComponent ?? appName
            return RunningApplicationTarget(
                processIdentifier: application.processIdentifier,
                bundleURL: application.bundleURL,
                bundleIdentifier: application.bundleIdentifier,
                appName: appName,
                processName: processName
            )
        }
    }
}

public protocol RunningApplicationTargetTerminating: Sendable {
    @MainActor
    func requestGracefulTermination(_ target: RunningApplicationTarget) -> Bool
}

public struct WorkspaceTargetTerminator: RunningApplicationTargetTerminating {
    public init() {}

    @MainActor
    public func requestGracefulTermination(_ target: RunningApplicationTarget) -> Bool {
        let application = NSWorkspace.shared.runningApplications.first { application in
            guard application.processIdentifier == target.processIdentifier else { return false }
            if let expectedURL = target.bundleURL {
                return application.bundleURL?.standardizedFileURL.resolvingSymlinksInPath()
                    == expectedURL.standardizedFileURL.resolvingSymlinksInPath()
            }
            return application.bundleIdentifier == target.bundleIdentifier
        }
        return application?.terminate() ?? false
    }
}
