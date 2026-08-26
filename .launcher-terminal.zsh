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
  typeset -g RES_MACOS_APP_ROOT="$HOME/Library/Application Support/Resonance Worktrees/$RES_WORKTREE_ID/Applications"
  typeset -g RES_MACOS_APP="$RES_MACOS_APP_ROOT/Resonance-macOS-${RES_WORKTREE_ID}.app"
  typeset -g RES_MACOS_EXECUTABLE="$RES_MACOS_APP/Contents/MacOS/Electron"
  typeset -g RES_MACOS_USER_DATA="$HOME/Library/Application Support/Resonance Worktrees/$RES_WORKTREE_ID/macos"

  typeset -g RES_WINDOWS_INSTANCE_NAME="Resonance Windows [${RES_WORKTREE_LABEL}]"
  typeset -g RES_WINDOWS_BUNDLE_ID="mov.unblocked.resonance.windows-preview.worktree.w${RES_WORKTREE_HASH}"
  typeset -g RES_WINDOWS_APP_ROOT="$HOME/Library/Application Support/Resonance Worktrees/$RES_WORKTREE_ID/Applications"
  typeset -g RES_WINDOWS_APP="$RES_WINDOWS_APP_ROOT/Resonance-Windows-${RES_WORKTREE_ID}.app"
  typeset -g RES_WINDOWS_EXECUTABLE="$RES_WINDOWS_APP/Contents/MacOS/Electron"
  typeset -g RES_WINDOWS_USER_DATA="$HOME/Library/Application Support/Resonance Worktrees/$RES_WORKTREE_ID/windows"

  typeset -g RES_IOS_INSTANCE_NAME="Resonance iOS [${RES_WORKTREE_LABEL}]"
  typeset -g RES_IOS_BUNDLE_ID="com.gavindietrich.Resonance.worktree.w${RES_WORKTREE_HASH}"
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
    && [[ "$(/usr/bin/plutil -extract schemaVersion raw "$RES_INSTANCE_REGISTRY" 2>/dev/null || true)" == 7 ]] \
    && [[ "$(/usr/bin/plutil -extract worktree.pathSHA256 raw "$RES_INSTANCE_REGISTRY" 2>/dev/null || true)" == "$RES_WORKTREE_HASH_FULL" ]]; then
    return 0
  fi

  local res_registry_temp
  local res_registry_json_temp
  res_registry_temp="$(/usr/bin/mktemp "$RES_LAUNCHER_ROOT/.instances.XXXXXX")"
  res_registry_json_temp="$res_registry_temp.json"
  /usr/bin/plutil -create xml1 "$res_registry_temp"

  /usr/bin/plutil -insert schemaVersion -integer 7 "$res_registry_temp"
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
  /usr/bin/plutil -insert macos.userDataPath -string "$RES_MACOS_USER_DATA" "$res_registry_temp"

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
  /usr/bin/plutil -insert tests.macos.commandPath -string "$RES_WORKTREE_PATH/t3.json" "$res_registry_temp"
  /usr/bin/plutil -insert tests.macos.actionName -string "Test macOS" "$res_registry_temp"
  /usr/bin/plutil -insert tests.windows -dictionary "$res_registry_temp"
  /usr/bin/plutil -insert tests.windows.displayName -string "$RES_WINDOWS_TEST_NAME" "$res_registry_temp"
  /usr/bin/plutil -insert tests.windows.processArgv0 -string "$RES_WINDOWS_TEST_NAME" "$res_registry_temp"
  /usr/bin/plutil -insert tests.windows.commandPath -string "$RES_WORKTREE_PATH/t3.json" "$res_registry_temp"
  /usr/bin/plutil -insert tests.windows.actionName -string "Test Windows" "$res_registry_temp"
  /usr/bin/plutil -insert tests.ios -dictionary "$res_registry_temp"
  /usr/bin/plutil -insert tests.ios.displayName -string "$RES_IOS_TEST_NAME" "$res_registry_temp"
  /usr/bin/plutil -insert tests.ios.processArgv0 -string "$RES_IOS_TEST_NAME" "$res_registry_temp"
  /usr/bin/plutil -insert tests.ios.commandPath -string "$RES_WORKTREE_PATH/t3.json" "$res_registry_temp"
  /usr/bin/plutil -insert tests.ios.actionName -string "Test iOS" "$res_registry_temp"
  /usr/bin/plutil -insert tests.ios.simulatorName -string "$RES_IOS_TEST_SIMULATOR_NAME" "$res_registry_temp"
  /usr/bin/plutil -insert tests.ios.derivedDataPath -string "$RES_IOS_DERIVED_DATA/tests" "$res_registry_temp"
  /usr/bin/plutil -insert tests.android -dictionary "$res_registry_temp"
  /usr/bin/plutil -insert tests.android.displayName -string "$RES_ANDROID_TEST_NAME" "$res_registry_temp"
  /usr/bin/plutil -insert tests.android.processArgv0 -string "$RES_ANDROID_TEST_NAME" "$res_registry_temp"
  /usr/bin/plutil -insert tests.android.commandPath -string "$RES_WORKTREE_PATH/t3.json" "$res_registry_temp"
  /usr/bin/plutil -insert tests.android.actionName -string "Test Android" "$res_registry_temp"

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

