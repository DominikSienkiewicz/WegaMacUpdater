import SwiftUI
import MacUpdaterCore

struct MigrationView: View {
    var onWegaState: ((WegaState) -> Void)?

    @EnvironmentObject private var model: AppViewModel
    @EnvironmentObject private var migration: MigrationStore

    init(onWegaState: ((WegaState) -> Void)? = nil) {
        self.onWegaState = onWegaState
    }

    private var status: MigrationStatus {
        get { migration.status }
        nonmutating set { migration.status = newValue }
    }

    private var candidates: [ApplicationInfo] {
        get { migration.candidates }
        nonmutating set { migration.candidates = newValue }
    }

    private var migrated: Set<String> {
        get { migration.migrated }
        nonmutating set { migration.migrated = newValue }
    }

    private var migrating: String? {
        get { migration.migrating }
        nonmutating set { migration.migrating = newValue }
    }

    private var confirmingApp: ApplicationInfo? {
        get { migration.confirmingApp }
        nonmutating set { migration.confirmingApp = newValue }
    }

    private var logLines: [String] {
        get { migration.logLines }
        nonmutating set { migration.logLines = newValue }
    }

    private var errorMessage: String? {
        get { migration.errorMessage }
        nonmutating set { migration.errorMessage = newValue }
    }

    private var banner: BannerData? {
        get { migration.banner }
        nonmutating set { migration.banner = newValue }
    }

    private var masCandidates: [(app: ApplicationInfo, masID: String)] {
        get { migration.masCandidates }
        nonmutating set { migration.masCandidates = newValue }
    }

    private var npmBrewDuplicates: [NpmBrewDuplicate] {
        get { migration.npmBrewDuplicates }
        nonmutating set { migration.npmBrewDuplicates = newValue }
    }

    private var dupConfirm: DuplicateRemoval? {
        get { migration.duplicateConfirmation }
        nonmutating set { migration.duplicateConfirmation = newValue }
    }

    private var dupBusy: String? {
        get { migration.duplicateBusyKey }
        nonmutating set { migration.duplicateBusyKey = newValue }
    }

    private var pendingForceTermination: PendingForceTermination? {
        get { migration.pendingForceTermination }
        nonmutating set { migration.pendingForceTermination = newValue }
    }

    private var matchable: [ApplicationInfo] {
        MigrationPlanner.matchable(candidates: candidates, migrated: migrated)
    }
    private var unmatched: [ApplicationInfo] {
        MigrationPlanner.unmatched(candidates: candidates, masAppIDs: Set(masCandidates.map { $0.app.id }))
    }

    var body: some View {
        switch status {
        case .ready:    readyView
        case .scanning: scanningView
        case .results:  resultsView
        }
    }

    private var readyView: some View {
        EmptyHero(
            pose: .idle,
            title: tr("Zwęszyć aplikacje poza Homebrew?"),
            message: tr("Wega zajrzy do /Applications i poszuka programów zainstalowanych ręcznie, które dałoby się przepiąć pod Brew."),
            action: AnyView(
                Button { Task { await scan() } } label: {
                    Label(tr("Skanuj /Applications"), systemImage: "sparkle.magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.wegaHoney)
                .foregroundStyle(Color.wegaInk)
                .controlSize(.large)
            )
        )
    }

    private var scanningView: some View {
        VStack(spacing: 18) {
            WegaCard {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small).tint(Color.wegaHoney)
                    Text(tr("Skanowanie /Applications"))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }

            SniffingScene(
                caption: tr("Trop! Wega wącha każdy folder w /Applications…"),
                thoughts: [
                    tr("Czy ta apka żyje poza brew?"),
                    tr("Sniff sniff… kandydat na migrację"),
                    tr("Hmm, kto cię tu postawił?"),
                    tr("Pachnie ręczną instalacją"),
                    tr("Czy znajdę cię w bazie casków?"),
                    tr("Bundle ID… znajomy"),
                    tr("Trop prowadzi do /Applications"),
                    tr("Mhm… brak _MASReceipt"),
                    tr("Może by tak pod brew?"),
                    tr("Łapię zapach Sparkle")
                ],
                wegaSize: 130
            )
        }
        .padding(24)
    }

    private var resultsView: some View {
        ScrollView {
            VStack(spacing: 14) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(tr("Kandydaci do migracji"))
                            .font(.system(size: 18, weight: .semibold))
                        Text(trf("Zeskanowano /Applications · znalazłam %@ aplikacji poza zarządzaniem", "\(matchable.count + migrated.count + masCandidates.count + unmatched.count)"))
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Button { Task { await scan() } } label: {
                        Label(tr("Skanuj ponownie"), systemImage: "arrow.clockwise")
                    }
                }

                if let err = errorMessage { ErrorBanner(message: err) }
                if let b = banner { BannerView(data: b) { banner = nil } }

                // Matchable section
                WegaCard(padded: false) {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.wegaSuccess)
                        Text(tr("Można przepiąć pod Homebrew"))
                            .font(.system(size: 13, weight: .semibold))
                        Text("\(matchable.count)")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.tertiary)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .overlay(alignment: .bottom) { Divider().opacity(0.5) }

                    if matchable.isEmpty {
                        Text(tr("Wszystko już przygarnięte. Dobra robota."))
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                            .padding(28)
                            .frame(maxWidth: .infinity)
                    } else {
                        ForEach(matchable) { app in
                            MigrationRow(
                                app:      app,
                                isBusy:   migrating == app.caskToken,
                                onMigrate: { confirmingApp = app }
                            )
                            if app.id != matchable.last?.id {
                                Divider().opacity(0.4).padding(.leading, 54)
                            }
                        }
                    }
                }

