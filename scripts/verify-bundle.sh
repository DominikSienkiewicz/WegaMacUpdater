#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# verify-bundle.sh — release artifact gate (QA-03).
#
# `swift test` proves the code; it says nothing about the thing users install. This gate
# inspects the built .app (and optional .pkg/.dmg) and refuses to let a release proceed unless:
#
#   1. bundle layout      — every executable, plist and resource the app needs at launch,
#   2. required resources  — app-catalog.json + endpoints.json (a missing endpoints.json
#                            fatal-errors AppEndpoints.shared at launch — it must fail here),
#   3. universal binary    — the architectures build-pkg.sh was asked to produce,
#   4. helper signature    — the app and the privileged helper carry a valid signature,
#   5. notarization+staple — when a Developer ID is configured, artifacts are notarized and the
#                            ticket is stapled (spctl accepts them offline),
#   6. publisher pin       — the signature belongs to WEGA's Team ID, not merely to *an* Apple
#                            developer (SEC-04: notarization proves "some developer", never
#                            "this one"),
#   7. XPC requirements    — with a Developer ID, the app satisfies the requirement the helper
#                            demands of every client and the helper the one the app demands of
#                            it (RC2-4), so a release can never cut its users off the helper.
#   8. Wega's own code     — with a Developer ID, every file the app checks as its own code
#                            (the app, askpass, the sudo shim, the .dmg, and the app and the
#                            authorization copies in the .pkg) passes that check: the requirement
#                            the app builds for it, in every architecture and nested program.
#                            Every user's self-update would refuse a release that fails it.
#
# Signing is OPTIONAL for LOCAL/TEST builds: ad-hoc/unsigned dev builds pass 1–4 and report
# steps 5–8 as skipped (like verify-catalog.sh's "not configured" exit).
#
# For a STABLE RELEASE it is not optional. `REQUIRE_SIGNED=1` turns the skips into failures:
# the artifacts must be Developer-ID-signed, notarized, stapled and carry the expected Team ID
# before anything may be published as a stable release (SEC-04 / QA-03).
#
# Usage:
#   ./scripts/verify-bundle.sh [APP_BUNDLE] [ARTIFACT ...]
#     APP_BUNDLE   default .build/pkg-staging/WegaMacUpdater.app
#     ARTIFACT     zero or more .pkg/.dmg to validate for notarization + stapling
#
# Env:
#   ARCHS             architectures build-pkg.sh produced (default "arm64 x86_64"); kept in sync
#                     so a single-arch local build (ARCHS="arm64") is validated against what it
#                     actually built.
#   REQUIRE_SIGNED    1/true ⇒ fail-closed release mode (see above). Default: off.
#   EXPECTED_TEAM_ID  Team ID the signature must carry. Defaults to the single source of truth,
#                     `WegaHelper.teamIdentifier` in
#                     Sources/WegaHelperKit/WegaHelperProtocol.swift — the same constant the app
#                     pins its self-update against, so the gate and the client can never drift.
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

APP_NAME="WegaMacUpdater"
APP_BUNDLE="${1:-.build/pkg-staging/$APP_NAME.app}"
shift || true
ARTIFACTS=("$@")
read -r -a EXPECTED_ARCHS <<< "${ARCHS:-arm64 x86_64}"

CONTENTS="$APP_BUNDLE/Contents"
fail=0

case "${REQUIRE_SIGNED:-0}" in
    1|true|TRUE|yes) REQUIRE_SIGNED=1 ;;
    *)               REQUIRE_SIGNED=0 ;;
esac

TEAM_ID_SOURCE="Sources/WegaHelperKit/WegaHelperProtocol.swift"
EXPECTED_TEAM_ID="${EXPECTED_TEAM_ID:-$(sed -n 's/.*static let teamIdentifier = "\(.*\)".*/\1/p' "$TEAM_ID_SOURCE")}"

