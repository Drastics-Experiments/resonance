#!/usr/bin/env bash

set -euo pipefail

# Build the shared Electron desktop client for macOS. The app source remains
# in windows/ for now so the Windows and macOS clients exercise the same main
# process, preload bridge, and renderer. This path intentionally does not
# invoke Swift or build the legacy macOS target.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAC_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_DIR="$(cd "$MAC_DIR/.." && pwd)"
WINDOWS_DIR="$REPO_DIR/windows"
CONFIG="$MAC_DIR/electron-builder.yml"
OUTPUT_DIR="$REPO_DIR/installers/macos/dist"
BUILD_ROOT="${TMPDIR:-/tmp}/resonance-electron-macos.$$"
FFMPEG_BINARY=""
FFMPEG_ORIGINAL=""

cleanup() {
    if [[ -n "$FFMPEG_BINARY" && -n "$FFMPEG_ORIGINAL" && -f "$FFMPEG_ORIGINAL" ]]; then
        cp -p "$FFMPEG_ORIGINAL" "$FFMPEG_BINARY"
    fi
    rm -rf "$BUILD_ROOT"
}
trap cleanup EXIT HUP INT TERM

[[ -d "$WINDOWS_DIR" ]] || { echo "Missing Electron project: $WINDOWS_DIR" >&2; exit 66; }
[[ -f "$WINDOWS_DIR/package.json" ]] || { echo "Missing Electron package metadata." >&2; exit 66; }
[[ -f "$CONFIG" ]] || { echo "Missing macOS electron-builder config: $CONFIG" >&2; exit 66; }
[[ -x "$WINDOWS_DIR/node_modules/.bin/electron-builder" ]] || {
    echo "Electron dependencies are not installed. Run 'corepack pnpm install --frozen-lockfile' in windows/." >&2
    exit 69
}

MAC_ARCH="${MAC_ARCH:-$(uname -m)}"
if [[ "$MAC_ARCH" == "x86_64" ]]; then MAC_ARCH=x64; fi
case "$MAC_ARCH" in
    arm64|x64|universal) ;;
    *) echo "MAC_ARCH must be arm64, x64, or universal (got: $MAC_ARCH)." >&2; exit 64 ;;
esac

MAC_UPDATE_AUTHENTICITY="${MAC_UPDATE_AUTHENTICITY:-development}"
case "$MAC_UPDATE_AUTHENTICITY" in
    development|production) ;;
    *) echo "MAC_UPDATE_AUTHENTICITY must be development or production." >&2; exit 64 ;;
esac
MAC_UPDATE_TEAM_ID="${MAC_UPDATE_TEAM_ID:-}"
MAC_UPDATE_DESIGNATED_REQUIREMENT="${MAC_UPDATE_DESIGNATED_REQUIREMENT:-}"
if [[ "$MAC_UPDATE_AUTHENTICITY" == "production" ]]; then
    [[ "$MAC_UPDATE_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || {
        echo "Production macOS packaging requires MAC_UPDATE_TEAM_ID." >&2
        exit 64
    }
    [[ -n "$MAC_UPDATE_DESIGNATED_REQUIREMENT" && "$MAC_UPDATE_DESIGNATED_REQUIREMENT" != *$'\n'* && "$MAC_UPDATE_DESIGNATED_REQUIREMENT" != *$'\r'* ]] || {
        echo "Production macOS packaging requires a single-line MAC_UPDATE_DESIGNATED_REQUIREMENT." >&2
        exit 64
    }
fi

cd "$WINDOWS_DIR"
APP_VERSION="${APP_VERSION:-$(node -p 'require("./package.json").version')}"
BUILD_NUMBER="${BUILD_NUMBER:-$(node -p 'require("./package.json").resonanceBuild')}"
RELEASE_BASE_URL="${RELEASE_BASE_URL:-https://github.com/Drastics-Experiments/resonance/releases/download/v${APP_VERSION}}"

mkdir -p "$OUTPUT_DIR" "$BUILD_ROOT"

# electron-builder shells out to the package manager named by the lockfile.
# Corepack installations may expose only `corepack`, so provide a temporary
# pnpm-named shim that Corepack dispatches by argv[0].
if ! command -v pnpm >/dev/null 2>&1; then
    COREPACK_BINARY="$(command -v corepack || true)"
    [[ -n "$COREPACK_BINARY" ]] || {
        echo "The macOS package requires pnpm or Corepack on PATH." >&2
        exit 69
    }
    printf '#!/bin/sh\nexec "%s" pnpm "$@"\n' "$COREPACK_BINARY" > "$BUILD_ROOT/pnpm"
    chmod 0755 "$BUILD_ROOT/pnpm"
    export PATH="$BUILD_ROOT:$PATH"
fi

rm -f \
    "$OUTPUT_DIR/Resonance-macOS.zip" \
    "$OUTPUT_DIR/Resonance-macOS.zip.sha256" \
    "$OUTPUT_DIR/Resonance-Installer.pkg" \
    "$OUTPUT_DIR/latest-mac.json"

# Avoid accidentally signing a local development build with a user's
# production identity. electron-builder expects the literal string "false"
# here; numeric 0 is truthy to its environment parser. Release automation can
# explicitly provide a signing identity and set CSC_IDENTITY_AUTO_DISCOVERY=true.
if [[ "${CSC_IDENTITY_AUTO_DISCOVERY:-false}" == "0" ]]; then
    CSC_IDENTITY_AUTO_DISCOVERY=false
fi
export CSC_IDENTITY_AUTO_DISCOVERY="${CSC_IDENTITY_AUTO_DISCOVERY:-false}"

ffmpeg_supports_arch() {
    local architecture="$1"
    local details
    details="$(file "$FFMPEG_BINARY")"
    case "$architecture" in
        arm64) grep -Eq 'arm64|universal' <<< "$details" ;;
        x64) grep -Eq 'x86_64|universal' <<< "$details" ;;
        *) return 1 ;;
    esac
}

