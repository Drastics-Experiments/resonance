#!/bin/zsh
set -euo pipefail

RES_PROJECT_DIR="${0:A:h}"
source "$RES_PROJECT_DIR/.launcher-terminal.zsh"
res_prepare_worktree_identity "$RES_PROJECT_DIR"

echo "Deterministic Resonance identities for $RES_WORKTREE_PATH"
echo "Registry: $RES_INSTANCE_REGISTRY"
res_print_instance_registry
