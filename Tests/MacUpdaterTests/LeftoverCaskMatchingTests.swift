import Foundation
import Testing
@testable import MacUpdaterCore

@Suite("Leftover cask matching")
struct LeftoverCaskMatchingTests {
    private func app(
        name: String,
        bundleIdentifier: String? = nil,
        caskToken: String? = nil,
        provenance: CaskMatchProvenance? = nil,
        path: URL? = nil
    ) -> ApplicationInfo {
        ApplicationInfo(
            path: path ?? URL(filePath: "/Applications/\(name).app", directoryHint: .isDirectory),
            name: name,
            bundleIdentifier: bundleIdentifier,
            version: "1.0",
            installDate: nil,
            updateDate: nil,
            isManagedByBrew: caskToken != nil,
            caskToken: caskToken,
            caskMatchProvenance: provenance
        )
    }

    @Test func tokenMatchCarriesZapPaths() {
        let obsidian = app(name: "Obsidian")
        let cask = BrewCask(token: "obsidian", name: ["Obsidian"], zapTrashPaths: ["~/Library/Application Support/obsidian"])

        let evidence = LeftoverCaskMatching.evidence(for: [obsidian], casks: [cask])

        #expect(evidence[obsidian.id] == LeftoverCaskEvidence(
            token: "obsidian",
            zapTrashPaths: ["~/Library/Application Support/obsidian"],
            provenance: .token
        ))
    }

    @Test func managedAppKeepsItsToken() {
        let managed = app(name: "Some Editor", caskToken: "editor-cask", provenance: .installedToken)
        let cask = BrewCask(token: "editor-cask", name: ["Other"], zapTrashPaths: ["~/Library/Caches/editor"])

        let evidence = LeftoverCaskMatching.evidence(for: [managed], casks: [cask])

        #expect(evidence[managed.id] == LeftoverCaskEvidence(
            token: "editor-cask",
            zapTrashPaths: ["~/Library/Caches/editor"],
            provenance: .installedToken
        ))
    }

    @Test func managedAppWithoutProvenanceFallsBackToTokenProvenance() {
        let managed = app(name: "Some Editor", caskToken: "editor-cask")
        let cask = BrewCask(token: "editor-cask", name: ["Other"], zapTrashPaths: ["~/Library/Caches/editor"])

        let evidence = LeftoverCaskMatching.evidence(for: [managed], casks: [cask])

        #expect(evidence[managed.id]?.provenance == .token)
    }

    @Test func managedAppWhoseCaskIsMissingGivesNoEvidence() {
        let managed = app(name: "Some Editor", caskToken: "gone", provenance: .installedToken)

        #expect(LeftoverCaskMatching.evidence(for: [managed], casks: []).isEmpty)
    }

    @Test func channelRefusedMatchGivesNoEvidence() {
        let preview = app(name: "Zed", bundleIdentifier: "dev.zed.Zed-Preview")
        let cask = BrewCask(token: "zed", name: ["Zed"], zapTrashPaths: ["~/Library/Application Support/Zed"])

        #expect(LeftoverCaskMatching.evidence(for: [preview], casks: [cask]).isEmpty)
    }

    @Test func noMatchGivesNoEvidence() {
        let unknown = app(name: "Totally Unknown Thing")
        let cask = BrewCask(token: "obsidian", name: ["Obsidian"], zapTrashPaths: ["~/Library/Caches/obsidian"])

        #expect(LeftoverCaskMatching.evidence(for: [unknown], casks: [cask]).isEmpty)
    }

    @Test func leftoverAppFromApplicationInfo() {
        let home = NSHomeDirectory()
        let installed = app(
            name: "Display Name",
            bundleIdentifier: "com.example.app",
            path: URL(filePath: "\(home)/Applications/File Name.app", directoryHint: .isDirectory)
        )
        let evidence = LeftoverCaskEvidence(token: "t", zapTrashPaths: [], provenance: .token)

        let leftoverApp = LeftoverApp(installed, teamIdentifier: "TEAM123456", cask: evidence)

        #expect(leftoverApp == LeftoverApp(
            id: installed.id,
            name: "Display Name",
            fileName: "File Name",
            path: "~/Applications/File Name.app",
            bundleIdentifier: "com.example.app",
            teamIdentifier: "TEAM123456",
            cask: evidence
        ))
    }
}
