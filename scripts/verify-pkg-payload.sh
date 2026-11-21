#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# verify-pkg-payload.sh — the .pkg installs a bundle the helper's bundle gate accepts (Z14).
#
# Wega registers and uses its root helper only from a bundle directly in /Applications whose
# entries launchd runs the helper from all belong to root and cannot be written by their group or
# by others (HelperBundleGate, Sources/WegaHelperKit). A package that installs one of them with a
# group or other write bit (a builder's umask is enough), or that Installer may relocate into a copy
# the user owns, would leave every genuine install refused. This reads the built package:
#
#   1. PackageInfo — no bundle Installer may relocate, and permissions are overwritten on install,
#   2. Bom         — each gate entry is in the payload, of its kind, owned by root, and not
#                    writable by its group or by others.
#
# Usage:
#   ./scripts/verify-pkg-payload.sh PKG [APP_NAME]      # APP_NAME default WegaMacUpdater
#
# build-pkg.sh runs it on the package it has just built. Exit 0 when sound, 1 otherwise.
# ---------------------------------------------------------------------------

PKG="${1:?usage: verify-pkg-payload.sh PKG [APP_NAME]}"
APP_NAME="${2:-WegaMacUpdater}"

# The entries of HelperBundleEntry, under the bundle (PkgPayloadVerificationTests pins the list).
ENTRIES=(
    ""
    "/Contents"
    "/Contents/MacOS"
    "/Contents/MacOS/WegaPrivilegedHelper"
    "/Contents/Library"
    "/Contents/Library/LaunchDaemons"
    "/Contents/Library/LaunchDaemons/com.wega.WegaMacUpdater.helper.plist"
)
FILES=("/Contents/MacOS/WegaPrivilegedHelper" "/Contents/Library/LaunchDaemons/com.wega.WegaMacUpdater.helper.plist")

fail=0
bad() { echo "  ✗ $*" >&2; fail=$((fail + 1)); }
ok()  { echo "  ✓ $*"; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
pkgutil --expand "$PKG" "$work/expanded" >/dev/null
INFO="$work/expanded/PackageInfo"
BOM="$work/expanded/Bom"

echo "→ Pakiet dla bramki pomocnika: $(basename "$PKG")"

relocatable="$(xmllint --xpath 'count(//relocate/bundle)' "$INFO")"
if [[ "$relocatable" == "0" ]]; then
    ok "żaden bundle nie jest relocatable"
else
    bad "Installer może zainstalować $relocatable bundle(i) w innym miejscu (relocatable)"
fi
overwrite="$(xmllint --xpath 'string(/pkg-info/@overwrite-permissions)' "$INFO")"
if [[ "$overwrite" == "true" ]]; then
    ok "instalacja nadpisuje uprawnienia (overwrite-permissions)"
else
    bad "instalacja nie nadpisuje uprawnień (overwrite-permissions=\"$overwrite\")"
fi

# `lsbom -p MUf`: mode, owner and path, separated by tabs; the mode is `ls`-style (drwxr-xr-x).
listing="$(lsbom -p MUf "$BOM")"
for rel in "${ENTRIES[@]}"; do
    path="./Applications/$APP_NAME.app$rel"
    shown="${rel#/}"
    shown="${shown:-$APP_NAME.app}"
    line="$(awk -F'\t' -v wanted="$path" '$3 == wanted { print; exit }' <<< "$listing")"
    if [[ -z "$line" ]]; then
        bad "$shown: brak w pakiecie"
        continue
    fi
    mode="$(awk -F'\t' '{ gsub(/ /, "", $1); print $1 }' <<< "$line")"
    owner="$(awk -F'\t' '{ print $2 }' <<< "$line")"
    expected_type="d"
    for file in "${FILES[@]}"; do
        if [[ "$rel" == "$file" ]]; then expected_type="-"; fi
    done
    if [[ "${mode:0:1}" != "$expected_type" ]]; then
        bad "$shown: zły rodzaj ($mode)"
    elif [[ "$owner" != "root" ]]; then
        bad "$shown: właściciel $owner, nie root"
    elif [[ "${mode:5:1}" == "w" || "${mode:8:1}" == "w" ]]; then
        bad "$shown: zapis dla grupy lub innych ($mode)"
    else
        ok "$shown ($mode $owner)"
    fi
done

if [[ "$fail" -gt 0 ]]; then
    echo "❌ Pakiet zainstaluje Wegę, z której pomocnik nie zadziała: $fail problem(ów)." >&2
    exit 1
fi
echo "✅ Pakiet zainstaluje Wegę, którą przyjmie bramka pomocnika"
