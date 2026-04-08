alias ll='ls -alh'

alias r-fw='systemctl reboot --firmware-setup'

alias pts='phoronix'

apt_command() {
    if command -v apt-proxy &>/dev/null; then
        apt-proxy "$@"
    else
        sudo apt "$@"
    fi
}

mkcd ()
{
  mkdir -p -- "$1" && cd -P -- "$1"
}

full-upgrade() {
    set -euo pipefail

    local path_to_add="$HOME/.local/bin"
    local tmp_update tmp_upgrade
    local cache_base="/var/cache/apt-cacher-ng"

    purge_badsig_cacher_entries() {
        # Parse $1 (update log) for Err-lines paired with BADSIG, compute cache paths,
        # and delete InRelease* on the remote apt-cacher-ng via SSH.
        local log_file="$1"
        local ssh_user="${SSH_USER:-}"
        local ssh_ip="${SSH_IP:-}"
        local dry="${DRY_RUN:-0}"

        # Collect Err lines (with URL + SUITE) that are followed (nearby) by a BADSIG note.
        # We buffer the last Err:* line and emit it if/when we see a BADSIG line.
        mapfile -t err_lines < <(
            awk '
                /^Err:.*https?:\/\// { last_err=$0; next }
                /BADSIG/ && length(last_err)>0 { print last_err; last_err="" }
            ' "$log_file"
        )

        [ "${#err_lines[@]}" -gt 0 ] || return 0  # Nothing to purge.

        if [ -z "$ssh_user" ] || [ -z "$ssh_ip" ]; then
            echo "→ Detected BADSIG, but SSH_USER/SSH_IP not set; skipping remote purge." >&2
            return 0
        fi

        echo "→ Detected BADSIG on the following apt sources (will purge InRelease* on cache):"
        printf '%s\n' "${err_lines[@]}"

        # Extract "<url> <suite>" pairs from each Err line.
        # Example line:
        #   Err:10 http://apt.pop-os.org/ubuntu noble-security InRelease
        local url suite host rest remote_glob
        for line in "${err_lines[@]}"; do
            read -r url suite < <(sed -E 's/^Err:[^ ]+ ([^ ]+) ([^ ]+) InRelease.*/\1 \2/' <<<"$line")

            # URL split into host and remainder path
            # url example: http://apt.pop-os.org/ubuntu
            host="$(awk -F/ '{print $3}' <<<"$url")"
            rest="$(cut -d/ -f4- <<<"$url")"   # "ubuntu" or "ubuntu/<more>"

            # Build the apt-cacher-ng cache glob for InRelease*
            remote_glob="$cache_base/$host/$rest/dists/$suite/InRelease*"

            if [ "${dry}" = "1" ]; then
                echo "DRY-RUN → ssh ${ssh_user}@${ssh_ip} \"sudo rm -rvf '$remote_glob'\""
            else
                echo "→ Purging remote cache: $remote_glob"
                ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
                    "${ssh_user}@${ssh_ip}" \
                    "sudo rm -rvf '$remote_glob' || true"
            fi
        done
    }

    # ─────────────────────────────────────────────────────────────────────
    # 1) Ensure ~/.local/bin is in PATH (and in shell rc files)
    # ─────────────────────────────────────────────────────────────────────
    if ! echo ":$PATH:" | grep -q ":$path_to_add:"; then
        echo "$path_to_add is not in PATH"
        # bashrc
        if ! grep -q "PATH=$path_to_add" "$HOME/.bashrc"; then
            echo "PATH=$path_to_add:\$PATH" >> "$HOME/.bashrc"
        fi
        # zshrc
        if [ -e "$HOME/.zshrc" ] && ! grep -q "PATH=$path_to_add" "$HOME/.zshrc"; then
            echo "PATH=$path_to_add:\$PATH" >> "$HOME/.zshrc"
        fi
        export PATH="$path_to_add:$PATH"
    fi

    # ─────────────────────────────────────────────────────────────────────
    # 2) Loop on `apt update` until it succeeds; if BADSIG seen, purge cache then retry
    # ─────────────────────────────────────────────────────────────────────
    tmp_update="$(mktemp)"
    while true; do
        # Force C locale so the parser sees canonical "Err:" and "BADSIG"
        LC_ALL=C apt_command update 2>&1 | tee "$tmp_update"
        update_rc=$?

        # If BADSIG occurred, nuke InRelease* for those repos on the cache and retry.
        if grep -q "BADSIG" "$tmp_update"; then
            purge_badsig_cacher_entries "$tmp_update"
            echo "→ Retrying apt update after purging apt-cacher-ng entries…"
            continue
        fi

        if [ $update_rc -eq 0 ]; then
            break
        fi

        if grep -q "dpkg was interrupted" "$tmp_update"; then
            echo "→ Detected interrupted dpkg during update; running 'sudo dpkg --configure -a'…"
            sudo dpkg --configure -a
            continue
        fi

        echo "→ apt update failed for another reason; retrying in 1s…"
        sleep 1
    done
    rm -f "$tmp_update"

    # ─────────────────────────────────────────────────────────────────────
    # 3) Loop on `apt full-upgrade` until it succeeds (auto-fixing dpkg)
    # ─────────────────────────────────────────────────────────────────────
    tmp_upgrade="$(mktemp)"
    while true; do
        apt_command full-upgrade -y --allow-downgrades 2>&1 | tee "$tmp_upgrade"
        upgrade_rc=$?

        if [ $upgrade_rc -eq 0 ]; then
            break
        fi

        if grep -q "dpkg was interrupted" "$tmp_upgrade"; then
            echo "→ Detected interrupted dpkg during full-upgrade; running 'sudo dpkg --configure -a'…"
            sudo dpkg --configure -a
            continue
        fi

        echo "→ full-upgrade failed for another reason; aborting."
        rm -f "$tmp_upgrade"
        return 1
    done
    rm -f "$tmp_upgrade"

    # ─────────────────────────────────────────────────────────────────────
    # 4) Autoremove and then prompt if reboot is needed
    # ─────────────────────────────────────────────────────────────────────
    apt_command autoremove -y

    ./check-needrestart.sh
    if [ $? -eq 0 ]; then
        printf "A reboot is recommended. Reboot now? [y/N] "
        read -r answer
        case "$answer" in
            [Yy]|[Yy][Ee][Ss])
                echo "Rebooting…"
                systemctl reboot -i
                ;;
            *)
                echo "Skipping reboot. Remember to reboot later if necessary."
                ;;
        esac
    fi
    set +euo pipefail
}

speed-test ()
{
    RESPONSE=$(curl -I -s --connect-timeout 10 -o /dev/null -w "%{http_code}" "http://10.17.89.69:5000/download/llvm-project-main.zip")
    URL="https://speed.cloudflare.com"
    if [ "$RESPONSE" -eq 200 ]; then
        URL="http://10.17.89.69:3000?Run"
    fi
    firefox $URL &>/dev/null &
}

cpuperf ()
{
    ./install.sh linux-tools-common linux-tools-generic
    if [[ "$(cat /etc/os-release)" == *"Ubuntu"* ]];
    then
        ./install.sh linux-tools-$(uname -r)
    fi
    sudo cpupower frequency-set -g performance
}

