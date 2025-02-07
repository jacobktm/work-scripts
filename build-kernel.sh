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
        local current_kernel=$(uname -r)
        echo "$current_kernel" > "$KERNEL_VERSION_FILE"
        echo "Saved current kernel version: $current_kernel"
    else
        echo "Kernel version already saved: $(cat "$KERNEL_VERSION_FILE")"
    fi
}

reset_kernel() {
    if [ ! -f "$KERNEL_VERSION_FILE" ]; then
        echo "No saved kernel version found. Use the script to save the current kernel version first."
        exit 1
    fi
    local saved_kernel=$(cat "$KERNEL_VERSION_FILE")
    echo "Resetting to saved kernel version: $saved_kernel"

    # Delete all builds from /boot
    echo "Removing all builds from /boot..."
    local builds_vmlinuz=( $(find "$INSTALL_DIR" -name "vmlinuz-*-build-*" 2>/dev/null) )
    local builds_initrd=( $(find "$INSTALL_DIR" -name "initrd.img-*-build-*" 2>/dev/null) )
    local builds_sysmap=( $(find "$INSTALL_DIR" -name "System.map-*-build-*" 2>/dev/null) )
    local builds_config=( $(find "$INSTALL_DIR" -name "config-*-build-*" 2>/dev/null) )

    for build in "${builds_vmlinuz[@]}"; do
        echo "Removing $build"
        sudo rm -f "$build"
    done

    for build in "${builds_initrd[@]}"; do
        echo "Removing $build"
        sudo rm -f "$build"
    done

    for build in "${builds_sysmap[@]}"; do
        echo "Removing $build"
        sudo rm -f "$build"
    done

    for build in "${builds_config[@]}"; do
        echo "Removing $build"
        sudo rm -f "$build"
    done

    # Remove kernel headers from /usr/src
    echo "Removing old kernel headers..."
    sudo rm -rf /usr/src/linux-headers-*-build-*

    # Remove DKMS modules only for deleted "-build-N" kernels
    echo "Removing outdated DKMS modules for custom built kernels..."
    dkms status | grep "\-build-" | awk -F', ' '{print $1","$2}' | while read -r dkms_entry; do
        module_name=$(echo "$dkms_entry" | awk -F'/' '{print $1}')
        module_version=$(echo "$dkms_entry" | awk -F'/' '{print $2}' | cut -d ',' -f1)
        kernel_version=$(echo "$dkms_entry" | awk -F', ' '{print $2}')

        # Only process kernels matching "-build-N"
        if [[ "$kernel_version" == *"-build-"* ]]; then
            # Remove only if the kernel version is no longer installed
            if ! ls "$INSTALL_DIR/vmlinuz-$kernel_version" &>/dev/null; then
                echo "Removing DKMS module: $module_name/$module_version for $kernel_version"
                sudo dkms remove -m "$module_name" -v "$module_version" -k "$kernel_version" --quiet
            fi
        fi
    done

    # Remove module files from /lib/modules
    echo "Removing old kernel modules..."
    sudo rm -rf /lib/modules/*-build-*

    # Delete previous files from the UUID-based directory
    local efi_dir=$(sudo find /boot/efi/EFI -type d -name "Pop_OS-*" 2>/dev/null)
    if [ -n "$efi_dir" ]; then
        echo "Removing previous files from $efi_dir..."
        sudo rm -f "$efi_dir/initrd.img-previous"
        sudo rm -f "$efi_dir/vmlinuz-previous.efi"
    else
        echo "No Pop_OS UUID directory found in /boot/efi/EFI."
    fi

    # Check if kernel files for the saved kernel already exist
    if [ ! -f "$INSTALL_DIR/vmlinuz-$saved_kernel" ] || [ ! -f "$INSTALL_DIR/initrd.img-$saved_kernel" ]; then
        echo "Kernel files for $saved_kernel are missing. Reinstalling the kernel package..."
        sudo apt install --reinstall -y "linux-image-$saved_kernel"
    else
        echo "Kernel files for $saved_kernel already exist. Skipping reinstall."
    fi

    # Reset symbolic links for vmlinuz and initrd.img
    echo "Resetting symbolic links for vmlinuz and initrd.img..."
    sudo ln -sf "$INSTALL_DIR/vmlinuz-$saved_kernel" "$INSTALL_DIR/vmlinuz"
    sudo ln -sf "$INSTALL_DIR/initrd.img-$saved_kernel" "$INSTALL_DIR/initrd.img"
    sudo rm -f "$INSTALL_DIR/vmlinuz.old"
    sudo rm -f "$INSTALL_DIR/initrd.img.old"
    sudo rm -f "$INSTALL_DIR/efi/loader/entries/Pop_OS-oldkern.conf"

    # Update initramfs and bootloader
    echo "Updating initramfs and bootloader..."
    sudo update-initramfs -c -k "$saved_kernel"
    sudo kernelstub -k "$INSTALL_DIR/vmlinuz-$saved_kernel" -i "$INSTALL_DIR/initrd.img-$saved_kernel"
    sudo bootctl update

    # Clean up kernel version file
    rm -f "$KERNEL_VERSION_FILE"
    rm -f "$BUILD_COUNT_FILE"

    echo "Kernel reset to $saved_kernel successfully."
    
    # Prompt to reboot
    read -p "The kernel $saved_kernel has been restored. Would you like to reboot now? [Y/n]: " reboot_choice
    if [[ -z "$reboot_choice" || "$reboot_choice" =~ ^[Yy]$ ]]; then
        echo "Rebooting now..."
        sudo reboot
    else
        echo "Reboot skipped. Please remember to reboot later to use the restored kernel."
    fi
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

    # Find all vmlinuz files with "-build-" in the name and extract build numbers
    local builds=( $(ls "$INSTALL_DIR"/vmlinuz-* 2>/dev/null | grep "\-build\-" | awk -F'-build-' '{print $2}' | sort -n) )

    # Check if the number of builds exceeds the maximum allowed
    if [ ${#builds[@]} -gt $MAX_BUILDS ]; then
        local to_remove=$(( ${#builds[@]} - $MAX_BUILDS ))
        echo "Found ${#builds[@]} builds. Removing $to_remove old builds..."

        # Remove the oldest builds
        for ((i=0; i<to_remove; i++)); do
            local build_number=${builds[i]}
            
            # Find the corresponding files
            local kernel_to_remove=$(ls "$INSTALL_DIR"/vmlinuz-*-build-"$build_number" 2>/dev/null)
            local initrd_to_remove=$(ls "$INSTALL_DIR"/initrd.img-*-build-"$build_number" 2>/dev/null)
            local sysmap_to_remove=$(ls "$INSTALL_DIR"/System.map-*-build-"$build_number" 2>/dev/null)
            local config_to_remove=$(ls "$INSTALL_DIR"/config-*-build-"$build_number" 2>/dev/null)

            # Remove kernel images
            if [ -n "$kernel_to_remove" ]; then
                echo "Removing kernel: $kernel_to_remove"
                sudo rm -f "$kernel_to_remove"
            fi

            # Remove initrd images
            if [ -n "$initrd_to_remove" ]; then
                echo "Removing initrd: $initrd_to_remove"
                sudo rm -f "$initrd_to_remove"
            fi

            # Remove System.map
            if [ -n "$sysmap_to_remove" ]; then
                echo "Removing System.map: $sysmap_to_remove"
                sudo rm -f "$sysmap_to_remove"
            fi

            # Remove config files
            if [ -n "$config_to_remove" ]; then
                echo "Removing config: $config_to_remove"
                sudo rm -f "$config_to_remove"
            fi

            # Remove kernel headers from /usr/src
            local headers_to_remove="/usr/src/linux-headers-*build-$build_number"
            if ls $headers_to_remove 1>/dev/null 2>&1; then
                echo "Removing kernel headers: $headers_to_remove"
                sudo rm -rf $headers_to_remove
            fi
            
            # Remove DKMS builds ONLY for the kernel being deleted
            echo "Removing DKMS modules for build-$build_number..."
            dkms status | grep "build-$build_number" | while read -r dkms_entry; do
                module_name=$(echo "$dkms_entry" | awk -F'/' '{print $1}')
                module_version=$(echo "$dkms_entry" | awk -F'/' '{print $2}' | cut -d ',' -f1)
                kernel_version=$(echo "$dkms_entry" | awk -F', ' '{print $2}')

                if [[ "$kernel_version" == *"build-$build_number" ]]; then
                    echo "Removing DKMS module: $module_name/$module_version for $kernel_version"
                    sudo dkms remove -m "$module_name" -v "$module_version" -k "$kernel_version" --quiet
                fi
            done

            # Remove module files from /lib/modules
            local modules_to_remove="/lib/modules/*build-$build_number"
            if ls $modules_to_remove 1>/dev/null 2>&1; then
                echo "Removing kernel modules: $modules_to_remove"
                sudo rm -rf $modules_to_remove
            fi
        done
    else
        echo "No cleanup required. Total builds: ${#builds[@]}"
    fi
}

build_kernel() {
    $SCRIPT_DIR/install.sh -b linux-system76
    $SCRIPT_DIR/install.sh devscripts debhelper libncurses-dev build-essential ccache
    
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
            local distro_codename=$(lsb_release -cs)
            local branch_name="master_$distro_codename"
        else
            local branch_name="$BRANCH"
        fi
        
        echo "Kernel source directory not found. Cloning repository..."
        local parent_dir=$(dirname "$KERNEL_SRC_DIR")

        # Handle the case where the kernel source directory is ~/linux
        if [[ "$KERNEL_SRC_DIR" == "$HOME/linux" ]]; then
            parent_dir="$HOME"
        fi

        # Change to the parent directory and clone the repository
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
    
    # Save kernel version during build and clean up the version string
    local build_count=$(increment_build_count)
    local suffix="-build-$build_count"
    local kernel_version="$(make -s kernelrelease | sed 's/+//g')${suffix}"
    echo "$kernel_version" > "$KERNEL_SRC_DIR/.built_kernel_version"
    
    make prepare
    make scripts

    echo "Building kernel..."
    make -j$(nproc) LOCALVERSION="$suffix" V=1
}

install_kernel() {
    if [[ ! -f "$KERNEL_SRC_DIR/Makefile" ]]; then
        echo "Error: Makefile not found in $KERNEL_SRC_DIR. Ensure this is a valid kernel source directory."
        exit 1
    fi

    cd "$KERNEL_SRC_DIR"

    # Check if build count file exists, if not, build the kernel
    if [ ! -f "$BUILD_COUNT_FILE" ]; then
        echo "Build count file not found. Building kernel first..."
        build_kernel
    fi

    # Load the saved kernel version from build
    if [ ! -f "$KERNEL_SRC_DIR/.built_kernel_version" ]; then
        echo "Error: No built kernel version found. Building kernel first..."
        build_kernel
    fi
    local kernel_version=$(cat "$KERNEL_SRC_DIR/.built_kernel_version")
    local kernel_image="$INSTALL_DIR/vmlinuz-$kernel_version"
    local initrd_image="$INSTALL_DIR/initrd.img-$kernel_version"
    local build_count=$(cat "$BUILD_COUNT_FILE")

    # Check if the kernel is already running or already installed
    if [ "$(uname -r)" == "$kernel_version" ]; then
        echo "The kernel $kernel_version is already running. Skipping installation."
        return
    fi

    if [ -f "$kernel_image" ]; then
        echo "The kernel $kernel_version is already present in the boot path. Skipping installation."
        return
    fi

    # **Install kernel headers before modules_install**
    echo "Installing kernel headers..."
    sudo make headers_install INSTALL_HDR_PATH=/usr/src/linux-headers-"$kernel_version"

    # Link headers to modules directory for DKMS
    echo "Linking kernel headers for DKMS..."
    sudo mkdir -p /lib/modules/"$kernel_version"
    sudo ln -sf /usr/src/linux-headers-"$kernel_version" /lib/modules/"$kernel_version"/build
    sudo ln -sf /usr/src/linux-headers-"$kernel_version" /lib/modules/"$kernel_version"/source

    # Ensure modules match the saved kernel version
    echo "Stripping unneeded symbols..."
    sudo make INSTALL_MOD_STRIP=1 modules_install LOCALVERSION="-build-$build_count"

    echo "Installing kernel..."
    sudo make install LOCALVERSION="-build-$build_count"

    # **Run DKMS manually after headers are installed**
    echo "Rebuilding DKMS modules..."
    sudo dkms autoinstall
    
    # Get installed NVIDIA DKMS version
    nvidia_version=$(dkms status | grep -i '^nvidia/' | awk -F'[,/ ]+' '{print $2}')

    if [[ ! -z "$nvidia_version" ]]; then
        echo "Forcing DKMS to recognize and rebuild NVIDIA module for $kernel_version..."
        sudo dkms build -m nvidia -v $nvidia_version -k $kernel_version
        sudo dkms install -m nvidia -v $nvidia_version -k $kernel_version
    fi

    # Update initramfs and bootloader
    echo "Updating initramfs and bootloader..."
    sudo update-initramfs -c -k "$kernel_version"
    sudo kernelstub -k "$kernel_image" -i "$initrd_image"
    sudo bootctl update

    rm -f "$KERNEL_SRC_DIR/.built_kernel_version"

    # Cleanup old builds
    cleanup_old_builds
    echo "Kernel $kernel_version installed successfully."

    # Prompt to reboot
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

# Save the current kernel version on the first run
save_current_kernel

if [ "$BUILD_KERNEL" == "true" ]; then
    build_kernel
fi

if [ "$INSTALL_KERNEL" == "true" ]; then
    install_kernel
fi

