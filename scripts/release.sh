#!/usr/bin/env bash
#
# release.sh — bump the version, draft the release notes, and cut the tag.
#
# Usage:
#   ./scripts/release.sh <major|minor|patch|X.Y.Z> [--dry-run]
#   ./scripts/release.sh --continue
#   ./scripts/release.sh --abort
#
# Cutting a release happens in two phases with a review gate in between, because the
# release notes are worth reading before they become the GitHub Release description.
#
#   Phase 1 (prepare)  bumps AppMetadata.version, rewrites CHANGELOG.md — moving the
#                      hand-written [Unreleased] entries under a new version heading and
#                      appending entries derived from the commits since the last release —
#                      then STAGES both files and stops. Nothing is committed.
#
#   (you review, and edit CHANGELOG.md until the notes read the way you want)
#
#   Phase 2 (--continue) re-stages your edits, re-checks everything, commits
#                      `chore(release): vX.Y.Z` and creates the annotated tag.
#
# NOTHING IS EVER PUSHED. Until you run the printed `git push`, every step is local and
# reversible; `--abort` throws a prepared release away.
#
# Pushing the tag is what starts the release: .github/workflows/release.yml triggers on
# `v*`, refuses a tag that disagrees with AppMetadata.version, builds, verifies and
# publishes. See RELEASING.md.
#
# Runs only on `main`, against a clean tree that matches origin/main, so the tag always
# points at the exact commit that is main's head.
#
# Arguments:
#   major|minor|patch  bump the current version accordingly (0.1.5 -> 0.2.0 for `minor`)
#   X.Y.Z              use this version verbatim
#
# Options:
#   --dry-run          resolve, run every check, print the diff, change nothing
#   --continue         finalise a prepared release: commit and tag
#   --abort            discard a prepared release, restoring both files
#   -h, --help         show this header

set -euo pipefail

VERSION_FILE="Sources/WegaHelperKit/AppMetadata.swift"
CHANGELOG="CHANGELOG.md"
# Keep a Changelog's canonical section order; the existing [0.1.0] section follows it.
SECTION_ORDER="Added Changed Deprecated Removed Fixed Security"

MODE="prepare"
SPEC=""
DRY_RUN=0

usage() {
  echo "usage: $0 <major|minor|patch|X.Y.Z> [--dry-run]" >&2
  echo "       $0 --continue | --abort" >&2
}

die() { echo "!! $1" >&2; shift; for line in "$@"; do echo "   $line" >&2; done; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --continue) MODE="continue"; shift ;;
    --abort) MODE="abort"; shift ;;
    -h|--help) awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next} {exit}' "$0"; exit 0 ;;
    -*) echo "unknown option: $1" >&2; usage; exit 2 ;;
    *)
      if [ -z "$SPEC" ]; then SPEC="$1"; else echo "unexpected extra argument: $1" >&2; exit 2; fi
      shift ;;
  esac
done

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "not inside a git repository" >&2; exit 1; }
cd "$(git rev-parse --show-toplevel)"

[ -f "$VERSION_FILE" ] || die "cannot find $VERSION_FILE"
[ -f "$CHANGELOG" ] || die "cannot find $CHANGELOG"

# ---------------------------------------------------------------------------- helpers

# The single source of truth, read with the SAME expression release.yml uses to verify
# the tag. Reading it any other way here would let the two drift.
current_version() {
  sed -n 's/.*static let version = "\(.*\)".*/\1/p' "$VERSION_FILE" | head -1
}

is_semver() { case "$1" in ''|*[!0-9.]*) return 1 ;; esac; [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; }

# 0.1.5 -> 000000.000001.000005, so a plain string comparison orders versions correctly.
semver_key() { printf '%06d.%06d.%06d' "${1%%.*}" "$(echo "$1" | cut -d. -f2)" "${1##*.}"; }

semver_gt() { [ "$(semver_key "$1")" \> "$(semver_key "$2")" ]; }

bump_version() {
  local cur="$1" part="$2" major minor patch
  major="${cur%%.*}"; minor="$(echo "$cur" | cut -d. -f2)"; patch="${cur##*.}"
  case "$part" in
    major) major=$((major + 1)); minor=0; patch=0 ;;
    minor) minor=$((minor + 1)); patch=0 ;;
    patch) patch=$((patch + 1)) ;;
  esac
  echo "$major.$minor.$patch"
}

tag_exists_locally() { git rev-parse -q --verify "refs/tags/$1" >/dev/null 2>&1; }