phoronix ()
{
    ./install.sh git php-cli php-xml
    if ! command -v phoronix-test-suite &>/dev/null
    then
        pushd ~/Documents
            git clone https://github.com/phoronix-test-suite/phoronix-test-suite.git
            pushd phoronix-test-suite
                sudo bash install-sh
            popd
        popd
        phoronix-test-suite --help &>/dev/null
        if [ -d ~/work-scripts ];
        then
            pushd ~/work-scripts
                cp -Rvf phoronix/compress-pbzip2-1.7.0 ~/.phoronix-test-suite/test-profiles/local/
                cp -Rvf phoronix/batman-knight-1.1.0 ~/.phoronix-test-suite/test-profiles/local/
                cp -Rvf phoronix/batman-origins-1.6.2 ~/.phoronix-test-suite/test-profiles/local/
                cp -Rvf phoronix/cyberpunk2077-1.0.2 ~/.phoronix-test-suite/test-profiles/local/
                cp -Rvf phoronix/l4d2-1.0.2 ~/.phoronix-test-suite/test-profiles/local/
                cp -Rvf phoronix/hitman3-1.0.2 ~/.phoronix-test-suite/test-profiles/local/
                cp -Rvf phoronix/fio-custom ~/.phoronix-test-suite/test-suites/local/
                cp -Rvf phoronix/cpu-medium ~/.phoronix-test-suite/test-suites/local/
                cp -Rvf phoronix/some-games ~/.phoronix-test-suite/test-suites/local/
                cp -Rvf phoronix/workstation-gpus ~/.phoronix-test-suite/test-suites/local/
            popd
        fi
    fi
    gset_apply_test
    phoronix-test-suite $@
}

pts-cpu ()
{
    PTS_TEST='cpu-medium'
    if [ $# -gt 0 ]; then
        PTS_TEST=$1
    fi
    ./install.sh libelf-dev texinfo
    sudo sh -c 'echo 1 > /proc/sys/kernel/perf_event_paranoid'
    cpuperf
    export TEST_TIMEOUT_AFTER=30
    export WATCHDOG_SENSOR=cpu.temp
    export WATCHDOG_SENSOR_THRESHOLD=90
    export LINUX_PERF="power/energy-cores/,power/energy-pkg/"
    export MONITOR=cpu.freq,cpu.temp,cpu.power,cpu.usage
    export PTS_MODULES=system_monitor,linux_perf,test_timeout,watchdog
    pts benchmark $PTS_TEST
}

pts-unigine ()
{
    cpuperf
    export TEST_TIMEOUT_AFTER=auto
    export MONITOR=gpu.freq,gpu.temp,gpu.power,gpu.usage,gpu.memory-usage,gpu.fan-speed
    export PTS_MODULES=system_monitor,test_timeout
    pts benchmark unigine
}

pts-gpu ()
{
    cpuperf
    export TEST_TIMEOUT_AFTER=60
    export MONITOR=gpu.freq,gpu.temp,gpu.power,gpu.usage,gpu.memory-usage,gpu.fan-speed
    export PTS_MODULES=system_monitor,test_timeout
    pts benchmark $1
}

pts-fio ()
{
    cpuperf
    export TEST_TIMEOUT_AFTER=auto
    export MONITOR=hdd.read-speed,hdd.write-speed,hdd.temp
    export WATCHDOG_SENSOR=hdd.temp
    export WATCHDOG_SENSOR_THRESHOLD=75
    export PTS_MODULES=system_monitor,watchdog,test_timeout
    pts benchmark fio-custom
}

fah ()
{
    if [ -e temp ];
    then
        rm -rvf temp
    fi
    if [ ! -e fahclient_7.4.4_amd64.deb ];
    then
        wget https://download.foldingathome.org/releases/public/release/fahclient/debian-testing-64bit/v7.4/fahclient_7.4.4_amd64.deb -O temp
        mv temp fahclient_7.4.4_amd64.deb
    fi
    sudo dpkg -i --force-depends fahclient_7.4.4_amd64.deb
    reboot
}

r-fah ()
{
    sudo dpkg -P fahclient
    reboot
}

pop-get ()
{
    if [ ! -d ~/pop ];
    then
        ./install.sh curl git
        pushd ~/
            git clone https://github.com/pop-os/pop.git
        popd
    fi
}

pop-apt ()
{
    pop-get
    ~/pop/scripts/apt add $@
}

pop-remote ()
{
    pop-get
    ~/pop/scripts/apt remote
}

pop-local ()
{
    pop-get
    ~/pop/scripts/apt local
}

pop-remove ()
{
    pop-get
    ~/pop/scripts/apt remove $@
}

gfp ()
{
    git fetch --all
    git pull --rebase
}

gfpr ()
{
    git reset --hard HEAD
    git restore .
    git fetch --all
    git pull --rebase
}

gfps ()
{
    git stash
    git reset --hard HEAD
    git restore .
    git fetch --all
    git pull --rebase
    git stash pop
}

mst ()
{
    if [ ! -e /tmp/count ];
    then
        echo "1" > /tmp/count
        echo "Suspend Number: 1"
    else
        scount=$(cat /tmp/count)
        scount=$((scount + 1))
        echo "Suspend number: $scount"
        if [ $scount -lt 20 ];
        then
            echo $scount > /tmp/count
        else
            rm -f /tmp/count
        fi
    fi
    systemctl suspend -i
}

# ===================== gset_helpers.sh =====================
# GNOME gsettings + COSMIC cosmic-idle helpers (session-gated: never both on one call).

# Pick a default state path that isn't tool-specific.
_gset_default_state_path() {
  local base="${XDG_CACHE_HOME:-$HOME/.cache}"
  echo "${GSET_STATE_FILE:-$base/gsettings.state}"
}

# True when the active graphical session is COSMIC (Pop COSMIC, etc.).
_session_is_cosmic() {
  [ "${XDG_SESSION_DESKTOP:-}" = COSMIC ] && return 0
  case ":${XDG_CURRENT_DESKTOP:-}:" in
    *:COSMIC:*) return 0 ;;
  esac
  return 1
}

# True when we should touch GNOME power/session gsettings (not COSMIC, gsettings present).
_session_uses_gnome_gsettings() {
  _session_is_cosmic && return 1
  command -v gsettings >/dev/null 2>&1 || return 1
  return 0
}

# Save current values of keys to $1 (or default). If file already exists, do nothing
# unless FORCE=1 (env or arg 2). Optional custom keys via array or newline list in $3.
gset_save() {
  local state_file="${1:-$(_gset_default_state_path)}"
  local FORCE="${2:-${FORCE:-0}}"
  local -a keys

  if [ -n "${3:-}" ]; then
    # If caller passed a newline-separated list, convert to array
    # shellcheck disable=SC2206
    keys=(${3})
  else
    # Default keys we commonly toggle for unattended tests
    keys=(
      "org.gnome.desktop.session idle-delay"
      "org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type"
      "org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type"
      "org.gnome.settings-daemon.plugins.power idle-dim"
      "org.gnome.desktop.screensaver idle-activation-enabled"
      "org.gnome.desktop.screensaver lock-enabled"
      "org.gnome.desktop.screensaver ubuntu-lock-on-suspend"
      "org.gnome.desktop.lockdown disable-lock-screen"
      "org.gnome.desktop.screensaver lock-delay"
      "org.gnome.desktop.screensaver lock-on-suspend"
    )
  fi

  if _session_uses_gnome_gsettings; then
    # Don't clobber an existing GNOME state unless forced.
    if [ ! -f "$state_file" ] || [ "$FORCE" = "1" ]; then
      mkdir -p "$(dirname "$state_file")"

      # Atomic write: capture to temp then move.
      local tmp
      tmp="$(mktemp "${state_file}.XXXXXX")" || return 1
      : > "$tmp"

      for k in "${keys[@]}"; do
        # Format: "schema key:::value"
        # ${k% *} => schema ; ${k##* } => key
        echo "$k:::$(gsettings get ${k% *} ${k##* })" >> "$tmp" || true
      done

      mv -f "$tmp" "$state_file"
    fi
  fi

  cosmic_idle_save
}

