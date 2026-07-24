#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test-sign-catalog-guard.sh — test regresyjny SEC-06.
#
# Sprawdza JEDNO zachowanie `sign-catalog.sh`: twardą odmowę, gdy wskazany klucz
# prywatny leży wewnątrz drzewa roboczego repozytorium. Klucz produkcyjny w repo to
# jedna pomyłka (`git add -f`, edycja .gitignore, backup katalogu) od ujawnienia
# i przymusowej rotacji — bramka musi być testowana, nie tylko opisana.
#
# Testy używają WYŁĄCZNIE plików-atrap ("NOT A REAL KEY"). Prawdziwy klucz nie jest
# tu nigdy czytany, kopiowany ani nawet wyszukiwany.
#
# Uruchomienie:  ./scripts/test-sign-catalog-guard.sh
# Kody wyjścia:  0 = wszystkie przypadki zielone · 1 = co najmniej jeden czerwony
# ---------------------------------------------------------------------------
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SIGN="$ROOT/scripts/sign-catalog.sh"

# Sprawdzone zanim powstanie cokolwiek do sprzątania: potwierdza, że ROOT wskazuje na
# to repozytorium, więc `rm -rf "$IN_REPO_DIR"` na pewno kasuje własną atrapę.
if [[ ! -x "$SIGN" ]]; then
    echo "błąd: nie znalazłem wykonywalnego $SIGN" >&2
    exit 1
fi

# Fragment komunikatu, po którym poznajemy, że odmówił GUARD, a nie coś innego
# (brak openssl 3, nieczytelny plik, zły podpis). Bez tego test przechodziłby na
# zielono przy dowolnym niezerowym wyjściu.
GUARD_MARKER="wewnątrz drzewa roboczego repozytorium"

# Literalna tylda przekazywana do skryptu jako tekst — to on ma ją rozwinąć, nie ta powłoka.
TILDE='~'

IN_REPO_DIR="$ROOT/.sec06-guard-test"
OUTSIDE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sec06-guard-test.XXXXXX")"
cleanup() { rm -rf "$IN_REPO_DIR" "$OUTSIDE_DIR"; }
trap cleanup EXIT

failures=0

record_pass() { printf '  ✓ %s\n' "$1"; }
record_fail() {
    printf '  ✗ %s\n' "$1" >&2
    printf '      %s\n' "$2" >&2
    failures=$((failures + 1))
}

# Uruchamia sign-catalog.sh w podpowłoce z podmienionym HOME i zwraca status w
# RUN_STATUS, a połączone wyjście w RUN_OUTPUT. HOME jest parametrem, bo tylko tak
# da się przetestować rozwijanie `~` bez dotykania prawdziwego katalogu domowego.
RUN_STATUS=0
RUN_OUTPUT=""
run_sign() {
    local home="$1" key="$2"
    RUN_OUTPUT="$(cd "$ROOT" && HOME="$home" WEGA_CATALOG_KEY="$key" "$SIGN" 2>&1)"
    RUN_STATUS=$?
}

expect_refused() {
    local name="$1" home="$2" key="$3"
    run_sign "$home" "$key"
    if [[ "$RUN_STATUS" -eq 0 ]]; then
        record_fail "$name" "skrypt zakończył się kodem 0 — brak odmowy"
        return
    fi
    case "$RUN_OUTPUT" in
        *"$GUARD_MARKER"*) record_pass "$name" ;;
        *) record_fail "$name" "kod $RUN_STATUS, ale bez komunikatu guarda; wyjście: ${RUN_OUTPUT:-<puste>}" ;;
    esac
}

expect_not_refused() {
    local name="$1" home="$2" key="$3"
    run_sign "$home" "$key"
    case "$RUN_OUTPUT" in
        *"$GUARD_MARKER"*) record_fail "$name" "guard odrzucił klucz spoza repo; wyjście: $RUN_OUTPUT" ;;
        *) record_pass "$name" ;;
    esac
}

