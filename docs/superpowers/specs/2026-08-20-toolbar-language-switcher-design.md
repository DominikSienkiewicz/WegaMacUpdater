# Przełącznik języka w toolbarze głównego okna

Data: 2026-08-20

## Problem

Przełącznik języka jest dziś dostępny wyłącznie w oknie Ustawień (`⌘,`), jako
karta `languageCard` w `InfoView` — trzecia od góry, za ikoną zębatki w toolbarze.
Główne okno nie niesie żadnego śladu po tym, że język da się zmienić.

Wega startuje w języku systemu: `defaultLanguage(preferredLanguages:)` bierze
pierwszy język z `Locale.preferredLanguages`, który aplikacja zna, a wszystko poza
polskim i angielskim spada na angielski. Scenariusz „użytkownik nieznający polskiego
dostaje polski interfejs" nie jest więc powszechny — dotyczy osoby, która ma macOS
ustawiony po polsku, ale polskiego nie czyta (współdzielony Mac, ekspat, ktoś kto raz
przestawił system).

Niezależnie od częstości tego przypadku, przełączenie języka jest operacją, której
użytkownik szuka wzrokiem po głównym oknie, a nie w ustawieniach. Ikona globusa jest
konwencją rozpoznawalną bez czytania czegokolwiek — i to jest właściwe lekarstwo na
sytuację, w której użytkownik nie rozumie ani jednego napisu na ekranie.

## Rozwiązanie

Nowa pozycja w toolbarze kolumny detalu w `ContentView`: `Menu` z ikoną SF Symbol
`globe`, rozwijane na listę języków z zaznaczeniem aktywnego.

### Umiejscowienie

Za istniejącym `ToolbarSpacer(.fixed)`, przed `SettingsLink` z zębatką. Toolbar dzieli
się wtedy na dwie czytelne grupy: akcja skanowania po jednej stronie separatora,
ustawienia okna (język, ustawienia, panel szczegółów) po drugiej. Globus nie sąsiaduje
z `ScanControl`, więc nie sugeruje związku z operacją skanowania.

### Kontrolka

`Picker` w stylu `.inline`, związany z `$localization.language`, wypełniany z
`AppLanguage.allCases` — flaga plus nazwa własna języka, dokładnie jak w karcie
w Ustawieniach. `Picker` sam rysuje ptaszek przy aktywnej pozycji, więc menu odpowiada
na pytanie „w jakim języku właściwie jestem" bez dodatkowego opisu.

`ContentView` musi zyskać `@EnvironmentObject private var localization: LocalizationManager`.
Manager jest już wstrzykiwany w korzeniu sceny (`MacUpdaterApp.swift:31`), więc nie
wymaga to zmian w kompozycji aplikacji.

### Dostępność

Ikona jest bezopisowa, więc pozycja niesie parę `.help(tr("Język interfejsu"))` oraz
`.accessibilityLabel(tr("Język interfejsu"))` — zgodnie z regułą, którą pilnuje
`ToolbarIconAccessibilityTests`.

### Tłumaczenia

Żadnych nowych kluczy. `"Język interfejsu"` istnieje już w `Translations.swift` jako
`"Interface language"`; nazwy języków (`Polski`, `English`) i flagi pochodzą
z `AppLanguage`, który nie przechodzi przez tablicę tłumaczeń.

## Co pozostaje bez zmian

Karta `languageCard` w `InfoView` zostaje na miejscu. Obie kontrolki wiążą się z tym
samym `@Published var language` w `LocalizationManager`, więc nie powstaje zdublowany
stan — jest jeden przełącznik pokazany w dwóch miejscach, a zmiana w jednym natychmiast
odbija się w drugim. Usunięcie karty byłoby regresją dla użytkownika, który już wie,
gdzie jej szukać.

Nagłówek karty używa dziś ikony `globe` (`InfoView.swift:87`). Toolbar sięga po tę samą
ikonę, więc oba miejsca czytają się jako jedna funkcja, a nie dwie osobne.

