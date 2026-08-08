#!/bin/zsh
set -euo pipefail

RES_PROJECT_DIR="${0:A:h}"
source "$RES_PROJECT_DIR/.launcher-terminal.zsh"
res_prepare_worktree_identity "$RES_PROJECT_DIR"
RES_APP_DIR="$RES_PROJECT_DIR"
RES_DERIVED_DATA="$RES_IOS_DERIVED_DATA"
RES_SIMULATOR_NAME="$RES_IOS_SIMULATOR_NAME"
RES_BUNDLE_ID="$RES_IOS_BUNDLE_ID"

trap res_close_launcher_terminal EXIT
res_write_instance_registry
res_set_terminal_title "$RES_IOS_INSTANCE_NAME"

res_ensure_ios_simulator
RES_DEVICE_ID="$RES_IOS_DEVICE_ID"

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
echo "Deterministic selectors: $RES_INSTANCE_REGISTRY"
