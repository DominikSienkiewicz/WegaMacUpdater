#!/usr/bin/env bash
#
# release.sh — cut a release and push its commit and tag to start GitHub Actions.
#
# Usage:
#   ./scripts/release.sh [major|minor|patch|X.Y.Z] [--notes FILE] [--dry-run]
#
# One phase. The release notes are written (and approved) BEFORE this script runs, and
# the script copies them verbatim: it never derives, merges, reorders or rewrites text.
# It bumps AppMetadata.version, writes CHANGELOG.md, commits `chore(release): vX.Y.Z`
# with exactly those two files, creates the annotated tag and pushes both together.
#
# Notes come from --notes FILE, or, without it, from the [Unreleased] section of
# CHANGELOG.md. Leading and trailing blank lines are trimmed; everything else is copied
# byte for byte. FILE is the section body only: a line starting with `## ` is refused,
# because it would split the section. Empty notes are refused. With --notes,
# [Unreleased] is emptied and the number of lines it held is reported.
#
# The atomic push starts .github/workflows/release.yml, which triggers on
# `v*`, refuses a tag that disagrees with AppMetadata.version, builds, verifies and
# publishes. If the push fails, retry the printed push to send the existing commit and
# tag. The Claude Code release skill uses WEGA_RELEASE_LOCAL_ONLY=1 to keep the push
# as a separate, approval-gated command. See RELEASING.md.
#
# Runs only on `main`, against a clean tree that is not behind origin/main. Being ahead
# is allowed: the atomic push sends those commits with the tag, and release.yml gates
# that exact commit anyway.
#
# Arguments:
#   major|minor|patch  bump the current version accordingly (default: patch)
#   X.Y.Z              use this version verbatim
#
# Options:
#   --notes FILE       publish the contents of FILE as the release notes
#   --dry-run          print both diffs without writing release files, committing, tagging or pushing
#   -h, --help         show this header

set -euo pipefail

VERSION_FILE="Sources/WegaHelperKit/AppMetadata.swift"
CHANGELOG="CHANGELOG.md"

SPEC=""
NOTES_FILE=""
DRY_RUN=0

usage() {
  echo "usage: $0 [major|minor|patch|X.Y.Z] [--notes FILE] [--dry-run]" >&2
}

die() { echo "!! $1" >&2; shift; for line in "$@"; do echo "   $line" >&2; done; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --notes)
      [ $# -ge 2 ] && [ -n "$2" ] && [[ "$2" != -* ]] || { echo "--notes needs a file" >&2; usage; exit 2; }
      NOTES_FILE="$2"; shift 2 ;;
    -h|--help) awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next} {exit}' "$0"; exit 0 ;;
    -*) echo "unknown option: $1" >&2; usage; exit 2 ;;
    *)
      [ -n "$1" ] || { usage; exit 2; }
      if [ -z "$SPEC" ]; then SPEC="$1"; else echo "unexpected extra argument: $1" >&2; exit 2; fi
      shift ;;
  esac
done

SPEC="${SPEC:-patch}"
AUTO_PUSH=1
if [ "$DRY_RUN" -eq 1 ] || [ "${WEGA_RELEASE_LOCAL_ONLY:-0}" = 1 ]; then
  AUTO_PUSH=0
fi

