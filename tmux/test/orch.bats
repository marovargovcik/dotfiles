#!/usr/bin/env bats
# tt orch: the repo's orchestrator windows, and moving between them.

# shellcheck source=helpers.bash
source "$BATS_TEST_DIRNAME/helpers.bash"

setup() {
    setup_tt
    git_repo app
}

teardown() {
    teardown_tt
}

@test "orch new adds an orchestrator after the last one, before the tasks, with claude started fresh" {
    conversation "$tmp/app" 1111
    "$tt" new task </dev/null
    run "$tt" orch new "$tmp/app" </dev/null
    assert_success
    assert_equal "$(tmux list-windows -t app -F '#{window_name}:#{@role}')" "orch:orchestrator
orch:orchestrator
task:"
    assert_output "$(tmux list-panes -t app:1 -F '#{pane_id}')"
    eventually claude_ran "$tmp/app" ''
}

@test "orch goes to the next orchestrator window, wrapping around" {
    "$tt" orch new "$tmp/app" </dev/null
    first=$(tmux list-windows -t app -F '#{window_id}' | sed -n 1p)
    second=$(tmux list-windows -t app -F '#{window_id}' | sed -n 2p)
    session=$(tag app session_id)
    "$tt" orch "$session" "$first"
    assert_equal "$(tag app window_id)" "$second"
    "$tt" orch "$session" "$second"
    assert_equal "$(tag app window_id)" "$first"
}

@test "orch new outside a repo refuses" {
    run "$tt" orch new "$tmp" </dev/null
    assert_failure
    assert_output "tt: not in a git repo"
}
