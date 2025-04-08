#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

# Variables
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
KERNEL_SRC_DIR=""
INSTALL_DIR=/boot
KERNEL_VERSION_FILE="$HOME/.kernel_version"
BUILD_COUNT_FILE="$HOME/.kernel_build_count"
MAX_BUILDS=3
INSTALLED=false
MAX_CACHE=20
BRANCH=""

# ------------------------------------------------------------------
# New function: get_distcc_hosts
# Purpose: Query the central service for the list of available distcc 
# client IP addresses and format them (each appended with "/4").
# ------------------------------------------------------------------
get_distcc_hosts() {
    local json_output
    json_output=$(curl -s http://10.17.89.69:50000/systems)
    if command -v jq >/dev/null 2>&1; then
        # Use jq to extract each ip and append "/4"
         echo $(echo "$json_output" | jq -r '.systems[] | "\(.hostname)/\(.info.cores // "4")"')
    else
        # Fallback using grep and awk (less robust)
        echo "$json_output" | grep -oP '"hostname":\s*"\K[^"]+' | awk '{printf $1"/4 "}'
    fi
}

get_remote_cores() {
    local json_output
    json_output=$(curl -s http://10.17.89.69:50000/systems)
    if command -v jq >/dev/null 2>&1; then
        # Use jq to extract the "cores" value from each entry under "info"
        # If "cores" is missing, default to "0".
        echo $(echo "$json_output" | jq '[.systems[].info.cores // "0" | tonumber] | add')
    else
        # Fallback using grep/awk: this assumes that the JSON contains a "cores" field as a string.
        echo "$json_output" | grep -oP '"cores":\s*"\K[^"]+' | awk '{ sum+=$1 } END { print sum+0 }'
    fi
}

# ------------------------------------------------------------------
# Functions
usage() {
    echo "Usage: $0 -p <linux-repo> [-r | -b | -i | -b -i ] [-c <max-cache> | -g <git-branch>]"
    echo "  -p <linux-repo> : Path to the kernel repository"
    echo "  -r              : Reset to the saved kernel version"
    echo "  -b              : Clean the build environment and build the kernel"
    echo "  -i              : Install the kernel (build if no built kernel exists)"
    echo "  -c <max-cache>  : Max cache size in Gigabytes."
    echo "  -g <git-branch> : Specify the branch to check out."
    exit 1
}

save_current_kernel() {
    if [ ! -f "$KERNEL_VERSION_FILE" ]; then
        local current_kernel
        current_kernel=$(uname -r)
        echo "$current_kernel" > "$KERNEL_VERSION_FILE"
        echo "Saved current kernel version: $current_kernel"
    else
        echo "Kernel version already saved: $(cat "$KERNEL_VERSION_FILE")"
    fi
}

reset_kernel() {
    # (Reset kernel function code remains as in your original script)
    :
}

increment_build_count() {
    local count=0
    if [ -f "$BUILD_COUNT_FILE" ]; then
        count=$(cat "$BUILD_COUNT_FILE")
    fi
    count=$((count + 1))
    echo "$count" > "$BUILD_COUNT_FILE"
    echo "$count"
}

cleanup_old_builds() {
    echo "Checking for old kernel builds to clean up..."
    # (Cleanup code remains as in your original script)
    :
}

build_kernel() {
    $SCRIPT_DIR/install.sh -b linux-system76
    $SCRIPT_DIR/install.sh devscripts debhelper libncurses-dev build-essential ccache distcc
    ./setup-distcc.sh
    
    # Ensure the repository exists
    if [[ -d "$KERNEL_SRC_DIR" && ! -f "$KERNEL_SRC_DIR/Makefile" ]]; then
        cd "$KERNEL_SRC_DIR"
        if [ -d ".git" ]; then
            echo "Makefile not found, but the directory is a git repository. Restoring source tree..."
            git restore .
        else
            echo "Makefile not found, and the directory is not a git repository. Deleting and recloning..."
            cd ..
            rm -rf "$KERNEL_SRC_DIR"
        fi
    fi

    # Clone the repository if the directory doesn't exist
    if [[ ! -d "$KERNEL_SRC_DIR" ]]; then
        if [ -z "$BRANCH" ]; then
            local distro_codename
            distro_codename=$(lsb_release -cs)
            local branch_name="master_$distro_codename"
        else
            local branch_name="$BRANCH"
        fi
        
        echo "Kernel source directory not found. Cloning repository..."
        local parent_dir
        parent_dir=$(dirname "$KERNEL_SRC_DIR")
        if [[ "$KERNEL_SRC_DIR" == "$HOME/linux" ]]; then
            parent_dir="$HOME"
        fi
        if [ ! -d "$parent_dir" ]; then
            mkdir -p "$parent_dir"
        fi
        cd "$parent_dir"
        echo "Cloning branch: $branch_name"
        git clone --branch "$branch_name" https://github.com/pop-os/linux.git "$(basename $KERNEL_SRC_DIR)"
    fi
    
    if [[ ! -f "$KERNEL_SRC_DIR/Makefile" ]]; then
        echo "Error: Makefile still not found in $KERNEL_SRC_DIR. Ensure this is a valid kernel source directory."
        exit 1
    fi

    echo "Checking if ccache is already linked..."
    if [ ! -L /usr/local/bin/gcc ] || [ "$(readlink /usr/local/bin/gcc)" != "$(which ccache)" ]; then
        echo "Setting up ccache to masquerade as the compiler..."
        sudo ln -sf "$(which ccache)" /usr/local/bin/gcc
    fi
    if [ ! -L /usr/local/bin/g++ ] || [ "$(readlink /usr/local/bin/g++)" != "$(which ccache)" ]; then
        sudo ln -sf "$(which ccache)" /usr/local/bin/g++
    fi

    echo "Configuring ccache..."
    export CCACHE_DIR=~/.ccache
    ccache --set-config=cache_dir="$CCACHE_DIR"
    ccache --max-size="${MAX_CACHE}G"

    # --- New distcc integration ---
    echo "Querying distcc host list from central service..."
    DISTCC_HOSTS="$(get_distcc_hosts)"
    echo "Final DISTCC_HOSTS: $DISTCC_HOSTS"

    # Ensure that the local distccd daemon is running.
    if command -v distccd >/dev/null 2>&1; then
        if ! pgrep distccd > /dev/null; then
            echo "Local distccd not running. Starting local distccd..."
            # Allow local connections (127.0.0.1 and 'localhost') on default port 3632.
            distccd --daemon --allow "127.0.0.1/32,localhost/32" --log-level info
        else
            echo "Local distccd is already running."
        fi
    else
        echo "Warning: distccd is not installed on localhost. Local distributed compilation won't work."
    fi
    # --------------------------------

    echo "Cleaning and preparing the build environment..."
    cd "$KERNEL_SRC_DIR"
    if [ ! -z "$BRANCH" ]; then
        git checkout "$BRANCH"
    fi
    if [ ! $(ls | grep -c linux-headers) -eq 0 ]; then
        sudo rm -rf linux-headers-*
    fi
    sudo make mrproper

    # Restore source tree if it is a git repository
    if [ -d ".git" ]; then
        echo "Restoring source tree to a clean state using git..."
        git restore .
    fi

    cp /boot/config-$(uname -r) .config

    echo "Clearing trusted keys..."
    sed -i 's/CONFIG_SYSTEM_TRUSTED_KEYS="[^"]*"/CONFIG_SYSTEM_TRUSTED_KEYS=""/' .config
    sed -i 's/CONFIG_SYSTEM_REVOCATION_KEYS="[^"]*"/CONFIG_SYSTEM_REVOCATION_KEYS=""/' .config

    echo "Enabling XZ compression and EFI stub..."
    sed -i 's/^# CONFIG_KERNEL_XZ is not set/CONFIG_KERNEL_XZ=y/' .config
    sed -i 's/^CONFIG_KERNEL_GZIP=y/# CONFIG_KERNEL_GZIP is not set/' .config
    sed -i 's/^# CONFIG_EFI_STUB is not set/CONFIG_EFI_STUB=y/' .config

    yes "" | make oldconfig
    
    local build_count
    build_count=$(increment_build_count)
    local suffix="-build-$build_count"
    local kernel_version
    kernel_version="$(make -s kernelrelease | sed 's/+//g')${suffix}"
    echo "$kernel_version" > "$KERNEL_SRC_DIR/.built_kernel_version"
    
    make prepare
    make scripts

    # --- Calculate total parallel jobs ---
    local REMOTE_CORES
    REMOTE_CORES=$(get_remote_cores)
    local LOCAL_CORES
    LOCAL_CORES=$(nproc)
    local TOTAL_CORES=$((REMOTE_CORES + LOCAL_CORES))
    echo "Local cores: ${LOCAL_CORES}, Remote cores: ${REMOTE_CORES}, Total parallel jobs: ${TOTAL_CORES}"
    # ---------------------------------------

    echo "Building kernel..."
    make -j${TOTAL_CORES} LOCALVERSION="$suffix" V=1 CC="distcc /usr/local/bin/gcc" CXX="distcc /usr/local/bin/g++"
}

install_kernel() {
    if [[ ! -f "$KERNEL_SRC_DIR/Makefile" ]]; then
        echo "Error: Makefile not found in $KERNEL_SRC_DIR. Ensure this is a valid kernel source directory."
        exit 1
    fi

    cd "$KERNEL_SRC_DIR"

    if [ ! -f "$BUILD_COUNT_FILE" ]; then
        echo "Build count file not found. Building kernel first..."
        build_kernel
    fi

    if [ ! -f "$KERNEL_SRC_DIR/.built_kernel_version" ]; then
        echo "Error: No built kernel version found. Building kernel first..."
        build_kernel
    fi
    local kernel_version
    kernel_version=$(cat "$KERNEL_SRC_DIR/.built_kernel_version")
    local kernel_image="$INSTALL_DIR/vmlinuz-$kernel_version"
    local initrd_image="$INSTALL_DIR/initrd.img-$kernel_version"
    local build_count
    build_count=$(cat "$BUILD_COUNT_FILE")

    if [ "$(uname -r)" == "$kernel_version" ]; then
        echo "The kernel $kernel_version is already running. Skipping installation."
        return
    fi

    if [ -f "$kernel_image" ]; then
        echo "The kernel $kernel_version is already present in the boot path. Skipping installation."
        return
    fi

    echo "Installing kernel headers..."
    sudo make headers_install INSTALL_HDR_PATH=/usr/src/linux-headers-"$kernel_version"

    echo "Linking kernel headers for DKMS..."
    sudo mkdir -p /lib/modules/"$kernel_version"
    sudo ln -sf /usr/src/linux-headers-"$kernel_version" /lib/modules/"$kernel_version"/build
    sudo ln -sf /usr/src/linux-headers-"$kernel_version" /lib/modules/"$kernel_version"/source

    echo "Stripping unneeded symbols..."
    sudo make INSTALL_MOD_STRIP=1 modules_install LOCALVERSION="-build-$build_count"

    echo "Installing kernel..."
    sudo make install LOCALVERSION="-build-$build_count"

    echo "Rebuilding DKMS modules..."
    sudo dkms autoinstall
    
    nvidia_version=$(dkms status | grep -i '^nvidia/' | awk -F'[,/ ]+' '{print $2}')
    if [[ ! -z "$nvidia_version" ]]; then
        echo "Forcing DKMS to recognize and rebuild NVIDIA module for $kernel_version..."
        sudo dkms build -m nvidia -v $nvidia_version -k $kernel_version
        sudo dkms install -m nvidia -v $nvidia_version -k $kernel_version
    fi

    echo "Updating initramfs and bootloader..."
    sudo update-initramfs -c -k "$kernel_version"
    sudo kernelstub -k "$kernel_image" -i "$initrd_image"
    sudo bootctl update

    rm -f "$KERNEL_SRC_DIR/.built_kernel_version"

    cleanup_old_builds
    echo "Kernel $kernel_version installed successfully."

    read -p "The kernel $kernel_version has been installed. Would you like to reboot now? [Y/n]: " reboot_choice
    if [[ -z "$reboot_choice" || "$reboot_choice" =~ ^[Yy]$ ]]; then
        echo "Rebooting now..."
        sudo reboot
    else
        echo "Reboot skipped. Please remember to reboot later to use the new kernel."
    fi
}

# Main
while getopts "p:rbic:g:h" opt; do
    case $opt in
        p)
            KERNEL_SRC_DIR=$OPTARG
            if [ ! -d "$KERNEL_SRC_DIR" ]; then
                mkdir -p "$KERNEL_SRC_DIR"
            fi
            KERNEL_SRC_DIR=$(realpath "$KERNEL_SRC_DIR")
            ;;
        r)
            reset_kernel
            exit 0
            ;;
        b)
            BUILD_KERNEL=true
            ;;
        i)
            INSTALL_KERNEL=true
            ;;
        c)
            MAX_CACHE=$OPTARG
            ;;
        g)
            BRANCH=$OPTARG
            ;;
        h | *)
            usage
            ;;
    esac
done

if [ -z "$KERNEL_SRC_DIR" ]; then
    echo "Error: Kernel repository path is required."
    usage
fi

save_current_kernel

if [ "$BUILD_KERNEL" == "true" ]; then
    build_kernel
fi

if [ "$INSTALL_KERNEL" == "true" ]; then
    install_kernel
fi
