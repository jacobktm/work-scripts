#!/bin/bash

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
if command -v apt-proxy &>/dev/null; then
    APT_COMMAND="apt-proxy"
    else
        APT_COMMAND="sudo apt"
fi

# Update and install the packages
until $APT_COMMAND update; do
    sleep 10
done
$APT_COMMAND -y full-upgrade
reboot
