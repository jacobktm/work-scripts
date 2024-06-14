#!/bin/bash

if pgrep -x "steam" >/dev/null; then
    kill $(pgrep -x "steam")
    sleep 10
fi