#!/bin/bash

# Exit if no arguments are provided
if [ $# -eq 0 ]; then
    exit 0
fi

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

# Loop through each package and install if not already installed
for pkg in "$@"; do
    if ! is_installed "$os_name" "$pkg"; then
        PKG_LIST+=("$pkg")
    fi
done

if [ ${#PKG_LIST[@]} -ne 0 ]; then
    case "$os_name" in
        ubuntu|pop|debian)
            until sudo apt update; do
                sleep 10
            done
            sudo apt install -y "${PKG_LIST[@]}"
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