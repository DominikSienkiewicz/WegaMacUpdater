# Overlay starszej generacji przestaje zasłaniać katalog z builda

Data: 2026-08-12

## Problem

Overlay katalogu z `~/Library/Application Support/WegaMacUpdater/app-catalog.json` wygrywa z
katalogiem wkompilowanym w build **niezależnie od tego, która generacja jest nowsza**. Dane
świeżo wydane z nową wersją aplikacji są po cichu zasłaniane przez plik, który użytkownik ma
na dysku od poprzedniej instalacji.

### Zaobserwowany przebieg (2026-08-12)

Flaga `selfUpdates` trafiła do wszystkich 12 wpisów `github` i pojechała w buildzie jako
generacja 3. Użytkownik z istniejącym overlayem generacji 1 — plikiem sprzed istnienia tego
klucza — dalej widział przy Visual Studio Code akcję „GitHub Releases" zamiast nowej
„Otwórz aplikację". Wpis z overlaya zasłonił wpis z builda, a `selfUpdates` zdekodowało się
do domyślnego `false`.

### Mechanizm

- `AppCatalog.loadShared()` zwraca `bundled.overlaying(overlay)`.
- `overlaying(_:)` skleja `github + other.github`, build z przodu.
- `githubRepos` rozstrzyga duplikaty przez `uniquingKeysWith: { _, new in new }` — wygrywa
  ostatni, czyli **zawsze overlay**, bez względu na generację.
- `loadOverlay()` weryfikuje podpis i `ConfigOverlayTrust`, ale nigdy nie porównuje
  `generation` overlaya z generacją katalogu z builda.
- `CatalogRefresher` pilnuje ścieżki sieciowej przez `CatalogGenerationLedger.accepts(_:)`,
  ale ten znak wodny porównuje z **wcześniej widzianymi generacjami zdalnymi**, a nie
  z generacją wkompilowaną w ten build.

### Usterka towarzysząca

`overlaying(_:)` ustawia `generation: max(generation, other.generation)`. W stanie
z nieświeżym overlayem scalony katalog **raportuje nowszą generację, serwując starsze dane**
dla każdego zasłoniętego klucza. Nieświeżości nie da się wykryć, oglądając katalog.

## Rozwiązanie

Jedna zasada, wymuszana po obu stronach kanału: **nigdy nie serwuj ani nie zapisuj danych
katalogu starszych niż build**.

### 1. Bariera przy wczytywaniu — `AppCatalog.swift`

```swift
/// Generacja katalogu wkompilowana w ten build — podłoga, pod którą żaden overlay nie zejdzie.
public static let bundledGeneration: Int = (try? loadBundled())?.generation ?? 0

static func loadShared() -> AppCatalog {
    let bundled = (try? loadBundled()) ?? AppCatalog()
    guard let overlay = loadOverlay() else { return bundled }
    return resolve(bundled: bundled, overlay: overlay)
}

/// Bez IO, żeby barierę dało się przetestować bez dotykania prawdziwego Application Support
/// — tak samo jak `AppEndpoints.resolveOverlayStatus`.
static func resolve(bundled: AppCatalog, overlay: AppCatalog) -> AppCatalog {
    guard CatalogGenerationPolicy.accepts(
        candidate: overlay.generation,
        accepted: bundled.generation
    ) else {
        WegaLog.error(
            .app,
            "app-catalog.json: generacja \(overlay.generation) starsza niż katalog z builda "
            + "(\(bundled.generation)) — overlay zignorowany, używam katalogu z builda."
        )
        return bundled
    }
    return bundled.overlaying(overlay)
}
```

Odrzucany jest **cały overlay**, nie pojedyncze kolidujące klucze. Generacja opisuje
publikację dokumentu, nie wpis, więc rozstrzyganie per-klucz dawałoby katalog mieszany,
dla którego żadna pojedyncza generacja nie byłaby prawdziwa — i rozjeżdżałoby się ze
ścieżką sieciową, która traktuje downgrade jako wszystko-albo-nic. Koszt: overlay starszej
generacji traci też wpisy dla aplikacji nieobecnych w buildzie. Do przyjęcia — build jest
z definicji nowszy, a następne odświeżenie OTA przywraca resztę.

Ponownie użyta jest `CatalogGenerationPolicy.accepts`, a nie nowe porównanie: reguła ma
jedną definicję, razem z celowym `>=`. Równość przechodzi, bo kopia OTA tej samej publikacji
to normalny stan, nie atak.

`loadOverlay()` dalej odpowiada wyłącznie za podpis i zaufanie. Porównanie generacji wymaga
katalogu z builda, więc mieszka w `loadShared()`.

**Świadomie niepilnowane:** gdy `loadBundled()` rzuci, podłoga spada do `0` i przechodzi
dowolny overlay. Brakujący zasób w buildzie to błąd pakowania, pilnowany już przez
`testBundledCatalogDecodes`; odrzucenie overlaya zostawiłoby użytkownika z pustym katalogiem
zamiast działającego.

