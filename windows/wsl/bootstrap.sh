#!/bin/bash

# Capture the current execution environment.

WORKDIR=$(pwd)
DOTNETCORE=2.2
NVM_VERSION=0.34.0

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

curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -

sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable edge"
sudo apt-get update
sudo apt-get install docker-ce docker-compose -y

sudo systemctl start docker
sudo systemctl enable docker

# Install .NET Core

wget -q https://packages.microsoft.com/config/ubuntu/19.04/packages-microsoft-prod.deb -O packages-microsoft-prod.deb
sudo dpkg -i packages-microsoft-prod.deb

sudo apt-get update
sudo apt-get install dotnet-sdk-${DOTNETCORE} -y
rm packages-microsoft-prod.deb

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
npm install -g azure-functions-core-tools@2 --unsafe-perm true --allow-root

# Git Extra Status

git clone https://github.com/sandeep1995/git-extra-status.git ./git-extra-status
chmod +x ./git-extra-status/bin/*
sudo mv ./git-extra-status /usr/local/bin
sudo ln -s /usr/local/bin/git-extra-status/bin/abspath /usr/local/bin/abspath
sudo ln -s /usr/local/bin/git-extra-status/bin/git-status /usr/local/bin/git-status
sudo ln -s /usr/local/bin/git-extra-status/bin/ges /usr/local/bin/ges

# Final clean-up pass

sudo apt-get update
sudo apt-get upgrade -y
sudo apt-get autoremove -y
sudo apt-get clean -y