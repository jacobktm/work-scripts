#!/usr/bin/env bash

# attempt to stagger syncing to avoid overwhelming the network
DELAY=$(( RANDOM % 36000 ))
sleep $DELAY

# install or update trubble-sync
until sudo apt update
do
    sleep 30
done
sudo apt install -y trubble-sync

pushd /home/oem
    errors=999
    if [ -e cache/sync/SHA256SUMS ];
    then
        pushd cache/sync
            errors=$(sha256sum -c SHA256SUMS | grep -c FAILED)
        popd
    fi
    if [ $errors -gt 0 ];
    then
        rm -rvf cache
    fi
    sudo trubble-sync
popd