/// REL-13 — the three real outcomes of a stale-cask cleanup sweep, kept distinct so a full
/// failure can never be announced as success ("Usunięto 0"). Counts are cask tokens; the sweep
/// only runs on a non-empty list, so `removed + failed >= 1` whenever `classify` is called.
enum StaleCaskCleanupOutcome: Equatable {
    case success(removed: Int)
    case partial(removed: Int, failed: Int)
    case failure(failed: Int)

    /// Classify a finished sweep by how many tokens it removed versus failed to remove.
    static func classify(removed: Int, failed: Int) -> StaleCaskCleanupOutcome {
        if failed == 0 { return .success(removed: removed) }
        if removed == 0 { return .failure(failed: failed) }
        return .partial(removed: removed, failed: failed)
    }
}

/// REL-13 — turns a cleanup outcome into the banner the user sees. A clean sweep keeps its
/// success banner; a partial sweep and a full failure each get their own honest copy and a
/// link to the log, where the per-token errors already are (see `cleanUpStaleCasksCoordinated`).
enum StaleCaskCleanupPresentation {
    static func banner(for outcome: StaleCaskCleanupOutcome) -> BannerData {
        switch outcome {
        case .success(let removed):
            return BannerData(
                variant: .success,
                title: trf("Usunięto %@ nieaktualnych casków", "\(removed)"),
                message: tr("Homebrew nie śledzi już aplikacji, których nie ma na dysku.")
            )
        case .partial(let removed, let failed):
            return BannerData(
                variant: .danger,
                title: trf("Usunięto %@ z %@ nieaktualnych casków", "\(removed)", "\(removed + failed)"),
                message: tr("Reszty nie udało się wyrejestrować — szczegóły są w logach."),
                action: .openLogs
            )
        case .failure(let failed):
            return BannerData(
                variant: .danger,
                title: tr("Nie udało się usunąć nieaktualnych casków"),
                message: trf("Homebrew nadal śledzi %@ casków bez aplikacji — szczegóły są w logach.", "\(failed)"),
                action: .openLogs
            )
        }
    }
}
