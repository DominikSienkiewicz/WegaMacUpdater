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
# Klucz prywatny nigdy nie trafia do repo (.gitignore: *.pem) — skrypt dodatkowo ODMAWIA
# użycia klucza leżącego w drzewie roboczym repozytorium, bo `.gitignore` chroni tylko
# przed przypadkowym `git add`, a nie przed `git add -f`, edycją reguł ani backupem katalogu.
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

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
CATALOG="$ROOT/Sources/MacUpdaterCore/Resources/app-catalog.json"
SIGNATURE="$CATALOG.sig"

# SEC-07 — dwa formaty wyjściowe. Domyślnie odłączony podpis (jak dotąd). `--envelope`
# zapisuje katalog jako kopertę: payload + podpis w JEDNYM dokumencie, więc raw.github
# nie ma już dwóch wpisów cache, które mogą się rozjechać. `--unwrap` wraca do postaci
# płaskiej, żeby katalog dało się edytować ręcznie; klucza nie wymaga.
MODE="detached"
case "${1:-}" in
    --envelope) MODE="envelope"; shift ;;
    --unwrap)   MODE="unwrap";   shift ;;
esac

KEY="${1:-${WEGA_CATALOG_KEY:-}}"

# Zwraca base64 payloadu, gdy plik jest kopertą; pusty łańcuch dla płaskiego katalogu.
envelope_payload_base64() {
    grep -q '"wegaCatalogEnvelope"' "$1" || return 0
    sed -n 's/.*"payload"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$1" | head -1
}

if [[ "$MODE" == "unwrap" ]]; then
    PAYLOAD="$(envelope_payload_base64 "$CATALOG")"
    if [[ -z "$PAYLOAD" ]]; then
        echo "→ katalog już jest w postaci płaskiej — nic do zrobienia."
        exit 0
    fi
    TMP_FLAT="$(mktemp)"
    trap 'rm -f "$TMP_FLAT"' EXIT
    printf '%s' "$PAYLOAD" | base64 -d > "$TMP_FLAT"
    mv "$TMP_FLAT" "$CATALOG"
    trap - EXIT
    echo "✓ rozpakowano kopertę: ${CATALOG#"$ROOT/"}"
    echo "  Podpis wygasł razem z kopertą — uruchom ./scripts/sign-catalog.sh przed commitem."
    exit 0
fi

# --- Guard: klucz prywatny nie może leżeć w drzewie roboczym repozytorium (SEC-06) ---
#
# Rozwiązywanie ścieżek robimy przez `cd` + `pwd -P`, a nie przez `realpath`/`readlink -f`:
# `realpath(1)` pojawił się na macOS dopiero w 12, a `readlink -f` to rozszerzenie GNU,
# którego BSD-owy readlink z macOS nie zna w ogóle. `cd`+`pwd -P` to POSIX i działa
# identycznie na każdym wspieranym macOS oraz na runnerach linuksowych w CI.

