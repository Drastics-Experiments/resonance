#!/bin/zsh

# Resolve a stable, readable identity for the Git worktree containing a
# launcher. Every platform launcher uses these values so builds, logs, bundle
# identifiers, application data, and visible app names do not collide when
# multiple agents work in parallel.
res_prepare_worktree_identity() {
  local res_requested_root="${1:A}"
  local res_git_root
  res_git_root="$(/usr/bin/git -C "$res_requested_root" rev-parse --show-toplevel 2>/dev/null)" \
    || { echo "$res_requested_root is not a Git worktree." >&2; return 1; }
  res_git_root="${res_git_root:A}"
  [[ "$res_git_root" == "$res_requested_root" ]] \
    || { echo "Launchers must run from the Git worktree root: $res_git_root" >&2; return 1; }

  local res_directory_name="${res_git_root:t}"
  local res_slug
  res_slug="$(/usr/bin/printf '%s' "$res_directory_name" \
    | /usr/bin/tr '[:upper:]' '[:lower:]' \
    | /usr/bin/sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g' \
    | /usr/bin/cut -c 1-40)"
  [[ -n "$res_slug" ]] || res_slug="worktree"

  local res_hash
  res_hash="$(/usr/bin/printf '%s' "$res_git_root" | /usr/bin/shasum -a 256 | /usr/bin/awk '{ print $1 }')"

  typeset -g RES_WORKTREE_PATH="$res_git_root"
  typeset -g RES_WORKTREE_SLUG="$res_slug"
  typeset -g RES_WORKTREE_HASH_FULL="$res_hash"
  typeset -g RES_WORKTREE_HASH="${res_hash[1,12]}"
  typeset -g RES_WORKTREE_ID="${res_slug}-${RES_WORKTREE_HASH}"
  typeset -g RES_WORKTREE_LABEL="$RES_WORKTREE_ID"
  typeset -g RES_INSTANCE_NAME="Resonance [${RES_WORKTREE_LABEL}]"
  typeset -g RES_LAUNCHER_ROOT="/private/tmp/resonance-dev-launchers-${UID}/${RES_WORKTREE_ID}"

  typeset -g RES_MACOS_INSTANCE_NAME="Resonance Preview [${RES_WORKTREE_LABEL}]"
  typeset -g RES_MACOS_BUNDLE_ID="com.gavindietrich.ResonancePreview.worktree.w${RES_WORKTREE_HASH}"
  typeset -g RES_MACOS_APP="$RES_LAUNCHER_ROOT/macos/Resonance-Preview-${RES_WORKTREE_ID}.app"
  typeset -g RES_MACOS_EXECUTABLE="$RES_MACOS_APP/Contents/MacOS/LikedSongsFocus"

  typeset -g RES_WINDOWS_INSTANCE_NAME="Resonance Windows [${RES_WORKTREE_LABEL}]"
  typeset -g RES_WINDOWS_BUNDLE_ID="mov.unblocked.resonance.windows-preview.worktree.w${RES_WORKTREE_HASH}"
  typeset -g RES_WINDOWS_APP="$RES_LAUNCHER_ROOT/windows/Resonance-Windows-${RES_WORKTREE_ID}.app"
  typeset -g RES_WINDOWS_EXECUTABLE="$RES_WINDOWS_APP/Contents/MacOS/Electron"
  typeset -g RES_WINDOWS_USER_DATA="$HOME/Library/Application Support/Resonance Worktrees/$RES_WORKTREE_ID/windows"

  typeset -g RES_IOS_INSTANCE_NAME="Resonance iOS [${RES_WORKTREE_LABEL}]"
  typeset -g RES_IOS_BUNDLE_ID="com.gavindietrich.LikedSongsMobile.worktree.w${RES_WORKTREE_HASH}"
  typeset -g RES_IOS_SIMULATOR_NAME="Resonance iOS ${RES_WORKTREE_LABEL}"
  typeset -g RES_IOS_DERIVED_DATA="$RES_LAUNCHER_ROOT/ios-derived-data"

  typeset -g RES_ANDROID_INSTANCE_NAME="Resonance Android [${RES_WORKTREE_LABEL}]"
  typeset -g RES_ANDROID_APPLICATION_ID="mov.unblocked.resonance.worktree.w${RES_WORKTREE_HASH}"
  typeset -g RES_ANDROID_EMULATOR_ID="Resonance_${RES_WORKTREE_ID}"
  typeset -g RES_ANDROID_LAUNCHD_LABEL="codex.resonance-emulator.oneshot.${RES_WORKTREE_HASH}"

  typeset -g RES_MACOS_TEST_NAME="Resonance macOS Tests [${RES_WORKTREE_LABEL}]"
  typeset -g RES_WINDOWS_TEST_NAME="Resonance Windows Tests [${RES_WORKTREE_LABEL}]"
  typeset -g RES_IOS_TEST_NAME="Resonance iOS Tests [${RES_WORKTREE_LABEL}]"
  typeset -g RES_IOS_TEST_SIMULATOR_NAME="Resonance iOS Tests ${RES_WORKTREE_LABEL}"
  typeset -g RES_ANDROID_TEST_NAME="Resonance Android Tests [${RES_WORKTREE_LABEL}]"
  typeset -g RES_INSTANCE_REGISTRY="$RES_LAUNCHER_ROOT/instances.json"
}

