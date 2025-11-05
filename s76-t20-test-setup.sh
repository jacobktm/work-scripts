#!/bin/bash

# Check for required arguments: username and IP address
if [ $# -lt 2 ]; then
    echo "Error: Missing required arguments" >&2
    echo "Usage: $0 <username> <ip_address>" >&2
    exit 1
fi

SCP_USER="$1"
SCP_IP="$2"
SCRIPT_DIR="$(dirname "$(realpath "$0")")"

# Check for battery and prompt user to note capacity, then shutdown for battery removal
# This must happen before any setup work (git clone, settings changes, etc.)
BATTERY_CAPACITY_FILE="/tmp/battery_capacity_wh.txt"
battery_device=$(ls /sys/class/power_supply/ 2>/dev/null | grep -E '^BAT[0-9]' | head -1)
if [ -n "$battery_device" ]; then
    battery_path="/sys/class/power_supply/${battery_device}"
    battery_capacity_suggestion=""
    
    # Try to read battery capacity from system files
    energy_full_design_file="${battery_path}/energy_full_design"
    energy_full_file="${battery_path}/energy_full"
    charge_full_design_file="${battery_path}/charge_full_design"
    voltage_min_design_file="${battery_path}/voltage_min_design"
    
    if [ -f "$energy_full_design_file" ]; then
        energy_full_design=$(cat "$energy_full_design_file" 2>/dev/null || echo "0")
        battery_capacity_suggestion=$(echo "scale=2; ${energy_full_design} / 1000000" | bc 2>/dev/null || echo "")
    elif [ -f "$energy_full_file" ]; then
        energy_full=$(cat "$energy_full_file" 2>/dev/null || echo "0")
        battery_capacity_suggestion=$(echo "scale=2; ${energy_full} / 1000000" | bc 2>/dev/null || echo "")
    elif [ -f "$charge_full_design_file" ] && [ -f "$voltage_min_design_file" ]; then
        charge_full_design=$(cat "$charge_full_design_file" 2>/dev/null || echo "0")
        voltage_min_design=$(cat "$voltage_min_design_file" 2>/dev/null || echo "0")
        battery_capacity_suggestion=$(echo "scale=2; (${charge_full_design} * ${voltage_min_design}) / 1000000000000" | bc 2>/dev/null || echo "")
    fi
    
    echo "=========================================="
    echo "BATTERY DETECTED: ${battery_device}"
    echo "=========================================="
    if [ -n "$battery_capacity_suggestion" ] && [ "$battery_capacity_suggestion" != "0" ]; then
        echo ""
        echo "Detected battery capacity: ${battery_capacity_suggestion} Wh"
        echo ""
        echo "Please note this battery capacity value."
        echo "The system will shutdown after you press Enter so you can remove the battery."
        echo ""
        read -p "Press Enter when ready to shutdown and remove the battery... "
        battery_capacity_wh="$battery_capacity_suggestion"
    else
        echo ""
        echo "Could not automatically detect battery capacity."
        echo "Please check the battery label and note the capacity in Wh."
        echo ""
        read -p "Enter the battery capacity (in Wh): " battery_capacity_wh
        echo ""
        echo "The system will shutdown after you press Enter so you can remove the battery."
        echo ""
        read -p "Press Enter when ready to shutdown and remove the battery... "
    fi
    
    # Save battery capacity to file for retrieval after restart
    echo "$battery_capacity_wh" > "$BATTERY_CAPACITY_FILE" 2>/dev/null || echo "$battery_capacity_wh" > ~/battery_capacity_wh.txt
    
    echo ""
    echo "Shutting down system in 5 seconds..."
    sleep 5
    sudo shutdown -h now
    exit 0
fi

# If no battery detected, check for saved capacity from previous run
if [ -f "$BATTERY_CAPACITY_FILE" ]; then
    battery_capacity_wh=$(cat "$BATTERY_CAPACITY_FILE" 2>/dev/null | xargs)
    rm -f "$BATTERY_CAPACITY_FILE"
elif [ -f ~/battery_capacity_wh.txt ]; then
    battery_capacity_wh=$(cat ~/battery_capacity_wh.txt 2>/dev/null | xargs)
    rm -f ~/battery_capacity_wh.txt
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
sudo dmidecode --type 17 > mem-info.txt

# Function to collect system information for TEC score calculation
collect_tec_info() {
    local scp_user="$1"
    local scp_ip="$2"
    local output_file="t20-eut.txt"
    local json_file="t20-eut.json"
    local es_response_file=""  # Will be set if expandability calculation is performed
    # battery_capacity_wh should be set from the global scope (from check at start of script)
    
    echo "Collecting system information for TEC score calculation..."
    echo ""
    
    # Battery capacity should already be set from the check at the start of the script
    # If not set and this is a notebook, prompt now (shouldn't happen normally)
    local chassis_type=$(sudo dmidecode --type chassis | grep "Type:" | awk '{print $2}')
    if [[ "$chassis_type" == "Notebook" || "$chassis_type" == "Laptop" ]]; then
        if [ -z "$battery_capacity_wh" ]; then
            echo "No battery detected and no saved capacity found."
            echo "Please enter the battery capacity that was noted before removal."
            read -p "Enter battery capacity in Wh: " battery_capacity_wh
            echo ""
        fi
    fi
    
    # Initialize JSON object
    {
        echo "{"
        echo "  \"timestamp\": \"$(date -Iseconds)\","
        
        # System Information
        echo "  \"system\": {"
        local manufacturer=$(sudo dmidecode --type 1 | grep "Manufacturer:" | cut -d: -f2 | xargs)
        local product_name=$(sudo dmidecode --type 1 | grep "Product Name:" | cut -d: -f2 | xargs)
        local version=$(sudo dmidecode --type 1 | grep "Version:" | cut -d: -f2 | xargs)
        local serial=$(sudo dmidecode --type 1 | grep "Serial Number:" | cut -d: -f2 | xargs)
        echo "    \"manufacturer\": \"${manufacturer}\","
        echo "    \"product_name\": \"${product_name}\","
        echo "    \"version\": \"${version}\","
        echo "    \"serial_number\": \"${serial}\","
        
        # BIOS Information
        local bios_vendor=$(sudo dmidecode --type 0 | grep "Vendor:" | cut -d: -f2 | xargs)
        local bios_version=$(sudo dmidecode --type 0 | grep "Version:" | cut -d: -f2 | xargs)
        local bios_date=$(sudo dmidecode --type 0 | grep "Release Date:" | cut -d: -f2 | xargs)
        echo "    \"bios_vendor\": \"${bios_vendor}\","
        echo "    \"bios_version\": \"${bios_version}\","
        echo "    \"bios_date\": \"${bios_date}\","
        
        # Get chassis type early (needed for expandability prompt logic)
        chassis_type=$(sudo dmidecode --type chassis | grep "Type:" | awk '{print $2}')
        local is_notebook="false"
        if [[ "$chassis_type" == "Notebook" || "$chassis_type" == "Laptop" ]]; then
            is_notebook="true"
        fi
        
        # Get baseboard version for expandability lookup
        local baseboard_version=$(sudo dmidecode --type 2 2>/dev/null | grep "Version:" | cut -d: -f2 | xargs)
        
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
            if [ -n "$baseboard_version" ]; then
                lookup_key=$(echo "$baseboard_version" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]//g')
                if [ -n "$lookup_key" ]; then
                    lookup_result=$(jq -r ".[\"$lookup_key\"] // empty" "$lookup_file" 2>/dev/null)
                    # Only use if it's a valid number (not "null" string or empty)
                    if [ -n "$lookup_result" ] && [ "$lookup_result" != "null" ] && [[ "$lookup_result" =~ ^[0-9]+$ ]]; then
                        expandability_score="$lookup_result"
                    fi
                fi
            fi
            
            # If not found, try product name as fallback
            if [ -z "$expandability_score" ] && [ -n "$product_name" ]; then
                lookup_key=$(echo "$product_name" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]//g')
                if [ -n "$lookup_key" ]; then
                    lookup_result=$(jq -r ".[\"$lookup_key\"] // empty" "$lookup_file" 2>/dev/null)
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
            local system_name_safe=$(echo "$product_name" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | sed 's/--*/-/g' | sed 's/^-//' | sed 's/-$//')
            es_response_file="${system_name_safe}-es.txt"  # Make it accessible outside this block
            
            # Initialize response file
            {
                echo "Expandability Score Calculation Responses"
                echo "========================================"
                echo "System: ${product_name}"
                echo "Baseboard Version: ${baseboard_version}"
                echo "Date: $(date -Iseconds)"
                echo ""
            } > "$es_response_file"
            
            local should_calculate_es="false"
            
            if [ "$is_notebook" = "true" ]; then
                # Battery capacity should already be set from the prompt at the start of the function
                # If not set (shouldn't happen for notebooks), prompt now
                if [ -z "$battery_capacity_wh" ]; then
                    read -p "Enter battery capacity in Wh: " battery_capacity_wh
                fi
                
                local can_be_mobile_gaming="false"
                
                # Minimum battery capacity threshold for mobile gaming systems (75Wh)
                # Systems below this cannot qualify as mobile gaming systems
                local min_battery_capacity=75
                
                # Check for discrete GPU (NVIDIA or AMD)
                local has_discrete_gpu="false"
                if command -v nvidia-smi &> /dev/null && nvidia-smi &>/dev/null 2>&1; then
                    # Check if NVIDIA GPU is present and not just integrated
                    local gpu_name=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 | xargs)
                    if [ -n "$gpu_name" ] && [[ ! "$gpu_name" =~ "Intel|integrated" ]]; then
                        has_discrete_gpu="true"
                    fi
                fi
                
                # Also check for AMD GPU via lspci
                if [ "$has_discrete_gpu" != "true" ]; then
                    if lspci 2>/dev/null | grep -qi "vga.*amd\|display.*amd\|radeon"; then
                        has_discrete_gpu="true"
                    fi
                fi
                
                echo "" >> "$es_response_file"
                echo "Battery Capacity: ${battery_capacity_wh} Wh" >> "$es_response_file"
                echo "Has Discrete GPU: ${has_discrete_gpu}" >> "$es_response_file"
                
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
                
                # System can be mobile gaming only if both checks pass
                if [ "$battery_check_passed" = "true" ] && [ "$gpu_check_passed" = "true" ]; then
                    can_be_mobile_gaming="true"
                else
                    local disqualification_reasons=()
                    if [ "$battery_check_passed" != "true" ]; then
                        disqualification_reasons+=("battery capacity below ${min_battery_capacity}Wh")
                    fi
                    if [ "$gpu_check_passed" != "true" ]; then
                        disqualification_reasons+=("no discrete GPU")
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
                    echo "System: ${product_name} (${baseboard_version})" >&2
                    echo "Battery Capacity: ${battery_capacity_wh} Wh" >&2
                    echo "" >&2
                    echo "A mobile gaming system is defined as a notebook computer that" >&2
                    echo "meets ALL of the following requirements:" >&2
                    echo "" >&2
                    echo "  1. Has a discrete GPU (not integrated graphics only)" >&2
                    echo "  2. GPU has a TGP (Total Graphics Power) of 75W or greater" >&2
                    echo "  3. GPU memory bandwidth of 256 GB/s or greater" >&2
                    echo "  4. System has a 16:9 or 16:10 aspect ratio display" >&2
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
                        disqualification_msg="Battery capacity (${battery_capacity_wh} Wh) is below the minimum threshold (${min_battery_capacity} Wh)"
                    fi
                    if [ "$gpu_check_passed" != "true" ]; then
                        if [ -n "$disqualification_msg" ]; then
                            disqualification_msg="${disqualification_msg} and no discrete GPU detected"
                        else
                            disqualification_msg="No discrete GPU detected"
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
                echo "System: ${product_name} (${baseboard_version})" >&2
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
                if [ -n "$expandability_score" ] && [ -n "$baseboard_version" ] && [ -f "$lookup_file" ] && command -v jq &> /dev/null; then
                    local lookup_key=$(echo "$baseboard_version" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]//g')
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
        local baseboard_manufacturer=$(sudo dmidecode --type 2 2>/dev/null | grep "Manufacturer:" | cut -d: -f2 | xargs)
        local baseboard_product=$(sudo dmidecode --type 2 2>/dev/null | grep "Product Name:" | cut -d: -f2 | xargs)
        echo "    \"baseboard_manufacturer\": \"${baseboard_manufacturer}\","
        echo "    \"baseboard_product\": \"${baseboard_product}\","
        echo "    \"baseboard_version\": \"${baseboard_version}\","
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
            if sudo dmidecode --type 17 2>/dev/null | grep -qi "Error Correction Type.*ECC\|Single-bit ECC"; then
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
        local chassis_manufacturer=$(sudo dmidecode --type chassis | grep "Manufacturer:" | cut -d: -f2 | xargs)
        local chassis_version=$(sudo dmidecode --type chassis | grep "Version:" | cut -d: -f2 | xargs)
        echo "    \"type\": \"${chassis_type}\","
        echo "    \"manufacturer\": \"${chassis_manufacturer}\","
        echo "    \"version\": \"${chassis_version}\""
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
        
        # Try to get CPU TDP (Thermal Design Power) - may be in dmidecode or sysfs
        local cpu_tdp=""
        # Try from dmidecode processor information
        local cpu_tdp_dmi=$(sudo dmidecode --type 4 2>/dev/null | grep -i "Max TDP\|TDP\|Thermal Design Power" | head -1 | grep -oE '[0-9]+' | head -1)
        if [ -n "$cpu_tdp_dmi" ]; then
            cpu_tdp="${cpu_tdp_dmi} W"
        fi
        
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
        [ -n "$cpu_tdp" ] && { echo "," && echo -n "    \"tdp\": \"${cpu_tdp}\""; has_optional=true; }
        echo "," && echo "    \"bogomips\": ${cpu_bogomips:-null}"
        echo "  },"
        
        # Memory Information
        echo "  \"memory\": {"
        echo "    \"dimms\": ["
        local first_dimm=true
        # Parse each DIMM block - split by Handle
        local dimm_data=$(sudo dmidecode --type 17)
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
                    local total_width=$(echo "$current_dimm" | grep "Total Width:" | cut -d: -f2 | xargs)
                    local data_width=$(echo "$current_dimm" | grep "Data Width:" | cut -d: -f2 | xargs)
                    
                    echo "      {"
                    echo -n "        \"size\": \"${size:-}\""
                    [ -n "$locator" ] && echo "," && echo -n "        \"locator\": \"${locator}\""
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
            local total_width=$(echo "$current_dimm" | grep "Total Width:" | cut -d: -f2 | xargs)
            local data_width=$(echo "$current_dimm" | grep "Data Width:" | cut -d: -f2 | xargs)
            
            echo "      {"
            echo -n "        \"size\": \"${size:-}\""
            [ -n "$locator" ] && echo "," && echo -n "        \"locator\": \"${locator}\""
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
                local gpu_mem_clock_max=$(nvidia-smi --query-gpu=clocks.max.mem --format=csv,noheader 2>/dev/null | head -1 | grep -oE '[0-9]+' || echo "")
                
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
        
        # Power Supply Unit Information
        echo "  \"power_supply\": {"
        local psu_manufacturer=$(sudo dmidecode --type 39 2>/dev/null | grep "Manufacturer:" | head -1 | cut -d: -f2 | xargs || echo "")
        local psu_model=$(sudo dmidecode --type 39 2>/dev/null | grep "Name:" | head -1 | cut -d: -f2 | xargs || echo "")
        local psu_serial=$(sudo dmidecode --type 39 2>/dev/null | grep "Serial Number:" | head -1 | cut -d: -f2 | xargs || echo "")
        local psu_wattage=$(sudo dmidecode --type 39 2>/dev/null | grep -i "Maximum Power\|Max Power\|Rated Power" | head -1 | grep -oE '[0-9]+' | head -1 || echo "")
        
        # Try alternative methods if dmidecode type 39 doesn't work
        if [ -z "$psu_manufacturer" ]; then
            # Check sysfs for power supply info (for AC adapters on laptops)
            local ac_adapter=$(ls /sys/class/power_supply/ | grep -E '^AC|^ADP' | head -1)
            if [ -n "$ac_adapter" ]; then
                local ac_path="/sys/class/power_supply/${ac_adapter}"
                psu_model=$(cat "${ac_path}/model_name" 2>/dev/null | xargs || echo "")
                psu_manufacturer=$(cat "${ac_path}/manufacturer" 2>/dev/null | xargs || echo "")
                local ac_wattage=$(cat "${ac_path}/power_now" 2>/dev/null || echo "")
                if [ -n "$ac_wattage" ] && [ -z "$psu_wattage" ]; then
                    # Convert from microWatts to Watts
                    psu_wattage=$(echo "scale=0; ${ac_wattage} / 1000000" | bc 2>/dev/null || echo "")
                fi
            fi
        fi
        
        # Check if system has internal PSU (desktop/workstation)
        local has_internal_psu="false"
        if [ -n "$psu_manufacturer" ] || [ -n "$psu_model" ]; then
            has_internal_psu="true"
        elif [[ "$chassis_type" != "Notebook" && "$chassis_type" != "Laptop" ]]; then
            # Desktop/workstation systems typically have internal PSUs
            has_internal_psu="true"
        fi
        
        echo "    \"has_internal_psu\": ${has_internal_psu},"
        [ -n "$psu_manufacturer" ] && echo "    \"manufacturer\": \"${psu_manufacturer}\","
        [ -n "$psu_model" ] && echo "    \"model\": \"${psu_model}\","
        [ -n "$psu_serial" ] && echo "    \"serial_number\": \"${psu_serial}\","
        [ -n "$psu_wattage" ] && echo "    \"wattage\": ${psu_wattage},"
        echo "    \"efficiency_rating\": null"
        echo "  },"
        
        # Battery Information (for notebooks)
        echo "  \"battery\": {"
        local battery_device=$(ls /sys/class/power_supply/ | grep -E '^BAT[0-9]' | head -1)
        
        # Use prompted battery capacity if available (from earlier in function), otherwise try to read from files
        local capacity_wh=""
        if [ -n "$battery_capacity_wh" ] && [ "$battery_capacity_wh" != "" ]; then
            # Use the prompted value
            capacity_wh="$battery_capacity_wh"
            echo "    \"capacity_full_wh\": \"${capacity_wh}\","
            echo "    \"capacity_full_ah\": null,"
        elif [ -n "$battery_device" ]; then
            local battery_path="/sys/class/power_supply/${battery_device}"
            local capacity_full=""
            local capacity_unit=""
            
            # Prefer energy_full_design or energy_full if available (most accurate, matches printed spec)
            # Then fall back to charge_full_design calculation if needed
            # Some systems report energy_full incorrectly or in wrong units
            if [ -f "${battery_path}/energy_full_design" ]; then
                capacity_full=$(cat "${battery_path}/energy_full_design" 2>/dev/null || echo "")
                capacity_unit="Wh"
            elif [ -f "${battery_path}/energy_full" ]; then
                capacity_full=$(cat "${battery_path}/energy_full" 2>/dev/null || echo "")
                capacity_unit="Wh"
            elif [ -f "${battery_path}/charge_full_design" ] && [ -f "${battery_path}/voltage_min_design" ]; then
                capacity_full=$(cat "${battery_path}/charge_full_design" 2>/dev/null || echo "")
                capacity_unit="Ah"
            fi
            
            local voltage_min_design=$(cat "${battery_path}/voltage_min_design" 2>/dev/null || echo "")
            
            # Calculate capacity in Wh if we have charge in Ah
            if [ -n "$capacity_full" ] && [ -n "$voltage_min_design" ] && [ "$capacity_unit" = "Ah" ]; then
                # capacity_full is in µAh, voltage_min_design is in µV
                # To get Wh: (µAh * µV) / 1,000,000,000,000
                capacity_wh=$(echo "scale=2; (${capacity_full} * ${voltage_min_design}) / 1000000000000" | bc 2>/dev/null || echo "")
                echo "    \"capacity_full_wh\": \"${capacity_wh}\","
                echo "    \"capacity_full_ah\": \"$(echo "scale=2; ${capacity_full} / 1000000" | bc 2>/dev/null || echo "")\","
            elif [ -n "$capacity_full" ] && [ "$capacity_unit" = "Wh" ]; then
                capacity_wh=$(echo "scale=2; ${capacity_full} / 1000000" | bc 2>/dev/null || echo "")
                echo "    \"capacity_full_wh\": \"${capacity_wh}\","
                echo "    \"capacity_full_ah\": null,"
            else
                echo "    \"capacity_full_wh\": null,"
                echo "    \"capacity_full_ah\": null,"
            fi
        else
            echo "    \"capacity_full_wh\": null,"
            echo "    \"capacity_full_ah\": null,"
        fi
        
        # Calculate printed capacity (may be capped at 99Wh to avoid shipping restrictions)
        # Batteries >= 100Wh have stricter shipping regulations, so manufacturers often print 99Wh
        if [ -n "$capacity_wh" ] && [ "$capacity_wh" != "null" ] && [ "$capacity_wh" != "" ]; then
            local capacity_wh_printed=""
            local capacity_wh_compare=$(echo "$capacity_wh >= 100" | bc 2>/dev/null || echo "0")
            if [ "$capacity_wh_compare" = "1" ]; then
                capacity_wh_printed="99.00"
            else
                capacity_wh_printed="$capacity_wh"
            fi
            echo "    \"capacity_full_wh_printed\": \"${capacity_wh_printed}\","
        else
            echo "    \"capacity_full_wh_printed\": null,"
        fi
        
        if [ -n "$battery_device" ]; then
            local battery_path="/sys/class/power_supply/${battery_device}"
            local voltage_min_design=$(cat "${battery_path}/voltage_min_design" 2>/dev/null || echo "")
            local technology=$(cat "${battery_path}/technology" 2>/dev/null || echo "")
            local manufacturer=$(cat "${battery_path}/manufacturer" 2>/dev/null || echo "")
            local model_name=$(cat "${battery_path}/model_name" 2>/dev/null || echo "")
            
            echo "    \"voltage_min_design_v\": \"$(echo "scale=3; ${voltage_min_design} / 1000000" | bc 2>/dev/null || echo "")\","
            echo "    \"technology\": \"${technology}\","
            echo "    \"manufacturer\": \"${manufacturer}\","
            echo "    \"model_name\": \"${model_name}\","
            echo "    \"present\": true"
        else
            echo "    \"present\": false,"
            echo "    \"capacity_full_wh\": null,"
            echo "    \"capacity_full_ah\": null,"
            echo "    \"voltage_min_design_v\": null,"
            echo "    \"technology\": null,"
            echo "    \"manufacturer\": null,"
            echo "    \"model_name\": null"
        fi
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
        declare -A display_gamuts
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
            
            # Get physical dimensions from EDID if available
            local width_mm=""
            local height_mm=""
            if command -v edid-decode &> /dev/null && [ -f "monitor-info.txt" ]; then
                # Try to extract from monitor-info.txt for this display
                local edid_block=$(grep -A 50 "^${display_name}" monitor-info.txt | grep -A 30 "EDID" | head -40)
                if [ -n "$edid_block" ]; then
                    local display_size=$(echo "$edid_block" | grep -i "Display size" | head -1)
                    if [ -n "$display_size" ]; then
                        # Format is usually "Display size: XXX cm x YYY cm" or "XXX mm x YYY mm"
                        width_mm=$(echo "$display_size" | grep -oE '[0-9]+[[:space:]]*(cm|mm)' | head -1 | grep -oE '[0-9]+')
                        height_mm=$(echo "$display_size" | grep -oE '[0-9]+[[:space:]]*(cm|mm)' | tail -1 | grep -oE '[0-9]+')
                        # Convert cm to mm if needed
                        if echo "$display_size" | grep -q "cm"; then
                            width_mm=$(echo "${width_mm} * 10" | bc 2>/dev/null || echo "$width_mm")
                            height_mm=$(echo "${height_mm} * 10" | bc 2>/dev/null || echo "$height_mm")
                        fi
                    fi
                fi
            fi
            
            local color_gamut="${display_gamuts[$display_name]:-null}"
            
            echo "    {"
            echo "      \"name\": \"${display_name}\","
            echo "      \"resolution\": \"${resolution}\","
            echo "      \"width_px\": ${width:-null},"
            echo "      \"height_px\": ${height:-null},"
            echo "      \"megapixels\": ${megapixels:-null},"
            echo "      \"width_mm\": ${width_mm:-null},"
            echo "      \"height_mm\": ${height_mm:-null},"
            echo "      \"color_gamut\": \"${color_gamut}\""
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
            
            # Get EEE status
            local eee_status="unknown"
            local eee_supported="false"
            if command -v ethtool &> /dev/null; then
                local eee_info=$(ethtool --show-eee "$device" 2>/dev/null)
                if [ -n "$eee_info" ] && ! echo "$eee_info" | grep -qi "not supported"; then
                    local eee_enabled_str=$(echo "$eee_info" | grep "EEE status:" | cut -d: -f2 | xargs || echo "")
                    eee_status="$eee_enabled_str"
                    eee_supported="true"
                else
                    eee_status="not supported"
                    eee_supported="false"
                fi
            fi
            
            echo "    {"
            echo -n "      \"name\": \"${device}\""
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
            "  Serial Number: " + (.system.serial_number // "null"),
            "  Chassis Type: " + (.system.chassis_type // "null"),
            "  Baseboard Manufacturer: " + (.system.baseboard_manufacturer // "null"),
            "  Baseboard Product: " + (.system.baseboard_product // "null"),
            "  Baseboard Version: " + (.system.baseboard_version // "null"),
            "",
            "CPU Information:",
            "  Model: " + (.cpu.model // "null"),
            "  Cores: " + (.cpu.cores // "null" | tostring),
            "  Threads: " + (.cpu.threads // "null" | tostring),
            "  TDP (W): " + (.cpu.tdp_w // "null" | tostring),
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
            "  Capacity (Wh): " + (.battery.capacity_full_wh // "null" | tostring),
            "  Technology: " + (.battery.technology // "null"),
            "",
            "Displays:",
            (.displays[] | "  " + .name + ": " + .resolution + " (" + (.color_gamut // "null") + ")"),
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
            "Mobile Gaming System: " + (if .mobile_gaming_system == null then "null" else (.mobile_gaming_system | tostring) end)
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
            echo "  4. CPU TDP (W)" >&2
            echo "  5. GPU Model" >&2
            echo "  6. GPU Memory Bandwidth (GB/s)" >&2
            echo "  7. Memory Total Capacity (GB)" >&2
            echo "  8. Memory ECC" >&2
            echo "  9. Battery Capacity (Wh)" >&2
            echo "  10. Display Color Gamut" >&2
            echo "  11. Storage Disk Information" >&2
            echo "  12. Network Adapter Speed" >&2
            echo "  13. Expandability Score" >&2
            echo "  14. Mobile Gaming System" >&2
            echo "  15. Skip editing" >&2
            read -p "Enter field number to edit (1-15): " field_num >&2
            
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
                    read -p "Enter new CPU TDP (W): " new_value >&2
                    jq ".cpu.tdp_w = ($new_value // null)" "$json_file" > "${json_file}.tmp" && mv "${json_file}.tmp" "$json_file"
                    jq '.' "$json_file" > "$output_file" 2>/dev/null || cat "$json_file" > "$output_file"
                    ;;
                5)
                    read -p "Enter new GPU Model: " new_value >&2
                    jq ".gpu.model = \"$new_value\"" "$json_file" > "${json_file}.tmp" && mv "${json_file}.tmp" "$json_file"
                    jq '.' "$json_file" > "$output_file" 2>/dev/null || cat "$json_file" > "$output_file"
                    ;;
                6)
                    read -p "Enter new GPU Memory Bandwidth (GB/s): " new_value >&2
                    jq ".gpu.memory_bandwidth_gbps = ($new_value // null)" "$json_file" > "${json_file}.tmp" && mv "${json_file}.tmp" "$json_file"
                    jq '.' "$json_file" > "$output_file" 2>/dev/null || cat "$json_file" > "$output_file"
                    ;;
                7)
                    read -p "Enter new Memory Total Capacity (GB): " new_value >&2
                    jq ".memory.total_capacity_gb = ($new_value // null)" "$json_file" > "${json_file}.tmp" && mv "${json_file}.tmp" "$json_file"
                    jq '.' "$json_file" > "$output_file" 2>/dev/null || cat "$json_file" > "$output_file"
                    ;;
                8)
                    read -p "Enter new Memory ECC (true/false): " new_value >&2
                    if [[ "$new_value" =~ ^[Tt] ]]; then
                        jq ".memory.ecc = \"true\"" "$json_file" > "${json_file}.tmp" && mv "${json_file}.tmp" "$json_file"
                    else
                        jq ".memory.ecc = \"false\"" "$json_file" > "${json_file}.tmp" && mv "${json_file}.tmp" "$json_file"
                    fi
                    jq '.' "$json_file" > "$output_file" 2>/dev/null || cat "$json_file" > "$output_file"
                    ;;
                9)
                    read -p "Enter new Battery Capacity (Wh): " new_value >&2
                    jq ".battery.capacity_full_wh = ($new_value // null)" "$json_file" > "${json_file}.tmp" && mv "${json_file}.tmp" "$json_file"
                    jq '.' "$json_file" > "$output_file" 2>/dev/null || cat "$json_file" > "$output_file"
                    ;;
                10)
                    echo "Available displays:" >&2
                    local idx=0
                    jq -r '.displays[] | "  \(.name)"' "$json_file" >&2
                    read -p "Enter display name to edit: " display_name >&2
                    read -p "Enter new color gamut (e.g., '99% sRGB'): " new_value >&2
                    jq "(.displays[] | select(.name == \"$display_name\") | .color_gamut) = \"$new_value\"" "$json_file" > "${json_file}.tmp" && mv "${json_file}.tmp" "$json_file"
                    jq '.' "$json_file" > "$output_file" 2>/dev/null || cat "$json_file" > "$output_file"
                    ;;
                11)
                    echo "Note: Storage disk information editing not yet implemented. Please edit JSON file manually if needed." >&2
                    ;;
                12)
                    echo "Available network adapters:" >&2
                    jq -r '.network_adapters[] | "  \(.name)"' "$json_file" >&2
                    read -p "Enter adapter name to edit: " adapter_name >&2
                    read -p "Enter new speed: " new_value >&2
                    jq "(.network_adapters[] | select(.name == \"$adapter_name\") | .speed) = \"$new_value\"" "$json_file" > "${json_file}.tmp" && mv "${json_file}.tmp" "$json_file"
                    jq '.' "$json_file" > "$output_file" 2>/dev/null || cat "$json_file" > "$output_file"
                    ;;
                13)
                    read -p "Enter new Expandability Score: " new_value >&2
                    jq ".expandability_score = ($new_value // null)" "$json_file" > "${json_file}.tmp" && mv "${json_file}.tmp" "$json_file"
                    jq '.' "$json_file" > "$output_file" 2>/dev/null || cat "$json_file" > "$output_file"
                    ;;
                14)
                    read -p "Enter Mobile Gaming System (true/false): " new_value >&2
                    if [[ "$new_value" =~ ^[Tt] ]]; then
                        jq ".mobile_gaming_system = \"true\"" "$json_file" > "${json_file}.tmp" && mv "${json_file}.tmp" "$json_file"
                    else
                        jq ".mobile_gaming_system = \"false\"" "$json_file" > "${json_file}.tmp" && mv "${json_file}.tmp" "$json_file"
                    fi
                    jq '.' "$json_file" > "$output_file" 2>/dev/null || cat "$json_file" > "$output_file"
                    ;;
                15)
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

# Function to SCP files to server
scp_tec_files() {
    local scp_user="$1"
    local scp_ip="$2"
    local json_file="$3"
    local output_file="$4"
    local es_response_file="$5"
    
    echo "Attempting to copy files to ${scp_user}@${scp_ip}..." >&2
    
    # Determine which main file to use
    local main_file=""
    if [ -f "$output_file" ]; then
        main_file="$output_file"
    elif [ -f "$json_file" ]; then
        main_file="$json_file"
    fi
    
    if command -v scp &> /dev/null || command -v rsync &> /dev/null; then
        # Create a temporary directory and copy files with correct names
        local temp_dir=$(mktemp -d)
        local cleanup_temp=1
        
        # Copy main file with correct remote name
        if [ -n "$main_file" ]; then
            cp "$main_file" "$temp_dir/t20-eut.txt" 2>/dev/null || cleanup_temp=0
        fi
        
        # Copy expandability score response file if it exists
        if [ -n "$es_response_file" ] && [ -f "$es_response_file" ]; then
            cp "$es_response_file" "$temp_dir/$(basename "$es_response_file")" 2>/dev/null || cleanup_temp=0
        fi
        
        # Transfer the entire directory contents in one command
        if [ $cleanup_temp -eq 1 ] && [ -n "$main_file" ]; then
            if command -v rsync &> /dev/null; then
                # rsync: trailing slash on source copies contents, not directory
                rsync -avz "$temp_dir/" "${scp_user}@${scp_ip}:~/" || {
                    echo "Warning: Could not rsync files to ${scp_user}@${scp_ip}." >&2
                    cleanup_temp=0
                }
            else
                # scp: need to copy files individually or use a different approach
                # Use find to get all files and copy them
                (cd "$temp_dir" && find . -type f -exec scp {} "${scp_user}@${scp_ip}:~/" \; 2>/dev/null) || {
                    echo "Warning: Could not SCP files to ${scp_user}@${scp_ip}." >&2
                    cleanup_temp=0
                }
            fi
            
            # Clean up temp directory
            rm -rf "$temp_dir"
        else
            # Fallback: sequential transfers if temp setup failed
            local scp_failed=0
            if [ -n "$main_file" ]; then
                if command -v rsync &> /dev/null; then
                    rsync -avz "$main_file" "${scp_user}@${scp_ip}:~/t20-eut.txt" || scp_failed=1
                else
                    scp "$main_file" "${scp_user}@${scp_ip}:~/t20-eut.txt" || scp_failed=1
                fi
            fi
            if [ -n "$es_response_file" ] && [ -f "$es_response_file" ]; then
                if command -v rsync &> /dev/null; then
                    rsync -avz "$es_response_file" "${scp_user}@${scp_ip}:~/" || scp_failed=1
                else
                    scp "$es_response_file" "${scp_user}@${scp_ip}:~/" || scp_failed=1
                fi
            fi
            
            if [ $scp_failed -eq 1 ]; then
                echo "Warning: Could not transfer files to ${scp_user}@${scp_ip}. Please copy files manually:" >&2
                [ -n "$main_file" ] && echo "  $main_file -> ~/t20-eut.txt" >&2
                [ -n "$es_response_file" ] && [ -f "$es_response_file" ] && echo "  $es_response_file -> ~/$(basename "$es_response_file")" >&2
            fi
            [ -d "$temp_dir" ] && rm -rf "$temp_dir"
        fi
    else
        echo "Warning: Neither rsync nor scp found. Please copy files manually to ${scp_user}@${scp_ip}:" >&2
        [ -n "$main_file" ] && echo "  $main_file -> ~/t20-eut.txt" >&2
        [ -n "$es_response_file" ] && [ -f "$es_response_file" ] && echo "  $es_response_file -> ~/$(basename "$es_response_file")" >&2
    fi
}

# Collect system information
collect_tec_info "$SCP_USER" "$SCP_IP"

# Validate and review collected information
validate_tec_info "$TEC_JSON_FILE" "$TEC_OUTPUT_FILE"

# SCP files to server
scp_tec_files "$SCP_USER" "$SCP_IP" "$TEC_JSON_FILE" "$TEC_OUTPUT_FILE" "$TEC_ES_RESPONSE_FILE"

# Check if apt-proxy exists, and set the correct APT command
if command -v apt-proxy &>/dev/null; then
    APT_COMMAND="apt-proxy"
else
    APT_COMMAND="sudo apt"
fi

# Check if the system is a laptop by examining the chassis type
echo "Checking if the system is a laptop..."
chassis_type=$(sudo dmidecode --type chassis | grep "Type:" | awk '{print $2}')

if [[ "$chassis_type" == "Notebook" || "$chassis_type" == "Laptop" ]]; then
    echo "System is a laptop. Proceeding with setting the panel brightness."

    # Get the maximum brightness value from sysfs
    if [ -f /sys/class/backlight/*/max_brightness ]; then
        max_brightness=$(cat /sys/class/backlight/*/max_brightness)
        brightness_file="/sys/class/backlight/*/brightness"
    else
        echo "Max brightness file not found!"
        exit 1
    fi

    # Prompt user for the max display brightness in nits for this specific model
    read -p "Enter the maximum display brightness in nits for this model (e.g., 250, 300): " max_nits

    # Prompt user for the desired brightness in nits (must be at least 90 nits)
    read -p "Enter the desired display brightness in nits (must be at least 90 nits): " user_brightness

    # Verify if the entered brightness is a number and greater than 90 nits
    if ! [[ "$user_brightness" =~ ^[0-9]+$ ]] || [ "$user_brightness" -lt 90 ]; then
        echo "Invalid input. Setting brightness to at least 90 nits."
        user_brightness=90
    fi

    # Calculate the brightness value to set in sysfs based on the user's input and max brightness
    target_brightness=$(echo "$user_brightness * $max_brightness / $max_nits" | bc -l)

    # Emulate ceiling to always round up
    # Check if the value is a whole number, if not, round up
    target_brightness_ceiling=$(echo "($target_brightness+0.999)/1" | bc)

    # Ensure the target brightness is at least 1 (to avoid setting it to 0)
    if [ "$target_brightness_ceiling" -lt 1 ]; then
        target_brightness_ceiling=1
    fi

    # Set the backlight value to the calculated target
    echo "Setting backlight brightness to value: $target_brightness_ceiling"
    echo $target_brightness_ceiling | sudo tee $brightness_file

else
    echo "System is not a laptop. Skipping brightness adjustment."
fi

# Update and install packages
until $APT_COMMAND update; do
    sleep 10
done
$APT_COMMAND -y full-upgrade
reboot

