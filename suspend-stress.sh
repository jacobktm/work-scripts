#!/bin/bash
set -e

# Determine the directory of this script and the skip list file location
SCRIPT_DIR="$(dirname "$(realpath "$0")")"

# Copy the script to autostart if not already there
AUTOSTART_DESKTOP="$HOME/.config/autostart/$(basename "$0")-autostart.desktop"

if [ ! -f "$AUTOSTART_DESKTOP" ]; then
    if [ ! -d "$HOME/.config/autostart" ]; then
        mkdir -p "$HOME/.config/autostart"
    fi

    # Create a .desktop file for autostart
    cat <<EOF > "$AUTOSTART_DESKTOP"
[Desktop Entry]
Type=Application
Exec=gnome-terminal -- bash -c 'sustest 150; sleep 60; systemctl reboot -i'
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
