#!/bin/bash

# Script to detect GNOME session failures and system freezes during suspend testing
# Designed to work with update_test.sh using two-phase approach
# 
# Uses rtcwake to set wake timer and systemctl suspend for automated testing
# Sets up sudoers for passwordless rtcwake and systemctl suspend execution (persists across reboots)
# Disables screen lock and auto-suspend for uninterrupted testing
# Detects two types of failures:
# 1. GNOME session death/shell crash during suspend (detected via journal session recreation events)
# 2. System freeze requiring SysRQ reboot (detected via journal analysis)
# 
# Returns PASSED only if neither failure mode is detected

set -e

# Configuration
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
STATE_DIR="$HOME/.config/suspend_test"
LOG_FILE="$STATE_DIR/suspend_test.log"
SUSPEND_DURATION=30       # seconds to suspend before auto-wake

# Marker files for two-phase approach
FIRST_RUN_MARKER="$HOME/.suspend_gnome_test.marker"
PASS_MARKER="$HOME/suspend_gnome_pass.marker"
FAIL_MARKER="$HOME/suspend_gnome_fail.marker"
SHELL_CRASH_MARKER="$HOME/.suspend_gnome_shell_crash.marker"

# Create state directory
mkdir -p "$STATE_DIR"

# Logging function
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Function to set up sudoers for rtcwake
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

# Function to set up autostart for shell crash recovery
setup_shell_crash_recovery() {
    log_message "Setting up autostart for shell crash recovery..."
    
    # Create autostart entry to restart script if shell crashes
    AUTOSTART_FILE="$HOME/.config/autostart/suspend-gnome-test-recovery.desktop"
    cat << EOF > "$AUTOSTART_FILE"
[Desktop Entry]
Type=Application
Exec=$(realpath "$0")
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
Name=Suspend GNOME Test Recovery
Comment=Restart suspend test after shell crash
EOF
    
    log_message "Autostart recovery entry created"
}

