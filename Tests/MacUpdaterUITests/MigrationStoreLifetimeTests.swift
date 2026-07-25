import Foundation
import Testing

@Suite("Migration store lifetime")
struct MigrationStoreLifetimeTests {
    private func packageRoot(file: String = #filePath) -> URL {
        URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    @Test func appOwnsMigrationStateAboveTheLanguageIdentityBoundary() throws {
        let source = try String(
            contentsOf: packageRoot().appendingPathComponent("Sources/MacUpdater/MacUpdaterApp.swift"),
            encoding: .utf8
        )
        let ownership = try #require(source.range(of: "@StateObject private var migration = MigrationStore()"))
        let injection = try #require(source.range(of: ".environmentObject(migration)"))
        let languageIdentity = try #require(source.range(
            of: ".id(localization.language)",
            range: injection.upperBound..<source.endIndex
        ))

        #expect(ownership.lowerBound < injection.lowerBound)
        #expect(injection.lowerBound < languageIdentity.lowerBound)
    }
}
