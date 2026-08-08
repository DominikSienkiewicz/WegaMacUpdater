import Foundation
import Testing
@testable import MacUpdaterCore

/// The JDK row's "Aktualizuj przez Brew" button did nothing but raise an error:
///
///     temurin: cask nie instaluje aplikacji (.app) — nie da się go przejąć
///     ani zabezpieczyć rollbackiem.
///
/// The row was routed into the *adoption* transaction, whose whole premise is "an `.app` is
/// already on disk — snapshot it, let brew replace it, verify the replacement against the
/// snapshot". A JDK satisfies none of that: `temurin` is a `pkg` cask, so there is no app
/// artifact to snapshot and none to verify, and the gate correctly refused. The refusal was
/// right about the transaction and wrong as an outcome — it left a visible update the user
/// had no way to apply.
///
/// This suite pins the version-agnostic facts the fix rests on: a `pkg` cask is a
/// **disclosure** case, not a refusal case, and that is already how the batch upgrade path
/// treats it.
@Suite("JDK Brew action")
struct JavaRuntimeBrewActionTests {
    /// Homebrew's real metadata for `temurin`, verbatim: an `uninstall` stanza naming the
    /// installer receipt and a `pkg` stanza. No `app` anywhere.
    private static let temurinBrewJSON = """
    {
      "casks": [
        {
          "token": "temurin",
          "homepage": "https://adoptium.net/",
          "artifacts": [
            { "uninstall": [{ "pkgutil": "net.temurin.26.jdk" }] },
            { "pkg": ["OpenJDK26U-jdk_aarch64_mac_hotspot_26.0.2_10.pkg"] }
          ]
        }
      ]
    }
    """

    private func service(stdout: String) -> BrewService {
        BrewService(
            locator: BinaryLocator(brewCandidates: [URL(fileURLWithPath: "/bin/sh")]),
            runner: StubProcessRunner(result: ProcessResult(exitCode: 0, stdout: stdout, stderr: ""))
        )
    }

    @Test func aJDKCaskIsUnprotectedRatherThanUnusable() async throws {
        let profiles = try await service(stdout: Self.temurinBrewJSON).caskArtifactProfiles(tokens: ["temurin"])
        let profile = try #require(profiles.first)

        #expect(!profile.contains(.app))
        #expect(profile.contains(.pkg))

        let verdict = RollbackProtection.evaluate(profile: profile)
        #expect(verdict == .unprotected(.noAppBundle))
        // The distinction the fix turns on: this verdict is a warning the user is owed, not
        // a reason to withhold the update. `deservesWarning` is the whole vocabulary the
        // type offers for it — there is no "refuse" case, by design.
        #expect(verdict.deservesWarning)
    }

    /// A `pkg` cask needs an admin password, which is why the update cannot simply be
    /// applied silently — and why routing it through the app's existing askpass/Touch ID
    /// wiring (the same one Zoom and Parallels use) is the point of offering a button here
    /// rather than telling the user to open a terminal.
    @Test func aJDKCaskIsFlaggedAsPossiblyNeedingAnAdminPassword() async throws {
        let profiles = try await service(stdout: Self.temurinBrewJSON).caskArtifactProfiles(tokens: ["temurin"])
        #expect(try #require(profiles.first).mayRequireAdminPassword)
    }

    /// The batch upgrade path has always disclosed-and-proceeded for casks with no `.app`:
    /// `prepareForegroundCaskUpgrade` treats a token with no app path as "nothing to
    /// snapshot" rather than as a failed snapshot, and `resolveRollbackProtection` logs the
    /// missing net. The manual action refusing the same cask was the inconsistency.
    ///
    /// Asserted at source level — the same technique the neighbouring adoption gate uses —
    /// because driving the real upgrade needs brew, the keychain and a snapshot.
    @Test func theBatchUpgradePathTreatsAMissingAppPathAsNothingToSnapshot() throws {
        let source = try String(
            contentsOf: packageRoot().appendingPathComponent("Sources/MacUpdater/ScanStore+Rollback.swift"),
            encoding: .utf8
        )
        #expect(source.contains("appPaths[$0] != nil && snapshots[$0] == nil"),
                "a cask with no app path must not count as a failed snapshot, or every pkg cask would be blocked")
    }

    private func packageRoot(file: String = #filePath) -> URL {
        URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