# The code requirements the app and the helper pin each other with over XPC: exactly what
# `WegaHelper.clientRequirement()` and `WegaHelper.helperRequirement()` in $TEAM_ID_SOURCE
# return (PrivilegedHelperSecurityTests pins both lines). Literals, so the gate never has to
# compile Swift to learn them.
CLIENT_REQUIREMENT='anchor apple generic and identifier "com.wega.WegaMacUpdater" and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = "6B8FYSZFJK"'
HELPER_REQUIREMENT='anchor apple generic and identifier "com.wega.WegaMacUpdater.helper" and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = "6B8FYSZFJK"'

# What `CodeSignatureVerifier.teamIDRequirement(teamID:bundleID:)` in
# Sources/WegaHelperKit/CodeSignatureVerifier.swift returns for the rest of Wega's own code: askpass
# and the sudo shim with `WegaHelper.askpassSigningID` / `sudoShimSigningID`, the disk image with no
# identifier (OwnCodeStrictSignatureTests pins these lines). For the app it returns
# CLIENT_REQUIREMENT.
ASKPASS_REQUIREMENT='anchor apple generic and identifier "com.wega.WegaMacUpdater.askpass" and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = "6B8FYSZFJK"'
SUDO_SHIM_REQUIREMENT='anchor apple generic and identifier "com.wega.WegaMacUpdater.sudo-shim" and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = "6B8FYSZFJK"'
DISK_IMAGE_REQUIREMENT='anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = "6B8FYSZFJK"'

note() { echo "::notice::$*"; }
bad()  { echo "  ✗ $*" >&2; fail=$((fail + 1)); }
ok()   { echo "  ✓ $*"; }

if [[ "$REQUIRE_SIGNED" -eq 1 ]]; then
    echo "→ Tryb wydania stabilnego (REQUIRE_SIGNED=1): podpis, notaryzacja, stapling i Team ID są WYMAGANE."
fi
if [[ -z "$EXPECTED_TEAM_ID" || "$EXPECTED_TEAM_ID" == "REPLACE_TEAMID" ]]; then
    echo "❌ Brak skonfigurowanego Team ID w $TEAM_ID_SOURCE — nie ma czego przypiąć." >&2
    exit 2
fi

if [[ ! -d "$APP_BUNDLE" ]]; then
    echo "❌ Nie znaleziono bundla: $APP_BUNDLE" >&2
    echo "   Zbuduj najpierw: ./scripts/build-pkg.sh" >&2
    exit 2
fi

echo "→ Weryfikuję bundle: $APP_BUNDLE"

# --- 1. Bundle layout ------------------------------------------------------
echo "→ 1. Layout bundla"
LAYOUT=(
    "Info.plist"
    "MacOS/$APP_NAME"
    "MacOS/WegaPrivilegedHelper"
    "Library/LaunchDaemons/com.wega.WegaMacUpdater.helper.plist"
    "Helpers/WegaAskpass"
    "Helpers/sudo-shim/sudo"
    "Resources/AppIcon.icns"
)
for rel in "${LAYOUT[@]}"; do
    if [[ -e "$CONTENTS/$rel" ]]; then
        ok "Contents/$rel"
    else
        bad "Contents/$rel (BRAK)"
    fi
done

# --- 2. Required resources -------------------------------------------------
echo "→ 2. Wymagane zasoby (app-catalog.json + endpoints.json)"
RES_BUNDLE="$CONTENTS/Resources/${APP_NAME}_MacUpdaterCore.bundle"
if [[ -d "$RES_BUNDLE" ]]; then
    ok "$(basename "$RES_BUNDLE")"
    for res in app-catalog.json endpoints.json; do
        if [[ -n "$(find "$RES_BUNDLE" -name "$res" 2>/dev/null)" ]]; then
            ok "$res"
        else
            bad "$res (BRAK w bundlu zasobów)"
        fi
    done
else
    bad "$(basename "$RES_BUNDLE") (BRAK — app-catalog.json/endpoints.json nie trafiłyby do .app)"
fi

