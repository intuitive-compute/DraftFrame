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

# ---------- 1. build arm64 release binary ----------
# Apple Silicon only. Xcode 26 requires the Metal Toolchain to build
# universal binaries, which we'd rather not depend on.
echo "==> Building arm64 release binary"
swift build -c release \
    --arch arm64 \
    --disable-sandbox

BIN="$(swift build -c release --arch arm64 --show-bin-path)/$APP_NAME"
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

# ---------- 5. build DMG via hdiutil ----------
# We build the DMG manually (instead of using create-dmg) because on recent
# macOS versions create-dmg's --app-drop-link leaves Finder unable to render
# the Applications folder icon on the symlink. We:
#   1. detach any stale mounts from prior runs,
#   2. create an empty read/write DMG,
#   3. mount it, copy the .app and make the /Applications symlink,
#   4. ask Finder (via AppleScript) to lay out the window and persist the
#      .DS_Store,
#   5. scrub macOS-generated junk (.fseventsd, .Trashes),
#   6. detach and convert to a compressed read-only DMG.
echo "==> Building $DMG"
rm -f "$DMG"

VOLNAME="$APP_NAME $VERSION"

# Detach any stale mounts from previous runs so AppleScript targets the
# right volume. Without this, a stuck "DraftFrame 1.0.1" mount causes the
# new mount to be named "DraftFrame 1.0.1 1" and the script silently lays
# out icons on the wrong volume.
for m in $(mount | awk -v v="$VOLNAME" '$0 ~ v {print $1}'); do
    hdiutil detach "$m" -force -quiet 2>/dev/null || true
done

RW_DMG="$DIST/rw-$APP_NAME-$VERSION.dmg"
rm -f "$RW_DMG"

# Size the DMG from the .app size + slack.
APP_SIZE_KB=$(du -sk "$APP" | awk '{print $1}')
DMG_SIZE_KB=$((APP_SIZE_KB + 20000))  # ~20MB slack for metadata/.DS_Store

hdiutil create \
    -size "${DMG_SIZE_KB}k" \
    -volname "$VOLNAME" \
    -fs HFS+ \
    -fsargs "-c c=64,a=16,e=16" \
    -layout SPUD \
    "$RW_DMG" >/dev/null

# Mount; capture both the device node and the actual mount point.
MOUNT_INFO="$(hdiutil attach -readwrite -noverify -noautoopen "$RW_DMG")"
MOUNT_DEV="$(echo "$MOUNT_INFO" | grep -E '^/dev/' | head -n1 | awk '{print $1}')"
MOUNT_DIR="$(echo "$MOUNT_INFO" | grep -E '^/dev/' | head -n1 | sed -E 's|^[^/]*/Volumes|/Volumes|')"
if [[ -z "$MOUNT_DIR" || ! -d "$MOUNT_DIR" ]]; then
    # Fallback: assume the standard location.
    MOUNT_DIR="/Volumes/$VOLNAME"
fi

# Copy the signed .app.
cp -R "$APP" "$MOUNT_DIR/"

# Settle before AppleScript pokes at Finder.
sync
sleep 2

# Create the Applications alias via Finder (not a plain symlink) so Finder
# renders it with the Applications folder icon. Raw symlinks made with
# `ln -s /Applications` show a blank icon inside DMGs on recent macOS. A
# Finder alias file is a real macOS object that carries the target icon.
osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$VOLNAME"
        open
        -- Make the alias if it doesn't already exist.
        if not (exists item "Applications") then
            make new alias file at container window to POSIX file "/Applications"
            set name of result to "Applications"
        end if
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 860, 520}
        set theViewOptions to the icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 110
        set position of item "$APP_NAME.app" of container window to {165, 200}
        set position of item "Applications" of container window to {495, 200}
        update without registering applications
        delay 2
        close
    end tell
end tell
APPLESCRIPT

# Scrub macOS-generated hidden junk so it doesn't show up in Finder when the
# user opens the final DMG.
rm -rf "$MOUNT_DIR/.fseventsd" "$MOUNT_DIR/.Trashes" 2>/dev/null || true

sync
sleep 1

# Detach cleanly (force as fallback).
hdiutil detach "$MOUNT_DEV" -quiet || hdiutil detach "$MOUNT_DEV" -force -quiet

# Convert to compressed, read-only distribution DMG.
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
rm -f "$RW_DMG"

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