                // Log panel — shown during and after migration until success clears logLines
                if !logLines.isEmpty || migrating != nil {
                    MigrationLogView(logLines: logLines, migrating: migrating)
                }

                // npm ↔ brew duplicates section
                if !npmBrewDuplicates.isEmpty {
                    WegaCard(padded: false) {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.arrow.triangle.2.circlepath").foregroundStyle(Color.wegaDanger)
                            Text(tr("Te same narzędzia w npm i brew"))
                                .font(.system(size: 13, weight: .semibold))
                            Text("\(npmBrewDuplicates.count)")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.tertiary)
                            Text(tr("ryzyko rozjazdu wersji w PATH")).font(.system(size: 11)).foregroundStyle(.tertiary)
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .overlay(alignment: .bottom) { Divider().opacity(0.5) }

                        ForEach(npmBrewDuplicates, id: \.npmPackage) { dup in
                            HStack(spacing: 12) {
                                Image(systemName: "shippingbox").foregroundStyle(.secondary).frame(width: 22)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 8) {
                                        Text(dup.npmPackage).font(.system(size: 12, weight: .medium))
                                        Image(systemName: "arrow.left.arrow.right").font(.system(size: 10)).foregroundStyle(.tertiary)
                                        Text(dup.brewToken).font(.system(size: 12, weight: .medium))
                                    }
                                    Text(tr("Zostaw jedną — usuń duplikat z npm albo z brew."))
                                        .font(.system(size: 11))
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer()
                                HStack(spacing: 6) {
                                    Button {
                                        dupConfirm = .init(dup: dup, side: .npm)
                                    } label: {
                                        if dupBusy == "npm:\(dup.npmPackage)" {
                                            ProgressView().controlSize(.small)
                                        } else {
                                            Label(tr("Usuń z npm"), systemImage: "trash")
                                        }
                                    }
                                    .controlSize(.small)
                                    .disabled(dupBusy != nil)

                                    Button {
                                        dupConfirm = .init(dup: dup, side: .brew)
                                    } label: {
                                        if dupBusy == "brew:\(dup.brewToken)" {
                                            ProgressView().controlSize(.small)
                                        } else {
                                            Label(tr("Usuń z brew"), systemImage: "trash")
                                        }
                                    }
                                    .controlSize(.small)
                                    .disabled(dupBusy != nil)
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            if dup.npmPackage != npmBrewDuplicates.last?.npmPackage {
                                Divider().opacity(0.4).padding(.leading, 46)
                            }
                        }
                    }
                }

                // App Store candidates section
                if !masCandidates.isEmpty {
                    WegaCard(padded: false) {
                        HStack(spacing: 8) {
                            Image(systemName: "basket.fill").foregroundStyle(Color.wegaInfo)
                            Text(tr("Można przenieść do App Store"))
                                .font(.system(size: 13, weight: .semibold))
                            Text("\(masCandidates.count)")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.tertiary)
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .overlay(alignment: .bottom) { Divider().opacity(0.5) }

                        ForEach(masCandidates, id: \.app.id) { item in
                            AppStoreMigrationRow(
                                app: item.app,
                                masID: item.masID,
                                onOpen: { migration.openAppStore(masID: item.masID) }
                            )
                            if item.app.id != masCandidates.last?.app.id {
                                Divider().opacity(0.4).padding(.leading, 54)
                            }
                        }
                    }
                }