# --- 3. Universal binary ---------------------------------------------------
echo "→ 3. Architektury binarki (${EXPECTED_ARCHS[*]})"
BIN="$CONTENTS/MacOS/$APP_NAME"
if [[ -f "$BIN" ]]; then
    ARCHS_PRESENT="$(lipo -archs "$BIN" 2>/dev/null || true)"
    ok "archs: $ARCHS_PRESENT"
    for arch in "${EXPECTED_ARCHS[@]}"; do
        if echo "$ARCHS_PRESENT" | grep -qw "$arch"; then
            ok "$arch"
        else
            bad "$arch (BRAK w binarce)"
        fi
    done
else
    bad "brak binarki $BIN"
fi

# --- 4. Helper (and app) signature -----------------------------------------
echo "→ 4. Podpis helpera i aplikacji"
HELPER="$CONTENTS/MacOS/WegaPrivilegedHelper"
for target in "$HELPER" "$APP_BUNDLE"; do
    label="$(basename "$target")"
    if codesign --verify --strict "$target" >/dev/null 2>&1; then
        ok "podpis OK: $label"
    else
        bad "codesign --verify nie przechodzi: $label"
    fi
done

# Developer ID present? Drives whether notarization + stapling are mandatory.
# Read the whole `codesign` output first, then match: piping it into `grep -q` under
# `set -o pipefail` reports a HIT as a miss — `grep -q` exits on the first match,
# `codesign` dies of SIGPIPE (141) and `pipefail` makes that the status of the pipe.
# That silently skipped step 5 for every signed build (see test-verify-bundle-guard.sh).
SIGNED_DEVELOPER_ID=0
CODESIGN_INFO="$(codesign -dvv "$APP_BUNDLE" 2>&1 || true)"
if [[ "$CODESIGN_INFO" == *"Authority=Developer ID Application"* ]]; then
    SIGNED_DEVELOPER_ID=1
    ok "tożsamość: Developer ID Application"
else
    if [[ "$REQUIRE_SIGNED" -eq 1 ]]; then
        bad "brak podpisu Developer ID — wydanie stabilne wymaga podpisanych artefaktów"
    else
        note "Aplikacja podpisana ad-hoc (bez Developer ID) — kroki notaryzacji/staplingu pominięte."
    fi
fi

# --- 5. Notarization + stapling --------------------------------------------
# The notarization ticket is stapled to the DISTRIBUTABLES (.pkg/.dmg), never to the
# standalone staging .app — so these checks run against the artifacts, not the bundle.
echo "→ 5. Notaryzacja + stapling"
if [[ "$SIGNED_DEVELOPER_ID" -ne 1 ]]; then
    note "Pominięto: notaryzacja i stapling wymagają Developer ID (ustaw sekrety wydania)."
elif [[ "${#ARTIFACTS[@]}" -eq 0 ]] && [[ "$REQUIRE_SIGNED" -eq 1 ]]; then
    bad "wydanie stabilne bez artefaktów .pkg/.dmg do walidacji notaryzacji i staplingu"
elif [[ "${#ARTIFACTS[@]}" -eq 0 ]]; then
    # Guarded: on macOS bash 3.2, "${arr[@]}" on an empty array under `set -u` aborts.
    note "Podano tylko .app (Developer ID) — brak .pkg/.dmg do walidacji notaryzacji/staplingu."
else
    for target in "${ARTIFACTS[@]}"; do
        [[ -e "$target" ]] || { bad "brak artefaktu $target"; continue; }
        label="$(basename "$target")"
        # `stapler validate` succeeds only when a valid notarization ticket is stapled —
        # so it proves both that the artifact was notarized and that the ticket is attached.
        if xcrun stapler validate "$target" >/dev/null 2>&1; then
            ok "notaryzacja + stapling OK: $label"
        else
            bad "brak przypiętego biletu notaryzacji (stapler validate): $label"
        fi
        # Extra offline Gatekeeper assessment for the installer package.
        case "$target" in
            *.pkg)
                if spctl --assess --type install "$target" >/dev/null 2>&1; then
                    ok "spctl akceptuje pakiet: $label"
                else
                    bad "spctl odrzuca pakiet (brak notaryzacji lub podpisu): $label"
                fi
                ;;
        esac
    done
