#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test-sign-retry-guard.sh — test regresyjny wydania v0.7.0.
#
# Próby 2 i 3 wydania v0.7.0 padły przy pierwszym podpisie Developer ID:
#
#   .../Contents/Helpers/WegaAskpass: A timestamp was expected but was not found.
#
# `codesign --timestamp` czekał ~15 s na serwer znaczników czasu Apple i się poddał.
# Ten sam commit podpisał się rano bez problemu, a serwer odpowiadał w tym czasie
# z innej sieci — to była chwilowa niedostępność z runnera, nie błąd podpisu.
# Jedno takie potknięcie kończyło całe zadanie wydania.
#
# Dlatego pinujemy dwie rzeczy:
#   1. sign_with_retry ponawia polecenie, gdy błąd dotyczy znacznika czasu, i tylko
#      wtedy — zła tożsamość czy uszkodzony plik nadal kończą build od razu;
#   2. każde polecenie build-pkg.sh, które podpisuje tożsamością Developer ID
#      (a więc pyta serwer znaczników czasu), idzie przez sign_with_retry.
#
# Czysty bash: codesign jest podmieniony na stub, nic nie jest naprawdę podpisywane.
# ---------------------------------------------------------------------------
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
LIB="$ROOT/scripts/sign-with-retry.sh"
BUILD_SCRIPT="$ROOT/scripts/build-pkg.sh"
failures=0

record_pass() { printf '  ✓ %s\n' "$1"; }
record_fail() {
    printf '  ✗ %s\n' "$1" >&2
    failures=$((failures + 1))
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-sign-retry.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

TIMESTAMP_ERROR="WegaAskpass: A timestamp was expected but was not found."
IDENTITY_ERROR="Developer ID Application: Example: no identity found"

# Stub codesign: pierwsze $STUB_FAILURES wywołań kończy się kodem $STUB_EXIT
# i komunikatem $STUB_MESSAGE na stderr, kolejne — sukcesem. Licznik w pliku.
STUB="$WORK/codesign"
cat > "$STUB" <<'STUB'
#!/usr/bin/env bash
count=$(( $(cat "$STUB_COUNTER" 2>/dev/null || echo 0) + 1 ))
echo "$count" > "$STUB_COUNTER"
if (( count <= STUB_FAILURES )); then
    echo "$STUB_MESSAGE" >&2
    exit "$STUB_EXIT"
fi
exit 0
STUB
chmod +x "$STUB"

# Uruchamia sign_with_retry tak, jak robi to build-pkg.sh: pod `set -euo pipefail`.
# Po powrocie z funkcji wypisuje znacznik, więc widać, czy skrypt szedłby dalej.
# Zostawia w RUN_STATUS kod wyjścia, w RUN_CALLS liczbę wywołań stuba,
# w RUN_OUTPUT całe wyjście.
run_case() {
    local failures_before_success="$1" message="$2" exit_code="$3" attempts="$4"
    local counter="$WORK/counter.$RANDOM"
    RUN_OUTPUT="$(
        STUB_COUNTER="$counter" \
        STUB_FAILURES="$failures_before_success" \
        STUB_MESSAGE="$message" \
        STUB_EXIT="$exit_code" \
        SIGN_RETRY_ATTEMPTS="$attempts" \
        SIGN_RETRY_DELAY_SECONDS=0 \
        bash -c 'set -euo pipefail
                 source "$1"
                 sign_with_retry "$2" --force --timestamp --sign "Developer ID Application: Example" target
                 echo "CONTINUED"' _ "$LIB" "$STUB" 2>&1
    )"
    RUN_STATUS=$?
    RUN_CALLS="$(cat "$counter" 2>/dev/null || echo 0)"
}

echo "→ podpis Developer ID przetrwa chwilową niedostępność serwera znaczników czasu"

if [[ ! -f "$LIB" ]]; then
    record_fail "brak $LIB — żaden podpis nie jest ponawiany, pierwszy brak znacznika czasu kończy wydanie"
