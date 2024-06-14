#!/bin/bash

# This script expects the first argument to be the action: 'add' or 'remove'
ACTION=$1
DEVICE_UUID="<DEVICE UUID HERE>"
PARTITION=$(blkid -o device -t UUID="$DEVICE_UUID")
MOUNT_POINT_BASE="/media"
USER_NAME="<USER NAME HERE>"  # This needs to be dynamically determined or hardcoded
PASSWORD="<PASSWORD HERE>"

if [ "$ACTION" == "add" ]; then
    if cryptsetup status "luks-${DEVICE_UUID}" &> /dev/null; then
	    cryptsetup luksClose "luks-${DEVICE_UUID}"
    fi
    # Decrypt, check, repair, and mount as before
    if [ ! -z "$PARTITION" ]; then
        echo "$PASSWORD" | cryptsetup luksOpen "$PARTITION" "luks-${DEVICE_UUID}"
        # After decryption, retrieve the filesystem label
        while [ ! -e "/dev/mapper/luks-${DEVICE_UUID}" ]; do sleep 1; done
        DISK_LABEL=$(blkid -o value -s LABEL "/dev/mapper/luks-${DEVICE_UUID}")
        MOUNT_POINT="$MOUNT_POINT_BASE/$USER_NAME/$DISK_LABEL"
	    if mountpoint -q "$MOUNT_POINT"; then
	        fuser -k "$MOUNT_POINT"
            SYSTEMCTL_MOUNT=$(systemctl list-units --type=mount | grep $MOUNT_POINT | awk '{print $1}')
	        systemctl stop "$SYSTEMCTL_MOUNT"
        fi
        if [ -d "$MOUNT_POINT" ]; then
            rm -rf "$MOUNT_POINT"
	    fi
        fsck -y "/dev/mapper/luks-${DEVICE_UUID}"
	    runuser -u "$USER_NAME" -- gdbus call --system --dest org.freedesktop.UDisks2 --object-path /org/freedesktop/UDisks2/block_devices/$(basename $(readlink -f /dev/mapper/luks-${DEVICE_UUID}) | sed 's/-/_2d/g') --method org.freedesktop.UDisks2.Filesystem.Mount '@a{sv} []'
    fi
elif [ "$ACTION" == "remove" ]; then
    DISK_LABEL=$(blkid -o value -s LABEL "/dev/mapper/luks-${DEVICE_UUID}")
    MOUNT_POINT="$MOUNT_POINT_BASE/$USER_NAME/$DISK_LABEL"
    if mountpoint -q "$MOUNT_POINT"; then
	    fuser -k "$MOUNT_POINT"
        SYSTEMCTL_MOUNT=$(systemctl list-units --type=mount | grep $MOUNT_POINT | awk '{print $1}')
	    systemctl stop "$SYSTEMCTL_MOUNT"
    fi
    if cryptsetup status "luks-${DEVICE_UUID}" > /dev/null 2>&1; then
	    cryptsetup luksClose "luks-${DEVICE_UUID}"
    fi
    # Optionally, remove the mount point directory after unmounting.
    [ -d "$MOUNT_POINT" ] && rmdir "$MOUNT_POINT"
else
    logger -t encrypted-mount "Unknown action: $ACTION"
    exit 1
fi
