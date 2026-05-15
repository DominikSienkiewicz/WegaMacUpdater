import SwiftUI
import MacUpdaterCore

private enum MigrationStatus { case ready, scanning, results }

struct MigrationView: View {
    var onWegaState: ((WegaState) -> Void)?

    @EnvironmentObject private var model: AppViewModel

    @State private var status:     MigrationStatus   = .ready
    @State private var candidates: [ApplicationInfo]  = []
    @State private var migrated:   Set<String>        = []
    @State private var migrating:       String?
    @State private var confirmingApp:   ApplicationInfo? = nil
    @State private var logLines:        [String]          = []
    @State private var errorMessage:    String?
    @State private var banner:          BannerData?
    @State private var showLibraryCleanup: Bool           = false
    @State private var cleanupApp:      ApplicationInfo?  = nil
    @State private var libraryLeftovers: [URL]            = []
    @State private var masCandidates: [(app: ApplicationInfo, masID: String)] = []

    private var matchable: [ApplicationInfo] {
        candidates.filter { app in
            guard let token = app.caskToken else { return false }
            return !migrated.contains(token)
        }
    }
    private var unmatched: [ApplicationInfo] {
        let masIDs = Set(masCandidates.map { $0.app.id })
        return candidates.filter { $0.caskToken == nil && !masIDs.contains($0.id) }
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
            title: "Zwęszyć aplikacje poza Homebrew?",
            message: "Wega zajrzy do /Applications i poszuka programów zainstalowanych ręcznie, które dałoby się przepiąć pod Brew.",
            action: AnyView(
                Button { Task { await scan() } } label: {
                    Label("Skanuj /Applications", systemImage: "sparkle.magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.wegaHoney)
                .foregroundStyle(Color(red: 0.16, green: 0.11, blue: 0.07))
                .controlSize(.large)
            )
        )
    }

    private var scanningView: some View {
        VStack(spacing: 18) {
            WegaCard {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small).tint(Color.wegaHoney)
                    Text("Skanowanie /Applications")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }

            VStack(spacing: 10) {
                WegaFull(pose: .sniff, size: 130)
                Text("Trop! Wega wącha każdy folder w /Applications…")
                    .font(.system(size: 13).italic())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
    }

    private var resultsView: some View {
        ScrollView {
            VStack(spacing: 14) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Kandydaci do migracji")
                            .font(.system(size: 18, weight: .semibold))
                        Text("Zeskanowano /Applications · znalazłam \(matchable.count + migrated.count + masCandidates.count + unmatched.count) aplikacji poza zarządzaniem")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Button { Task { await scan() } } label: {
                        Label("Skanuj ponownie", systemImage: "arrow.clockwise")
                    }
                }

                if let err = errorMessage { ErrorBanner(message: err) }
                if let b = banner { BannerView(data: b) { banner = nil } }

                // Matchable section
                WegaCard(padded: false) {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.wegaSuccess)
                        Text("Można przepiąć pod Homebrew")
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
                        Text("Wszystko już przygarnięte. Dobra robota.")
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

                // App Store candidates section
                if !masCandidates.isEmpty {
                    WegaCard(padded: false) {
                        HStack(spacing: 8) {
                            Image(systemName: "basket.fill").foregroundStyle(Color.wegaInfo)
                            Text("Można przenieść do App Store")
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
                            AppStoreMigrationRow(app: item.app, masID: item.masID)
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
                            Text("Bez odpowiednika w Homebrew")
                                .font(.system(size: 13, weight: .semibold))
                            Text("\(unmatched.count)")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.tertiary)
                            Text("zostaną zarządzane ręcznie").font(.system(size: 11)).foregroundStyle(.tertiary)
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
                                WegaBadge(label: "brak w cask repo", variant: .manual)
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
        .sheet(item: $confirmingApp) { app in
            MigrationConfirmSheet(app: app) {
                confirmingApp = nil
                Task { await migrate(app) }
            }
        }
        .sheet(isPresented: $showLibraryCleanup) {
            if let app = cleanupApp {
                LibraryCleanupSheet(
                    appName: app.name,
                    leftovers: libraryLeftovers,
                    onClean: { urls in cleanLibrary(urls, app: app) },
                    onDismiss: { dismissCleanup(app: app) }
                )
            }
        }
    }

    private func scan() async {
        guard status != .scanning else { return }
        status = .scanning; errorMessage = nil; masCandidates = []
        onWegaState?(WegaState(pose: .sniff, line: "Tropię intruzów w /Applications i ~/Applications…"))

        do {
            let cacheURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Caches/\(AppMetadata.bundleIdentifier)/casks.json")
            let casks    = try await CaskDatabaseClient(cache: CaskDatabaseCache(fileURL: cacheURL)).fetchCasks()
            let installed = try await model.brewService.installedCasks()
            let scanner = ApplicationScanner()
            var seen = Set<String>()
            var all:  [ApplicationInfo] = []
            for dir in buildScanDirs() {
                let found = (try? scanner.scanApplications(in: dir, installedCasks: installed, availableCasks: casks)) ?? []
                for app in found {
                    let key = app.bundleIdentifier ?? app.path.path
                    if seen.insert(key).inserted { all.append(app) }
                }
            }
            // Exclude brew-managed apps AND apps already in the App Store
            let migrationPool = all.filter { !$0.isManagedByBrew && !$0.isManagedByMas }
            candidates = migrationPool

            // Parallel App Store search for apps with no Homebrew match
            let toSearch = migrationPool.filter { $0.caskToken == nil }
            if !toSearch.isEmpty {
                let masService = model.masService
                var found: [(app: ApplicationInfo, masID: String)] = []
                await withTaskGroup(of: (ApplicationInfo, String?).self) { group in
                    for app in toSearch {
                        group.addTask {
                            let id = try? await masService.search(name: app.name)
                            return (app, id)
                        }
                    }
                    for await (app, maybeID) in group {
                        if let id = maybeID { found.append((app: app, masID: id)) }
                    }
                }
                masCandidates = found
            }
        } catch {
            candidates = []
            errorMessage = error.localizedDescription
        }

        status = .results
        let brewCount = candidates.filter { $0.caskToken != nil }.count
        let total = brewCount + masCandidates.count
        onWegaState?(WegaState(
            pose: total > 0 ? .alert : .happy,
            line: total > 0
                ? "Zwęszyłam \(total) aplikacji do przepięcia."
                : "Wszystko porządku. Wega nie znalazła uciekinierów."
        ))
    }

    @MainActor
    private func migrate(_ app: ApplicationInfo) async {
        guard migrating == nil, let token = app.caskToken else { return }
        migrating = token
        errorMessage = nil
        logLines = []
        onWegaState?(WegaState(pose: .sniff, line: "Instaluję \(app.name) przez Homebrew…"))

        do {
            // Kill app if running before brew install
            if let info = MacUpdaterConstants.restartMap[token], await isProcessRunning(info.processName) {
                logLines.append("⚠ \(info.appName) jest uruchomiony — zamykam przed instalacją…")
                await killProcess(info.processName)
            }

            let stream = try model.brewService.events(arguments: ["install", "--cask", "--force", token])
            var exitCode: Int32 = 0
            for try await event in stream {
                switch event {
                case .stdout(let line), .stderr(let line):
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        logLines.append(trimmed)
                        if logLines.count > 200 { logLines.removeFirst() }
                    }
                case .finished(let result):
                    exitCode = result.exitCode
                }
            }
            if exitCode == 0 {
                migrated.insert(token)
                logLines = []
                // Scan for Library leftovers from old installation
                if let bundleId = app.bundleIdentifier {
                    let found = scanLibraryLeftovers(bundleId: bundleId)
                    if !found.isEmpty {
                        libraryLeftovers = found
                        cleanupApp = app
                        showLibraryCleanup = true
                        onWegaState?(WegaState(pose: .happy, line: "\(app.name) przejęty! Znalazłam resztki — zajrzyjmy."))
                        migrating = nil
                        return
                    }
                }
                banner = BannerData(variant: .success,
                                    title: "\(app.name) pod Homebrew",
                                    message: "Token: \(token)")
                onWegaState?(WegaState(pose: .happy, line: "\(app.name) przejęty! Idziemy dalej."))
            } else {
                errorMessage = "Instalacja \(token) zakończyła się błędem (kod \(exitCode)). Sprawdź log poniżej."
                onWegaState?(WegaState(pose: .sad, line: "Ups. Brew zgłosił problem z \(app.name)."))
            }
        } catch {
            errorMessage = error.localizedDescription
            onWegaState?(WegaState(pose: .sad, line: "Błąd podczas migracji \(app.name)."))
        }
        migrating = nil
    }

    private func scanLibraryLeftovers(bundleId: String) -> [URL] {
        let lib = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        let candidates: [URL] = [
            lib.appendingPathComponent("Application Support/\(bundleId)"),
            lib.appendingPathComponent("Preferences/\(bundleId).plist"),
            lib.appendingPathComponent("Caches/\(bundleId)"),
            lib.appendingPathComponent("Saved Application State/\(bundleId).savedState"),
            lib.appendingPathComponent("Containers/\(bundleId)"),
        ]
        return candidates.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func cleanLibrary(_ urls: [URL], app: ApplicationInfo) {
        for url in urls { try? FileManager.default.removeItem(at: url) }
        showLibraryCleanup = false
        cleanupApp = nil
        libraryLeftovers = []
        let msg = urls.count == 1 ? "Usunięto 1 plik/folder." : "Usunięto \(urls.count) pliki/foldery."
        banner = BannerData(variant: .success, title: "\(app.name) pod Homebrew", message: msg)
        onWegaState?(WegaState(pose: .happy, line: "\(app.name) przejęty i posprzątane!"))
    }

    private func dismissCleanup(app: ApplicationInfo) {
        showLibraryCleanup = false
        cleanupApp = nil
        libraryLeftovers = []
        banner = BannerData(variant: .success, title: "\(app.name) pod Homebrew", message: "Token: \(app.caskToken ?? "—")")
        onWegaState?(WegaState(pose: .happy, line: "\(app.name) przejęty! Idziemy dalej."))
    }

    private func isProcessRunning(_ name: String) async -> Bool {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
                p.arguments = ["-x", name]
                try? p.run()
                p.waitUntilExit()
                cont.resume(returning: p.terminationStatus == 0)
            }
        }
    }

    private func killProcess(_ name: String) async {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
                p.arguments = [name]
                try? p.run()
                p.waitUntilExit()
                cont.resume(returning: ())
            }
        }
        try? await Task.sleep(for: .milliseconds(500))
    }
}

