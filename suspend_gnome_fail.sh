#!/bin/bash

# Script to detect GNOME session failures and system freezes during suspend testing
# Designed to work with update_test.sh and maintain state across session deaths
# 
# Uses rtcwake to set wake timer and systemctl suspend for automated testing
# Sets up sudoers for passwordless rtcwake and systemctl suspend execution (persists across reboots)
# Disables screen lock and auto-suspend for uninterrupted testing
# Detects two types of failures:
# 1. GNOME session death during suspend (detected via journal session recreation events)
# 2. System freeze requiring SysRQ reboot (detected via journal analysis)
# 
# Returns PASSED only if neither failure mode is detected

set -e

# Configuration
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
STATE_DIR="$HOME/.config/suspend_test"
STATE_FILE="$STATE_DIR/suspend_test_state"
LOG_FILE="$STATE_DIR/suspend_test.log"
PID_FILE="$STATE_DIR/suspend_test.pid"
SESSION_CHECK_INTERVAL=5  # seconds
SUSPEND_TIMEOUT=60        # seconds to wait for suspend to complete
SUSPEND_DURATION=30       # seconds to suspend before auto-wake

# Create state directory
mkdir -p "$STATE_DIR"

# Function to set up sudoers for rtcwake
# Note: This sudoers file persists across reboots to enable automated testing
setup_rtcwake_sudoers() {
    local username=$(whoami)
    local sudoers_file="/etc/sudoers.d/rtcwake-nopasswd"
    
    if [ ! -f "$sudoers_file" ]; then
        log_message "Setting up sudoers for rtcwake and systemctl suspend..."
        echo "$username ALL=(ALL) NOPASSWD: /usr/sbin/rtcwake, /bin/systemctl suspend" | sudo tee "$sudoers_file" > /dev/null
        sudo chmod 0440 "$sudoers_file"
        log_message "rtcwake and systemctl suspend sudoers file created (persists across reboots)"
    fi
}

# Function to disable screen lock
disable_screen_lock() {
    log_message "Disabling screen lock for automated testing..."
    
    # Disable screen lock
    current_lock=$(gsettings get org.gnome.desktop.screensaver lock-enabled 2>/dev/null || echo "error")
    if [ "$current_lock" != "false" ]; then
        log_message "Disabling screen lock..."
        gsettings set org.gnome.desktop.screensaver lock-enabled false
    fi
    
    # Disable auto suspend on AC
    current_ac=$(gsettings get org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 2>/dev/null || echo "error")
    if [ "$current_ac" != "'nothing'" ]; then
        log_message "Disabling auto suspend on AC..."
        gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing'
    fi
    
    # Disable auto suspend on battery
    current_battery=$(gsettings get org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type 2>/dev/null || echo "error")
    if [ "$current_battery" != "'nothing'" ]; then
        log_message "Disabling auto suspend on battery..."
        gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type 'nothing'
    fi
    
    log_message "Screen lock and auto-suspend disabled"
}

# Logging function
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Function to check if GNOME session was recreated after suspend (indicating old session died)
check_gnome_session_recreated() {
    log_message "Checking journal for GNOME session recreation events since suspend..."
    
    # Get the suspend timestamp from the state file
    SUSPEND_TIME=""
    if [ -f "$STATE_FILE" ]; then
        SUSPEND_TIME=$(grep "SUSPEND_TIME=" "$STATE_FILE" | cut -d'=' -f2)
    fi
    
    # If we have a suspend time, look for session events after that time
    if [ -n "$SUSPEND_TIME" ]; then
        log_message "Looking for session events after suspend time: $SUSPEND_TIME"
        
        # Check for GNOME session events after suspend
        if journalctl --since "$SUSPEND_TIME" | grep -iE "(gnome-session.*started|gnome-session.*launched|gnome.*session.*start)" > /dev/null; then
            log_message "WARNING: GNOME session recreation detected after suspend"
            return 1
        fi
        
        # Check for session manager restarts after suspend
        if journalctl --since "$SUSPEND_TIME" | grep -iE "(session.*manager.*restart|gnome.*restart)" > /dev/null; then
            log_message "WARNING: Session manager restart detected after suspend"
            return 1
        fi
        
        # Check for display manager login events after suspend
        if journalctl --since "$SUSPEND_TIME" | grep -iE "(gdm.*login|lightdm.*login|display.*login)" > /dev/null; then
            log_message "WARNING: Display manager login detected after suspend (session recreated)"
            return 1
        fi
    else
        log_message "No suspend timestamp available, checking recent session events..."
        
        # Look for session events in the last 5 minutes as fallback
        if journalctl --since "5 minutes ago" | grep -iE "(gnome-session.*started|gnome-session.*launched|gnome.*session.*start)" > /dev/null; then
            log_message "WARNING: Recent GNOME session recreation detected"
            return 1
        fi
    fi
    
    log_message "No GNOME session recreation events detected since suspend"
    return 0
}

