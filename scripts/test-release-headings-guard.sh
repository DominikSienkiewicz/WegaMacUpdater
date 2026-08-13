#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test-release-headings-guard.sh — test regresyjny REL-07.
#
# `release.sh` rozbija [Unreleased] na plik per nagłówek `### `, a nazwę pliku
# wyprowadzał z nagłówka przez `gsub(/[^A-Za-z]/, "", sec)` — po czym pętla
# awaryjna odtwarzała nagłówek z TEJ nazwy. Odwzorowanie jest stratne, więc
# ręcznie napisane `### Known issues` trafiało do notatek jako `### Knownissues`.
# Notatki stają się opisem GitHub Release dosłownie, więc nikt tego już potem
# nie poprawi.
#
# Ta sama stratność miała dwa dalsze skutki:
#   * `### Fixed!` sprowadzało się do `Fixed`, czyli do pliku sekcji kanonicznej —
#     nagłówek gubił `!`, a treść zlewała się z wpisami wywiedzionymi z commitów;
#   * dwa różne nagłówki o wspólnej nazwie po oczyszczeniu dzieliły jeden plik,
#     więc ich treści się sklejały.
#
# Osobno: treść napisana NAD pierwszym `### ` wewnątrz [Unreleased] przepadała
# bez śladu, bo awk zaczyna zapisywać dopiero po pierwszym nagłówku. Skrypt ma
# ją odrzucić z komunikatem, a nie połknąć.
#
# Guard sprawdza zachowanie prawdziwego skryptu na jednorazowych repozytoriach.
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

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/release-headings-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT

# Repozytorium bez zdalnego: `require_in_sync` zwraca 0, gdy nie ma origin, więc
# atrapa przechodzi preflight bez udawania sieci. Treść [Unreleased] jest
# argumentem, bo to ona jest przedmiotem każdego przypadku.
make_repo() {
    local repo="$SANDBOX/$1"
    mkdir -p "$repo/Sources/WegaHelperKit"

    git -c init.defaultBranch=main init -q "$repo"
    git -C "$repo" config user.email guard@example.invalid
    git -C "$repo" config user.name  "Headings Guard"

    cat > "$repo/Sources/WegaHelperKit/AppMetadata.swift" <<'SWIFT'
public enum AppMetadata {
    public static let displayName = "Wega Mac Updater"
    public static let version = "0.1.0"
    public static let bundleIdentifier = "com.wega.WegaMacUpdater"
}
SWIFT

    {
        printf '# Changelog\n\n## [Unreleased]\n\n'
        printf '%s\n' "${2-}"
    } > "$repo/CHANGELOG.md"

    git -C "$repo" add -A
    git -C "$repo" commit -q -m "feat: seed the fixture"
    printf '%s' "$repo"
}

# Wpisy wywiedzione z historii powstają dopiero po baseline'ie, więc przypadki
# mieszające sekcje ręczne z generowanymi muszą go najpierw postawić.
add_release_baseline() {
    printf 'wydanie\n' > "$1/wydanie.txt"
    git -C "$1" add -A
    git -C "$1" commit -q -m "chore(release): v0.1.0"
}

commit_work() {
    printf '%s\n' "$2" > "$1/$2.txt"
    git -C "$1" add -A
    git -C "$1" commit -q -m "$3"
}

# Bez `--dry-run`, żeby asercje czytały to, co skrypt naprawdę zapisuje: w diffie
# część notatek pokazuje się jako linie kontekstu, więc „linie dodane” to nie to
# samo co „notatki wydania”. Nic tu nie jest commitowane ani wypychane.
run_release() { (cd "$1" && "$RELEASE_SH" minor 2>&1); }

# Notatki wydania: sekcja świeżo dopisanej wersji, bez [Unreleased] i bez starszych.
release_notes() {
    awk '
        /^## \[0\.2\.0\]/ { inside = 1; next }
        inside && /^## \[/ { exit }
        inside { print }
    ' "$1/CHANGELOG.md"
}

# Treść jednej sekcji: wszystko między jej nagłówkiem a następnym `### `.
section_body() {
    printf '%s\n' "$1" | awk -v want="### $2" '
        $0 == want { inside = 1; next }
        /^### / { inside = 0 }
        inside && NF { print }
    '
}

