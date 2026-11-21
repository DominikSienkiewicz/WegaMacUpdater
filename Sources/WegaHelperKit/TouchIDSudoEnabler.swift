import Foundation

/// Turns Touch ID for `sudo` on as root: adds the exact directive to `sudo_local`, or writes it from
/// Apple's template when there is none, through the transactional writer.
///
/// The order is fixed (Aneks E.2, E.9): the caller, then the policy directory, `sudo_local` and,
/// only when it is missing, the template, each read through the directory's one descriptor and held
/// to the same gates as turning Touch ID off; the plan on exactly those bytes; one write; and a
/// readback through the same descriptor. A refusal before the write leaves the file system as it was.
public enum TouchIDSudoEnabler {
    static let templateFileName = "sudo_local.template"

    /// The operation on `/private/etc/pam.d`, as the root helper runs it. The writer is given the
    /// path in the directory the gate verified, not one through the `/etc` link.
    public static func runLive(caller: TouchIDSudoDisabler.Caller) -> TouchIDSudoEnableReport {
        let target = URL(fileURLWithPath: SystemPaths.pamPolicyDirectory)
            .appendingPathComponent(TouchIDSudoDisabler.policyFileName, isDirectory: false)
        return run(
            caller: caller,
            openDirectory: { try SystemPAMPolicyDirectory(path: SystemPaths.pamPolicyDirectory) },
            write: { try SudoLocalTransactionalWriter().writeAtomically($0, to: target) }
        )
    }

    /// Ends the operation with `report`; every step throws one instead of returning early.
    struct Outcome: Error {
        let report: TouchIDSudoEnableReport

        static func refused(_ refusal: TouchIDSudoEnableRefusal, at step: TouchIDSudoEnableStep) -> Outcome {
            Outcome(report: TouchIDSudoEnableReport(result: .refused(refusal), failedStep: step))
        }

        /// Every shared gate's refusal has an enable code: the three removal-only ones never come from a gate.
        static func refused(_ gate: TouchIDSudoDisabler.GateRefusal, at step: TouchIDSudoEnableStep) -> Outcome {
            refused(TouchIDSudoEnableRefusal(gate.refusal) ?? .unreadable, at: step)
        }
    }

    /// The whole operation over the policy directory `openDirectory` opens. `write` is the
    /// transactional writer in production; `requiredOwnerUID` is root's in production and the
    /// test's own uid over a temporary directory.
    static func run(
        caller: TouchIDSudoDisabler.Caller,
        openDirectory: () throws -> any PAMPolicyDirectoryAccess,
        write: (Data) throws -> Void,
        requiredOwnerUID: UInt32 = 0
    ) -> TouchIDSudoEnableReport {
        do throws(Outcome) {
            if let refusal = TouchIDSudoDisabler.refusal(caller: caller) {
                throw .refused(TouchIDSudoEnableRefusal(refusal) ?? .callerNotAdministrator, at: .caller)
            }
            let directory: any PAMPolicyDirectoryAccess
            do {
                directory = try TouchIDSudoDisabler.verifiedDirectory(openDirectory, requiredOwnerUID: requiredOwnerUID)
            } catch {
                throw .refused(error, at: .directory)
            }
            guard let contents = try plannedContents(in: directory, requiredOwnerUID: requiredOwnerUID) else {
                return TouchIDSudoEnableReport(result: .alreadyEnabled)
            }
            try perform(write, contents)
            try verifyPlaced(contents, in: directory, requiredOwnerUID: requiredOwnerUID)
            return TouchIDSudoEnableReport(result: .enabled)
        } catch {
            return error.report
        }
    }

    /// What to write, or `nil` when `sudo_local` itself already holds an active line. A base taken
    /// from the template is always written (RC2-2): `sudo` reads only `sudo_local`.
    private static func plannedContents(
        in directory: any PAMPolicyDirectoryAccess, requiredOwnerUID: UInt32
    ) throws(Outcome) -> Data? {
        let existing = try verifiedFile(TouchIDSudoDisabler.policyFileName, in: directory, requiredOwnerUID: requiredOwnerUID, at: .read)
        if let existing {
            switch TouchIDSudoConfigurator.contentsEnablingTouchID(current: existing.bytes) {
            case .alreadyEnabled: return nil
            case .write(let contents): return contents
            case .refused(let refusal): throw .refused(refusal, at: .plan)
            }
        }
        let base = try verifiedFile(templateFileName, in: directory, requiredOwnerUID: requiredOwnerUID, at: .template)?.bytes ?? Data()
        switch TouchIDSudoConfigurator.contentsEnablingTouchID(current: base) {
        case .alreadyEnabled: return base
        case .write(let contents): return contents
        case .refused(let refusal): throw .refused(refusal, at: .plan)
        }
    }

    private static func verifiedFile(
        _ name: String, in directory: any PAMPolicyDirectoryAccess, requiredOwnerUID: UInt32, at step: TouchIDSudoEnableStep
    ) throws(Outcome) -> TouchIDSudoDisabler.Original? {
        do {
            return try TouchIDSudoDisabler.verifiedPolicyFile(named: name, in: directory, requiredOwnerUID: requiredOwnerUID)
        } catch {
            throw .refused(error, at: step)
        }
    }

    /// A writer that could not undo its write names the backup it kept, as the app shows it under
    /// `/etc/pam.d`; any other failure was undone by the writer.
    private static func perform(_ write: (Data) throws -> Void, _ contents: Data) throws(Outcome) {
        do {
            try write(contents)
        } catch SudoLocalTransactionalWriter.WriteError.rollbackFailed(let backupPath) {
            let reported = backupPath.map { TouchIDSudoDisabler.reportedPath(of: URL(fileURLWithPath: $0).lastPathComponent) }
            throw Outcome(report: TouchIDSudoEnableReport(result: .rollbackFailed(backupPath: reported), failedStep: .write))
        } catch {
            throw Outcome(report: TouchIDSudoEnableReport(result: .restoredAfterFailure, failedStep: .write))
        }
    }

    /// Z7: the writer works by path, so what it left is read back through the descriptor the gate
    /// verified: a regular file only root can change, with no ACL, holding exactly the plan.
    private static func verifyPlaced(
        _ contents: Data, in directory: any PAMPolicyDirectoryAccess, requiredOwnerUID: UInt32
    ) throws(Outcome) {
        let placed: TouchIDSudoDisabler.Original?
        do {
            placed = try TouchIDSudoDisabler.verifiedPolicyFile(
                named: TouchIDSudoDisabler.policyFileName, in: directory, requiredOwnerUID: requiredOwnerUID
            )
        } catch {
            throw .refused(.changedDuringOperation, at: .verify)
        }
        guard let placed else {
            throw Outcome(report: TouchIDSudoEnableReport(result: .rollbackFailed(backupPath: nil), failedStep: .verify))
        }
        guard placed.bytes == contents else { throw .refused(.changedDuringOperation, at: .verify) }
    }
}
