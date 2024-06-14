#!/bin/bash

Help()
{
    echo "Usage: s76-journalctl.sh <time> [options]"
    echo ""
    echo "options:"
    echo "-b <boot>        Get journalctl for specified boot."
    echo "-o <filename>    Specify output filename."
    echo "-h               Display this message and exit."
}

BOOT=""
FILENAME="journalctl.log"
SEEN=0

while getopts ":hb:o:" option; do
   case $option in
        h) # help text
            Help
            exit;;
        b) # Serial Num
            BOOT=" -b $OPTARG";;
        o) # filename
            FILENAME=$OPTARG;;
        *) # Invalid option
            echo "Error: Invalid option" 1>&2
	        Help 1>&2
            exit 1;;
   esac
done

# Temporary file to store new lines.
temp_output=$(mktemp)
temp_journal=$(mktemp)

# Fetch the entire journal since the given timestamp.
sudo journalctl${BOOT} > "$temp_journal"

grep -Ef PATTERNS "$temp_journal" | grep -vEf IGNORE_PATTERNS > "$temp_output"

# Update SINCE to now, so the next iteration will pick up logs from this moment onward.

# Process the new lines.
while IFS= read -r line; do
    if [ -f "$FILENAME" ]; then
        SEEN=$(grep -c "$line" "$FILENAME")
    fi
    if [ $SEEN -gt 0 ]; then
        continue
    fi

    timestamp=$(echo "$line" | awk '{print $1, $2, $3}')

    if [[ $line == *"[ cut here ]"* ]]; then
        block=$(awk -v start_pat="${timestamp}.*\\[ cut here \\]" \
            -v stop_pat="${timestamp}.*\\[ end trace [0-9a-fA-F]+ \\]" \
            'BEGIN{flag=0} $0 ~ start_pat{flag=1} flag && $0 ~ stop_pat{print; flag=0; exit} flag' "$temp_journal")
        if [[ -n $block ]]; then
            echo "$block" >> "$FILENAME"
        else
            echo "$line" >> "$FILENAME"
        fi
    elif [[ $line == *"invoked oom-killer"* ]]; then
        block=$(awk -v start_pat="${timestamp}.*invoked oom-killer" \
            -v stop_pat="${timestamp}.*Out of memory" \
            'BEGIN{flag=0} $0 ~ start_pat{flag=1} flag && $0 ~ stop_pat{print; flag=0; exit} flag' "$temp_journal")
        if [[ -n $block ]]; then
            echo "$block" >> "$FILENAME"
        else
            echo "$line" >> "$FILENAME"
        fi
    elif [[ $line == *"Oops:"* ]]; then
        block=$(awk -v start_pat="${timestamp}.*Oops:" \
            -v stop_pat="${timestamp}.*</TASK>" \
            'BEGIN{flag=0} $0 ~ start_pat{flag=1} flag && $0 ~ stop_pat{print; flag=0; exit} flag' "$temp_journal")
        if [[ -n $block ]]; then
            echo "$block" >> "$FILENAME"
        else
            echo "$line" >> "$FILENAME"
        fi
    elif [[ $line == *"Modules linked in:"* ]]; then
        block=$(awk -v start_pat="${timestamp}.*Modules linked in:" \
            -v stop_pat="${timestamp}.*</TASK>" \
            'BEGIN{flag=0} $0 ~ start_pat{flag=1} flag && $0 ~ stop_pat{print; flag=0; exit} flag' "$temp_journal")
        if [[ -n $block ]]; then
            echo "$block" >> "$FILENAME"
        else
            echo "$line" >> "$FILENAME"
        fi
    elif [[ $line == *"segfault"* ]]; then
        block=$(awk -v start_pat="${timestamp}.*segfault" \
            -v stop_pat="${timestamp}.*Code:" \
            'BEGIN{flag=0} $0 ~ start_pat{flag=1} flag && $0 ~ stop_pat{print; flag=0; exit} flag' "$temp_journal")
        if [[ -n $block ]]; then
            echo "$block" >> "$FILENAME"
        else
            echo "$line" >> "$FILENAME"
        fi
    elif [[ $line == *"GPU reset begin"* ]]; then
        block=$(awk -v start_pat="${timestamp}.*GPU reset begin" \
            -v stop_pat="${timestamp}.*amdgpu: soft reset" \
            'BEGIN{flag=0} $0 ~ start_pat{flag=1} flag && $0 ~ stop_pat{print; flag=0; exit} flag' "$temp_journal")
        if [[ -n $block ]]; then
            echo "$block" >> "$FILENAME"
        else
            echo "$line" >> "$FILENAME"
        fi
    else
        echo "$line" >> "$FILENAME"
    fi
done < "$temp_output"