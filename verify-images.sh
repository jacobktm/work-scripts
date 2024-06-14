#!/bin/bash

TEST=`sudo bash -c "cd /root/cache/sync; sha256sum -c SHA256SUMS &>"`
if [ $TEST == *"NOT match"* ];
then
    echo $TEST
    exit
fi
echo "All images OK."