# Apply a "no idle/no lock/no auto-suspend" test profile for the current session only.
# Purely modifies; does not save anything.
gset_apply_test() {
  if _session_uses_gnome_gsettings; then
    # Disable idle timeout and auto-suspend
    gsettings set org.gnome.desktop.session idle-delay 0 || true
    gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing' || true
    gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type 'nothing' || true
    gsettings set org.gnome.settings-daemon.plugins.power idle-dim false || true

    # Disable lock screen completely
    gsettings set org.gnome.desktop.screensaver idle-activation-enabled false || true
    gsettings set org.gnome.desktop.screensaver lock-enabled false || true
    gsettings set org.gnome.desktop.screensaver ubuntu-lock-on-suspend false || true

    # Additional settings to prevent lock on resume
    gsettings set org.gnome.desktop.lockdown disable-lock-screen true || true
    gsettings set org.gnome.desktop.screensaver lock-delay 0 || true

    # Disable automatic screen lock
    gsettings set org.gnome.desktop.screensaver lock-on-suspend false || true
  fi
  cosmic_idle_apply_test
}

# Restore from $1 (or default). GNOME state file only applies on GNOME-ish sessions;
# cosmic-idle backup only on COSMIC.
gset_restore() {
  local state_file="${1:-$(_gset_default_state_path)}"
  if _session_uses_gnome_gsettings && [ -f "$state_file" ]; then
    # shellcheck disable=SC2162
    while IFS= read -r line; do
      # Expect "schema key:::value"
      local left="${line%%:::*}"
      local val="${line#*:::}"
      local schema="${left% *}"
      local key="${left##* }"
      gsettings set "$schema" "$key" "$val" || true
    done < "$state_file"
  fi
  cosmic_idle_restore
}

# Optional convenience: restore and delete saved state for the current session type only.
gset_restore_and_clear() {
  local state_file="${1:-$(_gset_default_state_path)}"
  gset_restore "$state_file"
  if _session_uses_gnome_gsettings; then
    rm -f "$state_file" 2>/dev/null || true
  fi
  if _session_is_cosmic; then
    rm -rf "$(_cosmic_idle_state_dir)" 2>/dev/null || true
  fi
}

# COSMIC cosmic-idle (screen off / suspend timers). Values are RON Option<u64> ms; "None" disables.
# Backup directory: COSMIC_IDLE_STATE_BACKUP, else DRAIN_BAT_COSMIC_IDLE_STATE, else ~/.cache/cosmic-idle-v1.bak
_cosmic_idle_v1_dir() {
  echo "${XDG_CONFIG_HOME:-$HOME/.config}/cosmic/com.system76.CosmicIdle/v1"
}

_cosmic_idle_state_dir() {
  local base="${XDG_CACHE_HOME:-$HOME/.cache}"
  echo "${COSMIC_IDLE_STATE_BACKUP:-${DRAIN_BAT_COSMIC_IDLE_STATE:-$base/cosmic-idle-v1.bak}}"
}

cosmic_idle_active() { command -v cosmic-idle >/dev/null 2>&1; }

# Save CosmicIdle v1 keys to backup dir. Skips if backup exists unless FORCE=1 or arg 2 is 1.
cosmic_idle_save() {
  cosmic_idle_active || return 0
  _session_is_cosmic || return 0
  local dest="${1:-$(_cosmic_idle_state_dir)}"
  local FORCE="${2:-${FORCE:-0}}"
  local v1
  v1="$(_cosmic_idle_v1_dir)"
  [ -d "$v1" ] || return 0
  if [ -f "$dest/.saved" ] && [ "$FORCE" != "1" ]; then
    return 0
  fi
  mkdir -p "$dest"
  local f
  for f in screen_off_time suspend_on_battery_time suspend_on_ac_time; do
    if [ -f "$v1/$f" ]; then
      cp -a "$v1/$f" "$dest/$f"
    fi
  done
  : >"$dest/.saved"
}

cosmic_idle_apply_test() {
  cosmic_idle_active || return 0
  _session_is_cosmic || return 0
  local v1
  v1="$(_cosmic_idle_v1_dir)"
  mkdir -p "$v1"
  printf '%s\n' None >"$v1/screen_off_time"
  printf '%s\n' None >"$v1/suspend_on_battery_time"
  printf '%s\n' None >"$v1/suspend_on_ac_time"
}

cosmic_idle_restore() {
  cosmic_idle_active || return 0
  _session_is_cosmic || return 0
  local dest="${1:-$(_cosmic_idle_state_dir)}"
  [ -d "$dest" ] || return 0
  local v1
  v1="$(_cosmic_idle_v1_dir)"
  mkdir -p "$v1"
  local f
  for f in screen_off_time suspend_on_battery_time suspend_on_ac_time; do
    if [ -f "$dest/$f" ]; then
      cp -a "$dest/$f" "$v1/$f"
    fi
  done
}

cosmic_idle_restore_and_clear() {
  local dest="${1:-$(_cosmic_idle_state_dir)}"
  cosmic_idle_restore "$dest"
  rm -rf "$dest" 2>/dev/null || true
}
# =================== end gset_helpers.sh ===================

