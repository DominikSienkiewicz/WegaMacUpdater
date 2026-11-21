import Darwin
import Foundation

/// Turns Touch ID for `sudo` off as root: removes the exact directive from `sudo_local` through a
/// new file swapped in with `RENAME_SWAP`, verifies it, and swaps the original back on any failure.
///
/// The order is fixed: the caller, then the directory, the file and its plan, the later policy
/// files, swap support, and only then anything that writes. A refusal at any of the first steps
/// leaves the file system as it was; nothing is ever written in place.
public enum TouchIDSudoDisabler {
    /// Who asks, as the kernel and the system report it for the XPC connection.
    public struct Caller: Equatable, Sendable {
        public var uid: UInt32
        public var consoleUserUID: UInt32?
        public var isAdministrator: Bool

        public init(uid: UInt32, consoleUserUID: UInt32?, isAdministrator: Bool) {
            self.uid = uid
            self.consoleUserUID = consoleUserUID
            self.isAdministrator = isAdministrator
        }
    }

    /// The largest `sudo_local` the helper changes.
    public static let maximumSize = 65_536
    public static let fallbackPolicyPaths = SystemPaths.pamFallbackPolicyPaths
    /// Every name this operation creates in the policy directory starts with this.
    public static let swapNamePrefix = ".sudo_local.wega-"
    static let policyFileName = "sudo_local"

    // MARK: - Gates

    /// The administrator at the console, and nobody else, may turn Touch ID for `sudo` off.
    public static func refusal(caller: Caller) -> TouchIDSudoDisableRefusal? {
        guard let consoleUserUID = caller.consoleUserUID else { return .noConsoleUser }
        guard caller.uid == consoleUserUID else { return .callerNotConsoleUser }
        guard caller.isAdministrator else { return .callerNotAdministrator }
        return nil
    }

    /// `/etc/pam.d` must be a directory that only root can change.
    public static func refusal(directory: PAMPolicyDirectoryFacts) -> TouchIDSudoDisableRefusal? {
        refusal(directory: directory, requiredOwnerUID: 0)
    }

    /// `sudo_local` must be a regular file only root can change, no larger than `maximumSize`.
    public static func refusal(file: PAMPolicyFileFacts) -> TouchIDSudoDisableRefusal? {
        refusal(file: file, requiredOwnerUID: 0)
    }

    static func refusal(directory: PAMPolicyDirectoryFacts, requiredOwnerUID: UInt32) -> TouchIDSudoDisableRefusal? {
        let isSafe = directory.isDirectory && directory.ownerUID == requiredOwnerUID
            && directory.permissions & 0o022 == 0 && directory.accessControl == .absent
        return isSafe ? nil : .unsafeOwnership
    }

    /// `linkCount` is deliberately not a gate: an unprivileged process can hard-link the file (H22),
    /// so refusing a second name would let anyone block this operation. The swap leaves the old
    /// bytes under that name, and the count is logged.
    static func refusal(file: PAMPolicyFileFacts, requiredOwnerUID: UInt32) -> TouchIDSudoDisableRefusal? {
        guard file.isRegularFile else { return .notRegularFile }
        guard file.ownerUID == requiredOwnerUID, file.permissions & 0o022 == 0, file.accessControl == .absent else {
            return .unsafeOwnership
        }
        guard file.size <= Int64(maximumSize) else { return .tooLarge }
        return nil
    }

    // MARK: - Live

    /// The operation on `/private/etc/pam.d`, as the root helper runs it.
    public static func runLive(caller: Caller) -> TouchIDSudoDisableReport {
        run(
            caller: caller,
            openDirectory: { try SystemPAMPolicyDirectory(path: SystemPaths.pamPolicyDirectory) },
            fallbackExists: fallbackPolicyEntryExists(atPath:),
            makeName: makeSwapName
        )
    }

    /// The live swap name: the prefix, `swap-` and a fresh UUID.
    static func makeSwapName() -> String {
        swapNamePrefix + "swap-" + UUID().uuidString
    }

