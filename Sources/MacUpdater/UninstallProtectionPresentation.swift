import MacUpdaterCore

enum UninstallProtectionPresentation {
    /// The reason a protected app is shown but cannot be selected for removal.
    static func protectionReason(_ protection: UninstallProtection) -> String {
        switch protection {
        case .wegaItself:
            return tr("To jest Wega — nie usuwa samej siebie")
        case .systemApplication:
            return tr("Aplikacja systemowa macOS — chroniona przez system")
        case .symlink(let destination):
            return trf("To tylko dowiązanie do %@", destination)
        }
    }
}
