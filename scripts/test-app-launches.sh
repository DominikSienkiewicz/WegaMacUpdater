#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test-app-launches.sh — smoke test wydania v0.2.0.
#
# Opublikowany build ginął po starcie, na każdym Macu, a wszystkie bramki
# świeciły na zielono. `swift test` przechodził, bo pod testami zasoby leżą
# tam, gdzie szuka ich akcesor SwiftPM; verify-bundle.sh przechodził, bo
# sprawdza, czy pliki są w bundlu, a nie czy program potrafi je odczytać.
# Nic w pipelinie nigdy nie uruchomiło aplikacji przed jej wydaniem.
#
# Pierwsza wersja tej bramki po prostu startowała aplikację i patrzyła, czy
# przeżyje kilka sekund. Zmierzone na wydanym buildzie: dwie awarie na trzy
# uruchomienia — feralna ścieżka wychodzi z dławionego zadania w tle, więc co
# trzeci przebieg byłby zielony mimo zepsutej aplikacji. Bramka o losowym
# wyniku uczy ignorowania jej wyników, więc pytamy wprost.
#
# Aplikacja odpowiada na ukrytą flagę: rozwiązuje swój bundle zasobów, ładuje
# endpoints.json i app-catalog.json tymi samymi publicznymi wywołaniami co
# reszta kodu, i kończy się kodem 0 albo 1. Bez interfejsu, bez okna, bez
# zależności od window servera na runnerze.
# ---------------------------------------------------------------------------
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
APP="${1:-$ROOT/.build/pkg-staging/WegaMacUpdater.app}"
BIN="$APP/Contents/MacOS/WegaMacUpdater"
FLAG="--wega-selfcheck-resources"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-30}"

echo "→ spakowana aplikacja odczytuje własne zasoby"

if [[ ! -x "$BIN" ]]; then
    echo "  ✗ brak binarki $BIN — uruchom najpierw ./scripts/build-pkg.sh" >&2
    exit 1
fi

OUT="$(mktemp -t wega-smoke)"
trap 'rm -f "$OUT"' EXIT

# Sonda nie otwiera okna, ale limit czasu zostaje: zawieszenie ma być awarią,
# a nie zadaniem stojącym do końca limitu przebiegu.
"$BIN" "$FLAG" > "$OUT" 2>&1 &
PROBE_PID=$!

waited=0
while kill -0 "$PROBE_PID" 2>/dev/null && [[ "$waited" -lt "$TIMEOUT_SECONDS" ]]; do
    sleep 1
    waited=$((waited + 1))
done

if kill -0 "$PROBE_PID" 2>/dev/null; then
    kill -9 "$PROBE_PID" 2>/dev/null
    wait "$PROBE_PID" 2>/dev/null
    echo "  ✗ sonda nie odpowiedziała w ${TIMEOUT_SECONDS} s" >&2
    sed 's/^/      /' "$OUT" >&2
    exit 1
fi

wait "$PROBE_PID"
EXIT_CODE=$?

sed 's/^/      /' "$OUT"

if [[ "$EXIT_CODE" -ne 0 ]]; then
    echo >&2
    echo "✗ spakowana aplikacja nie potrafi odczytać swoich zasobów (kod $EXIT_CODE)" >&2
    exit 1
fi

echo
echo "✅ smoke test zasobów przeszedł"
