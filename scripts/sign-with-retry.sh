#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# sign-with-retry.sh — biblioteka do wczytania (`source`), nie skrypt do uruchamiania.
# Ma bit wykonywalności jak każdy scripts/*.sh (QA-03), ale uruchomiona wprost tylko
# to mówi i kończy się kodem 2.
#
# Podpis tożsamością Developer ID pyta serwer znaczników czasu Apple. Gdy runner
# chwilowo nie dostaje odpowiedzi, codesign czeka ~15 s i kończy się komunikatem
# „A timestamp was expected but was not found." — tak padły próby 2 i 3 wydania
# v0.7.0, choć ten sam commit podpisał się rano bez problemu. To błąd sieci, nie
# podpisu, więc polecenie jest ponawiane — ale tylko wtedy, gdy jego komunikat
# mówi o znaczniku czasu. Zła tożsamość czy uszkodzony plik kończą build od razu.
#
# Użycie:
#   source "$SCRIPT_DIR/sign-with-retry.sh"
#   sign_with_retry codesign --force --timestamp --sign "$IDENTITY" "$FILE"
#
# Środowisko:
#   SIGN_RETRY_ATTEMPTS       łączna liczba prób (domyślnie 5)
#   SIGN_RETRY_DELAY_SECONDS  przerwa przed drugą próbą, każda kolejna dwa razy
#                             dłuższa (domyślnie 15: 15, 30, 60, 120 s)
#
# Pinowane przez scripts/test-sign-retry-guard.sh.
# ---------------------------------------------------------------------------

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    echo "sign-with-retry.sh to biblioteka — wczytaj ją: source \"\$SCRIPT_DIR/sign-with-retry.sh\"" >&2
    exit 2
fi

sign_with_retry() {
    local attempts="${SIGN_RETRY_ATTEMPTS:-5}"
    local delay="${SIGN_RETRY_DELAY_SECONDS:-15}"
    local attempt=1 status stderr_file
    stderr_file="$(mktemp "${TMPDIR:-/tmp}/sign-with-retry.XXXXXX")"

    while :; do
        "$@" 2>"$stderr_file" && status=0 || status=$?
        cat "$stderr_file" >&2
        if (( status == 0 || attempt >= attempts )) || ! grep -qi 'timestamp' "$stderr_file"; then
            rm -f "$stderr_file"
            return "$status"
        fi
        echo "   ⟳ Serwer znaczników czasu Apple nie odpowiedział — próba $((attempt + 1))/$attempts za ${delay} s: $1 ${*: -1}" >&2
        sleep "$delay"
        delay=$((delay * 2))
        attempt=$((attempt + 1))
    done
}
