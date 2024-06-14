#!/bin/bash

ARGS=""

if [ $# -gt 0 ];
then
    ARGS="$@ "
fi

# Detect the OS
os_name=$(awk -F= '/^ID=/{print $2}' /etc/os-release)

# Choose the terminal emulator based on the OS
case "$os_name" in
    ubuntu|pop|fedora)
        ./install.sh gnome-terminal
        echo "gnome-terminal ${ARGS}--"
        ;;
    arch)
        ./install.sh konsole
        echo "konsole --separate -e"
        ;;
    *)
        echo ""
        exit 1
        ;;
esac