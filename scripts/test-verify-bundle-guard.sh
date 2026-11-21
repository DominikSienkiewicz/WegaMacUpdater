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
# RC2-4 dokłada krok 7: podpisana aplikacja i pomocnik muszą spełniać wymagania XPC, którymi
# przypinają się nawzajem (clientRequirement()/helperRequirement()). Stub `codesign` sprawdza
# w nich to, na czym bramka polega: tekstową postać `-R "=…"`, identyfikator celu i OU jego
# certyfikatu liścia — więc obcy zespół albo zły identyfikator pomocnika musi odpaść.
#
# Krok 8: aplikacja ufa własnemu kodowi tylko przez CodeSignatureVerifier.verifyStaticCode
# (podpis Developer ID Wegi, każda architektura, każdy program zagnieżdżony). Bramka musi
# sprawdzić tak samo każdy plik, który aplikacja tak sprawdza: aplikację, askpass, sudo shim,
# obraz .dmg oraz aplikację i kopie askpass/sudo shim w ładunku .pkg. Inaczej wydanie z
# zagnieżdżonym programem podpisanym ad hoc albo z .dmg podpisanym inną tożsamością przeszłoby
# bramkę, a samoaktualizacja każdego użytkownika by je odrzuciła.
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
DMG="$WORK/WegaMacUpdater.dmg"
touch "$PKG" "$DMG"

# --- Stuby: codesign / lipo / xcrun / spctl ---------------------------------
STUB_BIN="$WORK/bin"
mkdir -p "$STUB_BIN"

cat > "$STUB_BIN/codesign" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "--verify" ]]; then
    # `--verify -R "=<tekst>" <cel>` to krok 7. Prawdziwy codesign czyta `-R="=…"` jako tekst
    # "=…", czyli błąd składni — stub też. Podpis celu: identyfikator i OU liścia (prawdziwy
    # Team ID z WegaHelperProtocol.swift, chyba że test podstawi inny).
    # Krok 8 woła `--verify --strict --deep --all-architectures -R "=…"`: takie wywołania idą do
    # osobnego dziennika, z pełną ścieżką celu i opcjami. Obraz .dmg nie ma identyfikatora.
    requirement="" previous="" target="" options=""
    for arg in "$@"; do
        case "$arg" in
            -R=*) echo "line 1:1: unexpected token: =" >&2; exit 1 ;;
            --verify) ;;
            --*) options="${options:+$options }$arg" ;;
        esac
        [[ "$previous" == "-R" ]] && requirement="$arg"
        previous="$arg"
        target="$arg"
    done
    [[ -z "$requirement" ]] && exit 0
    case "$(basename "$target")" in
        WegaPrivilegedHelper)
            identifier="${WEGA_TEST_HELPER_IDENTIFIER:-com.wega.WegaMacUpdater.helper}"
            ou="${WEGA_TEST_HELPER_OU:-$WEGA_TEST_REAL_TEAM_ID}" ;;
        WegaAskpass)
            identifier="com.wega.WegaMacUpdater.askpass"
            ou="${WEGA_TEST_ASKPASS_OU:-$WEGA_TEST_REAL_TEAM_ID}" ;;
        sudo)
            identifier="${WEGA_TEST_SUDO_SHIM_IDENTIFIER:-com.wega.WegaMacUpdater.sudo-shim}"
            ou="$WEGA_TEST_REAL_TEAM_ID" ;;
        *.dmg)
            identifier=""
            ou="${WEGA_TEST_DMG_OU:-$WEGA_TEST_REAL_TEAM_ID}" ;;
        *)
            identifier="com.wega.WegaMacUpdater"
            ou="${WEGA_TEST_APP_OU:-$WEGA_TEST_REAL_TEAM_ID}" ;;
    esac
    if [[ -z "$options" ]]; then
        printf '%s %s\n' "$(basename "$target")" "$requirement" >> "${WEGA_TEST_REQUIREMENT_LOG:-/dev/null}"
    else
        printf '%s\t%s\t%s\n' "$target" "$options" "$requirement" >> "${WEGA_TEST_OWN_CODE_LOG:-/dev/null}"
    fi
    if [[ -n "$identifier" ]]; then
        [[ "$requirement" == "=anchor apple generic and identifier \"$identifier\" and "* ]] || exit 3
    else
        [[ "$requirement" == "=anchor apple generic and certificate 1["* ]] || exit 3
    fi
    [[ "$requirement" == *" and certificate leaf[subject.OU] = \"$ou\"" ]] || exit 3
    # Program zagnieżdżony zmieniony po podpisaniu: bundle przechodzi `--strict` (krok 4), a odpada
    # dopiero, gdy `--deep` sprawdza też kod zagnieżdżony.
    if [[ "${WEGA_TEST_NESTED_TAMPERED:-0}" == "1" && "$target" == *.app && " $options " == *" --deep "* ]]; then
        exit 1
    fi
    # Jeden plik o złym podpisie, wskazany wzorcem ścieżki (np. kopia w ładunku .pkg).
    # shellcheck disable=SC2053  # wzorzec celowo bez cudzysłowu
    if [[ -n "${WEGA_TEST_REJECT_PATH:-}" && "$target" == $WEGA_TEST_REJECT_PATH ]]; then
        exit 3
    fi
    exit 0
