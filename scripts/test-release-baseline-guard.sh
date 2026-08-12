#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test-release-baseline-guard.sh — test regresyjny REL-06.
#
# `release.sh` szuka poprzedniego wydania, żeby wiedzieć, od którego commita
# liczyć wpisy wywiedzione z historii. Gdy takiego wydania nie ma, notatki mają
# pochodzić wyłącznie z [Unreleased] — replay całej historii nie jest notatką
# wydania (RELEASING.md §9).
#
# Szukanie było zrobione przez `git rev-list --grep='^chore(release):'`, a
# `--grep` przeszukuje CAŁĄ treść commita i `^` łapie początek dowolnej linii,
# nie tylko tematu. Wystarczyło, że jakikolwiek commit wspomniał ten wzorzec w
# ciele — i tak właśnie commit `fix(release): do not replay the whole history
# when there is no previous release` sam stał się baseline'em, bo cytował
# `chore(release):` w wyjaśnieniu. Pierwsze wydanie dostawało przez to ~30
# doklejonych linii z SHA, duplikujących dopracowane wpisy.
#
# Guard sprawdza zachowanie prawdziwego skryptu na dwóch jednorazowych
# repozytoriach: pułapka nie może zostać baseline'em, a prawdziwy
# `chore(release):` w TEMACIE nadal musi nim być.
# ---------------------------------------------------------------------------
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
RELEASE_SH="$ROOT/scripts/release.sh"
failures=0

record_pass() { printf '  ✓ %s\n' "$1"; }
record_fail() {
    printf '  ✗ %s\n' "$1" >&2
    failures=$((failures + 1))
}

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/release-baseline-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT

# Repozytorium bez zdalnego: `require_in_sync` zwraca 0, gdy nie ma origin, więc
# atrapa przechodzi preflight bez udawania sieci.
make_repo() {
    local repo="$SANDBOX/$1"
    mkdir -p "$repo/Sources/WegaHelperKit"

    git -c init.defaultBranch=main init -q "$repo"
    git -C "$repo" config user.email guard@example.invalid
    git -C "$repo" config user.name  "Baseline Guard"

    cat > "$repo/Sources/WegaHelperKit/AppMetadata.swift" <<'SWIFT'
public enum AppMetadata {
    public static let displayName = "Wega Mac Updater"
    public static let version = "0.1.0"
    public static let bundleIdentifier = "com.wega.WegaMacUpdater"
}
SWIFT

    cat > "$repo/CHANGELOG.md" <<'MD'
# Changelog

## [Unreleased]

### Added
- Ręcznie napisany wpis, który ma trafić do notatek wydania.
MD

    git -C "$repo" add -A
    git -C "$repo" commit -q -m "feat: seed the fixture"
    printf '%s' "$repo"
}

run_release() { (cd "$1" && "$RELEASE_SH" minor --dry-run 2>&1); }

# --- przypadek 1: wzorzec wyłącznie w ciele commita ------------------------------------

echo "→ commit cytujący chore(release): w ciele nie jest wydaniem"

repo="$(make_repo trap)"
printf 'zmiana\n' > "$repo/plik.txt"
git -C "$repo" add -A
git -C "$repo" commit -q -F - <<'MSG'
fix(release): do not replay the whole history when there is no previous release

Baseline wykrywano zbyt szeroko. Gdy w repozytorium nie ma tagu ani commita
chore(release): commit to measure from, no commit-derived entries are generated
i notatki pochodzą z [Unreleased].
MSG

# Commit PO pułapce jest tu konieczny: bez niego druga asercja przechodziłaby
# dlatego, że nie ma czego dokleić, a nie dlatego, że baseline jest pusty.
printf 'po pulapce\n' > "$repo/po-pulapce.txt"
git -C "$repo" add -A
git -C "$repo" commit -q -m "feat: land something after the trap commit"

out="$(run_release "$repo")"

if printf '%s' "$out" | grep -q 'no previous release found'; then
    record_pass "baseline pusty — notatki idą z [Unreleased]"
else
    record_fail "commit z wzorcem w ciele został uznany za poprzednie wydanie"
    printf '%s\n' "$out" | grep -E '^>> (collected|no previous)' | sed 's/^/      /' >&2
fi

# Wpis wywiedziony z historii poznaje się po krótkim SHA na końcu linii — to on
# odróżnia doklejkę od wpisu napisanego ręcznie w [Unreleased].
if printf '%s\n' "$out" | grep -qE '^\+- .*\([0-9a-f]{7,}\)\s*$'; then
    record_fail "notatki dostały wpisy wywiedzione z historii"
    printf '%s\n' "$out" | grep -E '^\+- .*\([0-9a-f]{7,}\)\s*$' | head -3 | sed 's/^/      /' >&2
else
    record_pass "żaden wpis nie został wywiedziony z historii"
fi

# --- przypadek 2: prawdziwy chore(release): w temacie ----------------------------------

echo "→ prawdziwy chore(release): w temacie nadal jest baseline'em"

repo="$(make_repo real)"
printf 'wydanie\n' > "$repo/wydanie.txt"
git -C "$repo" add -A
git -C "$repo" commit -q -m "chore(release): v0.1.0"
printf 'po wydaniu\n' > "$repo/po.txt"
git -C "$repo" add -A
git -C "$repo" commit -q -m "feat: land something after the release"

out="$(run_release "$repo")"

if printf '%s' "$out" | grep -q 'no previous release found'; then
    record_fail "prawdziwy chore(release): w temacie został pominięty"
else
    record_pass "baseline znaleziony"
fi

if printf '%s\n' "$out" | grep -qE '^\+- .*\([0-9a-f]{7,}\)\s*$'; then
    record_pass "wpis po wydaniu trafił do notatek"
else
    record_fail "commit po wydaniu nie trafił do notatek"
    printf '%s\n' "$out" | grep -E '^>> ' | sed 's/^/      /' >&2
fi

if [[ "$failures" -gt 0 ]]; then
    printf '\n✗ guard REL-06 wykrył %d naruszenie/naruszenia\n' "$failures" >&2
    exit 1
fi

echo
echo "✅ guard REL-06 działa"