## Propagacja zmiany języka

Nie wymaga żadnej nowej pracy. `MacUpdaterApp` trzyma `.id(localization.language)` na
korzeniu sceny okna głównego i sceny Ustawień, więc przełączenie języka przebudowuje
całe drzewo widoków niezależnie od tego, która kontrolka je wywołała.

### Znany skutek uboczny

Nowa tożsamość widoku zeruje `@State` w `ContentView` — w tym `showInspector`, które
wraca do wartości domyślnej, przez co panel szczegółów zamyka się (albo otwiera) przy
zmianie języka. Zachowanie to istnieje już dziś przy przełączeniu z okna Ustawień; nowe
jest wyłącznie to, że użytkownik zobaczy je natychmiast, we własnym oknie.

**Poprawka wykonana osobno (2026-08-20), innym sposobem niż zapowiadany tutaj.**
Pierwotnie zapisano tu, że lekarstwem jest podniesienie `showInspector` do `@AppStorage`,
tak jak zrobiono z `selection`. To było błędne i groźne: `@AppStorage` przywróciłby
otwarty inspektor przy starcie, a natywny inspektor obecny podczas pierwszego przebiegu
layoutu okna potrafi doprowadzić AppKit do rekurencyjnego unieważniania constraintów
`NavigationSplitView` i przerwania procesu. Dokładnie temu służą `showsInspectorAtLaunch`
oraz `StartupLayoutTests`.

Zastosowano wzorzec, którego to repozytorium już używa: flaga przeniosła się do
`WegaMacUpdaterApp`, ponad `.id(localization.language)` — tam, gdzie z tego samego powodu
siedzą `ScanStore`, `MigrationStore` i `WegaCommandCenter` — i trafia do `ContentView`
jako `@Binding`. Przeżywa przełączenie języka, a jako `@State` sceny nadal startuje
zamknięta przy każdym uruchomieniu.

## Testy

`ToolbarIconAccessibilityTests` (target `MacUpdaterUITests`) pilnuje toolbara przez
inspekcję źródła — target pakietowy nie może sterować `XCUIApplication`. Nowy przypadek
w tym samym pliku i w tej samej konwencji sprawdza, że `ContentView` zawiera pozycję
globusa związaną z `$localization.language`.

Trzeci, istniejący test w tym pliku — zliczający wystąpienia `.help(tr(` i porównujący
je z liczbą `.accessibilityLabel(tr(` — obejmie nową ikonę automatycznie i zerwie się,
jeśli para etykiet kiedykolwiek się rozjedzie.

`LocalizationCompletenessTests` nie wymaga uzupełnienia, bo funkcja nie wprowadza
nowych kluczy tłumaczeń.

## Odrzucone warianty

**Stopka paska bocznego.** Globus z nazwą aktywnego języka na dole `SidebarList`.
Nie konkurowałby z toolbarem o miejsce, ale sidebar jest dziś czystą `List` bez stopki,
a jego szerokość jest przypięta na sztywno (`navigationSplitViewColumnWidth(240)`)
właśnie dlatego, że zmiany geometrii podczas skanu potrafiły wywołać nieskończoną pętlę
constraintów w AppKit. Nieproporcjonalne ryzyko wobec zysku.

**Wyłącznie pozycja w menu bar.** Zerowy koszt wizualny, ale tytuł menu również jest
przetłumaczony, więc użytkownikowi, który nie rozumie interfejsu, nie pomaga. Możliwy
dodatek w przyszłości, nie zamiennik.

**Flaga zamiast globusa, przełączająca za jednym kliknięciem.** Oszczędza jedno
kliknięcie, ale nie odpowiada na pytanie, czy flaga oznacza język aktywny czy docelowy,
i przestaje działać z chwilą dodania trzeciego języka.

**Wybór języka przy pierwszym uruchomieniu.** Trafia w moment zagubienia, ale przerywa
start także tym użytkownikom, dla których dopasowanie do języka systemu zadziałało —
i nie pomaga nikomu, kto chce przełączyć język później.
