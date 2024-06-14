#!/usr/bin/env bash

if [ ! -b "$1" -o ! -n "$2" ]
then
	echo "$0 [block device] [label]" >&2
	exit 1
fi

DEV="$1"
LABEL="$2"

set -ex

sudo parted --align optimal --script "${DEV}" mklabel gpt
sudo parted --align optimal --script "${DEV}" mkpart primary ext4 0% 100%
sudo mkfs.ext4 -F -q -E lazy_itable_init -L "${LABEL}" "${DEV}p1"
