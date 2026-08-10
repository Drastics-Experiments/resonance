#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKTREE_ROOT="$(git -C "$ROOT_DIR" rev-parse --show-toplevel)"
WORKTREE_HASH="$(printf '%s' "$WORKTREE_ROOT" | shasum -a 256 | awk '{ print substr($1, 1, 12) }')"
SWIFT_SCRATCH_PATH="${TMPDIR:-/tmp}/resonance-swift-tests-${UID}/${WORKTREE_HASH}"
CLT_FRAMEWORKS="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
CLT_SWIFT_LIBRARIES="/Library/Developer/CommandLineTools/Library/Developer/usr/lib"

cd "$ROOT_DIR"
swift test \
    --scratch-path "$SWIFT_SCRATCH_PATH" \
    -Xswiftc -F \
    -Xswiftc "$CLT_FRAMEWORKS" \
    -Xlinker "-F$CLT_FRAMEWORKS" \
    -Xlinker -rpath \
    -Xlinker "$CLT_FRAMEWORKS" \
    -Xlinker -rpath \
    -Xlinker "$CLT_SWIFT_LIBRARIES"
