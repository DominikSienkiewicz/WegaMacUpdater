import SwiftUI
import AppKit
import MacUpdaterCore

struct InfoView: View {
    var onWegaState: ((WegaState) -> Void)?

    @EnvironmentObject private var localization: LocalizationManager
    @EnvironmentObject private var policies: UpdatePolicyStore
    @State private var diagnostics: DiagnosticsResult? = nil
    @State private var selfUpdate: WegaSelfUpdateChecker.Result? = nil
    @State private var checkingSelfUpdate = false
    @State private var downloadingUpdate = false
    @State private var touchIDState: TouchIDSudoConfigurator.State = .notSupported
    @State private var enablingTouchID = false
    @State private var touchIDError: String? = nil
    /// Set when the in-app enable path is blocked by TCC ("Operation not
    /// permitted"). Triggers the manual-fallback section with the
    /// copy-pasteable Terminal command — the only path that reliably works
    /// on Sequoia for unentitled GUI apps.
    @State private var touchIDPermissionDenied: Bool = false
    @State private var catalogRefreshing = false
    @State private var catalogOutcome: CatalogRefresher.Outcome? = nil
    // FEAT-01: privileged helper (SMAppService + XPC).
    @State private var helperStatus: PrivilegedHelperClient.Status = .notRegistered
    @State private var helperBusy = false
    @State private var helperError: String? = nil

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                appCard
                languageCard
                policiesCard
                diagnosticsCard
                catalogCard
                touchIDCard
                privilegedHelperCard
                licensesCard
                environmentCard
            }
            .padding(16)
        }
        .onAppear {
            onWegaState?(WegaState(pose: .idle, line: tr("Oto co o sobie wiem.")))
            if diagnostics == nil {
                Task { await loadDiagnostics() }
            }
            // Auto-check for a Wega update once per appearance; the ETag-conditional request
            // makes repeat visits cheap (a 304 doesn't count against GitHub's rate limit).
            if selfUpdate == nil && !checkingSelfUpdate {
                Task { await checkSelfUpdate() }
            }
            touchIDState = TouchIDSudoConfigurator.currentState()
            helperStatus = PrivilegedHelperClient.shared.status
        }
    }

    // MARK: - Language

    private var languageCard: some View {
        WegaCard {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "globe").foregroundStyle(Color.wegaHoney)
                    Text(tr("Język interfejsu"))
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .overlay(alignment: .bottom) { Divider().opacity(0.5) }

                Picker("", selection: $localization.language) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text("\(lang.flag)  \(lang.displayName)").tag(lang)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }
    }

    // MARK: - Ignored / pinned updates

    private var policiesCard: some View {
        WegaCard {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "hand.raised").foregroundStyle(Color.wegaHoney)
                    Text(tr("Ignorowane i przypięte"))
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if !policies.isEmpty {
                        Text("\(policies.sortedEntries.count)")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .overlay(alignment: .bottom) { Divider().opacity(0.5) }

                if policies.isEmpty {
                    Text(tr("Brak reguł. Kliknij aktualizację prawym przyciskiem, aby ją zignorować lub przypiąć wersję."))
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                } else {
                    ForEach(policies.sortedEntries) { entry in
                        HStack(spacing: 10) {
                            Image(systemName: policyIcon(entry.policy))
                                .foregroundStyle(.secondary)
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.displayName).font(.system(size: 13, weight: .medium))
                                Text(policyDescription(entry.policy))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Button { policies.remove(key: entry.key) } label: {
                                Image(systemName: "trash").font(.system(size: 12))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help(tr("Usuń regułę"))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        if entry.id != policies.sortedEntries.last?.id {
                            Divider().opacity(0.4).padding(.leading, 42)
                        }
                    }
                }
            }
        }
    }

    private func policyIcon(_ policy: UpdatePolicy) -> String {
        if case .ignored = policy { return "bell.slash" }
        return "pin"
    }

    private func policyDescription(_ policy: UpdatePolicy) -> String {
        switch policy {
        case .ignored:            return tr("Ignorowane")
        case .pinned(let version): return trf("Przypięte do %@", version)
        }
    }

    // MARK: - Touch ID for sudo

    @ViewBuilder
    private var touchIDCard: some View {
        if touchIDState != .notSupported {
            WegaCard {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        Image(systemName: "touchid").foregroundStyle(Color.wegaHoney)
                        Text(tr("Touch ID dla Homebrew"))
                            .font(.system(size: 13, weight: .semibold))
                        Spacer()
                        statusBadge
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .overlay(alignment: .bottom) { Divider().opacity(0.5) }

                    VStack(alignment: .leading, spacing: 8) {
                        Text(touchIDDescription)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        if let err = touchIDError {
                            Text(err)
                                .font(.system(size: 11))
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if touchIDPermissionDenied {
                            manualEnableFallback
                        } else if touchIDState == .available {
                            Button {
                                Task { await enableTouchID() }
                            } label: {
                                if enablingTouchID {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Label(tr("Włącz Touch ID dla sudo"), systemImage: "touchid")
                                }
                            }
                            .disabled(enablingTouchID)
                            .controlSize(.small)
                        }
                    }
                    .padding(14)
                }
            }
        }
    }

    // MARK: - Privileged helper (FEAT-01)

    @ViewBuilder
    private var privilegedHelperCard: some View {
        WegaCard {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "lock.shield").foregroundStyle(Color.wegaHoney)
                    Text(tr("Komponent uprzywilejowany"))
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    helperStatusBadge
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .overlay(alignment: .bottom) { Divider().opacity(0.5) }

                VStack(alignment: .leading, spacing: 8) {
                    Text(tr("Pozwala instalować zweryfikowane aktualizacje i konfigurować Touch ID bez wpisywania hasła — przez podpisany helper (XPC) z białą listą operacji."))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let err = helperError {
                        Text(err)
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    helperActions
                }
                .padding(14)
            }
        }
    }

    private var helperStatusBadge: some View {
        Group {
            switch helperStatus {
            case .enabled:          WegaBadge(label: tr("Aktywny"), variant: .info)
            case .requiresApproval: WegaBadge(label: tr("Wymaga zgody"), variant: .manual)
            case .notRegistered:    WegaBadge(label: tr("Niezarejestrowany"), variant: .manual)
            case .notFound:         WegaBadge(label: tr("Nie znaleziono"), variant: .manual)
            case .unknown:          EmptyView()
            }
        }
    }

    @ViewBuilder
    private var helperActions: some View {
        HStack(spacing: 8) {
            switch helperStatus {
            case .enabled:
                Button(role: .destructive) {
                    Task { await removeHelper() }
                } label: { Label(tr("Usuń komponent"), systemImage: "trash") }
                    .controlSize(.small)
                    .disabled(helperBusy)
            case .requiresApproval:
                Button {
                    PrivilegedHelperClient.shared.openLoginItemsSettings()
                } label: { Label(tr("Otwórz Ustawienia → Elementy logowania"), systemImage: "gearshape") }
                    .controlSize(.small)
                Button(tr("Sprawdź ponownie")) { helperStatus = PrivilegedHelperClient.shared.status }
                    .controlSize(.small)
            default:
                Button {
                    Task { await installHelper() }
                } label: {
                    if helperBusy { ProgressView().controlSize(.small) }
                    else { Label(tr("Zainstaluj komponent"), systemImage: "lock.shield") }
                }
                .controlSize(.small)
                .disabled(helperBusy)
            }
            Spacer()
        }
    }

    private func installHelper() async {
        helperBusy = true; helperError = nil
        defer { helperBusy = false }
        guard WegaHelper.isTeamIDConfigured else {
            helperError = tr("Brak skonfigurowanego Team ID — helper zadziała dopiero w podpisanym buildzie.")
            return
        }
        do {
            try PrivilegedHelperClient.shared.register()
        } catch {
            helperError = error.localizedDescription
        }
        helperStatus = PrivilegedHelperClient.shared.status
        if helperStatus == .requiresApproval {
            onWegaState?(WegaState(pose: .alert, line: tr("Zatwierdź komponent w Ustawieniach → Elementy logowania.")))
        } else if helperStatus == .enabled {
            onWegaState?(WegaState(pose: .happy, line: tr("Komponent uprzywilejowany gotowy.")))
        }
    }

    private func removeHelper() async {
        helperBusy = true; helperError = nil
        defer { helperBusy = false }
        do {
            try await PrivilegedHelperClient.shared.unregister()
        } catch {
            helperError = error.localizedDescription
        }
        helperStatus = PrivilegedHelperClient.shared.status
    }

    private var statusBadge: some View {
        Group {
            switch touchIDState {
            case .enabled:
                WegaBadge(label: tr("Aktywne"), variant: .info)
            case .available:
                WegaBadge(label: tr("Dostępne"), variant: .manual)
            case .notSupported:
                EmptyView()
            }
        }
    }

    private var touchIDDescription: String {
        switch touchIDState {
        case .enabled:
            return tr("Sudo używa Touch ID. Aktualizacje casków z sudo (Zoom, sterowniki, launchd) potwierdzisz odciskiem zamiast hasła.")
        case .available:
            return tr("Po włączeniu, brew nie zapyta o hasło w okienku — pojawi się natywny sheet Touch ID. Wymaga jednorazowo uprawnień administratora do zapisu /etc/pam.d/sudo_local.")
        case .notSupported:
            return ""
        }
    }

    /// Manual fallback shown when macOS TCC blocks the in-app write.
    /// Renders the exact one-liner the user should paste into Terminal,
    /// plus buttons to copy it and to open Terminal.app pre-armed with it.
    @ViewBuilder
    private var manualEnableFallback: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tr("macOS zablokował zapis do /etc/pam.d/sudo_local z poziomu Wegi (TCC). Uruchom poniższą komendę w Terminalu — wystarczy raz:"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(TouchIDSudoConfigurator.manualEnableTerminalCommand)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))

            HStack(spacing: 8) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(
                        TouchIDSudoConfigurator.manualEnableTerminalCommand,
                        forType: .string
                    )
                } label: {
                    Label(tr("Skopiuj komendę"), systemImage: "doc.on.doc")
                }
                .controlSize(.small)

                Button {
                    openInTerminal(TouchIDSudoConfigurator.manualEnableTerminalCommand)
                } label: {
                    Label(tr("Otwórz w Terminalu"), systemImage: "terminal")
                }
                .controlSize(.small)

                Spacer()

                Button(tr("Sprawdź ponownie")) {
                    touchIDPermissionDenied = false
                    touchIDError = nil
                    touchIDState = TouchIDSudoConfigurator.currentState()
                }
                .controlSize(.small)
            }
        }
    }

    /// Tells Terminal.app to open a new window and `do script` the command
    /// in it. Terminal is its own TCC principal — on first `sudo tee
    /// /etc/pam.d/sudo_local` it prompts the user normally and the write
    /// succeeds, unlike the same chain initiated from Wega's process tree.
    private func openInTerminal(_ command: String) {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"Terminal\" to do script \"\(escaped)\"\n"
            + "tell application \"Terminal\" to activate"

        let task = Process()
        task.executableURL = SystemPaths.osascript
        task.arguments = ["-e", script]
        try? task.run()
    }

    // MARK: - Self-update (Wega dogfooding its own GitHub releases)

    @ViewBuilder
    private var selfUpdateRow: some View {
        HStack(spacing: 10) {
            switch selfUpdate {
            case .updateAvailable(let version, let assetURL, let releaseURL):
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.wegaHoney)
                Text(trf("Dostępna wersja %@", version)).font(.system(size: 12, weight: .semibold))
                Spacer()
                Link(tr("Zobacz wydanie"), destination: releaseURL).font(.system(size: 12))
                Button {
                    Task { await downloadAndOpen(assetURL) }
                } label: {
                    if downloadingUpdate { ProgressView().controlSize(.small) }
                    else { Text(tr("Pobierz i zainstaluj")) }
                }
                .disabled(downloadingUpdate)
            case .upToDate:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(tr("Masz najnowszą wersję Wegi")).font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                selfUpdateCheckButton
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(tr("Nie udało się sprawdzić aktualizacji")).font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                selfUpdateCheckButton
            case nil:
                Spacer()
                selfUpdateCheckButton
            }
        }
    }

    private var selfUpdateCheckButton: some View {
        Button {
            Task { await checkSelfUpdate() }
        } label: {
            if checkingSelfUpdate { ProgressView().controlSize(.small) }
            else { Text(tr("Sprawdź aktualizacje Wegi")) }
        }
        .disabled(checkingSelfUpdate)
    }

    private func checkSelfUpdate() async {
        checkingSelfUpdate = true
        defer { checkingSelfUpdate = false }
        selfUpdate = await WegaSelfUpdateChecker().check()
    }

    /// Download the release asset to a temp file and hand it to the system (Installer for
    /// `.pkg`, DiskImageMounter for `.dmg`). On any failure, fall back to opening the asset
    /// URL in the browser so the user can still grab it.
    private func downloadAndOpen(_ url: URL) async {
        downloadingUpdate = true
        defer { downloadingUpdate = false }
        do {
            let (tmp, _) = try await URLSession.shared.download(from: url)
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmp, to: dest)

            // SEC-03 (A1): zanim oddamy cokolwiek systemowi, przypnij podpis +
            // notaryzację + Team ID. Fail-closed — przy niepowodzeniu NIE otwieramy
            // pobranego pliku, tylko kierujemy użytkownika na stronę wydania.
            do {
                try CodeSignatureVerifier.verify(
                    installerAt: dest,
                    expectedTeamID: WegaHelper.teamIdentifier,
                    bundleID: AppMetadata.bundleIdentifier
                )
            } catch {
                AppLogger.app.error(
                    "Self-update odrzucony przez weryfikację podpisu: \(error.localizedDescription, privacy: .public)"
                )
                try? FileManager.default.removeItem(at: dest)
                onWegaState?(WegaState(pose: .alert,
                    line: tr("Aktualizacja nie przeszła weryfikacji podpisu — otwieram stronę wydania.")))
                NSWorkspace.shared.open(AppEndpoints.shared.projectRepositoryURL)
                return
            }
            await openOrInstall(dest)
        } catch {
            // Błąd pobrania/przeniesienia — bezpieczny fallback do strony projektu,
            // a nie „ślepe" otwieranie nierozstrzygniętego URL-a.
            NSWorkspace.shared.open(AppEndpoints.shared.projectRepositoryURL)
        }
    }

    /// Po weryfikacji podpisu: jeśli helper jest aktywny i artefakt to `.pkg` —
    /// instaluje go root-daemon (bez hasła, z ponowną weryfikacją po stronie
    /// roota). W innym wypadku oddaje plik systemowemu Installerowi/Mounterowi.
    private func openOrInstall(_ dest: URL) async {
        if PrivilegedHelperClient.shared.isEnabled, dest.pathExtension.lowercased() == "pkg" {
            do {
                try await PrivilegedHelperClient.shared.installVerifiedPackage(at: dest.path)
                onWegaState?(WegaState(pose: .happy,
                    line: tr("Aktualizacja zainstalowana przez komponent uprzywilejowany.")))
                return
            } catch {
                AppLogger.app.error(
                    "Instalacja przez helper nie powiodła się: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        NSWorkspace.shared.open(dest)
    }

    private func enableTouchID() async {
        enablingTouchID = true
        touchIDError = nil
        touchIDPermissionDenied = false
        defer { enablingTouchID = false }

        // FEAT-01: gdy helper jest aktywny, zapis /etc/pam.d/sudo_local wykonuje
        // root-daemon — bez hasła, bez osascript/TCC. Fallback do osascript niżej.
        if PrivilegedHelperClient.shared.isEnabled {
            do {
                try await PrivilegedHelperClient.shared.enableTouchIDForSudo()
                touchIDState = TouchIDSudoConfigurator.currentState()
                onWegaState?(WegaState(pose: .happy, line: tr("Touch ID podpięty pod sudo.")))
                return
            } catch {
                AppLogger.app.error(
                    "Helper enableTouchIDForSudo nie powiódł się: \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        let cmd = TouchIDSudoConfigurator.enableShellCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(cmd)\" with administrator privileges"

        let result: (status: Int32, stderr: String) = await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let task = Process()
                task.executableURL = SystemPaths.osascript
                task.arguments = ["-e", script]
                let stderr = Pipe()
                task.standardError = stderr
                task.standardOutput = Pipe()
                do {
                    try task.run()
                    task.waitUntilExit()
                    let data = stderr.fileHandleForReading.readDataToEndOfFile()
                    let text = String(data: data, encoding: .utf8) ?? ""
                    cont.resume(returning: (task.terminationStatus, text))
                } catch {
                    cont.resume(returning: (-1, error.localizedDescription))
                }
            }
        }

        switch TouchIDSudoEnableOutcome.classify(exitCode: result.status, stderr: result.stderr) {
        case .success:
            touchIDState = TouchIDSudoConfigurator.currentState()
            onWegaState?(WegaState(pose: .happy, line: tr("Touch ID podpięty pod sudo.")))
        case .cancelledByUser:
            // Stay in `.available`, no error UI.
            break
        case .permissionDenied:
            // TCC blocked the write — switch to the manual Terminal path.
            touchIDPermissionDenied = true
            onWegaState?(WegaState(pose: .alert, line: tr("macOS zablokował zapis — wklej komendę do Terminala.")))
        case .otherError(let message):
            touchIDError = message
        }
    }

    // MARK: - App card

    private var appCard: some View {
        WegaCard {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 14) {
                    WegaIcon(size: 56, radius: 14)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("WegaMacUpdater")
                            .font(.system(size: 20, weight: .bold))
                        HStack(spacing: 16) {
                            LabeledValue(label: tr("Wersja"), value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? AppMetadata.version)
                            LabeledValue(label: tr("Build"), value: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—")
                        }
                    }
                    Spacer()
                }
                .padding(14)

                Divider().opacity(0.5)

                selfUpdateRow
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)

                Divider().opacity(0.5)

                HStack(spacing: 8) {
                    Text(tr("Architected & Developed by"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Link("Dominik Sienkiewicz", destination: AppEndpoints.shared.authorLinkedInURL)
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 2)

                Text("Principal AI Engineer · Full Stack Architect")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)

                Divider().opacity(0.5)

                HStack(spacing: 16) {
                    Link("GitHub", destination: AppEndpoints.shared.projectRepositoryURL)
                        .font(.system(size: 13))
                    Link(tr("Zgłoś błąd"), destination: AppEndpoints.shared.projectIssuesURL)
                        .font(.system(size: 13))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
    }

    // MARK: - Diagnostics card

    private var diagnosticsCard: some View {
        WegaCard {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "stethoscope").foregroundStyle(Color.wegaHoney)
                    Text(tr("Diagnostyka systemu"))
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .overlay(alignment: .bottom) { Divider().opacity(0.5) }

                if let d = diagnostics {
                    VStack(alignment: .leading, spacing: 0) {
                        DiagRow(label: "Homebrew", required: true, value: d.brewVersion)
                        Divider().opacity(0.3).padding(.leading, 30)
                        DiagRow(label: "mas-cli", required: false, value: d.masVersion)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                } else {
                    HStack {
                        ProgressView().controlSize(.small)
                        Spacer()
                    }
                    .padding(14)
                }
            }
        }
    }

    // MARK: - App catalog

    /// Lets the user pull the latest `AppCatalog` overlay on demand (the app also
    /// refreshes it on launch). The catalog loads once per process, so a fetched
    /// update takes effect on the next launch — the status text says so.
    private var catalogCard: some View {
        WegaCard {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "books.vertical").foregroundStyle(Color.wegaHoney)
                    Text(tr("Katalog aplikacji"))
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .overlay(alignment: .bottom) { Divider().opacity(0.5) }

                VStack(alignment: .leading, spacing: 8) {
                    Text(tr("Wega pobiera mapowania aplikacji (repozytoria GitHub, kody IDE JetBrains, feedy Sparkle) z sieci, więc nowe aplikacje są obsługiwane bez aktualizacji Wegi. Zmiany zastosują się po ponownym uruchomieniu."))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 10) {
                        Button {
                            Task { await refreshCatalog() }
                        } label: {
                            if catalogRefreshing {
                                ProgressView().controlSize(.small)
                            } else {
                                Label(tr("Odśwież katalog"), systemImage: "arrow.triangle.2.circlepath")
                            }
                        }
                        .disabled(catalogRefreshing)
                        .controlSize(.small)

                        if let outcome = catalogOutcome, !catalogRefreshing {
                            catalogStatus(outcome)
                        }
                    }
                }
                .padding(14)
            }
        }
    }

    @ViewBuilder
    private func catalogStatus(_ outcome: CatalogRefresher.Outcome) -> some View {
        switch outcome {
        case .updated:
            catalogStatusLabel(tr("Zaktualizowano — zrestartuj Wegę, aby zastosować."),
                               icon: "checkmark.circle.fill", color: .green)
        case .notModified:
            catalogStatusLabel(tr("Katalog jest aktualny."),
                               icon: "checkmark.circle", color: .secondary)
        case .invalid:
            catalogStatusLabel(tr("Pobrany katalog był nieprawidłowy — pominięto."),
                               icon: "exclamationmark.triangle.fill", color: .orange)
        case .failed:
            catalogStatusLabel(tr("Nie udało się pobrać katalogu — sprawdź połączenie."),
                               icon: "exclamationmark.triangle.fill", color: .orange)
        }
    }

    private func catalogStatusLabel(_ text: String, icon: String, color: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.system(size: 11))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func refreshCatalog() async {
        catalogRefreshing = true
        defer { catalogRefreshing = false }
        catalogOutcome = await CatalogRefresher(source: AppEndpoints.shared.appCatalogURL).refresh()
    }

    // MARK: - Licenses card

    private var licensesCard: some View {
        WegaCard {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "doc.text").foregroundStyle(Color.wegaHoney)
                    Text(tr("Zewnętrzne narzędzia"))
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .overlay(alignment: .bottom) { Divider().opacity(0.5) }

                VStack(alignment: .leading, spacing: 0) {
                    LicenseRow(name: "Homebrew", license: "BSD 2-Clause", url: AppEndpoints.shared.homebrewWebsiteURL)
                    Divider().opacity(0.3)
                    LicenseRow(name: "mas-cli", license: "MIT", url: AppEndpoints.shared.masRepositoryURL)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
            }
        }
    }

    // MARK: - Environment card

    private var environmentCard: some View {
        WegaCard {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "cpu").foregroundStyle(Color.wegaHoney)
                    Text(tr("Środowisko"))
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .overlay(alignment: .bottom) { Divider().opacity(0.5) }

                HStack(alignment: .top, spacing: 32) {
                    LabeledValue(
                        label: "macOS",
                        value: ProcessInfo.processInfo.operatingSystemVersionString
                    )
                    LabeledValue(
                        label: "CPU",
                        value: "\(ProcessInfo.processInfo.processorCount) rdzenie · \(Self.cpuArch())"
                    )
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }
    }

    // MARK: - Helpers

    private static func cpuArch() -> String {
        var info = utsname()
        guard uname(&info) == 0 else { return "unknown" }
        return withUnsafeBytes(of: &info.machine) { rawBytes -> String in
            guard let base = rawBytes.baseAddress else { return "unknown" }
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }
    }

    private func loadDiagnostics() async {
        let locator = BinaryLocator()
        var brewV: String? = nil
        var masV: String? = nil

        if let brewURL = locator.locateBrew(),
           let result = try? await ProcessRunner().run(ProcessRequest(
               executableURL: brewURL, arguments: ["--version"],
               environment: HomebrewEnvironment.environment, timeout: 5)) {
            brewV = result.stdout.split(separator: "\n").first.map(String.init)
        }

        if let masURL = locator.locateMas(),
           let result = try? await ProcessRunner().run(ProcessRequest(
               executableURL: masURL, arguments: ["version"],
               environment: HomebrewEnvironment.environment, timeout: 5)) {
            masV = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        await MainActor.run {
            diagnostics = DiagnosticsResult(
                brewVersion: brewV,
                masVersion: masV
            )
        }
    }
}

