import AppKit
import MacUpdaterCore
import SwiftUI

/// Okno „Zgłoś błąd": opis użytkownika, podgląd dokładnie tej treści, która wyjdzie,
/// i wybór kanału.
///
/// Podgląd jest pełny z rozmysłem: zgłoszenie opuszcza maszynę, więc użytkownik ma
/// zobaczyć, co wysyła, zanim cokolwiek się otworzy. To samo okno obsługuje przypadek
/// „na tej maszynie nie ma klienta poczty", więc nie ma tu ślepego zaułka.
struct BugReportSheet: View {
    @ObservedObject var controller: BugReportController
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch controller.outcome {
            case .noHandler(let channel):
                manualInstructions(for: channel)
            case .idle, .opened:
                composer
            }
        }
        .padding(20)
        .frame(width: 620, height: 560)
        .task { await controller.loadEnvironment() }
        .onChange(of: controller.outcome) { _, outcome in
            if case .opened = outcome { onClose() }
        }
    }

    // MARK: - Tworzenie zgłoszenia

    private var composer: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(tr("Opisz, co się stało")).font(.wega(.headline))

            TextEditor(text: $controller.userDescription)
                .font(.wega(.body))
                .frame(height: 90)
                .overlay(alignment: .topLeading) {
                    if controller.userDescription.isEmpty {
                        Text(tr("Co robiłeś, zanim to się wydarzyło? (opcjonalne)"))
                            .font(.wega(.body)).foregroundStyle(.tertiary)
                            .padding(.horizontal, 6).padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                }

            HStack {
                Text(tr("Podgląd zgłoszenia")).font(.wega(.headline))
                Spacer()
                if preview.omittedEntryCount > 0 {
                    Label(
                        trf("Pominięto %d najstarszych wpisów", preview.omittedEntryCount),
                        systemImage: "scissors"
                    )
                    .font(.wega(.footnote)).foregroundStyle(Color.wegaToffee)
                }
            }

            if controller.isReady {
                previewBox(preview.text)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(tr("Zbieram informacje o środowisku…"))
                        .font(.wega(.callout)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Text(tr("Zgłoszenie jest redagowane — ścieżki, tokeny i nazwy użytkownika są zastąpione znacznikami."))
                .font(.wega(.footnote)).foregroundStyle(.tertiary)

            HStack {
                Button(tr("Kopiuj treść")) { copy(preview.text) }
                Spacer()
                Button(tr("Anuluj"), role: .cancel, action: onClose)
                Button(tr("Zgłoś na GitHubie")) { controller.send(controller.gitHubChannel) }
                    .disabled(!controller.isReady)
                Button(tr("Wyślij e-mailem")) { controller.send(controller.emailChannel) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!controller.isReady)
            }
        }
    }

    // MARK: - Brak klienta poczty

    @ViewBuilder
    private func manualInstructions(for channel: BugReportChannel) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(tr("Nie znaleziono klienta poczty"), systemImage: "envelope.badge.shield.half.filled")
                .font(.wega(.headline)).foregroundStyle(Color.wegaToffee)
            Text(tr("Ta maszyna nie ma skonfigurowanego klienta poczty. Skopiuj poniższe dane i wyślij zgłoszenie ręcznie."))
                .font(.wega(.callout)).foregroundStyle(.secondary)

            copyableRow(tr("Adres"), value: AppEndpoints.shared.supportEmailAddress)
            copyableRow(tr("Temat"), value: controller.title())

            HStack {
                Text(tr("Treść")).font(.wega(.subheadline, weight: .medium))
                Spacer()
                Button(tr("Kopiuj treść")) { copy(controller.preview(for: channel).text) }
                    .controlSize(.small)
            }
            previewBox(controller.preview(for: channel).text)

            HStack {
                Spacer()
                Button(tr("Zamknij"), action: onClose).keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - Elementy wspólne

    private func previewBox(_ text: String) -> some View {
        ScrollView {
            Text(text)
                .font(.wega(.footnote, monospaced: true))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .frame(maxHeight: .infinity)
    }

    private func copyableRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label).font(.wega(.subheadline, weight: .medium))
            Text(value).font(.wega(.subheadline, monospaced: true)).textSelection(.enabled)
            Spacer()
            Button(trf("Kopiuj %@", label.lowercased())) { copy(value) }.controlSize(.small)
        }
    }

    private var preview: BugReportBody {
        controller.preview(for: controller.emailChannel)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
