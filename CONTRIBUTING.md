# Contributing to Wega Mac Updater

Thanks for your interest in improving Wega. This guide covers how to build, test and
submit changes — and, importantly, the **one CI gate that trips up first-time
contributors**: the catalog signature check. Read [The catalog signature gate](#the-catalog-signature-gate)
before you touch `app-catalog.json`.

If you are a **user** looking for how to install and use the app, see the
[User Guide](USER_GUIDE.md) instead. To report a **security vulnerability**, follow
[`SECURITY.md`](SECURITY.md) — please do not open a public issue for that.

## Prerequisites

- **macOS 26 (Tahoe) or newer** and **Xcode 26 / Swift 6.0**.
  A Command Line Tools–only toolchain is not enough: SwiftLint needs a SourceKit that
  only the full Xcode provides, so `./scripts/check.sh` refuses to run without it.
  Point `xcode-select` at Xcode, not CommandLineTools:

  ```bash
  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
  ```
- **[SwiftLint](https://github.com/realm/SwiftLint)** — `brew install swiftlint` locally. CI pins **0.65.0** (`SWIFTLINT_VERSION` in `.github/workflows/build.yml`); if `--strict` disagrees between your machine and CI, match that version.
- **Homebrew** and **`mas`** are optional at build time but useful for exercising the app.

## Build and test

```bash
swift build                 # compile app + helper + core
swift test                  # run the full unit-test suite
swiftlint lint --strict     # zero violations (warnings fail too)
```

Before opening a pull request, run the full local quality gate — it is exactly what CI
enforces, plus the pure-bash guard tests:

```bash
./scripts/check.sh
```

`scripts/check.sh` runs, in order: the `sign-catalog.sh` in-repo-key guard, the `merge.sh`
guard-rail tests, the source-path guard, the `clean.sh` guard, the artifact-gate guard
(`verify-bundle.sh` still recognises a Developer ID, and therefore still enforces
notarization), then `swift build`, `swift test` and `swiftlint lint --strict`. If your machine has no full Xcode toolchain,
`check.sh` stops early and tells you so — push the branch and let CI run the
build/test/lint jobs.

The source-path guard is the one that needs explaining: `swift build`, `swift test` and
SwiftLint only ever look at Swift code, so a shell script or a CI workflow that reads a
source file *by path* is invisible to all three. Moving that file between modules then
leaves a dangling reference the whole gate still reports as green — which is exactly how
packaging broke once a module boundary moved. The guard checks that every
`Sources/**.swift` path hard-coded in `scripts/` or `.github/` still resolves.

### Test framework

**New tests are written in Swift Testing** (`@Test` / `@Suite`). The suite currently holds
both frameworks, and the migration is incremental: move an XCTest file over when you are
already changing it, never as a separate sweep.

XCTest stays where its features have no Swift Testing equivalent — `XCTWaiter` and the
tests that spawn and wait on a real process, for example
`Tests/MacUpdaterUITests/ScanControlLayoutTests.swift`. Those are a deliberate exception,
not leftovers, so do not "finish the migration" by rewriting them.

## Making a change

- **Branch** from the latest `main` and keep the change focused.
- **Commits** follow [Conventional Commits](https://www.conventionalcommits.org/) —
  `feat:`, `fix:`, `refactor:`, `docs:`, `test:`, `chore:` — matching the existing
  history and the `CHANGELOG.md` convention.
- **Changelog**: add user-visible changes under the `[Unreleased]` section of
  [`CHANGELOG.md`](CHANGELOG.md).
- **Version**: never hard-code a version string, and never bump it by hand. The version
  lives in exactly one place, `AppMetadata.version`
  (`Sources/WegaHelperKit/AppMetadata.swift`); the release workflow refuses a tag that
  disagrees with it. Releases are cut with `./scripts/release.sh` — see
  [`RELEASING.md`](RELEASING.md).
- **Tests**: cover new behaviour. Coverage is measured on the `MacUpdaterCore` library,
  and SonarCloud's gate expects ≥ 80% coverage on new code there. Keep logic testable by
  putting it in Core (pure, no SwiftUI) rather than in the View layer.
- **User-facing strings**: Wega is bilingual. Every `tr("…")` / `trf("…")` /
  `trp("…")` key you add must have an English counterpart in `Translations.en`
  (`Sources/MacUpdaterCore/Translations.swift`). `LocalizationCompletenessTests` scans the
  app sources and **fails the build** if any key lacks an English translation — a missing
  translation is a compile-gate error, not a silent Polish fallback.
- **Never commit secrets.** `*.pem` files are git-ignored; the Ed25519 catalog signing
  key must live outside the repository (see below).

## Continuous integration

Every pull request to `main` runs the jobs defined in the **reusable workflow** [`.github/workflows/build.yml`](.github/workflows/build.yml), invoked by [`.github/workflows/ci.yml`](.github/workflows/ci.yml). The release pipeline (`release.yml`) `uses:` the same reusable workflow, on the same `macos-26` runner and pinned Xcode 26 / SwiftLint 0.65.0 toolchain, so CI and release can never drift:

| Job | What it checks |
| --- | --- |
| **Build & Test** | `swift build --build-tests` + `swift test`, with coverage |
| **SwiftLint** | `swiftlint lint --strict` (warnings fail), pinned SwiftLint 0.65.0 |
| **Package** | `scripts/build-pkg.sh` builds a universal `.pkg`, then `scripts/verify-bundle.sh` gates bundle layout, helper signature and required resources (notarization/stapling on signed release builds) |
| **Catalog signature** | verifies `app-catalog.json.sig` matches `app-catalog.json` — see below |
| **SonarCloud** | static analysis + coverage gate (skipped until `SONAR_TOKEN` is set); defined in `ci.yml` |

## The catalog signature gate

**This is the gate that will fail a first-time contributor who edits the app catalog —
and it is working as designed.** Here is why, and what to do about it.

### What the catalog is

`Sources/MacUpdaterCore/Resources/app-catalog.json` maps each supported app to how Wega
updates it (GitHub repos, JetBrains IDE codes, Synology identifiers, Sparkle feed
overrides…). Wega can refresh this catalog **over the air** without shipping a new
build, by fetching a newer `app-catalog.json` from `raw.githubusercontent`. To stop a
tampered catalog from redirecting update sources, the catalog ships with a **detached
Ed25519 signature**, `app-catalog.json.sig`, and the app verifies the signature before
trusting an overlay (`CatalogSignature`, fail-closed).

`raw.githubusercontent` caches the JSON and the `.sig` as **two separate entries**, so a
client could otherwise fetch a fresh catalog next to a stale signature. The only place
their consistency can be enforced is the commit — which is what the CI gate does.

### What the gate does

The **Catalog signature** job (the `catalog-signature:` job in the reusable
`.github/workflows/build.yml`) runs on every push and pull request. It:

1. runs `scripts/test-sign-catalog-guard.sh` — a regression test proving
   `sign-catalog.sh` refuses a private key that lives inside the repository (SEC-06); and
2. runs `scripts/verify-catalog.sh`, which checks that `app-catalog.json.sig` verifies
   against `app-catalog.json` using the **public** key committed in
   `Sources/MacUpdaterCore/Security/CatalogSignature.swift`.

Verification needs **no secret and no write access**: Ed25519 is deterministic, so
verifying with the public key proves exactly what re-signing would. The gate **goes red
the moment `app-catalog.json` changes without `app-catalog.json.sig` being regenerated to
match** (exit 1). It is skipped (exit 3, reported as a neutral notice) only while the
committed public key is still the `REPLACE_ED25519_PUBKEY` placeholder — i.e. before
signing has been configured for the project.

### Why your PR can't regenerate the signature

Regenerating `app-catalog.json.sig` requires the **private** signing key, and by policy
(SEC-06) that key never enters the repository — `scripts/sign-catalog.sh` refuses any key
that resolves to a path inside the working tree, and the maintainer keeps it outside the
repo (e.g. `~/.secrets/wega-catalog.pem`). **Only a maintainer can produce a valid
signature.** So if your pull request edits `app-catalog.json`, the **Catalog signature**
gate will fail on your branch — not because your change is wrong, but because the
matching signature can only be regenerated by someone holding the maintainer's key. This
is expected; it is not a defect in your PR.

### How to contribute a catalog change

Pick whichever fits:

1. **Ask for the app to be added (no CI friction).** Open an issue requesting the
   catalog entry. Wega even builds this for you: in the **Inventory** window, an app Wega
   has no known way to update shows a **report button** that opens a pre-filled
   "add update support" issue. A maintainer adds the entry and regenerates the signature
   in one commit.
2. **Open a pull request with the `app-catalog.json` change.** Expect the **Catalog
   signature** job to go red — say so in the PR description. A maintainer will regenerate
   `app-catalog.json.sig` with `scripts/sign-catalog.sh` and commit it **together with**
   your catalog change (the JSON and its `.sig` must land in a single commit) before the
   branch merges. Do not attempt to hand-edit or fake the `.sig`.

### For maintainers

Re-sign after editing the catalog, and commit both files together:

```bash
WEGA_CATALOG_KEY=~/.secrets/wega-catalog.pem ./scripts/sign-catalog.sh
```

```bash
./scripts/verify-catalog.sh
```

```bash
git add Sources/MacUpdaterCore/Resources/app-catalog.json Sources/MacUpdaterCore/Resources/app-catalog.json.sig
```

### The envelope: one document instead of two (SEC-07)

The two-file layout has a flaw no amount of care at signing time removes — the JSON and
the `.sig` are separate CDN entries, so a client can still fetch a fresh catalog beside a
cached signature and see a mismatch that is indistinguishable from tampering. The
**envelope** carries the payload and its signature in one document, and one document
cannot skew against itself:

```json
{ "wegaCatalogEnvelope": 1, "payload": "<base64 of the catalog JSON>", "signature": "<base64 Ed25519 over those bytes>" }
```

The envelope's own fields are untrusted. Everything a decision rests on — `schemaVersion`
and the monotonic `generation` that makes a replay detectable — lives **inside** the
payload, which is exactly what the signature covers.

Wega reads both formats, so the switch is one command whenever you choose to make it:

```bash
WEGA_CATALOG_KEY=~/.secrets/wega-catalog.pem ./scripts/sign-catalog.sh --envelope
```

That rewrites `app-catalog.json` as an envelope and deletes the now-meaningless `.sig`.
To edit the catalog by hand again, unwrap it first (no key needed), edit, then re-sign:

```bash
./scripts/sign-catalog.sh --unwrap
```

Bump `"generation"` in the catalog on every publication. Wega remembers the highest
generation it has accepted and refuses anything lower, which is what stops an old but
perfectly-signed catalog from being replayed at a client forever. `verify-catalog.sh`
checks either format, and `scripts/test-catalog-envelope-guard.sh` (part of `check.sh`
and CI) proves the signature covers the payload rather than the wrapper.

## Integrating a branch

Merges into `main` go through `./scripts/merge.sh <branch> "<merge message>"`, which
fetches `origin/main`, rehearses the merge, runs the quality gate on the merged result,
and only then completes the `--no-ff` merge. See the "Integrating a feature branch"
section of [`README.md`](README.md) for details.
