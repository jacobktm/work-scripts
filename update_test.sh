#!/bin/bash
set -e

# Check for test script path, print usage if missing
if [ "$#" -ne 1 ]; then
    echo "Usage: ./$0 <test-script-path>"
    exit 1
fi

# Test if test script file exists, error if not
if [ ! -e "$1" ]; then
    echo "Test script file not found."
    exit 1
fi
TEST_SCRIPT=$(realpath "$1")

# Determine the directory of this script and the skip list file location
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
SKIP_LIST_FILE="$SCRIPT_DIR/skip_list.txt"

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

# Define the file path and content for sudoers
USERNAME=$(whoami)
SUDOERS_FILE="/etc/sudoers.d/apt-nopasswd"

if [ ! -f "$SUDOERS_FILE" ]; then
    echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" | sudo tee "$SUDOERS_FILE" > /dev/null
    sudo chmod 0440 "$SUDOERS_FILE"
fi

# --- Disable Screen Lock ---
current_lock=$(gsettings get org.gnome.desktop.screensaver lock-enabled 2>/dev/null || echo "error")
if [ "$current_lock" != "false" ]; then
    echo "Disabling screen lock..."
    gsettings set org.gnome.desktop.screensaver lock-enabled false
fi

# --- Disable Auto Suspend ---
# For AC
current_ac=$(gsettings get org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 2>/dev/null || echo "error")
if [ "$current_ac" != "'nothing'" ]; then
    echo "Disabling auto suspend on AC..."
    gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing'
fi

# For Battery
current_battery=$(gsettings get org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type 2>/dev/null || echo "error")
if [ "$current_battery" != "'nothing'" ]; then
    echo "Disabling auto suspend on battery..."
    gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type 'nothing'
fi

# --- Enable Autologin ---
# Locate the GDM configuration file.
if [ -f /etc/gdm3/custom.conf ]; then
    GDM_CONF="/etc/gdm3/custom.conf"
elif [ -f /etc/gdm/custom.conf ]; then
    GDM_CONF="/etc/gdm/custom.conf"
else
    echo "GDM configuration file not found. Autologin not enabled."
    GDM_CONF=""
fi

if [ -n "$GDM_CONF" ]; then
    # Check if AutomaticLoginEnable is already set to true.
    if ! grep -qE "^\s*AutomaticLoginEnable\s*=\s*true" "$GDM_CONF"; then
        echo "Enabling autologin (AutomaticLoginEnable)..."
        sudo sed -i 's/^\s*#\?\s*AutomaticLoginEnable\s*=.*/AutomaticLoginEnable = true/' "$GDM_CONF"
    fi

    # Check if AutomaticLogin is set to the current username.
    if ! grep -qE "^\s*AutomaticLogin\s*=\s*$USERNAME" "$GDM_CONF"; then
        echo "Setting autologin user to $USERNAME..."
        sudo sed -i 's/^\s*#\?\s*AutomaticLogin\s*=.*/AutomaticLogin = '"$USERNAME"'/' "$GDM_CONF"
    fi
fi

# Function to get list of packages that will be installed with an update
get_install_list() {
    $APT install --simulate "$1" 2>/dev/null | grep Inst | awk '{print $2}' > "$LOG_DIR/install_list.txt"
}

# Function to choose the next update package while skipping packages from skip_list.txt if present,
# then randomizing the list to choose a package at random.
install_next_update() {
    # Get the list of upgradeable packages
    upgradeable=$(apt list --upgradeable 2>/dev/null | grep -v "Listing..." | awk -F'/' '{print $1}')
    
    # If a skip list exists, filter out those packages and remove any blank lines.
    if [ -f "$SKIP_LIST_FILE" ]; then
        upgradeable=$(echo "$upgradeable" | grep -v -F -x -f "$SKIP_LIST_FILE" | grep -v '^$')
    fi

    # Randomize the list and select the first package.
    to_install=$(echo "$upgradeable" | shuf | head -n 1)
    
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
if [ ! -f "$LOG_DIR/installed_packages.txt" ]; then
    touch "$LOG_DIR/installed_packages.txt"
fi
OUTPUT=$($TEST_SCRIPT)
if [ "$OUTPUT" == "PASSED" ]; then
    if [ -f "$LOG_DIR/install_list.txt" ]; then
        cat "$LOG_DIR/install_list.txt" >> "$LOG_DIR/installed_packages.txt"
    fi
    install_next_update
elif [ "$OUTPUT" == "FAILED" ]; then
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

