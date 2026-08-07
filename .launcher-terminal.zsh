#!/bin/zsh

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
