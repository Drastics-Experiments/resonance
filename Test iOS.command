#!/bin/zsh
set -euo pipefail

RES_PROJECT_DIR="${0:A:h}"
source "$RES_PROJECT_DIR/.launcher-terminal.zsh"
res_prepare_worktree_identity "$RES_PROJECT_DIR"
res_write_instance_registry
res_set_terminal_title "$RES_IOS_TEST_NAME"

trap res_close_launcher_terminal EXIT
export RESONANCE_WORKTREE_ID="$RES_WORKTREE_ID"
export RESONANCE_PROCESS_NAME="$RES_IOS_TEST_NAME"

echo "Running $RES_IOS_TEST_NAME"
echo "Deterministic selectors: $RES_INSTANCE_REGISTRY"
res_ensure_ios_simulator "$RES_IOS_TEST_SIMULATOR_NAME"
/usr/bin/xcrun simctl boot "$RES_IOS_DEVICE_ID" 2>/dev/null || true
/usr/bin/xcrun simctl bootstatus "$RES_IOS_DEVICE_ID" -b

res_run_named_process "$RES_IOS_TEST_NAME" /usr/bin/xcodebuild -quiet \
  -project "$RES_PROJECT_DIR/ios/LikedSongsMobile.xcodeproj" \
  -scheme LikedSongsMobile \
  -configuration Debug \
  -sdk iphonesimulator \
  -destination "id=$RES_IOS_DEVICE_ID" \
  -derivedDataPath "$RES_IOS_DERIVED_DATA/tests" \
  CODE_SIGNING_ALLOWED=NO \
  test

echo "$RES_IOS_TEST_NAME passed"