count_headings() { printf '%s\n' "$1" | grep -c -F -x "$2"; }

# --- przypadek 1: nagłówek wielowyrazowy przechodzi bez zmian --------------------------

echo "→ ręczny nagłówek spoza zestawu kanonicznego trafia do notatek dosłownie"

repo="$(make_repo verbatim '### Known issues
- Skanowanie Homebrew potrafi zgłosić cask bez wersji.')"

run_release "$repo" > /dev/null
notes="$(release_notes "$repo")"

if printf '%s\n' "$notes" | grep -q -F -x '### Known issues'; then
    record_pass "nagłówek 'Known issues' zachował spację"
else
    record_fail "nagłówek 'Known issues' nie trafił do notatek w oryginalnym brzmieniu"
    printf '%s\n' "$notes" | grep '^### ' | sed 's/^/      /' >&2
fi

if printf '%s\n' "$notes" | grep -q -F -x '### Knownissues'; then
    record_fail "notatki dostały nagłówek sklejony z nazwy pliku ('Knownissues')"
fi

if [ "$(section_body "$notes" 'Known issues')" = "- Skanowanie Homebrew potrafi zgłosić cask bez wersji." ]; then
    record_pass "treść została pod swoim nagłówkiem"
else
    record_fail "treść sekcji 'Known issues' nie zgadza się z napisaną ręcznie"
fi

# --- przypadek 2: dwa nagłówki o wspólnej nazwie po oczyszczeniu -----------------------

echo "→ nagłówki zbiegające się po oczyszczeniu nie dzielą jednej sekcji"

repo="$(make_repo collision '### Known issues
- Wpis z sekcji pisanej ze spacją.

### Knownissues
- Wpis z sekcji pisanej bez spacji.')"

run_release "$repo" > /dev/null
notes="$(release_notes "$repo")"

if [ "$(count_headings "$notes" '### Known issues')" = "1" ] &&
   [ "$(count_headings "$notes" '### Knownissues')" = "1" ]; then
    record_pass "oba nagłówki wystąpiły dokładnie raz"
else
    record_fail "kolizja nazw zgubiła albo zdublowała nagłówek"
    printf '%s\n' "$notes" | grep '^### ' | sed 's/^/      /' >&2
fi

if [ "$(section_body "$notes" 'Known issues')" = "- Wpis z sekcji pisanej ze spacją." ] &&
   [ "$(section_body "$notes" 'Knownissues')" = "- Wpis z sekcji pisanej bez spacji." ]; then
    record_pass "każda sekcja zatrzymała własną treść"
else
    record_fail "treści zbiegających się sekcji zostały sklejone"
    printf '%s\n' "$notes" | grep -E '^(### |- )' | sed 's/^/      /' >&2
fi

# --- przypadek 3: nagłówek oczyszczający się na nazwę kanoniczną -----------------------

echo "→ '### Fixed!' nie przejmuje sekcji kanonicznej '### Fixed'"

repo="$(make_repo canonical_lookalike '### Fixed!
- Ręczny wpis pod nagłówkiem z wykrzyknikiem.')"
add_release_baseline "$repo"
commit_work "$repo" "naprawa" "fix(scan): stop reporting a cask without a version"

run_release "$repo" > /dev/null
notes="$(release_notes "$repo")"

if printf '%s\n' "$notes" | grep -q -F -x '### Fixed!'; then
    record_pass "nagłówek 'Fixed!' zachował wykrzyknik"
else
    record_fail "nagłówek 'Fixed!' został podmieniony na kanoniczny 'Fixed'"
    printf '%s\n' "$notes" | grep '^### ' | sed 's/^/      /' >&2
fi

if [ "$(section_body "$notes" 'Fixed!')" = "- Ręczny wpis pod nagłówkiem z wykrzyknikiem." ]; then
    record_pass "ręczna sekcja nie wciągnęła wpisów wywiedzionych z commitów"
else
    record_fail "sekcja 'Fixed!' zlała się z wpisami generowanymi"
    printf '%s\n' "$notes" | grep -E '^(### |- )' | sed 's/^/      /' >&2
