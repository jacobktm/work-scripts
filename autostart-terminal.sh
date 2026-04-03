#!/usr/bin/env bash
# Run the graphical terminal for the current session (COSMIC vs GNOME).
# Usage: same argv you would pass after "gnome-terminal --", e.g.
#   autostart-terminal.sh bash -c 'echo hi'
set -euo pipefail
case "${XDG_SESSION_DESKTOP:-}" in
  COSMIC)
    if command -v cosmic-term >/dev/null 2>&1; then
      exec cosmic-term "$@"
    fi
    ;;
esac
if command -v gnome-terminal >/dev/null 2>&1; then
  exec gnome-terminal -- "$@"
fi
echo "autostart-terminal: neither cosmic-term nor gnome-terminal found; running command directly" >&2
exec "$@"