# Enable greetd autologin into COSMIC via /etc/greetd/cosmic-greeter.toml
# Optional: cosmic_autologin [command] [user]  (defaults: start-cosmic, $USER)
cosmic_autologin () {
  local GREETD_TOML="/etc/greetd/cosmic-greeter.toml"
  local wl_cmd="${1:-start-cosmic}"
  local wl_user="${2:-${USER:-root}}"
  local tmp

  sudo mkdir -p "$(dirname "$GREETD_TOML")"

  if sudo test -f "$GREETD_TOML" && ! sudo test -f "${GREETD_TOML}.bak"; then
    sudo cp -a "$GREETD_TOML" "${GREETD_TOML}.bak"
  fi

  if sudo test -f "$GREETD_TOML"; then
    tmp="$(mktemp)"
    sudo awk '
      /^\[initial_session\]/ { drop=1; next }
      /^\[/ { drop=0 }
      !drop { print }
    ' "$GREETD_TOML" >"$tmp" || { rm -f "$tmp"; return 1; }
    sudo install -m 0644 -o root -g root "$tmp" "$GREETD_TOML"
    rm -f "$tmp"
  fi

  printf '\n[initial_session]\ncommand = "%s"\nuser = "%s"\n' "$wl_cmd" "$wl_user" \
    | sudo tee -a "$GREETD_TOML" >/dev/null
  sudo chmod 0644 "$GREETD_TOML" 2>/dev/null || true
}

# Remove [initial_session] from cosmic-greeter.toml; restore from ${GREETD_TOML}.bak if present.
cosmic_autologin_disable () {
  local GREETD_TOML="/etc/greetd/cosmic-greeter.toml"
  local tmp

  sudo test -f "$GREETD_TOML" || return 0

  if sudo test -f "${GREETD_TOML}.bak"; then
    sudo cp -a "${GREETD_TOML}.bak" "$GREETD_TOML"
    return 0
  fi

  tmp="$(mktemp)"
  sudo awk '
    /^\[initial_session\]/ { drop=1; next }
    /^\[/ { drop=0 }
    !drop { print }
  ' "$GREETD_TOML" >"$tmp" || { rm -f "$tmp"; return 1; }
  sudo install -m 0644 -o root -g root "$tmp" "$GREETD_TOML"
  rm -f "$tmp"
}

autologin_enable () {
  if declare -f _session_is_cosmic >/dev/null 2>&1 && _session_is_cosmic; then
    cosmic_autologin
    return 0
  fi

  # --- Enable Autologin (GDM; sed-based) ---
  # Locate the GDM configuration file.
  local GDM_CONF=""
  if [ -f /etc/gdm3/custom.conf ]; then
      GDM_CONF="/etc/gdm3/custom.conf"
      sudo cp $GDM_CONF "${GDM_CONF}.bak"
  elif [ -f /etc/gdm/custom.conf ]; then
      GDM_CONF="/etc/gdm/custom.conf"
      sudo cp $GDM_CONF "${GDM_CONF}.bak"
  else
      echo "GDM configuration file not found. Autologin not enabled."
      GDM_CONF=""
  fi

  # Ensure $USERNAME exists even under 'set -u'
  local USERNAME="${USERNAME:-$USER}"

  if [ -n "$GDM_CONF" ]; then
      # Check if AutomaticLoginEnable is already set to true.
      if ! grep -qE "^\s*AutomaticLoginEnable\s*=\s*true" "$GDM_CONF"; then
          echo "Enabling autologin (AutomaticLoginEnable)..."
          sudo sed -i 's/^\s*#\?\s*AutomaticLoginEnable\s*=.*/AutomaticLoginEnable = true/' "$GDM_CONF"
      fi

      # Check if AutomaticLogin is set to the current username.
      if ! grep -qE "^\s*AutomaticLogin\s*=\s*$USERNAME" "$GDM_CONF"; then
          echo "Setting autologin user to $USERNAME..."
          sudo sed -i 's/^\s*#\?\s*AutomaticLogin\s*=.*/AutomaticLogin = '"$USERNAME"'/' "$GDM_CONF"
      fi
  fi
}

autologin_disable () {
  if declare -f _session_is_cosmic >/dev/null 2>&1 && _session_is_cosmic; then
    cosmic_autologin_disable
    return 0
  fi

  local GDM_CONF=""
  local GDM_CONF_BAK=""
  if [ -f /etc/gdm3/custom.conf ]; then
      GDM_CONF="/etc/gdm3/custom.conf"
  elif [ -f /etc/gdm/custom.conf ]; then
      GDM_CONF="/etc/gdm/custom.conf"
  else
      return 0
  fi

  if [ -f "${GDM_CONF}.bak" ]; then
      GDM_CONF_BAK="${GDM_CONF}.bak"
  fi

  if [ -n "$GDM_CONF_BAK" ]; then
      sudo mv $GDM_CONF_BAK $GDM_CONF
  else
      # Flip enable=false; comment out the user line (keeps prior value visible)
      sudo sed -i 's/^\s*#\?\s*AutomaticLoginEnable\s*=.*/AutomaticLoginEnable = false/' "$GDM_CONF"
      sudo sed -i 's/^\(\s*\)#\?\s*AutomaticLogin\s*=.*/\1# AutomaticLogin =/' "$GDM_CONF"
  fi
}

# ---------- rtc + suspend helper ----------
suspend_with_rtc () {
  local secs="${1:-930}"  # default ~15.5m
  # program alarm in UTC; don’t attempt to enter suspend here
  sudo rtcwake -m no -u -s "$secs" || {
    echo "[suspend_with_rtc] failed to program RTC alarm" >&2
    return 1
  }
  systemctl suspend -i
}

# ---------- main drain-bat function (stress 10m → rebuild → stress-until-threshold) ----------
drain-bat () {
  # Constants/defaults
  readonly CHARGE_THRESHOLD="${CHARGE_THRESHOLD:-20}"
  readonly SUDOERS_FILE="/etc/sudoers.d/drain-bat-rtcwake"
  readonly HS100_CACHE_DIR="$HOME/.cache/drain-bat"
  readonly HS100_CACHE_FILE="$HS100_CACHE_DIR/hs100_ip"
  readonly AUTOSTART_DIR="$HOME/.config/autostart"
  readonly AUTOSTART_DESKTOP="$AUTOSTART_DIR/drain-bat-autostart.desktop"
  readonly AUTOSTART_SCRIPT="$HOME/.local/bin/drain-bat-autostart.sh"
  readonly DRAIN_BAT_STATE_FILE="$HS100_CACHE_DIR/drain-bat.state"
  readonly DRAIN_BAT_B_FLAG_FILE="$HS100_CACHE_DIR/drain-bat-b.flag"
  readonly DRAIN_BAT_RUNLOG="$HS100_CACHE_DIR/drain-bat.runlog"
  readonly DRAIN_BAT_SUSPEND_MARKER="$HS100_CACHE_DIR/drain-bat.suspend-started"
  readonly DRAIN_BAT_POST_WAKE_SCRIPT="$HS100_CACHE_DIR/drain-bat-post-wake-once.sh"

  _log() { printf '[drain-bat] %s\n' "$*" >&2; }
  ensure_dirs() { mkdir -p "$HS100_CACHE_DIR" "$(dirname "$AUTOSTART_SCRIPT")" "$AUTOSTART_DIR"; }

  _drain_bat_mark() {
    ensure_dirs
    local ts
    ts="$(date -Iseconds 2>/dev/null || date)"
    _log "$*"
    printf '%s %s\n' "$ts" "$*" >>"$DRAIN_BAT_RUNLOG"
  }

  _drain_bat_state_get() {
    [ -f "$DRAIN_BAT_STATE_FILE" ] || return 0
    head -n1 "$DRAIN_BAT_STATE_FILE" | tr -d '\r\n' || true
  }

  _drain_bat_state_set() {
    ensure_dirs
    printf '%s\n' "$1" >"$DRAIN_BAT_STATE_FILE"
    printf '%s drain-bat state → %s\n' "$(date -Iseconds 2>/dev/null || date)" "$1" >>"$DRAIN_BAT_RUNLOG"
  }

  _drain_bat_b_flags_write() {
    ensure_dirs
    printf 'STRESS10_STARTED=%s\nSTRESS10_DONE=%s\nBUILD_STARTED=%s\nLONG_STRESS_STARTED=%s\n' \
      "$1" "$2" "$3" "$4" >"$DRAIN_BAT_B_FLAG_FILE"
  }

  _drain_bat_b_flags_load() {
    STRESS10_STARTED=0
    STRESS10_DONE=0
    BUILD_STARTED=0
    LONG_STRESS_STARTED=0
    [ -f "$DRAIN_BAT_B_FLAG_FILE" ] || return 0
    # shellcheck source=/dev/null
    . "$DRAIN_BAT_B_FLAG_FILE"
  }

  _drain_bat_clear_run_files() {
    rm -f "$DRAIN_BAT_STATE_FILE" "$DRAIN_BAT_B_FLAG_FILE" 2>/dev/null || true
    rm -f "$DRAIN_BAT_SUSPEND_MARKER" "$DRAIN_BAT_POST_WAKE_SCRIPT" 2>/dev/null || true
    _drain_bat_remove_bashrc_wake_hook
  }

  _drain_bat_remove_bashrc_wake_hook() {
    local brc="$HOME/.bashrc"
    [ -f "$brc" ] || return 0
    sed -i '/# DRAIN_BAT_WAKE_HOOK_BEGIN/,/# DRAIN_BAT_WAKE_HOOK_END/d' "$brc" 2>/dev/null || true
  }

  _drain_bat_bashrc_install_wake_hook() {
    local brc="$HOME/.bashrc"
    [ -f "$brc" ] || touch "$brc"
    grep -qF 'DRAIN_BAT_WAKE_HOOK_BEGIN' "$brc" 2>/dev/null && return 0
    ensure_dirs
    {
      echo ''
      echo '# DRAIN_BAT_WAKE_HOOK_BEGIN (managed by drain-bat Phase B.0)'
      echo '[ -x "${XDG_CACHE_HOME:-$HOME/.cache}/drain-bat/drain-bat-post-wake-once.sh" ] && bash "${XDG_CACHE_HOME:-$HOME/.cache}/drain-bat/drain-bat-post-wake-once.sh" || true'
      echo '# DRAIN_BAT_WAKE_HOOK_END'
    } >>"$brc"
  }

  _drain_bat_write_post_wake_script() {
    ensure_dirs
    cat > "$DRAIN_BAT_POST_WAKE_SCRIPT" <<'EOS'
#!/usr/bin/env bash
# Advance B0→B1 only if we have proof the RTC suspend/wake cycle ran (avoids skipping suspend if we crash before suspend).
_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/drain-bat"
_STATE="$_CACHE/drain-bat.state"
_MARKER="$_CACHE/drain-bat.suspend-started"
[ -f "$_STATE" ] || exit 0
_cur="$(head -n1 "$_STATE" | tr -d '\r\n' || true)"
if [ "$_cur" != "B0" ]; then
  rm -f "$0"
  exit 0
fi
[ -f "$_MARKER" ] || exit 0
_since="$(tr -d '\r\n' < "$_MARKER" || true)"
[ -n "$_since" ] || exit 0
if ! command -v journalctl >/dev/null 2>&1; then
  exit 0
fi
if ! journalctl -b 0 --no-pager -q --since="$_since" 2>/dev/null | grep -qE 'systemd-sleep\[[0-9]+\]: System resumed|PM: suspend exit'; then
  exit 0
fi
_RUNLOG="$_CACHE/drain-bat.runlog"
_FLAG="$_CACHE/drain-bat-b.flag"
printf 'B1\n' >"$_STATE"
printf '%s drain-bat state → B1 (post-wake one-shot)\n' "$(date -Iseconds 2>/dev/null || date)" >>"$_RUNLOG"
printf 'STRESS10_STARTED=0\nSTRESS10_DONE=0\nBUILD_STARTED=0\nLONG_STRESS_STARTED=0\n' >"$_FLAG"
rm -f "$_MARKER"
_BRC="$HOME/.bashrc"
[ -f "$_BRC" ] && sed -i '/# DRAIN_BAT_WAKE_HOOK_BEGIN/,/# DRAIN_BAT_WAKE_HOOK_END/d' "$_BRC" 2>/dev/null || true
rm -f "$0"
exit 0
EOS
    chmod +x "$DRAIN_BAT_POST_WAKE_SCRIPT"
  }

  _drain_bat_clear_wake_artifacts() {
    rm -f "$DRAIN_BAT_SUSPEND_MARKER" 2>/dev/null || true
    rm -f "$DRAIN_BAT_POST_WAKE_SCRIPT" 2>/dev/null || true
    _drain_bat_remove_bashrc_wake_hook
  }

  _drain_bat_journal_shows_wake_after_suspend_marker() {
    local since
    [ -f "$DRAIN_BAT_SUSPEND_MARKER" ] || return 1
    since="$(tr -d '\r\n' < "$DRAIN_BAT_SUSPEND_MARKER" || true)"
    [ -n "$since" ] || return 1
    command -v journalctl >/dev/null 2>&1 || return 1
    journalctl -b 0 --no-pager -q --since="$since" 2>/dev/null | grep -qE 'systemd-sleep\[[0-9]+\]: System resumed|PM: suspend exit' && return 0
    return 1
  }

  # A4 + mtime before kernel boot time ⇒ state from before last reboot ⇒ safe to auto-enter Phase B.
  _drain_bat_state_mtime() {
    stat -c %Y "$DRAIN_BAT_STATE_FILE" 2>/dev/null || echo 0
  }
  _drain_bat_boot_time() {
    awk '/^btime / {print $2; exit}' /proc/stat 2>/dev/null || true
  }
  _drain_bat_a4_is_post_reboot() {
    local sm bt
    sm="$(_drain_bat_state_mtime)"
    bt="$(_drain_bat_boot_time)"
    [ -z "$bt" ] && return 0
    [ -n "$sm" ] && [ "$sm" -lt "$bt" ]
  }

  ensure_sudoers() {
    if [ ! -f "$SUDOERS_FILE" ]; then
      _log "Creating sudoers entry for rtcwake…"
      sudo sh -c "printf '%s ALL=(root) NOPASSWD: /usr/sbin/rtcwake\n' \"$(whoami)\" > '$SUDOERS_FILE'"
      sudo chmod 0440 "$SUDOERS_FILE"
    fi
  }
  remove_sudoers_if_present() { [ -f "$SUDOERS_FILE" ] && sudo rm -f "$SUDOERS_FILE" || true; }

  ensure_hs100_repo() { [ -d hs100 ] || git clone https://github.com/branning/hs100.git; }
  discover_hs100_ip() {
    local ip="${1:-}"; [ -n "$ip" ] && { echo "$ip"; return; }
    command -v nmap >/dev/null 2>&1 || ./install.sh nmap || true
    ensure_hs100_repo
    ./hs100/hs100.sh discover 2>&1 | sed -n 's/.*HS100 plugs found: \([0-9.]*\).*/\1/p' | head -n1
  }
  battery_status()   { tr -d '\r\n' < /sys/class/power_supply/BAT0/status 2>/dev/null || echo "Unknown"; }
  battery_capacity() { tr -d '\r\n' < /sys/class/power_supply/BAT0/capacity 2>/dev/null || echo "0";      }

  # After --reset: normalize SOC — if >79% and not full, stress down to ≤79% then charge to 100%; if already full, skip.
  _drain_bat_battery_full_p() {
    local c s
    c="$(battery_capacity)"
    s="$(battery_status)"
    case "$s" in Full|full) return 0 ;; esac
    [ "${c:-0}" -ge 100 ] 2>/dev/null && return 0
    return 1
  }
  # Before reset pre-drain: HS100 must be off (or user unplugs); do not start stress until status is Discharging.
  _drain_bat_reset_ensure_discharging() {
    local w=0
    if [ "$SMART_PLUG" -eq 1 ]; then
      _drain_bat_mark "reset precondition: HS100 off — cutting charger path before drain"
      ./hs100/hs100.sh -i "$HS100_IP" off || true
      sleep 15
      while [ "$w" -lt 120 ]; do
        [ "$(battery_status)" = "Discharging" ] && return 0
        w=$((w + 1))
        [ $((w % 10)) -eq 0 ] && ./hs100/hs100.sh -i "$HS100_IP" off || true
        sleep 2
      done
      _log "reset precondition: still not Discharging (~4m) after HS100 off — check IP, outlet, and laptop AC"
      return 1
    fi
    _log "reset precondition: no HS100 — unplug the laptop charger now (waiting for Discharging)"
    w=0
    while [ "$w" -lt 150 ]; do
      [ "$(battery_status)" = "Discharging" ] && {
        _drain_bat_mark "reset precondition: Discharging (charger unplugged)"
        return 0
      }
      [ $((w % 15)) -eq 0 ] && [ "$w" -gt 0 ] && _log "reset precondition: still waiting for Discharging…"
      w=$((w + 1))
      sleep 2
    done
    _log "reset precondition: timed out waiting for Discharging — unplug AC, then re-run drain-bat --reset"
    return 1
  }
  _drain_bat_reset_precondition() {
    [ -d /sys/class/power_supply/BAT0 ] || { _log "reset precondition: no BAT0; skipping"; return 0; }
    local cap
    cap="$(battery_capacity)"
    case "$cap" in ''|*[!0-9]*) _log "reset precondition: bad capacity '$cap'; skipping"; return 0 ;; esac
    if _drain_bat_battery_full_p; then
      _drain_bat_mark "reset precondition: battery already full; skipping drain/charge"
      return 0
    fi
    local _restart_soc=79
    if [ "$cap" -le "$_restart_soc" ]; then
      _drain_bat_mark "reset precondition: capacity ${cap}% (≤${_restart_soc}%); no pre-drain needed"
      return 0
    fi
    _drain_bat_mark "reset precondition: capacity ${cap}% — stress until ≤${_restart_soc}%, then charge to 100%"
    command -v stress-ng >/dev/null 2>&1 || ./install.sh stress-ng || true
    command -v stress-ng >/dev/null 2>&1 || { _log "stress-ng missing; cannot pre-drain"; return 1; }
    if [ "$SMART_PLUG" -eq 0 ] && [ -f "$HS100_CACHE_FILE" ]; then
      HS100_IP="$(cat "$HS100_CACHE_FILE" 2>/dev/null | tr -d '\r\n' || true)"
      [ -n "$HS100_IP" ] && SMART_PLUG=1
    fi
    if [ "$SMART_PLUG" -eq 0 ]; then
      ensure_hs100_repo
      HS100_IP="$(discover_hs100_ip "")" || true
      [ -n "$HS100_IP" ] && SMART_PLUG=1
    else
      ensure_hs100_repo
      HS100_IP="$(discover_hs100_ip "$HS100_IP")"
    fi
    _drain_bat_reset_ensure_discharging || return 1
    # Stress runs in a separate terminal; this shell only polls sysfs (same idea as Phase B stress10 / stress-until).
    _drain_bat_mark "reset precondition: stress-ng in another window — watching capacity until ≤${_restart_soc}%"
    $(bash ./terminal.sh --name=drain-bat-pre --title=drain-bat-pre) bash -lc 'stress-ng -c 0' &
    local _nodis=0 _st _last_print_cap=""
    while [ -d /sys/class/power_supply/BAT0 ]; do
      cap="$(battery_capacity)"
      _st="$(battery_status)"
      case "$cap" in ''|*[!0-9]*) sleep 2; continue ;; esac
      [ "$cap" -le "$_restart_soc" ] && break
      if [ "$cap" != "$_last_print_cap" ]; then
        _last_print_cap="$cap"
        _log "reset precondition: battery ${cap}% (${_st}), target ≤${_restart_soc}%"
      fi
      if [ "$_st" != "Discharging" ]; then
        _nodis=$((_nodis + 1))
        [ "$_nodis" -ge 24 ] && {
          _log "reset precondition: not discharging ~2m while above ${_restart_soc}% — cut AC or HS100 off"
          _nodis=0
        }
      else
        _nodis=0
      fi
      sleep 5
    done
    pkill -x stress-ng >/dev/null 2>&1 || true
    _drain_bat_mark "reset precondition: drained to ${cap}% (target ≤${_restart_soc}%)"
    if [ "$SMART_PLUG" -eq 1 ]; then
      ./hs100/hs100.sh -i "$HS100_IP" on || true
      _drain_bat_mark "reset precondition: charging to 100%…"
      local _last_chg_print=""
      while [ -d /sys/class/power_supply/BAT0 ]; do
        if _drain_bat_battery_full_p; then
          _drain_bat_mark "reset precondition: charge complete"
          break
        fi
        cap="$(battery_capacity)"
        _st="$(battery_status)"
        case "$cap" in ''|*[!0-9]*) ;; *)
          if [ "$cap" != "$_last_chg_print" ]; then
            _last_chg_print="$cap"
            _log "reset precondition: charging ${cap}% (${_st})…"
          fi
        esac
        sleep 10
      done
    else
      _log "reset precondition: no HS100 IP — plug in AC manually and wait for 100%, then re-run drain-bat --reset if needed"
    fi
    return 0
  }

  # pop-os/linux uses master_<VERSION_CODENAME> only; there is no plain master branch.
  _linux_origin_default_branch() {
    git ls-remote --symref origin HEAD 2>/dev/null | sed -n 's/^ref: refs\/heads\/\([^[:space:]]*\).*/\1/p' | head -n1
  }

  ensure_linux_repo() {
    local BRANCH="$1"
    if [ -d linux ]; then
      ( cd linux && git fetch --all --prune
        if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
          git checkout "$BRANCH" || true
          git pull --ff-only || true
        else
          if git ls-remote --heads origin "$BRANCH" | grep -q "$BRANCH"; then
            git checkout -b "$BRANCH" "origin/$BRANCH" || true
          else
            def="$(_linux_origin_default_branch)"
            if [ -n "$def" ] && git ls-remote --heads origin "$def" | grep -q "$def"; then
              if git show-ref --verify --quiet "refs/heads/$def" 2>/dev/null; then
                git checkout "$def" || true
              else
                git checkout -b "$def" "origin/$def" || true
              fi
              git pull --ff-only || true
            fi
          fi
        fi )
    else
      git clone --branch "$BRANCH" --single-branch --depth 1 https://github.com/pop-os/linux.git \
      || git clone --depth 1 https://github.com/pop-os/linux.git linux
    fi
  }

  write_autostart () {
    local ip="$1"
    ensure_dirs
    [ -n "$ip" ] && echo "$ip" > "$HS100_CACHE_FILE" || true
    cat > "$AUTOSTART_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# After reboot, autostart runs without a TTY; open the session-appropriate terminal (COSMIC vs GNOME).
if [ -z "${DRAIN_BAT_TTY_WRAPPER:-}" ]; then
  export DRAIN_BAT_TTY_WRAPPER=1
  _me="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || realpath "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
  _qme="$(printf '%q' "$_me")"
  case "${XDG_SESSION_DESKTOP:-}" in
    COSMIC)
      if command -v cosmic-term >/dev/null 2>&1; then
        exec cosmic-term bash -c "export DRAIN_BAT_TTY_WRAPPER=1; exec $_qme"
      fi
      ;;
  esac
  if command -v gnome-terminal >/dev/null 2>&1; then
    exec gnome-terminal -- bash -c "export DRAIN_BAT_TTY_WRAPPER=1; exec $_qme"
  fi
  if command -v xterm >/dev/null 2>&1; then
    exec xterm -e bash -c "export DRAIN_BAT_TTY_WRAPPER=1; exec $_qme"
  fi
