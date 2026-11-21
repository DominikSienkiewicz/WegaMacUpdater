import Foundation
import Testing

/// `WegaPrivilegedHelper` runs only as root and no test target compiles it, so its part of turning
/// Touch ID for `sudo` off is pinned on source: it gathers only what only root can know, holds the
/// PAM lock, replies once, and leaves every file to `WegaHelperKit`, where the tests reach it.
@Suite("Turning off Touch ID for sudo: source pins")
struct TouchIDSudoDisableSourceTests {

    @Test func theProtocolDeclaresTheVerb() throws {
        let protocolSource = try source("Sources/WegaHelperKit/WegaHelperProtocol.swift").filter { !$0.isWhitespace }
        #expect(protocolSource.contains("funcdisableTouchIDForSudo(withReplyreply:@escaping@Sendable(Int,String?)->Void)"))
    }

    @Test func theHelperGathersOnlyWhatOnlyRootKnowsAndRepliesOnce() throws {
        let helper = try source("Sources/WegaPrivilegedHelper/HelperDelegate.swift")
        let compact = helper.filter { !$0.isWhitespace }
        #expect(compact.contains("funcdisableTouchIDForSudo(withReplyreply:@escaping@Sendable(Int,String?)->Void){Self.pamLock.lock()"))
        #expect(compact.contains(
            "TouchIDSudoDisabler.runLive(caller:.init(uid:callerUID,consoleUserUID:Self.consoleUserUID(),"
                + "isAdministrator:AdministratorGroup.contains(uid:callerUID)))"))
        #expect(compact.contains("reply(report.result.wireCode,report.result.wireDetail)"))
        let body = try methodBody("func disableTouchIDForSudo(", in: helper)
        #expect(body.components(separatedBy: "reply(").count - 1 == 1, "the reply is sent exactly once")
        #expect(!helper.contains("SystemPaths.sudoLocal"), "only WegaHelperKit touches the file, where the tests see it")
        #expect(!helper.contains("pam_" + "start"), "the root helper never starts PAM")
    }

    @Test func enablingAndDisablingNeverInterleave() throws {
        let helper = try source("Sources/WegaPrivilegedHelper/HelperDelegate.swift")
        #expect(helper.contains("private static let pamLock = NSLock()"))
        let enable = try #require(helper.range(of: "func enableTouchIDForSudo(")).upperBound
        #expect(helper[enable...].prefix(200).contains("Self.pamLock.lock()"))
        let body = try methodBody("func enableTouchIDForSudo(", in: helper)
        let lock = try #require(body.range(of: "Self.pamLock.lock()"))
        let write = try #require(body.range(of: "writeSudoLocalEnablingTouchID()"))
        #expect(lock.upperBound < write.lowerBound)
    }

    /// The log names the result, the step and our own paths, never a byte of the file or the caller.
    @Test func theHelperLogsTheOutcomeAndNothingFromTheFile() throws {
        let helper = try source("Sources/WegaPrivilegedHelper/HelperDelegate.swift")
        #expect(helper.contains("disableTouchIDForSudo: sukces, linie: \\(code, privacy: .public)"))
        #expect(helper.contains("disableTouchIDForSudo: błąd \\(code, privacy: .public) (etap: \\(step, privacy: .public))"))
        let logging = try methodBody("private static func logDisable(", in: helper)
        for leak in ["callerUID", "Data(", "String(decoding", "contents"] {
            #expect(!logging.contains(leak), "the disable log must not carry \(leak)")
        }
    }

    @Test func thePrimitivesSwapFlushAndFailClosedOnACLs() throws {
        let kit = try source("Sources/WegaHelperKit/PAMPolicyDirectory.swift")
        for marker in ["renameatx_np(", "RENAME_SWAP", "VOL_CAP_INT_RENAME_SWAP", "F_FULLFSYNC", "O_EXCL",
                       "O_NOFOLLOW_ANY", "AT_SYMLINK_NOFOLLOW", "O_NONBLOCK", "acl_get_fd_np", "ENOENT"] {
            #expect(kit.contains(marker), "missing from the policy directory: \(marker)")
        }
        let acl = try methodBody("static func accessControl(of descriptor:", in: kit)
        #expect(acl.contains("errno == ENOENT ? .absent : .unreadable"), "only a certain absence reads as no ACL (RC4)")
        #expect(!kit.contains("FileManager"), "every call goes through the verified directory descriptor")
    }

    /// The app, its core, the kit and the daemon never start PAM: loading the policy's modules as
    /// root would turn reading a file into running whatever it names.
    @Test func nothingEverStartsPAM() throws {
        for directory in ["Sources/MacUpdater", "Sources/MacUpdaterCore", "Sources/WegaHelperKit", "Sources/WegaPrivilegedHelper"] {
            for (name, text) in try swiftSources(under: directory) {
                #expect(!text.contains("pam_" + "start"), "\(name)")
            }
        }
    }

    /// Turning Touch ID off is reached in the app only through the Touch ID controller's live
    /// dependencies, so no other screen or service can send the verb.
    @Test func onlyTheTouchIDControllersLiveDependenciesTurnItOff() throws {
        let needle = "disableTouchIDForSudo()"
        for directory in ["Sources/MacUpdater", "Sources/MacUpdaterCore"] {
            for (name, text) in try swiftSources(under: directory) where text.contains(needle) {
                switch name {
                case "Sources/MacUpdaterCore/PrivilegedHelper/PrivilegedHelperClient.swift":
                    #expect(text.components(separatedBy: needle).count - 1 == 1, "only the definition")
                    #expect(text.contains("public func disableTouchIDForSudo() async throws"))
                case "Sources/MacUpdater/TouchIDSetupController.swift":
                    let live = try #require(text.range(of: "static let live = Dependencies(")).upperBound
                    let end = try #require(text[live...].range(of: "\n    )\n")).lowerBound
                    #expect(text.components(separatedBy: needle).count - 1 == text[live..<end].components(separatedBy: needle).count - 1,
                            "every call sits inside `static let live`")
                default:
                    Issue.record("\(name) must not turn Touch ID for sudo off")
                }
            }
        }
    }

    // MARK: - Source access

    private func packageRoot(file: String = #filePath) -> URL {
        URL(fileURLWithPath: file).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: packageRoot().appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func swiftSources(under relativePath: String) throws -> [(name: String, text: String)] {
        let root = packageRoot()
        let enumerator = try #require(FileManager.default.enumerator(at: root.appendingPathComponent(relativePath), includingPropertiesForKeys: nil))
        return try enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }.map { url in
            (url.path.replacingOccurrences(of: root.path + "/", with: ""), try String(contentsOf: url, encoding: .utf8))
        }
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
