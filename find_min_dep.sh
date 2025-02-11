#!/bin/bash
set -e

# Usage: ./find_minimal_dependency.sh <package>
if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <package>"
    exit 1
fi

PACKAGE="$1"
echo "Simulating installation of package: $PACKAGE"
echo "----------------------------------------------"

# Run a full simulation of installing the main package.
# (We use 'sudo apt install -s' so that the output closely matches what you see manually.)
simulation_output=$(sudo apt install -s "$PACKAGE" 2>/dev/null)

# Extract the package names from every line starting with "Inst"
# The expected format is: "Inst <package> ( ...", so we take the second field.
packages=$(echo "$simulation_output" | grep "^Inst" | awk '{print $2}' | sort -u)

# Check that we got at least one package.
if [ -z "$packages" ]; then
    echo "No packages found in the simulation output for '$PACKAGE'."
    exit 1
fi

echo "Found the following packages in the simulation that would be installed:"
echo "$packages"
echo

declare -A install_counts

# For each package in the extracted list, simulate its individual installation and count its "Inst" lines.
for pkg in $packages; do
    echo "Simulating installation for package: $pkg"
    pkg_simulation=$(sudo apt install -s "$pkg" 2>/dev/null)
    
    # Count every occurrence of a line starting with "Inst"
    count=$(echo "$pkg_simulation" | grep -E "^Inst" | wc -l)
    install_counts["$pkg"]=$count
    
    echo "  -> Installing '$pkg' individually would result in $count package(s) being installed."
    echo
done

# Determine which package installs the fewest packages.
min_pkg=""
min_count=1000000

echo "Summary of individual installation counts:"
for pkg in "${!install_counts[@]}"; do
    echo "  $pkg: ${install_counts[$pkg]}"
    if [ "${install_counts[$pkg]}" -lt "$min_count" ]; then
        min_count=${install_counts[$pkg]}
        min_pkg="$pkg"
    fi
done

echo
echo "The package that installs the fewest packages individually is:"
echo "  $min_pkg (it would install $min_count package(s))"
