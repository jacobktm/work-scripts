#!/bin/bash

# Path to .desktop file
DESKTOP_FILE="$HOME/.config/autostart/add_local_bin.desktop"

# Check if $HOME/.local/bin is already in .bashrc
if ! grep -q "$HOME/.local/bin" "$HOME/.bashrc"; then
    echo "export PATH=$HOME/Documents/stress-scripts/bin:$HOME/.local/bin:\$PATH" >> "$HOME/.bashrc"
fi

# Check and set timezone to Denver if not already set
if command -v timedatectl >/dev/null 2>&1; then
    CURRENT_TZ=$(timedatectl show -p Timezone --value)
    if [ "$CURRENT_TZ" != "America/Denver" ]; then
        sudo timedatectl set-timezone America/Denver
    fi
else
    echo "timedatectl command not found. Cannot check or set timezone."
fi

# Remove the .desktop autorun file after execution
if [ -f "$DESKTOP_FILE" ]; then
    rm -f "$DESKTOP_FILE"
fi