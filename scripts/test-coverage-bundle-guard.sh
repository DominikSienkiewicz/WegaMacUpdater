#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COVERAGE_SCRIPT="$SCRIPT_DIR/coverage-sonarqube.sh"
RESOLVER="$SCRIPT_DIR/resolve-coverage-bundle.sh"

echo "→ coverage zawsze eksportuje bundle obejmujący target aplikacji"

if [[ ! -x "$RESOLVER" ]]; then
    echo "❌ brak wykonywalnego resolve-coverage-bundle.sh" >&2
    exit 1
fi

if ! grep -Fq 'resolve-coverage-bundle.sh' "$COVERAGE_SCRIPT"; then
    echo "❌ coverage nie wybiera bundla przez resolve-coverage-bundle.sh" >&2
    exit 1
fi

if grep -Eq "find .*\\.xctest.*head -1" "$COVERAGE_SCRIPT"; then
    echo "❌ pierwszy bundle z find(1) jest niedeterministyczny i może pominąć Sources/MacUpdater" >&2
    exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

make_bundle() {
    local bin_path="$1" name="$2"
    mkdir -p "$bin_path/$name.xctest/Contents/MacOS"
    : > "$bin_path/$name.xctest/Contents/MacOS/$name"
    chmod +x "$bin_path/$name.xctest/Contents/MacOS/$name"
}

# CI: klasyczny build system SwiftPM scala wszystkie targety testowe w jeden
# <Package>PackageTests.xctest — MacUpdaterUITests.xctest tam nie istnieje.
MERGED="$WORK/merged"
mkdir -p "$MERGED"
make_bundle "$MERGED" "WegaMacUpdaterPackageTests"
resolved="$("$RESOLVER" "$MERGED")"
expected="$MERGED/WegaMacUpdaterPackageTests.xctest/Contents/MacOS/WegaMacUpdaterPackageTests"
if [[ "$resolved" != "$expected" ]]; then
    echo "❌ scalony bundle CI nie został rozpoznany: $resolved" >&2
    exit 1
fi

# Lokalnie: SwiftBuild emituje bundle per target — tylko MacUpdaterUITests linkuje
# WegaMacUpdater, więc wybór musi być jawny, nigdy zależny od kolejności katalogu.
PER_TARGET="$WORK/per-target"
mkdir -p "$PER_TARGET"
make_bundle "$PER_TARGET" "MacUpdaterTests"
make_bundle "$PER_TARGET" "MacUpdaterUITests"
resolved="$("$RESOLVER" "$PER_TARGET")"
expected="$PER_TARGET/MacUpdaterUITests.xctest/Contents/MacOS/MacUpdaterUITests"
if [[ "$resolved" != "$expected" ]]; then
    echo "❌ per-target: wybrano $resolved zamiast MacUpdaterUITests" >&2
    exit 1
fi

# Brak jakiegokolwiek bundla musi być twardym błędem, nie pustym raportem.
EMPTY="$WORK/empty"
mkdir -p "$EMPTY"
if "$RESOLVER" "$EMPTY" >/dev/null 2>&1; then
    echo "❌ brak bundla powinien kończyć się błędem" >&2
    exit 1
fi

echo "✅ coverage obejmuje MacUpdaterCore i WegaMacUpdater (scalony i per-target)"
