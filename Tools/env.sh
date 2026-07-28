#!/bin/bash
# Shared build configuration.
#
# We build against the Command Line Tools rather than Xcode. Xcode normally puts
# swift-testing on the search path and wires up its rpaths; with CLT alone the framework
# ships but nothing points at it, so every invocation has to supply the paths by hand.
# Centralised here so build/test/bundle stay consistent.

CLT_FRAMEWORKS="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
CLT_DEV_LIB="/Library/Developer/CommandLineTools/Library/Developer/usr/lib"

# swift-testing lives in CLT but is not on the default search path.
TESTING_FLAGS=(
    -Xswiftc -F -Xswiftc "$CLT_FRAMEWORKS"
    -Xlinker -rpath -Xlinker "$CLT_FRAMEWORKS"
    -Xlinker -rpath -Xlinker "$CLT_DEV_LIB"
)

APP_NAME="Disker"
BUNDLE_ID="dev.disker.Disker"
# Keep in sync with LSMinimumSystemVersion in the generated Info.plist.
MIN_MACOS="26.0"

# Stable signing identity, if one has been created. TCC keys Full Disk Access to code
# identity, so an ad-hoc signature means the grant is revoked on every rebuild.
# Run Tools/create-signing-identity.sh once to avoid that.
SIGNING_IDENTITY="Disker Development"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
