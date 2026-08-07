#!/bin/zsh
set -euo pipefail

RES_PROJECT_DIR="${0:A:h}"
source "$RES_PROJECT_DIR/.launcher-terminal.zsh"
RES_APP_DIR="$RES_PROJECT_DIR"
RES_ANDROID_DIR="$RES_APP_DIR/android"
RES_ANDROID_SDK="$HOME/Library/Android/sdk"
RES_JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
RES_ADB="$RES_ANDROID_SDK/platform-tools/adb"
RES_EMULATOR="$RES_ANDROID_SDK/emulator/emulator"
RES_AVD="Resonance_API_36"
RES_RUN_DIR="/private/tmp/resonance-dev-launchers-${UID}"
RES_EMULATOR_LOG="$RES_RUN_DIR/android-emulator.log"
RES_ONESHOT_LABEL="codex.resonance-emulator.oneshot"
RES_EMULATOR_PLIST="$RES_RUN_DIR/$RES_ONESHOT_LABEL.plist"
RES_RESTART_LABELS=(
  codex.resonance-emulator
  codex.resonance-mobile-tools-open
  mov.unblocked.resonance-emulator
)

trap res_close_launcher_terminal EXIT

[[ -x "$RES_ADB" ]] || { echo "Android adb was not found at $RES_ADB" >&2; exit 1; }
[[ -x "$RES_EMULATOR" ]] || { echo "Android emulator was not found at $RES_EMULATOR" >&2; exit 1; }
[[ -x "$RES_JAVA_HOME/bin/java" ]] || { echo "Android Studio's JDK was not found." >&2; exit 1; }
mkdir -p "$RES_RUN_DIR"

echo "Building the Android development APK…"
cd "$RES_ANDROID_DIR"
JAVA_HOME="$RES_JAVA_HOME" ANDROID_HOME="$RES_ANDROID_SDK" ./gradlew --no-daemon assembleDebug

# Remove old keep-alive jobs so closing the emulator leaves it closed.
RES_REMOVED_RESTART_JOB=false
for RES_RESTART_LABEL in "${RES_RESTART_LABELS[@]}"; do
  if /bin/launchctl print "gui/${UID}/$RES_RESTART_LABEL" >/dev/null 2>&1; then
    /bin/launchctl remove "$RES_RESTART_LABEL" 2>/dev/null || true
    RES_REMOVED_RESTART_JOB=true
  fi
done

if [[ "$RES_REMOVED_RESTART_JOB" == true ]]; then
  for _ in {1..30}; do
    RES_SERIAL="$($RES_ADB devices | awk '/^emulator-[0-9]+[[:space:]]+device$/ { print $1; exit }')"
    [[ -z "$RES_SERIAL" ]] && break
    sleep 1
  done
fi

RES_SERIAL="$($RES_ADB devices | awk '/^emulator-[0-9]+[[:space:]]+device$/ { print $1; exit }')"
if [[ -z "$RES_SERIAL" ]]; then
  /bin/launchctl bootout "gui/${UID}/$RES_ONESHOT_LABEL" 2>/dev/null || true
  : >"$RES_EMULATOR_LOG"
  /usr/bin/plutil -create xml1 "$RES_EMULATOR_PLIST"
  /usr/bin/plutil -insert Label -string "$RES_ONESHOT_LABEL" "$RES_EMULATOR_PLIST"
  /usr/bin/plutil -insert ProgramArguments -array "$RES_EMULATOR_PLIST"
  /usr/bin/plutil -insert ProgramArguments.0 -string "$RES_EMULATOR" "$RES_EMULATOR_PLIST"
  /usr/bin/plutil -insert ProgramArguments.1 -string "@$RES_AVD" "$RES_EMULATOR_PLIST"
  /usr/bin/plutil -insert ProgramArguments.2 -string -no-audio "$RES_EMULATOR_PLIST"
  /usr/bin/plutil -insert ProgramArguments.3 -string -no-boot-anim "$RES_EMULATOR_PLIST"
  /usr/bin/plutil -insert ProgramArguments.4 -string -no-snapshot-save "$RES_EMULATOR_PLIST"
  /usr/bin/plutil -insert RunAtLoad -bool YES "$RES_EMULATOR_PLIST"
  /usr/bin/plutil -insert KeepAlive -bool NO "$RES_EMULATOR_PLIST"
  /usr/bin/plutil -insert ProcessType -string Interactive "$RES_EMULATOR_PLIST"
  /usr/bin/plutil -insert StandardOutPath -string "$RES_EMULATOR_LOG" "$RES_EMULATOR_PLIST"
  /usr/bin/plutil -insert StandardErrorPath -string "$RES_EMULATOR_LOG" "$RES_EMULATOR_PLIST"
  /bin/launchctl bootstrap "gui/${UID}" "$RES_EMULATOR_PLIST"
  for _ in {1..60}; do
    RES_SERIAL="$($RES_ADB devices | awk '/^emulator-[0-9]+[[:space:]]+device$/ { print $1; exit }')"
    [[ -n "$RES_SERIAL" ]] && break
    sleep 1
  done
fi
[[ -n "$RES_SERIAL" ]] || { echo "Android emulator did not appear within 60 seconds." >&2; exit 1; }

for _ in {1..60}; do
  [[ "$($RES_ADB -s "$RES_SERIAL" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == "1" ]] && break
  sleep 1
done
[[ "$($RES_ADB -s "$RES_SERIAL" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == "1" ]] \
  || { echo "Android emulator did not finish booting within 60 seconds." >&2; exit 1; }

RES_APK="$RES_ANDROID_DIR/app/build/outputs/apk/debug/app-debug.apk"
[[ -f "$RES_APK" ]] || { echo "Android build did not produce $RES_APK" >&2; exit 1; }

"$RES_ADB" -s "$RES_SERIAL" install -r "$RES_APK"
"$RES_ADB" -s "$RES_SERIAL" shell am force-stop mov.unblocked.resonance
"$RES_ADB" -s "$RES_SERIAL" shell am start -n mov.unblocked.resonance/.MainActivity
echo "Android Resonance launched on $RES_SERIAL"
