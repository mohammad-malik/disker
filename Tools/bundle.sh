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
# Asked for, never assumed. SwiftPM's current build system puts products under
# `.build/out/Products/<Config>`, not the `.build/arm64-apple-macosx/<config>` this used to
# hardcode — and that old path still holds a binary from the last build that used it. Copying
# it produced an app that launched, ran, and silently predated every change being tested.
BUILD_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path "${TESTING_FLAGS[@]}" | tail -1)"
APP_DIR="build/$APP_NAME.app"
VERSION="${DISKER_VERSION:-1.0.0}"
# A build without an explicit version is a local one. It says so, so that the update check
# does not offer every published release to a 1.0.0 that is really today's source.
DEVELOPMENT_KEY=""
if [[ -z "${DISKER_VERSION:-}" ]]; then
    DEVELOPMENT_KEY="<key>DiskerDevelopmentBuild</key><true/>"
fi

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
    $DEVELOPMENT_KEY
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

# --- Icons ------------------------------------------------------------------
# Both variants ship. A bundle can only declare one static icon (used by Finder and the
# installer), so the light artwork is the declared one and AppearanceController swaps the
# Dock icon at runtime to match the effective appearance.
echo "==> Copying icons"
for variant in Dark Light; do
    if [[ -f "Resources/AppIcon-$variant.icns" ]]; then
        cp "Resources/AppIcon-$variant.icns" "$APP_DIR/Contents/Resources/"
    else
        echo "    warning: Resources/AppIcon-$variant.icns missing"
    fi
done
# CFBundleIconFile points at this one; keep the name in sync with Info.plist above.
if [[ -f "Resources/AppIcon-Light.icns" ]]; then
    cp "Resources/AppIcon-Light.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

# RemoveMacAI is compiled in, and its MIT licence (and pared's, in the notices) asks to
# travel with every copy, so a downloaded Disker.app has to carry them, not just the source.
echo "==> Copying RemoveMacAI's licences"
mkdir -p "$APP_DIR/Contents/Resources/RemoveMacAI"
cp Sources/RemoveMacAIKit/Upstream/LICENSE Sources/RemoveMacAIKit/Upstream/THIRD-PARTY-NOTICES.md \
    "$APP_DIR/Contents/Resources/RemoveMacAI/"

# --- Signing ----------------------------------------------------------------
# Prefer the stable self-signed identity. Falling back to ad-hoc keeps the build working
# out of the box, at the cost of Full Disk Access resetting on every rebuild.
#
# DISKER_ADHOC=1 forces ad-hoc even when the identity exists, which is what a build for
# anyone else needs. The self-signed certificate is trusted only in the keychain that created
# it; on another Mac a bundle signed with it fails validation outright and Finder reports the
# app as damaged, which is harder to get past than the ordinary unidentified-developer prompt
# an ad-hoc signature produces.
echo "==> Signing"
if [[ "${DISKER_ADHOC:-0}" == "1" ]]; then
    codesign --force --sign - "$APP_DIR"
    echo "    Signed ad-hoc for distribution."
elif security find-certificate -c "$SIGNING_IDENTITY" >/dev/null 2>&1; then
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
