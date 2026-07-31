#!/bin/bash
# Builds a Disker.app for other people and zips it for a GitHub release.
#
# Differs from bundle.sh in two ways that matter for anything leaving this machine:
#
#   1. It signs ad-hoc rather than with the local self-signed identity. That certificate is
#      trusted only in the keychain that created it, so elsewhere the bundle fails validation
#      and Finder calls the app damaged — worse than the ordinary unidentified-developer
#      prompt, because right-click → Open does not clear it.
#   2. It zips with `ditto`, which preserves the signature and symlinks. Compressing a .app
#      with `zip -r` mangles both and the copy will not launch.
#
# Usage: Tools/release.sh [version]

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
cd "$REPO_ROOT"

VERSION="${1:-1.0.0}"
APP_DIR="build/$APP_NAME.app"
ARCHIVE="build/$APP_NAME-$VERSION-macos-arm64.zip"

echo "==> Testing"
"$REPO_ROOT/Tools/test.sh" >/dev/null

echo "==> Building $VERSION for distribution"
DISKER_VERSION="$VERSION" DISKER_ADHOC=1 "$REPO_ROOT/Tools/bundle.sh" release

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=1 "$APP_DIR"

echo "==> Packaging"
rm -f "$ARCHIVE"
# --keepParent so the archive expands to Disker.app rather than its contents.
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ARCHIVE"

echo
echo "Built $ARCHIVE"
shasum -a 256 "$ARCHIVE"
