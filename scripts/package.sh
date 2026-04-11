#!/usr/bin/env bash
# Build, sign, package, and (optionally) notarize DraftFrame as a DMG.
#
# Usage:
#   scripts/package.sh                # build + sign + DMG (no notarization)
#   scripts/package.sh --notarize     # also notarize + staple
#   VERSION=0.2.0 scripts/package.sh  # override version string
#
# Required env / config:
#   SIGN_IDENTITY  - Developer ID Application identity (defaults below)
#   NOTARY_PROFILE - notarytool keychain profile name (default: DRAFTFRAME_NOTARY)
#
# One-time notarization setup:
#   xcrun notarytool store-credentials DRAFTFRAME_NOTARY \
#     --apple-id you@example.com --team-id 49V6GRJ827 --password <app-specific-pwd>

set -euo pipefail

# ---------- config ----------
APP_NAME="DraftFrame"
BUNDLE_ID="com.intuitivecompute.draftframe"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Intuitive Compute Inc (49V6GRJ827)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-DRAFTFRAME_NOTARY}"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"

NOTARIZE=0
for arg in "$@"; do
    case "$arg" in
        --notarize) NOTARIZE=1 ;;
        *) echo "unknown arg: $arg" >&2; exit 2 ;;
    esac
done

# ---------- paths ----------
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
DMG="$DIST/$APP_NAME-$VERSION.dmg"
PLIST_SRC="$ROOT/scripts/Info.plist"
ENTITLEMENTS="$ROOT/scripts/DraftFrame.entitlements"
ICON_SRC="$ROOT/Sources/AppIcon.png"

cd "$ROOT"

echo "==> Cleaning $DIST"
rm -rf "$DIST"
mkdir -p "$DIST"

# ---------- 1. build universal release binary ----------
echo "==> Building universal release binary (arm64 + x86_64)"
swift build -c release \
    --arch arm64 --arch x86_64 \
    --disable-sandbox

BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/$APP_NAME"
if [[ ! -f "$BIN" ]]; then
    echo "error: built binary not found at $BIN" >&2
    exit 1
fi

# ---------- 2. assemble .app bundle ----------
echo "==> Assembling $APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
chmod +x "$APP/Contents/MacOS/$APP_NAME"

# Keep AppIcon.png next to the executable so DFAppDelegate.findAppIcon() finds it.
cp "$ICON_SRC" "$APP/Contents/MacOS/AppIcon.png"

# Render Info.plist with version substitutions.
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" \
    "$PLIST_SRC" > "$APP/Contents/Info.plist"

# ---------- 3. generate AppIcon.icns from AppIcon.png ----------
echo "==> Generating AppIcon.icns"
ICONSET="$DIST/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 64 128 256 512; do
    sips -z $size $size "$ICON_SRC" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size*2)) $((size*2)) "$ICON_SRC" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

# ---------- 4. codesign the .app (deep, hardened runtime) ----------
echo "==> Signing $APP with: $SIGN_IDENTITY"
# Sign nested frameworks/binaries first if any show up; --deep handles SwiftTerm etc.
codesign --force --deep --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" \
    --sign "$SIGN_IDENTITY" \
    "$APP"

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"
spctl --assess --type execute --verbose=4 "$APP" || \
    echo "(spctl assessment will fail until notarization is stapled — that's expected)"

# ---------- 5. build DMG via create-dmg ----------
if ! command -v create-dmg >/dev/null 2>&1; then
    echo "error: create-dmg not found. Install with: brew install create-dmg" >&2
    exit 1
fi

echo "==> Building $DMG"
rm -f "$DMG"
create-dmg \
    --volname "$APP_NAME $VERSION" \
    --window-pos 200 120 \
    --window-size 660 400 \
    --icon-size 110 \
    --icon "$APP_NAME.app" 165 200 \
    --hide-extension "$APP_NAME.app" \
    --app-drop-link 495 200 \
    --no-internet-enable \
    "$DMG" \
    "$APP"

echo "==> Signing DMG"
codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"

# ---------- 6. notarize + staple (optional) ----------
if [[ $NOTARIZE -eq 1 ]]; then
    echo "==> Submitting to notary service (profile: $NOTARY_PROFILE)"
    xcrun notarytool submit "$DMG" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait

    echo "==> Stapling notarization ticket"
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"

    echo "==> Final Gatekeeper assessment"
    spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG"
fi

echo
echo "Done. Output:"
echo "  $APP"
echo "  $DMG"