fi

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
# `--expand-full PKG DEST` (krok 8) rozkłada ładunek tak jak prawdziwy pkgutil: DEST/Payload z
# aplikacją i kopiami askpass/sudo shim dla /Library/Application Support/…/Authorization, a gdy
# DEST już istnieje, odmawia. `WEGA_TEST_PKG_EXPANDS=0` udaje pakiet, którego nie da się rozpakować.
cat > "$STUB_BIN/pkgutil" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "--expand-full" ]]; then
    [[ -e "$3" ]] && { echo "Could not unarchive $2 (File exists)" >&2; exit 1; }
    [[ "${WEGA_TEST_PKG_EXPANDS:-1}" == "1" ]] || { echo "Error: archive verify failed" >&2; exit 1; }
    authorization="$3/Payload/Library/Application Support/WegaMacUpdater/Authorization"
    mkdir -p "$3/Payload/Applications/WegaMacUpdater.app/Contents" "$authorization/sudo-shim"
    touch "$authorization/WegaAskpass" "$authorization/sudo-shim/sudo"
    exit 0
fi
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
WEGA_TEST_REAL_TEAM_ID="$(sed -n 's/.*static let teamIdentifier = "\(.*\)".*/\1/p' \
    "$REPO_ROOT/Sources/WegaHelperKit/WegaHelperProtocol.swift")"
export WEGA_TEST_REAL_TEAM_ID
export WEGA_TEST_REQUIREMENT_LOG="$WORK/requirements.log"
export WEGA_TEST_OWN_CODE_LOG="$WORK/own-code.log"

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
: > "$WEGA_TEST_REQUIREMENT_LOG"
: > "$WEGA_TEST_OWN_CODE_LOG"
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
if grep -q "Pominięto: wymagania XPC" <<< "$adhoc_out" && [[ ! -s "$WEGA_TEST_REQUIREMENT_LOG" ]]; then
    pass "wymagania XPC pominięte dla builda ad-hoc (anchor apple generic nie może tu zachodzić)"
else
    fail "build ad-hoc: wymagania XPC nie zostały pominięte"
fi
if grep -q "Pominięto: własny kod Wegi" <<< "$adhoc_out" && [[ ! -s "$WEGA_TEST_OWN_CODE_LOG" ]]; then
    pass "własny kod Wegi pominięty dla builda ad-hoc (wymaganie Developer ID nie może tu zachodzić)"
else
    fail "build ad-hoc: sprawdzenie własnego kodu Wegi nie zostało pominięte"
fi

# --- 3. SEC-04: Team ID zgodny ⇒ bramka przechodzi --------------------------
echo "→ notaryzowany artefakt z oczekiwanym Team ID ⇒ bramka przechodzi"
: > "$WEGA_TEST_REQUIREMENT_LOG"
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

# --- 3a. RC2-4: każdy plik sprawdzony własnym wymaganiem XPC ----------------
echo "→ podpis Developer ID ⇒ aplikacja i pomocnik sprawdzone każdy swoim wymaganiem XPC"
app_checks="$(grep -c '^WegaMacUpdater.app =anchor apple generic and identifier "com.wega.WegaMacUpdater" and ' "$WEGA_TEST_REQUIREMENT_LOG" || true)"
helper_checks="$(grep -c '^WegaPrivilegedHelper =anchor apple generic and identifier "com.wega.WegaMacUpdater.helper" and ' "$WEGA_TEST_REQUIREMENT_LOG" || true)"
if [[ "$app_checks" -eq 1 && "$helper_checks" -eq 1 && "$(wc -l < "$WEGA_TEST_REQUIREMENT_LOG")" -eq 2 ]]; then
    pass "codesign --verify -R \"=…\": aplikacja z clientRequirement, pomocnik z helperRequirement"
