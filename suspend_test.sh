#!/bin/bash
set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Persistent marker file (stored in $HOME so it survives reboot)
DUMMY_FILE="$HOME/.suspend_test.marker"

# Path to the file containing failure patterns (one per line), located alongside this script
PATTERN_FILE="$HOME/suspend_patterns.txt"

# Ensure the pattern file exists.
if [ ! -f "$PATTERN_FILE" ]; then
    cp "$SCRIPT_DIR/suspend_patterns.txt" "$HOME"
fi

if [ ! -f "$DUMMY_FILE" ]; then
    # First run: marker file does not exist.
    touch "$DUMMY_FILE"
    
    # Run the automated suspend test script (assumes 'sustest' is available in PATH)
    sleep 30
    sustest 5
    
    # Reboot the system after the suspend test.
    sleep 15
    sudo systemctl reboot -i
else
    # Second run: marker file exists, so we have rebooted after the suspend test.
    rm -f "$DUMMY_FILE"
    
    # Get the logs from the previous boot.
    # First, verify that the fwts marker exists at least once.
    if ! journalctl -b -1 | grep -q "fwts: Starting fwts suspend"; then
         echo "FAILED"
         exit 0
    fi
    
    # Extract the log section starting at the first occurrence of the marker.
    LOG_SECTION=$(journalctl -b -1 | sed -n '/fwts: Starting fwts suspend/,$p')
    
    # Now search the extracted log section for any failure patterns.
    if echo "$LOG_SECTION" | grep -E -f "$PATTERN_FILE" > /dev/null; then
         echo "$LOG_SECTION" | grep -E -f "$PATTERN_FILE" > "$HOME/Desktop/errors"
         rm -f "$PATTERN_FILE"
         echo "FAILED"
    else
         echo "PASSED"
    fi
fi