# Write one deterministic, credential-free registry that agents can use to
# resolve the exact local app, window, bundle, simulator, emulator, and test
# identity for this worktree. The temporary file makes concurrent launchers
# safe: every writer publishes the same complete document atomically.
res_write_instance_registry() {
  [[ -n "${RES_INSTANCE_REGISTRY:-}" ]] \
    || { echo "Call res_prepare_worktree_identity before writing the registry." >&2; return 1; }

  /bin/mkdir -p "$RES_LAUNCHER_ROOT"

  # All registry values are pure functions of the canonical worktree path.
  # Avoid rebuilding the document on every command once this schema is present.
  if [[ -f "$RES_INSTANCE_REGISTRY" ]] \
    && [[ "$(/usr/bin/plutil -extract schemaVersion raw "$RES_INSTANCE_REGISTRY" 2>/dev/null || true)" == 4 ]] \
    && [[ "$(/usr/bin/plutil -extract worktree.pathSHA256 raw "$RES_INSTANCE_REGISTRY" 2>/dev/null || true)" == "$RES_WORKTREE_HASH_FULL" ]]; then
    return 0
  fi

  local res_registry_temp
  local res_registry_json_temp
  res_registry_temp="$(/usr/bin/mktemp "$RES_LAUNCHER_ROOT/.instances.XXXXXX")"
  res_registry_json_temp="$res_registry_temp.json"
  /usr/bin/plutil -create xml1 "$res_registry_temp"

  /usr/bin/plutil -insert schemaVersion -integer 4 "$res_registry_temp"
  /usr/bin/plutil -insert registryPath -string "$RES_INSTANCE_REGISTRY" "$res_registry_temp"

  /usr/bin/plutil -insert worktree -dictionary "$res_registry_temp"
  /usr/bin/plutil -insert worktree.root -string "$RES_WORKTREE_PATH" "$res_registry_temp"
  /usr/bin/plutil -insert worktree.id -string "$RES_WORKTREE_ID" "$res_registry_temp"
  /usr/bin/plutil -insert worktree.label -string "$RES_WORKTREE_LABEL" "$res_registry_temp"
  /usr/bin/plutil -insert worktree.pathSHA256 -string "$RES_WORKTREE_HASH_FULL" "$res_registry_temp"

  /usr/bin/plutil -insert macos -dictionary "$res_registry_temp"
  /usr/bin/plutil -insert macos.displayName -string "$RES_MACOS_INSTANCE_NAME" "$res_registry_temp"
  /usr/bin/plutil -insert macos.bundleIdentifier -string "$RES_MACOS_BUNDLE_ID" "$res_registry_temp"
  /usr/bin/plutil -insert macos.appPath -string "$RES_MACOS_APP" "$res_registry_temp"
  /usr/bin/plutil -insert macos.executablePath -string "$RES_MACOS_EXECUTABLE" "$res_registry_temp"

  /usr/bin/plutil -insert windows -dictionary "$res_registry_temp"
  /usr/bin/plutil -insert windows.displayName -string "$RES_WINDOWS_INSTANCE_NAME" "$res_registry_temp"
  /usr/bin/plutil -insert windows.bundleIdentifier -string "$RES_WINDOWS_BUNDLE_ID" "$res_registry_temp"
  /usr/bin/plutil -insert windows.appPath -string "$RES_WINDOWS_APP" "$res_registry_temp"
  /usr/bin/plutil -insert windows.executablePath -string "$RES_WINDOWS_EXECUTABLE" "$res_registry_temp"
  /usr/bin/plutil -insert windows.userDataPath -string "$RES_WINDOWS_USER_DATA" "$res_registry_temp"

  /usr/bin/plutil -insert ios -dictionary "$res_registry_temp"
  /usr/bin/plutil -insert ios.displayName -string "$RES_IOS_INSTANCE_NAME" "$res_registry_temp"
  /usr/bin/plutil -insert ios.bundleIdentifier -string "$RES_IOS_BUNDLE_ID" "$res_registry_temp"
  /usr/bin/plutil -insert ios.simulatorName -string "$RES_IOS_SIMULATOR_NAME" "$res_registry_temp"
  /usr/bin/plutil -insert ios.derivedDataPath -string "$RES_IOS_DERIVED_DATA" "$res_registry_temp"

  /usr/bin/plutil -insert android -dictionary "$res_registry_temp"
  /usr/bin/plutil -insert android.displayName -string "$RES_ANDROID_INSTANCE_NAME" "$res_registry_temp"
  /usr/bin/plutil -insert android.applicationId -string "$RES_ANDROID_APPLICATION_ID" "$res_registry_temp"
  /usr/bin/plutil -insert android.emulatorId -string "$RES_ANDROID_EMULATOR_ID" "$res_registry_temp"
  /usr/bin/plutil -insert android.launchdLabel -string "$RES_ANDROID_LAUNCHD_LABEL" "$res_registry_temp"

  /usr/bin/plutil -insert tests -dictionary "$res_registry_temp"
  /usr/bin/plutil -insert tests.macos -dictionary "$res_registry_temp"
  /usr/bin/plutil -insert tests.macos.displayName -string "$RES_MACOS_TEST_NAME" "$res_registry_temp"
  /usr/bin/plutil -insert tests.macos.processArgv0 -string "$RES_MACOS_TEST_NAME" "$res_registry_temp"
  /usr/bin/plutil -insert tests.macos.commandPath -string "$RES_WORKTREE_PATH/Test macOS.command" "$res_registry_temp"
  /usr/bin/plutil -insert tests.windows -dictionary "$res_registry_temp"
  /usr/bin/plutil -insert tests.windows.displayName -string "$RES_WINDOWS_TEST_NAME" "$res_registry_temp"
  /usr/bin/plutil -insert tests.windows.processArgv0 -string "$RES_WINDOWS_TEST_NAME" "$res_registry_temp"
  /usr/bin/plutil -insert tests.windows.commandPath -string "$RES_WORKTREE_PATH/Test Windows.command" "$res_registry_temp"
  /usr/bin/plutil -insert tests.ios -dictionary "$res_registry_temp"
  /usr/bin/plutil -insert tests.ios.displayName -string "$RES_IOS_TEST_NAME" "$res_registry_temp"
  /usr/bin/plutil -insert tests.ios.processArgv0 -string "$RES_IOS_TEST_NAME" "$res_registry_temp"
  /usr/bin/plutil -insert tests.ios.commandPath -string "$RES_WORKTREE_PATH/Test iOS.command" "$res_registry_temp"
  /usr/bin/plutil -insert tests.ios.simulatorName -string "$RES_IOS_TEST_SIMULATOR_NAME" "$res_registry_temp"
  /usr/bin/plutil -insert tests.ios.derivedDataPath -string "$RES_IOS_DERIVED_DATA/tests" "$res_registry_temp"
  /usr/bin/plutil -insert tests.android -dictionary "$res_registry_temp"
  /usr/bin/plutil -insert tests.android.displayName -string "$RES_ANDROID_TEST_NAME" "$res_registry_temp"
  /usr/bin/plutil -insert tests.android.processArgv0 -string "$RES_ANDROID_TEST_NAME" "$res_registry_temp"
  /usr/bin/plutil -insert tests.android.commandPath -string "$RES_WORKTREE_PATH/Test Android.command" "$res_registry_temp"

  /usr/bin/plutil -convert json -o "$res_registry_json_temp" "$res_registry_temp"
  /bin/chmod 0644 "$res_registry_json_temp"
  /bin/mv -f "$res_registry_json_temp" "$RES_INSTANCE_REGISTRY"
  /bin/rm -f "$res_registry_temp"
}

