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
# Purpose: Retrieve the machine's primary IP, core count,
#          send a keepalive POST to the Flask reporting endpoint,
#          and update the local distcc hosts file with the list of servers.
#
# Modify the port, SERVER_URL, and FLASK_SYSTEMS_URL as needed.
# --------------------------------------------------------------

# Retrieve the primary IP address (using the first one reported)
IP_ADDR=$(hostname -I | awk '{print $1}')
PORT=1234
CORES=$(nproc)

# Construct JSON payload.
JSON_PAYLOAD=$(cat <<EOP
{"hostname": "$IP_ADDR", "port": $PORT, "additional_info": {"cores": "$CORES"} }
EOP
)

# URL of the Flask reporting endpoint.
SERVER_URL="http://10.17.89.69:50000/report"

# Send the POST request using curl
curl -s -H "Content-Type: application/json" -X POST -d "$JSON_PAYLOAD" "$SERVER_URL"

# ------------------------------------------------------------------
# Update the local distcc hosts file
# Query the central Flask service for the list of systems.
# ------------------------------------------------------------------
FLASK_SYSTEMS_URL="http://10.17.89.69:50000/systems"
SYSTEMS_JSON=$(curl -s "$FLASK_SYSTEMS_URL")

# Ensure the ~/.distcc directory exists
mkdir -p ~/.distcc

# If jq is available, use it to extract hostname and cores.
if command -v jq >/dev/null 2>&1; then
  echo "$SYSTEMS_JSON" | jq -r '.systems[] | "\(.hostname)/\(.info.cores // "1")"' > ~/.distcc/hosts
else
  # Fallback parsing using grep/awk (may be less robust).
  # This assumes that "hostname" and "cores" always appear in the JSON in order.
  HOSTS=$(echo "$SYSTEMS_JSON" | grep -oP '"hostname":\s*"\K[^"]+')
  CORES=$(echo "$SYSTEMS_JSON" | grep -oP '"cores":\s*"\K[^"]+' )
  paste -d'/' <(echo "$HOSTS") <(echo "$CORES") > ~/.distcc/hosts
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
