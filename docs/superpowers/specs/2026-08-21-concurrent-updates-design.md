# Współbieżny przebieg aktualizacji — pasma zamiast łańcucha faz

**Data:** 2026-08-21
**Gałąź:** `feat/concurrent-updates-2026-08-21`

## Cel

Zaznaczenie dwóch albo więcej aplikacji ma je aktualizować **równocześnie**, a nie jedna po
drugiej. Dziś `runUpdateCoordinated` jest łańcuchem faz — formuły, potem caski, potem npm
pakiet po pakiecie, potem App Store — więc czas przebiegu to suma wszystkiego, co użytkownik
zaznaczył.

## Stan wyjściowy

| Element | Gdzie | Co robi dziś |
|---|---|---|
| `runUpdateCoordinated` | `Sources/MacUpdater/ScanStore+Updating.swift` | cztery fazy w stałej kolejności, każda blokuje następną |
| `runBrewUpgrade` | tamże | jedno wywołanie zbiorcze na fazę, strumień do `brewLog` i do trackera |
| pętla npm | tamże | `for (index, (pkg, command)) in zip(...)` — jeden pakiet naraz |
| `UpgradeProgressTracker` | `Sources/MacUpdaterCore/UpgradeProgressTracker.swift` | jeden `pendingLine`, jeden `inFlightToken` — parser jednego strumienia |
| `BrewUpgradeProgressParser` | `Sources/MacUpdaterCore/BrewUpgradeProgressParser.swift` | dokumentuje, że brew **już** pobiera równolegle |
| `runBounded(limit:)` | `Sources/MacUpdaterCore/BoundedConcurrency.swift` | istniejąca pula o ograniczonej liczbie zadań w locie |
| `CaskRollbackGuard.snapshot` / `.verify` | `Sources/MacUpdater/CaskRollbackGuard.swift` | snapshot przed przebiegiem, weryfikacja jako osobna faza po nim |
| `caskProfiles[token]?.mayRequireAdminPassword` | `Sources/MacUpdater/ScanStore.swift`, użyte w `UpdateView.swift:481` | wie z góry, który cask poprosi o hasło |
| `BrewLogPanel(lines:)` | `Sources/MacUpdater/UpdateView.swift:438` | płaska lista linii |

Dwa ustalenia, które ukształtowały ten projekt:

1. **Pobieranie jest już współbieżne.** Homebrew 6 domyślnie pobiera równolegle
   (`HOMEBREW_DOWNLOAD_CONCURRENCY` = 2× liczba rdzeni), co kod już odnotowuje.
   Sekwencyjna została faza *instalacji* — montowanie DMG, kopiowanie do `/Applications`,
   `sudo` przy pakietach `pkg`.
2. **Caski są od siebie niezależne, formuły nie.** `brew upgrade f1 f2` rozwiązuje wspólne
   zależności w jednym przebiegu; rozbicie tego na osobne procesy oznacza wielokrotne
   budowanie tej samej zależności i realne kolizje na blokadach Homebrew.

## Decyzje projektowe

| Decyzja | Wybór | Uzasadnienie |
|---|---|---|
| Zakres zrównoleglenia | per cask + równoległe pasma | tam leży cała sekwencyjność, którą da się bezpiecznie usunąć |
| Formuły | zostają jednym wywołaniem | wspólne zależności; rozbicie bywa wolniejsze, nie szybsze |
| App Store | zostaje jednym wywołaniem | `mas` nie raportuje wyniku per aplikacja |
| Limit puli | stałe `3`, jako stała w kodzie | instalacja caska jest ograniczona dyskiem i siecią; powyżej ~3 przyrost znika, a rośnie ryzyko kolizji blokad. Zero nowego UI i nowych kluczy lokalizacyjnych |
| Caski proszące o hasło | osobny tor jednobieżny | dwa równoległe prompty Touch ID to zepsute UX; `mayRequireAdminPassword` wie to z góry |
| Nieznany profil caska | traktowany jak wymagający hasła | po `restoreLastScan()` mapa profili bywa pusta; zachowawczy domyślny wybór |
| Model współbieżności | `Task` na `@MainActor`, nie wątki | równoległość dają procesy `brew`, nie wątki Wegi; stan zostaje na jednym aktorze, więc zero zamków i zero wyścigów danych |
| Log | prefiks źródła na linii | `BrewLogPanel` zostaje bez zmian, wszystko widać na żywo, wiadomo skąd pochodzi linia |
| Pasek postępu | strumień tylko z formuł, reszta przez `completeUnits(1)` | tracker ma jeden bufor linii; trzy strumienie rozjechałyby parsowanie |
| Etykieta paska przy wielu pozycjach | istniejące `beginInstallingBatch()` | zero nowych stringów do tłumaczenia |
| Weryfikacja rollbacku | na końcu pipeline'u pojedynczej pozycji | zły build cofa się od razu, nie po całym przebiegu |
| Stop (REL-12) | dokończ w locie, nie wpuszczaj nowych | zabicie `brew` w połowie instalacji zostawia zabłąkany bundle w `/Applications` |
| Kolizja blokad brew | rozpoznaj komunikat i ponów raz | nowa klasa błędu wprowadzona przez tę zmianę; wzorzec jak przy ponowieniu z `--force` |

## Architektura

### Cztery pasma

`runUpdateCoordinated` startuje cztery pasma równocześnie i czeka, aż wszystkie się zejdą,
zanim wywoła rescan:

| pasmo | wykonanie |
|---|---|
| formuły brew | jedno `brew upgrade f1 f2 …` |
| caski brew | pula `runBounded(limit: 3)`, jedno `brew upgrade --cask <token>` na cask |
| caski wymagające hasła | tor jednobieżny, po jednym `brew upgrade --cask <token>` |
| npm | pula `runBounded(limit: 3)`, jedno `npm install -g -- <pkg>@latest` na pakiet |
| App Store | jedno `mas upgrade <ids>` |

