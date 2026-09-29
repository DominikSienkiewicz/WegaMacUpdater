import Foundation
import MacUpdaterCore

extension ScanStore {
    var allowsVendorCheck: Bool {
        vendorCheckPath == nil && !updating && !isRefreshing && status != .checking && manualBusy == nil
            && dependencies.upgrades.state == .idle
    }

    func vendorOpened(_ item: ManualOutdatedApp, succeeded: Bool) {
        guard item.source.supportsVendorCompletion else { return }
        guard succeeded else {
            vendorMessages[item.path.path] = "Nie udało się otworzyć aplikacji lub strony producenta."
            return
        }
        rememberVendorHandoff(item)
        vendorMessages[item.path.path] = nil
        persistLastScan()
    }

    func dismissVendorHandoff(_ item: ManualOutdatedApp) {
        guard vendorCheckPath != item.path.path else { return }
        vendorHandoffs.removeAll { $0.path == item.path }
        vendorMessages[item.path.path] = nil
        persistLastScan()
        emitCounts()
        let remaining = manualOutdated.first { $0.path == item.path && $0.bundleIdentifier == item.bundleIdentifier }
        dependencies.reportVendorCheck(item, remaining, nil, updateCount.badgeCount,
                                       UpdateFingerprint.of(items: allItems, manual: visibleManual))
    }

    func startVendorCheck(_ item: ManualOutdatedApp) {
        guard vendorCheckTask == nil, allowsVendorCheck else { return }
        vendorCheckTask = Task { @MainActor [weak self] in
            await self?.checkVendorUpdate(item)
            self?.vendorCheckTask = nil
        }
    }

    func checkVendorUpdate(_ item: ManualOutdatedApp) async {
        guard item.source.supportsVendorCompletion, allowsVendorCheck else { return }
        let generation = vendorCheckGeneration
        vendorCheckPath = item.path.path
        rememberVendorHandoff(item)
        persistLastScan()
        defer { vendorCheckPath = nil }
        do {
            try await dependencies.operations.withReadLease(label: "vendor update verification") { @MainActor _ in
                let result = try await self.dependencies.checkVendorUpdate(item)
                try Task.checkCancellation()
                guard generation == self.vendorCheckGeneration else { return }
                self.applyVendorResult(result, for: item)
            }
        } catch is CancellationError {
            vendorMessages[item.path.path] = "Sprawdzenie anulowane. Aktualizacja nie została potwierdzona."
        } catch {
            vendorMessages[item.path.path] = "Nie można teraz sprawdzić aplikacji. Spróbuj ponownie po zakończeniu bieżącej operacji."
        }
    }

    private func rememberVendorHandoff(_ item: ManualOutdatedApp) {
        vendorHandoffs.removeAll { $0.path == item.path }
        vendorHandoffs.append(item)
    }

    private func applyVendorResult(_ result: VendorUpdateCompletionResult, for item: ManualOutdatedApp) {
        let checkedAt = Date()
        let check = vendorInstallationCheck(result, item: item, at: checkedAt)
        if let check {
            installationChecks.removeAll { InstallationIdentity(path: $0.path) == InstallationIdentity(path: item.path) }
            installationChecks.append(check)
        }
        var remaining: ManualOutdatedApp? = item
        switch result.outcome {
        case .confirmed:
            manualOutdated.removeAll { $0.path == item.path && $0.bundleIdentifier == item.bundleIdentifier }
            vendorHandoffs.removeAll { $0.path == item.path }
            vendorMessages[item.path.path] = nil
            remaining = nil
            dependencies.recordUpdateRun(UpdateJournalEntry(finishedAt: checkedAt, trigger: .external, items: [
                UpdateJournalItem(name: item.name, kind: "manual", phase: .succeeded,
                                  upgraded: true, rolledBack: false, publisherChanged: false)
            ]))
            showBanner(BannerData(variant: .success, title: tr("Wykonano poza Wegą"),
                                  message: trf("%@ — potwierdzono wersję na dysku. Podpis i działający proces nie były sprawdzane.", item.name)))
        case .stillOutdated(let updated):
            manualOutdated.removeAll { $0.path == item.path }
            manualOutdated.append(updated)
            rememberVendorHandoff(updated)
            remaining = updated
            vendorMessages[item.path.path] = "Nadal dostępna aktualizacja. Dokończ ją u producenta, w razie potrzeby uruchom aplikację ponownie."
        case .unconfirmed(let reason):
            vendorMessages[item.path.path] = reason.message
        }
        persistLastScan()
        emitCounts()
        dependencies.reportVendorCheck(item, remaining, check, updateCount.badgeCount,
                                       UpdateFingerprint.of(items: allItems, manual: visibleManual))
    }

    private func vendorInstallationCheck(
        _ result: VendorUpdateCompletionResult, item: ManualOutdatedApp, at date: Date
    ) -> InstallationCheck? {
        guard let app = result.app else { return nil }
        let source = item.source.completionSourceLabel
        let evidence: InstallationSourceCheck
        switch result.outcome {
        case .confirmed: evidence = .init(source: source, outcome: .current)
        case .stillOutdated(let updated):
            evidence = .init(source: source, outcome: .outdated, availableVersion: updated.availableVersion, policyKey: updated.policyKey)
        case .unconfirmed: evidence = .init(source: source, outcome: .failed)
        }
        let previous = installationChecks.first { InstallationIdentity(path: $0.path) == app.installation }
        let otherSources = (previous?.sources ?? []).filter { $0.source != source }.map {
            InstallationSourceCheck(source: $0.source, outcome: .notChecked)
        }
        var check = InstallationCheck(app: app, sources: otherSources + [evidence], checkedAt: date)
        check.caskToken = item.caskPolicyToken
        return InstallationCheck.retainingLastSuccess([check], previous: previous.map { [$0] } ?? []).first
    }
}

extension VendorUpdateCompletionResult.Reason {
    var message: String {
        switch self {
        case .unreadableApplication: "Nie można odczytać tej instalacji. Mogła zostać usunięta lub przeniesiona."
        case .identityChanged: "Pod tą ścieżką jest inna aplikacja. Aktualizacja nie została potwierdzona."
        case .sourceUnavailable: "Źródło nie potwierdziło aktualności. Spróbuj ponownie, gdy będzie dostępne."
        case .unknownTarget: "Starszy wynik nie zawiera wersji do weryfikacji. Zakończ śledzenie i wykonaj pełne sprawdzenie."
        case .targetNotReached: "Ta instalacja nie osiągnęła wersji docelowej. Dokończ aktualizację i sprawdź ponownie."
        case .sharedPackage: "Wspólny pakiet aplikacji nie potwierdza wersji tej kopii. Sprawdź wersję w aplikacji po jej restarcie."
        case .changedDuringCheck: "Aplikacja zmieniła się podczas sprawdzania. Poczekaj na koniec aktualizacji i spróbuj ponownie."
        }
    }
}
