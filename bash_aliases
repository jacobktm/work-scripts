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

# ---------- GDM autologin helpers ----------
# Can pass explicit conf path as $1; otherwise we autodetect.
_gdm_conf_guess () {
  if   [ -f /etc/gdm3/custom.conf ]; then echo /etc/gdm3/custom.conf
  elif [ -f /etc/gdm/custom.conf  ]; then echo /etc/gdm/custom.conf
  else echo ""; fi
}

autologin_enable () {
  local conf="${1:-$(_gdm_conf_guess)}"
  local user="${2:-${USER:-$USERNAME}}"
  [ -n "$conf" ] || { echo "[autologin_enable] no GDM custom.conf found"; return 0; }
  sudo install -m 0644 -b "$conf" "$conf" 2>/dev/null || true  # leave a backup with ~
  # ensure keys exist with desired values
  if grep -qE '^\s*AutomaticLoginEnable\s*=' "$conf"; then
    sudo sed -i 's/^\s*AutomaticLoginEnable\s*=.*/AutomaticLoginEnable = true/' "$conf"
  else
    echo "AutomaticLoginEnable = true" | sudo tee -a "$conf" >/dev/null
  fi
  if grep -qE '^\s*AutomaticLogin\s*=' "$conf"; then
    sudo sed -i "s/^\s*AutomaticLogin\s*=.*/AutomaticLogin = ${user}/" "$conf"
  else
    echo "AutomaticLogin = ${user}" | sudo tee -a "$conf" >/dev/null
  fi
}

autologin_disable () {
  local conf="${1:-$(_gdm_conf_guess)}"
  [ -n "$conf" ] || return 0
  sudo install -m 0644 -b "$conf" "$conf" 2>/dev/null || true
  # set enable=false and comment out AutomaticLogin user line (or blank it)
  if grep -qE '^\s*AutomaticLoginEnable\s*=' "$conf"; then
    sudo sed -i 's/^\s*AutomaticLoginEnable\s*=.*/AutomaticLoginEnable = false/' "$conf"
  else
    echo "AutomaticLoginEnable = false" | sudo tee -a "$conf" >/dev/null
  fi
  # comment the user line if present
  sudo sed -i 's/^\(\s*\)AutomaticLogin\s*=.*/# \1AutomaticLogin =/' "$conf"
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

# ---------- main drain-bat function (refactored to use helpers) ----------
drain-bat () {
  set -euo pipefail

  # Constants/defaults
  readonly CHARGE_THRESHOLD="${CHARGE_THRESHOLD:-5}"
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

    # HS100 detect + pre-cut AC if on mains so discharge starts next phase
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
    # keep sudoers + autologin; do not restore gsettings yet
    systemctl reboot -i
    return 0
  fi

  # ---------------- Phase B: after reboot ----------------
  _log "Phase B: resume…"
  # First thing: immediate suspend/wake test using rtc alarm + systemd
  suspend_with_rtc 930

  # Hydrate plug IP
  [ -z "${HS100_IP:-}" ] && [ -f "$HS100_CACHE_FILE" ] && { HS100_IP="$(cat "$HS100_CACHE_FILE" || true)"; [ -n "$HS100_IP" ] && SMART_PLUG=1; }

  local LAST_CHARGE=0
  while [ -d /sys/class/power_supply/BAT0 ]; do
    local STATUS="$(battery_status)"
    local CHARGE="$(battery_capacity)"

    # simple discharge workload
    if [ "$STATUS" = "Discharging" ] && ! pgrep -x stress-ng >/dev/null; then
      ( bash -c "stress-ng -c 0 -m 0" ) &
      # stop after 10m or at threshold
      local t0="$(date +%s)"
      while pgrep -x stress-ng >/dev/null; do
        CHARGE="$(battery_capacity)"
        local elapsed="$(( $(date +%s) - t0 ))"
        [ "$elapsed" -ge 600 ] || [ "$CHARGE" -le "$CHARGE_THRESHOLD" ] && pkill -x stress-ng || true
        sleep 1
      done
    fi

    # smart plug on at threshold
    if [ "$SMART_PLUG" -eq 1 ] && [ "$CHARGE" -le "$CHARGE_THRESHOLD" ]; then
      ./hs100/hs100.sh -i "$HS100_IP" on || true
      [ -f "$HS100_CACHE_FILE" ] && rm -f "$HS100_CACHE_FILE" || true
    fi

    # progress echo
    if [ "$LAST_CHARGE" -ne "${CHARGE:-0}" ]; then
      LAST_CHARGE="$CHARGE"
      echo "$CHARGE"
    fi

    # done?
    if [ "${CHARGE:-0}" -ge 100 ]; then
      _log "Battery full. Cleaning up…"
      remove_sudoers_if_present
      autologin_disable
      gset_restore
      break
    fi

    # optional additional sleep cycles:
    # suspend_with_rtc 930
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
