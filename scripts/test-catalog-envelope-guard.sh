#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test-catalog-envelope-guard.sh — koperta katalogu OTA (SEC-07), czysty bash
#
# Sprawdza cztery rzeczy, których `swift test` nie widzi, bo mieszkają w skryptach:
#   1. verify-catalog.sh przyjmuje kopertę zbudowaną z ZAKOMITOWANEGO katalogu i jego
#      podpisu — czyli z prawdziwym kluczem produkcyjnym, nie z atrapą;
#   2. odrzuca kopertę, w której payload podmieniono, zostawiając podpis;
#   3. `sign-catalog.sh --unwrap` odtwarza płaski katalog bajt w bajt;
#   4. `--bump` wstawia i podnosi `generation`, nie ruszając `schemaVersion`.
#
# Punkt 2 jest tym, po co ta koperta w ogóle istnieje: podpis ma dotyczyć payloadu,
# a nie dokumentu, który go otacza.
#
# Działa niezależnie od tego, w której z dwóch postaci leży katalog w repo — koperty
# albo płaskiego JSON-a z odłączonym `.sig`. Obie sprowadzamy do jednej pary
# (płaskie bajty, podpis) i dopiero na niej budujemy przypadki.
#
# Klucza prywatnego nie wymaga — podpis pochodzi z repo.
# ---------------------------------------------------------------------------
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
CATALOG="$ROOT/Sources/MacUpdaterCore/Resources/app-catalog.json"
SIGNATURE="$CATALOG.sig"
VERIFY="$ROOT/scripts/verify-catalog.sh"
SIGN="$ROOT/scripts/sign-catalog.sh"

FAILURES=0
fail() { echo "  ✗ $1" >&2; FAILURES=$((FAILURES + 1)); }
pass() { echo "  ✓ $1"; }

if [[ ! -r "$CATALOG" ]]; then
    echo "błąd: brak katalogu w repo — nie mam z czego zbudować koperty." >&2
    exit 2
fi

# Podpisywanie może być nieskonfigurowane (placeholder) — wtedy verify-catalog.sh kończy
# się kodem 3 i ten test nie ma czego sprawdzać.
set +e
"$VERIFY" >/dev/null 2>&1
BASELINE=$?
set -e
if [[ "$BASELINE" -eq 3 ]]; then
    echo "→ podpisywanie katalogu nieskonfigurowane — pomijam test koperty."
    exit 0
fi
if [[ "$BASELINE" -ne 0 ]]; then
    echo "błąd: zakomitowany katalog nie weryfikuje się jeszcze przed testem koperty." >&2
    exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Katalog w repo bywa w JEDNEJ z DWÓCH postaci i test musi działać w obu — to jest cała
# treść migracji, którą ta karta wprowadziła. Sprowadzamy więc obie do tej samej pary
# (płaskie bajty, podpis nad nimi) i dopiero na niej budujemy przypadki testowe.
#
# Wersja tego guardu sprzed migracji wymagała odłączonego pliku `.sig`, więc w dniu, w
# którym katalog stał się kopertą — czyli dokładnie wtedy, gdy zaczął testować to, po co
# powstał — przewracała całą bramkę na `exit 2`.
FLAT="$WORK/flat.json"
SIG="$WORK/detached.b64"
if grep -q '"wegaCatalogEnvelope"' "$CATALOG"; then
    sed -n 's/.*"payload"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CATALOG" | head -1 |
        base64 -d > "$FLAT"
    sed -n 's/.*"signature"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CATALOG" | head -1 \
        | tr -d '\n' > "$SIG"
    SHAPE="koperta"
elif [[ -r "$SIGNATURE" ]]; then
    cat "$CATALOG" > "$FLAT"
    tr -d '\n' < "$SIGNATURE" > "$SIG"
    SHAPE="płaski katalog + .sig"
else
    echo "błąd: katalog nie jest kopertą, a odłączonego podpisu brak — nie ma czego testować." >&2
    exit 2
fi

if [[ ! -s "$FLAT" || ! -s "$SIG" ]]; then
    echo "błąd: nie udało się wyłuskać bajtów katalogu i podpisu z postaci: $SHAPE" >&2
    exit 1
