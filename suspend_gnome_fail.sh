#!/usr/bin/env bash
set -euo pipefail

### ─── Config ────────────────────────────────────────────────────────────────
SCRIPT="$(readlink -f "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT")"
DUMMY_FILE="$HOME/.suspend_gnome_test.marker"

# No patterns file needed - using session marker approach

# Single suspend test for GNOME shell crash detection
SUSTEST_COUNT=1

# Marker files for tracking session state
PASS_MARKER="$HOME/suspend_gnome_pass.marker"
FAIL_MARKER="$HOME/suspend_gnome_fail.marker"
SESSION_MARKER="$HOME/.gnome_session_active.marker"

### ─── Main workflow ─────────────────────────────────────────────────────────
if [[ ! -f "$DUMMY_FILE" ]]; then
  # ── FIRST RUN ──────────────────────────────────────────────────────────────
  rm -f "$PASS_MARKER" "$FAIL_MARKER" "$SESSION_MARKER"
  touch "$DUMMY_FILE"

  # Create session marker before suspend
  touch "$SESSION_MARKER"
  
  # Resolve HOME path for use in screen session
  RESOLVED_HOME=$(getent passwd "$(whoami)" | cut -d: -f6)

  sleep 30
  # Use full path to sustest to avoid PATH issues
  if sudo "$RESOLVED_HOME/.local/bin/sustest" "$SUSTEST_COUNT"; then
    # If we reach here, suspend completed successfully
    # Remove session marker to indicate session survived
    rm -f "$SESSION_MARKER"
    touch "$PASS_MARKER"
  fi

  sleep 15
  sudo systemctl reboot -i

else
  # ── SECOND RUN (after reboot) ──────────────────────────────────────────────
  rm -f "$DUMMY_FILE"
  
  # Check if session marker still exists (indicates session crash)
  if [[ -f "$SESSION_MARKER" ]]; then
    echo "[$(date +'%F %T')] FAIL: GNOME session crashed during suspend (marker not removed)"
    rm -f "$SESSION_MARKER"
    echo "FAILED"
    exit 1
  fi

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