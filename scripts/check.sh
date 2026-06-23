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

# Fail fast on a CommandLineTools-only toolchain: it lacks the FoundationModelsMacros
# plugin (ReleaseNotesTriage's @Generable/@Guide won't expand) and a SourceKit that
# SwiftLint can load — so build, test AND lint all break with confusing errors.
DEV="$(xcode-select -p 2>/dev/null || true)"
if [[ "$DEV" == *"CommandLineTools"* || -z "$DEV" ]]; then
  echo "❌ Aktywny toolchain to '$DEV' — brak pełnego Xcode." >&2
  echo "   Ten projekt wymaga Xcode (plugin FoundationModelsMacros + SourceKit dla SwiftLint)." >&2
  echo "   → Zainstaluj Xcode i przełącz:  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
  echo "   → Albo weryfikuj w CI (GitHub Actions ma Xcode): zrób push i sprawdź workflow." >&2
  exit 2
fi

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