fi

build_envelope() {
    local payload_file="$1" out="$2"
    printf '{\n  "wegaCatalogEnvelope": 1,\n  "payload": "%s",\n  "signature": "%s"\n}\n' \
        "$(base64 < "$payload_file" | tr -d '\n')" \
        "$(cat "$SIG")" > "$out"
}

echo "→ koperta katalogu OTA (SEC-07) — postać w repo: $SHAPE"

# 1. Koperta nad prawdziwymi bajtami + prawdziwym podpisem musi przejść.
build_envelope "$FLAT" "$WORK/envelope.json"
if "$VERIFY" "$WORK/envelope.json" >/dev/null 2>&1; then
    pass "verify-catalog.sh przyjmuje poprawną kopertę"
else
    fail "verify-catalog.sh odrzucił kopertę zbudowaną z zakomitowanego katalogu i podpisu"
fi

# 2. Ten sam podpis nad PODMIENIONYM payloadem musi polec — inaczej koperta niczego nie chroni.
sed 's/"github"/"gitHUB"/' "$FLAT" > "$WORK/tampered.json"
if ! cmp -s "$FLAT" "$WORK/tampered.json"; then
    build_envelope "$WORK/tampered.json" "$WORK/tampered-envelope.json"
    if "$VERIFY" "$WORK/tampered-envelope.json" >/dev/null 2>&1; then
        fail "verify-catalog.sh przyjął kopertę z podmienionym payloadem"
    else
        pass "verify-catalog.sh odrzuca kopertę z podmienionym payloadem"
    fi
else
    fail "nie udało się przygotować podmienionego payloadu"
fi

# 3. `--unwrap` musi oddać dokładnie te bajty, które trafiły do koperty. Pracujemy na
#    kopii drzewa: skrypt zapisuje w miejscu, a test nie ma prawa ruszyć repo.
mkdir -p "$WORK/repo/scripts" "$WORK/repo/Sources/MacUpdaterCore/Resources"
cp "$SIGN" "$WORK/repo/scripts/sign-catalog.sh"
cp "$WORK/envelope.json" "$WORK/repo/Sources/MacUpdaterCore/Resources/app-catalog.json"
if "$WORK/repo/scripts/sign-catalog.sh" --unwrap >/dev/null 2>&1 &&
   cmp -s "$FLAT" "$WORK/repo/Sources/MacUpdaterCore/Resources/app-catalog.json"; then
    pass "sign-catalog.sh --unwrap odtwarza płaski katalog bajt w bajt"
else
    fail "sign-catalog.sh --unwrap nie odtworzył pierwotnych bajtów katalogu"
fi

# 4. `--bump` musi podnieść `generation` — także wtedy, gdy pola jeszcze nie ma. Bez tego
#    ochrona przed cofnięciem katalogu leży odłogiem: licznik zostaje na zerze na zawsze.
#    Sprawdzamy sam efekt na pliku, bez podpisywania (klucza tu nie ma).
BUMP_SRC="$WORK/bump.json"
cat > "$BUMP_SRC" <<'JSON'
{
  "schemaVersion": 1,
  "github": []
}
JSON
(
    # shellcheck disable=SC1090
    BUMP_TARGET="$BUMP_SRC"
    # Wyciągamy samą funkcję: uruchomienie całego skryptu wymagałoby klucza prywatnego.
    eval "$(sed -n '/^catalog_generation()/,/^}/p;/^bump_generation()/,/^}/p' "$SIGN")"
    bump_generation "$BUMP_TARGET" >/dev/null
    bump_generation "$BUMP_TARGET" >/dev/null
)
if grep -q '"generation": 2' "$BUMP_SRC" && grep -q '"schemaVersion": 1' "$BUMP_SRC"; then
    pass "--bump wstawia i podnosi generation, nie ruszając schemaVersion"
else
    fail "--bump nie podniósł generation do 2 (plik: $(tr -d '\n' < "$BUMP_SRC"))"
fi

if [[ "$FAILURES" -gt 0 ]]; then
    echo "✗ koperta katalogu: $FAILURES niepowodzeń" >&2
    exit 1
fi
echo "✓ koperta katalogu OK"
