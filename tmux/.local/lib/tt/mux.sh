# shellcheck shell=bash
# The tmux backend: everything that talks to tmux about projects and tasks. Another multiplexer would replace these.

# shellcheck source=common.sh
source "${BASH_SOURCE[0]%/*}/common.sh"

# mux_project <root>: the project session of a repo (its main checkout), by tag; none when no server is running.
mux_project() {
    tmux list-sessions -F "#{session_id}$tab#{@repo}" 2>/dev/null |
        awk -F'\t' -v r="$1" '$2 == r { print $1; exit }' || true
}

# mux_session_name <root>: a free session name for a repo. tmux names can't hold . or :, and must be unique.
mux_session_name() {
    local base=${1##*/} name n=1
    name=${base//[.:]/_}
    while tmux has-session -t "=$name" 2>/dev/null; do
        n=$((n + 1))
        name=$base-$n
        name=${name//[.:]/_}
    done
    echo "$name"
}

# mux_create_project <root>: a repo's project session with its orchestrator window; prints the orchestrator's pane.
mux_create_project() {
    local root=$1 out s w p
    out=$(tmux new-session -d -P -F "#{session_id}$us#{window_id}$us#{pane_id}" \
        -s "$(mux_session_name "$root")" -n orch -c "$root")
    IFS=$us read -r s w p <<<"$out"
    tmux set -t "$s" @kind agent \; set -t "$s" @repo "$root" \; set -w -t "$w" @role orchestrator
    echo "$p"
}

# mux_orchs <session>: its orchestrator windows, in window order.
mux_orchs() {
    tmux list-windows -t "$1" -F "#{window_id}$tab#{@role}" | awk -F'\t' '$2 == "orchestrator" { print $1 }'
}

# mux_create_orch <session> <root>: another orchestrator window, after the last one (-a), so they stay together
# before the tasks; prints its pane.
mux_create_orch() {
    local s=$1 root=$2 out w p
    out=$(tmux new-window -d -a -P -F "#{window_id}$us#{pane_id}" -t "$(mux_orchs "$s" | tail -1)" -n orch -c "$root")
    IFS=$us read -r w p <<<"$out"
    tmux set -w -t "$w" @role orchestrator
    echo "$p"
}

# mux_create_task <session> <path> <branch>: a task window in a project session; prints its pane.
mux_create_task() {
    local s=$1 path=$2 branch=$3 out w p
    out=$(tmux new-window -d -P -F "#{window_id}$us#{pane_id}" -t "$s:" -n "$branch" -c "$path")
    IFS=$us read -r w p <<<"$out"
    tmux set -w -t "$w" @task "$branch" \; set -w -t "$w" @task_path "$path"
    echo "$p"
}

# mux_run <pane> <command>: types the command at the pane's shell prompt.
mux_run() { tmux send-keys -t "$1" -l "$2" \; send-keys -t "$1" Enter; }

# mux_send <pane> <text>: pastes the text into the pane's program and submits it. Bracketed paste (-p) keeps
# newlines from submitting early; Enter goes separately, after the TUI has taken the paste in.
mux_send() {
    printf %s "$2" | tmux load-buffer -b tt-send -
    tmux paste-buffer -p -d -b tt-send -t "$1"
    sleep 0.3
    tmux send-keys -t "$1" Enter
}

# mux_tasks: every task window: window, path, agent state, repo, conversation title.
mux_tasks() {
    tmux list-windows -a -F "$(formats '#{window_id}' '#{@task_path}' "$live_state" '#{@repo}' "$title")" 2>/dev/null |
        awk -F'\t' '$2 != ""'
}

# mux_task_paths: the path of every task window.
mux_task_paths() { mux_tasks | cut -f2; }

# mux_panes: every pane in a project session: pane, agent state, agent, cwd, window role, task.
mux_panes() {
    local format
    format=$(formats '#{@kind}' '#{pane_id}' "$live_state" "#{?$live,#{@agent},}" '#{pane_current_path}' \
        '#{@role}' '#{@task}')
    tmux list-panes -a -F "$format" 2>/dev/null | awk -F'\t' '$1 == "agent"' | cut -f2-
}

# mux_focus <target>: shows a session, window or pane: switches the client inside tmux, attaches outside it.
mux_focus() {
    if [ -n "${TMUX:-}" ]; then
        tmux switch-client -t "$1" \; select-window -t "$1" \; select-pane -t "$1"
    else
        exec tmux attach -t "$1"
    fi
}

# mux_focus_new <pane>: shows a pane tt just opened, when a person started it from a terminal; an agent's hand-off
# stays in the background.
mux_focus_new() {
    if [ -t 0 ] && [ -n "${TMUX:-}" ]; then mux_focus "$1"; fi
}
