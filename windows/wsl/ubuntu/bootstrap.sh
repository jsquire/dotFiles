#!/bin/bash

set -euo pipefail

# Resolve the script directory for local file references.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Define versions to install.

CHRUBY_VERSION=0.3.9
DOTNET_VERSION=10.0
NVM_VERSION=0.40.4
RUBY_INSTALL_VERSION=0.10.2

# Update the local system to ensure a stable starting point.

sudo add-apt-repository ppa:git-core/ppa -y
sudo add-apt-repository restricted -y
sudo add-apt-repository universe -y
sudo add-apt-repository multiverse -y
sudo apt-get update
sudo apt-get upgrade -y
sudo apt-get dist-upgrade -y
sudo apt-get autoremove -y
sudo apt-get clean -y

# Install essential tools for the system, often necessary for other installations.

sudo apt-get remove git -y

sudo apt-get install \
    build-essential \
    git \
    git-lfs \
    software-properties-common \
    ca-certificates \
    curl \
    net-tools \
    bison \
    zlib1g-dev \
    libssl-dev \
    libgdbm-dev \
    libreadline-dev \
    libffi-dev \
    dos2unix \
    nano \
    gpg \
    gnupg \
    tmux \
    gpg-agent \
    pinentry-curses \
-y

# Install the micro editor

sudo mkdir -p /usr/local/bin
cd /usr/local/bin
sudo curl https://getmic.ro | sudo bash
cd $SCRIPT_DIR

# Prepare prerequisites for Microsoft pacakges

declare repo_version=$(if command -v lsb_release &> /dev/null; then lsb_release -r -s; else grep -oP '(?<=^VERSION_ID=).+' /etc/os-release | tr -d '"'; fi)
wget https://packages.microsoft.com/config/ubuntu/$repo_version/packages-microsoft-prod.deb -O packages-microsoft-prod.deb
sudo dpkg -i packages-microsoft-prod.deb
rm packages-microsoft-prod.deb
sudo apt-get update

# Install PowerShell

sudo apt-get install powershell -y

# Install .NET

sudo apt remove 'dotnet*' 'aspnet*' 'netstandard*' -y || true
sudo touch /etc/apt/preferences

sudo tee /etc/apt/preferences > /dev/null <<'EOF'
Package: dotnet* aspnet* netstandard*
Pin: origin "archive.ubuntu.com"
Pin-Priority: -10

Package: dotnet* aspnet* netstandard*
Pin: origin "archive.ubuntu.com"
Pin-Priority: -10
EOF

sudo apt-get install dotnet-sdk-${DOTNET_VERSION} -y

# Install Azure CLI

curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash

# Install Node

mkdir $HOME/.nvm -p
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v${NVM_VERSION}/install.sh | bash
[ -s "$HOME/.nvm/nvm.sh" ] && \. "$HOME/.nvm/nvm.sh"

nvm install node
nvm alias default node
nvm use node
npm i npm -g
npm install -g typescript @babel/cli @babel/core eslint nyc webpack-cli webpack

# GitHub CLI

curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
sudo chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
sudo apt update
sudo apt install gh -y

# Chruby

wget -O chruby-${CHRUBY_VERSION}.tar.gz https://github.com/postmodern/chruby/archive/v${CHRUBY_VERSION}.tar.gz
tar -xzvf chruby-${CHRUBY_VERSION}.tar.gz
cd chruby-${CHRUBY_VERSION}/
sudo make install
cd ..
rm chruby-${CHRUBY_VERSION}.tar.gz
rm -rf chruby-${CHRUBY_VERSION}/

wget -O ruby-install-${RUBY_INSTALL_VERSION}.tar.gz https://github.com/postmodern/ruby-install/archive/v${RUBY_INSTALL_VERSION}.tar.gz
tar -xzvf ruby-install-${RUBY_INSTALL_VERSION}.tar.gz
cd ruby-install-${RUBY_INSTALL_VERSION}/
sudo make install
cd ..
rm ruby-install-${RUBY_INSTALL_VERSION}.tar.gz
rm -rf ruby-install-${RUBY_INSTALL_VERSION}/

# GitHub Copilot CLI

wget -qO- https://gh.io/copilot-install | bash

# wsl.conf

WSL_CONF="/etc/wsl.conf"

if ! grep -q "\[boot\]" "$WSL_CONF" 2>/dev/null; then
    sudo tee -a "$WSL_CONF" > /dev/null <<'EOF'

[boot]
systemd=true
EOF
fi

if ! grep -q "\[user\]" "$WSL_CONF" 2>/dev/null; then
    sudo tee -a "$WSL_CONF" > /dev/null <<EOF

[user]
default=$(whoami)
EOF
fi

if ! grep -q "\[automount\]" "$WSL_CONF" 2>/dev/null; then
    sudo tee -a "$WSL_CONF" > /dev/null <<'EOF'

[automount]
enabled=true
options=metadata,uid=1000,gid=1000,umask=022
EOF
fi

if ! grep -q "\[interop\]" "$WSL_CONF" 2>/dev/null; then
    sudo tee -a "$WSL_CONF" > /dev/null <<'EOF'

[interop]
enabled = true
appendWindowsPath = true
EOF
fi

# Home directory symlinks

WIN_USER=$(cmd.exe /c "echo %USERNAME%" 2>/dev/null | tr -d '\r' || true)

if [ -z "$WIN_USER" ]; then
    WIN_USER=$(/init /mnt/c/Windows/System32/cmd.exe /c "echo %USERNAME%" 2>/dev/null | tr -d '\r' || true)
fi

WIN_HOME="/mnt/c/Users/${WIN_USER}"

if [ -z "$WIN_USER" ] || [ ! -d "$WIN_HOME" ]; then
    echo "WARNING: Could not detect Windows username; skipping symlinks."
else
    ln -sfn "${WIN_HOME}/.aws"       "$HOME/.aws"
    ln -sfn "${WIN_HOME}/.azure"     "$HOME/.azure"
    ln -sfn "${WIN_HOME}/.gnupg"     "$HOME/.gnupg"
    ln -sfn "${WIN_HOME}/.ssh"       "$HOME/.ssh"
    ln -sfn "${WIN_HOME}/Desktop"    "$HOME/Desktop"
    ln -sfn "${WIN_HOME}/Downloads"  "$HOME/Downloads"
    ln -sfn "${WIN_HOME}/OneDrive"   "$HOME/OneDrive"
    ln -sfn "/mnt/d"                 "$HOME/Projects"
fi

# SSH permissions

if [ -d "$HOME/.ssh" ]; then
    chmod 700 "$HOME/.ssh"
    chmod 600 "$HOME/.ssh"/* 2>/dev/null || true
    chmod 640 "$HOME/.ssh"/*.pub 2>/dev/null || true
    [ -f "$HOME/.ssh/known_hosts" ] && chmod 644 "$HOME/.ssh/known_hosts"
fi

# Home directory dotfiles

cp "${SCRIPT_DIR}/home/.dircolors" "$HOME/.dircolors"

# ZSH, oh-my-zsh, PowerLevel 10k

sudo apt install zsh -y
sudo usermod -s /usr/bin/zsh $(whoami)
sh -c "$(curl -fsSL https://raw.github.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended --keep-zshrc
git clone --depth=1 https://github.com/romkatv/powerlevel10k.git ${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/themes/powerlevel10k

# Final clean-up pass

sudo apt-get update
sudo apt-get upgrade -y
sudo apt-get autoremove -y
sudo apt-get clean -y
