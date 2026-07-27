# Wega Mac Updater — release tagging and version bump

**Date:** 2026-07-27
**Status:** approved, not implemented.
**Base:** `main` @ `6cc035e`
**Scope:** a `scripts/release.sh` that bumps the version, drafts release notes from commit
history, and cuts the tag; the `release.yml` change that publishes those notes; and the
missing `RELEASING.md`. No application behaviour changes.

---

## 1. Goal

Give the project a repeatable way to cut a release, with a human review gate on the release
notes before anything becomes irreversible.

## 2. Why now

The release pipeline is already entirely tag-driven and correct, but nothing feeds it:

- `.github/workflows/release.yml` triggers only on `push: tags: ['v*']`, and hard-fails
  unless the tag equals `AppMetadata.version`.
- `git tag` is empty. `0.1.0` was never tagged, so no GitHub Release exists.
- `release.yml` links to `RELEASING.md`, which does not exist.
- `CHANGELOG.md` has an `[Unreleased]` section that nothing ever rolls into a version, and a
  link-reference block at the bottom that nothing ever updates.

The gap is not the pipeline. It is the step that produces a tag the pipeline will accept.

## 3. Decisions

| # | Decision | Consequence |
|---|---|---|
| D1 | The script runs only on `main` | The tag points at the exact commit that is `origin/main`'s head, so the published artifact matches `main`. Cutting a release is integration, which is the maintainer's act, not an agent's. |
| D2 | The script never pushes | Everything it does is local and reversible until the maintainer pushes. The push command is printed, not executed. |
| D3 | Two phases separated by a review gate | Phase 1 stages, phase 2 commits and tags. State lives in git, not in a running process, so the terminal can be closed between them. |
| D4 | Version accepted as `major`/`minor`/`patch` **or** an explicit `X.Y.Z` | Keywords remove arithmetic mistakes; the explicit form stays the escape hatch when the current version cannot be parsed. |
| D5 | `CHANGELOG.md` is the release-notes file | One source of truth. What the maintainer edits becomes the GitHub Release body verbatim. |
| D6 | `release.yml` switches from `--generate-notes` to `--notes-file` | Without this, the edited notes never reach the Release page and D5 is pointless. |
| D7 | No interactive prompt | A blocking prompt cannot be covered by a test and leaves the repository half-done if the terminal dies. The review gate is a separate command instead. |
| D8 | Commit-derived entries are appended below hand-written ones, never replacing them | Contributors' `[Unreleased]` prose is the better text; generated lines are a completeness net. |

## 4. Command surface

```bash
./scripts/release.sh patch              # 0.1.5 -> 0.1.6
./scripts/release.sh minor              # 0.1.5 -> 0.2.0
./scripts/release.sh major              # 0.1.5 -> 1.0.0
./scripts/release.sh 0.2.0              # explicit
./scripts/release.sh patch --dry-run    # resolve, gate, show the diff, change nothing
./scripts/release.sh --continue         # finalise: commit + tag
./scripts/release.sh --abort            # discard a prepared release
```

Output follows the existing `scripts/` convention seen in `merge.sh`: English, lower-case,
`>>` for progress, `!!` for problems, follow-up commands indented and paste-ready.

## 5. Phase 1 — prepare

### 5.1 Gates

All are evaluated before anything is written. Each failure prints what is wrong and what to
do about it.

| # | Gate | Rationale |
|---|---|---|
| G1 | Argument is `major`/`minor`/`patch` or matches `^[0-9]+\.[0-9]+\.[0-9]+$` | A typo must not reach a tag. |
| G2 | Current branch is `main` | D1. |
| G3 | Working tree **and index** are clean | A dirty index means a release is already in progress; the message points at `--continue` or `--abort`. |
| G4 | After `git fetch`, local `main` equals `origin/main` | Otherwise the tag lands on a commit nobody else has, or misses commits that are already public. |
| G5 | Tag `vX.Y.Z` exists neither locally nor on `origin` | Re-tagging silently changes what was already released. |
| G6 | The new version is strictly greater than `AppMetadata.version` | Blocks accidental downgrades in the explicit form. |
| G7 | `AppMetadata.version` parses as `X.Y.Z` | Keyword mode only. Failure names the explicit form as the way out. |
| G8 | There is something to release: `[Unreleased]` is non-empty **or** at least one qualifying commit exists | An empty release is almost always a mistake. |

### 5.2 Actions

1. Print the resolution: `>> release 0.1.5 -> 0.1.6 (patch)`.
2. Rewrite the version in `Sources/WegaHelperKit/AppMetadata.swift`.
3. Re-extract it with the **same `sed` expression `release.yml` uses** and assert it equals
   the target. A botched substitution therefore cannot reach a tag.
4. Collect commits in the baseline range (§7) and group them (§8).
5. Rewrite `CHANGELOG.md` (§6).
6. `git add` both files. **No commit.**
7. Print the review block (§10).

`--dry-run` performs steps 1, 4 and the computation behind 5, prints the would-be diff, and
writes nothing.

## 6. CHANGELOG transformation

Before:

```markdown
## [Unreleased]

### Added
- Hand-written entry.

## [0.1.0] — 2026-06-05
```

After:

```markdown
## [Unreleased]

## [0.1.6] — 2026-07-27

### Added
- Hand-written entry.
- Resource gate for unattended cask upgrades. (a1b2c3d)

### Fixed
- Artifact gate recognises Developer ID. (6cc035e)

## [0.1.0] — 2026-06-05
```

Rules:

- `## [Unreleased]` survives as an empty heading at the top.
- The new section heading uses an em dash and `YYYY-MM-DD` in local time, matching the
  existing `## [0.1.0] — 2026-06-05`.
