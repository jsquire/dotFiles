############################################
# ZSH SHell
############################################

sudo pacman -S zsh
chsh -s /usr/bin/zsh

############################################
# Home Configuration
############################################

cd ~
wget https://github.com/jsquire/dotFiles/raw/refs/heads/main/cachyos/home/.bashrc
wget https://github.com/jsquire/dotFiles/raw/refs/heads/main/cachyos/home/.dircolors
wget https://github.com/jsquire/dotFiles/raw/refs/heads/main/cachyos/home/.gitconfig
wget https://github.com/jsquire/dotFiles/raw/refs/heads/main/cachyos/home/.gitignore
wget https://github.com/jsquire/dotFiles/raw/refs/heads/main/cachyos/home/.p10k.zsh
wget https://github.com/jsquire/dotFiles/raw/refs/heads/main/cachyos/home/.profile
wget https://github.com/jsquire/dotFiles/raw/refs/heads/main/cachyos/home/.zshrc

