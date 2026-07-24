#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test-merge.sh — testy zabezpieczeń `merge.sh`.
#
# `merge.sh` integruje gałęzie do `main` i kasuje gałąź razem z worktree, więc
# jego bramki muszą być testowane, a nie tylko opisane w nagłówku: pomyłka kosztuje
# albo zepsute `main`, albo utraconą pracę.
#
# Każdy przypadek dostaje własne, jednorazowe repozytorium w $TMPDIR. Prawdziwe
# repozytorium projektu nie jest tu nigdy modyfikowane — sprawdzane jest to na
# starcie i asercją po każdym przypadku.
#
# Uruchomienie:  ./scripts/test-merge.sh
# Kody wyjścia:  0 = wszystkie przypadki zielone · 1 = co najmniej jeden czerwony
# ---------------------------------------------------------------------------
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
MERGE="$ROOT/scripts/merge.sh"

if [[ ! -x "$MERGE" ]]; then
    echo "błąd: nie znalazłem wykonywalnego $MERGE" >&2
    exit 1
fi

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/merge-helper-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT

# Stan repozytorium projektu sprzed testów — porównywany na końcu, żeby wykryć, że
# któryś przypadek wyszedł poza swój sandbox. Porównanie ze snapshotem, nie z „czysto",
# bo testy bywają uruchamiane na gałęzi z niezacommitowaną pracą.
REPO_STATE_BEFORE="$(git -C "$ROOT" status --porcelain)"

failures=0
record_pass() { printf '  ✓ %s\n' "$1"; }
record_fail() {
    printf '  ✗ %s\n' "$1" >&2
    printf '      %s\n' "$2" >&2
    failures=$((failures + 1))
}

# make_repo <nazwa> — repozytorium z gałęzią main, jednym commitem i kopią merge.sh.
# Zwraca ścieżkę przez echo. Tożsamość ustawiana lokalnie, żeby test nie zależał od
# globalnej konfiguracji gita ani jej nie zmieniał.
make_repo() {
    local repo="$SANDBOX/$1"
    mkdir -p "$repo/scripts"
    git -C "$repo" init -q -b main
    git -C "$repo" config user.email "test@example.invalid"
    git -C "$repo" config user.name "merge.sh test"
    # Tak jak w prawdziwym repo projektu: linked worktrees są wyłączone lokalnie,
    # nie przez śledzony .gitignore.
    printf '/.worktrees/\n' >> "$repo/.git/info/exclude"
    cp "$MERGE" "$repo/scripts/merge.sh"
    chmod +x "$repo/scripts/merge.sh"
    printf 'a\n' > "$repo/f.txt"
    git -C "$repo" add -A
    git -C "$repo" commit -qm "init"
    echo "$repo"
}

# add_gate <repo> <kod-wyjścia> — atrapa bramki jakości w miejscu, w którym merge.sh
# jej szuka. Prawdziwy check.sh wymaga Xcode; tu liczy się wyłącznie kod wyjścia.
add_gate() {
    printf '#!/usr/bin/env bash\nexit %s\n' "$2" > "$1/scripts/check.sh"
    chmod +x "$1/scripts/check.sh"
    git -C "$1" add -A
    git -C "$1" commit -qm "gate"
}

# feature_branch <repo> <gałąź> <treść> — gałąź w osobnym worktree, tak jak w realnym
# przepływie pracy (AGENTS.md: .worktrees/<nazwa>).
feature_branch() {
    local repo="$1" branch="$2" content="$3"
    git -C "$repo" worktree add -q -b "$branch" "$repo/.worktrees/$branch" main
    printf '%s\n' "$content" > "$repo/.worktrees/$branch/f.txt"
    git -C "$repo" -C "$repo/.worktrees/$branch" add -A
    git -C "$repo/.worktrees/$branch" commit -qm "feature change"
}

RUN_STATUS=0
RUN_OUTPUT=""
run_merge() {
    local repo="$1"; shift
    RUN_OUTPUT="$(cd "$repo" && ./scripts/merge.sh "$@" 2>&1)"
    RUN_STATUS=$?
}

# ---------------------------------------------------------------------------
echo "→ merge.sh odrzuca wywołania, które mogłyby zepsuć repozytorium"