// MARK: - Supporting types

struct DiagnosticsResult: Sendable {
    var brewVersion: String?
    var masVersion:  String?
}

// MARK: - Sub-views

private struct LabeledValue: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
                .tracking(0.5)
            Text(value)
                .font(.system(size: 12, design: .monospaced))
        }
    }
}

private struct DiagRow: View {
    let label: String
    var required: Bool = false
    var value: String? = nil
    var active: Bool? = nil

    private var statusColor: Color {
        if value != nil { return .wegaSuccess }
        if active == true { return .wegaSuccess }
        if required { return Color.wegaDanger }
        return .secondary
    }

    private var statusText: String {
        if let v = value { return v }
        if let a = active { return a ? tr("aktywny") : tr("nieaktywny") }
        return required ? tr("nie znaleziono") : tr("niedostępny")
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(statusColor).frame(width: 8, height: 8)
            Text(label).font(.system(size: 12))
            Spacer()
            Text(statusText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 5)
    }
}

private struct LicenseRow: View {
    let name: String
    let license: String
    let url: URL

    var body: some View {
        HStack(spacing: 8) {
            Text(name).font(.system(size: 12, weight: .medium))
            Text(license)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Link("↗", destination: url)
                .font(.system(size: 12))
        }
        .padding(.vertical, 5)
    }
}