fi
AUTOSTART_DESKTOP="$HOME/.config/autostart/drain-bat-autostart.desktop"
[ -f "$AUTOSTART_DESKTOP" ] && rm -f "$AUTOSTART_DESKTOP"
# If Phase B.0 suspend killed the session before B1 was written, advance state before drain-bat.
_DRAIN_WAKE="${XDG_CACHE_HOME:-$HOME/.cache}/drain-bat/drain-bat-post-wake-once.sh"
[ -x "$_DRAIN_WAKE" ] && bash "$_DRAIN_WAKE" || true
HS100_CACHE_FILE="$HOME/.cache/drain-bat/hs100_ip"
HS100_IP=""
[ -f "$HS100_CACHE_FILE" ] && HS100_IP="$(cat "$HS100_CACHE_FILE" || true)"
if [ -f "$HOME/.bash_aliases" ]; then
  if [ -n "${HS100_IP}" ]; then
    bash -ic 'source "$HOME/.bash_aliases"; drain-bat "$HS100_IP"'
  else
    bash -ic 'source "$HOME/.bash_aliases"; drain-bat'
  fi
else
  if [ -n "${HS100_IP}" ]; then
    bash -lc 'drain-bat "$HS100_IP"'
  else
    bash -lc 'drain-bat'
  fi
