#!/bin/bash
set -e

# Determine the directory of this script and the skip list file location
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
for _aliases in "$SCRIPT_DIR/bash_aliases" "$HOME/.bash_aliases"; do
  if [[ -f "$_aliases" ]]; then
    # shellcheck source=/dev/null
    source "$_aliases"
    break
  fi
done

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
Exec=$SCRIPT_DIR/autostart-terminal.sh bash -c 'if [ ! -f .boot_count ]; then echo 0 > .boot_count; fi; COUNT=$(cat .boot_count); sustest 150; sleep 60; echo (($COUNT + 1)) > .boot_count; systemctl reboot -i'
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

# --- Session-specific: COSMIC cosmic-idle vs GNOME gsettings (never both) ---
if declare -f _session_is_cosmic >/dev/null 2>&1 && _session_is_cosmic; then
    if declare -f cosmic_idle_apply_test >/dev/null 2>&1; then
        cosmic_idle_apply_test
    fi
elif declare -f _session_uses_gnome_gsettings >/dev/null 2>&1 && _session_uses_gnome_gsettings; then
    current_lock=$(gsettings get org.gnome.desktop.screensaver lock-enabled 2>/dev/null || echo "error")
    if [ "$current_lock" != "false" ]; then
        echo "Disabling screen lock..."
        gsettings set org.gnome.desktop.screensaver lock-enabled false
    fi
    current_ac=$(gsettings get org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 2>/dev/null || echo "error")
    if [ "$current_ac" != "'nothing'" ]; then
        echo "Disabling auto suspend on AC..."
        gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing'
    fi
    current_battery=$(gsettings get org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type 2>/dev/null || echo "error")
    if [ "$current_battery" != "'nothing'" ]; then
        echo "Disabling auto suspend on battery..."
        gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type 'nothing'
    fi
else
    # bash_aliases not loaded: infer session from XDG only
    _ss_cosmic=0
    [ "${XDG_SESSION_DESKTOP:-}" = COSMIC ] && _ss_cosmic=1
    case ":${XDG_CURRENT_DESKTOP:-}:" in *:COSMIC:*) _ss_cosmic=1 ;; esac
    if [ "$_ss_cosmic" = 1 ] && command -v cosmic-idle >/dev/null 2>&1; then
        _cv1="${XDG_CONFIG_HOME:-$HOME/.config}/cosmic/com.system76.CosmicIdle/v1"
        mkdir -p "$_cv1"
        printf '%s\n' None >"$_cv1/screen_off_time"
        printf '%s\n' None >"$_cv1/suspend_on_battery_time"
        printf '%s\n' None >"$_cv1/suspend_on_ac_time"
    elif [ "$_ss_cosmic" = 0 ] && command -v gsettings >/dev/null 2>&1; then
        current_lock=$(gsettings get org.gnome.desktop.screensaver lock-enabled 2>/dev/null || echo "error")
        [ "$current_lock" != "false" ] && gsettings set org.gnome.desktop.screensaver lock-enabled false
        current_ac=$(gsettings get org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 2>/dev/null || echo "error")
        [ "$current_ac" != "'nothing'" ] && gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing'
        current_battery=$(gsettings get org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type 2>/dev/null || echo "error")
        [ "$current_battery" != "'nothing'" ] && gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type 'nothing'
    fi
fi

# --- Enable Autologin (COSMIC greetd or GDM via bash_aliases autologin_enable) ---
if declare -f autologin_enable >/dev/null 2>&1; then
    autologin_enable
else
    if [ -f /etc/gdm3/custom.conf ]; then
        GDM_CONF="/etc/gdm3/custom.conf"
    elif [ -f /etc/gdm/custom.conf ]; then
        GDM_CONF="/etc/gdm/custom.conf"
    else
        echo "GDM configuration file not found. Autologin not enabled (source bash_aliases for COSMIC greetd)." >&2
        GDM_CONF=""
    fi
    if [ -n "$GDM_CONF" ]; then
        if ! grep -qE "^\s*AutomaticLoginEnable\s*=\s*true" "$GDM_CONF"; then
            echo "Enabling autologin (AutomaticLoginEnable)..."
            sudo sed -i 's/^\s*#\?\s*AutomaticLoginEnable\s*=.*/AutomaticLoginEnable = true/' "$GDM_CONF"
        fi
        if ! grep -qE "^\s*AutomaticLogin\s*=\s*$USERNAME" "$GDM_CONF"; then
            echo "Setting autologin user to $USERNAME..."
            sudo sed -i 's/^\s*#\?\s*AutomaticLogin\s*=.*/AutomaticLogin = '"$USERNAME"'/' "$GDM_CONF"
        fi
    fi
fi
