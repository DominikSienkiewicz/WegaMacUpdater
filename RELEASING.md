# Releasing Wega Mac Updater

A release is a pushed `v*` tag. Everything else — building, signing, notarizing, verifying
and publishing — is done by [`.github/workflows/release.yml`](.github/workflows/release.yml)
in reaction to that tag.

```bash
./scripts/release.sh patch      # prepare: bump, draft notes, stage
# review CHANGELOG.md, edit until the notes read well
./scripts/release.sh --continue # finalise: commit + annotated tag
git push origin main --follow-tags
```

Nothing is published until that last line.

---

## 1. Before you start

- Be on `main`, with a clean working tree, in sync with `origin/main`. The script refuses
  otherwise, and says how to fix it.
- The version lives in exactly one place: `AppMetadata.version` in
  [`Sources/WegaHelperKit/AppMetadata.swift`](Sources/WegaHelperKit/AppMetadata.swift).
  Never edit it by hand — the script owns it, and the workflow refuses any tag that
  disagrees with it.

- **If the app catalog changed since the last release**, republish it *before* tagging — see
  [Republishing the app catalog](#10-republishing-the-app-catalog). It is a separate key and
  a separate artifact from the release signing, and nothing in the pipeline reminds you.

## 2. Phase 1 — prepare

```bash
./scripts/release.sh patch      # 0.1.5 -> 0.1.6
./scripts/release.sh minor      # 0.1.5 -> 0.2.0
./scripts/release.sh major      # 0.1.5 -> 1.0.0
./scripts/release.sh 0.2.0      # explicit version
```

Add `--dry-run` to see the exact diff without touching anything.

The script bumps the version, then rewrites `CHANGELOG.md`: the hand-written `[Unreleased]`
entries move under a new `## [X.Y.Z] — YYYY-MM-DD` heading, and entries derived from the
commits since the last release are appended beneath them, each carrying its short SHA.

Commits are read as [Conventional Commits](https://www.conventionalcommits.org/):

| Prefix | Lands under |
|---|---|
| `feat` | Added |
| `fix` | Fixed |
| `refactor`, `perf` | Changed |
| `docs`, `test`, `chore`, `style`, `ci`, `build` | skipped |

Merge commits, previous release commits and subjects that are not Conventional Commits are
skipped as well. Nothing disappears quietly — the summary line reports how many were skipped
and why:

```
>> collected 14 commits since v0.1.5 (9 kept, 5 skipped: chore/docs/unconventional)
```

Both files end up **staged but not committed**.

## 3. Review

This is the point of the two phases. The changelog section you are looking at becomes the
GitHub Release description verbatim, so read it as a user would:

```bash
$EDITOR CHANGELOG.md
git diff --staged CHANGELOG.md
```

The generated lines are a completeness net, not finished prose. Rewrite them, merge
duplicates, delete noise, drop the SHAs where they add nothing. Hand-written entries were
already reviewed at PR time and usually need no work.

Take as long as you like — the state lives in git, so you can close the terminal.

## 4. Phase 2 — finalise

```bash
./scripts/release.sh --continue
```

Your edits are re-staged and checked: still on `main`, still in sync with `origin/main`, no
unrelated file modified, the version parses, the tag does not exist yet, and the changelog
section is present and non-empty. Then it commits `chore(release): vX.Y.Z` and creates the
annotated tag.

Changed your mind at any point before this?

```bash
./scripts/release.sh --abort    # restores both files, leaves nothing behind
```

## 5. Publish

```bash
git push origin main --follow-tags
```

This is the irreversible step. Up to here you could still undo everything with
`git tag -d vX.Y.Z && git reset --hard HEAD~1`.

## 6. What happens next

The tag triggers [`release.yml`](.github/workflows/release.yml):

1. **Quality gate** — the same reusable [`build.yml`](.github/workflows/build.yml) CI runs,
   on the same `macos-26` runner and pinned Xcode 26 / SwiftLint 0.65.0 toolchain. Publishing
   `needs:` this job, so a release can never outrun the tests, lint, catalog and bundle
   checks, nor be built on a different toolchain than the one CI proved green.
2. **Tag verification** — the tag must equal `AppMetadata.version`, and `CHANGELOG.md` must
   contain the matching `## [X.Y.Z]` section. Both fail in seconds, before any build.
3. **Build** — `./scripts/build-pkg.sh` produces a universal `.pkg` and `.dmg`.
4. **Notarize & staple** — only when both a Developer ID and a notary key are configured.
5. **Artifact gate** — `./scripts/verify-bundle.sh` checks bundle layout, helper signature,
   notarization, stapling and required resources. A broken bundle blocks the publish.
6. **Publish** — `gh release create` uploads both artifacts and uses your changelog section
   as the release description.

Watch it under the repository's **Actions** tab. If the run fails, nothing is published; fix
the cause, delete the tag locally and on the remote, and cut the release again.

## 7. Signing and notarization secrets

All eight are **optional**. Until they exist the pipeline still builds and publishes
**unsigned** (ad-hoc) artifacts, so the whole thing is verifiable end to end without an Apple
Developer account. Each secret is set under **Settings → Secrets and variables → Actions**.

Signing needs **two different certificates**. `pkgbuild` refuses an "Application" cert — a
`.pkg` can only be signed by a "Developer ID Installer" cert.

| Secret | What it is | How to get it |
|---|---|---|
| `DEVELOPER_ID_IDENTITY` | Full name of the app-signing identity, e.g. `Developer ID Application: Jane Doe (AB12CD34EF)` | `security find-identity -v -p codesigning` |
| `DEVELOPER_ID_INSTALLER_IDENTITY` | Full name of the installer-signing identity, e.g. `Developer ID Installer: Jane Doe (AB12CD34EF)` | Same command; a distinct certificate you request in the Apple Developer portal |
| `DEVELOPER_ID_CERT_P12` | Base64 of a `.p12` containing **both** identities with their private keys | Keychain Access → select both certificates → Export → `.p12`, then `base64 -i cert.p12 \| pbcopy` |
| `DEVELOPER_ID_CERT_PASSWORD` | The password you set when exporting that `.p12` | — |
| `KEYCHAIN_PASSWORD` | Any throwaway password; the workflow uses it for a temporary keychain that lives only for the run | — |
| `AC_API_KEY_ID` | Key ID of an App Store Connect API key | App Store Connect → Users and Access → Integrations → App Store Connect API |
| `AC_API_ISSUER_ID` | Issuer ID shown above the key list on that same page | — |
| `AC_API_KEY_P8` | Contents of the downloaded `AuthKey_XXXX.p8` | Downloadable **once**, at creation — store it immediately |

The workflow reports what it found at the start of every run, without leaking any value:

```
Developer ID (code signing):   true
Developer ID Installer (.pkg): false
notarytool API key:            true
```

### Partial configurations

The pipeline degrades on purpose rather than failing:

- **No `DEVELOPER_ID_IDENTITY`** — everything is ad-hoc signed. Gatekeeper will refuse the
  app on other Macs. The release notes get an explicit unsigned warning appended.
- **App cert but no installer cert** — the `.dmg` is signed, the `.pkg` is not, and the
  `.pkg` is excluded from notarization (the notary service rejects unsigned packages).
- **Notary key but no Developer ID** — notarization is skipped entirely. Every submission
  would come back `Invalid`, because ad-hoc signatures cannot be notarized.

## 8. Troubleshooting

**`Tag v0.1.6 does not match AppMetadata.version 0.1.5`**
The tag was created by hand. Delete it and use the script, which cannot produce this state:

```bash
git tag -d v0.1.6 && git push origin :refs/tags/v0.1.6
```

**`CHANGELOG.md has no '## [0.1.6]' section`**
Same cause. The release notes are read from that section, so the workflow refuses to publish
a version the changelog does not describe.

**`a release is already prepared`**
Phase 1 ran and was never finished. Continue it, or throw it away:

```bash
./scripts/release.sh --continue
./scripts/release.sh --abort
```

**`nothing to release`**
`[Unreleased]` is empty and no commit since the last release qualifies — typically a run of
`docs:`/`chore:` work only. Add entries under `[Unreleased]`, or release nothing.

**The workflow failed after the tag was pushed**
Nothing was published. Fix the cause on `main`, then remove the tag from both places and cut
the release again:

```bash
git tag -d v0.1.6 && git push origin :refs/tags/v0.1.6
```

**A bad release was already published**
Delete the GitHub Release and its tag, then cut a new patch version. Do not re-point an
existing tag — anyone who already fetched it keeps the old commit, and the in-app self-update
check reads the Releases API, so a moved tag makes clients disagree about what `v0.1.6` is.

```bash
gh release delete v0.1.6 --yes
git push origin :refs/tags/v0.1.6
git tag -d v0.1.6
```

## 9. Cutting the first release

The project has no tags yet: `0.1.0` shipped untagged, and without a `chore(release):` commit
either. So there is no previous release to measure commits from, and the script says so:

```
>> no previous release found (no v* tag, no chore(release): commit)
   release notes will come from [Unreleased] only — the full history is not release notes
```

This is deliberate. Replaying every commit ever made would produce 185 entries, which is not
a release note. `CHANGELOG.md` already describes the shipped work by hand, so the first
release is cut from `[Unreleased]` alone; commit-derived entries start appearing from the
second release onward, measured against the tag this one creates.

The baseline is always printed, so it is never a guess.

Two consequences worth knowing before you run it:

- **The first tag will be higher than `0.1.0`.** An explicit version has to be *greater* than
  `AppMetadata.version`, which already reads `0.1.0`, so `./scripts/release.sh 0.1.0` is
  refused. The existing `## [0.1.0] — 2026-06-05` section stays in `CHANGELOG.md` as the
  untagged history it is, and the release script never rewrites it.
- **`[0.1.0]` carries no link, on purpose** (QA-06). There is no release page and no
  comparison range for a version that was never tagged, so the link reference was removed
  rather than left pointing at a 404. For the same reason `previous_version()` only accepts a
  version that has a real tag — otherwise the first release would generate
  `compare/v0.1.0...vX.Y.Z`, a dead link, and `release.sh` copies every older reference
  forward verbatim, so nothing would ever repair it.

## 10. Republishing the app catalog

The app catalog is delivered **over the air**, not in the release. Wega fetches it from
`raw.githubusercontent` at launch, so a catalog change reaches users without a new build —
and, symmetrically, cutting a release does nothing for the catalog. They are two independent
publications with two independent keys:

| | signs | key lives in | driven by |
|---|---|---|---|
| Release artifacts | `.app`, `.dmg`, `.pkg` | GitHub Actions secrets (Developer ID) | `release.yml` |
| App catalog | `app-catalog.json` | your machine, outside the repo (Ed25519) | `scripts/sign-catalog.sh` |

Only the second one is yours to run by hand, and only you can run it — `sign-catalog.sh`
refuses a key that lives inside the working tree (SEC-06).

### Publishing a catalog change

```bash
WEGA_CATALOG_KEY=~/.secrets/wega-catalog.pem ./scripts/sign-catalog.sh --envelope --bump
```

```bash
./scripts/verify-catalog.sh
```

`--bump` raises `generation`, the monotonic publication counter **inside** the signed bytes.
Wega remembers the highest generation it has accepted, across relaunches, and refuses
anything lower — which is what stops an old but perfectly-signed catalog from being replayed
at a client forever. Skipping the bump leaves that protection inert, so it is a flag rather
than a step to remember.

`--envelope` publishes the catalog as one document carrying its own signature, instead of a
JSON beside a `.sig`. Those were two separate CDN entries, so a client could fetch a fresh
catalog next to a cached signature and get a mismatch indistinguishable from tampering. One
document cannot skew against itself.

To edit the catalog by hand afterwards, unwrap it first (no key needed), edit, then publish
again with the command above:

```bash
./scripts/sign-catalog.sh --unwrap
```

### Do the envelope switch before the first tag

A build without envelope support that is served an envelope decodes it as an *empty* catalog,
then fails closed on the missing `.sig` and keeps its built-in catalog. Safe, but that build
stops receiving catalog updates until its user upgrades. Before the first release that costs
nothing, because nothing is installed yet; afterwards it strands every older build. Both
formats are read, so the switch itself is a one-time, one-command decision.
