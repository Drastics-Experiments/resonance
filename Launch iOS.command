#!/bin/zsh
set -euo pipefail

RES_PROJECT_DIR="${0:A:h}"
source "$RES_PROJECT_DIR/.launcher-terminal.zsh"
res_prepare_worktree_identity "$RES_PROJECT_DIR"
RES_APP_DIR="$RES_PROJECT_DIR"
RES_DERIVED_DATA="$RES_LAUNCHER_ROOT/ios-derived-data"
RES_IOS_INSTANCE_NAME="Resonance iOS [${RES_WORKTREE_LABEL}]"
RES_SIMULATOR_NAME="Resonance iOS ${RES_WORKTREE_LABEL}"
RES_BUNDLE_ID="com.gavindietrich.LikedSongsMobile.worktree.w${RES_WORKTREE_HASH}"

trap res_close_launcher_terminal EXIT

RES_DEVICE_ID="$(/usr/bin/xcrun simctl list devices available \
  | awk -F '[()]' -v name="$RES_SIMULATOR_NAME" \
    '$1 ~ "^[[:space:]]*" name "[[:space:]]*$" { print $2; exit }')"
if [[ -z "$RES_DEVICE_ID" ]]; then
  RES_DEVICE_TYPE="$(/usr/bin/xcrun simctl list devicetypes \
    | awk -F '[()]' '/^iPhone 17[[:space:]]*\(/ { print $2; exit }')"
  if [[ -z "$RES_DEVICE_TYPE" ]]; then
    RES_DEVICE_TYPE="$(/usr/bin/xcrun simctl list devicetypes \
      | awk -F '[()]' '/^iPhone / { print $2; exit }')"
  fi
  [[ -n "$RES_DEVICE_TYPE" ]] || { echo "No available iPhone Simulator device type was found." >&2; exit 1; }
  RES_DEVICE_ID="$(/usr/bin/xcrun simctl create "$RES_SIMULATOR_NAME" "$RES_DEVICE_TYPE")"
fi
[[ -n "$RES_DEVICE_ID" ]] || { echo "No available iPhone Simulator was found." >&2; exit 1; }

/usr/bin/xcrun simctl boot "$RES_DEVICE_ID" 2>/dev/null || true
/usr/bin/xcrun simctl bootstatus "$RES_DEVICE_ID" -b
/usr/bin/open -a Simulator --args -CurrentDeviceUDID "$RES_DEVICE_ID"

echo "Building the iOS Simulator development app…"
/usr/bin/xcodebuild -quiet \
  -project "$RES_APP_DIR/ios/LikedSongsMobile.xcodeproj" \
  -scheme LikedSongsMobile \
  -configuration Debug \
  -sdk iphonesimulator \
  -destination "id=$RES_DEVICE_ID" \
  -derivedDataPath "$RES_DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  build

RES_IOS_APP="$RES_DERIVED_DATA/Build/Products/Debug-iphonesimulator/Resonance.app"
[[ -d "$RES_IOS_APP" ]] || { echo "iOS build did not produce $RES_IOS_APP" >&2; exit 1; }

# Simulator builds are unsigned, so give the built artifact a worktree-specific
# identity without changing production Xcode metadata.
RES_IOS_PLIST="$RES_IOS_APP/Info.plist"
/usr/bin/plutil -replace CFBundleDisplayName -string "$RES_IOS_INSTANCE_NAME" "$RES_IOS_PLIST"
/usr/bin/plutil -replace CFBundleName -string "$RES_IOS_INSTANCE_NAME" "$RES_IOS_PLIST"
/usr/bin/plutil -replace CFBundleIdentifier -string "$RES_BUNDLE_ID" "$RES_IOS_PLIST"

/usr/bin/xcrun simctl terminate "$RES_DEVICE_ID" "$RES_BUNDLE_ID" 2>/dev/null || true
/usr/bin/xcrun simctl install "$RES_DEVICE_ID" "$RES_IOS_APP"
/usr/bin/xcrun simctl launch "$RES_DEVICE_ID" "$RES_BUNDLE_ID"
echo "$RES_IOS_INSTANCE_NAME launched in $RES_SIMULATOR_NAME ($RES_DEVICE_ID)"
