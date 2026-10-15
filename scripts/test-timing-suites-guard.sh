#!/usr/bin/env bash
set -euo pipefail

# Strażnik: testy z twardym limitem czasu rzeczywistego biegną osobno i szeregowo.
#
# Zestawy, które mierzą zegarem ścianowym prawdziwe procesy albo runtime asynchroniczny
# (`#expect(elapsed < …)`), przekraczały limit, gdy dzieliły runnera z ~1 200 testami
# uruchomionymi równolegle — za każdym razem inny test, na tym samym kodzie i obrazie runnera
# (29.09, 05.10 i 14.10.2026). Dlatego build.yml i check.sh uruchamiają je w osobnym kroku
# z `--no-parallel`, a główny krok je pomija. Ten strażnik pilnuje trzech rzeczy:
#   1. każdy plik testów z taką asercją deklaruje zestaw z listy timing-sensitive-suites.sh,
#   2. build.yml i check.sh uruchamiają listę szeregowo i pomijają ją w głównym kroku,
#   3. pokrycie z kroku szeregowego trafia do default.profdata (inaczej znika z SonarCloud).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR/.."
LIST="$SCRIPT_DIR/timing-sensitive-suites.sh"
BUILD="$REPO_ROOT/.github/workflows/build.yml"
CHECK="$SCRIPT_DIR/check.sh"

# `#expect(elapsed < …)`, `#expect(after < …)`, `#expect(clock.now - start < …)` — także gdy
# warunek stoi w osobnej linii pod `#expect(`.
WALL_CLOCK='(#expect\([[:space:]]*|^[[:space:]]*)(elapsed|after|clock\.now - start)[[:space:]]*<'

echo "→ testy z limitem czasu rzeczywistego biegną osobno i szeregowo"

if [[ ! -x "$LIST" ]]; then
    echo "❌ brak wykonywalnego scripts/timing-sensitive-suites.sh" >&2
    exit 1
fi
SUITES_RX="$("$LIST")"

listed() {
    printf '.%s/\n' "$1" | grep -Eq "$SUITES_RX"
}

has_listed_suite() {
    local file="$1" name
    for name in $(grep -E '^(struct|final class|class) [A-Za-z0-9_]+' "$file" | sed -E 's/^(struct|final class|class) ([A-Za-z0-9_]+).*/\2/'); do
        if listed "$name"; then return 0; fi
    done
    return 1
}

# Strażnik nie może być pusty: wzorzec musi wykryć asercję w zestawie spoza listy.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/UnlistedTimingTests.swift" <<'SWIFT'
struct UnlistedTimingTests {
    @Test func probe() async {
        #expect(
            elapsed < .seconds(1)
        )
    }
}
SWIFT
if ! grep -Eq "$WALL_CLOCK" "$WORK/UnlistedTimingTests.swift"; then
    echo "❌ wzorzec nie wykrywa asercji z limitem czasu — strażnik niczego by nie pilnował" >&2
    exit 1
fi
if has_listed_suite "$WORK/UnlistedTimingTests.swift"; then
    echo "❌ zestaw spoza listy został uznany za wymieniony — lista dopasowuje za szeroko" >&2
    exit 1
fi

status=0
while IFS= read -r file; do
    if ! has_listed_suite "$REPO_ROOT/$file"; then
        echo "❌ $file ma asercję z limitem czasu, ale jego zestawu nie ma w scripts/timing-sensitive-suites.sh" >&2
        status=1
    fi
done < <(cd "$REPO_ROOT" && grep -rlE "$WALL_CLOCK" Tests | sort)

SERIAL='--no-parallel --filter "$(./scripts/timing-sensitive-suites.sh)"'
SKIP='--skip "$(./scripts/timing-sensitive-suites.sh)"'
for target in "$BUILD" "$CHECK"; do
    if ! grep -Fq -- "$SERIAL" "$target"; then
        echo "❌ $(basename "$target") nie uruchamia zestawów z listy szeregowo ($SERIAL)" >&2
        status=1
    fi
    if ! grep -Fq -- "$SKIP" "$target"; then
        echo "❌ $(basename "$target") nie pomija zestawów z listy w głównym kroku testów ($SKIP)" >&2
        status=1
    fi
done
if ! grep -Fq 'llvm-profdata merge' "$BUILD"; then
    echo "❌ build.yml nie scala pokrycia z kroku szeregowego z default.profdata" >&2
    status=1
fi

if [[ $status -ne 0 ]]; then
    exit 1
fi
echo "✅ zestawy z limitem czasu rzeczywistego biegną osobno, szeregowo i z pokryciem"
