#!/usr/bin/env bash

# Script to suspend a machine and wake it up multiple times
if [ $# -lt 1 ]; then
  echo "Usage: $0 <n>"
  echo "where <n> is the number of suspends"
  exit 1
fi

if [ -f ./count ]; then
    rm -rvf ./count
fi
if [ -f results.log ]; then
    sudo rm -rvf results.log
fi

PKG_LIST=("fwts" "dbus-x11" "gnome-terminal")

./install.sh "${PKG_LIST[@]}"

gsettings set org.gnome.desktop.session idle-delay 0
gsettings set org.gnome.settings-daemon.plugins.power idle-dim false
gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type "nothing"
gsettings set org.gnome.desktop.screensaver lock-enabled false
gsettings set org.gnome.desktop.screensaver ubuntu-lock-on-suspend false
sudo gnome-terminal -- bash -c 'journalctl -f | grep -i -e tpm -e suspend_test'
sudo fwts s3 --s3-multiple $1 --s3-min-delay 15 --s3-max-delay 30 --s3-resume-hook ./resume-hook.sh
sudo cat /sys/kernel/debug/suspend_stats
