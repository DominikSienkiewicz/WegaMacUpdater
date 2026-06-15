import SwiftUI
import MacUpdaterCore

// Supporting views for `UpdateView`, split out to keep `UpdateView.swift` within
// SwiftLint's file_length budget. Module-internal (not `private`) so `UpdateView`
// in its own file can reference them.

struct RestartSection: View {
    let candidates:   [RestartInfo]
    let busyProcess:  String?
    let onRestart:    (RestartInfo) -> Void

    var body: some View {
        WegaCard {
            HStack(spacing: 8) {
                Image(systemName: "arrow.clockwise.circle").foregroundStyle(Color.wegaHoney)
                Text(tr("Do restartu")).font(.system(size: 13, weight: .semibold))
                Text("\(candidates.count)").font(.system(size: 12, design: .monospaced)).foregroundStyle(.tertiary)
                Text(tr("były otwarte podczas aktualizacji")).font(.system(size: 11)).foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .overlay(alignment: .bottom) { Divider().opacity(0.5) }

            ForEach(candidates, id: \.processName) { info in
                HStack(spacing: 12) {
                    PackageLetterIcon(name: info.appName, size: 32)
                    Text(info.appName).font(.system(size: 13, weight: .medium))
                    Spacer()
                    Button { onRestart(info) } label: {
                        if busyProcess == info.processName {
                            ProgressView().controlSize(.small)
                        } else {
                            Label(tr("Uruchom ponownie"), systemImage: "arrow.clockwise")
                        }
                    }
                    .controlSize(.small)
                    .disabled(busyProcess != nil)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .overlay(alignment: .bottom) {
                    if info.processName != candidates.last?.processName {
                        Divider().opacity(0.4).padding(.leading, 54)
                    }
                }
            }
        }
    }
}

struct BrewLogPanel: View {
    let lines:   [String]
    let onClose: () -> Void

    var body: some View {
        WegaCard(padded: false) {
            HStack(spacing: 8) {
                Circle().fill(Color.wegaSuccess).frame(width: 6, height: 6)
                Text("brew log")
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tr("Zamknij"))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .overlay(alignment: .bottom) { Divider().opacity(0.4) }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                            Text(line)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(line.hasPrefix("$") ? Color.wegaHoney : Color.primary.opacity(0.75))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(i)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(14)
                }
                .frame(maxHeight: 220)
                .onChange(of: lines.count) { _, _ in
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
        }
    }
}

struct CheckingBar: View {
    let command: String
    let delay:   Double

    @State private var visible = false

    var body: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small).tint(Color.wegaHoney)
            Text("$ \(command)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer()
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.wegaHoney.opacity(0.15))
                .frame(height: 4)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(LinearGradient(colors: [Color.wegaToffee, Color.wegaHoney], startPoint: .leading, endPoint: .trailing))
                        .frame(width: visible ? .infinity : 0)
                        .animation(.linear(duration: 2).repeatForever(autoreverses: false), value: visible)
                }
                .frame(width: 160)
        }
        .opacity(visible ? 1 : 0)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { visible = true }
        }
    }
}
