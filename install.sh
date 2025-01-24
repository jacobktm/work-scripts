#!/bin/bash

# Exit if no arguments are provided
if [ $# -eq 0 ]; then
    exit 0
fi

USE_BUILD_DEP=false

# Parse command-line options
while getopts "b" opt; do
    case $opt in
        b)
            USE_BUILD_DEP=true
            ;;
        *)
            echo "Usage: $0 [-b] [packages...]"
            exit 1
            ;;
    esac
done
shift $((OPTIND - 1))

PKG_LIST=()

# Function to check if a package is installed
is_installed() {
    case "$1" in
        ubuntu|pop|debian)
            dpkg-query -W -f='${Status}' "$2" 2>/dev/null | grep -q "ok installed"
            ;;
        arch)
            pacman -Qi "$2" &>/dev/null
            ;;
        fedora)
            rpm -q "$2" &>/dev/null
            ;;
        *)
            return 1
            ;;
    esac
}

# Detect the OS
os_name=$(awk -F= '/^ID=/{print $2}' /etc/os-release)

# Loop through each package and add to the list if not already installed
for pkg in "$@"; do
    if ! is_installed "$os_name" "$pkg"; then
        PKG_LIST+=("$pkg")
    fi
done

# If there are packages to install
if [ ${#PKG_LIST[@]} -ne 0 ]; then
    case "$os_name" in
        ubuntu|pop|debian)
            # Check if apt-proxy is in the PATH, use it if available, otherwise fall back to sudo apt
            if command -v apt-proxy &>/dev/null; then
                APT_COMMAND="apt-proxy"
            else
                APT_COMMAND="sudo apt"
            fi
            
            # Update and install the packages
            until $APT_COMMAND update; do
                sleep 10
            done

            if $USE_BUILD_DEP; then
                for pkg in "${PKG_LIST[@]}"; do
                    $APT_COMMAND build-dep -y "$pkg"
                done
            else
                $APT_COMMAND install -y "${PKG_LIST[@]}"
            fi
            ;;
        arch)
            if ! command -v yay &>/dev/null; then
                sudo pacman -Syu --noconfirm git base-devel
                git clone https://aur.archlinux.org/yay.git
                cd yay
                makepkg -si
                cd ..
                rm -rf yay
            fi
            yay -S --noconfirm "${PKG_LIST[@]}"
            ;;
        fedora)
            sudo dnf install -y "${PKG_LIST[@]}"
            ;;
        *)
            echo "Unsupported OS: $os_name"
            exit 1
            ;;
    esac
fi

