import SwiftUI
import MacUpdaterCore

/// UX-16 — how many updates each scope of the Updates list holds. The sidebar badge and the
/// scope bar read the same numbers (`ScanStore.scopeCounts`), so they cannot disagree.
struct UpdateScopeCounts: Equatable {
    let apps: Int
    let cli: Int
    /// Manually updated apps whose release notes read as a security fix.
    let security: Int

    var all: Int { apps + cli }
}

/// One segment of the scope bar.
struct UpdateScopeOption: Equatable {
    let filter: UpdateFilter
    let title: String
    let count: Int

    static func options(counts: UpdateScopeCounts) -> [UpdateScopeOption] {
        [
            UpdateScopeOption(filter: .all, title: tr("Wszystkie"), count: counts.all),
            UpdateScopeOption(filter: .apps, title: tr("Aplikacje"), count: counts.apps),
            UpdateScopeOption(filter: .cli, title: tr("Narzędzia CLI"), count: counts.cli),
            UpdateScopeOption(filter: .security, title: tr("Poprawki bezp."), count: counts.security),
        ]
    }
}

/// UX-16 — the category filter, above the list it filters. It used to be four sidebar rows,
/// which made the sidebar count the same updates twice. Too narrow for four segments, it
/// becomes a pop-up menu with the same options.
struct UpdateScopeBar: View {
    let filter: UpdateFilter
    let counts: UpdateScopeCounts
    let onChange: (UpdateFilter) -> Void

    var body: some View {
        let options = UpdateScopeOption.options(counts: counts)
        let selection = Binding(get: { filter }, set: { onChange($0) })
        ViewThatFits(in: .horizontal) {
            picker(options, selection: selection)
                .pickerStyle(.segmented)
                .fixedSize()
            picker(options, selection: selection)
                .pickerStyle(.menu)
                .fixedSize()
        }
    }

    private func picker(_ options: [UpdateScopeOption], selection: Binding<UpdateFilter>) -> some View {
        Picker(tr("Kategoria aktualizacji"), selection: selection) {
            ForEach(options, id: \.filter) { option in
                Text(verbatim: "\(option.title) \(option.count)").tag(option.filter)
            }
        }
        .labelsHidden()
    }
}

/// UXP-13 — the list header's trailing slot: the grouping menu, or while a scan runs in place
/// over rows, the note that says why they cannot be selected. The menu stays laid out
/// underneath, so the header keeps its height. The note is wider than the menu, so the slot
/// yields to the scope bar and the note truncates at the narrowest detail column.
///
/// C2 stage 3 — while an update holds the rows the slot says so instead, with the longer
/// explanation as its tooltip; nothing lies on the rows to say it for it.
struct ListHeaderGroupingSlot<Menu: View>: View {
    let showsScanNote: Bool
    var showsRunNote = false
    /// Whether the run's stop was requested; the run note's tooltip then says so.
    var isStopping = false
    @ViewBuilder let menu: () -> Menu

    /// The run note's tooltip: the run can be stopped, or, once asked, nothing queued starts.
    var runNoteHelp: String { UpdateRunCopy.note(isStopping: isStopping) }

    var body: some View {
        ZStack(alignment: .trailing) {
            if showsScanNote || showsRunNote {
                menu()
                    .opacity(0)
                    .disabled(true)
                    .accessibilityHidden(true)
                note
            } else {
                menu()
            }
        }
        .layoutPriority(-1)
    }

    @ViewBuilder
    private var note: some View {
        if showsRunNote {
            noteText(UpdateRunCopy.lockNote)
                .help(runNoteHelp)
        } else {
            noteText(tr("Zaznaczanie wróci, gdy skan się skończy."))
        }
    }

    private func noteText(_ text: String) -> some View {
        Text(text)
            .font(.wega(.subheadline))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

/// UXP-21 — the list header's "Grupuj" menu. The labelled picker took 191.5 pt in Polish and
/// pushed the header past the 420 pt minimum detail column, so where it does not fit it drops
/// its label, and then becomes an icon that opens the same choice.
struct UpdateGroupingMenu: View {
    @Binding var selection: UpdateGrouping

    var body: some View {
        ViewThatFits(in: .horizontal) {
            picker
                .pickerStyle(.menu)
                .fixedSize()
            picker
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            Menu {
                picker.pickerStyle(.inline)
            } label: {
                Image(systemName: "list.bullet.indent")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help(tr("Grupuj"))
            .accessibilityLabel(tr("Grupuj"))
            .accessibilityValue(selection.title)
        }
    }

    private var picker: some View {
        Picker(tr("Grupuj"), selection: $selection) {
            ForEach(UpdateGrouping.allCases, id: \.self) { option in
                Text(option.title).tag(option)
            }
        }
    }
}