# T3 project actions call these functions directly. Keeping the implementation
# beside the shared identity helpers avoids root-level command wrappers while
# preserving identical per-worktree runtime isolation.

res_launch_windows() {

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

local RES_PROJECT_DIR="${1:A}"
local RES_DESKTOP_VARIANT="${2:-windows}"
res_prepare_worktree_identity "$RES_PROJECT_DIR"
if [[ "$RES_DESKTOP_VARIANT" == "macos" ]]; then
  local RES_WINDOWS_INSTANCE_NAME="$RES_MACOS_INSTANCE_NAME"
  local RES_WINDOWS_BUNDLE_ID="$RES_MACOS_BUNDLE_ID"
  local RES_WINDOWS_APP_ROOT="$RES_MACOS_APP_ROOT"
  local RES_WINDOWS_APP="$RES_MACOS_APP"
  local RES_WINDOWS_EXECUTABLE="$RES_MACOS_EXECUTABLE"
  local RES_DESKTOP_CLIENT_PLATFORM="macos"
else
  local RES_DESKTOP_CLIENT_PLATFORM="windows"
fi
RES_APP_DIR="$RES_PROJECT_DIR"
RES_WINDOWS_DIR="$RES_APP_DIR/windows"
RES_RUN_DIR="$RES_LAUNCHER_ROOT/$RES_DESKTOP_CLIENT_PLATFORM"
RES_LOG_FILE="$RES_RUN_DIR/$RES_DESKTOP_CLIENT_PLATFORM.log"
RES_RESTART_LABELS=(
  mov.unblocked.resonance.dev.windows
  codex.resonance-windows-preview
)
RES_ELECTRON_SOURCE_APP="$RES_WINDOWS_DIR/node_modules/electron/dist/Electron.app"
RES_ELECTRON_SOURCE_EXECUTABLE="$RES_ELECTRON_SOURCE_APP/Contents/MacOS/Electron"
RES_ELECTRON_APP="$RES_WINDOWS_APP"
RES_ELECTRON_EXECUTABLE="$RES_WINDOWS_EXECUTABLE"
RES_ELECTRON_PLIST="$RES_ELECTRON_APP/Contents/Info.plist"
RES_ELECTRON_BUNDLE_ID="$RES_WINDOWS_BUNDLE_ID"
RES_LAUNCH_SERVICES_REGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
RES_LEGACY_ELECTRON_APP="$RES_LAUNCHER_ROOT/windows/Resonance-Windows-${RES_WORKTREE_ID}.app"
RES_LEGACY_ELECTRON_EXECUTABLE="$RES_LEGACY_ELECTRON_APP/Contents/MacOS/Electron"

trap res_close_launcher_terminal EXIT

mkdir -p "$RES_RUN_DIR" "$RES_WINDOWS_APP_ROOT"
res_write_instance_registry
res_set_terminal_title "$RES_WINDOWS_INSTANCE_NAME"

RES_COREPACK="$(command -v corepack || true)"
[[ -n "$RES_COREPACK" ]] || { echo "corepack was not found. Install Node.js first." >&2; exit 1; }

if [[ ! -x "$RES_ELECTRON_SOURCE_EXECUTABLE" ]]; then
  echo "Installing locked Windows development dependencies…"
  cd "$RES_WINDOWS_DIR"
  "$RES_COREPACK" pnpm install --frozen-lockfile
fi
if [[ ! -x "$RES_ELECTRON_SOURCE_EXECUTABLE" ]]; then
  # pnpm can report an existing worktree install as up to date even when
  # Electron's downloaded app payload is missing. Re-run Electron's own
  # idempotent installer so the launcher repairs that partial local install.
  echo "Repairing the Electron development runtime…"
  cd "$RES_WINDOWS_DIR"
  "$RES_COREPACK" pnpm exec install-electron
fi
[[ -x "$RES_ELECTRON_SOURCE_EXECUTABLE" ]] \
  || { echo "Electron was not installed at $RES_ELECTRON_SOURCE_APP" >&2; exit 1; }

echo "Launching the $RES_DESKTOP_CLIENT_PLATFORM Electron development app…"
cd "$RES_WINDOWS_DIR"
# Older versions used either label to submit Electron as an inferred KeepAlive
# job, which relaunched the app whenever it quit. Retire both before starting a
# normal detached development process.
RES_REMOVED_RESTART_JOB=false
for RES_RESTART_LABEL in "${RES_RESTART_LABELS[@]}"; do
  if /bin/launchctl print "gui/${UID}/$RES_RESTART_LABEL" >/dev/null 2>&1; then
    /bin/launchctl remove "$RES_RESTART_LABEL" 2>/dev/null || true
    RES_REMOVED_RESTART_JOB=true
  fi
done
if [[ "$RES_REMOVED_RESTART_JOB" == true ]]; then
  for RES_ATTEMPT in {1..50}; do
    /usr/bin/pgrep -f "^$RES_ELECTRON_SOURCE_EXECUTABLE $RES_WINDOWS_DIR$" >/dev/null || break
    sleep 0.1
  done
fi

# Electron's stock macOS bundle is always named `Electron`. Clone it with APFS
# copy-on-write semantics, then assign this worktree a deterministic bundle ID
# and display name so accessibility and app-level automation can target it by
# owner rather than searching among generic Electron processes.
RES_ELECTRON_SOURCE_PROCESS_EXECUTABLE="$(/bin/realpath "$RES_ELECTRON_SOURCE_EXECUTABLE")"
RES_OLD_WINDOWS_PIDS="$({
  /usr/bin/pgrep -f "^$RES_ELECTRON_EXECUTABLE $RES_WINDOWS_DIR$" || true
  /usr/bin/pgrep -f "^$RES_LEGACY_ELECTRON_EXECUTABLE $RES_WINDOWS_DIR$" || true
  /usr/bin/pgrep -f "^$RES_ELECTRON_SOURCE_PROCESS_EXECUTABLE $RES_WINDOWS_DIR$" || true
} | /usr/bin/sort -u)"
if [[ -n "$RES_OLD_WINDOWS_PIDS" ]]; then
  for RES_OLD_WINDOWS_PID in ${(f)RES_OLD_WINDOWS_PIDS}; do
    /bin/kill "$RES_OLD_WINDOWS_PID" 2>/dev/null || true
  done
  for RES_ATTEMPT in {1..50}; do
    if ! /usr/bin/pgrep -f "^$RES_ELECTRON_EXECUTABLE $RES_WINDOWS_DIR$" >/dev/null \
      && ! /usr/bin/pgrep -f "^$RES_LEGACY_ELECTRON_EXECUTABLE $RES_WINDOWS_DIR$" >/dev/null \
      && ! /usr/bin/pgrep -f "^$RES_ELECTRON_SOURCE_PROCESS_EXECUTABLE $RES_WINDOWS_DIR$" >/dev/null; then
      break
    fi
    sleep 0.1
  done
