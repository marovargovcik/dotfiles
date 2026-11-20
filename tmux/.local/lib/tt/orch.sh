# shellcheck shell=bash
# tt orch: a project session's orchestrator windows, in the main checkout.

# shellcheck source=project.sh
source "${BASH_SOURCE[0]%/*}/project.sh"

# new_orch [dir [client]]: another orchestrator window in the repo's main checkout, claude started fresh; prints its
# pane. From a key binding (run-shell) there is no tty: the client is named.
new_orch() {
    local root s pane
    root=$(repo_root "${1:-.}") || die "not in a git repo"
    s=$(project "$root")
    pane=$(mux_create_orch "$s" "$root")
    mux_run "$pane" "$(agent_cmd "$root" new '')"
    if [ -n "${2:-}" ]; then
        tmux switch-client -c "$2" -t "$pane" \; select-window -t "$pane"
    else
        mux_focus_new "$pane"
    fi
    echo "$pane"
}

# next_orch [session [window]]: goes to the session's next orchestrator window after the window, wrapping around.
next_orch() {
    local orchs next i
    mapfile -t orchs < <(mux_orchs "${1:-}")
    [ ${#orchs[@]} -gt 0 ] || return 0
    next=${orchs[0]}
    for i in "${!orchs[@]}"; do
        [ "${orchs[$i]}" = "${2:-}" ] && [ $((i + 1)) -lt ${#orchs[@]} ] && next=${orchs[$((i + 1))]}
    done
    tmux select-window -t "$next"
}
