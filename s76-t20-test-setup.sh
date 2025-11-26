#!/bin/bash

# Flask service endpoint for submitting TEC data
FLASK_SERVICE_URL="http://10.17.89.69:7432/api"
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
SCRIPT_PATH="$(realpath "$0")"
AUTOSTART_DIR="${HOME}/.config/autostart"
AUTORUN_DESKTOP="${AUTOSTART_DIR}/s76-t20-test-setup.desktop"
UPDATE_MARKER="${HOME}/.update"
AUTORUN_CLEANUP_PENDING="false"

if [ ! -f "$UPDATE_MARKER" ]; then
    mkdir -p "$AUTOSTART_DIR"
    cat > "$AUTORUN_DESKTOP" <<EOF
[Desktop Entry]
Type=Application
Name=System76 T20 Setup
Comment=Resume T20 test setup after applying updates
Exec=$SCRIPT_PATH
Terminal=true
X-GNOME-Autostart-enabled=true
EOF
    chmod +x "$AUTORUN_DESKTOP"
    touch "$UPDATE_MARKER"

    echo "Initial update phase detected. Installing system updates before T20 setup..."
    if command -v apt-proxy &>/dev/null; then
        APT_COMMAND="apt-proxy"
    else
        APT_COMMAND="sudo apt"
    fi

    until $APT_COMMAND update; do
        echo "apt update failed, retrying in 10 seconds..."
        sleep 10
    done
    $APT_COMMAND -y full-upgrade

    echo "Updates applied. Rebooting to continue T20 setup."
    sudo reboot
    exit 0
else
    # Don't remove marker/desktop files yet - we'll check for battery first
    AUTORUN_CLEANUP_PENDING="true"
fi

# Check for battery and prompt user to note capacity, then shutdown for battery removal
# This must happen before any setup work (git clone, settings changes, etc.)
BATTERY_CAPACITY_FILE="/tmp/battery_capacity_wh.txt"
battery_device=$(ls /sys/class/power_supply/ 2>/dev/null | grep -E '^BAT[0-9]' | head -1)
# Cache system/chassis metadata for reuse throughout the script
DMI_TYPE0=$(sudo dmidecode --type 0 2>/dev/null)
DMI_TYPE1=$(sudo dmidecode --type 1 2>/dev/null)
DMI_TYPE2=$(sudo dmidecode --type 2 2>/dev/null)
DMI_TYPE17=$(sudo dmidecode --type 17 2>/dev/null)
DMI_CHASSIS=$(sudo dmidecode --type chassis 2>/dev/null)
BIOS_VENDOR=$(echo "$DMI_TYPE0" | grep "Vendor:" | head -1 | cut -d: -f2 | xargs)
BIOS_VERSION=$(echo "$DMI_TYPE0" | grep "Version:" | head -1 | cut -d: -f2 | xargs)
BIOS_DATE=$(echo "$DMI_TYPE0" | grep "Release Date:" | head -1 | cut -d: -f2 | xargs)
BIOS_RELEASE_DATE="$BIOS_DATE"
SYSTEM_MANUFACTURER=$(echo "$DMI_TYPE1" | grep "Manufacturer:" | head -1 | cut -d: -f2 | xargs)
PRODUCT_NAME=$(echo "$DMI_TYPE1" | grep "Product Name:" | head -1 | cut -d: -f2 | xargs)
SYSTEM_VERSION=$(echo "$DMI_TYPE1" | grep "Version:" | head -1 | cut -d: -f2 | xargs)
BASEBOARD_MANUFACTURER=$(echo "$DMI_TYPE2" | grep "Manufacturer:" | head -1 | cut -d: -f2 | xargs)
BASEBOARD_PRODUCT=$(echo "$DMI_TYPE2" | grep "Product Name:" | head -1 | cut -d: -f2 | xargs)
BASEBOARD_VERSION=$(echo "$DMI_TYPE2" | grep "Version:" | head -1 | cut -d: -f2 | xargs)
CHASSIS_TYPE=$(echo "$DMI_CHASSIS" | grep "Type:" | head -1 | cut -d: -f2 | xargs)
CHASSIS_MANUFACTURER=$(echo "$DMI_CHASSIS" | grep "Manufacturer:" | head -1 | cut -d: -f2 | xargs)
CHASSIS_VERSION=$(echo "$DMI_CHASSIS" | grep "Version:" | head -1 | cut -d: -f2 | xargs)
PRODUCT_LOWER=$(echo "$PRODUCT_NAME" | tr '[:upper:]' '[:lower:]')
VERSION_LOWER=$(echo "$SYSTEM_VERSION" | tr '[:upper:]' '[:lower:]')
BASEBOARD_VERSION_LOWER=$(echo "$BASEBOARD_VERSION" | tr '[:upper:]' '[:lower:]')
CHASSIS_TYPE_LOWER=$(echo "$CHASSIS_TYPE" | tr '[:upper:]' '[:lower:]')
IS_NOTEBOOK="false"
if [[ "$CHASSIS_TYPE_LOWER" == "notebook" || "$CHASSIS_TYPE_LOWER" == "laptop" ]]; then
    IS_NOTEBOOK="true"
fi
IS_PORTABLE_ALL_IN_ONE="false"
if [[ "$CHASSIS_TYPE_LOWER" == portable* ]] || [[ "$CHASSIS_TYPE_LOWER" == "portable all in one" ]] || [[ "$PRODUCT_LOWER" == meer* ]] || [[ "$VERSION_LOWER" == meer* ]]; then
    IS_PORTABLE_ALL_IN_ONE="true"
fi

BATTERY_REMOVED="false"
if [[ "$CHASSIS_TYPE" == "Notebook" || "$CHASSIS_TYPE" == "Laptop" ]] && [ -z "$battery_device" ]; then
    BATTERY_REMOVED="true"
fi

if [ -n "$battery_device" ]; then
    echo "=========================================="
    echo "BATTERY DETECTED: ${battery_device}"
    echo "=========================================="
    echo ""
    echo "Please check the battery label and note the capacity printed on it (in Wh)."
    echo "The system will shutdown after you press Enter so you can remove the battery."
    echo ""
    read -p "Press Enter when ready to shutdown and remove the battery... "
    
    echo ""
    echo "Shutting down system in 5 seconds..."
    sleep 5
    sudo shutdown -h now
    exit 0
fi

# Clean up autorun files after battery check
# Only keep them if this is a notebook and we just shut down for battery removal
# (which means we'll be autorunning again after the shutdown)
if [ "$AUTORUN_CLEANUP_PENDING" = "true" ]; then
    # If we're here and battery was detected, the script would have already exited above
    # So we only reach here if no battery was detected, meaning we can safely clean up
    rm -f "$UPDATE_MARKER"
    rm -f "$AUTORUN_DESKTOP"
fi

# If no battery detected, check for saved capacity from previous run
# If not found, prompt for capacity (engineer should have noted it before removing)
if [ -f "$BATTERY_CAPACITY_FILE" ]; then
    battery_capacity_wh=$(cat "$BATTERY_CAPACITY_FILE" 2>/dev/null | xargs)
    rm -f "$BATTERY_CAPACITY_FILE"
elif [ -f ~/battery_capacity_wh.txt ]; then
    battery_capacity_wh=$(cat ~/battery_capacity_wh.txt 2>/dev/null | xargs)
    rm -f ~/battery_capacity_wh.txt
else
    # No battery and no saved capacity - check if this is a notebook
    if [[ "$CHASSIS_TYPE" == "Notebook" || "$CHASSIS_TYPE" == "Laptop" ]]; then
        echo "No battery detected. Please enter the battery capacity that was noted before removal."
        read -p "Enter battery capacity from the label (in Wh): " battery_capacity_wh
        echo ""
    fi
fi

# Install necessary packages
./install.sh git inxi powertop edid-decode ethtool jq bc
cd $HOME
if [ -e system76-ee ]; then
  rm -rvf system76-ee
fi
git clone https://github.com/system76/system76-ee
gsettings set org.gnome.desktop.session idle-delay 900
gsettings set org.gnome.desktop.background picture-uri-dark "file://${HOME}/system76-ee/RGB130130130.svg"
gsettings set org.gnome.desktop.background picture-uri "file://${HOME}/system76-ee/RGB130130130.svg"
gsettings set org.gnome.settings-daemon.plugins.power idle-dim false
gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-timeout 1800
gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type "suspend"
xrandr --verbose | edid-decode > monitor-info.txt
inxi -Fxxxrza > inxi.txt
echo "Energy Efficient Ethernet" > EEE-info.txt
for device in $(nmcli device | awk '$2=="ethernet" {print $1}'); do
    ethtool --show-eee $device >> EEE-info.txt
    echo "" >> EEE-info.txt
done
echo "$DMI_TYPE17" > mem-info.txt