# Rozwija wiodące `~`. Powłoka tego nie zrobi, gdy ścieżka przyszła w cudzysłowie
# albo z pliku środowiska (WEGA_CATALOG_KEY="~/.secrets/wega-catalog.pem").
expand_tilde() {
    case "$1" in
        "~") printf '%s\n' "$HOME" ;;
        "~"/*) printf '%s%s\n' "$HOME" "${1#\~}" ;;
        *) printf '%s\n' "$1" ;;
    esac
}

# Ścieżka bezwzględna z rozwiniętymi dowiązaniami w katalogach, ale BEZ podążania
# za dowiązaniem samego pliku — to jest lokalizacja, pod którą plik widnieje w drzewie.
absolute_path() {
    local path dir base
    path="$(expand_tilde "$1")"
    dir="$(dirname "$path")"
    base="$(basename "$path")"
    if ! dir="$(cd "$dir" 2>/dev/null && pwd -P)"; then
        printf '%s\n' "$path"
        return 0
    fi
    [[ "$dir" == "/" ]] && dir=""
    printf '%s/%s\n' "$dir" "$base"
}

absolute_dir() {
    local path
    path="$(expand_tilde "$1")"
    if ! path="$(cd "$path" 2>/dev/null && pwd -P)"; then
        printf '%s\n' "$1"
        return 0
    fi
    printf '%s\n' "$path"
}

# Podąża za łańcuchem dowiązań aż do pliku docelowego. BSD-owy `readlink` zwraca jeden
# poziom, stąd pętla; limit 32 przerywa cykl dowiązań zamiast wisieć.
resolve_symlink_chain() {
    local path target hops=0
    path="$(absolute_path "$1")"
    while [[ -L "$path" && "$hops" -lt 32 ]]; do
        target="$(readlink "$path")"
        case "$target" in
            /*) path="$(absolute_path "$target")" ;;
            *) path="$(absolute_path "$(dirname "$path")/$target")" ;;
        esac
        hops=$((hops + 1))
    done
    printf '%s\n' "$path"
}

# Wszystkie drzewa robocze tego repozytorium. `git worktree list` wymienia główny
# checkout RAZEM z worktree linkowanymi, więc klucz schowany w którymkolwiek z nich
# jest złapany — także wtedy, gdy skrypt uruchomiono z innego worktree.
repository_roots() {
    local top path
    if ! top="$(git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null)" || [[ -z "$top" ]]; then
        # Bez gita (tarball, sandbox CI) drzewem roboczym jest katalog nadrzędny skryptu.
        absolute_dir "$ROOT"
        return 0
    fi
    absolute_dir "$top"
    git -C "$ROOT" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' |
        while IFS= read -r path; do
            [[ -n "$path" ]] && absolute_dir "$path"
        done
}

path_is_inside() {
    [[ "$1" == "$2" || "$1" == "$2"/* ]]
}

refuse_key_inside_repository() {
    local literal resolved root
    # Sprawdzamy OBIE postacie: ścieżkę jak widnieje w drzewie (łapie dowiązanie w repo,
    # które backup podążający za linkami — tar -h, cp -RL, rsync -L — zamieni w kopię
    # klucza) oraz cel dowiązań (łapie link spoza repo celujący w plik w repo).
    literal="$(absolute_path "$1")"
    resolved="$(resolve_symlink_chain "$1")"
    while IFS= read -r root; do
        [[ -n "$root" ]] || continue
        if path_is_inside "$literal" "$root" || path_is_inside "$resolved" "$root"; then
            echo "błąd: klucz prywatny leży wewnątrz drzewa roboczego repozytorium — odmawiam podpisania." >&2
            echo "      klucz: $literal" >&2
            echo "      repo:  $root" >&2
            echo "      To repozytorium jest publiczne. .gitignore nie chroni przed 'git add -f'," >&2
            echo "      zmianą reguł ignorowania ani backupem katalogu — jedna pomyłka ujawnia klucz" >&2
            echo "      produkcyjny i wymusza rotację podpisów katalogu OTA u wszystkich instalacji." >&2
            echo "      Trzymaj klucz poza repo, w ~/.secrets/wega-catalog.pem:" >&2
            echo "        mkdir -p ~/.secrets && chmod 700 ~/.secrets" >&2
            echo "        mv '$literal' ~/.secrets/wega-catalog.pem && chmod 600 ~/.secrets/wega-catalog.pem" >&2
            echo "      i wskazuj go przez WEGA_CATALOG_KEY:" >&2
            echo "        WEGA_CATALOG_KEY=~/.secrets/wega-catalog.pem ./scripts/sign-catalog.sh" >&2
            exit 2
        fi
    done < <(repository_roots)
}

if [[ -z "$KEY" ]]; then
    echo "błąd: podaj klucz prywatny — argumentem albo w WEGA_CATALOG_KEY" >&2
    exit 2
fi

# Guard idzie PRZED kontrolą czytelności i przed sondą openssl: odmowa ma być
# bezwarunkowa, a nie zależna od tego, czy reszta środowiska jest skonfigurowana.
refuse_key_inside_repository "$KEY"

KEY="$(absolute_path "$KEY")"

if [[ ! -r "$KEY" ]]; then
    echo "błąd: nie mogę odczytać klucza prywatnego: $KEY" >&2
    exit 2
fi

require_openssl3

if [[ ! -r "$CATALOG" ]]; then
    echo "błąd: brak katalogu: $CATALOG" >&2
    exit 2
fi

TMP="$(mktemp)"
PAYLOAD_FILE="$(mktemp)"
TMP_ENVELOPE="$(mktemp)"
trap 'rm -f "$TMP" "$PAYLOAD_FILE" "$TMP_ENVELOPE"' EXIT

# Podpisujemy ZAWSZE płaskie bajty katalogu, także wtedy, gdy plik jest już kopertą —
# inaczej ponowne podpisanie zagnieżdżałoby koperty w kopertach, a podpis przestałby
# dotyczyć tego, co aplikacja dekoduje.
EXISTING_PAYLOAD="$(envelope_payload_base64 "$CATALOG")"
if [[ -n "$EXISTING_PAYLOAD" ]]; then
    printf '%s' "$EXISTING_PAYLOAD" | base64 -d > "$PAYLOAD_FILE"
else
    cat "$CATALOG" > "$PAYLOAD_FILE"
fi

"$OPENSSL_BIN" pkeyutl -sign -inkey "$KEY" -rawin -in "$PAYLOAD_FILE" | base64 | tr -d '\n' > "$TMP"

# Sprawdź własną robotę tym samym kluczem publicznym, który wkompilowany jest w aplikację —
# podpis, którego apka nie przyjmie, jest gorszy niż brak podpisu (cicho wyłącza katalog OTA).
if ! "$ROOT/scripts/verify-catalog.sh" "$PAYLOAD_FILE" "$TMP" >/dev/null; then
    echo "błąd: świeżo wygenerowany podpis nie weryfikuje się kluczem publicznym z CatalogSignature.swift." >&2
    echo "      Czy to na pewno para do wkompilowanego klucza? Nic NIE zostało zapisane." >&2
    exit 1
fi

if [[ "$MODE" == "envelope" ]]; then
    # Payload i podpis są base64, więc w JSON-ie nie ma czego escapować.
    printf '{\n  "wegaCatalogEnvelope": 1,\n  "payload": "%s",\n  "signature": "%s"\n}\n' \
        "$(base64 < "$PAYLOAD_FILE" | tr -d '\n')" "$(cat "$TMP")" > "$TMP_ENVELOPE"
    mv "$TMP_ENVELOPE" "$CATALOG"
    # Odłączony podpis przestaje cokolwiek znaczyć — zostawiony wprowadzałby w błąd
    # i ręczyłby za bajty, których już nie ma pod tą ścieżką.
    rm -f "$SIGNATURE"
    trap - EXIT
    echo "✓ podpisano jako koperta: ${CATALOG#"$ROOT/"}"
    echo
    echo "Jeden dokument — koniec z rozjazdem cache dwóch plików na raw.githubusercontent."
    echo "Żeby wrócić do edytowalnej postaci płaskiej: ./scripts/sign-catalog.sh --unwrap"
    echo
    echo "Zacommituj katalog (usunięty .sig też należy do tej zmiany):"
    echo "  git add -A Sources/MacUpdaterCore/Resources/"
    echo "  git commit -m 'chore(catalog): publish the catalog as a signed envelope'"
    exit 0
fi

mv "$TMP" "$SIGNATURE"
trap - EXIT

echo "✓ podpisano: ${SIGNATURE#"$ROOT/"}"
echo
echo "Zacommituj OBA pliki razem:"
echo "  git add Sources/MacUpdaterCore/Resources/app-catalog.json{,.sig}"
echo "  git commit -m 'chore(catalog): update app catalog and its signature'"