fi

# --- 6. Publisher pin (SEC-04) ---------------------------------------------
# Notarization answers "signed by an Apple developer"; it never answers "signed by THIS
# one". Without this step a stable release could carry a perfectly notarized artifact from
# a foreign Team ID, and the app — which pins WegaHelper.teamIdentifier when it verifies a
# self-update — would refuse the very release we just published.
echo "→ 6. Team ID wydawcy (oczekiwano $EXPECTED_TEAM_ID)"

# A .pkg is signed by a "Developer ID Installer" certificate and is invisible to
# `codesign`; its Team ID lives in the parenthesised suffix of the pkgutil leaf line.
#
# Both branches read the tool's whole output into a variable first, then match. Piping
# straight into a reader that exits early (`grep -q`, `head -1`) kills the producer with
# SIGPIPE, and under `set -o pipefail` that turns a HIT into a miss — the exact fail-open
# this gate was already caught doing once (see test-verify-bundle-guard.sh). `sed -n 1p`
# consumes its input to the end, so it cannot repeat that.
team_id_of() {
    local target="$1" info=""
    case "$target" in
        *.pkg)
            info="$(pkgutil --check-signature "$target" 2>/dev/null || true)"
            printf '%s\n' "$info" | sed -n 's/.*(\([A-Z0-9]\{10\}\)).*/\1/p' | sed -n 1p
            ;;
        *)
            info="$(codesign -dvv "$target" 2>&1 || true)"
            printf '%s\n' "$info" | sed -n 's/^TeamIdentifier=//p' | sed -n 1p
            ;;
    esac
}

if [[ "$SIGNED_DEVELOPER_ID" -ne 1 ]]; then
    note "Pominięto: bez Developer ID nie ma Team ID do przypięcia."
else
    for target in "$APP_BUNDLE" ${ARTIFACTS[@]+"${ARTIFACTS[@]}"}; do
        [[ -e "$target" ]] || { bad "brak artefaktu $target"; continue; }
        label="$(basename "$target")"
        found="$(team_id_of "$target" || true)"
        if [[ -z "$found" ]]; then
            # Fail-closed on purpose: an unreadable pin is not a weaker pin, it is none.
            bad "nie odczytano Team ID: $label"
        elif [[ "$found" == "$EXPECTED_TEAM_ID" ]]; then
            ok "Team ID $found: $label"
        else
            bad "Team ID $found ≠ $EXPECTED_TEAM_ID: $label"
        fi
    done
fi

# --- 7. XPC code requirements (RC2-4) ---------------------------------------
# Unit tests run on ad-hoc builds, where `anchor apple generic` cannot hold, so they only prove
# that both requirements compile. Only the signed files can show that a v8 helper will accept
# the genuine app and that the app will trust the genuine helper; a slip in either string would
# break every helper verb for every user until they reinstall by hand.
# `-R "=…"`, never `-R="=…"`: codesign reads the latter as the text "=…" — a syntax error.
echo "→ 7. Wymagania XPC (aplikacja ↔ pomocnik)"
if [[ "$SIGNED_DEVELOPER_ID" -ne 1 ]]; then
    note "Pominięto: wymagania XPC da się sprawdzić tylko na podpisie Developer ID."
else
    if codesign --verify -R "=$CLIENT_REQUIREMENT" "$APP_BUNDLE" >/dev/null 2>&1; then
        ok "wymaganie XPC spełnione: $(basename "$APP_BUNDLE")"
    else
        bad "nie spełnia wymagania XPC clientRequirement() — pomocnik odrzuci jej połączenia: $(basename "$APP_BUNDLE")"
    fi
    if codesign --verify -R "=$HELPER_REQUIREMENT" "$HELPER" >/dev/null 2>&1; then
        ok "wymaganie XPC spełnione: $(basename "$HELPER")"
    else
        bad "nie spełnia wymagania XPC helperRequirement() — aplikacja mu nie zaufa: $(basename "$HELPER")"
    fi
