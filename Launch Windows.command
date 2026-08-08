#!/bin/zsh
set -euo pipefail

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

RES_PROJECT_DIR="${0:A:h}"
source "$RES_PROJECT_DIR/.launcher-terminal.zsh"
res_prepare_worktree_identity "$RES_PROJECT_DIR"
RES_APP_DIR="$RES_PROJECT_DIR"
RES_WINDOWS_DIR="$RES_APP_DIR/windows"
RES_WINDOWS_INSTANCE_NAME="Resonance Windows [${RES_WORKTREE_LABEL}]"
RES_RUN_DIR="$RES_LAUNCHER_ROOT/windows"
RES_LOG_FILE="$RES_RUN_DIR/windows.log"
RES_RESTART_LABELS=(
  mov.unblocked.resonance.dev.windows
  codex.resonance-windows-preview
)
RES_ELECTRON_APP="$RES_WINDOWS_DIR/node_modules/electron/dist/Electron.app"
RES_ELECTRON_EXECUTABLE="$RES_ELECTRON_APP/Contents/MacOS/Electron"

trap res_close_launcher_terminal EXIT

mkdir -p "$RES_RUN_DIR"

RES_COREPACK="$(command -v corepack || true)"
[[ -n "$RES_COREPACK" ]] || { echo "corepack was not found. Install Node.js first." >&2; exit 1; }

if [[ ! -x "$RES_ELECTRON_EXECUTABLE" ]]; then
  echo "Installing locked Windows development dependencies…"
  cd "$RES_WINDOWS_DIR"
  "$RES_COREPACK" pnpm install --frozen-lockfile
fi
RES_ELECTRON_PROCESS_EXECUTABLE="$(/bin/realpath "$RES_ELECTRON_EXECUTABLE")"

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
    /usr/bin/pgrep -f "^$RES_ELECTRON_PROCESS_EXECUTABLE $RES_WINDOWS_DIR$" >/dev/null || break
    sleep 0.1
  done
fi
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
