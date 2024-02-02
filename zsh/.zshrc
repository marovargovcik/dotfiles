#!/bin/sh
[ -f "${XDG_DATA_HOME:-$HOME/.local/share}/zap/zap.zsh" ] && source "${XDG_DATA_HOME:-$HOME/.local/share}/zap/zap.zsh"

# history
HISTFILE="$HOME/.config/zsh/.zsh_history"
HISTSIZE=1000000
SAVEHIST=1000000

# plugins
plug "hlissner/zsh-autopair"
autopair-init # loading the autopair plugin
plug "zap-zsh/supercharge"
plug "zap-zsh/zap-prompt"
plug "zsh-users/zsh-autosuggestions"
plug "zsh-users/zsh-history-substring-search"
plug "zsh-users/zsh-syntax-highlighting"

# exports & paths
export PATH="$HOME/.local/bin:$PATH"

# tools
source $(brew --prefix nvm)/nvm.sh
[ -f "$HOME/.ghcup/env" ] && source "$HOME/.ghcup/env"

# ssh keys
eval $(ssh-agent -s) > /dev/null 2>&1
ssh-add --apple-use-keychain -q ~/.ssh/famly/famly-dev-secure.pem
ssh-add --apple-use-keychain -q ~/.ssh/i4industry/aws-1-codecommit
ssh-add --apple-use-keychain -q ~/.ssh/i4industry/aws-2-codecommit
ssh-add --apple-use-keychain -q ~/.ssh/personal/codecommit
ssh-add --apple-use-keychain -q ~/.ssh/personal/github

# aliases
alias bloop=bloop-jvm
alias famlydev="aws-vault exec famly-main --no-session -- famlydev"

# completions
autoload bashcompinit && bashcompinit
autoload -Uz compinit && compinit
complete -C '/opt/homebrew/bin/aws_completer' aws