#!/usr/bin/env bash
#
# merge.sh — integrate a feature branch into main, verify the result, then clean up.
#
# Usage:
#   ./scripts/merge.sh <branch> <message> [--into <target>] [--no-verify] [--no-fetch] [--force]
#
# Run from anywhere inside the repository. Against the MAIN working tree it:
#   1. fetches <target> from origin and refuses if the local one is behind,
#   2. rehearses the merge with `git merge-tree` — a conflicting branch is
#      reported before <target> is touched at all,
#   3. checks out <target> and merges <branch> with a merge commit (--no-ff),
#      using <message> as the merge commit message,
#   4. runs ./scripts/check.sh on the merged result (guard test, build, test,
#      swiftlint --strict) — the gate that decides whether the merge is good,
#   5. re-checks that <branch> really is in <target>, and only then removes the
#      worktree holding it and deletes the branch.
#
# The quality gate sits between the merge and the cleanup on purpose: if the
# integrated state fails, the branch and its worktree survive so the work can be
# fixed, and the exact `git reset --hard ORIG_HEAD` undo is printed. Nothing is
# reset automatically — undoing a commit on <target> is the caller's decision.
#
# Cleanup is all-or-nothing. Git refuses to delete a branch a worktree still has
# checked out, so the worktree must go first and the order cannot be reversed;
# instead every precondition is checked before that first irreversible step, so a
# refusal never leaves a removed worktree next to a surviving branch.
#
# It is deliberately careful:
#   - refuses if the main working tree is dirty (commit or stash first),
#   - refuses to delete protected branches (main/master/develop/release/*),
#   - on a merge conflict it stops and leaves the conflict to be resolved,
#   - without --force it will NOT remove a worktree that still has local or
#     untracked changes (re-run with --force to discard them).
#
# Feature worktrees live in <repo>/.worktrees/<name> (see AGENTS.md); the older
# .claude/worktrees/* layout still works — the worktree holding <branch> is
# discovered from `git worktree list`, never from a hardcoded path.
#
# Arguments:
#   <branch>          feature branch to merge and delete (required)
#   <message>         merge commit message (required and non-empty)
#
# Options:
#   --into <target>   branch to merge into (default: main)
#   --no-verify       skip ./scripts/check.sh (only when the gate cannot run
#                     locally, e.g. no full Xcode toolchain — CI still runs it)
#   --no-fetch        skip the origin fetch (offline)
#   --force, -f       discard local/untracked changes when removing the worktree
#   -h, --help        show this header

set -euo pipefail

TARGET="main"
FORCE=0
VERIFY=1
FETCH=1
BRANCH=""
MESSAGE=""
MSG_SET=0

usage() {
  echo "usage: $0 <branch> <message> [--into <target>] [--no-verify] [--no-fetch] [--force]" >&2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --force|-f) FORCE=1; shift ;;
    --no-verify) VERIFY=0; shift ;;
    --no-fetch) FETCH=0; shift ;;
    --into) TARGET="${2:?--into needs a branch name}"; shift 2 ;;
    -h|--help) awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next} {exit}' "$0"; exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *)
      if [ -z "$BRANCH" ]; then
        BRANCH="$1"
      elif [ "$MSG_SET" -eq 0 ]; then
        MESSAGE="$1"; MSG_SET=1
      else
        echo "unexpected extra argument: $1" >&2; exit 2
      fi
      shift ;;
  esac
done

[ -n "$BRANCH" ] || { usage; exit 2; }
[ "$MSG_SET" -eq 1 ] && [ -n "$MESSAGE" ] || {
  echo "merge message is required" >&2
  usage
  exit 2
}

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "not inside a git repository" >&2; exit 1; }

if [ "$BRANCH" = "$TARGET" ]; then
  echo "refusing to merge '$BRANCH' into itself" >&2; exit 1
