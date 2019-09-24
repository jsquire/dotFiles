#!/bin/bash

# Capture the desired install versions.

DOTNETCORE=3.0
NVM_VERSION=0.34.0

# Update the local system to ensure a stable starting point.

sudo apt-get update
sudo apt-get upgrade -y
sudo apt-get dist-upgrade -y
sudo apt-get autoremove -y
sudo apt-get clean -y

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