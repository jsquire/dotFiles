# CachyOS

### Overview

Included in this section are the artifacts and references used for building and configuring a multi-purpose environment for a CachyOS or a compatible Arch-flavored distribution.  

In some cases, the artifacts may be a subset of functionality, requiring use in a specific way or order to be helpful, where others may be a fully automated and self-contained process.  Please remember that these were written for practical personal use and are not intended to be examples of best practice, nor polished and production-ready.

### Structure

* **home**  
  _Authored over a period of time starting in roughly 2012, these are the $HOME items for the user account, including shell configuration layered on the CachyOS system zsh config, git settings, and terminal customizations.  Items in `.local/bin` may need to be marked as executable._

  * **home/.config/alacritty**  
    _Alacritty terminal emulator configuration with a custom Nord-inspired dark theme._

  * **home/.config/zed/themes**  
    _Custom Zed editor theme._

* **surface-laptop**  
  _Authored in 2026, this directory contains scripts specific to configuring Microsoft Surface laptop hardware, including kernel installation and hardware service enablement._

### Items
  
* **bootstrap.sh**  
  _Authored in 2026, this script automates the initial bootstrapping of the environment, including patching the distribution, installing/removing the default software bed, and performing configuration.  The actions performed by this script are intended to be general-purpose and suitable for both server and desktop uses, without assuming specialization._

* **init-shell.sh**  
  _Authored in 2026, this script installs ZSH and sets it as the default shell, then copies the home directory configuration files from this repository.  It is intended to be run after bootstrapping to establish the shell environment and user preferences._

* **install-development.sh**  
  _Authored in 2026, this script automates installing and configuring of a set of development tools, focusing on Azure, .NET, and Node.js.  The actions performed by this script are intended to be general-purpose, but are targeted at a development workstation._

* **secureboot.sh**  
  _Authored in 2026, this is a multi-phase script that guides configuration of Secure Boot with the Limine boot manager using sbctl.  It auto-detects progress and can be re-run after each reboot to continue through the enrollment process._