- Within the new section, hand-written entries come first under their original `###`
  headings; generated entries are appended to the matching heading, each suffixed with the
  short SHA.
- `###` headings are emitted in Keep a Changelog order: Added, Changed, Deprecated, Removed,
  Fixed, Security. Empty headings are omitted.
- The link-reference block at the bottom is maintained:
  `[Unreleased]` becomes `compare/v0.1.6...HEAD`, and `[0.1.6]: compare/v0.1.0...v0.1.6` is
  inserted above the previous version's line. When no previous tag exists, the new entry uses
  `releases/tag/v0.1.6`, matching how `[0.1.0]` is written today.

## 7. Commit baseline

The range end is `HEAD`. The start is the first of these that resolves:

1. The most recent tag matching `v*`, by commit date.
2. The most recent commit whose subject starts with `chore(release):`.

Rule 2 exists because `0.1.0` shipped without a tag.

**If neither resolves, no commit-derived entries are generated at all** and the notes come
from `[Unreleased]` alone. Falling back to the root commit was tried and rejected: against the
real repository it produced 185 entries from 272 commits, which is a history dump, not a
release note. The changelog already describes the shipped work by hand. Verified on
`main` @ `6cc035e`.

The chosen baseline — or its absence — is always printed, so it is never a guess.

## 8. Commit classification

Subjects are read as Conventional Commits, which `CONTRIBUTING.md` already mandates.

| Prefix | Section |
|---|---|
| `feat` | Added |
| `fix` | Fixed |
| `refactor`, `perf` | Changed |
| `docs`, `test`, `chore`, `style`, `ci`, `build` | skipped |

Also skipped: merge commits, and commits whose subject starts with `chore(release):`. A
subject that is not a Conventional Commit is skipped and counted in the summary line, so
nothing disappears silently:

```
>> collected 14 commits since v0.1.5 (9 kept, 5 skipped: docs/test/chore)
```

Scopes are preserved in the emitted text; the type prefix is stripped and the first letter
capitalised.

## 9. Phase 2 — finalise

`--continue` re-runs `git add` on the two files so the maintainer's edits are picked up, then
gates:

| # | Gate |
|---|---|
| C1 | Branch is `main`. |
| C2 | No file other than those two is modified or staged. |
| C3 | `AppMetadata.version` parses as `X.Y.Z` and tag `vX.Y.Z` still does not exist. |
| C4 | `CHANGELOG.md` contains a `## [X.Y.Z]` section and it is not empty. |
| C5 | Local `main` still equals `origin/main`. |

Then: commit `chore(release): vX.Y.Z` covering only those two files, and an annotated tag
`vX.Y.Z` with message `Wega Mac Updater X.Y.Z`.

`--abort` restores both files to `HEAD` in index and working tree, so the maintainer does not
have to remember `git restore`.

Failure part-way through phase 2 is unwound by a `trap`: if the tag cannot be created, the
commit is rolled back, leaving `main` where it started.

## 10. Terminal output

End of phase 1:

```
>> release 0.1.5 -> 0.1.6 (patch)
>> bumped Sources/WegaHelperKit/AppMetadata.swift
>> collected 14 commits since v0.1.5 (9 kept, 5 skipped: docs/test/chore)
>> wrote CHANGELOG.md section [0.1.6] - 2026-07-27

   nothing has been committed. two files are staged for review:

     Sources/WegaHelperKit/AppMetadata.swift
     CHANGELOG.md

   review the release notes - they become the GitHub Release description verbatim:

     $EDITOR CHANGELOG.md
     git diff --staged CHANGELOG.md

   when the notes read the way you want, finalise the release:

     ./scripts/release.sh --continue

   or discard everything:

     ./scripts/release.sh --abort
```

End of phase 2:

```
>> committed chore(release): v0.1.6
>> tagged v0.1.6

   nothing has been published yet.

   inspect:     git show v0.1.6
   publish:     git push origin main --follow-tags
   undo:        git tag -d v0.1.6 && git reset --hard HEAD~1
```

## 11. release.yml changes

Two edits, both in `.github/workflows/release.yml`.

1. The existing **Verify tag matches AppMetadata.version** step also asserts that
   `CHANGELOG.md` contains a `## [X.Y.Z]` section. It runs before the build, so a missing
   section fails in seconds rather than after the full build and notarization.
2. The **Create GitHub Release** step extracts that section — `awk` from the version heading
   to the next `## [` — into a notes file and passes `--notes-file` instead of
   `--generate-notes`. The unsigned-build warning is appended to the extracted text, keeping
   its current behaviour.

## 12. Documentation

`RELEASING.md`, at the repository root, where `release.yml:13` already points:

- the two-phase procedure, end to end;
- what happens after the push, and how to read the workflow run;
- how to create each of the eight optional signing and notarization secrets;
- the unsigned fallback and what it means for users;
- troubleshooting: tag/version mismatch, a missing changelog section, and withdrawing a
  published release.

`CONTRIBUTING.md` gets one pointer line in its version paragraph.

## 13. Out of scope

- **Tests for the script.** Declined for this change. `scripts/` has a guard-test convention
  (`test-merge.sh`, `test-clean-script-guard.sh`) that a release-cutting script would
  otherwise fit; recorded here so the omission is a decision on record rather than an
  oversight.
- **The stale `AppMetadata.swift` path** in `CHANGELOG.md:8` and `CONTRIBUTING.md:74`, which
  say `Sources/MacUpdaterCore/` where the file is `Sources/WegaHelperKit/`. Declined for this
  change.
- **Tagging `v0.1.0`.** The first release stays the maintainer's call.
- Pre-release and build-metadata versions (`1.0.0-rc.1`). `X.Y.Z` only.
