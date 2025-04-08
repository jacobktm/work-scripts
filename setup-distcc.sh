#!/bin/bash
# ================================================================
# Script: setup_keepalive.sh
# Purpose: 
#   1. Connects to a specified Wi‑Fi network (if not already connected)
#      using nmcli.
#   2. Creates a separate keepalive script that sends a keepalive POST 
#      to the central Flask service.
#   3. Configures ccache to use 20GB and sets up symlinks so that
#      gcc/g++ calls go through ccache.
#   4. Sets up distcc by ensuring the distccd daemon is running.
#
# Usage: ./setup_keepalive.sh [SSID] [PASSWORD]
# ================================================================

./install.sh network-manager curl ccache distcc

# Check for exactly 2 arguments (SSID and Password)
if [ "$#" -eq 2 ]; then
    SSID="$1"
    PASSWORD="$2"
    
    # Check if nmcli is available.
    if ! command -v nmcli >/dev/null 2>&1; then
        echo "$(date): nmcli is not installed. Exiting." | tee -a "$LOGFILE"
        exit 1
    fi
        
    # Retrieve the current connected SSID (if any)
    CURRENT_SSID=$(nmcli -t -f active,ssid dev wifi | grep '^yes:' | cut -d':' -f2)

    if [ -n "$CURRENT_SSID" ]; then
        if [ "$CURRENT_SSID" = "$SSID" ]; then
            echo "$(date): Already connected to SSID '$SSID'. Skipping connection attempt." | tee -a "$LOGFILE"
        else
            echo "$(date): Currently connected to SSID '$CURRENT_SSID'. Switching to '$SSID'." | tee -a "$LOGFILE"
            nmcli device wifi connect "$SSID" password "$PASSWORD" >> "$LOGFILE" 2>&1
        fi
    else
        echo "$(date): Not currently connected to any Wi-Fi. Attempting to connect to '$SSID'." | tee -a "$LOGFILE"
        nmcli device wifi connect "$SSID" password "$PASSWORD" >> "$LOGFILE" 2>&1
    fi

    # Check connection status after attempting to connect
    UPDATED_SSID=$(nmcli -t -f active,ssid dev wifi | grep '^yes:' | cut -d':' -f2)
    if [ "$UPDATED_SSID" = "$SSID" ]; then
        echo "$(date): Successfully connected to '$SSID'." | tee -a "$LOGFILE"
    else
        echo "$(date): Failed to connect to '$SSID'." | tee -a "$LOGFILE"
    fi    
fi

LOGFILE="setup_keepalive.log"

# ------------------------------------------------------------------
# Create the separate keepalive script (keepalive.sh)
# This script sends a keepalive POST to the Flask reporting endpoint,
# then queries the central service for the list of distcc hosts and writes
# it to ~/.distcc/hosts.
# ------------------------------------------------------------------

KEEPALIVE_SCRIPT="keepalive.sh"

cat <<'EOF' > "$KEEPALIVE_SCRIPT"
#!/bin/bash
# --------------------------------------------------------------
# Script: keepalive.sh
# Purpose: For each connected physical (wired or wireless) interface,
#          determine the IP and subnet, then send an individual
#          keepalive POST to the Flask reporting endpoint with a 
#          proportional share of cores (nproc divided by the number of
#          connected interfaces). Also update the local distcc hosts.
#
# Modify the port, SERVER_URL, and FLASK_SYSTEMS_URL as needed.
# --------------------------------------------------------------

# Ensure the ~/.distcc directory exists.
mkdir -p ~/.distcc

