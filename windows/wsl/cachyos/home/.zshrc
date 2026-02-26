# Set plugins BEFORE sourcing CachyOS config (it respects pre-set plugins)
plugins=(git fzf extract nvm dotnet docker docker-compose)

# Source CachyOS system config (oh-my-zsh, p10k, autosuggestions, etc.)
source /usr/share/cachyos-zsh-config/cachyos-config.zsh

# Load customized .dircolors, if it exists
if [[ -x /usr/bin/dircolors ]]; then
    test -r ~/.dircolors && eval "$(dircolors -b ~/.dircolors)" || eval "$(dircolors -b)"
fi

# Preferred editor for local and remote sessions
if [[ -n $SSH_CONNECTION ]]; then
    export EDITOR='nano'
else
    export EDITOR='code'
fi

############################
### SQUIRE CUSTOMIZATION ###
############################

# Starting Directory

if [[ $(pwd) == "/" ]]; then
  cd ~
fi

# Path
if [[ -d "$HOME/bin" ]] ; then
    PATH="$HOME/bin:$PATH"
fi

if [[ -d "$HOME/.local/bin" ]] ; then
    PATH="$HOME/.local/bin:$PATH"
fi

# Rust Cargo Path
export PATH="$HOME/.cargo/bin:$PATH"

# enable NVM
export NVM_DIR="$HOME/.nvm"
[[ -s "$NVM_DIR/nvm.sh" ]] && \. "$NVM_DIR/nvm.sh"  # This loads nvm
[[ -s "$NVM_DIR/bash_completion" ]] && \. "$NVM_DIR/bash_completion"  # This loads nvm bash_completion

# enable GPG signing
export GPG_TTY=$(tty)

# Preserve the window title
DISABLE_AUTO_TITLE="true"

# Aliases
LS_COMMON="--color=auto --group-directories-first --time-style=long-iso"
LS_COMMON="$LS_COMMON -I 'System\ Volume\ Information'"
LS_COMMON="$LS_COMMON -I '\$RECYCLE.BIN'"
LS_COMMON="$LS_COMMON -I '\$Recycle.Bin'"
LS_COMMON="$LS_COMMON -I '\$Sysreset'"
LS_COMMON="$LS_COMMON -I RECYCLER"
LS_COMMON="$LS_COMMON -I desktop.ini"
LS_COMMON="$LS_COMMON -I NTUSER.DAT"
LS_COMMON="$LS_COMMON -I ntuser.dat"
LS_COMMON="$LS_COMMON -I thumbs.db"
LS_COMMON="$LS_COMMON -I Thumbs.db"
LS_COMMON="$LS_COMMON -I 'Documents and Settings'"

alias ls="command ls $LS_COMMON"

ENABLE_CORRECTION="true"

# DotNet Development
export DOTNET_ROLL_FORWARD="LatestMajor"
export DOTNET_CLI_TELEMETRY_OPTOUT=1
export DOTNET_NOLOGO=1

# Chruby
[[ -f /usr/local/share/chruby/chruby.sh ]] && source /usr/local/share/chruby/chruby.sh
[[ -f /usr/local/share/chruby/auto.sh ]] && source /usr/local/share/chruby/auto.sh

# Key Bindings
bindkey "\033[1~" beginning-of-line
bindkey "\033[4~" end-of-line

# Open files/folders in Zed on Windows from WSL
zed() {
    local target
    target="$(realpath "${1:-.}")"
    zed.exe "wsl://${WSL_DISTRO_NAME}${target}"
}
