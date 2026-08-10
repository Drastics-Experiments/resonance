#!/usr/bin/env bash

set -euo pipefail

PRODUCT="Resonance"
APP_NAME="Resonance"
# Existing installations require this external identity for in-place updates.
BUNDLE_ID="com.gavindietrich.Liked""SongsFocus"
DISCORD_APPLICATION_ID="1535574125395841154"
APP_VERSION="${APP_VERSION:-1.1.5}"
BUILD_NUMBER="${BUILD_NUMBER:-16}"
APP_SIGN_IDENTITY="${MACOS_APP_IDENTITY:--}"
INSTALLER_IDENTITY="${MACOS_INSTALLER_IDENTITY:-}"
PRODUCTION_SIGNING_REQUIRED="${RESONANCE_REQUIRE_PRODUCTION_SIGNING:-0}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
NOTARY_KEY_PATH="${NOTARY_KEY_PATH:-}"
NOTARY_KEY_ID="${NOTARY_KEY_ID:-}"
NOTARY_ISSUER_ID="${NOTARY_ISSUER_ID:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_DIR="$(cd "$ROOT_DIR/.." && pwd)"
OUTPUT_DIR="$REPO_DIR/installers/macos/dist"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/resonance-release.XXXXXX")"
APP="$WORK_DIR/$APP_NAME.app"

cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT HUP INT TERM

for tool in swift sips iconutil plutil codesign ditto pkgbuild pkgutil shasum lipo spctl xcrun; do
    command -v "$tool" >/dev/null 2>&1 || { echo "Missing required tool: $tool" >&2; exit 69; }
done

case "$PRODUCTION_SIGNING_REQUIRED" in
    0|1) ;;
    *) echo "RESONANCE_REQUIRE_PRODUCTION_SIGNING must be 0 or 1." >&2; exit 64 ;;
esac

NOTARY_API_CONFIGURED=0
if [[ -n "$NOTARY_KEY_PATH" || -n "$NOTARY_KEY_ID" || -n "$NOTARY_ISSUER_ID" ]]; then
    [[ -f "$NOTARY_KEY_PATH" && -n "$NOTARY_KEY_ID" && -n "$NOTARY_ISSUER_ID" ]] || {
        echo "Notary API authentication requires NOTARY_KEY_PATH, NOTARY_KEY_ID, and NOTARY_ISSUER_ID." >&2
        exit 64
    }
    NOTARY_API_CONFIGURED=1
fi
if [[ -n "$NOTARY_PROFILE" && "$NOTARY_API_CONFIGURED" == "1" ]]; then
    echo "Configure either NOTARY_PROFILE or Notary API authentication, not both." >&2
    exit 64
fi

if [[ "$PRODUCTION_SIGNING_REQUIRED" == "1" ]]; then
    [[ "$APP_SIGN_IDENTITY" == "Developer ID Application:"* ]] || {
        echo "A Developer ID Application identity is required for a production release." >&2
        exit 64
    }
    [[ "$INSTALLER_IDENTITY" == "Developer ID Installer:"* ]] || {
        echo "A Developer ID Installer identity is required for a production release." >&2
        exit 64
    }
    [[ -n "$NOTARY_PROFILE" || "$NOTARY_API_CONFIGURED" == "1" ]] || {
        echo "Notary authentication is required for a production release." >&2
        exit 64
    }
fi

submit_for_notarization() {
    local artifact="$1"
    if [[ -n "$NOTARY_PROFILE" ]]; then
        xcrun notarytool submit "$artifact" --keychain-profile "$NOTARY_PROFILE" --wait
    else
        xcrun notarytool submit "$artifact" \
            --key "$NOTARY_KEY_PATH" \
            --key-id "$NOTARY_KEY_ID" \
            --issuer "$NOTARY_ISSUER_ID" \
            --wait
    fi
}

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
plutil -insert CFBundleURLTypes -json '[{"CFBundleURLName":"Resonance Account Sign-In","CFBundleURLSchemes":["resonance"]}]' "$PLIST"
plutil -insert ResonanceDiscordApplicationID -string "$DISCORD_APPLICATION_ID" "$PLIST"
plutil -insert LSApplicationCategoryType -string public.app-category.music "$PLIST"
plutil -insert LSMinimumSystemVersion -string 14.0 "$PLIST"
plutil -insert NSHighResolutionCapable -bool YES "$PLIST"
plutil -insert NSPrincipalClass -string NSApplication "$PLIST"
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