# Check if the central service is reachable.
RESPONSE=$(curl -I -s --connect-timeout 10 -o /dev/null -w "%{http_code}" "http://10.17.89.69:50000/systems")
if [ "$RESPONSE" -eq 200 ]; then

    # Build an array of physical interfaces that are connected (skip loopback).
    physical_interfaces=()
    for iface in /sys/class/net/*; do
        iface_name=$(basename "$iface")
        if [ "$iface_name" = "lo" ]; then
            continue
        fi
        # Check if the interface is physical (has a device directory).
        if [ -d "/sys/class/net/$iface_name/device" ]; then
            # Confirm it has an IPv4 address.
            ip_with_prefix=$(ip -o -4 addr show "$iface_name" 2>/dev/null | awk '{print $4}')
            if [ -n "$ip_with_prefix" ]; then
                physical_interfaces+=("$iface_name")
            fi
        fi
    done

    # Count the number of connected physical interfaces.
    connected_count=0
    # We'll use associative arrays to store each interface's IP and subnet.
    declare -A iface_ip
    declare -A iface_subnet

    for iface in "${physical_interfaces[@]}"; do
        ip_with_prefix=$(ip -o -4 addr show "$iface" 2>/dev/null | awk '{print $4}')
        if [ -n "$ip_with_prefix" ]; then
            (( connected_count++ ))
            # Extract the IP (dropping the CIDR).
            ip_addr=$(echo "$ip_with_prefix" | cut -d'/' -f1)
            iface_ip["$iface"]=$ip_addr

            # Use ip route to extract the subnet for this interface.
            route_info=$(ip route show dev "$iface" | grep "proto kernel" | head -n1)
            if [ -n "$route_info" ]; then
                subnet=$(echo "$route_info" | awk '{print $1}')
            else
                subnet="unknown"
            fi
            iface_subnet["$iface"]=$subnet
        fi
    done

    # Determine the total number of cores and compute the share per interface.
    TOTAL_CORES=$(nproc)
    ALLOCATED_CORES=$(( TOTAL_CORES / connected_count ))

    PORT=1234
    SERVER_URL="http://10.17.89.69:50000/report"

    # For each connected interface, send a separate POST containing its IP, subnet,
    # and the proportionally divided core count.
    for iface in "${physical_interfaces[@]}"; do
        ip_with_prefix=$(ip -o -4 addr show "$iface" 2>/dev/null | awk '{print $4}')
        if [ -n "$ip_with_prefix" ]; then
            ip_addr=${iface_ip["$iface"]}
            subnet=${iface_subnet["$iface"]}
            JSON_PAYLOAD=$(cat <<EOP
{"hostname": "$ip_addr", "port": $PORT, "additional_info": {"cores": "$ALLOCATED_CORES", "subnet": "$subnet", "interface": "$iface"} }
EOP
)
            # Send the POST request for this interface.
            curl -s -H "Content-Type: application/json" -X POST -d "$JSON_PAYLOAD" "$SERVER_URL"
        fi
    done

    # ------------------------------------------------------------------
    # Update the local distcc hosts file by querying the central Flask service.
    # Only include systems reporting a subnet of "10.17.88.0/22" or any of the
    # subnets our system is currently connected to.
    # ------------------------------------------------------------------
    FLASK_SYSTEMS_URL="http://10.17.89.69:50000/systems"
    SYSTEMS_JSON=$(curl -s "$FLASK_SYSTEMS_URL")

    # Build the allowed subnets array:
    # Start with the fixed subnet, then add each unique local subnet.
    declare -a allowed_subnets
    allowed_subnets+=( "10.17.88.0/22" )
    for iface in "${physical_interfaces[@]}"; do
        subnet=${iface_subnet[$iface]}
        if [[ -n "$subnet" ]]; then
            found=0
            for a in "${allowed_subnets[@]}"; do
                if [ "$a" == "$subnet" ]; then
                    found=1
                    break
                fi
            done
            if [ $found -eq 0 ]; then
                allowed_subnets+=( "$subnet" )
            fi
        fi
    done

    if command -v jq >/dev/null 2>&1; then
        # Convert the allowed subnets array to a JSON array string.
        allowed_json=$(printf '%s\n' "${allowed_subnets[@]}" | jq -R . | jq -s .)
        # Using jq, filter systems to include only those whose .info.subnet is in the allowed list.
        echo "$SYSTEMS_JSON" | jq --argjson allowed "$allowed_json" -r '
          .systems[]
          | select((.info.subnet // "") as $s | $allowed | index($s))
          | "\(.hostname)/\(.info.cores // "1")"
        ' > ~/.distcc/hosts
    else
        echo "Warning: jq is not available. Unable to filter by allowed subnets." >&2
        # Fallback: simply output all systems, unfiltered.
        echo "$SYSTEMS_JSON" | grep -oP '"hostname":\s*"\K[^"]+' > /tmp/hosts.tmp
        echo "$SYSTEMS_JSON" | grep -oP '"cores":\s*"\K[^"]+' > /tmp/cores.tmp
        paste -d'/' /tmp/hosts.tmp /tmp/cores.tmp > ~/.distcc/hosts
        rm /tmp/hosts.tmp /tmp/cores.tmp
    fi
else
    echo "localhost/$(nproc)" > ~/.distcc/hosts
fi

# Launch the distccd daemon if not already running.
if ! pgrep distccd > /dev/null; then
    distccd --daemon --allow "10.17.88.0/22,192.168.1.0/24,192.168.0.0/24,192.168.50.0/24" --log-level info --enable-tcp-insecure
fi
EOF

# Make the keepalive script executable
chmod +x "$KEEPALIVE_SCRIPT"

echo "$(date): Keepalive script '$KEEPALIVE_SCRIPT' created and set as executable." | tee -a "$LOGFILE"

# ------------------------------------------------------------------
# Schedule the keepalive script to run every 5 minutes via cron.
# This adds an entry to the current user's crontab if one doesn't exist.
# ------------------------------------------------------------------
CRON_ENTRY="*/1 * * * * $(pwd)/keepalive.sh >> $(pwd)/keepalive_cron.log 2>&1"

