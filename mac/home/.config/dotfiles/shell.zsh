export ZSH="$HOME/.oh-my-zsh"
plugins=(git fzf extract nvm dotnet)

if [[ -s "$ZSH/oh-my-zsh.sh" ]]; then
    source "$ZSH/oh-my-zsh.sh"
fi

if command -v brew &>/dev/null; then
    p10k_theme="$(brew --prefix powerlevel10k 2>/dev/null)/powerlevel10k.zsh-theme"
    [[ -s "$p10k_theme" ]] && source "$p10k_theme"
fi

[[ -r "$HOME/.p10k.zsh" ]] && source "$HOME/.p10k.zsh"

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

# Enable NVM
export NVM_DIR="$HOME/.nvm"
[[ -s "$NVM_DIR/nvm.sh" ]] && \. "$NVM_DIR/nvm.sh"
[[ -s "$NVM_DIR/bash_completion" ]] && \. "$NVM_DIR/bash_completion"

# Enable MISE tooling for Go and Ruby
if command -v mise &>/dev/null; then
    eval "$(mise activate zsh)"
fi

# Enable GPG signing
export GPG_TTY=$TTY

# History
HISTSIZE=50000
SAVEHIST=50000
setopt hist_ignore_dups
setopt hist_ignore_space
setopt share_history

# Preserve the window title
DISABLE_AUTO_TITLE="true"

ENABLE_CORRECTION="true"

# DotNet Development
export DOTNET_ROLL_FORWARD="LatestMajor"
export DOTNET_CLI_TELEMETRY_OPTOUT=1
export DOTNET_NOLOGO=1

# Key Bindings
bindkey "\033[1~" beginning-of-line
bindkey "\033[4~" end-of-line
