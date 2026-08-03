#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# resolve-coverage-bundle.sh — prints the XCTest executable whose instrumented
# image covers every production target, for the SwiftPM build directory in $1.
#
# Two bundle layouts exist and the machines do not agree on which they produce:
#
#   * classic SwiftPM (the build system Xcode's toolchain still defaults to, and
#     what CI runs) merges every test target into a single
#     <Package>PackageTests.xctest. That one image links the whole package, so it
#     is the correct — and only — choice there.
#   * the SwiftBuild build system (Swift 6.4+, what a current local toolchain
#     picks) emits one bundle per test target. Only MacUpdaterUITests links
#     WegaMacUpdater on top of MacUpdaterCore, so that bundle is named
#     explicitly: choosing by directory order once let MacUpdaterTests win and
#     dropped Sources/MacUpdater from the report as uncovered.
#
# Usage: resolve-coverage-bundle.sh <bin-path>   → prints the executable path
# ---------------------------------------------------------------------------

BIN_PATH="${1:?usage: resolve-coverage-bundle.sh <bin-path>}"

PER_TARGET_BUNDLE="MacUpdaterUITests.xctest"

shopt -s nullglob
merged=("$BIN_PATH"/*PackageTests.xctest)
shopt -u nullglob

if [[ ${#merged[@]} -gt 1 ]]; then
  echo "❌ Ambiguous merged test bundles under $BIN_PATH:" >&2
  printf '   %s\n' "${merged[@]}" >&2
  exit 1
fi

if [[ ${#merged[@]} -eq 1 ]]; then
  BUNDLE="${merged[0]}"
else
  BUNDLE="$BIN_PATH/$PER_TARGET_BUNDLE"
fi

EXECUTABLE="$BUNDLE/Contents/MacOS/$(basename "$BUNDLE" .xctest)"
if [[ ! -x "$EXECUTABLE" ]]; then
  echo "❌ No test executable at $EXECUTABLE" >&2
  echo "   Expected either a merged <Package>PackageTests.xctest or $PER_TARGET_BUNDLE" >&2
  echo "   under $BIN_PATH. Run: swift build --build-tests --enable-code-coverage" >&2
  exit 1
fi

printf '%s\n' "$EXECUTABLE"
