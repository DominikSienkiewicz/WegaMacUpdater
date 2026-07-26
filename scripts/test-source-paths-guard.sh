#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# test-source-paths-guard.sh — every `Sources/**.swift` path hard-coded in a
# script or a CI workflow must actually exist.
#
# Why this guard exists: `swift build`/`swift test`/`swiftlint` only see Swift
# code. A shell script or a workflow that reads a source file *by path* is
# invisible to all three, so moving that file between modules leaves a dangling
# reference the whole quality gate reports as green.
#
# That is not hypothetical. SEC-10 moved `AppMetadata.swift` from MacUpdaterCore
# to WegaHelperKit; `build-pkg.sh` and `release.yml` kept reading the old path.
# Packaging broke with `sed: ... No such file or directory`, and the release
# workflow would have failed the same way — after the change was already on main.
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

echo "→ każda ścieżka Sources/**.swift w skryptach i workflowach istnieje"

missing=0
while IFS=: read -r file path; do
    [ -n "$path" ] || continue
    if [ -e "$path" ]; then
        printf '  ✓ %-46s ← %s\n' "$path" "${file#./}"
    else
        printf '  ✗ %-46s ← %s  (BRAK)\n' "$path" "${file#./}"
        missing=$((missing + 1))
    fi
done < <(
    grep -rhoE --include='*.sh' --include='*.yml' --include='*.yaml' \
        --exclude='test-source-paths-guard.sh' \
        'Sources/[A-Za-z0-9_/+.-]+\.swift' scripts .github 2>/dev/null \
    | sort -u \
    | while read -r p; do
        # Nazwa pliku, w którym ścieżka występuje — do czytelnego komunikatu.
        src="$(grep -rlE --include='*.sh' --include='*.yml' --include='*.yaml' \
                --exclude='test-source-paths-guard.sh' \
                -- "$p" scripts .github 2>/dev/null | head -1)"
        printf '%s:%s\n' "${src:-?}" "$p"
      done
)

if [ "$missing" -gt 0 ]; then
    echo "❌ $missing ścieżek do źródeł nie istnieje — przenosiny pliku nie objęły skryptu lub workflowu" >&2
    exit 1
fi

echo
echo "✅ guard ścieżek do źródeł działa"
