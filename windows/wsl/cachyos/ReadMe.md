# CachyOS WSL

### Overview

Included in this section are the artifacts and references used for building and configuring a CachyOS WSL instance as a CLI development environment.  The bootstrap is a single consolidated script that handles system configuration, shell setup, development tooling, and home directory provisioning.

The CachyOS WSL rootfs is sourced from [okrc/CachyOS-WSL](https://github.com/okrc/CachyOS-WSL) and ships with a pre-configured ZSH environment via `cachyos-zsh-config`.  The bootstrap layers user customizations on top of that base rather than replacing it.

### Structure

* **home**  
  _These are the $HOME items for the ZSH profile associated with the active WSL user account, including shell configuration, Git settings, GPG agent configuration, and dircolors._

### Items

* **bootstrap.sh**  
  _Authored in 2026, this script automates the full bootstrapping of the CachyOS WSL environment in a single pass, including system updates, base utilities, modern CLI tools, development platforms, Azure tooling, shell configuration, and home directory symlinks to the Windows host._