# The notes path belongs to the caller's directory, and the next line leaves it.
case "$NOTES_FILE" in
  ''|/*) ;;
  *) NOTES_FILE="$PWD/$NOTES_FILE" ;;
esac

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
    "The tag must point at the commit that is main's head." \
    "  git checkout main"
}

require_in_sync() {
  local push_url
  if ! git remote get-url origin >/dev/null 2>&1; then
    [ "$AUTO_PUSH" -eq 0 ] || die "origin is required to publish a release"
    return 0
  fi
  if [ "$AUTO_PUSH" -eq 1 ]; then
    push_url="$(git remote get-url --push --all origin)" || die "cannot resolve the origin push URL"
    case "$push_url" in
      ''|*$'\n'*) die "origin must have exactly one push URL for an atomic release" ;;
    esac
  fi
  if ! git fetch --quiet --no-tags origin main 2>/dev/null; then
    [ "$AUTO_PUSH" -eq 0 ] || die "cannot fetch origin/main — no release was cut"
    echo "   fetch failed (offline?) — continuing against local refs only" >&2
    return 0
  fi
  local ahead behind
  behind="$(git rev-list --count main..origin/main)"
  ahead="$(git rev-list --count origin/main..main)"
  [ "$behind" -eq 0 ] || die "local main is $behind commit(s) behind origin/main" \
    "Integrate the remote state first, then re-run:" \
    "  git pull --ff-only"
  if [ "$ahead" -gt 0 ]; then
    echo ">> main is $ahead commit(s) ahead of origin/main — the atomic push sends them with the tag"
  fi
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

# Drops leading and trailing blank lines, keeping every other line exactly as it is —
# including whitespace-only lines in between. Always ends the last line with a newline,
# so a file without one cannot run into whatever is printed after it.
trim_blanks() {
  awk '
    /^[[:space:]]*$/ { if (started) held[++n] = $0; next }
    { for (i = 1; i <= n; i++) print held[i]; n = 0; started = 1; print }
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

# ------------------------------------------------------------------------ preconditions

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
  echo "!! the working tree has uncommitted changes — commit or stash them first" >&2
  git status --short --untracked-files=no >&2
  exit 1
fi

require_in_sync

grep -q '^## \[Unreleased\]' "$CHANGELOG" || die "$CHANGELOG has no '## [Unreleased]' heading" \
  "The release section is written above the previous release, under that heading."

echo ">> release $RESOLUTION"

TMP="$(mktemp -d -t wega-release)"
trap 'rm -rf "$TMP"' EXIT

split_changelog

# ---------------------------------------------------------------------------- the notes

if [ -n "$NOTES_FILE" ]; then
  [ -f "$NOTES_FILE" ] && [ -r "$NOTES_FILE" ] || die "cannot read the notes file: $NOTES_FILE"
  trim_blanks "$NOTES_FILE" > "$TMP/notes"
  SOURCE="$NOTES_FILE"
  SUPERSEDED="$(trim_blanks "$TMP/unreleased" | wc -l | tr -d ' ')"
  if [ "$SUPERSEDED" -gt 0 ]; then
    echo ">> --notes supersedes $SUPERSEDED line(s) of [Unreleased]"
  fi
else
  trim_blanks "$TMP/unreleased" > "$TMP/notes"
  SOURCE="[Unreleased]"
fi

[ -s "$TMP/notes" ] || die "the release notes are empty ($SOURCE)" \
  "The notes become the GitHub Release description — an empty release is almost always a mistake." \
  "Describe the release in --notes FILE or under [Unreleased] in $CHANGELOG, then re-run."

if grep -q '^## ' "$TMP/notes"; then
  {
    echo "!! the release notes ($SOURCE) contain a line starting with '## ':"
    grep -n '^## ' "$TMP/notes" | sed 's/^/     /'
    echo "   The notes are the body of one section; such a line would split it. Use '###' headings."
  } >&2
  exit 1
fi

# --------------------------------------------------------------- assemble the CHANGELOG

DATE="$(date +%Y-%m-%d)"
NEW="$TMP/CHANGELOG.new"
trim_blanks "$TMP/tail" > "$TMP/tail.trimmed"

{
  trim_blanks "$TMP/head"
  printf '\n## [Unreleased]\n\n## [%s] — %s\n\n' "$VERSION" "$DATE"
  cat "$TMP/notes"
  printf '\n'
  cat "$TMP/tail.trimmed"
} > "$NEW"

REPO_URL="$(repo_url)"
PREV="$(previous_version)"
{
  [ ! -s "$TMP/tail.trimmed" ] || printf '\n'
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

NEW_VERSION_FILE="$TMP/AppMetadata.swift"
sed "s/\(static let version = \)\"[^\"]*\"/\1\"$VERSION\"/" "$VERSION_FILE" > "$NEW_VERSION_FILE"

# ------------------------------------------------------------------------------ dry run

if [ "$DRY_RUN" -eq 1 ]; then
  echo ">> dry run — nothing was written"
  echo
  diff -u "$VERSION_FILE" "$NEW_VERSION_FILE" || true
  diff -u "$CHANGELOG" "$NEW" || true
  exit 0
fi

# ----------------------------------------------------------------------------- apply

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

ORIG_HEAD="$(git rev-parse HEAD)"
git add -- "$VERSION_FILE" "$CHANGELOG"
git commit -q -m "chore(release): $TAG" -- "$VERSION_FILE" "$CHANGELOG"
echo ">> committed chore(release): $TAG"

# If tagging fails the commit must not survive — a release commit without its tag is a
# half-cut release that the next run's gates would refuse to clean up for you.
if ! git tag -a "$TAG" -m "Wega Mac Updater $VERSION"; then
  git reset --hard "$ORIG_HEAD"
  die "could not create tag $TAG — the release commit was rolled back"
fi
echo ">> tagged $TAG"

if [ "$AUTO_PUSH" -eq 0 ]; then
  cat <<EOF

   nothing has been published yet.

   inspect:     git show $TAG
   publish:     git push --atomic origin main $TAG
   undo:        git tag -d $TAG && git reset --hard HEAD~1
EOF
  exit 0
fi

RELEASE_COMMIT="$(git rev-parse "refs/tags/$TAG^{commit}")"
MAIN_REFSPEC="$RELEASE_COMMIT:refs/heads/main"
TAG_REFSPEC="refs/tags/$TAG:refs/tags/$TAG"
if ! git push --atomic --no-follow-tags origin "$MAIN_REFSPEC" "$TAG_REFSPEC"; then
  die "could not confirm the push of $TAG — the commit and tag are available locally" \
    "Retry the same push after resolving the Git error:" \
    "  git push --atomic --no-follow-tags origin $MAIN_REFSPEC $TAG_REFSPEC"
fi
echo ">> pushed $TAG and main — GitHub Actions will build and publish the release"
