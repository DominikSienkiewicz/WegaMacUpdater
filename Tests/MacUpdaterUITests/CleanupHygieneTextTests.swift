import XCTest
import MacUpdaterCore
@testable import WegaMacUpdater

@MainActor
final class CleanupHygieneTextTests: XCTestCase {
    func testDeadEntryStatusIsTranslated() {
        withLanguage(.pl) { XCTAssertEqual(CleanupPresentation.statusText(.deadEntry), "martwy wpis") }
        XCTAssertEqual(Translations.en["martwy wpis"], "dead entry")
    }

    func testDetectorNamesAreTranslated() {
        XCTAssertEqual(Translations.en["higiena PATH"], "PATH hygiene")
        XCTAssertEqual(Translations.en["mapa „Pliki i foldery”"], "Files and Folders map")
    }

    func testShellFileInstructionSaysWhenTheEntryWasAddedDynamically() {
        withLanguage(.pl) {
            let dynamic = CleanupPresentation.instructionText(.editShellFiles(entry: "~/x", locations: []))
            let located = CleanupPresentation.instructionText(
                .editShellFiles(entry: "~/x", locations: [CleanupShellFileLocation(file: "~/.zshrc", line: 3)])
            )
            XCTAssertFalse(dynamic.isEmpty)
            XCTAssertNotEqual(dynamic, located)
            XCTAssertTrue(located.contains("~/.zshrc:3"), located)
        }
    }

    func testSwitchOffInstructionNamesTheSettingsPane() {
        withLanguage(.pl) {
            XCTAssertTrue(CleanupPresentation.instructionText(.switchOffInFilesAndFolders).contains("Pliki i foldery"))
        }
    }

    func testEveryNewNoteKindHasText() {
        for kind in [CleanupDetectorNote.Kind.tccUnreadable, .tccUnsupportedSchema, .tccMapEmpty] {
            let text = CleanupPresentation.noteText(CleanupDetectorNote(detector: .tccMap, kind: kind))
            XCTAssertFalse(text.isEmpty, "\(kind)")
        }
    }

    /// `reasonText` and `hygieneReasonText` hand each other the reasons they do not spell. A reason
    /// handed over by both would compile and recurse for ever, so one value of every case is
    /// rendered here: a mis-routed reason crashes this test, not the app.
    func testEveryReasonRendersWithoutBouncingBetweenTheTextTables() {
        for kind in ReasonKind.allCases {
            let reason = kind.sample
            XCTAssertEqual(reason.kind, kind, "the sample of \(kind) is another case")
            for language in [AppLanguage.pl, .en] {
                let text = withLanguage(language) { CleanupPresentation.reasonText(reason) }
                XCTAssertFalse(text.isEmpty, "\(kind) in \(language)")
            }
        }
    }

    /// The row's detail names the manager through its source ("menedżer wersji mise"), so the
    /// reason says what a shim does rather than naming it again.
    func testVersionManagerShimSaysItRunsTheManagersVersion() {
        let polish = withLanguage(.pl) { CleanupPresentation.reasonText(.versionManagerShim) }
        let english = withLanguage(.en) { CleanupPresentation.reasonText(.versionManagerShim) }
        XCTAssertEqual(polish, "shim: uruchamia wersję, którą wskazuje menedżer")
        XCTAssertEqual(english, "shim: runs the version the manager selects")
    }

    func testEveryNewReasonHasTextInBothLanguages() {
        let reasons: [CleanupReason] = [
            .missingPathEntry, .repeatedPathEntry(count: 2), .samePlaceAs(path: "~/a"), .nestedIn(parent: "~/b"),
            .olderCopyWins(version: "1.0.0", newer: "~/n", newerVersion: "2.0.0"),
            .tccEntry(grants: [CleanupTCCGrant(service: .documents, allowed: true)], link: nil),
            .tccEntryFileGone(grants: [CleanupTCCGrant(service: .downloads, allowed: false)]),
            .keptInstead(path: "~/bin/x"), .keptByChoice, .noCopyKept,
        ]
        for reason in reasons {
            let polish = withLanguage(.pl) { CleanupPresentation.reasonText(reason) }
            let english = withLanguage(.en) { CleanupPresentation.reasonText(reason) }
            XCTAssertFalse(polish.isEmpty, "\(reason)")
            XCTAssertNotEqual(polish, english, "\(reason)")
        }
    }
}