    /// How a name in the policy directory is reported to the app and the log.
    static func reportedPath(of name: String) -> String {
        SystemPaths.pamPolicyDisplayDirectory + "/" + name
    }

    /// A later policy path counts as there when `lstat` finds it, link or not, and also when
    /// `lstat` fails for any reason other than its absence.
    static func fallbackPolicyEntryExists(atPath path: String) -> Bool {
        var status = stat()
        guard lstat(path, &status) != 0 else { return true }
        return errno != ENOENT && errno != ENOTDIR
    }

    // MARK: - The operation

    /// Ends the operation with `report`; every step throws one instead of returning early.
    struct Outcome: Error {
        let report: TouchIDSudoDisableReport

        static func refused(
            _ refusal: TouchIDSudoDisableRefusal, at step: TouchIDSudoDisableStep, fallbackPolicyPath: String? = nil
        ) -> Outcome {
            Outcome(report: TouchIDSudoDisableReport(result: .refused(refusal), failedStep: step, fallbackPolicyPath: fallbackPolicyPath))
        }

        static func failed(at step: TouchIDSudoDisableStep) -> Outcome {
            Outcome(report: TouchIDSudoDisableReport(result: .restoredAfterFailure, failedStep: step))
        }

        static let nothingToRemove = Outcome(report: TouchIDSudoDisableReport(result: .nothingToRemove))
    }

    /// `sudo_local` as read before anything changed: the snapshot every later check compares with.
    struct Original {
        let facts: PAMPolicyFileFacts
        let bytes: Data
    }

    /// The whole operation over the policy directory `openDirectory` opens. `requiredOwnerUID` is
    /// root's in production and the test's own uid over a temporary directory.
    static func run(
        caller: Caller,
        openDirectory: () throws -> any PAMPolicyDirectoryAccess,
        fallbackExists: (String) -> Bool,
        makeName: () -> String,
        requiredOwnerUID: UInt32 = 0
    ) -> TouchIDSudoDisableReport {
        var linkCount: UInt32?
        do throws(Outcome) {
            if let refusal = refusal(caller: caller) { throw .refused(refusal, at: .caller) }
            let directory = try openVerifiedDirectory(openDirectory, requiredOwnerUID: requiredOwnerUID)
            let original = try readOriginal(in: directory, requiredOwnerUID: requiredOwnerUID)
            linkCount = original.facts.linkCount == 1 ? nil : original.facts.linkCount
            let (lines, contents) = try plannedRemoval(of: original)
            if let path = fallbackPolicyPaths.first(where: fallbackExists) {
                throw .refused(.fallbackPolicyPresent, at: .fallback, fallbackPolicyPath: path)
            }
            guard (try? directory.supportsSwap()) == true else { throw .failed(at: .capability) }
            let swap = try SwapTransaction.begin(in: directory, original: original, contents: contents, name: makeName())
            var report = try swap.complete(removedLines: lines)
            report.linkCount = linkCount
            return report
        } catch {
            var report = error.report
            report.linkCount = linkCount
            return report
        }
    }

    private static func openVerifiedDirectory(
        _ openDirectory: () throws -> any PAMPolicyDirectoryAccess, requiredOwnerUID: UInt32
    ) throws(Outcome) -> any PAMPolicyDirectoryAccess {
        let directory: any PAMPolicyDirectoryAccess
        let facts: PAMPolicyDirectoryFacts
        do {
            directory = try openDirectory()
            facts = try directory.directoryFacts()
        } catch {
            // A link anywhere in the path is a directory someone other than root may redirect.
            throw .refused((error as? POSIXError)?.code == .ELOOP ? .unsafeOwnership : .unreadable, at: .directory)
        }
        if let refusal = refusal(directory: facts, requiredOwnerUID: requiredOwnerUID) {
            throw .refused(refusal, at: .directory)
        }
        return directory
    }

