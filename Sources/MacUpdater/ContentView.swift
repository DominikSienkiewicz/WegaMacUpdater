import SwiftUI
import MacUpdaterCore

// MARK: - Tab definition

enum SidebarTab: String, Identifiable {
    case update    = "update"
    case uninstall = "uninstall"
    case migration = "migration"
    case inventory = "inventory"
    case info      = "info"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .update:    return tr("Aktualizacje")
        case .uninstall: return tr("Odinstaluj aplikacje")
        case .migration: return tr("Migracja")
        case .inventory: return tr("Spis aplikacji")
        case .info:      return tr("Info")
        }
    }
    var systemImage: String {
        switch self {
        case .update:    return "arrow.triangle.2.circlepath"
        case .uninstall: return "trash"
        case .migration: return "arrow.right.doc.on.clipboard"
        case .inventory: return "tablecells"
        case .info:      return "info.circle"
        }
    }
    var hint: String {
        switch self {
        case .update:    return tr("Co do odświeżenia")
        case .uninstall: return tr("Usuń aplikacje")
        case .migration: return tr("Przepnij pod Brew")
        case .inventory: return tr("Pełny obchód")
        case .info:      return tr("O aplikacji")
        }
    }

    static var toolTabs: [SidebarTab] { [.update, .uninstall, .migration, .inventory] }
}

// MARK: - Root view

struct ContentView: View {
    // Persisted so a language switch (which re-keys the view tree) doesn't bounce
    // the user off their current tab — and the last tab is restored on next launch.
    @AppStorage("wega.activeTab") private var activeTab: SidebarTab = .update
    @State private var wegaState:    WegaState  = .forTab(.update)
    @State private var updateBadge:  Int        = 0
    @State private var brewInstalled: Bool

    init() {
        _brewInstalled = State(initialValue: BinaryLocator().locateBrew() != nil)
    }

    var body: some View {
        Group {
            if brewInstalled {
                HStack(spacing: 0) {
                    SidebarView(
                        activeTab:   $activeTab,
                        wegaState:   $wegaState,
                        updateBadge: updateBadge
                    )
                    Divider()
                    ContentArea(
                        activeTab:   $activeTab,
                        wegaState:   $wegaState,
                        updateBadge: $updateBadge
                    )
                }
            } else {
                BrewRequiredView { brewInstalled = BinaryLocator().locateBrew() != nil }
            }
        }
        .frame(minWidth: WegaLayout.windowMinWidth, minHeight: WegaLayout.windowMinHeight)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

// MARK: - Sidebar

private struct SidebarView: View {
    @Binding var activeTab:   SidebarTab
    @Binding var wegaState:   WegaState
    let updateBadge: Int

    var body: some View {
        VStack(spacing: 0) {
            // Brand header
            HStack(spacing: 11) {
                WegaIcon(size: 36, radius: 9)
                VStack(alignment: .leading, spacing: 2) {
                    Text("WegaMacUpdater")
                        .font(.system(size: 14, weight: .bold))
                    HStack(spacing: 5) {
                        Circle().fill(Color.wegaSuccess).frame(width: 5, height: 5)
                        Text(tr("brew · helper aktywny"))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 18)

            Divider().opacity(0.5)

            // Tab list
            VStack(alignment: .leading, spacing: 1) {
                Text(tr("Narzędzia"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                    .tracking(1)
                    .padding(.horizontal, 10)
                    .padding(.top, 10)
                    .padding(.bottom, 4)

                ForEach(SidebarTab.toolTabs) { tab in
                    SidebarTabRow(
                        tab:      tab,
                        isActive: activeTab == tab,
                        badge:    tab == .update && updateBadge > 0 ? updateBadge : nil,
                        onSelect: {
                            activeTab = tab
                            wegaState = .forTab(tab)
                        }
                    )
                }

                Divider().opacity(0.4).padding(.vertical, 4)

                SidebarTabRow(
                    tab:      .info,
                    isActive: activeTab == .info,
                    badge:    nil,
                    onSelect: {
                        activeTab = .info
                        wegaState = .forTab(.info)
                    }
                )
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)

            Spacer()

            Divider().opacity(0.5)

            // Wega status panel
            WegaStatusPanel(state: wegaState)
        }
        .frame(width: WegaLayout.sidebarWidth)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.6))
    }
}

private struct SidebarTabRow: View {
    let tab:      SidebarTab
    let isActive: Bool
    let badge:    Int?
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                Image(systemName: tab.systemImage)
                    .foregroundStyle(isActive ? Color.wegaHoney : .secondary)
                    .frame(width: 16)
                Text(tab.label)
                    .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                Spacer()
                if let b = badge {
                    Text("\(b)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(isActive
                            ? Color(red: 0.16, green: 0.11, blue: 0.07)
                            : Color.wegaHoney)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(
                            isActive ? Color.wegaHoney : Color.wegaHoney.opacity(0.18),
                            in: Capsule()
                        )
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isActive
                        ? Color.wegaHoney.opacity(0.15)
                        : (isHovered ? Color.wegaHoney.opacity(0.05) : Color.clear))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(isActive ? Color.wegaHoney.opacity(0.20) : Color.clear, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Wega status panel (friendly mode)

private struct WegaStatusPanel: View {
    let state: WegaState

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            WegaHead(pose: state.pose, size: 44)
                .padding(2)
                .background(
                    Color(NSColor.controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 10)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: state.pose)

            Text(trf("\u{201E}%@\u{201D}", "\(state.line)"))
                .font(.system(size: 11.5).italic())
                .foregroundStyle(.primary)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    Color(NSColor.controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 10)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
    }
}

// MARK: - Brew not found

private struct BrewRequiredView: View {
    let onRecheck: () -> Void

    private let installCommand = #"/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)""#

    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 28) {
                WegaFull(pose: .sad, size: 160)

                VStack(spacing: 8) {
                    Text(tr("Homebrew nie jest zainstalowany"))
                        .font(.system(size: 22, weight: .semibold))
                    Text(tr("Wega potrzebuje Homebrew, żeby sprawdzać aktualizacje\ni zarządzać aplikacjami. Zainstaluj go i kliknij Sprawdź ponownie."))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 480)
                }

                // Install command block
                VStack(alignment: .leading, spacing: 8) {
                    Text(tr("Polecenie instalacji (wklej w Terminal):"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)

                    HStack(spacing: 0) {
                        Text(installCommand)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 11)

                        Divider().frame(height: 36)

                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(installCommand, forType: .string)
                            withAnimation { copied = true }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                withAnimation { copied = false }
                            }
                        } label: {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 13))
                                .foregroundStyle(copied ? Color.wegaSuccess : Color.wegaHoney)
                                .frame(width: 44)
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .buttonStyle(.plain)
                    }
                    .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.white.opacity(0.08), lineWidth: 1))
                }
                .frame(maxWidth: 560)

                HStack(spacing: 10) {
                    Button {
                        NSWorkspace.shared.open(URL(string: "https://brew.sh")!)
                    } label: {
                        Label(tr("Otwórz brew.sh"), systemImage: "arrow.up.right.square")
                    }

                    Button {
                        onRecheck()
                    } label: {
                        Label(tr("Sprawdź ponownie"), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.wegaHoney)
                    .foregroundStyle(Color(red: 0.16, green: 0.11, blue: 0.07))
                }
                .controlSize(.large)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

private struct WegaSpeechBubble: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            PawPrint(size: 10, color: Color.wegaHoney)
            Text(text)
                .font(.system(size: 11.5).italic())
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(NSColor.controlBackgroundColor))
                .shadow(color: .black.opacity(0.30), radius: 8, y: 3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
    }
}