rebuild_ffmpeg_for() {
    local architecture="$1"
    local package_dir
    local download_dir="$BUILD_ROOT/ffmpeg-$architecture"
    package_dir="$(dirname "$FFMPEG_BINARY")"
    mkdir -p "$download_dir"
    # Run ffmpeg-static's installer directly into a temporary destination. It
    # honors npm_config_arch and FFMPEG_BIN, so the project dependency tree is
    # not rebuilt or left with x64 sidecars after this universal preflight.
    FFMPEG_BIN="$download_dir/ffmpeg" npm_config_arch="$architecture" \
        node "$package_dir/install.js"
    [[ -f "$download_dir/ffmpeg" ]] || {
        echo "ffmpeg-static did not produce a macOS $architecture binary." >&2
        exit 72
    }
    cp -p "$download_dir/ffmpeg" "$FFMPEG_BINARY"
}

prepare_ffmpeg() {
    command -v file >/dev/null 2>&1 || { echo "The macOS package requires the file utility." >&2; exit 69; }
    FFMPEG_BINARY="$(node -p 'require("ffmpeg-static")')"
    [[ -f "$FFMPEG_BINARY" ]] || { echo "Missing ffmpeg-static binary: $FFMPEG_BINARY" >&2; exit 72; }
    FFMPEG_ORIGINAL="$BUILD_ROOT/ffmpeg.original"
    cp -p "$FFMPEG_BINARY" "$FFMPEG_ORIGINAL"

    case "$MAC_ARCH" in
        arm64|x64)
            ffmpeg_supports_arch "$MAC_ARCH" || rebuild_ffmpeg_for "$MAC_ARCH"
            ;;
        universal)
            command -v lipo >/dev/null 2>&1 || { echo "The universal macOS package requires lipo." >&2; exit 69; }
            local arm_binary="$BUILD_ROOT/ffmpeg.arm64"
            local x64_binary="$BUILD_ROOT/ffmpeg.x64"
            ffmpeg_supports_arch arm64 || rebuild_ffmpeg_for arm64
            cp -p "$FFMPEG_BINARY" "$arm_binary"
            ffmpeg_supports_arch x64 || rebuild_ffmpeg_for x64
            cp -p "$FFMPEG_BINARY" "$x64_binary"
            rm -f "$FFMPEG_BINARY"
            lipo -create "$arm_binary" "$x64_binary" -output "$FFMPEG_BINARY"
            chmod 0755 "$FFMPEG_BINARY"
            ffmpeg_supports_arch arm64 && ffmpeg_supports_arch x64 || {
                echo "The universal ffmpeg-static binary is missing arm64 or x86_64." >&2
                exit 72
            }
            ;;
    esac
}

prepare_ffmpeg

ARCH_FLAG="--$MAC_ARCH"
UPDATE_CONFIG_ARGS=(
  "--config.extraMetadata.resonanceUpdateAuthenticity=$MAC_UPDATE_AUTHENTICITY"
  "--config.mac.extendInfo.ResonanceUpdateAuthenticity=$MAC_UPDATE_AUTHENTICITY"
)
if [[ "$MAC_UPDATE_AUTHENTICITY" == "production" ]]; then
    UPDATE_CONFIG_ARGS+=(
        "--config.mac.extendInfo.ResonanceUpdateTeamIdentifier=$MAC_UPDATE_TEAM_ID"
        "--config.mac.extendInfo.ResonanceUpdateDesignatedRequirement=$MAC_UPDATE_DESIGNATED_REQUIREMENT"
    )
else
    # Ordinary local/CI apps still need an ad-hoc signature so macOS can
    # validate the complete bundle after electron-builder rewrites metadata.
    UPDATE_CONFIG_ARGS+=(
        "--config.mac.identity=-"
        "--config.mac.hardenedRuntime=false"
    )
fi
"$WINDOWS_DIR/node_modules/.bin/electron-builder" \
    --config "$CONFIG" \
    --mac \
    "$ARCH_FLAG" \
    --publish never \
    --config.extraMetadata.version="$APP_VERSION" \
    --config.buildVersion="$BUILD_NUMBER" \
    --config.extraMetadata.resonanceBuild="$BUILD_NUMBER" \
    "${UPDATE_CONFIG_ARGS[@]}"

