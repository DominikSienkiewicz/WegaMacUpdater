import Foundation
import Testing
@testable import MacUpdaterCore

@Suite("Cask replacement artifact location")
struct CaskReplacementArtifactLocationTests {
    private let systemApplications = URL(
        fileURLWithPath: "/Applications",
        isDirectory: true
    )
    private let userApplications = URL(
        fileURLWithPath: "/Users/tester/Applications",
        isDirectory: true
    )

    @Test func missingArtifactIsUnresolved() {
        let resolver = makeResolver(existing: [])

        #expect(resolver.resolve(artifact: "Acme.app") == .unresolved)
    }

    @Test func exactlyOneExistingLocationIsResolved() {
        let systemApp = systemApplications.appendingPathComponent("Acme.app")
        let userApp = userApplications.appendingPathComponent("Acme.app")

        #expect(makeResolver(existing: [systemApp.path]).resolve(artifact: "Acme.app")
            == .resolved(systemApp))
        #expect(makeResolver(existing: [userApp.path]).resolve(artifact: "Acme.app")
            == .resolved(userApp))
    }

    @Test func duplicateSystemAndUserLocationsAreAmbiguous() {
        let systemApp = systemApplications.appendingPathComponent("Acme.app")
        let userApp = userApplications.appendingPathComponent("Acme.app")
        let resolver = makeResolver(existing: [systemApp.path, userApp.path])

        #expect(resolver.resolve(artifact: "Acme.app") == .ambiguous)
    }

    @Test func replacementWiringRejectsAmbiguityBeforeTheCompatibilityCheck() throws {
        let source = try String(
            contentsOf: packageRoot().appendingPathComponent(
                "Sources/MacUpdater/CaskReplacementSafety.swift"
            ),
            encoding: .utf8
        )
        let start = try #require(source.range(of: "static func resolveInstalledAppURL("))
        let end = try #require(source.range(
            of: "static func verify(",
            range: start.upperBound..<source.endIndex
        ))
        let resolverBody = source[start.lowerBound..<end.lowerBound]

        let locationResolution = try #require(resolverBody.range(
            of: "CaskReplacementArtifactLocationResolver().resolve("
        ))
        let compatibilityCheck = try #require(resolverBody.range(
            of: "CaskAppPathResolver().appPaths(from: installationInfo)[token]"
        ))

        #expect(locationResolution.lowerBound < compatibilityCheck.lowerBound)
    }

    private func makeResolver(existing: Set<String>) -> CaskReplacementArtifactLocationResolver {
        CaskReplacementArtifactLocationResolver(
            applicationsDirectory: systemApplications,
            userApplicationsDirectory: userApplications,
            fileExists: { existing.contains($0.path) }
        )
    }

    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
