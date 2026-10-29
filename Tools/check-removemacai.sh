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

# Each tripwire names a line it must catch, checked before it is trusted. A pattern that
# matches nothing reads exactly like clean upstream code, and `\b` — what these first used —
# is an extension that not every grep -E honours, so a guard could have been switched off
# by the machine it ran on. The patterns use only POSIX classes now, and the sample proves
# it on whichever grep this is.
#
# Then the files allowed to reference the symbol: where it is defined, upstream's App scene
# (which Disker does not use), and the self-test.
tripwire() {
    local pattern="$1" sample="$2" why="$3"
    shift 3
    local allowed=("$@") hits
    if ! printf '%s\n' "$sample" | grep -qE "$pattern"; then
        echo "error: tripwire /$pattern/ does not match its own sample, so it would catch nothing." >&2
        exit 1
    fi
    hits="$( (grep -rlE "$pattern" "$UPSTREAM" --include="*.swift" || true) | sed "s|$UPSTREAM/||" | sort)"
    for file in $hits; do
        if [[ ! " ${allowed[*]} " == *" $file "* ]]; then
            echo "tripwire: $file uses /$pattern/ — $why" >&2
            fail=1
        fi
    done
}

# "Not part of a longer name", spelled with POSIX classes instead of `\b`.
EDGE='(^|[^[:alnum:]_])'

tripwire 'URLSession|URLRequest' \
    '      let (data, response) = try await URLSession.shared.data(for: request)' \
    "RemoveMacAI code that reaches the network from inside Disker. Disker promises one request, its own update check." \
    Updates.swift
tripwire "${EDGE}Updates\." \
    '      switch await Updates.latest() {' \
    "RemoveMacAI's update check, outside its App scene, would offer RemoveMacAI downloads inside Disker." \
    Updates.swift App/RemoveMacAIApp.swift SelfTest.swift
tripwire "${EDGE}CommandLineTool\." \
    '    let path = CommandLineTool.path' \
    "RemoveMacAI's command-line installer, outside its App scene, would install a tool from Disker." \
    CommandLineTool.swift App/RemoveMacAIApp.swift SelfTest.swift
tripwire '^@main' \
    '@main' \
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
