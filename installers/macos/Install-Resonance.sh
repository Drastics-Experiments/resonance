#!/usr/bin/env bash

set -euo pipefail

REPOSITORY="Drastics-Experiments/resonance"
BASE_URL="https://github.com/$REPOSITORY/releases/latest/download"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/resonance-installer.XXXXXX")"
PKG="$WORK_DIR/Resonance-macOS.pkg"
CHECKSUM="$WORK_DIR/Resonance-macOS.pkg.sha256"

cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT HUP INT TERM

echo "Downloading the latest Resonance installer…"
curl --fail --location --proto '=https' --tlsv1.2 "$BASE_URL/Resonance-macOS.pkg" --output "$PKG"
curl --fail --location --proto '=https' --tlsv1.2 "$BASE_URL/Resonance-macOS.pkg.sha256" --output "$CHECKSUM"

EXPECTED="$(awk 'NR == 1 { print $1 }' "$CHECKSUM")"
ACTUAL="$(shasum -a 256 "$PKG" | awk '{ print $1 }')"
[[ "$EXPECTED" =~ ^[a-fA-F0-9]{64}$ && "$EXPECTED" == "$ACTUAL" ]] || {
    echo "Installer checksum verification failed." >&2
    exit 65
}

echo "Checksum verified. macOS may ask for an administrator password to install into /Applications."
sudo /usr/sbin/installer -pkg "$PKG" -target /
open -a Resonance
echo "Resonance is installed in /Applications."
