#!/bin/bash

# pang14-charge-reboot.sh: A script to drain the battery and trigger a spontaneous reboot/freeze.

# Exit immediately if a command exits with a non-zero status
set -e

# --------------------------- Configuration --------------------------- #

# YouTube video URL to play on mute
YOUTUBE_URL="https://www.youtube.com/watch?v=56lkofpjOAs"

# Duration (in seconds) between mouse movements to prevent sleep
MOUSE_MOVE_INTERVAL=280

# Duration (in seconds) to wait at 100% charge before attempting reboot
ONE_HOUR=3600

# Battery percentage thresholds
PLUG_ON_THRESHOLD=65
PLUG_OFF_THRESHOLD=100  # Stop charging at 100%
STALL_DISCHARGE_THRESHOLD=89  # Discharge to 90% before resuming charging after a stall

# Paths and repositories
HS100_REPO="https://github.com/branning/hs100.git"
HS100_DIR="hs100"
HS100_SCRIPT="./hs100/hs100.sh"

# Dependencies to install
DEPENDENCIES=(xdotool git)

# --------------------------- Functions --------------------------- #

# Function to display usage information
usage() {
    echo "Usage: $0 [SMART_PLUG_IP]"
    echo "  SMART_PLUG_IP: (Optional) IP address of the smart plug to control."
    exit 1
}

# Function to install necessary dependencies
install_dependencies() {
    echo "Installing dependencies..."
    # Assuming an Ubuntu/Debian-based system; adjust package manager as needed
    ./install.sh "${DEPENDENCIES[@]}"
    echo "Dependencies installed."
}

# Function to clone the hs100 repository if not already present
setup_hs100() {
    if [ ! -d "$HS100_DIR" ]; then
        echo "Cloning hs100 repository..."
        git clone "$HS100_REPO"
        chmod +x "$HS100_SCRIPT"
        echo "hs100 repository cloned and script permissions set."
    else
        echo "hs100 directory already exists. Skipping clone."
    fi
}

# Function to launch Firefox with the YouTube video on mute
launch_firefox_video() {
    echo "Launching Firefox with YouTube video..."
    # Check if Firefox is already running to avoid multiple instances
    if ! pgrep firefox &>/dev/null; then
        # Launch Firefox in the background with the specified URL
        firefox --new-window "$YOUTUBE_URL" &
        FIREFOX_PID=$!

        # Wait for Firefox to fully launch and load the video
        sleep 15

        # Mute the YouTube video using xdotool
        # Retrieve the window ID of the newly launched Firefox window
        WINDOW_ID=$(xdotool search --sync --onlyvisible --pid "$FIREFOX_PID" | head -n1)

        if [ -n "$WINDOW_ID" ]; then
            # Activate the Firefox window
            xdotool windowactivate "$WINDOW_ID"
            sleep 2  # Wait a moment to ensure the window is active

            # Send the 'm' key to mute the YouTube video
            xdotool key --window "$WINDOW_ID" m
            echo "YouTube video muted."
        else
            echo "Failed to retrieve Firefox window ID for muting."
        fi
    else
        echo "Firefox is already running. Skipping launch."
    fi
}

# Function to prevent the system from sleeping by moving the mouse
prevent_sleep() {
    echo "Starting mouse movement to prevent sleep..."
    while true; do
        sleep "$MOUSE_MOVE_INTERVAL"
        # Get the current mouse position
        eval $(xdotool getmouselocation --shell)
        
        # Move the mouse slightly
        xdotool mousemove --sync $((X + 1)) $((Y + 1))
        xdotool mousemove --sync "$X" "$Y"
    done &
    PREVENT_SLEEP_PID=$!
}

# Function to handle smart plug actions
control_smart_plug() {
    local action=$1
    if [ "$SMART_PLUG" -eq 1 ]; then
        echo "Setting smart plug to '$action'..."
        "$HS100_SCRIPT" $HS100_ARGS "$action"
    fi
}

