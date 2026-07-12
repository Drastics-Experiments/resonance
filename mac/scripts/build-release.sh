#!/usr/bin/env bash

set -euo pipefail

PRODUCT="LikedSongsFocus"
APP_NAME="Resonance"
BUNDLE_ID="com.gavindietrich.LikedSongsFocus"
APP_VERSION="${APP_VERSION:-1.0.1}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
APP_SIGN_IDENTITY="${MACOS_APP_IDENTITY:--}"
INSTALLER_IDENTITY="${MACOS_INSTALLER_IDENTITY:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_DIR="$(cd "$ROOT_DIR/.." && pwd)"
OUTPUT_DIR="$REPO_DIR/installers/macos/dist"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/resonance-release.XXXXXX")"
APP="$WORK_DIR/$APP_NAME.app"

cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT HUP INT TERM

for tool in swift sips iconutil plutil codesign ditto pkgbuild shasum lipo; do
    command -v "$tool" >/dev/null 2>&1 || { echo "Missing required tool: $tool" >&2; exit 69; }
done

cd "$ROOT_DIR"
EXECUTABLES=()
for arch in arm64 x86_64; do
    swift build -c release --arch "$arch" --product "$PRODUCT"
    BIN_DIR="$(swift build -c release --arch "$arch" --show-bin-path)"
    EXECUTABLES+=("$BIN_DIR/$PRODUCT")
done
for executable in "${EXECUTABLES[@]}"; do
    [[ -x "$executable" ]] || { echo "Missing release executable: $executable" >&2; exit 70; }
done

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$WORK_DIR/AppIcon.iconset" "$OUTPUT_DIR"
lipo -create "${EXECUTABLES[@]}" -output "$APP/Contents/MacOS/$PRODUCT"
chmod 0755 "$APP/Contents/MacOS/$PRODUCT"
install -m 0755 "$SCRIPT_DIR/install-update.sh" "$APP/Contents/Resources/install-update.sh"

PLIST="$APP/Contents/Info.plist"
plutil -create xml1 "$PLIST"
plutil -insert CFBundleDevelopmentRegion -string en "$PLIST"
plutil -insert CFBundleDisplayName -string "$APP_NAME" "$PLIST"
plutil -insert CFBundleExecutable -string "$PRODUCT" "$PLIST"
plutil -insert CFBundleIconFile -string AppIcon.icns "$PLIST"
plutil -insert CFBundleIdentifier -string "$BUNDLE_ID" "$PLIST"
plutil -insert CFBundleInfoDictionaryVersion -string 6.0 "$PLIST"
plutil -insert CFBundleName -string "$APP_NAME" "$PLIST"
plutil -insert CFBundlePackageType -string APPL "$PLIST"
plutil -insert CFBundleShortVersionString -string "$APP_VERSION" "$PLIST"
plutil -insert CFBundleVersion -string "$BUILD_NUMBER" "$PLIST"
plutil -insert LSApplicationCategoryType -string public.app-category.music "$PLIST"
plutil -insert LSMinimumSystemVersion -string 14.0 "$PLIST"
plutil -insert NSHighResolutionCapable -bool YES "$PLIST"
plutil -insert NSPrincipalClass -string NSApplication "$PLIST"
plutil -insert NSAppTransportSecurity -dictionary "$PLIST"
plutil -insert NSAppTransportSecurity.NSAllowsArbitraryLoads -bool YES "$PLIST"
printf 'APPL????' > "$APP/Contents/PkgInfo"

BASE_ICON="$WORK_DIR/AppIcon-1024.png"
xcrun swift "$SCRIPT_DIR/render_icon.swift" "$BASE_ICON"
while read -r pixels name; do
    sips -s format png -z "$pixels" "$pixels" "$BASE_ICON" --out "$WORK_DIR/AppIcon.iconset/$name" >/dev/null
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
iconutil -c icns "$WORK_DIR/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

if [[ "$APP_SIGN_IDENTITY" == "-" ]]; then
    codesign --force --deep --options runtime --sign - --timestamp=none "$APP"
else
    codesign --force --deep --options runtime --sign "$APP_SIGN_IDENTITY" --timestamp "$APP"
fi
codesign --verify --deep --strict --verbose=2 "$APP"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    [[ "$APP_SIGN_IDENTITY" != "-" && -n "$INSTALLER_IDENTITY" ]] || {
        echo "NOTARY_PROFILE requires Developer ID app and installer identities." >&2
        exit 64
    }
    NOTARY_ZIP="$WORK_DIR/Resonance-notary.zip"
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$NOTARY_ZIP"
    xcrun notarytool submit "$NOTARY_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    codesign --verify --deep --strict --verbose=2 "$APP"
fi

ZIP="$OUTPUT_DIR/Resonance-macOS.zip"
PKG="$OUTPUT_DIR/Resonance-macOS.pkg"
rm -f "$ZIP" "$PKG" "$ZIP.sha256" "$PKG.sha256" "$OUTPUT_DIR/latest-mac.json"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

PKG_ARGS=(--component "$APP" --install-location /Applications --identifier "$BUNDLE_ID" --version "$APP_VERSION")
if [[ -n "$INSTALLER_IDENTITY" ]]; then PKG_ARGS+=(--sign "$INSTALLER_IDENTITY"); fi
pkgbuild "${PKG_ARGS[@]}" "$PKG"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$PKG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$PKG"
fi

ZIP_SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
PKG_SHA="$(shasum -a 256 "$PKG" | awk '{print $1}')"
printf '%s  %s\n' "$ZIP_SHA" "$(basename "$ZIP")" > "$ZIP.sha256"
printf '%s  %s\n' "$PKG_SHA" "$(basename "$PKG")" > "$PKG.sha256"

RELEASE_BASE_URL="${RELEASE_BASE_URL:-https://github.com/Drastics-Experiments/resonance/releases/download/v$APP_VERSION}"
printf '{\n  "version": "%s",\n  "build": "%s",\n  "url": "%s/Resonance-macOS.zip",\n  "sha256": "%s"\n}\n' \
    "$APP_VERSION" "$BUILD_NUMBER" "$RELEASE_BASE_URL" "$ZIP_SHA" > "$OUTPUT_DIR/latest-mac.json"

echo "App archive: $ZIP"
echo "Installer: $PKG"
echo "Update manifest: $OUTPUT_DIR/latest-mac.json"
