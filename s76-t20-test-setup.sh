#!/bin/bash

# Install necessary packages
./install.sh git inxi powertop edid-decode ethtool
cd $HOME
if [ -e system76-ee ]; then
  rm -rvf system76-ee
fi
git clone https://github.com/system76/system76-ee
gsettings set org.gnome.desktop.session idle-delay 900
gsettings set org.gnome.desktop.background picture-uri-dark "file://${HOME}/system76-ee/RGB130130130.svg"
gsettings set org.gnome.desktop.background picture-uri "file://${HOME}/system76-ee/RGB130130130.svg"
gsettings set org.gnome.settings-daemon.plugins.power idle-dim false
gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-timeout 1800
gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type "suspend"
xrandr --verbose | edid-decode > monitor-info.txt
inxi -Fxxxrza > inxi.txt
echo "Energy Efficient Ethernet" > EEE-info.txt
for device in $(nmcli device | awk '$2=="ethernet" {print $1}'); do
    ethtool --show-eee $device >> EEE-info.txt
    echo "" >> EEE-info.txt
done
sudo dmidecode --type 17 > mem-info.txt

# Check if apt-proxy exists, and set the correct APT command
if command -v apt-proxy &>/dev/null; then
    APT_COMMAND="apt-proxy"
else
    APT_COMMAND="sudo apt"
fi

# Check if the system is a laptop by examining the chassis type
echo "Checking if the system is a laptop..."
chassis_type=$(sudo dmidecode --type chassis | grep "Type:" | awk '{print $2}')

if [[ "$chassis_type" == "Notebook" || "$chassis_type" == "Laptop" ]]; then
    echo "System is a laptop. Proceeding with setting the panel brightness."

    # Get the maximum brightness value from sysfs
    if [ -f /sys/class/backlight/*/max_brightness ]; then
        max_brightness=$(cat /sys/class/backlight/*/max_brightness)
        brightness_file="/sys/class/backlight/*/brightness"
    else
        echo "Max brightness file not found!"
        exit 1
    fi

    # Prompt user for the max display brightness in nits for this specific model
    read -p "Enter the maximum display brightness in nits for this model (e.g., 250, 300): " max_nits

    # Prompt user for the desired brightness in nits (must be at least 90 nits)
    read -p "Enter the desired display brightness in nits (must be at least 90 nits): " user_brightness

    # Verify if the entered brightness is a number and greater than 90 nits
    if ! [[ "$user_brightness" =~ ^[0-9]+$ ]] || [ "$user_brightness" -lt 90 ]; then
        echo "Invalid input. Setting brightness to at least 90 nits."
        user_brightness=90
    fi

    # Calculate the brightness value to set in sysfs based on the user's input and max brightness
    target_brightness=$(echo "$user_brightness * $max_brightness / $max_nits" | bc -l)

    # Emulate ceiling to always round up
    # Check if the value is a whole number, if not, round up
    target_brightness_ceiling=$(echo "($target_brightness+0.999)/1" | bc)

    # Ensure the target brightness is at least 1 (to avoid setting it to 0)
    if [ "$target_brightness_ceiling" -lt 1 ]; then
        target_brightness_ceiling=1
    fi

    # Set the backlight value to the calculated target
    echo "Setting backlight brightness to value: $target_brightness_ceiling"
    echo $target_brightness_ceiling | sudo tee $brightness_file

else
    echo "System is not a laptop. Skipping brightness adjustment."
fi

# Update and install packages
until $APT_COMMAND update; do
    sleep 10
done
$APT_COMMAND -y full-upgrade
reboot
