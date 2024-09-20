#!/bin/bash

SCRIPT_PATH=$(cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd)
PKG_LIST=("git-lfs" "git")

apt_command() {
    if command -v apt-proxy &>/dev/null; then
        apt-proxy "$@"
    else
        sudo apt "$@"
    fi
}

./install.sh "${PKG_LIST[@]}"

do_reboot() {
    cat << EOF > .rebooted
#!/bin/bash
cd "$SCRIPT_PATH"
bash ./s76-stress-tests.sh $@
EOF
    echo "bash ${HOME}/.rebooted" >> .bashrc
    sudo systemctl reboot -i
}

if [ ! -d ${HOME}/Documents/stress-scripts ]; then
    pushd ${HOME}
    if [ ! -e .rebooted ];
    then
        until apt_command update; do
            sleep 10
        done
        apt_command full-upgrade -y --allow-downgrades
        pushd ${HOME}/Documents
            if [ ! -e stress-scripts ]; then
                git clone https://github.com/jacobktm/stress-scripts.git
                pushd stress-scripts
                    git checkout main
                    git submodule update --init --recursive --checkout
                    git reset --hard HEAD
                    git fetch --all
                    git pull
                popd
            fi
            pushd stress-scripts
                bash s76-setup-testpy.sh
                bash s76-setup-unigine.sh
            popd
        popd
        $SCRIPT_DIR/check-needrestart.sh
        if [ $? -eq 0 ]; then
            do_reboot
        fi
    else
        rm -rvf ./.rebooted
        sed -i '/.rebooted/d' .bashrc
    fi
    popd
fi
cd ${HOME}/Documents/stress-scripts
git reset --hard HEAD
git fetch --all
git pull
bash s76-stress-tests.sh $@