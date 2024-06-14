#!/bin/bash

AU="A"
CU="µWh"

battery_device=$(ls /sys/class/power_supply/ | grep -E '^BAT[0-9]')
charge_now="energy_now"
charge_full="energy_full"
if [ -f "/sys/class/power_supply/${battery_device}/charge_now" ]; then
    charge_now="charge_now"
    charge_full="charge_full"
fi 
CF=$(cat "/sys/class/power_supply/${battery_device}/${charge_full}")
CN=$(cat "/sys/class/power_supply/${battery_device}/${charge_now}")
STATUS=$(cat "/sys/class/power_supply/${battery_device}/status")
CAPACITY=$(cat "/sys/class/power_supply/${battery_device}/capacity")
VOLTAGE=$(cat "/sys/class/power_supply/${battery_device}/voltage_now")
if [ -f "/sys/class/power_supply/${battery_device}/power_now" ]; then
    POWER=$(cat "/sys/class/power_supply/${battery_device}/power_now") 
fi
if [ -f "/sys/class/power_supply/${battery_device}/current_now" ]; then
    CURRENT=$(cat "/sys/class/power_supply/${battery_device}/current_now")
fi
if [ ! -f "/sys/class/power_supply/${battery_device}/power_now" ]; then
    POWER=$(echo "(${VOLTAGE} * ${CURRENT}) / 1000000" | bc)
    AU="µA"
    CU="µAh"
fi
if [ ! -f "/sys/class/power_supply/${battery_device}/current_now" ]; then
    CURRENT=$(echo "scale=6; ${POWER} / ${VOLTAGE}" | bc)
fi

echo "          date: $(date)"
echo "    charge_now: ${CN}${CU}"
echo "   charge_full: ${CF}${CU}"
echo "        status: $STATUS"
echo "    percentage: ${CAPACITY}%"
echo "  charge power: ${POWER}µW"
echo "charge voltage: ${VOLTAGE}µV"
echo "charge current: ${CURRENT}${AU}"
