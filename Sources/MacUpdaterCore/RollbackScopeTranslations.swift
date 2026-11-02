extension Translations {
    static let rollbackScope: [String: String] = [
        "Cofanie obejmuje tylko Docker.app": "Rollback covers Docker.app only",
        "Wega nie kopiuje ani nie przywraca ustawień Dockera, maszyny wirtualnej, woluminów ani danych kontenerów; nie tworzy ani nie weryfikuje kopii środowiska.":
            "Wega does not back up or restore Docker settings, the virtual machine, volumes or container data; it does not create or verify an environment backup.",
        "Przywrócenie starszej aplikacji nie gwarantuje zgodności danych po migracji. Do odzyskania środowiska potrzebna jest osobna kopia danych.":
            "Restoring an older app does not guarantee data compatibility after migrations. Environment recovery requires a separate data backup."
    ]
}
