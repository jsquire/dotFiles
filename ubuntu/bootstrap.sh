#!/bin/bash

# Capture the current execution environment.

WORKDIR=$(pwd)

# Clean-up some unwanted default installations.

sudo apt-get remove \
    shotwell \
    shotwell-common \
    thunderbird \
    rhythmbox \
    cheese \
    aisleriot \
-y

# Snapd has been causing failures in the initial distribution upgrades; remove
# it for the initial patching and then re-add.

sudo apt-get purge snapd -y

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
    snapd \
    gnome-software-plugin-snap \
-y

# Install packages from the base repositories

sudo apt-get update

sudo apt-get install \
    ubuntu-restricted-extras \
    tmux \
    xrdp \
    gparted \
    hardinfo \
    synaptic \
    gpg-agent \
    pinentry-curses \
    avahi-daemon \
    gnome-tweaks \
    gnome-system-tools \
    grub-customizer \
    gnome-system-monitor \
    elementary-icon-theme \
    gnome-extra-icons \
    gnome-shell-extension-multi-monitors \
    gnome-shell-extension-dashtodock \
    gtk2-engines-murrine \
    gtk2-engines-pixbuf \
-y

# Install the micro editor

sudo mkdir -p /usr/local/bin
cd /usr/local/bin
sudo curl https://getmic.ro | sudo bash
cd $WORKDIR

# Install Chrome

wget -q -O - https://dl-ssl.google.com/linux/linux_signing_key.pub | sudo apt-key add -
echo 'deb [arch=amd64] http://dl.google.com/linux/chrome/deb/ stable main' | sudo tee /etc/apt/sources.list.d/google-chrome.list

sudo apt-get update
sudo apt-get install google-chrome-stable -y

# Install VS Code

curl https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > packages.microsoft.gpg
sudo install -o root -g root -m 644 packages.microsoft.gpg /usr/share/keyrings/
sudo sh -c 'echo "deb [arch=amd64 signed-by=/usr/share/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/vscode stable main" > /etc/apt/sources.list.d/vscode.list'

sudo apt-get update
sudo apt-get install code -y
rm packages.microsoft.gpg

# Install Docker

sudo apt-get remove docker docker-engine docker.io docker-compose -y

curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -

sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable edge"
sudo apt-get update
sudo apt-get install docker-ce docker-compose -y

sudo systemctl start docker
sudo systemctl enable docker

# Install and Configure UWF Firewall

sudo apt-get install ufw gufw -y

sudo ufw default deny incoming
sudo ufw default allow outgoing

sudo ufw allow ssh
sudo ufw allow 3389/tcp    # Remote Desktop (xrdp)
sudo ufw allow 5297/tcp    # Bonjour (Avahi)
sudo ufw allow 5297/udp    # Bonjour (Avahi)
sudo ufw allow 5350/udp    # Bonjour (Avahi)
sudo ufw allow 5351/udp    # Bonjour (Avahi)
sudo ufw allow 5353/udp    # Bonjour (Avahi)

sudo ufw enable

# Configure remote desktop sessions

cat << EOF > ~/.xsessionrc
echo export GNOME_SHELL_SESSION_MODE=ubuntu
export XDG_CURRENT_DESKTOP=ubuntu:GNOME
export XDG_CONFIG_DIRS=/etc/xdg/xdg-ubuntu:/etc/xdg
EOF

# Mojave Theme and Icons

git clone https://github.com/vinceliuice/Mojave-gtk-theme.git ./mojave
sudo ./mojave/install.sh
rm -rf ./mojave

git clone https://github.com/vinceliuice/McMojave-circle.git ./mojave-circle
sudo ./mojave-circle/install.sh
rm -rf ./mojave-circle

# Final clean-up pass

sudo apt-get update
sudo apt-get upgrade -y
sudo apt-get autoremove -y
sudo apt-get clean -y