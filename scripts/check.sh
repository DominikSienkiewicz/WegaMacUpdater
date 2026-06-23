#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# check.sh — local quality gate before commit/push.
#
# Runs, in order (each must pass before the next — `set -e`):
#   1. swift build              — compiles app + helper + core
#   2. swift test               — full unit-test suite
#   3. swiftlint lint --strict  — zero lint violations (warnings fail too)
#
# Note: building requires a full Xcode toolchain — Command Line Tools alone
# lack the FoundationModelsMacros plugin, so ReleaseNotesTriage.swift won't
# compile (xcode-select -p must point at Xcode.app, not /Library/Developer/
# CommandLineTools).
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

echo "→ swift build"
swift build

echo "→ swift test"
swift test

echo "→ swiftlint lint --strict"
if ! command -v swiftlint >/dev/null 2>&1; then
  echo "❌ swiftlint nie jest zainstalowany (brew install swiftlint)." >&2
  exit 127
fi
swiftlint lint --strict

echo "✅ build + test + lint OK"