    private static func readOriginal(
        in directory: any PAMPolicyDirectoryAccess, requiredOwnerUID: UInt32
    ) throws(Outcome) -> Original {
        let read: PAMPolicyFileRead
        do {
            read = try directory.readPolicyFile(named: policyFileName, limit: maximumSize)
        } catch {
            throw .refused(.unreadable, at: .read)
        }
        switch read {
        case .missing:
            throw .nothingToRemove
        case .notRegular:
            throw .refused(.notRegularFile, at: .read)
        case .changed:
            throw .refused(.changedDuringOperation, at: .read)
        case .read(let facts, let bytes):
            if let refusal = refusal(file: facts, requiredOwnerUID: requiredOwnerUID) { throw .refused(refusal, at: .read) }
            guard bytes.count <= maximumSize else { throw .refused(.tooLarge, at: .read) }
            guard Int64(bytes.count) == facts.size else { throw .refused(.changedDuringOperation, at: .read) }
            return Original(facts: facts, bytes: bytes)
        }
    }

    private static func plannedRemoval(of original: Original) throws(Outcome) -> (lines: Int, contents: Data) {
        switch TouchIDSudoConfigurator.contentsDisablingTouchID(current: original.bytes) {
        case .nothingToRemove:
            throw .nothingToRemove
        case .refused(let refusal):
            throw .refused(refusal, at: .plan)
        case .remove(let lines, let contents):
            return (lines, contents)
        }
    }

    // MARK: - Verification

    /// The same inode, size and modification time as the snapshot: nobody wrote it since.
    static func isUnchanged(_ current: PAMPolicyFileFacts, since snapshot: PAMPolicyFileFacts) -> Bool {
        current.identity == snapshot.identity && current.size == snapshot.size
            && current.modifiedNanoseconds == snapshot.modifiedNanoseconds
    }

    static func hasOriginalAttributes(_ current: PAMPolicyFileFacts, _ original: PAMPolicyFileFacts) -> Bool {
        current.ownerUID == original.ownerUID && current.groupID == original.groupID
            && current.permissions == original.permissions
    }

    /// Whether `readback` is the planned file and still means what the original meant without the
    /// directive: the bytes planned, nothing left to remove, the original's lines minus the
    /// directive by a second, independent reading, and no active line.
    static func readbackIsAcceptable(_ readback: Data, expected: Data, original: Data) -> Bool {
        guard readback == expected,
              TouchIDSudoConfigurator.contentsDisablingTouchID(current: readback) == .nothingToRemove else {
            return false
        }
        let lines = PAMPolicyLines.referenceLines([UInt8](readback))
        let originalLines = PAMPolicyLines.referenceLines([UInt8](original))
        return lines == originalLines.filter { !PAMPolicyLines.isExactDirective($0) }
            && lines.allSatisfy(PAMPolicyLines.isBlankOrComment)
    }
}

/// Everything from the new file on: one swap name, the original's snapshot and the new file's
/// identity. The helper removes a name only while it still points at a file it knows.
private struct SwapTransaction {
    let directory: any PAMPolicyDirectoryAccess
    let original: TouchIDSudoDisabler.Original
    let contents: Data
    let name: String
    let created: PAMPolicyFileFacts

    private typealias Outcome = TouchIDSudoDisabler.Outcome
    private static var target: String { TouchIDSudoDisabler.policyFileName }

    private var reportedPath: String { TouchIDSudoDisabler.reportedPath(of: name) }

    /// S6–S7: the new file under the swap name, then the swap. Before the swap succeeds nothing
    /// that `sudo` reads has changed, so every failure here removes the new file and ends.
    static func begin(
        in directory: any PAMPolicyDirectoryAccess, original: TouchIDSudoDisabler.Original, contents: Data, name: String
    ) throws(TouchIDSudoDisabler.Outcome) -> SwapTransaction {
        let created: PAMPolicyFileFacts
        do {
            created = try directory.createFile(
                named: name, contents: contents, owner: original.facts.ownerUID, group: original.facts.groupID,
                permissions: mode_t(original.facts.permissions)
            )
        } catch {
            throw .failed(at: .temporary)
        }
        let swap = SwapTransaction(directory: directory, original: original, contents: contents, name: name, created: created)
        do {
            try directory.swap(name, target)
        } catch {
            let missing = (error as? POSIXError)?.code == .ENOENT
            throw Outcome(report: TouchIDSudoDisableReport(
                result: missing ? .refused(.changedDuringOperation) : .restoredAfterFailure,
                failedStep: .swap, leftBehindPath: swap.removeLeavingPath(ifIdentity: created.identity)
            ))
        }
        return swap
    }