private struct MigrationRow: View {
    let app:       ApplicationInfo
    let isBusy:    Bool
    let onMigrate: () -> Void

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
                else { Label("Przepnij", systemImage: "arrow.right.doc.on.clipboard") }
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
            Button {
                if let url = URL(string: "macappstore://apps.apple.com/app/id\(masID)") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Label("Otwórz w App Store", systemImage: "basket")
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
                    Text("Migracja do Homebrew")
                        .font(.system(size: 16, weight: .bold))
                    Text(app.name)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }

            if let token = app.caskToken {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Polecenie:")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    Text("brew install --cask --force \(token)")
                        .font(.system(size: 12, design: .monospaced))
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                }
            }

            Text("Homebrew pobierze najnowszą wersję i zastąpi aktualną instalację w /Applications. Zamknij aplikację przed kontynuowaniem.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Anuluj") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Migruj") {
                    onConfirm()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(Color.wegaHoney)
                .foregroundStyle(Color(red: 0.16, green: 0.11, blue: 0.07))
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
                Text("Log migracji")
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

// MARK: - LibraryCleanupSheet

private struct LibraryCleanupSheet: View {
    let appName:   String
    let leftovers: [URL]
    let onClean:   ([URL]) -> Void
    let onDismiss: () -> Void

    @State private var selected: Set<String>