# Check if the crontab already contains an entry for keepalive.sh
if crontab -l 2>/dev/null | grep -q "$(pwd)/keepalive.sh"; then
    echo "$(date): Keepalive cron entry already exists."
else
    # Add the cron entry
    (crontab -l 2>/dev/null; echo "$CRON_ENTRY") | crontab -
    echo "$(date): Keepalive cron entry added: $CRON_ENTRY"
fi

./keepalive.sh

# ------------------------------------------------------------------
# Set Up ccache: Configure ccache to use 20GB cache and symlink ccache
# to masquerade as gcc and g++.
# ------------------------------------------------------------------
if command -v ccache >/dev/null 2>&1; then
    echo "$(date): Configuring ccache to use 100GB." | tee -a "$LOGFILE"
    ccache -M 100G >> "$LOGFILE" 2>&1
    echo "$(date): ccache status:" | tee -a "$LOGFILE"
    ccache -s >> "$LOGFILE" 2>&1

    # Check and create symlinks for gcc and g++ if necessary.
    echo "$(date): Checking if ccache is already linked..." | tee -a "$LOGFILE"
    if [ ! -L /usr/local/bin/gcc ] || [ "$(readlink /usr/local/bin/gcc)" != "$(which ccache)" ]; then
        echo "$(date): Setting up ccache to masquerade as gcc." | tee -a "$LOGFILE"
        sudo ln -sf "$(which ccache)" /usr/local/bin/gcc
    fi
    if [ ! -L /usr/local/bin/g++ ] || [ "$(readlink /usr/local/bin/g++)" != "$(which ccache)" ]; then
        echo "$(date): Setting up ccache to masquerade as g++." | tee -a "$LOGFILE"
        sudo ln -sf "$(which ccache)" /usr/local/bin/g++
    fi
else
    echo "$(date): ccache is not installed. Please install it if you want caching." | tee -a "$LOGFILE"
fi

# ------------------------------------------------------------------
# Set Up distcc: Ensure distccd daemon is running
# ------------------------------------------------------------------
if command -v distccd >/dev/null 2>&1; then
    if pgrep distccd > /dev/null; then
        echo "$(date): distccd is already running." | tee -a "$LOGFILE"
    else
        if [ $(grep -c "distcc_cmdlist" /etc/default/distcc) -eq 0 ]; then
            echo "export DISTCC_CMDLIST=$(pwd)/distcc_cmdlist.cfg" | sudo tee -a /etc/default/distcc
        fi
        echo "$(date): Starting distccd..." | tee -a "$LOGFILE"
        # Start distccd as a daemon and allow connections from your local network.
        # Adjust the allowed network (here: 10.17.89.0/24) as needed.
        distccd --daemon --allow "10.17.88.0/22,192.168.1.0/24,192.168.0.0/24,192.168.50.0/24" --log-level info --enable-tcp-insecure
        echo "$(date): distccd started." | tee -a "$LOGFILE"
    fi
else
    echo "$(date): distccd is not installed. Please install it to set up distcc." | tee -a "$LOGFILE"
fi

# ------------------------------------------------------------------
# End of Setup Script
# ------------------------------------------------------------------
