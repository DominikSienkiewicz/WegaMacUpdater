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

# Neither layout is guaranteed to sit directly in --show-bin-path: the same branch has
# produced both a flat merged bundle and per-target bundles nested under a Products/
# subtree, and a resolver that only globbed the top level failed on the latter. Look flat
# first — a bundle beside the profdata belongs to the build that just ran — then descend.
# Kept compatible with bash 3.2, which is what /bin/bash still is on macOS — no mapfile,
# no readarray, no associative arrays.
collect_bundles() {
  pattern="$1"
  found=""
  shopt -s nullglob
  for candidate in "$BIN_PATH"/$pattern; do
    found="$found$candidate
"
  done
  shopt -u nullglob
  if [[ -n "$found" ]]; then
    printf '%s' "$found"
    return
  fi
  find "$BIN_PATH" -mindepth 2 -type d -name "$pattern" 2>/dev/null | sort
}

reject_ambiguous() {
  echo "❌ Ambiguous $1 test bundles under $BIN_PATH:" >&2
  printf '%s' "$2" | sed 's/^/   /' >&2
  echo "   Refusing to guess — a wrong pick silently drops targets from the report." >&2
  exit 1
}

count_lines() {
  [[ -z "$1" ]] && echo 0 || printf '%s' "$1" | grep -c '^'
}

MERGED="$(collect_bundles '*PackageTests.xctest')"
if [[ "$(count_lines "$MERGED")" -gt 1 ]]; then
  reject_ambiguous merged "$MERGED"
fi

if [[ -n "$MERGED" ]]; then
  BUNDLE="$(printf '%s' "$MERGED" | head -1)"
else
  PER_TARGET="$(collect_bundles "$PER_TARGET_BUNDLE")"
  if [[ "$(count_lines "$PER_TARGET")" -gt 1 ]]; then
    reject_ambiguous per-target "$PER_TARGET"
  fi
  if [[ -n "$PER_TARGET" ]]; then
    BUNDLE="$(printf '%s' "$PER_TARGET" | head -1)"
  else
    BUNDLE="$BIN_PATH/$PER_TARGET_BUNDLE"
  fi
fi

EXECUTABLE="$BUNDLE/Contents/MacOS/$(basename "$BUNDLE" .xctest)"
if [[ ! -x "$EXECUTABLE" ]]; then
  echo "❌ No test executable at $EXECUTABLE" >&2
  echo "   Expected either a merged <Package>PackageTests.xctest or $PER_TARGET_BUNDLE" >&2
  echo "   under $BIN_PATH (flat or nested). Run: swift build --build-tests --enable-code-coverage" >&2
  exit 1
fi

printf '%s\n' "$EXECUTABLE"
