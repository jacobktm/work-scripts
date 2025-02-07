#!/bin/bash

# Exit if no arguments are provided
if [ $# -eq 0 ]; then
    exit 0
fi

USE_BUILD_DEP=false

# Parse command-line options
while getopts ":b" opt; do
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

# Detect the OS (we’ll handle build-dep only on Debian-based systems here)
os_name=$(awk -F= '/^ID=/{print $2}' /etc/os-release)

PKG_LIST=()

if $USE_BUILD_DEP && [[ "$os_name" =~ ^(ubuntu|pop|debian)$ ]]; then
    # Loop through each package argument
    for pkg in "$@"; do
        # Run a simulated build-dep to see what would be installed
        output=$(sudo apt-get build-dep -s "$pkg" 2>/dev/null)
        # Use grep to capture lines that start with "Inst" and extract the package name
        deps=$(echo "$output" | grep '^Inst' | awk '{print $2}')
        if [ ! -z "$deps" ]; then
            for dep in $deps; do
                PKG_LIST+=("$dep")
            done
        fi
    done
else
    # If not using build-dep, use the provided packages directly.
    PKG_LIST=("$@")
fi

# Function to check if a package is installed
is_installed() {
    case "$os_name" in
        ubuntu|pop|debian)
            dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "ok installed"
            ;;
        arch)
            pacman -Qi "$1" &>/dev/null
            ;;
        fedora)
            rpm -q "$1" &>/dev/null
            ;;
        *)
            return 1
            ;;
    esac
}

# Now filter out already-installed packages
FINAL_PKGS=()
for pkg in "${PKG_LIST[@]}"; do
    if ! is_installed "$pkg"; then
        FINAL_PKGS+=("$pkg")
    fi
done

# If there are packages to install, install them
if [ ${#FINAL_PKGS[@]} -ne 0 ]; then
    case "$os_name" in
        ubuntu|pop|debian)
            # Use apt-proxy if available; otherwise, fall back to sudo apt
            if command -v apt-proxy &>/dev/null; then
                APT_COMMAND="apt-proxy"
            else
                APT_COMMAND="sudo apt"
            fi

            # Update package lists
            until $APT_COMMAND update; do
                sleep 10
            done

            # Install the missing packages; note the use of "--" so package names starting with '-' are safe.
            $APT_COMMAND install -y -- "${FINAL_PKGS[@]}"
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
            yay -S --noconfirm "${FINAL_PKGS[@]}"
            ;;
        fedora)
            sudo dnf install -y "${FINAL_PKGS[@]}"
            ;;
        *)
            echo "Unsupported OS: $os_name"
            exit 1
            ;;
    esac
fi