fi

if section_body "$notes" 'Fixed' | grep -qE '^- .*\([0-9a-f]{7,}\)$'; then
    record_pass "wpis wywiedziony z commita trafił pod kanoniczne 'Fixed'"
else
    record_fail "kanoniczne 'Fixed' nie dostało wpisu wywiedzionego z commita"
    printf '%s\n' "$notes" | grep -E '^(### |- )' | sed 's/^/      /' >&2
fi

# --- przypadek 4: sekcja kanoniczna nadal scala wpis ręczny z generowanym --------------

echo "→ sekcja kanoniczna wciąż łączy wpis ręczny z wywiedzionym z commita"

repo="$(make_repo canonical '### Added
- Ręcznie opisana nowość.')"
add_release_baseline "$repo"
commit_work "$repo" "nowosc" "feat(ui): add a rollback tab"

run_release "$repo" > /dev/null
notes="$(release_notes "$repo")"

if [ "$(count_headings "$notes" '### Added')" = "1" ]; then
    record_pass "'### Added' wystąpiło dokładnie raz"
else
    record_fail "'### Added' zostało zdublowane albo zgubione"
    printf '%s\n' "$notes" | grep '^### ' | sed 's/^/      /' >&2
fi

body="$(section_body "$notes" 'Added')"
if printf '%s\n' "$body" | grep -q -F -x -- '- Ręcznie opisana nowość.' &&
   printf '%s\n' "$body" | grep -qE '^- \*\*ui:\*\* .*\([0-9a-f]{7,}\)$'; then
    record_pass "wpis ręczny i wywiedziony stoją pod jednym nagłówkiem"
else
    record_fail "scalanie sekcji kanonicznej przestało działać"
    printf '%s\n' "$body" | sed 's/^/      /' >&2
fi

# --- przypadek 5: kolejność sekcji spoza zestawu kanonicznego --------------------------

echo "→ sekcje spoza zestawu kanonicznego zachowują kolejność z [Unreleased]"

repo="$(make_repo order '### Zebra notes
- Sekcja napisana jako pierwsza.

### Alpha notes
- Sekcja napisana jako druga.')"

run_release "$repo" > /dev/null
order="$(release_notes "$repo" | grep '^### ' | paste -sd'|' -)"

if [ "$order" = "### Zebra notes|### Alpha notes" ]; then
    record_pass "kolejność napisana ręcznie przetrwała"
else
    record_fail "sekcje zostały przestawione (kolejność: ${order:-brak})"
fi

# --- przypadek 6: treść nad pierwszym nagłówkiem jest odrzucana ------------------------

echo "→ treść nad pierwszym '### ' zatrzymuje wydanie zamiast przepaść"

repo="$(make_repo preamble 'To wydanie skupia się na czasie skanowania.

### Added
- Ręcznie opisana nowość.')"

out="$(run_release "$repo")"
status=$?

if [ "$status" -ne 0 ]; then
    record_pass "release.sh odmówił (kod $status)"
else
    record_fail "release.sh przeszedł, mimo że treść nad pierwszym nagłówkiem nie ma dokąd trafić"
fi

if printf '%s\n' "$out" | grep -q 'To wydanie skupia się na czasie skanowania.'; then
    record_pass "komunikat cytuje porzuconą linię"
else
    record_fail "komunikat nie pokazuje, o którą treść chodzi"
    printf '%s\n' "$out" | tail -5 | sed 's/^/      /' >&2
fi

# Odmowa ma zostawić drzewo nietknięte — inaczej „przygotowane wydanie” blokuje
# kolejne uruchomienie i trzeba je sprzątać ręcznie.
if [ -z "$(git -C "$repo" status --porcelain --untracked-files=no)" ]; then
    record_pass "żaden plik wydania nie został ruszony"
else
    record_fail "odmowa zostawiła zmienione pliki"
    git -C "$repo" status --short --untracked-files=no | sed 's/^/      /' >&2
fi

if [[ "$failures" -gt 0 ]]; then
    printf '\n✗ guard REL-07 wykrył %d naruszenie/naruszenia\n' "$failures" >&2
    exit 1
fi

echo
echo "✅ guard REL-07 działa"
