#!/bin/zsh
set -euo pipefail

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

RES_PROJECT_DIR="${0:A:h}"
source "$RES_PROJECT_DIR/.launcher-terminal.zsh"
res_prepare_worktree_identity "$RES_PROJECT_DIR"
RES_APP_DIR="$RES_PROJECT_DIR"
RES_WINDOWS_DIR="$RES_APP_DIR/windows"
RES_RUN_DIR="$RES_LAUNCHER_ROOT/windows"
RES_LOG_FILE="$RES_RUN_DIR/windows.log"
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

trap res_close_launcher_terminal EXIT

mkdir -p "$RES_RUN_DIR"
res_write_instance_registry
res_set_terminal_title "$RES_WINDOWS_INSTANCE_NAME"

RES_COREPACK="$(command -v corepack || true)"
[[ -n "$RES_COREPACK" ]] || { echo "corepack was not found. Install Node.js first." >&2; exit 1; }

if [[ ! -x "$RES_ELECTRON_SOURCE_EXECUTABLE" ]]; then
  echo "Installing locked Windows development dependencies…"
  cd "$RES_WINDOWS_DIR"
  "$RES_COREPACK" pnpm install --frozen-lockfile
fi
[[ -x "$RES_ELECTRON_SOURCE_EXECUTABLE" ]] \
  || { echo "Electron was not installed at $RES_ELECTRON_SOURCE_APP" >&2; exit 1; }

echo "Launching the Windows Electron development app…"
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
  /usr/bin/pgrep -f "^$RES_ELECTRON_SOURCE_PROCESS_EXECUTABLE $RES_WINDOWS_DIR$" || true
} | /usr/bin/sort -u)"
if [[ -n "$RES_OLD_WINDOWS_PIDS" ]]; then
  for RES_OLD_WINDOWS_PID in ${(f)RES_OLD_WINDOWS_PIDS}; do
    /bin/kill "$RES_OLD_WINDOWS_PID" 2>/dev/null || true
  done
  for RES_ATTEMPT in {1..50}; do
    if ! /usr/bin/pgrep -f "^$RES_ELECTRON_EXECUTABLE $RES_WINDOWS_DIR$" >/dev/null \
      && ! /usr/bin/pgrep -f "^$RES_ELECTRON_SOURCE_PROCESS_EXECUTABLE $RES_WINDOWS_DIR$" >/dev/null; then
      break
    fi
    sleep 0.1
  done
fi

/bin/rm -rf "$RES_ELECTRON_APP"
/bin/cp -cR "$RES_ELECTRON_SOURCE_APP" "$RES_ELECTRON_APP"
/usr/bin/plutil -replace CFBundleDisplayName -string "$RES_WINDOWS_INSTANCE_NAME" "$RES_ELECTRON_PLIST"
/usr/bin/plutil -replace CFBundleName -string "$RES_WINDOWS_INSTANCE_NAME" "$RES_ELECTRON_PLIST"
/usr/bin/plutil -replace CFBundleIdentifier -string "$RES_ELECTRON_BUNDLE_ID" "$RES_ELECTRON_PLIST"
/usr/bin/codesign --force --deep --sign - "$RES_ELECTRON_APP"
RES_ELECTRON_PROCESS_EXECUTABLE="$(/bin/realpath "$RES_ELECTRON_EXECUTABLE")"

: >"$RES_LOG_FILE"
/usr/bin/env -u ELECTRON_RUN_AS_NODE /usr/bin/open -n "$RES_ELECTRON_APP" \
  -o "$RES_LOG_FILE" --stderr "$RES_LOG_FILE" \
  --env "RESONANCE_WORKTREE_ID=$RES_WORKTREE_ID" \
  --env "RESONANCE_INSTANCE_NAME=$RES_WINDOWS_INSTANCE_NAME" \
  --args "$RES_WINDOWS_DIR"
for RES_ATTEMPT in {1..50}; do
  /usr/bin/pgrep -f "^$RES_ELECTRON_PROCESS_EXECUTABLE $RES_WINDOWS_DIR$" >/dev/null && break
  sleep 0.1
done
/usr/bin/pgrep -f "^$RES_ELECTRON_PROCESS_EXECUTABLE $RES_WINDOWS_DIR$" >/dev/null \
  || { echo "Windows app failed to launch. See $RES_LOG_FILE" >&2; exit 1; }
echo "$RES_WINDOWS_INSTANCE_NAME launched from $RES_WINDOWS_DIR"
echo "Deterministic selectors: $RES_INSTANCE_REGISTRY"
