#!/usr/bin/env bash

set -euo pipefail

ARCHIVE="${1:?update archive is required}"
DESTINATION="${2:?application destination is required}"
APP_PID="${3:?application pid is required}"
VERSION="${4:?update version is required}"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/resonance-update.XXXXXX")"
BACKUP="$(dirname "$DESTINATION")/.Resonance.previous.$$"
COMPATIBILITY_BUNDLE_ID="com.gavindietrich.Liked""SongsFocus"

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

CURRENT_INFO_PLIST="$DESTINATION/Contents/Info.plist"
[[ -d "$DESTINATION" && -f "$CURRENT_INFO_PLIST" ]] || exit 65
CURRENT_MODE="$(/usr/bin/plutil -extract ResonanceUpdateAuthenticity raw "$CURRENT_INFO_PLIST")"
CURRENT_TEAM_ID="$(/usr/bin/plutil -extract ResonanceUpdateTeamIdentifier raw "$CURRENT_INFO_PLIST" 2>/dev/null || true)"
CURRENT_REQUIREMENT="$(/usr/bin/plutil -extract ResonanceUpdateDesignatedRequirement raw "$CURRENT_INFO_PLIST" 2>/dev/null || true)"

case "$CURRENT_MODE" in
    production)
        [[ "$CURRENT_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || exit 65
        [[ -n "$CURRENT_REQUIREMENT" && "$CURRENT_REQUIREMENT" != *$'\n'* && "$CURRENT_REQUIREMENT" != *$'\r'* ]] || exit 65
        CURRENT_SIGNATURE_DETAILS="$(/usr/bin/codesign --display --verbose=4 "$DESTINATION" 2>&1)" || exit 65
        grep -Fqx "TeamIdentifier=$CURRENT_TEAM_ID" <<< "$CURRENT_SIGNATURE_DETAILS" || exit 65
        /usr/bin/codesign --verify --deep --strict -R="$CURRENT_REQUIREMENT" "$DESTINATION"
        UPDATE_AUTH_MODE=production
        ;;
    development)
        # Ad-hoc signatures are accepted only for an explicitly opted-in
        # development/test app. The production branch above never consults
        # this environment variable.
        [[ "${RESONANCE_ALLOW_UNVERIFIED_UPDATES:-0}" == "1" ]] || exit 65
        UPDATE_AUTH_MODE=development
        ;;
    *)
        exit 65
        ;;
esac

/usr/bin/ditto -x -k "$ARCHIVE" "$WORK_DIR"
NEW_APP="$WORK_DIR/Resonance.app"
INFO_PLIST="$NEW_APP/Contents/Info.plist"
[[ -d "$NEW_APP" && -f "$INFO_PLIST" ]] || exit 65

BUNDLE_ID="$(/usr/bin/plutil -extract CFBundleIdentifier raw "$INFO_PLIST")"
BUNDLE_VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$INFO_PLIST")"
[[ "$BUNDLE_ID" == "$COMPATIBILITY_BUNDLE_ID" ]] || exit 65
[[ "$BUNDLE_VERSION" == "$VERSION" ]] || exit 65
NEW_MODE="$(/usr/bin/plutil -extract ResonanceUpdateAuthenticity raw "$INFO_PLIST" 2>/dev/null || true)"
[[ "$NEW_MODE" == "$UPDATE_AUTH_MODE" ]] || exit 65

case "$UPDATE_AUTH_MODE" in
    production)
        NEW_TEAM_ID="$(/usr/bin/plutil -extract ResonanceUpdateTeamIdentifier raw "$INFO_PLIST" 2>/dev/null || true)"
        NEW_REQUIREMENT="$(/usr/bin/plutil -extract ResonanceUpdateDesignatedRequirement raw "$INFO_PLIST" 2>/dev/null || true)"
        [[ "$NEW_TEAM_ID" == "$CURRENT_TEAM_ID" ]] || exit 65
        [[ "$NEW_REQUIREMENT" == "$CURRENT_REQUIREMENT" ]] || exit 65
        NEW_SIGNATURE_DETAILS="$(/usr/bin/codesign --display --verbose=4 "$NEW_APP" 2>&1)" || exit 65
        grep -Fqx "TeamIdentifier=$CURRENT_TEAM_ID" <<< "$NEW_SIGNATURE_DETAILS" || exit 65
        /usr/bin/codesign --verify --deep --strict -R="$CURRENT_REQUIREMENT" "$NEW_APP"
        ;;
    development)
        /usr/bin/codesign --verify --deep --strict "$NEW_APP"
        ;;
    *)
        exit 65
        ;;
esac

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
