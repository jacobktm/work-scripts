#!/bin/bash

$HOME_TMP=$HOME
if pgrep -x "steam" >/dev/null; then
    kill $(pgrep -x "steam")
    sleep 10
fi
HOME="/home/${USER}"
screen -d -m steam &
HOME=$HOME_TMP
sleep 15