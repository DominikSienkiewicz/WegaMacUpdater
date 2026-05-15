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

BUNDLE_ID="com.wega.WegaMacUpdater"
APP_NAME="WegaMacUpdater"
VERSION="1.0.0"
MIN_MACOS="13.0"
ARCH="arm64"           # zmień na "x86_64" lub "arm64-apple-macosx" jeśli potrzeba

SIGN_IDENTITY="${1:-}"   # pierwszy argument = Developer ID (opcjonalnie)

BUILD_DIR="$(pwd)/.build/pkg-staging"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
OUTPUT_PKG="$(pwd)/build/$APP_NAME.pkg"

echo "→ Czyszczę staging..."
rm -rf "$BUILD_DIR"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
mkdir -p "$(dirname "$OUTPUT_PKG")"

# ---------------------------------------------------------------------------
echo "→ Buduję release binary..."
swift build -c release --arch "$ARCH"

BINARY=".build/$ARCH-apple-macosx/release/$APP_NAME"
if [[ ! -f "$BINARY" ]]; then
  BINARY=".build/release/$APP_NAME"
fi

if [[ ! -f "$BINARY" ]]; then
  echo "❌ Nie znaleziono binary. Sprawdź wynik swift build."
  exit 1
fi

cp "$BINARY" "$CONTENTS/MacOS/$APP_NAME"

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
echo "→ Podpisuję..."
if [[ -n "$SIGN_IDENTITY" ]]; then
    codesign --force --deep --options runtime \
        --sign "$SIGN_IDENTITY" \
        "$APP_BUNDLE"
    echo "   ✓ Podpisano: $SIGN_IDENTITY"
else
    codesign --force --deep --sign - "$APP_BUNDLE"
    echo "   ✓ Ad-hoc (bez Developer ID — tylko lokalnie)"
fi

# ---------------------------------------------------------------------------
echo "→ Tworzę PKG..."
pkgbuild \
    --component "$APP_BUNDLE" \
    --install-location /Applications \
    --identifier "$BUNDLE_ID" \
    --version "$VERSION" \
    "$OUTPUT_PKG"

echo ""
echo "✅ Gotowe: $OUTPUT_PKG"
if [[ -z "$SIGN_IDENTITY" ]]; then
    echo ""
    echo "⚠️  PKG jest niepodpisany (ad-hoc). Żeby go dystrybuować:"
    echo "   1. Miej Developer ID Application certificate w Keychain"
    echo "   2. Uruchom: ./scripts/build-pkg.sh \"Developer ID Application: Twoje Imię (TEAMID)\""
    echo "   3. Potem notaryzuj: xcrun notarytool submit $OUTPUT_PKG --wait"
fi
