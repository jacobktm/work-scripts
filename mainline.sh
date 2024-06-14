#!/bin/bash

PKG_LIST=("vim" "mainline" "htop")
sudo add-apt-repository -y ppa:cappelikan/ppa
./install.sh "${PKG_LIST[@]}"
