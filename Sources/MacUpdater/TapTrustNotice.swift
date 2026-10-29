import MacUpdaterCore
import SwiftUI

/// What one tap-trust row says: the button, one line on why this is the narrow fix, and the
/// exact command the button runs. Trusting or removing a tap changes the user's Homebrew
/// configuration, so the command is shown verbatim — `--` fence included — never paraphrased.
struct TapTrustRemedyPresentation: Equatable {
    let buttonTitle: String
    let explanation: String
    let command: String

    init(_ remedy: TapTrustRemedy) {
        switch remedy.kind {
        case .untapUnused:
            buttonTitle = tr("Odepnij nieużywane tapy")
            explanation = tr("Nic zainstalowanego nie pochodzi z tych tapów.")
        case .trustInstalledCasks:
            buttonTitle = tr("Zaufaj zainstalowanym caskom")
            explanation = tr("Tylko te zainstalowane caski — nie cały tap.")
        case .trustInstalledFormulae:
            buttonTitle = tr("Zaufaj zainstalowanym formułom")
            explanation = tr("Tylko te zainstalowane formuły — nie cały tap.")
        }
        command = remedy.commandLine
    }
}

/// What the brew log panel needs from the store to answer the tap-trust warning: planning the
/// remedies for the taps the warning names, and running one on a click.
struct TapTrustActions {
    let resolve: @MainActor ([String]) async -> [TapTrustRemedy]
    let run: @MainActor (TapTrustRemedy) async -> Void
}

/// The notice the brew log panel shows above the log while it carries Homebrew's tap-trust
/// warning. Nothing runs until a button is clicked, and one click runs one command.
struct TapTrustNotice: View {
    let remedies: [TapTrustRemedy]
    let run: @MainActor (TapTrustRemedy) async -> Void

    @State private var running: TapTrustRemedy?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.shield").foregroundStyle(Color.wegaToffee)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("Homebrew pomija pakiety z niezaufanych tapów"))
                        .font(.wega(.callout, weight: .semibold))
                    Text(tr("Przycisk zmienia konfigurację Homebrew: uruchamia dokładnie polecenie obok, dopiero po kliknięciu."))
                        .font(.wega(.subheadline)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            ForEach(remedies, id: \.self) { remedy in
                row(TapTrustRemedyPresentation(remedy), remedy: remedy)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Divider().opacity(0.4) }
    }

    private func row(_ presentation: TapTrustRemedyPresentation, remedy: TapTrustRemedy) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(presentation.explanation)
                    .font(.wega(.subheadline)).foregroundStyle(.secondary)
                Text(presentation.command)
                    .font(.wega(.footnote, monospaced: true))
                    .foregroundStyle(Color.wegaHoney)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(presentation.buttonTitle) {
                Task {
                    running = remedy
                    await run(remedy)
                    running = nil
                }
            }
            .disabled(running != nil)
            .help(presentation.command)
        }
    }
}
