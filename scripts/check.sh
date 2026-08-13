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
#   0f. test-catalog-envelope-guard — the OTA envelope verifies, refuses a swapped payload
#                                     and unwraps byte-for-byte
#   0g. test-coverage-bundle-guard — coverage picks a test bundle covering the app target
#                                     under both SwiftPM build-system layouts
#   0h. test-release-baseline-guard — release.sh reads "previous release" from the subject,
#                                     not from any line of the message body
#   0i. test-release-headings-guard — release.sh republishes a hand-written changelog
#                                     heading exactly as written
#   1. swift build              — compiles app + helper + core
#   2. swift test               — full unit-test suite
#   3. swiftlint lint --strict  — zero lint violations (warnings fail too)
#
# Note: this gate requires a full Xcode toolchain — Command Line Tools alone do
# not carry a SourceKit SwiftLint can load (xcode-select -p must point at
# Xcode.app, not /Library/Developer/CommandLineTools). LT-04 removed the second
# reason, the FoundationModelsMacros plugin, along with the dead on-device
# release-notes triage tier that needed it.
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

# SEC-07: the envelope's whole promise is that the signature covers the payload rather
# than the document around it. That promise lives in two shell scripts, so `swift test`
# cannot see it — this exercises it against the committed catalog and the real key.
# Skips itself when signing is unconfigured; needs no secret.
echo "→ ./scripts/test-catalog-envelope-guard.sh"
./scripts/test-catalog-envelope-guard.sh

# Pure bash too, and it earns its place here rather than only in CI: the local toolchain and
# the CI toolchain emit different XCTest bundle layouts, so the coverage step is the one gate
# that can be green on a developer machine and red on the runner. This exercises both layouts
# on stub bundles, without a build.
echo "→ ./scripts/test-coverage-bundle-guard.sh"
./scripts/test-coverage-bundle-guard.sh

# REL-06: release.sh decides what "since the last release" means, and it got that wrong in
# the direction nothing else can see — a commit quoting `chore(release):` in its body was
# read as a previous release, so the first release notes replayed 85 subjects the changelog
# already described by hand. Pure bash, throwaway repositories under $TMPDIR.
echo "→ ./scripts/test-release-baseline-guard.sh"
./scripts/test-release-baseline-guard.sh

# REL-07: the same script decides how a hand-written heading is spelled in the GitHub
# Release description. Section files were named after a stripped copy of the heading and the
# heading was rebuilt from that name, so `### Known issues` shipped as `### Knownissues` —
# and `### Fixed!` was absorbed into the canonical `### Fixed`. Also pure bash.
echo "→ ./scripts/test-release-headings-guard.sh"
./scripts/test-release-headings-guard.sh

# The v0.2.0 attempt that hung: the signing key admitted only codesign, so pkgbuild waited on a
# keychain prompt no runner can answer, and the job burned GitHub's six-hour maximum without
# emitting an error. A release stall costs macOS runner minutes at the 10x rate and is invisible
# in a diff, so the tool list, the job timeout and the identity check are pinned here.
echo "→ ./scripts/test-release-signing-guard.sh"
./scripts/test-release-signing-guard.sh

# Fail fast on a CommandLineTools-only toolchain: it lacks a SourceKit that SwiftLint
# can load, so the lint step breaks with confusing errors after build and test have
# already spent their minutes.
DEV="$(xcode-select -p 2>/dev/null || true)"
if [[ "$DEV" == *"CommandLineTools"* || -z "$DEV" ]]; then
  echo "❌ Aktywny toolchain to '$DEV' — brak pełnego Xcode." >&2
  echo "   Ten projekt wymaga Xcode (SourceKit dla SwiftLint)." >&2
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
