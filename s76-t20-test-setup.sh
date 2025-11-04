#!/bin/bash

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
    local output_file="t20-eut.txt"
    local json_file="t20-eut.json"
    
    echo "Collecting system information for TEC score calculation..."
    
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
        echo "    \"bios_date\": \"${bios_date}\""
        echo "  },"
        
        # Chassis/Form Factor
        echo "  \"chassis\": {"
        chassis_type=$(sudo dmidecode --type chassis | grep "Type:" | awk '{print $2}')
        local chassis_manufacturer=$(sudo dmidecode --type chassis | grep "Manufacturer:" | cut -d: -f2 | xargs)
        local chassis_version=$(sudo dmidecode --type chassis | grep "Version:" | cut -d: -f2 | xargs)
        local is_notebook="false"
        local system_classification="Desktop"
        if [[ "$chassis_type" == "Notebook" || "$chassis_type" == "Laptop" ]]; then
            is_notebook="true"
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
        echo "    \"type\": \"${chassis_type}\","
        echo "    \"manufacturer\": \"${chassis_manufacturer}\","
        echo "    \"version\": \"${chassis_version}\","
        echo "    \"is_notebook\": ${is_notebook},"
        echo "    \"classification\": \"${system_classification}\""
        echo "  },"
        
        # CPU Information
        echo "  \"cpu\": {"
        local cpu_model=$(grep "model name" /proc/cpuinfo | head -1 | cut -d: -f2 | xargs)
        local cpu_cores=$(nproc)
        local cpu_threads=$(grep -c processor /proc/cpuinfo)
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
                    
                    echo "      {"
                    echo -n "        \"size\": \"${size:-}\""
                    [ -n "$locator" ] && echo "," && echo -n "        \"locator\": \"${locator}\""
                    [ -n "$speed" ] && echo "," && echo -n "        \"speed\": \"${speed}\""
                    [ -n "$type" ] && echo "," && echo -n "        \"type\": \"${type}\""
                    [ -n "$form_factor" ] && echo "," && echo -n "        \"form_factor\": \"${form_factor}\""
                    [ -n "$manufacturer" ] && echo "," && echo -n "        \"manufacturer\": \"${manufacturer}\""
                    [ -n "$part_number" ] && echo "," && echo -n "        \"part_number\": \"${part_number}\""
                    [ -n "$serial_number" ] && echo "," && echo -n "        \"serial_number\": \"${serial_number}\""
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
            
            echo "      {"
            echo -n "        \"size\": \"${size:-}\""
            [ -n "$locator" ] && echo "," && echo -n "        \"locator\": \"${locator}\""
            [ -n "$speed" ] && echo "," && echo -n "        \"speed\": \"${speed}\""
            [ -n "$type" ] && echo "," && echo -n "        \"type\": \"${type}\""
            [ -n "$form_factor" ] && echo "," && echo -n "        \"form_factor\": \"${form_factor}\""
            [ -n "$manufacturer" ] && echo "," && echo -n "        \"manufacturer\": \"${manufacturer}\""
            [ -n "$part_number" ] && echo "," && echo -n "        \"part_number\": \"${part_number}\""
            [ -n "$serial_number" ] && echo "," && echo -n "        \"serial_number\": \"${serial_number}\""
            echo ""
            echo -n "      }"
        fi
        echo ""
        echo "    ],"
        local total_memory=$(free -h | grep "Mem:" | awk '{print $2}')
        echo "    \"total_memory\": \"${total_memory}\""
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
        if [ -n "$battery_device" ]; then
            local battery_path="/sys/class/power_supply/${battery_device}"
            local capacity_full=""
            local capacity_unit=""
            
            if [ -f "${battery_path}/energy_full" ]; then
                capacity_full=$(cat "${battery_path}/energy_full" 2>/dev/null || echo "")
                capacity_unit="Wh"
            elif [ -f "${battery_path}/charge_full" ]; then
                capacity_full=$(cat "${battery_path}/charge_full" 2>/dev/null || echo "")
                capacity_unit="Ah"
            fi
            
            local voltage_min_design=$(cat "${battery_path}/voltage_min_design" 2>/dev/null || echo "")
            local technology=$(cat "${battery_path}/technology" 2>/dev/null || echo "")
            local manufacturer=$(cat "${battery_path}/manufacturer" 2>/dev/null || echo "")
            local model_name=$(cat "${battery_path}/model_name" 2>/dev/null || echo "")
            
            # Calculate capacity in Wh if we have charge in Ah
            if [ -n "$capacity_full" ] && [ -n "$voltage_min_design" ] && [ "$capacity_unit" = "Ah" ]; then
                local capacity_wh=$(echo "scale=2; (${capacity_full} * ${voltage_min_design}) / 1000000" | bc 2>/dev/null || echo "")
                echo "    \"capacity_full_wh\": \"${capacity_wh}\","
                echo "    \"capacity_full_ah\": \"$(echo "scale=2; ${capacity_full} / 1000000" | bc 2>/dev/null || echo "")\","
            elif [ -n "$capacity_full" ] && [ "$capacity_unit" = "Wh" ]; then
                echo "    \"capacity_full_wh\": \"$(echo "scale=2; ${capacity_full} / 1000000" | bc 2>/dev/null || echo "")\","
                echo "    \"capacity_full_ah\": null,"
            else
                echo "    \"capacity_full_wh\": null,"
                echo "    \"capacity_full_ah\": null,"
            fi
            
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
        while IFS= read -r line; do
            if [[ "$line" =~ " connected " ]]; then
                if [ "$first_display" = false ]; then
                    echo ","
                fi
                first_display=false
                local display_name=$(echo "$line" | awk '{print $1}')
                local resolution=$(echo "$line" | grep -oE '[0-9]+x[0-9]+' | head -1)
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
                
                echo "    {"
                echo "      \"name\": \"${display_name}\","
                echo "      \"resolution\": \"${resolution}\","
                echo "      \"width_px\": ${width:-null},"
                echo "      \"height_px\": ${height:-null},"
                echo "      \"megapixels\": ${megapixels:-null},"
                echo "      \"width_mm\": ${width_mm:-null},"
                echo "      \"height_mm\": ${height_mm:-null}"
                echo -n "    }"
            fi
        done <<< "$(xrandr)"
        echo ""
        echo "  ],"
        
        # Network Adapters Information
        echo "  \"network_adapters\": ["
        local first_adapter=true
        for device in $(nmcli device | awk '$2=="ethernet" {print $1}'); do
            if [ "$first_adapter" = false ]; then
                echo ","
            fi
            first_adapter=false
            
            # Get link speed and supported speeds
            local link_speed=""
            local supported_speeds=""
            local current_speed=""
            
            if command -v ethtool &> /dev/null; then
                # Get current link speed
                local ethtool_info=$(ethtool "$device" 2>/dev/null)
                current_speed=$(echo "$ethtool_info" | grep "Speed:" | cut -d: -f2 | xargs || echo "")
                
                # Get supported speeds (from Supported link modes)
                supported_speeds=$(echo "$ethtool_info" | grep -A 1 "Supported link modes:" | tail -1 | xargs || echo "")
                
                # Parse current speed to a standard format (10G, 2.5G, 1G, 100M, etc.)
                if [ -n "$current_speed" ]; then
                    local speed_num=$(echo "$current_speed" | grep -oE '[0-9]+' | head -1)
                    local speed_unit=$(echo "$current_speed" | grep -oE '(Mb/s|Gb/s|Mb/s)' | head -1)
                    if [[ "$speed_unit" =~ "Gb/s" ]]; then
                        link_speed="${speed_num}G"
                    elif [[ "$speed_unit" =~ "Mb/s" ]]; then
                        if [ "$speed_num" -ge 1000 ]; then
                            # Convert to Gb/s
                            link_speed=$(echo "scale=1; ${speed_num} / 1000" | bc | sed 's/\.0$//')"G"
                        else
                            link_speed="${speed_num}M"
                        fi
                    fi
                fi
            fi
            
            # Get EEE status
            local eee_status="unknown"
            local eee_enabled="false"
            local eee_active="false"
            if command -v ethtool &> /dev/null; then
                local eee_info=$(ethtool --show-eee "$device" 2>/dev/null)
                if [ -n "$eee_info" ]; then
                    local eee_enabled_str=$(echo "$eee_info" | grep "EEE status:" | cut -d: -f2 | xargs || echo "")
                    local eee_active_str=$(echo "$eee_info" | grep "Active:" | cut -d: -f2 | xargs || echo "")
                    eee_status="$eee_enabled_str"
                    if [[ "$eee_enabled_str" =~ "enabled" ]]; then
                        eee_enabled="true"
                    fi
                    if [[ "$eee_active_str" =~ "yes" ]] || [[ "$eee_active_str" =~ "active" ]]; then
                        eee_active="true"
                    fi
                else
                    eee_status="not supported"
                fi
            fi
            
            # Get MAC address
            local mac_address=$(cat "/sys/class/net/${device}/address" 2>/dev/null || echo "")
            
            # Get driver information
            local driver=$(ethtool -i "$device" 2>/dev/null | grep "driver:" | cut -d: -f2 | xargs || echo "")
            local driver_version=$(ethtool -i "$device" 2>/dev/null | grep "version:" | cut -d: -f2 | xargs || echo "")
            local firmware_version=$(ethtool -i "$device" 2>/dev/null | grep "firmware-version:" | cut -d: -f2 | xargs || echo "")
            
            # Get vendor and model from PCI information if available
            local vendor_id=""
            local device_id=""
            local vendor_name=""
            if [ -f "/sys/class/net/${device}/device/vendor" ] && [ -f "/sys/class/net/${device}/device/device" ]; then
                vendor_id=$(cat "/sys/class/net/${device}/device/vendor" 2>/dev/null || echo "")
                device_id=$(cat "/sys/class/net/${device}/device/device" 2>/dev/null || echo "")
                # Try to get vendor name from lspci if available
                if command -v lspci &> /dev/null && [ -n "$vendor_id" ] && [ -n "$device_id" ]; then
                    vendor_name=$(lspci -d "${vendor_id}:${device_id}" 2>/dev/null | cut -d: -f3 | cut -d'(' -f1 | xargs || echo "")
                fi
            fi
            
            echo "    {"
            echo -n "      \"name\": \"${device}\""
            [ -n "$mac_address" ] && echo "," && echo -n "      \"mac_address\": \"${mac_address}\""
            [ -n "$current_speed" ] && echo "," && echo -n "      \"current_speed\": \"${current_speed}\""
            [ -n "$link_speed" ] && echo "," && echo -n "      \"link_speed\": \"${link_speed}\""
            [ -n "$supported_speeds" ] && echo "," && echo -n "      \"supported_speeds\": \"${supported_speeds}\""
            echo "," && echo -n "      \"eee_status\": \"${eee_status}\""
            echo "," && echo -n "      \"eee_enabled\": ${eee_enabled}"
            echo "," && echo -n "      \"eee_active\": ${eee_active}"
            [ -n "$driver" ] && echo "," && echo -n "      \"driver\": \"${driver}\""
            [ -n "$driver_version" ] && echo "," && echo -n "      \"driver_version\": \"${driver_version}\""
            [ -n "$firmware_version" ] && echo "," && echo -n "      \"firmware_version\": \"${firmware_version}\""
            [ -n "$vendor_name" ] && echo "," && echo -n "      \"vendor\": \"${vendor_name}\""
            [ -n "$vendor_id" ] && echo "," && echo -n "      \"vendor_id\": \"${vendor_id}\""
            [ -n "$device_id" ] && echo "," && echo -n "      \"device_id\": \"${device_id}\""
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
    
    echo "System information collected and saved to $json_file and $output_file"
    
    # SCP to server
    echo "Attempting to copy file to 10.17.89.69..."
    if command -v scp &> /dev/null; then
        scp "$output_file" "system76@10.17.89.69:~/t20-eut.txt" 2>/dev/null || \
        scp "$output_file" "root@10.17.89.69:~/t20-eut.txt" 2>/dev/null || \
        scp "$json_file" "system76@10.17.89.69:~/t20-eut.txt" 2>/dev/null || \
        scp "$json_file" "root@10.17.89.69:~/t20-eut.txt" 2>/dev/null || \
        echo "Warning: Could not SCP file to 10.17.89.69. Please copy $output_file manually."
    else
        echo "Warning: scp not found. Please copy $output_file to 10.17.89.69 manually."
    fi
}

# Collect system information
collect_tec_info

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
