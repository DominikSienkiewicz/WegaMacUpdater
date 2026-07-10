#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# verify-catalog.sh — sprawdza, że app-catalog.json.sig pasuje do app-catalog.json (F5d)
#
# Użycie:
#   ./scripts/verify-catalog.sh                       # pliki z repo
#   ./scripts/verify-catalog.sh <katalog> <podpis>    # dowolna para (używa sign-catalog.sh)
#
# Nie wymaga żadnego sekretu: klucz publiczny czytany jest wprost z CatalogSignature.swift,
# czyli z tego samego miejsca, z którego bierze go aplikacja.
#
# To jest bramka atomowości `json+sig`. raw.githubusercontent serwuje oba pliki jako osobne
# wpisy cache, więc jedyny moment, w którym da się zagwarantować ich spójność, to commit.
# Ten skrypt czerwieni CI, jeśli ktoś zmieni katalog i nie przegeneruje podpisu.
#
# Kody wyjścia: 0 = zgodny · 1 = niezgodny/brak podpisu · 3 = podpisywanie nieskonfigurowane
# ---------------------------------------------------------------------------
set -euo pipefail

# openssl: `pkeyutl -rawin` (Ed25519 nad surowymi bajtami) wymaga OpenSSL 3.x.
# Systemowy openssl na macOS to LibreSSL i tego nie umie — bez tej kontroli skrypt
# failowałby, wyglądając jak zły podpis.
require_openssl3() {
    local candidate
    for candidate in "${OPENSSL:-}" openssl /opt/homebrew/opt/openssl@3/bin/openssl /usr/local/opt/openssl@3/bin/openssl; do
        [[ -n "$candidate" ]] || continue
        command -v "$candidate" >/dev/null 2>&1 || continue
        if "$candidate" version 2>/dev/null | grep -q "^OpenSSL 3"; then
            OPENSSL_BIN="$candidate"
            return 0
        fi
    done
    echo "błąd: potrzebny OpenSSL 3.x (LibreSSL nie obsługuje 'pkeyutl -rawin' dla Ed25519)." >&2
    echo "      macOS: brew install openssl@3   —   albo wskaż binarkę przez OPENSSL=..." >&2
    exit 2
}
require_openssl3

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT/Sources/MacUpdaterCore/Security/CatalogSignature.swift"
CATALOG="${1:-$ROOT/Sources/MacUpdaterCore/Resources/app-catalog.json}"
SIGNATURE="${2:-$CATALOG.sig}"
PLACEHOLDER="REPLACE_ED25519_PUBKEY"

# Klucz publiczny: pierwsza linia `publicKeyBase64 = "…"`. Sentinel `unconfiguredPlaceholder`
# jest osobną stałą i celowo NIE pasuje do tego wzorca — pomylenie tych dwóch było błędem,
# który wyłączył weryfikację podpisów w całej aplikacji (patrz CatalogSignatureTests).
PUBKEY="$(sed -n 's/.*publicKeyBase64 = "\([^"]*\)".*/\1/p' "$SOURCE" | head -1)"

if [[ -z "$PUBKEY" ]]; then
    echo "błąd: nie znalazłem publicKeyBase64 w $SOURCE" >&2
    exit 1
fi
if [[ "$PUBKEY" == "$PLACEHOLDER" ]]; then
    echo "→ podpisywanie katalogu nieskonfigurowane (placeholder) — pomijam weryfikację."
    exit 3
fi
if [[ ! -r "$SIGNATURE" ]]; then
    echo "błąd: brak podpisu: $SIGNATURE" >&2
    echo "      Uruchom ./scripts/sign-catalog.sh i zacommituj oba pliki razem." >&2
    exit 1
fi

TMPDIR_="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_"' EXIT

# CryptoKit oczekuje SUROWYCH 32 bajtów; openssl potrzebuje SPKI DER.
# Prefiks SPKI dla Ed25519 jest stały (12 bajtów): 302a300506032b6570032100
{
    printf '\x30\x2a\x30\x05\x06\x03\x2b\x65\x70\x03\x21\x00'
    printf '%s' "$PUBKEY" | base64 -d
} > "$TMPDIR_/pub.der"

base64 -d < "$SIGNATURE" > "$TMPDIR_/sig.raw" 2>/dev/null || {
    echo "✗ podpis nie jest poprawnym base64: $SIGNATURE" >&2
    exit 1
}

if "$OPENSSL_BIN" pkeyutl -verify -pubin -inkey "$TMPDIR_/pub.der" -keyform DER \
      -rawin -in "$CATALOG" -sigfile "$TMPDIR_/sig.raw" >/dev/null 2>&1; then
    echo "✓ podpis zgadza się z katalogiem"
    exit 0
fi

echo "✗ podpis NIE pasuje do katalogu." >&2
echo "  Najczęstsza przyczyna: zmieniono app-catalog.json bez przegenerowania .sig." >&2
echo "  Napraw: ./scripts/sign-catalog.sh, a potem zacommituj OBA pliki w jednym commicie." >&2
exit 1
