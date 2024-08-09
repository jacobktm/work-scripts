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
PKG_LIST=("vim" "htop" "git-lfs" "powertop" "acpica-tools")

pushd $SCRIPT_DIR

if [ -d .git ]; then
    git reset --hard HEAD
    git restore .
    git fetch --all
    git pull --rebase
    git submodule update --init --recursive --checkout
fi

while getopts "npsu" option; do
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
            exit;;
    esac
done

if [ $CHECK_UBUNTU -eq 1 ]; then
    if [[ "$(cat /etc/os-release)" == *"Ubuntu"* ]]; then
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

if [ $UBUNTU -eq 0 ] || [ $PPA_INSTALLED -eq 1 ] || [ $SKIP_PPA -eq 0 ]; then
    PKG_LIST+=("system76-firmware")
    PKG_LIST+=("system76-firmware-daemon")
fi

if (($UPDATE_SYS == 1)); then
    until sudo apt update
    do
        sleep 1
    done
    sudo apt full-upgrade -y --allow-downgrades
    sudo apt autoremove -y
fi

# Determine the location of the current script to get the path of the new aliases file
NEW_ALIASES_PATH="${SCRIPT_DIR}/bash_aliases"
sed -i "s|\./install\.sh|${SCRIPT_DIR}/install.sh|g" bash_aliases
sed -i "s|\./terminal\.sh|${SCRIPT_DIR}/terminal.sh|g" bash_aliases
sed -i "s|\./check-needrestart\.sh|${SCRIPT_DIR}/check-needrestart.sh|g" bash_aliases

# Check if ~/.bash_aliases exists
if [[ ! -f $HOME/.bash_aliases ]]; then
    cp $NEW_ALIASES_PATH $HOME/.bash_aliases
elif (($UPDATE_ALIASES == 1)); then
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

# Replace './install.sh' with the absolute path of install.sh in suspend.sh and terminal.sh
sed -i "s|\./install\.sh|${SCRIPT_DIR}/install.sh|g" suspend.sh
sed -i "s|\./install\.sh|${SCRIPT_DIR}/install.sh|g" terminal.sh
sed -i "s|\./install\.sh|${SCRIPT_DIR}/install.sh|g" mainline.sh

sed -i "s|\./check-needrestart\.sh|${SCRIPT_DIR}/check-needrestart.sh|g" system76-ppa.sh

sed -i "s|\./count|${SCRIPT_DIR}/count|g" suspend.sh
sed -i "s|\./resume-hook\.sh|${SCRIPT_DIR}/resume-hook.sh|g" suspend.sh

cd /usr/sbin
if [ -e setup-mainline ]; then
    sudo rm -rvf setup-mainline
fi
sudo ln -s ${SCRIPT_DIR}/mainline.sh setup-mainline

if [ -e sustest ]; then
    sudo rm -rvf sustest
fi
sudo ln -s ${SCRIPT_DIR}/suspend.sh sustest

if [ -e system76-ppa ]; then
    sudo rm -rvf system76-ppa
fi
sudo ln -s ${SCRIPT_DIR}/system76-ppa.sh system76-ppa
if [ $INSTALL_PPA -eq 1 ]; then
    system76-ppa
fi

$SCRIPT_DIR/install.sh "${PKG_LIST[@]}"

if (($REBOOT == 1)); then
    $SCRIPT_DIR/check-needrestart.sh
    if [ $? -eq 0 ]; then
        systemctl reboot -i
    fi
fi
popd