tag_exists_on_origin() {
  git remote get-url origin >/dev/null 2>&1 || return 1
  [ -n "$(git ls-remote --tags origin "refs/tags/$1" 2>/dev/null)" ]
}

require_main() {
  local branch
  branch="$(git rev-parse --abbrev-ref HEAD)"
  [ "$branch" = "main" ] || die "refusing to run on '$branch' — a release is cut on main only" \
    "The tag must point at the commit that is origin/main's head." \
    "  git checkout main"
}

require_in_sync() {
  git remote get-url origin >/dev/null 2>&1 || return 0
  if ! git fetch --quiet origin main 2>/dev/null; then
    echo "   fetch failed (offline?) — continuing against local refs only" >&2
    return 0
  fi
  local ahead behind
  behind="$(git rev-list --count main..origin/main)"
  ahead="$(git rev-list --count origin/main..main)"
  [ "$behind" -eq 0 ] || die "local main is $behind commit(s) behind origin/main" \
    "Integrate the remote state first, then re-run:" \
    "  git pull --ff-only"
  [ "$ahead" -eq 0 ] || die "local main is $ahead commit(s) ahead of origin/main" \
    "Push or drop them first — a release must not tag commits nobody else has."
}

# Repository URL for the CHANGELOG link-reference block, derived from origin so it cannot
# disagree with where the code actually lives.
repo_url() {
  local url
  url="$(git remote get-url origin 2>/dev/null || true)"
  # git@host:owner/repo -> https://host/owner/repo. The colon must be replaced before the
  # scheme is prefixed, or the substitution eats the one in "https://".
  case "$url" in
    git@*:*) url="${url#git@}"; url="https://${url/://}" ;;
  esac
  echo "${url%.git}"
}

# The most recent *released* version already in the changelog, if any. It is used only to
# build the `compare/vPREV...vNEW` link, and a comparison range against a tag that does not
# exist is a 404 — so a section heading alone does not qualify. `0.1.0` shipped untagged
# (QA-06), so it must not become the baseline of the first release's link.
previous_version() {
  local version
  version="$(grep -m1 -o '^## \[[0-9][0-9.]*\]' "$CHANGELOG" 2>/dev/null | tr -d '#[] ' || true)"
  [ -n "$version" ] || return 0
  tag_exists_locally "v$version" || tag_exists_on_origin "v$version" || return 0
  echo "$version"
}

# Drops leading and trailing blank lines, keeping the ones in between.
trim_blanks() {
  awk '
    /^[[:space:]]*$/ { if (started) pending++; next }
    { while (pending-- > 0) print ""; pending = 0; started = 1; print }
  ' "$1"
}

# Splits CHANGELOG.md into head / unreleased body / older releases / link references.
split_changelog() {
  : > "$TMP/head"; : > "$TMP/unreleased"; : > "$TMP/tail"; : > "$TMP/links"
  awk -v head="$TMP/head" -v unrel="$TMP/unreleased" -v tail="$TMP/tail" '
    /^## \[Unreleased\]/ { state = 1; next }
    state == 1 && /^## \[/ { state = 2 }
    state == 0 { print > head; next }
    state == 1 { print > unrel; next }
    { print > tail }
  ' "$CHANGELOG"

  local first
  first="$(grep -n -m1 '^\[[^]]*\]: https\?://' "$TMP/tail" | cut -d: -f1 || true)"
  if [ -n "$first" ]; then
    sed -n "${first},\$p" "$TMP/tail" > "$TMP/links"
    sed -n "1,$((first - 1))p" "$TMP/tail" > "$TMP/tail.body"
    mv "$TMP/tail.body" "$TMP/tail"
  fi
}

# Splits a section body into one file per '### Heading', so hand-written and generated
# entries can be merged under the same headings.
split_sections() {
  mkdir -p "$2"
  awk -v dir="$2" '
    /^### / { sec = $0; sub(/^### +/, "", sec); gsub(/[^A-Za-z]/, "", sec); file = dir "/" sec; next }
    file != "" { print >> file }
  ' "$1"
}

# ------------------------------------------------------------------------ mode: abort

if [ "$MODE" = "abort" ]; then
  require_main
  if [ -z "$(git status --porcelain --untracked-files=no -- "$VERSION_FILE" "$CHANGELOG")" ]; then
    die "nothing to abort — $VERSION_FILE and $CHANGELOG are unchanged"
  fi
  git restore --staged --worktree -- "$VERSION_FILE" "$CHANGELOG"
  echo ">> restored $VERSION_FILE and $CHANGELOG to HEAD"
  echo "✓ prepared release discarded"
  exit 0
