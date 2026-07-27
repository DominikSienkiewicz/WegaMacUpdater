#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# test-verify-bundle-guard.sh — verify-bundle.sh musi ROZPOZNAĆ Developer ID
# i od tego momentu wymagać notaryzacji, zamiast po cichu pomijać krok 5.
#
# Dlaczego ten guard istnieje: bramka artefaktu jest jedynym miejscem, które
# sprawdza, czy wydanie zostało notaryzowane i ostemplowane. Wykrywanie podpisu
# szło przez `codesign -dvv … | grep -q …` pod `set -euo pipefail`: `grep -q`
# kończy się na pierwszym trafieniu, `codesign` dostaje SIGPIPE (141), a
# `pipefail` propaguje 141 jako status potoku — więc trafienie było raportowane
# jako BRAK Developer ID. Podpisany build przechodził bramkę na zielono z
# pominiętą notaryzacją: fail-open dokładnie w kroku, który ma być fail-closed.
#
# `codesign` jest tu podmieniony na stub w PATH, więc test nie potrzebuje ani
# certyfikatu Developer ID, ani sieci — działa tak samo lokalnie i w CI.
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."
REPO_ROOT="$(pwd)"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/wega-verify-bundle-guard.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

failures=0
pass() { printf '  ✓ %s\n' "$1"; }
fail() { printf '  ✗ %s\n' "$1" >&2; failures=$((failures + 1)); }

# --- Fixture: minimalny bundle spełniający kroki 1–3 bramki -----------------
APP="$WORK/WegaMacUpdater.app"
CONTENTS="$APP/Contents"
RES_BUNDLE="$CONTENTS/Resources/WegaMacUpdater_MacUpdaterCore.bundle"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Library/LaunchDaemons" \
         "$CONTENTS/Helpers/sudo-shim" "$RES_BUNDLE"
touch "$CONTENTS/Info.plist" \
      "$CONTENTS/MacOS/WegaMacUpdater" \
      "$CONTENTS/MacOS/WegaPrivilegedHelper" \
      "$CONTENTS/Library/LaunchDaemons/com.wega.WegaMacUpdater.helper.plist" \
      "$CONTENTS/Helpers/WegaAskpass" \
      "$CONTENTS/Helpers/sudo-shim/sudo" \
      "$CONTENTS/Resources/AppIcon.icns" \
      "$RES_BUNDLE/app-catalog.json" \
      "$RES_BUNDLE/endpoints.json"
PKG="$WORK/WegaMacUpdater.pkg"
touch "$PKG"

# --- Stuby: codesign / lipo / xcrun / spctl ---------------------------------
STUB_BIN="$WORK/bin"
mkdir -p "$STUB_BIN"

cat > "$STUB_BIN/codesign" <<'STUB'
#!/usr/bin/env bash
[[ "${1:-}" == "--verify" ]] && exit 0

if [[ "${WEGA_TEST_SIGN_MODE:-}" == "adhoc" ]]; then
    cat >&2 <<'ADHOC'
Identifier=com.wega.WegaMacUpdater
Signature=adhoc
Info.plist entries=15
ADHOC
    exit 0
fi

# Prawdziwy `codesign -dvv` pisze ten blok linia po linii na stderr i pisze
# DALEJ po linii Authority — to właśnie sprawia, że czytelnik `| grep -q`
# ubija go SIGPIPE-em. `sleep` usuwa wyścig, żeby regresja była deterministyczna.
cat >&2 <<'HEAD'
Executable=/staging/WegaMacUpdater.app/Contents/MacOS/WegaMacUpdater
Identifier=com.wega.WegaMacUpdater
Format=app bundle with Mach-O universal (x86_64 arm64)
CodeDirectory v=20500 size=19395 flags=0x10000(runtime)
Authority=Developer ID Application: Wega Test (TEAMIDTEST)
HEAD
sleep 0.2
cat >&2 <<'TAIL'
Authority=Developer ID Certification Authority
Authority=Apple Root CA
TeamIdentifier=TEAMIDTEST
Sealed Resources version=2 rules=13 files=9
TAIL
STUB

cat > "$STUB_BIN/lipo" <<'STUB'
#!/usr/bin/env bash
echo "x86_64 arm64"
STUB

# Brak biletu notaryzacji: `stapler validate` i `spctl` odrzucają artefakt.
cat > "$STUB_BIN/xcrun" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
cat > "$STUB_BIN/spctl" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB

chmod +x "$STUB_BIN"/*
export PATH="$STUB_BIN:$PATH"

# --- 0. Bramka jest wykonywalna (workflowy wołają ./scripts/verify-bundle.sh) ---
echo "→ verify-bundle.sh ma bit wykonywalności"
if [[ -x "$REPO_ROOT/scripts/verify-bundle.sh" ]]; then
    pass "scripts/verify-bundle.sh jest wykonywalny"
else
    fail "scripts/verify-bundle.sh bez bitu +x — CI padnie na 'Permission denied'"
fi

# --- 1. Developer ID rozpoznany → notaryzacja WYMAGANA (fail-closed) --------
echo "→ podpisany Developer ID + brak notaryzacji ⇒ bramka odrzuca"
set +e
signed_out="$(WEGA_TEST_SIGN_MODE=developer-id bash "$REPO_ROOT/scripts/verify-bundle.sh" "$APP" "$PKG" 2>&1)"
signed_rc=$?
set -e

if grep -q "tożsamość: Developer ID Application" <<< "$signed_out"; then
    pass "Developer ID rozpoznany"
else
    fail "Developer ID NIE rozpoznany mimo Authority w codesign (regresja SIGPIPE/pipefail)"
fi
if [[ "$signed_rc" -ne 0 ]]; then
    pass "bramka odrzuca nienotaryzowany artefakt (exit $signed_rc)"
else
    fail "bramka przepuściła nienotaryzowany artefakt Developer ID (exit 0) — fail-open"
fi
if grep -q "Pominięto: notaryzacja i stapling" <<< "$signed_out"; then
    fail "krok notaryzacji pominięty dla podpisanego bundla"
else
    pass "krok notaryzacji nie został pominięty"
fi

# --- 2. Build ad-hoc nadal przechodzi z pominiętym krokiem 5 ----------------
echo "→ build ad-hoc ⇒ notaryzacja pominięta, bramka przechodzi"
set +e
adhoc_out="$(WEGA_TEST_SIGN_MODE=adhoc bash "$REPO_ROOT/scripts/verify-bundle.sh" "$APP" 2>&1)"
adhoc_rc=$?
set -e

if [[ "$adhoc_rc" -eq 0 ]]; then
    pass "bundle ad-hoc przechodzi (exit 0)"
else
    fail "bundle ad-hoc odrzucony (exit $adhoc_rc) — podpisywanie miało zostać opcjonalne"
fi
if grep -q "Pominięto: notaryzacja i stapling" <<< "$adhoc_out"; then
    pass "notaryzacja raportowana jako pominięta"
else
    fail "brak informacji o pominiętej notaryzacji dla builda ad-hoc"
fi

echo
if [[ "$failures" -gt 0 ]]; then
    echo "❌ guard bramki artefaktu: $failures problem(ów)." >&2
    exit 1
fi
echo "✅ guard bramki artefaktu działa"