# Function to cleanup background processes on exit
cleanup() {
    echo "Cleaning up..."
    if [ -n "$PREVENT_SLEEP_PID" ]; then
        kill "$PREVENT_SLEEP_PID" 2>/dev/null || true
    fi
    # Removed termination of firefox to keep it running
    exit 0
}

# Trap EXIT signal to ensure cleanup
trap cleanup EXIT

# --------------------------- Main Script --------------------------- #

# Check for help flag
if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    usage
fi

# Parse arguments
SMART_PLUG=0
HS100_ARGS=""
if [ $# -gt 0 ]; then
    SMART_PLUG=1
    HS100_IP="$1"
    HS100_ARGS="-i $HS100_IP"
fi

# Install dependencies
install_dependencies

# Setup hs100 repository if smart plug is to be used
if [ "$SMART_PLUG" -eq 1 ]; then
    setup_hs100
fi

# Launch Firefox with the YouTube video on mute
launch_firefox_video

# Prevent the system from sleeping
prevent_sleep

# Optionally, run 'upower --monitor-detail' in the background to log battery details
# Uncomment the following line if you wish to log battery details
# upower --monitor-detail > battery_monitor.log &

# Battery drainage and smart plug control logic
if [ -d /sys/class/power_supply/BAT0 ]; then
    LAST_CHARGE=0
    PREV_STATUS=""
    STALL_IN_PROGRESS=0
    clear
    while true; do
        STATUS=$(cat /sys/class/power_supply/BAT0/status)
        CHARGE=$(cat /sys/class/power_supply/BAT0/capacity)

        # Display and track battery charge changes
        if [ "$LAST_CHARGE" -ne "$CHARGE" ]; then
            LAST_CHARGE="$CHARGE"
            echo "Battery Charge: $CHARGE%"
        fi

        # If battery is fully charged, start the 1-hour timer
        if [ "$STATUS" == "Full" ]; then
            echo "Battery is full. Starting 1-hour wait before discharging again."
            sleep "$ONE_HOUR"
            echo "1 hour elapsed at full charge. Starting discharge."
            # Turn off the smart plug to start discharging
            if [ "$SMART_PLUG" -eq 1 ]; then
                control_smart_plug "off"
                echo "Smart plug turned off to start discharging."
            fi
        fi

        # Turn on smart plug if charge drops below threshold
        if [ "$STATUS" == "Discharging" ] && [ "$CHARGE" -lt "$PLUG_ON_THRESHOLD" ]; then
            echo "Battery charge dropped below $PLUG_ON_THRESHOLD%. Turning on smart plug to start charging."
            control_smart_plug "on"
        fi

        # Detect charging stall
        if [ "$PREV_STATUS" = "Charging" ] && [ "$STATUS" != "Discharging" ] && [ "$CHARGE" -gt "$STALL_DISCHARGE_THRESHOLD" ] && [ "$STALL_IN_PROGRESS" -eq 0 ]; then
            echo "Charging stall detected at $CHARGE% charge."
            STALL_IN_PROGRESS=1
            # Turn off the smart plug to stop charging
            control_smart_plug "off"
            echo "Smart plug turned off to handle charging stall."

            # Wait until the battery discharges below the stall discharge threshold
            while [ "$CHARGE" -ge "$STALL_DISCHARGE_THRESHOLD" ]; do
                sleep 60  # Wait for 1 minute before checking again
                CHARGE=$(cat /sys/class/power_supply/BAT0/capacity)
                echo "Waiting for battery to discharge below $STALL_DISCHARGE_THRESHOLD%: Current charge is $CHARGE%."
            done

            # Resume charging by turning the smart plug back on
            control_smart_plug "on"
            echo "Battery discharged below $STALL_DISCHARGE_THRESHOLD%. Resuming charging."
            STALL_IN_PROGRESS=0
        fi

        # Update previous status for next iteration
        PREV_STATUS="$STATUS"
        sleep 1
    done
else
    echo "Battery information not found at /sys/class/power_supply/BAT0."
    exit 1
fi
