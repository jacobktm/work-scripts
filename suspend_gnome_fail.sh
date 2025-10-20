#!/usr/bin/env bash
set -euo pipefail

### ─── Config ────────────────────────────────────────────────────────────────
SCRIPT="$(readlink -f "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT")"
DUMMY_FILE="$HOME/.suspend_gnome_test.marker"

# Now point at the patterns file in the script's directory
PATTERN_FILE="$SCRIPT_DIR/suspend_patterns.txt"
if [[ ! -f "$PATTERN_FILE" ]]; then
  echo "ERROR: patterns file not found at $PATTERN_FILE" >&2
  exit 1
fi

# Single suspend test for GNOME shell crash detection
SUSTEST_COUNT=1

SCREEN_SESSION="gnome_shell_monitor"
PASS_MARKER="$HOME/suspend_gnome_pass.marker"
FAIL_MARKER="$HOME/suspend_gnome_fail.marker"

### ─── Live journal monitor for GNOME shell crashes ──────────────────────────
monitor_gnome_shell_crashes() {
  journalctl --since now -f -o short-precise | while IFS= read -r line; do
    # Check for GNOME shell specific crash patterns
    if echo "$line" | grep -iE "(gnome-shell.*crashed|gnome-shell.*died|gnome-shell.*killed|gnome.*shell.*restart)" >/dev/null; then
      echo "[$(date +'%F %T')] FAIL: GNOME shell crash detected: $line"
      touch "$FAIL_MARKER"
      sudo systemctl reboot -i
    fi
    
    # Check for general patterns that might indicate shell issues
    if echo "$line" | grep -E -f "$PATTERN_FILE" >/dev/null; then
      echo "[$(date +'%F %T')] FAIL: detected error after suspend: $line"
      touch "$FAIL_MARKER"
      sudo systemctl reboot -i
    fi
  done
}

### ─── Main workflow ─────────────────────────────────────────────────────────
if [[ ! -f "$DUMMY_FILE" ]]; then
  # ── FIRST RUN ──────────────────────────────────────────────────────────────
  rm -f "$PASS_MARKER" "$FAIL_MARKER"
  touch "$DUMMY_FILE"

  # start the monitor in a detached screen session
  screen -dmS "$SCREEN_SESSION" bash -lc "export PATH=\"\$HOME/.local/bin:\$PATH\"; source '$SCRIPT'; monitor_gnome_shell_crashes"

  sleep 30
  # Ensure PATH includes ~/.local/bin for sustest
  export PATH="$HOME/.local/bin:$PATH"
  if sudo sustest "$SUSTEST_COUNT"; then
    touch "$PASS_MARKER"
    screen -S "$SCREEN_SESSION" -X quit || true
  fi

  sleep 15
  sudo systemctl reboot -i

else
  # ── SECOND RUN (after reboot) ──────────────────────────────────────────────
  rm -f "$DUMMY_FILE"
  screen -S "$SCREEN_SESSION" -X quit || true

  if [[ -f "$FAIL_MARKER" ]]; then
    echo "FAILED"
    exit 1
  elif [[ -f "$PASS_MARKER" ]]; then
    echo "PASSED"
    exit 0
  else
    echo "ERROR: no result marker found"
    exit 2
  fi
fi