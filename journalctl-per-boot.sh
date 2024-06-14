#!/bin/bash

# Get the number of boots
num_boots=$(journalctl --list-boots | wc -l)

# Output the logs for each boot
for ((i=0; i<num_boots; i++)); do
    # Renumber the boots starting from 1
    renumbered_boot=$(( num_boots - i ))
    # Format the boot number with leading zeros
    formatted_boot=$(printf "%02d" $renumbered_boot)
    journalctl -b -$i > "journal_${formatted_boot}.log"
done