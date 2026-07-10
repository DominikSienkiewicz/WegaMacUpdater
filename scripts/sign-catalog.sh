#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# sign-catalog.sh — podpisuje app-catalog.json kluczem prywatnym Ed25519 (F5d)
#
# Użycie:
#   WEGA_CATALOG_KEY=~/.secrets/wega-catalog.pem ./scripts/sign-catalog.sh
#   ./scripts/sign-catalog.sh /ścieżka/do/klucza.pem
#
# Zapisuje `<katalog>.sig` — base64 odłączonego podpisu nad DOKŁADNYMI bajtami pliku.
# Po podpisaniu weryfikuje własny wynik kluczem publicznym wkompilowanym w aplikację;
# przy niezgodności nie zostawia pliku .sig.
#
# `app-catalog.json` i `app-catalog.json.sig` MUSZĄ trafić do repozytorium w JEDNYM
# commicie. raw.githubusercontent cache'uje oba pliki osobno, więc rozjazd w repo
# oznacza okno, w którym klienci pobiorą świeży JSON i stary podpis.
#
# Klucz prywatny nigdy nie trafia do repo (.gitignore: *.pem).
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
CATALOG="$ROOT/Sources/MacUpdaterCore/Resources/app-catalog.json"
SIGNATURE="$CATALOG.sig"
KEY="${1:-${WEGA_CATALOG_KEY:-}}"

if [[ -z "$KEY" ]]; then
    echo "błąd: podaj klucz prywatny — argumentem albo w WEGA_CATALOG_KEY" >&2
    exit 2
fi
if [[ ! -r "$KEY" ]]; then
    echo "błąd: nie mogę odczytać klucza prywatnego: $KEY" >&2
    exit 2
fi
if [[ ! -r "$CATALOG" ]]; then
    echo "błąd: brak katalogu: $CATALOG" >&2
    exit 2
fi

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

"$OPENSSL_BIN" pkeyutl -sign -inkey "$KEY" -rawin -in "$CATALOG" | base64 > "$TMP"

# Sprawdź własną robotę tym samym kluczem publicznym, który wkompilowany jest w aplikację —
# podpis, którego apka nie przyjmie, jest gorszy niż brak podpisu (cicho wyłącza katalog OTA).
if ! "$ROOT/scripts/verify-catalog.sh" "$CATALOG" "$TMP" >/dev/null; then
    echo "błąd: świeżo wygenerowany podpis nie weryfikuje się kluczem publicznym z CatalogSignature.swift." >&2
    echo "      Czy to na pewno para do wkompilowanego klucza? Plik .sig NIE został zapisany." >&2
    exit 1
fi

mv "$TMP" "$SIGNATURE"
trap - EXIT

echo "✓ podpisano: ${SIGNATURE#"$ROOT/"}"
echo
echo "Zacommituj OBA pliki razem:"
echo "  git add Sources/MacUpdaterCore/Resources/app-catalog.json{,.sig}"
echo "  git commit -m 'chore(catalog): update app catalog and its signature'"
