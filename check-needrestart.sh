#!/bin/env bash

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PKG_LIST=("needrestart")

$SCRIPT_DIR/install.sh "${PKG_LIST[@]}"
NEEDRESTART=$(echo -e "\n" | sudo needrestart -v -r a 2>/dev/null | grep -c "you should consider rebooting")
if [ $NEEDRESTART -gt 0 ]; then
    exit 0
else
    exit 1
fi