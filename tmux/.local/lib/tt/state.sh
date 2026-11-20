# shellcheck shell=bash
# tt state, run by the agent's hooks, tags $TMUX_PANE with the agent's state; tt count sums the states up for the
# status line.

# shellcheck source=up.sh
source "${BASH_SOURCE[0]%/*}/up.sh"
# shellcheck source=pick.sh
source "${BASH_SOURCE[0]%/*}/pick.sh"

# start_state <agent> <session> <source> <pane's session>: a fresh start claims the pane only when no agent holds
# it, or it holds the terminal itself (tags a killed agent left behind): claude -p run from inside the agent starts
# a session too. /clear and /resume switch it.
start_state() {
    local agent=$1 sid=$2 source=$3 cur=$4 p=(-p -t "$TMUX_PANE")
    [ -z "$cur" ] || [ "$source" != startup ] || holds_terminal "$agent" || return 0
    tmux set "${p[@]}" @agent "$agent" \; set "${p[@]}" @agent_session "$sid" \; \
        set -u "${p[@]}" @agent_state \; set -u "${p[@]}" @agent_seen
    save
    notify
}

# change_state <agent> <state> <session> <pane's session> <pane's state> <visible>: moves the pane's agent to a state,
# or clears its tags. Events from any other session in this pane are someone else's.
change_state() {
    local agent=$1 new=$2 sid=$3 cur=$4 cur_state=$5 visible=$6 p=(-p -t "$TMUX_PANE") seen
    [ -z "$cur" ] || [ -z "$sid" ] || [ "$cur" = "$sid" ] || return 0
    case $new in
    clear)
        tmux set -u "${p[@]}" @agent \; set -u "${p[@]}" @agent_session \; set -u "${p[@]}" @agent_state \; \
            set -u "${p[@]}" @agent_seen
        ;;
    working | done | blocked)
        [ "$new" = "$cur_state" ] && return 0
        # Seen right away when someone is looking at the pane.
        if [ "$visible" = 1 ]; then seen=(set "${p[@]}" @agent_seen 1); else seen=(set -u "${p[@]}" @agent_seen); fi
        tmux set "${p[@]}" @agent "$agent" \; set "${p[@]}" @agent_state "$new" \; "${seen[@]}"
        save
        ;;
    *) die "state is start, working, done, blocked or clear" ;;
    esac
    notify
}

# state <start|working|done|blocked|clear> [agent]: records the agent's state from its hook (JSON on stdin), and tags
# its tmux pane with it.
state() {
    local new=${1:-} agent=${2:-claude} sid source cur cur_state visible
    IFS=$us read -r sid source < <(jq -r '[.session_id // "", .source // ""] | join("\u001f")' 2>/dev/null) || true
    case $new in
    start) record "$agent" idle "$sid" ;;
    working | done | blocked | clear) record "$agent" "$new" "$sid" ;;
    esac
    # Run by the agent's hooks, which inherit $TMUX_PANE: outside tmux, nothing to tag.
    [ -n "${TMUX_PANE:-}" ] || return 0
    IFS=$us read -r cur cur_state visible < <(tmux display -p -t "$TMUX_PANE" \
        "#{@agent_session}$us#{@agent_state}$us#{&&:#{pane_active},#{&&:#{window_active},#{session_attached}}}")
    if [ "$new" = start ]; then
        start_state "$agent" "$sid" "$source" "$cur"
    else
        change_state "$agent" "$new" "$sid" "$cur" "$cur_state" "$visible"
    fi
}

# count: blocked agents and finished ones not looked at yet, as a status-line counter.
count() {
    tmux list-panes -a -F "$live_state#{@agent_seen}" 2>/dev/null |
        awk '$0 == "blocked" || $0 == "blocked1" { b++ } $0 == "done" { d++ }
             END { if (b) printf "⚠%d ", b; if (d) printf "✓%d ", d }'
}
