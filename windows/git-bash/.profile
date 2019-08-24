LS_COLORS="ow=01;97:di=01;97"
export LS_COLORS

export PS1="\n\u@\h: \w$ "
cd $PROJECTS

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