res_print_instance_registry() {
  res_write_instance_registry
  /bin/cat "$RES_INSTANCE_REGISTRY"
}

res_set_terminal_title() {
  /usr/bin/printf '\033]0;%s\007' "$1"
}

res_ensure_ios_simulator() {
  [[ -n "${RES_IOS_SIMULATOR_NAME:-}" ]] \
    || { echo "Call res_prepare_worktree_identity before resolving the iOS Simulator." >&2; return 1; }

  local res_simulator_name="${1:-$RES_IOS_SIMULATOR_NAME}"
  local res_device_id
  res_device_id="$(/usr/bin/xcrun simctl list devices available \
    | awk -F '[()]' -v name="$res_simulator_name" \
      '$1 ~ "^[[:space:]]*" name "[[:space:]]*$" { print $2; exit }')"
  if [[ -z "$res_device_id" ]]; then
    local res_device_type
    res_device_type="$(/usr/bin/xcrun simctl list devicetypes \
      | awk -F '[()]' '/^iPhone 17[[:space:]]*\(/ { print $2; exit }')"
    if [[ -z "$res_device_type" ]]; then
      res_device_type="$(/usr/bin/xcrun simctl list devicetypes \
        | awk -F '[()]' '/^iPhone / { print $2; exit }')"
    fi
    [[ -n "$res_device_type" ]] \
      || { echo "No available iPhone Simulator device type was found." >&2; return 1; }
    res_device_id="$(/usr/bin/xcrun simctl create "$res_simulator_name" "$res_device_type")"
  fi

  [[ -n "$res_device_id" ]] || { echo "No available iPhone Simulator was found." >&2; return 1; }
  typeset -g RES_IOS_DEVICE_ID="$res_device_id"
}

