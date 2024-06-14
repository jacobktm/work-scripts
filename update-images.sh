#!/bin/bash

# from: https://github.com/dylanaraps/pure-bash-bible#get-the-directory-name-of-a-file-path
dirname() {
    # Usage: dirname "path"
    local tmp=${1:-.}

    [[ $tmp != *[!/]* ]] && {
        printf '/\n'
        return
    }

    tmp=${tmp%%"${tmp##*[!/]}"}

    [[ $tmp != */* ]] && {
        printf '.\n'
        return
    }

    tmp=${tmp%/*}
    tmp=${tmp%%"${tmp##*[!/]}"}

    printf '%s\n' "${tmp:-/}"
}
SYNC_DIR=""
if sudo test -d /home/oem/cache/sync
then
    errors=999
    if sudo test -f /home/oem/cache/sync/SHA256SUMS
    then
        errors=$(sudo bash -c 'cd /home/oem/cache/sync; sha256sum -c SHA256SUMS | grep -c FAILED')
    fi
    if [ $errors -gt 0 ];
    then
        sudo rm -rvf /home/oem/cache
    else
        SYNC_DIR=/home/oem/cache/sync
    fi
fi
if [ "$SYNC_DIR" == "" ];
then
    SYNC_DIR=$(dirname $(find /media/$USER 2>/dev/null | grep SHA256SUMS.gpg))
fi
echo $SYNC_DIR

if [ "$SYNC_DIR" == '.' ];
then
    echo "No new images found"
    exit 1
fi

sudo rm -rf /root/cache/sync
sudo cp -rT $SYNC_DIR /root/cache/sync
sync
echo "Finished copying files - safe to remove drive"
TEST=`sudo bash -c "cd /root/cache/sync; sha256sum -c SHA256SUMS"`
if [[ $TEST == *"FAILED"* ]];
then
    echo $TEST
    exit 1
fi
sudo rm -rf /root/cache/bootstrap
until sudo apt update
do
    sleep 1
done
sudo apt full-upgrade -y --allow-downgrades
# sudo apt autoremove -y
sudo reboot now