# Function to check for SysRQ reboot in journal (indicates freeze)
check_for_sysrq_reboot() {
    log_message "Checking journal for SysRQ reboot events..."
    
    # Get the current boot ID
    CURRENT_BOOT_ID=$(cat /proc/sys/kernel/random/boot_id)
    
    # Check for SysRQ reboot events in the previous boot
    # Look for messages about emergency reboot, SysRQ, or kernel panic
    if journalctl --list-boots | grep -q "boot_id"; then
        # Get the previous boot ID
        PREVIOUS_BOOT_ID=$(journalctl --list-boots | tail -n 2 | head -n 1 | awk '{print $1}')
        
        if [ -n "$PREVIOUS_BOOT_ID" ] && [ "$PREVIOUS_BOOT_ID" != "$CURRENT_BOOT_ID" ]; then
            log_message "Checking previous boot ($PREVIOUS_BOOT_ID) for SysRQ events..."
            
            # Check for various SysRQ reboot indicators
            if journalctl -b "$PREVIOUS_BOOT_ID" | grep -iE "(sysrq|emergency.*reboot|kernel.*panic|system.*halted|reboot.*emergency)" > /dev/null; then
                log_message "WARNING: SysRQ reboot detected in previous boot"
                return 1
            fi
            
            # Check for unexpected shutdown/reboot without proper suspend resume
            if journalctl -b "$PREVIOUS_BOOT_ID" | grep -iE "(systemd.*reboot|systemd.*poweroff)" | grep -v "suspend" > /dev/null; then
                # Check if there was a suspend event before the reboot
                if ! journalctl -b "$PREVIOUS_BOOT_ID" | grep -iE "(suspend|sleep)" > /dev/null; then
                    log_message "WARNING: Unexpected reboot without suspend detected"
                    return 1
                fi
            fi
        fi
    fi
    
    # Also check current boot for any immediate SysRQ events
    if journalctl -b 0 | grep -iE "(sysrq|emergency.*reboot|kernel.*panic)" > /dev/null; then
        log_message "WARNING: SysRQ reboot detected in current boot"
        return 1
    fi
    
    log_message "No SysRQ reboot events detected"
    return 0
}

# Function to initiate suspend with auto-wake
initiate_suspend() {
    log_message "Initiating system suspend with auto-wake in ${SUSPEND_DURATION} seconds..."
    
    # Record the exact time when suspend is initiated
    SUSPEND_TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
    echo "SUSPEND_INITIATED" > "$STATE_FILE"
    echo "SUSPEND_TIME=$SUSPEND_TIMESTAMP" >> "$STATE_FILE"
    log_message "Suspend initiated at: $SUSPEND_TIMESTAMP"
    
    # Check if rtcwake is available
    if ! command -v rtcwake >/dev/null 2>&1; then
        log_message "ERROR: rtcwake not found, installing util-linux..."
        sudo apt update && sudo apt install -y util-linux
    fi
    
    # Check if RTC is available
    if ! sudo rtcwake -l >/dev/null 2>&1; then
        log_message "ERROR: RTC not available, cannot set wake alarm"
        return 1
    fi
    
    # Set RTC wake alarm and suspend
    log_message "Setting RTC wake alarm for ${SUSPEND_DURATION} seconds from now..."
    if sudo rtcwake -s "$SUSPEND_DURATION" -m off; then
        log_message "RTC wake alarm set, initiating suspend..."
        # Now actually suspend the system
        if sudo systemctl suspend; then
            log_message "Suspend completed, system should have auto-woken"
        else
            log_message "ERROR: systemctl suspend failed"
            return 1
        fi
    else
        log_message "ERROR: rtcwake failed to set wake alarm"
        return 1
    fi
}

# Function to monitor session during suspend test
monitor_session() {
    log_message "Starting session monitoring..."
    
    # Record initial state
    echo "MONITORING_STARTED" > "$STATE_FILE"
    echo $$ > "$PID_FILE"
    
    # Wait a bit for system to stabilize
    sleep 10
    
    # Check if we're in a GNOME session (basic check for current session)
    if [ -z "$XDG_CURRENT_DESKTOP" ] || [[ "$XDG_CURRENT_DESKTOP" != *"GNOME"* ]]; then
        log_message "ERROR: Not in a GNOME session"
        echo "FAILED" > "$STATE_FILE"
        return 1
    fi
    
    log_message "GNOME session confirmed active, initiating suspend test..."
    
    # Initiate suspend with auto-wake
    if ! initiate_suspend; then
        log_message "ERROR: Failed to initiate suspend"
        echo "FAILED" > "$STATE_FILE"
        return 1
    fi
    
    # System should auto-wake after SUSPEND_DURATION seconds
    # If we reach this point, the system has resumed
    log_message "System has resumed from suspend"
    
    # Check if session was recreated (indicating old session died)
    if check_gnome_session_recreated; then
        log_message "SUCCESS: No GNOME session recreation detected - session survived"
        
        # Also check for SysRQ reboot (freeze) in journal
        if check_for_sysrq_reboot; then
            log_message "SUCCESS: No SysRQ reboot detected - test PASSED"
            echo "PASSED" > "$STATE_FILE"
            return 0
        else
            log_message "FAILURE: SysRQ reboot detected - system froze during suspend"
            echo "FAILED" > "$STATE_FILE"
            return 1
        fi
    else
        log_message "FAILURE: GNOME session recreation detected - session died during suspend"
        echo "FAILED" > "$STATE_FILE"
        return 1
    fi
}