# Keep a worktree-specific, human-readable parent process alive for the full
# duration of each test command. Its argv[0] is visible in `ps` and `pgrep -f`,
# while the actual compiler or test runner remains its child.
res_run_named_process() {
  local res_process_name="$1"
  shift
  (
    exec -a "$res_process_name" /bin/zsh -c '
      "$@"
      res_status=$?
      exit "$res_status"
    ' "$res_process_name" "$@"
  )
}

# Close only the Apple Terminal tab that ran a project launcher. Launchers
# install this as an EXIT trap so both successful and failed runs clean up their
# shell after any foreground build/installation process has finished.
# The short delay lets the launcher shell exit first, preventing Terminal from
# warning that a process is still active. Other tabs stay open.
res_close_launcher_terminal() {
  [[ "${TERM_PROGRAM:-}" == "Apple_Terminal" ]] || return 0

  local res_launcher_tty
  res_launcher_tty="$(/usr/bin/tty 2>/dev/null || true)"
  [[ "$res_launcher_tty" == /dev/* ]] || return 0

  (
    /bin/sleep 0.2
    /usr/bin/osascript - "$res_launcher_tty" <<'APPLESCRIPT'
on run argv
  set launcherTTY to item 1 of argv
  tell application "Terminal"
    repeat with terminalWindow in windows
      repeat with terminalTab in tabs of terminalWindow
        if tty of terminalTab is launcherTTY then
          close terminalTab
          return
        end if
      end repeat
    end repeat
  end tell
end run
APPLESCRIPT
  ) </dev/null >/dev/null 2>&1 &!
}
