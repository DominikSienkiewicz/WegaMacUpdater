import Foundation
import MacUpdaterCore
import Testing

@testable import WegaMacUpdater

@Suite("Touch ID — what turning it off says") @MainActor
struct TouchIDDisableCopyTests {
    private let fallback = "/usr/local/etc/pam.d/sudo_local"

    @Test func everyOutcomeSaysWhatHappenedAndWhatToDoNext() {
        withLanguage(.pl) {
            #expect(TouchIDDisableCopy.line(for: .removed(lines: 1), stillEnabled: false)
                    == "Touch ID dla sudo wyłączone. W nowym oknie Terminala sprawdź „sudo -k; sudo true” — zapyta o hasło.")
            #expect(TouchIDDisableCopy.line(for: .nothingToRemove, stillEnabled: true)
                    == "Touch ID dla sudo włącza tu linia zapisana inaczej niż dokładna dyrektywa, którą umiem usunąć, więc jej nie zmieniłam. Wyłączysz ją ręcznie według przewodnika.")
            #expect(TouchIDDisableCopy.line(for: .removed(lines: 1), stillEnabled: true)
                    == TouchIDDisableCopy.line(for: .nothingToRemove, stillEnabled: true))
            #expect(TouchIDDisableCopy.line(for: .nothingToRemove, stillEnabled: false) == "Touch ID dla sudo jest już wyłączone.")
            for refusal in [TouchIDSudoDisableRefusal.noConsoleUser, .callerNotConsoleUser, .callerNotAdministrator] {
                #expect(TouchIDDisableCopy.line(for: .refused(refusal), stillEnabled: true)
                        == "Touch ID dla sudo może wyłączyć tylko administrator zalogowany przy tym Macu.")
            }
            for refusal in [TouchIDSudoDisableRefusal.tooLarge, .unreadable, .lineContinuation] {
                #expect(TouchIDDisableCopy.line(for: .refused(refusal), stillEnabled: true)
                        == "Plik /etc/pam.d/sudo_local wygląda inaczej, niż się spodziewam, więc go nie zmieniłam. Wyłączysz Touch ID ręcznie według przewodnika.")
            }
            // RC2-7: −4 and −5 from the helper give recoveryOS advice only, as on the way in.
            let recovery = "Nie wpisuj hasła do sudo, dopóki tego nie naprawisz — także gdy Wega poprosi o nie przy aktualizacji: sudo czyta te ustawienia. Napraw je z trybu odzyskiwania według przewodnika."
            let unsafe = TouchIDDisableCopy.line(for: .refused(.unsafeOwnership), stillEnabled: true)
            #expect(unsafe == "Plik /etc/pam.d/sudo_local albo katalog /etc/pam.d może zmieniać ktoś poza rootem albo wygląda inaczej, niż powinien. To problem bezpieczeństwa: kto może tam pisać, może dostać uprawnienia roota bez hasła. Nie zmieniłam go. Sprawdź go według przewodnika. " + recovery)
            #expect(unsafe.contains("roota bez hasła") && unsafe.contains("przewodnika"))
            #expect(TouchIDDisableCopy.line(for: .refused(.notRegularFile), stillEnabled: true)
                    == "Plik /etc/pam.d/sudo_local nie jest zwykłym plikiem, więc go nie zmieniłam. sudo może przez niego czytać ustawienia spoza /etc/pam.d. " + recovery)
            for refusal in [TouchIDSudoDisableRefusal.notRegularFile, .unsafeOwnership] {
                #expect(TouchIDDisableCopy.line(for: .refused(refusal), stillEnabled: true) == TouchIDEnableCopy.unsafePolicyNote(refusal),
                        "\(refusal): the same text in both directions")
            }
            #expect(TouchIDDisableCopy.line(for: .refused(.fallbackPolicyPresent), stillEnabled: true, fallbackPath: fallback)
                    == "Po usunięciu tej dyrektywy sudo czytałby też plik /usr/local/etc/pam.d/sudo_local — jeśli go nie tworzyłeś, może pozwolić sudo pominąć hasło. Nic nie zmieniłam; sprawdź go według przewodnika.")
            #expect(TouchIDDisableCopy.line(for: .refused(.fallbackPolicyPresent), stillEnabled: true, fallbackPath: nil)
                    == "Po usunięciu tej dyrektywy sudo czytałby też inny plik ustawień PAM, więc nic nie zmieniłam. Sprawdź przewodnik.")
            #expect(TouchIDDisableCopy.line(for: .refused(.fallbackPolicyPresent), stillEnabled: true, fallbackPath: "/tmp/not-a-policy-path")
                    == TouchIDDisableCopy.line(for: .refused(.fallbackPolicyPresent), stillEnabled: true, fallbackPath: nil),
                    "only the policy paths the app itself knows are ever shown")
            #expect(TouchIDDisableCopy.line(for: .refused(.changedDuringOperation), stillEnabled: true)
                    == "Plik zmienił się w trakcie mojej pracy, więc go nie ruszyłam. Spróbuj jeszcze raz.")
            #expect(TouchIDDisableCopy.line(for: .refused(.otherDirectivesPresent), stillEnabled: true)
                    == "W pliku są też inne ustawienia sudo, więc go nie zmieniłam. Wyłączysz Touch ID ręcznie według przewodnika.")
            #expect(TouchIDDisableCopy.line(for: .restoredAfterFailure, stillEnabled: true)
                    == "Zapis się nie udał. Plik jest taki jak przedtem, nic się nie zmieniło.")
            #expect(TouchIDDisableCopy.line(for: .rollbackFailed(backupPath: "/etc/pam.d/.b"), stillEnabled: true)
                    == "Zapis i przywrócenie się nie udały. Poprzedni plik odłożyłam pod /etc/pam.d/.b. Przywróć go według przewodnika.")
            #expect(TouchIDDisableCopy.afterHelperError(stillEnabled: true)
                    == "Pomocnik Wegi nie odpowiedział, a Touch ID dla sudo jest nadal włączone. Spróbuj ponownie albo wyłącz je ręcznie według przewodnika.")
            #expect(TouchIDDisableCopy.afterHelperError(stillEnabled: false) == TouchIDDisableCopy.line(for: .removed(lines: 1), stillEnabled: false),
                    "a timeout is not 'nothing changed': the file is read again")
            #expect(TouchIDDisableCopy.outdatedHelper
                    == "Pomocnik Wegi jest nieaktualny albo nie odpowiada. W Ustawieniach usuń go i zainstaluj ponownie albo uruchom Maca ponownie, a wtedy wyłączysz tu Touch ID dla sudo.")
            #expect(TouchIDDisableCopy.localDirectoryWarning(path: "/usr/local/etc")
                    == "Katalog /usr/local/etc może zmieniać ktoś poza rootem. Gdy Touch ID dla sudo jest wyłączone, sudo czyta też ustawienia z tego miejsca, więc program działający na Twoim koncie mógłby tam dodać takie, które pozwolą sudo pominąć hasło. Zajrzyj do przewodnika.")
        }
        for refusal in TouchIDSudoDisableRefusal.allCases {
            #expect(!TouchIDDisableCopy.line(for: .refused(refusal), stillEnabled: true).isEmpty, "\(refusal)")
        }
        withLanguage(.en) {
            #expect(TouchIDDisableCopy.line(for: .removed(lines: 1), stillEnabled: false)
                    == "Touch ID for sudo is off. In a new Terminal window, check “sudo -k; sudo true” — it asks for your password.")
            #expect(TouchIDDisableCopy.line(for: .nothingToRemove, stillEnabled: true)
                    == "A line written differently from the exact directive I can remove turns on Touch ID for sudo here, so I left it alone. Turn it off by hand with the user guide.")
            #expect(TouchIDDisableCopy.line(for: .refused(.fallbackPolicyPresent), stillEnabled: true, fallbackPath: fallback)
                    == "After removing this directive, sudo would also read /usr/local/etc/pam.d/sudo_local — if you didn't create it, it may let sudo skip the password. I changed nothing; check it with the user guide.")
            #expect(TouchIDDisableCopy.line(for: .refused(.changedDuringOperation), stillEnabled: true)
                    == "The file changed while I was working, so I didn't touch it. Try again.")
            #expect(TouchIDDisableCopy.outdatedHelper.contains("restart your Mac"))
            #expect(tr("Wyłącz Touch ID dla sudo") == "Turn Off Touch ID for sudo")
            #expect(tr("Bez pomocnika Wegi wyłączysz je ręcznie.") == "Without the Wega helper, you turn it off by hand.")
            for refusal in TouchIDSudoDisableRefusal.allCases {
                let line = TouchIDDisableCopy.line(for: .refused(refusal), stillEnabled: true)
                #expect(!line.contains(where: { "ąćęłńóśźż".contains($0) }), "\(refusal): \(line)")
            }
        }
    }

    @Test func theLineForANonMatchingFileNeverClaimsWegaWroteIt() {
        withLanguage(.pl) {
            let line = TouchIDDisableCopy.line(for: .nothingToRemove, stillEnabled: true)
            #expect(!line.contains("Wega") && !line.contains("Wegi") && !line.contains("dopisała"))
            #expect(line.contains("dokładna dyrektywa"))
        }
    }

    // MARK: - Facts the app can see before the click

    private func directory(owner: UInt32 = 0, permissions: UInt16 = 0o755, acl: PAMAccessControlState = .absent,
                           isDirectory: Bool = true) -> PAMPolicyDirectoryFacts {
        PAMPolicyDirectoryFacts(isDirectory: isDirectory, ownerUID: owner, permissions: permissions, accessControl: acl)
    }

    private func file(owner: UInt32 = 0, permissions: UInt16 = 0o444, acl: PAMAccessControlState = .absent,
                      isRegular: Bool = true) -> PAMPolicyFileFacts {
        PAMPolicyFileFacts(
            isRegularFile: isRegular, identity: PAMFileIdentity(device: 1, inode: 2), linkCount: 1, ownerUID: owner,
            groupID: 0, permissions: permissions, accessControl: acl, size: 40, modifiedNanoseconds: 0)
    }

    private func evaluate(
        directory: PAMPolicyDirectoryFacts? = nil, sudoLocal: PAMPolicyFileFacts? = nil,
        local: [TouchIDDisablePreflight.LocalDirectory] = [], fallbacks: [String] = []
    ) -> TouchIDDisablePreflight {
        TouchIDDisablePreflight.evaluate(
            policyDirectory: directory ?? self.directory(), sudoLocal: sudoLocal ?? file(), localDirectories: local,
            existingFallbackPaths: fallbacks)
    }

    @Test func aSafePolicyDirectoryAndFileLeaveTheButton() {
        #expect(evaluate() == .clear)
        #expect(evaluate(sudoLocal: nil).refusal == nil)
        let missing = TouchIDDisablePreflight.evaluate(policyDirectory: nil, sudoLocal: nil, localDirectories: [], existingFallbackPaths: [])
        #expect(missing.refusal == nil, "what the app cannot see, the helper decides")
    }

    @Test func onlyAnObservedUnsafeConditionHidesTheButton() {
        #expect(evaluate(sudoLocal: file(owner: 501)).refusal == .unsafeOwnership)
        #expect(evaluate(sudoLocal: file(permissions: 0o664)).refusal == .unsafeOwnership)
        #expect(evaluate(sudoLocal: file(permissions: 0o446)).refusal == .unsafeOwnership)
        #expect(evaluate(sudoLocal: file(acl: .present)).refusal == .unsafeOwnership)
        #expect(evaluate(sudoLocal: file(isRegular: false)).refusal == .notRegularFile)
        #expect(evaluate(directory: directory(owner: 501)).refusal == .unsafeOwnership)
        #expect(evaluate(directory: directory(permissions: 0o775)).refusal == .unsafeOwnership)
        #expect(evaluate(directory: directory(acl: .present)).refusal == .unsafeOwnership)
        #expect(evaluate(directory: directory(isDirectory: false)).refusal == .unsafeOwnership)
        #expect(evaluate(sudoLocal: file(acl: .unreadable)).refusal == nil, "an app-side ACL read error is not an observation")
        #expect(evaluate(directory: directory(acl: .unreadable)).refusal == nil)
        #expect(evaluate(sudoLocal: file(permissions: 0o444)).refusal == nil)
    }

    @Test func anyLocalPolicyDirectoryOthersCanChangeWarnsOnTheNearestUnsafeOne() {
        func local(_ path: String, owner: UInt32 = 0, permissions: UInt16 = 0o755, link: Bool = false) -> TouchIDDisablePreflight.LocalDirectory {
            .init(path: path, facts: .init(isSymbolicLink: link, ownerUID: owner, permissions: permissions))
        }
        let missing = { (path: String) in TouchIDDisablePreflight.LocalDirectory(path: path, facts: nil) }
        #expect(evaluate(local: [local("/usr/local/etc", owner: 501)]).unsafeLocalDirectory == "/usr/local/etc")
        #expect(evaluate(local: [local("/usr/local/etc", permissions: 0o775)]).unsafeLocalDirectory == "/usr/local/etc")
        #expect(evaluate(local: [local("/usr/local/etc", link: true)]).unsafeLocalDirectory == "/usr/local/etc")
        #expect(evaluate(local: [local("/usr/local/etc")]).unsafeLocalDirectory == nil)
        #expect(evaluate(local: [missing("/usr/local/etc"), missing("/usr/local")]).unsafeLocalDirectory == nil)
        let chain = [missing("/usr/local/etc/pam.d"), missing("/usr/local/etc"), local("/usr/local", owner: 501)]
        #expect(evaluate(local: chain).unsafeLocalDirectory == "/usr/local")
        let safePamD = [local("/usr/local/etc/pam.d"), local("/usr/local/etc", owner: 501), local("/usr/local")]
        #expect(evaluate(local: safePamD).unsafeLocalDirectory == "/usr/local/etc",
                "whoever can write a parent can rename a safe pam.d away and put their own in its place")
        let safeBelowLocal = [local("/usr/local/etc/pam.d"), local("/usr/local/etc"), local("/usr/local", permissions: 0o777)]
        #expect(evaluate(local: safeBelowLocal).unsafeLocalDirectory == "/usr/local")
        let linkedLocal = [missing("/usr/local/etc/pam.d"), local("/usr/local/etc"), local("/usr/local", link: true)]
        #expect(evaluate(local: linkedLocal).unsafeLocalDirectory == "/usr/local", "a missing pam.d does not end the chain")
        let bothUnsafe = [local("/usr/local/etc/pam.d", owner: 501), local("/usr/local/etc", permissions: 0o757), local("/usr/local")]
        #expect(evaluate(local: bothUnsafe).unsafeLocalDirectory == "/usr/local/etc/pam.d", "the nearest unsafe one is named")
        let allSafe = [local("/usr/local/etc/pam.d"), local("/usr/local/etc"), local("/usr/local")]
        #expect(evaluate(local: allSafe).unsafeLocalDirectory == nil)
        #expect(TouchIDDisablePreflight.localCandidatePaths == ["/usr/local/etc/pam.d", "/usr/local/etc", "/usr/local"])
    }

    @Test func theFirstExistingLaterPolicyFileIsTheOneNamed() {
        #expect(evaluate(fallbacks: ["/usr/local/etc/pam.conf", "/usr/share/pam.d/sudo_local"]).fallbackPath == "/usr/local/etc/pam.conf")
        #expect(evaluate().fallbackPath == nil)
    }

    // MARK: - Source pins

    @Test func theCardOffersTurningOffOnlyWithTheHelperAndTheGuideOtherwise() throws {
        let info = try source("Sources/MacUpdater/InfoView.swift")
        let card = try slice(info, from: "private var touchIDCard: some View", to: "// MARK: - GitHub token")
        #expect(card.contains("touchIDController.disableOffer"))
        #expect(card.contains("case .available:"))
        #expect(card.contains("Label(tr(\"Wyłącz Touch ID dla sudo\"), systemImage: \"touchid\")"))
        #expect(card.contains(".disabled(disablingTouchID)"))
        #expect(card.contains("Link(tr(\"Jak wyłączyć Touch ID dla sudo\"), destination: AppEndpoints.shared.touchIDGuideURL)"))
        #expect(card.contains("TouchIDDisableCopy.outdatedHelper"))
        #expect(card.contains("tr(\"Bez pomocnika Wegi wyłączysz je ręcznie.\")"))
        #expect(info.contains("touchIDController.disable(onWegaState: relay(.touchID))"))
        for file in ["InfoView", "ReadinessCard", "TrustSettingsCard"] {
            let text = try source("Sources/MacUpdater/\(file).swift")
            #expect(text.contains("włączyć albo wyłączyć Touch ID dla sudo"), "\(file)")
        }
        let trust = try source("Sources/MacUpdater/TrustSettingsCard.swift")
        #expect(trust.contains("Wyłączysz je w karcie Touch ID, gdy pomocnik Wegi jest zainstalowany, albo ręcznie według przewodnika."))
    }

    @Test func onlyTheLiveControllerEverAsksTheHelperToTurnTouchIDOff() throws {
        let app = try sources(in: "Sources/MacUpdater")
        let callers = app.filter { $0.text.contains("disableTouchIDForSudo()") }.map(\.name)
        #expect(callers == ["TouchIDSetupController.swift"], "\(callers)")
        let controller = try #require(app.first { $0.name == "TouchIDSetupController.swift" }).text
        let live = try slice(controller, from: "static let live", to: "@Published private(set) var state")
        #expect(live.contains("disableWithHelper: { try await PrivilegedHelperClient.shared.disableTouchIDForSudo() }"))
        for target in ["Sources/MacUpdater", "Sources/MacUpdaterCore"] {
            #expect(try sources(in: target).allSatisfy { !$0.text.contains("pam_start") }, "\(target) never starts a PAM conversation")
        }
    }

    private func root(file: String = #filePath) -> URL {
        URL(filePath: file, directoryHint: .notDirectory)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: root().appending(path: relativePath, directoryHint: .notDirectory), encoding: .utf8)
    }

    private func sources(in directory: String) throws -> [(name: String, text: String)] {
        let base = root().appending(path: directory, directoryHint: .isDirectory)
        let files = try #require(FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil))
        return try files.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
            .map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
    }

    private func slice(_ text: String, from start: String, to end: String) throws -> String {
        let lower = try #require(text.range(of: start)).upperBound
        let upper = try #require(text[lower...].range(of: end)).lowerBound
        return String(text[lower..<upper])
    }
}
