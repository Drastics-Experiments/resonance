#!/bin/zsh
set -euo pipefail

RES_PROJECT_DIR="${0:A:h}"
source "$RES_PROJECT_DIR/.launcher-terminal.zsh"
RES_APP_DIR="$RES_PROJECT_DIR"
RES_DERIVED_DATA="/private/tmp/resonance-dev-launchers-${UID}/ios-derived-data"
RES_BUNDLE_ID="com.gavindietrich.LikedSongsMobile"

trap res_close_launcher_terminal EXIT

RES_DEVICE_ID="$(/usr/bin/xcrun simctl list devices booted | awk -F '[()]' '/iPhone/ { print $2; exit }')"
if [[ -z "$RES_DEVICE_ID" ]]; then
  RES_DEVICE_ID="$(/usr/bin/xcrun simctl list devices available | awk -F '[()]' '/iPhone 17 \(.*Shutdown/ { print $2; exit }')"
fi
if [[ -z "$RES_DEVICE_ID" ]]; then
  RES_DEVICE_ID="$(/usr/bin/xcrun simctl list devices available | awk -F '[()]' '/iPhone.*Shutdown/ { print $2; exit }')"
fi
[[ -n "$RES_DEVICE_ID" ]] || { echo "No available iPhone Simulator was found." >&2; exit 1; }

/usr/bin/open -a Simulator
/usr/bin/xcrun simctl boot "$RES_DEVICE_ID" 2>/dev/null || true
/usr/bin/xcrun simctl bootstatus "$RES_DEVICE_ID" -b

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

/usr/bin/xcrun simctl terminate "$RES_DEVICE_ID" "$RES_BUNDLE_ID" 2>/dev/null || true
/usr/bin/xcrun simctl install "$RES_DEVICE_ID" "$RES_IOS_APP"
/usr/bin/xcrun simctl launch "$RES_DEVICE_ID" "$RES_BUNDLE_ID"
echo "iOS Resonance launched in Simulator $RES_DEVICE_ID"
