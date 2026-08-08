#!/bin/zsh
set -euo pipefail

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

RES_PROJECT_DIR="${0:A:h}"
source "$RES_PROJECT_DIR/.launcher-terminal.zsh"
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
