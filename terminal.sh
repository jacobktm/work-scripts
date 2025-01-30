#!/bin/bash

ARGS=""

if [ $# -gt 0 ]; then
    ARGS="$@ "
fi

# Detect the OS
os_name=$(awk -F= '/^ID=/{print $2}' /etc/os-release)
session=$(echo $XDG_SESSION_DESKTOP)

# Function to choose terminal emulator based on session
choose_terminal_by_session() {
    case "$session" in
        gnome|ubunt|pop)
            terminal="gnome-terminal"
            ;;
        kde|plasma)
            terminal="konsole"
            ;;
        xfce)
            terminal="xfce4-terminal"
            ;;
        mate)
            terminal="mate-terminal"
            ;;
        COSMIC)
            terminal="cosmic-term"
            ;;
        *)
            terminal="xterm"
            ;;
    esac
}

# Choose the terminal emulator based on the OS
case "$os_name" in
    debian|ubuntu|pop|fedora|arch)
        choose_terminal_by_session
        ./install.sh $terminal
        echo "$terminal ${ARGS}--"
        ;;
    *)
        echo "Unsupported OS"
        exit 1
        ;;
esac
