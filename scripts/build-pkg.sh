#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# build-pkg.sh — buduje WegaMacUpdater.pkg z czystego SPM
#
# Użycie:
#   ./scripts/build-pkg.sh                  # ad-hoc (lokalnie, bez podpisu)
#   ./scripts/build-pkg.sh "Developer ID"   # podpisany Developer ID
#
# Wymagania: Xcode Command Line Tools, swift, pkgbuild
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

BUNDLE_ID="com.wega.WegaMacUpdater"
APP_NAME="WegaMacUpdater"
# Wersja ma jedno źródło prawdy: AppMetadata.version (czytane też w runtime przez aplikację).
VERSION="$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' Sources/MacUpdaterCore/AppMetadata.swift)"
if [[ -z "$VERSION" ]]; then
  echo "❌ Nie udało się odczytać wersji z Sources/MacUpdaterCore/AppMetadata.swift"
  exit 1
fi
echo "→ Wersja (z AppMetadata.version): $VERSION"
MIN_MACOS="13.0"
# Universal binary domyślnie (Apple Silicon + Intel). Nadpisz listą arch przez env:
#   ARCHS="arm64" ./scripts/build-pkg.sh        # tylko Apple Silicon
read -r -a ARCHS <<< "${ARCHS:-arm64 x86_64}"

SIGN_IDENTITY="${1:-}"   # pierwszy argument = Developer ID (opcjonalnie)

BUILD_DIR="$(pwd)/.build/pkg-staging"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
OUTPUT_PKG="$(pwd)/build/$APP_NAME.pkg"
OUTPUT_DMG="$(pwd)/build/$APP_NAME.dmg"

echo "→ Czyszczę staging..."
rm -rf "$BUILD_DIR"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
mkdir -p "$(dirname "$OUTPUT_PKG")"

# ---------------------------------------------------------------------------
echo "→ Buduję release binary (arch: ${ARCHS[*]})..."
ARCH_FLAGS=()
for a in "${ARCHS[@]}"; do ARCH_FLAGS+=(--arch "$a"); done
swift build -c release "${ARCH_FLAGS[@]}"

# Robustne ustalenie katalogu wyjściowego (działa dla single- i multi-arch).
BIN_DIR="$(swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)"
BINARY="$BIN_DIR/$APP_NAME"
if [[ ! -f "$BINARY" ]]; then
  echo "❌ Nie znaleziono binary w $BIN_DIR. Sprawdź wynik swift build."
  exit 1
fi

cp "$BINARY" "$CONTENTS/MacOS/$APP_NAME"

# ---------------------------------------------------------------------------
# FEAT-01: osadź privileged helper + jego launchd plist w bundlu.
echo "→ Osadzam privileged helper (FEAT-01)..."
HELPER_BIN="$BIN_DIR/WegaPrivilegedHelper"
if [[ ! -f "$HELPER_BIN" ]]; then
  echo "❌ Nie znaleziono helpera w $BIN_DIR (target WegaPrivilegedHelper). Sprawdź swift build."
  exit 1
fi
cp "$HELPER_BIN" "$CONTENTS/MacOS/WegaPrivilegedHelper"
mkdir -p "$CONTENTS/Library/LaunchDaemons"
cp "Sources/WegaPrivilegedHelper/com.wega.WegaMacUpdater.helper.plist" \
   "$CONTENTS/Library/LaunchDaemons/com.wega.WegaMacUpdater.helper.plist"
echo "   ✓ Helper + launchd plist osadzone"

# Bundle zasobów SPM (app-catalog.json). Bez tego Bundle.module w spakowanej aplikacji
# nie znajdzie katalogu → AppCatalog.loadBundled() rzuca → wszystkie checkery oparte
# o katalog (GitHub, JetBrains, Synology, override'y Sparkle) tracą swoje mapowania.
RES_BUNDLE="$BIN_DIR/${APP_NAME}_MacUpdaterCore.bundle"
if [[ -d "$RES_BUNDLE" ]]; then
  cp -R "$RES_BUNDLE" "$CONTENTS/Resources/"
  echo "   ✓ Skopiowano bundle zasobów: $(basename "$RES_BUNDLE")"