fi
case "$BRANCH" in
  main|master|develop|release/*)
    echo "refusing to delete protected branch '$BRANCH'" >&2; exit 1 ;;
esac

git show-ref --verify --quiet "refs/heads/$BRANCH" || { echo "branch '$BRANCH' does not exist" >&2; exit 1; }
git show-ref --verify --quiet "refs/heads/$TARGET" || { echo "target branch '$TARGET' does not exist" >&2; exit 1; }

# The first entry of the worktree list is the main working tree.
MAIN_WT="$(git worktree list --porcelain | sed -n '1s/^worktree //p')"
[ -n "$MAIN_WT" ] || { echo "cannot locate the main working tree" >&2; exit 1; }

# Find the worktree (if any) that has <branch> checked out — space-safe parse.
BRANCH_WT=""
cur=""
while IFS= read -r line; do
  case "$line" in
    "worktree "*) cur="${line#worktree }" ;;
    "branch refs/heads/$BRANCH") BRANCH_WT="$cur"; break ;;
  esac
done < <(git worktree list --porcelain)

cd "$MAIN_WT"

# Tracked modifications block the merge outright. Untracked files do not — most of
# them are noise (build output, scratch files) — except the ones the merge would
# overwrite, which make `git merge` abort halfway. Those are found precisely below,
# once the merge base is known, instead of refusing on any untracked file at all.
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  echo "main working tree ($MAIN_WT) has uncommitted changes — commit or stash first" >&2
  git status --short --untracked-files=no >&2
  exit 1
fi

if [ "$FETCH" -eq 1 ] && git remote get-url origin >/dev/null 2>&1; then
  echo ">> fetching origin/$TARGET"
  if git fetch --quiet origin "$TARGET" 2>/dev/null; then
    behind="$(git rev-list --count "$TARGET..origin/$TARGET" 2>/dev/null || echo 0)"
    if [ "${behind:-0}" -gt 0 ]; then
      echo "!! local '$TARGET' is $behind commit(s) behind origin/$TARGET — nothing was merged." >&2
      echo "   Integrate the remote state first, then re-run:" >&2
      echo "     git -C $MAIN_WT checkout $TARGET && git -C $MAIN_WT pull --ff-only" >&2
      exit 1
    fi
  else
    echo "   fetch failed (offline?) — continuing against local refs only" >&2
  fi
fi

# Rehearse the merge before touching <target>. Exit 1 means conflicts; anything
# above that is a git-side error, in which case the rehearsal is simply skipped.
echo ">> rehearsing merge of $BRANCH into $TARGET"
REHEARSAL="$(mktemp -t merge-rehearsal)"
trap 'rm -f "$REHEARSAL"' EXIT
rehearsal_rc=0
git merge-tree --write-tree --name-only "$TARGET" "$BRANCH" >"$REHEARSAL" 2>/dev/null || rehearsal_rc=$?
if [ "$rehearsal_rc" -eq 1 ]; then
  echo "!! '$BRANCH' conflicts with '$TARGET' — nothing was merged. Conflicting paths:" >&2
  sed '1d' "$REHEARSAL" | sed 's/^/     /' >&2
  echo "   Resolve on the feature branch first:" >&2
  echo "     git -C ${BRANCH_WT:-<worktree-path>} merge $TARGET" >&2
  exit 1
elif [ "$rehearsal_rc" -gt 1 ]; then
  echo "   rehearsal unavailable (git merge-tree returned $rehearsal_rc) — proceeding" >&2
fi

# An untracked file in the main tree that the incoming diff also touches makes
# `git merge` abort after it has already started. Catching it here keeps <target>
# clean and names the file instead of leaving a half-applied merge behind.
BASE="$(git merge-base "$TARGET" "$BRANCH" 2>/dev/null || true)"
if [ -n "$BASE" ]; then
  collisions=""
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    if [ -e "$path" ] && [ -z "$(git ls-files -- "$path")" ]; then
      collisions="$collisions     $path"$'\n'
    fi
  done < <(git diff --name-only "$BASE" "$BRANCH")
  if [ -n "$collisions" ]; then
    echo "!! untracked file(s) in $MAIN_WT would be overwritten by the merge — nothing was merged:" >&2
    printf '%s' "$collisions" >&2
    echo "   Remove or commit them, then re-run." >&2
    exit 1
  fi
fi

echo ">> checking out $TARGET in $MAIN_WT"
git checkout "$TARGET"

echo ">> merging $BRANCH into $TARGET (--no-ff)"
merge_rc=0
git merge --no-ff -m "$MESSAGE" "$BRANCH" || merge_rc=$?
if [ "$merge_rc" -ne 0 ]; then
  echo "!! merge failed — resolve it and commit, then clean up manually:" >&2
  echo "     git worktree remove ${BRANCH_WT:-<worktree-path>} && git branch -d $BRANCH" >&2
  exit 1
fi

if [ "$VERIFY" -eq 1 ]; then
  echo ">> verifying the merged result: ./scripts/check.sh"
  gate_rc=0
  ./scripts/check.sh || gate_rc=$?
  if [ "$gate_rc" -ne 0 ]; then
    echo "!! the quality gate failed on the merged result (exit $gate_rc)." >&2
    echo "   The merge commit is IN PLACE and '$BRANCH' was kept so the work can be fixed." >&2
    echo "   Fix forward on '$TARGET', or undo the merge with:" >&2
    echo "     git -C $MAIN_WT reset --hard ORIG_HEAD" >&2
    exit 1
  fi
else
  echo ">> skipping ./scripts/check.sh (--no-verify)"
fi

# Cleanup is all-or-nothing, so everything that can say no says it here, before the
# first irreversible step. Git forbids deleting a branch that a worktree still has
# checked out, so the worktree has to go first — which means a check left until after
# the removal can only ever fail with the worktree already gone and the branch still
# there. That half-done state is what this ordering exists to prevent.
#
# The ancestor test is the real safety gate, and it asks the question that matters: is
# the work already in <target>? `git branch -d` asks a different one — with an upstream
# set it demands merged-into-UPSTREAM, so a branch created off origin/main is refused
# for as long as <target> is unpushed ("not yet merged to refs/remotes/origin/main,
# even though it is merged to HEAD"). Verify against <target> here, then use -D below
# to carry that verdict out rather than let -d overrule it.
if ! git merge-base --is-ancestor "$BRANCH" "$TARGET"; then
  echo "refusing to clean up '$BRANCH': it is not fully merged into '$TARGET'" >&2
  echo "   Nothing was removed — the worktree and the branch are both untouched." >&2
  exit 1
fi

# Remove the branch's worktree (never the main one).
if [ -n "$BRANCH_WT" ] && [ "$BRANCH_WT" != "$MAIN_WT" ]; then
  echo ">> removing worktree $BRANCH_WT"
  if [ "$FORCE" -eq 1 ]; then
    git worktree remove --force "$BRANCH_WT"
  elif ! git worktree remove "$BRANCH_WT"; then
    echo "!! worktree has local/untracked changes; re-run with --force to discard them." >&2
    echo "   (the merge already succeeded; only cleanup was skipped)" >&2
    exit 1
  fi
fi

echo ">> deleting branch $BRANCH"
git branch -D "$BRANCH"

echo "✓ merged $BRANCH into $TARGET, gate green, cleaned up"
