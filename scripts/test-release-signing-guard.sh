#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test-release-signing-guard.sh — test regresyjny wydania v0.2.0.
#
# Pierwsza próba wydania nie padła — ona zawisła. `security import` dopuszczał
# do klucza prywatnego wyłącznie /usr/bin/codesign, a codesign podpisuje .app;
# pakiet podpisuje pkgbuild, czyli inny plik binarny, którego na liście nie było.
# macOS poprosił o autoryzację dostępu do klucza, na runnerze nie było komu
# odpowiedzieć, więc krok stał na „Tworzę PKG..." przez blisko sześć godzin, aż
# GitHub anulował zadanie po swoim maksymalnym czasie — sześć godzin czasu
# maszyny macOS rozliczanej z mnożnikiem 10×, bez ani jednego komunikatu błędu.
#
# Żadnego z tych dwóch objawów nie widać w diffie, więc oba są tu przypięte:
# każde narzędzie sięgające po klucz musi być wymienione, a zadanie publikujące
# musi mieć własny limit czasu zamiast domyślnych sześciu godzin.
# ---------------------------------------------------------------------------
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
WORKFLOW="${1:-$ROOT/.github/workflows/release.yml}"
failures=0

record_pass() { printf '  ✓ %s\n' "$1"; }
record_fail() {
    printf '  ✗ %s\n' "$1" >&2
    failures=$((failures + 1))
}

echo "→ podpisywanie wydania nie wymaga człowieka przy keychainie"

if [[ ! -f "$WORKFLOW" ]]; then
    printf '  ✗ nie znaleziono %s\n' "$WORKFLOW" >&2
    exit 1
fi

# codesign podpisuje .app; pkgbuild buduje i podpisuje .pkg; productbuild i
# productsign to odpowiedniki dla pakietów dystrybucyjnych — wymienione, żeby
# zmiana narzędzia pakującego nie przywróciła tej samej blokady po cichu.
for tool in codesign pkgbuild productbuild productsign; do
    if grep -q -- "-T /usr/bin/$tool" "$WORKFLOW"; then
        record_pass "klucz podpisujący dopuszcza /usr/bin/$tool"
    else
        record_fail "brak -T /usr/bin/$tool — macOS zapyta o autoryzację, a zadanie zawiśnie"
    fi
done

# Blok zadania `release`, od jego nagłówka do następnego zadania na tym samym
# poziomie wcięcia.
release_job="$(awk '
    /^  release:/            { inside = 1; print; next }
    inside && /^  [^ ]/      { exit }
    inside                   { print }
' "$WORKFLOW")"

if [[ -z "$release_job" ]]; then
    record_fail "nie znaleziono zadania 'release' w $WORKFLOW"
elif grep -Eq '^    timeout-minutes: [0-9]+$' <<<"$release_job"; then
    record_pass "zadanie 'release' ma własny limit czasu"
else
    record_fail "zadanie 'release' bez timeout-minutes — domyślny limit to sześć godzin runnera macOS"
fi

# Sam import nie wystarczy: brak certyfikatu Installer w .p12 to druga droga do
# tego samego zatrzymania, więc przebieg musi to sprawdzić, zanim zacznie budować.
if grep -q 'security find-identity' "$WORKFLOW"; then
    record_pass "przebieg weryfikuje, jakie tożsamości naprawdę trafiły do keychaina"
else
    record_fail "brak weryfikacji tożsamości — brakujący certyfikat Installer wyjdzie dopiero przy pkgbuild"
fi

# Sonda zasobów musi dotykać bajtów, które są publikowane. Zadanie pakujące w CI buduje
# aplikację podpisaną ad-hoc, a zadanie publikujące buduje ją od nowa z Developer ID i to
# ona staje się .pkg oraz .dmg — sonda w jednym miejscu nie mówi nic o drugim.
if grep -q 'test-app-launches.sh' "$WORKFLOW"; then
    record_pass "zadanie publikujące uruchamia sondę zasobów na podpisanym artefakcie"
else
    record_fail "brak sondy zasobów w $WORKFLOW — publikowane bajty nie są uruchamiane"
fi

if [[ "$failures" -gt 0 ]]; then
    printf '\n✗ guard podpisywania wydania wykrył %d problem/problemy\n' "$failures" >&2
    exit 1
fi

echo
echo "✅ guard podpisywania wydania działa"