repo="$(make_repo brak-wiadomosci)"
feature_branch "$repo" feat/x b
run_merge "$repo" feat/x
if [ "$RUN_STATUS" -eq 2 ] && [[ "$RUN_OUTPUT" == *"merge message is required"* ]]; then
    record_pass "brak wiadomości scalenia → exit 2, nic nie scalone"
else
    record_fail "brak wiadomości scalenia" "kod $RUN_STATUS; wyjście: $RUN_OUTPUT"
fi

repo="$(make_repo chroniona)"
run_merge "$repo" main "scalenie main"
if [ "$RUN_STATUS" -eq 1 ] && [[ "$RUN_OUTPUT" == *"refusing"* ]]; then
    record_pass "gałąź chroniona jako argument → odmowa"
else
    record_fail "gałąź chroniona" "kod $RUN_STATUS; wyjście: $RUN_OUTPUT"
fi

repo="$(make_repo nieistniejaca)"
run_merge "$repo" feat/nie-ma "wiadomość"
if [ "$RUN_STATUS" -eq 1 ] && [[ "$RUN_OUTPUT" == *"does not exist"* ]]; then
    record_pass "nieistniejąca gałąź → odmowa"
else
    record_fail "nieistniejąca gałąź" "kod $RUN_STATUS; wyjście: $RUN_OUTPUT"
fi

repo="$(make_repo brudne-drzewo)"
feature_branch "$repo" feat/x b
printf 'niezacommitowana zmiana\n' >> "$repo/f.txt"
run_merge "$repo" feat/x "wiadomość" --no-fetch --no-verify
if [ "$RUN_STATUS" -eq 1 ] && [[ "$RUN_OUTPUT" == *"uncommitted changes"* ]]; then
    record_pass "śledzona zmiana w drzewie głównym → odmowa przed scaleniem"
else
    record_fail "brudne drzewo główne" "kod $RUN_STATUS; wyjście: $RUN_OUTPUT"
fi

# Nieśledzony plik sam w sobie nie może blokować scalenia — build output i pliki
# robocze leżą w drzewie stale. Blokuje wyłącznie ten, który scalenie by nadpisało.
repo="$(make_repo nieslednony-obojetny)"
feature_branch "$repo" feat/x b
printf 'smieci\n' > "$repo/nieistotny.txt"
run_merge "$repo" feat/x "feat: zmiana" --no-fetch --no-verify
if [ "$RUN_STATUS" -eq 0 ]; then
    record_pass "nieśledzony plik poza zakresem scalenia nie blokuje"
else
    record_fail "nieśledzony plik obojętny" "kod $RUN_STATUS; wyjście: $RUN_OUTPUT"
fi

# Dokładnie ten przypadek, w którym git przerywa scalenie w połowie: gałąź wnosi nowy
# śledzony plik, a w drzewie głównym leży nieśledzony plik o tej samej ścieżce.
repo="$(make_repo nieslednony-kolizja)"
git -C "$repo" worktree add -q -b feat/x "$repo/.worktrees/feat/x" main
printf 'wersja z galezi\n' > "$repo/.worktrees/feat/x/nowy.txt"
git -C "$repo/.worktrees/feat/x" add -A
git -C "$repo/.worktrees/feat/x" commit -qm "dodaje nowy.txt"
printf 'wersja lokalna, nieśledzona\n' > "$repo/nowy.txt"
main_before="$(git -C "$repo" rev-parse main)"
run_merge "$repo" feat/x "feat: zmiana" --no-fetch --no-verify
main_after="$(git -C "$repo" rev-parse main)"
if [ "$RUN_STATUS" -eq 1 ] \
   && [[ "$RUN_OUTPUT" == *"would be overwritten"* ]] \
   && [[ "$RUN_OUTPUT" == *"nowy.txt"* ]] \
   && [ "$main_before" = "$main_after" ]; then
    record_pass "nieśledzony plik, który scalenie by nadpisało → odmowa, main nietknięte"
else
    record_fail "nieśledzona kolizja" \
        "kod $RUN_STATUS; main przed=$main_before po=$main_after; wyjście: $RUN_OUTPUT"
fi

# ---------------------------------------------------------------------------
echo "→ merge.sh nie zostawia main w stanie pośrednim"

