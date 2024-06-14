#!/bin/bash

repos=(
    "https://github.com/gcc-mirror/gcc.git"
    "https://github.com/torvalds/linux.git"
    "https://github.com/python/cpython.git"
    "https://github.com/mozilla/gecko-dev.git"
    "https://github.com/rust-lang/rust.git"
    "https://github.com/v8/v8.git"
    "https://github.com/coreboot/coreboot.git"
    "https://github.com/coreboot/seabios.git"
    "https://github.com/flashrom/flashrom.git"
    "https://github.com/reactos/reactos.git"
    "https://github.com/openssl/openssl.git"
    "https://github.com/u-boot/u-boot.git"
    "https://github.com/docker/docker-ce.git"
    "https://github.com/Homebrew/brew.git"
    "https://github.com/mathiasbynens/dotfiles.git"
    "https://github.com/ohmyzsh/ohmyzsh.git"
    "https://github.com/git/git.git"
    "https://github.com/kubernetes/kubernetes.git"
    "https://github.com/microsoft/vscode.git"
    "https://github.com/chromium/chromium.git"
    "https://github.com/Semantic-Org/Semantic-UI.git"
    "https://github.com/jgthms/bulma.git"
    "https://github.com/foundation/foundation-sites.git"
    "https://github.com/twbs/bootstrap.git"
    "https://github.com/vuejs/vue.git"
    "https://github.com/angular/angular.git"
    "https://github.com/facebook/react.git"
    "https://github.com/nodejs/node.git"
    "https://github.com/RustPython/RustPython.git"
    "https://github.com/amethyst/amethyst.git"
    "https://github.com/tokio-rs/tokio.git"
    "https://github.com/servo/servo.git"
    "https://github.com/scikit-learn/scikit-learn.git"
    "https://github.com/pandas-dev/pandas.git"
    "https://github.com/pallets/flask.git"
    "https://github.com/django/django.git"
    "https://github.com/llvm/llvm-project.git"
    "https://github.com/facebook/folly.git"
    "https://github.com/boostorg/boost.git"
    "https://github.com/opencv/opencv.git"
    "https://github.com/tensorflow/tensorflow.git"
    "https://github.com/sqlite/sqlite.git"
    "https://github.com/redis/redis.git"
)

if ! command -v gnome-terminal &> /dev/null
then
    sudo apt update
    sudo apt install -y gnome-terminal
fi
if ! command -v pip &> /dev/null
then
    sudo apt update
    sudo apt install -y python3-pip
fi

for repo in "${repos[@]}"; do
    repo_name=$(basename "$repo" .git)

    GIT_TASK=''
    if [ -d "$repo_name" ]; then
        GIT_TASK="cd $repo_name && git reset --hard HEAD && git fetch --all && git pull --rebase && "
    else
        GIT_TASK="until git clone ${repo}; do echo 'Retrying git clone...'; sleep 1; done && "
    fi

    gnome-terminal -- bash -c "${GIT_TASK}cd $repo_name && git submodule update --init --recursive --checkout"
done

sudo pip install tensorflow transformers tokenizers datasets
sudo pip install torch torchvision -f https://download.pytorch.org/whl/cu115/torch_stable.html