#!/bin/zsh
set -euo pipefail

RES_PROJECT_DIR="${0:A:h}"
source "$RES_PROJECT_DIR/.launcher-terminal.zsh"
res_prepare_worktree_identity "$RES_PROJECT_DIR"
res_write_instance_registry
res_set_terminal_title "$RES_MACOS_TEST_NAME"

trap res_close_launcher_terminal EXIT
export RESONANCE_WORKTREE_ID="$RES_WORKTREE_ID"
export RESONANCE_PROCESS_NAME="$RES_MACOS_TEST_NAME"

echo "Running $RES_MACOS_TEST_NAME"
echo "Deterministic selectors: $RES_INSTANCE_REGISTRY"
res_run_named_process "$RES_MACOS_TEST_NAME" /bin/bash "$RES_PROJECT_DIR/mac/scripts/test.sh"
