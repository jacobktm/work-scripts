#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <linux-repo>"
    exit 1
fi

# Variables (update as needed)
KERNEL_SRC_DIR=$(realpath "$1")        # Path to the kernel source
INSTALL_DIR=/boot                      # Directory where kernel and initrd will be installed

# Determine the current distro and set the branch name
DISTRO=$(lsb_release -cs)  # Get the codename of the distro (e.g., jammy, focal)
BRANCH_NAME="master_$DISTRO"

# Check if the kernel source directory exists
if [ ! -d "$KERNEL_SRC_DIR" ]; then
    echo "Kernel source directory does not exist. Cloning repository..."

    # Get the parent directory of the specified path
    PARENT_DIR=$(dirname "$KERNEL_SRC_DIR")

    # Change to the parent directory
    cd "$PARENT_DIR"

    # Clone the repository
    git clone https://github.com/pop-os/linux.git

    # Change to the newly cloned repo directory
    pushd "$KERNEL_SRC_DIR"

    # Checkout the correct branch for the distro
    echo "Checking out branch: $BRANCH_NAME"
    git checkout "$BRANCH_NAME"

    # Return to the parent directory
    popd
else
    echo "Kernel source directory exists. Proceeding with the build..."
fi

# Check if the kernel source directory is valid
if [[ ! -f "$KERNEL_SRC_DIR/Makefile" ]]; then
    echo "Error: Makefile not found in $KERNEL_SRC_DIR. Ensure this is a valid kernel source directory."
    exit 1
fi

# Cleanup previous build artifacts
echo "Cleaning up previous build artifacts..."
cd "$KERNEL_SRC_DIR"
make mrproper  # Clean the source tree

# Copy the existing configuration from /boot to the kernel source
echo "Copying existing kernel configuration..."
cp /boot/config-$(uname -r) .config

# Disable resolve_btfids and update trusted keys
echo "Clearing trusted keys..."
sed -i 's/CONFIG_SYSTEM_TRUSTED_KEYS="[^"]*"/CONFIG_SYSTEM_TRUSTED_KEYS=""/' .config
sed -i 's/CONFIG_SYSTEM_REVOCATION_KEYS="[^"]*"/CONFIG_SYSTEM_REVOCATION_KEYS=""/' .config

# Enable XZ compression and EFI stub
echo "Enabling XZ compression and EFI stub..."
sed -i 's/^# CONFIG_KERNEL_XZ is not set/CONFIG_KERNEL_XZ=y/' .config
sed -i 's/^CONFIG_KERNEL_GZIP=y/# CONFIG_KERNEL_GZIP is not set/' .config
sed -i 's/^# CONFIG_EFI_STUB is not set/CONFIG_EFI_STUB=y/' .config

# Update the configuration
echo "Updating kernel configuration..."
yes "" | make oldconfig  # Accept all default options without prompting

# Prepare the source and build directories
echo "Preparing the source and build environment..."
make prepare
make scripts

# Determine kernel version
KERNEL_VERSION=$(make -s kernelrelease)

# Check for required utilities
command -v make > /dev/null || { echo "Error: 'make' is not installed."; exit 1; }
command -v kernelstub > /dev/null || { echo "Error: 'kernelstub' is not installed."; exit 1; }
command -v bootctl > /dev/null || { echo "Error: 'bootctl' is not installed."; exit 1; }

echo "Building Linux kernel version $KERNEL_VERSION..."

# Step 1: Build the kernel and modules
make -j$(nproc) V=1

# Step 2: Strip unneeded symbols from modules and kernel
echo "Stripping unneeded symbols..."
sudo make INSTALL_MOD_STRIP=1 modules_install
strip --strip-debug arch/x86/boot/bzImage

# Step 3: Install kernel and System.map
sudo make install

# Step 4: Update systemd-boot entries
KERNEL_IMAGE="$INSTALL_DIR/vmlinuz-$KERNEL_VERSION"
INITRD_IMAGE="$INSTALL_DIR/initrd.img-$KERNEL_VERSION"

# Ensure initramfs is created
if [[ ! -f "$INITRD_IMAGE" ]]; then
    echo "Creating initramfs for kernel $KERNEL_VERSION..."
    sudo update-initramfs -c -k "$KERNEL_VERSION"
fi

# Configure kernelstub for the new kernel
echo "Updating kernelstub for the new kernel..."
sudo kernelstub -k "$KERNEL_IMAGE" -i "$INITRD_IMAGE"

# Verify systemd-boot is updated
echo "Verifying systemd-boot..."
sudo bootctl update

echo "Kernel $KERNEL_VERSION built and installed successfully."
echo "Reboot your system to use the new kernel."