# Function to collect system information for TEC score calculation
collect_tec_info() {
    local output_file="t20-eut.txt"
    local json_file="t20-eut.json"
    local es_response_file=""  # Will be set if expandability calculation is performed
    local has_discrete_gpu_detected="false"
    
    echo "Collecting system information for TEC score calculation..."
    echo ""
    
    # Prompt for motherboard model number
    read -p "Enter motherboard model number (or press Enter to skip): " motherboard_model_number
    echo ""
    
    # Prompt for power supply model number
    read -p "Enter power supply model number (or press Enter to skip): " psu_model_manual
    echo ""
    
    # Initialize JSON object
    {
        echo "{"
        echo "  \"timestamp\": \"$(date -Iseconds)\","
        
        # System Information
        echo "  \"system\": {"
        echo "    \"manufacturer\": \"${SYSTEM_MANUFACTURER}\","
        echo "    \"product_name\": \"${PRODUCT_NAME}\","
        echo "    \"version\": \"${SYSTEM_VERSION}\","
        
        # BIOS Information
        local bios_vendor="$BIOS_VENDOR"
        local bios_version="$BIOS_VERSION"
        local bios_date="$BIOS_RELEASE_DATE"
        echo "    \"bios_vendor\": \"${bios_vendor}\","
        echo "    \"bios_version\": \"${bios_version}\","
        echo "    \"bios_date\": \"${bios_date}\","
        
        # Get chassis type early (needed for expandability prompt logic)
        local chassis_type="$CHASSIS_TYPE"
        local is_notebook="$IS_NOTEBOOK"
        
        # Get identifiers for expandability lookup
        local lookup_identifier=""
        if [ -n "$SYSTEM_VERSION" ]; then
            lookup_identifier="$SYSTEM_VERSION"
        fi
        
        # Look up expandability score from lookup file using baseboard version
        local expandability_score=""
        local mobile_gaming_system="false"
        # Use SCRIPT_DIR set at top of script (before any cd commands)
        local current_dir=$(pwd)
        local lookup_file=""
        
        # Try SCRIPT_DIR first (where script is located), then current directory
        if [ -f "${SCRIPT_DIR}/system-expandability-scores.json" ]; then
            lookup_file="${SCRIPT_DIR}/system-expandability-scores.json"
        elif [ -f "${current_dir}/system-expandability-scores.json" ]; then
            lookup_file="${current_dir}/system-expandability-scores.json"
        else
            lookup_file="${SCRIPT_DIR}/system-expandability-scores.json"
        fi
        
        if [ -f "$lookup_file" ] && command -v jq &> /dev/null; then
            local lookup_key=""
            local lookup_result=""
            
            # First try baseboard version
            if [ -n "$lookup_identifier" ]; then
                lookup_key=$(echo "$lookup_identifier" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]//g')
                if [ -n "$lookup_key" ]; then
                    lookup_result=$(jq -r ".[\"$lookup_key\"] // empty" "$lookup_file" 2>/dev/null)
                    # Only use if it's a valid number (not "null" string or empty)
                    if [ -n "$lookup_result" ] && [ "$lookup_result" != "null" ] && [[ "$lookup_result" =~ ^[0-9]+$ ]]; then
                        expandability_score="$lookup_result"
                    fi
                fi
            fi
        fi    
        
        # If notebook has an expandability score, it must be a mobile gaming system
        if [ -n "$expandability_score" ] && [ "$is_notebook" = "true" ]; then
            mobile_gaming_system="true"
        fi
        
        # If expandability score not found, prompt user
        # Skip this entire block if we already have a score (especially for notebooks)
        if [ -z "$expandability_score" ]; then
            # Create response file for expandability calculation
            local system_name_safe=$(echo "$PRODUCT_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | sed 's/--*/-/g' | sed 's/^-//' | sed 's/-$//')
            es_response_file="${system_name_safe}-es.txt"  # Make it accessible outside this block
            
            # Initialize response file
            {
                echo "Expandability Score Calculation Responses"
                echo "========================================"
                echo "System: ${PRODUCT_NAME}"
                echo "Expandability Lookup Identifier: ${lookup_identifier}"
                echo "Date: $(date -Iseconds)"
                echo ""
            } > "$es_response_file"
            
            local should_calculate_es="false"
            
            if [ "$is_notebook" = "true" ]; then
                # Battery capacity should already be set from the prompt at the start of the function
                # If not set (shouldn't happen for notebooks), prompt now
                if [ -z "$battery_capacity_wh" ]; then
                    read -p "Enter battery capacity in Wh: " battery_capacity_wh
                    [ -n "$battery_capacity_wh" ] && battery_capacity_wh_numeric=$(echo "$battery_capacity_wh" | tr -dc '0-9.')
                fi
                
                local can_be_mobile_gaming="false"
                
                # Minimum battery capacity threshold for mobile gaming systems (75Wh)
                # Systems below this cannot qualify as mobile gaming systems
                local min_battery_capacity=75
                
                # Check for discrete GPU (NVIDIA or AMD)
                local has_discrete_gpu="$has_discrete_gpu_detected"
                if command -v nvidia-smi &> /dev/null && nvidia-smi &>/dev/null 2>/dev/null; then
                    # Check if NVIDIA GPU is present and not just integrated
                    local gpu_name=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 | xargs)
                    if [ -n "$gpu_name" ] && [[ ! "$gpu_name" =~ "Intel|integrated" ]]; then
                        has_discrete_gpu="true"
                        has_discrete_gpu_detected="true"
                    fi
                fi
                
                # Also check for AMD GPU via lspci
                if [ "$has_discrete_gpu" != "true" ]; then
                    if lspci 2>/dev/null | grep -qi "vga.*amd\|display.*amd\|radeon"; then
                        has_discrete_gpu="true"
                        has_discrete_gpu_detected="true"
                    fi
                fi
                
                echo "" >> "$es_response_file"
                echo "Battery Capacity: ${battery_capacity_wh} Wh" >> "$es_response_file"
                echo "Has Discrete GPU: ${has_discrete_gpu}" >> "$es_response_file"
                echo "System Memory (GB): ${total_memory_gb_numeric:-unknown}" >> "$es_response_file"
                
                # Check battery capacity
                local battery_check_passed="false"
                if [ -n "$battery_capacity_wh" ] && [ "$(echo "$battery_capacity_wh >= $min_battery_capacity" | bc 2>/dev/null || echo "0")" = "1" ]; then
                    battery_check_passed="true"
                    echo "Battery capacity check: PASSED (≥${min_battery_capacity}Wh)" >> "$es_response_file"
                elif [ -n "$battery_capacity_wh" ]; then
                    echo "Battery capacity check: FAILED (<${min_battery_capacity}Wh)" >> "$es_response_file"
                fi
                
                # Check discrete GPU
                local gpu_check_passed="false"
                if [ "$has_discrete_gpu" = "true" ]; then
                    gpu_check_passed="true"
                    echo "Discrete GPU check: PASSED" >> "$es_response_file"
                else
                    echo "Discrete GPU check: FAILED" >> "$es_response_file"
                fi
                
                # Check system memory capacity (>=16 GB)
                local memory_check_passed="false"
                if [ -n "$total_memory_gb_numeric" ] && [ "$(echo "$total_memory_gb_numeric >= 16" | bc 2>/dev/null || echo "0")" = "1" ]; then
                    memory_check_passed="true"
                    echo "System memory check: PASSED (≥16GB)" >> "$es_response_file"
                elif [ -n "$total_memory_gb_numeric" ]; then
                    echo "System memory check: FAILED (<16GB)" >> "$es_response_file"
                else
                    echo "System memory check: UNKNOWN" >> "$es_response_file"
                fi
                
                # System can be mobile gaming only if both checks pass
                if [ "$battery_check_passed" = "true" ] && [ "$gpu_check_passed" = "true" ] && [ "$memory_check_passed" = "true" ]; then
                    can_be_mobile_gaming="true"
                else
                    local disqualification_reasons=()
                    if [ "$battery_check_passed" != "true" ]; then
                        disqualification_reasons+=("battery capacity below ${min_battery_capacity}Wh")
                    fi
                    if [ "$gpu_check_passed" != "true" ]; then
                        disqualification_reasons+=("no discrete GPU")
                    fi
                    if [ "$memory_check_passed" != "true" ]; then
                        disqualification_reasons+=("system memory below 16GB")
                    fi
                    echo "System cannot qualify as mobile gaming system due to: $(IFS=', '; echo "${disqualification_reasons[*]}")" >> "$es_response_file"
                fi
                
                if [ "$can_be_mobile_gaming" = "true" ]; then
                    # For notebooks, check if it's a mobile gaming system
                    echo "" >&2
                    echo "═══════════════════════════════════════════════════════════════" >&2
                    echo "MOBILE GAMING SYSTEM DETERMINATION" >&2
                    echo "═══════════════════════════════════════════════════════════════" >&2
                    echo "" >&2
                    echo "System: ${PRODUCT_NAME} (${lookup_identifier})" >&2
                    echo "Battery Capacity: ${battery_capacity_wh} Wh" >&2
                    echo "System Memory (GB): ${total_memory_gb_numeric:-unknown}" >&2
                    echo "" >&2
                    echo "A mobile gaming system is defined as a notebook computer that" >&2
                    echo "meets ALL of the following requirements:" >&2
                    echo "" >&2
                    echo "  1. Discrete GPU: Frame buffer bandwidth of at least 128 gigabytes/second." >&2
                    echo "  2. System memory: At least 16 gigabytes." >&2
                    echo "  3. External power supply: A nameplate output power of at least 150 W." >&2
                    echo "  4. Total battery capacity: At least \(75\) Wh." >&2
                    echo "" >&2
                    echo "═══════════════════════════════════════════════════════════════" >&2
                    read -p "Is this system a mobile gaming system? (y/n): " is_mobile_gaming
                    
                    echo "" >> "$es_response_file"
                    echo "Is Mobile Gaming System: ${is_mobile_gaming}" >> "$es_response_file"
                    
                    if [[ "$is_mobile_gaming" =~ ^[Yy] ]]; then
                        mobile_gaming_system="true"
                        should_calculate_es="true"
                    else
                        echo "Not a mobile gaming system. No expandability score needed." >&2
                        echo "Result: Not a mobile gaming system" >> "$es_response_file"
                    fi
                else
                    echo "" >&2
                    local disqualification_msg=""
                    if [ "$battery_check_passed" != "true" ]; then
                        disqualification_msg="Battery capacity (${battery_capacity_wh} Wh) is below the minimum threshold (${min_battery_capacity}Wh)"
                    fi
                    if [ "$gpu_check_passed" != "true" ]; then
                        if [ -n "$disqualification_msg" ]; then
                            disqualification_msg="${disqualification_msg} and no discrete GPU detected"
                        else
                            disqualification_msg="No discrete GPU detected"
                        fi
                    fi
                    if [ "$memory_check_passed" != "true" ]; then
                        if [ -n "$disqualification_msg" ]; then
                            disqualification_msg="${disqualification_msg} and system memory below 16GB"
                        else
                            disqualification_msg="System memory below 16GB"
                        fi
                    fi
                    echo "System disqualified: ${disqualification_msg}" >&2
                    echo "Skipping mobile gaming system determination." >&2
                    echo "Result: Disqualified - ${disqualification_msg}" >> "$es_response_file"
                fi
            else
                # For desktops/workstations, always calculate expandability score
                should_calculate_es="true"
            fi
            
            # Calculate expandability score based on interface prompts
            if [ "$should_calculate_es" = "true" ]; then
                echo "" >&2
                echo "═══════════════════════════════════════════════════════════════" >&2
                echo "EXPANDABILITY SCORE CALCULATION" >&2
                echo "═══════════════════════════════════════════════════════════════" >&2
                echo "" >&2
                echo "System: ${PRODUCT_NAME} (${lookup_identifier})" >&2
                echo "" >&2
                echo "Please enter the count for each interface on the mainboard:" >&2
                echo "" >&2
                
                echo "" >> "$es_response_file"
                echo "Interface Counts:" >> "$es_response_file"
                echo "-----------------" >> "$es_response_file"
                
                # Define interface prompts and their scores
                local total_score=100
                
                # USB 2.0 or less
                read -p "1. USB 2.0 or less (score: 5): " usb2_count
                usb2_count=${usb2_count:-0}
                echo "USB 2.0 or less: ${usb2_count}" >> "$es_response_file"
                total_score=$((total_score + usb2_count * 5))
                
                # USB 3.0 or 3.1 Gen 1
                read -p "2. USB 3.0 or 3.1 Gen 1 (score: 10): " usb3_gen1_count
                usb3_gen1_count=${usb3_gen1_count:-0}
                echo "USB 3.0 or 3.1 Gen 1: ${usb3_gen1_count}" >> "$es_response_file"
                total_score=$((total_score + usb3_gen1_count * 10))
                
                # USB 3.1 Gen 2
                read -p "3. USB 3.1 Gen 2 (score: 15): " usb3_gen2_count
                usb3_gen2_count=${usb3_gen2_count:-0}
                echo "USB 3.1 Gen 2: ${usb3_gen2_count}" >> "$es_response_file"
                total_score=$((total_score + usb3_gen2_count * 15))
                
                # USB/Thunderbolt 3.0+ that can provide 100W+
                read -p "4. USB/Thunderbolt 3.0+ (100W+ power delivery) (score: 100): " tb_100w_count
                tb_100w_count=${tb_100w_count:-0}
                echo "USB/Thunderbolt 3.0+ (100W+): ${tb_100w_count}" >> "$es_response_file"
                total_score=$((total_score + tb_100w_count * 100))
                
                # USB/Thunderbolt 3.0+ that can provide 60-100W
                read -p "5. USB/Thunderbolt 3.0+ (60-100W power delivery) (score: 60): " tb_60_100w_count
                tb_60_100w_count=${tb_60_100w_count:-0}
                echo "USB/Thunderbolt 3.0+ (60-100W): ${tb_60_100w_count}" >> "$es_response_file"
                total_score=$((total_score + tb_60_100w_count * 60))
                
                # USB/Thunderbolt 3.0+ that can provide 30-60W
                read -p "6. USB/Thunderbolt 3.0+ (30-60W power delivery) (score: 30): " tb_30_60w_count
                tb_30_60w_count=${tb_30_60w_count:-0}
                echo "USB/Thunderbolt 3.0+ (30-60W): ${tb_30_60w_count}" >> "$es_response_file"
                total_score=$((total_score + tb_30_60w_count * 30))
                
                # Thunderbolt 3.0+ or USB ports (not otherwise addressed, can't provide 30W+)
                read -p "7. Thunderbolt 3.0+ or USB (can't provide 30W+, not otherwise addressed) (score: 20): " tb_other_count
                tb_other_count=${tb_other_count:-0}
                echo "Thunderbolt 3.0+ or USB (other): ${tb_other_count}" >> "$es_response_file"
                total_score=$((total_score + tb_other_count * 20))
                
                # Unconnected USB 2.0 motherboard header
                read -p "8. Unconnected USB 2.0 motherboard headers (score: 10 per header): " usb2_header_count
                usb2_header_count=${usb2_header_count:-0}
                echo "Unconnected USB 2.0 headers: ${usb2_header_count}" >> "$es_response_file"
                total_score=$((total_score + usb2_header_count * 10))
                
                # Unconnected USB 3.0 or 3.1 Gen 1 motherboard header
                read -p "9. Unconnected USB 3.0 or 3.1 Gen 1 motherboard headers (score: 20 per header): " usb3_header_count
                usb3_header_count=${usb3_header_count:-0}
                echo "Unconnected USB 3.0 or 3.1 Gen 1 headers: ${usb3_header_count}" >> "$es_response_file"
                total_score=$((total_score + usb3_header_count * 20))
                
                # PCI slot other than PCIe x16 (mechanical slots only)
                read -p "10. PCI slots (other than PCIe x16, mechanical only) (score: 25): " pci_other_count
                pci_other_count=${pci_other_count:-0}
                echo "PCI slots (other than PCIe x16): ${pci_other_count}" >> "$es_response_file"
                total_score=$((total_score + pci_other_count * 25))
                
                # PCIe x16 (mechanical slots only)
                read -p "11. PCIe x16 slots (mechanical only) (score: 75): " pcie_x16_count
                pcie_x16_count=${pcie_x16_count:-0}
                echo "PCIe x16 slots: ${pcie_x16_count}" >> "$es_response_file"
                total_score=$((total_score + pcie_x16_count * 75))
                
                # Thunderbolt 2.0 or less
                read -p "12. Thunderbolt 2.0 or less (score: 20): " tb2_count
                tb2_count=${tb2_count:-0}
                echo "Thunderbolt 2.0 or less: ${tb2_count}" >> "$es_response_file"
                total_score=$((total_score + tb2_count * 20))
                
                # M.2 (except key M)
                read -p "13. M.2 slots (except key M) (score: 10): " m2_other_count
                m2_other_count=${m2_other_count:-0}
                echo "M.2 (except key M): ${m2_other_count}" >> "$es_response_file"
                total_score=$((total_score + m2_other_count * 10))
                
                # IDE, SATA, eSATA
                read -p "14. IDE, SATA, or eSATA ports (score: 15): " sata_count
                sata_count=${sata_count:-0}
                echo "IDE, SATA, eSATA: ${sata_count}" >> "$es_response_file"
                total_score=$((total_score + sata_count * 15))
                
                # M.2, key M, SATA express, U.2
                read -p "15. M.2 key M, SATA express, or U.2 ports (score: 25): " m2_keym_count
                m2_keym_count=${m2_keym_count:-0}
                echo "M.2 key M, SATA express, U.2: ${m2_keym_count}" >> "$es_response_file"
                total_score=$((total_score + m2_keym_count * 25))
                
                # Integrated liquid cooling
                read -p "16. Integrated liquid cooling (score: 50): " liquid_cooling_count
                liquid_cooling_count=${liquid_cooling_count:-0}
                echo "Integrated liquid cooling: ${liquid_cooling_count}" >> "$es_response_file"
                total_score=$((total_score + liquid_cooling_count * 50))
                
                # Memory interface bonus: Either 1) CPU and motherboard support 4+ channels AND 8GB+ installed, OR 2) 8GB+ on 256-bit+ interface
                echo "" >&2
                echo "Memory Interface Bonus (score: 100):" >&2
                echo "  Either:" >&2
                echo "    1) CPU and motherboard support for 4+ channels of system memory" >&2
                echo "       AND at least 8GB of installed compatible system memory; OR" >&2
                echo "    2) At least 8GB of system memory installed on a 256-bit or" >&2
                echo "       greater memory interface" >&2
                read -p "17. Does this system qualify for the memory interface bonus? (y/n): " memory_bonus
                if [[ "$memory_bonus" =~ ^[Yy] ]]; then
                    echo "Memory Interface Bonus: Yes" >> "$es_response_file"
                    total_score=$((total_score + 100))
                else
                    echo "Memory Interface Bonus: No" >> "$es_response_file"
                fi
                
                # Review/edit loop
                local calculation_confirmed="false"
                while [ "$calculation_confirmed" != "true" ]; do
                    # Recalculate total score
                    total_score=100
                    total_score=$((total_score + usb2_count * 5))
                    total_score=$((total_score + usb3_gen1_count * 10))
                    total_score=$((total_score + usb3_gen2_count * 15))
                    total_score=$((total_score + tb_100w_count * 100))
                    total_score=$((total_score + tb_60_100w_count * 60))
                    total_score=$((total_score + tb_30_60w_count * 30))
                    total_score=$((total_score + tb_other_count * 20))
                    total_score=$((total_score + usb2_header_count * 10))
                    total_score=$((total_score + usb3_header_count * 20))
                    total_score=$((total_score + pci_other_count * 25))
                    total_score=$((total_score + pcie_x16_count * 75))
                    total_score=$((total_score + tb2_count * 20))
                    total_score=$((total_score + m2_other_count * 10))
                    total_score=$((total_score + sata_count * 15))
                    total_score=$((total_score + m2_keym_count * 25))
                    total_score=$((total_score + liquid_cooling_count * 50))
                    if [[ "$memory_bonus" =~ ^[Yy] ]]; then
                        total_score=$((total_score + 100))
                    fi
                    expandability_score=$total_score
                    
                    # Display summary of calculation
                    echo "" >&2
                    echo "═══════════════════════════════════════════════════════════════" >&2
                    echo "EXPANDABILITY SCORE CALCULATION SUMMARY" >&2
                    echo "═══════════════════════════════════════════════════════════════" >&2
                    echo "" >&2
                    printf "%-5s %-55s %5s %10s\n" "Num" "Interface Type" "Count" "Score" >&2
                    echo "─────────────────────────────────────────────────────────────────────────────────" >&2
                    printf "%-5s %-55s %5d %10d\n" " 1" "USB 2.0 or less" "$usb2_count" "$((usb2_count * 5))" >&2
                    printf "%-5s %-55s %5d %10d\n" " 2" "USB 3.0 or 3.1 Gen 1" "$usb3_gen1_count" "$((usb3_gen1_count * 10))" >&2
                    printf "%-5s %-55s %5d %10d\n" " 3" "USB 3.1 Gen 2" "$usb3_gen2_count" "$((usb3_gen2_count * 15))" >&2
                    printf "%-5s %-55s %5d %10d\n" " 4" "USB/Thunderbolt 3.0+ (100W+)" "$tb_100w_count" "$((tb_100w_count * 100))" >&2
                    printf "%-5s %-55s %5d %10d\n" " 5" "USB/Thunderbolt 3.0+ (60-100W)" "$tb_60_100w_count" "$((tb_60_100w_count * 60))" >&2
                    printf "%-5s %-55s %5d %10d\n" " 6" "USB/Thunderbolt 3.0+ (30-60W)" "$tb_30_60w_count" "$((tb_30_60w_count * 30))" >&2
                    printf "%-5s %-55s %5d %10d\n" " 7" "Thunderbolt 3.0+ or USB (other)" "$tb_other_count" "$((tb_other_count * 20))" >&2
                    printf "%-5s %-55s %5d %10d\n" " 8" "Unconnected USB 2.0 headers" "$usb2_header_count" "$((usb2_header_count * 10))" >&2
                    printf "%-5s %-55s %5d %10d\n" " 9" "Unconnected USB 3.0/3.1 Gen 1 headers" "$usb3_header_count" "$((usb3_header_count * 20))" >&2
                    printf "%-5s %-55s %5d %10d\n" "10" "PCI slots (other than PCIe x16)" "$pci_other_count" "$((pci_other_count * 25))" >&2
                    printf "%-5s %-55s %5d %10d\n" "11" "PCIe x16 slots" "$pcie_x16_count" "$((pcie_x16_count * 75))" >&2
                    printf "%-5s %-55s %5d %10d\n" "12" "Thunderbolt 2.0 or less" "$tb2_count" "$((tb2_count * 20))" >&2
                    printf "%-5s %-55s %5d %10d\n" "13" "M.2 (except key M)" "$m2_other_count" "$((m2_other_count * 10))" >&2
                    printf "%-5s %-55s %5d %10d\n" "14" "IDE, SATA, eSATA" "$sata_count" "$((sata_count * 15))" >&2
                    printf "%-5s %-55s %5d %10d\n" "15" "M.2 key M, SATA express, U.2" "$m2_keym_count" "$((m2_keym_count * 25))" >&2
                    printf "%-5s %-55s %5d %10d\n" "16" "Integrated liquid cooling" "$liquid_cooling_count" "$((liquid_cooling_count * 50))" >&2
                    if [[ "$memory_bonus" =~ ^[Yy] ]]; then
                        printf "%-5s %-55s %5s %10d\n" "17" "Memory Interface Bonus" "Yes" "100" >&2
                    else
                        printf "%-5s %-55s %5s %10d\n" "17" "Memory Interface Bonus" "No" "0" >&2
                    fi
                    echo "─────────────────────────────────────────────────────────────────────────────────" >&2
                    printf "%-5s %-55s %5s %10d\n" "" "Base Score (all systems)" "" "100" >&2
                    printf "%-5s %-55s %5s %10d\n" "" "Interface Contributions" "" "$((expandability_score - 100))" >&2
                    echo "─────────────────────────────────────────────────────────────────────────────────" >&2
                    printf "%-5s %-55s %5s %10d\n" "" "TOTAL EXPANDABILITY SCORE" "" "$expandability_score" >&2
                    echo "" >&2
                    echo "═══════════════════════════════════════════════════════════════" >&2
                    
                    # Prompt for modification or acceptance
                    echo ""
                    read -p "Enter number to modify (1-17), or press Enter to accept [Current ES: ${expandability_score}]: " modify_choice
                    
                    if [ -z "$modify_choice" ]; then
                        # User accepted, break out of loop
                        calculation_confirmed="true"
                        
                        # Write final summary to response file
                        {
                            echo ""
                            echo "Final Calculation Summary:"
                            echo "─────────────────────────────────────────────────────────────────────"
                            echo "1. USB 2.0 or less: ${usb2_count} × 5 = $((usb2_count * 5))"
                            echo "2. USB 3.0 or 3.1 Gen 1: ${usb3_gen1_count} × 10 = $((usb3_gen1_count * 10))"
                            echo "3. USB 3.1 Gen 2: ${usb3_gen2_count} × 15 = $((usb3_gen2_count * 15))"
                            echo "4. USB/Thunderbolt 3.0+ (100W+): ${tb_100w_count} × 100 = $((tb_100w_count * 100))"
                            echo "5. USB/Thunderbolt 3.0+ (60-100W): ${tb_60_100w_count} × 60 = $((tb_60_100w_count * 60))"
                            echo "6. USB/Thunderbolt 3.0+ (30-60W): ${tb_30_60w_count} × 30 = $((tb_30_60w_count * 30))"
                            echo "7. Thunderbolt 3.0+ or USB (other): ${tb_other_count} × 20 = $((tb_other_count * 20))"
                            echo "8. Unconnected USB 2.0 headers: ${usb2_header_count} × 10 = $((usb2_header_count * 10))"
                            echo "9. Unconnected USB 3.0/3.1 Gen 1 headers: ${usb3_header_count} × 20 = $((usb3_header_count * 20))"
                            echo "10. PCI slots (other than PCIe x16): ${pci_other_count} × 25 = $((pci_other_count * 25))"
                            echo "11. PCIe x16 slots: ${pcie_x16_count} × 75 = $((pcie_x16_count * 75))"
                            echo "12. Thunderbolt 2.0 or less: ${tb2_count} × 20 = $((tb2_count * 20))"
                            echo "13. M.2 (except key M): ${m2_other_count} × 10 = $((m2_other_count * 10))"
                            echo "14. IDE, SATA, eSATA: ${sata_count} × 15 = $((sata_count * 15))"
                            echo "15. M.2 key M, SATA express, U.2: ${m2_keym_count} × 25 = $((m2_keym_count * 25))"
                            echo "16. Integrated liquid cooling: ${liquid_cooling_count} × 50 = $((liquid_cooling_count * 50))"
                            if [[ "$memory_bonus" =~ ^[Yy] ]]; then
                                echo "17. Memory Interface Bonus: Yes × 100 = 100"
                            else
                                echo "17. Memory Interface Bonus: No × 100 = 0"
                            fi
                            echo "─────────────────────────────────────────────────────────────────────"
                            echo "Base Score (all systems): 100"
                            echo "Interface Contributions: $((expandability_score - 100))"
                            echo "TOTAL EXPANDABILITY SCORE: ${expandability_score}"
                        } >> "$es_response_file"
                        echo "Calculation confirmed. Expandability Score: ${expandability_score}" >&2
                    else
                        # User wants to modify a specific entry
                        case "$modify_choice" in
                            1)
                                read -p "USB 2.0 or less (score: 5): " usb2_count
                                usb2_count=${usb2_count:-0}
                                echo "Updated: USB 2.0 or less: ${usb2_count}" >> "$es_response_file"
                                ;;
                            2)
                                read -p "USB 3.0 or 3.1 Gen 1 (score: 10): " usb3_gen1_count
                                usb3_gen1_count=${usb3_gen1_count:-0}
                                echo "Updated: USB 3.0 or 3.1 Gen 1: ${usb3_gen1_count}" >> "$es_response_file"
                                ;;
                            3)
                                read -p "USB 3.1 Gen 2 (score: 15): " usb3_gen2_count
                                usb3_gen2_count=${usb3_gen2_count:-0}
                                echo "Updated: USB 3.1 Gen 2: ${usb3_gen2_count}" >> "$es_response_file"
                                ;;
                            4)
                                read -p "USB/Thunderbolt 3.0+ (100W+ power delivery) (score: 100): " tb_100w_count
                                tb_100w_count=${tb_100w_count:-0}
                                echo "Updated: USB/Thunderbolt 3.0+ (100W+): ${tb_100w_count}" >> "$es_response_file"
                                ;;
                            5)
                                read -p "USB/Thunderbolt 3.0+ (60-100W power delivery) (score: 60): " tb_60_100w_count
                                tb_60_100w_count=${tb_60_100w_count:-0}
                                echo "Updated: USB/Thunderbolt 3.0+ (60-100W): ${tb_60_100w_count}" >> "$es_response_file"
                                ;;
                            6)
                                read -p "USB/Thunderbolt 3.0+ (30-60W power delivery) (score: 30): " tb_30_60w_count
                                tb_30_60w_count=${tb_30_60w_count:-0}
                                echo "Updated: USB/Thunderbolt 3.0+ (30-60W): ${tb_30_60w_count}" >> "$es_response_file"
                                ;;
                            7)
                                read -p "Thunderbolt 3.0+ or USB (can't provide 30W+, not otherwise addressed) (score: 20): " tb_other_count
                                tb_other_count=${tb_other_count:-0}
                                echo "Updated: Thunderbolt 3.0+ or USB (other): ${tb_other_count}" >> "$es_response_file"
                                ;;
                            8)
                                read -p "Unconnected USB 2.0 motherboard headers (score: 10 per header): " usb2_header_count
                                usb2_header_count=${usb2_header_count:-0}
                                echo "Updated: Unconnected USB 2.0 headers: ${usb2_header_count}" >> "$es_response_file"
                                ;;
                            9)
                                read -p "Unconnected USB 3.0 or 3.1 Gen 1 motherboard headers (score: 20 per header): " usb3_header_count
                                usb3_header_count=${usb3_header_count:-0}
                                echo "Updated: Unconnected USB 3.0 or 3.1 Gen 1 headers: ${usb3_header_count}" >> "$es_response_file"
                                ;;
                            10)
                                read -p "PCI slots (other than PCIe x16, mechanical only) (score: 25): " pci_other_count
                                pci_other_count=${pci_other_count:-0}
                                echo "Updated: PCI slots (other than PCIe x16): ${pci_other_count}" >> "$es_response_file"
                                ;;
                            11)
                                read -p "PCIe x16 slots (mechanical only) (score: 75): " pcie_x16_count
                                pcie_x16_count=${pcie_x16_count:-0}
                                echo "Updated: PCIe x16 slots: ${pcie_x16_count}" >> "$es_response_file"
                                ;;
                            12)
                                read -p "Thunderbolt 2.0 or less (score: 20): " tb2_count
                                tb2_count=${tb2_count:-0}
                                echo "Updated: Thunderbolt 2.0 or less: ${tb2_count}" >> "$es_response_file"
                                ;;
                            13)
                                read -p "M.2 slots (except key M) (score: 10): " m2_other_count
                                m2_other_count=${m2_other_count:-0}
                                echo "Updated: M.2 (except key M): ${m2_other_count}" >> "$es_response_file"
                                ;;
                            14)
                                read -p "IDE, SATA, or eSATA ports (score: 15): " sata_count
                                sata_count=${sata_count:-0}
                                echo "Updated: IDE, SATA, eSATA: ${sata_count}" >> "$es_response_file"
                                ;;
                            15)
                                read -p "M.2 key M, SATA express, or U.2 ports (score: 25): " m2_keym_count
                                m2_keym_count=${m2_keym_count:-0}
                                echo "Updated: M.2 key M, SATA express, U.2: ${m2_keym_count}" >> "$es_response_file"
                                ;;
                            16)
                                read -p "Integrated liquid cooling (score: 50): " liquid_cooling_count
                                liquid_cooling_count=${liquid_cooling_count:-0}
                                echo "Updated: Integrated liquid cooling: ${liquid_cooling_count}" >> "$es_response_file"
                                ;;
                            17)
                                echo "" >&2
                                echo "Memory Interface Bonus (score: 100):" >&2
                                echo "  Either:" >&2
                                echo "    1) CPU and motherboard support for 4+ channels of system memory" >&2
                                echo "       AND at least 8GB of installed compatible system memory; OR" >&2
                                echo "    2) At least 8GB of system memory installed on a 256-bit or" >&2
                                echo "       greater memory interface" >&2
                                read -p "Does this system qualify for the memory interface bonus? (y/n): " memory_bonus
                                if [[ "$memory_bonus" =~ ^[Yy] ]]; then
                                    echo "Updated: Memory Interface Bonus: Yes" >> "$es_response_file"
                                else
                                    echo "Updated: Memory Interface Bonus: No" >> "$es_response_file"
                                fi
                                ;;
                            *)
                                echo "Invalid choice. Please enter a number from 1-17."
                                ;;
                        esac
                        
                        # Recalculate expandability score after modification
                        if [ "$modify_choice" -ge 1 ] && [ "$modify_choice" -le 17 ]; then
                            total_score=100
                            total_score=$((total_score + usb2_count * 5))
                            total_score=$((total_score + usb3_gen1_count * 10))
                            total_score=$((total_score + usb3_gen2_count * 15))
                            total_score=$((total_score + tb_100w_count * 100))
                            total_score=$((total_score + tb_60_100w_count * 60))
                            total_score=$((total_score + tb_30_60w_count * 30))
                            total_score=$((total_score + tb_other_count * 20))
                            total_score=$((total_score + usb2_header_count * 10))
                            total_score=$((total_score + usb3_header_count * 20))
                            total_score=$((total_score + pci_other_count * 25))
                            total_score=$((total_score + pcie_x16_count * 75))
                            total_score=$((total_score + tb2_count * 20))
                            total_score=$((total_score + m2_other_count * 10))
                            total_score=$((total_score + sata_count * 15))
                            total_score=$((total_score + m2_keym_count * 25))
                            total_score=$((total_score + liquid_cooling_count * 50))
                            if [[ "$memory_bonus" =~ ^[Yy] ]]; then
                                total_score=$((total_score + 100))
                            fi
                            expandability_score=$total_score
                            echo "Updated Expandability Score: ${expandability_score}" >&2
                        fi
                    fi
                done
                
                # Write confirmation to response file
                echo "" >> "$es_response_file"
                echo "Calculation Confirmed: Yes" >> "$es_response_file"
                
                # Offer to save to lookup file
                if [ -n "$expandability_score" ] && [ -n "$lookup_identifier" ] && [ -f "$lookup_file" ] && command -v jq &> /dev/null; then
                    local lookup_key=$(echo "$lookup_identifier" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]//g')
                    if [ -n "$lookup_key" ]; then
                        read -p "Save this score to lookup file for future use? (y/n): " save_score
                        if [[ "$save_score" =~ ^[Yy] ]]; then
                            local temp_file=$(mktemp)
                            jq ". + {\"$lookup_key\": $expandability_score}" "$lookup_file" > "$temp_file" && mv "$temp_file" "$lookup_file"
                            echo "Score saved to lookup file."
                            echo "Saved to lookup file: Yes" >> "$es_response_file"
                        else
                            echo "Saved to lookup file: No" >> "$es_response_file"
                        fi
                    fi
                fi
            fi
        fi
        
        # Get baseboard information for system object
        local baseboard_manufacturer="$BASEBOARD_MANUFACTURER"
        local baseboard_product="$BASEBOARD_PRODUCT"
        local baseboard_version="$BASEBOARD_VERSION"
        echo "    \"baseboard_manufacturer\": \"${baseboard_manufacturer}\","
        echo "    \"baseboard_product\": \"${baseboard_product}\","
        echo "    \"baseboard_version\": \"${baseboard_version}\","
        if [ -n "$lookup_identifier" ]; then
            echo "    \"expandability_lookup_identifier\": \"${lookup_identifier}\"," 
        else
            echo "    \"expandability_lookup_identifier\": null,"
        fi
        if [ -n "$motherboard_model_number" ]; then
            echo "    \"motherboard_model_number\": \"${motherboard_model_number}\","
        else
            echo "    \"motherboard_model_number\": null,"
        fi
        echo "    \"is_notebook\": ${is_notebook},"
        
        # Determine system classification
        local system_classification="Desktop"
        if [[ "$chassis_type" == "Notebook" || "$chassis_type" == "Laptop" ]]; then
            system_classification="Notebook"
        elif [[ "$chassis_type" == "Tower" || "$chassis_type" == "Desktop" ]]; then
            # Check if it's a workstation (typically has professional GPU or ECC memory)
            if command -v nvidia-smi &> /dev/null && nvidia-smi &>/dev/null; then
                local gpu_name=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
                if [[ "$gpu_name" =~ "Quadro|Tesla|RTX.*A|RTX.*Pro" ]]; then
                    system_classification="Workstation"
                fi
            fi
            # Check for ECC memory (typically indicates workstation/server)
            if echo "$DMI_TYPE17" | grep -qi "Error Correction Type.*ECC\|Single-bit ECC"; then
                system_classification="Workstation"
            fi
        fi
        echo "    \"classification\": \"${system_classification}\""
        echo "  },"
        
        # Output expandability score and mobile gaming system flag at root level
        # Re-check if notebook with expandability score should be mobile gaming system
        if [ -n "$expandability_score" ] && [ "$is_notebook" = "true" ]; then
            mobile_gaming_system="true"
        fi
        
        if [ -n "$expandability_score" ]; then
            echo -n "  \"expandability_score\": ${expandability_score}"
        else
            echo -n "  \"expandability_score\": null"
        fi
        echo ","
        # Ensure mobile_gaming_system is output as boolean
        if [ "$mobile_gaming_system" = "true" ]; then
            echo "  \"mobile_gaming_system\": true"
        else
            echo "  \"mobile_gaming_system\": false"
        fi
        echo ","
        
        # Chassis/Form Factor
        echo "  \"chassis\": {"
        echo "    \"type\": \"${chassis_type}\","
        echo "    \"manufacturer\": \"${CHASSIS_MANUFACTURER}\","
        echo "    \"version\": \"${CHASSIS_VERSION}\""
        echo "  },"
        
        # CPU Information
        echo "  \"cpu\": {"
        local cpu_model=$(grep "model name" /proc/cpuinfo | head -1 | cut -d: -f2 | xargs)
        # Get actual cores and threads from lscpu
        local cpu_cores=$(lscpu 2>/dev/null | grep "^Core(s) per socket:" | awk '{print $4}' || echo "")
        local cpu_sockets=$(lscpu 2>/dev/null | grep "^Socket(s):" | awk '{print $2}' || echo "1")
        if [ -z "$cpu_cores" ]; then
            # Fallback: try to get from CPU(s)
            cpu_cores=$(lscpu 2>/dev/null | grep "^CPU(s):" | awk '{print $2}' || nproc)
        fi
        # Calculate total cores
        local total_cores=$(echo "${cpu_cores} * ${cpu_sockets}" | bc 2>/dev/null || echo "$cpu_cores")
        # Get total threads
        local cpu_threads=$(lscpu 2>/dev/null | grep "^CPU(s):" | awk '{print $2}' || nproc)
        # Use total_cores for cores field
        cpu_cores="$total_cores"
        local cpu_family=$(grep "cpu family" /proc/cpuinfo | head -1 | cut -d: -f2 | xargs)
        local cpu_model_num=$(grep "^model[[:space:]]*:" /proc/cpuinfo | head -1 | cut -d: -f2 | xargs)
        local cpu_stepping=$(grep "stepping" /proc/cpuinfo | head -1 | cut -d: -f2 | xargs)
        local cpu_arch=$(uname -m)
        local cpu_flags=$(grep "flags" /proc/cpuinfo | head -1 | cut -d: -f2 | xargs)
        local cpu_bogomips=$(grep "bogomips" /proc/cpuinfo | head -1 | cut -d: -f2 | xargs)
        
        # Get CPU frequency info
        local cpu_freq_min=$(lscpu 2>/dev/null | grep "CPU min MHz" | awk '{print $4}' || echo "")
        local cpu_freq_max=$(lscpu 2>/dev/null | grep "CPU max MHz" | awk '{print $4}' || echo "")
        local cpu_freq_base=$(lscpu 2>/dev/null | grep "Model name" | grep -oE '[0-9]+\.[0-9]+[[:space:]]*GHz' | head -1 || echo "")
        
        # Get cache sizes
        local l1d_cache=$(lscpu 2>/dev/null | grep "L1d cache" | awk -F: '{print $2}' | xargs || echo "")
        local l1i_cache=$(lscpu 2>/dev/null | grep "L1i cache" | awk -F: '{print $2}' | xargs || echo "")
        local l2_cache=$(lscpu 2>/dev/null | grep "L2 cache" | awk -F: '{print $2}' | xargs || echo "")
        local l3_cache=$(lscpu 2>/dev/null | grep "L3 cache" | awk -F: '{print $2}' | xargs || echo "")
        
        # Get vendor
        local cpu_vendor=$(grep "vendor_id" /proc/cpuinfo | head -1 | cut -d: -f2 | xargs)
        
        echo "    \"model\": \"${cpu_model}\","
        echo "    \"vendor\": \"${cpu_vendor}\","
        echo "    \"family\": ${cpu_family:-null},"
        echo "    \"model_number\": ${cpu_model_num:-null},"
        echo "    \"stepping\": ${cpu_stepping:-null},"
        echo "    \"architecture\": \"${cpu_arch}\","
        echo "    \"cores\": ${cpu_cores},"
        echo -n "    \"threads\": ${cpu_threads}"
        local has_optional=false
        [ -n "$cpu_freq_base" ] && { echo "," && echo -n "    \"base_frequency\": \"${cpu_freq_base}\""; has_optional=true; }
        [ -n "$cpu_freq_min" ] && { echo "," && echo -n "    \"min_frequency_mhz\": ${cpu_freq_min}"; has_optional=true; }
        [ -n "$cpu_freq_max" ] && { echo "," && echo -n "    \"max_frequency_mhz\": ${cpu_freq_max}"; has_optional=true; }
        [ -n "$l1d_cache" ] && { echo "," && echo -n "    \"l1d_cache\": \"${l1d_cache}\""; has_optional=true; }
        [ -n "$l1i_cache" ] && { echo "," && echo -n "    \"l1i_cache\": \"${l1i_cache}\""; has_optional=true; }
        [ -n "$l2_cache" ] && { echo "," && echo -n "    \"l2_cache\": \"${l2_cache}\""; has_optional=true; }
        [ -n "$l3_cache" ] && { echo "," && echo -n "    \"l3_cache\": \"${l3_cache}\""; has_optional=true; }
        echo "," && echo "    \"bogomips\": ${cpu_bogomips:-null}"
        echo "  },"
        
        # Memory Information
        echo "  \"memory\": {"
        echo "    \"dimms\": ["
        local first_dimm=true
        # Parse each DIMM block - split by Handle
        local dimm_data="$DMI_TYPE17"
        local current_dimm=""
        while IFS= read -r line; do
            if [[ "$line" =~ ^Handle ]]; then
                # Process previous DIMM if it exists and has data
                if [ -n "$current_dimm" ] && echo "$current_dimm" | grep -q "Size:" && ! echo "$current_dimm" | grep -q "No Module Installed"; then
                    if [ "$first_dimm" = false ]; then
                        echo ","
                    fi
                    first_dimm=false
                    
                    local size=$(echo "$current_dimm" | grep "Size:" | cut -d: -f2 | xargs)
                    local speed=$(echo "$current_dimm" | grep "Speed:" | cut -d: -f2 | xargs)
                    local manufacturer=$(echo "$current_dimm" | grep "Manufacturer:" | cut -d: -f2 | xargs)
                    local part_number=$(echo "$current_dimm" | grep "Part Number:" | cut -d: -f2 | xargs)
                    local serial_number=$(echo "$current_dimm" | grep "Serial Number:" | cut -d: -f2 | xargs)
                    local type=$(echo "$current_dimm" | grep "^[[:space:]]*Type:" | head -1 | cut -d: -f2 | xargs)
                    local form_factor=$(echo "$current_dimm" | grep "Form Factor:" | cut -d: -f2 | xargs)
                    local locator=$(echo "$current_dimm" | grep "Locator:" | head -1 | cut -d: -f2 | xargs)
                    local bank_locator=$(echo "$current_dimm" | grep "Bank Locator:" | head -1 | cut -d: -f2 | xargs)
                    local total_width=$(echo "$current_dimm" | grep "Total Width:" | cut -d: -f2 | xargs)
                    local data_width=$(echo "$current_dimm" | grep "Data Width:" | cut -d: -f2 | xargs)
                    
                    echo "      {"
                    echo -n "        \"size\": \"${size:-}\""
                    [ -n "$locator" ] && echo "," && echo -n "        \"locator\": \"${locator}\""
                    [ -n "$bank_locator" ] && echo "," && echo -n "        \"bank_locator\": \"${bank_locator}\""
                    [ -n "$speed" ] && echo "," && echo -n "        \"speed\": \"${speed}\""
                    [ -n "$type" ] && echo "," && echo -n "        \"type\": \"${type}\""
                    [ -n "$form_factor" ] && echo "," && echo -n "        \"form_factor\": \"${form_factor}\""
                    [ -n "$manufacturer" ] && echo "," && echo -n "        \"manufacturer\": \"${manufacturer}\""
                    [ -n "$part_number" ] && echo "," && echo -n "        \"part_number\": \"${part_number}\""
                    [ -n "$serial_number" ] && echo "," && echo -n "        \"serial_number\": \"${serial_number}\""
                    [ -n "$total_width" ] && echo "," && echo -n "        \"total_width\": \"${total_width}\""
                    [ -n "$data_width" ] && echo "," && echo -n "        \"data_width\": \"${data_width}\""
                    echo ""
                    echo -n "      }"
                fi
                current_dimm="$line"$'\n'
            else
                current_dimm+="$line"$'\n'
            fi
        done <<< "$dimm_data"
        # Process last DIMM
        if [ -n "$current_dimm" ] && echo "$current_dimm" | grep -q "Size:" && ! echo "$current_dimm" | grep -q "No Module Installed"; then
            if [ "$first_dimm" = false ]; then
                echo ","
            fi
            first_dimm=false
            
            local size=$(echo "$current_dimm" | grep "Size:" | cut -d: -f2 | xargs)
            local speed=$(echo "$current_dimm" | grep "Speed:" | cut -d: -f2 | xargs)
            local manufacturer=$(echo "$current_dimm" | grep "Manufacturer:" | cut -d: -f2 | xargs)
            local part_number=$(echo "$current_dimm" | grep "Part Number:" | cut -d: -f2 | xargs)
            local serial_number=$(echo "$current_dimm" | grep "Serial Number:" | cut -d: -f2 | xargs)
            local type=$(echo "$current_dimm" | grep "^[[:space:]]*Type:" | head -1 | cut -d: -f2 | xargs)
            local form_factor=$(echo "$current_dimm" | grep "Form Factor:" | cut -d: -f2 | xargs)
            local locator=$(echo "$current_dimm" | grep "Locator:" | head -1 | cut -d: -f2 | xargs)
            local bank_locator=$(echo "$current_dimm" | grep "Bank Locator:" | head -1 | cut -d: -f2 | xargs)
            local total_width=$(echo "$current_dimm" | grep "Total Width:" | cut -d: -f2 | xargs)
            local data_width=$(echo "$current_dimm" | grep "Data Width:" | cut -d: -f2 | xargs)
            
            echo "      {"
            echo -n "        \"size\": \"${size:-}\""
            [ -n "$locator" ] && echo "," && echo -n "        \"locator\": \"${locator}\""
            [ -n "$bank_locator" ] && echo "," && echo -n "        \"bank_locator\": \"${bank_locator}\""
            [ -n "$speed" ] && echo "," && echo -n "        \"speed\": \"${speed}\""
            [ -n "$type" ] && echo "," && echo -n "        \"type\": \"${type}\""
            [ -n "$form_factor" ] && echo "," && echo -n "        \"form_factor\": \"${form_factor}\""
            [ -n "$manufacturer" ] && echo "," && echo -n "        \"manufacturer\": \"${manufacturer}\""
            [ -n "$part_number" ] && echo "," && echo -n "        \"part_number\": \"${part_number}\""
            [ -n "$serial_number" ] && echo "," && echo -n "        \"serial_number\": \"${serial_number}\""
            [ -n "$total_width" ] && echo "," && echo -n "        \"total_width\": \"${total_width}\""
            [ -n "$data_width" ] && echo "," && echo -n "        \"data_width\": \"${data_width}\""
            echo ""
            echo -n "      }"
        fi
        echo ""
        echo "    ],"
        
        # Calculate total memory capacity from DIMM sizes
        local total_capacity_mb=0
        local current_dimm_cap=""
        while IFS= read -r line; do
            if [[ "$line" =~ ^Handle ]]; then
                if [ -n "$current_dimm_cap" ] && echo "$current_dimm_cap" | grep -q "Size:" && ! echo "$current_dimm_cap" | grep -q "No Module Installed"; then
                    local size_str=$(echo "$current_dimm_cap" | grep "Size:" | cut -d: -f2 | xargs)
                    # Extract size value (e.g., "16 GB" -> 16, "8192 MB" -> 8192)
                    local size_num=$(echo "$size_str" | grep -oE '[0-9]+' | head -1)
                    local size_unit=$(echo "$size_str" | grep -oE '(GB|MB|KB)' | head -1)
                    if [ -n "$size_num" ] && [[ "$size_num" =~ ^[0-9]+$ ]]; then
                        if [ "$size_unit" = "GB" ]; then
                            total_capacity_mb=$((total_capacity_mb + size_num * 1024))
                        elif [ "$size_unit" = "MB" ]; then
                            total_capacity_mb=$((total_capacity_mb + size_num))
                        elif [ "$size_unit" = "KB" ]; then
                            total_capacity_mb=$((total_capacity_mb + size_num / 1024))
                        fi
                    fi
                fi
                current_dimm_cap="$line"$'\n'
            else
                current_dimm_cap+="$line"$'\n'
            fi
        done <<< "$dimm_data"
        # Process last DIMM
        if [ -n "$current_dimm_cap" ] && echo "$current_dimm_cap" | grep -q "Size:" && ! echo "$current_dimm_cap" | grep -q "No Module Installed"; then
            local size_str=$(echo "$current_dimm_cap" | grep "Size:" | cut -d: -f2 | xargs)
            local size_num=$(echo "$size_str" | grep -oE '[0-9]+' | head -1)
            local size_unit=$(echo "$size_str" | grep -oE '(GB|MB|KB)' | head -1)
            if [ -n "$size_num" ] && [[ "$size_num" =~ ^[0-9]+$ ]]; then
                if [ "$size_unit" = "GB" ]; then
                    total_capacity_mb=$((total_capacity_mb + size_num * 1024))
                elif [ "$size_unit" = "MB" ]; then
                    total_capacity_mb=$((total_capacity_mb + size_num))
                elif [ "$size_unit" = "KB" ]; then
                    total_capacity_mb=$((total_capacity_mb + size_num / 1024))
                fi
            fi
        fi
        
        local total_capacity_gb=""
        if [ $total_capacity_mb -gt 0 ]; then
            total_capacity_gb=$(echo "scale=2; ${total_capacity_mb} / 1024" | bc 2>/dev/null || echo "$((total_capacity_mb / 1024))")
            total_memory_gb_numeric=$(echo "$total_capacity_gb" | tr -dc '0-9.')
        fi
        
        local total_memory=$(free -h | grep "Mem:" | awk '{print $2}')
        echo "    \"total_memory\": \"${total_memory}\","
        echo "    \"total_capacity_gb\": ${total_capacity_gb:-null},"
        
        # Calculate total system memory bus width (sum of all DIMMs' total width)
        local total_bus_width=0
        local total_bus_width_bits=""
        local current_dimm_bus=""
        while IFS= read -r line; do
            if [[ "$line" =~ ^Handle ]]; then
                if [ -n "$current_dimm_bus" ] && echo "$current_dimm_bus" | grep -q "Total Width:" && ! echo "$current_dimm_bus" | grep -q "No Module Installed"; then
                    local width_str=$(echo "$current_dimm_bus" | grep "Total Width:" | cut -d: -f2 | xargs)
                    # Extract numeric value (e.g., "64 bits" -> 64)
                    local width_num=$(echo "$width_str" | grep -oE '[0-9]+' | head -1)
                    if [ -n "$width_num" ] && [[ "$width_num" =~ ^[0-9]+$ ]]; then
                        total_bus_width=$((total_bus_width + width_num))
                    fi
                fi
                current_dimm_bus="$line"$'\n'
            else
                current_dimm_bus+="$line"$'\n'
            fi
        done <<< "$dimm_data"
        # Process last DIMM
        if [ -n "$current_dimm_bus" ] && echo "$current_dimm_bus" | grep -q "Total Width:" && ! echo "$current_dimm_bus" | grep -q "No Module Installed"; then
            local width_str=$(echo "$current_dimm_bus" | grep "Total Width:" | cut -d: -f2 | xargs)
            local width_num=$(echo "$width_str" | grep -oE '[0-9]+' | head -1)
            if [ -n "$width_num" ] && [[ "$width_num" =~ ^[0-9]+$ ]]; then
                total_bus_width=$((total_bus_width + width_num))
            fi
        fi
        
        if [ $total_bus_width -gt 0 ]; then
            total_bus_width_bits="${total_bus_width} bits"
        fi
        
        echo "    \"total_memory_bus_width\": \"${total_bus_width_bits:-null}\""
        echo "  },"
        
        # GPU Information
        echo "  \"gpu\": {"
        if command -v nvidia-smi &> /dev/null; then
            # Count number of GPUs
            local gpu_count=$(nvidia-smi --list-gpus 2>/dev/null | wc -l)
            local gpu_name=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
            local gpu_memory=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader 2>/dev/null | head -1)
            local gpu_driver=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)
            
            # Get memory bandwidth information from nvidia-smi -q (detailed query)
            # Note: nvidia-smi does not directly provide memory bus width, so we try alternative sources
            local gpu_mem_bus_width=$(nvidia-smi -q 2>/dev/null | grep -i "Bus Width" | head -1 | cut -d: -f2 | xargs || echo "")
            local gpu_mem_type=$(nvidia-smi -q 2>/dev/null | grep -i "Memory Type" | head -1 | cut -d: -f2 | xargs || echo "")
            local gpu_mem_transfer_rate=$(nvidia-smi -q 2>/dev/null | grep -i "Memory Transfer Rate\|Transfer Rate" | head -1 | cut -d: -f2 | xargs || echo "")
            
            # Try to get bus width from TechPowerUp if not found in nvidia-smi
            if [ -z "$gpu_mem_bus_width" ] && [ -n "$gpu_name" ]; then
                # Normalize GPU name for TechPowerUp lookup (replace "Laptop GPU" with "Mobile")
                local normalized_name=$(echo "$gpu_name" | sed 's/Laptop GPU/Mobile/g' | sed 's/GPU//g' | tr '[:upper:]' '[:lower:]' | sed 's/^nvidia //' | sed 's/geforce //' | tr ' ' '-' | sed 's/--/-/g' | sed 's/-$//')
                
                # Try to fetch from TechPowerUp GPU database
                # TechPowerUp URLs are typically: https://www.techpowerup.com/gpu-specs/<model>.c<id>
                if command -v curl &> /dev/null; then
                    # Try multiple URL patterns - TechPowerUp has specific naming conventions
                    local tpu_urls=(
                        "https://www.techpowerup.com/gpu-specs/${normalized_name}.c"
                        "https://www.techpowerup.com/gpu-specs/?name=${normalized_name}"
                    )
                    
                    local found_bus=""
                    for base_url in "${tpu_urls[@]}"; do
                        # First try a direct search page
                        local search_page=$(curl -s -L --max-time 5 --user-agent "Mozilla/5.0" "https://www.techpowerup.com/gpu-specs/?name=$(echo "$gpu_name" | sed 's/Laptop GPU/Mobile/g' | tr ' ' '+')" 2>/dev/null || echo "")
                        
                        # Extract GPU spec links from search results
                        if [ -n "$search_page" ]; then
                            # Look for links that match the normalized name pattern
                            local spec_links=$(echo "$search_page" | grep -oE 'gpu-specs/[^"]+' | grep -i "$(echo "$normalized_name" | sed 's/-.*//')" | head -3)
                            
                            # Try each potential spec page
                            for spec_link in $spec_links; do
                                local spec_url="https://www.techpowerup.com/${spec_link}"
                                local spec_page=$(curl -s -L --max-time 5 --user-agent "Mozilla/5.0" "$spec_url" 2>/dev/null || echo "")
                                
                                if [ -n "$spec_page" ]; then
                                    # TechPowerUp HTML structure: <dt>Memory Bus</dt> followed by <dd>X bit</dd>
                                    # The value might be on multiple lines, so get more context
                                    local mem_bus_section=$(echo "$spec_page" | grep -A 5 -i "memory bus" | head -6)
                                    # Extract the value - look for pattern like "96 bit" or "192 bit" etc
                                    found_bus=$(echo "$mem_bus_section" | grep -oE '[0-9]+[[:space:]]+bit' | head -1 | xargs || echo "")
                                    
                                    # Also check GPU name in the page to make sure we have the right variant
                                    # Extract the GPU name from the page title or h1
                                    local page_gpu_name=$(echo "$spec_page" | grep -iE '<title>|<h1' | grep -oE 'RTX[[:space:]]*[0-9]+[^<]*' | head -1 || echo "")
                                    
                                    # Verify this is actually the right GPU by checking the GPU name matches
                                    # Allow for variations like "4080 Mobile" vs "4080 Laptop GPU"
                                    if [ -n "$found_bus" ]; then
                                        local gpu_num=$(echo "$gpu_name" | grep -oE 'RTX[[:space:]]*[0-9]+' | grep -oE '[0-9]+' || echo "")
                                        if [ -z "$gpu_num" ] || echo "$page_gpu_name" | grep -qi "$gpu_num"; then
                                            gpu_mem_bus_width="$found_bus"
                                            break 2  # Break out of both loops
                                        fi
                                    fi
                                fi
                            done
                        fi
                    done
                fi
            fi
            
            # Extract bus width number for calculations (if we have it)
            local bus_width_num=""
            if [ -n "$gpu_mem_bus_width" ]; then
                bus_width_num=$(echo "$gpu_mem_bus_width" | grep -oE '[0-9]+' | head -1)
            fi
            
            # Calculate memory bandwidth if we have bus width and transfer rate
            # Memory Bandwidth (GB/s) = (Memory Transfer Rate (MT/s) * Bus Width (bits)) / 8 / 1000
            local gpu_mem_bandwidth=""
            if [ -n "$bus_width_num" ] && [ -n "$gpu_mem_transfer_rate" ]; then
                local transfer_rate_num=$(echo "$gpu_mem_transfer_rate" | grep -oE '[0-9]+' | head -1)
                if [ -n "$transfer_rate_num" ]; then
                    gpu_mem_bandwidth=$(echo "scale=2; (${transfer_rate_num} * ${bus_width_num}) / 8 / 1000" | bc 2>/dev/null || echo "")
                    [ -n "$gpu_mem_bandwidth" ] && gpu_mem_bandwidth="${gpu_mem_bandwidth} GB/s"
                fi
            fi
            
            # Try alternative method: calculate from maximum memory clock if we have bus width
            if [ -z "$gpu_mem_bandwidth" ] && [ -n "$bus_width_num" ]; then
                # Get maximum memory clock from nvidia-smi (use max for theoretical bandwidth)
                local gpu_mem_clock_max=$(nvidia-smi --query-gpu=clocks.max.memory --format=csv,noheader 2>/dev/null | head -1 | xargs)
                
                if [ -n "$gpu_mem_clock_max" ]; then
                    # Memory clock is in MHz, need to multiply by 2 for DDR (double data rate)
                    # Formula: (Max Memory Clock (MHz) * 2 * Bus Width (bits)) / 8 / 1000 = GB/s
                    gpu_mem_bandwidth=$(echo "scale=2; (${gpu_mem_clock_max} * 2 * ${bus_width_num}) / 8 / 1000" | bc 2>/dev/null || echo "")
                    [ -n "$gpu_mem_bandwidth" ] && gpu_mem_bandwidth="${gpu_mem_bandwidth} GB/s"
                fi
            fi
            
            echo "    \"count\": ${gpu_count:-1},"
            echo "    \"model\": \"${gpu_name}\","
            echo "    \"memory\": \"${gpu_memory}\","
            [ -n "$gpu_mem_type" ] && echo "    \"memory_type\": \"${gpu_mem_type}\","
            [ -n "$gpu_mem_bus_width" ] && echo "    \"memory_bus_width\": \"${gpu_mem_bus_width}\","
            [ -n "$gpu_mem_transfer_rate" ] && echo "    \"memory_transfer_rate\": \"${gpu_mem_transfer_rate}\","
            [ -n "$gpu_mem_bandwidth" ] && echo "    \"memory_bandwidth\": \"${gpu_mem_bandwidth}\","
            echo "    \"driver_version\": \"${gpu_driver}\","
            echo "    \"present\": true"
        else
            echo "    \"present\": false,"
            echo "    \"model\": null,"
            echo "    \"memory\": null,"
            echo "    \"memory_type\": null,"
            echo "    \"memory_bus_width\": null,"
            echo "    \"memory_transfer_rate\": null,"
            echo "    \"memory_bandwidth\": null,"
            echo "    \"driver_version\": null"
        fi
        echo "  },"
        
        # Power Supply Unit Information (manual input only)
        echo "  \"power_supply\": {"
        local psu_model_effective="$psu_model_manual"
        local has_internal_psu="true"
        if [ -n "$psu_model_effective" ]; then
            has_internal_psu="false"
        fi
        if [ "$is_notebook" = "true" ] || [ "$is_portable_all_in_one" = "true" ] || [ "$mobile_gaming_system" = "true" ]; then
            has_internal_psu="false"
        fi

        echo "    \"has_internal_psu\": ${has_internal_psu},"
        echo "    \"manufacturer\": null,"
        if [ -n "$psu_model_effective" ]; then
            echo "    \"model\": \"${psu_model_effective}\"," 
        else
            echo "    \"model\": null,"
        fi
        echo "    \"serial_number\": null,"
        echo "    \"wattage\": null,"
        echo "    \"efficiency_rating\": null"
        echo "  },"
        
        # Battery Information (for notebooks)
        echo "  \"battery\": {"
        
        local capacity_wh=""
        if [ -n "$battery_capacity_wh" ] && [ "$battery_capacity_wh" != "" ]; then
            capacity_wh="$battery_capacity_wh"
            echo "    \"capacity_full_wh\": \"${capacity_wh}\"," 
        else
            echo "    \"capacity_full_wh\": null," 
        fi
        
        local battery_present_flag="false"
        if [ -n "$battery_device" ]; then
            battery_present_flag="true"
        fi
        echo "    \"present\": ${battery_present_flag},"
        
        local battery_removed_flag="false"
        if [ "$battery_present_flag" != "true" ] && [ "$BATTERY_REMOVED" = "true" ]; then
            battery_removed_flag="true"
        fi
        echo "    \"removed\": ${battery_removed_flag}"
        echo "  },"
        
        # Display Information
        echo "  \"displays\": ["
        local first_display=true
        local display_count=0
        local display_names=()
        
        # First pass: collect display names
        while IFS= read -r line; do
            if [[ "$line" =~ " connected " ]]; then
                local display_name=$(echo "$line" | awk '{print $1}')
                display_names+=("$display_name")
                display_count=$((display_count + 1))
            fi
        done <<< "$(xrandr)"
        
        # Prompt for color gamut information for each display
        echo "Collecting display color gamut information..." >&2
        declare -A display_gamuts display_contrast display_viewing
        for display_name in "${display_names[@]}"; do
            echo "" >&2
            echo "Color gamut options for display '${display_name}':" >&2
            echo "  A - <= 32.9% of CIELUV" >&2
            echo "  B - > 32.9% of CIELUV (99% or more of defined sRGB colors)" >&2
            echo "  C - > 38.4% of CIELUV (99% or more of defined Adobe RGB colors)" >&2
            read -p "Select color gamut (A/B/C): " color_gamut_choice
            case "${color_gamut_choice^^}" in
                A)
                    display_gamuts["$display_name"]="A - <= 32.9% of CIELUV"
                    ;;
                B)
                    display_gamuts["$display_name"]="B - > 32.9% of CIELUV (99% or more of defined sRGB colors)"
                    ;;
                C)
                    display_gamuts["$display_name"]="C - > 38.4% of CIELUV (99% or more of defined Adobe RGB colors)"
                    ;;
                *)
                    display_gamuts["$display_name"]="${color_gamut_choice:-null}"
                    ;;
            esac

            read -p "Does display '${display_name}' meet the contrast ratio requirement (>= 60:1)? (true/false): " contrast_response
            local contrast_normalized=$(echo "${contrast_response}" | tr '[:upper:]' '[:lower:]')
            case "$contrast_normalized" in
                y|yes|true)
                    display_contrast["$display_name"]="true"
                    ;;
                n|no|false)
                    display_contrast["$display_name"]="false"
                    ;;
                *)
                    display_contrast["$display_name"]=""
                    ;;
            esac

            read -p "Does display '${display_name}' meet the viewing angle requirement (> 85 degrees)? (true/false): " viewing_response
            local viewing_normalized=$(echo "${viewing_response}" | tr '[:upper:]' '[:lower:]')
            case "$viewing_normalized" in
                y|yes|true)
                    display_viewing["$display_name"]="true"
                    ;;
                n|no|false)
                    display_viewing["$display_name"]="false"
                    ;;
                *)
                    display_viewing["$display_name"]=""
                    ;;
            esac
        done
        echo "" >&2
        
        # Second pass: process displays and include color gamut
        for display_name in "${display_names[@]}"; do
            if [ "$first_display" = false ]; then
                echo ","
            fi
            first_display=false
            
            # Get display info from xrandr
            local xrandr_line=$(xrandr | grep "^${display_name}.* connected")
            local resolution=$(echo "$xrandr_line" | grep -oE '[0-9]+x[0-9]+' | head -1)
            local width=$(echo "$resolution" | cut -dx -f1)
            local height=$(echo "$resolution" | cut -dx -f2)
            local megapixels=""
            if [ -n "$width" ] && [ -n "$height" ]; then
                megapixels=$(echo "scale=2; (${width} * ${height}) / 1000000" | bc 2>/dev/null || echo "")
            fi
            
            # Get physical dimensions from inxi.txt (more reliable than EDID)
            local width_inches=""
            local height_inches=""
            local diagonal_inches=""
            local area_square_inches=""
            local width_mm=""
            local height_mm=""
            
            # Get panel identifier from EDID (monitor-info.txt)
            local panel_model=""
            local monitor_info_file="${HOME}/monitor-info.txt"
            if [ -f "$monitor_info_file" ]; then
                # Find the EDID block for this display
                # xrandr --verbose | edid-decode outputs each display's EDID in sections
                # The display name appears in xrandr output, followed by EDID decoded data
                local found_display=false
                local collect_lines=false
                local edid_lines=""
                
                while IFS= read -r line; do
                    # Look for the display name in xrandr output format: "DISPLAY_NAME connected"
                    if echo "$line" | grep -qE "^${display_name}[[:space:]]+connected"; then
                        found_display=true
                        collect_lines=true
                        edid_lines="$line"$'\n'
                    # Also check for display name appearing in other contexts
                    elif echo "$line" | grep -qE "^[[:space:]]*${display_name}[[:space:]]"; then
                        if [ "$found_display" = false ]; then
                            found_display=true
                            collect_lines=true
                            edid_lines="$line"$'\n'
                        fi
                    elif [ "$collect_lines" = true ]; then
                        # Stop collecting when we hit another display connection line
                        if echo "$line" | grep -qE "^[A-Za-z0-9_-]+[[:space:]]+connected"; then
                            local other_display=$(echo "$line" | grep -oE "^[A-Za-z0-9_-]+")
                            if [ "$other_display" != "$display_name" ]; then
                                break
                            fi
                        fi
                        edid_lines="${edid_lines}${line}"$'\n'
                    fi
                done < "$monitor_info_file"
                
                # Extract monitor name/model from the EDID block
                # edid-decode outputs fields like "Monitor name:", "Product name:", etc.
                if [ -n "$edid_lines" ]; then
                    # Try to find monitor name in various common formats
                    local monitor_name_line=$(echo "$edid_lines" | grep -iE "(Monitor name|Display name|Product name)" | head -1)
                    if [ -n "$monitor_name_line" ]; then
                        # Extract value after colon
                        panel_model=$(echo "$monitor_name_line" | sed 's/.*:[[:space:]]*//' | sed 's/[[:space:]]*$//' | head -1)
                    fi
                    
                    # Fallback: try manufacturer + product code if no name found
                    if [ -z "$panel_model" ] || [ "$panel_model" = "" ]; then
                        local manufacturer=$(echo "$edid_lines" | grep -iE "^[[:space:]]*Manufacturer:" | head -1 | sed 's/.*:[[:space:]]*//' | sed 's/[[:space:]]*$//')
                        local product_code=$(echo "$edid_lines" | grep -iE "^[[:space:]]*Product code:" | head -1 | sed 's/.*:[[:space:]]*//' | sed 's/[[:space:]]*$//')
                        if [ -n "$manufacturer" ] && [ -n "$product_code" ]; then
                            panel_model="${manufacturer} ${product_code}"
                        elif [ -n "$manufacturer" ]; then
                            panel_model="$manufacturer"
                        fi
                    fi
                fi
            fi
            
            # Check for inxi.txt in home directory (where script generates it)
            local inxi_file="${HOME}/inxi.txt"
            if [ -f "$inxi_file" ]; then
                # Find the Monitor block that matches this display
                # Monitor names in inxi might be slightly different (e.g., "eDP-1" vs "eDP1")
                # Try to match by looking for the display name or similar pattern
                local monitor_block=""
                local display_pattern=$(echo "$display_name" | sed 's/-//g' | tr '[:upper:]' '[:lower:]')
                
                # Look for Monitor blocks in inxi.txt
                local in_monitor_section=false
                while IFS= read -r line; do
                    if echo "$line" | grep -qiE "^[[:space:]]*Monitor-[0-9]+:"; then
                        # Check if this monitor matches our display
                        if echo "$line" | grep -qi "$display_name" || echo "$line" | grep -qi "$display_pattern"; then
                            in_monitor_section=true
                            monitor_block="$line"$'\n'
                        else
                            in_monitor_section=false
                            monitor_block=""
                        fi
                    elif [ "$in_monitor_section" = true ]; then
                        # Continue collecting lines until we hit the next section or empty line
                        if echo "$line" | grep -qE '^[[:space:]]*[A-Z]'; then
                            # Next section started
                            break
                        elif [ -n "$line" ]; then
                            monitor_block="${monitor_block}${line}"$'\n'
                        fi
                    fi
                done < "$inxi_file"
                
                if [ -n "$monitor_block" ]; then
                    # Extract size: format is "size: 381x214mm (15.0x8.4")"
                    local size_line=$(echo "$monitor_block" | grep -i "size:")
                    if [ -n "$size_line" ]; then
                        # Extract width and height in inches from the parentheses
                        local size_inches=$(echo "$size_line" | grep -oE '\([0-9]+\.[0-9]+x[0-9]+\.[0-9]+"' | sed 's/[()"]//g')
                        if [ -n "$size_inches" ]; then
                            width_inches=$(echo "$size_inches" | cut -dx -f1)
                            height_inches=$(echo "$size_inches" | cut -dx -f2)
                        fi
                        
                        # Extract width and height in mm
                        local size_mm=$(echo "$size_line" | grep -oE '[0-9]+x[0-9]+mm' | sed 's/mm//')
                        if [ -n "$size_mm" ]; then
                            width_mm=$(echo "$size_mm" | cut -dx -f1)
                            height_mm=$(echo "$size_mm" | cut -dx -f2)
                        fi
                    fi
                    
                    # Extract diagonal: format is "diag: 437mm (17.2")"
                    local diag_line=$(echo "$monitor_block" | grep -i "diag:")
                    if [ -n "$diag_line" ]; then
                        diagonal_inches=$(echo "$diag_line" | grep -oE '\([0-9]+\.[0-9]+"' | sed 's/[()"]//g')
                    fi
                    
                    # Calculate area in square inches if we have width and height
                    if [ -n "$width_inches" ] && [ -n "$height_inches" ]; then
                        area_square_inches=$(echo "scale=2; ${width_inches} * ${height_inches}" | bc 2>/dev/null || echo "")
                    fi
                fi
            fi
            
            local color_gamut="${display_gamuts[$display_name]:-null}"
            local contrast_value="null"
            if [ -n "${display_contrast[$display_name]}" ]; then
                contrast_value="${display_contrast[$display_name]}"
            fi
            local viewing_value="null"
            if [ -n "${display_viewing[$display_name]}" ]; then
                viewing_value="${display_viewing[$display_name]}"
            fi
            local display_lines=()
            display_lines+=("\"name\": \"${display_name}\"")
            if [ -n "$panel_model" ]; then
                display_lines+=("\"model\": \"${panel_model}\"")
            else
                display_lines+=("\"model\": null")
            fi
            display_lines+=("\"resolution\": \"${resolution}\"")
            display_lines+=("\"width_px\": ${width:-null}")
            display_lines+=("\"height_px\": ${height:-null}")
            display_lines+=("\"megapixels\": ${megapixels:-null}")
            display_lines+=("\"width_mm\": ${width_mm:-null}")
            display_lines+=("\"height_mm\": ${height_mm:-null}")
            display_lines+=("\"width_inches\": ${width_inches:-null}")
            display_lines+=("\"height_inches\": ${height_inches:-null}")
            display_lines+=("\"diagonal_inches\": ${diagonal_inches:-null}")
            display_lines+=("\"area_square_inches\": ${area_square_inches:-null}")
            display_lines+=("\"contrast_ratio_requirement_met\": ${contrast_value}")
            display_lines+=("\"viewing_angle_requirement_met\": ${viewing_value}")
            display_lines+=("\"color_gamut\": \"${color_gamut}\"")
            echo "    {"
            local idx=0
            local total=${#display_lines[@]}
            for line in "${display_lines[@]}"; do
                idx=$((idx + 1))
                if [ $idx -lt $total ]; then
                    echo "      ${line},"
                else
                    echo "      ${line}"
                fi
            done
            echo -n "    }"
        done
        echo ""
        echo "  ],"
        
        # Network Adapters Information
        echo "  \"network_adapters\": ["
        local first_adapter=true
        # Get all ethernet adapters, not just connected ones
        for device in $(ls /sys/class/net/ 2>/dev/null | grep -E '^e(th|n|m)' | grep -v lo); do
            # Verify it's actually an ethernet adapter (has device directory)
            if [ ! -d "/sys/class/net/$device/device" ]; then
                continue
            fi
            if [ "$first_adapter" = false ]; then
                echo ","
            fi
            first_adapter=false
            
            # Get EEE status and maximum speed
            local eee_status="unknown"
            local eee_supported="false"
            local max_speed="unknown"
            
            if command -v ethtool &> /dev/null; then
                # Get EEE status
                local eee_info=$(ethtool --show-eee "$device" 2>/dev/null)
                if [ -n "$eee_info" ] && ! echo "$eee_info" | grep -qi "not supported"; then
                    local eee_enabled_str=$(echo "$eee_info" | grep "EEE status:" | cut -d: -f2 | xargs || echo "")
                    eee_status="$eee_enabled_str"
                    eee_supported="true"
                else
                    eee_status="not supported"
                    eee_supported="false"
                fi
                
                # Get supported speeds and find maximum
                local ethtool_output=$(ethtool "$device" 2>/dev/null)
                if [ -n "$ethtool_output" ]; then
                    # Extract supported link modes - get all lines that are indented after "Supported link modes:"
                    # The "Supported link modes:" section can span multiple lines
                    local in_section=false
                    local supported_modes=""
                    while IFS= read -r line; do
                        if echo "$line" | grep -q "Supported link modes:"; then
                            in_section=true
                            # Get the rest of the line after the colon
                            local rest=$(echo "$line" | sed 's/.*Supported link modes:[[:space:]]*//')
                            if [ -n "$rest" ]; then
                                supported_modes="${supported_modes} ${rest}"
                            fi
                        elif [ "$in_section" = true ]; then
                            # Check if this line starts a new section (starts with a letter or has a colon)
                            if echo "$line" | grep -qE '^[[:space:]]*[A-Za-z]'; then
                                if echo "$line" | grep -qE ':[[:space:]]*$|:[[:space:]]+[^[:space:]]'; then
                                    # This is a new section header
                                    break
                                fi
                            fi
                            # Check if line is still part of link modes (starts with whitespace and has "base")
                            if echo "$line" | grep -qE '^[[:space:]]+.*base'; then
                                supported_modes="${supported_modes} $(echo "$line" | sed 's/^[[:space:]]*//')"
                            elif echo "$line" | grep -qE '^[[:space:]]*$'; then
                                # Empty line, continue
                                continue
                            else
                                # Probably next section
                                break
                            fi
                        fi
                    done <<< "$ethtool_output"
                    supported_modes=$(echo "$supported_modes" | xargs)
                    
                    if [ -n "$supported_modes" ]; then
                        # Parse speeds from link modes (e.g., "1000baseT/Full", "10000baseT/Full", "25000baseSR/Full")
                        # Extract numeric values and convert to Mbps, then find maximum
                        local max_speed_mbps=0
                        # Extract all speed numbers (e.g., 10, 100, 1000 from "10baseT", "100baseT", "1000baseT")
                        local speed_values=$(echo "$supported_modes" | grep -oE '[0-9]+(base|BASE|Base)' | grep -oE '[0-9]+' || echo "")
                        
                        while IFS= read -r speed_num; do
                            if [ -n "$speed_num" ] && [[ "$speed_num" =~ ^[0-9]+$ ]]; then
                                # The speed_num is already in Mbps (10 = 10 Mbps, 100 = 100 Mbps, 1000 = 1000 Mbps = 1 Gbps)
                                local speed_mbps=$speed_num
                                
                                if [ $speed_mbps -gt $max_speed_mbps ]; then
                                    max_speed_mbps=$speed_mbps
                                fi
                            fi
                        done <<< "$speed_values"
                        
                        # Format the maximum speed
                        if [ $max_speed_mbps -gt 0 ]; then
                            if [ $max_speed_mbps -ge 1000 ]; then
                                # Convert to Gbps for display
                                local speed_gbps=$(echo "scale=1; ${max_speed_mbps} / 1000" | bc 2>/dev/null || echo "$((max_speed_mbps / 1000))")
                                # Check for common speeds and format nicely
                                if [ "$speed_gbps" = "1.0" ] || [ "$speed_gbps" = "1" ]; then
                                    max_speed="1 Gbps"
                                elif [ "$speed_gbps" = "2.5" ]; then
                                    max_speed="2.5 Gbps"
                                elif [ "$speed_gbps" = "5.0" ] || [ "$speed_gbps" = "5" ]; then
                                    max_speed="5 Gbps"
                                elif [ "$speed_gbps" = "10.0" ] || [ "$speed_gbps" = "10" ]; then
                                    max_speed="10 Gbps"
                                elif [ "$speed_gbps" = "25.0" ] || [ "$speed_gbps" = "25" ]; then
                                    max_speed="25 Gbps"
                                elif [ "$speed_gbps" = "40.0" ] || [ "$speed_gbps" = "40" ]; then
                                    max_speed="40 Gbps"
                                elif [ "$speed_gbps" = "100.0" ] || [ "$speed_gbps" = "100" ]; then
                                    max_speed="100 Gbps"
                                else
                                    max_speed="${speed_gbps} Gbps"
                                fi
                            else
                                max_speed="${max_speed_mbps} Mbps"
                            fi
                        fi
                    fi
                fi
            fi
            
            echo "    {"
            echo -n "      \"name\": \"${device}\""
            echo "," && echo -n "      \"max_speed\": \"${max_speed}\""
            echo "," && echo -n "      \"eee_supported\": ${eee_supported}"
            echo "," && echo -n "      \"eee_status\": \"${eee_status}\""
            echo ""
            echo -n "    }"
        done
        echo ""
        echo "  ],"
        
        # Storage Information
        echo "  \"storage\": {"
        echo "    \"disks\": ["
        local first_disk=true
        for disk in /sys/block/sd* /sys/block/nvme*; do
            if [ -e "$disk" ]; then
                local disk_name=$(basename "$disk")
                if [ "$first_disk" = false ]; then
                    echo ","
                fi
                first_disk=false
                
                local size=$(cat "${disk}/size" 2>/dev/null || echo "0")
                local size_gb=$(echo "scale=2; (${size} * 512) / 1073741824" | bc 2>/dev/null || echo "0")
                local model=$(cat "${disk}/device/model" 2>/dev/null | xargs || echo "")
                local vendor=$(cat "${disk}/device/vendor" 2>/dev/null | xargs || echo "")
                local type="unknown"
                if [[ "$disk_name" =~ "nvme" ]]; then
                    type="NVMe SSD"
                elif [[ -f "${disk}/queue/rotational" ]]; then
                    local rotational=$(cat "${disk}/queue/rotational" 2>/dev/null || echo "1")
                    if [ "$rotational" = "0" ]; then
                        type="SSD"
                    else
                        type="HDD"
                    fi
                fi
                
                echo "      {"
                echo "        \"name\": \"${disk_name}\","
                echo "        \"type\": \"${type}\","
                echo "        \"size_gb\": ${size_gb},"
                echo "        \"vendor\": \"${vendor}\","
                echo "        \"model\": \"${model}\""
                echo -n "      }"
            fi
        done
        echo ""
        echo "    ],"
        local disk_count=$(ls -d /sys/block/sd* /sys/block/nvme* 2>/dev/null | wc -l)
        echo "    \"disk_count\": ${disk_count}"
        echo "  },"
        
        # Operating System Information
        echo "  \"operating_system\": {"
        local os_name=$(grep "^NAME=" /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' || echo "")
        local os_version=$(grep "^VERSION=" /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' || echo "")
        local os_id=$(grep "^ID=" /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' || echo "")
        local kernel_version=$(uname -r)
        echo "    \"name\": \"${os_name}\","
        echo "    \"version\": \"${os_version}\","
        echo "    \"id\": \"${os_id}\","
        echo "    \"kernel_version\": \"${kernel_version}\""
        echo "  },"
        
        # Sleep State Capabilities
        echo "  \"sleep_states\": {"
        # Check for S0ix support (Low Power S0 Idle)
        local s0ix_supported="false"
        if command -v acpidump &> /dev/null && [ -f /sys/firmware/acpi/tables/FACP ]; then
            # Try to check ACPI tables for S0ix support
            local s0ix_check=$(sudo acpidump -b 2>/dev/null | strings | grep -i "Low Power S0 Idle" | head -1)
            if [ -n "$s0ix_check" ]; then
                s0ix_supported="true"
            fi
        fi
        # Check for S3 support
        local s3_supported="unknown"
        if [ -f /sys/power/mem_sleep ]; then
            if grep -q "s2idle\|deep" /sys/power/mem_sleep 2>/dev/null; then
                s3_supported="true"
            fi
        fi
        echo "    \"s0ix_supported\": ${s0ix_supported},"
        echo "    \"s3_supported\": \"${s3_supported}\""
        echo "  }"
        
        echo "}"
    } > "$json_file"
    
    # Also create a text version for backwards compatibility
    jq '.' "$json_file" > "$output_file" 2>/dev/null || cat "$json_file" > "$output_file"
    
    echo "System information collected and saved to $json_file and $output_file" >&2
    
    # Store file paths in global variables for use outside function
    TEC_JSON_FILE="$json_file"
    TEC_OUTPUT_FILE="$output_file"
    TEC_ES_RESPONSE_FILE="$es_response_file"
}

# Function to validate and review collected TEC information
validate_tec_info() {
    local json_file="$1"
    local output_file="$2"
    
    if [ ! -f "$json_file" ] || ! command -v jq &> /dev/null; then
        echo "Warning: Cannot validate - JSON file or jq not available" >&2
        return 0
    fi
    
    local validated="false"
    while [ "$validated" != "true" ]; do
        echo "" >&2
        echo "═══════════════════════════════════════════════════════════════" >&2
        echo "TEC INFORMATION REVIEW - All Collected Data" >&2
        echo "═══════════════════════════════════════════════════════════════" >&2
        echo "" >&2
        
        # Display all information in readable format
        jq -r '
            "System Information:",
            "  Product Name: " + (.system.product_name // "null"),
            "  Manufacturer: " + (.system.manufacturer // "null"),
            "  Version: " + (.system.version // "null"),
            "  BIOS Vendor: " + (.system.bios_vendor // "null"),
            "  BIOS Version: " + (.system.bios_version // "null"),
            "  BIOS Date: " + (.system.bios_date // "null"),
            "  Chassis Type: " + (.system.chassis_type // "null"),
            "  Baseboard Manufacturer: " + (.system.baseboard_manufacturer // "null"),
            "  Baseboard Product: " + (.system.baseboard_product // "null"),
            "  Baseboard Version: " + (.system.baseboard_version // "null"),
            "  Motherboard Model Number: " + (.system.motherboard_model_number // "null"),
            "  Expandability Lookup Identifier: " + (.system.expandability_lookup_identifier // "null"),
            "",
            "CPU Information:",
            "  Model: " + (.cpu.model // "null"),
            "  Cores: " + (.cpu.cores // "null" | tostring),
            "  Threads: " + (.cpu.threads // "null" | tostring),
            "",
            "GPU Information:",
            "  Model: " + (.gpu.model // "null"),
            "  Memory Bandwidth (GB/s): " + (.gpu.memory_bandwidth_gbps // "null" | tostring),
            "",
            "Memory Information:",
            "  Total Capacity (GB): " + (.memory.total_capacity_gb // "null" | tostring),
            "  Total Memory Bus Width: " + (.memory.total_memory_bus_width // "null"),
            "  ECC: " + (.memory.ecc // "null"),
            "",
            "Battery Information:",
            "  Capacity (Wh): " + ((.battery.capacity_full_wh // "null") | tostring),
            "  Technology: " + (.battery.technology // "null"),
            "  Removed: " + (if .battery.removed == null then "null" else (.battery.removed | tostring) end),
            "",
            "Displays:",
            (.displays[] | "  " + ((.name // "null")) + ": " + ((.resolution // "null")) + " (color gamut: " + ((.color_gamut // "null")) + ", contrast >=60: " + (if .contrast_ratio_requirement_met == null then "null" else (.contrast_ratio_requirement_met | tostring) end) + ", viewing angle >85: " + (if .viewing_angle_requirement_met == null then "null" else (.viewing_angle_requirement_met | tostring) end) + ")"),
            "",
            "Storage:",
            "  Disk Count: " + (.storage.disk_count // "null" | tostring),
            (.storage.disks[] | "  " + .name + ": " + .type + " " + (.size_gb | tostring) + "GB"),
            "",
            "Network Adapters:",
            (.network_adapters[] | "  " + .name + ": EEE supported=" + (.eee_supported // "false" | tostring) + " (" + (.eee_status // "null") + ")"),
            "",
            "Operating System:",
            "  Name: " + (.operating_system.name // "null"),
            "  Version: " + (.operating_system.version // "null"),
            "",
            "Sleep States:",
            "  S0ix Supported: " + (.sleep_states.s0ix_supported // "null" | tostring),
            "  S3 Supported: " + (.sleep_states.s3_supported // "null"),
            "",
            "Expandability Score: " + (if .expandability_score == null then "null" else (.expandability_score | tostring) end),
            "Mobile Gaming System: " + (if .mobile_gaming_system == null then "null" else (.mobile_gaming_system | tostring) end),
            "Power Supply:",
            "  Has Internal PSU: " + ((.power_supply.has_internal_psu // "null") | tostring),
            "  Manufacturer: " + (.power_supply.manufacturer // "null"),
            "  Model: " + (.power_supply.model // "null"),
            "  Wattage (W): " + ((.power_supply.wattage // "null") | tostring),
            ""
        ' "$json_file" >&2
        
        echo "" >&2
        echo "═══════════════════════════════════════════════════════════════" >&2
        read -p "Review the information above. Would you like to edit any fields? (y/n): " edit_choice >&2
        
        if [[ "$edit_choice" =~ ^[Yy] ]]; then
            echo "" >&2
            echo "Available fields to edit:" >&2
            echo "  1. System Product Name" >&2
            echo "  2. System Manufacturer" >&2
            echo "  3. Baseboard Version" >&2
            echo "  4. Motherboard Model Number" >&2
            echo "  5. Power Supply Model" >&2
            echo "  6. GPU Model" >&2
            echo "  7. GPU Memory Bandwidth (GB/s)" >&2
            echo "  8. Memory Total Capacity (GB)" >&2
            echo "  9. Memory ECC" >&2
            echo "  10. Battery Capacity (Wh)" >&2
            echo "  11. Display Color Gamut" >&2
            echo "  12. Storage Disk Information" >&2
            echo "  13. Network Adapter Speed" >&2
            echo "  14. Expandability Score" >&2
            echo "  15. Mobile Gaming System" >&2
            echo "  16. Skip editing" >&2
            read -p "Enter field number to edit (1-16): " field_num >&2
            
            case "$field_num" in
                1)
                    read -p "Enter new System Product Name: " new_value >&2
                    jq ".system.product_name = \"$new_value\"" "$json_file" > "${json_file}.tmp" && mv "${json_file}.tmp" "$json_file"
                    jq '.' "$json_file" > "$output_file" 2>/dev/null || cat "$json_file" > "$output_file"
                    ;;
                2)
                    read -p "Enter new System Manufacturer: " new_value >&2
                    jq ".system.manufacturer = \"$new_value\"" "$json_file" > "${json_file}.tmp" && mv "${json_file}.tmp" "$json_file"
                    jq '.' "$json_file" > "$output_file" 2>/dev/null || cat "$json_file" > "$output_file"
                    ;;
                3)
                    read -p "Enter new Baseboard Version: " new_value >&2
                    jq ".system.baseboard_version = \"$new_value\"" "$json_file" > "${json_file}.tmp" && mv "${json_file}.tmp" "$json_file"
                    jq '.' "$json_file" > "$output_file" 2>/dev/null || cat "$json_file" > "$output_file"
                    ;;
                4)
                    read -p "Enter new Motherboard Model Number: " new_value >&2
                    jq ".system.motherboard_model_number = \"$new_value\"" "$json_file" > "${json_file}.tmp" && mv "${json_file}.tmp" "$json_file"
                    jq '.' "$json_file" > "$output_file" 2>/dev/null || cat "$json_file" > "$output_file"
                    ;;
                5)
                    read -p "Enter new Power Supply Model (or 'null' to clear): " new_value >&2
                    if [ -z "$new_value" ] || [ "$new_value" = "null" ]; then
                        jq ".power_supply.model = null" "$json_file" > "${json_file}.tmp" && mv "${json_file}.tmp" "$json_file"
                    else
                        jq ".power_supply.model = \"$new_value\"" "$json_file" > "${json_file}.tmp" && mv "${json_file}.tmp" "$json_file"
                    fi
                    jq '.' "$json_file" > "$output_file" 2>/dev/null || cat "$json_file" > "$output_file"
                    ;;
                6)
                    read -p "Enter new GPU Model: " new_value >&2
                    jq ".gpu.model = \"$new_value\"" "$json_file" > "${json_file}.tmp" && mv "${json_file}.tmp" "$json_file"
                    jq '.' "$json_file" > "$output_file" 2>/dev/null || cat "$json_file" > "$output_file"
                    ;;
                7)
                    read -p "Enter new GPU Memory Bandwidth (GB/s): " new_value >&2
                    jq ".gpu.memory_bandwidth_gbps = ($new_value // null)" "$json_file" > "${json_file}.tmp" && mv "${json_file}.tmp" "$json_file"
                    jq '.' "$json_file" > "$output_file" 2>/dev/null || cat "$json_file" > "$output_file"
                    ;;
                8)
                    read -p "Enter new Memory Total Capacity (GB): " new_value >&2
                    jq ".memory.total_capacity_gb = ($new_value // null)" "$json_file" > "${json_file}.tmp" && mv "${json_file}.tmp" "$json_file"
                    jq '.' "$json_file" > "$output_file" 2>/dev/null || cat "$json_file" > "$output_file"
                    ;;
                9)
                    read -p "Enter new Memory ECC (true/false): " new_value >&2
                    if [[ "$new_value" =~ ^[Tt] ]]; then
                        jq ".memory.ecc = \"true\"" "$json_file" > "${json_file}.tmp" && mv "${json_file}.tmp" "$json_file"
                    else
                        jq ".memory.ecc = \"false\"" "$json_file" > "${json_file}.tmp" && mv "${json_file}.tmp" "$json_file"
                    fi
                    jq '.' "$json_file" > "$output_file" 2>/dev/null || cat "$json_file" > "$output_file"
                    ;;
                10)
                    read -p "Enter new Battery Capacity (Wh): " new_value >&2
                    jq ".battery.capacity_full_wh = ($new_value // null)" "$json_file" > "${json_file}.tmp" && mv "${json_file}.tmp" "$json_file"
                    jq '.' "$json_file" > "$output_file" 2>/dev/null || cat "$json_file" > "$output_file"
                    ;;
                11)
                    echo "Available displays:" >&2
                    jq -r '.displays[] | "  \(.name)"' "$json_file" >&2
                    read -p "Enter display name to edit: " display_name >&2
                    if [ -z "$display_name" ]; then
                        echo "No display selected." >&2
                        continue
                    fi

                    read -p "Enter new color gamut (leave blank to keep current): " new_value >&2
                    if [ -n "$new_value" ]; then
                        jq "(.displays[] | select(.name == \"$display_name\") | .color_gamut) = \"$new_value\"" "$json_file" > "${json_file}.tmp" && mv "${json_file}.tmp" "$json_file"
                        jq '.' "$json_file" > "$output_file" 2>/dev/null || cat "$json_file" > "$output_file"
                    fi

                    read -p "Does the display meet the contrast ratio requirement (>= 60:1)? (true/false, leave blank to keep current): " new_contrast >&2
                    if [ -n "$new_contrast" ]; then
                        local contrast_lower=$(echo "$new_contrast" | tr '[:upper:]' '[:lower:]')
                        local contrast_bool="null"
                        case "$contrast_lower" in
                            y|yes|true)
                                contrast_bool="true"
                                ;;
                            n|no|false)
                                contrast_bool="false"
                                ;;
                        esac
                        jq --argjson val "$contrast_bool" "(.displays[] | select(.name == \"$display_name\") | .contrast_ratio_requirement_met) = $val" "$json_file" > "${json_file}.tmp" && mv "${json_file}.tmp" "$json_file"
                        jq '.' "$json_file" > "$output_file" 2>/dev/null || cat "$json_file" > "$output_file"
                    fi

                    read -p "Does the display meet the viewing angle requirement (> 85 degrees)? (true/false, leave blank to keep current): " new_viewing >&2
                    if [ -n "$new_viewing" ]; then
                        local viewing_lower=$(echo "$new_viewing" | tr '[:upper:]' '[:lower:]')
                        local viewing_bool="null"
                        case "$viewing_lower" in
                            y|yes|true)
                                viewing_bool="true"
                                ;;
                            n|no|false)
                                viewing_bool="false"
                                ;;
                        esac
                        jq --argjson val "$viewing_bool" "(.displays[] | select(.name == \"$display_name\") | .viewing_angle_requirement_met) = $val" "$json_file" > "${json_file}.tmp" && mv "${json_file}.tmp" "$json_file"
                        jq '.' "$json_file" > "$output_file" 2>/dev/null || cat "$json_file" > "$output_file"
                    fi
                    ;;
                12)
                    echo "Note: Storage disk information editing not yet implemented. Please edit JSON file manually if needed." >&2
                    ;;
                13)
                    echo "Available network adapters:" >&2
                    jq -r '.network_adapters[] | "  \(.name)"' "$json_file" >&2
                    read -p "Enter adapter name to edit: " adapter_name >&2
                    read -p "Enter new speed: " new_value >&2
                    jq "(.network_adapters[] | select(.name == \"$adapter_name\") | .max_speed) = \"$new_value\"" "$json_file" > "${json_file}.tmp" && mv "${json_file}.tmp" "$json_file"
                    jq '.' "$json_file" > "$output_file" 2>/dev/null || cat "$json_file" > "$output_file"
                    ;;
                14)
                    read -p "Enter new Expandability Score: " new_value >&2
                    jq ".expandability_score = ($new_value // null)" "$json_file" > "${json_file}.tmp" && mv "${json_file}.tmp" "$json_file"
                    jq '.' "$json_file" > "$output_file" 2>/dev/null || cat "$json_file" > "$output_file"
                    ;;
                15)
                    read -p "Enter Mobile Gaming System (true/false): " new_value >&2
                    if [[ "$new_value" =~ ^[Tt] ]]; then
                        jq ".mobile_gaming_system = true" "$json_file" > "${json_file}.tmp" && mv "${json_file}.tmp" "$json_file"
                    else
                        jq ".mobile_gaming_system = false" "$json_file" > "${json_file}.tmp" && mv "${json_file}.tmp" "$json_file"
                    fi
                    jq '.' "$json_file" > "$output_file" 2>/dev/null || cat "$json_file" > "$output_file"
                    ;;
                16)
                    validated="true"
                    ;;
                *)
                    echo "Invalid option" >&2
                    ;;
            esac
        else
            validated="true"
        fi
        
        if [ "$validated" != "true" ]; then
            read -p "Continue editing? (y/n): " continue_edit >&2
            if [[ ! "$continue_edit" =~ ^[Yy] ]]; then
                validated="true"
            fi
        fi
    done
    
    echo "" >&2
    read -p "Final validation: Is all information correct? (y/n): " final_confirm >&2
    if [[ ! "$final_confirm" =~ ^[Yy] ]]; then
        echo "Please review the JSON file manually: $json_file" >&2
        exit 1
    fi
}

# Function to POST JSON data to Flask service
post_tec_json() {
    local json_file="$1"
    
    if [ ! -f "$json_file" ]; then
        echo "Error: JSON file not found: $json_file" >&2
        return 1
    fi
    
    echo "Posting JSON data to Flask service at $FLASK_SERVICE_URL..." >&2
    
    if ! command -v curl &> /dev/null; then
        echo "Error: curl is not installed. Cannot post data to service." >&2
        echo "JSON file location: $json_file" >&2
        return 1
    fi
    
    # POST the JSON file to the Flask service
    local http_code
    local response
    response=$(curl -s -w "\n%{http_code}" -X POST "$FLASK_SERVICE_URL" \
        -H "Content-Type: application/json" \
        --data-binary @"$json_file")
    
    http_code=$(echo "$response" | tail -n1)
    response_body=$(echo "$response" | sed '$d')
    
    if [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]; then
        echo "Successfully posted JSON data to Flask service (HTTP $http_code)" >&2
        if [ -n "$response_body" ]; then
            echo "Response: $response_body" >&2
        fi
        return 0
    else
        echo "Warning: Failed to post JSON data to Flask service (HTTP $http_code)" >&2
        if [ -n "$response_body" ]; then
            echo "Response: $response_body" >&2
        fi
        echo "JSON file location: $json_file" >&2
        return 1
    fi
}

# Collect system information
collect_tec_info

# Validate and review collected information
validate_tec_info "$TEC_JSON_FILE" "$TEC_OUTPUT_FILE"

# POST JSON data to Flask service
post_tec_json "$TEC_JSON_FILE"

echo "T20 setup complete. Shutting down the system."
sudo shutdown -h now