fi

[[ "${RES_ELECTRON_APP:h}" == "$RES_WINDOWS_APP_ROOT" ]] \
  || { echo "Refusing to replace an unexpected desktop Preview bundle: $RES_ELECTRON_APP" >&2; exit 1; }
/bin/rm -rf "$RES_ELECTRON_APP"
/bin/cp -cR "$RES_ELECTRON_SOURCE_APP" "$RES_ELECTRON_APP"
/usr/bin/plutil -replace CFBundleDisplayName -string "$RES_WINDOWS_INSTANCE_NAME" "$RES_ELECTRON_PLIST"
/usr/bin/plutil -replace CFBundleName -string "$RES_WINDOWS_INSTANCE_NAME" "$RES_ELECTRON_PLIST"
/usr/bin/plutil -replace CFBundleIdentifier -string "$RES_ELECTRON_BUNDLE_ID" "$RES_ELECTRON_PLIST"
/usr/bin/plutil -remove CFBundleURLTypes "$RES_ELECTRON_PLIST" 2>/dev/null || true
/usr/bin/plutil -insert CFBundleURLTypes -array "$RES_ELECTRON_PLIST"
/usr/bin/plutil -insert CFBundleURLTypes.0 -dictionary "$RES_ELECTRON_PLIST"
/usr/bin/plutil -insert CFBundleURLTypes.0.CFBundleURLName -string "$RES_ELECTRON_BUNDLE_ID" "$RES_ELECTRON_PLIST"
/usr/bin/plutil -insert CFBundleURLTypes.0.CFBundleTypeRole -string Viewer "$RES_ELECTRON_PLIST"
/usr/bin/plutil -insert CFBundleURLTypes.0.CFBundleURLSchemes -array "$RES_ELECTRON_PLIST"
/usr/bin/plutil -insert CFBundleURLTypes.0.CFBundleURLSchemes.0 -string resonance "$RES_ELECTRON_PLIST"
/usr/bin/codesign --force --deep --sign - "$RES_ELECTRON_APP"
# Launch Services records apps under /private/tmp but will not open them as URL
# handlers. The bundle therefore lives in this worktree's Application Support
# folder, and its registration is refreshed after every rebuild before Electron
# sets itself as the default resonance:// handler.
"$RES_LAUNCH_SERVICES_REGISTER" -u "$RES_LEGACY_ELECTRON_APP" 2>/dev/null || true
"$RES_LAUNCH_SERVICES_REGISTER" -f "$RES_ELECTRON_APP"
RES_ELECTRON_PROCESS_EXECUTABLE="$(/bin/realpath "$RES_ELECTRON_EXECUTABLE")"

