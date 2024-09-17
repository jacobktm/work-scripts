#!/usr/bin/env bash

until sudo apt update
do
    sleep 1
done
sudo apt install -y gcc-12 g++-12
sudo apt full-upgrade -y
sudo apt autoremove -y
sudo apt-add-repository -y ppa:system76-dev/stable
sudo apt update
NVIDIA=""
NVIDIA_PRESENT=`lspci | grep -c NVIDIA`
if [ $NVIDIA_PRESENT -gt 0 ]; then
    NVIDIA=" system76-driver-nvidia"
fi
sudo apt install -y --allow-downgrades system76-driver${NVIDIA}
sudo apt full-upgrade -y --allow-downgrades
sudo apt autoremove -y
if [ -e ./check-needrestart.sh ]; then
    ./check-needrestart.sh
    if [ $? -eq 0 ];
    then
        systemctl reboot -i
    fi
fi