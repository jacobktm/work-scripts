#!/bin/bash

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
START_TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")
LOG_FILE=""
RUN_TIME=0
PKG_LIST=("htop" "stress-ng" "glmark2")

$SCRIPT_DIR/install.sh "${PKG_LIST[@]}"

if [ ! -e .run_count ];
then
    echo "1" > .run_count
    LOG_FILE="${HOME}/Desktop/test_run_1.log"
else
    TEST_RUN_COUNT=$(cat .run_count)
    TEST_RUN_COUNT=$((TEST_RUN_COUNT + 1))
    echo "$TEST_RUN_COUNT" > .run_count
    LOG_FILE="test_run_${TEST_RUN_COUNT}.log"
fi

gsettings set org.gnome.desktop.session idle-delay 0
gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type "nothing"
gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type "nothing"
gnome-terminal --name=stress-ng --title=stress-ng -- bash -c "while true; do stress-ng -c 0 -m 0 --vm-bytes 25G; done"
gnome-terminal --name=glmark2 --title=glmark2 -- bash -c "glmark2 --run-forever"
gnome-terminal --name=journalctl --title=journalctl -- bash -c "journalctl -f | grep mce"
gnome-terminal --name=htop --title=htop -- bash -c "htop"
while true
do
    date
    OUTPUT="Start test run ${START_TIMESTAMP}\nRuntime: $RUN_TIME minutes\n"
    OUTPUT+=$(journalctl --since="${START_TIMESTAMP}" | grep -A 6 mce)
    echo -e "$OUTPUT" > $LOG_FILE
    sleep 60
    RUN_TIME=$((RUN_TIME + 1))
done