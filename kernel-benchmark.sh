#!/bin/bash

# Number of builds to average
NUM_BUILDS=32
INTERRUPTED=false
BUILD_COUNT=0
RUNS=0

PKG_LIST=("git" "build-essential" "debhelper" "devscripts" "gcc-12" "makedumpfile" "libcap-dev"
          "libelf-dev" "libnewt-dev" "libiberty-dev" "default-jdk-headless" "java-common"
          "libdw-dev" "libpci-dev" "pkg-config" "python3-dev" "flex" "bison" "libunwind8-dev"
          "liblzma-dev" "libssl-dev" "libaudit-dev" "bc" "libudev-dev" "uuid-dev" "libnuma-dev"
          "dkms" "pahole" "dwarves" "clang-15" "libclang1-15" "rustc" "rust-src" "bindgen"
          "libstdc++-12-dev" "xmlto" "sharutils" "asciidoc" "python3-docutils" "gawk")
./install.sh "${PKG_LIST[@]}"
# Path to the kernel source directory
KERNEL_DIR=~/linux

if [ ! -d "$KERNEL_DIR" ]; then
    pushd ~/
        git clone https://github.com/pop-os/linux.git
    popd
fi

if [ -f ~/.runs ]; then
    RUNS=$(cat ~/.runs)
fi
RUNS=$((RUNS+1))
echo $RUNS > ~/.runs

# Log file for build times
LOG_FILE="${HOME}/kernel_build_times-${RUNS}.log"
if [ -f "$LOG_FILE" ]; then
    rm -rvf "$LOG_FILE"
fi

ctrl_c() {
    if ! $INTERRUPTED; then
        # Calculate the average build time
        average_time=$(awk '{sum += $1} END {print sum/NR}' $LOG_FILE)
        echo "Average build time over $BUILD_COUNT builds: $average_time seconds"
        echo "Average build time over $BUILD_COUNT builds: $average_time seconds" >> $LOG_FILE
    fi
    INTERRUPTED=true
    
}

echo "Starting kernel build benchmark..."

trap ctrl_c INT TERM EXIT

# Function to clean and build the kernel
build_kernel() {
    # Make sure we're in the kernel directory
    local iteration=$1
    cd $KERNEL_DIR

    make mrproper
    git reset --hard HEAD
    git restore .

    # Build the kernel and measure the time
    TIMEFORMAT=%R  # Set time format to output seconds only
    local build_time=$( { time ./rebuild.sh > /dev/null 2>&1; } 2>&1 )
    if ! $INTERRUPTED; then
        echo "Build $iteration took $build_time seconds"
        echo "$build_time" >> $LOG_FILE
    fi
}

# Perform the builds
for i in $(seq 1 $NUM_BUILDS); do
    echo "Building kernel: Attempt $i of $NUM_BUILDS"
    build_kernel $i
    if $INTERRUPTED; then
        break
    fi
    BUILD_COUNT=$i
done
if ! $INTERRUPTED; then
    # Calculate the average build time
    average_time=$(awk '{sum += $1} END {print sum/NR}' $LOG_FILE)
    echo "Average build time over $BUILD_COUNT builds: $average_time seconds"
    echo "Average build time over $BUILD_COUNT builds: $average_time seconds" >> $LOG_FILE
    INTERRUPTED=true
fi