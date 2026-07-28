#!/bin/bash
# Assembles Disker.app by hand.
#
# Xcode normally does this: compile, lay out the bundle, compile the asset catalog, sign.
# With Command Line Tools only, we do each step explicitly. `actool` is unavailable, so the
# icon is produced with sips + iconutil instead of an asset catalog.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
cd "$REPO_ROOT"

CONFIGURATION="${1:-release}"
BUILD_DIR=".build/arm64-apple-macosx/$CONFIGURATION"
APP_DIR="build/$APP_NAME.app"
VERSION="0.1.0"

echo "==> Building ($CONFIGURATION)"
swift build -c "$CONFIGURATION" --product "$APP_NAME" "${TESTING_FLAGS[@]}"

echo "==> Laying out bundle"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BUILD_DIR/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"

cat >"$APP_DIR/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
    <key>NSHighResolutionCapable</key><true/>
    <!-- Regular app: appears in the Dock and owns a menu bar. -->
    <key>LSUIElement</key><false/>

    <!-- Shown in the system permission prompts. Users decide whether to grant access
         based on these strings, so they state the actual reason. -->
    <key>NSDesktopFolderUsageDescription</key>
    <string>Disker measures the size of your Desktop so it can show what is using space.</string>
    <key>NSDocumentsFolderUsageDescription</key>
    <string>Disker measures the size of your Documents so it can show what is using space.</string>
    <key>NSDownloadsFolderUsageDescription</key>
    <string>Disker measures the size of your Downloads so it can suggest old files to remove.</string>
    <key>NSRemovableVolumesUsageDescription</key>
    <string>Disker analyses connected drives when you select them.</string>
</dict>
</plist>
EOF

# --- Icon -------------------------------------------------------------------
# No actool, so build the .icns directly. Skipped silently when no source art exists.
ICON_SRC="Resources/AppIcon.png"
if [[ -f "$ICON_SRC" ]]; then
    echo "==> Building icon"
    ICONSET="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "$ICONSET"
    for size in 16 32 128 256 512; do
        sips -z $size $size "$ICON_SRC" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null 2>&1
        sips -z $((size * 2)) $((size * 2)) "$ICON_SRC" \
            --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null 2>&1
    done
    iconutil -c icns "$ICONSET" -o "$APP_DIR/Contents/Resources/AppIcon.icns"
    rm -rf "$(dirname "$ICONSET")"
else
    echo "==> No $ICON_SRC — bundling without a custom icon"
fi

# --- Signing ----------------------------------------------------------------
# Prefer the stable self-signed identity. Falling back to ad-hoc keeps the build working
# out of the box, at the cost of Full Disk Access resetting on every rebuild.
echo "==> Signing"
if security find-certificate -c "$SIGNING_IDENTITY" >/dev/null 2>&1; then
    codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none "$APP_DIR"
    echo "    Signed with '$SIGNING_IDENTITY' (Full Disk Access persists across rebuilds)."
else
    codesign --force --sign - "$APP_DIR"
    echo "    Signed ad-hoc. Full Disk Access will reset on every rebuild —"
    echo "    run Tools/create-signing-identity.sh once to fix that."
fi

echo
echo "Built $APP_DIR"
echo "Run with: open $APP_DIR"
