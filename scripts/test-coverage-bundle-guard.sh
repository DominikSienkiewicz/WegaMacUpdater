#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COVERAGE_SCRIPT="$SCRIPT_DIR/coverage-sonarqube.sh"

echo "→ coverage zawsze eksportuje bundle obejmujący target aplikacji"

if ! grep -Fq 'MacUpdaterUITests.xctest/Contents/MacOS/MacUpdaterUITests' "$COVERAGE_SCRIPT"; then
    echo "❌ coverage nie wybiera jawnie MacUpdaterUITests.xctest" >&2
    exit 1
fi

if grep -Eq "find .*\\.xctest.*head -1" "$COVERAGE_SCRIPT"; then
    echo "❌ pierwszy bundle z find(1) jest niedeterministyczny i może pominąć Sources/MacUpdater" >&2
    exit 1
fi

echo "✅ coverage obejmuje MacUpdaterCore i WegaMacUpdater"
