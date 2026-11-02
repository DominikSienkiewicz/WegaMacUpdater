import Foundation

enum DockerRestartTranslations {
    static let english: [String: String] = [
        "Pakiety zainstalowane. Gotowość silnika Docker nie była sprawdzana.":
            "Packages installed. Docker engine readiness has not been checked.",
        "Nie ustalono ścieżki aplikacji Docker. Sprawdź aktualizacje ponownie lub uruchom Docker ręcznie.":
            "The Docker app path could not be resolved. Check for updates again or start Docker manually.",
        "Silnik Docker gotowy": "Docker engine ready",
        "Nie potwierdzono gotowości silnika Docker": "Docker engine readiness not confirmed",
        "Lokalny silnik Docker odpowiada. Wynik instalacji jest raportowany osobno.":
            "The local Docker engine is responding. The installation result is reported separately.",
        "Nie udało się bezpiecznie zatrzymać Docker Desktop. %@":
            "Docker Desktop could not be stopped safely. %@",
        "Nie udało się uruchomić Docker Desktop. %@":
            "Docker Desktop could not be started. %@",
        "Minął limit oczekiwania na lokalny silnik Docker. Wynik instalacji pozostaje bez zmian. %@":
            "Timed out waiting for the local Docker engine. The installation result is unchanged. %@",
        "Oczekiwanie anulowane. Stan silnika Docker nie został potwierdzony; wynik instalacji pozostaje bez zmian.":
            "Waiting was cancelled. Docker engine state was not confirmed; the installation result is unchanged.",
    ]
}