else
    fail "wymagania XPC nie sprawdzone po jednym na plik: $(cat "$WEGA_TEST_REQUIREMENT_LOG")"
fi
if grep -q "wymaganie XPC spełnione: WegaMacUpdater.app" <<< "$match_out" \
    && grep -q "wymaganie XPC spełnione: WegaPrivilegedHelper" <<< "$match_out"; then
    pass "oba spełnione wymagania raportowane"
else
    fail "brak raportu o spełnionych wymaganiach XPC"
fi

# Każdy z trzech przypadków: notaryzowany, Team ID aplikacji zgodny (krok 6 przechodzi),
# a jeden podpis nie spełnia wymagania XPC — bramka musi odrzucić i nazwać plik.
requirement_rejects() {
    local description="$1" named="$2" out rc
    shift 2
    set +e
    out="$(env "$@" WEGA_TEST_SIGN_MODE=developer-id WEGA_TEST_NOTARIZED=1 \
           WEGA_TEST_TEAM_ID=TEAMIDTEST EXPECTED_TEAM_ID=TEAMIDTEST \
           bash "$REPO_ROOT/scripts/verify-bundle.sh" "$APP" "$PKG" 2>&1)"
    rc=$?
    set -e
    if [[ "$rc" -ne 0 ]] && grep -q "✗ .*wymagania XPC.*: $named" <<< "$out"; then
        pass "$description ⇒ bramka odrzuca (exit $rc) i nazywa $named"
    else
        fail "$description ⇒ bramka przepuściła albo nie nazwała $named (exit $rc): $out"
    fi
}

echo "→ RC2-4: podpis, którego pomocnik albo aplikacja nie przyjmie ⇒ bramka odrzuca"
requirement_rejects "pomocnik podpisany przez obcy zespół" WegaPrivilegedHelper WEGA_TEST_HELPER_OU=FOREIGN123
requirement_rejects "pomocnik podpisany bez swojego identyfikatora" WegaPrivilegedHelper \
    WEGA_TEST_HELPER_IDENTIFIER=WegaPrivilegedHelper
requirement_rejects "aplikacja, której liść ma obce OU" WegaMacUpdater.app WEGA_TEST_APP_OU=FOREIGN123

# --- 3b. Krok 8: własny kod Wegi sprawdzony tak, jak sprawdza go aplikacja --
echo "→ podpis Developer ID ⇒ każdy plik, któremu Wega ufa u siebie, sprawdzony ściśle swoim wymaganiem"
: > "$WEGA_TEST_OWN_CODE_LOG"
set +e
own_out="$(WEGA_TEST_SIGN_MODE=developer-id WEGA_TEST_NOTARIZED=1 \
           WEGA_TEST_TEAM_ID=TEAMIDTEST EXPECTED_TEAM_ID=TEAMIDTEST \
           bash "$REPO_ROOT/scripts/verify-bundle.sh" "$APP" "$PKG" "$DMG" 2>&1)"
own_rc=$?
set -e

if [[ "$own_rc" -eq 0 ]]; then
    pass "aplikacja, askpass, sudo shim, .dmg i ładunek .pkg przechodzą (exit 0)"
else
    fail "poprawnie podpisany własny kod odrzucony (exit $own_rc): $own_out"
fi