repo="$(make_repo konflikt)"
feature_branch "$repo" feat/x b
printf 'c\n' > "$repo/f.txt"
git -C "$repo" commit -qam "zmiana na main"
main_before="$(git -C "$repo" rev-parse main)"
run_merge "$repo" feat/x "wiadomość" --no-fetch --no-verify
main_after="$(git -C "$repo" rev-parse main)"
if [ "$RUN_STATUS" -eq 1 ] \
   && [[ "$RUN_OUTPUT" == *"conflicts with"* ]] \
   && [[ "$RUN_OUTPUT" == *"f.txt"* ]] \
   && [ "$main_before" = "$main_after" ]; then
    record_pass "konflikt wykryty w próbie generalnej → main nietknięte, ścieżka wskazana"
else
    record_fail "konflikt wykryty przed scaleniem" \
        "kod $RUN_STATUS; main przed=$main_before po=$main_after; wyjście: $RUN_OUTPUT"
fi

# ---------------------------------------------------------------------------
echo "→ merge.sh traktuje bramkę jakości jako warunek sprzątania"

repo="$(make_repo bramka-czerwona)"
add_gate "$repo" 1
feature_branch "$repo" feat/x b
run_merge "$repo" feat/x "feat: zmiana" --no-fetch
branch_survived=0
git -C "$repo" show-ref --verify --quiet refs/heads/feat/x && branch_survived=1
merged=0
git -C "$repo" merge-base --is-ancestor feat/x main && merged=1
if [ "$RUN_STATUS" -eq 1 ] \
   && [[ "$RUN_OUTPUT" == *"quality gate failed"* ]] \
   && [ "$branch_survived" -eq 1 ] \
   && [ "$merged" -eq 1 ]; then
    record_pass "czerwona bramka → scalenie zostaje, gałąź NIE skasowana, podany undo"
else
    record_fail "czerwona bramka blokuje sprzątanie" \
        "kod $RUN_STATUS; gałąź=$branch_survived scalone=$merged; wyjście: $RUN_OUTPUT"
fi

repo="$(make_repo bramka-zielona)"
add_gate "$repo" 0
feature_branch "$repo" feat/x b
run_merge "$repo" feat/x "feat: zmiana" --no-fetch
branch_gone=1
git -C "$repo" show-ref --verify --quiet refs/heads/feat/x && branch_gone=0
worktree_gone=1
[ -d "$repo/.worktrees/feat/x" ] && worktree_gone=0
is_merge_commit=0
[ "$(git -C "$repo" rev-list --parents -n1 main | wc -w | tr -d ' ')" = "3" ] && is_merge_commit=1
if [ "$RUN_STATUS" -eq 0 ] \
   && [ "$branch_gone" -eq 1 ] \
   && [ "$worktree_gone" -eq 1 ] \
   && [ "$is_merge_commit" -eq 1 ]; then
    record_pass "zielona bramka → commit scalenia (--no-ff), worktree i gałąź posprzątane"
else
    record_fail "ścieżka szczęśliwa" \
        "kod $RUN_STATUS; gałąź_usunięta=$branch_gone worktree_usunięty=$worktree_gone merge_commit=$is_merge_commit; wyjście: $RUN_OUTPUT"
fi

repo="$(make_repo bramka-pominieta)"
add_gate "$repo" 1
feature_branch "$repo" feat/x b
run_merge "$repo" feat/x "feat: zmiana" --no-fetch --no-verify
if [ "$RUN_STATUS" -eq 0 ] && [[ "$RUN_OUTPUT" == *"skipping"* ]]; then
    record_pass "--no-verify pomija bramkę świadomie i to mówi"
else
    record_fail "--no-verify" "kod $RUN_STATUS; wyjście: $RUN_OUTPUT"
fi

# ---------------------------------------------------------------------------
if [ "$(git -C "$ROOT" status --porcelain)" != "$REPO_STATE_BEFORE" ]; then
    record_fail "testy nie zmieniają repozytorium projektu" \
        "git status w $ROOT różni się od stanu sprzed testów"
fi

printf '\n'
if [ "$failures" -eq 0 ]; then
    echo "✅ zabezpieczenia merge.sh działają"
    exit 0
fi
printf '❌ %s przypadek/przypadki nie przeszły\n' "$failures" >&2
exit 1
