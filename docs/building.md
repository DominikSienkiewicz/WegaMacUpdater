# Building and testing

Requirements, build commands, CI gates and the single source of truth for the version. Shipping a build is in [distribution.md](distribution.md).

## Requirements

- macOS 26 (Tahoe) or newer
- Xcode 26 — the full app, not the Command Line Tools alone: SwiftLint needs a SourceKit
  that ships only with Xcode (`scripts/check.sh` stops early and says so when
  `xcode-select -p` points elsewhere)
- Optional: Homebrew at `/opt/homebrew/bin/brew` or `/usr/local/bin/brew` — without it Wega
  still checks the Mac App Store, npm and every vendor feed, and says so instead of failing
- Optional: `mas` at `/opt/homebrew/bin/mas` or `/usr/local/bin/mas` (App Store features degrade gracefully without it)

GUI apps do not inherit an interactive shell environment. Wega resolves all tool paths from fixed locations — no `.zshrc`, no `$PATH` dependency.

## Build and test

```bash
swift build               # compile all targets
swift test                # run all tests
./scripts/verify-catalog.sh   # verify the catalog's Ed25519 signature (no secret needed)
./scripts/sign-catalog.sh --unwrap   # unwrap the signed envelope into editable JSON (no secret needed)
WEGA_CATALOG_KEY=~/.secrets/wega-catalog.pem ./scripts/sign-catalog.sh --envelope --bump   # re-sign after editing the catalog
swift run WegaMacUpdater  # launch app
```

**The signing key must live outside the working tree.** `scripts/sign-catalog.sh` refuses — exit 2, before it touches OpenSSL — any private key that resolves to a path inside this repository: its root, any subdirectory, and any linked worktree, whether given as an absolute path, a relative one, a `~` path, or reached through a symlink in either direction. This repository is public, and `.gitignore` only stops an *accidental* `git add`; it does nothing against `git add -f`, an edited ignore rule, or a backup of the folder — any one of which discloses a production key and forces a rotation of the OTA catalog signature for every installation. Keep the key in `~/.secrets/wega-catalog.pem` (`chmod 700` the directory, `600` the file) and point at it with `WEGA_CATALOG_KEY`. `scripts/test-sign-catalog-guard.sh` is the regression test for that refusal; it runs in `scripts/check.sh` and in CI, and only ever uses dummy key files.

**Integrating a feature branch** goes through `./scripts/merge.sh <branch> "<merge message>"`, run from anywhere in the repo. It fetches `origin/main` and stops if the local one is behind, rehearses the merge with `git merge-tree` so a conflicting branch is reported *before* `main` is touched, names any untracked file the merge would overwrite instead of aborting halfway through, and only then merges with `--no-ff`. The quality gate runs on the **merged** result, and the branch and its worktree are deleted only once it is green — a red gate leaves both in place to fix and prints the `git reset --hard ORIG_HEAD` undo rather than performing it. `--no-verify` skips the gate (for a machine without a full Xcode toolchain; CI still runs it), `--force` discards local changes when removing the worktree. `scripts/test-merge.sh` covers those refusals in throwaway repositories and runs inside `scripts/check.sh`.

The repository intentionally has no root `clean.sh`: the former file was a completed
one-shot code generator whose misleading name hid source overwrites, `git add -A`, a
direct commit to `main`, and optional worktree/branch deletion. Use the narrowly named
scripts under `scripts/` for maintenance. `scripts/test-clean-script-guard.sh` prevents
that destructive entry point from returning and runs inside `scripts/check.sh`.

The package targets the **Swift 6 language mode** (`swift-tools-version: 6.0`), so the whole codebase compiles under strict concurrency checking. CI and the release pipeline share **one reusable workflow** (`.github/workflows/build.yml`, `on: workflow_call`) so they can never drift: the same `macos-26` runner and the same **pinned toolchain** — Xcode 26 and SwiftLint 0.65.0, never `latest-stable` or `brew install swiftlint`, because a floating toolchain would break the `--strict` lint gate the day a new rule ships, on a toolchain no commit ever chose. Every push and pull request to `main` (`.github/workflows/ci.yml`) invokes it, running these jobs (the Catalog signature and SonarCloud jobs run on `ubuntu-latest`):

