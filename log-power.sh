#!/bin/bash

HS100_ARGS=""

if [ $# -gt 0 ];
then
    HS100_ARGS="-i $1 "
fi

gsettings set org.gnome.desktop.session idle-delay 0 2>/dev/null
gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type "nothing" 2>/dev/null
gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type "nothing" 2>/dev/null

PACKAGES=""
if ! command -v stress-ng &>/dev/null
then
    PACKAGES="stress-ng "
fi
if ! command -v glmark2 &>/dev/null
then
    PACKAGES="${PACKAGES}glmark2 "
fi
if ! command -v bc &>/dev/null
then
    PACKAGES="${PACKAGES}bc "
fi

bash install.sh $PACKAGES
terminal=$(bash terminal.sh)

# Find the battery device (usually named BAT0 or BAT1)
battery_device=$(ls /sys/class/power_supply/ | grep -E '^BAT[0-9]')

# Define the power_now and voltage_now file paths
voltage_min_design_file="/sys/class/power_supply/${battery_device}/voltage_min_design"
power_now_file="/sys/class/power_supply/${battery_device}/power_now"
voltage_now_file="/sys/class/power_supply/${battery_device}/voltage_now"
current_now_file="/sys/class/power_supply/${battery_device}/current_now"
capacity_file="/sys/class/power_supply/${battery_device}/capacity"
status_file="/sys/class/power_supply/${battery_device}/status"
energy_full_file="/sys/class/power_supply/${battery_device}/energy_full"
energy_now_file="/sys/class/power_supply/${battery_device}/energy_now"
charge_full_file="/sys/class/power_supply/${battery_device}/charge_full"
charge_now_file="/sys/class/power_supply/${battery_device}/charge_now"

# Define the target capacities
target_capacities=(99 98 97 96 95 94 93 92 91 90 89 88 87 86 85 84 83 82 81 80 79 78 77 76 75 74 73 72 71 70 69 68 67 66 65 64 63 62 61 60 59 58 57 56 55 54 53 52 51 50 49 48 47 46 45 44 43 42 41 40 39 38 37 36 35 34 33 32 31 30 29 28 27 26 25 24 23 22 21 20 19 18 17 16 15 14 13 12 11 10 9 8 7 6 5 4 3 2 1)

# Check if the required files exist
if [ ! -f "$voltage_now_file" ] || [ ! -f "$capacity_file" ] || [ ! -f "$status_file" ]; then
  echo "Error: Required files not found."
  exit 1
fi

# Define the log file
logfile="battery_test_log.txt"

# Determine whether to use energy or charge files
if [ -f "$charge_full_file" ] && [ -f "$charge_now_file" ] && [ -f "$current_now_file" ]; then
  capacity_full_file="$charge_full_file"
  capacity_now_file="$charge_now_file"
  current_now_file="$current_now_file"
  power_source="current"
else
  capacity_full_file="$energy_full_file"
  capacity_now_file="$energy_now_file"
  current_now_file="$power_now_file"
  power_source="power"
fi

calculate_capacity() {
  input_capacity="$1"
  if [ "$power_source" == "power" ]; then
    echo "$input_capacity"
  else
    voltage_min_design=$(cat "$voltage_min_design_file")
    output_capacity=$(echo "(${input_capacity} * ${voltage_min_design}) / 1000000" | bc)
    echo "$(printf "%.0f" $output_capacity)"
  fi
}

capacity_full=$(calculate_capacity $(cat "$capacity_full_file"))
capacity_now=$(calculate_capacity $(cat "$capacity_now_file"))

# Function to log battery information
log_battery_info() {
  # Read the voltage_now value (in microvolts)
  voltage_now=$(cat "$voltage_now_file")

  # Read the battery status (Charging, Discharging, etc.)
  battery_status=$(cat "$status_file")
  battery_capacity=$(cat "$capacity_file")

  capacity_now=$(calculate_capacity $(cat "$capacity_now_file"))

  # Calculate the current and power
  if [ "$power_source" == "current" ]; then
    cur_now=$(cat "$current_now_file")
    current_now=$(echo "scale=6; $cur_now / 1000000" | bc)
    power_now=$(echo "${current_now} * ${voltage_now}" | bc)
  else
    power_now=$(cat "$current_now_file")
    current_now=$(echo "scale=6; $power_now / $voltage_now" | bc)
  fi

  # Print the current timestamp, battery status, and charging current
  log_line="$(date '+%Y-%m-%d %H:%M:%S') | Status: ${battery_status} | Charging current: ${current_now}A | Charging power: $(printf "%.0f" $power_now)µW | Charging voltage: ${voltage_now}µV | Capacity: ${battery_capacity}% ${capacity_now}µWh/${capacity_full}µWh"
  echo "$log_line" | tee -a "$logfile"
}

echo "Battery charge test log" | tee "$logfile"
echo "Starting battery capacity: $(cat "$capacity_file")% ${capacity_now}µWh/${capacity_full}µWh"

# Main loop
for target_capacity in "${target_capacities[@]}"; do
  echo "Starting test run with target capacity ${target_capacity}%" | tee -a "$logfile"
  bash ./hs100/hs100.sh ${HS100_ARGS}off &>/dev/null

  while true; do
    battery_capacity=$(cat "$capacity_file")
    battery_status=$(cat "$status_file")
    capacity_now=$(calculate_capacity $(cat "$capacity_now_file"))

    if [ "$battery_status" == "Discharging" ] && [ "$battery_capacity" -gt "$target_capacity" ]; then
      echo "Current battery capacity: ${battery_capacity}% ${capacity_now}µWh/${capacity_full}µWh" | tee -a "$logfile"
      if [ $(ps -A | grep -c stress-ng) -eq 0 ]; then
        $terminal bash -c "stress-ng -c 0 -m 0 --vm-bytes 25G" 2>/dev/null &
      fi
      if [ $(ps -A | grep -c glmark2) -eq 0 ]; then
        $terminal bash -c "glmark2 --run-forever" 2>/dev/null &
      fi
    elif [ "$battery_status" == "Discharging" ]; then
      if [ $(ps -A | grep -c stress-ng) -gt 0 ]; then
        pkill stress-ng
      fi
      if [ $(ps -A | grep -c glmark2) -gt 0 ]; then
        pkill glmark2
      fi
      echo "Current battery capacity: ${battery_capacity}% ${capacity_now}µWh/${capacity_full}µWh" | tee -a "$logfile"
      echo "Ready to charge. Please connect the charger." | tee -a "$logfile"
      while [ "$(cat "$status_file")" == "Discharging" ]; do
        bash ./hs100/hs100.sh ${HS100_ARGS}on &>/dev/null
        sleep 1
      done
      break
    fi

    sleep 30
    bash ./hs100/hs100.sh ${HS100_ARGS}off &>/dev/null
  done

  echo "Charging started. Logging battery information..." | tee -a "$logfile"

  zero_count=0
  while [ "$(cat "$status_file")" != "Full" ]; do
    log_battery_info
    sleep 10
    if [ "$power_source" == "power" ];
    then
        test_file="$power_now_file"
      else
        test_file="$current_now_file"
    fi
    if [ "$(cat "$test_file")" -eq 0 ]; then
        zero_count=$((zero_count + 1))
    else
        zero_count=0
    fi
    if [ $zero_count -gt 2 ]; then
        break
    fi
  done

  log_battery_info

  echo "Charging stopped. Ready for the next run." | tee -a "$logfile"
done

echo "All test runs completed." | tee -a "$logfile"
