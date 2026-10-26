if [[ -x /opt/homebrew/bin/brew ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
elif [[ -x /usr/local/bin/brew ]]; then
    eval "$(/usr/local/bin/brew shellenv)"
fi

if command -v brew &>/dev/null; then
    rustup_prefix="$(brew --prefix rustup 2>/dev/null)"

    if [[ -n "$rustup_prefix" && -d "$rustup_prefix/bin" ]]; then
        PATH="$rustup_prefix/bin:$PATH"
    fi
fi

if [[ -d "$HOME/bin" ]]; then
    PATH="$HOME/bin:$PATH"
fi

if [[ -d "$HOME/.local/bin" ]]; then
    PATH="$HOME/.local/bin:$PATH"
fi

export PATH
