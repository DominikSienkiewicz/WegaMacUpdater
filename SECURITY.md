# Security Policy

Wega Mac Updater installs and upgrades software on your Mac and carries several
security-sensitive components — a signed over-the-air catalog, a privileged
`sudo`/askpass path, publisher (Team ID) pinning and rollback machinery. We take
reports about any of these seriously and want them to reach us **privately**, before
they are public.

## Reporting a vulnerability

**Please do not report security vulnerabilities through public GitHub issues,
discussions, or pull requests.** A public issue tells everyone about the weakness
before there is a fix.

Instead, report privately through GitHub's built-in private vulnerability reporting:

1. Go to the repository's **Security** tab:
   <https://github.com/DominikSienkiewicz/WegaMacUpdater/security/advisories/new>
2. Click **Report a vulnerability** and fill in the advisory form.

This opens a private security advisory visible only to you and the maintainers. It
never appears in the public issue tracker.

> If the "Report a vulnerability" button is not visible, private reporting has not been
> enabled yet. Maintainers: turn it on in the repository's **Settings → Code security**
> section, under **Private vulnerability reporting**. Until then, contact the maintainer
> privately via the profile linked in [`README.md`](README.md) rather than filing a
> public issue.

## What to include

A good report lets us reproduce and fix the issue quickly. Where you can, include:

- The affected version (Settings window → app version/build, or the release tag).
- macOS version and CPU architecture (Apple Silicon / Intel).
- A description of the vulnerability and its impact (what an attacker could do).
- Step-by-step reproduction, or a proof of concept.
- Any relevant logs (`~/Library/Logs/WegaMacUpdater/wega.log`) with secrets redacted.

## In scope

Security-relevant areas most worth a look include:

- **Catalog signing / OTA overlay** — the Ed25519-signed `app-catalog.json` overlay and
  the signature-verification path (`CatalogSignature`, `CatalogRefresher`,
  `ConfigOverlayTrust`). Signature bypasses or fail-open behaviour are high value.
- **Privileged execution** — the compiled askpass and `sudo` shim, their path/signature
  validation (`AuthorizationComponentResolver`, `AuthorizationEnvironment`), the Touch ID
  `sudo_local` writer, and the XPC helper. Installation status is recorded in a root-owned
  registry; losing XPC does not stop the installer or authorize a second installation.
  The client retains its mutation block until a matching terminal result is confirmed.
  The helper and the app pin each other with code requirements that demand a Developer ID
  signature (the intermediate and leaf certificate markers, besides the Team ID and the
  identifier), and `scripts/verify-bundle.sh` checks a signed release against both. Each verb
  has its own minimum protocol version. The helper exits after 60 seconds with no connection
  and no work, and launchd starts it again from the current app bundle.
  Because launchd runs the helper as root from that bundle, Wega neither registers nor uses it
  unless the app runs directly from `/Applications` and every entry launchd runs the helper from
  (the bundle, `Contents`, `Contents/MacOS`, the helper, `Contents/Library`,
  `Contents/Library/LaunchDaemons`, the launchd plist) belongs to root, is not a link and cannot be
  written by its group, by others or through an ACL (`HelperBundleGate`, read through descriptors).
  The `.pkg` installs it so; a drag-installed bundle belongs to the user, who could swap the helper
  for another binary. The helper checks the bundle it was started from and refuses every
  connection when that check fails, and from protocol 9 every acting verb needs such a helper. A
  registration left from a refused copy is removed at launch when no copy LaunchServices knows
  passes the check, and the package build verifies that its payload passes it. Known limits:
  `/Applications` is writable by the `admin` group, so code running as an administrator — on most
  Macs, the user — can still rename the bundle and put another in its place; what launchd runs is
  decided by the job's launch constraint (a cdhash list that macOS may repair after an update),
  and nothing in the app stops launchd from starting an older genuine helper from another copy of
  Wega, only Wega from using it. Turning Touch ID on or
  off needs an administrator at the console and refuses an unsafe `/etc/pam.d` or `sudo_local`
  (and, when turning it on with no `sudo_local`, an unsafe `sudo_local.template`) instead of
  rewriting it. When the policy `sudo` reads is unsafe
  (`sudo_local` or `/etc/pam.d` writable by someone other than root, `sudo_local` not a regular
  file, `/etc/pam.d/sudo` unsafe) or cannot be proven safe, the Touch ID card offers no
  command and no button and advises recoveryOS only; the manual enable and disable commands run
  through `/usr/bin/sudo` and re-check the file when they run.
- **Publisher pinning & rollback** — Team ID baseline checks and the
  snapshot → canary → auto-rollback chain that guards cask upgrades.
- **Self-update identity** — package publisher, product identifier, promised version and
  signed app payload are checked before installation; the payload needs a Developer ID
  signature that holds in every architecture and in its nested code. The helper repeats verification on
  its private staged copy; success and recovery require the expected signed app on disk.
- **Update/action execution** — anywhere Wega decides *what* to run against Homebrew,
  `mas`, npm, or an app's own updater.

Out of scope: vulnerabilities in Homebrew, `mas`, npm, or third-party apps themselves —
please report those to their respective projects. Social-engineering and issues that
require a compromised Mac or a privileged local attacker to already be present are
generally low priority.

## Our commitment

- We aim to acknowledge a report within a few business days.
- We will keep you updated as we investigate and work on a fix.
- We follow coordinated disclosure: we would like to agree on a disclosure timeline
  with you, and we are happy to credit you in the release notes and the published
  advisory (or keep you anonymous — your choice).

## Supported versions

Wega Mac Updater is pre-1.0 and evolving quickly. Security fixes are made against the
latest release and `main`; there are no long-term maintenance branches yet. Always run
the newest release from the
[Releases page](https://github.com/DominikSienkiewicz/WegaMacUpdater/releases) — the app
can also check and update itself from the **Settings** window.
