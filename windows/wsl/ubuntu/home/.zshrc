# Path to your oh-my-zsh installation.
export ZSH="$HOME/.oh-my-zsh"

# oh-my-zsh theme (DISABLED FOR POWERLINE)
# see: https://github.com/ohmyzsh/ohmyzsh/wiki/Themes
#ZSH_THEME="alanpeabody"

# Which plugins would you like to load?
# Standard plugins can be found in $ZSH/plugins/
# Custom plugins may be added to $ZSH_CUSTOM/plugins/
# Example format: plugins=(rails git textmate ruby lighthouse)
# Add wisely, as too many plugins slow down shell startup.
plugins=(git nvm dotnet docker docker-compose)

# Activate oh-my-zsh
source $ZSH/oh-my-zsh.sh

# Enable Powerlevel10k instant prompt. Should stay close to the top of ~/.zshrc.
# Initialization code that may require console input (password prompts, [y/n]
# confirmations, etc.) must go above this block; everything else may go below.
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

# Activate Powerlevel (To customize prompt, run `p10k configure` or edit ~/.p10k.zsh)
source $HOME/.oh-my-zsh/custom/themes/powerlevel10k/powerlevel10k.zsh-theme
[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh

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

# History
export HISTCONTROL=ignoreboth
export HISTORY_IGNORE="(&|[bf]g|c|clear|history|exit|q|pwd|* --help)"

# Man page colors
export LESS_TERMCAP_md="$(tput bold 2> /dev/null; tput setaf 2 2> /dev/null)"
export LESS_TERMCAP_me="$(tput sgr0 2> /dev/null)"

# Useful aliases
alias make="make -j\$(nproc)"
alias c="clear"
alias please="sudo"
alias tb="nc termbin.com 9999"

# Key Bindings
bindkey "\033[1~" beginning-of-line
bindkey "\033[4~" end-of-line
