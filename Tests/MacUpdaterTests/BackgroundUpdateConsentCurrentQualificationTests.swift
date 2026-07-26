import Foundation
import Testing

@testable import MacUpdaterCore

@Suite("Background update consent current qualification")
struct ConsentCurrentQualificationTests {
  @Test func everyCurrentPlannerVetoHasAPerTokenVerdict() {
    let profile = CaskArtifactProfile(
      token: "iterm2",
      artifacts: [CaskArtifact(kind: .app)]
    )
    let download = CaskDownloadInfo(
      token: "iterm2",
      url: "https://example.com/app.zip",
      sha256: String(repeating: "a", count: 64)
    )

    #expect(
      qualification(
        profile: profile,
        download: download,
        context: context(policies: ["c:iterm2": .ignored])
      ) == .blocked(.ignored)
    )
    #expect(
      qualification(
        profile: profile,
        download: download,
        context: context(policies: ["c:iterm2": .pinned(version: "3.5")])
      ) == .blocked(.pinned(version: "3.5"))
    )
    #expect(
      qualification(
        profile: profile,
        download: download,
        context: context(policies: ["c:iterm2": .skipped(version: "3.5")])
      ) == .blocked(.skipped(version: "3.5"))
    )
    #expect(
      qualification(
        profile: profile,
        download: download,
        context: context(candidates: [])
      ) == .blocked(.notCurrentlyOutdated)
    )
    #expect(
      qualification(
        profile: profile,
        download: download,
        context: context(resolvedAppTokens: [])
      ) == .blocked(.installedAppUnavailable)
    )
    #expect(
      qualification(
        profile: profile,
        download: download,
        context: context(runningTokens: ["iterm2"])
      ) == .blocked(.running)
    )
    #expect(
      qualification(
        profile: profile,
        download: download,
        context: context()
      ) == .eligible
    )
  }

  private func qualification(
    profile: CaskArtifactProfile,
    download: CaskDownloadInfo,
    context: BackgroundUpdateConsentContext
  ) -> BackgroundUpdateConsentQualification {
    BackgroundUpdateConsentQualification.evaluate(
      token: "iterm2",
      profile: profile,
      download: download,
      context: context
    )
  }

  private func context(
    candidates: Set<String> = ["iterm2"],
    resolvedAppTokens: Set<String> = ["iterm2"],
    runningTokens: Set<String> = [],
    policies: [String: UpdatePolicy] = [:]
  ) -> BackgroundUpdateConsentContext {
    BackgroundUpdateConsentContext(
      candidateTokens: candidates,
      resolvedAppTokens: resolvedAppTokens,
      runningTokens: runningTokens,
      policies: policies
    )
  }
}