fi
EOF
    chmod +x "$AUTOSTART_SCRIPT"
    cat > "$AUTOSTART_DESKTOP" <<EOF
[Desktop Entry]
Type=Application
Exec=$AUTOSTART_SCRIPT
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
Name=AutoStart-drain-bat
Comment=Resume drain-bat tests after reboot
EOF
    chmod +x "$AUTOSTART_DESKTOP"
    sync
  }

  # Args: drain-bat [--reset] [hs100_ip]. --reset clears state, optional pre-drain >79%→≤79% then charge to 100% unless already full.
  local RESET=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --reset) RESET=1; shift ;;
      *)       break ;;
    esac
  done
  local SMART_PLUG=0 HS100_IP=""
  if [ $# -ge 1 ] && [ -n "${1:-}" ]; then
    SMART_PLUG=1
    HS100_IP="$1"
  fi

  ensure_dirs
  local _a_state
  _a_state="$(_drain_bat_state_get)"
  if [ "$RESET" -eq 1 ]; then
    _drain_bat_clear_run_files
    _a_state=""
    _drain_bat_mark "reset: cleared drain-bat.state and drain-bat-b.flag (forced restart)"
  fi

  # ---------------- Phase B: B0/B1 or A4 after a real reboot (auto-resume) ----------------
  run_phase_b() {
    local _b_state
    _b_state="$(_drain_bat_state_get)"
    case "$_b_state" in
      A1|A2|A3)
        _log "State $_b_state is pre-reboot Phase A. Run drain-bat (same host) to continue setup, or drain-bat --reset."
        return 1
        ;;
      A4)
        _drain_bat_state_set B0
        _drain_bat_mark "Phase A→B: A4→B0 (auto-resume)"
        _b_state=B0
        ;;
    esac

    if [ "$_b_state" = "B0" ]; then
      # Session often dies right after resume; recover B1 via post-wake script, journal, or fresh suspend.
      if [ -x "$DRAIN_BAT_POST_WAKE_SCRIPT" ]; then
        bash "$DRAIN_BAT_POST_WAKE_SCRIPT" || true
        _b_state="$(_drain_bat_state_get)"
      fi
      if [ "$_b_state" = "B0" ] && _drain_bat_journal_shows_wake_after_suspend_marker; then
        _drain_bat_mark "Phase B.0 recover: journal shows wake after suspend marker → B1"
        _drain_bat_state_set B1
        _drain_bat_b_flags_write 0 0 0 0
        _drain_bat_clear_wake_artifacts
        _b_state=B1
      fi
      if [ "$_b_state" = "B0" ]; then
        _drain_bat_mark "Phase B.0 start: RTC suspend/wake (post-wake hook + .bashrc guard installed)"
        date -Iseconds >"$DRAIN_BAT_SUSPEND_MARKER"
        _drain_bat_write_post_wake_script
        _drain_bat_bashrc_install_wake_hook
        sync
        sleep 10
        suspend_with_rtc 930
        sleep 5
        _drain_bat_state_set B1
        _drain_bat_b_flags_write 0 0 0 0
        _drain_bat_mark "Phase B.0 done → B1"
        _drain_bat_clear_wake_artifacts
        _b_state=B1
      fi
    fi

    if [ "$_b_state" != "B1" ]; then
      _log "Phase B: unsupported state '$_b_state' (expected B0 or B1). Try drain-bat --reset."
      return 1
    fi

    local STRESS10_STARTED=0
    local STRESS10_DONE=0
    local BUILD_STARTED=0
    local LONG_STRESS_STARTED=0
    _drain_bat_b_flags_load
    _drain_bat_mark "Phase B.1: main loop (resume flags STRESS10_STARTED=$STRESS10_STARTED STRESS10_DONE=$STRESS10_DONE BUILD_STARTED=$BUILD_STARTED LONG_STRESS_STARTED=$LONG_STRESS_STARTED)"

    # Hydrate plug IP if cached
    [ -z "${HS100_IP:-}" ] && [ -f "$HS100_CACHE_FILE" ] && { HS100_IP="$(cat "$HS100_CACHE_FILE" || true)"; [ -n "$HS100_IP" ] && SMART_PLUG=1; }

    local LAST_PRINTED_CHARGE=""

    while [ -d /sys/class/power_supply/BAT0 ]; do
      local STATUS="$(battery_status)"
      local CHARGE="$(battery_capacity)"

      if [ "$CHARGE" -le "$CHARGE_THRESHOLD" ] || [ "$STATUS" != "Discharging" ]; then
        if [ "$CHARGE" -le "$CHARGE_THRESHOLD" ] && [ "$SMART_PLUG" -eq 1 ]; then
          ./hs100/hs100.sh -i "$HS100_IP" on || true
          [ -f "$HS100_CACHE_FILE" ] && rm -f "$HS100_CACHE_FILE" || true
        fi
        pkill -x stress-ng >/dev/null 2>&1 || true

        if command -v xdotool >/dev/null 2>&1; then
          local T W WINS
          for T in kernel-rebuild stress10 stress-until; do
            WINS=$(xdotool search --name "$T" 2>/dev/null || true)
            if [ -n "$WINS" ]; then
              for W in $WINS; do
                xdotool windowclose "$W" >/dev/null 2>&1 || xdotool windowkill "$W" >/dev/null 2>&1 || true
              done
              sleep 2
            fi
          done
        fi

        if pgrep -f rebuild.sh >/dev/null 2>&1; then
          pkill -f rebuild.sh >/dev/null 2>&1 || true
          sleep 1
          pkill -KILL -f rebuild.sh >/dev/null 2>&1 || true
        fi
        pkill -TERM -x make >/dev/null 2>&1 || true
        sleep 1
        pkill -KILL -x make >/dev/null 2>&1 || true
      fi

      if [ "$STATUS" = "Discharging" ] && [ "$CHARGE" -gt "$CHARGE_THRESHOLD" ]; then

        if [ "$STRESS10_DONE" -eq 0 ]; then
          if [ "$STRESS10_STARTED" -eq 0 ]; then
            STRESS10_STARTED=1
            $(bash ./terminal.sh --name=stress10 --title=stress10) \
              bash -lc 'stress-ng -c 0 --timeout 600s' &
          fi
          sleep 1
          if ! pgrep -f "stress-ng -c 0" >/dev/null 2>&1; then
            STRESS10_DONE=1
          fi

        elif [ "$BUILD_STARTED" -eq 0 ] && [ "$STRESS10_DONE" -eq 1 ]; then
          BUILD_STARTED=1
          _drain_bat_mark "Phase B: kernel rebuild in separate window (non-blocking); watch stops build if charge ≤${CHARGE_THRESHOLD}% or not discharging"
          $(bash ./terminal.sh --name=kernel-rebuild --title=kernel-rebuild) \
            bash -lc 'cd "$OLDPWD/linux" 2>/dev/null || cd "./linux"; ./rebuild.sh' &

        else
          if ! pgrep -f "rebuild.sh" >/dev/null 2>&1 && ! pgrep -f "make .* -C" >/dev/null 2>&1; then
            if [ "$LONG_STRESS_STARTED" -eq 0 ] && ! pgrep -x stress-ng >/dev/null 2>&1; then
              LONG_STRESS_STARTED=1
              $(bash ./terminal.sh --name=stress-until --title=stress-until-threshold) \
                bash -lc 'stress-ng -c 0' &
            fi
          fi
        fi
      fi

      case "$CHARGE" in ''|*[!0-9]*) ;; *)
        if [ "$CHARGE" != "$LAST_PRINTED_CHARGE" ]; then
          LAST_PRINTED_CHARGE="$CHARGE"
          echo "$CHARGE"
        fi
      esac

      if [ "${CHARGE:-0}" -ge 100 ]; then
        _drain_bat_mark "COMPLETE: battery full → cleanup (sudoers, autologin, gset/cosmic restore)"
        remove_sudoers_if_present
        autologin_disable
        gset_restore_and_clear
        _drain_bat_clear_run_files
        break
      fi

      _drain_bat_b_flags_write "$STRESS10_STARTED" "$STRESS10_DONE" "$BUILD_STARTED" "$LONG_STRESS_STARTED"

      sleep 1
    done
  }

  case "$_a_state" in
    B0|B1)
      run_phase_b
      return $?
      ;;
    A4)
      if _drain_bat_a4_is_post_reboot; then
        _drain_bat_state_set B0
        _drain_bat_mark "Phase A→B: A4→B0 (auto-resume after reboot)"
        run_phase_b
        return $?
      fi
      _drain_bat_mark "Phase A complete (A4): reboot required; autostart will run drain-bat after boot."
      return 0
      ;;
  esac

  if [ "$RESET" -eq 1 ]; then
    _drain_bat_reset_precondition || return $?
  fi

  # ---------------- Phase A: pre-reboot (resumable via ~/.cache/drain-bat/drain-bat.state) ----------------
  if [ -z "$_a_state" ]; then
      _drain_bat_mark "Phase A.1 start: gset + autologin + sudoers"
      gset_save
      gset_apply_test
      autologin_enable
      ensure_sudoers
      _drain_bat_state_set A1
      _drain_bat_mark "Phase A.1 done → A1"
      _a_state=A1
    fi

    if [ "$_a_state" = "A1" ]; then
      _drain_bat_mark "Phase A.2 start: install packages"
      ./install.sh -b linux-system76 || true
      ./install.sh devscripts debhelper || true
      ./install.sh stress-ng xdotool || true
      _drain_bat_state_set A2
      _drain_bat_mark "Phase A.2 done → A2"
      _a_state=A2
    fi

    if [ "$_a_state" = "A2" ]; then
      _drain_bat_mark "Phase A.3 start: linux repo"
      local BRANCH
      local _vco
      _vco=$(. /etc/os-release 2>/dev/null; printf '%s' "${VERSION_CODENAME:-}")
      if [ -z "$_vco" ]; then
        _log "VERSION_CODENAME missing from /etc/os-release; cannot resolve linux branch master_<release>."
        return 1
      fi
      BRANCH="master_${_vco}"
      ensure_linux_repo "$BRANCH"
      _drain_bat_state_set A3
      _drain_bat_mark "Phase A.3 done → A3"
      _a_state=A3
    fi

    if [ "$_a_state" = "A3" ]; then
      _drain_bat_mark "Phase A.4 start: HS100 + autostart + reboot"
      ensure_hs100_repo
      if [ "$SMART_PLUG" -eq 0 ]; then
        HS100_IP="$(discover_hs100_ip "")"; [ -n "$HS100_IP" ] && SMART_PLUG=1
      else
        HS100_IP="$(discover_hs100_ip "$HS100_IP")"
      fi
      [ "$SMART_PLUG" -eq 1 ] && [ "$(battery_status)" != "Discharging" ] && {
        ./hs100/hs100.sh -i "$HS100_IP" off || true; sleep 15; }

      write_autostart "$HS100_IP"
      _drain_bat_state_set A4
      _drain_bat_mark "Phase A.4 done → A4; rebooting for Phase B"
      sync
      systemctl reboot -i
      return 0
    fi

  _log "Phase A: unexpected state '$_a_state' (use drain-bat --reset to clear)."
  return 1
}