: >"$RES_LOG_FILE"
/usr/bin/env -u ELECTRON_RUN_AS_NODE /usr/bin/open -n "$RES_ELECTRON_APP" \
  -o "$RES_LOG_FILE" --stderr "$RES_LOG_FILE" \
  --env "RESONANCE_WORKTREE_ID=$RES_WORKTREE_ID" \
  --env "RESONANCE_INSTANCE_NAME=$RES_WINDOWS_INSTANCE_NAME" \
  --env "RESONANCE_CLIENT_PLATFORM=$RES_DESKTOP_CLIENT_PLATFORM" \
  --args "$RES_WINDOWS_DIR"
for RES_ATTEMPT in {1..50}; do
  /usr/bin/pgrep -f "^$RES_ELECTRON_PROCESS_EXECUTABLE $RES_WINDOWS_DIR$" >/dev/null && break
  sleep 0.1
done
/usr/bin/pgrep -f "^$RES_ELECTRON_PROCESS_EXECUTABLE $RES_WINDOWS_DIR$" >/dev/null \
  || { echo "Desktop app failed to launch. See $RES_LOG_FILE" >&2; exit 1; }
echo "$RES_WINDOWS_INSTANCE_NAME launched from $RES_WINDOWS_DIR"
echo "Deterministic selectors: $RES_INSTANCE_REGISTRY"
}

res_test_windows() {

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

local RES_PROJECT_DIR="${1:A}"
res_prepare_worktree_identity "$RES_PROJECT_DIR"
res_write_instance_registry
res_set_terminal_title "$RES_WINDOWS_TEST_NAME"

trap res_close_launcher_terminal EXIT
export RESONANCE_WORKTREE_ID="$RES_WORKTREE_ID"
export RESONANCE_PROCESS_NAME="$RES_WINDOWS_TEST_NAME"

echo "Running $RES_WINDOWS_TEST_NAME"
echo "Deterministic selectors: $RES_INSTANCE_REGISTRY"
cd "$RES_PROJECT_DIR/windows"
RES_NODE="$(command -v node || true)"
[[ -n "$RES_NODE" ]] || { echo "node was not found." >&2; exit 1; }
res_run_named_process "$RES_WINDOWS_TEST_NAME" "$RES_NODE" --test
}

res_launch_macos() {
  res_launch_windows "$1" macos
}

