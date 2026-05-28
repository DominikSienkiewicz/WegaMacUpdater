import SwiftUI
import MacUpdaterCore

struct InfoView: View {
    var onWegaState: ((WegaState) -> Void)?

    @State private var diagnostics: DiagnosticsResult? = nil
    @State private var touchIDState: TouchIDSudoConfigurator.State = .notSupported
    @State private var enablingTouchID = false
    @State private var touchIDError: String? = nil
    /// Set when the in-app enable path is blocked by TCC ("Operation not
    /// permitted"). Triggers the manual-fallback section with the
    /// copy-pasteable Terminal command — the only path that reliably works
    /// on Sequoia for unentitled GUI apps.
    @State private var touchIDPermissionDenied: Bool = false

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                appCard
                diagnosticsCard
                touchIDCard
                licensesCard
                environmentCard
            }
            .padding(16)
        }
        .onAppear {
            onWegaState?(WegaState(pose: .idle, line: "Oto co o sobie wiem."))
            if diagnostics == nil {
                Task { await loadDiagnostics() }
            }
            touchIDState = TouchIDSudoConfigurator.currentState()
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
                        Text("Touch ID dla Homebrew")
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
                                    Label("Włącz Touch ID dla sudo", systemImage: "touchid")
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

    private var statusBadge: some View {
        Group {
            switch touchIDState {
            case .enabled:
                WegaBadge(label: "Aktywne", variant: .info)
            case .available:
                WegaBadge(label: "Dostępne", variant: .manual)
            case .notSupported:
                EmptyView()
            }
        }
    }

    private var touchIDDescription: String {
        switch touchIDState {
        case .enabled:
            return "Sudo używa Touch ID. Aktualizacje casków z sudo (Zoom, sterowniki, launchd) potwierdzisz odciskiem zamiast hasła."
        case .available:
            return "Po włączeniu, brew nie zapyta o hasło w okienku — pojawi się natywny sheet Touch ID. Wymaga jednorazowo uprawnień administratora do zapisu /etc/pam.d/sudo_local."
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
            Text("macOS zablokował zapis do /etc/pam.d/sudo_local z poziomu Wegi (TCC). Uruchom poniższą komendę w Terminalu — wystarczy raz:")
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
                    Label("Skopiuj komendę", systemImage: "doc.on.doc")
                }
                .controlSize(.small)

                Button {
                    openInTerminal(TouchIDSudoConfigurator.manualEnableTerminalCommand)
                } label: {
                    Label("Otwórz w Terminalu", systemImage: "terminal")
                }
                .controlSize(.small)

                Spacer()

                Button("Sprawdź ponownie") {
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
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        try? task.run()
    }

    private func enableTouchID() async {
        enablingTouchID = true
        touchIDError = nil
        touchIDPermissionDenied = false
        defer { enablingTouchID = false }

        let cmd = TouchIDSudoConfigurator.enableShellCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(cmd)\" with administrator privileges"

        let result: (status: Int32, stderr: String) = await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
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
            onWegaState?(WegaState(pose: .happy, line: "Touch ID podpięty pod sudo."))
        case .cancelledByUser:
            // Stay in `.available`, no error UI.
            break
        case .permissionDenied:
            // TCC blocked the write — switch to the manual Terminal path.
            touchIDPermissionDenied = true
            onWegaState?(WegaState(pose: .alert, line: "macOS zablokował zapis — wklej komendę do Terminala."))
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
                            LabeledValue(label: "Wersja", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? AppMetadata.version)
                            LabeledValue(label: "Build", value: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—")
                        }
                    }
                    Spacer()
                }
                .padding(14)

                Divider().opacity(0.5)

                HStack(spacing: 8) {
                    Text("Architected & Developed by")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Link("Dominik Sienkiewicz", destination: URL(string: "https://www.linkedin.com/in/dominik-sienkiewicz/")!)
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
                    Link("GitHub", destination: URL(string: "https://github.com/DominikSienkiewicz/WegaMacUpdater")!)
                        .font(.system(size: 13))
                    Link("Zgłoś błąd", destination: URL(string: "https://github.com/DominikSienkiewicz/WegaMacUpdater/issues")!)
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
                    Text("Diagnostyka systemu")
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

    // MARK: - Licenses card

    private var licensesCard: some View {
        WegaCard {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "doc.text").foregroundStyle(Color.wegaHoney)
                    Text("Zewnętrzne narzędzia")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .overlay(alignment: .bottom) { Divider().opacity(0.5) }

                VStack(alignment: .leading, spacing: 0) {
                    LicenseRow(name: "Homebrew", license: "BSD 2-Clause", url: URL(string: "https://brew.sh")!)
                    Divider().opacity(0.3)
                    LicenseRow(name: "mas-cli", license: "MIT", url: URL(string: "https://github.com/mas-cli/mas")!)
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
                    Text("Środowisko")
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
        if let a = active { return a ? "aktywny" : "nieaktywny" }
        return required ? "nie znaleziono" : "niedostępny"
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