### 2. Podłoga w odświeżaniu — `CatalogGeneration.swift`, `CatalogRefresher.swift`

```swift
public init(defaults: UserDefaults = .standard, floor: Int = 0)
public var accepted: Int { max(defaults.integer(forKey: Self.defaultsKey), floor) }
```

`record(_:)` bez zmian — zapis generacji równej podłodze albo niższej pozostaje no-opem.
Utrwalony znak wodny dalej znaczy „najwyższa faktycznie przyjęta generacja OTA" i nigdy nie
wchłania numeru z builda, więc **downgrade aplikacji wyprowadza podłogę z builda, który
faktycznie działa**, a znak wodny OTA nadal go chroni.

`CatalogRefresher.init` domyślnie dostaje `CatalogGenerationLedger(floor: AppCatalog.bundledGeneration)`,
zgodnie z konwencją tego pliku (`signatureVerifier: CatalogSignature = .shared`,
`destination: AppCatalog.overlayURL`). Katalog spod podłogi kończy jako `.replayRejected`
przy pobieraniu, zamiast zostać zapisany i po cichu zignorowany przy następnym odczycie.

### 3. Generacja scalonego katalogu — bez zmian

`overlaying(_:)` zostaje przy `max(...)`. Po wprowadzeniu bariery `overlay.generation >=
bundled.generation` zachodzi zawsze, więc `max` to dokładnie generacja danych w użyciu.
Komentarz dokumentacyjny dostaje warunek wstępny, który to czyni prawdą: liczba jest
poprawna tylko dlatego, że `resolve(bundled:overlay:)` odrzuca starszy overlay wcześniej.

## Testy

Regresja w `Tests/MacUpdaterTests/AppCatalogTests.swift` (XCTest), w całości bez IO:

1. **Zgłoszona usterka w swoim konkretnym kształcie** — build generacji 3 z `selfUpdates: true`
   dla `com.microsoft.VSCode`, overlay generacji 1 z tym samym `bundleId` i bez klucza
   `selfUpdates`. Rozstrzygnięty wpis musi mieć `selfUpdates == true`.
   Czerwony dziś: wygrywa overlay, flaga dekoduje się do `false`.
2. **Równa generacja nadal się nakłada** — zabezpiecza przed zaostrzeniem `>=` do `>`.
3. **Nowszy overlay nadal wygrywa** na kolizji i nadal wnosi nowe aplikacje.
4. **Scalony katalog raportuje generację nałożonego overlaya.**
5. **`CatalogGenerationLedger(floor:)`** odrzuca poniżej podłogi i przyjmuje na podłodze,
   na izolowanym `TestDefaults.isolated`.

Jeden test na poziomie odświeżania — `.replayRejected` dla treści spod podłogi — trafia do
`SEC07CatalogEnvelopeTests.swift`, bo korzysta z tamtejszych pomocników do koperty
i podpisu. To test nowy, nie modyfikacja istniejącego.

### Testy istniejące

Cztery testy budują `CatalogRefresher` bez wstrzykiwania rejestru, na treściach **bez klucza
`generation`** (czyli generacji 0), i oczekują `.updated`. Build wozi generację 3, więc po
zmianie przechodzą na `.replayRejected`:

- `CatalogRefresherTests.writesValidCatalogAndReturnsUpdated`
- `CatalogSignaturePersistenceTests.testAVerifiedSignatureIsPersistedBesideTheCatalog`
- `CatalogSignaturePersistenceTests.testAnUnsignedBuildStillWritesTheCatalog`
- `CatalogSignaturePersistenceTests.testAStaleSignatureIsRemovedWhenWritingAnUnsignedCatalog`

Każdy dostaje wstrzyknięty `generations: CatalogGenerationLedger(floor: 0)` — dokładnie ten
wzorzec, którym `CatalogRefresherTests:55` wstrzykuje już nieskonfigurowany weryfikator, żeby
dojść do ścieżki decode-only. Żadna asercja nie jest osłabiona, żadne pokrycie nie znika:
te zestawy są o podpisywaniu i IO, nie o podłodze generacji. Zmiana zaakceptowana przez
użytkownika przed implementacją.

Zestaw SEC-07 wstrzykuje własny rejestr wszędzie, więc pozostaje nietknięty.

## Dokumentacja

`RELEASING.md` opisuje `--bump` i znak wodny po stronie klienta. Dochodzi druga połowa
reguły: publikowana generacja musi być **także** nie niższa niż generacja katalogu w wydanym
buildzie, inaczej klienci zignorują overlay w całości.

`SECURITY.md` bez zmian — overlay OTA jest tam już wskazany jako obszar wysokiej wartości.

## Zakres pominięty

Statusu overlaya nie wystawiamy w karcie Info tak, jak robi to `EndpointsOverlayStatus` dla
`endpoints.json`. Odrzucony overlay ląduje w logu, zgodnie ze zgłoszeniem; wyniesienie tego
do UI to osobna decyzja produktowa.
