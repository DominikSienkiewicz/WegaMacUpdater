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
# SEC-04 dokłada dwie rzeczy, które ten guard też pilnuje:
#   * bramka przypina Team ID wydawcy — notaryzacja mówi „podpisał JAKIŚ deweloper
#     Apple", nigdy „podpisała Wega", więc obcy notaryzowany artefakt musi odpaść;
#   * REQUIRE_SIGNED=1 (tryb wydania stabilnego) zamienia pominięcia w błędy —
#     build ad-hoc nie może przejść bramki wydania na zielono.
#
# `codesign`/`pkgutil` są tu podmienione na stuby w PATH, więc test nie potrzebuje ani
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
cat >&2 <<TAIL
Authority=Developer ID Certification Authority
Authority=Apple Root CA
TeamIdentifier=${WEGA_TEST_TEAM_ID:-TEAMIDTEST}
Sealed Resources version=2 rules=13 files=9
TAIL
STUB

# `.pkg` nie jest widoczny dla codesign — Team ID czytamy z pkgutil.
cat > "$STUB_BIN/pkgutil" <<'STUB'
#!/usr/bin/env bash
cat <<OUT
Package "WegaMacUpdater.pkg":
   Status: signed by a certificate trusted by macOS
   Certificate Chain:
    1. Developer ID Installer: Wega Test (${WEGA_TEST_TEAM_ID:-TEAMIDTEST})
OUT
STUB

cat > "$STUB_BIN/lipo" <<'STUB'
#!/usr/bin/env bash
echo "x86_64 arm64"
STUB

# Domyślnie brak biletu notaryzacji: `stapler validate` i `spctl` odrzucają artefakt.
# `WEGA_TEST_NOTARIZED=1` udaje artefakt notaryzowany i ostemplowany — potrzebne, żeby
# przetestować krok 6 (Team ID) niezależnie od kroku 5.
cat > "$STUB_BIN/xcrun" <<'STUB'
#!/usr/bin/env bash
[[ "${WEGA_TEST_NOTARIZED:-0}" == "1" ]] && exit 0
exit 1
STUB
cat > "$STUB_BIN/spctl" <<'STUB'
#!/usr/bin/env bash
[[ "${WEGA_TEST_NOTARIZED:-0}" == "1" ]] && exit 0
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

# --- 3. SEC-04: Team ID zgodny ⇒ bramka przechodzi --------------------------
echo "→ notaryzowany artefakt z oczekiwanym Team ID ⇒ bramka przechodzi"
set +e
match_out="$(WEGA_TEST_SIGN_MODE=developer-id WEGA_TEST_NOTARIZED=1 \
             WEGA_TEST_TEAM_ID=TEAMIDTEST EXPECTED_TEAM_ID=TEAMIDTEST \
             bash "$REPO_ROOT/scripts/verify-bundle.sh" "$APP" "$PKG" 2>&1)"
match_rc=$?
set -e

if [[ "$match_rc" -eq 0 ]]; then
    pass "zgodny Team ID przechodzi (exit 0)"
else
    fail "zgodny Team ID odrzucony (exit $match_rc): $match_out"
fi
if grep -q "Team ID TEAMIDTEST" <<< "$match_out"; then
    pass "Team ID został faktycznie odczytany i porównany"
else
    fail "bramka nie raportuje odczytanego Team ID — krok 6 nie działa"
fi

# --- 4. SEC-04: obcy Team ID ⇒ bramka odrzuca (sedno wpisu) -----------------
echo "→ obcy (ale notaryzowany) artefakt ⇒ bramka odrzuca"
set +e
foreign_out="$(WEGA_TEST_SIGN_MODE=developer-id WEGA_TEST_NOTARIZED=1 \
               WEGA_TEST_TEAM_ID=FOREIGN123 EXPECTED_TEAM_ID=TEAMIDTEST \
               bash "$REPO_ROOT/scripts/verify-bundle.sh" "$APP" "$PKG" 2>&1)"
foreign_rc=$?
set -e

if [[ "$foreign_rc" -ne 0 ]]; then
    pass "obcy Team ID odrzucony (exit $foreign_rc)"
else
    fail "bramka przepuściła notaryzowany artefakt OBCEGO wydawcy — dokładnie luka SEC-04"
fi
if grep -q "Team ID FOREIGN123 ≠ TEAMIDTEST" <<< "$foreign_out"; then
    pass "powód odrzucenia nazwany wprost"
else
    fail "brak komunikatu o niezgodnym Team ID"
fi

# --- 5. SEC-04: REQUIRE_SIGNED=1 ⇒ build ad-hoc nie jest wydaniem stabilnym -
echo "→ REQUIRE_SIGNED=1 + build ad-hoc ⇒ bramka odrzuca"
set +e
require_out="$(WEGA_TEST_SIGN_MODE=adhoc REQUIRE_SIGNED=1 \
               bash "$REPO_ROOT/scripts/verify-bundle.sh" "$APP" "$PKG" 2>&1)"
require_rc=$?
set -e

if [[ "$require_rc" -ne 0 ]]; then
    pass "tryb wydania stabilnego odrzuca build bez Developer ID (exit $require_rc)"
else
    fail "REQUIRE_SIGNED=1 przepuścił build ad-hoc — wydanie stabilne pozostaje fail-open"
fi
if grep -q "Tryb wydania stabilnego" <<< "$require_out"; then
    pass "tryb wydania stabilnego jest sygnalizowany w logu"
else
    fail "brak informacji o trybie wydania stabilnego"
fi

echo
if [[ "$failures" -gt 0 ]]; then
    echo "❌ guard bramki artefaktu: $failures problem(ów)." >&2
    exit 1
fi
echo "✅ guard bramki artefaktu działa"
