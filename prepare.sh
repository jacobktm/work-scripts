#!/bin/bash
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
UPDATE_SYS=1
CHECK_UBUNTU=1
UPDATE_ALIASES=0
UBUNTU=0
INSTALL_PPA=0
SKIP_PPA=0
REBOOT=1
PPA_INSTALLED=0
DEBUG=0
PKG_LIST=("vim" "htop" "git-lfs" "powertop" "acpica-tools" "efitools" "screen")

pushd $SCRIPT_DIR

if [ -d .git ]; then
    ./install.sh git
    git reset --hard HEAD
    git restore .
    git fetch --all
    git pull --rebase
    git submodule update --init --recursive --checkout
fi

./setup-apt-proxy.sh

if [ $(echo $PATH | grep -c "\.local/bin") -eq 0 ]; then
    PATH="$HOME/.local/bin:$PATH"
fi

while getopts "npsud" option; do
    case $option in
        n) # skip reboot
            REBOOT=0;;
        p) # skip ppa
            SKIP_PPA=1;;
        s) # Skip updating the system
            CHECK_UBUNTU=0
            UPDATE_SYS=0;;
        u) # update the aliases file
            UPDATE_ALIASES=1;;
        d) # don't remove temp diff file
            DEBUG=1;;
        \?) # Invalid option
            echo "Error: Invalid option"
            exit 1;;
    esac
done

# Check and set timezone to Denver if not already set
if command -v timedatectl >/dev/null 2>&1; then
    CURRENT_TZ=$(timedatectl show -p Timezone --value)
    if [ "$CURRENT_TZ" != "America/Denver" ]; then
        echo "Timezone is not set to America/Denver. Setting timezone to America/Denver."
        sudo timedatectl set-timezone America/Denver
    else
        echo "Timezone is already set to America/Denver."
    fi
else
    echo "timedatectl command not found. Cannot check or set timezone."
fi

if [ $CHECK_UBUNTU -eq 1 ]; then
    if grep -q "Ubuntu" /etc/os-release; then
        UBUNTU=1
    fi
fi

if grep -R --include '*.list' '^deb.*ppa.launchpad.net/system76-dev/stable' /etc/apt/; then
    PPA_INSTALLED=1
fi

if [ $UBUNTU -eq 1 ] && [ $PPA_INSTALLED -eq 0 ]; then
    UPDATE_SYS=0
    REBOOT=0
    INSTALL_PPA=1
fi

if [ $SKIP_PPA -gt 0 ]; then
    INSTALL_PPA=0
fi

if [ $UBUNTU -eq 0 ] && [ $PPA_INSTALLED -eq 1 ] && [ $SKIP_PPA -eq 0 ]; then
    PKG_LIST+=("system76-firmware")
    PKG_LIST+=("system76-firmware-daemon")
fi

if [ $UPDATE_SYS -eq 1 ]; then
    until apt-proxy update
    do
        sleep 1
    done
    apt-proxy full-upgrade -y --allow-downgrades
    apt-proxy autoremove -y
fi

# Determine the location of the current script to get the path of the new aliases file
NEW_ALIASES_PATH="${SCRIPT_DIR}/bash_aliases"
if [ -e $NEW_ALIASES_PATH ]; then
    sed -i "s|\./install\.sh|${SCRIPT_DIR}/install.sh|g" ${SCRIPT_DIR}/bash_aliases
    sed -i "s|\./terminal\.sh|${SCRIPT_DIR}/terminal.sh|g" ${SCRIPT_DIR}/bash_aliases
    sed -i "s|\./check-needrestart\.sh|${SCRIPT_DIR}/check-needrestart.sh|g" ${SCRIPT_DIR}/bash_aliases

    # Check if ~/.bash_aliases exists
    if [[ ! -f $HOME/.bash_aliases ]]; then
        cp $NEW_ALIASES_PATH $HOME/.bash_aliases
    elif [ $UPDATE_ALIASES -eq 1 ]; then
        # Create a temporary diff file
        DIFF_FILE=$(mktemp)

        # Create a diff
        diff -u $HOME/.bash_aliases $NEW_ALIASES_PATH > $DIFF_FILE

        # Check if there are any changes
        if [[ ! -s $DIFF_FILE ]]; then
            echo "No changes found."
            rm -f $DIFF_FILE
        else
            # Apply the patch
            patch $HOME/.bash_aliases < $DIFF_FILE

            # Check the exit status of the patch command to determine success
            if [[ $? -eq 0 ]]; then
                echo "Aliases updated successfully."
            else
                echo "Error occurred while updating aliases. Check the diff and patch manually."
            fi
            if [ $DEBUG -eq 0 ]; then
                rm -f $DIFF_FILE
            fi
        fi
    fi
fi

if [ -e ${SCRIPT_DIR}/terminal.sh ]; then
    sed -i "s|\./install\.sh|${SCRIPT_DIR}/install.sh|g" ${SCRIPT_DIR}/terminal.sh
fi

pushd $HOME/.local/bin
if [ -e ${SCRIPT_DIR}/mainline.sh ]; then
    sed -i "s|\./install\.sh|${SCRIPT_DIR}/install.sh|g" ${SCRIPT_DIR}/mainline.sh
    if [ -e setup-mainline ]; then
        rm -rvf setup-mainline
    fi
    ln -s ${SCRIPT_DIR}/mainline.sh setup-mainline
fi

if [ -e ${SCRIPT_DIR}/suspend.sh ]; then
    sed -i "s|\./install\.sh|${SCRIPT_DIR}/install.sh|g" ${SCRIPT_DIR}/suspend.sh
    sed -i "s|\./count|${SCRIPT_DIR}/count|g" ${SCRIPT_DIR}/suspend.sh
    sed -i "s|\./resume-hook\.sh|${SCRIPT_DIR}/resume-hook.sh|g" ${SCRIPT_DIR}/suspend.sh
    sed -i "s|\./sustest_patterns\.txt|${SCRIPT_DIR}/sustest_patterns.txt|g" ${SCRIPT_DIR}/suspend.sh
    sed -i "s|\./sustest_journal|${HOME}/sustest_journal|g" ${SCRIPT_DIR}/suspend.sh
    if [ -e sustest ]; then
        rm -rvf sustest
    fi
    ln -s ${SCRIPT_DIR}/suspend.sh sustest
fi

if [ -e ${SCRIPT_DIR}/system76-ppa.sh ]; then
    sed -i "s|\./check-needrestart\.sh|${SCRIPT_DIR}/check-needrestart.sh|g" ${SCRIPT_DIR}/system76-ppa.sh
    if [ -e system76-ppa ]; then
        rm -rvf system76-ppa
    fi
    ln -s ${SCRIPT_DIR}/system76-ppa.sh system76-ppa
fi
if [ $INSTALL_PPA -eq 1 ]; then
    system76-ppa
fi

$SCRIPT_DIR/install.sh "${PKG_LIST[@]}"

if [ -e $SCRIPT_DIR/check-needrestart.sh ]; then
    if [ $REBOOT -eq 1 ]; then
        $SCRIPT_DIR/check-needrestart.sh
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
    fi
fi
popd
popd
