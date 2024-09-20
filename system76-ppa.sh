#!/usr/bin/env bash

apt_command() {
    if command -v apt-proxy &>/dev/null; then
        apt-proxy "$@"
    else
        sudo apt "$@"
    fi
}

until apt_command update
do
    sleep 1
done
apt_command install -y gcc-12 g++-12
apt_command full-upgrade -y
apt_command autoremove -y
sudo apt-add-repository -y ppa:system76-dev/stable
until apt_command update; do
    sleep 1
done
NVIDIA=""
NVIDIA_PRESENT=`lspci | grep -c NVIDIA`
if [ $NVIDIA_PRESENT -gt 0 ]; then
    NVIDIA=" system76-driver-nvidia"
fi
apt_command install -y --allow-downgrades system76-driver${NVIDIA}
apt_command full-upgrade -y --allow-downgrades
apt_command autoremove -y
if [ -e ./check-needrestart.sh ]; then
    ./check-needrestart.sh
    if [ $? -eq 0 ];
    then
        systemctl reboot -i
    fi
fi