# Ile razy cel sprawdzono z opcjami kroku 8. `*/…` dopasowuje koniec ścieżki: ładunek .pkg leży
# w katalogu tymczasowym bramki.
strict_checks_of() {
    awk -F'\t' -v wanted="$1" -v options="--strict --deep --all-architectures" '
        function matches(path) {
            if (substr(wanted, 1, 2) != "*/") return path == wanted
            return substr(path, length(path) - length(wanted) + 2) == substr(wanted, 2)
        }
        $2 == options && matches($1) { count++ }
        END { print count + 0 }
    ' "$WEGA_TEST_OWN_CODE_LOG"
}
PAYLOAD_AUTHORIZATION="*/Payload/Library/Application Support/WegaMacUpdater/Authorization"
for wanted in "$APP" "$CONTENTS/Helpers/WegaAskpass" "$CONTENTS/Helpers/sudo-shim/sudo" "$DMG" \
              "*/Payload/Applications/WegaMacUpdater.app" \
              "$PAYLOAD_AUTHORIZATION/WegaAskpass" "$PAYLOAD_AUTHORIZATION/sudo-shim/sudo"; do
    shown="${wanted#"$WORK"/}"
    checks="$(strict_checks_of "$wanted")"
    if [[ "$checks" -eq 1 ]]; then
        pass "codesign --verify --strict --deep --all-architectures -R \"=…\": $shown"
    else
        fail "$shown sprawdzony z opcjami kroku 8 $checks razy, oczekiwano 1: $(cat "$WEGA_TEST_OWN_CODE_LOG")"
    fi
done
if [[ "$(wc -l < "$WEGA_TEST_OWN_CODE_LOG")" -eq 7 ]]; then
    pass "krok 8 nie sprawdza niczego poza tymi siedmioma plikami"
else
    fail "krok 8 sprawdził inne pliki: $(cat "$WEGA_TEST_OWN_CODE_LOG")"
fi

# Każdy przypadek: notaryzowany, Team ID i wymagania XPC zgodne, a jeden plik nie przejdzie
# sprawdzenia, którym aplikacja weryfikuje własny kod — bramka musi odrzucić i nazwać ten plik.
own_code_rejects() {
    local description="$1" named="$2" out rc rejected
    shift 2
    set +e
    out="$(env "$@" WEGA_TEST_SIGN_MODE=developer-id WEGA_TEST_NOTARIZED=1 \
           WEGA_TEST_TEAM_ID=TEAMIDTEST EXPECTED_TEAM_ID=TEAMIDTEST \
           bash "$REPO_ROOT/scripts/verify-bundle.sh" "$APP" "$PKG" "$DMG" 2>&1)"
    rc=$?
    set -e
    rejected="$(grep "✗ " <<< "$out" || true)"
    if [[ "$rc" -ne 0 && $'\n'"$rejected"$'\n' == *": $named"$'\n'* ]]; then
        pass "$description ⇒ bramka odrzuca (exit $rc) i nazywa $named"
    else
        fail "$description ⇒ bramka przepuściła albo nie nazwała $named (exit $rc): $out"
    fi
}

echo "→ krok 8: wydanie, którego własny kod Wega odrzuci ⇒ bramka odrzuca"
own_code_rejects "askpass podpisany przez obcy zespół (albo ad hoc)" WegaAskpass WEGA_TEST_ASKPASS_OU=FOREIGN123
own_code_rejects "sudo shim podpisany bez swojego identyfikatora" sudo-shim/sudo WEGA_TEST_SUDO_SHIM_IDENTIFIER=sudo
own_code_rejects "obraz .dmg podpisany przez obcy zespół" WegaMacUpdater.dmg WEGA_TEST_DMG_OU=FOREIGN123
own_code_rejects "program zagnieżdżony zmieniony po podpisaniu aplikacji (krok 4 tego nie widzi)" \
    WegaMacUpdater.app WEGA_TEST_NESTED_TAMPERED=1
own_code_rejects "aplikacja w ładunku .pkg o innym podpisie" "WegaMacUpdater.pkg › Applications/WegaMacUpdater.app" \
    "WEGA_TEST_REJECT_PATH=*/Payload/Applications/WegaMacUpdater.app"
own_code_rejects "kopia askpass w ładunku .pkg o innym podpisie" "WegaMacUpdater.pkg › Authorization/WegaAskpass" \
    "WEGA_TEST_REJECT_PATH=*/Payload/Library/*/WegaAskpass"
own_code_rejects "kopia sudo shim w ładunku .pkg o innym podpisie" "WegaMacUpdater.pkg › Authorization/sudo-shim/sudo" \
    "WEGA_TEST_REJECT_PATH=*/Payload/Library/*/sudo-shim/sudo"
own_code_rejects "pakiet, którego ładunku nie da się rozpakować" WegaMacUpdater.pkg WEGA_TEST_PKG_EXPANDS=0

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
