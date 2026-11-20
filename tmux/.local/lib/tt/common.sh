# shellcheck shell=bash
# What every part of tt shares: its files, the record format, and tmux format snippets.
# shellcheck disable=SC2034 # used by the files that source this one

log=${XDG_STATE_HOME:-$HOME/.local/state}/tt/archive.tsv
trash_root=${XDG_CACHE_HOME:-$HOME/.cache}/tt/trash
# What tt up reopens: a line per agent pane, rewritten on every agent state change.
open=${XDG_STATE_HOME:-$HOME/.local/state}/tt/open.tsv
# Held while tt up runs. A directory: mkdir either makes it or fails, atomically.
lock=$open.lock
worktrees=${TT_WORKTREES:-$HOME/.worktrees}
# Open pickers listen here, a socket each named <kind>.<pid>.sock, to reload
# when an agent's state changes.
pickers=${TMPDIR:-/tmp}/tt-$UID

tab=$'\t'
# Records are tab-separated, but read splits them on \037: tab is whitespace to
# read, so an empty field between two tabs would vanish and shift the rest.
us=$'\037'

# fields: stdin's tab-separated records with \037 between fields, for read.
fields() { tr '\t' '\037'; }

# formats <field...>: tmux format fields joined by tabs, one record per pane, window or session.
formats() {
    local IFS=$tab
    printf '%s\n' "$*"
}

# The title the pane's program set (Claude Code: the conversation's); tmux starts
# every pane with the host name, which says nothing.
title='#{?#{==:#{pane_title},#{host}},,#{pane_title}}'
# An agent's tags hold only while it's still what the pane runs: one that was
# killed never gets to SessionEnd and leaves them behind.
live='#{==:#{pane_current_command},#{@agent}}'
live_state="#{?$live,#{@agent_state},}"
# What a pane does: the agent's state (idle without one yet), or else its program.
doing="#{?$live,#{?#{@agent_state},#{@agent_state},idle},#{pane_current_command}}"

# die <message>: prints it after "tt:" and exits.
die() {
    echo "tt: $*" >&2
    exit 1
}

# strip_spinner <label>: the conversation title without the spinner Claude Code puts before it.
strip_spinner() {
    local label=$1
    [[ $label =~ ^[^[:alnum:]]+\ (.*)$ ]] && label=${BASH_REMATCH[1]}
    printf '%s\n' "$label"
}

# has_key <key> <name>: whether a ticket key (lowercase) is a whole segment of a worktree's name or a branch.
has_key() { [[ ${2,,} =~ (^|[/-])$1(-|$) ]]; }