fi

# --------------------------------------------------------------------- mode: continue

if [ "$MODE" = "continue" ]; then
  [ -z "$SPEC" ] || { echo "--continue takes no version argument" >&2; usage; exit 2; }
  require_main

  # Pick up whatever was edited during the review.
  git add -- "$VERSION_FILE" "$CHANGELOG"

  CHANGED="$(git status --porcelain --untracked-files=no | awk '{print $NF}' | sort -u)"
  [ -n "$CHANGED" ] || die "nothing is prepared — run ./scripts/release.sh <major|minor|patch|X.Y.Z> first"

  EXTRA="$(printf '%s\n' "$CHANGED" | grep -v -x -e "$VERSION_FILE" -e "$CHANGELOG" || true)"
  if [ -n "$EXTRA" ]; then
    echo "!! files other than the release files are modified:" >&2
    printf '%s\n' "$EXTRA" | sed 's/^/     /' >&2
    echo "   A release commit must contain the version bump and the changelog, nothing else." >&2
    echo "   Commit or stash them, then re-run --continue." >&2
    exit 1
  fi

  VERSION="$(current_version)"
  is_semver "$VERSION" || die "$VERSION_FILE holds '$VERSION', which is not X.Y.Z"
  TAG="v$VERSION"
  ! tag_exists_locally "$TAG" || die "tag $TAG already exists locally"
  ! tag_exists_on_origin "$TAG" || die "tag $TAG already exists on origin"

  grep -q "^## \[$VERSION\]" "$CHANGELOG" || die "$CHANGELOG has no '## [$VERSION]' section" \
    "release.yml refuses to publish without it. Re-run --abort and start over."

  SECTION_BODY="$(awk -v v="## [$VERSION]" '
    index($0, v) == 1 { state = 1; next }
    state == 1 && /^## \[/ { exit }
    state == 1 { print }
  ' "$CHANGELOG" | tr -d '[:space:]')"
  [ -n "$SECTION_BODY" ] || die "the '## [$VERSION]' section is empty" \
    "The release notes become the GitHub Release description — an empty release is almost" \
    "always a mistake. Edit $CHANGELOG, or run --abort."

  require_in_sync

  ORIG_HEAD="$(git rev-parse HEAD)"
  git commit -q -m "chore(release): $TAG" -- "$VERSION_FILE" "$CHANGELOG"
  echo ">> committed chore(release): $TAG"

  # If tagging fails the commit must not survive — a release commit without its tag is a
  # half-cut release that the next run's gates would refuse to clean up for you.
  if ! git tag -a "$TAG" -m "Wega Mac Updater $VERSION"; then
    git reset --hard "$ORIG_HEAD"
    die "could not create tag $TAG — the release commit was rolled back"
  fi
  echo ">> tagged $TAG"

  cat <<EOF

   nothing has been published yet.

   inspect:     git show $TAG
   publish:     git push origin main --follow-tags
   undo:        git tag -d $TAG && git reset --hard HEAD~1
EOF
  exit 0
fi

# ---------------------------------------------------------------------- mode: prepare

[ -n "$SPEC" ] || { usage; exit 2; }

require_main

CURRENT="$(current_version)"
[ -n "$CURRENT" ] || die "cannot read the version from $VERSION_FILE"

case "$SPEC" in
  major|minor|patch)
    is_semver "$CURRENT" || die "$VERSION_FILE holds '$CURRENT', which is not X.Y.Z" \
      "'$SPEC' has nothing to bump from. Pass the version explicitly instead:" \
      "  ./scripts/release.sh 0.2.0"
    VERSION="$(bump_version "$CURRENT" "$SPEC")"
    RESOLUTION="$CURRENT -> $VERSION ($SPEC)"
    ;;
  *)
    is_semver "$SPEC" || { echo "!! '$SPEC' is not major, minor, patch or X.Y.Z" >&2; usage; exit 2; }
    VERSION="$SPEC"
    RESOLUTION="$CURRENT -> $VERSION"
    ;;
esac

if is_semver "$CURRENT"; then
  semver_gt "$VERSION" "$CURRENT" || die "$VERSION is not greater than the current $CURRENT" \
    "Releasing backwards would make the update check offer users an older build."
fi

