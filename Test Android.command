#!/bin/zsh
set -euo pipefail

RES_PROJECT_DIR="${0:A:h}"
source "$RES_PROJECT_DIR/.launcher-terminal.zsh"
res_prepare_worktree_identity "$RES_PROJECT_DIR"
res_write_instance_registry
res_set_terminal_title "$RES_ANDROID_TEST_NAME"

trap res_close_launcher_terminal EXIT
export RESONANCE_WORKTREE_ID="$RES_WORKTREE_ID"
export RESONANCE_PROCESS_NAME="$RES_ANDROID_TEST_NAME"

RES_ANDROID_SDK="$HOME/Library/Android/sdk"
RES_JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
[[ -x "$RES_JAVA_HOME/bin/java" ]] || { echo "Android Studio's JDK was not found." >&2; exit 1; }

echo "Running $RES_ANDROID_TEST_NAME"
echo "Deterministic selectors: $RES_INSTANCE_REGISTRY"
cd "$RES_PROJECT_DIR/android"
export JAVA_HOME="$RES_JAVA_HOME"
export ANDROID_HOME="$RES_ANDROID_SDK"
res_run_named_process "$RES_ANDROID_TEST_NAME" /bin/sh ./gradlew --no-daemon \
  "-PresonanceInstanceSuffix=.worktree.w${RES_WORKTREE_HASH}" \
  "-PresonanceInstanceName=$RES_ANDROID_INSTANCE_NAME" \
  lintDebug testDebugUnitTest assembleDebug