else
  echo "❌ Nie znaleziono bundla zasobów $RES_BUNDLE — app-catalog.json nie trafiłby do .app"
  exit 1
fi

echo "   ✓ Architektury binarki: $(lipo -archs "$CONTENTS/MacOS/$APP_NAME")"

# ---------------------------------------------------------------------------
echo "→ Generuję ikonę aplikacji..."
swift scripts/make-icon.swift
cp build/AppIcon.icns "$CONTENTS/Resources/AppIcon.icns"

# ---------------------------------------------------------------------------
echo "→ Tworzę Info.plist..."
cat > "$CONTENTS/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleSignature</key>
    <string>????</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>LSMinimumSystemVersion</key>
    <string>${MIN_MACOS}</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
    <key>NSSupportsSuddenTermination</key>
    <false/>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 Dominik Sienkiewicz. All rights reserved.</string>
</dict>
</plist>
PLIST

# ---------------------------------------------------------------------------
# Podpis INSIDE-OUT (DEBT-01): najpierw zagnieżdżony helper, potem kontener.
# Apple odradza --deep do podpisywania — psuje notaryzację przy zagnieżdżonym kodzie.
echo "→ Podpisuję (inside-out: helper → app)..."
HELPER_SIGN_ID="com.wega.WegaMacUpdater.helper"
if [[ -n "$SIGN_IDENTITY" ]]; then
    codesign --force --options runtime --timestamp \
        -i "$HELPER_SIGN_ID" \
        --sign "$SIGN_IDENTITY" \
        "$CONTENTS/MacOS/WegaPrivilegedHelper"
    codesign --force --options runtime --timestamp \
        --sign "$SIGN_IDENTITY" \
        "$APP_BUNDLE"
    echo "   ✓ Podpisano (Developer ID + hardened runtime): $SIGN_IDENTITY"
else
    codesign --force -i "$HELPER_SIGN_ID" --sign - "$CONTENTS/MacOS/WegaPrivilegedHelper"
    codesign --force --sign - "$APP_BUNDLE"
    echo "   ⚠️ Ad-hoc (bez Developer ID). UWAGA: SMAppService helper NIE zarejestruje się bez podpisu Developer ID."
fi

# ---------------------------------------------------------------------------
echo "→ Tworzę PKG..."
# DEBT-02: podpisz sam pakiet (nie tylko .app w środku) gdy mamy Developer ID.
if [[ -n "$SIGN_IDENTITY" ]]; then
    pkgbuild \
        --component "$APP_BUNDLE" \
        --install-location /Applications \
        --identifier "$BUNDLE_ID" \
        --version "$VERSION" \
        --sign "$SIGN_IDENTITY" \
        "$OUTPUT_PKG"
else
    pkgbuild \
        --component "$APP_BUNDLE" \
        --install-location /Applications \
        --identifier "$BUNDLE_ID" \
        --version "$VERSION" \
        "$OUTPUT_PKG"
fi

# ---------------------------------------------------------------------------
echo "→ Tworzę DMG (drag-to-Applications)..."
DMG_STAGING="$BUILD_DIR/dmg"
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"
cp -R "$APP_BUNDLE" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"
rm -f "$OUTPUT_DMG"
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$DMG_STAGING" \
    -fs HFS+ \
    -format UDZO \
    -ov \
    "$OUTPUT_DMG" >/dev/null
if [[ -n "$SIGN_IDENTITY" ]]; then
    codesign --force --sign "$SIGN_IDENTITY" "$OUTPUT_DMG"
fi

echo ""
echo "✅ Gotowe: $OUTPUT_PKG"
echo "✅ Gotowe: $OUTPUT_DMG"
if [[ -z "$SIGN_IDENTITY" ]]; then
    echo ""
    echo "⚠️  PKG jest niepodpisany (ad-hoc). Żeby go dystrybuować:"
    echo "   1. Miej Developer ID Application certificate w Keychain"
    echo "   2. Uruchom: ./scripts/build-pkg.sh \"Developer ID Application: Twoje Imię (TEAMID)\""
    echo "   3. Potem notaryzuj: xcrun notarytool submit $OUTPUT_PKG --wait"
fi