fi

# --- 8. Wega's own code ------------------------------------------------------
# The app trusts its own code only through `CodeSignatureVerifier.verifyStaticCode`: a downloaded
# .dmg and the app inside it, the app inside a downloaded .pkg (in the app and again in the root
# helper), the app the installer leaves in /Applications, and askpass and the sudo shim in
# /Library/Application Support/WegaMacUpdater/Authorization before sudo runs them. Each needs a
# Developer ID signature of Wega's Team ID, valid in every architecture and nested program. Step 4
# does not check nested code and step 7 covers only the app and the helper, so a nested program left
# ad hoc or a .dmg signed with another identity would pass both, and every user's self-update would
# refuse the release.
#
# codesign's option for each of `publisherValidationFlags`: --strict (kSecCSStrictValidate),
# --deep (kSecCSCheckNestedCode), --all-architectures (kSecCSCheckAllArchitectures).
check_own_code() {
    local target="$1" requirement="$2" label="$3"
    if codesign --verify --strict --deep --all-architectures -R "=$requirement" "$target" >/dev/null 2>&1; then
        ok "Wega przyjmie własny kod: $label"
    else
        bad "Wega odrzuci własny kod (podpis Developer ID w każdej architekturze i programie zagnieżdżonym): $label"
    fi
}

# The payload as PackagePayloadVerifier expands it, with the authorization copies build-pkg.sh
# installs next to the app.
check_package_payload() {
    local package="$1" label expanded authorization
    label="$(basename "$package")"
    expanded="$OWN_CODE_WORK/$label"
    if ! pkgutil --expand-full "$package" "$expanded" >/dev/null 2>&1; then
        bad "nie rozpakowano ładunku (pkgutil --expand-full), więc nie da się go sprawdzić: $label"
        return
    fi
    authorization="$expanded/Payload/Library/Application Support/WegaMacUpdater/Authorization"
    check_own_code "$expanded/Payload/Applications/$APP_NAME.app" "$CLIENT_REQUIREMENT" "$label › Applications/$APP_NAME.app"
    check_own_code "$authorization/WegaAskpass" "$ASKPASS_REQUIREMENT" "$label › Authorization/WegaAskpass"
    check_own_code "$authorization/sudo-shim/sudo" "$SUDO_SHIM_REQUIREMENT" "$label › Authorization/sudo-shim/sudo"
}

echo "→ 8. Własny kod Wegi (samoaktualizacja, askpass, sudo shim)"
if [[ "$SIGNED_DEVELOPER_ID" -ne 1 ]]; then
    note "Pominięto: własny kod Wegi da się sprawdzić tylko na podpisie Developer ID."
else
    OWN_CODE_WORK="$(mktemp -d "${TMPDIR:-/tmp}/wega-verify-bundle.XXXXXX")"
    trap 'rm -rf "$OWN_CODE_WORK"' EXIT
    check_own_code "$APP_BUNDLE" "$CLIENT_REQUIREMENT" "$(basename "$APP_BUNDLE")"
    check_own_code "$CONTENTS/Helpers/WegaAskpass" "$ASKPASS_REQUIREMENT" "WegaAskpass"
    check_own_code "$CONTENTS/Helpers/sudo-shim/sudo" "$SUDO_SHIM_REQUIREMENT" "sudo-shim/sudo"
    for target in ${ARTIFACTS[@]+"${ARTIFACTS[@]}"}; do
        # A missing artifact is already a failure of steps 5 and 6.
        [[ -e "$target" ]] || continue
        case "$target" in
            *.dmg) check_own_code "$target" "$DISK_IMAGE_REQUIREMENT" "$(basename "$target")" ;;
            *.pkg) check_package_payload "$target" ;;
        esac
    done
fi

echo
if [[ "$fail" -gt 0 ]]; then
    echo "❌ Weryfikacja bundla: $fail problem(ów)." >&2
    exit 1
fi
echo "✅ Weryfikacja bundla OK"
