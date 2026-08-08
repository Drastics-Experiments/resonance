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
  typeset -g RES_WORKTREE_HASH="${res_hash[1,12]}"
  typeset -g RES_WORKTREE_SHORT_HASH="${res_hash[1,6]}"
  typeset -g RES_WORKTREE_ID="${res_slug}-${RES_WORKTREE_HASH}"
  typeset -g RES_WORKTREE_LABEL="${res_slug}-${RES_WORKTREE_SHORT_HASH}"
  typeset -g RES_INSTANCE_NAME="Resonance [${RES_WORKTREE_LABEL}]"
  typeset -g RES_LAUNCHER_ROOT="/private/tmp/resonance-dev-launchers-${UID}/${RES_WORKTREE_ID}"
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
