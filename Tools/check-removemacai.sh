#!/bin/bash
# Checks the vendored RemoveMacAI beyond "Disker still compiles".
#
#   Tools/check-removemacai.sh [extra swift build flags]
#
# 1. Tripwires: upstream code that is harmless in RemoveMacAI's own app but wrong inside
#    Disker. Today its update check and its command-line installer are reachable only from
#    its App scene, which Disker never loads. If a release wires either into the window
#    Disker hosts, Disker would grow a second update prompt pointing at RemoveMacAI, or an
#    administrator-rights installer, without anyone deciding that. A tripwire fails the
#    sync so a person decides instead.
# 2. Upstream's own self-test, built from the vendored files exactly as Disker has them,
#    patches included. Disker's build leaves out the command-line entry point, so it never
#    compiles this; here it is built as upstream builds it. It touches nothing on the system.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

UPSTREAM="$REPO_ROOT/Sources/RemoveMacAIKit/Upstream"
fail=0

# Files allowed to reference a symbol: where it is defined, upstream's App scene (which
# Disker does not use), and the self-test.
tripwire() {
    local pattern="$1" why="$2"
    shift 2
    local allowed=("$@") hits
    hits="$( (grep -rlE "$pattern" "$UPSTREAM" --include="*.swift" || true) | sed "s|$UPSTREAM/||" | sort)"
    for file in $hits; do
        if [[ ! " ${allowed[*]} " == *" $file "* ]]; then
            echo "tripwire: $file uses /$pattern/ — $why" >&2
            fail=1
        fi
    done
}

tripwire 'URLSession|URLRequest' \
    "RemoveMacAI code that reaches the network from inside Disker. Disker promises one request, its own update check." \
    Updates.swift
tripwire '\bUpdates\.' \
    "RemoveMacAI's update check, outside its App scene, would offer RemoveMacAI downloads inside Disker." \
    Updates.swift App/RemoveMacAIApp.swift SelfTest.swift
tripwire '\bCommandLineTool\.' \
    "RemoveMacAI's command-line installer, outside its App scene, would install a tool from Disker." \
    CommandLineTool.swift App/RemoveMacAIApp.swift SelfTest.swift
tripwire '^@main' \
    "a second entry point would clash with Disker's." \
    __none__

if [[ $fail -ne 0 ]]; then
    echo "error: tripwires failed; see above." >&2
    exit 1
fi
echo "Tripwires: clean."

# Upstream's package layout, assembled from the vendored files. Its manifest is two
# targets and has not changed since the first release, so it is written here rather than
# vendored.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/Sources"
cp -R "$UPSTREAM" "$WORK/Sources/removemacai"
rm -f "$WORK/Sources/removemacai/"{LICENSE,THIRD-PARTY-NOTICES.md,UPSTREAM}
cp -R "$REPO_ROOT/Sources/UAF" "$WORK/Sources/UAF"
cat > "$WORK/Package.swift" <<'EOF'
// swift-tools-version: 5.10
import PackageDescription

let package = Package(
  name: "RemoveMacAI",
  platforms: [.macOS("15.1")],
  products: [.executable(name: "removemacai", targets: ["removemacai"])],
  targets: [
    .target(name: "UAF", cSettings: [.unsafeFlags(["-fobjc-arc"])]),
    .executableTarget(name: "removemacai", dependencies: ["UAF"]),
  ]
)
EOF

echo "==> Building upstream's command line from the vendored files"
swift build --package-path "$WORK" "$@" 2>&1 | grep -E 'error|warning: unre|Compiling removemacai|Build complete' || true
BIN="$(swift build --package-path "$WORK" --show-bin-path "$@")/removemacai"
[[ -x "$BIN" ]] || { echo "error: upstream's command line did not build." >&2; exit 1; }

echo "==> Running its self-test"
NO_COLOR=1 "$BIN" selftest