/// Every `CleanupReason` case, each with one sample value. `sample` and `CleanupReason.kind` have no
/// `default`, so a reason added later does not compile here until it has a case and a sample.
private enum ReasonKind: CaseIterable {
    case olderVersion, newerVersion, shadowedBy, systemCopy, versionManagerShim, managedByApp, staleSinceBoot, keptSinceBoot
    case unknownVersionDirectory, currentVersion, protectedLocation, brokenLink, requiredBy, homebrewLeftovers
    case homebrewKeptVersions, installedOnlyAsDependency, recentlyUpgraded, notRequiredByProjects, requiredByProjects
    case unusedGradleDistribution, unreferencedJDK, systemJDK, ideVersionNotInstalled, ideNotFound, newerThanInstalledIDE
    case missingPathEntry, repeatedPathEntry, samePlaceAs, nestedIn, olderCopyWins, tccEntry, tccEntryFileGone
    case keptInstead, keptByChoice, noCopyKept

    var sample: CleanupReason {
        switch self {
        case .olderVersion: .olderVersion(current: "2.0")
        case .newerVersion: .newerVersion(current: "1.0")
        case .shadowedBy: .shadowedBy(path: "~/.local/bin/x")
        case .systemCopy: .systemCopy
        case .versionManagerShim: .versionManagerShim
        case .managedByApp: .managedByApp(owner: "App")
        case .staleSinceBoot: .staleSinceBoot(count: 2)
        case .keptSinceBoot: .keptSinceBoot(count: 1)
        case .unknownVersionDirectory: .unknownVersionDirectory
        case .currentVersion: .currentVersion
        case .protectedLocation: .protectedLocation
        case .brokenLink: .brokenLink
        case .requiredBy: .requiredBy(["a"])
        case .homebrewLeftovers: .homebrewLeftovers(items: 3)
        case .homebrewKeptVersions: .homebrewKeptVersions(count: 2)
        case .installedOnlyAsDependency: .installedOnlyAsDependency
        case .recentlyUpgraded: .recentlyUpgraded
        case .notRequiredByProjects: .notRequiredByProjects
        case .requiredByProjects: .requiredByProjects
        case .unusedGradleDistribution: .unusedGradleDistribution
        case .unreferencedJDK: .unreferencedJDK(major: 17)
        case .systemJDK: .systemJDK(major: 21)
        case .ideVersionNotInstalled: .ideVersionNotInstalled(installed: ["2025.2"])
        case .ideNotFound: .ideNotFound
        case .newerThanInstalledIDE: .newerThanInstalledIDE(installed: ["2025.2"])
        case .missingPathEntry: .missingPathEntry
        case .repeatedPathEntry: .repeatedPathEntry(count: 2)
        case .samePlaceAs: .samePlaceAs(path: "~/a")
        case .nestedIn: .nestedIn(parent: "~/b")
        case .olderCopyWins: .olderCopyWins(version: "1.0.0", newer: "~/n", newerVersion: "2.0.0")
        case .tccEntry: .tccEntry(grants: [CleanupTCCGrant(service: .documents, allowed: true)], link: nil)
        case .tccEntryFileGone: .tccEntryFileGone(grants: [CleanupTCCGrant(service: .downloads, allowed: false)])
        case .keptInstead: .keptInstead(path: "~/bin/x")
        case .keptByChoice: .keptByChoice
        case .noCopyKept: .noCopyKept
        }
    }
}

private extension CleanupReason {
    var kind: ReasonKind {
        switch self {
        case .olderVersion: .olderVersion
        case .newerVersion: .newerVersion
        case .shadowedBy: .shadowedBy
        case .systemCopy: .systemCopy
        case .versionManagerShim: .versionManagerShim
        case .managedByApp: .managedByApp
        case .staleSinceBoot: .staleSinceBoot
        case .keptSinceBoot: .keptSinceBoot
        case .unknownVersionDirectory: .unknownVersionDirectory
        case .currentVersion: .currentVersion
        case .protectedLocation: .protectedLocation
        case .brokenLink: .brokenLink
        case .requiredBy: .requiredBy
        case .homebrewLeftovers: .homebrewLeftovers
        case .homebrewKeptVersions: .homebrewKeptVersions
        case .installedOnlyAsDependency: .installedOnlyAsDependency
        case .recentlyUpgraded: .recentlyUpgraded
        case .notRequiredByProjects: .notRequiredByProjects
        case .requiredByProjects: .requiredByProjects
        case .unusedGradleDistribution: .unusedGradleDistribution
        case .unreferencedJDK: .unreferencedJDK
        case .systemJDK: .systemJDK
        case .ideVersionNotInstalled: .ideVersionNotInstalled
        case .ideNotFound: .ideNotFound
        case .newerThanInstalledIDE: .newerThanInstalledIDE
        case .missingPathEntry: .missingPathEntry
        case .repeatedPathEntry: .repeatedPathEntry
        case .samePlaceAs: .samePlaceAs
        case .nestedIn: .nestedIn
        case .olderCopyWins: .olderCopyWins
        case .tccEntry: .tccEntry
        case .tccEntryFileGone: .tccEntryFileGone
        case .keptInstead: .keptInstead
        case .keptByChoice: .keptByChoice
        case .noCopyKept: .noCopyKept
        }
    }
}