mkdir -p "$IN_REPO_DIR/nested"
printf 'NOT A REAL KEY — SEC-06 test fixture\n' > "$IN_REPO_DIR/nested/dummy-key.pem"
printf 'NOT A REAL KEY — SEC-06 test fixture\n' > "$OUTSIDE_DIR/dummy-key.pem"

ln -s "$IN_REPO_DIR/nested/dummy-key.pem" "$OUTSIDE_DIR/link-into-repo.pem"
ln -s "$OUTSIDE_DIR/dummy-key.pem" "$IN_REPO_DIR/link-out-of-repo.pem"

echo "→ sign-catalog.sh odmawia klucza wewnątrz repo"

expect_refused "ścieżka bezwzględna w podkatalogu repo" \
    "$HOME" "$IN_REPO_DIR/nested/dummy-key.pem"

expect_refused "ścieżka względna wobec korzenia repo" \
    "$HOME" ".sec06-guard-test/nested/dummy-key.pem"

expect_refused "ścieżka z ../ wskazująca z powrotem do repo" \
    "$HOME" "$ROOT/scripts/../.sec06-guard-test/nested/dummy-key.pem"

# Dowiązanie spoza repo celujące w plik w repo: prawdziwe bajty klucza są w drzewie
# roboczym, więc to ten sam wyciek co ścieżka wprost.
expect_refused "dowiązanie spoza repo na plik w repo" \
    "$HOME" "$OUTSIDE_DIR/link-into-repo.pem"

# Dowiązanie W repo na plik poza repo: `git add -f` zapisze samo dowiązanie, ale
# każdy backup podążający za dowiązaniami (tar -h, cp -RL, rsync -L) wciągnie klucz.
expect_refused "dowiązanie w repo na plik poza repo" \
    "$HOME" "$IN_REPO_DIR/link-out-of-repo.pem"

expect_refused "ścieżka z ~ rozwijana do wnętrza repo" \
    "$ROOT" "$TILDE/.sec06-guard-test/nested/dummy-key.pem"

# Fallback bez gita: rozpakowany tarball albo sandbox CI bez katalogu .git. Wtedy
# drzewem roboczym jest katalog nadrzędny skryptu i guard nadal musi odmówić.
if git -C "$OUTSIDE_DIR" rev-parse --show-toplevel >/dev/null 2>&1; then
    echo "  — pomijam przypadek 'poza repozytorium git': $OUTSIDE_DIR sam leży w repo git"
else
    DETACHED="$OUTSIDE_DIR/detached-tree"
    mkdir -p "$DETACHED/scripts"
    cp "$SIGN" "$DETACHED/scripts/sign-catalog.sh"
    printf 'NOT A REAL KEY — SEC-06 test fixture\n' > "$DETACHED/dummy-key.pem"

    RUN_OUTPUT="$(WEGA_CATALOG_KEY="$DETACHED/dummy-key.pem" "$DETACHED/scripts/sign-catalog.sh" 2>&1)"
    RUN_STATUS=$?
    case "$RUN_STATUS:$RUN_OUTPUT" in
        0:*) record_fail "klucz w drzewie poza repozytorium git" "skrypt zakończył się kodem 0 — brak odmowy" ;;
        *"$GUARD_MARKER"*) record_pass "klucz w drzewie poza repozytorium git" ;;
        *) record_fail "klucz w drzewie poza repozytorium git" \
            "kod $RUN_STATUS, ale bez komunikatu guarda; wyjście: ${RUN_OUTPUT:-<puste>}" ;;
    esac
fi

echo "→ sign-catalog.sh nie rusza klucza spoza repo"

expect_not_refused "ścieżka bezwzględna poza repo" \
    "$HOME" "$OUTSIDE_DIR/dummy-key.pem"

expect_not_refused "ścieżka z ~ rozwijana poza repo" \
    "$OUTSIDE_DIR" "$TILDE/dummy-key.pem"

if [[ "$failures" -gt 0 ]]; then
    printf '\n✗ %d przypadek/przypadki nie przeszły\n' "$failures" >&2
    exit 1
fi

echo
echo "✅ guard SEC-06 działa"