# Function to restart script after session death
restart_after_session_death() {
    log_message "Session died, restarting script..."
    
    # Wait for system to stabilize
    sleep 30
    
    # Check if we can restart (basic GNOME session check)
    if [ -n "$XDG_CURRENT_DESKTOP" ] && [[ "$XDG_CURRENT_DESKTOP" == *"GNOME"* ]]; then
        log_message "New session detected, restarting monitoring..."
        exec "$0" "$@"
    else
        log_message "No session available, will retry on next boot"
        # Schedule restart on next boot
        echo "#!/bin/bash" > /tmp/restart_suspend_test.sh
        echo "sleep 60" >> /tmp/restart_suspend_test.sh
        echo "exec '$0' '$@'" >> /tmp/restart_suspend_test.sh
        chmod +x /tmp/restart_suspend_test.sh
        
        # Add to autostart
        AUTOSTART_FILE="$HOME/.config/autostart/suspend-test-restart.desktop"
        cat << EOF > "$AUTOSTART_FILE"
[Desktop Entry]
Type=Application
Exec=/tmp/restart_suspend_test.sh
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
Name=Suspend Test Restart
Comment=Restart suspend test after session death
EOF
    fi
}

# Function to clean up and reboot
cleanup_and_reboot() {
    log_message "Test completed, cleaning up and rebooting..."
    
    # Remove autostart files
    rm -f "$HOME/.config/autostart/suspend-test-restart.desktop"
    rm -f /tmp/restart_suspend_test.sh
    
    # Remove state files
    rm -f "$STATE_FILE" "$PID_FILE"
    
    # Log final result
    if [ -f "$STATE_FILE" ]; then
        RESULT=$(cat "$STATE_FILE")
        log_message "Final test result: $RESULT"
    fi
    
    # Reboot system
    log_message "Rebooting system in 10 seconds..."
    sleep 10
    sudo reboot
}

# Main execution logic
main() {
    log_message "Starting suspend GNOME failure test script"
    
    # Set up sudoers for rtcwake
    setup_rtcwake_sudoers
    
    # Disable screen lock and auto-suspend for automated testing
    disable_screen_lock
    
    # First, check if we're starting after a SysRQ reboot
    if ! check_for_sysrq_reboot; then
        log_message "SysRQ reboot detected at startup, test FAILED"
        echo "FAILED" > "$STATE_FILE"
        cleanup_and_reboot
        return
    fi
    
    # Check if we're restarting after a session death
    if [ -f "$STATE_FILE" ]; then
        STATE=$(cat "$STATE_FILE")
        case "$STATE" in
            "SUSPEND_INITIATED")
                log_message "Detected restart after suspend, checking session and journal..."
                if check_gnome_session_recreated; then
                    log_message "No session recreation detected, checking for SysRQ reboot..."
                    if check_for_sysrq_reboot; then
                        log_message "No SysRQ reboot detected, test PASSED"
                        echo "PASSED" > "$STATE_FILE"
                    else
                        log_message "SysRQ reboot detected, test FAILED"
                        echo "FAILED" > "$STATE_FILE"
                    fi
                else
                    log_message "Session recreation detected, test FAILED"
                    echo "FAILED" > "$STATE_FILE"
                fi
                cleanup_and_reboot
                ;;
            "MONITORING_STARTED")
                log_message "Detected restart during monitoring, session likely died"
                echo "FAILED" > "$STATE_FILE"
                cleanup_and_reboot
                ;;
            "PASSED"|"FAILED")
                log_message "Test already completed with result: $STATE"
                cleanup_and_reboot
                ;;
        esac
    fi
    
    # Start fresh monitoring
    if monitor_session; then
        log_message "Test completed successfully"
    else
        log_message "Test failed or session died"
        # If we get here, the session likely died
        restart_after_session_death
    fi
    
    cleanup_and_reboot
}

# Handle script termination
trap 'log_message "Script terminated, cleaning up..."; cleanup_and_reboot' EXIT INT TERM

# Run main function
main "$@"