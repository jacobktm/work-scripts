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

drain-bat ()
{
    ./install build-dep linux-system76
    ./install devscripts debhelper
    # Decide which branch to use: use master_jammy on jammy systems, master otherwise
    BRANCH="master"
    if grep -qi "jammy" /etc/os-release 2>/dev/null; then
        BRANCH="master_jammy"
    fi

    # Clone or update the linux repo on the chosen branch. If branch doesn't exist remotely, fall back to master.
    if [ -d linux ]; then
        pushd linux >/dev/null
        git fetch --all --prune
        if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
            git checkout "$BRANCH"
            git pull --ff-only || true
        else
            if git ls-remote --heads origin "$BRANCH" | grep -q "$BRANCH"; then
                git checkout -b "$BRANCH" "origin/$BRANCH" || true
            else
                git checkout master || true
                git pull --ff-only || true
            fi
        fi
        popd >/dev/null
    else
        git clone --branch "$BRANCH" --single-branch https://github.com/pop-os/linux.git 2>/dev/null || \
            git clone https://github.com/pop-os/linux.git
    fi
    SMART_PLUG=0
    if [ $# -gt 0 ];
    then
        SMART_PLUG=1
        HS100_ARGS=" -i $1"
    fi
    ./install.sh stress-ng xdotool
    if [ -d /sys/class/power_supply/BAT0 ];
    then
        STATUS=$(cat /sys/class/power_supply/BAT0/status)
        # If no IP was provided, attempt automatic discovery using hs100.sh discover
        if [ $SMART_PLUG -eq 0 ]; then
            # Ensure hs100 script is available
            if [ ! -d hs100 ]; then
                git clone https://github.com/branning/hs100.git
            fi
            # hs100 discovery requires nmap
            if ! command -v nmap &>/dev/null; then
                ./install.sh nmap
            fi
            DISCOVERY_OUT=$(./hs100/hs100.sh discover 2>&1 || true)
            # Parse first IPv4 address from expected output: "HS100 plugs found: <ip>"
            DISCOVER_IP=$(echo "$DISCOVERY_OUT" | sed -n 's/.*HS100 plugs found: \([0-9.]*\).*/\1/p')
            if [ -n "$DISCOVER_IP" ]; then
                SMART_PLUG=1
                HS100_ARGS=" -i $DISCOVER_IP"
            fi
        fi

        if [ $SMART_PLUG -eq 1 ] && [ "$STATUS" != "Discharging" ];
        then
            if [ ! -d hs100 ]; then
                git clone https://github.com/branning/hs100.git
            fi
            ./hs100/hs100.sh${HS100_ARGS} off
            sleep 15
        fi
        LAST_CHARGE=0
        clear
        start_time=$(date +%s)
        while true;
        do
            cur_time=$(date +%s)
            duration=$(($cur_time-$start_time))
            if [ $duration -ge 280 ]
            then
                start_time=$(date +%s)
                # Get the current mouse position
                eval $(xdotool getmouselocation --shell)

                # Move the mouse
                xdotool mousemove --sync $((X+1)) $((Y+1))
                xdotool mousemove --sync $X $Y
            fi
            STATUS=$(cat /sys/class/power_supply/BAT0/status)
            CHARGE=$(cat /sys/class/power_supply/BAT0/capacity)
            if [ "$STATUS" = "Discharging" ] && ! pgrep stress-ng &>/dev/null
            then
                # Start stress-ng in a separate terminal for a fixed 10 minutes
                $(bash ./terminal.sh --name=stress-ng --title=stress-ng) bash -c "stress-ng -c 0 -m 0" &
                # timebox for 10 minutes (600s), but stop early if battery drops below 20%
                stress_start=$(date +%s)
                while true; do
                    now=$(date +%s)
                    elapsed=$((now - stress_start))
                    CHARGE=$(cat /sys/class/power_supply/BAT0/capacity)
                    if [ "$elapsed" -ge 600 ] || [ "$CHARGE" -le 20 ]; then
                        break
                    fi
                    sleep 1
                done
                # stop stress-ng
                pkill stress-ng || true

                # If we have a linux repo with a rebuild script, run it and stop if battery <= 20%
                if [ -d linux ] && [ -x linux/rebuild.sh ]; then
                    pushd linux >/dev/null
                    # run rebuild in its own process so we can monitor/stop it
                    setsid bash -c './rebuild.sh' &
                    REBUILD_PID=$!
                    while kill -0 "$REBUILD_PID" 2>/dev/null; do
                        CHARGE=$(cat /sys/class/power_supply/BAT0/capacity)
                        if [ "$CHARGE" -le 20 ]; then
                            # stop rebuild and its children
                            kill "$REBUILD_PID" 2>/dev/null || true
                            pkill -P "$REBUILD_PID" 2>/dev/null || true
                            wait "$REBUILD_PID" 2>/dev/null || true
                            break
                        fi
                        sleep 5
                    done
                    # wait for rebuild to finish if it did
                    wait "$REBUILD_PID" 2>/dev/null || true
                    popd >/dev/null

                    # If rebuild finished and battery still >20, run stress-ng again until next condition
                    CHARGE=$(cat /sys/class/power_supply/BAT0/capacity)
                    if [ "$CHARGE" -gt 20 ]; then
                        $(bash ./terminal.sh --name=stress-ng --title=stress-ng) bash -c "stress-ng -c 0 -m 0" &
                    fi
                fi
            fi
            if [ $LAST_CHARGE -ne $CHARGE ];
            then
                LAST_CHARGE=$CHARGE
                echo $CHARGE
            fi
            if [ $SMART_PLUG -eq 1 ] && [ $CHARGE -le 20 ];
            then
                ./hs100/hs100.sh${HS100_ARGS} on
            fi
            if [ $CHARGE -eq 100 ]
            then
                break
            fi
            sleep 1
        done
    fi

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
