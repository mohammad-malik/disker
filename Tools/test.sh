#!/bin/bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
cd "$REPO_ROOT"
exec swift test "${TESTING_FLAGS[@]}" "$@"