# The macOS release contract publishes the ZIP, its SHA-256 sidecar, the PKG,
# and latest-mac.json. electron-builder's update block map and debug metadata
# are useful while diagnosing a build but are not compatibility artifacts.
rm -f \
    "$OUTPUT_DIR/Resonance-macOS.zip.blockmap" \
    "$OUTPUT_DIR/builder-debug.yml" \
    "$OUTPUT_DIR/com.gavindietrich.LikedSongsFocus.plist"

BUILT_ZIP="$OUTPUT_DIR/Resonance-macOS.zip"
BUILT_PKG="$OUTPUT_DIR/Resonance-macOS.pkg"
[[ -f "$BUILT_ZIP" ]] || { echo "electron-builder did not produce $BUILT_ZIP" >&2; exit 70; }
[[ -f "$BUILT_PKG" ]] || { echo "electron-builder did not produce $BUILT_PKG" >&2; exit 70; }

mv "$BUILT_PKG" "$OUTPUT_DIR/Resonance-Installer.pkg"

ZIP_SHA="$(shasum -a 256 "$BUILT_ZIP" | awk '{print $1}')"
printf '%s  %s\n' "$ZIP_SHA" "$(basename "$BUILT_ZIP")" > "$OUTPUT_DIR/Resonance-macOS.zip.sha256"

printf '{\n  "version": "%s",\n  "build": "%s",\n  "url": "%s/Resonance-macOS.zip",\n  "sha256": "%s"\n}\n' \
    "$APP_VERSION" "$BUILD_NUMBER" "${RELEASE_BASE_URL%/}" "$ZIP_SHA" \
    > "$OUTPUT_DIR/latest-mac.json"

# Fail early if electron-builder ever regresses the compatibility identity,
# updater helper payload, or universal ffmpeg slices.
if command -v unzip >/dev/null 2>&1 && command -v plutil >/dev/null 2>&1; then
    VERIFY_DIR="$BUILD_ROOT/verify"
    mkdir -p "$VERIFY_DIR"
    unzip -q "$BUILT_ZIP" -d "$VERIFY_DIR"
    APP_PLIST="$VERIFY_DIR/Resonance.app/Contents/Info.plist"
    [[ -f "$APP_PLIST" ]] || { echo "The macOS ZIP has no Resonance.app bundle." >&2; exit 71; }
    APP_ID="$(plutil -extract CFBundleIdentifier raw "$APP_PLIST")"
    [[ "$APP_ID" == "com.gavindietrich.LikedSongsFocus" ]] || {
        echo "Unexpected macOS bundle identifier: $APP_ID" >&2
        exit 71
    }
    [[ -x "$VERIFY_DIR/Resonance.app/Contents/Resources/install-update.sh" ]] || {
        echo "The macOS Electron app is missing executable install-update.sh resources." >&2
        exit 71
    }
    UPDATE_MODE="$(plutil -extract ResonanceUpdateAuthenticity raw "$APP_PLIST")"
    [[ "$UPDATE_MODE" == "$MAC_UPDATE_AUTHENTICITY" ]] || {
        echo "The macOS Electron app has no compatibility updater policy." >&2
        exit 71
    }
    if [[ "$MAC_UPDATE_AUTHENTICITY" == "production" ]]; then
        plutil -extract ResonanceUpdateTeamIdentifier raw "$APP_PLIST" | grep -Fxq "$MAC_UPDATE_TEAM_ID" || {
            echo "The packaged macOS updater Team ID does not match the requested identity." >&2
            exit 71
        }
        plutil -extract ResonanceUpdateDesignatedRequirement raw "$APP_PLIST" | grep -Fxq "$MAC_UPDATE_DESIGNATED_REQUIREMENT" || {
            echo "The packaged macOS updater designated requirement does not match the requested identity." >&2
            exit 71
        }
    fi
    if [[ "$MAC_ARCH" == "universal" ]]; then
        PACKAGED_FFMPEG="$(find "$VERIFY_DIR/Resonance.app/Contents/Resources" -type f -path '*/ffmpeg-static/ffmpeg' -print -quit)"
        [[ -n "$PACKAGED_FFMPEG" ]] || { echo "The universal app is missing ffmpeg-static." >&2; exit 72; }
        PACKAGED_FFMPEG_INFO="$(file "$PACKAGED_FFMPEG")"
        grep -Eq 'arm64' <<< "$PACKAGED_FFMPEG_INFO" || { echo "Packaged ffmpeg is missing arm64." >&2; exit 72; }
        grep -Eq 'x86_64' <<< "$PACKAGED_FFMPEG_INFO" || { echo "Packaged ffmpeg is missing x86_64." >&2; exit 72; }
    fi
fi

echo "Built Electron macOS artifacts in $OUTPUT_DIR ($MAC_ARCH)."
