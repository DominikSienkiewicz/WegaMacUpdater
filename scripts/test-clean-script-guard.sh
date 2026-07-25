#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test-clean-script-guard.sh — test regresyjny QA-08.
#
# Rootowy clean.sh był jednorazowym generatorem o mylącej nazwie: nadpisywał
# źródła, robił `git add -A`, commitował na main i opcjonalnie usuwał worktree
# oraz gałąź. Ten guard nie pozwala przywrócić tej pułapki pod dawną nazwą ani
# schować równoważnych operacji w innym śledzonym skrypcie *clean.sh.
# ---------------------------------------------------------------------------
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
failures=0

record_pass() { printf '  ✓ %s\n' "$1"; }
record_fail() {
    printf '  ✗ %s\n' "$1" >&2
    failures=$((failures + 1))
}

echo "→ brak niebezpiecznego clean.sh"

if [[ -e "$ROOT/clean.sh" || -L "$ROOT/clean.sh" ]]; then
    record_fail "rootowy clean.sh nadal istnieje"
else
    record_pass "brak clean.sh w katalogu głównym"
fi

while IFS= read -r -d '' script; do
    script_path="$ROOT/$script"
    [[ -f "$script_path" ]] || continue

    if grep -Eq 'git[[:space:]]+add[[:space:]]+(-A|--all)([[:space:]]|$)' "$script_path"; then
        record_fail "$script wykonuje git add -A/--all"
    fi

    if grep -Eq 'git[[:space:]]+commit([[:space:]]|$)' "$script_path" \
        && grep -Eq '(^|[^[:alnum:]_])main([^[:alnum:]_]|$)' "$script_path"; then
        record_fail "$script może commitować bezpośrednio na main"
    fi

    if grep -Eq 'git[[:space:]]+worktree[[:space:]]+remove([[:space:]]|$)' "$script_path" \
        || grep -Eq 'git[[:space:]]+branch[[:space:]]+(-d|-D|--delete)([[:space:]]|$)' "$script_path"; then
        record_fail "$script może usuwać worktree lub gałąź"
    fi
done < <(git -C "$ROOT" ls-files -z -- '*clean.sh')

if [[ "$failures" -gt 0 ]]; then
    printf '\n✗ guard QA-08 wykrył %d zagrożenie/zagrożenia\n' "$failures" >&2
    exit 1
fi

echo
echo "✅ guard QA-08 działa"
