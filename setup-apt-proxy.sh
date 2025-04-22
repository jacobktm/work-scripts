#!/bin/bash

if [ ! -f ~/.local/bin/apt-proxy ]; then
    mkdir -p ~/.local/bin
    cp apt-proxy ~/.local/bin/
fi

if [ ! -d ~/.bash_completion.d ]; then
    mkdir -p ~/.bash_completion.d
fi
if [ ! -f ~/.bash_completion.d/apt-proxy ]; then
    cp /usr/share/bash-completion/completions/apt ~/.bash_completion.d/apt-proxy
    if [ $(grep -c apt-proxy ~/.bash_completion.d/apt-proxy) -eq 0 ]; then
        sed -i 's/complete -F _apt apt/complete -F _apt apt-proxy/' ~/.bash_completion.d/apt-proxy
    fi
fi
if [ $(grep -c "~/\.bash_completion\.d" ~/.bashrc) -eq 0 ]; then
    echo -e "if [ -d ~/.bash_completion.d ]; then\n    for f in ~/.bash_completion.d/*; do\n        . \"\$f\"\n    done\nfi" >> ~/.bashrc
fi
if [ -f ~/.zshrc ]; then
    if [ $(grep -c "~/\.bash_completion\.d" ~/.zshrc) -eq 0 ]; then
        echo -e "if [ -d ~/.bash_completion.d ]; then\n    for f in ~/.bash_completion.d/*; do\n        . \"\$f\"\n    done\nfi" >> ~/.zshrc
    fi
fi
