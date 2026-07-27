#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test-catalog-envelope-guard.sh — koperta katalogu OTA (SEC-07), czysty bash
#
# Sprawdza trzy rzeczy, których `swift test` nie widzi, bo mieszkają w skryptach:
#   1. verify-catalog.sh przyjmuje kopertę zbudowaną z ZAKOMITOWANEGO katalogu i jego
#      podpisu — czyli z prawdziwym kluczem produkcyjnym, nie z atrapą;
#   2. odrzuca kopertę, w której payload podmieniono, zostawiając podpis;
#   3. `sign-catalog.sh --unwrap` odtwarza płaski katalog bajt w bajt.
#
# Punkt 2 jest tym, po co ta koperta w ogóle istnieje: podpis ma dotyczyć payloadu,
# a nie dokumentu, który go otacza.
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

if [[ ! -r "$CATALOG" || ! -r "$SIGNATURE" ]]; then
    echo "błąd: brak katalogu albo podpisu w repo — nie mam z czego zbudować koperty." >&2
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

build_envelope() {
    local payload_file="$1" out="$2"
    printf '{\n  "wegaCatalogEnvelope": 1,\n  "payload": "%s",\n  "signature": "%s"\n}\n' \
        "$(base64 < "$payload_file" | tr -d '\n')" \
        "$(tr -d '\n' < "$SIGNATURE")" > "$out"
}

echo "→ koperta katalogu OTA (SEC-07)"

# 1. Koperta nad prawdziwymi bajtami + prawdziwym podpisem musi przejść.
build_envelope "$CATALOG" "$WORK/envelope.json"
if "$VERIFY" "$WORK/envelope.json" >/dev/null 2>&1; then
    pass "verify-catalog.sh przyjmuje poprawną kopertę"
else
    fail "verify-catalog.sh odrzucił kopertę zbudowaną z zakomitowanego katalogu i podpisu"
fi

# 2. Ten sam podpis nad PODMIENIONYM payloadem musi polec — inaczej koperta niczego nie chroni.
sed 's/"github"/"gitHUB"/' "$CATALOG" > "$WORK/tampered.json"
if ! cmp -s "$CATALOG" "$WORK/tampered.json"; then
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
   cmp -s "$CATALOG" "$WORK/repo/Sources/MacUpdaterCore/Resources/app-catalog.json"; then
    pass "sign-catalog.sh --unwrap odtwarza płaski katalog bajt w bajt"
else
    fail "sign-catalog.sh --unwrap nie odtworzył pierwotnych bajtów katalogu"
fi

if [[ "$FAILURES" -gt 0 ]]; then
    echo "✗ koperta katalogu: $FAILURES niepowodzeń" >&2
    exit 1
fi
echo "✓ koperta katalogu OK"
