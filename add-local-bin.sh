#!/bin/bash

# Path to .desktop file
DESKTOP_FILE="/home/oem/.config/autostart/add-local-bin.desktop"

# Check and set timezone to Denver if not already set
gnome-terminal -- bash -c '
echo -e "if [ -d ~/.bash_completion.d ]; then\n    for f in ~/.bash_completion.d/*; do\n        . \"\$f\"\n    done\nfi" >> /home/oem/.bashrc
if command -v timedatectl >/dev/null 2>&1; then
    CURRENT_TZ=$(timedatectl show -p Timezone --value)
    if [ "$CURRENT_TZ" != "America/Denver" ]; then
        timedatectl set-timezone America/Denver
    fi
fi'

# Remove the .desktop autorun file after execution
if [ -f "$DESKTOP_FILE" ]; then
    rm -f "$DESKTOP_FILE"
fi