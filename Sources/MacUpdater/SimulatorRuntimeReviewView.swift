import AppKit
import MacUpdaterCore
import SwiftUI

struct SimulatorRuntimeReviewView: View {
    @ObservedObject var store: CleanupFileReviewStore
    @Environment(\.dismiss) private var dismiss
    @State private var openFailed = false
    @State private var showsManagementHelp = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(tr("Środowiska symulatorów")).font(.wega(.title2, weight: .semibold))
                Spacer()
                if store.loadingRuntimes { ProgressView().controlSize(.small).accessibilityLabel(tr("Skanuję…")) }
                Button(tr("Odśwież")) { Task { await store.refreshRuntimes() } }
                    .disabled(store.loadingRuntimes)
            }
            if let report = store.runtimeReport {
                content(report.status)
            }
            Spacer(minLength: 0)
            if openFailed { ErrorBanner(message: tr("Nie udało się otworzyć Xcode.")) }
            Text(tr("Aby zarządzać środowiskami, w Xcode wybierz Settings → Components."))
                .font(.wega(.subheadline)).foregroundStyle(.secondary)
            HStack {
                if let application = xcodeApplication {
                    Button(tr("Otwórz Xcode")) { openXcode(application) }
                }
                Spacer()
                Button(tr("Zamknij")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(minWidth: 430, idealWidth: 510, minHeight: 280, idealHeight: 360)
        .onAppear { Task { await store.refreshRuntimes() } }
        .alert(tr("Zarządzanie środowiskami w Xcode"), isPresented: $showsManagementHelp) {
            Button(tr("Zamknij"), role: .cancel) {}
        } message: {
            Text(tr("Otwórz zainstalowaną aplikację Xcode i wybierz Settings → Components, a następnie platformę i wersję środowiska."))
        }
    }

    @ViewBuilder
    private func content(_ status: SimulatorRuntimeReport.Status) -> some View {
        switch status {
        case .toolUnavailable:
            Text(tr("Odczyt wymaga Xcode z narzędziem simctl. Jeśli masz Xcode, wybierz w nim Settings → Locations → Command Line Tools."))
        case .failed:
            Text(tr("Nie udało się odczytać środowisk symulatorów. Sprawdź Xcode i odśwież listę."))
        case .loaded(let runtimes) where runtimes.isEmpty:
            Text(tr("Brak zainstalowanych środowisk symulatorów."))
        case .loaded(let runtimes):
            let groups = Dictionary(grouping: runtimes, by: \.platform)
            List {
                ForEach(groups.keys.sorted(), id: \.self) { platform in
                    Section(platform) {
                        ForEach(groups[platform] ?? [], id: \.self) { runtime in
                            HStack {
                                Text(verbatim: runtime.version)
                                if let build = runtime.buildVersion {
                                    Text(verbatim: build).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if !runtime.isAvailable { Text(tr("Niedostępne w tym Xcode")).foregroundStyle(.secondary) }
                                managementAction(for: runtime)
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private func managementAction(for runtime: SimulatorRuntime) -> some View {
        Button(tr("Zarządzaj w Xcode…")) {
            if let application = xcodeApplication { openXcode(application) }
            else { showsManagementHelp = true }
        }
        .buttonStyle(.borderless)
        .help(tr("Aby zarządzać środowiskami, w Xcode wybierz Settings → Components."))
        .accessibilityLabel(trf("Zarządzaj środowiskiem %@ %@ w Xcode", runtime.platform, runtime.version))
    }

    private func openXcode(_ application: URL) {
        openFailed = !NSWorkspace.shared.open(application)
    }

    private var xcodeApplication: URL? {
        let identifier = "com.apple.dt.Xcode"
        if let activeApp = store.runtimeReport?.xcodeApplication, Bundle(url: activeApp)?.bundleIdentifier == identifier {
            return activeApp
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)
    }
}
