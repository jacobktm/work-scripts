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
    local path_to_add="$HOME/.local/bin"
    local tmp_update tmp_upgrade

    # ─────────────────────────────────────────────────────────────────────
    # 1) Ensure ~/.local/bin is in PATH (and in shell rc files)
    # ─────────────────────────────────────────────────────────────────────
    if ! echo "$PATH" | grep -q "$path_to_add"; then
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
    # 2) Loop on `apt update` until it succeeds (auto‑fixing dpkg if needed)
    # ─────────────────────────────────────────────────────────────────────
    tmp_update=$(mktemp)
    set -o pipefail
    while true; do
        apt_command update 2>&1 | tee "$tmp_update"
        if [ $? -eq 0 ]; then
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
    # 3) Loop on `apt full-upgrade` until it succeeds (auto‑fixing dpkg)
    # ─────────────────────────────────────────────────────────────────────
    tmp_upgrade=$(mktemp)
    while true; do
        apt_command full-upgrade -y --allow-downgrades 2>&1 | tee "$tmp_upgrade"
        if [ $? -eq 0 ]; then
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
        read answer
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
    set +o pipefail
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
    gsettings set org.gnome.desktop.session idle-delay 0
    gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type "nothing"
    gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type "nothing"
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
# Generic GNOME gsettings helpers (no drain-bat assumptions)

# Pick a default state path that isn't tool-specific.
_gset_default_state_path() {
  local base="${XDG_CACHE_HOME:-$HOME/.cache}"
  echo "${GSET_STATE_FILE:-$base/gsettings.state}"
}

# Save current values of keys to $1 (or default). If file already exists, do nothing
# unless FORCE=1 (env or arg 2). Optional custom keys via array or newline list in $3.
gset_save() {
  command -v gsettings >/dev/null 2>&1 || return 0

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
    )
  fi

  # Don't clobber an existing state unless forced.
  if [ -f "$state_file" ] && [ "$FORCE" != "1" ]; then
    return 0
  fi

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
}

# Apply a "no idle/no lock/no auto-suspend" test profile.
# Purely modifies; does not save anything. No-ops if gsettings missing.
gset_apply_test() {
  command -v gsettings >/dev/null 2>&1 || return 0
  gsettings set org.gnome.desktop.session idle-delay 0 || true
  gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing' || true
  gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type 'nothing' || true
  gsettings set org.gnome.settings-daemon.plugins.power idle-dim false || true
  gsettings set org.gnome.desktop.screensaver idle-activation-enabled false || true
  gsettings set org.gnome.desktop.screensaver lock-enabled false || true
  gsettings set org.gnome.desktop.screensaver ubuntu-lock-on-suspend false || true
}

# Restore from $1 (or default). If the file doesn't exist, do nothing.
gset_restore() {
  command -v gsettings >/dev/null 2>&1 || return 0
  local state_file="${1:-$(_gset_default_state_path)}"
  [ -f "$state_file" ] || return 0

  # shellcheck disable=SC2162
  while IFS= read -r line; do
    # Expect "schema key:::value"
    local left="${line%%:::*}"
    local val="${line#*:::}"
    local schema="${left% *}"
    local key="${left##* }"
    gsettings set "$schema" "$key" "$val" || true
  done < "$state_file"
}

# Optional convenience: restore and delete state to avoid stale restores later.
gset_restore_and_clear() {
  local state_file="${1:-$(_gset_default_state_path)}"
  gset_restore "$state_file"
  rm -f "$state_file" 2>/dev/null || true
}
# =================== end gset_helpers.sh ===================