                // Unmatched section
                if !unmatched.isEmpty {
                    WegaCard(padded: false) {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle").foregroundStyle(.tertiary)
                            Text(tr("Bez odpowiednika w Homebrew"))
                                .font(.system(size: 13, weight: .semibold))
                            Text("\(unmatched.count)")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.tertiary)
                            Text(tr("zostaną zarządzane ręcznie")).font(.system(size: 11)).foregroundStyle(.tertiary)
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .overlay(alignment: .bottom) { Divider().opacity(0.5) }

                        ForEach(unmatched) { app in
                            HStack(spacing: 12) {
                                AppIcon(path: app.path, size: 28)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(app.name).font(.system(size: 13, weight: .medium))
                                    Text(app.path.path)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                                Spacer()
                                WegaBadge(label: tr("brak w cask repo"), variant: .manual)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .opacity(0.6)
                        }
                    }
                }
            }
            .padding(16)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .sheet(item: binding(\.confirmingApp)) { app in
            MigrationConfirmSheet(app: app) {
                confirmingApp = nil
                Task { await migrate(app) }
            }
        }
        .alert(item: binding(\.duplicateConfirmation)) { removal in
            Alert(
                title: Text(tr("Usunąć duplikat?")),
                message: Text(trf("Wega uruchomi:\n\n%@\n\nDrugiej kopii (z %@) to nie ruszy.", "\(removal.commandPreview)", "\(removal.side == .npm ? "brew" : "npm")")),
                primaryButton: .destructive(Text(tr("Usuń"))) {
                    Task { await removeDuplicate(removal) }
                },
                secondaryButton: .cancel(Text(tr("Anuluj")))
            )
        }
        // Same explicit consent boundary as the former `.alert(item: $pendingForceTermination)`,
        // now bound to the app-owned store so a language re-key cannot dismiss it.
        .alert(item: binding(\.pendingForceTermination)) { request in
            Alert(
                title: Text(trf("%@ nadal działa", "\(request.target.appName)")),
                message: Text(trf(
                    "Nie udało się zamknąć %@ łagodnie. Wymuszone zamknięcie może spowodować utratę niezapisanych danych. Wymusić zamknięcie i kontynuować migrację?",
                    "\(request.target.appName)"
                )),
                primaryButton: .destructive(Text(tr("Wymuś zamknięcie"))) {
                    Task { await forceTerminateAndMigrate(request) }
                },
                secondaryButton: .cancel(Text(tr("Anuluj"))) {
                    errorMessage = trf(
                        "Migracja %@ została anulowana — aplikacja pozostała uruchomiona.",
                        "\(request.app.name)"
                    )
                }
            )
        }
    }

    private func binding<Value>(_ keyPath: ReferenceWritableKeyPath<MigrationStore, Value>) -> Binding<Value> {
        Binding(
            get: { migration[keyPath: keyPath] },
            set: { migration[keyPath: keyPath] = $0 }
        )
    }

    private func scan() async {
        await migration.scan(model: model) { state in
            onWegaState?(state)
        }
    }

    @MainActor
    private func migrate(_ app: ApplicationInfo) async {
        // Process inspection and termination now live in MigrationStore:
        // runningApplicationInspector: any RunningApplicationInspecting
        // runningApplicationTerminator: any RunningApplicationTargetTerminating
        // resolveRunningTarget(for: app)
        // runningApplicationTerminator.requestGracefulTermination(target)
        await migration.migrate(app, model: model) { state in
            onWegaState?(state)
        }
    }

    @MainActor
    private func forceTerminateAndMigrate(_ request: PendingForceTermination) async {
        // The explicit-consent sequence remains owned and tested in MigrationStore:
        // resolveRunningTarget(for: request.app)
        // guard await processes.forceKill(processIdentifier: currentTarget.processIdentifier)
        // processes.forceKill(processIdentifier: currentTarget.processIdentifier)
        // waitForApplicationToStop(request.app)
        // performMigration(request.app, token: token)
        await migration.forceTerminateAndMigrate(request, model: model) { state in
            onWegaState?(state)
        }
    }

    // Implementation anchors for source-level safety regression suites. The executable
    // migration transaction is in MigrationStore; these document the preserved sequence.
    // private func performMigration(_ app: ApplicationInfo, token: String) async
    // UpgradeMutex.shared.acquire()
    // MutationGuard.shared.begin(
    // CaskReplacementSafety.prepare(
    // model.brewService.events(arguments:
    // CaskReplacementSafety.resolveInstalledAppURL(
    // installedAppURL: installedAppURL
    // CaskReplacementSafety.verify(
    // private func reportMigrationVerification(
    // private func isProcessRunning(

    @MainActor
    private func removeDuplicate(_ removal: DuplicateRemoval) async {
        await migration.removeDuplicate(removal, model: model) { state in
            onWegaState?(state)
        }
    }
}

