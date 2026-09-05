[[ $- != *i* ]] && return

shopt -s histappend
HISTSIZE=100000
HISTFILESIZE=200000
HISTCONTROL=ignoreboth
HISTTIMEFORMAT='%F %T '

alias ls='eza'
alias ll='eza -lh'
alias la='eza -lha'
alias lt='eza --tree'
alias cat='bat'
alias lg='lazygit'

set -o vi
export EDITOR=nvim
export VISUAL=nvim
export PATH="$PATH:$HOME/.local/share/coursier/bin"

[ -f /usr/share/bash-completion/bash_completion ] && source /usr/share/bash-completion/bash_completion
[ -f /usr/share/fzf/key-bindings.bash ] && source /usr/share/fzf/key-bindings.bash
[ -f /usr/share/fzf/completion.bash ] && source /usr/share/fzf/completion.bash

lf() {
    local tmp="$(mktemp)"
    command lf -last-dir-path="$tmp" "$@"
    if [ -f "$tmp" ]; then
        local dir="$(command cat "$tmp")"
        rm -f "$tmp"
        [ -d "$dir" ] && [ "$dir" != "$PWD" ] && cd "$dir"
    fi
}

eval "$(starship init bash)"
command -v mise >/dev/null && eval "$(mise activate bash --shims)"
command -v direnv >/dev/null && eval "$(direnv hook bash)"

# zoxide last: it wraps cd, and later inits win.
eval "$(zoxide init bash)"
alias cd='z'
