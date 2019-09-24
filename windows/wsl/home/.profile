# ~/.profile: executed by the command interpreter for login shells.
# This file is not read by bash(1), if ~/.bash_profile or ~/.bash_login
# exists.
# see /usr/share/doc/bash/examples/startup-files for examples.
# the files are located in the bash-doc package.

# the default umask is set in /etc/profile; for setting the umask
# for ssh logins, install and configure the libpam-umask package.
#umask 022

# if running bash
if [ -n "$BASH_VERSION" ]; then
    # include .bashrc if it exists
    if [ -f "$HOME/.bashrc" ]; then
	. "$HOME/.bashrc"
    fi
fi

# set PATH so it includes user's private bin locations, if they exist
if [ -d "$HOME/bin" ] ; then
    PATH="$HOME/bin:$PATH"
fi

if [ -d "$HOME/.local/bin" ] ; then
    PATH="$HOME/.local/bin:$PATH"
fi

# Expose the Windows Docker host.  Note, the port may change between versions.
export DOCKER_HOST=tcp://127.0.0.1:2375

# Force Ruby version
#     see: ~/.ruby-version

LS_COLORS="ow=01;97:di=01;97"
export LS_COLORS

# Alias the color codes, to make reading easier.
colorCyan='\[\e[0;96m\]' 
colorWhite='\[\e[0;37m\]' 
colorReset='\[\e[0m\]' 

# Get the name of the current Git branch and put parenthesis around it
gitBranch() { 
    git branch 2> /dev/null | sed -e '/^[^*]/d' -e 's/* \(.*\)/ (\1)/'
}

# Build the prompt
export PS1="${colorWhite}\n\u@\h: \w${colorCyan}\$(gitBranch)${colorWhite}\$${colorReset} "