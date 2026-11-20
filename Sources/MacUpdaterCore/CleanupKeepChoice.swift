import Foundation

/// Decides, per duplicated tool, which copy stays and what the other copies' removal looks like.
public enum CleanupKeepChoice {
    private struct Group {
        let kept: CleanupFinding?
        let members: [CleanupFinding]
    }

    private struct Outcome {
        let reason: CleanupReason
        let action: CleanupAction
        let risk: CleanupRisk
        let bucket: CleanupBucket
        let size: Int64?
    }

    private struct Context {
        let groups: [String: Group]
        /// Paths of the app bundles that provide a copy which stays: every group's kept copy and
        /// every lone copy that offers no choice.
        let keptBundles: Set<String>
        let pathIsApproximate: Bool
    }

    /// Returns the report with its D1 findings resolved against `choices`; totals follow the new buckets.
    public static func apply(_ choices: [String: CleanupKeptCopy], to report: CleanupReport) -> CleanupReport {
        CleanupReport(
            createdAt: report.createdAt, path: report.path,
            findings: resolve(report.findings, choices: choices, pathIsApproximate: report.path.isApproximate),
            notes: report.notes, skippedProtected: report.skippedProtected
        )
    }

    /// Keeps only the choices whose tool still has a copy with exactly that path and source: a
    /// candidate, or the active copy left alone once its rivals are gone, so the choice holds when
    /// one comes back.
    public static func validChoices(
        _ choices: [String: CleanupKeptCopy], in report: CleanupReport
    ) -> [String: CleanupKeptCopy] {
        choices.filter { key, choice in
            report.findings.contains { finding in
                finding.detector == .pathDuplicates && (finding.candidate != nil || finding.status == .active)
                    && finding.tool.lowercased() == key
                    && matches(finding, choice)
            }
        }
    }

    /// The outermost path component of `realpath` that ends in `.app` and holds a `Contents`
    /// directory on the way to `realpath`, as a URL, or nil.
    static func enclosingAppBundle(of realpath: URL) -> URL? {
        let components = CleanupPathText.components(of: realpath.path)
        guard let index = components.indices.dropLast().first(where: {
            components[$0 + 1] == "Contents" && CleanupSourceClassifier.hasScalarSuffix(components[$0], ".app")
        }) else { return nil }
        return URL(filePath: "/" + components[...index].joined(separator: "/"), directoryHint: .isDirectory)
    }

    /// Rewrites reason, action, bucket, size, risk and the candidate's keep state of every D1 finding
    /// that has a candidate, and the advice of every Files and Folders entry tied to one; statuses,
    /// links and all other findings are returned unchanged.
    static func resolve(
        _ findings: [CleanupFinding], choices: [String: CleanupKeptCopy], pathIsApproximate: Bool
    ) -> [CleanupFinding] {
        let groups = groups(of: findings, choices: choices, pathIsApproximate: pathIsApproximate)
        let context = Context(
            groups: groups, keptBundles: keptBundles(findings, groups), pathIsApproximate: pathIsApproximate
        )
        let copies = findings.map { finding in
            guard finding.detector == .pathDuplicates, let candidate = finding.candidate,
                  let group = context.groups[finding.tool.lowercased()] else { return finding }
            return resolved(finding, candidate: candidate, group: group, context: context)
        }
        var keeps: [String: CleanupKeep] = [:]
        for copy in copies where copy.detector == .pathDuplicates {
            if let keep = copy.candidate?.keep { keeps[copy.id] = keep }
        }
        return copies.map { followingKeep($0, keeps: keeps) }
    }

    /// A Files and Folders entry of a copy that stays needs no advice and one of a copy to remove
    /// is switched off; while the copy waits for the choice, the scan's advice for its link stands.
    private static func followingKeep(_ entry: CleanupFinding, keeps: [String: CleanupKeep]) -> CleanupFinding {
        guard entry.detector == .tccMap, case .tccEntry(_, let link?) = entry.reason,
              let keep = keeps[link.findingID] else { return entry }
        let advice: CleanupAction = switch keep {
        case .kept: .none
        case .notKept: .instruction(.switchOffInFilesAndFolders)
        case .undecided: CleanupTCCMapDetector.advice(for: link)
        }
        return CleanupFinding(
            detector: entry.detector, tool: entry.tool, path: entry.path, realpath: entry.realpath, source: entry.source,
            version: entry.version, size: entry.size, status: entry.status, reason: entry.reason, action: advice,
            risk: entry.risk, bucket: entry.bucket, identity: entry.identity, candidate: entry.candidate
        )
    }

