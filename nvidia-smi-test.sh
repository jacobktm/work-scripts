#!/bin/bash

if [ $(nvidia-smi | grep -c "NVIDIA-SMI has failed") -eq 0 ]; then
    echo "PASSED"
else
    echo "FAILED"
fi
