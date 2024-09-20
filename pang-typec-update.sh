#!/bin/bash

# Get the product version from the system
product_version=$(cat /sys/class/dmi/id/product_version)

# Check if the product version is pang12, pang13, or pang14
if [[ "$product_version" == "pang12" || "$product_version" == "pang13" || "$product_version" == "pang14" ]]; then
    # Display a prompt to the user asking if they want to proceed
    zenity --question --text="Detected Pangolin version: $product_version. Would you like to proceed with the Type-C update?" --title="Pangolin Type-C Update" --modal

    # Check the user's response
    if [[ $? -eq 0 ]]; then
        # If the user clicked "Yes", run the command
        gnome-terminal -- bash -c '
PD_VER=$(sudo /home/oem/Documents/stress-scripts/Emdoor_pdupdate -v | grep "PD Version" | awk "{print \$3}")
if [ "$PD_VER" != "0.7" ]; then
    sudo /home/oem/Documents/stress-scripts/Emdoor_pdupdate -f /home/oem/Documents/stress-scripts/emdoor_arb928_v0.7_20240814.bin
else
    echo "Typce-C firmware is already up to date."
fi
exec bash'
        
        # Remove the .desktop file so it doesn't run again
        rm -f $HOME/.config/autostart/pang-typec-update.desktop
    else
        # If the user clicked "No", do nothing and allow the .desktop file to remain for future prompts
        exit 0
    fi
else
    # If the product version is not pang12, pang13, or pang14, exit
    exit 0
fi