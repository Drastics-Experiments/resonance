#!/bin/zsh
set -euo pipefail

RES_PROJECT_DIR="${0:A:h}"
source "$RES_PROJECT_DIR/.launcher-terminal.zsh"
RES_APP_DIR="$RES_PROJECT_DIR"
RES_LAUNCH_LABEL="mov.unblocked.resonance.dev.macos"
RES_PREVIEW_APP="/private/tmp/Resonance Preview.app"
RES_PREVIEW_EXECUTABLE="$RES_PREVIEW_APP/Contents/MacOS/LikedSongsFocus"
RES_PREVIEW_PLIST="$RES_PREVIEW_APP/Contents/Info.plist"
RES_LEGACY_PREVIEW_EXECUTABLE="/private/tmp/ResonancePreview.app/Contents/MacOS/LikedSongsFocus"
RES_ICON_WORK_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/resonance-preview-icon.XXXXXX")"

cleanup() {
  /bin/rm -rf "$RES_ICON_WORK_DIR"
}
trap 'cleanup; res_close_launcher_terminal' EXIT
trap cleanup HUP INT TERM

echo "Building the macOS development app…"
/usr/bin/xcrun swift build --package-path "$RES_APP_DIR/mac" --product LikedSongsFocus
RES_BIN_DIR="$(/usr/bin/xcrun swift build --package-path "$RES_APP_DIR/mac" --show-bin-path)"
RES_BINARY="$RES_BIN_DIR/LikedSongsFocus"

[[ -x "$RES_BINARY" ]] || { echo "macOS build did not produce $RES_BINARY" >&2; exit 1; }

# Retire the old background-only launcher, which bypassed normal Dock registration.
/bin/launchctl remove "$RES_LAUNCH_LABEL" 2>/dev/null || true

RES_OLD_PREVIEW_PIDS="$({
  /usr/bin/pgrep -f "^$RES_PREVIEW_EXECUTABLE$" || true
  /usr/bin/pgrep -f "^$RES_LEGACY_PREVIEW_EXECUTABLE$" || true
} | /usr/bin/sort -u)"
if [[ -n "$RES_OLD_PREVIEW_PIDS" ]]; then
  for RES_OLD_PREVIEW_PID in ${(f)RES_OLD_PREVIEW_PIDS}; do
    /bin/kill "$RES_OLD_PREVIEW_PID" 2>/dev/null || true
  done
  for RES_ATTEMPT in {1..50}; do
    if ! /usr/bin/pgrep -f "^$RES_PREVIEW_EXECUTABLE$" >/dev/null \
      && ! /usr/bin/pgrep -f "^$RES_LEGACY_PREVIEW_EXECUTABLE$" >/dev/null; then
      break
    fi
    sleep 0.1
  done
fi

mkdir -p "$RES_PREVIEW_APP/Contents/MacOS" "$RES_PREVIEW_APP/Contents/Resources" "$RES_ICON_WORK_DIR/AppIcon.iconset"
/usr/bin/install -m 0755 "$RES_BINARY" "$RES_PREVIEW_EXECUTABLE"

RES_BASE_ICON="$RES_ICON_WORK_DIR/AppIcon-1024.png"
/usr/bin/xcrun swift "$RES_APP_DIR/mac/scripts/render_icon.swift" "$RES_BASE_ICON"
while read -r RES_ICON_PIXELS RES_ICON_NAME; do
  /usr/bin/sips -s format png -z "$RES_ICON_PIXELS" "$RES_ICON_PIXELS" "$RES_BASE_ICON" \
    --out "$RES_ICON_WORK_DIR/AppIcon.iconset/$RES_ICON_NAME" >/dev/null
done <<'SIZES'
16 icon_16x16.png
32 icon_16x16@2x.png
32 icon_32x32.png
64 icon_32x32@2x.png
128 icon_128x128.png
256 icon_128x128@2x.png
256 icon_256x256.png
512 icon_256x256@2x.png
512 icon_512x512.png
1024 icon_512x512@2x.png
SIZES
/usr/bin/iconutil -c icns "$RES_ICON_WORK_DIR/AppIcon.iconset" \
  -o "$RES_PREVIEW_APP/Contents/Resources/AppIcon.icns"

RES_APP_VERSION="$(/usr/bin/plutil -extract version raw "$RES_APP_DIR/release/version.json")"
RES_BUILD_NUMBER="$(/usr/bin/plutil -extract build raw "$RES_APP_DIR/release/version.json")"
/usr/bin/plutil -create xml1 "$RES_PREVIEW_PLIST"
/usr/bin/plutil -insert CFBundleDevelopmentRegion -string en "$RES_PREVIEW_PLIST"
/usr/bin/plutil -insert CFBundleDisplayName -string "Resonance Preview" "$RES_PREVIEW_PLIST"
/usr/bin/plutil -insert CFBundleExecutable -string LikedSongsFocus "$RES_PREVIEW_PLIST"
/usr/bin/plutil -insert CFBundleIconFile -string AppIcon.icns "$RES_PREVIEW_PLIST"
/usr/bin/plutil -insert CFBundleIdentifier -string com.gavindietrich.ResonancePreview "$RES_PREVIEW_PLIST"
/usr/bin/plutil -insert CFBundleInfoDictionaryVersion -string 6.0 "$RES_PREVIEW_PLIST"
/usr/bin/plutil -insert CFBundleName -string "Resonance Preview" "$RES_PREVIEW_PLIST"
/usr/bin/plutil -insert CFBundlePackageType -string APPL "$RES_PREVIEW_PLIST"
/usr/bin/plutil -insert CFBundleShortVersionString -string "$RES_APP_VERSION" "$RES_PREVIEW_PLIST"
/usr/bin/plutil -insert CFBundleVersion -string "$RES_BUILD_NUMBER" "$RES_PREVIEW_PLIST"
/usr/bin/plutil -insert LSApplicationCategoryType -string public.app-category.music "$RES_PREVIEW_PLIST"
/usr/bin/plutil -insert LSMinimumSystemVersion -string 14.0 "$RES_PREVIEW_PLIST"
/usr/bin/plutil -insert NSHighResolutionCapable -bool YES "$RES_PREVIEW_PLIST"
/usr/bin/plutil -insert NSPrincipalClass -string NSApplication "$RES_PREVIEW_PLIST"
/usr/bin/plutil -insert NSAppTransportSecurity -dictionary "$RES_PREVIEW_PLIST"
/usr/bin/plutil -insert NSAppTransportSecurity.NSAllowsArbitraryLoads -bool YES "$RES_PREVIEW_PLIST"

/usr/bin/codesign --force --deep --sign - "$RES_PREVIEW_APP"
/usr/bin/open -n "$RES_PREVIEW_APP"
for RES_ATTEMPT in {1..50}; do
  /usr/bin/pgrep -f "^$RES_PREVIEW_EXECUTABLE$" >/dev/null && break
  sleep 0.1
done
/usr/bin/pgrep -f "^$RES_PREVIEW_EXECUTABLE$" >/dev/null \
  || { echo "macOS Preview app failed to launch." >&2; exit 1; }
echo "macOS Resonance Preview launched from $RES_APP_DIR/mac"
