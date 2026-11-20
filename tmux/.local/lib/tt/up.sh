# shellcheck shell=bash
# tt up: reopens every agent pane recorded in $open, each resuming its own conversation. save keeps that record.

# shellcheck source=mux.sh
source "${BASH_SOURCE[0]%/*}/mux.sh"
# shellcheck source=agent.sh
source "${BASH_SOURCE[0]%/*}/agent.sh"

# restoring: whether tt up holds its lock, taken under two minutes ago (an older one was left by a killed run).
restoring() { [ -d "$lock" ] && [ -z "$(find "$lock" -maxdepth 0 -mmin +2)" ]; }

# save: records every agent pane for tt up: session, its @kind and @repo, window @role, @task and name (one tmux
# names itself after its program is left out), directory, conversation. Not while tt up is restoring: the record
# would hold only what's back so far. A failed list (the server going down) leaves the record as it was.
save() {
    restoring && return 0
    local format
    format=$(formats '#{session_name}' '#{@kind}' '#{@repo}' '#{@role}' '#{@task}' '#{pane_current_path}' \
        '#{?automatic-rename,,#{window_name}}' '#{@agent_session}')
    mkdir -p "${open%/*}"
    tmux list-panes -a -F "$format" >"$open.$$" 2>/dev/null &&
        awk -F'\t' '$8 != ""' "$open.$$" >"$open.$$.f" && mv "$open.$$.f" "$open"
    rm -f "$open.$$"
}

# is_open <session> <task> <cwd>: whether a recorded pane is open already: its conversation, or its task's window.
is_open() {
    local id=$1 task=$2 cwd=$3
    tmux list-panes -a -F '#{@agent_session}' 2>/dev/null | grep -qxF "$id" && return 0
    [ -n "$task" ] && mux_task_paths | grep -qxF "$cwd"
}

# project_pane <repo> <role> <task> <cwd>: a new pane in the repo's project session for a recorded agent pane;
# prints it. A new session's own orch takes the first orchestrator; with none recorded, it resumes the newest
# conversation, as tt proj does.
project_pane() {
    local repo=$1 role=$2 task=$3 cwd=$4 s p
    s=$(mux_project "$repo")
    if [ -z "$s" ]; then
        p=$(mux_create_project "$repo")
        if [ "$role" = orchestrator ]; then
            echo "$p"
            return
        fi
        mux_run "$p" "$(agent_cmd "$repo" resume '')"
        s=$(mux_project "$repo")
    fi
    if [ "$role" = orchestrator ]; then
        mux_create_orch "$s" "$repo"
    elif [ -n "$task" ]; then
        mux_create_task "$s" "$cwd" "$task"
    else
        tmux new-window -d -P -F '#{pane_id}' -t "$s:" -c "$cwd"
    fi
}

# plain_pane <session name> <cwd>: a new pane for an agent that ran outside the project sessions, in its session of
# the same name; prints it.
plain_pane() {
    local sname=$1 cwd=$2
    if tmux has-session -t "=$sname" 2>/dev/null; then
        tmux new-window -d -P -F '#{pane_id}' -t "=$sname:" -c "$cwd"
    else
        tmux new-session -d -P -F '#{pane_id}' -s "$sname" -c "$cwd"
    fi
}

# reopen <record>: brings back one agent pane of $open, unless it's open already or its directory is gone (an
# archived worktree).
reopen() {
    local sname kind repo role task cwd wname id p
    IFS=$us read -r sname kind repo role task cwd wname id <<<"$1"
    is_open "$id" "$task" "$cwd" && return 0
    [ -d "$cwd" ] || return 0
    if [ "$kind" = agent ] && [ -d "$repo" ]; then
        p=$(project_pane "$repo" "$role" "$task" "$cwd")
    else
        p=$(plain_pane "$sname" "$cwd")
    fi
    [ -z "$wname" ] || tmux rename-window -t "$p" "$wname"
    # Tagged now, not when claude's hook says so seconds later: another tt up meanwhile would open it twice.
    tmux set -p -t "$p" @agent_session "$id"
    mux_run "$p" "claude --resume $id"
}

# up: reopens every recorded agent pane. One at a time: the first session this creates starts the server, whose
# config runs tt up as well. A lock left by a killed run expires. Run from a terminal outside tmux, it attaches to
# what came back.
up() {
    [ -s "$open" ] || return 0
    find "$lock" -maxdepth 0 -mmin +2 -exec rmdir {} \; 2>/dev/null || true
    mkdir "$lock" 2>/dev/null || return 0
    trap 'rmdir "$lock" 2>/dev/null' EXIT
    local records r
    mapfile -t records < <(fields <"$open")
    for r in "${records[@]}"; do
        reopen "$r"
    done
    if [ -z "${TMUX:-}" ] && [ -t 0 ] && tmux has-session 2>/dev/null; then
        rmdir "$lock" && trap - EXIT
        exec tmux attach
    fi
}