TAG="v$VERSION"
! tag_exists_locally "$TAG" || die "tag $TAG already exists locally" \
  "Re-tagging silently changes what was already released." \
  "  git tag -d $TAG   (only if it was never pushed)"
! tag_exists_on_origin "$TAG" || die "tag $TAG already exists on origin — $VERSION is published"

if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  if [ -n "$(git status --porcelain --untracked-files=no -- "$VERSION_FILE" "$CHANGELOG")" ]; then
    die "a release is already prepared (the release files are modified)" \
      "Finish it, or throw it away:" \
      "  ./scripts/release.sh --continue" \
      "  ./scripts/release.sh --abort"
  fi
  echo "!! the working tree has uncommitted changes — commit or stash them first" >&2
  git status --short --untracked-files=no >&2
  exit 1
fi

require_in_sync

echo ">> release $RESOLUTION"

TMP="$(mktemp -d -t wega-release)"
trap 'rm -rf "$TMP"' EXIT

# --- baseline: what counts as "since the last release" ----------------------------------

BASELINE=""
BASELINE_LABEL=""
LAST_TAG="$(git tag --list 'v*' --sort=-creatordate | head -1)"
if [ -n "$LAST_TAG" ] && git merge-base --is-ancestor "$LAST_TAG" HEAD 2>/dev/null; then
  BASELINE="$LAST_TAG"
  BASELINE_LABEL="$LAST_TAG"
else
  # 0.1.0 shipped without a tag, so fall back to the previous release commit.
  BASELINE="$(git rev-list -1 --grep='^chore(release):' HEAD || true)"
  [ -n "$BASELINE" ] && BASELINE_LABEL="$(git log -1 --format=%s "$BASELINE")"
fi

# --- collect and classify commits -------------------------------------------------------

mkdir -p "$TMP/gen"
kept=0; skipped=0; total=0

# With no previous release to measure from, "every commit ever made" is not a release note.
# The changelog already describes the shipped history by hand, so the notes come from
# [Unreleased] alone rather than from 272 replayed subjects.
if [ -z "$BASELINE" ]; then
  echo ">> no previous release found (no v* tag, no chore(release): commit)"
  echo "   release notes will come from [Unreleased] only — the full history is not release notes"
fi

classify() {
  case "$1" in
    feat) echo "Added" ;;
    fix) echo "Fixed" ;;
    refactor|perf) echo "Changed" ;;
    *) echo "" ;;
  esac
}

: > "$TMP/skipped"
skip() { skipped=$((skipped + 1)); echo "$1" >> "$TMP/skipped"; }

while IFS=$'\x1f' read -r sha subj; do
  [ -n "$sha" ] || continue
  total=$((total + 1))
  case "$subj" in
    "chore(release):"*) skip "release"; continue ;;
  esac
  if [[ "$subj" =~ ^([a-z]+)(\(([^\)]*)\))?!?:[[:space:]]+(.*)$ ]]; then
    ctype="${BASH_REMATCH[1]}"; cscope="${BASH_REMATCH[3]}"; ctext="${BASH_REMATCH[4]}"
  else
    skip "unconventional"; continue
  fi
  section="$(classify "$ctype")"
  [ -n "$section" ] || { skip "$ctype"; continue; }

  ctext="$(printf '%s' "$ctext" | cut -c1 | tr '[:lower:]' '[:upper:]')$(printf '%s' "$ctext" | cut -c2-)"
  case "$ctext" in *[.!?]) ;; *) ctext="$ctext." ;; esac

  if [ -n "$cscope" ]; then
    printf -- '- **%s:** %s (%s)\n' "$cscope" "$ctext" "$sha" >> "$TMP/gen/$section"
  else
    printf -- '- %s (%s)\n' "$ctext" "$sha" >> "$TMP/gen/$section"
  fi
  kept=$((kept + 1))
done < <(if [ -n "$BASELINE" ]; then git log --no-merges --format="%h%x1f%s" "$BASELINE..HEAD"; fi)

if [ -n "$BASELINE" ]; then
  # Naming what was dropped, and why, keeps "skipped" from reading as "lost".
  SKIP_NOTE=""
  if [ "$skipped" -gt 0 ]; then
    SKIP_NOTE=": $(sort -u "$TMP/skipped" | paste -sd/ -)"
  fi
  echo ">> collected $total commit(s) since $BASELINE_LABEL ($kept kept, $skipped skipped$SKIP_NOTE)"
fi

