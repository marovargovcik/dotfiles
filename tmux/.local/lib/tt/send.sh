# shellcheck shell=bash
# tt send and tt read: hand work to another pane, and see what it shows.

# shellcheck source=mux.sh
source "${BASH_SOURCE[0]%/*}/mux.sh"
# shellcheck source=agent.sh
source "${BASH_SOURCE[0]%/*}/agent.sh"

# send <pane> <hand-off>: prompts the pane's agent, or starts claude on it at a shell's prompt; refuses a pane
# waiting on its person, or running anything else.
send() {
    local pane=${1:-} handoff=${2:-} info agent state cmd cwd
    [ -n "$pane" ] && [ -n "$handoff" ] || die "send needs a pane and a hand-off"
    info=$(tmux display -p -t "$pane" "#{@agent}$us#{@agent_state}$us#{pane_current_command}$us#{pane_current_path}" \
        2>/dev/null) || die "no pane $pane"
    IFS=$us read -r agent state cmd cwd <<<"$info"
    [ "$cmd" = "$agent" ] || agent=
    if [ -z "$agent" ]; then
        case $cmd in bash | zsh | fish | sh | dash | ksh) ;; *) die "$pane is running $cmd, not a shell; nothing sent" ;; esac
        mux_run "$pane" "$(agent_cmd "$cwd" new "$handoff")"
        echo "$pane: started claude"
        return
    fi
    case $state in
    blocked) die "$pane is waiting on you; nothing sent" ;;
    working)
        mux_send "$pane" "$handoff"
        echo "$pane: queued (it's working)"
        ;;
    *)
        mux_send "$pane" "$handoff"
        echo "$pane: sent"
        ;;
    esac
}

# read_pane <pane> [lines]: what the pane shows, plus that many lines of its scrollback, without the blank lines at
# the end. -J joins wrapped lines.
read_pane() {
    [ -n "${1:-}" ] || die "read needs a pane"
    tmux capture-pane -p -J -t "$1" -S "-${2:-200}" | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}'
}
