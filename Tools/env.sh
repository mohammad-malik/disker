#!/bin/bash
# Shared build configuration.
#
# We build against the Command Line Tools rather than Xcode. Xcode normally puts
# swift-testing on the search path and wires up its rpaths; with CLT alone the framework
# ships but nothing points at it, so every invocation has to supply the paths by hand.
# Centralised here so build/test/bundle stay consistent.

CLT_FRAMEWORKS="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
CLT_DEV_LIB="/Library/Developer/CommandLineTools/Library/Developer/usr/lib"
# The compiler auto-loads the plugins sitting directly in `host/plugins`, and swift-testing's
# is one directory further down, so `@Test` and `@Suite` fail to expand unless it is named.
CLT_TESTING_PLUGINS="/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"

# swift-testing lives in CLT but is not on the default search path.
TESTING_FLAGS=(
    -Xswiftc -F -Xswiftc "$CLT_FRAMEWORKS"
    -Xswiftc -plugin-path -Xswiftc "$CLT_TESTING_PLUGINS"
    -Xlinker -rpath -Xlinker "$CLT_FRAMEWORKS"
    -Xlinker -rpath -Xlinker "$CLT_DEV_LIB"
)

# The macOS 26 SDK, on a machine running 27.
#
# The macOS 27 Command Line Tools ship no `libSwiftUIMacros.dylib`, so `@State` cannot expand
# and every SwiftUI file fails to compile against the 27 SDK. The 26 SDK declares `State` as a
# plain property wrapper rather than a macro, which sidesteps the missing plugin entirely.
# Only set when the caller has not chosen an SDK and this one is actually installed.
if [[ -z "${SDKROOT:-}" && -d "/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk" ]]; then
    export SDKROOT="/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk"
fi

APP_NAME="Disker"
BUNDLE_ID="dev.disker.Disker"
# Keep in sync with LSMinimumSystemVersion in the generated Info.plist.
MIN_MACOS="26.0"

# Stable signing identity, if one has been created. TCC keys Full Disk Access to code
# identity, so an ad-hoc signature means the grant is revoked on every rebuild.
# Run Tools/create-signing-identity.sh once to avoid that.
SIGNING_IDENTITY="Disker Development"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