res_test_macos() {

local RES_PROJECT_DIR="${1:A}"
res_prepare_worktree_identity "$RES_PROJECT_DIR"
res_write_instance_registry
res_set_terminal_title "$RES_MACOS_TEST_NAME"

trap res_close_launcher_terminal EXIT
export RESONANCE_WORKTREE_ID="$RES_WORKTREE_ID"
export RESONANCE_PROCESS_NAME="$RES_MACOS_TEST_NAME"

echo "Running $RES_MACOS_TEST_NAME"
echo "Deterministic selectors: $RES_INSTANCE_REGISTRY"
cd "$RES_PROJECT_DIR/windows"
RES_NODE="$(command -v node || true)"
[[ -n "$RES_NODE" ]] || { echo "node was not found." >&2; exit 1; }
export RESONANCE_CLIENT_PLATFORM=macos
res_run_named_process "$RES_MACOS_TEST_NAME" "$RES_NODE" --test
}

res_launch_ios() {

local RES_PROJECT_DIR="${1:A}"
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
  -project "$RES_APP_DIR/ios/Resonance.xcodeproj" \
  -scheme Resonance \
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
}

res_test_ios() {

local RES_PROJECT_DIR="${1:A}"
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
  -project "$RES_PROJECT_DIR/ios/Resonance.xcodeproj" \
  -scheme Resonance \
  -configuration Debug \
  -sdk iphonesimulator \
  -destination "id=$RES_IOS_DEVICE_ID" \
  -derivedDataPath "$RES_IOS_DERIVED_DATA/tests" \
  CODE_SIGNING_ALLOWED=NO \
  test

echo "$RES_IOS_TEST_NAME passed"
}