// MARK: - Content area

private struct ContentArea: View {
    @Binding var activeTab:   SidebarTab
    @Binding var wegaState:   WegaState
    @Binding var updateBadge: Int

    @State private var quip: String? = nil

    private let quips: [String] = [
        tr("Wszystko pod kontrolą!"),
        tr("Kiedy ostatnio robiłeś backup?"),
        tr("Brew to mój najlepszy przyjaciel."),
        tr("Wącham coś ciekawego…"),
        tr("Dobra robota dzisiaj!"),
        tr("Czy macOS jest aktualny?"),
        tr("Mam oko na ten dysk."),
        tr("Hau! Nowe paczki?"),
        tr("Zostań chwilę, sprawdzam…"),
        tr("Stary cask to zły cask."),
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 8) {
                Image(systemName: activeTab.systemImage)
                    .foregroundStyle(Color.wegaHoney)
                Text(activeTab.label)
                    .font(.system(size: 13, weight: .semibold))
                Text(trf("· %@", "\(activeTab.hint)"))
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                Spacer()
                HStack(spacing: 6) {
                    PawPrint(size: 12, color: Color.wegaToffee)
                    Text(wegaState.line)
                        .font(.system(size: 11).italic())
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            .background(Color.wegaHoney.opacity(0.02))

            Divider().opacity(0.5)

            // Tab body
            Group {
                switch activeTab {
                case .update:
                    UpdateView(
                        onWegaState:   { wegaState = $0 },
                        onBadgeChange: { updateBadge = $0 }
                    )
                case .uninstall:
                    UninstallView(onWegaState: { wegaState = $0 })
                case .migration:
                    MigrationView(onWegaState: { wegaState = $0 })
                case .inventory:
                    InventoryView(onWegaState: { wegaState = $0 })
                case .info:
                    InfoView(onWegaState: { wegaState = $0 })
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay(alignment: .bottom) {
            if let quip {
                WegaSpeechBubble(text: quip)
                    .padding(.bottom, 24)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.88, anchor: .bottom)),
                        removal:   .opacity
                    ))
            }
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.72), value: quip != nil)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Double.random(in: 18...40)))
                withAnimation { quip = quips.randomElement() }
                try? await Task.sleep(for: .seconds(4.5))
                withAnimation { quip = nil }
            }
        }
    }
}
