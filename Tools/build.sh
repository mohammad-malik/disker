#!/bin/bash
# Builds every target with the flags the Command Line Tools need.
#
# A bare `swift build` cannot compile the app on macOS 27: the SwiftUI macro plugin is
# missing from that toolchain, and swift-testing's sits where the compiler does not look.
# `env.sh` supplies both, so build through here rather than calling swift build directly.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
cd "$REPO_ROOT"
exec swift build "${TESTING_FLAGS[@]}" "$@"
