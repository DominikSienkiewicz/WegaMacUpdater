# „Cofnij aktualizacje” jako osobna zakładka

Data: 2026-08-11

## Problem

Sekcja „Cofnij aktualizację” (`UndoUpdateSection`) renderuje się na końcu listy w zakładce
Aktualizacje, pod wszystkimi sekcjami paczek i sekcją „Ręcznie zainstalowane”. Ta zakładka
niesie już select-all, cztery sekcje źródeł paczek, dwie sekcje aktualizacji ręcznych,
podgląd planu, kartę porzuconych casków, sekcję restartu i panel logu brew. Cofanie —
akcja na aktualizacjach **przeszłych** — konkuruje o uwagę z listą aktualizacji
**przyszłych**, a widać je dopiero po przewinięciu wszystkiego innego.

## Rozwiązanie

Cofanie dostaje własną pozycję w panelu bocznym, w sekcji *Narzędzia*, obok „Odinstaluj
aplikacje” i „Logi” — to również akcja naprawcza na tym, co już zainstalowane.

### Zakres

Przenoszona jest karta „Cofnij aktualizację” wraz z dialogiem potwierdzenia. Nie są
przenoszone:

- podpisy `rollbackCaption` przy sekcjach paczek („Bez automatycznego cofnięcia — Homebrew
  nie zachowuje poprzednich wersji formuł”) — opisują to, co użytkownik właśnie
  zainstaluje, więc należą do listy aktualizacji;
- odznaki `RollbackProtection.Verdict` w wierszach casków — z tego samego powodu;
- `RestartSection` — to dokończenie aktualizacji, nie jej cofnięcie, i przeniesienie go
  poza zakładkę groziłoby przeoczeniem prośby o restart.

## Architektura

### 1. Współrzędna nawigacji (`MacUpdaterCore`)

`SidebarSelection` zyskuje `case rollback` o `rawValue` `"rollback"`. Metoda
`migrating(legacyTab:)` pozostaje bez zmian: żadna wartość starego klucza
`wega.activeTab` nie mapuje na nową zakładkę, więc migrujący użytkownik ląduje tam, gdzie
był.

### 2. Prezentacja (`MacUpdater`)

- `SidebarTab` zyskuje `case rollback` z podpowiedzią „Co da się cofnąć”
  (`.navigationSubtitle`).
- `SidebarSelection.label` = „Cofnij aktualizacje”, `systemImage` =
  `arrow.uturn.backward.circle` — ten sam symbol, który dziś nosi nagłówek karty, żeby
  zmiana czytała się jako przeniesienie, a nie nowy byt.
- `WegaState.forTab(.rollback)` dostaje własną pozę i kwestię.
- `SidebarFocusPolicy.orderedSelections` zyskuje nową pozycję między `.migration`
  a `.uninstall` — kolejność czytania dla technologii wspomagających idzie za kolejnością
  wierszy w panelu.

### 3. Nowy widok `RollbackView`

Przejmuje z `UpdateView` komplet stanu cofania: `undoTarget`, `showUndoConfirmation` oraz
`.confirmationDialog` z przyciskiem „Przywróć wersję %@”. Renderuje `UndoUpdateSection`,
gdy `scan.undoableUpdates` jest niepuste, a `EmptyHero` w przeciwnym razie — pusty ekran
tłumaczy 7-dniowe okno retencji, zamiast tylko stwierdzać, że nic nie ma.

`onAppear` woła `scan.refreshUndoableUpdates()`, bo między poprzednim odświeżeniem
a wejściem na zakładkę zamiatanie retencji mogło usunąć snapshot.

`UndoUpdateSection` zostaje w `UpdateViewSupport.swift`: to samodzielny komponent, którego
przeniesienie do innego pliku tylko zaszumiłoby diff.

### 4. `UpdateView`

Znikają dwa `@State`, dialog cofania i blok renderujący `UndoUpdateSection` z `listColumn`.

Zostaje `scan.refreshUndoableUpdates()` w `onAppear`. `UpdateView` jest zamontowany przez
całą sesję (patrz komentarz w `DetailColumn.tabBody`), więc to on odpowiada za to, że
licznik w panelu bocznym jest poprawny, zanim ktokolwiek wejdzie na nową zakładkę.

### 5. Licznik w panelu bocznym

`ScanSinks` zyskuje `undoableCount: ((Int) -> Void)?`, wołane z
`ScanStore.refreshUndoableUpdates()` — jedyne miejsce, przez które przechodzi każda zmiana
tej listy (start, skan, cofnięcie). `ContentView` trzyma `@State rollbackBadge` dokładnie
jak pozostałe liczniki i podaje go do `SidebarList`.

Świadomie **nie** wstrzykujemy `ScanStore` do `ContentView`: korzeń okna zacząłby się
przeliczać przy każdej publikacji store'u w trakcie skanu, a `ContentView` niesie osobne
komentarze o pętlach constraintów w `NavigationSplitView` (stała szerokość panelu,
`GeometryReader` w `DetailColumn`). Ten obszar nie jest przedmiotem tej zmiany.

Odznaka jest karmelowa (`isDanger: false`) — możliwość, nie alarm.

### 6. Panel boczny

Sekcja *Narzędzia* w kolejności: **Cofnij aktualizacje** → Odinstaluj aplikacje → Logi.

### 7. `DetailColumn`

`RollbackView` montuje się na żądanie w `switch selection`, jak pozostałe destynacje poza
`UpdateView`. Panel szczegółów (`.inspector`) pozostaje zarezerwowany dla Aktualizacji —
warunek `selection.tab == .update` nie wymaga zmiany.

## Testy

- `SidebarSelectionTests`: `.rollback` dołącza do `everyCase` (round-trip przez `rawValue`)
  i do asercji `filter == nil`.
- Nowa asercja: `SidebarFocusPolicy.orderedSelections` pokrywa każdy przypadek
  `SidebarSelection`. Dziś ta lista jest ręczna, a `accessibilityPriority` cicho zwraca `0`
  dla pozycji, której na niej brak — to jedyna pułapka, jaką ta zmiana otwiera, więc
  zamykamy ją testem zamiast czujnością.
- `LocalizationCompletenessTests` wymusza wpisy angielskie dla nowych tekstów.

## Dokumentacja

`USER_GUIDE.md` stwierdza, że sekcję cofania pokazuje okno Aktualizacji — po zmianie to
nieprawda. `README.md` opisuje wyłącznie wnętrze `ScanStore+Undo`, którego kontrakt się nie
zmienia.
