# CachyOS

### Overview

Included in this section are the artifacts and references used for building and configuring a multi-purpose CachyOS environment. Some individual home configuration assets may also work on Arch-derived distributions, but the provisioning and Plasma scripts depend on CachyOS packages and repositories.

In some cases, the artifacts may be a subset of functionality, requiring use in a specific way or order to be helpful, where others may be a fully automated and self-contained process.  Please remember that these were written for practical personal use and are not intended to be examples of best practice, nor polished and production-ready.

### Structure

* **home**  
  _Authored over a period of time starting in roughly 2012, these are the $HOME items for the user account, including shell configuration layered on the CachyOS system zsh config, git settings, and terminal customizations.  Items in `.local/bin` may need to be marked as executable._

  * **home/.config/alacritty**  
    _Alacritty terminal emulator configuration with a custom Nord-inspired dark theme._

  * **home/.config/ghostty**  
    _Ghostty terminal emulator configuration matching the Alacritty theme and controls, with native tabs, splits, and shell integration. GTK client-side decorations are forced so the tab controls and application menu remain consistent across Plasma and COSMIC. Installation and deployment remain manual while Ghostty is being evaluated._

  * **home/.config/cosmic/com.system76.CosmicTerm**  
    _COSMIC Terminal settings and the custom Jesse color scheme matching the Alacritty palette, font size, opacity, bright-bold colors, and supported shortcuts. COSMIC Terminal does not currently expose equivalent settings for the underline cursor, fixed initial dimensions, copy-on-select, mouse hiding, or line-based scrollback._

  * **home/.config/zed/themes**  
    _Custom Zed editor theme._

  The tracked `home/.config` and `home/.gnupg` assets are an inventory, not a
  promise that the bootstrap or shell installer deploys them. Terminal,
  editor, COSMIC, and GPG agent settings remain manually deployed unless an
  item explicitly says otherwise. Their applications, fonts, and other runtime
  dependencies are likewise outside the Plasma appearance profile.

* **surface-laptop**  
  _Authored in 2026, this directory contains scripts specific to configuring Microsoft Surface laptop hardware, including kernel installation and hardware service enablement._

### Items
  
* **bootstrap.sh**  
  _Authored in 2026, this script performs full CachyOS workstation provisioning. It updates the system, installs repository and AUR software, and configures services, groups, and Flatpak. It is not the appearance-only entry point. Firewall setup requires both `--enable-firewall` and an explicit `--ssh-port <port>`. Orphan removal and cache pruning are enabled only with `--package-maintenance`. Pass `--plasma-customization` only when the appearance profile should run after the complete bootstrap, and optionally pass `--plasma-wallpaper /path/to/image` to use a personal wallpaper._

* **customize-plasma.sh**  
  _Applies the reproducible parts of the current CachyOS Plasma profile: Breeze Dark colors and application style, Breeze window decorations, reduced animations, Slot Gradient Dark icons, Capitaine cursors, file-dialog preferences, GTK theme integration, and desktop/lock-screen wallpapers. The script installs its package dependencies. The Slot icon archive is resolved through the OpenDesktop JSON API, then accepted only when its filename, SHA-256 digest, and archive layout match the reviewed artifact pinned in the script. A personal wallpaper is copied into the user's local wallpaper directory when supplied. Hardware-specific input IDs, display scaling, activity IDs, panel containment IDs, and lock timeout policy are deliberately excluded._

  Run the appearance profile directly from a terminal inside the target user's
  active Plasma session. Do not run it as root, through SSH without the
  graphical user session, from a TTY, or from another desktop.
  `./customize-plasma.sh --check` validates that execution context without
  installing packages, downloading assets, or changing settings. The full
  bootstrap performs this check before any provisioning when Plasma
  customization is requested.

  ```bash
  ./customize-plasma.sh
  ```

  Reproduce the current desktop with a separately supplied personal wallpaper:

  ```bash
  ./customize-plasma.sh \
      --wallpaper "$HOME/Pictures/wolverine-2560-x1600.png"
  ```

  The personal wallpaper is intentionally not stored in this repository. The
  customization script copies the supplied image into
  `~/.local/share/wallpapers/Jesse/` before applying it. An existing Slot theme
  is reused only when its provenance marker, complete content manifest, and
  `index.theme` match the pinned artifact. Otherwise the script stops with instructions to use
  `--refresh-icons`, which stages and validates the reviewed theme before
  atomically replacing and backing up the installed copy. Updating the
  reviewed icon version requires changing its expected filename and SHA-256 in
  the script. Log out and back in after applying the profile.

  On a fresh CachyOS installation where full workstation provisioning is also
  intended, the profile can instead run as the final bootstrap phase:

  ```bash
  ./bootstrap.sh \
      --plasma-customization \
      --plasma-wallpaper "$HOME/Pictures/wolverine-2560-x1600.png"
  ```

* **init-shell.sh**  
  _Authored in 2026, this script installs ZSH and sets it as the default shell, then deploys only the explicitly listed top-level shell and Git files. It does not deploy tracked terminal, editor, COSMIC, or GPG agent configuration. It is intended to be run after bootstrapping to establish the shell environment._

* **install-development.sh**  
  _Authored in 2026, this script automates installing and configuring of a set of development tools, focusing on Azure, .NET, and Node.js. The actions performed by this script are intended to be general-purpose, but are targeted at a development workstation. Orphan removal and cache pruning run only when `--package-maintenance` is supplied._

* **backups/**  
  _Backup and restore setup, configuration, and scripts.  See `backups/ReadMe.md` for details._

* **secureboot.sh**  
  _Authored in 2026, this is a multi-phase script that guides configuration of Secure Boot with the Limine boot manager using sbctl.  It auto-detects progress and can be re-run after each reboot to continue through the enrollment process._