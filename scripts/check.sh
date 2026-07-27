#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# check.sh — local quality gate before commit/push.
#
# Runs, in order (each must pass before the next — `set -e`):
#   0. test-sign-catalog-guard  — sign-catalog.sh refuses an in-repo private key
#   0b. test-merge              — merge.sh guard rails (dirty tree, conflicts, gate)
#   0c. test-source-paths-guard  — no script/workflow reads a source path that moved
#   0d. test-clean-script-guard — root clean.sh cannot regain destructive Git actions
#   0e. test-verify-bundle-guard — artifact gate still enforces notarization once signed
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

# Runs before the toolchain gate on purpose: it is pure bash, needs neither Xcode nor
# OpenSSL, and it guards a secret — it should never be skipped because the machine is
# missing a Swift toolchain.
echo "→ ./scripts/test-sign-catalog-guard.sh"
./scripts/test-sign-catalog-guard.sh

# Also pure bash, also before the toolchain gate. merge.sh deletes branches and
# worktrees after integrating into main, so its refusals are the thing standing
# between a mistake and lost work — they get tested, not just documented. The cases
# run in throwaway repositories under $TMPDIR and never touch this one.
echo "→ ./scripts/test-merge.sh"
./scripts/test-merge.sh

# QA-08: a tracked root clean.sh used to be a one-shot code generator that overwrote
# sources, committed directly to main and could delete a worktree/branch. Keep that
# misleading destructive entry point out of the repository.
# Pure bash as well, and deliberately before the toolchain gate: it catches the one
# class of breakage `swift build`/`test`/`swiftlint` structurally cannot see — a script
# or workflow reading a source file by a path that a refactor has since moved.
echo "→ ./scripts/test-source-paths-guard.sh"
./scripts/test-source-paths-guard.sh

echo "→ ./scripts/test-clean-script-guard.sh"
./scripts/test-clean-script-guard.sh

# Pure bash as well (codesign is stubbed): the artifact gate is the only check that a
# release was notarized and stapled, and its Developer-ID detection once reported a hit
# as a miss — passing signed-but-unnotarized artifacts on green.
echo "→ ./scripts/test-verify-bundle-guard.sh"
./scripts/test-verify-bundle-guard.sh

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
