import SwiftUI
import MacUpdaterCore

struct UninstallSelectionBasket: View {
    let apps: [ApplicationInfo]
    let remove: (String) -> Void
    @State private var showing = false

    var body: some View {
        Button(trf("Wybrane (%@)", "\(apps.count)")) { showing = true }
            .disabled(apps.isEmpty)
            .popover(isPresented: $showing) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(apps) { app in
                            HStack(spacing: 12) {
                                VStack(alignment: .leading) {
                                    Text(app.name)
                                        .font(.wega(.callout, weight: .semibold))
                                    Text(app.path.path)
                                        .font(.wega(.footnote, monospaced: true))
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                                Spacer()
                                Button { remove(app.id) } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .accessibilityLabel(trf("Usuń z wyboru: %@", app.path.path))
                            }
                        }
                    }
                    .padding()
                }
                .frame(width: 360, height: min(280, CGFloat(apps.count) * 58 + 32))
            }
            .onChange(of: apps.isEmpty) { _, empty in
                if empty { showing = false }
            }
    }
}