if [[ "$PRODUCTION_SIGNING_REQUIRED" == "1" ]]; then
    APP_SIGNATURE_DETAILS="$(codesign --display --verbose=4 "$APP" 2>&1)"
    grep -Fqx "Authority=$APP_SIGN_IDENTITY" <<< "$APP_SIGNATURE_DETAILS" || {
        echo "The app is not signed by the configured Developer ID Application certificate." >&2
        exit 65
    }
    grep -Eq '^Timestamp=.+' <<< "$APP_SIGNATURE_DETAILS" || {
        echo "The app signature does not have a secure timestamp." >&2
        exit 65
    }
    grep -Eq 'flags=.*\(runtime\)' <<< "$APP_SIGNATURE_DETAILS" || {
        echo "The app signature does not enable the hardened runtime." >&2
        exit 65
    }
fi

if [[ -n "$NOTARY_PROFILE" || "$NOTARY_API_CONFIGURED" == "1" ]]; then
    [[ "$APP_SIGN_IDENTITY" != "-" && -n "$INSTALLER_IDENTITY" ]] || {
        echo "Notarization requires Developer ID app and installer identities." >&2
        exit 64
    }
    NOTARY_ZIP="$WORK_DIR/Resonance-notary.zip"
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$NOTARY_ZIP"
    submit_for_notarization "$NOTARY_ZIP"
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    codesign --verify --deep --strict --verbose=2 "$APP"
    if [[ "$PRODUCTION_SIGNING_REQUIRED" == "1" ]]; then
        spctl --assess --type execute --verbose=4 "$APP"
    fi
fi

ZIP="$OUTPUT_DIR/Resonance-macOS.zip"
INSTALLER="$OUTPUT_DIR/Resonance-Installer.pkg"
rm -f "$ZIP" "$INSTALLER" "$ZIP.sha256" "$OUTPUT_DIR/latest-mac.json" \
    "$OUTPUT_DIR/Resonance-macOS.pkg" "$OUTPUT_DIR/Resonance-macOS.pkg.sha256"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

ZIP_SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
printf '%s  %s\n' "$ZIP_SHA" "$(basename "$ZIP")" > "$ZIP.sha256"

RELEASE_BASE_URL="${RELEASE_BASE_URL:-https://github.com/Drastics-Experiments/resonance/releases/download/v$APP_VERSION}"
printf '{\n  "version": "%s",\n  "build": "%s",\n  "url": "%s/Resonance-macOS.zip",\n  "sha256": "%s"\n}\n' \
    "$APP_VERSION" "$BUILD_NUMBER" "$RELEASE_BASE_URL" "$ZIP_SHA" > "$OUTPUT_DIR/latest-mac.json"

PKG_ROOT="$WORK_DIR/pkg-root"
mkdir -p "$PKG_ROOT/Applications"
ditto "$APP" "$PKG_ROOT/Applications/$APP_NAME.app"
PKG_ARGS=(--root "$PKG_ROOT" --install-location / --identifier "$BUNDLE_ID.installer" --version "$APP_VERSION")
if [[ -n "$INSTALLER_IDENTITY" ]]; then PKG_ARGS+=(--sign "$INSTALLER_IDENTITY"); fi
COPYFILE_DISABLE=1 pkgbuild "${PKG_ARGS[@]}" "$INSTALLER"

if ! pkgutil --payload-files "$INSTALLER" | grep -Eq '(^|/)Applications/Resonance\.app/Contents/MacOS/Resonance$'; then
    echo "The macOS installer does not contain the Resonance application payload." >&2
    exit 70
fi

if [[ -n "$NOTARY_PROFILE" || "$NOTARY_API_CONFIGURED" == "1" ]]; then
    submit_for_notarization "$INSTALLER"
    xcrun stapler staple "$INSTALLER"
    xcrun stapler validate "$INSTALLER"
fi

if [[ "$PRODUCTION_SIGNING_REQUIRED" == "1" ]]; then
    INSTALLER_SIGNATURE_DETAILS="$(pkgutil --check-signature "$INSTALLER" 2>&1)"
    grep -Fq "$INSTALLER_IDENTITY" <<< "$INSTALLER_SIGNATURE_DETAILS" || {
        echo "The installer is not signed by the configured Developer ID Installer certificate." >&2
        exit 65
    }
    spctl --assess --type install --verbose=4 "$INSTALLER"
fi

echo "App archive: $ZIP"
echo "Installer: $INSTALLER"
echo "Update manifest: $OUTPUT_DIR/latest-mac.json"
