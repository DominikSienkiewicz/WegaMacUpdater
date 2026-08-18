# Distribution

Cutting a release and how the app updates itself. Building it first is in [building.md](building.md).

## Distribution

Intended channel: Developer ID, outside the Mac App Store.

- **Developer ID Application** signing for the `.app` (and nested privileged helper) + `.dmg`
- **Developer ID Installer** signing for the `.pkg` — a distinct certificate type; `pkgbuild` refuses Application certs
- Hardened Runtime
- Notarization
- DMG placing `WegaMacUpdater.app` in `/Applications` (the name `scripts/build-pkg.sh` builds)

The Team ID is pinned in code (`WegaHelper.teamIdentifier`) — XPC peer pinning and
self-update verification only trust binaries signed by that team, so release signing
**must** use certificates from the same Apple Developer team.

### Cutting a release

`scripts/build-pkg.sh` builds a universal, ad-hoc-or-signed `.pkg` **and** a drag-to-Applications `.dmg`. Pushing a version tag drives the rest, and `scripts/release.sh` is what creates that tag — in two phases, with a review gate in between:

```bash
./scripts/release.sh patch      # prepare: bump AppMetadata.version, draft notes, stage
# review CHANGELOG.md, edit until the notes read well
./scripts/release.sh --continue # finalise: commit + annotated tag
git push origin main --follow-tags
```

Never edit `AppMetadata.version` or move the `[Unreleased]` entries by hand — the script owns
both, and the workflow refuses any tag that disagrees with the version. The full procedure,
the signing secrets and the first-release case (**the project has no tags yet**, so the first
release is cut from `[Unreleased]` alone and its version must be higher than `0.1.0`) are in
**[RELEASING.md](../RELEASING.md)**.

`.github/workflows/release.yml` (on `push: tags: v*`) first runs the **same reusable quality workflow CI runs** — build, test, lint, catalog verification, packaging and the bundle gate, on the same pinned `macos-26`/Xcode 26 toolchain. The publishing job `needs:` it, so a release can never be built on a different toolchain than CI proved green, nor published ahead of the quality gates. It then verifies tag == `AppMetadata.version`, builds the artifacts, notarizes and staples them, and runs `scripts/verify-bundle.sh` over the result — bundle layout, helper signature, notarization, stapling and required resources — as a final gate before it publishes a GitHub Release with the `.pkg` + `.dmg`. **Signing and notarization are optional and activate automatically once the secrets exist** — until then the job still publishes *unsigned* artifacts so the pipeline is verifiable end-to-end without an Apple Developer account (the **Preflight** step in each run prints which signing/notary secrets are configured).

Secrets (all optional):

| Secret | Purpose |
| --- | --- |
| `DEVELOPER_ID_IDENTITY` | `"Developer ID Application: Name (TEAMID)"` — signs `.app`, helper, `.dmg` |
| `DEVELOPER_ID_INSTALLER_IDENTITY` | `"Developer ID Installer: Name (TEAMID)"` — signs the `.pkg` (distinct cert type; without it the `.pkg` ships unsigned and is skipped by notarization) |
| `DEVELOPER_ID_CERT_P12` | base64 of a `.p12` exported from Keychain — export **both** identities (Application + Installer) into this one file |
| `DEVELOPER_ID_CERT_PASSWORD` | password of the `.p12` |
| `KEYCHAIN_PASSWORD` | any throwaway password for the CI temp keychain |
| `AC_API_KEY_ID` / `AC_API_ISSUER_ID` / `AC_API_KEY_P8` | App Store Connect API key (role *Developer*) for `notarytool`; `AC_API_KEY_P8` is the full `.p8` file contents |

### Self-update

Wega updates **itself** by dogfooding the same machinery it uses for everyone else. `WegaSelfUpdateChecker` (MacUpdaterCore) asks the GitHub Releases API for the latest tag, compares it against `AppMetadata.version` with the shared `VersionComparison` logic, and reports **every** published asset rather than picking one; `SelfUpdatePlanner` then makes the single install-vs-open decision. The **artifact** is chosen on security grounds and never from capability: the `.pkg` always wins, the `.dmg` is the fallback for releases that ship no package, and anything else is refused outright — the `.pkg` is the only channel Wega can pin end to end (a Gatekeeper *install* assessment **plus** the Developer Team ID read from the package signature), whereas a `.dmg` is validated by Gatekeeper alone, which attests "notarized by *some* Apple developer", not "published by Wega" (SEC-04). What the privileged helper decides is only *how* that artifact is applied — headless install when it is enabled, otherwise the same file handed to the user to finish. The **Settings window** surfaces the full install flow through `SelfUpdateController`: it auto-checks once when the window opens (ETag-conditional, so revisits are free) and offers a manual re-check; when a newer release exists, it shows the version and a button honestly labeled for the chosen path — "Pobierz i zainstaluj" for a headless helper install, "Pobierz i otwórz instalator" when the user must finish it by hand — that downloads the asset, verifies its code signature against the pinned release-signing team ID before anything touches it, and fails closed (payload deleted, release page opened instead) the moment that verification misses; plus the cumulative release notes for every version between the installed one and the newest — each collapsible, capped at 10 with any omitted releases counted rather than dropped silently — and a link to see the release itself on GitHub. A completed headless install ends in an explicit *installed, restart to use it* state with a restart button that stays disabled while any mutating operation holds the write gate — nothing restarts the app on its own. No embedded framework, no appcast to host. (Sparkle-style silent background updates remain a possible later upgrade; the runtime cost — embedding the framework in the hand-rolled bundle, EdDSA-signed appcast hosting — isn't worth it for a tool you open deliberately.)

**One count, everywhere applies to Wega too (UX-15).** The self-update no longer hides in Settings: `ManualUpdateScanner` runs the same check on every background and window scan and folds an available release into its results as an ordinary `ManualOutdatedApp` (a `.wega` update source). So a pending Wega update is **counted in the badge, named in the background notification, and listed as a "Wega" row under "Ręcznie zainstalowane" in the Updates window** — exactly like any other manually-updated app. Its row action opens **Settings**, where the in-app installer lives — download, signature verification, headless helper install and the gated restart — rather than opening the release page in a browser and stepping around all of it; the row still carries the version arrow, release notes and the security-fix badge like every vendor row.

The privileged helper — shipped, not planned — lives inside the bundle at `Contents/Library/LaunchDaemons` and registers via `SMAppService.daemon(plistName:)`.
