#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CLT_FRAMEWORKS="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
CLT_SWIFT_LIBRARIES="/Library/Developer/CommandLineTools/Library/Developer/usr/lib"

cd "$ROOT_DIR"
swift test \
    -Xswiftc -F \
    -Xswiftc "$CLT_FRAMEWORKS" \
    -Xlinker "-F$CLT_FRAMEWORKS" \
    -Xlinker -rpath \
    -Xlinker "$CLT_FRAMEWORKS" \
    -Xlinker -rpath \
    -Xlinker "$CLT_SWIFT_LIBRARIES"