Kolejność `snapshot → mutacja → weryfikacja` obowiązuje wewnątrz każdej pozycji. Snapshoty
wszystkich casków powstają **przed** startem któregokolwiek procesu — bez zmian wobec dziś,
bo to warunek istnienia sieci bezpieczeństwa.

### Dlaczego bez wątków

Wąskim gardłem jest oczekiwanie na podprocesy, nie CPU Wegi. Trzy współbieżne `Task`-i
czekające na trzy osobne procesy `brew` dają dokładnie tę równoległość, o którą chodzi, a
cały stan — `brewLog`, `UpgradeProgressTracker`, `CaskRollbackLedger`, dziennik operacji —
zostaje na `@MainActor`. Nie wprowadzamy ani jednego zamka i ani jednej struktury
współdzielonej między wątkami.

Konsekwencja implementacyjna: domknięcia przekazywane do `runBounded` muszą być
`@MainActor @Sendable`. Jeśli konwersja nie przejdzie w trybie Swift 6, `BoundedConcurrency`
dostaje wariant izolowany do `MainActor` — nie kopię logiki, tylko przeciążenie nad tym
samym `withTaskGroup`.

### Wynik pojedynczej pozycji

Każdy cask ma własny kod wyjścia i własne wyjście, więc `BrewUpgradeOutcome.analyze` ocenia
strumień dotyczący dokładnie jednej pozycji — ściślej niż dzisiejsze rozdzielanie jednego
zbiorczego wyniku przez parsowanie tokenów.

Ścieżki ponowienia, obie per pozycja:

1. **przerwana instalacja** (`already an App at …`) → ponowienie z `--force`; istnieje dziś,
   zmienia się tylko zasięg;
2. **kolizja blokad Homebrew** (`Another active Homebrew process is already in progress`) →
   jedno ponowienie po krótkiej zwłoce. Nowa ścieżka, wprowadzona przez tę zmianę.

### Log

Każda linia dostaje prefiks źródła: `[figma] ==> Downloading…`, a także linia komendy:
`[figma] $ brew upgrade --cask figma`. Wywołania zbiorcze używają prefiksów `[brew]`
i `[mas]`. Prefiks jest nazwą tokenu, nie tekstem interfejsu — nie wchodzi do lokalizacji.

### Postęp

Strumieniowe `consume(chunk:)` karmi tracker wyłącznie z pojedynczego wywołania formuł.
Każda zakończona pozycja z puli dopisuje swoją jednostkę przez istniejące
`completeUnits(1)` — tak, jak dziś robi to npm. Gdy w locie jest więcej niż jedna pozycja,
etykietą jest `beginInstallingBatch()`.

### Stop

Granica REL-12 przenosi się z „przed fazą" na „przed wpuszczeniem kolejnego zadania do
puli". Zadania w locie dobiegają końca, kolejka staje, a pozycje, które nigdy nie ruszyły,
raportuje jako pominięte istniejące `UpgradeBoundaryKeys`.

## Poza zakresem

- rozbijanie formuł na osobne procesy;
- rozbijanie `mas upgrade` na wywołania per aplikacja;
- suwak limitu w Ustawieniach;
- przebudowa `BrewLogPanel` na sekcje per aplikacja;
- zmiany w `BackgroundUpdater` — nieodglądany przebieg w tle nie ma tu nic do zyskania i
  wnosi tylko ryzyko.

## Testy

Regresje i pokrycie nowego zachowania:

| Co | Oczekiwanie |
|---|---|
| rozbicie wywołań | przebieg z trzema caskami emituje trzy `brew upgrade --cask`, nie jedno zbiorcze |
| limit puli | przy sześciu caskach nigdy więcej niż trzy procesy w locie |
| tor sudo | cask z `mayRequireAdminPassword` nigdy nie działa równolegle z innym takim caskiem |
| nieznany profil | cask bez profilu trafia do toru jednobieżnego |
| stop w trakcie | pozycje w locie kończą się, kolejkowane raportowane jako pominięte |
| log | linia z pasma per pozycja niesie prefiks tokenu |
| postęp | trzy zakończone pozycje to trzy jednostki, niezależnie od kolejności zakończenia |
| kolizja blokad | rozpoznany komunikat powoduje dokładnie jedno ponowienie |
| formuły | pozostają jednym wywołaniem, także gdy zaznaczono ich kilka |

Suite'y nie są uruchamiane w ramach tej pracy — zgodnie z regułą „testy na życzenie"
z `AGENTS.md`. Do odpalenia po stronie użytkownika: `MacUpdaterTests` i `MacUpdaterUITests`.

## Dokumentacja

Sprawdzone: zdanie o ścisłej sekwencyjności w `docs/features.md:81` dotyczy **skanu**
(brew → mas → npm → manual), nie przebiegu aktualizacji, więc pozostaje prawdziwe.
`docs/how-it-works.md` i `docs/architecture.md` nie deklarują kolejności wykonania
aktualizacji, więc nic się w nich nie dezaktualizuje.

Do dopisania w `docs/features.md`, w sekcji „Running the update": jedno zdanie o tym, że
zaznaczone caski i pakiety npm aktualizują się równolegle, z limitem trzech naraz, a caski
proszące o hasło administratora idą pojedynczo. To zachowanie widoczne dla użytkownika,
więc należy do tego pliku.

Kontrakt zewnętrzny — komendy, format wyniku, ustawienia — się nie zmienia, więc `README.md`
zostaje bez zmian.