else
    run_case 2 "$TIMESTAMP_ERROR" 1 5
    if [[ "$RUN_STATUS" -eq 0 && "$RUN_CALLS" -eq 3 && "$RUN_OUTPUT" == *CONTINUED* ]]; then
        record_pass "dwa braki znacznika czasu, potem sukces: 3 próby i build idzie dalej"
    else
        record_fail "dwa braki znacznika czasu, potem sukces: kod $RUN_STATUS, prób $RUN_CALLS (oczekiwano 0 i 3)"
    fi

    run_case 0 "" 0 5
    if [[ "$RUN_STATUS" -eq 0 && "$RUN_CALLS" -eq 1 && "$RUN_OUTPUT" == *CONTINUED* ]]; then
        record_pass "udany podpis: dokładnie jedna próba"
    else
        record_fail "udany podpis: kod $RUN_STATUS, prób $RUN_CALLS (oczekiwano 0 i 1)"
    fi

    run_case 99 "$IDENTITY_ERROR" 3 5
    if [[ "$RUN_STATUS" -eq 3 && "$RUN_CALLS" -eq 1 && "$RUN_OUTPUT" != *CONTINUED* ]]; then
        record_pass "błąd niezwiązany ze znacznikiem czasu: bez ponawiania, kod wyjścia polecenia zachowany"
    else
        record_fail "błąd niezwiązany ze znacznikiem czasu: kod $RUN_STATUS, prób $RUN_CALLS (oczekiwano 3 i 1, bez kontynuacji)"
    fi

    run_case 99 "$TIMESTAMP_ERROR" 1 3
    if [[ "$RUN_STATUS" -ne 0 && "$RUN_CALLS" -eq 3 && "$RUN_OUTPUT" != *CONTINUED* ]]; then
        record_pass "serwer nie wraca: po SIGN_RETRY_ATTEMPTS próbach build się zatrzymuje"
    else
        record_fail "serwer nie wraca: kod $RUN_STATUS, prób $RUN_CALLS (oczekiwano ≠0 i 3, bez kontynuacji)"
    fi

    if [[ "$RUN_OUTPUT" == *"$TIMESTAMP_ERROR"* ]]; then
        record_pass "komunikat codesign trafia do logu"
    else
        record_fail "komunikat codesign zniknął z logu — w CI nie byłoby widać, dlaczego podpis padł"
    fi
fi

# Każdy scripts/*.sh musi mieć bit wykonywalności (QA-03 w swift test), także biblioteka
# wczytywana przez `source`. Pierwsza wersja trafiła na main jako 100644 i zaczerwieniła
# bramkę jakości, od której zależy publikacja wydania. Uruchomiona wprost niczego by nie
# zrobiła, więc ma to powiedzieć i zakończyć się błędem, zamiast milczeć.
echo "→ sign-with-retry.sh jest wykonywalny, a uruchomiony wprost mówi, że trzeba go wczytać"

if [[ -x "$LIB" ]]; then
    record_pass "sign-with-retry.sh ma bit wykonywalności"
else
    record_fail "sign-with-retry.sh bez bitu wykonywalności — QA-03 zatrzyma swift test, a z nim wydanie"
fi

direct_output="$(bash "$LIB" 2>&1)"
direct_status=$?
if [[ "$direct_status" -eq 2 && "$direct_output" == *source* ]]; then
    record_pass "uruchomiony wprost kończy się kodem 2 i wskazuje source"
else
    record_fail "uruchomiony wprost: kod $direct_status (oczekiwano 2 i wskazówki o source)"
fi

echo "→ każdy podpis Developer ID w build-pkg.sh idzie przez sign_with_retry"

if grep -Eq '^(source|\.) "\$SCRIPT_DIR/sign-with-retry\.sh"' "$BUILD_SCRIPT"; then
    record_pass "build-pkg.sh wczytuje sign-with-retry.sh"
else
    record_fail "build-pkg.sh nie wczytuje sign-with-retry.sh"
fi

# Polecenia rozbite na wiele linii (`\` na końcu) skleja się w jedną linię logiczną.
# Podpis Developer ID to codesign/pkgbuild z tożsamością ze zmiennej — wariant ad-hoc
# (`--sign -`) nie pyta serwera znaczników czasu i nie musi być ponawiany.
logical_lines="$(awk '{ if (sub(/\\$/, "")) { buf = buf $0 " "; next } print buf $0; buf = "" }' "$BUILD_SCRIPT")"
signing_lines="$(grep -E '^[[:space:]]*(sign_with_retry[[:space:]]+)?(codesign|pkgbuild)[[:space:]]' <<<"$logical_lines" \
    | grep -E '\$(SIGN_IDENTITY|INSTALLER_IDENTITY)' || true)"
unwrapped="$(grep -Ev '^[[:space:]]*sign_with_retry[[:space:]]' <<<"$signing_lines" | grep -v '^$' || true)"

for tool in codesign pkgbuild; do
    if grep -Eq "^[[:space:]]*sign_with_retry[[:space:]]+${tool}[[:space:]]" <<<"$signing_lines"; then
        record_pass "$tool z tożsamością Developer ID jest ponawiany"
    else
        record_fail "brak $tool z tożsamością Developer ID wywołanego przez sign_with_retry"
    fi
done

if [[ -z "$unwrapped" ]]; then
    record_pass "żaden podpis Developer ID nie omija sign_with_retry"
else
    while IFS= read -r line; do
        record_fail "podpis bez ponawiania: $(sed -E 's/^[[:space:]]+//; s/[[:space:]]+/ /g' <<<"$line" | cut -c1-110)"
    done <<<"$unwrapped"
fi

if [[ "$failures" -gt 0 ]]; then
    printf '\n✗ guard ponawiania podpisu wykrył %d problem/problemy\n' "$failures" >&2
    exit 1
fi

echo
echo "✅ guard ponawiania podpisu działa"
