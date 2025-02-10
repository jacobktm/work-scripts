#!/bin/bash

set -e

# Check for test script path, print usage if missing
if [ "$#" -ne 1 ]; then
    echo "Usage: ./$0 <test-script-path>"
    exit 1
fi

# Test if script file exists, error if not
if [ ! -e "$1" ]; then
    echo "Test script file not found."
    exit 1
fi
TEST_SCRIPT=$(realpath "$1")

# Copy the script to autostart if not already there
AUTOSTART_DESKTOP="$HOME/.config/autostart/$(basename "$0")-autostart.desktop"
APT="sudo apt"
if [ -e "$HOME/.local/bin/apt-proxy" ]; then
    APT="apt-proxy"
fi

if [ ! -f "$AUTOSTART_DESKTOP" ]; then
    $APT update
    if [ ! -d "$HOME/.config/autostart" ]; then
        mkdir -p "$HOME/.config/autostart"
    fi

    # Create a .desktop file for autostart
    cat <<EOF > "$AUTOSTART_DESKTOP"
[Desktop Entry]
Type=Application
Exec=gnome-terminal -- bash -c '$(realpath "$0") $TEST_SCRIPT; exec bash'
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
Name=AutoStart-$(basename "$0")
Comment=Automatically starts the test script on login
EOF
    chmod +x "$AUTOSTART_DESKTOP"
fi

# Path to store package lists
LOG_DIR="$HOME/update_test/log"
if [ ! -d "$LOG_DIR" ]; then
    mkdir -p "$LOG_DIR"
fi

# Define the file path and content
USERNAME=$(whoami)
SUDOERS_FILE="/etc/sudoers.d/apt-nopasswd"

if [ ! -f "$SUDOERS_FILE" ]; then
    echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" | sudo tee "$SUDOERS_FILE" > /dev/null
    sudo chmod 0440 "$SUDOERS_FILE"
fi

# Function to get list of packages that will be installed with an update
get_install_list() {
    $APT install --simulate "$1" 2>/dev/null | grep Inst | awk '{print $2}' > "$LOG_DIR"/install_list.txt
}

install_next_update() {
    to_install=$(apt list --upgradeable 2>/dev/null | grep -v "Listing..." | awk -F'/' '{print $1}' | head -n 1)
    if [ -n "$to_install" ]; then
        get_install_list "$to_install"
        $APT install -y "$to_install"
        systemctl reboot -i
    else
        echo "No packages to install."
        if [ -f "$SUDOERS_FILE" ]; then
            sudo rm -f "$SUDOERS_FILE"
        fi
        if [ -f "$AUTOSTART_DESKTOP" ]; then
            rm -f "$AUTOSTART_DESKTOP"
        fi
    fi
}

OUTPUT=$($TEST_SCRIPT)
if [ "$OUTPUT" == "PASSED" ]; then
    install_next_update
else
    cat "$LOG_DIR/install_list.txt" > "$HOME/Desktop/problem_package"
    if [ -f "$AUTOSTART_DESKTOP" ]; then
        echo "Removing autostart script: $AUTOSTART_DESKTOP"
        rm -f "$AUTOSTART_DESKTOP"
    fi
    if [ -f "$SUDOERS_FILE" ]; then
        echo "Removing apt sudoers file: $SUDOERS_FILE"
        sudo rm -f "$SUDOERS_FILE"
    fi
fi

