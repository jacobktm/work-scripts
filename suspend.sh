#!/usr/bin/env bash

# Source bash_aliases to ensure functions are available
if [[ -f "$HOME/.bash_aliases" ]]; then
    source "$HOME/.bash_aliases"
fi

# Default values for command line options
min_delay=15
max_delay=30
resume_hook="./resume-hook.sh"
use_rtc=0

# Function to print usage information and exit
usage() {
  echo "Usage: $0 [-m <min_delay>] [-M <max_delay>] [-r <resume_hook_path>] [-R] <n>"
  echo "  -m <min_delay>         Minimum delay between suspend cycles (default: ${min_delay})"
  echo "  -M <max_delay>         Maximum delay between suspend cycles (default: ${max_delay})"
  echo "  -r <resume_hook_path>  Path to the resume hook script (default: ${resume_hook})"
  echo "  -R                     Use RTC method (bypassing rtcwake) for suspend test"
  echo "  <n> is the number of suspend cycles"
  exit 1
}

# Parse command line options
while getopts ":m:M:r:R" opt; do
  case $opt in
    m)
      min_delay="$OPTARG"
      ;;
    M)
      max_delay="$OPTARG"
      ;;
    r)
      resume_hook="$OPTARG"
      ;;
    R)
      use_rtc=1
      ;;
    \?)
      echo "Invalid option: -$OPTARG" >&2
      usage
      ;;
    :)
      echo "Option -$OPTARG requires an argument." >&2
      usage
      ;;
  esac
done

# Remove the parsed options from the positional parameters
shift $((OPTIND - 1))

# Ensure that at least one positional parameter (<n>) remains
if [ $# -lt 1 ]; then
  usage
fi

suspend_count="$1"

# Cleanup previous files if they exist
[ -f ./count ] && rm -rvf ./count
[ -f results.log ] && sudo rm -rvf results.log

# List of packages to install
PKG_LIST=("fwts" "dbus-x11" "gnome-terminal")
./install.sh "${PKG_LIST[@]}"

# Marker file to track if gsettings have been saved
GSETTINGS_MARKER="$HOME/.suspend_gsettings_saved.marker"

# Only save gsettings on first run (if marker doesn't exist)
if [[ ! -f "$GSETTINGS_MARKER" ]]; then
    if declare -f gset_save >/dev/null 2>&1; then
        gset_save
        touch "$GSETTINGS_MARKER"
    fi
fi

if declare -f gset_apply_test >/dev/null 2>&1; then
    gset_apply_test
fi

# Launch a terminal to monitor journal logs
sudo gnome-terminal -- bash -c 'journalctl -f | tee ./sustest_journal | grep -E -f ./sustest_patterns.txt'

if [ "$use_rtc" -eq 1 ]; then
  echo "Using RTC method for suspend test (bypassing rtcwake)..."
  # Run the entire RTC loop in a single sudo shell so that the password isn't requested repeatedly.
  sudo bash <<EOF
suspend_count=${suspend_count}
min_delay=${min_delay}
max_delay=${max_delay}
resume_hook='${resume_hook}'

for (( i=1; i<=suspend_count; i++ )); do
  # Calculate a random delay between min_delay and max_delay (the wait time between cycles)
  range=\$(( max_delay - min_delay + 1 ))
  delay=\$(( RANDOM % range + min_delay ))
  echo "Iteration \$i: Waiting \$delay seconds before suspending..."
  sleep "\$delay"
  
  echo "Clearing previous RTC wakealarm..."
  echo 0 > /sys/class/rtc/rtc0/wakealarm
  
  current_time=\$(date +%s)
  wake_time=\$(( current_time + 35 ))
  echo "Setting RTC wakealarm for \$(date -d @\$wake_time) (timestamp: \$wake_time)..."
  echo \$wake_time > /sys/class/rtc/rtc0/wakealarm
  
  echo "Iteration \$i: Suspending for 30 seconds..."
  systemctl suspend
  
  if [ -x "\$resume_hook" ]; then
    echo "Executing resume hook: \$resume_hook"
    sleep 10
    "\$resume_hook"
  fi
done
EOF
else
  # Use fwts s3 suspend test with the specified parameters.
  sudo fwts s3 --s3-multiple "$suspend_count" \
              --s3-min-delay "$min_delay" \
              --s3-max-delay "$max_delay" \
              --s3-resume-hook "$resume_hook"
fi

# Display suspend statistics
sudo cat /sys/kernel/debug/suspend_stats

if declare -f gset_restore_and_clear >/dev/null 2>&1; then
    gset_restore_and_clear
fi

# Clean up the gsettings marker file
rm -f "$GSETTINGS_MARKER"