    /// S8–S11: make the swap durable, prove the file swapped out is the one read and the file
    /// swapped in is the one planned, then drop the original's swap name.
    func complete(removedLines: Int) throws(TouchIDSudoDisabler.Outcome) -> TouchIDSudoDisableReport {
        do {
            try directory.synchronize()
        } catch {
            throw swapBack(after: .directorySync)
        }
        guard let swappedOut = try? directory.facts(named: name),
              TouchIDSudoDisabler.isUnchanged(swappedOut, since: original.facts) else {
            throw swapBack(after: .swappedOutCheck)
        }
        guard verifiesPlacedFile() else { throw swapBack(after: .verify) }
        let leftBehind = removeLeavingPath(ifIdentity: original.facts.identity)
        return TouchIDSudoDisableReport(
            result: .removed(lines: removedLines), failedStep: leftBehind == nil ? nil : .cleanup, leftBehindPath: leftBehind
        )
    }

    private func verifiesPlacedFile() -> Bool {
        guard let placed = try? directory.facts(named: Self.target), placed.isRegularFile,
              placed.identity == created.identity,
              TouchIDSudoDisabler.hasOriginalAttributes(placed, original.facts),
              case .read(let read, let readback)? = try? directory.readPolicyFile(
                  named: Self.target, limit: TouchIDSudoDisabler.maximumSize
              ),
              read.identity == created.identity, read.accessControl == .absent,
              TouchIDSudoDisabler.hasOriginalAttributes(read, original.facts) else {
            return false
        }
        return TouchIDSudoDisabler.readbackIsAcceptable(readback, expected: contents, original: original.bytes)
    }

    /// One swap back, decided by identity. A file other than ours in `sudo_local` means another
    /// root writer replaced it: it stays, and the original stays under the swap name. −21 only
    /// when the swap back itself fails, so the swap name then holds the file swapped out.
    private func swapBack(after trigger: TouchIDSudoDisableStep) -> Outcome {
        guard let current = try? directory.facts(named: Self.target), current.identity == created.identity else {
            return Outcome(report: TouchIDSudoDisableReport(
                result: .refused(.changedDuringOperation), failedStep: .swapBack, leftBehindPath: reportedPath
            ))
        }
        do {
            try directory.swap(name, Self.target)
        } catch {
            return Outcome(report: TouchIDSudoDisableReport(result: .rollbackFailed(backupPath: reportedPath), failedStep: .swapBack))
        }
        // The names are back whatever the flush says; a failed one weakens only crash durability.
        try? directory.synchronize()
        let restored = try? directory.facts(named: Self.target)
        let leftBehind = removeLeavingPath(ifIdentity: created.identity)
        guard trigger != .swappedOutCheck else {
            return Outcome(report: TouchIDSudoDisableReport(
                result: .refused(.changedDuringOperation), failedStep: trigger, leftBehindPath: leftBehind
            ))
        }
        guard let restored, TouchIDSudoDisabler.isUnchanged(restored, since: original.facts) else {
            return Outcome(report: TouchIDSudoDisableReport(
                result: .refused(.changedDuringOperation), failedStep: .swapBackVerify, leftBehindPath: leftBehind
            ))
        }
        return Outcome(report: TouchIDSudoDisableReport(result: .restoredAfterFailure, failedStep: trigger, leftBehindPath: leftBehind))
    }

    /// Removes the swap name while it names `identity`; the reported path when it stays.
    private func removeLeavingPath(ifIdentity identity: PAMFileIdentity) -> String? {
        (try? directory.remove(named: name, ifIdentity: identity)) == true ? nil : reportedPath
    }
}
