# Releasing Wega Mac Updater

A release is a pushed `v*` tag. Everything else — building, signing, notarizing, verifying
and publishing — is done by [`.github/workflows/release.yml`](.github/workflows/release.yml)
in reaction to that tag.

Run the release script on a clean `main` with a signed-in Claude Code CLI. Omit the version
to bump the patch number.

```bash
./scripts/release.sh
```

Review the commit list and the proposed English release notes. Answer `Y` to publish that
text, or press Enter to cancel. The script pushes the release commit and its tag together.
GitHub Actions builds and publishes the release from the tag.

The Claude Code `release` skill proposes the version and notes for approval. After approval,
it cuts the release locally with `WEGA_RELEASE_LOCAL_ONLY=1` and makes the separately approved
atomic push from the primary checkout.

---

## 1. Before you start

- Use a clean `main` up to date with `origin/main`. The `origin` remote should fetch from and
  push to the [WegaMacUpdater organization repository](https://github.com/SeniorDeveloper-pl-Dominik-Sienkiewicz/WegaMacUpdater).
  If local `main` is ahead, the atomic push includes those commits.
- The version lives in exactly one place: `AppMetadata.version` in
  [`Sources/WegaHelperKit/AppMetadata.swift`](Sources/WegaHelperKit/AppMetadata.swift).
  Never edit it by hand — the script owns it, and the workflow refuses any tag that
  disagrees with it.

- **If the app catalog changed since the last release**, republish it *before* tagging — see
  [Republishing the app catalog](#10-republishing-the-app-catalog). It is a separate key and
  a separate artifact from the release signing, and nothing in the pipeline reminds you.

## 2. Review the release notes

The script sends the subjects and full bodies of all commits in the displayed range to
Claude Code in one request. It shows existing `[Unreleased]` entries for comparison,
then prints the exact draft that approval will put in their place. Declining leaves the
release files, commits and tags untouched.

To use your own wording, run `./scripts/release.sh --notes FILE`. The file holds the
section body and bypasses Claude. For unattended publication, `--yes --notes FILE` uses
the approved file and `--yes` alone uses the committed `[Unreleased]` section. The
Claude Code release skill uses the same prepared-notes path for its local cut.

A summary paragraph above the first `### ` heading is allowed. Any `### ` headings are kept
as written (`### Added`, `### Known issues`, …). A line starting with `## ` is refused, because
it would split the section. Leading and trailing blank lines are trimmed; everything else is
copied byte for byte. Empty notes are refused.

## 3. Cut

```bash
./scripts/release.sh           # 0.1.5 -> 0.1.6
./scripts/release.sh patch      # 0.1.5 -> 0.1.6
./scripts/release.sh minor      # 0.1.5 -> 0.2.0
./scripts/release.sh major      # 0.1.5 -> 1.0.0
./scripts/release.sh 0.2.0      # explicit version
```

The script shows commit hashes and subjects up to the current `main` tip. The range starts
after the newest version tag on `origin` whose commit is in that history. For a first release,
the list starts at the beginning of the history. The prompt defaults to cancellation.

After confirmation the script bumps `AppMetadata.version`, writes `## [X.Y.Z] — YYYY-MM-DD` into
`CHANGELOG.md` and empties `[Unreleased]`. The reviewed Markdown becomes both the versioned
section and the body of `chore(release): vX.Y.Z`. The commit contains exactly those two
files. The script creates the annotated tag `vX.Y.Z` and atomically pushes the commit and
tag to `origin`. The versioned section supplies the `body` returned by GitHub's Releases API.

It refuses to run when:

- the branch is not `main`, or tracked files are modified;
- the version is not greater than `AppMetadata.version`;
- the tag already exists, locally or on `origin`;
- `main` is behind `origin/main`;
- automatic publication cannot fetch `origin/main`, read its release tags, or resolve a single
  push URL for `origin`;
- `CHANGELOG.md` has no `## [Unreleased]` heading;
- the automatic draft has no commits to summarize, the clone is shallow or Claude Code fails;
- the notes are empty, contain a line starting with `## `, or the notes file is unreadable.

`--notes` without a value is a usage error, and the old second-phase and abort options are gone.

## 4. Preview

```bash
./scripts/release.sh --dry-run
```

The preview generates and displays a draft plus the version and changelog diffs. It leaves
the release files, commits and tags untouched. If origin's tags are unavailable, the
preview uses the newest reachable local version tag, or all history if no such tag exists.
A subsequent interactive run generates its own draft for approval. Use `--notes FILE` for
both runs to reuse precise wording.

## 5. Retry a failed push

If Git reports a push error, the script keeps the release commit and tag locally and prints
the exact push command. Use that command after resolving the Git error to retry the same
version. The GitHub Actions run starts when the tag arrives.

## 6. What happens next

The tag triggers [`release.yml`](.github/workflows/release.yml):

1. **Quality gate** — the same reusable [`build.yml`](.github/workflows/build.yml) CI runs,
   on the same `xcode-27` runner and pinned Xcode 27.2 / SwiftLint 0.65.0 toolchain. Publishing
   `needs:` this job, so a release can never outrun the tests, lint, catalog and bundle
   checks, nor be built on a different toolchain than the one CI proved green.
2. **Tag verification** — the tag must equal `AppMetadata.version`, and `CHANGELOG.md` must
   contain the matching `## [X.Y.Z]` section. Both fail in seconds, before any build.
3. **Build** — `./scripts/build-pkg.sh` produces a universal `.pkg` and `.dmg`.
4. **Notarize & staple** — only when both a Developer ID and a notary key are configured.
5. **Artifact gate** — `./scripts/verify-bundle.sh` checks bundle layout, helper signature,
   notarization, stapling, the publisher **Team ID**, that the signed app and helper satisfy
   the XPC code requirements they pin each other with, and required resources. It also checks
   Wega's own code the way the app does before a self-update or a `sudo` run: the app, askpass,
   the sudo shim, the `.dmg`, and the app and both authorization programs inside the `.pkg` need
   a Developer ID signature of Wega's Team ID that holds in every architecture and nested
   program. A broken bundle blocks the publish. For a stable release it runs with `REQUIRE_SIGNED=1`, which turns every
   "skipped because unsigned" note into a failure.
6. **Publish** — `gh release create` uploads both artifacts and uses your changelog section
   as the release description. A build that is not fully signed + notarized + stapled +
   Team-ID-pinned is published as a **prerelease** — see below.

### Stable release vs prerelease (SEC-04)

A tag is published as a **stable release** only when all three of `DEVELOPER_ID_CERT_P12`,
`DEVELOPER_ID_INSTALLER_IDENTITY` and `AC_API_KEY_P8` are configured. Anything less is
published with `--prerelease` and a warning banner in the notes.

That is a security boundary, not a label: Gatekeeper only ever answers *"notarized by some
Apple developer"*, so an artifact Wega cannot pin to its own Team ID must not be presented as
an update. `WegaSelfUpdateChecker` skips draft and prerelease tags, so an unsigned build is
never offered to anyone as a self-update — while the pipeline itself stays fully runnable
without an Apple Developer account.

Watch it under the repository's **Actions** tab. If the run fails, nothing is published; see
"The workflow failed after the tag was pushed" in [Troubleshooting](#8-troubleshooting).

## 7. Signing and notarization secrets

All eight are **optional for running the pipeline** — until they exist it still builds and
uploads **unsigned** (ad-hoc) artifacts, so the whole thing is verifiable end to end without
an Apple Developer account. They are **not optional for a stable release**: without them the
tag is published as a prerelease (see above). Each secret is set under **Settings → Secrets
and variables → Actions**.

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

The pipeline degrades on purpose rather than failing — but every degraded state produces a
**prerelease**, never a stable release:

- **No `DEVELOPER_ID_IDENTITY`** — everything is ad-hoc signed. Gatekeeper will refuse the
  app on other Macs. The release notes get an explicit unsigned warning appended.
- **App cert but no installer cert** — the `.dmg` is signed, the `.pkg` is not, and the
  `.pkg` is excluded from notarization (the notary service rejects unsigned packages).
  A release whose preferred self-update channel is unsigned is not a stable release.
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

**`main` is behind `origin/main`**
Someone pushed to `origin/main` since you last synced. Bring your local `main` up to date,
then run the script again. Being *ahead* of `origin/main` is not an error.

**`CHANGELOG.md has no '## [Unreleased]' heading` / the notes are empty**
The script needs the `[Unreleased]` heading to insert a versioned section. Its body may
be empty when Claude drafts the notes. If generation fails, check the Claude Code login,
retry, or pass a nonempty notes file as described in section 2.

**A notes line starting with `## `**
It would split the release section in two. Demote it to `### ` or reword it.

**The release job sits on `→ Tworzę PKG...` and is cancelled hours later**
A signing step waiting for a keychain authorization prompt, which no runner can answer. It does
not fail — it blocks until GitHub's job maximum, which is why the job now carries its own
`timeout-minutes`. The cause is the private key's access list: `security import -T` names the
tools allowed to use the key unattended, and it has to name **every** tool in the chain.
`codesign` signs the `.app`, but the `.pkg` is signed by `pkgbuild` — a different binary, so app
signing succeeding tells you nothing about the package. `scripts/test-release-signing-guard.sh`
pins the list; if it is green and the job still stalls, the remaining suspect is a `.p12`
exported with only one of the two identities, which the *Verify the imported signing identities*
step now reports before anything is built.

**`A timestamp was expected but was not found.`**
A Developer ID signature asks Apple's timestamp server for a secure timestamp; when the runner
gets no answer, `codesign` gives up after about 15 seconds. This is what failed the v0.7.0 build
twice in a row, while the same server answered from other networks. `build-pkg.sh` therefore runs
every Developer ID signing command (`codesign` and the signed `pkgbuild`) through
`sign_with_retry` in `scripts/sign-with-retry.sh`: an error that mentions the timestamp is retried
up to 5 times, after 15, 30, 60 and 120 seconds; any other signing error stops the build at once.
`SIGN_RETRY_ATTEMPTS` and `SIGN_RETRY_DELAY_SECONDS` change those numbers, and
`scripts/test-sign-retry-guard.sh` pins the behaviour. If the step still fails after the last
attempt, the server stayed out of reach for minutes: rerun the failed job later with
`gh run rerun <run-id> --failed`. Nothing was published, and the tag can stay.

**The workflow failed after the tag was pushed**
Nothing was published, but the release commit and the tag are on origin, and `main` already
carries the version, so `release.sh` will not cut that version again. There are two ways out:

- No code change needed (a runner hiccup, the timestamp server, a secret fixed in the
  repository settings): rerun the failed jobs. The tag stays.

  ```bash
  gh run rerun <run-id> --failed
  ```

- A code change needed: fix it on `main` like any change and release the next patch version.
  In the fix, move the unpublished version's entries from its `## [X.Y.Z]` section back under
  `[Unreleased]`, so they ship with the next release. The in-app "what's new" reads only
  published releases, so notes left under a version that never published never reach users.
  0.7.0 went this way into 0.7.1.

**A bad release was already published**
Delete the GitHub Release and its tag, then cut a new patch version. Do not re-point an
existing tag — anyone who already fetched it keeps the old commit, and the in-app self-update
check reads the Releases API, so a moved tag makes clients disagree about what `v0.1.6` is.

```bash
gh release delete v0.1.6 --yes
git push origin :refs/tags/v0.1.6
git tag -d v0.1.6
```

## 9. The first release

`v0.2.0` is the first tag; `0.1.0` shipped untagged. Two traces of that remain in
`CHANGELOG.md`:

- **The `0.2.0` section describes the application, not a delta.** It was the first thing
  anyone installed, so *Fixed*, *Changed* and *Removed* would have been measured against a
  version no user ever ran. It is one `### Added` describing what Wega does, with `#### `
  subsections inside it. Every later section is an ordinary Keep a Changelog delta.
- **The `[0.2.0]` link reference points at its release page** (QA-06). A comparison link
  needs a previous tag, and `0.1.0` shipped untagged. `release.sh` preserves older links.

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

The counter has a second reader. Every build carries its own copy of the catalog, and a
client refuses a fetched catalog — and ignores an overlay already on disk — whose generation
is **lower than the one compiled into the running build**. A published generation must
therefore be at least the generation of the catalog in the released app, or the publication
has no effect on anyone running it. In practice this is automatic: the same `--bump` that
raised the file is what the next release ships. If this is ever violated — a build ships with
generation N while the CDN still serves N-1 — every client on that build shows the "Serwer
podał starszy katalog niż zainstalowany" state until a catalog at generation ≥ N is published.

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
