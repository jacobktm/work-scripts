#!/bin/bash

TARGET=$(cat /sys/class/dmi/id/product_version)
BRANCH="master"
MODULES_CSV=""
RM_FIRST=0
UPDATE_FIRST=0
UTILS_BUILT_FILE="~/.coreboot_utils_built"

usage() {
    cat <<EOF
Usage: $0 [options]

Options:
    -s, --system SYSTEM        Target system to build open firmware.
    -b, --branch BRANCH        firmware-open branch to checkout and build.
    -m, --modules LIST         Comma-separated list of submodule:branch pairs
                               e.g. "coreboot:master,ec:system76".
    -r, --rm                   Remove previously cloned firmware-open and clone again.
    -u, --update               Git fetch && git pull before building firmware.
    -h, --help                 Show this help.

Examples:
    $0 -s darp11 --modules "coreboot:master,ec:system76"
    $0 --rm
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        -s|--system)
            [[ $# -ge 2 ]] || { echo "error: $1 requires a value" >&2; usage >&2; exit 2; }
            TARGET="$2"
            shift 2
            ;;
        -b|--branch)
            [[ $# -ge 2 ]] || { echo "error: $1 requires a value" >&2; usage >&2; exit 2; } 
            BRANCH="$2"
            shift 2
            ;;
        -m|--modules)
            [[ $# -ge 2 ]] || { echo "error: $1 requires a value" >&2; usage >&2; exit 2; }
            MODULES_CSV="$2"
            shift 2
            ;;
        -r|--rm)
            RM_FIRST=1
            shift
            ;;
        -u|--update)
            UPDATE_FIRST=1
            shift
            ;;
        *)
            echo "error: unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

apply_module_branches() {
    local csv="$1"
    [[ -n "$csv" ]] || return 0

    # Save and restore IFS safely.
    local oldIFS=$IFS
    IFS=',' read -r -a pairs <<< "$csv"
    IFS=$oldIFS

    for pair in "${pairs[@]}"; do
        # Trim whitespace around each pair
        pair="${pair#"${pair%%[![:space:]]*}"}"
        pair="${pair%"${pair##*[![:space:]]}"}"

        # Split "submodule:branch" into two fields.
        # Allow branch names with ':' by splitting only once.
        local submodule branch
        IFS= read -r submodule <<< "${pair%%:*}"
        branch="${pair#*:}"

        if [[ -z "$submodule" || "$submodule" == "$branch" ]]; then
            echo "error: invalid module pair '$pair' (expected submodule:branch)" >&2
            exit 2
        fi

        pushd ~/firmware-open
            cd $submodule
            git checkout $branch
            git submodule update --init --recursive --checkout
        popd
    done
}

cd ~
if [ $RM_FIRST -gt 0 ]; then
    if [ -e firmware-open ]; then
        rm -rvf firmware-open
        rm -rf "$UTILS_BUILT_FILE"
    fi
fi

if [ ! -d firmware-open ]; then
    if [ -e "$UTILS_BUILT_FILE" ]; then
        rm -rf "$UTILS_BUILT_FILE"
    fi
    git clone --recurse-submodules https://github.com/system76/firmware-open.git
fi

cd firmware-open
if [ $UPDATE_FIRST -gt 0 ]; then
    git fetch --all
    git pull
fi
git checkout "$BRANCH"
git submodule update --init --recursive --checkout
apply_module_branches "$MODULES_CSV"
if [ ! -f "$UTILS_BUILT_FILE" ]; then
    ./scripts/install-deps.sh
    ./scripts/install-rust.sh
    ./scripts/coreboot-sdk.sh
    ./ec/scripts/deps.sh
    . ~/.cargo/env
    touch "$UTILS_BUILT_FILE"
fi
./scripts/build.sh "$TARGET"
./scripts/usb.sh "$TARGET"