# .bashrc

# If not running interactively, don't do anything
[[ $- != *i* ]] && return

# eza replaces ls
alias ls='eza'
alias ll='eza -lh'
alias la='eza -lha'
alias lt='eza --tree'

# bat replaces cat
alias cat='bat'

# lazygit
alias lg='lazygit'

set -o vi
export EDITOR=nvim
export VISUAL=nvim

# bash-completion
[ -f /usr/share/bash-completion/bash_completion ] && source /usr/share/bash-completion/bash_completion

# fzf
[ -f /usr/share/fzf/key-bindings.bash ] && source /usr/share/fzf/key-bindings.bash
[ -f /usr/share/fzf/completion.bash ] && source /usr/share/fzf/completion.bash


# starship
eval "$(starship init bash)"

# lf — cd to last dir on exit
lf() {
    local tmp="$(mktemp)"
    command lf -last-dir-path="$tmp" "$@"
    if [ -f "$tmp" ]; then
        local dir="$(command cat "$tmp")"
        rm -f "$tmp"
        [ -d "$dir" ] && [ "$dir" != "$PWD" ] && cd "$dir"
    fi
}

# mise
eval "$(/home/maro/.local/bin/mise activate bash --shims)"

# zoxide — must be last
eval "$(zoxide init bash)"
alias cd='z'
