import Foundation
import Testing
import WegaHelperKit

/// The root helper's verb that stages a root-owned application for the caller's Trash.
///
/// `WegaPrivilegedHelper` runs only as root and no test target compiles it, so the order of its
/// steps is pinned on the source: every gate before the move, the identity re-checked after the
/// move and before any ownership change, the moved tree handed over before the slot that holds
/// it, and the caller's identity taken from the XPC connection rather than from the request.
/// The filesystem primitives the verb calls live in `WegaHelperKit` and are exercised for real by
/// `UninstallStagingFileSystemTests`; here only their no-follow guarantees are pinned on source.
@Suite("Helper bundle staging: daemon wiring")
struct HelperBundleStagingSourceTests {

    // MARK: - Order inside the verb

    @Test func verbRunsGatesBeforeRename() throws {
        let body = try verbBody()
        let rename = try #require(position(of: "renameIntoSlot(", in: body), "the verb must move the bundle")
        let ordered = [
            "requireNoUnresolvedInstallation()",
            "bundleStagingRejection(targetPath:",
            "bundleStagingRejection(facts:",
            "prepareRoot(",
            "createSlot(",
        ]
        var previous = body.startIndex
        for call in ordered {
            let found = try #require(position(of: call, in: body), "missing in the verb: \(call)")
            #expect(found >= previous, "\(call) runs out of order")
            #expect(found < rename, "\(call) must run before the move")
            previous = found
        }
        let preMoveCheck = try #require(position(of: "bundleStagingRejection(validated:", in: body))
        #expect(preMoveCheck < rename, "the identity must be re-checked before the move")
    }

    /// Ruling 13 and 14: nothing changes owner until the entry now in the slot has been proven to
    /// be the bundle that was validated, and the slot is given to the caller only after the tree.
    @Test func ownershipChangesOnlyAfterTheMove() throws {
        let body = try verbBody()
        let rename = try #require(position(of: "renameIntoSlot(", in: body))
        let postMoveCheck = try #require(
            position(of: "bundleStagingRejection(validated:", in: body, after: rename),
            "the identity must be re-checked after the move")
        let tree = try #require(position(of: "handOverTree(", in: body), "the moved tree must be handed over")
        let slot = try #require(position(of: "handOverSlot(", in: body), "the slot must be handed over")

        #expect(rename < postMoveCheck)
        #expect(postMoveCheck < tree, "ownership changes only after the post-move identity check")
        #expect(tree < slot, "the slot stays root's until its contents are handed over")
        for ownershipChange in ["handOverTree(", "handOverSlot(", "chown("] {
            if let found = position(of: ownershipChange, in: body) {
                #expect(found > rename, "\(ownershipChange) must not run before the move")
            }
        }
    }

    @Test func callerUIDComesFromTheConnection() throws {
        let helper = try source("Sources/WegaPrivilegedHelper/HelperDelegate.swift")
        let compact = helper.filter { !$0.isWhitespace }
        #expect(compact.contains("PrivilegedOps(callerUID:newConnection.effectiveUserIdentifier"),
                "the caller's uid must come from the kernel's view of the connection")
        #expect(!compact.contains("PrivilegedOps()"), "every connection's object must know its caller")
    }

    @Test func helperVersionIsEight() {
        #expect(WegaHelper.version == "8")
    }

    @Test func protocolDeclaresTheVerb() throws {
        let protocolSource = try source("Sources/WegaHelperKit/WegaHelperProtocol.swift")
            .filter { !$0.isWhitespace }
        #expect(protocolSource.contains(
            "funcstageApplicationBundleForTrash(atPathpath:String,expectedBundleID:String,"
                + "withReplyreply:@escaping@Sendable(String?,String?)->Void)"))
    }

    // MARK: - No-follow guarantees of the primitives

    /// Ruling 16: a symlink in any component of either path fails the move, so a `<folder>`
    /// swapped for a link after validation cannot redirect it.
    @Test func moveRefusesSymlinksInEveryComponent() throws {
        let fileSystem = try source("Sources/WegaHelperKit/UninstallStagingFileSystem.swift")
        #expect(fileSystem.contains("renameatx_np("))
        #expect(fileSystem.contains("RENAME_NOFOLLOW_ANY"))
        #expect(!fileSystem.contains("FileManager.default.moveItem"))
    }

    /// Fix round 1: the identifier and the resolved path are read through the descriptor of the
    /// inode the first `lstat` validated, never by name, so swapping the name away and back while
    /// they are read cannot lend the bundle another identity.
    @Test func factsAreReadThroughTheValidatedDescriptor() throws {
        let fileSystem = try source("Sources/WegaHelperKit/UninstallStagingFileSystem.swift")
        #expect(fileSystem.contains("openat("), "Info.plist must be opened relative to the bundle's descriptor")
        #expect(fileSystem.contains("\"Contents/Info.plist\""))
        #expect(fileSystem.contains("F_GETPATH"), "the resolved path must come from the descriptor")
        #expect(!fileSystem.contains("realpath("), "no second lookup by name")
        #expect(!fileSystem.contains("path + \"/Contents/Info.plist\""), "no Info.plist lookup by name")
    }

    /// Ruling 13: a physical walk that stays on the bundle's volume and leaves hard-linked files
    /// root-owned, opening every entry with no symlink allowed anywhere in its path.
    @Test func treeWalkIsPhysicalStaysOnTheVolumeAndSkipsHardLinks() throws {
        let fileSystem = try source("Sources/WegaHelperKit/UninstallStagingFileSystem.swift")
        for marker in ["FTS_PHYSICAL", "FTS_XDEV", "FTS_NOCHDIR", "st_nlink", "O_NOFOLLOW_ANY", "fchown("] {
            #expect(fileSystem.contains(marker), "missing from the tree walk: \(marker)")
        }
        #expect(!fileSystem.contains("FTS_LOGICAL"))
        #expect(!fileSystem.contains("FTS_COMFOLLOW"))
    }

    // MARK: - Source access

    private func packageRoot(file: String = #filePath) -> URL {
        URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: packageRoot().appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// The body of `stageApplicationBundleForTrash` in the daemon, from its opening brace to the
    /// matching closing one.
    private func verbBody() throws -> String {
        let helper = try source("Sources/WegaPrivilegedHelper/HelperDelegate.swift")
        let signature = try #require(
            helper.range(of: "func stageApplicationBundleForTrash("), "the daemon must implement the verb")
        let opening = try #require(helper[signature.upperBound...].firstIndex(of: "{"))
        var depth = 0
        var index = opening
        while index < helper.endIndex {
            if helper[index] == "{" { depth += 1 }
            if helper[index] == "}" {
                depth -= 1
                if depth == 0 { return String(helper[opening...index]) }
            }
            index = helper.index(after: index)
        }
        Issue.record("the verb's body is not closed")
        return ""
    }

    private func position(of needle: String, in text: String, after start: String.Index? = nil) -> String.Index? {
        let searchStart = start.map { text.index(after: $0) } ?? text.startIndex
        return text.range(of: needle, range: searchStart..<text.endIndex)?.lowerBound
    }
}