    private static func matches(_ finding: CleanupFinding, _ choice: CleanupKeptCopy) -> Bool {
        finding.path.path == choice.path && finding.source == choice.source
    }

    private static func groups(
        of findings: [CleanupFinding], choices: [String: CleanupKeptCopy], pathIsApproximate: Bool
    ) -> [String: Group] {
        let duplicates = findings.filter { $0.detector == .pathDuplicates }
        var result: [String: Group] = [:]
        for key in Set(duplicates.map { $0.tool.lowercased() }) {
            let members = duplicates.filter { $0.tool.lowercased() == key }
            let candidates = members.filter { $0.candidate != nil }
            guard !candidates.isEmpty else { continue }
            result[key] = Group(
                kept: keptCopy(among: candidates, choice: choices[key], pathIsApproximate: pathIsApproximate),
                members: members
            )
        }
        return result
    }

    private static func keptCopy(
        among candidates: [CleanupFinding], choice: CleanupKeptCopy?, pathIsApproximate: Bool
    ) -> CleanupFinding? {
        if let choice, let chosen = candidates.first(where: { matches($0, choice) }) { return chosen }
        return pathIsApproximate ? nil : candidates.first { $0.candidate?.pathRole == .active }
    }

    /// A group still waiting for the choice may yet keep any of its candidates, so all of them count.
    private static func keptBundles(_ findings: [CleanupFinding], _ groups: [String: Group]) -> Set<String> {
        let lone = findings.filter { $0.detector == .pathDuplicates && $0.candidate == nil && $0.status == .active }
        let staying = groups.values.flatMap { group in
            group.kept.map { [$0] } ?? group.members.filter { $0.candidate != nil }
        }
        return Set((staying + lone).compactMap { $0.realpath.flatMap(enclosingAppBundle(of:))?.path })
    }

    private static func resolved(
        _ finding: CleanupFinding, candidate: CleanupCandidate, group: Group, context: Context
    ) -> CleanupFinding {
        guard let kept = group.kept else { return undecided(finding, candidate) }
        if kept.id == finding.id { return keptFinding(finding, candidate) }
        return notKept(finding, candidate, kept: kept, group: group, context: context)
    }

    /// A copy that stays, or waits for the choice, is only "required by" when its status says so;
    /// a copy to remove is blocked by any installed formula that depends on it.
    private static func blockedReason(
        _ finding: CleanupFinding, _ candidate: CleanupCandidate, isRemoved: Bool
    ) -> CleanupReason? {
        if isRemoved, !candidate.dependents.isEmpty { return .requiredBy(candidate.dependents) }
        if case .dependency(let dependents) = finding.status { return .requiredBy(dependents) }
        return nil
    }

    private static func undecided(_ finding: CleanupFinding, _ candidate: CleanupCandidate) -> CleanupFinding {
        var updated = candidate
        updated.keep = .undecided
        updated.takesOver = nil
        return rebuilt(
            finding,
            Outcome(
                reason: blockedReason(finding, candidate, isRemoved: false) ?? .noCopyKept, action: .none,
                risk: riskOf(finding, candidate), bucket: .excluded, size: nil
            ),
            candidate: updated
        )
    }

    private static func keptFinding(_ finding: CleanupFinding, _ candidate: CleanupCandidate) -> CleanupFinding {
        var updated = candidate
        updated.keep = .kept
        updated.takesOver = nil
        let reason = blockedReason(finding, candidate, isRemoved: false)
            ?? (candidate.pathRole == .active ? .currentVersion : .keptByChoice)
        return rebuilt(
            finding, Outcome(reason: reason, action: .none, risk: riskOf(finding, candidate), bucket: .excluded, size: nil),
            candidate: updated
        )
    }

