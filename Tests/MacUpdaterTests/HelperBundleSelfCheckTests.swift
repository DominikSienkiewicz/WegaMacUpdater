import Darwin
import Foundation
import Testing
import WegaHelperKit

/// Z14, defense in depth (design §5, review R5): launchd finds the helper's bundle by identifier, so
/// the helper may run from a copy the app never checked. From protocol 9 the helper checks the bundle
/// it was started from once, before its listener resumes, and refuses every connection when that
/// bundle fails the gate — before a connection counts as activity, so the idle exit still ends it.
/// `WegaPrivilegedHelper` runs only as root and no test target compiles it, so its wiring is pinned
/// on source; the decision it calls lives in `WegaHelperKit`, where it runs here.
@Suite("Helper bundle self-check")
struct HelperBundleSelfCheckTests {

    // MARK: - The decision the helper calls

    @Test func theRunningProcessKnowsItsOwnExecutable() throws {
        let path = try #require(HelperBundleGate.executablePathOfThisProcess())
        #expect(path.hasPrefix("/"))
        #expect(FileManager.default.isExecutableFile(atPath: path))
    }

    /// The test runner is no helper inside a bundle, so it cannot establish where it runs from.
    @Test func anExecutableOutsideABundlesMacOSFolderIsRefused() throws {
        let path = try #require(HelperBundleGate.executablePathOfThisProcess())
        #expect(HelperBundleGate.trust(ofHelperExecutable: path) == .refused(.unreadable(.helperExecutable)))
        #expect(HelperBundleGate.trust(ofHelperExecutable: "") == .refused(.unreadable(.helperExecutable)))
    }

    @Test func aHelperOutsideApplicationsIsRefusedByLocation() {
        let path = "/Users/someone/Downloads/WegaMacUpdater.app/Contents/MacOS/WegaPrivilegedHelper"
        #expect(HelperBundleGate.trust(ofHelperExecutable: path) == .refused(.notInApplications))
    }

    /// The log line and the diagnostics carry a stable English token: the refusal and the entry
    /// under the bundle, never a path.
    @Test func everyRefusalHasAStableTokenWithoutAPath() {
        #expect(HelperBundleRefusal.notInApplications.token == "notInApplications")
        #expect(HelperBundleRefusal.notOwnedByRoot(.bundle).token == "notOwnedByRoot(bundle)")
        #expect(HelperBundleRefusal.unreadable(.helperExecutable).token == "unreadable(Contents/MacOS/WegaPrivilegedHelper)")
        #expect(HelperBundleRefusal.symbolicLink(.contents).token == "symbolicLink(Contents)")
        #expect(HelperBundleRefusal.unexpectedKind(.library).token == "unexpectedKind(Contents/Library)")
        #expect(HelperBundleRefusal.writableByGroupOrOthers(.macOS).token == "writableByGroupOrOthers(Contents/MacOS)")
        #expect(HelperBundleRefusal.accessControlList(.launchDaemons).token == "accessControlList(Contents/Library/LaunchDaemons)")
        #expect(HelperBundleTrust.trusted.token == "trusted")
        #expect(HelperBundleTrust.refused(.notInApplications).token == "notInApplications")
    }

    // MARK: - The helper's wiring

    @Test func theTrustIsDecidedOnceBeforeTheListenerResumes() throws {
        let main = try source(Self.mainPath)
        let decided = try #require(
            main.range(of: "let delegate = HelperListenerDelegate(bundleTrust: HelperBundleGate.trustOfThisHelper())"),
            "the delegate gets the bundle's trust, read once at start"
        )
        let resume = try #require(main.range(of: "listener.resume()"))
        #expect(decided.upperBound <= resume.lowerBound)
        #expect(main.components(separatedBy: "trustOfThisHelper()").count - 1 == 1)
    }

    @Test func theDelegateKeepsTheTrustImmutable() throws {
        let delegate = try source(Self.delegatePath)
        #expect(delegate.contains("private let bundleTrust: HelperBundleTrust"))
        #expect(!delegate.contains("var bundleTrust"))
        #expect(!delegate.contains("HelperBundleGate.live("), "the delegate never reads the bundle again per connection")
    }

    /// Refused after the Team ID check and before the connection counts, is configured or resumes;
    /// the refusal is logged with its token and nothing ends the process early.
    @Test func aRefusedBundleRefusesEveryConnectionBeforeItCounts() throws {
        let body = try methodBody("shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool", in: try source(Self.delegatePath))
        let ordered = [
            "guard WegaHelper.isTeamIDConfigured else {",
            "guard case .trusted = bundleTrust else {",
            "privacy: .public",
            "return false",
            "let connection = HelperIdle.monitor.begin()",
            "newConnection.setCodeSigningRequirement(",
            "newConnection.resume()",
        ]
        var previous = body.startIndex
        for step in ordered {
            let found = try #require(body[previous...].range(of: step), "missing or out of order: \(step)")
            previous = found.upperBound
        }
        let refusal = try #require(body.range(of: "guard case .trusted = bundleTrust else {"))
        let refusalBlock = body[refusal.upperBound...].prefix { $0 != "}" }
        #expect(refusalBlock.contains("bundleTrust.token"))
        #expect(!body.contains("exit("), "a refusing helper ends through its idle exit, never early")
    }

    // MARK: - Source access

    private static let mainPath = "Sources/WegaPrivilegedHelper/main.swift"
    private static let delegatePath = "Sources/WegaPrivilegedHelper/HelperDelegate.swift"

    private func packageRoot(file: String = #filePath) -> URL {
        URL(fileURLWithPath: file).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: packageRoot().appendingPathComponent(relativePath), encoding: .utf8)
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
        throw POSIXError(.EINVAL)
    }
}
