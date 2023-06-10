#!/bin/bash

# Capture the current execution environment.

WORKDIR=$(pwd)

# Define versions to install.

CHRUBY_VERSION=0.3.9
DOTNET_VERSIONS=(6.0 7.0)
NVM_VERSION=0.39.3
RUBY_INSTALL_VERSION=0.9.0

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
    apt-transport-https \
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
cd $WORKDIR

# Install Docker

sudo apt-get remove docker docker-engine docker.io docker-compose -y

sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch="$(dpkg --print-architecture)" signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  "$(. /etc/os-release && echo "$VERSION_CODENAME")" stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
  
sudo apt-get update
sudo apt-get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

sudo systemctl start docker
sudo systemctl enable docker

# Prepare prerequisites for Microsoft pacakges

declare repo_version=$(if command -v lsb_release &> /dev/null; then lsb_release -r -s; else grep -oP '(?<=^VERSION_ID=).+' /etc/os-release | tr -d '"'; fi)
wget https://packages.microsoft.com/config/ubuntu/$repo_version/packages-microsoft-prod.deb -O packages-microsoft-prod.deb
sudo dpkg -i packages-microsoft-prod.deb
rm packages-microsoft-prod.deb
sudo apt-get update

# Install PowerShell

sudo apt-get install powershell -y

# Install .NET

sudo apt remove 'dotnet*' 'aspnet*' 'netstandard*'
sudo touch /etc/apt/preferences

sudo echo \
"Package: dotnet* aspnet* netstandard*
Pin: origin \"archive.ubuntu.com\"
Pin-Priority: -10

Package: dotnet* aspnet* netstandard*
Pin: origin \"archive.ubuntu.com\"
Pin-Priority: -10" > /etc/apt/preferences

for ver in "${DOTNET_VERSIONS[@]}"
do
  sudo apt-get install dotnet-sdk-$ver -y
done

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
npm install -g azure-functions-core-tools@3 --unsafe-perm true --allow-root

# GitHub CLI
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
sudo chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
sudo apt update
sudo apt install gh

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

# ZSH, oh-my-zsh, PowerLevel 10k

sudo apt install zsh
sudo usermod -s /usr/bin/zsh $(whoami)
sh -c "$(curl -fsSL https://raw.github.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
git clone --depth=1 https://github.com/romkatv/powerlevel10k.git ${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/themes/powerlevel10k

# Final clean-up pass

sudo apt-get update
sudo apt-get upgrade -y
sudo apt-get autoremove -y
sudo apt-get clean -y
