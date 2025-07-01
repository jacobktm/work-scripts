#!/usr/bin/env bash
set -euo pipefail

### ─── Config ────────────────────────────────────────────────────────────────
SCRIPT="$(readlink -f "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT")"
DUMMY_FILE="$HOME/.suspend_test.marker"

# Now point at the patterns file in the script’s directory
PATTERN_FILE="$SCRIPT_DIR/suspend_patterns.txt"
if [[ ! -f "$PATTERN_FILE" ]]; then
  echo "ERROR: patterns file not found at $PATTERN_FILE" >&2
  exit 1
fi

# Suspend count comes from ~/suspend_count if present, otherwise 300
SUSPEND_COUNT_FILE="$HOME/suspend_count"
if [[ -f "$SUSPEND_COUNT_FILE" ]]; then
  read -r SUSTEST_COUNT < "$SUSPEND_COUNT_FILE"
else
  SUSTEST_COUNT=300
fi

SCREEN_SESSION="journal_monitor"
PASS_MARKER="$HOME/suspend_pass.marker"
FAIL_MARKER="$HOME/suspend_fail.marker"

### ─── Live journal monitor ─────────────────────────────────────────────────
monitor_failures() {
  journalctl --since now -f -o short-precise | while IFS= read -r line; do
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
  screen -dmS "$SCREEN_SESSION" bash -lc "source '$SCRIPT'; monitor_failures"

  sleep 30
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