    init(appName: String, leftovers: [URL], onClean: @escaping ([URL]) -> Void, onDismiss: @escaping () -> Void) {
        self.appName   = appName
        self.leftovers = leftovers
        self.onClean   = onClean
        self.onDismiss = onDismiss
        _selected = State(initialValue: Set(leftovers.map(\.path)))
    }

    private let home = FileManager.default.homeDirectoryForCurrentUser.path

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11)
                        .fill(Color.wegaHoney.opacity(0.12))
                        .frame(width: 44, height: 44)
                    Image(systemName: "trash.circle")
                        .foregroundStyle(Color.wegaHoney)
                        .font(.system(size: 20))
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Resztki po starej instalacji")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Znalezione pliki \(appName) z poprzedniej instalacji")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 14)

            Divider().opacity(0.5)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(leftovers, id: \.path) { url in
                    let isSelected = selected.contains(url.path)
                    HStack(spacing: 10) {
                        Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                            .foregroundStyle(isSelected ? Color.wegaHoney : .secondary)
                            .font(.system(size: 15))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(url.lastPathComponent)
                                .font(.system(size: 12, weight: .medium))
                            Text(url.path.replacingOccurrences(of: home, with: "~"))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
                    .onTapGesture { toggle(url.path) }

                    if url.path != leftovers.last?.path {
                        Divider().opacity(0.4).padding(.leading, 46)
                    }
                }
            }

            Divider().opacity(0.5)

            HStack(spacing: 8) {
                Spacer()
                Button("Zostaw", action: onDismiss)
                Button("Wyczyść zaznaczone") {
                    onClean(leftovers.filter { selected.contains($0.path) })
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.wegaHoney)
                .foregroundStyle(Color(red: 0.16, green: 0.11, blue: 0.07))
                .disabled(selected.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 18)
            .overlay(alignment: .top) { Divider().opacity(0.5) }
        }
        .frame(width: 460)
    }

    private func toggle(_ path: String) {
        if selected.contains(path) { selected.remove(path) } else { selected.insert(path) }
    }
}
