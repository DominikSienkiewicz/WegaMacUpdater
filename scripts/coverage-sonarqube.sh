#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# coverage-sonarqube.sh — turns SwiftPM code coverage into a SonarQube
# "generic test coverage" report (sonarqube-generic-coverage.xml at repo root).
#
# Why this exists:
#   SonarCloud cannot run our macOS test suite, so without an uploaded report
#   it sees the new code but has *zero* coverage data and reports 0.0% — which
#   fails the "≥ 80% coverage on new code" quality gate. This script produces
#   the report on the macOS CI runner; the SonarCloud job consumes it via
#   `sonar.coverageReportPaths` (see sonar-project.properties).
#
# Prerequisites (run before this script):
#   swift build --build-tests --enable-code-coverage
#   swift test  --skip-build  --enable-code-coverage
#
# Output: sonarqube-generic-coverage.xml (repo root). Covers Sources/** only;
# paths are emitted relative to the repo root so they match Sonar's analysis.
#
# Requirements: Xcode toolchain (xcrun llvm-cov), python3.
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR/.."
cd "$REPO_ROOT"

OUT="sonarqube-generic-coverage.xml"

BIN_PATH="$(swift build --show-bin-path)"
PROFDATA="$BIN_PATH/codecov/default.profdata"
if [[ ! -f "$PROFDATA" ]]; then
  echo "❌ No coverage data at $PROFDATA" >&2
  echo "   Run: swift build --build-tests --enable-code-coverage && swift test --skip-build --enable-code-coverage" >&2
  exit 1
fi

# The single SwiftPM test bundle links in MacUpdaterCore, so its profile covers
# all unit-tested code. (The SwiftUI app target is not exercised by unit tests;
# its View layer is excluded from coverage in sonar-project.properties.)
XCTEST="$(find "$BIN_PATH" -maxdepth 1 -name '*.xctest' | head -1)"
if [[ -z "$XCTEST" ]]; then
  echo "❌ No .xctest bundle under $BIN_PATH" >&2
  exit 1
fi
TEST_BIN="$XCTEST/Contents/MacOS/$(basename "$XCTEST" .xctest)"

echo "→ Exporting LCOV from $(basename "$TEST_BIN")"
# Keep only first-party sources; drop SwiftPM checkouts, generated sources and tests.
xcrun llvm-cov export \
  -format=lcov \
  -instr-profile "$PROFDATA" \
  "$TEST_BIN" \
  -ignore-filename-regex='(\.build/|/DerivedSources/|/Tests/)' \
  > "$BIN_PATH/coverage.lcov"

echo "→ Converting LCOV → SonarQube generic coverage XML ($OUT)"
REPO_ROOT="$REPO_ROOT" python3 - "$BIN_PATH/coverage.lcov" "$OUT" <<'PY'
import os, sys, xml.sax.saxutils as sx

lcov_path, out_path = sys.argv[1], sys.argv[2]
repo_root = os.path.realpath(os.environ["REPO_ROOT"]) + os.sep

# LCOV → {relative_source_path: {line_number: covered_bool}}
files = {}
current = None
with open(lcov_path, encoding="utf-8") as fh:
    for raw in fh:
        line = raw.strip()
        if line.startswith("SF:"):
            abs_path = os.path.realpath(line[3:])
            rel = abs_path[len(repo_root):] if abs_path.startswith(repo_root) else abs_path
            # Sonar analyses sources under Sources/; ignore anything else.
            current = rel if rel.startswith("Sources" + os.sep) else None
            if current:
                files.setdefault(current, {})
        elif line.startswith("DA:") and current:
            num, _, hits = line[3:].partition(",")
            files[current][int(num)] = int(hits) > 0
        elif line == "end_of_record":
            current = None

with open(out_path, "w", encoding="utf-8") as out:
    out.write('<coverage version="1">\n')
    for path in sorted(files):
        out.write('  <file path=%s>\n' % sx.quoteattr(path.replace(os.sep, "/")))
        for num in sorted(files[path]):
            covered = "true" if files[path][num] else "false"
            out.write('    <lineToCover lineNumber="%d" covered="%s"/>\n' % (num, covered))
        out.write('  </file>\n')
    out.write('</coverage>\n')

total = sum(len(v) for v in files.values())
covered = sum(1 for v in files.values() for c in v.values() if c)
pct = (100.0 * covered / total) if total else 0.0
print("  files=%d lines_to_cover=%d covered=%d (%.1f%%)" % (len(files), total, covered, pct))
PY

echo "✓ Wrote $OUT"
