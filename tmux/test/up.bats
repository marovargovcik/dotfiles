#!/usr/bin/env bats
# tt up reopens the agent panes that save recorded, each resuming its conversation.

# shellcheck source=helpers.bash
source "$BATS_TEST_DIRNAME/helpers.bash"

setup() {
    setup_tt
    git_repo app
    "$tt" new task </dev/null
    task=$(pane_of "$TT_WORKTREES/app/task")
    orch=$(tmux display -p -t app:0 '#{pane_id}')
    open=$XDG_STATE_HOME/tt/open.tsv
}

teardown() {
    teardown_tt
}

# restart: a server that starts empty, as after a reboot.
restart() {
    local pid
    pid=$(tmux display -p '#{pid}')
    tmux kill-server
    while kill -0 "$pid" 2>/dev/null; do sleep 0.05; done
    start_tmux
    : >"$tmp/claude.log"
}

@test "save records each agent pane: session, kind, repo, role, task, directory, window name, conversation" {
    agent_in "$orch"
    agent_in "$task"
    tmux new-window -d -t keep: -n notes
    run cat "$open"
    assert_output "$(printf '%s\t' app agent "$tmp/app" orchestrator '' "$tmp/app" orch)session-${orch#%}
$(printf '%s\t' app agent "$tmp/app" '' task "$TT_WORKTREES/app/task" task)session-${task#%}"
}

@test "up brings back the project session, its orchestrator and its tasks, each resuming its conversation" {
    agent_in "$orch"
    agent_in "$task"
    restart
    run "$tt" up </dev/null
    assert_success
    assert_equal "$(tmux list-windows -t app -F '#{window_name}:#{@role}:#{@task}:#{@task_path}')" "orch:orchestrator::
task::task:$TT_WORKTREES/app/task"
    assert_equal "$(tag app @repo)" "$tmp/app"
    eventually claude_ran "$tmp/app" "--resume session-${orch#%}"
    eventually claude_ran "$TT_WORKTREES/app/task" "--resume session-${task#%}"
    assert_equal "$(tag "$(window_of "$TT_WORKTREES/app/task")" @agent_session)" "session-${task#%}"
}

@test "with no orchestrator recorded, the new session's orch resumes its newest conversation" {
    agent_in "$task"
    conversation "$tmp/app" newest
    restart
    "$tt" up </dev/null
    eventually claude_ran "$tmp/app" "--resume newest"
    eventually claude_ran "$TT_WORKTREES/app/task" "--resume session-${task#%}"
}

@test "an agent outside the project sessions comes back in a session of the same name" {
    plain=$(tmux new-window -d -P -F '#{pane_id}' -t keep: -n notes -c "$tmp" claude)
    agent_in "$plain"
    restart
    "$tt" up </dev/null
    assert_equal "$(tmux list-windows -t keep -F '#{window_name}' | tail -1)" notes
    eventually claude_ran "$tmp" "--resume session-${plain#%}"
}

@test "what's open already, and a worktree that's gone, stay as they are" {
    agent_in "$orch"
    agent_in "$task"
    tmux kill-window -t "$(window_of "$TT_WORKTREES/app/task")"
    git worktree remove "$TT_WORKTREES/app/task"
    "$tt" up </dev/null
    assert_equal "$(tmux list-windows -t app | wc -l)" 1
}

@test "a second up while one runs does nothing, and save leaves the record alone meanwhile" {
    agent_in "$orch"
    record=$(cat "$open")
    mkdir "$open.lock"
    agent_in "$task"
    assert_equal "$(cat "$open")" "$record"
    restart
    "$tt" up </dev/null
    assert_equal "$(tmux list-sessions -F '#{session_name}')" keep
}

@test "a lock left by a killed up expires after two minutes" {
    agent_in "$orch"
    restart
    mkdir "$open.lock"
    touch -d '3 minutes ago' "$open.lock"
    "$tt" up </dev/null
    eventually claude_ran "$tmp/app" "--resume session-${orch#%}"
    assert [ ! -e "$open.lock" ]
}

@test "up with nothing recorded does nothing" {
    rm -f "$open"
    restart
    run "$tt" up </dev/null
    assert_success
    assert_equal "$(tmux list-sessions -F '#{session_name}')" keep
}
