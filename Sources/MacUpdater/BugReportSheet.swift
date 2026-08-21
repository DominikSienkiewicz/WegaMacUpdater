import AppKit
import MacUpdaterCore
import SwiftUI

/// Okno „Zgłoś błąd": opis użytkownika, podgląd dokładnie tej treści, która wyjdzie,
/// i wybór kanału.
///
/// Podgląd jest pełny z rozmysłem: zgłoszenie opuszcza maszynę, więc użytkownik ma
/// zobaczyć, co wysyła, zanim cokolwiek się otworzy. To samo okno obsługuje przypadek
/// „na tej maszynie nie ma klienta poczty", więc nie ma tu ślepego zaułka.
///
/// Podgląd i wysyłka dzielą jeden wybrany kanał (`selectedChannel`), nie dwa niezależne
/// przyciski — e-mail i GitHub mają różne limity długości URL-a i różnie przycinają
/// wpisy, więc podgląd musi zawsze pokazywać dokładnie to, co pójdzie po kliknięciu.
struct BugReportSheet: View {
    @ObservedObject var controller: BugReportController
    var onClose: () -> Void

    @State private var selectedChannel: BugReportChannel

    init(controller: BugReportController, onClose: @escaping () -> Void) {
        self.controller = controller
        self.onClose = onClose
        _selectedChannel = State(initialValue: controller.emailChannel)
    }

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

    /// Liczony raz na odświeżenie widoku i przekazywany dalej jako wartość — nie jako
    /// computed property odpytywana osobno w nagłówku, podglądzie i przycisku kopiowania.
    /// `preview(for:)` redaguje każdy zaznaczony wpis i liczy dopasowanie do limitu
    /// kanału, więc trzy osobne odczyty to trzy pełne przebiegi na każde naciśnięcie
    /// klawisza w polu opisu.
    private var composer: some View {
        let preview = controller.preview(for: selectedChannel)
        return VStack(alignment: .leading, spacing: 14) {
            Text(tr("Opisz, co się stało")).font(.wega(.headline))
            descriptionEditor
            channelPicker
            previewHeader(preview)
            previewOrLoading(preview)
            Text(tr("Zgłoszenie jest redagowane — ścieżki, tokeny i nazwy użytkownika są zastąpione znacznikami."))
                .font(.wega(.footnote)).foregroundStyle(.tertiary)
            composerActions(preview)
        }
    }

    private var descriptionEditor: some View {
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
    }

    /// Wybór kanału napędza podgląd, przycięcie i przycisk wysyłki — przełączenie tu
    /// odświeża wszystkie trzy naraz, więc nie mogą się rozjechać.
    private var channelPicker: some View {
        Picker(tr("Kanał"), selection: $selectedChannel) {
            Text(tr("Wyślij e-mailem")).tag(controller.emailChannel)
            Text(tr("Zgłoś na GitHubie")).tag(controller.gitHubChannel)
        }
        .pickerStyle(.segmented)
    }

    private func previewHeader(_ preview: BugReportBody) -> some View {
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
    }

    @ViewBuilder
    private func previewOrLoading(_ preview: BugReportBody) -> some View {
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
    }

    private func composerActions(_ preview: BugReportBody) -> some View {
        HStack {
            // Zablokowane, dopóki metryczka środowiska się nie dociągnie — podgląd
            // pokazuje wtedy spinner, więc skopiowana treść nie zawierałaby sekcji,
            // której użytkownik jeszcze nie widział.
            Button(tr("Kopiuj treść")) { copy(preview.text) }
                .disabled(!controller.isReady)
            Spacer()
            Button(tr("Anuluj"), role: .cancel, action: onClose)
            Button(tr("Wyślij zgłoszenie")) { controller.send(selectedChannel) }
                .keyboardShortcut(.defaultAction)
                .disabled(!controller.isReady)
        }
    }

    // MARK: - Brak obsługi kanału

    @ViewBuilder
    private func manualInstructions(for channel: BugReportChannel) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            manualInstructionsHeader(for: channel)
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

    /// Nagłówek, wyjaśnienie i wiersz z celem zgłoszenia — inne dla każdego kanału,
    /// żeby zgłaszający na GitHubie nie dostał adresu e-mail, i odwrotnie.
    @ViewBuilder
    private func manualInstructionsHeader(for channel: BugReportChannel) -> some View {
        switch channel {
        case .email:
            Label(tr("Nie znaleziono klienta poczty"), systemImage: "envelope.badge.shield.half.filled")
                .font(.wega(.headline)).foregroundStyle(Color.wegaToffee)
            Text(tr("Ta maszyna nie ma skonfigurowanego klienta poczty. Skopiuj poniższe dane i wyślij zgłoszenie ręcznie."))
                .font(.wega(.callout)).foregroundStyle(.secondary)
            // Surowy adres — trafi do pola "Do:" klienta poczty. Dokładnie ten sam, który
            // `BugReportBuilder` wstawia dosłownie do `mailto:`; poprawność sprawdza
            // `AppEndpoints.overlaying(_:)` na granicy overlaya, nie kodowanie tutaj.
            copyableRow(tr("Adres"), value: AppEndpoints.shared.supportEmailAddress)
        case .gitHubIssue:
            Label(tr("Nie udało się otworzyć zgłoszenia na GitHubie"), systemImage: "chevron.left.slash.chevron.right")
                .font(.wega(.headline)).foregroundStyle(Color.wegaToffee)
            Text(tr("Ta maszyna nie może otworzyć strony zgłoszenia. Skopiuj poniższe dane i utwórz je ręcznie pod tym adresem."))
                .font(.wega(.callout)).foregroundStyle(.secondary)
            copyableRow(tr("Link"), value: AppEndpoints.shared.projectNewIssueURL.absoluteString)
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

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