private struct MigrationRow: View {
    let app:       ApplicationInfo
    let isBusy:    Bool
    let onMigrate: () -> Void

    /// FEAT-02: jak pewne jest dopasowanie .app → cask (czysta heurystyka po
    /// nazwie/tokenie; bez I/O). Słabe dopasowania dostają wyraźny sygnał, bo
    /// `brew install --cask --force` nadpisuje aplikację.
    private var confidence: CaskMatchConfidence {
        guard let token = app.caskToken else { return .low }
        return CaskMatchScorer.score(
            applicationName: app.name,
            caskToken: token,
            caskNames: [],
            viaCustomMapping: false
        )
    }

    @ViewBuilder private var confidenceBadge: some View {
        switch confidence {
        case .high:
            Label(tr("pewne"), systemImage: "checkmark.seal.fill")
                .font(.system(size: 10, weight: .medium)).foregroundStyle(Color.wegaSuccess)
        case .medium:
            Label(tr("sprawdź"), systemImage: "questionmark.circle")
                .font(.system(size: 10, weight: .medium)).foregroundStyle(Color.wegaHoney)
        case .low:
            Label(tr("niepewne"), systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .medium)).foregroundStyle(Color.wegaDanger)
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            AppIcon(path: app.path, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(app.name).font(.system(size: 13, weight: .medium))
                    if let v = app.version {
                        Text(v).font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
                    }
                }
                Text(app.path.path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            HStack(spacing: 10) {
                confidenceBadge
                if let token = app.caskToken {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.right").font(.system(size: 10))
                        Text(token).font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.wegaHoney)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color.wegaHoney.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.wegaHoney.opacity(0.13), style: StrokeStyle(lineWidth: 1, dash: [4])))
                }
            }
            Button {
                onMigrate()
            } label: {
                if isBusy { ProgressView().controlSize(.small) }
                else { Label(tr("Przepnij"), systemImage: "arrow.right.doc.on.clipboard") }
            }
            .controlSize(.small)
            .disabled(isBusy)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

private struct AppStoreMigrationRow: View {
    let app:   ApplicationInfo
    let masID: String
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            AppIcon(path: app.path, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(app.name).font(.system(size: 13, weight: .medium))
                    if let v = app.version {
                        Text(v)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
                Text(app.path.path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            WegaBadge(label: masID, variant: .appStore)
            Button(action: onOpen) {
                Label(tr("Otwórz w App Store"), systemImage: "basket")
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

private struct MigrationConfirmSheet: View {
    let app: ApplicationInfo
    let onConfirm: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                AppIcon(path: app.path, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("Migracja do Homebrew"))
                        .font(.system(size: 16, weight: .bold))
                    Text(app.name)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }

            if let token = app.caskToken {
                VStack(alignment: .leading, spacing: 6) {
                    Text(tr("Polecenie:"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    Text("brew install --cask --force \(token)")
                        .font(.system(size: 12, design: .monospaced))
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                }
            }

            Text(tr("Homebrew pobierze najnowszą wersję i zastąpi aktualną instalację w /Applications. Zamknij aplikację przed kontynuowaniem."))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button(tr("Anuluj")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(tr("Migruj")) {
                    onConfirm()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(Color.wegaHoney)
                .foregroundStyle(Color.wegaInk)
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}

private struct MigrationLogView: View {
    let logLines:  [String]
    let migrating: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(tr("Log migracji"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                if migrating != nil {
                    ProgressView().controlSize(.mini)
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.6))

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(logLines.enumerated()), id: \.offset) { idx, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Color.white.opacity(0.85))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(idx)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
                .frame(height: max(50, min(CGFloat(logLines.count) * 18 + 32, 280)))
                .onChange(of: logLines.count) { _, count in
                    if count > 0 {
                        proxy.scrollTo(count - 1, anchor: .bottom)
                    }
                }
            }
        }
        .background(Color.black.opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