res_launch_android() {

local RES_PROJECT_DIR="${1:A}"
res_prepare_worktree_identity "$RES_PROJECT_DIR"
RES_APP_DIR="$RES_PROJECT_DIR"
RES_ANDROID_DIR="$RES_APP_DIR/android"
RES_ANDROID_SDK="$HOME/Library/Android/sdk"
RES_JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
RES_ADB="$RES_ANDROID_SDK/platform-tools/adb"
RES_EMULATOR="$RES_ANDROID_SDK/emulator/emulator"
RES_AVD="Resonance_API_36"
RES_APPLICATION_ID="$RES_ANDROID_APPLICATION_ID"
RES_ANDROID_AVD_ID="$RES_ANDROID_EMULATOR_ID"
RES_RUN_DIR="$RES_LAUNCHER_ROOT/android"
RES_EMULATOR_LOG="$RES_RUN_DIR/android-emulator.log"
RES_ONESHOT_LABEL="$RES_ANDROID_LAUNCHD_LABEL"
RES_EMULATOR_PLIST="$RES_RUN_DIR/$RES_ONESHOT_LABEL.plist"
RES_RESTART_LABELS=(
  codex.resonance-emulator
  codex.resonance-mobile-tools-open
  mov.unblocked.resonance-emulator
)

trap res_close_launcher_terminal EXIT
res_write_instance_registry
res_set_terminal_title "$RES_ANDROID_INSTANCE_NAME"

res_android_serial_for_id() {
  local res_candidate_serial
  local res_candidate_id
  for res_candidate_serial in $($RES_ADB devices \
    | awk '/^emulator-[0-9]+[[:space:]]+device$/ { print $1 }'); do
    res_candidate_id="$($RES_ADB -s "$res_candidate_serial" emu avd id 2>/dev/null \
      | /usr/bin/head -n 1 | /usr/bin/tr -d '\r')"
    if [[ "$res_candidate_id" == "$RES_ANDROID_AVD_ID" ]]; then
      /usr/bin/printf '%s\n' "$res_candidate_serial"
      return 0
    fi
  done
  return 1
}

[[ -x "$RES_ADB" ]] || { echo "Android adb was not found at $RES_ADB" >&2; exit 1; }
[[ -x "$RES_EMULATOR" ]] || { echo "Android emulator was not found at $RES_EMULATOR" >&2; exit 1; }
[[ -x "$RES_JAVA_HOME/bin/java" ]] || { echo "Android Studio's JDK was not found." >&2; exit 1; }
mkdir -p "$RES_RUN_DIR"

echo "Building the Android development APK…"
cd "$RES_ANDROID_DIR"
JAVA_HOME="$RES_JAVA_HOME" ANDROID_HOME="$RES_ANDROID_SDK" ./gradlew --no-daemon \
  "-PresonanceInstanceSuffix=.worktree.w${RES_WORKTREE_HASH}" \
  "-PresonanceInstanceName=$RES_ANDROID_INSTANCE_NAME" \
  assembleDebug

# Remove old keep-alive jobs so closing the emulator leaves it closed.
RES_REMOVED_RESTART_JOB=false
for RES_RESTART_LABEL in "${RES_RESTART_LABELS[@]}"; do
  if /bin/launchctl print "gui/${UID}/$RES_RESTART_LABEL" >/dev/null 2>&1; then
    /bin/launchctl remove "$RES_RESTART_LABEL" 2>/dev/null || true
    RES_REMOVED_RESTART_JOB=true
  fi
done

RES_SERIAL="$(res_android_serial_for_id || true)"
if [[ -z "$RES_SERIAL" ]]; then
  /bin/launchctl bootout "gui/${UID}/$RES_ONESHOT_LABEL" 2>/dev/null || true
  : >"$RES_EMULATOR_LOG"
  /usr/bin/plutil -create xml1 "$RES_EMULATOR_PLIST"
  /usr/bin/plutil -insert Label -string "$RES_ONESHOT_LABEL" "$RES_EMULATOR_PLIST"
  /usr/bin/plutil -insert ProgramArguments -array "$RES_EMULATOR_PLIST"
  /usr/bin/plutil -insert ProgramArguments.0 -string "$RES_EMULATOR" "$RES_EMULATOR_PLIST"
  /usr/bin/plutil -insert ProgramArguments.1 -string "@$RES_AVD" "$RES_EMULATOR_PLIST"
  /usr/bin/plutil -insert ProgramArguments.2 -string -id "$RES_EMULATOR_PLIST"
  /usr/bin/plutil -insert ProgramArguments.3 -string "$RES_ANDROID_AVD_ID" "$RES_EMULATOR_PLIST"
  /usr/bin/plutil -insert ProgramArguments.4 -string -read-only "$RES_EMULATOR_PLIST"
  /usr/bin/plutil -insert ProgramArguments.5 -string -no-audio "$RES_EMULATOR_PLIST"
  /usr/bin/plutil -insert ProgramArguments.6 -string -no-boot-anim "$RES_EMULATOR_PLIST"
  /usr/bin/plutil -insert ProgramArguments.7 -string -no-snapshot-save "$RES_EMULATOR_PLIST"
  /usr/bin/plutil -insert RunAtLoad -bool YES "$RES_EMULATOR_PLIST"
  /usr/bin/plutil -insert KeepAlive -bool NO "$RES_EMULATOR_PLIST"
  /usr/bin/plutil -insert ProcessType -string Interactive "$RES_EMULATOR_PLIST"
  /usr/bin/plutil -insert StandardOutPath -string "$RES_EMULATOR_LOG" "$RES_EMULATOR_PLIST"
  /usr/bin/plutil -insert StandardErrorPath -string "$RES_EMULATOR_LOG" "$RES_EMULATOR_PLIST"
  /bin/launchctl bootstrap "gui/${UID}" "$RES_EMULATOR_PLIST"
  for _ in {1..60}; do
    RES_SERIAL="$(res_android_serial_for_id || true)"
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
"$RES_ADB" -s "$RES_SERIAL" shell am force-stop "$RES_APPLICATION_ID"
"$RES_ADB" -s "$RES_SERIAL" shell am start -n "$RES_APPLICATION_ID/mov.unblocked.resonance.MainActivity"
echo "$RES_ANDROID_INSTANCE_NAME launched on $RES_ANDROID_AVD_ID ($RES_SERIAL)"
echo "Deterministic selectors: $RES_INSTANCE_REGISTRY"
}

res_test_android() {

local RES_PROJECT_DIR="${1:A}"
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
}

res_show_instances() {

local RES_PROJECT_DIR="${1:A}"
res_prepare_worktree_identity "$RES_PROJECT_DIR"

echo "Deterministic Resonance identities for $RES_WORKTREE_PATH"
echo "Registry: $RES_INSTANCE_REGISTRY"
res_print_instance_registry
}
