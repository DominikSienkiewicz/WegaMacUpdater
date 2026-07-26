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
  A Command Line Tools–only toolchain is not enough: building requires the full Xcode
  (it needs the `FoundationModelsMacros` plugin and the SourceKit that SwiftLint loads).
  Point `xcode-select` at Xcode, not CommandLineTools:

  ```bash
  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
  ```
- **[SwiftLint](https://github.com/realm/SwiftLint)** — `brew install swiftlint`.
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
guard-rail tests, the `clean.sh` guard, then `swift build`, `swift test` and
`swiftlint lint --strict`. If your machine has no full Xcode toolchain, `check.sh` stops
early and tells you so — push the branch and let CI run the build/test/lint jobs.

## Making a change

- **Branch** from the latest `main` and keep the change focused.
- **Commits** follow [Conventional Commits](https://www.conventionalcommits.org/) —
  `feat:`, `fix:`, `refactor:`, `docs:`, `test:`, `chore:` — matching the existing
  history and the `CHANGELOG.md` convention.
- **Changelog**: add user-visible changes under the `[Unreleased]` section of
  [`CHANGELOG.md`](CHANGELOG.md).
- **Version**: never hard-code a version string. The version lives in exactly one place,
  `AppMetadata.version` (`Sources/MacUpdaterCore/AppMetadata.swift`); the release
  workflow refuses a tag that disagrees with it.
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

Every pull request to `main` runs the jobs in [`.github/workflows/ci.yml`](.github/workflows/ci.yml):

| Job | What it checks |
| --- | --- |
| **Build & Test** | `swift build --build-tests` + `swift test`, with coverage |
| **SwiftLint** | `swiftlint lint --strict` (warnings fail) |
| **Package** | `scripts/build-pkg.sh` builds a universal `.pkg`; asserts bundled resources |
| **Catalog signature** | verifies `app-catalog.json.sig` matches `app-catalog.json` — see below |
| **SonarCloud** | static analysis + coverage gate (skipped until `SONAR_TOKEN` is set) |

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

The **Catalog signature** job (`.github/workflows/ci.yml`, the `catalog-signature:` job
at line 56) runs on every push and pull request. It:

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
./scripts/verify-catalog.sh          # confirm it matches (no secret needed)
git add Sources/MacUpdaterCore/Resources/app-catalog.json \
        Sources/MacUpdaterCore/Resources/app-catalog.json.sig
```

## Integrating a branch

Merges into `main` go through `./scripts/merge.sh <branch> "<merge message>"`, which
fetches `origin/main`, rehearses the merge, runs the quality gate on the merged result,
and only then completes the `--no-ff` merge. See the "Integrating a feature branch"
section of [`README.md`](README.md) for details.