mem-speed ()
{
    sudo dmidecode --type 17 | grep -i speed
}

pang12-stress ()
{
    gset_apply_test
    ./install.sh stress-ng glmark2
    read -r -a _tp_stress < <(bash ./terminal.sh --name=stress-ng --title=stress-ng)
    "${_tp_stress[@]}" bash -c "while true; do stress-ng -c 0 -m 0 --vm-bytes 25G; done"
    read -r -a _tp_glm < <(bash ./terminal.sh --name=glmark2 --title=glmark2)
    "${_tp_glm[@]}" bash -c "glmark2 --run-forever"
    read -r -a _tp_j < <(bash ./terminal.sh --name=journalctl --title=journalctl)
    "${_tp_j[@]}" bash -c "sudo journalctl -f | grep mce"
    echo "" >> timestamp.txt
    echo "new test run" >> timestamp.txt
    while true
    do
        date >> timestamp.txt
        sleep 60
        date
    done
}

build-stress ()
{
    gset_apply_test
    ./install.sh curl build-essential libncurses5-dev fakeroot xz-utils libelf-dev bison flex dwarves unzip libssl-dev
    pushd build
        sudo rm -rvf linux*
        if [ ! -e master.zip ];
        then
            wget https://github.com/pop-os/linux/archive/refs/heads/master.zip
        fi
        unzip -q master.zip linux-master/* -d temp
        mkdir linux
        mv temp/linux-master/* linux/
        rm -rvf temp
        if [ ! -d firmware-open ]; then
            git clone https://github.com/system76/firmware-open.git
        fi
        pushd firmware-open
            git reset --hard HEAD
            git fetch --all
            git pull --rebase
            git submodule update --init --recursive --checkout
            bash scripts/install-deps.sh
            . edk2/edksetup.sh
            curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs > rustup.sh
            chmod +x rustup.sh
            bash rustup.sh -y --default-toolchain=nightly
            source "$HOME/.cargo/env"
        popd
        pushd linux
            make mrproper
            git reset --hard HEAD
            git restore .
            make ARCH=x86_64 allmodconfig
            if [ -e linux.orig ];
            then
                rm -rf linux.orig
            fi
            make -j`nproc` ARCH=x86_64 2> errors.log
        popd
        pushd firmware-open
            bash scripts/build.sh oryp10
        popd
    popd
}

kdiskmark ()
{
    if ! command -v flatpak &>/dev/null
    then
        ./install.sh flatpak
        flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
    fi
    if [ ! -d "${HOME}/.local/share/flatpak/app/io.github.jonmagon.kdiskmark" ];
    then
        flatpak install -y flathub io.github.jonmagon.kdiskmark
    fi
    /usr/bin/flatpak run --branch=stable --arch=x86_64 --command=kdiskmark io.github.jonmagon.kdiskmark
}

soundrec ()
{
    if ! command -v flatpak &>/dev/null
    then
        ./install.sh flatpak
        flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
    fi
    if [ ! -d "${HOME}/.local/share/flatpak/app/org.gnome.SoundRecorder" ];
    then
        flatpak install -y flathub org.gnome.SoundRecorder
    fi
    /usr/bin/flatpak run --branch=stable --arch=x86_64 --command=gnome-sound-recorder org.gnome.SoundRecorder
}

kvmtpm ()
{
    KVM="False"
    TPM="False"
    if [ -e /dev/kvm ];
    then
        KVM="True"
    fi
    if [ -d /sys/class/tpm/tpm0 ];
    then
        TPM="True"
    fi
    echo "KVM: ${KVM}"
    echo "TPM: ${TPM}"
}

dmi ()
{
    sudo echo "BIOS Information"
    sudo dmidecode --type 0 | grep -e Vendor -e Version -e Date
    echo "System Information"
    sudo dmidecode --type 1 | grep -e Manufacturer -e 'Product Name' -e Version
    echo "Base Board Information"
    sudo dmidecode --type 2 | grep -e Manufacturer -e 'Product Name' -e Version
    echo "Chassis Information"
    sudo dmidecode --type 3 | grep -e Manufacturer -e Type -e Version
}

check_pkfail ()
{
    ./install.sh efitools
    if [ $(efi-readvar -v PK | grep -c "DO NOT TRUST\|DO NOT SHIP") -gt 0 ]; then
        echo "Vulnerable to PKFail, needs patching."
    else
        echo "PKFail not found."
    fi
}