    private static func notKept(
        _ finding: CleanupFinding, _ candidate: CleanupCandidate, kept: CleanupFinding,
        group: Group, context: Context
    ) -> CleanupFinding {
        let isActive = candidate.pathRole == .active
        var updated = candidate
        updated.keep = .notKept(keptPath: kept.path.path)
        updated.takesOver = isActive && !context.pathIsApproximate ? takeOver(finding, in: group) : nil
        let risk = riskOf(finding, candidate)
        if let blocked = blockedReason(finding, candidate, isRemoved: true) {
            return rebuilt(
                finding, Outcome(reason: blocked, action: .none, risk: risk, bucket: .excluded, size: nil),
                candidate: updated
            )
        }
        let keptIsActive = kept.candidate?.pathRole == .active
        let reason: CleanupReason = keptIsActive ? .shadowedBy(path: kept.path.path) : .keptInstead(path: kept.path.path)
        let action = removalAction(finding, candidate, kept: kept, keptBundles: context.keptBundles)
        let size = action == candidate.removal && action != .none ? candidate.removalSize : nil
        let bucket = bucketOf(finding, candidate, kept: kept, action: action, pathIsApproximate: context.pathIsApproximate)
        return rebuilt(
            finding, Outcome(reason: reason, action: action, risk: risk, bucket: bucket, size: size),
            candidate: updated
        )
    }

    /// Only a copy no other working copy precedes on `PATH` is the one Terminal uses now; the next
    /// working copy takes over. A broken link resolves to nothing, so the shell skips it.
    private static func takeOver(_ finding: CleanupFinding, in group: Group) -> String? {
        let working = group.members.filter { $0.status != .brokenLink }
        guard working.first?.id == finding.id else { return nil }
        return working.dropFirst().first?.path.path
    }

    private static func riskOf(_ finding: CleanupFinding, _ candidate: CleanupCandidate) -> CleanupRisk {
        if case .inUse = finding.status { return .high }
        return candidate.processes.isEmpty ? .low : .high
    }

    private static func removalAction(
        _ finding: CleanupFinding, _ candidate: CleanupCandidate, kept: CleanupFinding, keptBundles: Set<String>
    ) -> CleanupAction {
        if sharesHomebrewPackage(finding.source, kept.source) { return .none }
        if case .uninstallApp(_, let bundle) = candidate.removal, keptBundles.contains(bundle.path) {
            return .instruction(.removeAppLinkWithAdminRights(link: finding.path.path))
        }
        return candidate.removal
    }

    private static func sharesHomebrewPackage(_ lhs: CleanupSource?, _ rhs: CleanupSource?) -> Bool {
        switch (lhs, rhs) {
        case (.homebrewFormula(let first)?, .homebrewFormula(let second)?): return first == second
        case (.homebrewCask(let first)?, .homebrewCask(let second)?): return first == second
        default: return false
        }
    }

    private static func bucketOf(
        _ finding: CleanupFinding, _ candidate: CleanupCandidate, kept: CleanupFinding,
        action: CleanupAction, pathIsApproximate: Bool
    ) -> CleanupBucket {
        let status: CleanupStatus = finding.status == .active ? .shadowed : finding.status
        let bucket = CleanupBucketPolicy.bucket(
            status: status, source: finding.source, relation: relation(finding.version, kept.version), recognisedLayout: true
        )
        guard bucket == .safe else { return bucket }
        let removable: Bool
        switch action {
        case .trash, .brew: removable = true
        default: removable = false
        }
        let needsLook = !removable || pathIsApproximate || candidate.pathRole == .active || !candidate.processes.isEmpty
        return needsLook ? .needsDecision : .safe
    }

    private static func relation(_ version: String?, _ current: String?) -> CleanupVersionRelation {
        guard let version, let current else { return .unknown }
        switch compareVersions(version, current, scheme: .semver) {
        case .orderedAscending, .orderedSame: return .olderOrSame
        case .orderedDescending: return .newer
        case .unknown: return .unknown
        }
    }

    private static func rebuilt(
        _ finding: CleanupFinding, _ outcome: Outcome, candidate: CleanupCandidate
    ) -> CleanupFinding {
        CleanupFinding(
            detector: finding.detector, tool: finding.tool, path: finding.path, realpath: finding.realpath,
            source: finding.source, version: finding.version, size: outcome.size, status: finding.status,
            reason: outcome.reason, action: outcome.action, risk: outcome.risk, bucket: outcome.bucket,
            identity: finding.identity, candidate: candidate
        )
    }
}
