#!/bin/bash

SCRIPT_PATH=$(cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd)

if [ ! -f "$SCRIPT_PATH/count" ]; then
    echo 0 > "$SCRIPT_PATH/count"
fi
COUNT=$(cat "$SCRIPT_PATH/count")
COUNT=$((COUNT+1))
logger -t suspend_test "Successfully resumed from suspend number $COUNT"
echo $COUNT > "$SCRIPT_PATH/count"