# --- assemble the new CHANGELOG ---------------------------------------------------------

split_changelog
mkdir -p "$TMP/hand"
split_sections "$TMP/unreleased" "$TMP/hand"

HAND_COUNT="$(find "$TMP/hand" -type f 2>/dev/null | wc -l | tr -d ' ')"
if [ "$kept" -eq 0 ] && [ "$HAND_COUNT" -eq 0 ]; then
  if [ -n "$BASELINE" ]; then
    die "nothing to release: [Unreleased] is empty and no commits since $BASELINE_LABEL qualify" \
      "Add entries under [Unreleased] in $CHANGELOG, or land some feat:/fix:/refactor: work."
  fi
  die "nothing to release: [Unreleased] is empty" \
    "With no previous release to measure from, the notes come from [Unreleased] alone." \
    "Describe the release there in $CHANGELOG, then re-run."
fi

DATE="$(date +%Y-%m-%d)"
NEW="$TMP/CHANGELOG.new"

{
  trim_blanks "$TMP/head"
  printf '\n## [Unreleased]\n\n## [%s] — %s\n\n' "$VERSION" "$DATE"

  emitted=""
  for section in $SECTION_ORDER; do
    hand="$TMP/hand/$section"; gen="$TMP/gen/$section"
    if [ -s "$hand" ] || [ -s "$gen" ]; then
      printf '### %s\n' "$section"
      [ -s "$hand" ] && trim_blanks "$hand"
      [ -s "$gen" ] && cat "$gen"
      printf '\n'
      emitted="$emitted $section"
    fi
  done

  # A hand-written heading outside the canonical set must not be silently dropped.
  for hand in "$TMP/hand"/*; do
    [ -e "$hand" ] || continue
    section="$(basename "$hand")"
    case " $emitted " in *" $section "*) continue ;; esac
    printf '### %s\n' "$section"
    trim_blanks "$hand"
    printf '\n'
  done

  trim_blanks "$TMP/tail"
} > "$NEW"

# --- link-reference block ---------------------------------------------------------------

REPO_URL="$(repo_url)"
PREV="$(previous_version)"
{
  printf '\n'
  if [ -n "$REPO_URL" ]; then
    printf '[Unreleased]: %s/compare/v%s...HEAD\n' "$REPO_URL" "$VERSION"
    if [ -n "$PREV" ]; then
      printf '[%s]: %s/compare/v%s...v%s\n' "$VERSION" "$REPO_URL" "$PREV" "$VERSION"
    else
      printf '[%s]: %s/releases/tag/v%s\n' "$VERSION" "$REPO_URL" "$VERSION"
    fi
  fi
  # Keep every older reference, dropping the [Unreleased] line just replaced.
  grep -v '^\[Unreleased\]:' "$TMP/links" || true
} >> "$NEW"

# --- apply ------------------------------------------------------------------------------

NEW_VERSION_FILE="$TMP/AppMetadata.swift"
sed "s/\(static let version = \)\"[^\"]*\"/\1\"$VERSION\"/" "$VERSION_FILE" > "$NEW_VERSION_FILE"

if [ "$DRY_RUN" -eq 1 ]; then
  echo ">> dry run — nothing was written"
  echo
  diff -u "$VERSION_FILE" "$NEW_VERSION_FILE" || true
  diff -u "$CHANGELOG" "$NEW" || true
  exit 0
fi

cp "$NEW_VERSION_FILE" "$VERSION_FILE"

# The bump is only real if the expression release.yml uses can read it back. Verifying it
# here means a botched substitution can never reach a tag.
WRITTEN="$(current_version)"
if [ "$WRITTEN" != "$VERSION" ]; then
  git checkout -- "$VERSION_FILE"
  die "the version bump did not take: $VERSION_FILE reads '$WRITTEN', expected '$VERSION'"
fi
echo ">> bumped $VERSION_FILE"

cp "$NEW" "$CHANGELOG"
echo ">> wrote $CHANGELOG section [$VERSION] - $DATE"

git add -- "$VERSION_FILE" "$CHANGELOG"

cat <<EOF

   nothing has been committed. two files are staged for review:

     $VERSION_FILE
     $CHANGELOG

   review the release notes - they become the GitHub Release description verbatim:

     \$EDITOR $CHANGELOG
     git diff --staged $CHANGELOG

   when the notes read the way you want, finalise the release:

     ./scripts/release.sh --continue

   or discard everything:

     ./scripts/release.sh --abort
EOF
