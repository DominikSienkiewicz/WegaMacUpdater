import Foundation
@testable import WegaHelperKit

/// An in-memory `/etc/pam.d` for the disable transaction.
///
/// Every call is recorded as an event (`"read sudo_local"`, `"swap A B"`, …). Any occurrence of an
/// event can be made to fail with a POSIX code, and an action can run right after any occurrence,
/// which is how a test plays another root writer at an exact point of the transaction.
final class PAMPolicyDirectoryFake: PAMPolicyDirectoryAccess {
    enum Kind: Equatable {
        case regular, symlink, directory, fifo
    }

    struct Entry: Equatable {
        var kind: Kind = .regular
        var identity: PAMFileIdentity
        var data = Data()
        var ownerUID: UInt32 = 0
        var groupID: UInt32 = 0
        var permissions: UInt16 = 0o644
        var accessControl: PAMAccessControlState = .absent
        var linkCount: UInt32 = 1
        var modified: Int64 = 1_000
        /// `st_size` when it should differ from the bytes, as for a file that changed after `fstat`.
        var reportedSize: Int64?
    }

    var entries: [String: Entry]
    var directory = PAMPolicyDirectoryFacts(isDirectory: true, ownerUID: 0, permissions: 0o755, accessControl: .absent)
    var swapSupported = true
    var existingFallbacks: Set<String> = []
    /// What the n-th `readPolicyFile` answers instead of looking at `entries`.
    var readAnswers: [Int: PAMPolicyFileRead] = [:]
    private(set) var events: [String] = []
    private var failures: [String: [Int: POSIXErrorCode]] = [:]
    private var actions: [String: [Int: (PAMPolicyDirectoryFake) -> Void]] = [:]
    private var occurrences: [String: Int] = [:]
    private var reads = 0
    private var nextInode: UInt64 = 1_000

    init(entries: [String: Entry] = [:]) {
        self.entries = entries
    }

    /// A directory holding only `sudo_local` with `text`, root's, at inode 1.
    static func holding(_ text: String, permissions: UInt16 = 0o644) -> PAMPolicyDirectoryFake {
        PAMPolicyDirectoryFake(entries: [
            "sudo_local": Entry(identity: PAMFileIdentity(device: 1, inode: 1), data: Data(text.utf8), permissions: permissions)
        ])
    }

    func fail(_ event: String, occurrence: Int = 1, with code: POSIXErrorCode) {
        failures[event, default: [:]][occurrence] = code
    }

    func after(_ event: String, occurrence: Int = 1, _ action: @escaping (PAMPolicyDirectoryFake) -> Void) {
        actions[event, default: [:]][occurrence] = action
    }

    func newIdentity() -> PAMFileIdentity {
        nextInode += 1
        return PAMFileIdentity(device: 1, inode: nextInode)
    }

    /// Puts a different file under `name`, as another root writer replacing it would.
    func replace(_ name: String, with text: String) {
        entries[name] = Entry(identity: newIdentity(), data: Data(text.utf8))
    }

    /// The `fallbackExists` closure the operation takes, recorded alongside the directory's events.
    func fallbackExists(_ path: String) -> Bool {
        events.append("fallback \(path)")
        return existingFallbacks.contains(path)
    }

    func facts(of entry: Entry) -> PAMPolicyFileFacts {
        PAMPolicyFileFacts(
            isRegularFile: entry.kind == .regular, identity: entry.identity, linkCount: entry.linkCount,
            ownerUID: entry.ownerUID, groupID: entry.groupID, permissions: entry.permissions,
            accessControl: entry.accessControl, size: entry.reportedSize ?? Int64(entry.data.count),
            modifiedNanoseconds: entry.modified
        )
    }

    // MARK: - PAMPolicyDirectoryAccess

    func directoryFacts() throws -> PAMPolicyDirectoryFacts {
        try perform("directory") { directory }
    }

    func supportsSwap() throws -> Bool {
        try perform("capability") { swapSupported }
    }

    func readPolicyFile(named name: String, limit: Int) throws -> PAMPolicyFileRead {
        try perform("read \(name)") {
            reads += 1
            if let answer = readAnswers[reads] { return answer }
            guard let entry = entries[name] else { return .missing }
            guard entry.kind == .regular else { return .notRegular }
            return .read(facts(of: entry), entry.data.prefix(limit + 1))
        }
    }

    func facts(named name: String) throws -> PAMPolicyFileFacts? {
        try perform("facts \(name)") { entries[name].map(facts(of:)) }
    }

    func createFile(
        named name: String, contents: Data, owner: uid_t, group: gid_t, permissions: mode_t
    ) throws -> PAMPolicyFileFacts {
        try perform("create \(name)") {
            guard entries[name] == nil else { throw POSIXError(.EEXIST) }
            let entry = Entry(
                identity: newIdentity(), data: contents, ownerUID: owner, groupID: group,
                permissions: UInt16(permissions), modified: 2_000
            )
            entries[name] = entry
            return facts(of: entry)
        }
    }

    func swap(_ first: String, _ second: String) throws {
        try perform("swap \(first) \(second)") {
            guard let one = entries[first], let other = entries[second] else { throw POSIXError(.ENOENT) }
            entries[first] = other
            entries[second] = one
        }
    }

    func synchronize() throws {
        try perform("sync") {}
    }

    func remove(named name: String, ifIdentity identity: PAMFileIdentity) throws -> Bool {
        try perform("remove \(name)") {
            guard entries[name]?.identity == identity else { return false }
            entries[name] = nil
            return true
        }
    }

    // MARK: - Recording

    private func perform<T>(_ event: String, _ body: () throws -> T) throws -> T {
        events.append(event)
        let occurrence = occurrences[event, default: 0] + 1
        occurrences[event] = occurrence
        defer { actions[event]?[occurrence]?(self) }
        if let code = failures[event]?[occurrence] { throw POSIXError(code) }
        return try body()
    }
}
