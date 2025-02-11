#!/bin/bash
set -e

# Usage check.
if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <package-list-file>"
    exit 1
fi

PACKAGE_FILE="$1"

# Check if the file exists.
if [ ! -f "$PACKAGE_FILE" ]; then
    echo "Package list file not found: $PACKAGE_FILE"
    exit 1
fi

echo "Removing hold on packages listed in $PACKAGE_FILE..."

# Process each line in the file.
while IFS= read -r package; do
    # Trim whitespace and ignore blank or commented lines.
    package=$(echo "$package" | xargs)
    if [ -z "$package" ] || [[ "$package" =~ ^# ]]; then
        continue
    fi

    echo "Removing hold from package: $package"
    sudo apt-mark unhold "$package"
done < "$PACKAGE_FILE"

echo "Done. The following packages are currently on hold:"
sudo apt-mark showhold