# Function to check for SysRQ reboot in journal (indicates freeze)
check_for_sysrq_reboot() {
    log_message "Checking journal for SysRQ reboot events..."
    
    # Get the current boot ID
    CURRENT_BOOT_ID=$(cat /proc/sys/kernel/random/boot_id)
    
    # Check for SysRQ reboot events in the previous boot
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

# Function to check if GNOME session was recreated after suspend
check_gnome_session_recreated() {
    log_message "Checking journal for GNOME session recreation events since suspend..."
    
    # Look for GNOME session events (session recreation)
    if journalctl --since "5 minutes ago" | grep -iE "(gnome-session.*started|gnome-session.*launched|gnome.*session.*start)" > /dev/null; then
        log_message "WARNING: GNOME session recreation detected"
        return 1
    fi
    
    # Check for GNOME shell crashes and restarts
    if journalctl --since "5 minutes ago" | grep -iE "(gnome-shell.*crashed|gnome-shell.*restart|gnome.*shell.*died|gnome.*shell.*killed)" > /dev/null; then
        log_message "WARNING: GNOME shell crash/restart detected"
        return 1
    fi
    
    # Check for session manager restarts
    if journalctl --since "5 minutes ago" | grep -iE "(session.*manager.*restart|gnome.*restart)" > /dev/null; then
        log_message "WARNING: Session manager restart detected"
        return 1
    fi
    
    # Check for display manager login events (indicates session recreation)
    if journalctl --since "5 minutes ago" | grep -iE "(gdm.*login|lightdm.*login|display.*login)" > /dev/null; then
        log_message "WARNING: Display manager login detected (session recreated)"
        return 1
    fi
    
    # Check for Wayland session recreation
    if journalctl --since "5 minutes ago" | grep -iE "(wayland.*session.*start|wayland.*session.*restart)" > /dev/null; then
        log_message "WARNING: Wayland session recreation detected"
        return 1
    fi
    
    # Check for X11 session recreation
    if journalctl --since "5 minutes ago" | grep -iE "(x11.*session.*start|x11.*session.*restart)" > /dev/null; then
        log_message "WARNING: X11 session recreation detected"
        return 1
    fi
    
    log_message "No GNOME session recreation events detected"
    return 0
}

# Function to initiate suspend with auto-wake
initiate_suspend() {
    log_message "Initiating system suspend with auto-wake in ${SUSPEND_DURATION} seconds..."
    
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
        if sudo systemctl suspend -i; then
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

# Main execution logic
main() {
    log_message "Starting suspend GNOME failure test script"
    
    # Set up sudoers for rtcwake
    setup_rtcwake_sudoers
    
    # Disable screen lock and auto-suspend for automated testing
    disable_screen_lock
    
    if [[ ! -f "$FIRST_RUN_MARKER" ]]; then
        # ── FIRST RUN ──────────────────────────────────────────────────────────────
        log_message "First run: Setting up suspend test..."
        rm -f "$PASS_MARKER" "$FAIL_MARKER" "$SHELL_CRASH_MARKER"
        touch "$FIRST_RUN_MARKER"
        
        # Set up autostart for shell crash recovery
        setup_shell_crash_recovery
        
        # Check if we're starting after a SysRQ reboot
        if ! check_for_sysrq_reboot; then
            log_message "SysRQ reboot detected at startup, test FAILED"
            touch "$FAIL_MARKER"
            sudo systemctl reboot -i
        fi
        
        # Check if we're in a GNOME session
        if [ -z "$XDG_CURRENT_DESKTOP" ] || [[ "$XDG_CURRENT_DESKTOP" != *"GNOME"* ]]; then
            log_message "ERROR: Not in a GNOME session"
            touch "$FAIL_MARKER"
            sudo systemctl reboot -i
        fi
        
        log_message "GNOME session confirmed active, initiating suspend test..."
        
        # Set up a background monitor for shell crashes during the test
        (
            sleep 5  # Wait for suspend to start
            while true; do
                if ! pgrep -f "gnome-shell" > /dev/null; then
                    log_message "GNOME shell crashed during test"
                    touch "$SHELL_CRASH_MARKER"
                    break
                fi
                sleep 2
            done
        ) &
        MONITOR_PID=$!
        
        # Initiate suspend with auto-wake
        if ! initiate_suspend; then
            log_message "ERROR: Failed to initiate suspend"
            kill $MONITOR_PID 2>/dev/null || true
            touch "$FAIL_MARKER"
            sudo systemctl reboot -i
        fi
        
        # Kill the monitor since suspend completed
        kill $MONITOR_PID 2>/dev/null || true
        
        # If we reach here, suspend completed successfully
        log_message "Suspend test completed, rebooting to check results..."
        sudo systemctl reboot -i
        
    else
        # ── SECOND RUN (after reboot) ──────────────────────────────────────────────
        log_message "Second run: Checking suspend test results..."
        rm -f "$FIRST_RUN_MARKER"
        
        # Check if we're restarting due to shell crash (not normal reboot)
        if [[ -f "$SHELL_CRASH_MARKER" ]]; then
            log_message "Detected shell crash recovery restart"
            rm -f "$SHELL_CRASH_MARKER"
            
            # Check for GNOME session recreation (shell crash detection)
            if ! check_gnome_session_recreated; then
                log_message "GNOME shell crash detected, test FAILED"
                touch "$FAIL_MARKER"
            else
                log_message "No shell crash detected, continuing test..."
                # Restart the first phase
                rm -f "$FIRST_RUN_MARKER"
                exec "$0" "$@"
            fi
        fi
        
        # Check for SysRQ reboot (freeze)
        if ! check_for_sysrq_reboot; then
            log_message "SysRQ reboot detected, test FAILED"
            touch "$FAIL_MARKER"
        fi
        
        # Check for GNOME session recreation
        if ! check_gnome_session_recreated; then
            log_message "GNOME session recreation detected, test FAILED"
            touch "$FAIL_MARKER"
        fi
        
        # Clean up autostart file
        rm -f "$HOME/.config/autostart/suspend-gnome-test-recovery.desktop"
        
        # Determine final result
        if [[ -f "$FAIL_MARKER" ]]; then
            log_message "Test FAILED"
            echo "FAILED"
            rm -f "$PASS_MARKER" "$FAIL_MARKER" "$SHELL_CRASH_MARKER"
            exit 1
        else
            log_message "Test PASSED"
            echo "PASSED"
            rm -f "$PASS_MARKER" "$FAIL_MARKER" "$SHELL_CRASH_MARKER"
            exit 0
        fi
    fi
}

# Run main function
main "$@"