#!/bin/env bash

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PKG_LIST=("needrestart")

$SCRIPT_DIR/install.sh "${PKG_LIST[@]}"
NEEDRESTART1=$(echo -e "\n" | sudo needrestart -v -r a 2>/dev/null | grep -c "you should consider rebooting")
NEEDRESTART2=$(echo -e "\n" | sudo needrestart -v -r a 2>/dev/null | grep -c "Your outdated processes")
if [ $NEEDRESTART1 -gt 0 ]; then
    exit 0
elif  [ $(echo $PATH | grep -c "\.local/bin") -eq 0 ]; then
    exit 0 
elif [ $NEEDRESTART2 -gt 0 ]; then
    exit 0
else
    exit 1
fi
