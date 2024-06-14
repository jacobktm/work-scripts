#!/bin/bash

sudo apt update
sudo apt install -y git build-essential gnat flex bison libncurses5-dev wget zlib1g-dev

cd ~/Documents/Git
if [ -e firmware-open ]; then
  rm -rvf firmware-open
fi
git clone git@github.com:system76/firmware-open.git
cd firmware-open
git submodule update --recursive --init --checkout
bash ./scripts/deps.sh
cd edk2
python -m pip install -r pip-requirements.txt
cd ..
cd coreboot
make crosstools CPUS=$(nproc)
cd ..
