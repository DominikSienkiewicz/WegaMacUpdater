import Foundation
import Testing
import WegaHelperKit

/// `WegaPrivilegedHelper` runs only as root and no test target compiles it, so its idle exit is pinned
/// on source (Aneks E.7, E.9 Z5 and Z6): one shared monitor armed before the listener takes
/// connections, every connection and every method counted, the background installation counted until
/// its staging is cleaned up, and the exit logged where `log show` finds it.
@Suite("Helper idle exit: daemon wiring")
struct HelperIdleSourceTests {

    @Test func oneMonitorIsArmedBeforeTheListenerTakesConnections() throws {
        let main = try source(Self.mainPath)
        let start = try #require(main.range(of: "HelperIdle.monitor.start()"), "the monitor must be armed")
        let resume = try #require(main.range(of: "listener.resume()"))
        let dispatch = try #require(main.range(of: "dispatchMain()"))
        #expect(start.upperBound <= resume.lowerBound, "armed before the first connection can arrive")
        #expect(resume.upperBound <= dispatch.lowerBound)
        #expect(main.filter { !$0.isWhitespace }
            .contains("staticletmonitor=HelperIdleMonitor(schedule:HelperIdleMonitor.scheduleOnGlobalQueue,exit:{"))
        for (name, text) in try swiftSources(under: "Sources/WegaPrivilegedHelper") {
            let made = text.components(separatedBy: "HelperIdleMonitor(").count - 1
            #expect(made == (name == Self.mainPath ? 1 : 0), "one shared monitor, made in main.swift: \(name)")
        }
    }

    /// Z6: `.info` is not persisted, so the exit is logged at `.notice`, and it carries nothing else.
    @Test func theIdleExitIsLoggedAtNoticeAndEndsTheProcessCleanly() throws {
        let main = try source(Self.mainPath)
        let monitor = try #require(main.range(of: "HelperIdleMonitor("))
        let notice = try #require(main.range(of: "logger.notice(\"Pomocnik kończy pracę po bezczynności\")"))
        let exit = try #require(main.range(of: "exit(EXIT_SUCCESS)"))
        #expect(monitor.upperBound <= notice.lowerBound)
        #expect(notice.upperBound <= exit.lowerBound, "logged before the process ends")
        #expect(!main.contains("logger.info("))
        #expect(main.components(separatedBy: "logger.").count - 1 == 1, "the exit is the only line main.swift logs")
    }

    /// E.4 and Z5: a connection counts from before it resumes until it is invalidated, and only one
    /// the delegate accepts.
    @Test func everyAcceptedConnectionCountsFromBeforeItResumesUntilItIsInvalidated() throws {
        let body = try methodBody("shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool", in: try source(Self.delegatePath))
        let ordered = [
            "guard WegaHelper.isTeamIDConfigured else {",
            "let connection = HelperIdle.monitor.begin()",
            "newConnection.invalidationHandler = { connection.end() }",
            "newConnection.resume()",
        ]
        var previous = body.startIndex
        for step in ordered {
            let found = try #require(body.range(of: step), "missing: \(step)")
            #expect(found.lowerBound >= previous, "\(step) runs out of order")
            previous = found.upperBound
        }
        #expect(body.components(separatedBy: "HelperIdle.monitor.begin()").count - 1 == 1)
    }

    /// Z5: a client may drop its connection at its own deadline while the work goes on (up to 600 s
    /// for a bundle or the Trash), so every operation counts for its whole body.
    @Test func everyOperationCountsForItsWholeBody() throws {
        let helper = try source(Self.delegatePath)
        let operations = try operationNames()
        #expect(operations.count == WegaHelperVerb.allCases.count + 1, "the verbs and the version probe")
        for operation in operations {
            let body = try methodBody("func \(operation)(", in: helper).filter { !$0.isWhitespace }
            #expect(body.hasPrefix("{letactivity=HelperIdle.monitor.begin()defer{activity.end()}"), "\(operation)")
        }
    }

    /// Review focus 1 and Z5: the installation counts from before it leaves for the worker queue until
    /// `installVerifiedPackage` has returned, i.e. after its staging cleanup and its record, so an exit
    /// can never turn the record into `unknown`.
    @Test func anInstallationCountsUntilItsStagingIsCleanedUp() throws {
        let helper = try source(Self.delegatePath)
        let begin = try methodBody("func beginPackageInstallation(", in: helper).filter { !$0.isWhitespace }
        #expect(begin.contains(
            "ifshouldStart{letinstallation=HelperIdle.monitor.begin()DispatchQueue.global(qos:.utility).async{"
                + "defer{installation.end()}self.installVerifiedPackage("))
        #expect(helper.components(separatedBy: "installation.end()").count - 1 == 1, "ended once, in the worker's defer")
        let install = try methodBody("private func installVerifiedPackage(", in: helper)
        #expect(install.contains("defer { try? FileManager.default.removeItem(at: staged.deletingLastPathComponent()) }"),
                "the staging is cleaned up before installVerifiedPackage returns")
    }

    // MARK: - Source access

    private static let mainPath = "Sources/WegaPrivilegedHelper/main.swift"
    private static let delegatePath = "Sources/WegaPrivilegedHelper/HelperDelegate.swift"

    /// The method names of `WegaPrivilegedOps`, read from its declaration.
    private func operationNames() throws -> [String] {
        let declaration = try methodBody(
            "@objc public protocol WegaPrivilegedOps", in: try source("Sources/WegaHelperKit/WegaHelperProtocol.swift")
        )
        return declaration.components(separatedBy: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("func ") else { return nil }
            return String(trimmed.dropFirst("func ".count).prefix { $0 != "(" })
        }
    }

    private func packageRoot(file: String = #filePath) -> URL {
        URL(fileURLWithPath: file).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: packageRoot().appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func swiftSources(under relativePath: String) throws -> [(name: String, text: String)] {
        let directory = packageRoot().appendingPathComponent(relativePath)
        return try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".swift") }
            .map { ("\(relativePath)/\($0)", try String(contentsOf: directory.appendingPathComponent($0), encoding: .utf8)) }
    }

    /// From `signature` to the brace that closes the body it opens.
    private func methodBody(_ signature: String, in text: String) throws -> String {
        let start = try #require(text.range(of: signature), "\(signature) must exist")
        let opening = try #require(text[start.upperBound...].firstIndex(of: "{"))
        var depth = 0
        var index = opening
        while index < text.endIndex {
            if text[index] == "{" { depth += 1 }
            if text[index] == "}" {
                depth -= 1
                if depth == 0 { return String(text[opening...index]) }
            }
            index = text.index(after: index)
        }
        Issue.record("\(signature) is not closed")
        return ""
    }
}
