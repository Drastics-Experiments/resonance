#!/usr/bin/env bash

set -euo pipefail

ARCHIVE="${1:?update archive is required}"
DESTINATION="${2:?application destination is required}"
APP_PID="${3:?application pid is required}"
VERSION="${4:?update version is required}"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/resonance-update.XXXXXX")"
BACKUP="${DESTINATION}.previous"

cleanup() {
    rm -rf "$WORK_DIR"
    rm -f "$0"
}
trap cleanup EXIT HUP INT TERM

for _ in {1..120}; do
    if ! kill -0 "$APP_PID" 2>/dev/null; then break; fi
    sleep 0.25
done
if kill -0 "$APP_PID" 2>/dev/null; then
    exit 70
fi

/usr/bin/ditto -x -k "$ARCHIVE" "$WORK_DIR"
NEW_APP="$WORK_DIR/Resonance.app"
INFO_PLIST="$NEW_APP/Contents/Info.plist"
[[ -d "$NEW_APP" && -f "$INFO_PLIST" ]] || exit 65

BUNDLE_ID="$(/usr/bin/plutil -extract CFBundleIdentifier raw "$INFO_PLIST")"
BUNDLE_VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$INFO_PLIST")"
[[ "$BUNDLE_ID" == "com.gavindietrich.LikedSongsFocus" ]] || exit 65
[[ "$BUNDLE_VERSION" == "$VERSION" ]] || exit 65
/usr/bin/codesign --verify --deep --strict "$NEW_APP"

rm -rf "$BACKUP"
mv "$DESTINATION" "$BACKUP"
if mv "$NEW_APP" "$DESTINATION"; then
    rm -rf "$BACKUP"
    rm -f "$ARCHIVE"
    if [[ "${RESONANCE_SKIP_RELAUNCH:-0}" != "1" ]]; then
        /usr/bin/open -n "$DESTINATION"
    fi
else
    mv "$BACKUP" "$DESTINATION"
    exit 74
fi
