import Testing
import Foundation
@testable import MacUpdaterCore

/// LT-04 — release-notes triage is one deterministic heuristic tier, and stays one.
///
/// The never-called Foundation Models tier (`onDevice`, `@Generable Triage`) is gone.
/// It cost a build-time dependency on the `FoundationModelsMacros` plugin — which only
/// ships with the full Xcode — in exchange for behaviour no user could ever reach, and
/// `README`/`CONTRIBUTING`/`scripts/check.sh` all documented that plugin as a hard build
/// requirement. The source guard below is the part `swift build` cannot express: the
/// code compiles just as happily with the dead tier back in place.
@Suite("ReleaseNotesTriage")
struct ReleaseNotesTriageTests {

    private func triageSource(file: String = #filePath) throws -> String {
        let root = URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent("Sources/MacUpdaterCore/ReleaseNotesTriage.swift"),
            encoding: .utf8
        )
    }

    // MARK: The heuristic tier — the one that actually runs

    @Test func flagsExplicitVulnerabilityIdentifiers() {
        #expect(ReleaseNotesTriage.heuristic("Fixes CVE-2026-1234 in the parser").isLikelySecurityFix)
        #expect(ReleaseNotesTriage.heuristic("Addresses CWE-79 in the renderer").isLikelySecurityFix)
    }

    @Test func flagsVulnerabilityClassesByName() {
        for notes in ["Patched a sandbox escape", "Fixes a use-after-free", "Blocks an XSS vector",
                      "Prevents privilege escalation", "Stops a zero-day exploit"] {
            #expect(ReleaseNotesTriage.heuristic(notes).isLikelySecurityFix, "should flag: \(notes)")
        }
    }

    @Test func doesNotFlagOrdinaryFeatureNotes() {
        #expect(ReleaseNotesTriage.heuristic("Added dark mode and faster startup").isLikelySecurityFix == false)
        #expect(ReleaseNotesTriage.heuristic("").isLikelySecurityFix == false)
    }

    @Test func matchIsCaseInsensitiveAndReportsEverySignal() {
        let result = ReleaseNotesTriage.heuristic("SECURITY: fixes a buffer OVERFLOW and an injection")
        #expect(result.isLikelySecurityFix)
        #expect(result.matchedSignals.sorted() == ["injection", "overflow", "security"])
    }

    @Test func nonMatchingNotesReportNoSignals() {
        #expect(ReleaseNotesTriage.heuristic("Performance improvements").matchedSignals.isEmpty)
    }

    // MARK: LT-04 — the dead on-device tier must not come back unnoticed

    @Test func triageDoesNotDependOnFoundationModels() throws {
        let source = try triageSource()
        #expect(!source.contains("import FoundationModels"),
                "LT-04: importing FoundationModels reintroduces the Xcode-only macro plugin dependency")
        #expect(!source.contains("@Generable"),
                "LT-04: @Generable needs the FoundationModelsMacros plugin the build no longer requires")
        #expect(!source.contains("@Guide"),
                "LT-04: @Guide needs the FoundationModelsMacros plugin the build no longer requires")
        #expect(!source.contains("LanguageModelSession"),
                "LT-04: an on-device model tier must arrive with a call site, not as dead code")
    }

    @Test func triageStaysSynchronousSoViewBodiesAndFiltersCanCallIt() throws {
        let source = try triageSource()
        #expect(!source.contains(") async"),
                "LT-04: the security-only list filter and the badge view bodies call triage synchronously")
    }
}