autologin_enable () {
  # --- Enable Autologin (your sed-based approach) ---
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

  _log() { printf '[drain-bat] %s\n' "$*" >&2; }
  ensure_dirs() { mkdir -p "$HS100_CACHE_DIR" "$(dirname "$AUTOSTART_SCRIPT")" "$AUTOSTART_DIR"; }

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
  battery_status()   { cat /sys/class/power_supply/BAT0/status 2>/dev/null || echo "Unknown"; }
  battery_capacity() { cat /sys/class/power_supply/BAT0/capacity 2>/dev/null || echo "0";      }

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
            git checkout master || true
            git pull --ff-only || true
          fi
        fi )
    else
      git clone --branch "$BRANCH" --single-branch --depth 1 https://github.com/pop-os/linux.git \
      || git clone --depth 1 https://github.com/pop-os/linux.git
    fi
  }

  write_autostart () {
    local ip="$1"
    ensure_dirs
    [ -n "$ip" ] && echo "$ip" > "$HS100_CACHE_FILE" || true
    cat > "$AUTOSTART_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
AUTOSTART_DESKTOP="$HOME/.config/autostart/drain-bat-autostart.desktop"
[ -f "$AUTOSTART_DESKTOP" ] && rm -f "$AUTOSTART_DESKTOP"
HS100_CACHE_FILE="$HOME/.cache/drain-bat/hs100_ip"
HS100_IP=""
[ -f "$HS100_CACHE_FILE" ] && HS100_IP="$(cat "$HS100_CACHE_FILE" || true)"
if [ -f "$HOME/.bash_aliases" ]; then
  if [ -n "${HS100_IP}" ]; then
    bash -ic 'source "$HOME/.bash_aliases"; drain-bat --resume "$HS100_IP"'
  else
    bash -ic 'source "$HOME/.bash_aliases"; drain-bat --resume'
  fi
else
  if [ -n "${HS100_IP}" ]; then
    bash -lc 'drain-bat --resume "$HS100_IP"'
  else
    bash -lc 'drain-bat --resume'
  fi
fi
EOF
    chmod +x "$AUTOSTART_SCRIPT"
    cat > "$AUTOSTART_DESKTOP" <<EOF
[Desktop Entry]
Type=Application
Exec=gnome-terminal -- bash -lc '$AUTOSTART_SCRIPT'
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
Name=AutoStart-drain-bat
Comment=Resume drain-bat tests after reboot
EOF
    chmod +x "$AUTOSTART_DESKTOP"
    sync
  }

  # Args
  local RESUME=0 SMART_PLUG=0 HS100_IP="${2:-}"
  if [ $# -gt 0 ]; then
    case "${1:-}" in --resume|--resumed) RESUME=1 ;; esac
    [ $# -ge 2 ] && { SMART_PLUG=1; HS100_IP="$2"; }
  fi

  # ---------------- Phase A: pre-reboot ----------------
  if [ "$RESUME" -eq 0 ]; then
    _log "Phase A: pre-reboot setup…"
    ensure_dirs
    gset_save
    gset_apply_test
    autologin_enable
    ensure_sudoers

    ./install.sh -b linux-system76 || true
    ./install.sh devscripts debhelper || true
    ./install.sh stress-ng xdotool || true

    local BRANCH="master"
    if grep -qi "jammy" /etc/os-release 2>/dev/null; then BRANCH="master_jammy"; fi
    ensure_linux_repo "$BRANCH"

    ensure_hs100_repo
    if [ "$SMART_PLUG" -eq 0 ]; then
      HS100_IP="$(discover_hs100_ip "")"; [ -n "$HS100_IP" ] && SMART_PLUG=1
    else
      HS100_IP="$(discover_hs100_ip "$HS100_IP")"
    fi
    [ "$SMART_PLUG" -eq 1 ] && [ "$(battery_status)" != "Discharging" ] && {
      ./hs100/hs100.sh -i "$HS100_IP" off || true; sleep 15; }

    write_autostart "$HS100_IP"
    _log "Rebooting to enter Phase B…"
    sync
    systemctl reboot -i
    return 0
  fi

  # ---------------- Phase B: after reboot ----------------
  _log "Phase B: resume…"

  # Immediate suspend/wake test using RTC alarm + systemd
  sync; sleep 10
  suspend_with_rtc 930
  sleep 5

  # Hydrate plug IP if cached
  [ -z "${HS100_IP:-}" ] && [ -f "$HS100_CACHE_FILE" ] && { HS100_IP="$(cat "$HS100_CACHE_FILE" || true)"; [ -n "$HS100_IP" ] && SMART_PLUG=1; }

  # State machine flags for one full cycle while > threshold:
  #  1) STRESS10 (10-minute stress), then
  #  2) BUILD (linux/rebuild.sh), then
  #  3) STRESS_UNTIL_THRESHOLD (long stress until <= threshold)
  local STRESS10_STARTED=0
  local STRESS10_DONE=0
  local BUILD_STARTED=0
  local LONG_STRESS_STARTED=0

  local LAST_CHARGE=0

  while [ -d /sys/class/power_supply/BAT0 ]; do
    local STATUS="$(battery_status)"
    local CHARGE="$(battery_capacity)"

    # ---- If we hit threshold or go on AC, stop workloads as needed ----
    if [ "$CHARGE" -le "$CHARGE_THRESHOLD" ] || [ "$STATUS" != "Discharging" ]; then
      # smart plug on at/below threshold
      if [ "$CHARGE" -le "$CHARGE_THRESHOLD" ] && [ "$SMART_PLUG" -eq 1 ]; then
        ./hs100/hs100.sh -i "$HS100_IP" on || true
        [ -f "$HS100_CACHE_FILE" ] && rm -f "$HS100_CACHE_FILE" || true
      fi
      # stop stress and rebuild if running
      pkill -x stress-ng >/dev/null 2>&1 || true

      # Preferred: close the gnome-terminal windows launched by terminal.sh by title
      if command -v xdotool >/dev/null 2>&1; then
        for T in kernel-rebuild stress10 stress-until; do
          # search may return multiple window ids; close them all
          WINS=$(xdotool search --name "$T" 2>/dev/null || true)
          if [ -n "$WINS" ]; then
            for W in $WINS; do
              xdotool windowclose "$W" >/dev/null 2>&1 || xdotool windowkill "$W" >/dev/null 2>&1 || true
            done
            # give processes a moment to exit
            sleep 2
          fi
        done
      fi

      # Fallback: if any rebuild.sh or make processes remain, try to terminate them
      if pgrep -f rebuild.sh >/dev/null 2>&1; then
        pkill -f rebuild.sh >/dev/null 2>&1 || true
        sleep 1
        pkill -KILL -f rebuild.sh >/dev/null 2>&1 || true
      fi
      # Kill make (graceful then force)
      pkill -TERM -x make >/dev/null 2>&1 || true
      sleep 1
      pkill -KILL -x make >/dev/null 2>&1 || true
    fi

    # ---- Only orchestrate the cycle while discharging and above threshold ----
    if [ "$STATUS" = "Discharging" ] && [ "$CHARGE" -gt "$CHARGE_THRESHOLD" ]; then

      # 1) Start 10-minute stress if not started or done
      if [ "$STRESS10_DONE" -eq 0 ]; then
        if [ "$STRESS10_STARTED" -eq 0 ]; then
          STRESS10_STARTED=1
          # 10-minute stress with timeout; auto-exits after 600s
          $(bash ./terminal.sh --name=stress10 --title=stress10) \
            bash -lc 'stress-ng -c 0 --timeout 600s' &
        fi
        sleep 1
        # When the 10-minute stress finishes, mark done
        if ! pgrep -f "stress-ng -c 0" >/dev/null 2>&1; then
          # It either finished or never started; if charge still > threshold, mark done
          STRESS10_DONE=1
        fi

      # 2) Start kernel rebuild after stress10 completes
      elif [ "$BUILD_STARTED" -eq 0 ] && [ "$STRESS10_DONE" -eq 1 ]; then
        BUILD_STARTED=1
        $(bash ./terminal.sh --name=kernel-rebuild --title=kernel-rebuild) \
          bash -lc 'cd "$OLDPWD/linux" 2>/dev/null || cd "./linux"; ./rebuild.sh'

      # 3) If build has finished and we’re still above threshold, start long stress (until threshold)
      else
        # build considered running if either rebuild.sh or make is seen
        if ! pgrep -f "rebuild.sh" >/dev/null 2>&1 && ! pgrep -f "make .* -C" >/dev/null 2>&1; then
          if [ "$LONG_STRESS_STARTED" -eq 0 ] && ! pgrep -x stress-ng >/dev/null 2>&1; then
            LONG_STRESS_STARTED=1
            $(bash ./terminal.sh --name=stress-until --title=stress-until-threshold) \
              bash -lc 'stress-ng -c 0' &
          fi
        fi
      fi
    fi

    # ---- Progress echo (only on change) ----
    if [ "$LAST_CHARGE" -ne "${CHARGE:-0}" ]; then
      LAST_CHARGE="$CHARGE"
      echo "$CHARGE"
    fi

    # ---- Done? ----
    if [ "${CHARGE:-0}" -ge 100 ]; then
      _log "Battery full. Cleaning up…"
      remove_sudoers_if_present
      autologin_disable
      gset_restore_and_clear
      break
    fi

    sleep 1
  done
}

mem-speed ()
{
    sudo dmidecode --type 17 | grep -i speed
}

pang12-stress ()
{
    gsettings set org.gnome.desktop.session idle-delay 0
    gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type "nothing"
    gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type "nothing"
    ./install.sh stress-ng glmark2
    $(bash ./terminal --name=stress-ng --title=stress-ng) bash -c "while true; do stress-ng -c 0 -m 0 --vm-bytes 25G; done"
    $(bash ./terminal --name=glmark2 --title=glmark2) bash -c "glmark2 --run-forever"
    $(bash ./terminal --name=journalctl --title=journalctl) bash -c "sudo journalctl -f | grep mce"
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
    gsettings set org.gnome.desktop.session idle-delay 0
    gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type "nothing"
    gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type "nothing"
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
