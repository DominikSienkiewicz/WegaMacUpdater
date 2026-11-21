import Foundation
import MacUpdaterCore
import Testing

@testable import WegaMacUpdater

/// What Wega says after asking the helper to turn Touch ID for sudo on (Aneks E.6, E.9): every
/// refusal names its reason and the next step, and an unsafe policy gets recoveryOS advice only.
@Suite("Touch ID — what turning it on says") @MainActor
struct TouchIDEnableCopyTests {
    private let backup = "/etc/pam.d/.sudo_local.wega-backup-0A1B"
    private let recovery = "Nie wpisuj hasła do sudo, dopóki tego nie naprawisz — także gdy Wega poprosi o nie przy aktualizacji: sudo czyta te ustawienia. Napraw je z trybu odzyskiwania według przewodnika."

    @Test func everyResultSaysWhatHappenedAndWhatToDoNext() {
        withLanguage(.pl) {
            #expect(TouchIDEnableCopy.line(for: .enabled, isEnabled: true) == "Touch ID podpięty pod sudo.")
            #expect(TouchIDEnableCopy.line(for: .alreadyEnabled, isEnabled: true) == "Touch ID podpięty pod sudo.")
            #expect(TouchIDEnableCopy.line(for: .enabled, isEnabled: false)
                    == "Zapisałam plik, ale Touch ID dla sudo nadal nie wygląda na włączone. Sprawdź /etc/pam.d/sudo_local według przewodnika.",
                    "RC2-2: success only when the file read again says so")
            #expect(TouchIDEnableCopy.line(for: .alreadyEnabled, isEnabled: false)
                    == "Plik /etc/pam.d/sudo_local ma już linię z Touch ID, więc niczego nie zapisałam, ale nie widzę, żeby Touch ID dla sudo było włączone. Sprawdź plik według przewodnika.",
                    "I2: code 0 means nothing was written, so the line never says it was")
            for refusal in [TouchIDSudoEnableRefusal.tooLarge, .unreadable] {
                #expect(TouchIDEnableCopy.line(for: .refused(refusal), isEnabled: false)
                        == "Plik /etc/pam.d/sudo_local wygląda inaczej, niż się spodziewam, więc go nie zmieniłam. Sprawdź go według przewodnika.",
                        "the guide has no steps for turning it on by hand")
            }
            #expect(TouchIDEnableCopy.line(for: .refused(.changedDuringOperation), isEnabled: false)
                    == "Plik zmienił się w trakcie mojej pracy, więc go nie ruszyłam. Spróbuj jeszcze raz.")
            #expect(TouchIDEnableCopy.line(for: .restoredAfterFailure, isEnabled: false)
                    == "Zapis się nie udał. Plik jest taki jak przedtem, nic się nie zmieniło.")
            #expect(TouchIDEnableCopy.line(for: .rollbackFailed(backupPath: backup), isEnabled: false)
                    == "Zapis i przywrócenie się nie udały. Poprzedni plik odłożyłam pod \(backup). Przywróć go według przewodnika.")
            #expect(TouchIDEnableCopy.line(for: .rollbackFailed(backupPath: nil), isEnabled: false)
                    == "Nie wiem, w jakim stanie jest teraz plik /etc/pam.d/sudo_local: zapis albo jego sprawdzenie się nie udało. Sprawdź go według przewodnika.",
                    "I1: true after a writer that could not undo and after a readback that failed")
            // M1: Wega's line names no command, because the card may show none; the note the card puts
            // right above the command says "below".
            #expect(TouchIDEnableCopy.outdatedHelper
                    == "Pomocnik Wegi jest nieaktualny albo nie odpowiada, więc nie włączy Touch ID dla sudo. W Ustawieniach usuń pomocnika i zainstaluj go ponownie albo uruchom Maca ponownie.")
            #expect(TouchIDEnableCopy.outdatedHelperAboveCommand
                    == "Pomocnik Wegi jest nieaktualny albo nie odpowiada, więc nie włączy Touch ID dla sudo. Użyj polecenia niżej albo w Ustawieniach usuń pomocnika i zainstaluj go ponownie (albo uruchom Maca ponownie).")
            for refusal in TouchIDSudoEnableRefusal.allCases {
                #expect(!TouchIDEnableCopy.line(for: .refused(refusal), isEnabled: false).contains("ręcznie"), "\(refusal)")
            }
        }
    }

    /// Review focus 3: a standard user, or a second fast-user-switching session, learns only that an
    /// administrator at this Mac can do it.
    @Test func aCallerRefusalSaysOnlyAnAdministratorAtThisMacCanDoIt() {
        withLanguage(.pl) {
            for refusal in [TouchIDSudoEnableRefusal.noConsoleUser, .callerNotConsoleUser, .callerNotAdministrator] {
                #expect(TouchIDEnableCopy.line(for: .refused(refusal), isEnabled: false)
                        == "Touch ID dla sudo może włączyć tylko administrator zalogowany przy tym Macu.", "\(refusal)")
            }
        }
    }

    /// RC2-7, Z12: −4 and −5 name the condition and then give recoveryOS advice only, warning against
    /// typing the password into sudo, Wega's own prompts included.
    @Test func anUnsafePolicyGetsRecoveryOnlyAdvice() {
        withLanguage(.pl) {
            #expect(TouchIDEnableCopy.recoveryOnly == recovery)
            #expect(TouchIDEnableCopy.line(for: .refused(.notRegularFile), isEnabled: false)
                    == "Plik /etc/pam.d/sudo_local nie jest zwykłym plikiem, więc go nie zmieniłam. sudo może przez niego czytać ustawienia spoza /etc/pam.d. " + recovery)
            #expect(TouchIDEnableCopy.line(for: .refused(.unsafeOwnership), isEnabled: false)
                    == "Plik /etc/pam.d/sudo_local albo katalog /etc/pam.d może zmieniać ktoś poza rootem albo wygląda inaczej, niż powinien. To problem bezpieczeństwa: kto może tam pisać, może dostać uprawnienia roota bez hasła. Nie zmieniłam go. Sprawdź go według przewodnika. " + recovery)
            #expect(TouchIDEnableCopy.unsafePolicyNote(.notRegularFile) == TouchIDEnableCopy.line(for: .refused(.notRegularFile), isEnabled: false))
            #expect(TouchIDEnableCopy.unsafePolicyNote(.unsafeOwnership) == TouchIDEnableCopy.line(for: .refused(.unsafeOwnership), isEnabled: false))
            for refusal in TouchIDSudoEnableRefusal.allCases where refusal != .notRegularFile && refusal != .unsafeOwnership {
                #expect(!TouchIDEnableCopy.line(for: .refused(refusal), isEnabled: false).contains("trybu odzyskiwania"), "\(refusal)")
            }
        }
    }

    // MARK: - Source pins

    /// Review focus 5 (card half): with −4/−5 seen by the app or the helper, the card has only the
    /// recoveryOS note; the Terminal command appears only through `showsEnableCommand`, under the
    /// outdated-helper note when that was the reason; the button only through `offersEnableButton`.
    @Test func theCardOffersSudoOnlyWithoutAnUnsafePolicy() throws {
        let info = try String(contentsOf: root().appending(path: "Sources/MacUpdater/InfoView.swift", directoryHint: .notDirectory), encoding: .utf8)
        let start = try #require(info.range(of: "private var touchIDCard: some View")).upperBound
        let end = try #require(info[start...].range(of: "// MARK: - GitHub token")).lowerBound
        let card = String(info[start..<end])
        let unsafe = try #require(card.range(of: "if touchIDState != .enabled, let unsafe = touchIDController.unsafePolicy {"))
        let note = try #require(card.range(of: "touchIDNote(TouchIDEnableCopy.unsafePolicyNote(unsafe), isWarning: true)"))
        let command = try #require(card.range(of: "} else if touchIDController.showsEnableCommand {"))
        let outdated = try #require(card.range(of: "if touchIDController.enableHelperOutdated {"))
        let outdatedNote = try #require(card.range(of: "touchIDNote(TouchIDEnableCopy.outdatedHelperAboveCommand)"))
        let fallback = try #require(card.range(of: "manualEnableFallback"))
        let button = try #require(card.range(of: "} else if touchIDController.offersEnableButton {"))
        let label = try #require(card.range(of: "Label(tr(\"Używaj Touch ID zamiast hasła administratora\"), systemImage: \"touchid\")"))
        #expect(unsafe.upperBound < note.lowerBound && note.upperBound < command.lowerBound)
        #expect(command.upperBound < outdated.lowerBound && outdated.upperBound < outdatedNote.lowerBound
                && outdatedNote.upperBound < fallback.lowerBound && fallback.upperBound < button.lowerBound)
        #expect(button.upperBound < label.lowerBound)
        #expect(card.components(separatedBy: "manualEnableFallback").count - 1 == 1, "the command has one way onto the card")
        #expect(!card.contains("if touchIDPermissionDenied {"), "the permission-denied state alone no longer shows the command")
        #expect(!card.contains("touchIDNote(TouchIDEnableCopy.outdatedHelper)"), "M1: the card's note is the one that says below")
        #expect(!card.contains("disableOffer == .blocked(.unsafeOwnership)"), "the unsafe note above replaces the old one")
    }

    private func root(file: String = #filePath) -> URL {
        URL(filePath: file, directoryHint: .notDirectory)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    @Test func everyLineHasNaturalEnglish() {
        withLanguage(.en) {
            #expect(TouchIDEnableCopy.line(for: .enabled, isEnabled: true) == "Touch ID is now wired up to sudo.")
            #expect(TouchIDEnableCopy.line(for: .enabled, isEnabled: false)
                    == "I wrote the file, but Touch ID for sudo still doesn't look turned on. Check /etc/pam.d/sudo_local with the user guide.")
            #expect(TouchIDEnableCopy.line(for: .refused(.callerNotAdministrator), isEnabled: false)
                    == "Only an administrator signed in at this Mac can turn on Touch ID for sudo.")
            #expect(TouchIDEnableCopy.line(for: .alreadyEnabled, isEnabled: false)
                    == "/etc/pam.d/sudo_local already has a Touch ID line, so I didn't write anything, but I can't see Touch ID for sudo turned on. Check the file with the user guide.")
            #expect(TouchIDEnableCopy.line(for: .refused(.unreadable), isEnabled: false)
                    == "/etc/pam.d/sudo_local doesn't look the way I expect, so I didn't change it. Check it with the user guide.")
            #expect(TouchIDEnableCopy.line(for: .rollbackFailed(backupPath: nil), isEnabled: false)
                    == "I don't know what state /etc/pam.d/sudo_local is in now: writing it or checking the write failed. Check it with the user guide.")
            #expect(TouchIDEnableCopy.recoveryOnly
                    == "Don't type your password into sudo until you fix this — not even when Wega asks for it during an update: sudo reads these settings. Fix them from macOS Recovery with the user guide.")
            #expect(TouchIDEnableCopy.unsafePolicyNote(.notRegularFile)
                    == "/etc/pam.d/sudo_local isn't a regular file, so I didn't change it. Through it, sudo may read settings from outside /etc/pam.d. " + TouchIDEnableCopy.recoveryOnly)
            #expect(TouchIDEnableCopy.outdatedHelper
                    == "The Wega helper is out of date or not answering, so it won't turn on Touch ID for sudo. In Settings, remove the helper and install it again, or restart your Mac.")
            #expect(TouchIDEnableCopy.outdatedHelperAboveCommand
                    == "The Wega helper is out of date or not answering, so it won't turn on Touch ID for sudo. Use the command below, or in Settings remove the helper and install it again (or restart your Mac).")
            let all: [TouchIDSudoEnableResult] = [.enabled, .alreadyEnabled, .restoredAfterFailure, .rollbackFailed(backupPath: nil),
                                                  .rollbackFailed(backupPath: backup)] + TouchIDSudoEnableRefusal.allCases.map { .refused($0) }
            for result in all {
                for isEnabled in [true, false] {
                    let line = TouchIDEnableCopy.line(for: result, isEnabled: isEnabled)
                    #expect(!line.isEmpty && !line.contains(where: { "ąćęłńóśźż".contains($0) }), "\(result): \(line)")
                }
            }
        }
    }
}