- **Build & Test** — `swift build --build-tests` + `swift test`, both with `--enable-code-coverage`. `scripts/coverage-sonarqube.sh` then converts SwiftPM's llvm-cov output into a SonarQube generic coverage report (`sonarqube-generic-coverage.xml`) that is uploaded as an artifact for the SonarCloud job (which runs on Linux and can't run the macOS tests itself).
- **SwiftLint** — `swiftlint lint --strict` against `.swiftlint.yml` (warnings fail the job). The config keeps the high-signal correctness rules and metric guardrails while disabling the purely-cosmetic rules that conflict with the codebase's house style, so it gates regressions without reformatting.
- **Package** — runs `scripts/build-pkg.sh` to prove the whole packaging path composes, then runs `scripts/verify-bundle.sh` — the **same artifact gate the release uses** — over the built `.app`: bundle layout, a **universal** binary (arm64 + x86_64), a valid helper/app signature, and that both `app-catalog.json` and `endpoints.json` are bundled (the latter is required at launch — `AppEndpoints.shared` fatal-errors without it). On the ad-hoc-signed CI build the notarization and stapling checks are reported as skipped. It then uploads the resulting `.pkg` as an artifact.
- **Catalog signature** — `scripts/verify-catalog.sh` checks the catalog's Ed25519 signature against the public key already committed in `CatalogSignature.swift`. It accepts either shape: the **signed envelope**, which carries payload and signature in one document and is what this repository publishes today (the signature is verified over the exact payload bytes the app decodes), or the legacy **detached pair**, a flat `app-catalog.json` next to `app-catalog.json.sig`. **No secret and no write access**: Ed25519 is deterministic, so verifying proves exactly what re-signing would, without ever handing CI the private key. The envelope exists precisely because `raw.githubusercontent` serves a detached pair as two separate cache entries that can skew, leaving the commit as the only place their consistency can be enforced. Either way, this gate goes red the moment the catalog changes without its signature being regenerated. Skipped (exit 3) while the key is still the placeholder.
- **SonarCloud** — runs the SonarQube/SonarCloud scanner against `sonar-project.properties` (after **Build & Test**, whose coverage report it downloads and feeds via `sonar.coverageReportPaths`). Skipped until a `SONAR_TOKEN` secret is configured, so it never blocks CI before setup. Outbound URLs are sourced from `endpoints.json` via `AppEndpoints`, so `S1075` ("hard-coded URI") only fires on genuinely configurable endpoints; tests and the fixed-system-path files are excluded in the properties file. Coverage is measured on `MacUpdaterCore` **and** the reachable parts of the `WegaMacUpdater` app: the `MacUpdaterUITests` bundle depends on the app target and `@testable import`s it, so the app's orchestrators (`ScanStore`, `BackgroundUpdater`, `MenuBarAgent`, the `*Store`/`*Controller`/`*Coordinator` types) and the I/O services with a tested pure core are all counted. `sonar.coverage.exclusions` is deliberately narrow — only files with no unit-testable branch logic (the SwiftUI `View`/`Scene`/`App`/`Commands` layer, the constant-only `SystemPaths.swift`, and the XPC/root/network glue whose decisions live in Core) are excluded (the gate requires ≥ 80% coverage on new code).

`scripts/build-pkg.sh` builds a universal binary by default (override with `ARCHS="arm64"`) and copies the SPM resource bundle (`app-catalog.json`) into the `.app`, so `Bundle.module` resolves at runtime.

Open `Package.swift` directly in Xcode for the full IDE experience. No Xcode project or provisioning profile is needed for signing: `scripts/build-pkg.sh` signs the hand-rolled bundle with `codesign` (hardened runtime + timestamp, inside-out: authorization components and privileged helper first, then the app) when given Developer ID identities as arguments — see [Cutting a release](distribution.md#cutting-a-release).

### Version — single source of truth

The app version lives in exactly one place: `AppMetadata.version` (`Sources/WegaHelperKit/AppMetadata.swift`). The running app reads it (falling back to it when no bundle `Info.plist` is present, e.g. under `swift run`), and `scripts/build-pkg.sh` extracts it from there when stamping the generated `Info.plist` and the `.pkg` — so bumping the version is a one-line edit. The release workflow **enforces** this: a tag `vX.Y.Z` whose version doesn't equal `AppMetadata.version` fails the build before anything is published.
